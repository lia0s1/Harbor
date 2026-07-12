#!/usr/bin/env bash
# Build, Developer-ID sign, notarize, staple, package, and optionally install
# a universal Harbor app from the source currently saved in this workspace.
# Existing outputs are not replaced until every release verification succeeds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TEAM_ID="${TEAM_ID:-XXXXXXXXXX}"
DEVELOPER_IDENTITY="${DEVELOPER_IDENTITY:-Developer ID Application: Harbor Developer (XXXXXXXXXX)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ZIP_OUTPUT="${ZIP_OUTPUT:-$ROOT/Harbor.zip}"
DMG_OUTPUT="${DMG_OUTPUT:-$ROOT/harbor installer.dmg}"
INSTALL_APP=false
INSTALL_PATH="/Applications/Harbor.app"
SOURCE_REVISION=""

usage() {
    cat <<'EOF'
Usage: NOTARY_PROFILE=<keychain-profile> scripts/release.sh [options]

Options:
  --notary-profile NAME  notarytool Keychain profile (or use NOTARY_PROFILE)
  --zip-output PATH      final notarized ZIP (default: ./Harbor.zip)
  --dmg-output PATH      final signed and notarized DMG (default: ./harbor installer.dmg)
  --output PATH          compatibility alias for --zip-output
  --install              install the verified app in /Applications/Harbor.app
  --install-path PATH    install at PATH (also enables --install)
  -h, --help             show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notary-profile)
            [[ $# -ge 2 ]] || { echo "--notary-profile requires a profile name" >&2; exit 2; }
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --zip-output|--output)
            [[ $# -ge 2 ]] || { echo "$1 requires a path" >&2; exit 2; }
            ZIP_OUTPUT="$2"
            shift 2
            ;;
        --dmg-output)
            [[ $# -ge 2 ]] || { echo "--dmg-output requires a path" >&2; exit 2; }
            DMG_OUTPUT="$2"
            shift 2
            ;;
        --install)
            INSTALL_APP=true
            shift
            ;;
        --install-path)
            [[ $# -ge 2 ]] || { echo "--install-path requires a path" >&2; exit 2; }
            INSTALL_PATH="$2"
            INSTALL_APP=true
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ "$ZIP_OUTPUT" != "$DMG_OUTPUT" ]] || {
    echo "ZIP and DMG outputs must use different paths." >&2
    exit 2
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "Release refused: the source must be in a Git worktree." >&2
    exit 1
}
SOURCE_REVISION="$(git rev-parse --verify HEAD 2>/dev/null)" || {
    echo "Release refused: create and review an initial Git commit before release." >&2
    exit 1
}
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || {
    echo "Release refused: commit, stash, or remove all source changes before release." >&2
    exit 1
}
[[ -n "$NOTARY_PROFILE" ]] || {
    echo "NOTARY_PROFILE is required. Store credentials with 'xcrun notarytool store-credentials' first." >&2
    exit 2
}

for tool in xcodegen xcodebuild codesign ditto hdiutil lipo shasum swift xcrun SetFile GetFileInfo; do
    command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 1; }
done

mkdir -p "$ROOT/.build"
STAGING="$(mktemp -d "$ROOT/.build/harbor-release.XXXXXX")"
PUBLISH_ZIP_TEMP=""
PUBLISH_DMG_TEMP=""
DMG_MOUNT=""
cleanup() {
    if [[ -n "$DMG_MOUNT" ]]; then
        hdiutil detach "$DMG_MOUNT" >/dev/null 2>&1 || true
    fi
    [[ -z "$PUBLISH_ZIP_TEMP" || ! -e "$PUBLISH_ZIP_TEMP" ]] || /bin/rm -f "$PUBLISH_ZIP_TEMP"
    [[ -z "$PUBLISH_DMG_TEMP" || ! -e "$PUBLISH_DMG_TEMP" ]] || /bin/rm -f "$PUBLISH_DMG_TEMP"
    /bin/rm -rf "$STAGING"
}
trap cleanup EXIT

ARCHIVE="$STAGING/Harbor.xcarchive"
APP="$STAGING/Harbor.app"
SUBMISSION_ZIP="$STAGING/Harbor-submit.zip"
FINAL_ZIP="$STAGING/Harbor.zip"
FINAL_DMG="$STAGING/Harbor.dmg"
FINAL_DMG_RW="$STAGING/Harbor.rw.dmg"
DMG_ROOT="$STAGING/dmg-root"
APP_ICON="$APP/Contents/Resources/AppIcon.icns"

notarize_and_require_accepted() {
    local artifact="$1"
    local result_json="$2"
    local label="$3"
    local status
    local submission_id

    xcrun notarytool submit "$artifact" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --output-format json >"$result_json"
    status="$(/usr/bin/plutil -extract status raw -o - "$result_json")"
    submission_id="$(/usr/bin/plutil -extract id raw -o - "$result_json")"
    if [[ "$status" != "Accepted" ]]; then
        echo "$label notarization failed with status: $status" >&2
        xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" || true
        exit 1
    fi
    echo "$label notarization accepted: $submission_id"
}

verify_app() {
    local app_path="$1"
    codesign --verify --deep --strict --verbose=2 "$app_path"
    xcrun stapler validate "$app_path"
    spctl --assess --type execute --verbose=4 "$app_path"
}

set_dmg_finder_icon() {
    local dmg_path="$1"
    local icon_path="$2"

    TARGET_PATH="$dmg_path" ICON_PATH="$icon_path" swift -e '
import AppKit
import Foundation

let environment = ProcessInfo.processInfo.environment
guard let targetPath = environment["TARGET_PATH"],
      let iconPath = environment["ICON_PATH"],
      let icon = NSImage(contentsOfFile: iconPath) else {
    fatalError("Unable to load the DMG Finder icon.")
}
guard NSWorkspace.shared.setIcon(icon, forFile: targetPath, options: []) else {
    fatalError("Unable to set the DMG Finder icon.")
}
'
    [[ "$(GetFileInfo -aC "$dmg_path")" == "1" ]] || {
        echo "Release refused: DMG Finder icon was not applied." >&2
        return 1
    }
}

publish_outputs() {
    local backup_dir=""
    local zip_previous=false
    local dmg_previous=false

    mkdir -p "$(dirname "$ZIP_OUTPUT")" "$(dirname "$DMG_OUTPUT")"
    PUBLISH_ZIP_TEMP="$(mktemp "$(dirname "$ZIP_OUTPUT")/.Harbor.zip.new.XXXXXX")"
    PUBLISH_DMG_TEMP="$(mktemp "$(dirname "$DMG_OUTPUT")/.Harbor.dmg.new.XXXXXX")"
    /bin/cp -p "$FINAL_ZIP" "$PUBLISH_ZIP_TEMP"
    /bin/cp -p "$FINAL_DMG" "$PUBLISH_DMG_TEMP"

    if [[ -e "$ZIP_OUTPUT" || -e "$DMG_OUTPUT" ]]; then
        backup_dir="/private/tmp/Harbor-release-previous-$(date +%Y%m%d-%H%M%S)-$$"
        mkdir -p "$backup_dir"
    fi
    if [[ -e "$ZIP_OUTPUT" ]]; then
        mv "$ZIP_OUTPUT" "$backup_dir/Harbor.previous.zip"
        zip_previous=true
    fi
    if [[ -e "$DMG_OUTPUT" ]]; then
        mv "$DMG_OUTPUT" "$backup_dir/Harbor.previous.dmg"
        dmg_previous=true
    fi

    if ! mv "$PUBLISH_ZIP_TEMP" "$ZIP_OUTPUT"; then
        [[ "$zip_previous" == false ]] || mv "$backup_dir/Harbor.previous.zip" "$ZIP_OUTPUT"
        [[ "$dmg_previous" == false ]] || mv "$backup_dir/Harbor.previous.dmg" "$DMG_OUTPUT"
        return 1
    fi
    PUBLISH_ZIP_TEMP=""
    if ! mv "$PUBLISH_DMG_TEMP" "$DMG_OUTPUT"; then
        mv "$ZIP_OUTPUT" "$STAGING/Harbor.failed-publish.zip"
        [[ "$zip_previous" == false ]] || mv "$backup_dir/Harbor.previous.zip" "$ZIP_OUTPUT"
        [[ "$dmg_previous" == false ]] || mv "$backup_dir/Harbor.previous.dmg" "$DMG_OUTPUT"
        return 1
    fi
    PUBLISH_DMG_TEMP=""

    [[ -z "$backup_dir" ]] || echo "Previous release backup: $backup_dir"
}

install_verified_app() {
    local backup_path=""
    local failed_path="$STAGING/Harbor.failed-install.app"

    mkdir -p "$(dirname "$INSTALL_PATH")"
    if [[ -e "$INSTALL_PATH" ]]; then
        backup_path="/private/tmp/Harbor.app.preinstall-$(date +%Y%m%d-%H%M%S)-$$"
        mv "$INSTALL_PATH" "$backup_path"
    fi

    if ! ditto "$APP" "$INSTALL_PATH" || ! verify_app "$INSTALL_PATH"; then
        [[ ! -e "$INSTALL_PATH" ]] || mv "$INSTALL_PATH" "$failed_path"
        [[ -z "$backup_path" ]] || mv "$backup_path" "$INSTALL_PATH"
        echo "Installation failed; the previous app was restored." >&2
        return 1
    fi

    echo "Installed verified app: $INSTALL_PATH"
    [[ -z "$backup_path" ]] || echo "Previous app backup: $backup_path"
}

echo "Generating project from reviewed source revision: $SOURCE_REVISION"
xcodegen generate
xcodebuild \
    -quiet \
    -project Harbor.xcodeproj \
    -scheme Harbor \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination 'generic/platform=macOS' \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$DEVELOPER_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    archive

SOURCE_APP="$ARCHIVE/Products/Applications/Harbor.app"
[[ -d "$SOURCE_APP" ]] || { echo "Archived app not found: $SOURCE_APP" >&2; exit 1; }
ditto "$SOURCE_APP" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
SIGN_INFO="$(codesign -d --verbose=4 "$APP" 2>&1)"
[[ "$SIGN_INFO" == *"TeamIdentifier=$TEAM_ID"* ]] || {
    echo "Release refused: unexpected signing team." >&2
    exit 1
}
[[ "$SIGN_INFO" == *"runtime"* ]] || {
    echo "Release refused: hardened runtime flag is missing." >&2
    exit 1
}
APP_ARCHS="$(lipo -archs "$APP/Contents/MacOS/Harbor")"
[[ "$APP_ARCHS" == *"arm64"* && "$APP_ARCHS" == *"x86_64"* ]] || {
    echo "Release refused: Harbor is not a universal arm64/x86_64 binary ($APP_ARCHS)." >&2
    exit 1
}

ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMISSION_ZIP"
notarize_and_require_accepted "$SUBMISSION_ZIP" "$STAGING/app-notary.json" "Harbor.app"
xcrun stapler staple "$APP"
verify_app "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$FINAL_ZIP"

mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/Harbor.app"
ln -s /Applications "$DMG_ROOT/Applications"
[[ -f "$APP_ICON" ]] || { echo "Release refused: AppIcon.icns is missing." >&2; exit 1; }
cp "$APP_ICON" "$DMG_ROOT/.VolumeIcon.icns"
SetFile -a V "$DMG_ROOT/.VolumeIcon.icns"
hdiutil create \
    -volname Harbor \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDRW \
    "$FINAL_DMG_RW"
DMG_MOUNT="$STAGING/dmg-mount"
mkdir "$DMG_MOUNT"
hdiutil attach -nobrowse -mountpoint "$DMG_MOUNT" "$FINAL_DMG_RW"
SetFile -a C "$DMG_MOUNT"
hdiutil detach "$DMG_MOUNT"
DMG_MOUNT=""
hdiutil convert "$FINAL_DMG_RW" -format UDZO -o "${FINAL_DMG%.dmg}"
codesign --force --timestamp --sign "$DEVELOPER_IDENTITY" "$FINAL_DMG"
codesign --verify --strict --verbose=2 "$FINAL_DMG"
notarize_and_require_accepted "$FINAL_DMG" "$STAGING/dmg-notary.json" "Harbor.dmg"
xcrun stapler staple "$FINAL_DMG"
xcrun stapler validate "$FINAL_DMG"
hdiutil verify "$FINAL_DMG"
codesign --verify --strict --verbose=2 "$FINAL_DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$FINAL_DMG"
set_dmg_finder_icon "$FINAL_DMG" "$APP_ICON"
codesign --verify --strict --verbose=2 "$FINAL_DMG"
xcrun stapler validate "$FINAL_DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$FINAL_DMG"

publish_outputs
[[ "$(GetFileInfo -aC "$DMG_OUTPUT")" == "1" ]] || {
    echo "Release refused: published DMG Finder icon is missing." >&2
    exit 1
}
[[ "$INSTALL_APP" == false ]] || install_verified_app

shasum -a 256 "$ZIP_OUTPUT" "$DMG_OUTPUT"
echo "Released source revision: $SOURCE_REVISION"
echo "Verified release ZIP: $ZIP_OUTPUT"
echo "Verified release DMG: $DMG_OUTPUT"
