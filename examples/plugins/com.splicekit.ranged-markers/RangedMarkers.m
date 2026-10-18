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

// "[Red] Fix audio" -> color "red", title "Fix audio". Unknown tags are left alone.
static NSString *RMParseColorTag(NSString *name, NSString **titleOut) {
    if (titleOut) *titleOut = name ?: @"";
    if (![name hasPrefix:@"["]) return nil;
    NSRange close = [name rangeOfString:@"]"];
    if (close.location == NSNotFound || close.location < 2) return nil;
    NSString *tag = [[name substringWithRange:NSMakeRange(1, close.location - 1)] lowercaseString];
    if (!RMPalette()[tag]) return nil;
    if (titleOut) {
        *titleOut = [[name substringFromIndex:close.location + 1]
                     stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return tag;
}

static NSString *RMNameWithColor(NSString *name, NSString *color) {
    NSString *title = nil;
    RMParseColorTag(name, &title);
    if (!color.length || [color isEqualToString:@"none"]) return title;
    NSString *cap = [[[color substringToIndex:1] uppercaseString] stringByAppendingString:[color substringFromIndex:1]];
    return title.length ? [NSString stringWithFormat:@"[%@] %@", cap, title] : [NSString stringWithFormat:@"[%@]", cap];
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

// FCP's own one-frame markers are 1/48000s long, ours are >= 2 frames.
static BOOL RMIsRanged(id marker, double *durationOut) {
    RMTime d;
    if (!RMReadTime(marker, @"duration", &d)) return NO;
    double secs = RMSeconds(d);
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
        RMTimeRange range = { RMMakeTime(localStart, ts), RMMakeTime(duration, ts) };

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
        if (marker && (name.length || color.length)) {
            NSString *base = name.length ? name : (RMSend(marker, @"displayName") ?: @"Marker");
            RMRename(marker, RMNameWithColor(base, color), NULL);
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

// Undoable range change via -[FFAnchoredSequence actionMoveMarker:toRange:error:].
// localStart is in the marker's clip-local time; duration is snapped to whole frames.
static BOOL RMMoveMarker(id marker, RMTime localStart, double seconds) {
    id sequence = RMActiveSequence();
    SEL sel = NSSelectorFromString(@"actionMoveMarker:toRange:error:");
    if (!sequence || ![sequence respondsToSelector:sel]) return NO;
    RMTime fd;
    if (!RMReadTime(sequence, @"frameDuration", &fd)) fd = (RMTime){1001, 24000, 1, 0};
    int64_t frames = MAX(1, llround(seconds / RMSeconds(fd)));
    RMTimeRange range = { localStart, { fd.value * frames, fd.timescale, 1, 0 } };
    NSError *err = nil;
    BOOL ok = ((BOOL (*)(id, SEL, id, RMTimeRange, NSError **))objc_msgSend)(sequence, sel, marker, range, &err);
    if (!ok) NSLog(@"[RangedMarkers] move failed: %@", err.localizedDescription);
    RMRefreshAll();
    return ok;
}

static BOOL RMSetMarkerDuration(id marker, double seconds) {
    RMTime anchor;
    return RMReadTime(marker, @"targetAnchorTime", &anchor) && RMMoveMarker(marker, anchor, seconds);
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
    sRegister(@"rangedMarkers.debugLayers", ^NSDictionary *(NSDictionary *p) { return RMDebugLayers(p); }, @{
        @"description": @"Development: dump geometry of live timeline marker layers.",
        @"readOnly": @YES, @"pluginId": @"com.splicekit.ranged-markers", @"shortName": @"debugLayers"});

    dispatch_async(dispatch_get_main_queue(), ^{
        RMInstallHooks();
        RMInstallUI();
        RMRefreshAll();
    });
    NSLog(@"[RangedMarkers] loaded");
}

// Native plugin entry point (loaded at FCP launch from the plugins folder).
__attribute__((visibility("default"))) void SpliceKitPlugin_init(SpliceKitPluginAPI *api) { RMSetUp(); }

// Hot-load path (debug.loadPlugin): register immediately.
__attribute__((constructor)) static void RMConstructor(void) { RMSetUp(); }
