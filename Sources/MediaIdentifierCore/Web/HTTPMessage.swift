import Foundation

/// A parsed HTTP/1.1 request.
///
/// Pure value type with no networking, so parsing can be tested exhaustively
/// and the same code serves both the macOS listener and the portable socket
/// listener used on Linux.
public struct HTTPRequest: Sendable, Equatable {
    /// Upper-cased verb, e.g. `GET`.
    public var method: String
    /// Path with the query string removed and percent-escapes decoded, e.g.
    /// `/api/status`.
    ///
    /// Decoded means `%2F` has already become `/`, which is convenient for
    /// matching fixed routes but must never be joined onto a directory without
    /// sanitising first — see `JellyfinNamer.sanitizeRelativePath`.
    public var path: String
    /// Decoded query parameters. Repeated keys keep the first value.
    public var query: [String: String]
    /// Header fields with lower-cased names, so lookups need no case juggling.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:],
                headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// True for the read-only verbs this app's web interface serves without
    /// any side effects.
    public var isReadOnly: Bool { method == "GET" || method == "HEAD" }

    /// Body length the client announced, 0 when absent or unparsable.
    public var declaredContentLength: Int {
        headers["content-length"].flatMap(Int.init).map { max(0, $0) } ?? 0
    }
}

/// A response to be written back to the socket.
public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var contentType: String
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, contentType: String = "text/plain; charset=utf-8",
                headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.headers = headers
        self.body = body
    }

    // MARK: Convenience constructors

    public static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    public static func html(_ html: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/html; charset=utf-8", body: Data(html.utf8))
    }

    public static func json(_ body: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json", body: body)
    }

    public static func notFound() -> HTTPResponse { .text("not found", status: 404) }
    public static func methodNotAllowed() -> HTTPResponse { .text("method not allowed", status: 405) }
    public static func badRequest(_ reason: String = "bad request") -> HTTPResponse {
        .text(reason, status: 400)
    }

    /// Serialises headers and body into the bytes to put on the wire.
    ///
    /// `omitBody` serves a HEAD request: the headers (including the real
    /// `Content-Length`) are sent, the body is not.
    ///
    /// Deliberately absent: `Access-Control-Allow-Origin`. Without it a page on
    /// some other site cannot read this server's responses from a visitor's
    /// browser.
    public func serialized(omitBody: Bool = false) -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(for: status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            // Strip CR/LF so a header value can never inject extra headers.
            let clean = value.replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
            head += "\(name): \(clean)\r\n"
        }
        head += "\r\n"
        return omitBody ? Data(head.utf8) : Data(head.utf8) + body
    }

    public static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 303: return "See Other"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return status < 400 ? "OK" : "Error"
        }
    }
}

/// Incremental HTTP/1.1 request parser.
///
/// A socket read returns whatever arrived, which may be half a header line or a
/// head without its body. Feed bytes in until `request` is non-nil.
public struct HTTPRequestParser {
    /// Hard cap on a single request. The web interface only ever receives small
    /// form posts, so anything larger is refused rather than buffered.
    public static let maxRequestBytes = 64 * 1024

    private var buffer = Data()
    /// Set once the request exceeded `maxRequestBytes`.
    public private(set) var isTooLarge = false

    public init() {}

    /// Appends bytes. Returns the complete request once it has fully arrived.
    public mutating func feed(_ data: Data) -> HTTPRequest? {
        guard !isTooLarge else { return nil }
        buffer.append(data)
        if buffer.count > Self.maxRequestBytes {
            isTooLarge = true
            return nil
        }
        return complete()
    }

    /// The request, if the buffer already holds all of it.
    private func complete() -> HTTPRequest? {
        guard let headEnd = Self.endOfHead(in: buffer) else { return nil }
        let headData = buffer[buffer.startIndex..<headEnd.headLimit]
        guard var request = Self.parseHead(headData) else { return nil }

        let available = buffer.count - (headEnd.bodyStart - buffer.startIndex)
        let expected = request.declaredContentLength
        guard available >= expected else { return nil }
        if expected > 0 {
            let start = headEnd.bodyStart
            request.body = Data(buffer[start..<(start + expected)])
        }
        return request
    }

    /// Finds the blank line that ends the head. Accepts LF-only line endings as
    /// well as CRLF, because hand-written clients (curl pipes, test harnesses)
    /// send both.
    static func endOfHead(in data: Data) -> (headLimit: Int, bodyStart: Int)? {
        let bytes = [UInt8](data)
        let base = data.startIndex
        var index = 0
        while index + 1 < bytes.count {
            if bytes[index] == 0x0A, bytes[index + 1] == 0x0A {              // \n\n
                return (base + index + 1, base + index + 2)
            }
            if index + 3 < bytes.count,
               bytes[index] == 0x0D, bytes[index + 1] == 0x0A,
               bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {          // \r\n\r\n
                return (base + index + 2, base + index + 4)
            }
            index += 1
        }
        return nil
    }

    /// Parses the request line and headers.
    static func parseHead(_ data: Data) -> HTTPRequest? {
        guard let text = String(data: Data(data), encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: { $0 == "\n" }).map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
        }
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = parts[0].uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
                .trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if headers[name] == nil { headers[name] = value }
        }

        let (path, query) = splitTarget(target)
        return HTTPRequest(method: method, path: path, query: query, headers: headers)
    }

    /// Splits `/a/b?x=1&y=2` into its decoded path and parameters.
    static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = pieces.first.map(String.init) ?? "/"
        let path = rawPath.removingPercentEncoding ?? rawPath
        guard pieces.count > 1 else { return (path.isEmpty ? "/" : path, [:]) }
        return (path.isEmpty ? "/" : path, parseFormEncoded(String(pieces[1])))
    }

    /// Decodes `application/x-www-form-urlencoded` data — used for both query
    /// strings and form posts. Repeated keys keep the first value.
    public static func parseFormEncoded(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
            let halves = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = halves.first, !rawName.isEmpty else { continue }
            let name = decodeComponent(String(rawName))
            let value = halves.count > 1 ? decodeComponent(String(halves[1])) : ""
            if result[name] == nil { result[name] = value }
        }
        return result
    }

    /// Percent-decoding plus the `+` → space convention of form encoding.
    static func decodeComponent(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}
