#if os(macOS)
import XCTest
@testable import MediaIdentifierCore

/// Tests the pure JSON/tag parsing of `FFprobeMetadataProvider` (no ffprobe
/// binary required).
final class FFprobeMetadataProviderTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testParsesFormatTagsCaseInsensitively() throws {
        let json = """
        {"format":{"tags":{"TITLE":"The Matrix","DATE":"1999-03-31"}}}
        """
        let tags = try XCTUnwrap(FFprobeMetadataProvider.parseFormatTags(data(json)))
        XCTAssertEqual(FFprobeMetadataProvider.value(in: tags, keys: ["title"]), "The Matrix")
        XCTAssertEqual(FFprobeMetadataProvider.value(in: tags, keys: ["date"]), "1999-03-31")
    }

    func testReturnsNilWhenNoTags() {
        XCTAssertNil(FFprobeMetadataProvider.parseFormatTags(data(#"{"format":{}}"#)))
        XCTAssertNil(FFprobeMetadataProvider.parseFormatTags(data(#"{"format":{"tags":{}}}"#)))
        XCTAssertNil(FFprobeMetadataProvider.parseFormatTags(data("not json")))
    }

    func testValueTriesKeysInOrder() {
        let tags = ["year": "2008"]
        XCTAssertEqual(
            FFprobeMetadataProvider.value(in: tags, keys: ["date", "year", "creation_time"]),
            "2008"
        )
        XCTAssertNil(FFprobeMetadataProvider.value(in: tags, keys: ["title"]))
    }

    func testExtractsYearFromVariousDateFormats() {
        XCTAssertEqual(FFprobeMetadataProvider.extractYear("1999-03-31"), 1999)
        XCTAssertEqual(FFprobeMetadataProvider.extractYear("2021"), 2021)
        XCTAssertEqual(FFprobeMetadataProvider.extractYear("2014-08-01T00:00:00Z"), 2014)
        XCTAssertNil(FFprobeMetadataProvider.extractYear("no year here"))
    }
}
#endif
