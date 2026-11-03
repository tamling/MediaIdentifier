import Foundation

/// Escaping for text interpolated into the served HTML.
///
/// One implementation on purpose. There used to be two — the router's, which
/// escaped all five entities, and a second one inside the status page that
/// escaped only `&`, `<` and `>`. The weaker one was the one applied to
/// filenames. Nothing could be injected through it as written, because every
/// value it handled landed in element text, but the two were free to drift and
/// the next person to add a `title="…"` to that page would have had no reason
/// to suspect its escaper was not the real one.
public enum HTML {

    /// Escapes the five entities XML predefines, which is what both element
    /// text and a quoted attribute value need.
    ///
    /// `'` becomes `&#39;` rather than `&apos;`: the named form is not defined
    /// in HTML 4 and is mishandled by some older parsers, while the numeric
    /// form is understood everywhere.
    public static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }
}
