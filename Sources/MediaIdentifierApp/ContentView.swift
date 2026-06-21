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
        // Everything on a single horizontal line: traffic lights (system, left),
        // the name, then the status lamps and the mode badge on the right.
        HStack(spacing: 10) {
            Color.clear.frame(width: 70)        // room for the traffic lights
            Text("Mediafin")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0xD7D7DA))
            activity
            Spacer()
            lamps
            badge
        }
        .padding(.trailing, 12)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
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

    // MARK: Inline activity (progress shown on the title line)

    @ViewBuilder private var activity: some View {
        if state.isProcessing {
            activityItem("Renaming", "\(Int(state.progress * 100)) %")
        } else if state.isConverting {
            activityItem("Converting", convertLabel)
        } else if state.isLookingUp {
            activityItem("Identifying", "…")
        }
    }

    private var convertLabel: String {
        let name = state.currentConvert?.lastPathComponent ?? ""
        let pct = Int(state.convertProgress * 100)
        return name.isEmpty ? "\(pct) %" : "\(name) · \(pct) %"
    }

    private func activityItem(_ title: String, _ detail: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14)
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textRow)
            Text(detail).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.accentBright)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.leading, 6)
        .layoutPriority(1)
    }

    // MARK: Status lamps (red/yellow/green at-a-glance, on the same line)

    /// A compact traffic-light style overview of the optional subsystems.
    private var lamps: some View {
        HStack(spacing: 7) {
            lamp(state.ffmpegAvailable ? .ok : .bad,
                 symbol: "film",
                 help: state.ffmpegAvailable ? "FFmpeg: ready" : "FFmpeg: not found (Convert → Set up)",
                 action: { state.section = .convert })
            lamp(state.jellyfinConfigured ? .ok : .off,
                 symbol: "play.rectangle.on.rectangle",
                 help: state.jellyfinConfigured ? "Jellyfin: connected" : "Jellyfin: not configured",
                 action: { state.openSettings(.server) })
            lamp(state.watchActive ? .ok : .off,
                 symbol: "eye",
                 help: state.watchActive ? "Watch folder: active" : "Watch folder: off",
                 action: { state.section = .watch })
            lamp(state.webEnabled ? .ok : .off,
                 symbol: "globe.badge.chevron.backward",
                 help: state.webEnabled ? "Status web page: on" : "Status web page: off",
                 action: { state.openSettings(.server) })
        }
    }

    private enum LampState { case ok, warn, bad, off
        var color: Color {
            switch self {
            case .ok: return Theme.accentBright
            case .warn: return Theme.warn
            case .bad: return Color(hex: 0xE05A4F)
            case .off: return Theme.textTertiary
            }
        }
    }

    private func lamp(_ s: LampState, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(s.color)
                .frame(width: 18, height: 18)
                .background(s.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(s.color.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

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

/// Switches the main pane based on the selected sidebar section.
private struct MainArea: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        switch state.section {
        case .overview:
            OverviewView()
        case .queue:
            QueueView(section: .queue, title: "Rename")
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
