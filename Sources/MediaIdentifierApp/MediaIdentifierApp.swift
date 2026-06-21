import SwiftUI
import AppKit

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
            // Jump between sidebar sections with ⌘1…⌘5.
            CommandGroup(after: .sidebar) {
                Button("Queue") { state.section = .queue }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Convert") { state.section = .convert }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Watch folder") { state.section = .watch }
                    .keyboardShortcut("3", modifiers: [.command])
                Button("Log") { state.section = .log }
                    .keyboardShortcut("4", modifiers: [.command])
                Button("Overview") { state.section = .overview }
                    .keyboardShortcut("5", modifiers: [.command])
            }
        }

        // Menu-bar item: keep the app reachable from the status bar when the
        // window is minimized/closed (Show / Quit, with a live status line).
        MenuBarExtra("MediaIdentifier", systemImage: "film.stack") {
            Text(menuBarStatus)
            Divider()
            Button("Show MediaIdentifier") { showMainWindow() }
            Button("Settings…") { showMainWindow(); state.showingSettings = true }
            Divider()
            Button("Quit MediaIdentifier") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: [.command])
        }
    }

    private var menuBarStatus: String {
        if state.isProcessing { return "Renaming… \(Int(state.progress * 100)) %" }
        if state.isConverting { return "Converting… \(Int(state.convertProgress * 100)) %" }
        if state.hasFiles { return "\(state.items.count) files in queue" }
        return "Idle"
    }

    private func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows where window.canBecomeMain {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }
}
