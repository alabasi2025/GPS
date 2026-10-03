#!/usr/bin/env bash
# Restore the release signing key so new builds UPDATE the installed app
# (same certificate) instead of requiring uninstall.
#   usage:  SIGNING_PASS='xxxx' ./signing/restore.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGNING_PASS:?set SIGNING_PASS (ask the owner; never commit it)}"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in signing/signing.tgz.enc -pass env:SIGNING_PASS | tar xzf - -C android
echo "restored android/release-key.jks + android/key.properties"
EXPECTED=e7144bbc67e4c89c5bf4157ecab90c21d4737fde4ba34a0f7571d209bfc86f63
ACTUAL=$(sha256sum android/release-key.jks | cut -d' ' -f1)
[ "$ACTUAL" = "$EXPECTED" ] && echo "keystore SHA-256 OK" || { echo "keystore SHA-256 MISMATCH"; exit 1; }
