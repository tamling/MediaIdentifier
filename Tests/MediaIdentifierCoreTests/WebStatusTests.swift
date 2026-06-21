import XCTest
@testable import MediaIdentifierCore

final class WebStatusTests: XCTestCase {
    func testPathParsing() {
        XCTAssertEqual(StatusHTTP.path(from: "GET /api/status HTTP/1.1\r\nHost: x\r\n\r\n"), "/api/status")
        XCTAssertEqual(StatusHTTP.path(from: "GET / HTTP/1.1\r\n"), "/")
        XCTAssertEqual(StatusHTTP.path(from: "GET /healthz?foo=bar HTTP/1.1\r\n"), "/healthz")
        XCTAssertEqual(StatusHTTP.path(from: ""), "/")
        XCTAssertEqual(StatusHTTP.path(from: "garbage"), "/")
    }

    func testJSONContainsBusyAndOmitsNilOptionals() throws {
        let snapshot = StatusSnapshot(busy: true, renaming: true, renameProgress: 0.5, totalItems: 3)
        let data = StatusHTTP.json(snapshot)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["busy"] as? Bool, true)
        XCTAssertEqual(obj["totalItems"] as? Int, 3)
        // currentFile was nil → key omitted.
        XCTAssertNil(obj["currentFile"])
    }

    func testRouteStatusIsJSON200() {
        let response = StatusHTTP.route("/api/status", snapshot: .empty)
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(text.contains("Content-Type: application/json"))
        XCTAssertTrue(text.contains("\"busy\""))
    }

    func testRouteRootIsHTML() {
        let response = StatusHTTP.route("/", snapshot: .empty)
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Type: text/html"))
        XCTAssertTrue(text.contains("<!DOCTYPE html>"))
        XCTAssertTrue(text.contains("Ready"))
    }

    func testRouteUnknownIs404() {
        let response = StatusHTTP.route("/secret", snapshot: .empty)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 404"))
    }

    func testHealthzIdleIs200() {
        let response = StatusHTTP.route("/healthz", snapshot: .empty)
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(text.hasSuffix("ok"))
    }

    func testHealthzBusyIs503WithPercent() {
        let snapshot = StatusSnapshot(busy: true, converting: true, convertProgress: 0.42)
        let response = StatusHTTP.route("/healthz", snapshot: snapshot)
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 503"))
        XCTAssertTrue(text.contains("busy 42%"))
    }

    func testHealthzErrorIs500() {
        let snapshot = StatusSnapshot(lastResult: "1 fehlgeschlagen", hasError: true)
        let response = StatusHTTP.route("/healthz", snapshot: snapshot)
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 500"))
        XCTAssertTrue(text.contains("error"))
    }

    func testActivePercentClamps() {
        XCTAssertEqual(StatusSnapshot(converting: true, convertProgress: 0.5).activePercent, 50)
        XCTAssertEqual(StatusSnapshot(renaming: true, renameProgress: 1.5).activePercent, 100)
        XCTAssertEqual(StatusSnapshot(renaming: true, renameProgress: -1).activePercent, 0)
    }

    // MARK: Pentest-style attack simulations

    func testPathTraversalIsNotServed() {
        for attack in ["/../../../../etc/passwd", "/%2e%2e/%2e%2e/etc/passwd", "/../AppState.swift"] {
            let response = StatusHTTP.route(attack, snapshot: .empty)
            let text = String(decoding: response, as: UTF8.self)
            XCTAssertTrue(text.hasPrefix("HTTP/1.1 404"), "\(attack) should 404")
            XCTAssertFalse(text.contains("root:"), "must not disclose file contents")
        }
    }

    func testNonReadMethodsRejected() {
        for verb in ["POST", "PUT", "DELETE", "PATCH"] {
            let response = StatusHTTP.respond(
                toRawRequest: "\(verb) /api/status HTTP/1.1\r\nHost: x\r\n\r\n", snapshot: .empty)
            XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 405"),
                          "\(verb) should be rejected")
        }
    }

    func testGetAndHeadAllowed() {
        for verb in ["GET", "HEAD"] {
            let response = StatusHTTP.respond(
                toRawRequest: "\(verb) /api/status HTTP/1.1\r\n\r\n", snapshot: .empty)
            XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        }
    }

    func testCRLFInjectionInPathDoesNotForgeHeaders() {
        // A header smuggled into the request line must not appear in the response.
        let raw = "GET /x\r\nX-Injected: pwned\r\n\r\n"
        let response = StatusHTTP.respond(toRawRequest: raw, snapshot: .empty)
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertFalse(text.contains("X-Injected"))
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 404"))
    }

    func testHTMLEscapesMaliciousFilename() {
        // A crafted file name must not break out into live markup (stored XSS).
        let snapshot = StatusSnapshot(
            converting: true, currentFile: "<script>alert(1)</script>.mkv")
        let html = String(decoding: StatusHTTP.route("/", snapshot: snapshot), as: UTF8.self)
        XCTAssertFalse(html.contains("<script>alert(1)"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testStatusNeverLeaksSecretKeywords() {
        // Even with populated fields, the JSON must not carry secret-like keys.
        let snapshot = StatusSnapshot(
            busy: true, converting: true, currentFile: "movie.mkv",
            lastResult: "Fertig", jellyfinConfigured: true)
        let json = String(decoding: StatusHTTP.json(snapshot), as: UTF8.self).lowercased()
        for secret in ["token", "apikey", "api_key", "password", "secret", "bearer", "x-emby"] {
            XCTAssertFalse(json.contains(secret), "status JSON must not contain \(secret)")
        }
    }
}
