import Foundation

/// Options for transcoding a media file (FR16) with an emphasis on quality per
/// byte (FR-1): Constant Quality (RF/CRF) rather than a fixed target bitrate.
public struct ConversionOptions: Codable, Sendable, Equatable {
    public enum VideoCodec: String, Codable, Sendable, CaseIterable {
        case h265   // libx265 / hevc_videotoolbox
        case h264   // libx264 / h264_videotoolbox
        case av1    // libsvtav1 (optional, needs AV1 HW decode on playback)
        case copy
    }

    /// x264/x265 preset names. FR-1 requires at least "slow".
    public enum Preset: String, Codable, Sendable, CaseIterable {
        case slow, slower, veryslow, medium, fast, faster, veryfast

        /// SVT-AV1 uses a numeric preset (0 slowest … 13 fastest).
        var svtAV1Level: Int {
            switch self {
            case .veryslow: return 2
            case .slower:   return 3
            case .slow:     return 4
            case .medium:   return 6
            case .fast:     return 8
            case .faster:   return 9
            case .veryfast: return 10
            }
        }
    }

    public enum AudioMode: String, Codable, Sendable, CaseIterable {
        case passthrough   // keep the original stream (Auto-Passthru)
        case opus
        case aac
    }

    public var videoCodec: VideoCodec
    /// Use Apple Silicon VideoToolbox hardware encoders (FR17). Faster, but not
    /// true CRF and less efficient than software x265; off by default so the
    /// default path maximises quality per byte (FR-1).
    public var useHardwareAcceleration: Bool
    /// Constant Quality value (RF/CRF). Lower = better quality / larger file.
    public var quality: Int
    /// Encoder preset (FR-1: at least "slow").
    public var preset: Preset
    /// 10-bit encoding (main10) to reduce banding (FR-1, SHOULD).
    public var tenBit: Bool
    /// Target height, e.g. 1080. `nil` keeps the source resolution.
    public var targetHeight: Int?
    /// How to handle audio (FR-1: efficient codec or passthrough).
    public var audioMode: AudioMode
    /// Bitrate (kbps) for re-encoded audio (Opus/AAC).
    public var audioBitrate: Int
    /// Keep only the first audio stream (FR16).
    public var keepOnlyFirstAudio: Bool
    /// Drop all subtitle streams (FR16).
    public var stripSubtitles: Bool

    public init(
        videoCodec: VideoCodec = .h265,
        useHardwareAcceleration: Bool = false,
        quality: Int = 21,
        preset: Preset = .slow,
        tenBit: Bool = true,
        targetHeight: Int? = nil,
        audioMode: AudioMode = .passthrough,
        audioBitrate: Int = 160,
        keepOnlyFirstAudio: Bool = false,
        stripSubtitles: Bool = false
    ) {
        self.videoCodec = videoCodec
        self.useHardwareAcceleration = useHardwareAcceleration
        self.quality = quality
        self.preset = preset
        self.tenBit = tenBit
        self.targetHeight = targetHeight
        self.audioMode = audioMode
        self.audioBitrate = audioBitrate
        self.keepOnlyFirstAudio = keepOnlyFirstAudio
        self.stripSubtitles = stripSubtitles
    }

    /// Suggested RF for a given height (FR-1): ~20–22 for 1080p, ~22–26 for 4K.
    public static func suggestedQuality(forHeight height: Int?) -> Int {
        guard let height else { return 21 }
        return height >= 1600 ? 24 : 21
    }
}

/// Builds the FFmpeg argument list (FR16, FR17, FR-1). Pure and separate from
/// process execution so it can be unit-tested without FFmpeg installed.
///
/// Constant Quality only: never emits `-b:v`/`-pass` (no ABR / two-pass).
public enum FFmpegArgumentBuilder {
    public static func arguments(input: URL, output: URL, options: ConversionOptions) -> [String] {
        var args = ["-y", "-i", input.path]

        // Stream selection.
        if options.keepOnlyFirstAudio {
            args += ["-map", "0:v:0", "-map", "0:a:0?"]
        } else {
            args += ["-map", "0"]
        }
        if options.stripSubtitles {
            args += ["-sn"]
        }

        args += videoArguments(options)

        // Scaling (FR16).
        if let height = options.targetHeight {
            args += ["-vf", "scale=-2:\(height)"]
        }

        args += audioArguments(options)

        args.append(output.path)
        return args
    }

    private static func videoArguments(_ o: ConversionOptions) -> [String] {
        let q = String(o.quality)
        let pix10 = "yuv420p10le"
        let pix8 = "yuv420p"

        switch o.videoCodec {
        case .copy:
            return ["-c:v", "copy"]

        case .h265:
            if o.useHardwareAcceleration {
                var a = ["-c:v", "hevc_videotoolbox", "-q:v", q, "-tag:v", "hvc1"]
                if o.tenBit { a += ["-profile:v", "main10", "-pix_fmt", "p010le"] }
                return a
            }
            // Software x265 + Constant Quality (CRF) — the FR-1 quality path.
            return ["-c:v", "libx265", "-preset", o.preset.rawValue, "-crf", q,
                    "-pix_fmt", o.tenBit ? pix10 : pix8, "-tag:v", "hvc1"]

        case .h264:
            if o.useHardwareAcceleration {
                return ["-c:v", "h264_videotoolbox", "-q:v", q]
            }
            return ["-c:v", "libx264", "-preset", o.preset.rawValue, "-crf", q, "-pix_fmt", pix8]

        case .av1:
            // SVT-AV1, Constant Quality.
            return ["-c:v", "libsvtav1", "-crf", q, "-preset", String(o.preset.svtAV1Level),
                    "-pix_fmt", o.tenBit ? pix10 : pix8]
        }
    }

    private static func audioArguments(_ o: ConversionOptions) -> [String] {
        switch o.audioMode {
        case .passthrough:
            return ["-c:a", "copy"]
        case .opus:
            return ["-c:a", "libopus", "-b:a", "\(o.audioBitrate)k"]
        case .aac:
            return ["-c:a", "aac", "-b:a", "\(o.audioBitrate)k"]
        }
    }
}

/// Future-facing converter that shells out to FFmpeg (FR16). Execution is
/// implemented but the UI exposes it as an opt-in advanced feature.
public final class FFmpegConverter {
    public enum ConverterError: Error, LocalizedError {
        case ffmpegNotFound
        case conversionFailed(code: Int32, message: String)

        public var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "FFmpeg was not found. Install it (e.g. `brew install ffmpeg`)."
            case let .conversionFailed(code, message):
                return "FFmpeg exited with code \(code): \(message)"
            }
        }
    }

    private let ffmpegPath: String

    public init(ffmpegPath: String = "/opt/homebrew/bin/ffmpeg") {
        self.ffmpegPath = ffmpegPath
    }

    public var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: ffmpegPath)
    }

    #if os(macOS)
    /// Runs a conversion synchronously. Intended to be called off the main
    /// thread. `progress` reports this file's completion fraction (0...1),
    /// parsed live from FFmpeg's `-progress` output.
    public func convert(
        input: URL,
        output: URL,
        options: ConversionOptions,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        guard isAvailable else { throw ConverterError.ffmpegNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        var args = FFmpegArgumentBuilder.arguments(input: input, output: output, options: options)
        args.insert(contentsOf: ["-progress", "pipe:1", "-nostats"], at: 1)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let state = ProgressState()

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            state.appendError(text)
            if let dur = FFmpegConverter.parseDuration(text) { state.setDurationIfNeeded(dur) }
        }
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let us = Double(line.dropFirst("out_time_us=".count)),
                   let duration = state.duration, duration > 0 {
                    progress?(min(1.0, us / 1_000_000.0 / duration))
                }
            }
        }

        try process.run()
        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        if process.terminationStatus != 0 {
            throw ConverterError.conversionFailed(code: process.terminationStatus, message: state.errorText)
        }
        progress?(1)
    }

    /// Parses an FFmpeg "Duration: HH:MM:SS.ss" line into seconds.
    static func parseDuration(_ text: String) -> Double? {
        let pattern = #"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hR = Range(m.range(at: 1), in: text),
              let mR = Range(m.range(at: 2), in: text),
              let sR = Range(m.range(at: 3), in: text),
              let h = Double(text[hR]), let min = Double(text[mR]), let s = Double(text[sR])
        else { return nil }
        return h * 3600 + min * 60 + s
    }

    /// Thread-safe holder shared by the stdout/stderr readability handlers.
    private final class ProgressState: @unchecked Sendable {
        private let lock = NSLock()
        private var _duration: Double?
        private var _error = ""
        var duration: Double? { lock.lock(); defer { lock.unlock() }; return _duration }
        var errorText: String { lock.lock(); defer { lock.unlock() }; return _error }
        func setDurationIfNeeded(_ d: Double) { lock.lock(); if _duration == nil { _duration = d }; lock.unlock() }
        func appendError(_ s: String) { lock.lock(); _error += s; lock.unlock() }
    }
    #endif
}
