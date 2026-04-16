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
        self.resources = []
        self.prompts = []

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

    def resource(self, uri, **kwargs):
        def decorator(func):
            self.resources.append({"uri": uri, "func": func, **kwargs})
            return func
        return decorator

    def prompt(self, **kwargs):
        def decorator(func):
            self.prompts.append({"func": func, **kwargs})
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
            "mixer_set_solo",
            "mixer_set_mute",
            "mixer_apply_bus_effect",
            "mixer_open_bus_effect",
            "mixer_set_bus_effect_enabled",
            "mixer_remove_bus_effect",
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

    def test_mixer_solo_mute_wrappers_forward_expected_bridge_calls(self):
        calls = []

        def fake_call(method, **params):
            calls.append((method, params))
            if method == "mixer.setSolo":
                return {"ok": True, "role": "Dialogue", "soloed": True, "soloObjectCount": 2}
            if method == "mixer.setMute":
                return {"ok": True, "role": "Music", "muted": False, "roleUIDCount": 1}
            if method == "mixer.openBusEffect":
                return {"ok": True, "role": "Music", "effect": {"name": "Channel EQ"}, "effectIndex": 0}
            if method == "mixer.setBusEffectEnabled":
                return {"ok": True, "role": "Music", "enabled": False, "effectIndex": 0}
            if method == "mixer.removeBusEffect":
                return {"ok": True, "role": "Music", "effectIndex": 0, "busObjectCount": 1}
            return {"ok": True, "role": "Music", "effect": {"name": "Channel EQ"}, "busObjectCount": 1}

        self.module.bridge.call = fake_call

        solo_result = self.module.mixer_set_solo(index=0, mode="exclusive")
        mute_result = self.module.mixer_set_mute(role="Music", mode="unmute")
        bus_result = self.module.mixer_apply_bus_effect(name="Channel EQ", role="Music", dry_run=True)
        open_result = self.module.mixer_open_bus_effect(effect_index=0, role="Music")
        disable_result = self.module.mixer_set_bus_effect_enabled(effect_index=0, enabled=False, role="Music")
        remove_result = self.module.mixer_remove_bus_effect(effect_index=0, role="Music")

        self.assertIn("Dialogue: soloed", solo_result)
        self.assertIn("Music: unmuted", mute_result)
        self.assertIn("Channel EQ -> Music", bus_result)
        self.assertIn("Opened Channel EQ editor", open_result)
        self.assertIn("Music: disabled", disable_result)
        self.assertIn("Removed mixer bus effect 0 from Music", remove_result)
        self.assertEqual(
            calls,
            [
                ("mixer.setSolo", {"mode": "exclusive", "index": 0}),
                ("mixer.setMute", {"mode": "unmute", "role": "Music"}),
                ("mixer.applyBusEffect", {
                    "dryRun": True,
                    "allowObjectFallback": False,
                    "name": "Channel EQ",
                    "role": "Music",
                }),
                ("mixer.openBusEffect", {
                    "effectIndex": 0,
                    "allowObjectFallback": False,
                    "role": "Music",
                }),
                ("mixer.setBusEffectEnabled", {
                    "effectIndex": 0,
                    "enabled": False,
                    "allowObjectFallback": False,
                    "role": "Music",
                }),
                ("mixer.removeBusEffect", {
                    "effectIndex": 0,
                    "allowObjectFallback": False,
                    "role": "Music",
                }),
            ],
        )

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
        self.assertIn("ok", self.module.timeline_destructive_action("removeAllKeyframesFromClip"))
        self.assertIn("ok", self.module.timeline_edit_action("transcodeMedia"))

    def test_history_actions_are_rejected_by_non_destructive_split(self):
        result = self.module.timeline_edit_action("undo")
        self.assertIn("history_action()", result)

    def test_background_render_control_rejects_invalid_inputs(self):
        self.assertIn("action must be", self.module.background_render_control("pause", 1.0))
        self.assertIn("seconds must be > 0", self.module.background_render_control("hold_off", 0))

    def test_trim_clips_to_beats_forwards_expected_bridge_call(self):
        calls = []

        def fake_call(method, params_dict=None, **params):
            if params_dict is not None:
                params = {**params_dict, **params}
            calls.append((method, params))
            return {
                "status": "ok",
                "dryRun": True,
                "grid": "half_beat",
                "randomize": True,
                "randomSeed": 99,
                "gridPointCount": 3,
                "gridPreview": [1.0, 1.5, 2.0],
                "planned": 1,
                "applied": 0,
                "source": {"name": "Song", "tempo": 120.0},
                "plan": [
                    {
                        "name": "Clip A",
                        "start": 5.0,
                        "targetEnd": 6.5,
                        "trimAmount": 1.0,
                        "newDuration": 1.5,
                        "status": "planned",
                    }
                ],
            }

        self.module.bridge.call = fake_call

        result = self.module.trim_clips_to_beats(
            grid="half_beat",
            randomize=True,
            random_min_step=2,
            random_max_step=5,
            random_seed=99,
            min_trim_seconds=0.2,
            min_result_duration=0.5,
            source_handle="obj_10",
            target_handles='["obj_11","obj_12"]',
            dry_run=True,
        )

        self.assertIn("Previewing 0/1 planned trims", result)
        self.assertEqual(
            calls,
            [
                (
                    "timeline.trimClipsToBeats",
                    {
                        "grid": "half_beat",
                        "randomize": True,
                        "randomMinStep": 2,
                        "randomMaxStep": 5,
                        "randomSeed": 99,
                        "dryRun": True,
                        "minTrimSeconds": 0.2,
                        "minResultDuration": 0.5,
                        "sourceHandle": "obj_10",
                        "targetHandles": ["obj_11", "obj_12"],
                        "targetMode": "auto",
                    },
                )
            ],
        )

    def test_trim_clips_to_beats_rejects_invalid_target_handle_json(self):
        result = self.module.trim_clips_to_beats(target_handles="{bad json")
        self.assertIn("Invalid target_handles JSON", result)

    def test_sync_clips_to_song_beats_uses_overlay_shortcut(self):
        calls = []

        def fake_call(method, params_dict=None, **params):
            if params_dict is not None:
                params = {**params_dict, **params}
            calls.append((method, params))
            return {
                "status": "ok",
                "dryRun": True,
                "grid": "random_half_beat",
                "targetMode": "overlay",
                "randomize": True,
                "randomSeed": 77,
                "gridPointCount": 4,
                "gridPreview": [0.5, 1.0, 1.5],
                "planned": 2,
                "applied": 0,
                "source": {"name": "Song", "tempo": 128.0},
                "plan": [],
            }

        self.module.bridge.call = fake_call

        result = self.module.sync_clips_to_song_beats(
            mode="random_half_beat",
            overlay_only=True,
            random_min_step=2,
            random_max_step=3,
            random_seed=77,
            dry_run=True,
        )

        self.assertIn("targets=overlay", result)
        self.assertEqual(
            calls,
            [
                (
                    "timeline.trimClipsToBeats",
                    {
                        "grid": "random_half_beat",
                        "targetMode": "overlay",
                        "randomize": True,
                        "randomMinStep": 2,
                        "randomMaxStep": 3,
                        "randomSeed": 77,
                        "dryRun": True,
                    },
                )
            ],
        )

    def test_assemble_random_clips_to_song_beats_forwards_expected_bridge_call(self):
        calls = []

        def fake_call(method, params_dict=None, **params):
            if params_dict is not None:
                params = {**params_dict, **params}
            calls.append((method, params))
            return {
                "status": "ok",
                "dryRun": True,
                "grid": "bar",
                "projectName": "Beat Cut",
                "randomSeed": 12,
                "segmentCount": 3,
                "assignedClipCount": 2,
                "gapCount": 1,
                "clipPoolCount": 9,
                "source": {"name": "Song", "tempo": 122.0},
                "plan": [
                    {"clipName": "Clip A", "timelineStartSeconds": 0.0, "durationSeconds": 1.0, "clipEvent": "Beat Tests", "status": "planned"},
                    {"segmentIndex": 1, "timelineStartSeconds": 1.0, "durationSeconds": 1.0, "status": "gap"},
                ],
            }

        self.module.bridge.call = fake_call

        result = self.module.assemble_random_clips_to_song_beats(
            grid="bar",
            project_name="Beat Cut",
            event_name="Beat Tests",
            clip_handles='["obj_20","obj_21"]',
            source_handle="obj_10",
            segment_min_step=1,
            segment_max_step=3,
            max_segments=12,
            random_seed=12,
            allow_clip_reuse=False,
            include_audio=True,
            dry_run=True,
        )

        self.assertIn("Previewing 2/3 beat segments", result)
        self.assertEqual(
            calls,
            [
                (
                    "timeline.assembleRandomClipsToBeats",
                    {
                        "grid": "bar",
                        "projectName": "Beat Cut",
                        "segmentMinStep": 1,
                        "segmentMaxStep": 3,
                        "randomSeed": 12,
                        "allowClipReuse": False,
                        "includeAudio": True,
                        "buildMode": "native",
                        "targetCurrentTimeline": False,
                        "dryRun": True,
                        "eventName": "Beat Tests",
                        "clipHandles": ["obj_20", "obj_21"],
                        "sourceHandle": "obj_10",
                        "maxSegments": 12,
                    },
                )
            ],
        )

    def test_assemble_random_clips_to_song_beats_rejects_invalid_clip_handle_json(self):
        result = self.module.assemble_random_clips_to_song_beats(clip_handles="{bad json")
        self.assertIn("Invalid clip_handles JSON", result)

    def test_build_song_cut_maps_aggressive_preset(self):
        calls = []

        def fake_call(method, params_dict=None, **params):
            if params_dict is not None:
                params = {**params_dict, **params}
            calls.append((method, params))
            return {
                "status": "ok",
                "dryRun": True,
                "grid": "quarter_beat",
                "projectName": "Song Cut Demo",
                "randomSeed": 9,
                "segmentCount": 4,
                "assignedClipCount": 4,
                "gapCount": 0,
                "clipPoolCount": 12,
                "source": {"name": "Song", "tempo": 122.0},
                "plan": [],
            }

        self.module.bridge.call = fake_call

        result = self.module.build_song_cut(
            pace="aggressive",
            project_name="Song Cut Demo",
            event_name="Beat Tests",
            source_handle="obj_99",
            max_segments=20,
            random_seed=9,
            dry_run=True,
        )

        self.assertIn("Preset: aggressive", result)
        self.assertIn("Song attached underneath generated primary storyline", result)
        self.assertEqual(
            calls,
            [
                (
                    "timeline.assembleRandomClipsToBeats",
                    {
                        "grid": "quarter_beat",
                        "projectName": "Song Cut Demo",
                        "segmentMinStep": 1,
                        "segmentMaxStep": 4,
                        "randomSeed": 9,
                        "allowClipReuse": True,
                        "includeAudio": True,
                        "buildMode": "native",
                        "targetCurrentTimeline": False,
                        "dryRun": True,
                        "eventName": "Beat Tests",
                        "sourceHandle": "obj_99",
                        "maxSegments": 20,
                    },
                )
            ],
        )

    def test_build_song_cut_maps_natural_preset_with_weighted_steps(self):
        calls = []

        def fake_call(method, params_dict=None, **params):
            if params_dict is not None:
                params = {**params_dict, **params}
            calls.append((method, params))
            return {
                "status": "ok",
                "dryRun": True,
                "buildMethod": "fcpxml",
                "grid": "half_beat",
                "projectName": "Song Cut Natural",
                "randomSeed": 42,
                "segmentCount": 8,
                "assignedClipCount": 8,
                "gapCount": 0,
                "clipPoolCount": 6,
                "source": {"name": "Song", "tempo": 122.0},
                "plan": [],
            }

        self.module.bridge.call = fake_call

        result = self.module.build_song_cut(
            project_name="Song Cut Natural",
            build_mode="fcpxml",
            random_seed=42,
            dry_run=True,
        )

        self.assertIn("Preset: natural", result)
        self.assertIn("Build mode: fcpxml", result)
        self.assertEqual(
            calls,
            [
                (
                    "timeline.assembleRandomClipsToBeats",
                    {
                        "grid": "half_beat",
                        "projectName": "Song Cut Natural",
                        "segmentMinStep": 1,
                        "segmentMaxStep": 4,
                        "stepWeights": {"1": 1, "2": 8, "4": 3},
                        "randomSeed": 42,
                        "allowClipReuse": True,
                        "includeAudio": True,
                        "buildMode": "fcpxml",
                        "targetCurrentTimeline": False,
                        "dryRun": True,
                    },
                )
            ],
        )

    def test_build_song_cut_forwards_sequence_backed_source_and_current_timeline(self):
        calls = []

        def fake_call(method, params_dict=None, **params):
            if params_dict is not None:
                params = {**params_dict, **params}
            calls.append((method, params))
            return {
                "status": "ok",
                "dryRun": True,
                "buildMethod": "native",
                "grid": "half_beat",
                "projectName": "Test",
                "randomSeed": 7,
                "segmentCount": 10,
                "assignedClipCount": 10,
                "gapCount": 0,
                "clipPoolCount": 1,
                "source": {"name": "Here We Go", "tempo": 122.0},
                "plan": [],
            }

        self.module.bridge.call = fake_call

        result = self.module.build_song_cut(
            project_name="Ignored",
            source_project_name="Here We Go feat We Lepers - Instrumental by ivywild Song License",
            clip_source_project_name="THE LIONESS - A Kenyan Woman's Unexpected Journey to Photography",
            target_current_timeline=True,
            random_seed=7,
            dry_run=True,
        )

        self.assertIn("Preset: natural", result)
        self.assertEqual(
            calls,
            [
                (
                    "timeline.assembleRandomClipsToBeats",
                    {
                        "grid": "half_beat",
                        "projectName": "Ignored",
                        "segmentMinStep": 1,
                        "segmentMaxStep": 4,
                        "stepWeights": {"1": 1, "2": 8, "4": 3},
                        "randomSeed": 7,
                        "allowClipReuse": True,
                        "includeAudio": True,
                        "buildMode": "native",
                        "targetCurrentTimeline": True,
                        "dryRun": True,
                        "sourceProjectName": "Here We Go feat We Lepers - Instrumental by ivywild Song License",
                        "clipSourceProjectName": "THE LIONESS - A Kenyan Woman's Unexpected Journey to Photography",
                    },
                )
            ],
        )

    def test_build_song_cut_rejects_invalid_pace(self):
        result = self.module.build_song_cut(pace="slow")
        self.assertIn('pace must be one of', result)


if __name__ == "__main__":
    unittest.main()
