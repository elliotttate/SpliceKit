//
//  UndoHistoryUI.m
//  com.splicekit.undo-history-ui
//
//  Self-contained undo history palette for Final Cut Pro.
//  Survives SpliceKit patcher updates — the entire feature lives here.
//
//  What this plugin does
//  ─────────────────────
//  1. Defines SpliceKitUndoEntry + SpliceKitUndoHistoryPanel (if not already
//     present in the host binary — e.g. after a patcher update).
//  2. Installs NSUndoManager group-close observers so every user action is
//     captured into the palette's list (idempotent, safe to call twice).
//  3. Swizzles PEMainWindowModule's toolbar delegate method to vend a "History"
//     toolbar item, then inserts it after the Transcript button.
//  4. Injects an "Undo History" menu item into the Splices menu.
//
//  When the host binary already contains SpliceKitUndoHistoryPanel (user build),
//  the ObjC runtime keeps that version and the @implementation blocks here are
//  silently ignored. The toolbar/menu injection and installHooks call proceed
//  normally — installHooks is idempotent so double-calling is harmless.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "SpliceKitPluginAPI.h"

// ---------------------------------------------------------------------------
// Plugin API storage
// ---------------------------------------------------------------------------
static SpliceKitPluginAPI  sAPIStorage;
static SpliceKitPluginAPI *sAPI = NULL;

// ---------------------------------------------------------------------------
// Forward declarations for C functions provided by the host binary.
// With -undefined dynamic_lookup these resolve at load time from SpliceKit.
// ---------------------------------------------------------------------------
extern void SpliceKit_executeOnMainThread(dispatch_block_t block);
extern void SpliceKit_log(NSString *fmt, ...) __attribute__((format(__NSString__, 1, 2)));

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
static const NSInteger kUH_MaxEntries = 100;
static NSString * const kUH_ToolbarID = @"SpliceKitUndoHistoryItemID";

// ---------------------------------------------------------------------------
// SpliceKitUndoEntry
// (No-op if host binary already defines this class — first loader wins.)
// ---------------------------------------------------------------------------

@interface SpliceKitUndoEntry : NSObject
@property (nonatomic, copy)   NSString  *actionName;
@property (nonatomic, strong) NSDate    *timestamp;
@property (nonatomic)         NSInteger  index;
@end

@implementation SpliceKitUndoEntry
@end

// ---------------------------------------------------------------------------
// SpliceKitUndoHistoryTableView – forwards row clicks to the panel
// ---------------------------------------------------------------------------

@interface SpliceKitUndoHistoryTableView : NSTableView
@property (nonatomic, weak) id  clickTarget;
@property (nonatomic)       SEL clickAction;
@end

@implementation SpliceKitUndoHistoryTableView
- (void)mouseDown:(NSEvent *)event {
    [super mouseDown:event];
    NSInteger row = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (row >= 0 && self.clickTarget) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.clickTarget performSelector:self.clickAction withObject:@(row)];
#pragma clang diagnostic pop
    }
}
@end

// ---------------------------------------------------------------------------
// SpliceKitUndoHistoryPanel
// ---------------------------------------------------------------------------

@interface SpliceKitUndoHistoryPanel : NSObject <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) NSMutableArray<SpliceKitUndoEntry *> *entries;
@property (nonatomic)         NSInteger cursor;
@property (nonatomic)         BOOL      suppressRecord;
@property (nonatomic, strong) NSMapTable *nestingDepths;
@property (nonatomic, strong) NSPanel                       *panel;
@property (nonatomic, strong) SpliceKitUndoHistoryTableView *tableView;
@property (nonatomic, strong) NSScrollView                  *scrollView;
@property (nonatomic, strong) NSButton                      *clearButton;

+ (instancetype)sharedPanel;
+ (void)installHooks;
- (void)showPanel;
- (void)hidePanel;
- (BOOL)isVisible;
- (NSDictionary *)getHistory;
- (NSDictionary *)jumpToIndex:(NSInteger)targetIndex;
- (void)clearHistory;

@end

@implementation SpliceKitUndoHistoryPanel

// ── Singleton ────────────────────────────────────────────────────────────────

+ (instancetype)sharedPanel {
    static SpliceKitUndoHistoryPanel *sInstance = nil;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{ sInstance = [[self alloc] init]; });
    return sInstance;
}

// ── Hook installation (idempotent) ───────────────────────────────────────────

+ (void)installHooks {
    static BOOL sInstalled = NO;
    if (sInstalled) return;
    sInstalled = YES;

    SpliceKitUndoHistoryPanel *panel = [self sharedPanel];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:panel selector:@selector(_undoGroupDidOpen:)
               name:NSUndoManagerDidOpenUndoGroupNotification  object:nil];
    [nc addObserver:panel selector:@selector(_undoGroupDidClose:)
               name:NSUndoManagerDidCloseUndoGroupNotification object:nil];
}

// ── Init ─────────────────────────────────────────────────────────────────────

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _entries       = [NSMutableArray array];
    _cursor        = -1;
    _nestingDepths = [NSMapTable weakToStrongObjectsMapTable];
    [self _buildPanel];
    return self;
}

// ── Panel construction ───────────────────────────────────────────────────────

- (void)_buildPanel {
    NSRect frame = NSMakeRect(200, 400, 300, 480);
    _panel = [[NSPanel alloc] initWithContentRect:frame
                                        styleMask:NSWindowStyleMaskTitled
                                                 |NSWindowStyleMaskClosable
                                                 |NSWindowStyleMaskMiniaturizable
                                                 |NSWindowStyleMaskResizable
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
    _panel.title                  = @"Undo History";
    _panel.floatingPanel          = YES;
    _panel.becomesKeyOnlyIfNeeded = YES;
    _panel.minSize                = NSMakeSize(220, 200);

    NSView *content = _panel.contentView;

    _clearButton = [NSButton buttonWithTitle:@"Clear" target:self
                                      action:@selector(_clearButtonClicked:)];
    _clearButton.translatesAutoresizingMaskIntoConstraints = NO;
    _clearButton.bezelStyle  = NSBezelStyleRounded;
    _clearButton.controlSize = NSControlSizeSmall;
    [content addSubview:_clearButton];

    _tableView = [[SpliceKitUndoHistoryTableView alloc] initWithFrame:NSZeroRect];
    _tableView.clickTarget = self;
    _tableView.clickAction = @selector(_rowClicked:);
    _tableView.dataSource  = self;
    _tableView.delegate    = self;
    _tableView.headerView  = nil;
    _tableView.rowSizeStyle                 = NSTableViewRowSizeStyleSmall;
    _tableView.selectionHighlightStyle      = NSTableViewSelectionHighlightStyleNone;
    _tableView.usesAlternatingRowBackgroundColors = NO;
    _tableView.gridStyleMask                = NSTableViewGridNone;
    _tableView.focusRingType                = NSFocusRingTypeNone;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"action"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:col];

    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.documentView        = _tableView;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.autohidesScrollers  = YES;
    _scrollView.borderType          = NSNoBorder;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_scrollView];

    NSDictionary *views   = @{@"scroll": _scrollView, @"clear": _clearButton};
    NSDictionary *metrics = @{@"m": @8, @"b": @4};
    [NSLayoutConstraint activateConstraints:
     [NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(m)-[scroll]-(m)-|"
                                             options:0 metrics:metrics views:views]];
    [NSLayoutConstraint activateConstraints:
     [NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(m)-[clear]-(m)-|"
                                             options:0 metrics:metrics views:views]];
    [NSLayoutConstraint activateConstraints:
     [NSLayoutConstraint constraintsWithVisualFormat:@"V:|-(m)-[scroll]-(b)-[clear]-(m)-|"
                                             options:0 metrics:metrics views:views]];

    [_tableView sizeLastColumnToFit];
}

// ── Visibility ────────────────────────────────────────────────────────────────

- (void)showPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _reloadTable];
        [self->_panel makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    });
}

- (void)hidePanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_panel orderOut:nil];
    });
}

- (BOOL)isVisible {
    return _panel.isVisible;
}

// ── NSUndoManager notification handlers ─────────────────────────────────────

- (void)_undoGroupDidOpen:(NSNotification *)n {
    id um = n.object;
    NSInteger depth = [[_nestingDepths objectForKey:um] integerValue];
    [_nestingDepths setObject:@(depth + 1) forKey:um];
}

- (void)_undoGroupDidClose:(NSNotification *)n {
    id um = n.object;
    NSInteger depth = [[_nestingDepths objectForKey:um] integerValue];
    depth = MAX(0, depth - 1);
    [_nestingDepths setObject:@(depth) forKey:um];
    if (depth != 0 || _suppressRecord) return;

    NSString *name = [um undoActionName];
    if ([name hasPrefix:@"Edit "]) name = [name substringFromIndex:5];
    if (name.length == 0 || [name isEqualToString:@"Edit"]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self _recordAction:name];
    });
}

// ── History management ────────────────────────────────────────────────────────

- (void)_recordAction:(NSString *)name {
    if ((NSInteger)_entries.count >= kUH_MaxEntries) {
        [_entries removeObjectAtIndex:0];
        for (NSInteger i = 0; i < (NSInteger)_entries.count; i++)
            _entries[(NSUInteger)i].index = i;
        _cursor = MAX(-1, _cursor - 1);
    }

    SpliceKitUndoEntry *entry = [[SpliceKitUndoEntry alloc] init];
    entry.actionName = name;
    entry.timestamp  = [NSDate date];
    entry.index      = (NSInteger)_entries.count;
    [_entries addObject:entry];
    _cursor = entry.index;
    [self _reloadTable];
}

- (void)clearHistory {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_entries removeAllObjects];
        self->_cursor = -1;
        [self _reloadTable];
    });
}

// ── Table reload ──────────────────────────────────────────────────────────────

- (void)_reloadTable {
    [_tableView reloadData];
    if (_cursor >= 0 && _cursor < (NSInteger)_entries.count)
        [_tableView scrollRowToVisible:_cursor];
}

// ── NSTableViewDataSource ─────────────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return (NSInteger)_entries.count;
}

// ── NSTableViewDelegate ───────────────────────────────────────────────────────

- (NSView *)tableView:(NSTableView *)tv
   viewForTableColumn:(NSTableColumn *)col
                  row:(NSInteger)row {
    NSTextField *label = [tv makeViewWithIdentifier:@"cell" owner:self];
    if (!label) {
        label = [NSTextField labelWithString:@""];
        label.identifier    = @"cell";
        label.lineBreakMode = NSLineBreakByTruncatingTail;
    }

    SpliceKitUndoEntry *entry = _entries[(NSUInteger)row];
    BOOL isCurrent = (row == _cursor);

    if (isCurrent) {
        label.font      = [NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]];
        label.textColor = [NSColor controlAccentColor];
    } else {
        label.font      = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
        label.textColor = [NSColor labelColor];
    }

    label.stringValue = entry.actionName;
    return label;
}

- (CGFloat)tableView:(NSTableView *)tv heightOfRow:(NSInteger)row {
    return 20.0;
}

// ── Row click ─────────────────────────────────────────────────────────────────

- (void)_rowClicked:(NSNumber *)rowNumber {
    NSInteger row = rowNumber.integerValue;
    if (row == _cursor) return;
    [self jumpToIndex:row];
}

- (void)_clearButtonClicked:(id)sender {
    [self clearHistory];
}

// ── RPC: getHistory ───────────────────────────────────────────────────────────

- (NSDictionary *)getHistory {
    __block NSDictionary *result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:self->_entries.count];
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss";

        for (SpliceKitUndoEntry *e in self->_entries) {
            [arr addObject:@{
                @"index":     @(e.index),
                @"name":      e.actionName,
                @"timestamp": [fmt stringFromDate:e.timestamp],
                @"isCurrent": @(e.index == self->_cursor)
            }];
        }

        BOOL canUndo = NO, canRedo = NO;
        @try {
            id doc = [[[NSApplication sharedApplication] delegate]
                      performSelector:@selector(_targetLibrary)];
            id um  = [((id(*)(id,SEL))objc_msgSend)(doc, @selector(libraryDocument))
                      undoManager];
            canUndo = [um canUndo];
            canRedo = [um canRedo];
        } @catch (...) {}

        result = @{
            @"entries": [arr copy],
            @"cursor":  @(self->_cursor),
            @"canUndo": @(canUndo),
            @"canRedo": @(canRedo),
            @"visible": @(self->_panel.isVisible)
        };
    });
    return result;
}

// ── RPC: jumpToIndex ──────────────────────────────────────────────────────────

- (NSDictionary *)jumpToIndex:(NSInteger)target {
    if (target < -1 || target >= (NSInteger)_entries.count)
        return @{@"error": @"Index out of range"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        NSUndoManager *um = nil;
        @try {
            id delegate = [[NSApplication sharedApplication] delegate];
            id lib      = [delegate performSelector:@selector(_targetLibrary)];
            id doc      = ((id(*)(id,SEL))objc_msgSend)(lib, @selector(libraryDocument));
            um = [doc undoManager];
        } @catch (...) {}

        if (!um) {
            result = @{@"error": @"No undo manager found — is a project open?"};
            return;
        }

        NSInteger delta = target - self->_cursor;
        if (delta == 0) {
            result = @{@"status": @"ok", @"message": @"Already at that state"};
            return;
        }

        self->_suppressRecord = YES;
        NSInteger performed = 0;
        if (delta < 0) {
            for (NSInteger i = 0; i < -delta; i++) {
                if (![um canUndo]) break;
                [um undo];
                performed--;
            }
        } else {
            for (NSInteger i = 0; i < delta; i++) {
                if (![um canRedo]) break;
                [um redo];
                performed++;
            }
        }
        self->_suppressRecord = NO;

        self->_cursor += performed;
        [self _reloadTable];

        result = @{
            @"status":  @"ok",
            @"moved":   @(performed),
            @"cursor":  @(self->_cursor),
            @"canUndo": @([um canUndo]),
            @"canRedo": @([um canRedo])
        };
    });
    return result;
}

@end

// ---------------------------------------------------------------------------
// UHPlugin_Controller – action target for toolbar button and menu item
// ---------------------------------------------------------------------------

@interface UHPlugin_Controller : NSObject
+ (instancetype)shared;
- (void)togglePanel:(id)sender;
@end

@implementation UHPlugin_Controller

+ (instancetype)shared {
    static UHPlugin_Controller *sInstance = nil;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{ sInstance = [[self alloc] init]; });
    return sInstance;
}

- (void)togglePanel:(id)sender {
    SpliceKitUndoHistoryPanel *panel = [SpliceKitUndoHistoryPanel sharedPanel];
    if (panel.isVisible)
        [panel hidePanel];
    else
        [panel showPanel];

    // Sync button state if the sender is a button
    if ([sender isKindOfClass:[NSButton class]]) {
        NSControlStateValue state = panel.isVisible
            ? NSControlStateValueOn : NSControlStateValueOff;
        ((NSButton *)sender).state = state;
    }
}

@end

// ---------------------------------------------------------------------------
// Toolbar swizzle
// ---------------------------------------------------------------------------

static IMP sOrigToolbarItemForIdentifier = NULL;

static id UH_toolbarItemForIdentifier(id self, SEL _cmd,
                                       NSToolbar *toolbar,
                                       NSString *identifier,
                                       BOOL willInsert) {
    if ([identifier isEqualToString:kUH_ToolbarID]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:kUH_ToolbarID];
        item.label        = @"History";
        item.paletteLabel = @"Undo History";
        item.toolTip      = @"Undo History";

        NSImage *icon = [NSImage imageWithSystemSymbolName:@"clock.arrow.trianglehead.counterclockwise.rotate.90"
                                  accessibilityDescription:@"Undo History"];
        if (!icon) icon = [NSImage imageWithSystemSymbolName:@"clock.arrow.circlepath"
                                     accessibilityDescription:@"Undo History"];
        if (!icon) icon = [NSImage imageNamed:NSImageNameRefreshTemplate];

        NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
            configurationWithPointSize:13 weight:NSFontWeightMedium];
        icon = [icon imageWithSymbolConfiguration:cfg];

        NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 32, 25)];
        [btn setButtonType:NSButtonTypePushOnPushOff];
        btn.bezelStyle    = NSBezelStyleTexturedRounded;
        btn.bordered      = YES;
        btn.image         = icon;
        btn.alternateImage = icon;
        btn.imagePosition = NSImageOnly;
        btn.target        = [UHPlugin_Controller shared];
        btn.action        = @selector(togglePanel:);
        item.view = btn;
        return item;
    }

    return ((id (*)(id, SEL, NSToolbar *, NSString *, BOOL))sOrigToolbarItemForIdentifier)(
        self, _cmd, toolbar, identifier, willInsert);
}

static void UH_installToolbarSwizzle(void) {
    if (sOrigToolbarItemForIdentifier) return;
    @try {
        Class cls = NSClassFromString(@"PEMainWindowModule");
        if (!cls) return;
        SEL sel = @selector(toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) return;
        sOrigToolbarItemForIdentifier = method_getImplementation(m);
        class_replaceMethod(cls, sel, (IMP)UH_toolbarItemForIdentifier,
                            method_getTypeEncoding(m));
        if (sAPI) sAPI->log(@"[UndoHistoryUI] Toolbar swizzle installed.");
    } @catch (NSException *e) {
        sOrigToolbarItemForIdentifier = NULL;
        if (sAPI) sAPI->log(@"[UndoHistoryUI] Toolbar swizzle failed: %@", e.reason);
    }
}

// ---------------------------------------------------------------------------
// Toolbar button insertion
// ---------------------------------------------------------------------------

static NSString * const kTranscriptToolbarID = @"SpliceKitTranscriptItemID";

static void UH_addButtonToToolbar(NSToolbar *toolbar) {
    @try {
        if (!toolbar.delegate) return;
        UH_installToolbarSwizzle();

        // Deduplicate: scan for existing item, clean up stale (no view) entries.
        BOOL hasButton = NO;
        for (NSInteger i = (NSInteger)toolbar.items.count - 1; i >= 0; i--) {
            NSToolbarItem *ti = toolbar.items[(NSUInteger)i];
            if ([ti.itemIdentifier isEqualToString:kUH_ToolbarID]) {
                if (ti.view) { hasButton = YES; }
                else         { [toolbar removeItemAtIndex:(NSUInteger)i]; }
            }
        }
        if (hasButton) return;

        // Insert after the Transcript button if present, else after flexible space.
        NSUInteger insertIdx = toolbar.items.count;
        for (NSUInteger i = 0; i < toolbar.items.count; i++) {
            if ([toolbar.items[i].itemIdentifier isEqualToString:kTranscriptToolbarID]) {
                insertIdx = i + 1;
                break;
            }
        }
        if (insertIdx == toolbar.items.count) {
            // No Transcript button found — fall back to just after flexible space.
            for (NSUInteger i = 0; i < toolbar.items.count; i++) {
                if ([toolbar.items[i].itemIdentifier
                        isEqualToString:NSToolbarFlexibleSpaceItemIdentifier]) {
                    insertIdx = i + 1;
                    break;
                }
            }
        }

        [toolbar insertItemWithItemIdentifier:kUH_ToolbarID atIndex:insertIdx];
        if (sAPI) sAPI->log(@"[UndoHistoryUI] History button inserted at index %lu.",
                             (unsigned long)insertIdx);
    } @catch (NSException *e) {
        if (sAPI) sAPI->log(@"[UndoHistoryUI] Toolbar insert exception: %@", e.reason);
    }
}

static void UH_tryInstall(int attempt);
static void UH_tryInstall(int attempt) {
    if (attempt >= 30) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        for (NSWindow *w in [[NSApplication sharedApplication] windows]) {
            if (w.toolbar && w.toolbar.items.count > 0) {
                UH_addButtonToToolbar(w.toolbar);
                return;
            }
        }
        UH_tryInstall(attempt + 1);
    });
}

static void UH_startToolbarInstall(void) {
    __block id observer =
        [[NSNotificationCenter defaultCenter]
             addObserverForName:NSWindowDidBecomeMainNotification
             object:nil queue:[NSOperationQueue mainQueue]
             usingBlock:^(NSNotification *note) {
                 NSWindow *win = note.object;
                 if (win.toolbar) {
                     [[NSNotificationCenter defaultCenter] removeObserver:observer];
                     observer = nil;
                     UH_addButtonToToolbar(win.toolbar);
                 }
             }];
    UH_tryInstall(0);
}

// ---------------------------------------------------------------------------
// Menu item injection into the Splices menu
// ---------------------------------------------------------------------------

static void UH_addMenuItemIfNeeded(void) {
    @try {
        NSMenu *mainMenu = [NSApp mainMenu];
        if (!mainMenu) return;

        // Find the Splices top-level menu.
        NSMenu *splicesMenu = nil;
        for (NSMenuItem *topItem in mainMenu.itemArray) {
            if ([topItem.title isEqualToString:@"Splices"]) {
                splicesMenu = topItem.submenu;
                break;
            }
        }
        if (!splicesMenu) return;

        // Check if "Undo History" is already present.
        for (NSMenuItem *item in splicesMenu.itemArray) {
            if ([item.title isEqualToString:@"Undo History"]) return;
        }

        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:@"Undo History"
                   action:@selector(togglePanel:)
            keyEquivalent:@"u"];
        item.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
        item.target = [UHPlugin_Controller shared];
        [splicesMenu addItem:item];

        if (sAPI) sAPI->log(@"[UndoHistoryUI] Added Undo History to Splices menu.");
    } @catch (NSException *e) {
        if (sAPI) sAPI->log(@"[UndoHistoryUI] Menu inject exception: %@", e.reason);
    }
}

// ---------------------------------------------------------------------------
// Plugin entry point
// ---------------------------------------------------------------------------

__attribute__((visibility("default")))
void SpliceKitPlugin_init(SpliceKitPluginAPI *api) {
    sAPIStorage = *api;
    sAPI = &sAPIStorage;

    sAPI->log(@"[UndoHistoryUI] Loading.");

    // Install NSUndoManager hooks (idempotent — safe even if host binary already called this).
    [SpliceKitUndoHistoryPanel installHooks];

    // Inject toolbar button and menu item on the main thread.
    api->executeOnMainThreadAsync(^{
        UH_addMenuItemIfNeeded();
        UH_startToolbarInstall();
    });

    sAPI->log(@"[UndoHistoryUI] Loaded.");
}
