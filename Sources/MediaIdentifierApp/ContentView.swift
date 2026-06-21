import SwiftUI
import UniformTypeIdentifiers
import AppKit
import MediaIdentifierCore

/// Root layout: custom title bar + sidebar + main content (matches the design).
struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            ActivityBar()
            HStack(spacing: 0) {
                SidebarView()
                Divider().overlay(Theme.hairline)
                MainArea()
            }
        }
        .background(Theme.windowBg)
        .sheet(isPresented: conflictSheetBinding) {
            ConflictResolutionView()
        }
        .sheet(isPresented: $state.showingSettings) {
            MetadataSettingsView()
        }
    }

    private var conflictSheetBinding: Binding<Bool> {
        Binding(
            get: { !state.conflictsToResolve.isEmpty },
            set: { presenting in if !presenting { state.conflictsToResolve = [] } }
        )
    }
}

/// The window chrome's title strip with a live processing-mode badge.
private struct TitleBar: View {
    @EnvironmentObject private var state: AppState

    /// Online lookup on → data leaves the machine (only title/year); otherwise
    /// everything is processed locally (FR18).
    private var isOnline: Bool { state.onlineLookupEnabled && !state.tmdbAPIKey.isEmpty }

    var body: some View {
        ZStack {
            Text("Jellyfin Renamer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0xD7D7DA))
            HStack {
                Spacer()
                badge
            }
            .padding(.trailing, 12)
        }
        .frame(height: 28)          // match the standard title-bar height so the
        .frame(maxWidth: .infinity) // title sits on one line with the traffic lights
        .background(
            LinearGradient(colors: [Theme.titleBarTop, Theme.titleBarBot], startPoint: .top, endPoint: .bottom)
        )
        .overlay(Theme.hairline.frame(height: 0.5), alignment: .bottom)
        .contentShape(Rectangle())
        // Double-click the title bar to zoom/maximize, like a standard window.
        .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
    }

    private var usingLocalAI: Bool { state.useAppleIntelligence && state.appleIntelligenceSupported }
    private var usingLocalDB: Bool { state.useLocalDatabase && state.localDatabaseCount > 0 }

    private var badge: some View {
        let color = isOnline ? Theme.movie : Theme.accentGlow
        let localSuffix = usingLocalAI ? " · AI" : (usingLocalDB ? " · DB" : "")
        // Spell out what the indicator means so the colour isn't ambiguous.
        let label = isOnline ? "Online · TMDb" : "Local only\(localSuffix)"
        let help = isOnline
            ? "Online mode: identifying titles via TMDb. Only the title and year are sent — never media files. Turn this off in Settings → Identification to stay fully local."
            : "Local mode (green): everything is processed on this Mac, no uploads. The alternative is online lookup via TMDb (Settings → Identification)."
        return HStack(spacing: 6) {
            Image(systemName: isOnline ? "globe" : "lock.fill")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.3), lineWidth: 0.5))
        .help(help)
    }
}

/// Slim, always-visible strip showing what is currently running across the app
/// (renaming, converting, identifying) plus a steady watch-folder indicator.
private struct ActivityBar: View {
    @EnvironmentObject private var state: AppState

    private var active: Bool { state.isProcessing || state.isConverting || state.isLookingUp }

    var body: some View {
        if active {
            HStack(spacing: 16) {
                if state.isProcessing {
                    item("Rename", "\(Int(state.progress * 100)) %")
                }
                if state.isConverting {
                    item("Convert", convertLabel)
                }
                if state.isLookingUp {
                    item("Identification", "running …")
                }
                Spacer()
                if state.watchActive {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.accentBright).frame(width: 6, height: 6)
                        Text("Watch active").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 26)
            .background(Theme.titleBarBot)
            .overlay(Theme.hairline.frame(height: 0.5), alignment: .bottom)
        }
    }

    private var convertLabel: String {
        let name = state.currentConvert?.lastPathComponent ?? ""
        return "\(name) · \(Int(state.convertProgress * 100)) %"
    }

    private func item(_ title: String, _ detail: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textRow)
            Text(detail).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.accentBright)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// Switches the main pane based on the selected sidebar section.
private struct MainArea: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        switch state.section {
        case .overview:
            OverviewView()
        case .queue:
            QueueView(section: .queue, title: "Queue")
        case .movies:
            QueueView(section: .movies, title: "Movies")
        case .series:
            QueueView(section: .series, title: "Series")
        case .convert:
            ConvertView()
        case .watch:
            WatchView()
        case .log:
            LogView()
        }
    }
}
