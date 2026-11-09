// paste below lock (v5): pasted clips go under locked adjustment layers ("lock" in the name) -
// except locks the clip sat above where it was copied from, which it may stay above.
//  - on copy/cut we note, for each copied connected clip, which overlapping locks it sat above
//  - after Final Cut pastes, a new connected clip that landed above an overlapping lock and did NOT
//    come from above a lock is moved to the row right on top of the unlocked clips under the lock.
//    Only if there is no free row under the lock is the lock (and everything stacked on it) lifted
//    one row, so the stacking order of everything else stays exactly as it was.
//  - done inside Final Cut's own Paste action, so it is one undo step.
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void PL(NSString *s) {
    FILE *f = fopen([[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/pastefix.log"] fileSystemRepresentation], "a");
    if (f) { fprintf(f, "%s %s\n", [NSDate date].description.UTF8String, s.UTF8String); fclose(f); }
}
static id O(id o, NSString *s) {
    SEL sel = NSSelectorFromString(s);
    if (!o || ![o respondsToSelector:sel]) return nil;
    NSMethodSignature *g = [o methodSignatureForSelector:sel];
    if (!g || g.numberOfArguments != 2 || strcmp(g.methodReturnType, "@")) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(o, sel);
}
static long Lane(id o) { SEL s = NSSelectorFromString(@"anchoredLane"); return [o respondsToSelector:s] ? ((long(*)(id,SEL))objc_msgSend)(o, s) : 0; }
static void SetLane(id o, long l) { ((void(*)(id,SEL,long))objc_msgSend)(o, NSSelectorFromString(@"setAnchoredLane:"), l); }
static BOOL Locked(id o) {
    NSString *n = O(o, @"displayName");
    return [n isKindOfClass:[NSString class]] && [n rangeOfString:@"lock" options:NSCaseInsensitiveSearch].location != NSNotFound;
}
static CMTimeRange RangeIn(id o, id container) {
    SEL s = NSSelectorFromString(@"timeRangeInContainerSpace:");
    if (![o respondsToSelector:s]) return kCMTimeRangeInvalid;
    return ((CMTimeRange(*)(id,SEL,id))objc_msgSend)(o, s, container);
}
static BOOL Overlap(CMTimeRange a, CMTimeRange b) {
    if (!CMTIMERANGE_IS_VALID(a) || !CMTIMERANGE_IS_VALID(b)) return YES;   // unknown -> treat as overlapping
    CMTimeRange i = CMTimeRangeGetIntersection(a, b);
    return CMTIMERANGE_IS_VALID(i) && CMTimeCompare(i.duration, kCMTimeZero) > 0;
}
static id ActiveModule(void) { return O(O([NSApp delegate], @"activeEditorContainer"), @"timelineModule"); }
// connected clips/storylines only: markers (lane 999999), captions etc. are never part of the stacking
static BOOL IsLayer(id x) {
    long l = Lane(x);
    if (l == 0 || l > 100000 || l < -100000) return NO;
    NSString *c = NSStringFromClass([x class]);
    return [c rangeOfString:@"Marker"].location == NSNotFound && [c rangeOfString:@"Caption"].location == NSNotFound;
}
static NSArray *AnchoredItems(id prim) {
    NSMutableArray *a = [NSMutableArray array];
    for (id item in (NSArray *)O(prim, @"containedItems"))
        for (id x in (NSSet *)O(item, @"anchoredItems")) if (IsLayer(x)) [a addObject:x];
    return a;
}
static NSSet *Snapshot(void) {
    NSMutableSet *s = [NSMutableSet set];
    for (id x in AnchoredItems(O(O(ActiveModule(), @"sequence"), @"primaryObject"))) [s addObject:[NSValue valueWithNonretainedObject:x]];
    return s;
}

// what was copied: "name|duration" -> above a lock at the source (NSNumber), valid while the pasteboard is unchanged
static NSMutableDictionary *gCopied; static NSInteger gCopyChange = -1;
static NSString *Key(id o) {
    SEL s = NSSelectorFromString(@"duration");
    double d = 0;
    if ([o respondsToSelector:s] && [o methodSignatureForSelector:s].methodReturnType[0] == '{') d = CMTimeGetSeconds(((CMTime(*)(id,SEL))objc_msgSend)(o, s));
    return [NSString stringWithFormat:@"%@|%.3f", O(o, @"displayName"), d];
}
// the locked layers a clip sat above where it was copied from (by name)
static NSSet *LocksBelow(id x, id prim, NSArray *all) {
    NSMutableSet *s = [NSMutableSet set];
    long lane = Lane(x); if (lane <= 0) return s;
    CMTimeRange r = RangeIn(x, prim);
    for (id l in all) if (l != x && Locked(l) && Lane(l) > 0 && Lane(l) < lane && Overlap(r, RangeIn(l, prim))) [s addObject:O(l, @"displayName") ?: @""];
    return s;
}
static void NoteCopy(id tm) {
    @try {
        id prim = O(O(tm, @"sequence"), @"primaryObject");
        NSArray *sel = ((id(*)(id,SEL,BOOL,BOOL))objc_msgSend)(tm, NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:"), NO, NO);
        NSArray *all = AnchoredItems(prim);
        gCopied = [NSMutableDictionary dictionary];
        for (id x in sel) {
            NSSet *below = LocksBelow(x, prim, all);
            NSString *k = Key(x);
            if (below.count || !gCopied[k]) gCopied[k] = below;
        }
        gCopyChange = -2;   // filled in after Final Cut writes the pasteboard
        dispatch_async(dispatch_get_main_queue(), ^{ gCopyChange = [NSPasteboard generalPasteboard].changeCount; });
        PL([NSString stringWithFormat:@"copy noted: %@", gCopied]);
    } @catch (id e) { PL([NSString stringWithFormat:@"note copy threw %@", e]); gCopied = nil; }
}
static NSSet *SourceLocksBelow(id n) {
    if (!gCopied || (gCopyChange != -2 && gCopyChange != [NSPasteboard generalPasteboard].changeCount)) return [NSSet set];
    return gCopied[Key(n)] ?: [NSSet set];
}

static BOOL FixAfterPaste(NSSet *before, BOOL ownAction) {
    @try {
        id seq = O(ActiveModule(), @"sequence");
        id prim = O(seq, @"primaryObject");
        if (!seq || !prim) return NO;
        NSArray *all = AnchoredItems(prim);
        NSMutableArray *added = [NSMutableArray array]; BOOL anyLock = NO;
        for (id x in all) {
            if (Locked(x)) { if (Lane(x) > 0) anyLock = YES; continue; }
            if (![before containsObject:[NSValue valueWithNonretainedObject:x]] && Lane(x) > 0) [added addObject:x];
        }
        if (!added.count) return NO;
        if (!anyLock) return YES;
        [added sortUsingComparator:^NSComparisonResult(id a, id b) { return Lane(a) < Lane(b) ? NSOrderedAscending : Lane(a) > Lane(b) ? NSOrderedDescending : NSOrderedSame; }];
        BOOL began = NO;
        for (id n in added) {
            CMTimeRange r = RangeIn(n, prim);
            // keep the clip's relation to each lock as it was where it was copied from: it may stay above the
            // locks it sat above there, and goes under the lowest overlapping lock it was NOT above
            NSSet *wasAbove = SourceLocksBelow(n);
            long L = LONG_MAX;
            for (id l in all) if (Locked(l) && Lane(l) > 0 && Overlap(r, RangeIn(l, prim)) && ![wasAbove containsObject:O(l, @"displayName") ?: @""]) L = MIN(L, Lane(l));
            if (L == LONG_MAX || Lane(n) < L) { if (wasAbove.count) PL([NSString stringWithFormat:@"'%@' kept on lane %ld (was above %@)", O(n, @"displayName"), Lane(n), [wasAbove.allObjects componentsJoinedByString:@", "]]); continue; }
            if (!began && ownAction) {
                ((void(*)(id,SEL,id,id,BOOL))objc_msgSend)(seq, NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:"), @"Paste", nil, NO);
                began = YES;
            }
            long from = Lane(n), top = 0;
            for (id o in all) if (o != n && Lane(o) > 0 && Lane(o) < L && Overlap(r, RangeIn(o, prim))) top = MAX(top, Lane(o));
            long target = top + 1;
            if (target < L) { SetLane(n, target); PL([NSString stringWithFormat:@"pasted '%@' lane %ld -> %ld (free row under the lock on lane %ld)", O(n, @"displayName"), from, target, L]); continue; }
            // no free row under the lock: push up only what is actually in the way - starting with whatever
            // sits on the lock's row where the clip goes, then whatever that lands on, and so on (a cascade),
            // so every clip keeps its place in the stack and no empty rows are left behind
            NSMutableArray *lift = [NSMutableArray array];
            NSMutableArray *incoming = [NSMutableArray arrayWithObject:[NSValue valueWithBytes:&r objCType:@encode(CMTimeRange)]];
            for (long k = L; incoming.count && k < L + 1000; k++) {
                NSMutableArray *next = [NSMutableArray array];
                for (id o in all) {
                    if (o == n || Lane(o) != k) continue;
                    CMTimeRange ro = RangeIn(o, prim);
                    for (NSValue *v in incoming) {
                        CMTimeRange vr; [v getValue:&vr size:sizeof vr];
                        if (Overlap(ro, vr)) { [lift addObject:o]; [next addObject:[NSValue valueWithBytes:&ro objCType:@encode(CMTimeRange)]]; break; }
                    }
                }
                incoming = next;
            }
            for (id o in lift) SetLane(o, Lane(o) + 1);
            SetLane(n, L);
            PL([NSString stringWithFormat:@"pasted '%@' lane %ld -> %ld (under lock on lane %ld; lifted %lu item(s) above it one row)", O(n, @"displayName"), from, L, L, (unsigned long)lift.count]);
        }
        if (began) {
            NSError *err = nil;
            BOOL ok = ((BOOL(*)(id,SEL,id,BOOL,NSError **))objc_msgSend)(seq, NSSelectorFromString(@"actionEnd:save:error:"), @"Paste", YES, &err);
            if (!ok) PL([NSString stringWithFormat:@"actionEnd failed %@", err]);
        }
        return YES;
    } @catch (id e) { PL([NSString stringWithFormat:@"fix threw %@", e]); return YES; }
}
static void Watch(NSSet *before, int tries) {
    // the paste may finish after a settings sheet; look for the new clips for up to ~3 seconds
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!FixAfterPaste(before, YES) && tries > 0) Watch(before, tries - 1);
    });
}

static IMP o_paste, o_pasteAnchored, o_actionEnd, o_copy, o_cut;
static NSSet *gBefore; static BOOL gPasting, gHandled;
// fcp's paste runs inside its own model action; we adjust the lanes just before that action closes,
// so the move below the locks is part of the same undo step as the paste itself.
static BOOL h_actionEnd(id self, SEL _cmd, id name, BOOL save, NSError **err) {
    if (gPasting && !gHandled && gBefore && self == O(ActiveModule(), @"sequence")) {
        @try { if (FixAfterPaste(gBefore, NO)) gHandled = YES; } @catch (id e) { PL([NSString stringWithFormat:@"in-action fix threw %@", e]); gHandled = YES; }
    }
    return ((BOOL(*)(id,SEL,id,BOOL,NSError **))o_actionEnd)(self, _cmd, name, save, err);
}
static void PasteWrapped(id self, SEL _cmd, id sender, IMP orig) {
    NSSet *before = Snapshot();
    gBefore = before; gPasting = YES; gHandled = NO;
    @try { ((void(*)(id,SEL,id))orig)(self, _cmd, sender); }
    @finally { gPasting = NO; gBefore = nil; }
    if (!gHandled) Watch(before, 20);   // paste finished outside that action (e.g. after a settings sheet): fix as its own step
}
static void h_paste(id self, SEL _cmd, id sender) { PasteWrapped(self, _cmd, sender, o_paste); }
static void h_pasteAnchored(id self, SEL _cmd, id sender) { PasteWrapped(self, _cmd, sender, o_pasteAnchored); }
static void h_copy(id self, SEL _cmd, id sender) { NoteCopy(self); ((void(*)(id,SEL,id))o_copy)(self, _cmd, sender); }
static void h_cut(id self, SEL _cmd, id sender) { NoteCopy(self); ((void(*)(id,SEL,id))o_cut)(self, _cmd, sender); }
static void Install(void) {
    static BOOL done; if (done) return; done = YES;
    Class c = objc_getClass("FFAnchoredTimelineModule");
    Method m1 = class_getInstanceMethod(c, @selector(paste:));
    Method m2 = class_getInstanceMethod(c, NSSelectorFromString(@"pasteAnchored:"));
    if (m1) o_paste = method_setImplementation(m1, (IMP)h_paste);
    if (m2) o_pasteAnchored = method_setImplementation(m2, (IMP)h_pasteAnchored);
    Method m4 = class_getInstanceMethod(c, @selector(copy:)), m5 = class_getInstanceMethod(c, @selector(cut:));
    if (m4) o_copy = method_setImplementation(m4, (IMP)h_copy);
    if (m5) o_cut = method_setImplementation(m5, (IMP)h_cut);
    Method m3 = class_getInstanceMethod(objc_getClass("FFAnchoredSequence"), NSSelectorFromString(@"actionEnd:save:error:"));
    if (m3) o_actionEnd = method_setImplementation(m3, (IMP)h_actionEnd);
    PL([NSString stringWithFormat:@"paste below lock ready v5 (paste=%d anchored=%d actionEnd=%d copy=%d cut=%d)", o_paste != NULL, o_pasteAnchored != NULL, o_actionEnd != NULL, o_copy != NULL, o_cut != NULL]);
}
__attribute__((visibility("default"))) void SpliceKitPlugin_init(void *api) { (void)api; }
__attribute__((constructor)) static void ctor(void) { dispatch_async(dispatch_get_main_queue(), ^{ Install(); }); }
