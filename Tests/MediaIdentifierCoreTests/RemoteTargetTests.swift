import XCTest
@testable import MediaIdentifierCore

final class RemoteTargetTests: XCTestCase {

    func testDisabledTargetIsNeverComplainedAbout() {
        // Half-filled and switched off is the normal state of someone who
        // has not set this up. It must not block saving anything else.
        var target = RemoteTarget(isEnabled: false)
        target.host = "nas.local"
        XCTAssertTrue(target.problems().isEmpty)
    }

    func testEnabledTargetNeedsHostUserAndPath() {
        let problems = RemoteTarget(isEnabled: true).problems().map(\.field)
        XCTAssertTrue(problems.contains("remoteHost"))
        XCTAssertTrue(problems.contains("remoteUser"))
        XCTAssertTrue(problems.contains("remoteBasePath"))
    }

    /// A relative path lands in the login directory, which is rarely where a
    /// media library is and is hard to notice afterwards.
    func testRelativeBasePathIsRejected() {
        let target = RemoteTarget(isEnabled: true, host: "nas", user: "tam",
                                  basePath: "media")
        XCTAssertEqual(target.problems().map(\.field), ["remoteBasePath"])
    }

    func testAHostWithASlashIsRejected() {
        let target = RemoteTarget(isEnabled: true, host: "nas.local/media",
                                  user: "tam", basePath: "/srv")
        XCTAssertEqual(target.problems().map(\.field), ["remoteHost"])
    }

    func testCompleteTargetHasNoProblems() {
        let target = RemoteTarget(isEnabled: true, host: "nas.local", port: 2222,
                                  user: "tam", basePath: "/srv/media")
        XCTAssertTrue(target.problems().isEmpty, "\(target.problems())")
    }

    func testWhitespaceIsTrimmedOnTheWayIn() {
        let target = RemoteTarget(isEnabled: true, host: "  nas.local \n",
                                  user: " tam ", basePath: " /srv/media ")
        XCTAssertEqual(target.host, "nas.local")
        XCTAssertEqual(target.user, "tam")
        XCTAssertEqual(target.basePath, "/srv/media")
    }

    /// An impossible port is KEPT and reported, not corrected.
    ///
    /// It used to be clamped to 22 on the way in, which made the
    /// "Der Port muss 1–65535 sein." message unreachable and turned a
    /// typo into a connection to a different machine's SSH port. This
    /// test asserted the clamping — it pinned the defect in place.
    func testAnImpossiblePortIsReportedRatherThanCorrected() {
        XCTAssertEqual(RemoteTarget(port: 70000).port, 70000, "the value was rewritten")
        XCTAssertEqual(RemoteTarget(port: 2222).port, 2222)

        let broken = RemoteTarget(isEnabled: true, host: "nas", port: 70000,
                                  user: "tam", basePath: "/srv")
        XCTAssertTrue(broken.problems().contains { $0.field == "remotePort" },
                      "an impossible port produced no complaint")
        let fine = RemoteTarget(isEnabled: true, host: "nas", port: 2222,
                                user: "tam", basePath: "/srv")
        XCTAssertTrue(fine.problems().isEmpty)
    }

    func testDestinationIsUserAtHost() {
        XCTAssertEqual(RemoteTarget(host: "nas", user: "tam").destination, "tam@nas")
        // No user set yet: ssh would use the local account name, which is a
        // reasonable default and better than "@nas".
        XCTAssertEqual(RemoteTarget(host: "nas").destination, "nas")
    }

    // MARK: Settings file

    /// A hand-edited settings file gets the same treatment as the form:
    /// trimmed, and an impossible port kept so it can be complained about.
    func testDecodingAppliesTheSameRulesAsTheForm() throws {
        let json = #"{"isEnabled":true,"host":" nas ","port":70000,"user":"tam","basePath":"/srv"}"#
        let target = try JSONDecoder().decode(RemoteTarget.self, from: Data(json.utf8))
        XCTAssertEqual(target.host, "nas")
        XCTAssertEqual(target.port, 70000)
        XCTAssertTrue(target.problems().contains { $0.field == "remotePort" })
    }

    func testRoundTripIsLossless() throws {
        let original = RemoteTarget(isEnabled: true, host: "nas.local", port: 2222,
                                    user: "tam", basePath: "/srv/media",
                                    transport: .sftp, authentication: .password,
                                    identityFile: "/home/tam/.ssh/nas")
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(RemoteTarget.self, from: data), original)
    }

    /// A settings file written before this existed must still load.
    func testSettingsWithoutARemoteSectionStillLoad() throws {
        let json = #"{"sourceFolder":"/import"}"#
        let settings = try JSONDecoder().decode(WebSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.sourceFolder, "/import")
        XCTAssertFalse(settings.remote.isEnabled)
    }

    /// And a damaged remote section must not take the rest of the file down.
    func testADamagedRemoteSectionFallsBackOnItsOwn() throws {
        let json = #"{"sourceFolder":"/import","remote":"not-an-object"}"#
        let settings = try JSONDecoder().decode(WebSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.sourceFolder, "/import")
        XCTAssertEqual(settings.remote, RemoteTarget())
    }

    /// The validation has to reach through the settings, or a broken server
    /// configuration would save silently and fail at transfer time.
    func testSettingsValidationIncludesTheRemoteTarget() {
        var settings = WebSettings()
        settings.remote = RemoteTarget(isEnabled: true, host: "", user: "", basePath: "")
        XCTAssertFalse(settings.problems().isEmpty)
    }
}
