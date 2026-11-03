import XCTest
@testable import MediaIdentifierCore

/// The origin check is the second of two barriers in front of every
/// state-changing request, the first being the CSRF token. These tests pin
/// down what it must refuse — in particular another service on the same
/// machine, which the browser's own cookie rules do *not* keep away from us.
final class RequestOriginTests: XCTestCase {

    private func post(host: String? = "localhost:8720",
                      origin: String? = nil,
                      fetchSite: String? = nil) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let host { headers["host"] = host }
        if let origin { headers["origin"] = origin }
        if let fetchSite { headers["sec-fetch-site"] = fetchSite }
        return HTTPRequest(method: "POST", path: "/library/apply", headers: headers)
    }

    // MARK: Accepted

    /// curl and older browsers send neither header. The CSRF token still has
    /// to match, so this is not a hole on its own.
    func testNoOriginHeadersAtAllIsAccepted() {
        XCTAssertTrue(RequestOrigin.isSameSite(post()))
    }

    func testMatchingOriginWithExplicitPortIsAccepted() {
        XCTAssertTrue(RequestOrigin.isSameSite(
            post(host: "localhost:8720", origin: "https://localhost:8720",
                 fetchSite: "same-origin")))
    }

    /// Host omits the port when it is the scheme's default, and so does Origin.
    func testImplicitDefaultPortsMatchOverTLS() {
        XCTAssertTrue(RequestOrigin.isSameSite(
            post(host: "mediafin.lan", origin: "https://mediafin.lan"), isTLS: true))
    }

    func testImplicitDefaultPortsMatchOverPlainHTTP() {
        XCTAssertTrue(RequestOrigin.isSameSite(
            post(host: "mediafin.lan", origin: "http://mediafin.lan"), isTLS: false))
    }

    func testHostCaseIsIgnored() {
        XCTAssertTrue(RequestOrigin.isSameSite(
            post(host: "LocalHost:8720", origin: "https://localhost:8720")))
    }

    func testIPv6LiteralMatches() {
        XCTAssertTrue(RequestOrigin.isSameSite(
            post(host: "[::1]:8720", origin: "https://[::1]:8720")))
    }

    /// `none` means the user typed the address or used a bookmark.
    func testFetchSiteNoneIsAccepted() {
        XCTAssertTrue(RequestOrigin.isSameSite(post(fetchSite: "none")))
    }

    // MARK: Refused

    func testDifferentHostIsRefused() {
        XCTAssertFalse(RequestOrigin.isSameSite(
            post(host: "localhost:8720", origin: "https://evil.example")))
    }

    /// The reason the port is compared at all. Jellyfin on the same box is a
    /// different origin, but SameSite=Strict is port-blind, so its cookies —
    /// and ours — travel with a request it makes.
    func testAnotherPortOnTheSameHostIsRefused() {
        XCTAssertFalse(RequestOrigin.isSameSite(
            post(host: "localhost:8720", origin: "http://localhost:8096")))
    }

    /// Same host, same port, but plain HTTP against a TLS server: a different
    /// origin, and a downgrade worth noticing.
    func testDifferentSchemeIsRefused() {
        XCTAssertFalse(RequestOrigin.isSameSite(
            post(host: "mediafin.lan", origin: "http://mediafin.lan"), isTLS: true))
    }

    func testCrossSiteFetchMetadataIsRefused() {
        XCTAssertFalse(RequestOrigin.isSameSite(post(fetchSite: "cross-site")))
    }

    /// A "site" ignores the port, so same-site is reported by a page on
    /// another port and cannot stand in for same-origin.
    func testSameSiteFetchMetadataIsRefused() {
        XCTAssertFalse(RequestOrigin.isSameSite(post(fetchSite: "same-site")))
    }

    /// Sandboxed iframes and cross-origin redirects send this. It is never
    /// the interface itself.
    func testNullOriginIsRefused() {
        XCTAssertFalse(RequestOrigin.isSameSite(post(origin: "null")))
        XCTAssertFalse(RequestOrigin.isSameSite(post(origin: "NULL")))
    }

    func testOriginWithoutAHostIsRefused() {
        XCTAssertFalse(RequestOrigin.isSameSite(post(origin: "not a url")))
    }

    func testMissingHostHeaderIsRefusedWhenAnOriginIsGiven() {
        XCTAssertFalse(RequestOrigin.isSameSite(
            post(host: nil, origin: "https://localhost:8720")))
    }

    // MARK: Authority parsing

    func testAuthoritySplitting() {
        XCTAssertEqual(RequestOrigin.authority("host:8720", defaultPort: 443).host, "host")
        XCTAssertEqual(RequestOrigin.authority("host:8720", defaultPort: 443).port, 8720)
        XCTAssertEqual(RequestOrigin.authority("host", defaultPort: 443).port, 443)
        // Brackets are stripped, because URL.host reports IPv6 without them.
        XCTAssertEqual(RequestOrigin.authority("[fe80::1]:9", defaultPort: 443).host, "fe80::1")
        XCTAssertEqual(RequestOrigin.authority("[fe80::1]:9", defaultPort: 443).port, 9)
        XCTAssertEqual(RequestOrigin.authority("[fe80::1]", defaultPort: 443).host, "fe80::1")
        XCTAssertEqual(RequestOrigin.authority("[fe80::1]", defaultPort: 443).port, 443)
        // A non-numeric port must not silently read as "no port given".
        XCTAssertEqual(RequestOrigin.authority("host:abc", defaultPort: 443).port, 443)
    }
}
