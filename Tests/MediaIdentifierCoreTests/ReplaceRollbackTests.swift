import XCTest
@testable import MediaIdentifierCore

/// The "replace" policy when a step after the transfer fails.
///
/// `replace` does the expensive thing first: the incoming file is brought
/// into the destination's own directory under `.mediafin-incoming-…`, and
/// only then is the library's copy moved aside and the new one renamed into
/// place. That order is right and is not what these tests are about.
///
/// What was wrong is the window it opens. From the moment the transfer
/// returns until the last rename completes, that hidden file is the only copy
/// of the user's film — and nothing was recorded until the whole function
/// returned, all three rollback moves were `try?`, and nothing anywhere ever
/// looked for that prefix. So a failure in step two left 8 GB in a dotfile
/// inside a library folder, named in no message, absent from the journal, and
/// skipped by every scanner in the program.
///
/// The two existing tests in PlannerExecutorTests fail at step *one* (the
/// source is deleted before the run), so neither rollback was ever entered
/// and both of them asserted coverage of a case they did not reach.
final class ReplaceRollbackTests: XCTestCase {

    private var root: URL!
    private var source: URL!
    private var library: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        Text.language = .german
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-replace-\(UUID().uuidString)")
        source = root.appendingPathComponent("Downloads")
        library = root.appendingPathComponent("Filme")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    /// A better rip in Downloads, the film already in the library.
    private func setUpAReplacement(payload: String = "the better rip")
        throws -> (plan: [RenameItem], incoming: URL, destination: URL) {
        let incoming = source.appendingPathComponent("Tenet.2020.2160p.mkv")
        try Data(payload.utf8).write(to: incoming)
        let files = MediaScanner().scan(urls: [incoming])
        let plan = RenamePlanner().makePlan(for: files, outputRoot: library,
                                            libraryRoot: library)
        let destination = try XCTUnwrap(plan.first).primaryDestination
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data("the one already here".utf8).write(to: destination)
        return (plan, incoming, destination)
    }

    private func makeExecutor(fileManager: FileManager = .default)
        -> (RenameExecutor, RenameLog, RenameJournal) {
        let log = RenameLog(url: root.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: root.appendingPathComponent("journal.json"))
        return (RenameExecutor(fileManager: fileManager, log: log, journal: journal),
                log, journal)
    }

    private func staged(in directory: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(RenameExecutor.stagingPrefix) }.sorted()
    }

    // MARK: Step two fails

    /// The realistic one, and it needs no injection: a plain file called
    /// `.mediafin-trash` is sitting in the library folder, left by somebody
    /// who tidied up after an earlier replacement. `createDirectory` throws
    /// on it, and the rollback has to put the incoming file back.
    func testWhenTheTrashFolderCannotBeMadeTheIncomingFileGoesHome() throws {
        let setUp = try setUpAReplacement()
        try Data("not a directory".utf8).write(
            to: setUp.destination.deletingLastPathComponent()
                .appendingPathComponent(RenameExecutor.trashFolderName))
        let (executor, log, _) = makeExecutor()

        let outcome = executor.execute(plan: setUp.plan, policy: .replace)

        XCTAssertEqual(outcome.failed, 1)
        XCTAssertEqual(try Data(contentsOf: setUp.destination),
                       Data("the one already here".utf8),
                       "the library lost its own copy")
        XCTAssertEqual(try Data(contentsOf: setUp.incoming),
                       Data("the better rip".utf8),
                       "the incoming file did not come back to the import folder")
        XCTAssertEqual(staged(in: setUp.destination.deletingLastPathComponent()), [],
                       "a staged dotfile was left in the library")
        XCTAssertTrue(log.entries.contains { $0.status == .failure })
    }

    /// And when the source name has been retaken in the meantime — a
    /// re-download, a torrent client recreating it — the rollback used to
    /// give up silently, because `moveItem` refuses to overwrite. The file
    /// then stayed hidden in the library. It now lands beside the retaken
    /// name, where a scan finds it.
    func testARetakenSourceNameDoesNotStrandTheFile() throws {
        let setUp = try setUpAReplacement()
        try Data("not a directory".utf8).write(
            to: setUp.destination.deletingLastPathComponent()
                .appendingPathComponent(RenameExecutor.trashFolderName))
        let (executor, log, _) = makeExecutor()

        // The executor moves the source away in step one; something puts a
        // file back under that name before step two fails. Expressed by
        // recreating it from the progress callback, which runs after the
        // transfer.
        let outcome = executor.execute(plan: setUp.plan, policy: .replace,
                                       progress: { _ in
            if !self.fm.fileExists(atPath: setUp.incoming.path) {
                try? Data("a re-download, already started".utf8)
                    .write(to: setUp.incoming)
            }
        })

        XCTAssertEqual(outcome.failed, 1)
        XCTAssertEqual(staged(in: setUp.destination.deletingLastPathComponent()), [],
                       "the only copy of the film was left as a hidden dotfile "
                           + "in the library")
        // Beside the re-download, under the next free name.
        let inImport = try fm.contentsOfDirectory(atPath: source.path).sorted()
        XCTAssertTrue(inImport.contains("Tenet.2020.2160p (1).mkv"),
                      "the file is not in the import folder: \(inImport)")
        XCTAssertEqual(
            try Data(contentsOf: source.appendingPathComponent("Tenet.2020.2160p (1).mkv")),
            Data("the better rip".utf8))
        XCTAssertTrue(log.entries.contains { $0.status == .failure })
    }

    // MARK: Step three fails

    /// The last rename is within one directory on one filesystem, which is
    /// as close to "cannot fail" as a filesystem offers — but `replace`'s own
    /// comment promises what happens if it does anyway, and that promise was
    /// not kept: the library was left with a gap, the backup sat in
    /// `.mediafin-trash`, and the journal had nothing.
    func testWhenTheLastRenameFailsTheLibraryGetsItsFilmBack() throws {
        let setUp = try setUpAReplacement()
        let blocker = RefusingFileManager()
        // Only the staged file's move into place, so the backup's own way
        // back is left open: that is the case `replace`'s comment promises
        // to handle, and blocking both would be testing something else.
        blocker.refuseStagedMoveTo = setUp.destination
        let (executor, log, _) = makeExecutor(fileManager: blocker)

        let outcome = executor.execute(plan: setUp.plan, policy: .replace)

        XCTAssertEqual(outcome.failed, 1)
        XCTAssertTrue(blocker.refused, "the injected failure never happened, so "
                          + "nothing here is being tested")
        XCTAssertEqual(try Data(contentsOf: setUp.destination),
                       Data("the one already here".utf8),
                       "the library has a gap where its film was")
        XCTAssertEqual(staged(in: setUp.destination.deletingLastPathComponent()), [])
        XCTAssertEqual(try Data(contentsOf: setUp.incoming),
                       Data("the better rip".utf8))
        XCTAssertTrue(log.entries.contains { $0.status == .failure })
    }

    // MARK: What the failure line says

    /// The old failure line was the cause alone — "A file with the same name
    /// already exists" — with no path in it, while the user's film sat under
    /// a name nothing lists.
    func testTheFailureLineNamesWhereTheFileIs() throws {
        let setUp = try setUpAReplacement()
        try Data("not a directory".utf8).write(
            to: setUp.destination.deletingLastPathComponent()
                .appendingPathComponent(RenameExecutor.trashFolderName))
        let blocker = RefusingFileManager()
        // Both the move into place and the rollback refuse, so the file
        // really is stranded and the message has to say where.
        blocker.refuseMovesTo = "Tenet.2020.2160p"
        let (executor, log, _) = makeExecutor(fileManager: blocker)

        _ = executor.execute(plan: setUp.plan, policy: .replace)

        let failure = try XCTUnwrap(log.entries.first { $0.status == .failure })
        let said = failure.errorDescription ?? ""
        XCTAssertTrue(said.contains(RenameExecutor.stagingPrefix),
                      "the failure line does not say where the file is: \(said)")
        XCTAssertTrue(said.contains("umbenennen"), said)
    }

    // MARK: The record

    /// With the transfer done and the rest incomplete, the journal has to
    /// know where the file went. Nothing was recorded until `replace`
    /// returned, so a crash in the window left the user's file moved and no
    /// record of it anywhere — see JournalDurabilityTests for the batch-level
    /// half of this.
    func testTheStagedTransferIsRecordedBeforeTheLibraryIsTouched() throws {
        let setUp = try setUpAReplacement()
        let (executor, _, journal) = makeExecutor()
        var recordedDuringTheRun: [String] = []

        _ = executor.execute(plan: setUp.plan, policy: .replace, progress: { _ in
            recordedDuringTheRun = (try? String(contentsOf: journal.inFlightURL,
                                                encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
        })

        // The first line is the batch header; the staged move is a line of
        // its own, written while the transfer was the only thing that had
        // happened.
        XCTAssertTrue(
            recordedDuringTheRun.contains { $0.contains(RenameExecutor.stagingPrefix) },
            "the staged transfer was not recorded before the library was "
                + "touched: \(recordedDuringTheRun)")
    }

    // MARK: Leftovers are named

    /// A crash during the transfer leaves a partial dotfile holding
    /// gigabytes, with no error and no race: the source survives, because a
    /// cross-device move unlinks it only after the copy completes. Nothing
    /// anywhere looked for that prefix.
    func testAStagedFileLeftByAnEarlierCrashIsNamedInTheHistory() throws {
        let setUp = try setUpAReplacement()
        let orphan = setUp.destination.deletingLastPathComponent()
            .appendingPathComponent(RenameExecutor.stagingPrefix + "DEADBEEF.mkv")
        try Data(String(repeating: "x", count: 4096).utf8).write(to: orphan)
        let (executor, log, _) = makeExecutor()

        _ = executor.execute(plan: setUp.plan, policy: .replace)

        let said = log.entries.compactMap(\.errorDescription).joined(separator: "\n")
        XCTAssertTrue(said.contains("abgebrochenen Austauschs"),
                      "nothing in the history mentions the leftover: \(said)")
        XCTAssertTrue(log.entries.contains { $0.oldName == orphan.lastPathComponent },
                      "the leftover is not named")
        XCTAssertTrue(fm.fileExists(atPath: orphan.path),
                      "it was deleted rather than named — that is the user's call")
    }

    func testNoLeftoversMeansNothingIsSaid() throws {
        let setUp = try setUpAReplacement()
        let (executor, log, _) = makeExecutor()

        _ = executor.execute(plan: setUp.plan, policy: .replace)

        XCTAssertFalse(log.entries.contains {
            ($0.errorDescription ?? "").contains("abgebrochenen Austauschs")
        }, "a leftover was reported where there was none")
        XCTAssertEqual(try Data(contentsOf: setUp.destination),
                       Data("the better rip".utf8),
                       "and the ordinary replacement still works")
    }

    // MARK: Helpers

    /// Refuses to move anything whose destination name contains a given
    /// string, so a step that "cannot fail" can be made to.
    private final class RefusingFileManager: FileManager, @unchecked Sendable {
        /// Refuse any move whose destination name contains this.
        var refuseMovesTo: String?
        /// Refuse only the staged file's move to exactly this path.
        var refuseStagedMoveTo: URL?
        private(set) var refused = false

        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            if let refuseMovesTo,
               dstURL.lastPathComponent.contains(refuseMovesTo) {
                refused = true
                throw CocoaError(.fileWriteUnknown)
            }
            if let refuseStagedMoveTo,
               srcURL.lastPathComponent.hasPrefix(RenameExecutor.stagingPrefix),
               dstURL.standardizedFileURL == refuseStagedMoveTo.standardizedFileURL {
                refused = true
                throw CocoaError(.fileWriteUnknown)
            }
            try super.moveItem(at: srcURL, to: dstURL)
        }
    }
}
