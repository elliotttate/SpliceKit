//
//  SpliceKitUndoHistoryPanel.m
//  SpliceKit – Floating Undo History palette for Final Cut Pro
//
//  Architecture
//  ───────────
//  • Observes NSUndoManager group notifications (DidOpen / DidClose / Will+DidUndo /
//    Will+DidRedo) with object:nil so we catch every undo manager in the process.
//  • Tracks per-manager group nesting depth in a weak-keyed NSMapTable so nested
//    beginUndoGrouping/endUndoGrouping pairs don't generate spurious entries — only
//    the outermost close (depth 0→1→0) produces a new history entry.
//  • Suppresses recording during undo/redo replays (undo handlers register new actions
//    on the redo stack; we don't want those treated as fresh user actions).
//  • Stores up to kMaxEntries=100 SpliceKitUndoEntry objects in _entries (oldest→newest).
//    _cursor is the index of the last "done" entry (-1 = pristine state).
//  • The NSPanel shows a single-column NSTableView; row 0 is always the synthetic
//    "Pristine" row, rows 1..N correspond to _entries[0].._entries[N-1].
//    Rows ≤ (_cursor+1) are current/past; rows > (_cursor+1) are redo-available (grey).
//    Clicking any row calls -jumpToIndex: which loops undo/redo to reach that state.
//

#import "SpliceKitUndoHistoryPanel.h"
#import "SpliceKit.h"
#import <objc/runtime.h>

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

static const NSInteger kMaxEntries = 100;
static NSString * const kPrisitineLabel = @"(Pristine)";

// ---------------------------------------------------------------------------
// SpliceKitUndoEntry
// ---------------------------------------------------------------------------

@implementation SpliceKitUndoEntry
@end

// ---------------------------------------------------------------------------
// SpliceKitUndoHistoryTableView – forwards clicks to panel before selection
// ---------------------------------------------------------------------------

@interface SpliceKitUndoHistoryTableView : NSTableView
@property (nonatomic, weak) id clickTarget;
@property (nonatomic) SEL clickAction;
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

@interface SpliceKitUndoHistoryPanel () <NSTableViewDataSource, NSTableViewDelegate>

// History state
@property (nonatomic, strong) NSMutableArray<SpliceKitUndoEntry *> *entries;
@property (nonatomic)         NSInteger cursor;          // -1 = pristine
@property (nonatomic)         BOOL      suppressRecord;  // YES during undo/redo replay

// Nesting depth tracking: NSUndoManager* (weak) → NSNumber (depth)
@property (nonatomic, strong) NSMapTable *nestingDepths;

// UI
@property (nonatomic, strong) NSPanel                         *panel;
@property (nonatomic, strong) SpliceKitUndoHistoryTableView   *tableView;
@property (nonatomic, strong) NSScrollView                    *scrollView;
@property (nonatomic, strong) NSButton                        *clearButton;

@end

@implementation SpliceKitUndoHistoryPanel

// ---------------------------------------------------------------------------
// Singleton
// ---------------------------------------------------------------------------

+ (instancetype)sharedPanel {
    static SpliceKitUndoHistoryPanel *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[SpliceKitUndoHistoryPanel alloc] init];
    });
    return instance;
}

// ---------------------------------------------------------------------------
// Hook installation (called once at app-did-finish-launch)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _entries = [NSMutableArray array];
    _cursor  = -1;
    _nestingDepths = [NSMapTable weakToStrongObjectsMapTable];

    [self _buildPanel];
    return self;
}

// ---------------------------------------------------------------------------
// Panel construction
// ---------------------------------------------------------------------------

- (void)_buildPanel {
    NSRect frame = NSMakeRect(200, 400, 300, 480);
    _panel = [[NSPanel alloc] initWithContentRect:frame
                                        styleMask:NSWindowStyleMaskTitled
                                                 |NSWindowStyleMaskClosable
                                                 |NSWindowStyleMaskMiniaturizable
                                                 |NSWindowStyleMaskResizable
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
    _panel.title            = @"Undo History";
    _panel.floatingPanel    = YES;
    _panel.becomesKeyOnlyIfNeeded = YES;
    _panel.minSize          = NSMakeSize(220, 200);

    NSView *content = _panel.contentView;

    // ── Clear button ──────────────────────────────────────────────────────
    _clearButton = [NSButton buttonWithTitle:@"Clear"
                                      target:self
                                      action:@selector(_clearButtonClicked:)];
    _clearButton.translatesAutoresizingMaskIntoConstraints = NO;
    _clearButton.bezelStyle = NSBezelStyleRounded;
    _clearButton.controlSize = NSControlSizeSmall;
    [content addSubview:_clearButton];

    // ── Table view ────────────────────────────────────────────────────────
    _tableView = [[SpliceKitUndoHistoryTableView alloc] initWithFrame:NSZeroRect];
    _tableView.clickTarget = self;
    _tableView.clickAction = @selector(_rowClicked:);
    _tableView.dataSource = self;
    _tableView.delegate   = self;
    _tableView.headerView = nil;
    _tableView.rowSizeStyle    = NSTableViewRowSizeStyleSmall;
    _tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    _tableView.usesAlternatingRowBackgroundColors = NO;
    _tableView.gridStyleMask = NSTableViewGridNone;
    _tableView.focusRingType = NSFocusRingTypeNone;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"action"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:col];

    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.documentView             = _tableView;
    _scrollView.hasVerticalScroller      = YES;
    _scrollView.autohidesScrollers       = YES;
    _scrollView.borderType               = NSNoBorder;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_scrollView];

    // ── Layout ────────────────────────────────────────────────────────────
    NSDictionary *views = @{@"scroll": _scrollView, @"clear": _clearButton};
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

    // Auto-size the single column to fill scroll view width
    [_tableView sizeLastColumnToFit];
}

// ---------------------------------------------------------------------------
// Visibility
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// NSUndoManager notification handlers
// ---------------------------------------------------------------------------

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

    // Top-level group just closed — record the action.
    // FCP prefixes many action names with "Edit " internally; strip it to match
    // what the Edit menu displays (e.g. "Edit Blade" → "Blade").
    NSString *name = [um undoActionName];
    if ([name hasPrefix:@"Edit "]) name = [name substringFromIndex:5];
    if (name.length == 0 || [name isEqualToString:@"Edit"]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self _recordAction:name];
    });
}

// ---------------------------------------------------------------------------
// History management
// ---------------------------------------------------------------------------

- (void)_recordAction:(NSString *)name {
    // Ring: if at capacity, drop the oldest entry and adjust cursor.
    if ((NSInteger)_entries.count >= kMaxEntries) {
        [_entries removeObjectAtIndex:0];
        // Re-index all entries
        for (NSInteger i = 0; i < (NSInteger)_entries.count; i++) {
            _entries[(NSUInteger)i].index = i;
        }
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

// ---------------------------------------------------------------------------
// Table reload + scroll-to-current
// ---------------------------------------------------------------------------

- (void)_reloadTable {
    [_tableView reloadData];

    // Scroll so the current row is visible.
    if (_cursor >= 0 && _cursor < (NSInteger)_entries.count) {
        [_tableView scrollRowToVisible:_cursor];
    }
}

// ---------------------------------------------------------------------------
// NSTableViewDataSource
// ---------------------------------------------------------------------------

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return (NSInteger)_entries.count;
}

// ---------------------------------------------------------------------------
// NSTableViewDelegate
// ---------------------------------------------------------------------------

- (NSView *)tableView:(NSTableView *)tv
   viewForTableColumn:(NSTableColumn *)col
                  row:(NSInteger)row {
    NSTextField *label = [tv makeViewWithIdentifier:@"cell" owner:self];
    if (!label) {
        label = [NSTextField labelWithString:@""];
        label.identifier = @"cell";
        label.lineBreakMode = NSLineBreakByTruncatingTail;
    }

    BOOL isCurrent = (row == _cursor);

    SpliceKitUndoEntry *entry = _entries[(NSUInteger)row];
    NSString *text = entry.actionName;

    if (isCurrent) {
        label.font      = [NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]];
        label.textColor = [NSColor controlAccentColor];
    } else {
        label.font      = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
        label.textColor = [NSColor labelColor];
    }

    label.stringValue = text;
    return label;
}

- (CGFloat)tableView:(NSTableView *)tv heightOfRow:(NSInteger)row {
    return 20.0;
}

// ---------------------------------------------------------------------------
// Row click → jump
// ---------------------------------------------------------------------------

- (void)_rowClicked:(NSNumber *)rowNumber {
    NSInteger row = rowNumber.integerValue;
    if (row == _cursor) return;
    [self jumpToIndex:row];
}

- (void)_clearButtonClicked:(id)sender {
    [self clearHistory];
}

// ---------------------------------------------------------------------------
// RPC: getHistory
// ---------------------------------------------------------------------------

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

        // Determine canUndo / canRedo from the live undo manager if available.
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
            @"entries":  [arr copy],
            @"cursor":   @(self->_cursor),
            @"canUndo":  @(canUndo),
            @"canRedo":  @(canRedo),
            @"visible":  @(self->_panel.isVisible)
        };
    });
    return result;
}

// ---------------------------------------------------------------------------
// RPC: jumpToIndex
// ---------------------------------------------------------------------------

- (NSDictionary *)jumpToIndex:(NSInteger)target {
    if (target < -1 || target >= (NSInteger)_entries.count) {
        return @{@"error": @"Index out of range"};
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        // Resolve the undo manager
        NSUndoManager *um = nil;
        @try {
            id delegate = [[NSApplication sharedApplication] delegate];
            id lib = [delegate performSelector:@selector(_targetLibrary)];
            id doc = ((id(*)(id,SEL))objc_msgSend)(lib, @selector(libraryDocument));
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

        // Advance cursor to where we actually landed and refresh the highlight.
        self->_cursor += performed;
        [self _reloadTable];

        result = @{
            @"status":    @"ok",
            @"moved":     @(performed),
            @"cursor":    @(self->_cursor),
            @"canUndo":   @([um canUndo]),
            @"canRedo":   @([um canRedo])
        };
    });
    return result;
}

@end
