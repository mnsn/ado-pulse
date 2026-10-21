#!/bin/bash
# Creates "ADO Pulse Signing", a self-signed code-signing certificate, in your login keychain. Builds
# are signed with it (scripts/build-app.sh), so the app's designated requirement names this certificate
# rather than the code's hashes, and macOS keeps ADO Pulse's Full Disk Access (for pull requests sent
# in chats) across rebuilds. Ad-hoc signed builds lose it every time. Run it once per Mac; running it
# again checks that codesign may use the key.
#   scripts/make-signing-identity.sh [keychain]
# ADO_PULSE_SIGNING_IDENTITY picks another name. With ADO_PULSE_KEYCHAIN_PASSWORD set and a dedicated
# keychain (for CI), codesign never asks to use the key; otherwise macOS asks once, the first time.
set -euo pipefail

NAME="${ADO_PULSE_SIGNING_IDENTITY:-ADO Pulse Signing}"
KEYCHAIN="${1:-$HOME/Library/Keychains/login.keychain-db}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Signs a throwaway copy of a tool, to check that codesign may use the key (macOS asks the first time)
# and to show what macOS will match.
check_identity() {
    cp /usr/bin/true "$WORK/probe"
    if ! codesign --force --sign "$NAME" --keychain "$KEYCHAIN" --timestamp=none "$WORK/probe"; then
        echo "codesign can't use the \"$NAME\" key yet. Run this again, and when macOS asks whether" >&2
        echo "codesign may use it, enter your login password and choose Always Allow." >&2
        exit 1
    fi
    echo "Code signed with it is identified by: $(codesign -d -r- "$WORK/probe" 2>&1 | sed -n 's/^#* *designated => //p')"
}

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

# -T lets codesign use the private key. The key never leaves the keychain after this.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
if [[ -n "${ADO_PULSE_KEYCHAIN_PASSWORD:-}" ]]; then
    # Lets Apple's tools use every signing key in the keychain without asking, so only for a keychain
    # that holds nothing else (CI), never the login keychain.
    if [[ "$KEYCHAIN" == *"/login.keychain"* ]]; then
        echo "ADO_PULSE_KEYCHAIN_PASSWORD is only for a dedicated keychain, not the login keychain." >&2
        exit 1
    fi
    security set-key-partition-list -S apple-tool:,apple: -s -k "$ADO_PULSE_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
fi

echo "Created \"$NAME\" in $KEYCHAIN."
check_identity
echo "If macOS asked whether codesign may use the key, choosing Always Allow keeps it from asking again."
