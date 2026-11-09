// Topmost: "Edit Topmost Clip at Playhead" (View menu toggle + Command Editor command).
// While on, and only when nothing is selected, Blade (⌘B) and Copy (⌘C) act on the highest unlocked
// video clip under the skimmer/playhead instead of the primary storyline clip. Locked layers ("lock" in
// the name), audio-only clips, gaps, markers and captions are skipped. The edit itself is Final Cut's own
// blade:/copy: run on that clip (temporarily selected), so timing, connections and undo are native.
// A clip copied this way pastes (⌘V / ⌥V) as a connected clip at the playhead on the layer it came from,
// inside Final Cut's own Paste undo step. If that layer is taken at the playhead (by any clip, locked
// layers included) it goes to the next free layer. Paste Below Lock then keeps it under lock layers
// unless it was copied from above one.
// With nothing to target, or with the toggle off, everything is passed straight to Final Cut.
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kPrefKey = @"SpliceKitTopmostClipEditing";
static NSString *const kCmdID = @"SpliceKitToggleTopmostEditing";
static NSString *const kMenuTitle = @"Edit Topmost Clip at Playhead";

static void TL(NSString *fmt, ...) {
    va_list a; va_start(a, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a]; va_end(a);
    NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/topmost.log"];
    FILE *f = fopen(p.fileSystemRepresentation, "a");
    if (f) { fprintf(f, "%s %s\n", [NSDate date].description.UTF8String, s.UTF8String); fclose(f); }
}
static id O(id o, NSString *s) {
    SEL x = NSSelectorFromString(s);
    if (!o || ![o respondsToSelector:x]) return nil;
    NSMethodSignature *g = [o methodSignatureForSelector:x];
    if (!g || g.numberOfArguments != 2 || strcmp(g.methodReturnType, "@")) return nil;
    return ((id(*)(id, SEL))objc_msgSend)(o, x);
}
static BOOL OB(id o, NSString *s) { SEL x = NSSelectorFromString(s); return (o && [o respondsToSelector:x]) ? ((BOOL(*)(id, SEL))objc_msgSend)(o, x) : NO; }
static long Lane(id o) { SEL s = NSSelectorFromString(@"anchoredLane"); return [o respondsToSelector:s] ? ((long(*)(id, SEL))objc_msgSend)(o, s) : 0; }
static void SetLane(id o, long l) { ((void(*)(id, SEL, long))objc_msgSend)(o, NSSelectorFromString(@"setAnchoredLane:"), l); }
static CMTimeRange RangeIn(id o, id c) {
    SEL s = NSSelectorFromString(@"timeRangeInContainerSpace:");
    return [o respondsToSelector:s] ? ((CMTimeRange(*)(id, SEL, id))objc_msgSend)(o, s, c) : kCMTimeRangeInvalid;
}
static BOOL Locked(id o) {
    NSString *n = O(o, @"displayName");
    return [n isKindOfClass:[NSString class]] && [n rangeOfString:@"lock" options:NSCaseInsensitiveSearch].location != NSNotFound;
}
static BOOL Enabled(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kPrefKey];
    return v ? [v boolValue] : YES;
}
static id ActiveTM(void) { return O(O([NSApp delegate], @"activeEditorContainer"), @"timelineModule"); }

#pragma mark - finding the clip

// items that can never be a target: markers, keywords, captions, gaps, audio-only clips
static BOOL Skippable(id x) {
    NSString *c = NSStringFromClass([x class]);
    if ([c containsString:@"Marker"] || [c containsString:@"Keyword"] || [c containsString:@"Caption"] || [c containsString:@"Gap"]) return YES;
    if (Lane(x) >= 999999 || Lane(x) <= -999999) return YES;
    return NO;
}
static BOOL IsVideoTarget(id x) {
    if (Skippable(x) || Locked(x)) return NO;
    if (OB(x, @"isAudioOnly") || OB(x, @"isAudioOnlyClipOrCollection")) return NO;
    return OB(x, @"hasVideo");
}
static BOOL Contains(CMTimeRange r, CMTime t) {
    if (!CMTIMERANGE_IS_VALID(r) || CMTimeCompare(r.duration, kCMTimeZero) <= 0) return NO;
    return CMTimeCompare(t, r.start) >= 0 && CMTimeCompare(t, CMTimeRangeGetEnd(r)) < 0;   // a clip owns its first frame, not the one after its end
}
static BOOL IsConnectedStoryline(id x) {
    if (![NSStringFromClass([x class]) isEqualToString:@"FFAnchoredCollection"]) return NO;
    SEL s = NSSelectorFromString(@"isSpine");
    if ([x respondsToSelector:s]) return ((BOOL(*)(id, SEL))objc_msgSend)(x, s);
    return [(NSArray *)O(x, @"containedItems") count] > 1 && [O(x, @"displayName") isEqual:@"Storyline"];
}
typedef struct { __unsafe_unretained id item; long lane; BOOL inStoryline; } SKTarget;

static SKTarget FindTopmost(id tm, CMTime t) {
    __block SKTarget best = { nil, LONG_MIN, NO };
    id prim = O(O(tm, @"sequence"), @"primaryObject");
    if (!prim) return best;
    void (^consider)(id, long, BOOL) = ^(id x, long lane, BOOL inSL) {
        if (lane > best.lane && IsVideoTarget(x) && Contains(RangeIn(x, prim), t)) { best.item = x; best.lane = lane; best.inStoryline = inSL; }
    };
    for (id spineItem in (NSArray *)O(prim, @"containedItems")) {
        consider(spineItem, 0, NO);
        for (id a in (NSSet *)O(spineItem, @"anchoredItems")) {
            if (Skippable(a) || Locked(a)) continue;
            if (IsConnectedStoryline(a)) {
                if (!Contains(RangeIn(a, prim), t)) continue;
                for (id inner in (NSArray *)O(a, @"containedItems")) consider(inner, Lane(a), YES);
            } else consider(a, Lane(a), NO);
        }
    }
    return best;
}
static CMTime EditTime(id tm) {
    // Final Cut edits at the skimmer while skimming over the timeline, otherwise at the playhead
    SEL sk = NSSelectorFromString(@"skimmingTime");
    CMTime s = [tm respondsToSelector:sk] ? ((CMTime(*)(id, SEL))objc_msgSend)(tm, sk) : kCMTimeInvalid;
    id skItem = O(tm, @"skimmingItem");
    if (skItem && CMTIME_IS_NUMERIC(s)) return s;
    return ((CMTime(*)(id, SEL))objc_msgSend)(tm, NSSelectorFromString(@"playheadTime"));
}
// the user's explicit selection only. (Plain -selectedItems also returns Final Cut's "implicit" pick under the
// playhead when nothing is selected, which is not a selection the user made.)
static NSArray *Selection(id tm) {
    SEL s2 = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
    NSArray *s = [tm respondsToSelector:s2] ? ((id(*)(id, SEL, BOOL, BOOL))objc_msgSend)(tm, s2, NO, NO) : O(tm, @"selectedItems");
    return [s isKindOfClass:[NSArray class]] ? s : @[];
}
static void SetSelection(id tm, NSArray *items) { ((void(*)(id, SEL, id))objc_msgSend)(tm, NSSelectorFromString(@"setSelectedItems:"), items); }

#pragma mark - hooks

static IMP o_blade, o_copy, o_paste, o_pasteAnchored, o_actionEnd;
static BOOL gHaveCopy; static long gCopyLane; static NSInteger gCopyChange;
static BOOL gPasteActive, gPasteHandled; static NSSet *gPasteBefore; static long gPasteLane;

// run Final Cut's own command on the topmost clip; returns NO if this press isn't ours to handle
static BOOL RunOnTopmost(id tm, SEL cmd, id sender, IMP orig, NSString *what, long *outLane) {
    NSUInteger nsel = Selection(tm).count;
    if (!Enabled() || nsel) { TL(@"%@: %@ -> native", what, !Enabled() ? @"toggle off" : [NSString stringWithFormat:@"%lu item(s) selected", (unsigned long)nsel]); return NO; }
    if (tm != ActiveTM()) TL(@"%@: note, not the active timeline module (%@ vs %@)", what, tm, ActiveTM());
    CMTime t = EditTime(tm);
    SKTarget tg = FindTopmost(tm, t);
    if (!tg.item) { TL(@"%@ at %.3f: no unlocked video clip -> native", what, CMTimeGetSeconds(t)); return NO; }
    if (tg.lane == 0 && !tg.inStoryline) { TL(@"%@ at %.3f: topmost video is on the primary storyline -> native", what, CMTimeGetSeconds(t)); return NO; }
    TL(@"%@ at %.3f: target '%@' lane %ld%@", what, CMTimeGetSeconds(t), O(tg.item, @"displayName"), tg.lane, tg.inStoryline ? @" (in connected storyline)" : @"");
    SetSelection(tm, @[tg.item]);
    @try { ((void(*)(id, SEL, id))orig)(tm, cmd, sender); }
    @finally {
        SetSelection(tm, @[]);
        // Final Cut re-selects the blade's right-hand piece after the edit settles; we never had a
        // selection, so put it back to nothing (otherwise the next press would follow that piece)
        __weak id wtm = tm;
        void (^clear)(void) = ^{
            id t2 = wtm; NSArray *sel = Selection(t2);
            if (sel.count != 1) return;
            id prim = O(O(t2, @"sequence"), @"primaryObject"), it = sel.firstObject;
            CMTimeRange r = RangeIn(it, prim);
            // only the right-hand piece of our own cut (starts at the cut point); anything else is the user's
            if (CMTIMERANGE_IS_VALID(r) && fabs(CMTimeGetSeconds(r.start) - CMTimeGetSeconds(t)) < 0.0005) SetSelection(t2, @[]);
        };
        if (cmd == NSSelectorFromString(@"blade:")) {
            dispatch_async(dispatch_get_main_queue(), clear);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), clear);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), clear);
        }
    }
    if (outLane) *outLane = tg.lane;
    return YES;
}
static void h_blade(id self, SEL _cmd, id sender) {
    @try { if (RunOnTopmost(self, _cmd, sender, o_blade, @"blade", NULL)) return; } @catch (id e) { TL(@"blade hook threw %@", e); }
    ((void(*)(id, SEL, id))o_blade)(self, _cmd, sender);
}
static void h_copy(id self, SEL _cmd, id sender) {
    long lane = 0;
    BOOL ours = NO;
    @try { ours = RunOnTopmost(self, _cmd, sender, o_copy, @"copy", &lane); } @catch (id e) { TL(@"copy hook threw %@", e); }
    if (ours) { gHaveCopy = YES; gCopyLane = lane; gCopyChange = [NSPasteboard generalPasteboard].changeCount; return; }
    gHaveCopy = NO;                                              // an ordinary copy: paste behaves natively
    ((void(*)(id, SEL, id))o_copy)(self, _cmd, sender);
}
static BOOL ClipboardIsOurs(void) { return Enabled() && gHaveCopy && [NSPasteboard generalPasteboard].changeCount == gCopyChange; }
static NSArray *AnchoredItems(id prim) {
    NSMutableArray *a = [NSMutableArray array];
    for (id item in (NSArray *)O(prim, @"containedItems")) for (id x in (NSSet *)O(item, @"anchoredItems")) if (!Skippable(x)) [a addObject:x];
    return a;
}
static NSSet *Snapshot(id tm) {
    NSMutableSet *s = [NSMutableSet set];
    for (id x in AnchoredItems(O(O(tm, @"sequence"), @"primaryObject"))) [s addObject:[NSValue valueWithNonretainedObject:x]];
    return s;
}
static BOOL Overlap(CMTimeRange a, CMTimeRange b) {
    if (!CMTIMERANGE_IS_VALID(a) || !CMTIMERANGE_IS_VALID(b)) return YES;
    CMTimeRange i = CMTimeRangeGetIntersection(a, b);
    return CMTIMERANGE_IS_VALID(i) && CMTimeCompare(i.duration, kCMTimeZero) > 0;
}
// inside Final Cut's paste action: move the pasted clip to the layer it was copied from (or the first free one above it)
static void PlacePasted(id seq) {
    id prim = O(seq, @"primaryObject");
    NSArray *all = AnchoredItems(prim);
    for (id n in all) {
        if ([gPasteBefore containsObject:[NSValue valueWithNonretainedObject:n]] || Locked(n)) continue;
        CMTimeRange r = RangeIn(n, prim);
        long want = gPasteLane, from = Lane(n);
        for (;; want += (gPasteLane > 0 ? 1 : -1)) {
            BOOL busy = NO;
            for (id o in all) if (o != n && Lane(o) == want && Overlap(r, RangeIn(o, prim))) { busy = YES; break; }
            if (!busy || labs(want) > 200) break;
        }
        if (want != from) SetLane(n, want);
        TL(@"paste: '%@' lane %ld -> %ld (copied from lane %ld)", O(n, @"displayName"), from, want, gPasteLane);
        gPasteHandled = YES;
    }
}
static BOOL h_actionEnd(id self, SEL _cmd, id name, BOOL save, NSError **err) {
    if (gPasteActive && !gPasteHandled && self == O(ActiveTM(), @"sequence")) {
        @try { PlacePasted(self); } @catch (id e) { TL(@"paste placement threw %@", e); gPasteHandled = YES; }
    }
    return ((BOOL(*)(id, SEL, id, BOOL, NSError **))o_actionEnd)(self, _cmd, name, save, err);
}
static void PasteConnectedOnOurLane(id tm, id sender) {
    gPasteBefore = Snapshot(tm); gPasteLane = gCopyLane; gPasteActive = YES; gPasteHandled = NO;
    @try { ((void(*)(id, SEL, id))o_pasteAnchored)(tm, NSSelectorFromString(@"pasteAnchored:"), sender); }
    @finally { gPasteActive = NO; gPasteBefore = nil; }
}
static void h_paste(id self, SEL _cmd, id sender) {
    if (ClipboardIsOurs() && gCopyLane != 0 && self == ActiveTM()) {
        TL(@"paste (⌘V): clip copied from lane %ld -> connected paste on that layer", gCopyLane);
        @try { PasteConnectedOnOurLane(self, sender); return; } @catch (id e) { TL(@"paste hook threw %@", e); return; }
    }
    ((void(*)(id, SEL, id))o_paste)(self, _cmd, sender);
}
static void h_pasteAnchored(id self, SEL _cmd, id sender) {
    if (ClipboardIsOurs() && gCopyLane != 0 && self == ActiveTM() && !gPasteActive) {
        TL(@"paste (⌥V): clip copied from lane %ld -> that layer", gCopyLane);
        @try { PasteConnectedOnOurLane(self, sender); return; } @catch (id e) { TL(@"pasteAnchored hook threw %@", e); return; }
    }
    ((void(*)(id, SEL, id))o_pasteAnchored)(self, _cmd, sender);
}
// hook a method on exactly this class, even if it is inherited, without touching the superclass
static IMP Hook(Class c, SEL s, IMP n) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) { TL(@"missing %@", NSStringFromSelector(s)); return NULL; }
    IMP old = method_getImplementation(m);
    if (!class_addMethod(c, s, n, method_getTypeEncoding(m))) method_setImplementation(m, n);
    return old;
}

#pragma mark - toggle (View menu + Command Editor)

@interface SKTopmostToggle : NSObject <NSMenuItemValidation>
@end
@implementation SKTopmostToggle
- (void)toggleTopmost:(id)sender {
    BOOL on = !Enabled();
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kPrefKey];
    TL(@"Edit Topmost Clip at Playhead: %@", on ? @"ON" : @"OFF");
}
- (BOOL)validateMenuItem:(NSMenuItem *)item { item.state = Enabled() ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
@end
static SKTopmostToggle *gToggle;

static void InstallMenu(void) {
    NSMenu *view = nil;
    for (NSMenuItem *top in NSApp.mainMenu.itemArray) {
        for (NSMenuItem *it in top.submenu.itemArray) if (it.action == NSSelectorFromString(@"toggleTimelineScrolling:")) { view = top.submenu; break; }
        if (view) break;
    }
    if (!view) { for (NSMenuItem *top in NSApp.mainMenu.itemArray) if ([top.title isEqualToString:@"View"]) view = top.submenu; }
    if (!view || [view itemWithTitle:kMenuTitle]) return;
    NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:kMenuTitle action:@selector(toggleTopmost:) keyEquivalent:@""];
    mi.target = gToggle;
    NSInteger idx = view.numberOfItems;
    for (NSInteger i = 0; i < view.numberOfItems; i++) {
        NSMenuItem *it = [view itemAtIndex:i];
        if (it.action == NSSelectorFromString(@"toggleTimelineScrolling:") || [it.title isEqualToString:@"Timeline Scrolling"]) idx = i + 1;
    }
    [view insertItem:mi atIndex:idx];
}
@interface NSObject (SKLK)
- (id)initWithCommandIdentifier:(id)i dictionary:(id)d; - (void)_setName:(id)n; - (void)_setDetailedDescription:(id)d;
- (void)registerCommand:(id)c; - (void)addCommandWithIdentifier:(id)i toGroupWithIdentifier:(id)g; - (id)commandWithIdentifier:(id)i;
@end
static void InstallCommand(void) {
    SEL s = NSSelectorFromString(@"spliceKitToggleTopmostEditing:");
    IMP imp = imp_implementationWithBlock(^(id self, id sender) { [gToggle toggleTopmost:sender]; });
    if (!class_addMethod([NSApplication class], s, imp, "v@:@")) class_replaceMethod([NSApplication class], s, imp, "v@:@");
    id cc = ((id(*)(id, SEL))objc_msgSend)(objc_getClass("LKCommandsController"), NSSelectorFromString(@"sharedController"));
    if (!cc || [cc commandWithIdentifier:kCmdID]) return;
    id cmd = [[objc_getClass("LKCommand") alloc] initWithCommandIdentifier:kCmdID dictionary:@{ @"downSelector" : @"spliceKitToggleTopmostEditing:", @"downRepeats" : @0 }];
    [cmd _setName:@"Edit Topmost Clip at Playhead (On/Off)"];
    [cmd _setDetailedDescription:@"With nothing selected, Blade and Copy act on the highest unlocked video clip under the playhead"];
    [cc registerCommand:cmd];
    [cc addCommandWithIdentifier:kCmdID toGroupWithIdentifier:@"Editing"];
}

__attribute__((visibility("default"))) void SpliceKitPlugin_init(void *api) { (void)api; }
static void Install(void) {
    static BOOL done; if (done) return; done = YES;
    gToggle = [SKTopmostToggle new];
    Class tmc = objc_getClass("FFAnchoredTimelineModule");
    o_blade = Hook(tmc, NSSelectorFromString(@"blade:"), (IMP)h_blade);
    o_copy = Hook(tmc, @selector(copy:), (IMP)h_copy);
    o_paste = Hook(tmc, @selector(paste:), (IMP)h_paste);
    o_pasteAnchored = Hook(tmc, NSSelectorFromString(@"pasteAnchored:"), (IMP)h_pasteAnchored);
    o_actionEnd = Hook(objc_getClass("FFAnchoredSequence"), NSSelectorFromString(@"actionEnd:save:error:"), (IMP)h_actionEnd);
    InstallMenu(); InstallCommand();
    TL(@"topmost ready (blade=%d copy=%d paste=%d pasteAnchored=%d actionEnd=%d) enabled=%d", o_blade != NULL, o_copy != NULL, o_paste != NULL, o_pasteAnchored != NULL, o_actionEnd != NULL, Enabled());
}
// after the other plugins (paste-below-lock hooks the same paste methods) so ours wraps theirs
__attribute__((constructor)) static void ctor(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ Install(); });
}
