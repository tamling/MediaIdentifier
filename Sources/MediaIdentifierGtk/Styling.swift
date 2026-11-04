import CGtk3
import Foundation
import MediaIdentifierCore

/// The window's stylesheet.
///
/// GTK3 styles widgets with CSS, so the whole look is one string rather than a
/// pile of per-widget calls.
///
/// Unlike most GTK applications this one does **not** inherit the desktop
/// theme's colours. It paints Mediafin's own dark palette, the same one the
/// status page has always used, so the native window and the web interface
/// look like one product rather than two. The trade-off is real and worth
/// stating: on a carefully themed desktop this window will not match its
/// neighbours. `MEDIAFIN_GTK_THEME` turns it back into an ordinary themed
/// window for anyone who would rather have that.
///
/// Only widely supported properties are used. GTK's CSS is a subset of the
/// web's: no flexbox, no dependable `nth-child`, no shorthand the parser
/// silently drops. Anything exotic fails quietly and leaves the window
/// looking unstyled rather than broken, which is harder to notice.
enum Styling {

    static var css: String {
        """
        @define-color mf_bg \(Palette.background);
        @define-color mf_surface \(Palette.surface);
        @define-color mf_raised \(Palette.surfaceRaised);
        @define-color mf_border \(Palette.border);
        @define-color mf_text \(Palette.text);
        @define-color mf_muted \(Palette.textMuted);
        @define-color mf_ok \(Palette.ok);
        @define-color mf_busy \(Palette.busy);
        @define-color mf_error \(Palette.error);

        window, dialog, popover, menu {
          background-color: @mf_bg;
          color: @mf_text;
        }

        /* Flat, no gradient: the gradient is what makes a GTK3 window look
           like it was built a decade ago. */
        headerbar {
          background-image: none;
          background-color: @mf_surface;
          border-bottom: 1px solid @mf_border;
          box-shadow: none;
          min-height: 44px;
          padding: 0 8px;
          color: @mf_text;
        }
        headerbar .title { font-weight: 700; }
        headerbar .subtitle { color: @mf_muted; font-size: 9pt; }

        button {
          background-image: none;
          background-color: @mf_raised;
          color: @mf_text;
          border: 1px solid @mf_border;
          border-radius: 8px;
          padding: 6px 14px;
          text-shadow: none;
        }
        button:hover { background-color: shade(@mf_raised, 1.25); }
        button:active { background-color: shade(@mf_raised, 0.85); }
        button:disabled { color: @mf_muted; background-color: @mf_surface; }

        /* The primary action carries the palette's accent, and dark text on
           top of it because the accent is bright. */
        button.suggested-action {
          background-color: @mf_ok;
          color: \(Palette.onAccent);
          border-color: @mf_ok;
          font-weight: 700;
        }
        button.suggested-action:hover { background-color: shade(@mf_ok, 1.12); }
        button.suggested-action:disabled {
          background-color: @mf_surface;
          color: @mf_muted;
          border-color: @mf_border;
        }

        scrollbar { background-color: transparent; }
        scrollbar slider {
          background-color: alpha(@mf_text, 0.25);
          border: none;
          border-radius: 8px;
          min-width: 8px;
          min-height: 8px;
        }
        scrollbar slider:hover { background-color: alpha(@mf_text, 0.4); }

        /* A grouped panel. */
        .mf-card {
          background-color: @mf_surface;
          border: 1px solid @mf_border;
          border-radius: 14px;
          padding: 18px;
        }

        .mf-card-title {
          font-weight: 700;
          font-size: 9pt;
          color: @mf_muted;
        }

        .mf-dim {
          color: @mf_muted;
          font-size: 10pt;
        }

        /* One proposal. */
        .mf-row {
          padding: 9px 12px;
          border-radius: 8px;
        }

        /* Banding, applied from code: GTK's nth-child support is not
           dependable enough to do it here. */
        .mf-row-alt { background-color: @mf_raised; }

        /* The file as it is now — quieter than the name it will get, because
           the proposal is the thing being judged. */
        .mf-from {
          color: @mf_muted;
          font-size: 10pt;
        }

        .mf-to {
          color: @mf_text;
          font-weight: 600;
        }

        .mf-warn {
          color: @mf_busy;
          font-size: 10pt;
        }

        .mf-empty {
          color: @mf_muted;
          padding: 36px;
        }

        /* The log column. Separated by a hairline rather than a card, so it
           reads as a margin to the work and not as another panel of it. */
        .mf-log {
          background-color: @mf_surface;
          border-left: 1px solid @mf_border;
          padding: 14px;
        }

        .mf-log-entry {
          font-size: 9pt;
          padding: 4px 2px;
        }

        /* Status colours, from the same palette the web interface uses. */
        .mf-ok    { color: @mf_ok; }
        .mf-fail  { color: @mf_error; }
        .mf-skip  { color: @mf_muted; }

        /* Timestamps and the "to" name: present, but never competing with
           the error text, which is the reason anyone reads this column. */
        .mf-log-time { color: alpha(@mf_muted, 0.8); font-size: 8pt; }
        """
    }

    /// Name of the variable that turns the palette off.
    static let themeOverrideVariable = "MEDIAFIN_GTK_THEME"

    /// True when the user asked for their own desktop theme instead.
    static var isDisabled: Bool {
        let value = ProcessInfo.processInfo.environment[themeOverrideVariable] ?? ""
        return value == "system"
    }

    /// Installs the stylesheet for the whole application.
    ///
    /// Added at the application priority, which sits above the theme and below
    /// the user's own `gtk.css`, so someone who has styled their desktop still
    /// wins. The constant is `GTK_STYLE_PROVIDER_PRIORITY_APPLICATION`, a
    /// macro Swift does not import.
    static func install() {
        guard !isDisabled, let screen = gdk_screen_get_default() else { return }
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
