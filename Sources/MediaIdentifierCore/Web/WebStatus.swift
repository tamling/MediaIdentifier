import Foundation

/// A read-only snapshot of what the app is currently doing, served over a small
/// local HTTP endpoint so external monitors (e.g. Uptime Kuma) can poll it and
/// notify when a run finishes (FR20). Contains no secrets — only progress and
/// counts. Pure value type so the HTTP-formatting helpers are testable without
/// any networking.
public struct StatusSnapshot: Codable, Sendable, Equatable {
    public var updated: Date
    /// True while renaming or converting — the key field for "is a job running".
    public var busy: Bool
    public var renaming: Bool
    public var renameProgress: Double
    public var converting: Bool
    public var convertProgress: Double
    public var currentFile: String?
    public var convertStatus: String?
    public var convertDetail: String?
    public var pendingConversions: Int
    public var totalItems: Int
    public var ready: Int
    public var done: Int
    public var lastResult: String?
    public var watchActive: Bool
    public var jellyfinConfigured: Bool
    /// True when the most recent run finished with one or more failures, so the
    /// health endpoint can report an error via its HTTP status code.
    public var hasError: Bool
    /// Commands accepted but not finished, including ones still queued.
    ///
    /// `busy` is only set once a job is running, and every button press
    /// redirects before that happens — so a page that refreshed on `busy`
    /// alone stopped refreshing exactly when the user was waiting.
    public var queuedWork: Int
    /// A download from a URL is running.
    public var downloading: Bool
    /// 0…1, or nil when the server sent no size — which is normal for a
    /// stream, and where a bar would be a guess.
    public var downloadProgress: Double?
    /// "12,4 MB von 48,0 MB · 1,2 MB/s" as the interface should show it.
    public var downloadDetail: String?
    /// When the next unattended run is due, or nil when none is.
    ///
    /// Worth showing next to the schedule's own sentence rather than instead
    /// of it: the sentence is what was asked for, this is what the program
    /// will actually do. A schedule that is set but not running shows a
    /// sentence and no date, which is the one state the user needs to see.
    public var nextScheduledRun: Date?
    /// When the last unattended run happened, or nil if none has.
    public var lastScheduledRun: Date?

    public init(
        updated: Date = Date(),
        busy: Bool = false,
        renaming: Bool = false,
        renameProgress: Double = 0,
        converting: Bool = false,
        convertProgress: Double = 0,
        currentFile: String? = nil,
        convertStatus: String? = nil,
        convertDetail: String? = nil,
        pendingConversions: Int = 0,
        totalItems: Int = 0,
        ready: Int = 0,
        done: Int = 0,
        lastResult: String? = nil,
        watchActive: Bool = false,
        jellyfinConfigured: Bool = false,
        hasError: Bool = false,
        queuedWork: Int = 0,
        downloading: Bool = false,
        downloadProgress: Double? = nil,
        downloadDetail: String? = nil,
        nextScheduledRun: Date? = nil,
        lastScheduledRun: Date? = nil
    ) {
        self.updated = updated
        self.busy = busy
        self.renaming = renaming
        self.renameProgress = renameProgress
        self.converting = converting
        self.convertProgress = convertProgress
        self.currentFile = currentFile
        self.convertStatus = convertStatus
        self.convertDetail = convertDetail
        self.pendingConversions = pendingConversions
        self.totalItems = totalItems
        self.ready = ready
        self.done = done
        self.lastResult = lastResult
        self.watchActive = watchActive
        self.jellyfinConfigured = jellyfinConfigured
        self.hasError = hasError
        self.queuedWork = queuedWork
        self.downloading = downloading
        self.downloadProgress = downloadProgress
        self.downloadDetail = downloadDetail
        self.nextScheduledRun = nextScheduledRun
        self.lastScheduledRun = lastScheduledRun
    }

    /// Something is happening, or is about to. What the interface should
    /// keep refreshing for.
    public var isWorking: Bool { busy || queuedWork > 0 }

    /// Percent (0–100) of whichever job is currently active.
    public var activePercent: Int {
        let fraction: Double
        if converting {
            fraction = convertProgress
        } else {
            fraction = renameProgress
        }
        return max(0, min(100, Int((fraction * 100).rounded())))
    }

    public static let empty = StatusSnapshot()
}
