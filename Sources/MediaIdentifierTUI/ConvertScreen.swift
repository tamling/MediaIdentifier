import Foundation
import MediaIdentifierCore

/// Re-encoding, to save space.
///
/// The last of the five by importance, and the one used least often — but
/// also the slowest and the only one that writes a second copy of a film,
/// so what it is about to do is spelled out before it starts rather than
/// discovered afterwards.
public struct ConvertScreen {

    public enum Effect: Equatable {
        case none
        case leave
        case look
        case start(Set<UUID>)
        case cancel
        case save(WebConversionSettings)
    }

    public private(set) var candidates: [ConversionCandidate]
    public private(set) var options: WebConversionSettings
    public private(set) var ticked: Set<UUID>
    public private(set) var selected: Int
    public private(set) var snapshot: StatusSnapshot
    public private(set) var haveFFmpeg: Bool

    public init(candidates: [ConversionCandidate], options: WebConversionSettings,
                snapshot: StatusSnapshot, haveFFmpeg: Bool) {
        self.candidates = candidates
        self.options = options
        // Nothing ticked to start with. Converting is slow and writes a
        // second copy of every film; a screen that opened with everything
        // selected would make "start" a far bigger button than it looks.
        self.ticked = []
        self.selected = 0
        self.snapshot = snapshot
        self.haveFFmpeg = haveFFmpeg
    }

    public mutating func refresh(candidates: [ConversionCandidate],
                                 snapshot: StatusSnapshot) {
        self.candidates = candidates
        self.snapshot = snapshot
        // Ticks for files that are no longer offered are dropped, or a
        // start would carry ids the engine no longer knows.
        let known = Set(candidates.map(\.id))
        ticked.formIntersection(known)
        selected = min(selected, max(0, candidates.count - 1))
    }

    public var tickedSize: Int64 {
        candidates.filter { ticked.contains($0.id) }.map(\.byteSize).reduce(0, +)
    }

    // MARK: Keys

    public mutating func handle(_ key: Terminal.Key) -> Effect {
        let busy = snapshot.converting
        switch key {
        case .character("q"), .escape:
            return .leave
        case .character("f"):
            return busy ? .none : .look
        case .character("c"):
            return busy ? .cancel : .none
        case .character(" "):
            guard candidates.indices.contains(selected) else { return .none }
            let id = candidates[selected].id
            if ticked.contains(id) { ticked.remove(id) } else { ticked.insert(id) }
        case .character("a"):
            ticked = Set(candidates.map(\.id))
        case .character("n"):
            ticked = []
        case .enter:
            guard !busy, haveFFmpeg, !ticked.isEmpty else { return .none }
            return .start(ticked)
        case .up, .character("k"):
            selected = max(0, selected - 1)
        case .down, .character("j"):
            selected = min(max(0, candidates.count - 1), selected + 1)
        case .home: selected = 0
        case .end: selected = max(0, candidates.count - 1)
        // The options, stepped in place. A sub-screen for six settings that
        // each have three values would be a worse trade than six keys.
        case .character("v"):
            options.videoCodec = Self.step(ConversionOptions.VideoCodec.allCases,
                                           options.videoCodec)
            return .save(options)
        case .character("p"):
            options.preset = Self.step(ConversionOptions.Preset.allCases,
                                       options.preset)
            return .save(options)
        case .character("m"):
            options.audioMode = Self.step(ConversionOptions.AudioMode.allCases,
                                          options.audioMode)
            return .save(options)
        case .character("s"):
            options.stripSubtitles.toggle()
            return .save(options)
        case .character("+"):
            // Lower is better and bigger, so "+" means better.
            options.quality = max(0, options.quality - 1)
            return .save(options)
        case .character("-"):
            options.quality = min(51, options.quality + 1)
            return .save(options)
        default:
            break
        }
        return .none
    }

    /// Sizes for totals, which `ConversionCandidate` only offers per file.
    static func readable(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func step<T: Equatable>(_ all: [T], _ current: T) -> T {
        guard let index = all.firstIndex(of: current) else { return all[0] }
        return all[(index + 1) % all.count]
    }

    // MARK: Drawing

    public func render(size: ScreenSize) -> [Line] {
        var lines: [Line] = [header(), Dashboard.rule(size.columns),
                             optionsLine(), Dashboard.rule(size.columns)]

        let running = Dashboard.progress(
            Dashboard.State(snapshot: snapshot, checks: [], items: [], log: []),
            columns: size.columns)
        let showProgress = !running.plain.isEmpty
        let room = max(1, size.rows - lines.count - 2 - (showProgress ? 1 : 0))

        if !haveFFmpeg {
            lines.append(Line("  " + Text.s(
                "FFmpeg wurde nicht gefunden: sudo apt install ffmpeg",
                "FFmpeg was not found: sudo apt install ffmpeg"), .failed))
        } else if candidates.isEmpty {
            lines.append(Line("  " + Text.s(
                "Nichts gefunden — [f] durchsucht die Bibliotheksordner.",
                "Nothing found — [f] searches the library folders."), .dim))
        } else {
            let window = Dashboard.layout(selected: selected,
                                          count: candidates.count, rows: room)
            for index in window.first..<(window.first + window.visible) {
                lines.append(row(candidates[index], selected: index == selected,
                                 columns: size.columns))
            }
            if window.hidden > 0, window.visible < room {
                lines.append(Line("  … \(window.hidden) "
                    + Text.s("weitere", "more"), .dim))
            }
        }
        while lines.count < size.rows - 2 - (showProgress ? 1 : 0) {
            lines.append(Line(""))
        }
        if showProgress { lines.append(running) }
        lines.append(summary())
        lines.append(menu())
        return lines.map { $0.truncated(to: size.columns) }
    }

    func header() -> Line {
        Line([
            Segment(Text.s("Konvertieren", "Convert") + " ", .strong),
            Segment("\(candidates.count) "
                + Text.s("Kandidaten", "candidates") + " · ", .dim),
            Segment(Text.s("Nichts wird gelöscht", "Nothing is deleted"), .dim),
        ])
    }

    /// The options on one line, each with the key that steps it. Spelled
    /// out because the result is a second copy of a film and the choices
    /// decide how big and how long that takes.
    func optionsLine() -> Line {
        Line([
            Segment("v ", .accent),
            Segment("\(options.videoCodec.rawValue)  "),
            Segment("+/- ", .accent),
            Segment("CQ \(options.quality)  "),
            Segment("p ", .accent),
            Segment("\(options.preset.rawValue)  "),
            Segment("m ", .accent),
            Segment("\(options.audioMode.rawValue)  "),
            Segment("s ", .accent),
            Segment(Text.s("Untertitel ", "subtitles ")
                + (options.stripSubtitles
                    ? Text.s("weg", "dropped") : Text.s("behalten", "kept"))),
        ])
    }

    func row(_ candidate: ConversionCandidate, selected: Bool,
             columns: Int) -> Line {
        var line = Line([
            Segment(selected ? "▸" : " "),
            Segment(" " + (ticked.contains(candidate.id) ? "[x]" : "[ ]") + " "),
            Segment(candidate.fileName),
            Segment("  " + candidate.readableSize, .dim),
        ])
        if selected {
            line = Line(line.padded(to: columns).segments.map {
                Segment($0.text, .selected)
            })
        }
        return line
    }

    /// What pressing Enter would do, in bytes and in percent, before it is
    /// pressed. The estimate is the engine's own.
    func summary() -> Line {
        guard !ticked.isEmpty else { return Line("") }
        let percent = options.estimatedSizePercent
        let before = Self.readable(bytes: tickedSize)
        let after = Self.readable(
            bytes: Int64(Double(tickedSize) * Double(percent) / 100))
        return Line([
            Segment("\(ticked.count) " + Text.s("angehakt", "ticked") + " · ", .dim),
            Segment(before),
            Segment(" → ", .dim),
            Segment(after, .accent),
            Segment(Text.s(" (geschätzt \(percent) %)", " (estimated \(percent) %)"),
                    .dim),
        ])
    }

    func menu() -> Line {
        let busy = snapshot.converting
        var entries: [(String, String, Bool)] = [
            ("f", Text.s("suchen", "look"), !busy),
            ("␣", Text.s("an/aus", "tick"), !candidates.isEmpty),
            ("a/n", Text.s("alle/keine", "all/none"), !candidates.isEmpty),
            ("⏎", Text.s("starten", "start"), !busy && haveFFmpeg && !ticked.isEmpty),
        ]
        if busy { entries.append(("c", Text.s("stopp", "stop"), true)) }
        entries.append(("q", Text.s("zurück", "back"), true))

        var segments: [Segment] = []
        for (key, label, enabled) in entries {
            if !segments.isEmpty { segments.append(Segment("  ", .dim)) }
            segments.append(Segment(key, enabled ? .accent : .dim))
            segments.append(Segment(" " + label, enabled ? .normal : .dim))
        }
        return Line(segments)
    }
}
