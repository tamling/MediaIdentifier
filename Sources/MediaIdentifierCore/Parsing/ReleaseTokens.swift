import Foundation

/// Vocabulary of well-known release tokens. Used both to classify tokens
/// (resolution / source / codec) and to know where a title ends when there is
/// no year or season/episode marker to anchor on.
enum ReleaseTokens {
    /// Resolution tokens mapped to their normalised form.
    static let resolutions: [String: String] = [
        "2160p": "2160p", "4k": "2160p", "uhd": "2160p", "4320p": "4320p",
        "1080p": "1080p", "1080i": "1080p",
        "720p": "720p", "576p": "576p", "480p": "480p", "360p": "360p"
    ]

    /// Source tokens mapped to a normalised display form.
    static let sources: [String: String] = [
        "web-dl": "WEB-DL", "webdl": "WEB-DL", "web": "WEB",
        "webrip": "WEBRip", "bluray": "BluRay", "blu-ray": "BluRay",
        "brrip": "BRRip", "bdrip": "BDRip", "bdremux": "Remux", "remux": "Remux",
        "hdrip": "HDRip", "dvdrip": "DVDRip", "dvd": "DVD",
        "hdtv": "HDTV", "pdtv": "PDTV", "cam": "CAM", "ts": "TS", "hdcam": "HDCAM"
    ]

    /// Codec / audio / HDR tokens mapped to a normalised display form.
    static let codecs: [String: String] = [
        "x264": "x264", "x265": "x265", "h264": "h264", "h265": "h265",
        "h.264": "h264", "h.265": "h265", "avc": "AVC", "hevc": "HEVC",
        "xvid": "Xvid", "divx": "DivX", "av1": "AV1"
    ]

    /// Tokens that are never part of a title and signal "metadata starts here".
    /// Includes resolutions, sources, codecs plus assorted quality/edition tags.
    static let stopWords: Set<String> = {
        var set = Set<String>()
        set.formUnion(resolutions.keys)
        set.formUnion(sources.keys)
        set.formUnion(codecs.keys)
        set.formUnion([
            "proper", "repack", "extended", "unrated", "uncut", "remastered",
            "directors", "director", "cut", "internal", "limited", "multi",
            "dual", "subbed", "dubbed", "complete", "season", "10bit", "8bit",
            "hdr", "hdr10", "hdr10+", "dv", "dolby", "vision", "atmos",
            "truehd", "dts", "dts-hd", "ddp", "dd", "dd5", "ddp5", "aac",
            "ac3", "eac3", "flac", "mp3", "opus", "imax", "hybrid", "sdr",
            "amzn", "nf", "dsnp", "hmax", "atvp", "hulu"
        ])
        return set
    }()

    static func isStopWord(_ token: String) -> Bool {
        stopWords.contains(token.lowercased())
    }
}
