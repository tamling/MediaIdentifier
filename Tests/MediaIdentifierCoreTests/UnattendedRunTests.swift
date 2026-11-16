import XCTest
@testable import MediaIdentifierCore

/// What happens while nobody is watching.
///
/// Every test here pins a way the schedule used to be wrong rather than a
/// property of the design, because that is where this code failed: it was
/// never armed after a restart, it fired the moment Apply was pressed, and
/// "also send" sent exactly the files whose rename had failed. None of that
/// is visible from the outside — an unattended run that does the wrong thing
/// looks like an unattended run — so it has to be held down by tests.
final class UnattendedRunTests: XCTestCase {

    private var root: URL!
    private var config: URL!
    private var source: URL!
    private var movies: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mediafin-schedule-\(UUID().uuidString)")
        config = root.appendingPathComponent("config")
        source = root.appendingPathComponent("downloads")
        movies = root.appendingPathComponent("library/Movies")
        for directory in [config!, source!, movies!] {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        }
        // Last, after the coordinator exists: its init calls
        // Text.start from the settings it loads, which would
        // otherwise undo this.
        Text.language = .english
    }

    override func tearDownWithError() throws {
        Text.language = .german
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data("not really a video".utf8).write(to: url)
        return url
    }

    private func settings(_ schedule: Schedule,
                          movies moviesFolder: String? = nil) -> WebSettings {
        WebSettings(sourceFolder: source.path,
                    moviesFolder: moviesFolder ?? movies.path,
                    identification: .offline,
                    conflictPolicy: .rename,
                    schedule: schedule,
                    language: .english)
    }

    /// A day in the past, so a daily schedule is overdue.
    private var daysAgo: Date { Date().addingTimeInterval(-3 * 24 * 3600) }

    // MARK: Being armed at all

    /// The one that mattered most: `updateScheduleState` was only ever
    /// called from `save`, so the schedule ran in the session where the user
    /// pressed Apply and never again. On a media server that restarts, the
    /// nightly run simply stopped happening.
    func testAStoredScheduleIsArmedWhenTheProgramStarts() throws {
        let first = AppCoordinator(configDirectory: config)
        first.executeForTesting(.saveSettings(
            settings(Schedule(isEnabled: true, cadence: .daily, hour: 3))))
        XCTAssertTrue(first.scheduleIsArmedForTesting)

        let restarted = AppCoordinator(configDirectory: config)
        // Armed from the settings file alone, without anyone saving anything.
        XCTAssertTrue(restarted.scheduleIsArmedForTesting,
                      "the schedule was not armed at startup, so it would never "
                          + "have run again after a restart")
    }

    func testAScheduleThatIsOffIsNotArmed() {
        let coordinator = AppCoordinator(configDirectory: config)
        coordinator.executeForTesting(.saveSettings(settings(Schedule(isEnabled: false))))
        XCTAssertFalse(coordinator.scheduleIsArmedForTesting)
    }

    /// An impossible time is refused rather than run at some other hour.
    func testAScheduleWithAnImpossibleTimeIsNotArmed() {
        let coordinator = AppCoordinator(configDirectory: config)
        coordinator.executeForTesting(.saveSettings(
            settings(Schedule(isEnabled: true, hour: 25))))
        XCTAssertFalse(coordinator.scheduleIsArmedForTesting)
        XCTAssertNil(coordinator.snapshot.nextScheduledRun)
    }

    // MARK: Remembering across a restart

    func testTheLastRunSurvivesARestart() throws {
        let moment = Date(timeIntervalSince1970: 1_780_000_000)
        let store = ScheduleStateStore(directory: config)
        store.setLastRun(moment)

        let coordinator = AppCoordinator(configDirectory: config)
        coordinator.waitForStartupForTesting()
        XCTAssertEqual(coordinator.lastScheduledRun?.timeIntervalSince1970 ?? 0,
                       moment.timeIntervalSince1970, accuracy: 1,
                       "the last run was forgotten, so after every restart the "
                           + "program had no idea whether the nightly run had happened")
    }

    /// Nothing recorded is not the same as overdue: a first start must not
    /// set an unattended rename going.
    func testAFirstStartDoesNotCountAsOverdue() throws {
        _ = try makeFile("Some.Movie.2021.1080p.mkv")
        let coordinator = AppCoordinator(configDirectory: config)
        coordinator.executeForTesting(.saveSettings(
            settings(Schedule(isEnabled: true, hour: 3, alsoRename: true))))

        let fresh = AppCoordinator(configDirectory: config)
        fresh.runIfDueForTesting()
        XCTAssertEqual(try FileManager.default
            .contentsOfDirectory(atPath: movies.path), [],
                       "a restart renamed the library on its own")
    }

    /// A clock that was wrong when the file was written — a machine with no
    /// battery, booting at the epoch — must not leave every run overdue.
    func testAnEpochTimestampIsTreatedAsNoRecord() {
        let store = ScheduleStateStore(directory: config)
        store.setLastRun(Date(timeIntervalSince1970: 0))
        XCTAssertNil(store.lastRun())
    }

    // MARK: Pressing Apply

    /// Switching the schedule off and on again used to leave the old
    /// last-run time in place, so the next tick — twenty seconds later —
    /// found a run overdue and renamed the library while the user was still
    /// looking at the settings page.
    func testChangingTheScheduleDoesNotFireARunStraightAway() throws {
        _ = try makeFile("Another.Movie.2019.mkv")
        let coordinator = AppCoordinator(configDirectory: config)
        coordinator.executeForTesting(.saveSettings(
            settings(Schedule(isEnabled: true, hour: 3, alsoRename: true))))
        coordinator.setLastScheduledRunForTesting(daysAgo)

        // The user changes the time. That alone must not run anything.
        coordinator.executeForTesting(.saveSettings(
            settings(Schedule(isEnabled: true, hour: 4, alsoRename: true))))
        coordinator.runIfDueForTesting()

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: movies.path),
                       [], "pressing Apply set an unattended rename going")
    }

    /// The other half of that rule: saving something unrelated must not
    /// postpone a run that is already due. Saving the server address at
    /// 02:59 used to push tonight's 03:00 run to tomorrow.
    func testSavingAnUnrelatedSettingDoesNotPostponeADueRun() throws {
        let file = try makeFile("Third.Movie.2020.mkv")
        let coordinator = AppCoordinator(configDirectory: config)
        let schedule = Schedule(isEnabled: true, hour: 3, alsoRename: true)
        coordinator.executeForTesting(.saveSettings(settings(schedule)))

        // The run is overdue before the unrelated save, so the save is what
        // this test is about.
        coordinator.setLastScheduledRunForTesting(daysAgo)
        var other = settings(schedule)
        other.jellyfinBaseURL = "https://jellyfin.example:8920"
        coordinator.executeForTesting(.saveSettings(other))

        coordinator.runIfDueForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "the due run did not happen: " + (coordinator.snapshot.lastResult ?? "—"))
    }

    // MARK: What a run is allowed to do

    func testARunThatOnlyScansMovesNothing() throws {
        let file = try makeFile("Scan.Only.2018.mkv")
        let coordinator = AppCoordinator(configDirectory: config)
        coordinator.executeForTesting(.saveSettings(settings(Schedule(isEnabled: true))))
        coordinator.setLastScheduledRunForTesting(daysAgo)

        coordinator.runIfDueForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(coordinator.items.isEmpty, "the run did not even scan")
    }

    func testARunThatMayRenameDoesRename() throws {
        let file = try makeFile("Rename.Me.2017.1080p.mkv")
        let coordinator = AppCoordinator(configDirectory: config)
        coordinator.executeForTesting(.saveSettings(
            settings(Schedule(isEnabled: true, alsoRename: true))))
        coordinator.setLastScheduledRunForTesting(daysAgo)

        coordinator.runIfDueForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let landed = FileManager.default
            .enumerator(at: movies, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        XCTAssertTrue(landed.contains { $0.hasSuffix(".mkv") },
                      "nothing arrived in the library: \(landed)")
    }

    /// Without a library root the planner proposes a folder beside the file
    /// itself, so every unattended run buried it one level deeper:
    /// Film/Film.mkv, then Film/Film/Film.mkv. Nobody is watching, so the
    /// run refuses instead and says why.
    func testWithoutALibraryFolderAnUnattendedRunRefusesToRename() throws {
        let file = try makeFile("No.Root.2016.mkv")
        let coordinator = AppCoordinator(configDirectory: config)
        coordinator.executeForTesting(.saveSettings(
            settings(Schedule(isEnabled: true, alsoRename: true), movies: "")))
        coordinator.setLastScheduledRunForTesting(daysAgo)

        coordinator.runIfDueForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "the file was moved into a folder beside itself")
        let result = coordinator.snapshot.lastResult ?? ""
        XCTAssertTrue(result.contains("target folder"), result)
        XCTAssertTrue(coordinator.snapshot.hasError)
    }

    /// The rule on its own, without a scheduler: an episode needs the series
    /// folder and a film needs the films folder, not just any one of them.
    func testTheRuleIsPerKindOfFile() {
        func item(_ name: String, kind: MediaKind) -> RenameItem {
            let url = source.appendingPathComponent(name)
            var parsed = ParsedRelease(originalFileName: name, title: "T", kind: kind)
            parsed.season = 1
            parsed.episode = 1
            return RenameItem(mediaFile: MediaFile(url: url, parsed: parsed),
                              outputRoot: source, proposedRelativePath: name)
        }
        let plan = [item("film.mkv", kind: .movie), item("show.mkv", kind: .episode)]

        var onlyFilms = WebSettings(moviesFolder: movies.path)
        onlyFilms.seriesFolder = ""
        let split = AppCoordinator.unattendedRenameable(plan, settings: onlyFilms)
        XCTAssertEqual(split.renameable.map(\.originalFileName), ["film.mkv"])
        XCTAssertEqual(split.blocked.map(\.originalFileName), ["show.mkv"])
    }

    /// A scan that cannot run — the import folder unmounted overnight —
    /// leaves the previous plan in `items`. Acting on it would rename a list
    /// the user last saw hours ago, against a folder that has moved on.
    func testAFailedScanStopsTheRunRatherThanUsingTheOldPlan() throws {
        let file = try makeFile("Stale.Plan.2015.mkv")
        let coordinator = AppCoordinator(configDirectory: config)
        coordinator.executeForTesting(.saveSettings(
            settings(Schedule(isEnabled: true, alsoRename: true))))
        coordinator.executeForTesting(.scanSourceFolder)
        XCTAssertFalse(coordinator.items.isEmpty, "the plan was never built")

        // The folder goes away, but the file does not: it is still where the
        // old plan says it is, so a run working from that plan would move it.
        var gone = settings(Schedule(isEnabled: true, alsoRename: true))
        gone.sourceFolder = root.appendingPathComponent("not-mounted").path
        coordinator.executeForTesting(.saveSettings(gone))
        coordinator.setLastScheduledRunForTesting(daysAgo)

        coordinator.runIfDueForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "a stale plan was applied after the scan had failed")
    }

    // MARK: What the interface is told

    func testTheNextRunIsPublishedSoTheInterfaceCanShowIt() {
        let coordinator = AppCoordinator(configDirectory: config)
        coordinator.executeForTesting(.saveSettings(
            settings(Schedule(isEnabled: true, hour: 3))))
        let next = coordinator.snapshot.nextScheduledRun
        XCTAssertNotNil(next, "the page had nothing to show but the sentence")
        XCTAssertGreaterThan(next!, Date())
    }

    func testTheSentenceSaysBothWhatWasAskedForAndWhatWillHappen() {
        let schedule = Schedule(isEnabled: true, hour: 3)
        let armed = StatusSnapshot(nextScheduledRun: Date().addingTimeInterval(3600))
        XCTAssertTrue(ScheduleLine.describe(schedule, armed).contains("Next run"))

        // Set but not running: the one state the user has to be able to see.
        let idle = StatusSnapshot()
        XCTAssertTrue(ScheduleLine.describe(schedule, idle).contains("Not running"),
                      ScheduleLine.describe(schedule, idle))
    }

    // MARK: Reading a moment back

    func testAMomentIsWrittenTheWayAClockIsRead() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let now = formatter.date(from: "2026-06-10 22:00")!

        // Both languages: "heute" and "today" are separate strings and
        // either could be the one left behind.
        Text.language = .german
        XCTAssertEqual(Schedule.describe(formatter.date(from: "2026-06-10 23:30")!,
                                         now: now, calendar: calendar),
                       "heute 23:30")
        XCTAssertEqual(Schedule.describe(formatter.date(from: "2026-06-11 03:00")!,
                                         now: now, calendar: calendar),
                       "morgen 03:00")

        Text.language = .english
        XCTAssertEqual(Schedule.describe(formatter.date(from: "2026-06-10 23:30")!,
                                         now: now, calendar: calendar),
                       "today 23:30")
        XCTAssertEqual(Schedule.describe(formatter.date(from: "2026-06-11 03:00")!,
                                         now: now, calendar: calendar),
                       "tomorrow 03:00")
        // Day first in both, because a formatter on a server with no locale
        // set would otherwise produce an American date.
        XCTAssertEqual(Schedule.describe(formatter.date(from: "2026-06-14 03:00")!,
                                         now: now, calendar: calendar),
                       "14.06. 03:00")
    }

    // MARK: Two Mediafins at once

    /// The window and `mediafin` in a terminal share ~/.config/mediafin, and
    /// both arm the schedule at startup — so without a lock both would find
    /// the same run overdue and both would rename, the loser's moves failing
    /// against files the winner had already moved.
    func testOnlyOneProcessRunsTheSameJob() throws {
        let lockFile = config.appendingPathComponent("test.lock")
        var inner: Bool?
        let outer = RunLock.withLock(at: lockFile) {
            // Re-entered from the same process: flock is per open file
            // description, so a second `open` of the same path is a second
            // contender exactly as another process would be.
            inner = RunLock.withLock(at: lockFile) { }
        }
        XCTAssertTrue(outer)
        XCTAssertEqual(inner, false, "two runs of the same job were allowed at once")
    }

    /// And it has to be released, or the schedule fires once and never again.
    func testTheLockIsFreeAgainAfterwards() {
        let lockFile = config.appendingPathComponent("released.lock")
        XCTAssertTrue(RunLock.withLock(at: lockFile) { })
        XCTAssertTrue(RunLock.withLock(at: lockFile) { },
                      "the lock was not released, so nothing would ever run again")
    }

    /// A directory that cannot hold a lock file must not silently stop the
    /// schedule for ever: running unlocked is the lesser evil.
    func testAnUnusableLockPathStillRuns() {
        var ran = false
        let outcome = RunLock.withLock(at: URL(fileURLWithPath: "/proc/nowhere/x.lock")) {
            ran = true
        }
        XCTAssertTrue(outcome)
        XCTAssertTrue(ran)
    }
}
