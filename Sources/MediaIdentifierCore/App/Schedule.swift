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
            case .daily: return "Jeden Tag zu einer festen Uhrzeit"
            case .everyFewHours: return "Alle paar Stunden"
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
    public var alsoSend: Bool

    public init(isEnabled: Bool = false,
                cadence: Cadence = .daily,
                hour: Int = 3,
                minute: Int = 0,
                everyHours: Int = 6,
                alsoRename: Bool = false,
                alsoSend: Bool = false) {
        self.isEnabled = isEnabled
        self.cadence = cadence
        self.hour = hour
        self.minute = minute
        self.everyHours = everyHours
        self.alsoRename = alsoRename
        self.alsoSend = alsoSend
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
            alsoRename: value(.alsoRename, defaults.alsoRename),
            alsoSend: value(.alsoSend, defaults.alsoSend)
        )
    }

    public func problems() -> [WebSettings.Problem] {
        guard isEnabled else { return [] }
        var found: [WebSettings.Problem] = []
        if !(0...23).contains(hour) || !(0...59).contains(minute) {
            found.append(.init(field: "scheduleTime",
                               message: "Die Uhrzeit muss zwischen 00:00 und 23:59 liegen."))
        }
        if cadence == .everyFewHours, !(1...24).contains(everyHours) {
            found.append(.init(field: "scheduleEveryHours",
                               message: "Der Abstand muss zwischen 1 und 24 Stunden liegen."))
        }
        return found
    }

    /// A sentence saying what will happen, for the interface to show back.
    ///
    /// Worth having: a schedule the user cannot read back is a schedule
    /// they cannot tell is wrong.
    public var summary: String {
        guard isEnabled else { return "Aus — es läuft nichts von selbst." }
        let when: String
        switch cadence {
        case .daily:
            when = String(format: "täglich um %02d:%02d", hour, minute)
        case .everyFewHours:
            when = everyHours == 1 ? "jede Stunde" : "alle \(everyHours) Stunden"
        }
        var what = "durchsuchen"
        if alsoRename { what += ", umbenennen" }
        if alsoSend { what += ", zum Server senden" }
        return "\(when.prefix(1).uppercased())\(when.dropFirst()): \(what)."
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
