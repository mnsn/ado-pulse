#!/bin/bash
# Checks, in throwaway keychains, what keeps the keys that ADO Pulse is signed with safe
# (scripts/signing-key.swift): a key it imports trusts no app, or only the one it's told to, and can't be
# exported, not even by that app; and its check catches a key that some app may use without asking, or
# that can be exported. Then that builds sign with the certificate named exactly so, by its SHA-1
# (scripts/signing.sh), not one with a name like it. And it runs scripts/make-signing-identity.sh.
# Nothing here makes macOS ask anything.
#   scripts/test-signing-key.sh   (make signing-key-check)
# One more check needs an identity preference, which macOS keeps in your default keychain: it runs on GitHub
# Actions, or with ADO_PULSE_TEST_IDENTITY_PREFERENCE=1, and removes it afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh

OPENSSL=/usr/bin/openssl
WORK="$(mktemp -d)"
KEYCHAINS=()
SEARCH_LIST=()
PREFERENCE=""
DEFAULT_KEYCHAIN=""
cleanup() {
    [[ -n "$PREFERENCE" ]] && security set-identity-preference -n -s "$PREFERENCE" 2>/dev/null
    [[ -n "$DEFAULT_KEYCHAIN" ]] && security default-keychain -d user -s "$DEFAULT_KEYCHAIN"
    [[ ${#SEARCH_LIST[@]} -gt 0 ]] && security list-keychains -d user -s "${SEARCH_LIST[@]}"
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

# The SHA-1 of the certificate named exactly $1 in keychain $2.
sha1_of() {
    security find-certificate -a -c "$1" -Z "$2" | awk -v name="$1" '
        /^SHA-1 hash:/ { hash = $3 }
        /"labl"<blob>=/ { label = $0; sub(/^[^=]*="/, "", label); sub(/"$/, "", label); if (label == name) print hash }'
}

# signs_with <SHA-1> command...: runs the command, then checks that the probe is signed with that certificate.
signs_with() {
    local expected requirement
    expected="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
    shift
    "$@" || return 1
    requirement="$(/usr/bin/codesign -d -r- "$WORK/probe" 2>&1 | sed -n 's/^#* *designated => //p')"
    [[ "$requirement" == *"certificate leaf = H\"$expected\""* ]] || { echo "Signed: $requirement"; return 1; }
}

# Puts a keychain on the search list, until the end. codesign on macOS 15 and 26 finds an identity only in a keychain
# there, even when told which, so the release workflow puts its own there too.
add_to_search_list() {
    local line current=()
    while IFS= read -r line; do
        line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
        [[ -n "$line" ]] && current+=("$line")
    done <<< "$(security list-keychains -d user)"
    [[ ${#SEARCH_LIST[@]} -eq 0 ]] && SEARCH_LIST=("${current[@]}")
    security list-keychains -d user -s "${current[@]}" "$1"
}

# Lets codesign use every key in a keychain without asking, as in the release workflow's.
open_to_codesign() {
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$1" >/dev/null
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

# Which certificate builds are signed with: the one named exactly so, by its SHA-1. These keys may be used without
# asking, as in the release workflow's keychain, so that codesign can sign here.
cp /usr/bin/true "$WORK/probe"
LOOKALIKE="$WORK/lookalike.keychain-db"
new_keychain "$LOOKALIKE"
security_import "Test Lookalike Copy" "$LOOKALIKE" -T /usr/bin/codesign
open_to_codesign "$LOOKALIKE"
# A throwaway machine, where codesign needs it: here, the search list is left alone.
[[ "${GITHUB_ACTIONS:-}" == true ]] && add_to_search_list "$LOOKALIKE"
expect "codesign itself, given a name no certificate has exactly, signs with one whose name contains it" 0 \
    signs_with "$(sha1_of "Test Lookalike Copy" "$LOOKALIKE")" \
    codesign --force --sign "Test Lookalike" --keychain "$LOOKALIKE" --timestamp=none "$WORK/probe"
expect "while signing_identity finds no certificate named so, and builds are signed ad hoc" 1 \
    signing_identity "Test Lookalike" "$LOOKALIKE"

CHOOSING="$WORK/choosing.keychain-db"
new_keychain "$CHOOSING"
helper_import "Test Signer" "$CHOOSING" --trust /usr/bin/codesign
security_import "Test Signer Copy" "$CHOOSING" -T /usr/bin/codesign
security_import "Copy of Test Signer" "$CHOOSING" -T /usr/bin/codesign
open_to_codesign "$CHOOSING"
[[ "${GITHUB_ACTIONS:-}" == true ]] && add_to_search_list "$CHOOSING"
SIGNER="$(sha1_of "Test Signer" "$CHOOSING")"
expect "signing_identity finds the certificate named exactly so, among look-alikes" 0 --says "$SIGNER" \
    signing_identity "Test Signer" "$CHOOSING"
expect "sign_with signs with the certificate it's given, by its SHA-1" 0 \
    signs_with "$SIGNER" sign_with "$SIGNER" "$WORK/probe" "$CHOOSING" --timestamp=none
expect "but not given a name" 1 --says "Not a certificate's SHA-1" sign_with "Test Signer" "$WORK/probe" "$CHOOSING"
mkdir "$WORK/liar"
printf '#!/bin/sh\n[ "$1" = -d ] && echo "designated => certificate leaf = H\\"0000000000000000000000000000000000000000\\"" >&2\nexit 0\n' \
    > "$WORK/liar/codesign"
chmod +x "$WORK/liar/codesign"
with_lying_codesign() { (PATH="$WORK/liar:$PATH" && hash -r && "$@"); }
expect "and it fails when the signature names another certificate" 1 --says "isn't signed with the certificate" \
    with_lying_codesign sign_with "$SIGNER" "$WORK/probe" "$CHOOSING"

TWINS="$WORK/twins.keychain-db"
new_keychain "$TWINS"
helper_import "Test Twin" "$TWINS"
helper_import "Test Twin" "$TWINS"
expect "signing_identity won't choose between two certificates named so" 4 --says "more than one" \
    signing_identity "Test Twin" "$TWINS"

if [[ "${GITHUB_ACTIONS:-}" == true || "${ADO_PULSE_TEST_IDENTITY_PREFERENCE:-}" == 1 ]]; then
    PREFERRING="$WORK/preferring.keychain-db"
    new_keychain "$PREFERRING"
    helper_import "Test Preferred" "$PREFERRING" --trust /usr/bin/codesign
    helper_import "Test Decoy" "$PREFERRING" --trust /usr/bin/codesign
    open_to_codesign "$PREFERRING"
    PREFERRED="$(sha1_of "Test Preferred" "$PREFERRING")"
    # codesign finds an identity preference's certificate on the search list.
    add_to_search_list "$PREFERRING"
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
        # A throwaway machine, whose login keychain may be locked: the preference goes in the throwaway keychain.
        DEFAULT_KEYCHAIN="$(security default-keychain -d user | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
        security default-keychain -d user -s "$PREFERRING"
    fi
    PREFERENCE="Test Preferred"
    security set-identity-preference -s "$PREFERENCE" -Z "$(sha1_of "Test Decoy" "$PREFERRING")" "$PREFERRING"
    expect "codesign itself, given a name, signs with the identity preference by that name" 0 \
        signs_with "$(sha1_of "Test Decoy" "$PREFERRING")" codesign --force --sign "Test Preferred" --timestamp=none "$WORK/probe"
    expect "while sign_with signs with the certificate named so, by its SHA-1" 0 \
        signs_with "$PREFERRED" sign_with "$(signing_identity "Test Preferred")" "$WORK/probe" "" --timestamp=none
    security set-identity-preference -n -s "$PREFERENCE"
    PREFERENCE=""
    if [[ -n "$DEFAULT_KEYCHAIN" ]]; then
        security default-keychain -d user -s "$DEFAULT_KEYCHAIN"
        DEFAULT_KEYCHAIN=""
    fi
else
    echo "skipped: an identity preference named like the certificate (it goes in your default keychain: set"
    echo "         ADO_PULSE_TEST_IDENTITY_PREFERENCE=1 to check it here; GitHub Actions does)"
fi

# scripts/make-signing-identity.sh, with a stand-in for codesign, which would ask to use the key. It says that it
# signed with what it was given, and fails given a name rather than a certificate's SHA-1.
mkdir "$WORK/bin"
cat > "$WORK/bin/codesign" <<EOF
#!/bin/sh
if [ "\$1" = -d ]; then
    echo "designated => identifier \\"probe\\" and certificate leaf = H\\"\$(tr 'A-F' 'a-f' < "$WORK/signed-with")\\"" >&2
    exit 0
fi
while [ \$# -gt 0 ]; do
    if [ "\$1" = --sign ]; then
        printf '%s' "\$2" | grep -Eq '^[0-9A-F]{40}\$' || { echo "stand-in codesign: given a name: \$2" >&2; exit 1; }
        printf '%s' "\$2" > "$WORK/signed-with"
    fi
    shift
done
EOF
chmod +x "$WORK/bin/codesign"
IDENTITIES="$WORK/identities.keychain-db"
new_keychain "$IDENTITIES"
make_signing_identity() { ADO_PULSE_SIGNING_IDENTITY="Test Identity" PATH="$WORK/bin:$PATH" ./scripts/make-signing-identity.sh "$@"; }
security_import "Test Identity Copy" "$IDENTITIES" -T /usr/bin/codesign
expect "make-signing-identity.sh creates a certificate, whatever the names of others" 0 --says "Created \"Test Identity\"" \
    make_signing_identity "$IDENTITIES"
expect "and signed with it" 0 test "$(cat "$WORK/signed-with")" = "$(sha1_of "Test Identity" "$IDENTITIES")"
expect "whose key is safe" 0 make_signing_identity --check "$IDENTITIES"
expect "and finds it again" 0 --says "already in" make_signing_identity "$IDENTITIES"
expect "--replace makes a new one" 0 --says "Created \"Test Identity\"" make_signing_identity --replace "$IDENTITIES"
expect "and leaves just that one" 0 test "$(sha1_of "Test Identity" "$IDENTITIES" | wc -l | tr -d ' ')" = 1
expect "and the others" 0 test -n "$(sha1_of "Test Identity Copy" "$IDENTITIES")"
expect "--delete deletes it" 0 make_signing_identity --delete "$IDENTITIES"
expect "and --check then finds none" 1 make_signing_identity --check "$IDENTITIES"
security_import "Test Identity" "$IDENTITIES" -x -T /usr/bin/codesign
expect "--check catches a key that some app may use without asking" 3 --says "--replace" make_signing_identity --check "$IDENTITIES"
expect "and won't sign with it" 1 --says "--replace" make_signing_identity "$IDENTITIES"
expect "won't choose between two certificates named so either" 1 --says "--replace" \
    env ADO_PULSE_SIGNING_IDENTITY="Test Twin" PATH="$WORK/bin:$PATH" ./scripts/make-signing-identity.sh "$TWINS"

if [[ $FAILURES -gt 0 ]]; then
    echo "$FAILURES failed." >&2
    exit 1
fi
echo "signing-key-check passed."
