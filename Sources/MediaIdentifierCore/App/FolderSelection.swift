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
    /// Every folder the window has a chooser for is a parameter here, with no
    /// default, deliberately.
    ///
    /// The music folder used to be folded by hand in the settings window
    /// instead, one line after the call to this -- and the merge that ran
    /// nine lines later started again from the settings this returns and
    /// threw the chosen path away, while the label reported it applied. It
    /// was the only `problems()`-validated field the window had no way to
    /// write, which also made an already-invalid stored music folder a dead
    /// end: the guard refused every Apply and no control could correct it.
    /// A required parameter is what makes a fifth chooser impossible to add
    /// without deciding where it folds.
    public static func applying(source: String, movies: String, series: String,
                                music: String,
                                to settings: WebSettings) -> WebSettings {
        var updated = settings
        updated.sourceFolder = keep(settings.sourceFolder, orReplaceWith: source)
        updated.moviesFolder = keep(settings.moviesFolder, orReplaceWith: movies)
        updated.seriesFolder = keep(settings.seriesFolder, orReplaceWith: series)
        updated.musicFolder = keep(settings.musicFolder, orReplaceWith: music)
        return updated
    }

    private static func keep(_ current: String, orReplaceWith chosen: String) -> String {
        let trimmed = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? current : trimmed
    }
}
