#!/usr/bin/env python3
import importlib.util
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
            self.tools.append({"name": func.__name__, "annotations": dict(annotations or {}), "func": func})
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


try:
    import opentimelineio as otio
except ImportError:  # pragma: no cover - exercised via skip
    otio = None


@unittest.skipIf(otio is None, "opentimelineio is required for upstream fixture tests")
class OTIOUpstreamFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_server_module()
        cls.fixture_root = Path(__file__).resolve().parent / "fixtures" / "upstream_otio_fcpxml"
        cls.transitions_fixture = cls.fixture_root / "fcpx_transitions.fcpxml"
        cls.package_fixture = cls.fixture_root / "Test Library.fcpxmld"

    def test_transition_fixture_reads_with_adapter_fallback(self):
        result = self.module._otio_read_fcpx_string(
            self.transitions_fixture.read_text(encoding="utf-8")
        )
        timeline = self.module._otio_first_timeline(result)
        summary = self.module._otio_timeline_summary(timeline)

        transitions = [
            item
            for track in timeline.video_tracks()
            for item in track
            if isinstance(item, otio.schema.Transition)
        ]

        self.assertEqual(summary["name"], "Transitions_Test_Project")
        self.assertEqual(summary["tracks"], 1)
        self.assertEqual(summary["clips"], 3)
        self.assertEqual(summary["duration_seconds"], 30.5)
        self.assertEqual(len(transitions), 2)

    def test_fcpxmld_package_fixture_reads_via_info_entrypoint(self):
        xml = self.module._otio_read_fcpx_document(str(self.package_fixture))
        result = self.module._otio_read_fcpx_string(xml)
        timelines = self.module._otio_all_timelines(result)
        names = [self.module._otio_timeline_summary(timeline)["name"] for timeline in timelines]

        self.assertIn("<fcpxml", xml)
        self.assertEqual(len(timelines), 3)
        self.assertEqual(
            names,
            [
                "1920x1080 23.98p Timeline",
                "1920x1080 25p Timeline",
                "Untitled Project",
            ],
        )


if __name__ == "__main__":
    unittest.main()
