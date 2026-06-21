#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Structured result the on-device model fills in (guided generation).
@available(macOS 26.0, *)
@Generable
private struct ReleaseGuess {
    @Guide(description: "Official, human-readable title with normal capitalization and spaces. No dots, underscores, resolution, codec, language or release-group tokens.")
    var title: String

    @Guide(description: "Four-digit release year for a movie. Use 0 if unknown or if this is a TV series.")
    var year: Int

    @Guide(description: "True if this is an episode of a TV series, false if it is a movie.")
    var isSeries: Bool
}

/// Identifies media titles using Apple Intelligence's on-device language model
/// (FR3) — fully local, so it honours FR18 (no data leaves the machine).
///
/// Availability is gated: the caller must check `isSupported` (requires
/// macOS 26+, Apple Silicon and Apple Intelligence enabled). When unavailable,
/// `identify` returns nil and the heuristic parser result is used instead.
@available(macOS 26.0, *)
public struct AppleIntelligenceProvider: MetadataProvider {
    public init() {}

    /// Whether the on-device model is ready to use right now.
    public static var isSupported: Bool {
        switch SystemLanguageModel.default.availability {
        case .available: return true
        default: return false
        }
    }

    public func identify(_ parsed: ParsedRelease, at url: URL?) async throws -> MediaMetadata? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }

        let session = LanguageModelSession(
            instructions: """
            You clean up messy media download filenames into structured metadata.
            Only use information present in the filename. Do not invent titles.
            """
        )
        let response = try await session.respond(
            to: "Filename: \(parsed.originalFileName)",
            generating: ReleaseGuess.self
        )
        let guess = response.content

        let title = guess.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        return MediaMetadata(
            title: title,
            year: guess.year > 1800 ? guess.year : nil,
            kind: guess.isSeries ? .episode : .movie,
            source: "Apple Intelligence"
        )
    }
}
#endif
