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

private func usage() -> String {
    """
    mediafin-gtk — Mediafin's native interface

      mediafin-gtk                     open the window
      mediafin-gtk --screenshot FILE   render the window to FILE (PNG) and exit
      mediafin-gtk --help              this text

    Needs a display. Without one it exits 2 rather than hanging, so it is safe
    to run from a script; under a headless CI use xvfb-run.
    """
}

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("mediafin-gtk: " + message + "\n").utf8))
    exit(code)
}

private func parse(_ arguments: [String]) -> Mode {
    var mode = Mode.interactive
    var index = arguments.startIndex
    while index < arguments.endIndex {
        switch arguments[index] {
        case "--help", "-h":
            print(usage())
            exit(0)
        case "--screenshot":
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else {
                fail("--screenshot needs a file path", code: 64)
            }
            mode = .screenshot(path: arguments[next])
            index = next
        case let other:
            fail("unknown option \(other)\n\n" + usage(), code: 64)
        }
        index = arguments.index(after: index)
    }
    return mode
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
}

// MARK: Run

private let mode = parse(Array(CommandLine.arguments.dropFirst()))

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
private let coordinator = AppCoordinator(configDirectory: MediafinPaths.configDirectory())
private let mainWindow = AppWindow(coordinator: coordinator)
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

switch mode {
case .interactive:
    gtk_main()

case let .screenshot(path):
    Pending.screenshotPath = path
    // One pass through the main loop is not enough: GTK allocates sizes and
    // paints asynchronously after the window is shown, and drawing too early
    // yields a 1x1 widget. A short timeout lets that settle, and the callback
    // runs exactly once.
    let takeSnapshot: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        defer { gtk_main_quit() }
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
    g_timeout_add(400, takeSnapshot, nil)
    gtk_main()

    if let failure = Pending.failure {
        fail("could not render the window: \(failure)", code: 1)
    }
    print("Wrote \(path)")
}
