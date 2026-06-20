import SwiftUI
import MediaIdentifierCore

/// Protokoll: the persisted rename log (FR12), styled to match the design.
struct LogView: View {
    @EnvironmentObject private var state: AppState

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Protokoll").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(state.logEntries.count) Einträge · alt → neu · Zeit · Status")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if !state.logEntries.isEmpty {
                    ToolbarButton(title: "Protokoll leeren", action: state.clearLog)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            .overlay(Theme.hairline.frame(height: 0.5), alignment: .bottom)

            if state.logEntries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(Theme.textTertiary)
                    Text("Noch keine Vorgänge protokolliert.")
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(state.logEntries) { entry in
                                LogRow(entry: entry, formatter: Self.formatter).id(entry.id)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                    }
                    .onChange(of: state.logEntries.count) { _ in
                        if let last = state.logEntries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBg)
    }
}

private struct LogRow: View {
    let entry: RenameLogEntry
    let formatter: DateFormatter

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(formatter.string(from: entry.date))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 160, alignment: .leading)
            Text("\(entry.oldName)  →  \(entry.newName)")
                .foregroundStyle(Theme.textRow)
                .lineLimit(1).truncationMode(.middle)
            if let error = entry.errorDescription {
                Text(error).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch entry.status {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        case .skipped: return "minus.circle.fill"
        }
    }
    private var color: Color {
        switch entry.status {
        case .success: return Theme.accentBright
        case .failure: return Color(hex: 0xE05A4F)
        case .skipped: return Theme.mono
        }
    }
}
