import XCTest
@testable import MediaIdentifierCore

/// The progress parser and the error wording.
///
/// A caveat worth stating: the samples below are what rsync and sftp are
/// believed to print, written from their documented format rather than
/// captured from a run — neither tool is installed where these tests were
/// written. They pin the parser's behaviour and catch regressions, but they
/// are not proof that the format is right. That proof is in
/// `RemoteTransferIntegrationTests`, which runs the real tools against a
/// real sshd and asserts that progress was actually observed.
final class RemoteTransferTests: XCTestCase {

    // MARK: Progress

    func testReadsAPercentageFromAnRsyncLine() {
        let line = "  1,234,567  45%   12.34MB/s    0:00:05"
        let progress = RemoteTransfer.parseProgress(line)
        XCTAssertEqual(progress?.fraction ?? 0, 0.45, accuracy: 0.001)
        XCTAssertEqual(progress?.speed, "12.34MB/s")
    }

    func testReadsAPercentageFromAnSftpLine() {
        let line = "Dark - S01E01.mkv   45% 1234KB   1.2MB/s   00:01 ETA"
        let progress = RemoteTransfer.parseProgress(line)
        XCTAssertEqual(progress?.fraction ?? 0, 0.45, accuracy: 0.001)
        XCTAssertEqual(progress?.speed, "1.2MB/s")
    }

    /// Both tools overwrite one line with carriage returns rather than
    /// printing a stream of them, so a single read holds several updates and
    /// the last one is the current state.
    func testTakesTheLastUpdateInAChunk() {
        let chunk = "  10%  1MB/s\r  55%  2MB/s\r  90%  3MB/s"
        XCTAssertEqual(RemoteTransfer.parseProgress(chunk)?.fraction ?? 0, 0.9, accuracy: 0.001)
    }

    /// Nil, not zero. A caller shown 0% would be reporting progress that was
    /// never measured, which looks like a stalled transfer.
    func testOutputWithoutAPercentageIsNotProgress() {
        XCTAssertNil(RemoteTransfer.parseProgress("sending incremental file list"))
        XCTAssertNil(RemoteTransfer.parseProgress(""))
        XCTAssertNil(RemoteTransfer.parseProgress("total size is 1,234  speedup is 1.00"))
    }

    func testCompletionAndStartAreBothRecognised() {
        XCTAssertEqual(RemoteTransfer.parseProgress("  0%")?.fraction, 0)
        XCTAssertEqual(RemoteTransfer.parseProgress("100%")?.fraction, 1)
    }

    /// A byte count can run to any number of digits; only something that is
    /// actually a percentage may be read as one.
    func testALargeNumberIsNotMistakenForAPercentage() {
        XCTAssertNil(RemoteTransfer.parseProgress("1234567 bytes"))
        XCTAssertNil(RemoteTransfer.parseProgress("sent 1,234,567"))
    }

    func testProgressWithoutARateStillReports() {
        let progress = RemoteTransfer.parseProgress("   33%")
        XCTAssertEqual(progress?.fraction ?? 0, 0.33, accuracy: 0.001)
        XCTAssertNil(progress?.speed)
    }

    // MARK: Error wording

    /// The message a user is most likely to meet, and the one whose remedy
    /// is least obvious from what ssh prints.
    func testUnknownHostIsExplainedWithWhatToDo() {
        let message = RemoteTransfer.explain("Host key verification failed.")
        XCTAssertTrue(message.contains("ssh BENUTZER@SERVER"))
        // The original is kept: it is what a search engine will match.
        XCTAssertTrue(message.contains("Host key verification failed."))
    }

    func testRefusedLoginIsExplained() {
        let message = RemoteTransfer.explain("Permission denied (publickey,password).")
        XCTAssertTrue(message.contains("Anmeldung abgelehnt"))
    }

    func testAnUnrecognisedErrorIsPassedThroughUnchanged() {
        XCTAssertEqual(RemoteTransfer.explain("  something else entirely  "),
                       "something else entirely")
    }

    // MARK: Tools

    func testMissingToolsAreNamedPerTransport() {
        let none = RemoteTools(rsync: nil, sftp: nil, ssh: nil, sshpass: nil)
        let rsyncTarget = RemoteTarget(transport: .rsync, authentication: .key)
        XCTAssertEqual(none.missing(for: rsyncTarget), ["rsync", "openssh-client"])

        let sftpTarget = RemoteTarget(transport: .sftp, authentication: .key)
        XCTAssertEqual(none.missing(for: sftpTarget), ["openssh-client"])
    }

    func testPasswordAuthenticationAlsoNeedsSshpass() {
        let tools = RemoteTools(rsync: "/usr/bin/rsync", sftp: "/usr/bin/sftp",
                                ssh: "/usr/bin/ssh", sshpass: nil)
        let target = RemoteTarget(transport: .rsync, authentication: .password)
        XCTAssertEqual(tools.missing(for: target), ["sshpass"])
    }

    func testNothingIsMissingWhenEverythingIsPresent() {
        let tools = RemoteTools(rsync: "/usr/bin/rsync", sftp: "/usr/bin/sftp",
                                ssh: "/usr/bin/ssh", sshpass: "/usr/bin/sshpass")
        for transport in RemoteTarget.Transport.allCases {
            for auth in RemoteTarget.Authentication.allCases {
                XCTAssertTrue(tools.missing(for: RemoteTarget(transport: transport,
                                                              authentication: auth)).isEmpty)
            }
        }
    }

    /// A bare name would be resolved through PATH, and a service that runs
    /// the first rsync it finds can be made to run something else.
    func testToolsAreLookedUpByAbsolutePath() {
        for path in RemoteTools.searchPaths {
            XCTAssertTrue(path.hasPrefix("/"), path)
        }
    }
}
