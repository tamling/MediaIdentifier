import Foundation

/// TMDb-backed metadata provider (FR3). Only the parsed *title and year text*
/// are sent to TMDb to look up the official name — never any media file, which
/// keeps it consistent with FR18 (no media uploaded to the cloud).
///
/// Requires a free TMDb API key. Disabled by default; the app uses
/// `OfflineMetadataProvider` unless a key is supplied.
public struct TMDbMetadataProvider: MetadataProvider {
    private let apiKey: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.themoviedb.org/3")!

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func identify(_ parsed: ParsedRelease, at url: URL?) async throws -> MediaMetadata? {
        guard !parsed.title.isEmpty else { return nil }
        let isMovie = parsed.kind != .episode
        let path = isMovie ? "/search/movie" : "/search/tv"

        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: parsed.title)
        ]
        if let year = parsed.year {
            query.append(URLQueryItem(name: isMovie ? "year" : "first_air_date_year", value: String(year)))
        }
        components.queryItems = query

        let (data, response) = try await session.data(from: components.url!)
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
