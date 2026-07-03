//
//  PasteOverwrite.m
//  com.splicekit.paste-overwrite
//
//  Self-contained "Paste Overwrite" Edit menu item for Final Cut Pro.
//  Survives SpliceKit patcher updates — the entire feature lives here.
//
//  Adds "Paste Overwrite" (⌥V) to the Edit menu, right after the native
//  "Paste" item. The actual paste-overwrite edit (blade → select range →
//  delete selection only → paste) is implemented by the host's built-in
//  "timeline.action" RPC method with action="pasteOverwrite" — this plugin
//  only owns the menu item and calls back into the host via the documented
//  RPC passthrough, so it doesn't depend on any internal host symbols.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "SpliceKitPluginAPI.h"

static SpliceKitPluginAPI  sAPIStorage;
static SpliceKitPluginAPI *sAPI = NULL;

// ---------------------------------------------------------------------------
// Target/action controller
// ---------------------------------------------------------------------------

@interface POPlugin_Controller : NSObject
+ (instancetype)shared;
- (void)pasteOverwrite:(id)sender;
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem;
@end

@implementation POPlugin_Controller

+ (instancetype)shared {
    static POPlugin_Controller *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)pasteOverwrite:(id)sender {
    // Dispatch async so the menu can close before the operation starts.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sAPI) {
            sAPI->callMethod(@{@"method": @"timeline.action",
                                @"params": @{@"action": @"pasteOverwrite"}});
        }
    });
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action != @selector(pasteOverwrite:)) return YES;
    // Enabled when FCP native clipboard data is present OR FCPXML is on the pasteboard.
    Class ffpbClass = objc_getClass("FFPasteboard");
    if (ffpbClass) {
        id ffpb = ((id (*)(id, SEL, id))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)((id)ffpbClass, @selector(alloc)),
            NSSelectorFromString(@"initWithName:"), NSPasteboardNameGeneral);
        if (((BOOL (*)(id, SEL, BOOL))objc_msgSend)(ffpb, NSSelectorFromString(@"hasEdits:"), NO))
            return YES;
    }
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    SEL containsXMLSel = NSSelectorFromString(@"containsXML");
    if ([pb respondsToSelector:containsXMLSel] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(pb, containsXMLSel))
        return YES;
    return NO;
}

@end

// ---------------------------------------------------------------------------
// Menu item injection into the Edit menu
// ---------------------------------------------------------------------------

static void PO_addMenuItemIfNeeded(void) {
    @try {
        NSMenu *mainMenu = [NSApp mainMenu];
        if (!mainMenu) return;

        NSInteger editIdx = [mainMenu indexOfItemWithTitle:@"Edit"];
        if (editIdx < 0) return;
        NSMenu *editMenu = [[mainMenu itemAtIndex:editIdx] submenu];
        if (!editMenu) return;

        if ([editMenu indexOfItemWithTitle:@"Paste Overwrite"] >= 0) return;

        // Find the native "Paste" item (action = paste:).
        NSInteger pasteIdx = -1;
        for (NSInteger i = 0; i < editMenu.numberOfItems; i++) {
            NSMenuItem *item = [editMenu itemAtIndex:i];
            if ([item.title isEqualToString:@"Paste"] &&
                item.action == NSSelectorFromString(@"paste:")) {
                pasteIdx = i;
                break;
            }
        }
        if (pasteIdx < 0) {
            if (sAPI) sAPI->log(@"[PasteOverwrite] Could not find Paste item in Edit menu — skipping");
            return;
        }

        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Paste Overwrite"
                                                       action:@selector(pasteOverwrite:)
                                                keyEquivalent:@"v"];
        item.keyEquivalentModifierMask = NSEventModifierFlagOption;
        item.target = [POPlugin_Controller shared];

        [editMenu insertItem:item atIndex:pasteIdx + 1];

        if (sAPI) sAPI->log(@"[PasteOverwrite] Inserted 'Paste Overwrite' into Edit menu at index %ld",
                             (long)(pasteIdx + 1));
    } @catch (NSException *e) {
        if (sAPI) sAPI->log(@"[PasteOverwrite] Menu inject exception: %@", e.reason);
    }
}

// ---------------------------------------------------------------------------
// Plugin entry point
// ---------------------------------------------------------------------------

__attribute__((visibility("default")))
void SpliceKitPlugin_init(SpliceKitPluginAPI *api) {
    sAPIStorage = *api;
    sAPI = &sAPIStorage;

    sAPI->log(@"[PasteOverwrite] Loading.");

    api->executeOnMainThreadAsync(^{
        PO_addMenuItemIfNeeded();
    });

    sAPI->log(@"[PasteOverwrite] Loaded.");
}
