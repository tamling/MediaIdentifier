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
}

private struct Options {
    var mode = Mode.interactive
    /// Point the engine at a throwaway library of plausible files and scan it
    /// before doing anything else.
    var demo = false
}

private func usage() -> String {
    """
    mediafin-gtk — Mediafin's native interface, version \(MediafinVersion.number)

      mediafin-gtk                     open the window
      mediafin-gtk --screenshot FILE   render the window to FILE (PNG) and exit
      mediafin-gtk --demo              work on a throwaway library of made-up
                                       files instead of your own settings
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
    /// Set by the snapshot callback; read after the main loop returns to decide
    /// the exit status. A GUI that silently fails to draw must not exit 0.
    static var failure: String?
    /// True once the thing the screenshot is waiting for has happened.
    static var isReady: () -> Bool = { true }
    /// Gives up waiting, so a scan that never finishes still produces a
    /// picture — of the state it got stuck in, which is what one would want
    /// to look at.
    static var attemptsLeft = 1
    /// Set once the window has been given the finished state, so the shot is
    /// taken a tick later and catches it painted rather than pending.
    static var hasSettled = false
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
private let mainWindow = AppWindow(coordinator: coordinator)
Pending.window = mainWindow.widget

if let demoLayout {
    coordinator.submit(.saveSettings(DemoLibrary.settings(for: demoLayout)))
    coordinator.submit(.scanSourceFolder)
}

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

case let .screenshot(path):
    Pending.screenshotPath = path
    // With --demo there is a scan in flight, and a picture taken before it
    // lands would show the empty state — which is exactly the picture the
    // demo exists to stop taking. Wait for proposals to appear, then for one
    // more tick so the window has drawn them.
    if options.demo {
        Pending.isReady = { !coordinator.snapshot.busy && !coordinator.items.isEmpty }
        Pending.attemptsLeft = 60   // 12 s at 200 ms
    }
    // One pass through the main loop is never enough on its own: GTK
    // allocates sizes and paints asynchronously after the window is shown,
    // and drawing too early yields a 1x1 widget.
    let takeSnapshot: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        Pending.attemptsLeft -= 1
        let waitedLongEnough = Pending.attemptsLeft <= 0

        // Pull the engine's state into the window here rather than relying on
        // the half-second refresh: the proposals could otherwise exist while
        // the list that is about to be photographed is still empty.
        mainWindow.refresh()
        guard waitedLongEnough || Pending.isReady() else { return Gtk.sourceContinue }
        // One more turn of the loop after the rows are built, so GTK has
        // actually painted them before they are drawn into a surface.
        if !waitedLongEnough, !Pending.hasSettled {
            Pending.hasSettled = true
            return Gtk.sourceContinue
        }

        defer { gtk_main_quit() }
        capturedProposals = coordinator.items.count
        guard let widget = Pending.window, let path = Pending.screenshotPath else {
            Pending.failure = "no window to render"
            return Gtk.sourceRemove
        }
        if waitedLongEnough, !Pending.isReady() {
            // Not a failure: the picture is still worth having, and saying so
            // is better than a green run that quietly shot the wrong state.
            FileHandle.standardError.write(
                Data("mediafin-gtk: gave up waiting; capturing as-is\n".utf8))
        }
        do {
            try WindowSnapshot.write(widget, to: path)
        } catch {
            Pending.failure = "\(error)"
        }
        return Gtk.sourceRemove
    }
    g_timeout_add(options.demo ? 200 : 400, takeSnapshot, nil)
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
