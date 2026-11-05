import Foundation
import MediaIdentifierCore

/// What happened, newest first.
///
/// The dashboard shows the last message and nothing else, so this is the
/// answer to "why did nothing happen" — and to the question after it,
/// "what exactly did it do to my files". A failed row carries its reason
/// on the row rather than behind a key press: the reason is why you came.
public struct HistoryScreen {

    public enum Effect: Equatable {
        case none
        case leave
        case clear
    }

    public private(set) var entries: [RenameLogEntry]
    public private(set) var selected: Int
    /// Set after the first press of the clear key, cleared by anything else.
    public private(set) var confirmingClear: Bool

    public init(entries: [RenameLogEntry]) {
        // Newest first: the thing you just did is the thing you are asking
        // about, and scrolling to the bottom of a year of renames to find
        // it is not a feature.
        self.entries = entries.sorted { $0.date > $1.date }
        self.selected = 0
        self.confirmingClear = false
    }

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd.MM. HH:mm:ss"
        return formatter
    }()

    static func style(for status: RenameLogEntry.Status) -> Style {
        switch status {
        case .failure: return .failed
        case .skipped: return .warning
        case .success, .converted, .sent, .downloaded: return .ok
        }
    }

    public static func word(for status: RenameLogEntry.Status) -> String {
        switch status {
        case .success: return Text.s("umbenannt", "renamed")
        case .failure: return Text.s("fehlgeschlagen", "failed")
        case .skipped: return Text.s("übersprungen", "skipped")
        case .converted: return Text.s("konvertiert", "converted")
        case .sent: return Text.s("gesendet", "sent")
        case .downloaded: return Text.s("geladen", "fetched")
        }
    }

    // MARK: Keys

    public mutating func handle(_ key: Terminal.Key) -> Effect {
        if confirmingClear {
            // Only the same key again confirms. Any other key is an answer
            // of "no" — including the arrow somebody presses out of habit.
            confirmingClear = false
            if key == .character("x") { return .clear }
            if key == .character("q") || key == .escape { return .leave }
            return .none
        }
        switch key {
        case .character("q"), .escape:
            return .leave
        case .character("x"):
            guard !entries.isEmpty else { return .none }
            confirmingClear = true
        case .up, .character("k"):
            selected = max(0, selected - 1)
        case .down, .character("j"):
            selected = min(max(0, entries.count - 1), selected + 1)
        case .pageUp:
            selected = max(0, selected - 10)
        case .pageDown:
            selected = min(max(0, entries.count - 1), selected + 10)
        case .home:
            selected = 0
        case .end:
            selected = max(0, entries.count - 1)
        default:
            break
        }
        return .none
    }

    // MARK: Drawing

    public func render(size: ScreenSize) -> [Line] {
        let failed = entries.filter { $0.status == .failure }.count
        var lines: [Line] = [
            Line([
                Segment(Text.s("Verlauf", "History") + " ", .strong),
                Segment("\(entries.count) "
                    + Text.s(entries.count == 1 ? "Eintrag" : "Einträge",
                             entries.count == 1 ? "entry" : "entries"), .dim),
                Segment(failed > 0
                    ? " · \(failed) " + Text.s("fehlgeschlagen", "failed") : "",
                    .failed),
            ]),
            Dashboard.rule(size.columns),
        ]

        let room = max(1, size.rows - lines.count - 2)
        if entries.isEmpty {
            lines.append(Line("  " + Text.s("Noch nichts passiert.",
                                            "Nothing has happened yet."), .dim))
        } else {
            let window = Dashboard.layout(selected: selected, count: entries.count,
                                          rows: room)
            for index in window.first..<(window.first + window.visible) {
                lines.append(row(entries[index], selected: index == selected,
                                 columns: size.columns))
            }
            if window.hidden > 0, window.visible < room {
                lines.append(Line("  … \(window.hidden) "
                    + Text.s("weitere", "more"), .dim))
            }
        }
        while lines.count < size.rows - 2 { lines.append(Line("")) }

        lines.append(confirmingClear
            ? Line(Text.s("Verlauf wirklich leeren? Noch einmal x.",
                          "Really clear the history? x again."), .warning)
            : Line(""))
        lines.append(menu())
        return lines.map { $0.truncated(to: size.columns) }
    }

    func row(_ entry: RenameLogEntry, selected: Bool, columns: Int) -> Line {
        let word = Self.word(for: entry.status)
        var segments = [
            Segment(selected ? "▸ " : "  "),
            Segment(Self.time.string(from: entry.date) + "  ", .dim),
            Segment(word.padding(toLength: max(14, word.count),
                                 withPad: " ", startingAt: 0),
                    Self.style(for: entry.status)),
            Segment(entry.oldName),
        ]
        // "—" for a destination that is not a name: an undo logs where the
        // file came from, a refusal logs nothing at all.
        if entry.newName != entry.oldName, !entry.newName.isEmpty {
            segments.append(Segment(" → ", .dim))
            segments.append(Segment(entry.newName))
        }
        // The reason on the row, not behind a key press. It is why you came.
        if let reason = entry.errorDescription, !reason.isEmpty {
            segments.append(Segment("  · " + reason, .dim))
        }
        var line = Line(segments)
        if selected {
            line = Line(line.padded(to: columns).segments.map {
                Segment($0.text, .selected)
            })
        }
        return line
    }

    func menu() -> Line {
        var segments: [Segment] = []
        for (key, label) in [("↑↓", Text.s("blättern", "scroll")),
                             ("x", Text.s("leeren", "clear")),
                             ("q", Text.s("zurück", "back"))] {
            if !segments.isEmpty { segments.append(Segment("  ", .dim)) }
            segments.append(Segment(key, .accent))
            segments.append(Segment(" " + label))
        }
        return Line(segments)
    }
}
