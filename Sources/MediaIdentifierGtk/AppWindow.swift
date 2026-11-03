import CGtk3
import Foundation
import MediaIdentifierCore

/// Mediafin's window.
///
/// It owns no logic. Every button submits a `WebCommand` to the
/// `AppCoordinator` — the same engine the web interface drives — and the
/// window learns what happened by reading the snapshot back on a timer. The
/// coordinator runs work on its own serial queue, so a click must never wait
/// for a scan, and it cannot call into GTK, which may only be touched from
/// the main thread. Polling is the honest shape for that boundary.
final class AppWindow {
    let widget: UnsafeMutablePointer<GtkWidget>

    private let coordinator: AppCoordinator

    private let header: UnsafeMutablePointer<GtkWidget>
    private let resultLabel: UnsafeMutablePointer<GtkWidget>
    private let countsLabel: UnsafeMutablePointer<GtkWidget>
    private let sourceChooser: UnsafeMutablePointer<GtkWidget>
    private let moviesChooser: UnsafeMutablePointer<GtkWidget>
    private let seriesChooser: UnsafeMutablePointer<GtkWidget>
    private let scanButton: UnsafeMutablePointer<GtkWidget>
    private let applyButton: UnsafeMutablePointer<GtkWidget>
    private let undoButton: UnsafeMutablePointer<GtkWidget>
    private let listColumn: UnsafeMutablePointer<GtkWidget>

    /// The rows currently on screen, kept so they can be destroyed without
    /// walking the container — which would mean another C callback.
    private var rowWidgets: [UnsafeMutablePointer<GtkWidget>] = []
    /// Which proposal each tick box belongs to. The window holds no opinion
    /// about what is selected beyond what these say, so there is nothing to
    /// keep in step with them.
    private var rowChecks: [(id: UUID, check: UnsafeMutablePointer<GtkWidget>)] = []
    /// What the list was last built from. The refresh runs twice a second and
    /// rebuilding every time would throw away the scroll position.
    ///
    /// Optional rather than an empty array: at startup there are no proposals
    /// *and* nothing has been rendered, and comparing `[] == []` would skip
    /// the first build and leave the empty-state line unwritten.
    private var renderedItemIDs: [UUID]?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator

        let window = gtk_window_new(GTK_WINDOW_TOPLEVEL)!
        gtk_window_set_default_size(Gtk.window(window), 900, 640)
        // Set as well as the header bar's title: this is what a taskbar, an
        // alt-tab switcher and a window list show.
        gtk_window_set_title(Gtk.window(window), "Mediafin")
        self.widget = window

        // A header bar rather than a label at the top of the page: it is what
        // the window manager draws the title into on a modern desktop, so the
        // primary action sits in the same strip as the window controls
        // instead of below them.
        header = gtk_header_bar_new()!
        gtk_header_bar_set_show_close_button(Gtk.headerBar(header), 1)
        gtk_header_bar_set_title(Gtk.headerBar(header), "Mediafin")
        scanButton = gtk_button_new_with_label("Durchsuchen")!
        // The theme's own accent, not a colour of ours — it follows whatever
        // the user has set.
        Styling.style(scanButton, "suggested-action")
        gtk_header_bar_pack_end(Gtk.headerBar(header), scanButton)
        gtk_window_set_titlebar(Gtk.window(window), header)

        let page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16)!
        gtk_container_set_border_width(Gtk.container(page), 18)
        gtk_container_add(Gtk.container(window), page)

        // MARK: Folders

        sourceChooser = Self.folderChooser("Ordner mit den neuen Dateien")
        moviesChooser = Self.folderChooser("Filmbibliothek")
        seriesChooser = Self.folderChooser("Serienbibliothek")

        let folders = Self.card(titled: "Bibliothek")
        Self.add(Self.row("Quelle", sourceChooser), to: folders)
        Self.add(Self.row("Filme", moviesChooser), to: folders)
        Self.add(Self.row("Serien", seriesChooser), to: folders)

        let saveRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        let saveButton = gtk_button_new_with_label("Übernehmen")!
        gtk_box_pack_end(Gtk.box(saveRow), saveButton, 0, 0, 0)
        Self.add(saveRow, to: folders)
        gtk_box_pack_start(Gtk.box(page), folders, 0, 0, 0)

        // MARK: Proposals

        let proposals = Self.card(titled: "Vorschläge")
        countsLabel = Self.label("", classes: "mf-dim")
        Self.add(countsLabel, to: proposals)

        // A plain box inside a scroller rather than a GtkTreeView: a tree
        // model needs GValue boxing and cell renderers, which is a lot of C
        // surface to get wrong for a list that only has to be read. It will
        // have to become a TreeView if these lists reach the thousands.
        listColumn = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1)!
        let scroller = gtk_scrolled_window_new(nil, nil)!
        gtk_scrolled_window_set_policy(Gtk.scrolledWindow(scroller),
                                       GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_container_add(Gtk.container(scroller), listColumn)
        Self.add(scroller, to: proposals, expand: true)

        // Selecting on the left, acting on the right: the destructive end of
        // the row is the one that should take a deliberate reach.
        let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let allButton = gtk_button_new_with_label("Alle")!
        let noneButton = gtk_button_new_with_label("Keine")!
        gtk_box_pack_start(Gtk.box(actions), allButton, 0, 0, 0)
        gtk_box_pack_start(Gtk.box(actions), noneButton, 0, 0, 0)
        undoButton = gtk_button_new_with_label("Rückgängig")!
        applyButton = gtk_button_new_with_label("Umbenennen")!
        Styling.style(applyButton, "suggested-action")
        gtk_box_pack_end(Gtk.box(actions), applyButton, 0, 0, 0)
        gtk_box_pack_end(Gtk.box(actions), undoButton, 0, 0, 0)
        Self.add(actions, to: proposals)

        gtk_box_pack_start(Gtk.box(page), proposals, 1, 1, 0)

        // Footer: what just happened on the left, which version said so on
        // the right. The version is there so a bug report can name one.
        let footer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)!
        resultLabel = Self.label("", classes: "mf-dim")
        gtk_label_set_line_wrap(Gtk.label(resultLabel), 1)
        gtk_box_pack_start(Gtk.box(footer), resultLabel, 1, 1, 0)
        let version = Self.label(MediafinVersion.display, classes: "mf-dim")
        gtk_label_set_xalign(Gtk.label(version), 1)
        gtk_box_pack_end(Gtk.box(footer), version, 0, 0, 0)
        gtk_box_pack_start(Gtk.box(page), footer, 0, 0, 0)

        Gtk.onClick(saveButton, self) { $0.saveFolders() }
        Gtk.onClick(scanButton, self) { $0.scan() }
        Gtk.onClick(applyButton, self) { $0.applySelected() }
        Gtk.onClick(undoButton, self) { $0.undoLast() }
        Gtk.onClick(allButton, self) { $0.setAllChecked(true) }
        Gtk.onClick(noneButton, self) { $0.setAllChecked(false) }

        loadFolders()
        refresh()
    }

    // MARK: Actions

    /// Writes the chosen folders into the settings the engine reads.
    ///
    /// The folding is in Core (`FolderSelection`) and not here, because the
    /// rule it encodes is not obvious and needs a test: a blank chooser means
    /// "could not show it", not "cleared it". `gtk_file_chooser_set_filename`
    /// fails silently for a path that no longer exists, so an unmounted drive
    /// would otherwise wipe the stored library path on the next save.
    func saveFolders() {
        let settings = FolderSelection.applying(
            source: Gtk.chosenFolder(sourceChooser),
            movies: Gtk.chosenFolder(moviesChooser),
            series: Gtk.chosenFolder(seriesChooser),
            to: coordinator.settings
        )
        coordinator.submit(.saveSettings(settings))
    }

    /// Saving first, so pressing "Durchsuchen" straight after picking a folder
    /// does what it looks like it does rather than scanning the previous one.
    func scan() {
        saveFolders()
        coordinator.submit(.scanSourceFolder)
    }

    /// Hands the engine the ids that are ticked, and nothing else.
    ///
    /// An empty selection is submitted as an empty set rather than caught
    /// here: the coordinator already answers that case with "No files were
    /// ticked, so nothing was renamed", and a second opinion in the window
    /// would be one more place for the two to disagree.
    func applySelected() {
        let ticked = rowChecks.filter { Gtk.isChecked($0.check) }.map(\.id)
        coordinator.submit(.applyProposedRenames(accepting: Set(ticked)))
    }

    func undoLast() {
        coordinator.submit(.undoLastRename)
    }

    func setAllChecked(_ on: Bool) {
        for row in rowChecks { Gtk.setChecked(row.check, on) }
    }

    private func loadFolders() {
        let settings = coordinator.settings
        Gtk.setChosenFolder(sourceChooser, settings.sourceFolder)
        Gtk.setChosenFolder(moviesChooser, settings.moviesFolder)
        Gtk.setChosenFolder(seriesChooser, settings.seriesFolder)
    }

    // MARK: Reading the engine back

    /// Pulls the current state into the window. Called on a timer because the
    /// coordinator works on its own queue and has no way to call back into
    /// GTK, which may only be touched from the main thread.
    func refresh() {
        let state = coordinator.snapshot

        let subtitle: String
        if state.hasError {
            subtitle = "Mit Fehlern beendet"
        } else if state.busy {
            subtitle = "\(state.convertStatus ?? "Arbeitet") · \(state.activePercent) %"
        } else {
            subtitle = "Bereit"
        }
        gtk_header_bar_set_subtitle(Gtk.headerBar(header), subtitle)

        Gtk.setText(countsLabel,
                    "\(state.totalItems) Vorschläge · \(state.ready) bereit · "
                        + "\(state.done) umbenannt")
        Gtk.setText(resultLabel, state.lastResult ?? "")

        // Nothing to scan without a source folder, and a button that does
        // nothing is worse than one that is visibly unavailable.
        let hasSource = !coordinator.settings.sourceFolder.isEmpty
        gtk_widget_set_sensitive(scanButton, (hasSource && !state.busy) ? 1 : 0)
        gtk_widget_set_sensitive(applyButton, (!rowChecks.isEmpty && !state.busy) ? 1 : 0)
        gtk_widget_set_sensitive(undoButton, state.busy ? 0 : 1)

        refreshList()
    }

    /// Rebuilds the proposal list, but only when the proposals have actually
    /// changed: this runs twice a second, and rebuilding every time would
    /// reset the scroll position under the reader's hands.
    private func refreshList() {
        let items = coordinator.items
        let ids = items.map(\.id)
        guard ids != renderedItemIDs else { return }
        renderedItemIDs = ids

        for row in rowWidgets { gtk_widget_destroy(row) }
        rowWidgets = []
        rowChecks = []

        if items.isEmpty {
            let empty = Self.label("Noch nichts durchsucht.", classes: "mf-empty")
            gtk_label_set_xalign(Gtk.label(empty), 0.5)
            gtk_box_pack_start(Gtk.box(listColumn), empty, 0, 0, 0)
            rowWidgets = [empty]
        } else {
            for (index, item) in items.enumerated() {
                let built = Self.proposalRow(item, banded: index % 2 == 1)
                gtk_box_pack_start(Gtk.box(listColumn), built.row, 0, 0, 0)
                rowWidgets.append(built.row)
                rowChecks.append((id: item.id, check: built.check))
            }
        }
        // New widgets start hidden; the window was already shown.
        gtk_widget_show_all(listColumn)
    }

    /// One proposal: what the file is called now, and what it would be called.
    ///
    /// Nothing here says the rename has happened — the list is a preview, and
    /// the wording has to keep saying so until a button is pressed.
    private static func proposalRow(_ item: RenameItem, banded: Bool)
        -> (row: UnsafeMutablePointer<GtkWidget>, check: UnsafeMutablePointer<GtkWidget>) {
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10)!
        Styling.style(row, "mf-row")
        if banded { Styling.style(row, "mf-row-alt") }

        // The planner already decided what it would accept — a file it is
        // unsure about comes in unticked. Overriding that here would mean the
        // window quietly disagreeing with the engine about what is safe.
        let check = gtk_check_button_new()!
        Gtk.setChecked(check, item.isAccepted)
        gtk_widget_set_valign(check, GTK_ALIGN_CENTER)
        gtk_box_pack_start(Gtk.box(row), check, 0, 0, 0)

        let text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        let from = label(item.originalFileName, classes: "mf-from")
        gtk_label_set_ellipsize(Gtk.label(from), PANGO_ELLIPSIZE_MIDDLE)
        gtk_box_pack_start(Gtk.box(text), from, 0, 0, 0)

        let to = label(item.newFileName, classes: "mf-to")
        gtk_label_set_ellipsize(Gtk.label(to), PANGO_ELLIPSIZE_MIDDLE)
        gtk_box_pack_start(Gtk.box(text), to, 0, 0, 0)

        if let conflict = item.conflict {
            let warning = label(conflictText(conflict), classes: "mf-warn")
            gtk_box_pack_start(Gtk.box(text), warning, 0, 0, 0)
        }
        gtk_box_pack_start(Gtk.box(row), text, 1, 1, 0)
        return (row, check)
    }

    private static func conflictText(_ kind: ConflictKind) -> String {
        switch kind {
        case .existingFile: return "Dort liegt schon eine Datei"
        case .duplicateInBatch: return "Zwei Dateien wollen denselben Namen"
        }
    }

    // MARK: Widgets

    private static func label(_ text: String,
                              classes: String...) -> UnsafeMutablePointer<GtkWidget> {
        let label = gtk_label_new(text)!
        gtk_label_set_xalign(Gtk.label(label), 0)
        for name in classes { Styling.style(label, name) }
        return label
    }

    /// A grouped panel with a quiet caption, the shape GTK's own settings
    /// dialogues use.
    private static func card(titled title: String) -> UnsafeMutablePointer<GtkWidget> {
        let card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
        Styling.style(card, "mf-card")
        let caption = label(title.uppercased(), classes: "mf-card-title")
        gtk_box_pack_start(Gtk.box(card), caption, 0, 0, 0)
        return card
    }

    private static func add(_ child: UnsafeMutablePointer<GtkWidget>,
                            to card: UnsafeMutablePointer<GtkWidget>,
                            expand: Bool = false) {
        gtk_box_pack_start(Gtk.box(card), child, expand ? 1 : 0, expand ? 1 : 0, 0)
    }

    private static func folderChooser(_ title: String) -> UnsafeMutablePointer<GtkWidget> {
        gtk_file_chooser_button_new(title, GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER)!
    }

    /// A caption of fixed width beside its control, so the rows line up
    /// without a grid.
    private static func row(_ caption: String,
                            _ control: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget> {
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)!
        let text = label(caption)
        gtk_widget_set_size_request(text, 78, -1)
        gtk_box_pack_start(Gtk.box(row), text, 0, 0, 0)
        gtk_box_pack_start(Gtk.box(row), control, 1, 1, 0)
        return row
    }
}
