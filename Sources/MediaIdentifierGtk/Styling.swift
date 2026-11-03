import CGtk3
import Foundation

/// The window's stylesheet.
///
/// GTK3 styles widgets with CSS, so the whole look is one string rather than a
/// pile of per-widget calls. Two rules shape what is in here:
///
/// Colours are taken from the theme (`@theme_bg_color`, `@borders`, …) and
/// never written as literals. Mediafin runs on whatever desktop the user has
/// — Mint's Cinnamon with its own accent, a dark theme, a high-contrast theme
/// — and a hard-coded `#ffffff` is how an application ends up with white
/// panels and unreadable white text on someone else's dark desktop.
///
/// Only widely supported properties are used. GTK's CSS is a subset of the
/// web's: no flexbox, no `nth-child` worth relying on, no shorthand that the
/// parser silently drops. Anything exotic fails quietly and leaves the window
/// looking unstyled rather than broken, which is harder to notice.
enum Styling {

    static let css = """
    /* Secondary text: captions, counts, the last result. Alpha on the
       foreground colour rather than a grey, so it stays readable on a dark
       theme as well as a light one. */
    .mf-dim {
      color: alpha(@theme_fg_color, 0.6);
      font-size: 10pt;
    }

    /* A grouped panel. Matches what GTK's own settings dialogues do, so it
       looks native rather than drawn by us. */
    .mf-card {
      background-color: @theme_base_color;
      border: 1px solid alpha(@borders, 0.8);
      border-radius: 12px;
      padding: 14px;
    }

    .mf-card-title {
      font-weight: 700;
      font-size: 10pt;
      color: alpha(@theme_fg_color, 0.65);
    }

    /* One proposal. The padding is what makes a long list readable; the
       rounded corner only shows on the alternating rows below. */
    .mf-row {
      padding: 8px 10px;
      border-radius: 8px;
    }

    /* Banding, applied from code: GTK's nth-child support is not dependable
       enough to do it here. */
    .mf-row-alt {
      background-color: alpha(@theme_fg_color, 0.04);
    }

    /* The file as it is now — quieter than the name it will get, because the
       proposal is the thing being judged. */
    .mf-from {
      color: alpha(@theme_fg_color, 0.55);
      font-size: 10pt;
    }

    .mf-to {
      font-weight: 600;
    }

    /* A collision. Uses the theme's warning colour where one is defined. */
    .mf-warn {
      color: @warning_color;
      font-size: 10pt;
    }

    /* The empty state, centred and quiet so it reads as "nothing yet" rather
       than "something is broken". */
    .mf-empty {
      color: alpha(@theme_fg_color, 0.45);
      padding: 28px;
    }
    """

    /// Installs the stylesheet for the whole application.
    ///
    /// Added at the application priority, which sits above the theme and below
    /// the user's own `gtk.css`, so a user who has styled their desktop still
    /// wins. The constant is `GTK_STYLE_PROVIDER_PRIORITY_APPLICATION`, a
    /// macro Swift does not import.
    static func install() {
        guard let screen = gdk_screen_get_default() else { return }
        let provider = gtk_css_provider_new()
        var error: UnsafeMutablePointer<GError>?
        gtk_css_provider_load_from_data(provider, css, -1, &error)
        if let error {
            // Not fatal: an unstyled window is still a usable window, and
            // refusing to start over a stylesheet would be worse than the
            // thing it is complaining about.
            FileHandle.standardError.write(
                Data("mediafin-gtk: stylesheet ignored: \(String(cString: error.pointee.message))\n"
                    .utf8))
            g_error_free(error)
        }
        gtk_style_context_add_provider_for_screen(screen, OpaquePointer(provider), 600)
    }

    /// Adds a CSS class to a widget.
    static func style(_ widget: UnsafeMutablePointer<GtkWidget>, _ classes: String...) {
        let context = gtk_widget_get_style_context(widget)
        for name in classes { gtk_style_context_add_class(context, name) }
    }
}
