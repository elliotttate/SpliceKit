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
KEYCHAIN_PROFILE="SpliceKit"
XCODE_PROJECT="patcher/SpliceKit.xcodeproj"
VERSION_FILE="patcher/SpliceKit/Configuration/Version.xcconfig"
BUILD_DIR="patcher/build"
BUILT_APP="${BUILD_DIR}/Build/Products/Release/SpliceKit.app"
PATCHER_DSYM="${BUILD_DIR}/Build/Products/Release/SpliceKit.app.dSYM"
RUNTIME_DSYM="build/SpliceKit.dSYM"
DMG_NAME="SpliceKit-v${VERSION}.dmg"
DMG_PATH="patcher/${DMG_NAME}"
SPARKLE_SIGN="/tmp/bin/sign_update"
SENTRY_RELEASE_NAME="splicekit@${VERSION}"
SENTRY_PATCHER_PROJECT="${SENTRY_PATCHER_PROJECT:-splicekit-patcher}"
SENTRY_RUNTIME_PROJECT="${SENTRY_RUNTIME_PROJECT:-splicekit-fcp-runtime}"
CURRENT_BRANCH="$(git branch --show-current)"
PUSH_REMOTE="$(git config --get branch.${CURRENT_BRANCH}.remote || echo origin)"
PUSH_BRANCH="$(git config --get branch.${CURRENT_BRANCH}.merge | sed 's#refs/heads/##')"
if [ -z "${PUSH_BRANCH}" ]; then
    PUSH_BRANCH="${CURRENT_BRANCH}"
fi
REMOTE_URL="$(git remote get-url "${PUSH_REMOTE}")"
RELEASE_REPO="$(printf '%s' "${REMOTE_URL}" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
TAG_NAME="v${VERSION}"

if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo "ERROR: Working tree is dirty. Commit, stash, or remove local changes before releasing." >&2
    git status --short >&2
    exit 1
fi

echo "[0/15] Checking notarization profile..."
NOTARY_PREFLIGHT_LOG="$(mktemp)"
if ! xcrun notarytool history --keychain-profile "${KEYCHAIN_PROFILE}" >/dev/null 2>"${NOTARY_PREFLIGHT_LOG}"; then
    cat "${NOTARY_PREFLIGHT_LOG}" >&2
    rm -f "${NOTARY_PREFLIGHT_LOG}"
    echo "ERROR: Notarization profile ${KEYCHAIN_PROFILE} is not ready. Fix Apple Developer agreements or credentials before releasing." >&2
    exit 1
fi
rm -f "${NOTARY_PREFLIGHT_LOG}"

resolve_built_app() {
    local products_dir="${BUILD_DIR}/Build/Products/Release"
    local candidate=""

    while IFS= read -r app; do
        if [ -f "${app}/Contents/Info.plist" ] && [ -d "${app}/Contents/Frameworks/Sparkle.framework" ]; then
            candidate="${app}"
            break
        fi
    done < <(find "${products_dir}" -maxdepth 1 -type d -name "*.app" | sort)

    if [ -z "${candidate}" ]; then
        while IFS= read -r app; do
            if [ -f "${app}/Contents/Info.plist" ]; then
                candidate="${app}"
                break
            fi
        done < <(find "${products_dir}" -maxdepth 1 -type d -name "*.app" | sort)
    fi

    if [ -z "${candidate}" ]; then
        echo "ERROR: Could not locate built app bundle in ${products_dir}" >&2
        exit 1
    fi

    BUILT_APP="${candidate}"
}

update_version_file() {
    python3 - "$VERSION_FILE" "$VERSION" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text()
updated, count = re.subn(r"^SPLICEKIT_VERSION\s*=\s*.*$", f"SPLICEKIT_VERSION = {version}", text, flags=re.M)
if count != 1:
    raise SystemExit(f"ERROR: failed to update SPLICEKIT_VERSION in {path}")
path.write_text(updated)
PY
}

maybe_upload_sentry_symbols() {
    if [ -z "${SENTRY_AUTH_TOKEN:-}" ] || [ -z "${SENTRY_ORG:-}" ]; then
        echo "  Skipping Sentry symbol upload (set SENTRY_AUTH_TOKEN and SENTRY_ORG to enable)"
        return
    fi

    local sentry_cli
    sentry_cli="$(command -v sentry-cli || true)"
    if [ -z "${sentry_cli}" ]; then
        echo "ERROR: sentry-cli not found in PATH" >&2
        exit 1
    fi

    if [ -d "${RUNTIME_DSYM}" ]; then
        echo "  Uploading runtime dSYM to ${SENTRY_RUNTIME_PROJECT}..."
        "${sentry_cli}" debug-files upload \
            --org "${SENTRY_ORG}" \
            --project "${SENTRY_RUNTIME_PROJECT}" \
            "${RUNTIME_DSYM}"
    else
        echo "  WARNING: runtime dSYM missing at ${RUNTIME_DSYM}"
    fi

    if [ -d "${PATCHER_DSYM}" ]; then
        echo "  Uploading patcher dSYM to ${SENTRY_PATCHER_PROJECT}..."
        "${sentry_cli}" debug-files upload \
            --org "${SENTRY_ORG}" \
            --project "${SENTRY_PATCHER_PROJECT}" \
            "${PATCHER_DSYM}"
    else
        echo "  WARNING: patcher dSYM missing at ${PATCHER_DSYM}"
    fi
}

echo "=== SpliceKit Release v${VERSION} ==="
echo ""

# ──────────────────────────────────────────────
# BUILD
# ──────────────────────────────────────────────

echo "[1/15] Bumping version to ${VERSION}..."
update_version_file

echo "[2/15] Building SpliceKit dylib + tools..."
make clean
make
make tools
make symbols

echo "[3/15] Building parakeet-transcriber..."
PARAKEET_PKG_DIR="patcher/SpliceKitPatcher.app/Contents/Resources/tools/parakeet-transcriber"
PARAKEET_BIN="${PARAKEET_PKG_DIR}/.build/release/parakeet-transcriber"
if [ -d "${PARAKEET_PKG_DIR}" ]; then
    cd "${PARAKEET_PKG_DIR}" && swift build -c release 2>&1 | tail -3 && cd "${REPO_ROOT}"
    if [ -f "$PARAKEET_BIN" ]; then
        echo "  Built: $(du -h "$PARAKEET_BIN" | cut -f1)"
    else
        echo "  WARNING: parakeet-transcriber build failed — release will not include it"
    fi
else
    echo "  Skipped: parakeet-transcriber package not found (pre-built binary will be used if available)"
fi

echo "[4/15] Building SpliceKit app via Xcode..."
xcodebuild -project "${XCODE_PROJECT}" \
    -scheme SpliceKit \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    ONLY_ACTIVE_ARCH=NO \
    clean build

resolve_built_app
PATCHER_DSYM="$(find "${BUILD_DIR}/Build/Products/Release" -maxdepth 1 -name "*.app.dSYM" | head -n 1)"
echo "  Using app bundle: ${BUILT_APP}"

echo "[5/15] Syncing bundled resources into app..."
APP_RES="${BUILT_APP}/Contents/Resources"
mkdir -p "${APP_RES}/mcp"
mkdir -p "${APP_RES}/tools"
cp build/SpliceKit "${APP_RES}/SpliceKit"
cp build/silence-detector "${APP_RES}/tools/silence-detector"
cp mcp/server.py "${APP_RES}/mcp/server.py"
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

echo "[6/15] Uploading Sentry symbols..."
maybe_upload_sentry_symbols

# ──────────────────────────────────────────────
# SIGN
# ──────────────────────────────────────────────

echo "[7/15] Signing embedded binaries (inner-to-outer)..."
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

echo "[8/15] Signing app bundle..."
codesign --force --options runtime --timestamp --sign "${SIGN_ID}" "${BUILT_APP}"
codesign --verify --deep --strict "${BUILT_APP}"
echo "  Verification passed"

# ──────────────────────────────────────────────
# CREATE DMG
# ──────────────────────────────────────────────

echo "[9/15] Creating DMG..."
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

echo "[10/15] Submitting DMG for notarization (this may take a few minutes)..."
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${KEYCHAIN_PROFILE}" --wait

echo "[11/15] Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"
echo "  Stapled: ${DMG_PATH}"

# ──────────────────────────────────────────────
# SPARKLE APPCAST
# ──────────────────────────────────────────────

echo "[12/15] Generating Sparkle EdDSA signature..."
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

echo "[13/15] Updating appcast.xml..."
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
        url=\"https://github.com/${RELEASE_REPO}/releases/download/v${VERSION}/${DMG_NAME}\"
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

echo "[14/15] Committing and pushing..."
git add appcast.xml "${VERSION_FILE}"
git commit -m "Release v${VERSION}: ${NOTES}"
git push "${PUSH_REMOTE}" "HEAD:${PUSH_BRANCH}"

if git rev-parse -q --verify "refs/tags/${TAG_NAME}" >/dev/null; then
    git tag -d "${TAG_NAME}"
fi
git tag -a "${TAG_NAME}" -m "Release ${TAG_NAME}"

LOCAL_TAG_SHA="$(git rev-parse "${TAG_NAME}^{}")"
REMOTE_TAG_SHA="$(git ls-remote --tags "${PUSH_REMOTE}" "refs/tags/${TAG_NAME}^{}" | awk '{print $1}')"
if [ -n "${REMOTE_TAG_SHA}" ] && [ "${REMOTE_TAG_SHA}" != "${LOCAL_TAG_SHA}" ]; then
    echo "ERROR: Remote tag ${TAG_NAME} already exists on ${PUSH_REMOTE} at ${REMOTE_TAG_SHA}, expected ${LOCAL_TAG_SHA}" >&2
    exit 1
fi
if [ -z "${REMOTE_TAG_SHA}" ]; then
    git push "${PUSH_REMOTE}" "refs/tags/${TAG_NAME}:refs/tags/${TAG_NAME}"
fi

echo "[15/15] Creating GitHub release..."
if gh release create "${TAG_NAME}" "${DMG_PATH}" \
    -R "${RELEASE_REPO}" \
    --verify-tag \
    --title "${TAG_NAME}" \
    --notes "${NOTES}"; then
    RELEASE_URL=$(gh release view "${TAG_NAME}" -R "${RELEASE_REPO}" --json url -q '.url')
else
    echo "ERROR: Failed to create GitHub release ${TAG_NAME}" >&2
    exit 1
fi

echo ""
echo "========================================="
echo "  Release v${VERSION} complete!"
echo "  ${RELEASE_URL}"
echo "========================================="
echo ""
echo "  - Built via Xcode, signed, notarized, stapled"
echo "  - DMG: ${DMG_PATH}"
echo "  - Sentry release: ${SENTRY_RELEASE_NAME}"
echo "  - Appcast updated with EdDSA signature"
echo "  - Pushed to main, GitHub release created"
echo "  - Sparkle will auto-notify users"
echo ""
