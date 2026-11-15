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
    /// Editable Jellyfin relative path for the primary file (FR9 manual
    /// adjust), sanitised on the way in.
    ///
    /// The invariant — "this cannot climb out of `outputRoot`, and every
    /// component is a legal file name" — is enforced here, at the one place
    /// the value enters, rather than left to the discipline of whoever
    /// assigns it.
    ///
    /// `JellyfinNamer.sanitizeRelativePath` had three passing tests for
    /// `../../etc/passwd` and no call site in `Sources` at all: it was
    /// called by the form of a web interface that no longer exists. The
    /// traversal defence was green in CI and absent from the program —
    /// this project's recurring failure, where a check that cannot run looks
    /// exactly like a check that passes. Nothing was broken, because every
    /// producer happened to sanitise its own output; the next producer would
    /// not have inherited that and would not have broken a test either.
    ///
    /// Sanitising on the way in rather than inside `primaryDestination`
    /// matters: the two must never disagree. `settled(_:)` and the
    /// already-filed check both compare a file's own path against this
    /// string, and `MusicNamer` leaves through characters that `sanitize`
    /// removes — so cleaning only at the destination would have the row
    /// showing one path while the file went to another.
    public var proposedRelativePath: String {
        get { storedRelativePath }
        set { storedRelativePath = JellyfinNamer.sanitizeRelativePath(newValue) }
    }
    private var storedRelativePath: String
    /// Companion moves keyed implicitly by order; recomputed from the primary
    /// path so renaming the primary keeps companions in sync.
    public var companionMoves: [PlannedMove]
    /// Companions that are deleted rather than moved: the release `.nfo`.
    ///
    /// Jellyfin reads `*.nfo` beside a film or episode as its own metadata
    /// sidecar, in its own XML. A release `.nfo` is ASCII art and a group's
    /// notes, so carrying one into the library does not merely clutter it:
    /// Jellyfin finds a local sidecar it cannot parse where it expected its
    /// own, and the item can end up with no metadata rather than the wrong
    /// metadata.
    ///
    /// Named here rather than handled quietly at execution time so the
    /// preview can say it before anybody presses Umbenennen. A program that
    /// deletes a file it never mentioned is the program that gets accused of
    /// sending files into the void, and rightly.
    public var companionDeletions: [URL]
    /// The `.nfo` files beside this video that are deliberately left alone.
    ///
    /// The same extension carries two unrelated things, and only the content
    /// says which (see `NfoContent`). Named rather than silently skipped, for
    /// the same reason the deletions are named: somebody who has just read
    /// that release notes get deleted wants to see that their own metadata
    /// is not among them.
    public var companionKeptNotes: [URL]
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
        companionDeletions: [URL] = [],
        companionKeptNotes: [URL] = [],
        isAccepted: Bool = true,
        conflict: ConflictKind? = nil
    ) {
        self.id = id
        self.mediaFile = mediaFile
        self.outputRoot = outputRoot
        self.storedRelativePath =
            JellyfinNamer.sanitizeRelativePath(proposedRelativePath)
        self.companionMoves = companionMoves
        self.companionDeletions = companionDeletions
        self.companionKeptNotes = companionKeptNotes
        self.isAccepted = isAccepted
        self.conflict = conflict
    }

    /// Absolute destination URL for the primary file.
    ///
    /// Sanitised here, at the one point where a string becomes a path, and
    /// not left to the discipline of whoever set `proposedRelativePath`.
    ///
    /// `JellyfinNamer.sanitizeRelativePath` had three passing tests for
    /// `../../etc/passwd` and no call site in `Sources` at all: it was
    /// called by the form of a web interface that no longer exists. So the
    /// traversal defence was green in CI and absent from the program, which
    /// is this project's recurring failure — a check that cannot run looks
    /// exactly like a check that passes. Every producer happened to sanitise
    /// its own output, so nothing was broken; the next producer would not
    /// have inherited that and would not have broken a test either.
    public var primaryDestination: URL {
        // Already clean: see `proposedRelativePath`.
        outputRoot.appendingPathComponent(storedRelativePath)
    }

    /// The primary move plus all companion moves.
    public var allMoves: [PlannedMove] {
        [PlannedMove(source: mediaFile.url, destination: primaryDestination)] + companionMoves
    }

    /// What the file is called now, which is the left half of a row.
    ///
    /// The only one of these left. `detectedTitle`,
    /// `seasonEpisodeDescription` and `newFileName` were beside it, built
    /// for a web page that no longer exists, and none of them was ever read
    /// by the window: the title reaches the screen through the destination
    /// path, which `JellyfinNamer` builds with the sanitising this did not
    /// do, and the row shows that whole path rather than a bare file name.
    /// Their strings were English-only for the same reason.
    public var originalFileName: String { mediaFile.url.lastPathComponent }
}
