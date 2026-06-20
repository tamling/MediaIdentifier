#if canImport(AVFoundation)
import Foundation
import AVFoundation

/// Reads title / year tags embedded in the media container itself using
/// AVFoundation — fully local (FR3, FR18).
///
/// Covers AVFoundation-readable containers (MP4 / MOV / M4V). Matroska (MKV) is
/// not parsed by AVFoundation, so for MKV this returns nil and the chain falls
/// through to the next provider (ffprobe support is a planned follow-up). Many
/// scene releases carry no embedded tags either, in which case it also returns
/// nil. When a title *is* present it is authoritative, so this provider runs
/// first in the local chain.
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
            kind: parsed.kind == .unknown ? .movie : parsed.kind
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
           let parsed = Self.extractYear(dateString) {
            return parsed
        }
        return nil
    }

    static func extractYear(_ string: String) -> Int? {
        // First 19xx/20xx run in the string.
        let pattern = try? NSRegularExpression(pattern: #"(19|20)\d{2}"#)
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = pattern?.firstMatch(in: string, range: range),
              let r = Range(match.range, in: string) else { return nil }
        return Int(string[r])
    }
}
#endif
