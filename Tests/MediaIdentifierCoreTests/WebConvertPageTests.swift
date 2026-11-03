import XCTest
@testable import MediaIdentifierCore

/// Tests the Convert page. Converting is destructive of time and disk, so the
/// page must never start anything on its own and must say what it will do.
final class WebConvertPageTests: XCTestCase {

    private let token = "d00dd00dd00dd00dd00dd00dd00dd00dd00dd00dd00dd00dd00dd00dd00dd00d"

    private final class RecordingSink: WebCommandSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _commands: [WebCommand] = []
        func submit(_ command: WebCommand) {
            lock.lock(); _commands.append(command); lock.unlock()
        }
        var commands: [WebCommand] { lock.lock(); defer { lock.unlock() }; return _commands }
    }

    private var sink: RecordingSink!

    override func setUp() {
        super.setUp()
        sink = RecordingSink()
    }

    private func candidate(_ name: String, bytes: Int64 = 4_000_000_000) -> ConversionCandidate {
        ConversionCandidate(source: URL(fileURLWithPath: "/mnt/Movies/\(name)"), byteSize: bytes)
    }

    private func makeRouter(candidates: [ConversionCandidate] = [],
                            ffmpeg: Bool = true,
                            settings: WebSettings = WebSettings(moviesFolder: "/mnt/Movies"),
                            snapshot: StatusSnapshot = StatusSnapshot()) -> WebRouter {
        WebRouter(policy: WebSecurityPolicy(token: token, isTLS: true),
                  settings: { settings },
                  convertible: { candidates },
                  ffmpegAvailable: { ffmpeg },
                  commands: sink,
                  snapshot: { snapshot })
    }

    private func page(_ router: WebRouter) -> String {
        let request = HTTPRequest(method: "GET", path: "/convert",
                                  headers: ["authorization": "Bearer \(token)"])
        return String(decoding: router.respond(to: request).body, as: UTF8.self)
    }

    private func post(_ router: WebRouter, _ path: String, body: String = "") -> HTTPResponse {
        let full = "\(body)\(body.isEmpty ? "" : "&")\(CSRFToken.fieldName)=\(router.csrf.value)"
        return router.respond(to: HTTPRequest(
            method: "POST", path: path,
            headers: ["authorization": "Bearer \(token)"],
            body: Data(full.utf8)
        ))
    }

    // MARK: Rendering

    func testCandidatesAreListedWithTheirSize() {
        let html = page(makeRouter(candidates: [candidate("The Matrix (1999).mkv")]))
        XCTAssertTrue(html.contains("The Matrix (1999).mkv"), html)
        XCTAssertTrue(html.contains("GB"), html)
    }

    /// Nothing is pre-ticked: a run this expensive should be chosen, not
    /// defaulted into.
    func testNothingIsPreTicked() {
        let html = page(makeRouter(candidates: [candidate("A.mkv")]))
        XCTAssertFalse(html.contains("checked>"), html)
        XCTAssertFalse(html.contains("checked "), html)
    }

    func testThePageSaysWhereTheOutputGoesAndThatNothingIsDeleted() {
        let html = page(makeRouter(candidates: [candidate("A.mkv")]))
        XCTAssertTrue(html.contains("beside the original"), html)
        XCTAssertTrue(html.contains("Nothing is deleted"), html)
        XCTAssertTrue(html.contains(".x265"), html)
    }

    func testMissingFFmpegIsReportedAndTheButtonDisabled() {
        let html = page(makeRouter(candidates: [candidate("A.mkv")], ffmpeg: false))
        XCTAssertTrue(html.contains("FFmpeg was not found"), html)
        XCTAssertTrue(html.contains("apt install ffmpeg"), html)
        XCTAssertTrue(html.contains(" disabled>Convert the ticked files"), html)
    }

    func testEmptyListExplainsWhatTheButtonDoes() {
        let html = page(makeRouter())
        XCTAssertTrue(html.contains("Nothing found yet"), html)
        XCTAssertFalse(html.contains("Convert the ticked files"))
    }

    func testAnEstimateIsShown() {
        let html = page(makeRouter())
        XCTAssertTrue(html.contains("% of the original size"), html)
    }

    func testProgressIsShownWhileConverting() {
        let running = StatusSnapshot(busy: true, converting: true, convertProgress: 0.37,
                                     currentFile: "A.mkv", pendingConversions: 2)
        let html = page(makeRouter(candidates: [candidate("A.mkv")], snapshot: running))
        XCTAssertTrue(html.contains("Converting A.mkv"), html)
        XCTAssertTrue(html.contains("37 %"), html)
        XCTAssertTrue(html.contains("2 still queued"), html)
        XCTAssertTrue(html.contains("Stop after this file"), html)
        XCTAssertTrue(html.contains("http-equiv=\"refresh\""), html)
    }

    func testTheListIsNotOfferedWhileARunIsInFlight() {
        let running = StatusSnapshot(busy: true, converting: true)
        let html = page(makeRouter(candidates: [candidate("A.mkv")], snapshot: running))
        XCTAssertFalse(html.contains("Convert the ticked files"),
                       "a second run must not be startable mid-run")
    }

    func testFileNamesAreEscaped() {
        let html = page(makeRouter(candidates: [candidate("<script>x</script>.mkv")]))
        XCTAssertFalse(html.contains("<script>x</script>"), html)
        XCTAssertTrue(html.contains("&lt;script&gt;"), html)
    }

    func testConvertIsReachableFromTheNavigation() {
        let overview = HTTPRequest(method: "GET", path: "/",
                                   headers: ["authorization": "Bearer \(token)"])
        let html = String(decoding: makeRouter().respond(to: overview).body, as: UTF8.self)
        XCTAssertTrue(html.contains("/convert"), html)
    }

    // MARK: Starting a run

    func testOnlyTickedFilesAreConverted() {
        let first = candidate("A.mkv")
        let second = candidate("B.mkv")
        let router = makeRouter(candidates: [first, second])
        let response = post(router, "/convert/start",
                            body: "itemsPresent=1&items=\(first.id.uuidString)")
        XCTAssertEqual(response.status, 303)
        XCTAssertEqual(response.headers["Location"], "/convert")
        XCTAssertEqual(sink.commands, [.convertFiles(accepting: [first.id])])
    }

    /// With nothing ticked the command must carry an empty set, never "all".
    func testNothingTickedConvertsNothing() {
        let router = makeRouter(candidates: [candidate("A.mkv")])
        _ = post(router, "/convert/start", body: "itemsPresent=1")
        XCTAssertEqual(sink.commands, [.convertFiles(accepting: [])])
    }

    /// Even a request with no selection field at all must not convert
    /// everything — unlike renaming, this one defaults to nothing.
    func testAMissingSelectionConvertsNothing() {
        let router = makeRouter(candidates: [candidate("A.mkv")])
        _ = post(router, "/convert/start")
        XCTAssertEqual(sink.commands, [.convertFiles(accepting: [])])
    }

    func testLookingForFilesIsItsOwnCommand() {
        let router = makeRouter()
        XCTAssertEqual(post(router, "/convert/scan").status, 303)
        XCTAssertEqual(sink.commands, [.findConvertible])
    }

    func testCancelling() {
        let router = makeRouter()
        XCTAssertEqual(post(router, "/convert/cancel").status, 303)
        XCTAssertEqual(sink.commands, [.cancelConversions])
    }

    func testStartingNeedsAuthenticationAndACSRFToken() {
        let router = makeRouter(candidates: [candidate("A.mkv")])

        let anonymous = router.respond(to: HTTPRequest(
            method: "POST", path: "/convert/start",
            body: Data("\(CSRFToken.fieldName)=\(router.csrf.value)".utf8)
        ))
        XCTAssertEqual(anonymous.status, 401)

        let noToken = router.respond(to: HTTPRequest(
            method: "POST", path: "/convert/start",
            headers: ["authorization": "Bearer \(token)"]
        ))
        XCTAssertEqual(noToken.status, 403)
        XCTAssertTrue(sink.commands.isEmpty)
    }

    // MARK: Settings from this page come back to this page

    func testSavingFromTheConvertPageReturnsThere() {
        let router = makeRouter()
        let response = post(router, "/settings",
                            body: "after=%2Fconvert&conversionFormPresent=1&videoCodec=av1")
        XCTAssertEqual(response.status, 303)
        XCTAssertEqual(response.headers["Location"], "/convert?saved=1")
        guard case .saveSettings(let saved)? = sink.commands.first else {
            return XCTFail("expected a saveSettings command, got \(sink.commands)")
        }
        XCTAssertEqual(saved.conversion.videoCodec, .av1)
    }

    /// The return path is an allowlist, not whatever the form asked for.
    func testTheReturnPathCannotBeRedirectedElsewhere() {
        let router = makeRouter()
        let response = post(router, "/settings",
                            body: "after=https%3A%2F%2Fevil.example&conversionFormPresent=1")
        XCTAssertEqual(response.headers["Location"], "/settings?saved=1")
    }

    func testABadConversionValueComesBackOnTheConvertPage() {
        let router = makeRouter()
        let response = post(router, "/settings",
                            body: "after=%2Fconvert&conversionFormPresent=1&targetHeight=7")
        XCTAssertEqual(response.status, 422)
        let html = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(html.contains("between 120 and 8192"), html)
        XCTAssertTrue(html.contains("Convert"), html)
        XCTAssertTrue(sink.commands.isEmpty, "nothing may be saved when the form is wrong")
    }
}
