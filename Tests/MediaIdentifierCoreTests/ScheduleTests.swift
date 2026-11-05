import XCTest
@testable import MediaIdentifierCore

/// Working out when the next unattended run is due.
///
/// Dates are where this kind of code goes wrong, and it goes wrong rarely
/// enough that nobody notices for months: a run skipped on the morning the
/// clocks change, an interval that drifts a little later every time, a
/// schedule that fires the moment it is switched on. Each of those has a
/// test here, with a fixed calendar so they mean the same thing wherever
/// the suite runs.
final class ScheduleTests: XCTestCase {

    /// Berlin, because it is the user's zone and it has the awkward
    /// spring-forward morning this needs.
    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = berlin
        formatter.timeZone = berlin.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func text(_ moment: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = berlin
        formatter.timeZone = berlin.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: moment)
    }

    // MARK: Daily

    func testADailyRunIsDueTheSameDayWhenTheTimeHasNotPassed() {
        let schedule = Schedule(isEnabled: true, cadence: .daily, hour: 3, minute: 0)
        let next = schedule.nextRun(after: date("2026-06-10 01:00"), calendar: berlin)
        XCTAssertEqual(text(next!), "2026-06-10 03:00")
    }

    /// The case that is wrong in most hand-written versions: at 04:00 the
    /// next 03:00 is tomorrow, not a moment in the past.
    func testADailyRunRollsToTomorrowOnceTheTimeHasPassed() {
        let schedule = Schedule(isEnabled: true, cadence: .daily, hour: 3, minute: 0)
        let next = schedule.nextRun(after: date("2026-06-10 04:00"), calendar: berlin)
        XCTAssertEqual(text(next!), "2026-06-11 03:00")
    }

    func testExactlyOnTheMinuteCountsAsPassed() {
        let schedule = Schedule(isEnabled: true, cadence: .daily, hour: 3, minute: 0)
        let next = schedule.nextRun(after: date("2026-06-10 03:00"), calendar: berlin)
        XCTAssertEqual(text(next!), "2026-06-11 03:00",
                       "the run just happened; the next one is tomorrow")
    }

    /// On 29 March 2026 the clocks go forward at 02:00, so 02:30 does not
    /// exist. The run must happen anyway rather than being skipped for a
    /// day — a backup that silently misses the night of a time change is
    /// a backup nobody can rely on.
    func testARunInTheHourThatDoesNotExistStillHappens() {
        let schedule = Schedule(isEnabled: true, cadence: .daily, hour: 2, minute: 30)
        let next = schedule.nextRun(after: date("2026-03-29 00:30"), calendar: berlin)
        XCTAssertNotNil(next)
        // Whatever the calendar picks, it must be that morning and not a
        // day later.
        XCTAssertTrue(text(next!).hasPrefix("2026-03-29"), text(next!))
    }

    /// 25 October 2026: 02:30 happens twice. One run, not two.
    func testARepeatedHourDoesNotRunTwice() {
        let schedule = Schedule(isEnabled: true, cadence: .daily, hour: 2, minute: 30)
        let first = schedule.nextRun(after: date("2026-10-25 00:30"), calendar: berlin)!
        let second = schedule.nextRun(after: first, calendar: berlin)!
        XCTAssertGreaterThan(second.timeIntervalSince(first), 20 * 3600,
                             "the next run came less than a day later: \(text(first)) "
                                 + "then \(text(second))")
    }

    // MARK: Every few hours

    /// Anchored to the clock, not to the previous run, so a run that takes
    /// twenty minutes does not push every later one twenty minutes on.
    func testAnIntervalDoesNotDriftWhenARunTakesTime() {
        let schedule = Schedule(isEnabled: true, cadence: .everyFewHours, everyHours: 6)
        let first = schedule.nextRun(after: date("2026-06-10 01:00"), calendar: berlin)!
        // The run finished twenty minutes after it started.
        let second = schedule.nextRun(after: first.addingTimeInterval(20 * 60),
                                      calendar: berlin)!
        XCTAssertEqual(second.timeIntervalSince(first), 6 * 3600,
                       "the interval drifted: \(text(first)) then \(text(second))")
    }

    func testEveryHourIsAllowed() {
        let schedule = Schedule(isEnabled: true, cadence: .everyFewHours, everyHours: 1)
        let first = schedule.nextRun(after: date("2026-06-10 01:10"), calendar: berlin)!
        XCTAssertEqual(text(first), "2026-06-10 02:00")
    }

    // MARK: Refusing nonsense

    func testAnImpossibleTimeProducesNoRunAndAComplaint() {
        let schedule = Schedule(isEnabled: true, cadence: .daily, hour: 25, minute: 0)
        XCTAssertNil(schedule.nextRun(after: Date(), calendar: berlin))
        XCTAssertTrue(schedule.problems().contains { $0.field == "scheduleTime" })
    }

    func testAnImpossibleIntervalProducesNoRunAndAComplaint() {
        let schedule = Schedule(isEnabled: true, cadence: .everyFewHours, everyHours: 0)
        XCTAssertNil(schedule.nextRun(after: Date(), calendar: berlin))
        XCTAssertTrue(schedule.problems().contains { $0.field == "scheduleEveryHours" })
    }

    func testASwitchedOffScheduleNeverRuns() {
        let schedule = Schedule(isEnabled: false, cadence: .daily, hour: 3)
        XCTAssertNil(schedule.nextRun(after: Date(), calendar: berlin))
        XCTAssertFalse(schedule.isDue(at: Date(), lastRun: Date(timeIntervalSince1970: 0),
                                      calendar: berlin))
        XCTAssertTrue(schedule.problems().isEmpty, "a disabled schedule must not complain")
    }

    // MARK: Being due

    /// Switching the schedule on must not immediately fire a run the user
    /// did not ask for.
    func testTurningItOnDoesNotFireStraightAway() {
        let schedule = Schedule(isEnabled: true, cadence: .daily, hour: 3)
        XCTAssertFalse(schedule.isDue(at: date("2026-06-10 04:00"), lastRun: nil,
                                      calendar: berlin))
    }

    func testARunIsDueOnceItsTimeHasCome() {
        let schedule = Schedule(isEnabled: true, cadence: .daily, hour: 3)
        let yesterday = date("2026-06-09 03:00")
        XCTAssertFalse(schedule.isDue(at: date("2026-06-10 02:59"), lastRun: yesterday,
                                      calendar: berlin))
        XCTAssertTrue(schedule.isDue(at: date("2026-06-10 03:00"), lastRun: yesterday,
                                     calendar: berlin))
    }

    /// A machine that was asleep for three days runs once on waking, not
    /// three times.
    func testALongGapProducesOneRunAndNotABacklog() {
        let schedule = Schedule(isEnabled: true, cadence: .daily, hour: 3)
        let lastRun = date("2026-06-07 03:00")
        XCTAssertTrue(schedule.isDue(at: date("2026-06-10 09:00"), lastRun: lastRun,
                                     calendar: berlin))
        // After it runs, the next is tomorrow — not a catch-up queue.
        let next = schedule.nextRun(after: date("2026-06-10 09:00"), calendar: berlin)!
        XCTAssertEqual(text(next), "2026-06-11 03:00")
    }

    // MARK: What it says it will do

    /// A schedule the user cannot read back is one they cannot tell is
    /// wrong.
    /// The language is global and these assert German, so it is said out
    /// loud rather than relied on: another test class setting English and
    /// failing to put it back would otherwise fail this one, somewhere else
    /// entirely.
    override func setUp() {
        super.setUp()
        Text.language = .german
    }

    func testTheSummarySaysWhatWillHappen() {
        var schedule = Schedule(isEnabled: true, cadence: .daily, hour: 3, minute: 5)
        XCTAssertTrue(schedule.summary.contains("03:05"), schedule.summary)
        XCTAssertTrue(schedule.summary.contains("durchsuchen"))
        XCTAssertFalse(schedule.summary.contains("umbenennen"),
                       "renaming is off and must not be promised")

        schedule.alsoRename = true
        schedule.alsoSend = true
        XCTAssertTrue(schedule.summary.contains("umbenennen"))
        XCTAssertTrue(schedule.summary.contains("Server"))

        schedule.isEnabled = false
        XCTAssertTrue(schedule.summary.lowercased().contains("aus"), schedule.summary)
    }

    /// The same sentence in the other language, which is the only way to
    /// notice that half of it was left untranslated: `summary` is built from
    /// five separate pieces and any one of them could still be German.
    func testTheSummaryIsSaidInEnglishToo() {
        Text.language = .english
        defer { Text.language = .german }

        var schedule = Schedule(isEnabled: true, cadence: .daily, hour: 3, minute: 5)
        XCTAssertEqual(schedule.summary, "Daily at 03:05: look through.")

        schedule.alsoRename = true
        schedule.alsoSend = true
        XCTAssertEqual(schedule.summary,
                       "Daily at 03:05: look through, rename, send to the server.")

        schedule.cadence = .everyFewHours
        schedule.everyHours = 6
        XCTAssertEqual(schedule.summary,
                       "Every 6 hours: look through, rename, send to the server.")

        schedule.isEnabled = false
        XCTAssertEqual(schedule.summary, "Off — nothing runs by itself.")
    }

    /// Both off by default, and separately: an unattended run that only
    /// proposes is what most people mean by "check overnight".
    func testNothingIsActedOnUnlessAskedFor() {
        let schedule = Schedule()
        XCTAssertFalse(schedule.isEnabled)
        XCTAssertFalse(schedule.alsoRename)
        XCTAssertFalse(schedule.alsoSend)
    }

    // MARK: Reading the form

    /// Unticking a checkbox sends nothing, so the hidden companion is
    /// what tells "unticked" from "not in this form".
    func testTheCheckboxesNeedTheirCompanionField() {
        let on = Schedule(isEnabled: true, alsoRename: true, alsoSend: true)
        XCTAssertTrue(Schedule.fromForm([:], current: on).isEnabled,
                      "a form without the section wiped the schedule")

        let off = Schedule.fromForm(["schedulePresent": "1"], current: on)
        XCTAssertFalse(off.isEnabled)
        XCTAssertFalse(off.alsoRename)
        XCTAssertFalse(off.alsoSend)
    }

    func testATimeIsReadFromTheForm() {
        let schedule = Schedule.fromForm(["scheduleTime": "04:30"], current: Schedule())
        XCTAssertEqual(schedule.hour, 4)
        XCTAssertEqual(schedule.minute, 30)
    }

    /// A time that is not a time must not quietly become another hour:
    /// the program would then run at 00:00 and the user would never know
    /// why. It is kept impossible so the validation can say so.
    func testSomethingThatIsNotATimeIsReportedRatherThanGuessed() {
        for typed in ["morgens", "25:00", "4"] {
            var schedule = Schedule.fromForm(["scheduleTime": typed], current: Schedule())
            schedule.isEnabled = true
            XCTAssertFalse(schedule.problems().isEmpty,
                           "\(typed) was accepted as a time")
        }
    }

    func testAnEmptyTimeFieldLeavesTheStoredOne() {
        let stored = Schedule(hour: 3, minute: 15)
        let schedule = Schedule.fromForm(["scheduleTime": ""], current: stored)
        XCTAssertEqual(schedule.hour, 3)
        XCTAssertEqual(schedule.minute, 15)
    }

    // MARK: Settings file

    func testAnOlderSettingsFileStillLoads() throws {
        let json = #"{"isEnabled":true,"hour":4}"#
        let schedule = try JSONDecoder().decode(Schedule.self, from: Data(json.utf8))
        XCTAssertTrue(schedule.isEnabled)
        XCTAssertEqual(schedule.hour, 4)
        XCTAssertEqual(schedule.cadence, .daily, "a missing field takes its default")
        XCTAssertFalse(schedule.alsoRename)
    }
}
