#!/bin/bash
# Builds a Release ScreenControl.app and either leaves it in ./build or installs it to /Applications.
#
#   scripts/build-app.sh            # build only  -> build/ScreenControl.app
#   scripts/build-app.sh --install  # build, install to /Applications, launch
#
# The build itself happens in a temporary folder outside the repo so Spotlight and Launchpad only
# ever see one copy of the app.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found. Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi

WORK="$(mktemp -d /tmp/ScreenControl-build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
BUILT="$WORK/Release/ScreenControl.app"

# Build unsigned, then sign here. Finder likes to attach extended attributes (resource forks,
# Finder info, quarantine flags) to files in folders such as ~/Desktop, and codesign refuses to
# sign a bundle that contains them ("resource fork, Finder information, or similar detritus not
# allowed"). Stripping them before signing sidesteps that.
xcodebuild \
    -project ScreenControl.xcodeproj \
    -target ScreenControl \
    -configuration Release \
    -quiet \
    SYMROOT="$WORK" \
    CODE_SIGNING_ALLOWED=NO \
    build

xattr -cr "$BUILT"
codesign --force --sign - --options runtime --timestamp=none "$BUILT"

if [[ "${1:-}" == "--install" ]]; then
    if pgrep -x ScreenControl >/dev/null 2>&1; then
        osascript -e 'tell application "ScreenControl" to quit' >/dev/null 2>&1 || true
        sleep 1
    fi
    rm -rf /Applications/ScreenControl.app
    cp -R "$BUILT" /Applications/ScreenControl.app
    # Stale copies from earlier builds show up as duplicates in Spotlight; clear them out.
    rm -rf build
    echo "Installed to /Applications/ScreenControl.app"
    open /Applications/ScreenControl.app
else
    rm -rf build
    mkdir -p build
    cp -R "$BUILT" build/ScreenControl.app
    echo "Built: build/ScreenControl.app"
fi
