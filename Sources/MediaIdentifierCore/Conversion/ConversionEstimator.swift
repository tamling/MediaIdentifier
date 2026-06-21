import Foundation

/// Rough, perception-oriented estimates for a conversion (FR16): how much
/// smaller the output is likely to be, and a human-readable quality label.
///
/// These are deliberately approximate — real output size depends on content —
/// so the UI must present them as estimates ("~").
public enum ConversionEstimator {
    /// Estimated output-to-input size ratio (0.05…1.5).
    public static func sizeFraction(options: ConversionOptions, assumedSourceHeight: Int = 1080) -> Double {
        guard options.videoCodec != .copy else { return 1.0 }

        // Codec efficiency relative to a typical H.264 source.
        let codecFactor: Double
        switch options.videoCodec {
        case .av1:  codecFactor = 0.45
        case .h265: codecFactor = 0.55
        case .h264: codecFactor = 0.85
        case .copy: codecFactor = 1.0
        }
        // Each ~6 RF roughly halves/doubles the bitrate; RF 22 is the baseline.
        let rfFactor = pow(2.0, (22.0 - Double(options.quality)) / 6.0)
        // Downscaling reduces by area.
        var resFactor = 1.0
        if let height = options.targetHeight, height < assumedSourceHeight {
            resFactor = pow(Double(height) / Double(assumedSourceHeight), 2)
        }
        return min(1.5, max(0.05, codecFactor * rfFactor * resFactor))
    }

    public struct Quality: Equatable, Sendable {
        public let label: String
        /// 0 = lowest perceived quality … 4 = visually lossless.
        public let rank: Int
    }

    /// Perceived picture quality for the chosen RF / codec — about how it looks,
    /// not the bitrate.
    public static func quality(options: ConversionOptions) -> Quality {
        if options.videoCodec == .copy { return Quality(label: "Original (Kopie)", rank: 4) }
        switch options.quality {
        case ...18:    return Quality(label: "Visuell verlustfrei", rank: 4)
        case 19...21:  return Quality(label: "Sehr gut", rank: 3)
        case 22...24:  return Quality(label: "Gut – empfohlen", rank: 2)
        case 25...27:  return Quality(label: "Mittel", rank: 1)
        default:       return Quality(label: "Sichtbar reduziert", rank: 0)
        }
    }
}
