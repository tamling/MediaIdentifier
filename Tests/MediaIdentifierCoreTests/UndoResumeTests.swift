import XCTest
@testable import MediaIdentifierCore

/// Undo: that it can be retried, and that it does not report itself as a
/// rename.
///
/// Both findings were in one function. It took the transaction out of the
/// journal before touching a single file, so an undo that failed had
/// already destroyed the only record of what still had to be moved back —
/// and it wrote each restored file to the history as `.success`, which the
/// history calls "umbenannt" and the window counts as a rename.
final class UndoResumeTests: XCTestCase {

    private var root: URL!
    private var source: URL!
    private var library: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        Text.language = .german
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-undo-\(UUID().uuidString)")
        source = root.appendingPathComponent("Downloads")
        library = root.appendingPathComponent("Filme")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ name: String, in directory: URL? = nil,
                       contents: String = "x") throws -> URL {
        let url = (directory ?? source).appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeParts() -> (RenameExecutor, RenameLog, RenameJournal) {
        let log = RenameLog(url: root.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: root.appendingPathComponent("journal.json"))
        return (RenameExecutor(log: log, journal: journal), log, journal)
    }

    /// A film with a subtitle beside it: two moves in one transaction, so a
    /// partial undo is possible at all.
    private func planOneFilm() throws -> [RenameItem] {
        let film = try write("Tenet.2020.1080p.BluRay.x264-GROUP.mkv")
        try write("Tenet.2020.1080p.BluRay.x264-GROUP.en.srt")
        return RenamePlanner().makePlan(for: [MediaScanner().mediaFile(for: film)],
                                        outputRoot: library)
    }

    // MARK: The history must not call an undo a rename

    func testUndoIsRecordedAsUndoneAndNotAsSuccess() throws {
        let plan = try planOneFilm()
        let (executor, log, _) = makeParts()
        XCTAssertEqual(executor.execute(plan: plan, policy: .skip).succeeded, 2)

        let renames = log.entries.filter { $0.status == .success }.count
        XCTAssertEqual(executor.undoLast(), 2)

        XCTAssertEqual(log.entries.filter { $0.status == .success }.count, renames,
                       "undoing files made the rename count rise")
        XCTAssertEqual(log.entries.filter { $0.status == .undone }.count, 2)
    }

    /// The counter the window actually prints. It is the number of `.success`
    /// entries, so renaming eight files and undoing them said sixteen.
    func testTheWindowsRenamedCounterDoesNotRiseOnUndo() throws {
        let config = root.appendingPathComponent("config")
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        try write("Tenet.2020.1080p.BluRay.x264-GROUP.mkv")
        var settings = WebSettings(sourceFolder: source.path)
        settings.moviesFolder = library.path
        settings.identification = .offline

        let coordinator = AppCoordinator(configDirectory: config)
        coordinator.executeForTesting(.saveSettings(settings))
        coordinator.executeForTesting(.scanSourceFolder)
        coordinator.executeForTesting(.applyProposedRenames(accepting: nil))
        let afterRename = coordinator.snapshot.done
        XCTAssertGreaterThan(afterRename, 0, "nothing was renamed, so nothing is proved")

        coordinator.executeForTesting(.undoLastRename)
        XCTAssertEqual(coordinator.snapshot.done, afterRename,
                       "the window counts undone files as renamed")
    }

    /// `errorDescription` is for errors. It carried the string "undo".
    func testAnUndoEntryCarriesNoErrorText() throws {
        let plan = try planOneFilm()
        let (executor, log, _) = makeParts()
        executor.execute(plan: plan, policy: .skip)
        _ = executor.undoLast()

        for entry in log.entries where entry.status == .undone {
            XCTAssertNil(entry.errorDescription,
                         "an undo entry carries \(entry.errorDescription ?? "")")
        }
    }

    // MARK: The journal must survive a failed undo

    /// The finding. Something is in the way under the old name, so nothing
    /// can be moved back — and the journal used to be empty by then, so the
    /// Undo button went grey and the files stayed in the library for good.
    func testABlockedUndoKeepsTheJournalSoItCanBeRetried() throws {
        let plan = try planOneFilm()
        let item = try XCTUnwrap(plan.first)
        let (executor, log, journal) = makeParts()
        executor.execute(plan: plan, policy: .skip)
        XCTAssertTrue(journal.canUndo)

        // Both old names taken again, as a second download would.
        try write(item.originalFileName, contents: "something else")
        try write("Tenet.2020.1080p.BluRay.x264-GROUP.en.srt", contents: "else")

        XCTAssertEqual(executor.undoLast(), 0)
        XCTAssertTrue(journal.canUndo,
                      "a blocked undo threw away the record of what to undo")
        XCTAssertEqual(journal.transactions.last?.moves.count, 2,
                       "both blocked moves should still be there")
        // And it says why, rather than reporting nothing at all.
        let refusals = log.entries.filter { $0.status == .skipped }
        XCTAssertEqual(refusals.count, 2)
        XCTAssertTrue(refusals.allSatisfy {
            $0.errorDescription?.contains("alten Namen") ?? false
        }, refusals.first?.errorDescription ?? "nothing said why")
    }

    /// Resumable: the second press finishes what the first could not.
    func testASecondPressFinishesAPartialUndo() throws {
        let plan = try planOneFilm()
        let (executor, _, journal) = makeParts()
        executor.execute(plan: plan, policy: .skip)

        // Only the subtitle's old name is taken, so the film comes back and
        // the subtitle does not.
        let blocker = try write("Tenet.2020.1080p.BluRay.x264-GROUP.en.srt",
                                contents: "in the way")

        XCTAssertEqual(executor.undoLast(), 1, "the film should have come back")
        XCTAssertTrue(journal.canUndo, "the subtitle's move was forgotten")
        XCTAssertEqual(journal.transactions.last?.moves.count, 1,
                       "the move that succeeded is still in the journal")

        // Clear the obstacle and press again.
        try fm.removeItem(at: blocker)
        XCTAssertEqual(executor.undoLast(), 1, "the second press did nothing")
        XCTAssertTrue(fm.fileExists(atPath: blocker.path),
                      "the subtitle never came back")
        XCTAssertFalse(journal.canUndo, "the journal still has work in it")
    }

    /// A completed undo still clears the journal — resumability must not
    /// leave an entry behind that a later press would act on twice.
    func testACompletedUndoClearsTheJournal() throws {
        let plan = try planOneFilm()
        let (executor, _, journal) = makeParts()
        executor.execute(plan: plan, policy: .skip)
        XCTAssertEqual(executor.undoLast(), 2)
        XCTAssertFalse(journal.canUndo)
        XCTAssertEqual(executor.undoLast(), 0, "a second press undid something twice")
    }

    /// The journal is on disk, so a blocked undo has to be retryable after a
    /// restart as well — that is the whole reason the journal is a file.
    func testTheKeptTransactionIsOnDiskNotJustInMemory() throws {
        let plan = try planOneFilm()
        let item = try XCTUnwrap(plan.first)
        let (executor, _, _) = makeParts()
        executor.execute(plan: plan, policy: .skip)
        try write(item.originalFileName, contents: "something else")
        try write("Tenet.2020.1080p.BluRay.x264-GROUP.en.srt", contents: "else")
        _ = executor.undoLast()

        // A second journal over the same file: what a restart sees.
        let reopened = RenameJournal(url: root.appendingPathComponent("journal.json"))
        XCTAssertTrue(reopened.canUndo,
                      "after a restart there was nothing left to retry")
        XCTAssertEqual(reopened.transactions.last?.moves.count, 2)
    }

    /// `finishUndo` must not overwrite a transaction recorded since: the id
    /// it was given no longer matches the last one.
    func testFinishUndoLeavesSomebodyElsesTransactionAlone() throws {
        let (_, _, journal) = makeParts()
        let mine = RenameTransaction(moves: [
            .init(from: source.appendingPathComponent("a.mkv"),
                  to: library.appendingPathComponent("a.mkv"))])
        let theirs = RenameTransaction(moves: [
            .init(from: source.appendingPathComponent("b.mkv"),
                  to: library.appendingPathComponent("b.mkv"))])
        journal.record(mine)
        journal.record(theirs)

        XCTAssertFalse(journal.finishUndo(of: mine.id, leaving: []),
                       "it claimed to have acted on a transaction it could not see")
        XCTAssertEqual(journal.transactions.count, 2)
        XCTAssertEqual(journal.transactions.last?.id, theirs.id)
    }
}
