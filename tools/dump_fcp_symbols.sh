#!/bin/bash
# dump_fcp_symbols.sh - Extract debug symbols, feature flags, and metadata
# that IDA Pro's decompilation misses.
#
# Produces structured reference files for SpliceKit development.
#
# Usage: ./tools/dump_fcp_symbols.sh [output_dir]

set -uo pipefail

FCP_APP="/Applications/Final Cut Pro.app"
FCP_BIN="$FCP_APP/Contents/MacOS/Final Cut Pro"
FCP_FW="$FCP_APP/Contents/Frameworks"
OUT="${1:-$(pwd)/fcp_symbols}"

mkdir -p "$OUT"

# All frameworks to scan
FRAMEWORKS=(
    Flexo Ozone TimelineKit LunaKit Helium HeliumSenso Lithium
    ProCore ProAppSupport ProInspector ProInspectorFoundation
    ProChannel ProCurveEditor ProMedia ProMediaLibrary
    ProAppsFxSupport ProOSC ProGraphics ProGL ProShapes
    ProExtension ProExtensionHost ProExtensionSupport
    ProTracker ProService
    TextFramework Interchange AudioEffects AudioMixEngine
    FxPlug MIO RetimingMath MDPKit
    CloudContent PMLCloudContent
    LunaFoundation StudioSharedResources Stalgo
    EDEL PluginManager
    VAML XMLCodable
)

bin_path() {
    local fw="$1"
    if [ "$fw" = "FinalCutPro" ]; then
        echo "$FCP_BIN"
    else
        echo "$FCP_FW/${fw}.framework/${fw}"
    fi
}

echo "=== FCP Symbol Dump ==="
echo "Output: $OUT"
echo ""

# ─────────────────────────────────────────────────────────
# 1. Action selectors (the API surface for SpliceKit)
# ─────────────────────────────────────────────────────────
echo "[1/9] Extracting action selectors..."
{
    echo "# FCP Action Selectors"
    echo "# Extracted: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# These are the ObjC action methods FCP responds to."
    echo "# Many are not yet wired up in SpliceKit."
    echo ""

    # Main binary
    echo "## Final Cut Pro (main binary)"
    strings "$FCP_BIN" 2>/dev/null | grep -E '^action[A-Z]' | sort -u | sed 's/^/  /'
    echo ""

    for fw in "${FRAMEWORKS[@]}"; do
        bin=$(bin_path "$fw")
        [ ! -f "$bin" ] && continue
        actions=$(strings "$bin" 2>/dev/null | grep -E '^action[A-Z]' | sort -u)
        [ -z "$actions" ] && continue
        count=$(echo "$actions" | wc -l | tr -d ' ')
        echo "## $fw ($count)"
        echo "$actions" | sed 's/^/  /'
        echo ""
    done
} > "$OUT/action_selectors.txt"
echo "  -> $(grep -c '  action' "$OUT/action_selectors.txt") action selectors"

# ─────────────────────────────────────────────────────────
# 2. Toggle selectors (show/hide/toggle methods)
# ─────────────────────────────────────────────────────────
echo "[2/9] Extracting toggle/show/hide selectors..."
{
    echo "# FCP Toggle/Show/Hide Selectors"
    echo "# Extracted: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""

    for fw in FinalCutPro "${FRAMEWORKS[@]}"; do
        bin=$(bin_path "$fw")
        [ ! -f "$bin" ] && continue
        toggles=$(strings "$bin" 2>/dev/null | grep -E '^(toggle|show|hide)[A-Z]' | sort -u)
        [ -z "$toggles" ] && continue
        name="$fw"
        [ "$fw" = "FinalCutPro" ] && name="Final Cut Pro"
        count=$(echo "$toggles" | wc -l | tr -d ' ')
        echo "## $name ($count)"
        echo "$toggles" | sed 's/^/  /'
        echo ""
    done
} > "$OUT/toggle_selectors.txt"
echo "  -> $(grep -c '  ' "$OUT/toggle_selectors.txt" || echo 0) toggle selectors"

# ─────────────────────────────────────────────────────────
# 3. Notification names
# ─────────────────────────────────────────────────────────
echo "[3/9] Extracting notification names..."
{
    echo "# FCP Notification Names"
    echo "# Extracted: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Internal event bus - subscribe to react to FCP state changes."
    echo ""

    for fw in FinalCutPro "${FRAMEWORKS[@]}"; do
        bin=$(bin_path "$fw")
        [ ! -f "$bin" ] && continue
        notifs=$(strings "$bin" 2>/dev/null | grep -iE 'Notification$|DidChange$|WillChange$|DidEnd$|DidBegin$|DidStart$|DidFinish$|DidComplete$' | grep -v '^_' | sort -u)
        [ -z "$notifs" ] && continue
        name="$fw"
        [ "$fw" = "FinalCutPro" ] && name="Final Cut Pro"
        count=$(echo "$notifs" | wc -l | tr -d ' ')
        echo "## $name ($count)"
        echo "$notifs" | sed 's/^/  /'
        echo ""
    done
} > "$OUT/notifications.txt"
echo "  -> $(grep -c '  ' "$OUT/notifications.txt" || echo 0) notification names"

# ─────────────────────────────────────────────────────────
# 4. NSUserDefaults / feature flag keys
# ─────────────────────────────────────────────────────────
echo "[4/9] Extracting defaults keys and feature flags..."
{
    echo "# FCP NSUserDefaults Keys & Feature Flags"
    echo "# Extracted: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Hidden toggles, experimental features, debug settings."
    echo "# Set via: [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@\"KEY\"]"
    echo ""

    for fw in FinalCutPro "${FRAMEWORKS[@]}"; do
        bin=$(bin_path "$fw")
        [ ! -f "$bin" ] && continue
        keys=$(strings "$bin" 2>/dev/null | grep -E '^(FF|TLK|Debug|HMD|PE|LK|Pro)[A-Z][a-zA-Z]+(Enabled|Disabled|Mode|Key|Enable|Disable|Override|Force|Internal|Experimental|Default|Path|URL|Interval|Timeout|Level|Threshold|Duration|Factor|Scale|Limit|Count|Size|Rate|Delay|Max|Min|Log|Dump|Debug|Test|Show|Hide|Allow|Prevent|Skip)$' | sort -u)
        [ -z "$keys" ] && continue
        name="$fw"
        [ "$fw" = "FinalCutPro" ] && name="Final Cut Pro"
        count=$(echo "$keys" | wc -l | tr -d ' ')
        echo "## $name ($count)"
        echo "$keys" | sed 's/^/  /'
        echo ""
    done
} > "$OUT/defaults_keys.txt"
echo "  -> $(grep -c '  ' "$OUT/defaults_keys.txt" || echo 0) defaults keys"

# ─────────────────────────────────────────────────────────
# 5. Protocol and delegate interfaces
# ─────────────────────────────────────────────────────────
echo "[5/9] Extracting protocols and delegates..."
{
    echo "# FCP Protocol & Delegate Interfaces"
    echo "# Extracted: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""

    for fw in FinalCutPro "${FRAMEWORKS[@]}"; do
        bin=$(bin_path "$fw")
        [ ! -f "$bin" ] && continue
        protos=$(strings "$bin" 2>/dev/null | grep -E '^(FF|PE|LK|TLK|OZ|Pro|HMD)[A-Z].*((Protocol|Delegate|DataSource)$)' | sort -u)
        [ -z "$protos" ] && continue
        name="$fw"
        [ "$fw" = "FinalCutPro" ] && name="Final Cut Pro"
        count=$(echo "$protos" | wc -l | tr -d ' ')
        echo "## $name ($count)"
        echo "$protos" | sed 's/^/  /'
        echo ""
    done
} > "$OUT/protocols.txt"
echo "  -> $(grep -c '  ' "$OUT/protocols.txt" || echo 0) protocol/delegate names"

# ─────────────────────────────────────────────────────────
# 6. ObjC categories
# ─────────────────────────────────────────────────────────
echo "[6/9] Extracting ObjC categories..."
{
    echo "# FCP ObjC Categories"
    echo "# Extracted: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Methods added to existing classes. IDA decompiles the methods"
    echo "# but loses which category added them."
    echo ""

    for fw in FinalCutPro "${FRAMEWORKS[@]}"; do
        bin=$(bin_path "$fw")
        [ ! -f "$bin" ] && continue
        cats=$(nm "$bin" 2>/dev/null | grep "__OBJC_\$_CATEGORY_" | sed 's/.*__OBJC_\$_CATEGORY_//' | grep -v "CLASS_METHODS\|INSTANCE_METHODS" | sort -u)
        [ -z "$cats" ] && continue
        name="$fw"
        [ "$fw" = "FinalCutPro" ] && name="Final Cut Pro"
        count=$(echo "$cats" | wc -l | tr -d ' ')
        echo "## $name ($count categories)"
        echo "$cats" | sed 's/^/  /'
        echo ""
    done
} > "$OUT/categories.txt"
echo "  -> $(grep -c '  ' "$OUT/categories.txt" || echo 0) categories"

# ─────────────────────────────────────────────────────────
# 7. Swift symbols (demangled)
# ─────────────────────────────────────────────────────────
echo "[7/9] Extracting and demangling Swift symbols..."
{
    echo "# FCP Swift Symbols (Demangled)"
    echo "# Extracted: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# IDA Pro is poor at Swift - these symbols contain struct/enum/protocol"
    echo "# definitions that IDA can't reconstruct."
    echo ""

    for fw in FinalCutPro "${FRAMEWORKS[@]}"; do
        bin=$(bin_path "$fw")
        [ ! -f "$bin" ] && continue
        swift_count=$(nm "$bin" 2>/dev/null | grep -c "_\$s" || echo 0)
        [ "$swift_count" -lt 1 ] && continue
        name="$fw"
        [ "$fw" = "FinalCutPro" ] && name="Final Cut Pro"
        echo "## $name ($swift_count Swift symbols)"
        # Demangle and show unique type definitions
        nm "$bin" 2>/dev/null | grep "_\$s" | swift demangle 2>/dev/null | \
            grep -iE "type metadata|nominal type|protocol witness|struct |class |enum " | \
            sed 's/^[0-9a-f ]*/  /' | sort -u | head -200
        echo ""
    done
} > "$OUT/swift_symbols.txt" 2>/dev/null
echo "  -> $(wc -l < "$OUT/swift_symbols.txt" | tr -d ' ') lines"

# ─────────────────────────────────────────────────────────
# 8. Unnamed functions (IDA couldn't symbolicate)
# ─────────────────────────────────────────────────────────
DECOMPILED="${DECOMPILED_DIR:-$HOME/Desktop/FinalCutPro_DecompiledOLD}"
echo "[8/9] Cataloging unnamed functions from IDA decompile..."
{
    echo "# FCP Unnamed Functions (IDA couldn't symbolicate)"
    echo "# Extracted: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# These sub_XXXX functions may be nameable via nm + swift demangle."
    echo ""

    if [ -d "$DECOMPILED" ]; then
        for idx in "$DECOMPILED"/*/_INDEX.txt; do
            dir=$(dirname "$idx")
            name=$(basename "$dir")
            [[ "$name" == _* || "$name" == *.py || "$name" == *.sh ]] && continue
            total=$(wc -l < "$idx" 2>/dev/null | tr -d ' \n')
            unnamed=$(grep -c "sub_[0-9A-Fa-f]" "$idx" 2>/dev/null | tr -d ' \n' || echo "0")
            [ "$unnamed" -eq 0 ] 2>/dev/null && continue
            pct=$((unnamed * 100 / total))
            echo "## $name ($unnamed / $total unnamed, ${pct}%)"
            grep "sub_[0-9A-Fa-f]" "$idx" | head -50 | sed 's/^/  /'
            [ "$unnamed" -gt 50 ] && echo "  ... and $((unnamed - 50)) more"
            echo ""
        done
    else
        echo "# Decompiled directory not found at: $DECOMPILED"
        echo "# Set DECOMPILED_DIR env var to override."
    fi
} > "$OUT/unnamed_functions.txt"
echo "  -> $(grep -c '  0x' "$OUT/unnamed_functions.txt" 2>/dev/null || echo 0) unnamed functions cataloged"

# ─────────────────────────────────────────────────────────
# 9. Complete selector reference (every method FCP can call)
# ─────────────────────────────────────────────────────────
echo "[9/9] Extracting selector references from core frameworks..."
{
    echo "# FCP Selector References (Editing-Related)"
    echo "# Extracted: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Every selector referenced in Flexo related to editing operations."
    echo ""

    bin="$FCP_FW/Flexo.framework/Flexo"
    if [ -f "$bin" ]; then
        echo "## Flexo editing selectors"
        nm "$bin" 2>/dev/null | grep "__OBJC_SELECTOR_\$_" | sed 's/.*__OBJC_SELECTOR_\$_//' | sort -u | \
            grep -iE "blade|marker|transition|effect|undo|redo|timeline|playhead|export|import|share|render|clip|sequence|project|library|audio|video|caption|role|speed|retime|trim|split|join|nudge|keyframe|color|inspector|scope|viewer|zoom|snap|skim|solo|disable|compound|multicam|audition|storyline|duplicate|snapshot" | \
            sed 's/^/  /'
    fi
} > "$OUT/editing_selectors.txt"
echo "  -> $(grep -c '  ' "$OUT/editing_selectors.txt" || echo 0) editing-related selectors"

# ─────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────
echo ""
echo "=== Done ==="
echo "Output directory: $OUT"
echo ""
ls -lh "$OUT"/*.txt | awk '{print "  " $NF ": " $5}'
echo ""
echo "Total: $(du -sh "$OUT" | cut -f1)"
