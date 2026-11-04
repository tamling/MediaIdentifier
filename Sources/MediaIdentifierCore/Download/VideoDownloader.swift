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
    ) throws -> URL {
        let invocation = try DownloadCommand.download(url: url, into: importDirectory,
                                                      tools: tools)

        // Fresh each run, so a path left behind by the previous one can
        // never be mistaken for this one's result.
        try? FileManager.default.createDirectory(at: invocation.stagingDirectory,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: invocation.statusFile)

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
                    ? "yt-dlp lief ohne Fehler durch, hat aber keine Datei abgelegt — "
                        + "meist heißt das, die Datei war zu groß oder zu lang."
                    : reason)
            }
            throw Failure.failed(code: process.terminationStatus, message: reason)
        }
        progress?(Progress(fraction: 1, isFinished: true))
        return arrived
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
            return "Mit dieser Adresse kann yt-dlp nichts anfangen. " + text
        }
        if lowered.contains("video unavailable") || lowered.contains("private video") {
            return "Das Video ist nicht (mehr) öffentlich abrufbar. " + text
        }
        if lowered.contains("sign in") || lowered.contains("age") && lowered.contains("confirm") {
            return "Die Seite verlangt eine Anmeldung. " + text
        }
        if lowered.contains("http error 404") {
            return "Unter dieser Adresse liegt nichts (404). " + text
        }
        if lowered.contains("name or service not known")
            || lowered.contains("failed to resolve") {
            return "Der Rechnername ließ sich nicht auflösen — Tippfehler oder kein "
                + "Netz. " + text
        }
        if lowered.contains("ffmpeg") && lowered.contains("not found") {
            return "ffmpeg fehlt, deshalb konnten Bild und Ton nicht zusammengefügt "
                + "werden: sudo apt install ffmpeg. " + text
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
