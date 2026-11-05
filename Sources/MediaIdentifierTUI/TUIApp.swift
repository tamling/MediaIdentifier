import Foundation
import MediaIdentifierCore

/// The terminal interface.
///
/// A third front-end over the same engine the window and the web page drive:
/// it submits the same `WebCommand` values and reads the same
/// `StatusSnapshot` back. Nothing about scanning, renaming, sending or the
/// traffic light is reimplemented here, which is why this is a few hundred
/// lines rather than a rewrite.
public final class TUIApp {

    /// What a key means. Separated from both the terminal and the
    /// coordinator so the key map is a pure function of (key, state) — the
    /// part most likely to be wrong, and the part a test can hold down
    /// without a screen or a media library.
    public enum Action: Equatable {
        case quit
        case scan
        case toggleSelected
        case tickAll
        case tickNone
        case rename
        case undo
        case send
        case toggleChecks
        case move(Int)
        case cancel
        case openSettings
        case nothing
    }

    /// The key map.
    ///
    /// `hasItems` and `busy` are passed in rather than read from a
    /// coordinator so this stays pure. A key that cannot do anything right
    /// now returns `.nothing` instead of being submitted and refused: the
    /// refusal would overwrite the message the user is reading.
    public static func action(for key: Terminal.Key,
                              hasItems: Bool,
                              busy: Bool) -> Action {
        switch key {
        case .character("q"), .escape: return .quit
        case .character("s"): return busy ? .nothing : .scan
        case .character(" "): return hasItems ? .toggleSelected : .nothing
        case .character("a"): return hasItems ? .tickAll : .nothing
        case .character("n"): return hasItems ? .tickNone : .nothing
        case .character("r"): return hasItems && !busy ? .rename : .nothing
        case .character("u"): return busy ? .nothing : .undo
        case .character("t"): return hasItems && !busy ? .send : .nothing
        case .character("i"): return .toggleChecks
        // Stopping is never refused while something is running — it is the
        // one key that exists for exactly that moment. Giving `t` without
        // it was a gap worth closing straight away.
        case .character("c"): return busy ? .cancel : .nothing
        case .character("e"): return busy ? .nothing : .openSettings
        case .up, .character("k"): return .move(-1)
        case .down, .character("j"): return .move(1)
        case .pageUp: return .move(-10)
        case .pageDown: return .move(10)
        case .home: return .move(Int.min)
        case .end: return .move(Int.max)
        default: return .nothing
        }
    }

    /// Where the selection lands, kept inside the list.
    ///
    /// `Int.min` and `Int.max` are Home and End, so the arithmetic has to
    /// not overflow on the way: `selected + Int.max` traps in Swift.
    public static func moving(_ selected: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        if delta == Int.min { return 0 }
        if delta == Int.max { return count - 1 }
        return min(max(0, selected + delta), count - 1)
    }

    private let coordinator: AppCoordinator
    private let terminal: Terminal
    private var selected = 0
    private var checksOpen = false
    private var running = true

    public init(coordinator: AppCoordinator, terminal: Terminal = Terminal()) {
        self.coordinator = coordinator
        self.terminal = terminal
    }

    /// Runs until the user leaves. Returns the exit status.
    public func run() -> Int32 {
        guard Terminal.isInteractive else {
            FileHandle.standardError.write(Data(Text.s(
                "Das Terminalfenster wird nicht erkannt. Mit --serve startet "
                    + "stattdessen die Weboberfläche.\n",
                "This is not an interactive terminal. Use --serve to start the "
                    + "web interface instead.\n").utf8))
            return 2
        }
        terminal.start()
        defer { terminal.restore() }

        var size = Terminal.size()
        while running {
            let state = currentState()
            selected = Self.moving(selected, by: 0, count: state.items.count)
            terminal.draw(Dashboard.render(state, size: size), size: size)

            let key = terminal.read()
            if key == .resized {
                size = Terminal.size()
                terminal.invalidate()
                continue
            }
            if key == .timeout { continue }
            perform(Self.action(for: key,
                                hasItems: !state.items.isEmpty,
                                busy: state.snapshot.isWorking),
                    items: state.items)
        }
        return 0
    }

    private func currentState() -> Dashboard.State {
        // One read of each, so every part of a frame describes one moment.
        Dashboard.State(snapshot: coordinator.snapshot,
                        checks: coordinator.systemChecks,
                        items: coordinator.items,
                        log: coordinator.logEntries,
                        selected: selected,
                        checksOpen: checksOpen)
    }

    private func perform(_ action: Action, items: [RenameItem]) {
        switch action {
        case .quit: running = false
        case .scan: coordinator.submit(.scanSourceFolder)
        case .toggleChecks: checksOpen.toggle()
        case .move(let delta):
            selected = Self.moving(selected, by: delta, count: items.count)
        case .toggleSelected:
            guard items.indices.contains(selected) else { return }
            coordinator.submit(.setAccepted(items[selected].id,
                                            !items[selected].isAccepted))
        case .tickAll:
            coordinator.submit(.setAllAccepted(true))
        case .tickNone:
            coordinator.submit(.setAllAccepted(false))
        case .rename:
            let ticked = Set(items.filter(\.isAccepted).map(\.id))
            coordinator.submit(.applyProposedRenames(accepting: ticked))
        case .undo:
            coordinator.submit(.undoLastRename)
        case .send:
            let ticked = Set(items.filter(\.isAccepted).map(\.id))
            coordinator.submit(.transferFiles(accepting: ticked))
        case .cancel:
            // Whichever is running. The engine refuses the ones that are
            // not, quietly, and the user pressed one key for "stop".
            let snapshot = coordinator.snapshot
            if snapshot.transferring { coordinator.submit(.cancelTransfers) }
            else if snapshot.downloading { coordinator.submit(.cancelDownload) }
            else if snapshot.converting { coordinator.submit(.cancelConversions) }
        case .openSettings:
            runSettings()
        case .nothing:
            break
        }
    }

    /// The settings screen, as its own loop. A screen that edits a draft
    /// cannot share the dashboard's loop without the dashboard having to
    /// know about drafts.
    private func runSettings() {
        var screen = SettingsScreen(settings: coordinator.settings,
                                    secrets: coordinator.configuredSecrets)
        var size = Terminal.size()
        terminal.invalidate()
        var leaving = false
        var confirming = false

        while !leaving {
            var lines = screen.render(size: size)
            if confirming, lines.count >= 2 {
                lines[lines.count - 2] = Line(Text.s(
                    "Ungespeicherte Änderungen. Noch einmal q zum Verwerfen, "
                        + "S zum Speichern.",
                    "Unsaved changes. q again to discard, S to save."), .warning)
            }
            terminal.draw(lines, size: size)

            let key = terminal.read()
            if key == .resized {
                size = Terminal.size()
                terminal.invalidate()
                continue
            }
            if key == .timeout { continue }

            // The second q, answering the question asked above.
            if confirming, key == .character("q") || key == .escape {
                leaving = true
                continue
            }
            confirming = false

            switch screen.handle(key) {
            case .none:
                break
            case .save:
                coordinator.submit(.saveSettings(screen.draft))
                // Read back rather than assumed: the engine normalises what
                // it is given, so what was saved is not always what was sent.
                screen.markSaved(coordinator.settings,
                                 secrets: coordinator.configuredSecrets)
            case .setSecret(let key, let value):
                coordinator.submit(.setSecret(key, value))
                screen.markSaved(screen.draft,
                                 secrets: coordinator.configuredSecrets)
            case .leave(let unsaved):
                if unsaved { confirming = true } else { leaving = true }
            }
        }
        terminal.invalidate()
    }
}
