#!/bin/bash
set -euo pipefail

IDAT="${IDAT:-/Applications/IDA Professional 9.3.app/Contents/MacOS/idat}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FULL_SCRIPT="$SCRIPT_DIR/ida_apply_and_decompile.py"
TARGETED_SCRIPT="$SCRIPT_DIR/ida_targeted_slice.py"
APP="${1:-/Applications/DaVinci Resolve/DaVinci Resolve.app}"
OUTPUT_ROOT="${2:-$SCRIPT_DIR/../analysis/resolve_immersive_braw}"

mkdir -p "$OUTPUT_ROOT"

FULL_BINARIES=(
  "$APP/Contents/Frameworks/BlackmagicRawAPI.framework/BlackmagicRawAPI"
  "$APP/Contents/Frameworks/ImmersiveVideoToolbox.framework/ImmersiveVideoToolbox"
)

TARGETED_BINARIES=(
  "$APP/Contents/MacOS/Resolve"
  "$APP/Contents/Libraries/libImmersiveAudioBridge.dylib"
)

FULL_PATTERNS="immersive,braw,blackmagicraw,stereo,projection,metadata,visionpro,spatial,staticmetadata,dynamicmetadata,proim"
RESOLVE_PATTERNS="immersive,braw,blackmagic raw,stereo,projection,isspatialvideo,projectionformat,stereoscopicmode,staticmetadata,dynamicmetadata,vision pro,spatial,proim,ivt,ProtoVideoProcParamsBRAW"
AUDIO_PATTERNS="immersive,binaural,spatial,stereo,adm,object,audioscene,renderer,ear,scene metadata"

run_full() {
  local binary="$1"
  local name
  name="$(basename "$binary")"
  local outdir="$OUTPUT_ROOT/$name-full"
  mkdir -p "$outdir"
  echo "[*] Full decompile: $name -> $outdir"
  export RUNTIME_JSON=""
  export IMAGE_MAP_JSON=""
  export DECOMPILE_OUTPUT_DIR="$outdir"
  export EXPORT_XREF_PATTERNS="$FULL_PATTERNS"
  "$IDAT" -A -o"$outdir/$name.i64" -S"$FULL_SCRIPT" -L"$outdir/_ida.log" "$binary" \
    >"$outdir/_stdout.log" 2>&1
}

run_targeted() {
  local binary="$1"
  local patterns="$2"
  local tag="$3"
  local name
  name="$(basename "$binary")"
  local outdir="$OUTPUT_ROOT/$name-$tag"
  mkdir -p "$outdir"
  echo "[*] Targeted decompile: $name ($tag) -> $outdir"
  export TARGET_PATTERNS="$patterns"
  export TARGET_OUTPUT_DIR="$outdir"
  export TARGET_MAX_CALL_DEPTH="${TARGET_MAX_CALL_DEPTH:-1}"
  export TARGET_MAX_FUNCTIONS="${TARGET_MAX_FUNCTIONS:-500}"
  "$IDAT" -A -o"$outdir/$name.i64" -S"$TARGETED_SCRIPT" -L"$outdir/_ida.log" "$binary" \
    >"$outdir/_stdout.log" 2>&1
}

for binary in "${FULL_BINARIES[@]}"; do
  if [[ -f "$binary" ]]; then
    run_full "$binary"
  else
    echo "[!] Missing full binary: $binary" >&2
  fi
done

for binary in "${TARGETED_BINARIES[@]}"; do
  if [[ ! -f "$binary" ]]; then
    echo "[!] Missing targeted binary: $binary" >&2
    continue
  fi
  if [[ "$binary" == *"/Resolve" ]]; then
    run_targeted "$binary" "$RESOLVE_PATTERNS" "targeted"
  else
    run_targeted "$binary" "$AUDIO_PATTERNS" "targeted"
  fi
done

echo "[*] Outputs written to $OUTPUT_ROOT"
