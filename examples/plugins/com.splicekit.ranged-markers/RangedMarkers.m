//
//  RangedMarkers.m
//  SpliceKit plugin — ranged and colored timeline markers.
//
//  FCP markers (FFAnchoredTimeMarker) already store a full CMTimeRange; FCP just
//  always creates them one frame long and draws a pin. This plugin:
//    - creates markers with a real duration via FCP's own
//      -[FFAnchoredSequence actionAddMarkerToAnchoredObject:isToDo:isChapter:withRange:error:]
//      (undoable, saved in the library, exported to FCPXML as duration="…")
//    - stores a color as a name tag, e.g. "[Red] Fix audio"
//    - swizzles TLKMarkerLayer so ranged markers draw an always-visible bar and
//      colored markers get a tinted pin
//
//  Works either way it is loaded:
//    - as a native plugin from ~/Library/Application Support/SpliceKit/plugins/ (FCP launch)
//    - hot-loaded with debug.loadPlugin during development (constructor self-registers)
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "SpliceKitPluginAPI.h"

#pragma mark - Types and SpliceKit symbols

typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } RMTime;
typedef struct { RMTime start; RMTime duration; } RMTimeRange;

typedef void (*RMRegisterFn)(NSString *, SpliceKitMethodHandler, NSDictionary *);
typedef void (*RMMainThreadFn)(dispatch_block_t);
typedef id (*RMGetModuleFn)(void);
typedef NSString *(*RMStoreHandleFn)(id);
typedef id (*RMResolveHandleFn)(NSString *);

static RMRegisterFn sRegister;
static RMMainThreadFn sOnMain;
static RMGetModuleFn sGetTimelineModule;
static RMStoreHandleFn sStoreHandle;
static RMResolveHandleFn sResolveHandle;
static BOOL sSetUp;

static NSString *const kBarLayerName = @"skRangedMarkerBar";
static NSString *const kTintLayerName = @"skRangedMarkerTint";
static NSString *const kKnobLayerName = @"skRangedMarkerKnob";
static const NSInteger kMenuTag = 0x524D; // 'RM' — identifies menu items this plugin adds

// Drag state for the range end handle (main thread only).
static CALayer *sDragLayer;
static CGFloat sDragWidth;

static double RMSeconds(RMTime t) { return t.timescale > 0 ? (double)t.value / t.timescale : 0; }
static RMTime RMMakeTime(double s, int32_t ts) { return (RMTime){ (int64_t)llround(s * ts), ts, 1, 0 }; }
static NSDictionary *RMRangeDict(RMTimeRange r) { return @{@"start": @(RMSeconds(r.start)), @"duration": @(RMSeconds(r.duration))}; }

static id RMSend(id obj, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    return (obj && [obj respondsToSelector:sel]) ? ((id (*)(id, SEL))objc_msgSend)(obj, sel) : nil;
}

static BOOL RMReadTime(id obj, NSString *selName, RMTime *out) {
    SEL sel = NSSelectorFromString(selName);
    if (!obj || ![obj respondsToSelector:sel]) return NO;
    *out = ((RMTime (*)(id, SEL))objc_msgSend)(obj, sel);
    return out->timescale > 0;
}

static BOOL RMReadRange(id obj, NSString *selName, RMTimeRange *out) {
    SEL sel = NSSelectorFromString(selName);
    if (!obj || ![obj respondsToSelector:sel]) return NO;
    *out = ((RMTimeRange (*)(id, SEL))objc_msgSend)(obj, sel);
    return out->start.timescale > 0;
}

#pragma mark - Colors (DaVinci Resolve's 16 marker colors, so they round-trip)

static NSDictionary<NSString *, NSColor *> *RMPalette(void) {
    static NSDictionary *palette;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        #define RGB(r, g, b) [NSColor colorWithSRGBRed:(r) / 255.0 green:(g) / 255.0 blue:(b) / 255.0 alpha:1]
        palette = @{
            @"blue": RGB(0, 125, 255),     @"cyan": RGB(0, 205, 230),
            @"green": RGB(40, 200, 70),    @"yellow": RGB(240, 210, 0),
            @"red": RGB(240, 50, 50),      @"pink": RGB(255, 110, 190),
            @"purple": RGB(150, 80, 230),  @"fuchsia": RGB(220, 40, 200),
            @"rose": RGB(255, 140, 150),   @"lavender": RGB(185, 160, 255),
            @"sky": RGB(120, 200, 255),    @"mint": RGB(110, 230, 170),
            @"lemon": RGB(240, 240, 110),  @"sand": RGB(200, 170, 110),
            @"cocoa": RGB(140, 95, 60),    @"cream": RGB(250, 235, 200),
            @"orange": RGB(255, 140, 0),
        };
        #undef RGB
    });
    return palette;
}

// Marker name tags: "[Red] Fix audio", "[Red 12.5s] Fix audio" or "[12.5s] Fix audio".
// The optional duration stores a range longer than FCP allows on the marker's clip
// (FCP limits a marker to the source media of the clip it is attached to).
// Brackets containing anything else are treated as part of the title.
// Returns the stored duration (0 if none); color and title are optional outputs.
static double RMParseTag(NSString *name, NSString **titleOut, NSString **colorOut) {
    if (titleOut) *titleOut = name ?: @"";
    if (colorOut) *colorOut = nil;
    if (![name hasPrefix:@"["]) return 0;
    NSRange close = [name rangeOfString:@"]"];
    if (close.location == NSNotFound || close.location < 2) return 0;
    NSString *inner = [name substringWithRange:NSMakeRange(1, close.location - 1)];
    NSString *color = nil;
    double duration = 0;
    for (NSString *token in [inner.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (!token.length) continue;
        if (RMPalette()[token] && !color) {
            color = token;
        } else if ([token hasSuffix:@"s"] && [[token substringToIndex:token.length - 1] doubleValue] > 0) {
            duration = [[token substringToIndex:token.length - 1] doubleValue];
        } else {
            return 0; // not one of our tags
        }
    }
    if (colorOut) *colorOut = color;
    if (titleOut) {
        *titleOut = [[name substringFromIndex:close.location + 1]
                     stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    return duration;
}

static NSString *RMFormatName(NSString *title, NSString *color, double duration) {
    NSMutableArray *tokens = [NSMutableArray array];
    if (color.length && ![color isEqualToString:@"none"]) {
        [tokens addObject:[[[color substringToIndex:1] uppercaseString] stringByAppendingString:[color substringFromIndex:1]]];
    }
    if (duration > 0) {
        NSString *secs = [NSString stringWithFormat:@"%.3f", duration];
        while ([secs hasSuffix:@"0"]) secs = [secs substringToIndex:secs.length - 1];
        if ([secs hasSuffix:@"."]) secs = [secs substringToIndex:secs.length - 1];
        [tokens addObject:[secs stringByAppendingString:@"s"]];
    }
    if (!tokens.count) return title ?: @"";
    NSString *tag = [NSString stringWithFormat:@"[%@]", [tokens componentsJoinedByString:@" "]];
    return title.length ? [NSString stringWithFormat:@"%@ %@", tag, title] : tag;
}

static NSString *RMParseColorTag(NSString *name, NSString **titleOut) {
    NSString *color = nil;
    RMParseTag(name, titleOut, &color);
    return color;
}

// Replace the color, keeping the title and any stored duration.
static NSString *RMNameWithColor(NSString *name, NSString *color) {
    NSString *title = nil;
    double duration = RMParseTag(name, &title, NULL);
    return RMFormatName(title, color, duration);
}

// Colors FCP uses for its own marker types, for ranged markers with no tag.
static NSColor *RMDefaultColor(id marker) {
    BOOL (^flag)(NSString *) = ^BOOL(NSString *s) {
        SEL sel = NSSelectorFromString(s);
        return [marker respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(marker, sel);
    };
    if (flag(@"isChapter")) return RMPalette()[@"orange"];
    if (flag(@"isTodo")) return flag(@"isCompleted") ? RMPalette()[@"green"] : RMPalette()[@"red"];
    return [NSColor colorWithSRGBRed:0.47 green:0.47 blue:0.95 alpha:1];
}

#pragma mark - Marker model helpers

static BOOL RMIsTimeMarker(id obj) {
    Class cls = NSClassFromString(@"FFAnchoredTimeMarker");
    return cls && [obj isKindOfClass:cls];
}

static double RMFrameSeconds(id obj) {
    RMTime fd;
    if (RMReadTime(obj, @"frameDuration", &fd) && RMSeconds(fd) > 0) return RMSeconds(fd);
    return 1.0 / 24.0;
}

// FCP's own length for the marker (its one-frame markers are 1/48000s long).
static double RMFCPDuration(id marker) {
    RMTime d;
    return RMReadTime(marker, @"duration", &d) ? RMSeconds(d) : 0;
}

// A marker's range is the longer of FCP's duration and a duration stored in its tag.
static BOOL RMIsRanged(id marker, double *durationOut) {
    double secs = MAX(RMFCPDuration(marker), RMParseTag(RMSend(marker, @"displayName"), NULL, NULL));
    if (durationOut) *durationOut = secs;
    return secs > RMFrameSeconds(marker) * 1.5;
}

static id RMActiveSequence(void) {
    id tm = sGetTimelineModule ? sGetTimelineModule() : nil;
    return RMSend(tm, @"sequence");
}

static NSArray *RMSpineItems(id sequence) {
    id items = RMSend(RMSend(sequence, @"primaryObject"), @"containedItems");
    return [items isKindOfClass:[NSArray class]] ? items : @[];
}

// Sequence-time range of a primary storyline item.
static BOOL RMItemRange(id sequence, id item, RMTimeRange *out) {
    id primary = RMSend(sequence, @"primaryObject");
    SEL sel = NSSelectorFromString(@"effectiveRangeOfObject:");
    if (![primary respondsToSelector:sel]) return NO;
    *out = ((RMTimeRange (*)(id, SEL, id))objc_msgSend)(primary, sel, item);
    return out->duration.timescale > 0;
}

// Marker times are in the clip's local (media) time; convert from sequence seconds.
static double RMLocalOffset(id sequence, id item) {
    RMTimeRange seqRange, localRange;
    if (!RMItemRange(sequence, item, &seqRange)) return 0;
    if (!RMReadRange(item, @"clippedRange", &localRange)) return 0;
    return RMSeconds(localRange.start) - RMSeconds(seqRange.start);
}

static id RMSpineItemAtTime(id sequence, double t) {
    for (id item in RMSpineItems(sequence)) {
        if ([NSStringFromClass([item class]) containsString:@"Transition"]) continue;
        RMTimeRange r;
        if (!RMItemRange(sequence, item, &r)) continue;
        double s = RMSeconds(r.start), e = s + RMSeconds(r.duration);
        if (t >= s - 0.001 && t < e) return item;
    }
    return nil;
}

static NSArray *RMMarkersOnItem(id item) {
    id markers = RMSend(item, @"markerAnchoredItems");
    NSMutableArray *out = [NSMutableArray array];
    if ([markers respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) {
        for (id m in markers) if (RMIsTimeMarker(m)) [out addObject:m];
    }
    return out;
}

static NSDictionary *RMDescribeMarker(id sequence, id item, id marker) {
    // targetAnchorTime is the marker's position in its clip's local time.
    RMTime anchor = {0};
    RMReadTime(marker, @"targetAnchorTime", &anchor);
    double seqStart = RMSeconds(anchor) - RMLocalOffset(sequence, item);
    NSString *name = RMSend(marker, @"displayName") ?: @"";
    NSString *title = nil;
    NSString *color = RMParseColorTag(name, &title);
    double duration = 0;
    BOOL ranged = RMIsRanged(marker, &duration);
    BOOL (^flag)(NSString *) = ^BOOL(NSString *s) {
        SEL sel = NSSelectorFromString(s);
        return [marker respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(marker, sel);
    };
    NSString *kind = flag(@"isChapter") ? @"chapter" : flag(@"isTodo") ? (flag(@"isCompleted") ? @"completed" : @"todo") : @"standard";
    NSMutableDictionary *d = [@{
        @"name": name, @"title": title ?: @"", @"kind": kind,
        @"start": @(seqStart), @"duration": @(ranged ? duration : 0), @"ranged": @(ranged),
        @"color": color ?: [NSNull null],
    } mutableCopy];
    if (sStoreHandle) d[@"handle"] = sStoreHandle(marker);
    return d;
}

#pragma mark - Browser clips

// Browser (event) clips are small FFAnchoredSequences whose primaryObject holds the
// clip's markers, in the clip's own time. FCP's marker actions work on them the same
// way as on a project, so every edit goes to the sequence that owns the marker.
static id RMItemForMarker(id sequence, id marker);
static double RMPlayheadForMarker(id marker);
static double RMLayerSecondsPerPixel(CALayer *layer);


// Browser marker layers seen so far (weak), for redrawing and hit testing.
static NSHashTable *sBrowserMarkerLayers;
// Browser marker layer -> the filmstrip chunk (one row of a clip) it sits in.
static NSMapTable *sChunkForLayer;

static Class RMBrowserViewClass(void) { return NSClassFromString(@"FFOrganizerFilmstripView"); }

static BOOL RMIsBrowserMarkerLayer(CALayer *layer) {
    Class cls = NSClassFromString(@"FFMarkerLayer");
    return cls && [layer isKindOfClass:cls];
}

// Timeline marker layers carry the marker as representedObject, browser ones as marker.
static id RMLayerMarker(CALayer *layer) {
    id marker = RMSend(layer, @"representedObject");
    if (!RMIsTimeMarker(marker)) marker = RMSend(layer, @"marker");
    return RMIsTimeMarker(marker) ? marker : nil;
}

// The clip holding the marker: a primary storyline clip, or a browser clip.
static id RMMarkerItem(id marker) {
    id item = RMItemForMarker(RMActiveSequence(), marker);
    if (item) return item;
    id parent = RMSend(marker, @"parentItem");
    return [RMMarkersOnItem(parent) containsObject:marker] ? parent : nil;
}

// The sequence whose actions edit the marker: the open project or the browser clip's own.
static id RMMarkerSequence(id marker) {
    id active = RMActiveSequence();
    if (!marker || RMItemForMarker(active, marker)) return active;
    return RMSend(RMMarkerItem(marker), @"sequence") ?: active;
}

static BOOL RMIsInBrowser(id marker) {
    return marker && RMMarkerSequence(marker) != RMActiveSequence();
}

static NSArray<NSView *> *RMBrowserViews(void) {
    NSMutableArray *out = [NSMutableArray array];
    Class cls = RMBrowserViewClass();
    if (!cls) return out;
    __block __weak void (^weakWalk)(NSView *);
    void (^walk)(NSView *) = ^(NSView *view) {
        if ([view isKindOfClass:cls]) { [out addObject:view]; return; }
        for (NSView *sub in view.subviews) weakWalk(sub);
    };
    weakWalk = walk;
    for (NSWindow *window in NSApp.windows) if (window.isVisible) walk(window.contentView);
    return out;
}

// The browser filmstrip view if it has keyboard focus.
static NSView *RMFocusedBrowserView(void) {
    id responder = NSApp.keyWindow.firstResponder;
    Class cls = RMBrowserViewClass();
    return (cls && [responder isKindOfClass:cls]) ? responder : nil;
}

static NSView *RMBrowserView(void) {
    return RMFocusedBrowserView() ?: RMBrowserViews().firstObject;
}

static CALayer *RMChunkLayer(id chunk) {
    SEL has = NSSelectorFromString(@"hasLayer");
    if (![chunk respondsToSelector:has] || !((BOOL (*)(id, SEL))objc_msgSend)(chunk, has)) return nil;
    return RMSend(chunk, @"layer");
}

static id RMChunkForMarkerLayer(CALayer *layer) {
    CALayer *parent = layer.superlayer;
    if (!parent) return nil;
    id chunk = [sChunkForLayer objectForKey:layer];
    if (chunk && RMChunkLayer(chunk) == parent) return chunk;
    for (NSView *view in RMBrowserViews()) {
        id layout = nil;
        @try { layout = [view valueForKey:@"_layout"]; } @catch (NSException *e) {}
        for (id container in RMSend(layout, @"chunkContainerArray")) {
            for (id c in RMSend(container, @"chunkArray")) {
                if (RMChunkLayer(c) != parent) continue;
                [sChunkForLayer setObject:c forKey:layer];
                return c;
            }
        }
    }
    return nil;
}

// A chunk draws its filmstrip linearly: filmstripRange spans the filmstrip frame.
static double RMChunkSecondsPerPixel(id chunk) {
    CALayer *layer = RMChunkLayer(chunk);
    SEL sel = NSSelectorFromString(@"visibleFilmstripFrameInSpaceOfLayer:");
    RMTimeRange range;
    if (!layer || ![chunk respondsToSelector:sel] || !RMReadRange(chunk, @"filmstripRange", &range)) return 0;
    CGRect frame = ((CGRect (*)(id, SEL, id))objc_msgSend)(chunk, sel, layer);
    return frame.size.width > 0 ? RMSeconds(range.duration) / frame.size.width : 0;
}

static id RMBrowserClipSequence(id rangeObject) {
    return RMSend(RMSend(rangeObject, @"object"), @"sequence");
}

// The browser playhead in the clip time of the browser clip owning sequence.
static BOOL RMBrowserPlayhead(NSView *view, id sequence, double *seconds) {
    RMTime t;
    if (!sequence || RMBrowserClipSequence(RMSend(view, @"persistentPlayheadRangeOfMedia")) != sequence) return NO;
    if (!RMReadTime(view, @"persistentPlayheadTime", &t)) return NO;
    *seconds = RMSeconds(t);
    return YES;
}

// The browser's selected range (a FigTimeRangeAndObject), on sequence's clip if given.
static id RMBrowserSelectionObject(NSView *view, id sequence) {
    NSArray *selection = nil;
    @try { selection = [view valueForKey:@"_selection"]; } @catch (NSException *e) {}
    if (![selection isKindOfClass:[NSArray class]]) return nil;
    for (id ro in selection) {
        RMTimeRange r;
        if (RMReadRange(ro, @"range", &r) && (!sequence || RMBrowserClipSequence(ro) == sequence)) return ro;
    }
    return nil;
}

// Clicking a clip selects all of it; only a range picked inside it counts as in/out.
static BOOL RMIsWholeClipSelection(id ro) {
    RMTimeRange r, clip;
    if (!RMReadRange(ro, @"range", &r) || !RMReadRange(RMSend(ro, @"object"), @"clippedRange", &clip)) return NO;
    return fabs(RMSeconds(r.start) - RMSeconds(clip.start)) < 1e-3 && fabs(RMSeconds(r.duration) - RMSeconds(clip.duration)) < 1e-3;
}

static id RMBrowserHighlightedMarker(NSView *view) {
    id marker = nil;
    @try { marker = [view valueForKey:@"_highlightedMarker"]; } @catch (NSException *e) {}
    return RMIsTimeMarker(marker) ? marker : nil;
}

static BOOL RMLayerIsInView(CALayer *layer, NSView *view) {
    for (CALayer *l = layer; l; l = l.superlayer) if (l == view.layer) return YES;
    return NO;
}

#pragma mark - Drawing

static id RMTimelineView(CALayer *layer) {
    id view = RMSend(layer, @"timelineView");
    if (!view) view = RMSend(sGetTimelineModule ? sGetTimelineModule() : nil, @"timelineView");
    return view;
}

static CALayer *RMSublayerNamed(CALayer *layer, NSString *name) {
    for (CALayer *sub in layer.sublayers) if ([sub.name isEqualToString:name]) return sub;
    return nil;
}

// Seconds per pixel where the marker layer is drawn (timeline or browser filmstrip).
static double RMLayerSecondsPerPixel(CALayer *layer) {
    if (RMIsBrowserMarkerLayer(layer)) return RMChunkSecondsPerPixel(RMChunkForMarkerLayer(layer));
    RMTime tpp;
    return RMReadTime(RMTimelineView(layer), @"timePerPixel", &tpp) ? RMSeconds(tpp) : 0;
}

static void RMUpdateMarkerLayer(CALayer *layer) {
    @try {
        id marker = RMLayerMarker(layer);
        CALayer *bar = RMSublayerNamed(layer, kBarLayerName);
        CALayer *tint = RMSublayerNamed(layer, kTintLayerName);
        if (!marker) { [bar removeFromSuperlayer]; [tint removeFromSuperlayer]; return; }
        if (RMIsBrowserMarkerLayer(layer)) [sBrowserMarkerLayers addObject:layer];

        NSString *colorName = RMParseColorTag(RMSend(marker, @"displayName"), NULL);
        NSColor *color = colorName ? RMPalette()[colorName] : RMDefaultColor(marker);
        double duration = 0;
        BOOL ranged = RMIsRanged(marker, &duration);

        [CATransaction begin];
        [CATransaction setDisableActions:YES];

        // Tint the pin by masking a solid color layer with the pin's own image.
        if (colorName && layer.contents) {
            if (!tint) {
                tint = [CALayer layer];
                tint.name = kTintLayerName;
                tint.mask = [CALayer layer];
                [layer addSublayer:tint];
            }
            tint.frame = layer.bounds;
            tint.backgroundColor = color.CGColor;
            tint.mask.frame = tint.bounds;
            tint.mask.contents = layer.contents;
            tint.mask.contentsGravity = layer.contentsGravity;
            tint.mask.contentsScale = layer.contentsScale;
            tint.mask.contentsRect = layer.contentsRect;
            tint.mask.contentsCenter = layer.contentsCenter;
        } else {
            [tint removeFromSuperlayer];
        }

        // Ranged markers: an always-visible bar from the marker's start to its end.
        double spp = ranged ? RMLayerSecondsPerPixel(layer) : 0;
        if (spp > 0) {
            if (!bar) {
                bar = [CALayer layer];
                bar.name = kBarLayerName;
                bar.zPosition = -1;
                [layer addSublayer:bar];
            }
            // While the end handle is being dragged, the drag owns the width.
            CGFloat width = (layer == sDragLayer) ? sDragWidth : MAX(1.0, duration / spp);
            CGFloat height = MAX(3.0, round(layer.bounds.size.height * 0.4));
            CGFloat x = round(layer.bounds.size.width / 2.0);
            bar.frame = CGRectMake(x, 0, width, height);
            bar.backgroundColor = [color colorWithAlphaComponent:0.55].CGColor;
            bar.borderColor = color.CGColor;
            bar.borderWidth = 1.0;
            bar.cornerRadius = 1.5;

            // Drag handle at the end of the range.
            CALayer *knob = RMSublayerNamed(bar, kKnobLayerName);
            if (!knob) {
                knob = [CALayer layer];
                knob.name = kKnobLayerName;
                knob.cornerRadius = 1.5;
                [bar addSublayer:knob];
            }
            knob.frame = CGRectMake(width - 3, -2, 4, height + 4);
            knob.backgroundColor = color.CGColor;
        } else {
            [bar removeFromSuperlayer];
        }

        [CATransaction commit];
    } @catch (NSException *e) {
        NSLog(@"[RangedMarkers] draw failed: %@", e.reason);
    }
}

static void RMVisitMarkerLayers(CALayer *root, void (^block)(CALayer *)) {
    Class cls = NSClassFromString(@"TLKMarkerLayer");
    if (!root || !cls) return;
    if ([root isKindOfClass:cls]) block(root);
    for (CALayer *sub in [root.sublayers copy]) RMVisitMarkerLayers(sub, block);
}

// Browser marker layers drawn before the plugin loaded; later ones arrive via the hooks.
static void RMDiscoverBrowserMarkerLayers(void) {
    Class cls = NSClassFromString(@"FFMarkerLayer");
    __block __weak void (^weakVisit)(CALayer *);
    void (^visit)(CALayer *) = ^(CALayer *layer) {
        if ([layer isKindOfClass:cls]) { RMUpdateMarkerLayer(layer); return; }
        for (CALayer *sub in [layer.sublayers copy]) weakVisit(sub);
    };
    weakVisit = visit;
    if (cls) for (NSView *view in RMBrowserViews()) visit(view.layer);
}

static void RMRefreshAll(void) {
    id view = RMSend(sGetTimelineModule ? sGetTimelineModule() : nil, @"timelineView");
    if ([view isKindOfClass:[NSView class]]) RMVisitMarkerLayers([(NSView *)view layer], ^(CALayer *l) { RMUpdateMarkerLayer(l); });
    for (CALayer *l in sBrowserMarkerLayers.allObjects) if (l.superlayer) RMUpdateMarkerLayer(l);
}

#pragma mark - Swizzling (safe across hot reloads)

// The true original IMP is stashed on the class, so reloading the plugin
// re-wraps FCP's implementation instead of the previous plugin build's.
static IMP RMHook(Class cls, SEL sel, IMP replacement) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    class_addMethod(cls, sel, method_getImplementation(m), method_getTypeEncoding(m));
    m = class_getInstanceMethod(cls, sel);
    NSString *keyName = [NSString stringWithFormat:@"skRangedMarkers.orig.%s.%s", class_getName(cls), sel_getName(sel)];
    const void *key = sel_registerName(keyName.UTF8String);
    NSValue *orig = objc_getAssociatedObject(cls, key);
    if (!orig) {
        orig = [NSValue valueWithPointer:(const void *)method_getImplementation(m)];
        objc_setAssociatedObject(cls, key, orig, OBJC_ASSOCIATION_RETAIN);
    }
    method_setImplementation(m, replacement);
    return (IMP)orig.pointerValue;
}

static void (*sOrigLayout)(id, SEL);
static void (*sOrigUpdateAppearance)(id, SEL);
static void (*sOrigSetPosition)(id, SEL, CGPoint);

static void RMLayout(id self, SEL _cmd) { sOrigLayout(self, _cmd); RMUpdateMarkerLayer(self); }
static void RMUpdateAppearance(id self, SEL _cmd) { sOrigUpdateAppearance(self, _cmd); RMUpdateMarkerLayer(self); }
// Zooming moves marker layers without resizing them, so refresh on position changes too.
static void RMSetPosition(id self, SEL _cmd, CGPoint p) { sOrigSetPosition(self, _cmd, p); RMUpdateMarkerLayer(self); }

static void RMInstallHooks(void) {
    Class cls = NSClassFromString(@"TLKMarkerLayer");
    if (!cls) return;
    sOrigLayout = (void *)RMHook(cls, @selector(layoutSublayers), (IMP)RMLayout);
    sOrigUpdateAppearance = (void *)RMHook(cls, NSSelectorFromString(@"updateAppearance"), (IMP)RMUpdateAppearance);
    sOrigSetPosition = (void *)RMHook(cls, @selector(setPosition:), (IMP)RMSetPosition);
}

// Browser filmstrip markers (FFMarkerLayer, one per marker in each filmstrip chunk).
static void (*sOrigBrowserLayout)(id, SEL);
static void (*sOrigBrowserSetPosition)(id, SEL, CGPoint);
static void (*sOrigBrowserUpdateImage)(id, SEL);
static void (*sOrigChunkUpdateMarkers)(id, SEL, RMTimeRange);

static void RMBrowserLayout(id self, SEL _cmd) { sOrigBrowserLayout(self, _cmd); RMUpdateMarkerLayer(self); }
static void RMBrowserSetPosition(id self, SEL _cmd, CGPoint p) { sOrigBrowserSetPosition(self, _cmd, p); RMUpdateMarkerLayer(self); }
static void RMBrowserUpdateImage(id self, SEL _cmd) { sOrigBrowserUpdateImage(self, _cmd); RMUpdateMarkerLayer(self); }

static void RMChunkUpdateMarkers(id self, SEL _cmd, RMTimeRange range) {
    sOrigChunkUpdateMarkers(self, _cmd, range);
    @try {
        for (CALayer *l in RMSend(self, @"markerLayers")) {
            if (![l isKindOfClass:[CALayer class]]) continue;
            [sChunkForLayer setObject:self forKey:l];
            RMUpdateMarkerLayer(l);
        }
    } @catch (NSException *e) {
        NSLog(@"[RangedMarkers] browser markers failed: %@", e.reason);
    }
}

static void RMInstallBrowserHooks(void) {
    sBrowserMarkerLayers = [NSHashTable weakObjectsHashTable];
    sChunkForLayer = [NSMapTable weakToWeakObjectsMapTable];
    Class layer = NSClassFromString(@"FFMarkerLayer");
    if (layer) {
        sOrigBrowserLayout = (void *)RMHook(layer, @selector(layoutSublayers), (IMP)RMBrowserLayout);
        sOrigBrowserSetPosition = (void *)RMHook(layer, @selector(setPosition:), (IMP)RMBrowserSetPosition);
        sOrigBrowserUpdateImage = (void *)RMHook(layer, NSSelectorFromString(@"_updateImageFromMarkerProperties"), (IMP)RMBrowserUpdateImage);
    }
    Class chunk = NSClassFromString(@"FFOrganizerFilmstripChunk");
    if (chunk) sOrigChunkUpdateMarkers = (void *)RMHook(chunk, NSSelectorFromString(@"updateMarkersInRange:"), (IMP)RMChunkUpdateMarkers);
}

#pragma mark - RPC methods

static NSDictionary *RMOnMain(NSDictionary *(^block)(void)) {
    __block NSDictionary *result = nil;
    sOnMain(^{
        @try { result = block(); }
        @catch (NSException *e) { result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]}; }
    });
    return result ?: @{@"error": @"no result"};
}

static id RMSelectedMarker(void) {
    NSView *browser = RMFocusedBrowserView();
    if (browser) return RMBrowserHighlightedMarker(browser);
    id selected = RMSend(sGetTimelineModule ? sGetTimelineModule() : nil, @"selectedItems");
    if ([selected respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) {
        for (id obj in selected) if (RMIsTimeMarker(obj)) return obj;
    }
    return nil;
}

// Undoable rename. The action lives on FFAnchoredSequence, not the timeline module.
static NSString *RMDefaultNewMarkerColor(void);

static BOOL RMRename(id marker, NSString *name, NSError **err) {
    id sequence = RMMarkerSequence(marker);
    SEL sel = NSSelectorFromString(@"actionChangeMarkerDisplayName:marker:error:");
    if (![sequence respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(sequence, sel, name, marker, err);
}

// Adds a marker over [localStart, localStart + duration) in item's own time with
// sequence's undoable action. Returns the new marker, or nil with *error set.
static id RMAddMarkerToItem(id sequence, id item, double localStart, double duration, NSDictionary *params, NSString **error) {
    NSString *name = params[@"name"];
    NSString *color = [params[@"color"] lowercaseString];
    if (!params[@"color"] && [params[@"kind"] ?: @"standard" isEqualToString:@"standard"]) color = RMDefaultNewMarkerColor();
    if (color.length && ![color isEqualToString:@"none"] && !RMPalette()[color]) {
        *error = [NSString stringWithFormat:@"Unknown color '%@'. Use one of: %@", color,
                  [[RMPalette().allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]];
        return nil;
    }
    NSString *kind = params[@"kind"] ?: @"standard";
    double frame = RMFrameSeconds(sequence);
    int32_t ts = 24000;
    RMTime fd;
    if (RMReadTime(sequence, @"frameDuration", &fd)) ts = fd.timescale;
    // FCP won't let a marker run past its clip's source media; the rest goes in the tag.
    double fcpDuration = duration;
    RMTimeRange media;
    if (RMReadRange(item, @"unclippedRange", &media)) {
        double available = RMSeconds(media.start) + RMSeconds(media.duration) - localStart;
        fcpDuration = MAX(frame, MIN(duration, floor(available / frame) * frame));
    }
    double tagDuration = duration > fcpDuration + frame / 2 ? duration : 0;
    RMTimeRange range = { RMMakeTime(localStart, ts), RMMakeTime(fcpDuration, ts) };

    NSSet *before = [NSSet setWithArray:RMMarkersOnItem(item)];
    SEL addSel = NSSelectorFromString(@"actionAddMarkerToAnchoredObject:isToDo:isChapter:withRange:error:");
    if (![sequence respondsToSelector:addSel]) { *error = @"FCP can't add markers here"; return nil; }
    NSError *err = nil;
    BOOL ok = ((BOOL (*)(id, SEL, id, BOOL, BOOL, RMTimeRange, NSError **))objc_msgSend)(
        sequence, addSel, item, [kind isEqualToString:@"todo"], [kind isEqualToString:@"chapter"], range, &err);
    if (!ok) { *error = err.localizedDescription ?: @"FCP refused to add the marker"; return nil; }

    id marker = nil;
    for (id m in RMMarkersOnItem(item)) if (![before containsObject:m]) marker = m;
    if (marker && (name.length || color.length || tagDuration > 0)) {
        NSString *base = name.length ? name : (RMSend(marker, @"displayName") ?: @"Marker");
        RMRename(marker, RMFormatName(base, color, tagDuration), NULL);
    }
    RMRefreshAll();
    if (!marker) *error = nil;
    return marker;
}

// rangedMarkers.add {start, end | duration, name?, color?, kind?}
// Without start/end it uses the timeline's in/out range.
static NSDictionary *RMAdd(NSDictionary *params) {
    return RMOnMain(^NSDictionary *{
        id sequence = RMActiveSequence();
        if (!sequence) return @{@"error": @"No project open"};

        double start, duration;
        if (params[@"start"]) {
            start = [params[@"start"] doubleValue];
            duration = params[@"end"] ? [params[@"end"] doubleValue] - start : [params[@"duration"] doubleValue];
        } else {
            id view = RMSend(sGetTimelineModule(), @"timelineView");
            SEL sel = NSSelectorFromString(@"inOutTimeRange");
            if (![view respondsToSelector:sel]) return @{@"error": @"Pass start and end/duration (no in/out range available)"};
            RMTimeRange r = ((RMTimeRange (*)(id, SEL))objc_msgSend)(view, sel);
            start = RMSeconds(r.start);
            duration = RMSeconds(r.duration);
        }
        double frame = RMFrameSeconds(sequence);
        if (duration < frame * 2) return @{@"error": @"Range must be at least 2 frames. Pass start and end/duration, or set an in/out range."};

        id item = RMSpineItemAtTime(sequence, start);
        if (!item) return @{@"error": [NSString stringWithFormat:@"No clip at %.3fs on the primary storyline", start]};

        NSString *error = nil;
        id marker = RMAddMarkerToItem(sequence, item, start + RMLocalOffset(sequence, item), duration, params, &error);
        if (error) return @{@"error": error};
        return marker ? @{@"status": @"ok", @"marker": RMDescribeMarker(sequence, item, marker)}
                      : @{@"status": @"ok", @"note": @"Marker added but could not be read back"};
    });
}

// rangedMarkers.setColor {color, marker?} — selected marker if no handle is given.
static NSDictionary *RMSetColor(NSDictionary *params) {
    return RMOnMain(^NSDictionary *{
        NSString *color = [params[@"color"] lowercaseString];
        if (!color.length) return @{@"error": @"color is required (or \"none\" to clear)"};
        if (![color isEqualToString:@"none"] && !RMPalette()[color]) return @{@"error": [NSString stringWithFormat:@"Unknown color '%@'", color]};
        id marker = params[@"marker"] && sResolveHandle ? sResolveHandle(params[@"marker"]) : RMSelectedMarker();
        if (!RMIsTimeMarker(marker)) return @{@"error": @"Select a marker in the timeline or pass a marker handle"};
        NSString *newName = RMNameWithColor(RMSend(marker, @"displayName"), color);
        NSError *err = nil;
        if (!RMRename(marker, newName, &err)) return @{@"error": err.localizedDescription ?: @"Rename failed"};
        RMRefreshAll();
        return @{@"status": @"ok", @"name": newName};
    });
}

// rangedMarkers.list — every marker on the primary storyline with sequence times.
static NSDictionary *RMList(NSDictionary *params) {
    return RMOnMain(^NSDictionary *{
        id sequence = RMActiveSequence();
        if (!sequence) return @{@"error": @"No project open"};
        NSMutableArray *out = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (id item in RMSpineItems(sequence)) {
            RMTimeRange r;
            if (!RMItemRange(sequence, item, &r)) continue;
            double s = RMSeconds(r.start), e = s + RMSeconds(r.duration);
            for (id m in RMMarkersOnItem(item)) {
                NSDictionary *d = RMDescribeMarker(sequence, item, m);
                double t = [d[@"start"] doubleValue];
                // Bladed clips share marker lists; only report markers inside this piece.
                if (t < s - 0.001 || t >= e) continue;
                NSValue *key = [NSValue valueWithNonretainedObject:m];
                if ([seen containsObject:key]) continue;
                [seen addObject:key];
                [out addObject:d];
            }
        }
        [out sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"start" ascending:YES]]];
        return @{@"status": @"ok", @"markers": out, @"colors": [RMPalette().allKeys sortedArrayUsingSelector:@selector(compare:)]};
    });
}

// rangedMarkers.debugMarkers — each marker's clip, used range and available media (development).
static NSDictionary *RMDebugMarkers(NSDictionary *params) {
    return RMOnMain(^NSDictionary *{
        id sequence = RMActiveSequence();
        NSMutableArray *out = [NSMutableArray array];
        for (id item in RMSpineItems(sequence)) {
            NSArray *markers = RMMarkersOnItem(item);
            if (!markers.count) continue;
            RMTimeRange seqRange = {0}, clipped = {0}, unclipped = {0};
            RMItemRange(sequence, item, &seqRange);
            RMReadRange(item, @"clippedRange", &clipped);
            RMReadRange(item, @"unclippedRange", &unclipped);
            NSMutableArray *names = [NSMutableArray array];
            for (id m in markers) {
                RMTime a = {0};
                RMReadTime(m, @"targetAnchorTime", &a);
                [names addObject:@{@"name": RMSend(m, @"displayName") ?: @"", @"localStart": @(RMSeconds(a)),
                                   @"duration": @(RMFCPDuration(m)), @"id": [NSString stringWithFormat:@"%p", m]}];
            }
            [out addObject:@{
                @"clip": RMSend(item, @"displayName") ?: NSStringFromClass([item class]),
                @"class": NSStringFromClass([item class]),
                @"sequenceRange": RMRangeDict(seqRange),
                @"clippedRange": RMRangeDict(clipped),
                @"unclippedRange": RMRangeDict(unclipped),
                @"markers": names,
            }];
        }
        return @{@"items": out};
    });
}

static __weak id sLastMarkerEditor;
static void RMAddDurationRow(id editor);
static void RMActDurationCommitted(id self, SEL _cmd, NSTextField *field);
static void RMActEditorColor(id self, SEL _cmd, NSButton *sender);

static void RMDumpView(NSView *view, int depth, NSMutableArray *out) {
    if (!view || depth > 6) return;
    NSMutableDictionary *d = [@{
        @"class": NSStringFromClass([view class]),
        @"frame": NSStringFromRect(view.frame),
        @"depth": @(depth),
        @"hidden": @(view.hidden),
    } mutableCopy];
    if ([view isKindOfClass:[NSTextField class]]) d[@"string"] = [(NSTextField *)view stringValue] ?: @"";
    if ([view isKindOfClass:[NSButton class]]) d[@"title"] = [(NSButton *)view title] ?: @"";
    [out addObject:d];
    for (NSView *sub in view.subviews) RMDumpView(sub, depth + 1, out);
}

// rangedMarkers.debugEditor — view tree of the open marker editor (development).
static NSDictionary *RMDebugEditor(NSDictionary *params) {
    return RMOnMain(^NSDictionary *{
        id editor = sLastMarkerEditor;
        NSView *view = RMSend(editor, @"view");
        if (![view isKindOfClass:[NSView class]]) return @{@"error": @"No marker editor has been opened"};
        NSMutableArray *out = [NSMutableArray array];
        RMDumpView(view, 0, out);
        if ([params[@"addRow"] boolValue]) RMAddDurationRow(editor);
        NSView *tc = [editor valueForKey:@"timecodeField"];
        return @{@"editorClass": NSStringFromClass([editor class]), @"windowClass": NSStringFromClass([view.window class]) ?: @"",
                 @"timecodeField": tc ? NSStringFromRect(tc.frame) : @"", @"views": out};
    });
}

static NSDictionary *RMRefresh(NSDictionary *params) {
    return RMOnMain(^NSDictionary *{ RMDiscoverBrowserMarkerLayers(); RMRefreshAll(); return @{@"status": @"ok"}; });
}

// rangedMarkers.debugLayers — geometry of live marker layers, for development.
static NSDictionary *RMDebugLayers(NSDictionary *params) {
    return RMOnMain(^NSDictionary *{
        id view = RMSend(sGetTimelineModule ? sGetTimelineModule() : nil, @"timelineView");
        NSMutableArray *out = [NSMutableArray array];
        RMTime tpp = {0};
        RMReadTime(view, @"timePerPixel", &tpp);
        if ([view isKindOfClass:[NSView class]]) {
            RMVisitMarkerLayers([(NSView *)view layer], ^(CALayer *l) {
                id m = RMSend(l, @"representedObject");
                CGRect inView = [l convertRect:l.bounds toLayer:[(NSView *)view layer]];
                NSMutableArray *chain = [NSMutableArray array];
                for (CALayer *p = l.superlayer; p && chain.count < 4; p = p.superlayer)
                    [chain addObject:[NSString stringWithFormat:@"%@%@", NSStringFromClass([p class]), p.masksToBounds ? @"(clips)" : @""]];
                [out addObject:@{
                    @"class": NSStringFromClass([l class]),
                    @"marker": m ? (RMSend(m, @"displayName") ?: NSStringFromClass([m class])) : [NSNull null],
                    @"frameInView": NSStringFromRect(NSRectFromCGRect(inView)),
                    @"bounds": NSStringFromRect(NSRectFromCGRect(l.bounds)),
                    @"anchorPoint": NSStringFromPoint(NSPointFromCGPoint(l.anchorPoint)),
                    @"superlayers": chain,
                    @"hasContents": @(l.contents != nil),
                }];
            });
        }
        return @{@"timePerPixel": @(RMSeconds(tpp)), @"layers": out};
    });
}

// rangedMarkers.debugBrowser — browser marker layers, playhead and selection (development).
static NSDictionary *RMDebugBrowser(NSDictionary *params) {
    return RMOnMain(^NSDictionary *{
        NSMutableArray *layers = [NSMutableArray array];
        for (CALayer *l in sBrowserMarkerLayers.allObjects) {
            id m = RMLayerMarker(l);
            RMTime a = {0};
            RMReadTime(m, @"targetAnchorTime", &a);
            [layers addObject:@{@"marker": RMSend(m, @"displayName") ?: @"", @"localStart": @(RMSeconds(a)),
                                @"duration": @(RMFCPDuration(m)), @"frame": NSStringFromRect(NSRectFromCGRect(l.frame)),
                                @"attached": @(l.superlayer != nil), @"hasChunk": @(RMChunkForMarkerLayer(l) != nil),
                                @"secondsPerPixel": @(RMLayerSecondsPerPixel(l)), @"inBrowser": @(RMIsInBrowser(m)),
                                @"playhead": @(RMPlayheadForMarker(m)), @"hasContents": @(l.contents != nil)}];
        }
        NSView *view = RMBrowserView();
        id highlighted = nil;
        @try { highlighted = [view valueForKey:@"_highlightedMarker"]; } @catch (NSException *e) {}
        RMTime t = {0};
        RMReadTime(view, @"persistentPlayheadTime", &t);
        id ro = RMSend(view, @"persistentPlayheadRangeOfMedia");
        id sel = RMBrowserSelectionObject(view, nil);
        RMTimeRange sr = {0};
        RMReadRange(sel, @"range", &sr);
        return @{@"layers": layers, @"focused": @(RMFocusedBrowserView() != nil), @"hasView": @(view != nil),
                 @"highlighted": RMSend(highlighted, @"displayName") ?: [NSNull null],
                 @"playheadTime": @(RMSeconds(t)), @"playheadClip": RMSend(RMSend(ro, @"object"), @"displayName") ?: [NSNull null],
                 @"selection": sel ? RMRangeDict(sr) : [NSNull null], @"selectionIsWholeClip": @(RMIsWholeClipSelection(sel))};
    });
}

#pragma mark - Range edits shared by the menus and dragging

static double RMPlayheadSeconds(void) {
    RMTime t;
    return RMReadTime(sGetTimelineModule ? sGetTimelineModule() : nil, @"playheadTime", &t) ? RMSeconds(t) : -1;
}

// The timeline's in/out range in sequence seconds, if one is set.
static BOOL RMInOutRange(double *start, double *duration) {
    id tm = sGetTimelineModule ? sGetTimelineModule() : nil;
    SEL hasSel = NSSelectorFromString(@"timelineHasSelectedRange");
    if (![tm respondsToSelector:hasSel] || !((BOOL (*)(id, SEL))objc_msgSend)(tm, hasSel)) return NO;
    id ranges = RMSend(tm, @"selectedRangesOfMedia");
    SEL sel = NSSelectorFromString(@"rangeOfMediaForSelectedRangesOfMedia:useClippedRange:inRootItemTime:");
    if (!ranges || ![tm respondsToSelector:sel]) return NO;
    RMTimeRange r = ((RMTimeRange (*)(id, SEL, id, BOOL, BOOL))objc_msgSend)(tm, sel, ranges, YES, YES);
    if (r.duration.timescale <= 0 || RMSeconds(r.duration) <= 0) return NO;
    *start = RMSeconds(r.start);
    *duration = RMSeconds(r.duration);
    return YES;
}

static id RMItemForMarker(id sequence, id marker) {
    for (id item in RMSpineItems(sequence)) {
        if ([RMMarkersOnItem(item) containsObject:marker]) return item;
    }
    return nil;
}

static double RMMarkerSequenceStart(id sequence, id marker) {
    id item = RMItemForMarker(sequence, marker);
    RMTime anchor;
    if (!item || !RMReadTime(marker, @"targetAnchorTime", &anchor)) return -1;
    return RMSeconds(anchor) - RMLocalOffset(sequence, item);
}

// The playhead in the marker's clip time: the timeline playhead for project markers,
// the browser playhead for markers on browser clips. -1 if it isn't on that clip.
static double RMPlayheadForMarker(id marker) {
    id sequence = RMMarkerSequence(marker);
    if (sequence == RMActiveSequence()) {
        id item = RMItemForMarker(sequence, marker);
        double playhead = RMPlayheadSeconds();
        return (item && playhead >= 0) ? playhead + RMLocalOffset(sequence, item) : -1;
    }
    double seconds;
    return RMBrowserPlayhead(RMBrowserView(), sequence, &seconds) ? seconds : -1;
}

// The in/out range (timeline) or selected range (browser) in the marker's clip time.
static BOOL RMInOutForMarker(id marker, double *localStart, double *duration) {
    id sequence = RMMarkerSequence(marker);
    if (sequence == RMActiveSequence()) {
        id item = RMItemForMarker(sequence, marker);
        if (!item || !RMInOutRange(localStart, duration)) return NO;
        *localStart += RMLocalOffset(sequence, item);
        return YES;
    }
    RMTimeRange r;
    if (!RMReadRange(RMBrowserSelectionObject(RMBrowserView(), sequence), @"range", &r) || RMSeconds(r.duration) <= 0) return NO;
    *localStart = RMSeconds(r.start);
    *duration = RMSeconds(r.duration);
    return YES;
}

// Seconds of source media available after localStart on the marker's clip. FCP won't
// let a marker run past its clip's source media, however long the timeline range is.
static double RMAvailableMedia(id sequence, id item, RMTime localStart) {
    RMTimeRange media;
    if (!item || !RMReadRange(item, @"unclippedRange", &media)) return INFINITY;
    return RMSeconds(media.start) + RMSeconds(media.duration) - RMSeconds(localStart);
}

// Undoable range change via -[FFAnchoredSequence actionMoveMarker:toRange:error:].
// localStart is in the marker's clip-local time; duration is snapped to whole frames.
// FCP gets as much of the range as its clip's media allows; anything longer is
// kept in the name tag ("[Red 12.5s] ...") so the full range still draws and survives.
static BOOL RMMoveMarker(id marker, RMTime localStart, double seconds) {
    id sequence = RMMarkerSequence(marker);
    SEL sel = NSSelectorFromString(@"actionMoveMarker:toRange:error:");
    if (!sequence || ![sequence respondsToSelector:sel]) return NO;
    RMTime fd;
    if (!RMReadTime(sequence, @"frameDuration", &fd)) fd = (RMTime){1001, 24000, 1, 0};
    double frame = RMSeconds(fd);
    int64_t frames = MAX(1, llround(seconds / frame));
    double available = RMAvailableMedia(sequence, RMMarkerItem(marker), localStart);
    int64_t fcpFrames = MAX(1, MIN(frames, (int64_t)floor(available / frame)));

    RMTime anchor = {0};
    RMReadTime(marker, @"targetAnchorTime", &anchor);
    BOOL moving = fabs(RMSeconds(anchor) - RMSeconds(localStart)) > 1e-6;

    RMTimeRange range = { localStart, { fd.value * fcpFrames, fd.timescale, 1, 0 } };
    NSError *err = nil;
    BOOL ok = ((BOOL (*)(id, SEL, id, RMTimeRange, NSError **))objc_msgSend)(sequence, sel, marker, range, &err);
    if (!ok) {
        NSLog(@"[RangedMarkers] move failed: %@", err.localizedDescription);
        if (moving) { RMRefreshAll(); return NO; }
    }

    // Keep the full length in the tag only when FCP couldn't store it.
    double tagDuration = (!ok || fcpFrames < frames) && frames > 1 ? frames * frame : 0;
    NSString *title = nil, *color = nil;
    NSString *name = RMSend(marker, @"displayName");
    double current = RMParseTag(name, &title, &color);
    if (fabs(current - tagDuration) > frame / 2) RMRename(marker, RMFormatName(title, color, tagDuration), NULL);
    RMRefreshAll();
    return YES;
}

static BOOL RMSetMarkerDuration(id marker, double seconds) {
    RMTime anchor;
    return RMReadTime(marker, @"targetAnchorTime", &anchor) && RMMoveMarker(marker, anchor, seconds);
}

#pragma mark - Keeping ranges when FCP moves markers

// FCP's own marker moves (dragging a pin, Nudge Marker Left/Right) rebuild the
// marker one frame long. Snapshot every ranged marker before, restore after.
static NSArray *RMSnapshotRanged(void) {
    id sequence = RMActiveSequence();
    NSMutableArray *out = [NSMutableArray array];
    NSHashTable *seen = [NSHashTable weakObjectsHashTable];
    for (id item in RMSpineItems(sequence)) {
        for (id m in RMMarkersOnItem(item)) {
            double duration = 0;
            if ([seen containsObject:m] || !RMIsRanged(m, &duration)) continue;
            [seen addObject:m];
            [out addObject:@{@"marker": m, @"name": RMSend(m, @"displayName") ?: @"", @"duration": @(duration)}];
        }
    }
    return out;
}

static void RMRestoreRanged(NSArray *snapshot) {
    if (!snapshot.count) return;
    id sequence = RMActiveSequence();
    double frame = RMFrameSeconds(sequence);
    NSHashTable *current = [NSHashTable weakObjectsHashTable];
    for (id item in RMSpineItems(sequence)) for (id m in RMMarkersOnItem(item)) [current addObject:m];
    NSHashTable *before = [NSHashTable weakObjectsHashTable];
    for (NSDictionary *entry in snapshot) [before addObject:entry[@"marker"]];

    for (NSDictionary *entry in snapshot) {
        double wanted = [entry[@"duration"] doubleValue];
        id marker = entry[@"marker"];
        if (![current containsObject:marker]) {
            // Moved to another clip: FCP made a new marker object with the same name.
            marker = nil;
            for (id m in current.allObjects) {
                if (![before containsObject:m] && [RMSend(m, @"displayName") isEqualToString:entry[@"name"]] && !RMIsRanged(m, NULL)) {
                    marker = m;
                    break;
                }
            }
        }
        double now = 0;
        RMIsRanged(marker, &now);
        if (marker && fabs(now - wanted) > frame / 2) RMSetMarkerDuration(marker, wanted);
    }
}

static BOOL (*sOrigTimelineMoveMarker)(id, SEL, id, id, id, RMTime);
static void (*sOrigNudgeLeft)(id, SEL, id);
static void (*sOrigNudgeRight)(id, SEL, id);

static void RMRestoreSoon(NSArray *snapshot) {
    RMRestoreRanged(snapshot);
    // Some moves finish on a later runloop pass; check once more.
    dispatch_async(dispatch_get_main_queue(), ^{ RMRestoreRanged(snapshot); });
}

static BOOL RMTimelineMoveMarker(id self, SEL _cmd, id view, id marker, id toItem, RMTime time) {
    NSArray *snapshot = RMSnapshotRanged();
    BOOL result = sOrigTimelineMoveMarker(self, _cmd, view, marker, toItem, time);
    @try { RMRestoreSoon(snapshot); } @catch (NSException *e) { NSLog(@"[RangedMarkers] restore failed: %@", e.reason); }
    return result;
}

static void RMNudgeLeft(id self, SEL _cmd, id sender) {
    NSArray *snapshot = RMSnapshotRanged();
    sOrigNudgeLeft(self, _cmd, sender);
    @try { RMRestoreSoon(snapshot); } @catch (NSException *e) {}
}

static void RMNudgeRight(id self, SEL _cmd, id sender) {
    NSArray *snapshot = RMSnapshotRanged();
    sOrigNudgeRight(self, _cmd, sender);
    @try { RMRestoreSoon(snapshot); } @catch (NSException *e) {}
}

// The browser moves markers (dragging a pin, nudging) through its module with a
// one-frame range object. Keep the marker's length instead, as far as its media allows.
static BOOL (*sOrigBrowserMoveMarker)(id, SEL, id, id, NSError **);

static BOOL RMBrowserMoveMarker(id self, SEL _cmd, id marker, id rangeObject, NSError **err) {
    double wanted = 0;
    @try {
        RMTimeRange r;
        double frame = RMIsTimeMarker(marker) ? RMFrameSeconds(marker) : 0;
        SEL copySel = NSSelectorFromString(@"copyWithRange:");
        if (frame > 0 && RMIsRanged(marker, &wanted) && RMReadRange(rangeObject, @"range", &r) &&
            RMSeconds(r.duration) < frame * 1.5 && [rangeObject respondsToSelector:copySel]) {
            double available = RMAvailableMedia(RMMarkerSequence(marker), RMMarkerItem(marker), r.start);
            int64_t frames = MAX(1, MIN(llround(RMFCPDuration(marker) / frame), (int64_t)floor(available / frame)));
            r.duration = RMMakeTime(frames * frame, r.start.timescale);
            typedef id (*RMCopyFn)(id, SEL, RMTimeRange) __attribute__((ns_returns_retained));
            rangeObject = ((RMCopyFn)objc_msgSend)(rangeObject, copySel, r);
        } else {
            wanted = 0;
        }
    } @catch (NSException *e) {
        wanted = 0;
    }
    BOOL ok = sOrigBrowserMoveMarker(self, _cmd, marker, rangeObject, err);
    if (ok && wanted > 0) {
        // Clamped by the media at the new spot: RMSetMarkerDuration keeps the rest in the tag.
        double now = 0;
        RMIsRanged(marker, &now);
        if (fabs(now - wanted) > RMFrameSeconds(marker) / 2) RMSetMarkerDuration(marker, wanted);
    }
    return ok;
}

static void RMInstallMoveHooks(void) {
    Class organizer = NSClassFromString(@"FFOrganizerFilmstripModule");
    if (organizer) sOrigBrowserMoveMarker = (void *)RMHook(organizer, NSSelectorFromString(@"actionMoveMarker:toRange:error:"), (IMP)RMBrowserMoveMarker);
    Class tm = NSClassFromString(@"FFAnchoredTimelineModule");
    if (!tm) return;
    sOrigTimelineMoveMarker = (void *)RMHook(tm, NSSelectorFromString(@"timelineView:moveMarker:toItem:atTime:"), (IMP)RMTimelineMoveMarker);
    sOrigNudgeLeft = (void *)RMHook(tm, NSSelectorFromString(@"nudgeMarkerLeft:"), (IMP)RMNudgeLeft);
    sOrigNudgeRight = (void *)RMHook(tm, NSSelectorFromString(@"nudgeMarkerRight:"), (IMP)RMNudgeRight);
}

#pragma mark - Deleting every copy of a ranged marker

// Blading a clip gives each piece its own copy of every marker on it. A one-frame
// marker shows on one piece only, but FCP shows a ranged marker on every piece its
// range overlaps, so deleting one copy (Delete key or dragging it off the clip)
// leaves the others drawn on top of each other. Delete them all as one undo step.
static BOOL (*sOrigRemoveMarker)(id, SEL, id, NSError **);
static BOOL sRemovingCopies;

static NSArray *RMMarkerCopies(id sequence, id marker) {
    id item = RMItemForMarker(sequence, marker);
    NSString *name = RMSend(marker, @"displayName") ?: @"";
    NSString *clip = RMSend(item, @"displayName") ?: @"";
    RMTime anchor;
    if (!item || !RMReadTime(marker, @"targetAnchorTime", &anchor)) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id other in RMSpineItems(sequence)) {
        if (other == item || [other class] != [item class] || ![(RMSend(other, @"displayName") ?: @"") isEqualToString:clip]) continue;
        for (id m in RMMarkersOnItem(other)) {
            RMTime a;
            if (m != marker && [(RMSend(m, @"displayName") ?: @"") isEqualToString:name] &&
                RMReadTime(m, @"targetAnchorTime", &a) && fabs(RMSeconds(a) - RMSeconds(anchor)) < 1e-6) [out addObject:m];
        }
    }
    return out;
}

static NSUndoManager *RMUndoManager(void) {
    id library = RMSend(RMSend(NSApp, @"delegate"), @"_targetLibrary");
    id um = RMSend(RMSend(library, @"libraryDocument"), @"undoManager");
    return [um isKindOfClass:[NSUndoManager class]] ? um : nil;
}

static BOOL RMRemoveMarker(id self, SEL _cmd, id marker, NSError **err) {
    NSArray *copies = nil;
    @try {
        if (!sRemovingCopies && RMIsTimeMarker(marker) && RMIsRanged(marker, NULL)) copies = RMMarkerCopies(self, marker);
    } @catch (NSException *e) { NSLog(@"[RangedMarkers] finding marker copies failed: %@", e.reason); }
    if (!copies.count) return sOrigRemoveMarker(self, _cmd, marker, err);

    NSUndoManager *um = RMUndoManager();
    [um beginUndoGrouping];
    sRemovingCopies = YES;
    BOOL ok = sOrigRemoveMarker(self, _cmd, marker, err);
    if (ok) for (id m in copies) sOrigRemoveMarker(self, _cmd, m, NULL);
    sRemovingCopies = NO;
    [um endUndoGrouping];
    RMRefreshAll();
    return ok;
}

static void RMInstallDeleteHook(void) {
    Class seq = NSClassFromString(@"FFAnchoredSequence");
    if (seq) sOrigRemoveMarker = (void *)RMHook(seq, NSSelectorFromString(@"actionRemoveMarker:error:"), (IMP)RMRemoveMarker);
}

#pragma mark - Adding markers inside a range

// Pressing M where a marker already is selects that marker instead of adding one.
// FCP asks +[FFAnchoredObject timeMarkersForItem:inTimeRange:] for markers in the
// playhead's frame, which includes a ranged marker anywhere in its range. While
// adding, leave ranged markers out so new markers can go inside (or on) a range.
static id (*sOrigTimeMarkersForItem)(id, SEL, id, RMTimeRange);
static void (*sOrigAddMarker)(id, SEL, BOOL, BOOL, BOOL);
static BOOL sAddingMarker;

static id RMTimeMarkersForItem(id self, SEL _cmd, id item, RMTimeRange range) {
    id markers = sOrigTimeMarkersForItem(self, _cmd, item, range);
    // Only the "is there a marker at the playhead" check asks about a frame-sized
    // range. Wider queries (e.g. the timeline laying out a clip's markers while the
    // add runs) must see every marker, or FCP drops the ranged markers' layers.
    if (!sAddingMarker || RMSeconds(range.duration) > 0.25 || ![markers isKindOfClass:[NSSet class]]) return markers;
    @try {
        NSMutableSet *out = [NSMutableSet set];
        for (id m in markers) if (!RMIsTimeMarker(m) || !RMIsRanged(m, NULL)) [out addObject:m];
        return out;
    } @catch (NSException *e) {
        NSLog(@"[RangedMarkers] filtering markers at playhead failed: %@", e.reason);
        return markers;
    }
}

static void RMAddMarker(id self, SEL _cmd, BOOL alwaysEdit, BOOL todo, BOOL chapter) {
    sAddingMarker = YES;
    @try { sOrigAddMarker(self, _cmd, alwaysEdit, todo, chapter); }
    @finally { sAddingMarker = NO; }
}

// The browser's Add Marker takes an extra isMoment flag.
static void (*sOrigBrowserAddMarker)(id, SEL, BOOL, BOOL, BOOL, BOOL);

static void RMBrowserAddMarker(id self, SEL _cmd, BOOL alwaysEdit, BOOL todo, BOOL chapter, BOOL moment) {
    sAddingMarker = YES;
    @try { sOrigBrowserAddMarker(self, _cmd, alwaysEdit, todo, chapter, moment); }
    @finally { sAddingMarker = NO; }
}

// New standard markers added with Add Marker get the color last picked in the
// marker editor. To-do and chapter markers keep FCP's own colors.
static BOOL (*sOrigActionAddMarker)(id, SEL, id, BOOL, BOOL, RMTimeRange, NSError **);
static int sActionAddDepth;

static BOOL RMActionAddMarker(id self, SEL _cmd, id object, BOOL todo, BOOL chapter, RMTimeRange range, NSError **err) {
    NSString *color = (sAddingMarker && !todo && !chapter && sActionAddDepth == 0) ? RMDefaultNewMarkerColor() : nil;
    if (!color) return sOrigActionAddMarker(self, _cmd, object, todo, chapter, range, err);

    NSSet *before = nil;
    @try { before = [NSSet setWithArray:RMMarkersOnItem(object)]; } @catch (NSException *e) {}
    NSUndoManager *um = RMUndoManager();
    [um beginUndoGrouping];
    sActionAddDepth++;
    BOOL ok = NO;
    @try {
        ok = sOrigActionAddMarker(self, _cmd, object, todo, chapter, range, err);
        if (ok && before) {
            for (id m in RMMarkersOnItem(object)) {
                if ([before containsObject:m] || !RMIsTimeMarker(m)) continue;
                NSString *name = RMSend(m, @"displayName") ?: @"";
                if (!RMParseColorTag(name, NULL)) RMRename(m, RMNameWithColor(name, color), NULL);
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[RangedMarkers] default marker color failed: %@", e.reason);
    } @finally {
        sActionAddDepth--;
        [um endUndoGrouping];
    }
    RMRefreshAll();
    return ok;
}

static void RMInstallAddHooks(void) {
    Class seqCls = NSClassFromString(@"FFAnchoredSequence");
    if (seqCls) sOrigActionAddMarker = (void *)RMHook(seqCls, NSSelectorFromString(@"actionAddMarkerToAnchoredObject:isToDo:isChapter:withRange:error:"), (IMP)RMActionAddMarker);
    Class organizer = NSClassFromString(@"FFOrganizerFilmstripModule");
    if (organizer) sOrigBrowserAddMarker = (void *)RMHook(organizer, NSSelectorFromString(@"addMarkerAndAlwaysEdit:isToDo:isChapter:isMoment:"), (IMP)RMBrowserAddMarker);
    Class tm = NSClassFromString(@"FFAnchoredTimelineModule");
    Class anchored = NSClassFromString(@"FFAnchoredObject");
    if (!tm || !anchored) return;
    sOrigTimeMarkersForItem = (void *)RMHook(object_getClass(anchored), NSSelectorFromString(@"timeMarkersForItem:inTimeRange:"), (IMP)RMTimeMarkersForItem);
    sOrigAddMarker = (void *)RMHook(tm, NSSelectorFromString(@"addMarkerAndAlwaysEdit:isToDo:isChapter:"), (IMP)RMAddMarker);
}

#pragma mark - Menus

static NSArray<NSString *> *RMColorOrder(void) {
    return @[@"red", @"orange", @"yellow", @"green", @"cyan", @"blue", @"purple", @"pink",
             @"fuchsia", @"rose", @"lavender", @"sky", @"mint", @"lemon", @"sand", @"cocoa", @"cream"];
}

static NSImage *RMSwatch(NSColor *color) {
    return [NSImage imageWithSize:NSMakeSize(12, 12) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [color setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1, 1) xRadius:3 yRadius:3] fill];
        return YES;
    }];
}

// Marker under the playhead (its range covers the playhead), or with
// beforePlayhead, the closest marker starting at or before the playhead.
static BOOL RMMarkerMatchesPlayhead(id marker, double start, double playhead, double frame, BOOL beforePlayhead) {
    double duration = 0;
    RMIsRanged(marker, &duration);
    return beforePlayhead ? start <= playhead + frame / 2
                          : start <= playhead + frame / 2 && playhead < start + MAX(duration, frame);
}

// The same, on the browser clip under the browser playhead (all in clip time).
static id RMBrowserMarkerNearPlayhead(NSView *view, BOOL beforePlayhead) {
    id sequence = RMBrowserClipSequence(RMSend(view, @"persistentPlayheadRangeOfMedia"));
    double playhead;
    if (!RMBrowserPlayhead(view, sequence, &playhead)) return nil;
    double frame = RMFrameSeconds(sequence);
    id best = nil;
    double bestStart = -INFINITY;
    for (id m in RMMarkersOnItem(RMSend(sequence, @"primaryObject"))) {
        RMTime anchor;
        if (!RMReadTime(m, @"targetAnchorTime", &anchor)) continue;
        double start = RMSeconds(anchor);
        if (RMMarkerMatchesPlayhead(m, start, playhead, frame, beforePlayhead) && start > bestStart) { best = m; bestStart = start; }
    }
    return best;
}

static id RMMarkerNearPlayhead(BOOL beforePlayhead) {
    NSView *browser = RMFocusedBrowserView();
    if (browser) return RMBrowserMarkerNearPlayhead(browser, beforePlayhead);
    id sequence = RMActiveSequence();
    double playhead = RMPlayheadSeconds();
    double frame = RMFrameSeconds(sequence);
    id best = nil;
    double bestStart = -INFINITY;
    for (id item in RMSpineItems(sequence)) {
        RMTimeRange r;
        if (!RMItemRange(sequence, item, &r)) continue;
        double itemStart = RMSeconds(r.start), itemEnd = itemStart + RMSeconds(r.duration);
        for (id m in RMMarkersOnItem(item)) {
            double start = RMMarkerSequenceStart(sequence, m);
            if (start < itemStart - 0.001 || start >= itemEnd) continue; // copy on another blade piece
            if (RMMarkerMatchesPlayhead(m, start, playhead, frame, beforePlayhead) && start > bestStart) { best = m; bestStart = start; }
        }
    }
    return best;
}

// Menu items carry {marker, color} in representedObject. Without a marker (the
// main Mark menu) they act on the selected marker, else the one at the playhead.
static id RMMenuMarker(NSMenuItem *item) {
    id marker = [item.representedObject isKindOfClass:[NSDictionary class]] ? item.representedObject[@"marker"] : nil;
    if (RMIsTimeMarker(marker)) return marker;
    marker = RMSelectedMarker();
    if (marker) return marker;
    return RMMarkerNearPlayhead(item.action == NSSelectorFromString(@"rmExtendToPlayhead:"));
}

static void RMActSetColor(id self, SEL _cmd, NSMenuItem *sender) {
    id marker = RMMenuMarker(sender);
    NSString *color = sender.representedObject[@"color"];
    if (!marker || !RMRename(marker, RMNameWithColor(RMSend(marker, @"displayName"), color), NULL)) { NSBeep(); return; }
    RMRefreshAll();
}

static void RMActExtendToPlayhead(id self, SEL _cmd, NSMenuItem *sender) {
    id marker = RMMenuMarker(sender);
    RMTime anchor;
    double playhead = marker ? RMPlayheadForMarker(marker) : -1;
    if (!marker || playhead < 0 || !RMReadTime(marker, @"targetAnchorTime", &anchor) ||
        playhead <= RMSeconds(anchor) + RMFrameSeconds(marker) || !RMSetMarkerDuration(marker, playhead - RMSeconds(anchor))) NSBeep();
}

static void RMActUseInOut(id self, SEL _cmd, NSMenuItem *sender) {
    id marker = RMMenuMarker(sender);
    double start, duration;
    RMTime anchor, fd;
    if (!marker || !RMInOutForMarker(marker, &start, &duration) || !RMReadTime(marker, @"targetAnchorTime", &anchor)) { NSBeep(); return; }
    int32_t ts = RMReadTime(RMMarkerSequence(marker), @"frameDuration", &fd) ? fd.timescale : anchor.timescale;
    if (!RMMoveMarker(marker, RMMakeTime(start, ts), duration)) NSBeep();
}

static void RMActRemoveRange(id self, SEL _cmd, NSMenuItem *sender) {
    id marker = RMMenuMarker(sender);
    if (!marker || !RMSetMarkerDuration(marker, RMFrameSeconds(RMMarkerSequence(marker)))) NSBeep();
}

static NSDictionary *RMAdd(NSDictionary *params);

// In the browser: the range selected in a clip, else 5s from the browser playhead.
static void RMAddRangedInBrowser(NSView *view) {
    id ro = RMBrowserSelectionObject(view, nil);
    RMTimeRange r;
    id sequence = nil;
    double start = 0, duration = 0;
    if (ro && !RMIsWholeClipSelection(ro) && RMReadRange(ro, @"range", &r) && RMSeconds(r.duration) > 0) {
        sequence = RMBrowserClipSequence(ro);
        start = RMSeconds(r.start);
        duration = RMSeconds(r.duration);
    } else {
        sequence = RMBrowserClipSequence(RMSend(view, @"persistentPlayheadRangeOfMedia"));
        if (!RMBrowserPlayhead(view, sequence, &start)) sequence = nil;
        duration = 5.0;
    }
    NSString *error = nil;
    if (!sequence || duration < RMFrameSeconds(sequence) * 2) error = @"Select a range in a browser clip or put the playhead on one";
    else RMAddMarkerToItem(sequence, RMSend(sequence, @"primaryObject"), start, duration, @{}, &error);
    if (error) { NSLog(@"[RangedMarkers] %@", error); NSBeep(); }
}

// Mark > Markers > Add Ranged Marker: the in/out range if set, else 5s from the playhead.
static void RMActAddRanged(id self, SEL _cmd, NSMenuItem *sender) {
    NSView *browser = RMFocusedBrowserView();
    if (browser) { RMAddRangedInBrowser(browser); return; }
    double start, duration;
    if (!RMInOutRange(&start, &duration)) {
        start = RMPlayheadSeconds();
        duration = 5.0;
    }
    NSDictionary *r = RMAdd(@{@"start": @(start), @"duration": @(duration)});
    if (r[@"error"]) { NSLog(@"[RangedMarkers] %@", r[@"error"]); NSBeep(); }
}

static BOOL RMValidateMenuItem(id self, SEL _cmd, NSMenuItem *item) {
    if (item.action == NSSelectorFromString(@"rmAddRanged:")) return RMActiveSequence() != nil || RMFocusedBrowserView() != nil;
    return RMMenuMarker(item) != nil;
}

// Menu target class, created at runtime with a per-build name so hot reloads
// never collide with a previously loaded copy of this plugin.
static id RMMenuTarget(void) {
    static id target;
    if (target) return target;
    NSString *name = [NSString stringWithFormat:@"SKRangedMarkersMenuTarget_%lx", (unsigned long)&RMMenuTarget];
    Class cls = objc_allocateClassPair([NSObject class], name.UTF8String, 0);
    class_addMethod(cls, NSSelectorFromString(@"rmSetColor:"), (IMP)RMActSetColor, "v@:@");
    class_addMethod(cls, NSSelectorFromString(@"rmExtendToPlayhead:"), (IMP)RMActExtendToPlayhead, "v@:@");
    class_addMethod(cls, NSSelectorFromString(@"rmUseInOut:"), (IMP)RMActUseInOut, "v@:@");
    class_addMethod(cls, NSSelectorFromString(@"rmRemoveRange:"), (IMP)RMActRemoveRange, "v@:@");
    class_addMethod(cls, NSSelectorFromString(@"rmAddRanged:"), (IMP)RMActAddRanged, "v@:@");
    class_addMethod(cls, @selector(validateMenuItem:), (IMP)RMValidateMenuItem, "B@:@");
    class_addMethod(cls, NSSelectorFromString(@"rmDurationCommitted:"), (IMP)RMActDurationCommitted, "v@:@");
    class_addMethod(cls, NSSelectorFromString(@"rmEditorColor:"), (IMP)RMActEditorColor, "v@:@");
    objc_registerClassPair(cls);
    target = [cls new];
    return target;
}

static NSMenuItem *RMMenuItem(NSString *title, NSString *action, id marker, NSString *color) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:NSSelectorFromString(action) keyEquivalent:@""];
    item.target = RMMenuTarget();
    item.tag = kMenuTag;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (marker) info[@"marker"] = marker;
    if (color) info[@"color"] = color;
    item.representedObject = info;
    return item;
}

static NSMenuItem *RMTaggedSeparator(void) {
    NSMenuItem *sep = [NSMenuItem separatorItem];
    sep.tag = kMenuTag;
    return sep;
}

static void RMRemoveOurItems(NSMenu *menu) {
    for (NSMenuItem *item in [menu.itemArray copy]) if (item.tag == kMenuTag) [menu removeItem:item];
}

// Color submenu plus range items. marker == nil targets the selected marker.
static void RMAppendMarkerItems(NSMenu *menu, id marker) {
    NSString *current = marker ? RMParseColorTag(RMSend(marker, @"displayName"), NULL) : nil;
    NSMenu *colors = [[NSMenu alloc] initWithTitle:@"Marker Color"];
    for (NSString *c in RMColorOrder()) {
        NSString *title = [[[c substringToIndex:1] uppercaseString] stringByAppendingString:[c substringFromIndex:1]];
        NSMenuItem *item = RMMenuItem(title, @"rmSetColor:", marker, c);
        item.image = RMSwatch(RMPalette()[c]);
        if ([current isEqualToString:c]) item.state = NSControlStateValueOn;
        [colors addItem:item];
    }
    [colors addItem:[NSMenuItem separatorItem]];
    [colors addItem:RMMenuItem(@"Default", @"rmSetColor:", marker, @"none")];

    NSMenuItem *colorItem = RMMenuItem(@"Marker Color", @"", marker, nil);
    colorItem.action = NULL;
    colorItem.submenu = colors;

    [menu addItem:RMTaggedSeparator()];
    [menu addItem:colorItem];
    [menu addItem:RMMenuItem(@"Extend Marker Range to Playhead", @"rmExtendToPlayhead:", marker, nil)];
    [menu addItem:RMMenuItem(@"Set Marker Range to In/Out", @"rmUseInOut:", marker, nil)];
    if (!marker || RMIsRanged(marker, NULL)) {
        [menu addItem:RMMenuItem(@"Remove Marker Range", @"rmRemoveRange:", marker, nil)];
    }
}

static NSMenu *RMFindMenuContaining(NSMenu *menu, SEL action) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action == action) return menu;
        if (item.submenu) {
            NSMenu *found = RMFindMenuContaining(item.submenu, action);
            if (found) return found;
        }
    }
    return nil;
}

// Mark > Markers, found by FCP's own "Add Marker" action so it works in any language.
static void RMInstallMainMenu(void) {
    NSMenu *markers = RMFindMenuContaining(NSApp.mainMenu, NSSelectorFromString(@"addMarker:"));
    if (!markers) { NSLog(@"[RangedMarkers] Mark > Markers menu not found"); return; }
    RMRemoveOurItems(markers);
    NSInteger firstOurs = markers.numberOfItems; // RMAppendMarkerItems starts with a separator
    RMAppendMarkerItems(markers, nil);
    NSMenuItem *add = RMMenuItem(@"Add Ranged Marker", @"rmAddRanged:", nil, nil);
    add.keyEquivalent = @"m";
    add.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    [markers insertItem:add atIndex:firstOurs + 1];
}

static id (*sOrigContextMenu)(id, SEL);

static id RMContextMenu(id self, SEL _cmd) {
    NSMenu *menu = sOrigContextMenu(self, _cmd);
    @try {
        id marker = RMSend(self, @"representedObject");
        if (RMIsTimeMarker(marker)) {
            if (!menu) menu = [[NSMenu alloc] initWithTitle:@""];
            RMRemoveOurItems(menu);
            RMAppendMarkerItems(menu, marker);
        }
    } @catch (NSException *e) {
        NSLog(@"[RangedMarkers] context menu failed: %@", e.reason);
    }
    return menu;
}

// Browser marker layer whose pin or range bar is under the event.
static CALayer *RMBrowserMarkerLayerAt(NSEvent *event, NSView *view) {
    NSPoint p = [view convertPoint:event.locationInWindow fromView:nil];
    for (CALayer *layer in sBrowserMarkerLayers.allObjects) {
        if (layer.hidden || !RMLayerIsInView(layer, view)) continue;
        CALayer *bar = RMSublayerNamed(layer, kBarLayerName);
        if (CGRectContainsPoint(CGRectInset(layer.bounds, -1, -1), [view.layer convertPoint:p toLayer:layer]) ||
            (bar && CGRectContainsPoint(CGRectInset(bar.bounds, 0, -2), [view.layer convertPoint:p toLayer:bar]))) return layer;
    }
    return nil;
}

// The browser builds and pops up its context menu inside -rightMouseDown:. Note the
// marker under the click there, and add our items to the menu as it pops up.
static id sRightClickMarker;
static void (*sOrigBrowserRightMouseDown)(id, SEL, NSEvent *);
static void (*sOrigPopUpContextMenu)(id, SEL, NSMenu *, NSEvent *, NSView *);
static BOOL (*sOrigPopUpMenu)(id, SEL, NSMenuItem *, NSPoint, NSView *);

static void RMAddRightClickItems(NSMenu *menu) {
    id marker = sRightClickMarker;
    sRightClickMarker = nil;
    if (!marker || !menu) return;
    @try {
        RMRemoveOurItems(menu);
        RMAppendMarkerItems(menu, marker);
    } @catch (NSException *e) {
        NSLog(@"[RangedMarkers] browser context menu failed: %@", e.reason);
    }
}

static void RMBrowserRightMouseDown(id self, SEL _cmd, NSEvent *event) {
    @try { sRightClickMarker = RMLayerMarker(RMBrowserMarkerLayerAt(event, self)); } @catch (NSException *e) {}
    @try { sOrigBrowserRightMouseDown(self, _cmd, event); }
    @finally { sRightClickMarker = nil; }
}

static void RMPopUpContextMenu(id self, SEL _cmd, NSMenu *menu, NSEvent *event, NSView *view) {
    RMAddRightClickItems(menu);
    sOrigPopUpContextMenu(self, _cmd, menu, event, view);
}

static BOOL RMPopUpMenu(id self, SEL _cmd, NSMenuItem *item, NSPoint location, NSView *view) {
    RMAddRightClickItems(self);
    return sOrigPopUpMenu(self, _cmd, item, location, view);
}

#pragma mark - Dragging the range end

static id sDragMarker;
static NSView *sDragView;
static CGFloat sDragStartX, sDragStartWidth;
static double sDragTPP, sDragFrame;
static NSString *const kLabelLayerName = @"skRangedMarkerLabel";

static NSView *RMActiveTimelineView(void) {
    id view = RMSend(sGetTimelineModule ? sGetTimelineModule() : nil, @"timelineView");
    return [view isKindOfClass:[NSView class]] ? view : nil;
}

// Marker layer (timeline or browser view) whose range handle is under the event, if any.
static CALayer *RMHandleHit(NSEvent *event, NSView *view, CGFloat *viewX) {
    if (!view || event.window != view.window) return nil;
    NSPoint p = [view convertPoint:event.locationInWindow fromView:nil];
    if (viewX) *viewX = p.x;
    __block CALayer *hit = nil;
    void (^test)(CALayer *) = ^(CALayer *layer) {
        CALayer *bar = hit ? nil : RMSublayerNamed(layer, kBarLayerName);
        if (!bar) return;
        CGPoint lp = [view.layer convertPoint:p toLayer:bar];
        CGSize size = bar.bounds.size;
        if (lp.x >= size.width - 7 && lp.x <= size.width + 5 && lp.y >= -6 && lp.y <= size.height + 6) hit = layer;
    };
    if ([view isKindOfClass:RMBrowserViewClass()]) {
        for (CALayer *layer in sBrowserMarkerLayers.allObjects) if (RMLayerIsInView(layer, view)) test(layer);
    } else {
        RMVisitMarkerLayers(view.layer, test);
    }
    return hit;
}

static void RMShowDragLabel(CALayer *bar, double seconds) {
    CATextLayer *label = (CATextLayer *)RMSublayerNamed(bar, kLabelLayerName);
    if (!label) {
        label = [CATextLayer layer];
        label.name = kLabelLayerName;
        label.fontSize = 10;
        label.foregroundColor = NSColor.whiteColor.CGColor;
        label.backgroundColor = [NSColor colorWithWhite:0 alpha:0.75].CGColor;
        label.cornerRadius = 3;
        label.alignmentMode = kCAAlignmentCenter;
        label.contentsScale = NSScreen.mainScreen.backingScaleFactor;
        [bar addSublayer:label];
    }
    int fps = (int)llround(1.0 / sDragFrame);
    int64_t frames = llround(seconds / sDragFrame);
    label.string = [NSString stringWithFormat:@"%lld:%02lld:%02lld",
                    frames / fps / 60, (frames / fps) % 60, frames % fps];
    label.frame = CGRectMake(bar.bounds.size.width + 6, -3, 56, 14);
}

// Returns YES when the mouse down starts a range drag (FCP must not see the event).
static BOOL RMBeginRangeDrag(NSEvent *event, NSView *view) {
    @try {
        CGFloat x = 0;
        CALayer *layer = (event.clickCount == 1) ? RMHandleHit(event, view, &x) : nil;
        id marker = RMLayerMarker(layer);
        double spp = layer ? RMLayerSecondsPerPixel(layer) : 0;
        if (!marker || spp <= 0) return NO;
        sDragLayer = layer;
        sDragMarker = marker;
        sDragView = view;
        sDragStartX = x;
        sDragStartWidth = sDragWidth = RMSublayerNamed(layer, kBarLayerName).bounds.size.width;
        sDragTPP = spp;
        sDragFrame = RMFrameSeconds(marker);
        [[NSCursor resizeLeftRightCursor] set];
        return YES;
    } @catch (NSException *e) {
        sDragLayer = nil;
        return NO;
    }
}

static BOOL RMContinueRangeDrag(NSEvent *event) {
    if (!sDragLayer) return NO;
    CGFloat x = [sDragView convertPoint:event.locationInWindow fromView:nil].x;
    double seconds = MAX(2, llround((sDragStartWidth + (x - sDragStartX)) * sDragTPP / sDragFrame)) * sDragFrame;
    sDragWidth = seconds / sDragTPP;
    RMUpdateMarkerLayer(sDragLayer);
    CALayer *bar = RMSublayerNamed(sDragLayer, kBarLayerName);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    RMShowDragLabel(bar, seconds);
    [CATransaction commit];
    [[NSCursor resizeLeftRightCursor] set];
    return YES;
}

static BOOL RMEndRangeDrag(NSEvent *event) {
    if (!sDragLayer) return NO;
    CALayer *layer = sDragLayer;
    id marker = sDragMarker;
    double seconds = sDragWidth * sDragTPP;
    BOOL changed = fabs(sDragWidth - sDragStartWidth) >= 0.5;
    sDragLayer = nil;
    sDragMarker = nil;
    sDragView = nil;
    [RMSublayerNamed(RMSublayerNamed(layer, kBarLayerName), kLabelLayerName) removeFromSuperlayer];
    if (changed) RMSetMarkerDuration(marker, seconds);
    RMUpdateMarkerLayer(layer);
    [[NSCursor arrowCursor] set];
    return YES;
}

static void RMUpdateHandleCursor(NSEvent *event, NSView *view) {
    @try {
        if (!sDragLayer && RMHandleHit(event, view, NULL)) [[NSCursor resizeLeftRightCursor] set];
    } @catch (NSException *e) {}
}

// Timeline: TLKEventDispatcher handles the timeline view's mouse events.
static void (*sOrigMouseDown)(id, SEL, NSEvent *);
static void (*sOrigMouseDragged)(id, SEL, NSEvent *);
static void (*sOrigMouseUp)(id, SEL, NSEvent *);
static void (*sOrigMouseMoved)(id, SEL, NSEvent *);

static void RMMouseDown(id self, SEL _cmd, NSEvent *event) {
    if (!RMBeginRangeDrag(event, RMActiveTimelineView())) sOrigMouseDown(self, _cmd, event);
}
static void RMMouseDragged(id self, SEL _cmd, NSEvent *event) {
    if (!RMContinueRangeDrag(event)) sOrigMouseDragged(self, _cmd, event);
}
static void RMMouseUp(id self, SEL _cmd, NSEvent *event) {
    if (!RMEndRangeDrag(event)) sOrigMouseUp(self, _cmd, event);
}
static void RMMouseMoved(id self, SEL _cmd, NSEvent *event) {
    sOrigMouseMoved(self, _cmd, event);
    RMUpdateHandleCursor(event, RMActiveTimelineView());
}

#pragma mark - Dragging browser markers

// FCP's browser can't drag markers at all, so the plugin moves them: dragging a pin
// moves the marker (and its range) along its clip, as one undoable edit. FCP doesn't
// see a press on a pin until it is released without moving; then it gets the press
// and release as usual, so clicking and double-clicking a marker work as before.
static CALayer *sMoveLayer;
static NSEvent *sMoveDownEvent;
static CGFloat sMoveStartX;
static BOOL sMoveActive;

// Browser marker layer whose pin (not its range bar) is under the event.
static CALayer *RMBrowserPinAt(NSEvent *event, NSView *view) {
    NSPoint p = [view convertPoint:event.locationInWindow fromView:nil];
    for (CALayer *layer in sBrowserMarkerLayers.allObjects) {
        if (layer.hidden || !RMLayerIsInView(layer, view)) continue;
        if (CGRectContainsPoint(CGRectInset(layer.bounds, -1, -1), [view.layer convertPoint:p toLayer:layer])) return layer;
    }
    return nil;
}

static BOOL RMBeginPinPress(NSEvent *event, NSView *view) {
    if (event.clickCount != 1 || event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl)) return NO;
    CALayer *layer = nil;
    @try { layer = RMBrowserPinAt(event, view); } @catch (NSException *e) {}
    if (!RMLayerMarker(layer) || RMLayerSecondsPerPixel(layer) <= 0) return NO;
    sMoveLayer = layer;
    sMoveDownEvent = event;
    sMoveStartX = [view convertPoint:event.locationInWindow fromView:nil].x;
    sMoveActive = NO;
    return YES;
}

static BOOL RMContinuePinMove(NSEvent *event, NSView *view) {
    if (!sMoveLayer) return NO;
    CGFloat dx = [view convertPoint:event.locationInWindow fromView:nil].x - sMoveStartX;
    if (!sMoveActive && fabs(dx) < 3) return YES;
    sMoveActive = YES;
    double spp = RMLayerSecondsPerPixel(sMoveLayer), frame = RMFrameSeconds(RMLayerMarker(sMoveLayer));
    CGFloat snapped = spp > 0 ? llround(dx * spp / frame) * frame / spp : dx;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    sMoveLayer.transform = CATransform3DMakeTranslation(snapped, 0, 0);
    [CATransaction commit];
    [[NSCursor closedHandCursor] set];
    return YES;
}

// Moves marker to start at localStart in its clip, keeping its length.
static BOOL RMMoveMarkerStart(id marker, double localStart) {
    double duration = 0;
    id sequence = RMMarkerSequence(marker);
    int32_t ts = 24000;
    RMTime fd, d;
    if (RMReadTime(sequence, @"frameDuration", &fd)) ts = fd.timescale;
    if (RMIsRanged(marker, &duration)) return RMMoveMarker(marker, RMMakeTime(localStart, ts), duration);
    // One-frame markers keep FCP's own (sub-frame) length.
    SEL sel = NSSelectorFromString(@"actionMoveMarker:toRange:error:");
    if (![sequence respondsToSelector:sel] || !RMReadTime(marker, @"duration", &d)) return NO;
    RMTimeRange range = { RMMakeTime(localStart, ts), d };
    NSError *err = nil;
    BOOL ok = ((BOOL (*)(id, SEL, id, RMTimeRange, NSError **))objc_msgSend)(sequence, sel, marker, range, &err);
    if (!ok) NSLog(@"[RangedMarkers] move failed: %@", err.localizedDescription);
    RMRefreshAll();
    return ok;
}

// Returns NO if no pin press was pending. *wasClick says FCP should now get the press.
static BOOL RMEndPinPress(NSEvent *event, NSView *view, BOOL *wasClick) {
    if (!sMoveLayer) return NO;
    CALayer *layer = sMoveLayer;
    BOOL moved = sMoveActive;
    sMoveLayer = nil;
    sMoveActive = NO;
    *wasClick = !moved;
    if (!moved) return YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.transform = CATransform3DIdentity;
    [CATransaction commit];
    [[NSCursor arrowCursor] set];

    id marker = RMLayerMarker(layer);
    double spp = RMLayerSecondsPerPixel(layer), frame = RMFrameSeconds(marker);
    CGFloat dx = [view convertPoint:event.locationInWindow fromView:nil].x - sMoveStartX;
    RMTime anchor;
    RMTimeRange clip;
    if (!marker || spp <= 0 || !RMReadTime(marker, @"targetAnchorTime", &anchor)) { NSBeep(); return YES; }
    double start = RMSeconds(anchor) + llround(dx * spp / frame) * frame;
    // Keep the marker on its clip.
    if (RMReadRange(RMMarkerItem(marker), @"clippedRange", &clip)) {
        double clipStart = RMSeconds(clip.start), clipEnd = clipStart + RMSeconds(clip.duration);
        start = MAX(clipStart, MIN(start, floor((clipEnd - clipStart) / frame - 1) * frame + clipStart));
    }
    if (fabs(start - RMSeconds(anchor)) >= frame / 2 && !RMMoveMarkerStart(marker, start)) NSBeep();
    return YES;
}

// Browser: the filmstrip view handles its own mouse events.
static void (*sOrigBrowserMouseDown)(id, SEL, NSEvent *);
static void (*sOrigBrowserMouseDragged)(id, SEL, NSEvent *);
static void (*sOrigBrowserMouseUp)(id, SEL, NSEvent *);
static void (*sOrigBrowserMouseMoved)(id, SEL, NSEvent *);

static void RMBrowserMouseDown(id self, SEL _cmd, NSEvent *event) {
    if (RMBeginRangeDrag(event, self) || RMBeginPinPress(event, self)) return;
    sOrigBrowserMouseDown(self, _cmd, event);
}
static void RMBrowserMouseDragged(id self, SEL _cmd, NSEvent *event) {
    if (RMContinueRangeDrag(event) || RMContinuePinMove(event, self)) return;
    sOrigBrowserMouseDragged(self, _cmd, event);
}

// A pin press that never moved is a click: give FCP the press, then the release.
static void RMBrowserMouseUpWith(id self, SEL _cmd, NSEvent *event, void (*origUp)(id, SEL, NSEvent *)) {
    if (RMEndRangeDrag(event)) return;
    NSEvent *down = sMoveDownEvent;
    BOOL wasClick = NO;
    BOOL pinPress = RMEndPinPress(event, self, &wasClick);
    sMoveDownEvent = nil;
    if (pinPress && !wasClick) return;
    if (pinPress && down) sOrigBrowserMouseDown(self, @selector(mouseDown:), down);
    origUp(self, _cmd, event);
}
static void RMBrowserMouseUp(id self, SEL _cmd, NSEvent *event) {
    RMBrowserMouseUpWith(self, _cmd, event, sOrigBrowserMouseUp);
}
// FCP's browser is FFOrganizerFilmstripViewPro, which has its own -mouseUp:.
static void (*sOrigBrowserProMouseUp)(id, SEL, NSEvent *);
static void RMBrowserProMouseUp(id self, SEL _cmd, NSEvent *event) {
    RMBrowserMouseUpWith(self, _cmd, event, sOrigBrowserProMouseUp);
}
static void RMBrowserMouseMoved(id self, SEL _cmd, NSEvent *event) {
    sOrigBrowserMouseMoved(self, _cmd, event);
    RMUpdateHandleCursor(event, self);
}

#pragma mark - Duration field in the marker editor

static const void *kDurationFieldKey = &kDurationFieldKey;
static const void *kDurationEditorKey = &kDurationEditorKey;
static const CGFloat kDurationRowHeight = 30;

static NSString *RMFormatTimecode(double seconds, double frame) {
    int fps = MAX(1, (int)llround(1.0 / frame));
    int64_t frames = llround(seconds / frame);
    int64_t secs = frames / fps;
    return [NSString stringWithFormat:@"%02lld:%02lld:%02lld:%02lld",
            secs / 3600, (secs / 60) % 60, secs % 60, frames % fps];
}

// "10", "2.5", "10s" -> seconds; "10:00", "1:02:12", "00:00:10:00" -> timecode read right to
// left as HH:MM:SS:FF like FCP's own fields. Returns -1 for input it can't read.
static double RMParseDurationInput(NSString *text, double frame) {
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
    if (!text.length) return 0;
    if ([text hasSuffix:@"s"]) text = [text substringToIndex:text.length - 1];
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@":;."];
    if ([text rangeOfString:@":"].location == NSNotFound && [text rangeOfString:@";"].location == NSNotFound) {
        NSScanner *scanner = [NSScanner scannerWithString:text];
        double value;
        return ([scanner scanDouble:&value] && scanner.atEnd && value >= 0) ? value : -1;
    }
    NSArray *parts = [text componentsSeparatedByCharactersInSet:separators];
    if (parts.count > 4) return -1;
    int64_t fields[4] = {0, 0, 0, 0}; // HH MM SS FF
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *part = parts[parts.count - 1 - i];
        NSScanner *scanner = [NSScanner scannerWithString:part];
        long long v = 0;
        if (part.length && (![scanner scanLongLong:&v] || !scanner.atEnd || v < 0)) return -1;
        fields[3 - i] = v;
    }
    int fps = MAX(1, (int)llround(1.0 / frame));
    int64_t frames = ((fields[0] * 3600 + fields[1] * 60 + fields[2]) * fps) + fields[3];
    return frames * frame;
}

static id RMEditorMarker(id editor) {
    id marker = RMSend(editor, @"marker");
    return RMIsTimeMarker(marker) ? marker : nil;
}

static void RMRefreshDurationField(id editor) {
    NSTextField *field = objc_getAssociatedObject(editor, kDurationFieldKey);
    id marker = RMEditorMarker(editor);
    if (!field || !marker) return;
    double duration = 0;
    field.stringValue = RMIsRanged(marker, &duration) ? RMFormatTimecode(duration, RMFrameSeconds(marker)) : @"";
}

static void RMActDurationCommitted(id self, SEL _cmd, NSTextField *field) {
    id editor = objc_getAssociatedObject(field, kDurationEditorKey);
    id marker = RMEditorMarker(editor);
    if (!marker) return;
    double frame = RMFrameSeconds(marker);
    double seconds = RMParseDurationInput(field.stringValue, frame);
    if (seconds < 0) { NSBeep(); RMRefreshDurationField(editor); return; }
    double current = 0;
    RMIsRanged(marker, &current);
    double wanted = seconds < frame * 1.5 ? frame : seconds; // blank / 0 removes the range
    if (fabs(wanted - MAX(current, frame)) < frame / 2) { RMRefreshDurationField(editor); return; }

    NSTextField *nameField = [editor valueForKey:@"displayNameField"];
    NSString *nameBefore = RMSend(marker, @"displayName") ?: @"";
    if (!RMSetMarkerDuration(marker, wanted)) NSBeep();

    // The duration may have added or removed a "[... 12.5s]" tag. Carry that into the
    // name field so FCP's own save on Done doesn't write the old name back.
    NSString *nameAfter = RMSend(marker, @"displayName") ?: @"";
    if (nameField && ![nameAfter isEqualToString:nameBefore]) {
        if ([nameField.stringValue isEqualToString:nameBefore]) {
            nameField.stringValue = nameAfter;
        } else {
            NSString *title = nil, *color = nil;
            RMParseTag(nameField.stringValue, &title, &color);
            nameField.stringValue = RMFormatName(title, color, RMParseTag(nameAfter, NULL, NULL));
        }
    }
    RMRefreshDurationField(editor);
}

// Grow the editor view and its popover (or window) by dh points.
static void RMGrowEditor(NSView *view, CGFloat dh) {
    NSSize size = view.frame.size;
    size.height += dh;
    [view setFrameSize:size];
    NSPopover *popover = nil;
    @try { popover = [view.window valueForKey:@"_popover"]; } @catch (NSException *e) {}
    if ([popover isKindOfClass:[NSPopover class]]) {
        NSSize content = popover.contentSize;
        content.height += dh;
        popover.contentSize = content;
    } else if (view.window) {
        NSRect frame = view.window.frame;
        frame.size.height += dh;
        [view.window setFrame:frame display:YES];
    }
}

#pragma mark - Color row in the marker editor

// A row of marker-shaped swatches under Duration / Delete / Done. Picking one
// recolors the marker being edited and becomes the default color for markers
// added later (kDefaultColorKey). "none" is FCP's own marker color.
static const void *kColorRowKey = &kColorRowKey;
static const CGFloat kColorRowHeight = 30;
static NSString *const kDefaultColorKey = @"SKRangedMarkersDefaultColor";

static NSString *RMDefaultNewMarkerColor(void) {
    NSString *c = [[NSUserDefaults standardUserDefaults] stringForKey:kDefaultColorKey];
    return (c.length && RMPalette()[c]) ? c : nil;
}

static void RMSetDefaultNewMarkerColor(NSString *color) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (color.length && RMPalette()[color]) [d setObject:color forKey:kDefaultColorKey];
    else [d removeObjectForKey:kDefaultColorKey];
}

static NSColor *RMStandardMarkerColor(void) {
    return [NSColor colorWithSRGBRed:0.47 green:0.47 blue:0.95 alpha:1];
}

// FCP's marker glyph: a rounded tab with a point at the bottom.
static NSImage *RMMarkerGlyph(NSColor *color, BOOL selected) {
    return [NSImage imageWithSize:NSMakeSize(22, 22) flipped:NO drawingHandler:^BOOL(NSRect r) {
        if (selected) {
            [[NSColor colorWithWhite:1 alpha:0.18] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0.5, 0.5) xRadius:5 yRadius:5] fill];
            [[NSColor colorWithWhite:1 alpha:0.75] setStroke];
            NSBezierPath *ring = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1, 1) xRadius:4.5 yRadius:4.5];
            ring.lineWidth = 1.2;
            [ring stroke];
        }
        CGFloat w = 10, h = 14, x = NSMidX(r) - w / 2, top = NSMidY(r) + h / 2, bottom = top - h;
        CGFloat shoulder = bottom + 4.5, radius = 2;
        NSBezierPath *path = [NSBezierPath bezierPath];
        [path moveToPoint:NSMakePoint(NSMidX(r), bottom)];
        [path lineToPoint:NSMakePoint(x, shoulder)];
        [path lineToPoint:NSMakePoint(x, top - radius)];
        [path appendBezierPathWithArcFromPoint:NSMakePoint(x, top) toPoint:NSMakePoint(x + radius, top) radius:radius];
        [path lineToPoint:NSMakePoint(x + w - radius, top)];
        [path appendBezierPathWithArcFromPoint:NSMakePoint(x + w, top) toPoint:NSMakePoint(x + w, top - radius) radius:radius];
        [path lineToPoint:NSMakePoint(x + w, shoulder)];
        [path closePath];
        [color setFill];
        [path fill];
        [[NSColor colorWithWhite:0 alpha:0.35] setStroke];
        path.lineWidth = 0.75;
        [path stroke];
        return YES;
    }];
}

static NSArray<NSString *> *RMEditorColorChoices(void) {
    return [@[@"none"] arrayByAddingObjectsFromArray:RMColorOrder()];
}

static NSString *RMTitleCase(NSString *c) {
    return [[[c substringToIndex:1] uppercaseString] stringByAppendingString:[c substringFromIndex:1]];
}

// Highlight the swatch matching the edited marker's color.
static void RMRefreshColorRow(id editor) {
    NSArray<NSButton *> *buttons = objc_getAssociatedObject(editor, kColorRowKey);
    if (!buttons.count) return;
    id marker = RMEditorMarker(editor);
    NSString *current = marker ? (RMParseColorTag(RMSend(marker, @"displayName"), NULL) ?: @"none") : nil;
    for (NSButton *b in buttons) {
        NSString *c = b.identifier;
        NSColor *color = [c isEqualToString:@"none"] ? RMStandardMarkerColor() : RMPalette()[c];
        b.image = RMMarkerGlyph(color, [c isEqualToString:current]);
    }
}

static void RMActEditorColor(id self, SEL _cmd, NSButton *sender) {
    id editor = objc_getAssociatedObject(sender, kDurationEditorKey);
    id marker = RMEditorMarker(editor);
    NSString *color = sender.identifier;
    RMSetDefaultNewMarkerColor(color);
    if (!marker) { RMRefreshColorRow(editor); return; }

    NSTextField *nameField = [editor valueForKey:@"displayNameField"];
    NSString *nameBefore = RMSend(marker, @"displayName") ?: @"";
    if (!RMRename(marker, RMNameWithColor(nameBefore, color), NULL)) NSBeep();
    NSString *nameAfter = RMSend(marker, @"displayName") ?: @"";

    // Keep the name field in step so FCP's save on Done doesn't write the old name back.
    if (nameField) {
        if ([nameField.stringValue isEqualToString:nameBefore]) nameField.stringValue = nameAfter;
        else nameField.stringValue = RMNameWithColor(nameField.stringValue, color);
    }
    RMRefreshAll();
    RMRefreshColorRow(editor);
}

static void RMAddColorRow(id editor) {
    if (objc_getAssociatedObject(editor, kColorRowKey)) { RMRefreshColorRow(editor); return; }
    NSView *view = RMSend(editor, @"view");
    NSTextField *nameField = [editor valueForKey:@"displayNameField"];
    if (![view isKindOfClass:[NSView class]] || !nameField) return;

    // Lift everything one row; the swatches take the old bottom row's spot.
    CGFloat bottomY = CGFLOAT_MAX, right = NSMaxX(nameField.frame);
    for (NSView *sub in view.subviews) {
        if (sub.hidden || NSHeight(sub.frame) > NSHeight(view.bounds) * 0.8) continue;
        bottomY = MIN(bottomY, NSMinY(sub.frame));
        right = MAX(right, NSMaxX(sub.frame));
    }
    if (bottomY == CGFLOAT_MAX) return;
    for (NSView *sub in view.subviews) {
        if (NSHeight(sub.frame) > NSHeight(view.bounds) * 0.8) continue;
        [sub setFrameOrigin:NSMakePoint(NSMinX(sub.frame), NSMinY(sub.frame) + kColorRowHeight)];
    }

    NSArray *choices = RMEditorColorChoices();
    CGFloat left = NSMinX(nameField.frame);
    CGFloat step = MIN(26, (right - left) / choices.count);
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSUInteger i = 0; i < choices.count; i++) {
        NSString *c = choices[i];
        NSButton *b = [NSButton buttonWithImage:RMMarkerGlyph(RMStandardMarkerColor(), NO)
                                         target:RMMenuTarget() action:NSSelectorFromString(@"rmEditorColor:")];
        b.bordered = NO;
        b.imagePosition = NSImageOnly;
        b.frame = NSMakeRect(left + i * step, bottomY + 1, 22, 22);
        b.identifier = c;
        b.tag = kMenuTag;
        b.toolTip = [c isEqualToString:@"none"]
            ? @"Default marker color (also used for new markers)"
            : [NSString stringWithFormat:@"%@ (also used for new markers)", RMTitleCase(c)];
        objc_setAssociatedObject(b, kDurationEditorKey, editor, OBJC_ASSOCIATION_ASSIGN);
        [view addSubview:b];
        [buttons addObject:b];
    }
    objc_setAssociatedObject(editor, kColorRowKey, buttons, OBJC_ASSOCIATION_RETAIN);
    RMGrowEditor(view, kColorRowHeight);
    RMRefreshColorRow(editor);
}

// Adds "Duration: [00:00:08:00]" between the name field and the bottom row.
static void RMAddDurationRow(id editor) {
    if (objc_getAssociatedObject(editor, kDurationFieldKey)) { RMRefreshDurationField(editor); return; }
    NSView *view = RMSend(editor, @"view");
    NSTextField *nameField = [editor valueForKey:@"displayNameField"];
    NSView *typeControl = [editor valueForKey:@"typeControl"];
    NSTextField *timecode = [editor valueForKey:@"timecodeField"];
    if (![view isKindOfClass:[NSView class]] || !nameField || !timecode) return;

    // Move the name field and type buttons up one row; the new row takes the name's old spot.
    CGFloat rowY = NSMinY(nameField.frame);
    [nameField setFrameOrigin:NSMakePoint(NSMinX(nameField.frame), rowY + kDurationRowHeight)];
    if (typeControl) [typeControl setFrameOrigin:NSMakePoint(NSMinX(typeControl.frame), NSMinY(typeControl.frame) + kDurationRowHeight)];

    NSTextField *label = [NSTextField labelWithString:@"Duration:"];
    label.font = timecode.font ?: [NSFont systemFontOfSize:12];
    label.textColor = NSColor.secondaryLabelColor;
    label.alignment = NSTextAlignmentRight;
    label.frame = NSMakeRect(NSMinX(nameField.frame), rowY + 3, 64, 18);
    label.tag = kMenuTag;

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(NSMaxX(label.frame) + 6, rowY, 116, 24)];
    field.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    field.placeholderString = @"None";
    field.toolTip = @"Marker range length. Type timecode (00:00:10:00 or 10:00) or seconds (10, 2.5). Leave empty to remove the range.";
    field.bezelStyle = NSTextFieldRoundedBezel;
    field.target = RMMenuTarget();
    field.action = NSSelectorFromString(@"rmDurationCommitted:");
    field.cell.sendsActionOnEndEditing = YES;
    field.tag = kMenuTag;

    [view addSubview:label];
    [view addSubview:field];
    objc_setAssociatedObject(editor, kDurationFieldKey, field, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(field, kDurationEditorKey, editor, OBJC_ASSOCIATION_ASSIGN);

    RMGrowEditor(view, kDurationRowHeight);
    RMRefreshDurationField(editor);
    RMAddColorRow(editor);
}

static void (*sOrigEditorSave)(id, SEL, id);
static void (*sOrigEditorReflect)(id, SEL, id);

// Done: commit a typed duration before FCP saves the name and closes the popover.
static void RMEditorSave(id self, SEL _cmd, id sender) {
    NSTextField *field = objc_getAssociatedObject(self, kDurationFieldKey);
    @try {
        if (field && field.currentEditor) [field.window makeFirstResponder:nil]; // fires the field's action
    } @catch (NSException *e) {}
    sOrigEditorSave(self, _cmd, sender);
}

static void RMEditorReflect(id self, SEL _cmd, id key) {
    sOrigEditorReflect(self, _cmd, key);
    NSTextField *field = objc_getAssociatedObject(self, kDurationFieldKey);
    if (field && !field.currentEditor) RMRefreshDurationField(self);
    RMRefreshColorRow(self);
}

static void (*sOrigEditorInstalled)(id, SEL, id);

static void RMEditorInstalled(id self, SEL _cmd, id arg) {
    sOrigEditorInstalled(self, _cmd, arg);
    sLastMarkerEditor = self;
    @try { RMAddDurationRow(self); } @catch (NSException *e) { NSLog(@"[RangedMarkers] duration row failed: %@", e.reason); }
}

static void (*sOrigEditorDidShow)(id, SEL);

static void RMEditorDidShow(id self, SEL _cmd) {
    sOrigEditorDidShow(self, _cmd);
    sLastMarkerEditor = self;
    @try { RMAddDurationRow(self); } @catch (NSException *e) { NSLog(@"[RangedMarkers] duration row failed: %@", e.reason); }
}

static void RMInstallUI(void) {
    Class markerLayer = NSClassFromString(@"TLKMarkerLayer");
    if (markerLayer) sOrigContextMenu = (void *)RMHook(markerLayer, NSSelectorFromString(@"contextMenu"), (IMP)RMContextMenu);
    Class dispatcher = NSClassFromString(@"TLKEventDispatcher");
    if (dispatcher) {
        sOrigMouseDown = (void *)RMHook(dispatcher, @selector(mouseDown:), (IMP)RMMouseDown);
        sOrigMouseDragged = (void *)RMHook(dispatcher, @selector(mouseDragged:), (IMP)RMMouseDragged);
        sOrigMouseUp = (void *)RMHook(dispatcher, @selector(mouseUp:), (IMP)RMMouseUp);
        sOrigMouseMoved = (void *)RMHook(dispatcher, @selector(mouseMoved:), (IMP)RMMouseMoved);
    }
    Class browser = RMBrowserViewClass();
    if (browser) {
        sOrigBrowserRightMouseDown = (void *)RMHook(browser, @selector(rightMouseDown:), (IMP)RMBrowserRightMouseDown);
        sOrigPopUpContextMenu = (void *)RMHook(object_getClass([NSMenu class]), @selector(popUpContextMenu:withEvent:forView:), (IMP)RMPopUpContextMenu);
        sOrigPopUpMenu = (void *)RMHook([NSMenu class], @selector(popUpMenuPositioningItem:atLocation:inView:), (IMP)RMPopUpMenu);
        sOrigBrowserMouseDown = (void *)RMHook(browser, @selector(mouseDown:), (IMP)RMBrowserMouseDown);
        sOrigBrowserMouseDragged = (void *)RMHook(browser, @selector(mouseDragged:), (IMP)RMBrowserMouseDragged);
        sOrigBrowserMouseUp = (void *)RMHook(browser, @selector(mouseUp:), (IMP)RMBrowserMouseUp);
        sOrigBrowserMouseMoved = (void *)RMHook(browser, @selector(mouseMoved:), (IMP)RMBrowserMouseMoved);
        Class pro = NSClassFromString(@"FFOrganizerFilmstripViewPro");
        if (pro) sOrigBrowserProMouseUp = (void *)RMHook(pro, @selector(mouseUp:), (IMP)RMBrowserProMouseUp);
    }
    Class editor = NSClassFromString(@"FFMarkerEditorViewModule");
    if (editor) {
        sOrigEditorInstalled = (void *)RMHook(editor, NSSelectorFromString(@"moduleViewWasInstalled:"), (IMP)RMEditorInstalled);
        sOrigEditorDidShow = (void *)RMHook(editor, NSSelectorFromString(@"windowDidShow"), (IMP)RMEditorDidShow);
        sOrigEditorSave = (void *)RMHook(editor, NSSelectorFromString(@"save:"), (IMP)RMEditorSave);
        sOrigEditorReflect = (void *)RMHook(editor, NSSelectorFromString(@"_reflectMarkerPropertiesInGUIWithChangedKey:"), (IMP)RMEditorReflect);
    }
    RMInstallMainMenu();
}

#pragma mark - Setup

static void RMSetUp(void) {
    if (sSetUp) return;
    sRegister = (RMRegisterFn)dlsym(RTLD_DEFAULT, "SpliceKit_registerPluginMethod");
    sOnMain = (RMMainThreadFn)dlsym(RTLD_DEFAULT, "SpliceKit_executeOnMainThread");
    sGetTimelineModule = (RMGetModuleFn)dlsym(RTLD_DEFAULT, "SpliceKit_getActiveTimelineModule");
    sStoreHandle = (RMStoreHandleFn)dlsym(RTLD_DEFAULT, "SpliceKit_storeHandle");
    sResolveHandle = (RMResolveHandleFn)dlsym(RTLD_DEFAULT, "SpliceKit_resolveHandle");
    if (!sRegister || !sOnMain || !sGetTimelineModule) {
        NSLog(@"[RangedMarkers] SpliceKit symbols not found; not loading");
        return;
    }
    sSetUp = YES;

    sRegister(@"rangedMarkers.add", ^NSDictionary *(NSDictionary *p) { return RMAdd(p); }, @{
        @"description": @"Add a ranged (and optionally colored) marker. Params: start, end or duration (seconds, sequence time; defaults to the in/out range), name, color (red, blue, green, yellow, orange, purple, pink, cyan, ...), kind (standard|todo|chapter).",
        @"readOnly": @NO, @"pluginId": @"com.splicekit.ranged-markers", @"shortName": @"add"});
    sRegister(@"rangedMarkers.setColor", ^NSDictionary *(NSDictionary *p) { return RMSetColor(p); }, @{
        @"description": @"Set the color of the selected marker (or a marker handle). Params: color (or \"none\"), marker (optional handle).",
        @"readOnly": @NO, @"pluginId": @"com.splicekit.ranged-markers", @"shortName": @"setColor"});
    sRegister(@"rangedMarkers.list", ^NSDictionary *(NSDictionary *p) { return RMList(p); }, @{
        @"description": @"List markers on the primary storyline with start, duration, color and kind.",
        @"readOnly": @YES, @"pluginId": @"com.splicekit.ranged-markers", @"shortName": @"list"});
    sRegister(@"rangedMarkers.refresh", ^NSDictionary *(NSDictionary *p) { return RMRefresh(p); }, @{
        @"description": @"Redraw ranged/colored marker overlays.",
        @"readOnly": @YES, @"pluginId": @"com.splicekit.ranged-markers", @"shortName": @"refresh"});
    sRegister(@"rangedMarkers.debugMarkers", ^NSDictionary *(NSDictionary *p) { return RMDebugMarkers(p); }, @{
        @"description": @"Development: each marker's clip, used range and available media.",
        @"readOnly": @YES, @"pluginId": @"com.splicekit.ranged-markers", @"shortName": @"debugMarkers"});
    sRegister(@"rangedMarkers.debugEditor", ^NSDictionary *(NSDictionary *p) { return RMDebugEditor(p); }, @{
        @"description": @"Development: view tree of the open marker editor.",
        @"readOnly": @YES, @"pluginId": @"com.splicekit.ranged-markers", @"shortName": @"debugEditor"});
    sRegister(@"rangedMarkers.debugLayers", ^NSDictionary *(NSDictionary *p) { return RMDebugLayers(p); }, @{
        @"description": @"Development: dump geometry of live timeline marker layers.",
        @"readOnly": @YES, @"pluginId": @"com.splicekit.ranged-markers", @"shortName": @"debugLayers"});
    sRegister(@"rangedMarkers.debugBrowser", ^NSDictionary *(NSDictionary *p) { return RMDebugBrowser(p); }, @{
        @"description": @"Development: dump browser filmstrip marker layers.",
        @"readOnly": @YES, @"pluginId": @"com.splicekit.ranged-markers", @"shortName": @"debugBrowser"});

    dispatch_async(dispatch_get_main_queue(), ^{
        RMInstallBrowserHooks();
        RMInstallHooks();
        RMInstallMoveHooks();
        RMInstallDeleteHook();
        RMInstallAddHooks();
        RMInstallUI();
        RMDiscoverBrowserMarkerLayers();
        RMRefreshAll();
    });
    NSLog(@"[RangedMarkers] loaded");
}

// Native plugin entry point (loaded at FCP launch from the plugins folder).
__attribute__((visibility("default"))) void SpliceKitPlugin_init(SpliceKitPluginAPI *api) { RMSetUp(); }

// Hot-load path (debug.loadPlugin): register immediately.
__attribute__((constructor)) static void RMConstructor(void) { RMSetUp(); }
