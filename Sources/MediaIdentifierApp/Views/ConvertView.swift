import SwiftUI
import MediaIdentifierCore

/// Konvertieren: efficient transcoding options (FR16, FR17, FR-1). Constant
/// Quality (RF) with x265/10-bit by default; live FFmpeg command preview.
struct ConvertView: View {
    @EnvironmentObject private var state: AppState

    private var o: ConversionOptions { state.conversionOptions }

    private var previewArgs: String {
        let input = URL(fileURLWithPath: "/Filme/Interstellar (2014).mkv")
        let output = URL(fileURLWithPath: "/Filme/Interstellar (2014).hevc.mkv")
        return "ffmpeg " + FFmpegArgumentBuilder.arguments(input: input, output: output, options: o)
            .joined(separator: " ")
    }

    private var isSoftware: Bool { !o.useHardwareAcceleration && o.videoCodec != .copy }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    videoCard
                    audioCard
                    card("Befehlsvorschau") {
                        Text(previewArgs)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textRow)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBg)
        .tint(Theme.accent)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Konvertieren").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Constant Quality (RF) · FFmpeg · VideoToolbox").font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Chip(text: "GEPLANT", fg: Theme.warn, bg: Theme.warn.opacity(0.14))
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .overlay(Theme.hairline.frame(height: 0.5), alignment: .bottom)
    }

    private var videoCard: some View {
        card("Video") {
            Picker("Codec", selection: $state.conversionOptions.videoCodec) {
                Text("H.265 / HEVC").tag(ConversionOptions.VideoCodec.h265)
                Text("H.264").tag(ConversionOptions.VideoCodec.h264)
                Text("AV1 (SVT)").tag(ConversionOptions.VideoCodec.av1)
                Text("Kopieren").tag(ConversionOptions.VideoCodec.copy)
            }
            .pickerStyle(.segmented)

            Toggle("Hardwarebeschleunigung (VideoToolbox)",
                   isOn: $state.conversionOptions.useHardwareAcceleration)
            if o.useHardwareAcceleration {
                note("Schnell, aber kein echtes CRF und weniger effizient. Für maximale Qualität pro Byte ausschalten.")
            }

            Stepper(value: $state.conversionOptions.quality, in: 1...51) {
                Text("Constant Quality (RF): \(o.quality)")
            }
            note("Niedriger = bessere Qualität/größer. 1080p: 20–22, 4K: 22–26.")

            if isSoftware {
                Picker("Preset", selection: $state.conversionOptions.preset) {
                    ForEach(ConversionOptions.Preset.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.menu)
                note("Mindestens slow-Preset für bessere Effizienz (kostet nur Encode-Zeit).")
            }

            Toggle("10-Bit (main10) – weniger Banding", isOn: $state.conversionOptions.tenBit)

            Picker("Auflösung", selection: heightBinding) {
                Text("Original").tag(0)
                Text("2160p").tag(2160)
                Text("1080p").tag(1080)
                Text("720p").tag(720)
            }
            .pickerStyle(.menu)
        }
    }

    private var audioCard: some View {
        card("Audio & Spuren") {
            Picker("Audio", selection: $state.conversionOptions.audioMode) {
                Text("Original behalten (Passthru)").tag(ConversionOptions.AudioMode.passthrough)
                Text("Opus").tag(ConversionOptions.AudioMode.opus)
                Text("AAC").tag(ConversionOptions.AudioMode.aac)
            }
            .pickerStyle(.segmented)

            if o.audioMode != .passthrough {
                Stepper(value: $state.conversionOptions.audioBitrate, in: 64...512, step: 16) {
                    Text("Audio-Bitrate: \(o.audioBitrate) kbps")
                }
            }

            Toggle("Nur erste Tonspur behalten", isOn: $state.conversionOptions.keepOnlyFirstAudio)
            Toggle("Untertitelspuren entfernen", isOn: $state.conversionOptions.stripSubtitles)
        }
    }

    private var heightBinding: Binding<Int> {
        Binding(
            get: { o.targetHeight ?? 0 },
            set: { state.conversionOptions.targetHeight = $0 == 0 ? nil : $0 }
        )
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold)).tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .foregroundStyle(Theme.textRow)
    }
}
