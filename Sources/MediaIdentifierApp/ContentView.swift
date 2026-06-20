import SwiftUI
import UniformTypeIdentifiers
import MediaIdentifierCore

/// Root layout: custom title bar + sidebar + main content (matches the design).
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            HStack(spacing: 0) {
                SidebarView(showingSettings: $showingSettings)
                Divider().overlay(Theme.hairline)
                MainArea()
            }
        }
        .background(Theme.windowBg)
        .sheet(isPresented: conflictSheetBinding) {
            ConflictResolutionView()
        }
        .sheet(isPresented: $showingSettings) {
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

/// The window chrome's title strip with the "Lokal" badge (FR18).
private struct TitleBar: View {
    var body: some View {
        ZStack {
            Text("Jellyfin Renamer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0xD7D7DA))
            HStack {
                Spacer()
                HStack(spacing: 7) {
                    Circle()
                        .fill(Theme.accentGlow)
                        .frame(width: 6, height: 6)
                        .shadow(color: Theme.accentGlow, radius: 3)
                    Text("Lokal")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x7BDCB8))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color(hex: 0x00A878).opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color(hex: 0x00A878).opacity(0.3), lineWidth: 0.5)
                )
            }
            .padding(.trailing, 16)
        }
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Theme.titleBarTop, Theme.titleBarBot], startPoint: .top, endPoint: .bottom)
        )
        .overlay(Theme.hairline.frame(height: 0.5), alignment: .bottom)
    }
}

/// Switches the main pane based on the selected sidebar section.
private struct MainArea: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        switch state.section {
        case .queue:
            QueueView(section: .queue, title: "Warteschlange")
        case .movies:
            QueueView(section: .movies, title: "Filme")
        case .series:
            QueueView(section: .series, title: "Serien")
        case .convert:
            ConvertView()
        case .log:
            LogView()
        }
    }
}
