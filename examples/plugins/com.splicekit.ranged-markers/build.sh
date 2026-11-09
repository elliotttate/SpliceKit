#!/bin/sh
# Build the ranged-markers plugin. Pass --install to copy it into SpliceKit's
# plugins folder so it loads automatically the next time FCP launches.
set -e
cd "$(dirname "$0")"
clang -fobjc-arc -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
    -I ../../../Sources \
    -framework Foundation -framework AppKit -framework QuartzCore \
    -undefined dynamic_lookup \
    -o RangedMarkers.dylib RangedMarkers.m
codesign -f -s - RangedMarkers.dylib
if [ "$1" = "--install" ]; then
    dest="$HOME/Library/Application Support/SpliceKit/plugins/com.splicekit.ranged-markers"
    mkdir -p "$dest"
    cp plugin.json "$dest/"
    # Replace the dylib rather than overwrite it: a running FCP has the old file
    # mapped, and writing into it invalidates its code signature (SIGKILL).
    cp RangedMarkers.dylib "$dest/RangedMarkers.dylib.new"
    mv -f "$dest/RangedMarkers.dylib.new" "$dest/RangedMarkers.dylib"
    echo "Installed to $dest (restart FCP to load)"
fi
