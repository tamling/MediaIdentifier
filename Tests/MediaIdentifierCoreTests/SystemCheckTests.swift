import XCTest
@testable import MediaIdentifierCore

/// The traffic light.
///
/// A status panel that lies is worse than none: a green lamp is a promise
/// that the thing behind it works, and someone who has been told that twice
/// and found it false stops reading the panel. So what is checked here is
/// mostly the cases where it would be tempting to show green — a service
/// that is merely configured, one that answered with 401, a library folder
/// on a drive that is no longer mounted.
final class SystemCheckTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // This class asserts the German wording. It builds no coordinator,
        // so nothing would otherwise set the language and it would come from
        // the machine's LANG — German on a Mac with none set, English in the
        // CI container, which sets C.UTF-8. The same code, two answers.
        Text.language = .german
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mediafin-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Text.language = .german
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func checks(_ settings: WebSettings,
                        ffmpeg: Bool = true,
                        secrets: Set<SecretKey> = [],
                        probes: [ProbeSubject: ProbeResult] = [:]) -> [SystemCheck] {
        SystemChecks.all(settings: settings, ffmpegAvailable: ffmpeg,
                         secrets: secrets, probes: probes)
    }

    private func lamp(_ list: [SystemCheck], _ id: String) -> SystemCheck? {
        list.first { $0.id == id }
    }

    // MARK: Folders

    func testAnExistingImportFolderIsGreen() {
        let list = checks(WebSettings(sourceFolder: root.path))
        XCTAssertEqual(lamp(list, "source")?.state, .ok)
    }

    func testNoImportFolderIsRedBecauseNothingCanRunWithoutIt() {
        let list = checks(WebSettings())
        XCTAssertEqual(lamp(list, "source")?.state, .failed)
    }

    /// The unmounted-drive case, and the reason this panel exists: the path
    /// is set, so every form looks right, and nothing works.
    func testAConfiguredFolderThatIsNotThereIsRed() {
        let list = checks(WebSettings(sourceFolder: "/mnt/nas-that-is-not-mounted"))
        XCTAssertEqual(lamp(list, "source")?.state, .failed)
        XCTAssertTrue(lamp(list, "source")?.detail.contains("gibt es nicht") ?? false)
    }

    /// A missing library folder is only a warning: files are then renamed
    /// where they lie, which is a choice rather than a fault.
    func testAnUnsetLibraryFolderIsOnlyAWarning() {
        let list = checks(WebSettings(sourceFolder: root.path))
        XCTAssertEqual(lamp(list, "movies")?.state, .warning)
        XCTAssertEqual(lamp(list, "series")?.state, .warning)
    }

    // (A test used to live here requiring the local library lamps to vanish
    // when a server was configured, and a "Bibliothek" lamp to be green
    // whatever the server had said. Both were wrong — renaming still writes
    // to those folders, and that lamp reported on nothing: it had pinned the
    // bug in place. The two tests that replaced it went with the server
    // feature itself; what survives of the lesson is the lamp above, which
    // reports on a folder that is not there whatever else is configured.)

    // MARK: Services that have to be asked

    /// The important one. A model server that has been typed in is not a
    /// model server that answers, and the difference is the whole point.
    func testAConfiguredButUntestedServiceIsAmberNotGreen() {
        var settings = WebSettings(sourceFolder: root.path)
        settings.identification = .localLLM
        settings.localLLMBaseURL = "http://192.168.1.2:1234"
        settings.localLLMModel = "qwen/qwen3-8b"
        XCTAssertEqual(lamp(checks(settings), "identification")?.state, .warning)
    }

    func testASuccessfulTestTurnsItGreen() {
        var settings = WebSettings(sourceFolder: root.path)
        settings.identification = .localLLM
        settings.localLLMBaseURL = "http://192.168.1.2:1234"
        settings.localLLMModel = "qwen/qwen3-8b"
        let list = checks(settings,
                          probes: [.localLLM: ProbeResult(ok: true, detail: "Antwortet.")])
        XCTAssertEqual(lamp(list, "identification")?.state, .ok)
    }

    func testAFailedTestTurnsItRedAndKeepsTheReason() {
        var settings = WebSettings(sourceFolder: root.path)
        settings.identification = .localLLM
        settings.localLLMBaseURL = "http://192.168.1.2:1234"
        settings.localLLMModel = "qwen/qwen3-8b"
        let list = checks(settings,
                          probes: [.localLLM: ProbeResult(ok: false,
                                                          detail: "Zeitüberschreitung.")])
        XCTAssertEqual(lamp(list, "identification")?.state, .failed)
        // The reason is kept; the age is appended to it.
        XCTAssertTrue(lamp(list, "identification")?.detail.contains("Zeitüberschreitung.")
                        ?? false, lamp(list, "identification")?.detail ?? "")
    }

    /// Offline identification needs nothing and must not nag.
    func testOfflineIdentificationIsGreenWithoutAnythingToAsk() {
        let list = checks(WebSettings(sourceFolder: root.path))
        XCTAssertEqual(lamp(list, "identification")?.state, .ok)
    }

    /// A service nobody set up is grey, not red. Colouring it red teaches
    /// people to ignore the panel, which costs more than the lamp is worth.
    func testAnUnusedServiceIsGreyRatherThanRed() {
        let list = checks(WebSettings(sourceFolder: root.path))
        XCTAssertEqual(lamp(list, "jellyfin")?.state, .off)
    }

    func testJellyfinWithAnAddressButNoKeyIsAmber() {
        var settings = WebSettings(sourceFolder: root.path)
        settings.jellyfinBaseURL = "http://nas.local:8096"
        XCTAssertEqual(lamp(checks(settings), "jellyfin")?.state, .warning)
    }

    // MARK: Lamps a reader can act on

    /// A lamp may not tell the reader which key to press: one said "mit ←→
    /// umstellen", which was true in the terminal front-end and nonsense
    /// anywhere else. The terminal is gone; the rule stays, because the
    /// window's panel and its footer bar both render these same strings.
    func testNoLampTellsTheReaderToPressATerminalKey() {
        var settings = WebSettings(sourceFolder: root.path)
        settings.jellyfinBaseURL = "http://nas.local:8096"
        settings.moviesFolder = "/nowhere/at/all"
        for check in checks(settings, secrets: [.jellyfinToken]) {
            for key in ["←→", "⏎", "␣", "[t]", "[p]"] {
                XCTAssertFalse(check.detail.contains(key),
                               "\(check.id) names a key: \(check.detail)")
            }
        }
    }

    // MARK: A panel that does not lie

    /// A green lamp from this morning is not the same claim as one from a
    /// second ago. The date was recorded and never read, while the comment
    /// beside it said the panel reported it.
    func testAnOldGreenProbeIsAmberAndSaysHowOld() {
        var settings = WebSettings(sourceFolder: root.path)
        settings.jellyfinBaseURL = "http://nas.local:8096"
        let old = ProbeResult(ok: true, detail: "Antwortet.",
                              date: Date(timeIntervalSinceNow: -7200))
        let list = checks(settings, secrets: [.jellyfinToken], probes: [.jellyfin: old])
        XCTAssertEqual(lamp(list, "jellyfin")?.state, .warning,
                       "a two-hour-old success still reads as a live connection")
        XCTAssertTrue(lamp(list, "jellyfin")?.detail.contains("Std geprüft") ?? false,
                      lamp(list, "jellyfin")?.detail ?? "")
    }

    func testAFreshProbeIsGreenAndSaysSo() {
        var settings = WebSettings(sourceFolder: root.path)
        settings.jellyfinBaseURL = "http://nas.local:8096"
        let list = checks(settings, secrets: [.jellyfinToken],
                          probes: [.jellyfin: ProbeResult(ok: true, detail: "Antwortet.")])
        XCTAssertEqual(lamp(list, "jellyfin")?.state, .ok)
        XCTAssertTrue(lamp(list, "jellyfin")?.detail.contains("gerade geprüft") ?? false)
    }

    // MARK: Rolling it up

    func testTheWorstLampWins() {
        XCTAssertEqual(SystemChecks.worst([
            SystemCheck(id: "a", name: "A", state: .ok, detail: ""),
            SystemCheck(id: "b", name: "B", state: .warning, detail: ""),
            SystemCheck(id: "c", name: "C", state: .failed, detail: ""),
        ]), .failed)

        XCTAssertEqual(SystemChecks.worst([
            SystemCheck(id: "a", name: "A", state: .ok, detail: ""),
            SystemCheck(id: "b", name: "B", state: .warning, detail: ""),
        ]), .warning)

        XCTAssertEqual(SystemChecks.worst([]), .off)
    }

    /// Every lamp carries a word as well as a colour: about one man in
    /// twelve cannot tell the red one from the green one.
    func testEveryStateHasAWordAndEveryLampADetail() {
        for state in [SystemCheck.State.ok, .warning, .failed, .off] {
            XCTAssertFalse(state.word.isEmpty)
        }
        var settings = WebSettings(sourceFolder: root.path)
        settings.jellyfinBaseURL = "http://nas.local:8096"
        for check in checks(settings) {
            XCTAssertFalse(check.detail.isEmpty, "\(check.id) has no explanation")
            XCTAssertFalse(check.name.isEmpty)
        }
    }

    func testTheSummaryCountsOnlyWhatIsThere() {
        let summary = SystemChecks.summary([
            SystemCheck(id: "a", name: "A", state: .ok, detail: ""),
            SystemCheck(id: "b", name: "B", state: .ok, detail: ""),
            SystemCheck(id: "c", name: "C", state: .failed, detail: ""),
        ])
        XCTAssertEqual(summary, "2 bereit · 1 Problem")
    }

    // MARK: The schedule lamp

    /// The state worth a red lamp is the one that looks fine everywhere
    /// else: switched on in the settings, with nothing armed to run it. That
    /// was every restart, before the schedule was armed at startup, and the
    /// panel could not see it.
    func testAScheduleThatIsOnButNotRunningIsAProblem() {
        let check = SystemChecks.schedule(Schedule(isEnabled: true, hour: 3),
                                          nextRun: nil)
        XCTAssertEqual(check.state, .failed)
        XCTAssertTrue(check.detail.contains("l\u{00E4}uft aber nicht"), check.detail)
    }

    func testAnArmedScheduleSaysWhenItWillRun() {
        let check = SystemChecks.schedule(Schedule(isEnabled: true, hour: 3),
                                          nextRun: Date().addingTimeInterval(3600))
        XCTAssertEqual(check.state, .ok)
        XCTAssertTrue(check.detail.contains("N\u{00E4}chster Lauf"), check.detail)
    }

    /// Grey, not red: a schedule nobody asked for is not a fault.
    func testAScheduleThatIsOffIsGrey() {
        XCTAssertEqual(SystemChecks.schedule(Schedule(), nextRun: nil).state, .off)
    }

    /// An impossible time is a fault the user can fix, so the lamp carries
    /// the sentence that says how.
    func testAnImpossibleTimeIsReportedWithItsOwnMessage() {
        let check = SystemChecks.schedule(Schedule(isEnabled: true, hour: 25),
                                          nextRun: nil)
        XCTAssertEqual(check.state, .failed)
        XCTAssertTrue(check.detail.contains("00:00"), check.detail)
    }

    /// Every lamp has a word beside it, colour or no colour.
    func testTheScheduleLampHasAWordLikeEveryOther() {
        for state in [SystemCheck.State.ok, .warning, .failed, .off] {
            XCTAssertFalse(state.word.isEmpty)
        }
    }
}
