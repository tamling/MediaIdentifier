import XCTest
@testable import MediaIdentifierCore

/// Dynamic (integration-style) tests for `LocalLLMMetadataProvider`.
///
/// These exercise the real async `URLSession` path — request construction,
/// transport, status handling and response parsing — against a stubbed
/// transport, so no local model server is required in CI.
final class LocalLLMProviderDynamicTests: XCTestCase {

    // MARK: Stub transport

    /// Thread-safe holder so the stub stays usable under Swift's concurrency
    /// checking without relying on newer language features.
    final class Stub: @unchecked Sendable {
        private let lock = NSLock()
        private var _responder: ((URLRequest, Data) -> (Int, Data))?
        private var _lastURL: URL?
        private var _lastMethod: String?
        private var _lastHeaders: [String: String]?
        private var _lastBody: Data?

        static let shared = Stub()

        func reset() {
            lock.lock(); defer { lock.unlock() }
            _responder = nil; _lastURL = nil; _lastMethod = nil
            _lastHeaders = nil; _lastBody = nil
        }
        func respond(_ block: @escaping (URLRequest, Data) -> (Int, Data)) {
            lock.lock(); defer { lock.unlock() }
            _responder = block
        }
        func record(url: URL?, method: String?, headers: [String: String]?, body: Data) {
            lock.lock(); defer { lock.unlock() }
            _lastURL = url; _lastMethod = method; _lastHeaders = headers; _lastBody = body
        }
        func handle(_ request: URLRequest, _ body: Data) -> (Int, Data) {
            lock.lock(); let responder = _responder; lock.unlock()
            return responder?(request, body) ?? (500, Data())
        }
        var lastURL: URL? { lock.lock(); defer { lock.unlock() }; return _lastURL }
        var lastMethod: String? { lock.lock(); defer { lock.unlock() }; return _lastMethod }
        var lastHeaders: [String: String]? { lock.lock(); defer { lock.unlock() }; return _lastHeaders }
        var lastBody: Data? { lock.lock(); defer { lock.unlock() }; return _lastBody }
    }

    final class StubURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let body = Self.readBody(from: request)
            Stub.shared.record(url: request.url,
                               method: request.httpMethod,
                               headers: request.allHTTPHeaderFields,
                               body: body)
            let (status, data) = Stub.shared.handle(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        /// URLSession moves the body into a stream, so read both forms.
        private static func readBody(from request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 4096
            var buffer = [UInt8](repeating: 0, count: size)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    private func makeProvider(apiKey: String = "") -> LocalLLMMetadataProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return LocalLLMMetadataProvider(
            config: .init(baseURL: "http://192.168.3.116:1234",
                          model: "qwen/qwen3.6-35b-a3b",
                          apiKey: apiKey),
            session: URLSession(configuration: configuration)
        )
    }

    private func chatReply(_ content: String) -> Data {
        let payload: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    override func setUp() {
        super.setUp()
        Stub.shared.reset()
    }

    private func parsed(_ name: String, season: Int? = nil, episode: Int? = nil,
                        kind: MediaKind = .unknown, year: Int? = nil) -> ParsedRelease {
        ParsedRelease(originalFileName: name, title: "ignored", year: year,
                      season: season, episode: episode, kind: kind)
    }

    // MARK: The request we actually put on the wire

    func testSendsWellFormedRequestToCorrectEndpoint() async throws {
        Stub.shared.respond { _, _ in
            (200, self.chatReply(#"{"title":"The Matrix","year":1999,"is_series":false}"#))
        }
        _ = try await makeProvider(apiKey: "secret-key")
            .identify(parsed("The.Matrix.1999.1080p.BluRay.x265-GRP.mkv"), at: nil)

        XCTAssertEqual(Stub.shared.lastURL?.absoluteString,
                       "http://192.168.3.116:1234/v1/chat/completions")
        XCTAssertEqual(Stub.shared.lastMethod, "POST")
        XCTAssertEqual(Stub.shared.lastHeaders?["Content-Type"], "application/json")
        XCTAssertEqual(Stub.shared.lastHeaders?["Authorization"], "Bearer secret-key")

        let body = try XCTUnwrap(Stub.shared.lastBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "qwen/qwen3.6-35b-a3b")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("The.Matrix.1999.1080p.BluRay.x265-GRP.mkv"),
                      "the file name must be part of the prompt")
    }

    func testOmitsAuthorizationWhenNoAPIKey() async throws {
        Stub.shared.respond { _, _ in (200, self.chatReply(#"{"title":"Dune","year":2021}"#)) }
        _ = try await makeProvider().identify(parsed("Dune.2021.mkv"), at: nil)
        XCTAssertNil(Stub.shared.lastHeaders?["Authorization"])
    }

    // MARK: End-to-end happy paths

    func testIdentifiesMovieEndToEnd() async throws {
        Stub.shared.respond { _, _ in
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
        Stub.shared.respond { _, _ in (200, self.chatReply(reply)) }
        let result = try await makeProvider()
            .identify(parsed("the.last.of.us.s01e03.1080p.web.mkv", season: 1, episode: 3), at: nil)
        XCTAssertEqual(result?.title, "The Last of Us")
        XCTAssertEqual(result?.year, 2023)
    }

    // MARK: Failure handling — must degrade to nil, never throw

    func testHTTPErrorYieldsNil() async throws {
        Stub.shared.respond { _, _ in (500, Data("boom".utf8)) }
        let result = try await makeProvider().identify(parsed("Dune.2021.mkv"), at: nil)
        XCTAssertNil(result)
    }

    func testUnauthorizedYieldsNil() async throws {
        Stub.shared.respond { _, _ in (401, Data()) }
        let result = try await makeProvider().identify(parsed("Dune.2021.mkv"), at: nil)
        XCTAssertNil(result)
    }

    func testGarbageBodyYieldsNil() async throws {
        Stub.shared.respond { _, _ in (200, Data("not json".utf8)) }
        XCTAssertNil(try await makeProvider().identify(parsed("Dune.2021.mkv"), at: nil))
    }

    func testModelProseWithoutJSONYieldsNil() async throws {
        Stub.shared.respond { _, _ in (200, self.chatReply("I am not sure what this file is.")) }
        XCTAssertNil(try await makeProvider().identify(parsed("Dune.2021.mkv"), at: nil))
    }

    func testEmptyModelNameSkipsNetworkEntirely() async throws {
        Stub.shared.respond { _, _ in (200, self.chatReply(#"{"title":"X"}"#)) }
        let provider = LocalLLMMetadataProvider(
            config: .init(baseURL: "http://192.168.3.116:1234", model: "  "),
            session: URLSession(configuration: {
                let c = URLSessionConfiguration.ephemeral
                c.protocolClasses = [StubURLProtocol.self]
                return c
            }())
        )
        XCTAssertNil(try await provider.identify(parsed("Dune.2021.mkv"), at: nil))
        XCTAssertNil(Stub.shared.lastURL, "no request should be sent without a model")
    }

    // MARK: Connection test

    func testVerifyHitsModelsEndpointAndReturnsStatus() async throws {
        Stub.shared.respond { _, _ in (200, Data(#"{"data":[]}"#.utf8)) }
        let status = try await makeProvider().verify()
        XCTAssertEqual(status, 200)
        XCTAssertEqual(Stub.shared.lastURL?.absoluteString,
                       "http://192.168.3.116:1234/v1/models")
    }

    func testVerifyReportsUnauthorized() async throws {
        Stub.shared.respond { _, _ in (401, Data()) }
        let status = try await makeProvider().verify()
        XCTAssertEqual(status, 401)
    }

    // MARK: Regression — the LLM must not clobber parser results

    func testSeasonAndEpisodeSurviveEnrichment() async {
        Stub.shared.respond { _, _ in
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

    func testParsedYearKeptWhenModelOmitsIt() async throws {
        Stub.shared.respond { _, _ in (200, self.chatReply(#"{"title":"Dune","year":null}"#)) }
        let result = try await makeProvider()
            .identify(parsed("Dune.2021.mkv", year: 2021), at: nil)
        XCTAssertEqual(result?.year, 2021)
    }

    /// When the local model has nothing, the chain must fall through unchanged.
    func testCompositeFallsThroughWhenLLMFails() async throws {
        Stub.shared.respond { _, _ in (503, Data()) }
        let chain = CompositeMetadataProvider([makeProvider(), OfflineMetadataProvider()])
        let input = ParsedRelease(originalFileName: "Dune.2021.mkv", title: "Dune",
                                  year: 2021, kind: .movie)
        let result = try await chain.identify(input, at: nil)
        XCTAssertEqual(result?.title, "Dune")
        XCTAssertNil(result?.source, "offline fallback carries no provenance")
    }
}
