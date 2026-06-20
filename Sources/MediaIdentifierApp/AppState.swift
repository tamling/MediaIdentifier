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
        didSet { UserDefaults.standard.set(tmdbAPIKey, forKey: Keys.tmdbKey) }
    }
    @Published var isLookingUp = false

    // Conversion options (FR16/FR17 scaffold).
    @Published var conversionOptions = ConversionOptions()

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
    }

    /// Original scanned media, kept so the plan can be rebuilt when settings change.
    private var scannedFiles: [MediaFile] = []

    init() {
        logEntries = log.entries
        canUndo = journal.canUndo
        onlineLookupEnabled = UserDefaults.standard.bool(forKey: Keys.onlineLookup)
        tmdbAPIKey = UserDefaults.standard.string(forKey: Keys.tmdbKey) ?? ""
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
        if onlineLookupEnabled && !tmdbAPIKey.isEmpty {
            lookUpOnline()
        }
    }

    // MARK: Online metadata (FR3)

    func lookUpOnline() {
        guard !isLookingUp, !tmdbAPIKey.isEmpty, !scannedFiles.isEmpty else { return }
        isLookingUp = true

        let provider = TMDbMetadataProvider(apiKey: tmdbAPIKey)
        let enricher = MetadataEnricher(provider: provider)
        let files = scannedFiles

        Task { [weak self] in
            var enriched: [MediaFile] = []
            for file in files {
                var updated = file
                updated.parsed = await enricher.enrich(file.parsed)
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
        items[index].proposedRelativePath = newPath
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
                    Task { @MainActor in
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
