from fractions import Fraction
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

from tests.live.contract import VerificationError
from tests.live.fixtures.install import install
from tests.live.fixtures.prepare import fcpxml
from tests.live.fixtures.advanced import blueprint
from tests.live.mock_rpc import MockBridge, mock_server
from tests.live.rpc import RPCClient
from tests.live.run_live import ROOT


class FixturePlanTests(unittest.TestCase):
    def test_advanced_import_keeps_source_handles_and_separate_native_controls(self):
        tree = ET.fromstring(blueprint('/tmp/stereo.mov', '/tmp/SpliceKit-Test-v4.fcpbundle'))
        self.assertEqual(tree.find('resources/asset').get('audioChannels'), '2')
        clips = tree.findall('.//sequence/spine/asset-clip')
        self.assertEqual(clips[0].get('start'), '10s')
        self.assertEqual(clips[0].get('duration'), '6s')
        self.assertEqual(len(clips[0].findall('filter-video')), 4)
        self.assertEqual(len(clips[0].findall('.//keyframe')), 2)
        self.assertEqual({c.get('role') for c in tree.findall('.//caption')}, {'iTT.en', 'iTT.tr'})
        self.assertEqual(len(tree.findall('.//sequence/spine/transition')), 1)

    def test_xml_describes_original_linked_av_and_exact_frame_grid(self):
        for rate, expected in (("30", Fraction(1, 30)), ("2997", Fraction(1001, 30000))):
            root = ET.fromstring(fcpxml("/tmp/bars.mov", "/tmp/SpliceKit-Test-v4.fcpbundle", rate))
            fmt = root.find("resources/format")
            asset = root.find("resources/asset")
            sequence = root.find("library/event/project/sequence")
            self.assertEqual(Fraction(fmt.get("frameDuration")[:-1]), expected)
            self.assertEqual(Fraction(asset.get("duration")[:-1]), expected * 90)
            self.assertEqual(sequence.get("duration"), asset.get("duration"))
            self.assertEqual(sequence.find("spine/asset-clip").get("ref"), asset.get("id"))
            self.assertEqual((asset.get("hasVideo"), asset.get("hasAudio")), ("1", "1"))
            self.assertEqual(root.find("library").get("location"), Path("/tmp/SpliceKit-Test-v4.fcpbundle").resolve().as_uri())

    def test_installer_rejects_missing_media_manifest_before_rpc(self):
        rpc = RPCClient(port=1)
        with self.assertRaises(VerificationError):
            install({"schema": "splicekit.fixture/1", "media_generated": False}, rpc, "/tmp/x", "/tmp/x")
        self.assertEqual(rpc.transcript, [])

    def test_fixture_import_is_gated_before_dispatch(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            media = folder / "bars.mov"
            media.write_bytes(b"fixture test placeholder, never submitted to a real host")
            xml = folder / "fixture.fcpxml"
            xml.write_text(fcpxml(media, "/tmp/SpliceKit-Test-v4.fcpbundle", "30"))
            manifest = {"schema": "splicekit.fixture/1", "media_generated": True, "variants": [{
                "project": "SpliceKit-Test-30", "frame_duration": "1/30s", "media": str(media),
                "xml": str(xml), "media_sha256": hashlib.sha256(media.read_bytes()).hexdigest(),
                "xml_sha256": hashlib.sha256(xml.read_bytes()).hexdigest()}]}
            bridge = MockBridge()
            bridge.library_count = 2
            with mock_server(bridge) as port:
                with self.assertRaises(VerificationError):
                    install(manifest, RPCClient(port=port), bridge.library_path, folder)
            self.assertFalse(any(name == "fcpxml.import" for name, _ in bridge.calls))


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("swiftc"), "AVFoundation requires macOS/Swift")
class GeneratedMediaTests(unittest.TestCase):
    def test_both_generated_rates_have_exact_frames_and_non_silent_audio(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            output = folder / "generated"
            result = subprocess.run([sys.executable, "-m", "tests.live.fixtures.prepare", "--output", str(output)],
                                    cwd=ROOT, capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertTrue(manifest["media_generated"])
            self.assertFalse(manifest["library_created"])
            inspector = folder / "inspect-media"
            subprocess.run(["swiftc", str(ROOT / "tests/live/fixtures/inspect_media.swift"), "-o", str(inspector)],
                           check=True, capture_output=True, text=True, timeout=90)
            for variant in manifest["variants"]:
                with self.subTest(project=variant["project"]):
                    result = subprocess.run([str(inspector), variant["media"]], check=True,
                                            capture_output=True, text=True, timeout=30)
                    measured = json.loads(result.stdout)
                    frame = Fraction(variant["frame_duration"][:-1])
                    self.assertEqual((measured["width"], measured["height"]), (360, 640))
                    self.assertEqual(measured["frame_count"], 90)
                    self.assertEqual(measured["first_pts"]["value"], 0)
                    self.assertEqual(len(measured["frame_intervals"]), 89)
                    for interval in measured["frame_intervals"]:
                        self.assertEqual(Fraction(interval["value"], interval["timescale"]), frame)
                    self.assertEqual(Fraction(measured["duration"]["value"], measured["duration"]["timescale"]), frame * 90)
                    self.assertGreater(measured["audio_rms"], 0.05)
                    self.assertEqual(measured['audio_channels'], 1)
                    self.assertEqual(measured["audio_samples"], int(frame * 90 * 48000))
                    self.assertEqual(hashlib.sha256(Path(variant["media"]).read_bytes()).hexdigest(), variant["media_sha256"])
            stereo = folder / 'stereo.mov'
            subprocess.run([str(output / 'generate-media'), str(stereo), '30', '1', '150', '2'],
                           check=True, capture_output=True, timeout=45)
            measured = json.loads(subprocess.check_output([str(inspector), str(stereo)], text=True))
            self.assertEqual((measured['frame_count'], measured['audio_channels']), (150, 2))
            self.assertEqual(measured['audio_samples'], 2 * 5 * 48000)
            self.assertGreater(measured['audio_rms'], 0.05)


if __name__ == "__main__":
    unittest.main()
