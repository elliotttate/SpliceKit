//
//  TransitionAlignment.m
//  com.splicekit.transition-alignment
//
//  Restores legacy FCP 7 transition alignment options via the hidden
//  transitionOverlapType property on FFAnchoredTransition.
//
//  FCP 12.x only exposes "Center on Edit" in its UI, but the internal
//  data model still supports:
//    0 = End on Edit   (transition ends exactly at the cut point)
//    1 = Center on Edit (default — transition straddles the cut point)
//
//  "Start on Edit" was removed from FCP X and is not supported.
//
//  Features:
//    1. Right-click a transition → "Transition Alignment" submenu with
//       "Center on Edit" and "End on Edit" items.
//    2. MCP method transitions.setAlignment for programmatic control.
//
//  Build:   make
//  Install: make install
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "SpliceKitPluginAPI.h"

// ---------------------------------------------------------------------------
// Plugin API storage
// ---------------------------------------------------------------------------
static SpliceKitPluginAPI  sTAAPIStorage;
static SpliceKitPluginAPI *sTAAPI = NULL;

// IMP of the original timelineView:contextMenuForItem: we chain through to.
static IMP sTAOrigContextMenu = NULL;

// ---------------------------------------------------------------------------
// Runtime navigation helpers
// ---------------------------------------------------------------------------

static id TA_getSequence(void) {
    @try {
        Class appClass = NSClassFromString(@"NSApplication");
        id app      = ((id(*)(id,SEL))objc_msgSend)(appClass, @selector(sharedApplication));
        id delegate = ((id(*)(id,SEL))objc_msgSend)(app, @selector(delegate));
        if (!delegate) return nil;
        id container = ((id(*)(id,SEL))objc_msgSend)(delegate, @selector(activeEditorContainer));
        if (!container) return nil;
        id tlModule  = ((id(*)(id,SEL))objc_msgSend)(container, @selector(timelineModule));
        if (!tlModule) return nil;
        return ((id(*)(id,SEL))objc_msgSend)(tlModule, @selector(sequence));
    } @catch (__unused NSException *e) { return nil; }
}

static id TA_getSpine(id sequence) {
    if (!sequence) return nil;
    @try {
        SEL sel = NSSelectorFromString(@"primaryObject");
        if (![sequence respondsToSelector:sel]) return nil;
        return ((id(*)(id,SEL))objc_msgSend)(sequence, sel);
    } @catch (__unused NSException *e) { return nil; }
}

// ---------------------------------------------------------------------------
// Core alignment operation — caller must be on the main thread.
//
// Primary-storyline transitions have no meaningful anchorPair of their own.
// Their timeline position is entirely derived from where their adjacent clips
// overlap. The only API that physically moves the transition is
// FFAnchoredSequence -operationChangeTransitionObjectsOnSpineObjectOverlapType:
// spineObjectsToChange:transitionOverlapType:error:, which is what FCP uses
// internally. It adjusts the source-handle split between the two adjacent clips
// (outgoing donates more, incoming less, for End on Edit vs Center on Edit)
// and registers an undo action. We resolve sequence/spine here so the context-
// menu path can pass nil and still get the live objects.
// ---------------------------------------------------------------------------
static NSString *TA_applyAlignment(id sequence, id spine,
                                   NSArray *transitions, int overlapType) {
    if (transitions.count == 0) return @"No transitions found";

    if (!sequence) sequence = TA_getSequence();
    if (!sequence) return @"No active sequence";
    if (!spine)    spine    = TA_getSpine(sequence);
    if (!spine)    return @"Could not find primary storyline";

    @try {
        SEL opSel = NSSelectorFromString(
            @"operationChangeTransitionObjectsOnSpineObjectOverlapType:"
             "spineObjectsToChange:transitionOverlapType:error:");
        if (![sequence respondsToSelector:opSel])
            return @"operationChangeTransitionObjectsOnSpineObjectOverlapType: not found";

        NSError *error = nil;
        BOOL ok = ((BOOL(*)(id,SEL,id,NSArray*,int,NSError**))objc_msgSend)(
            sequence, opSel, spine, transitions, overlapType, &error);

        if (sTAAPI)
            sTAAPI->log(@"[TransitionAlignment] op ok=%d overlapType=%d count=%lu err=%@",
                        ok, overlapType, (unsigned long)transitions.count, error);

        if (!ok) return error ? error.localizedDescription : @"Operation returned NO";
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"Exception: %@", e.reason];
    }
}

// ---------------------------------------------------------------------------
// Context menu swizzle
//
// Swizzles FFAnchoredTimelineModule -timelineView:contextMenuForItem:
// When the right-clicked item is an FFAnchoredTransition, we append a
// "Transition Alignment" submenu to whatever menu FCP built.
// ---------------------------------------------------------------------------

// Button controller that owns the menu item actions.
@interface SpliceKitTA_MenuController : NSObject
+ (instancetype)shared;
- (void)setCenterOnEdit:(id)sender;
- (void)setEndOnEdit:(id)sender;
@end

@implementation SpliceKitTA_MenuController

+ (instancetype)shared {
    static SpliceKitTA_MenuController *sInstance;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{ sInstance = [[self alloc] init]; });
    return sInstance;
}

static void TA_reloadTimeline(void) {
    @try {
        id app      = ((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"NSApplication"),
                                                    @selector(sharedApplication));
        id delegate = ((id(*)(id,SEL))objc_msgSend)(app, @selector(delegate));
        id container = ((id(*)(id,SEL))objc_msgSend)(delegate,
                                                     @selector(activeEditorContainer));
        id tlModule = ((id(*)(id,SEL))objc_msgSend)(container, @selector(timelineModule));
        if (!tlModule) return;
        SEL sel = NSSelectorFromString(@"reloadTimelineView:");
        if ([tlModule respondsToSelector:sel])
            ((void(*)(id,SEL,id))objc_msgSend)(tlModule, sel, nil);
    } @catch (__unused NSException *e) {}
}

// The represented object of each menu item is the FFAnchoredTransition.
- (void)_applyOverlapType:(int)overlapType fromSender:(id)sender {
    id transition = [sender representedObject];
    if (!transition) return;
    NSString *err = TA_applyAlignment(nil, nil, @[transition], overlapType);
    if (err) {
        if (sTAAPI) sTAAPI->log(@"[TransitionAlignment] Context menu error: %@", err);
    } else {
        TA_reloadTimeline();
    }
}

- (void)setCenterOnEdit:(id)sender { [self _applyOverlapType:1 fromSender:sender]; }
- (void)setEndOnEdit:(id)sender    { [self _applyOverlapType:0 fromSender:sender]; }

@end


// The replacement IMP for timelineView:contextMenuForItem:
static id TA_contextMenuForItem(id self, SEL _cmd, id tlView, id item) {
    // Call through to get FCP's original menu.
    NSMenu *menu = ((id(*)(id, SEL, id, id))sTAOrigContextMenu)(self, _cmd, tlView, item);

    if (sTAAPI && item)
        sTAAPI->log(@"[TransitionAlignment] contextMenu item class: %s",
                    class_getName([item class]));

    // Accept FFAnchoredTransition or any object that has transitionOverlapType.
    // The item might be a view-model wrapper rather than the model object itself,
    // so we use KVC probing instead of an exact class check.
    id overlapVal = nil;
    @try { overlapVal = [item valueForKey:@"transitionOverlapType"]; }
    @catch (__unused NSException *e) { overlapVal = nil; }
    if (!overlapVal) return menu;

    // The item IS or WRAPS a transition. Use it directly as the target.
    id transition = item;

    // Create the submenu items. The representedObject carries the transition
    // so the action can operate on just that one clip.
    NSMenuItem *centerItem = [[NSMenuItem alloc]
        initWithTitle:@"Center on Edit"
               action:@selector(setCenterOnEdit:)
        keyEquivalent:@""];
    centerItem.target            = [SpliceKitTA_MenuController shared];
    centerItem.representedObject = item;

    NSMenuItem *endItem = [[NSMenuItem alloc]
        initWithTitle:@"End on Edit"
               action:@selector(setEndOnEdit:)
        keyEquivalent:@""];
    endItem.target            = [SpliceKitTA_MenuController shared];
    endItem.representedObject = item;

    // Mark the current alignment using the overlapVal we already have.
    int current = overlapVal ? [overlapVal intValue] : 1;
    centerItem.state = (current == 1) ? NSControlStateValueOn : NSControlStateValueOff;
    endItem.state    = (current == 0) ? NSControlStateValueOn : NSControlStateValueOff;

    NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"Transition Alignment"];
    [submenu addItem:centerItem];
    [submenu addItem:endItem];

    NSMenuItem *parentItem = [[NSMenuItem alloc] initWithTitle:@"Transition Alignment"
                                                        action:nil
                                                 keyEquivalent:@""];
    parentItem.submenu = submenu;

    if (!menu) menu = [[NSMenu alloc] initWithTitle:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:parentItem];

    return menu;
}

static void TA_installContextMenuSwizzle(void) {
    if (sTAOrigContextMenu) return;
    @try {
        Class cls = NSClassFromString(@"FFAnchoredTimelineModule");
        if (!cls) {
            if (sTAAPI) sTAAPI->log(@"[TransitionAlignment] FFAnchoredTimelineModule not found.");
            return;
        }
        SEL sel = NSSelectorFromString(@"timelineView:contextMenuForItem:");
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) {
            if (sTAAPI) sTAAPI->log(@"[TransitionAlignment] timelineView:contextMenuForItem: not found.");
            return;
        }
        sTAOrigContextMenu = method_getImplementation(m);
        class_replaceMethod(cls, sel, (IMP)TA_contextMenuForItem,
                            method_getTypeEncoding(m));
        if (sTAAPI) sTAAPI->log(@"[TransitionAlignment] Context menu swizzle installed.");
    } @catch (NSException *e) {
        sTAOrigContextMenu = NULL;
        if (sTAAPI) sTAAPI->log(@"[TransitionAlignment] Swizzle failed: %@", e.reason);
    }
}

// ---------------------------------------------------------------------------
// MCP method: transitions.setAlignment
// ---------------------------------------------------------------------------
static NSArray *TA_collectTransitions(id spine, BOOL selectedOnly) {
    if (!spine) return @[];
    @try {
        SEL itemsSel = NSSelectorFromString(@"containedItems");
        if (![spine respondsToSelector:itemsSel]) return @[];
        id items = ((id(*)(id,SEL))objc_msgSend)(spine, itemsSel);
        if (![items respondsToSelector:@selector(objectEnumerator)]) return @[];
        Class transitionClass = NSClassFromString(@"FFAnchoredTransition");
        NSMutableArray *result = [NSMutableArray array];
        for (id item in items) {
            if (!transitionClass || [item isKindOfClass:transitionClass]) {
                if (selectedOnly && ![[item valueForKey:@"selected"] boolValue]) continue;
                [result addObject:item];
            }
        }
        return result;
    } @catch (__unused NSException *e) { return @[]; }
}

static NSDictionary *TA_handleSetAlignment(NSDictionary *params) {
    NSString *alignment = params[@"alignment"];
    NSString *scope     = params[@"scope"] ?: @"all";

    if (!alignment)
        return @{@"error": @"Missing required param: alignment (\"center\" or \"end\")"};

    int overlapType;
    if      ([alignment isEqualToString:@"center"]) overlapType = 1;
    else if ([alignment isEqualToString:@"end"])    overlapType = 0;
    else return @{@"error": [NSString stringWithFormat:
        @"Invalid alignment \"%@\" — use \"center\" or \"end\"", alignment]};

    BOOL selectedOnly = [scope isEqualToString:@"selected"];

    __block NSString   *errorMsg = nil;
    __block NSUInteger  changed  = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        id sequence = TA_getSequence();
        if (!sequence) { errorMsg = @"No active sequence"; dispatch_semaphore_signal(sem); return; }
        id spine = TA_getSpine(sequence);
        if (!spine) { errorMsg = @"Could not find primary storyline"; dispatch_semaphore_signal(sem); return; }
        NSArray *transitions = TA_collectTransitions(spine, selectedOnly);
        if (transitions.count == 0) {
            errorMsg = selectedOnly ? @"No transitions selected" : @"No transitions on primary storyline";
            dispatch_semaphore_signal(sem);
            return;
        }
        errorMsg = TA_applyAlignment(nil, nil, transitions, overlapType);
        if (!errorMsg) changed = transitions.count;
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (errorMsg) return @{@"error": errorMsg};
    return @{@"status": @"ok", @"alignment": alignment, @"scope": scope, @"changed": @(changed)};
}

// ---------------------------------------------------------------------------
// Plugin entry point
// ---------------------------------------------------------------------------
__attribute__((visibility("default")))
void SpliceKitPlugin_init(SpliceKitPluginAPI *api) {
    sTAAPIStorage = *api;
    sTAAPI = &sTAAPIStorage;

    sTAAPI->log(@"[TransitionAlignment] Loading.");

    // Context menu swizzle must run on main thread.
    sTAAPI->executeOnMainThreadAsync(^{
        TA_installContextMenuSwizzle();
    });

    sTAAPI->registerMethod(
        @"transitions.setAlignment",
        ^NSDictionary *(NSDictionary *params) { return TA_handleSetAlignment(params); },
        @{
            @"description": @"Set transition alignment. \"center\" = Center on Edit (FCP default). "
                             @"\"end\" = End on Edit (transition ends at the cut point).",
            @"params": @{
                @"alignment": @"\"center\" | \"end\"",
                @"scope":     @"\"all\" | \"selected\"  (default: \"all\")",
            },
            @"readOnly": @NO,
        }
    );

    sTAAPI->log(@"[TransitionAlignment] Loaded.");
}
