<p align="center"><img src="docs/logo.png" width="128" alt="MediaIdentifier"></p>

# MediaIdentifier

A native **macOS (Apple Silicon)** app that analyses downloaded media files and
renames them into a **Jellyfin-compatible** layout — by drag-and-drop, with a
preview before anything touches the disk. Built with SwiftUI on top of a pure,
fully unit-tested domain core. Ships as a **universal binary** (Apple Silicon
and Intel).

---

## What it does

- **Drag in** files or whole folders (MKV, AVI, MP4, MOV, M4V, …).
- It **parses the release name** — title, year, season/episode, resolution,
  release group.
- It **proposes Jellyfin-conformant names** and shows a **preview**:
  - Movies → `Interstellar (2014)/Interstellar (2014).mkv`
  - Series → `The Last of Us/Season 01/The Last of Us - S01E01.mkv`
- You **accept, reject, or hand-edit** each row, then press **Start**.
- Subtitles and extras (`.srt`, `.ass`, `.sub`, `.nfo`, posters, samples) are
  **renamed alongside** the video.
- Every change is **logged** and can be **undone**.
- Everything runs **100% locally** — no media is ever uploaded.

## Building

The repository is a Swift Package plus an XcodeGen spec.

### Option A — build a `.app` (works with any Xcode)

```bash
./build_app.sh
```

Produces `build/MediaIdentifier.app`. It builds via Xcode (xcodegen + xcodebuild)
when available and falls back to a SwiftPM build with a hand-assembled bundle, so
it does not depend on the Xcode project format / version. On failure it prints
the error and keeps a log at `build/build.log`.

### Option B — Xcode project (requires Xcode 16+)

```bash
brew install xcodegen      # one-time
xcodegen generate          # creates MediaIdentifier.xcodeproj (project format 77)
open MediaIdentifier.xcodeproj
# Select the "MediaIdentifier" scheme and Run (⌘R)
```

> Older Xcode (≤ 15.x) cannot open the generated project ("future Xcode project
> file format (77)"). Use Option A (it falls back to SwiftPM) or update Xcode.

A ready-built, ad-hoc-signed `.app` is also published on the
[Releases page](https://github.com/tamling/MediaIdentifier/releases/tag/latest).

### Option C — open the package directly

Open `Package.swift` in Xcode and run the `MediaIdentifierApp` scheme, or
`swift run MediaIdentifierApp`.

### Run the tests

```bash
swift test
```

The test suite covers the parser, the Jellyfin namer, the planner/executor
(including companions, conflicts and undo) and the FFmpeg argument builder.

## Architecture

```
Sources/
  MediaIdentifierCore/        Pure Foundation — no UI, fully testable
    Models/                   ParsedRelease, MediaFile, CompanionFile
    Parsing/                  ReleaseNameParser, token vocabulary, regex helpers
    Naming/                   JellyfinNamer (FR7 naming rules)
    Planning/                 RenamePlanner, RenameItem, conflict detection
    FileOps/                  MediaScanner, RenameExecutor, file-type registry
    Logging/                  RenameLog (FR12)
    Undo/                     RenameJournal (FR13)
    Metadata/                 MetadataProvider (+ offline & TMDb implementations)
    Conversion/               FFmpeg argument builder + converter (FR16/FR17)
  MediaIdentifierApp/         SwiftUI macOS front-end (dark "Mediafin" design)
    AppState.swift            View model wiring Core to the UI
    Theme.swift               Colour palette + reusable chips/controls
    ContentView.swift         Title bar + sidebar + main area
    Views/                    SidebarView, QueueView, FileRowView, EmptyDropView,
                              ConvertView, LogView, ConflictResolutionView,
                              MetadataSettingsView
Tests/
  MediaIdentifierCoreTests/   XCTest suite
```

The **Core** library has no SwiftUI/AppKit imports, so the logic is portable and
testable in isolation; the **App** target is a thin SwiftUI layer over it.

## Metadata sources (FR3)

By default the app uses `OfflineMetadataProvider`, which trusts the parsed
title/year and makes **no network calls** — keeping it consistent with the
local-only guarantee (FR18). A `TMDbMetadataProvider` is included to look up
official titles; it only ever sends the parsed *title and year text* (never any
media file) and requires a free TMDb API key. Additional providers (TVDb, IMDb)
can be added by conforming to the `MetadataProvider` protocol (FR20).

**On-device Apple Intelligence (local):** when running on macOS 26+ with Apple
Silicon and Apple Intelligence enabled, `AppleIntelligenceProvider` can identify
titles using the built-in Foundation Models language model — fully on-device, so
it stays consistent with FR18. It takes priority over TMDb and falls back to the
heuristic parser when unavailable. Enable it under Settings → Identification.
(Requires the Foundation Models framework; guarded behind
`#if canImport(FoundationModels)` so older SDKs still build.)

**Embedded container tags (local):** `EmbeddedMetadataProvider` reads title/year
tags stored inside MP4/MOV/M4V files via AVFoundation. For MKV (which
AVFoundation cannot read) `FFprobeMetadataProvider` reads the container tags via
`ffprobe`.

**Local title database (local after one download):** `LocalTitleDatabase` +
`LocalTitleDatabaseLoader` build an offline index from a downloaded TMDb data
export (`files.tmdb.org/p/exports/`, the `movie_ids` / `tv_series_ids` NDJSON
files, plain or `.gz`) — or any JSON array of `{title, year, kind}`. Parsed
titles are matched offline (exact + fuzzy/Levenshtein, ranked by kind, year and
popularity). Pick the file under Settings → Identification.

The active identification chain is **embedded tags → local DB → Apple
Intelligence → TMDb**; each step falls through to the next when it has no
confident match (`CompositeMetadataProvider`). Everything except TMDb is fully
local (FR18).

**Enabling TMDb in the app:** open **Settings → Identification**, toggle "Look up
official titles online" and paste a TMDb API key (v3 key or v4 token). The key is
stored in the Keychain. When enabled, imports are enriched automatically, and
"Look up now" re-runs the lookup on demand.

**Library connector & monitoring (FR20):** a `JellyfinConnector` asks a local
Jellyfin server to rescan its library after a successful rename/move (only a scan
command is sent, no media). A read-only status web page (`/`, `/api/status`,
`/healthz`) lets external monitors such as Uptime Kuma watch progress and be
notified when a run finishes.

### Conflict handling (FR11)

The conflict policy is chosen in the toolbar: **Ask · Skip · Rename · Replace**.
With **Ask**, pressing Start opens a resolution sheet listing every collision so
you can decide per file (or apply one choice to all) before anything is moved.

## Feature coverage (FR1–FR20)

| FR | Topic | Status | Implementation |
|----|-------|--------|----------------|
| FR1 | Import via drag-and-drop (files/folders) | ✅ | `ContentView` drop + `MediaScanner` |
| FR2 | Release-name analysis | ✅ | `ReleaseNameParser` |
| FR3 | Identification via metadata sources | ✅ | `MetadataProvider`, embedded/ffprobe/local DB/Apple Intelligence/TMDb |
| FR4 | Official title resolution | ✅ | `MetadataEnricher` (provenance shown in the row) |
| FR5 | Release year | ✅ | `ReleaseNameParser` (multi-year heuristic) |
| FR6 | Season/episode (S01E01, 1x05, Episode 07, multi-episode) | ✅ | `ReleaseNameParser` |
| FR7 | Jellyfin-conformant renaming | ✅ | `JellyfinNamer` |
| FR8 | Preview of changes | ✅ | `QueueView` / `FileRowView` |
| FR9 | Accept / reject / hand-edit (inline) | ✅ | `FileRowView`, `AppState` |
| FR10 | Multiple files at once | ✅ | `MediaScanner`, `RenamePlanner` |
| FR11 | Conflict detection (Skip/Rename/Replace/Ask) | ✅ | `RenamePlanner`, `RenameExecutor` |
| FR12 | Logging (exportable) | ✅ | `RenameLog` |
| FR13 | Undo | ✅ | `RenameJournal`, `RenameExecutor.undoLast` |
| FR14 | Subtitles (SRT/ASS/SUB) renamed alongside | ✅ | `MediaScanner`, `RenamePlanner` |
| FR15 | Extra files (NFO/cover/sample) | ✅ | `VideoFileTypes`, `RenamePlanner` |
| FR16 | Conversion via FFmpeg | ✅ | `FFmpegConverter` + Convert view (queue, RF, progress, history) |
| FR17 | Hardware acceleration (VideoToolbox) | ✅ | `ConversionOptions.useHardwareAcceleration` |
| FR18 | Local processing (no cloud uploads) | ✅ | Offline default, no media uploads |
| FR19 | Graphical interface (drop, preview, progress, start, log) | ✅ | SwiftUI views |
| FR20 | Extensibility (Jellyfin connector, watch folder, status web page) | ✅ | `LibraryConnector`/`JellyfinConnector`, `WatchFolderScanner`, `StatusWebServer` |

**Legend:** ✅ implemented.

## Roadmap / future work

Further FR20 connectors (Emby, Sonarr/Radarr) build naturally on the
`LibraryConnector` protocol. Optional Developer ID signing + notarisation is
wired into the release workflow (see `docs/SIGNING.md`); without secrets the
release ships an ad-hoc-signed universal `.app`.

## Security

A static review informed these hardening measures:

- **No silent data loss:** the "Replace" conflict policy moves the existing file
  to the Trash (not a hard delete) and records it in the undo journal, so it can
  be restored (`RenameExecutor.trashExisting`).
- **Secrets in the Keychain:** the TMDb API key is stored in the Keychain, not
  UserDefaults (`KeychainStore`); a legacy plaintext value is migrated on launch.
- **No path traversal:** manually edited destination paths are sanitised so they
  cannot escape the output root (`JellyfinNamer.sanitizeRelativePath`).
- **No shell injection:** external tools (FFmpeg, gunzip) are invoked with fixed
  executables and argument arrays — never a shell string.
- **Bounded input / no key caching:** the local-database loader caps decoded
  size; TMDb requests use an ephemeral URL session so the key is not cached.

## Note on this environment

This project was authored in a Linux container without an Xcode/Swift
toolchain, so it has not been compiled here. The code targets Swift 5.9 /
macOS 13+ and the Core logic is covered by the included XCTest suite — run
`swift test` on macOS to verify.
