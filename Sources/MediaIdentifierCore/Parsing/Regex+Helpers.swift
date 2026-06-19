import Foundation

/// Lightweight wrapper around NSRegularExpression that keeps the parsing code
/// readable. Uses NSRegularExpression (rather than Swift `Regex`) so the core
/// stays compatible with older toolchains and Linux Foundation.
struct RX {
    let regex: NSRegularExpression

    init(_ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) {
        // Patterns are compile-time constants in this module; a bad pattern is a
        // programmer error, so trapping is acceptable here.
        // swiftlint:disable:next force_try
        self.regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// Returns the first match in `string`, if any.
    func firstMatch(in string: String) -> NSTextCheckingResult? {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.firstMatch(in: string, options: [], range: range)
    }

    /// All matches in `string`.
    func matches(in string: String) -> [NSTextCheckingResult] {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.matches(in: string, options: [], range: range)
    }
}

extension NSTextCheckingResult {
    /// Returns the captured group `index` as a `String`, or nil if it did not
    /// participate in the match.
    func group(_ index: Int, in string: String) -> String? {
        guard index < numberOfRanges else { return nil }
        let nsRange = range(at: index)
        guard nsRange.location != NSNotFound, let r = Range(nsRange, in: string) else {
            return nil
        }
        return String(string[r])
    }

    /// Captured group `index` as an `Int`.
    func intGroup(_ index: Int, in string: String) -> Int? {
        group(index, in: string).flatMap { Int($0) }
    }
}
