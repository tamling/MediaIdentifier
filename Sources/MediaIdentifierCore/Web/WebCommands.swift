import Foundation

/// Something the interface asks the app to do.
///
/// Commands are submitted and acknowledged immediately; anything slow (a scan,
/// a rename, a connection test) runs in the background and reports back
/// through `StatusSnapshot`. That keeps request handling free of long waits and
/// means a reload never re-triggers work.
public enum WebCommand: Sendable, Equatable {
    case saveSettings(WebSettings)
    /// An empty value clears the secret.
    case setSecret(SecretKey, String)
    case testLocalLLMConnection
    case testJellyfinConnection
    case scanSourceFolder
    /// Takes these files and folders as they are, and ADDS proposals for them
    /// to what is already listed.
    ///
    /// Adds rather than replaces, because the gesture is "and this one too":
    /// a drop that cleared the list would lose the twenty proposals already
    /// being worked through. The import folder is not consulted at all — the
    /// point is the file somebody pointed at.
    case addFiles([URL])
    /// Applies the proposed renames. `accepting` lists the items the user
    /// ticked; nil means every proposal.
    case applyProposedRenames(accepting: Set<UUID>?)
    case undoLastRename
    /// Looks for files that could be converted, so the page has something to
    /// show. Does not convert anything.
    case findConvertible
    /// Converts the files the user ticked. Never started on its own.
    case convertFiles(accepting: Set<UUID>)
    case cancelConversions
    /// Sends the files the user ticked to the remote library, sorted into the
    /// proposed folders. Never started on its own.
    /// Ticks or unticks every proposal.
    ///
    /// Server-side because the web interface forbids JavaScript outright in
    /// its own Content-Security-Policy, so "select all" cannot be a script.
    /// Keeping the state in the engine also means a reload does not lose it.
    case setAllAccepted(Bool)
    /// Ticks or unticks one proposal.
    ///
    /// The web page has no need of this — its checkboxes carry the whole
    /// selection in the form that applies it — but a terminal has no form,
    /// and the counts in its header come from the engine, so the engine has
    /// to be where a tick is recorded.
    case setAccepted(UUID, Bool)
    case transferFiles(accepting: Set<UUID>)
    case cancelTransfers
    /// Fetches one URL into the import folder with yt-dlp, then scans, so
    /// the download appears as a proposal like anything else that lands
    /// there. Never started on its own.
    case downloadURL(String)
    case cancelDownload
    /// Logs in to the server and checks the target path, for the status panel.
    case testRemoteConnection
    /// Runs every connection test there is, so one press answers "is
    /// everything there?" instead of three.
    case checkEverything
    case clearHistory
}

/// Accepts commands from the interface. Implementations must return at once.
public protocol WebCommandSink: Sendable {
    func submit(_ command: WebCommand)
}
