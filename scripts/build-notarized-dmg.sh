#!/bin/zsh
#
# build-notarized-dmg.sh — build the universal release app, sign it with a
# Developer ID identity + hardened runtime, wrap it in a DMG, notarize the DMG
# with Apple, staple the ticket, and verify the result against Gatekeeper.
#
# Usage:
#   ./scripts/build-notarized-dmg.sh                 # full signed + notarized build
#   ./scripts/build-notarized-dmg.sh --dry-run       # ad-hoc build for QA/size (no notarization)
#
# Configuration (env vars):
#   VERSION_LABEL   marketing label used in the DMG filename   (default: 1.0b2)
#   SIGN_IDENTITY   codesign identity                          (default: "Developer ID Application")
#   NOTARY_PROFILE  notarytool keychain profile                (default: threadkeep-notary)
#
# One-time setup on a new machine:
#   1. Xcode → Settings → Accounts → Michael Kushman (QHUS8AZVD4)
#      → Manage Certificates → + → "Developer ID Application"
#   2. xcrun notarytool store-credentials threadkeep-notary \
#        --apple-id <apple-id> --team-id QHUS8AZVD4
#      (prompts for an app-specific password from appleid.apple.com)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH_DIR="${THREADKEEPER_BUILD_CACHE:-$HOME/Library/Caches/ThreadKeepBuild/swiftpm-notarized}"
DIST_DIR="$ROOT_DIR/dist"
PRODUCT_NAME="ThreadKeep"
APP_BUNDLE="$DIST_DIR/$PRODUCT_NAME.app"
PLIST_PATH="$ROOT_DIR/Sources/ThreadKeep/Support/ThreadKeepInfo.plist"
ICON_PATH="$ROOT_DIR/Sources/ThreadKeep/Support/ThreadKeep.icns"

VERSION_LABEL="${VERSION_LABEL:-1.0b2}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-threadkeep-notary}"
DMG_PATH="$DIST_DIR/$PRODUCT_NAME-$VERSION_LABEL.dmg"

# Sparkle compares CFBundleVersion to decide whether an update exists, so every
# release MUST ship a strictly higher value. Bump BOTH:
#   - CFBundleVersion in Sources/ThreadKeep/Support/ThreadKeepInfo.plist
#   - LAST_SHIPPED_BUNDLE_VERSION below (to the value you just shipped, after release)
LAST_SHIPPED_BUNDLE_VERSION="${LAST_SHIPPED_BUNDLE_VERSION:-5}"   # 1.0b5 shipped as CFBundleVersion 5
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST_PATH")"
if [[ "${1:-}" != "--dry-run" ]] && [[ "$BUNDLE_VERSION" -le "$LAST_SHIPPED_BUNDLE_VERSION" ]]; then
    echo "CFBundleVersion is $BUNDLE_VERSION but $LAST_SHIPPED_BUNDLE_VERSION already shipped." >&2
    echo "Sparkle will never offer this build as an update. Bump CFBundleVersion in" >&2
    echo "Sources/ThreadKeep/Support/ThreadKeepInfo.plist before releasing." >&2
    echo "(Override for rebuilds of the shipped version: LAST_SHIPPED_BUNDLE_VERSION=$((BUNDLE_VERSION - 1)))" >&2
    exit 1
fi

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    # Never clobber a shipped, notarized artifact with an unsigned QA build.
    DMG_PATH="$DIST_DIR/$PRODUCT_NAME-$VERSION_LABEL-dryrun.dmg"
fi

cd "$ROOT_DIR"

echo "==> Building universal $PRODUCT_NAME (release, arm64 + x86_64)"
rm -rf "$SCRATCH_DIR"
mkdir -p "$(dirname "$SCRATCH_DIR")" "$DIST_DIR"
swift build --scratch-path "$SCRATCH_DIR" -c release \
    --arch arm64 --arch x86_64 \
    --product "$PRODUCT_NAME"

EXECUTABLE_PATH="$(find "$SCRATCH_DIR" -path "*/apple/Products/Release/$PRODUCT_NAME" -type f | head -n 1)"
if [[ -z "$EXECUTABLE_PATH" ]]; then
    EXECUTABLE_PATH="$(find "$SCRATCH_DIR" -path "*elease*/$PRODUCT_NAME" -type f | head -n 1)"
fi
RESOURCE_BUNDLE_PATH="$(find "$SCRATCH_DIR" -type d -name "${PRODUCT_NAME}_${PRODUCT_NAME}.bundle" | grep -i release | head -n 1)"

if [[ -z "$EXECUTABLE_PATH" || ! -x "$EXECUTABLE_PATH" ]]; then
    echo "Missing release executable under $SCRATCH_DIR" >&2
    exit 1
fi
lipo -info "$EXECUTABLE_PATH"

echo "==> Assembling $PRODUCT_NAME.app"
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

echo "==> Embedding Sparkle.framework"
SPARKLE_FRAMEWORK="$(find "$SCRATCH_DIR/artifacts" -type d -name "Sparkle.framework" -path "*macos*" | head -n 1)"
if [[ -z "$SPARKLE_FRAMEWORK" || ! -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "Missing Sparkle.framework under $SCRATCH_DIR/artifacts (SwiftPM binary artifact)" >&2
    exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
# -R preserves the framework's internal symlink structure (Versions/B layout).
cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
EMBEDDED_SPARKLE="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# Sparkle ships nested executable code (XPC services, Autoupdate, Updater.app)
# that must each be signed inside-out with the SAME identity as the app, per
# https://sparkle-project.org/documentation/sandboxing/#code-signing — no
# --deep, and Downloader.xpc keeps its entitlements. Notarization fails if any
# nested item is unsigned or lacks the hardened runtime.
sign_sparkle_nested() {
    local -a sign_args=("$@")
    codesign "${sign_args[@]}" "$EMBEDDED_SPARKLE/Versions/B/XPCServices/Installer.xpc"
    codesign "${sign_args[@]}" --preserve-metadata=entitlements "$EMBEDDED_SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    codesign "${sign_args[@]}" "$EMBEDDED_SPARKLE/Versions/B/Autoupdate"
    codesign "${sign_args[@]}" "$EMBEDDED_SPARKLE/Versions/B/Updater.app"
    codesign "${sign_args[@]}" "$EMBEDDED_SPARKLE"
}

if [[ $DRY_RUN -eq 1 ]]; then
    echo "==> [dry run] Ad-hoc signing (no hardened runtime, no notarization)"
    sign_sparkle_nested --force --sign -
    codesign --force --sign - "$APP_BUNDLE"
    codesign --verify --deep --strict "$APP_BUNDLE"
else
    echo "==> Signing with '$SIGN_IDENTITY' (hardened runtime + secure timestamp)"
    sign_sparkle_nested --force --timestamp --options runtime --sign "$SIGN_IDENTITY"
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
    codesign --verify --deep --strict "$APP_BUNDLE"
fi

echo "==> Creating DMG"
DMG_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/threadkeep-dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGE_DIR"' EXIT
cp -R "$APP_BUNDLE" "$DMG_STAGE_DIR/"
ln -s /Applications "$DMG_STAGE_DIR/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$PRODUCT_NAME" -srcfolder "$DMG_STAGE_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null

if [[ $DRY_RUN -eq 1 ]]; then
    echo
    echo "[dry run] Built unsigned QA DMG:"
    ls -la "$DMG_PATH"
    exit 0
fi

echo "==> Signing DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

echo "==> Submitting to Apple notary service (waits for verdict)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling ticket to DMG"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "==> Gatekeeper verification"
VERIFY_MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/threadkeep-verify.XXXXXX")"
hdiutil attach -nobrowse -readonly -mountpoint "$VERIFY_MOUNT" "$DMG_PATH" >/dev/null
spctl -a -vv "$VERIFY_MOUNT/$PRODUCT_NAME.app"
hdiutil detach "$VERIFY_MOUNT" >/dev/null
rmdir "$VERIFY_MOUNT" 2>/dev/null || true

echo
echo "Notarized DMG ready:"
ls -la "$DMG_PATH"

SIGN_UPDATE="$(find "$SCRATCH_DIR/artifacts" -type f -name "sign_update" -perm +111 2>/dev/null | head -n 1)"
echo
echo "Sparkle release steps (this machine holds the EdDSA key — see docs/CERT-MACHINE-SPARKLE-SETUP.md):"
echo "  1. Sign the update:  ${SIGN_UPDATE:-<scratch>/artifacts/**/bin/sign_update} '$DMG_PATH'"
echo "  2. Copy the printed sparkle:edSignature + length into a new <item> in the"
echo "     threadkeep-xyz repo's appcast.xml (template: docs/appcast-item-template.xml)."
echo "  3. Commit DMG + appcast.xml together and push main to deploy."
echo "  4. After release: bump LAST_SHIPPED_BUNDLE_VERSION in this script to $BUNDLE_VERSION."
