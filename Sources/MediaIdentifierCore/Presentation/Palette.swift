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

    /// The brand: the primary action, and the line around the window.
    ///
    /// Separate from `ok`, which it used to be. One colour cannot be both
    /// "this is the button you want" and "nothing is wrong": the three
    /// status colours above are a traffic light, and a traffic light whose
    /// green is also the accent has no spare meaning left. Keeping them
    /// apart is what lets the accent be red at all — beside an `error` that
    /// is also red, a red *success* would be unreadable.
    public static let accent = "#e30613"

    /// Text drawn on top of `accent`.
    ///
    /// White, at 4.88:1 — which the simplified luminance this project's test
    /// used would have got backwards. Leaving out the sRGB gamma step makes
    /// that formula claim black beats white on this red (5.23 against 4.02)
    /// when the real one says the opposite (4.30 against 4.88), so the
    /// measure would have chosen the harder foreground to read.
    public static let onAccent = "#ffffff"
}
