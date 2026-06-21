import Foundation

/// Extracts a release/air year from arbitrary date-ish text (e.g. "1999-03-31",
/// "2014-08-01T00:00:00Z"). Shared by the metadata providers so the heuristic
/// lives in one place.
public enum YearParser {
    private static let pattern = try? NSRegularExpression(pattern: #"(19|20)\d{2}"#)

    /// The first 19xx/20xx run in `string`, or nil if none is present.
    public static func firstYear(in string: String) -> Int? {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = pattern?.firstMatch(in: string, range: range),
              let r = Range(match.range, in: string) else { return nil }
        return Int(string[r])
    }
}
