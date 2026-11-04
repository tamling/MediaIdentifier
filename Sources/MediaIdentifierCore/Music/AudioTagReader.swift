import Foundation

/// Reads a music file's own tags, and its cover if it carries one.
///
/// ffprobe, like the rest of this project's metadata reading: no new
/// dependency, and the one tool that understands every container the
/// scanner will meet. The parsing lives in `AudioTagParser`, which is
/// pure; this part only runs the process.
public struct AudioTagReader {

    private let ffprobePath: String
    private let ffmpegPath: String

    public init(ffprobePath: String, ffmpegPath: String) {
        self.ffprobePath = ffprobePath
        self.ffmpegPath = ffmpegPath
    }

    public init?(tools: DownloadTools = .locate()) {
        guard let ffmpeg = tools.ffmpeg else { return nil }
        // ffprobe ships beside ffmpeg in every distribution's package.
        let probe = (ffmpeg as NSString).deletingLastPathComponent + "/ffprobe"
        guard FileManager.default.isExecutableFile(atPath: probe) else { return nil }
        self.init(ffprobePath: probe, ffmpegPath: ffmpeg)
    }

    /// What the file says about itself, or nil when ffprobe could not read
    /// it at all.
    public func read(_ url: URL) -> AudioTags? {
        guard let data = run(ffprobePath, [
            "-v", "quiet",
            // Both: the tags are in `format`, and the cover is a stream.
            "-show_format",
            "-show_streams",
            "-of", "json",
            url.path,
        ]) else { return nil }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        let format = root["format"] as? [String: Any]
        let rawTags = (format?["tags"] as? [String: Any]) ?? [:]
        var tags: [String: String] = [:]
        for (key, value) in rawTags {
            if let text = value as? String { tags[key] = text }
            else if let number = value as? NSNumber { tags[key] = number.stringValue }
        }

        return AudioTagParser.parse(tags, hasEmbeddedCover: Self.hasCover(root))
    }

    /// Cover art is an extra video stream whose disposition says so.
    ///
    /// Measured on MP3, FLAC and M4A: the picture is a stream with
    /// `disposition.attached_pic == 1`. NOT keyed on the stream's
    /// "comment": "Cover (front)" tag — MP3 and FLAC carry it, M4A has no
    /// tags on that stream at all.
    static func hasCover(_ root: [String: Any]) -> Bool {
        guard let streams = root["streams"] as? [[String: Any]] else { return false }
        return streams.contains { stream in
            (stream["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1
        }
    }

    /// Writes the file's embedded cover to `destination`.
    ///
    /// Re-encoded rather than copied: the embedded picture may be a PNG,
    /// and a PNG written to a file called cover.jpg is a file whose name
    /// lies about it. Returns false when there is nothing to extract.
    @discardableResult
    public func extractCover(from url: URL, to destination: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let written = run(ffmpegPath, [
            "-nostdin",
            "-v", "quiet",
            "-y",
            "-i", url.path,
            // Only the attached picture, never the audio.
            "-an",
            "-map", "0:v:0",
            // An explicit codec, so the extension and the contents agree.
            "-c:v", "mjpeg",
            "-frames:v", "1",
            destination.path,
        ]) != nil
        guard written else { return false }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size == 0 {
            // ffmpeg can exit 0 having written nothing when the input has
            // no picture stream; an empty cover.jpg is worse than none,
            // because Jellyfin would then stop looking.
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        return true
    }

    /// Runs a tool and returns its standard output, or nil on any failure.
    private func run(_ executable: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        let input = Pipe()
        process.standardInput = input
        try? input.fileHandleForWriting.close()

        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
