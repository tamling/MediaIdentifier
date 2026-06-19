import SwiftUI
import UniformTypeIdentifiers
import MediaIdentifierCore

/// Top-level layout: drop area + preview on top, log at the bottom, with a
/// toolbar of settings and the Start action (FR19).
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            SettingsBar()
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()

            VSplitView {
                VStack(spacing: 0) {
                    if state.items.isEmpty {
                        DropZone(isTargeted: $isDropTargeted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        PreviewTable()
                    }
                }
                .frame(minHeight: 260)
                .background(dropHighlight)
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)

                LogPane()
                    .frame(minHeight: 140)
            }

            Divider()
            StatusBar()
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 0)
            .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    // MARK: Drag and drop (FR1)

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            state.importURLs(urls)
        }
        return true
    }
}

/// The empty-state drop target.
struct DropZone: View {
    @Binding var isTargeted: Bool
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drag media files or folders here")
                .font(.title3)
            Text("MKV · AVI · MP4 · MOV · M4V and more — subtitles and extras come along automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Files…", action: chooseFiles)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .padding(20)
        )
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            state.importURLs(panel.urls)
        }
    }
}
