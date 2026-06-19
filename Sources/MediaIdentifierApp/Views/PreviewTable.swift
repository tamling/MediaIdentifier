import SwiftUI
import MediaIdentifierCore

/// Scrollable preview of all pending renames (FR8) with per-row accept,
/// manual edit and remove controls (FR9).
struct PreviewTable: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(state.items) { item in
                    PreviewRow(item: item)
                        .listRowSeparator(.visible)
                }
            }
            .listStyle(.inset)
        }
    }

    private var header: some View {
        HStack {
            Text("\(state.items.count) item(s) · \(state.acceptedCount) accepted")
                .font(.subheadline)
            if state.conflictCount > 0 {
                Label("\(state.conflictCount) conflict(s)", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Accept All") { setAll(true) }
            Button("Reject All") { setAll(false) }
            Button("Clear") { state.clear() }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func setAll(_ accepted: Bool) {
        for item in state.items { state.setAccepted(accepted, for: item.id) }
    }
}

private struct PreviewRow: View {
    @EnvironmentObject private var state: AppState
    let item: RenameItem

    @State private var editedPath: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { item.isAccepted },
                set: { state.setAccepted($0, for: item.id) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                // Original name (FR8).
                Text(item.originalFileName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Detected info (FR8).
                HStack(spacing: 8) {
                    Label(item.detectedTitle.isEmpty ? "—" : item.detectedTitle, systemImage: "film")
                    Text(item.seasonEpisodeDescription)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    if let res = item.mediaFile.parsed.resolution {
                        Text(res).foregroundStyle(.secondary)
                    }
                    if item.mediaFile.companions.count > 0 {
                        Label("\(item.mediaFile.companions.count)", systemImage: "paperclip")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)

                // New name, editable (FR8 new name + FR9 manual adjust).
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                    TextField("New path", text: $editedPath, onCommit: commit)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                    if let conflict = item.conflict {
                        ConflictBadge(kind: conflict)
                    }
                }
            }

            Button(role: .destructive) {
                state.removeItem(item)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .opacity(item.isAccepted ? 1 : 0.5)
        .onAppear { editedPath = item.proposedRelativePath }
        .onChange(of: item.proposedRelativePath) { editedPath = $0 }
    }

    private func commit() {
        state.updateProposedPath(editedPath, for: item.id)
    }
}

private struct ConflictBadge: View {
    let kind: ConflictKind
    var body: some View {
        let text = kind == .existingFile ? "Exists" : "Duplicate"
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
            .help(kind == .existingFile
                  ? "A file already exists at this destination."
                  : "Another item in this batch targets the same destination.")
    }
}
