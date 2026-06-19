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

    // FR14 / FR15 — companions are carried along and renamed in step.
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
        XCTAssertTrue(companionNames.contains("Interstellar (2014).nfo"))
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
}
