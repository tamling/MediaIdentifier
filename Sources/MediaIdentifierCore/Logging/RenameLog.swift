import Foundation

/// A single logged rename operation (FR12).
public struct RenameLogEntry: Identifiable, Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case success
        case failure
        case skipped
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
    private(set) public var entries: [RenameLogEntry] = []

    /// - Parameter url: file to persist to. Defaults to Application Support.
    public init(url: URL? = nil) {
        self.url = url ?? RenameLog.defaultURL()
        load()
    }

    public func append(_ entry: RenameLogEntry) {
        queue.sync {
            entries.append(entry)
            persist()
        }
    }

    public func append(contentsOf newEntries: [RenameLogEntry]) {
        queue.sync {
            entries.append(contentsOf: newEntries)
            persist()
        }
    }

    public func clear() {
        queue.sync {
            entries.removeAll()
            persist()
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([RenameLogEntry].self, from: data) {
            entries = decoded
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(entries) else { return }
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
