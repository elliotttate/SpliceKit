# Topmost Clip Editing

**View → Edit Topmost Clip at Playhead** (also in the Command Editor). With this on and **nothing selected**, Blade (⌘B) and Copy (⌘C) act on the highest unlocked video clip under the playhead instead of the primary storyline.

## Why

On a layered timeline, the shot you care about is often a connected clip on top. Final Cut's Blade and Copy with no selection always go to the storyline underneath. Other editors let you target the clip you can actually see. Selecting first and then deselecting before every cut breaks the rhythm of editing.

## How it works

- Skips locked layers (`lock` in the name), audio-only clips, gaps, markers and captions.
- Final Cut skimmer rules apply: it edits at the skimmer while skimming, otherwise at the playhead.
- A clip copied this way pastes (⌘V / ⌥V) back on the layer it came from, or the next free one. Paste Below Lock then keeps it under locks.
- Uses Final Cut's own blade:/copy: on that clip, so timing, connections and undo are native.
- With nothing to target, or with the toggle off, keys behave exactly as normal.

## Requires

Nothing. Works well with Paste Below Lock.

## Install

```sh
./install.sh topmost
```

Then restart Final Cut Pro. Remove with `./install.sh --uninstall topmost`. Log: `~/Library/Logs/SpliceKit/`.
