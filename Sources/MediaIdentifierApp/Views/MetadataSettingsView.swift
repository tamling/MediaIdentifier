import SwiftUI
import AppKit
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

            // On-device Apple Intelligence (FR3, local)
            group("Erkennung – Apple Intelligence (lokal)") {
                Toggle("Titel mit Apple Intelligence erkennen (on-device)",
                       isOn: $state.useAppleIntelligence)
                    .disabled(!state.appleIntelligenceSupported)
                Text(state.appleIntelligenceSupported
                     ? "Nutzt das geräteinterne Sprachmodell. Läuft komplett lokal — es werden keine Daten gesendet. Hat Vorrang vor TMDb."
                     : "Nicht verfügbar: benötigt macOS 26+, Apple Silicon und aktiviertes Apple Intelligence.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Embedded container tags (FR3, local)
            group("Eingebettete Metadaten (lokal)") {
                Toggle("Titel/Jahr aus der Datei (MKV/MP4) lesen",
                       isOn: $state.useEmbeddedMetadata)
                Text("Liest im Container gespeicherte Tags via AVFoundation. Greift nur, wenn die Datei solche Tags enthält.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Local offline title database (FR3)
            group("Lokale Titel-Datenbank (lokal)") {
                Toggle("Offline-Datenbank verwenden", isOn: $state.useLocalDatabase)
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive").foregroundStyle(Theme.textSecondary)
                    Text(databaseStatus)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(state.databaseError == nil ? Theme.textRow : Theme.warn)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if state.isLoadingDatabase {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Datei wählen…", action: chooseDatabase)
                    }
                }
                Text("Einmalig den TMDb-Export von files.tmdb.org/p/exports laden (movie_ids / tv_series_ids, .json/.jsonl, auch .gz). Danach erfolgt der Abgleich offline.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    Button("Verbindung testen") { state.testTMDb() }
                        .disabled(state.tmdbAPIKey.isEmpty)
                    Spacer()
                }
                if let result = state.tmdbTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("✓") ? Theme.accentBright : Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
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

    private var databaseStatus: String {
        if let error = state.databaseError { return error }
        if state.isLoadingDatabase { return "Wird geladen …" }
        if state.localDatabaseCount > 0 { return "\(state.localDatabaseCount) Titel geladen" }
        return state.localDatabasePath.isEmpty ? "Keine Datei gewählt" : "Nicht geladen"
    }

    private func chooseDatabase() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Laden"
        if panel.runModal() == .OK, let url = panel.url {
            state.setLocalDatabaseFile(url)
        }
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
