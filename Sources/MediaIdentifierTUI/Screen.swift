import Foundation

/// How a piece of text is drawn.
///
/// Named by meaning rather than by colour — `.failed` and not `.red` — so the
/// same line can be drawn in colour, drawn in plain text, or asserted in a
/// test without any of the three knowing about the other two.
public enum Style: Equatable, Sendable {
    case normal
    case dim
    case strong
    case ok
    case warning
    case failed
    case accent
    /// The selected row, drawn as reversed video.
    case selected

    /// SGR parameters. 8-colour codes rather than 256-colour or truecolour:
    /// they are the ones every terminal and every colour scheme supports,
    /// and they follow the user's own palette instead of overriding it with
    /// our idea of green.
    var sgr: String {
        switch self {
        case .normal: return "0"
        case .dim: return "2"
        case .strong: return "1"
        case .ok: return "32"
        case .warning: return "33"
        case .failed: return "31"
        case .accent: return "36"
        case .selected: return "7"
        }
    }
}

/// A run of text in one style.
public struct Segment: Equatable, Sendable {
    public let text: String
    public let style: Style

    public init(_ text: String, _ style: Style = .normal) {
        self.text = text
        self.style = style
    }
}

/// One row of the screen.
public struct Line: Equatable, Sendable {
    public var segments: [Segment]

    public init(_ segments: [Segment]) { self.segments = segments }
    public init(_ text: String, _ style: Style = .normal) {
        self.init([Segment(text, style)])
    }

    /// The text with no styling, which is what the tests read. Keeping this
    /// separate from the escape codes is the whole point of the model: a
    /// test that had to match "\u{1B}[32m" to check a word would be a test
    /// of the colour table, not of the layout.
    public var plain: String { segments.map(\.text).joined() }

    /// The number of columns this occupies, which is not the number of
    /// characters: an umlaut may arrive as two scalars, and the box-drawing
    /// and lamp characters used here are one column each.
    public var width: Int { plain.count }

    /// The same line with the styles turned into escape codes.
    public func ansi() -> String {
        var out = ""
        for segment in segments where !segment.text.isEmpty {
            if segment.style == .normal {
                out += segment.text
            } else {
                out += "\u{1B}[\(segment.style.sgr)m\(segment.text)\u{1B}[0m"
            }
        }
        return out
    }

    /// Cuts the line to `columns`, with an ellipsis when something was lost.
    ///
    /// Cutting here rather than letting the terminal wrap: a wrapped line
    /// pushes every row below it down by one, so one long file name turns
    /// the whole screen into a smear that redraws differently every frame.
    public func truncated(to columns: Int) -> Line {
        guard columns > 0 else { return Line([]) }
        guard width > columns else { return self }
        var kept: [Segment] = []
        var used = 0
        // One column is kept back for the ellipsis.
        let limit = columns - 1
        for segment in segments {
            if used >= limit { break }
            let room = limit - used
            if segment.text.count <= room {
                kept.append(segment)
                used += segment.text.count
            } else {
                kept.append(Segment(String(segment.text.prefix(room)), segment.style))
                used = limit
            }
        }
        kept.append(Segment("…", .dim))
        return Line(kept)
    }

    /// Pads to `columns` so a reversed-video row covers the full width.
    public func padded(to columns: Int) -> Line {
        guard width < columns else { return self }
        var out = segments
        let style = segments.last?.style ?? .normal
        out.append(Segment(String(repeating: " ", count: columns - width), style))
        return Line(out)
    }
}

/// How big the screen is.
public struct ScreenSize: Equatable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        // A floor rather than an error: a terminal that reports something
        // absurd should give a cramped screen, not a crash.
        self.columns = max(20, columns)
        self.rows = max(8, rows)
    }

    /// What a terminal that will not say gets. 80×24 is the size every
    /// terminal has defaulted to since the VT100.
    public static let fallback = ScreenSize(columns: 80, rows: 24)
}
