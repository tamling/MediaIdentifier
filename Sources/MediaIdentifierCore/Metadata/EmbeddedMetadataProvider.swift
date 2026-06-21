#if canImport(AVFoundation)
import Foundation
import AVFoundation

/// Reads title / year tags embedded in the media container itself using
/// AVFoundation — fully local (FR3, FR18).
///
/// Covers AVFoundation-readable containers (MP4 / MOV / M4V). Matroska (MKV) is
/// not parsed by AVFoundation, so for MKV this returns nil and the chain falls
/// through to `FFprobeMetadataProvider`, which understands MKV. Many scene
/// releases carry no embedded tags either, in which case it also returns nil.
/// When a title *is* present it is authoritative, so this provider runs first in
/// the local chain.
public struct EmbeddedMetadataProvider: MetadataProvider {
    public init() {}

    public func identify(_ parsed: ParsedRelease, at url: URL?) async throws -> MediaMetadata? {
        guard let url else { return nil }
        let asset = AVURLAsset(url: url)

        let common = (try? await asset.load(.commonMetadata)) ?? []
        guard !common.isEmpty else { return nil }

        let title = try await string(from: common, identifier: .commonIdentifierTitle)
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedTitle, !trimmedTitle.isEmpty else { return nil }

        let year = try await year(from: common)
        // Keep the parser's season/episode; embedded tags rarely carry them.
        return MediaMetadata(
            title: trimmedTitle,
            year: year ?? parsed.year,
            kind: parsed.kind == .unknown ? .movie : parsed.kind,
            source: "Datei-Tags"
        )
    }

    private func string(from items: [AVMetadataItem], identifier: AVMetadataIdentifier) async throws -> String? {
        let filtered = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
        guard let first = filtered.first else { return nil }
        return try await first.load(.stringValue)
    }

    private func year(from items: [AVMetadataItem]) async throws -> Int? {
        // Try an explicit creation date, then any year-like number in its string.
        if let dateString = try await string(from: items, identifier: .commonIdentifierCreationDate),
           let parsed = YearParser.firstYear(in: dateString) {
            return parsed
        }
        return nil
    }
}
#endif
