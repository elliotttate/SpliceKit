//
//  IndependentSlip.m
//  com.splicekit.independent-slip
//
//  Adds two toggle buttons to Final Cut Pro's toolbar that make the Trim
//  tool's slip operation affect only one component of a linked clip:
//
//    [▶] Video only  — audio source range stays in place, video slips freely.
//    [♪] Audio only  — video source range stays in place, audio slips freely.
//
//  How it works
//  ─────────────
//  FCP's slip drag runs through TLKSlipSlideHandler (TimelineKit).
//  Each drag frame calls continueTracking:, which updates both the video and
//  audio source ranges of the clicked clip together.
//
//  We swizzle three methods:
//
//    TLKSlipSlideHandler -startTracking:
//      Capture the locked component's source range before any drag frame moves it.
//
//    TLKSlipSlideHandler -continueTracking:
//      Call original (both components slip). No live restore — restoring via KVC
//      during the drag triggers FFAnchoredCollection's notification chain which
//      can crash on a freed FFSourceVideoEffect node (use-after-free in
//      FFSynchronizable::Lock). The locked waveform visual is corrected at commit.
//
//    TLKSlipSlideHandler -stopTrackingWithCommit:
//      After commit, restore the locked range via CoreData's primitive setter
//      (bypasses the notification chain that would crash), then force a full
//      timeline reload so TLKLayerManager.updateMediaRectsForItemComponentFragment:
//      re-reads audioClippedRange and recomputes unusedAudioMediaRect (the waveform
//      position rect) from the now-correct locked value.
//
//  We deliberately avoid putting CMTimeRange in any C function signature
//  because the arm64 register-decomposition ABI for 48-byte structs is
//  incompatible with ObjC swizzle chains.  KVC (valueForKey:/setValue:forKey:)
//  lets FCP's own compiled code handle the struct layout correctly.
//
//  KVC targets:
//    VideoOnly: FFAnchoredCollection.audioClippedRange  (audio source range)
//    AudioOnly: FFAnchoredCollection.clippedRange (the video source range)
//
//  Toolbar injection follows the same pattern as SpliceKit's built-in buttons.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "SpliceKitPluginAPI.h"

// ---------------------------------------------------------------------------
// Plugin API
// ---------------------------------------------------------------------------
static SpliceKitPluginAPI  sISAPIStorage;
static SpliceKitPluginAPI *sISAPI = NULL;

// ---------------------------------------------------------------------------
// Mode
// ---------------------------------------------------------------------------
typedef enum : NSInteger {
    kISMode_Normal    = 0,
    kISMode_VideoOnly = 1,
    kISMode_AudioOnly = 2,
} ISMode;

static ISMode    sMode           = kISMode_Normal;
// State captured at startTracking:.
static id        sLockedObject      = nil;   // FFAnchoredCollection being slipped
static NSString *sLockedKey         = nil;   // "audioClippedRange" or "clippedRange"
static id        sRangeToRestore    = nil;   // range to restore (NSValue wrapping CMTimeRange)

// ---------------------------------------------------------------------------
// Toolbar item identifiers
// ---------------------------------------------------------------------------
static NSString * const kISVideoOnlyID = @"SpliceKitIS_VideoOnlyItemID";
static NSString * const kISAudioOnlyID = @"SpliceKitIS_AudioOnlyItemID";

// ---------------------------------------------------------------------------
// Saved IMPs
// ---------------------------------------------------------------------------
static IMP sOrigToolbarItemForIdentifier  = NULL;
static IMP sOrigSlipStartTracking         = NULL;
static IMP sOrigSlipContinueTracking      = NULL;
static IMP sOrigSlipStopTracking          = NULL;
static IMP sOrigSlipStopHandling          = NULL;

// ---------------------------------------------------------------------------
// Button references (weak — toolbar owns them)
// ---------------------------------------------------------------------------
static __weak NSButton *sVideoOnlyButton = nil;
static __weak NSButton *sAudioOnlyButton = nil;

// ---------------------------------------------------------------------------
// Mode helpers
// ---------------------------------------------------------------------------
static void IS_setMode(ISMode newMode) {
    sMode = newMode;
    dispatch_async(dispatch_get_main_queue(), ^{
        sVideoOnlyButton.state = (newMode == kISMode_VideoOnly)
                                 ? NSControlStateValueOn : NSControlStateValueOff;
        sAudioOnlyButton.state = (newMode == kISMode_AudioOnly)
                                 ? NSControlStateValueOn : NSControlStateValueOff;
    });
}

// ---------------------------------------------------------------------------
// Button controller
// ---------------------------------------------------------------------------
@interface SpliceKitIS_Controller : NSObject
+ (instancetype)shared;
- (void)videoOnlyAction:(id)sender;
- (void)audioOnlyAction:(id)sender;
@end

@implementation SpliceKitIS_Controller

+ (instancetype)shared {
    static SpliceKitIS_Controller *sInstance = nil;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{ sInstance = [[self alloc] init]; });
    return sInstance;
}

- (void)videoOnlyAction:(id)sender {
    IS_setMode(sMode == kISMode_VideoOnly ? kISMode_Normal : kISMode_VideoOnly);
    if (sISAPI) sISAPI->log(@"[IndependentSlip] Mode → %ld", (long)sMode);
}

- (void)audioOnlyAction:(id)sender {
    IS_setMode(sMode == kISMode_AudioOnly ? kISMode_Normal : kISMode_AudioOnly);
    if (sISAPI) sISAPI->log(@"[IndependentSlip] Mode → %ld", (long)sMode);
}

@end

// ---------------------------------------------------------------------------
// Icon helper
// ---------------------------------------------------------------------------
static NSImage *IS_makeIcon(NSString *symbolName, NSString *desc) {
    NSImage *img = [NSImage imageWithSystemSymbolName:symbolName
                             accessibilityDescription:desc];
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
        configurationWithPointSize:13 weight:NSFontWeightMedium];
    return img ? [img imageWithSymbolConfiguration:cfg] : nil;
}

// ---------------------------------------------------------------------------
// Toolbar delegate swizzle
// ---------------------------------------------------------------------------
static id IS_toolbarItemForIdentifier(id self, SEL _cmd,
                                       NSToolbar *toolbar,
                                       NSString *identifier,
                                       BOOL willInsert) {
    NSButton * (^makeToggle)(NSImage *, SEL) = ^(NSImage *icon, SEL action) {
        NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 36, 25)];
        [btn setButtonType:NSButtonTypePushOnPushOff];
        btn.bezelStyle    = NSBezelStyleTexturedRounded;
        btn.bordered      = YES;
        btn.image         = icon;
        btn.imagePosition = NSImageOnly;
        btn.target        = [SpliceKitIS_Controller shared];
        btn.action        = action;
        return btn;
    };

    if ([identifier isEqualToString:kISVideoOnlyID]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label        = @"Video Only";
        item.paletteLabel = @"Slip Video Only";
        item.toolTip      = @"Slip video independently — audio source stays in place";
        NSButton *btn = makeToggle(IS_makeIcon(@"film", @"Slip video only"),
                                   @selector(videoOnlyAction:));
        sVideoOnlyButton = btn;
        item.view = btn;
        return item;
    }

    if ([identifier isEqualToString:kISAudioOnlyID]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label        = @"Audio Only";
        item.paletteLabel = @"Slip Audio Only";
        item.toolTip      = @"Slip audio independently — video source stays in place";
        NSButton *btn = makeToggle(IS_makeIcon(@"waveform", @"Slip audio only"),
                                   @selector(audioOnlyAction:));
        sAudioOnlyButton = btn;
        item.view = btn;
        return item;
    }

    return ((id (*)(id, SEL, NSToolbar *, NSString *, BOOL))sOrigToolbarItemForIdentifier)(
        self, _cmd, toolbar, identifier, willInsert);
}

// ---------------------------------------------------------------------------
// KVC helpers — avoid CMTimeRange in any C function signature.
//
// lockKey: "audioClippedRange" in VideoOnly mode (keep audio source fixed)
//          "clippedRange"      in AudioOnly  mode (keep video source fixed)
//
// Both are set on the FFAnchoredCollection (clickedItem from the handler).
// ---------------------------------------------------------------------------

// The clickedItem on TLKDragEdgesHandler is the FFAnchoredCollection being slipped.
static id IS_clipFromHandler(id handler) {
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(handler, @selector(clickedItem));
    } @catch (__unused NSException *) { return nil; }
}

// Capture state at drag start.
static void IS_captureLockedState(id clip) {
    sLockedObject   = nil;
    sLockedKey      = nil;
    sRangeToRestore = nil;
    if (!clip) return;

    sLockedObject = clip;
    sLockedKey    = (sMode == kISMode_VideoOnly) ? @"audioClippedRange" : @"clippedRange";
    @try { sRangeToRestore = [clip valueForKey:sLockedKey]; }
    @catch (__unused NSException *) {}

    if (sISAPI) sISAPI->log(@"[IndependentSlip] Locking %@=%@", sLockedKey, sRangeToRestore);
}

// Restore using the stored object+key via CoreData's primitive setter.
// setPrimitiveValue:forKey: writes directly to the CoreData backing store without
// calling willChangeValueForKey:, custom ObjC setters, or the FFAnchoredCollection
// notification/invalidation chain. Using setValue:forKey: here triggers
// setAudioClippedRange: → invalidateSourceRange: → FFNotificationCenter →
// FFSourceVideoEffect._invalidateCachedMD5: → FFSynchronizable::Lock() which
// crashes on freed effect nodes. The primitive write is safe everywhere.
static void IS_restoreLockedRange(id savedRange) {
    if (!sLockedObject || !savedRange) return;
    @try {
        SEL primSel = NSSelectorFromString(@"setPrimitiveValue:forKey:");
        if ([sLockedObject respondsToSelector:primSel])
            ((void(*)(id,SEL,id,id))objc_msgSend)(sLockedObject, primSel, savedRange, sLockedKey);
        else
            [sLockedObject setValue:savedRange forKey:sLockedKey];
    }
    @catch (__unused NSException *) {}
}

// Force a full timeline redraw so any cached waveform/filmstrip display
// reflects the model state we just restored via KVC.
static void IS_reloadTimeline(void) {
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
    } @catch (__unused NSException *) {}
}

// ---------------------------------------------------------------------------
// Slip lifecycle swizzles — on TLKClipTrimmerDragClipHandler
// ---------------------------------------------------------------------------

// startTracking: — capture which object+key+value to lock, BEFORE the original
// fires, so we have the true pre-drag value even if startTracking mutates it.
static BOOL IS_slipStartTracking(id self, SEL _cmd, id dispatcher) {
    id clip = IS_clipFromHandler(self);
    if (sMode != kISMode_Normal && clip)
        IS_captureLockedState(clip);

    BOOL result = ((BOOL (*)(id, SEL, id))sOrigSlipStartTracking)(self, _cmd, dispatcher);

    if (!result) {
        sLockedObject   = nil;
        sLockedKey      = nil;
        sRangeToRestore = nil;
    }

    if (sISAPI)
        sISAPI->log(@"[IndependentSlip] startTracking result=%d mode=%ld clip=%s key=%@ range=%@",
                    (int)result, (long)sMode,
                    clip ? class_getName([clip class]) : "NIL",
                    sLockedKey, sRangeToRestore);
    return result;
}

// continueTracking: — per-frame: let FCP slip both components freely.
// We do NOT restore the locked range here. Calling any setter on audioClippedRange
// during the drag triggers FFAnchoredCollection's deferred-update + notification
// pipeline which crashes on freed FFSourceVideoEffect nodes (use-after-free).
// The waveform display is corrected at commit time in stopTrackingWithCommit:.
static BOOL IS_slipContinueTracking(id self, SEL _cmd, id eventContext) {
    return ((BOOL (*)(id, SEL, id))sOrigSlipContinueTracking)(self, _cmd, eventContext);
}

static BOOL IS_slipStopTracking(id self, SEL _cmd, BOOL commit) {
    if (sMode != kISMode_Normal && commit) {
        id savedRange  = sRangeToRestore;
        id savedObject = sLockedObject;
        NSString *savedKey = sLockedKey;

        // Let FCP commit the slip. CoreData writes videoClippedRange = slipped and
        // audioClippedRange = slipped. The TLK layer reload inside this call reads
        // audioClippedRange to compute unusedAudioMediaRect (waveform position rect),
        // so the waveform is briefly wrong after this returns.
        BOOL result = ((BOOL (*)(id, SEL, BOOL))sOrigSlipStopTracking)(self, _cmd, commit);

        // Belt-and-suspenders: restore after commit in case stopHandling: didn't fire.
        // IS_slipStopHandling (swizzled below) does the primary restore BEFORE the TLK
        // reload so updateMediaRectsForItemComponentFragment: reads the correct value.
        if (savedObject && savedKey && savedRange)
            IS_restoreLockedRange(savedRange);

        if (sISAPI)
            sISAPI->log(@"[IndependentSlip] commit done, locked range restored: %@=%@", savedKey, savedRange);

        sRangeToRestore = nil;
        sLockedObject   = nil;
        sLockedKey      = nil;
        return result;
    }

    sRangeToRestore = nil;
    sLockedObject   = nil;
    sLockedKey      = nil;
    return ((BOOL (*)(id, SEL, BOOL))sOrigSlipStopTracking)(self, _cmd, commit);
}

// stopHandling: — fires inside stopTrackingWithCommit:YES, AFTER the CoreData
// commit writes audioClippedRange = slipped but BEFORE TLKDragEdgesHandler calls
// TLKTimelineView.reloadWithItemsAdded:removed:modified: → TLKReloadOperation.main
// → TLKLayerManager.updateMediaRectsForItemComponentFragment:.
//
// By restoring the locked range here (before calling the original) we ensure that
// updateMediaRectsForItemComponentFragment: reads audioClippedRange = locked and
// computes the correct unusedAudioMediaRect (waveform position rect).
//
// We swizzle this on TLKSlipSlideHandler directly — the previous attempt swizzled
// TLKDragEdgesHandler (parent), but TLKSlipSlideHandler has its own override which
// shadows the parent's method table entry for all slip handler instances.
static void IS_slipStopHandling(id self, SEL _cmd, id eventContext) {
    if (sMode != kISMode_Normal && sLockedObject && sRangeToRestore) {
        IS_restoreLockedRange(sRangeToRestore);
        if (sISAPI)
            sISAPI->log(@"[IndependentSlip] stopHandling: restored %@=%@ before TLK reload",
                        sLockedKey, sRangeToRestore);
    }
    ((void(*)(id,SEL,id))sOrigSlipStopHandling)(self, _cmd, eventContext);
}

// ---------------------------------------------------------------------------
// Swizzle installation
// ---------------------------------------------------------------------------
static void IS_installToolbarSwizzle(void) {
    if (sOrigToolbarItemForIdentifier) return;
    @try {
        Class cls = NSClassFromString(@"PEMainWindowModule");
        if (!cls) return;
        SEL sel = @selector(toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) return;
        sOrigToolbarItemForIdentifier = method_getImplementation(m);
        class_replaceMethod(cls, sel, (IMP)IS_toolbarItemForIdentifier,
                            method_getTypeEncoding(m));
        if (sISAPI) sISAPI->log(@"[IndependentSlip] Toolbar swizzle installed.");
    } @catch (NSException *e) {
        sOrigToolbarItemForIdentifier = NULL;
        if (sISAPI) sISAPI->log(@"[IndependentSlip] Toolbar swizzle failed: %@", e.reason);
    }
}

static void IS_installSlipSwizzles(void) {
    @try {
        // TLKSlipSlideHandler is the handler TimelineKit uses for slip drags.
        // It owns startTracking: and stopTrackingWithCommit: directly and
        // inherits continueTracking: from TLKDragEdgesHandler.
        // clickedItem (also on TLKDragEdgesHandler) returns FFAnchoredCollection
        // directly — the model object we KVC against for clippedRange.
        Class cls = NSClassFromString(@"TLKSlipSlideHandler");
        if (!cls) {
            if (sISAPI)
                sISAPI->log(@"[IndependentSlip] TLKClipTrimmerDragClipHandler not found.");
            return;
        }

        if (!sOrigSlipStartTracking) {
            SEL sel = @selector(startTracking:);
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                sOrigSlipStartTracking = method_getImplementation(m);
                class_replaceMethod(cls, sel, (IMP)IS_slipStartTracking,
                                    method_getTypeEncoding(m));
            }
        }

        if (!sOrigSlipContinueTracking) {
            SEL sel = @selector(continueTracking:);
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                sOrigSlipContinueTracking = method_getImplementation(m);
                class_replaceMethod(cls, sel, (IMP)IS_slipContinueTracking,
                                    method_getTypeEncoding(m));
            }
        }

        if (!sOrigSlipStopTracking) {
            SEL sel = @selector(stopTrackingWithCommit:);
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                sOrigSlipStopTracking = method_getImplementation(m);
                class_replaceMethod(cls, sel, (IMP)IS_slipStopTracking,
                                    method_getTypeEncoding(m));
            }
        }

        // stopHandling: — swizzled on TLKSlipSlideHandler rather than the parent
        // TLKDragEdgesHandler. TLKSlipSlideHandler declares its own stopHandling: which
        // takes precedence over the parent's method entry for all slip handler instances.
        // class_addMethod adds an entry directly to cls's method table if the selector
        // is not already there (inherited); class_replaceMethod handles the case where
        // cls owns the method itself. Either way dispatch to cls instances hits our IMP.
        if (!sOrigSlipStopHandling) {
            SEL sel = NSSelectorFromString(@"stopHandling:");
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                sOrigSlipStopHandling = method_getImplementation(m);
                if (!class_addMethod(cls, sel, (IMP)IS_slipStopHandling,
                                     method_getTypeEncoding(m)))
                    class_replaceMethod(cls, sel, (IMP)IS_slipStopHandling,
                                        method_getTypeEncoding(m));
            }
        }

        if (sISAPI) sISAPI->log(@"[IndependentSlip] Slip swizzles installed on TLKSlipSlideHandler.");
    } @catch (NSException *e) {
        if (sISAPI) sISAPI->log(@"[IndependentSlip] Slip swizzle exception: %@", e.reason);
    }
}

// ---------------------------------------------------------------------------
// Toolbar insertion
// ---------------------------------------------------------------------------
static void IS_addButtonsToToolbar(NSToolbar *toolbar) {
    @try {
        if (!toolbar.delegate) return;
        IS_installToolbarSwizzle();

        BOOL hasVideo = NO, hasAudio = NO;
        for (NSInteger i = (NSInteger)toolbar.items.count - 1; i >= 0; i--) {
            NSToolbarItem *ti = toolbar.items[(NSUInteger)i];
            if ([ti.itemIdentifier isEqualToString:kISVideoOnlyID]) {
                if (ti.view) hasVideo = YES; else [toolbar removeItemAtIndex:(NSUInteger)i];
            } else if ([ti.itemIdentifier isEqualToString:kISAudioOnlyID]) {
                if (ti.view) hasAudio = YES; else [toolbar removeItemAtIndex:(NSUInteger)i];
            }
        }
        if (hasVideo && hasAudio) return;

        NSUInteger insertIdx = toolbar.items.count;
        for (NSUInteger i = 0; i < toolbar.items.count; i++) {
            if ([toolbar.items[i].itemIdentifier
                    isEqualToString:NSToolbarFlexibleSpaceItemIdentifier]) {
                insertIdx = i + 1;
                break;
            }
        }

        if (!hasAudio) {
            [toolbar insertItemWithItemIdentifier:kISAudioOnlyID atIndex:insertIdx];
            insertIdx++;
        }
        if (!hasVideo) {
            [toolbar insertItemWithItemIdentifier:kISVideoOnlyID atIndex:insertIdx];
        }

        if (sISAPI) sISAPI->log(@"[IndependentSlip] Toolbar buttons installed.");
    } @catch (NSException *e) {
        if (sISAPI) sISAPI->log(@"[IndependentSlip] Toolbar insert exception: %@", e.reason);
    }
}

static void IS_tryInstall(int attempt);
static void IS_tryInstall(int attempt) {
    if (attempt >= 30) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        for (NSWindow *w in [[NSApplication sharedApplication] windows]) {
            if (w.toolbar && w.toolbar.items.count > 0) {
                IS_addButtonsToToolbar(w.toolbar);
                return;
            }
        }
        IS_tryInstall(attempt + 1);
    });
}

static void IS_startInstallation(void) {
    __block id observer =
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowDidBecomeMainNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note) {
                NSWindow *win = note.object;
                if (win.toolbar) {
                    [[NSNotificationCenter defaultCenter] removeObserver:observer];
                    observer = nil;
                    IS_addButtonsToToolbar(win.toolbar);
                }
            }];
    IS_tryInstall(0);
}

// ---------------------------------------------------------------------------
// Plugin entry point
// ---------------------------------------------------------------------------
__attribute__((visibility("default")))
void SpliceKitPlugin_init(SpliceKitPluginAPI *api) {
    sISAPIStorage = *api;
    sISAPI = &sISAPIStorage;

    sISAPI->log(@"[IndependentSlip] Loading (toolbar buttons disabled — removing legacy items).");

    // Remove old IS_ toolbar items that may have been saved in FCP's toolbar
    // customisation preferences from a previous install of this plugin.
    api->executeOnMainThreadAsync(^{
        @try {
            NSToolbar *tb = [[NSApplication sharedApplication] mainWindow].toolbar;
            if (!tb) return;
            for (NSInteger i = (NSInteger)tb.items.count - 1; i >= 0; i--) {
                NSString *ident = tb.items[(NSUInteger)i].itemIdentifier;
                if ([ident isEqualToString:kISVideoOnlyID] ||
                    [ident isEqualToString:kISAudioOnlyID]) {
                    [tb removeItemAtIndex:(NSUInteger)i];
                    if (sISAPI) sISAPI->log(@"[IndependentSlip] Removed legacy toolbar item: %@", ident);
                }
            }
        } @catch (__unused NSException *) {}
    });

    sISAPI->log(@"[IndependentSlip] Loaded.");
}
