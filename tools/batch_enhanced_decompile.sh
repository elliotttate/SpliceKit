#!/bin/bash
#
# Enhanced decompile: apply SpliceKit runtime metadata, then decompile.
# Processes ALL FCP binaries from the original batch_decompile.sh list.
#
set -euo pipefail

IDAT="/Applications/IDA Professional 9.3.app/Contents/MacOS/idat"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/ida_apply_and_decompile.py"
EXPORT_DIR="$SCRIPT_DIR/../ida_export"
FCP_APP="${FCP_APP:-$HOME/Applications/SpliceKit/Final Cut Pro.app}"
OUTPUT_ROOT="${1:-$HOME/Desktop/FinalCutPro_Decompiled}"

BINARIES=(
  # Tier 1 — Core
  "$FCP_APP/Contents/MacOS/Final Cut Pro"
  "$FCP_APP/Contents/Frameworks/Flexo.framework/Versions/A/Flexo"
  "$FCP_APP/Contents/Frameworks/Ozone.framework/Versions/A/Ozone"
  "$FCP_APP/Contents/Frameworks/TimelineKit.framework/Versions/A/TimelineKit"
  "$FCP_APP/Contents/Frameworks/Interchange.framework/Versions/A/Interchange"
  # Tier 2 — UI & Editing
  "$FCP_APP/Contents/Frameworks/LunaKit.framework/Versions/A/LunaKit"
  "$FCP_APP/Contents/Frameworks/ProInspector.framework/Versions/A/ProInspector"
  "$FCP_APP/Contents/Frameworks/ProCurveEditor.framework/Versions/A/ProCurveEditor"
  "$FCP_APP/Contents/Frameworks/ProChannel.framework/Versions/A/ProChannel"
  "$FCP_APP/Contents/Frameworks/ProCore.framework/Versions/A/ProCore"
  "$FCP_APP/Contents/Frameworks/ProMedia.framework/Versions/A/ProMedia"
  "$FCP_APP/Contents/Frameworks/ProMediaLibrary.framework/Versions/A/ProMediaLibrary"
  "$FCP_APP/Contents/Frameworks/TextFramework.framework/Versions/A/TextFramework"
  # Tier 3 — Media & Effects
  "$FCP_APP/Contents/Frameworks/Helium.framework/Versions/A/Helium"
  "$FCP_APP/Contents/Frameworks/HeliumSenso.framework/Versions/A/HeliumSenso"
  "$FCP_APP/Contents/Frameworks/Lithium.framework/Versions/A/Lithium"
  "$FCP_APP/Contents/Frameworks/AudioEffects.framework/Versions/A/AudioEffects"
  "$FCP_APP/Contents/Frameworks/ProAppsFxSupport.framework/Versions/A/ProAppsFxSupport"
  "$FCP_APP/Contents/Frameworks/FxPlug.framework/Versions/A/FxPlug"
  "$FCP_APP/Contents/Frameworks/MIO.framework/Versions/A/MIO"
  "$FCP_APP/Contents/Frameworks/RetimingMath.framework/Versions/A/RetimingMath"
  "$FCP_APP/Contents/Frameworks/ProOSC.framework/Versions/A/ProOSC"
  "$FCP_APP/Contents/Frameworks/ProGraphics.framework/Versions/A/ProGraphics"
  "$FCP_APP/Contents/Frameworks/ProGL.framework/Versions/A/ProGL"
  "$FCP_APP/Contents/Frameworks/ProShapes.framework/Versions/A/ProShapes"
  "$FCP_APP/Contents/Frameworks/Ozone.framework/Versions/A/Frameworks/AudioMixEngine.framework/Versions/A/AudioMixEngine"
  # Tier 4 — Extensions, Cloud, XML, Tracking
  "$FCP_APP/Contents/Frameworks/ProExtension.framework/Versions/A/ProExtension"
  "$FCP_APP/Contents/Frameworks/ProExtensionHost.framework/Versions/A/ProExtensionHost"
  "$FCP_APP/Contents/Frameworks/ProExtensionSupport.framework/Versions/A/ProExtensionSupport"
  "$FCP_APP/Contents/Frameworks/CloudContent.framework/Versions/A/CloudContent"
  "$FCP_APP/Contents/Frameworks/PMLCloudContent.framework/Versions/A/PMLCloudContent"
  "$FCP_APP/Contents/Frameworks/XMLCodable.framework/Versions/A/XMLCodable"
  "$FCP_APP/Contents/Frameworks/ProTracker.framework/Versions/A/ProTracker"
  "$FCP_APP/Contents/Frameworks/MDPKit.framework/Versions/A/MDPKit"
  "$FCP_APP/Contents/Frameworks/ProService.framework/Versions/A/ProService"
  "$FCP_APP/Contents/Frameworks/VAML.framework/Versions/A/VAML"
  "$FCP_APP/Contents/Frameworks/MusicUnderstandingEmbedded.framework/Versions/A/MusicUnderstandingEmbedded"
  # Tier 5 — Support/Utility
  "$FCP_APP/Contents/Frameworks/LunaFoundation.framework/Versions/A/LunaFoundation"
  "$FCP_APP/Contents/Frameworks/ProAppSupport.framework/Versions/A/ProAppSupport"
  "$FCP_APP/Contents/Frameworks/ProInspectorFoundation.framework/Versions/A/ProInspectorFoundation"
  "$FCP_APP/Contents/Frameworks/ProViewServiceSupport.framework/Versions/A/ProViewServiceSupport"
  "$FCP_APP/Contents/Frameworks/StudioSharedResources.framework/Versions/A/StudioSharedResources"
  "$FCP_APP/Contents/Frameworks/Stalgo.framework/Versions/A/Stalgo"
  "$FCP_APP/Contents/Frameworks/MXFExportSDK.framework/Versions/A/MXFExportSDK"
  "$FCP_APP/Contents/Frameworks/CoreAudioSDK.framework/Versions/A/CoreAudioSDK"
  "$FCP_APP/Contents/Frameworks/PMLUtilities.framework/Versions/A/PMLUtilities"
  "$FCP_APP/Contents/Frameworks/EmbeddedRemoteConfiguration.framework/Versions/A/EmbeddedRemoteConfiguration"
  "$FCP_APP/Contents/Frameworks/AppAnalytics.framework/Versions/A/AppAnalytics"
  "$FCP_APP/Contents/Frameworks/AppleMediaServicesKit.framework/Versions/A/AppleMediaServicesKit"
  "$FCP_APP/Contents/Frameworks/ProOnboardingFlowModelOne.framework/Versions/A/ProOnboardingFlowModelOne"
  "$FCP_APP/Contents/Frameworks/SwiftASN1.framework/Versions/A/SwiftASN1"
  "$FCP_APP/Contents/Frameworks/USearch.framework/Versions/A/USearch"
  "$FCP_APP/Contents/Frameworks/VAMLSentencePiece.framework/Versions/A/VAMLSentencePiece"
)

TOTAL=${#BINARIES[@]}
LOG="$OUTPUT_ROOT/_enhanced_batch.log"
mkdir -p "$OUTPUT_ROOT"

echo "========================================" | tee "$LOG"
echo "Enhanced Decompile with Runtime Metadata" | tee -a "$LOG"
echo "FCP App: $FCP_APP" | tee -a "$LOG"
echo "Export dir: $EXPORT_DIR" | tee -a "$LOG"
echo "Output: $OUTPUT_ROOT" | tee -a "$LOG"
echo "Binaries: $TOTAL" | tee -a "$LOG"
echo "Started: $(date)" | tee -a "$LOG"
echo "========================================" | tee -a "$LOG"

COMPLETED=0
FAILED=0
SKIPPED=0

for binary in "${BINARIES[@]}"; do
  name="$(basename "$binary")"
  outdir="$OUTPUT_ROOT/$name"
  json_file="$EXPORT_DIR/$name.json"
  mkdir -p "$outdir"

  # Skip if already done
  if [ -f "$outdir/_DONE.txt" ]; then
    echo "[$((COMPLETED+FAILED+SKIPPED+1))/$TOTAL] SKIP $name (already done)" | tee -a "$LOG"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [ ! -f "$binary" ]; then
    echo "[$((COMPLETED+FAILED+SKIPPED+1))/$TOTAL] SKIP $name - binary not found" | tee -a "$LOG"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Set runtime JSON if available
  if [ -f "$json_file" ]; then
    export RUNTIME_JSON="$json_file"
    echo "[$((COMPLETED+FAILED+SKIPPED+1))/$TOTAL] Processing $name (with runtime metadata)..." | tee -a "$LOG"
  else
    export RUNTIME_JSON=""
    echo "[$((COMPLETED+FAILED+SKIPPED+1))/$TOTAL] Processing $name (no runtime metadata)..." | tee -a "$LOG"
  fi

  start_time=$(date +%s)

  export IMAGE_MAP_JSON="$EXPORT_DIR/_image_map.json"
  export DECOMPILE_OUTPUT_DIR="$outdir"

  idb_path="$outdir/$name.i64"
  "$IDAT" -A -o"$idb_path" -S"$SCRIPT" -L"$outdir/_ida.log" "$binary" \
    >> "$outdir/_stdout.log" 2>&1 || true

  end_time=$(date +%s)
  elapsed=$((end_time - start_time))

  if [ -f "$outdir/_DONE.txt" ]; then
    stats=$(cat "$outdir/_DONE.txt")
    echo "  OK ($elapsed s) - $stats" | tee -a "$LOG"
    COMPLETED=$((COMPLETED + 1))
  else
    echo "  FAIL ($elapsed s) - check $outdir/_ida.log" | tee -a "$LOG"
    FAILED=$((FAILED + 1))
  fi
done

echo "========================================" | tee -a "$LOG"
echo "Finished: $(date)" | tee -a "$LOG"
echo "Completed: $COMPLETED / $TOTAL ($SKIPPED skipped)" | tee -a "$LOG"
echo "Failed: $FAILED / $TOTAL" | tee -a "$LOG"
echo "========================================" | tee -a "$LOG"
