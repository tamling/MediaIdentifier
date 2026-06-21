import SwiftUI
import AppKit

/// Watch-Ordner: monitor a folder and auto-import (and optionally auto-rename)
/// finished downloads (FR20).
struct WatchView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    card("Monitoring") {
                        Toggle("Monitor folder", isOn: $state.watchEnabled)
                            .disabled(state.watchFolderURL == nil)

                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .foregroundStyle(Theme.textSecondary)
                            Text(state.watchFolderPath.isEmpty ? "No folder chosen" : state.watchFolderPath)
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(state.watchFolderPath.isEmpty ? Theme.textTertiary : Theme.textRow)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            ToolbarButton(title: "Choose folder…", action: chooseFolder)
                        }

                        Toggle("Automatically rename new files", isOn: $state.watchAutoRename)
                        Text("Finished downloaded video files are detected, analyzed and - if enabled - renamed immediately following the Jellyfin scheme. Everything happens locally.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    statusCard

                    card("Activity") {
                        if state.watchActivity.isEmpty {
                            Text("No activity yet.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                        } else {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(state.watchActivity.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(Theme.textRow)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
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
                Text("Watch folder").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Automatic background processing").font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            statusPill
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .overlay(Theme.hairline.frame(height: 0.5), alignment: .bottom)
    }

    private var statusPill: some View {
        let active = state.watchEnabled && state.watchFolderURL != nil
        let color = active ? Theme.accentBright : Theme.textTertiary
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: active ? color : .clear, radius: 3)
            Text(active ? "Active" : "Inactive")
                .font(.system(size: 11.5, weight: .bold)).foregroundStyle(color)
        }
    }

    private var statusCard: some View {
        card("Mode") {
            HStack(spacing: 8) {
                Image(systemName: state.watchAutoRename ? "wand.and.stars" : "tray.and.arrow.down")
                    .foregroundStyle(Theme.accent)
                Text(state.watchAutoRename
                     ? "Auto-rename: new files are processed immediately."
                     : "Import only: new files land in the queue for review.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textRow)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Monitor"
        if panel.runModal() == .OK, let url = panel.url {
            state.setWatchFolder(url)
        }
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
