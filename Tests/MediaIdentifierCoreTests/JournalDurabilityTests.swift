import XCTest
@testable import MediaIdentifierCore

/// What survives a batch that never finishes.
///
/// The journal used to be written once, after the last file of a batch. For
/// the whole duration of a run — an hour, for 500 files going to a NAS mount
/// — the files were arriving in the library and the undo journal was empty.
/// Closing the window there did not lose the tail of the batch's
/// reversibility, it lost all of it, and the next launch's Undo then reached
/// past the unrecorded files to an *earlier* transaction, pulled a correctly
/// filed film back out of the library, and said it had put one file back.
final class JournalDurabilityTests: XCTestCase {

    private var root: URL!
    private var source: URL!
    private var library: URL!
    private var journalURL: URL!
    private var logURL: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        Text.language = .german
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-durable-\(UUID().uuidString)")
        source = root.appendingPathComponent("Downloads")
        library = root.appendingPathComponent("Filme")
        journalURL = root.appendingPathComponent("config/undo-journal.json")
        logURL = root.appendingPathComponent("config/rename-log.json")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ name: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? source).appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func planFilms(_ names: [String]) throws -> [RenameItem] {
        for name in names { try write(name) }
        let files = MediaScanner().scan(urls: [source])
        return RenamePlanner().makePlan(for: files, outputRoot: library)
    }

    /// Counted off the file on disk, which is the only thing durability can
    /// mean. The header line is not a move.
    private func inFlightMoves(_ journal: RenameJournal) -> Int {
        guard let text = try? String(contentsOf: journal.inFlightURL,
                                     encoding: .utf8)
        else { return 0 }
        return max(0, text.split(separator: "\n").count - 1)
    }

    private func filesIn(_ directory: URL) -> [String] {
        (fm.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? [])
            .filter { $0.hasSuffix(".mkv") }
            .sorted()
    }

    // MARK: The record keeps up with the filesystem

    /// A move and the record of it cannot be one atomic act, so the journal
    /// always lags by the file in flight. By one file — not by the batch.
    func testTheRecordNeverLagsTheLibraryByMoreThanOneFile() throws {
        let plan = try planFilms([
            "Tenet.2020.1080p.BluRay.x264-GROUP.mkv",
            "Arrival.2016.1080p.BluRay.x264-GROUP.mkv",
            "Dune.2021.1080p.BluRay.x264-GROUP.mkv",
            "Heat.1995.1080p.BluRay.x264-GROUP.mkv",
            "Alien.1979.1080p.BluRay.x264-GROUP.mkv",
        ])
        XCTAssertEqual(plan.count, 5)
        let journal = RenameJournal(url: journalURL)
        let executor = RenameExecutor(log: RenameLog(url: logURL), journal: journal)

        var worstGap = 0
        var samples: [(moved: Int, durable: Int)] = []
        _ = executor.execute(plan: plan, policy: .skip, progress: { _ in
            let moved = self.filesIn(self.library).count
            let durable = self.inFlightMoves(journal)
            samples.append((moved, durable))
            worstGap = max(worstGap, moved - durable)
        })

        XCTAssertLessThanOrEqual(
            worstGap, 1,
            "\(worstGap) files were in the library with no record of how they "
                + "got there; samples: \(samples)")
        XCTAssertEqual(filesIn(library).count, 5)
    }

    /// And the in-flight file is gone once the batch has been recorded
    /// properly: it is a crash record, not a second journal.
    func testTheInFlightRecordIsRemovedOnceTheBatchIsRecorded() throws {
        let plan = try planFilms(["Tenet.2020.1080p.BluRay.x264-GROUP.mkv"])
        let journal = RenameJournal(url: journalURL)
        let executor = RenameExecutor(log: RenameLog(url: logURL), journal: journal)

        _ = executor.execute(plan: plan, policy: .skip)

        XCTAssertFalse(fm.fileExists(atPath: journal.inFlightURL.path))
        XCTAssertEqual(journal.transactions.count, 1)
        XCTAssertEqual(journal.transactions[0].moves.count, 1)
    }

    // MARK: After the process dies

    /// The crash image is the executor's own output: the in-flight file as
    /// it stood after the third film, copied out of a running batch rather
    /// than written by hand here.
    private func crashImage(after moves: Int, of plan: [RenameItem])
        throws -> (bytes: Data, journal: RenameJournal) {
        let journal = RenameJournal(url: journalURL)
        let executor = RenameExecutor(log: RenameLog(url: logURL), journal: journal)
        var captured: Data?
        _ = executor.execute(plan: plan, policy: .skip, progress: { _ in
            if captured == nil, self.inFlightMoves(journal) == moves {
                captured = try? Data(contentsOf: journal.inFlightURL)
            }
        })
        return (try XCTUnwrap(captured), journal)
    }

    func testARestartAfterAnInterruptedBatchUndoesExactlyWhatMoved() throws {
        let plan = try planFilms([
            "Tenet.2020.1080p.BluRay.x264-GROUP.mkv",
            "Arrival.2016.1080p.BluRay.x264-GROUP.mkv",
            "Dune.2021.1080p.BluRay.x264-GROUP.mkv",
            "Heat.1995.1080p.BluRay.x264-GROUP.mkv",
            "Alien.1979.1080p.BluRay.x264-GROUP.mkv",
        ])
        let image = try crashImage(after: 3, of: plan)

        // The process died before the batch was recorded: the journal file
        // never appeared, and the in-flight file is what is on disk.
        try? fm.removeItem(at: journalURL)
        try image.bytes.write(to: image.journal.inFlightURL)

        // A new launch.
        let reopened = RenameJournal(url: journalURL)
        XCTAssertEqual(reopened.transactions.count, 1,
                       "the interrupted batch was not recovered at all")
        XCTAssertEqual(reopened.transactions[0].moves.count, 3)
        XCTAssertTrue(reopened.canUndo)
        XCTAssertFalse(fm.fileExists(atPath: reopened.inFlightURL.path),
                       "the crash record was not consumed, so the next launch "
                           + "would recover the same batch again")

        let restored = RenameExecutor(
            log: RenameLog(url: root.appendingPathComponent("config/log2.json")),
            journal: reopened).undoLast()

        XCTAssertEqual(restored, 3, "undo did not put back what was recorded")
        XCTAssertEqual(filesIn(source).count, 3)
        XCTAssertEqual(filesIn(library).count, 2,
                       "undo reached past the recovered batch")
    }

    /// The catastrophe the old behaviour produced. An earlier, finished
    /// batch is in the journal; today's batch is interrupted. Undo must
    /// reverse today's, not last week's.
    func testUndoAfterAnInterruptionDoesNotReachIntoAnEarlierBatch() throws {
        // Last week: one film, filed and recorded properly.
        let old = try planFilms(["Solaris.1972.1080p.BluRay.x264-GROUP.mkv"])
        let journal = RenameJournal(url: journalURL)
        _ = RenameExecutor(log: RenameLog(url: logURL), journal: journal)
            .execute(plan: old, policy: .skip)
        XCTAssertEqual(journal.transactions.count, 1)
        let solaris = try XCTUnwrap(old.first).primaryDestination
        XCTAssertTrue(fm.fileExists(atPath: solaris.path))

        // Today: five films, interrupted after three.
        let today = try planFilms([
            "Tenet.2020.1080p.BluRay.x264-GROUP.mkv",
            "Arrival.2016.1080p.BluRay.x264-GROUP.mkv",
            "Dune.2021.1080p.BluRay.x264-GROUP.mkv",
            "Heat.1995.1080p.BluRay.x264-GROUP.mkv",
            "Alien.1979.1080p.BluRay.x264-GROUP.mkv",
        ])
        let journalBefore = try Data(contentsOf: journalURL)
        let image = try crashImage(after: 3, of: today)
        try journalBefore.write(to: journalURL)       // today's batch unrecorded
        try image.bytes.write(to: image.journal.inFlightURL)

        let reopened = RenameJournal(url: journalURL)
        XCTAssertEqual(reopened.transactions.count, 2,
                       "last week's batch and today's interrupted one")
        let restored = RenameExecutor(
            log: RenameLog(url: root.appendingPathComponent("config/log3.json")),
            journal: reopened).undoLast()

        XCTAssertEqual(restored, 3)
        XCTAssertTrue(fm.fileExists(atPath: solaris.path),
                      "undo pulled last week's film back out of the library")
    }

    /// A line half written when the process died is skipped; the moves
    /// before it are real and are kept.
    func testATruncatedLastLineCostsOnlyThatLine() throws {
        let plan = try planFilms([
            "Tenet.2020.1080p.BluRay.x264-GROUP.mkv",
            "Arrival.2016.1080p.BluRay.x264-GROUP.mkv",
            "Dune.2021.1080p.BluRay.x264-GROUP.mkv",
        ])
        let image = try crashImage(after: 2, of: plan)
        try? fm.removeItem(at: journalURL)
        // Half a line, as a kill mid-write leaves it.
        var truncated = image.bytes
        truncated.append(contentsOf: Array(#"{"from":{"relative":fa"#.utf8))
        try truncated.write(to: image.journal.inFlightURL)

        let reopened = RenameJournal(url: journalURL)
        XCTAssertEqual(reopened.transactions.first?.moves.count, 2)
    }

    /// Nothing moved, so there is nothing to recover and no empty
    /// transaction left behind to make Undo look available.
    func testABatchThatMovedNothingLeavesNoRecord() throws {
        let plan = try planFilms(["Tenet.2020.1080p.BluRay.x264-GROUP.mkv"])
        var item = try XCTUnwrap(plan.first)
        item.isAccepted = false
        let journal = RenameJournal(url: journalURL)
        let executor = RenameExecutor(log: RenameLog(url: logURL), journal: journal)

        _ = executor.execute(plan: [item], policy: .skip)

        XCTAssertFalse(fm.fileExists(atPath: journal.inFlightURL.path))
        XCTAssertFalse(RenameJournal(url: journalURL).canUndo)
    }
}
