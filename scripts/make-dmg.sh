#!/bin/zsh
# Packs "build/Elva Scanner.app" into build/Elva-Scanner.dmg with a designed window:
# background with a drag arrow, app on the left, Applications on the right.
# The file name stays the same for every release so that
# https://github.com/qokalp/elva-macos-scanner/releases/latest/download/Elva-Scanner.dmg always works.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Elva Scanner.app"
DMG="build/Elva-Scanner.dmg"
[[ -d "$APP" ]] || { echo "Run scripts/build-app.sh first"; exit 1; }

rm -f "$DMG"

# dmgbuild writes the Finder window layout (background, icon positions, window size) into the image
# without having to script Finder, so the result is the same locally and on CI.
VENV=build/.venv
if [[ ! -x $VENV/bin/dmgbuild ]]; then
  python3 -m venv $VENV
  $VENV/bin/pip install --quiet dmgbuild
fi

BG=build/dmg-background
swift scripts/make-dmg-background.swift $BG
tiffutil -cathidpicheck $BG/background.png $BG/background@2x.png -out $BG/background.tiff >/dev/null

$VENV/bin/dmgbuild -s scripts/dmg-settings.py \
  -D app="$APP" -D background="$BG/background.tiff" -D icon=build/AppIcon.icns \
  "Elva Scanner" "$DMG"

IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)
if [[ -n "$IDENTITY" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  echo "▸ Signed DMG with $IDENTITY"
fi
shasum -a 256 "$DMG" | sed 's|build/||' > "$DMG.sha256"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
