# SpliceKit - Programmatic Final Cut Pro Control

SpliceKit is an ObjC dylib injected into FCP's process. It exposes all 78,000+ ObjC classes
via a JSON-RPC server on TCP 127.0.0.1:9876. Everything is fully programmatic -- no AppleScript,
no UI automation, no menu clicks.

## NEVER Use Keyboard Simulation or AppleScript

All FCP actions MUST go through direct ObjC calls. Never use any of these:
- `SpliceKit_simulateKeyPress()` or synthetic NSEvent key events
- `CGEvent` keyboard/mouse posting
- `osascript` / `NSAppleScript` / AppleScript `tell application`
- Accessibility APIs (`AXUIElement`) for clicking or typing
- Frame-stepping loops (`nextFrame` x N) when `seekToTime` exists

**Instead, always use one of these patterns (in priority order):**
1. **Direct method call** on the timeline/sequence/clip object via `objc_msgSend`
2. **Responder chain** via `[NSApp sendAction:NSSelectorFromString(@"selector:") to:nil from:nil]`
3. **Batch bridge endpoint** (e.g. `timeline.addMarkers`) for operations on multiple items
4. **Menu execute** via `menu.execute` for actions only accessible through menus

If an action doesn't have a direct ObjC selector yet, find one using `explore_class` /
`search_methods` on the relevant class (FFAnchoredTimelineModule, FFAnchoredSequence, etc.)
rather than simulating the keyboard shortcut.

## Quick Start

```
1. bridge_status()                    -- verify connection
2. open_project("My Project")         -- open a project by name
3. get_timeline_clips()               -- see timeline contents
4. timeline_action("blade")           -- edit
5. verify_action("after blade")       -- confirm state changed
6. capture_timeline()                 -- visually verify the timeline
7. capture_viewer()                   -- visually verify the viewer/canvas
```

## CRITICAL: Must Know Before Editing

### Opening a Project
Use `open_project()` to load a project by name:
```python
open_project("My Project")                   # find by name
open_project("Edit v2", event="4-5-26")      # filter by event too
```

If you need lower-level control, you can still navigate manually:
```python
# Navigate: library -> sequences -> find one with content -> load it
libs = call_method_with_args("FFLibraryDocument", "copyActiveLibraries", "[]", true, true)
libs_handle = json.loads(libs)["handle"]
lib = call_method_with_args(libs_handle, "objectAtIndex:", '[{"type":"int","value":0}]', false, true)
lib_handle = json.loads(lib)["handle"]
seqs = call_method_with_args(lib_handle, "_deepLoadedSequences", "[]", false, true)
seqs_handle = json.loads(seqs)["handle"]
allSeqs = call_method_with_args(seqs_handle, "allObjects", "[]", false, true)
# For each sequence result, extract its "handle" before calling hasContainedItems
# Example: seq_handle = json.loads(seq)["handle"]
# Check each: call_method_with_args(seq_handle, "hasContainedItems", "[]", false)
# Load: get NSApp -> delegate -> activeEditorContainer -> loadEditorForSequence:
```

### Select Before Acting
Color correction, retiming, titles, and effects require a selected clip:
```
playback_action("goToStart")              # position
playback_action("nextFrame") x N          # navigate
timeline_action("selectClipAtPlayhead")   # select primary storyline clip
timeline_action("addColorBoard")          # now apply
```

To select a connected clip (title, B-roll, etc.) use `select_clip_in_lane()`:
```
select_clip_in_lane(lane=1)               # select connected clip above primary
select_clip_in_lane(lane=-1)              # select connected clip below
select_clip_in_lane(lane=0)               # same as selectClipAtPlayhead
```

### Playhead Positioning
- 1 frame = ~0.042s at 24fps, ~0.033s at 30fps
- Use `nextFrame` with repeat count for precise positioning
- `batch_timeline_actions` is fastest for multi-step sequences
- Always go to a known position (goToStart) before stepping

### Undo After Mistakes
```
timeline_action("undo")   # undoes last edit, returns action name
timeline_action("redo")   # redoes it
```
Undo routes through FCP's FFUndoManager (not the responder chain).

### Timeline Data Model (Spine)
FCP stores items in: `sequence -> primaryObject (FFAnchoredCollection) -> containedItems`
- `FFAnchoredMediaComponent` = video/audio clips
- `FFAnchoredTransition` = transitions (Cross Dissolve, etc.)
- `get_timeline_clips()` handles this automatically

## All Timeline Actions

| Category | Actions |
|----------|---------|
| Blade | blade, bladeAll |
| Markers | addMarker, addTodoMarker, addChapterMarker, deleteMarker, nextMarker, previousMarker, deleteMarkersInSelection |
| Transitions | addTransition |
| Navigation | nextEdit, previousEdit, selectClipAtPlayhead, selectToPlayhead |
| Selection | selectAll, deselectAll |
| Edit | delete, cut, copy, paste, undo, redo, pasteAsConnected, replaceWithGap, copyTimecode |
| Edit Modes | connectToPrimaryStoryline, insertEdit, appendEdit, overwriteEdit |
| Effects | pasteEffects, pasteAttributes, removeAttributes, copyAttributes, removeEffects |
| Insert | insertGap, insertPlaceholder, addAdjustmentClip |
| Trim | trimToPlayhead, extendEditToPlayhead, trimStart, trimEnd, joinClips, nudgeLeft, nudgeRight, nudgeUp, nudgeDown |
| Color | addColorBoard, addColorWheels, addColorCurves, addColorAdjustment, addHueSaturation, addEnhanceLightAndColor, balanceColor, matchColor, addMagneticMask, smartConform |
| Volume | adjustVolumeUp, adjustVolumeDown |
| Audio | expandAudio, expandAudioComponents, addChannelEQ, enhanceAudio, matchAudio, detachAudio |
| Titles | addBasicTitle, addBasicLowerThird |
| Speed | retimeNormal, retimeFast2x/4x/8x/20x, retimeSlow50/25/10, retimeReverse, retimeHold, freezeFrame, retimeBladeSpeed, retimeSpeedRampToZero, retimeSpeedRampFromZero |
| Keyframes | addKeyframe, deleteKeyframes, nextKeyframe, previousKeyframe |
| Rating | favorite, reject, unrate |
| Range | setRangeStart, setRangeEnd, clearRange, setClipRange |
| Clip Ops | solo, disable, createCompoundClip, autoReframe, breakApartClipItems, synchronizeClips, openClip, renameClip, addToSoloedClips, referenceNewParentClip, changeDuration |
| Storyline | createStoryline, liftFromPrimaryStoryline, overwriteToPrimaryStoryline, collapseToConnectedStoryline |
| Audition | createAudition, finalizeAudition, nextAuditionPick, previousAuditionPick |
| Captions | addCaption, splitCaption, resolveOverlaps |
| Multicam | createMulticamClip |
| Show/Hide | showVideoAnimation, showAudioAnimation, soloAnimation, showTrackingEditor, showCinematicEditor, showMagneticMaskEditor, enableBeatDetection, showPrecisionEditor, showAudioLanes, expandSubroles, showDuplicateRanges, showKeywordEditor |
| View | zoomToFit, zoomIn, zoomOut, verticalZoomToFit, zoomToSamples, toggleSnapping, toggleSkimming, toggleClipSkimming, toggleAudioSkimming, toggleInspector, toggleTimeline, toggleTimelineIndex, toggleInspectorHeight, beatDetectionGrid, timelineScrolling, enterFullScreen, timelineHistoryBack, timelineHistoryForward |
| Project | duplicateProject, snapshotProject, projectProperties |
| Library | closeLibrary, libraryProperties, consolidateEventMedia, mergeEvents, deleteGeneratedFiles |
| Render | renderSelection, renderAll |
| Export | exportXML, shareSelection |
| Find | find, findAndReplaceTitle |
| Reveal | revealInBrowser, revealProjectInBrowser, revealInFinder, moveToTrash |
| Keywords | showKeywordEditor, removeAllKeywords, removeAnalysisKeywords |
| Other | analyzeAndFix, backgroundTasks, recordVoiceover, editRoles, hideClip, addVideoGenerator |

## Playback Actions
playPause, goToStart, goToEnd, nextFrame, prevFrame, nextFrame10, prevFrame10, playAroundCurrent

## New: Universal Menu Access
```
execute_menu_command(["File", "New", "Project"])     # any menu item
execute_menu_command(["Modify", "Balance Color"])     # color correction
execute_menu_command(["View", "Playback", "Loop"])    # toggle loop
list_menus(menu="File")                               # discover menu items
list_menus(menu="Modify", depth=3)                    # see nested submenus
```

## New: Inspector Properties
```
get_inspector_properties()                    # read all properties of selected clip
get_inspector_properties("transform")         # just transform (position, rotation, scale)
get_inspector_properties("compositing")       # opacity, blend mode
set_inspector_property("opacity", 0.5)        # set opacity to 50%
set_inspector_property("volume", -6.0)        # set audio volume
set_inspector_property("positionX", 100.0)    # move clip position
```

## New: Panel/View Toggles
```
toggle_panel("videoScopes")          # show/hide video scopes
toggle_panel("inspector")            # toggle inspector
toggle_panel("effectsBrowser")       # effects browser
set_workspace("colorEffects")        # switch workspace layout
```

## New: Tool Selection
```
select_tool("blade")     # switch to blade tool
select_tool("trim")      # switch to trim tool
select_tool("range")     # switch to range selection
select_tool("transform") # switch to transform tool
```

## New: Roles & Export
```
assign_role("audio", "Dialogue")     # assign audio role
assign_role("video", "Titles")       # assign video role
share_project("Export File")         # export with specific destination
share_project()                      # export with default destination
create_project()                     # create new project
create_event()                       # create new event
create_library()                     # create new library
```

## Common Workflows

### Blade at a specific time
```
seek_to_time(3.0)         # jump to 3 seconds
timeline_action("blade")  # cut there
```

### Multiple cuts (batch — preferred)
```
blade_at_times([3.0, 6.0, 9.0, 12.0, 15.0])   # cut at all times in one call
```

### Cuts at regular intervals across entire timeline
```
# Compute times: every 3s across a 30s timeline
blade_at_times([3.0, 6.0, 9.0, 12.0, 15.0, 18.0, 21.0, 24.0, 27.0])
```

### Multiple cuts (batch_timeline_actions alternative)
```
batch_timeline_actions('[
  {"type":"playback","action":"goToStart"},
  {"type":"playback","action":"nextFrame","repeat":48},
  {"type":"timeline","action":"blade"},
  {"type":"playback","action":"nextFrame","repeat":48},
  {"type":"timeline","action":"blade"},
  {"type":"playback","action":"nextFrame","repeat":48},
  {"type":"timeline","action":"blade"}
]')
```

### Add color correction
```
playback_action("goToStart")
timeline_action("selectClipAtPlayhead")
timeline_action("addColorBoard")
```

### Change speed
```
timeline_action("selectClipAtPlayhead")
timeline_action("retimeSlow50")    # 50% speed
# Undo: timeline_action("undo")
```

### Add markers at intervals
```
playback_action("goToStart")
batch_timeline_actions('[
  {"type":"playback","action":"nextFrame","repeat":120},
  {"type":"timeline","action":"addMarker"},
  {"type":"playback","action":"nextFrame","repeat":120},
  {"type":"timeline","action":"addChapterMarker"}
]')
```

### Create project via FCPXML (no restart)
```
xml = generate_fcpxml(
    project_name="My Project",
    frame_rate="24",
    items='[
      {"type":"gap","duration":10},
      {"type":"title","text":"Introduction","duration":5},
      {"type":"transition","duration":1},
      {"type":"gap","duration":15},
      {"type":"marker","time":5,"name":"Chapter 1","kind":"chapter"}
    ]'
)
import_fcpxml(xml, internal=True)
```

### Inspect clip effects
```
timeline_action("selectClipAtPlayhead")
get_clip_effects()  # shows effect names, IDs, handles
```

### Analyze timeline health
```
analyze_timeline()  # pacing, flash frames, clip stats
```

### Batch export clips individually
```
batch_export()                    # export all clips using default share destination
batch_export(scope="selected")    # export only selected clips
```

Each clip is exported individually with all effects/color grading baked in.
For each clip, SpliceKit:
1. Computes the clip's exact position in the timeline
2. Sets the in/out range (mark in/out) to the clip boundaries
3. Triggers FCP's share dialog — click "Share" to confirm

Set your default share destination in FCP first (File > Share > Add Destination).

### Set in/out range programmatically
```
set_timeline_range(start_seconds=5.0, end_seconds=10.0)  # mark in at 5s, out at 10s
timeline_action("setRangeStart")   # mark in at current playhead
timeline_action("setRangeEnd")     # mark out at current playhead
timeline_action("clearRange")      # remove range selection
```

### Text-based editing via transcript
```
open_transcript()                              # transcribe all clips on timeline
open_transcript(file_url="/path/to/video.mp4") # transcribe a specific file
get_transcript()                               # get words with timestamps + speakers + silences
delete_transcript_words(start_index=5, count=3) # delete words 5-7 (removes video segment)
move_transcript_words(start_index=10, count=2, dest_index=3) # reorder clips
search_transcript("hello")                     # search for text in transcript
search_transcript("pauses")                    # find all silences/pauses
delete_transcript_silences()                   # batch-remove all silences from timeline
delete_transcript_silences(min_duration=1.0)   # remove only silences > 1 second
set_transcript_speaker(start_index=0, count=50, speaker="Host")  # label speakers
set_silence_threshold(threshold=0.5)           # set minimum pause detection (seconds)
close_transcript()                             # close the panel
```

The transcript panel opens inside FCP as a floating window with an **engine selector dropdown**:
- **Parakeet v3** (default) — NVIDIA Parakeet TDT 0.6B multilingual (25 languages), on-device via FluidAudio
- **Parakeet v2** — English-optimized variant, same speed
- **Apple Speech** — SFSpeechRecognizer (slower, network-capable)
- **FCP Native** — Built-in AASpeechAnalyzer

All clips are transcribed in a single batch process (model loaded once, reused across clips).
Speaker diarization is available with Parakeet engines (checkbox in UI).

Panel features:
- Shows transcribed text grouped by **speaker segments** with timecode ranges (HH:MM:SS:FF)
- **Silence markers** `[...]` shown inline between words where pauses are detected
- Click a word to jump the playhead to that time
- Click a silence marker to jump to that pause
- Select words and press Delete to remove those video segments (ripple delete)
- Select silence markers and press Delete to remove pauses
- Drag words to reorder clips on the timeline
- Current word is highlighted as playback progresses
- **Search bar** with text search and filter by Pauses or Low Confidence
- **Batch operations**: Delete all search results or delete all silences
- Result count with prev/next navigation (Cmd+F to focus search)

Deleting words performs: blade at start -> blade at end -> select segment -> delete
Moving words performs: blade + cut at source -> move playhead -> paste at destination

## Transitions
```
list_transitions()                             # list all 376+ available transitions
list_transitions(filter="dissolve")            # filter by name or category
apply_transition(name="Flow")                  # apply by display name
apply_transition(name="Cross Dissolve")        # apply specific transition
apply_transition(effectID="HEFlowTransition")  # apply by effect ID
```

Transitions are applied at the current edit point. Navigate to an edit point first:
```
timeline_action("nextEdit")           # go to next edit point
apply_transition(name="Flow")         # apply Flow transition there
```

### Freeze Extend (not enough media handles)
When clips don't have enough extra media beyond their edges for a transition, FCP normally
shows a dialog offering to ripple trim. SpliceKit adds a third option: **"Use Freeze Frames"**.

- **UI button**: Whenever the "not enough extra media" dialog appears (including manual use),
  a "Use Freeze Frames" button is added. It extends clip edges with freeze frames and
  re-applies the transition without shortening the project.
- **API parameter**: Use `freeze_extend=True` to automatically extend with freeze frames:
```
apply_transition(name="Cross Dissolve", freeze_extend=True)  # auto freeze-extend if needed
```

This creates freeze frames at the outgoing clip's last frame and the incoming clip's first
frame, providing the media handles needed for the transition overlap.

## Command Palette
```
show_command_palette()                         # open the palette (or Cmd+Shift+P)
search_commands("blade")                       # find commands by name/keyword
execute_command("blade", type="timeline")      # run a command directly
ai_command("slow this clip to half speed")     # natural language via Apple Intelligence
hide_command_palette()                         # close it
```

The command palette opens as a floating window inside FCP:
- Fuzzy search across all available actions (editing, playback, color, speed, markers, etc.)
- Arrow keys to navigate, Return to execute, Escape to close
- Type natural language sentences and press Tab to ask Apple Intelligence
- Falls back to keyword matching when Apple Intelligence is unavailable
- Also accessible via toolbar button or Enhancements menu

## Playhead & Selection
```
get_playhead_position()              # current time, duration, frame rate, playing state
get_selected_clips()                 # get only selected clips in timeline
seek_to_time(3.5)                    # jump to 3.5 seconds instantly (faster than stepping)
```

## Screenshots & Visual Verification

Use `capture_viewer()` and `capture_timeline()` to take screenshots of FCP without
bringing it to the foreground. These capture GPU/Metal content directly — no `screencapture`
needed. The resulting PNGs can be read by Claude to visually verify edits.

**When to use:**
- After applying effects, color corrections, titles, or captions → `capture_viewer()`
- After blade cuts, rearranging clips, adding markers, or any timeline edit → `capture_timeline()`
- When debugging layout issues (clip positions, gaps, transitions) → `capture_timeline()`
- When verifying text rendering (font, size, position) → `capture_viewer()`

```
capture_viewer()                     # screenshot viewer to /tmp/splicekit_viewer.png
capture_viewer(path="/tmp/check.png") # screenshot to custom path
capture_timeline()                   # screenshot timeline to /tmp/splicekit_timeline.png
capture_timeline(path="/tmp/tl.png") # screenshot to custom path
```

## Viewer Zoom
```
get_viewer_zoom()                    # current zoom level (0.0=Fit, 1.0=100%, 2.0=200%)
set_viewer_zoom(0.0)                 # fit to window
set_viewer_zoom(1.0)                 # 100%
set_viewer_zoom(2.0)                 # 200% — any float value accepted
```

## Export FCPXML (No Dialog)
```
export_xml()                                       # export to /tmp/splicekit_export.fcpxml
export_xml(path="/tmp/my_project.fcpxml")           # export to custom path
```
Programmatic export — no save dialog. Returns the FCPXML file path.

## Deploy & Restart FCP
```
deploy_and_restart()                 # build, deploy, kill FCP, relaunch, wait for bridge
deploy_and_restart(skip_build=True)  # just restart FCP (skip make deploy)
```

## Dialog Automation
**Note:** The "video properties of this clip are not recognized" dialog is now
auto-dismissed at the start of every bridge request. No manual handling needed.
```
detect_dialog()                      # scan for open dialogs, see buttons/fields/checkboxes
click_dialog_button(button="OK")     # click by title (case-insensitive, partial match)
click_dialog_button(index=0)         # click by index
fill_dialog_field(value="My Project") # fill text field
toggle_dialog_checkbox("Use custom settings", checked=True)
select_dialog_popup(select="4K")     # choose from dropdown
dismiss_dialog(action="default")     # click default button to close
dismiss_dialog(action="cancel")      # cancel/escape
```

## Scene Detection
```
detect_scene_changes()                              # list scene change timestamps
detect_scene_changes(threshold=0.2)                 # more sensitive
detect_scene_changes(action="markers")              # add markers at cuts
detect_scene_changes(action="blade")                # blade at every scene change
detect_scene_changes(threshold=0.5, sample_interval=0.25) # less sensitive, faster
```

## Beat Detection
```
detect_beats(file_path="/path/to/song.mp3")         # detect beats, bars, sections, BPM
detect_beats(file_path="song.mp3", sensitivity=0.8) # more sensitive
detect_beats(file_path="song.mp3", min_bpm=120, max_bpm=180) # for fast music
```
Build first: `swiftc -O -o build/beat-detector tools/beat-detector.swift`

## SRT Import
```
import_srt_as_markers(srt_content="1\n00:00:05,000 --> 00:00:10,000\nSubtitle text")
```

## SpliceKit Options
```
get_bridge_options()                                # see all configurable options
set_bridge_option("effectDragAsAdjustmentClip", True)   # drag effects to create adjustment clips
set_bridge_option("viewerPinchZoom", True)              # trackpad pinch-to-zoom on viewer
set_bridge_option("videoOnlyKeepsAudioDisabled", True)  # keep audio disabled in video-only mode
set_bridge_option("suppressAutoImport", True)           # stop auto-opening Import window on card/camera mount
set_bridge_option_value("defaultSpatialConformType", "fill")  # default new clips to Fill (crop to fill frame)
set_bridge_option_value("defaultSpatialConformType", "none")  # default new clips to None (native resolution)
set_bridge_option_value("defaultSpatialConformType", "fit")   # restore FCP default (Fit)
```

## Object Handles
```
# Get a handle to an object
r = call_method_with_args("FFLibraryDocument", "copyActiveLibraries", "[]", true, true)
# r = {"handle": "obj_1", "class": "__NSArrayM", ...}

# Use handle in subsequent calls
call_method_with_args("obj_1", "objectAtIndex:", '[{"type":"int","value":0}]', false, true)

# Read properties via KVC
get_object_property("obj_2", "displayName")

# Always clean up
manage_handles(action="release_all")
```

Argument types: string, int, double, float, bool, nil, sender, handle, cmtime, selector

## Error Recovery
- "No active timeline module" -> No project open. Load one (see above).
- "No sequence in timeline" -> Same. Need loadEditorForSequence:.
- "Cannot connect" -> FCP not running. Launch it.
- "Handle not found" -> Released or GC'd. Get a fresh reference.
- "No responder handled X" -> Action not available (wrong state or no selection).
- Broken pipe -> Stale connection. Next call auto-reconnects.

## Key Classes
| Class | Use |
|-------|-----|
| FFAnchoredTimelineModule | Timeline editing (1435 methods) |
| FFAnchoredSequence | Timeline data model |
| FFAnchoredMediaComponent | Clips in timeline |
| FFAnchoredTransition | Transitions |
| FFLibrary / FFLibraryDocument | Library management |
| FFEditActionMgr | Edit commands |
| FFEffectStack | Effects on clips |
| PEAppController | App controller |
| PEEditorContainerModule | Editor/timeline modules |

## Discovering APIs (Runtime Introspection)
```
get_classes(filter="FFColor")                          # find classes by name
explore_class("FFAnchoredTimelineModule")              # full overview (methods, ivars, protocols)
search_methods("FFAnchoredTimelineModule", "blade")    # find methods by name
get_methods("FFEffectStack")                           # all instance + class methods with type encodings
get_ivars("FFPlayer")                                  # ivar names, types, byte offsets
get_properties("FFAnchoredSequence")                   # properties with parsed attributes
get_protocols("FFAnchoredMediaComponent")              # protocol conformances
get_superchain("FFAnchoredTimelineModule")             # inheritance chain to NSObject
```

Each method entry includes: selector name, ObjC type encoding, IMP hex address, owning
image (via dladdr), and linker symbol name. Ivar entries include byte offsets for struct
reconstruction.

## Debug & Diagnostics (FCP Internal Developer Tools)

SpliceKit exposes FCP's internal developer logging, debug overlays, and performance
monitoring tools that are normally hidden. These are built into FCP's own frameworks
(ProAppSupport, TimelineKit, Helium, ProCore) and controlled via NSUserDefaults and
CFPreferences keys.

### Quick Start
```
debug_get_config()                              # see all current debug settings
debug_enable_preset("timeline_visual")          # turn on visual debug overlays
debug_enable_preset("all_off")                  # reset everything to normal
```

### Get Current State
```
debug_get_config()
```
Returns the current value of every debug flag organized into four groups:
- **timeline_debug**: 35 TLKUserDefaults keys (visual overlays, logging, rendering)
- **cfpreferences_debug**: 6 CFPreferences keys (video decoder, frame drops, GPU)
- **proapp_log**: ProAppSupport structured log system (level, categories, UI, threads)
- **fcp_flags**: FCP behavioral overrides (gap coalescing, snapping, skimming)

### Set Individual Flags
```
debug_set_config("TLKShowHiddenGapItems", "true")       # show hidden gaps in timeline
debug_set_config("TLKPerformanceMonitorEnabled", "true") # enable perf monitor
debug_set_config("LogLevel", "trace")                    # most verbose logging
debug_set_config("VideoDecoderLogLevelInNLE", "3")       # video decoder verbosity
debug_set_config("GPU_LOGGING", "true")                  # GPU/FxPlug logging
debug_set_config("TLKShowHiddenGapItems", "false")       # turn it back off
```

TLK flags take effect immediately (TLKUserDefaults is reloaded live).
CFPreferences flags may require FCP restart for some subsystems.

### Presets (Enable Groups of Flags)
```
debug_enable_preset("timeline_visual")     # visual debug overlays
debug_enable_preset("timeline_logging")    # timeline subsystem logging
debug_enable_preset("performance")         # perf monitor + decoder/frame drop logging
debug_enable_preset("render_debug")        # disable rendering layers + GPU logging
debug_enable_preset("verbose_logging")     # trace-level logging + log UI + thread info
debug_enable_preset("all_off")             # reset all debug flags to defaults
```

**Preset details:**

| Preset | What it enables |
|--------|----------------|
| `timeline_visual` | Lane indices, misaligned edges, render bar, hidden gaps, invalid layouts, color-highlight changed objects |
| `timeline_logging` | Log layer changes, parts, reload requests, recycling, visible rect changes, segmentation stats |
| `performance` | TLK performance monitor, VideoDecoderLogLevelInNLE=2, FrameDropLogLevel=2 |
| `render_debug` | Disable filmstrip/background/waveform rendering, enable GPU logging (isolate render issues) |
| `verbose_logging` | LogLevel=trace, LogUI=true, LogThread=true, EnableScheduledReadAudioLogging=true |
| `all_off` | Remove all debug flags, reset CFPreferences, clear log settings |

### Framerate Monitor
```
debug_start_framerate_monitor(2.0)   # log fps every 2 seconds
debug_stop_framerate_monitor()       # stop monitoring
```
Uses FCP's built-in HMDFramerate (ProCore). Reports to system log:
- Overall fps
- Average getFrame() call time in ms
- Min/max frame times

View output: `log stream --process "Final Cut Pro"` or Console.app

### Reset
```
debug_reset_config("all")       # reset everything
debug_reset_config("tlk")       # reset timeline flags only
debug_reset_config("cfprefs")   # reset CFPreferences only
debug_reset_config("log")       # reset ProAppSupport log settings only
```

### All Available Debug Keys

**Timeline visual overlays** (TLK*):
| Key | Effect |
|-----|--------|
| TLKShowItemLaneIndex | Show lane index number on each timeline item |
| TLKShowMisalignedEdges | Highlight misaligned edges between items |
| TLKShowRenderBar | Show render status bar overlay |
| TLKShowHiddenGapItems | Reveal hidden gap items in timeline |
| TLKShowHiddenItemHeaders | Reveal hidden item headers |
| TLKShowInvalidLayoutRects | Highlight invalid layout rectangles |
| TLKShowContainerBounds | Show container bounds |
| TLKShowContentLayers | Show content layer boundaries |
| TLKShowRulerBounds | Show ruler bounds overlay |
| TLKShowUsedRegion | Show used region overlay |
| TLKShowZeroHeightSpineItems | Show zero-height spine items |

**Timeline logging** (TLK*):
| Key | What it logs |
|-----|-------------|
| TLKLogVisibleLayerChanges | Changes to visible layers |
| TLKLogParts | Timeline parts lifecycle |
| TLKLogReloadRequests | Reload/refresh requests |
| TLKLogRecyclingLayerChanges | Layer recycling events |
| TLKLogVisibleRectChanges | Visible rect geometry changes |
| TLKLogSegmentationStatistics | Segmentation statistics |

**Timeline performance/rendering** (TLK* and Debug*):
| Key | Effect |
|-----|--------|
| TLKPerformanceMonitorEnabled | Enable timeline performance monitoring |
| TLKDebugColorChangedObjects | Color-highlight changed objects after updates |
| TLKDebugLayoutConstraints | Debug layout constraint resolution |
| TLKDebugErrorsAndWarnings | Show errors and warnings visually |
| TLKDisableItemContents | Disable all item content rendering |
| DebugKeyItemVideoFilmstripsDisabled | Disable video filmstrip thumbnails |
| DebugKeyItemBackgroundDisabled | Disable item background rendering |
| DebugKeyItemAudioWaveformsDisabled | Disable audio waveform rendering |

**Video/audio/GPU logging** (CFPreferences):
| Key | Type | Effect |
|-----|------|--------|
| VideoDecoderLogLevelInNLE | int | Video decoder verbosity (0=off, higher=more) |
| FrameDropLogLevel | int | Frame drop reporting (0=off, higher=more) |
| GPU_LOGGING | bool | GPU/FxPlug pipeline logging |
| EnableScheduledReadAudioLogging | bool | Audio scheduled read logging |
| EnableLibraryUpdateHistoryValidation | bool | Library update history validation |
| FFVAMLSaveTranscription | bool | Save transcription data to disk |

**ProAppSupport log system**:
| Key | Values | Effect |
|-----|--------|--------|
| LogLevel | trace, debug, info, warning, error, failure | Set minimum log level |
| LogUI | bool | Toggle in-app log viewer panel |
| LogThread | bool | Include thread info in log output |
| LogCategory | bitmask | Filter by subsystem category |

Log categories: dev, player, sequenceEditor, camera, inspector, director,
voiceover, selection, network, theme, share, analysisKit, backgroundTasks,
angleEditor, lessons, onboarding, userNotifications, ui, all

**FCP behavior overrides**:
| Key | Effect |
|-----|--------|
| FFDontCoalesceGaps | Prevent automatic gap coalescing in timeline |
| FFDisableSnapping | Disable magnetic snapping |
| FFDisableSkimming | Disable clip skimming |

### How Debug Tools Help

**Diagnosing timeline layout issues**: Enable `timeline_visual` preset to see lane
indices, hidden gaps, misaligned edges, and invalid layout rects. This reveals
structural problems invisible in the normal UI.

**Performance troubleshooting**: Enable `performance` preset + `debug_start_framerate_monitor()`
to measure actual rendering fps and identify bottlenecks. Video decoder and frame drop
logging pinpoint decode pipeline issues.

**Render pipeline isolation**: The `render_debug` preset disables filmstrips, backgrounds,
and waveforms independently, letting you isolate which rendering subsystem is causing
problems. GPU logging captures the FxPlug/shader pipeline.

**Verbose logging for development**: The `verbose_logging` preset sets ProAppSupport to
trace level with the log UI enabled, giving maximum visibility into FCP's internal
operations. Useful when developing new SpliceKit features or investigating FCP behavior.

**Understanding timeline internals**: `TLKShowHiddenGapItems` and `TLKShowZeroHeightSpineItems`
reveal items FCP hides from the user, helping understand the true timeline data model.

## Runtime Metadata Export (for IDA Pro & Reverse Engineering)

Extract rich ObjC runtime metadata from the live FCP process — data that static binary
analysis cannot provide. Used to enrich IDA Pro decompilation and build the 303K-function
decompiled codebase.

### Bulk Class Metadata Export
```
dump_runtime_metadata(binary="Flexo")              # full metadata for all Flexo classes
dump_runtime_metadata(binary="Flexo", classes_only=True)  # just class names (fast)
dump_runtime_metadata()                             # all images (large!)
```

Returns per class:
- **Instance & class methods** with selector, type encoding, IMP address, **dladdr info**
  (which binary owns the IMP — reveals category methods from other frameworks)
- **Ivars** with name, type encoding, and **byte offset** (for struct reconstruction)
- **Ivar layout bitmaps** — which ivars are strong vs weak references
- **Protocol conformances** with **full method declarations** (required/optional,
  instance/class, type encodings) and protocol inheritance chains
- **Parsed property attributes** — type, getter/setter selectors, backing ivar,
  readonly/copy/strong/weak/nonatomic/dynamic (structured, not raw attribute strings)
- **Superclass chain** and **instance size**

### Loaded Image Enumeration
```
list_loaded_images()                     # all 1255 loaded Mach-O images
list_loaded_images(filter="Flexo")       # filter by name
```
Returns path, base address, ASLR slide, and ObjC class count per image.
The ASLR slide is needed to map runtime IMP addresses → IDA static addresses.

### Mach-O Section Data
```
get_image_sections(binary="Flexo")       # selector refs, class refs
```
Returns:
- **Selector references** — every ObjC selector the binary calls (44K+ for Flexo)
- **Class references** — which classes the binary references
- **Superclass references** — parent class dependencies

For shared-cache system frameworks, uses ObjC runtime APIs instead of raw section reads.

### Symbol Discovery with Swift Demangling
```
get_image_symbols(binary="Flexo", filter="Timeline")   # filtered
get_image_symbols(binary="TimelineKit")                 # all symbols
```
Discovers exported symbols via dladdr on all methods. Swift symbols are automatically
demangled using `swift_demangle()` from libswiftCore.

### Notification Name Discovery
```
get_notification_names(binary="Flexo")   # notification-related classes & symbols
```
Finds classes with "Notification" in their name and enumerates their methods.
Also resolves well-known notification name constants (e.g., `FFEffectsChangedNotification`).

### IDA Pro Integration Scripts
The `tools/` directory contains scripts for applying runtime metadata to IDA Pro:

```bash
# Step 1: Export runtime metadata from live FCP
python3 tools/fcp_runtime_export.py --binary Flexo -o ida_export

# Step 2: Run IDA headless with metadata enrichment + decompile
RUNTIME_JSON=ida_export/Flexo.json DECOMPILE_OUTPUT_DIR=output \
  idat -A -S"tools/ida_apply_and_decompile.py" /path/to/Flexo
```

**What the IDA script does:**
1. Declares struct types from ivars with correct offsets and typed members
2. Registers types in IDA's local type library (persists across sessions)
3. Renames functions to ObjC names (`sub_XXXX` → `-[FFPlayer play]`)
4. Sets function prototypes with typed parameters
5. Adds class hierarchy and protocol conformance comments
6. Creates enums for known constant sets
7. Triggers type propagation across the entire binary

**Tools:**
- `tools/fcp_runtime_export.py` — Collection script (connects to SpliceKit, dumps JSON per binary)
- `tools/ida_apply_and_decompile.py` — IDAPython headless script (applies metadata + decompiles)
- `tools/ida_objc_types.py` — ObjC type encoding parser (converts `@"NSArray"` → `NSArray *`)
- `tools/ida_import_runtime.py` — Interactive IDAPython script (for use inside IDA GUI)
- `tools/batch_enhanced_decompile.sh` — Batch process all 53 FCP binaries

## In-Process Debugging (Debugger Parity)

SpliceKit includes a full debugging toolkit that provides Xcode/lldb-level capabilities
from within FCP's process, accessible via MCP. No debugger attachment required.

### Breakpoints (pause + inspect + continue)
```
debug.breakpoint(action="add", className="FFAnchoredTimelineModule", selector="blade:")
# ... press B in FCP — execution pauses, breakpoint.hit event fires ...
debug.breakpoint(action="inspect")                                    # see paused state
debug.breakpoint(action="inspectSelf", keyPath="sequence.displayName") # inspect properties
debug.breakpoint(action="continue")                                   # resume execution
debug.breakpoint(action="step")                                       # resume + break on next call
```
Supports conditional breakpoints (`condition="keyPath"`), hit counts (`hitCount=5`),
and one-shot breakpoints (`oneShot=True`). FCP freezes while paused (same as Xcode).
The JSON-RPC server stays alive on a separate thread so you can inspect state.

### Method Tracing (non-blocking alternative)
```
debug.traceMethod(action="add", className="FFAnchoredTimelineModule",
                  selector="blade:", logStack=True)
# ... perform action in FCP ...
debug.traceMethod(action="getLog", limit=10)  # see calls + call stacks
debug.traceMethod(action="removeAll")          # clean up
```
Traces are broadcast to MCP clients in real-time as JSON-RPC notifications.
Use tracing when you want to observe without pausing, breakpoints when you need
to inspect state at a specific moment.

### Property Watching (replaces watchpoints)
```
debug.watch(action="add", className="NSApplication", keyPath="mainWindow")
# Events broadcast when property changes with old/new values
debug.watch(action="removeAll")
```

### Crash Handler (replaces debugger crash catching)
```
debug.crashHandler(action="install")   # catch exceptions + signals
debug.crashHandler(action="getLog")    # see crash stack traces
```
Catches NSExceptions and signals (SIGABRT, SIGSEGV, etc.) with full stack traces.

### Thread Inspection
```
debug.threads()                    # thread count, operation queues
debug.threads(detailed=True)       # per-thread CPU usage, run state, stacks
```
Uses Mach kernel APIs. Shows all ~45 threads with CPU usage percentages.

### Expression Evaluation (replaces lldb `po`)
```
debug.eval(expression="NSApp.delegate._targetLibrary.displayName")
debug.eval(chain=["delegate", "_targetLibrary"], storeResult=True)
```
Walks ObjC property chains. Stores results as handles for further inspection.

### Hot Plugin Loading (replaces dlopen from lldb)
```
debug.loadPlugin(action="load", path="/tmp/patch.dylib")   # inject code
debug.loadPlugin(action="unload", path="/tmp/patch.dylib")  # remove it
```
Compile a `.dylib` with fixes/features, load into running FCP without restart.

### Notification Observation
```
debug.observeNotification(action="add", name="FFEffectsChangedNotification")
debug.observeNotification(action="add", name="*")  # all notifications (high volume)
debug.observeNotification(action="removeAll")
```
Subscribe to FCP's internal NSNotification events. Broadcast to MCP clients.

## Direct Timeline Actions (`timeline.directAction`)

Calls Flexo's parameterized `action*` methods directly on FFAnchoredTimelineModule
with real arguments. More powerful than the simple responder-chain `timeline.action`.

### Retiming (direct control)
```
timeline.directAction(action="retimeSetRate", rate=0.5, ripple=True)
timeline.directAction(action="retimeSpeedRamp", toZero=True)
timeline.directAction(action="retimeInstantReplay", rate=0.5, addTitle=True)
timeline.directAction(action="retimeJumpCut", framesToJump=5)
timeline.directAction(action="retimeRewind", speed=2.0)
timeline.directAction(action="insertFreezeFrame")
```

### Markers (programmatic manipulation)
```
timeline.directAction(action="changeMarkerType", type="chapter")
timeline.directAction(action="changeMarkerName", name="Intro", marker="obj_5")
timeline.directAction(action="markMarkerCompleted", completed=True)
```

### Audio (precise control)
```
timeline.directAction(action="changeAudioVolume", amount=-6.0, relative=True)
timeline.directAction(action="applyAudioFadesDirect", fadeIn=True, duration=0.5)
timeline.directAction(action="setBackgroundMusic", enabled=True)
```

### Other direct actions
```
timeline.directAction(action="addKeywords", keywords=["Interview", "B-Roll"])
timeline.directAction(action="removeEffectByID", effectID="HEFlowTransition")
timeline.directAction(action="renameAngle", name="Camera 2")
timeline.directAction(action="newProject", name="My Project")
timeline.directAction(action="alignToMusicMarkers")
timeline.directAction(action="duplicateCaptions", language="es", format="SRT")
```

### Raw selector fallback
```
timeline.directAction(selector="actionValidateAndRepair:validateMode:error:")
```

See `docs/DEBUG_TOOLS_GUIDE.md` for comprehensive documentation of all debug
endpoints, parameters, workflows, and recipes.

## Full API Reference
See `docs/FCP_API_REFERENCE.md` for comprehensive documentation of all key classes,
methods, properties, notifications, and patterns. This reference is sufficient to use
SpliceKit without access to the decompiled FCP source code.

## Social Media Captions
```
open_captions()                                    # open panel + transcribe timeline
open_captions(style="bold_pop")                    # open with preset style
get_caption_state()                                # check transcription progress + segments
get_caption_styles()                               # list all 13 style presets
set_caption_style(preset_id="neon_glow")           # apply a preset
set_caption_style(preset_id="bold_pop", font_size=80, position="center")  # customize
set_caption_grouping(mode="words", max_words=4)    # control word grouping
generate_captions(style="bold_pop")                # generate + paste to user's timeline
verify_captions()                                  # inspect titles to verify text/font
get_title_text()                                   # read text/font from selected title
export_captions_srt(path="/tmp/captions.srt")      # export SRT subtitles
export_captions_txt(path="/tmp/captions.txt")      # export plain text
```

Generates word-by-word highlighted, animated caption titles as FCPXML. The pipeline:
1. Imports FCPXML into a temp project (resolves Motion template)
2. Copies titles from temp project to clipboard (native format)
3. Pastes as connected storyline onto the user's actual timeline
4. Applies position offset via ObjC transform (not FCPXML adjust-transform)
5. Self-verifies: inspects first title's CHChannelText for text/font/size
6. Cleans up the temp project

No drag-and-drop, no dialogs, captions land directly on the user's timeline.

**Style presets** (13 built-in): `bold_pop`, `neon_glow`, `clean_minimal`, `handwritten`,
`gradient_fire`, `outline_bold`, `shadow_deep`, `karaoke`, `typewriter`, `bounce_fun`,
`subtitle_pro`, `social_bold`, `social_reels`

**Positions**: bottom (default lower third), center, top, custom

**Animations**: none, fade, pop, slide_up, typewriter, bounce

**Word grouping modes**: social (2-3 words, 0.5s silence break — best for TikTok/Reels),
words (max N per group), sentence (by punctuation), time (max seconds), chars (max characters)

Each caption is a `<title>` element with `<text-style>` attributes. Word-by-word
highlight uses multiple `<text-style>` refs per title — the active word gets the
highlight color, others get the base text color.

**Title text inspection**: `get_title_text()` reads text content, font family, font name,
and point size from the selected Motion title's CHChannelText channel. `verify_captions()`
walks connected titles on the timeline and checks text/fontSize against the expected style.

## Lua Scripting

SpliceKit embeds a Lua 5.4 VM directly in FCP's process. Scripts use the `sk`
module to control FCP with zero latency:

```lua
sk.blade()                          -- blade at playhead
sk.seek(5.0)                        -- jump to 5 seconds
sk.select_clip()                    -- select clip at playhead
sk.color_board()                    -- add color correction
local clips = sk.clips()           -- get timeline clips as Lua table
local pos = sk.position()          -- get playhead position
sk.rpc("effects.apply", {name = "Gaussian Blur"})  -- any RPC method
sk.eval("NSApp.delegate.className") -- ObjC runtime bridge
```

**Entry points:**
- REPL panel: Ctrl+Option+L (Enhancements > Lua REPL)
- Live coding: save .lua files to `~/Library/Application Support/SpliceKit/lua/auto/`
- JSON-RPC: `lua.execute`, `lua.executeFile`, `lua.reset`, `lua.getState`, `lua.watch`
- MCP tools: `lua_execute`, `lua_execute_file`, `lua_reset`, `lua_watch`, `lua_state`

See `docs/LUA_SDK_REFERENCE.md` for the full SDK with 25 sections, 140+ RPC methods,
and complete cookbook examples.

## Additional Documentation
- `docs/LUA_SDK_REFERENCE.md` — **Lua scripting SDK** (sk module, 120+ actions, ObjC bridge, live coding, cookbook)
- `docs/LUA_SCRIPTING_GUIDE.md` — **Lua scripting tutorial** (data model, patterns, modules, persistence, pipelines, annotated examples)
- `docs/TRANSCRIPT_EDITING_GUIDE.md` — Transcript-based editing (engines, silence removal, speakers)
- `docs/COMMAND_PALETTE_GUIDE.md` — Command palette & Apple Intelligence
- `docs/RUNTIME_INTROSPECTION_GUIDE.md` — ObjC runtime exploration & reverse engineering
- `docs/DIALOG_AUTOMATION_GUIDE.md` — Dialog detection & interaction
- `docs/SCENE_BEAT_DETECTION_GUIDE.md` — Scene change & beat detection
- `docs/FXPLUG_PLUGIN_GUIDE.md` — FxPlug 4 plugin development
- `docs/FCPXML_FORMAT_REFERENCE.md` — FCPXML interchange format
- `docs/WORKFLOW_EXTENSIONS_GUIDE.md` — Workflow Extensions (ProExtensionHost)
- `docs/CONTENT_EXCHANGE_GUIDE.md` — Content exchange mechanisms
- `docs/FLEXMUSIC_AND_MONTAGE_GUIDE.md` — FlexMusic & Montage Maker
- `docs/DEBUG_TOOLS_GUIDE.md` — In-process debugging (tracing, watching, crash handling, eval, hot-loading)
- `tools/fcp_runtime_export.py` — Export runtime metadata for IDA Pro (usage: `--help`)
- `tools/ida_apply_and_decompile.py` — IDAPython headless: apply metadata + decompile all functions
- `tools/batch_enhanced_decompile.sh` — Batch decompile all 53 FCP binaries with runtime enrichment
