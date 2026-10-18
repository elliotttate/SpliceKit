# Ranged & Colored Markers (prototype)

Native SpliceKit plugin that adds markers with a real duration and custom colors.

- **Ranges** are stored as the marker's own duration, using FCP's
  `actionAddMarkerToAnchoredObject:isToDo:isChapter:withRange:error:`. They are
  undoable, saved in the library, survive blade edits, and export to FCPXML as
  `duration="…"`.
- **Colors** are stored as a tag at the start of the marker name, e.g.
  `[Red] Fix audio`. The palette is DaVinci Resolve's 16 marker colors plus orange.
- **Drawing** swizzles `TLKMarkerLayer` (`layoutSublayers`, `updateAppearance`,
  `setPosition:`) to tint the pin and draw an always-visible bar across the range.
  Without the plugin, markers show as normal pins with the tag in their name.

## Using it in Final Cut Pro

- **Mark ▸ Markers ▸ Add Ranged Marker** (⌃⌥M): adds a marker over the in/out
  range, or 5 seconds from the playhead if no range is set.
- **Right-click a marker**: Marker Color, Extend Marker Range to Playhead,
  Set Marker Range to In/Out, Remove Marker Range.
- **Mark ▸ Markers** has the same color and range items. They act on the
  selected marker, else the marker under the playhead. Extend uses the closest
  marker before the playhead, so you can add a marker, play, stop, and extend.
- **Drag the handle** at the end of a range bar to resize it. The new length is
  shown while dragging and snaps to whole frames.

Every change is a normal FCP edit, so Cmd-Z undoes it.

## Build and install

```bash
./build.sh            # build RangedMarkers.dylib
./build.sh --install  # also copy into ~/Library/Application Support/SpliceKit/plugins/
```

Installed plugins load when FCP launches. During development, hot-load a copy
with a unique path instead: `debug_load_plugin(action="load", path="/tmp/rm_<n>.dylib")`.

## Methods

| Method | Params |
|---|---|
| `rangedMarkers.add` | `start`, `end` or `duration` (sequence seconds; defaults to the in/out range), `name`, `color`, `kind` (`standard`/`todo`/`chapter`) |
| `rangedMarkers.setColor` | `color` (or `none`), `marker` handle (defaults to the selected marker) |
| `rangedMarkers.list` | — |
| `rangedMarkers.refresh` | — |
| `rangedMarkers.debugLayers` | — (development) |

## Known limitations

- Only markers on primary storyline clips are handled by `add` and `list`.
- Adding a named or colored marker makes two undo steps (add, then rename).
- Only the end of a range can be dragged; drag the pin itself to move a marker.
- The ⌃⌥M shortcut is a menu shortcut and is not listed in FCP's Command Editor.
