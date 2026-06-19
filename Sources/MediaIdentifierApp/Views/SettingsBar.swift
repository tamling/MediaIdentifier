import SwiftUI
import MediaIdentifierCore

/// Toolbar of naming / output / conflict settings plus the Start and Undo
/// actions (FR7, FR11, FR13, FR19).
struct SettingsBar: View {
    @EnvironmentObject private var state: AppState
    @State private var showingMetadataSettings = false

    var body: some View {
        HStack(spacing: 16) {
            Toggle("Movie folders", isOn: Binding(
                get: { state.namingOptions.useMovieFolders },
                set: { state.namingOptions.useMovieFolders = $0 }
            ))
            .help("Wrap each movie in its own folder: Title (Year)/Title (Year).ext")

            Toggle("Series year", isOn: Binding(
                get: { state.namingOptions.includeSeriesYear },
                set: { state.namingOptions.includeSeriesYear = $0 }
            ))
            .help("Include the year in the series folder name.")

            Divider().frame(height: 18)

            Picker("On conflict", selection: $state.conflictPolicy) {
                Text("Ask").tag(ConflictPolicy.ask)
                Text("Skip").tag(ConflictPolicy.skip)
                Text("Rename").tag(ConflictPolicy.rename)
                Text("Replace").tag(ConflictPolicy.replace)
            }
            .pickerStyle(.menu)
            .fixedSize()

            OutputModeControl()

            Spacer()

            if state.isLookingUp {
                ProgressView().controlSize(.small)
            }
            Button {
                showingMetadataSettings = true
            } label: {
                Label(state.onlineLookupEnabled ? "Online: On" : "Online", systemImage: "globe")
                    .foregroundStyle(state.onlineLookupEnabled ? Color.accentColor : Color.primary)
            }
            .help("TMDb online lookup settings (FR3).")
            .sheet(isPresented: $showingMetadataSettings) {
                MetadataSettingsView()
            }

            Button {
                state.undoLast()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!state.canUndo || state.isProcessing)

            Button {
                state.start()
            } label: {
                Label("Start", systemImage: "play.fill")
                    .frame(minWidth: 60)
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .disabled(state.isProcessing || state.acceptedCount == 0)
        }
    }
}

/// In-place vs. custom library folder selector (FR18 stays local either way).
private struct OutputModeControl: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            switch state.outputMode {
            case .inPlace:
                Button("Output: In place…") { chooseFolder() }
                    .help("Files are renamed where they are. Click to pick a library folder instead.")
            case let .customFolder(url):
                Button("Output: \(url.lastPathComponent)…") { chooseFolder() }
                Button {
                    state.outputMode = .inPlace
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Switch back to renaming in place.")
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Library Folder"
        if panel.runModal() == .OK, let url = panel.url {
            state.outputMode = .customFolder(url)
        }
    }
}
