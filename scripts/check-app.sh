#!/bin/bash
# Checks a built "ADO Pulse.app": its signature is valid and uses the hardened runtime, it's a menu-bar app
# with the expected identity and version, it still opens on macOS 15 (FoundationModels is linked weakly),
# its command-line mode runs, and it sorts the demo pull requests into the expected groups.
#   scripts/check-app.sh [--universal] [app]   (default: build/ADO Pulse.app, relative to the repository)
#   --universal   also requires code for both Apple silicon and Intel, as a release has.
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=false
if [[ "${1:-}" == "--universal" ]]; then
    UNIVERSAL=true
    shift
fi
APP="${1:-build/ADO Pulse.app}"
BIN="$APP/Contents/MacOS/ADOPulse"
PLIST="$APP/Contents/Info.plist"

fail() {
    echo "$APP: $1" >&2
    exit 1
}
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }

codesign --verify --deep --strict "$APP" || fail "has an invalid signature."
codesign -dv "$APP" 2>&1 | grep '^CodeDirectory.*flags=.*runtime' >/dev/null || fail "isn't signed with the hardened runtime."
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
if [[ "$REQUIREMENT" != *cdhash* && ( "$REQUIREMENT" != *'identifier "com.asaf.ADOPulse"'* || "$REQUIREMENT" != *certificate* ) ]]; then
    fail "has an unexpected designated requirement: $REQUIREMENT"
fi
[[ "$(plist CFBundleIdentifier)" == "com.asaf.ADOPulse" ]] || fail "has the wrong bundle identifier."
[[ "$(plist LSUIElement)" == true ]] || fail "isn't a menu-bar (LSUIElement) app."
[[ "$(plist CFBundleVersion)" == "$(plist CFBundleShortVersionString)" ]] ||
    fail "has a CFBundleVersion that isn't its version."
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] || fail "has no icon."

ARCHS="$(lipo -archs "$BIN")"
# Summaries need macOS 26's FoundationModels; linked weakly, the app still opens on macOS 15.
if otool -l "$BIN" | grep -B2 'FoundationModels.framework' | grep -q 'cmd LC_LOAD_DYLIB$'; then
    fail "links FoundationModels strongly, so it won't open before macOS 26."
fi
if $UNIVERSAL; then
    for arch in arm64 x86_64; do
        [[ " $ARCHS " == *" $arch "* ]] || fail "${BIN#"$APP/"} has no $arch code (only $ARCHS)."
    done
fi

"$BIN" --help >/dev/null || fail "doesn't run its command-line mode."
make -s demo-check PULSE="$BIN"
SIGNATURE="$([[ "$REQUIREMENT" == *cdhash* ]] && echo "ad hoc" || echo "certificate")"
echo "Checked $APP: valid signature ($SIGNATURE, hardened runtime), $ARCHS, and it runs on this Mac ($(uname -m))."
