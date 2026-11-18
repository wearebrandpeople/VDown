#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/outputs/release-2.1.0/VDown.app"
ARCHIVE="$PWD/outputs/release-2.1.0/VDown-notarization.zip"
PROFILE="${NOTARY_PROFILE:-VideoIndir}"
codesign --verify --deep --strict "$APP"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --output-format json > outputs/release-2.1.0/notary-submission.json
cat outputs/release-2.1.0/notary-submission.json
printf '\nSubmission saved. Use notarytool info/log to check it before stapling.\n'
