#!/bin/bash
set -e

# SpliceKit Release Script — fully automated
# Usage: ./release.sh <version> "<release notes>"
# Example: ./release.sh 3.0.0 "New feature X, fix Y"

VERSION="$1"
NOTES="$2"
if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <version> [\"release notes\"]"
    echo "Example: ./release.sh 3.0.0 \"Wizard UI, DMG distribution\""
    exit 1
fi
if [ -z "$NOTES" ]; then
    NOTES="Bug fixes and improvements"
fi

SIGN_ID="Developer ID Application: Brian Tate (RH4U5VJHM6)"
KEYCHAIN_PROFILE="SpliceKit"
XCODE_PROJECT="patcher/SpliceKit.xcodeproj"
BUILD_DIR="patcher/build"
BUILT_APP="${BUILD_DIR}/Build/Products/Release/SpliceKit.app"
DMG_NAME="SpliceKit-v${VERSION}.dmg"
DMG_PATH="patcher/${DMG_NAME}"
SPARKLE_SIGN="/tmp/bin/sign_update"

echo "=== SpliceKit Release v${VERSION} ==="
echo ""

# ──────────────────────────────────────────────
# BUILD
# ──────────────────────────────────────────────

echo "[1/13] Bumping version to ${VERSION}..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "patcher/SpliceKit/Info.plist"
# Also update the Xcode project build settings
sed -i '' "s/MARKETING_VERSION = \"[^\"]*\"/MARKETING_VERSION = \"${VERSION}\"/g" "${XCODE_PROJECT}/project.pbxproj"
sed -i '' "s/CURRENT_PROJECT_VERSION = \"[^\"]*\"/CURRENT_PROJECT_VERSION = \"${VERSION}\"/g" "${XCODE_PROJECT}/project.pbxproj"

echo "[2/13] Building SpliceKit dylib..."
make clean && make

echo "[3/13] Building SpliceKit app via Xcode..."
xcodebuild -project "${XCODE_PROJECT}" \
    -scheme SpliceKit \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    ONLY_ACTIVE_ARCH=NO \
    clean build

echo "[4/13] Syncing bundled resources into app..."
mkdir -p "${BUILT_APP}/Contents/Resources/Sources"
mkdir -p "${BUILT_APP}/Contents/Resources/mcp"
mkdir -p "${BUILT_APP}/Contents/Resources/tools/parakeet-transcriber"
cp build/SpliceKit "${BUILT_APP}/Contents/Resources/SpliceKit"
cp mcp/server.py "${BUILT_APP}/Contents/Resources/mcp/server.py"
cp tools/silence-detector.swift "${BUILT_APP}/Contents/Resources/tools/silence-detector.swift"
rsync -a --delete Sources/ "${BUILT_APP}/Contents/Resources/Sources/"
rsync -a --delete \
    --exclude '.build' \
    --exclude '.swiftpm' \
    tools/parakeet-transcriber/ "${BUILT_APP}/Contents/Resources/tools/parakeet-transcriber/"

# ──────────────────────────────────────────────
# SIGN
# ──────────────────────────────────────────────

echo "[5/13] Signing embedded binaries..."
find "${BUILT_APP}/Contents/Resources" -type f | while read f; do
    if file -b "$f" 2>/dev/null | grep -q "Mach-O"; then
        codesign --force --options runtime --timestamp --sign "${SIGN_ID}" "$f"
        echo "  Signed: $(basename "$f")"
    fi
done

echo "[6/13] Signing app bundle..."
codesign --force --deep --options runtime --timestamp --sign "${SIGN_ID}" "${BUILT_APP}"
codesign --verify --deep --strict "${BUILT_APP}"
echo "  Verification passed"

# ──────────────────────────────────────────────
# CREATE DMG
# ──────────────────────────────────────────────

echo "[7/13] Creating DMG..."
DMG_TEMP="${BUILD_DIR}/dmg_staging"
rm -rf "${DMG_TEMP}" "${DMG_PATH}"
mkdir -p "${DMG_TEMP}"
cp -R "${BUILT_APP}" "${DMG_TEMP}/"
ln -s /Applications "${DMG_TEMP}/Applications"

hdiutil create -volname "SpliceKit" \
    -srcfolder "${DMG_TEMP}" \
    -ov -format UDZO \
    "${DMG_PATH}"
rm -rf "${DMG_TEMP}"
echo "  DMG: ${DMG_PATH} ($(du -h "${DMG_PATH}" | cut -f1))"

# ──────────────────────────────────────────────
# NOTARIZE
# ──────────────────────────────────────────────

echo "[8/13] Submitting DMG for notarization (this may take a few minutes)..."
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${KEYCHAIN_PROFILE}" --wait

echo "[9/13] Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"
echo "  Stapled: ${DMG_PATH}"

# ──────────────────────────────────────────────
# SPARKLE APPCAST
# ──────────────────────────────────────────────

echo "[10/13] Generating Sparkle EdDSA signature..."
if [ ! -f "${SPARKLE_SIGN}" ]; then
    echo "  Downloading Sparkle tools..."
    SPARKLE_URL=$(curl -s https://api.github.com/repos/sparkle-project/Sparkle/releases/latest | python3 -c "import sys,json; [print(a['browser_download_url']) for a in json.loads(sys.stdin.read())['assets'] if a['name'].endswith('.tar.xz')]")
    curl -sL "${SPARKLE_URL}" -o /tmp/sparkle.tar.xz
    cd /tmp && tar xf sparkle.tar.xz && cd -
fi
SPARKLE_SIG=$("${SPARKLE_SIGN}" "${DMG_PATH}" | grep -o 'edSignature="[^"]*"' | sed 's/edSignature="//;s/"//')
FILE_SIZE=$(stat -f%z "${DMG_PATH}")
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
echo "  Signature: ${SPARKLE_SIG}"

echo "[11/13] Updating appcast.xml..."
# Build the new item XML
NEW_ITEM="    <item>
      <title>SpliceKit v${VERSION}</title>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>${PUB_DATE}</pubDate>
      <description><![CDATA[
        <h2>What's New in ${VERSION}</h2>
        <p>${NOTES}</p>
      ]]></description>
      <enclosure
        url=\"https://github.com/elliotttate/FCPBridge/releases/download/v${VERSION}/${DMG_NAME}\"
        sparkle:edSignature=\"${SPARKLE_SIG}\"
        length=\"${FILE_SIZE}\"
        type=\"application/octet-stream\" />
    </item>"

# Insert after <language>en</language>
python3 -c "
import sys
with open('appcast.xml', 'r') as f:
    content = f.read()
marker = '<language>en</language>'
idx = content.find(marker)
if idx == -1:
    print('ERROR: Could not find marker in appcast.xml', file=sys.stderr)
    sys.exit(1)
insert_pos = idx + len(marker)
new_content = content[:insert_pos] + '\n' + '''${NEW_ITEM}''' + content[insert_pos:]
with open('appcast.xml', 'w') as f:
    f.write(new_content)
print('  Appcast updated')
"

# ──────────────────────────────────────────────
# GIT + GITHUB RELEASE
# ──────────────────────────────────────────────

echo "[12/13] Committing and pushing..."
git add -A
git commit -m "Release v${VERSION}: ${NOTES}"
git push origin main

echo "[13/13] Creating GitHub release..."
gh release create "v${VERSION}" "${DMG_PATH}" \
    --title "v${VERSION}" \
    --notes "${NOTES}" \
    2>/dev/null && RELEASE_URL=$(gh release view "v${VERSION}" --json url -q '.url') || RELEASE_URL="(check GitHub)"

echo ""
echo "========================================="
echo "  SpliceKit v${VERSION} released!"
echo "  ${RELEASE_URL}"
echo "========================================="
echo ""
echo "  - Built via Xcode, signed, notarized, stapled"
echo "  - DMG created with drag-to-Applications"
echo "  - Appcast updated with EdDSA signature"
echo "  - Pushed to main, GitHub release created"
echo "  - Sparkle will auto-notify users"
echo ""
