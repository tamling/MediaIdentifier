#!/usr/bin/env bash
# Builds MediaIdentifier.app locally and leaves it at build/MediaIdentifier.app.
# Tries Xcode (xcodegen + xcodebuild) first; falls back to a SwiftPM build with
# a hand-assembled .app bundle. On failure it prints the error and keeps a log
# instead of vanishing.
set -uo pipefail
cd "$(dirname "$0")"

NAME="MediaIdentifier"
PRODUCT="MediaIdentifierApp"
BUNDLE_ID="com.mediaidentifier.app"
OUT="build"
LOG="$OUT/build.log"
ICON_SRC="docs/logo.png"

mkdir -p "$OUT"; : > "$LOG"
say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; }

if ! command -v swift >/dev/null 2>&1 && ! command -v xcodebuild >/dev/null 2>&1; then
  err "Neither 'swift' nor 'xcodebuild' found. Install Xcode or the Command Line Tools: xcode-select --install"
  exit 1
fi

APP=""

# ---- Path 1: Xcode project (proper .app incl. icon) — needs Xcode 16+ --------
if command -v xcodegen >/dev/null 2>&1 && command -v xcodebuild >/dev/null 2>&1; then
  say "Generating Xcode project (xcodegen)…"
  if xcodegen generate >>"$LOG" 2>&1; then
    say "Building with xcodebuild (Release)…"
    if xcodebuild -project "$NAME.xcodeproj" -scheme "$NAME" -configuration Release \
        -derivedDataPath "$OUT/dd" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build >>"$LOG" 2>&1; then
      APP="$(/usr/bin/find "$OUT/dd/Build/Products/Release" -maxdepth 1 -name '*.app' 2>/dev/null | head -1)"
    else
      err "xcodebuild failed (Xcode older than 16 cannot open the project). Falling back to SwiftPM…"
    fi
  fi
fi

# ---- Path 2: SwiftPM build + manual .app bundle (any toolchain) --------------
if [ -z "$APP" ]; then
  say "Building with SwiftPM (Release)…"
  if ! swift build -c release --product "$PRODUCT" >>"$LOG" 2>&1; then
    err "swift build failed. Last lines:"
    tail -n 30 "$LOG" >&2
    err "Full log: $LOG  — please share this output."
    exit 1
  fi
  BINDIR="$(swift build -c release --product "$PRODUCT" --show-bin-path 2>>"$LOG")"
  BIN="$BINDIR/$PRODUCT"
  if [ ! -f "$BIN" ]; then err "No binary at $BIN (see $LOG)"; exit 1; fi

  APP="$OUT/$NAME.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN" "$APP/Contents/MacOS/$NAME"
  chmod +x "$APP/Contents/MacOS/$NAME"

  ICON_KEY=""
  if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 && [ -f "$ICON_SRC" ]; then
    ICONSET="$OUT/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for spec in 16:icon_16x16 32:[email protected] 32:icon_32x32 64:[email protected] \
                128:icon_128x128 256:[email protected] 256:icon_256x256 \
                512:[email protected] 512:icon_512x512 1024:[email protected]; do
      sips -z "${spec%%:*}" "${spec%%:*}" "$ICON_SRC" --out "$ICONSET/${spec##*:}.png" >/dev/null 2>&1 || true
    done
    if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>>"$LOG"; then
      ICON_KEY=$'\t<key>CFBundleIconFile</key>\n\t<string>AppIcon</string>'
    fi
  fi

  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>$NAME</string>
	<key>CFBundleDisplayName</key><string>Mediafin</string>
	<key>CFBundleExecutable</key><string>$NAME</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
$ICON_KEY
</dict>
</plist>
PLIST
fi

# ---- Normalise location & finish --------------------------------------------
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  err "No .app was produced. See $LOG"
  exit 1
fi
if [ "$APP" != "$OUT/$NAME.app" ]; then
  rm -rf "$OUT/$NAME.app"; cp -R "$APP" "$OUT/$NAME.app"; APP="$OUT/$NAME.app"
fi

codesign --force --deep --sign - "$APP" >>"$LOG" 2>&1 || true
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

say "Done: $APP"
open "$APP" 2>/dev/null || open -R "$APP" 2>/dev/null || true
