import XCTest
@testable import MediaIdentifierCore

/// Tests the history page and the log download.
final class WebHistoryPageTests: XCTestCase {

    private let token = "cafecafecafecafecafecafecafecafecafecafecafecafecafecafecafecafe"

    private func entry(_ old: String, _ new: String,
                       status: RenameLogEntry.Status = .success,
                       error: String? = nil) -> RenameLogEntry {
        RenameLogEntry(oldName: old, newName: new, status: status, errorDescription: error)
    }

    private func makeRouter(_ entries: [RenameLogEntry]) -> WebRouter {
        WebRouter(policy: WebSecurityPolicy(token: token, isTLS: true),
                  logEntries: { entries },
                  snapshot: { StatusSnapshot() })
    }

    private func response(_ router: WebRouter, _ path: String) -> HTTPResponse {
        router.respond(to: HTTPRequest(method: "GET", path: path,
                                       headers: ["authorization": "Bearer \(token)"]))
    }

    private func text(_ response: HTTPResponse) -> String {
        String(decoding: response.body, as: UTF8.self)
    }

    // MARK: Page

    func testEntriesAreListedNewestFirst() throws {
        let router = makeRouter([entry("old1.mkv", "New 1.mkv"), entry("old2.mkv", "New 2.mkv")])
        let html = text(response(router, "/history"))
        let newest = try XCTUnwrap(html.range(of: "old2.mkv"))
        let oldest = try XCTUnwrap(html.range(of: "old1.mkv"))
        XCTAssertTrue(newest.lowerBound < oldest.lowerBound,
                      "the most recent entry should be at the top")
    }

    func testStatusesAreWordsNotCodes() {
        let router = makeRouter([
            entry("a.mkv", "A.mkv", status: .success),
            entry("b.mkv", "B.mkv", status: .skipped),
            entry("c.mkv", "C.mkv", status: .failure, error: "disk full"),
        ])
        let html = text(response(router, "/history"))
        XCTAssertTrue(html.contains("renamed"), html)
        XCTAssertTrue(html.contains("skipped"), html)
        XCTAssertTrue(html.contains("failed"), html)
        XCTAssertTrue(html.contains("disk full"), "the reason must be visible")
    }

    func testEmptyHistorySaysSoAndDisablesClearing() {
        let html = text(response(makeRouter([]), "/history"))
        XCTAssertTrue(html.contains("Nothing has been renamed yet"), html)
        XCTAssertTrue(html.contains(" disabled>Clear the history"), html)
    }

    func testCountIsReadable() {
        XCTAssertTrue(text(response(makeRouter([entry("a", "b")]), "/history"))
            .contains("1 entry"))
        XCTAssertTrue(text(response(makeRouter([entry("a", "b"), entry("c", "d")]), "/history"))
            .contains("2 entries"))
    }

    func testHistoryIsReachableFromEveryPage() {
        let router = makeRouter([])
        for path in ["/", "/settings", "/history"] {
            XCTAssertTrue(text(response(router, path)).contains("/history"),
                          "\(path) should link to the history")
        }
    }

    /// A file name from disk must not be able to break out of its cell.
    func testNamesAreEscaped() {
        let router = makeRouter([entry("<b>x</b>.mkv", "ok.mkv")])
        let html = text(response(router, "/history"))
        XCTAssertFalse(html.contains("<b>x</b>.mkv"), html)
        XCTAssertTrue(html.contains("&lt;b&gt;x&lt;/b&gt;.mkv"), html)
    }

    // MARK: Export

    func testExportIsADownloadWithAFixedName() {
        let router = makeRouter([entry("old.mkv", "New (2020).mkv")])
        let result = response(router, "/history/export")
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.contentType, "text/plain; charset=utf-8")
        XCTAssertEqual(result.headers["Content-Disposition"],
                       "attachment; filename=\"mediafin-log.txt\"")
    }

    func testExportContainsEveryEntry() {
        let router = makeRouter([
            entry("a.mkv", "A (2020).mkv"),
            entry("b.mkv", "B (2021).mkv", status: .failure, error: "no space"),
        ])
        let body = text(response(router, "/history/export"))
        XCTAssertTrue(body.contains("a.mkv"), body)
        XCTAssertTrue(body.contains("A (2020).mkv"), body)
        XCTAssertTrue(body.contains("no space"), body)
        XCTAssertTrue(body.contains("failure"), body)
    }

    func testExportOfAnEmptyLogStillWorks() {
        let body = text(response(makeRouter([]), "/history/export"))
        XCTAssertTrue(body.contains("Mediafin rename log"), body)
    }

    // MARK: Access control still applies

    func testHistoryAndExportNeedAuthentication() {
        let router = makeRouter([entry("secret-film.mkv", "A.mkv")])
        for path in ["/history", "/history/export"] {
            let anonymous = router.respond(to: HTTPRequest(method: "GET", path: path))
            XCTAssertEqual(anonymous.status, 401, path)
            XCTAssertFalse(text(anonymous).contains("secret-film"),
                           "\(path) must not leak names to an anonymous client")
        }
    }
}
