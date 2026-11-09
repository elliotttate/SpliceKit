// Workspace Collapse - in the "Vertical Workspace" layout, the Browser and the Inspector share one row above
// the timeline. Final Cut leaves that row on screen when both are closed (a blank band), and the Inspector
// can't grow past its maximum width when only the Browser is closed (a blank strip). This plugin:
//   - collapses the row when both panels are closed, so the timeline takes the full height,
//   - lets the Inspector fill the row when it is the only panel left in it,
//   - lets Final Cut bring everything back exactly as it was when a panel is reopened.
// Only the workspace named "Vertical Workspace" is touched; everything goes through Final Cut's own
// hide/unhide calls, so the native menu items, shortcuts and workspace switching are unchanged.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#ifndef WCNOTE
#define WCNOTE @"SKWC"
#endif
// The workspace to manage. Override with: defaults write com.apple.FinalCut SpliceKitWorkspaceCollapseName "My Workspace"
#define kWorkspaceName (([[NSUserDefaults standardUserDefaults] stringForKey:@"SpliceKitWorkspaceCollapseName"]) ?: @"Vertical Workspace")
static NSString *gLogPath;
static void WLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
    if (!h) { [line writeToFile:gLogPath atomically:NO encoding:NSUTF8StringEncoding error:nil]; return; }
    [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}
static id O(id o, NSString *s) { SEL x = NSSelectorFromString(s); return (o && [o respondsToSelector:x]) ? ((id(*)(id, SEL))objc_msgSend)(o, x) : nil; }
static BOOL OB1(id o, NSString *s, id a) { SEL x = NSSelectorFromString(s); return (o && [o respondsToSelector:x]) ? ((BOOL(*)(id, SEL, id))objc_msgSend)(o, x, a) : NO; }

static NSString *const kRowBrowser = @"PEMediaEventOrganizerContainerModule";
static NSString *const kRowInspector = @"PEInspectorColorSwapModule";

static BOOL WorkspaceActive(void) {
    @try {
        id lm = ((id(*)(id, SEL))objc_msgSend)(objc_getClass("LKModuleLayoutManager"), @selector(sharedInstance));
        if (!O(lm, @"currentLayoutIdentifier")) return NO;   // no workspace applied yet (launch)
        id cur = O(lm, @"currentModuleLayout");
        id name = O(cur, @"displayName");
        return [[NSString stringWithFormat:@"%@", name] isEqual:kWorkspaceName];
    } @catch (NSException *e) { WLog(@"workspace check threw %@ %@", e.name, e.reason); return NO; }
}
// the container that holds the Browser and the Inspector side by side
static BOOL IsPanelRow(id m) {
    if (![m isKindOfClass:objc_getClass("LKContainerModule")]) return NO;
    BOOL b = NO, i = NO;
    for (id s in (NSArray *)O(m, @"submodules")) { NSString *ident = O(s, @"identifier"); b |= [ident isEqual:kRowBrowser]; i |= [ident isEqual:kRowInspector]; }
    return b && i;
}
static id RowChild(id row, NSString *ident) { for (id s in (NSArray *)O(row, @"submodules")) if ([O(s, @"identifier") isEqual:ident]) return s; return nil; }
static BOOL Visible(id parent, id child) { return child && OB1(parent, @"isSubmoduleVisible:", child); }

// sizes of the two panels while both were open, so they come back exactly as they were
static NSMutableDictionary *gSaved;   // identifier -> @[width, height, proportion]
static id NodeFor(id row, id sub) { SEL x = NSSelectorFromString(@"_containerNodeFromSubmodule:"); return [row respondsToSelector:x] ? ((id(*)(id, SEL, id))objc_msgSend)(row, x, sub) : nil; }
static void SnapshotRow(id row) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *ident in @[kRowBrowser, kRowInspector]) {
        id node = NodeFor(row, RowChild(row, ident)); if (!node) return;
        NSSize sz = ((NSSize(*)(id, SEL))objc_msgSend)(node, @selector(currentSize));
        double pr = ((double(*)(id, SEL))objc_msgSend)(node, @selector(proportion));
        d[ident] = @[@(sz.width), @(sz.height), @(pr)];
    }
    gSaved = d;
    WLog(@"saved panel sizes %@", [[d description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]);
}
static void RestoreRow(id row) {
    if (!gSaved) return;
    for (NSString *ident in @[kRowBrowser, kRowInspector]) {
        NSArray *v = gSaved[ident]; id node = NodeFor(row, RowChild(row, ident)); if (!v || !node) continue;
        ((void(*)(id, SEL, NSSize))objc_msgSend)(node, @selector(setCurrentSize:), NSMakeSize([v[0] doubleValue], [v[1] doubleValue]));
        ((void(*)(id, SEL, double))objc_msgSend)(node, @selector(setProportion:), [v[2] doubleValue]);
    }
    ((void(*)(id, SEL))objc_msgSend)(row, @selector(layout));
    WLog(@"restored panel sizes");
}
static IMP oHide, oUnhide, oInspMax;
static BOOL gBusy;
static BOOL gStretchInspector;   // Browser closed, Inspector open: let the Inspector use the whole row

static void Settle(id row, NSString *why);
static BOOL hHide(id self, SEL _cmd, id sub) {
    @try { if (!gBusy && IsPanelRow(self) && WorkspaceActive() && Visible(self, RowChild(self, kRowBrowser)) && Visible(self, RowChild(self, kRowInspector))) SnapshotRow(self); } @catch (NSException *e) { WLog(@"snapshot threw %@", e.reason); }
    BOOL r = ((BOOL(*)(id, SEL, id))oHide)(self, _cmd, sub);
    @try { if (!gBusy && IsPanelRow(self)) Settle(self, [NSString stringWithFormat:@"hid %@", O(sub, @"identifier")]); } @catch (NSException *e) { WLog(@"hide follow-up threw %@", e.reason); }
    return r;
}
static BOOL hUnhide(id self, SEL _cmd, id sub) {
    @try { if (!gBusy && IsPanelRow(self)) {
        id parent = O(self, @"supermodule");
        if (parent && !Visible(parent, self) && WorkspaceActive()) {   // the row was collapsed by us: bring it back first
            gBusy = YES; @try { ((BOOL(*)(id, SEL, id))oUnhide)(parent, _cmd, self); } @finally { gBusy = NO; }
            WLog(@"restored panel row (for %@)", O(sub, @"identifier"));
        }
    } } @catch (NSException *e) { WLog(@"unhide pre-step threw %@", e.reason); }
    BOOL r = ((BOOL(*)(id, SEL, id))oUnhide)(self, _cmd, sub);
    @try { if (!gBusy && IsPanelRow(self)) Settle(self, [NSString stringWithFormat:@"showed %@", O(sub, @"identifier")]); } @catch (NSException *e) { WLog(@"unhide follow-up threw %@", e.reason); }
    return r;
}
static NSSize hInspMax(id self, SEL _cmd) {
    NSSize s = ((NSSize(*)(id, SEL))oInspMax)(self, _cmd);
    if (gStretchInspector && WorkspaceActive()) s.width = MAX(s.width, 100000);   // only in the Vertical Workspace
    return s;
}
static void Settle(id row, NSString *why) {
    BOOL active = WorkspaceActive();
    id parent = O(row, @"supermodule");
    id browser = RowChild(row, kRowBrowser), insp = RowChild(row, kRowInspector);
    BOOL bVis = Visible(row, browser), iVis = Visible(row, insp);
    BOOL wantStretch = active && iVis && !bVis;
    if (wantStretch != gStretchInspector) {
        gStretchInspector = wantStretch;
        NSSize mx = ((NSSize(*)(id, SEL))objc_msgSend)(insp, @selector(viewMaxSize));
        @try { ((void(*)(id, SEL, id, NSSize))objc_msgSend)(row, @selector(submodule:didChangeMaxSize:), insp, mx); } @catch (id e) { WLog(@"maxSize relayout threw %@", e); }
    }
    if (active && bVis && iVis && gSaved) { @try { RestoreRow(row); } @catch (NSException *e) { WLog(@"restore threw %@", e.reason); } gSaved = nil; }
    if (active && !bVis && !iVis && parent && Visible(parent, row)) {
        gBusy = YES; @try { ((BOOL(*)(id, SEL, id))oHide)(parent, @selector(hideSubmodule:), row); } @finally { gBusy = NO; }
        WLog(@"%@: both panels closed - collapsed the row, timeline takes the space", why);
    } else WLog(@"%@: browser %d inspector %d (workspace %@)%@", why, bVis, iVis, active ? @"vertical" : @"other", gStretchInspector ? @", inspector fills the row" : @"");
}

__attribute__((visibility("default"))) void SpliceKitPlugin_init(void *api) { (void)api; }
static void Install(void) {
    static BOOL done; if (done) return; done = YES;
    Class lc = objc_getClass("LKContainerModule"), ic = objc_getClass("PEInspectorSwapModule");
    Method mh = lc ? class_getInstanceMethod(lc, @selector(hideSubmodule:)) : NULL;
    Method mu = lc ? class_getInstanceMethod(lc, @selector(unhideSubmodule:)) : NULL;
    Method mx = ic ? class_getInstanceMethod(ic, @selector(viewMaxSize)) : NULL;
    if (!mh || !mu || ![objc_getClass("LKModuleLayoutManager") respondsToSelector:@selector(sharedInstance)]) { WLog(@"workspace collapse disabled: Final Cut internals not found"); return; }
    oHide = method_setImplementation(mh, (IMP)hHide);
    oUnhide = method_setImplementation(mu, (IMP)hUnhide);
    if (mx) {   // PEInspectorSwapModule may inherit viewMaxSize: give it its own override so other modules are untouched
        if (class_addMethod(ic, @selector(viewMaxSize), (IMP)hInspMax, method_getTypeEncoding(mx))) oInspMax = method_getImplementation(mx);
        else oInspMax = method_setImplementation(class_getInstanceMethod(ic, @selector(viewMaxSize)), (IMP)hInspMax);
    }
    [[NSNotificationCenter defaultCenter] addObserverForName:WCNOTE object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        NSString *c = n.object;
        @try { if ([c isEqual:@"info"]) {
            id row = ((id(*)(id, SEL, id))objc_msgSend)(objc_getClass("LKViewModule"), @selector(installedModuleWithIdentifier:), @"PEContainer2");
            id insp = RowChild(row, kRowInspector), parent = O(row, @"supermodule");
            NSSize mx2 = insp ? ((NSSize(*)(id, SEL))objc_msgSend)(insp, @selector(viewMaxSize)) : NSZeroSize, mn = insp ? ((NSSize(*)(id, SEL))objc_msgSend)(insp, @selector(viewMinSize)) : NSZeroSize;
            NSView *iv = O(insp, @"view"), *rv = O(row, @"view");
            WLog(@"info: workspace active %d row %@ isRow %d rowVisible %d visible %@ | inspector max %@ min %@ frame %@ | row frame %@ stretch %d",
                 WorkspaceActive(), O(row, @"identifier"), IsPanelRow(row), Visible(parent, row), [((NSArray *)O(row, @"visibleSubmodules")) valueForKey:@"identifier"],
                 NSStringFromSize(mx2), NSStringFromSize(mn), NSStringFromRect(iv.frame), NSStringFromRect(rv.frame), gStretchInspector);
        } } @catch (NSException *e) { WLog(@"info threw %@", e.reason); }
    }];
    WLog(@"workspace collapse ready (%@)", WorkspaceActive() ? @"Vertical Workspace active" : @"other workspace");
}
__attribute__((constructor)) static void wc_init(void) {
    gLogPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/wscollapse.log"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ @try { Install(); } @catch (NSException *e) { WLog(@"install threw %@ %@", e.name, e.reason); } });
}
