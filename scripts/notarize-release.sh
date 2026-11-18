#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/outputs/release/Video İndir.app"
ARCHIVE="$PWD/outputs/release/Video-Indir-notarization.zip"
PROFILE="${NOTARY_PROFILE:-VideoIndir}"
codesign --verify --deep --strict "$APP"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --output-format json > outputs/release/notary-submission.json
cat outputs/release/notary-submission.json
printf '\nSubmission saved. Use notarytool info/log to check it before stapling.\n'
