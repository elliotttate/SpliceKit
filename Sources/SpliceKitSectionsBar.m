//
//  SpliceKitSectionsBar.m
//  SpliceKit
//
//  A thin color-coded bar injected above FCP's timeline showing song structure
//  sections (intro, verse, chorus, bridge, outro). Each section has its own color
//  and label. Right-click to change colors, add/remove/rename sections.
//
//  The bar is a plain NSView added as a sibling above the timeline's LKScrollView.
//  It observes the timeline's scroll position and zoom level to stay aligned.
//

#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

// On ARM64, large structs still return via objc_msgSend (hidden pointer param).
#if defined(__arm64__)
#define SEC_STRET objc_msgSend
#else
#define SEC_STRET objc_msgSend_stret
#endif

typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } SEC_CMTime;

#pragma mark - Section Model

@interface SpliceKitSection : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic) double startTime;
@property (nonatomic) double endTime;
@property (nonatomic, strong) NSColor *color;
@property (nonatomic, copy) NSString *sectionId;
@end

@implementation SpliceKitSection
- (double)duration { return _endTime - _startTime; }
- (NSDictionary *)toDict {
    CGFloat r, g, b, a;
    NSColor *rgb = [_color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    [rgb getRed:&r green:&g blue:&b alpha:&a];
    return @{
        @"label": _label ?: @"",
        @"start": @(_startTime),
        @"end": @(_endTime),
        @"color": @{@"r": @(r), @"g": @(g), @"b": @(b)},
        @"id": _sectionId ?: @"",
    };
}
+ (instancetype)fromDict:(NSDictionary *)d {
    SpliceKitSection *s = [[SpliceKitSection alloc] init];
    s.label = d[@"label"] ?: @"Section";
    s.startTime = [d[@"start"] doubleValue];
    s.endTime = [d[@"end"] doubleValue];
    s.sectionId = d[@"id"] ?: [[NSUUID UUID] UUIDString];
    NSDictionary *c = d[@"color"];
    if (c) {
        s.color = [NSColor colorWithSRGBRed:[c[@"r"] doubleValue]
                                      green:[c[@"g"] doubleValue]
                                       blue:[c[@"b"] doubleValue]
                                      alpha:1.0];
    } else {
        s.color = [self defaultColorForLabel:s.label];
    }
    return s;
}
+ (NSColor *)defaultColorForLabel:(NSString *)label {
    NSString *l = [label lowercaseString];
    // Strip trailing numbers
    while (l.length > 0 && [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[l characterAtIndex:l.length-1]])
        l = [l substringToIndex:l.length-1];
    if ([l hasPrefix:@"intro"])     return [NSColor colorWithSRGBRed:0.40 green:0.50 blue:0.60 alpha:1.0];
    if ([l hasPrefix:@"outro"])     return [NSColor colorWithSRGBRed:0.40 green:0.50 blue:0.60 alpha:1.0];
    if ([l hasPrefix:@"verse"])     return [NSColor colorWithSRGBRed:0.22 green:0.50 blue:0.85 alpha:1.0];
    if ([l hasPrefix:@"chorus"])    return [NSColor colorWithSRGBRed:0.92 green:0.55 blue:0.12 alpha:1.0];
    if ([l hasPrefix:@"bridge"])    return [NSColor colorWithSRGBRed:0.58 green:0.28 blue:0.75 alpha:1.0];
    if ([l hasPrefix:@"drop"])      return [NSColor colorWithSRGBRed:0.90 green:0.18 blue:0.18 alpha:1.0];
    if ([l hasPrefix:@"pre"])       return [NSColor colorWithSRGBRed:0.75 green:0.45 blue:0.18 alpha:1.0];
    if ([l hasPrefix:@"breakdown"]) return [NSColor colorWithSRGBRed:0.25 green:0.60 blue:0.55 alpha:1.0];
    return [NSColor colorWithSRGBRed:0.50 green:0.50 blue:0.55 alpha:1.0];
}
@end

#pragma mark - Color Presets

static NSArray<NSDictionary *> *SectionColorPresets(void) {
    return @[
        @{@"name": @"Blue (Verse)",    @"color": [NSColor colorWithSRGBRed:0.22 green:0.50 blue:0.85 alpha:1.0]},
        @{@"name": @"Orange (Chorus)", @"color": [NSColor colorWithSRGBRed:0.92 green:0.55 blue:0.12 alpha:1.0]},
        @{@"name": @"Purple (Bridge)", @"color": [NSColor colorWithSRGBRed:0.58 green:0.28 blue:0.75 alpha:1.0]},
        @{@"name": @"Gray (Intro)",    @"color": [NSColor colorWithSRGBRed:0.40 green:0.50 blue:0.60 alpha:1.0]},
        @{@"name": @"Red (Drop)",      @"color": [NSColor colorWithSRGBRed:0.90 green:0.18 blue:0.18 alpha:1.0]},
        @{@"name": @"Green",           @"color": [NSColor colorWithSRGBRed:0.20 green:0.68 blue:0.32 alpha:1.0]},
        @{@"name": @"Teal",            @"color": [NSColor colorWithSRGBRed:0.18 green:0.62 blue:0.65 alpha:1.0]},
        @{@"name": @"Pink",            @"color": [NSColor colorWithSRGBRed:0.88 green:0.32 blue:0.52 alpha:1.0]},
        @{@"name": @"Yellow",          @"color": [NSColor colorWithSRGBRed:0.90 green:0.78 blue:0.15 alpha:1.0]},
    ];
}

#pragma mark - Sections Bar View

static const CGFloat kSectionsBarHeight = 24.0;

static const CGFloat kEdgeHitZone = 3.0;  // pixels from edge to trigger resize cursor

typedef NS_ENUM(NSInteger, SBDragMode) {
    SBDragModeNone = 0,
    SBDragModeEdgeLeft,
    SBDragModeEdgeRight,
    SBDragModeMove,         // dragging the whole section
};

@interface SpliceKitSectionsBarView : NSView
@property (nonatomic, strong) NSMutableArray<SpliceKitSection *> *sections;
@property (nonatomic, weak) NSView *timelineView;  // FFProTimelineView
@property (nonatomic, weak) NSClipView *clipView;
@property (nonatomic) SpliceKitSection *clickedSection;
@property (nonatomic) SpliceKitSection *dragSection;     // section being dragged/resized
@property (nonatomic) SBDragMode dragMode;               // what kind of drag
@property (nonatomic) BOOL isDragging;
@property (nonatomic) double dragAnchorOffset;           // for move: offset from section start to click point
@property (nonatomic) NSUInteger dragInsertIndex;        // for move: where the dragged section will land
@property (nonatomic) CGFloat lastClickX;                // debug: last click X position
@property (nonatomic) CGFloat dragGhostX;                // for move: current mouse X for ghost drawing
@property (nonatomic, strong) SpliceKitSection *dragGhostSection; // copy of section being dragged (for ghost rendering)
+ (instancetype)shared;
- (void)updateFromTimeline;
- (void)setSectionsFromArray:(NSArray<NSDictionary *> *)arr;
- (NSArray<NSDictionary *> *)sectionsAsArray;
@end

@implementation SpliceKitSectionsBarView

+ (instancetype)shared {
    static SpliceKitSectionsBarView *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] initWithFrame:NSMakeRect(0, 0, 100, kSectionsBarHeight)];
    });
    return instance;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _sections = [NSMutableArray array];
        _dragInsertIndex = NSNotFound;
    }
    return self;
}

// rebuildLayers now just triggers a
// display
//
// cycle — actual rendering happens in drawRect:
- (void)rebuildLayers {
    [self setNeedsDisplay:YES];
    return;
    // Dead code below kept for reference — original CALayer approach
    // that didn't work in FCP's layer-backed hierarchy.
    // Remove old section layers
    NSArray *sublayers = [self.layer.sublayers copy];
    for (CALayer *sub in sublayers) {
        if ([sub.name hasPrefix:@"section_"] || [sub.name isEqualToString:@"sections_bg"]) {
            [sub removeFromSuperlayer];
        }
    }

    if (_sections.count == 0) return;

    CGRect bounds = self.layer.bounds;

    // Render the sections bar into an NSImage and set it as layer.contents.
    // This uses pure Cocoa drawing (NSBezierPath/NSColor) which handles
    // coordinate systems correctly in all scenarios.
    CGFloat scale = self.window.backingScaleFactor ?: 2.0;
    NSSize imageSize = bounds.size;
    if (imageSize.width <= 0 || imageSize.height <= 0) return;

    NSImage *image = [[NSImage alloc] initWithSize:imageSize];
    [image lockFocusFlipped:YES];

    // Dark background
    [[NSColor colorWithWhite:0.12 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(0, 0, imageSize.width, imageSize.height));

    NSDictionary *labelAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:10],
        NSForegroundColorAttributeName: [NSColor whiteColor],
    };

    for (SpliceKitSection *sec in _sections) {
        CGFloat x1 = [self xForTime:sec.startTime];
        CGFloat x2 = [self xForTime:sec.endTime];

        if (x2 < -10 || x1 > imageSize.width + 10) continue;
        x1 = MAX(x1, 0);
        x2 = MIN(x2, imageSize.width);
        CGFloat width = x2 - x1;
        if (width < 1) continue;

        // Colored rectangle
        NSRect rect = NSMakeRect(x1, 1, width, imageSize.height - 2);
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:3 yRadius:3];
        [sec.color setFill];
        [path fill];

        // Border
        [[sec.color blendedColorWithFraction:0.4 ofColor:[NSColor blackColor]] setStroke];
        path.lineWidth = 0.5;
        [path stroke];

        // Label text
        if (width > 20) {
            CGFloat textY = (imageSize.height - 13) / 2;
            [sec.label drawAtPoint:NSMakePoint(x1 + 5, textY) withAttributes:labelAttrs];
        }
    }

    // Bottom separator
    [[NSColor colorWithWhite:0.06 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(0, imageSize.height - 1, imageSize.width, 1));

    [image unlockFocus];

    // Set as layer contents
    self.layer.contents = image;
    self.layer.contentsScale = scale;
    self.layer.contentsGravity = kCAGravityResize;
}

#pragma mark - Coordinate Mapping

- (double)timePerPixelSeconds {
    if (!_timelineView) return 0.05;
    SEL sel = NSSelectorFromString(@"timePerPixel");
    if (![_timelineView respondsToSelector:sel]) return 0.05;
    SEC_CMTime tpp = ((SEC_CMTime (*)(id, SEL))SEC_STRET)(_timelineView, sel);
    return (tpp.timescale > 0) ? (double)tpp.value / tpp.timescale : 0.05;
}

- (CGFloat)leftPaddingPx {
    if (!_timelineView) return 43.0;
    SEL sel = NSSelectorFromString(@"leftPadding");
    if (![_timelineView respondsToSelector:sel]) return 43.0;
    // leftPadding returns CGFloat
    return ((CGFloat (*)(id, SEL))objc_msgSend)(_timelineView, sel);
}

- (CGFloat)scrollOffsetX {
    if (!_clipView) return 0;
    return _clipView.bounds.origin.x;
}

- (CGFloat)xForTime:(double)seconds {
    double tpp = [self timePerPixelSeconds];
    if (tpp <= 0) tpp = 0.05;
    return [self leftPaddingPx] + (CGFloat)(seconds / tpp) - [self scrollOffsetX];
}

- (double)timeForX:(CGFloat)x {
    double tpp = [self timePerPixelSeconds];
    if (tpp <= 0) tpp = 0.05;
    return ((double)(x + [self scrollOffsetX] - [self leftPaddingPx])) * tpp;
}

- (NSPoint)localPointForEvent:(NSEvent *)event {
    if (!event) return NSZeroPoint;

    NSWindow *eventWindow = event.window ?: self.window;
    if (!eventWindow) return event.locationInWindow;

    NSPoint screenPoint = [eventWindow convertPointToScreen:event.locationInWindow];
    if (!self.window) return screenPoint;

    NSPoint panelPoint = [self.window convertPointFromScreen:screenPoint];
    return [self convertPoint:panelPoint fromView:nil];
}

- (NSRect)screenRectForView:(NSView *)view {
    if (!view || !view.window) return NSZeroRect;
    NSRect rectInWindow = [view convertRect:view.bounds toView:nil];
    return [view.window convertRectToScreen:rectInWindow];
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;

    // Semi-transparent background so the ruler is visible behind
    [[NSColor colorWithCalibratedRed:0.12 green:0.12 blue:0.12 alpha:0.5] set];
    NSRectFill(bounds);

    if (_sections.count == 0) return;

    NSDictionary *labelAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:10],
        NSForegroundColorAttributeName: [NSColor whiteColor],
    };

    for (SpliceKitSection *sec in _sections) {
        CGFloat x1 = [self xForTime:sec.startTime];
        CGFloat x2 = [self xForTime:sec.endTime];
        if (x2 < 0 || x1 > bounds.size.width) continue;
        x1 = MAX(x1, 0);
        x2 = MIN(x2, bounds.size.width);
        CGFloat width = x2 - x1;
        if (width < 2) continue;

        // Draw colored block using the CG context directly — NSBezierPath fill
        // may be suppressed by FCP's compositing layer, but CGContext calls
        // operate on the raw backing store.
        CGContextRef cgCtx = [[NSGraphicsContext currentContext] CGContext];
        if (cgCtx) {
            NSColor *srgb = [sec.color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            CGFloat cr = 0.5, cg2 = 0.5, cb = 0.5;
            if (srgb) { cr = srgb.redComponent; cg2 = srgb.greenComponent; cb = srgb.blueComponent; }

            CGContextSaveGState(cgCtx);
            CGRect cgRect = CGRectMake(x1, 1, width, bounds.size.height - 2);
            CGPathRef roundedPath = CGPathCreateWithRoundedRect(cgRect, 3, 3, NULL);
            CGContextAddPath(cgCtx, roundedPath);
            CGContextSetRGBFillColor(cgCtx, cr, cg2, cb, 0.5);
            CGContextFillPath(cgCtx);

            // Border
            CGContextAddPath(cgCtx, roundedPath);
            CGContextSetRGBStrokeColor(cgCtx, cr * 0.6, cg2 * 0.6, cb * 0.6, 0.6);
            CGContextSetLineWidth(cgCtx, 1.0);
            CGContextStrokePath(cgCtx);
            CGPathRelease(roundedPath);
            CGContextRestoreGState(cgCtx);
        }

        // Label (clipped to section bounds so text never overflows)
        if (width > 20) {
            CGFloat textY = (bounds.size.height - 13) / 2;
            NSRect textRect = NSMakeRect(x1 + 6, textY, width - 12, 14);
            NSMutableDictionary *clippedAttrs = [labelAttrs mutableCopy];
            NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
            ps.lineBreakMode = NSLineBreakByTruncatingTail;
            clippedAttrs[NSParagraphStyleAttributeName] = ps;
            [sec.label drawInRect:textRect withAttributes:clippedAttrs];
        }

        // Draw edge drag handles (thin bright lines at section edges)
        if (cgCtx) {
            CGContextSaveGState(cgCtx);
            CGContextSetRGBFillColor(cgCtx, 1.0, 1.0, 1.0, 0.3);
            // Left edge handle
            CGContextFillRect(cgCtx, CGRectMake(x1, 2, 2, bounds.size.height - 4));
            // Right edge handle
            CGContextFillRect(cgCtx, CGRectMake(x2 - 2, 2, 2, bounds.size.height - 4));
            CGContextRestoreGState(cgCtx);
        }
    }

    // During a move drag: draw the ghost (transparent copy) at the cursor position
    // and a yellow insertion line showing where it will land
    if (_isDragging && _dragGhostSection) {
        CGContextRef cgCtx = [[NSGraphicsContext currentContext] CGContext];
        if (cgCtx) {
            // Compute ghost dimensions
            double ghostDur = _dragGhostSection.endTime - _dragGhostSection.startTime;
            double tpp = [self timePerPixelSeconds];
            if (tpp <= 0) tpp = 0.05;
            CGFloat ghostW = MAX(10, (CGFloat)(ghostDur / tpp));
            CGFloat ghostX = _dragGhostX - _dragAnchorOffset;

            // Draw ghost section (semi-transparent)
            NSColor *ghostColor = [_dragGhostSection.color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            CGFloat cr = 0.5, cg2 = 0.5, cb = 0.5;
            if (ghostColor) { cr = ghostColor.redComponent; cg2 = ghostColor.greenComponent; cb = ghostColor.blueComponent; }

            CGContextSaveGState(cgCtx);
            CGRect ghostRect = CGRectMake(ghostX, 1, ghostW, bounds.size.height - 2);
            CGPathRef ghostPath = CGPathCreateWithRoundedRect(ghostRect, 3, 3, NULL);

            // Semi-transparent fill
            CGContextSetRGBFillColor(cgCtx, cr, cg2, cb, 0.45);
            CGContextAddPath(cgCtx, ghostPath);
            CGContextFillPath(cgCtx);

            // Dashed border
            CGContextAddPath(cgCtx, ghostPath);
            CGContextSetRGBStrokeColor(cgCtx, 1.0, 1.0, 1.0, 0.6);
            CGFloat dashes[] = {4, 3};
            CGContextSetLineDash(cgCtx, 0, dashes, 2);
            CGContextSetLineWidth(cgCtx, 1.0);
            CGContextStrokePath(cgCtx);
            CGPathRelease(ghostPath);

            // Ghost label
            CGContextSetLineDash(cgCtx, 0, NULL, 0); // reset dash
            CGContextRestoreGState(cgCtx);

            if (ghostW > 20) {
                NSDictionary *ghostLabelAttrs = @{
                    NSFontAttributeName: [NSFont boldSystemFontOfSize:10],
                    NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.7],
                };
                CGFloat textY = (bounds.size.height - 13) / 2;
                [_dragGhostSection.label drawAtPoint:NSMakePoint(ghostX + 6, textY) withAttributes:ghostLabelAttrs];
            }

            // Draw insertion line at the target position
            CGFloat insertX = 0;
            if (_dragInsertIndex != NSNotFound) {
                if (_dragInsertIndex < _sections.count) {
                    insertX = [self xForTime:_sections[_dragInsertIndex].startTime];
                } else if (_sections.count > 0) {
                    insertX = [self xForTime:_sections.lastObject.endTime];
                }
            }

            CGContextSaveGState(cgCtx);
            // Bright yellow insertion line
            CGContextSetRGBFillColor(cgCtx, 1.0, 0.85, 0.0, 1.0);
            CGContextFillRect(cgCtx, CGRectMake(insertX - 1.5, 0, 3, bounds.size.height));
            // Triangle at top
            CGContextMoveToPoint(cgCtx, insertX - 5, 0);
            CGContextAddLineToPoint(cgCtx, insertX + 5, 0);
            CGContextAddLineToPoint(cgCtx, insertX, 6);
            CGContextClosePath(cgCtx);
            CGContextFillPath(cgCtx);
            CGContextRestoreGState(cgCtx);
        }
    }

    // Debug: draw a red vertical line at the last click position
    // so the user can see where the code registered their click
    if (_lastClickX > 0) {
        CGContextRef cgCtx = [[NSGraphicsContext currentContext] CGContext];
        if (cgCtx) {
            CGContextSaveGState(cgCtx);
            CGContextSetRGBFillColor(cgCtx, 1.0, 0.0, 0.0, 0.8);
            CGContextFillRect(cgCtx, CGRectMake(_lastClickX - 1, 0, 2, bounds.size.height));
            CGContextRestoreGState(cgCtx);
        }
    }
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }

#pragma mark - Drag to Resize

- (SBDragMode)dragModeAtPoint:(NSPoint)point forSection:(SpliceKitSection **)outSection {
    NSArray *sorted = [_sections sortedArrayUsingComparator:^NSComparisonResult(SpliceKitSection *a, SpliceKitSection *b) {
        return a.startTime < b.startTime ? NSOrderedAscending : NSOrderedDescending;
    }];
    if (sorted.count == 0) return SBDragModeNone;

    // Two-pass hit test:
    // 1. Very tight boundary zones (2px) for resize at shared edges
    // 2. Everything else inside a section body is move/reorder

    // Pass 1: check shared boundaries between adjacent sections (2px zone)
    for (NSUInteger i = 0; i + 1 < sorted.count; i++) {
        CGFloat boundaryX = [self xForTime:[sorted[i] endTime]];
        if (fabs(point.x - boundaryX) <= 2.0) {
            if (outSection) *outSection = sorted[i];
            return SBDragModeEdgeRight;
        }
    }
    // Outer left edge
    CGFloat firstX = [self xForTime:[sorted[0] startTime]];
    if (fabs(point.x - firstX) <= 2.0) {
        if (outSection) *outSection = sorted[0];
        return SBDragModeEdgeLeft;
    }
    // Outer right edge
    CGFloat lastX = [self xForTime:[[sorted lastObject] endTime]];
    if (fabs(point.x - lastX) <= 2.0) {
        if (outSection) *outSection = [sorted lastObject];
        return SBDragModeEdgeRight;
    }

    // Pass 2: body = move
    for (SpliceKitSection *sec in sorted) {
        CGFloat x1 = [self xForTime:sec.startTime];
        CGFloat x2 = [self xForTime:sec.endTime];
        if (point.x >= x1 && point.x <= x2) {
            if (outSection) *outSection = sec;
            return SBDragModeMove;
        }
    }

    return SBDragModeNone;
}

- (void)updateCursorForPoint:(NSPoint)point {
    SpliceKitSection *sec = nil;
    SBDragMode mode = [self dragModeAtPoint:point forSection:&sec];
    switch (mode) {
        case SBDragModeEdgeLeft:
        case SBDragModeEdgeRight:
            [[NSCursor resizeLeftRightCursor] set];
            break;
        case SBDragModeMove:
            [[NSCursor openHandCursor] set];
            break;
        default:
            [[NSCursor arrowCursor] set];
            break;
    }
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint loc = [self localPointForEvent:event];
    [self updateCursorForPoint:loc];
}

- (void)mouseDown:(NSEvent *)event {
    NSWindow *eventWindow = event.window ?: self.window;
    NSPoint winLoc = event.locationInWindow;
    NSPoint screenLoc = eventWindow ? [eventWindow convertPointToScreen:winLoc] : winLoc;
    NSPoint loc = [self localPointForEvent:event];
    NSRect panelScreenFrame = self.window ? self.window.frame : NSZeroRect;
    NSRect clipScreenFrame = [self screenRectForView:_clipView];
    NSRect timelineScreenFrame = [self screenRectForView:_timelineView];

    SpliceKit_log(@"[Sections][DOWN_RAW] eventWindow=%@ winLoc=(%.1f,%.1f) screenLoc=(%.1f,%.1f) local=(%.1f,%.1f)",
                  NSStringFromClass([eventWindow class]), winLoc.x, winLoc.y, screenLoc.x, screenLoc.y, loc.x, loc.y);

    SpliceKit_log(@"[Sections][DOWN_GEOM] panel=(x=%.1f w=%.1f) clip=(x=%.1f w=%.1f) timeline=(x=%.1f w=%.1f) deltaClip=%.1f deltaTimeline=%.1f",
                  panelScreenFrame.origin.x, panelScreenFrame.size.width,
                  clipScreenFrame.origin.x, clipScreenFrame.size.width,
                  timelineScreenFrame.origin.x, timelineScreenFrame.size.width,
                  screenLoc.x - clipScreenFrame.origin.x,
                  screenLoc.x - timelineScreenFrame.origin.x);

    _lastClickX = loc.x;  // save for debug drawing

    SpliceKit_log(@"[Sections][DOWN_DEBUG] tpp=%.6f leftPad=%.1f scrollX=%.1f",
                  [self timePerPixelSeconds], [self leftPaddingPx], [self scrollOffsetX]);
    for (SpliceKitSection *sec in _sections) {
        CGFloat x1 = [self xForTime:sec.startTime];
        CGFloat x2 = [self xForTime:sec.endTime];
        CGFloat midX = (x1 + x2) / 2.0;
        SpliceKit_log(@"[Sections][DOWN_POS] '%@' x1=%.1f x2=%.1f mid=%.1f deltaMid=%.1f (%.1fs-%.1fs)",
                      sec.label, x1, x2, midX, loc.x - midX, sec.startTime, sec.endTime);
    }

    SpliceKitSection *sec = nil;
    SBDragMode mode = [self dragModeAtPoint:loc forSection:&sec];

    if (mode == SBDragModeNone || !sec) {
        // Double-click on empty area → create a new section
        if (event.clickCount >= 2) {
            NSMenuItem *fakeItem = [[NSMenuItem alloc] init];
            fakeItem.representedObject = @([self timeForX:loc.x]);
            [self addSectionAtClick:fakeItem];
        }
        return;
    }

    NSString *modeStr = (mode == SBDragModeMove) ? @"MOVE" :
                        (mode == SBDragModeEdgeLeft) ? @"EDGE_LEFT" : @"EDGE_RIGHT";
    CGFloat x1 = [self xForTime:sec.startTime];
    CGFloat x2 = [self xForTime:sec.endTime];
    SpliceKit_log(@"[Sections][DOWN] mode=%@ section='%@' locX=%.1f x1=%.1f x2=%.1f width=%.1f",
                  modeStr, sec.label, loc.x, x1, x2, x2-x1);

    // Double-click on a section → rename it
    if (event.clickCount >= 2 && mode == SBDragModeMove) {
        _clickedSection = sec;
        [self renameSection:nil];
        return;
    }

    _dragSection = sec;
    _dragMode = mode;
    _isDragging = YES;
    if (mode == SBDragModeMove) {
        [[NSCursor closedHandCursor] set];

        // Store ghost info for rendering during drag
        _dragGhostSection = sec;
        _dragAnchorOffset = MAX(0.0, MIN(loc.x - x1, x2 - x1));
        _dragGhostX = loc.x;

        // Compute the ghost width in pixels (stays constant during drag)
        double draggedDuration = sec.endTime - sec.startTime;
        double tpp = [self timePerPixelSeconds];
        if (tpp <= 0) tpp = 0.05;
        CGFloat ghostWidthPx = MAX(10.0, (CGFloat)(draggedDuration / tpp));

        // Remove from the live array but DON'T re-tile yet.
        // The remaining sections stay at their original positions during
        // the drag so the layout doesn't jump. Re-tiling happens on drop.
        [_sections removeObject:sec];
        _dragInsertIndex = NSNotFound;
        [self setNeedsDisplay:YES];

        // Track mouse in a local loop
        NSUInteger insertIdx = 0;
        while (YES) {
            NSEvent *nextEvent = [self.window nextEventMatchingMask:
                NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
            if (!nextEvent) break;

            NSPoint eLoc = [self localPointForEvent:nextEvent];
            _dragGhostX = eLoc.x;

            // Find insertion index
            insertIdx = _sections.count;
            for (NSUInteger i = 0; i < _sections.count; i++) {
                CGFloat sx1 = [self xForTime:_sections[i].startTime];
                CGFloat sx2 = [self xForTime:_sections[i].endTime];
                CGFloat midX = (sx1 + sx2) / 2.0;
                if (eLoc.x < midX) {
                    insertIdx = i;
                    break;
                }
            }

            _dragInsertIndex = insertIdx;
            [self setNeedsDisplay:YES];

            if (nextEvent.type == NSEventTypeLeftMouseUp) break;
        }

        // Re-insert at the chosen position
        [_sections insertObject:sec atIndex:insertIdx];

        // Re-tile everything contiguously
        {
            double c = 0;
            for (SpliceKitSection *s in _sections) {
                double dur = s.endTime - s.startTime;
                s.startTime = c;
                s.endTime = c + dur;
                c += dur;
            }
        }

        // Clear ghost
        _dragGhostSection = nil;

        _isDragging = NO;
        _dragSection = nil;
        _dragMode = SBDragModeNone;
        _dragInsertIndex = NSNotFound;
        _dragAnchorOffset = 0;
        [self closeGaps];
        [self setNeedsDisplay:YES];
        [self saveSections];
        [[NSCursor arrowCursor] set];
        SpliceKit_log(@"[Sections] Moved '%@' to index %lu", sec.label, (unsigned long)insertIdx);
        return; // skip the generic tracking loop below
    }

    // For edge resize: run the standard tracking loop
    while (_isDragging) {
        NSEvent *nextEvent = [self.window nextEventMatchingMask:
            NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
        if (!nextEvent) break;

        if (nextEvent.type == NSEventTypeLeftMouseUp) {
            [self mouseUp:nextEvent];
            break;
        }
        [self mouseDragged:nextEvent];
    }
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_isDragging || !_dragSection) return;

    NSPoint loc = [self localPointForEvent:event];
    double newTime = [self timeForX:loc.x];
    if (newTime < 0) newTime = 0;

    double minDur = 0.1;
    double snapThreshold = 0.15;

    // Keep sections sorted for neighbor detection
    [_sections sortUsingComparator:^NSComparisonResult(SpliceKitSection *a, SpliceKitSection *b) {
        return a.startTime < b.startTime ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSUInteger dragIdx = [_sections indexOfObject:_dragSection];
    SpliceKitSection *leftNeighbor = (dragIdx > 0) ? _sections[dragIdx - 1] : nil;
    SpliceKitSection *rightNeighbor = (dragIdx + 1 < _sections.count) ? _sections[dragIdx + 1] : nil;

    BOOL cmdHeld = (event.modifierFlags & NSEventModifierFlagCommand) != 0;

    if (_dragMode == SBDragModeEdgeRight) {
        double clampedTime = newTime;
        clampedTime = MAX(clampedTime, _dragSection.startTime + minDur);

        if (cmdHeld) {
            // Command+drag: push ALL sections to the right, preserving their durations.
            // The dragged section grows/shrinks, everything after shifts.
            double delta = clampedTime - _dragSection.endTime;
            _dragSection.endTime = clampedTime;
            for (NSUInteger i = dragIdx + 1; i < _sections.count; i++) {
                double dur = _sections[i].endTime - _sections[i].startTime;
                _sections[i].startTime += delta;
                _sections[i].endTime = _sections[i].startTime + dur;
            }
        } else {
            // Normal drag: resize shared boundary (neighbor shrinks/grows).
            if (rightNeighbor) {
                clampedTime = MIN(clampedTime, rightNeighbor.endTime - minDur);
            }
            _dragSection.endTime = clampedTime;
            if (rightNeighbor) {
                rightNeighbor.startTime = clampedTime;
            }
        }

    } else if (_dragMode == SBDragModeEdgeLeft) {
        double clampedTime = newTime;
        clampedTime = MIN(clampedTime, _dragSection.endTime - minDur);
        if (clampedTime < 0) clampedTime = 0;

        if (cmdHeld) {
            // Command+drag: push ALL sections to the left, preserving their durations.
            double delta = clampedTime - _dragSection.startTime;
            _dragSection.startTime = clampedTime;
            for (NSInteger i = (NSInteger)dragIdx - 1; i >= 0; i--) {
                double dur = _sections[i].endTime - _sections[i].startTime;
                _sections[i].endTime += delta;
                _sections[i].startTime = _sections[i].endTime - dur;
                if (_sections[i].startTime < 0) {
                    _sections[i].startTime = 0;
                    _sections[i].endTime = dur;
                }
            }
        } else {
            // Normal drag: resize shared boundary.
            if (leftNeighbor) {
                clampedTime = MAX(clampedTime, leftNeighbor.startTime + minDur);
            }
            if (clampedTime < 0) clampedTime = 0;
            _dragSection.startTime = clampedTime;
            if (leftNeighbor) {
                leftNeighbor.endTime = clampedTime;
            }
        }

    }
    // Move is handled entirely in mouseDown:'s tracking loop — not here.

    [self closeGaps];
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    if (_isDragging && _dragSection) {
        // Re-sort and close gaps after any drag
        [self closeGaps];
        [self saveSections];
        NSString *action = (_dragMode == SBDragModeMove) ? @"Moved" : @"Resized";
        SpliceKit_log(@"[Sections] %@ '%@' to %.1f-%.1f",
                      action, _dragSection.label, _dragSection.startTime, _dragSection.endTime);
    }
    _isDragging = NO;
    _dragSection = nil;
    _dragMode = SBDragModeNone;
    _dragAnchorOffset = 0;

    NSPoint loc = [self localPointForEvent:event];
    [self updateCursorForPoint:loc];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    // Remove old tracking areas
    for (NSTrackingArea *area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }
    // Add new tracking area for the entire view
    NSTrackingArea *ta = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways
               owner:self
            userInfo:nil];
    [self addTrackingArea:ta];
}

- (void)mouseExited:(NSEvent *)event {
    [[NSCursor arrowCursor] set];
}

#pragma mark - Close Gaps (Magnetic Tiling)

// Ensures all sections are contiguous — no gaps between them.
// Each section's end == next section's start. Called after every mutation.
- (void)closeGaps {
    if (_sections.count < 2) return;

    [_sections sortUsingComparator:^NSComparisonResult(SpliceKitSection *a, SpliceKitSection *b) {
        return a.startTime < b.startTime ? NSOrderedAscending : NSOrderedDescending;
    }];

    for (NSUInteger i = 0; i < _sections.count - 1; i++) {
        SpliceKitSection *current = _sections[i];
        SpliceKitSection *next = _sections[i + 1];
        // Close the gap: extend current to meet next, or pull next back to meet current
        if (current.endTime < next.startTime) {
            // Gap exists — extend current's end to next's start
            current.endTime = next.startTime;
        }
    }
}

#pragma mark - Section Data

- (void)setSectionsFromArray:(NSArray<NSDictionary *> *)arr {
    [_sections removeAllObjects];
    for (NSDictionary *d in arr) {
        [_sections addObject:[SpliceKitSection fromDict:d]];
    }
    [self closeGaps];
    [self rebuildLayers];
}

- (NSArray<NSDictionary *> *)sectionsAsArray {
    NSMutableArray *arr = [NSMutableArray array];
    for (SpliceKitSection *s in _sections) {
        [arr addObject:[s toDict]];
    }
    return arr;
}

- (void)updateFromTimeline {
    [self rebuildLayers];
}

#pragma mark - Scroll/Zoom Observation

- (void)startObserving {
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(clipViewBoundsChanged:)
        name:NSViewBoundsDidChangeNotification
        object:_clipView];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(clipViewBoundsChanged:)
        name:NSViewFrameDidChangeNotification
        object:_clipView];
    // Also observe the timeline view frame changes (zoom)
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(clipViewBoundsChanged:)
        name:NSViewFrameDidChangeNotification
        object:_timelineView];
    _clipView.postsBoundsChangedNotifications = YES;
}

- (void)clipViewBoundsChanged:(NSNotification *)note {
    [self rebuildLayers];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Right-Click Context Menu

- (SpliceKitSection *)sectionAtPoint:(NSPoint)point {
    for (SpliceKitSection *sec in _sections) {
        CGFloat x1 = [self xForTime:sec.startTime];
        CGFloat x2 = [self xForTime:sec.endTime];
        if (point.x >= x1 && point.x <= x2) return sec;
    }
    return nil;
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint loc = [self localPointForEvent:event];
    _clickedSection = [self sectionAtPoint:loc];

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Sections"];

    if (_clickedSection) {
        // Section-specific items
        NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:_clickedSection.label
                                                        action:nil keyEquivalent:@""];
        header.enabled = NO;
        [menu addItem:header];
        [menu addItem:[NSMenuItem separatorItem]];

        // Color submenu
        NSMenuItem *colorItem = [[NSMenuItem alloc] initWithTitle:@"Change Color"
                                                           action:nil keyEquivalent:@""];
        NSMenu *colorMenu = [[NSMenu alloc] initWithTitle:@"Change Color"];
        for (NSDictionary *preset in SectionColorPresets()) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:preset[@"name"]
                                                          action:@selector(changeColor:)
                                                   keyEquivalent:@""];
            item.target = self;
            item.representedObject = preset[@"color"];
            // Color swatch
            NSImage *swatch = [[NSImage alloc] initWithSize:NSMakeSize(12, 12)];
            [swatch lockFocus];
            [preset[@"color"] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0.5, 0.5, 11, 11) xRadius:2 yRadius:2] fill];
            [swatch unlockFocus];
            item.image = swatch;
            [colorMenu addItem:item];
        }
        colorItem.submenu = colorMenu;
        [menu addItem:colorItem];

        // Rename
        NSMenuItem *rename = [[NSMenuItem alloc] initWithTitle:@"Rename Section…"
                                                        action:@selector(renameSection:)
                                                 keyEquivalent:@""];
        rename.target = self;
        [menu addItem:rename];

        // Remove
        NSMenuItem *remove = [[NSMenuItem alloc] initWithTitle:@"Remove Section"
                                                        action:@selector(removeSection:)
                                                 keyEquivalent:@""];
        remove.target = self;
        [menu addItem:remove];

        [menu addItem:[NSMenuItem separatorItem]];
    }

    // General items
    NSMenuItem *addItem = [[NSMenuItem alloc] initWithTitle:@"Add Section Here…"
                                                     action:@selector(addSectionAtClick:)
                                              keyEquivalent:@""];
    addItem.target = self;
    addItem.representedObject = @([self timeForX:loc.x]);
    [menu addItem:addItem];

    if (_sections.count > 0) {
        NSMenuItem *removeAll = [[NSMenuItem alloc] initWithTitle:@"Remove All Sections"
                                                           action:@selector(removeAllSections:)
                                                    keyEquivalent:@""];
        removeAll.target = self;
        [menu addItem:removeAll];
    }

    return menu;
}

- (void)changeColor:(NSMenuItem *)sender {
    if (!_clickedSection) return;
    _clickedSection.color = sender.representedObject;
    [self rebuildLayers];
    [self saveSections];
    SpliceKit_log(@"[Sections] Changed '%@' color", _clickedSection.label);
}

- (void)renameSection:(NSMenuItem *)sender {
    if (!_clickedSection) return;
    // Use a simple alert with text field for rename
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Rename Section";
        alert.informativeText = @"Enter a new name for this section:";
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Cancel"];
        NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
        input.stringValue = self->_clickedSection.label;
        alert.accessoryView = input;
        [alert layout];
        [alert.window makeFirstResponder:input];
        [input selectText:nil];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            NSString *newName = input.stringValue;
            if (newName.length > 0) {
                self->_clickedSection.label = newName;
                [self rebuildLayers];
                [self saveSections];
                SpliceKit_log(@"[Sections] Renamed to '%@'", newName);
            }
        }
    });
}

- (void)removeSection:(NSMenuItem *)sender {
    if (!_clickedSection) return;
    SpliceKit_log(@"[Sections] Removed '%@'", _clickedSection.label);
    [_sections removeObject:_clickedSection];
    _clickedSection = nil;
    [self closeGaps];
    [self rebuildLayers];
    [self saveSections];
}

- (void)addSectionAtClick:(NSMenuItem *)sender {
    // New sections always snap to the end of the last existing section
    // (or start at 0 if no sections exist). Default duration is 10 seconds.
    double snapStart = 0;
    double snapEnd = 10.0;

    if (_sections.count > 0) {
        // Sort and find the end of the last section
        [_sections sortUsingComparator:^NSComparisonResult(SpliceKitSection *a, SpliceKitSection *b) {
            return a.startTime < b.startTime ? NSOrderedAscending : NSOrderedDescending;
        }];
        snapStart = _sections.lastObject.endTime;
        snapEnd = snapStart + 10.0;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Add Section";
        alert.informativeText = [NSString stringWithFormat:
            @"New section: %.1fs – %.1fs\nEnter a label:", snapStart, snapEnd];
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Cancel"];
        NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
        input.stringValue = @"New Section";
        alert.accessoryView = input;
        [alert layout];
        [alert.window makeFirstResponder:input];
        [input selectText:nil];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            NSString *name = input.stringValue;
            if (name.length == 0) name = @"Section";

            SpliceKitSection *sec = [[SpliceKitSection alloc] init];
            sec.label = name;
            sec.startTime = snapStart;
            sec.endTime = snapEnd;
            sec.color = [SpliceKitSection defaultColorForLabel:name];
            sec.sectionId = [[NSUUID UUID] UUIDString];

            [self->_sections addObject:sec];
            [self->_sections sortUsingComparator:^NSComparisonResult(SpliceKitSection *a, SpliceKitSection *b) {
                return a.startTime < b.startTime ? NSOrderedAscending : NSOrderedDescending;
            }];
            [self closeGaps];
            [self rebuildLayers];
            [self saveSections];
            SpliceKit_log(@"[Sections] Added '%@' at %.1f-%.1fs (snapped)", name, snapStart, snapEnd);
        }
    });
}

- (void)removeAllSections:(NSMenuItem *)sender {
    [_sections removeAllObjects];
    [self rebuildLayers];
    [self saveSections];
    SpliceKit_log(@"[Sections] Removed all sections");
}

#pragma mark - Persistence (saved inside FCP library bundle)

// Returns the path to the sections JSON file inside the FCP library bundle.
// Format: <library.fcpbundle>/SpliceKit/<sequence-uid>.sections.json
// This ensures sections travel with the library when it's moved or shared.
- (NSString *)sectionsFilePath {
    id tm = SpliceKit_getActiveTimelineModule();
    if (!tm) return nil;
    id sequence = ((id (*)(id, SEL))objc_msgSend)(tm, @selector(sequence));
    if (!sequence) return nil;

    // Get the sequence's unique identifier — try multiple selectors
    // to find a truly unique ID that won't collide across projects.
    NSString *seqUID = nil;
    for (NSString *selName in @[@"uid", @"uniqueIdentifier", @"identifier", @"uuid"]) {
        SEL sel = NSSelectorFromString(selName);
        if ([sequence respondsToSelector:sel]) {
            id val = ((id (*)(id, SEL))objc_msgSend)(sequence, sel);
            if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) {
                seqUID = val;
                break;
            }
        }
    }
    // Fallback: use displayName + a hash of the library path for uniqueness
    if (!seqUID) {
        SEL dnSel = NSSelectorFromString(@"displayName");
        NSString *name = [sequence respondsToSelector:dnSel]
            ? ((id (*)(id, SEL))objc_msgSend)(sequence, dnSel) : @"unknown";
        seqUID = [NSString stringWithFormat:@"%@-%lx", name, (unsigned long)[sequence hash]];
    }
    if (!seqUID) return nil;

    // Find the library URL by walking: sequence → library → URL
    id library = nil;
    SEL libSel = NSSelectorFromString(@"library");
    if ([sequence respondsToSelector:libSel]) {
        library = ((id (*)(id, SEL))objc_msgSend)(sequence, libSel);
    }
    if (!library) {
        // Fallback: get from FFLibraryDocument
        Class libDocClass = objc_getClass("FFLibraryDocument");
        if (libDocClass) {
            SEL copySel = NSSelectorFromString(@"copyActiveLibraries");
            if ([libDocClass respondsToSelector:copySel]) {
                NSArray *libs = ((id (*)(id, SEL))objc_msgSend)((id)libDocClass, copySel);
                if ([libs isKindOfClass:[NSArray class]] && libs.count > 0) {
                    library = libs[0];
                }
            }
        }
    }

    NSURL *libURL = nil;
    SEL urlSel = NSSelectorFromString(@"URL");
    if (library && [library respondsToSelector:urlSel]) {
        libURL = ((id (*)(id, SEL))objc_msgSend)(library, urlSel);
    }
    if (!libURL) {
        // Fallback to Application Support
        NSString *fallback = [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Application Support/SpliceKit/sections"];
        [[NSFileManager defaultManager] createDirectoryAtPath:fallback
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        return [fallback stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.sections.json", seqUID]];
    }

    // Create SpliceKit subfolder inside the library bundle
    NSString *skDir = [[libURL path] stringByAppendingPathComponent:@"SpliceKit"];
    [[NSFileManager defaultManager] createDirectoryAtPath:skDir
                              withIntermediateDirectories:YES attributes:nil error:nil];

    return [skDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.sections.json", seqUID]];
}

- (void)saveSections {
    NSString *path = [self sectionsFilePath];
    if (!path) return;

    NSArray *arr = [self sectionsAsArray];
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:arr
                                                  options:NSJSONWritingPrettyPrinted
                                                    error:&error];
    if (data) {
        [data writeToFile:path atomically:YES];
        SpliceKit_log(@"[Sections] Saved %lu sections to %@", (unsigned long)arr.count, path);
    }
}

- (void)loadSections {
    NSString *path = [self sectionsFilePath];
    if (!path) return;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;

    NSError *error = nil;
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if ([arr isKindOfClass:[NSArray class]] && arr.count > 0) {
        [self setSectionsFromArray:arr];
        SpliceKit_log(@"[Sections] Loaded %lu sections from %@", (unsigned long)arr.count, path);
    }
}

@end

#pragma mark - Installation into FCP's View Hierarchy

static BOOL sSectionsBarInstalled = NO;
static NSPanel *sSectionsPanel = nil;

static BOOL SpliceKit_findTimelineContextInView(NSView *view,
                                                NSInteger depth,
                                                NSView **timelineViewOut,
                                                NSClipView **clipViewOut,
                                                NSView **scrollViewOut) {
    if (!view || depth > 20) return NO;

    NSString *className = NSStringFromClass([view class]);
    if ([className isEqualToString:@"FFProTimelineView"]) {
        if (timelineViewOut) *timelineViewOut = view;
        if ([view.superview isKindOfClass:[NSClipView class]]) {
            NSClipView *clipView = (NSClipView *)view.superview;
            if (clipViewOut) *clipViewOut = clipView;
            if (scrollViewOut) *scrollViewOut = clipView.superview;
        }
        return YES;
    }

    for (NSView *subview in view.subviews) {
        if (SpliceKit_findTimelineContextInView(subview,
                                                depth + 1,
                                                timelineViewOut,
                                                clipViewOut,
                                                scrollViewOut)) {
            return YES;
        }
    }

    return NO;
}

static void SpliceKit_updateSectionsPanelPosition(void) {
    if (!sSectionsPanel || !sSectionsBarInstalled) return;

    NSWindow *parentWindow = nil;
    for (NSWindow *w in [NSApp windows]) {
        if ([NSStringFromClass([w class]) containsString:@"PEWindow"]) {
            parentWindow = w;
            break;
        }
    }
    if (!parentWindow) return;

    // Find the scroll view containing the timeline
    NSView *scrollView = nil;
    SpliceKit_findTimelineContextInView(parentWindow.contentView,
                                        0,
                                        NULL,
                                        NULL,
                                        &scrollView);
    if (!scrollView) return;

    // Position the panel at the top of the scroll view in screen coordinates
    NSRect scrollScreenFrame = [scrollView convertRect:scrollView.bounds toView:nil];
    scrollScreenFrame = [parentWindow convertRectToScreen:scrollScreenFrame];

    NSRect panelFrame = NSMakeRect(
        scrollScreenFrame.origin.x,
        scrollScreenFrame.origin.y + scrollScreenFrame.size.height - kSectionsBarHeight,
        scrollScreenFrame.size.width,
        kSectionsBarHeight
    );
    [sSectionsPanel setFrame:panelFrame display:YES];
}

static void SpliceKit_installSectionsBar(void) {
    if (sSectionsBarInstalled) return;

    SpliceKit_executeOnMainThread(^{
        NSWindow *parentWindow = nil;
        for (NSWindow *w in [NSApp windows]) {
            if ([NSStringFromClass([w class]) containsString:@"PEWindow"]) {
                parentWindow = w;
                break;
            }
        }
        if (!parentWindow) {
            SpliceKit_log(@"[Sections] PEWindow not found");
            return;
        }

        // Find FFProTimelineView
        NSView *timelineView = nil;
        NSClipView *clipView = nil;
        NSView *scrollView = nil;
        SpliceKit_findTimelineContextInView(parentWindow.contentView,
                                            0,
                                            &timelineView,
                                            &clipView,
                                            &scrollView);

        if (!timelineView || !scrollView) {
            SpliceKit_log(@"[Sections] FFProTimelineView not found");
            return;
        }

        // Create the sections bar view
        SpliceKitSectionsBarView *bar = [SpliceKitSectionsBarView shared];
        bar.timelineView = timelineView;
        bar.clipView = clipView;

        // Create a borderless floating panel (like transcript/caption panels)
        // that sits exactly over the top of the timeline scroll area.
        NSRect scrollScreenFrame = [scrollView convertRect:scrollView.bounds toView:nil];
        scrollScreenFrame = [parentWindow convertRectToScreen:scrollScreenFrame];

        NSRect panelFrame = NSMakeRect(
            scrollScreenFrame.origin.x,
            scrollScreenFrame.origin.y + scrollScreenFrame.size.height - kSectionsBarHeight,
            scrollScreenFrame.size.width,
            kSectionsBarHeight
        );

        // Use a custom NSPanel subclass that accepts mouse events and can become key
        sSectionsPanel = [[NSPanel alloc] initWithContentRect:panelFrame
                                                    styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        sSectionsPanel.level = NSNormalWindowLevel; // same level as FCP window
        sSectionsPanel.backgroundColor = [NSColor clearColor];
        sSectionsPanel.opaque = NO;
        sSectionsPanel.hasShadow = NO;
        sSectionsPanel.ignoresMouseEvents = NO;
        sSectionsPanel.acceptsMouseMovedEvents = YES;
        sSectionsPanel.floatingPanel = YES;
        sSectionsPanel.becomesKeyOnlyIfNeeded = YES;
        sSectionsPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                            NSWindowCollectionBehaviorTransient;

        bar.frame = NSMakeRect(0, 0, panelFrame.size.width, kSectionsBarHeight);
        bar.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        sSectionsPanel.contentView = bar;

        [parentWindow addChildWindow:sSectionsPanel ordered:NSWindowAbove];
        [sSectionsPanel orderFront:nil];

        [bar startObserving];
        [bar loadSections];

        // Observe parent window resize/move to reposition the panel
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResizeNotification
            object:parentWindow queue:nil usingBlock:^(NSNotification *note) {
            SpliceKit_updateSectionsPanelPosition();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidMoveNotification
            object:parentWindow queue:nil usingBlock:^(NSNotification *note) {
            SpliceKit_updateSectionsPanelPosition();
        }];

        sSectionsBarInstalled = YES;
        SpliceKit_log(@"[Sections] Panel installed at %@", NSStringFromRect(panelFrame));
    });
}

#pragma mark - Bridge Handlers

NSDictionary *SpliceKit_handleSectionsShow(NSDictionary *params) {
    SpliceKit_installSectionsBar();

    NSArray *sections = params[@"sections"];
    if ([sections isKindOfClass:[NSArray class]] && sections.count > 0) {
        SpliceKit_executeOnMainThread(^{
            [[SpliceKitSectionsBarView shared] setSectionsFromArray:sections];
            [[SpliceKitSectionsBarView shared] saveSections];
        });
    } else {
        // Try loading from saved state
        SpliceKit_executeOnMainThread(^{
            [[SpliceKitSectionsBarView shared] loadSections];
        });
    }

    return @{
        @"status": @"ok",
        @"installed": @(sSectionsBarInstalled),
        @"sectionCount": @([SpliceKitSectionsBarView shared].sections.count),
    };
}

NSDictionary *SpliceKit_handleSectionsHide(NSDictionary *params) {
    if (!sSectionsBarInstalled) return @{@"status": @"ok", @"message": @"not installed"};

    SpliceKit_executeOnMainThread(^{
        if (sSectionsPanel) {
            [sSectionsPanel.parentWindow removeChildWindow:sSectionsPanel];
            [sSectionsPanel orderOut:nil];
            sSectionsPanel = nil;
        }
        sSectionsBarInstalled = NO;
    });

    return @{@"status": @"ok", @"message": @"hidden"};
}

NSDictionary *SpliceKit_handleSectionsSetColor(NSDictionary *params) {
    NSString *sectionId = params[@"id"];
    NSString *label = params[@"label"];
    NSDictionary *color = params[@"color"];
    if (!color) return @{@"error": @"color required {r, g, b}"};

    NSColor *nsColor = [NSColor colorWithSRGBRed:[color[@"r"] doubleValue]
                                           green:[color[@"g"] doubleValue]
                                            blue:[color[@"b"] doubleValue]
                                           alpha:1.0];

    __block BOOL found = NO;
    SpliceKit_executeOnMainThread(^{
        for (SpliceKitSection *sec in [SpliceKitSectionsBarView shared].sections) {
            BOOL match = NO;
            if (sectionId && [sec.sectionId isEqualToString:sectionId]) match = YES;
            if (!match && label && [sec.label caseInsensitiveCompare:label] == NSOrderedSame) match = YES;
            if (match) {
                sec.color = nsColor;
                found = YES;
            }
        }
        if (found) {
            [[SpliceKitSectionsBarView shared] setNeedsDisplay:YES];
            [[SpliceKitSectionsBarView shared] saveSections];
        }
    });

    return found ? @{@"status": @"ok"} : @{@"error": @"section not found"};
}

NSDictionary *SpliceKit_handleSectionsAdd(NSDictionary *params) {
    NSString *label = params[@"label"] ?: @"Section";
    double start = [params[@"start"] doubleValue];
    double end = [params[@"end"] doubleValue];
    if (end <= start) return @{@"error": @"end must be > start"};

    NSDictionary *color = params[@"color"];

    SpliceKitSection *sec = [[SpliceKitSection alloc] init];
    sec.label = label;
    sec.startTime = start;
    sec.endTime = end;
    sec.sectionId = [[NSUUID UUID] UUIDString];
    if (color) {
        sec.color = [NSColor colorWithSRGBRed:[color[@"r"] doubleValue]
                                        green:[color[@"g"] doubleValue]
                                         blue:[color[@"b"] doubleValue]
                                        alpha:1.0];
    } else {
        sec.color = [SpliceKitSection defaultColorForLabel:label];
    }

    SpliceKit_installSectionsBar();

    SpliceKit_executeOnMainThread(^{
        SpliceKitSectionsBarView *bar = [SpliceKitSectionsBarView shared];
        [bar.sections addObject:sec];
        [bar.sections sortUsingComparator:^NSComparisonResult(SpliceKitSection *a, SpliceKitSection *b) {
            return a.startTime < b.startTime ? NSOrderedAscending : NSOrderedDescending;
        }];
        [bar setNeedsDisplay:YES];
        [bar saveSections];
    });

    return @{@"status": @"ok", @"id": sec.sectionId, @"label": label};
}

NSDictionary *SpliceKit_handleSectionsRemove(NSDictionary *params) {
    NSString *sectionId = params[@"id"];
    NSString *label = params[@"label"];
    BOOL all = [params[@"all"] boolValue];

    __block NSUInteger removed = 0;
    SpliceKit_executeOnMainThread(^{
        SpliceKitSectionsBarView *bar = [SpliceKitSectionsBarView shared];
        if (all) {
            removed = bar.sections.count;
            [bar.sections removeAllObjects];
        } else {
            NSMutableArray *toRemove = [NSMutableArray array];
            for (SpliceKitSection *sec in bar.sections) {
                if (sectionId && [sec.sectionId isEqualToString:sectionId]) [toRemove addObject:sec];
                else if (label && [sec.label caseInsensitiveCompare:label] == NSOrderedSame) [toRemove addObject:sec];
            }
            removed = toRemove.count;
            [bar.sections removeObjectsInArray:toRemove];
        }
        [bar setNeedsDisplay:YES];
        [bar saveSections];
    });

    return @{@"status": @"ok", @"removed": @(removed)};
}

NSDictionary *SpliceKit_handleSectionsGet(NSDictionary *params) {
    return @{
        @"status": @"ok",
        @"installed": @(sSectionsBarInstalled),
        @"sections": [[SpliceKitSectionsBarView shared] sectionsAsArray],
    };
}
