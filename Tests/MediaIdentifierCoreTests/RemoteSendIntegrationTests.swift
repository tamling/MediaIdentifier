import XCTest
@testable import MediaIdentifierCore

/// The send, end to end, through the coordinator and onto a real server.
///
/// `RemoteTransferIntegrationTests` proves the command lines work.
/// These prove the decisions *around* them do — above all the one that
/// deletes the user's only other copy. Until these existed, no test in the
/// repository had ever run that deletion, and an audit found three separate
/// ways it destroyed files the server had never received.
///
/// Skipped unless `MEDIAFIN_SSH_TEST_HOST` is set, like the other
/// integration tests; the CI step that provides the server fails the job if
/// they were skipped, so the gap cannot reopen quietly.
final class RemoteSendIntegrationTests: XCTestCase {

    private var root: URL!
    private var source: URL!
    private var coordinator: AppCoordinator!
    private var basePath: String!
    private var runFolder: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["MEDIAFIN_SSH_TEST_HOST"], !host.isEmpty else {
            throw XCTSkip("no SSH server configured; set MEDIAFIN_SSH_TEST_HOST")
        }

        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mediafin-sendint-\(UUID().uuidString)")
        source = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"),
                                                withIntermediateDirectories: true)
        coordinator = AppCoordinator(configDirectory: root.appendingPathComponent("config"))

        // Its own folder under the base, so parallel runs and reruns cannot
        // see each other's files.
        basePath = environment["MEDIAFIN_SSH_TEST_BASE"] ?? "/tmp/mediafin-remote"
        runFolder = "run-\(UUID().uuidString)"

        var settings = coordinator.settings
        settings.sourceFolder = source.path
        settings.identification = .offline
        settings.remote = RemoteTarget(
            isEnabled: true,
            host: host,
            port: Int(environment["MEDIAFIN_SSH_TEST_PORT"] ?? "22") ?? 22,
            user: environment["MEDIAFIN_SSH_TEST_USER"] ?? NSUserName(),
            basePath: "\(basePath!)/\(runFolder!)",
            transport: .rsync,
            authentication: .key,
            identityFile: environment["MEDIAFIN_SSH_TEST_KEY"] ?? ""
        )
        coordinator.executeForTesting(.saveSettings(settings))
    }

    override func tearDownWithError() throws {
        coordinator = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        if let basePath, let runFolder {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: "\(basePath)/\(runFolder)"))
        }
        try super.tearDownWithError()
    }

    private func setRemote(_ change: (inout RemoteTarget) -> Void) {
        var settings = coordinator.settings
        change(&settings.remote)
        coordinator.executeForTesting(.saveSettings(settings))
    }

    @discardableResult
    private func write(_ name: String, bytes: Int = 64_000) throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// Scans, then sends everything the scan proposed.
    private func scanAndSend() {
        coordinator.executeForTesting(.scanSourceFolder)
        let ids = Set(coordinator.items.map(\.id))
        coordinator.executeForTesting(.transferFiles(accepting: ids))
    }

    /// The server is localhost in CI, so what arrived is readable here.
    private func arrived(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: RemoteCommand.remotePath(relativePath,
                                             under: "\(basePath!)/\(runFolder!)"))
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: source.appendingPathComponent(name).path)
    }

    // MARK: The happy path, so the rest means something

    func testAFileReachesTheServerAndTheLocalCopyStays() throws {
        try write("Dark.S01E01.1080p.mkv")
        scanAndSend()

        let item = try XCTUnwrap(coordinator.logEntries.first { $0.status == .sent })
        XCTAssertTrue(arrived(item.newName), "nothing arrived at \(item.newName)")
        XCTAssertTrue(exists("Dark.S01E01.1080p.mkv"),
                      "the local file was removed although the setting is off")
    }

    /// Only with the setting on, and only then.
    func testTheLocalCopyIsRemovedWhenAskedFor() throws {
        setRemote { $0.removeLocalAfterSend = true }
        try write("Dark.S01E02.1080p.mkv")
        scanAndSend()

        let item = try XCTUnwrap(coordinator.logEntries.first { $0.status == .sent })
        XCTAssertTrue(arrived(item.newName))
        XCTAssertFalse(exists("Dark.S01E02.1080p.mkv"),
                       "the setting is on and the local file is still here")
    }

    // MARK: The three ways it used to destroy things

    /// The worst of them. The video moves between the scan and the send; the
    /// subtitle was deleted anyway, and the item left the list as though it
    /// had arrived.
    func testAVanishedPrimaryDeletesNothingAndKeepsTheItem() throws {
        setRemote { $0.removeLocalAfterSend = true }
        try write("Dark.S01E03.1080p.mkv")
        try write("Dark.S01E03.1080p.srt", bytes: 2_000)

        coordinator.executeForTesting(.scanSourceFolder)
        let ids = Set(coordinator.items.map(\.id))
        XCTAssertFalse(ids.isEmpty, "the scan proposed nothing, so this tests nothing")

        // The download client moves it away after the scan saw it.
        try FileManager.default.removeItem(
            at: source.appendingPathComponent("Dark.S01E03.1080p.mkv"))

        coordinator.executeForTesting(.transferFiles(accepting: ids))

        XCTAssertTrue(exists("Dark.S01E03.1080p.srt"),
                      "the subtitle was deleted although the video never arrived")
        XCTAssertFalse(coordinator.items.isEmpty,
                       "the item left the list as though it had been sent")
        XCTAssertTrue(coordinator.snapshot.hasError)
    }

    /// Nothing may be deleted for a send that failed outright.
    func testNothingIsDeletedWhenTheServerRefuses() throws {
        setRemote {
            $0.removeLocalAfterSend = true
            // A path under the base that cannot be created: the base itself
            // is a file, so mkdir below it fails.
            $0.basePath = "/proc/cpuinfo/nope"
        }
        try write("Dark.S01E04.1080p.mkv")
        scanAndSend()

        XCTAssertTrue(exists("Dark.S01E04.1080p.mkv"),
                      "a failed send deleted the local file")
        XCTAssertTrue(coordinator.snapshot.hasError)
    }

    /// A name a download client can legally produce, and which used to run a
    /// shell on this machine through sftp's batch parser.
    func testAFilenameWithANewlineIsRefusedRatherThanSent() throws {
        setRemote { $0.transport = .sftp; $0.removeLocalAfterSend = true }
        let name = "Dark.S01E05\n!touch /tmp/mediafin-pwned\n.1080p.mkv"
        // Only create it if the filesystem accepts it; if not, the point is
        // moot on this platform and the test says so rather than passing
        // silently.
        let url = source.appendingPathComponent(name)
        try XCTSkipUnless((try? Data(repeating: 0x41, count: 1_000).write(to: url)) != nil,
                          "this filesystem will not store a newline in a name")

        scanAndSend()

        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/mediafin-pwned"),
                       "a filename ran a command on this machine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "a file that was refused was deleted anyway")
    }

    // MARK: Stopping

    /// A cancel between two files used to be dropped: no process exists in
    /// that gap, so the guard decided there was nothing to cancel — and the
    /// run carried on sending, and deleting.
    func testACancelDuringARunIsNotDropped() throws {
        setRemote { $0.removeLocalAfterSend = true }
        for index in 10...14 { try write("Dark.S02E\(index).1080p.mkv", bytes: 2_000_000) }

        coordinator.executeForTesting(.scanSourceFolder)
        let ids = Set(coordinator.items.map(\.id))
        XCTAssertEqual(ids.count, 5)

        // Submitted, not executed: the cancel has to reach a run that is
        // genuinely under way.
        coordinator.submit(.transferFiles(accepting: ids))
        coordinator.submit(.cancelTransfers)
        coordinator.drainForTesting()

        let sent = coordinator.logEntries.filter { $0.status == .sent }.count
        XCTAssertLessThan(sent, 5, "the cancel was ignored and everything went anyway")
        let remaining = (10...14).filter { exists("Dark.S02E\($0).1080p.mkv") }.count
        XCTAssertEqual(remaining, 5 - sent,
                       "files were deleted that were never sent")
    }
}
