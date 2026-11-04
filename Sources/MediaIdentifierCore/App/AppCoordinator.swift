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
    private var _lastScheduledRun: Date?

    private let settingsStore: SettingsStore
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
        settingsStore = SettingsStore(directory: configDirectory)
        secretStore = SecretStore(directory: configDirectory)
        log = RenameLog(url: configDirectory.appendingPathComponent("rename-log.json"))
        journal = RenameJournal(url: configDirectory.appendingPathComponent("undo-journal.json"))
        executor = RenameExecutor(log: log, journal: journal)

        let loaded = settingsStore.load()
        _settings = loaded.settings
        if case .unreadable(let detail) = loaded.state {
            settingsProblem = detail
        } else {
            settingsProblem = nil
        }
        // A secrets file left readable by other accounts is a problem whether
        // or not it is read today.
        if secretStore.tightenPermissionsIfNeeded() {
            _snapshot.lastResult = """
            The credentials file was readable by other accounts; its permissions \
            have been corrected. Consider replacing the stored keys.
            """
        }
        refreshSnapshotCounts()
        // Not on the queue yet, so hand it over rather than touching the timer.
        queue.async { [weak self] in self?.updateWatchState() }
    }

    deinit {
        watchTimer?.cancel()
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
        case .saveSettings, .setSecret, .setAllAccepted, .clearHistory,
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
            update { $0.lastResult = "Settings saved." }
            updateWatchState()
            updateScheduleState()
            // So the interface stops offering a "send to the server" button
            // the moment the server is switched off, rather than at the next
            // scan.
            refreshSnapshotCounts()
        } catch {
            update { $0.lastResult = "Settings could not be saved: \(error)" }
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
                    ? "\(key.label) removed."
                    : "\(key.label) stored."
            }
        } catch {
            update { $0.lastResult = "\(key.label) could not be stored." }
        }
    }

    // MARK: Connection tests

    private func testLocalLLM() {
        let settings = self.settings
        guard let provider = localLLMProvider(settings) else {
            update { $0.lastResult = "Enter the model server address and model name first." }
            return
        }
        update { $0.lastResult = "Testing the model server…" }
        runAndWait { [weak self] in
            do {
                let status = try await provider.verify()
                let message = Self.describe(status: status, service: "model server")
                // 2xx only. A 401 is an answer, not a working connection, and
                // a lamp that went green on it would be the panel lying.
                self?.record(.localLLM, ok: (200..<300).contains(status), detail: message)
                self?.update { $0.lastResult = message }
            } catch {
                let message = "The model server could not be reached: "
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
            update { $0.lastResult = "Enter the Jellyfin address and API key first." }
            return
        }
        update { $0.lastResult = "Testing Jellyfin…" }
        runAndWait { [weak self] in
            do {
                let connector = try JellyfinConnector(serverURL: settings.jellyfinBaseURL,
                                                      apiKey: apiKey)
                let status = try await connector.verify()
                let message = Self.describe(status: status, service: "Jellyfin")
                self?.record(.jellyfin, ok: (200..<300).contains(status), detail: message)
                self?.update { $0.lastResult = message }
            } catch {
                let message = "Jellyfin could not be reached: " + Self.reason(for: error)
                self?.record(.jellyfin, ok: false, detail: message)
                self?.update { $0.lastResult = message }
            }
        }
    }

    /// Turns an HTTP status into something a user can act on.
    static func describe(status: Int, service: String) -> String {
        switch status {
        case 200..<300: return "The \(service) answered. The connection works."
        case 401, 403: return "The \(service) refused the key. Check the API key."
        case 404: return "The \(service) answered, but not on that address. Check the URL."
        case -1: return "The \(service) answered in a way that was not understood."
        default: return "The \(service) answered with status \(status)."
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

    private func scanSourceFolder() {
        let settings = self.settings
        let source = settings.sourceFolder
        guard !source.isEmpty else {
            update { $0.lastResult = "Set the import folder in the settings first." }
            return
        }
        let root = URL(fileURLWithPath: source, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            update { $0.lastResult = "The import folder does not exist: \(source)" }
            return
        }

        if settings.libraryMode == .music {
            scanForMusic(under: root, settings: settings)
            return
        }

        update { $0.busy = true; $0.convertStatus = "Looking for media…" }
        let urls = FolderScan.videoFiles(under: root)
        guard !urls.isEmpty else {
            lock.lock(); _items = []; lock.unlock()
            update {
                $0.busy = false
                $0.convertStatus = nil
                $0.lastResult = "No video files found in \(source)."
            }
            refreshSnapshotCounts()
            return
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
            $0.lastResult = "\(plan.count) file\(plan.count == 1 ? "" : "s") ready to rename."
        }
        refreshSnapshotCounts()
    }

    /// Proposes a place for every music file, from its own tags.
    ///
    /// Nothing is guessed. A file whose tags do not name an artist, an
    /// album and a title gets no proposal at all: filing it somewhere
    /// plausible puts it where the user will not think to look, which is
    /// worse than leaving it where they put it.
    private func scanForMusic(under root: URL, settings: WebSettings) {
        guard !settings.musicFolder.isEmpty else {
            update {
                $0.busy = false
                $0.hasError = true
                $0.lastResult = "Für den Musikmodus fehlt der Musikordner in den "
                    + "Einstellungen."
            }
            return
        }
        guard let reader = AudioTagReader() else {
            update {
                $0.busy = false
                $0.hasError = true
                $0.lastResult = "ffmpeg/ffprobe wurden nicht gefunden; ohne sie lassen "
                    + "sich die Tags nicht lesen: sudo apt install ffmpeg"
            }
            return
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

        lock.lock(); _items = plan; lock.unlock()
        update {
            $0.busy = false
            $0.convertStatus = nil
            $0.hasError = false
            if plan.isEmpty {
                $0.lastResult = urls.isEmpty
                    ? "Keine Musikdateien in \(root.path) gefunden."
                    : "\(urls.count) Musikdatei\(urls.count == 1 ? "" : "en") gefunden, "
                        + "aber keine mit genug Tags (Künstler, Album, Titel)."
            } else {
                $0.lastResult = "\(plan.count) Titel bereit"
                    + (unreadable > 0
                        ? " · \(unreadable) ohne ausreichende Tags übersprungen." : ".")
            }
        }
        refreshSnapshotCounts()
    }

    private func applyRenames(accepting: Set<UUID>?) {
        var plan = items
        guard !plan.isEmpty else {
            update { $0.lastResult = "Nothing to rename — scan the import folder first." }
            return
        }
        // The page sends the ids the user ticked. An empty selection means they
        // unticked everything, which must do nothing rather than everything.
        if let accepting {
            plan = plan.filter { accepting.contains($0.id) }
            guard !plan.isEmpty else {
                update { $0.lastResult = "No files were ticked, so nothing was renamed." }
                return
            }
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
            $0.hasError = outcome.failed > 0
            $0.lastResult = "Renamed \(outcome.succeeded), skipped \(outcome.skipped)"
                + (outcome.failed > 0 ? ", failed \(outcome.failed)" : "") + "."
        }
        if settings.libraryMode == .music { writeAlbumCovers(for: plan) }
        refreshSnapshotCounts()
        refreshJellyfinLibrary()
    }

    /// Writes each album's cover next to its tracks, once.
    ///
    /// From the file's own embedded picture, which is why this needs no
    /// network: most tagged music carries its art. An album that already
    /// has an image under any of the four names Jellyfin accepts is left
    /// alone — overwriting one the user chose would be presumptuous.
    private func writeAlbumCovers(for plan: [RenameItem]) {
        guard let reader = AudioTagReader() else { return }
        var done: Set<String> = []
        var written = 0

        for item in plan {
            let coverRelative = MusicNamer.coverPath(forTrackAt: item.proposedRelativePath)
            let folder = (coverRelative as NSString).deletingLastPathComponent
            guard done.insert(folder).inserted else { continue }

            let destination = item.outputRoot.appendingPathComponent(coverRelative)
            let albumFolder = destination.deletingLastPathComponent()
            // Any of folder/poster/cover/default, any of the image
            // extensions: Jellyfin accepts all of them, so any one of
            // them means this album is already covered.
            let existing = (try? FileManager.default.contentsOfDirectory(
                atPath: albumFolder.path)) ?? []
            if existing.contains(where: {
                AudioFileTypes.isCoverImage(URL(fileURLWithPath: $0))
            }) { continue }

            // The track has moved by now, so read the picture from where
            // it landed rather than from where it came from.
            let moved = item.outputRoot.appendingPathComponent(item.proposedRelativePath)
            let source = FileManager.default.fileExists(atPath: moved.path)
                ? moved : item.mediaFile.url
            if reader.extractCover(from: source, to: destination) { written += 1 }
        }

        guard written > 0 else { return }
        update {
            $0.lastResult = ($0.lastResult ?? "")
                + " \(written) Albumcover geschrieben."
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
                self?.update { $0.lastResult = ($0.lastResult ?? "") + " Jellyfin is rescanning." }
            } catch {
                self?.update {
                    $0.lastResult = ($0.lastResult ?? "")
                        + " Jellyfin could not be told to rescan: " + Self.reason(for: error)
                }
            }
        }
    }

    /// Ticks or unticks every proposal at once.
    private func setAllAccepted(_ accepted: Bool) {
        lock.lock()
        for index in _items.indices { _items[index].isAccepted = accepted }
        let count = _items.count
        lock.unlock()
        update {
            $0.lastResult = count == 0
                ? "Es gibt nichts zum Anhaken."
                : (accepted ? "Alle \(count) angehakt." : "Alle abgehakt.")
        }
    }

    private func undoLast() {
        let restored = executor.undoLast()
        update {
            $0.lastResult = restored == 0
                ? "There was nothing to undo."
                : "Put \(restored) file\(restored == 1 ? "" : "s") back."
        }
        refreshSnapshotCounts()
    }

    private func clearHistory() {
        log.clear()
        journal.clear()
        update { $0.lastResult = "History cleared." }
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
            update { $0.lastResult = "Set your library folders in the settings first." }
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
                ? "No files to convert were found."
                : "\(found.count) file\(found.count == 1 ? "" : "s") could be converted."
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
            update { $0.lastResult = "No files were ticked, so nothing was converted." }
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
        _cancelConversions = false
        lock.unlock()

        update {
            $0.busy = false
            $0.converting = false
            $0.convertProgress = 1
            $0.currentFile = nil
            $0.convertDetail = nil
            $0.pendingConversions = 0
            $0.hasError = failed > 0
            $0.lastResult = "Converted \(done)"
                + (failed > 0 ? ", \(failed) failed" : "")
                + (stopped ? " — stopped early" : "")
                + ". The originals are still there."
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
            update { $0.lastResult = "Nothing is converting." }
            return
        }
        // End the encoder now rather than waiting out a long file.
        process?.terminate()
        update {
            $0.lastResult = process == nil
                ? "Stopping before the next file."
                : "Stopping after the current file."
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
                $0.lastResult = "Es ist kein Importordner eingestellt, in den geladen "
                    + "werden könnte."
            }
            return
        }
        let importFolder = URL(fileURLWithPath: settings.sourceFolder, isDirectory: true)

        lock.lock()
        let alreadyCancelled = _cancelDownload
        _cancelDownload = false
        lock.unlock()
        if alreadyCancelled {
            update { $0.lastResult = "Der Download wurde abgebrochen, bevor er begann." }
            return
        }

        update {
            $0.busy = true
            $0.downloading = true
            $0.downloadProgress = nil
            $0.downloadDetail = "Wird geladen …"
            $0.hasError = false
        }

        let downloader = VideoDownloader()
        do {
            let file = try downloader.download(
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

            log.append(RenameLogEntry(oldName: url, newName: file.lastPathComponent,
                                      status: .downloaded))
            update {
                $0.busy = false
                $0.downloading = false
                $0.downloadProgress = 1
                $0.downloadDetail = nil
                $0.lastResult = "Geladen: \(file.lastPathComponent)"
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
            update { $0.lastResult = "Es läuft kein Download." }
            return
        }
        process?.terminate()
        update { $0.lastResult = "Der Download wird abgebrochen." }
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
                                probes: probes)
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
            update { $0.lastResult = "Der Server ist nicht eingeschaltet." }
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
                let message = "Für die Anmeldung per Passwort ist keines gespeichert."
                record(.remote, ok: false, detail: message)
                update { $0.hasError = true; $0.lastResult = message }
                return
            }
        }
        update { $0.lastResult = "Server wird geprüft …" }
        let outcome = RemoteTransfer().check(target, password: password)
        record(.remote, ok: outcome.ok, detail: outcome.detail)
        update {
            $0.hasError = !outcome.ok
            $0.lastResult = outcome.ok
                ? "Der Server antwortet. " + outcome.detail
                : "Der Server antwortet nicht: " + outcome.detail
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
            $0.lastResult = "Prüfung fertig: " + SystemChecks.summary(checks)
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

    static func remoteTransfers(for item: RenameItem) -> [(local: URL, relative: String)] {
        var sends: [(local: URL, relative: String)] = [
            (item.mediaFile.url, item.proposedRelativePath)
        ]
        let folder = (item.proposedRelativePath as NSString).deletingLastPathComponent
        for move in item.companionMoves {
            let name = move.destination.lastPathComponent
            sends.append((move.source, folder.isEmpty ? name : folder + "/" + name))
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

        let settings = self.settings
        let target = settings.remote
        guard target.isEnabled else {
            clearTransferCancelRequest()
            update { $0.lastResult = "Der Server ist in den Einstellungen nicht aktiviert." }
            return
        }
        let problems = target.problems()
        guard problems.isEmpty else {
            clearTransferCancelRequest()
            update {
                $0.hasError = true
                $0.lastResult = "Die Servereinstellungen sind unvollständig: "
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
                    $0.lastResult = "Für die Anmeldung per Passwort ist keines gespeichert."
                }
                return
            }
        }

        var pending = items.filter { accepting.contains($0.id) }
        guard !pending.isEmpty else {
            clearTransferCancelRequest()
            update { $0.lastResult = "Es war nichts angehakt, also wurde nichts gesendet." }
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
            byDestination[item.proposedRelativePath, default: []].append(item)
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
                $0.lastResult = "Mehrere Dateien sollen an dieselbe Stelle auf dem Server: "
                    + names + ". Diese wurden nicht gesendet — bitte eine davon abwählen "
                    + "oder umbenennen."
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

            for (offset, (local, relative)) in sends.enumerated() {
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
                        errorDescription: "Die Datei ist nicht mehr da."))
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
                        ? nil : "läuft – SFTP meldet keinen Fortschritt"
                }
                do {
                    try transfer.send(
                        local, relativePath: relative, to: target, password: password,
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
                            errorDescription: "Die Datei wurde während der Übertragung noch "
                                + "geschrieben; was angekommen ist, ist unvollständig. "
                                + "Erneut senden, wenn der Download fertig ist."))
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
                                              errorDescription: "Liegt schon auf dem "
                                                  + "Server: \(remote)"))
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
                                errorDescription: "Gesendet, aber die lokale Datei ließ sich "
                                    + "nicht löschen: " + Self.describe(error)))
                        }
                    }
                }
            }
        }

        let done = Set(finished)
        lock.lock()
        _items.removeAll { done.contains($0.id) }
        let stopped = _cancelTransfers
        _cancelTransfers = false
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
            $0.lastResult = "\(sent) Datei\(sent == 1 ? "" : "en") gesendet"
                + (failed > 0 ? ", \(failed) fehlgeschlagen" : "")
                + (stopped ? " — vorzeitig gestoppt" : "")
                + (target.removeLocalAfterSend
                    ? ", \(removed) lokal gelöscht."
                    : ". Die lokalen Dateien sind noch da.")
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
            update { $0.lastResult = "Es läuft keine Übertragung." }
            return
        }
        // rsync leaves a partial file behind on purpose, so the next run
        // picks up where this one stopped instead of starting over.
        process?.terminate()
        update {
            $0.lastResult = process == nil
                ? "Stoppt vor der nächsten Datei."
                : "Stoppt nach der aktuellen Datei."
        }
    }

    private func clearTransferCancelRequest() {
        lock.lock(); _cancelTransfers = false; lock.unlock()
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

    /// Starts or stops the schedule's minute tick to match the settings.
    ///
    /// A tick that asks "is it due yet", rather than a timer armed for the
    /// far future. A long timer does not survive the machine sleeping, a
    /// clock correction or a time-zone change, and all three happen to a
    /// media server. Asking once a minute costs nothing and is right
    /// afterwards.
    private func updateScheduleState() {
        let schedule = settings.schedule
        let shouldRun = schedule.isEnabled && schedule.problems().isEmpty

        if shouldRun, scheduleTimer == nil {
            // From now, so switching it on does not fire immediately.
            lock.lock()
            if _lastScheduledRun == nil { _lastScheduledRun = Date() }
            lock.unlock()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(20), repeating: .seconds(60))
            timer.setEventHandler { [weak self] in self?.runIfDue() }
            timer.resume()
            scheduleTimer = timer
        } else if !shouldRun, scheduleTimer != nil {
            scheduleTimer?.cancel()
            scheduleTimer = nil
        }
    }

    /// One unattended run, if one is due. Runs on the serial queue.
    private func runIfDue() {
        let schedule = settings.schedule
        lock.lock()
        let last = _lastScheduledRun
        lock.unlock()
        guard schedule.isDue(at: Date(), lastRun: last) else { return }

        // Stamped before the work, not after: a run that takes an hour
        // must not make the next one due the moment it finishes, and a
        // run that throws must not repeat every minute.
        lock.lock(); _lastScheduledRun = Date(); lock.unlock()

        log.append(RenameLogEntry(oldName: "Zeitplan", newName: schedule.summary,
                                  status: .skipped))
        scanSourceFolder()

        // Only what was asked for, and only the proposals the planner
        // accepted — an unattended run must not widen its own remit.
        guard schedule.alsoRename else { return }
        let accepted = Set(items.filter(\.isAccepted).map(\.id))
        guard !accepted.isEmpty else { return }
        applyRenames(accepting: accepted)

        guard schedule.alsoSend, settings.remote.isEnabled else { return }
        // applyRenames has emptied _items of what it moved, so the send
        // works from what the scan found, re-read after the rename.
        scanSourceFolder()
        let toSend = Set(items.filter(\.isAccepted).map(\.id))
        guard !toSend.isEmpty else { return }
        transferFiles(accepting: toSend)
    }

    /// When the next unattended run is due, for the interface to show.
    public var nextScheduledRun: Date? {
        let schedule = settings.schedule
        lock.lock(); let last = _lastScheduledRun; lock.unlock()
        return schedule.nextRun(after: last ?? Date())
    }

    /// Only for tests: pretend the last run happened then.
    func setLastScheduledRunForTesting(_ moment: Date?) {
        lock.lock(); _lastScheduledRun = moment; lock.unlock()
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
            $0.watchActive = settings.watchSourceFolder
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
