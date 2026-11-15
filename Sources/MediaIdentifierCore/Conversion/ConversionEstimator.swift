import Foundation

/// Rough, perception-oriented estimates for a conversion (FR16): how much
/// smaller the output is likely to be, and a human-readable quality label.
///
/// These are deliberately approximate — real output size depends on content —
/// so the UI must present them as estimates ("~").
public enum ConversionEstimator {
    /// Estimated output-to-input size ratio (0.05…1.5).
    ///
    /// `assumedSourceHeight` is not a detail: the resolution term is the
    /// difference between the source and the target, and without a real
    /// source height there is nothing to compute. The default of 1080 used
    /// to be the only value anybody passed, and it made the whole setting
    /// look inert — at h265 and quality 21, "keep the source resolution",
    /// 2160p and 1080p all come out at 62 %, because none of those is
    /// *less than* 1080. A user with 4K files picking 1080p was told the
    /// downscale saved nothing, when it saves three quarters.
    ///
    /// Nothing can probe the source at the moment the settings are shown —
    /// no file has been chosen yet — so the caller's job is to name the
    /// assumption rather than hide it. The settings window shows the number
    /// for a 1080p source and for a 4K one whenever the two differ.
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
        /// What the number means, in words.
        public let label: String
        /// 0 = lowest perceived quality … 4 = visually lossless.
        public let rank: Int
    }

    /// Perceived picture quality for the chosen RF and codec — about how it
    /// looks, not about the bitrate.
    ///
    /// Read by the settings window beside the quality field: "21" says
    /// nothing to somebody who has not encoded video before, and this is
    /// the sentence that makes the number mean something.
    ///
    /// The labels were German-only until they had a reader, like everything
    /// else that only the removed web front-end would have drawn.
    public static func quality(options: ConversionOptions) -> Quality {
        if options.videoCodec == .copy {
            return Quality(label: Text.s("Original, nur umgepackt",
                                         "The original, only repackaged"),
                           rank: 4)
        }
        switch options.quality {
        case ...18:
            return Quality(label: Text.s("sieht aus wie das Original",
                                         "looks like the original"), rank: 4)
        case 19...21:
            return Quality(label: Text.s("sehr gut", "very good"), rank: 3)
        case 22...24:
            return Quality(label: Text.s("gut", "good"), rank: 2)
        case 25...27:
            return Quality(label: Text.s("mittel", "middling"), rank: 1)
        default:
            return Quality(label: Text.s("sichtbar schlechter",
                                         "visibly worse"), rank: 0)
        }
    }
}
