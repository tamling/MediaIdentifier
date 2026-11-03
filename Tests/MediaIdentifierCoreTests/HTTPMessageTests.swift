import XCTest
@testable import MediaIdentifierCore

/// Logic tests for the portable HTTP message layer that the local web UI is
/// built on. Pure parsing and serialisation — no sockets, so these run
/// identically on macOS and Linux.
final class HTTPMessageTests: XCTestCase {

    private func parse(_ raw: String) -> HTTPRequest? {
        var parser = HTTPRequestParser()
        return parser.feed(Data(raw.utf8))
    }

    private func text(_ response: HTTPResponse, omitBody: Bool = false) -> String {
        String(decoding: response.serialized(omitBody: omitBody), as: UTF8.self)
    }

    // MARK: Request line

    func testParsesSimpleGet() throws {
        let request = try XCTUnwrap(parse("GET /api/status HTTP/1.1\r\nHost: x\r\n\r\n"))
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/status")
        XCTAssertEqual(request.headers["host"], "x")
        XCTAssertTrue(request.query.isEmpty)
        XCTAssertTrue(request.body.isEmpty)
        XCTAssertTrue(request.isReadOnly)
    }

    func testUppercasesMethodAndMarksWritesAsNotReadOnly() throws {
        let request = try XCTUnwrap(parse("post /run HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(request.method, "POST")
        XCTAssertFalse(request.isReadOnly)
    }

    func testAcceptsLFOnlyLineEndings() throws {
        let request = try XCTUnwrap(parse("GET /healthz HTTP/1.1\nHost: x\n\n"))
        XCTAssertEqual(request.path, "/healthz")
        XCTAssertEqual(request.headers["host"], "x")
    }

    func testRootPathWhenTargetIsJustSlash() throws {
        let request = try XCTUnwrap(parse("GET / HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(request.path, "/")
    }

    func testRejectsMalformedRequestLine() {
        var parser = HTTPRequestParser()
        XCTAssertNil(parser.feed(Data("GARBAGE\r\n\r\n".utf8)))
    }

    // MARK: Headers

    func testHeaderNamesAreCaseInsensitive() throws {
        let request = try XCTUnwrap(
            parse("GET / HTTP/1.1\r\nCoNtEnT-TyPe: application/json\r\n\r\n")
        )
        XCTAssertEqual(request.headers["content-type"], "application/json")
    }

    func testHeaderValueWithColonIsKeptWhole() throws {
        let request = try XCTUnwrap(parse("GET / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n"))
        XCTAssertEqual(request.headers["host"], "127.0.0.1:8080")
    }

    func testRepeatedHeaderKeepsFirstValue() throws {
        let request = try XCTUnwrap(
            parse("GET / HTTP/1.1\r\nX-A: one\r\nX-A: two\r\n\r\n")
        )
        XCTAssertEqual(request.headers["x-a"], "one")
    }

    // MARK: Query strings

    func testParsesQueryParameters() throws {
        let request = try XCTUnwrap(parse("GET /items?kind=movie&page=2 HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(request.path, "/items")
        XCTAssertEqual(request.query["kind"], "movie")
        XCTAssertEqual(request.query["page"], "2")
    }

    func testDecodesPercentAndPlusInQuery() throws {
        let request = try XCTUnwrap(
            parse("GET /s?q=The+Matrix%201999&p=%2Fmnt%2Fmedia HTTP/1.1\r\n\r\n")
        )
        XCTAssertEqual(request.query["q"], "The Matrix 1999")
        XCTAssertEqual(request.query["p"], "/mnt/media")
    }

    func testValuelessQueryParameterBecomesEmptyString() throws {
        let request = try XCTUnwrap(parse("GET /x?debug HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(request.query["debug"], "")
    }

    func testQueryIsStrippedFromPath() throws {
        let request = try XCTUnwrap(parse("GET /api/status?t=123 HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(request.path, "/api/status")
    }

    // MARK: Bodies and incremental arrival

    func testParsesBodyWithContentLength() throws {
        let raw = "POST /run HTTP/1.1\r\nContent-Length: 11\r\n\r\nhello world"
        let request = try XCTUnwrap(parse(raw))
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "hello world")
        XCTAssertEqual(request.declaredContentLength, 11)
    }

    /// A socket read can deliver half a request; the parser must wait.
    func testWaitsForSplitHead() {
        var parser = HTTPRequestParser()
        XCTAssertNil(parser.feed(Data("GET /api/sta".utf8)))
        XCTAssertNil(parser.feed(Data("tus HTTP/1.1\r\nHost: x".utf8)))
        let request = parser.feed(Data("\r\n\r\n".utf8))
        XCTAssertEqual(request?.path, "/api/status")
    }

    func testWaitsForSplitBody() {
        var parser = HTTPRequestParser()
        XCTAssertNil(parser.feed(Data("POST /run HTTP/1.1\r\nContent-Length: 9\r\n\r\nabcd".utf8)))
        let request = parser.feed(Data("efghi".utf8))
        XCTAssertEqual(request.map { String(decoding: $0.body, as: UTF8.self) }, "abcdefghi")
    }

    func testIgnoresBytesBeyondContentLength() throws {
        let raw = "POST /run HTTP/1.1\r\nContent-Length: 3\r\n\r\nabcEXTRA"
        let request = try XCTUnwrap(parse(raw))
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "abc")
    }

    func testMissingContentLengthMeansNoBody() throws {
        let request = try XCTUnwrap(parse("POST /run HTTP/1.1\r\n\r\nstray"))
        XCTAssertTrue(request.body.isEmpty)
    }

    func testOversizedRequestIsRefusedNotBuffered() {
        var parser = HTTPRequestParser()
        let huge = Data(repeating: 0x41, count: HTTPRequestParser.maxRequestBytes + 1)
        XCTAssertNil(parser.feed(huge))
        XCTAssertTrue(parser.isTooLarge)
        // Once refused it stays refused, so a flood cannot grow the buffer.
        XCTAssertNil(parser.feed(Data("GET / HTTP/1.1\r\n\r\n".utf8)))
    }

    func testFormEncodedBodyDecoding() {
        let fields = HTTPRequestParser.parseFormEncoded("path=%2Fmnt%2Fa&name=The+Matrix&flag=")
        XCTAssertEqual(fields["path"], "/mnt/a")
        XCTAssertEqual(fields["name"], "The Matrix")
        XCTAssertEqual(fields["flag"], "")
    }

    // MARK: Responses

    func testSerialisesStatusLineHeadersAndBody() {
        let raw = text(.json(Data(#"{"ok":true}"#.utf8)))
        XCTAssertTrue(raw.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(raw.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(raw.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(raw.hasSuffix("\r\n\r\n" + #"{"ok":true}"#))
    }

    func testIncludesHardeningHeadersAndNoCORS() {
        let raw = text(.html("<p>hi</p>"))
        XCTAssertTrue(raw.contains("X-Content-Type-Options: nosniff\r\n"))
        XCTAssertTrue(raw.contains("Cache-Control: no-store\r\n"))
        XCTAssertFalse(raw.lowercased().contains("access-control-allow-origin"),
                       "no site may read this server's responses from a visitor's browser")
    }

    func testHeadResponseKeepsContentLengthButDropsBody() {
        let response = HTTPResponse.text("hello")
        let raw = text(response, omitBody: true)
        XCTAssertTrue(raw.contains("Content-Length: 5\r\n"))
        XCTAssertTrue(raw.hasSuffix("\r\n\r\n"))
        XCTAssertFalse(raw.contains("hello"))
    }

    func testStatusReasonPhrases() {
        XCTAssertTrue(text(.notFound()).hasPrefix("HTTP/1.1 404 Not Found"))
        XCTAssertTrue(text(.methodNotAllowed()).hasPrefix("HTTP/1.1 405 Method Not Allowed"))
        XCTAssertTrue(text(.badRequest()).hasPrefix("HTTP/1.1 400 Bad Request"))
        XCTAssertEqual(HTTPResponse.reason(for: 503), "Service Unavailable")
    }

    /// A header value must not be able to smuggle in extra headers.
    func testHeaderInjectionIsStripped() {
        let response = HTTPResponse(status: 200, contentType: "text/plain",
                                    headers: ["X-Note": "a\r\nX-Evil: yes"],
                                    body: Data())
        let raw = text(response)
        XCTAssertTrue(raw.contains("X-Note: aX-Evil: yes\r\n"))
        XCTAssertFalse(raw.contains("\r\nX-Evil:"))
    }

    /// Regression: in Swift a CRLF is one `Character`, so splitting the head
    /// as a `String` on `"\n"` matched nothing and every header ended up
    /// swallowed into the request line.
    func testCRLFHeadersAreNotSwallowedIntoTheRequestLine() throws {
        let request = try XCTUnwrap(parse("GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n"))
        XCTAssertEqual(request.path, "/")
        XCTAssertEqual(request.headers["a"], "1")
        XCTAssertEqual(request.headers["b"], "2")
        XCTAssertEqual(request.headers["c"], "3")
    }

    /// The same trap in the older raw-request helpers.
    func testStatusHTTPReadsMethodAndPathFromCRLFRequest() {
        XCTAssertEqual(StatusHTTP.method(from: "POST /x HTTP/1.1\r\nHost: y\r\n\r\n"), "POST")
        XCTAssertEqual(
            StatusHTTP.path(from: "GET /api/status?x=1 HTTP/1.1\r\nHost: y\r\n\r\n"),
            "/api/status"
        )
    }

    // MARK: Regression — the existing status routes still behave

    func testStatusRoutesStillWork() {
        let snapshot = StatusSnapshot(busy: true, renaming: true, renameProgress: 0.5)
        XCTAssertTrue(String(decoding: StatusHTTP.route("/healthz", snapshot: snapshot), as: UTF8.self)
            .contains("503"))
        XCTAssertTrue(String(decoding: StatusHTTP.route("/", snapshot: snapshot), as: UTF8.self)
            .contains("Mediafin"))
        XCTAssertTrue(String(decoding: StatusHTTP.route("/nope", snapshot: snapshot), as: UTF8.self)
            .contains("404"))
    }
}
