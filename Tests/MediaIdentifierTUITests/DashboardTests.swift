import XCTest
@testable import MediaIdentifierTUI
@testable import MediaIdentifierCore

/// What the terminal screen looks like.
///
/// This is the thing the window could never have: the layout is a pure
/// function from state to lines, so it can be read and asserted on a machine
/// with no screen. For the GTK window "it compiles" was all CI could say
/// until a screenshot was wired up; here the shape of every frame is a value.
final class DashboardTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Text.language = .english
    }

    override func tearDown() {
        Text.language = .german
        super.tearDown()
    }

    private let size = ScreenSize(columns: 80, rows: 24)

    private func item(_ name: String, accepted: Bool = true,
                      conflict: ConflictKind? = nil) -> RenameItem {
        let url = URL(fileURLWithPath: "/downloads/\(name)")
        let parsed = ParsedRelease(originalFileName: name, title: name, kind: .movie)
        return RenameItem(mediaFile: MediaFile(url: url, parsed: parsed),
                          outputRoot: URL(fileURLWithPath: "/library"),
                          proposedRelativePath: "Film/\(name)",
                          isAccepted: accepted, conflict: conflict)
    }

    private func state(items: [RenameItem] = [],
                       checks: [SystemCheck] = [],
                       snapshot: StatusSnapshot = StatusSnapshot(),
                       selected: Int = 0,
                       checksOpen: Bool = false) -> Dashboard.State {
        Dashboard.State(snapshot: snapshot, checks: checks, items: items, log: [],
                        selected: selected, checksOpen: checksOpen, version: "1.2.3")
    }

    private func plain(_ lines: [Line]) -> [String] { lines.map(\.plain) }

    // MARK: The frame as a whole

    /// The one invariant everything else rests on: a frame is exactly as
    /// tall as the terminal and no line is wider than it. A line one column
    /// too long wraps, which pushes every row below it down and makes the
    /// next frame redraw somewhere else.
    func testAFrameFitsTheTerminalExactly() {
        for columns in [20, 40, 80, 200] {
            for rows in [8, 12, 24, 60] {
                let size = ScreenSize(columns: columns, rows: rows)
                let lines = Dashboard.render(
                    state(items: (1...30).map { item("Film \($0).mkv") }), size: size)
                XCTAssertEqual(lines.count, rows, "\(columns)x\(rows)")
                for line in lines {
                    XCTAssertLessThanOrEqual(line.width, columns,
                                             "\(columns)x\(rows): \"\(line.plain)\"")
                }
            }
        }
    }

    /// The menu is the last row, always. A menu that moves up and down as
    /// the list grows is one the hand cannot learn.
    func testTheMenuIsAlwaysOnTheLastRow() {
        for count in [0, 1, 5, 100] {
            let lines = Dashboard.render(
                state(items: (0..<count).map { item("F\($0).mkv") }), size: size)
            XCTAssertTrue(lines.last!.plain.hasPrefix("s "),
                          "with \(count) items: \"\(lines.last!.plain)\"")
        }
    }

    /// The way out is never the thing that falls off the end.
    ///
    /// Adding two keys made the full row longer than eighty columns, and
    /// what the truncation took was `q`. A terminal interface that cannot
    /// show how to leave it is a trap, so the row is built to the width it
    /// has rather than drawn and then cut.
    func testTheMenuFitsAndAlwaysKeepsTheWayOut() {
        for columns in [20, 30, 40, 60, 80, 120, 200] {
            for busy in [false, true] {
                let snapshot = StatusSnapshot(busy: busy, queuedWork: busy ? 1 : 0)
                let line = Dashboard.menu(
                    state(items: [item("A.mkv")], snapshot: snapshot),
                    columns: columns)
                XCTAssertLessThanOrEqual(line.width, columns,
                                         "\(columns): \"\(line.plain)\"")
                XCTAssertTrue(line.plain.contains("q"),
                              "\(columns): no way out in \"\(line.plain)\"")
            }
        }
    }

    /// Wide enough and the words are there; narrow and the letters alone
    /// are, which is what somebody who has used it twice reads anyway.
    func testTheMenuDropsItsWordsBeforeItDropsItsKeys() {
        let wide = Dashboard.menu(state(items: [item("A.mkv")]), columns: 200)
        XCTAssertTrue(wide.plain.contains("quit"), wide.plain)

        let narrow = Dashboard.menu(state(items: [item("A.mkv")]), columns: 30)
        XCTAssertFalse(narrow.plain.contains("quit"), narrow.plain)
        XCTAssertTrue(narrow.plain.contains("q"), narrow.plain)
        XCTAssertTrue(narrow.plain.contains("s"), narrow.plain)
    }

    // MARK: The header

    func testTheHeaderSaysWhatTheEngineIsDoing() {
        XCTAssertTrue(Dashboard.header(state(), columns: 80).plain.contains("ready"))

        let failed = StatusSnapshot(lastResult: "x", hasError: true)
        XCTAssertTrue(Dashboard.header(state(snapshot: failed), columns: 80)
            .plain.contains("errors"))

        let busy = StatusSnapshot(busy: true, renameProgress: 0.5, queuedWork: 1)
        XCTAssertTrue(Dashboard.header(state(snapshot: busy), columns: 80)
            .plain.contains("working"))
    }

    /// The counts go on the right only when there is room. On a narrow
    /// terminal they are dropped rather than pushing the name off the left.
    func testTheHeaderDropsTheCountsRatherThanOverflowing() {
        let narrow = Dashboard.header(state(), columns: 24)
        XCTAssertLessThanOrEqual(narrow.width, 24, narrow.plain)
        XCTAssertTrue(narrow.plain.contains("Mediafin"))
    }

    // MARK: The traffic light

    func testTheTrafficLightIsOneLineUntilItIsOpened() {
        let checks = [
            SystemCheck(id: "a", name: "Import", state: .ok, detail: "/downloads"),
            SystemCheck(id: "b", name: "FFmpeg", state: .warning, detail: "not found"),
        ]
        let folded = Dashboard.render(state(checks: checks), size: size)
        XCTAssertFalse(plain(folded).contains { $0.contains("/downloads") },
                       "the detail was shown while the panel was folded")

        let open = Dashboard.render(state(checks: checks, checksOpen: true), size: size)
        XCTAssertTrue(plain(open).contains { $0.contains("/downloads") })
        XCTAssertTrue(plain(open).contains { $0.contains("not found") })
    }

    /// Colour alone is unreadable to about one man in twelve, so the word is
    /// there as well — the same rule the other two front-ends follow.
    func testEveryLampCarriesItsWordAndNotOnlyAColour() {
        let checks = SystemCheck.State.allStates.map {
            SystemCheck(id: "\($0)", name: "Thing", state: $0, detail: "detail")
        }
        let rows = Dashboard.lampRows(checks, columns: 80)
        for (check, row) in zip(checks, rows) {
            XCTAssertTrue(row.plain.contains(check.state.word),
                          "\(check.state): \"\(row.plain)\"")
        }
    }

    // MARK: The list

    func testAProposalShowsItsTickAndItsNewName() {
        let lines = plain(Dashboard.render(
            state(items: [item("A.mkv", accepted: true),
                          item("B.mkv", accepted: false)]), size: size))
        XCTAssertTrue(lines.contains { $0.contains("[x]") && $0.contains("A.mkv") })
        XCTAssertTrue(lines.contains { $0.contains("[ ]") && $0.contains("B.mkv") })
    }

    func testAConflictIsNamedOnTheRow() {
        let lines = plain(Dashboard.render(
            state(items: [item("A.mkv", conflict: .duplicateInBatch)]), size: size))
        XCTAssertTrue(lines.contains { $0.contains("duplicate") }, lines.joined(separator: "\n"))
    }

    /// A list longer than the window says how much it is not showing. A
    /// window that just stops looks like a list that just stops.
    func testALongListSaysHowMuchIsHidden() {
        let lines = plain(Dashboard.render(
            state(items: (1...50).map { item("F\($0).mkv") }), size: size))
        XCTAssertTrue(lines.contains { $0.contains("more") }, lines.joined(separator: "\n"))
    }

    func testAnEmptyListSaysWhatToPress() {
        let lines = plain(Dashboard.render(state(), size: size))
        XCTAssertTrue(lines.contains { $0.contains("[s]") }, lines.joined(separator: "\n"))
    }

    // MARK: Scrolling

    /// The window follows the selection instead of the top of the list, or
    /// moving down past the last visible row would scroll nothing.
    func testTheWindowFollowsTheSelection() {
        // A list shorter than the window never scrolls and hides nothing.
        let short = Dashboard.layout(selected: 2, count: 3, rows: 10)
        XCTAssertEqual(short.first, 0)
        XCTAssertEqual(short.visible, 3)
        XCTAssertEqual(short.hidden, 0)

        // At the top, with more below: one row goes to the "… more" line.
        let top = Dashboard.layout(selected: 0, count: 100, rows: 10)
        XCTAssertEqual(top.first, 0)
        XCTAssertEqual(top.visible, 9)
        XCTAssertEqual(top.hidden, 91)
    }

    /// The bug this was written for: the "… N more" line took its row from
    /// the list after the window had been worked out, so the last entry was
    /// dropped — and at the bottom of the list that entry is the selected
    /// one. Pressing End scrolled the cursor off the screen.
    func testTheBottomOfTheListGivesTheIndicatorRowBackToIt() {
        let bottom = Dashboard.layout(selected: 99, count: 100, rows: 10)
        XCTAssertEqual(bottom.hidden, 0, "it claimed there was more below the end")
        XCTAssertEqual(bottom.visible, 10, "a row was wasted on an empty indicator")
        XCTAssertEqual(bottom.first + bottom.visible, 100)
        XCTAssertTrue((bottom.first..<(bottom.first + bottom.visible)).contains(99))
    }

    /// The invariant behind all of it, over every size and position: the
    /// selection is inside the window, the window is inside the list, and
    /// the rows drawn plus the rows announced add up to the list.
    func testTheWindowAlwaysHoldsTheSelection() {
        for count in [1, 2, 9, 10, 11, 50, 1000] {
            for rows in [1, 2, 3, 9, 10, 25] {
                for selected in [0, count / 3, count / 2, count - 2, count - 1] {
                    guard selected >= 0, selected < count else { continue }
                    let window = Dashboard.layout(selected: selected, count: count,
                                                  rows: rows)
                    let where_ = "count \(count) rows \(rows) selected \(selected)"
                    XCTAssertGreaterThanOrEqual(window.first, 0, where_)
                    XCTAssertLessThanOrEqual(window.first + window.visible, count, where_)
                    XCTAssertLessThanOrEqual(window.visible, rows, where_)
                    XCTAssertTrue(
                        (window.first..<(window.first + window.visible)).contains(selected),
                        where_ + " — the selection was off the screen")
                    XCTAssertEqual(window.first + window.visible + window.hidden,
                                   count, where_)
                    // Never nothing: a window with no rows in it cannot
                    // hold a selection, which is how the one-row case got
                    // through the first time.
                    XCTAssertGreaterThan(window.visible, 0, where_)
                }
            }
        }
    }

    func testTheSelectedRowIsAlwaysVisible() {
        for selected in [0, 1, 17, 49] {
            let lines = plain(Dashboard.render(
                state(items: (0..<50).map { item("F\($0).mkv") }, selected: selected),
                size: size))
            XCTAssertTrue(lines.contains { $0.contains("F\(selected).mkv") },
                          "selection \(selected) was off the screen")
        }
    }

    // MARK: Lines

    func testALineIsCutRatherThanWrapped() {
        let line = Line("abcdefghij")
        XCTAssertEqual(line.truncated(to: 5).plain, "abcd…")
        XCTAssertEqual(line.truncated(to: 100).plain, "abcdefghij")
        XCTAssertEqual(line.truncated(to: 0).plain, "")
    }

    /// The styles are a separate layer, so a test reads words and not escape
    /// codes — and the escape codes are still checked, once, here.
    func testStylingIsSeparateFromTheText() {
        let line = Line([Segment("ok", .ok), Segment(" plain")])
        XCTAssertEqual(line.plain, "ok plain")
        XCTAssertEqual(line.ansi(), "\u{1B}[32mok\u{1B}[0m plain")
    }

    func testAMessageIsShownAndAnErrorIsMarked() {
        let good = Dashboard.message(
            state(snapshot: StatusSnapshot(lastResult: "Renamed 3.")), columns: 80)
        XCTAssertEqual(good.plain, "Renamed 3.")
        XCTAssertEqual(good.segments.first?.style, .normal)

        let bad = Dashboard.message(
            state(snapshot: StatusSnapshot(lastResult: "It broke.", hasError: true)),
            columns: 80)
        XCTAssertEqual(bad.segments.first?.style, .failed)
    }
}

extension SystemCheck.State {
    /// Spelled out rather than CaseIterable, which this enum does not
    /// declare: adding a case should break this list loudly.
    static var allStates: [SystemCheck.State] { [.ok, .warning, .failed, .off] }
}
