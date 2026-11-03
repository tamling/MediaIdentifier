import XCTest
@testable import MediaIdentifierCore

/// One escaper for every page. There used to be two, and the weaker of them —
/// escaping only `&`, `<` and `>` — was the one applied to filenames on the
/// status page.
final class HTMLEscapingTests: XCTestCase {

    func testEscapesAllFiveEntities() {
        XCTAssertEqual(HTML.escape("&"), "&amp;")
        XCTAssertEqual(HTML.escape("<"), "&lt;")
        XCTAssertEqual(HTML.escape(">"), "&gt;")
        XCTAssertEqual(HTML.escape("\""), "&quot;")
        XCTAssertEqual(HTML.escape("'"), "&#39;")
    }

    func testAmpersandIsEscapedBeforeTheEntitiesItIntroduces() {
        XCTAssertEqual(HTML.escape("<a>"), "&lt;a&gt;")
        XCTAssertEqual(HTML.escape("&amp;"), "&amp;amp;")
    }

    func testLeavesOrdinaryTextAlone() {
        let name = "Der Name der Rose (1986) — S01E02 [1080p].mkv"
        XCTAssertEqual(HTML.escape(name), name)
    }

    func testTheRouterUsesTheSharedEscaper() {
        let nasty = "a&b<c>d\"e'f"
        XCTAssertEqual(WebRouter.escape(nasty), HTML.escape(nasty))
    }

    /// The status page renders whatever filename is being worked on, and that
    /// name comes from the watch folder rather than from us.
    func testStatusPageNeutralisesATagInAFilename() {
        var snapshot = StatusSnapshot()
        snapshot.converting = true
        snapshot.currentFile = "<script>alert(1)</script>.mkv"

        let html = StatusHTTP.html(snapshot)
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    /// The property the old status-page escaper did not have. Nothing in the
    /// current template puts a filename in an attribute, so this is here to
    /// fail loudly if the escaping is ever weakened again.
    func testStatusPageEscapesQuotesInAFilename() {
        var snapshot = StatusSnapshot()
        snapshot.converting = true
        snapshot.currentFile = #"He said "hi" — it's fine.mkv"#

        let html = StatusHTTP.html(snapshot)
        XCTAssertFalse(html.contains(#""hi""#))
        XCTAssertTrue(html.contains("&quot;hi&quot;"))
        XCTAssertTrue(html.contains("it&#39;s"))
    }

    func testStatusPageStillShowsTheFilename() {
        var snapshot = StatusSnapshot()
        snapshot.converting = true
        snapshot.currentFile = "Arrival (2016).mkv"

        XCTAssertTrue(StatusHTTP.html(snapshot).contains("Arrival (2016).mkv"))
    }
}
