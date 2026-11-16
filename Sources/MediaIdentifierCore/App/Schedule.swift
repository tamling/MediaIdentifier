import Foundation

/// When Mediafin should look by itself, and how far it may go.
///
/// Not a cron expression. Five fields of asterisks are a language, and a
/// language needs a parser, an error message for every way of writing it
/// wrong, and a user who knows it. "Every day at 03:00" and "every few
/// hours" are what a media library actually wants, and both can be stated
/// in a sentence the interface can show back.
public struct Schedule: Codable, Sendable, Equatable {

    public enum Cadence: String, Codable, Sendable, CaseIterable {
        case daily
        case everyFewHours

        public var label: String {
            switch self {
            case .daily: return Text.s("Jeden Tag zu einer festen Uhrzeit",
                                       "Every day at a fixed time")
            case .everyFewHours: return Text.s("Alle paar Stunden", "Every few hours")
            }
        }
    }

    public var isEnabled: Bool
    public var cadence: Cadence
    /// For `.daily`.
    public var hour: Int
    public var minute: Int
    /// For `.everyFewHours`.
    public var everyHours: Int

    /// Whether an unattended run may rename, and whether it may send.
    ///
    /// Both off by default, and separately. A scheduled run that only
    /// scans leaves a list for the user to look at, which is what most
    /// people want from "check overnight"; a run that renames and sends
    /// while nobody is watching is a different proposition and should be
    /// asked for on purpose.
    public var alsoRename: Bool

    public init(isEnabled: Bool = false,
                cadence: Cadence = .daily,
                hour: Int = 3,
                minute: Int = 0,
                everyHours: Int = 6,
                alsoRename: Bool = false) {
        self.isEnabled = isEnabled
        self.cadence = cadence
        self.hour = hour
        self.minute = minute
        self.everyHours = everyHours
        self.alsoRename = alsoRename
    }

    /// Every field optional on the way in, so a settings file written
    /// before this existed still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Schedule()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        self.init(
            isEnabled: value(.isEnabled, defaults.isEnabled),
            cadence: value(.cadence, defaults.cadence),
            hour: value(.hour, defaults.hour),
            minute: value(.minute, defaults.minute),
            everyHours: value(.everyHours, defaults.everyHours),
            alsoRename: value(.alsoRename, defaults.alsoRename)
        )
    }

    /// Reads the form, keeping anything it does not carry.
    public static func fromForm(_ fields: [String: String],
                                current: Schedule) -> Schedule {
        var schedule = current
        // Checkboxes send nothing when unticked, so a hidden companion
        // says the section was part of this form at all.
        if fields["schedulePresent"] != nil {
            schedule.isEnabled = fields["scheduleEnabled"] != nil
            schedule.alsoRename = fields["scheduleRename"] != nil
        }
        if let value = fields["scheduleCadence"], let cadence = Cadence(rawValue: value) {
            schedule.cadence = cadence
        }
        if let value = fields["scheduleTime"] {
            let parts = value.split(separator: ":", maxSplits: 1)
            // Kept as typed when it is not a time: problems() then says
            // so, rather than a silent fallback to some other hour.
            if parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) {
                schedule.hour = hour
                schedule.minute = minute
            } else if !value.trimmingCharacters(in: .whitespaces).isEmpty {
                schedule.hour = -1
            }
        }
        if let value = fields["scheduleEveryHours"] {
            schedule.everyHours = Int(value.trimmingCharacters(in: .whitespaces)) ?? -1
        }
        return schedule
    }

    public func problems() -> [WebSettings.Problem] {
        guard isEnabled else { return [] }
        var found: [WebSettings.Problem] = []
        if !(0...23).contains(hour) || !(0...59).contains(minute) {
            found.append(.init(field: "scheduleTime",
                               message: Text.s(
                                "Die Uhrzeit muss zwischen 00:00 und 23:59 liegen.",
                                "The time must be between 00:00 and 23:59.")))
        }
        if cadence == .everyFewHours, !(1...24).contains(everyHours) {
            found.append(.init(field: "scheduleEveryHours",
                               message: Text.s(
                                "Der Abstand muss zwischen 1 und 24 Stunden liegen.",
                                "The interval must be between 1 and 24 hours.")))
        }
        return found
    }

    /// A sentence saying what will happen, for the interface to show back.
    ///
    /// Worth having: a schedule the user cannot read back is a schedule
    /// they cannot tell is wrong.
    public var summary: String {
        guard isEnabled else {
            return Text.s("Aus — es läuft nichts von selbst.",
                          "Off — nothing runs by itself.")
        }
        let when: String
        switch cadence {
        case .daily:
            when = Text.s(String(format: "täglich um %02d:%02d", hour, minute),
                          String(format: "daily at %02d:%02d", hour, minute))
        case .everyFewHours:
            when = everyHours == 1
                ? Text.s("jede Stunde", "every hour")
                : Text.s("alle \(everyHours) Stunden", "every \(everyHours) hours")
        }
        var what = Text.s("durchsuchen", "look through")
        if alsoRename { what += Text.s(", umbenennen", ", rename") }
        return "\(when.prefix(1).uppercased())\(when.dropFirst()): \(what)."
    }

    /// A moment, written the way a person reads a clock.
    ///
    /// Shared by both front-ends so they cannot drift apart, and given its
    /// `now` and calendar so "heute" can be tested rather than only seen.
    ///
    /// `DateComponents` and `String(format:)` rather than a `DateFormatter`,
    /// for two reasons. A formatter's `dateStyle` on a server with no locale
    /// set produces American month-first dates in a German interface. And a
    /// formatter is expensive to build and unsafe to share: the GTK window
    /// calls this twice a second on the main thread while the web server
    /// calls it from its own, so a cached one would be a data race and an
    /// uncached one four allocations a second. A `Calendar` is a value, so
    /// neither applies.
    public static func describe(_ moment: Date,
                                now: Date = Date(),
                                calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: moment)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)

        if calendar.isDate(moment, inSameDayAs: now) {
            return Text.s("heute \(time)", "today \(time)")
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(moment, inSameDayAs: tomorrow) {
            return Text.s("morgen \(time)", "tomorrow \(time)")
        }

        return String(format: "%02d.%02d. ", parts.day ?? 0, parts.month ?? 0) + time
    }

    // MARK: When next

    /// The next moment this should run, strictly after `after`.
    ///
    /// Pure, and given its calendar, so the awkward cases can be tested
    /// rather than hoped about: the daily time having already passed
    /// today, a run that lands in the hour a clock goes forward, and an
    /// interval that must not drift later every time it fires.
    public func nextRun(after moment: Date, calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }
        switch cadence {
        case .daily:
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            var components = DateComponents()
            components.hour = hour
            components.minute = minute
            components.second = 0
            // matchingPolicy .nextTime: on the morning a clock jumps
            // forward, 02:30 does not exist and the run happens at the
            // next time that does, rather than being skipped for a day.
            return calendar.nextDate(after: moment, matching: components,
                                     matchingPolicy: .nextTime,
                                     direction: .forward)
        case .everyFewHours:
            guard (1...24).contains(everyHours) else { return nil }
            // Anchored to the top of the hour rather than to the last run,
            // so a run that takes twenty minutes does not push every
            // following one twenty minutes later for ever.
            let hoursSinceEpoch = Int(moment.timeIntervalSince1970 / 3600)
            let nextSlot = ((hoursSinceEpoch / everyHours) + 1) * everyHours
            return Date(timeIntervalSince1970: TimeInterval(nextSlot * 3600))
        }
    }

    /// Whether a run is due, given when one last happened.
    ///
    /// `lastRun` nil means none ever has, and the first due moment is
    /// computed from now — so switching the schedule on does not
    /// immediately fire a run the user did not ask for.
    public func isDue(at moment: Date, lastRun: Date?, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }
        guard let lastRun else { return false }
        guard let next = nextRun(after: lastRun, calendar: calendar) else { return false }
        return moment >= next
    }
}

/// The two lines the interface shows about the schedule: what was asked for,
/// and what will actually happen.
///
/// In Core and not in either front-end, because both show it and they must
/// not drift apart — and because the interesting case, a schedule that is
/// set but is not running, is worth a test of its own rather than something
/// only visible by looking at a window.
public enum ScheduleLine {
    public static func describe(_ schedule: Schedule, _ state: StatusSnapshot) -> String {
        guard schedule.isEnabled else { return schedule.summary }
        guard let next = state.nextScheduledRun else {
            return schedule.summary + "\n" + Text.s(
                "L\u{00E4}uft gerade nicht \u{2014} \u{201A}Speichern\u{2018} schaltet ihn wieder scharf.",
                "Not running \u{2014} \u{2018}Save\u{2019} arms it again.")
        }
        var line = schedule.summary + "\n"
            + Text.s("N\u{00E4}chster Lauf: ", "Next run: ") + Schedule.describe(next) + "."
        if let last = state.lastScheduledRun {
            line += Text.s(" Zuletzt: ", " Last: ") + Schedule.describe(last) + "."
        }
        return line
    }
}
