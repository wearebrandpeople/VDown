#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/outputs/Video İndir.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ui" "$APP/Contents/Resources/tools"
cp app/ui/* "$APP/Contents/Resources/ui/"
cp app/THIRD-PARTY.txt "$APP/Contents/Resources/THIRD-PARTY.txt"
ditto tools/yt-dlp-fast "$APP/Contents/Resources/tools/yt-dlp-fast"
cp tools/yt-dlp "$APP/Contents/Resources/tools/yt-dlp"
cp -L tools/ffmpeg "$APP/Contents/Resources/tools/ffmpeg"
NODE_BINARY="${NODE_BINARY:-$PWD/tools/node}"
if [ ! -f "$NODE_BINARY" ]; then NODE_BINARY="$(command -v node)"; fi
if lipo -info "$NODE_BINARY" | grep -q 'Non-fat'; then
  cp "$NODE_BINARY" "$APP/Contents/Resources/tools/node"
else
  lipo "$NODE_BINARY" -thin arm64 -output "$APP/Contents/Resources/tools/node"
fi
chmod +x "$APP/Contents/Resources/tools/"*
swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -framework AppKit -framework WebKit -framework ServiceManagement app/Models.swift app/EngineRun.swift app/Main.swift app/Pipeline.swift app/Features.swift -o "$APP/Contents/MacOS/VideoIndir"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Video İndir</string>
<key>CFBundleDisplayName</key><string>Video İndir</string>
<key>CFBundleIdentifier</key><string>local.serhat.videoindir</string>
<key>CFBundleExecutable</key><string>VideoIndir</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0.6</string>
<key>CFBundleVersion</key><string>8</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSDownloadsFolderUsageDescription</key><string>Videoları seçtiğin klasöre kaydetmek için erişim gerekir.</string>
</dict></plist>
PLIST
python3 scripts/sign-fast-engine.py "$APP/Contents/Resources/tools/yt-dlp-fast" -
for bin in ffmpeg node yt-dlp; do codesign --force --sign - "$APP/Contents/Resources/tools/$bin"; done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
