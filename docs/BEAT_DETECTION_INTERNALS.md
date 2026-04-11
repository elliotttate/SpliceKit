# Beat Detection Internals Guide

This guide documents how Final Cut Pro's built-in beat detection actually works,
how SpliceKit exposes it, and how that differs from SpliceKit's standalone
`detect_beats()` analysis tool.

It is based on three sources:

1. Live runtime inspection of FCP through SpliceKit's ObjC bridge
2. Decompiled Flexo symbols related to beat detection
3. SpliceKit's own source and MCP behavior

---

## Table of Contents

1. [Two Different Systems](#two-different-systems)
2. [Built-In FCP Beat Detection](#built-in-fcp-beat-detection)
3. [Command Validation Rules](#command-validation-rules)
4. [What Makes a Clip Beat-Detectable](#what-makes-a-clip-beat-detectable)
5. [Why A-V Clips Fail](#why-a-v-clips-fail)
6. [What Happens After Detection Runs](#what-happens-after-detection-runs)
7. [Beat Grid UI States](#beat-grid-ui-states)
8. [Existing Beat Grid Metadata](#existing-beat-grid-metadata)
9. [SpliceKit's External `detect_beats()` Tool](#splicekits-external-detect_beats-tool)
10. [Practical Workflows](#practical-workflows)
11. [Debugging Checklist](#debugging-checklist)

---

## Two Different Systems

There are two distinct beat-detection paths in this project:

| System | Entry Point | Scope | Works On | Output |
|--------|-------------|-------|----------|--------|
| FCP built-in beat grid | `enableBeatDetection` / `detectBeatsOnSelection:` | Timeline objects | Only beat-grid-capable timeline clips | Clip timing metadata + optional visible beat grid |
| SpliceKit external detector | `detect_beats(file_path=...)` | Arbitrary media file | Any file with an audio track, including MP4 with video | Beat/bar/section timestamps and BPM |

These systems are related conceptually, but they are not interchangeable.

The built-in FCP command is much stricter about what kinds of selected timeline
objects it accepts. The standalone SpliceKit detector is much more permissive.

---

## Built-In FCP Beat Detection

SpliceKit maps the timeline action `enableBeatDetection` to FCP's built-in
selector `detectBeatsOnSelection:`.

The decompiled method `-[FFAnchoredTimelineModule detectBeatsOnSelection:]`
shows a simple three-way state machine:

1. If any selected primordial clip `canDetectBeats`, run async beat analysis
2. Else if any selected primordial clip `canShowBeats`, enable the beat grid
3. Else if any selected primordial clip `canHideBeats`, disable the beat grid

In other words, the same command serves as:

- "analyze this clip for beats"
- "show the beat grid for an already-analyzed clip"
- "hide the beat grid for an already-analyzed clip"

The command is backed by `FFEnableBeatGridCommand`.

---

## Command Validation Rules

FCP validates the menu item in
`-[FFAnchoredTimelineModule validateUserInterfaceItem:]`.

For `detectBeatsOnSelection:` the menu is enabled when the selected items satisfy
any of these:

- `FFEnableBeatGridCommand canDetectBeatsOnObjects:`
- `FFEnableBeatGridCommand canShowBeatsOnObjects:`
- `FFEnableBeatGridCommand canHideBeatsOnObjects:`

If none of those are true, the menu item is disabled.

`FFEnableBeatGridCommand` does not inspect only the top-level selected objects.
It recursively walks "primordial" clips via
`_iterateOverPrimordialClipsWithinObjects:usingBlock:`.

That walker descends into selected collections that are both:

- `isSpine == true`
- `isAnchored == true`

and then evaluates their `containedItems`.

This is why selecting a container or collection can still resolve down to a
child clip for beat-detection eligibility.

---

## What Makes a Clip Beat-Detectable

The core predicate is `-[FFAnchoredObject canDetectBeats]`.

Decompiled logic:

```text
canDetectBeats =
    _supportsBeatGrid
    && !isFlexMusicObject
    && sequence.supportsBeatDetection
    && hasAudio
    && !hasTimingMetadata
```

That means a clip is eligible for first-time beat analysis only if:

- it is a beat-grid-capable object
- it is not a FlexMusic object
- its sequence supports beat detection
- it has audio
- it does not already have timing metadata

### Sequence-Level Gate

`-[FFAnchoredSequence supportsBeatDetection]` decompiles to:

```text
return clipType != 2;
```

So some sequence types are excluded before clip-level predicates even matter.

### `_supportsBeatGrid`

The most important gate is `-[FFAnchoredObject _supportsBeatGrid]`.

It immediately rejects any object that is:

- a video clip (`hasVideo == true`)
- a multicam object
- a reference clip
- a transition
- a synchronized clip

It also rejects some artistic retime cases. Constant artistic retime may still
pass, but non-constant artistic retime does not.

This single predicate explains most confusing UI behavior.

---

## Why A-V Clips Fail

This was the critical finding from the investigation:

FCP's built-in beat detection does not run on a normal A/V clip, even if that
clip contains clear music in its audio track.

If `hasVideo == true`, `_supportsBeatGrid` returns false, which means:

- `canDetectBeats == false`
- `canShowBeats == false`
- `canHideBeats == false`

That disables `Enable Beat Detection`.

### Why Expanding Audio Components Does Not Help

Expanding audio components is not enough.

The decompiled class `FFAudioComponentSource` returns `0` for:

- `canDetectBeats`
- `canShowBeats`
- `canHideBeats`

So selecting an expanded audio component does not satisfy the built-in beat-grid
command either.

The intended built-in workflow is an audio-only beat-grid-capable timeline
object, not a video clip with attached audio and not a component-source view of
that audio.

---

## What Happens After Detection Runs

When a clip passes validation, `detectBeatsOnSelection:` dispatches analysis
asynchronously through:

`+[FFEnableBeatGridCommand detectBeatsOnObjects:usingDelegate:enableBeatGrid:completionBlock:]`

That pipeline does the following:

1. Walks the selected primordial clips
2. Keeps clips that already `canShowBeats`
3. Collects clips that `canDetectBeats`
4. Groups those clips by representative asset `mediaIdentifier`
5. Calls `analyzeBeatsOnAssets:completionBlock:` on the delegate
6. Writes the resulting timing metadata back to the model under a model write lock
7. Optionally enables the beat grid immediately after metadata is written

The metadata write phase calls:

`setBeatTimeValues:barTimeValues:sectionTimeValues:tempo:`

So the built-in system stores four things on the clip model:

- beat times
- bar times
- section times
- tempo

If beat-grid enablement was requested and metadata was written successfully,
FCP enables the grid and may post `FFBeatGridSettingsChangedNotification`.

---

## Beat Grid UI States

`FFAudioBeatDetectionController` computes a simple four-state UI model in
`updateUI`:

- `0` = can detect beats
- `1` = can show beats
- `2` = can hide beats
- `3` = unsupported

This matches the three-way command behavior plus a disabled state.

SpliceKit runtime inspection also showed that a timeline with no active beat-grid
presentation can report `beatGridState = 0`, but the important actionable
predicates are still `canDetectBeats`, `canShowBeats`, and `canHideBeats`.

---

## Existing Beat Grid Metadata

Once a clip already has timing metadata:

- `canDetectBeats` becomes false
- `canShowBeats` becomes true when timing metadata exists and `beatGridEnabled == 0`
- `canHideBeats` becomes true when timing metadata exists and `beatGridEnabled != 0`

Decompiled logic:

```text
canShowBeats =
    _supportsBeatGrid
    && sequence.supportsBeatDetection
    && hasTimingMetadata
    && !beatGridEnabled

canHideBeats =
    _supportsBeatGrid
    && sequence.supportsBeatDetection
    && hasTimingMetadata
    && beatGridEnabled
```

So after analysis has been performed once, the same command toggles visibility
instead of re-running detection.

---

## SpliceKit's External `detect_beats()` Tool

SpliceKit also ships a completely separate beat analysis path:

```python
detect_beats(file_path="/path/to/media.mp4")
```

This path is implemented by the standalone Swift tool in
`tools/beat-detector.swift`.

Important differences from the built-in FCP path:

- it works on file paths, not timeline objects
- it accepts normal media files with video, as long as they contain audio
- it returns raw timestamps and BPM rather than mutating FCP clip metadata
- it bypasses FCP's beat-grid eligibility rules entirely

During investigation, this external path successfully analyzed a source MP4 that
FCP refused to analyze through `Enable Beat Detection`, producing a plausible BPM
and full beat/bar/section arrays.

This is the right fallback when:

- the music is embedded in an A/V clip
- FCP's menu item stays disabled
- you want timing data without changing timeline metadata

---

## Practical Workflows

### If You Want FCP's Built-In Beat Grid

Use an audio-only timeline object.

Recommended workflow:

1. Put the music on the timeline as a standalone audio-only clip
2. Select that audio-only clip
3. Run `Enable Beat Detection`
4. Use `Beat Detection Grid` once timing metadata exists

If the music currently lives inside a normal A/V clip:

1. Detach or otherwise isolate the audio into its own clip
2. Make sure the selected object is truly audio-only
3. Run beat detection on that audio-only object

### If You Only Need Beat Timing Data

Use the external detector:

```python
detect_beats(file_path="/path/to/file.mp4")
```

This is the most reliable option for:

- music videos
- source MP4s with embedded soundtrack
- montage planning
- scripting that only needs timestamps and BPM

---

## Debugging Checklist

When `Enable Beat Detection` is disabled, check these in order:

1. Does the selected primordial clip return `canDetectBeats`?
2. If not, does it return `canShowBeats` or `canHideBeats`?
3. If all three are false, inspect:
   - `hasVideo`
   - `hasAudio`
   - `hasTimingMetadata`
   - `isFlexMusicObject`
   - sequence `supportsBeatDetection`
4. If `hasVideo == true`, that alone is enough to fail built-in detection
5. If you are only selecting expanded audio components, expect failure there too
6. If the source media has an audio track, verify it with `detect_beats(file_path=...)`

Useful runtime probes through SpliceKit:

```python
call_method_with_args(target=clip, selector="canDetectBeats", args="[]")
call_method_with_args(target=clip, selector="canShowBeats", args="[]")
call_method_with_args(target=clip, selector="canHideBeats", args="[]")
call_method_with_args(target=clip, selector="_supportsBeatGrid", args="[]")
call_method_with_args(target=clip, selector="hasTimingMetadata", args="[]")
call_method_with_args(target=assetRef, selector="originalMediaURL", args="[]")
detect_beats(file_path="/resolved/source/file.mp4")
```

---

## Bottom Line

The built-in FCP beat grid is not a generic "analyze whatever audio is attached
to this clip" feature.

It is a model-level feature for beat-grid-capable timeline objects, and those
objects are effectively audio-only. A normal video clip with music embedded in
its audio track will fail the built-in predicate even if the audio itself is
perfectly suitable for beat analysis.

SpliceKit's external `detect_beats()` tool does not have that limitation, which
makes it the better option whenever the source media is an A/V file.
