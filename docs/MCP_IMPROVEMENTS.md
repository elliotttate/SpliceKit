# MCP / SpliceKit Improvements Needed

Issues encountered during word-progress caption development (April 2026).

## Priority 1: Blocking Issues

### 1. `open_project(name, event, library)`
Load a project into the timeline by name. Currently requires manual ObjC chain:
`_deepLoadedSequences` → iterate → find by displayName → `loadEditorForSequence:`.
This took 20+ tool calls and multiple failures. Should be one call.

### 2. `select_connected_clip(lane=1)` or `select_clip_by_name(name)`
`selectClipAtPlayhead` only selects the primary storyline. Connected clips (caption
titles, adjustment layers) can't be selected for inspector inspection. Up-arrow
keyboard shortcut is unreliable. Need direct selection of connected clips at the
playhead or by name/handle.

### 3. ~~`capture_viewer()` → image~~ ✅ Done
`capture_viewer()` and `capture_timeline()` both implemented. Capture GPU/Metal
content directly from the FCP window (viewer crops to FFPlayerView, timeline crops
to TLKTimelineView). No screencapture needed, FCP doesn't need to be in foreground.

### 4. Fix `call_method_with_args` args parameter
The MCP tool's Pydantic validation rejects `args` when passed as a JSON array
(expects string). The workaround is raw JSON-RPC via `nc`. The MCP wrapper should
accept both string and array formats for `args`.

## Priority 2: Major Time Savers

### 5. `deploy_and_restart(wait=True)`
Build → copy to framework path → re-sign → kill FCP → launch → wait for bridge.
This cycle was repeated ~15 times manually. Should be one command that returns
when the bridge is ready.

### 6. `export_project_xml(path="/tmp/export.fcpxml")`
Export the current project as FCPXML to a file without a save dialog. Needed for
discovering Motion template parameter key paths. Currently requires the GUI Export
XML dialog which can't be automated.

### 7. Auto-dismiss "video properties" dialog
The "video properties of this clip are not recognized" sheet appears whenever
switching to a project imported via FCPXML. It blocks all timeline interaction.
The caption pipeline (or the bridge) should auto-dismiss this with sensible defaults.

## Priority 3: Nice to Have

### 8. `get_inspector_properties` for connected clips
Allow passing a handle to `get_inspector_properties` so you can inspect any clip's
transform/compositing, not just the selected one.

### 9. `get_all_connected_clips(at_time=0.5)`
Return all connected/anchored clips at a given time with their handles, names,
and basic properties. Currently requires walking `anchoredItems` → `allObjects`
→ iterating.

### 10. Template key path discovery
`discover_template_keys(template_uid)` — Import a test title with the given
template, export the project, parse the FCPXML, and return all `<param>` key
paths. This automates the key path discovery process that currently requires
manual import → export → parse.
