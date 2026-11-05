import XCTest
@testable import MediaIdentifierTUI
@testable import MediaIdentifierCore

/// The history screen.
final class HistoryScreenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Text.language = .english
    }

    override func tearDown() {
        Text.language = .german
        super.tearDown()
    }

    private let size = ScreenSize(columns: 100, rows: 20)

    private func entry(_ old: String, _ new: String = "",
                       _ status: RenameLogEntry.Status = .success,
                       at seconds: TimeInterval = 0,
                       error: String? = nil) -> RenameLogEntry {
        RenameLogEntry(oldName: old, newName: new.isEmpty ? old : new,
                       date: Date(timeIntervalSince1970: 1_780_000_000 + seconds),
                       status: status, errorDescription: error)
    }

    private func plain(_ screen: HistoryScreen) -> [String] {
        screen.render(size: size).map(\.plain)
    }

    // MARK: Order

    /// Newest first: the thing you just did is the thing you are asking
    /// about, and scrolling past a year of renames to reach it is not a
    /// feature.
    func testTheNewestIsAtTheTop() {
        let screen = HistoryScreen(entries: [
            entry("old.mkv", at: 0), entry("new.mkv", at: 100),
        ])
        let rows = plain(screen).filter { $0.contains(".mkv") }
        XCTAssertTrue(rows.first?.contains("new.mkv") ?? false, rows.joined())
    }

    // MARK: What a row says

    func testARowSaysWhenWhatAndToWhat() {
        let screen = HistoryScreen(entries: [
            entry("Dark.S01E01.mkv", "Dark - S01E01.mkv"),
        ])
        let row = plain(screen).first { $0.contains("Dark") } ?? ""
        XCTAssertTrue(row.contains("renamed"), row)
        XCTAssertTrue(row.contains("Dark.S01E01.mkv"), row)
        XCTAssertTrue(row.contains("→"), row)
        XCTAssertTrue(row.contains("Dark - S01E01.mkv"), row)
    }

    /// The reason is on the row and not behind a key press: it is why you
    /// opened this screen.
    func testAFailureCarriesItsReasonOnTheRow() {
        let screen = HistoryScreen(entries: [
            entry("A.mkv", "B.mkv", .failure, error: "Permission denied"),
        ])
        let row = plain(screen).first { $0.contains("A.mkv") } ?? ""
        XCTAssertTrue(row.contains("failed"), row)
        XCTAssertTrue(row.contains("Permission denied"), row)
    }

    func testEveryStatusHasItsOwnWord() {
        let statuses: [RenameLogEntry.Status] =
            [.success, .failure, .skipped, .converted, .sent, .downloaded]
        let words = statuses.map { HistoryScreen.word(for: $0) }
        XCTAssertEqual(Set(words).count, statuses.count,
                       "two statuses share a word: \(words)")
        XCTAssertFalse(words.contains { $0.isEmpty })
    }

    func testTheHeaderCountsAndNamesTheFailures() {
        let screen = HistoryScreen(entries: [
            entry("a", "b"), entry("c", "d", .failure), entry("e", "f"),
        ])
        let header = plain(screen)[0]
        XCTAssertTrue(header.contains("3 entries"), header)
        XCTAssertTrue(header.contains("1 failed"), header)
    }

    func testAnEmptyHistorySaysSoRatherThanShowingNothing() {
        XCTAssertTrue(plain(HistoryScreen(entries: []))
            .contains { $0.contains("Nothing has happened yet") })
    }

    // MARK: Keys

    func testItScrollsAndStopsAtBothEnds() {
        var screen = HistoryScreen(entries: (0..<5).map { entry("F\($0)", at: Double($0)) })
        XCTAssertEqual(screen.selected, 0)
        _ = screen.handle(.up)
        XCTAssertEqual(screen.selected, 0, "it scrolled above the first row")
        for _ in 0..<10 { _ = screen.handle(.down) }
        XCTAssertEqual(screen.selected, 4, "it scrolled past the last row")
        _ = screen.handle(.home)
        XCTAssertEqual(screen.selected, 0)
        _ = screen.handle(.end)
        XCTAssertEqual(screen.selected, 4)
    }

    func testQAndEscapeLeave() {
        var screen = HistoryScreen(entries: [])
        XCTAssertEqual(screen.handle(.character("q")), .leave)
        XCTAssertEqual(screen.handle(.escape), .leave)
    }

    // MARK: Clearing

    /// Clearing is not undoable, so it asks — and only the same key again
    /// answers yes. An arrow pressed out of habit is an answer of no.
    func testClearingAsksFirstAndOnlyTheSameKeyConfirms() {
        var screen = HistoryScreen(entries: [entry("a", "b")])
        XCTAssertEqual(screen.handle(.character("x")), .none)
        XCTAssertTrue(screen.confirmingClear)
        XCTAssertTrue(plain(screen).contains { $0.contains("Really clear") })

        XCTAssertEqual(screen.handle(.character("x")), .clear)

        var again = HistoryScreen(entries: [entry("a", "b")])
        _ = again.handle(.character("x"))
        XCTAssertEqual(again.handle(.down), .none, "an arrow cleared the history")
        XCTAssertFalse(again.confirmingClear)
    }

    /// Nothing to clear, nothing to ask about.
    func testAnEmptyHistoryDoesNotAsk() {
        var screen = HistoryScreen(entries: [])
        XCTAssertEqual(screen.handle(.character("x")), .none)
        XCTAssertFalse(screen.confirmingClear)
    }

    // MARK: Shape

    func testTheScreenFitsTheTerminal() {
        for columns in [40, 80, 160] {
            for rows in [8, 20, 60] {
                let size = ScreenSize(columns: columns, rows: rows)
                let screen = HistoryScreen(entries: (0..<200).map {
                    entry("A very long original file name number \($0).mkv",
                          "An even longer renamed file name number \($0).mkv",
                          at: Double($0))
                })
                let lines = screen.render(size: size)
                XCTAssertEqual(lines.count, rows, "\(columns)x\(rows)")
                for line in lines {
                    XCTAssertLessThanOrEqual(line.width, columns,
                                             "\(columns)x\(rows): \"\(line.plain)\"")
                }
            }
        }
    }
}
