#!/bin/bash
set -e

# SpliceKit Release Script — fully automated
# Usage: ./release.sh <version> "<release notes>"
# Example: ./release.sh 3.0.0 "New feature X, fix Y"

VERSION="$1"
NOTES="$2"
REPO_ROOT="$(pwd)"
if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <version> [\"release notes\"]"
    echo "Example: ./release.sh 3.0.0 \"Wizard UI, DMG distribution\""
    exit 1
fi
if [ -z "$NOTES" ]; then
    NOTES="Bug fixes and improvements"
fi

SIGN_ID="Developer ID Application: Brian Tate (RH4U5VJHM6)"
KEYCHAIN_PROFILE="FCPBridge"  # legacy name; change to "SpliceKit" after: xcrun notarytool store-credentials "SpliceKit"
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

echo "[1/14] Bumping version to ${VERSION}..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "patcher/SpliceKit/Resources/Info.plist"
sed -i '' "s/MARKETING_VERSION = \"[^\"]*\"/MARKETING_VERSION = \"${VERSION}\"/g" "${XCODE_PROJECT}/project.pbxproj"
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = ${VERSION}/g" "${XCODE_PROJECT}/project.pbxproj"

echo "[2/14] Building SpliceKit dylib + tools..."
make clean && make && make tools

echo "[3/14] Building parakeet-transcriber..."
PARAKEET_PKG_DIR="patcher/SpliceKitPatcher.app/Contents/Resources/tools/parakeet-transcriber"
cd "${PARAKEET_PKG_DIR}" && swift build -c release 2>&1 | tail -3 && cd "${REPO_ROOT}"
PARAKEET_BIN="${PARAKEET_PKG_DIR}/.build/release/parakeet-transcriber"
if [ -f "$PARAKEET_BIN" ]; then
    echo "  Built: $(du -h "$PARAKEET_BIN" | cut -f1)"
else
    echo "  WARNING: parakeet-transcriber build failed — release will not include it"
fi

echo "[4/14] Building SpliceKit app via Xcode..."
xcodebuild -project "${XCODE_PROJECT}" \
    -scheme SpliceKit \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    ONLY_ACTIVE_ARCH=NO \
    clean build

echo "[5/14] Syncing bundled resources into app..."
APP_RES="${BUILT_APP}/Contents/Resources"
mkdir -p "${APP_RES}/Sources"
mkdir -p "${APP_RES}/mcp"
mkdir -p "${APP_RES}/tools"
cp build/SpliceKit "${APP_RES}/SpliceKit"
cp build/silence-detector "${APP_RES}/tools/silence-detector"
cp mcp/server.py "${APP_RES}/mcp/server.py"
rsync -a --delete Sources/ "${APP_RES}/Sources/"
# Bundle Lua vendor sources (for from-source builds)
if [ -d "vendor/lua-5.4.7" ]; then
    mkdir -p "${APP_RES}/vendor/lua-5.4.7/src"
    rsync -a vendor/lua-5.4.7/src/ "${APP_RES}/vendor/lua-5.4.7/src/"
    echo "  Bundled vendor/lua-5.4.7/"
fi
# Bundle Lua scripts
if [ -d "Scripts/lua" ]; then
    mkdir -p "${APP_RES}/Scripts/lua"
    rsync -a --delete Scripts/lua/ "${APP_RES}/Scripts/lua/"
    echo "  Bundled Scripts/lua/"
fi
# Bundle pre-built parakeet binary (no source build needed on user's machine)
if [ -f "$PARAKEET_BIN" ]; then
    cp "$PARAKEET_BIN" "${APP_RES}/tools/parakeet-transcriber"
    echo "  Bundled parakeet-transcriber binary"
fi

# ──────────────────────────────────────────────
# SIGN
# ──────────────────────────────────────────────

echo "[6/14] Signing embedded binaries (inner-to-outer)..."
SPARKLE_FW="${BUILT_APP}/Contents/Frameworks/Sparkle.framework"

# Sign Sparkle XPC services first (innermost)
for xpc in "${SPARKLE_FW}/Versions/B/XPCServices/"*.xpc; do
    if [ -d "$xpc" ]; then
        codesign --force --options runtime --timestamp --sign "${SIGN_ID}" "$xpc"
        echo "  Signed: $(basename "$xpc")"
    fi
done

# Sign Sparkle Updater.app
if [ -d "${SPARKLE_FW}/Versions/B/Updater.app" ]; then
    codesign --force --options runtime --timestamp --sign "${SIGN_ID}" "${SPARKLE_FW}/Versions/B/Updater.app"
    echo "  Signed: Updater.app"
fi

# Sign Sparkle Autoupdate helper
if [ -f "${SPARKLE_FW}/Versions/B/Autoupdate" ]; then
    codesign --force --options runtime --timestamp --sign "${SIGN_ID}" "${SPARKLE_FW}/Versions/B/Autoupdate"
    echo "  Signed: Autoupdate"
fi

# Sign Sparkle framework
codesign --force --options runtime --timestamp --sign "${SIGN_ID}" "${SPARKLE_FW}"
echo "  Signed: Sparkle.framework"

# Sign all Mach-O binaries in Resources (dylib, tools)
find "${BUILT_APP}/Contents/Resources" -type f | while read f; do
    if file -b "$f" 2>/dev/null | grep -q "Mach-O"; then
        codesign --force --options runtime --timestamp --sign "${SIGN_ID}" "$f"
        echo "  Signed: $(basename "$f")"
    fi
done

echo "[7/14] Signing app bundle..."
codesign --force --options runtime --timestamp --sign "${SIGN_ID}" "${BUILT_APP}"
codesign --verify --deep --strict "${BUILT_APP}"
echo "  Verification passed"

# ──────────────────────────────────────────────
# CREATE DMG
# ──────────────────────────────────────────────

echo "[8/14] Creating DMG..."
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

echo "[9/14] Submitting DMG for notarization (this may take a few minutes)..."
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${KEYCHAIN_PROFILE}" --wait

echo "[10/14] Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"
echo "  Stapled: ${DMG_PATH}"

# ──────────────────────────────────────────────
# SPARKLE APPCAST
# ──────────────────────────────────────────────

echo "[11/14] Generating Sparkle EdDSA signature..."
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

echo "[12/14] Updating appcast.xml..."
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
        url=\"https://github.com/elliotttate/SpliceKit/releases/download/v${VERSION}/${DMG_NAME}\"
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

echo "[13/14] Committing and pushing..."
git add -A
git commit -m "Release v${VERSION}: ${NOTES}"
git push origin main

echo "[14/14] Creating GitHub release..."
gh release create "v${VERSION}" "${DMG_PATH}" \
    --title "v${VERSION}" \
    --notes "${NOTES}" \
    2>/dev/null && RELEASE_URL=$(gh release view "v${VERSION}" --json url -q '.url') || RELEASE_URL="(check GitHub)"

echo ""
echo "========================================="
echo "  Release v${VERSION} complete!"
echo "  ${RELEASE_URL}"
echo "========================================="
echo ""
echo "  - Built via Xcode, signed, notarized, stapled"
echo "  - DMG: ${DMG_PATH}"
echo "  - Appcast updated with EdDSA signature"
echo "  - Pushed to main, GitHub release created"
echo "  - Sparkle will auto-notify users"
echo ""
