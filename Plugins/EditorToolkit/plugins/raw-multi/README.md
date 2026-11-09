# RAW Multi

With several RAW clips selected, the RAW controls stay editable instead of turning into a dead **Multiple Values** label. A change or reset applies to every selected clip.

## Why

Matching a scene shot on one camera usually means setting the same ISO, white balance or gamma on a dozen clips. Final Cut greys out any control whose value differs across the selection, so you end up clicking through clips one by one. Resolve lets you change them all at once; this brings that behaviour over.

## How it works

- Sliders, menus and the ↺ reset buttons keep working with mixed selections.
- Values that differ show a small **Multiple** chip (menus show `--`), drawn on top of the control, so Final Cut's own data is never altered just to display it.
- Dragging, typing or picking a value sets it on all selected clips.

## Requires

RAW Tab (recommended) or the *Edit RAW Properties* panel.

## Install

```sh
./install.sh raw-multi
```

Then restart Final Cut Pro. Remove with `./install.sh --uninstall raw-multi`. Log: `~/Library/Logs/SpliceKit/`.
