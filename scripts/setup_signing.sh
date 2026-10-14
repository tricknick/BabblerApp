#!/bin/bash
# Creates the "Babbler Local Signing" self-signed code-signing identity in the login
# keychain. Idempotent: does nothing if the identity already exists.
#
# The identity is intentionally NOT added to the trust store (that would need an
# interactive password prompt). codesign accepts it by SHA-1 hash anyway, and it is
# that stable certificate, not the ad-hoc cdhash, that keeps TCC grants valid across updates.
set -euo pipefail

IDENTITY_NAME="Babbler Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$ROOT_DIR/build/signing-setup"
OPENSSL=/usr/bin/openssl

identity_present() {
  security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY_NAME\""
}

if identity_present; then
  echo "Signing identity \"$IDENTITY_NAME\" already present."
  exit 0
fi

echo "==> Creating self-signed code-signing identity \"$IDENTITY_NAME\"..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no

[dn]
CN = Babbler Local Signing

[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -config "$WORK_DIR/openssl.cnf" \
  -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" >/dev/null 2>&1

P12_PASS="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
  -name "$IDENTITY_NAME" -passout "pass:$P12_PASS" \
  -out "$WORK_DIR/identity.p12" >/dev/null 2>&1

security import "$WORK_DIR/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

if ! identity_present; then
  echo "ERROR: identity \"$IDENTITY_NAME\" not found after import." >&2
  exit 1
fi

echo "==> Identity \"$IDENTITY_NAME\" installed in the login keychain."
