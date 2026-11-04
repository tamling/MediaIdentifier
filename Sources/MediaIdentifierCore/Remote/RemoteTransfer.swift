import Foundation

/// Runs the transfer and reports how far it has got.
///
/// Both tools report progress the same way a terminal does: one line
/// overwritten with carriage returns rather than a stream of newlines. So
/// the parsing below looks for the last percentage in whatever arrived,
/// instead of splitting on "\n" and finding nothing.
public final class RemoteTransfer {

    public struct Progress: Equatable, Sendable {
        /// 0…1, or nil while the tool has not said anything useful yet.
        public let fraction: Double
        /// "12.3MB/s" as the tool printed it, if it printed one.
        public let speed: String?

        public init(fraction: Double, speed: String? = nil) {
            self.fraction = fraction
            self.speed = speed
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case toolsMissing([String])
        case failed(code: Int32, message: String)
        case cancelled

        public var description: String {
            switch self {
            case .toolsMissing(let names):
                return "Fehlende Programme: \(names.joined(separator: ", ")). "
                    + "Installieren mit: sudo apt install \(names.joined(separator: " "))"
            case let .failed(code, message):
                return message.isEmpty
                    ? "Die Übertragung schlug fehl (Code \(code))."
                    : "Die Übertragung schlug fehl (Code \(code)): \(message)"
            case .cancelled:
                return "Die Übertragung wurde abgebrochen."
            }
        }
    }

    private let tools: RemoteTools

    public init(tools: RemoteTools = .locate()) {
        self.tools = tools
    }

    /// Sends one file and returns when it has arrived.
    ///
    /// Synchronous on purpose, like the converter: the coordinator already
    /// owns a serial queue to run slow work on, and two ways of being
    /// asynchronous in one program is one too many.
    public func send(
        _ localFile: URL,
        relativePath: String,
        to target: RemoteTarget,
        password: String?,
        onStart: ((Process) -> Void)? = nil,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) throws {
        let absent = tools.missing(for: target)
        guard absent.isEmpty else { throw Failure.toolsMissing(absent) }

        let invocation: RemoteCommand.Invocation
        switch target.transport {
        case .rsync:
            invocation = try RemoteCommand.rsync(
                target, localFile: localFile, relativePath: relativePath,
                rsyncPath: tools.rsync ?? "rsync", sshPath: tools.ssh ?? "ssh",
                password: password)
        case .sftp:
            invocation = try RemoteCommand.sftp(
                target, localFile: localFile, relativePath: relativePath,
                sftpPath: tools.sftp ?? "sftp", password: password)
        }

        // sshpass is named rather than pathed by the command builder, which
        // keeps that file free of lookup logic; resolve it here.
        var executable = invocation.executable
        if executable == "sshpass" { executable = tools.sshpass ?? "sshpass" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = invocation.arguments
        if !invocation.environment.isEmpty {
            // Inherit, then add: dropping the environment would lose HOME,
            // and ssh reads ~/.ssh/known_hosts relative to it.
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in invocation.environment { environment[key] = value }
            process.environment = environment
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        let state = TransferState()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if let update = RemoteTransfer.parseProgress(text) { progress?(update) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            state.appendError(text)
        }

        onStart?(process)
        try process.run()

        // sftp reads its batch script from standard input; rsync wants the
        // pipe closed so it does not wait on a terminal that is not there.
        if let script = invocation.standardInput {
            inPipe.fileHandleForWriting.write(Data(script.utf8))
        }
        try? inPipe.fileHandleForWriting.close()

        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            throw Failure.failed(code: process.terminationStatus,
                                 message: Self.explain(state.errorText))
        }
        progress?(Progress(fraction: 1))
    }

    /// Asks the server whether a transfer would work, and says why not.
    ///
    /// Returns rather than throws: this is the traffic light, and a red lamp
    /// with a reason on it is the normal outcome, not an exception.
    public func check(_ target: RemoteTarget, password: String?) -> (ok: Bool, detail: String) {
        let absent = tools.missing(for: target)
        guard absent.isEmpty else {
            return (false, Failure.toolsMissing(absent).description)
        }
        let invocation: RemoteCommand.Invocation
        do {
            invocation = try RemoteCommand.probe(target, sshPath: tools.ssh ?? "ssh",
                                                 password: password)
        } catch {
            return (false, "\(error)")
        }

        var executable = invocation.executable
        if executable == "sshpass" { executable = tools.sshpass ?? "sshpass" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = invocation.arguments
        if !invocation.environment.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in invocation.environment { environment[key] = value }
            process.environment = environment
        }
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        // Closed at once: ssh must not sit waiting on a terminal that is not
        // there, which would hang the traffic light rather than light it.
        let inPipe = Pipe()
        process.standardInput = inPipe
        try? inPipe.fileHandleForWriting.close()

        do {
            try process.run()
        } catch {
            return (false, "\(executable) ließ sich nicht starten: \(error)")
        }
        let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let text = String(data: errorData, encoding: .utf8) ?? ""
            // ssh exits 1 when the remote command failed but the login
            // worked, which here means the path is the problem and not the
            // connection — worth saying, because the remedies differ.
            if process.terminationStatus == 1, text.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty {
                return (false, "Angemeldet, aber \(target.basePath) fehlt oder ist "
                            + "nicht beschreibbar.")
            }
            return (false, Self.explain(text))
        }
        return (true, "Angemeldet, \(target.basePath) ist beschreibbar.")
    }

    // MARK: Output

    /// The last percentage, and a transfer rate if one was printed.
    ///
    /// One read can contain several carriage-return separated updates, so
    /// the last is the current one. Returns nil rather than zero when there
    /// is no percentage: a caller showing 0% would be reporting progress
    /// that has not been measured.
    public static func parseProgress(_ text: String) -> Progress? {
        let chunks = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        for chunk in chunks.reversed() {
            guard let percent = percentage(in: chunk) else { continue }
            return Progress(fraction: min(max(percent / 100, 0), 1), speed: rate(in: chunk))
        }
        return nil
    }

    /// `45%` → 45. Scanned from the front, since both tools put the size
    /// before the percentage and the rate after it.
    static func percentage(in text: Substring) -> Double? {
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
                // Three digits is 100%; more means it is not a percentage.
                if digits.count > 3 { digits = "" }
            } else if character == "%" {
                if let value = Double(digits), value <= 100 { return value }
                digits = ""
            } else {
                digits = ""
            }
        }
        return nil
    }

    /// `12.34MB/s` as printed, or nil.
    static func rate(in text: Substring) -> String? {
        guard let slash = text.range(of: "B/s") else { return nil }
        // Walk back over the number and its unit.
        var start = slash.lowerBound
        while start > text.startIndex {
            let previous = text.index(before: start)
            let character = text[previous]
            guard character.isNumber || character == "." || "KMGTk".contains(character) else {
                break
            }
            start = previous
        }
        let value = text[start..<slash.upperBound].trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value == "B/s" ? nil : value
    }

    /// Turns the tools' own wording into something that says what to do.
    ///
    /// These three are the overwhelming majority of first-time failures, and
    /// each has a specific remedy that the raw message does not mention.
    static func explain(_ stderr: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        if lowered.contains("host key verification failed") {
            return "Der Server ist unbekannt oder sein Schlüssel hat sich geändert. "
                + "Einmal von Hand verbinden und den Fingerabdruck prüfen: "
                + "ssh BENUTZER@SERVER — danach geht es hier automatisch. " + text
        }
        if lowered.contains("permission denied") {
            return "Anmeldung abgelehnt — Benutzername, Schlüssel oder Passwort stimmen nicht. "
                + text
        }
        if lowered.contains("no such file or directory") || lowered.contains("failure") {
            return "Der Zielpfad existiert nicht oder darf nicht beschrieben werden. " + text
        }
        return text
    }

    /// Collects stderr across the reader thread.
    private final class TransferState: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func appendError(_ chunk: String) {
            lock.lock(); defer { lock.unlock() }
            // Bounded: a tool that fails in a loop must not fill memory with
            // its complaints before anyone sees the first one.
            if text.count < 8_000 { text += chunk }
        }
        var errorText: String { lock.lock(); defer { lock.unlock() }; return text }
    }
}
