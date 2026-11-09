// grade lock part 2: locked clips ("lock" in name) are ignored by the
// playhead/skimmer implicit selection, so the inspector shows the clip below.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *GSName(id o) {
    @try {
        for (NSString *k in @[@"displayName", @"name"]) {
            if ([o respondsToSelector:NSSelectorFromString(k)]) {
                id v = [o valueForKey:k];
                if ([v isKindOfClass:[NSString class]]) return v;
            }
        }
    } @catch (__unused id e) {}
    return nil;
}
static BOOL GSLocked(id o) {
    NSString *n = GSName(o);
    return n && [n rangeOfString:@"lock" options:NSCaseInsensitiveSearch].location != NSNotFound;
}
static void GSLog(NSString *s) {
    FILE *f = fopen([[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/gradelock.log"] fileSystemRepresentation], "a");
    if (f) { fprintf(f, "%s\n", s.UTF8String); fclose(f); }
}
static NSString *GSDescribe(id c) {
    if (![c respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) return [NSString stringWithFormat:@"%@ %@", NSStringFromClass([c class]), GSName(c)];
    NSMutableArray *names = [NSMutableArray array];
    for (id o in c) [names addObject:[NSString stringWithFormat:@"%@:%@", NSStringFromClass([o class]), GSName(o) ?: @"?"]];
    return [NSString stringWithFormat:@"%@ [%@]", NSStringFromClass([c class]), [names componentsJoinedByString:@", "]];
}
static id GSFilter(id c, NSString *where) {
    if (([NSEvent modifierFlags] & NSEventModifierFlagOption) != 0) return c;
    if (!c) return c;
    if (![c respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) {
        if (GSLocked(c)) { GSLog([NSString stringWithFormat:@"%@: hid single %@", where, GSName(c)]); return nil; }
        return c;
    }
    NSMutableArray *keep = [NSMutableArray array]; NSUInteger dropped = 0;
    for (id o in c) { if (GSLocked(o)) dropped++; else [keep addObject:o]; }
    if (!dropped) return c;
    static int logged = 0;
    if (logged++ < 40) GSLog([NSString stringWithFormat:@"%@: in=%@ kept=%lu", where, GSDescribe(c), (unsigned long)keep.count]);
    if ([c isKindOfClass:[NSSet class]]) return [NSSet setWithArray:keep];
    if ([c isKindOfClass:[NSOrderedSet class]]) return [NSOrderedSet orderedSetWithArray:keep];
    return keep;
}


#import <dlfcn.h>
static IMP gInspUpdate = NULL;
static id GSReplacementBelow(void) {
    static id (*getModule)(void) = NULL;
    if (!getModule) getModule = (id(*)(void))dlsym(RTLD_DEFAULT, "_Z33SpliceKit_getActiveTimelineModulev");
    id module = getModule ? getModule() : nil;
    if (!module) { GSLog(@"insp: no timeline module"); return nil; }
    CMTime t = kCMTimeInvalid;
    SEL skimSel = NSSelectorFromString(@"skimmingTime"), phSel = NSSelectorFromString(@"playheadTime");
    if ([module respondsToSelector:skimSel]) t = ((CMTime(*)(id, SEL))objc_msgSend)(module, skimSel);
    if (!CMTIME_IS_VALID(t) && [module respondsToSelector:phSel]) t = ((CMTime(*)(id, SEL))objc_msgSend)(module, phSel);
    if (!CMTIME_IS_VALID(t)) return nil;
    SEL visSel = NSSelectorFromString(@"_visibleItemsAtPlayhead:includeTransitions:includeAll:");
    id items = ((id(*)(id, SEL, CMTime, BOOL, BOOL))objc_msgSend)(module, visSel, t, NO, YES);
    id best = nil; long bestLane = -1000;
    for (id o in items) {
        if (GSLocked(o)) continue;
        long lane = 0;
        if ([o respondsToSelector:NSSelectorFromString(@"anchoredLane")]) lane = ((long(*)(id, SEL))objc_msgSend)(o, NSSelectorFromString(@"anchoredLane"));
        if (lane < 0) continue; // audio below the storyline
        if (!best || lane > bestLane) { best = o; bestLane = lane; }
    }
    return best;
}
static void GSInspUpdate(id self, SEL _cmd, id items) {
    id use = items;
    if (([NSEvent modifierFlags] & NSEventModifierFlagOption) == 0 && [items respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) {
        NSUInteger total = 0, locked = 0;
        for (id o in items) { total++; if (GSLocked(o)) locked++; }
        if (locked) {
            NSMutableArray *keep = [NSMutableArray array];
            for (id o in items) if (!GSLocked(o)) [keep addObject:o];
            if (keep.count == 0) { id below = GSReplacementBelow(); if (below) [keep addObject:below]; }
            static int n = 0;
            if (n++ < 30) GSLog([NSString stringWithFormat:@"insp: %@ -> %lu item(s) %@", GSDescribe(items), (unsigned long)keep.count, keep.count ? GSName(keep[0]) : @""]);
            if ([items isKindOfClass:[NSSet class]]) use = [NSSet setWithArray:keep];
            else if ([items isKindOfClass:[NSOrderedSet class]]) use = [NSOrderedSet orderedSetWithArray:keep];
            else use = keep;
        }
    }
    ((void(*)(id, SEL, id))gInspUpdate)(self, _cmd, use);
}

static IMP gImplicit = NULL, gTargets = NULL, gVisible = NULL;
static id GSImplicit(id self, SEL _cmd, id container, CMTime t) {
    id r = ((id(*)(id, SEL, id, CMTime))gImplicit)(self, _cmd, container, t);
    return GSFilter(r, @"implicit");
}
static id GSTargets(id self, SEL _cmd, CMTime *tOut, BOOL *isSpine, id container) {
    id r = ((id(*)(id, SEL, CMTime *, BOOL *, id))gTargets)(self, _cmd, tOut, isSpine, container);
    return GSFilter(r, @"targets");
}
static id GSVisible(id self, SEL _cmd, CMTime t, BOOL inclTrans, BOOL inclAll) {
    id r = ((id(*)(id, SEL, CMTime, BOOL, BOOL))gVisible)(self, _cmd, t, inclTrans, inclAll);
    return GSFilter(r, @"visible");
}
static void GSHook(Class c, NSString *sel, IMP repl, IMP *orig) {
    Method m = class_getInstanceMethod(c, NSSelectorFromString(sel));
    if (!m) { GSLog([NSString stringWithFormat:@"skim init: missing %@", sel]); return; }
    *orig = method_setImplementation(m, repl);
}
__attribute__((constructor)) static void GSInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class c = objc_getClass("FFAnchoredTimelineModule");
        if (!c) { GSLog(@"skim init: no module class"); return; }
        GSHook(c, @"_implicitSelectionSetFullForContainer:containerPlayheadTime:", (IMP)GSImplicit, &gImplicit);
        GSHook(c, @"getTargetsUnderSkimmerOrPlayhead:isSpine:container:", (IMP)GSTargets, &gTargets);
        GSHook(c, @"_visibleItemsAtPlayhead:includeTransitions:includeAll:", (IMP)GSVisible, &gVisible);
        Class ic = objc_getClass("PEInspectorContainerModule");
        if (ic) GSHook(ic, @"_updateInspectorWithItems:", (IMP)GSInspUpdate, &gInspUpdate);
        GSLog(@"skim init: active (v2)");
    });
}
__attribute__((visibility("default"))) void SpliceKitPlugin_init(void *api) { (void)api; }
