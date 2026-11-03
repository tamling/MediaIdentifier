import Foundation

/// Escaping for Pango markup, GTK's inline styling language.
///
/// Pango markup is XML, so any text interpolated into it has to be escaped —
/// and the text that will be interpolated is filenames, which routinely
/// contain `&` and sometimes `<`. An unescaped ampersand does not merely look
/// wrong: Pango rejects the whole string as malformed and the label renders
/// empty, silently losing the one piece of information the row existed to
/// show.
///
/// It lives in Core rather than in the GTK front-end so it can be unit-tested
/// without a display, for the same reason the HTML escaping does.
public enum PangoMarkup {

    /// The five entities XML predefines. `&` must be replaced first, otherwise
    /// the ampersands introduced by the later replacements get escaped again
    /// and `<` turns into `&amp;lt;`.
    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }

    /// `text` wrapped in a span, escaped.
    ///
    /// Attribute values are escaped too. They are chosen in code today, but a
    /// span built from a stored setting later would otherwise be an injection
    /// point.
    public static func span(_ text: String, size: String? = nil, weight: String? = nil) -> String {
        var attributes = ""
        if let size { attributes += " size='\(escape(size))'" }
        if let weight { attributes += " weight='\(escape(weight))'" }
        return "<span\(attributes)>\(escape(text))</span>"
    }
}
