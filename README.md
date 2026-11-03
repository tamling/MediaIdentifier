<p align="center"><img src="docs/logo.png" width="128" alt="MediaIdentifier"></p>

# MediaIdentifier

Analyses downloaded media files and renames them into a **Jellyfin-compatible**
layout, with a preview before anything touches the disk.

It runs two ways on top of one shared, fully unit-tested domain core:

- **Linux** (and macOS): the `mediafin` binary serves a local web interface
  over **HTTPS** — see [Running on Linux](#running-on-linux).
- **macOS**: a native SwiftUI app with drag-and-drop, shipped as a universal
  binary (Apple Silicon and Intel).

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

## Running on Linux

On Debian or Ubuntu, install the package from the
[latest release](../../releases/tag/latest):

```bash
sudo apt install ./mediafin-linux-x86_64.deb
mediafin
```

It declares its dependencies, so apt pulls what is needed. The Swift runtime
is linked statically — no Swift installation required — but Foundation still
uses a few system libraries, and `openssl` is needed to create the first
self-signed certificate; both come in as dependencies. `ffmpeg` is a
*recommendation*, needed only for re-encoding. The package also installs
`man mediafin` and a systemd unit, which it deliberately does **not** enable:
starting a server that exposes your library should be your decision. See the
comments at the top of `/lib/systemd/system/mediafin.service` before
`systemctl enable --now mediafin`.

Elsewhere, take the tarball — same binary, no package management:

```bash
tar -xzf mediafin-linux-x86_64.tar.gz
./mediafin
```

Or build it yourself:

```bash
swift build -c release --product mediafin
.build/release/mediafin
```

On the first start it creates an access token and a self-signed certificate,
prints the token once, and tells you the URL:

```
Mediafin is serving its interface on https://localhost:8720
```

Open that in a browser and sign in with the printed token. The token is kept
in the configuration directory (`$XDG_CONFIG_HOME/mediafin`, by default
`~/.config/mediafin`) with mode `0600`, so it survives a restart; print it
again with `mediafin --print-token`, or issue a new one — signing every browser
out — with `mediafin --rotate-token`.

**The browser will warn once about the certificate.** That is inherent to
self-signing, not a fault. Compare the SHA-256 fingerprint printed at startup
with the one the browser shows, then accept it; or supply a real certificate:

```bash
mediafin --cert /etc/ssl/mediafin.pem --key /etc/ssl/mediafin.key
```

Useful options (`mediafin --help` lists them all):

| Option | Meaning |
| --- | --- |
| `--port <n>` | Port to listen on (default 8720). |
| `--bind local\|all` | Reachable from this machine only (default), or from the network. |
| `--no-tls` | Serve plain HTTP. Refused for a network bind. |
| `--cert` / `--key` | Use your own PEM certificate and key. |
| `--config-dir <dir>` | Where to keep the token, certificate and settings. |

The defaults are the careful ones: **loopback only, TLS on, access token
required**. Binding to the network without TLS is refused outright rather than
quietly sending your token in clear text — if something in front of Mediafin
already terminates TLS, say so explicitly with
`--i-accept-plain-http-on-the-network`.

`openssl` is needed only for generating that first self-signed certificate.
TLS itself does not need it: NIOSSL brings its own BoringSSL.

### What the interface can do

Sign in → **Settings** (import folder, library folders, how titles are
identified, your own model server, Jellyfin) → **Overview** (look for new
files, review each proposed name, tick the ones you want, rename, undo).

`/healthz` answers without a token for uptime monitors — `200` idle, `503`
while running, `500` after a run with failures — and reveals nothing but that.

## Building

The repository is a Swift Package plus an XcodeGen spec.

### Option A — build a `.app` (works with any Xcode)

```bash
./build_app.sh
```

Produces `build/Mediafin.app`. It builds via Xcode (xcodegen + xcodebuild)
when available and falls back to a SwiftPM build with a hand-assembled bundle, so
it does not depend on the Xcode project format / version. On failure it prints
the error and keeps a log at `build/build.log`.

### Option B — Xcode project (requires Xcode 16+)

```bash
brew install xcodegen      # one-time
xcodegen generate          # creates Mediafin.xcodeproj (project format 77)
open Mediafin.xcodeproj
# Select the "Mediafin" scheme and Run (⌘R)
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
    Web/                      HTTP message layer, router, access control,
                              settings & secret stores (portable)
  MediaIdentifierWeb/         HTTPS server (SwiftNIO + NIOSSL), certificate
                              handling, command coordinator
  mediafin/                   The Linux binary: serves the web interface
  MediaIdentifierApp/         SwiftUI macOS front-end (dark "Mediafin" design)
    AppState.swift            View model wiring Core to the UI
    Theme.swift               Colour palette + reusable chips/controls
    ContentView.swift         Title bar + sidebar + main area
    Views/                    SidebarView, QueueView, FileRowView, EmptyDropView,
                              ConvertView, LogView, ConflictResolutionView,
                              MetadataSettingsView
Tests/
  MediaIdentifierCoreTests/   XCTest suite for the Core
  MediaIdentifierWebTests/    End-to-end tests over real sockets, incl. TLS
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

The web interface is treated as a privileged surface — it can see the whole
library — so it is hardened separately:

- **Encrypted by default, and refuses not to be:** TLS 1.2 is the floor, and
  binding to anything but loopback without TLS is refused rather than quietly
  sending the access token in clear text.
- **Authenticated by default:** a 256-bit token, compared in
  length-independent time; an unconfigured token matches nothing instead of
  letting everyone in. Failed logins are rate-limited, and while blocked even
  the correct token is refused so the limit cannot be probed around.
- **Token never in a URL:** it is accepted from a header or the session
  cookie only, because URLs end up in logs, history and referrers. The cookie
  is `HttpOnly`, `SameSite=Strict` and — over TLS — `Secure`.
- **Three layers against cross-site requests:** that cookie policy, a
  `form-action 'self'` CSP, and a per-process CSRF token in every form. A
  cross-site request is refused *before* the credentials are checked, so it
  cannot spend login attempts and lock the real user out.
- **No scripting at all:** the pages use no JavaScript, so their own
  Content-Security-Policy can forbid it outright (`default-src 'none'`).
- **Writes only where intended:** an explicit list of paths accepts a POST;
  everything else answers 405. Redirect targets are never taken from the
  request. An unauthenticated client gets 401 even for unknown paths, so it
  cannot map what exists.
- **Credentials apart from configuration:** `settings.json` has no field for a
  key at all — keys live in `secrets.json`, mode `0600`, written through a
  temporary file created with its permissions already applied so a secret is
  never briefly world-readable. The interface is only ever told *whether* a
  key is stored, never its value.
- **Bounded requests:** anything over 64 KiB stops being buffered and gets a
  413. `/healthz` may answer anonymously for uptime monitors and reveals only
  idle/busy/error — never a file name.

## Note on this environment

This project was authored in a Linux container without an Xcode/Swift
toolchain, so it has not been compiled here. The code targets Swift 5.9 /
macOS 13+ and the Core logic is covered by the included XCTest suite — run
`swift test` on macOS to verify.

## License

Mediafin is free software, licensed under the **GNU General Public License,
version 3 or (at your option) any later version (GPL-3.0-or-later)**. See the
full text in [`LICENSE`](LICENSE).

    Copyright (C) 2026 Mediafin contributors

    This program is free software: you can redistribute it and/or modify it
    under the terms of the GNU General Public License as published by the Free
    Software Foundation, either version 3 of the License, or (at your option)
    any later version.

    This program is distributed in the hope that it will be useful, but
    WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
    or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
    more details.
