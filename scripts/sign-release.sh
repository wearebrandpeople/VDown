#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
SOURCE="$PWD/outputs/VDown.app"
APP="$PWD/outputs/release-2.1.0/VDown.app"
if [ -e "$APP" ]; then
  printf 'Release already exists; move it aside before creating a new release.\n' >&2
  exit 1
fi
mkdir -p "$PWD/outputs/release-2.1.0"
ditto "$SOURCE" "$APP"
BIN="$APP/Contents/Resources/tools"
python3 scripts/sign-fast-engine.py "$BIN/yt-dlp-fast" "$IDENTITY"
codesign --force --sign "$IDENTITY" --timestamp --options runtime --entitlements app/signing/node.entitlements.plist "$BIN/node"
codesign --force --sign "$IDENTITY" --timestamp --options runtime --entitlements app/signing/ytdlp.entitlements.plist "$BIN/yt-dlp"
codesign --force --sign "$IDENTITY" --timestamp --options runtime "$BIN/ffmpeg"
codesign --force --sign "$IDENTITY" --timestamp --options runtime "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$PWD/outputs/release-2.1.0/VDown-notarization.zip"
printf '%s\n' "$APP"
