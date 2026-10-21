#!/bin/bash
# Signs the app in a package that scripts/package.sh made, for a release: with the release certificate,
# which scripts/import-signing-certificate.sh put in a keychain. Then checks it against
# scripts/release-certificate.sha1, and zips it again, with the new SHA-256 in the .sha256 file and the
# release notes.
#   scripts/sign-package.sh [folder]   (default: build/release)
# Signs with ADO_PULSE_SIGNING_IDENTITY, found in ADO_PULSE_SIGNING_KEYCHAIN if that's set.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/release}"
ZIP="ADO-Pulse.zip"
IDENTITY="${ADO_PULSE_SIGNING_IDENTITY:?Set ADO_PULSE_SIGNING_IDENTITY, as scripts/import-signing-certificate.sh does.}"
KEYCHAIN_ARGS=()
if [[ -n "${ADO_PULSE_SIGNING_KEYCHAIN:-}" ]]; then
    KEYCHAIN_ARGS=(--keychain "$ADO_PULSE_SIGNING_KEYCHAIN")
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto -x -k "$OUT/$ZIP" "$WORK"
APP="$WORK/ADO Pulse.app"
# The same options as scripts/build-app.sh; the check below makes sure of the result.
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} "$APP"
./scripts/check-app.sh --universal --release "$APP"

OLD="$(cut -d ' ' -f 1 "$OUT/$ZIP.sha256")"
if [[ "$(grep -c "$OLD" "$OUT/notes.md")" != 1 ]]; then
    echo "$OUT/notes.md doesn't give the zip's SHA-256 exactly once." >&2
    exit 1
fi
rm "$OUT/$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"
(cd "$OUT" && shasum -a 256 "$ZIP" > "$ZIP.sha256")
NEW="$(cut -d ' ' -f 1 "$OUT/$ZIP.sha256")"
sed -i '' "s/$OLD/$NEW/" "$OUT/notes.md"
echo "Signed $OUT/$ZIP with \"$IDENTITY\" (SHA-256 $NEW)."
