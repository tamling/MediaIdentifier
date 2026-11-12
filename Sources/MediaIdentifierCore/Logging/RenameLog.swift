import Foundation

/// A single logged rename operation (FR12).
public struct RenameLogEntry: Identifiable, Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case success
        case failure
        case skipped
        /// A re-encode rather than a rename, so the history can say which it
        /// was instead of labelling a conversion "renamed".
        case converted
        /// Sent to a server by a version of Mediafin that could do that.
        ///
        /// Nothing writes this any more — the sending feature is gone — but
        /// the case stays: removing it would make an existing
        /// `rename-log.json` fail to decode and take the user's whole
        /// history with it.
        case sent
        /// Fetched from a URL into the import folder.
        case downloaded
    }

    public var id: UUID
    public var oldName: String
    public var newName: String
    public var date: Date
    public var status: Status
    public var errorDescription: String?

    public init(
        id: UUID = UUID(),
        oldName: String,
        newName: String,
        date: Date = Date(),
        status: Status,
        errorDescription: String? = nil
    ) {
        self.id = id
        self.oldName = oldName
        self.newName = newName
        self.date = date
        self.status = status
        self.errorDescription = errorDescription
    }
}

/// Persists rename log entries as a JSON file and keeps an in-memory copy
/// (FR12). Thread-safe for appends.
public final class RenameLog: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "MediaIdentifier.RenameLog")
    /// Only ever touched inside `queue`. Reads go through `entries`.
    private var _entries: [RenameLogEntry] = []

    /// A snapshot, taken on the queue.
    ///
    /// Reads used to go straight at the array while appends ran on the
    /// queue, from another thread: the window reads it twice a second
    /// while a run appends once per file. That is a
    /// data race on an array's storage, which is a crash rather than a
    /// stale number.
    public var entries: [RenameLogEntry] { queue.sync { _entries } }

    /// - Parameter url: file to persist to. Defaults to Application Support.
    public init(url: URL? = nil) {
        self.url = url ?? RenameLog.defaultURL()
        load()
    }

    public func append(_ entry: RenameLogEntry) {
        queue.sync {
            // _entries, not entries: we are already on the queue, and the
            // accessor would sync onto it again and deadlock.
            _entries.append(entry)
            persist()
        }
    }

    public func append(contentsOf newEntries: [RenameLogEntry]) {
        queue.sync {
            _entries.append(contentsOf: newEntries)
            persist()
        }
    }

    public func clear() {
        queue.sync {
            _entries.removeAll()
            persist()
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([RenameLogEntry].self, from: data) {
            // Called from init, before anything else can see the log.
            _entries = decoded
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(_entries) else { return }
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
            .appendingPathComponent("rename-log.json")
    }
}
