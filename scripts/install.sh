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

DEST="$HOME/Applications/Orpheus.app"
DERIVED="$ROOT/build-release"
BUILT_APP="$DERIVED/Build/Products/Release/Orpheus.app"

# Remove a stale PianobarGUI.app from earlier installs.
rm -rf "$HOME/Applications/PianobarGUI.app"

echo "▶︎ Regenerating Xcode project"
xcodegen generate >/dev/null

# The project signs ad-hoc by default so a fresh clone builds anywhere. If the
# stable local identity exists, use it instead: ad-hoc signing gives the app a
# designated requirement of a bare code hash that changes every build, so macOS
# treats each reinstall as a different app and stops handing over the saved
# Pandora credentials. See scripts/make-signing-cert.sh.
#
# Note the guarded expansion at the xcodebuild call below: macOS still ships
# bash 3.2, where expanding an empty array under `set -u` is an error.
SIGN_ARGS=()
if security find-certificate -c "Orpheus Code Signing" >/dev/null 2>&1; then
  # CODE_SIGN_STYLE=Manual is required alongside the identity: a command-line
  # build-setting override applies to *every* target, including the SwiftPM
  # resource bundle, and that one defaults to automatic signing — which then
  # fails with "requires a development team".
  SIGN_ARGS=(
    CODE_SIGN_IDENTITY="Orpheus Code Signing"
    CODE_SIGN_STYLE=Manual
    DEVELOPMENT_TEAM=""
  )
else
  echo "⚠︎  No 'Orpheus Code Signing' certificate found; signing ad-hoc."
  echo "   You'll have to re-enter your Pandora password after each install."
  echo "   Run ./scripts/make-signing-cert.sh once to fix that."
fi

echo "▶︎ Building PianobarGUI (Release)"
xcodebuild \
    -project PianobarGUI.xcodeproj \
    -scheme PianobarGUI \
    -destination 'platform=macOS' \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
    build >/dev/null

[ -d "$BUILT_APP" ] || { echo "Built app not found at $BUILT_APP" >&2; exit 1; }

# The app group that lets the desktop widget read now-playing state can't be
# declared in the Xcode project — doing so makes manual signing demand a
# provisioning profile, and therefore a Developer Team. Inject it here instead,
# after the build, using the same identity. See scripts/sign-entitlements.sh.
echo "▶︎ Applying entitlements (app group for the widget)"
SIGN_IDENTITY="-"
if security find-certificate -c "Orpheus Code Signing" >/dev/null 2>&1; then
    SIGN_IDENTITY="Orpheus Code Signing"
fi
"$ROOT/scripts/sign-entitlements.sh" "$BUILT_APP" "$SIGN_IDENTITY"

echo "▶︎ Stopping any running copy"
killall Orpheus 2>/dev/null || true
killall PianobarGUI 2>/dev/null || true
# `killall` sends SIGTERM, which the app catches and uses to kill its pianobar
# child before re-raising. Give that a moment to land before we pull the bundle
# out from under it. The `killall pianobar` below is only a backstop for a
# pianobar orphaned by an older build (or a SIGKILL), which the app would
# otherwise not reap until its next launch.
sleep 1
killall pianobar 2>/dev/null || true
# The widget extension is a separate process owned by WidgetKit, and it keeps
# running — executing the *old* binary from memory — when the bundle is replaced
# underneath it. Without this, a reinstall silently has no effect on the widget
# until something else happens to restart it. WidgetKit relaunches it on demand.
killall OrpheusWidget 2>/dev/null || true

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
