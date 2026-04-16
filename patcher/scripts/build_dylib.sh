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
CANONICAL_DYLIB_OUT="$REPO_DIR/build/SpliceKit"
SOURCE_MANIFEST="$REPO_DIR/Sources/SOURCES.txt"

mkdir -p "$BUILD_OUT"

if [ ! -f "$SOURCE_MANIFEST" ]; then
    echo "Missing source manifest: $SOURCE_MANIFEST" >&2
    exit 1
fi

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

SOURCES=()
while IFS= read -r source; do
    SOURCES+=("$REPO_DIR/Sources/$source")
done < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$SOURCE_MANIFEST")

LUA_FLAGS=()
if [ -f "$LUA_LIB" ]; then
    LUA_FLAGS=(-I "$LUA_DIR" "$LUA_LIB")
fi

echo "Building SpliceKit dylib..."
clang -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -framework Foundation -framework AppKit -framework AVFoundation -framework CoreServices \
    -framework CoreImage -framework Metal -framework MetalKit -framework QuartzCore -framework Vision \
    -fobjc-arc -fmodules -Wno-deprecated-declarations \
    -undefined dynamic_lookup -dynamiclib \
    -install_name @rpath/SpliceKit.framework/Versions/A/SpliceKit \
    -I "$REPO_DIR/Sources" \
    "${SOURCES[@]}" "${LUA_FLAGS[@]}" -o "$BUILD_OUT/SpliceKit"

# Keep the repo's canonical deploy target in sync when the script is run directly.
# This prevents `make deploy` from accidentally shipping a stale dylib after a
# successful standalone build.
if [ -z "${BUILT_PRODUCTS_DIR:-}" ]; then
    mkdir -p "$(dirname "$CANONICAL_DYLIB_OUT")"
    cp "$BUILD_OUT/SpliceKit" "$CANONICAL_DYLIB_OUT"
    echo "Synced canonical dylib: $CANONICAL_DYLIB_OUT"
fi

echo "Building silence-detector..."
SILENCE_SRC="$REPO_DIR/tools/silence-detector.swift"
if [ -f "$SILENCE_SRC" ]; then
    swiftc -O -suppress-warnings -o "$BUILD_OUT/silence-detector" "$SILENCE_SRC"
fi

echo "Build complete: $BUILD_OUT"
ls -la "$BUILD_OUT/"
