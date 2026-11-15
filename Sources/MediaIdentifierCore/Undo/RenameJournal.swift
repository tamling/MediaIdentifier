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
        inFlightURL(forProcess: ProcessInfo.processInfo.processIdentifier)
    }

    /// Per process, because two Mediafins can share one configuration
    /// directory — the window and `mediafin --once` from a cron line — and
    /// one append-only file between them would interleave two batches into
    /// nonsense.
    private func inFlightURL(forProcess pid: Int32) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-in-flight-\(pid).jsonl")
    }

    /// How many transactions are kept.
    ///
    /// The history beside this file got `maximumEntries = 2_000` and
    /// coalesced writes after 2,000 appends were measured at 18 seconds and
    /// ~360 MB written to produce a 357 KB file. This file, in the same
    /// directory, written by the same `applyRenames`, holding the same kind
    /// of path data, got neither: it grew for ever and was re-encoded whole
    /// on every rename.
    ///
    /// Ten, not two thousand, because of what the grown part is for:
    /// `undoLast` reads `journal.last` and nothing else, so everything
    /// before the newest transaction is already write-only. Ten leaves room
    /// for an undo that steps back further without keeping a year of them.
    static let maximumTransactions = 10

    /// And a cap on the total moves, because one transaction can hold
    /// thousands: ten batches of 5,000 files would be a 10 MB file
    /// re-encoded on every rename.
    static let maximumMoves = 20_000

    /// The file whose lock serialises writers.
    ///
    /// A separate file, not the journal itself: `AtomicFile.write` finishes
    /// with `rename(2)`, which replaces the inode, so a lock held on the
    /// journal would protect a file that no longer exists.
    private var lockURL: URL {
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(stem).lock")
    }

    public func record(_ transaction: RenameTransaction) {
        queue.sync {
            RunLock.waiting(at: lockURL) {
                // Re-read first. This object read the file once in `init`
                // and then rewrote the whole array on every change, so a
                // window left open all day held a snapshot from startup —
                // and the next rename in it erased whatever the nightly
                // `mediafin --once` had recorded in between. Nobody noticed
                // until a restart, because undo works from memory.
                mergeFromDisk()
                transactions.append(transaction)
                sortByDate()
                trim()
                persist()
            }
        }
    }

    /// Takes in whatever another process has written since, keeping both.
    ///
    /// Called with `lock` held and on `queue`. Merged by id rather than
    /// replaced, so this process's own unwritten work is not lost either.
    private func mergeFromDisk() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let onDisk = try? decoder.decode([RenameTransaction].self, from: data)
        else { return }
        var merged = onDisk
        let known = Set(onDisk.map(\.id))
        for mine in transactions where !known.contains(mine.id) {
            merged.append(mine)
        }
        transactions = merged
    }

    /// Oldest first, so `last` is the most recent transaction whoever wrote
    /// it. Undo asks for exactly that.
    private func sortByDate() {
        transactions.sort { $0.date < $1.date }
    }

    /// Drops the oldest transactions past the caps. Called with the lock
    /// held, after sorting, before persisting.
    private func trim() {
        if transactions.count > Self.maximumTransactions {
            transactions.removeFirst(transactions.count - Self.maximumTransactions)
        }
        var moves = transactions.reduce(0) { $0 + $1.moves.count }
        // Never the last one, whatever its size: that is the one undo acts
        // on, and dropping it would be the data loss this file prevents.
        while moves > Self.maximumMoves, transactions.count > 1 {
            moves -= transactions.removeFirst().moves.count
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
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let prefix = "\(stem)-in-flight-"
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted()
        where name.hasPrefix(prefix) && name.hasSuffix(".jsonl") {
            let pidText = name.dropFirst(prefix.count).dropLast(".jsonl".count)
            // Another Mediafin that is still running owns its file: it is in
            // the middle of a batch, and taking it would both steal a record
            // it is about to write properly and delete the file it is
            // appending to.
            if let pid = Int32(pidText), pid != ProcessInfo.processInfo.processIdentifier,
               Self.processIsRunning(pid) {
                continue
            }
            recover(fileAt: directory.appendingPathComponent(name))
        }
    }

    /// Whether a process id belongs to something still running.
    ///
    /// `kill(pid, 0) == 0` is not the test. A process that exists but
    /// belongs to another user answers -1 with EPERM, and reading that as
    /// "gone" would take its in-flight record away while it is still
    /// appending to it. The CI container runs everything as root, where
    /// EPERM never happens, so this only showed up on the macOS runner —
    /// the same shape as the test that made a directory read-only and found
    /// that root ignores the mode bits.
    private static func processIsRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func recover(fileAt inFlight: URL) {
        let fileManager = FileManager.default
        guard let data = try? Data(contentsOf: inFlight),
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
        defer { try? fileManager.removeItem(at: inFlight) }
        guard let header, !moves.isEmpty else { return }
        // The batch may have finished and been recorded, and only the
        // removal of this file lost the race with the process dying.
        guard !transactions.contains(where: { $0.id == header.id }) else { return }
        queue.sync {
            RunLock.waiting(at: lockURL) {
                mergeFromDisk()
                guard !transactions.contains(where: { $0.id == header.id }) else { return }
                transactions.append(RenameTransaction(id: header.id, date: header.date,
                                                      moves: moves))
                sortByDate()
                trim()
                persist()
            }
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
            RunLock.waiting(at: lockURL) { mergeFromDisk(); sortByDate() }
            guard let last = transactions.last, last.id == id else { return false }
            RunLock.waiting(at: lockURL) {
                transactions.removeLast()
                // The same id, so a second partial undo still matches this
                // transaction rather than being refused as somebody else's.
                if !remaining.isEmpty {
                    transactions.append(RenameTransaction(id: last.id, date: last.date,
                                                          moves: remaining))
                }
                persist()
            }
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
