# FCPBridge - Programmatic Final Cut Pro Control

FCPBridge is an ObjC dylib injected into FCP's process. It exposes all 78,000+ ObjC classes
via a JSON-RPC server on TCP 127.0.0.1:9876. Everything is fully programmatic -- no AppleScript,
no UI automation, no menu clicks.

## Quick Start

```
1. bridge_status()                    -- verify connection
2. get_timeline_clips()               -- see timeline contents
3. timeline_action("blade")           -- edit
4. verify_action("after blade")       -- confirm
```

## CRITICAL: Must Know Before Editing

### Opening a Project
If `get_timeline_clips()` returns an error about "no sequence", load a project:
```python
# Navigate: library -> sequences -> find one with content -> load it
libs = call_method_with_args("FFLibraryDocument", "copyActiveLibraries", "[]", true, true)
lib = call_method_with_args(libs_handle, "objectAtIndex:", '[{"type":"int","value":0}]', false, true)
seqs = call_method_with_args(lib_handle, "_deepLoadedSequences", "[]", false, true)
allSeqs = call_method_with_args(seqs_handle, "allObjects", "[]", false, true)
# Check each: call_method_with_args(seq_handle, "hasContainedItems", "[]", false)
# Load: get NSApp -> delegate -> activeEditorContainer -> loadEditorForSequence:
```

### Select Before Acting
Color correction, retiming, titles, and effects require a selected clip:
```
playback_action("goToStart")              # position
playback_action("nextFrame") x N          # navigate
timeline_action("selectClipAtPlayhead")   # select
timeline_action("addColorBoard")          # now apply
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
| Markers | addMarker, addTodoMarker, addChapterMarker, deleteMarker, nextMarker, previousMarker |
| Transitions | addTransition |
| Navigation | nextEdit, previousEdit, selectClipAtPlayhead, selectToPlayhead |
| Selection | selectAll, deselectAll |
| Edit | delete, cut, copy, paste, undo, redo |
| Insert | insertGap |
| Trim | trimToPlayhead |
| Color | addColorBoard, addColorWheels, addColorCurves, addColorAdjustment, addHueSaturation, addEnhanceLightAndColor |
| Volume | adjustVolumeUp, adjustVolumeDown |
| Titles | addBasicTitle, addBasicLowerThird |
| Speed | retimeNormal, retimeFast2x/4x/8x/20x, retimeSlow50/25/10, retimeReverse, retimeHold, freezeFrame, retimeBladeSpeed |
| Keyframes | addKeyframe, deleteKeyframes, nextKeyframe, previousKeyframe |
| Other | solo, disable, createCompoundClip, autoReframe, exportXML, shareSelection |

## Playback Actions
playPause, goToStart, goToEnd, nextFrame, prevFrame, nextFrame10, prevFrame10

## Common Workflows

### Blade at a specific time
```
playback_action("goToStart")
batch_timeline_actions('[{"type":"playback","action":"nextFrame","repeat":72}]')  # 3s at 24fps
timeline_action("blade")
```

### Multiple cuts
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

### Text-based editing via transcript
```
open_transcript()                              # transcribe all clips on timeline
open_transcript(file_url="/path/to/video.mp4") # transcribe a specific file
get_transcript()                               # get words with timestamps
delete_transcript_words(start_index=5, count=3) # delete words 5-7 (removes video segment)
move_transcript_words(start_index=10, count=2, dest_index=3) # reorder clips
close_transcript()                             # close the panel
```

The transcript panel opens inside FCP as a floating window:
- Shows transcribed text with word-level timestamps and confidence scores
- Click a word to jump the playhead to that time
- Select words and press Delete to remove those video segments (ripple delete)
- Drag words to reorder clips on the timeline
- Current word is highlighted as playback progresses

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
- Also accessible via toolbar button or FCPBridge menu

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

## Discovering APIs
```
get_classes(filter="FFColor")                          # find classes
explore_class("FFAnchoredTimelineModule")              # full overview
search_methods("FFAnchoredTimelineModule", "blade")    # find methods
get_methods("FFEffectStack")                           # all methods
```

## Full API Reference
See `docs/FCP_API_REFERENCE.md` for comprehensive documentation of all key classes,
methods, properties, notifications, and patterns. This reference is sufficient to use
FCPBridge without access to the decompiled FCP source code.
