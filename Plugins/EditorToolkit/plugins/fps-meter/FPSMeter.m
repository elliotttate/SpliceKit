// FPS Meter - live playback frame rate in Final Cut Pro's viewer header (Resolve-style).
//
// What it measures: the frames Final Cut's viewer actually puts on screen. On every display refresh the viewer's
// display destination (FFDestVideoDisplay -drawNow:) picks the frame to show; we look at which frame that is.
// A new frame time = one more frame delivered; a jump of n frame-durations = n-1 frames skipped (Final Cut skips
// frames instead of slowing down when it can't keep up). Target = the frame rate of whatever the viewer is playing
// (project or clip) x play speed. Nothing is estimated from the clock or the playhead.
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <os/lock.h>

#ifndef FMNOTE
#define FMNOTE @"SKFPS"
#endif
static NSString *const kEnabledKey = @"SpliceKitFPSIndicatorEnabled";
static NSString *gLogPath;
static void FLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
    if (!h) { [line writeToFile:gLogPath atomically:NO encoding:NSUTF8StringEncoding error:nil]; return; }
    [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}
static double HostNow(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9; }

#pragma mark - measurement (display-link thread)
#define RING 1024
typedef struct {
    void *dest;                 // FFDestVideoDisplay (not retained)
    os_unfair_lock lock;
    CMTime lastFrame;           // time of the frame on screen at the previous refresh
    double times[RING];         // host time each NEW frame went on screen
    unsigned char skipped[RING];// frames jumped over to reach it
    unsigned head, count;
    double frameDur, rate;      // what the viewer is playing: seconds per frame, play speed
    double playStart, lastSeen; // host times
    double health;              // Final Cut's own 0..1 playback health for this destination
    long runFrames, runSkipped; double runFirst, runLast, runMaxHold;  // whole play run
} Slot;
static Slot gSlots[4];
static os_unfair_lock gSlotsLock = OS_UNFAIR_LOCK_INIT;
static ptrdiff_t gOffLastFrame = -1;
static IMP oDraw, oHealth;
static volatile BOOL gEnabled = YES;

static Slot *SlotFor(void *d, BOOL create) {
    for (int i = 0; i < 4; i++) if (gSlots[i].dest == d) return &gSlots[i];
    if (!create) return NULL;
    os_unfair_lock_lock(&gSlotsLock);
    Slot *s = NULL;
    for (int i = 0; i < 4 && !s; i++) if (!gSlots[i].dest) s = &gSlots[i];
    if (!s) { double oldest = 1e300; for (int i = 0; i < 4; i++) if (gSlots[i].lastSeen < oldest) { oldest = gSlots[i].lastSeen; s = &gSlots[i]; } }
    memset(s, 0, sizeof *s); s->lock = OS_UNFAIR_LOCK_INIT; s->lastFrame = kCMTimeInvalid; s->health = -1; s->dest = d;
    os_unfair_lock_unlock(&gSlotsLock);
    return s;
}
static int hDraw(id self, SEL _cmd, const void *ts) {
    int r = ((int(*)(id, SEL, const void *))oDraw)(self, _cmd, ts);
    if (!gEnabled || gOffLastFrame < 0) return r;
    BOOL playing = ((BOOL(*)(id, SEL))objc_msgSend)(self, @selector(_isPlayingOrPrerolling));
    Slot *s = SlotFor((__bridge void *)self, playing);
    if (!s) return r;
    double now = HostNow();
    os_unfair_lock_lock(&s->lock);
    if (!playing) { s->lastFrame = kCMTimeInvalid; s->playStart = 0; os_unfair_lock_unlock(&s->lock); return r; }
    void *fp = *(void **)((char *)(__bridge void *)self + gOffLastFrame);
    if (fp) {
        CMTime t = ((CMTime(*)(id, SEL))objc_msgSend)((__bridge id)fp, @selector(time));
        if (!s->playStart) { s->playStart = now; s->head = s->count = 0; s->runFrames = s->runSkipped = 0; s->runFirst = s->runLast = 0; s->runMaxHold = 0; s->lastFrame = t; }
        else if (CMTIME_IS_VALID(t) && CMTimeCompare(t, s->lastFrame) != 0) {
            if (!s->runFrames || s->frameDur <= 0) {
                CMTime sd = ((CMTime(*)(id, SEL))objc_msgSend)(self, @selector(sampleDuration));
                s->frameDur = CMTimeGetSeconds(sd);
                id pl = ((id(*)(id, SEL))objc_msgSend)(self, @selector(player));
                s->rate = pl ? ((double(*)(id, SEL))objc_msgSend)(pl, @selector(rate)) : 1;
            }
            double dt = CMTimeGetSeconds(CMTimeSubtract(t, s->lastFrame));
            long n = s->frameDur > 0 ? lround(fabs(dt) / s->frameDur) : 1;
            long expected = MAX(1, lround(fabs(s->rate)));         // at 2x every other frame is skipped by design
            long skip = n > expected ? n - expected : 0;
            // a jump against the play direction or of more than half a second is a seek/loop, not a dropped run
            if ((dt < 0) != (s->rate < 0) || fabs(dt) > 0.5 * MAX(1.0, fabs(s->rate))) skip = 0;
            if (skip > 255) skip = 255;
            if (s->runLast > 0) s->runMaxHold = MAX(s->runMaxHold, now - s->runLast);
            unsigned i = (s->head + s->count) % RING;
            if (s->count == RING) { s->head = (s->head + 1) % RING; s->count--; }
            s->times[i] = now; s->skipped[i] = (unsigned char)skip; s->count++;
            if (!s->runFirst) s->runFirst = now;
            s->runLast = now; s->runFrames++; s->runSkipped += skip;
            s->lastFrame = t;
        }
    }
    s->lastSeen = now;
    os_unfair_lock_unlock(&s->lock);
    return r;
}
static void hHealth(id self, SEL _cmd, float h, float d) {
    Slot *s = SlotFor((__bridge void *)self, NO); if (s) s->health = h;
    ((void(*)(id, SEL, float, float))oHealth)(self, _cmd, h, d);
}

#pragma mark - indicator view (lives in the viewer header, next to "1080 × 1920 | 25 fps, Stereo")
@interface FMDot : NSView @property (nonatomic, strong) NSColor *color; @end
@implementation FMDot
- (BOOL)isFlipped { return YES; }
- (void)setColor:(NSColor *)c { if ([_color isEqual:c]) return; _color = c; self.needsDisplay = YES; }
- (NSSize)intrinsicContentSize { return NSMakeSize(8, 8); }
- (void)drawRect:(NSRect)r {
    [(self.color ?: [NSColor tertiaryLabelColor]) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(self.bounds, 0.5, 0.5)] fill];
}
@end
@interface FMIndicator : NSStackView
@property (strong) FMDot *dot; @property (strong) NSTextField *label; @property (weak) NSTextField *info;
@end
@implementation FMIndicator
+ (instancetype)indicatorMatching:(NSTextField *)info {
    FMIndicator *v = [FMIndicator new];
    v.orientation = NSUserInterfaceLayoutOrientationHorizontal; v.alignment = NSLayoutAttributeCenterY; v.spacing = 5;
    v.info = info;
    v.dot = [FMDot new]; v.dot.translatesAutoresizingMaskIntoConstraints = NO;
    [v.dot.widthAnchor constraintEqualToConstant:8].active = YES; [v.dot.heightAnchor constraintEqualToConstant:8].active = YES;
    v.label = [NSTextField labelWithString:@""];
    NSFont *f = info.font ?: [NSFont systemFontOfSize:13 weight:NSFontWeightThin];
    NSFontDescriptor *fd = [f.fontDescriptor fontDescriptorByAddingAttributes:@{ NSFontFeatureSettingsAttribute: @[@{ NSFontFeatureTypeIdentifierKey: @(kNumberSpacingType), NSFontFeatureSelectorIdentifierKey: @(kMonospacedNumbersSelector) }] }];
    v.label.font = [NSFont fontWithDescriptor:fd size:f.pointSize] ?: f;
    v.label.textColor = info.textColor ?: [NSColor textColor];
    v.label.lineBreakMode = NSLineBreakByClipping;
    [v addArrangedSubview:v.dot]; [v addArrangedSubview:v.label];
    v.identifier = @"SpliceKitFPSIndicator";
    v.hidden = YES;
    return v;
}
@end

#pragma mark - wiring the indicator to the right viewer
static NSTextField *FindInfoLabel(NSView *v) {
    if ([v isKindOfClass:[NSTextField class]] && !v.hidden && [((NSTextField *)v).stringValue rangeOfString:@" fps"].location != NSNotFound && [v.superview isKindOfClass:[NSStackView class]]) return (NSTextField *)v;
    for (NSView *s in v.subviews) { NSTextField *r = FindInfoLabel(s); if (r) return r; }
    return nil;
}
static NSView *ViewForDest(void *dest) {
    id d = ((id(*)(id, SEL))objc_msgSend)((__bridge id)dest, @selector(delegate));
    if ([d isKindOfClass:[NSView class]]) return d;
    for (NSString *k in @[@"view", @"videoView", @"playerView", @"canvasView"]) if ([d respondsToSelector:NSSelectorFromString(k)]) { id v = ((id(*)(id, SEL))objc_msgSend)(d, NSSelectorFromString(k)); if ([v isKindOfClass:[NSView class]]) return v; }
    return nil;
}
static NSTextField *InfoLabelForDest(void *dest) {
    NSView *v = ViewForDest(dest);
    for (NSView *a = v; a; a = a.superview)                 // the viewer's container holds both the picture and its header
        if ([NSStringFromClass([a class]) isEqualToString:@"LKContainerItemView"]) { NSTextField *l = FindInfoLabel(a); if (l) return l; }
    NSWindow *w = v.window ?: NSApp.mainWindow;              // fallback: the viewer header in the main window
    return FindInfoLabel(w.contentView);
}
static NSMapTable *gIndicators;   // info label -> indicator

static FMIndicator *IndicatorFor(NSTextField *info) {
    if (!info) return nil;
    FMIndicator *ind = [gIndicators objectForKey:info];
    if (ind && ind.superview) return ind;
    NSStackView *stack = (NSStackView *)info.superview;
    if (![stack isKindOfClass:[NSStackView class]]) return nil;
    ind = [FMIndicator indicatorMatching:info];
    NSUInteger idx = [stack.arrangedSubviews indexOfObject:info];
    [stack insertArrangedSubview:ind atIndex:idx == NSNotFound ? stack.arrangedSubviews.count : idx + 1];
    [stack setCustomSpacing:10 afterView:info];
    [gIndicators setObject:ind forKey:info];
    return ind;
}
static NSString *Num(double fps) { return fabs(fps - round(fps)) < 0.005 ? [NSString stringWithFormat:@"%.0f", fps] : [NSString stringWithFormat:@"%.2f", fps]; }

#pragma mark - UI refresh (main thread, 4x a second)
typedef struct { BOOL valid, playing; double fps, target, rate, health, maxHold, span; long skipped1s, skipped3s, runFrames, runSkipped; double runFps; } Reading;
static Reading Read(Slot *s, double now) {
    Reading r = {0};
    os_unfair_lock_lock(&s->lock);
    r.playing = s->playStart > 0 && now - s->lastSeen < 0.25;
    r.target = s->frameDur > 0 ? fabs(s->rate ?: 1) / s->frameDur : 0; r.rate = s->rate ?: 1; r.health = s->health;
    double since = r.playing ? now - s->playStart : 0;
    if (s->count >= 2 && s->frameDur > 0) {
        double win = MIN(1.0, MAX(since - 0.3, 0.001));        // ignore the first moments of preroll
        long n = 0;
        for (unsigned k = 0; k < s->count; k++) {
            unsigned i = (s->head + k) % RING;
            double age = now - s->times[i];
            if (age <= win) n++;
            if (age <= 1.0) r.skipped1s += s->skipped[i];
            if (age <= 3.0 && s->times[i] - s->playStart > 0.3) r.skipped3s += s->skipped[i];
        }
        r.fps = n / win; r.span = since; r.valid = since >= 0.6;
    }
    r.runFrames = s->runFrames; r.runSkipped = s->runSkipped; r.maxHold = s->runMaxHold;
    r.runFps = (s->runFrames > 1 && s->runLast > s->runFirst) ? (s->runFrames - 1) / (s->runLast - s->runFirst) : 0;
    os_unfair_lock_unlock(&s->lock);
    return r;
}
typedef enum { FMGray, FMGreen, FMAmber, FMRed } FMState;
static NSColor *ColorFor(FMState s) {
    switch (s) {
        case FMGreen: return [NSColor colorWithSRGBRed:0.20 green:0.78 blue:0.35 alpha:1];
        case FMAmber: return [NSColor colorWithSRGBRed:1.00 green:0.70 blue:0.00 alpha:1];
        case FMRed:   return [NSColor colorWithSRGBRed:1.00 green:0.27 blue:0.23 alpha:1];
        default:      return [NSColor tertiaryLabelColor];
    }
}
static FMState Judge(double fps, double target, long skipped, double rate) {
    if (target <= 0 || fabs(fabs(rate) - 1) > 0.01) return FMGray;          // fast-forward / slow-mo: no verdict
    double ratio = fps / target;
    if (ratio >= 0.97 && skipped == 0) return FMGreen;
    if (ratio >= 0.85 && skipped <= 3) return FMAmber;
    return FMRed;
}
static void *gShownDest; static double gStoppedAt;
static void Refresh(void) {
    double now = HostNow();
    // the destination that most recently put a new frame on screen
    Slot *best = NULL; double bestT = 0;
    for (int i = 0; i < 4; i++) if (gSlots[i].dest && gSlots[i].runLast > bestT) { bestT = gSlots[i].runLast; best = &gSlots[i]; }
    for (FMIndicator *ind in [[gIndicators objectEnumerator] allObjects]) if (!gEnabled || (best && ind.info != InfoLabelForDest(best->dest))) ind.hidden = YES;
    if (!gEnabled || !best) return;
    Reading r = Read(best, now);
    FMIndicator *ind = IndicatorFor(InfoLabelForDest(best->dest));
    if (!ind) return;
    NSString *target = r.target > 0 ? Num(r.target) : @"?";
    if (r.playing) {
        gStoppedAt = 0; gShownDest = best->dest;
        ind.hidden = NO; ind.alphaValue = 1;
        if (!r.valid) { ind.dot.color = ColorFor(FMGray); ind.label.stringValue = [NSString stringWithFormat:@"– / %@ fps", target]; }
        else {
            FMState st = Judge(r.fps, r.target, r.skipped3s, r.rate);
            ind.dot.color = ColorFor(st);
            double shown = (st == FMGreen) ? MIN(r.fps, r.target) : r.fps;   // a 75 Hz refresh can't add frames: cap the jitter
            ind.label.stringValue = [NSString stringWithFormat:@"%.1f / %@ fps", shown, target];
        }
        ind.toolTip = [NSString stringWithFormat:@"Playback: %.1f of %@ frames per second reached the viewer%@\nFrames skipped: %ld in the last 3 s, %ld this play\nLongest a frame stayed on screen: %.0f ms (one frame is %.0f ms)%@",
            r.fps, target, fabs(r.rate - 1) > 0.01 ? [NSString stringWithFormat:@" (playing at %.2gx)", r.rate] : @"", r.skipped3s, r.runSkipped, r.maxHold * 1000, r.target > 0 ? 1000 / r.target : 0,
            r.health >= 0 ? [NSString stringWithFormat:@"\nFinal Cut playback health: %.0f%%", r.health * 100] : @""];
    } else if (gShownDest == best->dest && r.runFrames > 1) {
        if (!gStoppedAt) {
            gStoppedAt = now;
            FMState st = Judge(r.runFps, r.target, r.runSkipped, r.rate);
            ind.dot.color = ColorFor(st);
            ind.label.stringValue = [NSString stringWithFormat:@"last play %.1f / %@ fps%@", MIN(r.runFps, st == FMGreen ? r.target : 1e9), target, r.runSkipped ? [NSString stringWithFormat:@", %ld skipped", r.runSkipped] : @""];
            ind.alphaValue = 0.75;
            FLog(@"play finished: %.2f / %@ fps, %ld frames, %ld skipped, longest hold %.0f ms, health %.2f", r.runFps, target, r.runFrames, r.runSkipped, r.maxHold * 1000, r.health);
        } else if (now - gStoppedAt > 6) { ind.hidden = YES; gShownDest = NULL; }
    } else ind.hidden = YES;
}

#pragma mark - install
static void ToggleEnabled(id sender) {
    gEnabled = !gEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:gEnabled forKey:kEnabledKey];
    if ([sender isKindOfClass:[NSMenuItem class]]) ((NSMenuItem *)sender).state = gEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    Refresh();
}
static void InstallMenu(void) {
    NSMenuItem *viewItem = nil;
    for (NSMenuItem *it in NSApp.mainMenu.itemArray) if ([it.title isEqualToString:@"View"]) viewItem = it;
    NSMenu *m = viewItem.submenu; if (!m || [m itemWithTitle:@"Playback Frame Rate"]) return;
    NSInteger idx = m.numberOfItems;
    for (NSInteger i = 0; i < m.numberOfItems; i++) if ([[m itemAtIndex:i].title hasPrefix:@"Show Video Scopes"] || [[m itemAtIndex:i].title hasPrefix:@"Show Video Animation"]) { idx = i; break; }
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:@"Playback Frame Rate" action:NSSelectorFromString(@"spliceKitToggleFPSIndicator:") keyEquivalent:@""];
    it.state = gEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [m insertItem:it atIndex:idx];
}
__attribute__((visibility("default"))) void SpliceKitPlugin_init(void *api) { (void)api; }
static void Install(void) {
    static BOOL done; if (done) return; done = YES;
    Class c = objc_getClass("FFDestVideoDisplay"), base = objc_getClass("FFDestVideo");
    Ivar iv = c ? class_getInstanceVariable(c, "_lastSelectedFrame") : NULL;
    Method md = c ? class_getInstanceMethod(c, @selector(drawNow:)) : NULL;
    Method mh = base ? class_getInstanceMethod(base, @selector(setLastHealthMetric:diskHealth:)) : NULL;
    BOOL ok = iv && md && [c instancesRespondToSelector:@selector(_isPlayingOrPrerolling)] && [c instancesRespondToSelector:@selector(sampleDuration)]
        && [objc_getClass("FFPlayerFrame") instancesRespondToSelector:@selector(time)] && [objc_getClass("FFPlayer") instancesRespondToSelector:@selector(rate)];
    if (!ok) { FLog(@"FPS meter disabled: this Final Cut version doesn't have the playback internals it reads"); return; }
    gOffLastFrame = ivar_getOffset(iv);
    oDraw = method_setImplementation(md, (IMP)hDraw);
    if (mh) oHealth = method_setImplementation(mh, (IMP)hHealth);
    gIndicators = [NSMapTable weakToWeakObjectsMapTable];
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kEnabledKey];
    gEnabled = stored ? [stored boolValue] : YES;
    SEL ts = NSSelectorFromString(@"spliceKitToggleFPSIndicator:");
    IMP ti = imp_implementationWithBlock(^(id self, id sender) { ToggleEnabled(sender); });
    if (!class_addMethod([NSApplication class], ts, ti, "v@:@")) class_replaceMethod([NSApplication class], ts, ti, "v@:@");
    InstallMenu();
    [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) { @try { Refresh(); } @catch (id e) { FLog(@"refresh threw %@", e); } }];
    [[NSNotificationCenter defaultCenter] addObserverForName:FMNOTE object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        NSString *cmd = n.object;
        if ([cmd isEqual:@"snap"]) {   // test helper: picture of the viewer header
            for (FMIndicator *ind in [[gIndicators objectEnumerator] allObjects]) {
                NSView *v = ind.superview.superview.superview; if (!v) continue;
                NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds]; [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
                [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/header.png"] atomically:YES];
                FLog(@"snap: '%@' hidden=%d dot=%@ alpha=%.2f tip=%@", ind.label.stringValue, ind.hidden, ind.dot.color, ind.alphaValue, ind.toolTip);
            }
        } else if ([cmd isEqual:@"where"]) {
            for (int i = 0; i < 4; i++) if (gSlots[i].dest) { id d = ((id(*)(id, SEL))objc_msgSend)((__bridge id)gSlots[i].dest, @selector(delegate)); FLog(@"dest %p delegate %@ view %@ label %@", gSlots[i].dest, [d class], [ViewForDest(gSlots[i].dest) class], InfoLabelForDest(gSlots[i].dest).stringValue); }
        }
    }];
    FLog(@"FPS meter ready (%@)", gEnabled ? @"on" : @"off");
}
__attribute__((constructor)) static void fm_init(void) {
    gLogPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/fpsmeter.log"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ Install(); });
}
