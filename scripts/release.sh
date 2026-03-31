#!/bin/bash
set -e

# Usage: ./scripts/release.sh "1.6" "Short description of changes"
# Or:    ./scripts/release.sh bump "Short description of changes"  (auto-increment minor)

VERSION="$1"
MESSAGE="$2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
cd "$ROOT"

if [ -z "$VERSION" ] || [ -z "$MESSAGE" ]; then
    echo "Usage: $0 <version|bump> \"commit message\""
    echo "  $0 1.6 \"Add retention policies\""
    echo "  $0 bump \"Fix sync engine\""
    exit 1
fi

# Auto-increment if "bump"
if [ "$VERSION" = "bump" ]; then
    CURRENT=$(grep 'AppVersion = ' internal/api/rest/server.go | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
    IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
    PATCH=${PATCH:-0}
    VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
    echo "Auto-bumping: $CURRENT → $VERSION"
fi

DATE=$(date +%Y-%m-%d)

echo "=== Releasing v$VERSION ==="

# 1. Update Go backend version
echo "[1/10] Updating backend version..."
sed -i '' "s/AppVersion = \".*\"/AppVersion = \"$VERSION\"/" internal/api/rest/server.go

# 2. Update macOS app version in AppState.swift
echo "[2/10] Updating app version constant..."
sed -i '' "s/let appVersion = \".*\"/let appVersion = \"$VERSION\"/" macos/Sources/SyncVault/AppState.swift

# 3. Update macOS app Info.plist
echo "[3/10] Updating macOS app Info.plist..."
plutil -replace CFBundleShortVersionString -string "$VERSION" macos/Sources/SyncVault/Info.plist
plutil -replace CFBundleVersion -string "$VERSION" macos/Sources/SyncVault/Info.plist

# 4. Update FileProvider Info.plist
echo "[4/10] Updating FileProvider Info.plist..."
plutil -replace CFBundleShortVersionString -string "$VERSION" macos/FileProvider/Info.plist
plutil -replace CFBundleVersion -string "$VERSION" macos/FileProvider/Info.plist

# 5. Add changelog entry
echo "[5/10] Adding changelog entry..."
CHANGELOG_ENTRY="## [$VERSION] — $DATE\n- $MESSAGE\n"
if [ -f internal/api/rest/changelog.txt ]; then
    echo -e "$CHANGELOG_ENTRY\n$(cat internal/api/rest/changelog.txt)" > internal/api/rest/changelog.txt
else
    echo -e "$CHANGELOG_ENTRY" > internal/api/rest/changelog.txt
fi

# 5b. Build frontend
echo "[5b/10] Building frontend..."
cd web && npm run build 2>&1 | tail -1 && cd ..
rm -rf internal/api/rest/dist && mkdir -p internal/api/rest/dist
cp -r web/build/* internal/api/rest/dist/

# 6. Build, sign, and create macOS app
echo "[6/10] Building macOS app..."
CERT="Developer ID Application: Niel Heesakkers (DE59N86W33)"
ENT_APP="Sources/SyncVault/SyncVault.entitlements"
ENT_FP="FileProvider/FileProvider.entitlements"

cd macos
xcodebuild -scheme SyncVault -configuration Release -derivedDataPath build clean build 2>&1 | tail -3
xcodebuild -scheme SyncVaultFinderSync -configuration Release -derivedDataPath build build 2>&1 | tail -1

APP="build/Build/Products/Release/SyncVault.app"

# Embed FinderSync extension in app bundle
if [ -d "build/Build/Products/Release/SyncVaultFinderSync.appex" ]; then
    cp -R "build/Build/Products/Release/SyncVaultFinderSync.appex" "$APP/Contents/PlugIns/"
    echo "Embedded FinderSync extension"
fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

# Fix Sparkle framework structure (remove unsealed symlinks + resource forks)
echo "Fixing Sparkle framework structure..."
rm -f "$SPARKLE/Autoupdate"
rm -f "$SPARKLE/Updater.app"
rm -f "$SPARKLE/XPCServices"
find "$APP" -name "._*" -delete 2>/dev/null || true

# Re-sign with Developer ID + timestamp + hardened runtime + entitlements
echo "Signing with Developer ID..."
codesign --force --sign "$CERT" --timestamp --options runtime "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign "$CERT" --timestamp --options runtime "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign "$CERT" --timestamp --options runtime "$SPARKLE/Versions/B/Autoupdate"
codesign --force --sign "$CERT" --timestamp --options runtime "$SPARKLE/Versions/B/Updater.app"
codesign --force --sign "$CERT" --timestamp --options runtime "$SPARKLE"
codesign --force --sign "$CERT" --timestamp --options runtime --entitlements "$ENT_FP" "$APP/Contents/PlugIns/SyncVaultFileProvider.appex"
if [ -d "$APP/Contents/PlugIns/SyncVaultFinderSync.appex" ]; then
    codesign --force --sign "$CERT" --timestamp --options runtime --entitlements "FinderSync/FinderSync.entitlements" "$APP/Contents/PlugIns/SyncVaultFinderSync.appex"
fi
codesign --force --sign "$CERT" --timestamp --options runtime --entitlements "$ENT_APP" "$APP"

# Verify signature
codesign --verify --deep --strict "$APP"
echo "Signing OK"

# 7. Create ZIP and notarize
echo "[7/10] Creating and notarizing ZIP..."
rm -f "build/SyncVault-$VERSION.zip"
COPYFILE_DISABLE=1 ditto -c -k --keepParent "$APP" "build/SyncVault-$VERSION.zip"

xcrun notarytool submit "build/SyncVault-$VERSION.zip" \
    --keychain-profile "notarytool" --wait

# Staple the app, strip quarantine, and re-create ZIP with stapled ticket
xcrun stapler staple "$APP"
xattr -cr "$APP"
rm -f "build/SyncVault-$VERSION.zip"
COPYFILE_DISABLE=1 ditto -c -k --keepParent "$APP" "build/SyncVault-$VERSION.zip"

# Install to /Applications
rm -rf /Applications/SyncVault.app
ditto "$APP" /Applications/SyncVault.app
xattr -cr /Applications/SyncVault.app
echo "Installed to /Applications"

# 8. Create and notarize DMG
echo "[8/10] Creating and notarizing DMG..."
rm -f "build/SyncVault-$VERSION.dmg"
hdiutil create -volname "SyncVault" -srcfolder "$APP" -ov -format UDZO "build/SyncVault-$VERSION.dmg" 2>&1

xcrun notarytool submit "build/SyncVault-$VERSION.dmg" \
    --keychain-profile "notarytool" --wait
xcrun stapler staple "build/SyncVault-$VERSION.dmg"

cd ..

# 9. Sign ZIP with EdDSA and update appcast.xml
echo "[9/10] Signing ZIP and updating appcast.xml..."
SIGN_OUTPUT=$(macos/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update "macos/build/SyncVault-$VERSION.zip" 2>&1)
ED_SIG=$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
ZIP_LENGTH=$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
cat > docs/appcast.xml << APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>SyncVault</title>
    <item>
      <title>Version $VERSION</title>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <pubDate>$(date -R)</pubDate>
      <enclosure
        url="https://github.com/NielHeesakkers/SyncVault/releases/download/v$VERSION/SyncVault-$VERSION.zip"
        length="$ZIP_LENGTH"
        type="application/octet-stream"
        sparkle:edSignature="$ED_SIG" />
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
APPCAST

# 10. Update version.json (used by custom updater in the app)
echo "[10/10] Updating version.json..."
python3 -c "
import json
with open('version.json', 'r') as f:
    vj = json.load(f)

vj['version'] = '$VERSION'
vj['release_date'] = '$DATE'
vj['dmg_url'] = 'https://github.com/NielHeesakkers/SyncVault/releases/download/v$VERSION/SyncVault-$VERSION.dmg'

# Add to history
new_entry = {'version': '$VERSION', 'date': '$DATE', 'changes': ['$MESSAGE']}
if not any(h['version'] == '$VERSION' for h in vj.get('history', [])):
    vj.setdefault('history', []).insert(0, new_entry)

with open('version.json', 'w') as f:
    json.dump(vj, f, indent=2)
print('version.json updated to $VERSION')
"

# 11. Auto commit, push, and release
echo "[11/11] Committing, pushing, and creating release..."
git add -A
git commit -m "$(cat <<COMMIT
v$VERSION: $MESSAGE

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
COMMIT
)"
git push origin main

# Create GitHub release with both DMG and ZIP
gh release create "v$VERSION" \
    "macos/build/SyncVault-$VERSION.dmg" \
    "macos/build/SyncVault-$VERSION.zip" \
    --title "SyncVault v$VERSION" \
    --notes "$MESSAGE"

echo ""
echo "=== v$VERSION released! ==="
echo "  GitHub: https://github.com/NielHeesakkers/SyncVault/releases/tag/v$VERSION"
echo "  Docker image building via GitHub Actions..."
