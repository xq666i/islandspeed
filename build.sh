#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
for asset in App/silence.wav App/quiet.wav; do
    if [[ ! -s "$asset" ]]; then
        echo "缺少或为空的音频资源：$asset。请从完整项目包恢复该文件后再构建。" >&2
        exit 1
    fi
done
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
python3 scripts/package_ipa.py \
    build/Build/Products/Release-iphoneos/IslandSpeed.app \
    dist/IslandSpeed-unsigned.ipa
