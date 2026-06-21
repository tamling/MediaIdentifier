import SwiftUI

/// macOS (Apple Silicon) entry point. Drag-and-drop media files, preview the
/// Jellyfin-conformant renames, then apply them.
@main
struct MediaIdentifierApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 900, idealWidth: 1180, maxWidth: .infinity,
                       minHeight: 600, idealHeight: 760, maxHeight: .infinity)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Einstellungen…") { state.showingSettings = true }
                    .keyboardShortcut(",", modifiers: [.command])
            }
            CommandGroup(after: .pasteboard) {
                Button("Umbenennung rückgängig") { state.undoLast() }
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(!state.showUndo)
                Button("Liste leeren") { state.clear() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(!state.hasFiles)
            }
            // Jump between sidebar sections with ⌘1…⌘7.
            CommandGroup(after: .sidebar) {
                Button("Warteschlange") { state.section = .queue }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Filme") { state.section = .movies }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Serien") { state.section = .series }
                    .keyboardShortcut("3", modifiers: [.command])
                Button("Konvertieren") { state.section = .convert }
                    .keyboardShortcut("4", modifiers: [.command])
                Button("Watch-Ordner") { state.section = .watch }
                    .keyboardShortcut("5", modifiers: [.command])
                Button("Protokoll") { state.section = .log }
                    .keyboardShortcut("6", modifiers: [.command])
                Button("Übersicht") { state.section = .overview }
                    .keyboardShortcut("7", modifiers: [.command])
            }
        }
    }
}
