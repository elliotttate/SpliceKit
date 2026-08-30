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

        // Locate the Edit menu by content (an item with action paste:) rather than
        // by localized title, so this works on non-English FCP builds too.
        NSMenu *editMenu = nil;
        NSInteger pasteIdx = -1;
        SEL pasteSel = NSSelectorFromString(@"paste:");
        for (NSMenuItem *topItem in mainMenu.itemArray) {
            NSMenu *submenu = topItem.submenu;
            if (!submenu) continue;
            for (NSInteger i = 0; i < submenu.numberOfItems; i++) {
                NSMenuItem *item = [submenu itemAtIndex:i];
                if (item.action == pasteSel) {
                    editMenu = submenu;
                    pasteIdx = i;
                    break;
                }
            }
            if (editMenu) break;
        }
        if (!editMenu || pasteIdx < 0) {
            if (sAPI) sAPI->log(@"[PasteOverwrite] Could not find Paste item — skipping");
            return;
        }

        // Duplicate check by action selector, not localized title.
        for (NSInteger i = 0; i < editMenu.numberOfItems; i++) {
            if ([editMenu itemAtIndex:i].action == @selector(pasteOverwrite:)) return;
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
