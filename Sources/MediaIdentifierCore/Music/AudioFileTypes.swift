import Foundation

/// Which files count as music.
public enum AudioFileTypes {

    /// The formats worth claiming. Taken from Jellyfin's own audio list,
    /// trimmed to what actually turns up in a download folder.
    public static let audioExtensions: Set<String> = [
        "mp3", "flac", "m4a", "m4b", "aac", "ogg", "oga", "opus", "wav",
        "wma", "alac", "aiff", "aif", "ape", "wv", "mpc", "dsf", "dff",
    ]

    /// `.3gp` is the single extension Jellyfin lists as both audio and
    /// video, and this project's video scanner already claims it.
    ///
    /// Measured rather than assumed: Jellyfin's audio list intersected
    /// with `VideoFileTypes.videoExtensions` is exactly `{3gp}`. It is left
    /// to the video side — a .3gp is almost always an old phone recording
    /// with a picture in it — and named here so the next person does not
    /// have to rediscover the overlap.
    public static let claimedByVideoInstead: Set<String> = ["3gp"]

    public static func isAudio(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// Cover art that may already be sitting beside an album.
    ///
    /// Jellyfin accepts four base names for the primary image — folder,
    /// poster, cover, default — so a folder that already has any of them
    /// does not need another.
    public static let coverBaseNames: Set<String> = [
        "folder", "poster", "cover", "default",
    ]

    public static let coverExtensions: Set<String> = ["jpg", "jpeg", "png", "webp"]

    public static func isCoverImage(_ url: URL) -> Bool {
        coverBaseNames.contains(url.deletingPathExtension().lastPathComponent.lowercased())
            && coverExtensions.contains(url.pathExtension.lowercased())
    }
}
