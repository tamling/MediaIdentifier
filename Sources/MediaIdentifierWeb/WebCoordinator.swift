import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MediaIdentifierCore

/// Carries out the commands the web interface submits.
///
/// Every command runs on one serial queue, so two scans or a scan and a rename
/// can never interleave, and requests are never made to wait: they submit and
/// return, and progress is reported back through `snapshot`.
public final class WebCoordinator: WebCommandSink, @unchecked Sendable {
    /// Finds media below a folder.
    public struct FolderScan: Sendable {
        /// Hard limit so pointing Mediafin at a huge tree cannot exhaust
        /// memory before the user sees anything.
        public static let maximumFiles = 5_000

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
    public var configuredSecrets: Set<SecretKey> { secretStore.configuredKeys() }
    public var logEntries: [RenameLogEntry] { log.entries }

    // MARK: Submission

    public func submit(_ command: WebCommand) {
        queue.async { [weak self] in self?.execute(command) }
    }

    /// Runs a command and waits for it. Only for tests: a request must never
    /// call this, or it would block on the work.
    func executeForTesting(_ command: WebCommand) {
        queue.sync { self.execute(command) }
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
        case .startConversions:
            // Converting is not reachable from the interface yet. Say so
            // rather than appear to have started something.
            update { $0.lastResult = "Converting is not available in the web interface yet." }
        case .clearHistory:
            clearHistory()
        }
    }

    private func save(_ settings: WebSettings) {
        do {
            try settingsStore.save(settings)
            lock.lock(); _settings = settings.normalised(); lock.unlock()
            update { $0.lastResult = "Settings saved." }
            updateWatchState()
        } catch {
            update { $0.lastResult = "Settings could not be saved: \(error)" }
        }
    }

    private func setSecret(_ key: SecretKey, _ value: String) {
        do {
            try secretStore.set(value, for: key)
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
                self?.update { $0.lastResult = Self.describe(status: status, service: "model server") }
            } catch {
                self?.update {
                    $0.lastResult = "The model server could not be reached: "
                        + Self.reason(for: error)
                }
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
                self?.update { $0.lastResult = Self.describe(status: status, service: "Jellyfin") }
            } catch {
                self?.update {
                    $0.lastResult = "Jellyfin could not be reached: " + Self.reason(for: error)
                }
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
        refreshSnapshotCounts()
        refreshJellyfinLibrary()
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

    /// Looks for files that have appeared since the last look.
    ///
    /// New files are only *offered*: they are scanned and proposed, never
    /// renamed on their own. Moving someone's files without them having seen
    /// the proposal is not something a watch setting should authorise.
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
        let count = items.count
        let settings = self.settings
        let hasJellyfin = !settings.jellyfinBaseURL.isEmpty
            && secretStore.value(for: .jellyfinToken) != nil
        let done = log.entries.filter { $0.status == .success }.count
        update {
            $0.totalItems = count
            $0.ready = count
            $0.done = done
            $0.watchActive = settings.watchSourceFolder
            $0.jellyfinConfigured = hasJellyfin
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
