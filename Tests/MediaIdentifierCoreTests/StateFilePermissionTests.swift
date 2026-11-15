import XCTest
@testable import MediaIdentifierCore

/// Who can read the four files in the config directory.
///
/// `settings.json` and `secrets.json` went through `AtomicFile`, which
/// creates the directory at 0700 and the file at the mode it is given.
/// `rename-log.json` and `undo-journal.json` did not: a bare `data.write`
/// with no mode, and a directory created at 0755. So whichever of the four
/// was written first decided the directory's mode — and a first run that
/// renamed a dropped file before any settings were saved left
/// ~/.config/mediafin world-readable with the log at 0644, holding every
/// path of the user's media library.
final class StateFilePermissionTests: XCTestCase {

    private var directory: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        Text.language = .german
        directory = fm.temporaryDirectory
            .appendingPathComponent("mediafin-perm-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let directory { try? fm.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func mode(of url: URL) throws -> Int16 {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).int16Value
    }

    // MARK: Each file on its own

    func testTheHistoryIsNotReadableByOtherAccounts() throws {
        let log = RenameLog(url: directory.appendingPathComponent("rename-log.json"))
        log.append(RenameLogEntry(oldName: "a.mkv", newName: "b.mkv", status: .success))
        XCTAssertEqual(try mode(of: log.url) & 0o077, 0,
                       "the history is readable by other accounts")
    }

    func testTheUndoJournalIsNotReadableByOtherAccounts() throws {
        let journal = RenameJournal(
            url: directory.appendingPathComponent("undo-journal.json"))
        journal.record(RenameTransaction(moves: [
            .init(from: URL(fileURLWithPath: "/a/x.mkv"),
                  to: URL(fileURLWithPath: "/b/y.mkv")),
        ]))
        XCTAssertEqual(try mode(of: journal.url) & 0o077, 0,
                       "the undo journal is readable by other accounts")
    }

    // MARK: The directory, whoever gets there first

    /// The order-dependent bug, stated as a test. Each of the four files is
    /// made to be the first thing written, and the directory must come out
    /// at 0700 either way.
    func testTheDirectoryIsPrivateWhicheverFileIsWrittenFirst() throws {
        func freshDirectory() -> URL {
            directory.appendingPathComponent(UUID().uuidString)
        }

        let first = freshDirectory()
        RenameLog(url: first.appendingPathComponent("rename-log.json"))
            .append(RenameLogEntry(oldName: "a", newName: "b", status: .success))
        XCTAssertEqual(try mode(of: first) & 0o077, 0,
                       "the log created the directory world-readable")

        let second = freshDirectory()
        RenameJournal(url: second.appendingPathComponent("undo-journal.json"))
            .record(RenameTransaction(moves: [
                .init(from: URL(fileURLWithPath: "/a"), to: URL(fileURLWithPath: "/b")),
            ]))
        XCTAssertEqual(try mode(of: second) & 0o077, 0,
                       "the journal created the directory world-readable")

        let third = freshDirectory()
        try SettingsStore(directory: third).save(WebSettings())
        XCTAssertEqual(try mode(of: third) & 0o077, 0)

        let fourth = freshDirectory()
        try SecretStore(directory: fourth).set("k", for: .tmdbAPIKey)
        XCTAssertEqual(try mode(of: fourth) & 0o077, 0)
    }

    /// The whole config directory as the app really builds it, in the order
    /// that used to produce 0755.
    func testAFirstRunThatRenamesBeforeSavingIsStillPrivate() throws {
        let config = directory.appendingPathComponent("config")
        let log = RenameLog(url: config.appendingPathComponent("rename-log.json"))
        log.append(RenameLogEntry(oldName: "a.mkv", newName: "b.mkv", status: .success))
        try SettingsStore(directory: config).save(WebSettings())

        XCTAssertEqual(try mode(of: config) & 0o077, 0)
        for name in ["rename-log.json", "settings.json"] {
            XCTAssertEqual(try mode(of: config.appendingPathComponent(name)) & 0o077, 0,
                           name)
        }
    }

    // MARK: A write that cannot happen is said out loud

    /// The journal's whole purpose is to survive a restart. A write that
    /// fails used to be swallowed by `try?`, leaving the in-memory state
    /// claiming to be recorded while the disk knew nothing — so Undo was
    /// offered and then was not there after a restart.
    func testAJournalThatCannotBeWrittenSaysSo() throws {
        // A FILE where the directory should be, not a read-only directory.
        // The Linux tests run as root in a container, and root ignores mode
        // bits — a 0500 directory is writable to it, so the first version of
        // this test asserted a failure that never happened. ENOTDIR binds
        // root as well.
        let blocker = directory.appendingPathComponent("locked")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blocker)

        let journal = RenameJournal(url: blocker.appendingPathComponent("j.json"))
        XCTAssertNil(journal.lastWriteFailure, "it complained before writing anything")
        journal.record(RenameTransaction(moves: [
            .init(from: URL(fileURLWithPath: "/a"), to: URL(fileURLWithPath: "/b")),
        ]))
        XCTAssertEqual(journal.lastWriteFailure, journal.url.path,
                       "a journal that could not be written reported nothing")
    }

    func testASuccessfulWriteClearsAnEarlierFailure() throws {
        let journal = RenameJournal(
            url: directory.appendingPathComponent("undo-journal.json"))
        journal.record(RenameTransaction(moves: [
            .init(from: URL(fileURLWithPath: "/a"), to: URL(fileURLWithPath: "/b")),
        ]))
        XCTAssertNil(journal.lastWriteFailure)
    }

    /// And the user is told. Not in a field nobody reads: in the history,
    /// beside the rename whose undo record just failed to reach the disk.
    func testTheHistorySaysTheUndoRecordDidNotReachTheDisk() throws {
        let work = directory.appendingPathComponent("work")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let film = work.appendingPathComponent("Tenet.2020.1080p.mkv")
        try Data("x".utf8).write(to: film)
        // See above: a file in the way, not a mode. Root ignores modes.
        let blocker = directory.appendingPathComponent("locked")
        try Data("not a directory".utf8).write(to: blocker)

        let log = RenameLog(url: work.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: blocker.appendingPathComponent("j.json"))
        let plan = RenamePlanner().makePlan(
            for: [MediaScanner().mediaFile(for: film)],
            outputRoot: work)

        let outcome = RenameExecutor(log: log, journal: journal)
            .execute(plan: plan, policy: .skip)

        XCTAssertEqual(outcome.succeeded, 1, "the rename itself should still happen")
        XCTAssertTrue(log.entries.contains {
            $0.status == .failure
                && ($0.errorDescription?.contains("Journal") ?? false)
        }, "nothing in the history says the undo record was lost")
    }
}
