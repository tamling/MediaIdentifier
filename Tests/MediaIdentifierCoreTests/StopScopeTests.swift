import XCTest
@testable import MediaIdentifierCore

/// What the Stop button reaches.
///
/// The window lights Stop on `busy` alone, and five different things set
/// `busy`: the two scan commands, the watch poll, the scan after a download,
/// the scheduled run, and a rename. The flag it armed was maintained by the
/// two commands only. So on the other paths the button was lit, the press
/// was answered with "Es wird gerade nicht gesucht", and the run carried on
/// to the end — with every other button queued behind it.
///
/// The worst of them was the scheduled run: Stop said "Stoppt vor der
/// nächsten Datei", identification really was abandoned, and then every file
/// was moved into the library under a parse-only name, which is the one
/// outcome the press was meant to prevent.
final class StopScopeTests: XCTestCase {

    private var root: URL!
    private var config: URL!
    private var source: URL!
    private var library: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        Text.language = .german
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-stopscope-\(UUID().uuidString)")
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

    @discardableResult
    private func makeFile(_ name: String) throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func films(_ count: Int) throws {
        for index in 1...count { try makeFile("Film.20\(10 + index).1080p.mkv") }
    }

    private func configured(watching: Bool = false) -> WebSettings {
        var settings = WebSettings(sourceFolder: source.path)
        settings.moviesFolder = library.path
        settings.identification = .localLLM
        settings.localLLMBaseURL = "http://127.0.0.1:1"
        settings.localLLMModel = "test"
        settings.watchSourceFolder = watching
        return settings
    }

    private func makeCoordinator() -> AppCoordinator {
        let coordinator = AppCoordinator(configDirectory: config, lampInterval: 0)
        Text.language = .german
        return coordinator
    }

    private func importFolderCount() -> Int {
        ((try? fm.contentsOfDirectory(atPath: source.path)) ?? [])
            .filter { $0.hasSuffix(".mkv") }.count
    }

    // MARK: Stop reaches every scan path

    /// The watch poll. A torrent client drops forty episodes, the timer
    /// fires, and the window says "Identifying…" with Stop lit.
    func testStopReachesAScanStartedByTheWatchPoll() throws {
        let coordinator = makeCoordinator()
        // Settings first, then the files: the watcher offers what appeared
        // after it started looking, which is the whole point of it.
        coordinator.executeForTesting(.saveSettings(configured(watching: true)))
        try films(5)
        let attempts = Counter()
        coordinator.setEnrichmentProviderForTesting(
            StopPressingProvider(attempts: attempts) { coordinator.submit(.cancelScan) })

        // A file is offered once its size has been stable across two polls,
        // so that a download still being written is not picked up. The
        // second poll is the one that scans.
        coordinator.pollWatchFolderForTesting()
        coordinator.pollWatchFolderForTesting()

        XCTAssertEqual(attempts.value, 1,
                       "Stop did not stop the watch scan — it asked about "
                           + "\(attempts.value) files")
        let said = coordinator.snapshot.lastResult ?? ""
        XCTAssertFalse(said.contains("nicht gesucht"),
                       "Stop was pressed during a scan and answered: \(said)")
        XCTAssertTrue(said.contains("abgebrochen"), said)
    }

    /// The scheduled run, and the part that matters: the rename it was going
    /// to do afterwards does not happen either.
    func testStopDuringTheScheduledRunLeavesTheFilesWhereTheyAre() throws {
        try films(5)
        let coordinator = makeCoordinator()
        coordinator.executeForTesting(.saveSettings(configured()))
        let attempts = Counter()
        coordinator.setEnrichmentProviderForTesting(
            StopPressingProvider(attempts: attempts) { coordinator.submit(.cancelScan) })

        coordinator.performScheduledRun(
            Schedule(isEnabled: true, hour: 3, alsoRename: true))

        XCTAssertEqual(attempts.value, 1)
        XCTAssertEqual(importFolderCount(), 5,
                       "the unattended run renamed the files after the user "
                           + "had stopped it")
        let said = coordinator.snapshot.lastResult ?? ""
        XCTAssertTrue(said.contains("abgebrochen"), said)
    }

    /// And the stop does not leak into the next run, which is why it is
    /// cleared by whoever finishes last rather than by the command.
    func testAStopDoesNotSurviveIntoTheNextScan() throws {
        let coordinator = makeCoordinator()
        coordinator.executeForTesting(.saveSettings(configured(watching: true)))
        try films(3)
        let attempts = Counter()
        coordinator.setEnrichmentProviderForTesting(
            StopPressingProvider(attempts: attempts) { coordinator.submit(.cancelScan) })
        coordinator.pollWatchFolderForTesting()
        coordinator.pollWatchFolderForTesting()
        XCTAssertEqual(attempts.value, 1)

        // A second scan, nothing pressed.
        coordinator.setEnrichmentProviderForTesting(
            StopPressingProvider(attempts: Counter()) {})
        coordinator.executeForTesting(.scanSourceFolder)
        XCTAssertEqual(coordinator.items.count, 3,
                       "the previous stop killed the next scan")
    }

    // MARK: Stop reaches a rename

    /// Four hundred files moving to a NAS mount: Stop was lit throughout and
    /// answered that nothing was being searched.
    func testStopBeforeARenameStopsItAndTheFilesStay() throws {
        try films(5)
        let coordinator = makeCoordinator()
        var settings = configured()
        settings.identification = .offline
        coordinator.executeForTesting(.saveSettings(settings))
        coordinator.executeForTesting(.scanSourceFolder)
        XCTAssertEqual(coordinator.items.count, 5)

        // Pressed while the rename is still queued: before this was counted,
        // the press had no target and was thrown away.
        let release = DispatchSemaphore(value: 0)
        coordinator.blockQueueForTesting(until: release)
        coordinator.submit(.applyProposedRenames(accepting: nil))
        coordinator.submit(.cancelScan)
        let answer = coordinator.snapshot.lastResult ?? ""
        release.signal()
        coordinator.drainForTesting()

        XCTAssertFalse(answer.contains("nicht gesucht"),
                       "Stop with a rename in hand answered: \(answer)")
        XCTAssertEqual(importFolderCount(), 5,
                       "the rename went ahead after Stop")
        let said = coordinator.snapshot.lastResult ?? ""
        XCTAssertTrue(said.contains("gestoppt"), said)
        XCTAssertEqual(coordinator.items.count, 5,
                       "the files nobody touched were cleared out of the list")
    }

    /// The executor's own boundary rule, exercised directly: a stop lands
    /// between items, never between a film and its subtitle.
    func testAStopNeverTearsAReleaseInHalf() throws {
        for index in 1...4 {
            try makeFile("Film.20\(10 + index).1080p.mkv")
            _ = try makeFile("Film.20\(10 + index).1080p.en.srt")
        }
        let files = MediaScanner().scan(urls: [source])
        let plan = RenamePlanner().makePlan(for: files, outputRoot: library)
        XCTAssertEqual(plan.count, 4)
        let journal = RenameJournal(url: config.appendingPathComponent("j.json"))
        let executor = RenameExecutor(
            log: RenameLog(url: config.appendingPathComponent("l.json")),
            journal: journal)

        // Stop once the second film has moved.
        var moved = 0
        let outcome = executor.execute(plan: plan, policy: .skip, shouldStop: {
            moved += 1
            return moved > 2
        })

        XCTAssertTrue(outcome.stoppedEarly)
        XCTAssertEqual(outcome.landed.count, 2, "two releases should have gone")
        // Every film in the library has its subtitle beside it, and every
        // film still in Downloads has its subtitle there.
        for item in plan {
            let video = item.primaryDestination
            let subtitle = video.deletingPathExtension()
                .appendingPathExtension("en.srt")
            XCTAssertEqual(
                fm.fileExists(atPath: video.path),
                fm.fileExists(atPath: subtitle.path),
                "\(video.lastPathComponent) and its subtitle were separated")
        }
        XCTAssertEqual(journal.transactions.first?.moves.count, 4,
                       "two films and two subtitles should be recorded")
    }

    // MARK: Helpers

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() -> Int { lock.lock(); count += 1; let n = count; lock.unlock(); return n }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// Presses Stop from inside the first identification, which is what "the
    /// user pressed Stop while it was working on the first file" means — and
    /// needs no second thread to express.
    private struct StopPressingProvider: MetadataProvider, Sendable {
        let attempts: Counter
        let press: @Sendable () -> Void

        init(attempts: Counter, press: @escaping @Sendable () -> Void) {
            self.attempts = attempts
            self.press = press
        }

        func identify(_ parsed: ParsedRelease, at url: URL?) async throws
            -> MediaMetadata? {
            if attempts.bump() == 1 { press() }
            return MediaMetadata(title: "Identified", year: 1999,
                                 kind: .movie, source: "test")
        }
    }
}
