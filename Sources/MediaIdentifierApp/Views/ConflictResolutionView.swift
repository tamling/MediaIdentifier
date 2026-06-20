import SwiftUI
import MediaIdentifierCore

/// Interactive resolution for the "Ask" conflict policy (FR11). Shown when the
/// user starts a batch that has destination collisions; lets them choose what to
/// do per file (or all at once).
struct ConflictResolutionView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// Per-item decision. Defaults to Rename (the safest non-destructive choice).
    @State private var resolutions: [RenameItem.ID: ConflictPolicy] = [:]

    private let options: [ConflictPolicy] = [.rename, .skip, .replace]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            List {
                ForEach(state.conflictsToResolve) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.newFileName)
                            .font(.callout.bold())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(conflictDescription(item))
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Picker("Action", selection: binding(for: item.id)) {
                            ForEach(options, id: \.self) { option in
                                Text(label(for: option)).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)

            Divider()
            footer
        }
        .frame(width: 520, height: 420)
        .background(Theme.windowBg)
        .tint(Theme.accent)
        .onAppear(perform: seedDefaults)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(state.conflictsToResolve.count) conflict(s)", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Choose how to handle each existing destination.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            Text("Apply to all:")
                .foregroundStyle(.secondary)
            ForEach(options, id: \.self) { option in
                Button(label(for: option)) { applyToAll(option) }
                    .controlSize(.small)
            }
            Spacer()
            Button("Cancel") {
                state.cancelConflictResolution()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Apply & Rename") {
                state.resolveConflicts(resolutions)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func binding(for id: RenameItem.ID) -> Binding<ConflictPolicy> {
        Binding(
            get: { resolutions[id] ?? .rename },
            set: { resolutions[id] = $0 }
        )
    }

    private func seedDefaults() {
        for item in state.conflictsToResolve where resolutions[item.id] == nil {
            resolutions[item.id] = .rename
        }
    }

    private func applyToAll(_ option: ConflictPolicy) {
        for item in state.conflictsToResolve { resolutions[item.id] = option }
    }

    private func label(for policy: ConflictPolicy) -> String {
        switch policy {
        case .rename: return "Rename"
        case .skip: return "Skip"
        case .replace: return "Replace"
        case .ask: return "Ask"
        }
    }

    private func conflictDescription(_ item: RenameItem) -> String {
        switch item.conflict {
        case .existingFile: return "A file already exists at this destination."
        case .duplicateInBatch: return "Another item targets the same destination."
        case .none: return ""
        }
    }
}
