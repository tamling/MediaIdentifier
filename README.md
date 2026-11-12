<p align="center"><img src="docs/logo.png" width="128" alt="Mediafin"></p>

# Mediafin

Renames downloaded media into a **Jellyfin-compatible** layout, with a preview
before anything touches the disk. One window, one engine, Linux.

<p align="center"><img src="gtk-window.png" width="720" alt="The Mediafin window"></p>

---

## What it does

- **Drag in** files or whole folders (MKV, AVI, MP4, MOV, M4V, …) from the file
  manager, or point it at an import folder and press **Durchsuchen**.
- It **parses the release name** — title, year, season/episode, resolution,
  release group.
- It **proposes Jellyfin-conformant names** and shows them as a **preview**:
  - Films → `Interstellar (2014)/Interstellar (2014).mkv`
  - Series → `The Last of Us/Season 01/The Last of Us - S01E01.mkv`
  - Music → `Artist/Album (1998)/01 - Title.flac`, from the file's own tags
- You **tick, untick or hand-edit** each row, then press **Umbenennen**.
- Subtitles and extras (`.srt`, `.ass`, `.sub`, `.nfo`, posters, samples) are
  **renamed alongside** the video.
- Optionally **sends** the sorted files to another machine over rsync or SFTP,
  with a path per kind, and **re-encodes** to save space.
- Every change is **logged** and can be **undone**.
- Everything runs **locally**. Only a title and a year are ever sent anywhere,
  and only if you switch online identification on.

## Installing

```bash
wget https://github.com/tamling/MediaIdentifier/releases/download/latest/mediafin-linux-x86_64.deb
sudo apt install ./mediafin-linux-x86_64.deb
mediafin-gtk
```

The package carries its own Swift runtime, so nothing else has to be installed
for the window to start. `ffmpeg` is needed for converting and for reading
music tags, `rsync` or `openssh-client` for sending to a server, `sshpass` only
to log in with a password instead of a key, `yt-dlp` to fetch from a link. Each
says which program it wants when that program is missing, rather than failing
obscurely.

## The window

Everything that is not the list lives behind the **menu button** in the header:

| Menu entry | |
|---|---|
| **Einstellungen …** | Library folders, identification, schedule, server — all in one window, with one **Übernehmen** button at the bottom that says `Übernommen um 14:52:31`. The time is there so a second press is visibly a second press. |
| **Status …** | The traffic light: one lamp per thing that can be wrong, each carrying the sentence that says what to do about it. |
| **Aus dem Netz laden …** | Fetch a video from a link with `yt-dlp`. |

The main surface is the list, its buttons, and a footer with the last thing
that happened and the version. While the list is empty, that same sentence is
repeated in the middle of the window, because the middle is where you are
looking when you are wondering what happened.

## Running by itself

The schedule in the settings runs either daily at a fixed time or every few
hours, and may scan, rename and send — each asked for separately, all three off
by default. A run that only scans leaves a list for you to look at, which is
what most people mean by "check overnight".

The timer lives in the engine, so it fires while the window is open. For runs
with no window, the package installs a service:

```bash
sudo systemctl enable --now mediafin      # runs mediafin --watch
```

It is deliberately **not** enabled on install: letting a service move your
media unattended is your decision, not the package's. Read the unit first — it
runs as its own `mediafin` user, which by default can reach none of your files.
`mediafin --once` does whatever is due and exits, for a cron line of your own.

Two things the schedule deliberately does and does not do:

- **It survives a restart.** The last run is recorded in `schedule-state.json`
  beside the settings, so a machine that was off at 03:00 does the missed run
  when it comes back rather than skipping the night — or, worse, running the
  moment it boots, every time.
- **It does not catch up.** Three days asleep produces one run, not three.
- **It refuses to rename without a library folder.** Without one the proposal
  is a folder beside the file itself, so each run would bury it a level deeper.
  Looking at the proposal would show you that; nobody is looking at this one.

Two Mediafins sharing a configuration directory will not both do the same run;
the second waits for the next.

## Architecture

```
Sources/
  MediaIdentifierCore/        Pure Foundation — no interface imports, fully testable
    Models/                   ParsedRelease, MediaFile, CompanionFile
    Parsing/                  ReleaseNameParser, token vocabulary, regex helpers
    Naming/                   JellyfinNamer (naming rules)
    Music/                    MusicNamer, tag reading, cover extraction
    Planning/                 RenamePlanner, RenameItem, conflict detection
    FileOps/                  MediaScanner, RenameExecutor, file-type registry
    Logging/                  RenameLog
    Undo/                     RenameJournal
    Metadata/                 MetadataProvider (+ offline, TMDb, local LLM)
    Conversion/               FFmpeg argument builder + converter
    Remote/                   rsync / SFTP command building and transfer
    Web/                      Settings, commands, status snapshot, stores.
                              The `Web` prefix is left over from a web
                              interface that no longer exists; this is the
                              engine's own vocabulary.
    App/                      AppCoordinator — the engine every front-end drove
  MediaIdentifierGtk/         The window (GTK3)
  CMediafinGtk/               Accepting dropped files, in C
  mediafin/                   Headless runner: holds the engine so the
                              schedule fires with no window open. Draws nothing.
Tests/
  MediaIdentifierCoreTests/   XCTest suite for the engine
```

There were once four front-ends over this engine: this window, a terminal
interface, a local web interface and a SwiftUI app for macOS. Keeping them in
step was most of the work and none of the value — every setting had to be built
three times, and a release could be green while the one front-end anybody ran
was broken. The three nobody ran are gone, along with SwiftNIO, which only the
web server needed. The engine has no dependencies at all.

## How it is tested

There is no Swift toolchain on the machine this is developed from, so CI is the
only compiler and the only test runner. That has shaped what the tests are.

The engine's logic is tested directly, and the window is **driven** rather than
photographed. `mediafin-gtk` has modes that CI uses:

| | |
|---|---|
| `--screenshot FILE` | render the window to a PNG and report what was in it |
| `--press-scan` | press **Durchsuchen** through the signal and print what the window then says, in the footer *and* in the middle |
| `--press-apply` | open the settings, press **Übernehmen** twice, and print what it says each time |
| `--drop FILE…` | hand files over exactly as a drop does, skipping GTK's drag plumbing, which cannot be faked from a script |

This exists because a picture of a window proves only that it draws. Two
releases went out green while the scan button said nothing a person could see
and dropping a file took the window down — CI had never pressed anything. The
status text is read back off the labels rather than from the engine's own
snapshot: asking the engine what it thinks it said would agree with itself and
prove nothing.

`tools/check-workflows.py` refuses a workflow file that GitHub Actions would
refuse, for the same reason: `yaml.safe_load` accepts a mapping with the same
key twice and keeps the last, Actions rejects it outright, and a check that
cannot see the fault in front of it is worse than no check because it is
believed.

```bash
swift test                    # the engine
swift build --product mediafin-gtk
```

## Conflict handling

When a proposed name is already taken, the setting decides: **skip**, **rename**
(` (1)`, ` (2)`, …), **replace**, or **ask**.

**Replace** moves the file it displaces aside rather than deleting it — on Linux
into a hidden `.mediafin-trash` folder beside the library, journalled so undo
can put it back. And it does it in an order that cannot leave a gap: the
incoming file is brought into the destination's own directory under a hidden
name first, and only once it is there is the old one moved aside and the new one
renamed into place. Those last two are renames within one directory on one
filesystem. If one fails anyway, both are undone and the library keeps its own
copy.

## Security

No media ever leaves the machine. Online identification sends a title and a
year, nothing else, and only when switched on.

- **Secrets are not in the settings file.** API keys and the server password
  live in `secrets.json`, mode 0600; `settings.json` can be pasted into a bug
  report.
- **A password is never an argument.** It reaches `ssh` through the
  environment, because anyone on the machine can read `ps`.
- **Host keys are checked.** `StrictHostKeyChecking` is never `no`. The
  optional "trust this server the first time" is `accept-new`, which remembers
  a server it has not met and still refuses one whose key has *changed* — which
  is the case that matters.
- **Names that cannot be quoted are refused, not escaped.** A filename
  containing a newline would become a second command in an SFTP batch script,
  and `sftp`'s `!` runs a local shell. There is nothing to escape it to, so the
  user is told which file to rename.
- **Nothing is deleted to make room.** "Delete the local copy after sending" is
  off by default and stays off unless you turn it on: sending is a copy, which
  can be undone by deleting what arrived; deleting the original cannot.

## License

See [LICENSE](LICENSE).
