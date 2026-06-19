import Foundation

/// Options for transcoding a media file (FR16). This is the scaffold for the
/// planned conversion feature; the argument-building logic is implemented and
/// unit-testable, while actual execution is gated behind `FFmpegConverter`.
public struct ConversionOptions: Codable, Sendable, Equatable {
    public enum VideoCodec: String, Codable, Sendable, CaseIterable {
        case h264, h265, copy
    }

    public var videoCodec: VideoCodec
    /// Use Apple Silicon VideoToolbox hardware encoders (FR17).
    public var useHardwareAcceleration: Bool
    /// Constant quality factor (lower = better). Maps to -crf / -q:v.
    public var quality: Int
    /// Target height, e.g. 1080. `nil` keeps the source resolution.
    public var targetHeight: Int?
    /// Audio codec, e.g. "aac". `nil` copies audio.
    public var audioCodec: String?
    /// Keep only the first audio stream (FR16: remove unneeded audio tracks).
    public var keepOnlyFirstAudio: Bool
    /// Drop all subtitle streams (FR16: remove unneeded subtitle tracks).
    public var stripSubtitles: Bool

    public init(
        videoCodec: VideoCodec = .h265,
        useHardwareAcceleration: Bool = true,
        quality: Int = 23,
        targetHeight: Int? = nil,
        audioCodec: String? = nil,
        keepOnlyFirstAudio: Bool = false,
        stripSubtitles: Bool = false
    ) {
        self.videoCodec = videoCodec
        self.useHardwareAcceleration = useHardwareAcceleration
        self.quality = quality
        self.targetHeight = targetHeight
        self.audioCodec = audioCodec
        self.keepOnlyFirstAudio = keepOnlyFirstAudio
        self.stripSubtitles = stripSubtitles
    }
}

/// Builds the FFmpeg argument list for a conversion (FR16, FR17). Kept pure and
/// separate from process execution so it can be tested without FFmpeg installed.
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

        // Video codec (FR16) with optional VideoToolbox hardware path (FR17).
        switch options.videoCodec {
        case .copy:
            args += ["-c:v", "copy"]
        case .h264:
            if options.useHardwareAcceleration {
                args += ["-c:v", "h264_videotoolbox", "-q:v", String(options.quality)]
            } else {
                args += ["-c:v", "libx264", "-crf", String(options.quality)]
            }
        case .h265:
            if options.useHardwareAcceleration {
                args += ["-c:v", "hevc_videotoolbox", "-q:v", String(options.quality), "-tag:v", "hvc1"]
            } else {
                args += ["-c:v", "libx265", "-crf", String(options.quality), "-tag:v", "hvc1"]
            }
        }

        // Scaling (FR16: resolution change).
        if let height = options.targetHeight {
            args += ["-vf", "scale=-2:\(height)"]
        }

        // Audio (FR16: audio conversion).
        if let audioCodec = options.audioCodec {
            args += ["-c:a", audioCodec]
        } else {
            args += ["-c:a", "copy"]
        }

        args.append(output.path)
        return args
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
    /// Runs a conversion synchronously. Intended to be called off the main thread.
    public func convert(input: URL, output: URL, options: ConversionOptions) throws {
        guard isAvailable else { throw ConverterError.ffmpegNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = FFmpegArgumentBuilder.arguments(input: input, output: output, options: options)

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            throw ConverterError.conversionFailed(code: process.terminationStatus, message: message)
        }
    }
    #endif
}
