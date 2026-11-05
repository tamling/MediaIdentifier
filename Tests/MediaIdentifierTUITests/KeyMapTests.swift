import XCTest
@testable import MediaIdentifierTUI
@testable import MediaIdentifierCore

/// What each key does.
///
/// The key map is a pure function of (key, state) precisely so it can be
/// held down here: it is the part most likely to be wrong and the part
/// hardest to notice being wrong, because a key that silently does nothing
/// looks exactly like a key that is not pressed hard enough.
final class KeyMapTests: XCTestCase {

    private func action(_ key: Terminal.Key, hasItems: Bool = true,
                        busy: Bool = false) -> TUIApp.Action {
        TUIApp.action(for: key, hasItems: hasItems, busy: busy)
    }

    // MARK: Leaving

    /// Three ways out, because somebody who has lost their bearings in a
    /// full-screen program tries all three.
    func testThereAreThreeWaysOut() {
        XCTAssertEqual(action(.character("q")), .quit)
        XCTAssertEqual(action(.escape), .quit)
        // Ctrl-C arrives as "q" from the decoder, so it lands here too.
    }

    // MARK: Refusing rather than submitting

    /// A key that cannot do anything now does nothing, rather than
    /// submitting a command the engine will refuse: the refusal would
    /// overwrite the message the user is reading, which is usually the one
    /// explaining why the key does nothing.
    func testAKeyThatCannotWorkDoesNotSubmitAnything() {
        XCTAssertEqual(action(.character("r"), hasItems: false), .nothing)
        XCTAssertEqual(action(.character(" "), hasItems: false), .nothing)
        XCTAssertEqual(action(.character("a"), hasItems: false), .nothing)
        XCTAssertEqual(action(.character("t"), hasItems: false), .nothing)
    }

    /// Nothing that starts work is accepted while work is running. The
    /// engine serialises anyway, but a second scan queued behind the first
    /// is a surprise, not a feature.
    func testNothingIsStartedWhileSomethingIsRunning() {
        for key in ["s", "r", "u", "t"] {
            XCTAssertEqual(action(.character(Character(key)), busy: true), .nothing, key)
        }
    }

    /// Looking around still works while a run is going: that is when you
    /// most want to.
    func testLookingAroundStillWorksWhileBusy() {
        XCTAssertEqual(action(.down, busy: true), .move(1))
        XCTAssertEqual(action(.character("i"), busy: true), .toggleChecks)
        XCTAssertEqual(action(.character("q"), busy: true), .quit)
    }

    // MARK: Moving

    func testArrowsAndViKeysBothMove() {
        XCTAssertEqual(action(.up), .move(-1))
        XCTAssertEqual(action(.character("k")), .move(-1))
        XCTAssertEqual(action(.down), .move(1))
        XCTAssertEqual(action(.character("j")), .move(1))
    }

    func testTheSelectionStaysInsideTheList() {
        XCTAssertEqual(TUIApp.moving(0, by: -1, count: 10), 0)
        XCTAssertEqual(TUIApp.moving(9, by: 1, count: 10), 9)
        XCTAssertEqual(TUIApp.moving(4, by: 3, count: 10), 7)
        // An empty list has nowhere to be.
        XCTAssertEqual(TUIApp.moving(5, by: 1, count: 0), 0)
        // And a selection left over from a longer list is pulled back in.
        XCTAssertEqual(TUIApp.moving(40, by: 0, count: 10), 9)
    }

    /// Home and End are carried as Int.min and Int.max, so the arithmetic
    /// must not do `selected + Int.max` on the way — that traps in Swift,
    /// and the crash would be an End key press on a list of any size.
    func testHomeAndEndDoNotOverflow() {
        XCTAssertEqual(TUIApp.moving(5, by: Int.min, count: 10), 0)
        XCTAssertEqual(TUIApp.moving(5, by: Int.max, count: 10), 9)
        XCTAssertEqual(TUIApp.moving(0, by: Int.max, count: 1), 0)
    }

    func testPagingMovesMoreThanOneRow() {
        XCTAssertEqual(action(.pageDown), .move(10))
        XCTAssertEqual(action(.pageUp), .move(-10))
    }

    // MARK: Doing

    func testTheWorkingKeysMapToTheWork() {
        XCTAssertEqual(action(.character("s")), .scan)
        XCTAssertEqual(action(.character(" ")), .toggleSelected)
        XCTAssertEqual(action(.character("a")), .tickAll)
        XCTAssertEqual(action(.character("n")), .tickNone)
        XCTAssertEqual(action(.character("r")), .rename)
        XCTAssertEqual(action(.character("u")), .undo)
        XCTAssertEqual(action(.character("t")), .send)
        XCTAssertEqual(action(.character("i")), .toggleChecks)
    }

    /// A key nobody assigned does nothing at all, rather than falling
    /// through to whatever came last in the switch.
    func testAnUnknownKeyDoesNothing() {
        for key in ["z", "7", "ß", "@"] {
            XCTAssertEqual(action(.character(Character(key))), .nothing, key)
        }
        XCTAssertEqual(action(.timeout), .nothing)
    }
}
