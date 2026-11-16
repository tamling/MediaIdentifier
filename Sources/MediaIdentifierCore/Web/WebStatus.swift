import Foundation

/// What the last finished search for convertible files did.
///
/// The conversion panel used to work this out for itself, from "the engine
/// has gone quiet". That cannot tell a search that found nothing from a
/// search the engine refused to run (no library folder configured, where it
/// returns at its first guard without ever setting `busy`), nor from a
/// search still waiting behind some unrelated job -- and it answered all
/// three with "Keine Dateien zum Konvertieren gefunden." The generation is
/// what makes a new answer distinguishable from the one already on screen;
/// it moves for a refusal too, because a refusal is also an answer.
public struct ConvertSearchReport: Codable, Sendable, Equatable {
    public var generation: Int
    /// The engine never looked: no library folder is configured.
    public var refused: Bool
    /// The user stopped the walk, so `found` is however far it got.
    public var stopped: Bool
    public var found: Int

    public init(generation: Int = 0, refused: Bool = false,
                stopped: Bool = false, found: Int = 0) {
        self.generation = generation
        self.refused = refused
        self.stopped = stopped
        self.found = found
    }
}

/// What the last finished conversion run did.
///
/// For the same reason: the panel inferred "your files were converted" from
/// "the candidate list went empty", and announced "Fertig. Die neuen Dateien
/// liegen neben den Originalen" after runs in which every single file had
/// failed and nothing had been written. The engine knows the counts; this is
/// how it says so.
public struct ConvertRunReport: Codable, Sendable, Equatable {
    public var generation: Int
    public var converted: Int
    public var failed: Int
    public var stopped: Bool

    public init(generation: Int = 0, converted: Int = 0, failed: Int = 0,
                stopped: Bool = false) {
        self.generation = generation
        self.converted = converted
        self.failed = failed
        self.stopped = stopped
    }
}

/// What became of the last settings write.
///
/// The settings window printed "Übernommen um HH:MM:SS" the moment it had
/// QUEUED the write, because `submit` is asynchronous and there was nothing
/// to wait for. A write that then failed -- a read-only configuration
/// directory, a full disk, settings.json replaced by a directory -- left the
/// clock saying it had been applied, with the engine's own "Einstellungen
/// nicht gespeichert" on the main window behind the panel. Worse, the window
/// advanced its merge baseline to values that were never written, and the
/// merge only writes back fields that differ from that baseline: every edit
/// in the next press compared equal and was dropped, so the correction could
/// not be made either.
public struct SettingsSaveReport: Codable, Sendable, Equatable {
    /// Bumped by every finished attempt, failures included.
    public var generation: Int
    /// Nothing was written. `lastResult` says why.
    public var failed: Bool

    public init(generation: Int = 0, failed: Bool = false) {
        self.generation = generation
        self.failed = failed
    }
}

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
    /// How many renames could still be taken back.
    ///
    /// `RenameJournal.canUndo` existed from the start and nothing read it:
    /// the Rückgängig button was sensitive whether or not there was anything
    /// to undo, and pressing it on an empty journal said so only afterwards.
    /// It is a count rather than a flag because the one place it really
    /// matters is the question before clearing the history, which takes the
    /// journal with it — and "3 Schritte gehen weg" is a different sentence
    /// from "nothing goes away".
    public var undoableBatches: Int = 0
    /// See `ConvertSearchReport`. Defaulted rather than in the initialiser so
    /// an older stored snapshot still decodes.
    public var convertSearch = ConvertSearchReport()
    /// See `ConvertRunReport`.
    public var convertRun = ConvertRunReport()
    /// See `SettingsSaveReport`.
    public var settingsSave = SettingsSaveReport()

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
