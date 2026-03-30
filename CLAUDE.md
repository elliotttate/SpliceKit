# FCPBridge - Programmatic Final Cut Pro Control

## Architecture

FCPBridge is an ObjC dylib injected into FCP's process. It exposes the full ObjC runtime
(78,000+ classes) via a JSON-RPC server on TCP `127.0.0.1:9876`. The MCP server wraps this
into Claude-friendly tools.

## Workflow

### 1. Check connection
```
bridge_status()
```

### 2. Read timeline state
```
get_timeline_clips()     -- structured list of all clips with handles
get_selected_clips()     -- just the selection
verify_action("before")  -- snapshot for before/after comparison
```

### 3. Perform edits
```
timeline_action("blade")       -- blade at playhead
timeline_action("addMarker")   -- add marker
timeline_action("addTransition") -- add default transition
playback_action("goToStart")   -- navigate
playback_action("nextFrame")   -- step forward
```

### 4. Verify
```
verify_action("after")  -- compare with before snapshot
```

## Available Timeline Actions
blade, bladeAll, addMarker, addTodoMarker, addChapterMarker, deleteMarker,
nextMarker, previousMarker, addTransition, nextEdit, previousEdit,
selectClipAtPlayhead, selectToPlayhead, selectAll, deselectAll,
delete, cut, copy, paste, undo, redo, insertGap, trimToPlayhead

## Available Playback Actions
playPause, goToStart, goToEnd, nextFrame, prevFrame, nextFrame10, prevFrame10

## Object Handle Pattern
For advanced operations, use handles to chain calls:
```
# Get libraries as a handle
libs = call_method_with_args("FFLibraryDocument", "copyActiveLibraries", return_handle=True)
# Read property on the handle
get_object_property(libs_handle, "firstObject", return_handle=True)
# Read property on that result
get_object_property(library_handle, "displayName")
```

## Calling Methods With Arguments
```
call_method_with_args(
    target="FFAnchoredSequence",      # class name or handle
    selector="insertGap:ofDuration:rootItem:",
    args='[{"type":"cmtime","value":{"value":300,"timescale":30}},...]',
    class_method=False,
    return_handle=True
)
```

Argument types: string, int, double, float, bool, nil, sender, handle, cmtime, selector

## FCPXML Import
For complex multi-element edits, generate FCPXML and import it:
```
import_fcpxml("<fcpxml version='1.11'>...</fcpxml>")
```

## Key FCP Classes

| Class | Methods | Use |
|-------|---------|-----|
| FFAnchoredTimelineModule | 1435 | Timeline editing, blade, markers, selection |
| FFAnchoredSequence | 1074 | Timeline data model, clips, structure |
| FFAnchoredObject | base | All timeline items (clips, gaps, transitions) |
| FFAnchoredClip | - | Video/audio clips |
| FFLibrary | 203 | Library container, events, projects |
| FFLibraryDocument | 231 | Library persistence |
| FFEditActionMgr | 42 | Edit commands (insert, append, overwrite) |
| FFPlayer | 228 | Playback engine |
| FFEffectStack | - | Effect management on clips |
| PEAppController | 484 | App controller, windows |
| PEEditorContainerModule | - | Editor container, modules |

## Error Recovery
- "No active timeline module" -> No project open. User needs to open a project.
- "No responder handled X" -> Action not available in current state.
- "Handle not found" -> Object was released or deallocated. Get a fresh reference.
- "Cannot connect" -> FCP not running or bridge not loaded.
- Connection reset -> MCP server auto-reconnects on next call.

## Editing Safety
- timeline_action() methods go through FCP's normal action/undo system
- Use undo/redo: timeline_action("undo"), timeline_action("redo")
- set_object_property() bypasses undo -- use only for non-undoable changes
- Always verify edits with get_timeline_clips() or verify_action()

## Discovering New APIs
```
get_classes(filter="FFColor")           -- find classes
explore_class("FFColorCorrectionEffect") -- see everything on a class
search_methods("FFAnchoredTimelineModule", "color") -- find methods by keyword
get_methods("FFEffectStack")            -- full method listing
```
