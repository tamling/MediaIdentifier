import Foundation

/// User-tunable options for Jellyfin naming conventions.
public struct NamingOptions: Codable, Sendable, Equatable {
    /// Wrap each movie in its own folder: `Title (Year)/Title (Year).ext`.
    public var useMovieFolders: Bool
    /// Include the series year in the show folder: `Show (2023)/...`.
    public var includeSeriesYear: Bool
    /// Minimum zero-padding width for season / episode numbers.
    public var numberPadding: Int

    public init(useMovieFolders: Bool = true, includeSeriesYear: Bool = false, numberPadding: Int = 2) {
        self.useMovieFolders = useMovieFolders
        self.includeSeriesYear = includeSeriesYear
        self.numberPadding = max(2, numberPadding)
    }

    public static let `default` = NamingOptions()
}

/// Builds Jellyfin-conformant relative paths from parsed releases (FR7).
///
/// Movies:   `Interstellar (2014)/Interstellar (2014).mkv`
/// Episodes: `The Last of Us/Season 01/The Last of Us - S01E01.mkv`
public struct JellyfinNamer {
    public let options: NamingOptions

    public init(options: NamingOptions = .default) {
        self.options = options
    }

    /// Returns the Jellyfin relative path (folders + file name) for a parsed
    /// release, preserving the original file extension.
    public func relativePath(for parsed: ParsedRelease, fileExtension: String) -> String {
        let ext = normalizedExtension(fileExtension)
        switch parsed.kind {
        case .episode:
            return episodePath(for: parsed, ext: ext)
        case .movie, .unknown:
            return moviePath(for: parsed, ext: ext)
        }
    }

    /// Convenience returning just the file name (no folders).
    public func fileName(for parsed: ParsedRelease, fileExtension: String) -> String {
        (relativePath(for: parsed, fileExtension: fileExtension) as NSString).lastPathComponent
    }

    // MARK: Movies

    private func moviePath(for parsed: ParsedRelease, ext: String) -> String {
        let stem = movieStem(for: parsed)
        let file = stem + ext
        if options.useMovieFolders {
            return stem + "/" + file
        }
        return file
    }

    private func movieStem(for parsed: ParsedRelease) -> String {
        let title = Self.sanitize(parsed.title.isEmpty ? "Unknown" : parsed.title)
        if let year = parsed.year {
            return "\(title) (\(year))"
        }
        return title
    }

    // MARK: Episodes

    private func episodePath(for parsed: ParsedRelease, ext: String) -> String {
        let showName = seriesFolderName(for: parsed)
        let season = parsed.season ?? 1
        let seasonFolder = "Season " + pad(season)
        let stem = episodeStem(showTitle: Self.sanitize(showTitleOnly(parsed)), parsed: parsed)
        return "\(showName)/\(seasonFolder)/\(stem)\(ext)"
    }

    private func showTitleOnly(_ parsed: ParsedRelease) -> String {
        parsed.title.isEmpty ? "Unknown" : parsed.title
    }

    private func seriesFolderName(for parsed: ParsedRelease) -> String {
        let title = Self.sanitize(showTitleOnly(parsed))
        if options.includeSeriesYear, let year = parsed.year {
            return "\(title) (\(year))"
        }
        return title
    }

    private func episodeStem(showTitle: String, parsed: ParsedRelease) -> String {
        let season = parsed.season ?? 1
        let episode = parsed.episode ?? 0
        var marker = "S\(pad(season))E\(pad(episode))"
        if let end = parsed.episodeEnd, end != episode {
            marker += "-E\(pad(end))"
        }
        return "\(showTitle) - \(marker)"
    }

    // MARK: Helpers

    private func pad(_ value: Int) -> String {
        String(format: "%0\(options.numberPadding)d", value)
    }

    private func normalizedExtension(_ ext: String) -> String {
        let trimmed = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmed.isEmpty ? "" : "." + trimmed.lowercased()
    }

    /// Sanitises a user-edited relative path so it cannot escape the output root
    /// (no `..`, no absolute/leading slash) and every component is a legal file
    /// name. Empty / `.` / `..` components are dropped.
    public static func sanitizeRelativePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { sanitize(String($0)) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    /// Removes characters that are illegal or problematic in file names on
    /// macOS / SMB shares (`/` and `:` in particular).
    public static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}")
        let cleaned = name
            .components(separatedBy: illegal)
            .joined(separator: " ")
        // Collapse the whitespace that sanitising may introduce and trim dots /
        // spaces from the ends (trailing dots are problematic on some shares).
        let collapsed = cleaned.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }
}
