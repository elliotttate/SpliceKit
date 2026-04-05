#!/bin/bash
#
# Launch modded FCP with SpliceKit dylib injected
#

# Auto-detect modded edition: prefer standard, fall back to Creator Studio
MODDED_STANDARD="$HOME/Applications/SpliceKit/Final Cut Pro.app"
MODDED_CREATOR="$HOME/Applications/SpliceKit/Final Cut Pro Creator Studio.app"
if [ -d "$MODDED_STANDARD" ]; then
    MODDED_APP="$MODDED_STANDARD"
elif [ -d "$MODDED_CREATOR" ]; then
    MODDED_APP="$MODDED_CREATOR"
else
    MODDED_APP="$MODDED_STANDARD"
fi
DYLIB="$MODDED_APP/Contents/Frameworks/SpliceKit.framework/Versions/A/SpliceKit"

if [ ! -f "$DYLIB" ]; then
    echo "ERROR: SpliceKit dylib not found at: $DYLIB"
    echo "Run 'make deploy' first."
    exit 1
fi

echo "=== Launching Final Cut Pro with SpliceKit ==="
echo "  Socket: /tmp/splicekit.sock"
echo "  PID will appear in Console.app under [SpliceKit]"
echo ""

export DYLD_INSERT_LIBRARIES="$DYLIB"
exec "$MODDED_APP/Contents/MacOS/Final Cut Pro"
