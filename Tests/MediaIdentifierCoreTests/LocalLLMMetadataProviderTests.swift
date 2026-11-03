import XCTest
@testable import MediaIdentifierCore

final class LocalLLMMetadataProviderTests: XCTestCase {
    private typealias P = LocalLLMMetadataProvider

    // MARK: Endpoint normalisation

    func testChatURLFromPlainHostAndPort() {
        XCTAssertEqual(P.chatURL(from: "http://192.168.3.116:1234")?.absoluteString,
                       "http://192.168.3.116:1234/v1/chat/completions")
    }

    func testChatURLToleratesTrailingSlashAndWhitespace() {
        XCTAssertEqual(P.chatURL(from: "  http://localhost:1234/  ")?.absoluteString,
                       "http://localhost:1234/v1/chat/completions")
    }

    func testChatURLAcceptsExplicitV1AndFullPath() {
        XCTAssertEqual(P.chatURL(from: "http://localhost:1234/v1")?.absoluteString,
                       "http://localhost:1234/v1/chat/completions")
        XCTAssertEqual(P.chatURL(from: "http://localhost:1234/v1/chat/completions")?.absoluteString,
                       "http://localhost:1234/v1/chat/completions")
    }

    func testModelsURL() {
        XCTAssertEqual(P.modelsURL(from: "http://192.168.3.116:1234")?.absoluteString,
                       "http://192.168.3.116:1234/v1/models")
    }

    func testInvalidBaseURLsRejected() {
        XCTAssertNil(P.chatURL(from: ""))
        XCTAssertNil(P.chatURL(from: "   "))
        XCTAssertNil(P.chatURL(from: "not a url"))
        XCTAssertNil(P.chatURL(from: "/no/scheme"))
    }

    // MARK: Request body

    func testRequestBodyCarriesModelAndFileName() throws {
        let data = try XCTUnwrap(P.requestBody(model: "qwen/qwen3.6-35b-a3b",
                                               fileName: "The.Matrix.1999.1080p.mkv"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "qwen/qwen3.6-35b-a3b")
        XCTAssertEqual(object["temperature"] as? Int, 0)
        XCTAssertEqual(object["stream"] as? Bool, false)
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertEqual(messages.last?["role"], "user")
        XCTAssertTrue(messages.last?["content"]?.contains("The.Matrix.1999.1080p.mkv") ?? false)
    }

    // MARK: Response extraction

    func testContentExtractedFromChatResponse() {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"hello"}}]}"#
        XCTAssertEqual(P.content(fromChatResponse: Data(json.utf8)), "hello")
    }

    func testContentNilForGarbage() {
        XCTAssertNil(P.content(fromChatResponse: Data("not json".utf8)))
        XCTAssertNil(P.content(fromChatResponse: Data(#"{"choices":[]}"#.utf8)))
    }

    // MARK: Lenient guess parsing

    func testParsesPlainJSON() {
        let guess = P.parseGuess(from: #"{"title":"The Matrix","year":1999,"is_series":false}"#)
        XCTAssertEqual(guess, P.Guess(title: "The Matrix", year: 1999, isSeries: false))
    }

    func testParsesFencedJSON() {
        let content = """
        ```json
        {"title": "The Last of Us", "year": 2023, "is_series": true}
        ```
        """
        XCTAssertEqual(P.parseGuess(from: content),
                       P.Guess(title: "The Last of Us", year: 2023, isSeries: true))
    }

    func testParsesAfterReasoningBlock() {
        // Qwen3-style reasoning models emit <think>…</think> before the answer.
        let content = """
        <think>The file name looks like a 1999 movie, probably The Matrix.</think>
        {"title":"The Matrix","year":1999,"is_series":false}
        """
        XCTAssertEqual(P.parseGuess(from: content),
                       P.Guess(title: "The Matrix", year: 1999, isSeries: false))
    }

    func testParsesWithSurroundingProse() {
        let content = "Sure! Here is the result: {\"title\":\"Dune\",\"year\":2021,\"is_series\":false} Hope that helps."
        XCTAssertEqual(P.parseGuess(from: content),
                       P.Guess(title: "Dune", year: 2021, isSeries: false))
    }

    func testYearAsStringAndNullHandled() {
        XCTAssertEqual(P.parseGuess(from: #"{"title":"Dune","year":"2021","is_series":false}"#)?.year, 2021)
        XCTAssertNil(P.parseGuess(from: #"{"title":"Dune","year":null,"is_series":false}"#)?.year)
    }

    func testImplausibleYearDropped() {
        XCTAssertNil(P.parseGuess(from: #"{"title":"X","year":12,"is_series":false}"#)?.year)
        XCTAssertNil(P.parseGuess(from: #"{"title":"X","year":9999,"is_series":false}"#)?.year)
    }

    func testMissingOrEmptyTitleRejected() {
        XCTAssertNil(P.parseGuess(from: #"{"year":1999,"is_series":false}"#))
        XCTAssertNil(P.parseGuess(from: #"{"title":"   ","year":1999}"#))
        XCTAssertNil(P.parseGuess(from: "no json at all"))
    }

    // MARK: Helpers

    func testStripReasoningRemovesBlocks() {
        XCTAssertEqual(P.stripReasoning("<think>abc</think>result"), "result")
        // An unclosed block means the answer never came.
        XCTAssertEqual(P.stripReasoning("before<think>unterminated"), "before")
    }

    func testFirstJSONObjectIgnoresBracesInsideStrings() {
        let text = #"{"title":"A {weird} title","year":2000}"#
        XCTAssertEqual(P.firstJSONObject(in: text), text)
    }

    func testFirstJSONObjectNilWhenAbsent() {
        XCTAssertNil(P.firstJSONObject(in: "nothing here"))
    }
}
