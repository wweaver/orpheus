#!/usr/bin/env bash
# Build a Release configuration and install into ~/Applications so the app
# launches from Spotlight, Launchpad, or the Applications folder. Intended
# for personal use — the binary is ad-hoc signed, no notarization.
#
# Usage:
#   scripts/install.sh           # build, install, launch
#   scripts/install.sh --no-open # build and install without launching
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OPEN_APP=1
for arg in "$@"; do
    case "$arg" in
        --no-open) OPEN_APP=0 ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /set -euo/d'
            exit 0
            ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

DEST="$HOME/Applications/PianobarGUI.app"
DERIVED="$ROOT/build-release"
BUILT_APP="$DERIVED/Build/Products/Release/PianobarGUI.app"

echo "▶︎ Regenerating Xcode project"
xcodegen generate >/dev/null

echo "▶︎ Building PianobarGUI (Release)"
xcodebuild \
    -project PianobarGUI.xcodeproj \
    -scheme PianobarGUI \
    -destination 'platform=macOS' \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    build >/dev/null

[ -d "$BUILT_APP" ] || { echo "Built app not found at $BUILT_APP" >&2; exit 1; }

echo "▶︎ Stopping any running copy"
killall PianobarGUI 2>/dev/null || true
# Give the atexit hook a moment to kill the child pianobar before we nuke
# the bundle out from under it.
sleep 1
killall pianobar 2>/dev/null || true

echo "▶︎ Installing to $DEST"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -R "$BUILT_APP" "$DEST"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
          "$DEST/Contents/Info.plist" 2>/dev/null || echo "dev")
echo "✓ Installed PianobarGUI ($VERSION) at $DEST"

if [ "$OPEN_APP" -eq 1 ]; then
    echo "▶︎ Launching"
    open "$DEST"
fi
