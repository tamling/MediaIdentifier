import Foundation

/// Which of the two kinds of `.nfo` a file is.
///
/// Two unrelated conventions share one extension, and the program's own
/// comments have known it all along without ever acting on it:
///
/// * A **release note** is the group's own file: ASCII art, a list of what
///   was ripped from what with which settings, usually in CP437. Carrying
///   one into the library is worse than clutter — Jellyfin finds a local
///   sidecar where it expected its own and the item can end up with no
///   metadata at all.
/// * A **metadata sidecar** is Jellyfin's own file, in its own XML, holding
///   the title, the plot, the ratings and every correction the user ever
///   made by hand.
///
/// Telling them apart by extension is impossible; by name it is hopeless,
/// because Jellyfin names its sidecar after the video, which is exactly what
/// the scanner matches companions on. By content it is easy, which is why
/// this type exists and why it is consulted at the point of deletion.
public enum NfoKind: Equatable, Sendable {
    /// A group's notes. The only value that permits deletion.
    case releaseNote
    /// Jellyfin's own metadata. Never deleted, never moved.
    case metadataSidecar
    /// Empty, unreadable, or gone. Never deleted: a file this program cannot
    /// read is not thereby rubbish.
    case undecidable
}

/// Reads an `.nfo` far enough to say which kind it is.
public enum NfoContent {

    /// How much of the file is read.
    ///
    /// A sidecar's root element is on the first or second line and an XML
    /// declaration is in the first forty bytes; 4 KiB leaves room for a
    /// byte-order mark, a comment and a stylesheet instruction in front of
    /// it. Bounded rather than reading the file whole, because nothing
    /// stops a 2 GB file from being named `.nfo`.
    static let sampleSize = 4096

    /// The root elements Jellyfin and Kodi write.
    ///
    /// Matched as bytes, so a file in an encoding this program cannot name
    /// still answers correctly: every one of these markers is pure ASCII,
    /// and in UTF-8, Latin-1 and CP437 alike the ASCII bytes are the ASCII
    /// bytes.
    static let metadataMarkers = [
        "<?xml", "<movie", "<episodedetails", "<tvshow", "<season",
        "<musicvideo", "<artist", "<album", "<set", "<person",
    ]

    /// Decides what the file at `url` is. Never throws and never deletes:
    /// anything it cannot answer for is `.undecidable`.
    public static func kind(of url: URL) -> NfoKind {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .undecidable
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: sampleSize),
              !data.isEmpty
        else {
            // An empty .nfo holds nothing worth deleting and might be a
            // placeholder Jellyfin is about to fill. Left alone.
            return .undecidable
        }
        return kind(ofSample: data)
    }

    /// The decision itself, over bytes, so it can be tested without a disk.
    static func kind(ofSample data: Data) -> NfoKind {
        // NUL bytes dropped and ASCII letters folded to lower case in one
        // pass. Dropping NUL is what makes a UTF-16 sidecar answer the same
        // as a UTF-8 one: its ASCII characters are each a byte and a NUL.
        var folded = [UInt8]()
        folded.reserveCapacity(data.count)
        for byte in data where byte != 0 {
            folded.append(byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte)
        }
        for marker in metadataMarkers
        where folded.containsBytes(of: Array(marker.utf8)) {
            return .metadataSidecar
        }
        // Kodi's other sidecar format, which Jellyfin also reads: a file
        // holding nothing but the URL of the entry on a metadata site. No
        // XML in it at all, and deleting it loses the one hint the user
        // gave about what this film is.
        let head = folded.drop { $0 == 0x20 || $0 == 0x09
            || $0 == 0x0A || $0 == 0x0D || $0 == 0xEF || $0 == 0xBB || $0 == 0xBF }
        if head.starts(with: Array("http://".utf8))
            || head.starts(with: Array("https://".utf8)) {
            return .metadataSidecar
        }
        return .releaseNote
    }
}

private extension Array where Element == UInt8 {
    /// Whether `needle` occurs in `self`. Plain search: the haystack is at
    /// most 4 KiB and the needles are a dozen bytes.
    func containsBytes(of needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        for start in 0...(count - needle.count) {
            var matched = true
            for offset in needle.indices {
                if self[start + offset] != needle[offset] {
                    matched = false
                    break
                }
            }
            if matched { return true }
        }
        return false
    }
}
