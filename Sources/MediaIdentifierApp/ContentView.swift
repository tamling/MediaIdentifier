import SwiftUI
import UniformTypeIdentifiers
import MediaIdentifierCore

/// Root layout: custom title bar + sidebar + main content (matches the design).
struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
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
    }

    private var usingLocalAI: Bool { state.useAppleIntelligence && state.appleIntelligenceSupported }
    private var usingLocalDB: Bool { state.useLocalDatabase && state.localDatabaseCount > 0 }

    private var badge: some View {
        let color = isOnline ? Theme.movie : Theme.accentGlow
        let localSuffix = usingLocalAI ? " · KI" : (usingLocalDB ? " · DB" : "")
        let label = isOnline ? "TMDb" : "Lokal\(localSuffix)"
        let help = isOnline
            ? "Online-Titelsuche aktiv – es werden nur Titel und Jahr an TMDb gesendet, niemals Mediendateien."
            : "Alle Dateien werden lokal verarbeitet – keine Cloud-Uploads."
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6).shadow(color: color, radius: 3)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.3), lineWidth: 0.5))
        .help(help)
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
            QueueView(section: .queue, title: "Warteschlange")
        case .movies:
            QueueView(section: .movies, title: "Filme")
        case .series:
            QueueView(section: .series, title: "Serien")
        case .convert:
            ConvertView()
        case .watch:
            WatchView()
        case .log:
            LogView()
        }
    }
}
