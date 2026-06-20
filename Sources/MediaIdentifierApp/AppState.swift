import Foundation
import SwiftUI
import MediaIdentifierCore

/// Where renamed files should be written.
enum OutputMode: Equatable {
    /// Rename in place, relative to each file's own folder (FR18, default).
    case inPlace
    /// Move everything under a chosen library root.
    case customFolder(URL)
}

/// Sidebar destinations (matches the design: Warteschlange / Filme / Serien /
/// Konvertieren / Protokoll).
enum SidebarSection: Hashable {
    case queue
    case movies
    case series
    case convert
    case watch
    case log
}

/// Display status for a queued item (matches the design's status pills).
enum ItemStatus {
    case ready      // Bereit
    case conflict   // Konflikt
    case done       // Umbenannt
    case skipped    // Übersprungen
}

/// Central observable view model that wires the Core engine to the UI.
@MainActor
final class AppState: ObservableObject {
    // Preview / plan (FR8).
    @Published var items: [RenameItem] = []

    // Navigation.
    @Published var section: SidebarSection = .queue

    // Settings.
    @Published var namingOptions: NamingOptions = .default { didSet { rebuildPlan() } }
    @Published var conflictPolicy: ConflictPolicy = .ask
    @Published var outputMode: OutputMode = .inPlace { didSet { rebuildPlan() } }

    // Online metadata lookup (FR3). Disabled by default to stay fully local (FR18).
    @Published var onlineLookupEnabled = false {
        didSet { UserDefaults.standard.set(onlineLookupEnabled, forKey: Keys.onlineLookup) }
    }
    @Published var tmdbAPIKey = "" {
        didSet { KeychainStore.set(tmdbAPIKey, for: Keys.tmdbKey) }
    }
    @Published var isLookingUp = false

    // On-device Apple Intelligence identification (FR3, local — FR18).
    @Published var useAppleIntelligence = false {
        didSet { UserDefaults.standard.set(useAppleIntelligence, forKey: Keys.useAI) }
    }

    // Embedded container tags (FR3, local).
    @Published var useEmbeddedMetadata = false {
        didSet { UserDefaults.standard.set(useEmbeddedMetadata, forKey: Keys.useEmbedded) }
    }

    // Local offline title database (FR3, local after one-time download).
    @Published var useLocalDatabase = false {
        didSet { UserDefaults.standard.set(useLocalDatabase, forKey: Keys.useLocalDB) }
    }
    @Published var localDatabasePath = "" {
        didSet { UserDefaults.standard.set(localDatabasePath, forKey: Keys.localDBPath) }
    }
    @Published private(set) var localDatabaseCount = 0
    @Published private(set) var isLoadingDatabase = false
    @Published var databaseError: String?
    private var localDatabase: LocalTitleDatabase?

    // Conversion options (FR16/FR17 scaffold).
    @Published var conversionOptions = ConversionOptions()

    // Watch folder (FR20). Auto-imports (and optionally auto-renames) finished
    // downloads dropped into a chosen folder.
    @Published var watchEnabled = false {
        didSet {
            UserDefaults.standard.set(watchEnabled, forKey: Keys.watchEnabled)
            restartWatch()
        }
    }
    @Published var watchAutoRename = true {
        didSet { UserDefaults.standard.set(watchAutoRename, forKey: Keys.watchAuto) }
    }
    @Published var watchFolderPath = "" {
        didSet { UserDefaults.standard.set(watchFolderPath, forKey: Keys.watchPath) }
    }
    @Published private(set) var watchActivity: [String] = []
    private let watchScanner = WatchFolderScanner()
    private var watchTimer: Timer?

    // Interactive conflict resolution (FR11, "Ask"). Non-empty drives a sheet.
    @Published var conflictsToResolve: [RenameItem] = []

    // Progress / status (FR19).
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var lastResult: String?
    @Published var didUndo = false

    // Log (FR12, FR19).
    @Published private(set) var logEntries: [RenameLogEntry] = []
    @Published private(set) var canUndo = false

    /// Source paths of items that have been successfully renamed in this session.
    @Published private var completed: Set<String> = []

    private let scanner = MediaScanner()
    private let log = RenameLog()
    private let journal = RenameJournal()

    private enum Keys {
        static let onlineLookup = "onlineLookupEnabled"
        static let tmdbKey = "tmdbAPIKey"
        static let watchEnabled = "watchEnabled"
        static let watchAuto = "watchAutoRename"
        static let watchPath = "watchFolderPath"
        static let useAI = "useAppleIntelligence"
        static let useEmbedded = "useEmbeddedMetadata"
        static let useLocalDB = "useLocalDatabase"
        static let localDBPath = "localDatabasePath"
    }

    /// Original scanned media, kept so the plan can be rebuilt when settings change.
    private var scannedFiles: [MediaFile] = []

    init() {
        logEntries = log.entries
        canUndo = journal.canUndo
        onlineLookupEnabled = UserDefaults.standard.bool(forKey: Keys.onlineLookup)
        // API key lives in the Keychain. Migrate any legacy UserDefaults value.
        let storedKey = KeychainStore.get(Keys.tmdbKey)
        if storedKey.isEmpty, let legacy = UserDefaults.standard.string(forKey: Keys.tmdbKey), !legacy.isEmpty {
            KeychainStore.set(legacy, for: Keys.tmdbKey)
            UserDefaults.standard.removeObject(forKey: Keys.tmdbKey)
            tmdbAPIKey = legacy
        } else {
            tmdbAPIKey = storedKey
        }
        useAppleIntelligence = UserDefaults.standard.bool(forKey: Keys.useAI)
        useEmbeddedMetadata = UserDefaults.standard.bool(forKey: Keys.useEmbedded)
        useLocalDatabase = UserDefaults.standard.bool(forKey: Keys.useLocalDB)
        localDatabasePath = UserDefaults.standard.string(forKey: Keys.localDBPath) ?? ""
        if useLocalDatabase, !localDatabasePath.isEmpty { loadDatabase() }
        watchAutoRename = UserDefaults.standard.object(forKey: Keys.watchAuto) as? Bool ?? true
        watchFolderPath = UserDefaults.standard.string(forKey: Keys.watchPath) ?? ""
        watchEnabled = UserDefaults.standard.bool(forKey: Keys.watchEnabled)
        // didSet does not fire during init, so start the watcher explicitly.
        restartWatch()
    }

    // MARK: Watch folder (FR20)

    var watchFolderURL: URL? {
        watchFolderPath.isEmpty ? nil : URL(fileURLWithPath: watchFolderPath)
    }

    func setWatchFolder(_ url: URL) {
        watchFolderPath = url.path
        watchScanner.reset()
        restartWatch()
    }

    private func restartWatch() {
        watchTimer?.invalidate()
        watchTimer = nil
        guard watchEnabled, let folder = watchFolderURL else { return }
        watchScanner.reset()
        logActivity("Überwachung gestartet: \(folder.lastPathComponent)")
        let timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.pollWatch() }
        }
        watchTimer = timer
        // Run an immediate first poll so existing files are picked up promptly.
        pollWatch()
    }

    private func pollWatch() {
        guard watchEnabled, let folder = watchFolderURL else { return }
        let found = watchScanner.poll(directory: folder)
        guard !found.isEmpty else { return }
        let names = found.map { $0.lastPathComponent }.joined(separator: ", ")
        logActivity("\(found.count) neue Datei(en) erkannt: \(names)")
        importURLs(found)
        if watchAutoRename {
            logActivity("Automatische Umbenennung gestartet …")
            runExecution(resolutions: [:])
        }
    }

    private func logActivity(_ message: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        watchActivity.insert("\(stamp)  \(message)", at: 0)
        if watchActivity.count > 100 { watchActivity.removeLast() }
    }

    private var namer: JellyfinNamer { JellyfinNamer(options: namingOptions) }
    private var planner: RenamePlanner { RenamePlanner(namer: namer) }

    private var outputRoot: URL? {
        switch outputMode {
        case .inPlace: return nil
        case let .customFolder(url): return url
        }
    }

    private func sourcePath(_ item: RenameItem) -> String {
        item.mediaFile.url.standardizedFileURL.path
    }

    var canLookUpOnline: Bool {
        onlineLookupEnabled && !tmdbAPIKey.isEmpty && !scannedFiles.isEmpty
    }

    // MARK: Import (FR1, FR10)

    func importURLs(_ urls: [URL]) {
        let newFiles = scanner.scan(urls: urls)
        var existing = Set(scannedFiles.map { $0.url.standardizedFileURL.path })
        for file in newFiles where existing.insert(file.url.standardizedFileURL.path).inserted {
            scannedFiles.append(file)
        }
        didUndo = false
        rebuildPlan()
        // Run the configured identification chain (embedded tags → local DB →
        // Apple Intelligence → TMDb). All but TMDb are fully local (FR18).
        if let provider = currentEnrichmentProvider() {
            enrich(with: provider)
        }
    }

    // MARK: Metadata enrichment (FR3)

    var appleIntelligenceSupported: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return AppleIntelligenceProvider.isSupported }
        #endif
        return false
    }

    /// Manual TMDb lookup (the Settings "Jetzt nachschlagen" button).
    func lookUpOnline() {
        guard !tmdbAPIKey.isEmpty else { return }
        enrich(with: TMDbMetadataProvider(apiKey: tmdbAPIKey))
    }

    /// Checks the TMDb API key and reports clear feedback (FR3).
    @Published var tmdbTestResult: String?
    func testTMDb() {
        guard !tmdbAPIKey.isEmpty else {
            tmdbTestResult = "Kein API-Schlüssel eingegeben."
            return
        }
        tmdbTestResult = "Teste Verbindung …"
        let provider = TMDbMetadataProvider(apiKey: tmdbAPIKey)
        Task { [weak self] in
            do {
                let status = try await provider.verify()
                switch status {
                case 200:
                    self?.tmdbTestResult = "✓ Verbunden – Schlüssel gültig."
                case 401:
                    self?.tmdbTestResult = "✗ Ungültiger Schlüssel (401). Bitte den v3-API-Key verwenden, nicht den v4-Token."
                default:
                    self?.tmdbTestResult = "TMDb antwortete mit Status \(status)."
                }
            } catch {
                self?.tmdbTestResult = "✗ Keine Verbindung: \(error.localizedDescription)"
            }
        }
    }

    /// Builds the active provider chain from the enabled identification options.
    private func currentEnrichmentProvider() -> MetadataProvider? {
        var providers: [MetadataProvider] = []
        #if canImport(AVFoundation)
        if useEmbeddedMetadata { providers.append(EmbeddedMetadataProvider()) }
        #endif
        if useLocalDatabase, let db = localDatabase {
            providers.append(LocalDatabaseMetadataProvider(database: db))
        }
        #if canImport(FoundationModels)
        if useAppleIntelligence, #available(macOS 26.0, *), AppleIntelligenceProvider.isSupported {
            providers.append(AppleIntelligenceProvider())
        }
        #endif
        if onlineLookupEnabled, !tmdbAPIKey.isEmpty {
            providers.append(TMDbMetadataProvider(apiKey: tmdbAPIKey))
        }
        guard !providers.isEmpty else { return nil }
        return providers.count == 1 ? providers[0] : CompositeMetadataProvider(providers)
    }

    // MARK: Local title database (FR3)

    func setLocalDatabaseFile(_ url: URL) {
        localDatabasePath = url.path
        loadDatabase()
    }

    func loadDatabase() {
        guard !localDatabasePath.isEmpty else { return }
        let url = URL(fileURLWithPath: localDatabasePath)
        isLoadingDatabase = true
        databaseError = nil
        Task.detached(priority: .utility) { [weak self] in
            do {
                let db = try LocalTitleDatabaseLoader.load(from: url)
                await self?.applyDatabase(db, error: nil)
            } catch {
                await self?.applyDatabase(nil, error: error.localizedDescription)
            }
        }
    }

    private func applyDatabase(_ db: LocalTitleDatabase?, error: String?) {
        isLoadingDatabase = false
        localDatabase = db
        localDatabaseCount = db?.count ?? 0
        databaseError = error
    }

    /// Refines every scanned file's parsed title/year using the given provider.
    private func enrich(with provider: MetadataProvider) {
        guard !isLookingUp, !scannedFiles.isEmpty else { return }
        isLookingUp = true

        let enricher = MetadataEnricher(provider: provider)
        let files = scannedFiles

        Task { [weak self] in
            var enriched: [MediaFile] = []
            for file in files {
                var updated = file
                updated.parsed = await enricher.enrich(file.parsed, at: file.url)
                enriched.append(updated)
            }
            guard let self else { return }
            let stillPresent = Set(self.scannedFiles.map { $0.url })
            self.scannedFiles = enriched.filter { stillPresent.contains($0.url) }
            self.isLookingUp = false
            self.rebuildPlan()
        }
    }

    func clear() {
        scannedFiles.removeAll()
        items.removeAll()
        completed.removeAll()
        progress = 0
        lastResult = nil
        didUndo = false
    }

    func removeItem(_ item: RenameItem) {
        scannedFiles.removeAll { $0.url == item.mediaFile.url }
        items.removeAll { $0.id == item.id }
    }

    /// Recomputes the plan from scanned files, preserving user acceptance where possible.
    private func rebuildPlan() {
        let previousBySource = Dictionary(
            items.map { ($0.mediaFile.url, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var rebuilt = planner.makePlan(for: scannedFiles, outputRoot: outputRoot)
        for index in rebuilt.indices {
            if let previous = previousBySource[rebuilt[index].mediaFile.url] {
                rebuilt[index].isAccepted = previous.isAccepted
            }
        }
        items = rebuilt
    }

    // MARK: Status & filtering

    func status(for item: RenameItem) -> ItemStatus {
        if completed.contains(sourcePath(item)) { return .done }
        if !item.isAccepted { return .skipped }
        if item.conflict != nil { return .conflict }
        return .ready
    }

    func items(in section: SidebarSection) -> [RenameItem] {
        switch section {
        case .movies:
            return items.filter { $0.mediaFile.parsed.kind != .episode }
        case .series:
            return items.filter { $0.mediaFile.parsed.kind == .episode }
        default:
            return items
        }
    }

    var hasFiles: Bool { !items.isEmpty }
    var readyCount: Int { items.filter { status(for: $0) == .ready }.count }
    var warnCount: Int { items.filter { status(for: $0) == .conflict }.count }
    var doneCount: Int { items.filter { status(for: $0) == .done }.count }
    var movieCount: Int { items(in: .movies).count }
    var seriesCount: Int { items(in: .series).count }

    private func runnablePlan() -> [RenameItem] {
        items.filter { $0.isAccepted && !completed.contains(sourcePath($0)) }
    }

    var approvedActiveCount: Int { runnablePlan().count }
    var canStart: Bool { approvedActiveCount > 0 && !isProcessing }
    var showUndo: Bool { (doneCount > 0 || canUndo) && !isProcessing }

    /// Header checkbox state: are all not-yet-done items accepted?
    var allChecked: Bool {
        let pending = items.filter { status(for: $0) != .done }
        return !pending.isEmpty && pending.allSatisfy { $0.isAccepted }
    }

    var subtitleText: String {
        guard hasFiles else { return "Bereit zum Import" }
        return "\(items.count) Dateien analysiert · \(approvedActiveCount) ausgewählt"
    }

    var statusBarText: String {
        if let lastResult { return lastResult }
        if doneCount > 0 {
            return didUndo
                ? "\(items.count) Dateien · Umbenennung rückgängig gemacht"
                : "\(doneCount) umbenannt · protokolliert · rückgängig möglich"
        }
        guard hasFiles else { return "Keine Dateien · alles wird lokal verarbeitet" }
        return "\(readyCount) bereit · \(warnCount) benötigen Prüfung"
    }

    var startLabel: String {
        isProcessing ? "Läuft …" : "\(approvedActiveCount) umbenennen"
    }

    // MARK: Editing (FR9)

    func setAccepted(_ accepted: Bool, for id: RenameItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isAccepted = accepted
    }

    func toggle(_ id: RenameItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isAccepted.toggle()
    }

    func toggleAll() {
        let target = !allChecked
        for index in items.indices where status(for: items[index]) != .done {
            items[index].isAccepted = target
        }
    }

    func updateProposedPath(_ newPath: String, for id: RenameItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        // Prevent a manual edit from escaping the output root (e.g. "../").
        let safe = JellyfinNamer.sanitizeRelativePath(newPath)
        guard !safe.isEmpty else { return }
        items[index].proposedRelativePath = safe
        items[index] = planner.reconcile(item: items[index])
    }

    // MARK: Execute (FR7, FR10, FR11, FR12, FR13, FR19)

    func start() {
        guard !isProcessing else { return }
        let runnable = runnablePlan()
        guard !runnable.isEmpty else { return }

        if conflictPolicy == .ask {
            let conflicting = runnable.filter { $0.conflict != nil }
            if !conflicting.isEmpty {
                conflictsToResolve = conflicting
                return
            }
        }
        runExecution(resolutions: [:])
    }

    func resolveConflicts(_ resolutions: [RenameItem.ID: ConflictPolicy]) {
        var bySource: [String: ConflictPolicy] = [:]
        for item in conflictsToResolve {
            let policy = resolutions[item.id] ?? .skip
            for move in item.allMoves {
                bySource[move.source.standardizedFileURL.path] = policy
            }
        }
        conflictsToResolve = []
        runExecution(resolutions: bySource)
    }

    func cancelConflictResolution() {
        conflictsToResolve = []
        lastResult = "Abgebrochen — Konflikte auflösen und erneut starten."
    }

    private func runExecution(resolutions: [String: ConflictPolicy]) {
        isProcessing = true
        progress = 0
        lastResult = nil
        didUndo = false

        let plan = runnablePlan()
        let policy = conflictPolicy
        let log = self.log
        let journal = self.journal

        Task.detached(priority: .userInitiated) { [weak self] in
            let executor = RenameExecutor(log: log, journal: journal)
            let outcome = executor.execute(
                plan: plan,
                policy: policy,
                askResolution: { move in
                    resolutions[move.source.standardizedFileURL.path] ?? .skip
                },
                progress: { completed, total in
                    Task { @MainActor [weak self] in
                        self?.progress = total == 0 ? 1 : Double(completed) / Double(total)
                    }
                }
            )
            await self?.finish(outcome: outcome)
        }
    }

    private func finish(outcome: RenameOutcome) {
        if let tx = outcome.transaction {
            let moved = Set(tx.moves.map { $0.from.standardizedFileURL.path })
            for item in items where moved.contains(sourcePath(item)) {
                completed.insert(sourcePath(item))
            }
        }
        isProcessing = false
        progress = 1
        logEntries = log.entries
        canUndo = journal.canUndo
        lastResult = "Fertig: \(outcome.succeeded) umbenannt, \(outcome.skipped) übersprungen, \(outcome.failed) fehlgeschlagen."
    }

    func undoLast() {
        let executor = RenameExecutor(log: log, journal: journal)
        let restored = executor.undoLast()
        completed.removeAll()
        didUndo = true
        logEntries = log.entries
        canUndo = journal.canUndo
        lastResult = "Rückgängig gemacht: \(restored) Datei(en) wiederhergestellt."
    }

    // MARK: Log

    func clearLog() {
        log.clear()
        logEntries = []
    }
}
