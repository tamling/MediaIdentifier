import Foundation

/// Central registry of recognised file extensions (FR1, FR14, FR15).
public enum VideoFileTypes {
    /// Supported video container extensions (lower-cased, no dot).
    public static let videoExtensions: Set<String> = [
        "mkv", "avi", "mp4", "mov", "m4v", "wmv", "flv", "webm",
        "mpg", "mpeg", "m2ts", "ts", "vob", "ogv", "3gp", "divx"
    ]

    /// Supported subtitle extensions (FR14).
    public static let subtitleExtensions: Set<String> = [
        "srt", "ass", "ssa", "sub", "idx", "vtt", "smi"
    ]

    /// Image extensions treated as cover / poster art (FR15).
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tbn", "webp", "gif"
    ]

    public static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    // No `isSubtitle` or `isImage` beside `isVideo`, on purpose.
    //
    // They existed, had no caller, and would have been a trap for the next
    // one: both were bare extension tests, while `role(for:)` below asks
    // `isSample` FIRST. So for `Fargo.S05E10-GROUP-sample.srt` the helper
    // said "subtitle" and the role says "sample", and only the role is
    // right — `ReleaseSampleTests` records exactly that bug ("it used to be
    // a bare `contains`, which also made a subtitle whose name ended in
    // 'sample' a sample rather than a subtitle"). Ask `role(for:)`.

    /// Whether this is a release sample rather than the release.
    ///
    /// A scene release ships a thirty-second excerpt beside the film, and
    /// until now nothing here knew that. The excerpt is a video file, so the
    /// folder scan proposed it as a film of its own; its name parses to the
    /// same episode as the real file, so both rows wanted the same
    /// destination, the pair was refused as a duplicate — and *neither* file
    /// was renamed. A release with a sample beside it quietly did nothing.
    ///
    /// The rule is deliberately narrow, because the cost of the two mistakes
    /// is not the same. Calling a sample a film puts a near-duplicate in the
    /// library; calling a film a sample makes the film disappear from the
    /// list with no explanation, and "Free Samples" (2012) and "Sample
    /// People" (2000) are real films. So "sample" is matched only as a whole
    /// name, as a folder name, or as the last token of the name — never
    /// merely contained, which is what this used to do, and never at the
    /// start, which is exactly where a film called Sample.People.2000 has it.
    public static func isSample(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        if stem == "sample" || stem == "samples" { return true }
        let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()
        if parent == "sample" || parent == "samples" { return true }
        for word in ["sample", "samples"] {
            for delimiter in [".", "-", "_", " "] {
                if stem.hasSuffix(delimiter + word) { return true }
            }
        }
        return false
    }

    public static func role(for url: URL) -> CompanionFile.Role {
        let ext = url.pathExtension.lowercased()
        if isSample(url) { return .sample }
        if subtitleExtensions.contains(ext) { return .subtitle }
        if ext == "nfo" { return .nfo }
        if imageExtensions.contains(ext) { return .image }
        return .other
    }
}
