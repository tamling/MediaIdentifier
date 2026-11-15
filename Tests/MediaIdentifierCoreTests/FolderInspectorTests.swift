import XCTest
@testable import MediaIdentifierCore

/// The window froze when a network mount went away.
///
/// `refresh()` ran on the GTK drawing thread every 500 ms and worked out the
/// lamps, which meant `stat` on every configured folder. On a dead CIFS
/// mount `stat` blocks until the kernel gives up — sixty seconds a call, by
/// default — so the window stopped painting, stopped accepting clicks, and
/// stopped being a way to reach the setting that would have fixed the path.
///
/// These tests are about the thing that must never happen again: a caller
/// waiting on a folder.
final class FolderInspectorTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        Text.language = .german
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-folders-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: Measuring

    func testARealFolderIsMeasuredCorrectly() {
        let facts = FolderFacts.measured(root.path)
        XCTAssertTrue(facts.exists)
        XCTAssertTrue(facts.isDirectory)
        XCTAssertTrue(facts.isWritable)
        XCTAssertFalse(facts.timedOut)
    }

    func testAFileIsNotAFolderAndNothingIsThereIsNeither() throws {
        let file = root.appendingPathComponent("x.mkv")
        try Data("x".utf8).write(to: file)
        let asFile = FolderFacts.measured(file.path)
        XCTAssertTrue(asFile.exists)
        XCTAssertFalse(asFile.isDirectory)

        let absent = FolderFacts.measured(root.appendingPathComponent("nope").path)
        XCTAssertFalse(absent.exists)
        XCTAssertFalse(absent.timedOut)
    }

    // MARK: The wait, bounded

    /// The whole point. A probe that never returns must not hold the caller
    /// for longer than the deadline.
    func testAProbeThatNeverReturnsDoesNotHoldTheCaller() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let inspector = FolderInspector(deadline: 0.2) { _ in
            entered.signal()
            // Exactly what a dead mount does: sits in the syscall.
            release.wait()
            return FolderFacts(exists: true, isDirectory: true, isWritable: true)
        }

        let started = Date()
        let facts = inspector.facts(for: ["/mnt/gone"])
        let waited = Date().timeIntervalSince(started)

        XCTAssertLessThan(waited, 2.0,
                          "the caller waited \(waited)s on a folder that never answered")
        XCTAssertEqual(facts["/mnt/gone"], .unreachable)
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success,
                       "the probe was never even started")
        release.signal()
    }

    /// Asked again while the first probe is still out, it answers at once
    /// instead of starting a second one and waiting again.
    func testASecondCallWhileStuckReturnsImmediately() {
        let release = DispatchSemaphore(value: 0)
        let probes = Counter()
        let inspector = FolderInspector(deadline: 0.2) { _ in
            probes.bump()
            release.wait()
            return FolderFacts(exists: true)
        }

        _ = inspector.facts(for: ["/mnt/gone"])
        let started = Date()
        for _ in 0..<5 { _ = inspector.facts(for: ["/mnt/gone"]) }
        let waited = Date().timeIntervalSince(started)

        XCTAssertLessThan(waited, 0.2,
                          "five more calls cost \(waited)s; they should cost nothing")
        XCTAssertEqual(probes.value, 1, "a second probe was started for a stuck path")
        release.signal()
    }

    /// A dead mount must not make a healthy local folder unknown. That is
    /// why each path is its own work item.
    func testOneStuckFolderDoesNotTarTheOthers() {
        let release = DispatchSemaphore(value: 0)
        let good = root.path
        let inspector = FolderInspector(deadline: 0.5) { path in
            if path == "/mnt/gone" {
                release.wait()
                return FolderFacts()
            }
            return FolderFacts.measured(path)
        }

        let facts = inspector.facts(for: ["/mnt/gone", good])

        XCTAssertEqual(facts["/mnt/gone"], .unreachable)
        XCTAssertEqual(facts[good]?.isWritable, true,
                       "a working folder was reported unreachable because another hung")
        release.signal()
    }

    /// It heals. The mount comes back, the stuck stat returns, and the next
    /// call gets the truth.
    ///
    /// Only the FIRST probe blocks. A later call starting a fresh probe is
    /// the design, not a bug — it is how a mount coming back is noticed at
    /// all — so a test whose probe blocks every time proves the opposite of
    /// what it set out to. Mine did, and the build said so.
    func testItRecoversOnceTheProbeComesBack() throws {
        let stuck = DispatchSemaphore(value: 0)
        let calls = Counter()
        let inspector = FolderInspector(deadline: 0.2) { _ in
            if calls.bump() == 1 { stuck.wait() }
            return FolderFacts(exists: true, isDirectory: true, isWritable: true)
        }

        XCTAssertEqual(inspector.facts(for: ["/mnt/slow"])["/mnt/slow"], .unreachable,
                       "the first call did not time out, so nothing is being tested")
        // The mount answers at last.
        stuck.signal()

        // The work item lands on its own thread; wait for the cache rather
        // than for a fixed time.
        let deadline = Date().addingTimeInterval(3)
        while inspector.cachedFactsForTesting(for: "/mnt/slow") == nil, Date() < deadline {
            usleep(10_000)
        }
        XCTAssertEqual(inspector.cachedFactsForTesting(for: "/mnt/slow")?.exists, true,
                       "the answer that did arrive never reached the cache")
        XCTAssertEqual(inspector.facts(for: ["/mnt/slow"])["/mnt/slow"]?.exists, true,
                       "a fresh probe after recovery still read as unreachable")
    }

    /// A path nobody has measured reads as unreachable, not as absent and
    /// not as fine: the honest answer to "can I use this right now".
    func testAnUnmeasuredPathIsUnreachableRatherThanAssumedGood() {
        let inspector = FolderInspector(deadline: 0.05) { _ in
            Thread.sleep(forTimeInterval: 5)
            return FolderFacts(exists: true)
        }
        XCTAssertEqual(inspector.facts(for: ["/mnt/x"])["/mnt/x"]?.timedOut, true)
    }

    // MARK: The lamp that comes out of it

    /// Distinct from "does not exist": the drive IS mounted, it is not
    /// answering, and no setting fixes that.
    func testAnUnreachableFolderGetsItsOwnSentence() {
        let lamp = SystemChecks.folder(id: "source", name: "Importordner",
                                       path: "/mnt/gone",
                                       missingDetail: "kein Ordner gewählt",
                                       facts: .unreachable)
        XCTAssertEqual(lamp.state, .failed)
        XCTAssertTrue(lamp.detail.contains("antwortet nicht"), lamp.detail)
        XCTAssertFalse(lamp.detail.contains("gibt es nicht"),
                       "it confused 'not mounted' with 'not answering'")
    }

    /// No entry at all is the same situation as a timeout. It must not read
    /// as green, which is the panel lying about a folder that went away.
    func testAMissingEntryIsNotGreen() {
        let lamp = SystemChecks.folder(id: "movies", name: "Filme",
                                       path: "/mnt/unknown",
                                       missingDetail: "kein Ordner gewählt",
                                       facts: nil)
        XCTAssertEqual(lamp.state, .failed)
    }

    /// An empty path is still "nothing chosen", not "unreachable": that is a
    /// setting, not a fault.
    func testAnEmptyPathIsStillTheMissingSetting() {
        let lamp = SystemChecks.folder(id: "movies", name: "Filme", path: "",
                                       missingDetail: "kein Ordner gewählt",
                                       missingState: .warning, facts: nil)
        XCTAssertEqual(lamp.state, .warning)
        XCTAssertEqual(lamp.detail, "kein Ordner gewählt")
    }

    // MARK: Nothing in the panel touches the disk any more

    /// SystemChecks.all used to take a FileManager and use it. The window's
    /// drawing timer was the caller. This fixes that it takes values only:
    /// if this stops compiling because a FileManager came back, that is the
    /// freeze coming back with it.
    func testThePanelIsProducedFromValuesAlone() {
        var settings = WebSettings(sourceFolder: "/mnt/gone")
        settings.moviesFolder = "/mnt/also-gone"
        let list = SystemChecks.all(
            settings: settings,
            ffmpegAvailable: false,
            secrets: [],
            probes: [:],
            folders: ["/mnt/gone": .unreachable,
                      "/mnt/also-gone": FolderFacts(exists: true, isDirectory: true,
                                                     isWritable: true)],
            now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(list.first { $0.id == "source" }?.state, .failed)
        XCTAssertEqual(list.first { $0.id == "movies" }?.state, .ok)
    }

    /// And the coordinator hands the window a stored answer rather than
    /// measuring on demand: reading the lamps must cost nothing, however
    /// dead the mount is.
    func testReadingTheLampsFromTheCoordinatorDoesNotMeasureAnything() throws {
        let config = root.appendingPathComponent("config")
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        let release = DispatchSemaphore(value: 0)
        let probes = Counter()
        let inspector = FolderInspector(deadline: 0.2) { _ in
            probes.bump()
            release.wait()
            return FolderFacts(exists: true)
        }
        // lampInterval 0: no timer, so this test measures only what it asks for.
        let coordinator = AppCoordinator(configDirectory: config,
                                         lampInterval: 0,
                                         folderInspector: inspector)
        var settings = WebSettings(sourceFolder: "/mnt/gone")
        settings.identification = .offline
        coordinator.executeForTesting(.saveSettings(settings))

        // One measurement, which is the one place the waiting is allowed to
        // happen. Without this the test would pass on an empty cache and
        // prove nothing at all.
        coordinator.refreshSystemChecksForTesting()
        XCTAssertFalse(coordinator.systemChecks.isEmpty, "no lamps were produced")

        let started = Date()
        for _ in 0..<50 { _ = coordinator.systemChecks }
        let waited = Date().timeIntervalSince(started)

        XCTAssertLessThan(waited, 0.5,
                          "fifty reads of the lamps cost \(waited)s — they are still "
                              + "measuring the filesystem")
        XCTAssertEqual(probes.value, 1,
                       "fifty-one accesses produced \(probes.value) probes")
        release.signal()
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        @discardableResult
        func bump() -> Int {
            lock.lock(); count += 1; let now = count; lock.unlock(); return now
        }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
