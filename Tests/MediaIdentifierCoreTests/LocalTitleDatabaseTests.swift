import XCTest
@testable import MediaIdentifierCore

final class LocalTitleDatabaseTests: XCTestCase {

    private func makeDB() -> LocalTitleDatabase {
        LocalTitleDatabase(entries: [
            .init(title: "Interstellar", year: 2014, kind: .movie, popularity: 90),
            .init(title: "The Last of Us", year: 2023, kind: .episode, popularity: 80),
            .init(title: "Dune: Part Two", year: 2024, kind: .movie, popularity: 95),
            .init(title: "Oppenheimer", year: 2023, kind: .movie, popularity: 88)
        ])
    }

    func testExactMatchNormalisesPunctuationAndCase() {
        let db = makeDB()
        // "dune part two" should match "Dune: Part Two" (punctuation folded).
        let match = db.match(title: "Dune Part Two", year: 2024, kind: .movie)
        XCTAssertEqual(match?.title, "Dune: Part Two")
        XCTAssertEqual(match?.year, 2024)
    }

    func testFuzzyMatchToleratesTypos() {
        let db = makeDB()
        let match = db.match(title: "Interstelar", year: nil, kind: .movie)
        XCTAssertEqual(match?.title, "Interstellar")
    }

    func testKindPreferenceAndNoFalsePositive() {
        let db = makeDB()
        XCTAssertEqual(db.match(title: "The Last of Us", year: nil, kind: .episode)?.kind, .episode)
        XCTAssertNil(db.match(title: "Completely Unknown Film", year: nil, kind: .movie))
    }

    func testParsesNDJSONExport() throws {
        let ndjson = """
        {"id":1,"original_title":"Interstellar","popularity":90.0}
        {"id":2,"original_name":"The Last of Us","popularity":80.0}
        """
        let entries = try LocalTitleDatabaseLoader.parse(Data(ndjson.utf8))
        XCTAssertEqual(entries.count, 2)
        let db = LocalTitleDatabase(entries: entries)
        XCTAssertEqual(db.match(title: "Interstellar", year: nil, kind: .movie)?.kind, .movie)
        XCTAssertEqual(db.match(title: "The Last of Us", year: nil, kind: .episode)?.kind, .episode)
    }

    func testParsesGenericJSONArray() throws {
        let json = """
        [{"title":"Oppenheimer","year":2023,"kind":"movie"}]
        """
        let entries = try LocalTitleDatabaseLoader.parse(Data(json.utf8))
        XCTAssertEqual(entries.first?.title, "Oppenheimer")
        XCTAssertEqual(entries.first?.year, 2023)
    }
}
