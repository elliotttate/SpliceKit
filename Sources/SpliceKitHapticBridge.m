//
//  SpliceKitHapticBridge.m
//  Observe every haptic FCP fires and rebroadcast it as a JSON-RPC event so
//  external accessories (the Logitech MX Master 4 mouse, etc.) can deliver
//  matching tactile feedback alongside the built-in Force Touch trackpad click.
//
//  How FCP's haptic surface works
//  ------------------------------
//  Every haptic in FCP funnels through one helper in LunaKit
//  (LKPerformAlignmentFeedbackPatternNow), which calls
//      [[NSHapticFeedbackManager defaultPerformer]
//          performFeedbackPattern:NSHapticFeedbackPatternAlignment
//                 performanceTime:NSHapticFeedbackPerformanceTimeNow]
//  from exactly four sites:
//      • -[FFSnapGridOSC addDrawProperties:...]_block_invoke
//          → Viewer canvas snap (transform/crop/title handles crossing a guide)
//      • -[FFAnchoredTimelineModule _acceptDrop:onItem:dropTime:dropHighlight:error:]
//          → Title drag-into-timeline highlight snapping to a new alignment
//      • -[TLKDragEdgesHandler _moveEdgeByTimeOffset:]
//        -[TLKDragEdgesHandler _timeOffsetForMovingEdgeToPoint:]
//          → Trim/roll edge first hits a constraint (no-more-handles wall)
//      • -[FFTransportLongPressButton mouseDown:]_block_invoke
//          → Force Touch FF/RW transport button stepping to a new rate bucket
//
//  Strategy
//  --------
//  We swizzle every Objective-C class that conforms to
//  NSHapticFeedbackPerformer (in practice there's just one — the private class
//  returned by +defaultPerformer) so any haptic FCP fires runs through us
//  first. We capture the call stack with backtrace(3), classify the originating
//  FCP function via dladdr, broadcast a typed event over SpliceKit's existing
//  JSON-RPC notification channel, then forward to the original implementation
//  so the trackpad click still happens.
//
//  Hardware note
//  -------------
//  +[NSHapticFeedbackManager defaultPerformer] returns nil on Macs without a
//  Force Touch trackpad. In that case the swizzle never gets invoked because
//  LunaKit's helper short-circuits on the nil performer. Phase 1 therefore
//  requires a Force Touch trackpad to mirror events to the MX Master 4. (A
//  later pass could fishhook LKPerformAlignmentFeedbackPatternNow itself to
//  cover the no-trackpad case.)

#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <execinfo.h>
#import <dlfcn.h>

// Map of swizzled class -> original IMP, keyed by class pointer (NSValue).
static NSMutableDictionary<NSValue *, NSValue *> *sOriginalImps = nil;
static dispatch_queue_t sStateQueue = NULL;
static BOOL sHapticBridgeInstalled = NO;

// Throttle log spam during long drags (snap-grid haptics fire on every guide
// crossing). We always broadcast the event — this gates the per-event log.
static NSTimeInterval sLastLogTimestamp = 0;
static NSString *sLastLogEventName = nil;

// Thread-local override used by SpliceKit_emitHaptic. When set, the swizzle
// uses this name verbatim instead of running its dladdr classifier — that's
// how "we fired this haptic ourselves" is distinguished from "FCP fired it
// natively". The override is set immediately before the AppKit call and
// cleared in the swizzle, so it's only ever live for the duration of one
// performFeedbackPattern: invocation on one thread.
static __thread const char *sEmitOverrideName = NULL;

// Match the actual FCP call site against a friendly event name so subscribers
// (the Logi plugin, primarily) can pick a distinct waveform per kind of haptic.
// Returns NULL if no caller matched — broadcast still happens with name="unknown".
static NSString *SK_haptic_classifyCallerSymbol(const char *symbol) {
    if (!symbol) return nil;
    NSString *sym = @(symbol);
    // Order matters: more specific patterns first. The FFAnchoredTimelineModule
    // method is keyed by `_acceptDrop` to avoid matching unrelated TLM swizzles.
    if ([sym containsString:@"FFSnapGridOSC"]) {
        return @"viewer_snap";
    }
    if ([sym containsString:@"FFAnchoredTimelineModule"] && [sym containsString:@"_acceptDrop"]) {
        return @"title_drop_snap";
    }
    if ([sym containsString:@"TLKDragEdgesHandler"]) {
        return @"trim_limit";
    }
    if ([sym containsString:@"FFTransportLongPressButton"]) {
        return @"jkl_pressure";
    }
    return nil;
}

// Walk a captured backtrace looking for a recognized FCP caller. Skips our
// own swizzle frame and the LunaKit helper thunk (LKPerformAlignmentFeedback…).
// Returns the matched event name and (out-param) the raw symbol string for
// diagnostics. If nothing matches we fall back to the most-distant-from-us
// symbol and label it "unknown".
static NSString *SK_haptic_eventNameFromBacktrace(void **frames, int n,
                                                   NSString **outRawSymbol) {
    NSString *firstUnknownSymbol = nil;
    for (int i = 0; i < n; i++) {
        Dl_info info;
        if (dladdr(frames[i], &info) == 0 || info.dli_sname == NULL) continue;
        NSString *sym = @(info.dli_sname);
        // Skip our own swizzle frame and the LunaKit helper itself; we want
        // the FCP-level caller that decided to fire this haptic.
        if ([sym hasPrefix:@"SK_haptic_"]) continue;
        if ([sym containsString:@"LKPerformAlignmentFeedback"]) continue;

        NSString *match = SK_haptic_classifyCallerSymbol(info.dli_sname);
        if (match) {
            if (outRawSymbol) *outRawSymbol = sym;
            return match;
        }
        if (!firstUnknownSymbol) firstUnknownSymbol = sym;
    }
    if (outRawSymbol) *outRawSymbol = firstUnknownSymbol;
    return @"unknown";
}

// Replacement IMP for -[<NSHapticFeedbackPerformer> performFeedbackPattern:performanceTime:].
// Signature: -(void)performFeedbackPattern:(NSHapticFeedbackPattern)pattern
//                          performanceTime:(NSHapticFeedbackPerformanceTime)time;
static void SK_haptic_swizzledPerform(id self, SEL _cmd,
                                       NSHapticFeedbackPattern pattern,
                                       NSHapticFeedbackPerformanceTime time) {
    NSString *rawSymbol = nil;
    NSString *eventName;
    if (sEmitOverrideName) {
        // Self-emitted: the caller already named this event. Skip the dladdr
        // classifier entirely so we don't have to teach it about every
        // SpliceKit emitter symbol. Free the buffer that SpliceKit_emitHaptic
        // strdup'd before clearing the slot — keeping ownership here keeps
        // the emitter call site simple.
        const char *taken = sEmitOverrideName;
        sEmitOverrideName = NULL;
        eventName = @(taken);
        free((void *)taken);
        rawSymbol = @"<self-emitted>";
    } else {
        void *frames[12];
        int n = backtrace(frames, 12);
        eventName = SK_haptic_eventNameFromBacktrace(frames, n, &rawSymbol);
    }

    NSDictionary *event = @{
        @"type": @"haptic",
        @"name": eventName,
        @"pattern": @(pattern),
        @"performance_time": @(time),
        @"caller_symbol": rawSymbol ?: @"",
    };
    SpliceKit_broadcastEvent(event);

    // Throttled log: at most one line per second per event name. The viewer
    // snap path can fire tens of times during a single drag.
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (![sLastLogEventName isEqualToString:eventName] || (now - sLastLogTimestamp) > 1.0) {
        sLastLogTimestamp = now;
        sLastLogEventName = eventName;
        SpliceKit_log(@"[HapticBridge] haptic '%@' (caller=%@)", eventName, rawSymbol ?: @"<unknown>");
    }

    // Forward to the original so the Force Touch trackpad still fires.
    Class cls = object_getClass(self);
    __block IMP origImp = NULL;
    dispatch_sync(sStateQueue, ^{
        NSValue *box = sOriginalImps[[NSValue valueWithPointer:(__bridge const void *)cls]];
        if (box) origImp = (IMP)[box pointerValue];
    });
    if (origImp) {
        ((void (*)(id, SEL, NSHapticFeedbackPattern, NSHapticFeedbackPerformanceTime))origImp)(
            self, _cmd, pattern, time);
    }
}

// Locate every loaded ObjC class that conforms to NSHapticFeedbackPerformer
// and swizzle its instance method. In practice +defaultPerformer returns one
// concrete class on Force Touch hardware; iterating the runtime makes us
// resilient to AppKit reorganizing the implementation across macOS versions.
static NSUInteger SK_haptic_swizzleAllPerformerClasses(void) {
    Protocol *performerProtocol = objc_getProtocol("NSHapticFeedbackPerformer");
    if (!performerProtocol) {
        SpliceKit_log(@"[HapticBridge] NSHapticFeedbackPerformer protocol not found; AppKit not loaded?");
        return 0;
    }

    SEL targetSel = @selector(performFeedbackPattern:performanceTime:);
    unsigned int count = 0;
    Class *classList = objc_copyClassList(&count);
    if (!classList) return 0;

    NSUInteger swizzled = 0;
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classList[i];
        // class_conformsToProtocol only checks the immediate class, not the
        // chain. Walk up so subclasses of an internal performer are still hit.
        Class probe = cls;
        BOOL conforms = NO;
        while (probe) {
            if (class_conformsToProtocol(probe, performerProtocol)) {
                conforms = YES;
                break;
            }
            probe = class_getSuperclass(probe);
        }
        if (!conforms) continue;
        if (![cls instancesRespondToSelector:targetSel]) continue;

        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)cls];
        __block BOOL alreadySwizzled = NO;
        dispatch_sync(sStateQueue, ^{
            alreadySwizzled = (sOriginalImps[key] != nil);
        });
        if (alreadySwizzled) continue;

        IMP origImp = SpliceKit_swizzleMethod(cls, targetSel, (IMP)SK_haptic_swizzledPerform);
        if (!origImp) {
            SpliceKit_log(@"[HapticBridge] swizzle failed on %@", NSStringFromClass(cls));
            continue;
        }
        dispatch_sync(sStateQueue, ^{
            sOriginalImps[key] = [NSValue valueWithPointer:(const void *)origImp];
        });
        swizzled++;
        SpliceKit_log(@"[HapticBridge] swizzled %@ -performFeedbackPattern:performanceTime:",
                      NSStringFromClass(cls));
    }
    free(classList);
    return swizzled;
}

void SpliceKit_installHapticBridge(void) {
    if (sHapticBridgeInstalled) return;

    sStateQueue = dispatch_queue_create("com.splicekit.hapticbridge.state",
                                        DISPATCH_QUEUE_SERIAL);
    sOriginalImps = [NSMutableDictionary dictionary];

    NSUInteger n = SK_haptic_swizzleAllPerformerClasses();

    // Touching +defaultPerformer forces lazy concrete-class registration on
    // some macOS releases; if our first sweep missed because the performer
    // class wasn't loaded yet, a follow-up sweep catches it.
    if (n == 0) {
        Class managerCls = NSClassFromString(@"NSHapticFeedbackManager");
        if (managerCls) {
            id performer = ((id (*)(id, SEL))objc_msgSend)((id)managerCls, @selector(defaultPerformer));
            if (performer) {
                n = SK_haptic_swizzleAllPerformerClasses();
            }
        }
    }

    sHapticBridgeInstalled = YES;
    SpliceKit_log(@"[HapticBridge] installed: %lu performer class(es) swizzled — "
                  @"subscribe to type='haptic' over JSON-RPC to receive events",
                  (unsigned long)n);
}

void SpliceKit_emitHaptic(NSString *eventName) {
    if (!sHapticBridgeInstalled) return;
    if (eventName.length == 0) eventName = @"unknown";

    // +defaultPerformer can return nil on Macs without a Force Touch trackpad.
    // Even so, we still want the JSON-RPC broadcast so the MX Master 4 fires
    // — so cover the nil case by broadcasting directly and skipping AppKit.
    Class managerCls = NSClassFromString(@"NSHapticFeedbackManager");
    id performer = managerCls
        ? ((id (*)(id, SEL))objc_msgSend)((id)managerCls, @selector(defaultPerformer))
        : nil;
    if (!performer) {
        SpliceKit_broadcastEvent(@{
            @"type": @"haptic",
            @"name": eventName,
            @"pattern": @(NSHapticFeedbackPatternAlignment),
            @"performance_time": @(NSHapticFeedbackPerformanceTimeNow),
            @"caller_symbol": @"<self-emitted, no trackpad>",
        });
        return;
    }

    // Set the thread-local override; the swizzle clears it on entry, both
    // broadcasts the event and forwards to the original IMP so the trackpad
    // click fires once.
    sEmitOverrideName = strdup([eventName UTF8String]);
    @try {
        ((void (*)(id, SEL, NSHapticFeedbackPattern, NSHapticFeedbackPerformanceTime))objc_msgSend)(
            performer, @selector(performFeedbackPattern:performanceTime:),
            NSHapticFeedbackPatternAlignment,
            NSHapticFeedbackPerformanceTimeNow);
    } @finally {
        // The swizzle takes ownership of the strdup'd buffer by reading the
        // pointer into an NSString; we still need to free it here in case
        // the AppKit call somehow bypassed our swizzle (e.g. install was
        // partial and the live performer class wasn't covered).
        if (sEmitOverrideName) {
            // Buffer leaked from before the swizzle ran — clear and free.
            const char *stale = sEmitOverrideName;
            sEmitOverrideName = NULL;
            free((void *)stale);
        }
    }
}
