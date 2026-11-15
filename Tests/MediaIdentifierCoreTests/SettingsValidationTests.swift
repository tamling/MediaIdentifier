import XCTest
@testable import MediaIdentifierCore

/// The rules that existed and never ran.
///
/// `WebSettings.problems()` and `isValid` had no caller anywhere in the
/// program. Three test files covered them, so "the folder must be an
/// absolute path", "must not contain '..'", "the address must look like
/// http://host:port" and "the time must be between 00:00 and 23:59" were all
/// green in CI — and two comments in the program described the checking as
/// something that happened.
///
/// What it cost: `settings.json` is the only way to configure the headless
/// service, and `"moviesFolder": "~/Filme"` was accepted and used as the
/// move root. `URL(fileURLWithPath:)` resolves that against the process's
/// working directory, which for the packaged unit is `/`, so every rename
/// failed on a path the user never typed. Under the window, started from
/// $HOME, it instead created a directory literally called `~` and filed the
/// library inside it — after which the folder lamp went green on it.
final class SettingsValidationTests: XCTestCase {

    private var root: URL!
    private var config: URL!
    private var source: URL!
    private var coordinator: AppCoordinator!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-validate-\(UUID().uuidString)")
        config = root.appendingPathComponent("config")
        source = root.appendingPathComponent("downloads")
        for url in [config, source] {
            try fm.createDirectory(at: url!, withIntermediateDirectories: true)
        }
        coordinator = AppCoordinator(configDirectory: config, lampInterval: 0)
        Text.language = .german
    }

    override func tearDownWithError() throws {
        coordinator = nil
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func valid() -> WebSettings {
        var settings = WebSettings(sourceFolder: source.path)
        settings.moviesFolder = root.appendingPathComponent("Filme").path
        settings.identification = .offline
        return settings
    }

    // MARK: Saving

    func testARelativeLibraryPathIsRefusedAndSaidOutLoud() {
        var settings = valid()
        settings.moviesFolder = "~/Filme"

        coordinator.executeForTesting(.saveSettings(settings))

        let said = coordinator.snapshot.lastResult ?? ""
        XCTAssertTrue(said.contains("Nicht gespeichert"), said)
        XCTAssertTrue(said.contains("absoluter Pfad"), said)
        XCTAssertTrue(coordinator.snapshot.hasError)
        XCTAssertNotEqual(coordinator.settings.moviesFolder, "~/Filme",
                          "a relative path was adopted as the library root")
    }

    func testAPathWithADoubleDotIsRefused() {
        var settings = valid()
        settings.seriesFolder = "/srv/media/../../etc"

        coordinator.executeForTesting(.saveSettings(settings))

        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("Nicht gespeichert"),
                      coordinator.snapshot.lastResult ?? "nil")
        XCTAssertEqual(coordinator.settings.seriesFolder, "")
    }

    /// The GUI-reachable one: the time box takes "9" and the window's own
    /// reader stores hour = -1 on purpose, for the validation to catch.
    /// Nothing caught it, the save said "Übernommen", and the nightly run
    /// simply stopped happening.
    func testAScheduleTimeThatCannotExistIsRefused() {
        var settings = valid()
        settings.schedule = Schedule(isEnabled: true, hour: -1, minute: 30)

        coordinator.executeForTesting(.saveSettings(settings))

        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("Nicht gespeichert"),
                      coordinator.snapshot.lastResult ?? "nil")
        XCTAssertFalse(coordinator.isScheduleArmedForTesting,
                       "a schedule that cannot run was armed")
    }

    func testAModelServerAddressThatIsNotAnAddressIsRefused() {
        var settings = valid()
        settings.identification = .localLLM
        settings.localLLMBaseURL = "192.168.3.116:1234"
        settings.localLLMModel = "qwen"

        coordinator.executeForTesting(.saveSettings(settings))

        let said = coordinator.snapshot.lastResult ?? ""
        XCTAssertTrue(said.contains("Nicht gespeichert"), said)
        XCTAssertTrue(said.contains("http://host:port"), said)
    }

    /// And the ordinary case still saves, or the whole program is bricked.
    func testGoodSettingsStillSave() {
        coordinator.executeForTesting(.saveSettings(valid()))
        XCTAssertEqual(coordinator.settings.sourceFolder, source.path)
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("gespeichert"),
                      coordinator.snapshot.lastResult ?? "nil")
        XCTAssertFalse(coordinator.snapshot.hasError)
    }

    /// An empty form is not a complaint: this is what a first run looks like.
    func testAnEmptyFormIsNotRefused() {
        coordinator.executeForTesting(.saveSettings(WebSettings()))
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("gespeichert"),
                      coordinator.snapshot.lastResult ?? "nil")
    }

    // MARK: A hand-written settings.json

    func testASettingsFileWithARelativeLibraryPathIsReported() throws {
        try Data("""
            {"sourceFolder":"/srv/downloads","moviesFolder":"~/Filme",
             "seriesFolder":"Serien","identification":"offline","language":"de"}
            """.utf8)
            .write(to: config.appendingPathComponent("settings.json"))

        let reopened = AppCoordinator(configDirectory: config, lampInterval: 0)
        Text.language = .german

        let problem = try XCTUnwrap(reopened.settingsProblem,
                                    "a settings file with a relative move root "
                                        + "loaded without a word")
        XCTAssertTrue(problem.contains("absolut"), problem)
    }

    func testTheLampSaysSoRatherThanOnlyAFieldNobodyReads() throws {
        var settings = valid()
        settings.moviesFolder = "Filme"
        let checks = SystemChecks.all(settings: settings, ffmpegAvailable: true,
                                      secrets: [], probes: [:])
        let lamp = try XCTUnwrap(checks.first { $0.id == "settings" },
                                 "there is no settings lamp on the panel")
        XCTAssertEqual(lamp.state, .failed)
        XCTAssertTrue(lamp.detail.contains("absolut"), lamp.detail)
    }

    func testTheLampIsGreyWithNothingEnteredAndGreenWhenItIsFine() throws {
        let empty = SystemChecks.all(settings: WebSettings(), ffmpegAvailable: true,
                                     secrets: [], probes: [:])
        XCTAssertEqual(empty.first { $0.id == "settings" }?.state, .off,
                       "a green lamp for a question nobody asked")

        let good = SystemChecks.all(settings: valid(), ffmpegAvailable: true,
                                    secrets: [], probes: [:])
        XCTAssertEqual(good.first { $0.id == "settings" }?.state, .ok)
    }

    // MARK: Trimming

    /// Three of the four folder paths were trimmed and this one was not.
    func testTheMusicFolderIsTrimmedLikeTheOthers() {
        var settings = WebSettings()
        settings.sourceFolder = "  /srv/downloads  "
        settings.musicFolder = "  /srv/music  "
        let normalised = settings.normalised()
        XCTAssertEqual(normalised.sourceFolder, "/srv/downloads")
        XCTAssertEqual(normalised.musicFolder, "/srv/music")
    }
}
