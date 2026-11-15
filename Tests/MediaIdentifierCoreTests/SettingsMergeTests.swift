import XCTest
@testable import MediaIdentifierCore

/// Apply writes back what the user changed, and nothing else.
///
/// The window reads the settings once, at startup, and its widgets are that
/// snapshot for the life of the window. Pressing Apply used to write every
/// widget unconditionally, so anything somebody else had changed since —
/// a second window, a hand-edited settings.json — was set back to what this
/// window had seen hours ago. `AppWindow.loadedSettings` has carried a
/// nine-line comment describing the defence since it was written, and had no
/// reader at all: assigned once, consulted never.
final class SettingsMergeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Text.language = .german
    }

    private func base() -> WebSettings {
        var settings = WebSettings(sourceFolder: "/srv/downloads")
        settings.moviesFolder = "/srv/films"
        settings.localLLMBaseURL = "http://192.168.3.116:1234"
        settings.localLLMModel = "qwen"
        settings.identification = .localLLM
        settings.schedule = Schedule(isEnabled: false, hour: 3)
        return settings
    }

    // MARK: The one that mattered

    /// The schedule turned on elsewhere, then a folder picked here and Apply
    /// pressed. The run silently stopped happening.
    func testApplyDoesNotTurnOffASchedulePutOnElsewhere() {
        let loaded = base()                       // what the window saw at 09:00
        var stored = base()
        stored.schedule.isEnabled = true          // turned on at 11:00, elsewhere
        var typed = loaded                        // the widgets, untouched
        typed.moviesFolder = "/srv/films2"        // except the folder

        let merged = SettingsMerge.applying(typed: typed, loaded: loaded, to: stored)

        XCTAssertTrue(merged.schedule.isEnabled,
                      "Apply turned the nightly run off again")
    }

    /// And the other way, which is worse: a schedule the user turned off
    /// must not be re-armed by an unrelated Apply.
    func testApplyDoesNotTurnOnAScheduleTurnedOffElsewhere() {
        var loaded = base()
        loaded.schedule.isEnabled = true
        var stored = base()
        stored.schedule.isEnabled = false
        let typed = loaded

        let merged = SettingsMerge.applying(typed: typed, loaded: loaded, to: stored)

        XCTAssertFalse(merged.schedule.isEnabled,
                       "Apply re-armed a run the user had switched off")
    }

    // MARK: What the user did change still goes through

    func testAChangedFieldIsWritten() {
        let loaded = base()
        let stored = base()
        var typed = base()
        typed.localLLMBaseURL = "http://192.168.3.200:1234"

        let merged = SettingsMerge.applying(typed: typed, loaded: loaded, to: stored)

        XCTAssertEqual(merged.localLLMBaseURL, "http://192.168.3.200:1234")
    }

    /// Changing one field must not drag the others' stale values with it.
    func testChangingOneFieldLeavesTheRestAsTheyAreStored() {
        let loaded = base()
        var stored = base()
        stored.localLLMModel = "qwen3.6-35b"      // changed elsewhere
        stored.schedule.hour = 4                  // and this
        var typed = base()
        typed.identification = .offline           // the user changed only this

        let merged = SettingsMerge.applying(typed: typed, loaded: loaded, to: stored)

        XCTAssertEqual(merged.identification, .offline)
        XCTAssertEqual(merged.localLLMModel, "qwen3.6-35b")
        XCTAssertEqual(merged.schedule.hour, 4)
    }

    /// A field the user clears is a change like any other.
    func testClearingAFieldIsWritten() {
        let loaded = base()
        let stored = base()
        var typed = base()
        typed.localLLMModel = ""

        let merged = SettingsMerge.applying(typed: typed, loaded: loaded, to: stored)

        XCTAssertEqual(merged.localLLMModel, "")
    }

    /// The schedule is merged field by field: a window that changed only the
    /// time must not write back a stale "enabled" with it.
    func testTheScheduleIsMergedFieldByField() {
        var loaded = base()
        loaded.schedule = Schedule(isEnabled: false, hour: 3, minute: 0)
        var stored = base()
        stored.schedule = Schedule(isEnabled: true, hour: 3, minute: 0,
                                   alsoRename: true)
        var typed = base()
        typed.schedule = Schedule(isEnabled: false, hour: 5, minute: 30)

        let merged = SettingsMerge.applying(typed: typed, loaded: loaded, to: stored)

        XCTAssertEqual(merged.schedule.hour, 5, "the user's new time was lost")
        XCTAssertEqual(merged.schedule.minute, 30)
        XCTAssertTrue(merged.schedule.isEnabled, "the stale 'off' was written back")
        XCTAssertTrue(merged.schedule.alsoRename)
    }

    /// With nothing changed anywhere, the result is what is stored.
    func testNothingChangedChangesNothing() {
        let loaded = base()
        var stored = base()
        stored.schedule.isEnabled = true
        stored.watchSourceFolder = true

        let merged = SettingsMerge.applying(typed: loaded, loaded: loaded, to: stored)

        XCTAssertEqual(merged, stored)
    }

    /// The language, which the window owns and which reaches a path nowhere
    /// — but losing it means the interface silently changes language.
    func testTheLanguageIsMergedLikeTheRest() {
        var loaded = base()
        loaded.language = .german
        var stored = base()
        stored.language = .english
        let typed = loaded

        let merged = SettingsMerge.applying(typed: typed, loaded: loaded, to: stored)

        XCTAssertEqual(merged.language, .english)
    }
}
