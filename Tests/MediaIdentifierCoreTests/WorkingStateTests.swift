import XCTest
@testable import MediaIdentifierCore

/// The gap between "a handler that reports progress is running" and "the user
/// asked for something and it has not finished".
///
/// `busy` is set only by the handlers that bother to. Four commands hold the
/// engine's serial queue without ever setting it, and the window keyed
/// everything on `busy` — so for as long as one of them ran, the header said
/// "Bereit" and every button stayed live. The dangerous one is Undo: a second
/// press during the first reverses a batch nobody asked to reverse, because
/// `finishUndo` has already dropped the transaction the first press worked
/// from.
final class WorkingStateTests: XCTestCase {

    /// The four commands that count as work and never set `busy`.
    ///
    /// Pinned as a list, because the gate the window now uses is only right
    /// while this list is: a fifth command that holds the queue without
    /// raising `busy` has to be counted as work or it reopens the hole.
    func testTheQueueHoldingCommandsCountAsWork() {
        for command in [WebCommand.undoLastRename,
                        .testLocalLLMConnection,
                        .testJellyfinConnection,
                        .checkEverything] {
            XCTAssertTrue(AppCoordinator.isWork(command),
                          "\(command) must raise the queue counter")
        }
    }

    /// And the ones that must not: a cancel has to get through while work is
    /// running, so it cannot itself count as work.
    func testCancellingIsNotWork() {
        for command in [WebCommand.cancelScan, .cancelConversions, .cancelDownload] {
            XCTAssertFalse(AppCoordinator.isWork(command),
                           "\(command) must not raise the queue counter, or a "
                               + "cancel would be gated behind the run it cancels")
        }
    }

    /// The predicate itself. `busy` false with something queued is exactly
    /// the state the window used to read as idle.
    func testQueuedWorkWithoutBusyStillCountsAsWorking() {
        var state = StatusSnapshot()
        state.busy = false
        state.queuedWork = 1

        XCTAssertTrue(state.isWorking,
                      "a command accepted but not finished is work")
        XCTAssertFalse(state.busy,
                       "and `busy` is false, which is the whole problem")
    }

    func testAnIdleSnapshotIsNotWorking() {
        let state = StatusSnapshot()
        XCTAssertFalse(state.isWorking)
    }

    /// The percentage is why the window needs a separate branch rather than
    /// swapping one flag for the other: during a probe `activePercent` falls
    /// back to `renameProgress`, which after a finished rename is 1. A naive
    /// one-word change would announce "Arbeitet · 100 %" of work that
    /// reports no progress at all.
    func testThePercentageIsMeaninglessWhileOnlyQueuedWorkIsRunning() {
        var state = StatusSnapshot()
        state.busy = false
        state.queuedWork = 1
        state.renameProgress = 1      // the last rename finished
        state.converting = false

        XCTAssertTrue(state.isWorking)
        XCTAssertEqual(state.activePercent, 100,
                       "which is why the window says no percentage here")
    }
}
