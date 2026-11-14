import XCTest
@testable import MediaIdentifierCore

/// The release `.nfo`: planned as a deletion, not a move, and deleted only
/// under conditions this suite states one at a time.
///
/// This is the only place in the program that destroys a file, so the tests
/// are written from the other direction as well: what must *not* be deleted.
final class ReleaseNoteDeletionTests: XCTestCase {

    private var root: URL!
    private var source: URL!
    private var library: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        Text.language = .german
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-nfo-\(UUID().uuidString)")
        source = root.appendingPathComponent("Downloads")
        library = root.appendingPathComponent("Serien")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func write(_ name: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? source).appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func makeExecutor() -> (RenameExecutor, RenameLog) {
        let log = RenameLog(url: root.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: root.appendingPathComponent("journal.json"))
        return (RenameExecutor(log: log, journal: journal), log)
    }

    /// One video with an .nfo and a subtitle beside it, planned the way the
    /// window plans it.
    private func planOneEpisode(videoName: String = "Fargo.S05E10.1080p.WEB.mkv",
                                nfoName: String? = "Fargo.S05E10.1080p.WEB.nfo",
                                subtitleName: String? = "Fargo.S05E10.1080p.WEB.srt")
        throws -> [RenameItem] {
        let video = try write(videoName)
        if let nfoName { _ = try write(nfoName) }
        if let subtitleName { _ = try write(subtitleName) }
        let scanner = MediaScanner()
        let file = scanner.mediaFile(for: video)
        let planner = RenamePlanner()
        return planner.makePlan(for: [file], outputRoot: library, libraryRoot: library)
    }

    // MARK: What the plan says

    /// The plan must not claim the .nfo is going anywhere. It used to be a
    /// companion move like any other, which is how an ASCII-art release note
    /// ended up in the library named after the episode.
    func testTheNoteIsPlannedAsADeletionAndNotAsAMove() throws {
        let plan = try planOneEpisode()
        let item = try XCTUnwrap(plan.first)

        XCTAssertFalse(
            item.companionMoves.contains { $0.source.pathExtension == "nfo" },
            "the release note is still planned as a move into the library")
        XCTAssertEqual(item.companionDeletions.map(\.lastPathComponent),
                       ["Fargo.S05E10.1080p.WEB.nfo"])
        XCTAssertFalse(
            item.allMoves.contains { $0.destination.pathExtension == "nfo" },
            "an .nfo destination is still in the move list")
    }

    /// The subtitle is not collateral: it still travels, with its name.
    func testTheSubtitleStillMoves() throws {
        let plan = try planOneEpisode()
        let item = try XCTUnwrap(plan.first)
        XCTAssertEqual(
            item.companionMoves.filter { $0.source.pathExtension == "srt" }.count, 1)
        XCTAssertTrue(item.companionDeletions.allSatisfy {
            $0.pathExtension.lowercased() == "nfo"
        }, "something other than an .nfo is on the deletion list")
    }

    func testAReleaseWithNoNoteHasNothingToDelete() throws {
        let plan = try planOneEpisode(nfoName: nil)
        XCTAssertEqual(try XCTUnwrap(plan.first).companionDeletions, [])
    }

    /// Editing the destination by hand recomputes the companions. The
    /// deletion list has to be recomputed with them, or a hand-edited row
    /// silently stops deleting — or keeps a stale entry.
    func testReconcileKeepsTheDeletionList() throws {
        let plan = try planOneEpisode()
        var item = try XCTUnwrap(plan.first)
        item.proposedRelativePath = "Fargo/Season 05/Fargo - S05E10.mkv"
        let reconciled = RenamePlanner().reconcile(item: item)
        XCTAssertEqual(reconciled.companionDeletions.map(\.lastPathComponent),
                       ["Fargo.S05E10.1080p.WEB.nfo"])
    }

    // MARK: What execution does

    func testTheNoteIsGoneAndTheVideoAndSubtitleArrived() throws {
        let plan = try planOneEpisode()
        let item = try XCTUnwrap(plan.first)
        let note = try XCTUnwrap(item.companionDeletions.first)
        let (executor, log) = makeExecutor()

        let outcome = executor.execute(plan: plan, policy: .skip)

        XCTAssertFalse(fm.fileExists(atPath: note.path), "the release note survived")
        XCTAssertTrue(fm.fileExists(atPath: item.primaryDestination.path),
                      "the video did not arrive")
        XCTAssertEqual(outcome.deleted, 1)
        // Not counted as a rename: that number is read as "files renamed".
        XCTAssertEqual(outcome.succeeded, 2, "video + subtitle, and nothing else")

        let entry = try XCTUnwrap(log.entries.first { $0.status == .deleted })
        XCTAssertEqual(entry.oldName, "Fargo.S05E10.1080p.WEB.nfo")
        XCTAssertTrue(entry.errorDescription?.contains("Jellyfin") ?? false,
                      entry.errorDescription ?? "nothing said why")
    }

    /// The important one. If the video did not move, the pair is still the
    /// user's and must be left whole: deleting the note of a release whose
    /// rename failed leaves them worse off than before they pressed anything.
    func testTheNoteStaysWhenThePrimaryWasSkipped() throws {
        let plan = try planOneEpisode()
        var item = try XCTUnwrap(plan.first)
        let note = try XCTUnwrap(item.companionDeletions.first)
        // Something is already at the destination, and the policy is skip.
        try fm.createDirectory(at: item.primaryDestination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        _ = try write(item.primaryDestination.lastPathComponent,
                      in: item.primaryDestination.deletingLastPathComponent())
        item.conflict = .existingFile
        let (executor, _) = makeExecutor()

        let outcome = executor.execute(plan: [item], policy: .skip)

        XCTAssertEqual(outcome.skipped, 1, "the primary was not actually skipped")
        XCTAssertEqual(outcome.deleted, 0)
        XCTAssertTrue(fm.fileExists(atPath: note.path),
                      "the note of a release that did not move was deleted anyway")
    }

    /// An unticked row does nothing at all, deletions included.
    func testAnUntickedRowDeletesNothing() throws {
        let plan = try planOneEpisode()
        var item = try XCTUnwrap(plan.first)
        let note = try XCTUnwrap(item.companionDeletions.first)
        item.isAccepted = false
        let (executor, _) = makeExecutor()

        let outcome = executor.execute(plan: [item], policy: .skip)

        XCTAssertEqual(outcome.deleted, 0)
        XCTAssertTrue(fm.fileExists(atPath: note.path))
    }

    /// A file already filed where it belongs counts as landed — it is at the
    /// destination — so its note goes with it.
    func testANoteBesideAnAlreadyFiledVideoIsStillRemoved() throws {
        let video = try write("Fargo - S05E10.mkv", in: library)
        let note = try write("Fargo - S05E10.nfo", in: library)
        let file = MediaScanner().mediaFile(for: video)
        let plan = RenamePlanner().makePlan(for: [file], outputRoot: library,
                                            libraryRoot: library)
        var item = try XCTUnwrap(plan.first)
        // Destination equal to the source: the no-op branch.
        item.proposedRelativePath = "Fargo - S05E10.mkv"
        item.companionDeletions = [note]
        let (executor, _) = makeExecutor()

        XCTAssertEqual(executor.execute(plan: [item], policy: .skip).deleted, 1)
        XCTAssertFalse(fm.fileExists(atPath: note.path))
        XCTAssertTrue(fm.fileExists(atPath: video.path), "the video itself went")
    }

    // MARK: What must never be deleted

    /// The guard that matters most: the deletion list is checked again at the
    /// point of deletion, so a wrong entry — from a bug in the scanner's role
    /// table, or anywhere else — cannot destroy a video.
    func testAnEntryThatIsNotAnNfoIsRefusedAtThePointOfDeletion() throws {
        let plan = try planOneEpisode(nfoName: nil)
        var item = try XCTUnwrap(plan.first)
        let video = item.mediaFile.url
        let subtitle = try XCTUnwrap(item.companionMoves.first).source
        // Deliberately poisoned, as a bug elsewhere would poison it.
        item.companionDeletions = [video, subtitle,
                                   source.appendingPathComponent("notes.txt")]
        let (executor, _) = makeExecutor()

        let outcome = executor.execute(plan: [item], policy: .skip)

        XCTAssertEqual(outcome.deleted, 0, "a non-.nfo entry was deleted")
        XCTAssertTrue(fm.fileExists(atPath: item.primaryDestination.path),
                      "the video is not in the library")
    }

    /// A directory called something.nfo is refused rather than removed with
    /// whatever is inside it.
    func testADirectoryNamedLikeANoteIsRefused() throws {
        let plan = try planOneEpisode(nfoName: nil)
        var item = try XCTUnwrap(plan.first)
        let directory = source.appendingPathComponent("Extras.nfo")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try write("inside.mkv", in: directory)
        item.companionDeletions = [directory]
        let (executor, _) = makeExecutor()

        XCTAssertEqual(executor.execute(plan: [item], policy: .skip).deleted, 0)
        XCTAssertTrue(fm.fileExists(atPath: directory.path), "a directory was removed")
        XCTAssertTrue(
            fm.fileExists(atPath: directory.appendingPathComponent("inside.mkv").path))
    }

    /// A note that is not there is not a failure: nothing is reported and
    /// nothing is counted.
    func testANoteThatIsAlreadyGoneIsNotAnError() throws {
        let plan = try planOneEpisode()
        var item = try XCTUnwrap(plan.first)
        let note = try XCTUnwrap(item.companionDeletions.first)
        try fm.removeItem(at: note)
        let (executor, log) = makeExecutor()

        let outcome = executor.execute(plan: [item], policy: .skip)

        XCTAssertEqual(outcome.deleted, 0)
        XCTAssertEqual(outcome.failed, 0)
        XCTAssertTrue(log.entries.allSatisfy { $0.status != .failure },
                      "an absent note was reported as a failure")
    }

    /// Undo restores the rename. It cannot restore the note, and must not
    /// claim to: nothing about the deletion goes into the journal.
    func testUndoRestoresTheRenameAndSaysNothingAboutTheNote() throws {
        let plan = try planOneEpisode()
        let item = try XCTUnwrap(plan.first)
        let video = item.mediaFile.url
        let (executor, _) = makeExecutor()

        _ = executor.execute(plan: plan, policy: .skip)
        XCTAssertEqual(executor.undoLast(), 2, "video + subtitle came back")
        XCTAssertTrue(fm.fileExists(atPath: video.path))
        XCTAssertFalse(fm.fileExists(atPath: item.primaryDestination.path))
    }
}
