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
        XCTAssertTrue(text.contains("Bereit"))
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
}
