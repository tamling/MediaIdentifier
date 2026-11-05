import XCTest
@testable import MediaIdentifierTUI
@testable import MediaIdentifierCore

/// The convert screen.
final class ConvertScreenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Text.language = .english
    }

    override func tearDown() {
        Text.language = .german
        super.tearDown()
    }

    private let size = ScreenSize(columns: 100, rows: 24)

    private func candidate(_ name: String, gigabytes: Double = 1)
        -> ConversionCandidate {
        ConversionCandidate(source: URL(fileURLWithPath: "/library/\(name)"),
                            byteSize: Int64(gigabytes * 1_000_000_000))
    }

    private func screen(_ candidates: [ConversionCandidate] = [],
                        snapshot: StatusSnapshot = StatusSnapshot(),
                        haveFFmpeg: Bool = true) -> ConvertScreen {
        ConvertScreen(candidates: candidates, options: WebConversionSettings(),
                      snapshot: snapshot, haveFFmpeg: haveFFmpeg)
    }

    // MARK: Nothing happens by accident

    /// Converting is slow and writes a second copy of every film. A screen
    /// that opened with everything ticked would make Enter a far bigger
    /// button than it looks.
    func testNothingIsTickedToStartWith() {
        let state = screen([candidate("a.mkv"), candidate("b.mkv")])
        XCTAssertTrue(state.ticked.isEmpty)
    }

    func testStartingDoesNothingWithNothingTicked() {
        var state = screen([candidate("a.mkv")])
        XCTAssertEqual(state.handle(.enter), .none)
        _ = state.handle(.character(" "))
        guard case .start(let ids) = state.handle(.enter) else {
            return XCTFail("a ticked file did not start")
        }
        XCTAssertEqual(ids.count, 1)
    }

    func testStartingDoesNothingWithoutFFmpeg() {
        var state = screen([candidate("a.mkv")], haveFFmpeg: false)
        _ = state.handle(.character("a"))
        XCTAssertEqual(state.handle(.enter), .none)
    }

    func testStartingDoesNothingWhileItIsAlreadyRunning() {
        var state = screen([candidate("a.mkv")],
                           snapshot: StatusSnapshot(converting: true))
        _ = state.handle(.character("a"))
        XCTAssertEqual(state.handle(.enter), .none)
    }

    func testStoppingOnlyExistsWhileSomethingRuns() {
        var idle = screen([candidate("a.mkv")])
        XCTAssertEqual(idle.handle(.character("c")), .none)
        var busy = screen([candidate("a.mkv")],
                          snapshot: StatusSnapshot(converting: true))
        XCTAssertEqual(busy.handle(.character("c")), .cancel)
    }

    // MARK: Ticks

    func testTickingAllAndNone() {
        var state = screen([candidate("a.mkv"), candidate("b.mkv")])
        _ = state.handle(.character("a"))
        XCTAssertEqual(state.ticked.count, 2)
        _ = state.handle(.character("n"))
        XCTAssertTrue(state.ticked.isEmpty)
    }

    /// A refresh that drops a file must drop its tick with it, or a start
    /// would carry an id the engine no longer knows.
    func testATickForAFileThatIsGoneIsDropped() {
        let a = candidate("a.mkv")
        let b = candidate("b.mkv")
        var state = screen([a, b])
        _ = state.handle(.character("a"))
        XCTAssertEqual(state.ticked.count, 2)

        state.refresh(candidates: [a], snapshot: StatusSnapshot())
        XCTAssertEqual(state.ticked, [a.id])
    }

    func testTheSelectionIsPulledBackWhenTheListShrinks() {
        var state = screen((0..<5).map { candidate("f\($0).mkv") })
        _ = state.handle(.end)
        XCTAssertEqual(state.selected, 4)
        state.refresh(candidates: [candidate("one.mkv")], snapshot: StatusSnapshot())
        XCTAssertEqual(state.selected, 0)
    }

    // MARK: Options

    func testTheOptionsStepInPlaceAndAreSavedAsTheyChange() {
        var state = screen()
        guard case .save(let after) = state.handle(.character("v")) else {
            return XCTFail("changing the codec did not ask for a save")
        }
        XCTAssertNotEqual(after.videoCodec, WebConversionSettings().videoCodec)
    }

    /// Lower is better and bigger, so "+" has to mean better rather than
    /// the number going up.
    func testPlusMeansBetterQualityNotABiggerNumber() {
        var state = screen()
        let start = state.options.quality
        _ = state.handle(.character("+"))
        XCTAssertLessThan(state.options.quality, start)
        _ = state.handle(.character("-"))
        _ = state.handle(.character("-"))
        XCTAssertGreaterThan(state.options.quality, start)
    }

    func testQualityStaysInRange() {
        var state = screen()
        for _ in 0..<80 { _ = state.handle(.character("+")) }
        XCTAssertEqual(state.options.quality, 0)
        for _ in 0..<80 { _ = state.handle(.character("-")) }
        XCTAssertEqual(state.options.quality, 51)
    }

    // MARK: What it says before it does anything

    /// The result is a second copy of a film, so what Enter would cost is
    /// on the screen before it is pressed.
    func testItSaysWhatTheTickedFilesWouldBecome() {
        var state = screen([candidate("a.mkv", gigabytes: 4)])
        _ = state.handle(.character("a"))
        let text = state.render(size: size).map(\.plain).joined(separator: "\n")
        XCTAssertTrue(text.contains("1 ticked"), text)
        XCTAssertTrue(text.contains("→"), text)
        XCTAssertTrue(text.contains("estimated"), text)
    }

    func testItSaysNothingIsDeleted() {
        let text = screen().render(size: size).map(\.plain).joined(separator: "\n")
        XCTAssertTrue(text.contains("Nothing is deleted"), text)
    }

    func testAMissingFFmpegIsSaidPlainlyWithTheRemedy() {
        let text = screen([candidate("a.mkv")], haveFFmpeg: false)
            .render(size: size).map(\.plain).joined(separator: "\n")
        XCTAssertTrue(text.contains("apt install ffmpeg"), text)
    }

    func testAnEmptyListSaysWhatToPress() {
        let text = screen().render(size: size).map(\.plain).joined(separator: "\n")
        XCTAssertTrue(text.contains("[f]"), text)
    }

    // MARK: Shape

    func testTheScreenFitsTheTerminal() {
        for columns in [40, 80, 160] {
            for rows in [10, 24, 50] {
                for converting in [false, true] {
                    let size = ScreenSize(columns: columns, rows: rows)
                    let snapshot = StatusSnapshot(converting: converting,
                                                  convertProgress: 0.4)
                    let lines = screen((0..<60).map {
                        candidate("A rather long film name number \($0).mkv")
                    }, snapshot: snapshot).render(size: size)
                    XCTAssertEqual(lines.count, rows, "\(columns)x\(rows)")
                    for line in lines {
                        XCTAssertLessThanOrEqual(line.width, columns,
                                                 "\(columns)x\(rows): \"\(line.plain)\"")
                    }
                }
            }
        }
    }
}
