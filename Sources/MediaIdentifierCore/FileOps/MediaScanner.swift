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

        // One directory listing per directory, shared by every video in it.
        //
        // This used to be one listing PER VIDEO, because `mediaFile(for:)`
        // called `companionFiles(for:)` which listed the folder itself. A
        // flat release folder with 1,000 videos and their subtitles and
        // notes is 3,000 entries, so the scan did 1,000 listings of 3,000
        // entries each. Measured, on this repository: 250 files took 2.8 s,
        // 500 took 10.4 s, 1,000 took 40.0 s. Doubling the input quadrupled
        // the time, which is the shape of the bug rather than an opinion
        // about it.
        var listings: [String: DirectoryListing] = [:]
        return uniqueVideos.map { url in
            let directory = url.deletingLastPathComponent()
            let key = directory.standardizedFileURL.path
            let listing = listings[key] ?? DirectoryListing(of: directory,
                                                            fileManager: fileManager)
            listings[key] = listing
            return mediaFile(for: url, in: listing)
        }
    }

    /// One directory, read once.
    ///
    /// `videoStems` is here rather than recomputed per video for the same
    /// reason the listing is: it is a property of the folder, not of the
    /// file being asked about.
    struct DirectoryListing {
        /// One file, with everything about it worked out once.
        ///
        /// `stem` and `role` are here rather than computed where they are
        /// used because they are facts about the file, and where they were
        /// used was a loop over every entry for every video: 1,000 videos
        /// in a folder of 3,000 entries asked each entry "are you a
        /// directory, what is your stem, what is your role" three million
        /// times, and the first of those is a syscall.
        struct Entry {
            let url: URL
            let stem: String
            let role: CompanionFile.Role
        }

        /// Regular files only. Directories are dropped here, once.
        let files: [Entry]
        /// Stems of the videos in this folder that are films in their own
        /// right. Samples are excluded: a sample is named after its film
        /// plus "-sample", so counting it here would make it longer than
        /// the film and let it win the film's own companions.
        let videoStems: [String]

        init(of directory: URL, fileManager: FileManager) {
            // The path-based listing, not the URL-based one. Same work —
            // one listing plus one lookup per entry — but this overload can
            // be overridden on Linux, where the URL one is declared in an
            // extension and cannot be. That is what lets a test COUNT the
            // listings, which is the only exact way to state the rule this
            // type exists for: one listing per folder, not one per video.
            // Two attempts at saying it with a stopwatch both flaked.
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path))
                ?? []
            var files: [Entry] = []
            var stems: [String] = []
            files.reserveCapacity(names.count)
            for name in names.sorted() {
                // `.skipsHiddenFiles` by hand, and it matters here beyond
                // tidiness: a replacement's staged `.mediafin-incoming-…`
                // file must not be picked up as somebody's companion.
                if name.hasPrefix(".") { continue }
                let url = directory.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
                else { continue }
                if isDir.boolValue { continue }
                let stem = url.deletingPathExtension().lastPathComponent
                files.append(Entry(url: url, stem: stem,
                                   role: VideoFileTypes.role(for: url)))
                if VideoFileTypes.isVideo(url), !VideoFileTypes.isSample(url) {
                    stems.append(stem)
                }
            }
            self.files = files
            self.videoStems = stems
        }
    }

    /// Builds a `MediaFile` for a single video URL, parsing its name and finding
    /// sibling companions that share its base name.
    public func mediaFile(for url: URL) -> MediaFile {
        mediaFile(for: url,
                  in: DirectoryListing(of: url.deletingLastPathComponent(),
                                       fileManager: fileManager))
    }

    /// The same, with the folder already read. `scan` uses this so a folder
    /// is listed once however many videos are in it.
    func mediaFile(for url: URL, in listing: DirectoryListing) -> MediaFile {
        let parsed = parser.parse(fileName: url.lastPathComponent)
        let companions = companionFiles(for: url, in: listing)
        return MediaFile(url: url, parsed: parsed, companions: companions)
    }

    // MARK: Companions

    /// Finds subtitles / nfo / images / samples in the same directory whose name
    /// matches the video's base name (FR14, FR15).
    func companionFiles(for videoURL: URL) -> [CompanionFile] {
        companionFiles(for: videoURL,
                       in: DirectoryListing(of: videoURL.deletingLastPathComponent(),
                                            fileManager: fileManager))
    }

    func companionFiles(for videoURL: URL,
                        in listing: DirectoryListing) -> [CompanionFile] {
        let stem = videoURL.deletingPathExtension().lastPathComponent

        // Which other videos in this folder have a longer name that starts
        // with ours. A prefix rule alone makes "Film.Extended.en.srt" a
        // companion of BOTH "Film.mkv" and "Film.Extended.mkv", so the same
        // subtitle was planned into two places: the first move took it and
        // the second failed with "no such file". The longer name wins,
        // because it is the one the file was actually named after.
        let longerVideoStems = listing.videoStems
            .filter { $0.count > stem.count && $0.hasPrefix(stem) }

        var companions: [CompanionFile] = []
        for entry in listing.files {
            // The prefix test first, and deliberately: it rejects almost
            // every entry in a folder of a thousand releases, and
            // everything after it is then paid for only by the handful of
            // files that really belong to this video. The old order asked
            // the filesystem whether the entry was a directory before it
            // asked whether the name was even related.
            guard entry.stem == stem || entry.stem.hasPrefix(stem) else { continue }
            guard entry.url != videoURL else { continue }
            guard !longerVideoStems.contains(where: { entry.stem.hasPrefix($0) })
            else { continue }
            guard entry.role != .other else { continue }

            let language = entry.role == .subtitle
                ? subtitleLanguageTag(stem: stem, entryStem: entry.stem)
                : nil
            companions.append(CompanionFile(url: entry.url, role: entry.role,
                                            languageTag: language))
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
