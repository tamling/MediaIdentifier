import SwiftUI
import MediaIdentifierCore

/// Einstellungen: naming, conflict handling, output and TMDb online lookup (FR3,
/// FR7, FR11, FR18).
struct MetadataSettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Einstellungen")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            // Naming (FR7)
            group("Benennung") {
                Toggle("Filme in eigenen Ordner legen", isOn: Binding(
                    get: { state.namingOptions.useMovieFolders },
                    set: { state.namingOptions.useMovieFolders = $0 }
                ))
                Toggle("Jahr im Serienordner anzeigen", isOn: Binding(
                    get: { state.namingOptions.includeSeriesYear },
                    set: { state.namingOptions.includeSeriesYear = $0 }
                ))
            }

            // Conflicts (FR11)
            group("Bei Konflikt") {
                Picker("", selection: $state.conflictPolicy) {
                    Text("Fragen").tag(ConflictPolicy.ask)
                    Text("Überspringen").tag(ConflictPolicy.skip)
                    Text("Umbenennen").tag(ConflictPolicy.rename)
                    Text("Ersetzen").tag(ConflictPolicy.replace)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Online metadata (FR3)
            group("Online-Metadaten (TMDb)") {
                Toggle("Offizielle Titel online nachschlagen", isOn: $state.onlineLookupEnabled)
                SecureField("TMDb API-Schlüssel", text: $state.tmdbAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!state.onlineLookupEnabled)
                Text("Kostenlosen Schlüssel auf themoviedb.org → Einstellungen → API holen. Es werden nur Titel und Jahr gesendet — niemals eine Mediendatei.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        state.lookUpOnline()
                    } label: {
                        if state.isLookingUp {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Jetzt nachschlagen")
                        }
                    }
                    .disabled(!state.canLookUpOnline || state.isLookingUp)
                    Spacer()
                }
            }

            HStack {
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.windowBg)
        .tint(Theme.accent)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold)).tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            content()
        }
        .foregroundStyle(Theme.textRow)
    }
}
