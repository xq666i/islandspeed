#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodebuild >/dev/null || { echo '需要 macOS 和 Xcode'; exit 1; }
command -v xcodegen >/dev/null || { echo '请先 brew install xcodegen'; exit 1; }
xcodegen generate
xcodebuild -project IslandSpeed.xcodeproj -scheme IslandSpeed -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
APP=build/Build/Products/Release-iphoneos/IslandSpeed.app
test -f "$APP/IslandSpeed"
test -f "$APP/PlugIns/IslandSpeedWidget.appex/IslandSpeedWidget"
test -f "$APP/silence.wav"
test -f "$APP/quiet.wav"
mkdir -p dist
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Payload"
cp -R "$APP" "$STAGING/Payload/"
OUT="$PWD/dist/IslandSpeed-unsigned.ipa"
rm -f "$OUT"
(cd "$STAGING" && /usr/bin/zip -qry "$OUT" Payload)
echo "Unsigned IPA: $OUT"
