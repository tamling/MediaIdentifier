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
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("Undo Last Rename") { state.undoLast() }
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(!state.canUndo)
            }
        }
    }
}
