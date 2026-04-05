#!/bin/bash
set -e

# SpliceKit Release Script — fully automated
# Usage: ./release.sh <version> "<release notes>"
# Example: ./release.sh 2.8.0 "New feature X, fix Y"

VERSION="$1"
NOTES="$2"
if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <version> [\"release notes\"]"
    echo "Example: ./release.sh 2.8.0 \"Batch export improvements, bug fixes\""
    exit 1
fi
if [ -z "$NOTES" ]; then
    NOTES="Bug fixes and improvements"
fi

SIGN_ID="Developer ID Application: Brian Tate (RH4U5VJHM6)"
KEYCHAIN_PROFILE="SpliceKit"
PATCHER_APP="patcher/SpliceKitPatcher.app"
ZIP_NAME="SpliceKitPatcher-v${VERSION}.zip"
ZIP_PATH="patcher/${ZIP_NAME}"
SPARKLE_SIGN="/tmp/bin/sign_update"

echo "=== SpliceKit Release v${VERSION} ==="
echo ""

# ──────────────────────────────────────────────
# BUILD
# ──────────────────────────────────────────────

echo "[1/12] Bumping version to ${VERSION}..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${PATCHER_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${PATCHER_APP}/Contents/Info.plist"

echo "[2/12] Building SpliceKit dylib..."
make clean && make

echo "[3/12] Syncing patcher resources and rebuilding patcher..."
cp build/SpliceKit "${PATCHER_APP}/Contents/Resources/SpliceKit"
cp mcp/server.py "${PATCHER_APP}/Contents/Resources/mcp/server.py"
cp tools/silence-detector.swift "${PATCHER_APP}/Contents/Resources/tools/silence-detector.swift"
rsync -a --delete Sources/ "${PATCHER_APP}/Contents/Resources/Sources/"
rsync -a --delete \
    --exclude '.build' \
    --exclude '.swiftpm' \
    tools/parakeet-transcriber/ "${PATCHER_APP}/Contents/Resources/tools/parakeet-transcriber/"
xcrun swiftc -parse-as-library -O \
    -target arm64-apple-macos14.0 -target x86_64-apple-macos14.0 \
    -F "${PATCHER_APP}/Contents/Frameworks" \
    -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "${PATCHER_APP}/Contents/MacOS/SpliceKitPatcher" \
    patcher/SpliceKitPatcher/main.swift

# ──────────────────────────────────────────────
# SIGN
# ──────────────────────────────────────────────

echo "[4/12] Signing embedded binaries..."
find "${PATCHER_APP}/Contents/Resources" -type f | while read f; do
    if file -b "$f" 2>/dev/null | grep -q "Mach-O"; then
        codesign --force --options runtime --timestamp --sign "${SIGN_ID}" "$f"
        echo "  Signed: $(basename "$f")"
    fi
done

echo "[5/12] Signing app bundle..."
codesign --force --deep --options runtime --timestamp --sign "${SIGN_ID}" "${PATCHER_APP}"
codesign --verify --deep --strict "${PATCHER_APP}"
echo "  Verification passed"

# ──────────────────────────────────────────────
# NOTARIZE
# ──────────────────────────────────────────────

echo "[6/12] Creating zip..."
rm -f "${ZIP_PATH}"
cd patcher && ditto -c -k --keepParent SpliceKitPatcher.app "${ZIP_NAME}" && cd ..

echo "[7/12] Submitting for notarization (this may take a few minutes)..."
xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${KEYCHAIN_PROFILE}" --wait

echo "[8/12] Stapling notarization ticket..."
xcrun stapler staple "${PATCHER_APP}"
rm -f "${ZIP_PATH}"
cd patcher && ditto -c -k --keepParent SpliceKitPatcher.app "${ZIP_NAME}" && cd ..
echo "  Final zip: ${ZIP_PATH} ($(du -h "${ZIP_PATH}" | cut -f1))"

# ──────────────────────────────────────────────
# SPARKLE APPCAST
# ──────────────────────────────────────────────

echo "[9/12] Generating Sparkle EdDSA signature..."
if [ ! -f "${SPARKLE_SIGN}" ]; then
    echo "  Downloading Sparkle tools..."
    SPARKLE_URL=$(curl -s https://api.github.com/repos/sparkle-project/Sparkle/releases/latest | python3 -c "import sys,json; [print(a['browser_download_url']) for a in json.loads(sys.stdin.read())['assets'] if a['name'].endswith('.tar.xz')]")
    curl -sL "${SPARKLE_URL}" -o /tmp/sparkle.tar.xz
    cd /tmp && tar xf sparkle.tar.xz && cd -
fi
SPARKLE_SIG=$("${SPARKLE_SIGN}" "${ZIP_PATH}" | grep -o 'edSignature="[^"]*"' | sed 's/edSignature="//;s/"//')
FILE_SIZE=$(stat -f%z "${ZIP_PATH}")
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
echo "  Signature: ${SPARKLE_SIG}"

echo "[10/12] Updating appcast.xml..."
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
        url=\"https://github.com/elliotttate/SpliceKit/releases/download/v${VERSION}/${ZIP_NAME}\"
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

echo "[11/12] Committing and pushing..."
git add -A
git commit -m "Release v${VERSION}: ${NOTES}"
git push origin main

echo "[12/12] Creating GitHub release..."
gh release create "v${VERSION}" "${ZIP_PATH}" \
    --title "v${VERSION}" \
    --notes "${NOTES}" \
    2>/dev/null && RELEASE_URL=$(gh release view "v${VERSION}" --json url -q '.url') || RELEASE_URL="(check GitHub)"

echo ""
echo "========================================="
echo "  Release v${VERSION} complete!"
echo "  ${RELEASE_URL}"
echo "========================================="
echo ""
echo "  - Built, signed, notarized, stapled"
echo "  - Appcast updated with EdDSA signature"
echo "  - Pushed to main, GitHub release created"
echo "  - Sparkle will auto-notify users"
echo ""
