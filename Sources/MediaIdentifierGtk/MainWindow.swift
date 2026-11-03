import CGtk3
import Foundation
import MediaIdentifierCore

/// The front-end's main window.
///
/// At this stage it exists to prove the whole chain works: Swift talking to
/// GTK3's C API, the window laying itself out, and `MediaIdentifierCore`
/// linking into the same binary and answering questions. The facts shown below
/// are read from Core at runtime rather than hard-coded, so a blank or wrong
/// panel in the screenshot means a real failure rather than a stale string.
struct MainWindow {
    let widget: UnsafeMutablePointer<GtkWidget>

    init() {
        let window = gtk_window_new(GTK_WINDOW_TOPLEVEL)!
        gtk_window_set_title(Gtk.window(window), "Mediafin")
        gtk_window_set_default_size(Gtk.window(window), 760, 420)

        let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        gtk_container_set_border_width(Gtk.container(column), 24)
        gtk_container_add(Gtk.container(window), column)

        gtk_box_pack_start(Gtk.box(column), Self.heading("Mediafin"), 0, 0, 0)
        gtk_box_pack_start(Gtk.box(column), Self.body(Self.subtitle), 0, 0, 0)

        let separator = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)!
        gtk_box_pack_start(Gtk.box(column), separator, 0, 0, 6)

        // Read once: coreFacts() probes the filesystem for FFmpeg.
        let facts = Self.coreFacts()
        for (index, line) in facts.enumerated() {
            // The last line names the FFmpeg path, which is worth copying.
            gtk_box_pack_start(Gtk.box(column),
                               Self.body(line, copyable: index == facts.count - 1),
                               0, 0, 0)
        }

        self.widget = window
    }

    private static let subtitle =
        "Native Oberfläche auf GTK3. Die Weboberfläche bleibt für den Fernzugriff bestehen."

    /// Facts read out of `MediaIdentifierCore`, so the window can only render
    /// them if the Core really is linked in and working.
    private static func coreFacts() -> [String] {
        let video = VideoFileTypes.videoExtensions.sorted()
        let ffmpeg = FFmpegLocator.locate()
        return [
            "Erkannte Videoformate: \(video.count) — \(video.joined(separator: ", "))",
            "Untertitel: \(VideoFileTypes.subtitleExtensions.sorted().joined(separator: ", "))",
            ffmpeg.map { "ffmpeg gefunden: \($0)" }
                ?? "ffmpeg nicht gefunden — Konvertieren bleibt deaktiviert.",
        ]
    }

    // MARK: Labels

    /// Pango markup rather than a CSS provider: one escaped string is less to
    /// get wrong than a stylesheet, and it needs no theme to take effect.
    /// The escaping lives in Core, where it is unit-tested without a display.
    private static func heading(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = gtk_label_new(nil)!
        gtk_label_set_markup(Gtk.label(label), PangoMarkup.span(text, size: "xx-large", weight: "bold"))
        gtk_label_set_xalign(Gtk.label(label), 0)
        return label
    }

    /// - Parameter copyable: makes the text selectable, for values a user may
    ///   want to paste elsewhere — a path, a token, a fingerprint.
    ///
    ///   Off by default. Making a label selectable also makes it focusable,
    ///   GTK gives focus to the first focusable widget when the window opens,
    ///   and a focused selectable label draws its text highlighted — so with
    ///   every line selectable the window opened with one paragraph looking as
    ///   though the user had dragged across it. Where selection is wanted,
    ///   keyboard focus is switched back off so the mouse can still select but
    ///   nothing is highlighted on open.
    private static func body(_ text: String,
                             copyable: Bool = false) -> UnsafeMutablePointer<GtkWidget> {
        let label = gtk_label_new(text)!
        gtk_label_set_xalign(Gtk.label(label), 0)
        gtk_label_set_line_wrap(Gtk.label(label), 1)
        if copyable {
            gtk_label_set_selectable(Gtk.label(label), 1)
            gtk_widget_set_can_focus(label, 0)
            gtk_label_select_region(Gtk.label(label), 0, 0)
        }
        return label
    }
}
