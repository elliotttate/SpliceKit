// SpliceKit Shortcuts: adds two commands to Final Cut Pro's own Command Editor
// (Final Cut Pro > Commands > Customize...), so they can be given any key like a native command.
//   "Edit RAW Properties"  - jumps the inspector to the RAW tab for the selected BRAW clip (again = back)
//   "Toggle Stabilization" - turns Final Cut's Stabilization on/off for the selected timeline clips
//   "Show Video Inspector" / "Show Info Inspector" - switch to that tab; again on it hides the inspector
// Ships with no keys assigned; assignments are saved in the user's command set by identifier.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <CoreMedia/CoreMedia.h>
#ifndef DRYRUN
#define DRYRUN 0
#endif

static NSString *const kRAWCmd = @"SpliceKitEditRAWProperties";
static NSString *const kStabCmd = @"SpliceKitToggleStabilization";
static NSString *const kRAWTabIdent = @"SKInspectorTabRAWIdentifier";

static void SLog(NSString *fmt, ...) {
    va_list a; va_start(a, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a]; va_end(a);
    NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/shortcuts.log"];
    FILE *f = fopen(p.fileSystemRepresentation, "a");
    if (f) { fprintf(f, "%s %s\n", [NSDate date].description.UTF8String, s.UTF8String); fclose(f); }
}
static id O(id o, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    return (o && [o respondsToSelector:s]) ? ((id(*)(id, SEL))objc_msgSend)(o, s) : nil;
}
static BOOL OB(id o, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    return (o && [o respondsToSelector:s]) ? ((BOOL(*)(id, SEL))objc_msgSend)(o, s) : NO;
}

#pragma mark - Edit RAW Properties (RAW tab)

static __weak id gTabModule;
static id gReturnIdent;     // identifier of the tab shown before the RAW tab was opened by the shortcut
static NSInteger VideoTabIndexQuiet(NSTabView *tv);

static id FindResponderOfClass(NSView *v, Class c, int depth) {
    if (!v || depth > 60) return nil;
    if ([v.nextResponder isKindOfClass:c]) return v.nextResponder;
    for (NSView *sv in v.subviews) { id r = FindResponderOfClass(sv, c, depth + 1); if (r) return r; }
    return nil;
}
static id TabModule(void) {
    id m = gTabModule;
    NSView *mv = O(m, @"view");
    if (m && mv.window) return m;
    Class c = objc_getClass("FFInspectorTabModule");
    for (NSWindow *w in NSApp.windows) {
        if (!w.isVisible) continue;
        id r = FindResponderOfClass(w.contentView, c, 0);
        if (r) { gTabModule = r; return r; }
    }
    return nil;
}
static NSInteger RAWTabIndex(id module, NSTabView **outTV) {
    NSTabView *tv = nil;
    @try { tv = [module valueForKey:@"_tabView"]; } @catch (id e) { tv = nil; }
    if (outTV) *outTV = tv;
    for (NSUInteger i = 0; i < tv.tabViewItems.count; i++) {
        id ident = tv.tabViewItems[i].identifier;
        if ([ident isEqual:kRAWTabIdent] || [NSStringFromClass([ident class]) isEqualToString:@"SKRawTabModule"]) return (NSInteger)i;
    }
    return -1;
}
static void SelectTab(id module, NSInteger i) {
    ((void(*)(id, SEL, NSUInteger))objc_msgSend)(module, NSSelectorFromString(@"selectInspectorTab:"), (NSUInteger)i);
}
static BOOL InspectorShowing(id module) {
    NSView *v = O(module, @"view");
    return v.window && v.window.isVisible && !v.isHiddenOrHasHiddenAncestor && NSWidth(v.visibleRect) > 1 && NSHeight(v.visibleRect) > 1;
}
static BOOL gShowPending;
static void ToggleInspector(void) { [NSApp sendAction:NSSelectorFromString(@"toggleInspector:") to:nil from:nil]; }
// On/off toggle for the RAW properties:
//   RAW tab showing        -> hide the inspector (tab selection is left untouched)
//   anything else          -> show the inspector if needed and bring up the RAW tab
static void DoEditRAW(BOOL openedInspector) {
    id module = TabModule();
    BOOL showing = module && InspectorShowing(module);
    if (!showing) {
        if (openedInspector) { NSBeep(); SLog(@"RAW: inspector did not appear"); return; }
        if (gShowPending) { SLog(@"RAW: press ignored, inspector still opening"); return; }
        ToggleInspector();
        for (NSWindow *w in NSApp.windows) if (w.isVisible) [w.contentView layoutSubtreeIfNeeded];
        id m2 = TabModule();
        if (m2 && InspectorShowing(m2)) { SLog(@"RAW: showing inspector (immediate)"); DoEditRAW(YES); return; }
        gShowPending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ gShowPending = NO; DoEditRAW(YES); });
        SLog(@"RAW: showing inspector (deferred)");
        return;
    }
    NSTabView *tv = nil;
    NSInteger raw = RAWTabIndex(module, &tv);
    NSInteger cur = tv.selectedTabViewItem ? [tv indexOfTabViewItem:tv.selectedTabViewItem] : -1;
    if (raw < 0) {
        NSBeep(); SLog(@"RAW: no RAW tab (selection is not a BRAW clip)");
        if (openedInspector) ToggleInspector();       // we opened it only for this, so put it back
        return;
    }
    if (cur == raw && !openedInspector) {
        ToggleInspector();
        // Hand the hidden inspector back to the tab it showed before the RAW tab, so Final Cut's own
        // inspector commands (Show Inspector, Go to Inspector, ...) reopen it where they normally would
        // instead of on the RAW tab. Done after hiding, so nothing visibly switches.
        NSInteger back = -1;
        for (NSUInteger i = 0; gReturnIdent && i < tv.tabViewItems.count; i++) if ([tv.tabViewItems[i].identifier isEqual:gReturnIdent]) back = (NSInteger)i;
        if (back < 0) back = VideoTabIndexQuiet(tv);
        if (back >= 0 && back != raw) SelectTab(module, back);
        SLog(@"RAW: RAW tab was showing -> inspector hidden, underlying tab restored to %ld", (long)back);
    } else {
        if (cur != raw) {
            id prev = (cur >= 0) ? tv.tabViewItems[cur].identifier : nil;
            if (prev && !openedInspector) gReturnIdent = prev;            // tab the user was really looking at
            else if (prev && openedInspector && !gReturnIdent) gReturnIdent = prev;
            SelectTab(module, raw);
        }
        SLog(@"RAW: RAW tab shown (was tab %ld, inspector opened=%d)", (long)cur, openedInspector);
    }
}

#pragma mark - Toggle Stabilization

static id ActiveTimelineModule(void) {
    id (*fn)(void) = (id(*)(void))dlsym(RTLD_DEFAULT, "SpliceKit_getActiveTimelineModule");
    if (fn) { id tm = fn(); if (tm) return tm; }
    return O(O([NSApp delegate], @"activeEditorContainer"), @"timelineModule");
}
// The Video inspector's Stabilization belongs to the clip's media component, not the timeline
// wrapper (FFAnchoredCollection) around it - same rule SpliceKit uses for the inspector's effect stack.
static id ClipVideoStack(id item) {
    if (!item) return nil;
    if ([item isKindOfClass:objc_getClass("FFAnchoredCollection")]) {
        NSArray *inner = nil; @try { inner = [item valueForKey:@"containedItems"]; } @catch (id e) { inner = nil; }
        id first = [inner isKindOfClass:[NSArray class]] ? inner.firstObject : nil;
        id es = O(first, @"effectStack");
        if (es) return es;
    }
    return O(item, @"effectStack");
}
static BOOL StackStabilized(id es) {
    id fx = O(es, @"stabilizationEffect");
    return fx && OB(fx, @"enabled");
}
// Final Cut changes Stabilization through the inspector's checkbox (an Ozone channel operation that
// builds its own "Enable/Disable Stabilization" undo step and applies to every selected clip).
// So we press that same checkbox: identical result, undo and multi-clip behaviour as clicking it.
static BOOL gDumpButtons;
static BOOL gDryRun = DRYRUN;
static NSButton *FindStabilizationCheckbox(NSView *v, int depth) {
    if (!v || depth > 80 || v.isHidden) return nil;
    if ([v isKindOfClass:[NSButton class]] && [NSStringFromSelector([(NSButton *)v action]) isEqualToString:@"enableObject:"]) {
        NSButton *b = (NSButton *)v;
        NSString *ax = [NSString stringWithFormat:@"%@|%@|%@|%@", [b.cell accessibilityLabel], [b accessibilityLabel], [b accessibilityTitle], [b.cell accessibilityTitle]];
        if (gDumpButtons) SLog(@"STAB: candidate %@ target=%@", ax, [b.target class]);
        id fx = O(b.target, @"_effect");     // FFRiggedChannelFolderLabelController knows the effect it heads
        if (gDumpButtons) SLog(@"STAB:   effect=%@", [fx class]);
        if ([fx isKindOfClass:objc_getClass("FFStabilizationEffect")]) return b;
        for (NSString *part in [ax.lowercaseString componentsSeparatedByString:@"|"]) if ([part hasPrefix:@"stabilization"]) return b;
    }
    for (NSView *sv in v.subviews) { NSButton *b = FindStabilizationCheckbox(sv, depth + 1); if (b) return b; }
    return nil;
}
static NSInteger VideoTabIndexQuiet(NSTabView *tv) {
    for (NSUInteger i = 0; i < tv.tabViewItems.count; i++) {
        id ident = tv.tabViewItems[i].identifier;
        NSString *s = [ident isKindOfClass:[NSString class]] ? ident : NSStringFromClass([ident class]);
        if ([s rangeOfString:@"Video" options:NSCaseInsensitiveSearch].location != NSNotFound) return (NSInteger)i;
    }
    return 0;
}
static NSInteger VideoTabIndex(NSTabView *tv) {
    for (NSUInteger i = 0; i < tv.tabViewItems.count; i++) {
        id ident = tv.tabViewItems[i].identifier;
        NSString *s = [ident isKindOfClass:[NSString class]] ? ident : NSStringFromClass([ident class]);
        if ([s rangeOfString:@"Video" options:NSCaseInsensitiveSearch].location != NSNotFound) return (NSInteger)i;
    }
    NSMutableArray *ids = [NSMutableArray array]; for (NSTabViewItem *it in tv.tabViewItems) [ids addObject:[it.identifier description] ?: @"?"];
    SLog(@"STAB: no Video tab among %@", ids);
    return -1;
}
static void PressStabilization(id module, NSInteger restoreTab, BOOL hideInspectorAfter, int attempt) {
    NSView *root = O(module, @"view");
    NSButton *b = FindStabilizationCheckbox(root, 0);
    if (!b && attempt < 6) {   // the Video tab builds its controls on the next run-loop passes
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ PressStabilization(module, restoreTab, hideInspectorAfter, attempt + 1); });
        return;
    }
    if (!b) { NSBeep(); SLog(@"STAB: Stabilization checkbox not found"); gDumpButtons = YES; FindStabilizationCheckbox(root, 0); gDumpButtons = NO; }
    else if (!b.isEnabled) { NSBeep(); SLog(@"STAB: Stabilization not available for this selection"); }
    else if (gDryRun) { SLog(@"STAB: DRY RUN found checkbox state=%ld enabled=%d", (long)b.state, b.isEnabled); }
    else { NSInteger before = b.state; [b performClick:nil]; SLog(@"STAB: checkbox %ld -> %ld", (long)before, (long)b.state); }
    if (restoreTab >= 0) SelectTab(module, restoreTab);
    if (hideInspectorAfter) [NSApp sendAction:NSSelectorFromString(@"toggleInspector:") to:nil from:nil];
}
static void DoToggleStabilization(BOOL shownInspector) {
    id tm = ActiveTimelineModule();
    NSArray *sel = O(tm, @"selectedItems");
    BOOL anyVideo = NO;
    for (id it in sel) if (ClipVideoStack(it)) { anyVideo = YES; break; }
    if (!anyVideo) { NSBeep(); SLog(@"STAB: no video clips selected"); return; }
    id module = TabModule();
    if (!module) {
        if (shownInspector) { NSBeep(); SLog(@"STAB: inspector not found"); return; }
        [NSApp sendAction:NSSelectorFromString(@"toggleInspector:") to:nil from:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ DoToggleStabilization(YES); });
        return;
    }
    NSTabView *tv = nil; @try { tv = [module valueForKey:@"_tabView"]; } @catch (id e) { tv = nil; }
    NSInteger cur = tv.selectedTabViewItem ? [tv indexOfTabViewItem:tv.selectedTabViewItem] : -1;
    NSInteger video = VideoTabIndex(tv);
    NSInteger restore = -1;
    if (video >= 0 && video != cur) { SelectTab(module, video); restore = cur; }
    PressStabilization(module, restore, shownInspector, 0);
}

#pragma mark - Zoom to Fit (toggle, like DaVinci Resolve's Shift-Z)

// First press remembers the exact visible time window (zoom + horizontal scroll) and zooms to fit.
// Next press - as long as the view is still the fitted one - puts that exact window back.
// Restoring through zoomToRange:withPaddingFactor:0 with the saved visible range reproduces the
// original zoom factor and scroll offset exactly (verified: same zoomFactor, same clip-view origin).
static BOOL gZTFSaved;
static CMTimeRange gZTFRange;              // visible time range before zoom to fit
static double gZTFZoom;                    // zoom factor before zoom to fit
static CGFloat gZTFX, gZTFDocW;           // horizontal scroll + document width before zoom to fit
static double gZTFFitZoom;                 // zoom factor of the fitted view we produced
static CGFloat gZTFFitX;                   // horizontal scroll of the fitted view we produced
static __weak id gZTFSequence;             // which project the saved view belongs to
static __weak id gZTFView;

static double TVZoom(id tv) { return ((double(*)(id, SEL))objc_msgSend)(tv, NSSelectorFromString(@"zoomFactor")); }
static CMTimeRange TVVisible(id tv) { return ((CMTimeRange(*)(id, SEL))objc_msgSend)(tv, NSSelectorFromString(@"visibleTimeRange")); }
static CGFloat TVScrollX(id tv) { NSScrollView *sv = [tv enclosingScrollView]; return sv ? sv.contentView.bounds.origin.x : 0; }

static void DoZoomToFitToggle(void) {
    id tm = ActiveTimelineModule();
    id tv = O(tm, @"timelineView");
    id seq = O(tm, @"sequence");
    SEL fitSel = NSSelectorFromString(@"zoomToFit:"), rangeSel = NSSelectorFromString(@"zoomToRange:withPaddingFactor:");
    if (!tv || ![tv respondsToSelector:fitSel] || ![tv respondsToSelector:rangeSel]) { NSBeep(); SLog(@"ZTF: no timeline"); return; }
    double z = TVZoom(tv); CGFloat x = TVScrollX(tv);
    BOOL stillFitted = gZTFSaved && seq == gZTFSequence && tv == gZTFView
                       && fabs(z - gZTFFitZoom) <= 1e-6 * MAX(1.0, fabs(gZTFFitZoom)) && fabs(x - gZTFFitX) < 1.0;
    if (stillFitted) {
        ((void(*)(id, SEL, CMTimeRange, double))objc_msgSend)(tv, rangeSel, gZTFRange, 0.0);
        gZTFSaved = NO;
        CMTimeRange now = TVVisible(tv);
        double dStart = fabs(CMTimeGetSeconds(now.start) - CMTimeGetSeconds(gZTFRange.start));
        double dDur = fabs(CMTimeGetSeconds(now.duration) - CMTimeGetSeconds(gZTFRange.duration));
        double frameTol = MAX(CMTimeGetSeconds(gZTFRange.duration) * 0.002, 1e-6);
        if (fabs(TVZoom(tv) - gZTFZoom) > 1e-6 || dStart > frameTol || dDur > frameTol) {
            // zoomToRange refuses very small ranges (sub-frame zoom): set the zoom factor directly and scroll back
            ((void(*)(id, SEL, double))objc_msgSend)(tv, NSSelectorFromString(@"setZoomFactor:"), gZTFZoom);
            NSScrollView *sv = [tv enclosingScrollView];
            [[tv window] layoutIfNeeded];
            CGFloat docW = NSWidth([sv.documentView frame]);
            CGFloat targetX = (gZTFDocW > 0 && docW > 0) ? gZTFX * (docW / gZTFDocW) : gZTFX;
            [sv.contentView scrollToPoint:NSMakePoint(targetX, sv.contentView.bounds.origin.y)];
            [sv reflectScrolledClipView:sv.contentView];
            // fine-tune on time so the left edge lands on the same instant
            CMTimeRange v = TVVisible(tv);
            double pps = NSWidth(sv.contentView.bounds) / MAX(CMTimeGetSeconds(v.duration), 1e-9);
            double err = CMTimeGetSeconds(gZTFRange.start) - CMTimeGetSeconds(v.start);
            if (fabs(err * pps) >= 1.0) {
                [sv.contentView scrollToPoint:NSMakePoint(sv.contentView.bounds.origin.x + err * pps, sv.contentView.bounds.origin.y)];
                [sv reflectScrolledClipView:sv.contentView];
            }
            now = TVVisible(tv);
            SLog(@"ZTF: used zoom-factor restore (range restore gave start err %.4fs)", dStart);
        }
        SLog(@"ZTF: restored %.4f+%.4f (now %.4f+%.4f, zoom %.6f, x %.1f)", CMTimeGetSeconds(gZTFRange.start), CMTimeGetSeconds(gZTFRange.duration),
             CMTimeGetSeconds(now.start), CMTimeGetSeconds(now.duration), TVZoom(tv), TVScrollX(tv));
    } else {
        gZTFRange = TVVisible(tv);
        gZTFZoom = z; gZTFX = x; gZTFDocW = NSWidth([[tv enclosingScrollView].documentView frame]);
        gZTFSequence = seq; gZTFView = tv;
        ((void(*)(id, SEL, id))objc_msgSend)(tv, fitSel, nil);
        gZTFFitZoom = TVZoom(tv); gZTFFitX = TVScrollX(tv);
        gZTFSaved = YES;
        SLog(@"ZTF: saved %.4f+%.4f (zoom %.6f, x %.1f) -> fitted (zoom %.6f, x %.1f)", CMTimeGetSeconds(gZTFRange.start), CMTimeGetSeconds(gZTFRange.duration),
             z, x, gZTFFitZoom, gZTFFitX);
    }
}


#pragma mark - Show Video / Info Inspector (switch tab, never close)

// Final Cut has no "Video inspector" command - its usual key is Show/Hide Inspector, which closes the
// panel when pressed on another tab. These switch to the tab and open the inspector if needed, never close it.
static NSInteger TabIndexMatching(NSTabView *tv, NSArray<NSString *> *words) {
    for (NSUInteger i = 0; i < tv.tabViewItems.count; i++) {
        NSTabViewItem *it = tv.tabViewItems[i];
        id ident = it.identifier;
        NSString *s = [NSString stringWithFormat:@"%@|%@|%@", [ident isKindOfClass:[NSString class]] ? ident : @"", NSStringFromClass([ident class]), it.label ?: @""];
        if ([ident isEqual:kRAWTabIdent] || [s rangeOfString:@"SKRawTab"].location != NSNotFound) continue;
        for (NSString *w in words) if ([s rangeOfString:w options:NSCaseInsensitiveSearch].location != NSNotFound) return (NSInteger)i;
    }
    return -1;
}
static void DoShowInspectorTab(NSArray<NSString *> *words, NSString *what, BOOL opened) {
    id module = TabModule();
    if (!(module && InspectorShowing(module))) {
        if (opened) { NSBeep(); SLog(@"%@: inspector did not appear", what); return; }
        ToggleInspector();
        for (NSWindow *w in NSApp.windows) if (w.isVisible) [w.contentView layoutSubtreeIfNeeded];
        id m2 = TabModule();
        if (m2 && InspectorShowing(m2)) { DoShowInspectorTab(words, what, YES); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ DoShowInspectorTab(words, what, YES); });
        return;
    }
    NSTabView *tv = nil; @try { tv = [module valueForKey:@"_tabView"]; } @catch (id e) { tv = nil; }
    NSInteger i = TabIndexMatching(tv, words);
    if (i < 0) { SLog(@"%@: no such tab for this selection, left as is", what); return; }
    if (tv.selectedTabViewItem == tv.tabViewItems[i] && !opened) {   // already on this tab: same key closes it
        ToggleInspector();
        SLog(@"%@: tab %ld was showing -> inspector hidden", what, (long)i);
        return;
    }
    if (tv.selectedTabViewItem != tv.tabViewItems[i]) SelectTab(module, i);
    SLog(@"%@: tab %ld shown (inspector opened=%d)", what, (long)i, opened);
}

#pragma mark - never leave the hidden inspector on the RAW tab

// However the inspector gets hidden (Show/Hide Inspector key, menu, toolbar button) while the RAW tab
// is up, hand it back to the tab underneath, so Final Cut's own commands never reopen it on RAW.
static IMP gOrigToggleInspector;
static void RestoreUnderRAW(id module) {
    if (!module || InspectorShowing(module)) return;
    NSTabView *tv = nil;
    NSInteger raw = RAWTabIndex(module, &tv);
    NSInteger cur = tv.selectedTabViewItem ? [tv indexOfTabViewItem:tv.selectedTabViewItem] : -1;
    if (raw < 0 || cur != raw) return;
    NSInteger back = -1;
    for (NSUInteger i = 0; gReturnIdent && i < tv.tabViewItems.count; i++) if ([tv.tabViewItems[i].identifier isEqual:gReturnIdent]) back = (NSInteger)i;
    if (back < 0 || back == raw) back = VideoTabIndexQuiet(tv);
    if (back >= 0 && back != raw) { SelectTab(module, back); SLog(@"RAW: inspector hidden on RAW tab -> underlying tab set to %ld", (long)back); }
}
static void HookToggleInspector(void) {
    Class c = objc_getClass("PEAppController");
    Method m = c ? class_getInstanceMethod(c, NSSelectorFromString(@"toggleInspector:")) : NULL;
    if (!m || gOrigToggleInspector) return;
    IMP orig = method_getImplementation(m);
    gOrigToggleInspector = orig;
    method_setImplementation(m, imp_implementationWithBlock(^(id self, id sender) {
        id module = nil; BOOL onRAW = NO;
        @try {   // look before hiding: once hidden the inspector view may leave the window
            module = TabModule();
            if (module && InspectorShowing(module)) {
                NSTabView *tv = nil; NSInteger raw = RAWTabIndex(module, &tv);
                onRAW = raw >= 0 && tv.selectedTabViewItem == tv.tabViewItems[raw];
            }
        } @catch (id e) { onRAW = NO; }
        ((void(*)(id, SEL, id))orig)(self, NSSelectorFromString(@"toggleInspector:"), sender);
        if (!onRAW) return;
        @try {
            RestoreUnderRAW(module);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ @try { RestoreUnderRAW(module); } @catch (id e) {} });
        } @catch (id e) { SLog(@"toggle hook threw %@", e); }
    }));
    SLog(@"hooked PEAppController toggleInspector:");
}

#pragma mark - command registration

@interface NSObject (SKLKCommands)
- (id)initWithCommandIdentifier:(id)ident dictionary:(id)dict;
- (void)_setName:(id)n; - (void)_setDetailedDescription:(id)d;
- (void)registerCommand:(id)c; - (void)addCommandWithIdentifier:(id)i toGroupWithIdentifier:(id)g;
- (id)commandWithIdentifier:(id)i;
- (id)_activeCommandSet; - (id)commandWithCharacter:(unsigned short)c modifierMask:(unsigned long long)m;
- (void)_addCommand:(id)c withCharacter:(unsigned short)ch modifierMask:(unsigned long long)m;
- (void)_removeCommand:(id)c withCharacter:(unsigned short)ch modifierMask:(unsigned long long)m;
- (void)_saveIfNecessary; - (BOOL)isEditable; - (id)identifier;
@end

// Optional, one time (off unless SpliceKitShortcutsRebindKey2 is set): if the plain "2" key is bound to Show/Hide Inspector,
// Move just that key to Show Video Inspector (Cmd-4 stays Show/Hide Inspector). Never repeated, so any
// later change the user makes in the Command Editor is left alone.
static void MoveKey2ToVideoInspector(id cc) {
    NSString *flag = @"SpliceKitMovedKey2ToVideoInspector";
    if ([[NSUserDefaults standardUserDefaults] boolForKey:flag]) return;
    id set = [cc _activeCommandSet];
    id videoCmd = [cc commandWithIdentifier:@"SpliceKitShowVideoInspector"];
    if (!set || !videoCmd || ![set isEditable]) { SLog(@"key 2: command set not editable"); return; }
    id cur = [set commandWithCharacter:'2' modifierMask:0];
    if ([[cur identifier] isEqual:@"ToggleInspector"]) {
        [set _removeCommand:cur withCharacter:'2' modifierMask:0];
        [set _addCommand:videoCmd withCharacter:'2' modifierMask:0];
        [set _saveIfNecessary];
        SLog(@"key 2: moved from Show/Hide Inspector to Show Video Inspector (now %@)", [[set commandWithCharacter:'2' modifierMask:0] identifier]);
    } else SLog(@"key 2: bound to %@, left alone", [cur identifier]);
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:flag];
}

static void AddAction(NSString *selName, void (^body)(void)) {
    SEL s = NSSelectorFromString(selName);
    IMP imp = imp_implementationWithBlock(^(id self, id sender) { @try { body(); } @catch (id e) { SLog(@"%@ threw %@", selName, e); } });
    if (!class_addMethod([NSApplication class], s, imp, "v@:@")) class_replaceMethod([NSApplication class], s, imp, "v@:@");
}
static void Register(id cc, NSString *ident, NSString *sel, NSString *name, NSString *desc, NSString *group) {
    if ([cc commandWithIdentifier:ident]) { SLog(@"%@ already registered", ident); return; }
    id cmd = [[objc_getClass("LKCommand") alloc] initWithCommandIdentifier:ident dictionary:@{ @"downSelector" : sel, @"downRepeats" : @0 }];
    if (!cmd) { SLog(@"could not create %@", ident); return; }
    [cmd _setName:name]; [cmd _setDetailedDescription:desc];
    [cc registerCommand:cmd];
    [cc addCommandWithIdentifier:ident toGroupWithIdentifier:group];
    SLog(@"registered %@ (%@) in %@", ident, name, group);
}
__attribute__((visibility("default"))) void SpliceKitPlugin_init(void *api) { (void)api; }
static void install(void) {
    static BOOL done; if (done) return; done = YES;
    AddAction(@"spliceKitEditRAWProperties:", ^{ DoEditRAW(NO); });
    AddAction(@"spliceKitToggleStabilization:", ^{ DoToggleStabilization(NO); });
    AddAction(@"spliceKitZoomToFitToggle:", ^{ DoZoomToFitToggle(); });
    AddAction(@"spliceKitShowVideoInspector:", ^{ DoShowInspectorTab(@[@"Video"], @"VIDEO", NO); });
    AddAction(@"spliceKitShowInfoInspector:", ^{ DoShowInspectorTab(@[@"Info", @"Metadata"], @"INFO", NO); });
    HookToggleInspector();
    id cc = ((id(*)(id, SEL))objc_msgSend)(objc_getClass("LKCommandsController"), NSSelectorFromString(@"sharedController"));
    if (!cc) { SLog(@"no LKCommandsController"); return; }
    Register(cc, kRAWCmd, @"spliceKitEditRAWProperties:", @"Edit RAW Properties",
             @"Show or hide the RAW properties for the selected BRAW clip", @"General");
    Register(cc, kStabCmd, @"spliceKitToggleStabilization:", @"Toggle Stabilization",
             @"Turn Stabilization on or off for the selected clips", @"Effects");
    Register(cc, @"SpliceKitZoomToFitToggle", @"spliceKitZoomToFitToggle:", @"Zoom to Fit (Toggle)",
             @"Fit the whole timeline in view; press again to return to the exact zoom and scroll position you had before", @"View");
    Register(cc, @"SpliceKitShowVideoInspector", @"spliceKitShowVideoInspector:", @"Show Video Inspector",
             @"Switch the inspector to the Video tab (press again on that tab to hide the inspector)", @"General");
    Register(cc, @"SpliceKitShowInfoInspector", @"spliceKitShowInfoInspector:", @"Show Info Inspector",
             @"Switch the inspector to the Info tab (press again on that tab to hide the inspector)", @"General");
    // Opt-in only: `defaults write com.apple.FinalCut SpliceKitShortcutsRebindKey2 -bool YES`
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"SpliceKitShortcutsRebindKey2"]) MoveKey2ToVideoInspector(cc);
}
__attribute__((constructor)) static void shortcuts_init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ install(); });
}
