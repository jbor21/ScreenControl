#!/bin/bash
# Builds a Release ScreenControl.app into ./build and optionally installs it to /Applications.
#
#   scripts/build-app.sh            # build only  -> build/Release/ScreenControl.app
#   scripts/build-app.sh --install  # build and copy to /Applications, then launch
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found. Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi

xcodebuild \
    -project ScreenControl.xcodeproj \
    -target ScreenControl \
    -configuration Release \
    SYMROOT="$PWD/build" \
    build

APP="build/Release/ScreenControl.app"
echo
echo "Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
    if pgrep -x ScreenControl >/dev/null 2>&1; then
        osascript -e 'tell application "ScreenControl" to quit' >/dev/null 2>&1 || true
        sleep 1
    fi
    rm -rf /Applications/ScreenControl.app
    cp -R "$APP" /Applications/ScreenControl.app
    echo "Installed to /Applications/ScreenControl.app"
    open /Applications/ScreenControl.app
fi
