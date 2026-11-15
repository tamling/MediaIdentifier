import XCTest
@testable import MediaIdentifierCore

/// Two checks that were written, kept green, and could not run.
final class SilentFailureTests: XCTestCase {

    private var root: URL!
    private var config: URL!
    private var source: URL!
    private var library: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-silent-\(UUID().uuidString)")
        config = root.appendingPathComponent("config")
        source = root.appendingPathComponent("downloads")
        library = root.appendingPathComponent("films")
        for url in [config, source, library] {
            try fm.createDirectory(at: url!, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func configured() -> WebSettings {
        var settings = WebSettings(sourceFolder: source.path)
        settings.moviesFolder = library.path
        settings.identification = .offline
        return settings
    }

    // MARK: The history that cannot be written

    /// `RenameLog._lastWriteFailure` is set in its own catch ("Kept rather
    /// than swallowed") and was read in exactly one place: the coordinator's
    /// init, where it is nil by construction, because init only loads and
    /// nothing has written yet. So a config directory that had filled up
    /// swallowed a whole session's history — the window kept showing it,
    /// because `entries` is the in-memory array — and the next launch
    /// started empty with nothing ever saying why.
    ///
    /// A directory where the file has to be is the way to make every write
    /// fail without making anything else fail: the temporary file is
    /// written, and `rename(2)` onto a non-empty directory refuses. A mode
    /// of 0000 would prove nothing, because CI runs as root and root ignores
    /// the mode bits.
    func testARenameWhoseHistoryCannotBeWrittenSaysSo() throws {
        let inTheWay = config.appendingPathComponent("rename-log.json")
        try fm.createDirectory(at: inTheWay, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: inTheWay.appendingPathComponent("keep"))

        let coordinator = AppCoordinator(configDirectory: config, lampInterval: 0)
        Text.language = .german
        for index in 1...3 {
            try Data("x".utf8).write(
                to: source.appendingPathComponent("Film.20\(10 + index).1080p.mkv"))
        }
        coordinator.executeForTesting(.saveSettings(configured()))
        coordinator.executeForTesting(.scanSourceFolder)
        coordinator.executeForTesting(.applyProposedRenames(accepting: nil))

        // The files really did move: this is about the record, not the work.
        XCTAssertEqual(coordinator.logEntries.filter { $0.status == .success }.count, 3)
        let said = coordinator.snapshot.lastResult ?? ""
        XCTAssertTrue(said.contains("Verlauf konnte nicht geschrieben werden"),
                      "nothing said the history was lost: \(said)")
        XCTAssertTrue(coordinator.snapshot.hasError)
    }

    /// And it says nothing when the history writes fine — a warning that
    /// appears every time is not a warning.
    func testAnOrdinaryRenameSaysNothingAboutTheHistory() throws {
        let coordinator = AppCoordinator(configDirectory: config, lampInterval: 0)
        Text.language = .german
        try Data("x".utf8).write(
            to: source.appendingPathComponent("Film.2011.1080p.mkv"))
        coordinator.executeForTesting(.saveSettings(configured()))
        coordinator.executeForTesting(.scanSourceFolder)
        coordinator.executeForTesting(.applyProposedRenames(accepting: nil))

        let said = coordinator.snapshot.lastResult ?? ""
        XCTAssertFalse(said.contains("Verlauf konnte nicht"), said)
        XCTAssertFalse(coordinator.snapshot.hasError, said)
    }

    // MARK: Two rips of one film

    /// The preview must say so, because the apply step certainly will.
    ///
    /// `makePlan` ran its duplicate detection over destinations rooted at
    /// each file's OWN parent directory, because outputRoot was nil, and
    /// `videoProposals` then replaced every root and called `reconcile` —
    /// which refreshes only `.existingFile` and says outright that "batch
    /// duplicate detection is left to makePlan", the pass that had just run
    /// on the paths that were thrown away. So two rips of one film in
    /// separate release folders came up as two clean proposals, both ticked;
    /// pressing Umbenennen then refused the pair and named them, with
    /// nothing having warned beforehand. The drop path and the music path
    /// both re-detect; only the video scan did not, under a comment claiming
    /// it was covered.
    func testTwoRipsOfOneFilmAreFlaggedByAScan() throws {
        for (folder, name) in [("Tenet.2020.1080p-GRP", "Tenet.2020.1080p.mkv"),
                               ("Tenet.2020.2160p-OTHER", "Tenet.2020.2160p.mkv")] {
            let directory = source.appendingPathComponent(folder)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: directory.appendingPathComponent(name))
        }
        let coordinator = AppCoordinator(configDirectory: config, lampInterval: 0)
        Text.language = .german
        coordinator.executeForTesting(.saveSettings(configured()))

        coordinator.executeForTesting(.scanSourceFolder)

        XCTAssertEqual(coordinator.items.count, 2)
        // Both land on <Movies>/Tenet (2020)/Tenet (2020).mkv.
        XCTAssertEqual(Set(coordinator.items.map {
            $0.primaryDestination.standardizedFileURL.path
        }).count, 1, "the two rips do not actually collide, so this proves nothing")
        for item in coordinator.items {
            XCTAssertEqual(item.conflict, .duplicateInBatch,
                           "\(item.originalFileName) came up as a clean proposal")
        }
    }

    /// And a scan of files that do not collide must stay clean, or every
    /// row would carry a warning and the badge would mean nothing.
    func testAnOrdinaryScanFlagsNothing() throws {
        for name in ["Tenet.2020.1080p.mkv", "Arrival.2016.1080p.mkv"] {
            try Data("x".utf8).write(to: source.appendingPathComponent(name))
        }
        let coordinator = AppCoordinator(configDirectory: config, lampInterval: 0)
        Text.language = .german
        coordinator.executeForTesting(.saveSettings(configured()))

        coordinator.executeForTesting(.scanSourceFolder)

        XCTAssertEqual(coordinator.items.count, 2)
        XCTAssertTrue(coordinator.items.allSatisfy { $0.conflict == nil },
                      "a clean scan flagged a conflict")
    }

    // MARK: "Alles prüfen"

    /// `record` stores a probe and queues the lamp refresh onto another
    /// queue, and that refresh starts with bounded filesystem probes — so
    /// the summary was built from the lamp array as it stood before the
    /// button was pressed. With a model server that had just refused the
    /// connection, `hasError` came out false and the header subtitle stayed
    /// on "Bereit"; the lamp went red a moment later, so the panel and the
    /// answer to the button disagreed.
    ///
    /// And the summary replaced the probe's own sentence, which is the only
    /// place the reason appears.
    func testCheckEverythingReportsTheProbeItJustRan() throws {
        let coordinator = AppCoordinator(configDirectory: config, lampInterval: 0)
        Text.language = .german
        var settings = configured()
        settings.identification = .localLLM
        // Port 1: refused at once, no timeout to wait for.
        settings.localLLMBaseURL = "http://127.0.0.1:1"
        settings.localLLMModel = "test"
        coordinator.executeForTesting(.saveSettings(settings))

        coordinator.executeForTesting(.checkEverything)

        let said = coordinator.snapshot.lastResult ?? ""
        XCTAssertTrue(said.contains("Prüfung fertig"), said)
        XCTAssertTrue(coordinator.snapshot.hasError,
                      "the check came back clean with a server that refused the "
                          + "connection: \(said)")
        XCTAssertTrue(said.contains("Modellserver"),
                      "the answer to the button does not say what is wrong: \(said)")
        // And the lamp the summary counted is the one the probe just set.
        let lamp = try XCTUnwrap(
            coordinator.systemChecks.first { $0.id == "identification" })
        XCTAssertEqual(lamp.state, .failed, lamp.detail)
    }

    func testCheckEverythingIsCleanWhenThereIsNothingToProbe() {
        let coordinator = AppCoordinator(configDirectory: config, lampInterval: 0)
        Text.language = .german
        coordinator.executeForTesting(.saveSettings(configured()))

        coordinator.executeForTesting(.checkEverything)

        XCTAssertFalse(coordinator.snapshot.hasError,
                       coordinator.snapshot.lastResult ?? "")
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("Prüfung fertig"))
    }
}
