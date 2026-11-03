import Foundation

/// Mediafin's colours.
///
/// One definition, used by the status page and by the native window, so the
/// two cannot drift into looking like different programs. The values are the
/// ones the status page has had from the start — this moves them rather than
/// inventing a second scheme.
///
/// A dark palette fixed by the application rather than taken from the desktop
/// theme. That is a deliberate exception to the usual rule of inheriting the
/// user's theme: Mediafin shows video artwork and long file lists, where a
/// dark surface is easier to read for a long stretch, and a fixed palette
/// means the native window and the web interface look like one product on a
/// machine whose desktop is light. A user who disagrees can still override it
/// — see `MEDIAFIN_GTK_THEME` in the front-end.
public enum Palette {
    /// Window background: the surface everything else sits on.
    public static let background = "#16161a"
    /// A panel raised off the background.
    public static let surface = "#1e1e24"
    /// A panel raised off a panel — list banding, pressed buttons.
    public static let surfaceRaised = "#26262e"
    /// Hairlines between regions.
    public static let border = "#2a2a32"
    /// Body text.
    ///
    /// Four steps lighter per channel than the value the status page carried
    /// before, which measured 6.94 against the background — just short of the
    /// 7:1 that WCAG asks of body text. The difference is invisible; the point
    /// is that the test below can assert the real standard instead of a
    /// weaker one chosen to make it pass.
    public static let text = "#eaeaee"
    /// Captions, counts, anything secondary.
    public static let textMuted = "#8a8a92"

    /// Idle and success.
    public static let ok = "#36c98d"
    /// Working.
    public static let busy = "#f0a020"
    /// Failed.
    public static let error = "#e05a4f"

    /// Text drawn on top of `ok` — the accent is bright, so it needs a dark
    /// foreground rather than the usual light one.
    public static let onAccent = "#0c1a14"
}
