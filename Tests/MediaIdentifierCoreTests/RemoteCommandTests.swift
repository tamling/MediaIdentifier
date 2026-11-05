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

    /// "Trust the server the first time" is accept-new and never no.
    ///
    /// The difference is the whole security argument for offering the option
    /// at all: accept-new remembers a server it has not met, and still
    /// refuses one whose key has changed — which is the case that means
    /// another machine is answering. `no` accepts that too.
    func testTrustOnFirstUseAcceptsNewKeysAndStillRefusesChangedOnes() throws {
        var trusting = target()
        trusting.trustOnFirstUse = true
        for transport in RemoteTarget.Transport.allCases {
            let invocation = transport == .rsync
                ? try RemoteCommand.rsync(
                    trusting, localFile: file, relativePath: relative, library: .series,
                    rsyncPath: "/usr/bin/rsync", sshPath: "/usr/bin/ssh", password: nil)
                : try RemoteCommand.sftp(
                    trusting, localFile: file, relativePath: relative, library: .series,
                    sftpPath: "/usr/bin/sftp", password: nil)
            let joined = invocation.arguments.joined(separator: " ")
            XCTAssertTrue(joined.contains("StrictHostKeyChecking=accept-new"),
                          "\(transport): \(joined)")
            XCTAssertFalse(joined.contains("StrictHostKeyChecking=no"), joined)
            XCTAssertFalse(joined.contains("StrictHostKeyChecking=yes"), joined)
        }
    }

    // MARK: One path per kind

    /// The reason the option exists: a server with the three libraries on
    /// different disks. Sending music under the film path is not a cosmetic
    /// mistake — it puts albums where the media server will not look.
    func testEachKindGoesUnderItsOwnPath() throws {
        var split = target()
        split.moviesPath = "/volume1/Filme"
        split.seriesPath = "/volume2/Serien"
        split.musicPath = "/volume1/Musik"

        let cases: [(RemoteTarget.Library, String)] = [
            (.movies, "/volume1/Filme/x.mkv"),
            (.series, "/volume2/Serien/x.mkv"),
            (.music, "/volume1/Musik/x.mkv"),
        ]
        for (library, expected) in cases {
            let invocation = try RemoteCommand.rsync(
                split, localFile: file, relativePath: "x.mkv", library: library,
                rsyncPath: "/usr/bin/rsync", sshPath: "/usr/bin/ssh", password: nil)
            XCTAssertEqual(invocation.arguments.last, "tam@nas.local:" + expected)
        }
    }

    /// A kind with no path of its own keeps using the base path, so a setup
    /// that worked with one path goes on working untouched.
    func testAKindWithoutItsOwnPathFallsBackToTheBase() throws {
        var partial = target()
        partial.musicPath = "/volume1/Musik"
        let script = try XCTUnwrap(RemoteCommand.sftp(
            partial, localFile: file, relativePath: "x.mkv", library: .movies,
            sftpPath: "/usr/bin/sftp", password: nil).standardInput)
        XCTAssertTrue(script.contains("\"/srv/media/x.mkv\""), script)
    }

    /// The test would be worthless if it only looked at one of the three:
    /// films working while music silently does not is exactly what one path
    /// per kind makes possible.
    func testTheConnectionTestChecksEveryConfiguredPath() throws {
        var split = target()
        split.moviesPath = "/volume1/Filme"
        split.seriesPath = "/volume2/Serien"
        split.musicPath = "/volume1/Musik"
        let command = try XCTUnwrap(
            try RemoteCommand.probe(split, sshPath: "/usr/bin/ssh",
                                    password: nil).arguments.last)
        for path in ["/volume1/Filme", "/volume2/Serien", "/volume1/Musik"] {
            XCTAssertTrue(command.contains("test -d '\(path)'"), command)
            XCTAssertTrue(command.contains("test -w '\(path)'"), command)
        }
    }

    /// One path for everything is still one check, not three identical ones.
    func testTheConnectionTestDoesNotRepeatTheSamePath() throws {
        let command = try XCTUnwrap(
            try RemoteCommand.probe(target(), sshPath: "/usr/bin/ssh",
                                    password: nil).arguments.last)
        XCTAssertEqual(command.components(separatedBy: "test -d").count - 1, 1, command)
    }

    /// Nothing configured at all is a refusal, not a check of "".
    func testTheConnectionTestRefusesWithNoPathAnywhere() {
        var bare = target()
        bare.basePath = ""
        XCTAssertThrowsError(try RemoteCommand.probe(bare, sshPath: "ssh", password: nil))
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
            target(), localFile: file, relativePath: relative, library: .series,
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
            target(), localFile: file, relativePath: relative, library: .series,
            rsyncPath: "/usr/bin/rsync", sshPath: "/usr/bin/ssh", password: nil
        )
        XCTAssertTrue(invocation.arguments.contains("--protect-args"))
    }

    func testRsyncCarriesThePortIntoTheSSHCommand() throws {
        let invocation = try RemoteCommand.rsync(
            target(port: 2222), localFile: file, relativePath: relative, library: .series,
            rsyncPath: "/usr/bin/rsync", sshPath: "/usr/bin/ssh", password: nil
        )
        let sshCommand = try XCTUnwrap(
            invocation.arguments.first { $0.contains("/usr/bin/ssh") })
        XCTAssertTrue(sshCommand.contains("-p 2222"), sshCommand)
    }

    func testRsyncAsksForResumableProgress() throws {
        let invocation = try RemoteCommand.rsync(
            target(), localFile: file, relativePath: relative, library: .series,
            rsyncPath: "/usr/bin/rsync", sshPath: "/usr/bin/ssh", password: nil
        )
        // --partial-dir, not --partial: a plain --partial leaves the
        // fragment under the final name, and --ignore-existing then skips
        // it on the retry, reports success, and lets the local original be
        // deleted while the server keeps a truncated file.
        XCTAssertTrue(invocation.arguments.contains("--partial-dir=.mediafin-partial"),
                      "\(invocation.arguments)")
        XCTAssertFalse(invocation.arguments.contains("--partial"),
                       "a bare --partial puts the fragment under the final name")
        XCTAssertTrue(invocation.arguments.contains("--info=progress2"))
        XCTAssertTrue(invocation.arguments.contains("--mkpath"))
    }

    /// The pair that caused it, asserted together so neither can come back
    /// on its own.
    func testSkippingExistingFilesCannotMistakeAFragmentForOne() throws {
        let invocation = try RemoteCommand.rsync(
            target(), localFile: file, relativePath: relative, library: .series,
            rsyncPath: "/usr/bin/rsync", sshPath: "/usr/bin/ssh", password: nil,
            keepExisting: true
        )
        XCTAssertTrue(invocation.arguments.contains("--ignore-existing"))
        XCTAssertTrue(invocation.arguments.contains("--partial-dir=.mediafin-partial"))
    }

    func testRsyncUsesTheIdentityFileAndOnlyThatOne() throws {
        let invocation = try RemoteCommand.rsync(
            target(identity: "/home/tam/.ssh/nas"), localFile: file,
            relativePath: relative, library: .series, rsyncPath: "/usr/bin/rsync",
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
            target(.sftp), localFile: file, relativePath: relative, library: .series,
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
            target(.sftp), localFile: file, relativePath: relative, library: .series,
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
            target(.sftp, port: 2222), localFile: file, relativePath: relative, library: .series,
            sftpPath: "/usr/bin/sftp", password: nil
        )
        XCTAssertTrue(invocation.arguments.contains("-P"))
        XCTAssertTrue(invocation.arguments.contains("2222"))
    }

    /// With a password, sshpass runs sftp rather than the other way round.
    func testSftpWithPasswordRunsThroughSshpass() throws {
        let invocation = try RemoteCommand.sftp(
            target(.sftp, auth: .password), localFile: file, relativePath: relative, library: .series,
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
            empty, localFile: file, relativePath: relative, library: .series,
            rsyncPath: "rsync", sshPath: "ssh", password: nil))
        XCTAssertThrowsError(try RemoteCommand.sftp(
            empty, localFile: file, relativePath: relative, library: .series,
            sftpPath: "sftp", password: nil))
    }

    // MARK: Helper

    private func build(_ transport: RemoteTarget.Transport,
                       auth: RemoteTarget.Authentication = .key,
                       password: String? = "hunter2") throws -> RemoteCommand.Invocation {
        switch transport {
        case .rsync:
            return try RemoteCommand.rsync(
                target(.rsync, auth: auth), localFile: file, relativePath: relative, library: .series,
                rsyncPath: "/usr/bin/rsync", sshPath: "/usr/bin/ssh", password: password)
        case .sftp:
            return try RemoteCommand.sftp(
                target(.sftp, auth: auth), localFile: file, relativePath: relative, library: .series,
                sftpPath: "/usr/bin/sftp", password: password)
        }
    }
}
