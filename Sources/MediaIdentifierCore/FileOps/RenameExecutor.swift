import Foundation

/// Result summary of an executed plan.
public struct RenameOutcome: Sendable {
    public var succeeded: Int
    public var failed: Int
    public var skipped: Int
    /// Release `.nfo` files removed. Counted apart from `succeeded` because
    /// that number is read as "files renamed", and a deletion is not one.
    public var deleted: Int
    public var transaction: RenameTransaction?
    /// Where each item's primary file now is, for the items whose primary
    /// move actually happened.
    ///
    /// The counts alone cannot answer "which files are now in the library",
    /// and a caller that wants to do something with the renamed files — send
    /// them on, write a cover beside them — has to know. Working it out from
    /// the plan instead is what produced the scheduled run that sent exactly
    /// the files whose rename had failed. An item that was skipped or that
    /// failed is absent: its file is still where it was.
    public var landed: [UUID: URL]

    public init(succeeded: Int = 0, failed: Int = 0, skipped: Int = 0,
                deleted: Int = 0,
                transaction: RenameTransaction? = nil,
                landed: [UUID: URL] = [:]) {
        self.succeeded = succeeded
        self.failed = failed
        self.skipped = skipped
        self.deleted = deleted
        self.transaction = transaction
        self.landed = landed
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
    ///   - progress: overall completion fraction 0...1, updated continuously so
    ///     slow cross-volume moves show real progress (FR19).
    @discardableResult
    public func execute(
        plan: [RenameItem],
        policy: ConflictPolicy,
        askResolution: ((PlannedMove) -> ConflictPolicy)? = nil,
        progress: ((Double) -> Void)? = nil
    ) -> RenameOutcome {
        // Each move carries the item it belongs to, and whether it is that
        // item's primary file, so the outcome can say where each item ended
        // up. Flattened as before, so progress is still per file.
        let moves: [(owner: UUID, isPrimary: Bool, move: PlannedMove)] =
            plan.filter { $0.isAccepted }.flatMap { item in
                item.allMoves.enumerated().map { (item.id, $0.offset == 0, $0.element) }
            }
        let total = moves.count
        var completed = 0
        var outcome = RenameOutcome()
        var performed: [RenameTransaction.Move] = []
        progress?(0)

        for (owner, isPrimary, move) in moves {
            defer {
                completed += 1
                progress?(total == 0 ? 1 : Double(completed) / Double(total))
            }

            // No-op: source already at destination.
            if move.source.standardizedFileURL == move.destination.standardizedFileURL {
                // Nothing moved, but the file is at the destination, which is
                // what `landed` is asked about.
                if isPrimary { outcome.landed[owner] = move.destination }
                continue
            }

            let effectivePolicy: ConflictPolicy = {
                guard fileManager.fileExists(atPath: move.destination.path) else { return policy }
                if policy == .ask { return askResolution?(move) ?? .skip }
                return policy
            }()

            do {
                guard let resolution = resolveDestination(for: move, policy: effectivePolicy) else {
                    // Deliberately not recorded in `landed`: a skipped file is
                    // still where it was, and a caller that goes on to send or
                    // delete it must not be told otherwise.
                    outcome.skipped += 1
                    log.append(RenameLogEntry(
                        oldName: move.source.lastPathComponent,
                        newName: move.destination.lastPathComponent,
                        status: .skipped
                    ))
                    continue
                }

                let createdDirs = try ensureParentDirectory(for: resolution.destination)
                if resolution.replacesExisting {
                    // The incoming file arrives before the library's own copy
                    // is disturbed; `replace` is where that order lives, and
                    // why. Nothing is appended to `performed` until it has
                    // returned, so a throw leaves the journal describing only
                    // what really happened.
                    let backup = try replace(
                        at: resolution.destination, with: move.source,
                        base: completed, total: total, progress: progress)
                    // Before the main move, so undo restores it after the main
                    // move has been undone and the destination is free again.
                    if let backup { performed.append(backup) }
                } else {
                    try moveWithProgress(from: move.source, to: resolution.destination,
                                         base: completed, total: total, progress: progress)
                }

                performed.append(.init(from: move.source, to: resolution.destination, createdDirectories: createdDirs))
                // The resolved destination, not the planned one: under the
                // "rename" policy the file is now "… (1).mkv".
                if isPrimary { outcome.landed[owner] = resolution.destination }
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

        // After the moves, and only for items whose primary actually landed.
        // A file that did not move still has its .nfo beside it, and that
        // pair is the user's: deleting half of a release whose rename failed
        // would leave them worse off than before they pressed anything.
        //
        // Not in the journal: there is nothing to move back. Undo can restore
        // a rename; it cannot restore a deletion, and recording one as
        // reversible would be a lie the journal then acts on.
        for item in plan where item.isAccepted {
            guard outcome.landed[item.id] != nil else { continue }
            for url in item.companionDeletions {
                outcome.deleted += deleteReleaseNote(at: url) ? 1 : 0
            }
        }
        return outcome
    }

    /// Deletes one release `.nfo`, or declines and says why in the history.
    ///
    /// Every condition is checked here rather than trusted from the plan.
    /// This is the one call in the program that destroys a file, so the
    /// extension is verified again, a directory is refused outright, and a
    /// file that is already gone is not an error.
    private func deleteReleaseNote(at url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "nfo" else { return false }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        else { return false }
        guard !isDirectory.boolValue else { return false }
        do {
            try fileManager.removeItem(at: url)
            log.append(RenameLogEntry(
                oldName: url.lastPathComponent, newName: "—", status: .deleted,
                errorDescription: Text.s(
                    "Release-Infodatei gelöscht — Jellyfin würde sie als eigene "
                        + "Metadaten lesen.",
                    "Release note deleted — Jellyfin would read it as its own "
                        + "metadata.")))
            return true
        } catch {
            log.append(RenameLogEntry(
                oldName: url.lastPathComponent, newName: "—", status: .failure,
                errorDescription: error.localizedDescription))
            return false
        }
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

    /// Moves a file while reporting progress.
    ///
    /// On Apple platforms FileManager publishes progress into the current
    /// `Progress`, so slow cross-volume moves animate within a single file
    /// (same-volume renames complete instantly). That relies on KVO, which the
    /// Objective-C runtime provides; on Linux it does not exist, so there the
    /// move is reported as one completed step.
    private func moveWithProgress(
        from source: URL, to destination: URL,
        base: Int, total: Int, progress: ((Double) -> Void)?
    ) throws {
        guard let progress, total > 0 else {
            try fileManager.moveItem(at: source, to: destination)
            return
        }
        #if canImport(ObjectiveC)
        let parent = Progress(totalUnitCount: 100)
        let observation = parent.observe(\.fractionCompleted) { p, _ in
            progress((Double(base) + p.fractionCompleted) / Double(total))
        }
        defer { observation.invalidate() }
        parent.becomeCurrent(withPendingUnitCount: 100)
        defer { parent.resignCurrent() }
        try fileManager.moveItem(at: source, to: destination)
        #else
        try fileManager.moveItem(at: source, to: destination)
        progress(Double(base + 1) / Double(total))
        #endif
    }

    // MARK: Helpers

    /// The outcome of resolving a conflict: where the file should go, and
    /// whether something is already there that the policy says to displace.
    ///
    /// It does **not** displace anything. This used to move the old file aside
    /// as a side effect of being asked where the new one goes, which put the
    /// library's own copy out of the way before the incoming file had got
    /// anywhere — and *when* that happens is the whole point. See `apply`.
    private struct Resolution {
        let destination: URL
        let replacesExisting: Bool
    }

    /// Resolves the final destination honouring the conflict policy. Returns nil
    /// when the move should be skipped. Touches nothing on disk.
    private func resolveDestination(for move: PlannedMove,
                                    policy: ConflictPolicy) -> Resolution? {
        guard fileManager.fileExists(atPath: move.destination.path) else {
            return Resolution(destination: move.destination, replacesExisting: false)
        }
        switch policy {
        case .skip, .ask:
            return nil
        case .replace:
            return Resolution(destination: move.destination, replacesExisting: true)
        case .rename:
            return Resolution(destination: uniqueURL(for: move.destination),
                              replacesExisting: false)
        }
    }

    /// Replaces the file at `destination` with `source`, in an order that
    /// cannot leave the library with a gap.
    ///
    /// The old order moved the library's copy aside first and then moved the
    /// new file in. The second step is the one that can fail — a full disk, a
    /// read-only mount, a copy across filesystems that dies halfway — and when
    /// it did, the library was left with nothing where the film had been. It
    /// was recoverable: the move aside is journalled, so undo put it back. But
    /// it was recoverable by someone who knew to press undo, and the failure
    /// line said only what the error was.
    ///
    /// So now the expensive step goes first. The incoming file is brought into
    /// the destination's own directory under a hidden name — every scanner here
    /// passes `.skipsHiddenFiles`, so nothing picks it up — and only once it
    /// has arrived is the old file moved aside and the new one renamed into
    /// place. Those last two are renames within one directory on one
    /// filesystem, which is as close to "cannot fail" as a file system offers.
    /// If one does anyway, both are undone and the library keeps its own copy.
    private func replace(
        at destination: URL, with source: URL,
        base: Int, total: Int, progress: ((Double) -> Void)?
    ) throws -> RenameTransaction.Move? {
        // The extension is kept and the name is not: a staged file left behind
        // by a crash is then identifiable as a video rather than as a nameless
        // blob, without risking the 255-byte limit that a library file's own
        // name can already be close to.
        let suffix = destination.pathExtension.isEmpty
            ? "" : "." + destination.pathExtension
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".mediafin-incoming-\(UUID().uuidString.prefix(8))\(suffix)")

        // Step one: the whole transfer, before anything of the user's moves.
        try moveWithProgress(from: source, to: staged,
                             base: base, total: total, progress: progress)

        // Step two: the library's copy out of the way, journalled so undo can
        // put it back.
        let backup: RenameTransaction.Move?
        do {
            backup = try trashExisting(at: destination)
        } catch {
            // Put the incoming file back where it came from. A staged file
            // left behind is invisible litter, and the source has to still be
            // there for a second attempt to have anything to move.
            try? fileManager.moveItem(at: staged, to: source)
            throw error
        }

        // Step three: into place.
        do {
            try fileManager.moveItem(at: staged, to: destination)
        } catch {
            if let backup { try? fileManager.moveItem(at: backup.to, to: backup.from) }
            try? fileManager.moveItem(at: staged, to: source)
            throw error
        }
        return backup
    }

    /// Where a replaced file waits on a system with no desktop Trash.
    public static let trashFolderName = ".mediafin-trash"

    /// Puts `url` out of the way and returns a journal move, so undo can put
    /// it back.
    ///
    /// On Linux this used to be `removeItem`: a hard delete, returning nil,
    /// so nothing was journalled and undo could not restore it — while the
    /// setting's own label promised "the old file goes to the trash" and the
    /// comment here claimed "no silent data loss". Both were false on the
    /// platform this ships to.
    ///
    /// The file now moves into a hidden folder beside the library, which is
    /// on the same filesystem (so it is a rename, not a copy) and is skipped
    /// by every scanner. Deleting that folder is the user's to do.
    private func trashExisting(at url: URL) throws -> RenameTransaction.Move? {
        #if os(macOS)
        var resulting: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resulting)
        if let trashURL = resulting as URL? {
            return RenameTransaction.Move(from: url, to: trashURL)
        }
        return nil
        #else
        let folder = url.deletingLastPathComponent()
            .appendingPathComponent(Self.trashFolderName)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        // A unique name, so replacing the same title twice does not have the
        // second replacement destroy the first one's backup.
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        let aside = folder.appendingPathComponent(
            "\(stem)-\(UUID().uuidString.prefix(8))\(suffix)")
        try fileManager.moveItem(at: url, to: aside)
        return RenameTransaction.Move(from: url, to: aside)
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
