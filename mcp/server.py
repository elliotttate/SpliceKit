#!/usr/bin/env python3
"""
SpliceKit MCP Server — the bridge between AI tools and Final Cut Pro.

This is the MCP (Model Context Protocol) server that Claude and other AI tools
talk to. It exposes FCP's entire editing API as MCP tools. Under the hood, each
tool just sends a JSON-RPC request to the SpliceKit dylib running inside FCP's
process (127.0.0.1:9876) and returns the result.

The tools are intentionally verbose in their docstrings because that's what the
AI model sees when deciding which tool to use and how to call it.
"""

import socket
import json
import time
import functools
from mcp.server.fastmcp import FastMCP

SPLICEKIT_HOST = "127.0.0.1"
SPLICEKIT_PORT = 9876

mcp = FastMCP(
    "splicekit",
    instructions="""Direct in-process control of Final Cut Pro via injected SpliceKit dylib.
Connects to a JSON-RPC server running INSIDE the FCP process with access to 78,000+ ObjC classes.
All operations are fully programmatic - no AppleScript, no UI automation.

## Standard Workflow
1. bridge_status() -- verify FCP is running and connected
2. open_project("My Project") -- load a project by name
3. get_timeline_clips() -- see what's in the timeline (items, handles, durations)
4. Perform actions using timeline_action() and playback_action()
5. verify_action() -- confirm the edit took effect by comparing state snapshots
6. capture_timeline() -- screenshot the timeline to visually verify clip layout
7. capture_viewer() -- screenshot the viewer to visually verify canvas output

## Visual Verification
Use capture_viewer() and capture_timeline() to take PNG screenshots of FCP.
These capture GPU/Metal content directly — FCP does not need to be in the foreground.
- After effects, color, titles, captions → capture_viewer() to check the canvas
- After blade cuts, markers, rearrangement → capture_timeline() to check layout
Read the saved PNG to visually confirm the result.

## IMPORTANT: Opening a Project
Use open_project(name, event) to find and load a project by name:
  open_project("My Project")                 -- find by name
  open_project("Edit v2", event="4-5-26")    -- filter by event too

Or manually if needed:
  1. call_method_with_args("FFLibraryDocument", "copyActiveLibraries", return_handle=True)
  2. Navigate: array -> library -> _deepLoadedSequences -> allObjects
  3. Find a sequence with hasContainedItems == true
  4. Get editor container via NSApp -> delegate -> activeEditorContainer
  5. Call loadEditorForSequence: on the container with the sequence handle

## Dual Timeline
Use the dual_timeline_* tools to open a floating second editor window:
  - dual_timeline_open() -- load the primary sequence into the secondary window
  - dual_timeline_sync_root() -- match the primary editor's current root
  - dual_timeline_open_selected_in_secondary() -- open the selected compound/multicam on the other side
  - dual_timeline_focus("primary"/"secondary") -- route commands to a specific editor
  - dual_timeline_close() -- close the floating secondary window

## Positioning the Playhead
Use playback_action() to navigate before performing edits:
  - goToStart, goToEnd -- jump to boundaries
  - nextFrame, prevFrame -- single frame steps (1/24s at 24fps)
  - nextFrame10, prevFrame10 -- 10-frame jumps
  - For precise positioning, use batch: nextFrame with repeat count
    e.g., batch_timeline_actions('[{"type":"playback","action":"nextFrame","repeat":72}]')
    (72 frames = 3 seconds at 24fps)

## Timeline Actions (timeline_action)
Blade: blade, bladeAll
Markers: addMarker, addTodoMarker, addChapterMarker, deleteMarker, nextMarker, previousMarker
Transitions: addTransition
Navigation: nextEdit, previousEdit, selectClipAtPlayhead, selectToPlayhead
Selection: selectAll, deselectAll
Edit: delete, cut, copy, paste, undo, redo
Insert: insertGap
Trim: trimToPlayhead
Color: addColorBoard, addColorWheels, addColorCurves, addColorAdjustment,
       addHueSaturation, addEnhanceLightAndColor
Volume: adjustVolumeUp, adjustVolumeDown
Titles: addBasicTitle, addBasicLowerThird
Speed: retimeNormal, retimeFast2x, retimeFast4x, retimeFast8x, retimeFast20x,
       retimeSlow50, retimeSlow25, retimeSlow10, retimeReverse, retimeHold,
       freezeFrame, retimeBladeSpeed
Keyframes: addKeyframe, deleteKeyframes, removeAllKeyframesFromClip, nextKeyframe, previousKeyframe
Other: solo, disable, createCompoundClip, autoReframe, exportXML, shareSelection

## IMPORTANT: Selection Before Actions
Many actions require a clip to be selected first:
  1. Navigate to position: playback_action("goToStart") then step frames
  2. Select: timeline_action("selectClipAtPlayhead")
  3. Then apply: timeline_action("addColorBoard") or timeline_action("retimeSlow50")
  Undo with: timeline_action("undo")

## Playback (playback_action)
playPause, goToStart, goToEnd, nextFrame, prevFrame, nextFrame10, prevFrame10

## Batch Operations
Use batch_timeline_actions() for multi-step sequences:
  '[{"type":"playback","action":"goToStart"},
    {"type":"playback","action":"nextFrame","repeat":72},
    {"type":"timeline","action":"blade"},
    {"type":"playback","action":"nextFrame","repeat":48},
    {"type":"timeline","action":"blade"}]'

## Timeline Data Model
FCP uses a spine model: sequence -> primaryObject (collection) -> items
Items are FFAnchoredMediaComponent (clips), FFAnchoredTransition, etc.
get_timeline_clips() handles this automatically and returns handles for each item.

## Useful Findings
- Transition requests at a cut often target the right-hand clip with before=YES and after=NO.
  That still means "apply the transition on the cut before this clip", not "apply it to the
  clip's leading edge as a one-sided effect".
- The UI trim actions trimToPlayhead, trimStart, and trimEnd are coarse and mode-dependent.
  They are fine for interactive edits but poor for building exact repro cases.
- For model-level selection work, create NSArray handles explicitly. Example:
  arr = call_method_with_args("NSArray", "arrayWithObject:",
      '[{"type":"handle","value":"obj_7"}]', class_method=True, return_handle=True)
  call_method_with_args("obj_timeline", "setSelectedItems:",
      f'[{{"type":"handle","value":"{arr_handle}"}}]', class_method=False)
- Be careful with selectors that expose out-pointers such as error:, askedRetry:, or similar.
  call_method_with_args() passes raw pointers through NSInvocation. Passing nil is only safe if
  the target selector tolerates a null out pointer.
- Known hazard: FFAnchoredSequence actionTrimDuration:forEdits:isDelta:error: can crash Final Cut
  when the trim is rejected and error: is null. Do not use it as a probing tool through
  call_method_with_args() unless you have a safe wrapper that owns the NSError** path.

## FCPXML for Complex Edits
For creating entire projects with gaps, titles, markers:
  xml = generate_fcpxml(items='[{"type":"gap","duration":5},{"type":"title","text":"Hello","duration":3}]')
  import_fcpxml(xml, internal=True)  # imports without restart

## Object Handles for Deep Access
  call_method_with_args("FFLibraryDocument", "copyActiveLibraries", return_handle=True)
  # Returns {"handle": "obj_1", "class": "..."} -- pass handle to subsequent calls
  call_method_with_args("obj_1", "objectAtIndex:", '[{"type":"int","value":0}]', false, true)
  # Always release when done: manage_handles(action="release_all")

## FlexMusic (Dynamic Soundtrack)
flexmusic_list_songs() -- browse available songs
flexmusic_get_song(song_uid) -- detailed song info
flexmusic_get_timing(song_uid, duration_seconds) -- beat/bar/section timestamps
flexmusic_render_to_file(song_uid, duration_seconds, output_path) -- render to audio
flexmusic_add_to_timeline(song_uid) -- add music to timeline

## Montage Maker
montage_analyze_clips() -- score clips for montage
montage_plan_edit(beats, clips, style) -- create edit plan from timing + clips
montage_assemble(edit_plan, project_name, song_file) -- build timeline from plan
montage_auto(song_uid, event_name, style) -- one-shot auto-montage
sync_clips_to_song_beats() -- selected-song beat sync for current timeline clips
assemble_random_clips_to_song_beats() -- build a random browser-clip cut to a selected song beat map
build_song_cut() -- one-shot song-based random primary-storyline cut with pacing presets
"""
)


READ_ONLY = {
    "readOnlyHint": True,
    "destructiveHint": False,
    "idempotentHint": True,
    "openWorldHint": False,
}

LOCAL_WRITE = {
    "readOnlyHint": False,
    "destructiveHint": False,
    "idempotentHint": False,
    "openWorldHint": False,
}

DESTRUCTIVE_LOCAL_WRITE = {
    "readOnlyHint": False,
    "destructiveHint": True,
    "idempotentHint": False,
    "openWorldHint": False,
}

READ_ONLY_TOOLS = {
    "bridge_status",
    "background_render_status",
    "dual_timeline_status",
    "get_timeline_clips",
    "get_selected_clips",
    "verify_action",
    "get_object_property",
    "generate_fcpxml",
    "get_clip_effects",
    "analyze_timeline",
    "get_active_libraries",
    "is_library_updating",
    "get_classes",
    "get_methods",
    "get_properties",
    "get_ivars",
    "get_protocols",
    "get_superchain",
    "explore_class",
    "search_methods",
    "get_transcript",
    "search_transcript",
    "list_effects",
    "list_transitions",
    "search_commands",
    "list_menus",
    "get_inspector_properties",
    "get_title_text",
    "verify_captions",
    "get_playhead_position",
    "detect_dialog",
    "get_viewer_zoom",
    "get_bridge_options",
    "detect_scene_changes",
    "detect_beats",
    "analyze_song_structure",
    "toggle_structure_blocks",
    "get_sections",
    "flexmusic_list_songs",
    "flexmusic_get_song",
    "flexmusic_get_timing",
    "montage_analyze_clips",
    "montage_plan_edit",
    "debug_get_config",
    "dump_runtime_metadata",
    "list_loaded_images",
    "get_image_sections",
    "get_image_symbols",
    "get_notification_names",
    "debug_threads",
    "debug_eval",
    "browser_list_clips",
    "braw_probe",
    "get_caption_state",
    "get_caption_styles",
    "verify_native_captions",
    "list_handles",
    "inspect_handle",
    "plugin_list",
    "plugin_list_methods",
    "reload_plugin_tools",
    "mixer_get_state",
}

DESTRUCTIVE_TOOLS = {
    "timeline_action",
    "timeline_destructive_action",
    "history_action",
    "batch_export",
    "call_method",
    "call_method_with_args",
    "set_object_property",
    "import_fcpxml",
    "import_otio",
    "batch_timeline_actions",
    "delete_transcript_words",
    "move_transcript_words",
    "delete_transcript_silences",
    "blade_at_times",
    "trim_clips_to_beats",
    "sync_clips_to_song_beats",
    "assemble_random_clips_to_song_beats",
    "build_song_cut",
    "apply_effect",
    "apply_transition",
    "apply_transition_to_all_clips",
    "batch_apply_effect",
    "batch_color_correct",
    "execute_command",
    "ai_command",
    "execute_menu_command",
    "set_inspector_property",
    "share_project",
    "create_project",
    "create_event",
    "create_library",
    "click_dialog_button",
    "fill_dialog_field",
    "toggle_dialog_checkbox",
    "select_dialog_popup",
    "dismiss_dialog",
    "flexmusic_render_to_file",
    "flexmusic_add_to_timeline",
    "montage_assemble",
    "montage_auto",
    "debug_set_config",
    "debug_reset_config",
    "debug_enable_preset",
    "debug_load_plugin",
    "direct_timeline_action",
    "browser_append_clip",
    "import_media",
    "paste_fcpxml",
    "stabilize_subject",
    "insert_title",
    "generate_captions",
    "export_captions_srt",
    "export_captions_txt",
    "generate_native_captions",
    "blade_scene_changes",
    "beat_sync_blade",
    "song_structure_blocks",
    "song_structure_sections",
    "remove_structure_blocks",
    "hide_sections",
    "ai_command_gemma",
    "deploy_and_restart",
    "lua_execute",
    "lua_execute_file",
    "lua_reset",
    "lua_watch",
    "raw_call",
    "mixer_set_volume",
    "mixer_set_all_volumes",
    "mixer_apply_bus_effect",
    "mixer_set_bus_effect_enabled",
    "mixer_remove_bus_effect",
}

IDEMPOTENT_LOCAL_WRITE_TOOLS = {
    "seek_to_time",
    "set_timeline_range",
    "set_silence_threshold",
    "set_viewer_zoom",
    "set_bridge_option",
    "set_bridge_option_value",
    "set_workspace",
    "select_tool",
    "assign_role",
    "set_transcript_engine",
    "open_project",
    "select_clip_in_lane",
    "mixer_volume_begin",
    "mixer_volume_end",
}

CUSTOM_TOOL_TITLES = {
    "bridge_status": "Bridge Status",
    "background_render_status": "Background Render Status",
    "background_render_control": "Background Render Control",
    "get_timeline_clips": "Get Timeline Clips",
    "get_selected_clips": "Get Selected Clips",
    "set_timeline_range": "Set Timeline Range",
    "batch_export": "Batch Export Clips",
    "verify_action": "Verify Timeline Action",
    "call_method_with_args": "Call Method With Args",
    "manage_handles": "Manage Object Handles",
    "list_handles": "List Object Handles",
    "inspect_handle": "Inspect Object Handle",
    "release_handle": "Release Object Handle",
    "release_all_handles": "Release All Handles",
    "get_object_property": "Get Object Property",
    "set_object_property": "Set Object Property",
    "import_fcpxml": "Import FCPXML",
    "generate_fcpxml": "Generate FCPXML",
    "batch_timeline_actions": "Batch Timeline Actions",
    "import_srt_as_markers": "Import SRT As Markers",
    "blade_at_times": "Blade At Times",
    "trim_clips_to_beats": "Trim Clips To Beats",
    "sync_clips_to_song_beats": "Sync Clips To Song Beats",
    "assemble_random_clips_to_song_beats": "Assemble Random Clips To Song Beats",
    "build_song_cut": "Build Song Cut",
    "open_project": "Open Project",
    "select_clip_in_lane": "Select Clip In Lane",
    "capture_viewer": "Capture Viewer",
    "capture_timeline": "Capture Timeline",
    "capture_inspector": "Capture Inspector",
    "export_xml": "Export FCPXML",
    "export_otio": "Export OpenTimelineIO",
    "import_otio": "Import OpenTimelineIO",
    "is_library_updating": "Check Library Updating",
    "search_methods": "Search Methods",
    "raw_call": "Raw JSON-RPC Call",
    "ai_command_gemma": "AI Command Gemma",
    "delete_transcript_words": "Delete Transcript Words",
    "move_transcript_words": "Move Transcript Words",
    "close_transcript": "Close Transcript Panel",
    "search_transcript": "Search Transcript",
    "delete_transcript_silences": "Delete Transcript Silences",
    "set_silence_threshold": "Set Silence Threshold",
    "show_command_palette": "Show Command Palette",
    "hide_command_palette": "Hide Command Palette",
    "ai_command": "AI Command",
    "execute_menu_command": "Execute Menu Command",
    "get_inspector_properties": "Get Inspector Properties",
    "set_inspector_property": "Set Inspector Property",
    "get_title_text": "Get Title Text",
    "toggle_panel": "Toggle Panel",
    "get_playhead_position": "Get Playhead Position",
    "detect_dialog": "Detect Dialog",
    "click_dialog_button": "Click Dialog Button",
    "fill_dialog_field": "Fill Dialog Field",
    "toggle_dialog_checkbox": "Toggle Dialog Checkbox",
    "select_dialog_popup": "Select Dialog Popup",
    "dismiss_dialog": "Dismiss Dialog",
    "get_viewer_zoom": "Get Viewer Zoom",
    "set_viewer_zoom": "Set Viewer Zoom",
    "get_bridge_options": "Get Bridge Options",
    "set_bridge_option": "Set Bridge Option",
    "set_bridge_option_value": "Set Bridge Option Value",
    "apply_transition_to_all_clips": "Apply Transition To All Clips",
    "batch_apply_effect": "Batch Apply Effect",
    "batch_color_correct": "Batch Color Correct",
    "detect_beats": "Detect Beats",
    "analyze_song_structure": "Analyze Song Structure",
    "beat_sync_blade": "Beat Sync Blade",
    "song_structure_blocks": "Song Structure Blocks",
    "song_structure_sections": "Song Structure Sections",
    "toggle_structure_blocks": "Toggle Structure Blocks",
    "remove_structure_blocks": "Remove Structure Blocks",
    "get_sections": "Get Sections",
    "hide_sections": "Hide Sections",
    "flexmusic_list_songs": "List FlexMusic Songs",
    "flexmusic_get_song": "Get FlexMusic Song",
    "flexmusic_get_timing": "Get FlexMusic Timing",
    "flexmusic_render_to_file": "Render FlexMusic To File",
    "flexmusic_add_to_timeline": "Add FlexMusic To Timeline",
    "montage_analyze_clips": "Analyze Montage Clips",
    "montage_plan_edit": "Plan Montage Edit",
    "montage_assemble": "Assemble Montage",
    "montage_auto": "Auto Montage",
    "debug_get_config": "Get Debug Config",
    "debug_set_config": "Set Debug Config",
    "debug_reset_config": "Reset Debug Config",
    "debug_enable_preset": "Enable Debug Preset",
    "debug_start_framerate_monitor": "Start Framerate Monitor",
    "debug_stop_framerate_monitor": "Stop Framerate Monitor",
    "dump_runtime_metadata": "Dump Runtime Metadata",
    "list_loaded_images": "List Loaded Images",
    "get_image_sections": "Get Image Sections",
    "get_image_symbols": "Get Image Symbols",
    "get_notification_names": "Get Notification Names",
    "debug_trace_method": "Trace Method",
    "debug_watch": "Watch Property Changes",
    "debug_crash_handler": "Crash Handler",
    "debug_eval": "Evaluate Debug Expression",
    "debug_load_plugin": "Load Debug Plugin",
    "debug_observe_notification": "Observe Notifications",
    "direct_timeline_action": "Direct Timeline Action",
    "browser_list_clips": "List Browser Clips",
    "browser_append_clip": "Append Browser Clip",
    "import_media": "Import Media Files",
    "paste_fcpxml": "Paste FCPXML",
    "stabilize_subject": "Stabilize Subject",
    "insert_title": "Insert Title",
    "set_transcript_engine": "Set Transcript Engine",
    "open_captions": "Open Captions Panel",
    "close_captions": "Close Captions Panel",
    "get_caption_state": "Get Caption State",
    "get_caption_styles": "Get Caption Styles",
    "set_caption_style": "Set Caption Style",
    "set_caption_grouping": "Set Caption Grouping",
    "generate_captions": "Generate Captions",
    "export_captions_srt": "Export Captions SRT",
    "export_captions_txt": "Export Captions Text",
    "set_caption_words": "Set Caption Words",
    "generate_native_captions": "Generate Native Captions",
    "verify_native_captions": "Verify Native Captions",
    "mark_scene_changes": "Mark Scene Changes",
    "blade_scene_changes": "Blade Scene Changes",
    "timeline_navigation_action": "Timeline Navigation Action",
    "timeline_edit_action": "Timeline Edit Action",
    "timeline_destructive_action": "Timeline Destructive Action",
    "history_action": "Timeline History Action",
    "deploy_and_restart": "Deploy And Restart FCP",
    "lua_execute": "Execute Lua Code",
    "lua_execute_file": "Execute Lua File",
    "lua_reset": "Reset Lua VM",
    "lua_watch": "Watch Lua Files",
    "lua_state": "Get Lua State",
}

TIMELINE_NAVIGATION_ACTIONS = {
    "nextEdit", "previousEdit", "nextMarker", "previousMarker",
    "nextKeyframe", "previousKeyframe",
    "selectClipAtPlayhead", "selectToPlayhead", "selectAll", "deselectAll",
    "showVideoAnimation", "showAudioAnimation", "soloAnimation",
    "showTrackingEditor", "showCinematicEditor", "showMagneticMaskEditor",
    "enableBeatDetection",
    "showPrecisionEditor", "showAudioLanes", "expandSubroles",
    "showDuplicateRanges", "showKeywordEditor", "togglePrecisionEditor",
    "toggleSnapping", "toggleSkimming", "toggleClipSkimming",
    "toggleAudioSkimming", "toggleInspector", "toggleTimeline",
    "toggleTimelineIndex", "toggleInspectorHeight", "beatDetectionGrid",
    "timelineScrolling", "enterFullScreen", "timelineHistoryBack",
    "timelineHistoryForward", "zoomToFit", "zoomIn", "zoomOut",
    "verticalZoomToFit", "zoomToSamples", "goToInspector", "goToTimeline",
    "goToViewer", "goToColorBoard", "selectNextItem", "selectUpperItem",
}

TIMELINE_EDIT_ACTIONS = {
    "addMarker", "addTodoMarker", "addChapterMarker", "addTransition",
    "copy", "paste", "pasteAsConnected", "pasteEffects",
    "pasteAttributes", "removeAttributes", "copyAttributes", "copyTimecode",
    "connectToPrimaryStoryline", "insertEdit", "appendEdit", "insertGap",
    "insertPlaceholder", "addAdjustmentClip", "addColorBoard", "addColorWheels",
    "addColorCurves", "addColorAdjustment", "addHueSaturation",
    "addEnhanceLightAndColor", "balanceColor", "matchColor",
    "addMagneticMask", "smartConform", "adjustVolumeUp", "adjustVolumeDown",
    "expandAudio", "expandAudioComponents", "addChannelEQ", "enhanceAudio",
    "matchAudio", "detachAudio", "addBasicTitle", "addBasicLowerThird",
    "addKeyframe",
    "favorite", "reject", "unrate", "setRangeStart", "setRangeEnd",
    "clearRange", "setClipRange", "solo", "disable", "createCompoundClip",
    "autoReframe", "synchronizeClips", "openClip", "renameClip",
    "addToSoloedClips", "referenceNewParentClip", "changeDuration",
    "createStoryline", "liftFromPrimaryStoryline", "createAudition",
    "finalizeAudition", "nextAuditionPick", "previousAuditionPick",
    "addCaption", "createMulticamClip", "addKeywordGroup1", "addKeywordGroup2",
    "addKeywordGroup3", "addKeywordGroup4", "addKeywordGroup5",
    "addKeywordGroup6", "addKeywordGroup7", "nextColorEffect",
    "previousColorEffect", "resetColorBoard", "toggleAllColorOff",
    "alignAudioToVideo", "volumeMute", "addDefaultAudioEffect",
    "addDefaultVideoEffect", "applyAudioFades", "makeClipsUnique",
    "enableDisable", "transcodeMedia", "pasteAllAttributes", "duplicateProject", "snapshotProject",
    "projectProperties", "libraryProperties", "consolidateEventMedia",
    "mergeEvents", "renderSelection", "renderAll", "exportXML",
    "shareSelection", "find", "findAndReplaceTitle", "revealInBrowser",
    "revealProjectInBrowser", "revealInFinder", "analyzeAndFix",
    "backgroundTasks", "recordVoiceover", "editRoles", "addVideoGenerator",
}

TIMELINE_DESTRUCTIVE_ACTIONS = {
    "blade", "bladeAll", "deleteMarker", "deleteMarkersInSelection",
    "delete", "cut", "replaceWithGap", "overwriteEdit", "trimToPlayhead",
    "extendEditToPlayhead", "trimStart", "trimEnd", "joinClips", "nudgeLeft",
    "nudgeRight", "nudgeUp", "nudgeDown", "retimeNormal", "retimeFast2x",
    "retimeFast4x", "retimeFast8x", "retimeFast20x", "retimeSlow50",
    "retimeSlow25", "retimeSlow10", "retimeReverse", "retimeHold",
    "freezeFrame", "retimeBladeSpeed", "retimeSpeedRampToZero",
    "retimeSpeedRampFromZero", "deleteKeyframes", "removeAllKeyframesFromClip",
    "breakApartClipItems",
    "removeEffects", "overwriteToPrimaryStoryline", "collapseToConnectedStoryline",
    "splitCaption", "resolveOverlaps", "toggleSelectedEffectsOff",
    "toggleDuplicateDetection", "insertEditAudio", "insertEditVideo",
    "appendEditAudio", "appendEditVideo", "overwriteEditAudio",
    "overwriteEditVideo", "connectEditAudio", "connectEditVideo",
    "connectEditBacktimed", "avEditModeAudio", "avEditModeVideo",
    "avEditModeBoth", "replaceFromStart", "replaceFromEnd", "replaceWhole",
    "retimeCustomSpeed", "retimeInstantReplayHalf", "retimeInstantReplayQuarter",
    "retimeReset", "retimeOpticalFlow", "retimeFrameBlending",
    "retimeFloorFrame", "removeAllKeywords", "removeAnalysisKeywords",
    "closeLibrary", "deleteGeneratedFiles", "moveToTrash", "hideClip",
}

TIMELINE_HISTORY_ACTIONS = {
    "undo", "redo",
}


def _titleize_tool_name(name: str) -> str:
    return " ".join(part.upper() if part in {"ai", "fcpxml", "srt"} else part.capitalize()
                    for part in name.split("_"))


def _tool_annotations(name: str) -> dict:
    if name in READ_ONLY_TOOLS:
        annotations = dict(READ_ONLY)
    elif name in DESTRUCTIVE_TOOLS:
        annotations = dict(DESTRUCTIVE_LOCAL_WRITE)
    else:
        annotations = dict(LOCAL_WRITE)

    if name in IDEMPOTENT_LOCAL_WRITE_TOOLS:
        annotations["idempotentHint"] = True

    annotations["title"] = CUSTOM_TOOL_TITLES.get(name, _titleize_tool_name(name))
    return annotations


def _handle_management_response(action: str, handle: str = "") -> str:
    if action == "list":
        r = bridge.call("object.list")
    elif action == "inspect" and handle:
        r = bridge.call("object.get", handle=handle)
    elif action == "release" and handle:
        r = bridge.call("object.release", handle=handle)
    elif action == "release_all":
        r = bridge.call("object.release", all=True)
    else:
        return "Usage: manage_handles(action='list|inspect|release|release_all', handle='obj_N')"

    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


class BridgeConnection:
    """Persistent TCP connection to the SpliceKit JSON-RPC server inside FCP.

    Keeps the socket open between calls so we don't pay the connect overhead
    on every tool invocation. Auto-reconnects if the connection drops (FCP
    restarted, socket timed out, etc).
    """

    def __init__(self):
        self.sock = None
        self._buf = b""  # leftover bytes from previous recv (newline-delimited protocol)
        self._id = 0     # monotonically increasing JSON-RPC request ID

    def ensure_connected(self):
        if self.sock is None:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sock.settimeout(30)
            self.sock.connect((SPLICEKIT_HOST, SPLICEKIT_PORT))
            self._buf = b""

    def call(self, method: str, params_dict=None, **params) -> dict:
        """Send a JSON-RPC request and wait for the response.

        Accepts params as keyword args OR as a single dict positional arg:
            bridge.call("method", key="value")       # kwargs
            bridge.call("method", {"key": "value"})  # dict

        Returns the result dict on success, or {"error": "..."} on failure.
        Handles connection errors gracefully — the next call will auto-reconnect.
        """
        # Merge positional dict and kwargs so callers can use either style
        if params_dict is not None:
            if isinstance(params_dict, dict):
                params = {**params_dict, **params}
            # else ignore non-dict positional (shouldn't happen)
        try:
            self.ensure_connected()
        except (ConnectionRefusedError, OSError) as e:
            return {"error": f"Cannot connect to SpliceKit at {SPLICEKIT_HOST}:{SPLICEKIT_PORT}. "
                    f"Is the modded FCP running? Error: {e}"}

        self._id += 1
        req = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": self._id})
        try:
            # Protocol: newline-delimited JSON, one request/response per line
            self.sock.sendall(req.encode() + b"\n")
            while b"\n" not in self._buf:
                chunk = self.sock.recv(16777216)  # 16MB — FCPXML responses can be large
                if not chunk:
                    self.sock = None  # server closed the connection, force reconnect next call
                    return {"error": "Connection closed by SpliceKit"}
                self._buf += chunk
            # Split off the first complete message, keep any leftovers for next call
            line, self._buf = self._buf.split(b"\n", 1)
            resp = json.loads(line)
            if "error" in resp:
                return {"error": resp["error"]}
            return resp.get("result", {})
        except Exception as e:
            self.sock = None  # toss the broken socket so the next call reconnects
            return {"error": f"Bridge communication error: {e}"}


bridge = BridgeConnection()  # singleton -- shared by all tool functions below


# -- Helpers used by every tool function --

def _err(r):
    """Check if a bridge response contains an error."""
    return "error" in r


def _fmt(r):
    """Pretty-print a bridge response as indented JSON."""
    return json.dumps(r, indent=2, default=str)


def _call_or_error(method: str, **params) -> str:
    """Call the bridge and return formatted JSON, or an error string.

    This is the common pattern used by most tools — call the bridge,
    check for errors, format the result. Having it in one place means
    we don't repeat the same 4 lines in every tool function.
    """
    r = bridge.call(method, **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


class BridgeError(Exception):
    """Raised when a bridge call returns an error."""
    pass


def _call(method: str, **params) -> dict:
    """Call the bridge and return the result dict. Raises BridgeError on failure."""
    r = bridge.call(method, **params)
    if _err(r):
        raise BridgeError(r.get("error", str(r)))
    return r


def bridge_tool(fn):
    """Decorator: catches BridgeError and returns 'Error: ...' string.

    Use with _call() to eliminate the repetitive if-_err-return pattern:
        @mcp.tool(annotations=_tool_annotations("my_tool"))
        @bridge_tool
        def my_tool() -> str:
            r = _call("my.method")
            return _fmt(r)
    """
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except BridgeError as e:
            return f"Error: {e}"
    return wrapper


# ============================================================
# Core Connection & Status
# ============================================================
# The first thing any client should do is call bridge_status() to
# verify FCP is running and the bridge is responsive.

@mcp.tool(annotations=_tool_annotations("bridge_status"))
def bridge_status() -> str:
    """Check if SpliceKit is running and get FCP version info."""
    r = bridge.call("system.version")
    if _err(r):
        return f"SpliceKit NOT connected: {r.get('error', r)}"  # special error message for status
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("background_render_status"))
def background_render_status() -> str:
    """Inspect Final Cut Pro's live background-render state.

    Returns queue and manager state pulled from the running process, including:
    - Whether background render is currently in low-overhead mode
    - The current Background Render run-group queue concurrency
    - Auto-start delay and related background-render defaults
    - Active GPU/render preference defaults used for background render

    Use this before and after background_render_control() to see whether FCP
    accepted the requested throttle window.
    """
    r = bridge.call("backgroundRender.status")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("background_render_control"))
def background_render_control(action: str, seconds: float) -> str:
    """Temporarily reduce background-render impact while editing.

    Args:
        action: One of:
          - "hold_off": Delay background-render auto-start for `seconds`
          - "low_overhead": Enter FCP's internal low-overhead mode for `seconds`
        seconds: Duration in seconds. Must be > 0.

    This tool intentionally exposes only short-lived, reversible throttles.
    It does not change persistent preferences or attempt CPU affinity control.
    """
    normalized = action.strip().lower()
    if normalized not in {"hold_off", "low_overhead"}:
        return "Error: action must be 'hold_off' or 'low_overhead'."
    if seconds <= 0:
        return "Error: seconds must be > 0."

    r = bridge.call("backgroundRender.control", action=normalized, seconds=seconds)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Timeline Actions
# ============================================================
# These map directly to FCP's IBAction methods on the timeline module.
# Most require a clip to be selected first (selectClipAtPlayhead).

@mcp.tool(annotations=_tool_annotations("timeline_action"))
def timeline_action(action: str) -> str:
    """Use this legacy catch-all tool when a timeline action does not fit the narrower action tools.

    Actions:
      Blade: blade, bladeAll
      Markers: addMarker, addTodoMarker, addChapterMarker, deleteMarker, nextMarker,
               previousMarker, deleteMarkersInSelection
      Transitions: addTransition
      Navigation: nextEdit, previousEdit, selectClipAtPlayhead, selectToPlayhead
      Selection: selectAll, deselectAll
      Edit: delete, cut, copy, paste, undo, redo, pasteAsConnected, replaceWithGap,
            pasteEffects, pasteAttributes, removeAttributes, copyAttributes, copyTimecode
      Edit Modes: connectToPrimaryStoryline, insertEdit, appendEdit, overwriteEdit
      Insert: insertGap, insertPlaceholder, addAdjustmentClip
      Trim: trimToPlayhead, extendEditToPlayhead, trimStart, trimEnd, joinClips,
            nudgeLeft, nudgeRight, nudgeUp, nudgeDown
      Color: addColorBoard, addColorWheels, addColorCurves, addColorAdjustment,
             addHueSaturation, addEnhanceLightAndColor, balanceColor, matchColor,
             addMagneticMask, smartConform
      Volume: adjustVolumeUp, adjustVolumeDown
      Audio: expandAudio, expandAudioComponents, addChannelEQ, enhanceAudio,
             matchAudio, detachAudio
      Titles: addBasicTitle, addBasicLowerThird
      Speed: retimeNormal, retimeFast2x/4x/8x/20x, retimeSlow50/25/10,
             retimeReverse, retimeHold, freezeFrame, retimeBladeSpeed,
             retimeSpeedRampToZero, retimeSpeedRampFromZero
      Keyframes: addKeyframe, deleteKeyframes, removeAllKeyframesFromClip,
                 nextKeyframe, previousKeyframe
      Rating: favorite, reject, unrate
      Range: setRangeStart, setRangeEnd, clearRange, setClipRange
      Clip Ops: solo, disable, createCompoundClip, autoReframe, detachAudio,
                breakApartClipItems, removeEffects, synchronizeClips, openClip,
                renameClip, addToSoloedClips, referenceNewParentClip, changeDuration
      Storyline: createStoryline, liftFromPrimaryStoryline,
                 overwriteToPrimaryStoryline, collapseToConnectedStoryline
      Audition: createAudition, finalizeAudition, nextAuditionPick, previousAuditionPick
      Captions: addCaption, splitCaption, resolveOverlaps
      Multicam: createMulticamClip
      Show/Hide: showVideoAnimation, showAudioAnimation, soloAnimation,
                 showTrackingEditor, showCinematicEditor, showMagneticMaskEditor,
                 enableBeatDetection, showPrecisionEditor, showAudioLanes,
                 expandSubroles, showDuplicateRanges, showKeywordEditor,
                 togglePrecisionEditor, toggleSelectedEffectsOff, toggleDuplicateDetection
      Edit Modes AV: insertEditAudio, insertEditVideo, appendEditAudio, appendEditVideo,
                     overwriteEditAudio, overwriteEditVideo, connectEditAudio,
                     connectEditVideo, connectEditBacktimed, avEditModeAudio,
                     avEditModeVideo, avEditModeBoth
      Replace: replaceFromStart, replaceFromEnd, replaceWhole
      Speed Extra: retimeCustomSpeed, retimeInstantReplayHalf, retimeInstantReplayQuarter,
                   retimeReset, retimeOpticalFlow, retimeFrameBlending, retimeFloorFrame
      Keywords: addKeywordGroup1..7
      Color Nav: nextColorEffect, previousColorEffect, resetColorBoard, toggleAllColorOff
      Audio Extra: alignAudioToVideo, volumeMute, toggleMuteAudio, addDefaultAudioEffect,
                   addDefaultVideoEffect, applyAudioFades
      Clip Extra: makeClipsUnique, enableDisable, transcodeMedia, pasteAllAttributes
      Navigate: goToInspector, goToTimeline, goToViewer, goToColorBoard,
                selectNextItem, selectUpperItem
      View: zoomToFit, zoomIn, zoomOut, verticalZoomToFit, zoomToSamples,
            toggleSnapping, toggleSkimming, toggleClipSkimming, toggleAudioSkimming,
            toggleInspector, toggleTimeline, toggleTimelineIndex, toggleInspectorHeight,
            beatDetectionGrid, timelineScrolling, enterFullScreen,
            timelineHistoryBack, timelineHistoryForward
      Project: duplicateProject, snapshotProject, projectProperties
      Library: closeLibrary, libraryProperties, consolidateEventMedia, mergeEvents,
               deleteGeneratedFiles
      Render: renderSelection, renderAll
      Export: exportXML, shareSelection
      Find: find, findAndReplaceTitle
      Reveal: revealInBrowser, revealProjectInBrowser, revealInFinder, moveToTrash
      Other: analyzeAndFix, backgroundTasks, recordVoiceover, editRoles,
             hideClip, removeAllKeywords, removeAnalysisKeywords, addVideoGenerator

    You can also pass any raw ObjC selector name.
    """
    return _call_or_error("timeline.action", action=action)


@mcp.tool(annotations=_tool_annotations("timeline_navigation_action"))
def timeline_navigation_action(action: str) -> str:
    """Use this tool for non-destructive timeline navigation, selection, and view-state actions."""
    if action not in TIMELINE_NAVIGATION_ACTIONS:
        return (
            f"Error: '{action}' is not a supported navigation action. "
            "Use timeline_edit_action(), timeline_destructive_action(), history_action(), or legacy timeline_action()."
        )
    return _call_or_error("timeline.action", action=action)


@mcp.tool(annotations=_tool_annotations("timeline_edit_action"))
def timeline_edit_action(action: str) -> str:
    """Use this tool for non-destructive timeline edits like markers, effects, titles, and range changes."""
    if action not in TIMELINE_EDIT_ACTIONS:
        return (
            f"Error: '{action}' is not a supported non-destructive edit action. "
            "Use timeline_navigation_action(), timeline_destructive_action(), history_action(), or legacy timeline_action()."
        )
    return _call_or_error("timeline.action", action=action)


@mcp.tool(annotations=_tool_annotations("timeline_destructive_action"))
def timeline_destructive_action(action: str) -> str:
    """Use this tool for destructive timeline edits such as delete, cut, blade, replace, trim, and retime."""
    if action not in TIMELINE_DESTRUCTIVE_ACTIONS:
        return (
            f"Error: '{action}' is not a supported destructive action. "
            "Use timeline_navigation_action(), timeline_edit_action(), history_action(), or legacy timeline_action()."
        )
    return _call_or_error("timeline.action", action=action)


@mcp.tool(annotations=_tool_annotations("history_action"))
def history_action(action: str) -> str:
    """Use this tool for timeline history operations that can undo or reapply prior edits."""
    if action not in TIMELINE_HISTORY_ACTIONS:
        return (
            f"Error: '{action}' is not a supported history action. "
            "Valid actions are: undo, redo."
        )
    return _call_or_error("timeline.action", action=action)


@mcp.tool(annotations=_tool_annotations("playback_action"))
def playback_action(action: str) -> str:
    """Use this tool to move playback state without changing timeline content.

    Actions: playPause, goToStart, goToEnd, nextFrame, prevFrame,
             nextFrame10, prevFrame10, playAroundCurrent, playFromStart,
             playInToOut, playReverse, stopPlaying, loop,
             fastForward, rewind,
             playRate1X, playRate2X, playRate4X, playRate8X,
             playRate16X, playRate32X, playRateHalf, playRateMinusHalf,
             playRateMinus1X, playRateMinus2X, playRateMinus32X

    For precise speed control, use set_playback_speed() instead.
    """
    return _call_or_error("playback.action", action=action)


@mcp.tool(annotations=_tool_annotations("set_playback_speed"))
def set_playback_speed(rate: float = None, action: str = None) -> str:
    """Set playback speed to an exact rate, or use shuttle actions.

    Args:
        rate: Exact playback rate as float. Examples:
              0.5 = half speed, 1.0 = normal, 1.5, 1.8,
              2.0 = double speed, -1.0 = reverse normal.
              Supports any float value.
        action: Named speed action. One of:
              "faster" - play forward at configured L speed
              "slower" - play reverse at configured J speed
              "stop" - stop playback

    L/J speed ladders are configurable via Enhancements > Playback Speed menu,
    or via set_bridge_option("lLadder", value=[1, 1.5, 2, 4, 8]).
    Default ladders: [1, 2, 4, 8, 16, 32].
    "faster"/"slower" trigger the swizzled fastForward/rewind which walk
    the configured ladder progressively (like pressing L/J on keyboard).

    Provide either rate OR action, not both.
    """
    if rate is not None and action is not None:
        return "Error: provide either rate or action, not both"

    if rate is not None:
        return _call_or_error("playback.setRate", rate=rate)

    if action is not None:
        if action in ("faster", "slower", "stop"):
            return _call_or_error("playback.shuttle", direction=action)
        return f"Error: unknown action '{action}'. Valid: faster, slower, stop"

    return "Error: provide either rate (float) or action (string)"


@mcp.tool(annotations=_tool_annotations("detect_scene_changes"))
def detect_scene_changes(threshold: float = 0.35, action: str = "detect", sample_interval: float = 0.1) -> str:
    """Use this read-only tool to inspect scene changes before deciding whether to mark or blade them.

    Args:
        threshold: Sensitivity (0.0-1.0). Lower = more sensitive. Default 0.35.
        action: Deprecated compatibility argument. Only "detect" is accepted here.
        sample_interval: Seconds between sampled frames. Default 0.1.

    Returns list of scene change timestamps with confidence scores.
    Uses GPU-style histogram comparison (same approach as FCP internally).
    """
    if action != "detect":
        return "Error: detect_scene_changes() is read-only. Use mark_scene_changes() or blade_scene_changes()."

    r = bridge.call("scene.detect", threshold=threshold, action=action, sampleInterval=sample_interval)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    changes = r.get("sceneChanges", [])
    lines = [f"Scene changes: {r.get('count', 0)} (threshold={r.get('threshold', 0)}, file={r.get('mediaFile', '?')})"]
    if r.get("action") != "detect":
        lines.append(f"Action: {r.get('action')} applied at each scene change")
    lines.append("")
    for sc in changes:
        lines.append(f"  {sc['time']:.2f}s  (score: {sc.get('score', 0):.3f})")
    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("mark_scene_changes"))
def mark_scene_changes(threshold: float = 0.35, sample_interval: float = 0.1) -> str:
    """Use this tool to add markers at detected scene changes without cutting the timeline."""
    return _call_or_error("scene.detect", threshold=threshold, action="markers", sampleInterval=sample_interval)


@mcp.tool(annotations=_tool_annotations("blade_scene_changes"))
def blade_scene_changes(threshold: float = 0.35, sample_interval: float = 0.1) -> str:
    """Use this tool to blade the timeline at detected scene changes."""
    return _call_or_error("scene.detect", threshold=threshold, action="blade", sampleInterval=sample_interval)


@mcp.tool(annotations=_tool_annotations("seek_to_time"))
def seek_to_time(seconds: float) -> str:
    """Use this tool to jump the playhead to an exact time before another operation.

    Args:
        seconds: Time in seconds (e.g. 3.5 = 3 seconds 500ms)

    This is much faster than stepping frames. Use this for all
    time-based positioning before blade, marker, or other operations.
    """
    return _call_or_error("playback.seekToTime", seconds=seconds)


# ============================================================
# Timeline State (structured)
# ============================================================
# Read the timeline's current contents as structured data.
# This is how the AI "sees" what's in the project.

@mcp.tool(annotations=_tool_annotations("get_timeline_clips"))
def get_timeline_clips(limit: int = 100) -> str:
    """Get structured list of all clips in the current timeline.
    Returns: sequence name, playhead time, duration, and for each item:
    index, class, name, duration (seconds), lane, mediaType, selected, handle.
    Handles can be used with get_object_property() for deeper inspection.
    """
    r = bridge.call("timeline.getDetailedState", limit=limit)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    # Build a human-readable table -- the AI reads this to understand the timeline
    lines = []
    lines.append(f"Sequence: {r.get('sequenceName', '?')}")
    pt = r.get("playheadTime", {})
    lines.append(f"Playhead: {pt.get('seconds', 0):.3f}s")
    dur = r.get("duration", {})
    lines.append(f"Duration: {dur.get('seconds', 0):.3f}s")
    lines.append(f"Items: {r.get('itemCount', 0)}")
    lines.append(f"Selected: {r.get('selectedCount', 0)}")

    items = r.get("items", [])
    if items:
        # Two table formats: with start/end times if available, otherwise just duration + lane
        has_pos = any("startTime" in i for i in items)
        if has_pos:
            lines.append(f"\n{'Idx':<4} {'Class':<30} {'Name':<20} {'Start':>8} {'End':>8} {'Duration':>10} {'Sel':>4} {'Handle'}")
            lines.append("-" * 110)
        else:
            lines.append(f"\n{'Idx':<4} {'Class':<30} {'Name':<20} {'Duration':>10} {'Lane':>5} {'Sel':>4} {'Handle'}")
            lines.append("-" * 95)
        for item in items:
            dur_s = item.get("duration", {}).get("seconds", 0)
            if has_pos:
                start_s = item.get("startTime", {}).get("seconds", 0)
                end_s = item.get("endTime", {}).get("seconds", 0)
                lines.append(
                    f"{item.get('index', '?'):<4} "
                    f"{item.get('class', '?'):<30} "
                    f"{str(item.get('name', ''))[:20]:<20} "
                    f"{start_s:>7.2f}s "
                    f"{end_s:>7.2f}s "
                    f"{dur_s:>9.3f}s "
                    f"{'*' if item.get('selected') else ' ':>4} "
                    f"{item.get('handle', '')}"
                )
            else:
                lines.append(
                    f"{item.get('index', '?'):<4} "
                    f"{item.get('class', '?'):<30} "
                    f"{str(item.get('name', ''))[:20]:<20} "
                    f"{dur_s:>9.3f}s "
                    f"{item.get('lane', 0):>5} "
                    f"{'*' if item.get('selected') else ' ':>4} "
                    f"{item.get('handle', '')}"
                )

    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("get_selected_clips"))
def get_selected_clips() -> str:
    """Get only the currently selected clips in the timeline."""
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    items = [i for i in r.get("items", []) if i.get("selected")]
    if not items:
        return "No clips selected"
    return _fmt({"selectedCount": len(items), "items": items})


@mcp.tool(annotations=_tool_annotations("set_timeline_range"))
def set_timeline_range(start_seconds: float, end_seconds: float) -> str:
    """Set the timeline in/out range (mark in/out) to specific times in seconds.
    This positions the playhead and marks the range start and end points.
    Useful for defining export ranges or reviewing specific sections.
    """
    r = bridge.call("timeline.setRange", startSeconds=start_seconds, endSeconds=end_seconds)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return (
        f"Range set: {r.get('startSeconds', 0):.3f}s - {r.get('endSeconds', 0):.3f}s\n"
        f"Mark in: {'OK' if r.get('rangeStartSet') else 'FAILED'}\n"
        f"Mark out: {'OK' if r.get('rangeEndSet') else 'FAILED'}"
    )


@mcp.tool(annotations=_tool_annotations("batch_export"))
def batch_export(scope: str = "all", folder: str = "") -> str:
    """Batch export every clip from the active timeline as individual files.
    A folder picker appears once, then all clips are exported automatically
    with effects/color grading baked in. No further interaction needed.

    Args:
        scope: "all" exports every clip, "selected" exports only selected clips
        folder: Optional output folder path. If empty, a folder picker dialog appears.
    """
    params = {"scope": scope}
    if folder:
        params["folder"] = folder
    r = bridge.call("timeline.batchExport", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    if r.get("status") == "cancelled":
        return "Batch export cancelled by user."

    lines = [
        f"Batch export: {r.get('exported', 0)}/{r.get('total', 0)} clips queued",
        f"Folder: {r.get('folder', '?')}",
    ]
    clips = r.get("clips", [])
    for c in clips:
        start = c.get("startTime", {}).get("seconds", 0)
        end = c.get("endTime", {}).get("seconds", 0)
        lines.append(f"  [{c.get('status', '?')}] {c.get('name', '?')} ({start:.2f}s - {end:.2f}s)")
    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("verify_action"))
def verify_action(description: str = "") -> str:
    """Capture timeline state for before/after verification.
    Call before an action, then after, and compare the snapshots.
    Returns: playhead_seconds, item_count, selected_count, timestamp.
    """
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        # Fallback to basic state
        r = bridge.call("timeline.getState")
        if _err(r):
            return f"Error: {r.get('error', r)}"
    return _fmt({
        "playhead_seconds": r.get("playheadTime", {}).get("seconds", 0),
        "item_count": r.get("itemCount", 0),
        "selected_count": r.get("selectedCount", 0),
        "sequence_name": r.get("sequenceName", ""),
        "description": description,
        "timestamp": time.time()
    })


# ============================================================
# Advanced Method Calling (with arguments)
# ============================================================
# The swiss army knife — call any ObjC method on any object.
# Use this when a specific tool doesn't exist for what you need.

@mcp.tool(annotations=_tool_annotations("call_method_with_args"))
def call_method_with_args(target: str, selector: str, args: str | list = "[]",
                          class_method: bool = True, return_handle: bool = False) -> str:
    """Call any ObjC method with typed arguments via NSInvocation.

    target: class name (e.g. "FFLibraryDocument") or handle ID (e.g. "obj_3")
    selector: method selector (e.g. "copyActiveLibraries" or "openProjectAtURL:")
    args: JSON array of typed arguments (as string or list). Each arg is {"type": "...", "value": ...}
      Types: string, int, double, float, bool, nil, sender, handle, cmtime, selector
      cmtime value: {"value": 30000, "timescale": 600}
    return_handle: if true, store the returned object and return its handle ID

    Warnings:
      - Selectors with out-parameters (error:, askedRetry:, etc.) are invoked with the raw pointer
        bytes you pass in args. Passing [{"type":"nil"}] only works when the selector explicitly
        tolerates a null out pointer.
      - FFAnchoredSequence actionTrimDuration:forEdits:isDelta:error: is known to crash Final Cut
        on a constrained trim if error: is null.
      - If you need an NSArray argument, build it first via NSArray arrayWithObject: and pass the
        returned handle into the real call.

    Examples:
      call_method_with_args("FFLibraryDocument", "copyActiveLibraries", return_handle=True)
      call_method_with_args("obj_3", "displayName", "[]", false)
      call_method_with_args("obj_1", "objectAtIndex:", [{"type":"int","value":0}], false, true)
    """
    # Accept args as either a JSON string or a direct list
    if isinstance(args, list):
        parsed_args = args
    else:
        try:
            parsed_args = json.loads(args)
        except json.JSONDecodeError as e:
            return f"Invalid args JSON: {e}"

    # Safety rail: these selectors crash FCP when the error: out-pointer is nil
    unsafe_nil_error_selectors = {
        "actionTrimDuration:forEdits:isDelta:error:",
        "operationTrimDuration:forEdits:isDelta:error:",
    }
    if selector in unsafe_nil_error_selectors and parsed_args:
        last_arg = parsed_args[-1] if isinstance(parsed_args[-1], dict) else {}
        last_arg_type = last_arg.get("type", "nil")
        if last_arg_type == "nil":
            return (
                f"Refusing {selector} with a nil error: pointer. "
                "This selector is known to crash Final Cut when the trim is constrained. "
                "Use a dedicated safe wrapper instead."
            )

    r = bridge.call("system.callMethodWithArgs",
                    target=target, selector=selector, args=parsed_args,
                    classMethod=class_method, returnHandle=return_handle)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Object Handles
# ============================================================
# The handle system lets you hold references to live ObjC objects
# across multiple tool calls. Think of handles as pointers that
# survive between requests. Always release_all when you're done.

@mcp.tool(annotations=_tool_annotations("manage_handles"))
def manage_handles(action: str = "list", handle: str = "") -> str:
    """Use this legacy handle-management tool when you need both inspection and release operations in one interface.

    Actions:
      list - show all active handles with class names
      inspect <handle> - get details about a handle
      release <handle> - release a specific handle
      release_all - release all handles
    """
    return _handle_management_response(action, handle)


@mcp.tool(annotations=_tool_annotations("list_handles"))
def list_handles() -> str:
    """Use this tool to inspect the currently retained bridge object handles."""
    return _handle_management_response("list")


@mcp.tool(annotations=_tool_annotations("inspect_handle"))
def inspect_handle(handle: str) -> str:
    """Use this tool to inspect one retained bridge object handle."""
    return _handle_management_response("inspect", handle)


@mcp.tool(annotations=_tool_annotations("release_handle"))
def release_handle(handle: str) -> str:
    """Use this tool to release one retained bridge object handle when it is no longer needed."""
    return _handle_management_response("release", handle)


@mcp.tool(annotations=_tool_annotations("release_all_handles"))
def release_all_handles() -> str:
    """Use this tool to release every retained bridge object handle."""
    return _handle_management_response("release_all")


@mcp.tool(annotations=_tool_annotations("get_object_property"))
def get_object_property(handle: str, key: str, return_handle: bool = False) -> str:
    """Use this tool to inspect one property on a retained Objective-C object handle.

    handle: object handle ID (e.g. "obj_3")
    key: property name (e.g. "displayName", "duration", "containedItems")
    return_handle: if true, store the returned value as a new handle

    Example: get_object_property("obj_3", "displayName")
    """
    r = bridge.call("object.getProperty", handle=handle, key=key, returnHandle=return_handle)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("set_object_property"))
def set_object_property(handle: str, key: str, value: str, value_type: str = "string") -> str:
    """Set a property on an object handle using Key-Value Coding.

    WARNING: Direct KVC bypasses undo. For undoable edits, use timeline_action() instead.

    handle: object handle ID
    key: property name
    value: the value to set (as string, will be converted based on value_type)
    value_type: string, int, double, bool, nil
    """
    # Convert the string value to the correct Python type before sending to the bridge
    val_spec = {"type": value_type, "value": value}
    if value_type == "int":
        val_spec["value"] = int(value)
    elif value_type == "double":
        val_spec["value"] = float(value)
    elif value_type == "bool":
        val_spec["value"] = value.lower() in ("true", "1", "yes")
    r = bridge.call("object.setProperty", handle=handle, key=key, value=val_spec)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# FCPXML Import & Generation
# ============================================================
# FCPXML is Apple's interchange format for FCP projects. We can
# generate it programmatically and import it to create complex
# timelines without clicking through FCP's UI.

@mcp.tool(annotations=_tool_annotations("import_fcpxml"))
def import_fcpxml(xml: str, internal: bool = True) -> str:
    """Import FCPXML into FCP. If internal=True, uses PEAppController's import method
    (imports into the running instance without restart). If internal=False, opens via NSWorkspace.
    Provide valid FCPXML as a string.
    """
    r = bridge.call("fcpxml.import", xml=xml, internal=internal)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("generate_fcpxml"))
def generate_fcpxml(event_name: str = "SpliceKit Event", project_name: str = "SpliceKit Project",
                    frame_rate: str = "24", width: int = 1920, height: int = 1080,
                    items: str = "[]") -> str:
    """Generate valid FCPXML for import using OpenTimelineIO.

    Builds an OTIO Timeline from the provided items, then serializes to FCPXML
    via the otio-fcpx-xml-adapter. Title and transition items (which OTIO doesn't
    model natively) are injected as FCPXML-specific post-processing.

    items: JSON array of timeline items. Each item:
      {"type": "gap", "duration": 5.0}
      {"type": "gap", "duration": 5.0, "name": "My Gap"}
      {"type": "title", "text": "Hello World", "duration": 5.0}
      {"type": "title", "text": "Lower Third", "duration": 3.0, "position": "lower-third"}
      {"type": "marker", "time": 2.5, "name": "Review Here", "kind": "standard"}
      {"type": "marker", "time": 5.0, "name": "Chapter 1", "kind": "chapter"}
      {"type": "transition", "duration": 1.0}

    Returns the FCPXML string. Pass to import_fcpxml() or import_otio() to load into FCP.

    Example:
      xml = generate_fcpxml(project_name="Test", items='[
        {"type":"gap","duration":5},
        {"type":"transition","duration":1},
        {"type":"title","text":"Hello","duration":3},
        {"type":"gap","duration":5},
        {"type":"marker","time":2,"name":"Start","kind":"chapter"}
      ]')
      import_fcpxml(xml, internal=True)
    """
    try:
        item_list = json.loads(items)
    except json.JSONDecodeError:
        item_list = []

    # Frame rate string → numeric fps for OTIO RationalTime
    fps_map = {
        "23.976": 23.98, "24": 24, "25": 25, "29.97": 29.97,
        "30": 30, "48": 48, "50": 50, "59.94": 59.94, "60": 60,
    }
    fps = fps_map.get(frame_rate, 24)

    # Separate spine items, markers, titles, and transitions
    spine_items = [i for i in item_list if i.get("type") in ("gap", "title", "transition", None)]
    markers = [i for i in item_list if i.get("type") == "marker"]

    if not spine_items:
        spine_items = [{"type": "gap", "duration": 10.0}]

    # Keep the direct builder for title/transition synthesis. The custom `items`
    # input schema is intentionally tiny and relies on FCP-specific defaults.
    has_fcpxml_only_items = any(i.get("type") in ("title", "transition") for i in spine_items)

    if has_fcpxml_only_items:
        # Fall back to direct FCPXML construction for full feature support
        return _generate_fcpxml_direct(event_name, project_name, frame_rate, width, height, spine_items, markers)

    # Build OTIO Timeline from items
    try:
        import opentimelineio as otio
        from opentimelineio import opentime
    except ImportError:
        return _generate_fcpxml_direct(event_name, project_name, frame_rate, width, height, spine_items, markers)

    timeline = otio.schema.Timeline(name=project_name)
    track = otio.schema.Track(name="V1", kind=otio.schema.TrackKind.Video)

    for item in spine_items:
        itype = item.get("type", "gap")
        idur = item.get("duration", 5.0)
        frames = round(idur * fps)

        if itype == "gap":
            gap = otio.schema.Gap(
                source_range=opentime.TimeRange(
                    start_time=opentime.RationalTime(0, fps),
                    duration=opentime.RationalTime(frames, fps)
                )
            )
            track.append(gap)

    timeline.tracks.append(track)

    # Add markers to the first gap/clip (OTIO attaches markers to items, not the sequence)
    marker_color_map = {
        "standard": otio.schema.MarkerColor.PURPLE,
        "todo": otio.schema.MarkerColor.RED,
        "chapter": otio.schema.MarkerColor.GREEN,
    }
    if markers and len(track) > 0:
        for m in markers:
            mt = m.get("time", 0)
            mname = m.get("name", "Marker")
            mkind = m.get("kind", "standard")
            mdur = m.get("duration", 1.0 / fps)
            marker = otio.schema.Marker(
                name=mname,
                marked_range=opentime.TimeRange(
                    start_time=opentime.RationalTime(round(mt * fps), fps),
                    duration=opentime.RationalTime(max(1, round(mdur * fps)), fps)
                ),
                color=marker_color_map.get(mkind, otio.schema.MarkerColor.PURPLE)
            )
            track[0].markers.append(marker)

    # Serialize to FCPXML via the adapter
    try:
        xml = _otio_write_fcpx_string(timeline)
    except Exception as e:
        # Fall back to direct construction on adapter failure
        return _generate_fcpxml_direct(event_name, project_name, frame_rate, width, height, spine_items, markers)

    return xml


def _generate_fcpxml_direct(event_name, project_name, frame_rate, width, height, spine_items, markers):
    """Direct FCPXML string construction for items that OTIO can't model (titles, transitions)."""
    fr_map = {
        "23.976": (1001, 24000), "24": (100, 2400), "25": (100, 2500),
        "29.97": (1001, 30000), "30": (100, 3000), "48": (100, 4800),
        "50": (100, 5000), "59.94": (1001, 60000), "60": (100, 6000),
    }
    fd_num, fd_den = fr_map.get(frame_rate, (100, 2400))
    fd_str = f"{fd_num}/{fd_den}s"

    def dur_rational(seconds):
        frames = round(seconds * fd_den / fd_num)
        return f"{frames * fd_num}/{fd_den}s"

    spine_xml = ""
    offset_seconds = 0.0
    total_seconds = 0.0
    ts_counter = 1

    for item in spine_items:
        itype = item.get("type", "gap")
        idur = item.get("duration", 5.0)
        iname = item.get("name", "")
        dur_str = dur_rational(idur)
        off_str = dur_rational(offset_seconds)

        if itype == "gap":
            gap_name = iname or "Gap"
            spine_xml += f'            <gap name="{gap_name}" offset="{off_str}" duration="{dur_str}" start="3600s"/>\n'
        elif itype == "title":
            text = item.get("text", "Title")
            title_name = iname or text
            font_size = "63" if item.get("position") != "lower-third" else "42"
            ts_id = f"ts{ts_counter}"
            ts_counter += 1
            spine_xml += f'''            <title name="{title_name}" offset="{off_str}" duration="{dur_str}" start="3600s">
                <text><text-style ref="{ts_id}">{text}</text-style></text>
                <text-style-def id="{ts_id}"><text-style font="Helvetica" fontSize="{font_size}" fontColor="1 1 1 1"/></text-style-def>
            </title>\n'''
        elif itype == "transition":
            spine_xml += f'            <transition name="Cross Dissolve" offset="{off_str}" duration="{dur_str}"/>\n'

        offset_seconds += idur
        total_seconds += idur

    total_dur_str = dur_rational(total_seconds)

    markers_xml = ""
    for m in markers:
        mt = m.get("time", 0)
        mname = m.get("name", "Marker")
        mkind = m.get("kind", "standard")
        moff = dur_rational(mt)
        mdur = dur_rational(m.get("duration", 0) if m.get("duration") else fd_num / fd_den)
        if mkind == "chapter":
            markers_xml += f'            <chapter-marker start="{moff}" duration="{mdur}" value="{mname}" posterOffset="0s"/>\n'
        elif mkind == "todo":
            markers_xml += f'            <marker start="{moff}" duration="{mdur}" value="{mname}" completed="0"/>\n'
        else:
            markers_xml += f'            <marker start="{moff}" duration="{mdur}" value="{mname}"/>\n'

    return f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>
<fcpxml version="1.14">
    <resources>
        <format id="r1" name="FFVideoFormat{width}x{height}p{frame_rate}" frameDuration="{fd_str}" width="{width}" height="{height}"/>
    </resources>
    <library>
        <event name="{event_name}">
            <project name="{project_name}">
                <sequence format="r1" duration="{total_dur_str}" tcStart="0s" tcFormat="NDF">
                    <spine>
{spine_xml}                    </spine>
{markers_xml}                </sequence>
            </project>
        </event>
    </library>
</fcpxml>'''


# ============================================================
# Effects & Color Correction
# ============================================================
# Tools for inspecting and applying effects on clips.

@mcp.tool(annotations=_tool_annotations("get_clip_effects"))
def get_clip_effects(handle: str = "") -> str:
    """Get the effects applied to a clip. If no handle provided, uses the first selected clip.
    Returns effect names, IDs, classes, and handles for further inspection.
    """
    params = {}
    if handle:
        params["handle"] = handle
    r = bridge.call("effects.getClipEffects", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Clip: {r.get('clipName', '?')} ({r.get('clipClass', '?')})"]
    effects = r.get("effects", [])
    lines.append(f"Effects: {r.get('effectCount', len(effects))}")
    for ef in effects:
        lines.append(f"  {ef.get('name', '?')} ({ef.get('class', '?')}) ID={ef.get('effectID', '')} handle={ef.get('handle', '')}")

    if r.get("effectStackHandle"):
        lines.append(f"\nEffect stack handle: {r['effectStackHandle']}")

    return "\n".join(lines)


# ============================================================
# Batch Operations
# ============================================================
# Lets the AI chain many small edits in one round-trip instead
# of making a separate tool call for each step.

@mcp.tool(annotations=_tool_annotations("batch_timeline_actions"))
def batch_timeline_actions(actions: str) -> str:
    """Execute multiple timeline/playback actions in sequence.
    Much more efficient than calling individual tools.

    actions: JSON array of action objects. Each action:
      {"type": "timeline", "action": "blade"}
      {"type": "playback", "action": "nextFrame"}
      {"type": "playback", "action": "nextFrame", "repeat": 30}
      {"type": "wait", "seconds": 0.5}

    Example: blade at 3 positions:
      batch_timeline_actions('[
        {"type":"playback","action":"goToStart"},
        {"type":"playback","action":"nextFrame","repeat":48},
        {"type":"timeline","action":"blade"},
        {"type":"playback","action":"nextFrame","repeat":48},
        {"type":"timeline","action":"blade"},
        {"type":"playback","action":"nextFrame","repeat":48},
        {"type":"timeline","action":"blade"}
      ]')
    """
    try:
        action_list = json.loads(actions)
    except json.JSONDecodeError as e:
        return f"Invalid JSON: {e}"

    results = []
    errors = 0
    for i, act in enumerate(action_list):
        act_type = act.get("type", "timeline")
        action_name = act.get("action", "")
        repeat = act.get("repeat", 1)

        if act_type == "wait":
            secs = act.get("seconds", 0.5)
            time.sleep(secs)
            results.append(f"[{i}] wait {secs}s -> OK")
        elif act_type == "playback":
            r = None
            for _ in range(repeat):
                r = bridge.call("playback.action", action=action_name)
            label = f"[{i}] playback.{action_name}" + (f" x{repeat}" if repeat > 1 else "")
            if r and _err(r):
                errors += 1
                results.append(f"{label} -> FAILED: {r.get('error', '?')}")
            else:
                results.append(f"{label} -> OK")
        elif act_type == "timeline":
            r = None
            for _ in range(repeat):
                r = bridge.call("timeline.action", action=action_name)
            label = f"[{i}] timeline.{action_name}" + (f" x{repeat}" if repeat > 1 else "")
            if r and _err(r):
                errors += 1
                results.append(f"{label} -> FAILED: {r.get('error', '?')}")
            else:
                results.append(f"{label} -> OK")
        else:
            errors += 1
            results.append(f"[{i}] unknown type: {act_type} -> SKIPPED")

    summary = f"Executed {len(action_list)} actions"
    if errors:
        summary += f" ({errors} failed)"
    return summary + ":\n" + "\n".join(results)


# ============================================================
# Timeline Analysis
# ============================================================
# Computes statistics the AI can use to understand the timeline
# before suggesting edits (pacing, flash frames, etc).

@mcp.tool(annotations=_tool_annotations("analyze_timeline"))
def analyze_timeline() -> str:
    """Analyze the current timeline: duration, clip count, pacing stats,
    potential issues (short clips, gaps). Returns a structured report.
    """
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        return f"Error: {r.get('error', r)}"

    items = r.get("items", [])
    total_dur = r.get("duration", {}).get("seconds", 0)
    playhead = r.get("playheadTime", {}).get("seconds", 0)

    # Split items into clips vs transitions for separate stats
    clips = [i for i in items if "Transition" not in i.get("class", "")]
    transitions = [i for i in items if "Transition" in i.get("class", "")]
    durations = [i.get("duration", {}).get("seconds", 0) for i in clips]

    # Flag potential problems: flash frames (<0.5s) and overly long shots (>30s)
    short_clips = [i for i in clips if i.get("duration", {}).get("seconds", 0) < 0.5]
    long_clips = [i for i in clips if i.get("duration", {}).get("seconds", 0) > 30]

    avg_dur = sum(durations) / len(durations) if durations else 0
    min_dur = min(durations) if durations else 0
    max_dur = max(durations) if durations else 0

    # Pacing: compare average clip length in the first vs last quarter
    # to detect if the edit is accelerating or decelerating over time
    pacing = ""
    if len(durations) >= 4:
        q = len(durations) // 4
        q1_avg = sum(durations[:q]) / q if q else 0
        q4_avg = sum(durations[-q:]) / q if q else 0
        if q4_avg < q1_avg * 0.7:
            pacing = "Accelerating (cuts getting faster)"
        elif q4_avg > q1_avg * 1.3:
            pacing = "Decelerating (cuts getting slower)"
        else:
            pacing = "Steady"

    lines = [
        f"=== Timeline Analysis ===",
        f"Sequence: {r.get('sequenceName', '?')}",
        f"Duration: {total_dur:.1f}s ({total_dur/60:.1f}min)",
        f"Playhead: {playhead:.1f}s",
        f"",
        f"Clips: {len(clips)}",
        f"Transitions: {len(transitions)}",
        f"Avg clip duration: {avg_dur:.2f}s",
        f"Shortest clip: {min_dur:.2f}s",
        f"Longest clip: {max_dur:.2f}s",
    ]

    if pacing:
        lines.append(f"Pacing: {pacing}")

    # Issues
    issues = []
    if short_clips:
        issues.append(f"Flash frames: {len(short_clips)} clips < 0.5s")
    if long_clips:
        issues.append(f"Long clips: {len(long_clips)} clips > 30s")

    if issues:
        lines.append(f"\nPotential issues:")
        for issue in issues:
            lines.append(f"  - {issue}")
    else:
        lines.append(f"\nNo issues detected")

    return "\n".join(lines)


# ============================================================
# SRT/Transcript to Markers
# ============================================================
# Bulk marker placement. The bridge handles seeking internally
# so we don't have to move the playhead for each marker.

@mcp.tool(annotations=_tool_annotations("add_markers_at_times"))
def add_markers_at_times(markers: str) -> str:
    """Add multiple markers at specific times in a single batch call.
    Much faster than seeking + adding markers one at a time.

    markers: JSON array of marker objects. Each marker:
      {"time": 5.0, "name": "Scene 1", "kind": "standard"}
      {"time": 15.5, "name": "Chapter 1", "kind": "chapter"}
      {"time": 30.0, "name": "Review", "kind": "todo"}

    kind: "standard" (default), "chapter", or "todo"

    Returns count of markers successfully added.
    """
    try:
        marker_list = json.loads(markers)
    except json.JSONDecodeError as e:
        return f"Invalid JSON: {e}"

    r = bridge.call("timeline.addMarkers", markers=marker_list)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Added {r.get('applied', 0)}/{r.get('count', 0)} markers"]
    for m in r.get("markers", []):
        status = "OK" if m.get("success") else f"FAILED: {m.get('error', '?')}"
        lines.append(f"  {m['time']:.2f}s -> {status}")
    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("blade_at_times"))
def blade_at_times(times: str) -> str:
    """Blade (cut) the timeline at multiple specific times in a single batch call.
    Much faster than seeking + blading one at a time.

    times: JSON array of times in seconds. Example:
      [3.0, 6.0, 9.0, 12.0, 15.0]

    For regular intervals, compute all times first:
      To cut every 3 seconds across a 30-second timeline:
      [3.0, 6.0, 9.0, 12.0, 15.0, 18.0, 21.0, 24.0, 27.0]

    Returns count of cuts successfully applied.
    """
    try:
        time_list = json.loads(times)
    except json.JSONDecodeError as e:
        return f"Invalid JSON: {e}"

    r = bridge.call("timeline.bladeAtTimes", times=time_list)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Applied {r.get('applied', 0)}/{r.get('count', 0)} cuts"]
    for c in r.get("cuts", []):
        status = "OK" if c.get("success") else f"FAILED: {c.get('error', '?')}"
        lines.append(f"  {c['time']:.2f}s -> {status}")
    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("trim_clips_to_beats"))
def trim_clips_to_beats(
    grid: str = "beat",
    randomize: bool = False,
    random_min_step: int = 1,
    random_max_step: int = 4,
    random_seed: int = 1337,
    min_trim_seconds: float = 0.0,
    min_result_duration: float = 0.0,
    source_handle: str = "",
    target_handles: str = "",
    target_mode: str = "auto",
    dry_run: bool = False,
) -> str:
    """Trim video clips so they end on Apple beat-map boundaries from a music clip in the timeline.

    Uses Apple's timing metadata from a beat-detected audio clip already on the timeline.
    It preserves each target clip's start time and shortens the tail so the clip ends on:
      - the nearest valid beat before the current clip end (`grid="beat"`)
      - the nearest valid half-beat before the current clip end (`grid="half_beat"`)
      - the nearest valid bar before the current clip end (`grid="bar"`)

    If `randomize=True`, each clip picks a random valid boundary near its tail within the
    `random_min_step..random_max_step` window counted backward from the clip end.
    For example, with beat grid and `random_min_step=1`, `random_max_step=4`, each clip ends
    on one of the last 1-4 beat boundaries before its current end.

    Source selection:
      - If `source_handle` is provided, use that beat-detected clip.
      - Else prefer a selected beat-detected audio clip.
      - Else auto-discover the first beat-detected audio clip in the active timeline.

    Target selection:
      - If `target_handles` is provided, trim exactly those clips.
      - Else if non-source clips are selected, trim the selected video clips.
      - Else prefer connected/overlay video clips above the source lane.
      - Else trim all visible video clips except the source.

    Args:
        grid: "beat", "half_beat", "quarter_beat", "bar", "section", "random", "random_half_beat", or "random_quarter_beat"
        randomize: When true, pick a random tail-near grid point per clip
        random_min_step: Minimum step backward from the clip end when randomizing
        random_max_step: Maximum step backward from the clip end when randomizing
        random_seed: Seed for deterministic random trims
        min_trim_seconds: Skip trims smaller than this many seconds (0 = auto)
        min_result_duration: Skip trims that would leave a shorter clip than this (0 = auto)
        source_handle: Optional handle of the beat-detected audio clip in the active timeline
        target_handles: Optional JSON array of clip handles to trim
        target_mode: "auto", "selected", "overlay", or "all" when target_handles is omitted
        dry_run: When true, preview the trim plan without modifying the timeline

    Returns a preview or apply summary with the chosen source, grid preview, and per-clip plan.
    """
    parsed_target_handles = []
    if target_handles:
        try:
            parsed_target_handles = json.loads(target_handles)
        except json.JSONDecodeError as e:
            return f"Invalid target_handles JSON: {e}"
        if not isinstance(parsed_target_handles, list):
            return "target_handles must decode to a JSON array of clip handles"

    params = {
        "grid": grid,
        "randomize": randomize,
        "randomMinStep": random_min_step,
        "randomMaxStep": random_max_step,
        "randomSeed": random_seed,
        "dryRun": dry_run,
    }
    if target_mode:
        params["targetMode"] = target_mode
    if min_trim_seconds > 0:
        params["minTrimSeconds"] = min_trim_seconds
    if min_result_duration > 0:
        params["minResultDuration"] = min_result_duration
    if source_handle:
        params["sourceHandle"] = source_handle
    if parsed_target_handles:
        params["targetHandles"] = parsed_target_handles

    r = bridge.call("timeline.trimClipsToBeats", params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    return _format_trim_to_beats_result(r, random_min_step, random_max_step, random_seed)


def _format_trim_to_beats_result(
    response: dict,
    random_min_step: int,
    random_max_step: int,
    random_seed: int,
) -> str:
    source = response.get("source", {})
    lines = [
        f"{'Previewing' if response.get('dryRun') else 'Applied'} {response.get('applied', 0)}/{response.get('planned', 0)} planned trims",
        f"Source: {source.get('name', '<unknown>')}  grid={response.get('grid')}  gridPoints={response.get('gridPointCount', 0)}",
    ]
    tempo = source.get("tempo")
    if tempo:
        lines[-1] += f"  tempo={tempo:.2f}"
    if response.get("targetMode"):
        lines[-1] += f"  targets={response.get('targetMode')}"
    if response.get("randomize"):
        lines.append(
            f"Random window: {random_min_step}-{random_max_step} steps  seed={response.get('randomSeed', random_seed)}"
        )

    preview = response.get("gridPreview", [])
    if preview:
        lines.append("Grid preview: " + ", ".join(f"{float(v):.2f}s" for v in preview))

    for entry in response.get("plan", []):
        status = entry.get("status", "?")
        name = entry.get("name", "")
        if status in {"planned", "applied"}:
            lines.append(
                f"  {name}: {entry['start']:.2f}s -> {entry['targetEnd']:.2f}s "
                f"(trim {entry['trimAmount']:.2f}s, new {entry['newDuration']:.2f}s) [{status}]"
            )
        else:
            lines.append(f"  {name}: {entry.get('reason', 'skipped')} [{status}]")

    return "\n".join(lines)


def _song_cut_preset(pace: str) -> dict | None:
    presets = {
        "natural": {
            "grid": "half_beat",
            "segment_min_step": 1,
            "segment_max_step": 4,
            "step_weights": {"1": 1, "2": 8, "4": 3},
            "label": "mostly whole-beat cuts, sometimes two beats, rarely paired half-beats",
        },
        "medium": {
            "grid": "half_beat",
            "segment_min_step": 2,
            "segment_max_step": 4,
            "label": "1-2 beat cuts on a half-beat grid",
        },
        "fast": {
            "grid": "half_beat",
            "segment_min_step": 1,
            "segment_max_step": 2,
            "step_weights": {"1": 1, "2": 4},
            "label": "half- to full-beat cuts, half-beats always paired",
        },
        "aggressive": {
            "grid": "quarter_beat",
            "segment_min_step": 1,
            "segment_max_step": 4,
            "label": "quarter- to full-beat cuts",
        },
    }
    return presets.get((pace or "").lower())


@mcp.tool(annotations=_tool_annotations("sync_clips_to_song_beats"))
def sync_clips_to_song_beats(
    mode: str = "beat",
    target_mode: str = "auto",
    overlay_only: bool = False,
    source_handle: str = "",
    dry_run: bool = False,
    random_min_step: int = 1,
    random_max_step: int = 4,
    random_seed: int = 1337,
    min_trim_seconds: float = 0.0,
    min_result_duration: float = 0.0,
) -> str:
    """Sync timeline clips to a selected song's Apple beat map with editor-friendly defaults.

    This is the simpler wrapper over `trim_clips_to_beats()`:
      - source clip: selected beat-detected song, or the first detected song in the timeline
      - targets: selected video clips, overlay clips, or all visible clips depending on `target_mode`

    Args:
        mode: "beat", "half_beat", "quarter_beat", "bar", "section", "random", "random_half_beat", or "random_quarter_beat"
        target_mode: "auto", "selected", "overlay", or "all"
        overlay_only: Shortcut for target_mode="overlay"
        source_handle: Optional handle of the beat-detected song clip
        dry_run: Preview the trim plan without changing the timeline
        random_min_step: Random tail-window minimum when mode is random
        random_max_step: Random tail-window maximum when mode is random
        random_seed: Seed for deterministic random trims
        min_trim_seconds: Skip trims below this size (0 = auto)
        min_result_duration: Skip trims that would leave a shorter result (0 = auto)
    """
    effective_target_mode = "overlay" if overlay_only else target_mode
    randomize = mode in {"random", "random_half", "random_half_beat", "random_quarter", "random_quarter_beat"}
    params = {
        "grid": mode,
        "targetMode": effective_target_mode,
        "randomize": randomize,
        "randomMinStep": random_min_step,
        "randomMaxStep": random_max_step,
        "randomSeed": random_seed,
        "dryRun": dry_run,
    }
    if source_handle:
        params["sourceHandle"] = source_handle
    if min_trim_seconds > 0:
        params["minTrimSeconds"] = min_trim_seconds
    if min_result_duration > 0:
        params["minResultDuration"] = min_result_duration

    r = bridge.call("timeline.trimClipsToBeats", params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    return _format_trim_to_beats_result(r, random_min_step, random_max_step, random_seed)


@mcp.tool(annotations=_tool_annotations("build_song_cut"))
def build_song_cut(
    pace: str = "natural",
    project_name: str = "Song Beat Cut",
    event_name: str = "",
    clip_handles: str = "",
    source_handle: str = "",
    source_project_name: str = "",
    clip_source_project_name: str = "",
    max_segments: int = 0,
    random_seed: int = 1337,
    allow_clip_reuse: bool = True,
    include_audio: bool = True,
    build_mode: str = "native",
    target_current_timeline: bool = False,
    dry_run: bool = False,
) -> str:
    """Build a no-gap main-timeline cut against a selected song using simple pacing presets.

    This is the simplified wrapper over `assemble_random_clips_to_song_beats()`:
      - it always creates a contiguous primary-storyline cut
      - it keeps the selected song attached underneath as the timing bed
      - it chooses the beat subdivision and cut length spread from `pace`

    Pace presets:
      - `natural`: mostly whole-beat cuts, sometimes two beats, rarely half-beats
      - `medium`: half-beat grid, random cuts of 1-2 beats
      - `fast`: half-beat grid, random cuts of 0.5-1 beat
      - `aggressive`: quarter-beat grid, random cuts of 0.25-1 beat

    Args:
        pace: "natural", "medium", "fast", or "aggressive"
        project_name: Name of the generated project
        event_name: Optional browser event filter for the clip pool
        clip_handles: Optional JSON array of browser clip handles
        source_handle: Optional handle of the beat-detected song clip in the timeline
        source_project_name: Optional sequence name containing the beat-detected song clip
        clip_source_project_name: Optional sequence name whose timeline clips should form the reusable video pool
        max_segments: Optional hard limit on generated cuts (0 = full song)
        random_seed: Seed for deterministic assembly
        allow_clip_reuse: Reuse browser clips when the pool is smaller than the song
        include_audio: Include the selected song as the audio track in the generated sequence
        build_mode: "native" for direct in-app assembly, or "fcpxml" for the XML import variant
        target_current_timeline: For native builds only, append directly into the active empty timeline instead of creating a new project
        dry_run: Preview the assembly plan without creating the native sequence
    """
    preset = _song_cut_preset(pace)
    if not preset:
        return 'pace must be one of: "natural", "medium", "fast", "aggressive"'

    result = assemble_random_clips_to_song_beats(
        grid=preset["grid"],
        project_name=project_name,
        event_name=event_name,
        clip_handles=clip_handles,
        source_handle=source_handle,
        source_project_name=source_project_name,
        clip_source_project_name=clip_source_project_name,
        segment_min_step=preset["segment_min_step"],
        segment_max_step=preset["segment_max_step"],
        step_weights=json.dumps(preset["step_weights"]) if preset.get("step_weights") else "",
        max_segments=max_segments,
        random_seed=random_seed,
        allow_clip_reuse=allow_clip_reuse,
        include_audio=include_audio,
        build_mode=build_mode,
        target_current_timeline=target_current_timeline,
        dry_run=dry_run,
    )

    prefix = (
        f"Preset: {pace.lower()}  {preset['label']}\n"
        f"Build mode: {build_mode.lower()}\n"
        f"Song attached underneath generated primary storyline"
    )
    return f"{prefix}\n{result}"


@mcp.tool(annotations=_tool_annotations("assemble_random_clips_to_song_beats"))
def assemble_random_clips_to_song_beats(
    grid: str = "half_beat",
    project_name: str = "Beat Random Cut",
    event_name: str = "",
    clip_handles: str = "",
    source_handle: str = "",
    source_project_name: str = "",
    clip_source_project_name: str = "",
    segment_min_step: int = 1,
    segment_max_step: int = 4,
    step_weights: str = "",
    max_segments: int = 0,
    random_seed: int = 1337,
    allow_clip_reuse: bool = True,
    include_audio: bool = True,
    build_mode: str = "native",
    target_current_timeline: bool = False,
    dry_run: bool = False,
) -> str:
    """Build a new sequence by randomly assigning browser clips to a selected song's Apple beat map.

    Uses the Apple beat-detected song already on the active timeline as the timing source,
    or from `source_project_name` when the active timeline is just the target container.
    The generated video clips are placed contiguously on the primary storyline with no gaps;
    the song audio is attached underneath as the timing bed.
    The video pool comes from either:
      - timeline clips in `clip_source_project_name`, or
      - browser clips in the active library:
      - if `clip_handles` is provided, use exactly those browser clips
      - else if `event_name` is provided, pull clips from matching events
      - else use all browser video clips in the active library

    Segment timing:
      - `grid` chooses the beat map: beat, half_beat, quarter_beat, bar, or section
      - `segment_min_step..segment_max_step` controls how many grid intervals each cut spans
      - `step_weights` can bias specific step sizes, for example `{"1": 1, "2": 8, "4": 3}`
      - clips are chosen randomly for each segment, with optional reuse

    Args:
        grid: "beat", "half_beat", "quarter_beat", "bar", or "section"
        project_name: Name of the generated random-cut project
        event_name: Optional browser event filter for the clip pool
        clip_handles: Optional JSON array of browser clip handles
        source_handle: Optional handle of the beat-detected song clip in the timeline
        source_project_name: Optional sequence name containing the beat-detected song clip
        clip_source_project_name: Optional sequence name whose timeline clips form the reusable video pool
        segment_min_step: Minimum number of grid intervals per cut
        segment_max_step: Maximum number of grid intervals per cut
          For example, quarter_beat with 1..4 gives random quarter-, half-, three-quarter-, and full-beat cut lengths.
        step_weights: Optional JSON object mapping step size to relative weight
        max_segments: Optional hard limit on generated cuts (0 = full song)
        random_seed: Seed for deterministic assembly
        allow_clip_reuse: Reuse browser clips when the pool is smaller than the song
        include_audio: Include the selected song as the audio track in the generated sequence
        build_mode: "native" for direct in-app assembly, or "fcpxml" for the XML import variant
        target_current_timeline: For native builds only, append directly into the active empty timeline instead of creating a new project
        dry_run: Preview the assembly plan without creating the native sequence
    """
    parsed_clip_handles = []
    if clip_handles:
        try:
            parsed_clip_handles = json.loads(clip_handles)
        except json.JSONDecodeError as e:
            return f"Invalid clip_handles JSON: {e}"
        if not isinstance(parsed_clip_handles, list):
            return "clip_handles must decode to a JSON array of browser clip handles"

    parsed_step_weights = {}
    if step_weights:
        try:
            parsed_step_weights = json.loads(step_weights)
        except json.JSONDecodeError as e:
            return f"Invalid step_weights JSON: {e}"
        if not isinstance(parsed_step_weights, dict):
            return "step_weights must decode to a JSON object of step -> weight"

    params = {
        "grid": grid,
        "projectName": project_name,
        "segmentMinStep": segment_min_step,
        "segmentMaxStep": segment_max_step,
        "randomSeed": random_seed,
        "allowClipReuse": allow_clip_reuse,
        "includeAudio": include_audio,
        "buildMode": build_mode,
        "targetCurrentTimeline": target_current_timeline,
        "dryRun": dry_run,
    }
    if parsed_step_weights:
        params["stepWeights"] = parsed_step_weights
    if event_name:
        params["eventName"] = event_name
    if parsed_clip_handles:
        params["clipHandles"] = parsed_clip_handles
    if source_handle:
        params["sourceHandle"] = source_handle
    if source_project_name:
        params["sourceProjectName"] = source_project_name
    if clip_source_project_name:
        params["clipSourceProjectName"] = clip_source_project_name
    if max_segments > 0:
        params["maxSegments"] = max_segments

    r = bridge.call("timeline.assembleRandomClipsToBeats", params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    source = r.get("source", {})
    lines = [
        f"{'Previewing' if r.get('dryRun') else 'Built'} {r.get('assignedClipCount', 0)}/{r.get('segmentCount', 0)} beat segments",
        f"Source: {source.get('name', '<unknown>')}  grid={r.get('grid')}  tempo={source.get('tempo', 0):.2f}  pool={r.get('clipPoolCount', 0)}",
        f"Project: {r.get('projectName', project_name)}  build={r.get('buildMethod', 'native')}  gaps={r.get('gapCount', 0)}  seed={r.get('randomSeed', random_seed)}",
    ]
    if not r.get("dryRun"):
        lines.append(
            f"Song attached: {'yes' if r.get('songAudioInserted') else 'no'}"
        )
    for entry in r.get("plan", [])[:12]:
        if entry.get("status") == "gap":
            lines.append(
                f"  gap: {entry.get('timelineStartSeconds', 0):.2f}s +{entry.get('durationSeconds', 0):.2f}s"
            )
        else:
            lines.append(
                f"  {entry.get('clipName', 'Clip')}: {entry.get('timelineStartSeconds', 0):.2f}s "
                f"+{entry.get('durationSeconds', 0):.2f}s from {entry.get('clipEvent', '')}"
            )
    if len(r.get("plan", [])) > 12:
        lines.append(f"  ... {len(r['plan']) - 12} more")
    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("import_srt_as_markers"))
def import_srt_as_markers(srt_content: str) -> str:
    """Import SRT subtitle content as markers in the current timeline.
    Each subtitle becomes a standard marker at the corresponding timecode.

    srt_content: SRT file content as string. Example:
      1
      00:00:05,000 --> 00:00:10,000
      Hello world

      2
      00:01:30,500 --> 00:01:35,000
      Second subtitle
    """
    import re

    # Parse SRT format: sequential blocks of "index / timestamp / text"
    blocks = re.split(r'\n\n+', srt_content.strip())
    marker_list = []

    for block in blocks:
        lines = block.strip().split('\n')
        if len(lines) < 3:  # need at least: index line, timestamp line, text line
            continue

        # We only use the start time -- FCP markers are points, not ranges
        ts_match = re.match(r'(\d{2}):(\d{2}):(\d{2})[,.](\d{3})', lines[1])
        if not ts_match:
            continue

        h, m, s, ms = int(ts_match.group(1)), int(ts_match.group(2)), int(ts_match.group(3)), int(ts_match.group(4))
        total_seconds = h * 3600 + m * 60 + s + ms / 1000.0
        text = ' '.join(lines[2:]).strip()

        marker_list.append({"time": total_seconds, "name": text, "kind": "standard"})

    if not marker_list:
        return "No valid SRT entries found"

    # Single batch call to add all markers at once (no playhead movement needed)
    r = bridge.call("timeline.addMarkers", markers=marker_list)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    applied = r.get("applied", 0)
    result = f"Imported {applied}/{len(marker_list)} markers from SRT"
    failed = [m for m in r.get("markers", []) if not m.get("success")]
    if failed:
        result += f"\nFailed: {len(failed)}"
        for m in failed[:5]:
            result += f"\n  - {m['time']:.1f}s: {m.get('error', '?')}"
    return result


# ============================================================
# Library & Project Management
# ============================================================
# Thin wrappers around FCP's FFLibraryDocument class methods.

@mcp.tool(annotations=_tool_annotations("get_active_libraries"))
def get_active_libraries() -> str:
    """Get list of currently open libraries in FCP."""
    r = bridge.call("system.callMethodWithArgs", target="FFLibraryDocument",
                    selector="copyActiveLibraries", args=[], classMethod=True, returnHandle=True)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("is_library_updating"))
def is_library_updating() -> str:
    """Check if any library is currently being updated/saved."""
    r = bridge.call("system.callMethod", className="FFLibraryDocument",
                    selector="isAnyLibraryUpdating", classMethod=True)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Runtime Introspection
# ============================================================
# Reverse-engineering tools — enumerate classes, explore methods,
# inspect the class hierarchy. Use these to discover new APIs.

@mcp.tool(annotations=_tool_annotations("get_classes"))
def get_classes(filter: str = "") -> str:
    """List ObjC classes loaded in FCP's process.
    Common prefixes: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit), TK (TimelineKit), IX (Interchange).
    """
    r = bridge.call("system.getClasses", filter=filter) if filter else bridge.call("system.getClasses")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    classes = r.get("classes", [])
    count = r.get("count", len(classes))
    if count > 200:
        return f"Found {count} classes matching '{filter}'. Showing first 200:\n" + "\n".join(classes[:200])
    return f"Found {count} classes:\n" + "\n".join(classes)


@mcp.tool(annotations=_tool_annotations("get_methods"))
def get_methods(class_name: str, include_super: bool = False) -> str:
    """List all methods on an ObjC class with type encodings."""
    r = bridge.call("system.getMethods", className=class_name, includeSuper=include_super)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    lines = [f"=== {class_name} ==="]
    lines.append(f"\nInstance methods ({r.get('instanceMethodCount', 0)}):")
    for name in sorted(r.get("instanceMethods", {}).keys()):
        info = r["instanceMethods"][name]
        lines.append(f"  - {name}  ({info.get('typeEncoding', '')})")
    lines.append(f"\nClass methods ({r.get('classMethodCount', 0)}):")
    for name in sorted(r.get("classMethods", {}).keys()):
        info = r["classMethods"][name]
        lines.append(f"  + {name}  ({info.get('typeEncoding', '')})")
    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("get_properties"))
def get_properties(class_name: str) -> str:
    """List declared @property definitions on an ObjC class."""
    r = bridge.call("system.getProperties", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    lines = [f"{class_name}: {r.get('count', 0)} properties"]
    for p in r.get("properties", []):
        lines.append(f"  {p['name']}: {p['attributes']}")
    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("get_ivars"))
def get_ivars(class_name: str) -> str:
    """List instance variables of an ObjC class with their types."""
    r = bridge.call("system.getIvars", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    lines = [f"{class_name}: {r.get('count', 0)} ivars"]
    for iv in r.get("ivars", []):
        lines.append(f"  {iv['name']}: {iv['type']}")
    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("get_protocols"))
def get_protocols(class_name: str) -> str:
    """List protocols adopted by an ObjC class."""
    r = bridge.call("system.getProtocols", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return f"{class_name}: {r.get('count', 0)} protocols\n" + "\n".join(f"  {p}" for p in r.get("protocols", []))


@mcp.tool(annotations=_tool_annotations("get_superchain"))
def get_superchain(class_name: str) -> str:
    """Get the inheritance chain for an ObjC class."""
    r = bridge.call("system.getSuperchain", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return " -> ".join(r.get("superchain", []))


@mcp.tool(annotations=_tool_annotations("explore_class"))
def explore_class(class_name: str) -> str:
    """Comprehensive overview of an ObjC class: inheritance, protocols, properties, ivars, key methods."""
    lines = [f"=== {class_name} ===\n"]
    r = bridge.call("system.getSuperchain", className=class_name)
    if not _err(r):
        lines.append("Inheritance: " + " -> ".join(r.get("superchain", [])))
    r = bridge.call("system.getProtocols", className=class_name)
    if not _err(r) and r.get("count", 0) > 0:
        lines.append(f"\nProtocols ({r['count']}): " + ", ".join(r.get("protocols", [])))
    r = bridge.call("system.getProperties", className=class_name)
    if not _err(r) and r.get("count", 0) > 0:
        lines.append(f"\nProperties ({r['count']}):")
        for p in r.get("properties", [])[:30]:
            lines.append(f"  {p['name']}")
    r = bridge.call("system.getIvars", className=class_name)
    if not _err(r) and r.get("count", 0) > 0:
        lines.append(f"\nIvars ({r['count']}):")
        for iv in r.get("ivars", [])[:15]:
            lines.append(f"  {iv['name']}: {iv['type']}")
    r = bridge.call("system.getMethods", className=class_name)
    if not _err(r):
        im = r.get("instanceMethodCount", 0)
        cm = r.get("classMethodCount", 0)
        lines.append(f"\nMethods: {im} instance, {cm} class")
        if cm > 0:
            lines.append(f"\nClass methods:")
            for name in sorted(r.get("classMethods", {}).keys()):
                lines.append(f"  + {name}")
        # Surface the most interesting methods -- the ones an AI is likely to want to call
        keywords = ['get', 'set', 'current', 'active', 'selected', 'add', 'remove',
                    'create', 'delete', 'open', 'close', 'name', 'items', 'clip', 'effect', 'marker']
        notable = [m for m in sorted(r.get("instanceMethods", {}).keys()) if any(k in m.lower() for k in keywords)]
        if notable:
            lines.append(f"\nNotable instance methods ({len(notable)} of {im}):")
            for m in notable[:50]:
                lines.append(f"  - {m}")
    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("search_methods"))
def search_methods(class_name: str, keyword: str) -> str:
    """Search for methods on a class by keyword."""
    r = bridge.call("system.getMethods", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    lines = []
    for name in sorted(r.get("instanceMethods", {}).keys()):
        if keyword.lower() in name.lower():
            lines.append(f"  - {name}  ({r['instanceMethods'][name].get('typeEncoding', '')})")
    for name in sorted(r.get("classMethods", {}).keys()):
        if keyword.lower() in name.lower():
            lines.append(f"  + {name}  ({r['classMethods'][name].get('typeEncoding', '')})")
    if not lines:
        return f"No methods matching '{keyword}' on {class_name}"
    return f"Methods matching '{keyword}' on {class_name} ({len(lines)}):\n" + "\n".join(lines)


# -- Low-level escape hatches for arbitrary ObjC calls --

@mcp.tool(annotations=_tool_annotations("call_method"))
def call_method(class_name: str, selector: str, class_method: bool = True) -> str:
    """Call a zero-argument ObjC method. For methods WITH arguments, use call_method_with_args instead."""
    r = bridge.call("system.callMethod", className=class_name, selector=selector, classMethod=class_method)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("raw_call"))
def raw_call(method: str, params: str = "{}") -> str:
    """Send a raw JSON-RPC call to SpliceKit. Last resort when no other tool fits."""
    try:
        p = json.loads(params)
    except json.JSONDecodeError as e:
        return f"Invalid JSON params: {e}"
    r = bridge.call(method, **p)
    return _fmt(r)


# ============================================================
# Transcript-Based Editing
# ============================================================
# Text-based editing: transcribe clips, then edit the video by
# editing the text. Delete words to remove video segments,
# drag words to reorder clips.

@mcp.tool(annotations=_tool_annotations("open_transcript"))
def open_transcript(file_url: str = "", force_retranscribe: bool = False) -> str:
    """Open the transcript panel and start transcribing.

    If no file_url is provided, transcribes all clips on the current timeline.
    If file_url is provided, transcribes that specific audio/video file.

    By default, if a persisted transcript exists it will be restored without
    re-running analysis. Set force_retranscribe=True to discard the cache
    and run a fresh transcription.

    The transcript panel allows text-based editing:
    - Clicking a word jumps the playhead to that time
    - Deleting words removes those segments from the timeline
    - Dragging words reorders clips on the timeline

    Transcription is async - use get_transcript() to check progress and results.
    """
    params = {}
    if file_url:
        params["fileURL"] = file_url
    if force_retranscribe:
        params["forceRetranscribe"] = True
    r = bridge.call("transcript.open", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("get_transcript"))
def get_transcript() -> str:
    """Get the current transcript state, including all words with timestamps, speakers, and silences.

    Returns:
    - status: idle/transcribing/ready/error
    - wordCount: number of transcribed words
    - silenceCount: number of detected pauses/silences
    - text: full transcript text (with segment headers and silence markers)
    - words: array of {index, text, startTime, endTime, duration, confidence, speaker}
    - silences: array of {startTime, endTime, duration, startTimecode, endTimecode}
    - progress: {completed, total} when transcribing

    Use this after open_transcript() to check when transcription is complete
    and to get the word list for editing operations.
    """
    r = bridge.call("transcript.getState")
    if _err(r):
        return f"Error: {r.get('error', r)}"

    # Format nicely
    lines = [f"Status: {r.get('status', 'unknown')}"]
    lines.append(f"Words: {r.get('wordCount', 0)}")
    lines.append(f"Silences: {r.get('silenceCount', 0)}")
    lines.append(f"Silence threshold: {r.get('silenceThreshold', 0.3):.1f}s")

    if r.get('gapBuckets'):
        gb = r['gapBuckets']
        buckets = ' | '.join(f">={k}: {gb[k]}" for k in sorted(gb.keys()))
        lines.append(f"Gap histogram: {buckets}")

    if r.get('progress'):
        p = r['progress']
        lines.append(f"Progress: {p.get('completed', 0)}/{p.get('total', 0)} clips")

    if r.get('text'):
        text = r['text']
        if len(text) > 2000:
            text = text[:2000] + "..."
        lines.append(f"\nTranscript:\n{text}")

    if r.get('silences'):
        lines.append(f"\nSilences ({len(r['silences'])} pauses):")
        for s in r['silences']:
            lines.append(f"  {s.get('startTimecode', '?')} - {s.get('endTimecode', '?')} "
                         f"({s['duration']:.1f}s) after word [{s.get('afterWordIndex', '?')}]")

    if r.get('words'):
        lines.append(f"\nWord list ({len(r['words'])} words):")
        for w in r['words']:
            conf = w.get('confidence', 0) * 100
            speaker = w.get('speaker', 'Unknown')
            lines.append(f"  [{w['index']:3d}] {w['startTime']:7.2f}s - {w['endTime']:7.2f}s "
                         f"({conf:3.0f}%) [{speaker}] \"{w['text']}\"")

    if r.get('error'):
        lines.append(f"\nError: {r['error']}")

    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("delete_transcript_words"))
def delete_transcript_words(start_index: int, count: int) -> str:
    """Delete words from the transcript, which removes the corresponding video segments.

    This performs a ripple delete on the timeline:
    1. Blades at the start time of the first word
    2. Blades at the end time of the last word
    3. Selects and deletes the segment between the blades

    Args:
        start_index: Index of the first word to delete (from get_transcript word list)
        count: Number of consecutive words to delete

    The timeline gap closes automatically (ripple delete).
    Use timeline_action("undo") to reverse.
    """
    r = bridge.call("transcript.deleteWords", startIndex=start_index, count=count)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("move_transcript_words"))
def move_transcript_words(start_index: int, count: int, dest_index: int) -> str:
    """Move words in the transcript to a new position, which reorders clips on the timeline.

    This performs a cut-and-paste on the timeline:
    1. Blades at source start/end to isolate the segment
    2. Cuts the segment
    3. Moves playhead to the destination position
    4. Pastes the segment

    Args:
        start_index: Index of the first word to move
        count: Number of consecutive words to move
        dest_index: Target position in the word list (the words will be inserted before this index)

    Use timeline_action("undo") to reverse.
    """
    r = bridge.call("transcript.moveWords", startIndex=start_index, count=count, destIndex=dest_index)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("close_transcript"))
def close_transcript() -> str:
    """Close the transcript panel."""
    r = bridge.call("transcript.close")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Transcript panel closed."


@mcp.tool(annotations=_tool_annotations("search_transcript"))
def search_transcript(query: str) -> str:
    """Search the transcript for text or special keywords.

    Args:
        query: Search text to find in the transcript.
               Special keywords: "pauses" or "silences" to find all detected pauses.

    Returns matching words or silences with timestamps.
    Also updates the UI to highlight matches.
    """
    r = bridge.call("transcript.search", query=query)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Query: {r.get('query', query)}"]
    lines.append(f"Results: {r.get('resultCount', 0)}")

    results = r.get("results", [])
    for res in results:
        if res.get("type") == "silence":
            lines.append(f"  [Pause] {res['startTime']:.2f}s - {res['endTime']:.2f}s ({res['duration']:.1f}s)")
        else:
            lines.append(f"  [{res.get('index', '?'):3d}] {res['startTime']:.2f}s - {res['endTime']:.2f}s "
                         f"({res.get('confidence', 0)*100:.0f}%) \"{res.get('text', '')}\"")

    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("delete_transcript_silences"))
def delete_transcript_silences(min_duration: float = 0.0) -> str:
    """Delete all detected silences/pauses from the timeline.

    This performs batch ripple-deletes on all silence gaps, removing dead air
    from the video. Silences are deleted from end to start to maintain accuracy.

    Args:
        min_duration: Minimum silence duration in seconds to delete. Default 0 = all silences.
                      Use 0.5 to only delete pauses longer than half a second, etc.

    Use timeline_action("undo") repeatedly to reverse.
    """
    r = bridge.call("transcript.deleteSilences", minDuration=min_duration)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Status: {r.get('status', 'unknown')}"]
    lines.append(f"Deleted: {r.get('deletedCount', 0)}/{r.get('totalSilences', 0)} silences")
    if r.get("lastError"):
        lines.append(f"Last error: {r['lastError']}")

    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("set_transcript_speaker"))
def set_transcript_speaker(start_index: int, count: int, speaker: str) -> str:
    """Assign a speaker name to a range of words in the transcript.

    Args:
        start_index: Index of the first word to label
        count: Number of consecutive words to label
        speaker: Speaker name (e.g., "Host", "Guest", "Speaker 1")

    This updates the speaker labels in the transcript display.
    """
    r = bridge.call("transcript.setSpeaker", speaker=speaker, startIndex=start_index, count=count)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("set_silence_threshold"))
def set_silence_threshold(threshold: float) -> str:
    """Set the minimum gap duration (seconds) to detect as a silence/pause.

    Args:
        threshold: Duration in seconds. Default is 0.3 (300ms).
                   Lower values detect shorter pauses, higher values only long ones.

    Takes effect immediately — silences are recomputed from existing word
    timings without re-transcription. Returns the updated silence count.
    """
    r = bridge.call("transcript.setSilenceThreshold", threshold=threshold)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Effects (video filters, generators, titles, audio)
# ============================================================
# Enumerate FCP's installed effects and apply them to clips.
# FCP organizes effects by type (filter, generator, title, audio).

@mcp.tool(annotations=_tool_annotations("list_effects"))
def list_effects(type: str = "filter", filter: str = "") -> str:
    """List available effects in FCP by type.

    Args:
        type: "filter" (video effects), "generator", "title", "audio", or "all"
        filter: Optional search string to filter by name or category.

    Returns effect name, effectID, category, and type for each.
    Use the effectID or name with apply_effect() to add one.
    """
    params = {"type": type}
    if filter:
        params["filter"] = filter
    r = bridge.call("effects.listAvailable", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    effects = r.get("effects", [])
    lines = [f"Available {type} effects: {r.get('count', len(effects))}"]
    lines.append("")

    if effects:
        lines.append(f"{'Name':<30} {'Category':<25} {'Type':<12} {'Effect ID'}")
        lines.append("-" * 100)
        for e in effects:
            lines.append(
                f"{e['name']:<30} {e.get('category', ''):<25} "
                f"{e.get('type', ''):<12} {e['effectID'][:40]}"
            )
    else:
        lines.append("No effects found.")

    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("apply_effect"))
def apply_effect(name: str = "", effectID: str = "") -> str:
    """Apply a video effect, generator, or title to the selected clip(s).

    Select a clip first with timeline_action("selectClipAtPlayhead").
    Use list_effects() to see available effects.

    Args:
        name: Display name of the effect (e.g. "Gaussian Blur", "Vignette")
        effectID: The effect ID string

    Supports undo via timeline_action("undo").
    """
    if not name and not effectID:
        return "Error: provide either name or effectID"

    params = {}
    if effectID:
        params["effectID"] = effectID
    if name:
        params["name"] = name

    r = bridge.call("effects.apply", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    return f"Applied effect: {r.get('effect', '?')} ({r.get('effectID', '')})"


# ============================================================
# Transitions
# ============================================================
# FCP has 376+ built-in transitions. These tools enumerate them
# and apply them at edit points (between adjacent clips).

@mcp.tool(annotations=_tool_annotations("list_transitions"))
def list_transitions(filter: str = "") -> str:
    """List all available video transitions installed in FCP.

    Returns transition name, effectID, and category for each.
    Use the effectID or name with apply_transition() to add one.

    Args:
        filter: Optional search string to filter by name or category.
    """
    params = {}
    if filter:
        params["filter"] = filter
    r = bridge.call("transitions.list", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    transitions = r.get("transitions", [])
    default = r.get("defaultTransition", {})

    lines = [f"Available transitions: {r.get('count', len(transitions))}"]
    lines.append(f"Default: {default.get('name', '?')} ({default.get('effectID', '?')})")
    lines.append("")

    if transitions:
        lines.append(f"{'Name':<30} {'Category':<30} {'Effect ID'}")
        lines.append("-" * 90)
        for t in transitions:
            lines.append(
                f"{t['name']:<30} {t.get('category', ''):<30} {t['effectID'][:50]}"
            )
    else:
        lines.append("No transitions found.")

    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("apply_transition"))
def apply_transition(name: str = "", effectID: str = "", freeze_extend: bool = True) -> str:
    """Apply a specific transition at the current edit point.

    You can specify the transition by display name or effectID.
    Use list_transitions() to see available transitions.

    Args:
        name: Display name of the transition (e.g. "Cross Dissolve", "Flow")
        effectID: The effect ID (e.g. "FxPlug:4731E73A-...")
        freeze_extend: If True, automatically resolve missing-media transitions with freeze frames
            when there isn't enough media for the transition. This avoids the
            "not enough extra media" dialog and prevents ripple trimming.

    The transition is applied at the selected edit point (between clips).
    Select an edit point first with timeline_action("nextEdit") or
    timeline_action("previousEdit").
    """
    if not name and not effectID:
        return "Error: provide either name or effectID"

    params = {}
    if effectID:
        params["effectID"] = effectID
    if name:
        params["name"] = name
    if freeze_extend:
        params["freezeExtend"] = True

    r = bridge.call("transitions.apply", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    msg = f"Applied transition: {r.get('transition', '?')} ({r.get('effectID', '')})"
    if r.get("freezeExtended"):
        msg += " (missing-media fixed with freeze frames)"
    return msg


@mcp.tool(annotations=_tool_annotations("apply_transition_to_all_clips"))
def apply_transition_to_all_clips() -> str:
    """Apply the default transition (Cross Dissolve) between every clip on the timeline.

    This selects all clips and adds the default transition at every edit point
    in a single operation. Much faster than applying transitions one at a time.

    Use list_transitions() to see which transition is currently set as default.
    """
    r = bridge.call("command.execute", action="addTransitionToAll", type="timeline")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Command Palette
# ============================================================
# A floating search palette (like VS Code's Cmd+Shift+P) that
# can also pipe queries through Apple Intelligence for natural
# language editing commands.

@mcp.tool(annotations=_tool_annotations("show_command_palette"))
def show_command_palette() -> str:
    """Open the command palette inside FCP.
    The palette provides quick access to all FCP actions via fuzzy search,
    and supports natural language commands via Apple Intelligence.
    Shortcut: Cmd+Shift+P
    """
    r = bridge.call("command.show")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Command palette opened."


@mcp.tool(annotations=_tool_annotations("hide_command_palette"))
def hide_command_palette() -> str:
    """Close the command palette."""
    r = bridge.call("command.hide")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Command palette closed."


@mcp.tool(annotations=_tool_annotations("search_commands"))
def search_commands(query: str, limit: int = 20) -> str:
    """Search available FCP commands by name, keyword, or category.

    Returns matching commands sorted by relevance. Each result includes:
    name, action, type (timeline/playback/transcript), category, detail, shortcut.

    Use execute_command() to run one of the results.
    """
    r = bridge.call("command.search", query=query, limit=limit)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    commands = r.get("commands", [])
    if not commands:
        return f"No commands match '{query}'"

    lines = [f"Found {r.get('total', len(commands))} matches:"]
    for cmd in commands:
        shortcut = f"  [{cmd['shortcut']}]" if cmd.get("shortcut") else ""
        lines.append(f"  {cmd['name']:<30} {cmd['category']:<12} {cmd['type']}/{cmd['action']}{shortcut}")
        if cmd.get("detail"):
            lines.append(f"    {cmd['detail']}")

    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("execute_command"))
def execute_command(action: str, type: str = "timeline") -> str:
    """Execute a command from the palette by action name.

    Args:
        action: The action ID (e.g. "blade", "addColorBoard", "retimeSlow50")
        type: "timeline", "playback", or "transcript"

    This is equivalent to selecting a command in the palette and pressing Enter.
    """
    r = bridge.call("command.execute", action=action, type=type)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("ai_command"))
def ai_command(query: str) -> str:
    """Use Apple Intelligence (on-device LLM) to interpret a natural language
    editing instruction and execute the appropriate FCP actions.

    Examples:
      "cut at 3 seconds"
      "slow this clip to half speed"
      "add color correction"
      "go to the beginning and play"
      "add a chapter marker"

    The LLM translates your description into a sequence of FCP actions and
    executes them automatically. Falls back to keyword matching if Apple
    Intelligence is not available on this Mac.
    """
    r = bridge.call("command.ai", query=query)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    # Apple Intelligence+ (agentic) returns a summary string, not actions
    if r.get("summary"):
        return r["summary"]

    actions = r.get("actions", [])
    if not actions:
        return "No actions determined from query."

    # Execute a single AI action, dispatching by type
    def _exec_one(act):
        act_type = act.get("type", "timeline")
        action_name = act.get("action", "")
        repeat = act.get("repeat", 1)

        if act_type == "seek":
            secs = act.get("seconds", 0)
            er = bridge.call("playback.seekToTime", seconds=secs)
            if _err(er):
                return f"Error on seek({secs}s): {er.get('error', er)}"
            return f"seek -> {secs}s"

        if act_type == "effect":
            eff_name = act.get("name", "")
            # Auto-select clip at playhead first
            bridge.call("timeline.action", action="selectClipAtPlayhead")
            er = bridge.call("effects.apply", name=eff_name)
            if _err(er):
                return f"Error on effect '{eff_name}': {er.get('error', er)}"
            return f"effect '{eff_name}' -> ok"

        if act_type == "transition":
            tr_name = act.get("name", "")
            er = bridge.call("transitions.apply", name=tr_name, freezeExtend=True)
            if _err(er):
                return f"Error on transition '{tr_name}': {er.get('error', er)}"
            return f"transition '{tr_name}' -> ok"

        if act_type == "repeat_pattern":
            count = act.get("count", 1)
            inner = act.get("actions", [])
            msgs = []
            for i in range(count):
                for sub in inner:
                    msgs.append(_exec_one(sub))
            return f"repeat_pattern x{count}: " + "; ".join(msgs)

        if act_type == "scene_detect":
            er = bridge.call("scene.detect", threshold=0.35, action="detect", sampleInterval=0.1)
            if _err(er):
                return f"Error on scene_detect: {er.get('error', er)}"
            return f"scene_detect -> {er.get('count', 0)} changes"

        if act_type == "scene_markers":
            er = bridge.call("scene.detect", threshold=0.35, action="markers", sampleInterval=0.1)
            if _err(er):
                return f"Error on scene_markers: {er.get('error', er)}"
            return f"scene_markers -> {er.get('count', 0)} markers"

        # timeline, playback, or any other type with an action field
        for _ in range(repeat):
            er = bridge.call(f"{act_type}.action", action=action_name)
            if _err(er):
                return f"Error on {act_type}.{action_name}: {er.get('error', er)}"
        return f"{act_type}.{action_name}" + (f" x{repeat}" if repeat > 1 else "") + " -> ok"

    # Apple Intelligence returns a list of FCP actions — execute them in order
    results = []
    for act in actions:
        results.append(_exec_one(act))

    return f"AI executed {len(actions)} action(s):\n" + "\n".join(results)


@mcp.tool(annotations=_tool_annotations("ai_command_gemma"))
def ai_command_gemma(query: str, model: str = "unsloth/gemma-4-E4B-it-UD-MLX-4bit") -> str:
    """Use Gemma 4 (via MLX on Apple Silicon) for agentic natural language editing.
    Unlike ai_command which uses a fixed action schema, this runs a multi-turn
    tool-calling loop and can access all bridge methods.
    Requires mlx-lm server: python -m mlx_lm.server --model unsloth/gemma-4-E4B-it-UD-MLX-4bit

    Args:
        query: Natural language editing instruction
        model: HuggingFace model ID (default: unsloth/gemma-4-E4B-it-UD-MLX-4bit)
    """
    r = bridge.call("command.aiGemma", query=query, model=model)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return r.get("summary", "Done.")


# ============================================================
# Menu Execute (universal menu access)
# ============================================================
# Fallback for anything that doesn't have a dedicated tool.
# Walks FCP's NSMenu hierarchy by title to reach any menu item.

@mcp.tool(annotations=_tool_annotations("execute_menu_command"))
def execute_menu_command(menu_path: list[str]) -> str:
    """Execute ANY FCP menu command by navigating the menu bar hierarchy.

    Args:
        menu_path: List of menu item names from top to bottom.
                   e.g. ["File", "New", "Project"] or ["Edit", "Paste as Connected Clip"]

    This gives you access to every single menu item in FCP, including items
    that don't have dedicated SpliceKit actions. Menu items are matched
    case-insensitively and trailing ellipsis (...) is ignored.
    """
    r = bridge.call("menu.execute", menuPath=menu_path)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("list_menus"))
def list_menus(menu: str = "", depth: int = 2) -> str:
    """List FCP menu items to discover available commands.

    Args:
        menu: Optional top-level menu name (e.g. "File", "Edit", "Modify").
              If empty, lists all top-level menus.
        depth: How deep to recurse into submenus (default 2).

    Returns structured list of menu items with shortcuts and enabled status.
    """
    params = {"depth": depth}
    if menu:
        params["menu"] = menu
    r = bridge.call("menu.list", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Inspector Properties (read/write clip properties)
# ============================================================
# Reads/writes FCP's internal effect parameter channels directly,
# bypassing the inspector UI. Works on transform, compositing, audio, crop.

@mcp.tool(annotations=_tool_annotations("get_inspector_properties"))
def get_inspector_properties(property: str = "all") -> str:
    """Read properties of the selected clip from the inspector.

    Args:
        property: Which properties to read. Options:
                  "all" - transform, compositing, audio, crop values
                  "transform" - positionX/Y/Z, rotation, scaleX/Y, anchorX/Y
                  "compositing" - opacity (0.0-1.0), blend mode handle
                  "audio" - volume level (linear gain)
                  "crop" - left, right, top, bottom crop values
                  "info" - clip name, class, effect stack presence
                  "channels" - ALL effect channels with handles for direct access

    Returns actual numeric values from FCP's internal effect parameter channels.
    Requires a clip to be selected first (use timeline_action("selectClipAtPlayhead")).
    """
    r = bridge.call("inspector.get", property=property)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("set_inspector_property"))
def set_inspector_property(property: str, value: float | str | bool) -> str:
    """Set a property on the selected clip's effect parameters.

    Args:
        property: Property name to set:
                  "opacity" - 0.0 to 1.0 (0% to 100%)
                  "positionX" - horizontal position in pixels (0 = center)
                  "positionY" - vertical position in pixels (0 = center)
                  "positionZ" - Z depth
                  "rotation" - rotation in degrees
                  "scaleX" - horizontal scale (100 = 100%)
                  "scaleY" - vertical scale (100 = 100%)
                  "anchorX" - anchor point X
                  "anchorY" - anchor point Y
                  "volume" - audio volume (linear gain, 1.0 = 0dB)
                  "handle:<handle_id>" - set any channel directly by handle
        value: New numeric value to set

    Changes are undoable (Cmd+Z). Creates the transform effect if it doesn't exist yet.
    Requires a clip to be selected first.
    """
    r = bridge.call("inspector.set", property=property, value=value)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("get_title_text"))
def get_title_text() -> str:
    """Read text content, font, and size from the selected Motion title clip.

    Inspects the selected clip's effect channel tree to find CHChannelText nodes.
    Returns the rendered text string, font family, font name, and point size as
    stored in the NSAttributedString on the text channel.

    This is useful for verifying that title text imported via FCPXML actually
    rendered with the correct content and font size.

    Requires a title clip to be selected first (use timeline_action("selectClipAtPlayhead")).
    """
    r = bridge.call("inspector.getTitle")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("verify_captions"))
def verify_captions() -> str:
    """Verify that generated captions rendered correctly on the timeline.

    Checks the most recently generated captions by inspecting their text channels.
    Returns verification results: text content, font size, font family for each
    title that can be found. Reports any mismatches from the expected style.

    Run this after generate_captions() to confirm titles have visible text at
    the correct font size, without needing to ask the user to check manually.
    """
    r = bridge.call("captions.verify")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# View/Panel Toggles
# ============================================================
# Show/hide FCP's various panels and viewers.

@mcp.tool(annotations=_tool_annotations("toggle_panel"))
def toggle_panel(panel: str) -> str:
    """Show or hide a panel/viewer in the FCP interface.

    Args:
        panel: Panel to toggle. Options:
               inspector, timeline, browser, eventViewer,
               effectsBrowser, transitionsBrowser,
               videoScopes, histogram, vectorscope, waveform, audioMeter,
               keywordEditor, timelineIndex, precisionEditor, retimeEditor,
               audioCurves, videoAnimation, audioAnimation,
               multicamViewer, 360viewer, fullscreenViewer,
               backgroundTasks, voiceover, comparisonViewer
    """
    r = bridge.call("view.toggle", panel=panel)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("set_workspace"))
def set_workspace(workspace: str) -> str:
    """Switch to a predefined workspace layout.

    Args:
        workspace: "default", "organize", "colorEffects", or "dualDisplays"
    """
    r = bridge.call("view.workspace", workspace=workspace)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Tool Selection
# ============================================================
# Switch the active editing tool (blade, trim, range, etc).

@mcp.tool(annotations=_tool_annotations("select_tool"))
def select_tool(tool: str) -> str:
    """Switch to a specific editing tool.

    Args:
        tool: "select", "trim", "blade", "position", "hand", "zoom",
              "range", "crop", "distort", "transform"
    """
    r = bridge.call("tool.select", tool=tool)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Roles Management
# ============================================================
# Roles control how clips appear in the timeline index and
# how they're grouped during export (e.g. separate Dialogue/Music stems).

@mcp.tool(annotations=_tool_annotations("assign_role"))
def assign_role(type: str, role: str) -> str:
    """Assign a role to the selected clip.

    Args:
        type: "audio", "video", or "caption"
        role: Role name (e.g. "Dialogue", "Music", "Effects", "Titles", "Video")
    """
    r = bridge.call("roles.assign", type=type, role=role)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Mixer (Audio Faders)
# ============================================================
# Real-time audio mixer with per-clip volume faders.
# Returns clips overlapping the playhead with volume levels.

@mcp.tool(annotations=_tool_annotations("mixer_get_state"))
def mixer_get_state() -> str:
    """Get current mixer state: all clips overlapping the playhead with their volumes.

    Returns up to 12 faders, sorted by lane (highest/topmost clip = fader 0).
    Each fader includes clipHandle, volumeChannelHandle, effectStackHandle,
    volumeDB, volumeLinear, lane, role, and clip name.
    """
    r = bridge.call("mixer.getState")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    faders = r.get("faders", [])
    if not faders:
        return f"No clips at playhead (time: {r.get('playheadSeconds', 0):.3f}s)"
    lines = [f"Mixer State (playhead: {r.get('playheadSeconds', 0):.3f}s, {len(faders)} faders):"]
    lines.append("")
    for f in faders:
        db = f.get("volumeDB", 0)
        db_str = f"-inf" if db == float("-inf") else f"{db:.1f}"
        role_str = f" [{f['role']}]" if f.get("role") else ""
        flags = []
        if f.get("soloed"):
            flags.append("SOLO")
        if f.get("soloMuted"):
            flags.append("solo-muted")
        if f.get("muted"):
            flags.append("MUTE")
        elif f.get("muteMixed"):
            flags.append("mute-mixed")
        flag_str = f" ({', '.join(flags)})" if flags else ""
        lines.append(f"  Fader {f['index']}: {f.get('name', '?')} (lane {f['lane']})"
                     f"  {db_str} dB{role_str}{flag_str}")
        lines.append(f"    handles: clip={f.get('clipHandle','?')}"
                     f" vol={f.get('volumeChannelHandle','?')}"
                     f" es={f.get('effectStackHandle','?')}"
                     f" bus={f.get('busEffectStackHandle','?')}")
        if f.get("busKind") and f.get("busKind") != "none":
            lines.append(f"    bus: {f.get('busKind')} ({f.get('busObjectCount', 0)} object(s),"
                         f" {f.get('busEffectCount', 0)} effect(s))")
    if r.get("totalClipsAtPlayhead", 0) > 10:
        lines.append(f"\n  ({r['totalClipsAtPlayhead']} total clips, showing first 10)")
    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("mixer_set_volume"))
def mixer_set_volume(handle: str, volume_db: float = None,
                     volume_linear: float = None) -> str:
    """Set volume on a specific clip via its volumeChannelHandle.

    Use mixer_get_state() first to get handles. For proper undo support,
    call mixer_volume_begin() before a series of changes, then mixer_volume_end() after.

    Args:
        handle: The volumeChannelHandle from mixer_get_state()
        volume_db: Volume in dB (0 = unity, -6 = half, -inf = silent). Use this OR volume_linear.
        volume_linear: Volume as linear gain (1.0 = 0dB, 0.5 = -6dB, 0 = silent)
    """
    params = {"handle": handle}
    if volume_db is not None:
        params["volumeDB"] = volume_db
    elif volume_linear is not None:
        params["volumeLinear"] = volume_linear
    else:
        return "Error: provide either volume_db or volume_linear"
    r = bridge.call("mixer.setVolume", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    db = r.get("volumeDB", 0)
    db_str = f"-inf" if db == float("-inf") else f"{db:.1f}"
    return f"Volume set: {db_str} dB (linear: {r.get('volumeLinear', 0):.3f})"


@mcp.tool(annotations=_tool_annotations("mixer_set_solo"))
def mixer_set_solo(index: int = -1, role: str = "", mode: str = "toggle",
                   solo: bool = None) -> str:
    """Solo, unsolo, or clear solo for a mixer role fader.

    Args:
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role or clearing.
        role: Role name from mixer_get_state, used when index is not provided.
        mode: "toggle", "exclusive", "add", "remove", or "clear".
        solo: Optional explicit state. If omitted, toggle/exclusive behavior is used.
    """
    params = {"mode": mode}
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role
    if solo is not None:
        params["solo"] = solo

    r = bridge.call("mixer.setSolo", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    if mode == "clear":
        return "Mixer solo cleared"
    state = "soloed" if r.get("soloed") else "not soloed"
    target = r.get("role") or f"fader {r.get('index', index)}"
    return f"Mixer role {target}: {state} ({r.get('soloObjectCount', 0)} soloed objects)"


@mcp.tool(annotations=_tool_annotations("mixer_set_mute"))
def mixer_set_mute(index: int = -1, role: str = "", mode: str = "toggle",
                   muted: bool = None) -> str:
    """Mute, unmute, or clear mute for a mixer role fader.

    This uses Final Cut Pro's disabled audio-role playback map, so it does not
    change clip gain or insert mute effects.

    Args:
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role or clearing.
        role: Role name from mixer_get_state, used when index is not provided.
        mode: "toggle", "mute", "unmute", or "clear".
        muted: Optional explicit mute state. If omitted, toggle/mode behavior is used.
    """
    params = {"mode": mode}
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role
    if muted is not None:
        params["muted"] = muted

    r = bridge.call("mixer.setMute", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    if mode == "clear":
        return "Mixer role mutes cleared"
    state = "muted" if r.get("muted") else "unmuted"
    target = r.get("role") or f"fader {r.get('index', index)}"
    return f"Mixer role {target}: {state} ({r.get('roleUIDCount', 0)} role UIDs)"


@mcp.tool(annotations=_tool_annotations("mixer_apply_bus_effect"))
def mixer_apply_bus_effect(effect_id: str = "", name: str = "",
                           index: int = -1, role: str = "",
                           dry_run: bool = False,
                           allow_object_fallback: bool = False) -> str:
    """Apply an audio effect to a mixer role's collection-backed bus.

    The true bus path targets role-bearing compound/collection objects, so the
    effect is inserted on the parent audio stack that all contained audio flows through.

    Args:
        effect_id: Exact FCP audio effect ID. Use this or name.
        name: Audio effect display name, e.g. "Channel EQ". Used when effect_id is empty.
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role.
        role: Role name from mixer_get_state, used when index is not provided.
        dry_run: Preview the bus targets without applying the effect.
        allow_object_fallback: If true, target per-object audio stacks when no collection bus exists.
    """
    params = {"dryRun": dry_run, "allowObjectFallback": allow_object_fallback}
    if effect_id:
        params["effectID"] = effect_id
    if name:
        params["name"] = name
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role

    r = bridge.call("mixer.applyBusEffect", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    effect = r.get("effect", {})
    effect_name = effect.get("name") or effect.get("effectID") or name or effect_id
    target = r.get("role") or f"fader {r.get('index', index)}"
    count = r.get("busObjectCount", 0)
    if dry_run:
        return f"Mixer bus preview: {effect_name} -> {target} ({count} bus object{'s' if count != 1 else ''})"
    return f"Applied {effect_name} to mixer role {target} ({count} bus object{'s' if count != 1 else ''})"


@mcp.tool(annotations=_tool_annotations("mixer_open_bus_effect"))
def mixer_open_bus_effect(effect_index: int = -1, index: int = -1, role: str = "",
                          effect_handle: str = "", effect_stack_handle: str = "",
                          allow_object_fallback: bool = False) -> str:
    """Open the native FCP editor window for an effect on a mixer role bus.

    Args:
        effect_index: Zero-based effect index from mixer_get_state busEffects.
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role.
        role: Role name from mixer_get_state, used when index is not provided.
        effect_handle: Exact effect handle from mixer_get_state busEffects. Preferred when available.
        effect_stack_handle: Exact effect stack handle from mixer_get_state busEffects.
        allow_object_fallback: If true, target per-object audio stacks when no collection bus exists.
    """
    params = {"allowObjectFallback": allow_object_fallback}
    if effect_index >= 0:
        params["effectIndex"] = effect_index
    if effect_handle:
        params["effectHandle"] = effect_handle
    if effect_stack_handle:
        params["effectStackHandle"] = effect_stack_handle
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role

    r = bridge.call("mixer.openBusEffect", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    effect = r.get("effect", {})
    effect_name = effect.get("name") or effect.get("effectID") or f"effect {effect_index}"
    target = r.get("role") or f"fader {r.get('index', index)}"
    return f"Opened {effect_name} editor for mixer role {target}"


@mcp.tool(annotations=_tool_annotations("mixer_set_bus_effect_enabled"))
def mixer_set_bus_effect_enabled(effect_index: int = -1, enabled: bool = True,
                                 index: int = -1, role: str = "",
                                 effect_handle: str = "", effect_stack_handle: str = "",
                                 allow_object_fallback: bool = False) -> str:
    """Enable or disable an effect on a mixer role's collection-backed bus.

    Args:
        effect_index: Zero-based effect index from mixer_get_state busEffects.
        enabled: True to enable the effect, false to disable it.
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role.
        role: Role name from mixer_get_state, used when index is not provided.
        effect_handle: Exact effect handle from mixer_get_state busEffects. Preferred when available.
        effect_stack_handle: Exact effect stack handle from mixer_get_state busEffects.
        allow_object_fallback: If true, target per-object audio stacks when no collection bus exists.
    """
    params = {
        "enabled": enabled,
        "allowObjectFallback": allow_object_fallback,
    }
    if effect_index >= 0:
        params["effectIndex"] = effect_index
    if effect_handle:
        params["effectHandle"] = effect_handle
    if effect_stack_handle:
        params["effectStackHandle"] = effect_stack_handle
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role

    r = bridge.call("mixer.setBusEffectEnabled", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    target = r.get("role") or f"fader {r.get('index', index)}"
    state = "enabled" if r.get("enabled") else "disabled"
    return f"Mixer bus effect {effect_index} on {target}: {state}"


@mcp.tool(annotations=_tool_annotations("mixer_remove_bus_effect"))
def mixer_remove_bus_effect(effect_index: int = -1, index: int = -1, role: str = "",
                            effect_handle: str = "", effect_stack_handle: str = "",
                            allow_object_fallback: bool = False) -> str:
    """Remove an effect from a mixer role's collection-backed bus.

    Args:
        effect_index: Zero-based effect index from mixer_get_state busEffects.
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role.
        role: Role name from mixer_get_state, used when index is not provided.
        effect_handle: Exact effect handle from mixer_get_state busEffects. Preferred when available.
        effect_stack_handle: Exact effect stack handle from mixer_get_state busEffects.
        allow_object_fallback: If true, target per-object audio stacks when no collection bus exists.
    """
    params = {"allowObjectFallback": allow_object_fallback}
    if effect_index >= 0:
        params["effectIndex"] = effect_index
    if effect_handle:
        params["effectHandle"] = effect_handle
    if effect_stack_handle:
        params["effectStackHandle"] = effect_stack_handle
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role

    r = bridge.call("mixer.removeBusEffect", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    target = r.get("role") or f"fader {r.get('index', index)}"
    count = r.get("busObjectCount", 0)
    return f"Removed mixer bus effect {effect_index} from {target} ({count} bus object{'s' if count != 1 else ''})"


@mcp.tool(annotations=_tool_annotations("mixer_volume_begin"))
def mixer_volume_begin(effect_stack_handle: str) -> str:
    """Begin an undo-batched volume change (call before a series of mixer_set_volume).

    Opens an undo transaction so all volume changes until mixer_volume_end()
    are grouped as a single undo action.

    Args:
        effect_stack_handle: The effectStackHandle from mixer_get_state()
    """
    r = bridge.call("mixer.volumeBegin", effectStackHandle=effect_stack_handle)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Undo transaction opened for volume adjustment"


@mcp.tool(annotations=_tool_annotations("mixer_volume_end"))
def mixer_volume_end(effect_stack_handle: str) -> str:
    """End an undo-batched volume change (call after mixer_set_volume series).

    Closes the undo transaction. The entire series of changes becomes one undo action.

    Args:
        effect_stack_handle: The effectStackHandle used in mixer_volume_begin()
    """
    r = bridge.call("mixer.volumeEnd", effectStackHandle=effect_stack_handle)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Undo transaction closed"


@mcp.tool(annotations=_tool_annotations("mixer_set_all_volumes"))
def mixer_set_all_volumes(volumes: list) -> str:
    """Set volumes for multiple faders at once.

    Args:
        volumes: List of dicts with 'handle' (volumeChannelHandle) and
                 'volumeDB' or 'volumeLinear'. Example:
                 [{"handle": "obj_42", "volumeDB": -6.0},
                  {"handle": "obj_43", "volumeDB": -3.0}]
    """
    r = bridge.call("mixer.setAllVolumes", volumes=volumes)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    results = r.get("results", [])
    lines = [f"Set {len(results)} volumes:"]
    for res in results:
        if res.get("ok"):
            db = res.get("volumeDB", 0)
            db_str = f"-inf" if db == float("-inf") else f"{db:.1f}"
            lines.append(f"  {res.get('handle', '?')}: {db_str} dB")
        else:
            lines.append(f"  {res.get('handle', '?')}: ERROR - {res.get('error', '?')}")
    return "\n".join(lines)


# ============================================================
# Share/Export
# ============================================================
# Triggers FCP's share destinations (Export File, YouTube, etc).

@mcp.tool(annotations=_tool_annotations("share_project"))
def share_project(destination: str = "") -> str:
    """Share/export the project using a specific or default destination.

    Args:
        destination: Share destination name (e.g. "Export File", "Apple Devices 1080p",
                     "YouTube & Facebook"). Leave empty for default destination.
                     Use list_menus(menu="File") to see available Share destinations.
    """
    params = {}
    if destination:
        params["destination"] = destination
    r = bridge.call("share.export", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Project/Library/Event Management
# ============================================================
# Create new projects, events, and libraries via FCP's internal APIs.

@mcp.tool(annotations=_tool_annotations("create_project"))
def create_project() -> str:
    """Open the New Project dialog in FCP."""
    r = bridge.call("project.create")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("create_event"))
def create_event() -> str:
    """Create a new event in the current library."""
    r = bridge.call("project.createEvent")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("create_library"))
def create_library() -> str:
    """Open the New Library dialog."""
    r = bridge.call("project.createLibrary")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Open Project by Name
# ============================================================
# Find a sequence by name (and optionally event) and load it
# into the editor — no manual handle navigation required.

@mcp.tool(annotations=_tool_annotations("open_project"))
def open_project(name: str, event: str = "") -> str:
    """Open a project/sequence by name, loading it into the timeline editor.

    Searches all active libraries for a sequence matching the given name,
    and optionally filters by event name. Much faster than manually navigating
    the library -> sequences -> loadEditorForSequence: chain.

    Args:
        name: Project/sequence name to find (case-insensitive substring match).
              e.g. "My Project", "Edit v2", "Interview"
        event: Optional event name filter (case-insensitive substring match).
               e.g. "4-5-26", "Wedding", "Interview"

    Returns the matched project name, event, and library on success.
    If no match is found, returns a list of all available sequences.
    """
    params = {"name": name}
    if event:
        params["event"] = event
    r = bridge.call("project.open", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Dual Timeline
# ============================================================
# Floating secondary timeline window backed by a second
# PEEditorContainerModule. Commands route to the focused pane.

@mcp.tool(annotations=_tool_annotations("dual_timeline_status"))
def dual_timeline_status() -> str:
    """Inspect the primary/secondary timeline panes and current focused pane."""
    return _call_or_error("dualTimeline.status")


@mcp.tool(annotations=_tool_annotations("dual_timeline_open"))
def dual_timeline_open(source: str = "primary", focus: bool = False) -> str:
    """Open a floating secondary timeline window with a sequence loaded.

    Args:
        source: Which pane to copy the sequence from.
                "primary" (default), "focused", or "secondary"
        focus: When true, move keyboard focus to the secondary timeline after opening.
               When false, restore focus back to the primary timeline after loading.
    """
    params = {"source": source, "focus": focus}
    return _call_or_error("dualTimeline.open", **params)


@mcp.tool(annotations=_tool_annotations("dual_timeline_sync_root"))
def dual_timeline_sync_root(source: str = "primary", focus: bool = False) -> str:
    """Clone the source pane's current root into the secondary timeline.

    Useful for matching a primary pane that has drilled into a compound clip
    or multicam angle while keeping the two playheads independent afterward.
    """
    params = {"source": source, "focus": focus}
    return _call_or_error("dualTimeline.syncRoot", **params)


@mcp.tool(annotations=_tool_annotations("dual_timeline_open_selected_in_secondary"))
def dual_timeline_open_selected_in_secondary(source: str = "primary", focus: bool = True) -> str:
    """Open the selected compound clip / multicam item in the secondary timeline.

    The selection is taken from the source pane. This is the fastest way to keep
    the main timeline on one side while drilling into a nested item on the other.
    """
    params = {"source": source, "focus": focus}
    return _call_or_error("dualTimeline.openSelectedInSecondary", **params)


@mcp.tool(annotations=_tool_annotations("dual_timeline_focus"))
def dual_timeline_focus(pane: str) -> str:
    """Focus a specific timeline pane so subsequent commands target it.

    Args:
        pane: "primary" or "secondary"
    """
    return _call_or_error("dualTimeline.focus", pane=pane)


@mcp.tool(annotations=_tool_annotations("dual_timeline_close"))
def dual_timeline_close(focus_primary: bool = True) -> str:
    """Close the floating secondary timeline window.

    Args:
        focus_primary: When true, move focus back to the primary timeline after closing.
    """
    return _call_or_error("dualTimeline.close", focusPrimary=focus_primary)


@mcp.tool(annotations=_tool_annotations("dual_timeline_toggle_panel"))
def dual_timeline_toggle_panel(panel: str, pane: str = "secondary") -> str:
    """Toggle a container-local panel on a specific timeline pane.

    Supported panels:
        "browser", "timelineIndex", "audioMeters",
        "effectsBrowser", "transitionsBrowser"

    Args:
        panel: Panel identifier to toggle.
        pane: "primary" or "secondary". Defaults to "secondary".
    """
    return _call_or_error("dualTimeline.togglePanel", pane=pane, panel=panel)


# ============================================================
# Select Connected Clip at Playhead (Lane Selection)
# ============================================================
# The standard selectClipAtPlayhead only selects the primary
# storyline clip. This tool selects clips in any lane.

@mcp.tool(annotations=_tool_annotations("select_clip_in_lane"))
def select_clip_in_lane(lane: int = 1) -> str:
    """Select the clip at the playhead in a specific lane (connected storyline).

    The standard timeline_action("selectClipAtPlayhead") only selects clips in
    the primary storyline (lane 0). This tool can select connected clips in any
    lane — essential for inspecting or modifying connected titles, B-roll, etc.

    Args:
        lane: Lane number to select from.
              0 = primary storyline (same as selectClipAtPlayhead)
              1 = first connected lane above (captions, titles, B-roll)
              -1 = first connected lane below
              2, 3, etc. = higher connected lanes

    Returns the selected clip's name, class, and handle for further inspection.
    """
    r = bridge.call("timeline.selectClipInLane", lane=lane)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Capture Viewer Screenshot
# ============================================================
# Captures the viewer/canvas contents directly — no external
# screencapture tool needed, no other windows in the way.

@mcp.tool(annotations=_tool_annotations("capture_viewer"))
def capture_viewer(path: str = "/tmp/splicekit_viewer.png") -> str:
    """Capture the FCP viewer/canvas as a PNG screenshot.

    Screenshots the viewer area only (cropped from the FCP window, not the
    whole screen). Captures GPU/Metal content directly — FCP does not need
    to be in the foreground.

    Use after: applying effects, color correction, titles, captions, or
    any change visible in the canvas. Read the resulting PNG to visually
    verify text rendering, font/size, position, color, and compositing.

    Args:
        path: Output file path for the PNG image.
              Default: /tmp/splicekit_viewer.png

    Returns the file path, image dimensions, and file size.
    The saved PNG can be read by Claude to visually verify viewer output.
    """
    r = bridge.call("viewer.capture", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    if r.get("status") == "ok":
        return (f"Viewer captured: {r.get('path')}\n"
                f"Size: {r.get('width')}x{r.get('height')} ({r.get('bytes', 0)} bytes)")
    return _fmt(r)


# ============================================================
# Capture Timeline Screenshot
# ============================================================

@mcp.tool(annotations=_tool_annotations("capture_timeline"))
def capture_timeline(path: str = "/tmp/splicekit_timeline.png") -> str:
    """Capture the FCP timeline as a PNG screenshot.

    Screenshots the timeline area only (cropped from the FCP window, not the
    whole screen). Captures GPU/Metal content directly — FCP does not need
    to be in the foreground.

    Use after: blade cuts, clip rearrangement, adding/removing markers,
    transitions, trim edits, or any structural timeline change. Read the
    resulting PNG to visually verify clip layout, edit points, gaps,
    markers, transitions, and overall timeline structure.

    Args:
        path: Output file path for the PNG image.
              Default: /tmp/splicekit_timeline.png

    Returns the file path, image dimensions, and file size.
    The saved PNG can be read by Claude to visually verify timeline state.
    """
    r = bridge.call("timeline.capture", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    if r.get("status") == "ok":
        return (f"Timeline captured: {r.get('path')}\n"
                f"Size: {r.get('width')}x{r.get('height')} ({r.get('bytes', 0)} bytes)")
    return _fmt(r)


# ============================================================
# Capture Inspector Screenshot
# ============================================================

@mcp.tool(annotations=_tool_annotations("capture_inspector"))
def capture_inspector(path: str = "/tmp/splicekit_inspector.png", class_name: str = "") -> str:
    """Capture the FCP Inspector pane as a PNG screenshot.

    Crops the Inspector area from the FCP window. Searches the view hierarchy
    for one of FCP's known inspector root view classes (FFInspectorRootStackView,
    FFInspectorRootOutlineView, FFInspectorOutlineView, etc.) and captures the
    largest matching view.

    Use after applying or modifying an effect on the selected clip to visually
    verify what parameters appear, their values, and custom UI views (e.g.
    FxPlug 4 custom parameter views).

    Args:
        path: Output file path for the PNG image.
              Default: /tmp/splicekit_inspector.png
        class_name: Optional override — search for a specific NSView subclass
              instead of the default candidate list.

    Returns the file path, image dimensions, file size, and the matched class.
    The saved PNG can be read by Claude to visually verify Inspector contents.
    """
    kwargs = {"path": path}
    if class_name:
        kwargs["class_name"] = class_name
    r = bridge.call("inspector.capture", **kwargs)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    if r.get("status") == "ok":
        matched = r.get("matchedClass", "(full window fallback)")
        return (f"Inspector captured: {r.get('path')}\n"
                f"Matched class: {matched}\n"
                f"Size: {r.get('width')}x{r.get('height')} ({r.get('bytes', 0)} bytes)")
    return _fmt(r)


# ============================================================
# Export FCPXML (Programmatic, No Dialog)
# ============================================================
# Export the current project to FCPXML without the save dialog.

@mcp.tool(annotations=_tool_annotations("export_xml"))
def export_xml(path: str = "/tmp/splicekit_export.fcpxml") -> str:
    """Export the current project/sequence as FCPXML to a file — no save dialog.

    Programmatically serializes the active timeline's sequence to FCPXML format
    and writes it to the specified path. Unlike timeline_action("exportXML")
    which opens FCP's save dialog, this writes directly.

    Args:
        path: Output file path for the FCPXML.
              Default: /tmp/splicekit_export.fcpxml

    The exported FCPXML contains the full project structure including clips,
    effects, titles, markers, and timing. Useful for:
    - Inspecting the project structure (e.g. finding Custom Speed keyframes)
    - Backing up before destructive edits
    - Transferring projects between systems
    """
    r = bridge.call("fcpxml.export", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# OpenTimelineIO Import & Export
# ============================================================
# Universal timeline interchange via OpenTimelineIO. Handles all
# OTIO-supported formats (.otio, .otioz, .otiod) AND .fcpxml via
# the otio-fcpx-xml-adapter. Replaces import_fcpxml / export_xml
# as the primary format tools.

def _otio_prepare_for_fcp(timeline):
    """Prepare an OTIO timeline for FCP import.

    - Converts non-title GeneratorReference clips to gaps
    - Preserves title generators (the adapter writes them as <title> elements)
    - Returns the modified timeline (in-place)
    """
    import opentimelineio as otio
    if not isinstance(timeline, otio.schema.Timeline):
        return timeline
    for track in timeline.tracks:
        for i, item in enumerate(list(track)):
            if (isinstance(item, otio.schema.Clip) and
                    isinstance(item.media_reference, otio.schema.GeneratorReference)):
                if not _otio_is_title_generator_reference(item.media_reference):
                    track[i] = otio.schema.Gap(source_range=item.source_range)
    return timeline


def _otio_is_title_generator_reference(media_reference):
    """Detect title-like GeneratorReference metadata across adapter variants."""
    title_generator_kinds = {"Title", "title", "fcpx.title"}
    gen_kind = getattr(media_reference, "generator_kind", "")
    if gen_kind in title_generator_kinds:
        return True

    parameters = getattr(media_reference, "parameters", {}) or {}
    if not isinstance(parameters, dict):
        return False
    return bool(parameters.get("text_xml") or parameters.get("text_style_def_xml"))


def _otio_fcpx_adapter_candidates():
    """Return compatible FCPXML adapter names in preference order."""
    import opentimelineio as otio

    preferred = ("fcpxml", "fcpx_xml")
    try:
        available = set(otio.adapters.available_adapter_names())
    except Exception:
        available = set()

    ordered = [name for name in preferred if name in available]
    if ordered:
        return ordered
    return list(preferred)


def _otio_with_fcpx_adapter(operation):
    """Run an OTIO adapter operation against the supported FCPXML adapter names."""
    errors = []
    for adapter_name in _otio_fcpx_adapter_candidates():
        try:
            return operation(adapter_name)
        except Exception as exc:
            errors.append(f"{adapter_name}: {exc}")
    raise RuntimeError("No working FCPXML adapter found (" + "; ".join(errors) + ")")


def _otio_read_fcpx_string(fcpxml_str):
    """Read FCPXML using whichever adapter name is installed."""
    import opentimelineio as otio

    return _otio_with_fcpx_adapter(
        lambda adapter_name: otio.adapters.read_from_string(fcpxml_str, adapter_name)
    )


def _otio_write_fcpx_string(timeline, fcpxml_version=None):
    """Write FCPXML using whichever adapter name is installed.

    The modern PR #7 adapter accepts ``fcpxml_version`` for version-aware
    FCPXML 1.0-1.14 output. Older adapters reject that kwarg, so retry without
    it before moving to the next adapter name.
    """
    import opentimelineio as otio

    def write(adapter_name):
        if fcpxml_version:
            try:
                return otio.adapters.write_to_string(
                    timeline,
                    adapter_name,
                    fcpxml_version=fcpxml_version,
                )
            except TypeError as exc:
                if "fcpxml_version" not in str(exc):
                    raise
        return otio.adapters.write_to_string(timeline, adapter_name)

    return _otio_with_fcpx_adapter(write)


def _otio_fcpxmld_info_path(package_path):
    """Return the FCPXML document entrypoint for a `.fcpxmld` package."""
    from pathlib import Path

    package = Path(package_path)
    if not package.exists():
        raise FileNotFoundError(f"FCPXML package does not exist: '{package}'.")
    if not package.is_dir():
        raise NotADirectoryError(f"FCPXML package path is not a directory: '{package}'.")

    info_path = package / "Info.fcpxml"
    if not info_path.is_file():
        raise FileNotFoundError(f"FCPXML package is missing 'Info.fcpxml': '{package}'.")
    return info_path


def _otio_read_fcpx_document(path):
    """Read a `.fcpxml` document or `.fcpxmld` package entrypoint."""
    from pathlib import Path

    document_path = Path(path)
    if document_path.is_dir() or document_path.suffix.lower() == ".fcpxmld":
        document_path = _otio_fcpxmld_info_path(document_path)

    return document_path.read_text(encoding="utf-8")


def _otio_fcpxml_clean_for_paste(fcpxml_str):
    """Clean FCPXML for FCP's pasteboard import.

    - Strips <library> wrapper (pasteboard merges into active library)
    - Strips standalone <asset-clip> elements at event level (browser clutter)
    """
    lines = fcpxml_str.split("\n")
    clean = []
    for line in lines:
        s = line.strip()
        if s in ("<library>", "</library>"):
            continue
        if s.startswith("<asset-clip ") and s.endswith("/>"):
            if (len(line) - len(line.lstrip())) <= 16:
                continue
        clean.append(line)
    return "\n".join(clean)


def _otio_first_timeline(result):
    """Extract the first Timeline from an OTIO read result."""
    timelines = _otio_all_timelines(result, collection_fallback=False)
    if timelines:
        return timelines[0]
    return result

def _otio_all_timelines(result, collection_fallback=True):
    """Extract all Timelines from an OTIO read result."""
    import opentimelineio as otio
    if isinstance(result, otio.schema.Timeline):
        return [result]
    if isinstance(result, otio.schema.SerializableCollection):
        timelines = []
        if hasattr(result, "find_children"):
            timelines = list(result.find_children(descended_from_type=otio.schema.Timeline))
        if not timelines:
            timelines = [
                child
                for item in result
                for child in _otio_all_timelines(item, collection_fallback=False)
            ]
        if timelines:
            return timelines
        return list(result) if collection_fallback else []
    return [result] if collection_fallback else []

def _otio_timeline_summary(timeline):
    """Build a summary dict for an OTIO timeline."""
    import opentimelineio as otio
    info = {"name": getattr(timeline, "name", "unknown")}
    if isinstance(timeline, otio.schema.Timeline):
        info["tracks"] = len(timeline.tracks)
        info["clips"] = len(list(timeline.find_clips()))
        total_dur = timeline.duration()
        if total_dur and total_dur.value > 0 and total_dur.rate > 0:
            info["duration_seconds"] = round(total_dur.value / total_dur.rate, 3)
    return info


def _otio_detect_rate(timeline):
    """Auto-detect frame rate from an OTIO timeline. Returns 24 as default."""
    import opentimelineio as otio
    raw_rate = 24
    if isinstance(timeline, otio.schema.Timeline):
        for clip in timeline.find_clips():
            if clip.source_range and clip.source_range.duration.rate > 1:
                raw_rate = clip.source_range.duration.rate
                break
        else:
            dur = timeline.duration()
            if dur and dur.rate > 1:
                raw_rate = dur.rate
    return _otio_normalize_rate(raw_rate)


def _otio_normalize_rate(rate):
    """Map common approximate frame rates to exact SMPTE values.

    The FCPXML adapter returns integer rates (29 for 29.97fps) and user input
    may use approximate values (29.97). The EDL adapter needs exact fractional
    rates (30000/1001) for drop-frame timecode support.
    """
    rate_map = {
        23: 24000 / 1001,    # 23.976
        23.98: 24000 / 1001,
        23.976: 24000 / 1001,
        24: 24,
        25: 25,
        29: 30000 / 1001,    # 29.97 (FCPXML adapter returns 29)
        29.97: 30000 / 1001,
        30: 30,
        47: 48000 / 1001,
        47.95: 48000 / 1001,
        48: 48,
        50: 50,
        59: 60000 / 1001,    # 59.94
        59.94: 60000 / 1001,
        60: 60,
    }
    # Check exact match first, then closest integer
    if rate in rate_map:
        return rate_map[rate]
    rounded = round(rate)
    if rounded in rate_map:
        return rate_map[rounded]
    return rate


@mcp.tool(annotations=_tool_annotations("export_otio"))
def export_otio(path: str = "/tmp/splicekit_export.otio", rate: float = 0) -> str:
    """Export the current project/sequence via OpenTimelineIO.

    Universal export that handles all OTIO-supported formats including FCPXML.
    Enables timeline interchange with DaVinci Resolve, Premiere Pro, Avid Media
    Composer, and any NLE that supports OTIO or FCPXML.

    Supported output formats (determined by file extension):
      .otio   — OpenTimelineIO native JSON (default, most compatible for NLE exchange)
      .otioz  — OpenTimelineIO bundled with media references (zipped)
      .otiod  — OpenTimelineIO directory bundle
      .fcpxml — Final Cut Pro XML (uses FCP's native exporter for full fidelity,
                then round-trips through OTIO for normalization)
      .fcpxmld — Final Cut Pro XML package (writes native export to `Info.fcpxml`)
      .edl    — CMX 3600 EDL (Premiere, Resolve, Avid compatible)
      .aaf    — Advanced Authoring Format (Avid Media Composer)

    Args:
        path: Output file path. Extension determines format.
              Default: /tmp/splicekit_export.otio
        rate: Frame rate for EDL export (e.g. 23.98, 24, 29.97, 30).
              Required for .edl, ignored for other formats. If 0, auto-detected
              from timeline.

    Returns:
        JSON with status, output path, timeline name, track/clip counts, and duration.
    """
    try:
        import opentimelineio as otio
    except ImportError:
        return "Error: opentimelineio not installed. Run: pip install opentimelineio otio-fcpxml-adapter (or legacy otio-fcpx-xml-adapter)"

    import tempfile, os

    # For .fcpxml/.fcpxmld output, use FCP's native exporter directly for maximum fidelity.
    if path.lower().endswith((".fcpxml", ".fcpxmld")):
        export_path = path
        if path.lower().endswith(".fcpxmld"):
            os.makedirs(path, exist_ok=True)
            export_path = os.path.join(path, "Info.fcpxml")

        r = bridge.call("fcpxml.export", path=export_path)
        if _err(r):
            return f"Error exporting FCPXML: {r.get('error', r)}"
        # Also parse through OTIO for summary info
        try:
            with open(export_path, "r") as f:
                fcpxml_str = f.read()
            result = _otio_read_fcpx_string(fcpxml_str)
            timeline = _otio_first_timeline(result)
            summary = _otio_timeline_summary(timeline)
        except Exception:
            summary = {}
        summary.update({
            "status": "ok",
            "path": path,
            "bytes": os.path.getsize(export_path),
            "format": "fcpxmld" if path.lower().endswith(".fcpxmld") else "fcpxml",
        })
        return _fmt(summary)

    # For OTIO formats: export FCPXML from FCP, convert via adapter, write target format
    fcpxml_path = os.path.join(tempfile.gettempdir(), "splicekit_otio_export.fcpxml")
    r = bridge.call("fcpxml.export", path=fcpxml_path)
    if _err(r):
        return f"Error exporting FCPXML: {r.get('error', r)}"

    try:
        with open(fcpxml_path, "r") as f:
            fcpxml_str = f.read()
        result = _otio_read_fcpx_string(fcpxml_str)
    except Exception as e:
        return f"Error reading FCPXML into OTIO: {e}"

    timeline = _otio_first_timeline(result)

    # Format-specific write options
    ext = path.rsplit(".", 1)[-1].lower()
    try:
        if ext == "edl":
            # EDL needs a rate; auto-detect from timeline or use provided rate
            edl_rate = _otio_normalize_rate(rate) if rate > 0 else _otio_detect_rate(timeline)
            otio.adapters.write_to_file(timeline, path, rate=edl_rate)
        else:
            otio.adapters.write_to_file(timeline, path)
    except Exception as e:
        hint = ""
        if ext == "aaf" and "mob" in str(e).lower():
            hint = " (AAF requires Avid-specific metadata on clips — try .edl or .otio instead)"
        elif ext == "otioz" and ("NotAFileOnDisk" in type(e).__name__ or "not" in str(e).lower()):
            hint = " (.otioz bundles media files — referenced files must exist on disk)"
        return f"Error writing {ext.upper()} file: {e}{hint}"

    summary = _otio_timeline_summary(timeline)
    summary.update({"status": "ok", "path": path, "bytes": os.path.getsize(path), "format": ext})

    try:
        os.unlink(fcpxml_path)
    except OSError:
        pass

    return _fmt(summary)


@mcp.tool(annotations=_tool_annotations("import_otio"))
def import_otio(path: str = "", otio_json: str = "", rate: float = 0) -> str:
    """Import a timeline file into FCP via OpenTimelineIO.

    Universal import that handles all OTIO-supported formats including FCPXML.
    Enables importing timelines from DaVinci Resolve, Premiere Pro, Avid Media
    Composer, and any NLE that exports OTIO or FCPXML.

    Supported input formats (determined by file extension):
      .otio   — OpenTimelineIO native JSON (DaVinci Resolve, universal)
      .otioz  — OpenTimelineIO bundle (zipped)
      .otiod  — OpenTimelineIO directory bundle
      .fcpxml — Final Cut Pro XML (sent directly to FCP's native importer
                for full fidelity — effects, transitions, titles all preserved)
      .fcpxmld — Final Cut Pro XML package (loads `Info.fcpxml` for native import)
      .edl    — CMX 3600 EDL (Premiere, Resolve, Avid)
      .aaf    — Advanced Authoring Format (Avid Media Composer)

    Args:
        path:      Path to the file to import. Extension determines format.
        otio_json: Alternatively, pass raw OTIO JSON string directly (uses .otio adapter).
                   If both path and otio_json are provided, path takes priority.
        rate:      Frame rate for EDL import (e.g. 23.98, 24, 29.97, 30).
                   Required for .edl files with drop-frame timecodes. If 0, defaults to 24.

    Returns:
        JSON with import status, timeline name, track/clip counts.
    """
    try:
        import opentimelineio as otio
    except ImportError:
        return "Error: opentimelineio not installed. Run: pip install opentimelineio otio-fcpxml-adapter (or legacy otio-fcpx-xml-adapter)"

    # For .fcpxml/.fcpxmld input, send directly to FCP's native importer for full fidelity.
    if path and path.lower().endswith((".fcpxml", ".fcpxmld")):
        try:
            fcpxml_str = _otio_read_fcpx_document(path)
        except Exception as e:
            return f"Error reading file: {e}"

        r = bridge.call("fcpxml.import", xml=fcpxml_str, internal=True)

        # Also parse through OTIO for summary info
        summary = {"format": path.rsplit(".", 1)[-1].lower()}
        try:
            result = _otio_read_fcpx_string(fcpxml_str)
            timelines = _otio_all_timelines(result)
            summary["timelines_total"] = len(timelines)
            summary["details"] = [_otio_timeline_summary(tl) for tl in timelines]
        except Exception:
            pass

        if _err(r):
            summary["status"] = "error"
            summary["error"] = r.get("error", str(r))
        else:
            summary["status"] = "ok"
        return _fmt(summary)

    # For .otio files: prefer the native ObjC converter (correct transitions,
    # titles, connected clips, exact frame-rate math) over the Python adapter.
    ext = path.rsplit(".", 1)[-1].lower() if path else ""
    if ext == "otio" or (not path and otio_json):
        native_ok = False
        try:
            if path and ext == "otio":
                r = bridge.call("otio.toFCPXML", path=path)
            elif otio_json:
                r = bridge.call("otio.toFCPXML", path="/dev/null", otio_json=otio_json)
            else:
                r = {"error": "no input"}

            if not _err(r) and r.get("fcpxml"):
                fcpxml_str = r["fcpxml"]
                fcpxml_str = _otio_fcpxml_clean_for_paste(fcpxml_str)
                ir = bridge.call("fcpxml.import", xml=fcpxml_str, internal=True)
                # Parse through OTIO for summary
                summary = {"format": ext or "otio_json", "converter": "native"}
                try:
                    parsed = _otio_read_fcpx_string(fcpxml_str)
                    timelines = _otio_all_timelines(parsed)
                    summary["timelines_total"] = len(timelines)
                    summary["details"] = [_otio_timeline_summary(tl) for tl in timelines]
                except Exception:
                    pass
                if _err(ir):
                    summary["status"] = "error"
                    summary["error"] = ir.get("error", str(ir))
                else:
                    summary["status"] = "ok"
                return _fmt(summary)
        except Exception:
            pass  # Fall through to Python adapter path

    # Fallback: read via Python OTIO adapter, convert to FCPXML, import into FCP
    try:
        if path:
            if ext == "edl":
                edl_rate = _otio_normalize_rate(rate) if rate > 0 else 24
                result = otio.adapters.read_from_file(path, rate=edl_rate)
            else:
                result = otio.adapters.read_from_file(path)
        elif otio_json:
            result = otio.adapters.read_from_string(otio_json, "otio_json")
        else:
            return "Error: provide either 'path' (file path) or 'otio_json' (raw OTIO JSON string)"
    except Exception as e:
        hint = ""
        if path and path.lower().endswith(".edl") and "drop frame" in str(e).lower():
            hint = " (try setting rate=29.97 for drop-frame EDLs)"
        return f"Error reading file: {e}{hint}"

    timelines = _otio_all_timelines(result)
    if not timelines:
        return "Error: no timelines found in OTIO file"

    imported = []
    for tl in timelines:
        _otio_prepare_for_fcp(tl)
        try:
            fcpxml_str = _otio_write_fcpx_string(tl)
            fcpxml_str = _otio_fcpxml_clean_for_paste(fcpxml_str)
        except Exception as e:
            err_msg = f"FCPXML conversion failed: {e}"
            if "kind" in str(e):
                err_msg += " (nested compound clips may not convert — try flattening first)"
            elif "start_time" in str(e) or "NoneType" in str(e):
                err_msg += " (clip has missing source range — may need media references)"
            imported.append({"name": getattr(tl, "name", "unknown"), "error": err_msg})
            continue

        r = bridge.call("fcpxml.import", xml=fcpxml_str, internal=True)
        entry = _otio_timeline_summary(tl)
        entry["converter"] = "python_adapter"
        if _err(r):
            entry["error"] = r.get("error", str(r))
        else:
            entry["status"] = "ok"
        imported.append(entry)

    summary = {
        "status": "ok" if any(i.get("status") == "ok" for i in imported) else "error",
        "format": path.rsplit(".", 1)[-1] if path else "otio_json",
        "timelines_imported": len([i for i in imported if i.get("status") == "ok"]),
        "timelines_total": len(imported),
        "details": imported,
    }
    return _fmt(summary)


# ============================================================
# Deploy & Restart FCP
# ============================================================
# One-shot command to build, deploy, re-sign, kill FCP, relaunch,
# and wait for the bridge to come back online.

@mcp.tool(annotations=_tool_annotations("deploy_and_restart"))
def deploy_and_restart(skip_build: bool = False) -> str:
    """Build SpliceKit, deploy to the modded FCP app, and restart FCP.

    This automates the entire deploy cycle:
    1. Run `make deploy` (builds dylib + copies to framework path + re-signs)
    2. Kill any running FCP process
    3. Relaunch the modded FCP
    4. Wait for the SpliceKit bridge to come online (up to 30 seconds)

    Args:
        skip_build: If True, skip `make deploy` and just restart FCP.
                    Useful when you've already built and just need to relaunch.

    Returns success/failure status and bridge connection state.
    """
    import subprocess, os, time as _time

    project_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    results = []

    # Step 1: Build and deploy
    if not skip_build:
        try:
            proc = subprocess.run(
                ["make", "deploy"],
                cwd=project_dir, capture_output=True, text=True, timeout=120
            )
            if proc.returncode != 0:
                return f"Build failed (exit {proc.returncode}):\n{proc.stderr}\n{proc.stdout}"
            results.append("Build + deploy: OK")
        except subprocess.TimeoutExpired:
            return "Error: build timed out after 120s"
        except Exception as e:
            return f"Error running make deploy: {e}"

    # Step 2: Kill FCP
    try:
        subprocess.run(["pkill", "-x", "Final Cut Pro"], capture_output=True, timeout=5)
        results.append("Killed FCP")
        _time.sleep(2)  # wait for process to fully exit
    except Exception:
        results.append("FCP was not running")

    # Step 3: Relaunch
    # Find the modded app
    modded_standard = os.path.expanduser("~/Applications/SpliceKit/Final Cut Pro.app")
    modded_creator = os.path.expanduser("~/Applications/SpliceKit/Final Cut Pro Creator Studio.app")
    modded_app = modded_standard if os.path.isdir(modded_standard) else modded_creator

    if not os.path.isdir(modded_app):
        return f"Error: modded FCP not found at {modded_standard} or {modded_creator}"

    try:
        subprocess.Popen(["open", modded_app])
        results.append(f"Launched: {os.path.basename(modded_app)}")
    except Exception as e:
        return f"Error launching FCP: {e}"

    # Step 4: Wait for bridge
    # Drop the existing connection so we don't use a stale socket
    bridge.sock = None
    bridge._buf = b""

    max_wait = 30
    start = _time.time()
    connected = False
    while _time.time() - start < max_wait:
        _time.sleep(2)
        try:
            r = bridge.call("system.version")
            if not _err(r):
                connected = True
                break
        except Exception:
            pass
        bridge.sock = None  # reset on failure
        bridge._buf = b""

    if connected:
        results.append(f"Bridge connected ({_time.time() - start:.1f}s)")
        return "\n".join(results)
    else:
        results.append(f"Bridge NOT connected after {max_wait}s — FCP may still be loading")
        return "\n".join(results)


# ============================================================
# Playhead Position & Monitoring
# ============================================================
# Query current playhead position, frame rate, and play state.

@mcp.tool(annotations=_tool_annotations("get_playhead_position"))
def get_playhead_position() -> str:
    """Get the current playhead position, timeline duration, frame rate, and playing state.

    Returns:
        seconds: Current playhead position in seconds
        duration: Total timeline duration
        frameRate: Timeline frame rate (e.g. 23.976, 29.97, 59.94)
        isPlaying: Whether playback is currently active

    Use this to monitor playhead position during playback or to know
    exact position before performing edits.
    """
    r = bridge.call("playback.getPosition")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Dialog Detection & Interaction
# ============================================================
# FCP pops up modal dialogs for various operations (project settings,
# export, missing media, etc). These tools detect and interact with
# them so the AI can handle dialogs without human intervention.

@mcp.tool(annotations=_tool_annotations("detect_dialog"))
def detect_dialog() -> str:
    """Detect if any dialog, sheet, alert, or popup is currently showing in FCP.

    Returns details about all visible dialogs including:
    - Dialog type (modal, sheet, alert, panel, progress, share)
    - Title and all text labels
    - Available buttons with enabled/disabled status
    - Text fields (editable) with current values
    - Checkboxes with checked/unchecked state
    - Popup menus with available options and current selection

    Call this before/after any action that might trigger a dialog,
    or to check if a dialog needs to be handled before proceeding.
    """
    r = bridge.call("dialog.detect")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("click_dialog_button"))
def click_dialog_button(button: str = "", index: int = -1) -> str:
    """Click a button in the currently showing dialog/sheet/alert.

    Args:
        button: Button title to click (case-insensitive, partial match).
                e.g. "OK", "Cancel", "Share", "Don't Save", "Use Freeze Frames"
        index: Button index (0-based) if title is ambiguous. Use -1 to use title.

    Finds the active dialog (modal window, sheet, or alert panel) and clicks
    the specified button. Use detect_dialog() first to see available buttons.
    """
    params = {}
    if button:
        params["button"] = button
    if index >= 0:
        params["index"] = index
    r = bridge.call("dialog.click", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("fill_dialog_field"))
def fill_dialog_field(value: str, index: int = 0) -> str:
    """Fill a text field in the currently showing dialog.

    Args:
        value: Text to enter in the field
        index: Field index (0-based) if there are multiple fields

    Use detect_dialog() first to see available text fields and their indices.
    """
    r = bridge.call("dialog.fill", value=value, index=index)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("toggle_dialog_checkbox"))
def toggle_dialog_checkbox(checkbox: str, checked: bool = None) -> str:
    """Toggle or set a checkbox in the currently showing dialog.

    Args:
        checkbox: Checkbox title (partial match, case-insensitive)
        checked: True to check, False to uncheck, None to toggle

    Use detect_dialog() first to see available checkboxes.
    """
    params = {"checkbox": checkbox}
    if checked is not None:
        params["checked"] = checked
    r = bridge.call("dialog.checkbox", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("select_dialog_popup"))
def select_dialog_popup(select: str, popup_index: int = 0) -> str:
    """Select an item from a popup menu in the currently showing dialog.

    Args:
        select: Item title to select
        popup_index: Which popup menu (0-based) if there are multiple

    Use detect_dialog() first to see available popup menus and their options.
    """
    r = bridge.call("dialog.popup", select=select, popupIndex=popup_index)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("dismiss_dialog"))
def dismiss_dialog(action: str = "default") -> str:
    """Dismiss the currently showing dialog.

    Args:
        action: How to dismiss:
                "default" - click the default button (usually OK/Share/Done)
                "cancel" - click Cancel or press Escape
                "ok" - explicitly look for OK/Done/Share button

    Automatically finds and clicks the appropriate button to dismiss
    the dialog, sheet, or alert.
    """
    r = bridge.call("dialog.dismiss", action=action)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Viewer Zoom
# ============================================================
# Get/set the canvas zoom level. 0.0 = fit-to-window.

@mcp.tool(annotations=_tool_annotations("get_viewer_zoom"))
def get_viewer_zoom() -> str:
    """Get the current viewer zoom level.

    Returns the zoom factor (0.0 = Fit, 1.0 = 100%, 2.0 = 200%, etc.),
    the reported zoom percentage, and whether the viewer is in Fit mode.
    """
    r = bridge.call("viewer.getZoom")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("set_viewer_zoom"))
def set_viewer_zoom(zoom: float) -> str:
    """Set the viewer zoom level to any value.

    Args:
        zoom: Zoom factor. 0.0 = Fit to window, 0.5 = 50%, 1.0 = 100%,
              1.5 = 150%, 2.0 = 200%, etc. Any float value is accepted
              (not limited to FCP's preset percentages).
    """
    r = bridge.call("viewer.setZoom", zoom=zoom)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# SpliceKit Options
# ============================================================
# Runtime configuration for SpliceKit's own behavioral tweaks.

@mcp.tool(annotations=_tool_annotations("get_bridge_options"))
def get_bridge_options() -> str:
    """Get the current SpliceKit option settings.

    Returns the state of all configurable options
    (e.g. effectDragAsAdjustmentClip, viewerPinchZoom, videoOnlyKeepsAudioDisabled,
    suppressAutoImport, defaultSpatialConformType).
    """
    r = bridge.call("options.get")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("set_bridge_option"))
def set_bridge_option(option: str, enabled: bool) -> str:
    """Toggle a boolean SpliceKit option.

    Args:
        option: Option name. Currently supported:
                "effectDragAsAdjustmentClip" - enable/disable dragging effects to empty timeline space to create adjustment clips
                "viewerPinchZoom" - enable/disable trackpad pinch-to-zoom on the viewer
                "videoOnlyKeepsAudioDisabled" - when Video-Only AV edit mode adds clips, keep audio+video but with audio disabled in inspector
                "suppressAutoImport" - stop FCP from auto-opening the Import Media window when a card, camera, or iOS device mounts
                For "defaultSpatialConformType", use set_bridge_option_value() instead.
        enabled: True to enable, False to disable
    """
    r = bridge.call("options.set", option=option, enabled=enabled)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("set_bridge_option_value"))
def set_bridge_option_value(option: str, value: str) -> str:
    """Set a string-valued SpliceKit option.

    Args:
        option: Option name. Currently supported:
                "defaultSpatialConformType" - override the default spatial conform type for newly added clips
        value: The value to set. For "defaultSpatialConformType":
               "fit"  - Fit (letterbox/pillarbox, FCP default)
               "fill" - Fill (scale to fill frame, crops edges)
               "none" - None (native resolution, no scaling)
    """
    r = bridge.call("options.set", option=option, value=value)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Beat Detection (Any Audio File)
# ============================================================
# Runs an external Swift tool (not in-process, because AVFoundation
# deadlocks inside FCP's hardened runtime). Returns beat/bar/section
# timestamps for syncing video cuts to music.

@mcp.tool(annotations=_tool_annotations("detect_beats"))
def detect_beats(file_path: str, sensitivity: float = 0.5, min_bpm: float = 60.0, max_bpm: float = 200.0) -> str:
    """Detect beats, bars, and sections in any audio file (MP3, WAV, M4A, etc.).

    Analyzes the audio using onset detection and tempo estimation.
    Returns precise timestamps for every beat, bar (4 beats), and section (16 beats),
    plus the detected BPM. These timestamps can be fed directly into montage_plan_edit()
    to cut video clips to the rhythm of any song.

    Args:
        file_path: Path to audio file (MP3, WAV, M4A, AAC, AIFF, etc.)
        sensitivity: Beat detection sensitivity 0.0-1.0 (default 0.5).
                     Higher = more beats detected, lower = only strong beats.
        min_bpm: Minimum expected BPM (default 60).
        max_bpm: Maximum expected BPM (default 200).

    Returns beat timestamps, bar timestamps, section timestamps, BPM, and duration.
    """
    import subprocess, os
    # Search common install locations for the beat-detector binary
    tool_paths = [
        os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build", "beat-detector"),
        os.path.expanduser("~/Applications/SpliceKit/tools/beat-detector"),
        os.path.expanduser("~/Library/Application Support/SpliceKit/tools/beat-detector"),
        "/usr/local/bin/beat-detector",
    ]
    tool = None
    for p in tool_paths:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            tool = p
            break
    if not tool:
        return "Error: beat-detector tool not found. Re-run the SpliceKit patcher to install tools, or build from source with: swiftc -O -o build/beat-detector tools/beat-detector.swift"

    try:
        result = subprocess.run(
            [tool, file_path, str(sensitivity), str(min_bpm), str(max_bpm)],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            return f"Error: beat-detector failed: {result.stderr}"
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        return "Error: beat-detector timed out"
    except Exception as e:
        return f"Error: {e}"


# ============================================================
# Song Structure Analysis
# ============================================================
# Extends beat detection with song structure labeling (verse,
# chorus, bridge, intro, outro) using energy contour + spectral
# features. Also returns drop points and per-bar energy.

def _find_structure_analyzer():
    """Find the structure-analyzer binary."""
    import os
    tool_paths = [
        os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build", "structure-analyzer"),
        os.path.expanduser("~/Applications/SpliceKit/tools/structure-analyzer"),
        os.path.expanduser("~/Library/Application Support/SpliceKit/tools/structure-analyzer"),
        "/usr/local/bin/structure-analyzer",
    ]
    for p in tool_paths:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def _run_structure_analyzer(file_path: str, sensitivity: float = 0.5,
                             min_bpm: float = 60.0, max_bpm: float = 200.0) -> dict:
    """Run structure-analyzer and return parsed JSON dict (or dict with 'error' key)."""
    import subprocess
    tool = _find_structure_analyzer()
    if not tool:
        return {"error": "structure-analyzer tool not found. Build with: swiftc -O -o build/structure-analyzer tools/structure-analyzer.swift"}
    try:
        result = subprocess.run(
            [tool, file_path, str(sensitivity), str(min_bpm), str(max_bpm)],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            return {"error": f"structure-analyzer failed: {result.stderr}"}
        return json.loads(result.stdout)
    except subprocess.TimeoutExpired:
        return {"error": "structure-analyzer timed out"}
    except json.JSONDecodeError as e:
        return {"error": f"structure-analyzer returned invalid JSON: {e}"}
    except Exception as e:
        return {"error": str(e)}


@mcp.tool(annotations=_tool_annotations("analyze_song_structure"))
def analyze_song_structure(file_path: str, sensitivity: float = 0.5,
                           min_bpm: float = 60.0, max_bpm: float = 200.0) -> str:
    """Analyze a song's structure — detect verse, chorus, bridge, intro, outro sections.

    Goes beyond basic beat detection: segments the song by energy + spectral
    features, groups similar sections (repeated verses/choruses), detects
    "drop" points (sudden energy spikes), and returns per-bar energy contour.

    Args:
        file_path: Path to audio file (MP3, WAV, M4A, AAC, AIFF, etc.)
        sensitivity: Beat detection sensitivity 0.0-1.0 (default 0.5).
        min_bpm: Minimum expected BPM (default 60).
        max_bpm: Maximum expected BPM (default 200).

    Returns labeled song structure, beats, bars, BPM, drops, and energy contour.
    """
    import os
    data = _run_structure_analyzer(file_path, sensitivity, min_bpm, max_bpm)
    if "error" in data:
        return f"Error: {data['error']}"

    lines = [
        f"Song Structure Analysis: {os.path.basename(file_path)}",
        f"Duration: {data['duration']:.1f}s  BPM: {data['bpm']}  Bars: {data['barCount']}  Beats: {data['beatCount']}",
        "",
        "Structure:",
    ]
    for s in data.get("structure", []):
        lines.append(f"  {s['label']:15s}  {s['start']:7.1f}s - {s['end']:7.1f}s  "
                     f"({s['bars']:2d} bars, energy={s['energy']:.2f}, {s['duration']:.1f}s)")

    drops = data.get("drops", [])
    if drops:
        lines.append(f"\nDrops ({len(drops)}): {', '.join(f'{d:.1f}s' for d in drops)}")

    lines.append(f"\nBeat interval: {data.get('beatInterval', 0):.4f}s")
    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("beat_sync_blade"))
def beat_sync_blade(file_path: str, cut_on: str = "bar",
                    sensitivity: float = 0.5, min_bpm: float = 60.0,
                    max_bpm: float = 200.0,
                    range_start: float = -1, range_end: float = -1,
                    min_clip_duration: float = 0,
                    offset_frames: int = 0,
                    dry_run: bool = False) -> str:
    """Analyze a song's beats and blade the timeline at musical boundaries.

    Combines beat/structure analysis with blade_at_times in a single call.
    Detects beats in the audio file, then cuts the FCP timeline at the
    selected musical level (every beat, bar, section, etc.).

    Args:
        file_path: Path to audio file to analyze for beat timing.
        cut_on: What to cut on. Options:
            "beat"     — every beat (fast cuts, ~0.5s at 120 BPM)
            "bar"      — every bar/measure (natural pacing, ~2s at 120 BPM)
            "section"  — at structural section boundaries (verse/chorus/bridge)
            "downbeat" — only on beat 1 of each bar (same as "bar")
            "drop"     — only at detected drop points (dramatic energy spikes)
            "half_bar" — every 2 beats
        sensitivity: Beat detection sensitivity 0.0-1.0 (default 0.5).
        min_bpm: Minimum expected BPM (default 60).
        max_bpm: Maximum expected BPM (default 200).
        range_start: Only blade after this time in seconds (-1 = from start).
        range_end: Only blade before this time in seconds (-1 = to end).
        min_clip_duration: Skip cuts that would create clips shorter than this (seconds).
                           Prevents flash frames at fast tempos.
        offset_frames: Shift all cuts by N frames. Negative = cut before the beat
                       (anticipation feel), positive = cut after (laid-back feel).
                       Typical: -2 for music video anticipation.
        dry_run: If True, return the cut plan without actually blading.

    Returns summary of cuts applied (or planned if dry_run).
    """
    import os
    # Run structure analysis (includes beats, bars, structure, drops)
    data = _run_structure_analyzer(file_path, sensitivity, min_bpm, max_bpm)
    if "error" in data:
        return f"Error: {data['error']}"

    bpm = data.get("bpm", 120)
    beat_interval = data.get("beatInterval", 0.5)

    # Select timestamps based on cut_on mode
    if cut_on == "beat":
        times = data.get("beats", [])
        level_desc = "beat"
    elif cut_on in ("bar", "downbeat"):
        times = data.get("bars", [])
        level_desc = "bar"
    elif cut_on == "half_bar":
        # Every 2 beats
        beats = data.get("beats", [])
        times = [beats[i] for i in range(0, len(beats), 2)]
        level_desc = "half-bar (every 2 beats)"
    elif cut_on == "section":
        # Use structural section boundaries
        structure = data.get("structure", [])
        times = [s["start"] for s in structure]
        level_desc = "section boundary"
    elif cut_on == "drop":
        times = data.get("drops", [])
        level_desc = "drop"
    else:
        return f"Error: unknown cut_on value '{cut_on}'. Use: beat, bar, section, downbeat, drop, half_bar"

    if not times:
        return f"Error: no {level_desc} timestamps found in audio analysis"

    # Apply time range filter
    if range_start >= 0:
        times = [t for t in times if t >= range_start]
    if range_end >= 0:
        times = [t for t in times if t <= range_end]

    # Apply frame offset (convert frames to seconds using common frame rates)
    if offset_frames != 0:
        # Estimate frame rate from beat interval: use 24fps as default
        # (FCP projects are typically 23.976, 24, 25, 29.97, or 30 fps)
        frame_duration = 1.0 / 24.0  # ~0.0417s per frame
        offset_seconds = offset_frames * frame_duration
        times = [t + offset_seconds for t in times]
        # Remove any that went negative
        times = [t for t in times if t > 0]

    # Apply minimum clip duration filter
    if min_clip_duration > 0 and len(times) > 1:
        filtered = [times[0]]
        for t in times[1:]:
            if (t - filtered[-1]) >= min_clip_duration:
                filtered.append(t)
        times = filtered

    # Skip the first timestamp if it's at 0.0 (nothing to blade there)
    times = [t for t in times if t > 0.05]

    if not times:
        return "No cut points remain after filtering"

    # Build summary
    structure = data.get("structure", [])
    struct_summary = ""
    if structure:
        labels = [s["label"] for s in structure]
        struct_summary = f"\nSong structure: {' → '.join(labels)}"

    header = (
        f"Beat Sync Blade: {os.path.basename(file_path)}\n"
        f"BPM: {bpm}  Cut on: {level_desc}  Cuts: {len(times)}{struct_summary}\n"
    )

    if dry_run:
        lines = [header + "DRY RUN — no cuts applied\n"]
        lines.append("Planned cuts:")
        prev = 0.0
        for i, t in enumerate(times):
            clip_dur = t - prev
            lines.append(f"  {i+1:3d}. {t:7.2f}s  (clip: {clip_dur:.2f}s)")
            prev = t
        # Final clip to end
        duration = data.get("duration", 0)
        if duration > 0 and times:
            lines.append(f"  {len(times)+1:3d}. {duration:7.2f}s  (clip: {duration - times[-1]:.2f}s)  [end]")
        lines.append(f"\nShortest clip: {min(times[i] - (times[i-1] if i > 0 else 0) for i in range(len(times))):.2f}s")
        return "\n".join(lines)

    # Execute the blade
    r = bridge.call("timeline.bladeAtTimes", times=times)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    applied = r.get("applied", 0)
    total = r.get("count", len(times))
    lines = [header + f"Applied {applied}/{total} cuts"]

    failures = [c for c in r.get("cuts", []) if not c.get("success")]
    if failures:
        lines.append(f"\nFailed cuts ({len(failures)}):")
        for c in failures[:10]:
            lines.append(f"  {c['time']:.2f}s: {c.get('error', '?')}")

    return "\n".join(lines)


# ============================================================
# Song Structure Blocks (Color-Coded Timeline Sections)
# ============================================================
# Places song structure labels in FCP's native caption lane — the
# thin dedicated area above the timeline clips. Uses FCPXML <caption>
# elements with a custom role so they appear in their own lane.

def _structure_caption_role():
    """Role string for structure block captions. Uses SRT format with a
    'structure' language so they get their own caption lane."""
    return "SRT.structure"


@mcp.tool(annotations=_tool_annotations("song_structure_blocks"))
def song_structure_blocks(file_path: str, sensitivity: float = 0.5,
                          min_bpm: float = 60.0, max_bpm: float = 200.0) -> str:
    """Analyze a song and place section labels in FCP's native caption lane.

    Creates native FCP caption objects showing the song structure (intro, verse,
    chorus, bridge, outro) in the thin dedicated caption area above the timeline.
    Each section appears as a labeled block in the caption lane.

    Args:
        file_path: Path to audio file to analyze for song structure.
        sensitivity: Beat detection sensitivity 0.0-1.0 (default 0.5).
        min_bpm: Minimum expected BPM (default 60).
        max_bpm: Maximum expected BPM (default 200).

    Returns summary of structure blocks placed in the caption lane.
    """
    import os
    # Run structure analysis
    data = _run_structure_analyzer(file_path, sensitivity, min_bpm, max_bpm)
    if "error" in data:
        return f"Error: {data['error']}"

    structure = data.get("structure", [])
    if not structure:
        return "Error: no song structure detected"

    # Get timeline properties for rational time arithmetic
    pos = bridge.call("playback.getPosition")
    if _err(pos):
        return f"Error: {pos.get('error', pos)}"
    fd = pos.get("frameDuration", {})
    fd_num = fd.get("value", 100)
    fd_den = fd.get("timescale", 2400)

    def dur_rational(seconds):
        frames = round(seconds * fd_den / fd_num)
        return f"{frames * fd_num}/{fd_den}s"

    # Compute total duration (end of last section + 1s padding)
    total_dur = max(s["end"] for s in structure) + 1.0
    total_dur_str = dur_rational(total_dur)
    caption_role = _structure_caption_role()

    # Build FCPXML with <caption> elements inside a gap
    # These appear in FCP's native caption lane
    caption_xml = ""
    for s in structure:
        label = s["label"].upper()
        offset_str = dur_rational(s["start"])
        dur_str = dur_rational(s["duration"])
        caption_xml += (
            f'                            <caption lane="1" offset="{offset_str}" '
            f'name="{label}" duration="{dur_str}" role="{caption_role}">\n'
            f'                                <text>{label}</text>\n'
            f'                            </caption>\n'
        )

    xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>

<fcpxml version="1.11">
    <resources>
        <format id="r1" frameDuration="{fd_num}/{fd_den}s" width="1920" height="1080"/>
    </resources>
    <library>
        <event name="SpliceKit Structure">
            <project name="SpliceKit Structure Blocks">
                <sequence format="r1" duration="{total_dur_str}" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                    <spine>
                        <gap name="placeholder" duration="{total_dur_str}" start="0s">
{caption_xml}                        </gap>
                    </spine>
                </sequence>
            </project>
        </event>
    </library>
</fcpxml>'''

    # Use the ObjC bridge to create native captions in the caption lane.
    # This does: FCPXML import → load temp project → selectAll → copy → switch back → paste
    r = bridge.call("structure.generateCaptions", sections=structure)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    caption_count = r.get("captionCount", 0)
    lines = [
        f"Structure Blocks: {os.path.basename(file_path)}",
        f"BPM: {data.get('bpm', '?')}  Sections: {len(structure)}  Captions placed: {caption_count}",
        f"Placed in caption lane (same area as subtitles)",
        "",
    ]
    for s in structure:
        lines.append(f"  {s['label'].upper():15s}  {s['start']:7.1f}s - {s['end']:7.1f}s  ({s['duration']:.1f}s)")

    lines.append(f"\nToggle visibility: View > Timeline Index > Captions tab")
    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("toggle_structure_blocks"))
def toggle_structure_blocks() -> str:
    """Toggle visibility of song structure blocks on the timeline.

    If structure blocks exist, removes them. If they don't exist,
    returns an error (use song_structure_blocks to create them first).
    """
    r = bridge.call("structure.toggle")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    removed = r.get("removed", 0)
    if removed > 0:
        return f"Removed {removed} structure block storyline(s)"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("remove_structure_blocks"))
def remove_structure_blocks() -> str:
    """Remove all song structure blocks from the timeline."""
    r = bridge.call("structure.remove")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    removed = r.get("removed", 0)
    return f"Removed {removed} structure block storyline(s)"


# ============================================================
# Sections Bar (Custom Timeline View)
# ============================================================
# A dedicated color-coded bar injected into FCP's timeline showing
# song structure sections. Each section has its own color and can be
# modified via right-click context menu or these MCP tools.

@mcp.tool(annotations=_tool_annotations("song_structure_sections"))
def song_structure_sections(file_path: str, sensitivity: float = 0.5,
                             min_bpm: float = 60.0, max_bpm: float = 200.0) -> str:
    """Analyze a song and display color-coded sections in a dedicated bar above the timeline.

    Creates a thin, color-coded bar above the FCP timeline showing the song
    structure (intro, verse, chorus, bridge, outro). Each section type gets
    its own color. Right-click any section to change its color, rename it,
    or remove it. Right-click empty space to add new sections.

    The sections bar is a custom view — independent from captions, roles,
    or any other FCP system. Sections persist per-project.

    Args:
        file_path: Path to audio file to analyze.
        sensitivity: Beat detection sensitivity 0.0-1.0 (default 0.5).
        min_bpm: Minimum expected BPM (default 60).
        max_bpm: Maximum expected BPM (default 200).

    Returns summary of sections placed in the bar.
    """
    import os
    data = _run_structure_analyzer(file_path, sensitivity, min_bpm, max_bpm)
    if "error" in data:
        return f"Error: {data['error']}"

    structure = data.get("structure", [])
    if not structure:
        return "Error: no song structure detected"

    r = bridge.call("sections.show", sections=structure)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [
        f"Sections Bar: {os.path.basename(file_path)}",
        f"BPM: {data.get('bpm', '?')}  Sections: {r.get('sectionCount', len(structure))}",
        "",
    ]
    for s in structure:
        lines.append(f"  {s['label']:15s}  {s['start']:7.1f}s - {s['end']:7.1f}s  ({s['duration']:.1f}s)")
    lines.append(f"\nRight-click the sections bar to change colors, rename, add, or remove sections.")
    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("get_sections"))
def get_sections() -> str:
    """Get the current sections displayed in the timeline sections bar."""
    r = bridge.call("sections.get")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("hide_sections"))
def hide_sections() -> str:
    """Hide the sections bar from the timeline."""
    r = bridge.call("sections.hide")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Sections bar hidden"


# ============================================================
# FlexMusic (Dynamic Soundtrack)
# ============================================================
# FCP's built-in AI music engine. Songs can stretch/shrink to
# any duration by rearranging their musical sections dynamically.

@mcp.tool(annotations=_tool_annotations("flexmusic_list_songs"))
def flexmusic_list_songs(filter: str = "") -> str:
    """List available FlexMusic songs that can dynamically fit any project duration.

    Args:
        filter: Optional search filter for song name, mood, or genre.

    Returns list of songs with uid, name, artist, mood, pace, and genres.
    Songs dynamically adjust their arrangement to match any target duration.
    """
    r = bridge.call("flexmusic.listSongs", filter=filter)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("flexmusic_get_song"))
def flexmusic_get_song(song_uid: str) -> str:
    """Get detailed info about a specific FlexMusic song.

    Args:
        song_uid: The unique identifier of the song.

    Returns metadata (mood, pace, genres, arousal, valence),
    natural duration, minimum duration, and ideal durations.
    """
    r = bridge.call("flexmusic.getSong", songUID=song_uid)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("flexmusic_get_timing"))
def flexmusic_get_timing(song_uid: str, duration_seconds: float) -> str:
    """Get beat, bar, and section timing for a FlexMusic song fitted to a specific duration.

    The song's arrangement is dynamically computed to fit the requested duration.
    Returns precise timestamps for every beat, bar, and section boundary.
    These timestamps can be used to cut video clips to the rhythm.

    Args:
        song_uid: The unique identifier of the song.
        duration_seconds: Target duration in seconds to fit the song to.

    Returns arrays of beat timestamps, bar timestamps, section timestamps,
    and the actual fitted duration.
    """
    r = bridge.call("flexmusic.getTiming", songUID=song_uid, durationSeconds=duration_seconds)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("flexmusic_render_to_file"))
def flexmusic_render_to_file(song_uid: str, duration_seconds: float, output_path: str, format: str = "m4a") -> str:
    """Render a FlexMusic song fitted to a specific duration as an audio file.

    The song arrangement is dynamically computed to perfectly fill the duration,
    then rendered to a standard audio file that can be imported into any project.

    Args:
        song_uid: The unique identifier of the song.
        duration_seconds: Target duration in seconds.
        output_path: Where to save the rendered audio file.
        format: Audio format - "m4a" (AAC, default) or "wav".
    """
    r = bridge.call("flexmusic.renderToFile", songUID=song_uid,
                     durationSeconds=duration_seconds, outputPath=output_path, format=format)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("flexmusic_add_to_timeline"))
def flexmusic_add_to_timeline(song_uid: str, duration_seconds: float = 0) -> str:
    """Add a FlexMusic song to the current timeline as background music.

    The song dynamically fits to the specified duration (or the timeline duration
    if not specified). It will automatically re-arrange if the project length changes.

    Args:
        song_uid: The unique identifier of the song.
        duration_seconds: Target duration (0 = use current timeline duration).
    """
    r = bridge.call("flexmusic.addToTimeline", songUID=song_uid,
                     durationSeconds=duration_seconds)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Montage Maker (Auto-Edit to Beat)
# ============================================================
# End-to-end pipeline: analyze clips -> plan cuts to music beats
# -> assemble a montage timeline. Can run as individual steps
# or as a single montage_auto() call.

@mcp.tool(annotations=_tool_annotations("montage_analyze_clips"))
def montage_analyze_clips(event_name: str = "") -> str:
    """Analyze clips in the browser for montage creation.

    Scans clips in the specified event (or all events), scores them
    based on duration, type (video/photo), and available metadata.
    Returns a ranked list of clips suitable for montage assembly.

    Args:
        event_name: Event name to scan (empty = all events).
    """
    r = bridge.call("montage.analyzeClips", eventName=event_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("montage_plan_edit"))
def montage_plan_edit(beats: str, clips: str, style: str = "bar", total_duration: float = 0) -> str:
    """Create an edit decision list (EDL) that maps clips to musical beats.

    Takes beat/bar timing data and scored clips, then creates a plan
    that assigns the best clips to each musical segment.

    Args:
        beats: JSON array of beat timestamps in seconds (from flexmusic_get_timing).
        clips: JSON array of clip objects with handle, duration, score (from montage_analyze_clips).
        style: Cut rhythm - "beat" (every beat), "bar" (every bar/measure), "section" (at sections).
        total_duration: Total montage duration in seconds (0 = sum of available clips).

    Returns an edit decision list with clip assignments, in/out points, and timeline positions.
    """
    import json as _json
    beats_arr = _json.loads(beats) if isinstance(beats, str) else beats
    clips_arr = _json.loads(clips) if isinstance(clips, str) else clips
    r = bridge.call("montage.planEdit", beats=beats_arr, clips=clips_arr,
                     style=style, totalDuration=total_duration)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("montage_assemble"))
def montage_assemble(edit_plan: str, project_name: str = "Montage", song_file: str = "") -> str:
    """Assemble a montage on the timeline from an edit plan.

    Takes the edit decision list and creates the actual timeline:
    places clips at their assigned positions, adds transitions,
    and includes the background music track.

    Uses FCPXML import for reliable, atomic timeline construction.

    Args:
        edit_plan: JSON string of the edit decision list (from montage_plan_edit).
        project_name: Name for the new project.
        song_file: Path to rendered FlexMusic audio file (from flexmusic_render_to_file).
    """
    import json as _json
    plan = _json.loads(edit_plan) if isinstance(edit_plan, str) else edit_plan
    r = bridge.call("montage.assemble", editPlan=plan, projectName=project_name, songFile=song_file)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("montage_auto"))
def montage_auto(song_uid: str = "", event_name: str = "", style: str = "bar", project_name: str = "Montage") -> str:
    """One-shot automatic montage creation.

    Analyzes clips, selects a song, gets beat timing, plans the edit,
    renders the music, and assembles everything into a new timeline.

    This is the high-level convenience function that orchestrates the
    entire montage creation pipeline in a single call.

    Args:
        song_uid: FlexMusic song UID (empty = auto-select based on clip mood).
        event_name: Event to pull clips from (empty = all events).
        style: Cut rhythm - "beat", "bar" (default), or "section".
        project_name: Name for the new project.
    """
    r = bridge.call("montage.auto", songUID=song_uid, eventName=event_name,
                     style=style, projectName=project_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Debug & Diagnostics
# ============================================================
# Exposes FCP's hidden internal debug flags (TLK visual overlays,
# ProAppSupport logging, CFPreferences keys) and SpliceKit's own
# debugging toolkit (breakpoints, tracing, eval, crash handling).

@mcp.tool(annotations=_tool_annotations("debug_get_config"))
def debug_get_config() -> str:
    """Get current state of all FCP internal debug/logging settings.

    Returns the current values of:
    - Timeline debug flags (TLK*): visual overlays, logging, performance monitors
    - CFPreferences debug flags: video decoder log level, frame drop logging, GPU logging
    - ProAppSupport log settings: log level, categories, in-app panel visibility, thread info
    - FCP behavior flags: gap coalescing, snapping, skimming overrides

    Use this to see what debug options are currently active before changing them.
    """
    r = bridge.call("debug.getConfig")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("debug_set_config"))
def debug_set_config(key: str, value: str = "true") -> str:
    """Set a single FCP internal debug/logging flag.

    Args:
        key: The debug key to set. Common keys:

            Timeline visual overlays:
              TLKShowItemLaneIndex, TLKShowMisalignedEdges, TLKShowRenderBar,
              TLKShowHiddenGapItems, TLKShowHiddenItemHeaders,
              TLKShowInvalidLayoutRects, TLKShowContainerBounds,
              TLKShowContentLayers, TLKShowRulerBounds, TLKShowUsedRegion,
              TLKShowZeroHeightSpineItems

            Timeline logging:
              TLKLogVisibleLayerChanges, TLKLogParts, TLKLogReloadRequests,
              TLKLogRecyclingLayerChanges, TLKLogVisibleRectChanges,
              TLKLogSegmentationStatistics

            Performance/rendering:
              TLKPerformanceMonitorEnabled, TLKDebugColorChangedObjects,
              TLKDebugLayoutConstraints, TLKDebugErrorsAndWarnings,
              TLKDisableItemContents,
              DebugKeyItemVideoFilmstripsDisabled,
              DebugKeyItemBackgroundDisabled,
              DebugKeyItemAudioWaveformsDisabled

            Video/audio logging (integer values, higher = more verbose):
              VideoDecoderLogLevelInNLE, FrameDropLogLevel

            GPU/effects logging:
              GPU_LOGGING, EnableScheduledReadAudioLogging

            Library debugging:
              EnableLibraryUpdateHistoryValidation

            Transcription:
              FFVAMLSaveTranscription

            ProAppSupport log system:
              LogLevel (trace/debug/info/warning/error/failure),
              LogUI (show/hide the in-app SpliceKit log panel),
              LogThread (include thread info in emitted SpliceKit log lines),
              LogCategory (bitmask)

            FCP behavior overrides:
              FFDontCoalesceGaps, FFDisableSnapping, FFDisableSkimming

        value: Value to set. "true"/"false" for bools, integer string for int keys,
               or level name for LogLevel (trace/debug/info/warning/error/failure).
    """
    # Coerce the string value to the right type -- the bridge expects bool/int/string
    if value.lower() in ("true", "yes", "1"):
        parsed = True
    elif value.lower() in ("false", "no", "0"):
        parsed = False
    else:
        try:
            parsed = int(value)
        except ValueError:
            parsed = value  # pass as string (for LogLevel names like "trace", "debug", etc.)

    r = bridge.call("debug.setConfig", key=key, value=parsed)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("debug_reset_config"))
def debug_reset_config(scope: str = "all") -> str:
    """Reset debug/logging settings to defaults.

    Args:
        scope: What to reset:
          "all" - reset everything
          "tlk" - reset timeline debug flags only
          "cfprefs" - reset CFPreferences debug flags only
          "log" - reset ProAppSupport log settings only
    """
    r = bridge.call("debug.resetConfig", scope=scope)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("debug_enable_preset"))
def debug_enable_preset(preset: str) -> str:
    """Enable a preset group of debug settings.

    Args:
        preset: One of:
          "timeline_visual" - Show lane indices, misaligned edges, render bar,
                              hidden gaps, invalid layouts, color-highlight changes
          "timeline_logging" - Log layer changes, parts, reload requests,
                               recycling, visible rect changes, segmentation stats
          "performance" - Enable TLK performance monitor, video decoder logging,
                          frame drop logging
          "render_debug" - Disable filmstrips/backgrounds/waveforms rendering,
                           enable GPU logging (isolates render issues)
          "verbose_logging" - Set ProAppSupport log level to trace, enable log UI,
                              thread info, and audio logging
          "all_off" - Disable all debug flags and reset to defaults
    """
    r = bridge.call("debug.enablePreset", preset=preset)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("debug_start_framerate_monitor"))
def debug_start_framerate_monitor(interval: float = 2.0) -> str:
    """Start FCP's built-in HMD framerate monitor.

    Logs FPS and frame timing statistics to the system log at regular intervals.
    View output in Console.app or via: log stream --process "Final Cut Pro"

    Reports: overall fps, average getFrame() time, min/max frame times in ms.

    Args:
        interval: Seconds between measurements (default 2.0).
    """
    r = bridge.call("debug.startFramerateMonitor", interval=interval)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("debug_stop_framerate_monitor"))
def debug_stop_framerate_monitor() -> str:
    """Stop the HMD framerate monitor."""
    r = bridge.call("debug.stopFramerateMonitor")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# -- Runtime metadata export (for reverse engineering / IDA Pro) --

@mcp.tool(annotations=_tool_annotations("dump_runtime_metadata"))
def dump_runtime_metadata(binary: str = "", classes_only: bool = False) -> str:
    """Bulk-export ObjC runtime metadata from a running FCP process for IDA Pro import.

    Returns loaded images (with ASLR slides and base addresses) and full class metadata
    including instance/class methods with IMP addresses, ivars with offsets, properties,
    protocols, and superchains.

    Args:
        binary: Optional filter — match binary/framework name (e.g. "Flexo", "TLKit")
        classes_only: If true, return just class names per image (fast overview)
    """
    params = {}
    if binary:
        params["binary"] = binary
    if classes_only:
        params["classesOnly"] = True
    r = bridge.call("debug.dumpRuntimeMetadata", params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("list_loaded_images"))
def list_loaded_images(filter: str = "") -> str:
    """List all Mach-O images loaded in FCP's process with base addresses and ASLR slides.

    Use this to see which frameworks/dylibs are loaded and their address information
    needed for mapping runtime IMP addresses to static IDA addresses.

    Args:
        filter: Optional filter string to match image name/path
    """
    params = {}
    if filter:
        params["filter"] = filter
    r = bridge.call("debug.listLoadedImages", params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("get_image_sections"))
def get_image_sections(binary: str) -> str:
    """Get ObjC section data for a loaded binary: selector refs, class refs, superclass refs.

    Returns the selectors referenced by this binary (which methods it calls),
    the classes it references, and superclass references. Essential for
    understanding cross-binary dependencies and building call graphs.

    Args:
        binary: Binary/framework name to inspect (e.g. "Flexo", "TLKit")
    """
    r = bridge.call("debug.getImageSections", {"binary": binary})
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("get_image_symbols"))
def get_image_symbols(binary: str, filter: str = "", demangle: bool = True) -> str:
    """Get exported symbols from a loaded binary's symbol table.

    Returns all exported defined symbols including C functions, ObjC class symbols,
    global variables, and Swift symbols (with automatic demangling).

    Args:
        binary: Binary/framework name to inspect
        filter: Optional filter to match symbol names
        demangle: Whether to demangle Swift symbols (default True)
    """
    params = {"binary": binary}
    if filter:
        params["filter"] = filter
    if not demangle:
        params["demangle"] = False
    r = bridge.call("debug.getImageSymbols", params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("get_notification_names"))
def get_notification_names(binary: str = "") -> str:
    """Enumerate NSNotification name constants from exported symbols.

    Finds all exported symbols containing 'Notification' and resolves their
    actual NSString values. These are the notification names used in
    NSNotificationCenter postNotificationName: calls.

    Args:
        binary: Optional filter to a specific binary/framework
    """
    params = {}
    if binary:
        params["binary"] = binary
    r = bridge.call("debug.getNotificationNames", params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Debug: Breakpoints
# ---------------------------------------------------------------------------
# True breakpoints that freeze FCP mid-execution. The JSON-RPC server
# stays alive on a background thread so you can inspect state while paused.

@mcp.tool(annotations=_tool_annotations("debug_breakpoint"))
def debug_breakpoint(action: str = "list", class_name: str = "", selector: str = "",
                     condition: str = "", hit_count: int = 0, one_shot: bool = False,
                     key_path: str = "", store_result: bool = False,
                     class_method: bool = False) -> str:
    """Set, manage, and interact with in-process breakpoints on FCP methods.

    True breakpoints that pause FCP execution, let you inspect state, then continue.
    FCP's UI freezes while paused (same as Xcode). The JSON-RPC server stays alive
    on a separate thread so you can inspect and continue.

    Args:
        action: One of:
            - "add": Set a breakpoint on className.selector
            - "remove": Remove a breakpoint
            - "removeAll": Remove all breakpoints (auto-resumes if paused)
            - "list": List all breakpoints and paused state
            - "enable": Re-enable a disabled breakpoint
            - "disable": Disable without removing
            - "continue": Resume paused execution
            - "step": Resume but auto-break on next call to same class
            - "inspect": Get current paused state (self, args, call stack)
            - "inspectSelf": Evaluate a keyPath on the paused self object
        class_name: ObjC class name (e.g. "FFAnchoredTimelineModule")
        selector: ObjC selector (e.g. "blade:")
        condition: Optional keyPath on self that must be truthy for bp to fire
        hit_count: Only fire after this many calls (skip earlier ones)
        one_shot: If true, auto-remove after first hit
        key_path: For inspectSelf — the property path to evaluate
        store_result: For inspectSelf — store the result as a handle
        class_method: If true, breakpoint a class method (+) instead of instance (-)

    When a breakpoint fires, a "breakpoint.hit" event is broadcast with:
    - selfClass, self description, selfHandle
    - firstArg (if present), firstArgHandle
    - callStack (up to 20 frames)
    - threadName, isMainThread

    While paused, use debug_eval(), call_method_with_args(), or inspectSelf
    to examine state before continuing.
    """
    params = {"action": action}
    if class_name:
        params["className"] = class_name
    if selector:
        params["selector"] = selector
    if condition:
        params["condition"] = condition
    if hit_count > 0:
        params["hitCount"] = hit_count
    if one_shot:
        params["oneShot"] = True
    if key_path:
        params["keyPath"] = key_path
    if store_result:
        params["storeResult"] = True
    if class_method:
        params["classMethod"] = True
    r = bridge.call("debug.breakpoint", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Debug: Method Tracing
# ---------------------------------------------------------------------------
# Non-blocking alternative to breakpoints. Swizzles methods to log calls
# without pausing. Good for understanding call patterns and frequencies.

@mcp.tool(annotations=_tool_annotations("debug_trace_method"))
def debug_trace_method(action: str = "list", class_name: str = "", selector: str = "",
                       log_stack: bool = False, log_args: bool = True,
                       limit: int = 50, class_method: bool = False) -> str:
    """Trace ObjC method calls without pausing execution.

    Swizzles the target method to log every call with timestamp, self, and
    optionally the call stack. Traces are stored in a circular buffer (500 entries)
    and broadcast to MCP clients in real-time.

    Use this when you want to observe call patterns without freezing FCP.
    Use debug_breakpoint() when you need to pause and inspect.

    Args:
        action: One of:
            - "add": Start tracing className.selector
            - "remove": Stop tracing a specific method
            - "removeAll": Stop all traces
            - "list": List active traces
            - "getLog": Read trace log entries
            - "clearLog": Clear the trace log buffer
        class_name: ObjC class name
        selector: ObjC selector
        log_stack: Include call stack in trace entries (slower but more info)
        log_args: Log argument info (default true)
        limit: For getLog — max entries to return
        class_method: Trace a class method (+) instead of instance (-)
    """
    params = {"action": action}
    if class_name:
        params["className"] = class_name
    if selector:
        params["selector"] = selector
    if log_stack:
        params["logStack"] = True
    if not log_args:
        params["logArgs"] = False
    if action == "getLog":
        params["limit"] = limit
    if class_method:
        params["classMethod"] = True
    r = bridge.call("debug.traceMethod", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Debug: Property Watching (KVO)
# ---------------------------------------------------------------------------
# Uses ObjC Key-Value Observing to fire events whenever a property changes.
# Replaces hardware watchpoints -- works on any KVO-compliant property.

@mcp.tool(annotations=_tool_annotations("debug_watch"))
def debug_watch(action: str = "list", handle: str = "", class_name: str = "",
                key_path: str = "", watch_key: str = "") -> str:
    """Watch ObjC property changes via KVO (Key-Value Observing).

    When a watched property changes, old/new values are broadcast to MCP clients.

    Args:
        action: One of:
            - "add": Start watching a property
            - "remove": Stop watching (requires watch_key)
            - "removeAll": Stop all watches
            - "list": List active watches
        handle: Object handle (e.g. "obj_1") to watch
        class_name: Class name (resolved to singleton if no handle)
        key_path: The property to watch (e.g. "mainWindow", "sequence.displayName")
        watch_key: For remove — the key returned when the watch was created
    """
    params = {"action": action}
    if handle:
        params["handle"] = handle
    if class_name:
        params["className"] = class_name
    if key_path:
        params["keyPath"] = key_path
    if watch_key:
        params["watchKey"] = watch_key
    r = bridge.call("debug.watch", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Debug: Crash Handler
# ---------------------------------------------------------------------------
# Catches NSExceptions and Unix signals before the process dies,
# so you get a stack trace instead of a silent crash.

@mcp.tool(annotations=_tool_annotations("debug_crash_handler"))
def debug_crash_handler(action: str = "install") -> str:
    """Install or query the in-process crash handler.

    Catches uncaught NSExceptions and Unix signals (SIGABRT, SIGSEGV, SIGBUS,
    SIGFPE, SIGILL) inside FCP. Captures full stack traces and broadcasts to
    MCP clients before the process terminates.

    Args:
        action: One of:
            - "install": Install exception + signal handlers (idempotent)
            - "status": Check if installed + crash count
            - "getLog": Read captured crash stack traces
            - "clearLog": Clear the crash log
    """
    r = bridge.call("debug.crashHandler", action=action)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Debug: Thread Inspection
# ---------------------------------------------------------------------------
# Lists all ~45 threads in FCP's process with CPU usage via Mach APIs.

@mcp.tool(annotations=_tool_annotations("debug_threads"))
def debug_threads(detailed: bool = False) -> str:
    """List all threads in FCP's process with CPU usage and state.

    Uses Mach kernel APIs for accurate thread counts and per-thread metrics.

    Args:
        detailed: If true, include per-thread CPU usage, run state, and
                  call stacks for the current and main threads.

    Returns thread count, operation queue info, and optionally per-thread:
    - cpuUsage (percentage 0-100)
    - userTime / systemTime (seconds)
    - runState (1=running, 2=stopped, 3=waiting)
    - suspended flag
    """
    r = bridge.call("debug.threads", detailed=detailed)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Debug: Expression Evaluation
# ---------------------------------------------------------------------------
# Like lldb's `po` command. Walks ObjC property chains at runtime.

@mcp.tool(annotations=_tool_annotations("debug_eval"))
def debug_eval(expression: str = "", chain: str = "", target: str = "",
               store_result: bool = False) -> str:
    """Evaluate ObjC property chains inside FCP's process.

    Two modes:
    1. Dot expression: "NSApp.delegate._targetLibrary.displayName"
    2. Chain array: ["delegate", "_targetLibrary", "displayName"]

    Each step tries respondsToSelector: first, then KVC valueForKey: as fallback.

    Args:
        expression: Dot-separated property chain (e.g. "NSApp.delegate.className")
                   Starting points: "NSApp", "obj_XXX" (handle), or any class name
        chain: Comma-separated chain of property/method names (alternative to expression)
               e.g. "delegate,_targetLibrary,displayName"
        target: Object handle to start the chain from (e.g. "obj_1"). If omitted,
                starts from NSApp for chain mode.
        store_result: Store the final result as a handle for further inspection

    Returns the result value, its class, and optionally a handle.
    """
    params = {}
    if expression:
        params["expression"] = expression
    if chain:
        params["chain"] = [s.strip() for s in chain.split(",")]
    if target:
        params["target"] = target
    if store_result:
        params["storeResult"] = True
    r = bridge.call("debug.eval", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Debug: Hot Plugin Loading
# ---------------------------------------------------------------------------
# dlopen/dlclose for live-patching FCP without restarting.

@mcp.tool(annotations=_tool_annotations("debug_load_plugin"))
def debug_load_plugin(action: str = "list", path: str = "") -> str:
    """Dynamically load or unload code in FCP's running process.

    Load compiled .dylib or .bundle files without restarting FCP.
    The dylib's __attribute__((constructor)) runs immediately on load.
    Use for hot-patching fixes or adding features at runtime.

    Args:
        action: One of:
            - "load": Load a dylib or bundle into FCP
            - "unload": Unload a previously loaded dylib
            - "list": List currently loaded plugins
        path: File path to the .dylib or .bundle to load/unload

    Workflow:
    1. Write patch code (ObjC with constructor function)
    2. Compile: clang -dynamiclib -framework Foundation -o /tmp/fix.dylib fix.m
    3. Load: debug_load_plugin(action="load", path="/tmp/fix.dylib")
    4. Test the change
    5. Unload: debug_load_plugin(action="unload", path="/tmp/fix.dylib")
    """
    params = {"action": action}
    if path:
        params["path"] = path
    r = bridge.call("debug.loadPlugin", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Debug: Notification Observation
# ---------------------------------------------------------------------------
# Subscribe to NSNotificationCenter events. FCP posts 337+ named
# notifications internally -- this lets you see them in real time.

@mcp.tool(annotations=_tool_annotations("debug_observe_notification"))
def debug_observe_notification(action: str = "list", name: str = "",
                               log_object: bool = False) -> str:
    """Subscribe to FCP's internal NSNotification events.

    Events are broadcast to MCP clients in real-time with notification name,
    object class, and userInfo dictionary.

    Args:
        action: One of:
            - "add": Start observing a notification
            - "remove": Stop observing (requires name)
            - "removeAll": Stop all observers
            - "list": List active observers
        name: Notification name (e.g. "FFEffectsChangedNotification").
              Use "*" to observe ALL notifications (high volume — use briefly).
        log_object: Include the notification's object description in events

    Common notifications:
    - FFEffectsChangedNotification: effect stack modified
    - FFEffectStackChangedNotification: effect added/removed
    - FFAssetMediaChangedNotification: media asset changes
    - FFBeatGridSettingsChangedNotification: beat grid toggled
    - FFQTMovieExporterFinishedNotification: export completes
    See fcp_symbols/notifications.txt for all 337 notification names.
    """
    params = {"action": action}
    if name:
        params["name"] = name
    if log_object:
        params["logObject"] = True
    r = bridge.call("debug.observeNotification", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Direct Timeline Actions (parameterized Flexo methods)
# ---------------------------------------------------------------------------
# Unlike timeline_action() which dispatches through the responder chain
# with no arguments, these call Flexo's action* methods directly with
# real parameters (rates, durations, flags, etc). More powerful but
# requires knowing which parameters each action needs.

@mcp.tool(annotations=_tool_annotations("direct_timeline_action"))
def direct_timeline_action(action: str = "", selector: str = "",
                           rate: float = 0, ripple: bool = False,
                           allow_variable_speed: bool = True,
                           to_zero: bool = False, from_zero: bool = False,
                           frames_to_jump: int = 0, speed: float = 0,
                           name: str = "", marker: str = "",
                           type_: str = "", completed: bool = False,
                           amount: float = 0, relative: bool = True,
                           fade_in: bool = True, duration: float = 0,
                           enabled: bool = True, effect_id: str = "",
                           keywords: str = "", language: str = "",
                           format_: str = "", multicam: bool = False,
                           as_split: bool = False, is_delta: bool = False,
                           replace_with_gap: bool = False,
                           on_edges: bool = True, on_left: bool = True,
                           add_title: bool = True,
                           interpolation: str = "",
                           store_result: bool = False) -> str:
    """Call Flexo's parameterized action methods directly on FFAnchoredTimelineModule.

    More powerful than timeline_action() because these accept real parameters
    (rates, durations, flags) instead of just dispatching through the responder chain.

    Args:
        action: The action name. Available actions:

            Retiming/Speed:
              retimeSetRate (rate, ripple, allow_variable_speed)
              retimeHoldPreset, retimeReverse, retimeBladeSpeedPreset
              retimeSpeedRamp (to_zero, from_zero)
              retimeInstantReplay (rate, allow_variable_speed, add_title)
              retimeJumpCut (frames_to_jump, allow_variable_speed)
              retimeRewind (speed, allow_variable_speed)
              retimeSetInterpolation (interpolation)
              insertFreezeFrame

            Markers:
              changeMarkerType (type_: "chapter"/"todo"/"note")
              changeMarkerName (name, marker handle)
              markMarkerCompleted (completed, marker handle)
              removeMarker (marker handle)

            Audio:
              changeAudioVolume (amount, relative)
              applyAudioFadesDirect (fade_in, duration)
              setAudioPlayEnable (enabled)
              setBackgroundMusic (enabled)
              detachAudioDirect, alignAudioToVideoDirect

            Trim/Edit:
              splitAtTime, trimDuration (is_delta)
              extendOverNextClip, joinThroughEdits (on_edges, on_left)
              removeEdits (replace_with_gap), insertGapDirect

            Clips:
              breakApartClipItems, createCompoundClipDirect (multicam)
              liftAnchoredEdits, renameDirect (name)
              deleteItemsInArray, moveClipsToTrash

            Keywords/Roles:
              addKeywords (keywords: comma-separated), removeKeywords
              setRole

            Effects:
              removeEffectByID (effect_id), invertEffectMasks, toggleEnabled

            Multicam:
              deleteMultiAngle, renameAngle (name), audioSyncMultiAngle

            Variants:
              addVariants, removeVariants, finalizeVariant

            Captions:
              duplicateCaptions (language, format_)

            Music:
              alignToMusicMarkers, alignClipsAtMusicMarkers (as_split)

            Project:
              newProject (name), newEvent (name), validateAndRepair

            Other:
              autoReframeDirect, addTransitionsDirect
              analyzeAndOptimize, resolveLaneConflicts, resolveLaneGaps
              nudgeAnchoredItems, nudgeSpineItems

        selector: Raw ObjC selector for fallback (e.g. "actionValidateAndRepair:validateMode:error:")
    """
    # Only include params that were explicitly set -- the bridge uses their
    # presence/absence to determine which ObjC selector variant to call
    params = {}
    if action:
        params["action"] = action
    if selector:
        params["selector"] = selector
    if rate != 0:
        params["rate"] = rate
    if ripple:
        params["ripple"] = True
    if not allow_variable_speed:
        params["allowVariableSpeed"] = False
    if to_zero:
        params["toZero"] = True
    if from_zero:
        params["fromZero"] = True
    if frames_to_jump > 0:
        params["framesToJump"] = frames_to_jump
    if speed != 0:
        params["speed"] = speed
    if name:
        params["name"] = name
    if marker:
        params["marker"] = marker
    if type_:
        params["type"] = type_
    if completed:
        params["completed"] = True
    if amount != 0:
        params["amount"] = amount
    if not relative:
        params["relative"] = False
    if not fade_in:
        params["fadeIn"] = False
    if duration != 0:
        params["duration"] = duration
    if not enabled:
        params["enabled"] = False
    if effect_id:
        params["effectID"] = effect_id
    if keywords:
        params["keywords"] = [k.strip() for k in keywords.split(",")]
    if language:
        params["language"] = language
    if format_:
        params["format"] = format_
    if multicam:
        params["multicam"] = True
    if as_split:
        params["asSplit"] = True
    if is_delta:
        params["isDelta"] = True
    if replace_with_gap:
        params["replaceWithGap"] = True
    if not on_edges:
        params["onEdges"] = False
    if not on_left:
        params["onLeft"] = False
    if not add_title:
        params["addTitle"] = False
    if interpolation:
        params["interpolation"] = interpolation
    r = bridge.call("timeline.directAction", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ---------------------------------------------------------------------------
# Additional tools: browser, pasteboard import, seek, stabilize, titles,
# transcript engine selection
# ---------------------------------------------------------------------------


@mcp.tool(annotations=_tool_annotations("browser_list_clips"))
def browser_list_clips(event: str = "") -> str:
    """List clips in the FCP browser (media library).

    Returns clips from the active library's events with name, duration,
    media type, and handle for further operations.

    Args:
        event: Optional event name to filter by
    """
    params = {}
    if event:
        params["event"] = event
    r = bridge.call("browser.listClips", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("browser_append_clip"))
def browser_append_clip(handle: str = "", index: int = -1, name: str = "") -> str:
    """Append a clip from the browser to the timeline.

    Resolve the clip by handle (from browser_list_clips), index, or name.

    Args:
        handle: Object handle of the clip (e.g. "obj_5")
        index: Index of the clip in the browser
        name: Name of the clip to find
    """
    params = {}
    if handle:
        params["handle"] = handle
    if index >= 0:
        params["index"] = index
    if name:
        params["name"] = name
    r = bridge.call("browser.appendClip", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("import_media"))
def import_media(paths: list[str] | None = None,
                 path: str = "",
                 event: str = "",
                 library: str = "",
                 manage_file_type: int = 0) -> str:
    """Import local media files into an event's browser — the same landing
    place dragging a file into FCP puts it.

    Wraps -[FFMediaEventProject newClipFromURL:manageFileType:] + addOwnedClipsObject:
    which is FCP's native drop-import path. Works with any file type FCP can
    read (QuickTime, MP4, MXF, BRAW once the format reader is loaded, etc.).

    Args:
        paths: List of absolute paths to import
        path: Single absolute path (alternative to paths)
        event: Substring match for event name (case-insensitive). Empty = first event.
        library: Substring match for library display name. Empty = any library.
        manage_file_type: 0 = leave in place (default), 1 = copy into managed media.

    Returns imported clip handles plus any skipped paths with reasons.
    """
    all_paths: list[str] = []
    if paths:
        all_paths.extend(p for p in paths if p)
    if path:
        all_paths.append(path)
    if not all_paths:
        return "Error: provide `paths` (list) or `path` (single)"
    params: dict = {"paths": all_paths, "manageFileType": manage_file_type}
    if event:
        params["event"] = event
    if library:
        params["library"] = library
    r = bridge.call("media.importFile", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("braw_probe"))
def braw_probe(path: str = "",
               handle: str = "",
               decode_frame_index: int = -1,
               metadata_limit: int = 16,
               include_metadata: bool = False,
               include_processing: bool = False,
               include_audio: bool = False,
               selected: bool = False) -> str:
    """Probe `.braw` media through the Blackmagic RAW SDK without importing or transcoding.

    This validates the native Blackmagic SDK from inside the injected SpliceKit dylib.
    It can inspect an explicit file path, a browser/timeline clip handle, or the current
    selected timeline items when `selected=True` (or when no explicit input is supplied).

    Args:
        path: Absolute filesystem path to a `.braw` clip
        handle: Existing SpliceKit clip handle to resolve to media
        decode_frame_index: Optional frame index to read + decode for validation. Use -1 to skip decode.
        metadata_limit: Number of metadata entries to sample from the clip
        include_metadata: Include clip metadata/timecode/camera info sample
        include_processing: Include current clip processing attributes
        include_audio: Include embedded audio format/sample info
        selected: Probe the current selected timeline items
    """
    params = {
        "decodeFrameIndex": decode_frame_index,
        "metadataLimit": metadata_limit,
    }
    if path:
        params["path"] = path
    if handle:
        params["handle"] = handle
    if include_metadata:
        params["includeMetadata"] = True
    if include_processing:
        params["includeProcessing"] = True
    if include_audio:
        params["includeAudio"] = True
    if selected:
        params["selected"] = True
    r = bridge.call("braw.probe", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("paste_fcpxml"))
def paste_fcpxml(xml: str = "") -> str:
    """Import FCPXML content via the pasteboard (no file I/O, no dialogs).

    Puts FCPXML data on the system pasteboard and triggers FCP's internal
    paste-from-XML handler. Faster and cleaner than file-based import.

    Args:
        xml: FCPXML content string
    """
    params = {}
    if xml:
        params["xml"] = xml
    r = bridge.call("fcpxml.pasteImport", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("stabilize_subject"))
def stabilize_subject() -> str:
    """Stabilize the selected clip around a tracked subject.

    Uses the Vision framework to detect and track a subject at the current
    playhead position, then applies inverse position keyframes so the subject
    stays fixed on screen while the background moves.

    Requirements: a clip must be selected and the playhead should be on a frame
    where the subject is clearly visible.
    """
    r = bridge.call("stabilize.subject")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("insert_title"))
def insert_title(name: str = "", effect_id: str = "") -> str:
    """Insert a title or generator into the timeline.

    Resolves by display name or effect ID. If name is provided, searches
    all available title effects for a case-insensitive match.

    Args:
        name: Display name of the title (e.g. "Basic Title", "Lower Third")
        effect_id: Direct effect ID (e.g. "FFBasicTitleEffect")
    """
    params = {}
    if name:
        params["name"] = name
    if effect_id:
        params["effectID"] = effect_id
    r = bridge.call("titles.insert", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("set_transcript_engine"))
def set_transcript_engine(engine: str) -> str:
    """Set the speech recognition engine for transcript panel.

    Args:
        engine: One of:
            - "fcpNative": FCP's built-in AASpeechAnalyzer
            - "appleSpeech": Apple's SFSpeechRecognizer (slower, network-capable)
    """
    r = bridge.call("transcript.setEngine", engine=engine)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Social Media Captions
# ============================================================
# Word-by-word highlighted, animated caption titles overlaid
# on the timeline as a connected storyline. Uses the Parakeet
# transcript engine for word timing, then generates styled
# FCPXML title elements and imports via pasteboard.


@mcp.tool(annotations=_tool_annotations("open_captions"))
def open_captions(file_url: str = "", style: str = "") -> str:
    """Open the social captions panel and start transcribing the timeline.

    Transcribes timeline audio using Parakeet (word-level timing), then lets
    you choose a visual style and generate social-media-style captions
    (word-by-word highlighted, animated) as FCPXML title clips.

    Args:
        file_url: Optional path to a specific media file to transcribe.
                  If empty, transcribes all clips on the current timeline.
        style: Optional preset ID to apply (e.g. "bold_pop", "neon_glow").
               Use get_caption_styles() to see all available presets.

    Transcription is async — use get_caption_state() to check progress.
    """
    params = {}
    if file_url:
        params["fileURL"] = file_url
    if style:
        params["style"] = style
    r = bridge.call("captions.open", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("close_captions"))
def close_captions() -> str:
    """Close the social captions panel."""
    r = bridge.call("captions.close")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Captions panel closed."


@mcp.tool(annotations=_tool_annotations("get_caption_state"))
def get_caption_state() -> str:
    """Get the current caption panel state.

    Returns status, word count, segment count, current style, and segment list.
    Use after open_captions() to check transcription progress.
    """
    r = bridge.call("captions.getState")
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Status: {r.get('status', 'unknown')}"]
    lines.append(f"Words: {r.get('wordCount', 0)}")
    lines.append(f"Segments: {r.get('segmentCount', 0)}")

    if r.get('style'):
        s = r['style']
        lines.append(f"\nStyle: {s.get('name', 'Custom')}")
        lines.append(f"  Font: {s.get('font', '?')} {s.get('fontSize', '?')}pt")
        lines.append(f"  Position: {s.get('position', '?')}")
        lines.append(f"  Animation: {s.get('animation', 'none')}")
        lines.append(f"  Word highlight: {s.get('wordByWordHighlight', False)}")

    if r.get('segments'):
        lines.append(f"\nSegments ({len(r['segments'])}):")
        for seg in r['segments'][:20]:
            lines.append(f"  [{seg['index']:3d}] {seg['startTime']:.2f}s - "
                         f"{seg['endTime']:.2f}s \"{seg['text']}\"")
        if len(r['segments']) > 20:
            lines.append(f"  ... and {len(r['segments']) - 20} more")

    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("get_caption_styles"))
def get_caption_styles() -> str:
    """List all available caption style presets.

    Returns preset IDs and their visual characteristics (font, colors, animation).
    Use set_caption_style() or generate_captions() with a preset ID to apply one.
    """
    r = bridge.call("captions.getStyles")
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Available caption styles ({r.get('count', 0)}):"]
    for s in r.get('styles', []):
        lines.append(f"\n  {s['presetID']}: \"{s['name']}\"")
        lines.append(f"    Font: {s.get('font', '?')} {s.get('fontSize', '?')}pt")
        hl = s.get('highlightColor', 'none')
        lines.append(f"    Text: {s.get('textColor', '?')}  Highlight: {hl}")
        lines.append(f"    Animation: {s.get('animation', 'none')}  Position: {s.get('position', 'bottom')}")
        lines.append(f"    Caps: {s.get('allCaps', False)}  Word highlight: {s.get('wordByWordHighlight', True)}")
    return "\n".join(lines)


@mcp.tool(annotations=_tool_annotations("set_caption_style"))
def set_caption_style(preset_id: str = "", font: str = "", font_size: float = 0,
                      text_color: str = "", highlight_color: str = "",
                      outline_color: str = "", outline_width: float = -1,
                      position: str = "", animation: str = "",
                      word_highlight: bool = True, all_caps: bool = False) -> str:
    """Set the caption style, either from a preset or with custom values.

    Args:
        preset_id: Preset name (e.g. "bold_pop", "neon_glow", "clean_minimal",
                   "karaoke", "social_bold"). Use get_caption_styles() for full list.
        font: Font family name (e.g. "Futura-Bold", "Impact", "Avenir-Heavy")
        font_size: Size in points (20-120)
        text_color: RGBA as "R G B A" (0-1 floats), e.g. "1 1 1 1" for white
        highlight_color: RGBA for active word highlight
        outline_color: RGBA for text outline/stroke
        outline_width: Stroke width (0-6)
        position: "bottom", "center", "top"
        animation: "none", "fade", "pop", "slide_up", "typewriter", "bounce"
        word_highlight: Enable word-by-word karaoke highlighting (default True)
        all_caps: Convert text to uppercase

    If preset_id is given, it's used as the base and other params override it.
    """
    params = {}
    if preset_id:
        params["presetID"] = preset_id
    if font:
        params["font"] = font
    if font_size > 0:
        params["fontSize"] = font_size
    if text_color:
        params["textColor"] = text_color
    if highlight_color:
        params["highlightColor"] = highlight_color
    if outline_color:
        params["outlineColor"] = outline_color
    if outline_width >= 0:
        params["outlineWidth"] = outline_width
    if position:
        params["position"] = position
    if animation:
        params["animation"] = animation
    params["wordByWordHighlight"] = word_highlight
    params["allCaps"] = all_caps

    r = bridge.call("captions.setStyle", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("set_caption_grouping"))
def set_caption_grouping(mode: str = "social", max_words: int = 3,
                         max_chars: int = 20, max_seconds: float = 3.0) -> str:
    """Configure how words are grouped into caption segments.

    Args:
        mode: "social" (2-3 words, 0.5s silence break — best for TikTok/Reels),
              "words" (by word count), "sentence" (by punctuation),
              "time" (by duration), "chars" (by character count)
        max_words: Max words per segment (when mode="words", default 3)
        max_chars: Max characters per segment (when mode="chars", default 20)
        max_seconds: Max duration per segment (when mode="time", default 3.0)
    """
    r = bridge.call("captions.setGrouping",
                    mode=mode, maxWords=max_words,
                    maxChars=max_chars, maxSeconds=max_seconds)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("generate_captions"))
def generate_captions(style: str = "", position: str = "center",
                      animation: str = "pop", word_highlight: bool = True,
                      max_words: int = 3, all_caps: bool = True) -> str:
    """Generate social-media-style captions and add them to the USER's timeline.

    One-shot tool: uses the current transcription (or existing words),
    applies the style, generates FCPXML title clips, imports them into a
    temp project, then copies and pastes them as a connected storyline
    onto the user's actual timeline. The temp project is deleted after.

    Position offset (bottom/center/top) is applied via ObjC transform
    after paste, not via FCPXML adjust-transform (which breaks with
    Motion templates).

    After insertion, the pipeline self-verifies by inspecting the first
    title's text channel — returns verified text, font size, and font
    family in the response.

    Requires words to be loaded first via open_captions() or set_caption_words().

    Args:
        style: Preset ID (e.g. "bold_pop", "social_bold"). Empty = current style.
        position: "bottom", "center", "top"
        animation: "none", "fade", "pop", "slide_up", "typewriter", "bounce"
        word_highlight: Word-by-word karaoke highlighting (default True)
        max_words: Max words per caption segment (default 3)
        all_caps: Convert text to uppercase

    Returns the number of caption clips generated, import status,
    and self-verification results (text, fontSize, fontFamily).
    """
    params = {}
    if style:
        params["style"] = style
    params["position"] = position
    params["animation"] = animation
    params["wordByWordHighlight"] = word_highlight
    params["maxWords"] = max_words
    params["allCaps"] = all_caps

    r = bridge.call("captions.generate", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("export_captions_srt"))
def export_captions_srt(path: str) -> str:
    """Export the current captions as an SRT subtitle file.

    Args:
        path: Output file path (e.g. "/Users/you/Desktop/captions.srt")

    Requires captions to have been transcribed first.
    """
    r = bridge.call("captions.exportSRT", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("export_captions_txt"))
def export_captions_txt(path: str) -> str:
    """Export the current captions as plain text.

    Args:
        path: Output file path (e.g. "/Users/you/Desktop/captions.txt")
    """
    r = bridge.call("captions.exportTXT", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("set_caption_words"))
def set_caption_words(words: str) -> str:
    """Manually set caption words with timing (bypasses transcription).

    Args:
        words: JSON array of word objects, each with:
            {"text": "hello", "startTime": 1.5, "duration": 0.3}

    Use this when you already have word-level timing (e.g. from an SRT file
    or external transcription service).

    Example:
        set_caption_words('[
            {"text": "Hello", "startTime": 0.5, "duration": 0.3},
            {"text": "world", "startTime": 0.9, "duration": 0.4}
        ]')
    """
    try:
        word_list = json.loads(words)
    except json.JSONDecodeError as e:
        return f"Invalid JSON: {e}"

    r = bridge.call("captions.setWords", words=word_list)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("generate_native_captions"))
def generate_native_captions(grouping: str = "word", language: str = "en",
                              max_words: int = 1, max_seconds: float = 3.0,
                              format: str = "ITT") -> str:
    """Generate native FCP captions (FFAnchoredCaption) with word-level timing.

    Unlike generate_captions() which creates styled Motion title clips for
    social media, this creates FCP's native caption/subtitle objects that
    appear in the dedicated caption lane. These are real captions — editable
    in FCP's caption editor and exportable as ITT/SRT/SCC files.

    The key feature: words appear one at a time (one caption per word),
    using precise word-level timing from Parakeet transcription.

    Requires words to be loaded first via open_captions() or set_caption_words().

    Args:
        grouping: How to group words into captions.
                  "word" - one caption per word (default, words appear one at a time)
                  "phrase" or "sentence" - one caption per sentence
                  "group:N" - N words per caption (e.g. "group:3")
                  "time:S" - max S seconds per caption (e.g. "time:2.0")
                  "social" - 2-3 words, break on pauses (TikTok/Reels style)
        language: Language identifier (e.g. "en", "en-US", "fr")
        max_words: Override max words per caption (when grouping="word" or "group:N")
        max_seconds: Override max duration per caption (when grouping="time:S")
        format: Caption format - "ITT" (default), "SRT", or "CEA608"

    Returns the number of native captions created and their placement status.
    """
    params = {
        "grouping": grouping,
        "language": language,
        "maxWords": max_words,
        "maxSeconds": max_seconds,
        "format": format,
    }
    r = bridge.call("nativeCaptions.generate", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("verify_native_captions"))
def verify_native_captions() -> str:
    """Verify native captions on the current timeline.

    Walks the timeline's caption lane and reports all FFAnchoredCaption
    objects found — their text, display names, and count. Use after
    generate_native_captions() to confirm captions were placed correctly.
    """
    r = bridge.call("nativeCaptions.verify")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ── Lua Scripting ────────────────────────────────────────────────────────────


@mcp.tool(annotations=_tool_annotations("lua_execute"))
def lua_execute(code: str) -> str:
    """Execute Lua code in SpliceKit's embedded Lua 5.4 VM running inside FCP.

    The VM is persistent — variables and state survive between calls.
    Use the `sk` module for FCP operations:
      sk.blade(), sk.clips(), sk.seek(5.0), sk.rpc("method", {params}), etc.

    Returns output (from print()), result (last expression value), and any error.

    Examples:
      lua_execute("sk.blade()")
      lua_execute("local clips = sk.clips(); return #clips")
      lua_execute("for i=1,5 do sk.next_frame() end")
      lua_execute("x = 42")  -- persists: lua_execute("return x") → 42
    """
    r = bridge.call("lua.execute", code=code)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    parts = []
    if r.get("output"):
        parts.append(r["output"].rstrip())
    if r.get("result"):
        parts.append(f"→ {r['result']}")
    if r.get("error"):
        parts.append(f"Error: {r['error']}")
    return "\n".join(parts) if parts else "ok"


@mcp.tool(annotations=_tool_annotations("lua_execute_file"))
def lua_execute_file(path: str) -> str:
    """Execute a Lua script file in SpliceKit's VM.

    Path can be absolute or relative to ~/Library/Application Support/SpliceKit/lua/.

    Examples:
      lua_execute_file("examples/blade_every_n_seconds.lua")
      lua_execute_file("/tmp/my_script.lua")
    """
    r = bridge.call("lua.executeFile", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    parts = []
    if r.get("output"):
        parts.append(r["output"].rstrip())
    if r.get("result"):
        parts.append(f"→ {r['result']}")
    if r.get("error"):
        parts.append(f"Error: {r['error']}")
    return "\n".join(parts) if parts else "ok"


@mcp.tool(annotations=_tool_annotations("lua_reset"))
def lua_reset() -> str:
    """Reset the Lua VM. All state (variables, loaded modules) is cleared and the sk module is re-registered."""
    r = bridge.call("lua.reset")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Lua VM reset"


@mcp.tool(annotations=_tool_annotations("lua_watch"))
def lua_watch(action: str = "list", path: str = "") -> str:
    """Manage Lua file watching for live coding.

    Actions:
      list   — show watched directories
      add    — watch a directory (files in auto/ subdirs execute on save)
      remove — stop watching a directory

    The default watched directory is ~/Library/Application Support/SpliceKit/lua/.
    Save .lua files to the auto/ subdirectory and they execute automatically on every save.
    """
    r = bridge.call("lua.watch", action=action, path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool(annotations=_tool_annotations("lua_state"))
def lua_state() -> str:
    """Get Lua VM state: memory usage, user-defined globals, watched paths, scripts directory."""
    r = bridge.call("lua.getState")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Plugin System
# ============================================================
# Plugins can register JSON-RPC methods that become available as
# MCP tools automatically. The plugin.listMethods endpoint returns
# all registered plugin methods with metadata.


@mcp.tool(annotations=_tool_annotations("plugin_list"))
def plugin_list() -> str:
    """List all loaded SpliceKit plugins with their manifests."""
    return _call_or_error("plugin.list")


@mcp.tool(annotations=_tool_annotations("plugin_list_methods"))
def plugin_list_methods() -> str:
    """List all registered plugin methods with descriptions and parameter schemas."""
    return _call_or_error("plugin.listMethods")


def _register_plugin_tools():
    """Query SpliceKit for registered plugin methods and create MCP tools dynamically.

    Called at module load time. If FCP isn't running yet, this silently skips —
    plugin methods can still be called through the raw_call tool. Use
    reload_plugin_tools() to refresh after FCP launches or plugins change.
    """
    try:
        r = bridge.call("plugin.listMethods")
        if _err(r) or "methods" not in r:
            return 0
        count = 0
        for m in r["methods"]:
            method_name = m.get("name")
            if not method_name:
                continue

            # Build a safe tool name: com.example.plugin.greet -> com_example_plugin_greet
            tool_name = "plugin_" + method_name.replace(".", "_")
            description = m.get("description", f"Plugin method: {method_name}")
            plugin_name = m.get("pluginId", "")
            short_name = m.get("shortName", method_name)
            read_only = m.get("readOnly", False)

            # Create a closure that captures the method name
            def make_handler(mn):
                def handler(params: str = "{}") -> str:
                    try:
                        p = json.loads(params)
                    except json.JSONDecodeError as e:
                        return f"Invalid JSON params: {e}"
                    r = bridge.call(mn, **p)
                    if _err(r):
                        return f"Error: {r.get('error', r)}"
                    return _fmt(r)
                handler.__name__ = tool_name
                handler.__doc__ = description
                return handler

            annotations = dict(READ_ONLY if read_only else LOCAL_WRITE)
            title = f"{plugin_name}: {short_name}" if plugin_name else short_name
            annotations["title"] = title
            mcp.tool(annotations=annotations)(make_handler(method_name))
            count += 1
        return count
    except Exception:
        return 0  # FCP not running yet — no plugin tools to register


# Register plugin tools at startup (best-effort)
_plugin_tool_count = _register_plugin_tools()


@mcp.tool(annotations=_tool_annotations("reload_plugin_tools"))
def reload_plugin_tools() -> str:
    """Reload plugin tools from SpliceKit.

    Call this after FCP launches or after installing new plugins to make their
    methods available as MCP tools. Note: tools registered in a previous call
    remain available — this adds any newly registered plugin methods.
    """
    count = _register_plugin_tools()
    return json.dumps({"registered": count, "status": "ok"})


# ============================================================
# MCP Resources
# ============================================================
# Read-only contextual data that models can pre-load before
# acting. Cheaper than tool calls — no side effects, cacheable.


@mcp.resource("splicekit://project/info",
              name="Project Info",
              description="Current project name, library, event, timeline state, version, and library status",
              mime_type="application/json")
def resource_project_info() -> str:
    """Return project-level context: what's loaded, library name, version, library status."""
    r = bridge.call("system.version")
    version_info = r if not _err(r) else {}

    r2 = bridge.call("timeline.getState")
    timeline_state = r2 if not _err(r2) else {}

    r3 = bridge.call("playback.getPosition")
    playhead = r3 if not _err(r3) else {}

    r4 = bridge.call("system.callMethodWithArgs", target="FFLibraryDocument",
                      selector="copyActiveLibraries", args=[], classMethod=True, returnHandle=True)
    libraries = r4 if not _err(r4) else {}

    r5 = bridge.call("system.callMethod", className="FFLibraryDocument",
                      selector="isAnyLibraryUpdating", classMethod=True)
    updating = r5 if not _err(r5) else {}

    return json.dumps({
        "splicekit": version_info,
        "timeline": timeline_state,
        "playhead": playhead,
        "libraries": libraries,
        "isLibraryUpdating": updating,
    }, indent=2, default=str)


@mcp.resource("splicekit://timeline/clips",
              name="Timeline Clips",
              description="All clips on the active timeline with handles, durations, types, and track positions",
              mime_type="application/json")
def resource_timeline_clips() -> str:
    """Return the full clip list for the active timeline."""
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    return json.dumps(r, indent=2, default=str)


@mcp.resource("splicekit://timeline/markers",
              name="Timeline Markers",
              description="All markers in the active timeline with type, position, name, and notes",
              mime_type="application/json")
def resource_timeline_markers() -> str:
    """Return all markers from the active timeline."""
    r = bridge.call("timeline.getState")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    markers = r.get("markers", [])
    return json.dumps({"markers": markers, "count": len(markers)}, indent=2, default=str)


@mcp.resource("splicekit://effects/available",
              name="Available Effects",
              description="All installed video effects, generators, titles, and audio effects",
              mime_type="application/json")
def resource_available_effects() -> str:
    """Return all available effects from FCP."""
    r = bridge.call("effects.listAvailable", type="all")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    return json.dumps(r, indent=2, default=str)


@mcp.resource("splicekit://transitions/available",
              name="Available Transitions",
              description="All installed video transitions with names, effect IDs, and categories",
              mime_type="application/json")
def resource_available_transitions() -> str:
    """Return all available transitions from FCP."""
    r = bridge.call("transitions.list")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    return json.dumps(r, indent=2, default=str)


@mcp.resource("splicekit://timeline/selected-clips",
              name="Selected Clips",
              description="Currently selected clips in the timeline with handles, durations, and properties",
              mime_type="application/json")
def resource_selected_clips() -> str:
    """Return only the currently selected clips."""
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    items = [i for i in r.get("items", []) if i.get("selected")]
    return json.dumps({"selectedCount": len(items), "items": items}, indent=2, default=str)


@mcp.resource("splicekit://timeline/analysis",
              name="Timeline Analysis",
              description="Timeline statistics: clip count, duration, pacing, potential issues (flash frames, long clips)",
              mime_type="application/json")
def resource_timeline_analysis() -> str:
    """Return timeline analysis: pacing stats, potential issues, structure."""
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})

    items = r.get("items", [])
    total_dur = r.get("duration", {}).get("seconds", 0)
    playhead = r.get("playheadTime", {}).get("seconds", 0)

    clips = [i for i in items if "Transition" not in i.get("class", "")]
    transitions = [i for i in items if "Transition" in i.get("class", "")]
    durations = [i.get("duration", {}).get("seconds", 0) for i in clips]

    short_clips = [i for i in clips if i.get("duration", {}).get("seconds", 0) < 0.5]
    long_clips = [i for i in clips if i.get("duration", {}).get("seconds", 0) > 30]

    avg_dur = sum(durations) / len(durations) if durations else 0
    min_dur = min(durations) if durations else 0
    max_dur = max(durations) if durations else 0

    pacing = "unknown"
    if len(durations) >= 4:
        q = len(durations) // 4
        q1_avg = sum(durations[:q]) / q if q else 0
        q4_avg = sum(durations[-q:]) / q if q else 0
        if q4_avg < q1_avg * 0.7:
            pacing = "accelerating"
        elif q4_avg > q1_avg * 1.3:
            pacing = "decelerating"
        else:
            pacing = "steady"

    issues = []
    if short_clips:
        issues.append(f"{len(short_clips)} flash frames (< 0.5s)")
    if long_clips:
        issues.append(f"{len(long_clips)} long clips (> 30s)")

    return json.dumps({
        "sequenceName": r.get("sequenceName", "?"),
        "durationSeconds": round(total_dur, 2),
        "playheadSeconds": round(playhead, 2),
        "clipCount": len(clips),
        "transitionCount": len(transitions),
        "avgClipDuration": round(avg_dur, 2),
        "minClipDuration": round(min_dur, 2),
        "maxClipDuration": round(max_dur, 2),
        "pacing": pacing,
        "issues": issues,
    }, indent=2, default=str)


@mcp.resource("splicekit://clips/applied-effects",
              name="Applied Effects",
              description="Effects currently applied to the selected clip, with names, IDs, and handles",
              mime_type="application/json")
def resource_applied_effects() -> str:
    """Return effects applied to the current/selected clip."""
    r = bridge.call("effects.getClipEffects")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    return json.dumps(r, indent=2, default=str)


@mcp.resource("splicekit://browser/clips",
              name="Browser Clips",
              description="Clips available in the FCP browser/media library with names, durations, and handles",
              mime_type="application/json")
def resource_browser_clips() -> str:
    """Return clips from the active library's browser."""
    r = bridge.call("browser.listClips")
    if _err(r):
        return json.dumps({"error": r.get("error", str(r))})
    return json.dumps(r, indent=2, default=str)


@mcp.resource("splicekit://config/instructions",
              name="Editing Instructions",
              description="Operating rules, workflow guidance, and best practices for AI-driven FCP editing",
              mime_type="text/markdown")
def resource_instructions() -> str:
    """Workflow guidance and operating rules for models using SpliceKit.

    This teaches the model how to use SpliceKit properly regardless of
    whether CLAUDE.md is in context.
    """
    return """# SpliceKit Operating Instructions

## Golden Rules
1. **NEVER use keyboard simulation or AppleScript.** All actions go through direct ObjC calls via the bridge.
2. **Discover before editing.** Call get_timeline_clips() or read splicekit://timeline/clips before making changes.
3. **Select before acting.** Color correction, effects, retiming, and titles require a clip to be selected first.
4. **Verify after editing.** Use verify_action(), capture_timeline(), or capture_viewer() to confirm results.
5. **Prefer non-destructive workflows.** Use undo via timeline_action("undo") if something goes wrong.

## Standard Workflow
1. bridge_status() — verify FCP is connected
2. open_project("Name") — load a project
3. get_timeline_clips() — see timeline contents
4. Position playhead → select clip → apply action
5. verify_action() — confirm the edit took effect
6. capture_timeline() / capture_viewer() — visual verification

## Selection Pattern
```
playback_action("goToStart")
timeline_action("selectClipAtPlayhead")   # select primary storyline clip
timeline_action("addColorBoard")          # now apply effect/correction
```

For connected clips (B-roll, titles): use select_clip_in_lane(lane=1) for above, lane=-1 for below.

## Playhead Positioning
- 1 frame = ~0.042s at 24fps, ~0.033s at 30fps
- Use seekToTime(seconds) for precise positioning
- Use batch_timeline_actions() for multi-step navigation + edit sequences
- Avoid frame-stepping loops when seekToTime exists

## Batch Operations
Use batch_timeline_actions() for multi-step sequences rather than individual tool calls.
Use apply_transition_to_all_clips() to add transitions at every edit point at once.
Use blade_at_times() to cut at multiple timecodes in one call.
Use add_markers_at_times() to place markers at multiple positions.

## FCPXML for Complex Edits
For creating entire projects with precise timing, gaps, titles, and markers:
```
xml = generate_fcpxml(items='[{"type":"gap","duration":5},{"type":"title","text":"Hello","duration":3}]')
import_fcpxml(xml, internal=True)
```

## Timeline Data Model
FCP uses a spine model: sequence → primaryObject (collection) → items.
Items are FFAnchoredMediaComponent (clips), FFAnchoredTransition, etc.
get_timeline_clips() returns handles for each item — use handles in subsequent calls.

## Error Recovery
- timeline_action("undo") to reverse the last edit
- manage_handles(action="release_all") to clean up leaked object handles
- bridge_status() to check if the connection is still alive
"""


# ============================================================
# MCP Prompts
# ============================================================
# Workflow templates for common editing scenarios. Each prompt
# provides role context, step-by-step guidance, and attaches
# the instructions resource for operating rules.


@mcp.prompt(name="edit_podcast",
            description="Multi-participant podcast editing: silence removal, leveling, chapter markers")
def prompt_edit_podcast(episode_name: str = "", participants: str = "") -> str:
    """Guide for editing a podcast episode in FCP."""
    return f"""You are an expert podcast editor working in Final Cut Pro via SpliceKit.

Task: Edit the podcast episode{f' "{episode_name}"' if episode_name else ''}{f' with participants: {participants}' if participants else ''}.

## Workflow
1. **Setup**: Open the project and review the timeline with get_timeline_clips()
2. **Silence removal**: Use detect_scene_changes() to find dead air, then blade_at_times() to cut silent sections
3. **Audio leveling**: Check levels across participants — use timeline_action("adjustVolumeUp/Down") to balance
4. **Cleanup**: Remove filler words, long pauses, and false starts by selecting and deleting clips
5. **Chapter markers**: Add chapter markers at topic transitions using timeline_action("addChapterMarker")
6. **Transitions**: Add cross dissolves between segments with apply_transition_to_all_clips() or individual apply_transition()
7. **Export**: Use generate_fcpxml() to export, or share_project() for direct export

## Tips
- Use capture_timeline() frequently to verify your edits visually
- Use batch_timeline_actions() for efficient multi-step editing
- Silence detection threshold can be tuned with set_silence_threshold()
"""


@mcp.prompt(name="edit_music_video",
            description="Beat-synced music video editing with scene detection and montage assembly")
def prompt_edit_music_video(song_name: str = "", style: str = "bar") -> str:
    """Guide for editing a music video synced to beats."""
    return f"""You are an expert music video editor working in Final Cut Pro via SpliceKit.

Task: Edit a music video{f' for "{song_name}"' if song_name else ''} with cuts synced to the music.

## Workflow
1. **Analyze music**: Use detect_beats() to find beat positions, then analyze_song_structure() for sections
2. **Score clips**: Use montage_analyze_clips() to rank available footage
3. **Plan the edit**: Use montage_plan_edit() with style="{style}" to map clips to musical segments
4. **Assemble**: Use montage_assemble() to build the timeline, or montage_auto() for one-shot creation
5. **Refine**: Review with capture_viewer(), adjust individual clips, add effects
6. **Transitions**: Add transitions at cut points — apply_transition_to_all_clips() for uniform look, or individual apply_transition() for variety
7. **Color**: Select clips and apply color correction with timeline_action("addColorBoard") or timeline_action("addColorCurves")

## Beat Sync Tips
- "beat" style cuts on every beat (fast, energetic)
- "bar" style cuts on every measure (balanced, standard)
- "section" style cuts on verse/chorus boundaries (cinematic, slower)
- Use blade_at_times() to manually cut at specific beat positions
"""


@mcp.prompt(name="social_media_reformat",
            description="Reformat a timeline for social media: aspect ratio, captions, pacing")
def prompt_social_media(platform: str = "instagram", source_project: str = "") -> str:
    """Guide for reformatting content for social media platforms."""
    specs = {
        "instagram": {"aspect": "9:16 (1080x1920)", "duration": "15-60s", "captions": True},
        "tiktok": {"aspect": "9:16 (1080x1920)", "duration": "15-60s", "captions": True},
        "youtube_shorts": {"aspect": "9:16 (1080x1920)", "duration": "up to 60s", "captions": True},
        "youtube": {"aspect": "16:9 (1920x1080)", "duration": "any", "captions": True},
        "twitter": {"aspect": "16:9 or 1:1", "duration": "up to 2:20", "captions": True},
    }
    spec = specs.get(platform, specs["instagram"])

    return f"""You are a social media content editor working in Final Cut Pro via SpliceKit.

Task: Reformat{f' "{source_project}"' if source_project else ' the current project'} for {platform}.

## Target Specs
- Aspect ratio: {spec['aspect']}
- Duration: {spec['duration']}
- Captions: {'Required for accessibility' if spec['captions'] else 'Optional'}

## Workflow
1. **Review source**: get_timeline_clips() to understand the current edit
2. **Trim for length**: Identify the strongest {spec['duration']} segment — blade and remove excess
3. **Add captions**: Use open_transcript() to transcribe, then generate_captions() for subtitles
4. **Style captions**: Use set_caption_style() and set_caption_grouping() for platform-appropriate look
5. **Pacing**: Tighten cuts — social content needs faster pacing than long-form
6. **Visual polish**: Add effects, color correction, titles as needed
7. **Export**: share_project() or generate FCPXML

## Social Media Tips
- Front-load the hook in the first 3 seconds
- Captions are essential — most viewers watch without sound
- Use generate_social_captions() for word-by-word highlighting style
- Keep text and key visuals in the center safe zone for 9:16
"""


@mcp.prompt(name="color_grade",
            description="Color grading workflow: correction, look development, consistency")
def prompt_color_grade(look: str = "", mood: str = "") -> str:
    """Guide for color grading a project in FCP."""
    return f"""You are a professional colorist working in Final Cut Pro via SpliceKit.

Task: Color grade the current project{f' with a {look} look' if look else ''}{f' for a {mood} mood' if mood else ''}.

## Workflow
1. **Review**: get_timeline_clips() and capture_viewer() to assess current color state
2. **Primary correction** (per clip):
   - Select clip: timeline_action("selectClipAtPlayhead")
   - Add Color Board: timeline_action("addColorBoard") for basic lift/gamma/gain
   - Or Color Wheels: timeline_action("addColorWheels") for more control
   - Or Color Curves: timeline_action("addColorCurves") for precise curve adjustments
3. **Look development**: Use timeline_action("addHueSaturation") for selective color shifts
4. **Consistency**: Apply the same correction across similar clips using copy/paste attributes
5. **Verify**: capture_viewer() after each correction to check the result

## Color Tools Available
- addColorBoard — basic 3-way (global, shadows, midtones, highlights)
- addColorWheels — lift/gamma/gain wheels
- addColorCurves — RGB curves
- addColorAdjustment — exposure, saturation, black point
- addHueSaturation — selective hue shifts
- addEnhanceLightAndColor — FCP's auto enhancement
- balanceColor — automatic white balance
- matchColor — match color between clips

## Tips
- Always correct exposure/white balance first, then add creative looks
- Use capture_viewer() frequently to compare before/after
- Work clip-by-clip for narrative, or batch for documentary/event
"""


@mcp.prompt(name="rough_cut_assembly",
            description="Assemble a rough cut from clips: import, arrange, basic transitions")
def prompt_rough_cut(project_name: str = "", clip_folder: str = "") -> str:
    """Guide for assembling a rough cut from raw footage."""
    return f"""You are an assistant editor assembling a rough cut in Final Cut Pro via SpliceKit.

Task: Build a rough cut{f' for "{project_name}"' if project_name else ''}{f' from clips in {clip_folder}' if clip_folder else ''}.

## Workflow
1. **Review footage**: get_timeline_clips() to see what's in the timeline, or montage_analyze_clips() to score available clips
2. **Arrange clips**: Use the montage tools for automated assembly, or manually:
   - Position playhead where you want to place each clip
   - Use FCPXML for precise placement: generate_fcpxml() + import_fcpxml()
3. **Rough ordering**: Get the story structure right before fine-tuning
4. **Basic transitions**: apply_transition_to_all_clips() for uniform cross dissolves, or apply_transition() at specific cuts
5. **Timing**: Adjust clip durations, add gaps for pacing
6. **Review**: capture_timeline() for layout overview, capture_viewer() for content check

## Assembly Tips
- Start with the strongest clips, fill in secondary footage later
- Don't worry about perfect timing in a rough cut — focus on story order
- Use markers (timeline_action("addMarker")) to flag sections needing attention
- Use todo markers (timeline_action("addTodoMarker")) for notes on missing content
"""


@mcp.prompt(name="caption_workflow",
            description="Full captioning pipeline: transcribe, generate, style, and export captions")
def prompt_caption_workflow(language: str = "en", export_format: str = "srt") -> str:
    """Guide for the complete captioning workflow."""
    return f"""You are a captioning specialist working in Final Cut Pro via SpliceKit.

Task: Create captions for the current timeline in {language}, export as {export_format.upper()}.

## Workflow
1. **Transcribe**: open_transcript() to start the Parakeet speech-to-text engine
2. **Review transcript**: get_transcript() to read the text, search_transcript() to find specific words
3. **Clean up**: delete_transcript_words() to remove filler, move_transcript_words() to fix ordering
4. **Remove silence**: delete_transcript_silences() to clean dead air (tune with set_silence_threshold())
5. **Generate captions**: generate_captions() to create subtitle track from transcript
6. **Style**: set_caption_style() for font, size, position; set_caption_grouping() for line breaks
7. **Verify**: verify_captions() to check timing and content, capture_viewer() to see visual result
8. **Export**: export_captions_srt() for SRT or export_captions_txt() for plain text

## Caption Tips
- Use generate_social_captions() for word-by-word highlighting (TikTok/Reels style)
- Parakeet v3 supports multilingual transcription
- SRT is universal; use it for YouTube, Vimeo, social platforms
- Always verify_captions() before export to catch timing issues
"""


@mcp.prompt(name="documentary_editing",
            description="Documentary editing: interview structure, B-roll, narrative pacing")
def prompt_documentary(topic: str = "") -> str:
    """Guide for documentary-style editing."""
    return f"""You are a documentary editor working in Final Cut Pro via SpliceKit.

Task: Edit a documentary{f' about "{topic}"' if topic else ''}.

## Workflow
1. **Organize**: Review all clips with get_timeline_clips(), use markers to tag key moments
2. **Structure**: Build the narrative arc — establish the story spine with interview clips
3. **Transcribe**: Use open_transcript() + get_transcript() to find the best soundbites
4. **Assemble**: Place interview clips in story order using FCPXML or montage tools
5. **B-roll**: Layer supporting footage above the primary storyline:
   - select_clip_in_lane(lane=1) to work with connected clips
   - Use blade_at_times() to trim B-roll to match interview pacing
6. **Transitions**: Add dissolves at section breaks, hard cuts within scenes
7. **Audio**: Balance interview audio, add ambient sound, music bed
8. **Captions**: Full caption workflow for accessibility
9. **Review**: capture_viewer() and capture_timeline() throughout

## Documentary Tips
- Let interviews drive the structure, B-roll supports the narrative
- Use chapter markers (timeline_action("addChapterMarker")) at major sections
- Use todo markers for sections needing pickup shots or additional footage
- Color correct interviews for consistency, grade B-roll for mood
"""


# ============================================================
# Batch Effect & Color Tools
# ============================================================
# Apply effects or corrections to multiple clips in one call,
# reducing round-trips for common bulk operations.


@mcp.tool(annotations=_tool_annotations("batch_apply_effect"))
def batch_apply_effect(name: str = "", effectID: str = "", clip_count: int = 0) -> str:
    """Apply the same effect to multiple clips sequentially.

    Selects each clip at the playhead, applies the effect, then moves
    to the next edit point. Starts from the current playhead position.

    Args:
        name: Display name of the effect (e.g. "Gaussian Blur").
        effectID: The effect ID string (alternative to name).
        clip_count: Number of clips to process (0 = all clips from playhead to end).

    Select the starting clip first, or position the playhead at the first clip.
    """
    if not name and not effectID:
        return "Error: provide either name or effectID"

    results = []
    applied = 0
    errors = 0
    i = 0

    # Select clip at current position
    r = bridge.call("timeline.action", action="selectClipAtPlayhead")
    if _err(r):
        return f"Error selecting initial clip: {r.get('error', r)}"

    while clip_count == 0 or i < clip_count:
        # Apply effect to current selection
        params = {}
        if effectID:
            params["effectID"] = effectID
        if name:
            params["name"] = name
        r = bridge.call("effects.apply", **params)
        if _err(r):
            errors += 1
            results.append({"clip": i, "success": False, "error": r.get("error", str(r))})
        else:
            applied += 1
            results.append({"clip": i, "success": True, "effect": r.get("effect", "?")})

        i += 1

        # Move to next edit and select
        r = bridge.call("timeline.action", action="nextEdit")
        if _err(r):
            break  # No more edit points
        r = bridge.call("timeline.action", action="selectClipAtPlayhead")
        if _err(r):
            break  # No clip at this position

    return json.dumps({
        "applied": applied,
        "errors": errors,
        "total": i,
        "results": results,
    }, indent=2, default=str)


@mcp.tool(annotations=_tool_annotations("batch_color_correct"))
def batch_color_correct(correction: str = "addColorBoard", clip_count: int = 0) -> str:
    """Apply the same color correction to multiple clips sequentially.

    Selects each clip at the playhead, applies the correction, then moves
    to the next edit point. Starts from the current playhead position.

    Args:
        correction: The color correction action. One of:
            "addColorBoard", "addColorWheels", "addColorCurves",
            "addColorAdjustment", "addHueSaturation",
            "addEnhanceLightAndColor", "balanceColor", "matchColor"
        clip_count: Number of clips to process (0 = all clips from playhead to end).
    """
    valid_corrections = {
        "addColorBoard", "addColorWheels", "addColorCurves",
        "addColorAdjustment", "addHueSaturation",
        "addEnhanceLightAndColor", "balanceColor", "matchColor",
    }
    if correction not in valid_corrections:
        return f"Error: correction must be one of: {', '.join(sorted(valid_corrections))}"

    results = []
    applied = 0
    errors = 0
    i = 0

    r = bridge.call("timeline.action", action="selectClipAtPlayhead")
    if _err(r):
        return f"Error selecting initial clip: {r.get('error', r)}"

    while clip_count == 0 or i < clip_count:
        r = bridge.call("timeline.action", action=correction)
        if _err(r):
            errors += 1
            results.append({"clip": i, "success": False, "error": r.get("error", str(r))})
        else:
            applied += 1
            results.append({"clip": i, "success": True, "correction": correction})

        i += 1

        r = bridge.call("timeline.action", action="nextEdit")
        if _err(r):
            break
        r = bridge.call("timeline.action", action="selectClipAtPlayhead")
        if _err(r):
            break

    return json.dumps({
        "applied": applied,
        "errors": errors,
        "total": i,
        "correction": correction,
        "results": results,
    }, indent=2, default=str)


# MCP servers communicate over stdio -- the AI tool framework handles the transport
if __name__ == "__main__":
    mcp.run(transport="stdio")
