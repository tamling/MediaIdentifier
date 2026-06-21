import Foundation

/// Loads a `LocalTitleDatabase` from a file on disk (FR3, FR20).
///
/// Accepts:
/// - TMDb daily ID export (NDJSON: one JSON object per line, keys
///   `original_title` for movies or `original_name` for TV) — download once from
///   `http://files.tmdb.org/p/exports/`.
/// - A generic JSON array of `{ "title": …, "year": …, "kind": "movie"|"series" }`.
/// - Optionally gzip-compressed (`.gz`) input on macOS.
public enum LocalTitleDatabaseLoader {
    public enum LoaderError: Error, LocalizedError {
        case unreadable
        case empty

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "The database file could not be read."
            case .empty: return "The database file contains no usable entries."
            }
        }
    }

    /// One raw record; tolerates both TMDb-export and generic shapes.
    private struct RawEntry: Decodable {
        let original_title: String?
        let original_name: String?
        let title: String?
        let name: String?
        let year: Int?
        let release_date: String?
        let first_air_date: String?
        let popularity: Double?
        let kind: String?

        func toEntry() -> LocalTitleDatabase.Entry? {
            let movieTitle = original_title ?? title
            let tvTitle = original_name ?? name
            guard let resolved = movieTitle ?? tvTitle, !resolved.isEmpty else { return nil }

            let isTV: Bool
            if let kind { isTV = kind.lowercased().hasPrefix("tv") || kind.lowercased().hasPrefix("ser") || kind == "episode" }
            else { isTV = (movieTitle == nil && tvTitle != nil) }

            let resolvedYear = year ?? RawEntry.extractYear(release_date ?? first_air_date)
            return LocalTitleDatabase.Entry(
                title: resolved,
                year: resolvedYear,
                kind: isTV ? .episode : .movie,
                popularity: popularity ?? 0
            )
        }

        static func extractYear(_ string: String?) -> Int? {
            guard let string, string.count >= 4 else { return nil }
            return Int(string.prefix(4))
        }
    }

    public static func load(from url: URL) throws -> LocalTitleDatabase {
        let data = try readData(at: url)
        let entries = try parse(data)
        guard !entries.isEmpty else { throw LoaderError.empty }
        return LocalTitleDatabase(entries: entries)
    }

    // MARK: Parsing

    static func parse(_ data: Data) throws -> [LocalTitleDatabase.Entry] {
        // Detect a JSON array (generic format) vs. NDJSON (TMDb export).
        if let firstByte = data.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }),
           firstByte == UInt8(ascii: "[") {
            let raws = (try? JSONDecoder().decode([RawEntry].self, from: data)) ?? []
            return raws.compactMap { $0.toEntry() }
        }

        // NDJSON: decode line by line, skipping malformed lines.
        let decoder = JSONDecoder()
        var entries: [LocalTitleDatabase.Entry] = []
        for line in data.split(separator: 0x0A) {
            guard !line.isEmpty else { continue }
            if let raw = try? decoder.decode(RawEntry.self, from: Data(line)),
               let entry = raw.toEntry() {
                entries.append(entry)
            }
        }
        return entries
    }

    // MARK: Reading (with optional gzip)

    /// Upper bound on uncompressed input to avoid exhausting memory on an
    /// oversized file or a decompression bomb.
    private static let maxDecodedBytes = 1_500_000_000  // ~1.5 GB

    private static func readData(at url: URL) throws -> Data {
        if url.pathExtension.lowercased() == "gz" {
            let data = try gunzip(url)
            guard data.count <= maxDecodedBytes else { throw LoaderError.unreadable }
            return data
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= maxDecodedBytes else { throw LoaderError.unreadable }
        guard let data = try? Data(contentsOf: url) else { throw LoaderError.unreadable }
        return data
    }

    private static func gunzip(_ url: URL) throws -> Data {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            throw LoaderError.unreadable
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { throw LoaderError.unreadable }
        return data
        #else
        throw LoaderError.unreadable
        #endif
    }
}
