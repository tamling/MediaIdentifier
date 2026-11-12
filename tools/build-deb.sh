#!/usr/bin/env bash
#
# Builds a Debian package for the `mediafin` binary.
#
# The dependency list is not written by hand: dpkg-shlibdeps reads the actual
# ELF and resolves every shared library to the package that provides it, so
# `apt install ./mediafin_*.deb` pulls exactly what the binary needs. Guessing
# that list is how a package ends up almost working.
#
#   ./tools/build-deb.sh                      # build from source, then package
#   ./tools/build-deb.sh --binary ./mediafin  # package a binary you already have
#   …           --binary ./mediafin --gtk-binary ./mediafin-gtk
#
# The package carries the scheduler binary, and the native window too when
# one is given or built. Both end up in one package: the desktop it is meant
# for has GTK already, and splitting it would mean two packages to keep in
# step. On a headless machine use the tarball, or build without the window.
#
# The second form needs no Swift toolchain, so you can turn the published
# tarball into a .deb on the machine you want to install it on:
#
#   tar -xzf mediafin-linux-x86_64.tar.gz
#   ./tools/build-deb.sh --binary ./mediafin
#
# Needs: dpkg-dev (dpkg-shlibdeps, dpkg-deb). A Swift toolchain only for the
# first form.
#
set -euo pipefail

cd "$(dirname "$0")/.."

PREBUILT=""
PREBUILT_GTK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --binary)
      [ $# -ge 2 ] || { echo "--binary needs a path" >&2; exit 2; }
      PREBUILT="$2"
      shift 2
      ;;
    --gtk-binary)
      [ $# -ge 2 ] || { echo "--gtk-binary needs a path" >&2; exit 2; }
      PREBUILT_GTK="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1 (try --help)" >&2
      exit 2
      ;;
  esac
done

ARCH="$(dpkg --print-architecture)"

# Read from the source rather than written here, so the package and the
# window cannot disagree about which version is running.
VERSION_FILE="Sources/MediaIdentifierCore/App/MediafinVersion.swift"
BASE_VERSION="$(sed -n 's/.*static let number = "\([0-9.]*\)".*/\1/p' "$VERSION_FILE")"
[ -n "$BASE_VERSION" ] || {
  echo "FAIL: could not read the version from $VERSION_FILE" >&2
  exit 1
}

VERSION="${MEDIAFIN_VERSION:-}"
if [ -z "$VERSION" ]; then
  # A valid, sortable version for an untagged build:
  # <number>~gitYYYYMMDD.<sha>
  SHA="$(git rev-parse --short=8 HEAD 2>/dev/null || echo unknown)"
  VERSION="${BASE_VERSION}~git$(date -u +%Y%m%d).${SHA}"
fi
PACKAGE="mediafin_${VERSION}_${ARCH}.deb"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# mktemp -d gives 0700, and dpkg-deb records the staging root as the package's
# "./" entry — which IS the filesystem root on the target machine. dpkg applies
# a directory's archived mode even when the directory already exists, so a
# 0700 staging root would chmod / to 0700 on install and lock every non-root
# process out of the system. Verified by extracting such a package over a 0755
# directory: it came back 0700.
chmod 755 "$STAGE"

if [ -n "$PREBUILT" ]; then
  echo "==> Using the binary you supplied: $PREBUILT"
  BIN="$PREBUILT"
  [ -f "$BIN" ] || { echo "FAIL: no file at $BIN" >&2; exit 1; }
  # A wrong file here would produce a package that installs and then fails,
  # so check it is actually an ELF binary before packaging.
  #
  # Read the magic number rather than asking `file`: that is not installed
  # everywhere, and when it is missing the old form produced no output, matched
  # nothing, and rejected a perfectly good binary with a message blaming the
  # binary. `od` is in coreutils and is always there.
  case "$(od -An -N4 -tx1 "$BIN" 2>/dev/null | tr -d ' \n')" in
    7f454c46) : ;;   # 0x7F 'E' 'L' 'F'
    *) echo "FAIL: $BIN is not an ELF binary" >&2; exit 1 ;;
  esac
  chmod +x "$BIN" 2>/dev/null || true
else
  echo "==> Building mediafin (release, static Swift runtime)"
  swift build -c release --product mediafin --static-swift-stdlib
  BIN=.build/release/mediafin
  # Two invocations because SwiftPM takes one --product at a time. Both
  # static: linking GTK from the system says nothing about Swift's own
  # runtime, and without this the window needs libswiftCore.so and dies with
  # a loader error on any machine that has no Swift installation.
  echo "==> Building mediafin-gtk (release, static Swift runtime)"
  swift build -c release --product mediafin-gtk --static-swift-stdlib
  PREBUILT_GTK=.build/release/mediafin-gtk
fi
[ -x "$BIN" ] || { echo "FAIL: $BIN is not executable" >&2; exit 1; }

echo "==> Staging the package tree"
install -D -m 755 "$BIN"       "$STAGE/usr/bin/mediafin"
install -D -m 644 README.md    "$STAGE/usr/share/doc/mediafin/README.md"
install -D -m 644 LICENSE      "$STAGE/usr/share/doc/mediafin/copyright"
install -d -m 755 "$STAGE/DEBIAN"

# The native window, when there is one to ship. Optional rather than required
# so the package can still be built on a machine without GTK headers, and so
# `--binary` on its own keeps working for the scheduler-only case.
if [ -n "$PREBUILT_GTK" ]; then
  [ -x "$PREBUILT_GTK" ] || { echo "FAIL: $PREBUILT_GTK is not executable" >&2; exit 1; }
  echo "==> Including the native window: $PREBUILT_GTK"
  install -D -m 755 "$PREBUILT_GTK" "$STAGE/usr/bin/mediafin-gtk"

  # So it appears in the application menu rather than only on the command
  # line. The icon is a stock name the user's icon theme already provides —
  # shipping our own would mean an asset to maintain for no gain yet.
  install -d -m 755 "$STAGE/usr/share/applications"
  cat > "$STAGE/usr/share/applications/mediafin.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Mediafin
GenericName=Media renamer
Comment=Identify and rename media files for a Jellyfin library
Exec=mediafin-gtk
Icon=multimedia-video-player
Terminal=false
Categories=AudioVideo;Video;Utility;
Keywords=media;rename;jellyfin;movies;series;
StartupNotify=true
DESKTOP
  chmod 644 "$STAGE/usr/share/applications/mediafin.desktop"
else
  echo "==> No native window supplied; packaging the scheduler only"
fi

# Debian wants a changelog, compressed, with no timestamp inside the archive
# that changes per build beyond the version itself.
install -d -m 755 "$STAGE/usr/share/doc/mediafin"
cat > "$STAGE/usr/share/doc/mediafin/changelog.Debian" <<EOF
mediafin ($VERSION) unstable; urgency=low

  * Build from $(git rev-parse HEAD 2>/dev/null || echo "an unknown revision").

 -- Mediafin <noreply@example.invalid>  $(date -uR)
EOF
gzip -9n "$STAGE/usr/share/doc/mediafin/changelog.Debian"

echo "==> Writing the man page"
install -d -m 755 "$STAGE/usr/share/man/man1"
cat > "$STAGE/usr/share/man/man1/mediafin.1" <<'EOF'
.TH MEDIAFIN 1 "" "mediafin" "User Commands"
.SH NAME
mediafin \- run Mediafin's scheduled work with no window open
.SH SYNOPSIS
.B mediafin
\fB\-\-watch\fR | \fB\-\-once\fR | \fB\-\-version\fR | \fB\-\-help\fR
.SH DESCRIPTION
Mediafin's interface is
.BR mediafin\-gtk (1).
This command draws nothing: it exists so that scheduled scans, renames and
transfers happen while that window is closed.
.PP
There used to be a local web interface and a terminal interface here. Both are
gone, and so are their options \(em there is nothing to serve and nothing to
draw.
.SH OPTIONS
.TP
.B \-\-watch
Hold the engine and let its schedule fire. Does not exit on its own; this is
what the systemd service starts.
.TP
.B \-\-once
Do whatever the schedule says is due, then exit. For a cron line of your own.
It returns only when the work has finished, so a rename is never cut short.
.TP
.B \-\-version
Print the version and exit.
.SH FILES
.TP
.I ~/.config/mediafin/settings.json
Settings. Contains no credentials.
.TP
.I ~/.config/mediafin/secrets.json
API keys, mode 0600.
.SH ENVIRONMENT
.TP
.B MEDIAFIN_CONFIG_DIR
Use this directory instead of
.IR $XDG_CONFIG_HOME/mediafin .
.SH SEE ALSO
.BR mediafin-gtk (1),
.BR ffmpeg (1)
EOF
gzip -9n "$STAGE/usr/share/man/man1/mediafin.1"

echo "==> Writing the systemd unit"
install -d -m 755 "$STAGE/usr/lib/systemd/system"
cat > "$STAGE/usr/lib/systemd/system/mediafin.service" <<'EOF'
# Deliberately NOT enabled on install: letting a service move your media
# unattended is your decision, not the package's.
#
# Before `systemctl enable --now mediafin`, give the service access to your
# media. The mediafin user owns nothing by default, so either add it to the
# group that owns your library:
#
#     usermod -aG <your-media-group> mediafin
#
# or run it as yourself with an override:
#
#     systemctl edit mediafin
#     [Service]
#     User=<you>
#     Group=<you>
#
[Unit]
Description=Mediafin — scheduled media renaming, with no window open
Documentation=man:mediafin(1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mediafin
Group=mediafin
Environment=MEDIAFIN_CONFIG_DIR=/var/lib/mediafin
ExecStart=/usr/bin/mediafin --watch
Restart=on-failure
RestartSec=5

# The service only needs its own state directory and the media it is pointed
# at; everything else is off limits.
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=full
# Not ProtectHome: someone who overrides User= to themselves usually has the
# library under their home directory, and a read-only /home would make every
# rename fail for a reason that is hard to see from the interface. Tighten it
# in an override if your media lives elsewhere.
ProtectHome=no
ProtectControlGroups=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
StateDirectory=mediafin
StateDirectoryMode=0700

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$STAGE/usr/lib/systemd/system/mediafin.service"

echo "==> Resolving dependencies from the binary"
# Outside the staging tree: anything under $STAGE ends up inside the package.
SHLIBS_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$SHLIBS_DIR"' EXIT
# dpkg-shlibdeps wants a debian/control it can parse, not just a file that
# exists.
install -d "$SHLIBS_DIR/debian"
cat > "$SHLIBS_DIR/debian/control" <<'CONTROL'
Source: mediafin

Package: mediafin
Architecture: any
Description: placeholder for dpkg-shlibdeps
CONTROL
# Every shipped ELF, not just the server: the window links GTK, and a package
# that lists only the server's libraries would install and then fail to start
# the thing the menu entry points at.
SHLIB_TARGETS=("$STAGE/usr/bin/mediafin")
[ -n "$PREBUILT_GTK" ] && SHLIB_TARGETS+=("$STAGE/usr/bin/mediafin-gtk")
( cd "$SHLIBS_DIR" && dpkg-shlibdeps -O --ignore-missing-info \
    "${SHLIB_TARGETS[@]}" > shlibdeps.out 2>shlibdeps.err ) || {
  echo "FAIL: dpkg-shlibdeps could not resolve the libraries:" >&2
  cat "$SHLIBS_DIR/shlibdeps.err" >&2
  exit 1
}
# Output looks like: shlibs:Depends=libc6 (>= 2.34), libcurl4 (>= 7.16.2), …
SHLIB_DEPENDS="$(sed -n 's/^shlibs:Depends=//p' "$SHLIBS_DIR/shlibdeps.out")"
[ -n "$SHLIB_DEPENDS" ] || { echo "FAIL: no dependencies resolved" >&2; exit 1; }
echo "    $SHLIB_DEPENDS"

INSTALLED_SIZE="$(du -ks --exclude=DEBIAN "$STAGE" | cut -f1)"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: mediafin
Version: $VERSION
Architecture: $ARCH
Maintainer: Mediafin <noreply@example.invalid>
Installed-Size: $INSTALLED_SIZE
Section: video
Priority: optional
Depends: $SHLIB_DEPENDS, adduser
Recommends: ffmpeg
Suggests: yt-dlp
Description: Rename media into a Jellyfin layout, in a native window
 Mediafin parses release names, proposes Jellyfin-conformant names and shows
 them for review before anything is moved. It can also re-encode files to
 save space, and tells Jellyfin to rescan once a run finishes.
 .
 The interface is mediafin-gtk, a GTK3 window: files and folders can be
 dragged into it from the file manager. The mediafin command draws nothing;
 it exists so scheduled runs happen while the window is closed.
 .
 Fetching a video from a link with yt-dlp, and sorting a music library from
 its own tags, are both optional; each names the program it needs when that
 program is absent, rather than failing obscurely. yt-dlp is usually
 installed with pip rather than from the distribution, which is why it is a
 suggestion and not a recommendation.
 .
 The Swift runtime is linked statically, so no Swift installation is needed.
 ffmpeg is only needed for re-encoding.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

case "$1" in
  configure)
    # A system account that owns only its own state. It deliberately has no
    # access to any media until an administrator grants it.
    if ! getent passwd mediafin >/dev/null; then
      adduser --system --group --no-create-home \
              --home /var/lib/mediafin \
              --gecos "Mediafin" mediafin
    fi
    install -d -o mediafin -g mediafin -m 0700 /var/lib/mediafin

    if [ -d /run/systemd/system ]; then
      systemctl daemon-reload || true
      # Bring back a service that was already running before an upgrade.
      # try-restart does nothing at all when the unit is stopped, so a fresh
      # install still starts nothing: exposing your media library remains your
      # decision, see the comment at the top of the unit file.
      systemctl try-restart mediafin.service || true
    fi
    ;;
esac
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e

# Only when the package is going away. dpkg calls prerm with "upgrade" too,
# and stopping there would leave the service down for good: postinst
# deliberately never starts anything, so nothing would bring it back after a
# routine `apt upgrade`.
case "$1" in
  remove|deconfigure)
    if [ -d /run/systemd/system ]; then
      systemctl stop mediafin.service || true
    fi
    ;;
esac
EOF
chmod 755 "$STAGE/DEBIAN/prerm"

cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e

case "$1" in
  remove)
    if [ -d /run/systemd/system ]; then
      systemctl daemon-reload || true
    fi
    ;;
  purge)
    # Only on purge, and only the state directory: stored keys are not
    # worth keeping, and nobody's media lives here.
    rm -rf /var/lib/mediafin
    if getent passwd mediafin >/dev/null; then
      deluser --system mediafin || true
    fi
    ;;
esac
EOF
chmod 755 "$STAGE/DEBIAN/postrm"

echo "==> Building $PACKAGE"
# Deterministic ownership: the staging tree is built as whatever user runs
# this, but everything in the package belongs to root.
# xz, not dpkg-deb's default. Modern dpkg defaults to zstd, but apt can only
# take a .deb on the command line if it can read that .deb's control member
# itself, and apt is built without zstd on Debian-based systems (LMDE, Debian
# up to bullseye). There it refuses the file with
#   E: Unsupported file ./mediafin-linux-x86_64.deb given on commandline
# which reads like a corrupt download and is not one. xz is understood
# everywhere, costs a few seconds more to build, and compresses better.
dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$PACKAGE" >/dev/null
ls -l "$PACKAGE"

echo "==> Verifying"
dpkg-deb --info "$PACKAGE" | sed 's/^/    /'
echo "    --- contents ---"
dpkg-deb --contents "$PACKAGE" | awk '{print "    " $6, $1}'

# A package whose binary cannot run is not worth shipping.
EXTRACT="$(mktemp -d)"
dpkg-deb --extract "$PACKAGE" "$EXTRACT"
"$EXTRACT/usr/bin/mediafin" --help > /dev/null
rm -rf "$EXTRACT"

if command -v lintian >/dev/null; then
  echo "    --- lintian ---"
  # Informational: a hand-built package trips a few style tags that do not
  # affect whether it installs and works.
  lintian --no-tag-display-limit "$PACKAGE" 2>&1 | sed 's/^/    /' || true
fi

echo
echo "Built $PACKAGE"
echo "Install with:  sudo apt install ./$PACKAGE"
