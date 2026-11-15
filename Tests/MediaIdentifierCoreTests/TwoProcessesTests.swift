import XCTest
@testable import MediaIdentifierCore

/// Two Mediafins sharing one configuration directory.
///
/// Not hypothetical: `mediafin --help` advertises the cron line, the window
/// and the service read the same `~/.config/mediafin`, and RunLock exists
/// precisely because both can find the same scheduled run overdue.
///
/// The journal and the history each read their file once in `init` and then
/// rewrote the whole array on every change. So a window left open all day
/// held a snapshot from startup, and the next rename in it erased whatever
/// the nightly `mediafin --once` had recorded in between — silently, because
/// undo works from memory, so nothing was noticed until a restart. After it,
/// the files the nightly run had moved could not be undone at all.
///
/// Two objects on one file reproduce that exactly: the defect is the stale
/// snapshot and the whole-array write, and a second process is just the
/// commonest way to get a second snapshot.
final class TwoProcessesTests: XCTestCase {

    private var root: URL!
    private var journalURL: URL!
    private var logURL: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        Text.language = .german
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-twoproc-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        journalURL = root.appendingPathComponent("undo-journal.json")
        logURL = root.appendingPathComponent("rename-log.json")
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func move(_ name: String) -> RenameTransaction.Move {
        RenameTransaction.Move(from: root.appendingPathComponent("dl/\(name)"),
                              to: root.appendingPathComponent("lib/\(name)"))
    }

    private func transactionsOnDisk() throws -> [RenameTransaction] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([RenameTransaction].self,
                                  from: try Data(contentsOf: journalURL))
    }

    // MARK: The journal

    func testTheNightlyRunsRecordSurvivesTheOpenWindowsNextRename() throws {
        // The window, started in the morning.
        let window = RenameJournal(url: journalURL)
        window.record(RenameTransaction(date: Date(timeIntervalSince1970: 1_000),
                                        moves: [move("Morning.mkv")]))

        // 02:00, the cron line: its own process, its own fresh snapshot.
        let cron = RenameJournal(url: journalURL)
        cron.record(RenameTransaction(date: Date(timeIntervalSince1970: 2_000),
                                      moves: [move("Night1.mkv"), move("Night2.mkv")]))

        // 08:00, the window — which has not re-read anything since startup.
        window.record(RenameTransaction(date: Date(timeIntervalSince1970: 3_000),
                                        moves: [move("Later.mkv")]))

        let onDisk = try transactionsOnDisk()
        XCTAssertEqual(onDisk.count, 3,
                       "the cron run's transaction was erased by the window's own "
                           + "write: \(onDisk.map { $0.moves.map(\.from.lastPathComponent) })")
        let names = onDisk.flatMap { $0.moves.map(\.from.lastPathComponent) }.sorted()
        XCTAssertEqual(names, ["Later.mkv", "Morning.mkv", "Night1.mkv", "Night2.mkv"])
    }

    /// And the window can undo the nightly run after a restart, which is the
    /// thing that was actually lost.
    func testARestartedWindowCanUndoWhatTheNightlyRunDid() throws {
        let window = RenameJournal(url: journalURL)
        window.record(RenameTransaction(date: Date(timeIntervalSince1970: 1_000),
                                        moves: [move("Morning.mkv")]))
        let cron = RenameJournal(url: journalURL)
        cron.record(RenameTransaction(date: Date(timeIntervalSince1970: 2_000),
                                      moves: [move("Night.mkv")]))
        window.record(RenameTransaction(date: Date(timeIntervalSince1970: 3_000),
                                        moves: [move("Later.mkv")]))

        let afterRestart = RenameJournal(url: journalURL)
        XCTAssertEqual(afterRestart.transactions.count, 3)
        // Oldest first, so `last` is the most recent whoever wrote it.
        XCTAssertEqual(afterRestart.last?.moves.first?.from.lastPathComponent,
                       "Later.mkv")
    }

    /// The order is by time, not by whoever wrote last: undo takes `last`.
    func testTheJournalIsOrderedByTimeAcrossProcesses() throws {
        let second = RenameJournal(url: journalURL)
        second.record(RenameTransaction(date: Date(timeIntervalSince1970: 9_000),
                                        moves: [move("Newest.mkv")]))
        let first = RenameJournal(url: journalURL)
        first.record(RenameTransaction(date: Date(timeIntervalSince1970: 1_000),
                                       moves: [move("Oldest.mkv")]))

        let onDisk = try transactionsOnDisk()
        XCTAssertEqual(onDisk.map { $0.moves[0].from.lastPathComponent },
                       ["Oldest.mkv", "Newest.mkv"])
    }

    /// An undo must not act on somebody else's transaction, and the refusal
    /// is now based on what is really on disk rather than on a snapshot.
    func testAnUndoRefusesWhenTheOtherProcessHasRecordedSince() throws {
        let window = RenameJournal(url: journalURL)
        let mine = RenameTransaction(date: Date(timeIntervalSince1970: 1_000),
                                     moves: [move("Mine.mkv")])
        window.record(mine)

        let cron = RenameJournal(url: journalURL)
        cron.record(RenameTransaction(date: Date(timeIntervalSince1970: 2_000),
                                      moves: [move("Theirs.mkv")]))

        XCTAssertFalse(window.finishUndo(of: mine.id, leaving: []),
                       "the window dropped a transaction it had not worked from")
        XCTAssertEqual(try transactionsOnDisk().count, 2)
    }

    /// Clearing stays destructive: it is what the user asked for.
    func testClearingIsNotUndoneByTheMerge() throws {
        let window = RenameJournal(url: journalURL)
        window.record(RenameTransaction(moves: [move("A.mkv")]))
        let other = RenameJournal(url: journalURL)
        other.record(RenameTransaction(moves: [move("B.mkv")]))

        window.clear()

        XCTAssertFalse(fm.fileExists(atPath: journalURL.path))
        XCTAssertFalse(RenameJournal(url: journalURL).canUndo)
    }

    // MARK: The history

    func testTheHistoryKeepsBothProcessesEntries() throws {
        let window = RenameLog(url: logURL)
        window.append(RenameLogEntry(oldName: "Morning.mkv", newName: "a.mkv",
                                     date: Date(timeIntervalSince1970: 1_000),
                                     status: .success))
        window.flush()

        let cron = RenameLog(url: logURL)
        cron.append(RenameLogEntry(oldName: "Night.mkv", newName: "b.mkv",
                                   date: Date(timeIntervalSince1970: 2_000),
                                   status: .success))
        cron.flush()

        window.append(RenameLogEntry(oldName: "Later.mkv", newName: "c.mkv",
                                     date: Date(timeIntervalSince1970: 3_000),
                                     status: .success))
        window.flush()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode([RenameLogEntry].self,
                                        from: try Data(contentsOf: logURL))
        XCTAssertEqual(onDisk.map(\.oldName), ["Morning.mkv", "Night.mkv", "Later.mkv"],
                       "an entry was lost or misordered")
        // And the window's own in-memory view has the other run in it now,
        // which is what the user sees.
        XCTAssertEqual(window.entries.count, 3)
    }

    func testClearingTheHistoryIsNotUndoneByTheMerge() throws {
        let window = RenameLog(url: logURL)
        window.append(RenameLogEntry(oldName: "A.mkv", newName: "a.mkv",
                                     status: .success))
        window.flush()
        let other = RenameLog(url: logURL)
        other.append(RenameLogEntry(oldName: "B.mkv", newName: "b.mkv",
                                    status: .success))
        other.flush()

        window.clear()

        XCTAssertEqual(RenameLog(url: logURL).entries.count, 0)
    }

    // MARK: Bounded

    /// The history beside this file got a cap and coalesced writes after
    /// 2,000 appends were measured at 18 seconds and ~360 MB written to
    /// produce 357 KB. This file, in the same directory, written by the same
    /// code, holding the same kind of paths, got neither — and the grown
    /// part can never be used, because undo reads `last` and nothing else.
    func testTheJournalIsBoundedTheWayTheHistoryBesideItIs() throws {
        let journal = RenameJournal(url: journalURL)
        for index in 0..<(RenameJournal.maximumTransactions + 15) {
            journal.record(RenameTransaction(
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                moves: [move("Film\(index).mkv")]))
        }

        XCTAssertEqual(journal.transactions.count,
                       RenameJournal.maximumTransactions)
        // The newest are the ones kept, because the newest is what undo acts on.
        XCTAssertEqual(journal.last?.moves.first?.from.lastPathComponent,
                       "Film\(RenameJournal.maximumTransactions + 14).mkv")
        XCTAssertEqual(try transactionsOnDisk().count,
                       RenameJournal.maximumTransactions)
    }

    /// And the total moves are bounded too, because one transaction can hold
    /// thousands: ten batches of 5,000 files is a 10 MB file re-encoded on
    /// every rename.
    func testTheTotalNumberOfMovesIsBoundedAsWell() throws {
        let journal = RenameJournal(url: journalURL)
        let big = (0..<9_000).map { move("Film\($0).mkv") }
        for index in 0..<4 {
            journal.record(RenameTransaction(
                date: Date(timeIntervalSince1970: TimeInterval(index)), moves: big))
        }

        let total = journal.transactions.reduce(0) { $0 + $1.moves.count }
        XCTAssertLessThanOrEqual(total, RenameJournal.maximumMoves)
        XCTAssertFalse(journal.transactions.isEmpty,
                       "the cap took everything, including the one undo needs")
    }

    /// A single transaction larger than the cap is kept whole: it is the one
    /// undo acts on, and dropping it is the data loss this file prevents.
    func testOneOversizedTransactionIsStillKept() {
        let journal = RenameJournal(url: journalURL)
        let huge = (0..<(RenameJournal.maximumMoves + 5_000)).map {
            move("Film\($0).mkv")
        }
        journal.record(RenameTransaction(moves: huge))

        XCTAssertEqual(journal.transactions.count, 1)
        XCTAssertEqual(journal.last?.moves.count, huge.count)
    }

    // MARK: The credentials file

    /// `load()` swallows every failure and returns an empty dictionary, and
    /// `set` started from that and then replaced the whole file. So one
    /// edited value in secrets.json made all three placeholders read "keiner
    /// hinterlegt", and the user retyping one key destroyed the other two,
    /// with nothing said at any point.
    func testStoringAKeyOverADamagedFileDoesNotDestroyTheOthers() throws {
        let secretsURL = root.appendingPathComponent("secrets.json")
        // All three stored, one value edited to a number by hand.
        try Data("""
            {"tmdb-api-key": 12345, "jellyfin-token": "j-token-abc",
             "local-llm-api-key": "sk-old"}
            """.utf8).write(to: secretsURL)
        let store = SecretStore(directory: root)

        let keptAside = try store.set("sk-new", for: .localLLMAPIKey)

        XCTAssertEqual(store.value(for: .localLLMAPIKey), "sk-new")
        let aside = try XCTUnwrap(keptAside, "the damaged file was overwritten")
        let text = try String(contentsOfFile: aside, encoding: .utf8)
        XCTAssertTrue(text.contains("j-token-abc"),
                      "the Jellyfin token is gone for good: \(text)")
        XCTAssertTrue(text.contains("12345"))
    }

    /// And the ordinary case merges as it always did, with nothing kept
    /// aside — a guard that fires every time is not a guard.
    func testStoringAKeyOverAnIntactFileKeepsTheOthersAndSaysNothing() throws {
        let store = SecretStore(directory: root)
        try store.set("j-token", for: .jellyfinToken)

        let keptAside = try store.set("sk-new", for: .localLLMAPIKey)

        XCTAssertNil(keptAside)
        XCTAssertEqual(store.value(for: .jellyfinToken), "j-token")
        XCTAssertEqual(store.value(for: .localLLMAPIKey), "sk-new")
    }

    /// The window says so, because the other keys have to be retyped and
    /// only the user can do that.
    func testTheWindowIsToldWhereTheOldFileWent() throws {
        let config = root.appendingPathComponent("config")
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        try Data("{not json".utf8)
            .write(to: config.appendingPathComponent("secrets.json"))
        let coordinator = AppCoordinator(configDirectory: config, lampInterval: 0)
        Text.language = .german

        coordinator.executeForTesting(.setSecret(.localLLMAPIKey, "sk-new"))

        let said = coordinator.snapshot.lastResult ?? ""
        XCTAssertTrue(said.contains("nicht lesbar"), said)
        XCTAssertTrue(said.contains("unreadable"), said)
    }

    // MARK: The in-flight record

    func testTheInFlightFileIsPerProcess() {
        let journal = RenameJournal(url: journalURL)
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(journal.inFlightURL.lastPathComponent.contains("\(pid)"),
                      journal.inFlightURL.lastPathComponent)
    }

    /// A leftover belonging to a process that is still running is in the
    /// middle of a batch: taking it would steal a record it is about to
    /// write properly, and delete the file it is appending to.
    func testALiveProcessesInFlightFileIsLeftAlone() throws {
        let alive = root.appendingPathComponent("undo-journal-in-flight-1.jsonl")
        try Data("""
            {"id":"\(UUID().uuidString)","date":"2026-01-01T00:00:00Z"}
            {"from":"file:///dl/x.mkv","to":"file:///lib/x.mkv","createdDirectories":[]}
            """.utf8).write(to: alive)

        let journal = RenameJournal(url: journalURL)

        // pid 1 is always running, and on a machine where this test is not
        // run as root `kill(1, 0)` answers -1 with EPERM — which is what
        // made the first version of this pass in the root-only CI container
        // and fail on the macOS runner.
        XCTAssertTrue(fm.fileExists(atPath: alive.path),
                      "pid 1 is running, and its record was taken anyway")
        XCTAssertFalse(journal.canUndo)
    }

    /// A leftover from a process that is gone is exactly what recovery is
    /// for, whichever process finds it.
    func testADeadProcessesInFlightFileIsRecovered() throws {
        let dead = root.appendingPathComponent("undo-journal-in-flight-4194302.jsonl")
        try Data("""
            {"id":"\(UUID().uuidString)","date":"2026-01-01T00:00:00Z"}
            {"from":"file:///dl/x.mkv","to":"file:///lib/x.mkv","createdDirectories":[]}
            """.utf8).write(to: dead)

        let journal = RenameJournal(url: journalURL)

        XCTAssertTrue(journal.canUndo,
                      "the interrupted batch of a process that is gone was not "
                          + "recovered")
        XCTAssertFalse(fm.fileExists(atPath: dead.path))
    }
}
