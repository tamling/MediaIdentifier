import Foundation

/// Folds the folders a file chooser is showing into the stored settings.
///
/// It exists because of an asymmetry that is easy to miss: a chooser showing
/// nothing does not mean the user cleared the folder. `gtk_file_chooser_set_
/// filename` fails silently when the path no longer exists — an unplugged
/// drive, a renamed directory — and the chooser then comes up blank. Writing
/// that blank back would throw away a configured library path because a disk
/// was not mounted, and the user would see only that their settings had
/// quietly emptied.
///
/// So an empty selection leaves the stored value alone. Clearing a folder
/// deliberately is done where there is a field to clear, in the web
/// interface's settings form.
///
/// In Core rather than in the GTK front-end so it can be tested without a
/// display.
public enum FolderSelection {

    /// - Parameters:
    ///   - source: what the source chooser shows, empty when it shows nothing.
    ///   - settings: the current settings; every field this does not touch is
    ///     carried over, so the window cannot reset what the web interface
    ///     owns.
    public static func applying(source: String, movies: String, series: String,
                                to settings: WebSettings) -> WebSettings {
        var updated = settings
        updated.sourceFolder = keep(settings.sourceFolder, orReplaceWith: source)
        updated.moviesFolder = keep(settings.moviesFolder, orReplaceWith: movies)
        updated.seriesFolder = keep(settings.seriesFolder, orReplaceWith: series)
        return updated
    }

    private static func keep(_ current: String, orReplaceWith chosen: String) -> String {
        let trimmed = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? current : trimmed
    }
}
