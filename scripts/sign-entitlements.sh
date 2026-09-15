#!/usr/bin/env bash
# Re-sign a built Orpheus.app with the entitlements it actually needs.
#
# Why this isn't just CODE_SIGN_ENTITLEMENTS in project.yml: a target that
# declares sandbox entitlements sends Xcode's manual signing path looking for a
# provisioning profile, which means an Apple Developer Team — the exact thing
# this project avoids (see make-signing-cert.sh; a stable local identity is what
# keeps the saved Pandora password readable across reinstalls). codesign itself
# has no such objection, and the sandbox honours a temporary-exception
# entitlement no matter who signed it.
#
# Usage: scripts/sign-entitlements.sh <path/to/Orpheus.app> [identity]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?usage: sign-entitlements.sh <Orpheus.app> [identity]}"
IDENTITY="${2:--}"

APPEX="$APP/Contents/PlugIns/OrpheusWidget.appex"

# Inside out. Signing the outer bundle seals the contents, so the extension has
# to carry its final signature before the app is signed over the top of it.
if [ -d "$APPEX" ]; then
    codesign --force --options runtime --timestamp=none \
        --sign "$IDENTITY" \
        --entitlements "$ROOT/Widget/OrpheusWidget.entitlements" \
        "$APPEX"
else
    echo "⚠︎  No widget extension at $APPEX — signing app only." >&2
fi

# The app itself needs no entitlements — it isn't sandboxed. It still has to be
# re-signed, because signing the extension inside it invalidated the outer seal.
codesign --force --options runtime --timestamp=none \
    --sign "$IDENTITY" \
    "$APP"

codesign --verify --deep --strict "$APP"
