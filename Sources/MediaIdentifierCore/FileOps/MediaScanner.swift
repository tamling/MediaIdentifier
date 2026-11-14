import Foundation

/// Discovers media files and their companions on disk (FR1, FR10, FR14, FR15).
public struct MediaScanner {
    /// Hard ceiling on what one recursion returns, so pointing Mediafin at a
    /// huge tree cannot exhaust memory before the user sees anything.
    /// `AppCoordinator.FolderScan` uses the same number.
    public static let maximumFiles = 5_000

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

        // Which other videos in this folder have a longer name that starts
        // with ours. A prefix rule alone makes "Film.Extended.en.srt" a
        // companion of BOTH "Film.mkv" and "Film.Extended.mkv", so the same
        // subtitle was planned into two places: the first move took it and
        // the second failed with "no such file". The longer name wins,
        // because it is the one the file was actually named after.
        //
        // Samples are excluded from the competition: a sample is not a film,
        // so it has no claim on anything — and because its own name is the
        // film's name plus "-sample", counting it here made it longer than
        // the film and left the film's own sample unlisted, so the row could
        // no longer say where it stays.
        let longerVideoStems = entries
            .filter {
                $0 != videoURL && VideoFileTypes.isVideo($0)
                    && !VideoFileTypes.isSample($0)
            }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0.count > stem.count && $0.hasPrefix(stem) }

        var companions: [CompanionFile] = []
        for entry in entries {
            guard entry != videoURL, !isDirectory(entry) else { continue }
            let entryStem = entry.deletingPathExtension().lastPathComponent
            // Companion if its name equals the video stem or starts with it
            // (covers "Movie.en.srt", "Movie-poster.jpg", etc.).
            guard entryStem == stem || entryStem.hasPrefix(stem) else { continue }
            guard !longerVideoStems.contains(where: { entryStem.hasPrefix($0) })
            else { continue }

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
            // Found by looking, not pointed at: see FolderScan.videoFiles.
            // A sample handed over directly is still honoured, because then
            // somebody meant that file.
            guard !VideoFileTypes.isSample(fileURL) else { continue }
            result.append(fileURL)
            // The same ceiling the other scanner has. One of the two used to
            // have none, so whether a huge tree could exhaust memory before
            // the user saw anything depended on which call path found it.
            if result.count >= MediaScanner.maximumFiles { break }
        }
        return result.sorted { $0.path < $1.path }
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
