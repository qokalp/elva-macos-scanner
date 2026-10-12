#!/bin/zsh
# Packs "build/Elva Scanner.app" into build/Elva-Scanner.dmg (drag-to-Applications layout).
# The file name stays the same for every release so that
# https://github.com/qokalp/elva-macos-scanner/releases/latest/download/Elva-Scanner.dmg always works.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Elva Scanner.app"
DMG="build/Elva-Scanner.dmg"
STAGE=build/dmg-stage
[[ -d "$APP" ]] || { echo "Run scripts/build-app.sh first"; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Elva Scanner" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"

IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)
if [[ -n "$IDENTITY" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  echo "▸ Signed DMG with $IDENTITY"
fi
shasum -a 256 "$DMG" | sed 's|build/||' > "$DMG.sha256"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
