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
# The package carries the server, and the native window too when one is given
# or built. Both end up in one package: the desktop it is meant for has GTK
# already, and splitting it would mean two packages to keep in step. On a
# headless server use the tarball, or build without the window.
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
VERSION="${MEDIAFIN_VERSION:-}"
if [ -z "$VERSION" ]; then
  # A valid, sortable version for an untagged build: 1.0.0~gitYYYYMMDD.<sha>
  SHA="$(git rev-parse --short=8 HEAD 2>/dev/null || echo unknown)"
  VERSION="1.0.0~git$(date -u +%Y%m%d).${SHA}"
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
  # so check it is actually an executable for this machine before packaging.
  case "$(file -b "$BIN" 2>/dev/null)" in
    *ELF*executable*|*ELF*shared\ object*) : ;;
    *) echo "FAIL: $BIN is not a Linux executable" >&2; exit 1 ;;
  esac
  chmod +x "$BIN" 2>/dev/null || true
else
  echo "==> Building mediafin (release, static Swift runtime)"
  swift build -c release --product mediafin --static-swift-stdlib
  BIN=.build/release/mediafin
  # Two invocations because SwiftPM takes one --product at a time. The GUI is
  # not static: it links GTK from the system anyway, so a static Swift runtime
  # would only add weight it cannot avoid paying for elsewhere.
  echo "==> Building mediafin-gtk (release)"
  swift build -c release --product mediafin-gtk
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
# `--binary` on its own keeps working for the server-only case.
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
  echo "==> No native window supplied; packaging the server only"
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
mediafin \- rename media into a Jellyfin layout, through a local web interface
.SH SYNOPSIS
.B mediafin
[\fB\-\-port\fR \fIn\fR]
[\fB\-\-bind\fR local|all]
[\fB\-\-no\-tls\fR]
[\fB\-\-cert\fR \fIfile\fR \fB\-\-key\fR \fIfile\fR]
[\fB\-\-config\-dir\fR \fIdir\fR]
.SH DESCRIPTION
Serves a local web interface over HTTPS for renaming downloaded media into a
Jellyfin-compatible layout, and for re-encoding it.
.PP
On the first start an access token and a self\-signed certificate are created
in the configuration directory. The token is printed once; it is needed to
sign in. The certificate's SHA\-256 fingerprint is printed too, to compare
against the browser's warning.
.SH OPTIONS
.TP
.BR \-p ", " \-\-port " " \fIn\fR
Port to listen on. Default 8720.
.TP
.BR \-\-bind " " local|all
Reachable from this machine only (default), or from the network. A network
bind requires TLS.
.TP
.B \-\-no\-tls
Serve plain HTTP. Refused for a network bind unless
.B \-\-i\-accept\-plain\-http\-on\-the\-network
is also given.
.TP
.BR \-\-cert " " \fIfile\fR ", " \-\-key " " \fIfile\fR
Use this PEM certificate chain and key instead of the self\-signed one.
.TP
.BR \-\-config\-dir " " \fIdir\fR
Where to keep the token, certificate and settings. Defaults to
.I $XDG_CONFIG_HOME/mediafin
or
.IR ~/.config/mediafin .
.TP
.B \-\-rotate\-token
Issue a new access token and exit. Signs every browser out.
.TP
.B \-\-print\-token
Print the access token and exit.
.SH FILES
.TP
.I ~/.config/mediafin/token
The access token, mode 0600.
.TP
.I ~/.config/mediafin/cert.pem, ~/.config/mediafin/key.pem
The TLS certificate and its key. The key is mode 0600.
.TP
.I ~/.config/mediafin/settings.json
Settings. Contains no credentials.
.TP
.I ~/.config/mediafin/secrets.json
API keys, mode 0600.
.SH SECURITY
The interface can see the whole media library, so it requires the access
token and is served over TLS. Binding to the network without TLS is refused
rather than sending the token in clear text.
.I /healthz
answers without the token, for uptime monitors, and reveals only
idle/busy/error.
.SH SEE ALSO
.BR ffmpeg (1),
.BR openssl (1)
EOF
gzip -9n "$STAGE/usr/share/man/man1/mediafin.1"

echo "==> Writing the systemd unit"
install -d -m 755 "$STAGE/usr/lib/systemd/system"
cat > "$STAGE/usr/lib/systemd/system/mediafin.service" <<'EOF'
# Deliberately NOT enabled on install: starting a server that exposes your
# media library is your decision, not the package's.
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
Description=Mediafin — media renaming with a local web interface
Documentation=man:mediafin(1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mediafin
Group=mediafin
Environment=MEDIAFIN_CONFIG_DIR=/var/lib/mediafin
ExecStart=/usr/bin/mediafin --bind local
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
Depends: $SHLIB_DEPENDS, adduser, openssl
Recommends: ffmpeg
Description: Rename media into a Jellyfin layout from a local web interface
 Mediafin parses release names, proposes Jellyfin-conformant names and shows
 them for review before anything is moved. It can also re-encode files to
 save space, and tells Jellyfin to rescan once a run finishes.
 .
 The interface is served over HTTPS and requires an access token. It binds to
 loopback by default; binding to the network without TLS is refused rather
 than sending the token in clear text.
 .
 The Swift runtime is linked statically, so no Swift installation is needed.
 openssl is required to create the first self-signed certificate; ffmpeg only
 for re-encoding.
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
    # Only on purge, and only the state directory: tokens and certificates
    # are not worth keeping, but nobody's media lives here.
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
