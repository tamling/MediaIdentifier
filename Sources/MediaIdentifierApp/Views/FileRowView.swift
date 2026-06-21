import SwiftUI
import MediaIdentifierCore

/// One queued file: checkbox, type icon, paths, metadata chips and status.
struct FileRowView: View {
    @EnvironmentObject private var state: AppState
    let item: RenameItem
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""

    private var parsed: ParsedRelease { item.mediaFile.parsed }
    private var isSeries: Bool { parsed.kind == .episode }
    private var statusValue: ItemStatus { state.status(for: item) }
    private var isDone: Bool { statusValue == .done }

    private var folderPath: String {
        let folder = (item.proposedRelativePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? "" : folder + "/"
    }
    private var newFile: String { (item.proposedRelativePath as NSString).lastPathComponent }

    private var subtitleCompanion: CompanionFile? {
        item.mediaFile.companions.first { $0.role == .subtitle }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Button(action: { state.toggle(item.id) }) {
                CheckBox(checked: item.isAccepted || isDone)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            .disabled(isDone)

            typeIcon

            main

            if isDone {
                Button(action: { state.convert(item) }) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accentBright)
                }
                .buttonStyle(.borderless)
                .help("Diese Datei konvertieren")
                .padding(.top, 2)
            } else {
                Button(action: beginEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(editing ? Theme.accentBright : Theme.textSecondary)
                }
                .buttonStyle(.borderless)
                .help("Zielnamen bearbeiten")
                .padding(.top, 2)
            }

            Button(action: { state.revealInFinder(item) }) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.borderless)
            .help("Ordner im Finder öffnen")
            .padding(.top, 2)

            statusBadge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(rowBackground)
        .opacity(statusValue == .skipped ? 0.45 : 1)
        .onHover { hovering = $0 }
    }

    // MARK: Type icon

    private var typeIcon: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(isSeries ? Theme.seriesBg : Theme.movieBg)
            .frame(width: 34, height: 34)
            .overlay(
                Image(systemName: isSeries ? "tv" : "film")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSeries ? Theme.series : Theme.movie)
            )
            .padding(.top, 1)
    }

    // MARK: Main column

    private var main: some View {
        VStack(alignment: .leading, spacing: 5) {
            // New path (folder + file). Click reveals in Finder; the pencil
            // switches to an inline editor for the target file name (FR9).
            if editing {
                HStack(spacing: 6) {
                    if !folderPath.isEmpty {
                        Text(folderPath)
                            .font(Theme.monoFont)
                            .foregroundStyle(Color(hex: 0x7E7E85))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    TextField("Dateiname", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: 340)
                        .onSubmit(commitEdit)
                    Button("Sichern", action: commitEdit)
                        .controlSize(.small)
                    Button("Abbrechen") { editing = false }
                        .controlSize(.small)
                }
            } else {
                Button(action: { state.revealInFinder(item) }) {
                    HStack(spacing: 8) {
                        if !folderPath.isEmpty {
                            Text(folderPath)
                                .font(Theme.monoFont)
                                .foregroundStyle(Color(hex: 0x7E7E85))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Text(newFile)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("Im Finder anzeigen")
            }

            // Original name.
            HStack(spacing: 9) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(hex: 0x6A6A70))
                Text(item.originalFileName)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.mono)
                    .lineLimit(1).truncationMode(.middle)
            }

            // Chips.
            HStack(spacing: 6) {
                Chip(text: isSeries ? "SERIE" : "FILM",
                     fg: isSeries ? Theme.series : Theme.movie,
                     bg: isSeries ? Theme.seriesBg : Theme.movieBg)
                Chip(text: tagText)
                if let res = parsed.resolution {
                    Chip(text: res)
                }
                if let source = parsed.source {
                    Chip(text: source, fg: Theme.movie,
                         bg: Color(hex: 0x508CFF).opacity(0.12), systemImage: "clock")
                }
                if let sub = subtitleCompanion {
                    Chip(text: subLabel(sub), fg: Theme.series,
                         bg: Color(hex: 0x966EFF).opacity(0.13), systemImage: "captions.bubble")
                }
                ForEach(extraCompanions, id: \.label) { extra in
                    Chip(text: extra.label, fg: Theme.movie,
                         bg: Color(hex: 0x508CFF).opacity(0.10), systemImage: extra.icon)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tagText: String {
        if isSeries {
            let s = parsed.season ?? 1
            let e = parsed.episode ?? 0
            return String(format: "S%02dE%02d", s, e)
        }
        return parsed.year.map(String.init) ?? "—"
    }

    private func subLabel(_ sub: CompanionFile) -> String {
        if let tag = sub.languageTag, !tag.isEmpty { return tag.uppercased() }
        return sub.url.pathExtension.uppercased()
    }

    // MARK: Companion (extra) files (FR15)

    private struct ExtraChip { let label: String; let icon: String }

    /// One chip per non-subtitle companion type, so the user sees that NFO /
    /// cover / sample files travel with the rename (FR15).
    private var extraCompanions: [ExtraChip] {
        var counts: [CompanionFile.Role: Int] = [:]
        for companion in item.mediaFile.companions where companion.role != .subtitle {
            counts[companion.role, default: 0] += 1
        }
        let order: [CompanionFile.Role] = [.nfo, .image, .sample, .other]
        return order.compactMap { role in
            guard let count = counts[role] else { return nil }
            let suffix = count > 1 ? " ×\(count)" : ""
            switch role {
            case .nfo:    return ExtraChip(label: "+NFO\(suffix)", icon: "doc.text")
            case .image:  return ExtraChip(label: "+Cover\(suffix)", icon: "photo")
            case .sample: return ExtraChip(label: "+Sample\(suffix)", icon: "film.stack")
            case .other:  return ExtraChip(label: "+Datei\(suffix)", icon: "paperclip")
            case .subtitle: return nil
            }
        }
    }

    // MARK: Inline rename (FR9)

    private func beginEdit() {
        draft = newFile
        editing = true
    }

    private func commitEdit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { editing = false }
        guard !trimmed.isEmpty, trimmed != newFile else { return }
        let dir = (item.proposedRelativePath as NSString).deletingLastPathComponent
        let newPath = dir.isEmpty ? trimmed : dir + "/" + trimmed
        state.updateProposedPath(newPath, for: item.id)
    }

    // MARK: Status

    private var statusBadge: some View {
        let info = statusInfo
        return HStack(spacing: 7) {
            Circle().fill(info.color).frame(width: 7, height: 7)
                .shadow(color: info.color, radius: 3)
            Text(info.label)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(info.color)
        }
        .padding(.top, 3)
        .fixedSize()
    }

    private var statusInfo: (color: Color, label: String) {
        switch statusValue {
        case .ready:    return (Theme.accentBright, "Bereit")
        case .conflict: return (Theme.warn, "Konflikt")
        case .done:     return (Theme.accentBright, "Umbenannt")
        case .skipped:  return (Theme.mono, "Übersprungen")
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 11)
            .fill(
                isDone ? Theme.accent.opacity(0.07)
                : (hovering ? Color.white.opacity(0.035) : .clear)
            )
    }
}
