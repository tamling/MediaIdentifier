import SwiftUI
import UniformTypeIdentifiers
import MediaIdentifierCore

/// The main pane: toolbar, progress strip, drop area / file list, and status bar.
struct QueueView: View {
    @EnvironmentObject private var state: AppState
    let section: SidebarSection
    let title: String

    @State private var dragging = false
    @FocusState private var searchFocused: Bool

    private var rows: [RenameItem] { state.sortedItems(in: section) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if state.isProcessing { ProgressStrip() }

            ZStack {
                if state.hasFiles {
                    fileList
                } else {
                    EmptyDropView()
                }
                if dragging { DropOverlay() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $dragging, perform: handleDrop)

            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBg)
        .background(focusButton)
    }

    /// Invisible button giving ⌘F to focus the search field (FR19 polish).
    private var focusButton: some View {
        Button("") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            TextField("Suchen", text: $state.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 150)
                .focused($searchFocused)
            if !state.searchText.isEmpty {
                Button(action: { state.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.chipBg, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(searchFocused ? Theme.accent.opacity(0.5) : Color.white.opacity(0.08),
                              lineWidth: 0.5)
        )
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(state.subtitleText).font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()

            ToolbarButton(title: "Aufräumen…", systemImage: "wand.and.stars",
                          action: state.chooseFoldersToOrganize)
            if state.hasFiles {
                ToolbarButton(title: "Liste leeren", action: state.clear)
            }
            if state.hasConvertibleResults && !state.isProcessing {
                ToolbarButton(title: "Konvertieren", systemImage: "arrow.right.circle",
                              action: state.convertCompleted)
            }
            if state.showUndo {
                ToolbarButton(title: "Rückgängig", systemImage: "arrow.uturn.backward",
                              action: state.undoLast)
            }
            if state.canStart {
                Button(action: state.start) {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                        Text(state.startLabel).font(.system(size: 12.5, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15).padding(.vertical, 7)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
                    )
                    .shadow(color: Theme.accent.opacity(0.4), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .overlay(Theme.hairline.frame(height: 0.5), alignment: .bottom)
    }

    // MARK: List

    private var fileList: some View {
        VStack(spacing: 0) {
            listHeader
            ScrollView {
                LazyVStack(spacing: 4, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                FileRowView(item: item)
                            }
                        } header: {
                            if let title = section.title {
                                GroupHeader(title: title, count: section.items.count)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
        }
    }

    // Groups episodes under "Show · Staffel XX" headers (movies under "Filme")
    // when sorting by show is enabled.
    private struct RowSection: Identifiable { let id: String; let title: String?; let items: [RenameItem] }

    private var sections: [RowSection] {
        let items = state.sortedItems(in: section)
        guard state.sortByShow, !items.isEmpty else {
            return [RowSection(id: "all", title: nil, items: items)]
        }
        var result: [RowSection] = []
        var key: String? = nil
        var bucket: [RenameItem] = []
        func flush() {
            guard let first = bucket.first else { return }
            result.append(RowSection(id: key ?? first.id.uuidString, title: header(for: first), items: bucket))
            bucket = []
        }
        for item in items {
            let k = groupKey(for: item)
            if k != key { flush(); key = k }
            bucket.append(item)
        }
        flush()
        return result
    }

    private func groupKey(for item: RenameItem) -> String {
        let p = item.mediaFile.parsed
        guard p.kind == .episode else { return "movies" }
        return "\(p.title.lowercased())|\(p.season ?? 0)"
    }

    private func header(for item: RenameItem) -> String {
        let p = item.mediaFile.parsed
        guard p.kind == .episode else { return "Filme" }
        let title = p.title.isEmpty ? "Unbekannt" : p.title
        return "\(title) · Staffel \(String(format: "%02d", p.season ?? 1))"
    }

    private var listHeader: some View {
        HStack(spacing: 12) {
            Button(action: state.toggleAll) {
                HStack(spacing: 8) {
                    CheckBox(checked: state.allChecked, size: 16)
                    Text("Alle auswählen")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xA0A0A6))
                }
            }
            .buttonStyle(.plain)

            searchField

            Button(action: { state.hideCompleted.toggle() }) {
                HStack(spacing: 5) {
                    Image(systemName: state.hideCompleted ? "eye.slash" : "eye")
                    Text("Erledigte")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(state.hideCompleted ? Theme.accentBright : Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Bereits umbenannte Einträge aus- oder einblenden")

            Spacer()
            Button(action: { state.sortByShow.toggle() }) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(state.sortByShow ? "Serie/Staffel" : "Reihenfolge")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(state.sortByShow ? Theme.accentBright : Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Sortierung: nach Serie → Staffel → Episode")
            HStack(spacing: 14) {
                Text("\(state.readyCount) bereit")
                    .foregroundStyle(Theme.accentBright)
                Text("\(state.warnCount) prüfen")
                    .foregroundStyle(Theme.warn)
            }
            .font(.system(size: 11.5, weight: .semibold))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .overlay(Theme.hairline.frame(height: 0.5), alignment: .bottom)
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(state.statusBarText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.mono)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal").font(.system(size: 10))
                Text("Jellyfin-Schema").font(.system(size: 11.5))
            }
            .foregroundStyle(Theme.mono)
        }
        .padding(.horizontal, 18)
        .frame(height: 30)
        .background(Color.white.opacity(0.02))
        .overlay(Theme.hairline.frame(height: 0.5), alignment: .top)
    }

    // MARK: Drag & drop (FR1)

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
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

/// Indeterminate sweeping progress bar shown during renaming.
private struct ProgressStrip: View {
    @State private var animate = false
    var body: some View {
        GeometryReader { geo in
            Rectangle().fill(Color.white.opacity(0.06))
                .overlay(
                    LinearGradient(
                        colors: [.clear, Theme.accentGlow, .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.4)
                    .offset(x: animate ? geo.size.width : -geo.size.width * 0.4)
                )
                .clipped()
        }
        .frame(height: 3)
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(style: StrokeStyle(lineWidth: 2.5, dash: [9]))
            .foregroundStyle(Theme.accentBright)
            .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                Text("Zum Hinzufügen loslassen")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.accentBright)
            )
            .padding(10)
    }
}

/// Section heading for grouped results (e.g. "The Last of Us · Staffel 01").
private struct GroupHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.textRow)
                .lineLimit(1).truncationMode(.middle)
            Text("\(count)")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Theme.chipBg, in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12).padding(.bottom, 6)
        .background(Theme.windowBg)
    }
}

/// Small secondary toolbar button.
struct ToolbarButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .bold))
                }
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(Theme.textRow)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(hovering ? Color.white.opacity(0.1) : Theme.chipBg,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Rounded checkbox matching the design.
struct CheckBox: View {
    let checked: Bool
    var size: CGFloat = 19
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32)
            .fill(checked ? Theme.accent : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.32)
                    .strokeBorder(checked ? Color.white.opacity(0.2) : Color.white.opacity(0.22),
                                  lineWidth: checked ? 0.5 : 1.5)
            )
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.55, weight: .heavy))
                    .foregroundStyle(.white)
                    .opacity(checked ? 1 : 0)
            )
            .frame(width: size, height: size)
    }
}
