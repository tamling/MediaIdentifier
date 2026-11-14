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

    public init(url: URL? = nil) {
        self.url = url ?? RenameJournal.defaultURL()
        load()
    }

    public func record(_ transaction: RenameTransaction) {
        queue.sync {
            transactions.append(transaction)
            persist()
        }
    }

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
