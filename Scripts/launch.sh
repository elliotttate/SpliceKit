#!/bin/bash
#
# Launch modded FCP with FCPBridge dylib injected
#

# Auto-detect modded edition: prefer standard, fall back to Creator Studio
MODDED_STANDARD="$HOME/Desktop/FinalCutPro_Modded/Final Cut Pro.app"
MODDED_CREATOR="$HOME/Desktop/FinalCutPro_Modded/Final Cut Pro Creator Studio.app"
if [ -d "$MODDED_STANDARD" ]; then
    MODDED_APP="$MODDED_STANDARD"
elif [ -d "$MODDED_CREATOR" ]; then
    MODDED_APP="$MODDED_CREATOR"
else
    MODDED_APP="$MODDED_STANDARD"
fi
DYLIB="$MODDED_APP/Contents/Frameworks/FCPBridge.framework/Versions/A/FCPBridge"

if [ ! -f "$DYLIB" ]; then
    echo "ERROR: FCPBridge dylib not found at: $DYLIB"
    echo "Run 'make deploy' first."
    exit 1
fi

echo "=== Launching Final Cut Pro with FCPBridge ==="
echo "  Socket: /tmp/fcpbridge.sock"
echo "  PID will appear in Console.app under [FCPBridge]"
echo ""

export DYLD_INSERT_LIBRARIES="$DYLIB"
exec "$MODDED_APP/Contents/MacOS/Final Cut Pro"
