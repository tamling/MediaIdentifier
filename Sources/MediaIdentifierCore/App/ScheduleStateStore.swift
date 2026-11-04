import Foundation

/// Remembers when the last unattended run happened, across restarts.
///
/// Kept apart from the settings on purpose. The settings are what the user
/// typed; this is what the program did, it changes without anyone asking,
/// and writing it into `settings.json` would mean rewriting that file — the
/// one holding the server address and every folder path — every time a
/// scheduled run ticks over.
///
/// Why it has to be remembered at all: without it the last-run time lived
/// only in memory, so a machine that is switched off overnight came back with
/// no idea whether the 03:00 run had happened. It then either never ran
/// again or ran immediately, and which of the two you got depended on the
/// order the settings happened to be saved in.
public struct ScheduleStateStore: Sendable {
    public let fileURL: URL

    public init(directory: URL, fileName: String = "schedule-state.json") {
        self.fileURL = directory.appendingPathComponent(fileName)
    }

    private struct Stored: Codable {
        /// Seconds since the epoch, not an ISO string: no time zone, no
        /// locale, no formatter to get wrong, and a file that still means
        /// the same thing after the machine is moved to another country.
        var lastRun: Double?
    }

    /// When the last unattended run started, or nil if none is recorded.
    ///
    /// A damaged or unreadable file reads as nil rather than throwing: the
    /// consequence is one skipped or one extra scan, which is not worth
    /// refusing to start over.
    public func lastRun() -> Date? {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let seconds = stored.lastRun else { return nil }
        // A clock that was wrong when this was written — a machine without a
        // battery, booting at the epoch — would otherwise make every run
        // overdue for ever.
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Records the moment. Failure is ignored deliberately: a run that has
    /// already happened must not be undone because a file could not be
    /// written, and the next start then behaves as it did before this
    /// existed.
    public func setLastRun(_ moment: Date?) {
        let stored = Stored(lastRun: moment?.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? AtomicFile.write(data, to: fileURL, permissions: 0o600)
    }
}
