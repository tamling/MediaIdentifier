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
        /// Moved back by an undo.
        ///
        /// Its own case because the history's word for `.success` is
        /// "umbenannt" and the window's counter is the number of `.success`
        /// entries: undoing eight files made it say sixteen were renamed.
        /// It also used to carry the string "undo" in `errorDescription`,
        /// which is a field for errors.
        case undone
        /// Removed rather than renamed: the release `.nfo`, which Jellyfin
        /// would otherwise read as its own metadata sidecar. Its own case
        /// because the history must not report a deletion as a rename, and
        /// because undo cannot reverse it.
        case deleted
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
    /// Where it is. Readable so a caller can name it in a message and a
    /// test can check its permissions — it is a path, not a secret, and the
    /// file's own mode is what protects the contents.
    public let url: URL

    /// How many entries are kept.
    ///
    /// It used to be every entry ever written, and every append rewrote the
    /// whole file — so the program got measurably slower the longer it was
    /// used, and a big run was quadratic in bytes written. Measured: 2,000
    /// appends took 18.0 seconds for a 357 KB file, which is roughly 360 MB
    /// written to produce 357 KB.
    ///
    /// Two thousand is a history somebody might actually read. The older
    /// entries are not an archive anybody has ever asked for; they were the
    /// absence of a decision.
    public static let maximumEntries = 2_000

    /// How long appends are allowed to pile up before the file is written.
    ///
    /// The in-memory array is updated at once, so the window — which reads
    /// it twice a second — stays live. Only the write is coalesced, and a
    /// trailing write always follows, so nothing is held back indefinitely.
    static let writeInterval: TimeInterval = 0.25

    private let queue = DispatchQueue(label: "MediaIdentifier.RenameLog")
    /// Only ever touched inside `queue`. Reads go through `entries`.
    private var _entries: [RenameLogEntry] = []
    /// Entries have changed since the last write.
    private var needsWrite = false
    /// A trailing write is already scheduled.
    private var writeScheduled = false
    private var lastWrite = Date.distantPast

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
            trimAndScheduleWrite()
        }
    }

    public func append(contentsOf newEntries: [RenameLogEntry]) {
        queue.sync {
            _entries.append(contentsOf: newEntries)
            trimAndScheduleWrite()
        }
    }

    public func clear() {
        queue.sync {
            _entries.removeAll()
            // At once: clearing is something the user asked for and then
            // looks at, and there is nothing to coalesce it with.
            persist()
        }
    }

    /// Writes now if anything is waiting. For a caller that is about to
    /// exit, and for tests that want to look at the file.
    public func flush() {
        queue.sync { if needsWrite { persist() } }
    }

    /// Keeps the newest `maximumEntries` and writes at most every
    /// `writeInterval`, with a trailing write so the last append is never
    /// the one that is lost. Must be called on `queue`.
    private func trimAndScheduleWrite() {
        if _entries.count > Self.maximumEntries {
            _entries.removeFirst(_entries.count - Self.maximumEntries)
        }
        needsWrite = true
        let since = Date().timeIntervalSince(lastWrite)
        if since >= Self.writeInterval {
            persist()
            return
        }
        guard !writeScheduled else { return }
        writeScheduled = true
        queue.asyncAfter(deadline: .now() + (Self.writeInterval - since)) { [weak self] in
            guard let self else { return }
            self.writeScheduled = false
            if self.needsWrite { self.persist() }
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
        needsWrite = false
        lastWrite = Date()
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
            .appendingPathComponent("rename-log.json")
    }
}
