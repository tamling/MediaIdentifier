import Foundation

/// Turns parsed `MediaFile`s into a list of `RenameItem`s with computed
/// destinations and companion moves, then flags conflicts (FR7, FR8, FR10, FR11,
/// FR14, FR15).
public struct RenamePlanner {
    public let namer: JellyfinNamer
    private let fileManager: FileManager

    public init(namer: JellyfinNamer = JellyfinNamer(), fileManager: FileManager = .default) {
        self.namer = namer
        self.fileManager = fileManager
    }

    /// Builds the plan.
    ///
    /// - Parameters:
    ///   - mediaFiles: parsed media files to rename.
    ///   - outputRoot: destination root. When `nil`, each file is renamed in
    ///     place relative to its own parent directory (FR18, fully local).
    ///   - libraryRoot: when set, finished media is moved here as the final
    ///     step — movies always, but episodes only when their season is
    ///     complete (partial seasons stay at `outputRoot`/in place).
    public func makePlan(
        for mediaFiles: [MediaFile],
        outputRoot: URL? = nil,
        libraryRoot: URL? = nil
    ) -> [RenameItem] {
        let completeSeasons = libraryRoot == nil ? [] : SeasonAnalyzer.completeSeasons(in: mediaFiles)
        var items = mediaFiles.map {
            makeItem(for: $0, outputRoot: outputRoot, libraryRoot: libraryRoot, completeSeasons: completeSeasons)
        }
        detectConflicts(in: &items)
        return items
    }

    /// Rebuilds the companion moves and conflict state after the user edits the
    /// primary path of a single item (FR9).
    public func reconcile(item: RenameItem) -> RenameItem {
        var updated = item
        updated.companionMoves = companionMoves(
            for: item.mediaFile,
            primaryDestination: item.primaryDestination
        )
        updated.companionDeletions = Self.companionDeletions(for: item.mediaFile)
        // Refresh the on-disk conflict state for the edited destination. Batch
        // duplicate detection is left to `makePlan`.
        let primaryPath = updated.primaryDestination.standardizedFileURL.path
        let sourcePath = updated.mediaFile.url.standardizedFileURL.path
        if primaryPath != sourcePath, fileManager.fileExists(atPath: updated.primaryDestination.path) {
            updated.conflict = .existingFile
        } else if updated.conflict == .existingFile {
            updated.conflict = nil
        }
        return updated
    }

    // MARK: Item construction

    private func makeItem(
        for mediaFile: MediaFile,
        outputRoot: URL?,
        libraryRoot: URL?,
        completeSeasons: Set<SeasonAnalyzer.SeasonKey>
    ) -> RenameItem {
        let inPlace = outputRoot ?? mediaFile.url.deletingLastPathComponent()
        let root: URL
        if let libraryRoot {
            switch mediaFile.parsed.kind {
            case .movie, .unknown:
                root = libraryRoot
            case .episode:
                root = SeasonAnalyzer.isComplete(mediaFile.parsed, within: completeSeasons)
                    ? libraryRoot : inPlace
            }
        } else {
            root = inPlace
        }
        let ext = mediaFile.url.pathExtension
        let relativePath = namer.relativePath(for: mediaFile.parsed, fileExtension: ext)
        let primaryDestination = root.appendingPathComponent(relativePath)
        let companions = companionMoves(for: mediaFile, primaryDestination: primaryDestination)
        let deletions = Self.companionDeletions(for: mediaFile)

        return RenameItem(
            mediaFile: mediaFile,
            outputRoot: root,
            proposedRelativePath: relativePath,
            companionMoves: companions,
            companionDeletions: deletions
        )
    }

    /// Computes companion destinations next to the renamed primary, preserving
    /// any suffix beyond the shared base name (e.g. ".en" for subtitles).
    private func companionMoves(for mediaFile: MediaFile, primaryDestination: URL) -> [PlannedMove] {
        let destinationDir = primaryDestination.deletingLastPathComponent()
        let newStem = primaryDestination.deletingPathExtension().lastPathComponent
        let oldStem = mediaFile.url.deletingPathExtension().lastPathComponent

        return mediaFile.companions.compactMap { companion -> PlannedMove? in
            // The release .nfo is not moved anywhere: see companionDeletions.
            guard companion.role != .nfo else { return nil }
            let ext = companion.url.pathExtension
            let companionStem = companion.url.deletingPathExtension().lastPathComponent

            let suffix: String
            if companionStem.hasPrefix(oldStem) {
                suffix = String(companionStem.dropFirst(oldStem.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            } else {
                suffix = ""
            }

            var newName = newStem
            if !suffix.isEmpty { newName += "." + suffix }
            if !ext.isEmpty { newName += "." + ext }

            let destination = destinationDir.appendingPathComponent(newName)
            return PlannedMove(source: companion.url, destination: destination, companionRole: companion.role)
        }
    }

    /// The companions that are deleted instead of moved.
    ///
    /// Only `.nfo`, and the extension is checked again here rather than
    /// trusted from the role: this list is what the executor deletes, and a
    /// mistake in the scanner's role table must not be able to reach
    /// `removeItem` with a video in it.
    static func companionDeletions(for mediaFile: MediaFile) -> [URL] {
        mediaFile.companions
            .filter { $0.role == .nfo && $0.url.pathExtension.lowercased() == "nfo" }
            .map(\.url)
    }

    // MARK: Conflict detection (FR11)

    private func detectConflicts(in items: inout [RenameItem]) {
        // Within-batch duplicate destinations.
        var destinationCounts: [String: Int] = [:]
        for item in items {
            for move in item.allMoves {
                destinationCounts[move.destination.standardizedFileURL.path, default: 0] += 1
            }
        }

        for index in items.indices {
            let primaryPath = items[index].primaryDestination.standardizedFileURL.path
            let sourcePath = items[index].mediaFile.url.standardizedFileURL.path

            // A no-op (already correctly named) is not a conflict.
            if primaryPath == sourcePath {
                items[index].conflict = nil
                continue
            }
            if (destinationCounts[primaryPath] ?? 0) > 1 {
                items[index].conflict = .duplicateInBatch
            } else if fileManager.fileExists(atPath: items[index].primaryDestination.path) {
                items[index].conflict = .existingFile
            } else {
                items[index].conflict = nil
            }
        }
    }
}
