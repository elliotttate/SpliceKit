// Flip: native-style horizontal / vertical flip buttons inside the inspector's Transform section
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void FL(NSString *s) {
    FILE *f = fopen([[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/flip.log"] fileSystemRepresentation], "a");
    if (f) { fprintf(f, "%s %s\n", [NSDate date].description.UTF8String, s.UTF8String); fclose(f); }
}
static id IV(id o, const char *n) {
    Ivar iv = o ? class_getInstanceVariable(object_getClass(o), n) : NULL;
    if (!iv) return nil; const char *t = ivar_getTypeEncoding(iv);
    return (t && t[0] == '@') ? object_getIvar(o, iv) : nil;
}
static NSTextField *FindLabel(NSView *v, NSString *t) {
    if ([v isKindOfClass:[NSTextField class]] && [((NSTextField *)v).stringValue isEqualToString:t] && [NSStringFromClass([v class]) hasPrefix:@"OZLabel"]) return (id)v;
    for (NSView *c in v.subviews) { NSTextField *r = FindLabel(c, t); if (r) return r; }
    return nil;
}
static NSTextField *FindClass(NSView *v, NSString *cls) {
    if ([NSStringFromClass([v class]) isEqualToString:cls]) return (id)v;
    for (NSView *c in v.subviews) { NSTextField *r = FindClass(c, cls); if (r) return r; }
    return nil;
}
// value scrubber in the same row as a label ("Scale X" / "Scale Y")
static NSTextField *ScrubberFor(NSView *root, NSString *label) {
    NSTextField *l = FindLabel(root, label);
    NSView *row = l; for (int i = 0; i < 3 && row; i++) row = row.superview;  // label > flipped > box > row
    return row ? FindClass(row, @"PISegmentedScrubber") : nil;
}

#pragma mark - button

@interface SKFlipButton : NSButton
@property BOOL vertical, on, hover;
@end
@implementation SKFlipButton
- (void)updateTrackingAreas {
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect owner:self userInfo:nil]];
    [super updateTrackingAreas];
}
- (void)mouseEntered:(NSEvent *)e { self.hover = YES; [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)e { self.hover = NO; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)r {
    // resolve-style square button, drawn with fcp inspector colours
    NSRect b = NSInsetRect(self.bounds, 0.5, 0.5);
    BOOL down = self.isHighlighted;
    NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:b xRadius:4 yRadius:4];
    NSColor *accent = [NSColor controlAccentColor];
    if (self.on) { [[accent colorWithAlphaComponent:down ? 0.45 : 0.30] setFill]; [box fill]; }
    else if (down) { [[NSColor colorWithWhite:1 alpha:0.12] setFill]; [box fill]; }
    else if (self.hover) { [[NSColor colorWithWhite:1 alpha:0.05] setFill]; [box fill]; }
    [(self.on ? [accent colorWithAlphaComponent:0.9] : [NSColor colorWithWhite:1 alpha:self.hover ? 0.32 : 0.20]) setStroke];
    box.lineWidth = 1; [box stroke];
    NSColor *ink = self.on ? [NSColor whiteColor] : [NSColor colorWithWhite:self.enabled ? 0.72 : 0.40 alpha:1];
    [ink set];
    CGFloat cx = round(NSMidX(self.bounds)) , cy = round(NSMidY(self.bounds));
    CGFloat t = 4.0, h = 3.5, gap = 1.5;   // triangle depth, half-height, gap to centre line
    NSBezierPath *p = [NSBezierPath bezierPath];
    if (!self.vertical) {
        NSRectFill(NSMakeRect(cx - 0.5, cy - 5.5, 1, 11));
        [p moveToPoint:NSMakePoint(cx - gap - t, cy - h)]; [p lineToPoint:NSMakePoint(cx - gap, cy)]; [p lineToPoint:NSMakePoint(cx - gap - t, cy + h)]; [p closePath];
        [p moveToPoint:NSMakePoint(cx + gap + t, cy - h)]; [p lineToPoint:NSMakePoint(cx + gap, cy)]; [p lineToPoint:NSMakePoint(cx + gap + t, cy + h)]; [p closePath];
    } else {
        NSRectFill(NSMakeRect(cx - 5.5, cy - 0.5, 11, 1));
        [p moveToPoint:NSMakePoint(cx - h, cy - gap - t)]; [p lineToPoint:NSMakePoint(cx, cy - gap)]; [p lineToPoint:NSMakePoint(cx + h, cy - gap - t)]; [p closePath];
        [p moveToPoint:NSMakePoint(cx - h, cy + gap + t)]; [p lineToPoint:NSMakePoint(cx, cy + gap)]; [p lineToPoint:NSMakePoint(cx + h, cy + gap + t)]; [p closePath];
    }
    [p fill];
}
@end

#pragma mark - row

static const NSInteger kRowTag = 0x5F11B;
static double ReadScale(NSTextField *s);
@interface SKFlipTarget : NSObject
@property (weak) NSView *root;
@property (weak) SKFlipButton *h, *v;
@end
@implementation SKFlipTarget
- (void)refresh {
    NSTextField *sx = ScrubberFor(self.root, @"Scale X"), *sy = ScrubberFor(self.root, @"Scale Y");
    if (sx) { self.h.on = ReadScale(sx) < 0; [self.h setNeedsDisplay:YES]; }
    if (sy) { self.v.on = ReadScale(sy) < 0; [self.v setNeedsDisplay:YES]; }
}
static double ReadScale(NSTextField *s) {
    id sv = [s respondsToSelector:NSSelectorFromString(@"scrubberValue")] ? [s performSelector:NSSelectorFromString(@"scrubberValue")] : nil;
    return [sv respondsToSelector:@selector(doubleValue)] ? [sv doubleValue] : s.doubleValue;
}
- (void)flip:(SKFlipButton *)b {
    @try {
        NSTextField *s = ScrubberFor(self.root, b.vertical ? @"Scale Y" : @"Scale X");
        id ctl = s.target;
        if (!s || !ctl) { FL(@"no scale scrubber"); return; }
        double v = ReadScale(s);
        if (v == 0) return;
        double nv = -v;
        // 1) the same path as typing a value into the field: scrubber value + controller action, wrapped as one undoable edit
        SEL setSV = NSSelectorFromString(@"setScrubberValue:");
        if ([s respondsToSelector:setSV]) [s performSelector:setSV withObject:@(nv)];
        s.doubleValue = nv;
        SEL st = NSSelectorFromString(@"startSegmentedScrubberAction:"), en = NSSelectorFromString(@"endSegmentedScrubberAction:");
        if ([ctl respondsToSelector:st]) ((void(*)(id,SEL,id))objc_msgSend)(ctl, st, s);
        ((void(*)(id,SEL,id))objc_msgSend)(ctl, NSSelectorFromString(@"setChannelValueAction:"), s);
        if ([ctl respondsToSelector:en]) ((void(*)(id,SEL,id))objc_msgSend)(ctl, en, s);
        if ([ctl respondsToSelector:NSSelectorFromString(@"update")]) ((void(*)(id,SEL))objc_msgSend)(ctl, NSSelectorFromString(@"update"));
        double after = ReadScale(s);
        FL([NSString stringWithFormat:@"flip %@ via action: %.2f -> want %.2f, channel now %.2f", b.vertical ? @"V" : @"H", v, nv, after]);
        // 2) fallback: write the channel directly through the controller
        if (fabs(after - nv) > 0.01) {
            SEL conv = NSSelectorFromString(@"convertToChannelValueFor:");
            double cv = [ctl respondsToSelector:conv] ? ((double(*)(id,SEL,double))objc_msgSend)(ctl, conv, nv) : nv / 100.0;
            if ([ctl respondsToSelector:st]) ((void(*)(id,SEL,id))objc_msgSend)(ctl, st, s);
            ((void(*)(id,SEL,double))objc_msgSend)(ctl, NSSelectorFromString(@"setChannelValue:"), cv);
            if ([ctl respondsToSelector:en]) ((void(*)(id,SEL,id))objc_msgSend)(ctl, en, s);
            ((void(*)(id,SEL))objc_msgSend)(ctl, NSSelectorFromString(@"update"));
            FL([NSString stringWithFormat:@"flip %@ via setChannelValue:%.4f -> channel now %.2f", b.vertical ? @"V" : @"H", cv, ReadScale(s)]);
        }
    } @catch (id e) { FL([NSString stringWithFormat:@"flip threw %@", e]); }
    dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
}
@end

// ---------- image orientation (0 / 90 right / 180 / 90 left), done with fcp's own rotation + scale ----------
static void SetScrub(NSTextField *s, double nv) {
    id ctl = s.target; if (!s || !ctl) return;
    SEL setSV = NSSelectorFromString(@"setScrubberValue:");
    if ([s respondsToSelector:setSV]) [s performSelector:setSV withObject:@(nv)];
    s.doubleValue = nv;
    SEL st = NSSelectorFromString(@"startSegmentedScrubberAction:"), en = NSSelectorFromString(@"endSegmentedScrubberAction:");
    if ([ctl respondsToSelector:st]) ((void(*)(id,SEL,id))objc_msgSend)(ctl, st, s);
    ((void(*)(id,SEL,id))objc_msgSend)(ctl, NSSelectorFromString(@"setChannelValueAction:"), s);
    if ([ctl respondsToSelector:en]) ((void(*)(id,SEL,id))objc_msgSend)(ctl, en, s);
    if ([ctl respondsToSelector:NSSelectorFromString(@"update")]) ((void(*)(id,SEL))objc_msgSend)(ctl, NSSelectorFromString(@"update"));
}
static const double kOrientAngle[4] = { 0, -90, 180, 90 };          // fcp rotation: positive = counter-clockwise
static NSString *const kOrientTitle[4] = { @"0°", @"90° right", @"180°", @"90° left" };
static int OrientFromRotation(double rot) {
    long q = lround(rot / 90.0); int m = (int)(((q % 4) + 4) % 4);    // 0, +90, 180, +270
    return m == 0 ? 0 : m == 1 ? 3 : m == 2 ? 2 : 1;
}
static id OCall(id o, NSString *sel) { SEL s = NSSelectorFromString(sel); return (o && [o respondsToSelector:s]) ? ((id(*)(id,SEL))objc_msgSend)(o, s) : nil; }
static NSSize SquareSize(id props) {
    SEL s = NSSelectorFromString(@"squareFrameBounds");
    if (!props || ![props respondsToSelector:s]) return NSZeroSize;
    return ((CGRect(*)(id,SEL))objc_msgSend)(props, s).size;
}
// how much bigger/smaller fcp's spatial conform makes the picture once it is turned 90 degrees
static double ConformRatio(NSView *root, BOOL fromOdd, BOOL toOdd) {
    if (fromOdd == toOdd) return 1;
    id tm = OCall(OCall([NSApp delegate], @"activeEditorContainer"), @"timelineModule");
    id seq = OCall(tm, @"sequence");
    NSArray *sel = OCall(tm, @"selectedItems");
    id clip = [sel isKindOfClass:[NSArray class]] ? sel.firstObject : nil;
    NSSize src = SquareSize(OCall(clip, @"videoProps")), dst = SquareSize(OCall(seq, @"videoProps"));
    NSString *type = @"Fill";
    NSView *top = root; while (top.superview) top = top.superview;
    NSTextField *tl = FindLabel(top, @"Spatial Conform");
    if (tl) { NSView *sec = tl; for (int i = 0; i < 4 && sec; i++) sec = sec.superview;
        NSPopUpButton *p = nil; NSMutableArray *q = [NSMutableArray arrayWithObject:sec];
        while (q.count && !p) { NSView *v = q.firstObject; [q removeObjectAtIndex:0]; if ([v isKindOfClass:[NSPopUpButton class]]) p = (id)v; else [q addObjectsFromArray:v.subviews]; }
        if (p.titleOfSelectedItem) type = p.titleOfSelectedItem; }
    FL([NSString stringWithFormat:@"orientation conform: src %@ dst %@ type %@ clip %@", NSStringFromSize(src), NSStringFromSize(dst), type, [clip class]]);
    if (src.width <= 0 || src.height <= 0 || dst.width <= 0 || dst.height <= 0 || [type isEqualToString:@"None"]) return 1;
    BOOL fit = [type isEqualToString:@"Fit"];
    double sw = fromOdd ? src.height : src.width, sh = fromOdd ? src.width : src.height;
    double tw = toOdd ? src.height : src.width, th = toOdd ? src.width : src.height;
    double s0 = fit ? MIN(dst.width / sw, dst.height / sh) : MAX(dst.width / sw, dst.height / sh);
    double s1 = fit ? MIN(dst.width / tw, dst.height / th) : MAX(dst.width / tw, dst.height / th);
    return s1 / s0;
}
@interface SKOrientTarget : NSObject
@property (weak) NSView *root;
@property (weak) NSPopUpButton *popup;
@property CGFloat right;
@end
static void HugTitle(NSPopUpButton *p, CGFloat right) {
    NSString *t = p.titleOfSelectedItem ?: @"";
    CGFloat w = ceil([t sizeWithAttributes:@{NSFontAttributeName: p.font ?: [NSFont systemFontOfSize:13]}].width) + 16;
    NSRect f = p.frame; f.size.width = w; f.origin.x = right - w; p.frame = f;
}
@implementation SKOrientTarget
- (void)refresh {
    NSTextField *r = ScrubberFor(self.root, @"Rotation");
    if (!r || !self.popup) return;
    [self.popup selectItemAtIndex:OrientFromRotation(ReadScale(r))];
    if (self.right > 0) HugTitle(self.popup, self.right);
}
- (void)choose:(NSPopUpButton *)p {
    @try {
        int to = (int)p.indexOfSelectedItem;
        NSTextField *r = ScrubberFor(self.root, @"Rotation"), *sx = ScrubberFor(self.root, @"Scale X"), *sy = ScrubberFor(self.root, @"Scale Y");
        if (!r || to < 0 || to > 3) { FL(@"orientation: no rotation field"); return; }
        double rot = ReadScale(r);
        int from = OrientFromRotation(rot);
        if (from == to) return;
        double fine = rot - 90.0 * lround(rot / 90.0);          // keep any small manual tilt the user added
        double target = kOrientAngle[to] + fine;
        double delta = target - rot;
        double k = ConformRatio(self.root, from % 2 == 1, to % 2 == 1);
        id seq = OCall(OCall(OCall([NSApp delegate], @"activeEditorContainer"), @"timelineModule"), @"sequence");
        SEL ab = NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:"), ae = NSSelectorFromString(@"actionEnd:save:error:");
        BOOL wrap = seq && [seq respondsToSelector:ab] && [seq respondsToSelector:ae];
        if (wrap) ((void(*)(id,SEL,id,id,BOOL))objc_msgSend)(seq, ab, @"Image Orientation", nil, NO);
        @try {
            SetScrub(r, rot + delta);
            if (fabs(k - 1) > 1e-4 && sx && sy) { SetScrub(sx, ReadScale(sx) * k); SetScrub(sy, ReadScale(sy) * k); }
        } @finally {
            if (wrap) { NSError *e = nil; ((BOOL(*)(id,SEL,id,BOOL,NSError **))objc_msgSend)(seq, ae, @"Image Orientation", YES, &e); }
        }
        FL([NSString stringWithFormat:@"orientation %@ -> %@: rotation %.2f -> %.2f (now %.2f), scale x%.4f", kOrientTitle[from], kOrientTitle[to], rot, rot + delta, ReadScale(r), k]);
    } @catch (id e) { FL([NSString stringWithFormat:@"orientation threw %@", e]); }
    dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
}
@end

static char kTargetKey;
static char kOrientKey;
static __weak SKOrientTarget *gOrient; static __weak SKFlipTarget *gFlip;

static void CopyFlags(NSView *src, NSView *dst) {
    for (NSString *p in @[@"isRow", @"isSelectable", @"noDividerLine", @"drawsBrick", @"isBrick", @"isInnerGroup", @"isOuterGroup", @"isAlternatingBlock", @"recursiveNoDividerLineEnabled"]) {
        SEL g = NSSelectorFromString(p);
        NSString *setter = [NSString stringWithFormat:@"set%@%@:", [[p substringToIndex:1] uppercaseString], [p substringFromIndex:1]];
        SEL s = NSSelectorFromString(setter);
        if ([src respondsToSelector:g] && [dst respondsToSelector:s])
            ((void(*)(id,SEL,BOOL))objc_msgSend)(dst, s, ((BOOL(*)(id,SEL))objc_msgSend)(src, g));
    }
    dst.autoresizingMask = src.autoresizingMask;
}
static NSView *MakeRow(NSView *anchorRow, NSView *root) {
    // same two-level structure as a native row: outer wrapper (draws the divider) > inner row
    Class FV = objc_getClass("OZFlippedView");
    NSView *wrapSrc = anchorRow.superview;
    NSView *wrap = [[FV alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(anchorRow.frame), NSHeight(anchorRow.frame))];
    NSView *row = [[FV alloc] initWithFrame:wrap.bounds];
    CopyFlags(wrapSrc, wrap);
    CopyFlags(anchorRow, row);
    [wrap addSubview:row];
    // native rows get a 1px separator along their top edge; match it exactly
    NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(wrap.bounds), 1)];
    line.boxType = NSBoxCustom; line.borderWidth = 0; line.titlePosition = NSNoTitle;
    line.fillColor = [NSColor colorWithSRGBRed:30/255.0 green:30/255.0 blue:30/255.0 alpha:1];
    line.autoresizingMask = NSViewWidthSizable;
    [wrap addSubview:line];
    wrap.identifier = @"SKFlipRow";
    // label: clone the native "Anchor" label so font/colour/insets match exactly
    NSTextField *src = FindLabel(anchorRow, @"Anchor");
    NSTextField *label = nil;
    if (src) {
        NSError *err = nil;
        NSData *d = [NSKeyedArchiver archivedDataWithRootObject:src requiringSecureCoding:NO error:&err];
        NSKeyedUnarchiver *u = d ? [[NSKeyedUnarchiver alloc] initForReadingFromData:d error:&err] : nil;
        u.requiresSecureCoding = NO;
        label = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey];
        [u finishDecoding];
        if (label) { label.target = nil; label.action = NULL; label.editable = NO; label.selectable = NO; }
    }
    if (!label) { label = [NSTextField labelWithString:@""]; label.font = src.font; label.textColor = src.textColor; }
    label.stringValue = @"Flip";
    NSRect lf = src ? [src convertRect:src.bounds toView:anchorRow] : NSMakeRect(21, 0, 110, 24);
    label.frame = lf;
    [row addSubview:label];
    // buttons sit where the value column starts (same x as the sliders), one per axis
    NSView *paramBox = nil; for (NSView *c in anchorRow.subviews) if (NSMinX(c.frame) > 100) paramBox = c;
    // right-align the pair with the value numbers (same right edge as the rotation / scale values)
    CGFloat valueRight = 161;
    NSTextField *rs = FindClass(paramBox, @"PISegmentedScrubber");
    if (rs) valueRight = NSMaxX(rs.frame);
    NSView *rotBox = nil; NSTextField *rl = FindLabel(root, @"Rotation");
    if (rl) { NSView *rr = rl; for (int i = 0; i < 3 && rr; i++) rr = rr.superview; for (NSView *c in rr.subviews) if (NSMinX(c.frame) > 100) rotBox = c; }
    NSTextField *rv = rotBox ? FindClass(rotBox, @"PISegmentedScrubber") : nil;
    if (rv) valueRight = NSMaxX(rv.frame);
    // nudge so the pair spans the value + unit column (ends level with the % / ° signs)
    CGFloat x0 = (paramBox ? NSMinX(paramBox.frame) : 131) + valueRight + 6 - (20 + 6 + 20);
    SKFlipTarget *t = [SKFlipTarget new]; t.root = root;
    SKFlipButton *h = [[SKFlipButton alloc] initWithFrame:NSMakeRect(x0, 3, 20, 18)];
    SKFlipButton *v = [[SKFlipButton alloc] initWithFrame:NSMakeRect(x0 + 26, 3, 20, 18)];
    v.vertical = YES;
    for (SKFlipButton *b in @[h, v]) {
        b.bordered = NO; b.title = @""; b.buttonType = NSButtonTypeMomentaryChange;
        b.target = t; b.action = @selector(flip:);
        b.toolTip = b.vertical ? @"Flip Vertical" : @"Flip Horizontal";
        [row addSubview:b];
    }
    t.h = h; t.v = v;
    objc_setAssociatedObject(wrap, &kTargetKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [t refresh];
    return wrap;
}

static NSPopUpButton *FindPopup(NSView *v) {
    if ([v isKindOfClass:[NSPopUpButton class]]) return (id)v;
    for (NSView *c in v.subviews) { NSPopUpButton *p = FindPopup(c); if (p) return p; }
    return nil;
}
static NSView *MakeOrientRow(NSView *anchorRow, NSView *root) {
    NSView *wrap = MakeRow(anchorRow, root);              // same wrapper, divider and cloned label as the flip row
    NSView *row = wrap.subviews.firstObject;
    objc_setAssociatedObject(wrap, &kTargetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (NSView *c in [row.subviews copy]) if ([c isKindOfClass:[SKFlipButton class]]) [c removeFromSuperview];
    for (NSView *c in row.subviews) if ([c isKindOfClass:[NSTextField class]]) ((NSTextField *)c).stringValue = @"Image Orientation";
    wrap.identifier = @"SKOrientRow";
    // the pop-up: a copy of fcp's own Spatial Conform "Type" pop-up, so font, arrows and spacing match exactly
    NSView *top = root; while (top.superview) top = top.superview;
    NSTextField *tl = FindLabel(top, @"Spatial Conform");
    NSView *sec = tl; for (int i = 0; i < 4 && sec; i++) sec = sec.superview;
    NSPopUpButton *src = sec ? FindPopup(sec) : nil;
    NSPopUpButton *p = nil;
    CGFloat right = 131 + 172, y = 4, h = 16;
    if (src) {
        NSView *srcRow = src; while (srcRow && NSWidth(srcRow.frame) < 380) srcRow = srcRow.superview;
        NSRect f = [src convertRect:src.bounds toView:srcRow];
        right = NSMaxX(f); y = NSMinY(f); h = NSHeight(f);
        @try {
            NSData *d = [NSKeyedArchiver archivedDataWithRootObject:src requiringSecureCoding:NO error:nil];
            NSKeyedUnarchiver *u = d ? [[NSKeyedUnarchiver alloc] initForReadingFromData:d error:nil] : nil;
            u.requiresSecureCoding = NO;
            p = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey];
            [u finishDecoding];
        } @catch (id e) { p = nil; }
    }
    if (![p isKindOfClass:[NSPopUpButton class]]) {
        p = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, y, 80, h) pullsDown:NO];
        p.bordered = NO; p.font = [NSFont systemFontOfSize:13]; p.controlSize = NSControlSizeSmall;
    }
    [p removeAllItems];
    for (int i = 0; i < 4; i++) [p addItemWithTitle:kOrientTitle[i]];
    [p sizeToFit];
    NSRect pf = p.frame; pf.size.height = h; pf.origin.y = y; pf.origin.x = right - NSWidth(pf);
    p.frame = pf;
    p.autoresizingMask = NSViewMinXMargin;
    SKOrientTarget *t = [SKOrientTarget new]; t.root = root; t.popup = p; t.right = right;
    p.target = t; p.action = @selector(choose:);
    [row addSubview:p];
    objc_setAssociatedObject(wrap, &kOrientKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gOrient = t;
    [t refresh];
    return wrap;
}

static void LogCtl(id c, NSString *ind, int d) {
    if (d > 4) return;
    NSView *v = IV(c, "_pView");
    FL([NSString stringWithFormat:@"%@%@ view=%@ %@ hidden=%d", ind, [c class], [v class], NSStringFromRect(v.frame), v.hidden]);
    if ([c respondsToSelector:@selector(subcontrollers)]) for (id s in [c performSelector:@selector(subcontrollers)]) LogCtl(s, [ind stringByAppendingString:@"  "], d + 1);
}


// move the new row so it sits right under Rotation (above Scale), keeping fcp's own ordering in sync
static void PlaceAfter(id group, id ctl, NSView *row, NSString *afterLabel) {
    @try {
        NSView *box = row.superview;
        NSTextField *rl = FindLabel(box, afterLabel);
        if (!box || !rl) { FL(@"no rotation row"); return; }
        NSView *rotView = rl; while (rotView && rotView.superview != box) rotView = rotView.superview;   // direct child of the rows box
        NSMutableArray *ctls = IV(group, "_pControllers");
        NSUInteger ri = NSNotFound;
        for (NSUInteger i = 0; i < ctls.count; i++) if (IV(ctls[i], "_pView") == rotView) { ri = i; break; }
        if (ri == NSNotFound || ![ctls isKindOfClass:[NSMutableArray class]]) { FL(@"rotation controller not found"); return; }
        CGFloat y0 = NSMaxY(rotView.frame), h = NSHeight(row.frame);
        [ctls removeObject:ctl];
        [ctls insertObject:ctl atIndex:ri + 1];
        [row removeFromSuperview];
        [box addSubview:row positioned:NSWindowAbove relativeTo:rotView];
        for (NSView *v in box.subviews) {
            if (v == row || NSMinY(v.frame) < y0 - 0.5) continue;
            [v setFrameOrigin:NSMakePoint(NSMinX(v.frame), NSMinY(v.frame) + h)];
        }
        [row setFrameOrigin:NSMakePoint(NSMinX(row.frame), y0)];
        for (id c in ctls) if ([c respondsToSelector:NSSelectorFromString(@"updateViewFinalFrame")]) ((void(*)(id,SEL))objc_msgSend)(c, NSSelectorFromString(@"updateViewFinalFrame"));
        [box setNeedsDisplay:YES];
        FL([NSString stringWithFormat:@"placed flip row at y=%.0f (after rotation idx %lu)", y0, (unsigned long)ri]);
    } @catch (id e) { FL([NSString stringWithFormat:@"place threw %@", e]); }
}

static void Install(id folderCtl) {
    @try {
        NSView *root = IV(folderCtl, "_pView");
        for (int i = 0; i < 5 && root && !FindLabel(root, @"Anchor"); i++) root = root.superview;
        if (!root) { FL(@"no root view"); return; }
        NSTextField *old = FindLabel(root, @"Flip");
        if (old) {
            NSView *oldRow = old.superview.superview;
            BOOL mine = NO; for (NSView *c in old.superview.subviews) if ([c isKindOfClass:[SKFlipButton class]]) mine = YES;
            if (mine) return;
            // a row from an older build of this plugin: take it out so the current one replaces it
            id oc = [oldRow respondsToSelector:@selector(viewController)] ? [oldRow performSelector:@selector(viewController)] : nil;
            id og = IV(oc, "_pParentController");
            if (og && oc) ((void(*)(id,SEL,id))objc_msgSend)(og, NSSelectorFromString(@"removeController:"), oc);
            [oldRow removeFromSuperview];
            FL(@"replaced older flip row");
        }
        NSTextField *anchor = FindLabel(root, @"Anchor");
        if (!anchor) { FL([NSString stringWithFormat:@"no anchor row in %@ %@ subs=%lu", [root class], NSStringFromRect(root.frame), (unsigned long)root.subviews.count]); return; }
        NSView *anchorRow = anchor; for (int i = 0; i < 3; i++) anchorRow = anchorRow.superview;   // 385x24 controller view
        id anchorCtl = [anchorRow respondsToSelector:@selector(viewController)] ? [anchorRow performSelector:@selector(viewController)] : nil;
        id group = nil;
        group = IV(anchorCtl, "_pParentController");
        if (group && IV(group, "_pView") == anchorRow.superview) group = IV(group, "_pParentController");   // skip the anchor's own compound wrapper
        FL([NSString stringWithFormat:@"anchorCtl=%@ group=%@", [anchorCtl class], [group class]]);
        FL([NSString stringWithFormat:@"rows group %@ view %@", [group class], NSStringFromRect(((NSView *)IV(group, "_pView")).frame)]);
        NSView *row = MakeRow(anchorRow, root);
        Class VC = objc_getClass("OZViewController");
        id ctx = IV(folderCtl, "_pBuildContext");
        id ctl = ((id(*)(id,SEL,id,id))objc_msgSend)([VC alloc], NSSelectorFromString(@"initWithView:context:"), row, ctx);
        NSView *inner = row.subviews.firstObject;   // (row = wrapper; first subview = inner row)
        if (ctl && [inner respondsToSelector:@selector(setViewController:)]) [inner performSelector:@selector(setViewController:) withObject:ctl];
        if (group && ctl) {
            ((void(*)(id,SEL,id,BOOL))objc_msgSend)(group, NSSelectorFromString(@"addController:appendSubview:"), ctl, YES);
            PlaceAfter(group, ctl, row, @"Rotation");
            gFlip = objc_getAssociatedObject(row, &kTargetKey);
            FL([NSString stringWithFormat:@"added row ctl %@ row frame %@ superview %@ %@", ctl, NSStringFromRect(row.frame), [row.superview class], NSStringFromRect(row.superview.frame)]);
            if (!FindLabel(root, @"Image Orientation")) {
                NSView *orow = MakeOrientRow(anchorRow, root);
                id octl = ((id(*)(id,SEL,id,id))objc_msgSend)([VC alloc], NSSelectorFromString(@"initWithView:context:"), orow, ctx);
                NSView *oinner = orow.subviews.firstObject;
                if (octl && [oinner respondsToSelector:@selector(setViewController:)]) [oinner performSelector:@selector(setViewController:) withObject:octl];
                if (octl) {
                    ((void(*)(id,SEL,id,BOOL))objc_msgSend)(group, NSSelectorFromString(@"addController:appendSubview:"), octl, YES);
                    PlaceAfter(group, octl, orow, @"Anchor");
                    FL([NSString stringWithFormat:@"added orientation row %@", NSStringFromRect(orow.frame)]);
                }
            }
        }
    } @catch (id e) { FL([NSString stringWithFormat:@"install threw %@", e]); }
}

static IMP o_build, o_update, o_angUpd, o_dblUpd;
static BOOL gRefreshQueued;
static void QueueRefresh(id ctl) {
    if (gRefreshQueued) return;
    NSView *v = IV(ctl, "_pView");
    NSView *root = gOrient.root ?: gFlip.root;
    if (!v || !root || ![v isDescendantOf:root]) return;
    gRefreshQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ gRefreshQueued = NO; [gOrient refresh]; [gFlip refresh]; });
}
static void h_angUpd(id self, SEL _cmd) { ((void(*)(id,SEL))o_angUpd)(self, _cmd); QueueRefresh(self); }
static void h_dblUpd(id self, SEL _cmd) { ((void(*)(id,SEL))o_dblUpd)(self, _cmd); QueueRefresh(self); }
static void h_build(id self, SEL _cmd) {
    ((void(*)(id,SEL))o_build)(self, _cmd);
    __weak id w = self;
    dispatch_async(dispatch_get_main_queue(), ^{ if (w) Install(w); });
}
static void h_update(id self, SEL _cmd) {
    ((void(*)(id,SEL))o_update)(self, _cmd);
    NSView *root = IV(self, "_pView");
    for (int i = 0; i < 5 && root && !FindLabel(root, @"Anchor"); i++) root = root.superview;
    NSTextField *l = FindLabel(root, @"Flip");
    NSView *row = l.superview.superview;
    SKFlipTarget *t = objc_getAssociatedObject(row, &kTargetKey);
    [t refresh];
    NSTextField *ol = FindLabel(root, @"Image Orientation");
    SKOrientTarget *ot = objc_getAssociatedObject(ol.superview.superview, &kOrientKey);
    [ot refresh];
}
__attribute__((visibility("default"))) void SpliceKitPlugin_init(void *api) { (void)api; }
__attribute__((constructor)) static void flip_init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class c = objc_getClass("FFHeXForm3DEffectFolderController");
        Method mb = class_getInstanceMethod(c, @selector(didBuildUI));
        Method mu = class_getInstanceMethod(c, NSSelectorFromString(@"update"));
        // only hook this class's own implementations (it overrides both)
        o_build = method_setImplementation(mb, (IMP)h_build);
        o_update = method_setImplementation(mu, (IMP)h_update);
        Method ma = class_getInstanceMethod(objc_getClass("OZChanAngle3DController"), NSSelectorFromString(@"update"));
        Method md = class_getInstanceMethod(objc_getClass("OZChanDoubleController"), NSSelectorFromString(@"update"));
        if (ma) o_angUpd = method_setImplementation(ma, (IMP)h_angUpd);
        if (md) o_dblUpd = method_setImplementation(md, (IMP)h_dblUpd);
        [[NSNotificationCenter defaultCenter] addObserverForName:@"SKFlipTest" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            for (NSWindow *w in NSApp.windows) { NSTextField *l = FindLabel(w.contentView, @"Flip"); if (!l) continue;
                for (NSView *c in l.superview.subviews) if ([c isKindOfClass:[SKFlipButton class]] && ((SKFlipButton *)c).vertical == [n.object isEqual:@"V"]) { [(NSButton *)c performClick:nil]; return; } }
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:@"SKFlipTestDisclose" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            for (NSWindow *w in NSApp.windows) { NSTextField *l = FindLabel(w.contentView, @"Scale (All)"); if (!l) continue;
                for (NSView *c in l.superview.subviews) if ([c isKindOfClass:[NSButton class]] && [(NSButton *)c action] == NSSelectorFromString(@"toggleDisclosure:")) { [(NSButton *)c performClick:nil]; FL(@"toggled scale disclosure"); return; } }
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:@"SKOrientTest" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            for (NSWindow *w in NSApp.windows) { NSTextField *l = FindLabel(w.contentView, @"Image Orientation"); if (!l) continue;
                NSPopUpButton *p = FindPopup(l.superview); if (!p) return;
                [p selectItemAtIndex:[n.object integerValue]]; [p sendAction:p.action to:p.target]; return; }
        }];
        FL(@"flip loaded");
    });
}
