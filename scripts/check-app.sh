#!/bin/bash
# Checks a built "ADO Pulse.app": its signature is valid, it's a menu-bar app with the expected identity
# and version, its command-line mode runs, and it sorts the demo pull requests into the expected groups.
#   scripts/check-app.sh [app]   (default: build/ADO Pulse.app, relative to the repository)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/ADO Pulse.app}"
BIN="$APP/Contents/MacOS/ADOPulse"
PLIST="$APP/Contents/Info.plist"

fail() {
    echo "$APP: $1" >&2
    exit 1
}
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }

codesign --verify --deep --strict "$APP" || fail "has an invalid signature."
[[ "$(plist CFBundleIdentifier)" == "com.asaf.ADOPulse" ]] || fail "has the wrong bundle identifier."
[[ "$(plist LSUIElement)" == true ]] || fail "isn't a menu-bar (LSUIElement) app."
[[ "$(plist CFBundleVersion)" == "$(plist CFBundleShortVersionString)" ]] ||
    fail "has a CFBundleVersion that isn't its version."
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] || fail "has no icon."

"$BIN" --help >/dev/null || fail "doesn't run its command-line mode."
make -s demo-check PULSE="$BIN"
echo "Checked $APP: valid signature, $(lipo -archs "$BIN"), and it runs on this Mac ($(uname -m))."
