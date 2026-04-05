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
2. get_timeline_clips() -- see what's in the timeline (items, handles, durations)
3. Perform actions using timeline_action() and playback_action()
4. verify_action() -- confirm the edit took effect by comparing state snapshots

## IMPORTANT: Opening a Project
If get_timeline_clips() shows 0 items, you need to load a project into the timeline:
  1. call_method_with_args("FFLibraryDocument", "copyActiveLibraries", return_handle=True)
  2. Navigate: array -> library -> _deepLoadedSequences -> allObjects
  3. Find a sequence with hasContainedItems == true
  4. Get editor container via NSApp -> delegate -> activeEditorContainer
  5. Call loadEditorForSequence: on the container with the sequence handle

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
Keyframes: addKeyframe, deleteKeyframes, nextKeyframe, previousKeyframe
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
"""
)


class BridgeConnection:
    """Persistent TCP connection to the SpliceKit JSON-RPC server inside FCP.

    Keeps the socket open between calls so we don't pay the connect overhead
    on every tool invocation. Auto-reconnects if the connection drops (FCP
    restarted, socket timed out, etc).
    """

    def __init__(self):
        self.sock = None
        self._buf = b""
        self._id = 0

    def ensure_connected(self):
        if self.sock is None:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sock.settimeout(30)
            self.sock.connect((SPLICEKIT_HOST, SPLICEKIT_PORT))
            self._buf = b""

    def call(self, method: str, **params) -> dict:
        """Send a JSON-RPC request and wait for the response.

        Returns the result dict on success, or {"error": "..."} on failure.
        Handles connection errors gracefully — the next call will auto-reconnect.
        """
        try:
            self.ensure_connected()
        except (ConnectionRefusedError, OSError) as e:
            return {"error": f"Cannot connect to SpliceKit at {SPLICEKIT_HOST}:{SPLICEKIT_PORT}. "
                    f"Is the modded FCP running? Error: {e}"}

        self._id += 1
        req = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": self._id})
        try:
            self.sock.sendall(req.encode() + b"\n")
            # Read until we get a complete line (newline-delimited JSON)
            while b"\n" not in self._buf:
                chunk = self.sock.recv(16777216)  # 16MB — FCPXML responses can be large
                if not chunk:
                    self.sock = None
                    return {"error": "Connection closed by SpliceKit"}
                self._buf += chunk
            line, self._buf = self._buf.split(b"\n", 1)
            resp = json.loads(line)
            if "error" in resp:
                return {"error": resp["error"]}
            return resp.get("result", {})
        except Exception as e:
            self.sock = None
            return {"error": f"Bridge communication error: {e}"}


bridge = BridgeConnection()


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


# ============================================================
# Core Connection & Status
# ============================================================
# The first thing any client should do is call bridge_status() to
# verify FCP is running and the bridge is responsive.

@mcp.tool()
def bridge_status() -> str:
    """Check if SpliceKit is running and get FCP version info."""
    r = bridge.call("system.version")
    if _err(r):
        return f"SpliceKit NOT connected: {r.get('error', r)}"  # special error message for status
    return _fmt(r)


# ============================================================
# Timeline Actions
# ============================================================
# These map directly to FCP's IBAction methods on the timeline module.
# Most require a clip to be selected first (selectClipAtPlayhead).

@mcp.tool()
def timeline_action(action: str) -> str:
    """Perform a timeline editing action via direct ObjC calls.

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
      Keyframes: addKeyframe, deleteKeyframes, nextKeyframe, previousKeyframe
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
      Audio Extra: alignAudioToVideo, volumeMute, addDefaultAudioEffect,
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


@mcp.tool()
def playback_action(action: str) -> str:
    """Control playback via responder chain.

    Actions: playPause, goToStart, goToEnd, nextFrame, prevFrame,
             nextFrame10, prevFrame10, playAroundCurrent
    """
    return _call_or_error("playback.action", action=action)


@mcp.tool()
def detect_scene_changes(threshold: float = 0.35, action: str = "detect", sample_interval: float = 0.1) -> str:
    """Detect scene changes (cuts) in the timeline media using histogram analysis.

    Args:
        threshold: Sensitivity (0.0-1.0). Lower = more sensitive. Default 0.35.
        action: "detect" (just list), "markers" (add markers at cuts), "blade" (blade at cuts)
        sample_interval: Seconds between sampled frames. Default 0.1.

    Returns list of scene change timestamps with confidence scores.
    Uses GPU-style histogram comparison (same approach as FCP internally).
    """
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


@mcp.tool()
def seek_to_time(seconds: float) -> str:
    """Move the playhead to an exact time instantly (no playback).

    Args:
        seconds: Time in seconds (e.g. 3.5 = 3 seconds 500ms)

    This is much faster than stepping frames. Use this for all
    time-based positioning before blade, marker, or other operations.
    """
    return _call_or_error("playback.seekToTime", seconds=seconds)


# ============================================================
# Timeline State (structured)
# ============================================================

@mcp.tool()
def get_timeline_clips(limit: int = 100) -> str:
    """Get structured list of all clips in the current timeline.
    Returns: sequence name, playhead time, duration, and for each item:
    index, class, name, duration (seconds), lane, mediaType, selected, handle.
    Handles can be used with get_object_property() for deeper inspection.
    """
    r = bridge.call("timeline.getDetailedState", limit=limit)
    if _err(r):
        return f"Error: {r.get('error', r)}"

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


@mcp.tool()
def get_selected_clips() -> str:
    """Get only the currently selected clips in the timeline."""
    r = bridge.call("timeline.getDetailedState")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    items = [i for i in r.get("items", []) if i.get("selected")]
    if not items:
        return "No clips selected"
    return _fmt({"selectedCount": len(items), "items": items})


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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

@mcp.tool()
def call_method_with_args(target: str, selector: str, args: str = "[]",
                          class_method: bool = True, return_handle: bool = False) -> str:
    """Call any ObjC method with typed arguments via NSInvocation.

    target: class name (e.g. "FFLibraryDocument") or handle ID (e.g. "obj_3")
    selector: method selector (e.g. "copyActiveLibraries" or "openProjectAtURL:")
    args: JSON array of typed arguments. Each arg is {"type": "...", "value": ...}
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
    """
    try:
        parsed_args = json.loads(args)
    except json.JSONDecodeError as e:
        return f"Invalid args JSON: {e}"

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

@mcp.tool()
def manage_handles(action: str = "list", handle: str = "") -> str:
    """Manage object handles stored by SpliceKit.

    Actions:
      list - show all active handles with class names
      inspect <handle> - get details about a handle
      release <handle> - release a specific handle
      release_all - release all handles
    """
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


@mcp.tool()
def get_object_property(handle: str, key: str, return_handle: bool = False) -> str:
    """Read a property from an object handle using Key-Value Coding.

    handle: object handle ID (e.g. "obj_3")
    key: property name (e.g. "displayName", "duration", "containedItems")
    return_handle: if true, store the returned value as a new handle

    Example: get_object_property("obj_3", "displayName")
    """
    r = bridge.call("object.getProperty", handle=handle, key=key, returnHandle=return_handle)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
def set_object_property(handle: str, key: str, value: str, value_type: str = "string") -> str:
    """Set a property on an object handle using Key-Value Coding.

    WARNING: Direct KVC bypasses undo. For undoable edits, use timeline_action() instead.

    handle: object handle ID
    key: property name
    value: the value to set (as string, will be converted based on value_type)
    value_type: string, int, double, bool, nil
    """
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

@mcp.tool()
def import_fcpxml(xml: str, internal: bool = True) -> str:
    """Import FCPXML into FCP. If internal=True, uses PEAppController's import method
    (imports into the running instance without restart). If internal=False, opens via NSWorkspace.
    Provide valid FCPXML as a string.
    """
    r = bridge.call("fcpxml.import", xml=xml, internal=internal)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
def generate_fcpxml(event_name: str = "SpliceKit Event", project_name: str = "SpliceKit Project",
                    frame_rate: str = "24", width: int = 1920, height: int = 1080,
                    items: str = "[]") -> str:
    """Generate valid FCPXML for import. Creates a project with clips, gaps, titles,
    transitions, and markers. Uses rational time (fractions) to avoid frame drift.

    items: JSON array of timeline items. Each item:
      {"type": "gap", "duration": 5.0}
      {"type": "gap", "duration": 5.0, "name": "My Gap"}
      {"type": "title", "text": "Hello World", "duration": 5.0}
      {"type": "title", "text": "Lower Third", "duration": 3.0, "position": "lower-third"}
      {"type": "marker", "time": 2.5, "name": "Review Here", "kind": "standard"}
      {"type": "marker", "time": 5.0, "name": "Chapter 1", "kind": "chapter"}
      {"type": "transition", "duration": 1.0}

    Returns the FCPXML string. Pass to import_fcpxml() to load into FCP.

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

    # Rational frame rate mapping (numerator/denominator for exact frame boundaries)
    fr_map = {
        "23.976": (1001, 24000), "24": (100, 2400), "25": (100, 2500),
        "29.97": (1001, 30000), "30": (100, 3000), "48": (100, 4800),
        "50": (100, 5000), "59.94": (1001, 60000), "60": (100, 6000),
    }
    fd_num, fd_den = fr_map.get(frame_rate, (100, 2400))
    fd_str = f"{fd_num}/{fd_den}s"

    def dur_rational(seconds):
        """Convert seconds to rational time string using the timebase."""
        frames = round(seconds * fd_den / fd_num)
        return f"{frames * fd_num}/{fd_den}s"

    # Separate spine items from markers
    spine_items = [i for i in item_list if i.get("type") in ("gap", "title", "transition", None)]
    markers = [i for i in item_list if i.get("type") == "marker"]

    if not spine_items:
        spine_items = [{"type": "gap", "duration": 10.0}]

    # Build spine XML - respecting DTD child ordering
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
            # DTD order: note, adjust-*, audio, video, clip, title, caption, marker, keyword, filter-*
            spine_xml += f'''            <title name="{title_name}" offset="{off_str}" duration="{dur_str}" start="3600s">
                <text><text-style ref="{ts_id}">{text}</text-style></text>
                <text-style-def id="{ts_id}"><text-style font="Helvetica" fontSize="{font_size}" fontColor="1 1 1 1"/></text-style-def>
            </title>\n'''
        elif itype == "transition":
            spine_xml += f'            <transition name="Cross Dissolve" offset="{off_str}" duration="{dur_str}"/>\n'

        offset_seconds += idur
        total_seconds += idur

    total_dur_str = dur_rational(total_seconds)

    # Build markers XML (attached to the sequence)
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

    xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>
<fcpxml version="1.11">
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

    return xml


# ============================================================
# Effects & Color Correction
# ============================================================
# Tools for inspecting and applying effects on clips.

@mcp.tool()
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

@mcp.tool()
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
    for i, act in enumerate(action_list):
        act_type = act.get("type", "timeline")
        action_name = act.get("action", "")
        repeat = act.get("repeat", 1)

        if act_type == "wait":
            secs = act.get("seconds", 0.5)
            time.sleep(secs)
            results.append(f"[{i}] wait {secs}s")
        elif act_type == "playback":
            for _ in range(repeat):
                r = bridge.call("playback.action", action=action_name)
            results.append(f"[{i}] playback.{action_name}" + (f" x{repeat}" if repeat > 1 else ""))
        elif act_type == "timeline":
            for _ in range(repeat):
                r = bridge.call("timeline.action", action=action_name)
            results.append(f"[{i}] timeline.{action_name}" + (f" x{repeat}" if repeat > 1 else ""))
        else:
            results.append(f"[{i}] unknown type: {act_type}")

    return f"Executed {len(action_list)} actions:\n" + "\n".join(results)


# ============================================================
# Timeline Analysis
# ============================================================

@mcp.tool()
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

    # Analyze clips
    clips = [i for i in items if "Transition" not in i.get("class", "")]
    transitions = [i for i in items if "Transition" in i.get("class", "")]
    durations = [i.get("duration", {}).get("seconds", 0) for i in clips]

    short_clips = [i for i in clips if i.get("duration", {}).get("seconds", 0) < 0.5]
    long_clips = [i for i in clips if i.get("duration", {}).get("seconds", 0) > 30]

    avg_dur = sum(durations) / len(durations) if durations else 0
    min_dur = min(durations) if durations else 0
    max_dur = max(durations) if durations else 0

    # Pacing analysis (quartiles)
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

@mcp.tool()
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


@mcp.tool()
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

    # Parse SRT
    blocks = re.split(r'\n\n+', srt_content.strip())
    marker_list = []

    for block in blocks:
        lines = block.strip().split('\n')
        if len(lines) < 3:
            continue

        # Parse timestamp line: 00:00:05,000 --> 00:00:10,000
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

@mcp.tool()
def get_active_libraries() -> str:
    """Get list of currently open libraries in FCP."""
    r = bridge.call("system.callMethodWithArgs", target="FFLibraryDocument",
                    selector="copyActiveLibraries", args=[], classMethod=True, returnHandle=True)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
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

@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
def get_properties(class_name: str) -> str:
    """List declared @property definitions on an ObjC class."""
    r = bridge.call("system.getProperties", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    lines = [f"{class_name}: {r.get('count', 0)} properties"]
    for p in r.get("properties", []):
        lines.append(f"  {p['name']}: {p['attributes']}")
    return "\n".join(lines)


@mcp.tool()
def get_ivars(class_name: str) -> str:
    """List instance variables of an ObjC class with their types."""
    r = bridge.call("system.getIvars", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    lines = [f"{class_name}: {r.get('count', 0)} ivars"]
    for iv in r.get("ivars", []):
        lines.append(f"  {iv['name']}: {iv['type']}")
    return "\n".join(lines)


@mcp.tool()
def get_protocols(class_name: str) -> str:
    """List protocols adopted by an ObjC class."""
    r = bridge.call("system.getProtocols", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return f"{class_name}: {r.get('count', 0)} protocols\n" + "\n".join(f"  {p}" for p in r.get("protocols", []))


@mcp.tool()
def get_superchain(class_name: str) -> str:
    """Get the inheritance chain for an ObjC class."""
    r = bridge.call("system.getSuperchain", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return " -> ".join(r.get("superchain", []))


@mcp.tool()
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
        keywords = ['get', 'set', 'current', 'active', 'selected', 'add', 'remove',
                    'create', 'delete', 'open', 'close', 'name', 'items', 'clip', 'effect', 'marker']
        notable = [m for m in sorted(r.get("instanceMethods", {}).keys()) if any(k in m.lower() for k in keywords)]
        if notable:
            lines.append(f"\nNotable instance methods ({len(notable)} of {im}):")
            for m in notable[:50]:
                lines.append(f"  - {m}")
    return "\n".join(lines)


@mcp.tool()
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


@mcp.tool()
def call_method(class_name: str, selector: str, class_method: bool = True) -> str:
    """Call a zero-argument ObjC method. For methods WITH arguments, use call_method_with_args instead."""
    r = bridge.call("system.callMethod", className=class_name, selector=selector, classMethod=class_method)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
def raw_call(method: str, params: str = "{}") -> str:
    """Send a raw JSON-RPC call to SpliceKit."""
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

@mcp.tool()
def open_transcript(file_url: str = "") -> str:
    """Open the transcript panel and start transcribing.

    If no file_url is provided, transcribes all clips on the current timeline.
    If file_url is provided, transcribes that specific audio/video file.

    The transcript panel allows text-based editing:
    - Clicking a word jumps the playhead to that time
    - Deleting words removes those segments from the timeline
    - Dragging words reorders clips on the timeline

    Transcription is async - use get_transcript() to check progress and results.
    """
    params = {}
    if file_url:
        params["fileURL"] = file_url
    r = bridge.call("transcript.open", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
def close_transcript() -> str:
    """Close the transcript panel."""
    r = bridge.call("transcript.close")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Transcript panel closed."


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
def set_silence_threshold(threshold: float) -> str:
    """Set the minimum gap duration (seconds) to detect as a silence/pause.

    Args:
        threshold: Duration in seconds. Default is 0.3 (300ms).
                   Lower values detect shorter pauses, higher values only long ones.

    The transcript must be re-transcribed for changes to take effect.
    """
    r = bridge.call("transcript.setSilenceThreshold", threshold=threshold)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Effects (video filters, generators, titles, audio)
# ============================================================

@mcp.tool()
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


@mcp.tool()
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

@mcp.tool()
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


@mcp.tool()
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


# ============================================================
# Command Palette
# ============================================================

@mcp.tool()
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


@mcp.tool()
def hide_command_palette() -> str:
    """Close the command palette."""
    r = bridge.call("command.hide")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Command palette closed."


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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

    actions = r.get("actions", [])
    if not actions:
        return "No actions determined from query."

    # Execute each action
    results = []
    for act in actions:
        act_type = act.get("type", "timeline")
        action_name = act.get("action", "")
        repeat = act.get("repeat", 1)

        for _ in range(repeat):
            er = bridge.call(f"{act_type}.action", action=action_name)
            if _err(er):
                results.append(f"Error on {act_type}.{action_name}: {er.get('error', er)}")
                break
        results.append(f"{act_type}.{action_name}" + (f" x{repeat}" if repeat > 1 else "") + " -> ok")

    return f"AI executed {len(actions)} action(s):\n" + "\n".join(results)


# ============================================================
# Menu Execute (universal menu access)
# ============================================================

@mcp.tool()
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


@mcp.tool()
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

@mcp.tool()
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


@mcp.tool()
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


# ============================================================
# View/Panel Toggles
# ============================================================

@mcp.tool()
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


@mcp.tool()
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

@mcp.tool()
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

@mcp.tool()
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
# Share/Export
# ============================================================

@mcp.tool()
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

@mcp.tool()
def create_project() -> str:
    """Open the New Project dialog in FCP."""
    r = bridge.call("project.create")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
def create_event() -> str:
    """Create a new event in the current library."""
    r = bridge.call("project.createEvent")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
def create_library() -> str:
    """Open the New Library dialog."""
    r = bridge.call("project.createLibrary")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Playhead Position & Monitoring
# ============================================================

@mcp.tool()
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

@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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

@mcp.tool()
def get_viewer_zoom() -> str:
    """Get the current viewer zoom level.

    Returns the zoom factor (0.0 = Fit, 1.0 = 100%, 2.0 = 200%, etc.),
    the reported zoom percentage, and whether the viewer is in Fit mode.
    """
    r = bridge.call("viewer.getZoom")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
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

@mcp.tool()
def get_bridge_options() -> str:
    """Get the current SpliceKit option settings.

    Returns the state of all configurable options
    (e.g. effectDragAsAdjustmentClip, viewerPinchZoom, videoOnlyKeepsAudioDisabled).
    """
    r = bridge.call("options.get")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
def set_bridge_option(option: str, enabled: bool) -> str:
    """Toggle an SpliceKit option.

    Args:
        option: Option name. Currently supported:
                "effectDragAsAdjustmentClip" - enable/disable dragging effects to empty timeline space to create adjustment clips
                "viewerPinchZoom" - enable/disable trackpad pinch-to-zoom on the viewer
                "videoOnlyKeepsAudioDisabled" - when Video-Only AV edit mode adds clips, keep audio+video but with audio disabled in inspector
        enabled: True to enable, False to disable
    """
    r = bridge.call("options.set", option=option, enabled=enabled)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Beat Detection (Any Audio File)
# ============================================================

@mcp.tool()
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
    # Run beat-detector as an external process (AVFoundation deadlocks inside FCP)
    tool_paths = [
        os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build", "beat-detector"),
        "/usr/local/bin/beat-detector",
        os.path.expanduser("~/Documents/GitHub/SpliceKit/build/beat-detector"),
    ]
    tool = None
    for p in tool_paths:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            tool = p
            break
    if not tool:
        return "Error: beat-detector tool not found. Build it with: cd SpliceKit && swiftc -O -o build/beat-detector tools/beat-detector.swift"

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
# FlexMusic (Dynamic Soundtrack)
# ============================================================

@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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

@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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

@mcp.tool()
def debug_get_config() -> str:
    """Get current state of all FCP internal debug/logging settings.

    Returns the current values of:
    - Timeline debug flags (TLK*): visual overlays, logging, performance monitors
    - CFPreferences debug flags: video decoder log level, frame drop logging, GPU logging
    - ProAppSupport log settings: log level, categories, UI toggle, thread info
    - FCP behavior flags: gap coalescing, snapping, skimming overrides

    Use this to see what debug options are currently active before changing them.
    """
    r = bridge.call("debug.getConfig")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
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
              LogUI (shows in-app log viewer),
              LogThread (include thread info),
              LogCategory (bitmask)

            FCP behavior overrides:
              FFDontCoalesceGaps, FFDisableSnapping, FFDisableSkimming

        value: Value to set. "true"/"false" for bools, integer string for int keys,
               or level name for LogLevel (trace/debug/info/warning/error/failure).
    """
    # Parse value
    if value.lower() in ("true", "yes", "1"):
        parsed = True
    elif value.lower() in ("false", "no", "0"):
        parsed = False
    else:
        try:
            parsed = int(value)
        except ValueError:
            parsed = value  # pass as string (for LogLevel names etc.)

    r = bridge.call("debug.setConfig", key=key, value=parsed)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
def debug_stop_framerate_monitor() -> str:
    """Stop the HMD framerate monitor."""
    r = bridge.call("debug.stopFramerateMonitor")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


if __name__ == "__main__":
    mcp.run(transport="stdio")
