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
    private let modeCombo: UnsafeMutablePointer<GtkWidget>
    private let llmURLEntry: UnsafeMutablePointer<GtkWidget>
    private let llmModelEntry: UnsafeMutablePointer<GtkWidget>
    private let llmKeyEntry: UnsafeMutablePointer<GtkWidget>
    private let logColumn: UnsafeMutablePointer<GtkWidget>
    private let logCountLabel: UnsafeMutablePointer<GtkWidget>
    private let remoteEnabledCheck: UnsafeMutablePointer<GtkWidget>
    private let remoteHostEntry: UnsafeMutablePointer<GtkWidget>
    private let remotePortEntry: UnsafeMutablePointer<GtkWidget>
    private let remoteUserEntry: UnsafeMutablePointer<GtkWidget>
    private let remoteBaseEntry: UnsafeMutablePointer<GtkWidget>
    private let remoteIdentityEntry: UnsafeMutablePointer<GtkWidget>
    private let remotePasswordEntry: UnsafeMutablePointer<GtkWidget>
    private let remoteTransportCombo: UnsafeMutablePointer<GtkWidget>
    private let remoteAuthCombo: UnsafeMutablePointer<GtkWidget>
    private let remoteRemoveLocalCheck: UnsafeMutablePointer<GtkWidget>
    private let remoteProgress: UnsafeMutablePointer<GtkWidget>
    private let sendButton: UnsafeMutablePointer<GtkWidget>
    private let cancelSendButton: UnsafeMutablePointer<GtkWidget>
    private let checksColumn: UnsafeMutablePointer<GtkWidget>
    private let checksSummary: UnsafeMutablePointer<GtkWidget>

    /// The log rows on screen, so they can be replaced without walking the
    /// container.
    private var logWidgets: [UnsafeMutablePointer<GtkWidget>] = []
    /// What the log column was last built from. Optional so the first build
    /// happens even when there is nothing to show yet.
    private var renderedLogIDs: [UUID]?

    /// The lamps as last drawn, so an unchanged panel is left alone.
    private var renderedCheckSignature: [String]?
    private var checkWidgets: [UnsafeMutablePointer<GtkWidget>] = []

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

    /// - Parameter expandSettings: opens the identification section instead
    ///   of leaving it collapsed. Used by --demo, so the screenshot shows
    ///   those fields rendered rather than only proving they were built.
    init(coordinator: AppCoordinator, expandSettings: Bool = false) {
        self.coordinator = coordinator

        let window = gtk_window_new(GTK_WINDOW_TOPLEVEL)!
        gtk_window_set_default_size(Gtk.window(window), 1180, 680)
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

        // Work on the left, log on the right. The log is always there rather
        // than on a tab: a rename that failed is the thing you most need to
        // see, and a panel you have to go and find is a panel you look at
        // after wondering why nothing happened.
        let split = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_container_add(Gtk.container(window), split)

        let page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16)!
        gtk_container_set_border_width(Gtk.container(page), 18)
        gtk_box_pack_start(Gtk.box(split), page, 1, 1, 0)

        // MARK: The traffic light
        //
        // At the top, before the folders: the first question anyone has when
        // a run does nothing is "is everything plugged in", and a panel that
        // answers it below the fold is a panel nobody reads.
        let checks = Self.card(titled: "Status")
        checksSummary = Self.label("", classes: "mf-dim")
        Self.add(checksSummary, to: checks)
        checksColumn = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        Self.add(checksColumn, to: checks)
        let checkRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let checkButton = gtk_button_new_with_label("Alles prüfen")!
        gtk_box_pack_end(Gtk.box(checkRow), checkButton, 0, 0, 0)
        Self.add(checkRow, to: checks)
        gtk_box_pack_start(Gtk.box(page), checks, 0, 0, 0)

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

        // MARK: Identification
        //
        // Behind an expander, collapsed: it is set once and then never looked
        // at again, and leaving it open would take height away from the list,
        // which is what the window is actually for.
        modeCombo = gtk_combo_box_text_new()!
        for mode in IdentificationMode.allCases {
            gtk_combo_box_text_append_text(Gtk.comboBoxText(modeCombo), mode.label)
        }
        llmURLEntry = Self.entry(placeholder: "http://192.168.1.2:1234")
        llmModelEntry = Self.entry(placeholder: "qwen/qwen3-8b")
        // Never shown, never read back out of storage: the field stays empty
        // and its placeholder says whether a key is on file. Filling it in
        // from the secret store would put the key on screen and into any
        // screenshot of this window.
        llmKeyEntry = Self.entry(placeholder: "")
        gtk_entry_set_visibility(Gtk.entry(llmKeyEntry), 0)

        let detection = Self.card(titled: "Erkennung")
        Self.add(Self.row("Verfahren", modeCombo), to: detection)
        Self.add(Self.row("Server", llmURLEntry), to: detection)
        Self.add(Self.row("Modell", llmModelEntry), to: detection)
        Self.add(Self.row("API-Key", llmKeyEntry), to: detection)
        let testRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let testButton = gtk_button_new_with_label("Verbindung testen")!
        gtk_box_pack_end(Gtk.box(testRow), testButton, 0, 0, 0)
        Self.add(testRow, to: detection)

        let detectionExpander = gtk_expander_new("Erkennung und Modellserver")!
        gtk_expander_set_expanded(Gtk.expander(detectionExpander), expandSettings ? 1 : 0)
        gtk_container_add(Gtk.container(detectionExpander), detection)
        gtk_box_pack_start(Gtk.box(page), detectionExpander, 0, 0, 0)

        // MARK: The library on another machine
        //
        // Also behind an expander, for the same reason: it is configured once.
        // The progress bar lives in here rather than in the header, because
        // a transfer is the one job in this window that runs for minutes and
        // the question while it does is "how far", not "is it busy".
        remoteEnabledCheck = gtk_check_button_new_with_label(
            "Die Bibliothek liegt auf einem Server")!
        remoteHostEntry = Self.entry(placeholder: "nas.fritz.box")
        remotePortEntry = Self.entry(placeholder: "22")
        remoteUserEntry = Self.entry(placeholder: "benutzer")
        remoteBaseEntry = Self.entry(placeholder: "/volume1/Medien")
        remoteIdentityEntry = Self.entry(placeholder: "~/.ssh/id_ed25519 (leer = Standard)")
        // Write-only, like the model server's key: never filled in from
        // storage, so the password cannot end up in a screenshot.
        remotePasswordEntry = Self.entry(placeholder: "")
        gtk_entry_set_visibility(Gtk.entry(remotePasswordEntry), 0)
        remoteTransportCombo = gtk_combo_box_text_new()!
        for transport in RemoteTarget.Transport.allCases {
            gtk_combo_box_text_append_text(Gtk.comboBoxText(remoteTransportCombo),
                                           transport.label)
        }
        remoteAuthCombo = gtk_combo_box_text_new()!
        for auth in RemoteTarget.Authentication.allCases {
            gtk_combo_box_text_append_text(Gtk.comboBoxText(remoteAuthCombo), auth.label)
        }
        remoteRemoveLocalCheck = gtk_check_button_new_with_label(
            "Lokale Datei nach erfolgreicher Übertragung löschen")!

        let remote = Self.card(titled: "Server")
        Self.add(remoteEnabledCheck, to: remote)
        Self.add(Self.row("Adresse", remoteHostEntry), to: remote)
        Self.add(Self.row("Port", remotePortEntry), to: remote)
        Self.add(Self.row("Benutzer", remoteUserEntry), to: remote)
        Self.add(Self.row("Zielpfad", remoteBaseEntry), to: remote)
        Self.add(Self.row("Übertragung", remoteTransportCombo), to: remote)
        Self.add(Self.row("Anmeldung", remoteAuthCombo), to: remote)
        Self.add(Self.row("Schlüsseldatei", remoteIdentityEntry), to: remote)
        Self.add(Self.row("Passwort", remotePasswordEntry), to: remote)
        Self.add(remoteRemoveLocalCheck, to: remote)

        remoteProgress = gtk_progress_bar_new()!
        Self.add(remoteProgress, to: remote)

        let sendRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        sendButton = gtk_button_new_with_label("Zum Server senden")!
        cancelSendButton = gtk_button_new_with_label("Stopp")!
        gtk_box_pack_end(Gtk.box(sendRow), sendButton, 0, 0, 0)
        gtk_box_pack_end(Gtk.box(sendRow), cancelSendButton, 0, 0, 0)
        Self.add(sendRow, to: remote)

        let remoteExpander = gtk_expander_new("Server (rsync / SFTP)")!
        gtk_expander_set_expanded(Gtk.expander(remoteExpander), expandSettings ? 1 : 0)
        gtk_container_add(Gtk.container(remoteExpander), remote)
        gtk_box_pack_start(Gtk.box(page), remoteExpander, 0, 0, 0)

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

        // MARK: Log

        let logSide = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        Styling.style(logSide, "mf-log")
        gtk_widget_set_size_request(logSide, 320, -1)
        let logTitle = Self.label("VERLAUF", classes: "mf-card-title")
        gtk_box_pack_start(Gtk.box(logSide), logTitle, 0, 0, 0)
        logCountLabel = Self.label("", classes: "mf-dim")
        gtk_box_pack_start(Gtk.box(logSide), logCountLabel, 0, 0, 0)

        logColumn = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        let logScroller = gtk_scrolled_window_new(nil, nil)!
        gtk_scrolled_window_set_policy(Gtk.scrolledWindow(logScroller),
                                       GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_container_add(Gtk.container(logScroller), logColumn)
        gtk_box_pack_start(Gtk.box(logSide), logScroller, 1, 1, 0)
        gtk_box_pack_start(Gtk.box(split), logSide, 0, 0, 0)

        Gtk.onClick(saveButton, self) { $0.saveFolders() }
        Gtk.onClick(scanButton, self) { $0.scan() }
        Gtk.onClick(applyButton, self) { $0.applySelected() }
        Gtk.onClick(undoButton, self) { $0.undoLast() }
        Gtk.onClick(allButton, self) { $0.setAllChecked(true) }
        Gtk.onClick(noneButton, self) { $0.setAllChecked(false) }
        Gtk.onClick(testButton, self) { $0.testModelServer() }
        Gtk.onClick(sendButton, self) { $0.sendSelected() }
        Gtk.onClick(cancelSendButton, self) { $0.cancelSending() }
        Gtk.onClick(checkButton, self) { $0.checkEverything() }

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
        var settings = FolderSelection.applying(
            source: Gtk.chosenFolder(sourceChooser),
            movies: Gtk.chosenFolder(moviesChooser),
            series: Gtk.chosenFolder(seriesChooser),
            to: coordinator.settings
        )

        // Text boxes are taken at face value, unlike the folder choosers: an
        // empty box means the user emptied it, while an empty chooser may
        // only mean GTK could not display a path that no longer exists.
        settings.localLLMBaseURL =
            Gtk.text(of: llmURLEntry).trimmingCharacters(in: .whitespacesAndNewlines)
        settings.localLLMModel =
            Gtk.text(of: llmModelEntry).trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = Int(gtk_combo_box_get_active(Gtk.comboBox(modeCombo)))
        if mode >= 0, mode < IdentificationMode.allCases.count {
            settings.identification = IdentificationMode.allCases[mode]
        }
        settings.remote = readRemoteFields(from: settings.remote)
        coordinator.submit(.saveSettings(settings))

        // Only when something was typed. An empty field means "leave the
        // stored key alone", not "delete it" — otherwise saving a folder
        // would wipe a credential the user never touched.
        let key = Gtk.text(of: llmKeyEntry)
        if !key.isEmpty {
            coordinator.submit(.setSecret(.localLLMAPIKey, key))
            Gtk.setText(of: llmKeyEntry, "")
        }
        let serverPassword = Gtk.text(of: remotePasswordEntry)
        if !serverPassword.isEmpty {
            coordinator.submit(.setSecret(.remotePassword, serverPassword))
            // Cleared from the widget at once: it is in the secret store now,
            // and a password left in a field is a password on the screen.
            Gtk.setText(of: remotePasswordEntry, "")
        }
    }

    /// Reads the server fields, keeping anything the window cannot express.
    ///
    /// The port is the one field that can be typed wrong in a way worth
    /// catching here: an empty or non-numeric box keeps the stored port
    /// rather than quietly becoming 22, which would send the library to
    /// whatever answers there.
    private func readRemoteFields(from current: RemoteTarget) -> RemoteTarget {
        var target = current
        target.isEnabled = Gtk.isChecked(remoteEnabledCheck)
        target.removeLocalAfterSend = Gtk.isChecked(remoteRemoveLocalCheck)
        target.host = Gtk.text(of: remoteHostEntry).trimmingCharacters(in: .whitespaces)
        target.user = Gtk.text(of: remoteUserEntry).trimmingCharacters(in: .whitespaces)
        target.basePath = Gtk.text(of: remoteBaseEntry).trimmingCharacters(in: .whitespaces)
        target.identityFile =
            Gtk.text(of: remoteIdentityEntry).trimmingCharacters(in: .whitespaces)
        if let port = Int(Gtk.text(of: remotePortEntry).trimmingCharacters(in: .whitespaces)),
           (1...65535).contains(port) {
            target.port = port
        }
        let transport = Int(gtk_combo_box_get_active(Gtk.comboBox(remoteTransportCombo)))
        if transport >= 0, transport < RemoteTarget.Transport.allCases.count {
            target.transport = RemoteTarget.Transport.allCases[transport]
        }
        let auth = Int(gtk_combo_box_get_active(Gtk.comboBox(remoteAuthCombo)))
        if auth >= 0, auth < RemoteTarget.Authentication.allCases.count {
            target.authentication = RemoteTarget.Authentication.allCases[auth]
        }
        return target
    }

    /// Saves first, for the same reason scanning does: sending to an address
    /// that was typed but never saved would send to the old one.
    func sendSelected() {
        saveFolders()
        let ticked = rowChecks.filter { Gtk.isChecked($0.check) }.map(\.id)
        coordinator.submit(.transferFiles(accepting: Set(ticked)))
    }

    func cancelSending() {
        coordinator.submit(.cancelTransfers)
    }

    /// Saves first, so the lamps report on what is in the fields rather than
    /// on what was in them last time the user pressed Übernehmen.
    func checkEverything() {
        saveFolders()
        coordinator.submit(.checkEverything)
    }

    /// Saves first: testing an address the user typed but has not saved would
    /// report on the old one and look like the new one failed.
    func testModelServer() {
        saveFolders()
        coordinator.submit(.testLocalLLMConnection)
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

        Gtk.setText(of: llmURLEntry, settings.localLLMBaseURL)
        Gtk.setText(of: llmModelEntry, settings.localLLMModel)
        if let index = IdentificationMode.allCases.firstIndex(of: settings.identification) {
            gtk_combo_box_set_active(Gtk.comboBox(modeCombo), Int32(index))
        }
        // The key itself is never loaded — only whether there is one.
        let stored = coordinator.configuredSecrets.contains(.localLLMAPIKey)
        gtk_entry_set_placeholder_text(
            Gtk.entry(llmKeyEntry),
            stored ? "gespeichert — zum Ersetzen neu eingeben" : "keiner hinterlegt"
        )

        let remote = settings.remote
        Gtk.setChecked(remoteEnabledCheck, remote.isEnabled)
        Gtk.setChecked(remoteRemoveLocalCheck, remote.removeLocalAfterSend)
        Gtk.setText(of: remoteHostEntry, remote.host)
        Gtk.setText(of: remoteUserEntry, remote.user)
        Gtk.setText(of: remoteBaseEntry, remote.basePath)
        Gtk.setText(of: remoteIdentityEntry, remote.identityFile)
        Gtk.setText(of: remotePortEntry, String(remote.port))
        if let index = RemoteTarget.Transport.allCases.firstIndex(of: remote.transport) {
            gtk_combo_box_set_active(Gtk.comboBox(remoteTransportCombo), Int32(index))
        }
        if let index = RemoteTarget.Authentication.allCases
            .firstIndex(of: remote.authentication) {
            gtk_combo_box_set_active(Gtk.comboBox(remoteAuthCombo), Int32(index))
        }
        // As with the model key: whether one is stored, never the password.
        let hasPassword = coordinator.configuredSecrets.contains(.remotePassword)
        gtk_entry_set_placeholder_text(
            Gtk.entry(remotePasswordEntry),
            hasPassword ? "gespeichert — zum Ersetzen neu eingeben" : "keines hinterlegt"
        )
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

        // Sending needs somewhere to send to and something to send; stopping
        // needs something to stop. A button that would answer "nothing is
        // configured" is better off visibly unavailable.
        gtk_widget_set_sensitive(
            sendButton,
            (state.remoteConfigured && !rowChecks.isEmpty && !state.busy) ? 1 : 0)
        gtk_widget_set_sensitive(cancelSendButton, state.transferring ? 1 : 0)
        Gtk.setProgress(remoteProgress,
                        fraction: state.transferProgress,
                        text: state.transferSummary)

        refreshList()
        refreshLog()
        refreshChecks()
    }

    /// Rebuilds the traffic light, and only when a lamp actually changed.
    ///
    /// This runs twice a second; rebuilding every time would make the panel
    /// flicker and would fight anyone trying to read a long detail line.
    private func refreshChecks() {
        let checks = coordinator.systemChecks
        let signature = checks.map { "\($0.id)|\($0.state.rawValue)|\($0.detail)" }
        guard signature != renderedCheckSignature else { return }
        renderedCheckSignature = signature

        for row in checkWidgets { gtk_widget_destroy(row) }
        checkWidgets = []

        Gtk.setText(checksSummary, SystemChecks.summary(checks))
        for check in checks {
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
            // A dot and a word. Colour alone would leave the panel unreadable
            // for anyone who cannot tell the red lamp from the green one.
            let lamp = Self.label("\u{25CF}", classes: "mf-lamp",
                                  Self.lampClass(check.state))
            gtk_widget_set_size_request(lamp, 16, -1)
            gtk_box_pack_start(Gtk.box(row), lamp, 0, 0, 0)

            let name = Self.label(check.name, classes: "mf-lamp-name")
            gtk_widget_set_size_request(name, 150, -1)
            gtk_box_pack_start(Gtk.box(row), name, 0, 0, 0)

            let detail = Self.label(check.detail, classes: "mf-dim")
            gtk_label_set_line_wrap(Gtk.label(detail), 1)
            gtk_box_pack_start(Gtk.box(row), detail, 1, 1, 0)

            gtk_box_pack_start(Gtk.box(checksColumn), row, 0, 0, 0)
            gtk_widget_show_all(row)
            checkWidgets.append(row)
        }
    }

    private static func lampClass(_ state: SystemCheck.State) -> String {
        switch state {
        case .ok: return "mf-ok"
        case .warning: return "mf-warn"
        case .failed: return "mf-fail"
        case .off: return "mf-skip"
        }
    }

    /// Rebuilds the log column, newest first, and only when it changed.
    ///
    /// Newest first because the reason to look here is almost always "what
    /// just happened", and a column that grows downwards would put that
    /// answer off the bottom of the screen after a long run.
    private func refreshLog() {
        // Reversed once here rather than everywhere below.
        let entries = Array(coordinator.logEntries.reversed().prefix(Self.visibleLogEntries))
        let ids = entries.map(\.id)
        guard ids != renderedLogIDs else { return }
        renderedLogIDs = ids

        for row in logWidgets { gtk_widget_destroy(row) }
        logWidgets = []

        let total = coordinator.logEntries.count
        let failures = coordinator.logEntries.filter { $0.status == .failure }.count
        Gtk.setText(logCountLabel, failures > 0
            ? "\(total) Einträge · \(failures) mit Fehler"
            : "\(total) Einträge")

        if entries.isEmpty {
            let empty = Self.label("Noch nichts passiert.", classes: "mf-dim")
            gtk_box_pack_start(Gtk.box(logColumn), empty, 0, 0, 0)
            logWidgets = [empty]
        } else {
            for entry in entries {
                let row = Self.logRow(entry)
                gtk_box_pack_start(Gtk.box(logColumn), row, 0, 0, 0)
                logWidgets.append(row)
            }
        }
        gtk_widget_show_all(logColumn)
    }

    /// How much of the log the column holds.
    ///
    /// Capped because each entry is three widgets and a long history would
    /// cost more to rebuild than it is worth looking at. The full record
    /// stays on disk and in the web interface's history page.
    static let visibleLogEntries = 200

    private static func logRow(_ entry: RenameLogEntry)
        -> UnsafeMutablePointer<GtkWidget> {
        let row = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1)!
        Styling.style(row, "mf-log-entry")

        let time = label(Self.logTime.string(from: entry.date) + " · " + statusWord(entry.status),
                         classes: "mf-log-time", statusClass(entry.status))
        gtk_box_pack_start(Gtk.box(row), time, 0, 0, 0)

        // The new name, or the old one when there is no new one to show.
        let name = label(entry.newName.isEmpty ? entry.oldName : entry.newName)
        gtk_label_set_ellipsize(Gtk.label(name), PANGO_ELLIPSIZE_MIDDLE)
        Styling.style(name, "mf-log-entry")
        gtk_box_pack_start(Gtk.box(row), name, 0, 0, 0)

        // The whole reason this column is always visible.
        if let error = entry.errorDescription, !error.isEmpty {
            let message = label(error, classes: "mf-log-entry", "mf-fail")
            gtk_label_set_line_wrap(Gtk.label(message), 1)
            gtk_box_pack_start(Gtk.box(row), message, 0, 0, 0)
        }
        return row
    }

    private static let logTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func statusWord(_ status: RenameLogEntry.Status) -> String {
        switch status {
        case .success: return "umbenannt"
        case .failure: return "fehlgeschlagen"
        case .skipped: return "übersprungen"
        case .converted: return "konvertiert"
        case .sent: return "gesendet"
        }
    }

    private static func statusClass(_ status: RenameLogEntry.Status) -> String {
        switch status {
        case .success, .converted, .sent: return "mf-ok"
        case .failure: return "mf-fail"
        case .skipped: return "mf-skip"
        }
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

    private static func entry(placeholder: String) -> UnsafeMutablePointer<GtkWidget> {
        let field = gtk_entry_new()!
        if !placeholder.isEmpty {
            gtk_entry_set_placeholder_text(Gtk.entry(field), placeholder)
        }
        return field
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
