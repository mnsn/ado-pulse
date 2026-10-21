# Sourced by the scripts that sign ADO Pulse: scripts/build-app.sh, scripts/sign-package.sh and
# scripts/make-signing-identity.sh. They find the identity to sign with by its exact name, check its key,
# and sign with its SHA-1, so that codesign can't pick another one. Given a name, codesign uses an identity
# preference by that name if there is one, and otherwise a certificate whose name merely contains it:
# neither need be the one whose key was checked. scripts/test-signing-key.sh tests these.

SIGNING_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

signing_key() { swift -suppress-warnings "$SIGNING_SCRIPTS/signing-key.swift" "$@"; }

# signing_identity <name> [keychain]: prints the SHA-1 of the one identity whose certificate is named exactly
# <name>, in the keychain or on the search list. Fails with status 1 if there's none, and 4 if there's more
# than one.
signing_identity() { signing_key find "$@"; }

# require_safe_key <name or SHA-1> <name> [keychain]: fails, and says what to do, if some app may use the
# certificate's key without asking, or it can be exported, or that can't be told. Such a key would let
# anything running as you sign code as ADO Pulse, and get the Full Disk Access you gave ADO Pulse.
require_safe_key() {
    local status=0
    signing_key check "$1" ${3:+"$3"} || status=$?
    case $status in
        0) return 0 ;;
        3)
            echo "So anything running as you could sign code as ADO Pulse with \"$2\", and get the Full Disk Access" >&2
            echo "you gave ADO Pulse. Replace it, and when macOS asks, choose Allow, never Always Allow:" >&2
            echo "  scripts/make-signing-identity.sh --replace" >&2
            ;;
        2) echo "Couldn't check who may use the key of \"$2\"." >&2 ;;
    esac
    return $status
}

# sign_with <SHA-1> <path> <keychain, or ""> [codesign options...]: signs with exactly that certificate, and
# checks that the signature names it. On macOS 15 and 26, codesign finds it only in a keychain on the search
# list, even with --keychain.
sign_with() {
    local hash="$1" target="$2" keychain="$3" requirement
    shift 3
    if [[ ! "$hash" =~ ^[0-9A-F]{40}$ ]]; then
        echo "Not a certificate's SHA-1: \"$hash\"." >&2
        return 1
    fi
    codesign --force "$@" --sign "$hash" ${keychain:+--keychain "$keychain"} "$target" || return 1
    requirement="$(codesign -d -r- "$target" 2>&1 | sed -n 's/^#* *designated => //p')"
    if [[ "$requirement" != *"certificate leaf = H\"$(printf '%s' "$hash" | tr 'A-F' 'a-f')\""* ]]; then
        echo "$target isn't signed with the certificate $hash: $requirement" >&2
        return 1
    fi
}
