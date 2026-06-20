# MediaIdentifier

A native **macOS (Apple Silicon)** app that analyses downloaded media files and
renames them into a **Jellyfin-compatible** layout — by drag-and-drop, with a
preview before anything touches the disk. Built with SwiftUI on top of a pure,
fully unit-tested domain core.

> Beschreibung auf Deutsch weiter unten unter [Funktionsabdeckung](#funktionsabdeckung-fr1fr20).

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

### Option A — proper `.app` bundle (recommended)

```bash
brew install xcodegen      # one-time
xcodegen generate          # creates MediaIdentifier.xcodeproj
open MediaIdentifier.xcodeproj
# Select the "MediaIdentifier" scheme and Run (⌘R)
```

### Option B — open the package directly

Open `Package.swift` in Xcode and run the `MediaIdentifierApp` scheme, or from
the terminal:

```bash
swift run MediaIdentifierApp
```

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
  MediaIdentifierApp/         SwiftUI macOS front-end (dark "Jellyfin Renamer" design)
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

**Enabling it in the app:** click the **Online** button in the toolbar, toggle
"Look up official titles online" and paste a TMDb API key (key + toggle are
persisted in `UserDefaults`). When enabled, imports are enriched automatically,
and "Look Up Now" re-runs the lookup on demand.

### Conflict handling (FR11)

The conflict policy is chosen in the toolbar: **Ask · Skip · Rename · Replace**.
With **Ask**, pressing Start opens a resolution sheet listing every collision so
you can decide per file (or apply one choice to all) before anything is moved.

## Funktionsabdeckung (FR1–FR20)

| FR | Thema | Status | Umsetzung |
|----|-------|--------|-----------|
| FR1 | Import per Drag-and-Drop (Dateien/Ordner) | ✅ | `ContentView` Drop + `MediaScanner` |
| FR2 | Analyse von Release-Namen | ✅ | `ReleaseNameParser` |
| FR3 | Identifikation über Metadatenquellen | ✅ | `MetadataProvider`, `TMDbMetadataProvider` (offline default) |
| FR4 | Offizielle Titelbestimmung | ✅ | `ReleaseNameParser` / `MetadataEnricher` |
| FR5 | Erscheinungsjahr | ✅ | `ReleaseNameParser` (Mehrjahr-Heuristik) |
| FR6 | Staffel/Episode (S01E01, 1x05, Episode 07, Multi-Episode) | ✅ | `ReleaseNameParser` |
| FR7 | Jellyfin-konforme Umbenennung | ✅ | `JellyfinNamer` |
| FR8 | Vorschau der Änderungen | ✅ | `PreviewTable` |
| FR9 | Bestätigen / Ablehnen / manuell anpassen | ✅ | `PreviewTable`, `AppState` |
| FR10 | Mehrere Dateien gleichzeitig | ✅ | `MediaScanner`, `RenamePlanner` |
| FR11 | Konflikterkennung (Skip/Rename/Replace/Ask) | ✅ | `RenamePlanner`, `RenameExecutor` |
| FR12 | Protokollierung | ✅ | `RenameLog` |
| FR13 | Rückgängig-Funktion | ✅ | `RenameJournal`, `RenameExecutor.undoLast` |
| FR14 | Untertitel (SRT/ASS/SUB) mit umbenennen | ✅ | `MediaScanner`, `RenamePlanner` |
| FR15 | Zusätzliche Dateien (NFO/Cover/Sample) | ✅ | `VideoFileTypes`, `RenamePlanner` |
| FR16 | Konvertierung via FFmpeg | 🧩 Gerüst | `FFmpegArgumentBuilder`, `FFmpegConverter` |
| FR17 | Hardwarebeschleunigung (VideoToolbox) | 🧩 Gerüst | `ConversionOptions.useHardwareAcceleration` |
| FR18 | Lokale Verarbeitung (keine Cloud-Uploads) | ✅ | Offline default, keine Medien-Uploads |
| FR19 | Grafische Oberfläche (Drop, Vorschau, Fortschritt, Start, Log) | ✅ | SwiftUI Views |
| FR20 | Erweiterbarkeit (Plex/Emby/Sonarr, Watch-Folder …) | ✅ Basis | Protokoll-basierte Provider/Konverter |

**Legende:** ✅ implementiert · 🧩 Gerüst vorhanden (geplante Erweiterung gemäß FR16/FR17).

## Roadmap / future work

FR16 and FR17 (conversion + VideoToolbox) ship as a tested argument builder and
an execution wrapper, ready to be surfaced in the UI. FR20 extension points
(Plex/Emby naming profiles, Sonarr/Radarr hooks, watch-folders, background
batch processing) build naturally on the `MetadataProvider` and naming
abstractions.

## Note on this environment

This project was authored in a Linux container without an Xcode/Swift
toolchain, so it has not been compiled here. The code targets Swift 5.9 /
macOS 13+ and the Core logic is covered by the included XCTest suite — run
`swift test` on macOS to verify.
