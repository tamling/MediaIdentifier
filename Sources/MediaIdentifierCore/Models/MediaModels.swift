import Foundation

/// The kind of media a file represents.
public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case movie
    case episode
    case unknown
}

/// The structured information extracted from a raw release file name.
///
/// Satisfies FR2–FR6 (analysis of release names, title / year / season / episode
/// / resolution / release group extraction).
public struct ParsedRelease: Equatable, Codable, Sendable {
    /// The original file name (last path component) the information was parsed from.
    public var originalFileName: String
    /// Best-effort, human readable title (e.g. "The Last of Us").
    public var title: String
    /// Release / air year if one could be determined.
    public var year: Int?
    /// Season number for episodes.
    public var season: Int?
    /// Episode number for episodes (first episode for multi-episode files).
    public var episode: Int?
    /// Last episode number for multi-episode files (e.g. S01E01E02 -> 2).
    public var episodeEnd: Int?
    /// Resolution token, normalised to e.g. "1080p", "2160p".
    public var resolution: String?
    /// Source token, e.g. "WEB-DL", "BluRay".
    public var source: String?
    /// Codec token, e.g. "x265".
    public var codec: String?
    /// Release group, e.g. "GROUP".
    public var releaseGroup: String?
    /// Whether the file is a movie or an episode.
    public var kind: MediaKind
    /// Name of the metadata source that confirmed title/year (e.g. "TMDb"),
    /// shown as provenance in the UI (FR4). nil when only locally parsed.
    public var matchSource: String?

    public init(
        originalFileName: String,
        title: String,
        year: Int? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        episodeEnd: Int? = nil,
        resolution: String? = nil,
        source: String? = nil,
        codec: String? = nil,
        releaseGroup: String? = nil,
        kind: MediaKind = .unknown,
        matchSource: String? = nil
    ) {
        self.originalFileName = originalFileName
        self.title = title
        self.year = year
        self.season = season
        self.episode = episode
        self.episodeEnd = episodeEnd
        self.resolution = resolution
        self.source = source
        self.codec = codec
        self.releaseGroup = releaseGroup
        self.kind = kind
        self.matchSource = matchSource
    }
}

/// A companion file related to a primary media file (FR14 / FR15).
public struct CompanionFile: Equatable, Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case subtitle
        case nfo
        case image
        case sample
        case other
    }

    public var url: URL
    public var role: Role
    /// Language tag for subtitles, e.g. "en", "ger.forced". Preserved on rename.
    public var languageTag: String?

    public init(url: URL, role: Role, languageTag: String? = nil) {
        self.url = url
        self.role = role
        self.languageTag = languageTag
    }
}

/// A primary media file together with its companions and parsed metadata.
public struct MediaFile: Equatable, Codable, Sendable {
    public var url: URL
    public var parsed: ParsedRelease
    public var companions: [CompanionFile]

    public init(url: URL, parsed: ParsedRelease, companions: [CompanionFile] = []) {
        self.url = url
        self.parsed = parsed
        self.companions = companions
    }
}
