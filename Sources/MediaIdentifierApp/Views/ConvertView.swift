import SwiftUI
import MediaIdentifierCore

/// Konvertieren: FFmpeg conversion options (FR16) with VideoToolbox hardware
/// acceleration (FR17). The pipeline is a planned feature; this pane configures
/// it and previews the resulting FFmpeg command.
struct ConvertView: View {
    @EnvironmentObject private var state: AppState

    private var previewArgs: String {
        let input = URL(fileURLWithPath: "/Filme/Interstellar (2014).mkv")
        let output = URL(fileURLWithPath: "/Filme/Interstellar (2014).h265.mkv")
        let args = FFmpegArgumentBuilder.arguments(input: input, output: output, options: state.conversionOptions)
        return "ffmpeg " + args.joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Konvertieren").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("FFmpeg · Apple Silicon VideoToolbox").font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Chip(text: "GEPLANT", fg: Theme.warn, bg: Theme.warn.opacity(0.14))
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            .overlay(Theme.hairline.frame(height: 0.5), alignment: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    card("Video") {
                        Picker("Codec", selection: $state.conversionOptions.videoCodec) {
                            Text("H.265 / HEVC").tag(ConversionOptions.VideoCodec.h265)
                            Text("H.264").tag(ConversionOptions.VideoCodec.h264)
                            Text("Kopieren").tag(ConversionOptions.VideoCodec.copy)
                        }
                        .pickerStyle(.segmented)

                        Toggle("Hardwarebeschleunigung (VideoToolbox)",
                               isOn: $state.conversionOptions.useHardwareAcceleration)

                        Stepper(value: $state.conversionOptions.quality, in: 1...51) {
                            Text("Qualität (CRF/Q): \(state.conversionOptions.quality)")
                        }

                        Picker("Auflösung", selection: heightBinding) {
                            Text("Original").tag(0)
                            Text("2160p").tag(2160)
                            Text("1080p").tag(1080)
                            Text("720p").tag(720)
                        }
                        .pickerStyle(.menu)
                    }

                    card("Audio & Spuren") {
                        Toggle("Nur erste Tonspur behalten",
                               isOn: $state.conversionOptions.keepOnlyFirstAudio)
                        Toggle("Untertitelspuren entfernen",
                               isOn: $state.conversionOptions.stripSubtitles)
                    }

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

    private var heightBinding: Binding<Int> {
        Binding(
            get: { state.conversionOptions.targetHeight ?? 0 },
            set: { state.conversionOptions.targetHeight = $0 == 0 ? nil : $0 }
        )
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
