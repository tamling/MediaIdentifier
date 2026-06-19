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

/// Central observable view model that wires the Core engine to the UI.
@MainActor
final class AppState: ObservableObject {
    // Preview / plan (FR8).
    @Published var items: [RenameItem] = []

    // Settings.
    @Published var namingOptions: NamingOptions = .default { didSet { rebuildPlan() } }
    @Published var conflictPolicy: ConflictPolicy = .ask
    @Published var outputMode: OutputMode = .inPlace { didSet { rebuildPlan() } }

    // Progress / status (FR19).
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var statusMessage = "Drop media files or folders to begin."

    // Log (FR12, FR19).
    @Published private(set) var logEntries: [RenameLogEntry] = []
    @Published private(set) var canUndo = false

    private let scanner = MediaScanner()
    private let log = RenameLog()
    private let journal = RenameJournal()

    /// Original scanned media, kept so the plan can be rebuilt when settings change.
    private var scannedFiles: [MediaFile] = []

    init() {
        logEntries = log.entries
        canUndo = journal.canUndo
    }

    private var namer: JellyfinNamer { JellyfinNamer(options: namingOptions) }
    private var planner: RenamePlanner { RenamePlanner(namer: namer) }

    private var outputRoot: URL? {
        switch outputMode {
        case .inPlace: return nil
        case let .customFolder(url): return url
        }
    }

    // MARK: Import (FR1, FR10)

    func importURLs(_ urls: [URL]) {
        let newFiles = scanner.scan(urls: urls)
        // Merge, avoiding duplicates by source path.
        var existing = Set(scannedFiles.map { $0.url.standardizedFileURL.path })
        for file in newFiles where existing.insert(file.url.standardizedFileURL.path).inserted {
            scannedFiles.append(file)
        }
        rebuildPlan()
        statusMessage = scannedFiles.isEmpty
            ? "No supported media files found."
            : "\(scannedFiles.count) file(s) ready. Review the preview and press Start."
    }

    func clear() {
        scannedFiles.removeAll()
        items.removeAll()
        progress = 0
        statusMessage = "Drop media files or folders to begin."
    }

    func removeItem(_ item: RenameItem) {
        scannedFiles.removeAll { $0.url == item.mediaFile.url }
        items.removeAll { $0.id == item.id }
    }

    /// Recomputes the plan from scanned files, preserving user acceptance/edits
    /// where possible.
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

    // MARK: Editing (FR9)

    func setAccepted(_ accepted: Bool, for id: RenameItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isAccepted = accepted
    }

    func updateProposedPath(_ newPath: String, for id: RenameItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].proposedRelativePath = newPath
        items[index] = planner.reconcile(item: items[index])
    }

    var acceptedCount: Int { items.filter { $0.isAccepted }.count }
    var conflictCount: Int { items.filter { $0.isAccepted && $0.conflict != nil }.count }

    // MARK: Execute (FR7, FR10, FR11, FR12, FR13, FR19)

    func start() {
        guard !isProcessing, acceptedCount > 0 else { return }
        isProcessing = true
        progress = 0
        statusMessage = "Renaming…"

        let plan = items
        let policy = conflictPolicy
        // RenameLog / RenameJournal are thread-safe; build the executor inside the
        // background task to avoid hopping a non-Sendable value across actors.
        let log = self.log
        let journal = self.journal

        Task.detached(priority: .userInitiated) { [weak self] in
            let executor = RenameExecutor(log: log, journal: journal)
            let outcome = executor.execute(
                plan: plan,
                policy: policy,
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
        // Drop the processed files from the pending list, then report the result.
        scannedFiles.removeAll()
        items.removeAll()
        isProcessing = false
        progress = 1
        logEntries = log.entries
        canUndo = journal.canUndo
        statusMessage = "Done: \(outcome.succeeded) renamed, \(outcome.skipped) skipped, \(outcome.failed) failed."
    }

    func undoLast() {
        let executor = RenameExecutor(log: log, journal: journal)
        let restored = executor.undoLast()
        logEntries = log.entries
        canUndo = journal.canUndo
        statusMessage = "Undid last batch: \(restored) file(s) restored."
    }

    // MARK: Log

    func clearLog() {
        log.clear()
        logEntries = []
    }
}
