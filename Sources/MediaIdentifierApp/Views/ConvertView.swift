import SwiftUI
import UniformTypeIdentifiers
import AppKit
import MediaIdentifierCore

/// Konvertieren: drop files, configure Constant-Quality options (FR16/FR17,
/// FR-1) and run FFmpeg with a live command preview, progress and log.
struct ConvertView: View {
    @EnvironmentObject private var state: AppState
    @State private var dropTargeted = false

    private var o: ConversionOptions { state.conversionOptions }

    private var previewArgs: String {
        let input = URL(fileURLWithPath: "/Filme/Interstellar (2014).mkv")
        let output = AppState.conversionOutputURL(for: input, options: o)
        return "ffmpeg " + FFmpegArgumentBuilder.arguments(input: input, output: output, options: o)
            .joined(separator: " ")
    }
    private var isSoftware: Bool { !o.useHardwareAcceleration && o.videoCodec != .copy }

    var body: some View {
        VStack(spacing: 0) {
            header
            if state.isConverting {
                ProgressView(value: state.convertProgress)
                    .progressViewStyle(.linear).tint(Theme.accent)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    filesCard
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
                    if !state.convertLog.isEmpty { logCard }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBg)
        .tint(Theme.accent)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Konvertieren").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(state.convertStatus ?? "Constant Quality (RF) · FFmpeg · VideoToolbox")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !state.ffmpegAvailable {
                Chip(text: "FFmpeg fehlt", fg: Theme.warn, bg: Theme.warn.opacity(0.14))
            }
            if !state.convertFiles.isEmpty && !state.isConverting {
                Button(action: state.startConversion) {
                    HStack(spacing: 7) {
                        Image(systemName: "bolt.fill").font(.system(size: 12, weight: .bold))
                        Text("\(state.convertFiles.count) konvertieren").font(.system(size: 12.5, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15).padding(.vertical, 7)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!state.ffmpegAvailable)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .overlay(Theme.hairline.frame(height: 0.5), alignment: .bottom)
    }

    // MARK: Files

    private var filesCard: some View {
        card("Dateien") {
            if state.convertFiles.isEmpty {
                dropZone
            } else {
                VStack(spacing: 6) {
                    ForEach(state.convertFiles, id: \.self) { url in
                        HStack(spacing: 8) {
                            Image(systemName: "film").foregroundStyle(Theme.movie)
                            Text(url.lastPathComponent)
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(Theme.textRow)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(role: .destructive) { state.removeConvertFile(url) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Button("Dateien hinzufügen…", action: chooseFiles).controlSize(.small)
                        Button("Leeren", action: state.clearConvertFiles).controlSize(.small)
                        Spacer()
                        Text("\(state.convertFiles.count) Datei(en)")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(dropTargeted ? Theme.accentBright : Theme.textSecondary)
            Text("Videodateien zum Konvertieren hierher ziehen")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            Button("Dateien wählen…", action: chooseFiles).controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
                .foregroundStyle(dropTargeted ? Theme.accentBright : Color.white.opacity(0.14))
        )
    }

    private var logCard: some View {
        card("Verlauf") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(state.convertLog.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textRow)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    // MARK: Option cards

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

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Constant Quality (RF)").font(.system(size: 12.5))
                    Spacer()
                    Text("\(o.quality)").font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.accentBright)
                }
                Slider(value: qualityBinding, in: 14...30, step: 1)
                HStack {
                    Text("beste Qualität / größer").font(.caption2).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Text("kleiner").font(.caption2).foregroundStyle(Theme.textTertiary)
                }
            }
            note("1080p: 20–22, 4K: 22–26.")

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

    private var qualityBinding: Binding<Double> {
        Binding(
            get: { Double(o.quality) },
            set: { state.conversionOptions.quality = Int($0.rounded()) }
        )
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

    // MARK: Input

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK { state.addConvertFiles(panel.urls) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            state.addConvertFiles(urls)
        }
        return true
    }
}
