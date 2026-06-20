import SwiftUI

/// Left navigation rail (Bibliothek / Werkzeuge / Verlauf) plus Einstellungen.
struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionLabel("Bibliothek")
            SidebarRow(
                title: "Warteschlange",
                systemImage: "tray.and.arrow.down.fill",
                section: .queue,
                badge: state.hasFiles ? "\(state.items.count)" : nil
            )
            SidebarRow(title: "Filme", systemImage: "film",
                       section: .movies, badge: state.movieCount > 0 ? "\(state.movieCount)" : nil)
            SidebarRow(title: "Serien", systemImage: "tv",
                       section: .series, badge: state.seriesCount > 0 ? "\(state.seriesCount)" : nil)

            sectionLabel("Werkzeuge").padding(.top, 14)
            SidebarRow(title: "Konvertieren", systemImage: "arrow.triangle.2.circlepath",
                       section: .convert, trailingTag: "FFmpeg")
            SidebarRow(title: "Watch-Ordner", systemImage: "eye",
                       section: .watch,
                       trailingTag: state.watchEnabled ? "AN" : nil)

            sectionLabel("Verlauf").padding(.top, 14)
            SidebarRow(title: "Protokoll", systemImage: "clock.arrow.circlepath",
                       section: .log, badge: state.logEntries.isEmpty ? nil : "\(state.logEntries.count)")

            Spacer()

            Button(action: { showingSettings = true }) {
                Label("Einstellungen", systemImage: "slider.horizontal.3")
                    .labelStyle(SidebarLabelStyle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textRow)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(width: 212)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarBg)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var state: AppState
    let title: String
    let systemImage: String
    let section: SidebarSection
    var badge: String? = nil
    var trailingTag: String? = nil

    @State private var hovering = false

    private var isSelected: Bool { state.section == section }

    var body: some View {
        Button(action: { state.section = section }) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(isSelected ? Color.white.opacity(0.22) : Theme.chipBg)
                        )
                }
                if let trailingTag {
                    Text(trailingTag)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                        )
                }
            }
            .foregroundStyle(isSelected ? .white : Theme.textRow)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Theme.accent : (hovering ? Theme.hover : .clear))
                    .shadow(color: isSelected ? .black.opacity(0.25) : .clear, radius: 1, y: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.font(.system(size: 14, weight: .medium)).frame(width: 18)
            configuration.title.font(.system(size: 13.5, weight: .medium))
            Spacer()
        }
    }
}
