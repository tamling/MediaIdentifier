#if os(macOS)
import Foundation

/// Reads title / year tags embedded in a media container using `ffprobe` —
/// fully local (FR3, FR18).
///
/// AVFoundation (`EmbeddedMetadataProvider`) cannot parse Matroska (MKV), which
/// is the most common container for scene releases. `ffprobe` understands MKV
/// (and everything else FFmpeg supports), so this provider fills that gap. When
/// a title tag *is* present it is authoritative; when ffprobe is missing, the
/// file has no tags, or parsing fails, it returns nil and the chain falls
/// through to the next provider.
public struct FFprobeMetadataProvider: MetadataProvider {
    private let ffprobePath: String

    /// - Parameter ffprobePath: absolute path to the `ffprobe` binary.
    public init(ffprobePath: String) {
        self.ffprobePath = ffprobePath
    }

    /// First `ffprobe` binary found in a common Homebrew/system location.
    public static func defaultPath() -> String? {
        ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func identify(_ parsed: ParsedRelease, at url: URL?) async throws -> MediaMetadata? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try runFFprobe(on: url) else { return nil }
        guard let tags = Self.parseFormatTags(data) else { return nil }

        let title = Self.value(in: tags, keys: ["title"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }

        let year = Self.value(in: tags, keys: ["date", "year", "creation_time", "released_date"])
            .flatMap(YearParser.firstYear)
        return MediaMetadata(
            title: title,
            year: year ?? parsed.year,
            kind: parsed.kind == .unknown ? .movie : parsed.kind,
            source: "Datei-Tags (MKV)"
        )
    }

    /// Runs `ffprobe -show_format -of json` and returns the captured stdout.
    private func runFFprobe(on url: URL) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "quiet",
            "-show_format",
            "-of", "json",
            url.path,
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }

    /// Extracts the `format.tags` dictionary (tag keys are case-insensitive in
    /// Matroska, so callers should match case-insensitively).
    static func parseFormatTags(_ data: Data) -> [String: String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = root["format"] as? [String: Any],
              let tags = format["tags"] as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for (key, value) in tags {
            if let string = value as? String { result[key.lowercased()] = string }
        }
        return result.isEmpty ? nil : result
    }

    /// First matching tag value, comparing keys case-insensitively.
    static func value(in tags: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = tags[key.lowercased()] { return value }
        }
        return nil
    }
}
#endif
