import Foundation

/// A read-only snapshot of what the app is currently doing, served over a small
/// local HTTP endpoint so external monitors (e.g. Uptime Kuma) can poll it and
/// notify when a run finishes (FR20). Contains no secrets — only progress and
/// counts. Pure value type so the HTTP-formatting helpers are testable without
/// any networking.
public struct StatusSnapshot: Codable, Sendable, Equatable {
    public var updated: Date
    /// True while renaming or converting — the key field for "is a job running".
    public var busy: Bool
    public var renaming: Bool
    public var renameProgress: Double
    public var converting: Bool
    public var convertProgress: Double
    public var currentFile: String?
    public var convertStatus: String?
    public var convertDetail: String?
    public var pendingConversions: Int
    public var totalItems: Int
    public var ready: Int
    public var done: Int
    public var lastResult: String?
    public var watchActive: Bool
    public var jellyfinConfigured: Bool

    public init(
        updated: Date = Date(),
        busy: Bool = false,
        renaming: Bool = false,
        renameProgress: Double = 0,
        converting: Bool = false,
        convertProgress: Double = 0,
        currentFile: String? = nil,
        convertStatus: String? = nil,
        convertDetail: String? = nil,
        pendingConversions: Int = 0,
        totalItems: Int = 0,
        ready: Int = 0,
        done: Int = 0,
        lastResult: String? = nil,
        watchActive: Bool = false,
        jellyfinConfigured: Bool = false
    ) {
        self.updated = updated
        self.busy = busy
        self.renaming = renaming
        self.renameProgress = renameProgress
        self.converting = converting
        self.convertProgress = convertProgress
        self.currentFile = currentFile
        self.convertStatus = convertStatus
        self.convertDetail = convertDetail
        self.pendingConversions = pendingConversions
        self.totalItems = totalItems
        self.ready = ready
        self.done = done
        self.lastResult = lastResult
        self.watchActive = watchActive
        self.jellyfinConfigured = jellyfinConfigured
    }

    public static let empty = StatusSnapshot()
}

/// Pure HTTP-formatting helpers for the status server. Kept free of any
/// networking so they can be unit-tested.
public enum StatusHTTP {
    /// Extracts the request path from a raw HTTP request (first line, e.g.
    /// `GET /api/status HTTP/1.1`). Falls back to "/".
    public static func path(from request: String) -> String {
        guard let firstLine = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first
        else { return "/" }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        // Drop any query string for routing.
        return parts[1].split(separator: "?").first.map(String.init) ?? "/"
    }

    /// JSON body for `/api/status`. Optional fields are omitted when nil.
    public static func json(_ snapshot: StatusSnapshot) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(snapshot)) ?? Data("{}".utf8)
    }

    /// Builds a complete HTTP/1.1 response (headers + body).
    public static func response(status: String = "200 OK", contentType: String, body: Data) -> Data {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    /// Routes a path to a full HTTP response.
    public static func route(_ path: String, snapshot: StatusSnapshot) -> Data {
        switch path {
        case "/api/status", "/api/status/":
            return response(contentType: "application/json", body: json(snapshot))
        case "/healthz":
            return response(contentType: "text/plain; charset=utf-8", body: Data("ok".utf8))
        case "/", "/index.html":
            return response(contentType: "text/html; charset=utf-8", body: Data(html(snapshot).utf8))
        default:
            return response(status: "404 Not Found", contentType: "text/plain; charset=utf-8",
                            body: Data("not found".utf8))
        }
    }

    /// Minimal read-only dashboard with a 2s auto-refresh.
    public static func html(_ s: StatusSnapshot) -> String {
        let stateLabel = s.busy ? "Beschäftigt" : "Bereit"
        let stateColor = s.busy ? "#f0a020" : "#36c98d"
        func esc(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var rows = ""
        func row(_ label: String, _ value: String) {
            rows += "<tr><td class='k'>\(esc(label))</td><td class='v'>\(esc(value))</td></tr>"
        }
        if s.renaming {
            row("Umbenennen", "\(Int(s.renameProgress * 100)) %")
        }
        if s.converting {
            row("Konvertieren", s.convertDetail ?? "\(Int(s.convertProgress * 100)) %")
            if let file = s.currentFile { row("Aktuelle Datei", file) }
            row("Warteschlange", "\(s.pendingConversions) wartend")
        }
        if let status = s.convertStatus { row("Status", status) }
        if let last = s.lastResult { row("Letztes Ergebnis", last) }
        row("Dateien", "\(s.totalItems) gesamt · \(s.ready) bereit · \(s.done) fertig")
        row("Watch-Ordner", s.watchActive ? "aktiv" : "aus")
        row("Jellyfin", s.jellyfinConfigured ? "verbunden" : "nicht konfiguriert")
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .medium
        let updated = formatter.string(from: s.updated)

        return """
        <!DOCTYPE html>
        <html lang="de"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="refresh" content="2">
        <title>MediaIdentifier – Status</title>
        <style>
          :root { color-scheme: dark; }
          body { font-family: -apple-system, system-ui, sans-serif; background:#16161a; color:#e6e6ea;
                 margin:0; padding:32px; }
          .card { max-width:640px; margin:0 auto; background:#1e1e24; border:1px solid #2a2a32;
                  border-radius:16px; padding:24px 28px; }
          h1 { font-size:18px; margin:0 0 4px; }
          .sub { color:#8a8a92; font-size:13px; margin-bottom:20px; }
          .badge { display:inline-block; padding:6px 14px; border-radius:999px; font-weight:700;
                   background:\(stateColor)22; color:\(stateColor); border:1px solid \(stateColor)55; }
          table { width:100%; border-collapse:collapse; margin-top:18px; }
          td { padding:9px 4px; border-bottom:1px solid #26262e; font-size:14px; vertical-align:top; }
          td.k { color:#8a8a92; width:40%; }
          td.v { color:#e6e6ea; font-variant-numeric:tabular-nums; }
          .foot { color:#6a6a72; font-size:12px; margin-top:18px; }
        </style></head>
        <body><div class="card">
          <h1>MediaIdentifier</h1>
          <div class="sub">Status-Übersicht (nur Ansicht)</div>
          <span class="badge">\(stateLabel)</span>
          <table>\(rows)</table>
          <div class="foot">Aktualisiert: \(esc(updated)) · JSON: <code>/api/status</code></div>
        </div></body></html>
        """
    }
}
