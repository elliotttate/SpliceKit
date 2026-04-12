#!/bin/bash
# Build SpliceKit dylib and tools during Xcode build phase
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

# Build Lua 5.4.7 static library
LUA_DIR="$REPO_DIR/vendor/lua-5.4.7/src"
LUA_LIB="$BUILD_OUT/liblua.a"
if [ -d "$LUA_DIR" ]; then
    echo "Building Lua 5.4.7 static library..."
    mkdir -p "$BUILD_OUT/lua_obj"
    for src in "$LUA_DIR"/*.c; do
        base="$(basename "$src" .c)"
        # Skip standalone executables
        [ "$base" = "lua" ] && continue
        [ "$base" = "luac" ] && continue
        clang -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
            -DLUA_USE_MACOSX -O2 -Wall -c "$src" -o "$BUILD_OUT/lua_obj/$base.o"
    done
    libtool -static -o "$LUA_LIB" "$BUILD_OUT"/lua_obj/*.o
    echo "Built: $LUA_LIB"
fi

SOURCES=(
    "$REPO_DIR/Sources/SpliceKit.m"
    "$REPO_DIR/Sources/SpliceKitDualTimeline.m"
    "$REPO_DIR/Sources/SpliceKitDualTimelineDrag.m"
    "$REPO_DIR/Sources/SpliceKitRuntime.m"
    "$REPO_DIR/Sources/SpliceKitSwizzle.m"
    "$REPO_DIR/Sources/SpliceKitServer.m"
    "$REPO_DIR/Sources/SpliceKitLogPanel.m"
    "$REPO_DIR/Sources/SpliceKitTranscriptPanel.m"
    "$REPO_DIR/Sources/SpliceKitCaptionPanel.m"
    "$REPO_DIR/Sources/SpliceKitCommandPalette.m"
    "$REPO_DIR/Sources/SpliceKitDebugUI.m"
    "$REPO_DIR/Sources/SpliceKitLua.m"
    "$REPO_DIR/Sources/SpliceKitLuaPanel.m"
)

LUA_FLAGS=""
if [ -f "$LUA_LIB" ]; then
    LUA_FLAGS="-I $LUA_DIR $LUA_LIB"
fi

echo "Building SpliceKit dylib..."
clang -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -framework Foundation -framework AppKit -framework AVFoundation \
    -fobjc-arc -fmodules -Wno-deprecated-declarations \
    -undefined dynamic_lookup -dynamiclib \
    -install_name @rpath/SpliceKit.framework/Versions/A/SpliceKit \
    -I "$REPO_DIR/Sources" \
    "${SOURCES[@]}" $LUA_FLAGS -o "$BUILD_OUT/SpliceKit"

echo "Building silence-detector..."
SILENCE_SRC="$REPO_DIR/tools/silence-detector.swift"
if [ -f "$SILENCE_SRC" ]; then
    swiftc -O -suppress-warnings -o "$BUILD_OUT/silence-detector" "$SILENCE_SRC" 2>&1 || true
fi

echo "Build complete: $BUILD_OUT"
ls -la "$BUILD_OUT/"
