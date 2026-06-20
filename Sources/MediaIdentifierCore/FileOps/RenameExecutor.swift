import Foundation

/// Result summary of an executed plan.
public struct RenameOutcome: Sendable {
    public var succeeded: Int
    public var failed: Int
    public var skipped: Int
    public var transaction: RenameTransaction?

    public init(succeeded: Int = 0, failed: Int = 0, skipped: Int = 0, transaction: RenameTransaction? = nil) {
        self.succeeded = succeeded
        self.failed = failed
        self.skipped = skipped
        self.transaction = transaction
    }
}

/// Performs the planned moves on disk, applying the conflict policy, writing the
/// log (FR12) and recording a reversible transaction (FR13).
public final class RenameExecutor {
    private let fileManager: FileManager
    private let log: RenameLog
    private let journal: RenameJournal

    public init(
        fileManager: FileManager = .default,
        log: RenameLog,
        journal: RenameJournal
    ) {
        self.fileManager = fileManager
        self.log = log
        self.journal = journal
    }

    /// Executes the accepted items in `plan`.
    ///
    /// - Parameters:
    ///   - plan: the items to apply. Items with `isAccepted == false` are ignored (FR9).
    ///   - policy: how to resolve conflicts (FR11).
    ///   - askResolution: invoked for each conflicting move when `policy == .ask`.
    ///   - progress: called as (completed, total) for the progress bar (FR19).
    @discardableResult
    public func execute(
        plan: [RenameItem],
        policy: ConflictPolicy,
        askResolution: ((PlannedMove) -> ConflictPolicy)? = nil,
        progress: ((Int, Int) -> Void)? = nil
    ) -> RenameOutcome {
        let moves = plan.filter { $0.isAccepted }.flatMap { $0.allMoves }
        let total = moves.count
        var completed = 0
        var outcome = RenameOutcome()
        var performed: [RenameTransaction.Move] = []

        for move in moves {
            defer {
                completed += 1
                progress?(completed, total)
            }

            // No-op: source already at destination.
            if move.source.standardizedFileURL == move.destination.standardizedFileURL {
                continue
            }

            let effectivePolicy: ConflictPolicy = {
                guard fileManager.fileExists(atPath: move.destination.path) else { return policy }
                if policy == .ask { return askResolution?(move) ?? .skip }
                return policy
            }()

            do {
                guard let resolution = try resolveDestination(for: move, policy: effectivePolicy) else {
                    outcome.skipped += 1
                    log.append(RenameLogEntry(
                        oldName: move.source.lastPathComponent,
                        newName: move.destination.lastPathComponent,
                        status: .skipped
                    ))
                    continue
                }

                // For "replace", the existing file was moved to the Trash; record
                // that first so undo can restore it before the main move is undone.
                if let backup = resolution.backup {
                    performed.append(backup)
                }

                let createdDirs = try ensureParentDirectory(for: resolution.destination)
                try fileManager.moveItem(at: move.source, to: resolution.destination)

                performed.append(.init(from: move.source, to: resolution.destination, createdDirectories: createdDirs))
                outcome.succeeded += 1
                log.append(RenameLogEntry(
                    oldName: move.source.lastPathComponent,
                    newName: resolution.destination.lastPathComponent,
                    status: .success
                ))
            } catch {
                outcome.failed += 1
                log.append(RenameLogEntry(
                    oldName: move.source.lastPathComponent,
                    newName: move.destination.lastPathComponent,
                    status: .failure,
                    errorDescription: error.localizedDescription
                ))
            }
        }

        if !performed.isEmpty {
            let transaction = RenameTransaction(moves: performed)
            journal.record(transaction)
            outcome.transaction = transaction
        }
        return outcome
    }

    // MARK: Undo (FR13)

    /// Reverses the most recent transaction. Returns the number of files restored.
    @discardableResult
    public func undoLast() -> Int {
        guard let transaction = journal.popLast() else { return 0 }
        var restored = 0
        // Reverse order so nested moves unwind cleanly.
        for move in transaction.moves.reversed() {
            do {
                try ensureDirectoryExists(move.from.deletingLastPathComponent())
                if fileManager.fileExists(atPath: move.from.path) { continue }
                try fileManager.moveItem(at: move.to, to: move.from)
                restored += 1
                log.append(RenameLogEntry(
                    oldName: move.to.lastPathComponent,
                    newName: move.from.lastPathComponent,
                    status: .success,
                    errorDescription: "undo"
                ))
                // Clean up now-empty directories that were created for the move.
                for dir in move.createdDirectories.reversed() {
                    removeDirectoryIfEmpty(dir)
                }
            } catch {
                log.append(RenameLogEntry(
                    oldName: move.to.lastPathComponent,
                    newName: move.from.lastPathComponent,
                    status: .failure,
                    errorDescription: "undo failed: \(error.localizedDescription)"
                ))
            }
        }
        return restored
    }

    // MARK: Helpers

    /// The outcome of resolving a conflict: the destination to move to, plus an
    /// optional journal entry for a file that was moved to the Trash (so undo can
    /// restore it).
    private struct Resolution {
        let destination: URL
        let backup: RenameTransaction.Move?
    }

    /// Resolves the final destination honouring the conflict policy. Returns nil
    /// when the move should be skipped.
    private func resolveDestination(for move: PlannedMove, policy: ConflictPolicy) throws -> Resolution? {
        guard fileManager.fileExists(atPath: move.destination.path) else {
            return Resolution(destination: move.destination, backup: nil)
        }
        switch policy {
        case .skip, .ask:
            return nil
        case .replace:
            // Move the existing file to the Trash instead of deleting it, and
            // record it so the operation stays reversible (no silent data loss).
            let backup = try trashExisting(at: move.destination)
            return Resolution(destination: move.destination, backup: backup)
        case .rename:
            return Resolution(destination: uniqueURL(for: move.destination), backup: nil)
        }
    }

    /// Sends `url` to the Trash and returns a journal move (original location →
    /// trashed location) so undo can put it back. Falls back to a hard delete on
    /// platforms without a Trash (e.g. Linux CI).
    private func trashExisting(at url: URL) throws -> RenameTransaction.Move? {
        #if os(macOS)
        var resulting: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resulting)
        if let trashURL = resulting as URL? {
            return RenameTransaction.Move(from: url, to: trashURL)
        }
        return nil
        #else
        try fileManager.removeItem(at: url)
        return nil
        #endif
    }

    private func uniqueURL(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 1
        while true {
            let candidateName = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            let candidate = dir.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    /// Creates the parent directory chain for `url`, returning the directories it
    /// actually created (so undo can remove them if they end up empty).
    private func ensureParentDirectory(for url: URL) throws -> [URL] {
        let parent = url.deletingLastPathComponent()
        var created: [URL] = []
        var current = parent
        var missing: [URL] = []
        while !fileManager.fileExists(atPath: current.path) {
            missing.append(current)
            let next = current.deletingLastPathComponent()
            if next == current { break }
            current = next
        }
        if !missing.isEmpty {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            created = missing.reversed()
        }
        return created
    }

    private func ensureDirectoryExists(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func removeDirectoryIfEmpty(_ url: URL) {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: url.path),
              contents.isEmpty else { return }
        try? fileManager.removeItem(at: url)
    }
}
