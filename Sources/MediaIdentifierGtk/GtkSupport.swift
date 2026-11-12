import CGtk3
import CMediafinGtk
import Foundation

/// The small amount of glue that direct C interop needs.
///
/// GTK's object system does its upcasts with C macros — `GTK_WINDOW(w)`,
/// `GTK_CONTAINER(w)` and so on. Macros are not imported into Swift, so the
/// casts have to be written out. They are safe for the same reason the macros
/// are: GObject guarantees that a subclass instance begins with its parent's
/// layout, so a `GtkWidget *` that really is a window can be read as a
/// `GtkWindow *`.
///
/// `g_signal_connect` is also a macro, wrapping `g_signal_connect_data`. Same
/// treatment.
enum Gtk {

    // MARK: Upcasts

    /// A widget pointer, viewed as the GObject every GTK type starts with.
    static func object(_ widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GObject> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GObject.self)
    }

    static func window(_ widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWindow> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkWindow.self)
    }

    static func container(_ widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkContainer> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkContainer.self)
    }

    static func box(_ widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkBox> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkBox.self)
    }

    static func label(_ widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkLabel> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkLabel.self)
    }

    static func entry(_ widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkEntry> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkEntry.self)
    }

    static func button(
        _ widget: UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GtkButton> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkButton.self)
    }

    static func comboBox(
        _ widget: UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GtkComboBox> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkComboBox.self)
    }

    static func comboBoxText(
        _ widget: UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GtkComboBoxText> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkComboBoxText.self)
    }

    static func expander(
        _ widget: UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GtkExpander> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkExpander.self)
    }

    static func progressBar(
        _ widget: UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GtkProgressBar> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkProgressBar.self)
    }

    /// Sets the bar and the words on it in one call, because a bar without a
    /// number on it only says "something is happening".
    static func setProgress(_ widget: UnsafeMutablePointer<GtkWidget>,
                            fraction: Double, text: String) {
        let bar = progressBar(widget)
        gtk_progress_bar_set_fraction(bar, min(max(fraction, 0), 1))
        gtk_progress_bar_set_show_text(bar, 1)
        gtk_progress_bar_set_text(bar, text)
    }

    /// The text in an entry. GTK owns the buffer, so this copies it and does
    /// not free it — the usual mistake in both directions.
    static func text(of widget: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let raw = gtk_entry_get_text(entry(widget)) else { return "" }
        return String(cString: raw)
    }

    static func setText(of widget: UnsafeMutablePointer<GtkWidget>, _ value: String) {
        gtk_entry_set_text(entry(widget), value)
    }

    static func toggleButton(
        _ widget: UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GtkToggleButton> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkToggleButton.self)
    }

    static func isChecked(_ widget: UnsafeMutablePointer<GtkWidget>) -> Bool {
        gtk_toggle_button_get_active(toggleButton(widget)) != 0
    }

    static func setChecked(_ widget: UnsafeMutablePointer<GtkWidget>, _ on: Bool) {
        gtk_toggle_button_set_active(toggleButton(widget), on ? 1 : 0)
    }

    static func headerBar(
        _ widget: UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GtkHeaderBar> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkHeaderBar.self)
    }

    static func scrolledWindow(
        _ widget: UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GtkScrolledWindow> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkScrolledWindow.self)
    }

    /// `OpaquePointer`, unlike the casts above.
    ///
    /// GtkFileChooser is a GInterface, not a class: the header declares
    /// `struct _GtkFileChooser` and never defines it. Swift imports a pointer
    /// to an incomplete C type as an OpaquePointer, so there is no
    /// `GtkFileChooser` type to bind memory to — `assumingMemoryBound` does
    /// not compile here.
    static func fileChooser(_ widget: UnsafeMutablePointer<GtkWidget>) -> OpaquePointer {
        OpaquePointer(widget)
    }

    // MARK: Text

    static func setText(_ widget: UnsafeMutablePointer<GtkWidget>, _ text: String) {
        gtk_label_set_text(label(widget), text)
    }

    static func setMarkup(_ widget: UnsafeMutablePointer<GtkWidget>, _ markup: String) {
        gtk_label_set_markup(label(widget), markup)
    }

    /// The folder a chooser is showing, or "" when none is set.
    ///
    /// GTK hands back a string it allocated, which the caller owns. Forgetting
    /// the `g_free` leaks a little on every poll, which is exactly the kind of
    /// thing that never shows up in a test.
    static func chosenFolder(_ widget: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let raw = gtk_file_chooser_get_filename(fileChooser(widget)) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    static func setChosenFolder(_ widget: UnsafeMutablePointer<GtkWidget>, _ path: String) {
        guard !path.isEmpty else { return }
        gtk_file_chooser_set_filename(fileChooser(widget), path)
    }

    // MARK: Signals

    /// `g_signal_connect`, which is a macro in C.
    ///
    /// The handler is a C function pointer, so it cannot capture Swift state.
    /// Anything it needs has to arrive through `data` or live at file scope.
    @discardableResult
    static func connect(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ signal: String,
        _ handler: GCallback,
        data: UnsafeMutableRawPointer? = nil
    ) -> gulong {
        g_signal_connect_data(object(widget), signal, handler, data, nil, GConnectFlags(rawValue: 0))
    }

    /// Connects a button to a method on `owner`.
    ///
    /// This is the shape every GTK binding has to invent, because a C function
    /// pointer cannot close over anything. What the handler needs is put in an
    /// `Action` and passed through GTK's `user_data` as an opaque pointer.
    ///
    /// The Action is retained for GTK and released by the closure-notify GTK
    /// calls when the signal goes, so its lifetime is GTK's rather than
    /// something this code has to track. It holds the owner weakly, so this
    /// creates no cycle and no reference that outlives the window.
    static func onClick<Owner: AnyObject>(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ owner: Owner,
        _ action: @escaping (Owner) -> Void
    ) {
        // The owner is captured here, in an ordinary Swift closure, and only
        // the non-generic Action crosses into C. A @convention(c) closure may
        // not mention a generic parameter at all — not even inside
        // Unmanaged<Box<Owner>> — because there is nowhere in a bare function
        // pointer to put the type metadata.
        let payload = Unmanaged.passRetained(Action(owner: owner, action: action)).toOpaque()
        let handler: @convention(c) (UnsafeMutablePointer<GtkWidget>?,
                                     UnsafeMutableRawPointer?) -> Void = { _, data in
            guard let data else { return }
            Unmanaged<Action>.fromOpaque(data).takeUnretainedValue().run()
        }
        let release: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?)
            -> Void = { data, _ in
                guard let data else { return }
                Unmanaged<Action>.fromOpaque(data).release()
            }
        g_signal_connect_data(object(widget), "clicked",
                              unsafeBitCast(handler, to: GCallback.self),
                              payload, release, GConnectFlags(rawValue: 0))
    }

    /// Makes a widget accept files dragged from a file manager.
    ///
    /// The C side does the GTK half; this only turns the paths it reports into
    /// URLs. Same ownership dance as `onClick`: the owner is captured in an
    /// ordinary Swift closure and only the non-generic `Drop` crosses into C,
    /// because a @convention(c) function has nowhere to put type metadata.
    static func onFilesDropped<Owner: AnyObject>(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ owner: Owner,
        _ action: @escaping (Owner, [URL]) -> Void
    ) {
        let payload = Unmanaged.passRetained(Drop(owner: owner, action: action)).toOpaque()
        let received: @convention(c) (UnsafePointer<UnsafePointer<CChar>?>?,
                                      UnsafeMutableRawPointer?) -> Void = { paths, data in
            guard let paths, let data else { return }
            var urls: [URL] = []
            var index = 0
            while let path = paths[index] {
                urls.append(URL(fileURLWithPath: String(cString: path)))
                index += 1
            }
            guard !urls.isEmpty else { return }
            Unmanaged<Drop>.fromOpaque(data).takeUnretainedValue().run(urls)
        }
        let release: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
            guard let data else { return }
            Unmanaged<Drop>.fromOpaque(data).release()
        }
        mediafin_accept_file_drops(widget, received, payload, release)
    }

    /// Runs `action` on `owner` every `milliseconds` for as long as the main
    /// loop runs. Used to pull the engine's current state into the window:
    /// the work happens on the coordinator's own queue, so the interface has
    /// to ask rather than be told.
    static func repeating<Owner: AnyObject>(
        _ milliseconds: UInt32,
        _ owner: Owner,
        _ action: @escaping (Owner) -> Void
    ) {
        let payload = Unmanaged.passRetained(Action(owner: owner, action: action)).toOpaque()
        let tick: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
            guard let data else { return Gtk.sourceRemove }
            Unmanaged<Action>.fromOpaque(data).takeUnretainedValue().run()
            return Gtk.sourceContinue
        }
        let release: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
            guard let data else { return }
            Unmanaged<Action>.fromOpaque(data).release()
        }
        // _full rather than g_timeout_add: it takes the destroy notify that
        // frees the box, so the timer does not leak it when the source goes.
        // The priority is G_PRIORITY_DEFAULT, a macro Swift does not import.
        g_timeout_add_full(0, milliseconds, tick, payload, release)
    }

    /// Calls `action` for every key pressed on `widget`, with the keyval.
    ///
    /// `action` returns true when it handled the key, which stops GTK passing
    /// it on — so an entry that has the focus still gets every key this
    /// does not claim.
    static func onKeyPress<Owner: AnyObject>(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ owner: Owner,
        _ action: @escaping (Owner, UInt32) -> Bool
    ) {
        // The same shape as onClick, and for the same reason: the generic
        // part stays in this Swift closure and only the non-generic box
        // crosses into C.
        let payload = Unmanaged.passRetained(KeyAction(owner: owner, action: action)).toOpaque()
        let handler: @convention(c) (UnsafeMutablePointer<GtkWidget>?,
                                     UnsafeMutablePointer<GdkEventKey>?,
                                     UnsafeMutableRawPointer?) -> gboolean = { _, event, data in
            guard let data, let event else { return 0 }
            return Unmanaged<KeyAction>.fromOpaque(data)
                .takeUnretainedValue().run(event.pointee.keyval) ? 1 : 0
        }
        let release: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?)
            -> Void = { data, _ in
                guard let data else { return }
                Unmanaged<KeyAction>.fromOpaque(data).release()
            }
        g_signal_connect_data(object(widget), "key-press-event",
                              unsafeBitCast(handler, to: GCallback.self),
                              payload, release, GConnectFlags(rawValue: 0))
    }

    /// `Action`, but for a key: it takes the keyval and answers whether it
    /// consumed it.
    final class KeyAction {
        private let body: (UInt32) -> Bool

        init<Owner: AnyObject>(owner: Owner,
                               action: @escaping (Owner, UInt32) -> Bool) {
            body = { [weak owner] key in
                guard let owner else { return false }
                return action(owner, key)
            }
        }

        func run(_ key: UInt32) -> Bool { body(key) }
    }

    /// What a GTK callback is handed through `user_data`: one object, no
    /// generic parameters.
    ///
    /// Not generic on purpose. A `@convention(c)` closure is a bare function
    /// pointer with nowhere to carry type metadata, so it cannot name a
    /// generic type — `Unmanaged<Box<Owner>>` inside the callback is rejected
    /// even though nothing of `Owner` is used at runtime. The generic part
    /// stays outside, in the ordinary Swift closure that captures the owner.
    /// Carries dropped files back into Swift, as `Action` does for a click.
    /// Separate because a drop hands something over and a click does not.
    final class Drop {
        private let body: ([URL]) -> Void

        /// Weakly, for the same reason as `Action`: a drop can still arrive
        /// while the window is being torn down.
        init<Owner: AnyObject>(owner: Owner,
                               action: @escaping (Owner, [URL]) -> Void) {
            body = { [weak owner] urls in
                guard let owner else { return }
                action(owner, urls)
            }
        }

        func run(_ urls: [URL]) { body(urls) }
    }

    final class Action {
        private let body: () -> Void

        /// Holds the owner weakly: a click or a timer tick can still arrive
        /// while the window is being torn down.
        init<Owner: AnyObject>(owner: Owner, action: @escaping (Owner) -> Void) {
            body = { [weak owner] in
                guard let owner else { return }
                action(owner)
            }
        }

        func run() { body() }
    }

    // MARK: GLib main loop

    /// Returned by a `GSourceFunc` to run once and not be called again.
    ///
    /// `G_SOURCE_REMOVE` is a macro expanding to another macro (`FALSE`), which
    /// Swift does not import, so the value is written out.
    static let sourceRemove: gboolean = 0

    /// Returned by a `GSourceFunc` to stay scheduled.
    static let sourceContinue: gboolean = 1
}
