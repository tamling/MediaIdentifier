import Foundation
import SwiftUI
import AppKit
import MediaIdentifierCore

/// Thread-safe holder for the currently running FFmpeg process so it can be
/// terminated (Stop / remove current) from the main actor.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    func set(_ p: Process?) { lock.lock(); process = p; lock.unlock() }
    func terminate() { lock.lock(); process?.terminate(); lock.unlock() }
}

/// Sidebar destinations (matches the design: Warteschlange / Filme / Serien /
/// Konvertieren / Protokoll).
enum SidebarSection: Hashable {
    case overview
    case queue
    case movies
    case series
    case convert
    case watch
    case log
}

/// Filter for the consolidated queue (Queue/Movies/Series were merged).
enum LibraryFilter: String, CaseIterable {
    case all = "All"
    case movies = "Movies"
    case series = "Series"
}

/// Which settings group to reveal/highlight when opening Settings.
enum SettingsFocus {
    case naming
    case identification
    case server
}

/// Display status for a queued item (matches the design's status pills).
enum ItemStatus {
    case ready      // Bereit
    case conflict   // Konflikt
    case done       // Umbenannt
    case skipped    // Übersprungen
}

/// Central observable view model that wires the Core engine to the UI.
@MainActor
final class AppState: ObservableObject {
    // Preview / plan (FR8).
    @Published var items: [RenameItem] = []

    // Navigation. Start on the drag-and-drop queue; Übersicht is available in
    // the sidebar.
    @Published var section: SidebarSection = .queue
    @Published var showingSettings = false
    /// Sort the preview by show → season → episode (movies by title).
    @Published var sortByShow = true
    /// Filter the preview list by file/show name.
    @Published var searchText = ""
    /// Hide already-renamed rows so the working set stays focused.
    @Published var hideCompleted = false
    /// Filter the consolidated queue by media kind (All / Movies / Series).
    @Published var libraryFilter: LibraryFilter = .all
    /// Set when the user opens Settings for a specific area, to highlight it.
    @Published var settingsFocus: SettingsFocus?

    /// Opens Settings focused on a specific group (used by Overview "Set up").
    func openSettings(_ focus: SettingsFocus) {
        settingsFocus = focus
        showingSettings = true
    }

    // Settings.
    @Published var namingOptions: NamingOptions = .default { didSet { rebuildPlan() } }
    @Published var conflictPolicy: ConflictPolicy = .ask

    // Free output folder for renaming (FR18). When off, files are renamed in
    // place relative to each file's own folder (default). When on, the whole
    // Jellyfin layout is written under the chosen folder.
    @Published var outputToFolder = false {
        didSet { UserDefaults.standard.set(outputToFolder, forKey: Keys.outputToFolder); rebuildPlan() }
    }
    @Published var outputFolderPath = "" {
        didSet { UserDefaults.standard.set(outputFolderPath, forKey: Keys.outputFolderPath); rebuildPlan() }
    }

    // Final move into a library (movies always; series only when the season is
    // complete). Off by default.
    @Published var moveToLibrary = false {
        didSet { UserDefaults.standard.set(moveToLibrary, forKey: Keys.moveToLibrary); rebuildPlan() }
    }
    @Published var libraryFolderPath = "" {
        didSet { UserDefaults.standard.set(libraryFolderPath, forKey: Keys.libraryPath); rebuildPlan() }
    }

    // Online metadata lookup (FR3). Disabled by default to stay fully local (FR18).
    @Published var onlineLookupEnabled = false {
        didSet { UserDefaults.standard.set(onlineLookupEnabled, forKey: Keys.onlineLookup) }
    }
    @Published var tmdbAPIKey = "" {
        didSet { KeychainStore.set(tmdbAPIKey, for: Keys.tmdbKey) }
    }
    @Published var isLookingUp = false

    // Read-only status web page (FR20). Lets external monitors like Uptime Kuma
    // poll progress and notify when a run finishes. Off by default.
    @Published var webEnabled = false {
        didSet { UserDefaults.standard.set(webEnabled, forKey: Keys.webEnabled); restartWebServer() }
    }
    @Published var webPort = 8765 {
        didSet { UserDefaults.standard.set(webPort, forKey: Keys.webPort); restartWebServer() }
    }
    /// When true, the status server binds to 127.0.0.1 only (not the LAN).
    @Published var webLocalOnly = false {
        didSet { UserDefaults.standard.set(webLocalOnly, forKey: Keys.webLocalOnly); restartWebServer() }
    }
    private let webServer = StatusWebServer()
    private var webTimer: Timer?
    /// Whether the most recent run ended with failures (drives /healthz).
    private var lastRunHadError = false

    // Jellyfin library connector (FR20). After a successful rename/move, ask the
    // local Jellyfin server to rescan so the files are exported into the library
    // automatically.
    @Published var jellyfinEnabled = false {
        didSet { UserDefaults.standard.set(jellyfinEnabled, forKey: Keys.jellyfinEnabled) }
    }
    @Published var jellyfinServerURL = "" {
        didSet { UserDefaults.standard.set(jellyfinServerURL, forKey: Keys.jellyfinServer) }
    }
    @Published var jellyfinAPIKey = "" {
        didSet { KeychainStore.set(jellyfinAPIKey, for: Keys.jellyfinKey) }
    }
    @Published var jellyfinTestResult: String?

    // On-device Apple Intelligence identification (FR3, local — FR18).
    @Published var useAppleIntelligence = false {
        didSet { UserDefaults.standard.set(useAppleIntelligence, forKey: Keys.useAI) }
    }

    // Embedded container tags (FR3, local).
    @Published var useEmbeddedMetadata = false {
        didSet { UserDefaults.standard.set(useEmbeddedMetadata, forKey: Keys.useEmbedded) }
    }

    // Local offline title database (FR3, local after one-time download).
    @Published var useLocalDatabase = false {
        didSet { UserDefaults.standard.set(useLocalDatabase, forKey: Keys.useLocalDB) }
    }
    @Published var localDatabasePath = "" {
        didSet { UserDefaults.standard.set(localDatabasePath, forKey: Keys.localDBPath) }
    }
    @Published private(set) var localDatabaseCount = 0
    @Published private(set) var isLoadingDatabase = false
    @Published var databaseError: String?
    private var localDatabase: LocalTitleDatabase?

    // Conversion options (FR16/FR17 scaffold).
    @Published var conversionOptions = ConversionOptions()
    // Conversion queue & progress (FR16). convertFiles is the live pending
    // queue; currentConvert is the file being processed right now.
    @Published var convertFiles: [URL] = []
    @Published var currentConvert: URL?
    @Published var isConverting = false
    @Published var convertProgress: Double = 0
    @Published var convertStatus: String?
    @Published var convertDetail: String?
    @Published private(set) var convertLog: [String] = []
    private var cancelRequested = false
    private var convDone = 0
    private var convFailed = 0
    private let processBox = ProcessBox()
    private var convertSizes: [URL: Int64] = [:]

    // Watch folder (FR20). Auto-imports (and optionally auto-renames) finished
    // downloads dropped into a chosen folder.
    @Published var watchEnabled = false {
        didSet {
            UserDefaults.standard.set(watchEnabled, forKey: Keys.watchEnabled)
            restartWatch()
        }
    }
    @Published var watchAutoRename = true {
        didSet { UserDefaults.standard.set(watchAutoRename, forKey: Keys.watchAuto) }
    }
    @Published var watchFolderPath = "" {
        didSet { UserDefaults.standard.set(watchFolderPath, forKey: Keys.watchPath) }
    }
    @Published private(set) var watchActivity: [String] = []
    private let watchScanner = WatchFolderScanner()
    private var watchTimer: Timer?

    // Interactive conflict resolution (FR11, "Ask"). Non-empty drives a sheet.
    @Published var conflictsToResolve: [RenameItem] = []

    // Progress / status (FR19).
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var lastResult: String?
    @Published var didUndo = false

    // Log (FR12, FR19).
    @Published private(set) var logEntries: [RenameLogEntry] = []
    @Published private(set) var canUndo = false

    /// Source paths of items that have been successfully renamed in this session.
    @Published private var completed: Set<String> = []

    private let scanner = MediaScanner()
    private let log = RenameLog()
    private let journal = RenameJournal()

    private enum Keys {
        static let onlineLookup = "onlineLookupEnabled"
        static let tmdbKey = "tmdbAPIKey"
        static let watchEnabled = "watchEnabled"
        static let watchAuto = "watchAutoRename"
        static let watchPath = "watchFolderPath"
        static let useAI = "useAppleIntelligence"
        static let useEmbedded = "useEmbeddedMetadata"
        static let useLocalDB = "useLocalDatabase"
        static let localDBPath = "localDatabasePath"
        static let moveToLibrary = "moveToLibrary"
        static let libraryPath = "libraryFolderPath"
        static let outputToFolder = "outputToFolder"
        static let outputFolderPath = "outputFolderPath"
        static let jellyfinEnabled = "jellyfinEnabled"
        static let jellyfinServer = "jellyfinServerURL"
        static let jellyfinKey = "jellyfinAPIKey"
        static let webEnabled = "webEnabled"
        static let webPort = "webPort"
        static let webLocalOnly = "webLocalOnly"
        static let ffmpegPath = "customFFmpegPath"
    }

    /// Original scanned media, kept so the plan can be rebuilt when settings change.
    private var scannedFiles: [MediaFile] = []

    init() {
        logEntries = log.entries
        canUndo = journal.canUndo
        onlineLookupEnabled = UserDefaults.standard.bool(forKey: Keys.onlineLookup)
        // API key lives in the Keychain. Migrate any legacy UserDefaults value.
        let storedKey = KeychainStore.get(Keys.tmdbKey)
        if storedKey.isEmpty, let legacy = UserDefaults.standard.string(forKey: Keys.tmdbKey), !legacy.isEmpty {
            KeychainStore.set(legacy, for: Keys.tmdbKey)
            UserDefaults.standard.removeObject(forKey: Keys.tmdbKey)
            tmdbAPIKey = legacy
        } else {
            tmdbAPIKey = storedKey
        }
        useAppleIntelligence = UserDefaults.standard.bool(forKey: Keys.useAI)
        useEmbeddedMetadata = UserDefaults.standard.bool(forKey: Keys.useEmbedded)
        useLocalDatabase = UserDefaults.standard.bool(forKey: Keys.useLocalDB)
        localDatabasePath = UserDefaults.standard.string(forKey: Keys.localDBPath) ?? ""
        moveToLibrary = UserDefaults.standard.bool(forKey: Keys.moveToLibrary)
        libraryFolderPath = UserDefaults.standard.string(forKey: Keys.libraryPath) ?? ""
        outputToFolder = UserDefaults.standard.bool(forKey: Keys.outputToFolder)
        outputFolderPath = UserDefaults.standard.string(forKey: Keys.outputFolderPath) ?? ""
        jellyfinEnabled = UserDefaults.standard.bool(forKey: Keys.jellyfinEnabled)
        jellyfinServerURL = UserDefaults.standard.string(forKey: Keys.jellyfinServer) ?? ""
        jellyfinAPIKey = KeychainStore.get(Keys.jellyfinKey)
        webPort = UserDefaults.standard.object(forKey: Keys.webPort) as? Int ?? 8765
        webLocalOnly = UserDefaults.standard.bool(forKey: Keys.webLocalOnly)
        webEnabled = UserDefaults.standard.bool(forKey: Keys.webEnabled)
        customFFmpegPath = UserDefaults.standard.string(forKey: Keys.ffmpegPath) ?? ""
        if useLocalDatabase, !localDatabasePath.isEmpty { loadDatabase() }
        watchAutoRename = UserDefaults.standard.object(forKey: Keys.watchAuto) as? Bool ?? true
        watchFolderPath = UserDefaults.standard.string(forKey: Keys.watchPath) ?? ""
        watchEnabled = UserDefaults.standard.bool(forKey: Keys.watchEnabled)
        // didSet does not fire during init, so start the watcher explicitly.
        restartWatch()
        restartWebServer()
    }

    // MARK: Status web server (FR20)

    /// Hostname-based URL shown in Settings (reachable on the LAN via mDNS).
    var webURL: String {
        let host = webLocalOnly ? "localhost" : ProcessInfo.processInfo.hostName
        return "http://\(host):\(webPort)/"
    }

    private func restartWebServer() {
        webTimer?.invalidate()
        webTimer = nil
        webServer.stop()
        guard webEnabled else { return }
        guard webServer.start(port: webPort, localOnly: webLocalOnly) else {
            lastResult = "Status web page: port \(webPort) could not be opened."
            return
        }
        publishStatus()
        // Refresh the served snapshot once a second while enabled.
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.publishStatus() }
        }
        webTimer = timer
    }

    private func publishStatus() {
        guard webEnabled else { return }
        webServer.update(StatusSnapshot(
            updated: Date(),
            busy: isProcessing || isConverting,
            renaming: isProcessing,
            renameProgress: progress,
            converting: isConverting,
            convertProgress: convertProgress,
            currentFile: currentConvert?.lastPathComponent,
            convertStatus: convertStatus,
            convertDetail: convertDetail,
            pendingConversions: convertFiles.count,
            totalItems: items.count,
            ready: readyCount,
            done: doneCount,
            lastResult: lastResult,
            watchActive: watchActive,
            jellyfinConfigured: jellyfinConfigured,
            hasError: lastRunHadError
        ))
    }

    // MARK: Watch folder (FR20)

    var watchFolderURL: URL? {
        watchFolderPath.isEmpty ? nil : URL(fileURLWithPath: watchFolderPath)
    }

    func setWatchFolder(_ url: URL) {
        watchFolderPath = url.path
        watchScanner.reset()
        restartWatch()
    }

    private func restartWatch() {
        watchTimer?.invalidate()
        watchTimer = nil
        guard watchEnabled, let folder = watchFolderURL else { return }
        watchScanner.reset()
        logActivity("Monitoring started: \(folder.lastPathComponent)")
        let timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.pollWatch() }
        }
        watchTimer = timer
        // Run an immediate first poll so existing files are picked up promptly.
        pollWatch()
    }

    private func pollWatch() {
        guard watchEnabled, let folder = watchFolderURL else { return }
        let found = watchScanner.poll(directory: folder)
        guard !found.isEmpty else { return }
        let names = found.map { $0.lastPathComponent }.joined(separator: ", ")
        logActivity("\(found.count) new file(s) detected: \(names)")
        importURLs(found)
        if watchAutoRename {
            logActivity("Automatic renaming started …")
            runExecution(resolutions: [:])
        }
    }

    private func logActivity(_ message: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        watchActivity.insert("\(stamp)  \(message)", at: 0)
        if watchActivity.count > 100 { watchActivity.removeLast() }
    }

    private var namer: JellyfinNamer { JellyfinNamer(options: namingOptions) }
    private var planner: RenamePlanner { RenamePlanner(namer: namer) }

    private var outputRoot: URL? {
        guard outputToFolder, !outputFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: outputFolderPath)
    }

    var libraryRoot: URL? {
        guard moveToLibrary, !libraryFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: libraryFolderPath)
    }

    func setLibraryFolder(_ url: URL) { libraryFolderPath = url.path }
    func setOutputFolder(_ url: URL) { outputFolderPath = url.path }

    private func sourcePath(_ item: RenameItem) -> String {
        item.mediaFile.url.standardizedFileURL.path
    }

    var canLookUpOnline: Bool {
        onlineLookupEnabled && !tmdbAPIKey.isEmpty && !scannedFiles.isEmpty
    }

    // MARK: Import (FR1, FR10)

    func importURLs(_ urls: [URL]) {
        let newFiles = scanner.scan(urls: urls)
        var existing = Set(scannedFiles.map { $0.url.standardizedFileURL.path })
        for file in newFiles where existing.insert(file.url.standardizedFileURL.path).inserted {
            scannedFiles.append(file)
        }
        didUndo = false
        rebuildPlan()
        // Run the configured identification chain (embedded tags → local DB →
        // Apple Intelligence → TMDb). All but TMDb are fully local (FR18).
        if let provider = currentEnrichmentProvider() {
            enrich(with: provider)
        }
    }

    // MARK: Finder & organising

    /// Reveals the item in Finder — the renamed file once done, otherwise the
    /// source — so clicking a result opens its folder.
    func revealInFinder(_ item: RenameItem) {
        let url = status(for: item) == .done ? item.primaryDestination : item.mediaFile.url
        let target = FileManager.default.fileExists(atPath: url.path)
            ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// "Aufräumen": pick folder(s) and import them so their contents are sorted
    /// into the Jellyfin layout (Show/Season XX, Movie (Year)). The Season split
    /// is produced by `JellyfinNamer`; ensure movie folders are on for tidiness.
    func chooseFoldersToOrganize() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Organize"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        if !namingOptions.useMovieFolders { namingOptions.useMovieFolders = true }
        importURLs(panel.urls)
    }

    // MARK: Conversion (FR16/FR17) — dynamic queue

    func addConvertFiles(_ urls: [URL]) {
        let found = scanner.scan(urls: urls).map { $0.url }
        var seen = Set(convertFiles.map { $0.standardizedFileURL.path })
        if let current = currentConvert { seen.insert(current.standardizedFileURL.path) }
        for url in found where seen.insert(url.standardizedFileURL.path).inserted {
            convertFiles.append(url)
            convertSizes[url] = Self.fileSize(url)
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    // MARK: Conversion estimate (FR16)

    /// Files still to process (current + pending).
    private var convertRemainingURLs: [URL] { (currentConvert.map { [$0] } ?? []) + convertFiles }
    var convertRemainingBytes: Int64 {
        convertRemainingURLs.reduce(0) { $0 + (convertSizes[$1] ?? 0) }
    }
    var convertQuality: ConversionEstimator.Quality {
        ConversionEstimator.quality(options: conversionOptions)
    }
    /// Human-readable size estimate, e.g. "≈ 3,2 GB statt 7,1 GB · spart ~55 %".
    var convertEstimateText: String? {
        let input = convertRemainingBytes
        guard input > 0, conversionOptions.videoCodec != .copy else { return nil }
        let fraction = ConversionEstimator.sizeFraction(options: conversionOptions)
        let output = Int64(Double(input) * fraction)
        let saved = input - output
        let pct = Int((Double(saved) / Double(input) * 100).rounded())
        let f: (Int64) -> String = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        if saved >= 0 {
            return "≈ \(f(output)) instead of \(f(input)) · saves ~\(pct) %"
        }
        return "≈ \(f(output)) instead of \(f(input)) · ~+\(-pct) % larger"
    }

    func removeConvertFile(_ url: URL) {
        convertFiles.removeAll { $0 == url }
        // Removing the file currently being converted cancels it and moves on.
        if currentConvert == url { processBox.terminate() }
    }

    func clearConvertFiles() {
        convertFiles.removeAll()
        if !isConverting { convertProgress = 0; convertStatus = nil; convertDetail = nil }
    }

    func startConversion() {
        guard !isConverting, !convertFiles.isEmpty else { return }
        guard ffmpegPath != nil else {
            convertStatus = "FFmpeg not found – install with: brew install ffmpeg"
            return
        }
        isConverting = true
        cancelRequested = false
        convDone = 0
        convFailed = 0
        convertProgress = 0
        convertStatus = "Converting…"
        lastRunHadError = false
        publishStatus()
        processNext()
    }

    func stopConversion() {
        guard isConverting else { return }
        cancelRequested = true
        processBox.terminate()
        convertStatus = "Stopping…"
    }

    /// Pops the next file from the (live) queue and converts it, then recurses —
    /// so files added during conversion are picked up and removed ones skipped.
    private func processNext() {
        guard !cancelRequested, !convertFiles.isEmpty, let ffmpeg = ffmpegPath else {
            finishConversion()
            return
        }
        let input = convertFiles.removeFirst()
        currentConvert = input
        convertProgress = 0
        convertDetail = nil
        let options = conversionOptions
        let box = processBox
        appendConvertLog("⏳ \(input.lastPathComponent)")

        Task.detached(priority: .userInitiated) { [weak self] in
            let converter = FFmpegConverter(ffmpegPath: ffmpeg)
            let output = AppState.uniqueOutputURL(for: input, options: options)
            var ok = false
            var message: String
            do {
                try converter.convert(
                    input: input, output: output, options: options,
                    onStart: { proc in box.set(proc) },
                    progress: { p in
                        Task { @MainActor [weak self] in
                            self?.convertProgress = p.fraction
                            self?.convertDetail = AppState.progressDetail(p)
                        }
                    }
                )
                ok = true
                message = "✓ \(output.lastPathComponent)"
            } catch {
                message = "✗ \(input.lastPathComponent): \(error.localizedDescription)"
            }
            box.set(nil)
            await self?.fileFinished(ok: ok, message: message)
        }
    }

    private func fileFinished(ok: Bool, message: String) {
        if ok { convDone += 1 } else { convFailed += 1 }
        appendConvertLog(message)
        currentConvert = nil
        processNext()
    }

    private func finishConversion() {
        let stopped = cancelRequested
        isConverting = false
        cancelRequested = false
        currentConvert = nil
        convertProgress = stopped ? 0 : 1
        convertDetail = nil
        convertStatus = (stopped ? "Stopped" : "Done")
            + ": \(convDone) converted, \(convFailed) failed."
        lastRunHadError = convFailed > 0
        publishStatus()
    }

    nonisolated static func conversionOutputURL(for input: URL, options: ConversionOptions) -> URL {
        let stem = input.deletingPathExtension().lastPathComponent
        let tag = options.videoCodec == .copy ? "remux" : options.videoCodec.rawValue
        return input.deletingLastPathComponent().appendingPathComponent("\(stem).\(tag).mkv")
    }

    /// Output path that does not overwrite an existing file (ffmpeg runs with -y).
    nonisolated static func uniqueOutputURL(for input: URL, options: ConversionOptions) -> URL {
        let base = conversionOutputURL(for: input, options: options)
        let fm = FileManager.default
        guard fm.fileExists(atPath: base.path) else { return base }
        let dir = base.deletingLastPathComponent()
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        var n = 1
        while true {
            let candidate = dir.appendingPathComponent("\(stem) (\(n)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private func appendConvertLog(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        convertLog.insert("\(stamp)  \(line)", at: 0)
        if convertLog.count > 200 { convertLog.removeLast() }
    }

    /// Formats speed/ETA for display, e.g. "3.1× · Rest ~12:34".
    nonisolated static func progressDetail(_ p: ConversionProgress) -> String {
        var parts: [String] = ["\(Int(p.fraction * 100)) %"]
        if let speed = p.speed { parts.append(String(format: "%.1f×", speed)) }
        if let eta = p.etaSeconds {
            let total = Int(eta.rounded())
            parts.append(String(format: "Left ~%d:%02d", total / 60, total % 60))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Metadata enrichment (FR3)

    var appleIntelligenceSupported: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return AppleIntelligenceProvider.isSupported }
        #endif
        return false
    }

    /// A user-chosen FFmpeg binary, used when the auto-search finds nothing (FR16).
    @Published var customFFmpegPath = "" {
        didSet { UserDefaults.standard.set(customFFmpegPath, forKey: Keys.ffmpegPath) }
    }

    /// FFmpeg binary: a valid custom path wins, else the first common location.
    var ffmpegPath: String? {
        if !customFFmpegPath.isEmpty, FileManager.default.isExecutableFile(atPath: customFFmpegPath) {
            return customFFmpegPath
        }
        return ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    var ffmpegAvailable: Bool { ffmpegPath != nil }

    func setFFmpegPath(_ url: URL) { customFFmpegPath = url.path }

    var watchActive: Bool { watchEnabled && watchFolderURL != nil }
    var tmdbConfigured: Bool { onlineLookupEnabled && !tmdbAPIKey.isEmpty }
    var localDatabaseLoaded: Bool { localDatabaseCount > 0 }

    /// Manual TMDb lookup (the Settings "Jetzt nachschlagen" button).
    func lookUpOnline() {
        guard !tmdbAPIKey.isEmpty else { return }
        enrich(with: TMDbMetadataProvider(apiKey: tmdbAPIKey))
    }

    /// Checks the TMDb API key and reports clear feedback (FR3).
    @Published var tmdbTestResult: String?
    func testTMDb() {
        guard !tmdbAPIKey.isEmpty else {
            tmdbTestResult = "No API key entered."
            return
        }
        tmdbTestResult = "Testing connection …"
        let provider = TMDbMetadataProvider(apiKey: tmdbAPIKey)
        Task { [weak self] in
            do {
                let status = try await provider.verify()
                switch status {
                case 200:
                    self?.tmdbTestResult = "✓ Connected – key valid."
                case 401:
                    self?.tmdbTestResult = "✗ Invalid key (401). Please use the v3 API key, not the v4 token."
                default:
                    self?.tmdbTestResult = "TMDb responded with status \(status)."
                }
            } catch {
                self?.tmdbTestResult = "✗ No connection: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Jellyfin connector (FR20)

    var jellyfinConfigured: Bool { jellyfinEnabled && !jellyfinServerURL.isEmpty && !jellyfinAPIKey.isEmpty }

    private func makeJellyfinConnector() -> JellyfinConnector? {
        guard jellyfinConfigured else { return nil }
        return try? JellyfinConnector(serverURL: jellyfinServerURL, apiKey: jellyfinAPIKey)
    }

    /// Verifies the Jellyfin connection and reports clear feedback.
    func testJellyfin() {
        guard jellyfinEnabled, !jellyfinServerURL.isEmpty, !jellyfinAPIKey.isEmpty else {
            jellyfinTestResult = "Enter server URL and API key."
            return
        }
        guard let connector = makeJellyfinConnector() else {
            jellyfinTestResult = "✗ Invalid server URL (e.g. http://localhost:8096)."
            return
        }
        jellyfinTestResult = "Testing connection …"
        Task { [weak self] in
            do {
                let status = try await connector.verify()
                switch status {
                case 200:
                    self?.jellyfinTestResult = "✓ Connected – API key valid."
                case 401, 403:
                    self?.jellyfinTestResult = "✗ API key invalid (\(status))."
                default:
                    self?.jellyfinTestResult = "Jellyfin responded with status \(status)."
                }
            } catch {
                self?.jellyfinTestResult = "✗ No connection: \(error.localizedDescription)"
            }
        }
    }

    /// Triggers a Jellyfin library rescan (after a rename/move). Fire-and-forget.
    private func refreshJellyfinIfNeeded() {
        guard let connector = makeJellyfinConnector() else { return }
        Task { [weak self] in
            do {
                try await connector.refresh()
                self?.logActivity("Refreshing Jellyfin library …")
            } catch {
                self?.logActivity("Jellyfin refresh failed: \(error.localizedDescription)")
            }
        }
    }

    /// Builds the active provider chain from the enabled identification options.
    private func currentEnrichmentProvider() -> MetadataProvider? {
        var providers: [MetadataProvider] = []
        #if canImport(AVFoundation)
        if useEmbeddedMetadata { providers.append(EmbeddedMetadataProvider()) }
        #endif
        // ffprobe covers MKV (which AVFoundation cannot read). Runs after the
        // AVFoundation reader so native containers stay fast.
        #if os(macOS)
        if useEmbeddedMetadata, let ffprobe = FFprobeMetadataProvider.defaultPath() {
            providers.append(FFprobeMetadataProvider(ffprobePath: ffprobe))
        }
        #endif
        if useLocalDatabase, let db = localDatabase {
            providers.append(LocalDatabaseMetadataProvider(database: db))
        }
        #if canImport(FoundationModels)
        if useAppleIntelligence, #available(macOS 26.0, *), AppleIntelligenceProvider.isSupported {
            providers.append(AppleIntelligenceProvider())
        }
        #endif
        if onlineLookupEnabled, !tmdbAPIKey.isEmpty {
            providers.append(TMDbMetadataProvider(apiKey: tmdbAPIKey))
        }
        guard !providers.isEmpty else { return nil }
        return providers.count == 1 ? providers[0] : CompositeMetadataProvider(providers)
    }

    /// Whether any identification source is configured (drives "Erneut erkennen").
    var hasEnrichmentProvider: Bool { currentEnrichmentProvider() != nil }
    var canReIdentify: Bool { hasFiles && hasEnrichmentProvider && !isLookingUp }

    /// Re-runs the identification chain over the already-imported files, without
    /// requiring a re-import — e.g. after changing the metadata source (FR3).
    func reIdentify() {
        guard let provider = currentEnrichmentProvider() else { return }
        enrich(with: provider)
    }

    // MARK: Local title database (FR3)

    func setLocalDatabaseFile(_ url: URL) {
        localDatabasePath = url.path
        loadDatabase()
    }

    func loadDatabase() {
        guard !localDatabasePath.isEmpty else { return }
        let url = URL(fileURLWithPath: localDatabasePath)
        isLoadingDatabase = true
        databaseError = nil
        Task.detached(priority: .utility) { [weak self] in
            do {
                let db = try LocalTitleDatabaseLoader.load(from: url)
                await self?.applyDatabase(db, error: nil)
            } catch {
                await self?.applyDatabase(nil, error: error.localizedDescription)
            }
        }
    }

    private func applyDatabase(_ db: LocalTitleDatabase?, error: String?) {
        isLoadingDatabase = false
        localDatabase = db
        localDatabaseCount = db?.count ?? 0
        databaseError = error
    }

    /// Refines every scanned file's parsed title/year using the given provider.
    private func enrich(with provider: MetadataProvider) {
        guard !isLookingUp, !scannedFiles.isEmpty else { return }
        isLookingUp = true

        let enricher = MetadataEnricher(provider: provider)
        let files = scannedFiles

        Task { [weak self] in
            var enriched: [MediaFile] = []
            for file in files {
                var updated = file
                updated.parsed = await enricher.enrich(file.parsed, at: file.url)
                enriched.append(updated)
            }
            guard let self else { return }
            let stillPresent = Set(self.scannedFiles.map { $0.url })
            self.scannedFiles = enriched.filter { stillPresent.contains($0.url) }
            self.isLookingUp = false
            self.rebuildPlan()
        }
    }

    func clear() {
        scannedFiles.removeAll()
        items.removeAll()
        completed.removeAll()
        progress = 0
        lastResult = nil
        didUndo = false
    }

    func removeItem(_ item: RenameItem) {
        scannedFiles.removeAll { $0.url == item.mediaFile.url }
        items.removeAll { $0.id == item.id }
    }

    /// True once at least one item has been renamed (so it can be converted).
    var hasConvertibleResults: Bool { doneCount > 0 }

    /// Sends all renamed files into the conversion queue and switches view.
    func convertCompleted() {
        let urls = items.filter { status(for: $0) == .done }.map { $0.primaryDestination }
        guard !urls.isEmpty else { return }
        addConvertFiles(urls)
        section = .convert
    }

    /// Sends one renamed file into the conversion queue and switches view.
    func convert(_ item: RenameItem) {
        addConvertFiles([item.primaryDestination])
        section = .convert
    }

    /// Recomputes the plan from scanned files, preserving user acceptance where possible.
    private func rebuildPlan() {
        let previousBySource = Dictionary(
            items.map { ($0.mediaFile.url, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var rebuilt = planner.makePlan(for: scannedFiles, outputRoot: outputRoot, libraryRoot: libraryRoot)
        for index in rebuilt.indices {
            if let previous = previousBySource[rebuilt[index].mediaFile.url] {
                rebuilt[index].isAccepted = previous.isAccepted
            }
        }
        items = rebuilt
    }

    // MARK: Status & filtering

    func status(for item: RenameItem) -> ItemStatus {
        if completed.contains(sourcePath(item)) { return .done }
        if !item.isAccepted { return .skipped }
        if item.conflict != nil { return .conflict }
        return .ready
    }

    func items(in section: SidebarSection) -> [RenameItem] {
        switch section {
        case .movies:
            return items.filter { $0.mediaFile.parsed.kind != .episode }
        case .series:
            return items.filter { $0.mediaFile.parsed.kind == .episode }
        case .queue:
            // The consolidated queue applies the in-header Movies/Series filter.
            switch libraryFilter {
            case .all: return items
            case .movies: return items.filter { $0.mediaFile.parsed.kind != .episode }
            case .series: return items.filter { $0.mediaFile.parsed.kind == .episode }
            }
        default:
            return items
        }
    }

    /// Plain-text export of the rename log (FR12).
    var logExportText: String {
        let stamp = ISO8601DateFormatter()
        return logEntries.map { entry in
            let error = entry.errorDescription.map { " — \($0)" } ?? ""
            return "\(stamp.string(from: entry.date))\t\(entry.status)\t\(entry.oldName) -> \(entry.newName)\(error)"
        }.joined(separator: "\n")
    }

    /// Items for a section after applying the search filter and hide-completed
    /// toggle, optionally grouped/sorted by show → season → episode.
    func sortedItems(in section: SidebarSection) -> [RenameItem] {
        var list = items(in: section)
        if hideCompleted {
            list = list.filter { status(for: $0) != .done }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            list = list.filter { item in
                item.originalFileName.lowercased().contains(query)
                    || item.mediaFile.parsed.title.lowercased().contains(query)
                    || item.proposedRelativePath.lowercased().contains(query)
            }
        }
        guard sortByShow else { return list }
        return list.sorted { a, b in
            let pa = a.mediaFile.parsed, pb = b.mediaFile.parsed
            let ta = pa.title.lowercased(), tb = pb.title.lowercased()
            if ta != tb { return ta < tb }
            let sa = pa.season ?? -1, sb = pb.season ?? -1
            if sa != sb { return sa < sb }
            let ea = pa.episode ?? -1, eb = pb.episode ?? -1
            if ea != eb { return ea < eb }
            return a.originalFileName < b.originalFileName
        }
    }

    var hasFiles: Bool { !items.isEmpty }
    var readyCount: Int { items.filter { status(for: $0) == .ready }.count }
    var warnCount: Int { items.filter { status(for: $0) == .conflict }.count }
    var doneCount: Int { items.filter { status(for: $0) == .done }.count }
    var movieCount: Int { items(in: .movies).count }
    var seriesCount: Int { items(in: .series).count }

    private func runnablePlan() -> [RenameItem] {
        items.filter { $0.isAccepted && !completed.contains(sourcePath($0)) }
    }

    var approvedActiveCount: Int { runnablePlan().count }
    var canStart: Bool { approvedActiveCount > 0 && !isProcessing }
    var showUndo: Bool { (doneCount > 0 || canUndo) && !isProcessing }

    /// Header checkbox state: are all not-yet-done items accepted?
    var allChecked: Bool {
        let pending = items.filter { status(for: $0) != .done }
        return !pending.isEmpty && pending.allSatisfy { $0.isAccepted }
    }

    var subtitleText: String {
        guard hasFiles else { return "Ready to import" }
        return "\(items.count) files analyzed · \(approvedActiveCount) selected"
    }

    var statusBarText: String {
        if let lastResult { return lastResult }
        if doneCount > 0 {
            return didUndo
                ? "\(items.count) files · rename undone"
                : "\(doneCount) renamed · logged · undo available"
        }
        guard hasFiles else { return "No files · everything is processed locally" }
        return "\(readyCount) ready · \(warnCount) need review"
    }

    var startLabel: String {
        isProcessing ? "Running …" : "Rename \(approvedActiveCount)"
    }

    // MARK: Editing (FR9)

    func setAccepted(_ accepted: Bool, for id: RenameItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isAccepted = accepted
    }

    func toggle(_ id: RenameItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isAccepted.toggle()
    }

    func toggleAll() {
        let target = !allChecked
        for index in items.indices where status(for: items[index]) != .done {
            items[index].isAccepted = target
        }
    }

    func updateProposedPath(_ newPath: String, for id: RenameItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        // Prevent a manual edit from escaping the output root (e.g. "../").
        let safe = JellyfinNamer.sanitizeRelativePath(newPath)
        guard !safe.isEmpty else { return }
        items[index].proposedRelativePath = safe
        items[index] = planner.reconcile(item: items[index])
    }

    // MARK: Execute (FR7, FR10, FR11, FR12, FR13, FR19)

    func start() {
        guard !isProcessing else { return }
        let runnable = runnablePlan()
        guard !runnable.isEmpty else { return }

        if conflictPolicy == .ask {
            let conflicting = runnable.filter { $0.conflict != nil }
            if !conflicting.isEmpty {
                conflictsToResolve = conflicting
                return
            }
        }
        runExecution(resolutions: [:])
    }

    func resolveConflicts(_ resolutions: [RenameItem.ID: ConflictPolicy]) {
        var bySource: [String: ConflictPolicy] = [:]
        for item in conflictsToResolve {
            let policy = resolutions[item.id] ?? .skip
            for move in item.allMoves {
                bySource[move.source.standardizedFileURL.path] = policy
            }
        }
        conflictsToResolve = []
        runExecution(resolutions: bySource)
    }

    func cancelConflictResolution() {
        conflictsToResolve = []
        lastResult = "Cancelled — resolve conflicts and start again."
    }

    private func runExecution(resolutions: [String: ConflictPolicy]) {
        isProcessing = true
        progress = 0
        lastResult = nil
        didUndo = false
        lastRunHadError = false
        publishStatus()

        let plan = runnablePlan()
        let policy = conflictPolicy
        let log = self.log
        let journal = self.journal

        Task.detached(priority: .userInitiated) { [weak self] in
            let executor = RenameExecutor(log: log, journal: journal)
            let outcome = executor.execute(
                plan: plan,
                policy: policy,
                askResolution: { move in
                    resolutions[move.source.standardizedFileURL.path] ?? .skip
                },
                progress: { fraction in
                    Task { @MainActor [weak self] in self?.progress = fraction }
                }
            )
            await self?.finish(outcome: outcome)
        }
    }

    private func finish(outcome: RenameOutcome) {
        if let tx = outcome.transaction {
            let moved = Set(tx.moves.map { $0.from.standardizedFileURL.path })
            for item in items where moved.contains(sourcePath(item)) {
                completed.insert(sourcePath(item))
            }
        }
        isProcessing = false
        progress = 1
        logEntries = log.entries
        canUndo = journal.canUndo
        lastResult = "Done: \(outcome.succeeded) renamed, \(outcome.skipped) skipped, \(outcome.failed) failed."
        lastRunHadError = outcome.failed > 0
        publishStatus()
        // Tell Jellyfin to rescan so the renamed files are exported (FR20).
        if outcome.succeeded > 0 { refreshJellyfinIfNeeded() }
    }

    func undoLast() {
        let executor = RenameExecutor(log: log, journal: journal)
        let restored = executor.undoLast()
        completed.removeAll()
        didUndo = true
        logEntries = log.entries
        canUndo = journal.canUndo
        lastResult = "Undone: \(restored) file(s) restored."
    }

    // MARK: Log

    func clearLog() {
        log.clear()
        logEntries = []
    }
}
