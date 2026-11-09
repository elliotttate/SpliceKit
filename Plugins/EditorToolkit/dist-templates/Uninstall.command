#!/bin/bash
# Double-click to remove the plugins in this folder from SpliceKit.
cd "$(dirname "$0")"
DEST="$HOME/Library/Application Support/SpliceKit/plugins"
for d in plugins/*/; do
  p=$(basename "$d"); [ -d "$DEST/$p" ] && rm -rf "$DEST/$p" && echo "  removed $p"
done
echo; echo "Done. Quit and reopen Final Cut Pro."
echo; read -n1 -p "Press any key to close."
