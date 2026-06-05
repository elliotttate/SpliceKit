//
//  SpliceKitWaveformExpand.m
//
//  When video thumbnails are hidden via FCP's "Change Appearance" button,
//  the filmstrip area goes vacant. This swizzle expands the audio waveform
//  layer to fill the full clip height instead of occupying only a thin strip.
//
//  Hook: PETimelineItemLayer
//    -updateAppearance:(uint64_t)flags
//
//  PETimelineItemLayer overrides this to apply an FFTimelineItemAppearance
//  to the clip's sublayers. After the original runs, if the clip is not
//  showing a filmstrip (wantsFilmstripLayer == NO), we expand the audio
//  contents layer to cover the full clip bounds.
//

#import "SpliceKit.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

typedef void (*UpdateAppearanceFlagsFn)(id, SEL, uint64_t);
static UpdateAppearanceFlagsFn sOrigUpdateAppearanceFlags = NULL;

static void WE_expandWaveformIfNeeded(id self) {
    // Only act when the filmstrip is hidden (Change Appearance → no thumbnails,
    // or a purely audio clip with no video to show).
    typedef BOOL (*BoolImpFn)(id, SEL);
    BOOL wantsFilmstrip = ((BoolImpFn)objc_msgSend)(self, @selector(wantsFilmstripLayer));
    if (wantsFilmstrip) return;

    // Grab the audio contents layer via KVC — this is _audioContentsLayer (TLKFilmstripLayer).
    CALayer *audioLayer = [self valueForKey:@"_audioContentsLayer"];
    if (!audioLayer) return;

    // Expand it to fill the full clip layer bounds.
    CGRect bounds = ((CALayer *)self).bounds;
    if (CGRectIsEmpty(bounds)) return;

    audioLayer.frame = bounds;
}

static void WE_updateAppearanceFlags(id self, SEL _cmd, uint64_t flags) {
    sOrigUpdateAppearanceFlags(self, _cmd, flags);
    WE_expandWaveformIfNeeded(self);
}

void SpliceKit_installWaveformExpand(void) {
    Class cls = NSClassFromString(@"PETimelineItemLayer");
    if (!cls) {
        SpliceKit_log(@"[WaveformExpand] PETimelineItemLayer not found");
        return;
    }

    SEL sel = NSSelectorFromString(@"updateAppearance:");
    IMP orig = SpliceKit_swizzleMethod(cls, sel, (IMP)WE_updateAppearanceFlags);
    if (orig) {
        sOrigUpdateAppearanceFlags = (UpdateAppearanceFlagsFn)orig;
        SpliceKit_log(@"[WaveformExpand] installed");
    }
}
