#!/bin/bash
# Build SpliceKit dylib and tools during Xcode build phase
set -e

REPO_DIR="${PROJECT_DIR}/.."
BUILD_OUT="${BUILT_PRODUCTS_DIR}/SpliceKit_prebuilt"
mkdir -p "$BUILD_OUT"

SOURCES=(
    "$REPO_DIR/Sources/SpliceKit.m"
    "$REPO_DIR/Sources/SpliceKitRuntime.m"
    "$REPO_DIR/Sources/SpliceKitSwizzle.m"
    "$REPO_DIR/Sources/SpliceKitServer.m"
    "$REPO_DIR/Sources/SpliceKitTranscriptPanel.m"
    "$REPO_DIR/Sources/SpliceKitCommandPalette.m"
)

echo "Building SpliceKit dylib..."
clang -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -framework Foundation -framework AppKit -framework AVFoundation \
    -fobjc-arc -fmodules -Wno-deprecated-declarations \
    -undefined dynamic_lookup -dynamiclib \
    -install_name @rpath/SpliceKit.framework/Versions/A/SpliceKit \
    -I "$REPO_DIR/Sources" \
    "${SOURCES[@]}" -o "$BUILD_OUT/SpliceKit"

echo "Building silence-detector..."
SILENCE_SRC="$REPO_DIR/tools/silence-detector.swift"
if [ -f "$SILENCE_SRC" ]; then
    swiftc -O -suppress-warnings -o "$BUILD_OUT/silence-detector" "$SILENCE_SRC" 2>&1 || true
fi

echo "Build complete: $BUILD_OUT"
ls -la "$BUILD_OUT/"
