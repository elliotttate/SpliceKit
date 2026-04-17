#!/bin/bash
# Bundle SpliceKit resources into the app during Xcode build phase
set -e

REPO_DIR="${PROJECT_DIR}/.."
APP_RESOURCES="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources"
PREBUILT="${BUILT_PRODUCTS_DIR}/SpliceKit_prebuilt"

# Copy pre-built dylib
if [ -f "$PREBUILT/SpliceKit" ]; then
    cp "$PREBUILT/SpliceKit" "$APP_RESOURCES/SpliceKit"
    echo "Bundled SpliceKit dylib"
fi

# Sources/ and vendor/lua are no longer bundled — the pre-built dylib is sufficient.
# From-source builds use the repo checkout directly (Makefile / patch_fcp.sh).

# Copy MCP server
mkdir -p "$APP_RESOURCES/mcp"
cp "$REPO_DIR/mcp/server.py" "$APP_RESOURCES/mcp/server.py"
echo "Bundled mcp/server.py"

# Generate bundled Sentry config from the current build environment.
bash "$REPO_DIR/Scripts/generate_sentry_config.sh" "$APP_RESOURCES/SpliceKitSentryConfig.plist"
echo "Bundled SpliceKitSentryConfig.plist"

# Copy Lua scripts
if [ -d "$REPO_DIR/Scripts/lua" ]; then
    mkdir -p "$APP_RESOURCES/Scripts/lua"
    rsync -a --delete "$REPO_DIR/Scripts/lua/" "$APP_RESOURCES/Scripts/lua/"
    echo "Bundled Scripts/lua/"
fi

# Copy tools
mkdir -p "$APP_RESOURCES/tools"
for tool in silence-detector structure-analyzer SpliceKitMixer; do
    if [ -f "$PREBUILT/$tool" ]; then
        cp "$PREBUILT/$tool" "$APP_RESOURCES/tools/$tool"
        echo "Bundled $tool"
    fi
done
if [ -f "$REPO_DIR/tools/silence-detector.swift" ]; then
    cp "$REPO_DIR/tools/silence-detector.swift" "$APP_RESOURCES/tools/silence-detector.swift"
fi

# Copy parakeet-transcriber: prefer pre-built binary, fall back to sources
PARAKEET_SRC="$REPO_DIR/patcher/SpliceKitPatcher.app/Contents/Resources/tools/parakeet-transcriber"
PARAKEET_RELEASE_BIN="$PARAKEET_SRC/.build/release/parakeet-transcriber"
PARAKEET_DEBUG_BIN="$PARAKEET_SRC/.build/debug/parakeet-transcriber"
if [ -f "$PARAKEET_RELEASE_BIN" ]; then
    cp "$PARAKEET_RELEASE_BIN" "$APP_RESOURCES/tools/parakeet-transcriber"
    echo "Bundled parakeet-transcriber binary (pre-built)"
elif [ -f "$PARAKEET_DEBUG_BIN" ]; then
    cp "$PARAKEET_DEBUG_BIN" "$APP_RESOURCES/tools/parakeet-transcriber"
    echo "Bundled parakeet-transcriber binary (debug build)"
elif [ -d "$PARAKEET_SRC" ]; then
    mkdir -p "$APP_RESOURCES/tools/parakeet-transcriber"
    rsync -a --delete \
        --exclude '.build' --exclude '.swiftpm' \
        "$PARAKEET_SRC/" "$APP_RESOURCES/tools/parakeet-transcriber/"
    echo "Bundled parakeet-transcriber sources (will build on first use)"
fi

# Bundle BRAW plugin bundles (VT decoder + FormatReader). PatcherModel copies
# these into the modded FCP.app/Contents/PlugIns/{Codecs,FormatReaders} during
# install — without them, FCP has no registered decoder for BRAW fourccs and
# drag/drop + Import Media silently fail for .braw files.
BRAW_STAGE_DIR="$PREBUILT/BRAWPlugins"
BRAW_OUT_DIR="$APP_RESOURCES/BRAWPlugins"
rm -rf "$BRAW_OUT_DIR"
mkdir -p "$BRAW_OUT_DIR/Codecs" "$BRAW_OUT_DIR/FormatReaders"
if [ -d "$BRAW_STAGE_DIR/Codecs/SpliceKitBRAWDecoder.bundle" ]; then
    cp -R "$BRAW_STAGE_DIR/Codecs/SpliceKitBRAWDecoder.bundle" "$BRAW_OUT_DIR/Codecs/"
    echo "Bundled SpliceKitBRAWDecoder.bundle"
else
    echo "WARNING: SpliceKitBRAWDecoder.bundle not found at $BRAW_STAGE_DIR/Codecs/"
fi
if [ -d "$BRAW_STAGE_DIR/FormatReaders/SpliceKitBRAWImport.bundle" ]; then
    cp -R "$BRAW_STAGE_DIR/FormatReaders/SpliceKitBRAWImport.bundle" "$BRAW_OUT_DIR/FormatReaders/"
    echo "Bundled SpliceKitBRAWImport.bundle"
else
    echo "WARNING: SpliceKitBRAWImport.bundle not found at $BRAW_STAGE_DIR/FormatReaders/"
fi

echo "Resource bundling complete"
