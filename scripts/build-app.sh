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

APP="build/Release/ScreenControl.app"

# Build unsigned, then sign here. Finder likes to attach extended attributes (resource forks,
# Finder info, quarantine flags) to files in folders such as ~/Desktop, and codesign refuses to
# sign a bundle that contains them ("resource fork, Finder information, or similar detritus not
# allowed"). Stripping them before signing sidesteps that.
xcodebuild \
    -project ScreenControl.xcodeproj \
    -target ScreenControl \
    -configuration Release \
    -quiet \
    SYMROOT="$PWD/build" \
    CODE_SIGNING_ALLOWED=NO \
    build

xattr -cr "$APP"
codesign --force --sign - --options runtime --timestamp=none "$APP"

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
