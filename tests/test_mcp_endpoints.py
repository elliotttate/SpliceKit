#!/usr/bin/env python3
"""
Comprehensive test suite for all SpliceKit MCP endpoints.

Tests every JSON-RPC endpoint exposed by the ObjC server to verify:
1. The endpoint responds (no Method not found)
2. The response has the expected structure
3. Error cases return proper error messages

Usage:
    python3 tests/test_mcp_endpoints.py              # run all tests
    python3 tests/test_mcp_endpoints.py --group debug # run only debug tests
    python3 tests/test_mcp_endpoints.py --verbose     # show all responses

Requires: FCP running with SpliceKit injected, bridge on 127.0.0.1:9876
"""

import socket
import json
import sys
import time
import argparse

# ── Connection ──────────────────────────────────────────────

HOST = "127.0.0.1"
PORT = 9876
_id = 0


def rpc(method, params=None, timeout=10):
    """Send a JSON-RPC request and return the parsed response."""
    global _id
    _id += 1
    req = {"jsonrpc": "2.0", "method": method, "id": _id}
    if params:
        req["params"] = params
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((HOST, PORT))
    s.sendall((json.dumps(req) + "\n").encode())
    data = b""
    while b"\n" not in data:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    s.close()
    return json.loads(data.decode().strip())


# ── Test helpers ────────────────────────────────────────────

PASSED = 0
FAILED = 0
SKIPPED = 0
VERBOSE = False


def _res(r):
    """Extract result from response."""
    return r.get("result", r)


def ok(name, r, check=None):
    global PASSED, FAILED
    res = _res(r)
    err = None
    if isinstance(res, dict):
        err = res.get("error")
    if isinstance(r.get("error"), dict):
        err = r["error"].get("message", r["error"])

    if err:
        print(f"  FAIL  {name}: {str(err)[:150]}")
        FAILED += 1
        return False

    display = str(res)[:180]
    if check and not check(r):
        print(f"  FAIL  {name}: check failed — {display}")
        FAILED += 1
        return False

    if VERBOSE:
        print(f"  OK    {name}: {display}")
    else:
        print(f"  OK    {name}")
    PASSED += 1
    return True


def expect_error(name, r, substring=None):
    global PASSED, FAILED
    res = _res(r)
    err = None
    if isinstance(res, dict):
        err = res.get("error")
    if isinstance(r.get("error"), dict):
        err = r["error"].get("message", r["error"])
    if isinstance(r.get("error"), str):
        err = r["error"]

    if err:
        if substring and substring.lower() not in str(err).lower():
            print(f"  FAIL  {name}: expected '{substring}' in error, got: {str(err)[:120]}")
            FAILED += 1
            return
        print(f"  OK    {name}: (expected error)")
        PASSED += 1
    else:
        print(f"  FAIL  {name}: expected error but got success — {str(res)[:100]}")
        FAILED += 1


def skip(name, reason=""):
    global SKIPPED
    print(f"  SKIP  {name}{' — ' + reason if reason else ''}")
    SKIPPED += 1


# ── Test Groups ─────────────────────────────────────────────

def test_system():
    print("\n[system.*]")
    ok("version", rpc("system.version"),
       lambda r: "splicekit_version" in str(r))
    ok("getClasses", rpc("system.getClasses", {"filter": "FFAnchoredTimeline"}),
       lambda r: len(_res(r).get("classes", [])) > 0)
    ok("getMethods", rpc("system.getMethods", {"className": "NSObject", "filter": "init"}))
    ok("getProperties", rpc("system.getProperties", {"className": "NSApplication"}))
    ok("getProtocols", rpc("system.getProtocols", {"className": "NSObject"}))
    ok("getSuperchain", rpc("system.getSuperchain", {"className": "NSWindow"}),
       lambda r: "NSResponder" in str(r))
    ok("getIvars", rpc("system.getIvars", {"className": "NSApplication"}))
    ok("callMethod", rpc("system.callMethod", {
        "className": "NSProcessInfo", "selector": "processInfo", "classMethod": True
    }))
    ok("callMethodWithArgs", rpc("system.callMethodWithArgs", {
        "target": "NSProcessInfo",
        "selector": "processInfo",
        "args": [],
        "classMethod": True,
        "returnHandle": True
    }), lambda r: "handle" in str(r))
    expect_error("swizzle (stub)", rpc("system.swizzle", {}))


def test_timeline():
    print("\n[timeline.*]")
    ok("action (toggleSnapping)", rpc("timeline.action", {"action": "toggleSnapping"}))
    ok("action (toggleSnapping back)", rpc("timeline.action", {"action": "toggleSnapping"}))
    # getState may error if no project open — that's ok, we just test it responds
    r = rpc("timeline.getState")
    if "error" in str(r) and "No active" in str(r):
        skip("getState", "no project open")
    else:
        ok("getState", r)
    r = rpc("timeline.getDetailedState")
    if "error" in str(r) and "No active" in str(r):
        skip("getDetailedState", "no project open")
    else:
        ok("getDetailedState", r)


def test_timeline_direct():
    print("\n[timeline.directAction]")
    expect_error("missing params", rpc("timeline.directAction", {}), "action or selector")
    expect_error("unknown action", rpc("timeline.directAction", {"action": "fakeAction999"}), "Unknown")
    # Raw selector fallback
    r = rpc("timeline.directAction", {"selector": "sequence"})
    res = _res(r)
    if "error" in str(res) and "No active" in str(res):
        skip("raw selector", "no project open")
    else:
        ok("raw selector", r)


def test_playback():
    print("\n[playback.*]")
    ok("action (goToStart)", rpc("playback.action", {"action": "goToStart"}))
    r = rpc("playback.getPosition")
    if "error" in str(r) and ("No active" in str(r) or "No player" in str(r)):
        skip("getPosition", "no project open")
    else:
        ok("getPosition", r)
    r = rpc("playback.seekToTime", {"seconds": 0.0})
    if "error" in str(r) and "No active" in str(r):
        skip("seekToTime", "no project open")
    else:
        ok("seekToTime", r)


def test_effects():
    print("\n[effects.*]")
    r = rpc("effects.list")
    if "error" in str(r) and ("No active" in str(r) or "Registry" in str(r)):
        skip("list", "no active timeline or registry unavailable")
    else:
        ok("list", r)
    ok("listAvailable", rpc("effects.listAvailable", {"type": "effect.video.transition"}),
       lambda r: len(_res(r).get("effects", [])) > 0)
    r = rpc("effects.getClipEffects")
    if "error" in str(r):
        skip("getClipEffects", "no clip selected")
    else:
        ok("getClipEffects", r)


def test_transitions():
    print("\n[transitions.*]")
    ok("list", rpc("transitions.list"),
       lambda r: len(_res(r).get("transitions", [])) > 0)
    # apply would modify timeline, skip unless project open
    skip("apply", "would modify timeline")


def test_fcpxml():
    print("\n[fcpxml.*]")
    # import needs XML, just test error handling
    expect_error("import (no xml)", rpc("fcpxml.import", {}), "xml")
    expect_error("pasteImport (no xml)", rpc("fcpxml.pasteImport", {}), "xml")


def test_inspector():
    print("\n[inspector.*]")
    r = rpc("inspector.get")
    if "error" in str(r):
        skip("get", "no clip selected")
    else:
        ok("get", r)
    # set would modify state, skip
    skip("set", "would modify clip properties")


def test_menu():
    print("\n[menu.*]")
    ok("list", rpc("menu.list"),
       lambda r: len(_res(r).get("menus", _res(r).get("items", []))) > 0)
    # execute would trigger a menu action
    skip("execute", "would trigger menu action")


def test_tool():
    print("\n[tool.select]")
    ok("select (select)", rpc("tool.select", {"tool": "select"}))


def test_view():
    print("\n[view.*]")
    ok("toggle (inspector)", rpc("view.toggle", {"panel": "inspector"}))
    ok("toggle (inspector back)", rpc("view.toggle", {"panel": "inspector"}))


def test_viewer():
    print("\n[viewer.*]")
    r = rpc("viewer.getZoom")
    if "error" in str(r):
        skip("getZoom", "no viewer")
    else:
        ok("getZoom", r, lambda r: "zoom" in str(r))


def test_roles():
    print("\n[roles.*]")
    skip("assign", "would modify clip roles")


def test_share():
    print("\n[share.*]")
    skip("export", "would trigger export")


def test_project():
    print("\n[project.*]")
    # Don't actually create projects/events/libraries — just test error paths
    skip("create", "would create project")
    skip("createEvent", "would create event")
    skip("createLibrary", "would create library")


def test_object():
    print("\n[object.*]")
    ok("list", rpc("object.list"))
    expect_error("get (bad handle)", rpc("object.get", {"handle": "obj_99999"}), "not found")
    expect_error("getProperty (bad)", rpc("object.getProperty", {"handle": "obj_99999", "key": "x"}))


def test_dialog():
    print("\n[dialog.*]")
    ok("detect", rpc("dialog.detect"))
    # Other dialog actions need an open dialog
    skip("click/fill/checkbox/popup/dismiss", "no dialog open")


def test_command():
    print("\n[command.*]")
    ok("search", rpc("command.search", {"query": "blade"}))
    skip("execute/show/hide/ai", "would trigger command palette")


def test_dual_timeline():
    print("\n[dualTimeline.*]")
    ok("status", rpc("dualTimeline.status"),
       lambda r: "primary" in str(_res(r)) and "secondaryIdentifier" in str(_res(r)))
    skip("open/syncRoot/openSelected/focus/close", "would modify window focus/layout")


def test_scene():
    print("\n[scene.detect]")
    skip("detect", "needs media on timeline")


def test_beats():
    print("\n[beats.detect]")
    # The ObjC handler just returns an error saying to use MCP tool
    r = rpc("beats.detect", {"file_path": "/tmp/nonexistent.wav"})
    # This is expected to error (either "use MCP tool" or "file not found")
    expect_error("detect (no file)", r)


def test_browser():
    print("\n[browser.*]")
    r = rpc("browser.listClips")
    if "error" in str(r) and "No active" in str(r):
        skip("listClips", "no library open")
    else:
        ok("listClips", r)
    expect_error("appendClip (no args)", rpc("browser.appendClip", {}))


def test_titles():
    print("\n[titles.insert]")
    expect_error("insert (no args)", rpc("titles.insert", {}), "effectID or name")


def test_stabilize():
    print("\n[stabilize.subject]")
    r = rpc("stabilize.subject")
    if "error" in str(r):
        # Expected: no clip selected or no timeline
        expect_error("subject (no selection)", r)
    else:
        ok("subject", r)


def test_transcript():
    print("\n[transcript.*]")
    r = rpc("transcript.getState")
    ok("getState", r)
    ok("setEngine", rpc("transcript.setEngine", {"engine": "fcpNative"}))
    expect_error("setEngine bad", rpc("transcript.setEngine", {"engine": "nonexistent"}), "Unknown")
    skip("open/close/delete/move/search/setSpeaker/setSilence/deleteSilences",
         "would modify transcript state")


def test_options():
    print("\n[options.*]")
    ok("get", rpc("options.get"))


def test_background_render():
    print("\n[backgroundRender.*]")
    ok("status", rpc("backgroundRender.status"),
       lambda r: "available" in str(_res(r)) or "taskQueue" in str(_res(r)))
    skip("control", "would transiently modify background render scheduling")


def test_flexmusic():
    print("\n[flexmusic.*]")
    skip("all", "needs FlexMusic setup")


def test_montage():
    print("\n[montage.*]")
    skip("all", "needs clips on timeline")


# ── Debug endpoints ─────────────────────────────────────────

def test_debug_config():
    print("\n[debug.config]")
    ok("getConfig", rpc("debug.getConfig"),
       lambda r: "timeline_debug" in str(r))
    ok("setConfig", rpc("debug.setConfig", {"key": "TLKShowRenderBar", "value": "true"}))
    r = rpc("debug.resetConfig", {"scope": "tlk"})
    if "error" in str(r) and "background thread" in str(r):
        skip("resetConfig (tlk)", "TLK reload requires main thread")
    else:
        ok("resetConfig (tlk)", r)
    ok("enablePreset", rpc("debug.enablePreset", {"preset": "all_off"}))


def test_debug_framerate():
    print("\n[debug.framerate]")
    ok("start", rpc("debug.startFramerateMonitor", {"interval": 5.0}))
    ok("stop", rpc("debug.stopFramerateMonitor"))


def test_debug_runtime():
    print("\n[debug.runtime]")
    ok("listLoadedImages", rpc("debug.listLoadedImages"),
       lambda r: _res(r).get("count", 0) > 0)
    ok("getNotificationNames", rpc("debug.getNotificationNames"))
    ok("dumpRuntimeMetadata", rpc("debug.dumpRuntimeMetadata", {"binary": "Flexo", "classesOnly": True}))
    ok("getImageSymbols", rpc("debug.getImageSymbols", {"binary": "Flexo", "limit": 5}))
    ok("getImageSections", rpc("debug.getImageSections", {"binary": "Flexo"}))


def test_debug_breakpoint():
    print("\n[debug.breakpoint]")
    rpc("debug.breakpoint", {"action": "removeAll"})

    ok("list (empty)", rpc("debug.breakpoint", {"action": "list"}),
       lambda r: _res(r).get("count") == 0)
    ok("add", rpc("debug.breakpoint", {
        "action": "add", "className": "NSApplication", "selector": "isActive"
    }), lambda r: "swizzle" in str(r))
    ok("list (1)", rpc("debug.breakpoint", {"action": "list"}),
       lambda r: _res(r).get("count") == 1)
    ok("disable", rpc("debug.breakpoint", {
        "action": "disable", "className": "NSApplication", "selector": "isActive"
    }))
    ok("enable", rpc("debug.breakpoint", {
        "action": "enable", "className": "NSApplication", "selector": "isActive"
    }))
    ok("inspect (not paused)", rpc("debug.breakpoint", {"action": "inspect"}),
       lambda r: _res(r).get("paused") == False)
    ok("remove", rpc("debug.breakpoint", {
        "action": "remove", "className": "NSApplication", "selector": "isActive"
    }))

    # Conditional + hitCount + oneShot
    ok("add conditional", rpc("debug.breakpoint", {
        "action": "add", "className": "NSApplication", "selector": "isActive",
        "condition": "isHidden", "hitCount": 10, "oneShot": True
    }))
    ok("removeAll", rpc("debug.breakpoint", {"action": "removeAll"}))

    # Multi-arg method
    ok("add multi-arg (trace_only)", rpc("debug.breakpoint", {
        "action": "add", "className": "PEAppController",
        "selector": "application:openFile:"
    }), lambda r: "trace_only" in str(r))
    ok("removeAll cleanup", rpc("debug.breakpoint", {"action": "removeAll"}))

    # Error cases
    expect_error("continue (not paused)", rpc("debug.breakpoint", {"action": "continue"}), "Not paused")
    expect_error("step (not paused)", rpc("debug.breakpoint", {"action": "step"}), "Not paused")
    expect_error("bad class", rpc("debug.breakpoint", {
        "action": "add", "className": "ZZZZZ", "selector": "x"
    }), "not found")
    expect_error("bad selector", rpc("debug.breakpoint", {
        "action": "add", "className": "NSApplication", "selector": "zzz999:"
    }), "not found")
    expect_error("missing params", rpc("debug.breakpoint", {"action": "add"}), "required")


def test_debug_trace():
    print("\n[debug.traceMethod]")
    rpc("debug.traceMethod", {"action": "removeAll"})
    rpc("debug.traceMethod", {"action": "clearLog"})

    ok("list (empty)", rpc("debug.traceMethod", {"action": "list"}),
       lambda r: _res(r).get("count") == 0)
    ok("add", rpc("debug.traceMethod", {
        "action": "add", "className": "NSApplication", "selector": "isActive"
    }), lambda r: "swizzle" in str(r))
    ok("list (1)", rpc("debug.traceMethod", {"action": "list"}),
       lambda r: _res(r).get("count") == 1)
    ok("getLog", rpc("debug.traceMethod", {"action": "getLog", "limit": 5}),
       lambda r: "log" in str(r))
    ok("remove", rpc("debug.traceMethod", {
        "action": "remove", "className": "NSApplication", "selector": "isActive"
    }))
    ok("clearLog", rpc("debug.traceMethod", {"action": "clearLog"}))
    ok("removeAll", rpc("debug.traceMethod", {"action": "removeAll"}))


def test_debug_watch():
    print("\n[debug.watch]")
    rpc("debug.watch", {"action": "removeAll"})

    ok("list (empty)", rpc("debug.watch", {"action": "list"}),
       lambda r: _res(r).get("count") == 0)
    ok("add", rpc("debug.watch", {
        "action": "add", "className": "NSApplication", "keyPath": "mainWindow"
    }), lambda r: "watching" in str(r))
    ok("list (1)", rpc("debug.watch", {"action": "list"}),
       lambda r: _res(r).get("count") == 1)
    ok("removeAll", rpc("debug.watch", {"action": "removeAll"}))
    expect_error("missing keyPath", rpc("debug.watch", {
        "action": "add", "className": "NSApplication"
    }), "keyPath")


def test_debug_crash():
    print("\n[debug.crashHandler]")
    ok("install", rpc("debug.crashHandler", {"action": "install"}))
    ok("status", rpc("debug.crashHandler", {"action": "status"}),
       lambda r: _res(r).get("installed") == True)
    ok("getLog", rpc("debug.crashHandler", {"action": "getLog"}),
       lambda r: "crashes" in str(r))
    ok("clearLog", rpc("debug.crashHandler", {"action": "clearLog"}))


def test_debug_threads():
    print("\n[debug.threads]")
    ok("basic", rpc("debug.threads"),
       lambda r: _res(r).get("totalThreadCount", 0) > 0)
    ok("detailed", rpc("debug.threads", {"detailed": True}),
       lambda r: len(_res(r).get("threads", [])) > 0)


def test_debug_eval():
    print("\n[debug.eval]")
    ok("expression", rpc("debug.eval", {"expression": "NSApp.delegate"}),
       lambda r: "PEAppController" in str(r))
    ok("chain", rpc("debug.eval", {"chain": ["delegate"]}),
       lambda r: "PEAppController" in str(r))
    ok("storeResult", rpc("debug.eval", {"expression": "NSApp.delegate", "storeResult": True}),
       lambda r: "handle" in str(r))
    ok("deep chain", rpc("debug.eval", {"expression": "NSApp.delegate.className"}))
    expect_error("bad property", rpc("debug.eval", {"expression": "NSApp.zzz999"}))


def test_debug_plugin():
    print("\n[debug.loadPlugin]")
    ok("list (empty)", rpc("debug.loadPlugin", {"action": "list"}),
       lambda r: _res(r).get("count", -1) >= 0)
    expect_error("load nonexistent", rpc("debug.loadPlugin", {
        "action": "load", "path": "/tmp/nope_99999.dylib"
    }), "dlopen")
    expect_error("missing path", rpc("debug.loadPlugin", {"action": "load"}), "path")


def test_debug_notification():
    print("\n[debug.observeNotification]")
    rpc("debug.observeNotification", {"action": "removeAll"})

    ok("list (empty)", rpc("debug.observeNotification", {"action": "list"}),
       lambda r: _res(r).get("count") == 0)
    ok("add specific", rpc("debug.observeNotification", {
        "action": "add", "name": "FFEffectsChangedNotification"
    }))
    ok("list (1)", rpc("debug.observeNotification", {"action": "list"}),
       lambda r: _res(r).get("count") == 1)
    ok("remove specific", rpc("debug.observeNotification", {
        "action": "remove", "name": "FFEffectsChangedNotification"
    }))
    ok("add wildcard", rpc("debug.observeNotification", {"action": "add", "name": "*"}))
    ok("removeAll", rpc("debug.observeNotification", {"action": "removeAll"}))


# ── New actionMap entries ───────────────────────────────────

def test_new_actions():
    print("\n[new actionMap entries]")
    # These send through the responder chain — they may error with "No responder"
    # if no project is open, but the point is they don't return "Method not found"
    for action_name in ["dropMenuCancel", "retimeTurnOnOpticalFlowHigh",
                        "resetCinematic", "trimEdgeAtPlayhead",
                        "setCaptionPlaybackEnabled", "deleteActiveVariant"]:
        r = rpc("timeline.action", {"action": action_name})
        res = _res(r)
        err = str(res.get("error", "")) if isinstance(res, dict) else ""
        if "Method not found" in err:
            print(f"  FAIL  {action_name}: not registered in actionMap")
            global FAILED
            FAILED += 1
        elif "No responder" in err or "No active" in err or "does not respond" in err:
            # Expected when no project/clip is active — action IS registered
            global PASSED
            print(f"  OK    {action_name} (registered, needs active target)")
            PASSED += 1
        else:
            ok(action_name, r)


# ── Run ─────────────────────────────────────────────────────

TEST_GROUPS = {
    "system": test_system,
    "timeline": test_timeline,
    "timeline_direct": test_timeline_direct,
    "playback": test_playback,
    "effects": test_effects,
    "transitions": test_transitions,
    "fcpxml": test_fcpxml,
    "inspector": test_inspector,
    "menu": test_menu,
    "tool": test_tool,
    "view": test_view,
    "viewer": test_viewer,
    "roles": test_roles,
    "share": test_share,
    "project": test_project,
    "object": test_object,
    "dialog": test_dialog,
    "command": test_command,
    "dual_timeline": test_dual_timeline,
    "scene": test_scene,
    "beats": test_beats,
    "browser": test_browser,
    "titles": test_titles,
    "stabilize": test_stabilize,
    "transcript": test_transcript,
    "options": test_options,
    "flexmusic": test_flexmusic,
    "montage": test_montage,
    "debug_config": test_debug_config,
    "debug_framerate": test_debug_framerate,
    "debug_runtime": test_debug_runtime,
    "debug_breakpoint": test_debug_breakpoint,
    "debug_trace": test_debug_trace,
    "debug_watch": test_debug_watch,
    "debug_crash": test_debug_crash,
    "debug_threads": test_debug_threads,
    "debug_eval": test_debug_eval,
    "debug_plugin": test_debug_plugin,
    "debug_notification": test_debug_notification,
    "new_actions": test_new_actions,
}


def main():
    global VERBOSE

    parser = argparse.ArgumentParser(description="Test SpliceKit MCP endpoints")
    parser.add_argument("--group", help="Run only this test group")
    parser.add_argument("--verbose", "-v", action="store_true", help="Show all responses")
    args = parser.parse_args()
    VERBOSE = args.verbose

    # Verify connection
    try:
        r = rpc("system.version", timeout=3)
        ver = _res(r).get("splicekit_version", "?")
        pid = _res(r).get("pid", "?")
        print(f"Connected to SpliceKit {ver} (FCP pid {pid})")
    except Exception as e:
        print(f"Cannot connect to SpliceKit: {e}")
        print("Make sure modded FCP is running with SpliceKit injected.")
        sys.exit(1)

    print("=" * 60)
    print("SpliceKit Endpoint Test Suite")
    print("=" * 60)

    if args.group:
        if args.group in TEST_GROUPS:
            TEST_GROUPS[args.group]()
        else:
            print(f"Unknown group: {args.group}")
            print(f"Available: {', '.join(TEST_GROUPS.keys())}")
            sys.exit(1)
    else:
        for group_fn in TEST_GROUPS.values():
            group_fn()

    print("\n" + "=" * 60)
    total = PASSED + FAILED
    print(f"Results: {PASSED} passed, {FAILED} failed, {SKIPPED} skipped, {total} total")
    if FAILED == 0:
        print("ALL TESTS PASSED")
    print("=" * 60)
    sys.exit(1 if FAILED > 0 else 0)


if __name__ == "__main__":
    main()
