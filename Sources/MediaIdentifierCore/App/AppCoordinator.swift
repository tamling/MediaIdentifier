import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Carries out the commands a front-end submits.
///
/// This is the engine both interfaces drive: the web UI and the native GTK
/// window send the same `WebCommand` values here and read the same snapshot
/// back. It lives in Core rather than beside the HTTP server because it never
/// needed the server — only `WebServer.swift` imports SwiftNIO — and leaving
/// it there would have meant either a second copy of this logic for the GTK
/// front-end, or that front-end linking a web server it never starts.
///
/// Every command runs on one serial queue, so two scans or a scan and a rename
/// can never interleave, and requests are never made to wait: they submit and
/// return, and progress is reported back through `snapshot`.
public final class AppCoordinator: WebCommandSink, @unchecked Sendable {
    /// Finds media below a folder.
    public struct FolderScan: Sendable {
        /// Hard limit so pointing Mediafin at a huge tree cannot exhaust
        /// memory before the user sees anything.
        public static let maximumFiles = 5_000

        /// Music files under a folder.
        ///
        /// `.3gp` is in both registries and the video scanner already
        /// claims it, so it is skipped here: a .3gp is almost always a
        /// phone recording with a picture in it, and deciding per file
        /// would mean starting a process for a case nobody has.
        public static func audioFiles(under root: URL,
                                      fileManager: FileManager = .default) -> [URL] {
            guard let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            var found: [URL] = []
            for case let url as URL in enumerator {
                guard AudioFileTypes.isAudio(url),
                      !AudioFileTypes.claimedByVideoInstead
                          .contains(url.pathExtension.lowercased()) else { continue }
                found.append(url)
                if found.count >= maximumFiles { break }
            }
            return found
        }

        public static func videoFiles(under root: URL,
                                      fileManager: FileManager = .default) -> [URL] {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }

            var found: [URL] = []
            for case let url as URL in enumerator {
                guard VideoFileTypes.isVideo(url) else { continue }
                found.append(url)
                if found.count >= maximumFiles { break }
            }
            return found.sorted { $0.path < $1.path }
        }
    }

    private let queue = DispatchQueue(label: "mediafin.coordinator", qos: .utility)
    private let lock = NSLock()
    private let watchScanner = WatchFolderScanner()
    private let watchInterval: TimeInterval
    /// Only touched on `queue`.
    private var watchTimer: DispatchSourceTimer?
    private var scheduleTimer: DispatchSourceTimer?
    /// When the last unattended run happened. Nil until one has.
    ///
    /// Mirrored to disk by `scheduleState`, because the question it answers
    /// — has tonight's run happened? — outlives the process.
    private var _lastScheduledRun: Date?

    private let configDirectory: URL
    private let settingsStore: SettingsStore
    private let scheduleState: ScheduleStateStore
    private let secretStore: SecretStore
    private let log: RenameLog
    private let journal: RenameJournal
    private let executor: RenameExecutor
    private let scanner = MediaScanner()
    private let planner = RenamePlanner()

    private var _settings: WebSettings
    private var _snapshot = StatusSnapshot()
    private var _items: [RenameItem] = []
    private var _convertible: [ConversionCandidate] = []
    /// Set while a conversion run should stop after the file in flight.
    ///
    /// Deliberately not cleared when a run starts. The queue is serial, so a
    /// convert command can wait behind a scan for a long time, and a cancel
    /// pressed during that wait arrives first — clearing the flag at the start
    /// of the run would discard it and convert everything after the interface
    /// had already confirmed it was stopping.
    private var _cancelConversions = false
    /// Convert commands submitted but not yet taken off the queue, so a cancel
    /// can tell "stop the run that is coming" from "there is nothing to stop".
    private var _queuedConversionRuns = 0
    /// The running FFmpeg, so a cancel can end it.
    private var _runningConversion: Process?
    private var _cancelTransfers = false
    private var _queuedTransferRuns = 0
    private var _runningTransfer: Process?
    /// True from the moment a send starts until it ends, including the gaps
    /// between files when no process exists.
    private var _transferRunning = false
    private var _runningDownload: Process?
    private var _cancelDownload = false
    private var _queuedDownloads = 0
    private var _probes: [ProbeSubject: ProbeResult] = [:]
    /// Commands accepted but not finished.
    ///
    /// Counted in `submit`, before the queue is even touched, because the
    /// interface redirects the moment a button is pressed: without this, the
    /// page it redirects to is rendered before the work starts, sees nothing
    /// happening, and stops refreshing. The user then stares at the state
    /// from before they pressed the button.
    private var _pendingWork = 0

    /// Set when the settings file could not be read, so the interface can say
    /// so instead of silently running on defaults.
    public let settingsProblem: String?

    /// - Parameter watchInterval: how often the import folder is looked at
    ///   when watching is on. Injectable so the tests do not wait.
    public init(configDirectory: URL, watchInterval: TimeInterval = 15) {
        self.watchInterval = max(1, watchInterval)
        self.configDirectory = configDirectory
        settingsStore = SettingsStore(directory: configDirectory)
        scheduleState = ScheduleStateStore(directory: configDirectory)
        secretStore = SecretStore(directory: configDirectory)
        log = RenameLog(url: configDirectory.appendingPathComponent("rename-log.json"))
        journal = RenameJournal(url: configDirectory.appendingPathComponent("undo-journal.json"))
        executor = RenameExecutor(log: log, journal: journal)

        let loaded = settingsStore.load()
        _settings = loaded.settings
        // Before anything builds a string. Both front-ends construct the
        // coordinator first, so this is the one place that covers them both
        // — and it has to happen before the first window label is made,
        // because a GTK label is given its text once at construction.
        Text.start(configured: loaded.settings.language)
        if case .unreadable(let detail) = loaded.state {
            settingsProblem = detail
        } else {
            settingsProblem = nil
        }
        // A secrets file left readable by other accounts is a problem whether
        // or not it is read today.
        if secretStore.tightenPermissionsIfNeeded() {
            _snapshot.lastResult = Text.s(
                "Die Datei mit den Zugangsdaten war für andere Konten lesbar; die "
                    + "Rechte wurden korrigiert. Die gespeicherten Schlüssel sollten "
                    + "ersetzt werden.",
                "The credentials file was readable by other accounts; its permissions "
                    + "have been corrected. Consider replacing the stored keys.")
        }
        refreshSnapshotCounts()
        // Not on the queue yet, so hand it over rather than touching the timer.
        //
        // The schedule is armed here as well, which it used to not be: it was
        // only ever started from `save`, so it ran in the session where the
        // user pressed Apply and never again. On a media server that is
        // exactly the opposite of the point — the machine restarts, and the
        // nightly run stops happening without a word.
        queue.async { [weak self] in
            self?.updateWatchState()
            self?.updateScheduleState(.startup)
        }
    }

    deinit {
        watchTimer?.cancel()
        scheduleTimer?.cancel()
    }

    // MARK: State the interface reads

    public var snapshot: StatusSnapshot { lock.lock(); defer { lock.unlock() }; return _snapshot }
    public var settings: WebSettings { lock.lock(); defer { lock.unlock() }; return _settings }
    public var items: [RenameItem] { lock.lock(); defer { lock.unlock() }; return _items }
    public var convertible: [ConversionCandidate] {
        lock.lock(); defer { lock.unlock() }; return _convertible
    }

    /// Whether FFmpeg can be found, so the page can say so instead of failing
    /// once the button is pressed.
    public var ffmpegAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: ffmpegPath)
    }

    private var ffmpegPath: String {
        FFmpegLocator.resolve(configured: settings.conversion.ffmpegPath)
    }
    public var configuredSecrets: Set<SecretKey> { secretStore.configuredKeys() }
    public var logEntries: [RenameLogEntry] { log.entries }

    // MARK: Submission

    public func submit(_ command: WebCommand) {
        // Cancelling must not queue behind the very run it is meant to stop,
        // so it is handled here rather than on the serial queue.
        if case .cancelConversions = command {
            cancelConversions()
            return
        }
        // Counted here rather than when the run starts, so a cancel issued
        // while the command is still waiting its turn is not mistaken for a
        // cancel with nothing to cancel.
        if case .cancelTransfers = command {
            cancelTransfers()
            return
        }
        if case .cancelDownload = command {
            cancelDownload()
            return
        }
        // Counted here rather than when the run starts, so a cancel issued
        // while the command is still waiting its turn is not mistaken for a
        // cancel with nothing to cancel.
        if case .convertFiles = command {
            lock.lock(); _queuedConversionRuns += 1; lock.unlock()
        }
        if case .transferFiles = command {
            lock.lock(); _queuedTransferRuns += 1; lock.unlock()
        }
        if case .downloadURL = command {
            lock.lock(); _queuedDownloads += 1; lock.unlock()
        }
        if Self.isWork(command) {
            // The count is read out while the lock is held and then used
            // outside it. Reading it inside `update`'s closure would take
            // the same non-recursive lock a second time and hang the app —
            // which is exactly what the first version of this did.
            lock.lock()
            _pendingWork += 1
            let pending = _pendingWork
            lock.unlock()
            update { $0.queuedWork = pending }
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.execute(command)
            if Self.isWork(command) {
                self.lock.lock()
                self._pendingWork = max(0, self._pendingWork - 1)
                let pending = self._pendingWork
                self.lock.unlock()
                self.update { $0.queuedWork = pending }
            }
        }
    }

    var pendingWorkCount: Int { lock.lock(); defer { lock.unlock() }; return _pendingWork }

    /// Whether a command does something the user should see progress for.
    ///
    /// Saving a setting or storing a key finishes before the redirect lands;
    /// scanning, renaming, sending and the connection probes do not.
    static func isWork(_ command: WebCommand) -> Bool {
        switch command {
        case .saveSettings, .setSecret, .setAllAccepted, .setAccepted,
             .clearHistory,
             .cancelConversions, .cancelTransfers, .cancelDownload:
            return false
        case .scanSourceFolder, .applyProposedRenames, .undoLastRename,
             .findConvertible, .convertFiles, .transferFiles, .downloadURL,
             .testLocalLLMConnection, .testJellyfinConnection,
             .testRemoteConnection, .checkEverything:
            return true
        }
    }

    /// Runs a command and waits for it. Only for tests: a request must never
    /// call this, or it would block on the work.
    func executeForTesting(_ command: WebCommand) {
        queue.sync { self.execute(command) }
    }

    /// Holds the serial queue until `release` is signalled. Only for tests:
    /// it is what makes "a cancel arrives while the run is still waiting its
    /// turn" reproducible instead of a race that passes by luck.
    func blockQueueForTesting(until release: DispatchSemaphore) {
        queue.async { release.wait() }
    }

    /// Waits for everything already on the queue to finish. Only for tests.
    func drainForTesting() {
        queue.sync {}
    }

    /// Whether a cancel is currently armed. Only for tests: the end-to-end
    /// path needs FFmpeg, which CI does not install, so the flag's own rules
    /// are checked directly.
    var cancelIsArmedForTesting: Bool {
        lock.lock(); defer { lock.unlock() }; return _cancelConversions
    }

    /// The same, for transfers. Only for tests: the end-to-end path needs an
    /// SSH server, so the flag's own rules are checked directly.
    var transferCancelIsArmedForTesting: Bool {
        lock.lock(); defer { lock.unlock() }; return _cancelTransfers
    }

    // MARK: Execution

    private func execute(_ command: WebCommand) {
        switch command {
        case .saveSettings(let settings):
            save(settings)
        case .setSecret(let key, let value):
            setSecret(key, value)
        case .testLocalLLMConnection:
            testLocalLLM()
        case .testJellyfinConnection:
            testJellyfin()
        case .scanSourceFolder:
            scanSourceFolder()
        case .applyProposedRenames(let accepting):
            applyRenames(accepting: accepting)
        case .undoLastRename:
            undoLast()
        case .findConvertible:
            findConvertible()
        case .convertFiles(let accepting):
            convertFiles(accepting: accepting)
        case .cancelConversions:
            // Handled in `submit`, off the queue.
            break
        case .setAllAccepted(let accepted):
            setAllAccepted(accepted)
        case let .setAccepted(id, accepted):
            setAccepted(id, accepted)
        case .transferFiles(let accepting):
            transferFiles(accepting: accepting)
        case .cancelTransfers:
            // Handled in `submit`, off the queue.
            break
        case .downloadURL(let url):
            downloadURL(url)
        case .cancelDownload:
            // Handled in `submit`, off the queue.
            break
        case .testRemoteConnection:
            testRemote()
        case .checkEverything:
            checkEverything()
        case .clearHistory:
            clearHistory()
        }
    }

    private func save(_ settings: WebSettings) {
        do {
            let previous = self.settings
            try settingsStore.save(settings)
            lock.lock()
            _settings = settings.normalised()
            // A probe is about the thing it probed. Changing the address,
            // the login or the target path makes the stored answer describe
            // a different machine — and it used to be kept, so a green lamp
            // could be reporting on a server nobody had ever contacted.
            if settings.remote != previous.remote { _probes[.remote] = nil }
            if settings.localLLMBaseURL != previous.localLLMBaseURL
                || settings.localLLMModel != previous.localLLMModel {
                _probes[.localLLM] = nil
            }
            if settings.jellyfinBaseURL != previous.jellyfinBaseURL {
                _probes[.jellyfin] = nil
            }
            lock.unlock()
            if settings.language != previous.language {
                Text.start(configured: settings.language)
            }
            update { $0.lastResult = Text.s("Einstellungen gespeichert.",
                                            "Settings saved.") }
            updateWatchState()
            // Only a changed schedule resets the clock. Saving an unrelated
            // setting at 02:59 must not push tonight's 03:00 run to tomorrow.
            updateScheduleState(settings.schedule == previous.schedule
                                ? .settingsSaved : .scheduleChanged)
            // So the interface stops offering a "send to the server" button
            // the moment the server is switched off, rather than at the next
            // scan.
            refreshSnapshotCounts()
        } catch {
            update { $0.lastResult = Text.s("Einstellungen nicht gespeichert: \(error)",
                                            "Settings could not be saved: \(error)") }
        }
    }

    private func setSecret(_ key: SecretKey, _ value: String) {
        do {
            try secretStore.set(value, for: key)
            lock.lock()
            switch key {
            case .remotePassword: _probes[.remote] = nil
            case .localLLMAPIKey: _probes[.localLLM] = nil
            case .jellyfinToken: _probes[.jellyfin] = nil
            case .tmdbAPIKey: break
            }
            lock.unlock()
            // Never echo the value, not even its length.
            update {
                $0.lastResult = value.isEmpty
                    ? Text.s("\(key.label) entfernt.", "\(key.label) removed.")
                    : Text.s("\(key.label) gespeichert.", "\(key.label) stored.")
            }
        } catch {
            update { $0.lastResult = Text.s("\(key.label) ließ sich nicht speichern.",
                                            "\(key.label) could not be stored.") }
        }
    }

    // MARK: Connection tests

    private func testLocalLLM() {
        let settings = self.settings
        guard let provider = localLLMProvider(settings) else {
            update { $0.lastResult = Text.s(
                "Erst Adresse und Modellnamen des Modellservers eintragen.",
                "Enter the model server address and model name first.") }
            return
        }
        update { $0.lastResult = Text.s("Modellserver wird geprüft …",
                                        "Testing the model server…") }
        runAndWait { [weak self] in
            do {
                let status = try await provider.verify()
                let message = Self.describe(
                    status: status, service: Text.s("Modellserver", "model server"))
                // 2xx only. A 401 is an answer, not a working connection, and
                // a lamp that went green on it would be the panel lying.
                self?.record(.localLLM, ok: (200..<300).contains(status), detail: message)
                self?.update { $0.lastResult = message }
            } catch {
                let message = Text.s("Modellserver nicht erreichbar: ",
                                     "The model server could not be reached: ")
                    + Self.reason(for: error)
                self?.record(.localLLM, ok: false, detail: message)
                self?.update { $0.lastResult = message }
            }
        }
    }

    private func testJellyfin() {
        let settings = self.settings
        guard !settings.jellyfinBaseURL.isEmpty,
              let apiKey = secretStore.value(for: .jellyfinToken) else {
            update { $0.lastResult = Text.s(
                "Erst Jellyfin-Adresse und API-Key eintragen.",
                "Enter the Jellyfin address and API key first.") }
            return
        }
        update { $0.lastResult = Text.s("Jellyfin wird geprüft …", "Testing Jellyfin…") }
        runAndWait { [weak self] in
            do {
                let connector = try JellyfinConnector(serverURL: settings.jellyfinBaseURL,
                                                      apiKey: apiKey)
                let status = try await connector.verify()
                let message = Self.describe(status: status, service: "Jellyfin")
                self?.record(.jellyfin, ok: (200..<300).contains(status), detail: message)
                self?.update { $0.lastResult = message }
            } catch {
                let message = Text.s("Jellyfin nicht erreichbar: ",
                                     "Jellyfin could not be reached: ")
                    + Self.reason(for: error)
                self?.record(.jellyfin, ok: false, detail: message)
                self?.update { $0.lastResult = message }
            }
        }
    }

    /// Turns an HTTP status into something a user can act on.
    static func describe(status: Int, service: String) -> String {
        switch status {
        case 200..<300:
            return Text.s("\(service): antwortet. Die Verbindung steht.",
                          "The \(service) answered. The connection works.")
        case 401, 403:
            return Text.s("\(service): Schlüssel abgelehnt. API-Key prüfen.",
                          "The \(service) refused the key. Check the API key.")
        case 404:
            return Text.s("\(service): antwortet, aber nicht unter dieser Adresse. "
                              + "URL prüfen.",
                          "The \(service) answered, but not on that address. "
                              + "Check the URL.")
        case -1:
            return Text.s("\(service): antwortet auf eine Art, die nicht verstanden wurde.",
                          "The \(service) answered in a way that was not understood.")
        default:
            return Text.s("\(service): antwortet mit Status \(status).",
                          "The \(service) answered with status \(status).")
        }
    }

    /// The raw reason, including the numeric code, because a bare
    /// "could not connect" tells the user nothing they can fix. Apple's
    /// transport-security refusal (-1022) in particular looks like a network
    /// fault but is not one.
    static func reason(for error: Error) -> String {
        let urlError = error as? URLError
        guard let urlError else { return String(describing: error) }
        let code = urlError.errorCode
        var text = urlError.localizedDescription
        if code == -1022 {
            text += " (the app refused to send this request unencrypted; "
                + "use https, or allow local networking)"
        }
        return "\(text) [\(code)]"
    }

    // MARK: Scanning and renaming

    /// Scans the import folder and replaces the plan.
    ///
    /// - Returns: true when this call produced a plan of its own — including
    ///   an empty one, when the folder holds nothing. False means it could
    ///   not run, and that whatever `items` holds is from an earlier scan.
    ///   The unattended run needs that distinction: acting on a stale plan
    ///   means renaming and sending a list nobody has looked at.
    @discardableResult
    private func scanSourceFolder() -> Bool {
        let settings = self.settings
        let source = settings.sourceFolder
        guard !source.isEmpty else {
            update {
                $0.hasError = true
                $0.lastResult = Text.s(
                    "Erst den Importordner in den Einstellungen setzen.",
                    "Set the import folder in the settings first.")
            }
            return false
        }
        let root = URL(fileURLWithPath: source, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            update {
                $0.hasError = true
                $0.lastResult = Text.s("Den Importordner gibt es nicht: \(source)",
                                       "The import folder does not exist: \(source)")
            }
            return false
        }

        if settings.libraryMode == .music {
            return scanForMusic(under: root, settings: settings)
        }

        update { $0.busy = true; $0.convertStatus = "Looking for media…" }
        let urls = FolderScan.videoFiles(under: root)
        guard !urls.isEmpty else {
            lock.lock(); _items = []; lock.unlock()
            update {
                $0.busy = false
                $0.convertStatus = nil
                $0.hasError = false
                $0.lastResult = Text.s("Keine Videodateien in \(source) gefunden.",
                                       "No video files found in \(source).")
            }
            refreshSnapshotCounts()
            return true
        }

        var mediaFiles = scanner.scan(urls: urls)
        if let provider = enrichmentProvider(settings) {
            update { $0.convertStatus = "Identifying…" }
            var enriched: [MediaFile] = []
            for var file in mediaFiles {
                let input = file.parsed
                let parsed = runAndWaitReturning {
                    await MetadataEnricher(provider: provider).enrich(input)
                }
                file.parsed = parsed ?? file.parsed
                enriched.append(file)
            }
            mediaFiles = enriched
        }

        // The namer produces a path relative to a library root and does not
        // prefix "Movies"/"Series", so movies and episodes need their own
        // roots. Anything without a configured root is renamed where it is.
        let movies = settings.moviesFolder.isEmpty
            ? nil : URL(fileURLWithPath: settings.moviesFolder, isDirectory: true)
        let series = settings.seriesFolder.isEmpty
            ? nil : URL(fileURLWithPath: settings.seriesFolder, isDirectory: true)
        let plan = planner.makePlan(for: mediaFiles, outputRoot: nil, libraryRoot: nil)
            .map { item -> RenameItem in
                let root = item.mediaFile.parsed.kind == .episode ? series : movies
                guard let root else { return item }
                var moved = item
                moved.outputRoot = root
                return planner.reconcile(item: moved)
            }

        lock.lock(); _items = plan; lock.unlock()
        update {
            $0.busy = false
            $0.convertStatus = nil
            $0.hasError = false
            $0.lastResult = Text.s(
                "\(plan.count) Datei\(plan.count == 1 ? "" : "en") bereit zum Umbenennen.",
                "\(plan.count) file\(plan.count == 1 ? "" : "s") ready to rename.")
        }
        refreshSnapshotCounts()
        return true
    }

    /// Proposes a place for every music file, from its own tags.
    ///
    /// Nothing is guessed. A file whose tags do not name an artist, an
    /// album and a title gets no proposal at all: filing it somewhere
    /// plausible puts it where the user will not think to look, which is
    /// worse than leaving it where they put it.
    @discardableResult
    private func scanForMusic(under root: URL, settings: WebSettings) -> Bool {
        guard !settings.musicFolder.isEmpty else {
            update {
                $0.busy = false
                $0.hasError = true
                $0.lastResult = Text.s(
                    "Für den Musikmodus fehlt der Musikordner in den Einstellungen.",
                    "The music folder is missing from the settings; music mode needs it.")
            }
            return false
        }
        guard let reader = AudioTagReader() else {
            update {
                $0.busy = false
                $0.hasError = true
                $0.lastResult = Text.s(
                    "ffmpeg/ffprobe wurden nicht gefunden; ohne sie lassen sich die Tags "
                        + "nicht lesen: sudo apt install ffmpeg",
                    "ffmpeg/ffprobe were not found; without them the tags cannot be "
                        + "read: sudo apt install ffmpeg")
            }
            return false
        }

        update { $0.busy = true; $0.convertStatus = "Musik wird gelesen …" }
        let urls = FolderScan.audioFiles(under: root)
        let musicRoot = URL(fileURLWithPath: settings.musicFolder, isDirectory: true)

        var plan: [RenameItem] = []
        var unreadable = 0
        for url in urls {
            guard let tags = reader.read(url),
                  let relative = MusicNamer.relativePath(
                    for: tags, extension: url.pathExtension) else {
                unreadable += 1
                continue
            }
            let parsed = ParsedRelease(originalFileName: url.lastPathComponent,
                                       title: tags.title ?? url.lastPathComponent,
                                       year: tags.year,
                                       kind: .unknown)
            plan.append(RenameItem(mediaFile: MediaFile(url: url, parsed: parsed),
                                   outputRoot: musicRoot,
                                   proposedRelativePath: relative))
        }

        // The same detection the video path gets from RenamePlanner. Built
        // by hand here, these items had no conflict set at all — so two
        // copies of one album, which resolve to byte-identical paths, were
        // shown without a warning and then handed to the conflict policy.
        plan = Self.markingConflicts(in: plan)

        lock.lock(); _items = plan; lock.unlock()
        update {
            $0.busy = false
            $0.convertStatus = nil
            $0.hasError = false
            if plan.isEmpty {
                $0.lastResult = urls.isEmpty
                    ? Text.s("Keine Musikdateien in \(root.path) gefunden.",
                             "No music files found in \(root.path).")
                    : Text.s(
                        "\(urls.count) Musikdatei\(urls.count == 1 ? "" : "en") gefunden, "
                            + "aber keine mit genug Tags (Künstler, Album, Titel).",
                        "\(urls.count) music file\(urls.count == 1 ? "" : "s") found, but "
                            + "none with enough tags (artist, album, title).")
            } else {
                $0.lastResult = Text.s("\(plan.count) Titel bereit",
                                       "\(plan.count) tracks ready")
                    + (unreadable > 0
                        ? Text.s(" · \(unreadable) ohne ausreichende Tags übersprungen.",
                                 " · \(unreadable) skipped for want of tags.")
                        : ".")
            }
        }
        refreshSnapshotCounts()
        return true
    }

    /// - Returns: the outcome, or nil when nothing was attempted.
    @discardableResult
    private func applyRenames(accepting: Set<UUID>?) -> RenameOutcome? {
        var plan = items
        guard !plan.isEmpty else {
            update { $0.lastResult = Text.s(
                "Nichts umzubenennen — erst den Importordner durchsuchen.",
                "Nothing to rename — scan the import folder first.") }
            return nil
        }
        // The page sends the ids the user ticked. An empty selection means they
        // unticked everything, which must do nothing rather than everything.
        if let accepting {
            plan = plan.filter { accepting.contains($0.id) }
            guard !plan.isEmpty else {
                update { $0.lastResult = Text.s(
                    "Es war nichts angehakt, also wurde nichts umbenannt.",
                    "No files were ticked, so nothing was renamed.") }
                return nil
            }
        }
        // Two ticked proposals that want the same name would be resolved by
        // the policy — and under "replace" the first one, already filed, is
        // moved aside to make room for the second. Which of two rips to
        // keep is not a decision this code should make, so the pair is
        // refused and named, exactly as the transfer does.
        var byDestination: [String: [RenameItem]] = [:]
        for item in plan {
            byDestination[item.primaryDestination.standardizedFileURL.path,
                          default: []].append(item)
        }
        let collisions = byDestination.filter { $0.value.count > 1 }
        var collided = false
        if !collisions.isEmpty {
            let names = collisions.values.flatMap { $0 }
                .map(\.originalFileName).sorted().joined(separator: ", ")
            let ids = Set(collisions.values.flatMap { $0 }.map(\.id))
            plan = plan.filter { !ids.contains($0.id) }
            collided = true
            update {
                $0.hasError = true
                $0.lastResult = Text.s(
                    "Mehrere Dateien sollen denselben Namen bekommen: " + names
                        + ". Diese wurden nicht umbenannt — bitte eine davon abwählen.",
                    "Several files would be given the same name: " + names
                        + ". They were not renamed — please untick one of them.")
            }
            guard !plan.isEmpty else { return nil }
        }

        let policy = settings.conflictPolicy.policy
        update { $0.busy = true; $0.renaming = true; $0.renameProgress = 0; $0.hasError = false }

        let outcome = executor.execute(plan: plan, policy: policy,
                                       progress: { [weak self] fraction in
            self?.update { $0.renameProgress = fraction }
        })

        let applied = Set(plan.map(\.id))
        lock.lock(); _items.removeAll { applied.contains($0.id) }; lock.unlock()
        update {
            $0.busy = false
            $0.renaming = false
            $0.renameProgress = 1
            $0.hasError = outcome.failed > 0 || collided
            $0.lastResult = (collided
                ? Text.s("Namenskonflikte übersprungen. ", "Name clashes skipped. ") : "")
                + Text.s("Umbenannt \(outcome.succeeded), übersprungen \(outcome.skipped)",
                         "Renamed \(outcome.succeeded), skipped \(outcome.skipped)")
                + (outcome.failed > 0
                    ? Text.s(", fehlgeschlagen \(outcome.failed)",
                             ", failed \(outcome.failed)")
                    : "") + "."
        }
        // Only for the files that are now in the library, and only for the
        // audio ones. Driving this off `libraryMode` instead meant a plan
        // scanned as video, applied after the user had switched the mode to
        // music, had ffmpeg asked for a cover inside every film.
        writeAlbumCovers(landed: outcome.landed, in: plan)
        refreshSnapshotCounts()
        refreshJellyfinLibrary()
        return outcome
    }

    /// Flags items that would land on top of each other, or on a file that
    /// is already there.
    ///
    /// Pure, so the rule is testable. The video path gets this from
    /// `RenamePlanner.detectConflicts`; music items are built by hand and
    /// were getting nothing.
    static func markingConflicts(in plan: [RenameItem],
                                 fileManager: FileManager = .default) -> [RenameItem] {
        var counts: [String: Int] = [:]
        for item in plan {
            counts[item.primaryDestination.standardizedFileURL.path, default: 0] += 1
        }
        return plan.map { item in
            var flagged = item
            let path = item.primaryDestination.standardizedFileURL.path
            if counts[path, default: 0] > 1 {
                flagged.conflict = .duplicateInBatch
            } else if fileManager.fileExists(atPath: path) {
                flagged.conflict = .existingFile
            }
            return flagged
        }
    }

    /// Writes each album's cover next to its tracks, once.
    ///
    /// From the file's own embedded picture, which is why this needs no
    /// network: most tagged music carries its art. An album that already
    /// has an image under any of the four names Jellyfin accepts is left
    /// alone — overwriting one the user chose would be presumptuous.
    ///
    /// - Parameter landed: where each item's file actually is, from the
    ///   rename outcome. Only those get a cover: an item that was skipped or
    ///   that failed has no album folder to put one in, and the old version,
    ///   which worked from the plan, asked ffmpeg for a picture from files
    ///   that had never moved and wrote it beside nothing.
    private func writeAlbumCovers(landed: [UUID: URL], in plan: [RenameItem]) {
        // Per file rather than per library mode: a plan scanned as video and
        // applied after the user switched the mode to music used to have
        // ffmpeg asked for a cover inside every film.
        let audio = plan.filter {
            landed[$0.id] != nil && AudioFileTypes.isAudio($0.mediaFile.url)
        }
        guard !audio.isEmpty, let reader = AudioTagReader() else { return }
        var done: Set<String> = []
        var written = 0

        for item in audio {
            guard let moved = landed[item.id] else { continue }
            let coverRelative = MusicNamer.coverPath(forTrackAt: item.proposedRelativePath)
            let folder = (coverRelative as NSString).deletingLastPathComponent
            guard done.insert(folder).inserted else { continue }

            // Beside the file as it now is, not beside where it was planned
            // to go: under the "rename" conflict policy the two differ.
            let albumFolder = moved.deletingLastPathComponent()
            let destination = albumFolder
                .appendingPathComponent((coverRelative as NSString).lastPathComponent)
            // Any of folder/poster/cover/default, any of the image
            // extensions: Jellyfin accepts all of them, so any one of
            // them means this album is already covered.
            let existing = (try? FileManager.default.contentsOfDirectory(
                atPath: albumFolder.path)) ?? []
            if existing.contains(where: {
                AudioFileTypes.isCoverImage(URL(fileURLWithPath: $0))
            }) { continue }

            if reader.extractCover(from: moved, to: destination) { written += 1 }
        }

        guard written > 0 else { return }
        update {
            $0.lastResult = ($0.lastResult ?? "")
                + Text.s(" \(written) Albumcover geschrieben.",
                         " \(written) album covers written.")
        }
    }

    /// Tells Jellyfin to rescan, so renamed files show up without the user
    /// having to do it by hand (FR20).
    private func refreshJellyfinLibrary() {
        let settings = self.settings
        guard !settings.jellyfinBaseURL.isEmpty,
              let apiKey = secretStore.value(for: .jellyfinToken) else { return }
        runAndWait { [weak self] in
            do {
                let connector = try JellyfinConnector(serverURL: settings.jellyfinBaseURL,
                                                      apiKey: apiKey)
                try await connector.refresh()
                self?.update { $0.lastResult = ($0.lastResult ?? "")
                    + Text.s(" Jellyfin durchsucht neu.", " Jellyfin is rescanning.") }
            } catch {
                self?.update {
                    $0.lastResult = ($0.lastResult ?? "")
                        + Text.s(" Jellyfin ließ sich nicht zum Neudurchsuchen bewegen: ",
                                 " Jellyfin could not be told to rescan: ")
                        + Self.reason(for: error)
                }
            }
        }
    }

    /// Ticks or unticks one proposal, by id.
    ///
    /// Silent: this runs on every press of the space bar, and a message
    /// saying "ticked" each time would push whatever the user was reading
    /// off the screen.
    private func setAccepted(_ id: UUID, _ accepted: Bool) {
        lock.lock()
        if let index = _items.firstIndex(where: { $0.id == id }) {
            _items[index].isAccepted = accepted
        }
        lock.unlock()
        refreshSnapshotCounts()
    }

    /// Ticks or unticks every proposal at once.
    private func setAllAccepted(_ accepted: Bool) {
        lock.lock()
        for index in _items.indices { _items[index].isAccepted = accepted }
        let count = _items.count
        lock.unlock()
        update {
            $0.lastResult = count == 0
                ? Text.s("Es gibt nichts zum Anhaken.", "There is nothing to tick.")
                : (accepted
                    ? Text.s("Alle \(count) angehakt.", "All \(count) ticked.")
                    : Text.s("Alle abgehakt.", "All unticked."))
        }
    }

    private func undoLast() {
        let restored = executor.undoLast()
        update {
            $0.lastResult = restored == 0
                ? Text.s("Es gab nichts rückgängig zu machen.",
                         "There was nothing to undo.")
                : Text.s("\(restored) Datei\(restored == 1 ? "" : "en") zurückgelegt.",
                         "Put \(restored) file\(restored == 1 ? "" : "s") back.")
        }
        refreshSnapshotCounts()
    }

    private func clearHistory() {
        log.clear()
        journal.clear()
        update { $0.lastResult = Text.s("Verlauf geleert.", "History cleared.") }
        refreshSnapshotCounts()
    }

    // MARK: Converting

    /// Lists videos in the library folders that are not already output of a
    /// previous conversion.
    private func findConvertible() {
        let settings = self.settings
        let roots = [settings.moviesFolder, settings.seriesFolder, settings.sourceFolder]
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }

        guard !roots.isEmpty else {
            update { $0.lastResult = Text.s(
                "Erst die Bibliotheksordner in den Einstellungen setzen.",
                "Set your library folders in the settings first.") }
            return
        }

        update { $0.busy = true; $0.convertStatus = "Looking for files…" }
        var found: [ConversionCandidate] = []
        var seen: Set<String> = []
        for root in roots {
            for url in FolderScan.videoFiles(under: root) {
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                // Never offer our own output: a second pass would re-encode
                // an already lossy file.
                guard !ConversionOutput.isConvertedOutput(url) else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                found.append(ConversionCandidate(source: url, byteSize: Int64(size)))
            }
        }

        lock.lock(); _convertible = found; lock.unlock()
        update {
            $0.busy = false
            $0.convertStatus = nil
            $0.lastResult = found.isEmpty
                ? Text.s("Keine Dateien zum Konvertieren gefunden.",
                         "No files to convert were found.")
                : Text.s(
                    "\(found.count) Datei\(found.count == 1 ? "" : "en") "
                        + "könnte\(found.count == 1 ? "" : "n") konvertiert werden.",
                    "\(found.count) file\(found.count == 1 ? "" : "s") could be converted.")
        }
    }

    /// Converts the ticked files, one after another.
    ///
    /// The output goes beside the original and the original is kept: a
    /// re-encode is lossy and slow, so a bad result has to be undoable by
    /// deleting the new file. Nothing starts without this command.
    private func convertFiles(accepting: Set<UUID>) {
        // This run is no longer queued, whatever happens below.
        lock.lock(); _queuedConversionRuns = max(0, _queuedConversionRuns - 1); lock.unlock()
        let all = convertible
        let pending = all.filter { accepting.contains($0.id) }
        guard !pending.isEmpty else {
            clearCancelRequest()
            update { $0.lastResult = Text.s(
                "Es war nichts angehakt, also wurde nichts konvertiert.",
                "No files were ticked, so nothing was converted.") }
            return
        }
        let options = settings.conversion.options
        let converter = FFmpegConverter(ffmpegPath: ffmpegPath)
        guard converter.isAvailable else {
            clearCancelRequest()
            update {
                $0.lastResult = FFmpegConverter.ConverterError.ffmpegNotFound
                    .errorDescription ?? "FFmpeg was not found."
            }
            return
        }

        // The flag is NOT cleared here. A cancel that arrived while this
        // command was still queued is meant for this run, and clearing it now
        // would be exactly the bug: the interface says it is stopping and then
        // converts everything.
        var done = 0
        var failed = 0

        for (index, candidate) in pending.enumerated() {
            lock.lock()
            let cancelled = _cancelConversions
            lock.unlock()
            if cancelled { break }

            let destination = ConversionOutput.destination(for: candidate.source,
                                                           options: options)
            update {
                $0.busy = true
                $0.converting = true
                $0.convertProgress = 0
                $0.currentFile = candidate.fileName
                $0.pendingConversions = pending.count - index - 1
                $0.convertDetail = nil
            }

            do {
                try converter.convert(
                    input: candidate.source,
                    output: destination,
                    options: options,
                    onStart: { [weak self] process in
                        guard let self else { return }
                        self.lock.lock()
                        self._runningConversion = process
                        self.lock.unlock()
                    },
                    progress: { [weak self] progress in
                        self?.update {
                            $0.convertProgress = progress.fraction
                            if let speed = progress.speed {
                                $0.convertDetail = String(format: "%.0f %% · %.1f×",
                                                          progress.fraction * 100, speed)
                            }
                        }
                    }
                )
                done += 1
                log.append(RenameLogEntry(oldName: candidate.fileName,
                                          newName: destination.lastPathComponent,
                                          status: .converted))
            } catch {
                failed += 1
                // A half-written output is worse than none: it would look like
                // a finished file to a media server.
                try? FileManager.default.removeItem(at: destination)
                log.append(RenameLogEntry(oldName: candidate.fileName,
                                          newName: destination.lastPathComponent,
                                          status: .failure,
                                          errorDescription: Self.describe(error)))
            }
            lock.lock(); _runningConversion = nil; lock.unlock()
        }

        let converted = Set(pending.prefix(done + failed).map(\.id))
        lock.lock()
        _convertible.removeAll { converted.contains($0.id) }
        let stopped = _cancelConversions
        // As for transfers, and the declaration of this flag already says
        // why: it is "deliberately not cleared when a run starts" so that a
        // cancel pressed while a run was still queued is not lost. Clearing
        // it unconditionally at the end of a run lost it anyway, and the
        // queued run re-encoded everything the user had already stopped.
        if _queuedConversionRuns == 0 { _cancelConversions = false }
        lock.unlock()

        update {
            $0.busy = false
            $0.converting = false
            $0.convertProgress = 1
            $0.currentFile = nil
            $0.convertDetail = nil
            $0.pendingConversions = 0
            $0.hasError = failed > 0
            $0.lastResult = Text.s("Konvertiert \(done)", "Converted \(done)")
                + (failed > 0
                    ? Text.s(", \(failed) fehlgeschlagen", ", \(failed) failed") : "")
                + (stopped ? Text.s(" — vorzeitig gestoppt", " — stopped early") : "")
                + Text.s(". Die Originale sind noch da.",
                         ". The originals are still there.")
        }
        refreshSnapshotCounts()
    }

    private func cancelConversions() {
        lock.lock()
        // Only arm the flag when there is something it can apply to: a run in
        // flight, or one waiting on the queue. Otherwise a stray press while
        // idle would sit there and stop the next run the user asks for.
        let hasTarget = _runningConversion != nil || _queuedConversionRuns > 0
        if hasTarget { _cancelConversions = true }
        let process = _runningConversion
        lock.unlock()

        guard hasTarget else {
            update { $0.lastResult = Text.s("Es konvertiert gerade nichts.",
                                            "Nothing is converting.") }
            return
        }
        // End the encoder now rather than waiting out a long file.
        process?.terminate()
        update {
            $0.lastResult = process == nil
                ? Text.s("Stoppt vor der nächsten Datei.",
                         "Stopping before the next file.")
                : Text.s("Stoppt nach der aktuellen Datei.",
                         "Stopping after the current file.")
        }
    }

    /// Drops a cancel that has nothing left to act on, so it cannot carry over
    /// into the next run.
    private func clearCancelRequest() {
        lock.lock(); _cancelConversions = false; lock.unlock()
    }

    // MARK: Fetching from a URL

    /// Downloads one URL into the import folder, then scans.
    ///
    /// The scan is the point: the file lands where everything else lands,
    /// and the existing identify–propose–rename–send pipeline takes it from
    /// there. Nothing about a downloaded file is special afterwards.
    private func downloadURL(_ url: String) {
        lock.lock(); _queuedDownloads = max(0, _queuedDownloads - 1); lock.unlock()

        let settings = self.settings
        guard !settings.sourceFolder.isEmpty else {
            clearDownloadCancelRequest()
            update {
                $0.hasError = true
                $0.lastResult = Text.s(
                    "Es ist kein Importordner eingestellt, in den geladen werden könnte.",
                    "No import folder is set, so there is nowhere to download to.")
            }
            return
        }
        let importFolder = URL(fileURLWithPath: settings.sourceFolder, isDirectory: true)

        lock.lock()
        let alreadyCancelled = _cancelDownload
        _cancelDownload = false
        lock.unlock()
        if alreadyCancelled {
            update { $0.lastResult = Text.s(
                "Der Download wurde abgebrochen, bevor er begann.",
                "The download was cancelled before it started.") }
            return
        }

        update {
            $0.busy = true
            $0.downloading = true
            $0.downloadProgress = nil
            $0.downloadDetail = "Wird geladen …"
            $0.hasError = false
        }

        // The ffmpeg the user configured for conversion, so a download and
        // a conversion cannot end up using two different binaries.
        let downloader = VideoDownloader(
            tools: .locate(configuredFFmpeg: settings.conversion.ffmpegPath))
        do {
            let arrival = try downloader.download(
                url, into: importFolder,
                onStart: { [weak self] process in
                    guard let self else { return }
                    self.lock.lock()
                    self._runningDownload = process
                    self.lock.unlock()
                },
                progress: { [weak self] progress in
                    self?.update {
                        $0.downloadProgress = progress.fraction
                        $0.downloadDetail = Self.describe(progress)
                    }
                }
            )
            lock.lock(); _runningDownload = nil; lock.unlock()

            let file = arrival.file
            // Said plainly rather than reported as a download. With
            // `--no-overwrites` yt-dlp exits 0 and prints the path of the
            // file that was already there, which looks identical to a real
            // download — so "Geladen:" was being claimed for a file
            // nothing had fetched, and a page whose contents had changed
            // since would never be fetched again.
            let message = arrival.wasAlreadyThere
                ? "Lag schon im Importordner, nichts neu geladen: "
                    + file.lastPathComponent
                : "Geladen: " + file.lastPathComponent
            log.append(RenameLogEntry(oldName: url, newName: file.lastPathComponent,
                                      status: arrival.wasAlreadyThere
                                          ? .skipped : .downloaded))
            update {
                $0.busy = false
                $0.downloading = false
                $0.downloadProgress = 1
                $0.downloadDetail = nil
                $0.lastResult = message
            }
            // Straight into the ordinary pipeline.
            scanSourceFolder()
        } catch {
            lock.lock()
            _runningDownload = nil
            let stopped = _cancelDownload
            _cancelDownload = false
            lock.unlock()

            let message = stopped
                ? "Der Download wurde abgebrochen."
                : Self.describe(error)
            log.append(RenameLogEntry(oldName: url, newName: "—", status: .failure,
                                      errorDescription: message))
            update {
                $0.busy = false
                $0.downloading = false
                $0.downloadProgress = nil
                $0.downloadDetail = nil
                $0.hasError = !stopped
                $0.lastResult = message
            }
        }
    }

    /// "12,4 MB von 48,0 MB · 1,2 MB/s · noch 0:32", leaving out whatever
    /// the tool did not report rather than inventing it.
    static func describe(_ progress: VideoDownloader.Progress) -> String {
        var parts: [String] = []
        if let done = progress.downloadedBytes {
            if let total = progress.totalBytes {
                parts.append("\(bytes(done)) von \(bytes(total))")
            } else {
                parts.append(bytes(done))
            }
        }
        if let speed = progress.bytesPerSecond, speed > 0 {
            parts.append("\(bytes(Int64(speed)))/s")
        }
        if let eta = progress.secondsRemaining, eta > 0 {
            parts.append(String(format: "noch %d:%02d", eta / 60, eta % 60))
        }
        return parts.isEmpty ? "Wird geladen …" : parts.joined(separator: " · ")
    }

    static func bytes(_ count: Int64) -> String {
        let units = ["B", "kB", "MB", "GB", "TB"]
        var value = Double(count)
        var unit = 0
        while value >= 1000, unit < units.count - 1 { value /= 1000; unit += 1 }
        return unit == 0
            ? "\(count) B"
            : String(format: "%.1f %@", value, units[unit])
    }

    private func cancelDownload() {
        lock.lock()
        let hasTarget = _runningDownload != nil || _queuedDownloads > 0
        if hasTarget { _cancelDownload = true }
        let process = _runningDownload
        lock.unlock()

        guard hasTarget else {
            update { $0.lastResult = Text.s("Es läuft kein Download.",
                                            "No download is running.") }
            return
        }
        process?.terminate()
        update { $0.lastResult = Text.s("Der Download wird abgebrochen.",
                                        "The download is being cancelled.") }
    }

    private func clearDownloadCancelRequest() {
        lock.lock(); _cancelDownload = false; lock.unlock()
    }

    /// Whether a download cancel is armed. Only for tests.
    var downloadCancelIsArmedForTesting: Bool {
        lock.lock(); defer { lock.unlock() }; return _cancelDownload
    }

    // MARK: The traffic light

    /// The lamps, worked out from what is on this machine right now plus the
    /// last answer each service gave.
    public var systemChecks: [SystemCheck] {
        lock.lock()
        let probes = _probes
        let settings = _settings
        lock.unlock()
        return SystemChecks.all(settings: settings,
                                tools: RemoteTools.locate(),
                                ffmpegAvailable: ffmpegAvailable,
                                secrets: secretStore.configuredKeys(),
                                probes: probes,
                                // From the snapshot rather than recomputed:
                                // this says whether the tick is actually
                                // armed, which is the thing worth a lamp.
                                nextScheduledRun: snapshot.nextScheduledRun)
    }

    private func record(_ subject: ProbeSubject, ok: Bool, detail: String) {
        lock.lock()
        _probes[subject] = ProbeResult(ok: ok, detail: detail)
        lock.unlock()
    }

    /// Only for tests: proposals, without needing a scan and a real folder.
    func setItemsForTesting(_ items: [RenameItem]) {
        lock.lock(); _items = items; lock.unlock()
        refreshSnapshotCounts()
    }

    /// Only for tests: the probe results a run would otherwise have to reach
    /// a server to produce.
    func recordProbeForTesting(_ subject: ProbeSubject, ok: Bool, detail: String) {
        record(subject, ok: ok, detail: detail)
    }

    private func testRemote() {
        let target = settings.remote
        guard target.isEnabled else {
            update { $0.lastResult = Text.s("Der Server ist nicht eingeschaltet.",
                                            "The server is not switched on.") }
            return
        }
        let problems = target.problems()
        guard problems.isEmpty else {
            let message = problems.map(\.message).joined(separator: " ")
            record(.remote, ok: false, detail: message)
            update { $0.hasError = true; $0.lastResult = message }
            return
        }
        var password: String?
        if target.authentication == .password {
            password = secretStore.value(for: .remotePassword)
            guard let stored = password, !stored.isEmpty else {
                let message = Text.s(
                    "Für die Anmeldung per Passwort ist keines gespeichert.",
                    "Password login is selected but no password is stored.")
                record(.remote, ok: false, detail: message)
                update { $0.hasError = true; $0.lastResult = message }
                return
            }
        }
        update { $0.lastResult = Text.s("Server wird geprüft …", "Testing the server…") }
        let outcome = RemoteTransfer().check(target, password: password)
        record(.remote, ok: outcome.ok, detail: outcome.detail)
        update {
            $0.hasError = !outcome.ok
            $0.lastResult = outcome.ok
                ? Text.s("Der Server antwortet. ", "The server answers. ") + outcome.detail
                : Text.s("Der Server antwortet nicht: ",
                         "The server does not answer: ") + outcome.detail
        }
    }

    /// Every test, one after another. Each is skipped when the thing it tests
    /// is not in use, so pressing this with a plain offline setup does not
    /// produce three complaints about services nobody asked for.
    private func checkEverything() {
        let settings = self.settings
        if settings.identification == .localLLM { testLocalLLM() }
        if !settings.jellyfinBaseURL.isEmpty { testJellyfin() }
        if settings.remote.isEnabled { testRemote() }

        let checks = systemChecks
        update {
            $0.hasError = SystemChecks.worst(checks) == .failed
            $0.lastResult = Text.s("Prüfung fertig: ", "Check finished: ")
                + SystemChecks.summary(checks)
        }
    }

    // MARK: Sending to the remote library

    /// Every file of one proposal and where it goes on the server.
    ///
    /// Companions keep the primary's folder and their own name, which is what
    /// the planner does locally — computed from `proposedRelativePath` rather
    /// than from the companion's absolute destination, so an item whose
    /// output root was never set still gets a sensible remote path.
    /// Size in bytes, or nil when the file is not there.
    static func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    /// Which of the server's three paths this item belongs under.
    ///
    /// The primary decides for its companions too: a subtitle belongs beside
    /// its film, whatever the subtitle file itself looks like.
    static func remoteLibrary(for item: RenameItem) -> RemoteTarget.Library {
        RemoteTarget.Library.of(item.mediaFile.url, kind: item.mediaFile.parsed.kind)
    }

    static func remoteTransfers(for item: RenameItem)
        -> [(local: URL, relative: String, library: RemoteTarget.Library)] {
        let library = remoteLibrary(for: item)
        var sends: [(local: URL, relative: String, library: RemoteTarget.Library)] = [
            (item.mediaFile.url, item.proposedRelativePath, library)
        ]
        let folder = (item.proposedRelativePath as NSString).deletingLastPathComponent
        for move in item.companionMoves {
            let name = move.destination.lastPathComponent
            sends.append((move.source, folder.isEmpty ? name : folder + "/" + name,
                          library))
        }
        return sends
    }

    /// Copies the ticked files to the remote library, sorted into the folders
    /// the proposals name.
    ///
    /// A copy, not a move: the local file stays unless the user has ticked
    /// "remove the local copy".
    ///
    /// Undoable only in the sense that the local file is still here. What
    /// arrived may have replaced something — neither rsync nor sftp is told
    /// to refuse an existing file unless the conflict policy says to skip —
    /// and nothing here can put that back. Two proposals that resolve to
    /// the same remote path are refused outright rather than silently
    /// collapsing into one file on the server.
    private func transferFiles(accepting: Set<UUID>) {
        lock.lock(); _queuedTransferRuns = max(0, _queuedTransferRuns - 1); lock.unlock()
        send(items.filter { accepting.contains($0.id) })
    }

    /// Sends the given items, which need not be in `items` any more.
    ///
    /// Taking the items rather than their ids is what lets an unattended run
    /// send the files it has just renamed: by then they have left `items` and
    /// moved on disk, so there is nothing left to look up.
    private func send(_ requested: [RenameItem]) {
        let settings = self.settings
        let target = settings.remote
        guard target.isEnabled else {
            clearTransferCancelRequest()
            update { $0.lastResult = Text.s(
                "Der Server ist in den Einstellungen nicht aktiviert.",
                "The server is not switched on in the settings.") }
            return
        }
        let problems = target.problems()
        guard problems.isEmpty else {
            clearTransferCancelRequest()
            update {
                $0.hasError = true
                $0.lastResult = Text.s("Die Servereinstellungen sind unvollständig: ",
                                       "The server settings are incomplete: ")
                    + problems.map(\.message).joined(separator: " ")
            }
            return
        }

        // Asked for before anything is sent: finding out halfway through that
        // there is no password means half a library in two places.
        var password: String?
        if target.authentication == .password {
            password = secretStore.value(for: .remotePassword)
            guard let stored = password, !stored.isEmpty else {
                clearTransferCancelRequest()
                update {
                    $0.hasError = true
                    $0.lastResult = Text.s(
                        "Für die Anmeldung per Passwort ist keines gespeichert.",
                        "Password login is selected but no password is stored.")
                }
                return
            }
        }

        var pending = requested
        guard !pending.isEmpty else {
            clearTransferCancelRequest()
            update { $0.lastResult = Text.s(
                "Es war nichts angehakt, also wurde nichts gesendet.",
                "No files were ticked, so nothing was sent.") }
            return
        }

        // Two ticked proposals that resolve to the same remote path would
        // arrive one on top of the other, leaving one file where the user
        // had two — and, with "delete the local copy" on, destroying both
        // originals. Refused, with both named, rather than resolved
        // silently: which of a 1080p and a 720p rip to keep is not a
        // decision this code should make on its own.
        var collided = false
        var byDestination: [String: [RenameItem]] = [:]
        for item in pending {
            // Keyed by the path a transfer would actually write, not by the
            // relative path: with a path per kind, two files can share a
            // relative path and land in different libraries without
            // colliding at all.
            let key = RemoteCommand.remotePath(
                item.proposedRelativePath,
                under: target.path(for: Self.remoteLibrary(for: item)))
            byDestination[key, default: []].append(item)
        }
        let collisions = byDestination.filter { $0.value.count > 1 }
        if !collisions.isEmpty {
            let names = collisions.values.flatMap { $0 }
                .map(\.originalFileName).sorted().joined(separator: ", ")
            let colliding = Set(collisions.values.flatMap { $0 }.map(\.id))
            pending = pending.filter { !colliding.contains($0.id) }
            collided = true
            update {
                $0.hasError = true
                $0.lastResult = Text.s(
                    "Mehrere Dateien sollen an dieselbe Stelle auf dem Server: " + names
                        + ". Diese wurden nicht gesendet — bitte eine davon abwählen "
                        + "oder umbenennen.",
                    "Several files would go to the same place on the server: " + names
                        + ". They were not sent — please untick or rename one of them.")
            }
            guard !pending.isEmpty else {
                clearTransferCancelRequest()
                return
            }
        }

        lock.lock(); _transferRunning = true; lock.unlock()
        defer { lock.lock(); _transferRunning = false; lock.unlock() }

        let transfer = RemoteTransfer()
        var sent = 0
        var failed = 0
        var removed = 0
        var finished: [UUID] = []

        for (index, item) in pending.enumerated() {
            lock.lock()
            let cancelled = _cancelTransfers
            lock.unlock()
            if cancelled { break }

            let sends = Self.remoteTransfers(for: item)
            var itemFailed = false
            // What actually arrived, so the deletion below can be driven by
            // what happened rather than by what was planned.
            var arrived: [URL] = []

            for (offset, (local, relative, library)) in sends.enumerated() {
                lock.lock()
                let stopNow = _cancelTransfers
                lock.unlock()
                if stopNow { itemFailed = true; break }
                let isPrimary = offset == 0
                // A companion that has since been deleted is not a failure of
                // the transfer. The primary vanishing is: without this the
                // item counted as finished, left the list, and its subtitle
                // was deleted while the video had gone nowhere.
                guard let before = Self.fileSize(local) else {
                    log.append(RenameLogEntry(
                        oldName: local.lastPathComponent, newName: relative,
                        status: isPrimary ? .failure : .skipped,
                        errorDescription: Text.s("Die Datei ist nicht mehr da.",
                                                 "The file is no longer there.")))
                    if isPrimary {
                        // Counted, not just flagged: `hasError` is derived
                        // from this, and without it the run ended reporting
                        // no error at all — "0 Dateien gesendet." with a
                        // green badge, for a file that was lost.
                        failed += 1
                        itemFailed = true
                        break
                    }
                    continue
                }
                update {
                    $0.busy = true
                    $0.transferring = true
                    $0.transferProgress = Double(index) / Double(pending.count)
                    $0.currentFile = local.lastPathComponent
                    $0.pendingTransfers = pending.count - index - 1
                    // sftp prints no progress at all — it draws its meter
                    // only to a terminal, and never in batch mode. Saying so
                    // beats a bar that sits at the same number for ten
                    // minutes and looks like a stall.
                    $0.transferDetail = target.transport.reportsProgress
                        ? nil : Text.s("läuft – SFTP meldet keinen Fortschritt",
                                       "running – SFTP reports no progress")
                }
                do {
                    try transfer.send(
                        local, relativePath: relative, library: library,
                        to: target, password: password,
                        // "Skip the file" is a promise about the server's
                        // copy too, not only about a local rename.
                        keepExisting: settings.conflictPolicy == .skip,
                        onStart: { [weak self] process in
                            guard let self else { return }
                            self.lock.lock()
                            self._runningTransfer = process
                            self.lock.unlock()
                        },
                        progress: { [weak self] progress in
                            // Within this file, scaled into the whole run, so
                            // the bar moves once from start to finish rather
                            // than resetting on every file.
                            let whole = (Double(index) + progress.fraction)
                                / Double(pending.count)
                            self?.update {
                                $0.transferProgress = whole
                                $0.transferDetail = [
                                    "\(Int((progress.fraction * 100).rounded())) %",
                                    progress.speed,
                                ].compactMap { $0 }.joined(separator: " · ")
                            }
                        }
                    )
                    // A file that grew or shrank while it was being sent
                    // was still being written — a downloader had not
                    // finished with it — so what arrived is a truncated
                    // copy. rsync exits 0 for that quite happily.
                    let after = Self.fileSize(local)
                    if after != before {
                        failed += 1
                        itemFailed = true
                        log.append(RenameLogEntry(
                            oldName: local.lastPathComponent, newName: relative,
                            status: .failure,
                            errorDescription: Text.s(
                                "Die Datei wurde während der Übertragung noch geschrieben; "
                                    + "was angekommen ist, ist unvollständig. Erneut "
                                    + "senden, wenn der Download fertig ist.",
                                "The file was still being written during the transfer; "
                                    + "what arrived is incomplete. Send it again once the "
                                    + "download has finished.")))
                    } else {
                        sent += 1
                        arrived.append(local)
                        log.append(RenameLogEntry(oldName: local.lastPathComponent,
                                                  newName: relative,
                                                  status: .sent))
                    }
                } catch RemoteTransfer.Failure.alreadyThere(let remote) {
                    // The policy says skip, and the server has it. Not a
                    // failure — but not a success either, so the item stays
                    // on the list and nothing local is deleted for it.
                    itemFailed = true
                    log.append(RenameLogEntry(oldName: local.lastPathComponent,
                                              newName: relative,
                                              status: .skipped,
                                              errorDescription: Text.s(
                                                "Liegt schon auf dem Server: \(remote)",
                                                "Already on the server: \(remote)")))
                } catch {
                    failed += 1
                    itemFailed = true
                    log.append(RenameLogEntry(oldName: local.lastPathComponent,
                                              newName: relative,
                                              status: .failure,
                                              errorDescription: Self.describe(error)))
                }
                lock.lock(); _runningTransfer = nil; lock.unlock()
            }

            // Only a proposal whose every file arrived is taken off the list
            // and, if asked, removed here: a half-sent item must stay visible
            // so it can be sent again.
            if !itemFailed {
                finished.append(item.id)
                if target.removeLocalAfterSend {
                    // `arrived`, never `sends`: the planned list includes
                    // files that were skipped, that failed, and that were
                    // never there. Deleting from it destroyed local copies
                    // of files the server had never received.
                    for local in arrived {
                        do {
                            try FileManager.default.removeItem(at: local)
                            removed += 1
                        } catch {
                            log.append(RenameLogEntry(
                                oldName: local.lastPathComponent,
                                newName: "—",
                                status: .failure,
                                errorDescription: Text.s(
                                    "Gesendet, aber die lokale Datei ließ sich nicht "
                                        + "löschen: ",
                                    "Sent, but the local file could not be deleted: ")
                                    + Self.describe(error)))
                        }
                    }
                }
            }
        }

        let done = Set(finished)
        lock.lock()
        _items.removeAll { done.contains($0.id) }
        let stopped = _cancelTransfers
        // Only when no other run is waiting. The page redirects the moment a
        // button is pressed, so pressing "send" twice leaves two runs on the
        // queue; a cancel during the first was armed for both — that is why
        // `cancelTransfers` arms it when `_queuedTransferRuns > 0`. Clearing
        // it here unconditionally threw that away, and the queued run then
        // sent every file the cancel was meant to save and, with "remove the
        // local copy" on, deleted each original afterwards. The interface had
        // already confirmed the stop.
        if _queuedTransferRuns == 0 { _cancelTransfers = false }
        lock.unlock()

        update {
            $0.busy = false
            $0.transferring = false
            $0.transferProgress = 1
            $0.transferDetail = nil
            $0.currentFile = nil
            $0.pendingTransfers = 0
            // `collided` too: the refusal set hasError and this line used
            // to clear it again, so the warning vanished with the run.
            $0.hasError = failed > 0 || collided
            $0.lastResult = Text.s("\(sent) Datei\(sent == 1 ? "" : "en") gesendet",
                                   "\(sent) file\(sent == 1 ? "" : "s") sent")
                + (failed > 0
                    ? Text.s(", \(failed) fehlgeschlagen", ", \(failed) failed") : "")
                + (stopped ? Text.s(" — vorzeitig gestoppt", " — stopped early") : "")
                + (target.removeLocalAfterSend
                    ? Text.s(", \(removed) lokal gelöscht.",
                             ", \(removed) deleted locally.")
                    : Text.s(". Die lokalen Dateien sind noch da.",
                             ". The local files are still there."))
        }
        refreshSnapshotCounts()
    }

    private func cancelTransfers() {
        lock.lock()
        // `_transferRunning` as well as the process: between two files there
        // is no process, and the queued count was already spent on the first
        // line of the run — so a cancel pressed in that gap used to be
        // dropped, with the interface reporting that nothing was running
        // while the next file went out (and, with the setting on, while the
        // last one was deleted).
        let hasTarget = _runningTransfer != nil || _queuedTransferRuns > 0 || _transferRunning
        if hasTarget { _cancelTransfers = true }
        let process = _runningTransfer
        lock.unlock()

        guard hasTarget else {
            update { $0.lastResult = Text.s("Es läuft keine Übertragung.",
                                            "No transfer is running.") }
            return
        }
        // rsync leaves a partial file behind on purpose, so the next run
        // picks up where this one stopped instead of starting over.
        process?.terminate()
        update {
            $0.lastResult = process == nil
                ? Text.s("Stoppt vor der nächsten Datei.",
                         "Stopping before the next file.")
                : Text.s("Stoppt nach der aktuellen Datei.",
                         "Stopping after the current file.")
        }
    }

    /// Clears a cancel request, unless it still covers a queued run.
    ///
    /// Called on the paths where a run gives up before sending anything — no
    /// server, no password, nothing ticked. Those are exactly the paths where
    /// the cancel is still owed to the run behind this one, and clearing it
    /// unconditionally handed that run a clean slate.
    private func clearTransferCancelRequest() {
        lock.lock()
        if _queuedTransferRuns == 0 { _cancelTransfers = false }
        lock.unlock()
    }

    /// Only for tests: arm a cancel with `queuedRuns` still waiting, end a
    /// run, and report whether the cancel survived.
    func cancelSurvivesRunEndForTesting(queuedRuns: Int) -> Bool {
        lock.lock()
        _queuedTransferRuns = queuedRuns
        _cancelTransfers = true
        lock.unlock()
        clearTransferCancelRequest()
        lock.lock(); defer { lock.unlock() }; return _cancelTransfers
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: Watching the import folder

    /// True while the import folder is being watched.
    var isWatching: Bool { queue.sync { watchTimer != nil } }

    /// Starts or stops watching to match the settings. Runs on `queue`.
    private func updateWatchState() {
        let settings = self.settings
        let shouldWatch = settings.watchSourceFolder && !settings.sourceFolder.isEmpty

        if shouldWatch, watchTimer == nil {
            watchScanner.reset()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(Int(watchInterval * 1000)),
                           repeating: watchInterval)
            timer.setEventHandler { [weak self] in self?.pollWatchFolder() }
            timer.resume()
            watchTimer = timer
        } else if !shouldWatch, watchTimer != nil {
            watchTimer?.cancel()
            watchTimer = nil
        }
        let watching = watchTimer != nil
        update { $0.watchActive = watching }
    }

    // MARK: Running by itself

    /// Why the schedule is being (re-)armed, which decides what happens to
    /// the last-run time.
    enum ScheduleArming {
        /// The program has just started: take the last-run time from disk, so
        /// a run missed while the machine was off still happens.
        case startup
        /// Settings were saved but the schedule itself is unchanged: leave the
        /// last-run time alone.
        case settingsSaved
        /// The user has just changed the schedule: treat now as the last run,
        /// so pressing Apply never sets an unattended rename going twenty
        /// seconds later — which is what it used to do whenever the schedule
        /// had been switched off and on again.
        case scheduleChanged
    }

    /// Starts or stops the schedule's minute tick to match the settings.
    ///
    /// A tick that asks "is it due yet", rather than a timer armed for the
    /// far future. A long timer does not survive the machine sleeping, a
    /// clock correction or a time-zone change, and all three happen to a
    /// media server. Asking once a minute costs nothing and is right
    /// afterwards.
    private func updateScheduleState(_ arming: ScheduleArming = .settingsSaved) {
        let schedule = settings.schedule
        let shouldRun = schedule.isEnabled && schedule.problems().isEmpty

        switch arming {
        case .startup:
            let stored = scheduleState.lastRun()
            lock.lock(); _lastScheduledRun = stored; lock.unlock()
            // Nothing recorded — first start, or an upgrade from a version
            // that kept it in memory. Start the clock now rather than
            // treating "never run" as "overdue".
            if stored == nil, shouldRun { recordScheduledRun(Date()) }
        case .scheduleChanged:
            if shouldRun { recordScheduledRun(Date()) }
        case .settingsSaved:
            break
        }

        if shouldRun, scheduleTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(20), repeating: .seconds(60))
            timer.setEventHandler { [weak self] in self?.runIfDue() }
            timer.resume()
            scheduleTimer = timer
        } else if !shouldRun, scheduleTimer != nil {
            scheduleTimer?.cancel()
            scheduleTimer = nil
        }
        // Read before `update`, never inside it: the lock is not recursive
        // and these accessors take it.
        let next = nextScheduledRun
        let last = lastScheduledRun
        update { $0.nextScheduledRun = next; $0.lastScheduledRun = last }
    }

    /// Stamps the last-run time, in memory and on disk together.
    private func recordScheduledRun(_ moment: Date) {
        lock.lock(); _lastScheduledRun = moment; lock.unlock()
        scheduleState.setLastRun(moment)
    }

    /// One unattended run, if one is due. Runs on the serial queue.
    private func runIfDue() {
        let schedule = settings.schedule
        lock.lock()
        let previousRun = _lastScheduledRun
        lock.unlock()
        guard schedule.isDue(at: Date(), lastRun: previousRun) else { return }

        // Under a lock on the configuration directory, because the window
        // and `mediafin` in a terminal share one and both now arm the
        // schedule at startup: without this they would both find the run
        // overdue and both rename.
        let ours = RunLock.withLock(at: configDirectory
            .appendingPathComponent("schedule-run.lock")) {
            // Stamped before the work, not after: a run that takes an hour
            // must not make the next one due the moment it finishes, and a
            // run that throws must not repeat every minute.
            recordScheduledRun(Date())

            log.append(RenameLogEntry(oldName: "Zeitplan", newName: schedule.summary,
                                      status: .skipped))
            performScheduledRun(schedule)
        }
        if !ours {
            // The other Mediafin is doing it. Its stamp is the shared
            // answer, so take that rather than asking again in a minute and
            // finding the same run still overdue.
            let stored = scheduleState.lastRun()
            lock.lock(); _lastScheduledRun = stored ?? Date(); lock.unlock()
        }
        // Read before `update`, never inside it: the lock is not recursive
        // and these accessors take it.
        let next = nextScheduledRun
        let last = lastScheduledRun
        update { $0.nextScheduledRun = next; $0.lastScheduledRun = last }
    }

    /// The work of one unattended run. Separate from `runIfDue` so the tests
    /// can run it without waiting for a timer or faking a clock.
    func performScheduledRun(_ schedule: Schedule) {
        // A scan that could not run at all — no import folder, the folder
        // gone, ffprobe missing — leaves the previous plan in place. Acting
        // on it would rename and send a list the user last saw hours ago,
        // against a folder that has moved on since. So the run stops here
        // and the reason it gives is the scan's own.
        guard scanSourceFolder() else { return }
        let scanned = items.filter(\.isAccepted)
        guard !scanned.isEmpty else { return }

        // Collected rather than written straight to `lastResult`, because
        // the rename and the send each replace that line with their own
        // summary — so a warning put there first vanished unread.
        var notes: [String] = []
        var failedSomething = false
        // `if`, not `guard … else { return }`: a return may not cross a
        // defer, and the compiler is right to say so.
        defer {
            if !notes.isEmpty {
                let appended = notes.joined(separator: " ")
                let bad = failedSomething
                update { snapshot in
                    if bad { snapshot.hasError = true }
                    let existing = snapshot.lastResult
                    snapshot.lastResult = existing.map { $0 + " " + appended } ?? appended
                }
            }
        }

        var toSend = scanned

        if schedule.alsoRename {
            // Without a library root the planner proposes a folder beside the
            // file itself, so an unattended run buries it one level deeper
            // every night: Film/Film.mkv, then Film/Film/Film.mkv. Somebody
            // looking at the proposal would see that; nobody is looking here.
            let (renameable, blocked) = Self.unattendedRenameable(scanned,
                                                                  settings: settings)
            if !blocked.isEmpty {
                failedSomething = true
                notes.append(Text.s(
                    "\(blocked.count) Datei" + (blocked.count == 1 ? " wurde" : "en wurden")
                        + " nicht umbenannt, weil der Zielordner in den Einstellungen "
                        + "fehlt — sonst landen sie in Unterordnern neben sich selbst.",
                    "\(blocked.count) file\(blocked.count == 1 ? " was" : "s were") not "
                        + "renamed because the target folder is missing from the settings "
                        + "— they would end up in subfolders beside themselves."))
                for item in blocked {
                    log.append(RenameLogEntry(
                        oldName: item.originalFileName, newName: "—",
                        status: .skipped,
                        errorDescription: Text.s(
                            "Geplanter Lauf: kein Zielordner gesetzt.",
                            "Scheduled run: no target folder is set.")))
                }
            }
            guard !renameable.isEmpty else { return }

            let outcome = applyRenames(accepting: Set(renameable.map(\.id)))
            // Only what actually moved, and from where it actually landed.
            // This used to re-scan the import folder instead, which finds
            // precisely the files whose rename had *failed* — so "also send"
            // sent the failures and left the library untouched.
            toSend = renameable.compactMap { item in
                guard let now = outcome?.landed[item.id] else { return nil }
                var moved = item
                moved.mediaFile.url = now
                return moved
            }
        }

        guard schedule.alsoSend else { return }
        guard settings.remote.isEnabled else {
            failedSomething = true
            notes.append(Text.s(
                "Senden war geplant, aber der Server ist abgeschaltet.",
                "Sending was scheduled, but the server is switched off."))
            return
        }
        // Reached whether or not renaming was asked for: "also send" used to
        // sit behind `guard alsoRename`, so ticking send on its own did
        // nothing at all while the summary promised it.
        guard !toSend.isEmpty else { return }
        send(toSend)
    }

    /// Of a scanned plan, the items an unattended run may safely rename, and
    /// the ones it must leave alone.
    ///
    /// Pure, so the rule is testable without a scheduler.
    static func unattendedRenameable(_ plan: [RenameItem],
                                     settings: WebSettings)
        -> (renameable: [RenameItem], blocked: [RenameItem]) {
        var renameable: [RenameItem] = []
        var blocked: [RenameItem] = []
        for item in plan {
            let hasRoot: Bool
            if settings.libraryMode == .music {
                hasRoot = !settings.musicFolder.isEmpty
            } else if item.mediaFile.parsed.kind == .episode {
                hasRoot = !settings.seriesFolder.isEmpty
            } else {
                hasRoot = !settings.moviesFolder.isEmpty
            }
            if hasRoot { renameable.append(item) } else { blocked.append(item) }
        }
        return (renameable, blocked)
    }

    /// When the next unattended run is due, for the interface to show.
    public var nextScheduledRun: Date? {
        let schedule = settings.schedule
        lock.lock(); let last = _lastScheduledRun; lock.unlock()
        return schedule.nextRun(after: last ?? Date())
    }

    /// When the last unattended run happened, for the interface to show.
    public var lastScheduledRun: Date? {
        lock.lock(); defer { lock.unlock() }; return _lastScheduledRun
    }

    /// Only for tests: pretend the last run happened then.
    func setLastScheduledRunForTesting(_ moment: Date?) {
        lock.lock(); _lastScheduledRun = moment; lock.unlock()
        scheduleState.setLastRun(moment)
    }

    /// Only for tests: one tick of the schedule, synchronously.
    func runIfDueForTesting() {
        queue.sync { self.runIfDue() }
    }

    /// Only for tests: waits for the work `init` handed to the queue.
    ///
    /// Arming the schedule happens there, so a test that reads the last-run
    /// time straight after constructing a coordinator would otherwise race
    /// it and pass or fail by luck.
    func waitForStartupForTesting() {
        queue.sync { }
    }

    /// Only for tests: whether the minute tick is armed.
    var scheduleIsArmedForTesting: Bool { queue.sync { scheduleTimer != nil } }

    /// Looks for files that have appeared since the last look.
    ///
    /// New files are only *offered*: they are scanned and proposed, never
    /// renamed on their own. Moving someone's files without them having seen
    /// the proposal is not something a watch setting should authorise.
    ///
    /// A file is reported only once its size has stayed the same between two
    /// polls (`WatchFolderScanner`), so a download still being written is not
    /// picked up half-finished. That means a new file shows up one interval
    /// after it finishes, which is the right trade.
    private func pollWatchFolder() {
        let settings = self.settings
        guard settings.watchSourceFolder, !settings.sourceFolder.isEmpty,
              !snapshot.busy, !snapshot.renaming else { return }

        let root = URL(fileURLWithPath: settings.sourceFolder, isDirectory: true)
        let appeared = watchScanner.poll(directory: root).filter(VideoFileTypes.isVideo)
        guard !appeared.isEmpty else { return }

        scanSourceFolder()
        let count = appeared.count
        update {
            $0.lastResult = "\(count) new file\(count == 1 ? "" : "s") appeared in the import "
                + "folder and \($0.totalItems == 1 ? "is" : "are") waiting for you to confirm."
        }
    }

    /// Runs one poll synchronously. Tests only — the real one is on a timer.
    func pollWatchFolderForTesting() {
        queue.sync { self.pollWatchFolder() }
    }

    // MARK: Providers

    /// The provider chain implied by the settings. Returns nil when titles are
    /// only parsed from the file name, so no lookup happens at all.
    func enrichmentProvider(_ settings: WebSettings) -> MetadataProvider? {
        switch settings.identification {
        case .offline:
            return nil
        case .localLLM:
            return localLLMProvider(settings)
        case .tmdb:
            guard let key = secretStore.value(for: .tmdbAPIKey) else { return nil }
            return TMDbMetadataProvider(apiKey: key)
        }
    }

    func localLLMProvider(_ settings: WebSettings) -> LocalLLMMetadataProvider? {
        guard !settings.localLLMBaseURL.isEmpty, !settings.localLLMModel.isEmpty else {
            return nil
        }
        return LocalLLMMetadataProvider(config: .init(
            baseURL: settings.localLLMBaseURL,
            model: settings.localLLMModel,
            apiKey: secretStore.value(for: .localLLMAPIKey) ?? ""
        ))
    }

    // MARK: Snapshot

    private func update(_ change: (inout StatusSnapshot) -> Void) {
        lock.lock()
        change(&_snapshot)
        _snapshot.updated = Date()
        lock.unlock()
    }

    private func refreshSnapshotCounts() {
        let all = items
        let count = all.count
        let accepted = all.filter(\.isAccepted).count
        let settings = self.settings
        let hasJellyfin = !settings.jellyfinBaseURL.isEmpty
            && secretStore.value(for: .jellyfinToken) != nil
        let done = log.entries.filter { $0.status == .success }.count
        update {
            $0.totalItems = count
            // The ones that would actually be acted on, which is not the
            // same as the number proposed — it used to be set to `count`,
            // so the window printed the same number twice.
            $0.ready = accepted
            $0.done = done
            // Deliberately NOT set here. `updateWatchState` sets it from
            // whether the timer is really armed, and this runs after it in
            // `save` — so writing the raw setting back meant that with
            // watching on and no import folder set, nothing was polled while
            // every lamp and the status row said "active".
            //   $0.watchActive = settings.watchSourceFolder
            $0.jellyfinConfigured = hasJellyfin
            $0.remoteConfigured = settings.remote.isEnabled
                && settings.remote.problems().isEmpty
        }
    }

    // MARK: Bridging async work onto the serial queue

    /// Runs async work to completion. Called only from the coordinator's own
    /// queue, never from a request, so blocking here holds nothing up.
    private func runAndWait(_ work: @escaping @Sendable () async -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await work()
            semaphore.signal()
        }
        semaphore.wait()
    }

    private func runAndWaitReturning<T: Sendable>(
        _ work: @escaping @Sendable () async -> T
    ) -> T? {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            box.set(await work())
            semaphore.signal()
        }
        semaphore.wait()
        return box.get()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
