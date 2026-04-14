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

# Copy Sources for from-source builds
mkdir -p "$APP_RESOURCES/Sources"
rsync -a --delete "$REPO_DIR/Sources/" "$APP_RESOURCES/Sources/"
echo "Bundled Sources/"

# Copy Lua vendor sources (for from-source builds)
if [ -d "$REPO_DIR/vendor/lua-5.4.7" ]; then
    mkdir -p "$APP_RESOURCES/vendor/lua-5.4.7/src"
    rsync -a "$REPO_DIR/vendor/lua-5.4.7/src/" "$APP_RESOURCES/vendor/lua-5.4.7/src/"
    echo "Bundled vendor/lua-5.4.7/"
fi

# Copy MCP server
mkdir -p "$APP_RESOURCES/mcp"
cp "$REPO_DIR/mcp/server.py" "$APP_RESOURCES/mcp/server.py"
echo "Bundled mcp/server.py"

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

echo "Resource bundling complete"
