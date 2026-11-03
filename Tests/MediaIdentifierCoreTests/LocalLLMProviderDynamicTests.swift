import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MediaIdentifierCore

/// Dynamic (integration-style) tests for `LocalLLMMetadataProvider`.
///
/// These drive the real async code path — request construction, status
/// handling, response parsing and the enrichment chain — against a recording
/// transport, so no local model server is required in CI.
///
/// The transport is injected rather than stubbed via `URLProtocol`, because
/// swift-corelibs-foundation on Linux never consults custom protocol classes
/// (see `HTTPTransport`). This way one set of tests covers both platforms.
final class LocalLLMProviderDynamicTests: XCTestCase {

    // MARK: Recording transport

    /// Captures what went on the wire and replies with a scripted response.
    /// `@unchecked Sendable` with a lock: the provider is `Sendable`, so the
    /// transport is read from a concurrent context.
    final class RecordingTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _responder: (URLRequest) -> (Int, Data)
        private var _requests: [URLRequest] = []
        private var _bodies: [Data] = []

        init(responder: @escaping (URLRequest) -> (Int, Data) = { _ in (500, Data()) }) {
            _responder = responder
        }

        func respond(_ block: @escaping (URLRequest) -> (Int, Data)) {
            lock.lock(); defer { lock.unlock() }
            _responder = block
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse?) {
            lock.lock()
            _requests.append(request)
            _bodies.append(request.httpBody ?? Data())
            let responder = _responder
            lock.unlock()

            let (status, data) = responder(request)
            let response = HTTPURLResponse(url: request.url ?? URL(string: "http://invalid")!,
                                           statusCode: status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: nil)
            return (data, response)
        }

        var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _requests.count }
        var lastRequest: URLRequest? { lock.lock(); defer { lock.unlock() }; return _requests.last }
        var lastBody: Data? { lock.lock(); defer { lock.unlock() }; return _bodies.last }
        var lastURL: URL? { lastRequest?.url }
        var lastMethod: String? { lastRequest?.httpMethod }
        var lastHeaders: [String: String]? { lastRequest?.allHTTPHeaderFields }
    }

    private var transport = RecordingTransport()

    override func setUp() {
        super.setUp()
        transport = RecordingTransport()
    }

    private func makeProvider(apiKey: String = "", model: String = "qwen/qwen3.6-35b-a3b")
        -> LocalLLMMetadataProvider {
        LocalLLMMetadataProvider(
            config: .init(baseURL: "http://192.168.3.116:1234", model: model, apiKey: apiKey),
            transport: transport
        )
    }

    private func chatReply(_ content: String) -> Data {
        let payload: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func parsed(_ name: String, season: Int? = nil, episode: Int? = nil,
                        kind: MediaKind = .unknown, year: Int? = nil) -> ParsedRelease {
        ParsedRelease(originalFileName: name, title: "ignored", year: year,
                      season: season, episode: episode, kind: kind)
    }

    // MARK: The request we actually put on the wire

    func testSendsWellFormedRequestToCorrectEndpoint() async throws {
        transport.respond { _ in
            (200, self.chatReply(#"{"title":"The Matrix","year":1999,"is_series":false}"#))
        }
        _ = try await makeProvider(apiKey: "secret-key")
            .identify(parsed("The.Matrix.1999.1080p.BluRay.x265-GRP.mkv"), at: nil)

        XCTAssertEqual(transport.lastURL?.absoluteString,
                       "http://192.168.3.116:1234/v1/chat/completions")
        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastHeaders?["Content-Type"], "application/json")
        XCTAssertEqual(transport.lastHeaders?["Authorization"], "Bearer secret-key")

        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "qwen/qwen3.6-35b-a3b")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("The.Matrix.1999.1080p.BluRay.x265-GRP.mkv"),
                      "the file name must be part of the prompt")
    }

    func testOmitsAuthorizationWhenNoAPIKey() async throws {
        transport.respond { _ in (200, self.chatReply(#"{"title":"Dune","year":2021}"#)) }
        _ = try await makeProvider().identify(parsed("Dune.2021.mkv"), at: nil)
        XCTAssertNil(transport.lastHeaders?["Authorization"])
    }

    /// Nothing but the file name may leave the machine (FR18).
    func testSendsOnlyTheFileName() async throws {
        transport.respond { _ in (200, self.chatReply(#"{"title":"Dune","year":2021}"#)) }
        _ = try await makeProvider()
            .identify(parsed("Dune.2021.mkv"),
                      at: URL(fileURLWithPath: "/Users/private/Movies/Dune.2021.mkv"))
        let text = String(decoding: try XCTUnwrap(transport.lastBody), as: UTF8.self)
        XCTAssertFalse(text.contains("/Users/private"), "the file's location must not be sent")
        XCTAssertTrue(text.contains("Dune.2021.mkv"))
    }

    // MARK: End-to-end happy paths

    func testIdentifiesMovieEndToEnd() async throws {
        transport.respond { _ in
            (200, self.chatReply(#"{"title":"The Matrix","year":1999,"is_series":false}"#))
        }
        let result = try await makeProvider()
            .identify(parsed("The.Matrix.1999.1080p.mkv"), at: nil)
        XCTAssertEqual(result?.title, "The Matrix")
        XCTAssertEqual(result?.year, 1999)
        XCTAssertEqual(result?.kind, .movie)
        XCTAssertEqual(result?.source, "Local LLM")
    }

    /// The configured model is a reasoning model, so this is the realistic shape.
    func testIdentifiesThroughReasoningOutput() async throws {
        let reply = """
        <think>This looks like a TV episode from 2023. The show is The Last of Us.</think>
        ```json
        {"title": "The Last of Us", "year": 2023, "is_series": true}
        ```
        """
        transport.respond { _ in (200, self.chatReply(reply)) }
        let result = try await makeProvider()
            .identify(parsed("the.last.of.us.s01e03.1080p.web.mkv", season: 1, episode: 3), at: nil)
        XCTAssertEqual(result?.title, "The Last of Us")
        XCTAssertEqual(result?.year, 2023)
        XCTAssertEqual(result?.kind, .episode)
    }

    // MARK: Failure handling — must degrade to nil, never throw

    func testHTTPErrorYieldsNil() async throws {
        transport.respond { _ in (500, Data("boom".utf8)) }
        let result = try await makeProvider().identify(parsed("Dune.2021.mkv"), at: nil)
        XCTAssertNil(result)
    }

    func testUnauthorizedYieldsNil() async throws {
        transport.respond { _ in (401, Data()) }
        let result = try await makeProvider().identify(parsed("Dune.2021.mkv"), at: nil)
        XCTAssertNil(result)
    }

    func testGarbageBodyYieldsNil() async throws {
        transport.respond { _ in (200, Data("not json".utf8)) }
        let result = try await makeProvider().identify(parsed("Dune.2021.mkv"), at: nil)
        XCTAssertNil(result)
    }

    func testModelProseWithoutJSONYieldsNil() async throws {
        transport.respond { _ in (200, self.chatReply("I am not sure what this file is.")) }
        let result = try await makeProvider().identify(parsed("Dune.2021.mkv"), at: nil)
        XCTAssertNil(result)
    }

    func testTransportErrorPropagates() async {
        struct Boom: Error {}
        final class FailingTransport: HTTPTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse?) { throw Boom() }
        }
        let provider = LocalLLMMetadataProvider(
            config: .init(baseURL: "http://192.168.3.116:1234", model: "m"),
            transport: FailingTransport()
        )
        do {
            _ = try await provider.identify(parsed("Dune.2021.mkv"), at: nil)
            XCTFail("a transport failure must surface, so the UI can report it")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    func testEmptyModelNameSkipsNetworkEntirely() async throws {
        transport.respond { _ in (200, self.chatReply(#"{"title":"X"}"#)) }
        let result = try await makeProvider(model: "  ").identify(parsed("Dune.2021.mkv"), at: nil)
        XCTAssertNil(result)
        XCTAssertEqual(transport.requestCount, 0, "no request should be sent without a model")
    }

    func testEmptyFileNameSkipsNetworkEntirely() async throws {
        transport.respond { _ in (200, self.chatReply(#"{"title":"X"}"#)) }
        let input = ParsedRelease(originalFileName: "", title: "", kind: .unknown)
        let result = try await makeProvider().identify(input, at: nil)
        XCTAssertNil(result)
        XCTAssertEqual(transport.requestCount, 0)
    }

    // MARK: Connection test

    func testVerifyHitsModelsEndpointAndReturnsStatus() async throws {
        transport.respond { _ in (200, Data(#"{"data":[]}"#.utf8)) }
        let status = try await makeProvider().verify()
        XCTAssertEqual(status, 200)
        XCTAssertEqual(transport.lastURL?.absoluteString,
                       "http://192.168.3.116:1234/v1/models")
    }

    func testVerifyReportsUnauthorized() async throws {
        transport.respond { _ in (401, Data()) }
        let status = try await makeProvider().verify()
        XCTAssertEqual(status, 401)
    }

    // MARK: Regression — the LLM must not clobber parser results

    func testSeasonAndEpisodeSurviveEnrichment() async {
        transport.respond { _ in
            (200, self.chatReply(#"{"title":"The Last of Us","year":2023,"is_series":true}"#))
        }
        let original = parsed("the.last.of.us.s01e03.mkv", season: 1, episode: 3, kind: .episode)
        let enriched = await MetadataEnricher(provider: makeProvider()).enrich(original)
        XCTAssertEqual(enriched.season, 1)
        XCTAssertEqual(enriched.episode, 3)
        XCTAssertEqual(enriched.kind, .episode, "a known kind must not be downgraded")
        XCTAssertEqual(enriched.title, "The Last of Us")
        XCTAssertEqual(enriched.matchSource, "Local LLM")
    }

    /// A movie stays a movie even if the model claims it is a series.
    func testKnownKindIsNotOverriddenByModel() async throws {
        transport.respond { _ in
            (200, self.chatReply(#"{"title":"Dune","year":2021,"is_series":true}"#))
        }
        let result = try await makeProvider()
            .identify(parsed("Dune.2021.mkv", kind: .movie), at: nil)
        XCTAssertEqual(result?.kind, .movie)
    }

    func testParsedYearKeptWhenModelOmitsIt() async throws {
        transport.respond { _ in (200, self.chatReply(#"{"title":"Dune","year":null}"#)) }
        let result = try await makeProvider()
            .identify(parsed("Dune.2021.mkv", year: 2021), at: nil)
        XCTAssertEqual(result?.year, 2021)
    }

    /// When the local model has nothing, the chain must fall through unchanged.
    func testCompositeFallsThroughWhenLLMFails() async throws {
        transport.respond { _ in (503, Data()) }
        let chain = CompositeMetadataProvider([makeProvider(), OfflineMetadataProvider()])
        let input = ParsedRelease(originalFileName: "Dune.2021.mkv", title: "Dune",
                                  year: 2021, kind: .movie)
        let result = try await chain.identify(input, at: nil)
        XCTAssertEqual(result?.title, "Dune")
        XCTAssertNil(result?.source, "offline fallback carries no provenance")
    }
}
