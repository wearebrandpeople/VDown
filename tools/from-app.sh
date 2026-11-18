#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Usage: bash tools/from-app.sh '/Applications/VDown.app'}"
SOURCE="$APP/Contents/Resources/tools"
for tool in yt-dlp-fast yt-dlp ffmpeg node; do
  [ -e "$SOURCE/$tool" ] || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 1; }
done
for tool in yt-dlp-fast yt-dlp ffmpeg node; do
  ditto "$SOURCE/$tool" "$ROOT/tools/$tool"
done
printf 'Dependencies copied to tools/.\n'
