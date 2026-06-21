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
            case .missing: return "Missing"
            case .neutral: return "Off"
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
                Text("Overview").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Requirements status").font(.system(size: 11.5))
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
            ? "All set – the core features are ready to use."
            : "\(missing) missing · \(warn) optional not configured."
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
                ? (state.useAppleIntelligence ? "Available and enabled." : "Available – can be enabled in Settings.")
                : "Not available (requires macOS 26+, Apple Silicon, Apple Intelligence).",
            level: state.appleIntelligenceSupported ? .ok : .warn,
            actionLabel: state.appleIntelligenceSupported && !state.useAppleIntelligence ? "Settings" : nil,
            action: { state.showingSettings = true }))

        // FFmpeg
        list.append(Check(
            icon: "film", title: "FFmpeg (Conversion)",
            detail: state.ffmpegAvailable ? "Found – transcoding available."
                                          : "Not found. Install (brew install ffmpeg) or choose a file.",
            level: state.ffmpegAvailable ? .ok : .missing,
            actionLabel: state.ffmpegAvailable ? nil : "Set up",
            action: { state.section = .convert }))

        // TMDb
        list.append(Check(
            icon: "globe", title: "TMDb online search",
            detail: state.tmdbConfigured ? "Configured and active." : "Optional – no API key stored.",
            level: state.tmdbConfigured ? .ok : .warn,
            actionLabel: state.tmdbConfigured ? nil : "Set up",
            action: { state.showingSettings = true }))

        // Local title database
        list.append(Check(
            icon: "externaldrive", title: "Local title database",
            detail: state.localDatabaseLoaded ? "\(state.localDatabaseCount) titles loaded."
                                              : "Optional – no offline database loaded.",
            level: state.localDatabaseLoaded ? .ok : .warn,
            actionLabel: state.localDatabaseLoaded ? nil : "Load",
            action: { state.showingSettings = true }))

        // Watch folder
        list.append(Check(
            icon: "eye", title: "Watch folder",
            detail: state.watchActive ? "Active." : "Off – can be enabled under Watch folder.",
            level: state.watchActive ? .ok : .neutral,
            actionLabel: state.watchActive ? nil : "Open",
            action: { state.section = .watch }))

        // Jellyfin connector
        list.append(Check(
            icon: "play.rectangle.on.rectangle", title: "Jellyfin server",
            detail: state.jellyfinConfigured ? "Connected – library is refreshed after renaming."
                                             : "Optional – not configured.",
            level: state.jellyfinConfigured ? .ok : .neutral,
            actionLabel: state.jellyfinConfigured ? nil : "Set up",
            action: { state.showingSettings = true }))

        // Status web page
        list.append(Check(
            icon: "globe.badge.chevron.backward", title: "Status web page",
            detail: state.webEnabled ? "Active – \(state.webURL)"
                                     : "Optional – can be enabled for Uptime Kuma and similar.",
            level: state.webEnabled ? .ok : .neutral,
            actionLabel: state.webEnabled ? nil : "Set up",
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
