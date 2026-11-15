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
    /// 2160p and 1080p all came out at 62 %, because none of those is
    /// *less than* 1080. A user with 4K files picking 1080p was told the
    /// downscale saved nothing, when it saves three quarters; a user with
    /// 1080p files picking 4K was told the same 62 %, for a run that writes
    /// a bigger file than it reads.
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
        // Scaling changes the size by area, in both directions.
        //
        // This used to be clipped at 1.0 by a `height < assumedSourceHeight`
        // guard, which left two of the five offered resolutions saying the
        // same thing: for a 1080p source, "2160p (4K)" and "keep the source
        // resolution" came out identical, so the window collapsed them to
        // one number and told a user who had just chosen 4K that the run
        // would save 38 %. The engine scales unconditionally -- `-vf
        // scale=-2:2160` with no `min(ih, …)` -- so that run really does
        // upscale 1080p to four times the pixels and write a file BIGGER
        // than the original. Modelling the upscale is what makes the
        // window's two-number line fire for it and read above 100 %.
        var resFactor = 1.0
        if let height = options.targetHeight {
            resFactor = pow(Double(height) / Double(assumedSourceHeight), 2)
        }
        // The 1.5 ceiling is deliberate and not a mistake about upscaling:
        // an encoder given upscaled input compresses the invented detail
        // far better than native 4K, so the honest ceiling for a rough
        // estimate is "half again as big", not the 2.5× the pixel count
        // alone suggests. What matters is that it is above 100 %.
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
