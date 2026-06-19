import Foundation

/// Discovers media files and their companions on disk (FR1, FR10, FR14, FR15).
public struct MediaScanner {
    private let fileManager: FileManager
    private let parser: ReleaseNameParser

    public init(fileManager: FileManager = .default, parser: ReleaseNameParser = ReleaseNameParser()) {
        self.fileManager = fileManager
        self.parser = parser
    }

    /// Expands a list of dropped URLs (files and/or folders) into parsed
    /// `MediaFile` values, recursing into directories and attaching companions.
    public func scan(urls: [URL]) -> [MediaFile] {
        var videoURLs: [URL] = []
        for url in urls {
            if isDirectory(url) {
                videoURLs.append(contentsOf: videoFiles(in: url))
            } else if VideoFileTypes.isVideo(url) {
                videoURLs.append(url)
            }
        }
        // De-duplicate while preserving order.
        var seen = Set<String>()
        let uniqueVideos = videoURLs.filter { seen.insert($0.standardizedFileURL.path).inserted }

        return uniqueVideos.map { mediaFile(for: $0) }
    }

    /// Builds a `MediaFile` for a single video URL, parsing its name and finding
    /// sibling companions that share its base name.
    public func mediaFile(for url: URL) -> MediaFile {
        let parsed = parser.parse(fileName: url.lastPathComponent)
        let companions = companionFiles(for: url)
        return MediaFile(url: url, parsed: parsed, companions: companions)
    }

    // MARK: Companions

    /// Finds subtitles / nfo / images / samples in the same directory whose name
    /// matches the video's base name (FR14, FR15).
    func companionFiles(for videoURL: URL) -> [CompanionFile] {
        let directory = videoURL.deletingLastPathComponent()
        let stem = videoURL.deletingPathExtension().lastPathComponent
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var companions: [CompanionFile] = []
        for entry in entries {
            guard entry != videoURL, !isDirectory(entry) else { continue }
            let entryStem = entry.deletingPathExtension().lastPathComponent
            // Companion if its name equals the video stem or starts with it
            // (covers "Movie.en.srt", "Movie-poster.jpg", etc.).
            guard entryStem == stem || entryStem.hasPrefix(stem) else { continue }

            let role = VideoFileTypes.role(for: entry)
            guard role != .other else { continue }

            let language = (role == .subtitle) ? subtitleLanguageTag(stem: stem, entryStem: entryStem) : nil
            companions.append(CompanionFile(url: entry, role: role, languageTag: language))
        }
        return companions.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    /// Extracts a subtitle language tag, e.g. "Movie.en.forced.srt" -> "en.forced".
    func subtitleLanguageTag(stem: String, entryStem: String) -> String? {
        guard entryStem.hasPrefix(stem) else { return nil }
        let suffix = String(entryStem.dropFirst(stem.count))
        let trimmed = suffix.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Directory traversal

    func videoFiles(in directory: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for case let fileURL as URL in enumerator where VideoFileTypes.isVideo(fileURL) {
            result.append(fileURL)
        }
        return result.sorted { $0.path < $1.path }
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
