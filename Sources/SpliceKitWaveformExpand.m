//
//  SpliceKitWaveformExpand.m
//
//  When video thumbnails are hidden via FCP's "Change Appearance" button,
//  the filmstrip area goes vacant. This swizzle makes the audio waveform
//  fill the full clip height including the space where the filmstrip was.
//
//  Root cause: FFFilmstripCell.audioHeight returns -1 (sentinel: "use
//  appearance default = 28px") when thumbnails are turned off. Even though
//  the container layer expands to 96px, the waveform renderer reads -1 and
//  draws only the default 28px at the bottom of the 96px cell.
//
//  Fix: swizzle FFFilmstripCell.audioHeight getter. When the stored value
//  is -1 (i.e., "auto"), return the cell layer's actual height so the
//  renderer fills the full available space.
//

#import "SpliceKit.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

typedef double (*AudioHeightGetterFn)(id, SEL);
static AudioHeightGetterFn sOrigAudioHeight = NULL;

static double WE_audioHeight(id self, SEL _cmd) {
    double h = sOrigAudioHeight(self, _cmd);
    if (h >= 0) return h;  // explicit value — honour it

    // h == -1 (or any negative): FCP means "use the appearance default strip".
    // Instead, return the cell layer's actual current height so the waveform
    // fills the full audio container when thumbnails are hidden.
    CALayer *layer = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"layer"));
    if (layer) {
        CGFloat layerH = layer.bounds.size.height;
        if (layerH > 1.0) return layerH;
    }
    return h;
}

void SpliceKit_installWaveformExpand(void) {
    Class cellCls = NSClassFromString(@"FFFilmstripCell");
    if (!cellCls) {
        SpliceKit_log(@"[WaveformExpand] FFFilmstripCell not found");
        return;
    }
    SEL sel = NSSelectorFromString(@"audioHeight");
    IMP orig = SpliceKit_swizzleMethod(cellCls, sel, (IMP)WE_audioHeight);
    if (orig) {
        sOrigAudioHeight = (AudioHeightGetterFn)orig;
        SpliceKit_log(@"[WaveformExpand] installed");
    }
}
