#!/bin/bash
# Checks, in throwaway keychains, what keeps the keys that ADO Pulse is signed with safe
# (scripts/signing-key.swift): a key it imports trusts no app, or only the one it's told to, and can't be
# exported, not even by that app; and its check catches a key that some app may use without asking, or
# that can be exported. Then runs scripts/make-signing-identity.sh. Nothing here makes macOS ask anything.
#   scripts/test-signing-key.sh   (make signing-key-check)
set -euo pipefail
cd "$(dirname "$0")/.."

OPENSSL=/usr/bin/openssl
WORK="$(mktemp -d)"
KEYCHAINS=()
cleanup() {
    for keychain in ${KEYCHAINS[@]+"${KEYCHAINS[@]}"}; do security delete-keychain "$keychain" 2>/dev/null || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT
KEYCHAIN_PASSWORD="$("$OPENSSL" rand -hex 16)"
P12_PASSWORD="$("$OPENSSL" rand -hex 16)"
FAILURES=0

new_keychain() {
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$1"
    KEYCHAINS+=("$1")
    security set-keychain-settings "$1"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$1"
}

# A PKCS #12, in base64, with a self-signed code-signing certificate named $1 and its key.
make_identity() {
    local key config
    key="$("$OPENSSL" genrsa 2048 2>/dev/null)"
    config="$(printf '[ req ]\ndistinguished_name = subject\nprompt = no\nx509_extensions = codesigning\n[ subject ]\nCN = %s\n[ codesigning ]\nbasicConstraints = critical, CA:false\nkeyUsage = critical, digitalSignature\nextendedKeyUsage = critical, codeSigning\n' "$1")"
    "$OPENSSL" pkcs12 -export -name "$1" -inkey <(printf '%s\n' "$key") \
        -in <("$OPENSSL" req -x509 -new -sha256 -days 30 -config <(printf '%s\n' "$config") -key <(printf '%s\n' "$key")) \
        -passout "file:"<(printf '%s\n' "$P12_PASSWORD") | base64
}

helper_import() { # name, keychain, [--trust app]
    { printf '%s\n' "$P12_PASSWORD"; make_identity "$1"; } | "$WORK/signing-key" import "$2" "$1" "${@:3}"
}

security_import() { # name, keychain, options...
    make_identity "$1" | base64 --decode -o "$WORK/identity.p12"
    security import "$WORK/identity.p12" -k "$2" -f pkcs12 -P "$P12_PASSWORD" "${@:3}" >/dev/null
    rm -f "$WORK/identity.p12"
}

# expect description status [--says text] command...: status is a number or "failure".
expect() {
    local description="$1" expected="$2" says="" status=0
    shift 2
    if [[ "$1" == "--says" ]]; then
        says="$2"
        shift 2
    fi
    "$@" >"$WORK/output" 2>&1 || status=$?
    if { [[ "$expected" == "failure" && $status -ne 0 ]] || [[ "$status" == "$expected" ]]; } &&
        { [[ -z "$says" ]] || grep -qF -- "$says" "$WORK/output"; }; then
        echo "ok: $description"
    else
        echo "FAILED: $description (status $status, expected $expected${says:+, saying \"$says\"}):" >&2
        sed 's/^/    /' "$WORK/output" >&2
        FAILURES=$((FAILURES + 1))
    fi
}

# The extractable attribute of the only private key in a keychain.
extractable() {
    security dump-keychain -a "$1" | awk '
        /^class: 0x00000010/ { key = 1 }
        key && /^ +0x00000010 <uint32>=/ { print substr($0, index($0, "=") + 1); exit }' | tr -d ' '
}

swiftc -suppress-warnings -O -o "$WORK/signing-key" scripts/signing-key.swift

KEYCHAIN="$WORK/keys.keychain-db"
new_keychain "$KEYCHAIN"
expect "imports a key that no app may use without asking, and that can't be exported" 0 \
    helper_import "Test Safe" "$KEYCHAIN"
expect "macOS agrees that it can't be exported" 0 test "$(extractable "$KEYCHAIN")" = "0x00000000"
expect "its check passes" 0 "$WORK/signing-key" check "Test Safe" "$KEYCHAIN"

TRUSTING="$WORK/trusting.keychain-db"
new_keychain "$TRUSTING"
expect "imports a key that only the app it trusts may use" 0 \
    helper_import "Test Trusting" "$TRUSTING" --trust /usr/bin/security
expect "even that app can't export it" failure \
    security export -k "$TRUSTING" -t privKeys -f pkcs12 -P "$P12_PASSWORD" -o "$WORK/exported.p12"
expect "the check names the app" 3 --says "without asking: /usr/bin/security" \
    "$WORK/signing-key" check "Test Trusting" "$TRUSTING"
EXPORTABLE="$WORK/exportable.keychain-db"
new_keychain "$EXPORTABLE"
security_import "Test Exportable" "$EXPORTABLE" -T /usr/bin/security
expect "while a key that can be exported is, by the app it trusts" 0 \
    security export -k "$EXPORTABLE" -t privKeys -f pkcs12 -P "$P12_PASSWORD" -o "$WORK/exported.p12"
rm -f "$WORK/exported.p12"

security_import "Test T Empty" "$KEYCHAIN" -x -T ""
expect "catches a key that can be exported (security import -x has no effect on a PKCS #12)" 3 --says "can be exported" \
    "$WORK/signing-key" check "Test T Empty" "$KEYCHAIN"
security_import "Test Codesign" "$KEYCHAIN" -x -T /usr/bin/codesign
expect "catches a key that codesign may use without asking (Always Allow)" 3 --says "without asking: /usr/bin/codesign" \
    "$WORK/signing-key" check "Test Codesign" "$KEYCHAIN"
security_import "Test Plain" "$KEYCHAIN" -x
expect "catches a key that security may use without asking (security import without -T)" 3 \
    --says "without asking: /usr/bin/security" "$WORK/signing-key" check "Test Plain" "$KEYCHAIN"
security_import "Test Any" "$KEYCHAIN" -A
expect "catches a key that any app may use" 3 --says "without asking: any app" \
    "$WORK/signing-key" check "Test Any" "$KEYCHAIN"
expect "fails for a certificate that isn't there" 1 "$WORK/signing-key" check "Test Missing" "$KEYCHAIN"
expect "checks only the certificate it names" 0 "$WORK/signing-key" check "Test Safe" "$KEYCHAIN"

# scripts/make-signing-identity.sh, with a stand-in for codesign, which would ask to use the key.
mkdir "$WORK/bin"
printf '#!/bin/sh\n[ "$1" = -d ] && echo "designated => certificate leaf = H\\"0\\"" >&2\nexit 0\n' > "$WORK/bin/codesign"
chmod +x "$WORK/bin/codesign"
IDENTITIES="$WORK/identities.keychain-db"
new_keychain "$IDENTITIES"
make_signing_identity() { ADO_PULSE_SIGNING_IDENTITY="Test Identity" PATH="$WORK/bin:$PATH" ./scripts/make-signing-identity.sh "$@"; }
expect "make-signing-identity.sh creates a certificate" 0 --says "Created \"Test Identity\"" make_signing_identity "$IDENTITIES"
expect "whose key is safe" 0 make_signing_identity --check "$IDENTITIES"
expect "and finds it again" 0 --says "already in" make_signing_identity "$IDENTITIES"
expect "--replace makes a new one" 0 --says "Created \"Test Identity\"" make_signing_identity --replace "$IDENTITIES"
expect "and leaves just that one" 0 test "$(security find-certificate -a -c "Test Identity" -Z "$IDENTITIES" | grep -c '^SHA-1 hash:')" = 1
expect "--delete deletes it" 0 make_signing_identity --delete "$IDENTITIES"
expect "and --check then finds none" 1 make_signing_identity --check "$IDENTITIES"
security_import "Test Identity" "$IDENTITIES" -x -T /usr/bin/codesign
expect "--check catches a key that some app may use without asking" 3 --says "--replace" make_signing_identity --check "$IDENTITIES"
expect "and won't sign with it" 1 --says "--replace" make_signing_identity "$IDENTITIES"

if [[ $FAILURES -gt 0 ]]; then
    echo "$FAILURES failed." >&2
    exit 1
fi
echo "signing-key-check passed."
