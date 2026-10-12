#!/bin/zsh
# Builds "build/Elva Scanner.app" as a universal (Apple Silicon + Intel) release build.
#
#   scripts/build-app.sh               # build (signs with Developer ID if available, else ad-hoc)
#   scripts/build-app.sh --install     # also copy to /Applications
#
# Environment:
#   VERSION         app version (default: contents of ./VERSION)
#   BUILD_NUMBER    build number (default: git commit count)
#   SIGN_IDENTITY   codesign identity; default: first "Developer ID Application" in the keychain,
#                   or "-" (ad-hoc) when there is none
#   ARCHS           architectures (default: "arm64 x86_64")
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-$(cat VERSION)}
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
ARCHS=(${=ARCHS:-arm64 x86_64})
APP="build/Elva Scanner.app"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
  SIGN_IDENTITY=${SIGN_IDENTITY:--}
fi

ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch $a); done

echo "▸ Building Elva Scanner $VERSION ($BUILD_NUMBER) for ${ARCHS[*]}"
swift build -c release $ARCH_FLAGS --product ElvaScanner
swift build -c release $ARCH_FLAGS --product elvascan
BIN=$(swift build -c release $ARCH_FLAGS --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ElvaScanner" "$APP/Contents/MacOS/ElvaScanner"
cp "$BIN/elvascan" "$APP/Contents/MacOS/elvascan"
cp Sources/ElvaScanner/Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Sources/ElvaScanner/Resources/*.lproj "$APP/Contents/Resources/"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "▸ Signing ad-hoc (no Developer ID certificate found – fine for local use, not for distribution)"
  codesign --force --sign - "$APP/Contents/MacOS/elvascan"
  codesign --force --sign - "$APP"
else
  echo "▸ Signing with: $SIGN_IDENTITY (hardened runtime)"
  for target in "$APP/Contents/MacOS/elvascan" "$APP"; do
    codesign --force --timestamp --options runtime \
      --entitlements scripts/Elva.entitlements --sign "$SIGN_IDENTITY" "$target"
  done
fi
codesign --verify --strict --verbose=1 "$APP"
lipo -info "$APP/Contents/MacOS/ElvaScanner"
echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/Elva Scanner.app"
  cp -R "$APP" /Applications/
  echo "✓ Installed /Applications/Elva Scanner.app"
fi
