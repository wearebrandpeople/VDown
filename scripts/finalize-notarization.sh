#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/outputs/release-2.1.0/VDown.app"
PROFILE="${NOTARY_PROFILE:-VideoIndir}"
SUBMISSION_ID=$(python3 -c 'import json; print(json.load(open("outputs/release-2.1.0/notary-submission.json"))["id"])')
xcrun notarytool info "$SUBMISSION_ID" --keychain-profile "$PROFILE" --output-format json > outputs/release-2.1.0/notary-status.json
python3 -c 'import json; s=json.load(open("outputs/release-2.1.0/notary-status.json")); print(s["status"]); assert s["status"]=="Accepted", "Notarization has not been accepted"'
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$PWD/outputs/release-2.1.0/VDown-Mac.zip"
