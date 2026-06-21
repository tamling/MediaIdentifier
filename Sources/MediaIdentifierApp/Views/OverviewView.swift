import SwiftUI
import MediaIdentifierCore

/// Start dashboard: a traffic-light overview of dependencies and capabilities,
/// so the user sees at a glance what is ready and what needs attention.
struct OverviewView: View {
    @EnvironmentObject private var state: AppState

    enum Level {
        case ok, warn, missing, neutral
        var color: Color {
            switch self {
            case .ok: return Theme.accentBright
            case .warn: return Theme.warn
            case .missing: return Color(hex: 0xE05A4F)
            case .neutral: return Theme.textTertiary
            }
        }
        var label: String {
            switch self {
            case .ok: return "OK"
            case .warn: return "Optional"
            case .missing: return "Fehlt"
            case .neutral: return "Aus"
            }
        }
    }

    struct Check: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
        let level: Level
        var actionLabel: String? = nil
        var action: (() -> Void)? = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    VStack(spacing: 0) {
                        ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                            if index > 0 { Divider().overlay(Theme.hairline) }
                            HealthRow(check: check)
                        }
                    }
                    .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 0.5))
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBg)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Übersicht").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Status der Voraussetzungen").font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .overlay(Theme.hairline.frame(height: 0.5), alignment: .bottom)
    }

    private var summary: some View {
        let missing = checks.filter { $0.level == .missing }.count
        let warn = checks.filter { $0.level == .warn }.count
        let allGood = missing == 0 && warn == 0
        let color: Level = missing > 0 ? .missing : (warn > 0 ? .warn : .ok)
        let text = allGood
            ? "Alles bereit – die Kernfunktionen sind einsatzfähig."
            : "\(missing) fehlend · \(warn) optional nicht konfiguriert."
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.color.opacity(0.16)).frame(width: 40, height: 40)
                Image(systemName: allGood ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 20)).foregroundStyle(color.color)
            }
            Text(text).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.textRow)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 12))
    }

    private var checks: [Check] {
        var list: [Check] = []

        // System
        #if arch(arm64)
        let arch = "Apple Silicon"
        #else
        let arch = "Intel"
        #endif
        list.append(Check(
            icon: "desktopcomputer", title: "System",
            detail: "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion) · \(arch)",
            level: .ok))

        // Apple Intelligence
        list.append(Check(
            icon: "sparkles", title: "Apple Intelligence (on-device)",
            detail: state.appleIntelligenceSupported
                ? (state.useAppleIntelligence ? "Verfügbar und aktiviert." : "Verfügbar – in den Einstellungen aktivierbar.")
                : "Nicht verfügbar (benötigt macOS 26+, Apple Silicon, Apple Intelligence).",
            level: state.appleIntelligenceSupported ? .ok : .warn,
            actionLabel: state.appleIntelligenceSupported && !state.useAppleIntelligence ? "Einstellungen" : nil,
            action: { state.showingSettings = true }))

        // FFmpeg
        list.append(Check(
            icon: "film", title: "FFmpeg (Konvertierung)",
            detail: state.ffmpegAvailable ? "Gefunden – Transkodierung verfügbar."
                                          : "Nicht gefunden. Installieren mit:  brew install ffmpeg",
            level: state.ffmpegAvailable ? .ok : .missing))

        // TMDb
        list.append(Check(
            icon: "globe", title: "TMDb Online-Suche",
            detail: state.tmdbConfigured ? "Konfiguriert und aktiv." : "Optional – kein API-Schlüssel hinterlegt.",
            level: state.tmdbConfigured ? .ok : .warn,
            actionLabel: state.tmdbConfigured ? nil : "Einrichten",
            action: { state.showingSettings = true }))

        // Local title database
        list.append(Check(
            icon: "externaldrive", title: "Lokale Titel-Datenbank",
            detail: state.localDatabaseLoaded ? "\(state.localDatabaseCount) Titel geladen."
                                              : "Optional – keine Offline-Datenbank geladen.",
            level: state.localDatabaseLoaded ? .ok : .warn,
            actionLabel: state.localDatabaseLoaded ? nil : "Laden",
            action: { state.showingSettings = true }))

        // Watch folder
        list.append(Check(
            icon: "eye", title: "Watch-Ordner",
            detail: state.watchActive ? "Aktiv." : "Aus – kann unter Watch-Ordner aktiviert werden.",
            level: state.watchActive ? .ok : .neutral,
            actionLabel: state.watchActive ? nil : "Öffnen",
            action: { state.section = .watch }))

        // Jellyfin connector
        list.append(Check(
            icon: "play.rectangle.on.rectangle", title: "Jellyfin-Server",
            detail: state.jellyfinConfigured ? "Verbunden – Bibliothek wird nach dem Umbenennen aktualisiert."
                                             : "Optional – nicht konfiguriert.",
            level: state.jellyfinConfigured ? .ok : .neutral,
            actionLabel: state.jellyfinConfigured ? nil : "Einrichten",
            action: { state.showingSettings = true }))

        // Status web page
        list.append(Check(
            icon: "globe.badge.chevron.backward", title: "Status-Webseite",
            detail: state.webEnabled ? "Aktiv – \(state.webURL)"
                                     : "Optional – für Uptime Kuma o. Ä. aktivierbar.",
            level: state.webEnabled ? .ok : .neutral,
            actionLabel: state.webEnabled ? nil : "Einrichten",
            action: { state.showingSettings = true }))

        return list
    }
}

private struct HealthRow: View {
    let check: OverviewView.Check

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(check.level.color.opacity(0.16)).frame(width: 30, height: 30)
                Image(systemName: check.icon).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(check.level.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(check.detail).font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let label = check.actionLabel, let action = check.action {
                Button(label, action: action).controlSize(.small)
            }
            statusPill
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle().fill(check.level.color).frame(width: 7, height: 7)
                .shadow(color: check.level.color, radius: 2)
            Text(check.level.label).font(.system(size: 11, weight: .bold))
                .foregroundStyle(check.level.color)
        }
        .frame(width: 78, alignment: .trailing)
    }
}
