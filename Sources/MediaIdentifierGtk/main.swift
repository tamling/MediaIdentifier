import CGtk3
import Foundation
import MediaIdentifierCore
// For setenv.
#if canImport(Glibc)
import Glibc
#endif

// Mediafin's native Linux front-end.
//
// `--screenshot` is not a convenience feature, it is how this interface gets
// tested at all: the window is rendered to a PNG and the process exits with a
// status that says whether it worked. That makes a GUI something CI can check
// and a person can look at, instead of something only a compiler ever sees.

// MARK: Arguments

/// What the process should do once GTK is up.
private enum Mode {
    case interactive
    /// Render the window to this path, then quit.
    case screenshot(path: String)
    /// Hand these files to the window exactly as a drop does, and report
    /// what came of it.
    ///
    /// This splits the drop in two. GTK's own drag plumbing cannot be faked
    /// from here -- there is no public way to build a GdkDragContext -- but
    /// everything after it can, and that is the half with the engine in it.
    /// If this works and a real drop still dies, the fault is in the
    /// plumbing; if this dies too, it is in the engine. Either answer is
    /// worth more than another guess.
    case drop(paths: [String])
    /// Open the settings panel, press Apply twice, and report what it says
    /// each time. Exists because "no idea whether that saved" is a report
    /// about a window that gave no answer at all.
    case pressApply
    /// Press "Scan" and report what the window then says, then quit.
    ///
    /// This exists because CI had only ever rendered a picture of the window.
    /// It proved that the window draws; it never pressed anything. So "the
    /// scan button does nothing and says nothing" was a report CI had no way
    /// of contradicting -- and a check that cannot run looks exactly like a
    /// check that passes.
    case pressScan
}

private struct Options {
    var mode = Mode.interactive
    /// Point the engine at a throwaway library of plausible files and scan it
    /// before doing anything else.
    var demo = false
    /// How long to let the window settle before capturing, in milliseconds.
    /// Exposed so the capture delay can be varied from outside while the
    /// blank-image problem is being pinned down.
    var captureDelay: UInt32?
}

private func usage() -> String {
    """
    mediafin-gtk — Mediafin's native interface, version \(MediafinVersion.number)

      mediafin-gtk                     open the window
      mediafin-gtk --screenshot FILE   render the window to FILE (PNG) and exit
      mediafin-gtk --demo              work on a throwaway library of made-up
                                       files instead of your own settings
      mediafin-gtk --delay MS          how long to let the window settle
                                       before --screenshot captures it
      mediafin-gtk --press-scan        press "Scan", print what the window
                                       then says, and exit non-zero if it
                                       says nothing at all
      mediafin-gtk --press-apply       open the settings, press Apply twice,
                                       and print what it says each time
      mediafin-gtk --drop FILE…        hand these files to the window as a
                                       drop would, and print what came of it
      mediafin-gtk --help              this text

    Needs a display. Without one it exits 2 rather than hanging, so it is safe
    to run from a script; under a headless CI use xvfb-run.

    MEDIAFIN_GTK_THEME=system uses your desktop theme instead of Mediafin's
    own dark palette.
    """
}

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("mediafin-gtk: " + message + "\n").utf8))
    exit(code)
}

private func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var index = arguments.startIndex
    while index < arguments.endIndex {
        switch arguments[index] {
        case "--help", "-h":
            print(usage())
            exit(0)
        case "--version":
            print(MediafinVersion.display)
            exit(0)
        case "--demo":
            options.demo = true
        case "--delay":
            let next = arguments.index(after: index)
            guard next < arguments.endIndex, let value = UInt32(arguments[next]) else {
                fail("--delay needs a number of milliseconds", code: 64)
            }
            options.captureDelay = value
            index = next
        case "--press-scan":
            options.mode = .pressScan
        case "--press-apply":
            options.mode = .pressApply
        case "--drop":
            // Everything after --drop is a path, so this has to come last.
            let rest = Array(arguments[arguments.index(after: index)...])
            guard !rest.isEmpty else { fail("--drop needs at least one path", code: 64) }
            options.mode = .drop(paths: rest)
            index = arguments.endIndex
        case "--screenshot":
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else {
                fail("--screenshot needs a file path", code: 64)
            }
            options.mode = .screenshot(path: arguments[next])
            index = next
        case let other:
            fail("unknown option \(other)\n\n" + usage(), code: 64)
        }
        index = arguments.index(after: index)
    }
    return options
}

// MARK: State the C callbacks reach

// GTK's handlers are C function pointers, which cannot capture Swift context,
// so what they need lives here.
private enum Pending {
    static var window: UnsafeMutablePointer<GtkWidget>?
    static var screenshotPath: String?
    /// What --drop was given, so the C timeout callback can reach it.
    static var dropPaths: [String] = []
    /// Set by the snapshot callback; read after the main loop returns to decide
    /// the exit status. A GUI that silently fails to draw must not exit 0.
    static var failure: String?
}

/// How many proposals were on screen when the picture was taken.
private var capturedProposals = 0

// MARK: Run

private let options = parse(Array(CommandLine.arguments.dropFirst()))

// Before gtk_init, which reads this when it picks a theme.
//
// The stylesheet paints Mediafin's own dark palette, but it cannot reach
// everything: a file chooser dialog, a menu, a tooltip are built by GTK from
// the theme, and a light theme underneath would make those flash white out of
// a dark window. Asking for the dark variant lines them up.
//
// Overwrite is 0 on purpose: a user who sets GTK_THEME themselves keeps it,
// and MEDIAFIN_GTK_THEME=system turns the whole thing off.
if !Styling.isDisabled {
    setenv("GTK_THEME", "Adwaita:dark", 0)
}

// gtk_init_check rather than gtk_init: gtk_init prints its own message and
// aborts, which gives a script no way to tell "no display" from a crash.
guard gtk_init_check(nil, nil) != 0 else {
    fail("""
        no display available (is DISPLAY or WAYLAND_DISPLAY set?).
        On a headless machine: xvfb-run -a mediafin-gtk --screenshot out.png
        """, code: 2)
}

// After gtk_init, which has to have run before a screen exists to style.
Styling.install()

// The same engine the web interface drives, pointed at the same configuration
// directory — so folders set here show up there and the other way round.
//
// With --demo the engine is pointed at a throwaway library instead, so the
// window can be looked at with something in it. Its own configuration
// directory too: filling someone's real settings with made-up folders would
// be a rude way to demonstrate anything.
private let demoLayout: DemoLibrary.Layout? = options.demo ? orExitDemo() : nil

private func orExitDemo() -> DemoLibrary.Layout {
    do { return try DemoLibrary.create() } catch {
        fail("could not build the demo library: \(error)", code: 1)
    }
}

private let configDirectory = demoLayout
    .map { $0.root.appendingPathComponent("config", isDirectory: true) }
    ?? MediafinPaths.configDirectory()

private let coordinator = AppCoordinator(configDirectory: configDirectory)

// The demo scan runs here, before the window exists, and this thread waits
// for it.
//
// Not because waiting is tidy, but because a window cannot be photographed
// after it has been sitting around. Measured under Xvfb with no window
// manager: a capture at 400 ms renders fully, one at 3000 ms renders nothing
// at all — while the widget still reports itself mapped, visible, drawable
// and correctly sized. Three attempts to fix that from the GTK side failed,
// because the problem was never the drawing. So the scan finishes first and
// the capture keeps the short delay that works.
//
// Blocking the main thread is safe here only because GTK's loop has not
// started: once it has, this would freeze the interface.
if let demoLayout {
    coordinator.submit(.saveSettings(DemoLibrary.settings(for: demoLayout)))
    coordinator.submit(.scanSourceFolder)

    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if !coordinator.snapshot.busy, !coordinator.items.isEmpty { break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    if coordinator.items.isEmpty {
        // Carry on and let the picture be taken: an empty one, reported as
        // such, is more use than no picture and no explanation.
        FileHandle.standardError.write(
            Data("mediafin-gtk: the demo scan produced nothing\n".utf8))
    }
}

private let mainWindow = AppWindow(coordinator: coordinator, expandSettings: options.demo)
Pending.window = mainWindow.widget

// The coordinator works on its own queue and cannot call into GTK, which may
// only be touched from the main thread, so the window asks instead. Twice a
// second: fast enough to look live, slow enough to cost nothing.
Gtk.repeating(500, mainWindow) { $0.refresh() }

private let onDestroy: @convention(c) (UnsafeMutablePointer<GtkWidget>?, UnsafeMutableRawPointer?) -> Void = { _, _ in
    gtk_main_quit()
}
Gtk.connect(mainWindow.widget, "destroy", unsafeBitCast(onDestroy, to: GCallback.self))

gtk_widget_show_all(mainWindow.widget)

switch options.mode {
case .interactive:
    gtk_main()

case .pressScan:
    // Two timeouts, not one. The first lets GTK finish laying the window out
    // -- pressing a button that has not been allocated yet is not the thing
    // under test -- and the second gives the engine time to answer on its own
    // queue and the window's own refresh time to pick that answer up.
    let press: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        print("scan button available: \(mainWindow.scanButtonIsAvailable)")
        print("send button on the main surface: "
            + "\(mainWindow.sendButtonIsOnTheMainSurface)")
        mainWindow.pressScan()
        let report: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
            defer { gtk_main_quit() }
            mainWindow.refresh()
            let status = mainWindow.statusText
            print("status: \(status)")
            print("lamp bar: \(mainWindow.lampBarText)")
            print("middle: \(mainWindow.emptyListText)")
            print("proposals: \(coordinator.items.count)")
            if status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Pending.failure = "pressing Scan left the window saying nothing"
            }
            return Gtk.sourceRemove
        }
        g_timeout_add(3000, report, nil)
        return Gtk.sourceRemove
    }
    g_timeout_add(400, press, nil)
    gtk_main()

    // Checked here and not only in the screenshot branch: a mode that reports
    // a fault and then exits 0 is a check that cannot fail, which is the
    // thing this whole mode exists to stop.
    if let failure = Pending.failure {
        fail(failure, code: 1)
    }

case let .drop(paths):
    let handOver: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        mainWindow.addDropped(Pending.dropPaths.map { URL(fileURLWithPath: $0) })
        let report: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
            defer { gtk_main_quit() }
            mainWindow.refresh()
            print("proposals: \(coordinator.items.count)")
            for destination in mainWindow.destinationTexts {
                print("destination: \(destination)")
            }
            print("status: \(mainWindow.statusText)")
            if coordinator.items.isEmpty {
                Pending.failure = "the dropped files produced no proposal"
            }
            return Gtk.sourceRemove
        }
        g_timeout_add(4000, report, nil)
        return Gtk.sourceRemove
    }
    Pending.dropPaths = paths
    g_timeout_add(400, handOver, nil)
    gtk_main()

    if let failure = Pending.failure {
        fail(failure, code: 1)
    }

case .pressApply:
    let apply: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        mainWindow.openSettings()
        mainWindow.pressApply()
        print("applied once: \(mainWindow.appliedText)")
        // A second press a second later. The question is not whether the
        // label has text -- it is whether pressing again is visibly a second
        // press, which is the thing a fixed "Saved." cannot show.
        let again: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
            defer { gtk_main_quit() }
            mainWindow.pressApply()
            print("applied twice: \(mainWindow.appliedText)")
            return Gtk.sourceRemove
        }
        g_timeout_add(1200, again, nil)
        return Gtk.sourceRemove
    }
    g_timeout_add(400, apply, nil)
    gtk_main()

    if let failure = Pending.failure {
        fail(failure, code: 1)
    }

case let .screenshot(path):
    Pending.screenshotPath = path
    // One pass through the main loop is not enough: GTK allocates sizes and
    // paints asynchronously after the window is shown, and drawing too early
    // yields a 1x1 widget. A single timeout lets that settle, and the
    // callback runs exactly once.
    //
    // It must also not be much longer. Under Xvfb with no window manager a
    // capture at 3000 ms comes out entirely blank, with the widget still
    // claiming to be mapped, visible and drawable; 400 ms renders fully,
    // with or without content. Whatever the window loses in those seconds,
    // it is gone before anything can be drawn from it — so the demo does its
    // scanning before the loop starts rather than waiting here.
    let takeSnapshot: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        defer { gtk_main_quit() }
        // The engine works on another queue, so pull its state in here rather
        // than waiting for the window's own half-second refresh.
        mainWindow.refresh()
        capturedProposals = coordinator.items.count
        guard let widget = Pending.window, let path = Pending.screenshotPath else {
            Pending.failure = "no window to render"
            return Gtk.sourceRemove
        }
        do {
            try WindowSnapshot.write(widget, to: path)
        } catch {
            Pending.failure = "\(error)"
        }
        return Gtk.sourceRemove
    }
    g_timeout_add(options.captureDelay ?? 400, takeSnapshot, nil)
    gtk_main()

    if let layout = demoLayout {
        try? FileManager.default.removeItem(at: layout.root)
    }
    if let failure = Pending.failure {
        fail("could not render the window: \(failure)", code: 1)
    }
    print("Wrote \(path)")
    if options.demo {
        // Said out loud so a caller can check what was actually in the
        // picture. A screenshot of the empty state is a valid PNG, and
        // without this the only signal would be its file size.
        print("Captured \(capturedProposals) proposals")
    }
}
