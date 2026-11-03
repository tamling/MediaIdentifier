import CGtk3
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
    /// pointer cannot close over anything. The owner is passed through GTK's
    /// `user_data` as an opaque pointer and read back on the other side.
    /// Unretained on purpose: the caller holds the only strong reference for
    /// the lifetime of the window, so retaining here would be a cycle GTK has
    /// no way to break.
    static func onClick<Owner: AnyObject>(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ owner: Owner,
        _ action: @escaping (Owner) -> Void
    ) {
        // The closure itself also cannot ride along in user_data, so it is
        // stored next to the owner in a box GTK frees when the signal goes.
        let box = Box(owner: owner, action: action)
        let payload = Unmanaged.passRetained(box).toOpaque()
        let handler: @convention(c) (UnsafeMutablePointer<GtkWidget>?,
                                     UnsafeMutableRawPointer?) -> Void = { _, data in
            guard let data else { return }
            Unmanaged<Box<Owner>>.fromOpaque(data).takeUnretainedValue().run()
        }
        let release: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?)
            -> Void = { data, _ in
                guard let data else { return }
                Unmanaged<Box<Owner>>.fromOpaque(data).release()
            }
        g_signal_connect_data(object(widget), "clicked",
                              unsafeBitCast(handler, to: GCallback.self),
                              payload, release, GConnectFlags(rawValue: 0))
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
        let payload = Unmanaged.passRetained(Box(owner: owner, action: action)).toOpaque()
        let tick: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
            guard let data else { return Gtk.sourceRemove }
            Unmanaged<Box<Owner>>.fromOpaque(data).takeUnretainedValue().run()
            return Gtk.sourceContinue
        }
        let release: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
            guard let data else { return }
            Unmanaged<Box<Owner>>.fromOpaque(data).release()
        }
        // _full rather than g_timeout_add: it takes the destroy notify that
        // frees the box, so the timer does not leak it when the source goes.
        // The priority is G_PRIORITY_DEFAULT, a macro Swift does not import.
        g_timeout_add_full(0, milliseconds, tick, payload, release)
    }

    /// Holds a weak owner and what to do with it, so both can be reached from
    /// a C callback through a single pointer.
    final class Box<Owner: AnyObject> {
        private weak var owner: Owner?
        private let action: (Owner) -> Void

        init(owner: Owner, action: @escaping (Owner) -> Void) {
            self.owner = owner
            self.action = action
        }

        /// Does nothing once the owner is gone — a click can still arrive
        /// while the window is being torn down.
        func run() {
            guard let owner else { return }
            action(owner)
        }
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
