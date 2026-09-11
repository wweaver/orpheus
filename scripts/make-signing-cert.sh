#!/usr/bin/env bash
#
# Create a stable, self-signed code-signing identity for local builds.
#
# Why: without one, Xcode signs the app ad-hoc and its designated requirement
# is a bare code hash that changes on every build:
#
#     designated => cdhash H"4411..."
#
# macOS binds keychain ACLs to that requirement, so every reinstall looks like
# a brand-new app and the saved Pandora credentials become unreadable — you
# retype your password after every `./scripts/install.sh`. Signing with a
# stable certificate makes the requirement identity-based instead:
#
#     designated => identifier "org.pianobar-gui.PianobarGUI" and certificate root = H"..."
#
# which survives rebuilds, so the credentials stick.
#
# The certificate is only used locally. It is NOT added to your trust settings
# — `codesign` doesn't need that, and leaving it untrusted keeps the change
# contained to a single keychain entry.
#
# To undo: delete "Orpheus Code Signing" in Keychain Access (login keychain,
# My Certificates), and drop CODE_SIGN_IDENTITY from project.yml.

set -euo pipefail

CERT_NAME="Orpheus Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
  echo "✓ '$CERT_NAME' already exists in your login keychain; nothing to do."
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = Orpheus Code Signing
O  = Orpheus

[ v3 ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "▶︎ Generating a 10-year self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -config "$WORK/openssl.cnf" >/dev/null 2>&1

# The passphrase only protects the PKCS#12 in transit to the keychain; the
# file is deleted moments later by the trap above.
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/id.p12" -passout pass:orpheus-temp -name "$CERT_NAME" >/dev/null 2>&1

echo "▶︎ Importing into your login keychain"
# -T lets codesign use the private key without prompting every build.
security import "$WORK/id.p12" -k "$KEYCHAIN" -P orpheus-temp \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "✓ Created '$CERT_NAME'."
echo "  Builds will now be signed with it; run ./scripts/install.sh to pick it up."
