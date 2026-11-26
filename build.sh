#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodebuild >/dev/null || { echo '需要 macOS 和 Xcode'; exit 1; }
command -v xcodegen >/dev/null || { echo '请先 brew install xcodegen'; exit 1; }
# This experiment must never silently fall back to the legacy route.
has_routing_sdk() {
    local version
    version=$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null) || return 1
    [[ ${version%%.*} =~ ^[0-9]+$ ]] && (( ${version%%.*} >= 27 ))
}
if ! has_routing_sdk; then
    for candidate in /Applications/Xcode*.app/Contents/Developer; do
        if [[ -d "$candidate" ]] && DEVELOPER_DIR="$candidate" has_routing_sdk; then
            export DEVELOPER_DIR="$candidate"
            break
        fi
    done
fi
has_routing_sdk || { echo 'ERROR: iOS 27 SDK required. Refusing to create a legacy-route IPA.' >&2; exit 1; }
echo 'Intent routing: REQUIRED explicit iOS 27 main target'
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
xcodegen generate
# Verify explicit target-level flags and version after regenerating the project.
for target in IslandSpeed IslandSpeedWidget; do
    resolved=$(xcodebuild -project IslandSpeed.xcodeproj -target "$target" -configuration Release -sdk iphoneos -showBuildSettings)
    flags=$(printf '%s\n' "$resolved" | awk '$1 == "SWIFT_ACTIVE_COMPILATION_CONDITIONS" && $2 == "=" { $1=""; $2=""; print; exit }')
    echo "$target SWIFT_ACTIVE_COMPILATION_CONDITIONS =$flags"
    case " $flags " in
        *" ISLANDSPEED_MAIN_TARGET_ROUTING "*) ;;
        *) echo "ERROR: routing flag missing in $target; replace project.yml" >&2; exit 1 ;;
    esac
    case " $flags " in
        *" ISLANDSPEED_APP "*)
            [[ "$target" == IslandSpeed ]] || { echo 'ERROR: app-only flag present in widget' >&2; exit 1; } ;;
        *)
            [[ "$target" != IslandSpeed ]] || { echo 'ERROR: app-only flag missing in IslandSpeed' >&2; exit 1; } ;;
    esac
    version=$(printf '%s\n' "$resolved" | awk '$1 == "MARKETING_VERSION" && $2 == "=" {print $3; exit}')
    build=$(printf '%s\n' "$resolved" | awk '$1 == "CURRENT_PROJECT_VERSION" && $2 == "=" {print $3; exit}')
    echo "$target version: $version ($build)"
    [[ "$version" == 1.2.1 && "$build" == 15 ]] || { echo 'ERROR: unexpected project version; replace project.yml' >&2; exit 1; }
done
xcodebuild -project IslandSpeed.xcodeproj -scheme IslandSpeed -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
app=build/Build/Products/Release-iphoneos/IslandSpeed.app
for bundle in "$app" "$app/PlugIns/IslandSpeedWidget.appex"; do
    echo "App Intents metadata: $bundle"
    find "$bundle/Metadata.appintents" -maxdepth 2 -type f -print 2>/dev/null || true
    if [[ ! -d "$bundle/Metadata.appintents" ]]; then
        echo "WARNING: no Metadata.appintents directory in $bundle; inspect Xcode extraction logs and signing tool." >&2
    fi
done
python3 scripts/package_ipa.py "$app" dist/IslandSpeed-unsigned.ipa
