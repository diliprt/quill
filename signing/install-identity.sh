#!/usr/bin/env bash
# Recreate Quill's local code-signing identity.
#
# Self-signed, trusted by nobody — its only job is to keep the app's code identity
# stable so macOS stops treating each rebuild as a different app and re-asking for
# Accessibility and Microphone.
#
# It goes in a DEDICATED keychain, not the login keychain, with a password set
# here and codesign pre-authorised via set-key-partition-list. In the login
# keychain, macOS prompts for the user's password on every single build.
set -euo pipefail
cd "$(dirname "$0")"

KCNAME="quill-signing.keychain"
KC="$HOME/Library/Keychains/quill-signing.keychain-db"

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config cert.cnf -keyout key.pem -out cert.pem 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -out quill.p12 \
  -passout pass:quill -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -name "Quill Local Signing"

security delete-keychain "$KCNAME" 2>/dev/null || true
security create-keychain -p quill "$KCNAME"
security set-keychain-settings "$KCNAME"          # never auto-lock
security unlock-keychain -p quill "$KCNAME"
security import quill.p12 -k "$KCNAME" -P quill -A -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k quill "$KCNAME" >/dev/null

EXISTING=$(security list-keychains -d user | sed 's/[",]//g' | xargs)
case "$EXISTING" in
  *quill-signing*) ;;
  *) security list-keychains -d user -s $EXISTING "$KC" ;;
esac

echo "✓ 'Quill Local Signing' installed in its own keychain — builds will not prompt."
echo "  Note: the app's code identity changed, so grant Accessibility once more."
