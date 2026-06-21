import Foundation

/// A metadata match for an identified medium (FR3, FR4, FR5).
public struct MediaMetadata: Equatable, Codable, Sendable {
    public var title: String
    public var year: Int?
    public var kind: MediaKind
    /// Provider-specific identifier (e.g. TMDb id), when available.
    public var identifier: String?
    /// Human-readable name of the source that produced this match (e.g. "TMDb",
    /// "Lokale DB"), used to show provenance in the UI (FR4).
    public var source: String?

    public init(title: String, year: Int? = nil, kind: MediaKind, identifier: String? = nil, source: String? = nil) {
        self.title = title
        self.year = year
        self.kind = kind
        self.identifier = identifier
        self.source = source
    }
}

/// Abstraction over a metadata source so providers (offline, embedded tags,
/// local database, Apple Intelligence, TMDb, …) can be swapped or chained
/// (FR3, FR20).
public protocol MetadataProvider: Sendable {
    /// Resolves official metadata for a parsed release. `url` is the media file
    /// on disk (when known) so providers that read the file itself — e.g.
    /// embedded container tags — can access it. Implementations should return
    /// nil rather than throw for "not found".
    func identify(_ parsed: ParsedRelease, at url: URL?) async throws -> MediaMetadata?
}

/// Default, fully local provider (FR18): it trusts the parsed title/year and
/// performs no network access.
public struct OfflineMetadataProvider: MetadataProvider {
    public init() {}

    public func identify(_ parsed: ParsedRelease, at url: URL?) async throws -> MediaMetadata? {
        guard !parsed.title.isEmpty else { return nil }
        return MediaMetadata(
            title: parsed.title,
            year: parsed.year,
            kind: parsed.kind == .unknown ? .movie : parsed.kind
        )
    }
}

/// Tries an ordered list of providers and returns the first confident match.
/// Used to chain local sources (embedded tags → local DB → Apple Intelligence)
/// before falling back to an online lookup (FR3, FR20).
public struct CompositeMetadataProvider: MetadataProvider {
    public let providers: [MetadataProvider]

    public init(_ providers: [MetadataProvider]) {
        self.providers = providers
    }

    public func identify(_ parsed: ParsedRelease, at url: URL?) async throws -> MediaMetadata? {
        for provider in providers {
            if let match = try? await provider.identify(parsed, at: url) {
                return match
            }
        }
        return nil
    }
}

/// Applies resolved metadata back onto a parsed release to firm up the official
/// title and year (FR4, FR5) before naming.
public struct MetadataEnricher {
    private let provider: MetadataProvider

    public init(provider: MetadataProvider = OfflineMetadataProvider()) {
        self.provider = provider
    }

    public func enrich(_ parsed: ParsedRelease, at url: URL? = nil) async -> ParsedRelease {
        guard let metadata = try? await provider.identify(parsed, at: url) else {
            return parsed
        }
        var updated = parsed
        if !metadata.title.isEmpty { updated.title = metadata.title }
        if let year = metadata.year { updated.year = year }
        if updated.kind == .unknown { updated.kind = metadata.kind }
        if let source = metadata.source { updated.matchSource = source }
        return updated
    }
}
