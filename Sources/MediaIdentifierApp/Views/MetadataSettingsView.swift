import SwiftUI
import AppKit
import MediaIdentifierCore

/// Einstellungen: naming, conflict handling, output and TMDb online lookup (FR3,
/// FR7, FR11, FR18).
struct MetadataSettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            TabView(selection: $selectedTab) {
                tab { namingTab }
                    .tabItem { Label("Naming & output", systemImage: "textformat") }.tag(0)
                tab { detectionTab }
                    .tabItem { Label("Identification", systemImage: "sparkles") }.tag(1)
                tab { serverTab }
                    .tabItem { Label("Server & automation", systemImage: "server.rack") }.tag(2)
            }
            .frame(height: 600)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 600)
        .background(Theme.windowBg)
        .tint(Theme.accent)
        .onAppear(perform: applyFocus)
        .onChange(of: state.settingsFocus) { _ in applyFocus() }
    }

    /// Opens the tab matching the area the user asked to set up (from Overview).
    private func applyFocus() {
        switch state.settingsFocus {
        case .naming: selectedTab = 0
        case .identification: selectedTab = 1
        case .server: selectedTab = 2
        case nil: break
        }
    }

    /// Wraps a tab's groups in a scroll view so long content stays reachable.
    private func tab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 2)
        }
    }

    // MARK: Tab 1 — Benennung & Ausgabe

    @ViewBuilder private var namingTab: some View {
            // Naming (FR7)
            group("Naming") {
                Toggle("Place movies in their own folder", isOn: Binding(
                    get: { state.namingOptions.useMovieFolders },
                    set: { state.namingOptions.useMovieFolders = $0 }
                ))
                Toggle("Show year in series folder", isOn: Binding(
                    get: { state.namingOptions.includeSeriesYear },
                    set: { state.namingOptions.includeSeriesYear = $0 }
                ))
            }

            // Free output folder for renaming (FR18)
            group("Output folder") {
                Toggle("Write renamed files to a dedicated folder", isOn: $state.outputToFolder)
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(Theme.textSecondary)
                    Text(state.outputFolderPath.isEmpty ? "No folder chosen" : state.outputFolderPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(state.outputFolderPath.isEmpty ? Theme.textTertiary : Theme.textRow)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose folder…", action: chooseOutput)
                }
                .disabled(!state.outputToFolder)
                Text("Off is the default: files are renamed in place. When on, the entire Jellyfin layout is created under the chosen folder — you can then convert from there.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Library move (complete seasons / movies)
            group("Library") {
                Toggle("Move finished files to library", isOn: $state.moveToLibrary)
                HStack(spacing: 10) {
                    Image(systemName: "books.vertical").foregroundStyle(Theme.textSecondary)
                    Text(state.libraryFolderPath.isEmpty ? "No folder chosen" : state.libraryFolderPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(state.libraryFolderPath.isEmpty ? Theme.textTertiary : Theme.textRow)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose folder…", action: chooseLibrary)
                }
                .disabled(!state.moveToLibrary)
                Text("Movies are always moved; series only when the season is complete (episodes 1…N without gaps). Incomplete seasons stay in place.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Conflicts (FR11)
            group("On conflict") {
                Picker("", selection: $state.conflictPolicy) {
                    Text("Ask").tag(ConflictPolicy.ask)
                    Text("Skip").tag(ConflictPolicy.skip)
                    Text("Rename").tag(ConflictPolicy.rename)
                    Text("Replace").tag(ConflictPolicy.replace)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
    }

    // MARK: Tab 2 — Erkennung

    @ViewBuilder private var detectionTab: some View {
            // On-device Apple Intelligence (FR3, local)
            group("Identification – Apple Intelligence (local)") {
                Toggle("Identify titles with Apple Intelligence (on-device)",
                       isOn: $state.useAppleIntelligence)
                    .disabled(!state.appleIntelligenceSupported)
                Text(state.appleIntelligenceSupported
                     ? "Uses the on-device language model. Runs entirely locally — no data is sent. Takes precedence over TMDb."
                     : "Not available: requires macOS 26+, Apple Silicon and enabled Apple Intelligence.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Embedded container tags (FR3, local)
            group("Embedded metadata (local)") {
                Toggle("Read title/year from the file (MKV/MP4)",
                       isOn: $state.useEmbeddedMetadata)
                Text("Reads tags stored in the container via AVFoundation. Only applies if the file contains such tags.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Local offline title database (FR3)
            group("Local title database (local)") {
                Toggle("Use offline database", isOn: $state.useLocalDatabase)
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
                        Button("Choose file…", action: chooseDatabase)
                    }
                }
                Text("Download the TMDb export once from files.tmdb.org/p/exports (movie_ids / tv_series_ids, .json/.jsonl, also .gz). After that, matching happens offline.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Online metadata (FR3)
            group("Online metadata (TMDb)") {
                Toggle("Look up official titles online", isOn: $state.onlineLookupEnabled)
                SecureField("TMDb v3 key or v4 Read Access Token", text: $state.tmdbAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!state.onlineLookupEnabled)
                Text("Get the key/token on themoviedb.org → Settings → API. v3 key and v4 token are detected automatically. Only title and year are sent — never a media file.")
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
                            Text("Look up now")
                        }
                    }
                    .disabled(!state.canLookUpOnline || state.isLookingUp)
                    Button("Test connection") { state.testTMDb() }
                        .disabled(state.tmdbAPIKey.isEmpty)
                    Spacer()
                }
                testResult(state.tmdbTestResult)
            }
    }

    // MARK: Tab 3 — Server & Automatik

    @ViewBuilder private var serverTab: some View {
            // Jellyfin connector (FR20)
            group("Jellyfin server (refresh after renaming)") {
                Toggle("Refresh Jellyfin library automatically", isOn: $state.jellyfinEnabled)
                TextField("Server URL, e.g. http://localhost:8096", text: $state.jellyfinServerURL)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!state.jellyfinEnabled)
                SecureField("API key (Dashboard → API Keys)", text: $state.jellyfinAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!state.jellyfinEnabled)
                Text("After renaming, Jellyfin is asked to rescan the library so the files are picked up automatically. No media files are sent — only a scan command. Create a key in the Jellyfin dashboard under 'API Keys'.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Test connection") { state.testJellyfin() }
                        .disabled(!state.jellyfinEnabled || state.jellyfinServerURL.isEmpty || state.jellyfinAPIKey.isEmpty)
                    Spacer()
                }
                testResult(state.jellyfinTestResult)
            }

            // Read-only status web page (FR20)
            group("Status web page (view only)") {
                Toggle("Enable status web page", isOn: $state.webEnabled)
                HStack {
                    Text("Port")
                    TextField("Port", value: $state.webPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .disabled(!state.webEnabled)
                    Spacer()
                }
                Toggle("Local only (127.0.0.1)", isOn: $state.webLocalOnly)
                    .disabled(!state.webEnabled)
                if state.webEnabled {
                    Text("Open: \(state.webURL)  ·  JSON: \(state.webURL)api/status")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.accentBright)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Provides a view-only page with the current state. Simple reachability monitoring: in Uptime Kuma set up a regular HTTP monitor on …/healthz accepting status 200 → 200 = done (100 %), 503 = still running, 500 = error; Kuma thus reports completion and errors. Alternatively JSON: …/api/status with field 'busy'. Turn on 'Local only' if Kuma runs on the same Mac (otherwise reachable on the LAN). No commands are accepted, and no tokens or full paths are shown.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Watch folder lives in its own sidebar section; point users there.
            group("Watch folder") {
                Text("Automatic monitoring of a download folder is configured in the 'Watch folder' section in the sidebar.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }

    private var databaseStatus: String {
        if let error = state.databaseError { return error }
        if state.isLoadingDatabase { return "Loading …" }
        if state.localDatabaseCount > 0 { return "\(state.localDatabaseCount) titles loaded" }
        return state.localDatabasePath.isEmpty ? "No file chosen" : "Not loaded"
    }

    private func chooseLibrary() { chooseFolder(apply: state.setLibraryFolder) }
    private func chooseOutput() { chooseFolder(apply: state.setOutputFolder) }

    /// Prompts for a single folder and passes the chosen URL to `apply`.
    private func chooseFolder(apply: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { apply(url) }
    }

    private func chooseDatabase() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Load"
        if panel.runModal() == .OK, let url = panel.url {
            state.setLocalDatabaseFile(url)
        }
    }

    /// Coloured connection-test feedback (green for success, warn otherwise).
    @ViewBuilder
    private func testResult(_ result: String?) -> some View {
        if let result {
            Text(result)
                .font(.caption)
                .foregroundStyle(result.hasPrefix("✓") ? Theme.accentBright : Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
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
