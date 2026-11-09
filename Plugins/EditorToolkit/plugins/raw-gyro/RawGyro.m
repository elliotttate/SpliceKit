// RAW Gyro: one-click gyro stabilisation presets in the RAW tab, under "Gyroflow Stabilisation".
// "Gyro Preset:  Off / Smooth / Medium / Locked" — sets BRAW Toolbox's Gyroflow controls for all
// selected clips at once (like DaVinci Resolve's Stabilizer → Gyro mode). Styled like the panel's menus.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
static void GLog(NSString *s) {
    FILE *f = fopen([[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/rawgyro.log"] fileSystemRepresentation], "a");
    if (f) { fprintf(f, "%s %s\n", [NSDate date].description.UTF8String, s.UTF8String); fclose(f); }
}
static id RefIvar(id obj, const char *name) {
    Ivar iv = obj ? class_getInstanceVariable(object_getClass(obj), name) : NULL;
    if (!iv) return nil;
    return (__bridge id)(*(void **)((char *)(__bridge void *)obj + ivar_getOffset(iv)));
}
static id GHud(void) { return ((id(*)(id,SEL))objc_msgSend)(objc_getClass("FFVTRAWSettingsHud"), NSSelectorFromString(@"shared")); }
static NSString *const kRowID = @"SKGyroPresetRow";

static NSArray<NSDictionary *> *GPresets(void) {
    // smoothness 0-100 · adaptive zoom = seconds of zoom smoothing (0 = fixed crop)
    // zoom limit % = how far it may crop in to hide edges · horizon lock 0-100
    #define P(n, sm, az, mz, hl) @{@"name": n, @"stabilisationEnabled": @YES, @"stabilisationSmoothness": @(sm), @"stabilisationAdaptiveZoom": @(az), @"stabilisationMaxZoom": @(mz), @"stabilisationHorizonLock": @(hl), @"stabilisationLensCorrection": @1, @"stabilisationFOV": @1}
    return @[
        @{@"name": @"Off", @"stabilisationEnabled": @NO},
        P(@"Smooth",       30,  4, 130,   0),
        P(@"Medium",       55,  4, 130,   0),
        P(@"Strong",       75,  6, 160,  50),
        P(@"Extra Strong", 90,  8, 190,  80),
        P(@"Locked",      100,  6, 130, 100),
        P(@"Ultra",       100, 10, 220, 100),
        P(@"Tripod",      100,  0, 250, 100),
    ];
    #undef P
}
static void GWalk(NSArray *ps, NSMutableDictionary *d) {
    for (id p in ps) {
        if ([p respondsToSelector:@selector(children)]) GWalk([p valueForKey:@"children"], d);
        else if ([p respondsToSelector:NSSelectorFromString(@"current")]) { id v = [p valueForKey:@"current"]; NSString *k = [p valueForKey:@"key"]; if (k && v) d[k] = v; }
    }
}
static NSDictionary *GCurrent(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    GWalk(RefIvar(GHud(), "_parameters"), d);
    return d;
}

static void GApply(NSDictionary *values, NSString *what) {
    id hud = GHud(), ctrl = RefIvar(hud, "_controller");
    if (!ctrl) { NSBeep(); return; }
    @try {
        ((void(*)(id,SEL,id))objc_msgSend)(hud, NSSelectorFromString(@"settingsChangeBegin:"), nil);
        NSMutableArray *keys = [[values allKeys] mutableCopy]; [keys removeObject:@"name"];
        if ([keys containsObject:@"stabilisationEnabled"]) { [keys removeObject:@"stabilisationEnabled"]; [keys insertObject:@"stabilisationEnabled" atIndex:0]; }
        for (NSString *k in keys) ((BOOL(*)(id,SEL,id,id))objc_msgSend)(ctrl, @selector(setValue:forKey:), values[k], k);
        ((void(*)(id,SEL,id))objc_msgSend)(hud, NSSelectorFromString(@"settingsChangeEnd:"), nil);
        ((void(*)(id,SEL))objc_msgSend)(hud, NSSelectorFromString(@"refreshOrRebuildUI"));
        GLog([NSString stringWithFormat:@"applied %@ via %@", what, [ctrl class]]);
    } @catch (id e) { GLog([NSString stringWithFormat:@"apply threw %@", e]); }
}
// One "strength" dial 0-100 that drives all the gyro controls together (like Resolve).
static NSDictionary *GStrengthValues(double s) {
    if (s <= 0.5) return @{@"stabilisationEnabled": @NO};
    return @{@"stabilisationEnabled": @YES,
             @"stabilisationSmoothness": @(round(s)),
             @"stabilisationAdaptiveZoom": @(round(4 + s * 0.06)),
             @"stabilisationMaxZoom": @(round(130 + s * 1.2)),
             @"stabilisationHorizonLock": @(round(MAX(0, (s - 50) * 2))),
             @"stabilisationLensCorrection": @1, @"stabilisationFOV": @1};
}
@interface SKGyroPresetTarget : NSObject
- (void)choose:(NSPopUpButton *)sender;
- (void)strength:(NSSlider *)sender;
@end
@implementation SKGyroPresetTarget
- (void)choose:(NSPopUpButton *)sender {
    NSInteger i = sender.indexOfSelectedItem;
    NSArray *ps = GPresets();
    if (i < 0 || i >= (NSInteger)ps.count) return;
    GApply(ps[i], [NSString stringWithFormat:@"preset %@", ps[i][@"name"]]);
}
- (void)strength:(NSSlider *)sender {
    NSTextField *val = objc_getAssociatedObject(sender, "sk_val");
    val.stringValue = [NSString stringWithFormat:@"%.0f", sender.doubleValue];
    NSEvent *e = NSApp.currentEvent;
    BOOL done = !(e.type == NSEventTypeLeftMouseDragged);   // apply when you let go, not on every pixel
    if (done) GApply(GStrengthValues(sender.doubleValue), [NSString stringWithFormat:@"strength %.0f", sender.doubleValue]);
}
@end
static SKGyroPresetTarget *gTarget;

static void GSync(NSPopUpButton *pop) {
    NSDictionary *cur = GCurrent();
    NSArray *ps = GPresets();
    NSInteger match = -1;
    if (![cur[@"stabilisationEnabled"] boolValue]) match = 0;
    else for (NSInteger i = 1; i < (NSInteger)ps.count; i++) {
        BOOL ok = YES;
        for (NSString *k in ps[i]) { if ([k isEqual:@"name"]) continue; if (fabs([cur[k] doubleValue] - [ps[i][k] doubleValue]) > 0.01) { ok = NO; break; } }
        if (ok) { match = i; break; }
    }
    NSMenuItem *custom = [pop itemWithTitle:@"Custom"];
    if (match >= 0) { [pop selectItemAtIndex:match]; custom.hidden = YES; }
    else { custom.hidden = NO; [pop selectItem:custom]; }
}

static NSString *const kSliderRowID = @"SKGyroStrengthRow";
static void GSyncSlider(NSSlider *sl) {
    NSDictionary *cur = GCurrent();
    double v = [cur[@"stabilisationEnabled"] boolValue] ? [cur[@"stabilisationSmoothness"] doubleValue] : 0;
    sl.doubleValue = v;
    NSTextField *val = objc_getAssociatedObject(sl, "sk_val");
    val.stringValue = [NSString stringWithFormat:@"%.0f", v];
}
static void GInstall(id hud) {
    NSArray *controls = RefIvar(hud, "_controls");
    NSGridView *grid = nil; NSInteger enabledRow = -1, lutRow = -1;
    for (id c in controls) {
        id p = ((id(*)(id,SEL))objc_msgSend)(c, NSSelectorFromString(@"rawParameter"));
        NSString *key = [p valueForKey:@"key"];
        for (NSView *v in ((id(*)(id,SEL))objc_msgSend)(c, NSSelectorFromString(@"controls"))) if ([v.superview isKindOfClass:[NSGridView class]]) { grid = (NSGridView *)v.superview; break; }
        if (!grid) continue;
        if ([key isEqual:@"stabilisationEnabled"] || [key isEqual:@"lutSource"]) {
            NSView *any = [((id(*)(id,SEL))objc_msgSend)(c, NSSelectorFromString(@"controls")) lastObject];
            NSGridCell *cell = [grid cellForView:any];
            NSInteger r = cell ? [grid indexOfRow:cell.row] : -1;
            if ([key isEqual:@"stabilisationEnabled"]) enabledRow = r; else lutRow = r;
        }
    }
    if (!grid || enabledRow < 0 || lutRow < 0) return;
    // already there?
    BOOL havePreset = NO;
    for (NSInteger r = 0; r < grid.numberOfRows; r++) {
        NSView *cv = [grid cellAtColumnIndex:0 rowIndex:r].contentView;
        if ([cv.identifier isEqual:kRowID]) havePreset = YES;
        if ([cv.identifier isEqual:kRowID]) { GSync((NSPopUpButton *)[grid cellAtColumnIndex:1 rowIndex:r].contentView); }
        if ([cv.identifier isEqual:kSliderRowID]) { GSyncSlider((NSSlider *)[grid cellAtColumnIndex:1 rowIndex:r].contentView); return; }
    }
    if (havePreset) return;
    // copy the look of the "LUT Source:" row
    NSTextField *refLabel = (NSTextField *)[grid cellAtColumnIndex:0 rowIndex:lutRow].contentView;
    NSPopUpButton *refPop = (NSPopUpButton *)[grid cellAtColumnIndex:1 rowIndex:lutRow].contentView;
    if (![refLabel isKindOfClass:[NSTextField class]] || ![refPop isKindOfClass:[NSPopUpButton class]]) return;
    NSTextField *label = [NSTextField labelWithString:@"Gyro Preset:"];
    label.font = refLabel.font; label.textColor = refLabel.textColor; label.alignment = refLabel.alignment;
    label.identifier = kRowID;
    NSPopUpButton *pop = [[NSPopUpButton alloc] initWithFrame:refPop.frame pullsDown:NO];
    pop.font = refPop.font; pop.controlSize = refPop.controlSize; pop.bezelStyle = refPop.bezelStyle;
    for (NSDictionary *p in GPresets()) [pop addItemWithTitle:p[@"name"]];
    [pop addItemWithTitle:@"Custom"]; [pop itemWithTitle:@"Custom"].hidden = YES;
    if (!gTarget) gTarget = [SKGyroPresetTarget new];
    pop.target = gTarget; pop.action = @selector(choose:);
    pop.toolTip = @"One-click gyro stabilisation from the gyro data in the clip";
    NSView *spacer = [[NSView alloc] initWithFrame:NSZeroRect];
    NSInteger at = enabledRow + 1;
    [grid insertRowAtIndex:at withViews:@[label, pop, [NSGridCell emptyContentView], spacer]];
    @try { [grid mergeCellsInHorizontalRange:NSMakeRange(1, 2) verticalRange:NSMakeRange(at, 1)]; } @catch (id e) {}
    NSGridCell *refCell = [grid cellForView:refPop], *newCell = [grid cellForView:pop];
    newCell.xPlacement = refCell.xPlacement; newCell.yPlacement = refCell.yPlacement; newCell.rowAlignment = refCell.rowAlignment;
    NSGridCell *lc = [grid cellForView:label], *rlc = [grid cellForView:refLabel];
    lc.xPlacement = rlc.xPlacement; lc.yPlacement = rlc.yPlacement;
    GSync(pop);
    // slider row: copy the look of the first slider row in the panel (e.g. Exposure)
    NSInteger sliderRef = -1;
    for (NSInteger r = 0; r < grid.numberOfRows; r++) if ([[grid cellAtColumnIndex:1 rowIndex:r].contentView isKindOfClass:[NSSlider class]]) { sliderRef = r; break; }
    if (sliderRef >= 0) {
        NSTextField *rl = (NSTextField *)[grid cellAtColumnIndex:0 rowIndex:sliderRef].contentView;
        NSSlider *rs = (NSSlider *)[grid cellAtColumnIndex:1 rowIndex:sliderRef].contentView;
        NSTextField *rv = (NSTextField *)[grid cellAtColumnIndex:2 rowIndex:sliderRef].contentView;
        NSTextField *l2 = [NSTextField labelWithString:@"Gyro Strength:"];
        l2.font = rl.font; l2.textColor = rl.textColor; l2.alignment = rl.alignment; l2.identifier = kSliderRowID;
        Class sc = [rs class];
        NSSlider *sl = [[sc alloc] initWithFrame:rs.frame];
        sl.controlSize = rs.controlSize; sl.minValue = 0; sl.maxValue = 100; sl.continuous = YES;
        sl.numberOfTickMarks = rs.numberOfTickMarks; sl.tickMarkPosition = rs.tickMarkPosition;
        sl.allowsTickMarkValuesOnly = NO;
        sl.target = gTarget; sl.action = @selector(strength:);
        sl.toolTip = @"Gyro stabilisation strength — 0 is off, 100 is strongest";
        NSTextField *val = [NSTextField labelWithString:@"0"];
        val.font = [rv isKindOfClass:[NSTextField class]] ? rv.font : rl.font;
        val.alignment = NSTextAlignmentRight;
        val.textColor = [NSColor labelColor];
        objc_setAssociatedObject(sl, "sk_val", val, OBJC_ASSOCIATION_RETAIN);
        NSInteger at2 = [grid indexOfRow:[grid cellForView:pop].row] + 1;
        [grid insertRowAtIndex:at2 withViews:@[l2, sl, val, [[NSView alloc] initWithFrame:NSZeroRect]]];
        NSGridCell *c1 = [grid cellForView:sl], *r1 = [grid cellForView:rs];
        c1.xPlacement = r1.xPlacement; c1.yPlacement = r1.yPlacement; c1.rowAlignment = r1.rowAlignment;
        NSGridCell *c2 = [grid cellForView:val], *r2 = [grid cellForView:rv];
        if (r2) { c2.xPlacement = r2.xPlacement; c2.yPlacement = r2.yPlacement; }
        NSGridCell *c0 = [grid cellForView:l2], *r0 = [grid cellForView:rl];
        c0.xPlacement = r0.xPlacement; c0.yPlacement = r0.yPlacement;
        GSyncSlider(sl);
    }
    GLog(@"preset + strength rows added");
}

static IMP o_refreshUI, o_rebuildUI, o_refreshUI0, o_updateUI;
static void GSchedule(id hud) {
    for (NSNumber *d in @[@0.0, @0.25]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try { GInstall(hud); } @catch (id e) { GLog([NSString stringWithFormat:@"install threw %@", e]); }
        });
    }
}
static void h_refreshUI(id self, SEL _cmd, BOOL safe) { ((void(*)(id,SEL,BOOL))o_refreshUI)(self, _cmd, safe); GSchedule(self); }
static void h_rebuildUI(id self, SEL _cmd) { ((void(*)(id,SEL))o_rebuildUI)(self, _cmd); GSchedule(self); }
static void h_refreshUI0(id self, SEL _cmd) { ((void(*)(id,SEL))o_refreshUI0)(self, _cmd); GSchedule(self); }
static void h_updateUI(id self, SEL _cmd, id a) { ((void(*)(id,SEL,id))o_updateUI)(self, _cmd, a); GSchedule(self); }
static IMP GHook(Class c, NSString *sel, IMP imp) {
    Method m = class_getInstanceMethod(c, NSSelectorFromString(sel));
    return m ? method_setImplementation(m, imp) : NULL;
}
__attribute__((visibility("default"))) void SpliceKitPlugin_init(void *api) { (void)api; }
__attribute__((constructor)) static void g_init(void) {
    Class h = objc_getClass("FFVTRAWSettingsHud");
    o_refreshUI  = GHook(h, @"_refreshUIWithIsSafeToRebuild:", (IMP)h_refreshUI);
    o_rebuildUI  = GHook(h, @"rebuildUI", (IMP)h_rebuildUI);
    o_refreshUI0 = GHook(h, @"refreshUI", (IMP)h_refreshUI0);
    o_updateUI   = GHook(h, @"updateUI:", (IMP)h_updateUI);
    GLog([NSString stringWithFormat:@"RAW Gyro v2 loaded (%d%d%d%d)", o_refreshUI != NULL, o_rebuildUI != NULL, o_refreshUI0 != NULL, o_updateUI != NULL]);
}
