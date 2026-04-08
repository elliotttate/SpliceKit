//
//  SpliceKit.m
//  Main entry point — this is where everything starts.
//
//  The __attribute__((constructor)) at the bottom fires before FCP's main() runs.
//  From there we: set up logging, patch out crash-prone code paths (CloudContent,
//  shutdown hang), and wait for the app to finish launching. Once it does, we
//  install our menu, toolbar buttons, feature swizzles, and spin up the server.
//

#import "SpliceKit.h"
#import "SpliceKitLua.h"
#import "SpliceKitCommandPalette.h"
#import "SpliceKitDebugUI.h"
#import <AppKit/AppKit.h>

#pragma mark - Logging
//
// We log to both NSLog (shows up in Console.app) and a file on disk.
// The file is invaluable for debugging crashes that happened while you
// weren't looking at Console — just `cat ~/Library/Logs/SpliceKit/splicekit.log`.
//

static NSString *sLogPath = nil;
static NSFileHandle *sLogHandle = nil;
static dispatch_queue_t sLogQueue = nil;

static void SpliceKit_initLogging(void) {
    sLogQueue = dispatch_queue_create("com.splicekit.log", DISPATCH_QUEUE_SERIAL);

    NSString *logDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit"];
    [[NSFileManager defaultManager] createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:nil];
    sLogPath = [logDir stringByAppendingPathComponent:@"splicekit.log"];

    // Start fresh each launch so the log doesn't grow forever
    [[NSFileManager defaultManager] createFileAtPath:sLogPath contents:nil attributes:nil];
    sLogHandle = [NSFileHandle fileHandleForWritingAtPath:sLogPath];
    [sLogHandle seekToEndOfFile];
}

void SpliceKit_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    BOOL includeThreadInfo = [[NSUserDefaults standardUserDefaults] boolForKey:@"LogThread"];
    NSString *threadLabel = @"";
    if (includeThreadInfo) {
        NSThread *thread = [NSThread currentThread];
        NSString *name = thread.isMainThread ? @"main" : thread.name;
        if (name.length == 0) {
            name = [NSString stringWithFormat:@"%p", thread];
        }
        threadLabel = [NSString stringWithFormat:@"[%@] ", name];
    }

    NSString *consolePrefix = threadLabel.length
        ? [NSString stringWithFormat:@"[SpliceKit] %@", threadLabel]
        : @"[SpliceKit] ";
    NSLog(@"%@%@", consolePrefix, message);

    // Append to log file on a serial queue so we don't block the caller
    if (sLogHandle && sLogQueue) {
        NSString *timestamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                            dateStyle:NSDateFormatterNoStyle
                                                            timeStyle:NSDateFormatterMediumStyle];
        NSString *line = [NSString stringWithFormat:@"[%@] [SpliceKit] %@%@\n",
                          timestamp, threadLabel, message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        dispatch_async(sLogQueue, ^{
            [sLogHandle writeData:data];
            [sLogHandle synchronizeFile];
        });
    }
}

#pragma mark - Socket Path
//
// FCP runs in a partial sandbox. Our entitlements grant read-write to "/",
// so /tmp usually works. But on some setups it doesn't — the sandbox silently
// denies the write. We probe for it and fall back to the app's cache dir.
//

static char sSocketPath[1024] = {0};

const char *SpliceKit_getSocketPath(void) {
    if (sSocketPath[0] != '\0') return sSocketPath;

    NSString *path = @"/tmp/splicekit.sock";

    // Quick write test to see if the sandbox lets us use /tmp
    NSString *testPath = @"/tmp/splicekit_test";
    BOOL canWrite = [[NSFileManager defaultManager] createFileAtPath:testPath
                                                            contents:[@"test" dataUsingEncoding:NSUTF8StringEncoding]
                                                          attributes:nil];
    if (canWrite) {
        [[NSFileManager defaultManager] removeItemAtPath:testPath error:nil];
    } else {
        // /tmp blocked — use the container instead
        NSString *cacheDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/SpliceKit"];
        [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];
        path = [cacheDir stringByAppendingPathComponent:@"splicekit.sock"];
        SpliceKit_log(@"Using fallback socket path: %@", path);
    }

    strncpy(sSocketPath, [path UTF8String], sizeof(sSocketPath) - 1);
    return sSocketPath;
}

#pragma mark - Cached Class References
//
// We look these up once and stash them globally. Most of these come from Flexo.framework
// (FCP's core editing engine). If Apple renames them in a future version, the compatibility
// check below will tell us exactly which ones are missing.
//

Class SpliceKit_FFAnchoredTimelineModule = nil;
Class SpliceKit_FFAnchoredSequence = nil;
Class SpliceKit_FFLibrary = nil;
Class SpliceKit_FFLibraryDocument = nil;
Class SpliceKit_FFEditActionMgr = nil;
Class SpliceKit_FFModelDocument = nil;
Class SpliceKit_FFPlayer = nil;
Class SpliceKit_FFActionContext = nil;
Class SpliceKit_PEAppController = nil;
Class SpliceKit_PEDocument = nil;

#pragma mark - Compatibility Check

// Runs after FCP finishes loading all its frameworks.
// Looks up each critical class by name and caches the reference.
// If something's missing, we log it but keep going — partial functionality
// is better than no functionality.
static void SpliceKit_checkCompatibility(void) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = info[@"CFBundleShortVersionString"];
    NSString *build = info[@"CFBundleVersion"];
    SpliceKit_log(@"FCP version %@ (build %@)", version, build);

    struct { const char *name; Class *ref; } classes[] = {
        {"FFAnchoredTimelineModule", &SpliceKit_FFAnchoredTimelineModule},
        {"FFAnchoredSequence",       &SpliceKit_FFAnchoredSequence},
        {"FFLibrary",                &SpliceKit_FFLibrary},
        {"FFLibraryDocument",        &SpliceKit_FFLibraryDocument},
        {"FFEditActionMgr",          &SpliceKit_FFEditActionMgr},
        {"FFModelDocument",          &SpliceKit_FFModelDocument},
        {"FFPlayer",                 &SpliceKit_FFPlayer},
        {"FFActionContext",          &SpliceKit_FFActionContext},
        {"PEAppController",         &SpliceKit_PEAppController},
        {"PEDocument",              &SpliceKit_PEDocument},
    };

    int found = 0, total = sizeof(classes) / sizeof(classes[0]);
    for (int i = 0; i < total; i++) {
        *classes[i].ref = objc_getClass(classes[i].name);
        if (*classes[i].ref) {
            // Log the method count as a quick sanity check — if it's wildly
            // different from what we expect, the class might have been gutted
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(*classes[i].ref, &methodCount);
            free(methods);
            SpliceKit_log(@"  OK: %s (%u methods)", classes[i].name, methodCount);
            found++;
        } else {
            SpliceKit_log(@"  MISSING: %s", classes[i].name);
        }
    }
    SpliceKit_log(@"Class check: %d/%d found", found, total);
}

#pragma mark - SpliceKit Menu
//
// We add our own top-level "SpliceKit" menu to FCP's menu bar, right before Help.
// It has entries for the transcript editor, command palette, and a submenu of
// toggleable options (effect drag, pinch zoom, etc).
//

@interface SpliceKitMenuController : NSObject <NSMenuDelegate>
+ (instancetype)shared;
- (void)toggleTranscriptPanel:(id)sender;
- (void)toggleCaptionPanel:(id)sender;
- (void)toggleCommandPalette:(id)sender;
- (void)toggleLuaPanel:(id)sender;
- (void)runLuaScript:(id)sender;
- (void)openLuaScriptsFolder:(id)sender;
- (void)toggleEffectDragAsAdjustmentClip:(id)sender;
- (void)toggleViewerPinchZoom:(id)sender;
- (void)toggleVideoOnlyKeepsAudioDisabled:(id)sender;
- (void)toggleSuppressAutoImport:(id)sender;
- (void)editLLadder:(id)sender;
- (void)editJLadder:(id)sender;
- (void)setDefaultConformFit:(id)sender;
- (void)setDefaultConformFill:(id)sender;
- (void)setDefaultConformNone:(id)sender;
@property (nonatomic, weak) NSButton *toolbarButton;
@property (nonatomic, weak) NSButton *paletteToolbarButton;
@property (nonatomic, strong) NSMenu *luaScriptsMenu;
@end

@implementation SpliceKitMenuController

+ (instancetype)shared {
    static SpliceKitMenuController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)toggleTranscriptPanel:(id)sender {
    Class panelClass = objc_getClass("SpliceKitTranscriptPanel");
    if (!panelClass) {
        SpliceKit_log(@"SpliceKitTranscriptPanel class not found");
        return;
    }
    id panel = ((id (*)(id, SEL))objc_msgSend)((id)panelClass, @selector(sharedPanel));
    BOOL visible = ((BOOL (*)(id, SEL))objc_msgSend)(panel, @selector(isVisible));
    if (visible) {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(hidePanel));
    } else {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(showPanel));
    }
    // Update toolbar button pressed state
    BOOL nowVisible = !visible;
    [self updateToolbarButtonState:nowVisible];
}

- (void)toggleCaptionPanel:(id)sender {
    Class panelClass = objc_getClass("SpliceKitCaptionPanel");
    if (!panelClass) {
        SpliceKit_log(@"SpliceKitCaptionPanel class not found");
        return;
    }
    id panel = ((id (*)(id, SEL))objc_msgSend)((id)panelClass, @selector(sharedPanel));
    BOOL visible = ((BOOL (*)(id, SEL))objc_msgSend)(panel, @selector(isVisible));
    if (visible) {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(hidePanel));
    } else {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(showPanel));
    }
}

- (void)toggleCommandPalette:(id)sender {
    [[SpliceKitCommandPalette sharedPalette] togglePalette];
}

- (void)toggleLuaPanel:(id)sender {
    Class panelClass = objc_getClass("SpliceKitLuaPanel");
    if (!panelClass) {
        SpliceKit_log(@"SpliceKitLuaPanel class not found");
        return;
    }
    id panel = ((id (*)(id, SEL))objc_msgSend)((id)panelClass, @selector(sharedPanel));
    BOOL visible = ((BOOL (*)(id, SEL))objc_msgSend)(panel, @selector(isVisible));
    if (visible) {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(hidePanel));
    } else {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(showPanel));
    }
}

#pragma mark - Lua Scripts Menu

// Run a .lua script when its menu item is clicked.
// The full path is stored in the menu item's representedObject.
- (void)runLuaScript:(id)sender {
    NSMenuItem *item = (NSMenuItem *)sender;
    NSString *path = item.representedObject;
    if (!path) return;

    SpliceKit_log(@"[Lua] Running script: %@", [path lastPathComponent]);

    // Run on a background thread so the menu dismisses immediately
    // and the main thread stays free for SpliceKit_executeOnMainThread callbacks.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = SpliceKitLua_executeFile(path);
        NSString *error = result[@"error"];
        NSString *output = result[@"output"];
        if (error) {
            SpliceKit_log(@"[Lua] Error in %@: %@", [path lastPathComponent], error);
        } else if (output.length > 0) {
            SpliceKit_log(@"[Lua] %@: %@", [path lastPathComponent], output);
        } else {
            SpliceKit_log(@"[Lua] %@ completed", [path lastPathComponent]);
        }
    });
}

// Open the scripts folder in Finder so the user can add/edit scripts.
- (void)openLuaScriptsFolder:(id)sender {
    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *scriptsDir = [appSupport stringByAppendingPathComponent:@"SpliceKit/lua/menu"];
    // Create the directory if it doesn't exist yet
    [[NSFileManager defaultManager] createDirectoryAtPath:scriptsDir
                              withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:scriptsDir]];
}

// NSMenuDelegate — rebuild the Lua Scripts submenu every time it opens.
// This picks up newly added/removed scripts without restarting FCP.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != self.luaScriptsMenu) return;

    [menu removeAllItems];

    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *menuDir = [appSupport stringByAppendingPathComponent:@"SpliceKit/lua/menu"];

    // Create the directory if it doesn't exist
    [[NSFileManager defaultManager] createDirectoryAtPath:menuDir
                              withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];

    // Enumerate .lua files, sorted alphabetically
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:menuDir error:nil];
    NSMutableArray *luaFiles = [NSMutableArray array];
    for (NSString *file in files) {
        if ([file.pathExtension isEqualToString:@"lua"]) {
            [luaFiles addObject:file];
        }
    }
    [luaFiles sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    if (luaFiles.count == 0) {
        NSMenuItem *emptyItem = [[NSMenuItem alloc]
            initWithTitle:@"No scripts — add .lua files to menu/ folder"
                   action:nil
            keyEquivalent:@""];
        emptyItem.enabled = NO;
        [menu addItem:emptyItem];
    } else {
        for (NSString *file in luaFiles) {
            // Display name: strip .lua extension and leading numbers/underscores
            // "01_blade_every_2s.lua" → "blade every 2s"
            NSString *displayName = [file stringByDeletingPathExtension];
            // Strip leading "01_", "02_" etc. for ordering without showing numbers
            NSRegularExpression *regex = [NSRegularExpression
                regularExpressionWithPattern:@"^\\d+[_\\-\\s]+"
                                     options:0 error:nil];
            displayName = [regex stringByReplacingMatchesInString:displayName
                                                         options:0
                                                           range:NSMakeRange(0, displayName.length)
                                                withTemplate:@""];
            // Replace underscores with spaces
            displayName = [displayName stringByReplacingOccurrencesOfString:@"_" withString:@" "];

            NSString *fullPath = [menuDir stringByAppendingPathComponent:file];

            NSMenuItem *item = [[NSMenuItem alloc]
                initWithTitle:displayName
                       action:@selector(runLuaScript:)
                keyEquivalent:@""];
            item.target = [SpliceKitMenuController shared];
            item.representedObject = fullPath;
            item.enabled = YES;

            // Read the first comment line for a tooltip
            NSString *content = [NSString stringWithContentsOfFile:fullPath
                                                         encoding:NSUTF8StringEncoding
                                                            error:nil];
            if (content) {
                // Look for first "-- " comment line
                for (NSString *line in [content componentsSeparatedByString:@"\n"]) {
                    NSString *trimmed = [line stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
                    if ([trimmed hasPrefix:@"-- "] && trimmed.length > 3) {
                        item.toolTip = [trimmed substringFromIndex:3];
                        break;
                    } else if ([trimmed hasPrefix:@"--[["]) {
                        // Multi-line comment — grab the next non-empty line
                        continue;
                    } else if (trimmed.length > 0 && ![trimmed hasPrefix:@"--"]) {
                        break; // hit code, stop looking
                    } else if (trimmed.length > 2 && [trimmed hasPrefix:@"  "]) {
                        // Indented line inside --[[ block — use as tooltip
                        item.toolTip = [trimmed stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
                        break;
                    }
                }
            }

            [menu addItem:item];
        }
    }

    [menu addItem:[NSMenuItem separatorItem]];

    // "Open Scripts Folder" item at the bottom
    NSMenuItem *openFolderItem = [[NSMenuItem alloc]
        initWithTitle:@"Open Scripts Folder..."
               action:@selector(openLuaScriptsFolder:)
        keyEquivalent:@""];
    openFolderItem.target = [SpliceKitMenuController shared];
    openFolderItem.enabled = YES;
    [menu addItem:openFolderItem];
}

- (void)toggleEffectDragAsAdjustmentClip:(id)sender {
    BOOL newState = !SpliceKit_isEffectDragAsAdjustmentClipEnabled();
    SpliceKit_setEffectDragAsAdjustmentClipEnabled(newState);
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        [(NSMenuItem *)sender setState:newState ? NSControlStateValueOn : NSControlStateValueOff];
    }
}

- (void)toggleViewerPinchZoom:(id)sender {
    BOOL newState = !SpliceKit_isViewerPinchZoomEnabled();
    SpliceKit_setViewerPinchZoomEnabled(newState);
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        [(NSMenuItem *)sender setState:newState ? NSControlStateValueOn : NSControlStateValueOff];
    }
}

- (void)toggleVideoOnlyKeepsAudioDisabled:(id)sender {
    BOOL newState = !SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled();
    SpliceKit_setVideoOnlyKeepsAudioDisabledEnabled(newState);
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        [(NSMenuItem *)sender setState:newState ? NSControlStateValueOn : NSControlStateValueOff];
    }
}

- (void)toggleSuppressAutoImport:(id)sender {
    BOOL newState = !SpliceKit_isSuppressAutoImportEnabled();
    SpliceKit_setSuppressAutoImportEnabled(newState);
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        [(NSMenuItem *)sender setState:newState ? NSControlStateValueOn : NSControlStateValueOff];
    }
}

// --- Playback Speed ladder editors ---

static NSString *SpliceKit_ladderToString(NSArray<NSNumber *> *ladder) {
    NSMutableArray *strs = [NSMutableArray array];
    for (NSNumber *n in ladder) {
        float v = [n floatValue];
        if (v == (int)v) [strs addObject:[NSString stringWithFormat:@"%d", (int)v]];
        else [strs addObject:[NSString stringWithFormat:@"%.1f", v]];
    }
    return [strs componentsJoinedByString:@", "];
}

static NSArray<NSNumber *> *SpliceKit_parseLadderString(NSString *str) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *part in [str componentsSeparatedByString:@","]) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length > 0) {
            float val = [trimmed floatValue];
            if (val > 0.0f) [result addObject:@(val)];
        }
    }
    // Sort ascending
    [result sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [a compare:b];
    }];
    return result;
}

- (void)editLLadder:(id)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"L Key Speeds";
        alert.informativeText = @"Each press of L advances to the next speed.\nEnter values separated by commas:";
        [alert addButtonWithTitle:@"Save"];
        [alert addButtonWithTitle:@"Cancel"];
        NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
        input.stringValue = SpliceKit_ladderToString(SpliceKit_getLLadder());
        alert.accessoryView = input;
        [alert.window makeFirstResponder:input];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            NSArray *speeds = SpliceKit_parseLadderString(input.stringValue);
            if (speeds.count > 0) {
                SpliceKit_setLLadder(speeds);
                if ([sender isKindOfClass:[NSMenuItem class]])
                    [(NSMenuItem *)sender setTitle:
                        [NSString stringWithFormat:@"L Speeds: %@", SpliceKit_ladderToString(speeds)]];
            }
        }
    });
}

- (void)editJLadder:(id)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"J Key Speeds";
        alert.informativeText = @"Each press of J advances to the next reverse speed.\nEnter values separated by commas:";
        [alert addButtonWithTitle:@"Save"];
        [alert addButtonWithTitle:@"Cancel"];
        NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
        input.stringValue = SpliceKit_ladderToString(SpliceKit_getJLadder());
        alert.accessoryView = input;
        [alert.window makeFirstResponder:input];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            NSArray *speeds = SpliceKit_parseLadderString(input.stringValue);
            if (speeds.count > 0) {
                SpliceKit_setJLadder(speeds);
                if ([sender isKindOfClass:[NSMenuItem class]])
                    [(NSMenuItem *)sender setTitle:
                        [NSString stringWithFormat:@"J Speeds: %@", SpliceKit_ladderToString(speeds)]];
            }
        }
    });
}

- (void)setDefaultConformFit:(id)sender {
    SpliceKit_setDefaultSpatialConformType(@"fit");
    [self _updateConformMenuFromSender:sender];
}

- (void)setDefaultConformFill:(id)sender {
    SpliceKit_setDefaultSpatialConformType(@"fill");
    [self _updateConformMenuFromSender:sender];
}

- (void)setDefaultConformNone:(id)sender {
    SpliceKit_setDefaultSpatialConformType(@"none");
    [self _updateConformMenuFromSender:sender];
}

- (void)_updateConformMenuFromSender:(id)sender {
    if (![sender isKindOfClass:[NSMenuItem class]]) return;
    NSMenu *menu = [(NSMenuItem *)sender menu];
    if (!menu) return;
    NSString *current = SpliceKit_getDefaultSpatialConformType();
    for (NSMenuItem *item in menu.itemArray) {
        NSString *tag = nil;
        if (item.action == @selector(setDefaultConformFit:)) tag = @"fit";
        else if (item.action == @selector(setDefaultConformFill:)) tag = @"fill";
        else if (item.action == @selector(setDefaultConformNone:)) tag = @"none";
        if (tag) {
            item.state = [current isEqualToString:tag] ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
}

- (void)updateToolbarButtonState:(BOOL)active {
    NSButton *btn = self.toolbarButton;
    if (!btn) return;
    btn.state = active ? NSControlStateValueOn : NSControlStateValueOff;
    // Match FCP's native toolbar style — active buttons get a blue accent tint
    if (active) {
        btn.contentTintColor = [NSColor controlAccentColor];
        btn.bezelColor = [NSColor colorWithWhite:0.0 alpha:0.5];
    } else {
        btn.contentTintColor = nil;
        btn.bezelColor = nil;
    }
}

@end

static void SpliceKit_installMenu(void) {
    NSMenu *mainMenu = [NSApp mainMenu];
    if (!mainMenu) {
        SpliceKit_log(@"No main menu found - skipping menu install");
        return;
    }

    // Create "Enhancements" top-level menu
    NSMenu *bridgeMenu = [[NSMenu alloc] initWithTitle:@"Enhancements"];

    NSMenuItem *transcriptItem = [[NSMenuItem alloc]
        initWithTitle:@"Transcript Editor"
               action:@selector(toggleTranscriptPanel:)
        keyEquivalent:@"t"];
    transcriptItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    transcriptItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:transcriptItem];

    NSMenuItem *captionItem = [[NSMenuItem alloc]
        initWithTitle:@"Social Captions"
               action:@selector(toggleCaptionPanel:)
        keyEquivalent:@"c"];
    captionItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    captionItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:captionItem];

    NSMenuItem *paletteItem = [[NSMenuItem alloc]
        initWithTitle:@"Command Palette"
               action:@selector(toggleCommandPalette:)
        keyEquivalent:@"p"];
    paletteItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    paletteItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:paletteItem];

    NSMenuItem *luaItem = [[NSMenuItem alloc]
        initWithTitle:@"Lua REPL"
               action:@selector(toggleLuaPanel:)
        keyEquivalent:@"l"];
    luaItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    luaItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:luaItem];

    // --- Lua Scripts submenu (dynamically populated) ---
    NSMenu *luaScriptsMenu = [[NSMenu alloc] initWithTitle:@"Lua Scripts"];
    luaScriptsMenu.delegate = [SpliceKitMenuController shared];
    luaScriptsMenu.autoenablesItems = NO;
    [SpliceKitMenuController shared].luaScriptsMenu = luaScriptsMenu;
    NSMenuItem *luaScriptsMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Lua Scripts"
               action:nil
        keyEquivalent:@""];
    luaScriptsMenuItem.submenu = luaScriptsMenu;
    [bridgeMenu addItem:luaScriptsMenuItem];

    // --- Playback Speed submenu ---
    [bridgeMenu addItem:[NSMenuItem separatorItem]];

    NSMenu *speedMenu = [[NSMenu alloc] initWithTitle:@"Playback Speed"];
    SpliceKitMenuController *mc = [SpliceKitMenuController shared];

    NSMenuItem *lItem = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"L Speeds: %@",
                       SpliceKit_ladderToString(SpliceKit_getLLadder())]
               action:@selector(editLLadder:)
        keyEquivalent:@""];
    lItem.target = mc;
    [speedMenu addItem:lItem];

    NSMenuItem *jItem = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"J Speeds: %@",
                       SpliceKit_ladderToString(SpliceKit_getJLadder())]
               action:@selector(editJLadder:)
        keyEquivalent:@""];
    jItem.target = mc;
    [speedMenu addItem:jItem];

    NSMenuItem *speedMenuItem = [[NSMenuItem alloc] initWithTitle:@"Playback Speed" action:nil keyEquivalent:@""];
    speedMenuItem.submenu = speedMenu;
    [bridgeMenu addItem:speedMenuItem];

    // --- Options submenu ---
    [bridgeMenu addItem:[NSMenuItem separatorItem]];

    NSMenu *optionsMenu = [[NSMenu alloc] initWithTitle:@"Options"];

    NSMenuItem *effectDragItem = [[NSMenuItem alloc]
        initWithTitle:@"Effect Drag as Adjustment Clip"
               action:@selector(toggleEffectDragAsAdjustmentClip:)
        keyEquivalent:@""];
    effectDragItem.target = [SpliceKitMenuController shared];
    effectDragItem.state = SpliceKit_isEffectDragAsAdjustmentClipEnabled()
        ? NSControlStateValueOn : NSControlStateValueOff;
    [optionsMenu addItem:effectDragItem];

    NSMenuItem *pinchZoomItem = [[NSMenuItem alloc]
        initWithTitle:@"Viewer Pinch-to-Zoom"
               action:@selector(toggleViewerPinchZoom:)
        keyEquivalent:@""];
    pinchZoomItem.target = [SpliceKitMenuController shared];
    pinchZoomItem.state = SpliceKit_isViewerPinchZoomEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    [optionsMenu addItem:pinchZoomItem];

    NSMenuItem *videoOnlyKeepsAudioItem = [[NSMenuItem alloc]
        initWithTitle:@"Video-Only Edit Keeps Audio (Disabled)"
               action:@selector(toggleVideoOnlyKeepsAudioDisabled:)
        keyEquivalent:@""];
    videoOnlyKeepsAudioItem.target = [SpliceKitMenuController shared];
    videoOnlyKeepsAudioItem.state = SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled()
        ? NSControlStateValueOn : NSControlStateValueOff;
    [optionsMenu addItem:videoOnlyKeepsAudioItem];

    NSMenuItem *suppressAutoImportItem = [[NSMenuItem alloc]
        initWithTitle:@"Suppress Auto Import Window on Device Connect"
               action:@selector(toggleSuppressAutoImport:)
        keyEquivalent:@""];
    suppressAutoImportItem.target = [SpliceKitMenuController shared];
    suppressAutoImportItem.state = SpliceKit_isSuppressAutoImportEnabled()
        ? NSControlStateValueOn : NSControlStateValueOff;
    [optionsMenu addItem:suppressAutoImportItem];

    // --- Default Spatial Conform submenu ---
    NSMenu *conformMenu = [[NSMenu alloc] initWithTitle:@"Default Spatial Conform"];
    NSString *currentConform = SpliceKit_getDefaultSpatialConformType();

    NSMenuItem *conformFitItem = [[NSMenuItem alloc]
        initWithTitle:@"Fit (Default)" action:@selector(setDefaultConformFit:) keyEquivalent:@""];
    conformFitItem.target = [SpliceKitMenuController shared];
    conformFitItem.state = [currentConform isEqualToString:@"fit"] ? NSControlStateValueOn : NSControlStateValueOff;
    [conformMenu addItem:conformFitItem];

    NSMenuItem *conformFillItem = [[NSMenuItem alloc]
        initWithTitle:@"Fill" action:@selector(setDefaultConformFill:) keyEquivalent:@""];
    conformFillItem.target = [SpliceKitMenuController shared];
    conformFillItem.state = [currentConform isEqualToString:@"fill"] ? NSControlStateValueOn : NSControlStateValueOff;
    [conformMenu addItem:conformFillItem];

    NSMenuItem *conformNoneItem = [[NSMenuItem alloc]
        initWithTitle:@"None" action:@selector(setDefaultConformNone:) keyEquivalent:@""];
    conformNoneItem.target = [SpliceKitMenuController shared];
    conformNoneItem.state = [currentConform isEqualToString:@"none"] ? NSControlStateValueOn : NSControlStateValueOff;
    [conformMenu addItem:conformNoneItem];

    NSMenuItem *conformMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Default Spatial Conform" action:nil keyEquivalent:@""];
    conformMenuItem.submenu = conformMenu;
    [optionsMenu addItem:conformMenuItem];

    NSMenuItem *optionsMenuItem = [[NSMenuItem alloc] initWithTitle:@"Options" action:nil keyEquivalent:@""];
    optionsMenuItem.submenu = optionsMenu;
    [bridgeMenu addItem:optionsMenuItem];

    // Add the menu to the menu bar (before the last item which is usually "Help")
    NSMenuItem *bridgeMenuItem = [[NSMenuItem alloc] initWithTitle:@"Enhancements" action:nil keyEquivalent:@""];
    bridgeMenuItem.submenu = bridgeMenu;

    NSInteger helpIndex = [mainMenu indexOfItemWithTitle:@"Help"];
    if (helpIndex >= 0) {
        [mainMenu insertItem:bridgeMenuItem atIndex:helpIndex];
    } else {
        [mainMenu addItem:bridgeMenuItem];
    }

    SpliceKit_log(@"SpliceKit menu installed (Ctrl+Option+T Transcript, Ctrl+Option+C Captions, Cmd+Shift+P Palette, Ctrl+Option+L Lua REPL)");
}

static NSString * const kSpliceKitTranscriptToolbarID = @"SpliceKitTranscriptItemID";
static NSString * const kSpliceKitPaletteToolbarID = @"SpliceKitPaletteItemID";
static IMP sOriginalToolbarItemForIdentifier = NULL;

// We swizzle FCP's toolbar delegate so it knows about our custom toolbar items.
// When FCP asks "what item goes at this identifier?", we intercept our IDs and
// return our buttons. Everything else passes through to the original handler.
static id SpliceKit_toolbar_itemForItemIdentifier(id self, SEL _cmd, NSToolbar *toolbar,
                                                   NSString *identifier, BOOL willInsert) {
    if ([identifier isEqualToString:kSpliceKitTranscriptToolbarID]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:kSpliceKitTranscriptToolbarID];
        item.label = @"Transcript";
        item.paletteLabel = @"Transcript Editor";
        item.toolTip = @"Transcript Editor";

        NSImage *icon = [NSImage imageWithSystemSymbolName:@"text.quote"
                                  accessibilityDescription:@"Transcript Editor"];
        if (!icon) icon = [NSImage imageNamed:NSImageNameListViewTemplate];
        NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration
            configurationWithPointSize:13 weight:NSFontWeightMedium];
        icon = [icon imageWithSymbolConfiguration:config];

        NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 32, 25)];
        [button setButtonType:NSButtonTypePushOnPushOff];
        button.bezelStyle = NSBezelStyleTexturedRounded;
        button.bordered = YES;
        button.image = icon;
        button.alternateImage = icon;
        button.imagePosition = NSImageOnly;
        button.target = [SpliceKitMenuController shared];
        button.action = @selector(toggleTranscriptPanel:);

        [SpliceKitMenuController shared].toolbarButton = button;
        item.view = button;

        return item;
    }
    if ([identifier isEqualToString:kSpliceKitPaletteToolbarID]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:kSpliceKitPaletteToolbarID];
        item.label = @"Commands";
        item.paletteLabel = @"Command Palette";
        item.toolTip = @"Command Palette (Cmd+Shift+P)";

        NSImage *icon = [NSImage imageWithSystemSymbolName:@"command"
                                  accessibilityDescription:@"Command Palette"];
        if (!icon) icon = [NSImage imageNamed:NSImageNameSmartBadgeTemplate];
        NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration
            configurationWithPointSize:13 weight:NSFontWeightMedium];
        icon = [icon imageWithSymbolConfiguration:config];

        NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 32, 25)];
        [button setButtonType:NSButtonTypeMomentaryPushIn];
        button.bezelStyle = NSBezelStyleTexturedRounded;
        button.bordered = YES;
        button.image = icon;
        button.imagePosition = NSImageOnly;
        button.target = [SpliceKitMenuController shared];
        button.action = @selector(toggleCommandPalette:);

        [SpliceKitMenuController shared].paletteToolbarButton = button;
        item.view = button;

        return item;
    }
    // Call original
    return ((id (*)(id, SEL, NSToolbar *, NSString *, BOOL))sOriginalToolbarItemForIdentifier)(
        self, _cmd, toolbar, identifier, willInsert);
}

@implementation SpliceKitMenuController (Toolbar)

+ (void)installToolbarButton {
    // FCP's main window isn't ready immediately at launch — we need to wait
    // for it. We use a two-pronged approach: listen for the notification,
    // and also poll as a fallback in case we missed it.
    __block id observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowDidBecomeMainNotification
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
            NSWindow *window = note.object;
            if (window.toolbar) {
                [[NSNotificationCenter defaultCenter] removeObserver:observer];
                observer = nil;
                [SpliceKitMenuController addToolbarButtonToWindow:window];
            }
        }];

    // Also poll as fallback in case the notification already fired
    [self installToolbarButtonAttempt:0];
}

+ (void)installToolbarButtonAttempt:(int)attempt {
    if (attempt >= 30) {
        // 30 seconds is plenty. If there's no toolbar by now, something's wrong.
        SpliceKit_log(@"No main window for toolbar button after %d attempts", attempt);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // FCP sometimes has multiple windows — check all of them
        for (NSWindow *w in [NSApp windows]) {
            if (w.toolbar && w.toolbar.items.count > 0) {
                [SpliceKitMenuController addToolbarButtonToWindow:w];
                return;
            }
        }
        [self installToolbarButtonAttempt:attempt + 1];
    });
}

+ (void)addToolbarButtonToWindow:(NSWindow *)window {
    @try {
        NSToolbar *toolbar = window.toolbar;
        if (!toolbar) {
            SpliceKit_log(@"No toolbar on main window");
            return;
        }

        // We need to teach FCP's toolbar delegate about our custom item IDs.
        // The cleanest way is to swizzle the delegate's itemForItemIdentifier: method.
        id delegate = toolbar.delegate;
        if (!delegate) {
            SpliceKit_log(@"No toolbar delegate");
            return;
        }

        if (!sOriginalToolbarItemForIdentifier) {
            SEL sel = @selector(toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:);
            Method m = class_getInstanceMethod([delegate class], sel);
            if (m) {
                sOriginalToolbarItemForIdentifier = method_getImplementation(m);
                method_setImplementation(m, (IMP)SpliceKit_toolbar_itemForItemIdentifier);
                SpliceKit_log(@"Swizzled toolbar delegate %@ for custom item", NSStringFromClass([delegate class]));
            }
        }

        // Guard against double-insertion — can happen if both the notification
        // and the polling fallback fire. Also clean up stale items (no view).
        BOOL hasTranscript = NO, hasPalette = NO;
        for (NSInteger i = (NSInteger)toolbar.items.count - 1; i >= 0; i--) {
            NSToolbarItem *ti = toolbar.items[(NSUInteger)i];
            if ([ti.itemIdentifier isEqualToString:kSpliceKitTranscriptToolbarID]) {
                if (ti.view) {
                    if ([ti.view isKindOfClass:[NSButton class]])
                        [SpliceKitMenuController shared].toolbarButton = (NSButton *)ti.view;
                    hasTranscript = YES;
                } else {
                    [toolbar removeItemAtIndex:(NSUInteger)i];
                }
            } else if ([ti.itemIdentifier isEqualToString:kSpliceKitPaletteToolbarID]) {
                if (ti.view) {
                    if ([ti.view isKindOfClass:[NSButton class]])
                        [SpliceKitMenuController shared].paletteToolbarButton = (NSButton *)ti.view;
                    hasPalette = YES;
                } else {
                    [toolbar removeItemAtIndex:(NSUInteger)i];
                }
            }
        }
        if (hasTranscript && hasPalette) {
            SpliceKit_log(@"Both toolbar buttons already present — skipping");
            return;
        }

        // Insert our buttons just before the flexible space — that's where
        // they look most natural, grouped with FCP's own tool buttons.
        NSUInteger insertIdx = toolbar.items.count;
        for (NSUInteger i = 0; i < toolbar.items.count; i++) {
            NSToolbarItem *ti = toolbar.items[i];
            if ([ti.itemIdentifier isEqualToString:NSToolbarFlexibleSpaceItemIdentifier]) {
                insertIdx = i;
                break;
            }
        }
        if (!hasPalette) {
            [toolbar insertItemWithItemIdentifier:kSpliceKitPaletteToolbarID atIndex:insertIdx];
            SpliceKit_log(@"Command Palette toolbar button inserted at index %lu", (unsigned long)insertIdx);
            insertIdx++;
        }
        if (!hasTranscript) {
            [toolbar insertItemWithItemIdentifier:kSpliceKitTranscriptToolbarID atIndex:insertIdx];
            SpliceKit_log(@"Transcript toolbar button inserted at index %lu", (unsigned long)insertIdx);
        }

    } @catch (NSException *e) {
        SpliceKit_log(@"Failed to install toolbar button: %@", e.reason);
    }
}

@end

#pragma mark - App Launch Handler
//
// This fires once FCP is fully loaded and its UI is ready. We can't do most of
// our setup in the constructor because FCP's frameworks aren't loaded yet at that
// point — you'll get nil back from objc_getClass for anything in Flexo.framework.
//

static void SpliceKit_appDidLaunch(void) {
    SpliceKit_log(@"================================================");
    SpliceKit_log(@"App launched. Starting control server...");
    SpliceKit_log(@"================================================");

    // Run compatibility check now that all frameworks are loaded
    SpliceKit_checkCompatibility();

    // Count total loaded classes
    unsigned int classCount = 0;
    Class *allClasses = objc_copyClassList(&classCount);
    free(allClasses);
    SpliceKit_log(@"Total ObjC classes in process: %u", classCount);

    // Install Enhancements menu in the menu bar
    SpliceKit_installMenu();

    // Install toolbar button in FCP's main window
    [SpliceKitMenuController installToolbarButton];

    // Install transition freeze-extend swizzle (adds "Use Freeze Frames" button
    // to the "not enough extra media" dialog)
    SpliceKit_installTransitionFreezeExtendSwizzle();

    // Install effect-drag-as-adjustment-clip swizzle (allows dragging effects
    // to empty timeline space to create adjustment clips)
    SpliceKit_installEffectDragAsAdjustmentClip();

    // Install viewer pinch-to-zoom if previously enabled
    if (SpliceKit_isViewerPinchZoomEnabled()) {
        SpliceKit_installViewerPinchZoom();
    }

    // Install video-only-keeps-audio-disabled swizzle if previously enabled
    if (SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled()) {
        SpliceKit_installVideoOnlyKeepsAudioDisabled();
    }

    // Install suppress-auto-import swizzle if previously enabled. The mount-notification
    // observers were already set up at FCP launch before our dylib loaded, so we have
    // to intercept the handler methods themselves rather than the observer registration.
    if (SpliceKit_isSuppressAutoImportEnabled()) {
        SpliceKit_installSuppressAutoImport();
    }

    // Install default spatial conform swizzle if set to non-default value
    if (![SpliceKit_getDefaultSpatialConformType() isEqualToString:@"fit"]) {
        SpliceKit_installDefaultSpatialConformType();
    }

    // Install effect browser favorites context menu (always on)
    SpliceKit_installEffectFavoritesSwizzle();

    // Install FCPXML direct paste support (converts FCPXML on pasteboard
    // to native clipboard format so pasteAnchored: can handle it)
    SpliceKit_installFCPXMLPasteSwizzle();

    // Swizzle J/L to use configurable speed ladders
    SpliceKit_installPlaybackSpeedSwizzle();

    // Rebuild FCP's hidden Debug pane + Debug menu bar (Apple strips the NIB
    // and leaves the menu unassigned in release builds; we reconstruct both).
    SpliceKit_installDebugSettingsPanel();
    SpliceKit_installDebugMenuBar();

    // Start the control server on a background thread
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SpliceKit_startControlServer();
    });

    // Initialize Lua scripting VM
    SpliceKitLua_initialize();
}

#pragma mark - Crash Prevention & Startup Fixes
//
// FCP has a few code paths that crash or hang when running outside its normal
// signed/entitled environment. We patch them out before they have a chance to fire.
//
// These swizzles are applied in the constructor (before main), so they need to
// target classes that are available early — mostly Swift classes in the main
// binary and ProCore framework classes.
//

// Replacement IMPs for blocking problematic methods
static void noopMethod(id self, SEL _cmd) {
    SpliceKit_log(@"BLOCKED: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}

static void noopMethodWithArg(id self, SEL _cmd, id arg) {
    SpliceKit_log(@"BLOCKED: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}

static BOOL returnNO(id self, SEL _cmd) {
    SpliceKit_log(@"BLOCKED (returning NO): +[%@ %@]",
                  NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd));
    return NO;
}

// Silent variant — no logging. Used for high-frequency swizzles like isSPVEnabled
// which gets called dozens of times during startup.
static BOOL returnNO_silent(id self, SEL _cmd) {
    return NO;
}

static void noopMethodWith2Args(id self, SEL _cmd, id arg1, id arg2) {}

// PCUserDefaultsMigrator runs on quit and calls copyDataFromSource:toTarget:,
// which walks a potentially massive media directory tree via getattrlistbulk.
// On large libraries this hangs for 30+ seconds, making FCP feel like it froze.
// Since we don't need the migration, we just no-op it.
static void SpliceKit_fixShutdownHang(void) {
    Class migrator = objc_getClass("PCUserDefaultsMigrator");
    if (migrator) {
        SEL sel = NSSelectorFromString(@"copyDataFromSource:toTarget:");
        Method m = class_getInstanceMethod(migrator, sel);
        if (m) {
            method_setImplementation(m, (IMP)noopMethodWith2Args);
            SpliceKit_log(@"Swizzled PCUserDefaultsMigrator.copyDataFromSource: (fixes shutdown hang)");
        }
    }
}

// CloudContent/ImagePlayground crashes at launch because:
//   PEAppController.presentMainWindowOnAppLaunch: checks CloudContentFeatureFlag.isEnabled,
//   which triggers CloudContentCatalog.shared -> CCFirstLaunchHelper -> CloudKit.
//   Without proper iCloud entitlements, CloudKit throws an uncaught exception.
//
// Fix: make the feature flag return NO so the entire code path is skipped.
// Same deal with FFImagePlayground.isAvailable — it goes through a similar CloudKit path.
static void SpliceKit_disableCloudContent(void) {
    SpliceKit_log(@"Disabling CloudContent/ImagePlayground...");

    // Swift class names get mangled. Try the mangled name first, then the demangled form.
    Class ccFlag = objc_getClass("_TtC13Final_Cut_Pro23CloudContentFeatureFlag");
    if (!ccFlag) {
        ccFlag = objc_getClass("Final_Cut_Pro.CloudContentFeatureFlag");
    }

    if (ccFlag) {
        Method m = class_getClassMethod(ccFlag, @selector(isEnabled));
        if (m) {
            method_setImplementation(m, (IMP)returnNO);
            SpliceKit_log(@"  Swizzled +[CloudContentFeatureFlag isEnabled] -> NO");
        } else {
            SpliceKit_log(@"  WARNING: +isEnabled not found on CloudContentFeatureFlag");
        }
    } else {
        SpliceKit_log(@"  WARNING: CloudContentFeatureFlag class not found");
    }

    Class ipClass = objc_getClass("_TtC5Flexo17FFImagePlayground");
    if (!ipClass) ipClass = objc_getClass("Flexo.FFImagePlayground");
    if (ipClass) {
        Method m = class_getClassMethod(ipClass, @selector(isAvailable));
        if (m) {
            method_setImplementation(m, (IMP)returnNO);
            SpliceKit_log(@"  Swizzled +[FFImagePlayground isAvailable] -> NO");
        }
    }

    // Also handle the CCFirstLaunchHelper directly — on Creator Studio the Swift feature
    // flag swizzle above may not take effect, so we ensure the CloudContent first-launch
    // flow (which requires CloudKit entitlements lost after re-signing) doesn't run.
    Class ccHelper = objc_getClass("CCFirstLaunchHelper");
    if (ccHelper) {
        SEL sel = NSSelectorFromString(@"setupAndPresentFirstLaunchIfNeededWithCompletionHandler:");
        Method m = class_getInstanceMethod(ccHelper, sel);
        if (m) {
            method_setImplementation(m, (IMP)noopMethodWithArg);
            SpliceKit_log(@"  Handled CCFirstLaunchHelper (CloudKit entitlements fix)");
        }
    }

    SpliceKit_log(@"CloudContent/ImagePlayground disabled.");
}

#pragma mark - App Store Receipt Validation
//
// Validates the App Store receipt from the original (unmodded) FCP installation.
// The receipt is a PKCS7-signed ASN.1 blob from Apple. We verify the signature
// via CMSDecoder and parse the payload to extract the bundle ID, confirming the
// user legitimately downloaded the app from the App Store.
//
// This runs locally — no network calls, no Apple servers.
//

#import <Security/CMSDecoder.h>

// Read a DER length field. Returns bytes consumed (0 on error).
static size_t SpliceKit_readDERLength(const uint8_t *buf, size_t bufLen, size_t *outLen) {
    if (bufLen == 0) return 0;
    uint8_t first = buf[0];
    if (!(first & 0x80)) {
        *outLen = first;
        return 1;
    }
    size_t numBytes = first & 0x7F;
    if (numBytes == 0 || numBytes > 4 || numBytes >= bufLen) return 0;
    size_t len = 0;
    for (size_t i = 0; i < numBytes; i++)
        len = (len << 8) | buf[1 + i];
    *outLen = len;
    return 1 + numBytes;
}

// Parse the ASN.1 receipt payload and extract the bundle ID (attribute type 2).
// Receipt structure: SET { SEQUENCE { INTEGER type, INTEGER version, OCTET STRING value } ... }
static NSString *SpliceKit_extractBundleIdFromPayload(NSData *payload) {
    const uint8_t *buf = payload.bytes;
    size_t total = payload.length;
    if (total < 2) return nil;

    // Outer SET (tag 0x31)
    if (buf[0] != 0x31) return nil;
    size_t setLen = 0;
    size_t off = 1 + SpliceKit_readDERLength(buf + 1, total - 1, &setLen);
    size_t setEnd = off + setLen;
    if (setEnd > total) setEnd = total;

    while (off < setEnd) {
        // Each entry is a SEQUENCE (tag 0x30)
        if (buf[off] != 0x30) break;
        size_t seqLen = 0;
        size_t hdr = 1 + SpliceKit_readDERLength(buf + off + 1, setEnd - off - 1, &seqLen);
        size_t seqStart = off + hdr;
        size_t seqEnd = seqStart + seqLen;
        if (seqEnd > setEnd) break;

        // Parse: INTEGER type
        size_t p = seqStart;
        if (p >= seqEnd || buf[p] != 0x02) { off = seqEnd; continue; }
        p++;
        size_t intLen = 0;
        p += SpliceKit_readDERLength(buf + p, seqEnd - p, &intLen);
        int attrType = 0;
        for (size_t i = 0; i < intLen && i < 4; i++)
            attrType = (attrType << 8) | buf[p + i];
        p += intLen;

        // Skip: INTEGER version
        if (p >= seqEnd || buf[p] != 0x02) { off = seqEnd; continue; }
        p++;
        size_t verLen = 0;
        p += SpliceKit_readDERLength(buf + p, seqEnd - p, &verLen);
        p += verLen;

        // OCTET STRING value
        if (p >= seqEnd || buf[p] != 0x04) { off = seqEnd; continue; }
        p++;
        size_t valLen = 0;
        p += SpliceKit_readDERLength(buf + p, seqEnd - p, &valLen);

        // Type 2 = Bundle Identifier. The value is a UTF8String (tag 0x0C) inside the OCTET STRING.
        if (attrType == 2 && p + valLen <= seqEnd) {
            const uint8_t *val = buf + p;
            if (valLen >= 2 && val[0] == 0x0C) {
                size_t strLen = 0;
                size_t strHdr = 1 + SpliceKit_readDERLength(val + 1, valLen - 1, &strLen);
                if (strHdr + strLen <= valLen) {
                    return [[NSString alloc] initWithBytes:val + strHdr
                                                    length:strLen
                                                  encoding:NSUTF8StringEncoding];
                }
            }
        }

        off = seqEnd;
    }
    return nil;
}

// Log diagnostic details about a receipt (PKCS7 signature, bundle ID).
// This is informational only — the result does not gate app launch.
static void SpliceKit_logReceiptDiagnostics(NSData *receiptData, NSString *receiptPath) {
    CMSDecoderRef decoder = NULL;
    OSStatus status = CMSDecoderCreate(&decoder);
    if (status != noErr) {
        SpliceKit_log(@"[Receipt] CMSDecoderCreate failed: %d", (int)status);
        return;
    }

    status = CMSDecoderUpdateMessage(decoder, receiptData.bytes, receiptData.length);
    if (status != noErr) {
        SpliceKit_log(@"[Receipt] CMSDecoderUpdateMessage failed: %d", (int)status);
        CFRelease(decoder);
        return;
    }

    status = CMSDecoderFinalizeMessage(decoder);
    if (status != noErr) {
        SpliceKit_log(@"[Receipt] CMSDecoderFinalizeMessage failed: %d", (int)status);
        CFRelease(decoder);
        return;
    }

    size_t numSigners = 0;
    CMSDecoderGetNumSigners(decoder, &numSigners);
    if (numSigners == 0) {
        SpliceKit_log(@"[Receipt] No signers in receipt");
        CFRelease(decoder);
        return;
    }

    SecPolicyRef policy = SecPolicyCreateBasicX509();
    CMSSignerStatus signerStatus = kCMSSignerUnsigned;
    SecTrustRef trust = NULL;
    OSStatus certVerifyResult = 0;

    status = CMSDecoderCopySignerStatus(decoder, 0, policy, TRUE,
                                        &signerStatus, &trust, &certVerifyResult);

    BOOL signatureValid = (status == noErr && signerStatus == kCMSSignerValid);
    SpliceKit_log(@"[Receipt] Signature: %@ (signerStatus=%d certVerify=%d)",
        signatureValid ? @"VALID" : @"INVALID", (int)signerStatus, (int)certVerifyResult);

    if (trust) CFRelease(trust);
    if (policy) CFRelease(policy);

    CFDataRef contentRef = NULL;
    status = CMSDecoderCopyContent(decoder, &contentRef);
    CFRelease(decoder);

    if (status != noErr || !contentRef) {
        SpliceKit_log(@"[Receipt] Failed to extract payload: %d", (int)status);
        return;
    }

    NSData *payload = (__bridge_transfer NSData *)contentRef;
    NSString *bundleId = SpliceKit_extractBundleIdFromPayload(payload);
    if (bundleId) {
        BOOL bundleIdMatch = [bundleId isEqualToString:@"com.apple.FinalCut"] ||
                             [bundleId isEqualToString:@"com.apple.FinalCutApp"];
        SpliceKit_log(@"[Receipt] Bundle ID: \"%@\" %@",
            bundleId, bundleIdMatch ? @"MATCH" : @"MISMATCH");
    } else {
        SpliceKit_log(@"[Receipt] Could not extract bundle ID from payload");
    }
}

// Paths checked during the last receipt search (used in error reporting).
static NSArray *sCheckedReceiptPaths = nil;

// Search for an App Store receipt file at known locations.
// Returns YES if a receipt file is found (file existence is sufficient).
// PKCS7/signature details are logged for diagnostics but do not gate the result.
static BOOL SpliceKit_findReceiptFile(void) {
    NSMutableArray *paths = [NSMutableArray array];

    // 1. Running app's own receipt (patcher copies it into the modded bundle)
    NSURL *receiptURL = [[NSBundle mainBundle] appStoreReceiptURL];
    if (receiptURL.path) {
        [paths addObject:receiptURL.path];
    }

    // 2. Original Creator Studio install
    [paths addObject:
        @"/Applications/Final Cut Pro Creator Studio.app/Contents/_MASReceipt/receipt"];

    // 3. Standard FCP install (user may have both editions)
    [paths addObject:
        @"/Applications/Final Cut Pro.app/Contents/_MASReceipt/receipt"];

    sCheckedReceiptPaths = [paths copy];

    for (NSString *path in paths) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data.length > 0) {
            SpliceKit_log(@"[Receipt] Found: %@ (%lu bytes)", path, (unsigned long)data.length);
            SpliceKit_logReceiptDiagnostics(data, path);
            return YES;
        }
    }

    SpliceKit_log(@"[Receipt] No App Store receipt found. Checked:");
    for (NSString *path in paths) {
        SpliceKit_log(@"[Receipt]   %@", path);
    }
    return NO;
}

// Handle subscription validation based on which FCP edition is running.
// - Standard FCP (com.apple.FinalCut): perpetual license, no receipt check needed.
// - Creator Studio (com.apple.FinalCutApp): subscription-based, verify receipt file exists.
// - Unknown: proceed without blocking (future-proofing).
//
// Creator Studio uses an online subscription validation flow (SPV) at launch.
// After ad-hoc re-signing for dylib injection, the entitlements required for that
// online check are lost, causing a "Cannot Connect" error on startup. We route
// around it by making isSPVEnabled return NO.
static void SpliceKit_handleSubscriptionValidation(void) {
    SpliceKit_log(@"Checking subscription status...");

    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    SpliceKit_log(@"  Bundle identifier: %@", bundleId ?: @"(nil)");

    BOOL isCreatorStudio = [bundleId isEqualToString:@"com.apple.FinalCutApp"];
    BOOL isStandardFCP   = [bundleId isEqualToString:@"com.apple.FinalCut"];

    if (isStandardFCP) {
        // Standard FCP is a perpetual license — no subscription to validate.
        SpliceKit_log(@"  Standard FCP detected — skipping receipt validation");
    } else if (isCreatorStudio) {
        // Creator Studio requires a subscription. Verify the App Store receipt
        // file exists to confirm the user downloaded it from the App Store.
        SpliceKit_log(@"  Creator Studio detected — checking for App Store receipt");
        BOOL receiptFound = SpliceKit_findReceiptFile();
        if (!receiptFound) {
            SpliceKit_log(@"  No App Store receipt found");
            [[NSNotificationCenter defaultCenter]
                addObserverForName:NSApplicationDidFinishLaunchingNotification
                object:nil queue:nil usingBlock:^(NSNotification *note) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSMutableString *info = [NSMutableString stringWithString:
                            @"SpliceKit could not find an App Store receipt for "
                            @"Final Cut Pro Creator Studio.\n\nChecked locations:\n"];
                        for (NSString *path in sCheckedReceiptPaths) {
                            [info appendFormat:@"  \u2022 %@\n", path];
                        }
                        [info appendString:
                            @"\nPossible causes:\n"
                            @"  \u2022 Final Cut Pro was not installed from the App Store\n"
                            @"  \u2022 The original app was deleted before patching\n"
                            @"  \u2022 Volume license or MDM installation (no App Store receipt)\n"
                            @"\nPlease reinstall Final Cut Pro Creator Studio from the "
                            @"App Store, then re-run the SpliceKit patcher."];

                        NSAlert *alert = [[NSAlert alloc] init];
                        [alert setMessageText:@"No Valid Subscription Found"];
                        [alert setInformativeText:info];
                        [alert setAlertStyle:NSAlertStyleCritical];
                        [alert addButtonWithTitle:@"Quit"];
                        [alert runModal];
                        [NSApp terminate:nil];
                    });
                }];
            return;
        }
        SpliceKit_log(@"  Receipt found — proceeding with offline validation");
    } else {
        // Unknown bundle ID — don't block. Could be a renamed app or future edition.
        SpliceKit_log(@"  Unknown bundle ID \"%@\" — proceeding without receipt check", bundleId);
    }

    // Route the subscription check through the standard (non-online) launch path.
    // For standard FCP this is a harmless no-op. For Creator Studio it bypasses
    // the broken online SPV check.
    Class flexo = objc_getClass("Flexo");
    if (flexo) {
        Method m = class_getClassMethod(flexo, @selector(isSPVEnabled));
        if (m) {
            method_setImplementation(m, (IMP)returnNO_silent);
            SpliceKit_log(@"  Configured offline subscription validation");
        }
    }

    Class pcFeature = objc_getClass("PCAppFeature");
    if (pcFeature) {
        Method m = class_getClassMethod(pcFeature, @selector(isSPVEnabled));
        if (m)
            method_setImplementation(m, (IMP)returnNO_silent);
    }

    // The standard launch path triggers a CloudContent first-launch flow that
    // requires CloudKit entitlements (lost after re-signing). Mark it as already
    // completed to prevent the CloudKit crash.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"CloudContentFirstLaunchCompleted"];
    [defaults setBool:YES forKey:@"FFCloudContentDisabled"];

    SpliceKit_log(@"  Subscription validation configured");
}

#pragma mark - Constructor
//
// __attribute__((constructor)) means this runs automatically when the dylib is loaded,
// before FCP's main() function. At this point most of FCP's frameworks aren't loaded
// yet, so we can only do early setup: logging, crash prevention patches, and
// registering for the "app finished launching" notification where the real work happens.
//

__attribute__((constructor))
static void SpliceKit_init(void) {
    SpliceKit_initLogging();

    SpliceKit_log(@"================================================");
    SpliceKit_log(@"SpliceKit v%s initializing...", SPLICEKIT_VERSION);
    SpliceKit_log(@"PID: %d", getpid());
    SpliceKit_log(@"Home: %@", NSHomeDirectory());
    SpliceKit_log(@"================================================");

    // These patches need to land before FCP's own init code runs
    SpliceKit_disableCloudContent();
    SpliceKit_handleSubscriptionValidation();
    SpliceKit_fixShutdownHang();

    // Everything else waits for the app to finish launching
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidFinishLaunchingNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            SpliceKit_appDidLaunch();
        }];

    SpliceKit_log(@"Constructor complete. Waiting for app launch...");
}
