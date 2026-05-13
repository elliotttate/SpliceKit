//
//  SelectFromPlayheadButtons.m
//  com.splicekit.select-from-playhead-buttons
//
//  Injects two buttons into Final Cut Pro's main toolbar:
//
//    ▶|  Select Forward  — selects all primary-storyline clips whose start
//                          time is at or after the playhead position.
//    |◀  Select Backward — selects all primary-storyline clips whose end
//                          time is at or before the playhead position.
//
//  The buttons invoke timeline.action("selectForward") and
//  timeline.action("selectBackward"), which are built into SpliceKit core.
//
//  Toolbar injection follows the same pattern as SpliceKit's own LiveCam /
//  Transcript / Command Palette buttons (SpliceKit.m lines 2819-3047):
//    1. Swizzle FCP's toolbar delegate so it recognises our custom item IDs.
//    2. Insert our items into the toolbar once the main window is ready.
//    3. Use a notification + polling fallback to survive timing edge-cases.
//
//  Build:   make -f Makefile
//  Install: make -f Makefile install
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "SpliceKitPluginAPI.h"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// Unique identifier strings for our two toolbar items.
// Must not collide with any identifier already used by FCP or SpliceKit core.
static NSString * const kSFPBForwardID  = @"SpliceKitSFP_SelectForwardItemID";
static NSString * const kSFPBBackwardID = @"SpliceKitSFP_SelectBackwardItemID";

// Plugin API — copied into static storage at init time.
// IMPORTANT: SpliceKitPlugins_loadNative allocates SpliceKitPluginAPI on the
// stack and passes a pointer to it. If we store that raw pointer and use it
// after init returns (e.g. from an async block), we read freed memory and
// crash. We avoid this by copying the struct contents and keeping our own copy.
static SpliceKitPluginAPI  sSFPBAPIStorage;          // owns the data
static SpliceKitPluginAPI *sSFPBAPI = NULL;           // set to &sSFPBAPIStorage once copied

// The original (or already-swizzled) implementation we chain through to.
// This is whatever was in place at the moment we installed our swizzle —
// either FCP's original method or SpliceKit's already-installed swizzle.
static IMP sSFPBOriginalItemForIdentifier = NULL;

// ---------------------------------------------------------------------------
// Button target — singleton NSObject whose action methods fire the RPC calls.
// Declaring an ObjC class inside a plugin dylib is fine; the class is
// registered in the shared runtime and persists for the process lifetime.
// ---------------------------------------------------------------------------
@interface SpliceKitSFP_BtnController : NSObject
+ (instancetype)shared;
- (void)selectForwardAction:(id)sender;
- (void)selectBackwardAction:(id)sender;
@end

@implementation SpliceKitSFP_BtnController

+ (instancetype)shared {
    static SpliceKitSFP_BtnController *sInstance = nil;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{ sInstance = [[self alloc] init]; });
    return sInstance;
}

- (void)selectForwardAction:(id)sender {
    (void)sender;
    if (sSFPBAPI) {
        sSFPBAPI->callMethod(@{
            @"method": @"timeline.action",
            @"params": @{@"action": @"selectForward"}
        });
    }
}

- (void)selectBackwardAction:(id)sender {
    (void)sender;
    if (sSFPBAPI) {
        sSFPBAPI->callMethod(@{
            @"method": @"timeline.action",
            @"params": @{@"action": @"selectBackward"}
        });
    }
}

@end

// ---------------------------------------------------------------------------
// Icon helper — SF Symbol sized to match FCP's toolbar buttons.
// ---------------------------------------------------------------------------
static NSImage *SFPB_makeIcon(NSString *symbolName, NSString *description) {
    NSImage *img = [NSImage imageWithSystemSymbolName:symbolName
                             accessibilityDescription:description];
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
        configurationWithPointSize:13 weight:NSFontWeightMedium];
    return img ? [img imageWithSymbolConfiguration:cfg] : nil;
}

// ---------------------------------------------------------------------------
// Toolbar delegate swizzle
//
// FCP asks its toolbar delegate "what NSToolbarItem goes at identifier X?"
// whenever it needs to instantiate or display an item. By replacing the
// delegate's implementation with this function, we intercept requests for
// our two custom identifiers and synthesise NSToolbarItems on the fly.
// All other identifiers are forwarded to whatever was there before us.
// ---------------------------------------------------------------------------
static id SFPB_toolbarItemForIdentifier(id self, SEL _cmd,
                                         NSToolbar *toolbar,
                                         NSString *identifier,
                                         BOOL willInsert) {
    // Helper: build a momentary push button that matches FCP's toolbar aesthetic.
    NSButton * (^makeButton)(NSImage *, SEL) = ^(NSImage *icon, SEL action) {
        NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 36, 25)];
        [btn setButtonType:NSButtonTypeMomentaryPushIn];
        btn.bezelStyle    = NSBezelStyleTexturedRounded;
        btn.bordered      = YES;
        btn.image         = icon;
        btn.imagePosition = NSImageOnly;
        btn.target        = [SpliceKitSFP_BtnController shared];
        btn.action        = action;
        return btn;
    };

    if ([identifier isEqualToString:kSFPBForwardID]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label        = @"Select Fwd";
        item.paletteLabel = @"Select Forward from Playhead";
        item.toolTip      = @"Select all clips from the playhead to the end of the timeline";

        item.view = makeButton(SFPB_makeIcon(@"arrow.right.square",
                                            @"Select Forward from Playhead"),
                              @selector(selectForwardAction:));
        return item;
    }

    if ([identifier isEqualToString:kSFPBBackwardID]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label        = @"Select Bwd";
        item.paletteLabel = @"Select Backward from Playhead";
        item.toolTip      = @"Select all clips from the beginning of the timeline to the playhead";

        item.view = makeButton(SFPB_makeIcon(@"arrow.left.square",
                                            @"Select Backward from Playhead"),
                              @selector(selectBackwardAction:));
        return item;
    }

    // Not ours — call through to whatever was there before (either FCP's
    // original method or SpliceKit core's already-installed swizzle).
    return ((id (*)(id, SEL, NSToolbar *, NSString *, BOOL))sSFPBOriginalItemForIdentifier)(
        self, _cmd, toolbar, identifier, willInsert);
}

// ---------------------------------------------------------------------------
// Swizzle installation — targets PEMainWindowModule by name so it works
// even when called before the toolbar/delegate are reachable.
// ---------------------------------------------------------------------------

static void SFPB_installSwizzle(void) {
    if (sSFPBOriginalItemForIdentifier) return; // already installed

    @try {
        // Prefer the named class so we always swizzle the right delegate regardless
        // of which window we happen to find first during the polling phase.
        Class cls = NSClassFromString(@"PEMainWindowModule");

        // Fallback: walk open windows to find whatever class is acting as delegate.
        if (!cls) {
            for (NSWindow *w in [[NSApplication sharedApplication] windows]) {
                if (w.toolbar && w.toolbar.delegate) {
                    cls = [w.toolbar.delegate class];
                    break;
                }
            }
        }
        if (!cls) return;

        SEL sel = @selector(toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) return;

        // Capture the current IMP (may be SpliceKit's swizzle or FCP's original).
        sSFPBOriginalItemForIdentifier = method_getImplementation(m);

        // Use class_replaceMethod rather than method_setImplementation so we only
        // touch cls's OWN method table. method_setImplementation would modify
        // whichever class in the hierarchy owns the Method object, potentially
        // breaking unrelated subclasses that share the same inherited method.
        class_replaceMethod(cls, sel,
                            (IMP)SFPB_toolbarItemForIdentifier,
                            method_getTypeEncoding(m));

        if (sSFPBAPI)
            sSFPBAPI->log(@"[SFPButtons] Swizzled %s", class_getName(cls));

    } @catch (NSException *e) {
        sSFPBOriginalItemForIdentifier = NULL; // reset so we can retry
        if (sSFPBAPI)
            sSFPBAPI->log(@"[SFPButtons] Swizzle exception: %@", e.reason);
    }
}

// ---------------------------------------------------------------------------
// Toolbar installation
// ---------------------------------------------------------------------------

static void SFPB_addButtonsToToolbar(NSToolbar *toolbar) {
    @try {
        if (!toolbar.delegate) return;

        // Swizzle is installed eagerly at init; this is just a safety net in
        // case we somehow get here before the eager call finished.
        SFPB_installSwizzle();

        // Scan for existing items; remove any stale (view-less) copies.
        BOOL hasForward = NO, hasBackward = NO;
        for (NSInteger i = (NSInteger)toolbar.items.count - 1; i >= 0; i--) {
            NSToolbarItem *ti = toolbar.items[(NSUInteger)i];
            if ([ti.itemIdentifier isEqualToString:kSFPBForwardID]) {
                if (ti.view) hasForward  = YES;
                else         [toolbar removeItemAtIndex:(NSUInteger)i];
            } else if ([ti.itemIdentifier isEqualToString:kSFPBBackwardID]) {
                if (ti.view) hasBackward = YES;
                else         [toolbar removeItemAtIndex:(NSUInteger)i];
            }
        }
        if (hasForward && hasBackward) return; // Already present — done.

        // Insert before the flexible space so our buttons sit with FCP's own
        // tool controls (same grouping used by SpliceKit's built-in buttons).
        NSUInteger insertIdx = toolbar.items.count;
        for (NSUInteger i = 0; i < toolbar.items.count; i++) {
            if ([toolbar.items[i].itemIdentifier
                    isEqualToString:NSToolbarFlexibleSpaceItemIdentifier]) {
                insertIdx = i;
                break;
            }
        }

        // Insert backward first so forward ends up to its right: [Bwd][Fwd]
        if (!hasBackward) {
            [toolbar insertItemWithItemIdentifier:kSFPBBackwardID atIndex:insertIdx];
            insertIdx++;
        }
        if (!hasForward) {
            [toolbar insertItemWithItemIdentifier:kSFPBForwardID atIndex:insertIdx];
        }

        if (sSFPBAPI)
            sSFPBAPI->log(@"[SFPButtons] Toolbar buttons installed.");

    } @catch (NSException *e) {
        if (sSFPBAPI)
            sSFPBAPI->log(@"[SFPButtons] Exception during toolbar install: %@", e.reason);
    }
}

// Polling fallback: check all windows for a ready toolbar.
static void SFPB_tryInstall(int attempt);

static void SFPB_tryInstall(int attempt) {
    if (attempt >= 30) {
        if (sSFPBAPI) sSFPBAPI->log(@"[SFPButtons] Giving up after %d attempts.", attempt);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        for (NSWindow *w in [[NSApplication sharedApplication] windows]) {
            if (w.toolbar && w.toolbar.items.count > 0) {
                SFPB_addButtonsToToolbar(w.toolbar);
                return;
            }
        }
        SFPB_tryInstall(attempt + 1);
    });
}

static void SFPB_startInstallation(void) {
    // Fast path: notification fires when a window with a toolbar becomes main.
    __block id observer =
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowDidBecomeMainNotification
            object:nil
            queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note) {
                NSWindow *win = note.object;
                if (win.toolbar) {
                    [[NSNotificationCenter defaultCenter] removeObserver:observer];
                    observer = nil;
                    SFPB_addButtonsToToolbar(win.toolbar);
                }
            }];

    // Slow path: poll every second in case the notification already fired
    // before we registered, or in case FCP's window isn't main yet.
    SFPB_tryInstall(0);
}

// ---------------------------------------------------------------------------
// Plugin entry point
// ---------------------------------------------------------------------------
__attribute__((visibility("default")))
void SpliceKitPlugin_init(SpliceKitPluginAPI *api) {
    // Copy the struct — the caller allocates it on the stack and it's gone
    // the moment SpliceKitPlugins_loadNative returns (before our async block runs).
    sSFPBAPIStorage = *api;
    sSFPBAPI = &sSFPBAPIStorage;

    sSFPBAPI->log(@"[SFPButtons] Loading — will inject Select Forward/Backward toolbar buttons.");

    // All AppKit work must happen on the main thread.
    api->executeOnMainThreadAsync(^{
        // Install the swizzle immediately — before the notification/polling
        // fires — so FCP's toolbar delegate is ready to serve our identifiers
        // the moment we call insertItemWithItemIdentifier:atIndex:.
        SFPB_installSwizzle();
        SFPB_startInstallation();
    });

    api->log(@"[SFPButtons] Loaded.");
}
