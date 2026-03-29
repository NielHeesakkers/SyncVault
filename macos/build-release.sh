#!/bin/bash
set -e

# SyncVault macOS Release Build Script
# Usage: ./build-release.sh

CERT="Developer ID Application: Niel Heesakkers (DE59N86W33)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build/Build/Products/Release"
APP="$BUILD_DIR/SyncVault.app"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ENT_APP="$SCRIPT_DIR/Sources/SyncVault/SyncVault.entitlements"
ENT_FP="$SCRIPT_DIR/FileProvider/FileProvider.entitlements"
SIGN_UPDATE="$SCRIPT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"

VERSION=$(defaults read "$SCRIPT_DIR/Sources/SyncVault/Info.plist" CFBundleShortVersionString)

echo "=== Building SyncVault v$VERSION ==="

# 1. Clean build
echo "→ Building..."
cd "$SCRIPT_DIR"
xcodebuild -scheme SyncVault -configuration Release -derivedDataPath build clean build 2>&1 | tail -3

# 2. Fix Sparkle framework structure (remove unsealed symlinks + resource forks)
echo "→ Fixing Sparkle framework structure..."
rm -f "$SPARKLE/Autoupdate"
rm -f "$SPARKLE/Updater.app"
rm -f "$SPARKLE/XPCServices"
# Remove ALL ._ resource fork files (Finder creates these, they break code signing)
find "$APP" -name "._*" -delete 2>/dev/null || true

# 3. Re-sign with Developer ID + timestamp + hardened runtime
echo "→ Signing with Developer ID..."
codesign --force --sign "$CERT" --timestamp --options runtime "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign "$CERT" --timestamp --options runtime "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign "$CERT" --timestamp --options runtime "$SPARKLE/Versions/B/Autoupdate"
codesign --force --sign "$CERT" --timestamp --options runtime "$SPARKLE/Versions/B/Updater.app"
codesign --force --sign "$CERT" --timestamp --options runtime "$SPARKLE"
codesign --force --sign "$CERT" --timestamp --options runtime --entitlements "$ENT_FP" "$APP/Contents/PlugIns/SyncVaultFileProvider.appex"
codesign --force --sign "$CERT" --timestamp --options runtime --entitlements "$ENT_APP" "$APP"

# 4. Verify
echo "→ Verifying..."
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose "$APP" 2>&1

# 5. Create ZIP with ditto (COPYFILE_DISABLE prevents ._ resource forks in zip)
echo "→ Creating ZIP..."
rm -f /tmp/SyncVault-$VERSION.zip
COPYFILE_DISABLE=1 ditto -c -k --keepParent "$APP" /tmp/SyncVault-$VERSION.zip

# 6. Notarize
echo "→ Notarizing ZIP..."
xcrun notarytool submit /tmp/SyncVault-$VERSION.zip --keychain-profile "notarytool" --wait

# 7. Staple and re-zip
echo "→ Stapling..."
xcrun stapler staple "$APP"
rm -f /tmp/SyncVault-$VERSION.zip
COPYFILE_DISABLE=1 ditto -c -k --keepParent "$APP" /tmp/SyncVault-$VERSION.zip
cp /tmp/SyncVault-$VERSION.zip "$SCRIPT_DIR/SyncVault-$VERSION.zip"

# 8. Create and notarize DMG
echo "→ Creating DMG..."
rm -f /tmp/SyncVault-$VERSION.dmg
hdiutil create -volname "SyncVault" -srcfolder "$APP" -ov -format UDZO /tmp/SyncVault-$VERSION.dmg
echo "→ Notarizing DMG..."
xcrun notarytool submit /tmp/SyncVault-$VERSION.dmg --keychain-profile "notarytool" --wait
xcrun stapler staple /tmp/SyncVault-$VERSION.dmg
cp /tmp/SyncVault-$VERSION.dmg "$SCRIPT_DIR/SyncVault-$VERSION.dmg"

# 9. Sparkle signature
echo "→ Sparkle signature:"
"$SIGN_UPDATE" /tmp/SyncVault-$VERSION.zip

echo ""
echo "=== Done! ==="
echo "ZIP: $SCRIPT_DIR/SyncVault-$VERSION.zip"
echo "DMG: $SCRIPT_DIR/SyncVault-$VERSION.dmg"
echo "Update appcast.xml with the signature above, then commit and push."
