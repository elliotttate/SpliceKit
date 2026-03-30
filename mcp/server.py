#!/usr/bin/env python3
"""
FCPBridge MCP Server v2
Provides direct in-process control of Final Cut Pro via the FCPBridge dylib.
Connects to the JSON-RPC server running INSIDE the FCP process at 127.0.0.1:9876.
"""

import socket
import json
import time
from mcp.server.fastmcp import FastMCP

FCPBRIDGE_HOST = "127.0.0.1"
FCPBRIDGE_PORT = 9876

mcp = FastMCP(
    "fcpbridge",
    instructions="""Direct in-process control of Final Cut Pro via injected FCPBridge dylib.
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

## FCPXML for Complex Edits
For creating entire projects with gaps, titles, markers:
  xml = generate_fcpxml(items='[{"type":"gap","duration":5},{"type":"title","text":"Hello","duration":3}]')
  import_fcpxml(xml, internal=True)  # imports without restart

## Object Handles for Deep Access
  call_method_with_args("FFLibraryDocument", "copyActiveLibraries", return_handle=True)
  # Returns {"handle": "obj_1", "class": "..."} -- pass handle to subsequent calls
  call_method_with_args("obj_1", "objectAtIndex:", '[{"type":"int","value":0}]', false, true)
  # Always release when done: manage_handles(action="release_all")
"""
)


class BridgeConnection:
    """Persistent connection to the FCPBridge JSON-RPC server."""

    def __init__(self):
        self.sock = None
        self._buf = b""
        self._id = 0

    def ensure_connected(self):
        if self.sock is None:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sock.settimeout(30)
            self.sock.connect((FCPBRIDGE_HOST, FCPBRIDGE_PORT))
            self._buf = b""

    def call(self, method: str, **params) -> dict:
        try:
            self.ensure_connected()
        except (ConnectionRefusedError, OSError) as e:
            return {"error": f"Cannot connect to FCPBridge at {FCPBRIDGE_HOST}:{FCPBRIDGE_PORT}. "
                    f"Is the modded FCP running? Error: {e}"}

        self._id += 1
        req = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": self._id})
        try:
            self.sock.sendall(req.encode() + b"\n")
            while b"\n" not in self._buf:
                chunk = self.sock.recv(16777216)
                if not chunk:
                    self.sock = None
                    return {"error": "Connection closed by FCPBridge"}
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
    return "error" in r or "ERROR" in r


def _fmt(r):
    return json.dumps(r, indent=2, default=str)


# ============================================================
# Core Connection & Status
# ============================================================

@mcp.tool()
def bridge_status() -> str:
    """Check if FCPBridge is running and get FCP version info."""
    r = bridge.call("system.version")
    if _err(r):
        return f"FCPBridge NOT connected: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Timeline Actions (direct ObjC IBAction calls)
# ============================================================

@mcp.tool()
def timeline_action(action: str) -> str:
    """Perform a timeline editing action via direct ObjC calls.

    Actions:
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
      Other: solo, disable, createCompoundClip, autoReframe, exportXML,
             shareSelection, addVideoGenerator

    You can also pass any raw ObjC selector name.
    """
    r = bridge.call("timeline.action", action=action)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@mcp.tool()
def playback_action(action: str) -> str:
    """Control playback via responder chain.

    Actions: playPause, goToStart, goToEnd, nextFrame, prevFrame,
             nextFrame10, prevFrame10, playAroundCurrent
    """
    r = bridge.call("playback.action", action=action)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


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
        lines.append(f"\n{'Idx':<4} {'Class':<30} {'Name':<20} {'Duration':>10} {'Lane':>5} {'Sel':>4} {'Handle'}")
        lines.append("-" * 95)
        for item in items:
            dur_s = item.get("duration", {}).get("seconds", 0)
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

    Examples:
      call_method_with_args("FFLibraryDocument", "copyActiveLibraries", return_handle=True)
      call_method_with_args("obj_3", "displayName", "[]", false)
    """
    try:
        parsed_args = json.loads(args)
    except json.JSONDecodeError as e:
        return f"Invalid args JSON: {e}"

    r = bridge.call("system.callMethodWithArgs",
                    target=target, selector=selector, args=parsed_args,
                    classMethod=class_method, returnHandle=return_handle)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Object Handles
# ============================================================

@mcp.tool()
def manage_handles(action: str = "list", handle: str = "") -> str:
    """Manage object handles stored by FCPBridge.

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
# FCPXML Import
# ============================================================

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
def generate_fcpxml(event_name: str = "FCPBridge Event", project_name: str = "FCPBridge Project",
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
    markers_added = 0
    errors = []

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

        # Navigate to the timestamp and add marker
        # Use frame stepping to get close (at 24fps)
        frames = int(total_seconds * 24)

        # Go to start, step to position, add marker
        bridge.call("playback.action", action="goToStart")
        for _ in range(frames):
            bridge.call("playback.action", action="nextFrame")

        r = bridge.call("timeline.action", action="addMarker")
        if not _err(r):
            markers_added += 1
        else:
            errors.append(f"Failed at {total_seconds:.1f}s: {r}")

    result = f"Imported {markers_added} markers from SRT"
    if errors:
        result += f"\nErrors: {len(errors)}"
        for e in errors[:5]:
            result += f"\n  - {e}"
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
    """Send a raw JSON-RPC call to FCPBridge."""
    try:
        p = json.loads(params)
    except json.JSONDecodeError as e:
        return f"Invalid JSON params: {e}"
    r = bridge.call(method, **p)
    return _fmt(r)


if __name__ == "__main__":
    mcp.run(transport="stdio")
