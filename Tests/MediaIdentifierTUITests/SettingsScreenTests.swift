import XCTest
@testable import MediaIdentifierTUI
@testable import MediaIdentifierCore

/// Editing the settings from the terminal.
///
/// The form is two pure functions and a small state machine, so all three
/// can be held down here: what the screen shows, what a key press changes,
/// and the bargain that leaving without saving changes nothing.
final class SettingsScreenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Text.language = .english
    }

    override func tearDown() {
        Text.language = .german
        super.tearDown()
    }

    private let size = ScreenSize(columns: 100, rows: 30)

    private func screen(_ settings: WebSettings = WebSettings(),
                        secrets: Set<SecretKey> = []) -> SettingsScreen {
        SettingsScreen(settings: settings, secrets: secrets)
    }

    private func field(_ id: String, _ settings: WebSettings = WebSettings(),
                       secrets: Set<SecretKey> = []) -> SettingsForm.Field? {
        SettingsForm.fields(for: settings, secrets: secrets).first { $0.id == id }
    }

    // MARK: What the form says

    func testEverySettingTheWebFormHasIsHereToo() {
        let ids = Set(SettingsForm.fields(for: WebSettings(), secrets: []).map(\.id))
        for expected in ["sourceFolder", "moviesFolder", "seriesFolder", "musicFolder",
                         "libraryMode", "language", "conflictPolicy", "watchSourceFolder",
                         "identification", "localLLMBaseURL", "localLLMModel",
                         "jellyfinBaseURL", "scheduleEnabled", "scheduleCadence",
                         "scheduleTime", "scheduleEveryHours", "scheduleRename",
                         "scheduleSend", "remoteEnabled", "remoteHost", "remotePort",
                         "remoteUser", "remoteBasePath", "remoteTransport",
                         "remoteAuthentication", "remoteIdentityFile",
                         "remoteRemoveLocal"] {
            XCTAssertTrue(ids.contains(expected), "no field for \(expected)")
        }
        for key in SecretKey.allCases {
            XCTAssertTrue(ids.contains(SettingsForm.secretField(key)),
                          "no field for \(key)")
        }
    }

    /// A secret's id is built from its raw value, which differs from the
    /// case name — `.localLLMAPIKey` is "local-llm-api-key". A mismatch
    /// would make the field unwritable and nothing would report it.
    func testASecretFieldIsFoundBackFromItsID() {
        for key in SecretKey.allCases {
            XCTAssertEqual(SettingsForm.secret(for: SettingsForm.secretField(key)), key)
        }
        XCTAssertNil(SettingsForm.secret(for: "sourceFolder"))
    }

    /// The screen never has the value, so it says whether one is stored and
    /// nothing else.
    func testASecretSaysOnlyWhetherOneIsStored() {
        XCTAssertEqual(field(SettingsForm.secretField(.remotePassword),
                             WebSettings(), secrets: [.remotePassword])?.value, "stored")
        XCTAssertEqual(field(SettingsForm.secretField(.remotePassword))?.value, "not set")
    }

    func testTheValidatorsComplaintIsShownOnTheFieldItIsAbout() {
        var settings = WebSettings()
        settings.remote = RemoteTarget(isEnabled: true, host: "", user: "u",
                                       basePath: "/x")
        let host = SettingsForm.fields(for: settings, secrets: [])
            .first { $0.id == "remoteHost" }
        XCTAssertNotNil(host?.problem, "the empty address was not complained about")
    }

    // MARK: Changing things

    func testTypingIntoAFieldChangesOnlyThatField() {
        let before = WebSettings()
        let after = SettingsForm.applying("/srv/media/Filme", to: "moviesFolder",
                                          in: before)
        XCTAssertEqual(after.moviesFolder, "/srv/media/Filme")
        XCTAssertEqual(after.sourceFolder, before.sourceFolder)
        XCTAssertEqual(after.remote, before.remote)
    }

    /// A port that is not a number is kept impossible so the validator can
    /// say so, rather than quietly becoming a port nobody asked for.
    func testAPortThatIsNotANumberIsNotGuessed() {
        let after = SettingsForm.applying("steckdose", to: "remotePort",
                                          in: WebSettings())
        XCTAssertEqual(after.remote.port, -1)
        var enabled = after
        enabled.remote.isEnabled = true
        enabled.remote.host = "h"
        enabled.remote.user = "u"
        enabled.remote.basePath = "/x"
        XCTAssertTrue(enabled.problems().contains { $0.field == "remotePort" })
    }

    func testATimeIsReadAndSomethingElseIsNotGuessed() {
        let good = SettingsForm.applying("04:30", to: "scheduleTime", in: WebSettings())
        XCTAssertEqual(good.schedule.hour, 4)
        XCTAssertEqual(good.schedule.minute, 30)

        var bad = SettingsForm.applying("morgens", to: "scheduleTime", in: WebSettings())
        bad.schedule.isEnabled = true
        XCTAssertFalse(bad.problems().isEmpty, "\"morgens\" was accepted as a time")
    }

    func testAToggleFlips() {
        let on = SettingsForm.toggling("remoteRemoveLocal", in: WebSettings())
        XCTAssertTrue(on.remote.removeLocalAfterSend)
        XCTAssertFalse(SettingsForm.toggling("remoteRemoveLocal", in: on)
            .remote.removeLocalAfterSend)
    }

    /// Stepping backwards off the first entry must wrap to the last. Swift's
    /// % keeps the sign of the left operand, so the obvious arithmetic
    /// indexes with -1 and traps.
    func testAChoiceWrapsInBothDirections() {
        var settings = WebSettings()
        settings.libraryMode = LibraryMode.allCases.first!
        let back = SettingsForm.cycling("libraryMode", by: -1, in: settings)
        XCTAssertEqual(back.libraryMode, LibraryMode.allCases.last!)
        let forward = SettingsForm.cycling("libraryMode", by: 1, in: back)
        XCTAssertEqual(forward.libraryMode, LibraryMode.allCases.first!)
    }

    /// The language list is one longer than the languages: "follow the
    /// system" comes first and is a choice of its own.
    func testTheLanguageCycleIncludesFollowingTheSystem() {
        var seen: [Language?] = []
        var settings = WebSettings()
        for _ in 0...Language.allCases.count {
            seen.append(settings.language)
            settings = SettingsForm.cycling("language", by: 1, in: settings)
        }
        XCTAssertTrue(seen.contains(nil), "there was no way back to following the system")
        for language in Language.allCases {
            XCTAssertTrue(seen.contains(language), "\(language) was not reachable")
        }
    }

    // MARK: The screen

    func testSectionsCannotBeSelected() {
        var state = screen()
        let fields = state.fields
        XCTAssertTrue(fields[state.selected].isEditable)
        for _ in 0..<(fields.count * 2) {
            _ = state.handle(.down)
            XCTAssertTrue(state.fields[state.selected].isEditable,
                          "landed on a heading")
        }
    }

    func testTypingCommitsOnEnterAndDiscardsOnEscape() {
        var state = screen()
        while state.fields[state.selected].id != "sourceFolder" { _ = state.handle(.down) }

        _ = state.handle(.enter)
        for character in "/tmp/in" { _ = state.handle(.character(character)) }
        _ = state.handle(.enter)
        XCTAssertEqual(state.draft.sourceFolder, "/tmp/in")

        _ = state.handle(.enter)
        for character in "/wrong" { _ = state.handle(.character(character)) }
        _ = state.handle(.escape)
        XCTAssertEqual(state.draft.sourceFolder, "/tmp/in", "escape kept the typing")
    }

    func testBackspaceDeletes() {
        var state = screen()
        while state.fields[state.selected].id != "sourceFolder" { _ = state.handle(.down) }
        _ = state.handle(.enter)
        for character in "/tmpX" { _ = state.handle(.character(character)) }
        _ = state.handle(.backspace)
        _ = state.handle(.enter)
        XCTAssertEqual(state.draft.sourceFolder, "/tmp")
    }

    /// While typing, "q" is a letter. A text field that quit the screen on
    /// the first q of a path would be unusable.
    func testQIsALetterWhileTyping() {
        var state = screen()
        while state.fields[state.selected].id != "sourceFolder" { _ = state.handle(.down) }
        _ = state.handle(.enter)
        XCTAssertEqual(state.handle(.character("q")), .none)
        _ = state.handle(.enter)
        XCTAssertEqual(state.draft.sourceFolder, "q")
    }

    /// Leaving with changes asks rather than losing them.
    func testLeavingSaysWhenThereAreUnsavedChanges() {
        var state = screen()
        XCTAssertEqual(state.handle(.character("q")), .leave(unsaved: false))

        while state.fields[state.selected].id != "watchSourceFolder" {
            _ = state.handle(.down)
        }
        _ = state.handle(.enter)
        XCTAssertTrue(state.hasUnsavedChanges)
        XCTAssertEqual(state.handle(.character("q")), .leave(unsaved: true))
    }

    func testSavingIsAskedForExplicitly() {
        var state = screen()
        XCTAssertEqual(state.handle(.character("S")), .save)
    }

    /// A secret is submitted as a secret, not written into the settings.
    func testASecretGoesToTheSecretStoreAndNotIntoTheSettings() {
        var state = screen()
        while state.fields[state.selected].id
            != SettingsForm.secretField(.remotePassword) { _ = state.handle(.down) }
        _ = state.handle(.enter)
        for character in "hunter2" { _ = state.handle(.character(character)) }
        XCTAssertEqual(state.handle(.enter), .setSecret(.remotePassword, "hunter2"))

        // And nothing of it reached the settings, which get written to a
        // file that is not the secret store.
        let encoded = try? JSONEncoder().encode(state.draft)
        let text = String(decoding: encoded ?? Data(), as: UTF8.self)
        XCTAssertFalse(text.contains("hunter2"), "the secret was put in settings.json")
    }

    // MARK: Drawing

    func testTheScreenFitsTheTerminal() {
        for columns in [40, 80, 140] {
            for rows in [10, 24, 50] {
                let size = ScreenSize(columns: columns, rows: rows)
                let lines = screen().render(size: size)
                XCTAssertEqual(lines.count, rows, "\(columns)x\(rows)")
                for line in lines {
                    XCTAssertLessThanOrEqual(line.width, columns, "\"\(line.plain)\"")
                }
            }
        }
    }

    /// Typing shows what is typed; a secret shows that something is being
    /// typed without showing what.
    func testASecretIsMaskedWhileItIsTyped() {
        var state = screen()
        while state.fields[state.selected].id
            != SettingsForm.secretField(.remotePassword) { _ = state.handle(.down) }
        _ = state.handle(.enter)
        for character in "hunter2" { _ = state.handle(.character(character)) }
        let text = state.render(size: size).map(\.plain).joined(separator: "\n")
        XCTAssertFalse(text.contains("hunter2"), "the password was drawn on the screen")
        XCTAssertTrue(text.contains("•••••••"))
    }

    func testAnEmptyFieldShowsAnExampleRatherThanNothing() {
        let text = screen().render(size: size).map(\.plain).joined(separator: "\n")
        XCTAssertTrue(text.contains("/home/you/Downloads"))
    }

    func testTheScreenSaysWhenThereIsSomethingUnsaved() {
        var state = screen()
        XCTAssertFalse(state.render(size: size)[0].plain.contains("unsaved"))
        while state.fields[state.selected].id != "watchSourceFolder" {
            _ = state.handle(.down)
        }
        _ = state.handle(.enter)
        XCTAssertTrue(state.render(size: size)[0].plain.contains("unsaved"))
    }
}
