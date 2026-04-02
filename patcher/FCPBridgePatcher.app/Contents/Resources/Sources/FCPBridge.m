//
//  FCPBridge.m
//  Main entry point - constructor, class caching, app launch hook
//

#import "FCPBridge.h"
#import "FCPCommandPalette.h"
#import <AppKit/AppKit.h>

#pragma mark - Logging

static NSString *sLogPath = nil;
static NSFileHandle *sLogHandle = nil;
static dispatch_queue_t sLogQueue = nil;

static void FCPBridge_initLogging(void) {
    sLogQueue = dispatch_queue_create("com.fcpbridge.log", DISPATCH_QUEUE_SERIAL);

    // Write to ~/Library/Logs/FCPBridge/fcpbridge.log
    NSString *logDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/FCPBridge"];
    [[NSFileManager defaultManager] createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:nil];
    sLogPath = [logDir stringByAppendingPathComponent:@"fcpbridge.log"];

    // Create or truncate the log file
    [[NSFileManager defaultManager] createFileAtPath:sLogPath contents:nil attributes:nil];
    sLogHandle = [NSFileHandle fileHandleForWritingAtPath:sLogPath];
    [sLogHandle seekToEndOfFile];
}

void FCPBridge_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // Also NSLog
    NSLog(@"[FCPBridge] %@", message);

    // Write to file
    if (sLogHandle && sLogQueue) {
        NSString *timestamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                            dateStyle:NSDateFormatterNoStyle
                                                            timeStyle:NSDateFormatterMediumStyle];
        NSString *line = [NSString stringWithFormat:@"[%@] [FCPBridge] %@\n", timestamp, message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        dispatch_async(sLogQueue, ^{
            [sLogHandle writeData:data];
            [sLogHandle synchronizeFile];
        });
    }
}

#pragma mark - Socket Path

static char sSocketPath[1024] = {0};

const char *FCPBridge_getSocketPath(void) {
    if (sSocketPath[0] != '\0') return sSocketPath;

    // Try /tmp first - works if not sandboxed or has exception
    // The entitlements include absolute-path.read-write: ["/"]
    // so /tmp should work. But if not, fall back to container.
    NSString *path = @"/tmp/fcpbridge.sock";

    // Test writability
    NSString *testPath = @"/tmp/fcpbridge_test";
    BOOL canWrite = [[NSFileManager defaultManager] createFileAtPath:testPath
                                                            contents:[@"test" dataUsingEncoding:NSUTF8StringEncoding]
                                                          attributes:nil];
    if (canWrite) {
        [[NSFileManager defaultManager] removeItemAtPath:testPath error:nil];
    } else {
        // Fall back to app-specific cache directory
        NSString *cacheDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/FCPBridge"];
        [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];
        path = [cacheDir stringByAppendingPathComponent:@"fcpbridge.sock"];
        FCPBridge_log(@"Using fallback socket path: %@", path);
    }

    strncpy(sSocketPath, [path UTF8String], sizeof(sSocketPath) - 1);
    return sSocketPath;
}

#pragma mark - Cached Class References

Class FCPBridge_FFAnchoredTimelineModule = nil;
Class FCPBridge_FFAnchoredSequence = nil;
Class FCPBridge_FFLibrary = nil;
Class FCPBridge_FFLibraryDocument = nil;
Class FCPBridge_FFEditActionMgr = nil;
Class FCPBridge_FFModelDocument = nil;
Class FCPBridge_FFPlayer = nil;
Class FCPBridge_FFActionContext = nil;
Class FCPBridge_PEAppController = nil;
Class FCPBridge_PEDocument = nil;

#pragma mark - Compatibility Check

static void FCPBridge_checkCompatibility(void) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = info[@"CFBundleShortVersionString"];
    NSString *build = info[@"CFBundleVersion"];
    FCPBridge_log(@"FCP version %@ (build %@)", version, build);

    // Verify critical classes
    struct { const char *name; Class *ref; } classes[] = {
        {"FFAnchoredTimelineModule", &FCPBridge_FFAnchoredTimelineModule},
        {"FFAnchoredSequence",       &FCPBridge_FFAnchoredSequence},
        {"FFLibrary",                &FCPBridge_FFLibrary},
        {"FFLibraryDocument",        &FCPBridge_FFLibraryDocument},
        {"FFEditActionMgr",          &FCPBridge_FFEditActionMgr},
        {"FFModelDocument",          &FCPBridge_FFModelDocument},
        {"FFPlayer",                 &FCPBridge_FFPlayer},
        {"FFActionContext",          &FCPBridge_FFActionContext},
        {"PEAppController",         &FCPBridge_PEAppController},
        {"PEDocument",              &FCPBridge_PEDocument},
    };

    int found = 0, total = sizeof(classes) / sizeof(classes[0]);
    for (int i = 0; i < total; i++) {
        *classes[i].ref = objc_getClass(classes[i].name);
        if (*classes[i].ref) {
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(*classes[i].ref, &methodCount);
            free(methods);
            FCPBridge_log(@"  OK: %s (%u methods)", classes[i].name, methodCount);
            found++;
        } else {
            FCPBridge_log(@"  MISSING: %s", classes[i].name);
        }
    }
    FCPBridge_log(@"Class check: %d/%d found", found, total);
}

#pragma mark - FCPBridge Menu

@interface FCPBridgeMenuController : NSObject
+ (instancetype)shared;
- (void)toggleTranscriptPanel:(id)sender;
- (void)toggleCommandPalette:(id)sender;
- (void)toggleViewerPinchZoom:(id)sender;
@property (nonatomic, weak) NSButton *toolbarButton;
@property (nonatomic, weak) NSButton *paletteToolbarButton;
@end

@implementation FCPBridgeMenuController

+ (instancetype)shared {
    static FCPBridgeMenuController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)toggleTranscriptPanel:(id)sender {
    Class panelClass = objc_getClass("FCPTranscriptPanel");
    if (!panelClass) {
        FCPBridge_log(@"FCPTranscriptPanel class not found");
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
    [[FCPCommandPalette sharedPalette] togglePalette];
}

- (void)toggleViewerPinchZoom:(id)sender {
    BOOL newState = !FCPBridge_isViewerPinchZoomEnabled();
    FCPBridge_setViewerPinchZoomEnabled(newState);
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

static void FCPBridge_installMenu(void) {
    NSMenu *mainMenu = [NSApp mainMenu];
    if (!mainMenu) {
        FCPBridge_log(@"No main menu found - skipping menu install");
        return;
    }

    // Create "FCPBridge" top-level menu
    NSMenu *bridgeMenu = [[NSMenu alloc] initWithTitle:@"FCPBridge"];

    NSMenuItem *transcriptItem = [[NSMenuItem alloc]
        initWithTitle:@"Transcript Editor"
               action:@selector(toggleTranscriptPanel:)
        keyEquivalent:@"t"];
    transcriptItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    transcriptItem.target = [FCPBridgeMenuController shared];
    [bridgeMenu addItem:transcriptItem];

    NSMenuItem *paletteItem = [[NSMenuItem alloc]
        initWithTitle:@"Command Palette"
               action:@selector(toggleCommandPalette:)
        keyEquivalent:@"p"];
    paletteItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    paletteItem.target = [FCPBridgeMenuController shared];
    [bridgeMenu addItem:paletteItem];

    // --- Options submenu ---
    [bridgeMenu addItem:[NSMenuItem separatorItem]];

    NSMenu *optionsMenu = [[NSMenu alloc] initWithTitle:@"Options"];

    NSMenuItem *pinchZoomItem = [[NSMenuItem alloc]
        initWithTitle:@"Viewer Pinch-to-Zoom"
               action:@selector(toggleViewerPinchZoom:)
        keyEquivalent:@""];
    pinchZoomItem.target = [FCPBridgeMenuController shared];
    pinchZoomItem.state = FCPBridge_isViewerPinchZoomEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    [optionsMenu addItem:pinchZoomItem];

    NSMenuItem *optionsMenuItem = [[NSMenuItem alloc] initWithTitle:@"Options" action:nil keyEquivalent:@""];
    optionsMenuItem.submenu = optionsMenu;
    [bridgeMenu addItem:optionsMenuItem];

    // Add the menu to the menu bar (before the last item which is usually "Help")
    NSMenuItem *bridgeMenuItem = [[NSMenuItem alloc] initWithTitle:@"FCPBridge" action:nil keyEquivalent:@""];
    bridgeMenuItem.submenu = bridgeMenu;

    NSInteger helpIndex = [mainMenu indexOfItemWithTitle:@"Help"];
    if (helpIndex >= 0) {
        [mainMenu insertItem:bridgeMenuItem atIndex:helpIndex];
    } else {
        [mainMenu addItem:bridgeMenuItem];
    }

    FCPBridge_log(@"FCPBridge menu installed (Ctrl+Option+T for Transcript Editor, Cmd+Shift+P for Command Palette)");
}

static NSString * const kFCPBridgeTranscriptToolbarID = @"FCPBridgeTranscriptItemID";
static NSString * const kFCPBridgePaletteToolbarID = @"FCPBridgePaletteItemID";
static IMP sOriginalToolbarItemForIdentifier = NULL;

// Swizzled toolbar delegate method — returns our custom item for our identifier,
// passes everything else to the original implementation.
static id FCPBridge_toolbar_itemForItemIdentifier(id self, SEL _cmd, NSToolbar *toolbar,
                                                   NSString *identifier, BOOL willInsert) {
    if ([identifier isEqualToString:kFCPBridgeTranscriptToolbarID]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:kFCPBridgeTranscriptToolbarID];
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
        button.target = [FCPBridgeMenuController shared];
        button.action = @selector(toggleTranscriptPanel:);

        [FCPBridgeMenuController shared].toolbarButton = button;
        item.view = button;

        return item;
    }
    if ([identifier isEqualToString:kFCPBridgePaletteToolbarID]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:kFCPBridgePaletteToolbarID];
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
        button.target = [FCPBridgeMenuController shared];
        button.action = @selector(toggleCommandPalette:);

        [FCPBridgeMenuController shared].paletteToolbarButton = button;
        item.view = button;

        return item;
    }
    // Call original
    return ((id (*)(id, SEL, NSToolbar *, NSString *, BOOL))sOriginalToolbarItemForIdentifier)(
        self, _cmd, toolbar, identifier, willInsert);
}

@implementation FCPBridgeMenuController (Toolbar)

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
                [FCPBridgeMenuController addToolbarButtonToWindow:window];
            }
        }];

    // Also poll as fallback in case the notification already fired
    [self installToolbarButtonAttempt:0];
}

+ (void)installToolbarButtonAttempt:(int)attempt {
    if (attempt >= 30) {
        FCPBridge_log(@"No main window for toolbar button after %d attempts", attempt);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Check all windows, not just mainWindow
        for (NSWindow *w in [NSApp windows]) {
            if (w.toolbar && w.toolbar.items.count > 0) {
                [FCPBridgeMenuController addToolbarButtonToWindow:w];
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
            FCPBridge_log(@"No toolbar on main window");
            return;
        }

        // Swizzle the toolbar delegate to handle our custom item identifier
        id delegate = toolbar.delegate;
        if (!delegate) {
            FCPBridge_log(@"No toolbar delegate");
            return;
        }

        if (!sOriginalToolbarItemForIdentifier) {
            SEL sel = @selector(toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:);
            Method m = class_getInstanceMethod([delegate class], sel);
            if (m) {
                sOriginalToolbarItemForIdentifier = method_getImplementation(m);
                method_setImplementation(m, (IMP)FCPBridge_toolbar_itemForItemIdentifier);
                FCPBridge_log(@"Swizzled toolbar delegate %@ for custom item", NSStringFromClass([delegate class]));
            }
        }

        // Check existing items — remove stale ones, skip if already present
        BOOL hasTranscript = NO, hasPalette = NO;
        for (NSInteger i = (NSInteger)toolbar.items.count - 1; i >= 0; i--) {
            NSToolbarItem *ti = toolbar.items[(NSUInteger)i];
            if ([ti.itemIdentifier isEqualToString:kFCPBridgeTranscriptToolbarID]) {
                if (ti.view) {
                    if ([ti.view isKindOfClass:[NSButton class]])
                        [FCPBridgeMenuController shared].toolbarButton = (NSButton *)ti.view;
                    hasTranscript = YES;
                } else {
                    [toolbar removeItemAtIndex:(NSUInteger)i];
                }
            } else if ([ti.itemIdentifier isEqualToString:kFCPBridgePaletteToolbarID]) {
                if (ti.view) {
                    if ([ti.view isKindOfClass:[NSButton class]])
                        [FCPBridgeMenuController shared].paletteToolbarButton = (NSButton *)ti.view;
                    hasPalette = YES;
                } else {
                    [toolbar removeItemAtIndex:(NSUInteger)i];
                }
            }
        }
        if (hasTranscript && hasPalette) {
            FCPBridge_log(@"Both toolbar buttons already present — skipping");
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
            [toolbar insertItemWithItemIdentifier:kFCPBridgePaletteToolbarID atIndex:insertIdx];
            FCPBridge_log(@"Command Palette toolbar button inserted at index %lu", (unsigned long)insertIdx);
            insertIdx++;
        }
        if (!hasTranscript) {
            [toolbar insertItemWithItemIdentifier:kFCPBridgeTranscriptToolbarID atIndex:insertIdx];
            FCPBridge_log(@"Transcript toolbar button inserted at index %lu", (unsigned long)insertIdx);
        }

    } @catch (NSException *e) {
        FCPBridge_log(@"Failed to install toolbar button: %@", e.reason);
    }
}

@end

#pragma mark - App Launch Handler

static void FCPBridge_appDidLaunch(void) {
    FCPBridge_log(@"================================================");
    FCPBridge_log(@"App launched. Starting control server...");
    FCPBridge_log(@"================================================");

    // Run compatibility check now that all frameworks are loaded
    FCPBridge_checkCompatibility();

    // Count total loaded classes
    unsigned int classCount = 0;
    Class *allClasses = objc_copyClassList(&classCount);
    free(allClasses);
    FCPBridge_log(@"Total ObjC classes in process: %u", classCount);

    // Install FCPBridge menu in the menu bar
    FCPBridge_installMenu();

    // Install toolbar button in FCP's main window
    [FCPBridgeMenuController installToolbarButton];

    // Install transition freeze-extend swizzle (adds "Use Freeze Frames" button
    // to the "not enough extra media" dialog)
    FCPBridge_installTransitionFreezeExtendSwizzle();

    // Install effect-drag-as-adjustment-clip swizzle (allows dragging effects
    // to empty timeline space to create adjustment clips)
    FCPBridge_installEffectDragAsAdjustmentClip();

    // Install viewer pinch-to-zoom if previously enabled
    if (FCPBridge_isViewerPinchZoomEnabled()) {
        FCPBridge_installViewerPinchZoom();
    }

    // Start the control server on a background thread
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FCPBridge_startControlServer();
    });
}

#pragma mark - CloudContent Crash Prevention

static void noopMethod(id self, SEL _cmd) {
    FCPBridge_log(@"BLOCKED: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}

static void noopMethodWithArg(id self, SEL _cmd, id arg) {
    FCPBridge_log(@"BLOCKED: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}

static BOOL returnNO(id self, SEL _cmd) {
    FCPBridge_log(@"BLOCKED (returning NO): +[%@ %@]",
                  NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd));
    return NO;
}

static void noopMethodWith2Args(id self, SEL _cmd, id arg1, id arg2) {}

static void FCPBridge_fixShutdownHang(void) {
    // FCP's PCUserDefaultsMigrator.copyUserDefaultsToGroupContainer hangs on quit
    // by enumerating a huge media directory via getattrlistbulk. Swizzle it to no-op.
    Class migrator = objc_getClass("PCUserDefaultsMigrator");
    if (migrator) {
        SEL sel = NSSelectorFromString(@"copyDataFromSource:toTarget:");
        Method m = class_getInstanceMethod(migrator, sel);
        if (m) {
            method_setImplementation(m, (IMP)noopMethodWith2Args);
            FCPBridge_log(@"Swizzled PCUserDefaultsMigrator.copyDataFromSource: (fixes shutdown hang)");
        }
    }
}

static void FCPBridge_disableCloudContent(void) {
    FCPBridge_log(@"Disabling CloudContent/ImagePlayground...");

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
            FCPBridge_log(@"  Swizzled +[CloudContentFeatureFlag isEnabled] -> NO");
        } else {
            FCPBridge_log(@"  WARNING: +isEnabled not found on CloudContentFeatureFlag");
        }
    } else {
        FCPBridge_log(@"  WARNING: CloudContentFeatureFlag class not found");
    }

    // Also disable FFImagePlayground.isAvailable which can also crash
    Class ipClass = objc_getClass("_TtC5Flexo17FFImagePlayground");
    if (!ipClass) ipClass = objc_getClass("Flexo.FFImagePlayground");
    if (ipClass) {
        Method m = class_getClassMethod(ipClass, @selector(isAvailable));
        if (m) {
            method_setImplementation(m, (IMP)returnNO);
            FCPBridge_log(@"  Swizzled +[FFImagePlayground isAvailable] -> NO");
        }
    }

    FCPBridge_log(@"CloudContent/ImagePlayground disabled.");
}

#pragma mark - Constructor (called on dylib load)

__attribute__((constructor))
static void FCPBridge_init(void) {
    // Initialize logging first
    FCPBridge_initLogging();

    FCPBridge_log(@"================================================");
    FCPBridge_log(@"FCPBridge v%s initializing...", FCPBRIDGE_VERSION);
    FCPBridge_log(@"PID: %d", getpid());
    FCPBridge_log(@"Home: %@", NSHomeDirectory());
    FCPBridge_log(@"================================================");

    // Swizzle out CloudContent first-launch flow that crashes without iCloud entitlements
    FCPBridge_disableCloudContent();

    // Fix shutdown hang caused by PCUserDefaultsMigrator
    FCPBridge_fixShutdownHang();

    // Register for app launch notification
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidFinishLaunchingNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            FCPBridge_appDidLaunch();
        }];

    FCPBridge_log(@"Constructor complete. Waiting for app launch...");
}
