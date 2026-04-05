//
//  SpliceKit.m
//  Main entry point - constructor, class caching, app launch hook
//

#import "SpliceKit.h"
#import "SpliceKitCommandPalette.h"
#import <AppKit/AppKit.h>

#pragma mark - Logging

static NSString *sLogPath = nil;
static NSFileHandle *sLogHandle = nil;
static dispatch_queue_t sLogQueue = nil;

static void SpliceKit_initLogging(void) {
    sLogQueue = dispatch_queue_create("com.splicekit.log", DISPATCH_QUEUE_SERIAL);

    // Write to ~/Library/Logs/SpliceKit/splicekit.log
    NSString *logDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit"];
    [[NSFileManager defaultManager] createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:nil];
    sLogPath = [logDir stringByAppendingPathComponent:@"splicekit.log"];

    // Create or truncate the log file
    [[NSFileManager defaultManager] createFileAtPath:sLogPath contents:nil attributes:nil];
    sLogHandle = [NSFileHandle fileHandleForWritingAtPath:sLogPath];
    [sLogHandle seekToEndOfFile];
}

void SpliceKit_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // Also NSLog
    NSLog(@"[SpliceKit] %@", message);

    // Write to file
    if (sLogHandle && sLogQueue) {
        NSString *timestamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                            dateStyle:NSDateFormatterNoStyle
                                                            timeStyle:NSDateFormatterMediumStyle];
        NSString *line = [NSString stringWithFormat:@"[%@] [SpliceKit] %@\n", timestamp, message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        dispatch_async(sLogQueue, ^{
            [sLogHandle writeData:data];
            [sLogHandle synchronizeFile];
        });
    }
}

#pragma mark - Socket Path

static char sSocketPath[1024] = {0};

const char *SpliceKit_getSocketPath(void) {
    if (sSocketPath[0] != '\0') return sSocketPath;

    // Try /tmp first - works if not sandboxed or has exception
    // The entitlements include absolute-path.read-write: ["/"]
    // so /tmp should work. But if not, fall back to container.
    NSString *path = @"/tmp/splicekit.sock";

    // Test writability
    NSString *testPath = @"/tmp/splicekit_test";
    BOOL canWrite = [[NSFileManager defaultManager] createFileAtPath:testPath
                                                            contents:[@"test" dataUsingEncoding:NSUTF8StringEncoding]
                                                          attributes:nil];
    if (canWrite) {
        [[NSFileManager defaultManager] removeItemAtPath:testPath error:nil];
    } else {
        // Fall back to app-specific cache directory
        NSString *cacheDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/SpliceKit"];
        [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];
        path = [cacheDir stringByAppendingPathComponent:@"splicekit.sock"];
        SpliceKit_log(@"Using fallback socket path: %@", path);
    }

    strncpy(sSocketPath, [path UTF8String], sizeof(sSocketPath) - 1);
    return sSocketPath;
}

#pragma mark - Cached Class References

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

static void SpliceKit_checkCompatibility(void) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = info[@"CFBundleShortVersionString"];
    NSString *build = info[@"CFBundleVersion"];
    SpliceKit_log(@"FCP version %@ (build %@)", version, build);

    // Verify critical classes
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

@interface SpliceKitMenuController : NSObject
+ (instancetype)shared;
- (void)toggleTranscriptPanel:(id)sender;
- (void)toggleCommandPalette:(id)sender;
- (void)toggleEffectDragAsAdjustmentClip:(id)sender;
- (void)toggleViewerPinchZoom:(id)sender;
- (void)toggleVideoOnlyKeepsAudioDisabled:(id)sender;
@property (nonatomic, weak) NSButton *toolbarButton;
@property (nonatomic, weak) NSButton *paletteToolbarButton;
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

- (void)toggleCommandPalette:(id)sender {
    [[SpliceKitCommandPalette sharedPalette] togglePalette];
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

- (void)updateToolbarButtonState:(BOOL)active {
    NSButton *btn = self.toolbarButton;
    if (!btn) return;
    btn.state = active ? NSControlStateValueOn : NSControlStateValueOff;
    // Match FCP's active style: blue tint on the icon when active
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

    // Create "SpliceKit" top-level menu
    NSMenu *bridgeMenu = [[NSMenu alloc] initWithTitle:@"SpliceKit"];

    NSMenuItem *transcriptItem = [[NSMenuItem alloc]
        initWithTitle:@"Transcript Editor"
               action:@selector(toggleTranscriptPanel:)
        keyEquivalent:@"t"];
    transcriptItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    transcriptItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:transcriptItem];

    NSMenuItem *paletteItem = [[NSMenuItem alloc]
        initWithTitle:@"Command Palette"
               action:@selector(toggleCommandPalette:)
        keyEquivalent:@"p"];
    paletteItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    paletteItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:paletteItem];

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

    NSMenuItem *optionsMenuItem = [[NSMenuItem alloc] initWithTitle:@"Options" action:nil keyEquivalent:@""];
    optionsMenuItem.submenu = optionsMenu;
    [bridgeMenu addItem:optionsMenuItem];

    // Add the menu to the menu bar (before the last item which is usually "Help")
    NSMenuItem *bridgeMenuItem = [[NSMenuItem alloc] initWithTitle:@"SpliceKit" action:nil keyEquivalent:@""];
    bridgeMenuItem.submenu = bridgeMenu;

    NSInteger helpIndex = [mainMenu indexOfItemWithTitle:@"Help"];
    if (helpIndex >= 0) {
        [mainMenu insertItem:bridgeMenuItem atIndex:helpIndex];
    } else {
        [mainMenu addItem:bridgeMenuItem];
    }

    SpliceKit_log(@"SpliceKit menu installed (Ctrl+Option+T for Transcript Editor, Cmd+Shift+P for Command Palette)");
}

static NSString * const kSpliceKitTranscriptToolbarID = @"SpliceKitTranscriptItemID";
static NSString * const kSpliceKitPaletteToolbarID = @"SpliceKitPaletteItemID";
static IMP sOriginalToolbarItemForIdentifier = NULL;

// Swizzled toolbar delegate method — returns our custom item for our identifier,
// passes everything else to the original implementation.
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
    // Observe window-did-become-main to catch the toolbar as soon as it's ready
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
        SpliceKit_log(@"No main window for toolbar button after %d attempts", attempt);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Check all windows, not just mainWindow
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

        // Swizzle the toolbar delegate to handle our custom item identifier
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

        // Check existing items — remove stale ones, skip if already present
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

        // Find flexible space to insert before it
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

    // Install SpliceKit menu in the menu bar
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

    // Install effect browser favorites context menu (always on)
    SpliceKit_installEffectFavoritesSwizzle();

    // Start the control server on a background thread
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SpliceKit_startControlServer();
    });
}

#pragma mark - CloudContent Crash Prevention

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

static void noopMethodWith2Args(id self, SEL _cmd, id arg1, id arg2) {}

static void SpliceKit_fixShutdownHang(void) {
    // FCP's PCUserDefaultsMigrator.copyUserDefaultsToGroupContainer hangs on quit
    // by enumerating a huge media directory via getattrlistbulk. Swizzle it to no-op.
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

static void SpliceKit_disableCloudContent(void) {
    SpliceKit_log(@"Disabling CloudContent/ImagePlayground...");

    // The crash path in -[PEAppController presentMainWindowOnAppLaunch:]:
    //   if (+[CloudContentFeatureFlag isEnabled]) {  <-- gate the whole flow
    //     CloudContentCatalog.shared -> CCFirstLaunchHelper -> CloudKit (crash)
    //   }
    // Fix: make +[CloudContentFeatureFlag isEnabled] return NO

    // CloudContentFeatureFlag is a Swift class with mangled name
    // _TtC13Final_Cut_Pro23CloudContentFeatureFlag
    Class ccFlag = objc_getClass("_TtC13Final_Cut_Pro23CloudContentFeatureFlag");
    if (!ccFlag) {
        // Try alternate name
        ccFlag = objc_getClass("Final_Cut_Pro.CloudContentFeatureFlag");
    }

    if (ccFlag) {
        // Swizzle the class method +isEnabled to return NO
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

    // Also disable FFImagePlayground.isAvailable which can also crash
    Class ipClass = objc_getClass("_TtC5Flexo17FFImagePlayground");
    if (!ipClass) ipClass = objc_getClass("Flexo.FFImagePlayground");
    if (ipClass) {
        Method m = class_getClassMethod(ipClass, @selector(isAvailable));
        if (m) {
            method_setImplementation(m, (IMP)returnNO);
            SpliceKit_log(@"  Swizzled +[FFImagePlayground isAvailable] -> NO");
        }
    }

    SpliceKit_log(@"CloudContent/ImagePlayground disabled.");
}

#pragma mark - Constructor (called on dylib load)

__attribute__((constructor))
static void SpliceKit_init(void) {
    // Initialize logging first
    SpliceKit_initLogging();

    SpliceKit_log(@"================================================");
    SpliceKit_log(@"SpliceKit v%s initializing...", SPLICEKIT_VERSION);
    SpliceKit_log(@"PID: %d", getpid());
    SpliceKit_log(@"Home: %@", NSHomeDirectory());
    SpliceKit_log(@"================================================");

    // Swizzle out CloudContent first-launch flow that crashes without iCloud entitlements
    SpliceKit_disableCloudContent();

    // Fix shutdown hang caused by PCUserDefaultsMigrator
    SpliceKit_fixShutdownHang();

    // Register for app launch notification
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidFinishLaunchingNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            SpliceKit_appDidLaunch();
        }];

    SpliceKit_log(@"Constructor complete. Waiting for app launch...");
}
