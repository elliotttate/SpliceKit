//
//  CloseOtherLibraries.m
//  com.splicekit.close-other-libraries
//
//  Self-contained "Close Other Libraries" File menu item for Final Cut Pro.
//  Survives SpliceKit patcher updates — the entire feature lives here.
//
//  Adds "Close Other Libraries" (⇧W) to the File menu, right after
//  "Close Library". Closes every open library except the currently active
//  one via each library's NSDocument close flow (so unsaved-change prompts
//  still appear normally).
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

@interface COLPlugin_Controller : NSObject
+ (instancetype)shared;
- (void)closeOtherLibraries:(id)sender;
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem;
@end

@implementation COLPlugin_Controller

+ (instancetype)shared {
    static COLPlugin_Controller *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)closeOtherLibraries:(id)sender {
    // Get the currently active/focused library via the app delegate's _targetLibrary.
    id delegate = [[NSApplication sharedApplication] delegate];

    id activeLib = nil;
    SEL targetLibSel = NSSelectorFromString(@"_targetLibrary");
    if ([delegate respondsToSelector:targetLibSel]) {
        activeLib = ((id (*)(id, SEL))objc_msgSend)(delegate, targetLibSel);
    }

    // Enumerate all open libraries.
    Class libDocClass = objc_getClass("FFLibraryDocument");
    if (!libDocClass) return;
    id allLibs = ((id (*)(id, SEL))objc_msgSend)(
        libDocClass, NSSelectorFromString(@"copyActiveLibraries"));
    if (![allLibs isKindOfClass:[NSArray class]]) return;

    NSArray *libs = (NSArray *)allLibs;
    if (libs.count <= 1) return;

    for (id lib in libs) {
        if (activeLib && lib == activeLib) continue;
        // Close via the library's NSDocument (triggers FCP's close flow including save prompt).
        SEL libDocSel = NSSelectorFromString(@"libraryDocument");
        id doc = [lib respondsToSelector:libDocSel]
            ? ((id (*)(id, SEL))objc_msgSend)(lib, libDocSel) : nil;
        if (doc && [doc respondsToSelector:@selector(close)]) {
            ((void (*)(id, SEL))objc_msgSend)(doc, @selector(close));
        }
    }

    if (sAPI) sAPI->log(@"[CloseOtherLibraries] Closed other libraries.");
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action != @selector(closeOtherLibraries:)) return YES;
    Class libDocClass = objc_getClass("FFLibraryDocument");
    if (!libDocClass) return NO;
    id allLibs = ((id (*)(id, SEL))objc_msgSend)(
        libDocClass, NSSelectorFromString(@"copyActiveLibraries"));
    NSInteger count = [allLibs isKindOfClass:[NSArray class]] ? [(NSArray *)allLibs count] : 0;
    return count > 1;
}

@end

// ---------------------------------------------------------------------------
// Menu item injection into the File menu
// ---------------------------------------------------------------------------

static void COL_addMenuItemIfNeeded(void) {
    @try {
        NSMenu *mainMenu = [NSApp mainMenu];
        if (!mainMenu) return;

        NSMenu *fileMenu = nil;
        for (NSMenuItem *topItem in mainMenu.itemArray) {
            if ([topItem.title isEqualToString:@"File"] && topItem.submenu) {
                fileMenu = topItem.submenu;
                break;
            }
        }
        if (!fileMenu) return;

        for (NSMenuItem *item in fileMenu.itemArray) {
            if ([item.title isEqualToString:@"Close Other Libraries"]) return;
        }

        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:@"Close Other Libraries"
                   action:@selector(closeOtherLibraries:)
            keyEquivalent:@"W"];
        item.keyEquivalentModifierMask = NSEventModifierFlagShift;
        item.target = [COLPlugin_Controller shared];

        BOOL inserted = NO;
        for (NSInteger i = 0; i < fileMenu.numberOfItems; i++) {
            if ([[fileMenu itemAtIndex:i].title isEqualToString:@"Close Library"]) {
                [fileMenu insertItem:item atIndex:i + 1];
                inserted = YES;
                break;
            }
        }
        if (!inserted) {
            [fileMenu insertItem:item atIndex:1];
        }

        if (sAPI) sAPI->log(@"[CloseOtherLibraries] Added to File menu.");
    } @catch (NSException *e) {
        if (sAPI) sAPI->log(@"[CloseOtherLibraries] Menu inject exception: %@", e.reason);
    }
}

// ---------------------------------------------------------------------------
// Plugin entry point
// ---------------------------------------------------------------------------

__attribute__((visibility("default")))
void SpliceKitPlugin_init(SpliceKitPluginAPI *api) {
    sAPIStorage = *api;
    sAPI = &sAPIStorage;

    sAPI->log(@"[CloseOtherLibraries] Loading.");

    api->executeOnMainThreadAsync(^{
        COL_addMenuItemIfNeeded();
    });

    sAPI->log(@"[CloseOtherLibraries] Loaded.");
}
