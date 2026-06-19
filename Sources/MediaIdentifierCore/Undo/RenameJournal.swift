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
    private let url: URL
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

    /// Pops the most recent transaction for undoing.
    public func popLast() -> RenameTransaction? {
        queue.sync {
            guard !transactions.isEmpty else { return nil }
            let last = transactions.removeLast()
            persist()
            return last
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
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MediaIdentifier", isDirectory: true)
            .appendingPathComponent("undo-journal.json")
    }
}
