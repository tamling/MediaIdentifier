#!/usr/bin/env bash
# Builds MediaIdentifier.app locally (macOS + Xcode required).
set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate

xcodebuild \
  -project MediaIdentifier.xcodeproj \
  -scheme MediaIdentifier \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

APP=$(find build/Build/Products/Release -maxdepth 1 -name '*.app' | head -1)
echo "Built: $APP"
open -R "$APP"
