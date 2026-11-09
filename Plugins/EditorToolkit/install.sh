#!/bin/bash
# Editor Toolkit for SpliceKit - build and install any or all of the plugins.
#
#   ./install.sh --list                 show every plugin and preset
#   ./install.sh --all                  build + install everything
#   ./install.sh raw-tab flip           build + install just these
#   ./install.sh @raw                   build + install a preset (see --list)
#   ./install.sh --uninstall flip       remove a plugin
#   ./install.sh --package              build double-click installer zips into dist/ (all, presets, each plugin)
#
# Needs: Final Cut Pro with SpliceKit, Apple Silicon, and the Xcode command line tools (xcode-select --install).
# Restart Final Cut Pro after installing so SpliceKit loads the new plugins.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
DEST="$HOME/Library/Application Support/SpliceKit/plugins"
LOGS="$HOME/Library/Logs/SpliceKit"
BUILD="$ROOT/build"

PRESET_raw="raw-tab raw-multi raw-gyro shortcuts"
PRESET_lock="grade-lock grade-lock-skim paste-below-lock topmost"
PRESET_workspace="workspace-collapse workspace-fix"
PRESET_editing="topmost paste-below-lock xml-clips audio-sync flip"
PRESET_monitoring="fps-meter"

all_plugins() { ls -1 "$ROOT/plugins"; }
json_field() { /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2" 2>/dev/null || true; }

list() {
  echo "Plugins:"
  for p in $(all_plugins); do printf "  %-20s %s\n" "$p" "$(json_field "$ROOT/plugins/$p/plugin.json" description)"; done
  echo; echo "Presets (install with ./install.sh @name):"
  for v in $(compgen -v | grep '^PRESET_'); do printf "  @%-19s %s\n" "${v#PRESET_}" "${!v}"; done
}

need_clang() {
  command -v clang >/dev/null 2>&1 || { echo "clang not found. Install Apple's command line tools first:  xcode-select --install"; exit 1; }
}

build_one() {
  local p="$1" dir="$ROOT/plugins/$1"
  [ -d "$dir" ] || { echo "unknown plugin: $p (see --list)"; exit 1; }
  # shellcheck disable=SC1091
  SOURCE=""; PRODUCT=""; FRAMEWORKS=""; source "$dir/build.env"
  local fw=""; for f in $FRAMEWORKS; do fw="$fw -framework $f"; done
  mkdir -p "$BUILD/$p"
  echo "building $p"
  # shellcheck disable=SC2086
  clang -arch arm64 -mmacosx-version-min=14.0 -dynamiclib -fobjc-arc -O2 $fw \
        -Wl,-undefined,dynamic_lookup -o "$BUILD/$p/$PRODUCT" "$dir/$SOURCE" 2> "$BUILD/$p/build.log" \
    || { cat "$BUILD/$p/build.log"; echo "build failed: $p"; exit 1; }
  codesign -s - -f "$BUILD/$p/$PRODUCT" >/dev/null 2>&1
  cp "$dir/plugin.json" "$BUILD/$p/"
}

install_one() {
  local p="$1"; build_one "$p"
  source "$ROOT/plugins/$p/build.env"
  local t="$DEST/$p"; mkdir -p "$t/data" "$LOGS"
  cp "$BUILD/$p/$PRODUCT" "$t/.$PRODUCT.tmp" && mv -f "$t/.$PRODUCT.tmp" "$t/$PRODUCT"   # atomic swap, safe while FCP runs
  cp "$BUILD/$p/plugin.json" "$t/plugin.json"
  echo "  installed -> $t"
}

uninstall_one() {
  local t="$DEST/$1"
  [ -d "$t" ] || { echo "not installed: $1"; return; }
  rm -rf "$t" && echo "removed $1"
}

expand() {
  local out=""
  for a in "$@"; do
    case "$a" in
      @*) v="PRESET_${a#@}"; [ -n "${!v:-}" ] || { echo "unknown preset: $a"; exit 1; }; out="$out ${!v}";;
      *) out="$out $a";;
    esac
  done
  echo "$out" | tr ' ' '\n' | awk 'NF && !seen[$0]++'
}

hints() {
  local sel=" $* "
  for p in raw-multi raw-gyro shortcuts; do
    [[ "$sel" == *" $p "* && "$sel" != *" raw-tab "* && ! -d "$DEST/raw-tab" ]] && echo "note: $p works best with raw-tab installed too."
  done
  [[ "$sel" == *" grade-lock-skim "* && "$sel" != *" grade-lock "* && ! -d "$DEST/grade-lock" ]] && echo "note: grade-lock-skim is the second half of grade-lock; install both."
  return 0
}

package() {
  need_clang; rm -rf "$ROOT/dist"; mkdir -p "$ROOT/dist"
  local stage="$ROOT/dist/.stage"
  bundle() {   # bundle <zip name> <folder name> <plugins...>
    local zipname="$1" folder="$2"; shift 2
    local b="$stage/$folder"; rm -rf "$stage"; mkdir -p "$b/plugins"
    cp "$ROOT/dist-templates/"* "$b/"; chmod +x "$b/"*.command
    for p in "$@"; do
      mkdir -p "$b/plugins/$p"
      cp "$BUILD/$p/"*.dylib "$BUILD/$p/plugin.json" "$ROOT/plugins/$p/README.md" "$b/plugins/$p/"
    done
    (cd "$stage" && ditto -c -k --keepParent "$folder" "$ROOT/dist/$zipname.zip")
  }
  for p in $(all_plugins); do build_one "$p"; done
  bundle "EditorToolkit-All" "Editor Toolkit" $(all_plugins)
  for v in $(compgen -v | grep '^PRESET_'); do n="${v#PRESET_}"; bundle "EditorToolkit-preset-$n" "Editor Toolkit - $n" ${!v}; done
  for p in $(all_plugins); do
    name=$(json_field "$ROOT/plugins/$p/plugin.json" name)
    bundle "EditorToolkit-$p" "Editor Toolkit - $name" "$p"
  done
  rm -rf "$stage"
  echo "zips in $ROOT/dist - each has a double-click Install.command."
}

case "${1:-}" in
  ""|-h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; echo; list;;
  --list) list;;
  --package) package;;
  --uninstall) shift; for p in $(expand "$@"); do uninstall_one "$p"; done; echo "Restart Final Cut Pro to unload.";;
  --all) need_clang; sel=$(all_plugins); for p in $sel; do install_one "$p"; done; echo "Done. Restart Final Cut Pro.";;
  *) need_clang; sel=$(expand "$@"); for p in $sel; do install_one "$p"; done; hints $sel; echo "Done. Restart Final Cut Pro.";;
esac
