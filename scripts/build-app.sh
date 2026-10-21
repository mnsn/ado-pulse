#!/bin/bash
# Builds "ADO Pulse.app" into ./build, for this Mac's architecture, signed with the certificate that
# scripts/make-signing-identity.sh creates, or ad hoc when there isn't one (as on CI).
#   --universal   builds for both Apple silicon and Intel instead.
#   --install     also copies it to ~/Applications and (re)launches it.
#   --ad-hoc      signs it ad hoc even when the certificate exists.
# ADO_PULSE_SIGNING_IDENTITY names another certificate; ADO_PULSE_SIGNING_KEYCHAIN is a keychain to find
# it in, instead of the search list.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="ADO Pulse"
EXECUTABLE="ADOPulse"
APP="build/$APP_NAME.app"
IDENTITY="${ADO_PULSE_SIGNING_IDENTITY:-ADO Pulse Signing}"
KEYCHAIN="${ADO_PULSE_SIGNING_KEYCHAIN:-}"

UNIVERSAL=false
INSTALL=false
AD_HOC=false
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=true ;;
        --install) INSTALL=true ;;
        --ad-hoc) AD_HOC=true ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done
if ! $AD_HOC && ! security find-certificate -c "$IDENTITY" ${KEYCHAIN:+"$KEYCHAIN"} >/dev/null 2>&1; then
    AD_HOC=true
    echo "note: there's no \"$IDENTITY\" certificate, so the app is signed ad hoc, and Full Disk Access" >&2
    echo "      (for pull requests sent in chats) won't survive the next build. 'make signing-identity' fixes that." >&2
fi

BUILD_FLAGS=(-c release)
if $UNIVERSAL; then
    BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_FLAGS[@]}" --product "$EXECUTABLE"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist >/dev/null 2>&1; then
    echo "Resources/Info.plist sets CFBundleVersion. Remove it: the build sets it to CFBundleShortVersionString." >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# The hardened runtime costs nothing here: the app links only system frameworks. No timestamp, so
# signing makes no network request. A certificate keeps the designated requirement, and so Full Disk
# Access, the same from one build to the next; an ad-hoc signature changes with every build.
if $AD_HOC; then
    codesign --force --options runtime --sign - "$APP"
else
    KEYCHAIN_ARGS=()
    if [[ -n "$KEYCHAIN" ]]; then
        KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")
    fi
    if ! codesign --force --options runtime --timestamp=none --sign "$IDENTITY" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} "$APP"; then
        echo "error: codesign couldn't use the \"$IDENTITY\" key. When macOS asks whether it may, enter your login" >&2
        echo "       password and choose Allow (never Always Allow), or build with --ad-hoc." >&2
        exit 1
    fi
fi
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
echo "Built $APP (version $VERSION, $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"))"
echo "Designated requirement: $REQUIREMENT"

if $INSTALL; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"

    # Quit a running copy so the new build takes over.
    pids="$(pgrep -f "/$APP_NAME.app/Contents/MacOS/$EXECUTABLE" || true)"
    if [[ -n "$pids" ]]; then
        kill $pids 2>/dev/null || true
        for _ in {1..50}; do
            pgrep -f "/$APP_NAME.app/Contents/MacOS/$EXECUTABLE" >/dev/null || break
            sleep 0.1
        done
    fi

    rm -rf "$DEST/$APP_NAME.app"
    cp -R "$APP" "$DEST/"
    open "$DEST/$APP_NAME.app"
    echo "Installed and launched $DEST/$APP_NAME.app"
fi
