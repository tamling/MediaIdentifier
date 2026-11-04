import XCTest
@testable import MediaIdentifierCore

/// The command lines that move someone's library to another machine.
///
/// These are worth testing hard precisely because they look obvious. A space
/// in a path, a port quietly dropped, a host key check turned off to make
/// the first attempt work: each produces code that runs, and the failure
/// surfaces as a file in the wrong place, a transfer to the wrong machine,
/// or nothing at all.
final class RemoteCommandTests: XCTestCase {

    private func target(_ transport: RemoteTarget.Transport = .rsync,
                        auth: RemoteTarget.Authentication = .key,
                        port: Int = 22,
                        base: String = "/srv/media",
                        identity: String = "") -> RemoteTarget {
        RemoteTarget(isEnabled: true, host: "nas.local", port: port, user: "tam",
                     basePath: base, transport: transport,
                     authentication: auth, identityFile: identity)
    }

    private let file = URL(fileURLWithPath: "/home/tam/Downloads/Dark.S01E01.mkv")
    private let relative = "Serien/Dark/Staffel 01/Dark - S01E01.mkv"

    // MARK: Paths

    func testRemotePathJoinsBaseAndRelative() {
        XCTAssertEqual(RemoteCommand.remotePath("a/b.mkv", under: "/srv/media"),
                       "/srv/media/a/b.mkv")
    }

    /// A base path typed with a trailing slash is the same base path.
    func testTrailingAndLeadingSlashesDoNotDouble() {
        XCTAssertEqual(RemoteCommand.remotePath("a/b.mkv", under: "/srv/media/"),
                       "/srv/media/a/b.mkv")
        XCTAssertEqual(RemoteCommand.remotePath("/a/b.mkv", under: "/srv/media/"),
                       "/srv/media/a/b.mkv")
    }

    func testParentDirectoriesAreListedFromTheRootDown() {
        XCTAssertEqual(
            RemoteCommand.parentDirectories(of: "/srv/media/Serien/Dark"),
            ["/srv", "/srv/media", "/srv/media/Serien", "/srv/media/Serien/Dark"]
        )
    }

    // MARK: Host key checking

    /// The one setting that would make everything else here pointless.
    /// Accepting whatever key answers is how a library ends up on someone
    /// else's machine.
    func testHostKeyCheckingIsNeverDisabled() throws {
        for auth in RemoteTarget.Authentication.allCases {
            for transport in RemoteTarget.Transport.allCases {
                let invocation = try build(transport, auth: auth)
                let joined = invocation.arguments.joined(separator: " ")
                XCTAssertTrue(joined.contains("StrictHostKeyChecking=yes"),
                              "\(transport)/\(auth): \(joined)")
                XCTAssertFalse(joined.contains("StrictHostKeyChecking=no"))
                XCTAssertFalse(joined.contains("StrictHostKeyChecking=accept-new"))
                XCTAssertFalse(joined.lowercased().contains("userknownhostsfile=/dev/null"))
            }
        }
    }

    // MARK: Passwords

    /// A password in argv is readable by every user on the machine through
    /// `ps`. It goes in the environment or nowhere.
    func testPasswordNeverAppearsInTheArguments() throws {
        for transport in RemoteTarget.Transport.allCases {
            let invocation = try build(transport, auth: .password, password: "hunter2")
            XCTAssertFalse(invocation.arguments.contains { $0.contains("hunter2") },
                           "\(transport): \(invocation.arguments)")
            XCTAssertFalse((invocation.standardInput ?? "").contains("hunter2"))
            XCTAssertEqual(invocation.environment["SSHPASS"], "hunter2")
        }
    }

    func testPasswordModeRefusesWithoutAPassword() {
        for transport in RemoteTarget.Transport.allCases {
            XCTAssertThrowsError(try build(transport, auth: .password, password: nil))
            XCTAssertThrowsError(try build(transport, auth: .password, password: ""))
        }
    }

    /// With a key there is nothing to store and nothing to leak.
    func testKeyModeSetsNoEnvironment() throws {
        for transport in RemoteTarget.Transport.allCases {
            XCTAssertTrue(try build(transport, auth: .key).environment.isEmpty)
        }
    }

    // MARK: rsync

    func testRsyncSendsToTheRightPlace() throws {
        let invocation = try RemoteCommand.rsync(
            target(), localFile: file, relativePath: relative,
            rsyncPath: "/usr/bin/rsync", sshPath: "/usr/bin/ssh", password: nil
        )
        XCTAssertEqual(invocation.executable, "/usr/bin/rsync")
        XCTAssertEqual(invocation.arguments.last,
                       "tam@nas.local:/srv/media/Serien/Dark/Staffel 01/Dark - S01E01.mkv")
        XCTAssertTrue(invocation.arguments.contains(file.path))
    }

    /// Without --protect-args the remote shell splits the path again and a
    /// season folder with a space becomes two directories.
    func testRsyncProtectsRemoteArgumentsFromTheShell() throws {
        let invocation = try RemoteCommand.rsync(
            target(), localFile: file, relativePath: relative,
            rsyncPath: "/usr/bin/rsync", sshPath: "/usr/bin/ssh", password: nil
        )
        XCTAssertTrue(invocation.arguments.contains("--protect-args"))
    }

    func testRsyncCarriesThePortIntoTheSSHCommand() throws {
        let invocation = try RemoteCommand.rsync(
            target(port: 2222), localFile: file, relativePath: relative,
            rsyncPath: "/usr/bin/rsync", sshPath: "/usr/bin/ssh", password: nil
        )
        let sshCommand = try XCTUnwrap(
            invocation.arguments.first { $0.contains("/usr/bin/ssh") })
        XCTAssertTrue(sshCommand.contains("-p 2222"), sshCommand)
    }

    func testRsyncAsksForResumableProgress() throws {
        let invocation = try RemoteCommand.rsync(
            target(), localFile: file, relativePath: relative,
            rsyncPath: "/usr/bin/rsync", sshPath: "/usr/bin/ssh", password: nil
        )
        XCTAssertTrue(invocation.arguments.contains("--partial"))
        XCTAssertTrue(invocation.arguments.contains("--info=progress2"))
        XCTAssertTrue(invocation.arguments.contains("--mkpath"))
    }

    func testRsyncUsesTheIdentityFileAndOnlyThatOne() throws {
        let invocation = try RemoteCommand.rsync(
            target(identity: "/home/tam/.ssh/nas"), localFile: file,
            relativePath: relative, rsyncPath: "/usr/bin/rsync",
            sshPath: "/usr/bin/ssh", password: nil
        )
        let sshCommand = try XCTUnwrap(
            invocation.arguments.first { $0.contains("/usr/bin/ssh") })
        XCTAssertTrue(sshCommand.contains("-i /home/tam/.ssh/nas"))
        // Or ssh offers every key the agent holds and can be locked out
        // before it reaches the right one.
        XCTAssertTrue(sshCommand.contains("IdentitiesOnly=yes"))
    }

    // MARK: sftp

    func testSftpBuildsEveryDirectoryThenPuts() throws {
        let invocation = try RemoteCommand.sftp(
            target(.sftp), localFile: file, relativePath: relative,
            sftpPath: "/usr/bin/sftp", password: nil
        )
        let script = try XCTUnwrap(invocation.standardInput)
        XCTAssertTrue(script.contains("-mkdir \"/srv\""))
        XCTAssertTrue(script.contains("-mkdir \"/srv/media/Serien/Dark/Staffel 01\""))
        XCTAssertTrue(script.contains(
            "put \"/home/tam/Downloads/Dark.S01E01.mkv\" "
                + "\"/srv/media/Serien/Dark/Staffel 01/Dark - S01E01.mkv\""))
        XCTAssertTrue(script.hasSuffix("bye\n"))
    }

    /// Each mkdir is prefixed with `-` so an existing directory does not
    /// abort the batch — which is the normal case after the first episode.
    func testSftpToleratesDirectoriesThatAlreadyExist() throws {
        let invocation = try RemoteCommand.sftp(
            target(.sftp), localFile: file, relativePath: relative,
            sftpPath: "/usr/bin/sftp", password: nil
        )
        for line in try XCTUnwrap(invocation.standardInput).split(separator: "\n")
        where line.contains("mkdir") {
            XCTAssertTrue(line.hasPrefix("-mkdir"), String(line))
        }
    }

    func testSftpQuotesPathsContainingSpacesAndQuotes() {
        XCTAssertEqual(RemoteCommand.quote("/a b/c.mkv"), "\"/a b/c.mkv\"")
        XCTAssertEqual(RemoteCommand.quote("/a\"b"), "\"/a\\\"b\"")
        XCTAssertEqual(RemoteCommand.quote("/a\\b"), "\"/a\\\\b\"")
    }

    func testSftpCarriesThePort() throws {
        let invocation = try RemoteCommand.sftp(
            target(.sftp, port: 2222), localFile: file, relativePath: relative,
            sftpPath: "/usr/bin/sftp", password: nil
        )
        XCTAssertTrue(invocation.arguments.contains("-P"))
        XCTAssertTrue(invocation.arguments.contains("2222"))
    }

    /// With a password, sshpass runs sftp rather than the other way round.
    func testSftpWithPasswordRunsThroughSshpass() throws {
        let invocation = try RemoteCommand.sftp(
            target(.sftp, auth: .password), localFile: file, relativePath: relative,
            sftpPath: "/usr/bin/sftp", password: "hunter2"
        )
        XCTAssertEqual(invocation.executable, "sshpass")
        XCTAssertEqual(invocation.arguments.first, "-e")
        XCTAssertTrue(invocation.arguments.contains("/usr/bin/sftp"))
    }

    // MARK: Refusals

    func testBothRefuseAnUnconfiguredTarget() {
        var empty = RemoteTarget(isEnabled: true)
        empty.basePath = "/srv"
        XCTAssertThrowsError(try RemoteCommand.rsync(
            empty, localFile: file, relativePath: relative,
            rsyncPath: "rsync", sshPath: "ssh", password: nil))
        XCTAssertThrowsError(try RemoteCommand.sftp(
            empty, localFile: file, relativePath: relative,
            sftpPath: "sftp", password: nil))
    }

    // MARK: Helper

    private func build(_ transport: RemoteTarget.Transport,
                       auth: RemoteTarget.Authentication = .key,
                       password: String? = "hunter2") throws -> RemoteCommand.Invocation {
        switch transport {
        case .rsync:
            return try RemoteCommand.rsync(
                target(.rsync, auth: auth), localFile: file, relativePath: relative,
                rsyncPath: "/usr/bin/rsync", sshPath: "/usr/bin/ssh", password: password)
        case .sftp:
            return try RemoteCommand.sftp(
                target(.sftp, auth: auth), localFile: file, relativePath: relative,
                sftpPath: "/usr/bin/sftp", password: password)
        }
    }
}
