#!/bin/bash
# Creates the certificate that releases are signed with. Run it once for the project, not once per Mac:
# like scripts/make-signing-identity.sh's, it's a self-signed code-signing certificate, but it goes into
# the release workflow's secrets rather than a keychain. Every release signed with it has the same
# designated requirement, so macOS keeps the Full Disk Access people gave ADO Pulse when they update.
#   scripts/make-release-certificate.sh [--replace] folder
# Writes the certificate's SHA-1 to scripts/release-certificate.sha1, which releases are checked
# against, and the values of two secrets into a new folder:
#   RELEASE_SIGNING_P12.txt           the certificate and its private key as a .p12 file, base64-encoded
#   RELEASE_SIGNING_P12_PASSWORD.txt  the .p12 file's password
# See "Releasing" in CONTRIBUTING.md. A new certificate makes everyone allow Full Disk Access again, so
# when there's one already, this needs --replace.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="ADO Pulse Release"
PIN="scripts/release-certificate.sha1"
REPLACE=false
if [[ "${1:-}" == "--replace" ]]; then
    REPLACE=true
    shift
fi
OUT="${1:?Usage: scripts/make-release-certificate.sh [--replace] folder}"
if [[ -e "$OUT" ]]; then
    echo "$OUT already exists." >&2
    exit 1
fi
if grep -qv '^#' "$PIN" 2>/dev/null && ! $REPLACE; then
    echo "$PIN already names the release certificate. A new one makes everyone allow Full Disk" >&2
    echo "Access again when they update; to make one anyway, pass --replace." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# macOS's own LibreSSL rather than whatever openssl comes first: `security import` can't read the .p12
# files that OpenSSL 3 writes by default.
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
P12_PASSWORD="$(/usr/bin/openssl rand -base64 24)"
P12_PASSWORD="$P12_PASSWORD" /usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" \
    -in "$WORK/certificate.pem" -passout env:P12_PASSWORD -out "$WORK/identity.p12"

mkdir -m 700 "$OUT"
umask 077
base64 -i "$WORK/identity.p12" -o "$OUT/RELEASE_SIGNING_P12.txt"
# No line break at the end: it would become part of the secret.
printf '%s' "$P12_PASSWORD" > "$OUT/RELEASE_SIGNING_P12_PASSWORD.txt"
umask 022

SHA1="$(/usr/bin/openssl x509 -in "$WORK/certificate.pem" -noout -fingerprint -sha1 | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f')"
{
    echo "# The SHA-1 of the certificate that releases are signed with (scripts/make-release-certificate.sh)."
    echo "# Releases are checked against it. A new certificate makes everyone allow Full Disk Access again."
    echo "$SHA1"
} > "$PIN"

cat <<EOF
Created the "$NAME" certificate (SHA-1 $SHA1), valid for 10 years, and wrote its SHA-1 to $PIN.
Next:
1. Add two repository secrets (Settings › Secrets and variables › Actions › New repository secret):
   RELEASE_SIGNING_P12, with the contents of $OUT/RELEASE_SIGNING_P12.txt, and
   RELEASE_SIGNING_P12_PASSWORD, with the contents of $OUT/RELEASE_SIGNING_P12_PASSWORD.txt.
2. Keep both somewhere safe, such as a password manager, then delete $OUT.
3. Commit $PIN.
EOF
