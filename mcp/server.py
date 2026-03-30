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
Connects to a JSON-RPC server running INSIDE the FCP process with access to all 78,000+ ObjC classes.

## Workflow Pattern
1. bridge_status() -- verify FCP is running
2. get_timeline_clips() -- see what's in the timeline
3. Perform actions: timeline_action(), playback_action(), call_method_with_args()
4. verify_action() -- confirm the edit took effect

## Key Actions (timeline_action)
blade, bladeAll, addMarker, addTodoMarker, addChapterMarker, deleteMarker,
addTransition, nextEdit, previousEdit, selectClipAtPlayhead, selectAll,
deselectAll, delete, cut, copy, paste, undo, redo, insertGap, trimToPlayhead

## Key Playback (playback_action)
playPause, goToStart, goToEnd, nextFrame, prevFrame, nextFrame10, prevFrame10

## Object Handles
Methods that return objects can store them as handles (e.g. "obj_1").
Pass handles as arguments to chain operations:
  libs = call_method_with_args("FFLibraryDocument", "copyActiveLibraries", return_handle=True)
  get_object_property(libs["handle"], "firstObject")

## Key FCP Classes
FFAnchoredTimelineModule (1435 methods) - timeline editing
FFAnchoredSequence (1074) - timeline data model
FFLibrary (203) - library container
FFEditActionMgr (42) - edit command dispatcher
FFPlayer (228) - playback engine
PEAppController (484) - app controller
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
      blade, bladeAll, addMarker, addTodoMarker, addChapterMarker, deleteMarker,
      nextMarker, previousMarker, addTransition, nextEdit, previousEdit,
      selectClipAtPlayhead, selectToPlayhead, selectAll, deselectAll,
      delete, cut, copy, paste, undo, redo, insertGap, trimToPlayhead

    You can also pass any raw ObjC selector name (e.g. "freezeFrame").
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
def import_fcpxml(xml: str) -> str:
    """Import FCPXML into FCP. Writes to a temp file and opens it with FCP's native importer.
    Provide valid FCPXML as a string. This can create entire timelines, add clips, etc.
    """
    r = bridge.call("fcpxml.import", xml=xml)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


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
