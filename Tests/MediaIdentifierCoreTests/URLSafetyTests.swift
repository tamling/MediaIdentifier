import XCTest
@testable import MediaIdentifierCore

/// Which addresses a stored key may be sent to unencrypted.
final class URLSafetyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Text.language = .german
    }

    // MARK: What counts as "my own network"

    /// The setup this program is actually used with: LM Studio on the desk,
    /// plain HTTP, a private address. It must not be warned about, or the
    /// warning is noise and gets ignored on the day it matters.
    func testTheUsualLocalModelServerIsNotFlaggedAtAll() {
        XCTAssertFalse(URLSafety.sendsCredentialsInTheClear("http://192.168.3.116:1234"))
        XCTAssertFalse(URLSafety.sendsCredentialsInTheClear("http://127.0.0.1:1234"))
        XCTAssertFalse(URLSafety.sendsCredentialsInTheClear("http://localhost:8096"))
        XCTAssertFalse(URLSafety.sendsCredentialsInTheClear("http://nas:8096"))
        XCTAssertFalse(URLSafety.sendsCredentialsInTheClear("http://nas.fritz.box:8096"))
    }

    func testEveryPrivateRangeIsRecognised() {
        for host in ["10.0.0.5", "10.255.255.255", "172.16.0.1", "172.31.255.1",
                     "192.168.0.1", "169.254.1.1", "127.0.0.1", "localhost",
                     "nas.local", "server.lan", "box.home.arpa", "::1",
                     // The router domains, because this is a German home
                     // network: a FRITZ!Box serves fritz.box, and warning
                     // about nas.fritz.box would be the false alarm that
                     // teaches people to ignore the lamp.
                     "fritz.box", "nas.fritz.box", "speedport.ip"] {
            XCTAssertTrue(URLSafety.isPrivateHost(host), host)
        }
    }

    /// The known limit, stated rather than left to be discovered: the list
    /// of router domains cannot be complete, so a host that really is local
    /// under some other vendor's domain is flagged. That is why the lamp is
    /// amber and says the host does not *look* local instead of asserting
    /// that it is not.
    func testALocalNameUnderAnUnlistedRouterDomainIsStillFlagged() {
        XCTAssertTrue(URLSafety.sendsCredentialsInTheClear("http://nas.easybox"))
        XCTAssertTrue(URLSafety.isPrivateHost("nas.local"),
                      "the .local that every vendor supports still works")
    }

    /// 172.32 is public, and so is 11.x: the ranges have edges and an
    /// off-by-one here hides a real warning.
    func testAddressesJustOutsideThePrivateRangesArePublic() {
        for host in ["172.15.0.1", "172.32.0.1", "11.0.0.1", "193.168.0.1",
                     "8.8.8.8", "example.com", "jellyfin.example.com"] {
            XCTAssertFalse(URLSafety.isPrivateHost(host), host)
        }
    }

    // MARK: The warning itself

    func testPlainHTTPToAPublicHostIsFlagged() {
        XCTAssertTrue(URLSafety.sendsCredentialsInTheClear("http://jellyfin.example.com"))
        XCTAssertTrue(URLSafety.sendsCredentialsInTheClear("http://8.8.8.8:8096"))
    }

    func testHTTPSIsNeverFlaggedWhereverItPoints() {
        XCTAssertFalse(URLSafety.sendsCredentialsInTheClear("https://jellyfin.example.com"))
        XCTAssertFalse(URLSafety.sendsCredentialsInTheClear("https://192.168.3.116:1234"))
    }

    /// An empty field is not a complaint, and a field that is not an address
    /// has its own message already. Two voices for one typo helps nobody.
    func testNothingAndNonsenseAreSomebodyElsesComplaint() {
        XCTAssertFalse(URLSafety.sendsCredentialsInTheClear(""))
        XCTAssertFalse(URLSafety.sendsCredentialsInTheClear("   "))
        XCTAssertFalse(URLSafety.sendsCredentialsInTheClear("not an address"))
        XCTAssertFalse(URLSafety.sendsCredentialsInTheClear("file:///etc/passwd"))
    }

    // MARK: The lamp

    func testTheLampNamesWhichServiceIsExposed() {
        var settings = WebSettings()
        settings.jellyfinBaseURL = "http://jellyfin.example.com"
        let lamp = SystemChecks.encryption(settings: settings)
        XCTAssertEqual(lamp.state, .warning)
        XCTAssertTrue(lamp.detail.contains("Jellyfin"), lamp.detail)
        XCTAssertTrue(lamp.detail.contains("https://"), lamp.detail)
    }

    func testTheLampNamesBothWhenBothAreExposed() {
        var settings = WebSettings()
        settings.localLLMBaseURL = "http://llm.example.com:1234"
        settings.jellyfinBaseURL = "http://jellyfin.example.com"
        let lamp = SystemChecks.encryption(settings: settings)
        XCTAssertEqual(lamp.state, .warning)
        XCTAssertTrue(lamp.detail.contains("Modellserver"), lamp.detail)
        XCTAssertTrue(lamp.detail.contains("Jellyfin"), lamp.detail)
    }

    func testTheLampIsGreenForTheLocalSetup() {
        var settings = WebSettings()
        settings.localLLMBaseURL = "http://192.168.3.116:1234"
        settings.jellyfinBaseURL = "https://jellyfin.example.com"
        XCTAssertEqual(SystemChecks.encryption(settings: settings).state, .ok)
    }

    /// Grey rather than green with nothing entered: a green lamp for a
    /// question nobody asked is how this panel learned to be ignored.
    func testTheLampIsGreyWithNothingConfigured() {
        XCTAssertEqual(SystemChecks.encryption(settings: WebSettings()).state, .off)
    }

    /// It is on the real panel, not only reachable from a test.
    func testTheLampIsPartOfThePanel() {
        var settings = WebSettings(sourceFolder: FileManager.default.temporaryDirectory.path)
        settings.jellyfinBaseURL = "http://jellyfin.example.com"
        let list = SystemChecks.all(settings: settings, ffmpegAvailable: true,
                                    secrets: [], probes: [:])
        XCTAssertEqual(list.first { $0.id == "encryption" }?.state, .warning)
    }
}
