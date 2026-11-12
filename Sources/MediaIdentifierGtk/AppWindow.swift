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
    private let musicChooser: UnsafeMutablePointer<GtkWidget>
    private let libraryModeCombo: UnsafeMutablePointer<GtkWidget>
    private let languageCombo: UnsafeMutablePointer<GtkWidget>
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
    private let remoteMoviesPathEntry: UnsafeMutablePointer<GtkWidget>
    private let remoteSeriesPathEntry: UnsafeMutablePointer<GtkWidget>
    private let remoteMusicPathEntry: UnsafeMutablePointer<GtkWidget>
    private let remoteIdentityEntry: UnsafeMutablePointer<GtkWidget>
    private let remotePasswordEntry: UnsafeMutablePointer<GtkWidget>
    private let remoteTransportCombo: UnsafeMutablePointer<GtkWidget>
    private let remoteAuthCombo: UnsafeMutablePointer<GtkWidget>
    private let remoteTrustCheck: UnsafeMutablePointer<GtkWidget>
    private let remoteRemoveLocalCheck: UnsafeMutablePointer<GtkWidget>
    private let remoteProgress: UnsafeMutablePointer<GtkWidget>
    private let sendButton: UnsafeMutablePointer<GtkWidget>
    private let cancelSendButton: UnsafeMutablePointer<GtkWidget>
    private let urlEntry: UnsafeMutablePointer<GtkWidget>
    private let downloadButton: UnsafeMutablePointer<GtkWidget>
    private let cancelDownloadButton: UnsafeMutablePointer<GtkWidget>
    private let downloadProgress: UnsafeMutablePointer<GtkWidget>
    private let scheduleCheck: UnsafeMutablePointer<GtkWidget>
    private let scheduleCadenceCombo: UnsafeMutablePointer<GtkWidget>
    private let scheduleTimeEntry: UnsafeMutablePointer<GtkWidget>
    private let scheduleHoursEntry: UnsafeMutablePointer<GtkWidget>
    private let scheduleRenameCheck: UnsafeMutablePointer<GtkWidget>
    private let scheduleSendCheck: UnsafeMutablePointer<GtkWidget>
    private let scheduleSummary: UnsafeMutablePointer<GtkWidget>
    private let checksColumn: UnsafeMutablePointer<GtkWidget>
    private let checksExpander: UnsafeMutablePointer<GtkWidget>
    /// Settings, status and fetching live in windows of their own, opened from
    /// the header's menu.
    ///
    /// They used to be six cards stacked above the proposals on the main
    /// surface. That made the main surface a form with a list at the bottom,
    /// and it made "are these options even working, did that save" a fair
    /// question: a settings form you are looking at all the time looks like
    /// it should be live, and this one is not -- it is read when Apply is
    /// pressed. Behind a menu, opened deliberately, with one Apply button and
    /// a timestamp, it stops pretending.
    private let settingsDialog: UnsafeMutablePointer<GtkWidget>
    private let statusDialog: UnsafeMutablePointer<GtkWidget>
    private let fetchDialog: UnsafeMutablePointer<GtkWidget>
    /// The traffic light, in the bar at the bottom: a coloured dot and one
    /// line, always visible.
    ///
    /// It lived behind the menu, which answers "what is wrong" only once you
    /// have thought to go and look. The first question anyone has when a run
    /// does nothing is whether everything is plugged in, and a panel that has
    /// to be opened to answer it is a panel nobody opens.
    private let lampDot: UnsafeMutablePointer<GtkWidget>
    private let lampText: UnsafeMutablePointer<GtkWidget>
    /// What the bar last said, so an unchanged bar is left alone rather than
    /// rewritten twice a second.
    private var lampShown: (state: SystemCheck.State, text: String)?

    /// Says when the settings were last taken, with the time of day.
    ///
    /// The time is the point. "Saved." appearing where "Saved." already was
    /// is indistinguishable from nothing happening, which is exactly what was
    /// reported. A clock that moves proves the press landed.
    private let savedLabel: UnsafeMutablePointer<GtkWidget>

    /// The log rows on screen, so they can be replaced without walking the
    /// container.
    private var logWidgets: [UnsafeMutablePointer<GtkWidget>] = []
    /// What the log column was last built from. Optional so the first build
    /// happens even when there is nothing to show yet.
    private var renderedLogIDs: [UUID]?

    /// The lamps as last drawn, so an unchanged panel is left alone.
    private var renderedCheckSignature: [String]?
    /// So the panel opens itself once when something breaks, and then leaves
    /// the user's choice alone.
    private var hasOpenedChecksOnFailure = false

    /// The settings the widgets were filled from.
    ///
    /// Saving writes back only the fields whose widget differs from this.
    /// Both front-ends share one configuration file, so without it the
    /// window — which reads the settings once, at startup — would write its
    /// hours-old copy back over whatever the web interface had changed in
    /// the meantime. That includes switching "delete the local file after
    /// sending" back on.
    private var loadedSettings = WebSettings()
    private var checkWidgets: [UnsafeMutablePointer<GtkWidget>] = []

    /// The rows currently on screen, kept so they can be destroyed without
    /// walking the container — which would mean another C callback.
    private var rowWidgets: [UnsafeMutablePointer<GtkWidget>] = []
    /// The "→ …" label of each row, so what the window really says about
    /// where a file is going can be read back rather than assumed.
    private var rowDestinations: [UnsafeMutablePointer<GtkWidget>] = []
    /// The second line of the empty list, kept so what just happened can be
    /// said in the middle of the window rather than only in the footer.
    ///
    /// The footer line is small, dim and at the bottom edge. Pressing Scan
    /// with no import folder set put the answer there and nowhere else, and
    /// "it does nothing, no status, nothing at all" is what that looks like
    /// from a chair in front of it. The answer belongs where the eye is.
    private var emptyDetail: UnsafeMutablePointer<GtkWidget>?
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

    /// Tracked rather than read back from the window: `gdk_window_get_state`
    /// needs the window realized and is a frame behind after a toggle.
    private var isFullscreen = false

    /// GDK_KEY_F11 and GDK_KEY_Escape. Written out because they are macros,
    /// which Swift does not import from a C header.
    static let keyF11: UInt32 = 0xFFC8
    static let keyEscape: UInt32 = 0xFF1B

    /// - Parameter expandSettings: opens the identification section instead
    ///   of leaving it collapsed. Used by --demo, so the screenshot shows
    ///   those fields rendered rather than only proving they were built.
    init(coordinator: AppCoordinator, expandSettings: Bool = false) {
        self.coordinator = coordinator

        let window = gtk_window_new(GTK_WINDOW_TOPLEVEL)!
        let opening = Self.openingSize()
        gtk_window_set_default_size(Gtk.window(window), opening.width, opening.height)
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
        scanButton = gtk_button_new_with_label(Text.s("Durchsuchen", "Scan"))!
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

        let page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
        gtk_container_set_border_width(Gtk.container(page), 12)
        // Where the settings cards go. Built here so the construction below
        // can pack into it exactly as it used to pack into the page; the
        // dialog that holds it is assembled at the end of this initialiser.
        let settingsPage = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
        gtk_container_set_border_width(Gtk.container(settingsPage), 12)
        let statusPage = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
        gtk_container_set_border_width(Gtk.container(statusPage), 12)
        let fetchPage = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
        gtk_container_set_border_width(Gtk.container(fetchPage), 12)
        // The whole left column scrolls, and this is the fix for the bug it
        // shipped with: a GtkWindow cannot be made shorter than its content's
        // minimum height, and this column's minimum was about a thousand
        // pixels — six cards, each with its own padding. On a 1366×768
        // laptop the window opened taller than the screen, so the row with
        // ‚Umbenennen‘ and ‚Rückgängig‘ on it, and the footer under that,
        // were off the bottom edge and could not be reached by resizing,
        // maximising or going fullscreen — there was nothing to resize to.
        // A scrolled window asks for almost no height of its own, so the
        // window shrinks to whatever screen it is on and the bottom is always
        // one scroll away.
        let pageScroller = gtk_scrolled_window_new(nil, nil)!
        gtk_scrolled_window_set_policy(Gtk.scrolledWindow(pageScroller),
                                       GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        // Horizontal policy NEVER propagates the column's minimum width, so
        // the controls are never squeezed sideways; only the height gives.
        gtk_scrolled_window_set_min_content_height(Gtk.scrolledWindow(pageScroller), 160)
        gtk_container_add(Gtk.container(pageScroller), page)
        gtk_box_pack_start(Gtk.box(split), pageScroller, 1, 1, 0)

        // MARK: The traffic light
        //
        // At the top, before the folders: the first question anyone has when
        // a run does nothing is "is everything plugged in", and a panel that
        // answers it below the fold is a panel nobody reads.
        // No title and no summary line of its own: the expander's label
        // already carries both, and in a window this is only ever seen
        // opened, with that label directly above it. It read
        // "Status - 4 bereit" and then "STATUS / 4 bereit" again, two lines
        // under the first.
        let checks = Self.card()
        checksColumn = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        Self.add(checksColumn, to: checks)
        let checkRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let checkButton = gtk_button_new_with_label(Text.s("Alles prüfen", "Check everything"))!
        gtk_box_pack_end(Gtk.box(checkRow), checkButton, 0, 0, 0)
        Self.add(checkRow, to: checks)
        // Behind an expander, with the summary on the expander's own label.
        // Seven rows of detail cost about 300 pixels, and the list of
        // proposals — which is what the window is for — was being squeezed
        // to a row and a half to pay for them. Collapsed, the panel still
        // answers "is everything plugged in" in one line; opened, it says
        // which lamp and why.
        checksExpander = gtk_expander_new(Text.s("Status", "Status"))!
        gtk_expander_set_expanded(Gtk.expander(checksExpander), 1)
        gtk_container_add(Gtk.container(checksExpander), checks)
        gtk_box_pack_start(Gtk.box(statusPage), checksExpander, 1, 1, 0)

        // MARK: Fetching from a link
        //
        // Above the folders because this is where a file comes from; what
        // happens to it afterwards is the rest of the window.
        urlEntry = Self.entry(placeholder: "https://…")
        downloadButton = gtk_button_new_with_label(Text.s("Laden", "Fetch"))!
        cancelDownloadButton = gtk_button_new_with_label(Text.s("Stopp", "Stop"))!
        downloadProgress = gtk_progress_bar_new()!

        let fetch = Self.card(titled: Text.s("Aus dem Netz laden", "Fetch from a link"))
        let urlRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_pack_start(Gtk.box(urlRow), urlEntry, 1, 1, 0)
        gtk_box_pack_start(Gtk.box(urlRow), downloadButton, 0, 0, 0)
        gtk_box_pack_start(Gtk.box(urlRow), cancelDownloadButton, 0, 0, 0)
        Self.add(urlRow, to: fetch)
        Self.add(downloadProgress, to: fetch)
        Self.add(Self.label(Text.s(
                    "Landet im Importordner und wird dann wie jede andere gefundene "
                        + "Datei vorgeschlagen.",
                    "Lands in the import folder and is then proposed like any other "
                        + "file found there."), classes: "mf-dim"),
                 to: fetch)
        gtk_box_pack_start(Gtk.box(fetchPage), fetch, 0, 0, 0)

        // MARK: Folders

        sourceChooser = Self.folderChooser(Text.s("Ordner mit den neuen Dateien",
                                                  "Folder the new files land in"))
        moviesChooser = Self.folderChooser(Text.s("Filmbibliothek", "Film library"))
        seriesChooser = Self.folderChooser(Text.s("Serienbibliothek", "Series library"))

        musicChooser = Self.folderChooser(Text.s("Musikbibliothek", "Music library"))
        libraryModeCombo = gtk_combo_box_text_new()!
        for mode in LibraryMode.allCases {
            gtk_combo_box_text_append_text(Gtk.comboBoxText(libraryModeCombo), mode.label)
        }

        // Each language names itself in itself: somebody who has landed in
        // the wrong one cannot read the other one's word for it. The first
        // entry follows the machine's locale, which is a choice of its own
        // and has to be choosable again after a language has been picked.
        languageCombo = gtk_combo_box_text_new()!
        gtk_combo_box_text_append_text(Gtk.comboBoxText(languageCombo),
                                       Text.s("Wie das System", "Follow the system"))
        for language in Language.allCases {
            gtk_combo_box_text_append_text(Gtk.comboBoxText(languageCombo), language.label)
        }

        let folders = Self.card(titled: Text.s("Bibliothek", "Library"))
        Self.add(Self.row(Text.s("Sprache", "Language"), languageCombo), to: folders)
        Self.add(Self.row(Text.s("Sortiert", "Sorting"), libraryModeCombo), to: folders)
        Self.add(Self.row(Text.s("Quelle", "Source"), sourceChooser), to: folders)
        Self.add(Self.row(Text.s("Filme", "Films"), moviesChooser), to: folders)
        Self.add(Self.row(Text.s("Serien", "Series"), seriesChooser), to: folders)
        Self.add(Self.row(Text.s("Musik", "Music"), musicChooser), to: folders)

        gtk_box_pack_start(Gtk.box(settingsPage), folders, 0, 0, 0)

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

        let detection = Self.card(titled: Text.s("Erkennung", "Identification"))
        Self.add(Self.row(Text.s("Verfahren", "Method"), modeCombo), to: detection)
        Self.add(Self.row(Text.s("Server", "Server"), llmURLEntry), to: detection)
        Self.add(Self.row(Text.s("Modell", "Model"), llmModelEntry), to: detection)
        Self.add(Self.row(Text.s("API-Key", "API key"), llmKeyEntry), to: detection)
        let testRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let testButton = gtk_button_new_with_label(Text.s("Verbindung testen", "Test the connection"))!
        gtk_box_pack_end(Gtk.box(testRow), testButton, 0, 0, 0)
        Self.add(testRow, to: detection)

        let detectionExpander = gtk_expander_new(
            Text.s("Erkennung und Modellserver", "Identification and model server"))!
        gtk_expander_set_expanded(Gtk.expander(detectionExpander), 1)
        gtk_container_add(Gtk.container(detectionExpander), detection)
        gtk_box_pack_start(Gtk.box(settingsPage), detectionExpander, 0, 0, 0)

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
        remoteUserEntry = Self.entry(placeholder: Text.s("benutzer", "user"))
        remoteBaseEntry = Self.entry(placeholder: "/volume1/Medien")
        // One path per kind: a server rarely keeps films, series and music
        // under one parent, and the single path above cannot say so.
        remoteMoviesPathEntry = Self.entry(
            placeholder: Text.s("leer = Zielpfad", "empty = target path"))
        remoteSeriesPathEntry = Self.entry(
            placeholder: Text.s("leer = Zielpfad", "empty = target path"))
        remoteMusicPathEntry = Self.entry(
            placeholder: Text.s("leer = Zielpfad", "empty = target path"))
        remoteIdentityEntry = Self.entry(placeholder: Text.s("~/.ssh/id_ed25519 (leer = Standard)",
                                       "~/.ssh/id_ed25519 (empty = default)"))
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
        remoteTrustCheck = gtk_check_button_new_with_label(
            Text.s("Dem Server beim ersten Mal vertrauen (geänderter Schlüssel bleibt abgelehnt)",
                   "Trust this server the first time (a changed key is still refused)"))!
        remoteRemoveLocalCheck = gtk_check_button_new_with_label(
            Text.s("Lokale Datei nach erfolgreicher Übertragung löschen",
                   "Delete the local file after a successful transfer"))!

        let remote = Self.card(titled: Text.s("Server", "Server"))
        Self.add(remoteEnabledCheck, to: remote)
        Self.add(Self.row(Text.s("Adresse", "Address"), remoteHostEntry), to: remote)
        Self.add(Self.row(Text.s("Port", "Port"), remotePortEntry), to: remote)
        Self.add(Self.row(Text.s("Benutzer", "User"), remoteUserEntry), to: remote)
        Self.add(Self.row(Text.s("Zielpfad", "Target path"), remoteBaseEntry), to: remote)
        Self.add(Self.row(Text.s("Nur Filme", "Films only"), remoteMoviesPathEntry),
                 to: remote)
        Self.add(Self.row(Text.s("Nur Serien", "Series only"), remoteSeriesPathEntry),
                 to: remote)
        Self.add(Self.row(Text.s("Nur Musik", "Music only"), remoteMusicPathEntry),
                 to: remote)
        Self.add(Self.row(Text.s("Übertragung", "Transfer"), remoteTransportCombo), to: remote)
        Self.add(Self.row(Text.s("Anmeldung", "Login"), remoteAuthCombo), to: remote)
        Self.add(Self.row(Text.s("Schlüsseldatei", "Key file"), remoteIdentityEntry), to: remote)
        Self.add(Self.row(Text.s("Passwort", "Password"), remotePasswordEntry), to: remote)
        Self.add(remoteTrustCheck, to: remote)
        Self.add(remoteRemoveLocalCheck, to: remote)

        remoteProgress = gtk_progress_bar_new()!
        Self.add(remoteProgress, to: remote)

        let sendRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        // Testing the server on its own, rather than only as part of
        // "Alles prüfen": this is the one the user presses while they are
        // still getting the address and the key right.
        let testServerButton = gtk_button_new_with_label(Text.s("Server testen", "Test the server"))!
        gtk_box_pack_start(Gtk.box(sendRow), testServerButton, 0, 0, 0)
        sendButton = gtk_button_new_with_label(Text.s("Zum Server senden", "Send to the server"))!
        cancelSendButton = gtk_button_new_with_label(Text.s("Stopp", "Stop"))!
        gtk_box_pack_end(Gtk.box(sendRow), sendButton, 0, 0, 0)
        gtk_box_pack_end(Gtk.box(sendRow), cancelSendButton, 0, 0, 0)
        Self.add(sendRow, to: remote)

        // MARK: Looking by itself

        scheduleCheck = gtk_check_button_new_with_label(Text.s("Von selbst nachsehen", "Look by itself"))!
        scheduleCadenceCombo = gtk_combo_box_text_new()!
        for cadence in Schedule.Cadence.allCases {
            gtk_combo_box_text_append_text(Gtk.comboBoxText(scheduleCadenceCombo),
                                           cadence.label)
        }
        scheduleTimeEntry = Self.entry(placeholder: "03:00")
        scheduleHoursEntry = Self.entry(placeholder: "6")
        scheduleRenameCheck = gtk_check_button_new_with_label(
            Text.s("Dabei auch umbenennen", "Rename what it finds"))!
        scheduleSendCheck = gtk_check_button_new_with_label(
            Text.s("Dabei auch zum Server senden", "Also send to the server"))!
        scheduleSummary = Self.label("", classes: "mf-dim")
        gtk_label_set_line_wrap(Gtk.label(scheduleSummary), 1)

        let scheduleCard = Self.card(titled: Text.s("Zeitplan", "Schedule"))
        Self.add(scheduleCheck, to: scheduleCard)
        Self.add(Self.row(Text.s("Wann", "When"), scheduleCadenceCombo), to: scheduleCard)
        Self.add(Self.row(Text.s("Uhrzeit", "Time"), scheduleTimeEntry), to: scheduleCard)
        Self.add(Self.row(Text.s("Abstand (h)", "Interval (h)"), scheduleHoursEntry), to: scheduleCard)
        Self.add(scheduleRenameCheck, to: scheduleCard)
        Self.add(scheduleSendCheck, to: scheduleCard)
        Self.add(scheduleSummary, to: scheduleCard)

        let scheduleExpander = gtk_expander_new(Text.s("Zeitplan", "Schedule"))!
        gtk_expander_set_expanded(Gtk.expander(scheduleExpander), 1)
        gtk_container_add(Gtk.container(scheduleExpander), scheduleCard)
        gtk_box_pack_start(Gtk.box(settingsPage), scheduleExpander, 0, 0, 0)

        let remoteExpander = gtk_expander_new(
            Text.s("Server (rsync / SFTP)", "Server (rsync / SFTP)"))!
        gtk_expander_set_expanded(Gtk.expander(remoteExpander), 1)
        gtk_container_add(Gtk.container(remoteExpander), remote)
        gtk_box_pack_start(Gtk.box(settingsPage), remoteExpander, 0, 0, 0)

        // MARK: Proposals

        let proposals = Self.card(titled: Text.s("Vorschläge", "Proposals"))
        countsLabel = Self.label("", classes: "mf-dim")
        Self.add(countsLabel, to: proposals)

        // A plain box inside a scroller rather than a GtkTreeView: a tree
        // model needs GValue boxing and cell renderers, which is a lot of C
        // surface to get wrong for a list that only has to be read. It will
        // have to become a TreeView if these lists reach the thousands.
        listColumn = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1)!
        // Directly in the card, with no scroller of its own. It used to have
        // one, with a 260-pixel floor so the cards above could not squeeze
        // the list to a single row — but that floor was a large part of why
        // the window could not fit a small screen, and a scroller inside the
        // scrolling column would mean two scrollbars fighting over one wheel.
        // The list now grows and the column scrolls.
        Self.add(listColumn, to: proposals, expand: true)

        // Selecting on the left, acting on the right: the destructive end of
        // the row is the one that should take a deliberate reach.
        let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let allButton = gtk_button_new_with_label(Text.s("Alle", "All"))!
        let noneButton = gtk_button_new_with_label(Text.s("Keine", "None"))!
        gtk_box_pack_start(Gtk.box(actions), allButton, 0, 0, 0)
        gtk_box_pack_start(Gtk.box(actions), noneButton, 0, 0, 0)
        undoButton = gtk_button_new_with_label(Text.s("Rückgängig", "Undo"))!
        applyButton = gtk_button_new_with_label(Text.s("Umbenennen", "Rename"))!
        Styling.style(applyButton, "suggested-action")
        gtk_box_pack_end(Gtk.box(actions), applyButton, 0, 0, 0)
        gtk_box_pack_end(Gtk.box(actions), undoButton, 0, 0, 0)
        Self.add(actions, to: proposals)

        gtk_box_pack_start(Gtk.box(page), proposals, 1, 1, 0)

        // Footer, left to right: the traffic light, what just happened, and
        // the version. The version is there so a bug report can name one.
        //
        // The traffic light is first because it is the standing answer -- "is
        // everything plugged in" -- while the message beside it is whatever
        // happened a moment ago. Both at a glance, neither needing a click.
        let footer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)!

        // A button, not a label: the one line says how many lamps are amber,
        // and the obvious next question is which. Flat, so the bar still
        // reads as a bar.
        let lampButton = gtk_button_new()!
        gtk_button_set_relief(Gtk.button(lampButton), GTK_RELIEF_NONE)
        gtk_widget_set_tooltip_text(
            lampButton, Text.s("Status öffnen", "Open the status panel"))
        let lampRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        lampDot = Self.label("\u{25CF}", classes: "mf-lamp", "mf-skip")
        lampText = Self.label("", classes: "mf-dim")
        gtk_box_pack_start(Gtk.box(lampRow), lampDot, 0, 0, 0)
        gtk_box_pack_start(Gtk.box(lampRow), lampText, 0, 0, 0)
        gtk_container_add(Gtk.container(lampButton), lampRow)
        gtk_box_pack_start(Gtk.box(footer), lampButton, 0, 0, 0)

        resultLabel = Self.label("", classes: "mf-dim")
        gtk_label_set_line_wrap(Gtk.label(resultLabel), 1)
        gtk_label_set_xalign(Gtk.label(resultLabel), 0)
        gtk_box_pack_start(Gtk.box(footer), resultLabel, 1, 1, 0)
        let version = Self.label(MediafinVersion.display, classes: "mf-dim")
        gtk_label_set_xalign(Gtk.label(version), 1)
        gtk_box_pack_end(Gtk.box(footer), version, 0, 0, 0)
        gtk_box_pack_start(Gtk.box(page), footer, 0, 0, 0)

        // MARK: Log

        let logSide = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        Styling.style(logSide, "mf-log")
        gtk_widget_set_size_request(logSide, 264, -1)
        let logTitle = Self.label(Text.s("VERLAUF", "HISTORY"), classes: "mf-card-title")
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

        // MARK: The three windows behind the menu

        // One Apply for the whole dialog, at the bottom where a dialog's
        // buttons belong. It used to sit inside the Library card, which read
        // as though it applied to that card and left the three sections below
        // it looking like they saved themselves. They never did: Apply reads
        // every field in the dialog, and always has.
        savedLabel = Self.label("", classes: "mf-dim")
        gtk_label_set_xalign(Gtk.label(savedLabel), 0)
        let saveRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let saveButton = gtk_button_new_with_label(Text.s("Übernehmen", "Apply"))!
        Styling.style(saveButton, "suggested-action")
        gtk_box_pack_start(Gtk.box(saveRow), savedLabel, 1, 1, 0)
        gtk_box_pack_end(Gtk.box(saveRow), saveButton, 0, 0, 0)
        gtk_box_pack_end(Gtk.box(settingsPage), saveRow, 0, 0, 0)

        settingsDialog = Self.panel(Text.s("Einstellungen", "Settings"),
                                    holding: settingsPage, over: window)
        statusDialog = Self.panel(Text.s("Status", "Status"),
                                  holding: statusPage, over: window)
        fetchDialog = Self.panel(Text.s("Aus dem Netz laden", "Fetch from a link"),
                                 holding: fetchPage, over: window)

        // A menu in the header, which is where a GTK application keeps the
        // things it is not doing right now -- the same place a Mac keeps
        // them. The main surface is then the list and nothing else.
        let menuButton = gtk_button_new_from_icon_name("open-menu-symbolic",
                                                       GTK_ICON_SIZE_BUTTON)!
        gtk_widget_set_tooltip_text(menuButton, Text.s("Menü", "Menu"))
        gtk_header_bar_pack_start(Gtk.headerBar(header), menuButton)

        Gtk.onClick(saveButton, self) { $0.saveFolders() }
        Gtk.onClick(menuButton, self) { $0.showMenu() }
        Gtk.onClick(lampButton, self) { $0.open($0.statusDialog) }
        Gtk.onClick(scanButton, self) { $0.scan() }
        Gtk.onClick(applyButton, self) { $0.applySelected() }
        Gtk.onClick(undoButton, self) { $0.undoLast() }
        Gtk.onClick(allButton, self) { $0.setAllChecked(true) }
        Gtk.onClick(noneButton, self) { $0.setAllChecked(false) }
        Gtk.onClick(testButton, self) { $0.testModelServer() }
        Gtk.onClick(sendButton, self) { $0.sendSelected() }
        Gtk.onClick(cancelSendButton, self) { $0.cancelSending() }
        Gtk.onClick(checkButton, self) { $0.checkEverything() }
        Gtk.onClick(testServerButton, self) { $0.testServer() }
        Gtk.onClick(downloadButton, self) { $0.startDownload() }
        Gtk.onClick(cancelDownloadButton, self) { $0.cancelDownload() }

        // On the whole window rather than on the list: a GtkBox has no window
        // of its own, so a drop target on it is at the mercy of how GTK
        // happens to route the event, while a toplevel certainly has one.
        // Being able to let go anywhere is also the more forgiving target --
        // and a text entry that wants the drop for itself still gets it,
        // because GTK offers it to the innermost widget first. Dropping a
        // folder on the import-folder field therefore fills the field in,
        // which is what someone aiming there meant.
        Gtk.onFilesDropped(window, self) { $0.addDropped($1) }

        // F11 toggles fullscreen and Escape leaves it — the two keys anyone
        // tries. Every other key is passed on untouched, so typing Escape in
        // a text entry still does what the entry expects.
        Gtk.onKeyPress(window, self) { window, key in
            switch key {
            case Self.keyF11: window.toggleFullscreen(); return true
            case Self.keyEscape where window.isFullscreen:
                window.leaveFullscreen(); return true
            default: return false
            }
        }

        loadFolders()
        refresh()
    }

    /// A size that fits the screen the window opens on.
    ///
    /// It used to be a flat 1180×680. 680 is taller than the work area of a
    /// 1366×768 laptop once the panel and the title bar are taken off, so the
    /// window opened with its lower edge below the screen on the most common
    /// size of cheap laptop there is.
    ///
    /// The monitor is asked for its *work* area, not its resolution: that is
    /// the part left over after the desktop's panels, which is what a window
    /// can actually occupy.
    ///
    /// The room left for the decoration is subtracted and not scaled, because
    /// it does not scale: this sets the size of the window's *content*, while
    /// the window on screen is that plus its header bar and borders. Measured
    /// under Xvfb, that is a flat 60 pixels of height and 10 of width at both
    /// 900 and 600 pixels of screen — so a percentage of the work area
    /// overshoots by a constant, which is how the first attempt at this came
    /// out 624 pixels tall on a 600-pixel screen.
    static func openingSize() -> (width: Int32, height: Int32) {
        // What the header bar and the client-side borders add on top of the
        // content size, with room to spare: being a little smaller than the
        // screen costs nothing, being larger hides the bottom of the window.
        let decorationWidth: Int32 = 24
        let decorationHeight: Int32 = 88

        var width: Int32 = 1180
        var height: Int32 = 740
        if let display = gdk_display_get_default(),
           let monitor = gdk_display_get_primary_monitor(display)
               ?? gdk_display_get_monitor(display, 0) {
            var area = GdkRectangle()
            gdk_monitor_get_workarea(monitor, &area)
            if area.width > 0, area.height > 0 {
                width = min(width, area.width - decorationWidth)
                height = min(height, area.height - decorationHeight)
            }
        }
        // A floor as well as a ceiling: a misreported work area of a few
        // pixels must not open a window nobody can use. The window can be
        // smaller than this if the screen is — the column scrolls, so there
        // is no height it cannot be given.
        return (max(480, width), max(320, height))
    }

    /// Fullscreen, and back again.
    ///
    /// There was no way to do this at all — no key, no menu item — so
    /// ‚fullscreen does not work‘ was literally true: pressing F11 did
    /// nothing, and on a screen the window was already too tall for, the
    /// desktop's own fullscreen could not help either because the window had
    /// no smaller size to take. Escape leaves it, which is what every other
    /// fullscreen does and what somebody who has lost the title bar will try.
    func toggleFullscreen() {
        if isFullscreen {
            gtk_window_unfullscreen(Gtk.window(widget))
        } else {
            gtk_window_fullscreen(Gtk.window(widget))
        }
        isFullscreen.toggle()
    }

    func leaveFullscreen() {
        guard isFullscreen else { return }
        gtk_window_unfullscreen(Gtk.window(widget))
        isFullscreen = false
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
        let languageRow = Int(gtk_combo_box_get_active(Gtk.comboBox(languageCombo)))
        settings.language = languageRow <= 0 || languageRow > Language.allCases.count
            ? nil : Language.allCases[languageRow - 1]
        // A GTK label is given its text once, when it is built, so changing
        // the language cannot reach the labels already on screen. The web
        // interface re-renders every request and does not have this problem;
        // here the honest thing is to say so rather than leave the user
        // looking at a window that only half changed.
        let languageChanged = settings.language != coordinator.settings.language

        let mode = Int(gtk_combo_box_get_active(Gtk.comboBox(modeCombo)))
        if mode >= 0, mode < IdentificationMode.allCases.count {
            settings.identification = IdentificationMode.allCases[mode]
        }
        // The music folder goes through the same folding as the others: a
        // blank chooser means GTK could not show the path, not that the
        // user cleared it.
        let chosenMusic = Gtk.chosenFolder(musicChooser)
        if !chosenMusic.isEmpty { settings.musicFolder = chosenMusic }
        let library = Int(gtk_combo_box_get_active(Gtk.comboBox(libraryModeCombo)))
        if library >= 0, library < LibraryMode.allCases.count {
            settings.libraryMode = LibraryMode.allCases[library]
        }
        settings.schedule = readScheduleFields(from: settings.schedule)
        settings.remote = readRemoteFields(from: settings.remote)
        coordinator.submit(.saveSettings(settings))

        // With the time of day, and said next to the button that was just
        // pressed. "Saved." appearing where "Saved." already was is
        // indistinguishable from nothing happening, which is what was
        // reported: "no idea whether that saved or not". A clock that moves
        // is the only version of this sentence that answers the question.
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        Gtk.setText(savedLabel, Text.s(
            "Übernommen um \(formatter.string(from: Date()))",
            "Applied at \(formatter.string(from: Date()))"))
        if languageChanged {
            Gtk.setText(resultLabel, Text.s(
                "Sprache gespeichert — das Fenster zeigt sie nach einem Neustart.",
                "Language saved — the window shows it after a restart."))
        }

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

    /// Reads the schedule fields.
    ///
    /// A time that is not a time is kept as an impossible hour rather
    /// than quietly becoming some other hour: problems() then says so,
    /// and the user sees why nothing was saved.
    private func readScheduleFields(from current: Schedule) -> Schedule {
        var schedule = current
        schedule.isEnabled = Gtk.isChecked(scheduleCheck)
        schedule.alsoRename = Gtk.isChecked(scheduleRenameCheck)
        schedule.alsoSend = Gtk.isChecked(scheduleSendCheck)

        let typed = Gtk.text(of: scheduleTimeEntry).trimmingCharacters(in: .whitespaces)
        let parts = typed.split(separator: ":", maxSplits: 1)
        if parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) {
            schedule.hour = hour
            schedule.minute = minute
        } else if !typed.isEmpty {
            schedule.hour = -1
        }
        let hours = Gtk.text(of: scheduleHoursEntry).trimmingCharacters(in: .whitespaces)
        if !hours.isEmpty { schedule.everyHours = Int(hours) ?? -1 }

        let cadence = Int(gtk_combo_box_get_active(Gtk.comboBox(scheduleCadenceCombo)))
        if cadence >= 0, cadence < Schedule.Cadence.allCases.count {
            schedule.cadence = Schedule.Cadence.allCases[cadence]
        }
        return schedule
    }

    /// Reads the server fields, keeping anything the window cannot express.
    ///
    /// The port is the one field that can be typed wrong in a way worth
    /// catching here: an empty or non-numeric box keeps the stored port
    /// rather than quietly becoming 22, which would send the library to
    /// whatever answers there.
    private func readRemoteFields(from current: RemoteTarget) -> RemoteTarget {
        let loaded = loadedSettings.remote
        var target = current

        // Each field is written back only when the widget differs from what
        // was loaded into it — that is, only when the user changed it here.
        // Anything they did not touch keeps whatever is in the settings now,
        // which may have been changed from the web interface since.
        func merge<T: Equatable>(_ widget: T, _ wasLoaded: T, into field: inout T) {
            if widget != wasLoaded { field = widget }
        }

        merge(Gtk.isChecked(remoteEnabledCheck), loaded.isEnabled, into: &target.isEnabled)
        merge(Gtk.isChecked(remoteRemoveLocalCheck), loaded.removeLocalAfterSend,
              into: &target.removeLocalAfterSend)
        merge(Gtk.isChecked(remoteTrustCheck), loaded.trustOnFirstUse,
              into: &target.trustOnFirstUse)
        merge(Gtk.text(of: remoteHostEntry).trimmingCharacters(in: .whitespaces),
              loaded.host, into: &target.host)
        merge(Gtk.text(of: remoteUserEntry).trimmingCharacters(in: .whitespaces),
              loaded.user, into: &target.user)
        merge(Gtk.text(of: remoteBaseEntry).trimmingCharacters(in: .whitespaces),
              loaded.basePath, into: &target.basePath)
        merge(Gtk.text(of: remoteMoviesPathEntry).trimmingCharacters(in: .whitespaces),
              loaded.moviesPath, into: &target.moviesPath)
        merge(Gtk.text(of: remoteSeriesPathEntry).trimmingCharacters(in: .whitespaces),
              loaded.seriesPath, into: &target.seriesPath)
        merge(Gtk.text(of: remoteMusicPathEntry).trimmingCharacters(in: .whitespaces),
              loaded.musicPath, into: &target.musicPath)
        merge(Gtk.text(of: remoteIdentityEntry).trimmingCharacters(in: .whitespaces),
              loaded.identityFile, into: &target.identityFile)

        if let port = Int(Gtk.text(of: remotePortEntry).trimmingCharacters(in: .whitespaces)),
           (1...65535).contains(port) {
            merge(port, loaded.port, into: &target.port)
        }
        let transport = Int(gtk_combo_box_get_active(Gtk.comboBox(remoteTransportCombo)))
        if transport >= 0, transport < RemoteTarget.Transport.allCases.count {
            merge(RemoteTarget.Transport.allCases[transport], loaded.transport,
                  into: &target.transport)
        }
        let auth = Int(gtk_combo_box_get_active(Gtk.comboBox(remoteAuthCombo)))
        if auth >= 0, auth < RemoteTarget.Authentication.allCases.count {
            merge(RemoteTarget.Authentication.allCases[auth], loaded.authentication,
                  into: &target.authentication)
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

    /// Saves first, so the file lands in the folder currently shown rather
    /// than in whichever one was stored when the window opened.
    func startDownload() {
        let url = Gtk.text(of: urlEntry).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        saveFolders()
        coordinator.submit(.downloadURL(url))
        // Cleared on submission: the field is for the next one, and a link
        // left sitting there invites a second press that fetches it twice.
        Gtk.setText(of: urlEntry, "")
    }

    func cancelDownload() {
        coordinator.submit(.cancelDownload)
    }

    /// Saves first, for the same reason the model-server test does: testing
    /// the stored address while the user looks at a corrected one reports on
    /// the wrong server.
    func testServer() {
        saveFolders()
        coordinator.submit(.testRemoteConnection)
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

    // MARK: The menu and the windows behind it

    /// A window for one group of settings, hidden rather than destroyed when
    /// it is closed.
    ///
    /// Hidden, because destroying it would take the entries with it, and
    /// every read and fill in this file points at those entries. A closed
    /// panel that can be opened again with its text still in it is also what
    /// a person expects.
    private static func panel(_ title: String,
                              holding content: UnsafeMutablePointer<GtkWidget>,
                              over parent: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget> {
        let panel = gtk_window_new(GTK_WINDOW_TOPLEVEL)!
        gtk_window_set_title(Gtk.window(panel), title)
        gtk_window_set_transient_for(Gtk.window(panel), Gtk.window(parent))
        // Not modal: someone adjusting the server address may well want to
        // read the list behind it while they do.
        gtk_window_set_modal(Gtk.window(panel), 0)
        gtk_window_set_destroy_with_parent(Gtk.window(panel), 1)
        gtk_window_set_default_size(Gtk.window(panel), 560, 620)
        // The same reason the main column scrolls: a window cannot be made
        // shorter than its content's minimum height, and four sections of
        // settings are taller than a laptop screen.
        let scroller = gtk_scrolled_window_new(nil, nil)!
        gtk_scrolled_window_set_policy(Gtk.scrolledWindow(scroller),
                                       GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_container_add(Gtk.container(scroller), content)
        gtk_container_add(Gtk.container(panel), scroller)
        // Closing hides it. Without this the window is destroyed and every
        // widget this file holds a pointer to goes with it.
        let onDelete: @convention(c) (UnsafeMutablePointer<GtkWidget>?,
                                      UnsafeMutableRawPointer?,
                                      UnsafeMutableRawPointer?) -> gboolean = { widget, _, _ in
            guard let widget else { return 0 }
            gtk_widget_hide(widget)
            return 1   // handled: do not destroy
        }
        Gtk.connect(panel, "delete-event", unsafeBitCast(onDelete, to: GCallback.self))
        return panel
    }

    /// Opens one of those windows, building it on screen the first time.
    private func open(_ panel: UnsafeMutablePointer<GtkWidget>) {
        gtk_widget_show_all(panel)
        gtk_window_present(Gtk.window(panel))
    }

    /// The header menu.
    ///
    /// Built fresh each time rather than kept: it has four entries and no
    /// state, and a menu assembled on demand cannot drift out of step with
    /// what the window can actually do.
    func showMenu() {
        let menu = gtk_menu_new()!
        func entry(_ label: String, _ action: @escaping (AppWindow) -> Void) {
            let item = gtk_menu_item_new_with_label(label)!
            Gtk.onActivate(item, self, action)
            gtk_menu_shell_append(Gtk.menuShell(menu), item)
        }
        entry(Text.s("Einstellungen …", "Settings…")) { $0.open($0.settingsDialog) }
        entry(Text.s("Status …", "Status…")) { $0.open($0.statusDialog) }
        entry(Text.s("Aus dem Netz laden …", "Fetch from a link…")) {
            $0.open($0.fetchDialog)
        }
        gtk_menu_shell_append(Gtk.menuShell(menu),
                              gtk_separator_menu_item_new())
        entry(MediafinVersion.display) { _ in }
        gtk_widget_show_all(menu)
        gtk_menu_popup_at_pointer(Gtk.menu(menu), nil)
    }

    // MARK: Driven from outside, so CI can press a button

    /// What the window is currently telling the user, read back from the
    /// label itself.
    ///
    /// Read from the widget and not from the snapshot on purpose: the
    /// complaint was "pressing Scan says nothing at all", and only the widget
    /// can answer that. Asking the engine what it thinks it said would agree
    /// with itself and prove nothing.
    var statusText: String {
        String(cString: gtk_label_get_text(Gtk.label(resultLabel)))
    }

    /// Where each row says its file is going, read off the labels.
    var destinationTexts: [String] {
        rowDestinations.map { String(cString: gtk_label_get_text(Gtk.label($0))) }
    }

    /// What the settings panel says about the last time Apply was pressed,
    /// read back off that label.
    var appliedText: String {
        String(cString: gtk_label_get_text(Gtk.label(savedLabel)))
    }

    /// Opens the settings panel, as the menu does.
    func openSettings() { open(settingsDialog) }

    /// Presses Apply in the settings panel.
    func pressApply() { saveFolders() }

    /// What the middle of the window says while the list is empty, read back
    /// off that label. Empty when the list has rows.
    ///
    /// Checked separately from `statusText` because the complaint was not
    /// that nothing was said -- something was -- but that it was said in a
    /// small dim line at the bottom edge where nobody was looking.
    var emptyListText: String {
        guard let detail = emptyDetail else { return "" }
        return String(cString: gtk_label_get_text(Gtk.label(detail)))
    }

    /// Whether the Scan button can be pressed at all. It used to be greyed
    /// out whenever no import folder was set, which is how "the scan button
    /// does not work" came about.
    var scanButtonIsAvailable: Bool {
        gtk_widget_get_sensitive(scanButton) != 0
    }

    /// Presses Scan exactly as a click does -- through the signal, so the
    /// real handler runs and nothing about this path is special.
    func pressScan() {
        gtk_button_clicked(Gtk.button(scanButton))
    }

    /// Files let go of on the window.
    ///
    /// Handed straight to the engine with no filtering here: which of them
    /// are media, which are folders to look inside, and which were already
    /// listed is one set of rules, and it lives in one place. A window that
    /// formed its own opinion would be a second place for the two to disagree.
    func addDropped(_ urls: [URL]) {
        FileHandle.standardError.write(Data(
            "mediafin: drop: \(urls.count) handed to the engine\n".utf8))
        coordinator.submit(.addFiles(urls))
        FileHandle.standardError.write(Data("mediafin: drop: submitted\n".utf8))
    }

    func setAllChecked(_ on: Bool) {
        for row in rowChecks { Gtk.setChecked(row.check, on) }
    }

    private func loadFolders() {
        let settings = coordinator.settings
        loadedSettings = settings
        Gtk.setChosenFolder(sourceChooser, settings.sourceFolder)
        Gtk.setChosenFolder(moviesChooser, settings.moviesFolder)
        Gtk.setChosenFolder(seriesChooser, settings.seriesFolder)
        Gtk.setChosenFolder(musicChooser, settings.musicFolder)
        if let index = LibraryMode.allCases.firstIndex(of: settings.libraryMode) {
            gtk_combo_box_set_active(Gtk.comboBox(libraryModeCombo), Int32(index))
        }
        // 0 is "follow the system"; the languages come after it.
        let languageRow = settings.language
            .flatMap { Language.allCases.firstIndex(of: $0) }
            .map { $0 + 1 } ?? 0
        gtk_combo_box_set_active(Gtk.comboBox(languageCombo), Int32(languageRow))

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

        let schedule = settings.schedule
        Gtk.setChecked(scheduleCheck, schedule.isEnabled)
        Gtk.setChecked(scheduleRenameCheck, schedule.alsoRename)
        Gtk.setChecked(scheduleSendCheck, schedule.alsoSend)
        Gtk.setText(of: scheduleTimeEntry,
                    String(format: "%02d:%02d", schedule.hour, schedule.minute))
        Gtk.setText(of: scheduleHoursEntry, String(schedule.everyHours))
        if let index = Schedule.Cadence.allCases.firstIndex(of: schedule.cadence) {
            gtk_combo_box_set_active(Gtk.comboBox(scheduleCadenceCombo), Int32(index))
        }
        Gtk.setText(scheduleSummary, ScheduleLine.describe(schedule, coordinator.snapshot))

        let remote = settings.remote
        Gtk.setChecked(remoteEnabledCheck, remote.isEnabled)
        Gtk.setChecked(remoteRemoveLocalCheck, remote.removeLocalAfterSend)
        Gtk.setChecked(remoteTrustCheck, remote.trustOnFirstUse)
        Gtk.setText(of: remoteHostEntry, remote.host)
        Gtk.setText(of: remoteUserEntry, remote.user)
        Gtk.setText(of: remoteBaseEntry, remote.basePath)
        Gtk.setText(of: remoteMoviesPathEntry, remote.moviesPath)
        Gtk.setText(of: remoteSeriesPathEntry, remote.seriesPath)
        Gtk.setText(of: remoteMusicPathEntry, remote.musicPath)
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
            subtitle = Text.s("Mit Fehlern beendet", "Finished with errors")
        } else if state.busy {
            subtitle = (state.convertStatus ?? Text.s("Arbeitet", "Working"))
                + " · \(state.activePercent) %"
        } else {
            subtitle = Text.s("Bereit", "Ready")
        }
        gtk_header_bar_set_subtitle(Gtk.headerBar(header), subtitle)

        Gtk.setText(countsLabel, Text.s(
            "\(state.totalItems) Vorschläge · \(state.ready) angehakt · "
                + "\(state.done) umbenannt",
            "\(state.totalItems) proposals · \(state.ready) ticked · "
                + "\(state.done) renamed"))
        Gtk.setText(resultLabel, state.lastResult ?? "")
        refreshLampBar()

        // While the list is empty, the last thing that happened goes in the
        // middle too. Not instead of the footer -- the footer is the running
        // commentary -- but because an empty list is exactly the moment the
        // user is looking at the middle and asking "well, what happened?".
        if let detail = emptyDetail, let said = state.lastResult, !said.isEmpty {
            Gtk.setText(detail, said)
            // Remove then add, rather than Styling.style, which only ever
            // adds: this runs twice a second, so a state that flips would
            // otherwise end up carrying both classes at once and let CSS
            // precedence decide which colour the user gets.
            let context = gtk_widget_get_style_context(detail)
            gtk_style_context_remove_class(context, state.hasError ? "mf-dim" : "mf-fail")
            gtk_style_context_add_class(context, state.hasError ? "mf-fail" : "mf-dim")
        }

        // Available whenever nothing is running, even with no import folder
        // set. It used to be greyed out without one -- and the engine has the
        // right sentence for that case ("set the import folder first"), which
        // a disabled button is precisely the way to never see. "The scan
        // button does not work" is what that looks like from the outside.
        let hasSource = !coordinator.settings.sourceFolder.isEmpty
        gtk_widget_set_sensitive(scanButton, state.busy ? 0 : 1)
        gtk_widget_set_sensitive(applyButton, (!rowChecks.isEmpty && !state.busy) ? 1 : 0)
        gtk_widget_set_sensitive(undoButton, state.busy ? 0 : 1)

        // Sending needs somewhere to send to and something to send; stopping
        // needs something to stop. A button that would answer "nothing is
        // configured" is better off visibly unavailable.
        gtk_widget_set_sensitive(
            sendButton,
            (state.remoteConfigured && !rowChecks.isEmpty && !state.busy) ? 1 : 0)
        gtk_widget_set_sensitive(cancelSendButton, state.transferring ? 1 : 0)

        gtk_widget_set_sensitive(downloadButton, (!hasSource || state.busy) ? 0 : 1)
        gtk_widget_set_sensitive(cancelDownloadButton, state.downloading ? 1 : 0)
        if state.downloading {
            // No fraction means no size was reported — a stream with no
            // Content-Length. Pulsing says "working" without claiming a
            // percentage nobody measured.
            if let fraction = state.downloadProgress {
                Gtk.setProgress(downloadProgress, fraction: fraction,
                                text: state.downloadDetail ?? "")
            } else {
                gtk_progress_bar_pulse(Gtk.progressBar(downloadProgress))
                gtk_progress_bar_set_show_text(Gtk.progressBar(downloadProgress), 1)
                gtk_progress_bar_set_text(Gtk.progressBar(downloadProgress),
                                          state.downloadDetail
                                              ?? Text.s("Wird geladen …", "Fetching…"))
            }
        } else {
            Gtk.setProgress(downloadProgress, fraction: 0,
                            text: Text.s("Kein Download", "No download"))
        }
        // Emptied when nothing is running: the bar used to stay visually
        // full after a run while the words beside it said "Keine
        // Übertragung", which reads as a transfer stuck at 100 %.
        Gtk.setProgress(remoteProgress,
                        fraction: state.transferring ? state.transferProgress : 0,
                        text: state.transferSummary)

        // The schedule line too, so "Nächster Lauf" stays true while the
        // window is open rather than being whatever it was when the settings
        // were last loaded.
        Gtk.setText(scheduleSummary,
                    ScheduleLine.describe(coordinator.settings.schedule, state))

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

        let summary = SystemChecks.summary(checks)
        // So a collapsed panel still says whether anything is wrong.
        gtk_expander_set_label(Gtk.expander(checksExpander),
                               Text.s("Status — ", "Status — ") + summary)
        // A red lamp must not stay folded away behind a summary line. Opened
        // once, not on every refresh, so it cannot fight a user who closes it.
        if SystemChecks.worst(checks) == .failed, !hasOpenedChecksOnFailure {
            hasOpenedChecksOnFailure = true
            gtk_expander_set_expanded(Gtk.expander(checksExpander), 1)
        }
        for check in checks {
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
            // A dot and a word. Colour alone would leave the panel unreadable
            // for anyone who cannot tell the red lamp from the green one.
            let lamp = Self.label("\u{25CF}", classes: "mf-lamp",
                                  Self.lampClass(check.state))
            gtk_widget_set_size_request(lamp, 16, -1)
            gtk_box_pack_start(Gtk.box(row), lamp, 0, 0, 0)

            let name = Self.label(check.name, classes: "mf-lamp-name")
            gtk_widget_set_size_request(name, 128, -1)
            gtk_box_pack_start(Gtk.box(row), name, 0, 0, 0)

            // The word the comment above has always promised. Without it the
            // row is colour and nothing else, which is the thing that
            // comment says must not happen.
            let word = Self.label(check.state.word, classes: Self.lampClass(check.state))
            gtk_widget_set_size_request(word, 62, -1)
            gtk_box_pack_start(Gtk.box(row), word, 0, 0, 0)

            let detail = Self.label(check.detail, classes: "mf-dim")
            // Cut in the middle rather than wrapped: three of the eight rows
            // are folder paths, each of which took a second line, and the
            // readable parts of a path are its start and its end. The whole
            // of it is still in the tooltip.
            gtk_label_set_ellipsize(Gtk.label(detail), PANGO_ELLIPSIZE_MIDDLE)
            gtk_widget_set_tooltip_text(detail, check.detail)
            gtk_label_set_line_wrap(Gtk.label(detail), 1)
            gtk_box_pack_start(Gtk.box(row), detail, 1, 1, 0)

            gtk_box_pack_start(Gtk.box(checksColumn), row, 0, 0, 0)
            gtk_widget_show_all(row)
            checkWidgets.append(row)
        }
    }

    /// The traffic light in the bar at the bottom.
    ///
    /// Rewritten only when it changed. This runs twice a second, and setting a
    /// label to the text it already has makes GTK re-measure the row for
    /// nothing.
    private func refreshLampBar() {
        let checks = coordinator.systemChecks
        let worst = SystemChecks.worst(checks)
        // The summary carries the counts; the word carries the verdict. One
        // without the other reads either as "7 of something" or as a mood.
        // The lamp's own word, with a capital so it opens the line: "bereit"
        // and "prüfen" are lower case in the lamp rows, where they sit after
        // a name.
        let word = worst.word
        let verdict = word.isEmpty ? word : word.prefix(1).uppercased() + word.dropFirst()
        let text = checks.isEmpty
            ? Text.s("Noch nicht geprüft", "Not checked yet")
            : verdict + " · " + SystemChecks.summary(checks)
        guard lampShown?.state != worst || lampShown?.text != text else { return }
        lampShown = (worst, text)

        Gtk.setText(lampText, text)
        // Remove every other class before adding this one. Styling.style only
        // ever adds, and a dot that has been green and is now red would
        // otherwise carry both and let CSS precedence pick.
        let context = gtk_widget_get_style_context(lampDot)
        for state in [SystemCheck.State.ok, .warning, .failed, .off] {
            gtk_style_context_remove_class(context, Self.lampClass(state))
        }
        gtk_style_context_add_class(context, Self.lampClass(worst))
    }

    /// What the bar says about the worst lamp, read back off the label.
    var lampBarText: String {
        String(cString: gtk_label_get_text(Gtk.label(lampText)))
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
            ? Text.s("\(total) Einträge · \(failures) mit Fehler",
                     "\(total) entries · \(failures) with an error")
            : Text.s("\(total) Einträge", "\(total) entries"))

        if entries.isEmpty {
            let empty = Self.label(Text.s("Noch nichts passiert.", "Nothing has happened yet."),
                                       classes: "mf-dim")
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
        case .success: return Text.s("umbenannt", "renamed")
        case .failure: return Text.s("fehlgeschlagen", "failed")
        case .skipped: return Text.s("übersprungen", "skipped")
        case .converted: return Text.s("konvertiert", "converted")
        case .sent: return Text.s("gesendet", "sent")
        case .downloaded: return Text.s("geladen", "fetched")
        }
    }

    private static func statusClass(_ status: RenameLogEntry.Status) -> String {
        switch status {
        case .success, .converted, .sent, .downloaded: return "mf-ok"
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
        rowDestinations = []
        emptyDetail = nil
        rowChecks = []

        if items.isEmpty {
            // Two sentences, because there are two ways in and the second one
            // is invisible until somebody says so. An empty list that only
            // said "nothing scanned yet" left dragging a file onto the window
            // as something you had to guess at.
            let empty = Self.label(
                Text.s("Dateien oder Ordner hierher ziehen,",
                       "Drag files or folders here,"),
                classes: "mf-empty")
            gtk_label_set_xalign(Gtk.label(empty), 0.5)
            gtk_box_pack_start(Gtk.box(listColumn), empty, 0, 0, 0)
            let second = Self.label(
                coordinator.settings.sourceFolder.isEmpty
                    ? Text.s("oder einen Importordner in den Einstellungen setzen "
                                 + "und „Durchsuchen“ drücken.",
                             "or set an import folder in the settings and press "
                                 + "“Scan”.")
                    : Text.s("oder „Durchsuchen“ drücken.", "or press “Scan”."),
                classes: "mf-dim")
            gtk_label_set_xalign(Gtk.label(second), 0.5)
            gtk_label_set_line_wrap(Gtk.label(second), 1)
            gtk_box_pack_start(Gtk.box(listColumn), second, 0, 0, 0)
            rowWidgets = [empty, second]
            emptyDetail = second
        } else {
            for (index, item) in items.enumerated() {
                let built = Self.proposalRow(item, banded: index % 2 == 1)
                gtk_box_pack_start(Gtk.box(listColumn), built.row, 0, 0, 0)
                rowWidgets.append(built.row)
                rowChecks.append((id: item.id, check: built.check))
                rowDestinations.append(built.destination)
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
        -> (row: UnsafeMutablePointer<GtkWidget>,
            destination: UnsafeMutablePointer<GtkWidget>,
            check: UnsafeMutablePointer<GtkWidget>) {
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10)!
        Styling.style(row, "mf-row")
        if banded { Styling.style(row, "mf-row-alt") }

        // Whatever the engine says about this item. As things stand the
        // planner never declines one — it flags a problem with `conflict`
        // rather than by setting isAccepted to false — so in practice this
        // is always ticked. Reading the field anyway keeps the window from
        // disagreeing with the engine if that ever changes. (An earlier
        // comment here claimed the planner leaves uncertain files unticked.
        // It does not; nothing in Core ever assigns isAccepted = false.)
        let check = gtk_check_button_new()!
        Gtk.setChecked(check, item.isAccepted)
        gtk_widget_set_valign(check, GTK_ALIGN_CENTER)
        gtk_box_pack_start(Gtk.box(row), check, 0, 0, 0)

        let text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        let from = label(item.originalFileName, classes: "mf-from")
        gtk_label_set_ellipsize(Gtk.label(from), PANGO_ELLIPSIZE_MIDDLE)
        gtk_box_pack_start(Gtk.box(text), from, 0, 0, 0)

        // The whole destination, absolutely, and not just the relative path.
        //
        // The row used to read "→ Fargo/Season 05/Fargo - S05E10.mkv" and say
        // nothing about where that is. Asked "where is this being moved to",
        // the window had no answer: an episode goes under the series folder
        // when one is set, and into the folder the file is already in when one
        // is not — the same name, two completely different places, and the one
        // you cannot see is the one that buries the file a level deeper where
        // it stands.
        //
        // Ellipsised in the middle so a long path keeps both ends, and the
        // whole thing is on the tooltip.
        let destination = item.primaryDestination.path
        let to = label("→ " + destination, classes: "mf-to")
        gtk_label_set_ellipsize(Gtk.label(to), PANGO_ELLIPSIZE_MIDDLE)
        gtk_widget_set_tooltip_text(to, destination)
        gtk_box_pack_start(Gtk.box(text), to, 0, 0, 0)

        // Said out loud when the destination is the folder the file is in
        // already. That is what happens with no library folder set, and it is
        // not obviously wrong from the path alone — it reads like a tidy
        // subfolder until you notice it is under Downloads.
        if item.outputRoot.standardizedFileURL.path
            == item.mediaFile.url.deletingLastPathComponent()
                .standardizedFileURL.path {
            let here = label(
                Text.s("Bleibt neben der Datei — kein Bibliotheksordner gesetzt",
                       "Stays next to the file — no library folder is set"),
                classes: "mf-warn")
            gtk_label_set_ellipsize(Gtk.label(here), PANGO_ELLIPSIZE_END)
            gtk_box_pack_start(Gtk.box(text), here, 0, 0, 0)
        }

        if let conflict = item.conflict {
            let warning = label(conflictText(conflict), classes: "mf-warn")
            gtk_box_pack_start(Gtk.box(text), warning, 0, 0, 0)
        }
        gtk_box_pack_start(Gtk.box(row), text, 1, 1, 0)
        return (row, destination: to, check)
    }

    private static func conflictText(_ kind: ConflictKind) -> String {
        switch kind {
        case .existingFile:
            return Text.s("Dort liegt schon eine Datei", "A file is already there")
        case .duplicateInBatch:
            return Text.s("Zwei Dateien wollen denselben Namen",
                          "Two files want the same name")
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
    private static func card(titled title: String? = nil)
        -> UnsafeMutablePointer<GtkWidget> {
        let card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        Styling.style(card, "mf-card")
        // Optional: a card inside an expander already has that expander's
        // label over it, and a caption repeating it is a wasted line.
        if let title {
            let caption = label(title.uppercased(), classes: "mf-card-title")
            gtk_box_pack_start(Gtk.box(card), caption, 0, 0, 0)
        }
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
