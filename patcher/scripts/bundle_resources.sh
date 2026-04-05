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

# Copy MCP server
mkdir -p "$APP_RESOURCES/mcp"
cp "$REPO_DIR/mcp/server.py" "$APP_RESOURCES/mcp/server.py"
echo "Bundled mcp/server.py"

# Copy tools
mkdir -p "$APP_RESOURCES/tools"
if [ -f "$PREBUILT/silence-detector" ]; then
    cp "$PREBUILT/silence-detector" "$APP_RESOURCES/tools/silence-detector"
    echo "Bundled silence-detector"
fi
if [ -f "$REPO_DIR/tools/silence-detector.swift" ]; then
    cp "$REPO_DIR/tools/silence-detector.swift" "$APP_RESOURCES/tools/silence-detector.swift"
fi

# Copy parakeet-transcriber sources if available
PARAKEET_SRC="$REPO_DIR/tools/parakeet-transcriber"
if [ -d "$PARAKEET_SRC" ]; then
    mkdir -p "$APP_RESOURCES/tools/parakeet-transcriber"
    rsync -a --delete \
        --exclude '.build' --exclude '.swiftpm' \
        "$PARAKEET_SRC/" "$APP_RESOURCES/tools/parakeet-transcriber/"
    echo "Bundled parakeet-transcriber sources"
fi

echo "Resource bundling complete"
