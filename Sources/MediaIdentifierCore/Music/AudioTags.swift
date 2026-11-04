import Foundation

/// What a music file says about itself.
public struct AudioTags: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    /// The album's artist, which is not the track's artist on a
    /// compilation — that difference is the whole reason the field exists.
    public var albumArtist: String?
    public var album: String?
    public var year: Int?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    /// True when the file carries its own cover image.
    public var hasEmbeddedCover: Bool

    public init(title: String? = nil, artist: String? = nil, albumArtist: String? = nil,
                album: String? = nil, year: Int? = nil, trackNumber: Int? = nil,
                trackTotal: Int? = nil, discNumber: Int? = nil, discTotal: Int? = nil,
                hasEmbeddedCover: Bool = false) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.year = year
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.hasEmbeddedCover = hasEmbeddedCover
    }

    /// Whoever the album belongs to. A compilation's tracks each have
    /// their own artist; the folder must be named after the album's.
    public var effectiveAlbumArtist: String? {
        if let albumArtist, !albumArtist.isEmpty { return albumArtist }
        return artist
    }

    /// Enough to file the track without asking anyone.
    ///
    /// Artist and album name the folders and title names the file; a
    /// missing track number only costs the ordering prefix. This is the
    /// test for "the tags are good enough", which is what decides whether
    /// anything is looked up online at all.
    public var areSufficient: Bool {
        func filled(_ value: String?) -> Bool {
            !(value ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        return filled(title) && filled(album) && filled(effectiveAlbumArtist)
    }
}

/// Turns ffprobe's `format.tags` into `AudioTags`.
///
/// Pure, so every rule below is testable without a media file — and the
/// rules are not what one would guess. Measured against ffprobe 6.1.1 with
/// files built for the purpose:
///
///  - All three of MP3, FLAC and M4A put their music metadata in
///    `format.tags`. `streams[].tags` holds none of it: MP3 and FLAC have
///    no such key at all, and M4A's holds only the handler name.
///  - MP3 and M4A always arrive under canonical lowercase names, because
///    the demuxer maps fixed frame IDs and atoms onto them.
///  - FLAC does NOT. Vorbis comments pass through in whatever case the
///    tagger wrote, so a Picard file yields `TITLE`, `ARTIST`, `ALBUM`.
///    Only a few names are remapped (ALBUMARTIST, TRACKNUMBER, DISCNUMBER,
///    case-insensitively); `ALBUM_ARTIST`, `ALBUM ARTIST`, `YEAR` and
///    `TOTALTRACKS` come through verbatim. Hence the case-insensitive
///    lookup over a list of spellings rather than one key.
///  - A track number may be "3/11", "3" or "03", and FLAC usually keeps
///    the total in a separate key that ffprobe does not fold in.
///  - Several values for one name are joined with a semicolon.
public enum AudioTagParser {

    public static func parse(_ tags: [String: String],
                             hasEmbeddedCover: Bool = false) -> AudioTags {
        // One lowercased copy, so every lookup below is case-insensitive
        // without repeating the work. A later duplicate does not displace
        // an earlier one: ffprobe emits the canonical name first when it
        // remaps, and that is the one to trust.
        var lowered: [String: String] = [:]
        for (key, value) in tags {
            let name = key.lowercased()
            if lowered[name] == nil { lowered[name] = value }
        }

        func first(_ names: [String]) -> String? {
            for name in names {
                if let value = lowered[name] {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }

        let track = numbers(first(["track", "tracknumber"]))
        let disc = numbers(first(["disc", "discnumber"]))

        return AudioTags(
            title: first(["title"]),
            artist: firstOfSeveral(first(["artist"])),
            albumArtist: firstOfSeveral(first([
                "album_artist", "albumartist", "album artist", "band",
            ])),
            album: first(["album"]),
            year: year(from: first(["date", "year", "originaldate", "originalyear"])),
            trackNumber: track.value,
            // The slash tail when there is one, otherwise the separate key
            // that FLAC taggers write and ffprobe does not merge.
            trackTotal: track.total ?? integer(first(["totaltracks", "tracktotal"])),
            discNumber: disc.value,
            discTotal: disc.total ?? integer(first(["totaldiscs", "disctotal"])),
            hasEmbeddedCover: hasEmbeddedCover
        )
    }

    /// "3/11" → (3, 11); "3" → (3, nil); "03" → (3, nil).
    static func numbers(_ raw: String?) -> (value: Int?, total: Int?) {
        guard let raw else { return (nil, nil) }
        let parts = raw.split(separator: "/", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let head = parts.first else { return (nil, nil) }
        return (integer(head), parts.count > 1 ? integer(parts[1]) : nil)
    }

    /// A year out of "1998", "1998-04-27" or "27.04.1998".
    ///
    /// Only a plausible one: a four-digit run that could be a year. A date
    /// field holding something else must not produce 27 as the year.
    static func year(from raw: String?) -> Int? {
        guard let raw else { return nil }
        var digits = ""
        for character in raw {
            if character.isNumber {
                digits.append(character)
                if digits.count == 4 {
                    if let value = Int(digits), (1900...2199).contains(value) {
                        return value
                    }
                    digits.removeFirst()
                }
            } else {
                digits = ""
            }
        }
        return nil
    }

    static func integer(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let digits = raw.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Several values for one tag arrive joined with a semicolon. The first
    /// is the one that names the folder; keeping the whole string would
    /// produce "First;Second" as an artist's name.
    static func firstOfSeveral(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let first = raw.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return (first?.isEmpty ?? true) ? raw : first
    }
}
