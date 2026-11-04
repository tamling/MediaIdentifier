import Foundation

/// Works out where a track belongs in a Jellyfin music library.
///
/// Jellyfin's own documentation is unusually relaxed here: "Individual
/// songs have no required parameters for filenames since the information
/// will be scraped from metadata." So the layout below is for the person
/// browsing the folder, not for the server — which is why it looks like
/// the example in those docs rather than like something clever.
///
///     /Artist/Album (1998)/01 - Title.flac
///
/// Disc folders are created only when the tags say there is more than one
/// disc. The documentation calls them optional and says tags alone are
/// enough, so a single-disc album does not get a pointless `/Disc 1`.
public enum MusicNamer {

    /// The relative path under the music library root.
    ///
    /// Returns nil when the tags do not name an artist, an album and a
    /// title: a guess at any of those puts the file somewhere the user
    /// will not think to look, which is worse than leaving it alone.
    public static func relativePath(for tags: AudioTags,
                                    extension fileExtension: String) -> String? {
        guard tags.areSufficient,
              let album = clean(tags.album),
              let artist = clean(tags.effectiveAlbumArtist),
              let title = clean(tags.title) else { return nil }

        var albumFolder = album
        if let year = tags.year { albumFolder += " (\(year))" }

        var components = [artist, albumFolder]
        // Only for a genuine multi-disc release. The tag often says "1/1",
        // which is one disc and must not produce a folder.
        if let disc = tags.discNumber, let total = tags.discTotal, total > 1 {
            components.append("Disc \(disc)")
        } else if let disc = tags.discNumber, disc > 1 {
            // No total, but a disc number above one: there is certainly
            // more than one disc, even if the file does not say how many.
            components.append("Disc \(disc)")
        }

        components.append(fileName(for: tags, title: title, extension: fileExtension))
        return components.joined(separator: "/")
    }

    /// "01 - Title.flac", or "Title.flac" when nothing numbers it.
    static func fileName(for tags: AudioTags, title: String,
                         extension fileExtension: String) -> String {
        let suffix = fileExtension.isEmpty ? "" : "." + fileExtension.lowercased()
        guard let track = tags.trackNumber, track > 0 else { return title + suffix }
        // Two digits is what the Jellyfin example uses and what sorts
        // correctly in a file manager; three only when an album really has
        // a hundred tracks.
        let width = (tags.trackTotal ?? track) >= 100 ? 3 : 2
        let number = String(format: "%0\(width)d", track)
        return "\(number) - \(title)\(suffix)"
    }

    /// Where the album's cover belongs, given a track's relative path.
    ///
    /// Beside the tracks, which for a multi-disc release means the album
    /// folder rather than the disc folder: Jellyfin scrapes the album
    /// folder, and one cover per disc would be three copies of the same
    /// picture.
    public static func coverPath(forTrackAt relativePath: String,
                                 named name: String = "cover.jpg") -> String {
        var components = relativePath.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return name }
        components.removeLast()                               // the file
        if components.last?.lowercased().hasPrefix("disc ") == true {
            components.removeLast()
        }
        return (components + [name]).joined(separator: "/")
    }

    /// Strips what a path component may not hold.
    ///
    /// A slash in an artist's name — AC/DC is the standing example — would
    /// otherwise create a folder nobody asked for. Replaced rather than
    /// removed, so AC/DC stays readable.
    static func clean(_ value: String?) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "/", with: "-")
        text = text.replacingOccurrences(of: "\\", with: "-")
        // Control characters, including the newline that a broken tagger
        // can leave in a title.
        text = String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        // A component may not end in a dot or a space: harmless on Linux,
        // but the library may well be served to a Windows client.
        while text.hasSuffix(".") || text.hasSuffix(" ") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // 150 bytes keeps every component under Linux's 255-byte limit
        // even after a long extension.
        if text.utf8.count > 150 {
            text = String(text.prefix(while: { _ in true }).prefix(120))
                .trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? nil : text
    }
}
