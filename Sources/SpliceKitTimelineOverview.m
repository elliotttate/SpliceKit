//
//  SpliceKitTimelineOverview.m
//  SpliceKit
//
//  An optional inline timeline overview that sits below the ruler and shows a
//  scaled-down view of the whole project. Click or drag anywhere on it to jump
//  the playhead. Modeled after the Touch Bar's timeline miniature — it reuses
//  FFAnchoredCollectionImageCreation (the same renderer FCP's Touch Bar uses)
//  so color-coded lanes match FCP's internal representation.
//
//  The bar is a floating NSPanel child window positioned over the top of the
//  timeline scroll view (same injection pattern as SpliceKitSectionsBar).
//

#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>

#if defined(__x86_64__)
#define OV_STRET objc_msgSend_stret
#else
#define OV_STRET objc_msgSend
#endif

typedef struct __attribute__((aligned(8))) {
    int64_t value;
    int32_t timescale;
    uint32_t flags;
    int64_t epoch;
} OV_CMTime;
typedef struct { OV_CMTime start; OV_CMTime duration; } OV_CMTimeRange;

static const CGFloat kOverviewBarHeight = 40.0;
static const CGFloat kOverviewBarTopInset = 28.0;  // leave room for FCP's ruler ticks
static const CGFloat kOverviewEdgeGrabWidth = 6.0; // edge-drag hit zone half-width

typedef NS_ENUM(NSInteger, OV_DragMode) {
    OV_DRAG_SEEK = 0,
    OV_DRAG_SCROLL,
    OV_DRAG_ZOOM_LEFT,
    OV_DRAG_ZOOM_RIGHT,
};

static NSString *const kOverviewDefaultsKey = @"SpliceKitTimelineOverviewBarEnabled";

#pragma mark - Collection / Sequence Helpers

// Sequence -> primaryObject (FFAnchoredCollection). This is the tree the
// ImageCreation renderer walks to produce the miniature.
static id OV_currentCollection(void) {
    id tm = SpliceKit_getActiveTimelineModule();
    if (!tm) return nil;
    SEL seqSel = NSSelectorFromString(@"sequence");
    if (![tm respondsToSelector:seqSel]) return nil;
    id sequence = ((id (*)(id, SEL))objc_msgSend)(tm, seqSel);
    if (!sequence) return nil;
    SEL poSel = NSSelectorFromString(@"primaryObject");
    if (![sequence respondsToSelector:poSel]) return sequence; // fallback
    id collection = ((id (*)(id, SEL))objc_msgSend)(sequence, poSel);
    return collection ?: sequence;
}

static id OV_currentSequence(void) {
    id tm = SpliceKit_getActiveTimelineModule();
    if (!tm) return nil;
    SEL seqSel = NSSelectorFromString(@"sequence");
    if (![tm respondsToSelector:seqSel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(tm, seqSel);
}

static double OV_sequenceDurationSeconds(void) {
    // FFAnchoredSequence itself does not implement `duration`, but its
    // primaryObject (an FFAnchoredCollection -> FFAnchoredObject) does.
    // Fall back to summing contained-item durations if even that is missing.
    id collection = OV_currentCollection();
    if (!collection) return 0.0;

    SEL durSel = NSSelectorFromString(@"duration");
    if ([collection respondsToSelector:durSel]) {
        OV_CMTime d = ((OV_CMTime (*)(id, SEL))OV_STRET)(collection, durSel);
        if (d.timescale > 0) {
            double secs = (double)d.value / (double)d.timescale;
            if (secs > 0) return secs;
        }
    }

    SEL ciSel = NSSelectorFromString(@"containedItems");
    if (![collection respondsToSelector:ciSel]) return 0.0;
    id items = ((id (*)(id, SEL))objc_msgSend)(collection, ciSel);
    if (![items isKindOfClass:[NSArray class]]) return 0.0;
    int64_t totalValue = 0;
    int32_t totalTs = 0;
    for (id item in (NSArray *)items) {
        if (![item respondsToSelector:durSel]) continue;
        OV_CMTime cd = ((OV_CMTime (*)(id, SEL))OV_STRET)(item, durSel);
        if (cd.timescale <= 0) continue;
        if (totalTs == 0) totalTs = cd.timescale;
        if (cd.timescale == totalTs) totalValue += cd.value;
        else totalValue += cd.value * totalTs / cd.timescale;
    }
    if (totalTs <= 0) return 0.0;
    return (double)totalValue / (double)totalTs;
}

static double OV_playheadSeconds(void) {
    id tm = SpliceKit_getActiveTimelineModule();
    if (!tm) return 0.0;
    SEL phSel = NSSelectorFromString(@"playheadTime");
    if (![tm respondsToSelector:phSel]) return 0.0;
    OV_CMTime t = ((OV_CMTime (*)(id, SEL))OV_STRET)(tm, phSel);
    if (t.timescale <= 0) return 0.0;
    return (double)t.value / (double)t.timescale;
}

static int32_t OV_sequenceTimescale(void) {
    id seq = OV_currentSequence();
    if (!seq) return 24000;
    SEL fdSel = NSSelectorFromString(@"frameDuration");
    if (![seq respondsToSelector:fdSel]) return 24000;
    OV_CMTime fd = ((OV_CMTime (*)(id, SEL))OV_STRET)(seq, fdSel);
    return fd.timescale > 0 ? fd.timescale : 24000;
}

#pragma mark - Overview View

@interface SpliceKitTimelineOverviewView : NSView
@property (nonatomic, strong) NSImage *cachedImage;
@property (nonatomic) CGSize cachedImageBackingSize;
@property (nonatomic, strong) NSDate *cachedAt;
@property (nonatomic, assign) NSUInteger cachedCollectionHash;  // sequence handle hash
@property (nonatomic, assign) double cachedDuration;

// Linked timeline refs — used to draw the visible-region rectangle overlay
@property (nonatomic, weak) NSView *fcpTimelineView;   // FFProTimelineView
@property (nonatomic, weak) NSClipView *fcpClipView;   // scroll clip wrapping the timeline

// Playhead redraw — CADisplayLink matches the display's refresh rate (60Hz
// on most displays, 120Hz on ProMotion). Only runs while FCP is playing.
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) BOOL playing;

+ (instancetype)shared;
- (void)invalidateImageCache;
- (void)rerenderIfNeeded;
- (void)startDisplayLink;
- (void)stopDisplayLink;
@end

@implementation SpliceKitTimelineOverviewView

+ (instancetype)shared {
    static SpliceKitTimelineOverviewView *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] initWithFrame:NSMakeRect(0, 0, 200, kOverviewBarHeight)];
    });
    return instance;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.cachedImageBackingSize = CGSizeZero;
    }
    return self;
}

- (BOOL)isFlipped { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)invalidateImageCache {
    self.cachedImage = nil;
    self.cachedImageBackingSize = CGSizeZero;
    self.cachedCollectionHash = 0;
    self.cachedDuration = 0.0;
    [self setNeedsDisplay:YES];
}

- (void)invalidateImageCacheAndRerender {
    [self invalidateImageCache];
    [self rerenderIfNeeded];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    // Defer first render — do NOT call the renderer synchronously here. The
    // view has only just entered the window hierarchy and the collection may
    // be mid-load (observed: SIGSEGV inside newImageFromCollection: +3444
    // when we render immediately on window attach). Retry a few times in
    // case the collection isn't renderable yet — after that, the notification
    // observers take over.
    __weak typeof(self) weakSelf = self;
    __block int attempts = 0;
    __block void (^tryRender)(void) = NULL;
    __block void (^tryRenderStrong)(void) = ^{
        typeof(self) s = weakSelf;
        if (!s) return;
        [s rerenderIfNeeded];
        if (s.cachedImage) return; // success
        if (++attempts >= 10) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), tryRender);
    };
    tryRender = tryRenderStrong;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), tryRender);
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self invalidateImageCache];
}

// Compare pixel-backed cache size to the view's current backing-size.
// Regenerate the image whenever size, duration, or identity changes.
- (BOOL)cacheIsFresh {
    if (!self.cachedImage) return NO;
    double dur = OV_sequenceDurationSeconds();
    if (fabs(dur - self.cachedDuration) > 0.5) return NO;
    id collection = OV_currentCollection();
    NSUInteger h = collection ? (NSUInteger)collection : 0;
    if (h != self.cachedCollectionHash) return NO;
    NSRect backing = [self convertRectToBacking:self.bounds];
    if (fabs(backing.size.width  - self.cachedImageBackingSize.width)  > 1.0) return NO;
    if (fabs(backing.size.height - self.cachedImageBackingSize.height) > 1.0) return NO;
    return YES;
}

- (void)rerenderIfNeeded {
    if ([self cacheIsFresh]) {
        [self setNeedsDisplay:YES];
        return;
    }
    [self renderCollectionImage];
    [self setNeedsDisplay:YES];
}

// FFModelLockFromRef is a C function exported by Flexo. Resolved lazily via
// dlsym. Returns an object we can message _readLock/_readUnlock on.
typedef id (*OV_FFModelLockFromRef_t)(id ref);
static OV_FFModelLockFromRef_t OV_modelLockFromRef(void) {
    static OV_FFModelLockFromRef_t fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (OV_FFModelLockFromRef_t)dlsym(RTLD_DEFAULT, "FFModelLockFromRef");
    });
    return fn;
}

// The collection must be suitable for the renderer. It has to be an
// FFAnchoredCollection that actually contains items and whose sequence has a
// positive duration — otherwise the renderer crashes deep in its item loop.
static BOOL OV_collectionIsRenderable(id collection) {
    if (!collection) return NO;
    Class wanted = objc_getClass("FFAnchoredCollection");
    if (wanted && ![collection isKindOfClass:wanted]) return NO;
    SEL hasSel = NSSelectorFromString(@"hasContainedItems");
    if ([collection respondsToSelector:hasSel]) {
        BOOL has = ((BOOL (*)(id, SEL))objc_msgSend)(collection, hasSel);
        if (!has) return NO;
    }
    if (OV_sequenceDurationSeconds() <= 0.0) return NO;
    return YES;
}

// Call FCP's own miniature-timeline renderer. Same code path the Touch Bar
// uses — color-coded rectangles per clip per lane.
- (void)renderCollectionImage {
    id collection = OV_currentCollection();
    if (!OV_collectionIsRenderable(collection)) {
        self.cachedImage = nil;
        return;
    }

    Class imageCreateCls = objc_getClass("FFAnchoredCollectionImageCreation");
    if (!imageCreateCls) {
        self.cachedImage = nil;
        return;
    }

    NSRect backing = [self convertRectToBacking:self.bounds];
    double w = backing.size.width;
    double h = backing.size.height;
    if (w < 10 || h < 4) { self.cachedImage = nil; return; }

    id modelLock = nil;
    BOOL locked = NO;
    @try {
        // Use the full initializer with explicit sRGB colors. The default
        // `[NSColor blackColor]` / `[NSColor grayColor]` are in the generic-
        // gray colorspace, and FFAnchoredCollectionImageCreation calls
        // -getRed:green:blue:alpha: on its colors during rendering — which
        // crashes when the color is non-RGB.
        SEL fullInit = NSSelectorFromString(
            @"initWithWidth:imageHeight:top:left:right:bottom:"
             "minLaneHeight:maxLaneHeight:gapBetweenLanes:showStartAndEndLines:"
             "imageColor:backgroundColor:");
        id inst = [imageCreateCls alloc];
        if (![inst respondsToSelector:fullInit]) {
            SpliceKit_log(@"[Overview] Full initializer missing on FFAnchoredCollectionImageCreation");
            return;
        }
        NSColor *imageColor =
            [NSColor colorWithSRGBRed:0.55 green:0.55 blue:0.58 alpha:1.0];
        NSColor *bgColor =
            [NSColor colorWithSRGBRed:0.08 green:0.08 blue:0.09 alpha:1.0];
        id renderer = ((id (*)(id, SEL,
                               double, double, double, double, double, double,
                               double, double, double, BOOL,
                               id, id))objc_msgSend)(
            inst, fullInit,
            w, h,                 // width, imageHeight
            1.0, 0.0, 0.0, 0.0,   // top, left, right, bottom
            2.0, 10.0, 1.0,       // minLaneHeight, maxLaneHeight, gapBetweenLanes
            YES,                  // showStartAndEndLines
            imageColor, bgColor);
        if (!renderer) return;

        SEL renderSel = NSSelectorFromString(@"newImageFromCollection:addLineForTime:showWindow:rectsAndColors:itemsToSelect:");
        if (![renderer respondsToSelector:renderSel]) {
            SpliceKit_log(@"[Overview] newImageFromCollection:... missing on FFAnchoredCollectionImageCreation");
            return;
        }

        // Acquire FFModelLock around the render call — FFNavViewController
        // does this before reading the collection's timing, and the renderer
        // itself reads containedItems/clippedRange without taking any lock.
        OV_FFModelLockFromRef_t lockFn = OV_modelLockFromRef();
        if (lockFn) {
            modelLock = lockFn(collection);
            if (modelLock && [modelLock respondsToSelector:@selector(_readLock)]) {
                ((void (*)(id, SEL))objc_msgSend)(modelLock, @selector(_readLock));
                locked = YES;
            }
        }

        // Signature (ObjC type encoding `@112@0:8@16{?=qiIq}24{?={?=qiIq}{?=qiIq}}48@96@104`):
        //   newImageFromCollection:(id) addLineForTime:(CMTime)
        //   showWindow:(CMTimeRange) rectsAndColors:(id) itemsToSelect:(id)
        //
        // Pass nil for rectsAndColors — otherwise the renderer uses its
        // "accumulate mode": it appends rect/color pairs to the array for
        // an external compositor to draw later, and leaves the NSImage
        // empty. We want it to draw directly into the image, so nil here.
        NSMutableArray *rectsAndColors = nil;
        OV_CMTime     invalidTime  = {0, 0, 0, 0};
        OV_CMTimeRange invalidRange = {{0,0,0,0}, {0,0,0,0}};
        NSImage *img = ((NSImage *(*)(id, SEL, id, OV_CMTime, OV_CMTimeRange, id, id))objc_msgSend)(
            renderer, renderSel, collection, invalidTime, invalidRange, rectsAndColors, nil);

        static int sRenderCount = 0;
        if ((sRenderCount++ % 10) == 0) {
            SpliceKit_log(@"[Overview] render #%d coll=%p dur=%.2fs img=%@ sz=%@",
                          sRenderCount,
                          collection, OV_sequenceDurationSeconds(),
                          img ? @"OK" : @"nil",
                          img ? NSStringFromSize(img.size) : @"n/a");
        }

        if (img) {
            self.cachedImage = img;
            self.cachedImageBackingSize = backing.size;
            self.cachedDuration = OV_sequenceDurationSeconds();
            self.cachedCollectionHash = (NSUInteger)collection;
            self.cachedAt = [NSDate date];
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Overview] render exception: %@", e.reason ?: e.description);
        self.cachedImage = nil;
    } @finally {
        if (locked && modelLock && [modelLock respondsToSelector:@selector(_readUnlock)]) {
            ((void (*)(id, SEL))objc_msgSend)(modelLock, @selector(_readUnlock));
        }
    }
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;

    // Background strip — subtle dark fill so the bar reads as a distinct lane.
    [[NSColor colorWithCalibratedRed:0.09 green:0.09 blue:0.10 alpha:0.92] setFill];
    NSRectFill(bounds);

    // Top + bottom hairlines
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.08] setFill];
    NSRectFill(NSMakeRect(0, bounds.size.height - 1, bounds.size.width, 1));
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.35] setFill];
    NSRectFill(NSMakeRect(0, 0, bounds.size.width, 1));

    // Cached miniature timeline image
    NSImage *img = self.cachedImage;
    if (img) {
        NSRect inset = NSInsetRect(bounds, 0, 2);
        [img drawInRect:inset
               fromRect:NSZeroRect
              operation:NSCompositingOperationSourceOver
               fraction:1.0
         respectFlipped:YES
                  hints:@{NSImageHintInterpolation: @(NSImageInterpolationLow)}];
    } else {
        // Placeholder while we haven't rendered yet
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.06] setFill];
        NSRect p = NSInsetRect(bounds, 8, 6);
        NSRectFill(p);
    }

    double duration = OV_sequenceDurationSeconds();
    if (duration <= 0) return;
    CGFloat pixelPerSec = bounds.size.width / duration;

    // Visible-region rectangle overlay — outline only, clips show through.
    NSRect vis = [self visibleRegionRect];
    if (!NSIsEmptyRect(vis)) {
        // Thick outline (2pt) with subtle inner/outer shadow so it reads well
        // over the miniature. No fill so the clip colors remain visible.
        [[NSColor colorWithSRGBRed:1.0 green:0.92 blue:0.40 alpha:0.95] setStroke];
        NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSInsetRect(vis, 1.0, 1.0)];
        border.lineWidth = 2.0;
        [border stroke];
    }

    // Playhead line
    double ph = OV_playheadSeconds();
    if (ph >= 0 && ph <= duration) {
        CGFloat px = (CGFloat)(ph * pixelPerSec);
        // Shadow / halo
        [[NSColor colorWithCalibratedRed:1.0 green:0.95 blue:0.55 alpha:0.35] setFill];
        NSRectFill(NSMakeRect(px - 1.5, 0, 3.0, bounds.size.height));
        // Core
        [[NSColor colorWithCalibratedRed:1.0 green:0.92 blue:0.40 alpha:1.0] setFill];
        NSRectFill(NSMakeRect(px - 0.5, 0, 1.0, bounds.size.height));
    }
}

#pragma mark - Coordinate / Region Helpers

- (double)timeForLocalX:(CGFloat)x {
    NSRect b = self.bounds;
    if (b.size.width <= 0) return 0;
    double duration = OV_sequenceDurationSeconds();
    if (duration <= 0) return 0;
    double frac = (double)(x / b.size.width);
    if (frac < 0) frac = 0; if (frac > 1) frac = 1;
    return frac * duration;
}

// Current visible-region rectangle in this view's coords, or NSZeroRect if the
// linked timeline is not yet usable.
- (NSRect)visibleRegionRect {
    NSRect b = self.bounds;
    double duration = OV_sequenceDurationSeconds();
    if (duration <= 0 || !self.fcpClipView || !self.fcpTimelineView) return NSZeroRect;

    NSRect clipBounds = self.fcpClipView.bounds;
    CGFloat leftPadding = 0;
    double tppSeconds = 0;
    SEL lpSel = NSSelectorFromString(@"leftPadding");
    if ([self.fcpTimelineView respondsToSelector:lpSel]) {
        leftPadding = ((CGFloat (*)(id, SEL))objc_msgSend)(self.fcpTimelineView, lpSel);
    }
    SEL tppSel = NSSelectorFromString(@"timePerPixel");
    if ([self.fcpTimelineView respondsToSelector:tppSel]) {
        OV_CMTime tpp = ((OV_CMTime (*)(id, SEL))OV_STRET)(self.fcpTimelineView, tppSel);
        if (tpp.timescale > 0) tppSeconds = (double)tpp.value / tpp.timescale;
    }
    if (tppSeconds <= 0) return NSZeroRect;

    double t0 = (clipBounds.origin.x - leftPadding) * tppSeconds;
    double t1 = t0 + clipBounds.size.width * tppSeconds;
    if (t0 < 0) t0 = 0;
    if (t1 > duration) t1 = duration;
    if (t1 <= t0) return NSZeroRect;

    CGFloat pixelPerSec = b.size.width / duration;
    CGFloat vx0 = (CGFloat)(t0 * pixelPerSec);
    CGFloat vx1 = (CGFloat)(t1 * pixelPerSec);
    CGFloat vw  = MAX(2.0, vx1 - vx0);
    return NSMakeRect(vx0, 1, vw, b.size.height - 2);
}

- (void)visibleRegionTimeT0:(double *)outT0 t1:(double *)outT1 {
    NSRect vis = [self visibleRegionRect];
    NSRect b = self.bounds;
    double duration = OV_sequenceDurationSeconds();
    if (NSIsEmptyRect(vis) || b.size.width <= 0 || duration <= 0) {
        if (outT0) *outT0 = 0;
        if (outT1) *outT1 = 0;
        return;
    }
    double pps = b.size.width / duration;
    if (outT0) *outT0 = NSMinX(vis) / pps;
    if (outT1) *outT1 = NSMaxX(vis) / pps;
}

#pragma mark - Main-Timeline Control

- (void)seekToSeconds:(double)seconds {
    id tm = SpliceKit_getActiveTimelineModule();
    if (!tm) return;
    SEL setSel = NSSelectorFromString(@"setPlayheadTime:");
    if (![tm respondsToSelector:setSel]) return;
    int32_t ts = OV_sequenceTimescale();
    OV_CMTime t;
    t.value = (int64_t)(seconds * ts);
    t.timescale = ts;
    t.flags = 1;
    t.epoch = 0;
    ((void (*)(id, SEL, OV_CMTime))objc_msgSend)(tm, setSel, t);
}

// Scroll the main timeline so `t0` lands at the left edge of the visible area.
// Uses direct NSClipView bounds-origin adjustment — matches exactly the inverse
// of our visibleRegionRect math (which reads from clipBounds.origin.x). Using
// TLKTimelineView's scrollTime:toLocation: was unreliable: location=0.0 did not
// put `t0` at the visible-area left edge as expected.
- (void)scrollMainTimelineToTime:(double)t0 {
    NSClipView *cv = self.fcpClipView;
    NSView *tv = self.fcpTimelineView;
    if (!cv || !tv) return;

    CGFloat leftPadding = 0;
    double tppSeconds = 0;
    SEL lpSel = NSSelectorFromString(@"leftPadding");
    if ([tv respondsToSelector:lpSel]) {
        leftPadding = ((CGFloat (*)(id, SEL))objc_msgSend)(tv, lpSel);
    }
    SEL tppSel = NSSelectorFromString(@"timePerPixel");
    if ([tv respondsToSelector:tppSel]) {
        OV_CMTime tpp = ((OV_CMTime (*)(id, SEL))OV_STRET)(tv, tppSel);
        if (tpp.timescale > 0) tppSeconds = (double)tpp.value / tpp.timescale;
    }
    if (tppSeconds <= 0) return;

    CGFloat newX = leftPadding + (CGFloat)(t0 / tppSeconds);
    if (newX < 0) newX = 0;
    NSPoint origin = cv.bounds.origin;
    origin.x = newX;
    [cv setBoundsOrigin:origin];
    [cv.enclosingScrollView reflectScrolledClipView:cv];
}

// Zoom the main timeline so its visible area shows [t0, t1].
- (void)zoomMainTimelineToT0:(double)t0 t1:(double)t1 {
    NSView *tv = self.fcpTimelineView;
    if (!tv || t1 <= t0) return;
    SEL zoomSel = NSSelectorFromString(@"zoomToRange:withPaddingFactor:");
    if (![tv respondsToSelector:zoomSel]) return;
    int32_t ts = OV_sequenceTimescale();
    if (ts <= 0) ts = 24000;
    OV_CMTimeRange range;
    range.start.value = (int64_t)(t0 * ts);
    range.start.timescale = ts;
    range.start.flags = 1;
    range.start.epoch = 0;
    range.duration.value = (int64_t)((t1 - t0) * ts);
    range.duration.timescale = ts;
    range.duration.flags = 1;
    range.duration.epoch = 0;
    ((void (*)(id, SEL, OV_CMTimeRange, double))objc_msgSend)(tv, zoomSel, range, 0.0);
}

#pragma mark - Mouse

- (OV_DragMode)dragModeForLocalPoint:(NSPoint)loc visibleRect:(NSRect)vis {
    if (NSIsEmptyRect(vis)) return OV_DRAG_SEEK;
    // Edge zones take priority over body. When the rect is narrower than the
    // combined grab zones, prefer left edge for the left half, right for the
    // right half so neither becomes unreachable.
    CGFloat leftEdge  = NSMinX(vis);
    CGFloat rightEdge = NSMaxX(vis);
    BOOL nearLeft  = fabs(loc.x - leftEdge)  <= kOverviewEdgeGrabWidth;
    BOOL nearRight = fabs(loc.x - rightEdge) <= kOverviewEdgeGrabWidth;
    if (nearLeft && nearRight) {
        return (loc.x <= (leftEdge + rightEdge) * 0.5) ? OV_DRAG_ZOOM_LEFT : OV_DRAG_ZOOM_RIGHT;
    }
    if (nearLeft)  return OV_DRAG_ZOOM_LEFT;
    if (nearRight) return OV_DRAG_ZOOM_RIGHT;
    if (loc.x > leftEdge && loc.x < rightEdge) return OV_DRAG_SCROLL;
    return OV_DRAG_SEEK;
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];

    // Double-click anywhere → seek to that point, regardless of hit zone.
    // This is the fastest way to jump the playhead without caring whether
    // the click landed inside or outside the visible-region rectangle.
    if (event.clickCount >= 2) {
        [self seekToSeconds:[self timeForLocalX:loc.x]];
        [self setNeedsDisplay:YES];
        return;
    }

    NSRect vis = [self visibleRegionRect];
    double t0 = 0, t1 = 0;
    [self visibleRegionTimeT0:&t0 t1:&t1];
    double duration = OV_sequenceDurationSeconds();

    OV_DragMode mode = [self dragModeForLocalPoint:loc visibleRect:vis];

    // Anchor state for each mode
    double anchorT0 = t0;              // SCROLL: time under mouse at mouseDown
    double anchorT1 = t1;              // ZOOM_*: fixed opposite edge
    double mouseTimeAtDown = [self timeForLocalX:loc.x];
    double scrollOffsetInTime = mouseTimeAtDown - t0; // SCROLL: keep this offset

    if (mode == OV_DRAG_SEEK) {
        [self seekToSeconds:mouseTimeAtDown];
        [self setNeedsDisplay:YES];
    } else if (mode == OV_DRAG_SCROLL) {
        [[NSCursor closedHandCursor] push];
    } else {
        [[NSCursor resizeLeftRightCursor] push];
    }

    BOOL pushed = (mode != OV_DRAG_SEEK);

    @try {
        while (YES) {
            NSEvent *next = [self.window nextEventMatchingMask:
                NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
            if (!next) break;
            NSPoint p = [self convertPoint:next.locationInWindow fromView:nil];
            double t = [self timeForLocalX:p.x];

            switch (mode) {
                case OV_DRAG_SEEK: {
                    [self seekToSeconds:t];
                    break;
                }
                case OV_DRAG_SCROLL: {
                    double newT0 = t - scrollOffsetInTime;
                    double width = anchorT1 - anchorT0;
                    if (newT0 < 0) newT0 = 0;
                    if (newT0 + width > duration) newT0 = duration - width;
                    if (newT0 < 0) newT0 = 0;
                    [self scrollMainTimelineToTime:newT0];
                    break;
                }
                case OV_DRAG_ZOOM_LEFT: {
                    double newT0 = t;
                    if (newT0 < 0) newT0 = 0;
                    if (newT0 > anchorT1 - 0.1) newT0 = anchorT1 - 0.1;
                    [self zoomMainTimelineToT0:newT0 t1:anchorT1];
                    [self scrollMainTimelineToTime:newT0];
                    break;
                }
                case OV_DRAG_ZOOM_RIGHT: {
                    double newT1 = t;
                    if (newT1 > duration) newT1 = duration;
                    if (newT1 < anchorT0 + 0.1) newT1 = anchorT0 + 0.1;
                    [self zoomMainTimelineToT0:anchorT0 t1:newT1];
                    [self scrollMainTimelineToTime:anchorT0];
                    break;
                }
            }
            [self setNeedsDisplay:YES];
            if (next.type == NSEventTypeLeftMouseUp) break;
        }
    } @finally {
        if (pushed) [NSCursor pop];
    }
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect vis = [self visibleRegionRect];
    OV_DragMode hover = [self dragModeForLocalPoint:loc visibleRect:vis];
    switch (hover) {
        case OV_DRAG_ZOOM_LEFT:
        case OV_DRAG_ZOOM_RIGHT:
            [[NSCursor resizeLeftRightCursor] set];
            break;
        case OV_DRAG_SCROLL:
            [[NSCursor openHandCursor] set];
            break;
        default:
            [[NSCursor arrowCursor] set];
            break;
    }
}

- (void)mouseExited:(NSEvent *)event {
    [[NSCursor arrowCursor] set];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in [self.trackingAreas copy]) {
        [self removeTrackingArea:a];
    }
    NSTrackingArea *area = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                     NSTrackingActiveAlways | NSTrackingInVisibleRect
               owner:self userInfo:nil];
    [self addTrackingArea:area];
}

#pragma mark - Display Link (drives playhead redraw during playback)

- (void)displayLinkFired:(CADisplayLink *)link {
    [self setNeedsDisplay:YES];
}

- (void)startDisplayLink {
    if (self.displayLink) return;
    CADisplayLink *link = [self.window displayLinkWithTarget:self
                                                    selector:@selector(displayLinkFired:)];
    if (!link) {
        // Window may not be attached yet — fall back to the main-screen display.
        link = [NSScreen.mainScreen displayLinkWithTarget:self
                                                 selector:@selector(displayLinkFired:)];
    }
    if (!link) return;
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.displayLink = link;
}

- (void)stopDisplayLink {
    [self.displayLink invalidate];
    self.displayLink = nil;
}

- (void)setPlaying:(BOOL)playing {
    if (_playing == playing) return;
    _playing = playing;
    if (playing) {
        [self startDisplayLink];
    } else {
        [self stopDisplayLink];
        [self setNeedsDisplay:YES]; // one final paint at the stop position
    }
}

@end

#pragma mark - Installation

static BOOL      sOverviewBarInstalled = NO;
static NSPanel  *sOverviewPanel = nil;

static BOOL OV_findTimelineViews(NSView *view,
                                 NSInteger depth,
                                 NSView **timelineViewOut,
                                 NSClipView **clipViewOut,
                                 NSView **scrollViewOut) {
    if (!view || depth > 20) return NO;
    NSString *cn = NSStringFromClass([view class]);
    if ([cn isEqualToString:@"FFProTimelineView"]) {
        if (timelineViewOut) *timelineViewOut = view;
        if ([view.superview isKindOfClass:[NSClipView class]]) {
            NSClipView *clip = (NSClipView *)view.superview;
            if (clipViewOut) *clipViewOut = clip;
            if (scrollViewOut) *scrollViewOut = clip.superview;
        }
        return YES;
    }
    for (NSView *sub in view.subviews) {
        if (OV_findTimelineViews(sub, depth + 1, timelineViewOut, clipViewOut, scrollViewOut)) {
            return YES;
        }
    }
    return NO;
}

static void OV_repositionPanel(void) {
    if (!sOverviewPanel || !sOverviewBarInstalled) return;
    NSWindow *parent = nil;
    for (NSWindow *w in [NSApp windows]) {
        if ([NSStringFromClass([w class]) containsString:@"PEWindow"]) {
            parent = w;
            break;
        }
    }
    if (!parent) return;
    NSClipView *clip = nil;
    NSView *scroll = nil;
    OV_findTimelineViews(parent.contentView, 0, NULL, &clip, &scroll);
    if (!clip) return;
    // Use the scroll view's wrapper (the NSView the split view sizes to) for
    // X/width — the LKScrollView is 3px wider than its allotted area.
    NSView *widthRef = (scroll && scroll.superview) ? scroll.superview : (NSView *)clip;
    NSRect widthScreen = [widthRef convertRect:widthRef.bounds toView:nil];
    widthScreen = [parent convertRectToScreen:widthScreen];
    NSRect clipScreen = [clip convertRect:clip.bounds toView:nil];
    clipScreen = [parent convertRectToScreen:clipScreen];
    NSRect panelFrame = NSMakeRect(
        widthScreen.origin.x,
        clipScreen.origin.y + clipScreen.size.height - kOverviewBarHeight - kOverviewBarTopInset,
        widthScreen.size.width,
        kOverviewBarHeight
    );
    [sOverviewPanel setFrame:panelFrame display:YES];
}

// Edits, scrub, and playback are all driven by FCP's own notifications — no
// polling. Coalesce multiple edit notifications within a single run-loop turn
// into a single re-render via NSObject's performSelector mechanism.
static void OV_scheduleRerender(void) {
    SpliceKitTimelineOverviewView *v = [SpliceKitTimelineOverviewView shared];
    [NSObject cancelPreviousPerformRequestsWithTarget:v
                                             selector:@selector(invalidateImageCacheAndRerender)
                                               object:nil];
    [v performSelector:@selector(invalidateImageCacheAndRerender)
            withObject:nil
            afterDelay:0.0
               inModes:@[NSRunLoopCommonModes]];
}

static int sOverviewInstallRetries = 0;

void SpliceKit_installTimelineOverviewBar(void) {
    if (sOverviewBarInstalled) return;

    SpliceKit_executeOnMainThread(^{
        NSWindow *parent = nil;
        for (NSWindow *w in [NSApp windows]) {
            if ([NSStringFromClass([w class]) containsString:@"PEWindow"]) {
                parent = w;
                break;
            }
        }
        if (!parent) {
            // PEWindow may not exist yet during app-launch auto-install.
            // Retry for ~15 seconds before giving up.
            if (sOverviewInstallRetries < 30
                && SpliceKit_isTimelineOverviewBarEnabled()) {
                sOverviewInstallRetries++;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    SpliceKit_installTimelineOverviewBar();
                });
            } else {
                SpliceKit_log(@"[Overview] PEWindow not found — giving up after %d retries",
                              sOverviewInstallRetries);
            }
            return;
        }
        sOverviewInstallRetries = 0;

        NSView *timelineView = nil;
        NSClipView *clipView = nil;
        NSView *scrollView = nil;
        OV_findTimelineViews(parent.contentView, 0, &timelineView, &clipView, &scrollView);
        if (!timelineView || !scrollView) {
            SpliceKit_log(@"[Overview] FFProTimelineView not found — cannot install");
            return;
        }

        SpliceKitTimelineOverviewView *bar = [SpliceKitTimelineOverviewView shared];
        bar.fcpTimelineView = timelineView;
        bar.fcpClipView = clipView;

        NSView *widthRef = scrollView.superview ?: (NSView *)clipView;
        NSRect widthScreen = [widthRef convertRect:widthRef.bounds toView:nil];
        widthScreen = [parent convertRectToScreen:widthScreen];
        NSRect clipScreen = [clipView convertRect:clipView.bounds toView:nil];
        clipScreen = [parent convertRectToScreen:clipScreen];
        NSRect panelFrame = NSMakeRect(
            widthScreen.origin.x,
            clipScreen.origin.y + clipScreen.size.height - kOverviewBarHeight - kOverviewBarTopInset,
            widthScreen.size.width,
            kOverviewBarHeight
        );

        sOverviewPanel = [[NSPanel alloc] initWithContentRect:panelFrame
                                                    styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        sOverviewPanel.level = NSNormalWindowLevel;
        sOverviewPanel.backgroundColor = [NSColor clearColor];
        sOverviewPanel.opaque = NO;
        sOverviewPanel.hasShadow = NO;
        sOverviewPanel.ignoresMouseEvents = NO;
        sOverviewPanel.acceptsMouseMovedEvents = YES;
        sOverviewPanel.floatingPanel = YES;
        sOverviewPanel.becomesKeyOnlyIfNeeded = YES;
        sOverviewPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                            NSWindowCollectionBehaviorTransient;

        if (bar.superview) [bar removeFromSuperview];
        bar.frame = NSMakeRect(0, 0, panelFrame.size.width, kOverviewBarHeight);
        bar.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        // Clear any debug background
        bar.wantsLayer = YES;
        bar.layer.backgroundColor = [NSColor clearColor].CGColor;
        sOverviewPanel.contentView = bar;

        [parent addChildWindow:sOverviewPanel ordered:NSWindowAbove];
        [sOverviewPanel orderFront:nil];

        [bar rerenderIfNeeded];

        // ── Playback state → CADisplayLink ─────────────────────────────────
        // These notifications tell us exactly when playback starts and stops.
        // We run the display link only between them, matching FCP's own
        // playhead-redraw cadence (60Hz or 120Hz ProMotion) with zero CPU
        // when idle.
        [[NSNotificationCenter defaultCenter] addObserverForName:@"PEPlayerDidBeginPlaybackNotification"
            object:nil queue:nil usingBlock:^(NSNotification *n) {
            [[SpliceKitTimelineOverviewView shared] setPlaying:YES];
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:@"PEPlayerDidEndPlaybackNotification"
            object:nil queue:nil usingBlock:^(NSNotification *n) {
            [[SpliceKitTimelineOverviewView shared] setPlaying:NO];
        }];

        // ── Playhead scrub / step (not playback) → one-shot setNeedsDisplay ─
        [[NSNotificationCenter defaultCenter] addObserverForName:@"TLKPlayheadViewFrameDidChangeNotification"
            object:nil queue:nil usingBlock:^(NSNotification *n) {
            [[SpliceKitTimelineOverviewView shared] setNeedsDisplay:YES];
        }];

        // ── Timeline content edits → invalidate image + rerender ───────────
        // FFSequenceEditedNotification fires for every mutation of the spine
        // (blade, insert, delete, move, ripple, etc). Coalesced so a compound
        // edit results in a single re-render.
        [[NSNotificationCenter defaultCenter] addObserverForName:@"FFSequenceEditedNotification"
            object:nil queue:nil usingBlock:^(NSNotification *n) {
            OV_scheduleRerender();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:@"FFSequenceRangesChangedNotification"
            object:nil queue:nil usingBlock:^(NSNotification *n) {
            OV_scheduleRerender();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:@"FFEffectsChangedNotification"
            object:nil queue:nil usingBlock:^(NSNotification *n) {
            OV_scheduleRerender();
        }];

        // ── Project / sequence becoming active → render the miniature ──────
        // These fire when a project is opened, or when the active sequence is
        // swapped (e.g. opening a compound clip). Without listening for them
        // the bar stays blank until the user touches something that triggers
        // an edit or scroll notification.
        [[NSNotificationCenter defaultCenter] addObserverForName:@"activeRootItemDidChange"
            object:nil queue:nil usingBlock:^(NSNotification *n) {
            OV_scheduleRerender();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:@"PEActivePlayerModuleDidChangeNotification"
            object:nil queue:nil usingBlock:^(NSNotification *n) {
            OV_scheduleRerender();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:@"FFTimelineIndexDidReloadArrangedItemsNotification"
            object:nil queue:nil usingBlock:^(NSNotification *n) {
            OV_scheduleRerender();
        }];

        // Seed the initial playback state in case playback is already active.
        id tm = SpliceKit_getActiveTimelineModule();
        if (tm) {
            SEL isPlayingSel = NSSelectorFromString(@"isPlaying");
            if ([tm respondsToSelector:isPlayingSel]) {
                BOOL playing = ((BOOL (*)(id, SEL))objc_msgSend)(tm, isPlayingSel);
                [bar setPlaying:playing];
            }
        }

        // Re-render on scroll/zoom so the visible-region rectangle stays accurate
        [[NSNotificationCenter defaultCenter] addObserverForName:NSViewBoundsDidChangeNotification
            object:clipView queue:nil usingBlock:^(NSNotification *n) {
            [[SpliceKitTimelineOverviewView shared] setNeedsDisplay:YES];
        }];
        clipView.postsBoundsChangedNotifications = YES;
        [[NSNotificationCenter defaultCenter] addObserverForName:NSViewFrameDidChangeNotification
            object:timelineView queue:nil usingBlock:^(NSNotification *n) {
            // Zoom change -> visible region width changes
            [[SpliceKitTimelineOverviewView shared] setNeedsDisplay:YES];
        }];

        // Reposition when the timeline scroll view's frame changes (e.g. the
        // user opens/closes a sidebar, the inspector, or drags a split view).
        // This is independent of window resize — the containing splitter moves
        // without the window changing size.
        scrollView.postsFrameChangedNotifications = YES;
        clipView.postsFrameChangedNotifications = YES;
        NSView *widthRefObserve = scrollView.superview;
        if (widthRefObserve) widthRefObserve.postsFrameChangedNotifications = YES;
        [[NSNotificationCenter defaultCenter] addObserverForName:NSViewFrameDidChangeNotification
            object:scrollView queue:nil usingBlock:^(NSNotification *n) {
            OV_repositionPanel();
            OV_scheduleRerender();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSViewFrameDidChangeNotification
            object:clipView queue:nil usingBlock:^(NSNotification *n) {
            OV_repositionPanel();
            OV_scheduleRerender();
        }];
        if (widthRefObserve) {
            [[NSNotificationCenter defaultCenter] addObserverForName:NSViewFrameDidChangeNotification
                object:widthRefObserve queue:nil usingBlock:^(NSNotification *n) {
                OV_repositionPanel();
                OV_scheduleRerender();
            }];
        }

        // Reposition on window move/resize
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResizeNotification
            object:parent queue:nil usingBlock:^(NSNotification *n) {
            OV_repositionPanel();
            OV_scheduleRerender();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidMoveNotification
            object:parent queue:nil usingBlock:^(NSNotification *n) {
            OV_repositionPanel();
        }];

        sOverviewBarInstalled = YES;
        SpliceKit_log(@"[Overview] Timeline overview bar installed at %@",
                      NSStringFromRect(panelFrame));
    });
}

void SpliceKit_uninstallTimelineOverviewBar(void) {
    if (!sOverviewBarInstalled) return;
    SpliceKit_executeOnMainThread(^{
        SpliceKitTimelineOverviewView *bar = [SpliceKitTimelineOverviewView shared];
        [bar setPlaying:NO];
        [bar stopDisplayLink];
        [NSObject cancelPreviousPerformRequestsWithTarget:bar];
        [[NSNotificationCenter defaultCenter] removeObserver:bar];
        if (sOverviewPanel) {
            [sOverviewPanel.parentWindow removeChildWindow:sOverviewPanel];
            [sOverviewPanel orderOut:nil];
            sOverviewPanel = nil;
        }
        sOverviewBarInstalled = NO;
        SpliceKit_log(@"[Overview] Timeline overview bar uninstalled");
    });
}

BOOL SpliceKit_isTimelineOverviewBarEnabled(void) {
    NSNumber *v = [[NSUserDefaults standardUserDefaults] objectForKey:kOverviewDefaultsKey];
    return v ? [v boolValue] : NO;
}

void SpliceKit_setTimelineOverviewBarEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kOverviewDefaultsKey];
    if (enabled) {
        SpliceKit_installTimelineOverviewBar();
    } else {
        SpliceKit_uninstallTimelineOverviewBar();
    }
}
