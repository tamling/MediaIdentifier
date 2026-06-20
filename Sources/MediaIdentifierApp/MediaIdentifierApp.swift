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
                .frame(minWidth: 960, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("Umbenennung rückgängig") { state.undoLast() }
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(!state.showUndo)
            }
        }
    }
}
