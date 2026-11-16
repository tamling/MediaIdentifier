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

        // The run is over, so the engine has to read as idle again.
        //
        // It did not. The stop leaves the `for` loop through a `break`,
        // which jumps over the one line that cleared `_runningConversion`,
        // and the run's tail never cleared it either. `cancelConversions`
        // reads that pointer to decide whether there is anything to stop,
        // so every later press while idle armed the flag against a dead
        // process and answered "Stoppt nach der aktuellen Datei." with
        // nothing running -- and the next conversion the user asked for
        // died on its first file. Self-perpetuating, too: that run breaks
        // before FFmpeg starts, so nothing ever overwrote the pointer.
        coordinator.submit(.cancelConversions)
        XCTAssertEqual(coordinator.snapshot.lastResult, "Nothing is converting.",
                       "with the run finished there is nothing left to stop")
        XCTAssertFalse(coordinator.cancelIsArmedForTesting,
                       "a press while idle must not arm the flag against the "
                           + "next run the user asks for")

        // And the proof that it matters: the next run has to reach the
        // encoder. The marker is deleted first, so its reappearance can
        // only come from a second launch.
        try FileManager.default.removeItem(at: marker)
        coordinator.submit(.convertFiles(accepting: [target.id]))
        let upAgainBy = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker.path),
              Date() < upAgainBy {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "the conversion after a stopped one never started its "
                          + "encoder: \(coordinator.snapshot.lastResult ?? "")")
        coordinator.submit(.cancelConversions)
        coordinator.drainForTesting()
    }

    /// A run in which the encode fails has to say so, and leave the file
    /// alone.
    ///
    /// The panel in front of the main window worked out what had happened
    /// from "the candidate list went empty", and the engine emptied it for
    /// failures exactly as for successes -- so a run in which every single
    /// file failed and nothing whatever was written announced "Fertig. Die
    /// neuen Dateien liegen neben den Originalen; zu konvertieren ist
    /// nichts mehr da." The one sentence saying otherwise was on the window
    /// behind the panel. The files were gone from the list too, so there
    /// was nothing to retry.
    func testAFailedFileStaysOnTheListAndTheRunSaysSo() throws {
        let fake = root.appendingPathComponent("broken-ffmpeg")
        try [
            "#!/bin/sh",
            "# Stands in for FFmpeg refusing the file.",
            "echo \"Invalid data found when processing input\" >&2",
            "exit 1",
        ].joined(separator: "\n").write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: fake.path)

        let source = root.appendingPathComponent("movies/Broken (2021).mkv")
        try Data(repeating: 0x21, count: 4096).write(to: source)

        var settings = coordinator.settings
        settings.moviesFolder = root.appendingPathComponent("movies").path
        settings.conversion.ffmpegPath = fake.path
        coordinator.executeForTesting(.saveSettings(settings))
        coordinator.executeForTesting(.findConvertible)
        let target = try XCTUnwrap(coordinator.convertible.first)

        coordinator.submit(.convertFiles(accepting: [target.id]))
        coordinator.drainForTesting()

        let run = coordinator.snapshot.convertRun
        XCTAssertEqual(run.converted, 0, "nothing was written")
        XCTAssertEqual(run.failed, 1, "and the run has to own the failure")
        XCTAssertFalse(run.stopped, "nobody stopped it")
        XCTAssertTrue(coordinator.snapshot.hasError)
        XCTAssertEqual(coordinator.convertible.map(\.source.path),
                       [target.source.path],
                       "a file the program failed to convert is exactly as "
                           + "convertible as before, so it stays offered -- "
                           + "otherwise the user has to search the whole "
                           + "library again for a file nothing happened to")
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            ConversionOutput.destination(for: target.source,
                                         options: settings.conversion.options).path),
                       "no half-written output may be left behind")
    }

    /// The search says whether it looked, so the panel does not have to
    /// guess from the queue going quiet.
    func testARefusedSearchIsReportedAsARefusal() throws {
        var settings = coordinator.settings
        settings.moviesFolder = ""
        settings.seriesFolder = ""
        settings.sourceFolder = ""
        coordinator.executeForTesting(.saveSettings(settings))

        let before = coordinator.snapshot.convertSearch.generation
        coordinator.executeForTesting(.findConvertible)
        let after = coordinator.snapshot.convertSearch

        XCTAssertEqual(after.generation, before + 1,
                       "a refusal is an answer, so the panel has to be able "
                           + "to see that one arrived")
        XCTAssertTrue(after.refused,
                      "with no library folder the engine never looked, and "
                          + "\"found nothing\" would be a different claim")
        XCTAssertEqual(after.found, 0)
    }

    /// And a search that really looked reports that instead.
    func testASearchThatLooksReportsWhatItFound() throws {
        let source = root.appendingPathComponent("movies/Film (2020).mkv")
        try Data(repeating: 0x21, count: 2048).write(to: source)
        var settings = coordinator.settings
        settings.moviesFolder = root.appendingPathComponent("movies").path
        coordinator.executeForTesting(.saveSettings(settings))

        let before = coordinator.snapshot.convertSearch.generation
        coordinator.executeForTesting(.findConvertible)
        let after = coordinator.snapshot.convertSearch

        XCTAssertEqual(after.generation, before + 1)
        XCTAssertFalse(after.refused)
        XCTAssertEqual(after.found, 1)
    }

    /// Stopp during the walk for convertible files.
    ///
    /// The walk sets `busy` and nothing else, and the one Stopp outside the
    /// menu is sensitive on bare `busy` -- so the button was lit for the
    /// whole walk and pressing it answered "Es wird gerade nicht gesucht."
    /// while the bar advanced, because `cancelScan`'s target test covered
    /// scans and renames only. Nothing could act on the walk at all. That
    /// is verbatim the fault `stopScan`'s dispatcher says it fixed, for the
    /// one busy-setter it has no branch for.
    func testStoppDuringTheConvertibleSearchHasSomethingToStop() throws {
        let movies = root.appendingPathComponent("movies")
        for i in 1...40 {
            try Data(repeating: 0x21, count: 512).write(
                to: movies.appendingPathComponent("Film \(i) (2020).mkv"))
        }
        var settings = coordinator.settings
        settings.moviesFolder = movies.path
        coordinator.executeForTesting(.saveSettings(settings))

        // The press has to land while the walk is running, so the walk is
        // held on the queue and the cancel is sent first -- the same
        // reproducible ordering ConversionCancelTests uses.
        let gate = DispatchSemaphore(value: 0)
        coordinator.blockQueueForTesting(until: gate)
        coordinator.submit(.findConvertible)
        coordinator.submit(.cancelScan)

        XCTAssertEqual(coordinator.snapshot.lastResult,
                       "Stopping before the next file.",
                       "a Stopp with a search queued has something to stop; "
                           + "it used to answer \"Nothing is being searched.\" "
                           + "with the bar moving")
        gate.signal()
        coordinator.drainForTesting()

        let report = coordinator.snapshot.convertSearch
        XCTAssertTrue(report.stopped,
                      "the walk has to own up to having been stopped")
        XCTAssertFalse(report.refused)
        let result = coordinator.snapshot.lastResult ?? ""
        XCTAssertTrue(result.contains("stopped"),
                      "and say so where the user is looking: \(result)")
        XCTAssertFalse(result.contains("No files to convert were found"),
                       "\"nothing found\" is a claim about a library this "
                           + "walk never finished reading: \(result)")
        // And the flag does not carry over into the next search.
        coordinator.executeForTesting(.findConvertible)
        XCTAssertFalse(coordinator.snapshot.convertSearch.stopped,
                       "a stop must not stop the search after it")
        XCTAssertEqual(coordinator.convertible.count, 40,
                       "the search after a stopped one has to finish")
    }
}
