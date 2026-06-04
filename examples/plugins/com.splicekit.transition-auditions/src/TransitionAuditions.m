//
//  TransitionAuditions.m
//  com.splicekit.transition-auditions
//
//  Adds a "Transition Auditions" button to FCP's timeline bar.
//
//  IDLE state:
//    - Segmented control: [All Transitions] [Custom Set]
//    - In Custom mode: searchable checkbox table
//    - [Start Audition] — finds nearest edit point, applies first transition
//
//  ACTIVE state — tournament bracket:
//    Each transition is applied at the edit point.
//    [▶ Preview]        — seek 2s before transition, play
//    [👍 Add to Audition] — keep this one in the running, advance
//    [👎 Skip]           — eliminate this one, advance
//    After all are evaluated, repeat with the survivors.
//    When only one transition remains it is applied and the popover closes.
//
//  Custom set persisted in {dataPath}/custom-set.json.
//
//  Build:   make
//  Install: make install
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <float.h>

#import "SpliceKitPluginAPI.h"

// ---------------------------------------------------------------------------
// Plugin globals
// ---------------------------------------------------------------------------
static SpliceKitPluginAPI  sTAuAPIStorage;
static SpliceKitPluginAPI *sTAuAPI = NULL;

static NSString * const kTAuButtonID  = @"SpliceKitTAu_AuditionButtonID";
static NSString * const kSFPBackwardID = @"SpliceKitSFP_SelectBackwardItemID";

// ---------------------------------------------------------------------------
#pragma mark - Audition state
// ---------------------------------------------------------------------------

typedef NS_ENUM(NSInteger, TAuPhase) {
    TAuPhaseIdle = 0,
    TAuPhaseActive,
};

@interface TAuState : NSObject
@property (nonatomic) TAuPhase phase;
// Tournament bracket
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *pendingQueue; // not yet voted this round
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *keptSet;      // survived this round
@property (nonatomic, strong) NSDictionary *currentTransition;              // currently applied
@property (nonatomic) NSInteger currentIndex;   // index into pendingQueue of currentTransition
@property (nonatomic) double  editPointTime;    // seconds
@property (nonatomic) NSInteger roundNumber;
@property (nonatomic) NSInteger originalCount;  // set at start of each round
@property (nonatomic) NSInteger positionInRound; // 1-indexed display counter
// If there was already a transition at the edit point when audition started,
// we delete it first so addTransition: can succeed (count 0→1).
// Cancel fires one extra undo to restore it.
@property (nonatomic) BOOL hadOriginalTransition;
@end

@implementation TAuState
- (instancetype)init {
    self = [super init];
    _phase                  = TAuPhaseIdle;
    _pendingQueue           = [NSMutableArray array];
    _keptSet                = [NSMutableArray array];
    _currentIndex           = 0;
    _editPointTime          = 0;
    _roundNumber            = 0;
    _originalCount          = 0;
    _positionInRound        = 1;
    _hadOriginalTransition  = NO;
    return self;
}
@end

// ---------------------------------------------------------------------------
#pragma mark - Settings persistence  (preroll / postroll / custom set)
// ---------------------------------------------------------------------------

static NSMutableSet<NSString *> *sTAuCustomIDs     = nil;
static NSString                 *sTAuDataPath       = nil;
static double                    sTAuPrerollSeconds  = 2.0;
static double                    sTAuPostrollSeconds = 2.0;

// Loop interval = preroll + ~1.2s default transition buffer + postroll
static NSTimeInterval TAu_loopInterval(void) {
    return sTAuPrerollSeconds + 1.2 + sTAuPostrollSeconds;
}

static void TAu_loadSettings(void) {
    if (!sTAuDataPath) return;
    NSString    *path = [sTAuDataPath stringByAppendingPathComponent:@"settings.json"];
    NSData      *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![d isKindOfClass:[NSDictionary class]]) return;
    if (d[@"prerollSeconds"])  sTAuPrerollSeconds  = MAX(2.0, MIN(5.0, [d[@"prerollSeconds"]  doubleValue]));
    if (d[@"postrollSeconds"]) sTAuPostrollSeconds = MAX(2.0, MIN(5.0, [d[@"postrollSeconds"] doubleValue]));
}

static void TAu_saveSettings(void) {
    if (!sTAuDataPath) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:sTAuDataPath
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *d = @{@"prerollSeconds":  @(sTAuPrerollSeconds),
                        @"postrollSeconds": @(sTAuPostrollSeconds)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (data)
        [data writeToFile:[sTAuDataPath stringByAppendingPathComponent:@"settings.json"]
               atomically:YES];
}

static void TAu_loadCustomSet(void) {
    sTAuCustomIDs = [NSMutableSet set];
    if (!sTAuDataPath) return;
    NSString *path = [sTAuDataPath stringByAppendingPathComponent:@"custom-set.json"];
    NSData   *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;
    NSArray *ids = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([ids isKindOfClass:[NSArray class]])
        [sTAuCustomIDs addObjectsFromArray:ids];
}

static void TAu_saveCustomSet(void) {
    if (!sTAuDataPath || !sTAuCustomIDs) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:sTAuDataPath
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:[sTAuCustomIDs allObjects]
                                                   options:0 error:nil];
    if (data)
        [data writeToFile:[sTAuDataPath stringByAppendingPathComponent:@"custom-set.json"]
               atomically:YES];
}

// ---------------------------------------------------------------------------
#pragma mark - RPC helpers  (background thread)
// ---------------------------------------------------------------------------

static NSArray<NSDictionary *> *TAu_loadAllTransitions(void) {
    NSDictionary *r      = sTAuAPI->callMethod(@{@"method": @"transitions.list"});
    NSDictionary *result = r[@"result"];
    NSArray      *list   = result[@"transitions"];
    if (![list isKindOfClass:[NSArray class]]) return @[];

    // Deduplicate by display name — the same transition often appears multiple
    // times with different effectIDs when it is saved in Favorites as well as
    // its original category folder.  Keep the first occurrence of each name.
    NSMutableOrderedSet<NSString *> *seen = [NSMutableOrderedSet orderedSet];
    NSMutableArray<NSDictionary *>  *deduped = [NSMutableArray array];
    for (NSDictionary *t in list) {
        NSString *name = t[@"name"] ?: @"";
        if (![seen containsObject:name]) {
            [seen addObject:name];
            [deduped addObject:t];
        }
    }
    sTAuAPI->log(@"[TAu] Loaded %lu transitions (%lu after dedup)",
                 (unsigned long)[(NSArray *)list count], (unsigned long)deduped.count);
    return deduped;
}

// Returns the edit-point time (seconds) to audition, or -1 if none qualifies.
//
// Rules:
//   1. Only consider primary-storyline FFAnchoredTransition objects.
//   2. Exclude the last (highest-midpoint) transition — it's at the sequence
//      tail with no postroll room.
//   3. Among the remaining candidates:
//        a. A SELECTED transition takes priority regardless of playhead distance.
//        b. Otherwise, use the candidate whose midpoint is nearest the playhead,
//           provided it is within 10 seconds (prevents auditing a random distant
//           transition when the playhead is far away).
//   4. Fall back to nearest bare clip boundary if no transitions exist at all.
static double TAu_findNearestEditPoint(void) {
    NSDictionary *r      = sTAuAPI->callMethod(@{@"method": @"timeline.getDetailedState"});
    NSDictionary *result = r[@"result"];
    if (!result || result[@"error"] || !result[@"items"]) return -1;

    double  playhead = [result[@"playheadTime"][@"seconds"] doubleValue];
    NSArray *items   = result[@"items"];

    // --- Collect primary-storyline transitions ---
    NSMutableArray<NSDictionary *> *transitions = [NSMutableArray array];
    for (NSDictionary *item in items) {
        NSNumber *lane = item[@"lane"];
        if (lane && [lane integerValue] != 0) continue;
        if (![item[@"class"] containsString:@"Transition"]) continue;
        if (!item[@"startTime"] || !item[@"endTime"]) continue;
        [transitions addObject:item];
    }

    if (transitions.count > 0) {
        // Sequence duration — used to detect end-of-sequence transitions.
        double seqDuration = [result[@"duration"][@"seconds"] doubleValue];

        // Exclude transitions with less than 2s of postroll.
        NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
        for (NSDictionary *t in transitions) {
            double te  = [t[@"endTime"][@"seconds"] doubleValue];
            double postroll = seqDuration - te;
            if (seqDuration > 0 && postroll < 2.0) {
                sTAuAPI->log(@"[TAu] skipping end-of-sequence transition (postroll=%.2fs)", postroll);
                continue;
            }
            [candidates addObject:t];
        }

        // Priority 1: transition whose range CONTAINS the playhead.
        // When the user scrubs to a transition this fires instantly.
        for (NSDictionary *t in candidates) {
            double ts = [t[@"startTime"][@"seconds"] doubleValue];
            double te = [t[@"endTime"][@"seconds"]   doubleValue];
            if (playhead >= ts && playhead <= te) {
                double mid = (ts + te) / 2.0;
                sTAuAPI->log(@"[TAu] edit point: playhead inside transition at %.4fs", mid);
                return mid;
            }
        }

        // Priority 2: nearest transition to the playhead.
        // FCP's selectedItems: never includes transitions, so we can't detect
        // "highlighted" programmatically — proximity to playhead is the signal.
        double nearest = -1, bestDist = DBL_MAX;
        for (NSDictionary *t in candidates) {
            double ts  = [t[@"startTime"][@"seconds"] doubleValue];
            double te  = [t[@"endTime"][@"seconds"]   doubleValue];
            double mid = (ts + te) / 2.0;
            double dist = fabs(mid - playhead);
            if (dist < bestDist) { bestDist = dist; nearest = mid; }
        }
        if (nearest >= 0) {
            sTAuAPI->log(@"[TAu] edit point: nearest transition at %.4fs (dist %.2fs)", nearest, bestDist);
            return nearest;
        }
    }

    // --- Fallback: bare clip boundaries (no transitions on timeline yet) ---
    NSMutableArray<NSDictionary *> *clips = [NSMutableArray array];
    for (NSDictionary *item in items) {
        NSNumber *lane = item[@"lane"];
        if (lane && [lane integerValue] != 0) continue;
        if ([item[@"class"] containsString:@"Transition"]) continue;
        if (!item[@"startTime"] || !item[@"endTime"])      continue;
        [clips addObject:item];
    }
    [clips sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double ta = [a[@"startTime"][@"seconds"] doubleValue];
        double tb = [b[@"startTime"][@"seconds"] doubleValue];
        return (ta < tb) ? NSOrderedAscending : (ta > tb ? NSOrderedDescending : NSOrderedSame);
    }];
    // Exclude boundaries with less than 2s remaining in the sequence.
    double seqDur2   = [result[@"duration"][@"seconds"] doubleValue];
    double nearest   = -1, bestDist = DBL_MAX;
    for (NSInteger i = 0; i + 1 < (NSInteger)clips.count; i++) {
        double boundary = [clips[i][@"endTime"][@"seconds"] doubleValue];
        if (seqDur2 > 0 && (seqDur2 - boundary) < 2.0) continue;
        double dist = fabs(boundary - playhead);
        if (dist < bestDist) { bestDist = dist; nearest = boundary; }
    }
    if (nearest >= 0)
        sTAuAPI->log(@"[TAu] edit point: clip boundary at %.4fs (dist %.2fs)", nearest, bestDist);
    return nearest;
}

static void TAu_seekToTime(double seconds) {
    sTAuAPI->callMethod(@{
        @"method": @"playback.seekToTime",
        @"params": @{@"seconds": @(seconds)}
    });
}

static BOOL TAu_isPlaying(void) {
    NSDictionary *r = sTAuAPI->callMethod(@{@"method": @"playback.getPosition"});
    return [r[@"result"][@"isPlaying"] boolValue];
}

static void TAu_play(void) {
    sTAuAPI->callMethod(@{@"method": @"playback.action",
                          @"params": @{@"action": @"playPause"}});
}

static void TAu_ensurePlaying(void) {
    if (!TAu_isPlaying()) TAu_play();
}

static void TAu_ensurePaused(void) {
    if (TAu_isPlaying()) TAu_play();
}

static void TAu_applyTransition(NSDictionary *transition) {
    NSDictionary *r = sTAuAPI->callMethod(@{
        @"method": @"transitions.apply",
        @"params": @{@"effectID": transition[@"effectID"], @"freezeExtend": @YES}
    });
    NSDictionary *res = r[@"result"];
    if (res[@"error"] || r[@"error"]) {
        sTAuAPI->log(@"[TAu] apply '%@' ERROR: %@", transition[@"name"], res[@"error"] ?: r[@"error"]);
    } else {
        sTAuAPI->log(@"[TAu] apply '%@' OK: %@", transition[@"name"], res[@"transition"]);
    }
}

static void TAu_undo(void) {
    NSDictionary *r = sTAuAPI->callMethod(@{
        @"method": @"timeline.action",
        @"params": @{@"action": @"undo"}
    });
    NSDictionary *res = r[@"result"];
    sTAuAPI->log(@"[TAu] undo -> action='%@' error='%@'", res[@"action"] ?: @"?", r[@"error"] ?: @"none");
}

// Delete the transition at editTime.
// Strategy: getDetailedState gives us item handles; use the handle to call
// setSelectedItems: directly on the timeline module, then delete via responder chain.
// This avoids selectClipAtPlayhead which ignores transitions entirely.
static BOOL TAu_deleteExistingTransitionAt(double editTime) {
    NSDictionary *r      = sTAuAPI->callMethod(@{@"method": @"timeline.getDetailedState"});
    NSDictionary *result = r[@"result"];
    NSArray      *items  = result[@"items"];
    if (!items) return NO;

    // Find the transition item within 1s of editTime and grab its handle string
    NSString *transHandle = nil;
    for (NSDictionary *item in items) {
        if (![item[@"class"] containsString:@"Transition"]) continue;
        double ts  = [item[@"startTime"][@"seconds"] doubleValue];
        double te  = [item[@"endTime"][@"seconds"]   doubleValue];
        double mid = (ts + te) / 2.0;
        if (fabs(mid - editTime) < 1.0) { transHandle = item[@"handle"]; break; }
    }
    if (!transHandle) return NO;

    // Resolve the handle to the live ObjC object via SpliceKit's inspect endpoint,
    // then select it directly on the timeline module and delete.
    // SpliceKit stores handles in a global registry; call_method_with_args can
    // dereference them. We use call_method with the handle as the receiver to
    // call a no-op selector just to confirm it's alive, then select via main thread.
    __block BOOL deleted = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            // Retrieve the live object from SpliceKit's handle table via the
            // inspect_handle RPC which returns the pointer address. We can also
            // directly call objc_msgSend on the stored pointer if we can retrieve it.
            //
            // Simpler: use the bridge's list_handles to get the raw pointer, but
            // the cleanest path is to traverse the live sequence ourselves now that
            // we know the transition's midpoint.
            id delegate = [[NSApplication sharedApplication] delegate];
            id ec = ((id(*)(id,SEL))objc_msgSend)(delegate, NSSelectorFromString(@"activeEditorContainer"));
            id tm = ((id(*)(id,SEL))objc_msgSend)(ec,       NSSelectorFromString(@"timelineModule"));
            id seq = ((id(*)(id,SEL))objc_msgSend)(tm,      NSSelectorFromString(@"sequence"));
            id primary = ((id(*)(id,SEL))objc_msgSend)(seq, NSSelectorFromString(@"primaryObject"));
            NSArray *liveItems = ((NSArray*(*)(id,SEL))objc_msgSend)(primary, NSSelectorFromString(@"containedItems"));

            Class transCls = NSClassFromString(@"FFAnchoredTransition");
            SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
            id found = nil;

            for (id item in liveItems) {
                if (transCls && ![item isKindOfClass:transCls]) continue;
                if (![primary respondsToSelector:erSel]) continue;
                // effectiveRangeOfObject: returns a CMTimeRange struct.
                // CMTimeRange = { CMTime start, CMTime duration }
                // CMTime = { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; }
                // Total: 2 × (8+4+4+8) = 2 × 24 = 48 bytes on arm64.
                // Use NSInvocation to call the struct-returning method safely.
                NSMethodSignature *sig = [primary methodSignatureForSelector:erSel];
                if (!sig) continue;
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target   = primary;
                inv.selector = erSel;
                id itemArg = item;
                [inv setArgument:&itemArg atIndex:2];
                [inv invoke];

                // Read the returned struct: 48 bytes
                uint8_t buf[48] = {0};
                [inv getReturnValue:buf];
                // start: bytes 0-23, duration: bytes 24-47
                int64_t sv = *(int64_t *)(buf + 0);
                int32_t sts = *(int32_t *)(buf + 8);
                int64_t dv = *(int64_t *)(buf + 24);
                int32_t dts = *(int32_t *)(buf + 32);
                double startSec = sts > 0 ? (double)sv / sts : 0;
                double durSec   = dts > 0 ? (double)dv / dts : 0;
                double mid = startSec + durSec / 2.0;
                if (fabs(mid - editTime) < 1.0) { found = item; break; }
            }

            if (!found) return;

            // Select the transition directly on the timeline module
            SEL setSel = NSSelectorFromString(@"setSelectedItems:");
            if ([tm respondsToSelector:setSel])
                ((void(*)(id,SEL,id))objc_msgSend)(tm, setSel, @[found]);
            deleted = YES;
        } @catch (NSException *e) {
            sTAuAPI->log(@"[TAu] findTransition exception: %@", e.reason);
        }
    });

    if (!deleted) return NO;

    [NSThread sleepForTimeInterval:0.05];
    sTAuAPI->callMethod(@{@"method": @"timeline.action", @"params": @{@"action": @"delete"}});
    [NSThread sleepForTimeInterval:0.15];
    sTAuAPI->log(@"[TAu] Deleted existing transition at %.3fs", editTime);
    return YES;
}

// ---------------------------------------------------------------------------
#pragma mark - Popover controller
// ---------------------------------------------------------------------------

@interface TAuPopoverController : NSObject <NSPopoverDelegate,
                                            NSTableViewDataSource,
                                            NSTableViewDelegate,
                                            NSSearchFieldDelegate>

@property (nonatomic, strong) NSPopover     *popover;
@property (nonatomic, weak)   NSButton      *toolbarButton;
@property (nonatomic)         BOOL           cancelingAudition; // YES only when Cancel button tapped

// Transition library
@property (nonatomic, strong) NSArray<NSDictionary *> *allTransitions;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredTransitions;
@property (nonatomic)         BOOL loading;

// Audition state
@property (nonatomic, strong) TAuState *audition;

// ---- Idle UI ----
@property (nonatomic, strong) NSView              *idleView;
@property (nonatomic, strong) NSPopUpButton       *prerollPopup;
@property (nonatomic, strong) NSPopUpButton       *postrollPopup;
@property (nonatomic, strong) NSSegmentedControl  *modeControl;
@property (nonatomic, strong) NSScrollView        *tableScroll;
@property (nonatomic, strong) NSTableView         *tableView;
@property (nonatomic, strong) NSSearchField       *searchField;
@property (nonatomic, strong) NSTextField         *countLabel;
@property (nonatomic, strong) NSButton            *startButton;
@property (nonatomic, strong) NSProgressIndicator *spinner;

// Preview loop
@property (nonatomic, strong) NSTimer     *loopTimer;
@property (atomic)            BOOL         loopActive; // checked by in-flight bg blocks

// ---- Active UI ----
@property (nonatomic, strong) NSView      *activeView;
@property (nonatomic, strong) NSTextField *roundLabel;      // "Round 2"
@property (nonatomic, strong) NSTextField *nameLabel;       // transition name
@property (nonatomic, strong) NSTextField *progressLabel;   // "3 of 7 remaining"
@property (nonatomic, strong) NSButton    *previewButton;
@property (nonatomic, strong) NSButton    *prevButton;      // browse prev
@property (nonatomic, strong) NSButton    *nextButton;      // browse next
@property (nonatomic, strong) NSButton    *addButton;       // 👍 Add to Audition
@property (nonatomic, strong) NSButton    *skipButton;      // 👎 Reject
@property (nonatomic, strong) NSButton    *cancelButton;
@property (nonatomic, strong) NSButton    *confirmButton;     // keep transition + exit
@property (nonatomic, strong) NSButton    *confirmFavButton;  // keep transition + add to favorites + exit

+ (instancetype)shared;
- (void)toggleFromButton:(NSButton *)button;

@end

@implementation TAuPopoverController

+ (instancetype)shared {
    static TAuPopoverController *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _allTransitions      = @[];
    _filteredTransitions = @[];
    _audition            = [[TAuState alloc] init];
    return self;
}

// ---------------------------------------------------------------------------
#pragma mark Popover building
// ---------------------------------------------------------------------------

- (void)buildPopoverIfNeeded {
    if (_popover) return;

    // ============================  IDLE VIEW  ================================
    NSView *idle = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 390)];
    idle.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *title = [NSTextField labelWithString:@"Transition Auditions"];
    title.font    = [NSFont boldSystemFontOfSize:13];
    title.toolTip = @"Scrub the playhead to the transition you want to audition, then click Start Audition.";
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [idle addSubview:title];

    // --- Preroll / Postroll row ---
    NSTextField *prerollLbl = [NSTextField labelWithString:@"Preroll:"];
    prerollLbl.font = [NSFont systemFontOfSize:12];
    prerollLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [idle addSubview:prerollLbl];

    NSPopUpButton *prerollPop = [[NSPopUpButton alloc] init];
    for (int s = 2; s <= 5; s++)
        [prerollPop addItemWithTitle:[NSString stringWithFormat:@"%ds", s]];
    [prerollPop selectItemWithTitle:[NSString stringWithFormat:@"%ds", (int)sTAuPrerollSeconds]];
    prerollPop.target = self;
    prerollPop.action = @selector(prerollChanged:);
    prerollPop.translatesAutoresizingMaskIntoConstraints = NO;
    [idle addSubview:prerollPop];

    NSTextField *postrollLbl = [NSTextField labelWithString:@"Postroll:"];
    postrollLbl.font = [NSFont systemFontOfSize:12];
    postrollLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [idle addSubview:postrollLbl];

    NSPopUpButton *postrollPop = [[NSPopUpButton alloc] init];
    for (int s = 2; s <= 5; s++)
        [postrollPop addItemWithTitle:[NSString stringWithFormat:@"%ds", s]];
    [postrollPop selectItemWithTitle:[NSString stringWithFormat:@"%ds", (int)sTAuPostrollSeconds]];
    postrollPop.target = self;
    postrollPop.action = @selector(postrollChanged:);
    postrollPop.translatesAutoresizingMaskIntoConstraints = NO;
    [idle addSubview:postrollPop];

    NSSegmentedControl *mode = [NSSegmentedControl
        segmentedControlWithLabels:@[@"All Transitions", @"Custom Set"]
        trackingMode:NSSegmentSwitchTrackingSelectOne
        target:self action:@selector(modeChanged:)];
    mode.selectedSegment = 0;
    mode.translatesAutoresizingMaskIntoConstraints = NO;
    [idle addSubview:mode];

    NSSearchField *sf = [[NSSearchField alloc] init];
    sf.placeholderString = @"Filter transitions…";
    sf.delegate = self;
    sf.hidden   = YES;
    sf.translatesAutoresizingMaskIntoConstraints = NO;
    [idle addSubview:sf];

    NSTableView *tv = [[NSTableView alloc] init];
    tv.dataSource    = self;
    tv.delegate      = self;
    tv.rowHeight     = 20;
    tv.headerView    = nil;
    tv.focusRingType = NSFocusRingTypeNone;

    NSTableColumn *checkCol = [[NSTableColumn alloc] initWithIdentifier:@"check"];
    checkCol.width = checkCol.minWidth = checkCol.maxWidth = 24;
    NSButtonCell *checkCell = [[NSButtonCell alloc] init];
    checkCell.buttonType  = NSButtonTypeSwitch;
    checkCell.controlSize = NSControlSizeSmall;
    checkCell.title       = @"";
    checkCol.dataCell = checkCell;
    [tv addTableColumn:checkCol];

    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameCol.width    = 270;
    nameCol.editable = NO;
    [tv addTableColumn:nameCol];

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.documentView        = tv;
    scroll.hasVerticalScroller = YES;
    scroll.borderType          = NSBezelBorder;
    scroll.hidden              = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [idle addSubview:scroll];

    NSTextField *count = [NSTextField labelWithString:@""];
    count.textColor = [NSColor secondaryLabelColor];
    count.font      = [NSFont systemFontOfSize:11];
    count.hidden    = NO;
    count.translatesAutoresizingMaskIntoConstraints = NO;
    [idle addSubview:count];

    NSProgressIndicator *spin = [[NSProgressIndicator alloc] init];
    spin.style       = NSProgressIndicatorStyleSpinning;
    spin.controlSize = NSControlSizeSmall;
    spin.hidden      = YES;
    spin.translatesAutoresizingMaskIntoConstraints = NO;
    [idle addSubview:spin];

    NSButton *start = [NSButton buttonWithTitle:@"Start Audition"
                                         target:self action:@selector(startAudition:)];
    start.bezelStyle   = NSBezelStyleRounded;
    start.keyEquivalent = @"\r";
    start.translatesAutoresizingMaskIntoConstraints = NO;
    [idle addSubview:start];

    CGFloat pad = 14, gap = 8;
    [NSLayoutConstraint activateConstraints:@[
        [idle.widthAnchor  constraintEqualToConstant:320],
        [idle.heightAnchor constraintEqualToConstant:420],

        // Title row
        [title.topAnchor     constraintEqualToAnchor:idle.topAnchor constant:pad],
        [title.leadingAnchor constraintEqualToAnchor:idle.leadingAnchor constant:pad],

        [spin.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [spin.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:6],

        // Preroll / Postroll row (below title)
        [prerollLbl.topAnchor     constraintEqualToAnchor:title.bottomAnchor constant:gap],
        [prerollLbl.leadingAnchor constraintEqualToAnchor:idle.leadingAnchor constant:pad],
        [prerollLbl.centerYAnchor constraintEqualToAnchor:prerollPop.centerYAnchor],

        [prerollPop.topAnchor     constraintEqualToAnchor:title.bottomAnchor constant:gap],
        [prerollPop.leadingAnchor constraintEqualToAnchor:prerollLbl.trailingAnchor constant:4],
        [prerollPop.widthAnchor   constraintEqualToConstant:62],

        [postrollLbl.centerYAnchor constraintEqualToAnchor:prerollPop.centerYAnchor],
        [postrollLbl.leadingAnchor constraintEqualToAnchor:prerollPop.trailingAnchor constant:12],

        [postrollPop.topAnchor     constraintEqualToAnchor:prerollPop.topAnchor],
        [postrollPop.leadingAnchor constraintEqualToAnchor:postrollLbl.trailingAnchor constant:4],
        [postrollPop.widthAnchor   constraintEqualToConstant:62],

        // Mode control (All / Custom) — below preroll row
        [mode.topAnchor      constraintEqualToAnchor:prerollPop.bottomAnchor constant:gap],
        [mode.leadingAnchor  constraintEqualToAnchor:idle.leadingAnchor constant:pad],
        [mode.trailingAnchor constraintEqualToAnchor:idle.trailingAnchor constant:-pad],

        [sf.topAnchor      constraintEqualToAnchor:mode.bottomAnchor constant:gap],
        [sf.leadingAnchor  constraintEqualToAnchor:idle.leadingAnchor constant:pad],
        [sf.trailingAnchor constraintEqualToAnchor:idle.trailingAnchor constant:-pad],

        [scroll.topAnchor      constraintEqualToAnchor:sf.bottomAnchor constant:4],
        [scroll.leadingAnchor  constraintEqualToAnchor:idle.leadingAnchor constant:pad],
        [scroll.trailingAnchor constraintEqualToAnchor:idle.trailingAnchor constant:-pad],
        [scroll.heightAnchor   constraintEqualToConstant:230],

        [count.topAnchor     constraintEqualToAnchor:mode.bottomAnchor constant:gap],
        [count.leadingAnchor constraintEqualToAnchor:idle.leadingAnchor constant:pad],

        [start.bottomAnchor   constraintEqualToAnchor:idle.bottomAnchor constant:-pad],
        [start.trailingAnchor constraintEqualToAnchor:idle.trailingAnchor constant:-pad],
    ]];

    self.prerollPopup = prerollPop;
    self.postrollPopup = postrollPop;
    self.modeControl  = mode;
    self.searchField  = sf;
    self.tableScroll  = scroll;
    self.tableView    = tv;
    self.countLabel   = count;
    self.spinner      = spin;
    self.startButton  = start;
    self.idleView     = idle;

    // ============================  ACTIVE VIEW  ==============================
    NSView *active = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 240)];
    active.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *roundLbl = [NSTextField labelWithString:@"Round 1"];
    roundLbl.textColor = [NSColor secondaryLabelColor];
    roundLbl.font      = [NSFont systemFontOfSize:11];
    roundLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [active addSubview:roundLbl];

    // Use a non-empty placeholder so Auto Layout measures a real intrinsic height from the start.
    // The string is replaced with the real transition name in updateActiveView.
    NSTextField *nameLbl = [NSTextField labelWithString:@"Transition Name"];
    nameLbl.font          = [NSFont boldSystemFontOfSize:17];
    nameLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    nameLbl.alignment     = NSTextAlignmentLeft;
    nameLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [active addSubview:nameLbl];

    NSTextField *progLbl = [NSTextField labelWithString:@""];
    progLbl.textColor = [NSColor secondaryLabelColor];
    progLbl.font      = [NSFont systemFontOfSize:12];
    progLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [active addSubview:progLbl];

    // Preview button — full width
    NSButton *preview = [NSButton buttonWithTitle:@"▶  Preview"
                                           target:self action:@selector(previewTransition:)];
    preview.bezelStyle = NSBezelStyleRounded;
    preview.translatesAutoresizingMaskIntoConstraints = NO;
    [active addSubview:preview];

    // Prev / Next navigation (browse without voting)
    NSButton *prevBtn = [NSButton buttonWithTitle:@"◀  Prev"
                                           target:self action:@selector(browseTransition:)];
    prevBtn.tag        = -1;
    prevBtn.bezelStyle = NSBezelStyleRounded;
    prevBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [active addSubview:prevBtn];

    NSButton *nextBtn = [NSButton buttonWithTitle:@"Next  ▶"
                                           target:self action:@selector(browseTransition:)];
    nextBtn.tag        = +1;
    nextBtn.bezelStyle = NSBezelStyleRounded;
    nextBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [active addSubview:nextBtn];

    // Separator
    NSBox *sep = [[NSBox alloc] init];
    sep.boxType = NSBoxSeparator;
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    [active addSubview:sep];

    // Add / Reject vote buttons
    NSButton *addBtn = [NSButton buttonWithTitle:@"👍  Add to Audition"
                                          target:self action:@selector(addToAudition:)];
    addBtn.bezelStyle = NSBezelStyleRounded;
    addBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [active addSubview:addBtn];

    NSButton *rejectBtn = [NSButton buttonWithTitle:@"👎  Reject"
                                             target:self action:@selector(skipTransition:)];
    rejectBtn.bezelStyle = NSBezelStyleRounded;
    rejectBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [active addSubview:rejectBtn];

    // Cancel link
    NSButton *cancelBtn = [NSButton buttonWithTitle:@"Cancel Audition"
                                             target:self action:@selector(cancelAudition:)];
    cancelBtn.bezelStyle    = NSBezelStyleInline;
    cancelBtn.keyEquivalent = @"\033";
    cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [active addSubview:cancelBtn];

    NSButton *confirmBtn = [NSButton buttonWithTitle:@"Confirm Transition and Exit"
                                              target:self action:@selector(confirmAndExit:)];
    confirmBtn.bezelStyle = NSBezelStyleRounded;
    confirmBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [active addSubview:confirmBtn];

    NSButton *confirmFavBtn = [NSButton buttonWithTitle:@"Add to Favorites and Exit"
                                                 target:self action:@selector(confirmAndAddFavoritesAndExit:)];
    confirmFavBtn.bezelStyle = NSBezelStyleRounded;
    confirmFavBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [active addSubview:confirmFavBtn];

    CGFloat apad = 14, agap = 8;
    [NSLayoutConstraint activateConstraints:@[
        [active.widthAnchor  constraintEqualToConstant:320],
        [active.heightAnchor constraintEqualToConstant:360],

        [roundLbl.topAnchor     constraintEqualToAnchor:active.topAnchor constant:apad],
        [roundLbl.leadingAnchor constraintEqualToAnchor:active.leadingAnchor constant:apad],

        [nameLbl.topAnchor      constraintEqualToAnchor:roundLbl.bottomAnchor constant:2],
        [nameLbl.leadingAnchor  constraintEqualToAnchor:active.leadingAnchor constant:apad],
        [nameLbl.trailingAnchor constraintEqualToAnchor:active.trailingAnchor constant:-apad],

        [progLbl.topAnchor     constraintEqualToAnchor:nameLbl.bottomAnchor constant:2],
        [progLbl.leadingAnchor constraintEqualToAnchor:active.leadingAnchor constant:apad],

        [preview.topAnchor      constraintEqualToAnchor:progLbl.bottomAnchor constant:agap + 4],
        [preview.leadingAnchor  constraintEqualToAnchor:active.leadingAnchor constant:apad],
        [preview.trailingAnchor constraintEqualToAnchor:active.trailingAnchor constant:-apad],

        [prevBtn.topAnchor     constraintEqualToAnchor:preview.bottomAnchor constant:agap],
        [prevBtn.leadingAnchor constraintEqualToAnchor:active.leadingAnchor constant:apad],
        [prevBtn.widthAnchor   constraintEqualToConstant:120],

        [nextBtn.topAnchor      constraintEqualToAnchor:preview.bottomAnchor constant:agap],
        [nextBtn.trailingAnchor constraintEqualToAnchor:active.trailingAnchor constant:-apad],
        [nextBtn.widthAnchor    constraintEqualToConstant:120],

        [sep.topAnchor      constraintEqualToAnchor:prevBtn.bottomAnchor constant:agap],
        [sep.leadingAnchor  constraintEqualToAnchor:active.leadingAnchor constant:apad],
        [sep.trailingAnchor constraintEqualToAnchor:active.trailingAnchor constant:-apad],
        [sep.heightAnchor   constraintEqualToConstant:1],

        [addBtn.topAnchor     constraintEqualToAnchor:sep.bottomAnchor constant:agap],
        [addBtn.leadingAnchor constraintEqualToAnchor:active.leadingAnchor constant:apad],
        [addBtn.widthAnchor   constraintEqualToConstant:160],

        [rejectBtn.topAnchor      constraintEqualToAnchor:sep.bottomAnchor constant:agap],
        [rejectBtn.trailingAnchor constraintEqualToAnchor:active.trailingAnchor constant:-apad],
        [rejectBtn.widthAnchor    constraintEqualToConstant:100],

        [confirmBtn.topAnchor      constraintEqualToAnchor:addBtn.bottomAnchor constant:20],
        [confirmBtn.leadingAnchor  constraintEqualToAnchor:active.leadingAnchor constant:apad],
        [confirmBtn.trailingAnchor constraintEqualToAnchor:active.trailingAnchor constant:-apad],

        [confirmFavBtn.topAnchor      constraintEqualToAnchor:confirmBtn.bottomAnchor constant:agap],
        [confirmFavBtn.leadingAnchor  constraintEqualToAnchor:active.leadingAnchor constant:apad],
        [confirmFavBtn.trailingAnchor constraintEqualToAnchor:active.trailingAnchor constant:-apad],

        [cancelBtn.bottomAnchor   constraintEqualToAnchor:active.bottomAnchor constant:-apad],
        [cancelBtn.leadingAnchor  constraintEqualToAnchor:active.leadingAnchor constant:apad],
    ]];

    self.roundLabel         = roundLbl;
    self.nameLabel          = nameLbl;
    self.progressLabel      = progLbl;
    self.previewButton      = preview;
    self.prevButton         = prevBtn;
    self.nextButton         = nextBtn;
    self.addButton          = addBtn;
    self.skipButton         = rejectBtn;
    self.cancelButton       = cancelBtn;
    self.confirmButton      = confirmBtn;
    self.confirmFavButton   = confirmFavBtn;
    self.activeView         = active;

    // ============================  POPOVER  ==================================
    NSViewController *vc = [[NSViewController alloc] init];
    vc.view = idle;

    NSPopover *pop = [[NSPopover alloc] init];
    pop.contentViewController = vc;
    pop.behavior = NSPopoverBehaviorTransient;
    pop.delegate = self;
    self.popover = pop;
}

// ---------------------------------------------------------------------------
#pragma mark Show / hide
// ---------------------------------------------------------------------------

- (void)toggleFromButton:(NSButton *)button {
    self.toolbarButton = button;
    [self buildPopoverIfNeeded];

    if (self.popover.shown) {
        [self.popover close];
        return;
    }

    if (self.audition.phase == TAuPhaseActive) {
        [self showActiveView];
    } else {
        [self showIdleView];
        [self ensureTransitionsLoaded];
    }

    [self.popover showRelativeToRect:button.bounds
                              ofView:button
                       preferredEdge:NSRectEdgeMaxY];
}

- (void)showIdleView {
    self.popover.contentViewController.view = self.idleView;
    self.popover.contentSize = self.idleView.frame.size;
    [self updateIdleView];
}

- (void)showActiveView {
    self.addButton.hidden          = NO;
    self.skipButton.hidden         = NO;
    self.confirmButton.enabled     = YES;
    self.confirmFavButton.enabled  = YES;
    self.popover.contentViewController.view = self.activeView;
    self.popover.contentSize = self.activeView.frame.size;
    [self updateActiveView];
}

- (void)updateIdleView {
    BOOL isCustom = (self.modeControl.selectedSegment == 1);
    self.searchField.hidden = !isCustom;
    self.tableScroll.hidden = !isCustom;
    self.countLabel.hidden  =  isCustom;

    if (!isCustom) {
        NSUInteger n = self.allTransitions.count;
        self.countLabel.stringValue = n > 0
            ? [NSString stringWithFormat:@"%lu transitions available", (unsigned long)n]
            : @"Loading…";
    } else {
        [self.tableView reloadData];
    }

    BOOL isCustomOK = isCustom && sTAuCustomIDs.count > 0;
    BOOL isAllOK    = !isCustom && self.allTransitions.count > 0;
    self.startButton.enabled = !self.loading && (isCustomOK || isAllOK);
}

- (void)updateActiveView {
    TAuState *a = self.audition;
    if (!a.currentTransition) return;

    // positionInRound is 1-indexed: which transition we are currently reviewing this round.
    // originalCount is the count at the start of this round.
    self.roundLabel.stringValue = [NSString stringWithFormat:@"Round %ld  ·  %lu in this round",
                                   (long)a.roundNumber, (unsigned long)a.originalCount];

    self.nameLabel.stringValue = a.currentTransition[@"name"] ?: @"";

    self.progressLabel.stringValue = [NSString stringWithFormat:@"%ld of %lu  ·  %lu kept so far",
                                      (long)a.positionInRound,
                                      (unsigned long)a.originalCount,
                                      (unsigned long)a.keptSet.count];

    self.addButton.enabled     = YES;
    self.skipButton.enabled    = YES;
    self.previewButton.enabled = YES;
}

// ---------------------------------------------------------------------------
#pragma mark Loading
// ---------------------------------------------------------------------------

- (void)ensureTransitionsLoaded {
    if (self.allTransitions.count > 0) { [self updateIdleView]; return; }
    self.loading = YES;
    self.startButton.enabled    = NO;
    self.spinner.hidden         = NO;
    self.countLabel.hidden      = NO;
    self.countLabel.stringValue = @"Loading transitions…";
    [self.spinner startAnimation:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *all = TAu_loadAllTransitions();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.allTransitions      = all;
            self.filteredTransitions = all;
            self.loading = NO;
            [self.spinner stopAnimation:nil];
            self.spinner.hidden = YES;
            [self updateIdleView];
        });
    });
}

// ---------------------------------------------------------------------------
#pragma mark Mode / search
// ---------------------------------------------------------------------------

- (void)modeChanged:(NSSegmentedControl *)sender {
    (void)sender;
    BOOL isCustom = (self.modeControl.selectedSegment == 1);
    // 420 = full height with table; 210 = compact (title+preroll row+mode+count+start)
    self.popover.contentSize = isCustom ? NSMakeSize(320, 420) : NSMakeSize(320, 210);
    [self updateIdleView];
}

- (void)prerollChanged:(NSPopUpButton *)sender {
    NSString *title = sender.selectedItem.title; // e.g. "3s"
    sTAuPrerollSeconds = MAX(2.0, MIN(5.0, [[title stringByReplacingOccurrencesOfString:@"s" withString:@""] doubleValue]));
    TAu_saveSettings();
}

- (void)postrollChanged:(NSPopUpButton *)sender {
    NSString *title = sender.selectedItem.title;
    sTAuPostrollSeconds = MAX(2.0, MIN(5.0, [[title stringByReplacingOccurrencesOfString:@"s" withString:@""] doubleValue]));
    TAu_saveSettings();
}

- (void)controlTextDidChange:(NSNotification *)note {
    (void)note;
    NSString *query = [self.searchField.stringValue lowercaseString];
    self.filteredTransitions = query.length == 0 ? self.allTransitions :
        [self.allTransitions filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSDictionary *t, id _) {
                return [[t[@"name"] lowercaseString] containsString:query];
            }]];
    [self.tableView reloadData];
}

// ---------------------------------------------------------------------------
#pragma mark NSTableView  (custom set)
// ---------------------------------------------------------------------------

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { (void)tv; return (NSInteger)self.filteredTransitions.count; }

- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    (void)tv;
    if (row < 0 || row >= (NSInteger)self.filteredTransitions.count) return nil;
    NSDictionary *t = self.filteredTransitions[row];
    if ([col.identifier isEqualToString:@"check"])
        return @([sTAuCustomIDs containsObject:t[@"effectID"]]);
    return t[@"name"];
}

- (void)tableView:(NSTableView *)tv setObjectValue:(id)val
   forTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    (void)tv;
    if (![col.identifier isEqualToString:@"check"]) return;
    if (row < 0 || row >= (NSInteger)self.filteredTransitions.count) return;
    NSString *eid = self.filteredTransitions[row][@"effectID"];
    if ([val boolValue]) [sTAuCustomIDs addObject:eid]; else [sTAuCustomIDs removeObject:eid];
    TAu_saveCustomSet();
    self.startButton.enabled = sTAuCustomIDs.count > 0;
}

// ---------------------------------------------------------------------------
#pragma mark Start
// ---------------------------------------------------------------------------

- (void)startAudition:(id)sender {
    (void)sender;
    BOOL isCustom = (self.modeControl.selectedSegment == 1);
    NSArray<NSDictionary *> *set;
    if (!isCustom) {
        set = self.allTransitions;
    } else {
        NSMutableArray *custom = [NSMutableArray array];
        for (NSDictionary *t in self.allTransitions)
            if ([sTAuCustomIDs containsObject:t[@"effectID"]]) [custom addObject:t];
        set = custom;
    }
    if (set.count == 0) return;

    self.startButton.enabled = NO;
    self.startButton.title   = @"Finding edit point…";

    NSArray<NSDictionary *> *captured = set;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        double editTime = TAu_findNearestEditPoint();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.startButton.title = @"Start Audition";
            if (editTime < 0) {
                NSAlert *a = [[NSAlert alloc] init];
                a.messageText     = @"No transition found";
                a.informativeText = @"Scrub the playhead to (or near) the transition you want to audition, then click Start Audition. The final transition in a sequence is excluded — there must be at least 2 seconds of footage after it.";
                [a addButtonWithTitle:@"OK"];
                [a runModal];
                self.startButton.enabled = YES;
                return;
            }
            TAuState *au = self.audition;
            au.editPointTime   = editTime;
            au.originalCount   = captured.count;
            au.roundNumber     = 1;
            au.positionInRound = 1;
            au.currentIndex    = 0;
            au.pendingQueue    = [captured mutableCopy];
            au.keptSet         = [NSMutableArray array];
            au.currentTransition = au.pendingQueue.firstObject;
            au.phase           = TAuPhaseActive;

            // Delete any pre-existing transition at the edit point so addTransition:
            // can succeed (addTransition: only inserts — it won't replace).
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                au.hadOriginalTransition = TAu_deleteExistingTransitionAt(editTime);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self applyNextTransitionCompletion:^{ [self showActiveView]; }];
                });
            });
        });
    });
}

// ---------------------------------------------------------------------------
#pragma mark Tournament bracket
// ---------------------------------------------------------------------------

// Dequeues pendingQueue[0], applies it, starts the preview loop, calls completion on main thread.
- (void)applyNextTransitionCompletion:(dispatch_block_t)completion {
    TAuState *au = self.audition;
    NSDictionary *next = au.pendingQueue.firstObject;
    if (!next) { if (completion) completion(); return; }
    au.currentTransition = next;
    double editTime  = au.editPointTime;
    double preroll   = MAX(0.0, editTime - sTAuPrerollSeconds);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Seek slightly before the edit point then snap with nextEdit so the
        // playhead lands on the exact CMTime frame boundary.  Seeking directly
        // to the floating-point editTime loses sub-millisecond precision which
        // causes addTransition: to silently fail to find the edit point.
        TAu_seekToTime(MAX(0.0, editTime - MIN(sTAuPrerollSeconds, 0.5)));
        sTAuAPI->callMethod(@{@"method": @"timeline.action",
                               @"params": @{@"action": @"nextEdit"}});
        TAu_applyTransition(next);
        // Immediately jump to preroll and start playing
        TAu_seekToTime(preroll);
        TAu_ensurePlaying();
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateActiveView];
            // Kick off the repeating loop timer
            [self stopPreviewLoop];
            self.loopActive = YES;
            self.loopTimer = [NSTimer scheduledTimerWithTimeInterval:TAu_loopInterval()
                                                              target:self
                                                            selector:@selector(_loopTimerFired:)
                                                            userInfo:nil
                                                             repeats:YES];
            if (completion) completion();
        });
    });
}

// Called after user rates the current transition (add or skip).
// Removes current from pendingQueue, then either advances or ends the round.
// Called after a vote (add/reject) has removed the item from pendingQueue
// and undo has been executed.
- (void)advanceAfterUndo {
    TAuState *au = self.audition;
    au.positionInRound++;

    if (au.pendingQueue.count > 0) {
        // Apply the item now at currentIndex (clamped by caller)
        au.currentTransition = au.pendingQueue[au.currentIndex];
        [self applyNextTransitionCompletion:^{ [self enableRatingButtons]; }];
    } else {
        [self endRound];
    }
}

- (void)endRound {
    TAuState *au = self.audition;
    NSUInteger kept = au.keptSet.count;

    if (kept == 0) {
        // Nobody was liked — shouldn't happen in practice, but handle gracefully
        sTAuAPI->log(@"[TAu] All transitions skipped — ending audition with no result.");
        au.phase = TAuPhaseIdle;
        [self.popover close];
        [self updateToolbarButtonTint];
        return;
    }

    if (kept == 1) {
        // We have a winner — apply it and show the final selection UI.
        NSDictionary *winner = au.keptSet.firstObject;
        au.currentTransition = winner;
        [self disableRatingButtons];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            TAu_ensurePaused();
            TAu_seekToTime(MAX(0.0, au.editPointTime - MIN(sTAuPrerollSeconds, 0.5)));
            sTAuAPI->callMethod(@{@"method": @"timeline.action",
                                   @"params": @{@"action": @"nextEdit"}});
            TAu_applyTransition(winner);
            TAu_seekToTime(MAX(0.0, au.editPointTime - sTAuPrerollSeconds));
            TAu_ensurePlaying();
            dispatch_async(dispatch_get_main_queue(), ^{
                sTAuAPI->log(@"[TAu] Winner: %@", winner[@"name"]);
                self.roundLabel.stringValue    = @"Winner";
                self.nameLabel.stringValue     = winner[@"name"] ?: @"";
                self.progressLabel.stringValue = @"";
                self.addButton.hidden          = YES;
                self.skipButton.hidden         = YES;
                self.confirmButton.enabled     = YES;
                self.confirmFavButton.enabled  = YES;
                // Restart preview loop so user can watch the winning transition loop
                [self stopPreviewLoop];
                self.loopActive = YES;
                self.loopTimer = [NSTimer scheduledTimerWithTimeInterval:TAu_loopInterval()
                                                                  target:self
                                                                selector:@selector(_loopTimerFired:)
                                                                userInfo:nil
                                                                 repeats:YES];
            });
        });
        return;
    }

    // Start a new round with the survivors
    au.roundNumber++;
    au.pendingQueue    = [au.keptSet mutableCopy];
    au.keptSet         = [NSMutableArray array];
    au.originalCount   = au.pendingQueue.count;
    au.positionInRound = 1;
    au.currentIndex    = 0;
    au.currentTransition = au.pendingQueue.firstObject;

    [self disableRatingButtons];
    self.roundLabel.stringValue = [NSString stringWithFormat:@"Round %ld  ·  %lu surviving",
        (long)au.roundNumber, (unsigned long)au.pendingQueue.count];
    [self applyNextTransitionCompletion:^{ [self enableRatingButtons]; }];
}

// ---------------------------------------------------------------------------
#pragma mark Rating actions
// ---------------------------------------------------------------------------

// Browse without voting: cycle prev/next through the pending queue.
- (void)browseTransition:(NSButton *)sender {
    TAuState *au = self.audition;
    if (au.phase != TAuPhaseActive || !au.currentTransition) return;
    NSInteger delta = sender.tag; // -1 = prev, +1 = next
    NSInteger count = (NSInteger)au.pendingQueue.count;
    if (count <= 1) return; // nothing to browse
    au.currentIndex = ((au.currentIndex + delta) % count + count) % count;
    au.currentTransition = au.pendingQueue[au.currentIndex];
    [self stopPreviewLoop];
    [self disableRatingButtons];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TAu_ensurePaused();
        [NSThread sleepForTimeInterval:0.15];
        TAu_undo(); // remove current transition
        [NSThread sleepForTimeInterval:0.2];
        // Snap to exact edit point and apply the browsed transition
        TAu_seekToTime(MAX(0.0, au.editPointTime - MIN(sTAuPrerollSeconds, 0.5)));
        sTAuAPI->callMethod(@{@"method": @"timeline.action",
                               @"params": @{@"action": @"nextEdit"}});
        TAu_applyTransition(au.currentTransition);
        TAu_seekToTime(MAX(0.0, au.editPointTime - sTAuPrerollSeconds));
        TAu_ensurePlaying();
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateActiveView];
            [self stopPreviewLoop];
            self.loopActive = YES;
            self.loopTimer = [NSTimer scheduledTimerWithTimeInterval:TAu_loopInterval()
                                                              target:self
                                                            selector:@selector(_loopTimerFired:)
                                                            userInfo:nil
                                                             repeats:YES];
            [self enableRatingButtons];
        });
    });
}

- (void)addToAudition:(id)sender {
    (void)sender;
    TAuState *au = self.audition;
    if (au.phase != TAuPhaseActive || !au.currentTransition) return;
    [au.keptSet addObject:au.currentTransition];
    sTAuAPI->log(@"[TAu] Add '%@'  kept=%lu", au.currentTransition[@"name"], (unsigned long)au.keptSet.count);
    [au.pendingQueue removeObjectAtIndex:au.currentIndex];
    // Keep index in bounds after removal
    if (au.pendingQueue.count > 0)
        au.currentIndex = au.currentIndex % (NSInteger)au.pendingQueue.count;
    [self stopPreviewLoop];
    [self disableRatingButtons];
    [self _doUndoThenVoteAdvance];
}

- (void)skipTransition:(id)sender {
    (void)sender;
    TAuState *au = self.audition;
    if (au.phase != TAuPhaseActive || !au.currentTransition) return;
    sTAuAPI->log(@"[TAu] Reject '%@'", au.currentTransition[@"name"]);
    [au.pendingQueue removeObjectAtIndex:au.currentIndex];
    if (au.pendingQueue.count > 0)
        au.currentIndex = au.currentIndex % (NSInteger)au.pendingQueue.count;
    [self stopPreviewLoop];
    [self disableRatingButtons];
    [self _doUndoThenVoteAdvance];
}

- (void)_doUndoThenVoteAdvance {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TAu_ensurePaused();
        [NSThread sleepForTimeInterval:0.2];
        TAu_undo();
        [NSThread sleepForTimeInterval:0.2];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self advanceAfterUndo];
        });
    });
}

- (void)confirmAndExit:(id)sender {
    (void)sender;
    TAuState *au = self.audition;
    if (au.phase != TAuPhaseActive) return;
    [self stopPreviewLoop];
    [self disableRatingButtons];
    self.confirmButton.enabled    = NO;
    self.confirmFavButton.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TAu_ensurePaused();
        dispatch_async(dispatch_get_main_queue(), ^{
            au.phase = TAuPhaseIdle;
            [self.popover close];
            [self updateToolbarButtonTint];
        });
    });
}

- (void)confirmAndAddFavoritesAndExit:(id)sender {
    (void)sender;
    TAuState *au = self.audition;
    if (au.phase != TAuPhaseActive || !au.currentTransition) return;
    NSString *effectID = au.currentTransition[@"effectID"];
    if (effectID) {
        Class ffEffect = NSClassFromString(@"FFEffect");
        if (ffEffect) {
            @try {
                SEL getSel = NSSelectorFromString(@"favoriteEffectIDs:video:filterUnregisteredEffects:");
                NSArray *current = ((NSArray*(*)(id,SEL,BOOL,BOOL,BOOL))objc_msgSend)(
                    (id)ffEffect, getSel, NO, YES, NO);
                if (![current containsObject:effectID]) {
                    NSMutableArray *updated = current ? [current mutableCopy] : [NSMutableArray array];
                    [updated addObject:effectID];
                    SEL setSel = NSSelectorFromString(@"setFavoriteEffectIDs:video:");
                    ((void(*)(id,SEL,id,BOOL))objc_msgSend)((id)ffEffect, setSel, updated, YES);
                    sTAuAPI->log(@"[TAu] Added '%@' (%@) to FCP Favorites",
                                 au.currentTransition[@"name"], effectID);
                }
            } @catch (NSException *e) {
                sTAuAPI->log(@"[TAu] addToFavorites exception: %@", e.reason);
            }
        }
        [sTAuCustomIDs addObject:effectID];
        TAu_saveCustomSet();
    }
    [self confirmAndExit:nil];
}

- (void)cancelAudition:(id)sender {
    (void)sender;
    TAuState *au = self.audition;
    [self stopPreviewLoop];
    if (au.phase != TAuPhaseActive) { [self.popover close]; return; }
    BOOL hadOriginal = au.hadOriginalTransition;
    self.cancelingAudition = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TAu_ensurePaused();
        [NSThread sleepForTimeInterval:0.15];
        TAu_undo(); // undo the current test transition
        if (hadOriginal) {
            [NSThread sleepForTimeInterval:0.1];
            TAu_undo(); // undo the original deletion → restores original transition
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            au.phase = TAuPhaseIdle;
            self.cancelingAudition = NO;
            [self.popover close];
            [self updateToolbarButtonTint];
        });
    });
}

// ---------------------------------------------------------------------------
#pragma mark Preview loop
// ---------------------------------------------------------------------------

// Loop interval is now computed dynamically from sTAuPrerollSeconds + sTAuPostrollSeconds.

- (void)previewTransition:(id)sender {
    (void)sender;
    if (self.audition.phase != TAuPhaseActive) return;
    [self startPreviewLoop];
}

- (void)startPreviewLoop {
    [self stopPreviewLoop]; // sets loopActive=NO, then we set YES below
    self.loopActive = YES;
    double preroll = MAX(0.0, self.audition.editPointTime - sTAuPrerollSeconds);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TAu_seekToTime(preroll);
        TAu_ensurePlaying();
        dispatch_async(dispatch_get_main_queue(), ^{
            // Repeating timer: on each fire, seek back to preroll while FCP keeps playing.
            self.loopTimer = [NSTimer scheduledTimerWithTimeInterval:TAu_loopInterval()
                                                              target:self
                                                            selector:@selector(_loopTimerFired:)
                                                            userInfo:nil
                                                             repeats:YES];
        });
    });
}

- (void)_loopTimerFired:(NSTimer *)timer {
    (void)timer;
    if (!self.loopActive || self.audition.phase != TAuPhaseActive) { return; }
    double preroll = MAX(0.0, self.audition.editPointTime - sTAuPrerollSeconds);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (!self.loopActive) return; // bail if stopped while we were queued
        TAu_seekToTime(preroll);
        if (!self.loopActive) return; // bail if stopped while seeking
        TAu_ensurePlaying();
    });
}

- (void)stopPreviewLoop {
    // Set loopActive=NO FIRST so any in-flight background blocks exit immediately
    // before trying to sync-dispatch back to main (which could interfere with an
    // ongoing transitions.apply / waitForTransitionInsertion spin).
    self.loopActive = NO;
    [self.loopTimer invalidate];
    self.loopTimer = nil;
}

// ---------------------------------------------------------------------------
#pragma mark Helpers
// ---------------------------------------------------------------------------

- (void)disableRatingButtons {
    self.addButton.enabled        = NO;
    self.skipButton.enabled       = NO;
    self.previewButton.enabled    = NO;
    self.prevButton.enabled       = NO;
    self.nextButton.enabled       = NO;
    self.confirmButton.enabled    = NO;
    self.confirmFavButton.enabled = NO;
}

- (void)enableRatingButtons {
    NSInteger queueCount = (NSInteger)self.audition.pendingQueue.count;
    self.addButton.enabled        = YES;
    self.skipButton.enabled       = YES;
    self.previewButton.enabled    = YES;
    self.prevButton.enabled       = (queueCount > 1);
    self.nextButton.enabled       = (queueCount > 1);
    self.confirmButton.enabled    = YES;
    self.confirmFavButton.enabled = YES;
    [self updateActiveView];
}

- (void)updateToolbarButtonTint {
    if (!self.toolbarButton) return;
    self.toolbarButton.contentTintColor =
        (self.audition.phase == TAuPhaseActive)
        ? [NSColor controlAccentColor]
        : [NSColor controlTextColor];
}

// NSPopoverDelegate — clicking outside the popover keeps whatever transition is applied
- (void)popoverWillClose:(NSNotification *)note {
    (void)note;
    if (self.cancelingAudition) return; // cancel handles its own cleanup
    TAuState *au = self.audition;
    if (au.phase == TAuPhaseActive) {
        // User dismissed by clicking away — stop the preview loop but keep the transition
        [self stopPreviewLoop];
        au.phase = TAuPhaseIdle;
        [self updateToolbarButtonTint];
    }
}

@end

// ---------------------------------------------------------------------------
#pragma mark - Button target
// ---------------------------------------------------------------------------

@interface TAuButtonTarget : NSObject
+ (instancetype)shared;
- (void)buttonClicked:(NSButton *)sender;
@end

@implementation TAuButtonTarget
+ (instancetype)shared {
    static TAuButtonTarget *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}
- (void)buttonClicked:(NSButton *)sender {
    [[TAuPopoverController shared] toggleFromButton:sender];
}
@end

// ---------------------------------------------------------------------------
#pragma mark - Timeline bar injection
// ---------------------------------------------------------------------------

static NSImage *TAu_makeIcon(void) {
    NSImage *img = [NSImage imageWithSystemSymbolName:@"film.stack"
                             accessibilityDescription:@"Transition Auditions"];
    return img ? [img imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:19 weight:NSFontWeightMedium]] : nil;
}

static NSView *TAu_findTimelineBarView(void) {
    @try {
        id delegate = [[NSApplication sharedApplication] delegate];
        if (!delegate) return nil;
        SEL ecSel = NSSelectorFromString(@"activeEditorContainer");
        if (![delegate respondsToSelector:ecSel]) return nil;
        id ec = ((id(*)(id,SEL))objc_msgSend)(delegate, ecSel);
        if (!ec) return nil;
        SEL tmSel = NSSelectorFromString(@"timelineModule");
        if (![ec respondsToSelector:tmSel]) return nil;
        id tm = ((id(*)(id,SEL))objc_msgSend)(ec, tmSel);
        if (!tm) return nil;
        NSView *v = [tm performSelector:@selector(view)];
        if (!v) return nil;
        for (int i = 0; i < 4; i++) { v = v.superview; if (!v) return nil; }
        Class capClass = NSClassFromString(@"LKContainerItemCapView");
        for (NSView *sv in v.subviews) {
            if (capClass ? [sv isKindOfClass:capClass]
                         : [NSStringFromClass([sv class]) containsString:@"CapView"])
                return sv.subviews.firstObject;
        }
        return nil;
    } @catch (__unused NSException *) { return nil; }
}

static void TAu_addButtonToTimelineBar(void) {
    @try {
        NSView *bar = TAu_findTimelineBarView();
        if (!bar) return;
        for (NSView *sv in bar.subviews)
            if ([sv.identifier isEqualToString:kTAuButtonID]) return;

        NSView *anchor = nil;
        CGFloat gap    = 2.0;
        for (NSView *sv in bar.subviews)
            if ([sv.identifier isEqualToString:kSFPBackwardID]) { anchor = sv; break; }
        if (!anchor) {
            Class pc = NSClassFromString(@"LKPaneCapSegmentedControl");
            for (NSView *sv in bar.subviews)
                if (pc && [sv isKindOfClass:pc]) { anchor = sv; gap = 6.0; break; }
        }
        if (!anchor) { sTAuAPI->log(@"[TAu] Anchor not found."); return; }

        NSButton *btn = [[NSButton alloc] init];
        [btn setButtonType:NSButtonTypeMomentaryPushIn];
        btn.bezelStyle    = NSBezelStyleTexturedRounded;
        btn.bordered      = YES;
        btn.image         = TAu_makeIcon();
        btn.imagePosition = NSImageOnly;
        btn.target        = [TAuButtonTarget shared];
        btn.action        = @selector(buttonClicked:);
        btn.identifier    = kTAuButtonID;
        btn.toolTip       = @"Transition Auditions — cycle through transitions at the nearest edit point";
        btn.translatesAutoresizingMaskIntoConstraints = NO;

        [bar addSubview:btn];
        [NSLayoutConstraint activateConstraints:@[
            [btn.trailingAnchor constraintEqualToAnchor:anchor.leadingAnchor constant:-gap],
            [btn.centerYAnchor  constraintEqualToAnchor:anchor.centerYAnchor],
            [btn.widthAnchor    constraintEqualToConstant:40.0],
            [btn.heightAnchor   constraintEqualToAnchor:anchor.heightAnchor],
        ]];
        sTAuAPI->log(@"[TAu] Button installed.");
    } @catch (NSException *e) {
        sTAuAPI->log(@"[TAu] Exception: %@", e.reason);
    }
}

static void TAu_tryInstall(int attempt);
static void TAu_tryInstall(int attempt) {
    if (attempt >= 40) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSView *bar = TAu_findTimelineBarView();
        if (bar && bar.subviews.count > 0) TAu_addButtonToTimelineBar();
        else TAu_tryInstall(attempt + 1);
    });
}

static void TAu_startInstallation(void) {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowDidBecomeMainNotification object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification * __unused n) {
            NSView *bar = TAu_findTimelineBarView();
            if (bar && bar.subviews.count > 0) TAu_addButtonToTimelineBar();
        }];
    TAu_tryInstall(0);
}

// ---------------------------------------------------------------------------
#pragma mark - Plugin entry point
// ---------------------------------------------------------------------------

__attribute__((visibility("default")))
void SpliceKitPlugin_init(SpliceKitPluginAPI *api) {
    sTAuAPIStorage = *api;
    sTAuAPI        = &sTAuAPIStorage;

    if (api->dataPath)
        sTAuDataPath = [NSString stringWithUTF8String:api->dataPath];

    sTAuAPI->log(@"[TAu] Loading.");
    TAu_loadSettings();
    TAu_loadCustomSet();

    api->executeOnMainThreadAsync(^{
        TAu_startInstallation();

        // Global Escape key monitor: cancel audition regardless of popover state.
        // Key code 53 = Escape. Return nil to consume the event (suppress FCP's own handler).
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                              handler:^NSEvent *(NSEvent *event) {
            if (event.keyCode == 53) {
                TAuPopoverController *ctrl = [TAuPopoverController shared];
                if (ctrl.audition.phase == TAuPhaseActive) {
                    [ctrl cancelAudition:nil];
                    return nil; // consume — don't let FCP also handle Escape
                }
            }
            return event;
        }];
    });
    api->log(@"[TAu] Loaded.");
}
