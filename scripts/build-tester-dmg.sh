#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="ThreadKeep"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
PLIST_PATH="$ROOT_DIR/Sources/ThreadKeep/Support/ThreadKeepInfo.plist"
README_TEMPLATE_PATH="$ROOT_DIR/Sources/ThreadKeep/Support/TesterReadMeTemplate.txt"
STAGE_DIR="$DIST_DIR/tester-dmg-root"
README_PATH="$STAGE_DIR/Read Me First.txt"
VOL_NAME="$APP_NAME"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_PATH")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST_PATH")"
DMG_NAME="$APP_NAME-$VERSION-Apple-Silicon.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

cd "$ROOT_DIR"

"$ROOT_DIR/scripts/build-release-app.sh"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "Missing app bundle at $APP_BUNDLE" >&2
    exit 1
fi

if [[ ! -f "$README_TEMPLATE_PATH" ]]; then
    echo "Missing tester read me template at $README_TEMPLATE_PATH" >&2
    exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

cp -R "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

sed \
    -e "s/__VERSION__/$VERSION ($BUILD_NUMBER)/g" \
    "$README_TEMPLATE_PATH" > "$README_PATH"

hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo
echo "Built tester DMG:"
echo "  $DMG_PATH"
echo
echo "Contents:"
echo "  $APP_NAME.app"
echo "  Applications"
echo "  Read Me First.txt"
