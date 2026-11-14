import XCTest
@testable import MediaIdentifierCore

final class PlannerExecutorTests: XCTestCase {
    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tempDir = fm.temporaryDirectory.appendingPathComponent("MI-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempDir)
    }

    private func touch(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    // FR14 / FR15 — companions are carried along and renamed in step. The
    // release .nfo is the exception and is planned as a deletion instead:
    // Jellyfin reads *.nfo as its own metadata sidecar, so carrying a
    // group's ASCII art into the library is worse than leaving it behind.
    // ReleaseNoteDeletionTests covers that on its own.
    func testPlanRenamesCompanions() throws {
        _ = try touch("Interstellar.2014.1080p.BluRay.mkv")
        _ = try touch("Interstellar.2014.1080p.BluRay.en.srt")
        _ = try touch("Interstellar.2014.1080p.BluRay.nfo")

        let scanner = MediaScanner()
        let files = scanner.scan(urls: [tempDir])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].companions.count, 2)

        let plan = RenamePlanner().makePlan(for: files, outputRoot: tempDir)
        XCTAssertEqual(plan.count, 1)
        let item = plan[0]

        XCTAssertEqual(
            item.proposedRelativePath,
            "Interstellar (2014)/Interstellar (2014).mkv"
        )
        let companionNames = Set(item.companionMoves.map { $0.destination.lastPathComponent })
        XCTAssertTrue(companionNames.contains("Interstellar (2014).en.srt"))
        XCTAssertFalse(companionNames.contains("Interstellar (2014).nfo"),
                       "the release note is still being moved into the library")
        XCTAssertEqual(item.companionDeletions.map(\.lastPathComponent),
                       ["Interstellar.2014.1080p.BluRay.nfo"])
    }

    // FR7 / FR10 / FR12 — execute moves files and writes the log.
    func testExecuteMovesFilesAndLogs() throws {
        let source = try touch("The.Last.of.Us.S01E01.1080p.WEB-DL.mkv")
        let files = MediaScanner().scan(urls: [source])
        let plan = RenamePlanner().makePlan(for: files, outputRoot: tempDir)

        let log = RenameLog(url: tempDir.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: tempDir.appendingPathComponent("journal.json"))
        let executor = RenameExecutor(log: log, journal: journal)

        let outcome = executor.execute(plan: plan, policy: .skip)
        XCTAssertEqual(outcome.succeeded, 1)

        let expected = tempDir
            .appendingPathComponent("The Last of Us/Season 01/The Last of Us - S01E01.mkv")
        XCTAssertTrue(fm.fileExists(atPath: expected.path))
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(log.entries.filter { $0.status == .success }.count, 1)
    }

    // FR13 — undo restores the original file.
    func testUndoRestoresOriginal() throws {
        let source = try touch("Interstellar.2014.1080p.mkv")
        let files = MediaScanner().scan(urls: [source])
        let plan = RenamePlanner().makePlan(for: files, outputRoot: tempDir)

        let log = RenameLog(url: tempDir.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: tempDir.appendingPathComponent("journal.json"))
        let executor = RenameExecutor(log: log, journal: journal)

        executor.execute(plan: plan, policy: .skip)
        XCTAssertFalse(fm.fileExists(atPath: source.path))

        let restored = executor.undoLast()
        XCTAssertEqual(restored, 1)
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertFalse(journal.canUndo)
    }

    // FR11 — an existing destination is detected as a conflict.
    func testConflictDetection() throws {
        let source = try touch("Interstellar.2014.1080p.mkv")
        // Pre-create the destination.
        let destDir = tempDir.appendingPathComponent("Interstellar (2014)")
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        try Data("y".utf8).write(to: destDir.appendingPathComponent("Interstellar (2014).mkv"))

        let files = MediaScanner().scan(urls: [source])
        let plan = RenamePlanner().makePlan(for: files, outputRoot: tempDir)
        XCTAssertEqual(plan[0].conflict, .existingFile)
    }

    // FR11 — skip policy leaves a conflicting file untouched.
    func testSkipPolicyKeepsConflict() throws {
        let source = try touch("Interstellar.2014.1080p.mkv")
        let destDir = tempDir.appendingPathComponent("Interstellar (2014)")
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("Interstellar (2014).mkv")
        try Data("y".utf8).write(to: dest)

        let files = MediaScanner().scan(urls: [source])
        let plan = RenamePlanner().makePlan(for: files, outputRoot: tempDir)
        let log = RenameLog(url: tempDir.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: tempDir.appendingPathComponent("journal.json"))

        let outcome = RenameExecutor(log: log, journal: journal).execute(plan: plan, policy: .skip)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertTrue(fm.fileExists(atPath: source.path))     // original untouched
        XCTAssertEqual(try Data(contentsOf: dest), Data("y".utf8)) // destination untouched
    }

    // FR11 — "Ask" policy delegates the decision; here the user picks Rename.
    func testAskPolicyResolvesPerMove() throws {
        let source = try touch("Interstellar.2014.1080p.mkv")
        let destDir = tempDir.appendingPathComponent("Interstellar (2014)")
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        try Data("y".utf8).write(to: destDir.appendingPathComponent("Interstellar (2014).mkv"))

        let files = MediaScanner().scan(urls: [source])
        let plan = RenamePlanner().makePlan(for: files, outputRoot: tempDir)
        let log = RenameLog(url: tempDir.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: tempDir.appendingPathComponent("journal.json"))

        let outcome = RenameExecutor(log: log, journal: journal).execute(
            plan: plan,
            policy: .ask,
            askResolution: { _ in .rename }
        )
        XCTAssertEqual(outcome.succeeded, 1)
        // Original is gone and a de-duplicated name was created.
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertTrue(fm.fileExists(atPath: destDir.appendingPathComponent("Interstellar (2014) (1).mkv").path))
    }

    // MARK: Where the files actually went

    /// The counts cannot answer "which files are now in the library", and a
    /// caller that goes on to send them, or to write a cover beside them,
    /// has to know. Working it out from the plan instead is what made a
    /// scheduled run send exactly the files whose rename had failed.
    func testTheOutcomeSaysWhereEachItemLanded() throws {
        let source = try touch("Arrival.2016.1080p.mkv")
        let files = MediaScanner().scan(urls: [source])
        let plan = RenamePlanner().makePlan(for: files, outputRoot: tempDir)
        let log = RenameLog(url: tempDir.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: tempDir.appendingPathComponent("journal.json"))

        let outcome = RenameExecutor(log: log, journal: journal)
            .execute(plan: plan, policy: .rename)
        let landed = outcome.landed[plan[0].id]
        XCTAssertNotNil(landed)
        XCTAssertTrue(fm.fileExists(atPath: landed!.path), landed!.path)
    }

    /// Under the rename policy the file is not where the plan said: it is
    /// "… (1).mkv". The outcome must give the resolved name, or whatever is
    /// sent next is the file that was already there.
    func testLandedGivesTheResolvedNameNotThePlannedOne() throws {
        let source = try touch("Dune.2021.1080p.mkv")
        let destDir = tempDir.appendingPathComponent("Dune (2021)")
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        try Data("older rip".utf8).write(
            to: destDir.appendingPathComponent("Dune (2021).mkv"))

        let files = MediaScanner().scan(urls: [source])
        let plan = RenamePlanner().makePlan(for: files, outputRoot: tempDir)
        let log = RenameLog(url: tempDir.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: tempDir.appendingPathComponent("journal.json"))

        let outcome = RenameExecutor(log: log, journal: journal)
            .execute(plan: plan, policy: .rename)
        XCTAssertEqual(outcome.landed[plan[0].id]?.lastPathComponent,
                       "Dune (2021) (1).mkv")
    }

    /// A skipped item is still where it was, so it must not be reported as
    /// having landed: a caller that then deletes "the local copy" would
    /// destroy the only copy.
    func testASkippedItemDidNotLand() throws {
        let source = try touch("Tenet.2020.1080p.mkv")
        let destDir = tempDir.appendingPathComponent("Tenet (2020)")
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        try Data("y".utf8).write(to: destDir.appendingPathComponent("Tenet (2020).mkv"))

        let files = MediaScanner().scan(urls: [source])
        let plan = RenamePlanner().makePlan(for: files, outputRoot: tempDir)
        let log = RenameLog(url: tempDir.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: tempDir.appendingPathComponent("journal.json"))

        let outcome = RenameExecutor(log: log, journal: journal)
            .execute(plan: plan, policy: .skip)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertNil(outcome.landed[plan[0].id])
    }

    // MARK: Replacing, which had no test at all

    /// The happy path first, because the rest of this section is about what
    /// happens when it does not happen: the new file is in place and the
    /// library's old copy is aside rather than gone.
    /// Linux only, and deliberately: putting a file aside here is a rename
    /// into a folder beside the library, which a test can look inside. On a
    /// Mac it is the real Trash, and whether a CI machine even has one is not
    /// a thing to build an assertion on. The order under test is the same code
    /// on both.
    func testReplacePutsTheOldFileAsideAndTheNewOneInPlace() throws {
        #if !os(macOS)
        let source = try touch("Interstellar.2014.2160p.mkv")
        let destDir = tempDir.appendingPathComponent("Interstellar (2014)")
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("Interstellar (2014).mkv")
        try Data("the old one".utf8).write(to: dest)

        let files = MediaScanner().scan(urls: [source])
        let plan = RenamePlanner().makePlan(for: files, outputRoot: tempDir)
        let log = RenameLog(url: tempDir.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: tempDir.appendingPathComponent("journal.json"))

        let outcome = RenameExecutor(log: log, journal: journal)
            .execute(plan: plan, policy: .replace)
        XCTAssertEqual(outcome.succeeded, 1)
        XCTAssertEqual(try Data(contentsOf: dest), Data("x".utf8), "the new file is not there")

        // Aside, not deleted. On a Mac that is the real Trash, which a test
        // must not go rummaging in; on Linux it is a folder we can name.
        let aside = destDir.appendingPathComponent(RenameExecutor.trashFolderName)
        let kept = try fm.contentsOfDirectory(atPath: aside.path)
        XCTAssertEqual(kept.count, 1, "the old file was not put aside")
        XCTAssertEqual(
            try Data(contentsOf: aside.appendingPathComponent(kept[0])),
            Data("the old one".utf8))
        #endif
    }

    /// Undo after a replacement has to put both files back, in the right
    /// order: the new one out of the way first, then the old one home.
    /// Linux only, and deliberately: putting a file aside here is a rename
    /// into a folder beside the library, which a test can look inside. On a
    /// Mac it is the real Trash, and whether a CI machine even has one is not
    /// a thing to build an assertion on. The order under test is the same code
    /// on both.
    func testUndoAfterAReplacementRestoresTheOldFile() throws {
        #if !os(macOS)
        let source = try touch("Interstellar.2014.2160p.mkv")
        let destDir = tempDir.appendingPathComponent("Interstellar (2014)")
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("Interstellar (2014).mkv")
        try Data("the old one".utf8).write(to: dest)

        let files = MediaScanner().scan(urls: [source])
        let plan = RenamePlanner().makePlan(for: files, outputRoot: tempDir)
        let log = RenameLog(url: tempDir.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: tempDir.appendingPathComponent("journal.json"))
        let executor = RenameExecutor(log: log, journal: journal)

        XCTAssertEqual(executor.execute(plan: plan, policy: .replace).succeeded, 1)
        _ = executor.undoLast()

        XCTAssertEqual(try Data(contentsOf: source), Data("x".utf8),
                       "the file that was renamed did not come back")
        XCTAssertEqual(try Data(contentsOf: dest), Data("the old one".utf8),
                       "the library's own copy did not come back")
        #endif
    }

    /// The bug this section exists for.
    ///
    /// Replacing used to move the library's copy aside **first** and then move
    /// the new file in. The second step is the one that fails — a full disk, a
    /// read-only mount, a source that has gone away since the scan — and when
    /// it did, the library was left with nothing where the film had been. It
    /// was recoverable by undo, but only by someone who knew to press it, and
    /// the failure line said only what the error was.
    ///
    /// A source that no longer exists is the cheapest way to make the move
    /// fail for real, and it is not a contrived one: scan, go and make coffee,
    /// let something clear the download folder, press "rename".
    func testAFailedReplacementLeavesTheLibrarysOwnCopyWhereItWas() throws {
        let source = try touch("Interstellar.2014.2160p.mkv")
        let destDir = tempDir.appendingPathComponent("Interstellar (2014)")
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("Interstellar (2014).mkv")
        try Data("the old one".utf8).write(to: dest)

        let files = MediaScanner().scan(urls: [source])
        let plan = RenamePlanner().makePlan(for: files, outputRoot: tempDir)
        // Between the scan and the rename, the source goes away.
        try fm.removeItem(at: source)

        let log = RenameLog(url: tempDir.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: tempDir.appendingPathComponent("journal.json"))
        let outcome = RenameExecutor(log: log, journal: journal)
            .execute(plan: plan, policy: .replace)

        XCTAssertEqual(outcome.failed, 1)
        XCTAssertEqual(outcome.succeeded, 0)
        // The whole point: the library still has its film.
        XCTAssertEqual(try Data(contentsOf: dest), Data("the old one".utf8),
                       "the library lost its own copy to a move that never happened")
        XCTAssertNil(outcome.landed[plan[0].id],
                     "a failed replacement must not report having landed")

        #if !os(macOS)
        let aside = destDir.appendingPathComponent(RenameExecutor.trashFolderName)
        XCTAssertFalse(fm.fileExists(atPath: aside.path),
                       "the old file was put aside although nothing replaced it")
        #endif
    }

    /// And it leaves nothing behind. A staged file is hidden, so litter here
    /// would be litter nobody ever sees — holding a film's worth of disk.
    func testAFailedReplacementLeavesNoHiddenLeftovers() throws {
        let source = try touch("Tenet.2020.2160p.mkv")
        let destDir = tempDir.appendingPathComponent("Tenet (2020)")
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        try Data("y".utf8).write(to: destDir.appendingPathComponent("Tenet (2020).mkv"))

        let files = MediaScanner().scan(urls: [source])
        let plan = RenamePlanner().makePlan(for: files, outputRoot: tempDir)
        try fm.removeItem(at: source)

        let log = RenameLog(url: tempDir.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: tempDir.appendingPathComponent("journal.json"))
        _ = RenameExecutor(log: log, journal: journal)
            .execute(plan: plan, policy: .replace)

        let left = try fm.contentsOfDirectory(atPath: destDir.path)
        XCTAssertEqual(left, ["Tenet (2020).mkv"],
                       "something was left behind in the library folder: \(left)")
    }

    /// Replacing the same title twice must not have the second replacement
    /// destroy the first one's backup — both old copies are still somewhere.
    func testTwoReplacementsOfTheSameTitleKeepBothOldCopies() throws {
        #if !os(macOS)
        let destDir = tempDir.appendingPathComponent("Dune (2021)")
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("Dune (2021).mkv")
        let log = RenameLog(url: tempDir.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: tempDir.appendingPathComponent("journal.json"))

        for round in ["first", "second"] {
            let source = tempDir.appendingPathComponent("Dune.2021.2160p.mkv")
            try Data("new \(round)".utf8).write(to: source)
            try Data("old \(round)".utf8).write(to: dest)
            let files = MediaScanner().scan(urls: [source])
            let plan = RenamePlanner().makePlan(for: files, outputRoot: tempDir)
            XCTAssertEqual(RenameExecutor(log: log, journal: journal)
                .execute(plan: plan, policy: .replace).succeeded, 1, round)
        }

        let aside = destDir.appendingPathComponent(RenameExecutor.trashFolderName)
        let kept = try fm.contentsOfDirectory(atPath: aside.path).sorted()
        XCTAssertEqual(kept.count, 2, "one backup overwrote the other: \(kept)")
        let contents = Set(try kept.map {
            try Data(contentsOf: aside.appendingPathComponent($0))
        })
        XCTAssertEqual(contents, [Data("old first".utf8), Data("old second".utf8)])
        #endif
    }
}
