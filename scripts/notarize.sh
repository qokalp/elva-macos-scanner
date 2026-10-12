#!/bin/zsh
# Submits a file (.dmg or .zip) to Apple's notary service, waits, and staples the ticket.
#
#   scripts/notarize.sh build/Elva-Scanner.dmg
#
# Credentials, either:
#   NOTARY_PROFILE  name of a keychain profile created once with
#                   xcrun notarytool store-credentials elva-notary --apple-id you@example.com --team-id TEAMID
#                   (default: elva-notary)
# or, for CI, an App Store Connect API key:
#   NOTARY_KEY_PATH (path to AuthKey_XXXX.p8), NOTARY_KEY_ID, NOTARY_ISSUER_ID
set -euo pipefail
FILE=$1

if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  AUTH=(--keychain-profile "${NOTARY_PROFILE:-elva-notary}")
fi

echo "▸ Notarizing $FILE (this usually takes a few minutes)"
xcrun notarytool submit "$FILE" "${AUTH[@]}" --wait --timeout 30m

case "$FILE" in
  *.zip) ;;   # zips can't be stapled; staple the .app inside instead (see release.sh)
  *) xcrun stapler staple "$FILE" && xcrun stapler validate "$FILE" ;;
esac
echo "✓ Notarized $FILE"
