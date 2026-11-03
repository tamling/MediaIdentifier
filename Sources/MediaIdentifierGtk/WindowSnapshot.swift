import CGtk3
import Foundation

/// Renders a widget to a PNG.
///
/// This exists because of a testing problem: the GTK front-end is developed
/// without a screen to look at, so "it builds" is the only thing a compiler can
/// tell us, and that says nothing about whether the window actually draws.
/// Rendering to a file turns the interface into something CI can produce and a
/// person can inspect.
///
/// It deliberately does *not* go through `gdk_pixbuf_get_from_window`, the
/// obvious route. That reads back pixels the X server already holds, so it
/// needs the window mapped and composited and returns NULL under a bare Xvfb
/// often enough to be useless. `gtk_widget_draw` instead asks the widget to
/// paint itself into a surface we own, which works headless and gives the same
/// pixels every run.
enum WindowSnapshot {

    enum Failure: Error, CustomStringConvertible {
        case notRealized
        case zeroSize(width: Int32, height: Int32)
        case surfaceFailed
        case writeFailed(status: String)

        var description: String {
            switch self {
            case .notRealized:
                return "the widget has not been realized yet, so it has nothing to draw"
            case let .zeroSize(width, height):
                return "the widget measures \(width)x\(height); it has not been laid out yet"
            case .surfaceFailed:
                return "cairo could not create an image surface"
            case let .writeFailed(status):
                return "cairo could not write the PNG: \(status)"
            }
        }
    }

    /// Draws `widget` into a PNG at `path`.
    ///
    /// Call it only after the widget has been shown and the main loop has run
    /// at least once; before that GTK has not assigned it a size.
    static func write(_ widget: UnsafeMutablePointer<GtkWidget>, to path: String) throws {
        guard gtk_widget_get_realized(widget) != 0 else { throw Failure.notRealized }

        let width = gtk_widget_get_allocated_width(widget)
        let height = gtk_widget_get_allocated_height(widget)
        // GTK reports 1x1 for a widget it has not laid out, which would write a
        // technically valid PNG that shows nothing — worse than an error,
        // because it looks like a pass.
        guard width > 1, height > 1 else { throw Failure.zeroSize(width: width, height: height) }

        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height) else {
            throw Failure.surfaceFailed
        }
        defer { cairo_surface_destroy(surface) }

        guard let context = cairo_create(surface) else { throw Failure.surfaceFailed }
        defer { cairo_destroy(context) }

        // ARGB32 starts fully transparent, and a theme that paints no window
        // background would leave the PNG empty. White first means what lands in
        // the file is what a person would see.
        cairo_set_source_rgb(context, 1, 1, 1)
        cairo_paint(context)

        gtk_widget_draw(widget, context)
        cairo_surface_flush(surface)

        let status = cairo_surface_write_to_png(surface, path)
        guard status == CAIRO_STATUS_SUCCESS else {
            let text = String(cString: cairo_status_to_string(status))
            throw Failure.writeFailed(status: text)
        }
    }
}
