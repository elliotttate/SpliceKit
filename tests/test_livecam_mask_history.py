import platform
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources" / "SpliceKitLiveCam.m"
SOAK_SOURCE = ROOT / "tests" / "livecam_mask_history_soak.m"


class LiveCamMaskHistoryTests(unittest.TestCase):
    def test_production_history_is_materialized_and_bounded(self):
        source = SOURCE.read_text(encoding="utf-8")

        self.assertIn("materializedMaskForHistory", source)
        self.assertIn("CVPixelBufferPoolCreatePixelBufferWithAuxAttributes", source)
        self.assertIn("toCVPixelBuffer:historyBuffer", source)
        self.assertIn("self.previousMaskForBlend = materialized;", source)
        self.assertNotIn("self.previousMaskForBlend = mask;", source)
        self.assertIn("kCIContextCacheIntermediates: @NO", source)
        self.assertIn("@autoreleasepool", source)

    def test_reused_vision_mask_skips_duplicate_refinement(self):
        source = SOURCE.read_text(encoding="utf-8")

        self.assertIn("params.sourceGeneration == self.previousMaskSourceGeneration", source)
        self.assertIn("return self.previousMaskForBlend;", source)
        self.assertIn("inferenceFrameInterval", source)

    def test_selected_capture_resolution_is_enforced(self):
        source = SOURCE.read_text(encoding="utf-8")

        self.assertIn("SpliceKitLiveCamSessionPresetForResolution", source)
        self.assertIn("AVCaptureSessionPreset1280x720", source)
        self.assertIn("kCVPixelBufferWidthKey", source)
        self.assertIn("kCVPixelBufferHeightKey", source)

    @unittest.skipUnless(platform.system() == "Darwin", "Core Image soak test requires macOS")
    def test_mask_feedback_soak_has_stable_depth_and_memory(self):
        with tempfile.TemporaryDirectory(prefix="splicekit-livecam-test-") as temp_dir:
            executable = Path(temp_dir) / "livecam-mask-history-soak"
            compile_result = subprocess.run(
                [
                    "clang",
                    "-fobjc-arc",
                    "-O2",
                    "-mmacosx-version-min=14.0",
                    "-framework",
                    "Foundation",
                    "-framework",
                    "CoreImage",
                    "-framework",
                    "CoreVideo",
                    "-framework",
                    "Metal",
                    str(SOAK_SOURCE),
                    "-o",
                    str(executable),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=120,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)

            run_result = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=120,
            )
            self.assertEqual(
                run_result.returncode,
                0,
                f"stdout:\n{run_result.stdout}\nstderr:\n{run_result.stderr}",
            )
            self.assertIn("frames=5000", run_result.stdout)


if __name__ == "__main__":
    unittest.main()
