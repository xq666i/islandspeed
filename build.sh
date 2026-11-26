#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodebuild >/dev/null || { echo '需要 macOS 和 Xcode'; exit 1; }
command -v xcodegen >/dev/null || { echo '请先 brew install xcodegen'; exit 1; }
supports_measurement_sdk() {
    local version
    version=$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null) || return 1
    [[ ${version%%.*} =~ ^[0-9]+$ ]] && (( ${version%%.*} >= 26 ))
}
if ! supports_measurement_sdk; then
    for candidate in /Applications/Xcode*.app/Contents/Developer; do
        if [[ -d "$candidate" ]] && DEVELOPER_DIR="$candidate" supports_measurement_sdk; then
            export DEVELOPER_DIR="$candidate"
            break
        fi
    done
fi
supports_measurement_sdk || { echo '系统后台测量需要 Xcode 26 或更高版本的 iPhoneOS SDK'; exit 1; }
xcodegen generate
xcodebuild -project IslandSpeed.xcodeproj -scheme IslandSpeed -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
APP=build/Build/Products/Release-iphoneos/IslandSpeed.app
test -f "$APP/IslandSpeed"
test -f "$APP/PlugIns/IslandSpeedWidget.appex/IslandSpeedWidget"
test -f "$APP/silence.wav"
test -f "$APP/quiet.wav"
task_pattern=$(/usr/libexec/PlistBuddy -c 'Print :BGTaskSchedulerPermittedIdentifiers:0' "$APP/Info.plist")
[[ "$task_pattern" == *'.measurement.*' && "$task_pattern" != *'$('* ]] || { echo '后台任务标识未正确写入 Info.plist'; exit 1; }
mkdir -p dist
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Payload"
cp -R "$APP" "$STAGING/Payload/"
OUT="$PWD/dist/IslandSpeed-unsigned.ipa"
rm -f "$OUT"
(cd "$STAGING" && /usr/bin/zip -qry "$OUT" Payload)
echo "Unsigned IPA: $OUT"
