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

    // MARK: One path per kind

    func testAKindWithNoPathOfItsOwnUsesTheBasePath() {
        let target = RemoteTarget(isEnabled: true, host: "nas", user: "tam",
                                  basePath: "/srv/media")
        for library in RemoteTarget.Library.allCases {
            XCTAssertEqual(target.path(for: library), "/srv/media")
        }
    }

    func testAKindsOwnPathWinsOverTheBase() {
        let target = RemoteTarget(isEnabled: true, host: "nas", user: "tam",
                                  basePath: "/srv/media", musicPath: "/volume2/Musik")
        XCTAssertEqual(target.path(for: .music), "/volume2/Musik")
        XCTAssertEqual(target.path(for: .movies), "/srv/media")
        XCTAssertEqual(target.path(for: .series), "/srv/media")
    }

    /// The connection test uses this list, and checking the same path three
    /// times would make a one-path setup three times slower for nothing.
    func testTargetPathsFoldsPathsThatAreTheSame() {
        var target = RemoteTarget(isEnabled: true, host: "nas", user: "tam",
                                  basePath: "/srv/media")
        XCTAssertEqual(target.targetPaths().count, 1)
        XCTAssertEqual(target.targetPaths()[0].libraries.count, 3)

        target.musicPath = "/volume2/Musik"
        let paths = target.targetPaths()
        XCTAssertEqual(paths.map(\.path), ["/srv/media", "/volume2/Musik"])
        XCTAssertEqual(paths[0].libraries, [.movies, .series])
        XCTAssertEqual(paths[1].libraries, [.music])
    }

    /// With all three filled in there is nothing left for a base path to do,
    /// so demanding one would be a complaint about a complete setup.
    func testTheBasePathIsOptionalOnceAllThreeAreSet() {
        let target = RemoteTarget(isEnabled: true, host: "nas", user: "tam",
                                  basePath: "", moviesPath: "/a",
                                  seriesPath: "/b", musicPath: "/c")
        XCTAssertTrue(target.problems().isEmpty, "\(target.problems())")
    }

    /// Two of three is not enough: the third would silently have nowhere to
    /// go, which is the failure this whole check exists to prevent.
    func testTheBasePathIsStillNeededWhenOneKindIsLeftOut() {
        let target = RemoteTarget(isEnabled: true, host: "nas", user: "tam",
                                  basePath: "", moviesPath: "/a", seriesPath: "/b")
        XCTAssertEqual(target.problems().map(\.field), ["remoteBasePath"])
    }

    func testARelativePerKindPathIsRejectedAndNamed() {
        let target = RemoteTarget(isEnabled: true, host: "nas", user: "tam",
                                  basePath: "/srv", seriesPath: "Serien")
        XCTAssertEqual(target.problems().map(\.field), ["remoteSeriesPath"])
    }

    func testThePerKindPathsSurviveARoundTrip() throws {
        let original = RemoteTarget(isEnabled: true, host: "nas.local", port: 2222,
                                    user: "tam", basePath: "/srv/media",
                                    moviesPath: "/v1/Filme", seriesPath: "/v2/Serien",
                                    musicPath: "/v1/Musik", transport: .sftp,
                                    authentication: .password,
                                    identityFile: "/home/tam/.ssh/nas",
                                    trustOnFirstUse: true)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(RemoteTarget.self, from: data), original)
    }

    /// A settings file written before the three paths existed must load, and
    /// must not come back trusting a server it was never told to trust.
    func testASettingsFileFromBeforeThePerKindPathsStillLoads() throws {
        let json = #"{"isEnabled":true,"host":"nas","user":"tam","basePath":"/srv"}"#
        let target = try JSONDecoder().decode(RemoteTarget.self, from: Data(json.utf8))
        XCTAssertEqual(target.path(for: .music), "/srv")
        XCTAssertFalse(target.trustOnFirstUse)
        XCTAssertTrue(target.problems().isEmpty, "\(target.problems())")
    }

    /// A checkbox sends nothing when unticked, so it needs the hidden
    /// companion field that says the section was on the form at all —
    /// otherwise another page's form would silently untick it.
    func testTrustingTheServerNeedsItsSectionToBePresent() {
        var trusting = RemoteTarget(isEnabled: true, host: "nas", user: "tam",
                                    basePath: "/srv")
        trusting.trustOnFirstUse = true
        XCTAssertTrue(RemoteTarget.fromForm([:], current: trusting).trustOnFirstUse,
                      "a form without the server section turned the trust off")
        XCTAssertFalse(RemoteTarget.fromForm(["remoteTrustOnFirstUsePresent": "1"],
                                             current: trusting).trustOnFirstUse)
        XCTAssertTrue(RemoteTarget.fromForm(["remoteTrustOnFirstUsePresent": "1",
                                             "remoteTrustOnFirstUse": "1"],
                                            current: RemoteTarget()).trustOnFirstUse)
    }

    func testThePerKindPathsComeInFromTheForm() {
        let target = RemoteTarget.fromForm(["remoteMoviesPath": "/v1/Filme",
                                            "remoteSeriesPath": "/v2/Serien",
                                            "remoteMusicPath": "/v1/Musik"],
                                           current: RemoteTarget())
        XCTAssertEqual(target.moviesPath, "/v1/Filme")
        XCTAssertEqual(target.seriesPath, "/v2/Serien")
        XCTAssertEqual(target.musicPath, "/v1/Musik")
    }

    // MARK: Which library a file belongs to

    /// A track is parsed as `.unknown`, and so is an unrecognised film, so
    /// the kind alone cannot tell them apart. The extension can.
    func testMusicIsRecognisedByItsFileAndNotByItsParsedKind() {
        XCTAssertEqual(
            RemoteTarget.Library.of(URL(fileURLWithPath: "/x/01 - Song.flac"),
                                    kind: .unknown), .music)
        XCTAssertEqual(
            RemoteTarget.Library.of(URL(fileURLWithPath: "/x/Film (2020).mkv"),
                                    kind: .unknown), .movies)
        XCTAssertEqual(
            RemoteTarget.Library.of(URL(fileURLWithPath: "/x/Dark - S01E01.mkv"),
                                    kind: .episode), .series)
        XCTAssertEqual(
            RemoteTarget.Library.of(URL(fileURLWithPath: "/x/Film.mkv"),
                                    kind: .movie), .movies)
    }
}
