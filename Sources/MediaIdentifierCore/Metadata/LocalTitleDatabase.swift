import Foundation

/// An offline title index built from a downloaded TMDb data export (FR3, FR20).
///
/// After a one-time download the matching is fully local ("Lokal" once cached).
/// Supports TMDb's daily ID export (NDJSON with `original_title` /
/// `original_name`) as well as a generic JSON array of `{title, year, kind}`.
public struct LocalTitleDatabase: Sendable {
    public struct Entry: Sendable, Equatable {
        public var title: String
        public var year: Int?
        public var kind: MediaKind
        public var popularity: Double

        public init(title: String, year: Int? = nil, kind: MediaKind, popularity: Double = 0) {
            self.title = title
            self.year = year
            self.kind = kind
            self.popularity = popularity
        }
    }

    private let entries: [Entry]
    private let exactIndex: [String: [Int]]   // normalized title -> entry indices
    private let tokenIndex: [String: [Int]]   // first token -> entry indices (fuzzy blocking)

    public var count: Int { entries.count }

    public init(entries: [Entry]) {
        self.entries = entries
        var exact: [String: [Int]] = [:]
        var token: [String: [Int]] = [:]
        for (i, entry) in entries.enumerated() {
            let norm = LocalTitleDatabase.normalize(entry.title)
            guard !norm.isEmpty else { continue }
            exact[norm, default: []].append(i)
            if let first = norm.split(separator: " ").first {
                token[String(first), default: []].append(i)
            }
        }
        self.exactIndex = exact
        self.tokenIndex = token
    }

    // MARK: Matching

    /// Finds the best canonical entry for a parsed title. Prefers an exact
    /// normalized match, then a fuzzy match within the same first-token block,
    /// ranked by kind, year agreement and popularity.
    public func match(title: String, year: Int?, kind: MediaKind) -> Entry? {
        let norm = LocalTitleDatabase.normalize(title)
        guard !norm.isEmpty else { return nil }

        var candidates: [Entry]
        if let indices = exactIndex[norm] {
            candidates = indices.map { entries[$0] }
        } else {
            guard let first = norm.split(separator: " ").first,
                  let block = tokenIndex[String(first)] else { return nil }
            candidates = block.compactMap { index -> Entry? in
                let entry = entries[index]
                let similarity = LocalTitleDatabase.similarity(norm, LocalTitleDatabase.normalize(entry.title))
                return similarity >= 0.86 ? entry : nil
            }
        }
        guard !candidates.isEmpty else { return nil }

        return candidates.max { a, b in
            score(a, year: year, kind: kind) < score(b, year: year, kind: kind)
        }
    }

    private func score(_ entry: Entry, year: Int?, kind: MediaKind) -> Double {
        var s = entry.popularity
        if kind != .unknown, entry.kind == kind { s += 1_000_000 }
        if let year, let entryYear = entry.year, year == entryYear { s += 500_000 }
        return s
    }

    // MARK: Normalisation & similarity

    static func normalize(_ string: String) -> String {
        let folded = string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
            } else {
                scalars.append(" ")
            }
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    /// Normalised Levenshtein similarity in 0...1.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1 }
        let distance = levenshtein(Array(a), Array(b))
        return 1 - Double(distance) / Double(maxLen)
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

/// Resolves titles against a `LocalTitleDatabase` (FR3, offline).
public struct LocalDatabaseMetadataProvider: MetadataProvider {
    public let database: LocalTitleDatabase

    public init(database: LocalTitleDatabase) {
        self.database = database
    }

    public func identify(_ parsed: ParsedRelease, at url: URL?) async throws -> MediaMetadata? {
        guard let entry = database.match(title: parsed.title, year: parsed.year, kind: parsed.kind) else {
            return nil
        }
        return MediaMetadata(
            title: entry.title,
            year: entry.year ?? parsed.year,
            kind: entry.kind == .unknown ? parsed.kind : entry.kind
        )
    }
}
