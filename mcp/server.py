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
2. open_project("My Project") -- load a project by name
3. get_timeline_clips() -- see what's in the timeline (items, handles, durations)
4. Perform actions using timeline_action() and playback_action()
5. verify_action() -- confirm the edit took effect by comparing state snapshots

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
             nextFrame10, prevFrame10, playAroundCurrent, playFromStart,
             playInToOut, playReverse, stopPlaying, loop,
             fastForward, rewind,
             playRate1X, playRate2X, playRate4X, playRate8X,
             playRate16X, playRate32X, playRateHalf, playRateMinusHalf,
             playRateMinus1X, playRateMinus2X, playRateMinus32X

    For precise speed control, use set_playback_speed() instead.
    """
    return _call_or_error("playback.action", action=action)


@mcp.tool()
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
# Read the timeline's current contents as structured data.
# This is how the AI "sees" what's in the project.

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

    # FCPXML uses rational time (e.g. "100/2400s") to avoid floating-point frame drift.
    # This maps user-friendly frame rates to numerator/denominator pairs.
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

    # Spine items go inside <spine> (the primary storyline), markers attach to the sequence
    spine_items = [i for i in item_list if i.get("type") in ("gap", "title", "transition", None)]
    markers = [i for i in item_list if i.get("type") == "marker"]

    if not spine_items:
        spine_items = [{"type": "gap", "duration": 10.0}]

    # Build spine XML -- items must follow Apple's DTD child ordering
    spine_xml = ""
    offset_seconds = 0.0  # running offset for placing items sequentially
    total_seconds = 0.0
    ts_counter = 1        # unique ID for text-style-def elements

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
# Lets the AI chain many small edits in one round-trip instead
# of making a separate tool call for each step.

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
# Computes statistics the AI can use to understand the timeline
# before suggesting edits (pacing, flash frames, etc).

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
        # Surface the most interesting methods -- the ones an AI is likely to want to call
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


# -- Low-level escape hatches for arbitrary ObjC calls --

@mcp.tool()
def call_method(class_name: str, selector: str, class_method: bool = True) -> str:
    """Call a zero-argument ObjC method. For methods WITH arguments, use call_method_with_args instead."""
    r = bridge.call("system.callMethod", className=class_name, selector=selector, classMethod=class_method)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
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
# Enumerate FCP's installed effects and apply them to clips.
# FCP organizes effects by type (filter, generator, title, audio).

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
# FCP has 376+ built-in transitions. These tools enumerate them
# and apply them at edit points (between adjacent clips).

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
# A floating search palette (like VS Code's Cmd+Shift+P) that
# can also pipe queries through Apple Intelligence for natural
# language editing commands.

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


@mcp.tool()
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
# Reads/writes FCP's internal effect parameter channels directly,
# bypassing the inspector UI. Works on transform, compositing, audio, crop.

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


@mcp.tool()
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


@mcp.tool()
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
# Switch the active editing tool (blade, trim, range, etc).

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
# Roles control how clips appear in the timeline index and
# how they're grouped during export (e.g. separate Dialogue/Music stems).

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
# Triggers FCP's share destinations (Export File, YouTube, etc).

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
# Create new projects, events, and libraries via FCP's internal APIs.

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
# Open Project by Name
# ============================================================
# Find a sequence by name (and optionally event) and load it
# into the editor — no manual handle navigation required.

@mcp.tool()
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
# Select Connected Clip at Playhead (Lane Selection)
# ============================================================
# The standard selectClipAtPlayhead only selects the primary
# storyline clip. This tool selects clips in any lane.

@mcp.tool()
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

@mcp.tool()
def capture_viewer(path: str = "/tmp/splicekit_viewer.png") -> str:
    """Capture the FCP viewer contents as a PNG image.

    Takes a screenshot of just the viewer/canvas area (not the whole screen),
    so you can verify text rendering, effects, color correction, etc. without
    relying on manual screenshots or having other windows in the way.

    Args:
        path: Output file path for the PNG image.
              Default: /tmp/splicekit_viewer.png

    Returns the file path, image dimensions, and file size.
    The saved PNG can be read by Claude to visually verify timeline output.
    """
    r = bridge.call("viewer.capture", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    if r.get("status") == "ok":
        return (f"Viewer captured: {r.get('path')}\n"
                f"Size: {r.get('width')}x{r.get('height')} ({r.get('bytes', 0)} bytes)")
    return _fmt(r)


# ============================================================
# Export FCPXML (Programmatic, No Dialog)
# ============================================================
# Export the current project to FCPXML without the save dialog.

@mcp.tool()
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
# History (Persistent Unlimited Undo)
# ============================================================
# Every edit in FCP is automatically captured as a compressed FCPXML snapshot
# in a per-project SQLite database. Snapshots survive FCP restarts and have
# no count limit. Browse, restore, compare, and manage history here.

@mcp.tool()
def snapshot_project(label: str = "") -> str:
    """Take a manual snapshot of the current timeline state for persistent undo history.

    Snapshots are automatically taken on every edit (blade, trim, add effect, etc.),
    but you can also take manual ones with a descriptive label for easy identification.

    Args:
        label: Optional descriptive label (default: "Manual Snapshot")
    """
    r = bridge.call("history.snapshot", action=label or "Manual Snapshot")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
def timeline_history(limit: int = 20, offset: int = 0) -> str:
    """Browse the persistent undo history for the current project.

    Shows timestamped snapshots with action names (e.g. "Blade", "Trim", "Add Dissolve").
    Each snapshot can be restored with history_restore(). History survives FCP restarts.

    Args:
        limit: Max number of snapshots to return (default 20)
        offset: Skip this many snapshots from the newest (for paging)
    """
    r = bridge.call("history.list", limit=limit, offset=offset)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    snapshots = r.get("snapshots", [])
    if not snapshots:
        return "No snapshots found for this project."
    lines = [f"History for current project ({len(snapshots)} snapshots):"]
    for s in snapshots:
        lines.append(
            f"  #{s['id']}  {s.get('time', '')}  \"{s.get('action', '')}\"  "
            f"items={s.get('itemCount', '?')}  dur={s.get('durationSeconds', 0):.1f}s  "
            f"seq={s.get('undoSeq', 0)}  size={s.get('storeSize', 0) // 1024}KB"
        )
    return "\n".join(lines)


@mcp.tool()
def history_restore(snapshot_id: int) -> str:
    """Restore the timeline to a previous snapshot state.

    Within a session: uses FCP's native undo manager (exact undo count via
    monotonic edit sequence counter). Fully reversible with redo.

    After a restart (undo stack exhausted): falls back to async Core Data
    store swap — closes the library, replaces the store files with the
    snapshot, and reopens. Check history_status() to confirm completion.

    Args:
        snapshot_id: The snapshot ID from timeline_history()
    """
    r = bridge.call("history.restore", id=snapshot_id)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
def history_compare(id1: int, id2: int = 0) -> str:
    """Compare two snapshots, or a snapshot vs the current timeline state.

    Shows differences in item count and duration between the two states.

    Args:
        id1: First snapshot ID
        id2: Second snapshot ID (0 or omitted = compare to current state)
    """
    params = {"id1": id1}
    if id2 > 0:
        params["id2"] = id2
    r = bridge.call("history.compare", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
def history_status() -> str:
    """Show the status of the persistent undo history system.

    Returns: enabled state, database path, snapshot count, storage size,
    and configuration (max snapshots, max age).
    """
    r = bridge.call("history.status")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
def history_configure(
    enabled: bool = True,
    max_snapshots: int = 0,
    max_age_days: int = 0,
) -> str:
    """Configure the persistent undo history system.

    Args:
        enabled: Enable or disable auto-capture on every edit
        max_snapshots: Max snapshots per project (0 = don't change, default 1000)
        max_age_days: Max age in days before auto-prune (0 = don't change, default 30)
    """
    params = {"enabled": enabled}
    if max_snapshots > 0:
        params["maxSnapshots"] = max_snapshots
    if max_age_days > 0:
        params["maxAgeDays"] = max_age_days
    r = bridge.call("history.configure", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
def history_prune(
    snapshot_id: int = 0,
    before_timestamp: float = 0,
    all: bool = False,
) -> str:
    """Delete snapshots from the history database.

    Args:
        snapshot_id: Delete a specific snapshot by ID
        before_timestamp: Delete all snapshots before this Unix timestamp
        all: Delete ALL snapshots for this project (use with caution)
    """
    params = {}
    if snapshot_id > 0:
        params["id"] = snapshot_id
    elif before_timestamp > 0:
        params["before_timestamp"] = before_timestamp
    elif all:
        params["all"] = True
    else:
        return "Error: specify snapshot_id, before_timestamp, or all=True"
    r = bridge.call("history.delete", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
def history_get_data(snapshot_id: int, path: str = "") -> str:
    """Extract the Core Data store snapshot files to a directory.

    Unpacks the .flexolibrary + WAL/SHM files from a history snapshot
    to disk. Useful for offline inspection or manual restore.

    Args:
        snapshot_id: The snapshot ID from timeline_history()
        path: Directory to write to (default: /tmp/splicekit_snapshot_<id>/)
    """
    params = {"id": snapshot_id}
    if path:
        params["path"] = path
    r = bridge.call("history.getData", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    files = r.get("files", [])
    return f"Store snapshot extracted to {r.get('path', path)} ({len(files)} files, {r.get('totalBytes', 0)} bytes)"


# ============================================================
# Deploy & Restart FCP
# ============================================================
# One-shot command to build, deploy, re-sign, kill FCP, relaunch,
# and wait for the bridge to come back online.

@mcp.tool()
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
# FCP pops up modal dialogs for various operations (project settings,
# export, missing media, etc). These tools detect and interact with
# them so the AI can handle dialogs without human intervention.

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
# Get/set the canvas zoom level. 0.0 = fit-to-window.

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
# Runtime configuration for SpliceKit's own behavioral tweaks.

@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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
# FlexMusic (Dynamic Soundtrack)
# ============================================================
# FCP's built-in AI music engine. Songs can stretch/shrink to
# any duration by rearranging their musical sections dynamically.

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
# End-to-end pipeline: analyze clips -> plan cuts to music beats
# -> assemble a montage timeline. Can run as individual steps
# or as a single montage_auto() call.

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
# Exposes FCP's hidden internal debug flags (TLK visual overlays,
# ProAppSupport logging, CFPreferences keys) and SpliceKit's own
# debugging toolkit (breakpoints, tracing, eval, crash handling).

@mcp.tool()
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


# -- Runtime metadata export (for reverse engineering / IDA Pro) --

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


# ---------------------------------------------------------------------------
# Debug: Breakpoints
# ---------------------------------------------------------------------------
# True breakpoints that freeze FCP mid-execution. The JSON-RPC server
# stays alive on a background thread so you can inspect state while paused.

@mcp.tool()
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

@mcp.tool()
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

@mcp.tool()
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

@mcp.tool()
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

@mcp.tool()
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

@mcp.tool()
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

@mcp.tool()
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

@mcp.tool()
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

@mcp.tool()
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


# This is the bridge-side beat detection (delegates to the dylib).
# The earlier detect_beats() runs an external subprocess instead.
@mcp.tool()
def detect_beats(file_path: str, sensitivity: float = 0.5,
                 min_bpm: int = 0, max_bpm: int = 0) -> str:
    """Detect beats, bars, sections, and BPM in an audio file.

    Runs the beat-detector tool externally (FCP's hardened runtime prevents
    in-process audio file access). Build first:
        swiftc -O -o build/beat-detector tools/beat-detector.swift

    Args:
        file_path: Path to audio file (mp3, wav, aif, etc.)
        sensitivity: Detection sensitivity 0.0-1.0 (higher = more beats)
        min_bpm: Minimum BPM to consider (0 = auto)
        max_bpm: Maximum BPM to consider (0 = auto)
    """
    r = bridge.call("beats.detect", file_path=file_path,
                    sensitivity=sensitivity, min_bpm=min_bpm, max_bpm=max_bpm)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
def seek_to_time(seconds: float) -> str:
    """Jump the playhead to an exact time in seconds.

    Faster and more precise than stepping frames. Uses CMTime internally
    with the timeline's native timescale for frame-accurate positioning.

    Args:
        seconds: Time in seconds (e.g. 3.5 for 3.5 seconds in)
    """
    r = bridge.call("playback.seekToTime", seconds=seconds)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
def close_captions() -> str:
    """Close the social captions panel."""
    r = bridge.call("captions.close")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Captions panel closed."


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
def export_captions_txt(path: str) -> str:
    """Export the current captions as plain text.

    Args:
        path: Output file path (e.g. "/Users/you/Desktop/captions.txt")
    """
    r = bridge.call("captions.exportTXT", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
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


@mcp.tool()
def lua_reset() -> str:
    """Reset the Lua VM. All state (variables, loaded modules) is cleared and the sk module is re-registered."""
    r = bridge.call("lua.reset")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Lua VM reset"


@mcp.tool()
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


@mcp.tool()
def lua_state() -> str:
    """Get Lua VM state: memory usage, user-defined globals, watched paths, scripts directory."""
    r = bridge.call("lua.getState")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# MCP servers communicate over stdio -- the AI tool framework handles the transport
if __name__ == "__main__":
    mcp.run(transport="stdio")
