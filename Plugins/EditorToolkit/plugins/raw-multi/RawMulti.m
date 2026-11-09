// RAW Multi v17: with several clips selected whose RAW values differ, keep the normal
// slider / menu / reset (not a dead "Multiple Values" label) so a change or reset applies
// to all selected clips — like DaVinci Resolve — and show "Multiple" over the value.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
static void MLog(NSString *s) {
    FILE *f = fopen([[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/rawmulti.log"] fileSystemRepresentation], "a");
    if (f) { fprintf(f, "%s %s\n", [NSDate date].description.UTF8String, s.UTF8String); fclose(f); }
}
static id RefIvar(id obj, const char *name) {
    Ivar iv = obj ? class_getInstanceVariable(object_getClass(obj), name) : NULL;
    if (!iv) return nil;
    return (__bridge id)(*(void **)((char *)(__bridge void *)obj + ivar_getOffset(iv)));
}
static id MHud(void) { return ((id(*)(id,SEL))objc_msgSend)(objc_getClass("FFVTRAWSettingsHud"), NSSelectorFromString(@"shared")); }
static NSMutableSet *gDiffKeys;

// A label drawn over the value box; ignores the mouse so dragging/typing still reaches the control.
@interface SKMultiOverlay : NSTextField @end
@implementation SKMultiOverlay
- (NSView *)hitTest:(NSPoint)p { return nil; }
@end

@interface SKMultiReset : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, weak) id param;
@property (nonatomic, weak) id origTarget;
@property (nonatomic) SEL origAction;
@end
@implementation SKMultiReset
- (void)resetAll:(id)sender {
    id hud = MHud(); id ctrl = RefIvar(hud, "_controller");
    id value = nil;
    @try { if ([self.param respondsToSelector:NSSelectorFromString(@"initialValue")]) value = [self.param valueForKey:@"initialValue"]; } @catch (id e) {}
    if (![value isKindOfClass:[NSNumber class]] && ![value isKindOfClass:[NSString class]]) value = nil;
    if (value && ctrl) {
      @try {
        ((void(*)(id,SEL,id))objc_msgSend)(hud, NSSelectorFromString(@"settingsChangeBegin:"), nil);
        BOOL ok = ((BOOL(*)(id,SEL,id,id))objc_msgSend)(ctrl, @selector(setValue:forKey:), value, self.key);
        ((void(*)(id,SEL,id))objc_msgSend)(hud, NSSelectorFromString(@"settingsChangeEnd:"), nil);
        ((void(*)(id,SEL))objc_msgSend)(hud, NSSelectorFromString(@"refreshOrRebuildUI"));
        MLog([NSString stringWithFormat:@"reset %@ -> %@ on all selected (%d)", self.key, value, ok]);
      } @catch (id e) { MLog([NSString stringWithFormat:@"reset %@ threw %@", self.key, e]); }
    } else {
        MLog([NSString stringWithFormat:@"reset %@: no default value, skipped", self.key]);
        NSBeep();
    }
}
@end
static char kOverlayKey, kResetKey, kObsKey, kColorKey, kPopKey, kEditObsKey;
// Put the overlay exactly over the value box (same parent, so it scrolls with it).
// A small rounded "chip" over the value, styled like Apple's pro-app value fields.
static void MPlace(NSTextField *ov, NSView *v) {
    NSView *host = v.superview;
    if (!host || NSIsEmptyRect(v.frame)) return;
    NSRect r;
    if ([v isKindOfClass:[NSPopUpButton class]]) {
        // Menus keep their own look: cover only the title part of the menu (its blue arrows stay
        // visible) with the menu's own grey and font, so it reads like a native "Mixed" menu.
        NSPopUpButton *p = (NSPopUpButton *)v;
        r = NSInsetRect(v.frame, 0, 1);
        r.size.width -= 17;                       // leave the arrow button visible
        ov.font = p.font;
        ov.alignment = NSTextAlignmentLeft;
        ov.textColor = [NSColor labelColor];
        ov.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.35 alpha:1].CGColor;
        ov.layer.cornerRadius = 3.5;
        ov.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
        for (NSString *t in @[@" Multiple", @" Mixed", @" –"]) {
            ov.stringValue = t;
            if ([t sizeWithAttributes:@{NSFontAttributeName: ov.font}].width + 2 <= r.size.width) break;
        }
        ov.frame = NSIntegralRect(r);
        if (ov.superview != host) { [ov removeFromSuperview]; [host addSubview:ov positioned:NSWindowAbove relativeTo:nil]; }
        return;
    } else {
        NSFont *f = [(NSTextField *)v font] ?: [NSFont systemFontOfSize:11];
        CGFloat h = ceil(f.boundingRectForFont.size.height) + 1;
        r = v.frame;
        r.origin.y = NSMidY(v.frame) - h / 2; r.size.height = h;
        ov.font = f;
        ov.alignment = NSTextAlignmentCenter;
        ov.textColor = [NSColor secondaryLabelColor];
        ov.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.24 alpha:1].CGColor;
        ov.layer.cornerRadius = 3.5;
        ov.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    }
    ov.stringValue = @"--";
    ov.frame = NSIntegralRect(r);
    if (ov.superview != host) { [ov removeFromSuperview]; [host addSubview:ov positioned:NSWindowAbove relativeTo:nil]; }
}

static char kDashFlag;
static IMP MSuperDrawTitle(Class c) {
    while (c && ![NSStringFromClass(c) hasPrefix:@"SKDash_"]) c = class_getSuperclass(c);   // skip any KVO subclass on top
    return class_getMethodImplementation(class_getSuperclass(c), @selector(drawTitle:withFrame:inView:));
}
static NSRect MDrawTitle(NSButtonCell *self, SEL _cmd, NSAttributedString *title, NSRect frame, NSView *view) {
    NSAttributedString *t = title;
    if ([objc_getAssociatedObject(self, &kDashFlag) boolValue] && title.length) {
        NSDictionary *attrs = [title attributesAtIndex:0 effectiveRange:NULL];
        t = [[NSAttributedString alloc] initWithString:@"--" attributes:attrs];
    }
    return ((NSRect(*)(id,SEL,id,NSRect,id))MSuperDrawTitle(object_getClass(self)))(self, _cmd, t, frame, view);
}
// Give this one cell a private subclass whose only change is drawing "--" when flagged.
static void MDashCell(NSCell *cell, BOOL on) {
    if (!cell) return;
    Class cur = object_getClass(cell);
    if (![NSStringFromClass(cur) hasPrefix:@"SKDash_"]) {
        if (!on) return;
        NSString *name = [@"SKDash_" stringByAppendingString:NSStringFromClass(cur)];
        Class sub = NSClassFromString(name);
        if (!sub) {
            sub = objc_allocateClassPair(cur, name.UTF8String, 0);
            if (!sub) return;
            Method m = class_getInstanceMethod(cur, @selector(drawTitle:withFrame:inView:));
            class_addMethod(sub, @selector(drawTitle:withFrame:inView:), (IMP)MDrawTitle, method_getTypeEncoding(m));
            objc_registerClassPair(sub);
        }
        object_setClass(cell, sub);
    }
    objc_setAssociatedObject(cell, &kDashFlag, @(on), OBJC_ASSOCIATION_RETAIN);
}

static void MMark(id control) {
    @try {
        id param = ((id(*)(id,SEL))objc_msgSend)(control, NSSelectorFromString(@"rawParameter"));
        NSString *key = [param valueForKey:@"key"];
        BOOL differs = key && [gDiffKeys containsObject:key];
        NSArray *views = ((id(*)(id,SEL))objc_msgSend)(control, NSSelectorFromString(@"controls"));
        for (NSView *v in views) {
            if ([v isKindOfClass:[NSPopUpButton class]]) {
                // Menus: only the DRAWN title becomes "--" (like DaVinci Resolve). The menu's items and
                // selection are untouched, so Final Cut never sees anything it doesn't expect.
                NSPopUpButton *p = (NSPopUpButton *)v;
                MDashCell(p.cell, differs);
                [p setNeedsDisplay:YES];
                continue;
            }
            BOOL isValue = [v isKindOfClass:[NSTextField class]] && [(NSTextField *)v isEditable];
            // the ↺ button on every row (sliders AND menus) — Final Cut titles them "Button"
            NSString *act = [v isKindOfClass:[NSButton class]] ? NSStringFromSelector([(NSButton *)v action]) : @"";
            BOOL isReset = [v isKindOfClass:[NSButton class]] && ![v isKindOfClass:[NSPopUpButton class]] &&
                           ([[(NSButton *)v title] isEqualToString:@"Button"] || [act hasPrefix:@"reset"]);
            if (isReset) { static NSMutableSet *seen; if (!seen) seen = [NSMutableSet set]; NSString *k2 = [NSString stringWithFormat:@"%@:%@", key, act]; if (![seen containsObject:k2]) { [seen addObject:k2]; MLog([NSString stringWithFormat:@"reset button %@ action=%@", key, act]); } }
            if (isValue) {
                SKMultiOverlay *ov = objc_getAssociatedObject(v, &kOverlayKey);
                if (differs) {
                    if (!ov) {
                        ov = [SKMultiOverlay labelWithString:@"Multiple"];
                        ov.usesSingleLineMode = YES; ov.lineBreakMode = NSLineBreakByClipping;
                        ov.drawsBackground = NO; ov.bezeled = NO; ov.bordered = NO;
                        ov.wantsLayer = YES;
                        ov.layer.cornerRadius = 3.5;
                        ov.layer.masksToBounds = YES;
                        objc_setAssociatedObject(v, &kOverlayKey, ov, OBJC_ASSOCIATION_RETAIN);
                        __weak NSView *wv = v; __weak SKMultiOverlay *wov = ov;
                        if ([v isKindOfClass:[NSTextField class]]) {
                            id tok = [[NSNotificationCenter defaultCenter] addObserverForName:NSControlTextDidBeginEditingNotification object:v queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { wov.hidden = YES; (void)wv; }];
                            objc_setAssociatedObject(ov, &kEditObsKey, tok, OBJC_ASSOCIATION_RETAIN);
                        }
                    }
                    ov.toolTip = @"Multiple Values — change it to set all selected clips";
                    if (!objc_getAssociatedObject(ov, &kObsKey)) {
                        v.postsFrameChangedNotifications = YES;
                        __weak SKMultiOverlay *wov = ov; __weak NSView *wv = v;
                        id tok = [[NSNotificationCenter defaultCenter] addObserverForName:NSViewFrameDidChangeNotification object:v queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { if (wov && wv && !wov.hidden) MPlace(wov, wv); }];
                        objc_setAssociatedObject(ov, &kObsKey, tok, OBJC_ASSOCIATION_RETAIN);
                    }
                    MPlace(ov, v);
                    for (NSNumber *d in @[@0.05, @0.3, @1.0]) {
                        __weak SKMultiOverlay *wov = ov; __weak NSView *wv = v;
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (wov && wv && !wov.hidden) MPlace(wov, wv); });
                    }
                    ov.hidden = NO;
                } else if (ov) {
                    ov.hidden = YES;
                }
            } else if (isReset) {
                NSButton *b = (NSButton *)v;
                SKMultiReset *rs = objc_getAssociatedObject(b, &kResetKey);
                if (differs) {
                    if (!rs) {
                        rs = [SKMultiReset new];
                        rs.origTarget = b.target; rs.origAction = b.action;
                        objc_setAssociatedObject(b, &kResetKey, rs, OBJC_ASSOCIATION_RETAIN);
                    }
                    rs.key = key; rs.param = param;
                    b.target = rs; b.action = @selector(resetAll:);
                    b.enabled = YES;
                } else if (rs) {
                    b.target = rs.origTarget; b.action = rs.origAction;
                    objc_setAssociatedObject(b, &kResetKey, nil, OBJC_ASSOCIATION_RETAIN);
                }
            }
        }
    } @catch (id e) { MLog([NSString stringWithFormat:@"mark threw %@", e]); }
}

static IMP o_equal, o_rebuild, o_update, o_setItems, o_refreshUI;
static void h_setItems(id self, SEL _cmd, id items) { [gDiffKeys removeAllObjects]; ((void(*)(id,SEL,id))o_setItems)(self, _cmd, items); }
static void h_rebuild(id self, SEL _cmd) { [gDiffKeys removeAllObjects]; ((void(*)(id,SEL))o_rebuild)(self, _cmd); }
static BOOL h_equal(id self, SEL _cmd, id key, id perController) {
    BOOL really = ((BOOL(*)(id,SEL,id,id))o_equal)(self, _cmd, key, perController);
    if (!really && key) [gDiffKeys addObject:key];
    return YES;
}
static void h_update(id self, SEL _cmd, id arg) {
    ((void(*)(id,SEL,id))o_update)(self, _cmd, arg);
    MMark(self);
}
static void h_refreshUI(id self, SEL _cmd, BOOL safe) {
    ((void(*)(id,SEL,BOOL))o_refreshUI)(self, _cmd, safe);
    dispatch_async(dispatch_get_main_queue(), ^{ for (id c in (NSArray *)RefIvar(self, "_controls")) MMark(c); });
}
__attribute__((visibility("default"))) void SpliceKitPlugin_init(void *api) { (void)api; }
__attribute__((constructor)) static void m_init(void) {
    gDiffKeys = [NSMutableSet set];
    Class c = objc_getClass("FFVTRAWMultiSettingsController"), pc = objc_getClass("FFRAWProcessorControl"), hc = objc_getClass("FFVTRAWSettingsHud");
    if (!c || !pc || !hc) { MLog(@"missing classes"); return; }
    struct { Class cls; const char *sel; IMP imp; IMP *orig; } hooks[] = {
        { c,  "areSettingsEqualForKey:settingsPerController:", (IMP)h_equal, &o_equal },
        { c,  "_rebuild", (IMP)h_rebuild, &o_rebuild },
        { pc, "update:", (IMP)h_update, &o_update },
        { hc, "setAssetItems:", (IMP)h_setItems, &o_setItems },
        { hc, "_refreshUIWithIsSafeToRebuild:", (IMP)h_refreshUI, &o_refreshUI },
    };
    int okc = 0;
    for (size_t i = 0; i < sizeof(hooks)/sizeof(hooks[0]); i++) {
        Method m = class_getInstanceMethod(hooks[i].cls, sel_registerName(hooks[i].sel));
        if (m) { *hooks[i].orig = method_setImplementation(m, hooks[i].imp); okc++; } else MLog([NSString stringWithFormat:@"missing %s", hooks[i].sel]);
    }
    MLog([NSString stringWithFormat:@"RAW Multi v17 loaded (%d/5 hooks)", okc]);
}
