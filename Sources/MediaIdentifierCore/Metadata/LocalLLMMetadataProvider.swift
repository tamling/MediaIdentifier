import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Identifies titles with a **locally hosted LLM** that speaks the
/// OpenAI-compatible chat API — LM Studio, Ollama or a llama.cpp server
/// (FR3, FR20).
///
/// Only the file name is sent, as plain text, to a server the user runs
/// themselves. No media file ever leaves the machine, so this stays consistent
/// with the local-processing guarantee (FR18). Unlike `AppleIntelligenceProvider`
/// this needs no Apple-only framework, so it also works on Linux.
public struct LocalLLMMetadataProvider: MetadataProvider {
    /// Connection settings for the local model server.
    public struct Config: Sendable, Equatable {
        /// Server base URL, e.g. `http://localhost:1234` (LM Studio default).
        public var baseURL: String
        /// Model identifier as the server reports it, e.g. `qwen/qwen3.6-35b-a3b`.
        public var model: String
        /// Optional API key. LM Studio usually ignores it; sent as a Bearer token
        /// when non-empty.
        public var apiKey: String

        public init(baseURL: String, model: String, apiKey: String = "") {
            self.baseURL = baseURL
            self.model = model
            self.apiKey = apiKey
        }
    }

    private let config: Config
    private let session: URLSession

    public init(config: Config, session: URLSession? = nil) {
        self.config = config
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    // MARK: Identification

    public func identify(_ parsed: ParsedRelease, at url: URL?) async throws -> MediaMetadata? {
        let name = parsed.originalFileName.isEmpty ? parsed.title : parsed.originalFileName
        guard !name.isEmpty,
              !config.model.trimmingCharacters(in: .whitespaces).isEmpty,
              let endpoint = Self.chatURL(from: config.baseURL) else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Self.requestBody(model: config.model, fileName: name)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let content = Self.content(fromChatResponse: data),
              let guess = Self.parseGuess(from: content) else { return nil }

        // Keep the parser's season/episode — regexes are more reliable than an
        // LLM for SxxExx; the model only firms up title / year / kind.
        let kind: MediaKind = guess.isSeries ? .episode : .movie
        return MediaMetadata(
            title: guess.title,
            year: guess.year ?? parsed.year,
            kind: parsed.kind == .unknown ? kind : parsed.kind,
            source: "Local LLM"
        )
    }

    /// Checks that the server is reachable and returns the HTTP status code
    /// (200 = reachable). Uses the OpenAI-compatible `/v1/models` endpoint.
    public func verify() async throws -> Int {
        guard let url = Self.modelsURL(from: config.baseURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    // MARK: URL building (pure, testable)

    /// Normalises a user-entered base URL into the chat-completions endpoint.
    /// Accepts `http://host:1234`, `…/v1` and the full `…/v1/chat/completions`.
    public static func chatURL(from base: String) -> URL? {
        normalised(base, suffix: "chat/completions")
    }

    /// Endpoint used for the connection test.
    public static func modelsURL(from base: String) -> URL? {
        normalised(base, suffix: "models")
    }

    private static func normalised(_ base: String, suffix: String) -> URL? {
        var text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/v1/chat/completions") {
            text = String(text.dropLast("/chat/completions".count))
        }
        if !text.hasSuffix("/v1") { text += "/v1" }
        guard let url = URL(string: text + "/" + suffix),
              url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    // MARK: Request / response shaping (pure, testable)

    /// Builds the OpenAI-compatible chat-completions body. Temperature 0 keeps
    /// the answer deterministic; the prompt demands bare JSON.
    public static func requestBody(model: String, fileName: String) -> Data? {
        let system = """
        You identify movies and TV shows from messy release file names. \
        Reply with ONLY a single JSON object and nothing else, in this exact shape:
        {"title": "Official Title", "year": 1999, "is_series": false}
        Rules: use the official English title without release tags, resolution, \
        codec or group names. If the year is unknown use null. Set is_series to \
        true for episodes of a TV show, false for movies. No explanation.
        """
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": "File name: \(fileName)"],
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// Extracts the assistant message text from an OpenAI-compatible response.
    public static func content(fromChatResponse data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }

    /// The model's answer, parsed leniently.
    public struct Guess: Equatable, Sendable {
        public let title: String
        public let year: Int?
        public let isSeries: Bool
    }

    /// Pulls the JSON object out of a model reply. Tolerates reasoning models
    /// (`<think>…</think>`), Markdown code fences and surrounding prose.
    public static func parseGuess(from content: String) -> Guess? {
        let cleaned = stripReasoning(content)
        guard let json = firstJSONObject(in: cleaned),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }

        guard let rawTitle = object["title"] as? String else { return nil }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        // Year may arrive as a number or a string; anything implausible is dropped.
        var year: Int?
        if let number = object["year"] as? Int { year = number }
        else if let text = object["year"] as? String { year = Int(text.prefix(4)) }
        if let value = year, value < 1870 || value > 2200 { year = nil }

        let isSeries = (object["is_series"] as? Bool)
            ?? ((object["is_series"] as? String)?.lowercased() == "true")
        return Guess(title: title, year: year, isSeries: isSeries)
    }

    /// Removes `<think>…</think>` blocks emitted by reasoning models such as
    /// Qwen3. An unclosed block means the answer never arrived.
    static func stripReasoning(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>") {
            guard let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex)
            else {
                result = String(result[result.startIndex..<open.lowerBound])
                break
            }
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First balanced `{…}` run in the text, ignoring braces inside strings.
    static func firstJSONObject(in text: String) -> String? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { break }
                depth -= 1
                if depth == 0, let start {
                    return String(text[start...index])
                }
            default: break
            }
        }
        return nil
    }
}
