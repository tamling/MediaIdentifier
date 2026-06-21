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
                Button("Settings…") { state.showingSettings = true }
                    .keyboardShortcut(",", modifiers: [.command])
            }
            CommandGroup(after: .pasteboard) {
                Button("Undo rename") { state.undoLast() }
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(!state.showUndo)
                Button("Clear list") { state.clear() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(!state.hasFiles)
            }
            // Jump between sidebar sections with ⌘1…⌘7.
            CommandGroup(after: .sidebar) {
                Button("Queue") { state.section = .queue }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Movies") { state.section = .movies }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Series") { state.section = .series }
                    .keyboardShortcut("3", modifiers: [.command])
                Button("Convert") { state.section = .convert }
                    .keyboardShortcut("4", modifiers: [.command])
                Button("Watch folder") { state.section = .watch }
                    .keyboardShortcut("5", modifiers: [.command])
                Button("Log") { state.section = .log }
                    .keyboardShortcut("6", modifiers: [.command])
                Button("Overview") { state.section = .overview }
                    .keyboardShortcut("7", modifiers: [.command])
            }
        }
    }
}
