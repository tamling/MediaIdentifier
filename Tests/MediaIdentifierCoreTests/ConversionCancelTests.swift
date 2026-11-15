import XCTest
@testable import MediaIdentifierCore

/// Cancelling a conversion run.
///
/// The queue is serial, so a convert command can wait behind a scan or a long
/// identification pass for many seconds, and a cancel pressed during that wait
/// arrives first. The run used to clear the cancel flag as its first act, so
/// that press was discarded and every ticked file was re-encoded — hours of
/// work the user had explicitly stopped, after the interface had confirmed it
/// was stopping.
///
/// The end-to-end path needs FFmpeg, which the test container does not have,
/// so these check the flag's own rules through the same public entry points a
/// request uses.
final class ConversionCancelTests: XCTestCase {

    private var root: URL!
    private var coordinator: AppCoordinator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mediafin-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"),
                                                withIntermediateDirectories: true)
        coordinator = AppCoordinator(configDirectory: root.appendingPathComponent("config"))
        // Last, after the coordinator exists: its init calls Text.start from
        // the settings it loads, which would otherwise undo this. These
        // tests assert the English wording and German is the default.
        Text.language = .english
    }

    override func tearDownWithError() throws {
        Text.language = .german
        coordinator = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    /// The regression test. The gate holds the queue so the convert command is
    /// provably still waiting when the cancel is submitted — the real-world
    /// ordering, made reproducible instead of raced for.
    func testACancelThatArrivesBeforeTheRunStartsIsKept() {
        let gate = DispatchSemaphore(value: 0)
        coordinator.blockQueueForTesting(until: gate)

        coordinator.submit(.convertFiles(accepting: [UUID()]))
        coordinator.submit(.cancelConversions)

        XCTAssertTrue(coordinator.cancelIsArmedForTesting,
                      "a cancel for a run that has not started yet must be remembered")
        XCTAssertEqual(coordinator.snapshot.lastResult, "Stopping before the next file.")

        gate.signal()
        coordinator.drainForTesting()
    }

    /// A press with nothing running and nothing queued must not linger and
    /// stop whatever the user asks for next.
    func testACancelWhileIdleIsNotRemembered() {
        coordinator.submit(.cancelConversions)

        XCTAssertFalse(coordinator.cancelIsArmedForTesting,
                       "an idle cancel must not carry over into the next run")
        XCTAssertEqual(coordinator.snapshot.lastResult, "Nothing is converting.")
    }

    /// Following on from the above: the next run really does proceed.
    func testARunAfterAnIdleCancelIsNotStopped() {
        coordinator.submit(.cancelConversions)
        coordinator.drainForTesting()

        coordinator.executeForTesting(.convertFiles(accepting: []))

        XCTAssertFalse(coordinator.cancelIsArmedForTesting)
        XCTAssertEqual(coordinator.snapshot.lastResult,
                       "No files were ticked, so nothing was converted.")
    }

    /// A run that ends without converting anything must still leave the flag
    /// clear, or the cancel would apply to the run after it.
    func testTheFlagIsClearedByARunThatFindsNothingToDo() {
        let gate = DispatchSemaphore(value: 0)
        coordinator.blockQueueForTesting(until: gate)
        coordinator.submit(.convertFiles(accepting: [UUID()]))
        coordinator.submit(.cancelConversions)
        XCTAssertTrue(coordinator.cancelIsArmedForTesting)

        gate.signal()
        coordinator.drainForTesting()

        XCTAssertFalse(coordinator.cancelIsArmedForTesting,
                       "the cancel was consumed by that run and must not outlive it")
    }

    /// Cancelling is handled off the serial queue on purpose: queued behind
    /// the run it is meant to stop, it could never arrive in time.
    func testCancelIsNotBlockedByABusyQueue() {
        let gate = DispatchSemaphore(value: 0)
        coordinator.blockQueueForTesting(until: gate)
        coordinator.submit(.convertFiles(accepting: [UUID()]))

        let answered = expectation(description: "cancel returned while the queue was blocked")
        DispatchQueue.global().async {
            self.coordinator.submit(.cancelConversions)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)

        gate.signal()
        coordinator.drainForTesting()
    }
}

/// What a stopped conversion does to the file it was working on.
///
/// With a stand-in for FFmpeg rather than the real one. The question is
/// what the `catch` in `convertFiles` makes of an encoder that was
/// terminated, and a script that reports it is up and then waits to be
/// killed makes that deterministic — where a real encode is a race against
/// how fast the machine is, and a slow enough encode to lose that race
/// takes minutes.
final class StoppedConversionTests: XCTestCase {

    private var root: URL!
    private var coordinator: AppCoordinator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mediafin-stopconv-\(UUID().uuidString)")
        for leaf in ["config", "movies"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(leaf),
                withIntermediateDirectories: true)
        }
        coordinator = AppCoordinator(configDirectory: root.appendingPathComponent("config"))
        Text.language = .english
    }

    override func tearDownWithError() throws {
        Text.language = .german
        coordinator = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    /// Pressing Stopp used to be reported as a failure of the file, and the
    /// file was dropped off the candidate list.
    ///
    /// `cancelConversions` terminates the encoder, so it exits non-zero and
    /// lands in the same `catch` a broken file would: `failed += 1`, a red
    /// `.failure` row in the history carrying an FFmpeg exit code,
    /// `hasError` set — which turns the header to "Mit Fehlern beendet" —
    /// and the file removed from `_convertible` by
    /// `pending.prefix(done + failed)`, although nothing whatever had been
    /// done to it. A user who stops a conversion was told their library had
    /// hit an error, and "some files failed" is the likeliest route to
    /// pressing Rückgängig.
    func testStoppingIsNotAFailureAndKeepsTheFileOnTheList() throws {
        let marker = root.appendingPathComponent("encoder-is-up")
        let fake = root.appendingPathComponent("slow-ffmpeg")
        // `exec`, not a plain `sleep`: the point is that the process the
        // coordinator holds is the one that blocks. A forked `sleep` would
        // inherit the pipes and outlive the SIGTERM sent to its shell, and
        // the run would never come back — which is what the first version
        // of this test did, for a reason that has nothing to do with the
        // program.
        try """
        #!/bin/sh
        # Stands in for FFmpeg: says it is up, then waits to be killed.
        touch "\(marker.path)"
        exec sleep 120
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: fake.path)

        let source = root.appendingPathComponent("movies/Long Film (2019).mkv")
        try Data(repeating: 0x21, count: 4096).write(to: source)

        var settings = coordinator.settings
        settings.moviesFolder = root.appendingPathComponent("movies").path
        settings.conversion.ffmpegPath = fake.path
        coordinator.executeForTesting(.saveSettings(settings))
        coordinator.executeForTesting(.findConvertible)

        let candidates = coordinator.convertible
        XCTAssertEqual(candidates.count, 1, "the test file should be the one candidate")
        let target = try XCTUnwrap(candidates.first)

        coordinator.submit(.convertFiles(accepting: [target.id]))

        // Wait for the encoder to actually be up, rather than guessing at a
        // sleep: a cancel that arrives before the run starts takes a
        // different path entirely, and that one already has its own test.
        let upBy = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker.path),
              Date() < upBy {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "the stand-in encoder never started")

        coordinator.submit(.cancelConversions)
        // Proof the cancel found the running process rather than merely
        // arming the flag for the next file: those are two different
        // sentences, and only one of them means the encoder was ended.
        XCTAssertEqual(coordinator.snapshot.lastResult,
                       "Stopping after the current file.")
        coordinator.drainForTesting()

        let result = coordinator.snapshot.lastResult ?? ""
        XCTAssertTrue(result.contains("Converted 0"),
                      "nothing finished, so the count has to say so: \(result)")
        XCTAssertTrue(result.contains("stopped early"),
                      "the run has to own up to being stopped: \(result)")
        XCTAssertFalse(coordinator.snapshot.hasError,
                       "stopping on purpose is not an error: \(result)")
        XCTAssertFalse(result.contains("failed"),
                       "a file the user stopped was never attempted, let "
                           + "alone failed: \(result)")
        XCTAssertEqual(coordinator.convertible.map(\.source.path),
                       [target.source.path],
                       "a stopped file was not touched, so it has to stay on "
                           + "the list — otherwise the user must search again "
                           + "to get back a file nothing happened to")
        XCTAssertFalse(coordinator.logEntries.contains { $0.status == .failure },
                       "no red row for a file nothing was done to")
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            ConversionOutput.destination(for: target.source,
                                         options: settings.conversion.options).path),
                       "the half-written output must be gone")
    }
}
