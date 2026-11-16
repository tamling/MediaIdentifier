import Foundation

/// Finds the programs that fetch a video from a URL.
///
/// Absolute paths only: Mediafin may run as a service whose `PATH` is
/// whatever the unit inherited,
/// and a service that executes the first `yt-dlp` it happens to find is a
/// service that can be made to execute something else.
public struct DownloadTools: Sendable, Equatable {
    public let ytDlp: String?
    public let ffmpeg: String?

    public init(ytDlp: String?, ffmpeg: String?) {
        self.ytDlp = ytDlp
        self.ffmpeg = ffmpeg
    }

    /// The usual locations for yt-dlp. `/usr/local/bin` and `~/.local/bin`
    /// matter more here than for the transfer tools: yt-dlp is updated often
    /// enough that most people install it with pip or pipx rather than from
    /// their distribution, and those put it outside `/usr/bin`.
    public static var searchPaths: [String] {
        var paths = ["/usr/local/bin", "/usr/bin", "/bin", "/opt/homebrew/bin"]
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        if !home.isEmpty { paths.append(home + "/.local/bin") }
        return paths
    }

    /// - Parameter configuredFFmpeg: the path the user set for conversion,
    ///   if any.
    ///
    /// ffmpeg is found by `FFmpegLocator` and not by the list above, so the
    /// whole program agrees about which ffmpeg it has. It did not: this
    /// looked in four directories and `FFmpegLocator` in six, in a
    /// different order — so with a snap or flatpak install the traffic
    /// light showed ffmpeg found while the download refused for want of it,
    /// and where both found one they could be different binaries. The
    /// configured path is honoured for the same reason: a user who sets
    /// ffmpeg for conversion means that ffmpeg.
    public static func locate(
        in directories: [String] = searchPaths,
        configuredFFmpeg: String? = nil,
        fileManager: FileManager = .default
    ) -> DownloadTools {
        func find(_ name: String) -> String? {
            for directory in directories {
                let path = directory + "/" + name
                if fileManager.isExecutableFile(atPath: path) { return path }
            }
            return nil
        }
        // `resolve` returns a plausible path even when nothing is there, so
        // that it can appear in a message; here it has to be nil, or
        // `missing()` would say ffmpeg was present and yt-dlp would be
        // handed a path to nothing.
        let resolved = FFmpegLocator.resolve(configured: configuredFFmpeg)
        return DownloadTools(
            ytDlp: find("yt-dlp"),
            ffmpeg: fileManager.isExecutableFile(atPath: resolved) ? resolved : nil)
    }

    /// What is missing, named so the message can say what to install.
    ///
    /// ffmpeg is required, not optional. Without it yt-dlp cannot merge a
    /// separate video and audio stream, so its format selection quietly
    /// falls back to a pre-muxed stream — a 720p file where a 1080p was
    /// available, with a warning on stderr and an exit status of 0. That is
    /// a quality regression nothing downstream can see, so it is refused up
    /// front instead.
    public func missing() -> [String] {
        var absent: [String] = []
        if ytDlp == nil { absent.append("yt-dlp") }
        if ffmpeg == nil { absent.append("ffmpeg") }
        return absent
    }
}
