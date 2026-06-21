import SwiftUI

/// Left navigation rail. Stable layout (constant row height/weight so items
/// don't shift on click) with live activity indicators. Settings now lives in
/// the menu bar (⌘,).
struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarRow(title: "Overview", systemImage: "gauge", section: .overview)

            sectionLabel("Tasks").padding(.top, 14)
            SidebarRow(title: "Rename", systemImage: "tray.and.arrow.down.fill",
                       section: .queue,
                       badge: state.hasFiles ? "\(state.items.count)" : nil,
                       active: state.isProcessing)
            SidebarRow(title: "Convert", systemImage: "arrow.triangle.2.circlepath",
                       section: .convert,
                       trailingTag: state.isConverting ? nil : "FFmpeg",
                       active: state.isConverting)

            sectionLabel("Automation").padding(.top, 14)
            SidebarRow(title: "Watch folder", systemImage: "eye",
                       section: .watch,
                       trailingTag: state.watchEnabled ? "ON" : nil,
                       active: state.watchActive)

            sectionLabel("History").padding(.top, 14)
            SidebarRow(title: "Log", systemImage: "clock.arrow.circlepath",
                       section: .log, badge: state.logEntries.isEmpty ? nil : "\(state.logEntries.count)")

            Spacer()
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
    var active: Bool = false

    @State private var hovering = false

    private var isSelected: Bool { state.section == section }

    var body: some View {
        Button(action: { state.section = section }) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))   // constant weight → no reflow
                Spacer(minLength: 4)
                if active {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                } else if let badge {
                    Text(badge)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Capsule().fill(isSelected ? Color.white.opacity(0.22) : Theme.chipBg))
                } else if let trailingTag {
                    Text(trailingTag)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                }
            }
            .foregroundStyle(isSelected ? .white : Theme.textRow)
            .padding(.horizontal, 10)
            .frame(height: 34)                       // fixed height → stable layout
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Theme.accent : (hovering ? Theme.hover : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(hovering && !isSelected ? 0.06 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
