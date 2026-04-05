#!/bin/bash
set -e

# Bundle SpliceKit resources into the app
# Called by Xcode Run Script phase after Embed Frameworks

REPO_ROOT="${PROJECT_DIR}/.."
BUILD_OUT="${BUILT_PRODUCTS_DIR}/SpliceKit_prebuilt"
RESOURCES="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources"

# Pre-built dylib binary
echo "Bundling SpliceKit dylib..."
cp "$BUILD_OUT/SpliceKit" "$RESOURCES/SpliceKit"

# ObjC source files (for cache-based fallback installs)
echo "Bundling source files..."
mkdir -p "$RESOURCES/Sources"
rsync -a --delete "$REPO_ROOT/Sources/" "$RESOURCES/Sources/"

# MCP server
echo "Bundling MCP server..."
mkdir -p "$RESOURCES/mcp"
cp "$REPO_ROOT/mcp/server.py" "$RESOURCES/mcp/server.py"

# Tools — binaries
echo "Bundling tools..."
mkdir -p "$RESOURCES/tools"
cp "$REPO_ROOT/tools/silence-detector.swift" "$RESOURCES/tools/silence-detector.swift"
[ -f "$BUILD_OUT/silence-detector" ] && cp "$BUILD_OUT/silence-detector" "$RESOURCES/tools/silence-detector"
[ -f "$BUILD_OUT/parakeet-transcriber" ] && cp "$BUILD_OUT/parakeet-transcriber" "$RESOURCES/tools/parakeet-transcriber"

# Parakeet source (for fallback building at patch-time)
mkdir -p "$RESOURCES/tools/parakeet-transcriber"
rsync -a --delete --exclude '.build' --exclude '.swiftpm' \
    "$REPO_ROOT/tools/parakeet-transcriber/" "$RESOURCES/tools/parakeet-transcriber/"

echo "Bundle complete."
