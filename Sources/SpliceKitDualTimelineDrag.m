//
//  SpliceKitDualTimelineDrag.m
//  Cross-window timeline dragging for the dual timeline feature.
//
//  TimelineKit keeps ordinary timeline drags on an internal "move layers in
//  place" path. That never becomes an AppKit drag session, so another timeline
//  window cannot participate as a drop target. This module promotes a local
//  drag into a real NSDragging session once the cursor leaves the source
//  editor window, reusing FCP's native timeline pasteboard payload on
//  NSPasteboardNameDrag.
//

#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP sOriginalTLKDragItems = NULL;
static IMP sOriginalTLKDragOrAcceptDrop = NULL;
static IMP sOriginalTLKStopHandling = NULL;

static const void *kSpliceKitDualTimelineDragSavedStateKey = &kSpliceKitDualTimelineDragSavedStateKey;
static const void *kSpliceKitDualTimelineDragPromotedKey = &kSpliceKitDualTimelineDragPromotedKey;
static const void *kSpliceKitDualTimelineDragSourceKey = &kSpliceKitDualTimelineDragSourceKey;

static NSWindow *SpliceKit_dualTimelineDragWindowForContainer(id container) {
    if (!container) return nil;

    SEL windowSel = NSSelectorFromString(@"window");
    if ([container respondsToSelector:windowSel]) {
        id window = ((id (*)(id, SEL))objc_msgSend)(container, windowSel);
        if ([window isKindOfClass:[NSWindow class]]) {
            return (NSWindow *)window;
        }
    }

    if ([container respondsToSelector:@selector(view)]) {
        id view = ((id (*)(id, SEL))objc_msgSend)(container, @selector(view));
        if ([view respondsToSelector:@selector(window)]) {
            id window = ((id (*)(id, SEL))objc_msgSend)(view, @selector(window));
            if ([window isKindOfClass:[NSWindow class]]) {
                return (NSWindow *)window;
            }
        }
    }

    return nil;
}

static id SpliceKit_dualTimelineDragTimelineModuleForContainer(id container) {
    if (!container) return nil;
    SEL timelineModuleSel = NSSelectorFromString(@"timelineModule");
    if ([container respondsToSelector:timelineModuleSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(container, timelineModuleSel);
    }
    return nil;
}

static BOOL SpliceKit_dualTimelineDragWindowUsable(NSWindow *window) {
    return window && window.visible && !window.miniaturized;
}

static id SpliceKit_dualTimelineDragContainerForWindow(NSWindow *window) {
    if (!window) return nil;

    id primary = SpliceKit_dualTimelinePrimaryEditorContainer();
    if (SpliceKit_dualTimelineDragWindowForContainer(primary) == window) {
        return primary;
    }

    id secondary = SpliceKit_dualTimelineSecondaryEditorContainer(NO);
    if (SpliceKit_dualTimelineDragWindowForContainer(secondary) == window) {
        return secondary;
    }

    return nil;
}

static id SpliceKit_dualTimelineDragOppositeContainer(id sourceContainer) {
    if (!sourceContainer) return nil;

    id primary = SpliceKit_dualTimelinePrimaryEditorContainer();
    id secondary = SpliceKit_dualTimelineSecondaryEditorContainer(NO);
    if (sourceContainer == primary) return secondary;
    if (sourceContainer == secondary) return primary;
    return nil;
}

static NSArray *SpliceKit_dualTimelineDragSelectedItemsForTimeline(id timelineModule) {
    if (!timelineModule) return @[];

    SEL selectedItemsWithFallbackSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
    if ([timelineModule respondsToSelector:selectedItemsWithFallbackSel]) {
        id selected = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timelineModule, selectedItemsWithFallbackSel, NO, NO);
        if ([selected isKindOfClass:[NSArray class]]) {
            return selected;
        }
    }

    SEL selectedItemsSel = NSSelectorFromString(@"selectedItems");
    if ([timelineModule respondsToSelector:selectedItemsSel]) {
        id selected = ((id (*)(id, SEL))objc_msgSend)(timelineModule, selectedItemsSel);
        if ([selected isKindOfClass:[NSArray class]]) {
            return selected;
        }
    }

    return @[];
}

static NSArray *SpliceKit_dualTimelineDragItemsForHandler(id handler) {
    if (!handler) return @[];

    SEL clickedItemSel = NSSelectorFromString(@"clickedItem");
    id clickedItem = [handler respondsToSelector:clickedItemSel]
        ? ((id (*)(id, SEL))objc_msgSend)(handler, clickedItemSel)
        : nil;

    SEL selectedItemsSel = NSSelectorFromString(@"selectedItemsIncludingEntireRangesWithClickedItem:");
    if ([handler respondsToSelector:selectedItemsSel]) {
        id items = ((id (*)(id, SEL, id))objc_msgSend)(handler, selectedItemsSel, clickedItem);
        if ([items isKindOfClass:[NSArray class]]) {
            return items;
        }
    }

    id timelineView = [handler respondsToSelector:NSSelectorFromString(@"timelineView")]
        ? ((id (*)(id, SEL))objc_msgSend)(handler, NSSelectorFromString(@"timelineView"))
        : nil;
    id sourceContainer = SpliceKit_dualTimelineDragContainerForWindow(
        [timelineView respondsToSelector:@selector(window)] ? ((id (*)(id, SEL))objc_msgSend)(timelineView, @selector(window)) : nil);
    id timelineModule = SpliceKit_dualTimelineDragTimelineModuleForContainer(sourceContainer);
    return SpliceKit_dualTimelineDragSelectedItemsForTimeline(timelineModule);
}

static BOOL SpliceKit_dualTimelineDragIsInternalDraggingInfo(id draggingInfo) {
    Class tlkDraggingInfoClass = objc_getClass("TLKDraggingInfo");
    return tlkDraggingInfoClass && [draggingInfo isKindOfClass:tlkDraggingInfoClass];
}

static NSImage *SpliceKit_dualTimelineDragImage(NSUInteger itemCount, BOOL copyOperation) {
    NSString *verb = copyOperation ? @"Copy" : @"Move";
    NSString *label = itemCount > 1
        ? [NSString stringWithFormat:@"%@ %lu clips", verb, (unsigned long)itemCount]
        : [NSString stringWithFormat:@"%@ clip", verb];

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:13.0],
        NSForegroundColorAttributeName: NSColor.whiteColor,
    };
    NSSize textSize = [label sizeWithAttributes:attrs];
    NSSize imageSize = NSMakeSize(MAX(132.0, ceil(textSize.width) + 28.0), 30.0);

    NSImage *image = [[NSImage alloc] initWithSize:imageSize];
    [image lockFocus];
    [[NSColor colorWithCalibratedWhite:0.12 alpha:0.9] setFill];
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0.0, 0.0, imageSize.width, imageSize.height)
                                                         xRadius:7.0
                                                         yRadius:7.0];
    [path fill];
    [label drawAtPoint:NSMakePoint(14.0, floor((imageSize.height - textSize.height) * 0.5))
        withAttributes:attrs];
    [image unlockFocus];
    return image;
}

static void SpliceKit_dualTimelineDragClearState(id handler) {
    if (!handler) return;
    objc_setAssociatedObject(handler, kSpliceKitDualTimelineDragSavedStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(handler, kSpliceKitDualTimelineDragPromotedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(handler, kSpliceKitDualTimelineDragSourceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SpliceKit_dualTimelineDragSaveSelectionStateIfNeeded(id handler, id items) {
    if (!handler || !items) return;
    if (objc_getAssociatedObject(handler, kSpliceKitDualTimelineDragSavedStateKey)) return;
    if (![items respondsToSelector:@selector(count)] || ((NSUInteger)[items count]) == 0) return;

    SEL clickedItemSel = NSSelectorFromString(@"clickedItem");
    SEL saveSel = NSSelectorFromString(@"_saveSelectionStateForItems:forClickedItem:");
    if (![handler respondsToSelector:saveSel]) return;

    id clickedItem = [handler respondsToSelector:clickedItemSel]
        ? ((id (*)(id, SEL))objc_msgSend)(handler, clickedItemSel)
        : nil;
    ((void (*)(id, SEL, id, id))objc_msgSend)(handler, saveSel, items, clickedItem);
    objc_setAssociatedObject(handler, kSpliceKitDualTimelineDragSavedStateKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SpliceKit_dualTimelineDragRestoreSelectionIfNeeded(id handler, id timelineView) {
    if (!handler) return;

    id layoutDatabase = nil;
    if ([timelineView respondsToSelector:NSSelectorFromString(@"layoutDatabase")]) {
        layoutDatabase = ((id (*)(id, SEL))objc_msgSend)(timelineView, NSSelectorFromString(@"layoutDatabase"));
    }

    id dataSourceProxy = nil;
    if (layoutDatabase && [layoutDatabase respondsToSelector:NSSelectorFromString(@"dataSourceProxy")]) {
        dataSourceProxy = ((id (*)(id, SEL))objc_msgSend)(layoutDatabase, NSSelectorFromString(@"dataSourceProxy"));
    }

    if (dataSourceProxy && [dataSourceProxy respondsToSelector:NSSelectorFromString(@"beginDataAccess:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(dataSourceProxy, NSSelectorFromString(@"beginDataAccess:"), YES);
        if ([dataSourceProxy respondsToSelector:NSSelectorFromString(@"endBeginTimelineHandlerTransaction")]) {
            ((void (*)(id, SEL))objc_msgSend)(dataSourceProxy, NSSelectorFromString(@"endBeginTimelineHandlerTransaction"));
        }
        if ([dataSourceProxy respondsToSelector:NSSelectorFromString(@"endDataAccess:")]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(dataSourceProxy, NSSelectorFromString(@"endDataAccess:"), YES);
        }
    }

    SEL restoreSel = NSSelectorFromString(@"_restoreSelectionStateIfNeeded");
    if ([handler respondsToSelector:restoreSel]) {
        ((void (*)(id, SEL))objc_msgSend)(handler, restoreSel);
    }

    SEL removePlaceholdersSel = NSSelectorFromString(@"removeAllPlaceholders");
    if ([handler respondsToSelector:removePlaceholdersSel]) {
        ((void (*)(id, SEL))objc_msgSend)(handler, removePlaceholdersSel);
    }
}

static BOOL SpliceKit_dualTimelineDragWriteItemsToPasteboard(id timelineView, id items) {
    if (!timelineView || !items || ![items respondsToSelector:@selector(count)] || ((NSUInteger)[items count]) == 0) {
        return NO;
    }

    id layoutDatabase = [timelineView respondsToSelector:NSSelectorFromString(@"layoutDatabase")]
        ? ((id (*)(id, SEL))objc_msgSend)(timelineView, NSSelectorFromString(@"layoutDatabase"))
        : nil;
    id dataSourceProxy = (layoutDatabase && [layoutDatabase respondsToSelector:NSSelectorFromString(@"dataSourceProxy")])
        ? ((id (*)(id, SEL))objc_msgSend)(layoutDatabase, NSSelectorFromString(@"dataSourceProxy"))
        : nil;
    if (!dataSourceProxy) {
        return NO;
    }

    NSPasteboard *dragPasteboard = [NSPasteboard pasteboardWithName:NSPasteboardNameDrag];
    [dragPasteboard clearContents];

    SEL beginSel = NSSelectorFromString(@"beginDataAccess:");
    SEL addSel = NSSelectorFromString(@"addItems:toPasteboardWithName:");
    SEL endSel = NSSelectorFromString(@"endDataAccess:");
    if (![dataSourceProxy respondsToSelector:addSel]) {
        return NO;
    }

    if ([dataSourceProxy respondsToSelector:beginSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(dataSourceProxy, beginSel, NO);
    }
    BOOL wrote = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(dataSourceProxy, addSel, items, NSPasteboardNameDrag);
    if ([dataSourceProxy respondsToSelector:endSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(dataSourceProxy, endSel, NO);
    }

    return wrote;
}

@interface SpliceKitDualTimelineDragSource : NSObject <NSDraggingSource>
@property (nonatomic, weak) id handler;
@property (nonatomic, weak) id sourceContainer;
@property (nonatomic, weak) id timelineView;
@property (nonatomic, assign) BOOL copyOperation;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) NSUInteger itemCount;
@end

@implementation SpliceKitDualTimelineDragSource

- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)local {
    return NSDragOperationCopy | NSDragOperationMove;
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return NSDragOperationCopy | NSDragOperationMove;
}

- (BOOL)ignoreModifierKeysForDraggingSession:(NSDraggingSession *)session {
    return NO;
}

- (void)draggedImage:(NSImage *)image endedAt:(NSPoint)screenPoint operation:(NSDragOperation)operation {
    [self spliceKit_finishWithOperation:operation];
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation {
    [self spliceKit_finishWithOperation:operation];
}

- (void)spliceKit_finishWithOperation:(NSDragOperation)operation {
    if (self.finished) return;
    self.finished = YES;

    id handler = self.handler;
    id sourceContainer = self.sourceContainer;
    BOOL success = operation != NSDragOperationNone;

    if (handler && [handler respondsToSelector:NSSelectorFromString(@"_draggingSessionEndedWithSuccess:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(handler, NSSelectorFromString(@"_draggingSessionEndedWithSuccess:"), success);
    }

    if (success && (operation & NSDragOperationMove) != 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            id timelineModule = SpliceKit_dualTimelineDragTimelineModuleForContainer(sourceContainer);
            NSArray *selectedItems = SpliceKit_dualTimelineDragSelectedItemsForTimeline(timelineModule);
            if (timelineModule && selectedItems.count > 0 &&
                [timelineModule respondsToSelector:@selector(delete:)]) {
                SpliceKit_log(@"[DualTimelineDrag] Removing %lu source items after move drop",
                              (unsigned long)selectedItems.count);
                ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, @selector(delete:), nil);
            }
        });
    }

    SpliceKit_dualTimelineDragClearState(handler);
}

@end

static BOOL SpliceKit_dualTimelineShouldPromoteDrag(id handler,
                                                    id timelineView,
                                                    CGPoint currentPoint,
                                                    id *outSourceContainer,
                                                    id *outTargetContainer)
{
    NSWindow *sourceWindow = [timelineView respondsToSelector:@selector(window)]
        ? ((id (*)(id, SEL))objc_msgSend)(timelineView, @selector(window))
        : nil;
    if (!SpliceKit_dualTimelineDragWindowUsable(sourceWindow)) {
        return NO;
    }

    id sourceContainer = SpliceKit_dualTimelineDragContainerForWindow(sourceWindow);
    id targetContainer = SpliceKit_dualTimelineDragOppositeContainer(sourceContainer);
    NSWindow *targetWindow = SpliceKit_dualTimelineDragWindowForContainer(targetContainer);
    if (!sourceContainer || !SpliceKit_dualTimelineDragWindowUsable(targetWindow)) {
        return NO;
    }

    NSPoint windowPoint = [timelineView convertPoint:currentPoint toView:nil];
    NSPoint screenPoint = [sourceWindow convertPointToScreen:windowPoint];

    if (NSPointInRect(screenPoint, sourceWindow.frame)) {
        return NO;
    }

    if (outSourceContainer) *outSourceContainer = sourceContainer;
    if (outTargetContainer) *outTargetContainer = targetContainer;
    return YES;
}

static BOOL SpliceKit_dualTimelineStartAppKitDrag(id handler,
                                                  id timelineView,
                                                  id items,
                                                  CGPoint currentPoint,
                                                  NSUInteger modifierFlags,
                                                  id sourceContainer,
                                                  id targetContainer)
{
    if (!handler || !timelineView || !items) {
        return NO;
    }

    if (!SpliceKit_dualTimelineDragWriteItemsToPasteboard(timelineView, items)) {
        SpliceKit_log(@"[DualTimelineDrag] Failed to write dragged items to NSPasteboardNameDrag");
        return NO;
    }

    SpliceKit_dualTimelineDragRestoreSelectionIfNeeded(handler, timelineView);

    NSEvent *event = NSApp.currentEvent;
    if (!event && [timelineView respondsToSelector:@selector(window)]) {
        NSWindow *window = ((id (*)(id, SEL))objc_msgSend)(timelineView, @selector(window));
        if ([window respondsToSelector:@selector(currentEvent)]) {
            event = ((id (*)(id, SEL))objc_msgSend)(window, @selector(currentEvent));
        }
    }
    if (!event) {
        SpliceKit_log(@"[DualTimelineDrag] No current event available to start AppKit drag");
        return NO;
    }

    BOOL copyOperation = (modifierFlags & NSEventModifierFlagOption) != 0;
    SpliceKitDualTimelineDragSource *dragSource = [SpliceKitDualTimelineDragSource new];
    dragSource.handler = handler;
    dragSource.sourceContainer = sourceContainer;
    dragSource.timelineView = timelineView;
    dragSource.copyOperation = copyOperation;
    dragSource.itemCount = [items respondsToSelector:@selector(count)] ? (NSUInteger)[items count] : 0;

    objc_setAssociatedObject(handler, kSpliceKitDualTimelineDragSourceKey, dragSource, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(handler, kSpliceKitDualTimelineDragPromotedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSView *sourceView = [timelineView isKindOfClass:[NSView class]] ? (NSView *)timelineView : nil;
    NSWindow *sourceWindow = [timelineView respondsToSelector:@selector(window)]
        ? ((id (*)(id, SEL))objc_msgSend)(timelineView, @selector(window))
        : nil;
    NSPoint windowPoint = [timelineView convertPoint:currentPoint toView:nil];
    NSPoint viewPoint = currentPoint;
    if (sourceWindow && sourceView) {
        NSPoint clamped = NSMakePoint(
            MIN(MAX(viewPoint.x, 8.0), NSWidth(sourceView.bounds) - 8.0),
            MIN(MAX(viewPoint.y, 8.0), NSHeight(sourceView.bounds) - 8.0));
        viewPoint = clamped;
        windowPoint = [timelineView convertPoint:viewPoint toView:nil];
    }

    NSImage *dragImage = SpliceKit_dualTimelineDragImage(dragSource.itemCount, copyOperation);
    SpliceKit_log(@"[DualTimelineDrag] Promoting drag to AppKit session (%@, %lu items)",
                  copyOperation ? @"copy" : @"move",
                  (unsigned long)dragSource.itemCount);

    ((void (*)(id, SEL, id, NSPoint, NSSize, id, id, id, BOOL))objc_msgSend)(
        timelineView,
        @selector(dragImage:at:offset:event:pasteboard:source:slideBack:),
        dragImage,
        viewPoint,
        NSZeroSize,
        event,
        [NSPasteboard pasteboardWithName:NSPasteboardNameDrag],
        dragSource,
        NO);

    return YES;
}

static void SpliceKit_dualTimelineSwizzledDragItems(id self,
                                                    SEL _cmd,
                                                    id items,
                                                    CGPoint fromPoint,
                                                    CGPoint toPoint,
                                                    CGPoint initialPoint,
                                                    NSUInteger modifierFlags)
{
    id timelineView = [self respondsToSelector:NSSelectorFromString(@"timelineView")]
        ? ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"timelineView"))
        : nil;

    SpliceKit_dualTimelineDragSaveSelectionStateIfNeeded(self, items);

    if (!objc_getAssociatedObject(self, kSpliceKitDualTimelineDragPromotedKey)) {
        id sourceContainer = nil;
        id targetContainer = nil;
        if (timelineView &&
            SpliceKit_dualTimelineShouldPromoteDrag(self, timelineView, toPoint, &sourceContainer, &targetContainer) &&
            SpliceKit_dualTimelineStartAppKitDrag(self, timelineView, items, toPoint, modifierFlags, sourceContainer, targetContainer)) {
            return;
        }
    }

    if (sOriginalTLKDragItems) {
        ((void (*)(id, SEL, id, CGPoint, CGPoint, CGPoint, NSUInteger))sOriginalTLKDragItems)(
            self, _cmd, items, fromPoint, toPoint, initialPoint, modifierFlags);
    }
}

static unsigned long long SpliceKit_dualTimelineSwizzledDragOrAcceptDrop(id self,
                                                                         SEL _cmd,
                                                                         id draggingInfo,
                                                                         CGPoint fromPoint,
                                                                         CGPoint toPoint,
                                                                         CGPoint initialPoint,
                                                                         NSUInteger modifierFlags)
{
    if (!objc_getAssociatedObject(self, kSpliceKitDualTimelineDragPromotedKey) &&
        SpliceKit_dualTimelineDragIsInternalDraggingInfo(draggingInfo)) {
        id timelineView = [self respondsToSelector:NSSelectorFromString(@"timelineView")]
            ? ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"timelineView"))
            : nil;
        id sourceContainer = nil;
        id targetContainer = nil;
        NSArray *items = SpliceKit_dualTimelineDragItemsForHandler(self);
        if (timelineView && items.count > 0 &&
            SpliceKit_dualTimelineShouldPromoteDrag(self, timelineView, toPoint, &sourceContainer, &targetContainer) &&
            SpliceKit_dualTimelineStartAppKitDrag(self, timelineView, items, toPoint, modifierFlags, sourceContainer, targetContainer)) {
            return (modifierFlags & NSEventModifierFlagOption) ? NSDragOperationCopy : NSDragOperationMove;
        }
    }

    if (sOriginalTLKDragOrAcceptDrop) {
        return ((unsigned long long (*)(id, SEL, id, CGPoint, CGPoint, CGPoint, NSUInteger))sOriginalTLKDragOrAcceptDrop)(
            self, _cmd, draggingInfo, fromPoint, toPoint, initialPoint, modifierFlags);
    }
    return NSDragOperationNone;
}

static void SpliceKit_dualTimelineSwizzledStopHandling(id self, SEL _cmd, id sender) {
    if (sOriginalTLKStopHandling) {
        ((void (*)(id, SEL, id))sOriginalTLKStopHandling)(self, _cmd, sender);
    }
    SpliceKit_dualTimelineDragClearState(self);
}

void SpliceKit_installDualTimelineCrossWindowDrag(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class dragItemsHandlerClass = objc_getClass("TLKDragItemsHandler");
        if (!dragItemsHandlerClass) {
            SpliceKit_log(@"[DualTimelineDrag] TLKDragItemsHandler not available");
            return;
        }

        sOriginalTLKDragItems = SpliceKit_swizzleMethod(
            dragItemsHandlerClass,
            NSSelectorFromString(@"dragItems:fromPoint:toPoint:initialPoint:modifierFlags:"),
            (IMP)SpliceKit_dualTimelineSwizzledDragItems);
        sOriginalTLKDragOrAcceptDrop = SpliceKit_swizzleMethod(
            dragItemsHandlerClass,
            NSSelectorFromString(@"_dragOrAcceptDrop:fromPoint:toPoint:initialPoint:modifierFlags:"),
            (IMP)SpliceKit_dualTimelineSwizzledDragOrAcceptDrop);
        sOriginalTLKStopHandling = SpliceKit_swizzleMethod(
            dragItemsHandlerClass,
            NSSelectorFromString(@"stopHandling:"),
            (IMP)SpliceKit_dualTimelineSwizzledStopHandling);

        SpliceKit_log(@"[DualTimelineDrag] Installed cross-window drag promotion swizzles");
    });
}
