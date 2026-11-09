#!/bin/bash
# Double-click to install the plugins in this folder into SpliceKit, then restart Final Cut Pro.
cd "$(dirname "$0")"
DEST="$HOME/Library/Application Support/SpliceKit/plugins"
mkdir -p "$DEST" "$HOME/Library/Logs/SpliceKit"
echo "Installing Editor Toolkit plugins..."; echo
n=0
for d in plugins/*/; do
  p=$(basename "$d"); mkdir -p "$DEST/$p/data"
  for f in "$d"*; do
    b=$(basename "$f"); cp "$f" "$DEST/$p/.$b.tmp" && mv -f "$DEST/$p/.$b.tmp" "$DEST/$p/$b"
  done
  xattr -dr com.apple.quarantine "$DEST/$p" 2>/dev/null
  echo "  ✓ $p"; n=$((n+1))
done
echo; echo "Installed $n plugin(s). Quit and reopen Final Cut Pro (with SpliceKit) to use them."
echo; read -n1 -p "Press any key to close."
