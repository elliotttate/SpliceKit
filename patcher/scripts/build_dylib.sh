#!/bin/bash
# Build SpliceKit dylib and tools during Xcode build phase.
# Delegates to the repo-root Makefile so there is a single source of truth
# for source files, compiler flags, and tool builds.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${PROJECT_DIR:-}" ]; then
    REPO_DIR="${PROJECT_DIR}/.."
else
    REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

if [ -n "${BUILT_PRODUCTS_DIR:-}" ]; then
    BUILD_OUT="${BUILT_PRODUCTS_DIR}/SpliceKit_prebuilt"
else
    BUILD_OUT="$REPO_DIR/build/SpliceKit_prebuilt"
fi

mkdir -p "$BUILD_OUT"

# Ensure the vendored Sentry framework exists before Swift sources compile.
bash "$REPO_DIR/Scripts/ensure_sentry_framework.sh"

# Build everything via the Makefile (handles incremental builds)
# Includes braw-prototype so the VT decoder + FormatReader bundles end up
# at build/braw-prototype/{Codecs,FormatReaders}/*.bundle ready to ship.
echo "Building SpliceKit via Makefile..."
make -C "$REPO_DIR" all tools braw-prototype

# Copy artifacts to Xcode's expected location
cp "$REPO_DIR/build/SpliceKit" "$BUILD_OUT/SpliceKit"

for tool in silence-detector structure-analyzer SpliceKitMixer; do
    if [ -f "$REPO_DIR/build/$tool" ]; then
        cp "$REPO_DIR/build/$tool" "$BUILD_OUT/$tool"
    fi
done

# Stage BRAW plugin bundles so bundle_resources.sh can copy them into the app.
BRAW_OUT="$BUILD_OUT/BRAWPlugins"
rm -rf "$BRAW_OUT"
mkdir -p "$BRAW_OUT/Codecs" "$BRAW_OUT/FormatReaders"
if [ -d "$REPO_DIR/build/braw-prototype/Codecs/SpliceKitBRAWDecoder.bundle" ]; then
    cp -R "$REPO_DIR/build/braw-prototype/Codecs/SpliceKitBRAWDecoder.bundle" \
          "$BRAW_OUT/Codecs/"
fi
if [ -d "$REPO_DIR/build/braw-prototype/FormatReaders/SpliceKitBRAWImport.bundle" ]; then
    cp -R "$REPO_DIR/build/braw-prototype/FormatReaders/SpliceKitBRAWImport.bundle" \
          "$BRAW_OUT/FormatReaders/"
fi

echo "Build complete: $BUILD_OUT"
ls -la "$BUILD_OUT/"
echo "BRAW plugin staging:"
ls -la "$BRAW_OUT/Codecs/" "$BRAW_OUT/FormatReaders/" 2>/dev/null || true
