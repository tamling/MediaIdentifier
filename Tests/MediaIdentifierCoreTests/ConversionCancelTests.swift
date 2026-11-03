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
    }

    override func tearDownWithError() throws {
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
