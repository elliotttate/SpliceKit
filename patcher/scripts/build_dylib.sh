#!/bin/bash
set -e

# Build SpliceKit ObjC dylib and tools
# Called by Xcode Run Script phase before Sources compilation

REPO_ROOT="${PROJECT_DIR}/.."
BUILD_OUT="${BUILT_PRODUCTS_DIR}/SpliceKit_prebuilt"
mkdir -p "$BUILD_OUT"

# Build ObjC dylib (universal binary)
echo "Building SpliceKit dylib..."
clang -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -framework Foundation -framework AppKit -framework AVFoundation \
    -fobjc-arc -fmodules -Wno-deprecated-declarations \
    -undefined dynamic_lookup -dynamiclib \
    -install_name @rpath/SpliceKit.framework/Versions/A/SpliceKit \
    -I "$REPO_ROOT/Sources" \
    "$REPO_ROOT/Sources/SpliceKit.m" \
    "$REPO_ROOT/Sources/SpliceKitRuntime.m" \
    "$REPO_ROOT/Sources/SpliceKitSwizzle.m" \
    "$REPO_ROOT/Sources/SpliceKitServer.m" \
    "$REPO_ROOT/Sources/SpliceKitTranscriptPanel.m" \
    "$REPO_ROOT/Sources/SpliceKitCommandPalette.m" \
    -o "$BUILD_OUT/SpliceKit"

# Build silence-detector
echo "Building silence-detector..."
swiftc -O -suppress-warnings \
    -o "$BUILD_OUT/silence-detector" \
    "$REPO_ROOT/tools/silence-detector.swift"

# Build parakeet-transcriber (non-fatal — first build downloads deps)
PARAKEET_DIR="$REPO_ROOT/tools/parakeet-transcriber"
if [ -f "$PARAKEET_DIR/Package.swift" ]; then
    echo "Building parakeet-transcriber..."
    cd "$PARAKEET_DIR" && swift build -c release 2>&1 && \
        cp "$PARAKEET_DIR/.build/release/parakeet-transcriber" "$BUILD_OUT/parakeet-transcriber" || \
        echo "warning: parakeet-transcriber build failed (transcription will use Apple Speech fallback)"
fi

echo "Build complete."
