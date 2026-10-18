"""FCP-free execution tests for the v4 media native code and published contracts."""
import json
import platform
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NATIVE = [ROOT / "Sources" / (name + ".m") for name in (
    "SpliceKitV4Result", "SpliceKitV4Media", "SpliceKitV4Color", "SpliceKitV4Audio",
    "SpliceKitV4Retime", "SpliceKitV4Analysis")]
CAPABILITIES = ROOT / "mcp/splicekit_v4/capabilities/media.json"
PLAN = ROOT / "tests/live/v4/media.json"


class MediaContractTests(unittest.TestCase):
    def test_every_registered_method_has_an_honest_capability(self):
        registered = set(re.findall(r'SKMRegister\(@"([^"]+)"',
                                    "\n".join(path.read_text() for path in NATIVE)))
        caps = json.loads(CAPABILITIES.read_text())["capabilities"]
        self.assertEqual(registered, {cap["method"] for cap in caps})
        self.assertEqual(len(caps), 18)
        for cap in caps:
            with self.subTest(capability=cap["name"]):
                self.assertEqual(cap["evidence_level"], "offline_tested")
                self.assertEqual(cap["requires_fcp_build"], ["454072"])
                self.assertEqual(cap["input_schema"]["type"], "object")
                self.assertTrue(cap["readback_supported"])
                self.assertTrue(cap["known_limitations"])
                self.assertIn("error", cap["output_schema"]["required"])
        admission = next(c for c in caps if c["method"] == "v4.analysis.start")
        self.assertFalse(admission["write_supported"])
        self.assertEqual(admission["backend"], "blocked_admission")

    def test_every_rpc_has_a_live_case_and_undo_policy(self):
        plan = json.loads(PLAN.read_text())
        self.assertEqual(plan["schema"], "splicekit.live-plan/1")
        self.assertTrue(plan["template"])
        self.assertTrue(plan["fixture"]["library_name"].startswith("SpliceKit-Test"))
        coverage = plan["manual_cases"]
        methods = {cap["method"] for cap in json.loads(CAPABILITIES.read_text())["capabilities"]}
        self.assertEqual(methods, {case["method"] for case in coverage})
        for case in coverage:
            self.assertTrue(case["steps"])
            self.assertTrue(case["expected_readback"])
            self.assertTrue(case["undo_check"])

    def test_native_selectors_have_static_abi_evidence(self):
        text = (ROOT / "docs/v4/media-selectors.tsv").read_text()
        for selector in ("actionRetimeHoldPreset:holdComponentTime:duration:newHoldComponentTime:error:",
                         "actionRetimeSpeedRampPreset:startComponentTime:endComponentTime:toZero:fromZero:error:",
                         "mediaTimeFromComponentTime:", "audioEffectsForIdentifier:",
                         "setAudioChannelMap:", "actionAddRole:toItems:error:",
                         "setFactoryPreset:", "setCurveDoubleValue:atTime:options:"):
            self.assertIn("\t" + selector + "\t", text)

    @unittest.skipUnless(platform.system() == "Darwin", "Native ObjC execution requires macOS")
    def test_native_media_rpc_execution_without_fcp(self):
        build = ROOT / "build"
        build.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="media-test-", dir=build) as directory:
            executable = Path(directory) / "media-mock"
            command = ["clang", "-fobjc-arc", "-Wl,-export_dynamic", "-I", str(ROOT / "Sources"),
                       "-framework", "Foundation", "-framework", "AppKit", "-framework", "CoreMedia",
                       *map(str, NATIVE), str(ROOT / "tests/v4/media_mock.m"), "-o", str(executable)]
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
            report = json.loads(result.stdout)
            (build / "media-mock-result.json").write_text(json.dumps(report, indent=2) + "\n")
            failures = [check["name"] for check in report["checks"] if not check["passed"]]
            self.assertEqual(result.returncode, 0, failures or result.stderr)
            self.assertGreaterEqual(report["passed"], 70)
            self.assertEqual(report["failed"], 0)


if __name__ == "__main__":
    unittest.main()
