# Final Cut Pro Haptics — Complete Reference

A deep dive into every haptic FCP fires, derived from the decompiled `Final Cut Pro`,
`Flexo`, `TimelineKit`, and `LunaKit` binaries.

## TL;DR

FCP's entire haptic surface goes through a **single helper function** in LunaKit
(`LKPerformAlignmentFeedbackPatternNow`) that calls
`[NSHapticFeedbackManager defaultPerformer] performFeedbackPattern:1 performanceTime:1`.

- **Pattern**: `NSHapticFeedbackPatternAlignment` (constant `1`) — a single, light
  "click" intended for snap/alignment events. (The two other AppKit patterns,
  `…GenericPattern` and `…LevelChangePattern`, are **not** used anywhere in FCP.)
- **Performance time**: `NSHapticFeedbackPerformanceTimeNow` (constant `1`) — fire
  immediately, do not coalesce.
- **Hardware requirement**: A Force Touch trackpad. `NSHapticFeedbackManager` only
  routes haptics to that device class; Magic Mouse, regular trackpads, and external
  pointing devices receive nothing.
- **System gate**: `System Settings → Trackpad → Force Click and haptic feedback`
  must be enabled. FCP does not expose its own preference — there is no per-app
  on/off switch and no way to change pattern or intensity from inside the app.

There are exactly **four call sites** in the entire app. Three live in `Flexo`
(the timeline/editor framework) and two live in `TimelineKit` (the lower-level
timeline view). All four fire a single alignment "click" the moment an
alignment- or constraint-related state changes.

## The helper function

```objc
// LunaKit, +0xDFE60
id LKPerformAlignmentFeedbackPatternNow(void) {
    id performer = [NSHapticFeedbackManager defaultPerformer];
    return [performer performFeedbackPattern:NSHapticFeedbackPatternAlignment
                             performanceTime:NSHapticFeedbackPerformanceTimeNow];
}
```

Both `Flexo` and `TimelineKit` re-export thunks of this symbol so internal callers
can invoke it without a separate dlsym; the body lives in LunaKit.

## Every haptic, by trigger

### 1. Snap-target change in the Viewer canvas

| Where | `Flexo` → `-[FFSnapGridOSC addDrawProperties:forTime:forContainer:viewBounds:]` block |
|-------|---|
| When  | The active horizontal or vertical snap line changes while you drag a Transform / Crop / Distort handle, an on-screen drop-zone, the Position effect, the title bounding box, or any other Viewer overlay that participates in `FFSnapGrid`. |
| Logic | `FFSnapGrid` exposes `activeHorIndex` / `activeVerIndex` (-1 = no snap, otherwise the index of the snap line being held). The OSC compares the new (H, V) snap pair against the previously stored pair; if either index changed and at least one is non-`-1`, the haptic fires once and the new pair is stored as the previous. |
| Effect | One alignment tap each time you cross from one canvas snap to another — equivalent to feeling each guide line "catch". |
| Notes  | Only fires when the snap grid is enabled (Viewer → ⌘N or `View → Show Snapping`) **and** a drag is actually engaging snap targets. Unsnapped motion produces no haptic. |

### 2. Snap during anchored-drop on the timeline

| Where | `Flexo` → `-[FFAnchoredTimelineModule _acceptDrop:onItem:dropTime:dropHighlight:error:]` |
|-------|---|
| When  | Dragging a title (or other anchored item) into the timeline and the **drop highlight** moves to a new aligned position — typically when the drop point or highlight range snaps to a clip boundary, the playhead, a marker, or the project's edge. |
| Logic | The function compares the new `dropHighlight` start, duration, and `dropTime` against the values cached on the module from the last drag tick (`+892 / +868 / +880 / +904 / +908`). If any component differs, the haptic fires. |
| Effect | One alignment tap each time the title drop indicator jumps to a new snap target during the drag-to-timeline gesture (titles only — clip drops use the `TLKDragEdgesHandler` snap path below). |
| Notes  | Gated by `+[Flexo timelineTitleDropZonesEnabled]` and only for items that pass the `kFFEffectType_VideoTitle` pasteboard check — this is specifically the **title drag** path, not the generic media drag path. |

### 3. Trim/roll edge hits a constraint (state-machine entry)

| Where | `TimelineKit` → `-[TLKDragEdgesHandler _moveEdgeByTimeOffset:]` |
|-------|---|
| When  | While trimming or rolling a clip edge, the data source returns `NO` from `shouldTrimEdge:trimType:ofItem:byTimeOffset:movementType:` (or `shouldRollEdge:…`) **for the first time** in the current drag — i.e., the edge has just hit the limit of available media handles, the start/end of the parent storyline, an adjacent edit, or any other trim constraint. |
| Logic | The handler keeps a "currently rejected" bit (`_dhFlags & 0x2000`). When `shouldTrim/Roll` returns `NO` and that bit was clear, it fires the haptic and sets the bit; the bit is cleared as soon as a future tick is allowed again. So you feel exactly **one** click on the transition from "moving freely" to "constrained". |
| Effect | A single alignment tap the moment a trim or roll runs out of room. |
| Notes  | `_moveEdgeByTimeOffset:` is the *commit* path — it runs as the layout actually advances. This haptic is what tells you "you've maxed out the trim" without watching the inspector. |

### 4. Trim/roll edge constraint (cursor-tracking state-machine path)

| Where | `TimelineKit` → `-[TLKDragEdgesHandler _timeOffsetForMovingEdgeToPoint:]` |
|-------|---|
| When  | The same trim/roll constraint as #3, but reached from the cursor-tracking path that runs every mouse-moved event. |
| Logic | Mirror of #3 but operating on the cursor-derived candidate offset rather than the committed move. The 0x2000 bit is shared with #3, so the two functions cooperate: only one of them ever fires the haptic for a given "first hit". |
| Effect | Same single alignment tap as #3; this branch is what guarantees the haptic fires even on tiny mouse moves that don't make it through to `_moveEdgeByTimeOffset:`. |
| Notes  | If you're hunting for "why no haptic on this trim", the relevant guard is `(unsigned __int8)objc_msgSend(v48, "isAnchoredItem")` and `[TLKTimelineView timeUnits] != 1` — anchored items and time-rule timelines skip the entire `shouldTrim/Roll` evaluation, so trimming a connected clip currently produces no haptic. |

### 5. Force Touch pressure-state change on the J/K/L jog buttons

| Where | `Flexo` → `-[FFTransportLongPressButton mouseDown:]` block |
|-------|---|
| When  | While pressing the fast-forward (`L`-style) or rewind (`J`-style) buttons in the **transport controls** under the Viewer, the Force Touch pressure crosses into a new discrete rate bucket (1×, 2×, 4×, 8×, 20×, etc.). |
| Logic | The button is registered with `NSPressureConfiguration` behavior **3** (`NSPressureBehaviorPrimaryAccelerator` — multi-stage) via `LKCreatePressureConfigurationWithPressureBehaviour(3)` in `-[FFTransportLongPressButton updateTrackingAreas]`. The mouseDown event-tracking block reads `NSEvent.pressure` and `NSEvent.stage`, maps the float `pressure` to an integer `currentPressureState` over `numberOfPressureStates` buckets (`stage 2` jumps to the maximum bucket directly), and on every bucket transition fires the haptic and re-invokes `pressurePressAction` (which is wired up to `setRate:` on the transport delegate). |
| Effect | A click each time the playback rate steps up under your finger — gives the Force Touch jog buttons the same tactile "notched" feel as a physical jog/shuttle wheel. |
| Notes  | Only fires after the long-press timer (`minLongPressTimeInterval`, ≥ 0.5 s) has elapsed; tapping the button briefly does not enter pressure mode. The cap-out (already at the highest bucket) explicitly skips the haptic so the click only happens on real transitions. |

## What does **not** fire a haptic in FCP

Worth noting because it's surprising:

- **Playhead snapping during scrubbing or slipping.** The playhead snapping logic
  in `FFAnchoredTimelineModule` and the timeline scrubbing path don't call the helper.
- **Slip / slide edits.** No constraint or limit haptic on slip/slide drags.
- **Magnetic snapping when moving a clip on the spine.** Clip *moves* don't trip
  the helper — the haptic in #3/#4 only covers edge trims/rolls. `setUseSnap:`
  toggles snapping behavior but doesn't add tactile feedback for clip-body moves.
- **Marker placement.** Adding/dragging a marker, even when it lands on an edit
  boundary, does not fire.
- **Beat-detection grid alignment.** No haptic when blading on a detected beat.
- **Range selection (I/O).** Marking In/Out has no haptic, even when it snaps to
  an edit point.
- **Touch Bar.** No `DFRTouchBar` / `NSTouchBar` haptic APIs are imported anywhere
  in the FCP binary.
- **Audio meter peaks, render completion, or any "notification" event.** FCP only
  uses haptics for direct manipulation feedback.
- **Inspector slider detents** (focal length, opacity 100%, volume 0 dB, etc.).
  Even though these are visual detents, no haptic is fired.

## Why "alignment" specifically

`NSHapticFeedbackPatternAlignment` is documented by Apple as "the user is moving an
object and it has aligned to something". FCP uses it for *every* haptic — including
the J/K/L pressure clicks, where one might have expected `…LevelChangePattern`. The
choice means all FCP haptics feel identical: a single light tap, never a
double-thump or escalating pattern.

## Hardware/system requirements summary

| Requirement | Notes |
|---|---|
| Force Touch trackpad | Built-in 2015+ MacBook Pros, Magic Trackpad 2+, etc. The `defaultPerformer` returns `nil` and the call is a no-op on machines without one. |
| `System Settings → Trackpad → Force Click and haptic feedback` ON | If the user disables this, the OS suppresses all four FCP haptics. |
| External mice | No haptics, ever — even a Magic Mouse. |
| Touch Bar | Touch Bar buttons that mirror transport controls do **not** fire haptics; only the on-screen buttons hit `FFTransportLongPressButton`. |

## Reverse-engineering recipe (for SpliceKit)

If you want to extend FCP with new haptics from a SpliceKit plugin, do not try to
swizzle the helper or look it up by symbol — it's only resolvable via dyld inside
LunaKit. Just call AppKit directly:

```objc
[[NSHapticFeedbackManager defaultPerformer]
    performFeedbackPattern:NSHapticFeedbackPatternAlignment
           performanceTime:NSHapticFeedbackPerformanceTimeNow];
```

Use `NSHapticFeedbackPatternGeneric` (0) for "ack" events and
`NSHapticFeedbackPatternLevelChange` (2) for value-step events; FCP itself avoids
these but they're available system-wide. Coalesce close-spaced events with
`NSHapticFeedbackPerformanceTimeDefault` (0) instead of `…Now` (1) to let the OS
throttle them to a comfortable rate.

## Source map

| Symbol | Binary | Address |
|---|---|---|
| `_LKPerformAlignmentFeedbackPatternNow` | LunaKit | `0xDFE60` |
| `_LKCreatePressureConfigurationWithPressureBehaviour` | LunaKit | `0xDFEE0` |
| `-[FFSnapGridOSC addDrawProperties:forTime:forContainer:viewBounds:]_block_invoke` | Flexo | `0x6D6480` |
| `-[FFAnchoredTimelineModule _acceptDrop:onItem:dropTime:dropHighlight:error:]` | Flexo | `0x9B41D0` |
| `-[FFTransportLongPressButton mouseDown:]_block_invoke` | Flexo | `0x7C2250` |
| `-[FFTransportLongPressButton updateTrackingAreas]` | Flexo | `0x7C1F80` |
| `-[TLKDragEdgesHandler _moveEdgeByTimeOffset:]` | TimelineKit | `0x1B13E` |
| `-[TLKDragEdgesHandler _timeOffsetForMovingEdgeToPoint:]` | TimelineKit | `0x1D2C0` |

(Addresses are in-binary; add the runtime ASLR slide for the loaded image to map
to live memory.)
