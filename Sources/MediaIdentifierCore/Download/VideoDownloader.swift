import Foundation

/// Runs yt-dlp and reports how far it has got.
///
/// Synchronous, like the converter and the transfer: the coordinator already
/// owns a serial queue for slow work.
public final class VideoDownloader {

    public struct Progress: Equatable, Sendable {
        /// 0…1, or nil when the total size is unknown — which is the normal
        /// case for a chunked stream. nil rather than 0, because a caller
        /// showing 0 % is reporting progress that was never measured.
        public let fraction: Double?
        public let downloadedBytes: Int64?
        public let totalBytes: Int64?
        /// Bytes per second, as yt-dlp measured it.
        public let bytesPerSecond: Double?
        public let secondsRemaining: Int?
        public let isFinished: Bool

        public init(fraction: Double?, downloadedBytes: Int64? = nil,
                    totalBytes: Int64? = nil, bytesPerSecond: Double? = nil,
                    secondsRemaining: Int? = nil, isFinished: Bool = false) {
            self.fraction = fraction
            self.downloadedBytes = downloadedBytes
            self.totalBytes = totalBytes
            self.bytesPerSecond = bytesPerSecond
            self.secondsRemaining = secondsRemaining
            self.isFinished = isFinished
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case toolsMissing([String])
        case failed(code: Int32, message: String)
        case nothingArrived(String)

        public var description: String {
            switch self {
            case .toolsMissing(let names):
                return "Fehlende Programme: \(names.joined(separator: ", ")). "
                    + "Installieren mit: sudo apt install \(names.joined(separator: " "))"
            case let .failed(code, message):
                return message.isEmpty
                    ? "Der Download schlug fehl (Code \(code))."
                    : "Der Download schlug fehl (Code \(code)): \(message)"
            case .nothingArrived(let detail):
                return detail
            }
        }
    }

    /// What one run produced.
    public struct Arrival: Equatable, Sendable {
        public let file: URL
        /// True when the file was already in the import folder and yt-dlp
        /// only pointed at it.
        ///
        /// `--no-overwrites` makes that a silent success: yt-dlp exits 0 and
        /// prints the existing path, so the path file looks exactly as it
        /// does after a real download and the interface said "Geladen:" for
        /// a file it had not fetched. Worth telling apart — if the page
        /// behind the URL has changed, "Geladen" is simply false.
        public let wasAlreadyThere: Bool

        public init(file: URL, wasAlreadyThere: Bool) {
            self.file = file
            self.wasAlreadyThere = wasAlreadyThere
        }
    }

    /// How long a partial file is kept for a possible resume.
    ///
    /// yt-dlp continues an interrupted download from the `.part` in the
    /// staging folder, which is worth keeping for a while — but only for a
    /// while: nothing else ever deleted them, so a few cancelled downloads
    /// of large files sat in the import folder for good, invisible because
    /// the folder is hidden.
    public static let partialLifetime: TimeInterval = 7 * 24 * 3600

    private let tools: DownloadTools

    public init(tools: DownloadTools = .locate()) {
        self.tools = tools
    }

    /// Fetches one URL into the import folder and returns where it landed.
    public func download(
        _ url: String,
        into importDirectory: URL,
        onStart: ((Process) -> Void)? = nil,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) throws -> Arrival {
        let invocation = try DownloadCommand.download(url: url, into: importDirectory,
                                                      tools: tools)

        // What is in the folder before the run, so "already there" can be
        // told from "arrived" without reading yt-dlp's wording.
        let before = Set((try? FileManager.default.contentsOfDirectory(
            atPath: importDirectory.path)) ?? [])

        // Fresh each run, so a path left behind by the previous one can
        // never be mistaken for this one's result.
        try? FileManager.default.createDirectory(at: invocation.stagingDirectory,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: invocation.statusFile)
        Self.sweepStaging(invocation.stagingDirectory, keeping: invocation.statusFile)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        let state = DownloadState()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if let update = VideoDownloader.parseProgress(text) { progress?(update) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            state.appendError(text)
        }

        // run() before publishing the Process: a cancel arriving in between
        // would call terminate() on something that was never launched.
        try process.run()
        onStart?(process)
        try? inPipe.fileHandleForWriting.close()

        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        // The exit status is NOT the success test. A refusal by
        // --max-filesize or by the match filter exits 0 and writes nothing;
        // the proof that something arrived is the path file. Measured
        // against the real binary, both ways.
        let arrived = Self.arrivedFile(at: invocation.statusFile)
        guard let arrived else {
            let reason = Self.explain(state.errorText)
            if process.terminationStatus == 0 {
                throw Failure.nothingArrived(reason.isEmpty
                    ? Text.s(
                        "yt-dlp lief ohne Fehler durch, hat aber keine Datei abgelegt — "
                            + "meist heißt das, die Datei war zu groß oder zu lang.",
                        "yt-dlp finished without an error but left no file — usually "
                            + "that means the file was too large or too long.")
                    : reason)
            }
            throw Failure.failed(code: process.terminationStatus, message: reason)
        }
        progress?(Progress(fraction: 1, isFinished: true))
        // This run's own leftovers go at once; everything else waits for the
        // age check, because it may be a partial somebody still wants.
        Self.sweepLeftovers(of: arrived, in: invocation.stagingDirectory)
        return Arrival(file: arrived,
                       wasAlreadyThere: before.contains(arrived.lastPathComponent))
    }

    /// Deletes stale leftovers from the staging folder.
    ///
    /// - Parameters:
    ///   - keeping: the path file, which this run is about to read.
    ///   - olderThan: how old a file has to be to go. The default keeps a
    ///     week, so an interrupted download can still be resumed; zero
    ///     clears everything, which is what a finished run wants.
    ///
    /// Age-based rather than "delete the lot", because yt-dlp resumes from
    /// a `.part` and throwing one away silently turns a cancelled download
    /// of twenty gigabytes into twenty gigabytes to fetch again.
    static func sweepStaging(_ staging: URL, keeping keep: URL,
                             olderThan age: TimeInterval = VideoDownloader.partialLifetime,
                             now: Date = Date(),
                             fileManager: FileManager = .default) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: staging.path) else {
            return
        }
        for name in names where name != keep.lastPathComponent {
            let url = staging.appendingPathComponent(name)
            // No modification date is not a reason to delete something that
            // might still be wanted, so one of those is left to the next
            // pass — where it will still have no date, and still be left.
            // Rare enough to prefer over deleting a file we know nothing
            // about.
            guard let modified = (try? fileManager
                .attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
                continue
            }
            if now.timeIntervalSince(modified) >= age {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Removes what this run left in staging, by name.
    ///
    /// yt-dlp names every temporary file after the output template, so they
    /// all begin with the final file's stem: "ID_Title.f399.mp4.part",
    /// "ID_Title.f140.m4a". Matching on that rather than clearing the folder
    /// means a partial from a download the user cancelled and may resume is
    /// not destroyed by an unrelated download succeeding.
    static func sweepLeftovers(of arrived: URL, in staging: URL,
                               fileManager: FileManager = .default) {
        let stem = arrived.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty,
              let names = try? fileManager.contentsOfDirectory(atPath: staging.path) else {
            return
        }
        for name in names where name.hasPrefix(stem) {
            try? fileManager.removeItem(at: staging.appendingPathComponent(name))
        }
    }

    /// The path yt-dlp reported, if it reported one and it is really there.
    static func arrivedFile(at statusFile: URL) -> URL? {
        guard let text = try? String(contentsOf: statusFile, encoding: .utf8) else { return nil }
        // One path per line; the last non-empty one is this run's.
        let path = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let path, !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: Output

    /// The last progress record in whatever arrived.
    ///
    /// yt-dlp's ordinary chatter shares this stream — `--print-to-file` does
    /// not imply `--quiet` the way `--print` does — so a line counts only if
    /// it carries the marker. Reading unsupported output is what the sftp
    /// parser did wrong.
    public static func parseProgress(_ text: String) -> Progress? {
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        for line in lines.reversed() {
            guard let marker = line.range(of: DownloadCommand.progressMarker + "\t") else {
                continue
            }
            let fields = line[marker.upperBound...].split(separator: "\t",
                                                          omittingEmptySubsequences: false)
            guard fields.count >= 5 else { continue }

            // Every numeric field can be "NA": the total is unknown without
            // a Content-Length, the ETA is absent on the finished record,
            // and on an already-downloaded file even the byte count is.
            func number(_ index: Int) -> Double? {
                let value = fields[index].trimmingCharacters(in: .whitespaces)
                return value == "NA" ? nil : Double(value)
            }
            let status = fields[0].trimmingCharacters(in: .whitespaces)
            let downloaded = number(1)
            let total = number(2)
            let speed = number(3)
            let eta = number(4)

            var fraction: Double?
            if let downloaded, let total, total > 0 {
                fraction = min(max(downloaded / total, 0), 1)
            }
            return Progress(
                fraction: status == "finished" ? 1 : fraction,
                downloadedBytes: downloaded.map { Int64($0) },
                totalBytes: total.map { Int64($0) },
                bytesPerSecond: speed,
                secondsRemaining: eta.map { Int($0) },
                isFinished: status == "finished"
            )
        }
        return nil
    }

    /// Turns yt-dlp's wording into something that says what to do.
    static func explain(_ stderr: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        if lowered.contains("unsupported url") || lowered.contains("is not a valid url") {
            return Text.s("Mit dieser Adresse kann yt-dlp nichts anfangen. ",
                          "yt-dlp cannot do anything with this address. ") + text
        }
        if lowered.contains("video unavailable") || lowered.contains("private video") {
            return Text.s("Das Video ist nicht (mehr) öffentlich abrufbar. ",
                          "The video is not (or no longer) publicly available. ") + text
        }
        if lowered.contains("sign in") || lowered.contains("age") && lowered.contains("confirm") {
            return Text.s("Die Seite verlangt eine Anmeldung. ",
                          "The site demands a sign-in. ") + text
        }
        if lowered.contains("http error 404") {
            return Text.s("Unter dieser Adresse liegt nichts (404). ",
                          "There is nothing at this address (404). ") + text
        }
        if lowered.contains("name or service not known")
            || lowered.contains("failed to resolve") {
            return Text.s(
                "Der Rechnername ließ sich nicht auflösen — Tippfehler oder kein Netz. ",
                "The host name could not be resolved — a typo, or no network. ") + text
        }
        if lowered.contains("ffmpeg") && lowered.contains("not found") {
            return Text.s(
                "ffmpeg fehlt, deshalb konnten Bild und Ton nicht zusammengefügt werden: ",
                "ffmpeg is missing, so video and audio could not be merged: ")
                + "sudo apt install ffmpeg. " + text
        }
        return text
    }

    /// Collects stderr across the reader thread.
    private final class DownloadState: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func appendError(_ chunk: String) {
            lock.lock(); defer { lock.unlock() }
            if text.count < 8_000 { text += chunk }
        }
        var errorText: String { lock.lock(); defer { lock.unlock() }; return text }
    }
}
