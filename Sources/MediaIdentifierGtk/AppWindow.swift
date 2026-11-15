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
    /// Beside Scan in the header, and only sensitive while something is
    /// running. A scan with identification on is one blocking request per
    /// file, so without this there was no way to stop a run that had turned
    /// into hours of timeouts.
    private let stopScanButton: UnsafeMutablePointer<GtkWidget>
    private let applyButton: UnsafeMutablePointer<GtkWidget>
    private let undoButton: UnsafeMutablePointer<GtkWidget>
    private let listColumn: UnsafeMutablePointer<GtkWidget>
    private let modeCombo: UnsafeMutablePointer<GtkWidget>
    private let llmURLEntry: UnsafeMutablePointer<GtkWidget>
    private let llmModelEntry: UnsafeMutablePointer<GtkWidget>
    private let llmKeyEntry: UnsafeMutablePointer<GtkWidget>
    private let logColumn: UnsafeMutablePointer<GtkWidget>
    private let logCountLabel: UnsafeMutablePointer<GtkWidget>
    /// Empties the history — and the undo journal with it, which is why it
    /// asks first. It was the last command the engine accepted that nothing
    /// in the program could send.
    private let clearHistoryButton: UnsafeMutablePointer<GtkWidget>
    private let urlEntry: UnsafeMutablePointer<GtkWidget>
    private let downloadButton: UnsafeMutablePointer<GtkWidget>
    private let cancelDownloadButton: UnsafeMutablePointer<GtkWidget>
    private let downloadProgress: UnsafeMutablePointer<GtkWidget>
    private let scheduleCheck: UnsafeMutablePointer<GtkWidget>
    private let scheduleCadenceCombo: UnsafeMutablePointer<GtkWidget>
    private let scheduleTimeEntry: UnsafeMutablePointer<GtkWidget>
    private let scheduleHoursEntry: UnsafeMutablePointer<GtkWidget>
    private let scheduleRenameCheck: UnsafeMutablePointer<GtkWidget>
    private let scheduleSummary: UnsafeMutablePointer<GtkWidget>
    private let checksColumn: UnsafeMutablePointer<GtkWidget>
    private let checksExpander: UnsafeMutablePointer<GtkWidget>
    /// Where the media server is, so a rename can tell it to look again.
    ///
    /// The field was missing for as long as the window has existed: the
    /// setting is in `WebSettings`, `SettingsMerge` writes it back, the
    /// engine uses it — and nothing could ever type it in. The web
    /// front-end had the field and the web front-end is gone.
    private let jellyfinURLEntry: UnsafeMutablePointer<GtkWidget>
    // MARK: Converting
    //
    // The whole conversion feature was reachable from the web front-end
    // only, so when that went, FFmpeg driving, progress, cancelling and
    // size estimation stayed in the binary with no way to ask for them.
    // These are the switches that decide what a conversion does.
    private let convertCodecCombo: UnsafeMutablePointer<GtkWidget>
    private let convertQualityEntry: UnsafeMutablePointer<GtkWidget>
    private let convertPresetCombo: UnsafeMutablePointer<GtkWidget>
    private let convertHeightCombo: UnsafeMutablePointer<GtkWidget>
    private let convertAudioCombo: UnsafeMutablePointer<GtkWidget>
    private let convertSubtitlesCheck: UnsafeMutablePointer<GtkWidget>
    private let ffmpegPathEntry: UnsafeMutablePointer<GtkWidget>
    /// What the settings above will roughly do to the file size, recomputed
    /// from the widgets on every refresh so it answers before the run rather
    /// than after it.
    private let convertEstimate: UnsafeMutablePointer<GtkWidget>
    /// The panel a conversion is actually started from, and its parts.
    private let convertDialog: UnsafeMutablePointer<GtkWidget>
    private let convertFindButton: UnsafeMutablePointer<GtkWidget>
    private let convertRunButton: UnsafeMutablePointer<GtkWidget>
    private let convertStopButton: UnsafeMutablePointer<GtkWidget>
    private let convertListColumn: UnsafeMutablePointer<GtkWidget>
    private let convertCountLabel: UnsafeMutablePointer<GtkWidget>
    private let convertBar: UnsafeMutablePointer<GtkWidget>
    /// The rows of the conversion list, and which candidate each belongs to.
    private var convertRows: [(id: UUID, check: UnsafeMutablePointer<GtkWidget>)] = []
    private var convertRowWidgets: [UnsafeMutablePointer<GtkWidget>] = []
    /// The list's own sentences — the empty state, and the line about rows
    /// past the drawing limit — kept apart from the rows so they can be read
    /// back as text. See `convertListTexts`.
    private var convertNotes: [UnsafeMutablePointer<GtkWidget>] = []
    /// Which files the user has taken *out* of the run, by path.
    ///
    /// Held here and not only in the widgets, for the reason the proposals
    /// list learned the hard way: the list is rebuilt whenever the engine's
    /// candidates change, and a tick that lives only in a destroyed widget
    /// is a tick the user set and the program then quietly dropped. Unlike
    /// the proposals there is no engine-side flag for these — `convertFiles`
    /// takes the set from whoever asks — so this is where it lives.
    ///
    /// By path, and as the *exclusions*, for two reasons. A fresh search
    /// builds fresh candidates with fresh UUIDs, so ids carry nothing over
    /// and a second press of Suchen would silently re-tick the files the
    /// user had just taken out. And everything found is ticked by default:
    /// pressing Suchen is already the statement of intent, and clearing 40
    /// boxes to convert 39 is the wrong way round.
    private var convertExcludedPaths: Set<String> = []
    /// The candidate ids the list is currently drawn from.
    ///
    /// Optional, like `renderedItemIDs`, and for a reason the first version
    /// of this got wrong: with `[]` as the starting value, the first
    /// refresh of an empty list compares `[] != []`, decides nothing has
    /// changed and returns — so the panel opened with a blank black box and
    /// no "Noch nichts gesucht" in it. nil cannot equal any real list, so
    /// the first draw always happens.
    private var renderedConvertIDs: [UUID]?
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
    /// The "will be deleted" label of each row that has one, so a test can
    /// read the warning off the widget rather than off the engine.
    private var rowDeletionNotes: [UnsafeMutablePointer<GtkWidget>] = []
    /// The rows' "this one stays" labels, for the same reason.
    private var rowKeptNotes: [UnsafeMutablePointer<GtkWidget>] = []
    /// True while the rows are being built or seeded, so the tick boxes'
    /// own "toggled" signal is not mistaken for a press.
    private(set) var isSeedingRows = false
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
        stopScanButton = gtk_button_new_with_label(Text.s("Stopp", "Stop"))!
        gtk_widget_set_tooltip_text(
            stopScanButton,
            // It stops a rename as well now, so it no longer says "search".
            // The old wording was the reason nobody noticed that pressing it
            // during a rename answered "Es wird gerade nicht gesucht".
            Text.s("Vor der nächsten Datei anhalten — Suche oder Umbenennen",
                   "Stop before the next file — search or rename"))
        // Packed after Scan, so in a header's end group it sits to its left:
        // the thing you reach for second is not in front of the thing you
        // reach for first.
        gtk_header_bar_pack_end(Gtk.headerBar(header), scanButton)
        gtk_header_bar_pack_end(Gtk.headerBar(header), stopScanButton)
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
        scheduleSummary = Self.label("", classes: "mf-dim")
        gtk_label_set_line_wrap(Gtk.label(scheduleSummary), 1)

        let scheduleCard = Self.card(titled: Text.s("Zeitplan", "Schedule"))
        Self.add(scheduleCheck, to: scheduleCard)
        Self.add(Self.row(Text.s("Wann", "When"), scheduleCadenceCombo), to: scheduleCard)
        Self.add(Self.row(Text.s("Uhrzeit", "Time"), scheduleTimeEntry), to: scheduleCard)
        Self.add(Self.row(Text.s("Abstand (h)", "Interval (h)"), scheduleHoursEntry), to: scheduleCard)
        Self.add(scheduleRenameCheck, to: scheduleCard)
        Self.add(scheduleSummary, to: scheduleCard)

        let scheduleExpander = gtk_expander_new(Text.s("Zeitplan", "Schedule"))!
        gtk_expander_set_expanded(Gtk.expander(scheduleExpander), 1)
        gtk_container_add(Gtk.container(scheduleExpander), scheduleCard)
        gtk_box_pack_start(Gtk.box(settingsPage), scheduleExpander, 0, 0, 0)

        // MARK: Converting
        //
        // Collapsed, like the detection card: most people never convert
        // anything, and an open card of eight encoder switches is the first
        // thing they would see on opening the settings.
        convertCodecCombo = gtk_combo_box_text_new()!
        for codec in ConversionOptions.VideoCodec.allCases {
            gtk_combo_box_text_append_text(Gtk.comboBoxText(convertCodecCombo),
                                           codec.label)
        }
        convertQualityEntry = Self.entry(placeholder: "21")
        convertPresetCombo = gtk_combo_box_text_new()!
        for preset in ConversionOptions.Preset.allCases {
            gtk_combo_box_text_append_text(Gtk.comboBoxText(convertPresetCombo),
                                           preset.label)
        }
        convertHeightCombo = gtk_combo_box_text_new()!
        for height in WebConversionSettings.offeredHeights {
            gtk_combo_box_text_append_text(Gtk.comboBoxText(convertHeightCombo),
                                           WebConversionSettings.heightLabel(height))
        }
        convertAudioCombo = gtk_combo_box_text_new()!
        for mode in ConversionOptions.AudioMode.allCases {
            gtk_combo_box_text_append_text(Gtk.comboBoxText(convertAudioCombo),
                                           mode.label)
        }
        convertSubtitlesCheck = gtk_check_button_new_with_label(
            Text.s("Untertitel nicht mitnehmen", "Leave the subtitles out"))!
        ffmpegPathEntry = Self.entry(placeholder: "/usr/bin/ffmpeg")
        convertEstimate = Self.label("", classes: "mf-dim")
        gtk_label_set_line_wrap(Gtk.label(convertEstimate), 1)

        let conversionCard = Self.card()
        Self.add(Self.row(Text.s("Verfahren", "Codec"), convertCodecCombo),
                 to: conversionCard)
        Self.add(Self.row(Text.s("Qualität", "Quality"), convertQualityEntry),
                 to: conversionCard)
        Self.add(Self.row(Text.s("Tempo", "Speed"), convertPresetCombo),
                 to: conversionCard)
        Self.add(Self.row(Text.s("Auflösung", "Resolution"), convertHeightCombo),
                 to: conversionCard)
        Self.add(Self.row(Text.s("Ton", "Audio"), convertAudioCombo),
                 to: conversionCard)
        Self.add(convertSubtitlesCheck, to: conversionCard)
        Self.add(Self.row(Text.s("FFmpeg", "FFmpeg"), ffmpegPathEntry),
                 to: conversionCard)
        Self.add(convertEstimate, to: conversionCard)
        Self.add(Self.label(Text.s(
                    "Die neue Datei wird neben die alte gelegt; die alte bleibt "
                        + "liegen. Angefangen wird im Menü, unter Konvertieren.",
                    "The new file is written beside the old one and the old one "
                        + "stays. A run is started from the Convert panel in the "
                        + "menu."), classes: "mf-dim"),
                 to: conversionCard)

        let conversionExpander = gtk_expander_new(
            Text.s("Konvertieren", "Converting"))!
        gtk_container_add(Gtk.container(conversionExpander), conversionCard)
        gtk_box_pack_start(Gtk.box(settingsPage), conversionExpander, 0, 0, 0)

        // MARK: The conversion panel
        //
        // Separate from the settings: the settings say what a conversion
        // does, this says do it now, to these files. Putting the button in
        // the settings would have made Apply and Konvertieren neighbours,
        // and one of them starts hours of encoding.
        let convertPage = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
        gtk_container_set_border_width(Gtk.container(convertPage), 12)

        convertFindButton = gtk_button_new_with_label(
            Text.s("Suchen", "Look for files"))!
        convertRunButton = gtk_button_new_with_label(
            Text.s("Konvertieren", "Convert"))!
        Styling.style(convertRunButton, "suggested-action")
        convertStopButton = gtk_button_new_with_label(Text.s("Stopp", "Stop"))!
        convertCountLabel = Self.label("", classes: "mf-dim")
        gtk_label_set_line_wrap(Gtk.label(convertCountLabel), 1)
        convertListColumn = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1)!
        convertBar = gtk_progress_bar_new()!

        let convertCard = Self.card()
        let findRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_pack_start(Gtk.box(findRow), convertFindButton, 0, 0, 0)
        gtk_box_pack_start(Gtk.box(findRow), convertCountLabel, 1, 1, 0)
        Self.add(findRow, to: convertCard)

        let convertScroller = gtk_scrolled_window_new(nil, nil)!
        gtk_scrolled_window_set_policy(Gtk.scrolledWindow(convertScroller),
                                       GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_size_request(convertScroller, -1, 220)
        gtk_container_add(Gtk.container(convertScroller), convertListColumn)
        Self.add(convertScroller, to: convertCard, expand: true)

        Self.add(convertBar, to: convertCard)

        let convertActions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let convertAllButton = gtk_button_new_with_label(Text.s("Alle", "All"))!
        let convertNoneButton = gtk_button_new_with_label(Text.s("Keine", "None"))!
        gtk_box_pack_start(Gtk.box(convertActions), convertAllButton, 0, 0, 0)
        gtk_box_pack_start(Gtk.box(convertActions), convertNoneButton, 0, 0, 0)
        // Right to left: convert, then stop — the same order as the main
        // surface, where the one that does the work sits furthest right.
        gtk_box_pack_end(Gtk.box(convertActions), convertRunButton, 0, 0, 0)
        gtk_box_pack_end(Gtk.box(convertActions), convertStopButton, 0, 0, 0)
        Self.add(convertActions, to: convertCard)

        Self.add(Self.label(Text.s(
                    "Die neue Datei wird neben die alte gelegt; die alte bleibt "
                        + "liegen und wird nicht angefasst. Was dabei herauskommt, "
                        + "steht in den Einstellungen unter Konvertieren.",
                    "The new file is written beside the old one; the old one "
                        + "stays and is not touched. What comes out is decided "
                        + "in the settings, under Converting."),
                            classes: "mf-dim"),
                 to: convertCard)
        gtk_box_pack_start(Gtk.box(convertPage), convertCard, 1, 1, 0)

        // MARK: The media server

        jellyfinURLEntry = Self.entry(placeholder: "http://192.168.1.2:8096")
        let jellyfinCard = Self.card()
        Self.add(Self.row(Text.s("Server", "Server"), jellyfinURLEntry), to: jellyfinCard)
        let jellyfinRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let jellyfinTestButton = gtk_button_new_with_label(
            Text.s("Verbindung testen", "Test the connection"))!
        gtk_box_pack_end(Gtk.box(jellyfinRow), jellyfinTestButton, 0, 0, 0)
        Self.add(jellyfinRow, to: jellyfinCard)
        Self.add(Self.label(Text.s(
                    "Nach dem Umbenennen wird dem Server gesagt, dass er neu "
                        + "einlesen soll. Leer lassen, wenn keiner da ist.",
                    "After renaming, the server is told to scan again. Leave it "
                        + "empty if there is none."), classes: "mf-dim"),
                 to: jellyfinCard)

        let jellyfinExpander = gtk_expander_new(
            Text.s("Medienserver", "Media server"))!
        gtk_container_add(Gtk.container(jellyfinExpander), jellyfinCard)
        gtk_box_pack_start(Gtk.box(settingsPage), jellyfinExpander, 0, 0, 0)

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
        // Right to left: rename, then undo. Renaming is the usual one and
        // sits furthest right.
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
        // The title and the button on one line, so the button is clearly
        // this column's and not the list's below it.
        let logHeader = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_pack_start(Gtk.box(logHeader), logTitle, 1, 1, 0)
        // Flat, and at the quiet end of the column: it is not an action
        // anybody came here for, and it throws away the undo history with
        // the list. The dialog behind it says so.
        clearHistoryButton = gtk_button_new_with_label(Text.s("Leeren", "Clear"))!
        gtk_button_set_relief(Gtk.button(clearHistoryButton), GTK_RELIEF_NONE)
        gtk_widget_set_tooltip_text(
            clearHistoryButton,
            Text.s("Verlauf und Rückgängig-Schritte löschen",
                   "Delete the history and the undo steps"))
        gtk_box_pack_end(Gtk.box(logHeader), clearHistoryButton, 0, 0, 0)
        gtk_box_pack_start(Gtk.box(logSide), logHeader, 0, 0, 0)
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
        gtk_container_set_border_width(Gtk.container(saveRow), 12)

        settingsDialog = Self.panel(Text.s("Einstellungen", "Settings"),
                                    holding: settingsPage, over: window,
                                    footer: saveRow)
        statusDialog = Self.panel(Text.s("Status", "Status"),
                                  holding: statusPage, over: window)
        fetchDialog = Self.panel(Text.s("Aus dem Netz laden", "Fetch from a link"),
                                 holding: fetchPage, over: window)
        convertDialog = Self.panel(Text.s("Konvertieren", "Converting"),
                                   holding: convertPage, over: window)

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
        Gtk.onClick(stopScanButton, self) { $0.stopScan() }
        Gtk.onClick(applyButton, self) { $0.applySelected() }
        Gtk.onClick(undoButton, self) { $0.undoLast() }
        Gtk.onClick(allButton, self) { $0.setAllChecked(true) }
        Gtk.onClick(noneButton, self) { $0.setAllChecked(false) }
        Gtk.onClick(testButton, self) { $0.testModelServer() }
        Gtk.onClick(jellyfinTestButton, self) { $0.testMediaServer() }
        Gtk.onClick(convertFindButton, self) { $0.findConvertible() }
        Gtk.onClick(convertRunButton, self) { $0.convertTickedFiles() }
        Gtk.onClick(convertStopButton, self) { $0.stopConverting() }
        Gtk.onClick(convertAllButton, self) { $0.setAllConvertChecked(true) }
        Gtk.onClick(convertNoneButton, self) { $0.setAllConvertChecked(false) }
        Gtk.onClick(clearHistoryButton, self) { $0.clearHistory() }
        Gtk.onClick(checkButton, self) { $0.checkEverything() }
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
        let stored = FolderSelection.applying(
            source: Gtk.chosenFolder(sourceChooser),
            movies: Gtk.chosenFolder(moviesChooser),
            series: Gtk.chosenFolder(seriesChooser),
            to: coordinator.settings
        )
        // Built from the widgets, then merged against what the widgets were
        // filled with: only the fields the user really changed are written.
        // See SettingsMerge — and the comment on `loadedSettings`, which has
        // described this since before it was true.
        var settings = stored

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
        settings.conversion = readConversionFields(from: settings.conversion)
        settings.jellyfinBaseURL =
            Gtk.text(of: jellyfinURLEntry).trimmingCharacters(in: .whitespacesAndNewlines)
        settings = SettingsMerge.applying(typed: settings, loaded: loadedSettings,
                                          to: stored)
        coordinator.submit(.saveSettings(settings))
        // So a second Apply does not re-apply what this one just wrote over
        // somebody else's newer value.
        loadedSettings = settings

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
        // The engine's own `isAccepted`, not the drawn rows. Every tick box
        // reports itself with `.setAccepted`, so the two agree — and reading
        // the rows would mean that with the list capped at
        // `visibleProposals`, pressing Umbenennen renamed only what happened
        // to be on screen. `accepting: nil` means "whatever is accepted",
        // and the executor acts on `isAccepted` alone.
        coordinator.submit(.applyProposedRenames(accepting: nil))
    }

    /// Stops a scan. Goes straight to the engine without saving first: the
    /// point of pressing this is that something is already running, and
    /// saving would queue behind it.
    func stopScan() {
        coordinator.submit(.cancelScan)
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
    /// - Parameter footer: a row pinned to the bottom edge, outside the
    ///   scrolling area. The settings panel's Apply button lives there: it
    ///   used to be packed at the end of the scrolling content, which was
    ///   fine with four sections and stopped being fine at six — the button
    ///   that saves everything sat just below the fold, and a settings
    ///   dialogue whose Apply has to be scrolled to is one people believe
    ///   has no Apply.
    private static func panel(_ title: String,
                              holding content: UnsafeMutablePointer<GtkWidget>,
                              over parent: UnsafeMutablePointer<GtkWidget>,
                              footer: UnsafeMutablePointer<GtkWidget>? = nil)
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
        if let footer {
            let shell = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
            gtk_box_pack_start(Gtk.box(shell), scroller, 1, 1, 0)
            gtk_box_pack_start(Gtk.box(shell), footer, 0, 0, 0)
            gtk_container_add(Gtk.container(panel), shell)
        } else {
            gtk_container_add(Gtk.container(panel), scroller)
        }
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
        // Built once and kept.
        //
        // It used to be built on every press and never destroyed: in GTK3
        // `gtk_menu_init` parents the menu to an internal GTK_WINDOW_POPUP
        // that ref-sinks itself into GTK's toplevel list, so only
        // `gtk_widget_destroy` would release it — and each of the four
        // `Gtk.onActivate` calls retains an `Action` whose matching release
        // is the GClosureNotify that widget destruction fires. So one menu
        // toplevel and four Swift objects leaked per open. The items are
        // the same four every time, so the fix is to stop rebuilding them.
        //
        // The version label is the one thing that could change, and it
        // cannot: it is the binary's own version.
        if menu == nil {
            let built = gtk_menu_new()!
            func entry(_ label: String, _ action: @escaping (AppWindow) -> Void) {
                let item = gtk_menu_item_new_with_label(label)!
                Gtk.onActivate(item, self, action)
                gtk_menu_shell_append(Gtk.menuShell(built), item)
            }
            entry(Text.s("Einstellungen …", "Settings…")) { $0.open($0.settingsDialog) }
            entry(Text.s("Status …", "Status…")) { $0.open($0.statusDialog) }
            entry(Text.s("Aus dem Netz laden …", "Fetch from a link…")) {
                $0.open($0.fetchDialog)
            }
            entry(Text.s("Konvertieren …", "Converting…")) {
                $0.open($0.convertDialog)
            }
            gtk_menu_shell_append(Gtk.menuShell(built),
                                  gtk_separator_menu_item_new())
            entry(MediafinVersion.display) { _ in }
            // Owned by the window, so it goes when the window does rather
            // than outliving it in GTK's toplevel list.
            gtk_menu_attach_to_widget(Gtk.menu(built), widget, nil)
            menu = built
        }
        guard let menu else { return }
        gtk_widget_show_all(menu)
        gtk_menu_popup_at_pointer(Gtk.menu(menu), nil)
    }

    /// The menu, built on first use. See `showMenu`.
    private var menu: UnsafeMutablePointer<GtkWidget>?

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

    /// What the rows say about files that will be deleted, read back off
    /// those labels. Empty when nothing is going to be deleted.
    ///
    /// Deleting is the one thing this program does that cannot be undone, so
    /// what matters is not that the engine knows — it is that the row says
    /// so before the button is pressed. That is a label, so it is read as a
    /// label.
    var deletionTexts: [String] {
        rowDeletionNotes.map { String(cString: gtk_label_get_text(Gtk.label($0))) }
    }

    /// What the rows say about the `.nfo` files they are leaving alone.
    /// Presses one row's tick box, as a click does.
    ///
    /// For the smoke modes: the assertion worth making about a tick is that
    /// pressing the widget changes what the engine will rename, and that can
    /// only be checked by going through the widget.
    @discardableResult
    func pressRowCheck(at index: Int) -> Bool {
        guard rowChecks.indices.contains(index) else { return false }
        let check = rowChecks[index].check
        gtk_toggle_button_set_active(Gtk.toggleButton(check),
                                     Gtk.isChecked(check) ? 0 : 1)
        return true
    }

    /// How many rows are ticked, read off the boxes.
    var tickedRowCount: Int {
        rowChecks.filter { Gtk.isChecked($0.check) }.count
    }

    var keptNoteTexts: [String] {
        rowKeptNotes.map { String(cString: gtk_label_get_text(Gtk.label($0))) }
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

    /// The conversion settings as the *widgets* hold them, for the smoke
    /// modes.
    ///
    /// Read off the widgets and not out of `coordinator.settings`, for the
    /// same reason `statusText` is read off its label: the question is
    /// whether the window shows the stored settings and hands them back
    /// unchanged, and asking the engine what it stored would agree with
    /// itself and prove nothing. This is how a card that is on screen but
    /// wired to nothing is told from one that works.
    ///
    /// Deliberately *not* via `readConversionFields`, which is the saving
    /// path and falls back to the stored value for a field left blank — the
    /// right rule for Apply and a useless one for a probe. Built this way
    /// the first time, it printed a correct-looking `quality=28` with the
    /// line that fills that box deleted. An empty widget prints as empty
    /// here, and an unselected list as `none`.
    var conversionText: String {
        func selection<T>(_ combo: UnsafeMutablePointer<GtkWidget>,
                          _ cases: [T], _ name: (T) -> String) -> String {
            let row = Int(gtk_combo_box_get_active(Gtk.comboBox(combo)))
            guard cases.indices.contains(row) else { return "none" }
            return name(cases[row])
        }
        let codec = selection(convertCodecCombo,
                              ConversionOptions.VideoCodec.allCases) { $0.rawValue }
        let preset = selection(convertPresetCombo,
                               ConversionOptions.Preset.allCases) { $0.rawValue }
        let audio = selection(convertAudioCombo,
                              ConversionOptions.AudioMode.allCases) { $0.rawValue }
        let height = selection(convertHeightCombo,
                               WebConversionSettings.offeredHeights) {
            $0.map(String.init) ?? "source"
        }
        return "codec=\(codec) quality=\(Gtk.text(of: convertQualityEntry)) "
            + "preset=\(preset) height=\(height) "
            + "audio=\(audio) "
            + "subtitles=\(Gtk.isChecked(convertSubtitlesCheck)) "
            + "ffmpeg=\(Gtk.text(of: ffmpegPathEntry))"
    }

    /// The media-server address as the widget reads it, for the smoke modes.
    var mediaServerText: String {
        Gtk.text(of: jellyfinURLEntry)
    }

    /// The estimate line under the conversion settings, read off the label.
    var estimateText: String {
        String(cString: gtk_label_get_text(Gtk.label(convertEstimate)))
    }

    // MARK: Driving the conversion panel from outside

    /// Opens the conversion panel, as the menu does.
    func openConverting() { open(convertDialog) }

    /// Opens one of the panels by name and hands it back, so `--screenshot`
    /// can render it.
    ///
    /// Most of this window's surface now lives behind the menu — settings,
    /// status, fetching, converting — and the only picture anything ever
    /// took was of the main window. A panel that came up blank, clipped or
    /// half-built would have been invisible to every check in CI.
    func panelNamed(_ name: String) -> UnsafeMutablePointer<GtkWidget>? {
        let panel: UnsafeMutablePointer<GtkWidget>
        switch name {
        case "settings": panel = settingsDialog
        case "status": panel = statusDialog
        case "fetch": panel = fetchDialog
        case "convert": panel = convertDialog
        default: return nil
        }
        open(panel)
        return panel
    }

    /// Presses "Leeren" in the history column.
    ///
    /// Blocks until the confirmation is answered, so a smoke mode has to
    /// arrange the answer before calling this — see `Gtk.answerDialog`.
    func pressClearHistory() { clearHistory() }

    /// Presses "Suchen".
    func pressFindConvertible() { findConvertible() }

    /// Presses "Konvertieren".
    func pressConvert() { convertTickedFiles() }

    /// Presses "Stopp".
    func pressStopConverting() { stopConverting() }

    /// How many rows the conversion list is drawing.
    var convertRowCount: Int { convertRows.count }

    /// The line beside Suchen, read off the label.
    var convertCountText: String {
        String(cString: gtk_label_get_text(Gtk.label(convertCountLabel)))
    }

    /// What the conversion list is showing, read off its own labels.
    ///
    /// Read as text and not as a row count because the fault worth catching
    /// is the empty list saying nothing at all: the panel shipped with its
    /// first refresh comparing an empty id list against an empty id list,
    /// deciding nothing had changed, and never building the empty state. It
    /// looked exactly like a working panel with no files in it, and the
    /// byte size of a screenshot cannot tell one missing sentence from a
    /// short one.
    var convertListTexts: [String] {
        convertNotes.map { String(cString: gtk_label_get_text(Gtk.label($0))) }
    }

    /// What the progress bar says, read off the bar.
    var convertBarText: String {
        guard let text = gtk_progress_bar_get_text(Gtk.progressBar(convertBar))
        else { return "" }
        return String(cString: text)
    }

    /// How many files pressing Konvertieren would hand to the engine.
    ///
    /// Worked out the same way the button does, not counted off the rows:
    /// the list is capped and a file past the cap is still in the run.
    var tickedConvertCount: Int { tickedConvertIDs.count }

    /// Presses one conversion row's tick box, as a click does.
    @discardableResult
    func pressConvertRowCheck(at index: Int) -> Bool {
        guard convertRows.indices.contains(index) else { return false }
        let check = convertRows[index].check
        gtk_toggle_button_set_active(Gtk.toggleButton(check),
                                     Gtk.isChecked(check) ? 0 : 1)
        return true
    }

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

    /// Whether Undo can be pressed at all.
    ///
    /// Read as a sensitivity and not as a snapshot field, because the fault
    /// was precisely that the engine knew it was working and the button did
    /// not. Asking the engine would agree with itself and prove nothing.
    var undoButtonIsPressable: Bool {
        gtk_widget_get_sensitive(undoButton) != 0
    }

    /// What the header says under the title, read back off the header bar.
    var subtitleText: String {
        guard let text = gtk_header_bar_get_subtitle(Gtk.headerBar(header))
        else { return "" }
        return String(cString: text)
    }

    /// Presses "Alles prüfen" in the status panel.
    func pressCheckEverything() { checkEverything() }

    /// Whether the buttons that must be reachable without opening anything
    /// really are on the main window.
    ///
    /// The send button was once built into a panel and became unreachable
    /// when that panel moved behind the menu. This guards against repeating
    /// that — and it had no reader at all until the conversion panel added
    /// five more buttons inside a panel, which is exactly when a guard like
    /// this stops being theoretical. It is printed by `--press-scan` and
    /// asserted in CI.
    ///
    /// Stop, Rename and Undo, because those are the three that answer "make
    /// it stop" and "put it back". `gtk_widget_get_toplevel` returns the
    /// widget itself when it has no toplevel ancestor, so an orphan fails
    /// here too.
    var urgentButtonsAreOnTheMainSurface: Bool {
        [stopScanButton, applyButton, undoButton].allSatisfy {
            gtk_widget_get_toplevel($0) == widget
        }
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
        // One command instead of N: the engine has a case for exactly this,
        // and it also says something in the footer. The widgets are set here
        // as well so the boxes change under the cursor rather than at the
        // next refresh, with the per-row reporting suppressed while they do.
        isSeedingRows = true
        for row in rowChecks { Gtk.setChecked(row.check, on) }
        isSeedingRows = false
        coordinator.submit(.setAllAccepted(on))
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
            stored
                ? Text.s("gespeichert — zum Ersetzen neu eingeben",
                         "stored — type a new one to replace it")
                : Text.s("keiner hinterlegt", "none stored")
        )

        let schedule = settings.schedule
        Gtk.setChecked(scheduleCheck, schedule.isEnabled)
        Gtk.setChecked(scheduleRenameCheck, schedule.alsoRename)
        Gtk.setText(of: scheduleTimeEntry,
                    String(format: "%02d:%02d", schedule.hour, schedule.minute))
        Gtk.setText(of: scheduleHoursEntry, String(schedule.everyHours))
        if let index = Schedule.Cadence.allCases.firstIndex(of: schedule.cadence) {
            gtk_combo_box_set_active(Gtk.comboBox(scheduleCadenceCombo), Int32(index))
        }
        Gtk.setText(scheduleSummary, ScheduleLine.describe(schedule, coordinator.snapshot))

        Gtk.setText(of: jellyfinURLEntry, settings.jellyfinBaseURL)

        let conversion = settings.conversion
        if let index = ConversionOptions.VideoCodec.allCases
            .firstIndex(of: conversion.videoCodec) {
            gtk_combo_box_set_active(Gtk.comboBox(convertCodecCombo), Int32(index))
        }
        Gtk.setText(of: convertQualityEntry, String(conversion.quality))
        if let index = ConversionOptions.Preset.allCases
            .firstIndex(of: conversion.preset) {
            gtk_combo_box_set_active(Gtk.comboBox(convertPresetCombo), Int32(index))
        }
        // A stored height the list does not offer — hand-edited, or from a
        // version that offered more — selects nothing rather than silently
        // becoming one of the five. Saving then leaves it alone, because the
        // merge only writes a field the widget actually changed.
        if let index = WebConversionSettings.offeredHeights
            .firstIndex(of: conversion.targetHeight) {
            gtk_combo_box_set_active(Gtk.comboBox(convertHeightCombo), Int32(index))
        }
        if let index = ConversionOptions.AudioMode.allCases
            .firstIndex(of: conversion.audioMode) {
            gtk_combo_box_set_active(Gtk.comboBox(convertAudioCombo), Int32(index))
        }
        Gtk.setChecked(convertSubtitlesCheck, conversion.stripSubtitles)
        Gtk.setText(of: ffmpegPathEntry, conversion.ffmpegPath)
    }

    /// Reads the conversion fields back out of the widgets.
    ///
    /// A quality that is not a number is kept as an impossible one rather
    /// than quietly becoming the default, for the same reason the schedule
    /// keeps an impossible hour: `problems()` then says so, and the user
    /// learns why nothing was saved instead of finding a number they never
    /// typed.
    private func readConversionFields(from current: WebConversionSettings)
        -> WebConversionSettings {
        var conversion = current
        conversion.stripSubtitles = Gtk.isChecked(convertSubtitlesCheck)
        conversion.ffmpegPath =
            Gtk.text(of: ffmpegPathEntry).trimmingCharacters(in: .whitespacesAndNewlines)

        let codec = Int(gtk_combo_box_get_active(Gtk.comboBox(convertCodecCombo)))
        if codec >= 0, codec < ConversionOptions.VideoCodec.allCases.count {
            conversion.videoCodec = ConversionOptions.VideoCodec.allCases[codec]
        }
        let preset = Int(gtk_combo_box_get_active(Gtk.comboBox(convertPresetCombo)))
        if preset >= 0, preset < ConversionOptions.Preset.allCases.count {
            conversion.preset = ConversionOptions.Preset.allCases[preset]
        }
        let audio = Int(gtk_combo_box_get_active(Gtk.comboBox(convertAudioCombo)))
        if audio >= 0, audio < ConversionOptions.AudioMode.allCases.count {
            conversion.audioMode = ConversionOptions.AudioMode.allCases[audio]
        }
        let height = Int(gtk_combo_box_get_active(Gtk.comboBox(convertHeightCombo)))
        if height >= 0, height < WebConversionSettings.offeredHeights.count {
            conversion.targetHeight = WebConversionSettings.offeredHeights[height]
        }

        let typed = Gtk.text(of: convertQualityEntry)
            .trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty {
            // Out of range on purpose when it is not a number: the engine
            // clamps 0...51, so -1 arrives as 0 and is visibly wrong rather
            // than invisibly plausible.
            conversion.quality = Int(typed) ?? -1
        }
        return conversion
    }

    /// The estimate line under the conversion settings.
    ///
    /// Built from the widgets rather than from the saved settings, so it
    /// answers "what will this do" before Apply is pressed. Recomputed on
    /// the refresh timer, which is cheap enough: four reads and a format.
    private func refreshConversionEstimate() {
        let typed = readConversionFields(from: coordinator.settings.conversion)
        // Through the initialiser, so the percentage is the one the engine
        // would really use: it clamps the quality the same way.
        let effective = WebConversionSettings(videoCodec: typed.videoCodec,
                                              quality: typed.quality,
                                              preset: typed.preset,
                                              targetHeight: typed.targetHeight,
                                              audioMode: typed.audioMode,
                                              stripSubtitles: typed.stripSubtitles)
        // Two numbers, not one, whenever the chosen resolution means
        // different things for different sources — which is most of the
        // time. A downscale saves the difference between the source and the
        // target, so "1080p" saves nothing from a 1080p file and three
        // quarters from a 4K one. The estimator silently assumed 1080 and
        // the line therefore printed the same 62 % for "keep the source
        // resolution", 2160p and 1080p alike: a setting that looked inert
        // and, for the 4K libraries it exists for, was wrong by a factor of
        // four. Naming the assumption is the only honest version of this
        // sentence, because nothing can probe a source here — no file has
        // been chosen yet.
        let normal = effective.estimatedSizePercent(forSourceHeight: 1080)
        let fourK = effective.estimatedSizePercent(forSourceHeight: 2160)
        let size = normal == fourK
            ? Text.s("Schätzung: etwa \(normal) % der ursprünglichen Größe.",
                     "Estimate: about \(normal) % of the original size.")
            : Text.s("Schätzung: etwa \(normal) % bei einer 1080p-Quelle, "
                         + "etwa \(fourK) % bei einer 4K-Quelle.",
                     "Estimate: about \(normal) % from a 1080p source, about "
                         + "\(fourK) % from a 4K source.")
        let usual = ConversionOptions.suggestedQuality(forHeight: effective.targetHeight)
        Gtk.setText(convertEstimate, size
            + Text.s(" Das Bild wird dabei: \(effective.qualityDescription). "
                         + "Bei dieser Auflösung ist \(usual) der übliche "
                         + "Qualitätswert; kleiner heißt besser und größer.",
                     " The picture comes out: \(effective.qualityDescription). "
                         + "At this resolution \(usual) is the usual quality "
                         + "value; lower means better and bigger."))
    }

    // MARK: Converting

    /// Looks for files that could be converted.
    ///
    /// Saves first, like `startDownload`: the search reads the library
    /// folders out of the settings, and searching the folders shown in the
    /// window beats searching the ones stored when it opened.
    private func findConvertible() {
        saveFolders()
        coordinator.submit(.findConvertible)
    }

    /// Starts converting what is ticked.
    private func convertTickedFiles() {
        // Built from what the engine currently offers, so an exclusion left
        // over from an earlier search cannot name a file that is no longer
        // on the list, and a file that is on the list cannot be missed
        // because no row was ever drawn for it.
        //
        // The engine says "nothing was ticked" for an empty set, which is
        // the right message, so this is not guarded here.
        coordinator.submit(.convertFiles(accepting: tickedConvertIDs))
    }

    /// The ticked candidates, worked out from the engine's list and the
    /// exclusions rather than from the rows: the list is capped at
    /// `visibleProposals` rows, and a file past the cap is still in the run.
    private var tickedConvertIDs: Set<UUID> {
        Set(coordinator.convertible
            .filter { !convertExcludedPaths.contains($0.source.path) }
            .map(\.id))
    }

    private func stopConverting() {
        coordinator.submit(.cancelConversions)
    }

    private func setAllConvertChecked(_ on: Bool) {
        convertExcludedPaths = on
            ? []
            : Set(coordinator.convertible.map(\.source.path))
        isSeedingRows = true
        for row in convertRows { Gtk.setChecked(row.check, on) }
        isSeedingRows = false
        refreshConvertCounts()
    }

    /// Rebuilds the conversion list when the engine's candidates change.
    ///
    /// The same shape as `refreshList`, and for the same reason: GTK rows
    /// are rebuilt only when the ids actually differ, or every refresh would
    /// destroy the widget under the user's cursor twice a second.
    private func refreshConvertList() {
        let candidates = coordinator.convertible
        let ids = candidates.map(\.id)
        guard ids != renderedConvertIDs else {
            refreshConvertCounts()
            return
        }
        renderedConvertIDs = ids

        isSeedingRows = true
        defer { isSeedingRows = false }
        for row in convertRowWidgets { gtk_widget_destroy(row) }
        convertRowWidgets = []
        convertNotes = []
        convertRows = []

        if candidates.isEmpty {
            let empty = Self.label(
                Text.s("Noch nichts gesucht — „Suchen“ drücken.",
                       "Nothing looked for yet — press “Look for files”."),
                classes: "mf-dim")
            gtk_label_set_xalign(Gtk.label(empty), 0.5)
            gtk_box_pack_start(Gtk.box(convertListColumn), empty, 0, 0, 0)
            convertRowWidgets = [empty]
            convertNotes = [empty]
        } else {
            for (index, candidate) in candidates.prefix(Self.visibleProposals)
                .enumerated() {
                let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10)!
                Styling.style(row, "mf-row")
                if index % 2 == 1 { Styling.style(row, "mf-row-alt") }

                let check = gtk_check_button_new()!
                let id = candidate.id
                let path = candidate.source.path
                Gtk.setChecked(check, !convertExcludedPaths.contains(path))
                Gtk.onToggled(check, self) { window in
                    guard !window.isSeedingRows else { return }
                    if Gtk.isChecked(check) {
                        window.convertExcludedPaths.remove(path)
                    } else {
                        window.convertExcludedPaths.insert(path)
                    }
                    window.refreshConvertCounts()
                }
                gtk_widget_set_valign(check, GTK_ALIGN_CENTER)
                gtk_box_pack_start(Gtk.box(row), check, 0, 0, 0)

                let name = Self.label(candidate.fileName, classes: "mf-from")
                gtk_label_set_ellipsize(Gtk.label(name), PANGO_ELLIPSIZE_MIDDLE)
                gtk_widget_set_tooltip_text(name, candidate.source.path)
                gtk_box_pack_start(Gtk.box(row), name, 1, 1, 0)

                // The size, because it is the one number that says how long
                // this will take and whether there is room for the output.
                let size = Self.label(candidate.readableSize, classes: "mf-dim")
                gtk_box_pack_end(Gtk.box(row), size, 0, 0, 0)

                gtk_box_pack_start(Gtk.box(convertListColumn), row, 0, 0, 0)
                convertRowWidgets.append(row)
                convertRows.append((id: id, check: check))
            }
            if candidates.count > Self.visibleProposals {
                let rest = candidates.count - Self.visibleProposals
                let more = Self.label(
                    Text.s("… und \(rest) weitere, hier nicht gezeichnet. Sie "
                               + "sind angehakt und werden mit konvertiert.",
                           "… and \(rest) more, not drawn here. They are ticked "
                               + "and will be converted with the rest."),
                    classes: "mf-dim")
                gtk_label_set_line_wrap(Gtk.label(more), 1)
                gtk_box_pack_start(Gtk.box(convertListColumn), more, 0, 0, 0)
                convertRowWidgets.append(more)
                convertNotes.append(more)
            }
        }
        gtk_widget_show_all(convertListColumn)
        refreshConvertCounts()
    }

    /// The line beside Suchen: how many were found, how many are ticked, and
    /// how much that is. Spelled out, because the whole point of the panel
    /// is to see what a run will chew through before starting it.
    private func refreshConvertCounts() {
        let candidates = coordinator.convertible
        guard !candidates.isEmpty else {
            Gtk.setText(convertCountLabel, "")
            return
        }
        let ticked = candidates.filter {
            !convertExcludedPaths.contains($0.source.path)
        }
        let bytes = ticked.reduce(Int64(0)) { $0 + $1.byteSize }
        let size = ConversionCandidate.readableSize(ofBytes: bytes)
        Gtk.setText(convertCountLabel, Text.s(
            "\(candidates.count) gefunden · \(ticked.count) angehakt · \(size)",
            "\(candidates.count) found · \(ticked.count) ticked · \(size)"))
    }

    /// Empties the history, after asking.
    ///
    /// It asks because this is not only the list on the right: the engine's
    /// `clearHistory` empties the rename journal too, so the undo steps go
    /// with it. A plain "Leeren" button beside a list of past renames does
    /// not look like it takes Rückgängig away, and that is the one thing
    /// standing between a wrong rename and a lost library.
    private func clearHistory() {
        // Named, not implied. "The undo steps go too" is easy to skim past;
        // "3 Schritte, die danach weg sind" is a number the reader has to
        // look at. With nothing to undo the sentence says so instead of
        // threatening a loss that is not there.
        let steps = coordinator.snapshot.undoableBatches
        let cost = steps == 0
            ? Text.s("Im Moment gibt es nichts rückgängig zu machen.",
                     "There is nothing to undo at the moment.")
            : Text.s("\(steps) Schritt\(steps == 1 ? "" : "e") lassen sich "
                         + "danach nicht mehr zurücknehmen.",
                     "\(steps) step\(steps == 1 ? "" : "s") could not be "
                         + "taken back afterwards.")
        guard Gtk.confirm(
            over: widget,
            heading: Text.s("Verlauf wirklich leeren?",
                            "Clear the history?"),
            body: Text.s("Damit gehen auch die Rückgängig-Schritte weg. ",
                         "The undo steps go with it. ")
                + cost
                + Text.s(" Die Dateien selbst bleiben, wo sie sind.",
                         " The files themselves stay where they are."),
            confirm: Text.s("Leeren", "Clear"),
            cancel: Text.s("Abbrechen", "Cancel")
        ) else { return }
        coordinator.submit(.clearHistory)
    }

    /// Asks the media server whether it is there.
    private func testMediaServer() {
        // Saved first, so the test uses the address in the field rather than
        // whatever was stored when the window opened. The same reason
        // `startDownload` saves first.
        saveFolders()
        coordinator.submit(.testJellyfinConnection)
    }

    // MARK: Reading the engine back

    /// Pulls the current state into the window. Called on a timer because the
    /// coordinator works on its own queue and has no way to call back into
    /// GTK, which may only be touched from the main thread.
    func refresh() {
        let state = coordinator.snapshot

        // What it is doing now outranks how the last thing ended.
        //
        // `hasError` used to be tested first, and it is sticky: nothing
        // clears it on entry, only the end of the next run recomputes it. So
        // a scan started after a partly failed rename showed "Mit Fehlern
        // beendet" for its whole duration instead of progress — and the
        // likeliest route to the Undo button is "some files failed, so I
        // will undo", which is exactly the case where the user most needs
        // to see that something is happening.
        let subtitle: String
        if state.isWorking {
            // Two kinds of working. `busy` is set by the handlers that
            // report progress; `isWorking` also covers the four commands
            // that hold the engine's serial queue without ever setting it —
            // Rückgängig, both connection tests, and Alles prüfen. A probe
            // against an unreachable server holds the queue for the
            // 30-second request timeout, and Alles prüfen runs two of them.
            if state.busy {
                subtitle = (state.convertStatus ?? Text.s("Arbeitet", "Working"))
                    + " · \(state.activePercent) %"
            } else {
                // No percentage: `activePercent` falls back to
                // `renameProgress`, which after a finished rename is 1 — so
                // a probe would announce "Arbeitet · 100 %" of work that
                // reports no progress at all.
                subtitle = Text.s("Arbeitet …", "Working…")
            }
        } else if state.hasError {
            subtitle = Text.s("Mit Fehlern beendet", "Finished with errors")
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
        // The buttons that START work are gated on `isWorking`, not on
        // `busy`. They were already gated — this only extends the gate to
        // the four commands that hold the queue without setting `busy`.
        //
        // Undo is the one that matters, and it is not cosmetic. `undoLast`
        // never sets `busy`, so the button stayed live for the whole
        // duration of an undo. The queue is serial, so a second press waited
        // and then ran — but by then `finishUndo` had removed the
        // transaction the first press worked from, so `journal.last` was the
        // next older one. The second press therefore did not harmlessly
        // repeat: it reversed a batch the user never asked to reverse. On a
        // slow cross-volume move the window invited that press twice a
        // second while the header said "Bereit".
        //
        // The stop buttons are deliberately NOT gated: a button whose whole
        // job is to interrupt the work must be pressable while the work is
        // running.
        gtk_widget_set_sensitive(scanButton, state.isWorking ? 0 : 1)
        gtk_widget_set_sensitive(stopScanButton, state.busy ? 1 : 0)
        gtk_widget_set_sensitive(applyButton,
                                 (!rowChecks.isEmpty && !state.isWorking) ? 1 : 0)
        gtk_widget_set_sensitive(undoButton, state.isWorking ? 0 : 1)
        gtk_widget_set_sensitive(downloadButton,
                                 (!hasSource || state.isWorking) ? 0 : 1)
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
        // The schedule line too, so "Nächster Lauf" stays true while the
        // window is open rather than being whatever it was when the settings
        // were last loaded.
        Gtk.setText(scheduleSummary,
                    ScheduleLine.describe(coordinator.settings.schedule, state))
        refreshConversionEstimate()

        // The conversion panel. Driven from the same timer as everything
        // else, so it is live whether or not it happens to be open.
        gtk_widget_set_sensitive(convertFindButton, state.isWorking ? 0 : 1)
        gtk_widget_set_sensitive(convertRunButton,
                                 (!convertRows.isEmpty && !state.isWorking) ? 1 : 0)
        gtk_widget_set_sensitive(convertStopButton, state.converting ? 1 : 0)
        if state.converting {
            let detail = [state.currentFile, state.convertDetail]
                .compactMap { $0 }.joined(separator: " · ")
            Gtk.setProgress(convertBar, fraction: state.convertProgress,
                            text: state.pendingConversions > 0
                                ? detail + Text.s(" · noch \(state.pendingConversions)",
                                                  " · \(state.pendingConversions) to go")
                                : detail)
        } else if let status = state.convertStatus {
            // The engine is doing something it has no percentage for.
            gtk_progress_bar_pulse(Gtk.progressBar(convertBar))
            gtk_progress_bar_set_show_text(Gtk.progressBar(convertBar), 1)
            gtk_progress_bar_set_text(Gtk.progressBar(convertBar), status)
        } else {
            Gtk.setProgress(convertBar, fraction: 0,
                            text: Text.s("Keine Konvertierung",
                                         "Nothing converting"))
        }
        refreshConvertList()

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
        // One read, three answers. It used to ask three times, and each ask
        // is a `queue.sync` onto the log's own queue — so the drawing thread
        // waited on that queue three times every 500 ms, and could wait on
        // a file write going on there. The three snapshots could also
        // disagree with each other: "42 entries · 43 with an error" was
        // expressible.
        let all = coordinator.logEntries
        let entries = Array(all.reversed().prefix(Self.visibleLogEntries))
        let ids = entries.map(\.id)
        guard ids != renderedLogIDs else { return }
        renderedLogIDs = ids

        for row in logWidgets { gtk_widget_destroy(row) }
        logWidgets = []

        let total = all.count
        let failures = all.reduce(into: 0) { $0 += $1.status == .failure ? 1 : 0 }
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

    /// How many proposal rows are drawn.
    ///
    /// The log beside this was capped at 200 for the reason above, and the
    /// proposal list — three to four times the widgets per row, and up to
    /// the engine's own 5,000-file ceiling — had no cap at all. Each row is
    /// a box, a check button, an inner box, two or three ellipsized labels
    /// with their own Pango layouts, sometimes a deletion note and a sample
    /// note, and an icon button that is itself a button plus an image plus
    /// an icon-theme lookup. The comment at the list's own construction
    /// names the threshold — "it will have to become a TreeView if these
    /// lists reach the thousands" — and nothing enforced it.
    ///
    /// 500 rather than 200: this list is the thing the user is here to
    /// read, and scrolling through 500 is a reasonable amount of reading.
    /// The rest are in the plan and are renamed with them; the engine owns
    /// the tick state, so a row that is not drawn is not a row that is not
    /// renamed.
    static let visibleProposals = 500

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
        case .deleted: return Text.s("gelöscht", "deleted")
        case .undone: return Text.s("rückgängig", "undone")
        }
    }

    private static func statusClass(_ status: RenameLogEntry.Status) -> String {
        switch status {
        case .success, .converted, .sent, .downloaded: return "mf-ok"
        case .failure: return "mf-fail"
        // Dim rather than green: it happened as planned, but "done" is the
        // wrong colour for a file that is gone.
        case .skipped, .deleted, .undone: return "mf-skip"
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

        // Nothing built in here is a press by the user.
        isSeedingRows = true
        defer { isSeedingRows = false }
        for row in rowWidgets { gtk_widget_destroy(row) }
        rowWidgets = []
        rowDestinations = []
        rowDeletionNotes = []
        rowKeptNotes = []
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
            for (index, item) in items.prefix(Self.visibleProposals).enumerated() {
                let built = proposalRow(item, banded: index % 2 == 1)
                gtk_box_pack_start(Gtk.box(listColumn), built.row, 0, 0, 0)
                rowWidgets.append(built.row)
                rowChecks.append((id: item.id, check: built.check))
                rowDestinations.append(built.destination)
                if let note = built.deletionNote { rowDeletionNotes.append(note) }
                if let note = built.keptNote { rowKeptNotes.append(note) }
            }
            if items.count > Self.visibleProposals {
                // Said, because a list that stops at 500 with nothing to
                // explain it looks like 500 files were found. These are in
                // the plan and will be renamed: the engine owns the ticks
                // now, so Umbenennen does not depend on a row existing.
                let rest = items.count - Self.visibleProposals
                let more = Self.label(
                    Text.s("… und \(rest) weitere, hier nicht gezeichnet. Sie sind "
                               + "im Plan und werden mit umbenannt.",
                           "… and \(rest) more, not drawn here. They are in the "
                               + "plan and will be renamed with the rest."),
                    classes: "mf-dim")
                gtk_label_set_line_wrap(Gtk.label(more), 1)
                gtk_box_pack_start(Gtk.box(listColumn), more, 0, 0, 0)
                rowWidgets.append(more)
            }
        }
        // New widgets start hidden; the window was already shown.
        gtk_widget_show_all(listColumn)
    }

    /// One proposal: what the file is called now, and what it would be called.
    ///
    /// Nothing here says the rename has happened — the list is a preview, and
    /// the wording has to keep saying so until a button is pressed.
    /// An instance method, not a static one: the folder button has to carry
    /// this row's path into its handler, and the handler needs the window to
    /// put a failure somewhere the user will see it.
    private func proposalRow(_ item: RenameItem, banded: Bool)
        -> (row: UnsafeMutablePointer<GtkWidget>,
            destination: UnsafeMutablePointer<GtkWidget>,
            check: UnsafeMutablePointer<GtkWidget>,
            deletionNote: UnsafeMutablePointer<GtkWidget>?,
            keptNote: UnsafeMutablePointer<GtkWidget>?) {
        var deletionNote: UnsafeMutablePointer<GtkWidget>?
        var keptNote: UnsafeMutablePointer<GtkWidget>?
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10)!
        Styling.style(row, "mf-row")
        if banded { Styling.style(row, "mf-row-alt") }

        // Seeded from the engine, and reported back to it.
        //
        // The tick used to live nowhere but this widget. `refreshList`
        // destroys every row whenever the id list changes — a drop, a watch
        // poll, a scheduled scan — and re-seeded each box from `isAccepted`,
        // which nothing could ever set to false because the two commands for
        // it had no sender since the web front end was removed. So an
        // exclusion was silently discarded and the next press of Umbenennen
        // moved the files the user had taken out, while the counts row went
        // on printing "20 proposals · 20 ticked" with three boxes clear.
        let check = gtk_check_button_new()!
        let id = item.id
        Gtk.setChecked(check, item.isAccepted)
        Gtk.onToggled(check, self) { window in
            // Not while the list is being rebuilt: set_active emits
            // "toggled" too, so seeding the boxes would report every row
            // back to the engine as if it had just been pressed.
            guard !window.isSeedingRows else { return }
            window.coordinator.submit(.setAccepted(id, Gtk.isChecked(check)))
        }
        gtk_widget_set_valign(check, GTK_ALIGN_CENTER)
        gtk_box_pack_start(Gtk.box(row), check, 0, 0, 0)

        let text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        let from = Self.label(item.originalFileName, classes: "mf-from")
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
        let to = Self.label("→ " + destination, classes: "mf-to")
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
            let here = Self.label(
                Text.s("Bleibt neben der Datei — kein Bibliotheksordner gesetzt",
                       "Stays next to the file — no library folder is set"),
                classes: "mf-warn")
            gtk_label_set_ellipsize(Gtk.label(here), PANGO_ELLIPSIZE_END)
            gtk_box_pack_start(Gtk.box(text), here, 0, 0, 0)
        }

        // Said in the row, not only in the history afterwards. This is the
        // one thing the program destroys, so it is named before the button
        // that does it is pressed.
        if !item.companionDeletions.isEmpty {
            let names = item.companionDeletions.map(\.lastPathComponent)
                .joined(separator: ", ")
            let note = Self.label(
                Text.s("Wird gelöscht: \(names) — Infodatei der Release-Gruppe, "
                           + "die Jellyfin für eigene Metadaten halten würde",
                       "Will be deleted: \(names) — the release group's note, "
                           + "which Jellyfin would mistake for its own metadata"),
                classes: "mf-warn")
            gtk_label_set_ellipsize(Gtk.label(note), PANGO_ELLIPSIZE_END)
            gtk_widget_set_tooltip_text(note, names)
            gtk_box_pack_start(Gtk.box(text), note, 0, 0, 0)
            deletionNote = note
        }

        // The other half of the same sentence. Somebody who has just read
        // that .nfo files get deleted is entitled to see, in the same row,
        // that their own metadata is not one of them.
        if !item.companionKeptNotes.isEmpty {
            let names = item.companionKeptNotes.map(\.lastPathComponent)
                .joined(separator: ", ")
            let kept = Self.label(
                Text.s("Bleibt liegen: \(names) — Jellyfins eigene Metadaten",
                       "Stays where it is: \(names) — Jellyfin's own metadata"),
                classes: "mf-dim")
            gtk_label_set_ellipsize(Gtk.label(kept), PANGO_ELLIPSIZE_END)
            gtk_widget_set_tooltip_text(kept, names)
            gtk_box_pack_start(Gtk.box(text), kept, 0, 0, 0)
            keptNote = kept
        }

        // The sample is not deleted and not moved, so the row says where it
        // stays. Computed from the companions rather than carried on the
        // item: the engine needs nothing for a file it does not touch.
        let samples = item.mediaFile.companions
            .filter { $0.role == .sample }
            .map(\.url.lastPathComponent)
        if !samples.isEmpty {
            let kept = Self.label(
                Text.s("Bleibt liegen: \(samples.joined(separator: ", ")) "
                           + "— Ausschnitt, nicht der Film",
                       "Left where it is: \(samples.joined(separator: ", ")) "
                           + "— an excerpt, not the film"),
                classes: "mf-dim")
            gtk_label_set_ellipsize(Gtk.label(kept), PANGO_ELLIPSIZE_END)
            gtk_box_pack_start(Gtk.box(text), kept, 0, 0, 0)
        }

        if let conflict = item.conflict {
            let warning = Self.label(Self.conflictText(conflict), classes: "mf-warn")
            gtk_box_pack_start(Gtk.box(text), warning, 0, 0, 0)
        }
        gtk_box_pack_start(Gtk.box(row), text, 1, 1, 0)

        // Opens the destination in whatever file manager the desktop uses.
        // Before the rename that folder does not exist yet, so what opens is
        // the deepest folder on the way that does — which is where the file
        // is now, and a true answer rather than a button that does nothing.
        let revealButton = gtk_button_new_from_icon_name("folder-open-symbolic",
                                                         GTK_ICON_SIZE_BUTTON)!
        gtk_button_set_relief(Gtk.button(revealButton), GTK_RELIEF_NONE)
        gtk_widget_set_valign(revealButton, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(revealButton,
                                    Text.s("Ordner öffnen", "Open the folder"))
        let folder = item.primaryDestination.deletingLastPathComponent()
        Gtk.onClick(revealButton, self) { $0.reveal(folder) }
        gtk_box_pack_end(Gtk.box(row), revealButton, 0, 0, 0)

        return (row, destination: to, check, deletionNote: deletionNote,
                keptNote: keptNote)
    }

    /// Hands a folder to the desktop's file manager.
    ///
    /// `g_filename_to_uri` rather than "file://" + path: a path with a space
    /// or an umlaut in it — which a film called "Der Name der Rose" certainly
    /// has — is not a URI until it is escaped, and getting that wrong opens
    /// nothing with no explanation.
    func reveal(_ folder: URL) {
        guard let existing = FolderReveal.nearestExistingDirectory(for: folder) else {
            Gtk.setText(resultLabel, Text.s(
                "Dieser Ordner lässt sich nicht öffnen: \(folder.path)",
                "That folder cannot be opened: \(folder.path)"))
            return
        }
        var error: UnsafeMutablePointer<GError>?
        guard let uri = g_filename_to_uri(existing.path, nil, &error) else {
            if let error { g_error_free(error) }
            Gtk.setText(resultLabel, Text.s(
                "Dieser Ordner lässt sich nicht öffnen: \(existing.path)",
                "That folder cannot be opened: \(existing.path)"))
            return
        }
        defer { g_free(uri) }
        // Timestamp 0 is "now". Passing a real event time would be better
        // form, but a button handler has none to hand and every desktop
        // accepts 0.
        if gtk_show_uri_on_window(Gtk.window(widget), uri, 0, &error) == 0 {
            let detail = error.flatMap { String(cString: $0.pointee.message) } ?? ""
            if let error { g_error_free(error) }
            // In the footer rather than swallowed: a file manager that is not
            // installed, or a sandbox that forbids this, is worth saying.
            Gtk.setText(resultLabel, Text.s(
                "Der Ordner ließ sich nicht öffnen: \(detail)",
                "The folder could not be opened: \(detail)"))
        }
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
