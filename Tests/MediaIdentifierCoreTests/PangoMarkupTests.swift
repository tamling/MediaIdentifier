import XCTest
@testable import MediaIdentifierCore

final class PangoMarkupTests: XCTestCase {

    func testEscapesTheFiveXMLEntities() {
        XCTAssertEqual(PangoMarkup.escape("&"), "&amp;")
        XCTAssertEqual(PangoMarkup.escape("<"), "&lt;")
        XCTAssertEqual(PangoMarkup.escape(">"), "&gt;")
        XCTAssertEqual(PangoMarkup.escape("\""), "&quot;")
        XCTAssertEqual(PangoMarkup.escape("'"), "&apos;")
    }

    /// The ordering trap: escaping `<` before `&` would turn `<` into
    /// `&amp;lt;` and render the entity as literal text.
    func testDoesNotDoubleEscapeItsOwnOutput() {
        XCTAssertEqual(PangoMarkup.escape("<a>"), "&lt;a&gt;")
        XCTAssertEqual(PangoMarkup.escape("&amp;"), "&amp;amp;")
        XCTAssertEqual(PangoMarkup.escape("a & b < c"), "a &amp; b &lt; c")
    }

    /// The case this exists for. An unescaped ampersand makes Pango reject the
    /// whole string, so the label would render empty rather than wrong.
    func testEscapesARealFilename() {
        let name = "Fear & Loathing <1998> [1080p].mkv"
        XCTAssertEqual(
            PangoMarkup.escape(name),
            "Fear &amp; Loathing &lt;1998&gt; [1080p].mkv"
        )
    }

    func testLeavesOrdinaryTextUntouched() {
        let name = "Der Name der Rose (1986) - S01E02 - Köln, 25 % fertig.mkv"
        XCTAssertEqual(PangoMarkup.escape(name), name)
    }

    func testPreservesNonLatinText() {
        XCTAssertEqual(PangoMarkup.escape("白夜行 — 第1話"), "白夜行 — 第1話")
    }

    func testSpanEscapesBodyAndAttributes() {
        XCTAssertEqual(
            PangoMarkup.span("A & B", size: "xx-large", weight: "bold"),
            "<span size='xx-large' weight='bold'>A &amp; B</span>"
        )
    }

    func testSpanOmitsAbsentAttributes() {
        XCTAssertEqual(PangoMarkup.span("plain"), "<span>plain</span>")
        XCTAssertEqual(PangoMarkup.span("x", weight: "bold"), "<span weight='bold'>x</span>")
    }

    /// A quote in an attribute value would otherwise close the attribute and
    /// let the rest be read as markup.
    func testSpanAttributeCannotBreakOutOfItsQuotes() {
        let markup = PangoMarkup.span("t", size: "large' foreground='red")
        XCTAssertFalse(markup.contains("foreground='red'"))
        XCTAssertTrue(markup.contains("&apos;"))
    }
}
