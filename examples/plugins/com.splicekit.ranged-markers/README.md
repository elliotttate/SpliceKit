# Ranged & Colored Markers (prototype)

Native SpliceKit plugin that adds markers with a real duration and custom colors.

- **Ranges** are stored as the marker's own duration, using FCP's
  `actionAddMarkerToAnchoredObject:isToDo:isChapter:withRange:error:`. They are
  undoable, saved in the library, survive blade edits, and export to FCPXML as
  `duration="…"`.
- **Colors** are stored as a tag at the start of the marker name, e.g.
  `[Red] Fix audio`. The palette is DaVinci Resolve's 16 marker colors plus orange.
- **Long ranges:** FCP won't let a marker run past the source media of the clip
  it's attached to. When a range needs more than that, FCP gets as much as fits
  and the full length is kept in the tag, e.g. `[Red 12.5s] Fix audio`.
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
- **Marker dialog** (double-click a marker) has a **Duration** field. Type
  timecode (`00:00:10:00`, or `10:00` read right to left like FCP's fields) or
  seconds (`10`, `2.5`); leave it empty to remove the range.
- **Deleting a ranged marker deletes all its copies.** Blading a clip gives every
  piece its own copy of the clip's markers, and FCP shows a ranged marker's copy
  on every piece its range overlaps. Deleting one (Delete key or dragging it off
  the clip) also removes the copies in the other pieces, as one undo step.
- **Moving markers keeps their range.** FCP's own drag and Nudge Marker
  Left/Right rebuild a marker one frame long; the plugin restores the length.

Every change is a normal FCP edit, so Cmd-Z undoes it.

## FCPXML

Ranged and colored markers need nothing custom in FCPXML:

```xml
<marker start="43380157/12000s" duration="404404/24000s" value="[Fuchsia] Marker 2"/>
```

Exporting and re-importing keeps the range, the color tag and plain markers
unchanged (tested in FCP 12.3). Without the plugin, imported markers show as
normal pins with the tag in their name. Other apps should keep the `duration`
but will show the `[Color]` tag as part of the name.

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
| `rangedMarkers.debugMarkers` | — (development: each marker's clip and media range) |
| `rangedMarkers.debugEditor` | — (development: view tree of the open marker dialog) |

## Known limitations

- Only markers on primary storyline clips are handled by `add` and `list`.
- Adding a named or colored marker makes two undo steps (add, then rename).
- Restoring a range after FCP moves a marker is its own undo step.
- Only the end of a range can be dragged; drag the pin itself to move a marker.
- The ⌃⌥M shortcut is a menu shortcut and is not listed in FCP's Command Editor.
