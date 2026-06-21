import XCTest
@testable import MediaIdentifierCore

final class JellyfinConnectorTests: XCTestCase {
    func testRejectsInvalidServerURL() {
        XCTAssertThrowsError(try JellyfinConnector(serverURL: "", apiKey: "k"))
        XCTAssertThrowsError(try JellyfinConnector(serverURL: "not a url", apiKey: "k"))
        XCTAssertThrowsError(try JellyfinConnector(serverURL: "/no/scheme", apiKey: "k"))
    }

    func testAcceptsValidServerURL() {
        XCTAssertNoThrow(try JellyfinConnector(serverURL: "http://localhost:8096", apiKey: "k"))
        XCTAssertNoThrow(try JellyfinConnector(serverURL: "https://jelly.example.com", apiKey: "k"))
    }

    func testAuthorizationHeaderFormat() {
        XCTAssertEqual(
            JellyfinConnector.authorizationHeader(apiKey: "abc123"),
            "MediaBrowser Token=\"abc123\""
        )
    }

    func testNameIsJellyfin() throws {
        let connector = try JellyfinConnector(serverURL: "http://localhost:8096", apiKey: "k")
        XCTAssertEqual(connector.name, "Jellyfin")
    }
}
