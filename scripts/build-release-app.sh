#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH_DIR="${THREADKEEPER_BUILD_CACHE:-$HOME/Library/Caches/ThreadKeepBuild/swiftpm}"
DIST_DIR="$ROOT_DIR/dist"
PRODUCT_NAME="ThreadKeep"
APP_NAME="ThreadKeep"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
PLIST_PATH="$ROOT_DIR/Sources/ThreadKeep/Support/ThreadKeepInfo.plist"
ICON_PATH="$ROOT_DIR/Sources/ThreadKeep/Support/ThreadKeep.icns"

cd "$ROOT_DIR"

echo "Building $PRODUCT_NAME into $APP_NAME.app in Release mode..."
rm -rf "$SCRATCH_DIR"
mkdir -p "$(dirname "$SCRATCH_DIR")" "$DIST_DIR"

# A clean scratch build is slower, but it avoids stale module/build-db issues
# and keeps packaging deterministic across machines.
swift build --scratch-path "$SCRATCH_DIR" -c release --product "$PRODUCT_NAME"

EXECUTABLE_PATH="$(find "$SCRATCH_DIR" -path "*/release/$PRODUCT_NAME" -type f | head -n 1)"
RESOURCE_BUNDLE_PATH="$(find "$SCRATCH_DIR" -path "*/release/${PRODUCT_NAME}_${PRODUCT_NAME}.bundle" -type d | head -n 1)"

if [[ -z "$EXECUTABLE_PATH" || ! -x "$EXECUTABLE_PATH" ]]; then
    echo "Missing release executable at $EXECUTABLE_PATH" >&2
    exit 1
fi

if [[ ! -f "$PLIST_PATH" ]]; then
    echo "Missing Info.plist at $PLIST_PATH" >&2
    exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$EXECUTABLE_PATH" "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"
cp "$PLIST_PATH" "$APP_BUNDLE/Contents/Info.plist"

if [[ -n "$RESOURCE_BUNDLE_PATH" && -d "$RESOURCE_BUNDLE_PATH" ]]; then
    cp -R "$RESOURCE_BUNDLE_PATH" "$APP_BUNDLE/Contents/Resources/"
fi

if [[ -f "$ICON_PATH" ]]; then
    cp "$ICON_PATH" "$APP_BUNDLE/Contents/Resources/ThreadKeep.icns"
fi

# Clear Finder metadata/xattrs so ad-hoc signing works reproducibly.
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# Ad-hoc signing keeps the local bundle launchable without introducing a
# Developer ID or notarization requirement at this stage.
codesign --force --sign - "$APP_BUNDLE"

echo
echo "Built release app:"
echo "  $APP_BUNDLE"
