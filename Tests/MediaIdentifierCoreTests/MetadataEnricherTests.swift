import XCTest
@testable import MediaIdentifierCore

private struct StubProvider: MetadataProvider {
    let metadata: MediaMetadata?
    func identify(_ parsed: ParsedRelease, at url: URL?) async throws -> MediaMetadata? { metadata }
}

final class MetadataEnricherTests: XCTestCase {
    func testEnrichStampsMatchSource() async {
        let enricher = MetadataEnricher(provider: StubProvider(
            metadata: MediaMetadata(title: "The Matrix", year: 1999, kind: .movie, source: "TMDb")
        ))
        let parsed = ParsedRelease(originalFileName: "the.matrix.1999.mkv", title: "The Matrix")
        let result = await enricher.enrich(parsed)
        XCTAssertEqual(result.title, "The Matrix")
        XCTAssertEqual(result.year, 1999)
        XCTAssertEqual(result.matchSource, "TMDb")
    }

    func testEnrichWithoutMatchLeavesSourceNil() async {
        let enricher = MetadataEnricher(provider: StubProvider(metadata: nil))
        let parsed = ParsedRelease(originalFileName: "unknown.mkv", title: "Unknown")
        let result = await enricher.enrich(parsed)
        XCTAssertNil(result.matchSource)
    }

    func testOfflineProviderDoesNotStampSource() async throws {
        let parsed = ParsedRelease(originalFileName: "movie.2020.mkv", title: "Movie", year: 2020)
        let metadata = try await OfflineMetadataProvider().identify(parsed, at: nil)
        XCTAssertNil(metadata?.source)
    }
}
