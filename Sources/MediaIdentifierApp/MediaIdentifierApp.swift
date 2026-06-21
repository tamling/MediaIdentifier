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
            }
        }
    }
}
