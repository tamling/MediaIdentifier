import Foundation

/// Decides where a converted file goes.
///
/// The output is written **beside** the original and the original is kept.
/// Nothing is deleted: re-encoding is lossy and slow, so a mistake must be
/// recoverable by simply deleting the new file. The cost is needing room for
/// both for a while, which is the right trade for media you cannot get back.
public enum ConversionOutput {
    /// Marker inserted before the extension, e.g. `Film (2014).x265.mkv`.
    public static func marker(for options: ConversionOptions) -> String {
        switch options.videoCodec {
        case .h265: return "x265"
        case .h264: return "x264"
        case .av1: return "av1"
        case .copy: return "remux"
        }
    }

    /// The file a conversion of `source` should be written to.
    ///
    /// `.mkv` is forced: it holds anything the source did, so a conversion
    /// never fails because the container cannot carry a stream.
    public static func destination(for source: URL, options: ConversionOptions,
                                   fileManager: FileManager = .default) -> URL {
        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let base = "\(stem).\(marker(for: options))"

        var candidate = directory.appendingPathComponent("\(base).mkv")
        var counter = 2
        // Never overwrite: a second run must not silently replace the first
        // run's output while it may still be playing or copying.
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(counter)).mkv")
            counter += 1
        }
        return candidate
    }

    /// True when `url` looks like something this app produced, so a second
    /// pass does not re-encode its own output.
    public static func isConvertedOutput(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return ConversionOptions.VideoCodec.allCases.contains { codec in
            let marker = Self.marker(for: ConversionOptions(videoCodec: codec))
            return stem.hasSuffix(".\(marker)")
                || stem.range(of: "\\.\(marker) \\(\\d+\\)$", options: .regularExpression) != nil
        }
    }
}

/// One file queued for conversion, as the interface shows it.
public struct ConversionCandidate: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let source: URL
    /// Size on disk, for showing what the run will chew through.
    public let byteSize: Int64

    public init(id: UUID = UUID(), source: URL, byteSize: Int64) {
        self.id = id
        self.source = source
        self.byteSize = byteSize
    }

    public var fileName: String { source.lastPathComponent }

    /// Human-readable size, e.g. "4.3 GB".
    public var readableSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: byteSize)
    }
}

/// The conversion settings the web interface exposes.
///
/// A subset of `ConversionOptions`: the switches that change the outcome in
/// ways a user can reason about. The rest keeps the library's defaults, which
/// already favour quality per byte.
public struct WebConversionSettings: Codable, Sendable, Equatable {
    public var videoCodec: ConversionOptions.VideoCodec
    /// Constant Quality. Lower is better and bigger.
    public var quality: Int
    public var preset: ConversionOptions.Preset
    /// Scale down to this height, or nil to keep the source resolution.
    public var targetHeight: Int?
    public var audioMode: ConversionOptions.AudioMode
    public var stripSubtitles: Bool
    /// Where FFmpeg is, when it is not in one of the usual places.
    public var ffmpegPath: String

    /// Set when a submitted height could not be read as a number, so
    /// `problems()` can say so instead of the value quietly becoming "keep the
    /// source resolution". It describes one submission rather than a stored
    /// setting, so it is deliberately left out of `CodingKeys` and never
    /// written to disk.
    public var targetHeightWasUnreadable: Bool = false

    private enum CodingKeys: String, CodingKey {
        case videoCodec, quality, preset, targetHeight, audioMode, stripSubtitles, ffmpegPath
    }

    public init(videoCodec: ConversionOptions.VideoCodec = .h265,
                quality: Int = 21,
                preset: ConversionOptions.Preset = .slow,
                targetHeight: Int? = nil,
                audioMode: ConversionOptions.AudioMode = .passthrough,
                stripSubtitles: Bool = false,
                ffmpegPath: String = "") {
        self.videoCodec = videoCodec
        self.quality = min(max(quality, 0), 51)
        self.preset = preset
        // A height outside what any encoder will accept is treated as "keep
        // the source resolution". Dropping it is the one choice that cannot
        // damage anything: the alternative, passing it to FFmpeg, fails the
        // encode with a message no one can act on.
        self.targetHeight = targetHeight.flatMap { (120...8192).contains($0) ? $0 : nil }
        self.audioMode = audioMode
        self.stripSubtitles = stripSubtitles
        self.ffmpegPath = ffmpegPath
    }

    /// Decoded through the memberwise initialiser so a hand-edited or
    /// older settings file gets the same clamping as a form submission.
    /// The synthesised conformance would not: it assigns the stored
    /// properties directly, and `quality: 999` from the file would reach
    /// FFmpeg as `-crf 999`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WebConversionSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        self.init(
            videoCodec: value(.videoCodec, defaults.videoCodec),
            quality: value(.quality, defaults.quality),
            preset: value(.preset, defaults.preset),
            targetHeight: try? container.decodeIfPresent(Int.self, forKey: .targetHeight),
            audioMode: value(.audioMode, defaults.audioMode),
            stripSubtitles: value(.stripSubtitles, defaults.stripSubtitles),
            ffmpegPath: value(.ffmpegPath, defaults.ffmpegPath)
        )
    }

    /// The library options these settings describe.
    public var options: ConversionOptions {
        ConversionOptions(videoCodec: videoCodec,
                          quality: quality,
                          preset: preset,
                          targetHeight: targetHeight,
                          audioMode: audioMode,
                          stripSubtitles: stripSubtitles)
    }

    /// Roughly how large the output will be, as a percentage of the input.
    public var estimatedSizePercent: Int {
        Int((ConversionEstimator.sizeFraction(options: options) * 100).rounded())
    }

    // MARK: Form decoding

    public static func fromForm(_ fields: [String: String],
                                current: WebConversionSettings) -> WebConversionSettings {
        var settings = current
        if let raw = fields["videoCodec"],
           let codec = ConversionOptions.VideoCodec(rawValue: raw) {
            settings.videoCodec = codec
        }
        if let raw = fields["preset"], let preset = ConversionOptions.Preset(rawValue: raw) {
            settings.preset = preset
        }
        if let raw = fields["audioMode"],
           let mode = ConversionOptions.AudioMode(rawValue: raw) {
            settings.audioMode = mode
        }
        if let raw = fields["quality"], let value = Int(raw) {
            settings.quality = min(max(value, 0), 51)
        }
        if let raw = fields["targetHeight"] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // "Keep the source resolution" is the empty choice. Anything else
            // that is not a number is an error, not a third way of saying it:
            // mapping it to nil would save silently and leave the user
            // believing they had configured a downscale that never happens.
            if trimmed.isEmpty {
                settings.targetHeight = nil
                settings.targetHeightWasUnreadable = false
            } else if let height = Int(trimmed) {
                settings.targetHeight = height
                settings.targetHeightWasUnreadable = false
            } else {
                settings.targetHeightWasUnreadable = true
            }
        }
        if fields["conversionFormPresent"] != nil {
            settings.stripSubtitles = fields["stripSubtitles"] != nil
        }
        if let raw = fields["ffmpegPath"] {
            settings.ffmpegPath = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return settings
    }

    public func problems() -> [WebSettings.Problem] {
        var found: [WebSettings.Problem] = []
        if targetHeightWasUnreadable {
            found.append(.init(field: "targetHeight",
                               message: "The height must be a number, or empty to keep the "
                                   + "source resolution."))
        }
        if let height = targetHeight, height < 120 || height > 8192 {
            found.append(.init(field: "targetHeight",
                               message: "The height must be between 120 and 8192."))
        }
        if !ffmpegPath.isEmpty, !ffmpegPath.hasPrefix("/") {
            found.append(.init(field: "ffmpegPath",
                               message: "The FFmpeg path must be absolute."))
        }
        return found
    }

    /// Heights offered in the form. `nil` keeps the source resolution.
    public static let offeredHeights: [Int?] = [nil, 2160, 1440, 1080, 720]

    public static func heightLabel(_ height: Int?) -> String {
        switch height {
        case nil: return "Keep the source resolution"
        case 2160?: return "2160p (4K)"
        case let value?: return "\(value)p"
        }
    }
}
