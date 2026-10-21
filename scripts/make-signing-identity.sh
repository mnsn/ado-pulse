#!/bin/bash
# Creates "ADO Pulse Signing", a self-signed code-signing certificate, in your login keychain. Builds
# are signed with it (scripts/build-app.sh), so the app's designated requirement names this certificate
# rather than the code's hashes, and macOS keeps ADO Pulse's Full Disk Access (for pull requests sent
# in chats) across rebuilds. Ad-hoc signed builds lose it every time. Run it once per Mac; running it
# again checks that the key works.
#   scripts/make-signing-identity.sh [--replace | --delete | --check] [keychain]
# No app may use the key without asking, not even codesign or security, and it can't be exported
# (scripts/signing-key.swift): macOS asks for your login password each time something signs with it, a
# build included. Choose Allow, never Always Allow, which would let anything running as you sign code as
# ADO Pulse, and so get the Full Disk Access you gave it. Builds won't sign with a key like that.
# --replace deletes the certificate and its key first, and makes new ones. Then allow Full Disk Access
# for the next build.
# --delete only deletes them: builds are then signed ad hoc again.
# --check only says, without asking for anything, whether the key is still safe: it fails with status 3
# if some app may use it without asking, or it can be exported. Without a keychain, it checks every one
# that codesign would look in.
# ADO_PULSE_SIGNING_IDENTITY picks another name.
set -euo pipefail

REPLACE=false
DELETE=false
CHECK=false
case "${1:-}" in
    --replace) REPLACE=true; shift ;;
    --delete) DELETE=true; shift ;;
    --check) CHECK=true; shift ;;
esac
NAME="${ADO_PULSE_SIGNING_IDENTITY:-ADO Pulse Signing}"
KEYCHAIN_ARGUMENT="${1:-}"
KEYCHAIN="${KEYCHAIN_ARGUMENT:-$HOME/Library/Keychains/login.keychain-db}"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
# macOS's own LibreSSL: `security import` can't read the .p12 files that OpenSSL 3 writes by default.
OPENSSL=/usr/bin/openssl

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

signing_key() { swift -suppress-warnings "$SCRIPTS/signing-key.swift" "$@"; }

# Whether the key is still safe: no app may use it without asking, and it can't be exported. Only its
# attributes and access list are read, so macOS doesn't ask anything.
key_is_safe() {
    local status=0
    signing_key check "$NAME" ${KEYCHAIN_ARGUMENT:+"$KEYCHAIN_ARGUMENT"} || status=$?
    if [[ $status -eq 3 ]]; then
        echo "So anything running as you could sign code as ADO Pulse with it, and get the Full Disk Access you" >&2
        echo "gave ADO Pulse. Replace it, and when macOS asks, choose Allow, never Always Allow:" >&2
        echo "  scripts/make-signing-identity.sh --replace" >&2
    fi
    return $status
}

# Signs a throwaway copy of a tool, to check that the key works (macOS asks) and to show what macOS will
# match. Then checks that the answer wasn't Always Allow.
check_identity() {
    cp /usr/bin/true "$WORK/probe"
    echo "macOS asks whether codesign may use the key: enter your login password and choose Allow."
    if ! codesign --force --sign "$NAME" --keychain "$KEYCHAIN" --timestamp=none "$WORK/probe"; then
        echo "codesign couldn't use the \"$NAME\" key. Run this again, and when macOS asks whether codesign" >&2
        echo "may use it, enter your login password and choose Allow." >&2
        exit 1
    fi
    echo "Code signed with it is identified by: $(codesign -d -r- "$WORK/probe" 2>&1 | sed -n 's/^#* *designated => //p')"
    key_is_safe || exit 1
}

# The SHA-1 of each certificate named exactly $NAME (security's -c matches part of a name).
certificates() {
    security find-certificate -a -c "$NAME" -Z "$KEYCHAIN" 2>/dev/null | awk -v name="$NAME" '
        /^SHA-1 hash:/ { hash = $3 }
        /"labl"<blob>=/ { label = $0; sub(/^[^=]*="/, "", label); sub(/"$/, "", label); if (label == name) print hash }'
}

# Deletes each certificate named exactly $NAME, with its key.
delete_certificates() {
    for hash in $(certificates); do
        security delete-identity -Z "$hash" "$KEYCHAIN" >/dev/null 2>&1 || security delete-certificate -Z "$hash" "$KEYCHAIN" >/dev/null
    done
}

if $CHECK; then
    STATUS=0
    key_is_safe || STATUS=$?
    exit $STATUS
fi

if $REPLACE || $DELETE; then
    delete_certificates
    echo "Deleted any \"$NAME\" certificate and key from $KEYCHAIN."
    if $DELETE; then
        echo "Builds are signed ad hoc now: allow Full Disk Access again after each one."
        exit 0
    fi
fi

if security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$NAME\"" >/dev/null; then
    echo "\"$NAME\" is already in $KEYCHAIN."
    key_is_safe || exit 1
    check_identity
    exit 0
fi
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "$KEYCHAIN has a \"$NAME\" certificate but not its private key. Delete the certificate" >&2
    echo "in Keychain Access, then run this again." >&2
    exit 1
fi

# A leaf certificate for code signing only, valid for 10 years. Nothing needs to trust it: macOS matches
# the certificate itself against the app's designated requirement. The key stays in variables, and
# reaches openssl and the keychain through pipes, never a file.
CONFIG="[ req ]
distinguished_name = subject
prompt = no
x509_extensions = codesigning
[ subject ]
CN = $NAME
[ codesigning ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash"
KEY="$("$OPENSSL" genrsa 3072 2>/dev/null)"
CERTIFICATE="$("$OPENSSL" req -x509 -new -sha256 -days 3650 -config <(printf '%s\n' "$CONFIG") -key <(printf '%s\n' "$KEY"))"
P12_PASSWORD="$("$OPENSSL" rand -hex 16)"
P12="$("$OPENSSL" pkcs12 -export -name "$NAME" -inkey <(printf '%s\n' "$KEY") -in <(printf '%s\n' "$CERTIFICATE") \
    -passout "file:"<(printf '%s\n' "$P12_PASSWORD") | base64)"
KEY=""

# It never leaves the keychain after this. If macOS imported it otherwise than asked, it's deleted.
if ! printf '%s\n%s\n' "$P12_PASSWORD" "$P12" | signing_key import "$KEYCHAIN" "$NAME"; then
    delete_certificates
    echo "Couldn't create \"$NAME\" in $KEYCHAIN." >&2
    exit 1
fi
P12=""
echo "Created \"$NAME\" in $KEYCHAIN."
check_identity
echo "macOS asks like that each time a build is signed. Choose Allow, never Always Allow: that would let anything"
echo "running as you sign code as ADO Pulse, and get the Full Disk Access you gave it."
