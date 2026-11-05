import XCTest
@testable import MediaIdentifierCore

/// The transfer, against a real SSH server.
///
/// Everything else about this feature is tested by reading command lines,
/// which proves the arguments are what was intended and nothing about
/// whether they work. These tests run the actual rsync and sftp binaries
/// against an sshd the CI job starts, with a real key and a real password,
/// and check that the file arrives where the planner said it should.
///
/// Skipped unless `MEDIAFIN_SSH_TEST_HOST` is set, so a developer without a
/// server — and the macOS job, which has no sshd — runs everything else
/// normally. The CI step that provides the server is in build.yml; if these
/// ever stop running there, the count printed at the end of the job drops
/// and the skip is visible rather than silent.
final class RemoteTransferIntegrationTests: XCTestCase {

    private struct Server {
        let host: String
        let port: Int
        let user: String
        let keyFile: String
        let password: String
        let basePath: String
    }

    private var server: Server?
    private var sourceFile: URL!
    private var sourceDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["MEDIAFIN_SSH_TEST_HOST"], !host.isEmpty else {
            throw XCTSkip("no SSH server configured; set MEDIAFIN_SSH_TEST_HOST")
        }
        server = Server(
            host: host,
            port: Int(environment["MEDIAFIN_SSH_TEST_PORT"] ?? "22") ?? 22,
            user: environment["MEDIAFIN_SSH_TEST_USER"] ?? NSUserName(),
            keyFile: environment["MEDIAFIN_SSH_TEST_KEY"] ?? "",
            password: environment["MEDIAFIN_SSH_TEST_PASSWORD"] ?? "",
            basePath: environment["MEDIAFIN_SSH_TEST_BASE"] ?? "/tmp/mediafin-remote"
        )

        sourceDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mediafin-send-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDirectory,
                                                withIntermediateDirectories: true)
        sourceFile = sourceDirectory.appendingPathComponent("Dark.S01E01.mkv")
        // Large enough that the tools print progress at all: a file that
        // transfers in one chunk may never report a percentage, and the
        // progress assertions below would then be testing nothing.
        try Data(repeating: 0x5A, count: 6_000_000).write(to: sourceFile)
        // Last, after the coordinator exists: its init calls
        // Text.start from the settings it loads, which would
        // otherwise undo this.
        Text.language = .english
    }

    override func tearDownWithError() throws {
        Text.language = .german
        if let sourceDirectory { try? FileManager.default.removeItem(at: sourceDirectory) }
        try super.tearDownWithError()
    }

    /// Where this run writes, so parallel runs and reruns cannot collide.
    private func relativePath(_ label: String) -> String {
        "Serien/Dark/Staffel 01/\(label)-\(UUID().uuidString).mkv"
    }

    private func target(_ transport: RemoteTarget.Transport,
                        _ auth: RemoteTarget.Authentication) throws -> RemoteTarget {
        let server = try XCTUnwrap(self.server)
        return RemoteTarget(isEnabled: true, host: server.host, port: server.port,
                            user: server.user, basePath: server.basePath,
                            transport: transport, authentication: auth,
                            identityFile: auth == .key ? server.keyFile : "")
    }

    private func password(for auth: RemoteTarget.Authentication) -> String? {
        auth == .password ? server?.password : nil
    }

    /// The file really is on the other side, and it is the same file.
    private func assertArrived(_ relative: String) throws {
        let server = try XCTUnwrap(self.server)
        let remote = RemoteCommand.remotePath(relative, under: server.basePath)
        // The server is localhost in CI, so the "remote" path is readable
        // here. That is what makes this checkable at all.
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote),
                      "nothing arrived at \(remote)")
        let sent = try Data(contentsOf: sourceFile)
        let received = try Data(contentsOf: URL(fileURLWithPath: remote))
        XCTAssertEqual(received.count, sent.count, "arrived truncated")
        XCTAssertEqual(received, sent, "arrived corrupted")
    }

    // MARK: The four combinations

    func testRsyncWithKey() throws { try roundTrip(.rsync, .key) }
    func testRsyncWithPassword() throws { try roundTrip(.rsync, .password) }
    func testSftpWithKey() throws { try roundTrip(.sftp, .key) }
    func testSftpWithPassword() throws { try roundTrip(.sftp, .password) }

    private func roundTrip(_ transport: RemoteTarget.Transport,
                           _ auth: RemoteTarget.Authentication) throws {
        if auth == .password, (server?.password ?? "").isEmpty {
            throw XCTSkip("no password configured for the test server")
        }
        let relative = relativePath("\(transport)-\(auth)")
        let seen = ProgressRecorder()

        try RemoteTransfer().send(sourceFile, relativePath: relative,
                                  to: try target(transport, auth),
                                  password: password(for: auth),
                                  progress: { seen.record($0) })

        try assertArrived(relative)

        // The parser was written from the documented format without either
        // tool to hand. This is the assertion that says it reads reality —
        // and the first run of it found that sftp reports nothing at all,
        // which is now what `reportsProgress` says and what the interface
        // tells the user.
        if transport.reportsProgress {
            XCTAssertTrue(seen.sawRealProgress,
                          "no progress was parsed from \(transport); "
                              + "the output format is not what the parser expects")
        } else {
            XCTAssertFalse(
                seen.sawRealProgress,
                "\(transport) reported progress after all. That is good news, but "
                    + "`reportsProgress` and the transport's label both say it does not — "
                    + "fix them rather than this assertion.")
        }
    }

    /// The directories below the base are created on the way, so a second
    /// episode of the same series does not need them to exist already.
    func testCreatesTheSeasonFolder() throws {
        let relative = relativePath("deep/one/two/three")
        try RemoteTransfer().send(sourceFile, relativePath: relative,
                                  to: try target(.rsync, .key), password: nil)
        try assertArrived(relative)
    }

    /// Names with spaces survive the trip. Without --protect-args the remote
    /// shell splits "Staffel 01" and the file lands in the wrong place — and
    /// that is a bug no argument-reading test can see.
    func testPathsWithSpacesArriveInOnePiece() throws {
        let relative = "Serien/Der Name der Rose/Staffel 01/"
            + "Folge 1 - Ein später Tag-\(UUID().uuidString).mkv"
        try RemoteTransfer().send(sourceFile, relativePath: relative,
                                  to: try target(.rsync, .key), password: nil)
        try assertArrived(relative)
    }

    func testPathsWithSpacesArriveOverSftpToo() throws {
        let relative = "Serien/Der Name der Rose/Staffel 02/"
            + "Folge 2 - Noch später-\(UUID().uuidString).mkv"
        try RemoteTransfer().send(sourceFile, relativePath: relative,
                                  to: try target(.sftp, .key), password: nil)
        try assertArrived(relative)
    }

    // MARK: The security property, proved rather than asserted

    /// An unknown host must stop the transfer.
    ///
    /// Every other test here has the host key in known_hosts, so this is the
    /// only one that shows the check is live. It points at a host that
    /// cannot be in known_hosts and expects a refusal — if this ever passes
    /// a transfer, StrictHostKeyChecking has been turned off somewhere.
    func testAnUnknownHostIsRefused() throws {
        var unknown = try target(.rsync, .key)
        // The same server, reached by a name that was never scanned.
        // known_hosts holds "127.0.0.1" and nothing else, so "localhost"
        // resolves to the very same sshd and is still an unknown host —
        // which is the point: the refusal is about the key, not the route.
        unknown.host = "localhost"
        XCTAssertThrowsError(
            try RemoteTransfer().send(sourceFile, relativePath: relativePath("refused"),
                                      to: unknown, password: nil)
        ) { error in
            let message = "\(error)"
            XCTAssertTrue(
                message.lowercased().contains("host key")
                    || message.lowercased().contains("verification"),
                "refused for the wrong reason: \(message)"
            )
        }
    }

    /// Collects progress across the reader thread.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var fractions: [Double] = []
        func record(_ progress: RemoteTransfer.Progress) {
            lock.lock(); fractions.append(progress.fraction); lock.unlock()
        }
        /// Something other than the completion value the sender always
        /// reports at the end — otherwise this would pass without the
        /// parser ever having worked.
        var sawRealProgress: Bool {
            lock.lock(); defer { lock.unlock() }
            return fractions.contains { $0 > 0 && $0 < 1 } || fractions.count > 1
        }
    }
}
