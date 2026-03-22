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
    CURRENT=$(grep 'AppVersion = ' internal/api/rest/server.go | grep -oE '[0-9]+\.[0-9]+')
    MAJOR=$(echo "$CURRENT" | cut -d. -f1)
    MINOR=$(echo "$CURRENT" | cut -d. -f2)
    VERSION="$MAJOR.$((MINOR + 1))"
    echo "Auto-bumping: $CURRENT → $VERSION"
fi

DATE=$(date +%Y-%m-%d)

echo "=== Releasing v$VERSION ==="

# 1. Update Go backend version
echo "[1/7] Updating backend version..."
sed -i '' "s/AppVersion = \".*\"/AppVersion = \"$VERSION\"/" internal/api/rest/server.go

# 2. Update macOS app Info.plist
echo "[2/7] Updating macOS app version..."
sed -i '' "s/<string>[0-9]*\.[0-9]*<\/string><!--APP_VERSION-->/<string>$VERSION<\/string><!--APP_VERSION-->/" macos/Sources/SyncVault/Info.plist 2>/dev/null || \
plutil -replace CFBundleShortVersionString -string "$VERSION" macos/Sources/SyncVault/Info.plist
plutil -replace CFBundleVersion -string "$VERSION" macos/Sources/SyncVault/Info.plist

# 3. Update FileProvider Info.plist
echo "[3/7] Updating FileProvider version..."
plutil -replace CFBundleShortVersionString -string "$VERSION" macos/FileProvider/Info.plist
plutil -replace CFBundleVersion -string "$VERSION" macos/FileProvider/Info.plist

# 4. Add changelog entry
echo "[4/7] Adding changelog entry..."
CHANGELOG_ENTRY="## [$VERSION] — $DATE\n- $MESSAGE\n"
if [ -f internal/api/rest/changelog.txt ]; then
    echo -e "$CHANGELOG_ENTRY\n$(cat internal/api/rest/changelog.txt)" > internal/api/rest/changelog.txt
else
    echo -e "$CHANGELOG_ENTRY" > internal/api/rest/changelog.txt
fi

# 5. Build frontend
echo "[5/7] Building frontend..."
cd web && npm run build 2>&1 | tail -1 && cd ..
rm -rf internal/api/rest/dist && mkdir -p internal/api/rest/dist
cp -r web/build/* internal/api/rest/dist/

# 6. Build and create macOS DMG
echo "[6/7] Building macOS app..."
cd macos
xcodebuild -scheme SyncVault -configuration Release -derivedDataPath build \
    -arch arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=DE59N86W33 CODE_SIGN_STYLE=Manual 2>&1 | grep -E "(BUILD|error:)" | head -5

rm -f "build/SyncVault-$VERSION.dmg"
mkdir -p build/dmg-staging
cp -R build/Build/Products/Release/SyncVault.app build/dmg-staging/
ln -sf /Applications build/dmg-staging/Applications
hdiutil create -volname "SyncVault" -srcfolder build/dmg-staging -ov -format UDZO "build/SyncVault-$VERSION.dmg" 2>&1
rm -rf build/dmg-staging

# Create ZIP for Sparkle
rm -f "build/SyncVault-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent build/Build/Products/Release/SyncVault.app "build/SyncVault-$VERSION.zip"
cd ..

# 7. Update appcast.xml for Sparkle auto-update
echo "[7/7] Updating appcast.xml..."
ZIP_SIZE=$(stat -f%z "macos/build/SyncVault-$VERSION.zip")
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
        length="$ZIP_SIZE"
        type="application/octet-stream"
        sparkle:edSignature="" />
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
APPCAST

echo ""
echo "=== v$VERSION ready! ==="
echo ""
echo "Next steps:"
echo "  git add -A && git commit -m \"v$VERSION: $MESSAGE\""
echo "  git push origin main"
echo "  gh release create v$VERSION macos/build/SyncVault-$VERSION.dmg macos/build/SyncVault-$VERSION.zip --title \"SyncVault v$VERSION\" --notes \"$MESSAGE\""
