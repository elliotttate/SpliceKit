#!/usr/bin/env python3
import importlib.util
import json
import sys
import types
import unittest
from pathlib import Path


class FakeFastMCP:
    def __init__(self, name, instructions=""):
        self.name = name
        self.instructions = instructions
        self.tools = []

    def tool(self, annotations=None):
        def decorator(func):
            self.tools.append(
                {
                    "name": func.__name__,
                    "annotations": dict(annotations or {}),
                    "func": func,
                }
            )
            return func

        return decorator


def load_server_module():
    repo_root = Path(__file__).resolve().parents[1]
    module_path = repo_root / "mcp" / "server.py"

    fake_mcp = types.ModuleType("mcp")
    fake_mcp_server = types.ModuleType("mcp.server")
    fake_fastmcp = types.ModuleType("mcp.server.fastmcp")
    fake_fastmcp.FastMCP = FakeFastMCP

    injected_modules = {
        "mcp": fake_mcp,
        "mcp.server": fake_mcp_server,
        "mcp.server.fastmcp": fake_fastmcp,
    }
    previous_modules = {name: sys.modules.get(name) for name in injected_modules}

    try:
        sys.modules.update(injected_modules)

        spec = importlib.util.spec_from_file_location("splicekit_mcp_server_under_test", module_path)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        return module
    finally:
        for name, previous in previous_modules.items():
            if previous is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = previous


class MCPToolAnnotationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_server_module()
        cls.tools = {tool["name"]: tool for tool in cls.module.mcp.tools}

    def test_every_registered_tool_has_required_annotations(self):
        required = {"readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint", "title"}
        self.assertGreater(len(self.tools), 0)
        for name, tool in self.tools.items():
            self.assertTrue(required.issubset(tool["annotations"]), name)

    def test_split_tools_are_registered(self):
        expected = {
            "background_render_status",
            "background_render_control",
            "mark_scene_changes",
            "blade_scene_changes",
            "history_action",
            "list_handles",
            "inspect_handle",
            "release_handle",
            "release_all_handles",
            "timeline_navigation_action",
            "timeline_edit_action",
            "timeline_destructive_action",
            "transcript_grep_analyze",
            "transcript_grep_jump",
            "transcript_grep_apply",
            "open_livecam",
            "close_livecam",
            "get_livecam_status",
        }
        self.assertTrue(expected.issubset(self.tools.keys()))

    def test_key_annotation_profiles_match_expected_behavior(self):
        checks = {
            "detect_scene_changes": {"readOnlyHint": True, "destructiveHint": False},
            "background_render_status": {"readOnlyHint": True, "destructiveHint": False},
            "background_render_control": {"readOnlyHint": False, "destructiveHint": False},
            "mark_scene_changes": {"readOnlyHint": False, "destructiveHint": False},
            "blade_scene_changes": {"readOnlyHint": False, "destructiveHint": True},
            "timeline_action": {"readOnlyHint": False, "destructiveHint": True},
            "timeline_navigation_action": {"readOnlyHint": False, "destructiveHint": False},
            "timeline_destructive_action": {"readOnlyHint": False, "destructiveHint": True},
            "history_action": {"readOnlyHint": False, "destructiveHint": True},
            "call_method": {"readOnlyHint": False, "destructiveHint": True},
            "manage_handles": {"readOnlyHint": False, "destructiveHint": False},
            "list_handles": {"readOnlyHint": True, "destructiveHint": False},
            "transcript_grep_analyze": {"readOnlyHint": True, "destructiveHint": False},
            "transcript_grep_jump": {"readOnlyHint": False, "destructiveHint": False},
            "transcript_grep_apply": {"readOnlyHint": False, "destructiveHint": True},
            "open_livecam": {"readOnlyHint": False, "destructiveHint": False},
            "close_livecam": {"readOnlyHint": False, "destructiveHint": False},
            "get_livecam_status": {"readOnlyHint": True, "destructiveHint": False},
        }
        for name, expected in checks.items():
            annotations = self.tools[name]["annotations"]
            for key, value in expected.items():
                self.assertEqual(annotations[key], value, f"{name} {key}")
            self.assertFalse(annotations["openWorldHint"], name)

    def test_scene_split_wrappers_forward_expected_bridge_calls(self):
        calls = []

        def fake_call(method, **params):
            calls.append((method, params))
            return {"method": method, "params": params}

        self.module.bridge.call = fake_call

        self.module.mark_scene_changes(threshold=0.2, sample_interval=0.25)
        self.module.blade_scene_changes(threshold=0.5, sample_interval=0.1)

        self.assertEqual(
            calls,
            [
                ("scene.detect", {"threshold": 0.2, "action": "markers", "sampleInterval": 0.25}),
                ("scene.detect", {"threshold": 0.5, "action": "blade", "sampleInterval": 0.1}),
            ],
        )

    def test_background_render_wrappers_forward_expected_bridge_calls(self):
        calls = []

        def fake_call(method, **params):
            calls.append((method, params))
            return {"method": method, "params": params}

        self.module.bridge.call = fake_call

        self.module.background_render_status()
        self.module.background_render_control("hold_off", 2.5)

        self.assertEqual(
            calls,
            [
                ("backgroundRender.status", {}),
                ("backgroundRender.control", {"action": "hold_off", "seconds": 2.5}),
            ],
        )

    def test_handle_split_wrappers_forward_expected_bridge_calls(self):
        calls = []

        def fake_call(method, **params):
            calls.append((method, params))
            return {"method": method, "params": params}

        self.module.bridge.call = fake_call

        self.module.list_handles()
        self.module.inspect_handle("obj_7")
        self.module.release_handle("obj_7")
        self.module.release_all_handles()

        self.assertEqual(
            calls,
            [
                ("object.list", {}),
                ("object.get", {"handle": "obj_7"}),
                ("object.release", {"handle": "obj_7"}),
                ("object.release", {"all": True}),
            ],
        )

    def test_timeline_split_wrappers_forward_expected_bridge_calls(self):
        calls = []

        def fake_call(method, **params):
            calls.append((method, params))
            return {"ok": True}

        self.module.bridge.call = fake_call

        self.module.timeline_navigation_action("nextEdit")
        self.module.timeline_edit_action("addMarker")
        self.module.timeline_destructive_action("blade")
        self.module.history_action("undo")

        self.assertEqual(
            calls,
            [
                ("timeline.action", {"action": "nextEdit"}),
                ("timeline.action", {"action": "addMarker"}),
                ("timeline.action", {"action": "blade"}),
                ("timeline.action", {"action": "undo"}),
            ],
        )

    def test_read_only_scene_tool_rejects_mutating_legacy_actions(self):
        result = self.module.detect_scene_changes(action="markers")
        self.assertIn("read-only", result)

    def test_timeline_split_wrappers_accept_documented_actions(self):
        self.module.bridge.call = lambda method, **params: {"ok": True, "action": params["action"]}

        self.assertIn("ok", self.module.timeline_navigation_action("enableBeatDetection"))
        self.assertIn("ok", self.module.timeline_navigation_action("nextKeyframe"))
        self.assertIn("ok", self.module.timeline_edit_action("addKeyframe"))
        self.assertIn("ok", self.module.timeline_edit_action("transcodeMedia"))

    def test_history_actions_are_rejected_by_non_destructive_split(self):
        result = self.module.timeline_edit_action("undo")
        self.assertIn("history_action()", result)

    def test_background_render_control_rejects_invalid_inputs(self):
        self.assertIn("action must be", self.module.background_render_control("pause", 1.0))
        self.assertIn("seconds must be > 0", self.module.background_render_control("hold_off", 0))

    def test_transcript_grep_wrappers_forward_expected_bridge_calls(self):
        calls = []

        def fake_call(method, **params):
            calls.append((method, params))
            return {"method": method, "params": params}

        self.module.bridge.call = fake_call

        self.module.transcript_grep_analyze(
            query="banana",
            scope="selected",
            search_mode="regex",
            match_mode="sentence",
            case_sensitive=True,
            whole_word=True,
            padding_before=0.25,
            padding_after=0.5,
            merge_nearby=True,
            merge_gap=0.4,
            dedupe_identical=True,
        )
        self.module.transcript_grep_jump(
            analysis_id="analysis-1",
            match_id="match-9",
            to_edit_start=True,
            set_range=True,
            play_around=True,
        )
        self.module.transcript_grep_apply(
            analysis_id="analysis-1",
            action="build_selects_project",
            project_name="Transcript Grep - banana",
            open_project_after=False,
            allow_repeated_apply=False,
            allow_experimental_connected_insert=False,
        )

        self.assertEqual(
            calls,
            [
                (
                    "transcriptGrep.analyze",
                    {
                        "query": "banana",
                        "scope": "selected",
                        "searchMode": "regex",
                        "matchMode": "sentence",
                        "caseSensitive": True,
                        "wholeWord": True,
                        "paddingBefore": 0.25,
                        "paddingAfter": 0.5,
                        "mergeNearby": True,
                        "mergeGap": 0.4,
                        "dedupeIdentical": True,
                    },
                ),
                (
                    "transcriptGrep.jump",
                    {
                        "analysisId": "analysis-1",
                        "toEditStart": True,
                        "setRange": True,
                        "playAround": True,
                        "matchId": "match-9",
                    },
                ),
                (
                    "transcriptGrep.apply",
                    {
                        "analysisId": "analysis-1",
                        "action": "build_selects_project",
                        "markerKind": "standard",
                        "openProject": False,
                        "allowRepeatedApply": False,
                        "allowExperimentalConnectedInsert": False,
                        "projectName": "Transcript Grep - banana",
                    },
                ),
            ],
        )

    def test_livecam_wrappers_forward_expected_bridge_calls(self):
        calls = []

        def fake_call(method, **params):
            calls.append((method, params))
            return {"method": method, "params": params}

        self.module.bridge.call = fake_call

        self.module.open_livecam()
        self.module.close_livecam()
        self.module.get_livecam_status()

        self.assertEqual(
            calls,
            [
                ("liveCam.show", {}),
                ("liveCam.hide", {}),
                ("liveCam.status", {}),
            ],
        )


if __name__ == "__main__":
    unittest.main()
