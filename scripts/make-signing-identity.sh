#!/bin/bash
# Creates "ADO Pulse Signing", a self-signed code-signing certificate, in your login keychain. Builds
# are signed with it (scripts/build-app.sh), so the app's designated requirement names this certificate
# rather than the code's hashes, and macOS keeps ADO Pulse's Full Disk Access (for pull requests sent
# in chats) across rebuilds. Ad-hoc signed builds lose it every time. Run it once per Mac; running it
# again checks that the key works.
#   scripts/make-signing-identity.sh [--replace | --check] [keychain]
# No app may use the key without asking, and it can't be exported: macOS asks for your login password
# each time something signs with it, a build included. Choose Allow, never Always Allow, which would let
# anything running as you sign code as ADO Pulse, and so get the Full Disk Access you gave it.
# --replace deletes the certificate and its key first, such as one an earlier version of this script
# made, which let codesign use the key without asking. Then allow Full Disk Access for the next build.
# --check only says, without asking for anything, whether codesign may use the key without asking.
# ADO_PULSE_SIGNING_IDENTITY picks another name.
set -euo pipefail

REPLACE=false
CHECK=false
case "${1:-}" in
    --replace) REPLACE=true; shift ;;
    --check) CHECK=true; shift ;;
esac
NAME="${ADO_PULSE_SIGNING_IDENTITY:-ADO Pulse Signing}"
KEYCHAIN="${1:-$HOME/Library/Keychains/login.keychain-db}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Signs a throwaway copy of a tool, to check that the key works (macOS asks) and to show what macOS will
# match.
check_identity() {
    cp /usr/bin/true "$WORK/probe"
    echo "macOS asks whether codesign may use the key: enter your login password and choose Allow."
    if ! codesign --force --sign "$NAME" --keychain "$KEYCHAIN" --timestamp=none "$WORK/probe"; then
        echo "codesign couldn't use the \"$NAME\" key. Run this again, and when macOS asks whether codesign" >&2
        echo "may use it, enter your login password and choose Allow." >&2
        exit 1
    fi
    echo "Code signed with it is identified by: $(codesign -d -r- "$WORK/probe" 2>&1 | sed -n 's/^#* *designated => //p')"
    if trusts_codesign; then
        echo "That was Always Allow: codesign may now use the key without asking, so anything running as you" >&2
        echo "could sign code as ADO Pulse. Run this again with --replace, and choose Allow." >&2
        exit 1
    fi
}

# Whether codesign may use the key without asking: what Always Allow does. The key is found by its label,
# the SHA-1 of its public key, and only its own access list is read.
trusts_codesign() {
    local label
    label="$(security find-certificate -c "$NAME" -p "$KEYCHAIN" 2>/dev/null | /usr/bin/openssl x509 -pubkey -noout 2>/dev/null \
        | /usr/bin/openssl rsa -pubin -RSAPublicKey_out -outform DER 2>/dev/null | shasum -a 1 | cut -d ' ' -f 1 | tr 'a-f' 'A-F')"
    security dump-keychain -a "$KEYCHAIN" 2>/dev/null | awk -v label="0x$label" '
        /^keychain:/ { if (hit) print block; block = ""; hit = 0 }
        { block = block $0 "\n" }
        index($0, "0x00000006 <blob>=" label) { hit = 1 }
        END { if (hit) print block }' | grep -q ': /usr/bin/codesign '
}

# The SHA-1 of each certificate named exactly $NAME (security's -c matches part of a name).
certificates() {
    security find-certificate -a -c "$NAME" -Z "$KEYCHAIN" 2>/dev/null | awk -v name="$NAME" '
        /^SHA-1 hash:/ { hash = $3 }
        /"labl"<blob>=/ { label = $0; sub(/^[^=]*="/, "", label); sub(/"$/, "", label); if (label == name) print hash }'
}

if $CHECK; then
    if trusts_codesign; then
        echo "warning: codesign may use the \"$NAME\" key without asking (Always Allow), so anything running as you" >&2
        echo "         could sign code as ADO Pulse. Run scripts/make-signing-identity.sh --replace, and choose Allow." >&2
        exit 1
    fi
    exit 0
fi

if $REPLACE; then
    for hash in $(certificates); do
        security delete-identity -Z "$hash" "$KEYCHAIN" >/dev/null 2>&1 || security delete-certificate -Z "$hash" "$KEYCHAIN" >/dev/null
    done
    echo "Deleted any \"$NAME\" certificate and key from $KEYCHAIN."
fi

if security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$NAME\"" >/dev/null; then
    echo "\"$NAME\" is already in $KEYCHAIN."
    check_identity
    exit 0
fi
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "$KEYCHAIN has a \"$NAME\" certificate but not its private key. Delete the certificate" >&2
    echo "in Keychain Access, then run this again." >&2
    exit 1
fi

# A leaf certificate for code signing only, valid for 10 years, made with macOS's own LibreSSL: `security
# import` can't read the .p12 files that OpenSSL 3 writes by default. Nothing needs to trust it: macOS
# matches the certificate itself against the app's designated requirement.
cat > "$WORK/certificate.cnf" <<EOF
[ req ]
distinguished_name = subject
prompt = no
x509_extensions = codesigning
[ subject ]
CN = $NAME
[ codesigning ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes -config "$WORK/certificate.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/certificate.pem" 2>/dev/null
PASSWORD="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/certificate.pem" \
    -passout "pass:$PASSWORD" -out "$WORK/identity.p12"

# -T "": no app may use the private key without asking, not even codesign or security. -x: it can't be
# exported. It never leaves the keychain after this.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$PASSWORD" -x -T "" >/dev/null

echo "Created \"$NAME\" in $KEYCHAIN."
check_identity
echo "macOS asks like that each time a build is signed. Choose Allow, never Always Allow: that would let anything"
echo "running as you sign code as ADO Pulse, and get the Full Disk Access you gave it."
