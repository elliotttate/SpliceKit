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

static void RMUpdateMarkerLayer(CALayer *layer) {
    @try {
        id marker = RMSend(layer, @"representedObject");
        CALayer *bar = RMSublayerNamed(layer, kBarLayerName);
        CALayer *tint = RMSublayerNamed(layer, kTintLayerName);
        if (!RMIsTimeMarker(marker)) { [bar removeFromSuperlayer]; [tint removeFromSuperlayer]; return; }

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
        id view = ranged ? RMTimelineView(layer) : nil;
        RMTime tpp;
        if (ranged && view && RMReadTime(view, @"timePerPixel", &tpp) && RMSeconds(tpp) > 0) {
            if (!bar) {
                bar = [CALayer layer];
                bar.name = kBarLayerName;
                bar.zPosition = -1;
                [layer addSublayer:bar];
            }
            // While the end handle is being dragged, the drag owns the width.
            CGFloat width = (layer == sDragLayer) ? sDragWidth : MAX(1.0, duration / RMSeconds(tpp));
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

static void RMRefreshAll(void) {
    id view = RMSend(sGetTimelineModule ? sGetTimelineModule() : nil, @"timelineView");
    if ([view isKindOfClass:[NSView class]]) RMVisitMarkerLayers([(NSView *)view layer], ^(CALayer *l) { RMUpdateMarkerLayer(l); });
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
    id selected = RMSend(sGetTimelineModule ? sGetTimelineModule() : nil, @"selectedItems");
    if ([selected respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) {
        for (id obj in selected) if (RMIsTimeMarker(obj)) return obj;
    }
    return nil;
}

// Undoable rename. The action lives on FFAnchoredSequence, not the timeline module.
static BOOL RMRename(id marker, NSString *name, NSError **err) {
    id sequence = RMActiveSequence();
    SEL sel = NSSelectorFromString(@"actionChangeMarkerDisplayName:marker:error:");
    if (![sequence respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(sequence, sel, name, marker, err);
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

        NSString *kind = params[@"kind"] ?: @"standard";
        int32_t ts = 24000;
        RMTime fd;
        if (RMReadTime(sequence, @"frameDuration", &fd)) ts = fd.timescale;
        double localStart = start + RMLocalOffset(sequence, item);
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
        NSError *err = nil;
        BOOL ok = ((BOOL (*)(id, SEL, id, BOOL, BOOL, RMTimeRange, NSError **))objc_msgSend)(
            sequence, addSel, item, [kind isEqualToString:@"todo"], [kind isEqualToString:@"chapter"], range, &err);
        if (!ok) return @{@"error": err.localizedDescription ?: @"FCP refused to add the marker"};

        id marker = nil;
        for (id m in RMMarkersOnItem(item)) if (![before containsObject:m]) marker = m;

        NSString *name = params[@"name"];
        NSString *color = [params[@"color"] lowercaseString];
        if (color.length && ![color isEqualToString:@"none"] && !RMPalette()[color]) {
            return @{@"error": [NSString stringWithFormat:@"Unknown color '%@'. Use one of: %@", color,
                                [[RMPalette().allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]]};
        }
        if (marker && (name.length || color.length || tagDuration > 0)) {
            NSString *base = name.length ? name : (RMSend(marker, @"displayName") ?: @"Marker");
            RMRename(marker, RMFormatName(base, color, tagDuration), NULL);
        }
        RMRefreshAll();
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
    return RMOnMain(^NSDictionary *{ RMRefreshAll(); return @{@"status": @"ok"}; });
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
    id sequence = RMActiveSequence();
    SEL sel = NSSelectorFromString(@"actionMoveMarker:toRange:error:");
    if (!sequence || ![sequence respondsToSelector:sel]) return NO;
    RMTime fd;
    if (!RMReadTime(sequence, @"frameDuration", &fd)) fd = (RMTime){1001, 24000, 1, 0};
    double frame = RMSeconds(fd);
    int64_t frames = MAX(1, llround(seconds / frame));
    double available = RMAvailableMedia(sequence, RMItemForMarker(sequence, marker), localStart);
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

static void RMInstallMoveHooks(void) {
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
    if (!sAddingMarker || ![markers isKindOfClass:[NSSet class]]) return markers;
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

static void RMInstallAddHooks(void) {
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
static id RMMarkerNearPlayhead(BOOL beforePlayhead) {
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
            double duration = 0;
            RMIsRanged(m, &duration);
            BOOL matches = beforePlayhead ? start <= playhead + frame / 2
                                          : start <= playhead + frame / 2 && playhead < start + MAX(duration, frame);
            if (matches && start > bestStart) { best = m; bestStart = start; }
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
    id sequence = RMActiveSequence();
    double start = marker ? RMMarkerSequenceStart(sequence, marker) : -1;
    double playhead = RMPlayheadSeconds();
    if (start < 0 || playhead <= start + RMFrameSeconds(sequence) || !RMSetMarkerDuration(marker, playhead - start)) NSBeep();
}

static void RMActUseInOut(id self, SEL _cmd, NSMenuItem *sender) {
    id marker = RMMenuMarker(sender);
    id sequence = RMActiveSequence();
    id item = marker ? RMItemForMarker(sequence, marker) : nil;
    double start, duration;
    RMTime anchor, fd;
    if (!item || !RMInOutRange(&start, &duration) || !RMReadTime(marker, @"targetAnchorTime", &anchor)) { NSBeep(); return; }
    int32_t ts = RMReadTime(sequence, @"frameDuration", &fd) ? fd.timescale : anchor.timescale;
    if (!RMMoveMarker(marker, RMMakeTime(start + RMLocalOffset(sequence, item), ts), duration)) NSBeep();
}

static void RMActRemoveRange(id self, SEL _cmd, NSMenuItem *sender) {
    id marker = RMMenuMarker(sender);
    if (!marker || !RMSetMarkerDuration(marker, RMFrameSeconds(RMActiveSequence()))) NSBeep();
}

static NSDictionary *RMAdd(NSDictionary *params);

// Mark > Markers > Add Ranged Marker: the in/out range if set, else 5s from the playhead.
static void RMActAddRanged(id self, SEL _cmd, NSMenuItem *sender) {
    double start, duration;
    if (!RMInOutRange(&start, &duration)) {
        start = RMPlayheadSeconds();
        duration = 5.0;
    }
    NSDictionary *r = RMAdd(@{@"start": @(start), @"duration": @(duration)});
    if (r[@"error"]) { NSLog(@"[RangedMarkers] %@", r[@"error"]); NSBeep(); }
}

static BOOL RMValidateMenuItem(id self, SEL _cmd, NSMenuItem *item) {
    if (item.action == NSSelectorFromString(@"rmAddRanged:")) return RMActiveSequence() != nil;
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

#pragma mark - Dragging the range end

static id sDragMarker;
static CGFloat sDragStartX, sDragStartWidth;
static double sDragTPP, sDragFrame;
static NSString *const kLabelLayerName = @"skRangedMarkerLabel";

static NSView *RMActiveTimelineView(void) {
    id view = RMSend(sGetTimelineModule ? sGetTimelineModule() : nil, @"timelineView");
    return [view isKindOfClass:[NSView class]] ? view : nil;
}

// Marker layer whose range handle is under the event, if any.
static CALayer *RMHandleHit(NSEvent *event, NSView *view, CGFloat *viewX) {
    if (!view || event.window != view.window) return nil;
    NSPoint p = [view convertPoint:event.locationInWindow fromView:nil];
    if (viewX) *viewX = p.x;
    __block CALayer *hit = nil;
    RMVisitMarkerLayers(view.layer, ^(CALayer *layer) {
        CALayer *bar = hit ? nil : RMSublayerNamed(layer, kBarLayerName);
        if (!bar) return;
        CGPoint lp = [view.layer convertPoint:p toLayer:bar];
        CGSize size = bar.bounds.size;
        if (lp.x >= size.width - 7 && lp.x <= size.width + 5 && lp.y >= -6 && lp.y <= size.height + 6) hit = layer;
    });
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

static void (*sOrigMouseDown)(id, SEL, NSEvent *);
static void (*sOrigMouseDragged)(id, SEL, NSEvent *);
static void (*sOrigMouseUp)(id, SEL, NSEvent *);
static void (*sOrigMouseMoved)(id, SEL, NSEvent *);

static void RMMouseDown(id self, SEL _cmd, NSEvent *event) {
    @try {
        NSView *view = RMActiveTimelineView();
        CGFloat x = 0;
        CALayer *layer = (event.clickCount == 1) ? RMHandleHit(event, view, &x) : nil;
        id marker = RMSend(layer, @"representedObject");
        RMTime tpp;
        if (layer && RMIsTimeMarker(marker) && RMReadTime(view, @"timePerPixel", &tpp)) {
            sDragLayer = layer;
            sDragMarker = marker;
            sDragStartX = x;
            sDragStartWidth = sDragWidth = RMSublayerNamed(layer, kBarLayerName).bounds.size.width;
            sDragTPP = RMSeconds(tpp);
            sDragFrame = RMFrameSeconds(marker);
            [[NSCursor resizeLeftRightCursor] set];
            return; // swallow: FCP must not start its own marker drag
        }
    } @catch (NSException *e) {
        sDragLayer = nil;
    }
    sOrigMouseDown(self, _cmd, event);
}

static void RMMouseDragged(id self, SEL _cmd, NSEvent *event) {
    if (!sDragLayer) { sOrigMouseDragged(self, _cmd, event); return; }
    NSView *view = RMActiveTimelineView();
    CGFloat x = [view convertPoint:event.locationInWindow fromView:nil].x;
    double seconds = MAX(2, llround((sDragStartWidth + (x - sDragStartX)) * sDragTPP / sDragFrame)) * sDragFrame;
    sDragWidth = seconds / sDragTPP;
    RMUpdateMarkerLayer(sDragLayer);
    CALayer *bar = RMSublayerNamed(sDragLayer, kBarLayerName);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    RMShowDragLabel(bar, seconds);
    [CATransaction commit];
    [[NSCursor resizeLeftRightCursor] set];
}

static void RMMouseUp(id self, SEL _cmd, NSEvent *event) {
    if (!sDragLayer) { sOrigMouseUp(self, _cmd, event); return; }
    CALayer *layer = sDragLayer;
    id marker = sDragMarker;
    double seconds = sDragWidth * sDragTPP;
    BOOL changed = fabs(sDragWidth - sDragStartWidth) >= 0.5;
    sDragLayer = nil;
    sDragMarker = nil;
    [RMSublayerNamed(RMSublayerNamed(layer, kBarLayerName), kLabelLayerName) removeFromSuperlayer];
    if (changed) RMSetMarkerDuration(marker, seconds);
    RMUpdateMarkerLayer(layer);
    [[NSCursor arrowCursor] set];
}

static void RMMouseMoved(id self, SEL _cmd, NSEvent *event) {
    sOrigMouseMoved(self, _cmd, event);
    @try {
        if (!sDragLayer && RMHandleHit(event, RMActiveTimelineView(), NULL)) [[NSCursor resizeLeftRightCursor] set];
    } @catch (NSException *e) {}
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

    NSTextField *hint = [NSTextField labelWithString:@"Empty = no range"];
    hint.font = [NSFont systemFontOfSize:10];
    hint.textColor = NSColor.tertiaryLabelColor;
    hint.frame = NSMakeRect(NSMaxX(field.frame) + 8, rowY + 5, 140, 14);
    hint.tag = kMenuTag;

    [view addSubview:label];
    [view addSubview:field];
    [view addSubview:hint];
    objc_setAssociatedObject(editor, kDurationFieldKey, field, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(field, kDurationEditorKey, editor, OBJC_ASSOCIATION_ASSIGN);

    // Grow the editor and its popover by one row.
    NSSize size = view.frame.size;
    size.height += kDurationRowHeight;
    [view setFrameSize:size];
    NSPopover *popover = nil;
    @try { popover = [view.window valueForKey:@"_popover"]; } @catch (NSException *e) {}
    if ([popover isKindOfClass:[NSPopover class]]) {
        NSSize content = popover.contentSize;
        content.height += kDurationRowHeight;
        popover.contentSize = content;
    } else if (view.window) {
        NSRect frame = view.window.frame;
        frame.size.height += kDurationRowHeight;
        [view.window setFrame:frame display:YES];
    }
    RMRefreshDurationField(editor);
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

    dispatch_async(dispatch_get_main_queue(), ^{
        RMInstallHooks();
        RMInstallMoveHooks();
        RMInstallDeleteHook();
        RMInstallAddHooks();
        RMInstallUI();
        RMRefreshAll();
    });
    NSLog(@"[RangedMarkers] loaded");
}

// Native plugin entry point (loaded at FCP launch from the plugins folder).
__attribute__((visibility("default"))) void SpliceKitPlugin_init(SpliceKitPluginAPI *api) { RMSetUp(); }

// Hot-load path (debug.loadPlugin): register immediately.
__attribute__((constructor)) static void RMConstructor(void) { RMSetUp(); }
