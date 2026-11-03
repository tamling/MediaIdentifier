import Foundation

/// Finds the FFmpeg binary.
///
/// The converter used to default to Homebrew's path, which only exists on an
/// Apple Silicon Mac — on Linux, and on an Intel Mac, FFmpeg could never be
/// found however it was installed. The candidates are absolute and fixed: the
/// binary is never looked up through `PATH`, so nothing in the environment can
/// point the converter at a different program.
public enum FFmpegLocator {
    /// Where FFmpeg usually lives, in the order they are tried.
    public static let candidatePaths = [
        "/usr/bin/ffmpeg",                    // most Linux distributions
        "/usr/local/bin/ffmpeg",              // manual install, Homebrew on Intel
        "/opt/homebrew/bin/ffmpeg",           // Homebrew on Apple Silicon
        "/snap/bin/ffmpeg",                   // Ubuntu snap
        "/var/lib/flatpak/exports/bin/ffmpeg",
        "/bin/ffmpeg",
    ]

    /// The first candidate that exists and can be executed, or nil.
    public static func locate(candidates: [String] = candidatePaths,
                              fileManager: FileManager = .default) -> String? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// The path to use when none was configured. Falls back to the first
    /// candidate so the error message names a plausible location rather than
    /// an empty string.
    public static var defaultPath: String {
        locate() ?? candidatePaths[0]
    }

    /// Resolves a user-supplied path, ignoring a blank one.
    public static func resolve(configured: String?) -> String {
        guard let configured = configured?.trimmingCharacters(in: .whitespacesAndNewlines),
              !configured.isEmpty else { return defaultPath }
        return configured
    }
}
