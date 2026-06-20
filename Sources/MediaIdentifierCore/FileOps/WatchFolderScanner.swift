import Foundation

/// Detects newly-arrived, finished media files in a watched folder (FR20:
/// Watch-Folder / automatische Hintergrundverarbeitung).
///
/// A downloaded file may still be growing, so a file is only reported once its
/// size has stayed unchanged between two consecutive polls. State is kept across
/// polls; call `poll(directory:)` on a timer.
public final class WatchFolderScanner {
    private var lastSizes: [String: Int64] = [:]
    private var reported: Set<String> = []
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns video files that are new since watching began and whose size has
    /// been stable since the previous poll.
    public func poll(directory: URL) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var stable: [URL] = []
        var current: [String: Int64] = [:]

        for url in entries where VideoFileTypes.isVideo(url) {
            let path = url.standardizedFileURL.path
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            current[path] = size

            if reported.contains(path) { continue }
            // Report only when the file existed last poll with the same size.
            if let previous = lastSizes[path], previous == size {
                stable.append(url)
                reported.insert(path)
            }
        }

        lastSizes = current
        // Forget files that disappeared so they can be reported again if re-added.
        reported = reported.intersection(current.keys)
        return stable
    }

    /// Clears all state (e.g. when the watched folder changes).
    public func reset() {
        lastSizes.removeAll()
        reported.removeAll()
    }
}
