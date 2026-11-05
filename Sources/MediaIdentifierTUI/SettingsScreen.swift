import Foundation
import MediaIdentifierCore

/// The settings screen: a list of fields, one of which may be being typed
/// into.
///
/// It edits a draft and only submits when asked, so leaving without saving
/// changes nothing — the same bargain the web form makes, and the one a
/// person poking at an unfamiliar program needs.
public struct SettingsScreen {

    /// What a key press asked for. Returned rather than performed, so the
    /// decision and the doing can be tested apart.
    public enum Effect: Equatable {
        case none
        case save
        /// Leave without saving. True when there are unsaved changes, which
        /// the caller turns into a confirmation rather than losing them.
        case leave(unsaved: Bool)
        case setSecret(SecretKey, String)
    }

    public private(set) var draft: WebSettings
    /// What was last saved, to tell "changed" from "typed the same thing".
    public private(set) var saved: WebSettings
    public private(set) var secrets: Set<SecretKey>
    public private(set) var selected: Int
    /// The text being typed, or nil when nothing is being edited.
    public private(set) var editing: String?

    public init(settings: WebSettings, secrets: Set<SecretKey>) {
        self.draft = settings
        self.saved = settings
        self.secrets = secrets
        self.selected = 0
        self.editing = nil
        selected = Self.nextEditable(from: -1, by: 1, in: fields)
    }

    public var fields: [SettingsForm.Field] {
        SettingsForm.fields(for: draft, secrets: secrets)
    }

    public var hasUnsavedChanges: Bool { draft != saved }

    /// Called after the engine has saved, so "unsaved" stops being true.
    public mutating func markSaved(_ settings: WebSettings, secrets: Set<SecretKey>) {
        draft = settings
        saved = settings
        self.secrets = secrets
    }

    /// Skips the section headings, which cannot be selected.
    static func nextEditable(from index: Int, by delta: Int,
                             in fields: [SettingsForm.Field]) -> Int {
        guard !fields.isEmpty else { return 0 }
        var candidate = index
        for _ in 0..<fields.count {
            candidate += delta
            if candidate < 0 { candidate = fields.count - 1 }
            if candidate >= fields.count { candidate = 0 }
            if fields[candidate].isEditable { return candidate }
        }
        return max(0, min(index, fields.count - 1))
    }

    // MARK: Keys

    public mutating func handle(_ key: Terminal.Key) -> Effect {
        let all = fields
        guard !all.isEmpty else { return .none }

        // While typing, almost every key is text.
        if var buffer = editing {
            switch key {
            case .enter:
                let field = all[selected]
                editing = nil
                if let secret = SettingsForm.secret(for: field.id) {
                    return .setSecret(secret, buffer)
                }
                draft = SettingsForm.applying(buffer, to: field.id, in: draft)
                return .none
            case .escape:
                editing = nil
                return .none
            case .backspace:
                if !buffer.isEmpty { buffer.removeLast() }
                editing = buffer
                return .none
            case .character(let character):
                buffer.append(character)
                editing = buffer
                return .none
            default:
                return .none
            }
        }

        switch key {
        case .character("q"), .escape:
            return .leave(unsaved: hasUnsavedChanges)
        case .character("S"):
            return .save
        case .up, .character("k"):
            selected = Self.nextEditable(from: selected, by: -1, in: all)
        case .down, .character("j"):
            selected = Self.nextEditable(from: selected, by: 1, in: all)
        case .enter:
            let field = all[selected]
            switch field.kind {
            case .text:
                editing = field.value
            case .secret:
                // Starts empty, never with the stored value: this screen
                // never has the value, and showing "stored" as if it were
                // text to edit would be a lie the user could press Enter on.
                editing = ""
            case .toggle:
                draft = SettingsForm.toggling(field.id, in: draft)
            case .choice:
                draft = SettingsForm.cycling(field.id, by: 1, in: draft)
            case .section:
                break
            }
        case .character(" "):
            let field = all[selected]
            if field.kind == .toggle {
                draft = SettingsForm.toggling(field.id, in: draft)
            }
        case .character("h"):
            draft = SettingsForm.cycling(all[selected].id, by: -1, in: draft)
        case .character("l"):
            draft = SettingsForm.cycling(all[selected].id, by: 1, in: draft)
        default:
            break
        }
        return .none
    }

    // MARK: Drawing

    public func render(size: ScreenSize) -> [Line] {
        let all = fields
        var lines: [Line] = []
        lines.append(Line([
            Segment(Text.s("Einstellungen", "Settings") + " ", .strong),
            Segment(hasUnsavedChanges
                ? Text.s("· ungespeichert", "· unsaved") : "", .warning),
        ]))
        lines.append(Dashboard.rule(size.columns))

        let fixed = lines.count + 3
        let room = max(1, size.rows - fixed)
        let start = Dashboard.windowStart(selected: selected, count: all.count,
                                          rows: room)
        let labelWidth = min(22, all.filter(\.isEditable).map(\.label.count).max() ?? 10)

        for index in start..<min(start + room, all.count) {
            let field = all[index]
            if field.kind == .section {
                lines.append(Line("  " + field.label.uppercased(), .dim))
                continue
            }
            let isSelected = index == selected
            let label = field.label.padding(
                toLength: max(labelWidth, field.label.count),
                withPad: " ", startingAt: 0)
            var value = field.value
            var valueStyle: Style = .normal
            if isSelected, let buffer = editing {
                // A block for the cursor: there is no real cursor to show,
                // because it is hidden for the whole program.
                value = (field.kind == .secret
                    ? String(repeating: "•", count: buffer.count) : buffer) + "█"
                valueStyle = .accent
            } else if value.isEmpty, case .text(let placeholder) = field.kind {
                value = placeholder
                valueStyle = .dim
            }
            var segments = [
                Segment(isSelected ? "▸ " : "  "),
                Segment(label + "  "),
                Segment(value, valueStyle),
            ]
            if let problem = field.problem {
                segments.append(Segment("  ! " + problem, .failed))
            }
            var line = Line(segments)
            if isSelected, editing == nil {
                line = Line(line.padded(to: size.columns).segments.map {
                    Segment($0.text, .selected)
                })
            }
            lines.append(line)
        }
        while lines.count < size.rows - 2 { lines.append(Line("")) }

        // The hint for the selected field, where the message line is on the
        // dashboard: the same row always says "what about the thing you are
        // looking at".
        let hint = all.indices.contains(selected) ? (all[selected].hint ?? "") : ""
        lines.append(Line(hint, .dim))
        lines.append(menu())
        return lines.map { $0.truncated(to: size.columns) }
    }

    func menu() -> Line {
        if editing != nil {
            return Line([
                Segment("⏎", .accent), Segment(" " + Text.s("übernehmen", "commit")),
                Segment("   "),
                Segment("esc", .accent), Segment(" " + Text.s("verwerfen", "discard")),
            ])
        }
        let entries: [(String, String)] = [
            ("↑↓", Text.s("wählen", "move")),
            ("⏎", Text.s("ändern", "change")),
            ("h/l", Text.s("umschalten", "cycle")),
            ("S", Text.s("speichern", "save")),
            ("q", Text.s("zurück", "back")),
        ]
        var segments: [Segment] = []
        for (key, label) in entries {
            if !segments.isEmpty { segments.append(Segment("  ", .dim)) }
            segments.append(Segment(key, .accent))
            segments.append(Segment(" " + label))
        }
        return Line(segments)
    }
}
