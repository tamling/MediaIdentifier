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
                         "remoteUser", "remoteBasePath", "remoteMoviesPath",
                         "remoteSeriesPath", "remoteMusicPath", "remoteTransport",
                         "remoteAuthentication", "remoteIdentityFile",
                         "remoteTrustOnFirstUse", "remoteRemoveLocal"] {
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

/// Testing a connection, and saying what a field does.
///
/// Both came out of the first five minutes of somebody using it: "what is
/// h/l cycle?" and "how do I test the connection?". The first was a label
/// that explained nothing, the second was missing outright.
final class SettingsTestingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Text.language = .english
    }

    override func tearDown() {
        Text.language = .german
        super.tearDown()
    }

    private let size = ScreenSize(columns: 100, rows: 30)

    private func screen() -> SettingsScreen {
        SettingsScreen(settings: WebSettings(), secrets: [])
    }

    private func moved(to id: String) -> SettingsScreen {
        var state = screen()
        for _ in 0..<(state.fields.count * 2) where state.fields[state.selected].id != id {
            _ = state.handle(.down)
        }
        return state
    }

    // MARK: Which field tests what

    func testEachSectionKnowsWhatItWouldTest() {
        XCTAssertEqual(SettingsForm.test(for: "localLLMBaseURL"),
                       .testLocalLLMConnection)
        XCTAssertEqual(SettingsForm.test(for: "localLLMModel"),
                       .testLocalLLMConnection)
        XCTAssertEqual(SettingsForm.test(for: SettingsForm.secretField(.localLLMAPIKey)),
                       .testLocalLLMConnection)
        XCTAssertEqual(SettingsForm.test(for: "jellyfinBaseURL"),
                       .testJellyfinConnection)
        XCTAssertEqual(SettingsForm.test(for: "remoteHost"), .testRemoteConnection)
        XCTAssertEqual(SettingsForm.test(for: SettingsForm.secretField(.remotePassword)),
                       .testRemoteConnection)
    }

    /// A folder has nothing to connect to, so [t] offers nothing there
    /// rather than testing whatever was last touched.
    func testAFieldWithNothingToTestOffersNothing() {
        XCTAssertNil(SettingsForm.test(for: "sourceFolder"))
        XCTAssertNil(SettingsForm.test(for: "scheduleTime"))
        XCTAssertNil(SettingsForm.testName(for: "moviesFolder"))
    }

    /// Saving has to happen first, or the test asks the engine about the
    /// address it had before — and a passing test on the old address is the
    /// most misleading answer available.
    func testTestingAsksToSaveTheTypedAddressWithIt() {
        var state = moved(to: "remoteHost")
        _ = state.handle(.enter)
        for character in "nas.local" { _ = state.handle(.character(character)) }
        _ = state.handle(.enter)
        XCTAssertEqual(state.draft.remote.host, "nas.local")
        XCTAssertEqual(state.handle(.character("t")), .test(.testRemoteConnection))
    }

    func testTIsALetterWhileTyping() {
        var state = moved(to: "remoteHost")
        _ = state.handle(.enter)
        XCTAssertEqual(state.handle(.character("t")), .none)
        _ = state.handle(.enter)
        XCTAssertEqual(state.draft.remote.host, "t")
    }

    // MARK: The arrows that were missing

    func testArrowsStepAChoiceAndNotOnlyTheViKeys() {
        var left = moved(to: "libraryMode")
        let start = left.draft.libraryMode
        _ = left.handle(.right)
        XCTAssertNotEqual(left.draft.libraryMode, start, "→ did nothing")
        _ = left.handle(.left)
        XCTAssertEqual(left.draft.libraryMode, start, "← did not come back")
    }

    // MARK: The row that describes the field

    /// It used to say "h/l cycle" on every field, which says neither what
    /// is cycled nor that it only applies to a choice.
    func testTheRowSaysWhatThisFieldDoes() {
        let text = moved(to: "sourceFolder").render(size: size).last!.plain
        XCTAssertTrue(text.contains("edit"), text)
        XCTAssertFalse(text.contains("of "), text)

        let toggle = moved(to: "watchSourceFolder").render(size: size).last!.plain
        XCTAssertTrue(toggle.contains("on/off"), toggle)

        // A choice says how many there are, so it is clear there is a list.
        let choice = moved(to: "libraryMode").render(size: size).last!.plain
        XCTAssertTrue(choice.contains("←→"), choice)
        XCTAssertTrue(choice.contains("of \(LibraryMode.allCases.count)"), choice)

        let secret = moved(to: SettingsForm.secretField(.remotePassword))
            .render(size: size).last!.plain
        XCTAssertTrue(secret.contains("enter"), secret)
    }

    /// And it offers the test only where there is one.
    func testTheRowOffersTheTestOnlyWhereThereIsOne() {
        let server = moved(to: "remoteHost").render(size: size).last!.plain
        XCTAssertTrue(server.contains("test server"), server)

        let folder = moved(to: "sourceFolder").render(size: size).last!.plain
        XCTAssertFalse(folder.contains("test"), folder)
    }

    // MARK: The server's three paths, and the login that failed silently

    func testEachKindsPathCanBeTypedAndReachesTheRightField() {
        let settings = WebSettings()
        XCTAssertEqual(SettingsForm.applying("/v1/Filme", to: "remoteMoviesPath",
                                             in: settings).remote.moviesPath, "/v1/Filme")
        XCTAssertEqual(SettingsForm.applying("/v2/Serien", to: "remoteSeriesPath",
                                             in: settings).remote.seriesPath, "/v2/Serien")
        XCTAssertEqual(SettingsForm.applying("/v1/Musik", to: "remoteMusicPath",
                                             in: settings).remote.musicPath, "/v1/Musik")
    }

    func testTrustingTheServerIsAToggleAndStartsOff() {
        let settings = WebSettings()
        XCTAssertFalse(settings.remote.trustOnFirstUse)
        XCTAssertTrue(SettingsForm.toggling("remoteTrustOnFirstUse", in: settings)
            .remote.trustOnFirstUse)
    }

    /// The field that cost the evening. With login set to "key", ssh is not
    /// allowed to ask for anything, so a stored password is never offered —
    /// and the row said nothing about that, while the arrows that change it
    /// did nothing at all.
    func testTheLoginFieldSaysThatAKeyIgnoresTheStoredPassword() {
        let hint = SettingsForm.fields(for: WebSettings(), secrets: [.remotePassword])
            .first { $0.id == "remoteAuthentication" }?.hint ?? ""
        XCTAssertTrue(hint.lowercased().contains("password"), hint)
        XCTAssertTrue(hint.contains("←→"), hint)
    }

    /// The paths are part of the server, so [t] tests the server from them
    /// rather than offering nothing where it is most wanted.
    func testThePerKindPathsOfferTheServerTest() {
        for id in ["remoteMoviesPath", "remoteSeriesPath", "remoteMusicPath"] {
            XCTAssertEqual(SettingsForm.test(for: id), .testRemoteConnection, id)
        }
    }

    /// Every server field the terminal offers is on the web form too.
    ///
    /// Checked by machine rather than by eye, because by eye is how the
    /// three paths nearly went in without the web form hearing about them.
    /// One engine behind three front-ends is only honest if a setting added
    /// to one is reachable from the others.
    func testEveryServerFieldOfTheTerminalIsOnTheWebFormToo() {
        let token = String(repeating: "d00d", count: 16)
        let router = WebRouter(policy: WebSecurityPolicy(token: token, isTLS: true),
                               settings: { WebSettings() },
                               snapshot: { StatusSnapshot() })
        let response = router.respond(to: HTTPRequest(
            method: "GET", path: "/settings",
            headers: ["authorization": "Bearer \(token)"]))
        // Said explicitly: a login redirect would otherwise fail every
        // assertion below and read like twelve missing fields.
        XCTAssertEqual(response.status, 200, "the settings page was not served")
        let html = String(decoding: response.body, as: UTF8.self)

        let ids = SettingsForm.fields(for: WebSettings(), secrets: [])
            .map(\.id).filter { $0.hasPrefix("remote") }
        XCTAssertFalse(ids.isEmpty, "the terminal form lost its server section")
        for id in ids {
            XCTAssertTrue(html.contains("name=\"\(id)\""),
                          "the web form has no \(id)")
        }
    }

    func testTheRowStillFitsEveryWidth() {
        for id in ["sourceFolder", "libraryMode", "remoteHost", "watchSourceFolder",
                   "remoteMusicPath", "remoteAuthentication"] {
            let state = moved(to: id)
            for columns in [40, 60, 80, 120] {
                let size = ScreenSize(columns: columns, rows: 30)
                for line in state.render(size: size) {
                    XCTAssertLessThanOrEqual(line.width, columns,
                                             "\(id) at \(columns): \"\(line.plain)\"")
                }
            }
        }
    }
}
