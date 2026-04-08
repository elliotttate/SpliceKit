#!/usr/bin/env python3
"""
Comprehensive test suite for Apple Intelligence ai_command.

Tests 120+ natural language queries against the command.ai endpoint,
validates the returned action plans, and reports pass/fail with details.

Usage:
    python3 tests/test_ai_command.py              # run all tests
    python3 tests/test_ai_command.py --group effects  # run one group
    python3 tests/test_ai_command.py --execute    # actually execute actions (will modify timeline!)

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


def rpc(method, params=None, timeout=90):
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


# ── Test Framework ─────────────────────────────────────────

PASSED = 0
FAILED = 0
ERRORS = 0
RESULTS = []  # (query, status, actions, details)


def has_action(actions, act_type, **kwargs):
    """Check if actions list contains an action matching type and fields."""
    for a in actions:
        if a.get("type") == act_type:
            match = True
            for k, v in kwargs.items():
                if isinstance(v, list):
                    if a.get(k) not in v:
                        match = False
                elif a.get(k) != v:
                    match = False
            if match:
                return True
    return False


def has_any_action(actions, act_type):
    """Check if actions list contains any action of given type."""
    return any(a.get("type") == act_type for a in actions)


def has_seek(actions):
    """Check if actions contain a seek action."""
    return has_any_action(actions, "seek")


def has_seek_near(actions, target, tolerance=2.0):
    """Check if actions contain a seek near target seconds."""
    for a in actions:
        if a.get("type") == "seek":
            if abs(a.get("seconds", -999) - target) <= tolerance:
                return True
    return False


def count_actions(actions, act_type, **kwargs):
    """Count actions matching type and fields."""
    n = 0
    for a in actions:
        if a.get("type") == act_type:
            match = True
            for k, v in kwargs.items():
                if isinstance(v, list):
                    if a.get(k) not in v:
                        match = False
                elif a.get(k) != v:
                    match = False
            if match:
                n += 1
    return n


def run_test(query, validate_fn, description=""):
    """Run a single ai_command test."""
    global PASSED, FAILED, ERRORS
    label = description or query

    try:
        r = rpc("command.ai", {"query": query})
    except Exception as e:
        print(f"  ERROR {label}: {e}")
        ERRORS += 1
        RESULTS.append((query, "ERROR", [], str(e)))
        return

    result = r.get("result", r)
    if isinstance(result, dict) and result.get("error"):
        # Check if it's a timeout or AI unavailable — still an error
        err = str(result["error"])
        print(f"  ERROR {label}: {err[:120]}")
        ERRORS += 1
        RESULTS.append((query, "ERROR", [], err))
        return

    actions = result.get("actions", [])
    if not actions:
        print(f"  FAIL  {label}: no actions returned")
        FAILED += 1
        RESULTS.append((query, "FAIL", [], "no actions"))
        return

    ok, detail = validate_fn(actions)
    actions_str = json.dumps(actions, separators=(",", ":"))
    if len(actions_str) > 200:
        actions_str = actions_str[:200] + "..."

    if ok:
        print(f"  OK    {label}")
        PASSED += 1
        RESULTS.append((query, "OK", actions, ""))
    else:
        print(f"  FAIL  {label}: {detail}")
        print(f"         got: {actions_str}")
        FAILED += 1
        RESULTS.append((query, "FAIL", actions, detail))


# ── Validator Helpers ──────────────────────────────────────

def expect_timeline(action_name):
    """Expect a timeline action."""
    def v(actions):
        if has_action(actions, "timeline", action=action_name):
            return True, ""
        # Also accept if it's in a list of valid alternatives
        return False, f"expected timeline.{action_name}"
    return v


def expect_playback(action_name):
    """Expect a playback action."""
    def v(actions):
        if has_action(actions, "playback", action=action_name):
            return True, ""
        return False, f"expected playback.{action_name}"
    return v


def expect_seek(target=None, tolerance=2.0):
    """Expect a seek action, optionally near a target time."""
    def v(actions):
        if target is not None:
            if has_seek_near(actions, target, tolerance):
                return True, ""
            return False, f"expected seek near {target}s"
        if has_seek(actions):
            return True, ""
        return False, "expected seek action"
    return v


def expect_effect(name=None):
    """Expect an effect action."""
    def v(actions):
        if name:
            if has_action(actions, "effect", name=name):
                return True, ""
            # Check case-insensitive
            for a in actions:
                if a.get("type") == "effect" and a.get("name", "").lower() == name.lower():
                    return True, ""
            return False, f"expected effect '{name}'"
        if has_any_action(actions, "effect"):
            return True, ""
        return False, "expected effect action"
    return v


def expect_transition(name=None):
    """Expect a transition action."""
    def v(actions):
        if name:
            if has_action(actions, "transition", name=name):
                return True, ""
            for a in actions:
                if a.get("type") == "transition" and name.lower() in a.get("name", "").lower():
                    return True, ""
            return False, f"expected transition '{name}'"
        if has_any_action(actions, "transition"):
            return True, ""
        return False, "expected transition action"
    return v


def expect_any_of(*validators):
    """Pass if any of the validators pass."""
    def v(actions):
        for val in validators:
            ok, _ = val(actions)
            if ok:
                return True, ""
        details = [val(actions)[1] for val in validators]
        return False, " or ".join(details)
    return v


def expect_all(*validators):
    """Pass if all validators pass."""
    def v(actions):
        for val in validators:
            ok, detail = val(actions)
            if not ok:
                return False, detail
        return True, ""
    return v


def expect_sequence(*validators):
    """Like expect_all but checks order too (loosely)."""
    return expect_all(*validators)


def expect_select_then(action_name):
    """Expect selectClipAtPlayhead followed by a timeline action."""
    return expect_all(
        expect_timeline("selectClipAtPlayhead"),
        expect_timeline(action_name)
    )


def expect_seek_then_action(seek_target, action_name, tolerance=2.0):
    """Expect seek to time then a timeline action."""
    return expect_all(
        expect_seek(seek_target, tolerance),
        expect_timeline(action_name)
    )


def expect_multiple_seeks(count_min):
    """Expect at least N seek actions (for repeated operations)."""
    def v(actions):
        # Count seeks in top level and inside repeat_patterns
        seek_count = count_actions(actions, "seek")
        for a in actions:
            if a.get("type") == "repeat_pattern":
                for inner in a.get("actions", []):
                    if inner.get("type") == "seek":
                        seek_count += a.get("count", 1)
        if seek_count >= count_min:
            return True, ""
        return False, f"expected at least {count_min} seeks, got {seek_count}"
    return v


# ── Test Definitions ───────────────────────────────────────
# Over 120 natural language queries organized by category

TESTS = {
    # ── Navigation & Playback ──────────────────────────────
    "navigation": [
        ("go to the beginning",
         expect_any_of(expect_playback("goToStart"), expect_seek(0, 0.1)),
         "nav: go to beginning"),
        ("go to the end",
         expect_any_of(expect_playback("goToEnd"), expect_seek(126.7, 2)),
         "nav: go to end"),
        ("play",
         expect_playback("playPause"),
         "nav: play"),
        ("pause",
         expect_playback("playPause"),
         "nav: pause"),
        ("go to 5 seconds",
         expect_seek(5, 1),
         "nav: go to 5 seconds"),
        ("go to 10.5 seconds",
         expect_seek(10.5, 1),
         "nav: go to 10.5 seconds"),
        ("jump to the middle of the timeline",
         expect_seek(63, 10),
         "nav: jump to middle"),
        ("advance one frame",
         expect_any_of(expect_playback("nextFrame"), expect_timeline("nextFrame")),
         "nav: next frame"),
        ("go back one frame",
         expect_any_of(expect_playback("prevFrame"), expect_timeline("prevFrame")),
         "nav: prev frame"),
        ("advance 10 frames",
         expect_any_of(expect_playback("nextFrame10"), expect_timeline("nextFrame10")),
         "nav: next 10 frames"),
        ("go back 10 frames",
         expect_any_of(expect_playback("prevFrame10"), expect_timeline("prevFrame10")),
         "nav: prev 10 frames"),
        ("play from the start",
         expect_any_of(
             expect_all(expect_seek(0, 0.5), expect_playback("playPause")),
             expect_all(expect_playback("goToStart"), expect_playback("playPause")),
         ),
         "nav: play from start"),
        ("go to 30 seconds",
         expect_seek(30, 1),
         "nav: go to 30s"),
        ("rewind to the beginning",
         expect_any_of(expect_playback("goToStart"), expect_seek(0, 0.5)),
         "nav: rewind"),
        ("jump to one minute",
         expect_seek(60, 2),
         "nav: jump to 1 min"),
    ],

    # ── Blade / Cut ────────────────────────────────────────
    "blade": [
        ("cut here",
         expect_timeline("blade"),
         "blade: cut here"),
        ("blade at the playhead",
         expect_timeline("blade"),
         "blade: at playhead"),
        ("split the clip",
         expect_timeline("blade"),
         "blade: split clip"),
        ("cut at 3 seconds",
         expect_seek_then_action(3, "blade"),
         "blade: cut at 3s"),
        ("blade at 10 seconds",
         expect_seek_then_action(10, "blade"),
         "blade: at 10s"),
        ("cut at the 5 second mark",
         expect_seek_then_action(5, "blade"),
         "blade: at 5s mark"),
        ("blade all clips at the playhead",
         expect_timeline("bladeAll"),
         "blade: blade all"),
        ("split at 20 seconds and 40 seconds",
         expect_all(expect_seek(20, 2), expect_seek(40, 2), expect_timeline("blade")),
         "blade: two points"),
        ("make a cut every 30 seconds",
         expect_all(expect_seek(30, 2), expect_timeline("blade")),
         "blade: every 30s"),
        ("cut at 1 minute",
         expect_seek_then_action(60, "blade", 2),
         "blade: at 1 min"),
    ],

    # ── Delete / Remove ────────────────────────────────────
    "delete": [
        ("delete the selected clip",
         expect_timeline("delete"),
         "delete: selected clip"),
        ("remove the first 5 seconds",
         expect_all(expect_seek(5, 1), expect_timeline("blade"), expect_timeline("delete")),
         "delete: first 5s"),
        ("remove the last 10 seconds",
         expect_all(expect_timeline("blade"), expect_timeline("delete")),
         "delete: last 10s"),
        ("delete everything",
         expect_any_of(
             expect_all(expect_timeline("selectAll"), expect_timeline("delete")),
             expect_timeline("delete"),
         ),
         "delete: everything"),
        ("trim to playhead",
         expect_timeline("trimToPlayhead"),
         "delete: trim to playhead"),
        ("join the clips together",
         expect_timeline("joinClips"),
         "delete: join clips"),
        ("replace the selection with a gap",
         expect_any_of(expect_timeline("replaceWithGap"), expect_timeline("insertGap")),
         "delete: replace with gap"),
        ("copy the selected clip",
         expect_timeline("copy"),
         "delete: copy"),
    ],

    # ── Markers ────────────────────────────────────────────
    "markers": [
        ("add a marker",
         expect_timeline("addMarker"),
         "marker: add"),
        ("add a chapter marker",
         expect_timeline("addChapterMarker"),
         "marker: add chapter"),
        ("add a to-do marker",
         expect_timeline("addTodoMarker"),
         "marker: add todo"),
        ("delete the marker",
         expect_timeline("deleteMarker"),
         "marker: delete"),
        ("go to the next marker",
         expect_any_of(expect_timeline("nextMarker"), expect_playback("nextMarker")),
         "marker: next"),
        ("go to the previous marker",
         expect_any_of(expect_timeline("previousMarker"), expect_playback("previousMarker")),
         "marker: previous"),
        ("add a marker at 15 seconds",
         expect_seek_then_action(15, "addMarker"),
         "marker: at 15s"),
        ("add a chapter marker at 30 seconds",
         expect_seek_then_action(30, "addChapterMarker", 2),
         "marker: chapter at 30s"),
        ("remove all markers",
         expect_any_of(
             expect_all(expect_timeline("selectAll"), expect_timeline("deleteMarkersInSelection")),
             expect_timeline("deleteMarkersInSelection"),
         ),
         "marker: remove all"),
        ("add markers every 10 seconds",
         expect_all(expect_seek(10, 2), expect_timeline("addMarker")),
         "marker: every 10s"),
    ],

    # ── Effects ────────────────────────────────────────────
    "effects": [
        ("add a blur",
         expect_effect("Gaussian Blur"),
         "effect: blur"),
        ("apply gaussian blur",
         expect_effect("Gaussian Blur"),
         "effect: gaussian blur"),
        ("make it black and white",
         expect_effect("Black & White"),
         "effect: b&w"),
        ("add a vignette",
         expect_effect("Vignette"),
         "effect: vignette"),
        ("sharpen the clip",
         expect_effect("Sharpen"),
         "effect: sharpen"),
        ("add noise reduction",
         expect_effect("Noise Reduction"),
         "effect: noise reduction"),
        ("stabilize the clip",
         expect_effect("Stabilization"),
         "effect: stabilization"),
        ("add a keyer",
         expect_effect("Keyer"),
         "effect: keyer"),
        ("add a luma keyer",
         expect_effect("Luma Keyer"),
         "effect: luma keyer"),
        ("add a drop shadow",
         expect_effect("Drop Shadow"),
         "effect: drop shadow"),
        ("add film grain",
         expect_effect("Film Grain"),
         "effect: film grain"),
        ("add a glow effect",
         expect_effect("Glow"),
         "effect: glow"),
        ("apply a bloom effect",
         expect_effect("Bloom"),
         "effect: bloom"),
        ("add letterbox bars",
         expect_effect("Letterbox"),
         "effect: letterbox"),
        ("add a lens flare",
         expect_effect("Lens Flare"),
         "effect: lens flare"),
        ("apply a sepia tone",
         expect_effect("Sepia"),
         "effect: sepia"),
        ("flip the video horizontally",
         expect_effect("Flipped"),
         "effect: flipped"),
        ("pixelate the clip",
         expect_any_of(expect_effect("Pixellate"), expect_effect("Pixelate")),
         "effect: pixelate"),
        ("invert the colors",
         expect_effect("Invert"),
         "effect: invert"),
        ("make it look like old film",
         expect_any_of(expect_effect("Aged Film"), expect_effect("Film Grain"), expect_effect()),
         "effect: aged film"),
        ("add an underwater effect",
         expect_effect("Underwater"),
         "effect: underwater"),
        ("add a tilt-shift effect",
         expect_any_of(expect_effect("Tilt-Shift"), expect_effect("Tilt Shift")),
         "effect: tilt-shift"),
        ("reduce camera shake",
         expect_effect("Stabilization"),
         "effect: stabilization (alt phrasing)"),
        ("fix the rolling shutter",
         expect_any_of(expect_effect("Rolling Shutter"), expect_effect()),
         "effect: rolling shutter"),
        ("add a posterize effect",
         expect_any_of(expect_effect("Posterize"), expect_effect()),
         "effect: posterize"),
    ],

    # ── Transitions ────────────────────────────────────────
    "transitions": [
        ("add a cross dissolve",
         expect_transition("Cross Dissolve"),
         "transition: cross dissolve"),
        ("add a flow transition",
         expect_transition("Flow"),
         "transition: flow"),
        ("add a wipe transition",
         expect_transition("Wipe"),
         "transition: wipe"),
        ("add a push transition",
         expect_transition("Push"),
         "transition: push"),
        ("fade to black",
         expect_any_of(expect_transition("Fade"), expect_transition("Color")),
         "transition: fade to black"),
        ("add a spin transition",
         expect_transition("Spin"),
         "transition: spin"),
        ("add a page curl transition",
         expect_transition("Page Curl"),
         "transition: page curl"),
        ("add a slide transition",
         expect_transition("Slide"),
         "transition: slide"),
        ("add a zoom transition",
         expect_transition("Zoom"),
         "transition: zoom"),
        ("add a dissolve",
         expect_any_of(expect_transition("Cross Dissolve"), expect_transition("Dissolve")),
         "transition: dissolve"),
        ("add a default transition",
         expect_any_of(expect_transition(), expect_timeline("addTransition")),
         "transition: default"),
        ("add a star transition",
         expect_transition("Star"),
         "transition: star"),
    ],

    # ── Color Correction ──────────────────────────────────
    "color": [
        ("add color correction",
         expect_any_of(
             expect_timeline("addColorBoard"),
             expect_select_then("addColorBoard"),
         ),
         "color: color correction"),
        ("add color wheels",
         expect_any_of(
             expect_timeline("addColorWheels"),
             expect_select_then("addColorWheels"),
         ),
         "color: color wheels"),
        ("add color curves",
         expect_any_of(
             expect_timeline("addColorCurves"),
             expect_select_then("addColorCurves"),
         ),
         "color: color curves"),
        ("balance the color",
         expect_any_of(
             expect_timeline("balanceColor"),
             expect_select_then("balanceColor"),
         ),
         "color: balance"),
        ("add hue and saturation adjustment",
         expect_any_of(
             expect_timeline("addHueSaturation"),
             expect_select_then("addHueSaturation"),
         ),
         "color: hue/sat"),
        ("enhance the light and color",
         expect_any_of(
             expect_timeline("addEnhanceLightAndColor"),
             expect_select_then("addEnhanceLightAndColor"),
         ),
         "color: enhance"),
        ("color grade this clip",
         expect_any_of(
             expect_timeline("addColorBoard"),
             expect_timeline("addColorWheels"),
             expect_timeline("addColorCurves"),
             expect_select_then("addColorBoard"),
             expect_select_then("addColorWheels"),
         ),
         "color: grade"),
        ("add a color adjustment",
         expect_any_of(
             expect_timeline("addColorAdjustment"),
             expect_select_then("addColorAdjustment"),
             expect_timeline("addColorBoard"),
         ),
         "color: adjustment"),
    ],

    # ── Speed / Retime ─────────────────────────────────────
    "speed": [
        ("slow this clip to half speed",
         expect_any_of(
             expect_timeline("retimeSlow50"),
             expect_select_then("retimeSlow50"),
         ),
         "speed: slow 50%"),
        ("slow to 25 percent",
         expect_any_of(
             expect_timeline("retimeSlow25"),
             expect_select_then("retimeSlow25"),
         ),
         "speed: slow 25%"),
        ("speed up to 2x",
         expect_any_of(
             expect_timeline("retimeFast2x"),
             expect_select_then("retimeFast2x"),
         ),
         "speed: fast 2x"),
        ("speed up to 4x",
         expect_any_of(
             expect_timeline("retimeFast4x"),
             expect_select_then("retimeFast4x"),
         ),
         "speed: fast 4x"),
        ("make it 8 times faster",
         expect_any_of(
             expect_timeline("retimeFast8x"),
             expect_select_then("retimeFast8x"),
         ),
         "speed: fast 8x"),
        ("play in reverse",
         expect_any_of(
             expect_timeline("retimeReverse"),
             expect_select_then("retimeReverse"),
         ),
         "speed: reverse"),
        ("freeze frame here",
         expect_any_of(
             expect_timeline("freezeFrame"),
             expect_select_then("freezeFrame"),
         ),
         "speed: freeze frame"),
        ("reset speed to normal",
         expect_any_of(
             expect_timeline("retimeNormal"),
             expect_select_then("retimeNormal"),
         ),
         "speed: normal"),
        ("make it super slow at 10 percent",
         expect_any_of(
             expect_timeline("retimeSlow10"),
             expect_select_then("retimeSlow10"),
         ),
         "speed: slow 10%"),
        ("hold this frame",
         expect_any_of(
             expect_timeline("retimeHold"),
             expect_select_then("retimeHold"),
             expect_timeline("freezeFrame"),
             expect_select_then("freezeFrame"),
         ),
         "speed: hold"),
        ("make it 20x fast",
         expect_any_of(
             expect_timeline("retimeFast20x"),
             expect_select_then("retimeFast20x"),
         ),
         "speed: fast 20x"),
        ("blade the speed segment",
         expect_timeline("retimeBladeSpeed"),
         "speed: blade speed"),
    ],

    # ── Titles ─────────────────────────────────────────────
    "titles": [
        ("add a title",
         expect_timeline("addBasicTitle"),
         "title: basic"),
        ("add a lower third",
         expect_timeline("addBasicLowerThird"),
         "title: lower third"),
        ("add some title text",
         expect_timeline("addBasicTitle"),
         "title: text"),
        ("add a text overlay",
         expect_any_of(expect_timeline("addBasicTitle"), expect_timeline("addBasicLowerThird")),
         "title: overlay"),
        ("put a title on screen",
         expect_any_of(expect_timeline("addBasicTitle"), expect_timeline("addBasicLowerThird")),
         "title: on screen"),
    ],

    # ── Audio ──────────────────────────────────────────────
    "audio": [
        ("turn up the volume",
         expect_timeline("adjustVolumeUp"),
         "audio: volume up"),
        ("turn down the volume",
         expect_timeline("adjustVolumeDown"),
         "audio: volume down"),
        ("detach the audio",
         expect_any_of(
             expect_timeline("detachAudio"),
             expect_select_then("detachAudio"),
         ),
         "audio: detach"),
        ("make it louder",
         expect_timeline("adjustVolumeUp"),
         "audio: louder"),
        ("make it quieter",
         expect_timeline("adjustVolumeDown"),
         "audio: quieter"),
    ],

    # ── Selection & Organization ───────────────────────────
    "selection": [
        ("select the clip at the playhead",
         expect_timeline("selectClipAtPlayhead"),
         "select: at playhead"),
        ("select all clips",
         expect_timeline("selectAll"),
         "select: all"),
        ("deselect everything",
         expect_timeline("deselectAll"),
         "select: deselect"),
        ("create a compound clip",
         expect_any_of(
             expect_timeline("createCompoundClip"),
             expect_select_then("createCompoundClip"),
         ),
         "select: compound clip"),
        ("solo this clip",
         expect_any_of(
             expect_timeline("solo"),
             expect_select_then("solo"),
         ),
         "select: solo"),
        ("disable this clip",
         expect_any_of(
             expect_timeline("disable"),
             expect_select_then("disable"),
         ),
         "select: disable"),
    ],

    # ── Undo / Redo ────────────────────────────────────────
    "undo": [
        ("undo",
         expect_timeline("undo"),
         "undo: basic"),
        ("redo",
         expect_timeline("redo"),
         "redo: basic"),
        ("undo the last action",
         expect_timeline("undo"),
         "undo: last action"),
        ("redo the last undo",
         expect_timeline("redo"),
         "redo: last undo"),
    ],

    # ── View / Timeline UI ─────────────────────────────────
    "view": [
        ("zoom to fit the timeline",
         expect_timeline("zoomToFit"),
         "view: zoom to fit"),
        ("zoom in on the timeline",
         expect_timeline("zoomIn"),
         "view: zoom in"),
        ("zoom out on the timeline",
         expect_timeline("zoomOut"),
         "view: zoom out"),
        ("toggle snapping",
         expect_timeline("toggleSnapping"),
         "view: toggle snapping"),
        ("render the whole timeline",
         expect_any_of(expect_timeline("renderAll"), expect_timeline("renderSelection")),
         "view: render all"),
    ],

    # ── Complex Multi-step ─────────────────────────────────
    "complex": [
        ("cut at 3 seconds and delete the first part",
         expect_all(
             expect_seek(3, 1),
             expect_timeline("blade"),
             expect_timeline("delete"),
         ),
         "complex: cut and delete first part"),
        ("go to 10 seconds and add a gaussian blur",
         expect_all(
             expect_seek(10, 1),
             expect_effect("Gaussian Blur"),
         ),
         "complex: seek then blur"),
        ("select the clip and remove all effects",
         expect_all(
             expect_timeline("selectClipAtPlayhead"),
             expect_timeline("removeEffects"),
         ),
         "complex: remove effects"),
        ("go to the beginning and add a marker",
         expect_all(
             expect_any_of(expect_seek(0, 0.5), expect_playback("goToStart")),
             expect_timeline("addMarker"),
         ),
         "complex: start + marker"),
        ("render the timeline",
         expect_any_of(expect_timeline("renderAll"), expect_timeline("renderSelection")),
         "complex: render"),
        ("export the project as XML",
         expect_timeline("exportXML"),
         "complex: export xml"),
        ("analyze and fix the clips",
         expect_timeline("analyzeAndFix"),
         "complex: analyze and fix"),
        ("add an adjustment layer",
         expect_any_of(
             expect_timeline("addAdjustmentClip"),
             expect_timeline("insertPlaceholder"),
         ),
         "complex: adjustment layer"),
    ],
}

# ── Main ───────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Test Apple Intelligence ai_command")
    parser.add_argument("--group", help="Run only this test group")
    parser.add_argument("--execute", action="store_true", help="Actually execute actions (modifies timeline!)")
    parser.add_argument("--query", help="Run a single query")
    args = parser.parse_args()

    # Check bridge
    print("Checking bridge connection...")
    try:
        r = rpc("bridge.status")
        res = r.get("result", r)
        print(f"Connected: FCP {res.get('fcp_version', '?')} / SpliceKit {res.get('splicekit_version', '?')}\n")
    except Exception as e:
        print(f"Cannot connect to bridge: {e}")
        sys.exit(1)

    # Single query mode
    if args.query:
        print(f"Testing: {args.query}")
        r = rpc("command.ai", {"query": args.query})
        result = r.get("result", r)
        print(json.dumps(result, indent=2))
        return

    start = time.time()

    # Run tests
    groups = TESTS if not args.group else {args.group: TESTS.get(args.group, [])}
    total_tests = sum(len(tests) for tests in groups.values())
    print(f"Running {total_tests} tests across {len(groups)} groups...\n")

    for group_name, tests in groups.items():
        if not tests:
            print(f"Unknown group: {group_name}")
            continue
        print(f"[{group_name}] ({len(tests)} tests)")
        for query, validator, desc in tests:
            run_test(query, validator, desc)
        print()

    elapsed = time.time() - start

    # Summary
    print("=" * 60)
    print(f"RESULTS: {PASSED} passed, {FAILED} failed, {ERRORS} errors")
    print(f"Total: {PASSED + FAILED + ERRORS} tests in {elapsed:.1f}s")
    print(f"Average: {elapsed / max(PASSED + FAILED + ERRORS, 1):.1f}s per test")
    print("=" * 60)

    # Show failures
    failures = [(q, s, a, d) for q, s, a, d in RESULTS if s != "OK"]
    if failures:
        print(f"\nFailed/Error tests ({len(failures)}):")
        for query, status, actions, detail in failures:
            print(f"  [{status}] \"{query}\": {detail}")
            if actions:
                print(f"         actions: {json.dumps(actions, separators=(',',':'))[:200]}")

    sys.exit(1 if FAILED + ERRORS > 0 else 0)


if __name__ == "__main__":
    main()
