import Foundation

/// Parses raw release file names into structured `ParsedRelease` values.
///
/// Implements FR2 (release name analysis), FR4 (title), FR5 (year) and
/// FR6 (season / episode recognition). The parser is deliberately heuristic and
/// pure: it only looks at the file name string, never the file system.
public struct ReleaseNameParser {

    public init() {}

    // MARK: Patterns

    // S01E02 / s01.e02 / S01E02E03 / S01E02-E03
    private static let seasonEpisode = RX(
        #"[sS](\d{1,2})[\s._-]*[eE](\d{1,3})(?:[\s._-]*[eE]?(\d{1,3}))?"#
    )
    // 1x05 / 01x05
    private static let altSeasonEpisode = RX(#"(?<![a-zA-Z0-9])(\d{1,2})x(\d{1,3})(?![a-zA-Z0-9])"#)
    // "Season 1 Episode 7"
    private static let wordySeasonEpisode = RX(#"season[\s._-]*(\d{1,2})[\s._-]*episode[\s._-]*(\d{1,3})"#)
    // "Episode 07" / "E07" (episode only, season unknown)
    private static let episodeOnly = RX(#"(?:^|[\s._-])(?:episode|ep|e)[\s._-]*(\d{1,3})(?![a-zA-Z0-9])"#)
    // A four digit year between 1900 and 2099, optionally parenthesised.
    private static let year = RX(#"(?<![0-9])(?:\((19\d{2}|20\d{2})\)|(19\d{2}|20\d{2}))(?![0-9])"#)
    // Trailing release group: "...-GROUP" at the very end.
    private static let trailingGroup = RX(#"-([A-Za-z0-9][A-Za-z0-9._]{1,})$"#, options: [])
    // Bracketed group: "[GROUP]".
    private static let bracketGroup = RX(#"[\[\(]([A-Za-z0-9][A-Za-z0-9._ -]{1,})[\]\)]"#)

    // MARK: Public API

    public func parse(fileName: String) -> ParsedRelease {
        let base = ReleaseNameParser.stripKnownExtension(from: fileName)

        var result = ParsedRelease(originalFileName: fileName, title: "", kind: .unknown)

        // Resolution / source / codec / group can appear anywhere; scan first.
        result.resolution = ReleaseNameParser.firstNormalisedToken(in: base, table: ReleaseTokens.resolutions)
        result.source = ReleaseNameParser.firstNormalisedToken(in: base, table: ReleaseTokens.sources)
        result.codec = ReleaseNameParser.firstNormalisedToken(in: base, table: ReleaseTokens.codecs)
        result.releaseGroup = ReleaseNameParser.detectReleaseGroup(in: base)

        // Find where the title ends, based on the strongest anchor available.
        var titleEndIndex = base.endIndex

        if let se = ReleaseNameParser.parseSeasonEpisode(in: base) {
            result.kind = .episode
            result.season = se.season
            result.episode = se.episode
            result.episodeEnd = se.episodeEnd
            titleEndIndex = min(titleEndIndex, se.startIndex)

            // A series may also carry an air year before the S/E marker.
            if let y = ReleaseNameParser.parseYear(in: base, before: se.startIndex) {
                result.year = y.value
                titleEndIndex = min(titleEndIndex, y.startIndex)
            }
        } else if let y = ReleaseNameParser.parseMovieYear(in: base) {
            result.kind = .movie
            result.year = y.value
            titleEndIndex = min(titleEndIndex, y.startIndex)
        } else if let stopIndex = ReleaseNameParser.firstStopWordIndex(in: base) {
            titleEndIndex = min(titleEndIndex, stopIndex)
        }

        let titleRaw = String(base[base.startIndex..<titleEndIndex])
        result.title = ReleaseNameParser.cleanTitle(titleRaw)

        // If we still have no kind but a season/episode was never found and a
        // title exists, leave it as `.unknown`; the planner can treat unknowns
        // as movies without a year.
        return result
    }

    // MARK: Season / Episode

    struct SeasonEpisodeMatch {
        var season: Int?
        var episode: Int?
        var episodeEnd: Int?
        var startIndex: String.Index
    }

    static func parseSeasonEpisode(in base: String) -> SeasonEpisodeMatch? {
        if let m = seasonEpisode.firstMatch(in: base),
           let r = Range(m.range, in: base) {
            return SeasonEpisodeMatch(
                season: m.intGroup(1, in: base),
                episode: m.intGroup(2, in: base),
                episodeEnd: m.intGroup(3, in: base),
                startIndex: r.lowerBound
            )
        }
        if let m = altSeasonEpisode.firstMatch(in: base),
           let r = Range(m.range, in: base) {
            return SeasonEpisodeMatch(
                season: m.intGroup(1, in: base),
                episode: m.intGroup(2, in: base),
                episodeEnd: nil,
                startIndex: r.lowerBound
            )
        }
        if let m = wordySeasonEpisode.firstMatch(in: base),
           let r = Range(m.range, in: base) {
            return SeasonEpisodeMatch(
                season: m.intGroup(1, in: base),
                episode: m.intGroup(2, in: base),
                episodeEnd: nil,
                startIndex: r.lowerBound
            )
        }
        if let m = episodeOnly.firstMatch(in: base),
           let r = Range(m.range, in: base) {
            // Episode only -> assume season 1.
            return SeasonEpisodeMatch(
                season: 1,
                episode: m.intGroup(1, in: base),
                episodeEnd: nil,
                startIndex: r.lowerBound
            )
        }
        return nil
    }

    // MARK: Year

    struct YearMatch {
        var value: Int
        var startIndex: String.Index
        /// Index immediately after the matched year token.
        var endIndex: String.Index
    }

    /// Returns the first year found strictly before `limit`.
    static func parseYear(in base: String, before limit: String.Index) -> YearMatch? {
        for m in year.matches(in: base) {
            guard let r = Range(m.range, in: base), r.lowerBound < limit else { continue }
            let value = m.intGroup(1, in: base) ?? m.intGroup(2, in: base)
            if let value {
                return YearMatch(value: value, startIndex: r.lowerBound, endIndex: r.upperBound)
            }
        }
        return nil
    }

    /// Picks the most plausible *release* year for a movie. When several year
    /// tokens are present (e.g. "Blade Runner 2049 2017 1080p"), prefers a
    /// parenthesised year, otherwise the last year token whose following context
    /// looks like quality metadata, otherwise the last year token overall.
    static func parseMovieYear(in base: String) -> YearMatch? {
        let allMatches = year.matches(in: base).compactMap { m -> YearMatch? in
            guard let r = Range(m.range, in: base) else { return nil }
            let value = m.intGroup(1, in: base) ?? m.intGroup(2, in: base)
            return value.map { YearMatch(value: $0, startIndex: r.lowerBound, endIndex: r.upperBound) }
        }
        guard !allMatches.isEmpty else { return nil }

        // Prefer a parenthesised year.
        if let paren = allMatches.last(where: { match in
            match.startIndex > base.startIndex
                && base[base.index(before: match.startIndex)] == "("
        }) {
            return paren
        }

        // Prefer the last year that is followed by a stop word (quality token)
        // or the end of the string.
        if let anchored = allMatches.last(where: { isFollowedByStopWordOrEnd(in: base, after: $0.endIndex) }) {
            return anchored
        }

        return allMatches.last
    }

    private static func isFollowedByStopWordOrEnd(in base: String, after index: String.Index) -> Bool {
        guard index < base.endIndex else { return true }
        let rest = base[index...]
        let nextToken = rest
            .split(whereSeparator: { ReleaseNameParser.isSeparator($0) })
            .first
            .map(String.init)
        guard let nextToken, !nextToken.isEmpty else { return true }
        return ReleaseTokens.isStopWord(nextToken)
    }

    // MARK: Tokens

    static func firstNormalisedToken(in base: String, table: [String: String]) -> String? {
        for token in tokenize(base) {
            if let normalised = table[token.lowercased()] {
                return normalised
            }
        }
        return nil
    }

    static func firstStopWordIndex(in base: String) -> String.Index? {
        var index = base.startIndex
        while index < base.endIndex {
            // Advance over separators.
            while index < base.endIndex, isSeparator(base[index]) {
                index = base.index(after: index)
            }
            guard index < base.endIndex else { break }
            var end = index
            while end < base.endIndex, !isSeparator(base[end]) {
                end = base.index(after: end)
            }
            let token = String(base[index..<end])
            if ReleaseTokens.isStopWord(token) {
                return index
            }
            index = end
        }
        return nil
    }

    static func detectReleaseGroup(in base: String) -> String? {
        if let m = trailingGroup.firstMatch(in: base), let token = m.group(1, in: base) {
            // Reject when the trailing token is itself a known tag (e.g. the
            // "DL" of "WEB-DL").
            if !ReleaseTokens.isStopWord(token) {
                return token
            }
        }
        if let m = bracketGroup.firstMatch(in: base), let token = m.group(1, in: base) {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            if !ReleaseTokens.isStopWord(trimmed), Int(trimmed) == nil {
                return trimmed
            }
        }
        return nil
    }

    // MARK: Title cleanup

    static func cleanTitle(_ raw: String) -> String {
        var s = raw
        // Normalise separators to spaces.
        s = s.replacingOccurrences(of: ".", with: " ")
        s = s.replacingOccurrences(of: "_", with: " ")
        // A lone "-" used as a separator becomes a space, but keep hyphenated words.
        s = s.replacingOccurrences(of: " - ", with: " ")
        // Collapse whitespace.
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" })
        s = parts.joined(separator: " ")
        // Trim stray punctuation / separators from the ends.
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -._([{"))
        return s
    }

    // MARK: Utilities

    static func isSeparator(_ c: Character) -> Bool {
        c == "." || c == "_" || c == " " || c == "-"
    }

    static func tokenize(_ base: String) -> [String] {
        base.split(whereSeparator: { isSeparator($0) }).map(String.init)
    }

    /// Known video & subtitle extensions are stripped before parsing. Only the
    /// last extension is removed and only when recognised, so titles like
    /// "S.W.A.T" are not mangled.
    static func stripKnownExtension(from fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if VideoFileTypes.videoExtensions.contains(ext)
            || VideoFileTypes.subtitleExtensions.contains(ext)
            || ["nfo", "txt", "jpg", "jpeg", "png"].contains(ext) {
            return (fileName as NSString).deletingPathExtension
        }
        return fileName
    }
}
