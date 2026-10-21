#!/bin/bash
# For the release workflow: puts the release certificate, from the release environment's
# RELEASE_SIGNING_P12 and RELEASE_SIGNING_P12_PASSWORD secrets (see scripts/make-release-certificate.sh),
# in a new keychain that codesign may use without asking. On GitHub Actions, the later steps get
# ADO_PULSE_SIGNING_KEYCHAIN and ADO_PULSE_SIGNING_IDENTITY, for scripts/sign-package.sh. Delete the
# keychain afterwards: security delete-keychain keychain
#   scripts/import-signing-certificate.sh keychain
set -euo pipefail

KEYCHAIN="${1:?Usage: scripts/import-signing-certificate.sh keychain}"
if [[ -z "${RELEASE_SIGNING_P12:-}" || -z "${RELEASE_SIGNING_P12_PASSWORD:-}" ]]; then
    echo "${GITHUB_ACTIONS:+::error::}The release environment has no RELEASE_SIGNING_P12 and RELEASE_SIGNING_P12_PASSWORD" \
        "secrets. See \"Releasing\" in CONTRIBUTING.md." >&2
    exit 1
fi

# Nothing else is ever in this keychain, so its password only needs to last until it's deleted.
KEYCHAIN_PASSWORD="$(/usr/bin/openssl rand -base64 24)"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# Only codesign may use the key without asking, and nothing can export it, so the steps after this one
# can sign with it but not take it (scripts/signing-key.swift: security import's -x has no effect on a
# PKCS #12). The password and the certificate reach it through a pipe, not its command line.
printf '%s\n%s\n' "$RELEASE_SIGNING_P12_PASSWORD" "$RELEASE_SIGNING_P12" |
    swift -suppress-warnings "$(dirname "$0")/signing-key.swift" import "$KEYCHAIN" "ADO Pulse Release" --trust /usr/bin/codesign
# Lets codesign use the key without asking, which it couldn't do on a build machine.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" | sed -n 's/^ *1) [0-9A-F]* "\(.*\)".*$/\1/p')"
if [[ -z "$IDENTITY" ]]; then
    echo "RELEASE_SIGNING_P12 has no code-signing certificate and private key." >&2
    exit 1
fi
echo "Imported \"$IDENTITY\" into $KEYCHAIN."
if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
        echo "ADO_PULSE_SIGNING_KEYCHAIN=$KEYCHAIN"
        echo "ADO_PULSE_SIGNING_IDENTITY=$IDENTITY"
    } >> "$GITHUB_ENV"
fi
