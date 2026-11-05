import Foundation
import MediaIdentifierCore

/// What the whole screen looks like, as data.
///
/// Pure: it is given the state and the size and returns lines. Nothing here
/// touches a terminal, which is why the layout can be asserted in CI on a
/// machine with no screen at all — the thing that was impossible for the
/// window, where "it builds" was all a test could say.
public enum Dashboard {

    /// Everything the screen needs, gathered once per frame so that every
    /// part of one frame describes the same moment. Reading the coordinator
    /// piecemeal while drawing gives a header from before a scan and a list
    /// from after it.
    public struct State {
        public var snapshot: StatusSnapshot
        public var checks: [SystemCheck]
        public var items: [RenameItem]
        public var log: [RenameLogEntry]
        public var selected: Int
        public var checksOpen: Bool
        public var version: String

        public init(snapshot: StatusSnapshot, checks: [SystemCheck], items: [RenameItem],
                    log: [RenameLogEntry], selected: Int = 0, checksOpen: Bool = false,
                    version: String = MediafinVersion.display) {
            self.snapshot = snapshot
            self.checks = checks
            self.items = items
            self.log = log
            self.selected = selected
            self.checksOpen = checksOpen
            self.version = version
        }
    }

    /// The lamp character. One column wide in every font, unlike the emoji
    /// circles, which are two in some terminals and one in others — and a
    /// character whose width you cannot predict makes every column after it
    /// land in a different place.
    static let lamp = "\u{25CF}"

    static func style(for state: SystemCheck.State) -> Style {
        switch state {
        case .ok: return .ok
        case .warning: return .warning
        case .failed: return .failed
        case .off: return .dim
        }
    }

    // MARK: The whole screen

    public static func render(_ state: State, size: ScreenSize) -> [Line] {
        var lines: [Line] = []
        lines.append(header(state, columns: size.columns))
        lines.append(trafficLight(state, columns: size.columns))
        if state.checksOpen {
            lines.append(contentsOf: lampRows(state.checks, columns: size.columns))
        }
        lines.append(rule(size.columns))

        // The list gets whatever is left after the fixed parts. Worked out
        // rather than guessed, so an eight-row terminal still shows a row of
        // the list instead of scrolling the menu off the bottom.
        let fixed = lines.count + 3   // rule + message + menu
        let room = max(1, size.rows - fixed)
        lines.append(contentsOf: proposals(state, columns: size.columns, rows: room))

        lines.append(rule(size.columns))
        lines.append(message(state, columns: size.columns))
        lines.append(menu(state, columns: size.columns))
        return lines.map { $0.truncated(to: size.columns) }
    }

    // MARK: The parts

    static func header(_ state: State, columns: Int) -> Line {
        let snapshot = state.snapshot
        let word: String
        let style: Style
        if snapshot.hasError {
            word = Text.s("Fehler", "errors")
            style = .failed
        } else if snapshot.isWorking {
            word = (snapshot.convertStatus ?? Text.s("arbeitet", "working"))
                + " \(snapshot.activePercent) %"
            style = .accent
        } else {
            word = Text.s("bereit", "ready")
            style = .ok
        }
        var segments = [Segment("Mediafin ", .strong), Segment(word, style)]
        let counts = Text.s(
            "\(snapshot.totalItems) Vorschläge · \(snapshot.ready) angehakt",
            "\(snapshot.totalItems) proposals · \(snapshot.ready) ticked")
        let right = " " + counts + " " + state.version
        let left = Line(segments).width
        if left + right.count < columns {
            segments.append(Segment(String(repeating: " ",
                                           count: columns - left - right.count)))
            segments.append(Segment(counts + " ", .dim))
            segments.append(Segment(state.version, .dim))
        }
        return Line(segments)
    }

    /// One line, always: the summary and the worst lamp. Folded by default
    /// because eight rows of detail are not what you look at when the
    /// summary already says everything is fine — the same reason the window
    /// puts it behind an expander.
    static func trafficLight(_ state: State, columns: Int) -> Line {
        guard !state.checks.isEmpty else { return Line("") }
        let worst = SystemChecks.worst(state.checks)
        let marker = state.checksOpen ? "▾" : "▸"
        return Line([
            Segment("\(marker) ", .dim),
            Segment(lamp + " ", style(for: worst)),
            Segment(Text.s("Status", "Status") + " ", .strong),
            Segment(SystemChecks.summary(state.checks), .dim),
        ])
    }

    static func lampRows(_ checks: [SystemCheck], columns: Int) -> [Line] {
        // The widest name, so the words and the details line up in a column
        // instead of stepping left and right down the panel.
        let nameWidth = min(18, checks.map(\.name.count).max() ?? 0)
        let wordWidth = min(10, checks.map(\.state.word.count).max() ?? 0)
        return checks.map { check in
            let name = check.name.padding(toLength: max(nameWidth, check.name.count),
                                          withPad: " ", startingAt: 0)
            let word = check.state.word.padding(
                toLength: max(wordWidth, check.state.word.count),
                withPad: " ", startingAt: 0)
            return Line([
                Segment("   " + lamp + " ", style(for: check.state)),
                Segment(name + "  ", .normal),
                Segment(word + "  ", style(for: check.state)),
                Segment(check.detail, .dim),
            ])
        }
    }

    static func rule(_ columns: Int) -> Line {
        Line(String(repeating: "─", count: columns), .dim)
    }

    /// The list, with the selected row reversed and a window that follows
    /// the selection rather than the top of the list.
    static func proposals(_ state: State, columns: Int, rows: Int) -> [Line] {
        guard !state.items.isEmpty else {
            let text = state.snapshot.totalItems == 0
                ? Text.s("Noch nichts durchsucht — [s] sucht im Importordner.",
                         "Nothing scanned yet — [s] looks in the import folder.")
                : Text.s("Nichts übrig.", "Nothing left.")
            var out = [Line("  " + text, .dim)]
            while out.count < rows { out.append(Line("")) }
            return out
        }

        let window = layout(selected: state.selected, count: state.items.count,
                            rows: rows)
        var out: [Line] = []
        for index in window.first..<(window.first + window.visible) {
            let item = state.items[index]
            let isSelected = index == state.selected
            let tick = item.isAccepted ? "[x]" : "[ ]"
            var segments = [
                Segment(isSelected ? "▸" : " "),
                Segment(" \(tick) "),
                Segment(item.newFileName),
            ]
            if let conflict = item.conflict {
                let word = conflict == .duplicateInBatch
                    ? Text.s("doppelt", "duplicate")
                    : Text.s("liegt schon da", "already there")
                segments.append(Segment("  ! " + word, .warning))
            }
            var line = Line(segments)
            if isSelected { line = Line(line.padded(to: columns).segments.map {
                Segment($0.text, .selected)
            }) }
            out.append(line)
        }
        // The rest of the list said in one line, so the screen never
        // pretends the list ends where the window does. `layout` has
        // already kept a row free for it — the first version took the row
        // back from the list instead, which ate the last entry, and that
        // was exactly the entry the selection was on when you pressed End.
        if window.hidden > 0 {
            out.append(Line("  … \(window.hidden) " + Text.s("weitere", "more"), .dim))
        }
        while out.count < rows { out.append(Line("")) }
        return out
    }

    /// Which slice of the list to draw, and how much is left below it.
    ///
    /// One function rather than two, because the three numbers constrain
    /// each other: the "… N more" line needs a row, that row comes out of
    /// the list, and taking it changes which entries fit — which is how the
    /// first version managed to scroll the selected row off the bottom
    /// while believing it had put it in view.
    static func layout(selected: Int, count: Int,
                       rows: Int) -> (first: Int, visible: Int, hidden: Int) {
        guard rows > 0 else { return (0, 0, count) }
        guard count > rows else { return (0, count, 0) }

        // One row given to the indicator, and the window centred on the
        // selection so moving down scrolls instead of stopping.
        let visible = rows - 1
        let first = min(max(0, selected - visible / 2), count - visible)
        let hidden = count - (first + visible)
        guard hidden > 0 else {
            // At the bottom there is nothing below to announce, so the row
            // the indicator would have taken goes back to the list.
            return (count - rows, rows, 0)
        }
        return (first, visible, hidden)
    }

    /// Kept for the settings screen, which has no "more" line of its own.
    static func windowStart(selected: Int, count: Int, rows: Int) -> Int {
        guard count > rows else { return 0 }
        return min(max(0, selected - rows / 2), count - rows)
    }

    static func message(_ state: State, columns: Int) -> Line {
        guard let text = state.snapshot.lastResult, !text.isEmpty else {
            return Line("")
        }
        return Line(text, state.snapshot.hasError ? .failed : .normal)
    }

    /// The menu, always on the last row, always fitting.
    ///
    /// Fitting is the part that needed thinking about. Adding two keys made
    /// the full row longer than eighty columns, and what fell off the end
    /// was `q` — the way out. So the row is built to the width it has: the
    /// labels go first, then the least important keys, and `q` is never one
    /// of them. A terminal that cannot show the way out is a trap.
    static func menu(_ state: State, columns: Int) -> Line {
        let snapshot = state.snapshot
        let busy = snapshot.isWorking
        let hasItems = !state.items.isEmpty
        // Ordered by what you would miss most, least-missed first, because
        // that is the end they are dropped from.
        let entries: [(key: String, label: String, enabled: Bool)] = [
            ("e", Text.s("einstellungen", "settings"), !busy),
            ("i", Text.s("status", "status"), true),
            ("a/n", Text.s("alle/keine", "all/none"), hasItems),
            ("u", Text.s("zurück", "undo"), !busy),
            ("t", Text.s("senden", "send"),
             snapshot.remoteConfigured && hasItems && !busy),
            ("c", Text.s("stopp", "stop"), busy),
            ("␣", Text.s("an/aus", "tick"), hasItems),
            ("r", Text.s("umbenennen", "rename"), hasItems && !busy),
            ("s", Text.s("suchen", "scan"), !busy),
            ("q", Text.s("ende", "quit"), true),
        ]

        func build(_ chosen: [(key: String, label: String, enabled: Bool)],
                   labels: Bool) -> Line {
            var segments: [Segment] = []
            // Drawn in the order a hand expects, which is the reverse of the
            // order they are dropped in.
            for entry in chosen.reversed() {
                if !segments.isEmpty { segments.append(Segment("  ", .dim)) }
                segments.append(Segment(entry.key, entry.enabled ? .accent : .dim))
                if labels {
                    segments.append(Segment(" " + entry.label,
                                            entry.enabled ? .normal : .dim))
                }
            }
            return Line(segments)
        }

        let full = build(entries, labels: true)
        if full.width <= columns { return full }

        // Keys only: on a narrow terminal the letters are the part that
        // matters, and they are what somebody who has used it twice reads.
        let bare = build(entries, labels: false)
        if bare.width <= columns { return bare }

        // Still too narrow: drop from the front of the list, which is the
        // least-missed end, but never the last entry.
        var kept = entries
        while kept.count > 1, build(kept, labels: false).width > columns {
            kept.removeFirst()
        }
        return build(kept, labels: false)
    }
}
