import Foundation

/// Working out which folder to open for a file that is not there yet.
///
/// A proposal names where a file *will* go, and before the rename that folder
/// does not exist: `~/Downloads/Fargo/Season 05/` is created when the move
/// happens and not a moment earlier. Handing that path to a file manager gets
/// nothing — the window would have a button that does nothing, which is the
/// fault this program has already been through once today.
///
/// So the answer is the deepest folder on that path that does exist. For a
/// destination of `~/Downloads/Fargo/Season 05/Fargo - S05E10.mkv` with
/// nothing created yet, that is `~/Downloads`, which is both a true answer and
/// a useful one: it is where the file is now.
///
/// In Core rather than beside the window because it is a rule, and a rule can
/// be tested without a screen.
public enum FolderReveal {

    /// The deepest existing directory at or above `url`.
    ///
    /// Returns nil only when even the root is not a directory, which should
    /// not happen but is not worth crashing over.
    public static func nearestExistingDirectory(
        for url: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidate = url.standardizedFileURL
        // Bounded rather than `while true`: a path is finite, but a URL that
        // never shortens — which `deletingLastPathComponent` can produce at
        // the root — would otherwise spin for ever.
        for _ in 0...candidate.pathComponents.count {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path,
                                      isDirectory: &isDirectory) {
                if isDirectory.boolValue { return candidate }
                // A file: its own folder is the answer, and that folder
                // certainly exists because the file is in it.
                return candidate.deletingLastPathComponent()
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return nil
    }
}
