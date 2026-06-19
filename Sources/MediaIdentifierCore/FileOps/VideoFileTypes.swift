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

    public static func isSubtitle(_ url: URL) -> Bool {
        subtitleExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    public static func role(for url: URL) -> CompanionFile.Role {
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        if name.contains("sample") { return .sample }
        if subtitleExtensions.contains(ext) { return .subtitle }
        if ext == "nfo" { return .nfo }
        if imageExtensions.contains(ext) { return .image }
        return .other
    }
}
