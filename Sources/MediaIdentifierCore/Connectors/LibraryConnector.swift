import Foundation

/// A downstream media server that should be told to rescan its library after
/// files have been renamed/moved (FR20). Implementations talk to Jellyfin,
/// Emby, Sonarr/Radarr, … so the connector list can grow without touching the
/// rest of the app.
public protocol LibraryConnector: Sendable {
    /// Human-readable name for UI/logging (e.g. "Plex").
    var name: String { get }

    /// Asks the server to rescan its library so newly renamed files appear.
    func refresh() async throws

    /// Checks connectivity/credentials and returns the HTTP status code
    /// (200 = reachable & authorised). Used by the "Verbindung testen" action.
    func verify() async throws -> Int
}
