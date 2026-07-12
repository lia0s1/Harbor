#!/bin/bash
# Regenerates the Xcode project and builds Harbor.
#
# Defaults to RELEASE: SwiftUI + SwiftTerm are dramatically smoother optimized,
# and Release is what the user actually runs. Pass `debug` to build Debug.
#
# Usage:
#   ./build.sh              # build Release, prints the .app path
#   ./build.sh open         # build Release, then launch the app
#   ./build.sh debug        # build Debug, prints the .app path
#   ./build.sh debug open   # build Debug, then launch the app
set -euo pipefail
cd "$(dirname "$0")"

# Asset catalogs / SwiftUI need the full Xcode toolchain, not CommandLineTools.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

CONFIG="Release"
DO_OPEN="no"
for arg in "$@"; do
    case "$arg" in
        debug|Debug) CONFIG="Debug" ;;
        release|Release) CONFIG="Release" ;;
        open) DO_OPEN="yes" ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

command -v xcodegen >/dev/null || {
    echo "xcodegen not found — install it with: brew install xcodegen" >&2
    exit 1
}

xcodegen generate

xcodebuild \
    -project Harbor.xcodeproj \
    -scheme Harbor \
    -configuration "$CONFIG" \
    -derivedDataPath .build/DerivedData \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    build

APP_PATH="$PWD/.build/DerivedData/Build/Products/$CONFIG/Harbor.app"
echo
echo "Built ($CONFIG): $APP_PATH"

if [[ "$DO_OPEN" == "yes" ]]; then
    open "$APP_PATH"
fi
