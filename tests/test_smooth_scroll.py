import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLAYHEAD_SOURCE = ROOT / "Sources" / "SpliceKitTimelinePlayheadOverlay.m"
INTERACTION_SOURCE = ROOT / "Sources" / "SpliceKitTimelineInteractionSuspend.m"


class SmoothScrollRegressionTests(unittest.TestCase):
    def test_animates_fcps_native_playhead_artwork(self):
        source = PLAYHEAD_SOURCE.read_text(encoding="utf-8")

        self.assertIn("sNativePlayheadLayerWeak", source)
        self.assertIn("PO_setNativePlayheadX(marker, x);", source)
        self.assertNotIn("colorWithCalibratedRed:1.0 green:0.85", source)
        self.assertNotIn("real.hidden = YES", source)
        self.assertNotIn("sOverlayLayer", source)

    def test_disabling_during_playback_restores_native_scrolling(self):
        source = PLAYHEAD_SOURCE.read_text(encoding="utf-8")
        remove = re.search(
            r"void SpliceKit_removeTimelinePlayheadOverlay\(void\) \{(?P<body>.*?)\n\}",
            source,
            re.DOTALL,
        )

        self.assertIsNotNone(remove)
        self.assertIn("PO_endPlaybackSession();", remove.group("body"))
        self.assertIn("PO_restoreAppleScroller();", source)
        self.assertIn("activeSource != source", source)

    def test_display_link_is_reused_between_playback_sessions(self):
        source = PLAYHEAD_SOURCE.read_text(encoding="utf-8")

        self.assertIn("PO_prepareDisplayLink", source)
        self.assertIn("PO_prepareDisplayLinkWhenTimelineReady(40)", source)
        self.assertIn("link.paused = YES;", source)
        self.assertIn("sDisplayLink.paused = NO;", source)
        self.assertIn("PO_pauseDisplayLink();", source)
        self.assertIn("PO_disposeDisplayLink();", source)
        self.assertIn("dispatch_async(dispatch_get_main_queue()", source)
        self.assertIn("A paused", source)
        self.assertIn("First active display tick", source)

    def test_native_scroller_stays_live_until_first_smooth_frame(self):
        source = PLAYHEAD_SOURCE.read_text(encoding="utf-8")

        self.assertIn("sPendingCenteredScrollTakeover", source)
        self.assertIn("PO_activateCenteredScrollTakeover(view);", source)
        self.assertLess(
            source.index("PO_activateCenteredScrollTakeover(view);"),
            source.index("BOOL drivingScroll ="),
        )
        begin = re.search(
            r"static void PO_onPlaybackBegan\(id source\) \{(?P<body>.*?)\n\}",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(begin)
        self.assertNotIn("setPaused, YES", begin.group("body"))

    def test_disabling_during_interaction_restores_every_live_view(self):
        source = INTERACTION_SOURCE.read_text(encoding="utf-8")

        self.assertIn("weakObjectsHashTable", source)
        self.assertIn("for (id timelineView in IS_suspendedViews().allObjects)", source)
        self.assertIn("st->refcount = 1;", source)
        self.assertIn("IS_endSuspend(timelineView);", source)

    def test_fcp_12_3_uses_layer_manager_for_anchored_state_getter(self):
        source = INTERACTION_SOURCE.read_text(encoding="utf-8")

        self.assertIn("SEL layerManagerSel = @selector(layerManager);", source)
        self.assertIn("anchoredOwner", source)
        self.assertIn("st->capturedAnchored", source)


if __name__ == "__main__":
    unittest.main()
