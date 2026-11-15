import Foundation

/// Writes back only the fields the user actually changed.
///
/// The window reads the settings once, at startup, and its widgets are that
/// snapshot for the life of the window. Pressing Apply used to write every
/// widget unconditionally, so a field somebody else had changed in the
/// meantime — a second window, a hand-edited settings.json, anything sharing
/// the configuration directory — was quietly set back to what this window
/// had seen hours ago.
///
/// The schedule was the one that mattered: turn the nightly run on
/// elsewhere, then pick a new films folder here and press Apply, and
/// `isEnabled` goes back to false. The run never fires and nothing says a
/// schedule setting was touched. It works in the other direction too, which
/// is worse: a schedule the user had turned off gets re-armed, and the
/// program starts moving files with nobody looking.
///
/// `AppWindow.loadedSettings` has carried a comment describing exactly this
/// defence since it was written. It had no reader: the field was assigned
/// once and never consulted. This is the rule it described, in Core and
/// testable, for the same reason `FolderSelection` is here.
public enum SettingsMerge {

    /// - Parameters:
    ///   - typed: the settings as the widgets read right now.
    ///   - loaded: the settings the widgets were filled from. A field equal
    ///     to this one was not touched by the user.
    ///   - stored: the settings as they are now, which may have moved on.
    /// - Returns: `stored` with the changed fields of `typed` applied.
    ///
    /// The folder paths are not here: they go through `FolderSelection`,
    /// whose rule is different and stricter (a blank chooser means GTK could
    /// not show the path, not that the user cleared it).
    public static func applying(typed: WebSettings, loaded: WebSettings,
                                to stored: WebSettings) -> WebSettings {
        var result = stored
        apply(typed.localLLMBaseURL, loaded.localLLMBaseURL, &result.localLLMBaseURL)
        apply(typed.localLLMModel, loaded.localLLMModel, &result.localLLMModel)
        apply(typed.jellyfinBaseURL, loaded.jellyfinBaseURL, &result.jellyfinBaseURL)
        apply(typed.language, loaded.language, &result.language)
        apply(typed.identification, loaded.identification, &result.identification)
        apply(typed.libraryMode, loaded.libraryMode, &result.libraryMode)
        apply(typed.conflictPolicy, loaded.conflictPolicy, &result.conflictPolicy)
        apply(typed.watchSourceFolder, loaded.watchSourceFolder,
              &result.watchSourceFolder)
        apply(typed.conversion, loaded.conversion, &result.conversion)
        // Field by field rather than whole, because the schedule has five of
        // them and a window that only changed the time must not also write
        // back a stale "enabled".
        apply(typed.schedule.isEnabled, loaded.schedule.isEnabled,
              &result.schedule.isEnabled)
        apply(typed.schedule.alsoRename, loaded.schedule.alsoRename,
              &result.schedule.alsoRename)
        apply(typed.schedule.cadence, loaded.schedule.cadence,
              &result.schedule.cadence)
        apply(typed.schedule.hour, loaded.schedule.hour, &result.schedule.hour)
        apply(typed.schedule.minute, loaded.schedule.minute, &result.schedule.minute)
        apply(typed.schedule.everyHours, loaded.schedule.everyHours,
              &result.schedule.everyHours)
        return result
    }

    private static func apply<T: Equatable>(_ typed: T, _ loaded: T,
                                            _ stored: inout T) {
        if typed != loaded { stored = typed }
    }
}
