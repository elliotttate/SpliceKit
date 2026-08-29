import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources" / "SpliceKitLiveCam.m"


class LiveCamAudioCaptureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_writer_uses_session_aware_audio_settings(self):
        self.assertIn(
            "recommendedAudioSettingsForAssetWriterWithOutputFileType:AVFileTypeQuickTimeMovie",
            self.source,
        )
        self.assertIn("audioWriterSettingsForCurrentSession", self.source)
        self.assertNotIn("AVNumberOfChannelsKey: @2,\n            AVSampleRateKey: @48000", self.source)

    def test_capture_preserves_native_microphone_format(self):
        self.assertIn("audioOutput.audioSettings = nil;", self.source)
        self.assertIn("audioInput.device", self.source)
        self.assertIn("CMAudioFormatDescriptionGetStreamBasicDescription", self.source)

    def test_audio_callbacks_are_prioritized_and_diagnosed(self):
        self.assertIn("QOS_CLASS_USER_INTERACTIVE", self.source)
        self.assertIn("trackAudioFormatAndContinuityFromSampleBuffer", self.source)
        self.assertIn('@"sourceAudioDiscontinuities"', self.source)
        self.assertIn('@"sourceAudioGapFrames"', self.source)

    def test_meter_work_is_throttled_and_format_aware(self):
        self.assertIn("now - self.lastAudioMeterDispatchTime < 0.05", self.source)
        self.assertIn("asbd->mBitsPerChannel == 24", self.source)
        self.assertIn("kAudioFormatFlagIsAlignedHigh", self.source)
        self.assertIn("asbd->mBitsPerChannel == 32", self.source)
        self.assertIn("asbd->mBitsPerChannel == 64", self.source)

    def test_audio_monitor_uses_dbfs_with_peak_and_clip_indication(self):
        self.assertIn("SpliceKitLiveCamAudioMeterView", self.source)
        self.assertIn("20.0 * log10(self.smoothedAudioLevel)", self.source)
        self.assertIn("updateWithRMSDB:rmsDB peakDB:peakDB", self.source)
        self.assertIn('@"CLIP"', self.source)
        self.assertIn('@"audioLevelDB"', self.source)
        self.assertIn('@"audioPeakDB"', self.source)

    def test_audio_monitor_sizes_buffer_list_from_live_sample(self):
        size_query = "&bufferListSize,\n        NULL,\n        0,"
        self.assertIn(size_query, self.source)
        self.assertIn("calloc(1, bufferListSize)", self.source)
        self.assertIn('@"audioMeterBuffersReceived"', self.source)
        self.assertIn('@"audioMeterDecodedSamples"', self.source)
        self.assertIn('@"audioMeterLastError"', self.source)


if __name__ == "__main__":
    unittest.main()
