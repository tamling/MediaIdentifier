import XCTest
@testable import MediaIdentifierCore

/// The one line under the window title.
///
/// These exist because the check that was meant to cover the interesting
/// half of this rule could not fail. It read the subtitle from the
/// --press-check run, and that same step asserts `busy == false` seventy
/// lines earlier -- so the code before the fix took its `else` branch and
/// printed exactly what the fixed code prints. The state the fault needs,
/// `busy` true with nothing measurable and a `renameProgress` left at 1 by
/// an earlier rename, was never reached.
final class HeaderSubtitleTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Text.language = .english
    }

    override func tearDown() {
        Text.language = .german
        super.tearDown()
    }

    /// The fault itself: a job that measures nothing must not borrow the
    /// last rename's finished percentage.
    func testABusyJobThatMeasuresNothingShowsNoPercentage() {
        var state = StatusSnapshot()
        state.busy = true
        // Set to 1 at the end of every rename and never reset, so this is
        // the state of the engine after any successful rename.
        state.renameProgress = 1
        state.renaming = false
        state.converting = false
        state.convertStatus = nil

        let text = HeaderSubtitle.text(for: state)

        XCTAssertFalse(text.contains("%"),
                       "a job that reports no progress must not show a "
                           + "percentage; this read \"Working… · 100 %\" of "
                           + "work it knew nothing about: \(text)")
        XCTAssertEqual(text, "Working…")
    }

    /// The same state a download is in: `busy`, with its progress in
    /// `downloadProgress`, which `activePercent` does not look at.
    func testADownloadDoesNotBorrowTheRenamePercentage() {
        var state = StatusSnapshot()
        state.busy = true
        state.downloading = true
        state.downloadProgress = 0.03
        state.renameProgress = 1

        let text = HeaderSubtitle.text(for: state)

        XCTAssertFalse(text.contains("100"),
                       "the header read \"Arbeitet · 100 %\" from the first "
                           + "instant of a fetch while the panel's own bar "
                           + "beside it read 3 %: \(text)")
        XCTAssertFalse(text.contains("%"), text)
    }

    /// And the convertible search, which is the other `busy` job with
    /// nothing to measure. Its own status line is what should be shown.
    func testTheSearchShowsItsOwnStatusAndNoNumber() {
        var state = StatusSnapshot()
        state.busy = true
        state.convertStatus = "Looking for files…"
        state.renameProgress = 1

        XCTAssertEqual(HeaderSubtitle.text(for: state), "Looking for files…")
    }

    /// The other direction, or the rule above would be satisfied by never
    /// showing a percentage at all.
    func testAConversionShowsItsPercentage() {
        var state = StatusSnapshot()
        state.busy = true
        state.converting = true
        state.convertProgress = 0.42
        state.convertStatus = "Converting"

        XCTAssertEqual(HeaderSubtitle.text(for: state), "Converting · 42 %")
    }

    func testARenameShowsItsPercentage() {
        var state = StatusSnapshot()
        state.busy = true
        state.renaming = true
        state.renameProgress = 0.5

        XCTAssertEqual(HeaderSubtitle.text(for: state), "Working · 50 %")
    }

    /// A command that holds the serial queue without setting `busy`:
    /// Rückgängig, both connection tests, Alles prüfen.
    func testQueuedWorkWithoutBusySaysItIsWorking() {
        var state = StatusSnapshot()
        state.queuedWork = 1
        state.renameProgress = 1

        let text = HeaderSubtitle.text(for: state)
        XCTAssertEqual(text, "Working…")
        XCTAssertFalse(text.contains("%"), text)
    }

    /// What it is doing now outranks how the last thing ended: `hasError` is
    /// sticky and only the end of the next run recomputes it.
    func testWorkingOutranksAStickyError() {
        var state = StatusSnapshot()
        state.busy = true
        state.hasError = true

        XCTAssertEqual(HeaderSubtitle.text(for: state), "Working…")
    }

    func testIdleWithAnErrorSaysSo() {
        var state = StatusSnapshot()
        state.hasError = true

        XCTAssertEqual(HeaderSubtitle.text(for: state), "Finished with errors")
    }

    func testIdleAndWellSaysReady() {
        XCTAssertEqual(HeaderSubtitle.text(for: StatusSnapshot()), "Ready")
    }
}
