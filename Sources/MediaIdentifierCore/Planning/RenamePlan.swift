import Foundation

/// How a name collision should be handled (FR11).
public enum ConflictPolicy: String, Codable, Sendable, CaseIterable {
    case skip
    case rename   // append " (1)", " (2)", ...
    case replace
    case ask
}

/// The detected conflict for a planned destination (FR11).
public enum ConflictKind: String, Codable, Sendable {
    /// A file already exists at the destination on disk.
    case existingFile
    /// Two operations in the same batch target the same destination.
    case duplicateInBatch
}

/// A single file move (primary or companion).
public struct PlannedMove: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var source: URL
    public var destination: URL
    public var companionRole: CompanionFile.Role?

    public init(id: UUID = UUID(), source: URL, destination: URL, companionRole: CompanionFile.Role? = nil) {
        self.id = id
        self.source = source
        self.destination = destination
        self.companionRole = companionRole
    }
}

/// One row in the preview (FR8): a primary media file plus its companions,
/// with user controls for acceptance and manual editing (FR9).
public struct RenameItem: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var mediaFile: MediaFile
    /// The destination root the relative path is resolved against.
    public var outputRoot: URL
    /// Editable Jellyfin relative path for the primary file (FR9 manual adjust).
    public var proposedRelativePath: String
    /// Companion moves keyed implicitly by order; recomputed from the primary
    /// path so renaming the primary keeps companions in sync.
    public var companionMoves: [PlannedMove]
    /// Whether the user has accepted this change (FR9). Defaults to true.
    public var isAccepted: Bool
    /// Conflict detected for the primary destination, if any.
    public var conflict: ConflictKind?

    public init(
        id: UUID = UUID(),
        mediaFile: MediaFile,
        outputRoot: URL,
        proposedRelativePath: String,
        companionMoves: [PlannedMove] = [],
        isAccepted: Bool = true,
        conflict: ConflictKind? = nil
    ) {
        self.id = id
        self.mediaFile = mediaFile
        self.outputRoot = outputRoot
        self.proposedRelativePath = proposedRelativePath
        self.companionMoves = companionMoves
        self.isAccepted = isAccepted
        self.conflict = conflict
    }

    /// Absolute destination URL for the primary file.
    public var primaryDestination: URL {
        outputRoot.appendingPathComponent(proposedRelativePath)
    }

    /// The primary move plus all companion moves.
    public var allMoves: [PlannedMove] {
        [PlannedMove(source: mediaFile.url, destination: primaryDestination)] + companionMoves
    }

    // Convenience accessors for the preview UI (FR8).
    public var originalFileName: String { mediaFile.url.lastPathComponent }
    public var detectedTitle: String { mediaFile.parsed.title }
    public var seasonEpisodeDescription: String {
        guard mediaFile.parsed.kind == .episode else {
            return mediaFile.parsed.year.map { "Movie (\($0))" } ?? "Movie"
        }
        let s = mediaFile.parsed.season.map { String(format: "S%02d", $0) } ?? "S?"
        let e = mediaFile.parsed.episode.map { String(format: "E%02d", $0) } ?? "E?"
        return s + e
    }
    public var newFileName: String { (proposedRelativePath as NSString).lastPathComponent }
}
