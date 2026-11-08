#!/bin/bash
# Creates a self-signed code-signing certificate for Cortex releases and prints how to add it to the repo.
#
# Why: releases are ad-hoc signed, and an ad-hoc signature's identity is a hash of that exact build. macOS
# ties Accessibility / Screen Recording / Automation grants to that identity, so after every update the old
# grant stops applying (the switch still looks "on") and you have to remove Cortex and add it again.
# Signing every release with the same certificate gives it a stable identity, so grants survive updates.
# (A paid Apple Developer ID does the same and also removes the "unidentified developer" warning.)
#
# Run once on your Mac:  bash native/scripts/make-signing-cert.sh
set -euo pipefail
NAME="Cortex Release Signing"
DIR="$(mktemp -d)"
PASS="$(openssl rand -hex 16)"
cat > "$DIR/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$DIR/cert.cnf" -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -name "$NAME" -out "$DIR/cert.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -name "$NAME" -out "$DIR/cert.p12" -passout "pass:$PASS"
B64="$DIR/cert.p12.b64"
base64 -i "$DIR/cert.p12" > "$B64"
echo
echo "Certificate created: $DIR/cert.p12"
echo
if command -v gh >/dev/null 2>&1; then
  echo "Adding it to the repository secrets with gh…"
  gh secret set MACOS_CERT_P12 --repo rayanjainn/aio < "$B64"
  printf '%s' "$PASS" | gh secret set MACOS_CERT_PASSWORD --repo rayanjainn/aio
  echo "Done. The next release is signed with it."
else
  echo "Add two repository secrets (GitHub → Settings → Secrets and variables → Actions):"
  echo "  MACOS_CERT_P12      = the contents of $B64"
  echo "  MACOS_CERT_PASSWORD = $PASS"
fi
echo
echo "Keep $DIR/cert.p12 somewhere safe (a password manager). After installing the first release signed with it,"
echo "open Cortex → Settings → Privacy & Permissions → 'Reset and ask again' once; from then on grants survive updates."
rm -f "$DIR/key.pem"
