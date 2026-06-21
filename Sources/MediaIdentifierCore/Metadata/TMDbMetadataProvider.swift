import Foundation

/// TMDb-backed metadata provider (FR3). Only the parsed *title and year text*
/// are sent to TMDb to look up the official name — never any media file, which
/// keeps it consistent with FR18 (no media uploaded to the cloud).
///
/// Supports both auth styles automatically:
/// - **v3** API key (32-hex) → sent as the `api_key` query parameter.
/// - **v4** Read Access Token (JWT, contains dots) → sent as
///   `Authorization: Bearer …`.
public struct TMDbMetadataProvider: MetadataProvider {
    private let credential: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.themoviedb.org/3")!

    /// True when the credential is a v4 Read Access Token (JWT) rather than a
    /// v3 key. JWTs contain dots; v3 keys are 32 hex characters.
    private var usesBearer: Bool { credential.contains(".") }

    public init(apiKey: String, session: URLSession? = nil) {
        self.credential = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ephemeral session so a v3 key (carried in the URL query) is not
        // persisted in the shared URL cache.
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    /// Validates the credential against TMDb's `/configuration` endpoint and
    /// returns the HTTP status code (200 = valid, 401 = invalid). Used by the
    /// app's "Verbindung testen" action so users get clear feedback.
    public func verify() async throws -> Int {
        let request = try makeRequest(path: "/configuration", queryItems: [])
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    public func identify(_ parsed: ParsedRelease, at url: URL?) async throws -> MediaMetadata? {
        guard !parsed.title.isEmpty else { return nil }
        let isMovie = parsed.kind != .episode
        let path = isMovie ? "/search/movie" : "/search/tv"

        var query = [URLQueryItem(name: "query", value: parsed.title)]
        if let year = parsed.year {
            query.append(URLQueryItem(name: isMovie ? "year" : "first_air_date_year", value: String(year)))
        }
        let request = try makeRequest(path: path, queryItems: query)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        guard let first = decoded.results.first else { return nil }

        let title = first.title ?? first.name ?? parsed.title
        let dateString = first.releaseDate ?? first.firstAirDate
        let year = dateString.flatMap { Int($0.prefix(4)) } ?? parsed.year

        return MediaMetadata(
            title: title,
            year: year,
            kind: isMovie ? .movie : .episode,
            identifier: first.id.map(String.init)
        )
    }

    /// Builds a request with the right auth (v3 query param vs. v4 Bearer header).
    private func makeRequest(path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw URLError(.badURL)
        }
        var items = queryItems
        if !usesBearer {
            items.insert(URLQueryItem(name: "api_key", value: credential), at: 0)
        }
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        if usesBearer {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "accept")
        }
        return request
    }

    // MARK: TMDb response model

    private struct SearchResponse: Decodable {
        let results: [Result]
        struct Result: Decodable {
            let id: Int?
            let title: String?        // movies
            let name: String?         // tv
            let releaseDate: String?
            let firstAirDate: String?

            enum CodingKeys: String, CodingKey {
                case id, title, name
                case releaseDate = "release_date"
                case firstAirDate = "first_air_date"
            }
        }
    }
}
