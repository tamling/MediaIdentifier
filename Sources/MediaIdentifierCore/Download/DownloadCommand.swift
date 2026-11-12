import Foundation

/// Builds the command line that fetches one video.
///
/// Pure: it produces an executable path and an argument array and runs
/// nothing, so every decision below can be tested without a network. The decisions are where the damage would be.
///
/// Every flag here was checked against a real yt-dlp (2026.10.26) serving a
/// real file over HTTP, not taken from its documentation. Four things that
/// the documentation does not say, and that each cost a measurement:
///
///  - `--print` implies `--quiet`, and `--quiet` turns progress off. The
///    obvious command — a progress template plus `--print` for the filename
///    — therefore emits no progress at all and discards the template in
///    silence. `--progress` undoes it. This is the same shape as the sftp
///    bug, where `-b` set `BatchMode=yes` behind our backs.
///  - `--match-filters 'duration<14400'` rejects every direct link, because
///    the generic extractor reports no duration and the filter fails safe.
///    The `?` in `duration<?14400` is what makes it mean "if it is known".
///  - `--max-downloads 1` makes a perfectly good download exit 101.
///  - An exit status of 0 does not mean a file arrived: a refusal by
///    `--max-filesize` or by the match filter also exits 0. The proof that
///    something arrived is the path file, which is why there is one.
public enum DownloadCommand {

    public struct Invocation: Equatable, Sendable {
        public let executable: String
        public let arguments: [String]
        /// Where yt-dlp will write the final path, after any merge and move.
        public let statusFile: URL
        /// Where partial files live while they are being written.
        public let stagingDirectory: URL

        public init(executable: String, arguments: [String],
                    statusFile: URL, stagingDirectory: URL) {
            self.executable = executable
            self.arguments = arguments
            self.statusFile = statusFile
            self.stagingDirectory = stagingDirectory
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case toolsMissing([String])
        case notAWebAddress(String)
        case noImportFolder
        case unsafeInput(String)

        public var description: String {
            switch self {
            case .toolsMissing(let names):
                return "Fehlende Programme: \(names.joined(separator: ", ")). "
                    + "Installieren mit: sudo apt install \(names.joined(separator: " "))"
            case .notAWebAddress(let scheme):
                return scheme.isEmpty
                    ? "Das ist keine Web-Adresse. Erwartet wird http:// oder https://."
                    : "Nur http:// und https:// werden geladen, nicht \(scheme)://."
            case .noImportFolder:
                return "Der Importordner fehlt oder ist nicht erreichbar."
            case .unsafeInput(let what):
                return "Nicht ladbar: \(what)"
            }
        }
    }

    /// The folder partial files live in while they are being written.
    ///
    /// Inside the import folder so the final move is a rename on the same
    /// filesystem, and dot-prefixed so neither `MediaScanner` nor
    /// `WatchFolderScanner` sees it — both skip hidden files. Without this
    /// a download in progress would leave a growing `.part`, and a merge
    /// would leave two separate stream files, in the folder being scanned.
    public static let stagingFolderName = ".mediafin-incoming"

    /// The marker every progress line carries.
    ///
    /// yt-dlp's own chatter shares the stream with the template's output —
    /// `--print-to-file` does not imply `--quiet` the way `--print` does —
    /// so lines are recognised by this and never by their position.
    public static let progressMarker = "MFPROG"

    /// Accepts only what can be fetched over the web.
    ///
    /// yt-dlp installs handlers for `data:` and `ftp:` unconditionally and
    /// refuses `file:` only because `--enable-file-urls` is never passed.
    /// Checking here rather than relying on that means the rule is ours,
    /// is testable without a network, and says what it refused.
    public static func validatedURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.notAWebAddress("") }
        guard !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else {
            throw Failure.unsafeInput(Text.s(
                "Die Adresse enthält ein Steuerzeichen.",
                "The address contains a control character."))
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            throw Failure.notAWebAddress("")
        }
        guard scheme == "http" || scheme == "https" else {
            throw Failure.notAWebAddress(scheme)
        }
        guard let host = components.host, !host.isEmpty else {
            throw Failure.notAWebAddress("")
        }
        return trimmed
    }

    public static func download(url rawURL: String,
                                into importDirectory: URL,
                                tools: DownloadTools,
                                fileManager: FileManager = .default) throws -> Invocation {
        let absent = tools.missing()
        guard absent.isEmpty else { throw Failure.toolsMissing(absent) }
        guard let ytDlp = tools.ytDlp, let ffmpeg = tools.ffmpeg else {
            throw Failure.toolsMissing(absent)
        }
        // Not "is it absolute": URL(fileURLWithPath:) absolutises anything
        // it is given, so that check could never fail and a test caught it
        // as vacuous. Whether the folder is actually there can fail, and is
        // the case that matters — a library path on a drive that is no
        // longer mounted.
        var isDirectory: ObjCBool = false
        guard !importDirectory.path.isEmpty,
              fileManager.fileExists(atPath: importDirectory.path,
                                     isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw Failure.noImportFolder
        }
        let url = try validatedURL(rawURL)

        let staging = importDirectory.appendingPathComponent(stagingFolderName)
        let statusFile = staging.appendingPathComponent("last-download-path.txt")

        var arguments = [
            // Nothing on disk may give this process instructions. yt-dlp
            // reads ~/.config/yt-dlp/config, /etc/yt-dlp.conf and — because
            // -P home: sets the "portable" location — a yt-dlp.conf sitting
            // in the import folder itself. That last one is reachable by
            // anything that can write a file into the download folder, and
            // a config file may carry --exec, which runs through a shell.
            // Demonstrated against the real binary, and stopped by this.
            "--ignore-config",
            // --ignore-config deliberately does not cover --config-locations.
            "--no-config-locations",
            // Plugins load from ~/.yt-dlp/plugins and /etc/yt-dlp/plugins by
            // default. That is arbitrary Python.
            "--no-plugin-dirs",

            // One click must not become forty gigabytes.
            "--no-playlist",
            "--playlist-items", "1",
            // Bites on a direct link, where Content-Length is known.
            "--max-filesize", "20G",
            // Bites on HLS and DASH, where the manifest knows the duration
            // but Content-Length does not exist. The "?" means "when it is
            // known": without it every direct link is refused, because the
            // generic extractor reports no duration and the filter fails
            // safe. Measured — the version without "?" downloads nothing
            // and exits 0.
            "--match-filters", "duration<?14400 & !is_live",
            "--retries", "3",
            // A server that accepts and then stalls must not hang the
            // coordinator's queue for ever.
            "--socket-timeout", "30",

            // Naming. The template is flat — no "/" after any field — so a
            // site whose title is ".." cannot climb out of the folder:
            // sanitize_filename neutralises a slash inside a component but
            // a field used as a directory is a different matter.
            "--restrict-filenames",
            "--no-overwrites",
            "--no-mtime",

            // Progress, machine-readable. See the note above about
            // --progress: without it there is none.
            "--newline",
            "--progress",
            "--no-colors",
            "--progress-delta", "0.5",
            // With more than one progress line active, yt-dlp prefixes each
            // with "1: ", "2: ". The parser keys on the marker rather than
            // on the start of the line, but one stream keeps it simple.
            "--concurrent-fragments", "1",
            "--progress-template", progressTemplate,

            // The finished path, into a file so it never races the progress
            // lines on stdout. "after_move:" is required: a bare
            // "--print filepath" defaults to WHEN=video, which implies
            // --simulate and downloads nothing.
            "--print-to-file", "after_move:filepath", statusFile.path,

            "-P", "home:" + importDirectory.path,
            "-P", "temp:" + staging.path,
            "-o", "%(id)s_%(title).150B.%(ext)s",

            "--ffmpeg-location", ffmpeg,
            "--merge-output-format", "mkv",
            "-f", "bv*+ba/b",
        ]
        // Everything of ours is before this. yt-dlp handles "--" in both of
        // its parsing paths, so a URL beginning with a dash is a URL and
        // not an option.
        arguments += ["--", url]

        return Invocation(executable: ytDlp, arguments: arguments,
                          statusFile: statusFile, stagingDirectory: staging)
    }

    /// Raw fields only. The pre-rendered `_percent_str` and `_speed_str` are
    /// width-padded and conditionally coloured; these are not. Tab-separated
    /// because no yt-dlp status value contains a tab.
    static let progressTemplate =
        "download:\(progressMarker)\t%(progress.status)s\t%(progress.downloaded_bytes)s\t"
        + "%(progress.total_bytes)s\t%(progress.speed)s\t%(progress.eta)s"
}
