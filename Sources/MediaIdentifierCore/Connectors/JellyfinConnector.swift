import Foundation

/// Tells a local Jellyfin server to rescan its library after files were renamed
/// or moved, so they are exported into the library automatically (FR20).
///
/// Jellyfin exposes an HTTP API (default port 8096):
/// - `POST /Library/Refresh` triggers a scan of all libraries.
/// - `GET /System/Info` validates the API key.
/// Authentication uses an API key (Dashboard → API-Schlüssel), sent via the
/// `Authorization: MediaBrowser Token="…"` header (with `X-Emby-Token` as a
/// widely-supported fallback). Only a scan trigger is sent — no media leaves the
/// machine, consistent with FR18. As Jellyfin typically runs locally, this stays
/// on the LAN.
public struct JellyfinConnector: LibraryConnector {
    public let name = "Jellyfin"
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    /// - Parameters:
    ///   - serverURL: e.g. `http://localhost:8096` (scheme required).
    ///   - apiKey: a Jellyfin API key.
    public init(serverURL: String, apiKey: String, session: URLSession? = nil) throws {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw URLError(.badURL)
        }
        self.baseURL = url
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    public func refresh() async throws {
        var request = makeRequest(path: "/Library/Refresh")
        request.httpMethod = "POST"
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    public func verify() async throws -> Int {
        // /System/Info requires a valid API key (401/403 otherwise).
        let request = makeRequest(path: "/System/Info")
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    /// Authorization header value Jellyfin expects for token auth.
    static func authorizationHeader(apiKey: String) -> String {
        "MediaBrowser Token=\"\(apiKey)\""
    }

    private func makeRequest(path: String) -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.setValue(Self.authorizationHeader(apiKey: apiKey), forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
