import XCTest
@testable import MediaIdentifierCore

/// Stopping a scan, and the scan giving up on a server that has gone quiet.
///
/// Identification is one blocking HTTP round trip per file, in order, on the
/// serial queue. With a model server that has stopped answering, each file
/// costs its 30-second timeout — so two thousand files is sixteen hours
/// during which every other button is queued behind it and does nothing.
/// There was no way to stop it and no point at which it gave up.
final class ScanCancelTests: XCTestCase {

    private var root: URL!
    private var config: URL!
    private var source: URL!
    private var library: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        Text.language = .german
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-scancancel-\(UUID().uuidString)")
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

    private func configured() -> WebSettings {
        var settings = WebSettings(sourceFolder: source.path)
        settings.moviesFolder = library.path
        settings.identification = .offline
        return settings
    }

    private func makeCoordinator() -> AppCoordinator {
        // No lamp timer: a timer firing mid-test is noise, not a test.
        let coordinator = AppCoordinator(configDirectory: config, lampInterval: 0)
        // After construction, not before. The coordinator's init calls
        // Text.start, which follows the environment whenever the stored
        // settings name no language — and CI's environment is English. A
        // setUp that pins the language before this is overruled by it, which
        // is how three of these tests first failed against English strings.
        Text.language = .german
        return coordinator
    }

    // MARK: Stopping one

    /// A cancel that arrives while the scan is still waiting its turn must
    /// not be lost. That is why the flag is not cleared when a run starts —
    /// the conversion path learned it the hard way.
    func testACancelWhileTheScanIsStillQueuedStopsIt() throws {
        for index in 1...5 { try makeFile("Film.20\(10 + index).1080p.mkv") }
        let coordinator = makeCoordinator()
        coordinator.executeForTesting(.saveSettings(configured()))

        let release = DispatchSemaphore(value: 0)
        coordinator.blockQueueForTesting(until: release)
        coordinator.submit(.scanSourceFolder)
        coordinator.submit(.cancelScan)
        release.signal()
        coordinator.drainForTesting()

        let said = coordinator.snapshot.lastResult ?? ""
        XCTAssertTrue(said.contains("abgebrochen"),
                      "a cancel queued behind the scan was lost: \(said)")
    }

    /// With nothing running, the press says so instead of arming a flag that
    /// would silently kill the next scan the user asks for.
    func testACancelWithNothingRunningIsSaidAndNotStored() throws {
        try makeFile("Film.2011.1080p.mkv")
        let coordinator = makeCoordinator()
        coordinator.executeForTesting(.saveSettings(configured()))

        coordinator.submit(.cancelScan)
        coordinator.drainForTesting()
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("nicht gesucht"),
                      coordinator.snapshot.lastResult ?? "nil")

        // And the next scan still happens.
        coordinator.executeForTesting(.scanSourceFolder)
        XCTAssertEqual(coordinator.items.count, 1,
                       "a stray cancel killed the next scan")
    }

    /// Cancelling is not work: it must not queue behind the run it exists to
    /// stop, and it must not be counted as pending work.
    func testCancellingIsNotWork() {
        XCTAssertFalse(AppCoordinator.isWork(.cancelScan))
    }

    // MARK: Giving up on a server that has gone quiet

    /// Three tries into nothing is information. Two thousand are not.
    func testIdentificationGivesUpAfterThreeSilentReplies() throws {
        for index in 1...8 { try makeFile("Film.20\(10 + index).1080p.mkv") }
        let attempts = Counter()
        let provider = CountingProvider(attempts: attempts, answer: nil)

        let coordinator = makeCoordinator()
        var settings = configured()
        settings.identification = .localLLM
        settings.localLLMBaseURL = "http://127.0.0.1:1"
        settings.localLLMModel = "test"
        coordinator.executeForTesting(.saveSettings(settings))
        coordinator.setEnrichmentProviderForTesting(provider)

        coordinator.executeForTesting(.scanSourceFolder)

        XCTAssertEqual(attempts.value, AppCoordinator.identificationGiveUpAfter,
                       "it kept asking a server that had answered nothing "
                           + "\(AppCoordinator.identificationGiveUpAfter) times")
        // Every file still gets a proposal, from its own name.
        XCTAssertEqual(coordinator.items.count, 8,
                       "giving up on identification dropped the files as well")
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("antwortet nicht"),
                      coordinator.snapshot.lastResult ?? "nil")
    }

    /// A server that answers must not be given up on. The counter resets.
    func testAServerThatAnswersIsAskedAboutEveryFile() throws {
        for index in 1...6 { try makeFile("Film.20\(10 + index).1080p.mkv") }
        let attempts = Counter()
        let provider = CountingProvider(
            attempts: attempts,
            answer: MediaMetadata(title: "Identified", year: 1999,
                                  kind: .movie, source: "test"))

        let coordinator = makeCoordinator()
        var settings = configured()
        settings.identification = .localLLM
        settings.localLLMBaseURL = "http://127.0.0.1:1"
        settings.localLLMModel = "test"
        coordinator.executeForTesting(.saveSettings(settings))
        coordinator.setEnrichmentProviderForTesting(provider)

        coordinator.executeForTesting(.scanSourceFolder)

        XCTAssertEqual(attempts.value, 6, "it stopped asking a server that was working")
    }

    /// Alternating failures must not accumulate: three in a row is the rule,
    /// not three in total.
    func testFailuresMustBeConsecutiveToCountAsGivingUp() throws {
        for index in 1...8 { try makeFile("Film.20\(10 + index).1080p.mkv") }
        let attempts = Counter()
        let provider = CountingProvider(
            attempts: attempts,
            answer: MediaMetadata(title: "Identified", year: 1999,
                                  kind: .movie, source: "test"),
            failEvery: 2)

        let coordinator = makeCoordinator()
        var settings = configured()
        settings.identification = .localLLM
        settings.localLLMBaseURL = "http://127.0.0.1:1"
        settings.localLLMModel = "test"
        coordinator.executeForTesting(.saveSettings(settings))
        coordinator.setEnrichmentProviderForTesting(provider)

        coordinator.executeForTesting(.scanSourceFolder)

        XCTAssertEqual(attempts.value, 8,
                       "every other failure was treated as a run of failures")
    }

    // MARK: Helpers

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() -> Int { lock.lock(); count += 1; let n = count; lock.unlock(); return n }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// Counts how often it is asked and answers as told, so the test can say
    /// "a server that has gone quiet" without one.
    private struct CountingProvider: MetadataProvider, Sendable {
        let attempts: Counter
        let answer: MediaMetadata?
        /// When set, every nth call fails and the others succeed.
        var failEvery: Int?

        func identify(_ parsed: ParsedRelease, at url: URL?) async throws -> MediaMetadata? {
            let n = attempts.bump()
            if let failEvery, n % failEvery == 0 { return nil }
            return answer
        }
    }
}
