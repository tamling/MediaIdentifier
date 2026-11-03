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

    // MARK: GLib main loop

    /// Returned by a `GSourceFunc` to run once and not be called again.
    ///
    /// `G_SOURCE_REMOVE` is a macro expanding to another macro (`FALSE`), which
    /// Swift does not import, so the value is written out.
    static let sourceRemove: gboolean = 0

    /// Returned by a `GSourceFunc` to stay scheduled.
    static let sourceContinue: gboolean = 1
}
