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
    /// Open the conversion panel, look for files, untick one, and convert
    /// what is left -- the whole feature end to end.
    ///
    /// The conversion feature was reachable from the removed web front-end
    /// and from nothing else: the engine, the FFmpeg driving, the progress
    /// reporting, the cancelling and their tests were all there, and no
    /// button in the program could ask for any of it. A unit test cannot
    /// catch that, and a check that cannot run looks exactly like a check
    /// that passes -- so this presses the buttons.
    case pressConvert
    /// Press "Leeren" in the history column twice: cancel the confirmation
    /// the first time, confirm it the second, and report the history both
    /// times.
    ///
    /// Clearing takes the undo journal with it, so the confirmation is the
    /// only thing between a stray click and a library that cannot be put
    /// back. A guard nothing presses is a guard somebody deletes.
    case pressClearHistory
    /// Press "Alles prüfen" and report, while it is still running, what the
    /// header says and whether Undo can be pressed.
    ///
    /// Four commands hold the engine's serial queue without ever setting
    /// `busy`: both connection tests, Alles prüfen, and Rückgängig. For as
    /// long as one runs, the window used to say "Bereit" with every button
    /// live -- and a second press of Undo during the first reversed a batch
    /// the user never asked to reverse, because the first press had already
    /// removed the transaction it worked from. Pointed at a server that
    /// accepts and never answers, this holds that state open long enough to
    /// look at it.
    case pressCheck
}

private struct Options {
    var mode = Mode.interactive
    /// Which panel `--screenshot` should render instead of the main window.
    var panel: String?
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
      mediafin-gtk --panel NAME        with --screenshot, render that panel
                                       instead: settings, status, fetch or
                                       convert
      mediafin-gtk --demo              work on a throwaway library of made-up
                                       files instead of your own settings
      mediafin-gtk --delay MS          how long to let the window settle
                                       before --screenshot captures it
      mediafin-gtk --press-scan        press "Scan", print what the window
                                       then says, and exit non-zero if it
                                       says nothing at all
      mediafin-gtk --press-apply       open the settings, press Apply twice,
                                       and print what it says each time
      mediafin-gtk --press-convert     open the conversion panel, look for
                                       files, untick one, convert the rest,
                                       then tick everything and convert the
                                       remainder, printing what came of it
      mediafin-gtk --press-clear-history
                                       press "Leeren", cancel the question,
                                       press it again and confirm, printing
                                       the history each time
      mediafin-gtk --press-check       press "Alles prüfen" and report, while
                                       it still runs, what the header says and
                                       whether Undo can be pressed
      mediafin-gtk --drop FILE…        hand these files to the window as a
                                       drop would, and print what came of it
      mediafin-gtk --help              this text

    --press-convert, --press-clear-history and --press-apply change files,
    so they refuse to run against your real library: point them at a
    throwaway one with MEDIAFIN_CONFIG_DIR, or pass --demo.

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
        case "--press-convert":
            options.mode = .pressConvert
        case "--press-clear-history":
            options.mode = .pressClearHistory
        case "--press-check":
            options.mode = .pressCheck
        case "--drop":
            // Everything after --drop is a path, so this has to come last.
            let rest = Array(arguments[arguments.index(after: index)...])
            guard !rest.isEmpty else { fail("--drop needs at least one path", code: 64) }
            options.mode = .drop(paths: rest)
            index = arguments.endIndex
        case "--panel":
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else {
                fail("--panel needs a name: settings, status, fetch or convert",
                     code: 64)
            }
            options.panel = arguments[next]
            index = next
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
    /// How many times --press-convert has looked to see whether the encode
    /// has finished, so a hung FFmpeg fails CI instead of hanging it.
    static var convertTicks = 0
    /// Set by the snapshot callback; read after the main loop returns to decide
    /// the exit status. A GUI that silently fails to draw must not exit 0.
    static var failure: String?
}

/// How many proposals were on screen when the picture was taken.
private var capturedProposals = 0

// MARK: Run

private let options = parse(Array(CommandLine.arguments.dropFirst()))

// Before the engine exists, let alone a window: the guard is about not
// touching somebody's library, and `AppCoordinator`'s own startup reads and
// scans the configured folders. Refusing inside the mode's branch was too
// late to mean that.
switch options.mode {
case .pressConvert:
    refuseARealLibrary("--press-convert", doing: "re-encodes real video "
        + "files, which takes hours of CPU and fills the disk beside them")
case .pressClearHistory:
    refuseARealLibrary("--press-clear-history", doing: "renames everything "
        + "a scan proposes and then destroys the undo journal")
case .pressApply:
    refuseARealLibrary("--press-apply", doing: "writes the settings file")
case .interactive, .screenshot, .pressScan, .drop, .pressCheck:
    break
}

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

/// The smoke modes that move or re-encode real files refuse to run against
/// a real configuration.
///
/// `--press-clear-history` scans, renames everything the scan proposed, and
/// then clears the undo journal while answering its own confirmation
/// dialog "yes" from inside the process. It ships in the release binary and
/// it is in `--help`, so somebody reading that help could point it at their
/// own library and lose both the arrangement and the only record that could
/// put it back. CI already runs every one of these under a throwaway
/// MEDIAFIN_CONFIG_DIR, so asking for one costs the checks nothing and is
/// the whole difference for a curious user.
/// The engine's stored conversion settings, in one line, for the smoke
/// modes. Deliberately the engine's copy and not the widgets': the question
/// these checks ask is what reached the settings file.
private func describeConversion(_ c: WebConversionSettings) -> String {
    "codec=\(c.videoCodec.rawValue) quality=\(c.quality) "
        + "preset=\(c.preset.rawValue) "
        + "height=\(c.targetHeight.map(String.init) ?? "source") "
        + "ffmpeg=\(c.ffmpegPath)"
}

private func refuseARealLibrary(_ flag: String, doing what: String) {
    if options.demo { return }
    let chosen = ProcessInfo.processInfo.environment["MEDIAFIN_CONFIG_DIR"] ?? ""
    guard chosen.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    fail(flag + " " + what + ". Point it at a throwaway library first: "
            + "set MEDIAFIN_CONFIG_DIR to a directory you do not mind "
            + "losing, or add --demo.", code: 64)
}

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
    // Closing the window drops out of gtk_main and falls off the end of
    // main. The history's writes are coalesced with a trailing write, which
    // is no use to a process that is already gone.
    coordinator.flushToDisk()

case .pressScan:
    // Two timeouts, not one. The first lets GTK finish laying the window out
    // -- pressing a button that has not been allocated yet is not the thing
    // under test -- and the second gives the engine time to answer on its own
    // queue and the window's own refresh time to pick that answer up.
    let press: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        print("scan button available: \(mainWindow.scanButtonIsAvailable)")
        // Checked here because this mode already looks at the main surface,
        // and because the window now has three panels full of buttons: the
        // fault this guards against is a control sliding into one of them
        // and only being noticed by somebody who needed it urgently.
        print("urgent buttons on main surface: "
                  + "\(mainWindow.urgentButtonsAreOnTheMainSurface)")
        mainWindow.pressScan()
        let report: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
            defer { gtk_main_quit() }
            mainWindow.refresh()
            let status = mainWindow.statusText
            print("status: \(status)")
            print("lamp bar: \(mainWindow.lampBarText)")
            print("middle: \(mainWindow.emptyListText)")
            print("proposals: \(coordinator.items.count)")
            // Off the rows, like the drop mode does. Without these the
            // assertions about what Scan proposed have nothing to read and
            // pass by finding nothing, which is the failure mode this whole
            // mode exists to stop.
            for destination in mainWindow.destinationTexts {
                print("destination: \(destination)")
            }
            print("deletion notes: \(mainWindow.deletionTexts.count)")
            for note in mainWindow.deletionTexts {
                print("deletes: \(note)")
            }
            // Printed beside the deletions, because the assertion that
            // matters is about the pair: the group's note goes, Jellyfin's
            // own metadata stays, and the row says both.
            print("kept notes: \(mainWindow.keptNoteTexts.count)")
            for note in mainWindow.keptNoteTexts {
                print("keeps: \(note)")
            }
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

case .pressConvert:
    // Three stages, for the reason pressScan has two: GTK has to lay the
    // panel out before a button can be pressed, the engine answers on its
    // own queue, and FFmpeg takes as long as it takes.
    let look: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        mainWindow.openConverting()
        mainWindow.refresh()
        print("convert bar before: \(mainWindow.convertBarText)")
        // Before anything is searched for, the list has to SAY it has not
        // searched yet. It shipped drawing nothing at all: the first
        // refresh compared an empty id list against an empty id list,
        // decided nothing had changed and never built the empty state, so
        // the panel looked like a working one with no files in it.
        for line in mainWindow.convertListTexts {
            print("convert list before: \(line)")
        }
        // Stopp first, while nothing is running. The engine deliberately
        // refuses to arm its cancel flag with no run to apply it to --
        // "otherwise a stray press while idle would sit there and stop the
        // next run the user asks for" -- and a rule with no caller is a
        // rule nobody has watched work. The conversion below must still
        // happen after this press.
        // Read before the press, because the press is through the widget
        // now and `gtk_button_clicked` fires whether the button is grey or
        // not -- so the sensitivity is the part worth printing. Nothing is
        // converting here, so the panel's Stopp must be grey; during the
        // run below it must not be. The line this replaces said "pressed
        // stop while idle: yes" and said it unconditionally.
        print("stop pressable while idle: \(mainWindow.convertStopIsPressable)")
        mainWindow.pressStopConverting()
        mainWindow.pressFindConvertible()

        let tick: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
            mainWindow.refresh()
            print("convertible found: \(coordinator.convertible.count)")
            print("convert rows: \(mainWindow.convertRowCount)")
            print("convert counts: \(mainWindow.convertCountText)")
            print("ticked: \(mainWindow.tickedConvertCount)")
            // What the panel says after a search, which for an empty result
            // used to be the never-searched sentence -- a panel identical
            // to the one the user opened, telling them to press the button
            // they just pressed.
            for line in mainWindow.convertListTexts {
                print("convert list after search: \(line)")
            }
            // Untick the first one. The assertion worth making about a tick
            // is that pressing the widget changes what the engine is asked
            // to convert, and that can only be checked through the widget.
            if mainWindow.pressConvertRowCheck(at: 0) {
                print("after untick, counts: \(mainWindow.convertCountText)")
                print("after untick, ticked: \(mainWindow.tickedConvertCount)")
            } else {
                Pending.failure = "the conversion list drew no row to untick"
            }

            // Search again before converting. A fresh search builds fresh
            // candidates with fresh UUIDs, so the window holds the user's
            // exclusions by PATH -- and the promise that a second Suchen
            // does not undo what you took out is worth a check rather than
            // a comment.
            mainWindow.pressFindConvertible()
            let afterSecond: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
                mainWindow.refresh()
                print("after second search, ticked: "
                          + "\(mainWindow.tickedConvertCount)")
                mainWindow.pressConvert()
                return Gtk.sourceRemove
            }
            g_timeout_add(2000, afterSecond, nil)

            // Polled, because an encode has no fixed duration. The deadline
            // is what stops a hung FFmpeg from hanging CI instead of
            // failing it. It starts before the second search so the poll is
            // already running when that search's conversion begins.
            let wait: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
                mainWindow.refresh()
                Pending.convertTicks += 1
                let state = coordinator.snapshot
                if state.converting {
                    print("converting: \(mainWindow.convertBarText)")
                    // The other direction of the same gate: a Stopp that is
                    // grey while a 40-minute encode runs is the fault that
                    // matters, and "grey while idle" alone cannot tell it
                    // apart from a button that is never pressable.
                    print("stop pressable while converting: "
                              + "\(mainWindow.convertStopIsPressable)")
                    // The other half of the percentage rule: a job that
                    // DOES measure itself must still say so. The check in
                    // --press-check covers the silent side, where the
                    // header used to print a stale 100 %.
                    print("converting subtitle: \(mainWindow.subtitleText)")
                    return Gtk.sourceContinue
                }
                // Not merely "not converting": that is also true in the
                // moment before the engine takes the command off its queue,
                // and quitting there would report success having waited for
                // nothing. The result line is the engine saying it is done.
                let status = mainWindow.statusText
                // "Konvertiert" only: the search's own result line says how
                // many files could be converted, and treating that as the
                // end would report success before anything was encoded.
                let finished = status.contains("Konvertiert")
                    || status.contains("Converted")
                    || status.contains("FFmpeg")
                    || status.contains("ffmpeg")
                if !finished, Pending.convertTicks < 120 {
                    return Gtk.sourceContinue
                }
                print("convert status: \(status)")
                for line in mainWindow.convertListTexts {
                    print("convert list after run: \(line)")
                }
                print("convert bar after: \(mainWindow.convertBarText)")
                print("convertible left: \(coordinator.convertible.count)")
                // The library as it stands between the two runs, because
                // that is the only moment "the file taken out of the run
                // was left alone" is true: the second run below converts it
                // on purpose, so a check made after the process exits reads
                // the wrong state. The shell assertion that did exactly
                // that is what failed CI run 194.
                let folder = coordinator.settings.moviesFolder
                let held = (try? FileManager.default
                    .contentsOfDirectory(atPath: folder)) ?? []
                for name in held.sorted() {
                    print("after the first run, library holds: \(name)")
                }
                if !finished {
                    Pending.failure = "the conversion never finished: " + status
                    gtk_main_quit()
                    return Gtk.sourceRemove
                }

                // One more run, with everything ticked, so the list empties.
                //
                // Two things only this can see. An emptied list is the third
                // empty state, and all three used to draw "Noch nichts
                // gesucht — „Suchen" drücken.", so a finished run left a
                // panel that denied it had happened. And a run whose
                // candidates have all gone takes the `pending.isEmpty`
                // branch, which announced "Es war nichts angehakt, also
                // wurde nichts konvertiert." over the top of a run that had
                // just encoded everything -- that branch is now only for a
                // genuinely empty tick set.
                mainWindow.pressTickEverything()
                print("after Alle, ticked: \(mainWindow.tickedConvertCount)")
                mainWindow.pressConvert()
                Pending.convertTicks = 0
                let second: @convention(c) (UnsafeMutableRawPointer?)
                    -> gboolean = { _ in
                    mainWindow.refresh()
                    Pending.convertTicks += 1
                    let state = coordinator.snapshot
                    if state.converting { return Gtk.sourceContinue }
                    let done = mainWindow.statusText
                    let over = done.contains("Konvertiert")
                        || done.contains("Converted")
                    if !over, Pending.convertTicks < 120 {
                        return Gtk.sourceContinue
                    }
                    defer { gtk_main_quit() }
                    print("second run status: \(done)")
                    print("convertible after the second run: "
                              + "\(coordinator.convertible.count)")
                    for line in mainWindow.convertListTexts {
                        print("convert list when empty: \(line)")
                    }
                    if !over {
                        Pending.failure = "the second conversion never "
                            + "finished: " + done
                    }
                    return Gtk.sourceRemove
                }
                g_timeout_add(500, second, nil)
                return Gtk.sourceRemove
            }
            g_timeout_add(500, wait, nil)
            return Gtk.sourceRemove
        }
        g_timeout_add(2500, tick, nil)
        return Gtk.sourceRemove
    }
    g_timeout_add(400, look, nil)
    gtk_main()

    if let failure = Pending.failure {
        fail(failure, code: 1)
    }

case .pressClearHistory:
    // A real rename first, so there is something to lose. With an empty
    // history "unchanged after Cancel" is 0 and 0, which proves nothing --
    // the mode has to make the history it then tries to clear.
    let fill: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        mainWindow.pressScan()
        let rename: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
            mainWindow.refresh()
            print("proposals: \(coordinator.items.count)")
            mainWindow.applySelected()
            return Gtk.sourceRemove
        }
        g_timeout_add(2500, rename, nil)
        return Gtk.sourceRemove
    }
    g_timeout_add(400, fill, nil)

    let clear: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        mainWindow.refresh()
        print("history before: \(coordinator.logEntries.count)")
        print("undo steps before: \(coordinator.snapshot.undoableBatches)")

        // The answer is arranged before the button is pressed, because the
        // handler blocks inside gtk_dialog_run. A timeout still fires there:
        // GTK keeps its own loop running, which is the whole point of that
        // call.
        let sayNo: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
            if !Gtk.answerDialog(accept: false) {
                // No dialog on screen means the button did not ask. That is
                // the fault this mode exists to catch, so it is a failure
                // and not a quiet pass.
                Pending.failure = "pressing Leeren asked nothing before clearing"
                gtk_main_quit()
            }
            return Gtk.sourceRemove
        }
        g_timeout_add(300, sayNo, nil)
        mainWindow.pressClearHistory()

        // Read on a later turn, not here. `submit` only queues: the engine
        // works on its own queue, so a count read the instant the handler
        // returns is the count from before the command was even seen. The
        // first version of this printed "history after cancel: 1" with the
        // confirmation's answer ignored entirely -- a check that could not
        // fail, which is the exact fault this whole mode exists to catch.
        let afterCancel: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
            mainWindow.refresh()
            print("history after cancel: \(coordinator.logEntries.count)")
            print("undo steps after cancel: "
                      + "\(coordinator.snapshot.undoableBatches)")

            let sayYes: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
                if !Gtk.answerDialog(accept: true) {
                    Pending.failure = "the second press asked nothing"
                    gtk_main_quit()
                }
                return Gtk.sourceRemove
            }
            g_timeout_add(300, sayYes, nil)
            mainWindow.pressClearHistory()

            let report: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
                defer { gtk_main_quit() }
                mainWindow.refresh()
                print("history after confirm: \(coordinator.logEntries.count)")
                print("undo steps after: \(coordinator.snapshot.undoableBatches)")
                print("status: \(mainWindow.statusText)")
                return Gtk.sourceRemove
            }
            g_timeout_add(1500, report, nil)
            return Gtk.sourceRemove
        }
        g_timeout_add(1500, afterCancel, nil)
        return Gtk.sourceRemove
    }
    g_timeout_add(5500, clear, nil)
    gtk_main()

    if let failure = Pending.failure {
        fail(failure, code: 1)
    }

case .pressCheck:
    let check: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        mainWindow.refresh()
        print("idle subtitle: \(mainWindow.subtitleText)")
        print("idle undo pressable: \(mainWindow.undoButtonIsPressable)")
        print("idle clear-history pressable: "
                  + "\(mainWindow.clearHistoryIsPressable)")
        mainWindow.pressCheckEverything()
        // Read with no refresh of our own in between, which is the whole
        // point. The gate lives in `refresh()`, and `refresh()` is called
        // by a 500 ms timer -- so until the press handler closed the gate
        // itself, every gated button stayed live for up to half a second
        // after the press that started the work. That window is where the
        // Rückgängig double-click landed, and the old check could not see
        // it because it called `refresh()` before looking.
        print("undo pressable straight after the press: "
                  + "\(mainWindow.undoButtonIsPressable)")
        print("clear-history pressable straight after the press: "
                  + "\(mainWindow.clearHistoryIsPressable)")

        // Read while the probe is still in flight. The engine's request
        // timeout is 30 seconds and Alles prüfen runs two probes, so a
        // second in is comfortably inside it.
        let during: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
            defer { gtk_main_quit() }
            mainWindow.refresh()
            let state = coordinator.snapshot
            print("during busy: \(state.busy)")
            print("during queued: \(state.queuedWork)")
            print("during subtitle: \(mainWindow.subtitleText)")
            print("during undo pressable: \(mainWindow.undoButtonIsPressable)")
            print("during clear-history pressable: "
                      + "\(mainWindow.clearHistoryIsPressable)")
            print("during scan pressable: \(mainWindow.scanButtonIsAvailable)")
            // If the probe has already finished, the run proves nothing and
            // must not pass: the whole point is to look at the window while
            // the queue is held.
            if state.queuedWork == 0 {
                Pending.failure = "the probe finished before the window was read, "
                    + "so nothing was observed in flight"
            }
            return Gtk.sourceRemove
        }
        g_timeout_add(1200, during, nil)
        return Gtk.sourceRemove
    }
    g_timeout_add(400, check, nil)
    gtk_main()

    if let failure = Pending.failure {
        fail(failure, code: 1)
    }

case let .drop(paths):
    let handOver: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        mainWindow.addDropped(Pending.dropPaths.map { URL(fileURLWithPath: $0) })
        let report: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
            mainWindow.refresh()
            print("proposals: \(coordinator.items.count)")
            for destination in mainWindow.destinationTexts {
                print("destination: \(destination)")
            }
            // Read off the row's own label: what matters about a deletion is
            // that the window said so before the button was pressed.
            print("deletion notes: \(mainWindow.deletionTexts.count)")
            for note in mainWindow.deletionTexts {
                print("deletes: \(note)")
            }
            // Printed beside the deletions, because the assertion that
            // matters is about the pair: the group's note goes, Jellyfin's
            // own metadata stays, and the row says both.
            print("kept notes: \(mainWindow.keptNoteTexts.count)")
            for note in mainWindow.keptNoteTexts {
                print("keeps: \(note)")
            }
            print("status: \(mainWindow.statusText)")
            // The tick box, pressed through the widget and then read back
            // out of the engine. The ticks used to live nowhere but the
            // widget, so an exclusion was lost the moment the list was
            // rebuilt and the file was renamed anyway. Asserted here rather
            // than in a unit test because only the widget can be pressed.
            print("ticked rows: \(mainWindow.tickedRowCount)")
            print("engine ready: \(coordinator.snapshot.ready)")
            if coordinator.items.isEmpty {
                Pending.failure = "the dropped files produced no proposal"
            }
            // The press, and then a second tick of the loop before reading
            // the engine: the command goes onto the coordinator's serial
            // queue, so reading straight afterwards reads the old answer.
            // Which is how the first version of this check reported
            // "ticked rows: 1, engine ready: 2" and looked like a bug.
            mainWindow.pressRowCheck(at: 0)
            let afterUntick: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
                defer { gtk_main_quit() }
                mainWindow.refresh()
                print("after untick, ticked rows: \(mainWindow.tickedRowCount)")
                print("after untick, engine ready: \(coordinator.snapshot.ready)")
                if mainWindow.tickedRowCount != coordinator.snapshot.ready {
                    Pending.failure = "the window shows "
                        + "\(mainWindow.tickedRowCount) ticked rows and the engine "
                        + "says \(coordinator.snapshot.ready) are ready"
                }
                return Gtk.sourceRemove
            }
            g_timeout_add(1000, afterUntick, nil)
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
        // Before the first Apply: what the window made of the stored
        // settings. A card wired to nothing prints the defaults here.
        print("conversion read: \(mainWindow.conversionText)")
        print("media server read: \(mainWindow.mediaServerText)")
        print("estimate: \(mainWindow.estimateText)")
        print("apply button on screen: \(mainWindow.applyButtonIsOnScreen)")
        mainWindow.pressApply()
        // Straight after the press, before the engine can have written
        // anything. The window used to print "Übernommen um HH:MM:SS" here,
        // which is a claim about a file nothing had touched yet -- and it
        // stayed on screen when the write then failed.
        print("applied the instant it was pressed: \(mainWindow.appliedText)")
        // A second press a second later. The question is not whether the
        // label has text -- it is whether pressing again is visibly a second
        // press, which is the thing a fixed "Saved." cannot show.
        let again: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
            // Now that the engine has had its turn.
            mainWindow.refresh()
            print("applied once: \(mainWindow.appliedText)")
            mainWindow.pressApply()
            print("applied twice: \(mainWindow.appliedText)")
            // After two saves: still what was stored. Apply must hand back
            // what it was given, not a default it invented along the way.
            print("conversion after apply: \(mainWindow.conversionText)")

            // Now the refused Apply, which had two faults sitting in it.
            //
            // Two edits in one press: a codec the user means to keep, and a
            // quality with a typo in it. The engine refuses the WHOLE write
            // when anything is wrong, and the window used to carry on
            // regardless -- it printed "Übernommen um HH:MM:SS" for a save
            // that never happened, and it advanced its merge baseline to
            // the values it had just failed to write. The merge writes back
            // only fields whose widget differs from that baseline, so on
            // the corrected retry the codec compared equal to the baseline
            // and was silently dropped: one typo lost the other edit made
            // in the same breath. The engine kept h265.
            guard mainWindow.chooseCodecRow(1) else {
                Pending.failure = "the codec combo has no second row"
                gtk_main_quit()
                return Gtk.sourceRemove
            }
            mainWindow.typeQuality("24p")
            mainWindow.refresh()
            print("estimate with a typo: \(mainWindow.estimateText)")
            mainWindow.pressApply()
            print("refused apply says: \(mainWindow.appliedText)")

            let corrected: @convention(c) (UnsafeMutableRawPointer?)
                -> gboolean = { _ in
                print("engine after the refusal: "
                          + "\(describeConversion(coordinator.settings.conversion))")
                // Correct only the quality. The codec must survive.
                mainWindow.typeQuality("24")
                mainWindow.pressApply()
                print("corrected apply says: \(mainWindow.appliedText)")

                let settled: @convention(c) (UnsafeMutableRawPointer?)
                    -> gboolean = { _ in
                    mainWindow.refresh()
                    print("corrected apply settles as: \(mainWindow.appliedText)")
                    print("engine after the retry: "
                              + "\(describeConversion(coordinator.settings.conversion))")

                    // The other half of the same fault: a write the engine
                    // ACCEPTS and then cannot perform.
                    //
                    // The window only ever saw `problems()`; a failing disk
                    // write -- read-only configuration directory, full
                    // disk, settings.json replaced by a directory -- left
                    // "Übernommen um HH:MM:SS" on screen with the engine's
                    // own "nicht gespeichert" on the window behind the
                    // panel. And the merge baseline had advanced to values
                    // that were never stored, so the next press compared
                    // every edit equal to that baseline and dropped it: the
                    // edit was lost for good, correction included.
                    //
                    // A directory where settings.json goes cannot be
                    // renamed over, which fails the write for root too.
                    let file = configDirectory
                        .appendingPathComponent("settings.json")
                    try? FileManager.default.removeItem(at: file)
                    try? FileManager.default.createDirectory(
                        at: file, withIntermediateDirectories: true)
                    mainWindow.typeQuality("26")
                    mainWindow.pressApply()

                    let blocked: @convention(c) (UnsafeMutableRawPointer?)
                        -> gboolean = { _ in
                        mainWindow.refresh()
                        print("apply onto an unwritable file says: "
                                  + "\(mainWindow.appliedText)")
                        print("engine after the unwritable write: "
                                  + "\(describeConversion(coordinator.settings.conversion))")
                        // Writable again, and the SAME edit pressed again.
                        // It has to arrive: that is what a baseline which
                        // never moved buys.
                        let file = configDirectory
                            .appendingPathComponent("settings.json")
                        try? FileManager.default.removeItem(at: file)
                        mainWindow.pressApply()

                        let recovered: @convention(c) (UnsafeMutableRawPointer?)
                            -> gboolean = { _ in
                            defer { gtk_main_quit() }
                            mainWindow.refresh()
                            print("apply once the file is writable again says: "
                                      + "\(mainWindow.appliedText)")
                            print("engine after the file came back: "
                                      + "\(describeConversion(coordinator.settings.conversion))")
                            return Gtk.sourceRemove
                        }
                        g_timeout_add(900, recovered, nil)
                        return Gtk.sourceRemove
                    }
                    g_timeout_add(900, blocked, nil)
                    return Gtk.sourceRemove
                }
                g_timeout_add(900, settled, nil)
                return Gtk.sourceRemove
            }
            g_timeout_add(900, corrected, nil)
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
    if let name = options.panel {
        guard let panel = mainWindow.panelNamed(name) else {
            fail("unknown panel \(name): try settings, status, fetch or convert",
                 code: 64)
        }
        // The panel is its own toplevel, so the capture is pointed at it
        // rather than at the window behind it.
        Pending.window = panel
    }
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
