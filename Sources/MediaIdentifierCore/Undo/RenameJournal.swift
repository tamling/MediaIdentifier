import Foundation

/// A reversible batch of moves performed together (FR13).
public struct RenameTransaction: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    /// Performed moves, in the order they were applied. Undo reverses them.
    public var moves: [Move]

    public struct Move: Codable, Equatable, Sendable {
        public var from: URL
        public var to: URL
        /// Directories created while applying the move, newest last; removed on
        /// undo if empty.
        public var createdDirectories: [URL]

        public init(from: URL, to: URL, createdDirectories: [URL] = []) {
            self.from = from
            self.to = to
            self.createdDirectories = createdDirectories
        }
    }

    public init(id: UUID = UUID(), date: Date = Date(), moves: [Move]) {
        self.id = id
        self.date = date
        self.moves = moves
    }
}

/// Stores rename transactions so they can be undone, even across launches
/// (FR13).
public final class RenameJournal: @unchecked Sendable {
    /// Where it is. Readable so a caller can name it in a message and a
    /// test can check its permissions — it is a path, not a secret, and the
    /// file's own mode is what protects the contents.
    public let url: URL
    private let queue = DispatchQueue(label: "MediaIdentifier.RenameJournal")
    private(set) public var transactions: [RenameTransaction] = []

    /// The batch that is running right now, if one is.
    private var inFlight: InFlight?
    private var inFlightHandle: FileHandle?

    private struct InFlight {
        var id: UUID
        var date: Date
        var moves: [RenameTransaction.Move]
    }

    private struct InFlightHeader: Codable {
        var id: UUID
        var date: Date
    }

    public init(url: URL? = nil) {
        self.url = url ?? RenameJournal.defaultURL()
        load()
        recoverInterruptedBatch()
    }

    /// Where a running batch appends to, beside the journal itself.
    ///
    /// Separate from the journal because the journal is rewritten whole on
    /// every change: writing it through after each move would cost O(n²)
    /// bytes across a batch of n files, which is the exact shape this
    /// project has already had to take out of the history append. This file
    /// is append-only — one move per line, one `write(2)` each, nothing
    /// re-encoded — so the cost per file does not depend on how many files
    /// came before it.
    public var inFlightURL: URL {
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-in-flight.jsonl")
    }

    public func record(_ transaction: RenameTransaction) {
        queue.sync {
            transactions.append(transaction)
            persist()
        }
    }

    // MARK: A batch that is still running

    /// Opens the record of a batch about to start.
    ///
    /// Until this existed the journal was written once, after the last file
    /// of a batch. For the whole duration of a run the files were already in
    /// the library and the undo journal was empty, so a process that died
    /// part way through — the window closed on an hour-long batch over a NAS
    /// mount, `systemctl stop` on the watcher — left every moved file with
    /// no record at all. Worse than nothing: the next launch's Undo reached
    /// past them to an *earlier* batch, pulled a correctly filed film back
    /// out of the library, and reported success.
    public func beginBatch(id: UUID, date: Date) {
        queue.sync {
            closeInFlight()
            inFlight = InFlight(id: id, date: date, moves: [])
            let fileManager = FileManager.default
            let directory = inFlightURL.deletingLastPathComponent()
            try? fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try? fileManager.removeItem(at: inFlightURL)
            // 0600 from the start, like the journal: these lines are every
            // path of the user's media library.
            guard fileManager.createFile(
                atPath: inFlightURL.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else { return }
            inFlightHandle = try? FileHandle(forWritingTo: inFlightURL)
            writeInFlightLine(InFlightHeader(id: id, date: date))
        }
    }

    /// Records one move that has already happened.
    public func appendToBatch(_ move: RenameTransaction.Move) {
        queue.sync {
            guard inFlight != nil else { return }
            inFlight?.moves.append(move)
            writeInFlightLine(move)
        }
    }

    /// Closes the batch. The durable record is the journal proper by now,
    /// so the in-flight file is removed — unless the journal's own write
    /// failed, in which case this file is the only record left and stays.
    public func endBatch() {
        queue.sync {
            let hadMoves = !(inFlight?.moves.isEmpty ?? true)
            closeInFlight()
            inFlight = nil
            if hadMoves, _lastWriteFailure != nil { return }
            try? FileManager.default.removeItem(at: inFlightURL)
        }
    }

    private func closeInFlight() {
        try? inFlightHandle?.close()
        inFlightHandle = nil
    }

    private func writeInFlightLine<T: Encodable>(_ value: T) {
        guard let handle = inFlightHandle else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(value) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }

    /// Folds a batch that never finished into the journal, at startup.
    ///
    /// A line that was half written when the process died does not decode
    /// and is skipped; the moves before it are real and are kept.
    private func recoverInterruptedBatch() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: inFlightURL.path),
              let data = try? Data(contentsOf: inFlightURL),
              let text = String(data: data, encoding: .utf8)
        else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var header: InFlightHeader?
        var moves: [RenameTransaction.Move] = []
        for line in text.split(separator: "\n") {
            guard let lineData = String(line).data(using: .utf8) else { continue }
            if header == nil {
                header = try? decoder.decode(InFlightHeader.self, from: lineData)
                continue
            }
            if let move = try? decoder.decode(RenameTransaction.Move.self,
                                              from: lineData) {
                moves.append(move)
            }
        }
        defer { try? fileManager.removeItem(at: inFlightURL) }
        guard let header, !moves.isEmpty else { return }
        // The batch may have finished and been recorded, and only the
        // removal of this file lost the race with the process dying.
        guard !transactions.contains(where: { $0.id == header.id }) else { return }
        queue.sync {
            transactions.append(RenameTransaction(id: header.id, date: header.date,
                                                  moves: moves))
            persist()
        }
    }

    /// Whether there is anything to reverse.
    ///
    /// Deliberately not what the Undo button is gated on. Greying the button
    /// out would be a worse answer than the engine's own: press it with an
    /// empty journal and the window says "Es gab nichts rückgängig zu
    /// machen", which is readable, whereas a disabled button says "Undo is
    /// broken". The same reasoning is written out at the scan button, which
    /// stays live without an import folder for exactly this reason.
    public var canUndo: Bool { !transactions.isEmpty }

    /// The transaction an undo would reverse, left in place.
    ///
    /// There used to be a `popLast()` here, and the executor called it
    /// before touching a single file. An undo that then failed — the file
    /// gone, the volume unmounted, the old name taken — had already lost the
    /// only record of what still needed moving back, and a second press had
    /// nothing to work from. A partial undo was worse: the files that came
    /// back were restored, the rest stayed in the library, and nothing
    /// anywhere remembered them.
    ///
    /// So the work is done first and `finishUndo` is called afterwards. That
    /// method is the only way to remove a transaction, which is why
    /// `popLast` is gone rather than merely unused.
    public var last: RenameTransaction? { queue.sync { transactions.last } }

    /// Records the result of an undo: drops the transaction, or keeps what
    /// could not be moved back so a second press can carry on.
    ///
    /// - Parameters:
    ///   - id: the transaction the caller worked from. If the journal has
    ///     moved on since, nothing is changed — whatever is last now belongs
    ///     to somebody else and must not be overwritten.
    ///   - remaining: the moves still to undo, in their original order.
    /// - Returns: whether it acted.
    @discardableResult
    public func finishUndo(of id: UUID,
                           leaving remaining: [RenameTransaction.Move]) -> Bool {
        queue.sync {
            guard let last = transactions.last, last.id == id else { return false }
            transactions.removeLast()
            // The same id, so a second partial undo still matches this
            // transaction rather than being refused as somebody else's.
            if !remaining.isEmpty {
                transactions.append(RenameTransaction(id: last.id, date: last.date,
                                                      moves: remaining))
            }
            persist()
            return true
        }
    }

    /// Forgets all recorded transactions and removes the on-disk journal file.
    /// Undo is no longer possible afterwards.
    public func clear() {
        queue.sync {
            transactions.removeAll()
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([RenameTransaction].self, from: data) {
            transactions = decoded
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(transactions) else { return }
        // Through AtomicFile, like settings.json and secrets.json: it
        // creates the directory at 0700 and the file at the mode given,
        // with the contents never briefly readable by anyone else.
        //
        // This used to be a bare `data.write`, with no mode and a directory
        // created at 0755. Whichever of the four files was written first
        // decided the directory's mode, so a first run that renamed a
        // dropped file before any settings were saved left
        // ~/.config/mediafin world-readable with this file at 0644 — and
        // this file holds every path of the user's media library.
        do {
            try AtomicFile.write(data, to: url, permissions: 0o600)
            _lastWriteFailure = nil
        } catch {
            // Kept rather than swallowed. The whole point of this file is to
            // survive a restart, and a write that cannot happen means the
            // offer to undo is a promise that will not be kept.
            _lastWriteFailure = url.path
        }
    }

    /// The path of this file if the last write to it failed, else nil.
    ///
    /// Read once per session by the coordinator, which says so in the
    /// footer. It used to be `try?` and therefore invisible: a full disk or
    /// a read-only directory left the in-memory state claiming to be
    /// recorded while the disk knew nothing.
    ///
    /// Through the queue, like every other read here: `persist` runs on it,
    /// and a caller on another thread reading the raw field would be a data
    /// race on a String — a crash rather than a stale answer.
    public var lastWriteFailure: String? { queue.sync { _lastWriteFailure } }
    private var _lastWriteFailure: String?

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MediaIdentifier", isDirectory: true)
            .appendingPathComponent("undo-journal.json")
    }
}
