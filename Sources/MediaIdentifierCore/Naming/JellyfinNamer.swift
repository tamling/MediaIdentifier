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

    /// How many bytes one path component may use.
    ///
    /// 200 and not 255: what goes through here is a stem, and the caller
    /// wraps it — " (2014)" on a film, " - S05E10" on an episode, the
    /// extension on both — so the component that reaches the filesystem is
    /// longer than what this returns. ext4, XFS, APFS and SMB all stop at
    /// 255 **bytes**, and `ENAMETOOLONG` is where the slack goes.
    public static let componentByteLimit = 200

    /// Removes characters that are illegal or problematic in file names on
    /// macOS / SMB shares (`/` and `:` in particular), strips control
    /// characters, and keeps the result inside one component's byte budget.
    ///
    /// The length and the control characters were missing while
    /// `MusicNamer.clean` had both — the same job, two rules, and the video
    /// path was the one without. The title that arrives here comes from TMDb
    /// or from a local model, and the only check on it is "not empty":
    ///
    /// A 240-character title makes a component that fits as a folder and
    /// not as a file, because the file carries the extension as well. So
    /// `ensureParentDirectory` creates the folder, the move into it fails
    /// with `ENAMETOOLONG`, and the library keeps an empty 240-character
    /// folder that nothing cleans up — undo has no entry for an operation
    /// that failed.
    ///
    /// A title with a newline in it makes a file name with a newline in it:
    /// legal on Linux, awkward for the user in a shell for ever, and
    /// straight into the systemd journal from `mediafin --once`.
    public static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name
            .components(separatedBy: illegal)
            .joined(separator: " ")
        // Control characters, including the newline a broken tagger or a
        // talkative model can leave in a title. DEL too, which is above the
        // C0 range and just as unwelcome in a file name.
        let printable = String(cleaned.unicodeScalars.filter {
            $0.value >= 0x20 && $0.value != 0x7F
        })
        // Collapse the whitespace that sanitising may introduce and trim dots /
        // spaces from the ends (trailing dots are problematic on some shares).
        let collapsed = printable.split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
        let bounded = truncating(collapsed, toBytes: componentByteLimit)
        // After the cut, not before: cutting can leave a trailing dot or
        // space, and a component may not end in either.
        return bounded.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    /// Cuts `text` to at most `limit` bytes, never through the middle of a
    /// character.
    ///
    /// Counted in bytes and stepped by `Character`: the limit a filesystem
    /// enforces is a byte count, a Japanese title is three bytes a
    /// character, and stepping by UTF-8 index instead would leave half a
    /// grapheme cluster — a broken flag or a family emoji missing a member.
    static func truncating(_ text: String, toBytes limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.utf8.count > limit else { return text }
        var kept = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > limit { break }
            kept.append(character)
            used += size
        }
        return kept
    }
}
