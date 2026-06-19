import SwiftUI
import MediaIdentifierCore

/// Scrollable log of performed operations (FR12, FR19).
struct LogPane: View {
    @EnvironmentObject private var state: AppState

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Log", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.bold())
                Spacer()
                Text("\(state.logEntries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear Log") { state.clearLog() }
                    .controlSize(.small)
                    .disabled(state.logEntries.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            Divider()

            if state.logEntries.isEmpty {
                Spacer()
                Text("No operations yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(state.logEntries) { entry in
                                LogRow(entry: entry, formatter: Self.dateFormatter)
                                    .id(entry.id)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: state.logEntries.count) { _ in
                        if let last = state.logEntries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

private struct LogRow: View {
    let entry: RenameLogEntry
    let formatter: DateFormatter

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text(formatter.string(from: entry.date))
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text("\(entry.oldName)  →  \(entry.newName)")
                .lineLimit(1)
                .truncationMode(.middle)
            if let error = entry.errorDescription {
                Text(error).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var statusIcon: String {
        switch entry.status {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        case .skipped: return "minus.circle.fill"
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .success: return .green
        case .failure: return .red
        case .skipped: return .secondary
        }
    }
}

/// Bottom status bar with progress (FR19).
struct StatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Text(state.statusMessage)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if state.isProcessing {
                ProgressView(value: state.progress)
                    .frame(width: 180)
                Text("\(Int(state.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}
