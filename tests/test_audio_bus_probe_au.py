#!/usr/bin/env python3
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PROBE_DIR = REPO_ROOT / "tools" / "audio-bus-probe-au"
SOURCE = PROBE_DIR / "SpliceKitAudioBusProbe.c"
INFO_PLIST = PROBE_DIR / "Info.plist"
MAKEFILE = REPO_ROOT / "Makefile"
READER = PROBE_DIR / "read_probe.py"


def source(path):
    return path.read_text(encoding="utf-8")


def function_body(text, name):
    search_from = 0
    while True:
        start = text.index(name, search_from)
        brace = text.index("{", start)
        semicolon = text.find(";", start, brace)
        if semicolon == -1:
            break
        search_from = start + len(name)

    depth = 0
    for index in range(brace, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1:index]
    raise AssertionError(f"Could not find body for {name}")


class AudioBusProbeAUTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = source(SOURCE)
        cls.makefile = source(MAKEFILE)
        with INFO_PLIST.open("rb") as handle:
            cls.info = plistlib.load(handle)

    def test_component_registration_matches_au_effect(self):
        components = self.info["AudioComponents"]
        self.assertEqual(len(components), 1)
        component = components[0]
        self.assertEqual(component["type"], "aufx")
        self.assertEqual(component["subtype"], "SkBP")
        self.assertEqual(component["manufacturer"], "SpKt")
        self.assertEqual(component["factoryFunction"], "SpliceKitAudioBusProbeFactory")
        self.assertIn("Analyzer", component["tags"])

    def test_probe_supports_fcp_effect_input_paths(self):
        self.assertIn("kAudioUnitProperty_SetRenderCallback", self.source)
        self.assertIn("AURenderCallbackStruct", self.source)
        self.assertIn("kAudioUnitProperty_MakeConnection", self.source)
        self.assertIn("AudioUnitRender(state->connection.sourceAudioUnit", self.source)
        lookup = function_body(self.source, "SKBPLookup")
        self.assertIn("kAudioUnitRenderSelect", lookup)
        self.assertIn("kAudioUnitProcessSelect", lookup)
        self.assertIn("kAudioUnitProcessMultipleSelect", lookup)

    def test_status_writes_are_outside_render_path(self):
        render = function_body(self.source, "SKBPRender")
        self.assertNotIn("fopen", render)
        self.assertNotIn("fprintf", render)
        self.assertIn("SKBPAnalyzeAudio", render)
        self.assertIn("SKBPRecordRender", render)
        self.assertIn("SKBP_METRICS_BASENAME", self.source)
        self.assertIn("%s-latest.json", self.source)

    def test_diagnostic_parameters_are_published(self):
        for name in (
            "Receiving Audio",
            "Input Peak",
            "Input RMS",
            "Avg Render ms",
            "Max Render ms",
            "CPU Load",
            "Last Render Age ms",
            "Render Count",
            "Last Frames",
            "Reset Stats",
        ):
            self.assertIn(name, self.source)
        self.assertIn("kAudioUnitParameterFlag_MeterReadOnly", self.source)

    def test_make_targets_build_and_install_component(self):
        self.assertIn("audio-bus-probe:", self.makefile)
        self.assertIn("install-audio-bus-probe:", self.makefile)
        self.assertIn("uninstall-audio-bus-probe:", self.makefile)
        self.assertIn("AudioComponentRegistrar", self.makefile)
        self.assertIn("SpliceKitAudioBusProbe.component", self.makefile)

    def test_reader_reports_explicit_status_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            status = Path(tmp) / "probe.json"
            status.write_text(
                "{"
                "\"plugin\":\"SpliceKit Audio Bus Probe\","
                "\"instance\":\"unit-test\","
                "\"renderCount\":12,"
                "\"nonSilentRenderCount\":12,"
                "\"avgRenderMs\":0.004"
                "}",
                encoding="utf-8",
            )
            result = subprocess.run(
                ["python3", str(READER), str(status)],
                check=True,
                text=True,
                capture_output=True,
            )
        self.assertIn("statusPath:", result.stdout)
        self.assertIn("instance: unit-test", result.stdout)
        self.assertIn("renderCount: 12", result.stdout)

    def test_reader_can_list_all_instances(self):
        reader = source(READER)
        self.assertIn("Path(\"/tmp\").glob(\"splicekit-audio-bus-probe-*.json\")", reader)
        self.assertIn("status_rank", reader)
        self.assertIn("--all", reader)


if __name__ == "__main__":
    unittest.main()
