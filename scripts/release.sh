#!/bin/zsh
# Full release: test → build → sign → notarize app → DMG → notarize DMG → (optionally) publish.
#
#   scripts/release.sh             # build build/Elva-Scanner.dmg
#   scripts/release.sh --publish   # also create the GitHub release v$VERSION and upload the DMG
#
# Without a Developer ID certificate the DMG is ad-hoc signed and not notarized: it still works,
# but users must approve it once (see README → "Opening the app the first time").
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${VERSION:-$(cat VERSION)}
TAG="v$VERSION"
export VERSION

echo "▸ Running tests"
swift test

scripts/build-app.sh
APP="build/Elva Scanner.app"

# Notarize when signed with Developer ID and credentials are available: an API key (CI) or,
# locally, the keychain profile created with `xcrun notarytool store-credentials`.
CAN_NOTARIZE=no
if codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
  if [[ -n "${NOTARY_KEY_PATH:-}" || -z "${GITHUB_ACTIONS:-}" ]]; then CAN_NOTARIZE=yes; fi
fi

if [[ $CAN_NOTARIZE == yes ]]; then
  echo "▸ Notarizing the app"
  ditto -c -k --keepParent "$APP" build/Elva-Scanner-app.zip
  scripts/notarize.sh build/Elva-Scanner-app.zip
  xcrun stapler staple "$APP"
  rm -f build/Elva-Scanner-app.zip
  scripts/make-dmg.sh
  scripts/notarize.sh build/Elva-Scanner.dmg
  spctl --assess --type open --context context:primary-signature -v build/Elva-Scanner.dmg
  NOTARIZED=yes
else
  echo "⚠︎ Not notarizing (no Developer ID signature or no notary credentials)"
  scripts/make-dmg.sh
  NOTARIZED=no
fi

if [[ "${1:-}" == "--publish" ]]; then
  NOTES_FILE=$(mktemp)
  {
    echo "## Elva Scanner $VERSION"
    echo
    echo "**Download:** \`Elva-Scanner.dmg\` below → open it → drag *Elva Scanner* to *Applications*."
    echo
    if [[ $NOTARIZED == no ]]; then
      echo "> This build is not notarized by Apple. The first time, right-click the app → *Open*, or allow it in *System Settings → Privacy & Security*."
      echo
    fi
    echo "Requires macOS 15 Sequoia or later (tested on macOS 26 Tahoe). Universal: Apple Silicon and Intel."
  } > "$NOTES_FILE"
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" build/Elva-Scanner.dmg build/Elva-Scanner.dmg.sha256 --clobber
  else
    gh release create "$TAG" build/Elva-Scanner.dmg build/Elva-Scanner.dmg.sha256 \
      --title "Elva Scanner $VERSION" --notes-file "$NOTES_FILE" --generate-notes
  fi
  rm -f "$NOTES_FILE"
  echo "✓ Published $TAG"
fi
