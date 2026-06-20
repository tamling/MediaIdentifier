#!/usr/bin/env bash
# Builds MediaIdentifier.app locally without depending on the Xcode project
# format. Uses SwiftPM to compile and assembles the .app bundle directly, so it
# works regardless of the installed Xcode version. (The Xcode project is still
# available for development: `xcodegen generate && open MediaIdentifier.xcodeproj`,
# which requires Xcode 16+.)
set -euo pipefail
cd "$(dirname "$0")"

NAME="MediaIdentifier"
PRODUCT="MediaIdentifierApp"
BUNDLE_ID="com.mediaidentifier.app"
ICON_SRC="docs/logo.png"

echo "==> Building $PRODUCT (release) with SwiftPM…"
swift build -c release --product "$PRODUCT"
BIN="$(swift build -c release --product "$PRODUCT" --show-bin-path)/$PRODUCT"
[ -f "$BIN" ] || { echo "error: no binary produced at $BIN" >&2; exit 1; }

APP="build/$NAME.app"
echo "==> Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
chmod +x "$APP/Contents/MacOS/$NAME"

# App icon (best effort) — sips + iconutil ship with macOS, no Xcode needed.
ICON_KEY=""
if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 && [ -f "$ICON_SRC" ]; then
  ICONSET="build/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for spec in 16:icon_16x16 32:[email protected] 32:icon_32x32 64:[email protected] \
              128:icon_128x128 256:[email protected] 256:icon_256x256 \
              512:[email protected] 512:icon_512x512 1024:[email protected]; do
    px="${spec%%:*}"; nm="${spec##*:}"
    sips -z "$px" "$px" "$ICON_SRC" --out "$ICONSET/$nm.png" >/dev/null 2>&1 || true
  done
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    ICON_KEY=$'\t<key>CFBundleIconFile</key>\n\t<string>AppIcon</string>'
  fi
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundleDisplayName</key>
	<string>Jellyfin Renamer</string>
	<key>CFBundleExecutable</key>
	<string>$NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
$ICON_KEY
</dict>
</plist>
PLIST

# Ad-hoc sign so it launches without Gatekeeper complaints.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> Done: $APP"
open "$APP" 2>/dev/null || open -R "$APP"
