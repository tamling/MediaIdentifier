import Foundation

/// A metadata match for an identified medium (FR3, FR4, FR5).
public struct MediaMetadata: Equatable, Codable, Sendable {
    public var title: String
    public var year: Int?
    public var kind: MediaKind
    /// Provider-specific identifier (e.g. TMDb id), when available.
    public var identifier: String?

    public init(title: String, year: Int? = nil, kind: MediaKind, identifier: String? = nil) {
        self.title = title
        self.year = year
        self.kind = kind
        self.identifier = identifier
    }
}

/// Abstraction over a metadata source so providers (offline, TMDb, TVDb, …) can
/// be swapped or added as plug-ins (FR3, FR20).
public protocol MetadataProvider: Sendable {
    /// Resolves official metadata for a parsed release. Implementations should
    /// fall back gracefully and never throw for "not found".
    func identify(_ parsed: ParsedRelease) async throws -> MediaMetadata?
}

/// Default, fully local provider (FR18): it trusts the parsed title/year and
/// performs no network access. This keeps the app usable with zero configuration
/// and guarantees no data leaves the machine.
public struct OfflineMetadataProvider: MetadataProvider {
    public init() {}

    public func identify(_ parsed: ParsedRelease) async throws -> MediaMetadata? {
        guard !parsed.title.isEmpty else { return nil }
        return MediaMetadata(
            title: parsed.title,
            year: parsed.year,
            kind: parsed.kind == .unknown ? .movie : parsed.kind
        )
    }
}

/// Applies resolved metadata back onto a parsed release to firm up the official
/// title and year (FR4, FR5) before naming.
public struct MetadataEnricher {
    private let provider: MetadataProvider

    public init(provider: MetadataProvider = OfflineMetadataProvider()) {
        self.provider = provider
    }

    public func enrich(_ parsed: ParsedRelease) async -> ParsedRelease {
        guard let metadata = try? await provider.identify(parsed), let metadata else {
            return parsed
        }
        var updated = parsed
        if !metadata.title.isEmpty { updated.title = metadata.title }
        if let year = metadata.year { updated.year = year }
        if updated.kind == .unknown { updated.kind = metadata.kind }
        return updated
    }
}
