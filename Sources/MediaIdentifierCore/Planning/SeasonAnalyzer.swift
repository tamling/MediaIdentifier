import Foundation

/// Determines which seasons in a batch look "complete" so that only finished
/// seasons are moved into a library, while partial seasons are left in place.
public enum SeasonAnalyzer {
    public struct SeasonKey: Hashable, Sendable {
        public let showTitle: String
        public let season: Int

        public init(showTitle: String, season: Int) {
            // Case/space-insensitive so "The Office" == "the  office".
            self.showTitle = showTitle.lowercased().split(separator: " ").joined(separator: " ")
            self.season = season
        }
    }

    /// A season counts as complete when its episodes are contiguous from 1 to
    /// the maximum present (no gaps) and there are at least two episodes.
    /// Multi-episode files (S01E01E02) contribute all covered episode numbers.
    public static func completeSeasons(in files: [MediaFile]) -> Set<SeasonKey> {
        var episodesByKey: [SeasonKey: Set<Int>] = [:]
        for file in files where file.parsed.kind == .episode {
            guard let season = file.parsed.season, let episode = file.parsed.episode else { continue }
            let key = SeasonKey(showTitle: file.parsed.title, season: season)
            let end = file.parsed.episodeEnd ?? episode
            for ep in min(episode, end)...max(episode, end) {
                episodesByKey[key, default: []].insert(ep)
            }
        }

        var complete = Set<SeasonKey>()
        for (key, episodes) in episodesByKey {
            guard let maxEpisode = episodes.max(), maxEpisode >= 2 else { continue }
            if episodes == Set(1...maxEpisode) {
                complete.insert(key)
            }
        }
        return complete
    }

    /// Whether the file's season is complete within `completeSeasons`.
    public static func isComplete(_ parsed: ParsedRelease, within completeSeasons: Set<SeasonKey>) -> Bool {
        guard parsed.kind == .episode, let season = parsed.season else { return false }
        return completeSeasons.contains(SeasonKey(showTitle: parsed.title, season: season))
    }
}
