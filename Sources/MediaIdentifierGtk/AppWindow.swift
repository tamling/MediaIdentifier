import CGtk3
import Foundation
import MediaIdentifierCore

/// Mediafin's window.
///
/// It owns no logic of its own. Every button submits a `WebCommand` to the
/// `AppCoordinator` — the same engine the web interface drives — and the
/// window learns what happened by reading the snapshot back on a timer. That
/// is deliberate: the coordinator runs work on its own serial queue, so a
/// click must never wait for a scan to finish, and anything the window
/// decided for itself would be a second answer to a question the engine has
/// already answered.
final class AppWindow {
    let widget: UnsafeMutablePointer<GtkWidget>

    private let coordinator: AppCoordinator

    private let statusBadge: UnsafeMutablePointer<GtkWidget>
    private let resultLabel: UnsafeMutablePointer<GtkWidget>
    private let countsLabel: UnsafeMutablePointer<GtkWidget>
    private let sourceChooser: UnsafeMutablePointer<GtkWidget>
    private let moviesChooser: UnsafeMutablePointer<GtkWidget>
    private let seriesChooser: UnsafeMutablePointer<GtkWidget>
    private let scanButton: UnsafeMutablePointer<GtkWidget>

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator

        let window = gtk_window_new(GTK_WINDOW_TOPLEVEL)!
        gtk_window_set_title(Gtk.window(window), "Mediafin")
        gtk_window_set_default_size(Gtk.window(window), 820, 560)
        self.widget = window

        let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14)!
        gtk_container_set_border_width(Gtk.container(column), 20)
        gtk_container_add(Gtk.container(window), column)

        // Header: the name, and what the engine is doing right now.
        let header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)!
        gtk_box_pack_start(Gtk.box(header), Self.heading("Mediafin"), 0, 0, 0)
        statusBadge = Self.label("")
        gtk_box_pack_end(Gtk.box(header), statusBadge, 0, 0, 0)
        gtk_box_pack_start(Gtk.box(column), header, 0, 0, 0)

        gtk_box_pack_start(Gtk.box(column),
                           gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)!, 0, 0, 2)

        // Folders. A chooser rather than a text field: a path typed by hand is
        // the single most common way to point this at the wrong place.
        sourceChooser = Self.folderChooser("Ordner mit den neuen Dateien")
        moviesChooser = Self.folderChooser("Filmbibliothek")
        seriesChooser = Self.folderChooser("Serienbibliothek")
        gtk_box_pack_start(Gtk.box(column), Self.row("Quelle", sourceChooser), 0, 0, 0)
        gtk_box_pack_start(Gtk.box(column), Self.row("Filme", moviesChooser), 0, 0, 0)
        gtk_box_pack_start(Gtk.box(column), Self.row("Serien", seriesChooser), 0, 0, 0)

        let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let saveButton = gtk_button_new_with_label("Ordner übernehmen")!
        scanButton = gtk_button_new_with_label("Durchsuchen")!
        gtk_box_pack_start(Gtk.box(actions), saveButton, 0, 0, 0)
        gtk_box_pack_start(Gtk.box(actions), scanButton, 0, 0, 0)
        gtk_box_pack_start(Gtk.box(column), actions, 0, 0, 4)

        countsLabel = Self.label("")
        gtk_box_pack_start(Gtk.box(column), countsLabel, 0, 0, 0)
        resultLabel = Self.label("")
        gtk_label_set_line_wrap(Gtk.label(resultLabel), 1)
        gtk_box_pack_start(Gtk.box(column), resultLabel, 0, 0, 0)

        Gtk.onClick(saveButton, self) { $0.saveFolders() }
        Gtk.onClick(scanButton, self) { $0.scan() }

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

        let badge: String
        if state.hasError {
            badge = PangoMarkup.span("Mit Fehlern beendet", weight: "bold")
        } else if state.busy {
            let what = state.convertStatus ?? "Arbeitet"
            badge = PangoMarkup.span("\(what) \(state.activePercent) %", weight: "bold")
        } else {
            badge = PangoMarkup.span("Bereit", weight: "bold")
        }
        Gtk.setMarkup(statusBadge, badge)

        Gtk.setText(countsLabel,
                    "\(state.totalItems) Vorschläge · \(state.ready) bereit · "
                        + "\(state.done) umbenannt")
        Gtk.setText(resultLabel, state.lastResult ?? "")

        // Nothing to scan without a source folder, and a button that does
        // nothing is worse than one that is visibly unavailable.
        let hasSource = !coordinator.settings.sourceFolder.isEmpty
        gtk_widget_set_sensitive(scanButton, (hasSource && !state.busy) ? 1 : 0)
    }

    // MARK: Widgets

    private static func heading(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = gtk_label_new(nil)!
        gtk_label_set_markup(Gtk.label(label),
                             PangoMarkup.span(text, size: "xx-large", weight: "bold"))
        gtk_label_set_xalign(Gtk.label(label), 0)
        return label
    }

    private static func label(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = gtk_label_new(text)!
        gtk_label_set_xalign(Gtk.label(label), 0)
        return label
    }

    private static func folderChooser(_ title: String) -> UnsafeMutablePointer<GtkWidget> {
        gtk_file_chooser_button_new(title, GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER)!
    }

    /// A caption of fixed width beside its control, so the three rows line up
    /// without a grid.
    private static func row(_ caption: String,
                            _ control: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget> {
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10)!
        let text = label(caption)
        gtk_widget_set_size_request(text, 90, -1)
        gtk_box_pack_start(Gtk.box(row), text, 0, 0, 0)
        gtk_box_pack_start(Gtk.box(row), control, 1, 1, 0)
        return row
    }
}
