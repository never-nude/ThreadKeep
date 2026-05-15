#!/usr/bin/env bash
#
# build-dmg.sh — build ThreadKeep v2 and wrap it in a .dmg for local testing.
#
# Run this from the ThreadKeep-v2 root:
#   ./scripts/build-dmg.sh
#
# Requires: Xcode command-line tools (swift), hdiutil (ships with macOS).
# Produces: build/ThreadKeep.dmg
#
# This builds an UNSIGNED app. It will run locally after a right-click → Open
# (or `xattr -d com.apple.quarantine ThreadKeep.app` if Gatekeeper complains).
# For real distribution you'll want to sign + notarize, but for "let me try it"
# this is enough.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

APP_NAME="ThreadKeep"
CONFIG="release"
BUILD_DIR="$ROOT/build"
PACKAGE_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/threadkeep-build.XXXXXX")"
APP_DIR="$PACKAGE_TMP_DIR/$APP_NAME.app"
DMG_STAGE_DIR="$PACKAGE_TMP_DIR/dmg-stage"
DMG_PATH_TMP="$PACKAGE_TMP_DIR/$APP_NAME.dmg"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

cleanup() {
    rm -rf "$PACKAGE_TMP_DIR"
}

trap cleanup EXIT

echo "==> Cleaning previous build artifacts"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Compiling Swift package ($CONFIG)"
# Build both arm64 and x86_64 so the app runs on Apple Silicon and Intel Macs.
swift build -c "$CONFIG" \
    --arch arm64 \
    --arch x86_64

BIN_PATH="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)"
BINARY="$BIN_PATH/$APP_NAME"

if [ ! -f "$BINARY" ]; then
    echo "!! Build did not produce $BINARY" >&2
    exit 1
fi

echo "==> Assembling $APP_NAME.app bundle"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "Sources/ThreadKeep/Support/ThreadKeep.icns" "$APP_DIR/Contents/Resources/"
cp "Sources/ThreadKeep/Support/ThreadKeepInfo.plist" "$APP_DIR/Contents/Info.plist"
RESOURCE_BUNDLE="$BIN_PATH/ThreadKeep_ThreadKeep.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
fi
xattr -cr "$APP_DIR"

# The Info.plist is also linker-embedded, but giving the bundle a loose copy
# means Finder's Get Info picks the icon and version up reliably.

echo "==> Ad-hoc signing (so Gatekeeper will at least let you Open)"
codesign --force --deep --sign - "$APP_DIR"

echo "==> Staging DMG contents"
mkdir -p "$DMG_STAGE_DIR"
cp -R "$APP_DIR" "$DMG_STAGE_DIR/"
ln -s /Applications "$DMG_STAGE_DIR/Applications"

echo "==> Creating compressed DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGE_DIR" \
    -ov -format UDZO \
    "$DMG_PATH_TMP"

echo "==> Copying packaged artifacts into build/"
ditto "$APP_DIR" "$BUILD_DIR/$APP_NAME.app"
xattr -cr "$BUILD_DIR/$APP_NAME.app"
cp "$DMG_PATH_TMP" "$DMG_PATH"

echo ""
echo "Done."
echo "  App:  $APP_DIR"
echo "  DMG:  $DMG_PATH"
echo ""
echo "First-run tip: because this build is ad-hoc signed, macOS will refuse to"
echo "open it with a double-click. Right-click the app → Open, or run:"
echo "  xattr -d com.apple.quarantine \"$APP_DIR\""
