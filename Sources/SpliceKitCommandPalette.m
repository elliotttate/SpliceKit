//
//  SpliceKitCommandPalette.m
//  VS Code-style command palette for FCP — Cmd+Shift+P opens it.
//
//  Fuzzy-searches across 100+ registered commands (editing, playback, color,
//  speed, markers, effects, FlexMusic, montage, etc). Type a command name to
//  filter, or type a full sentence and press Tab to ask Apple Intelligence
//  to figure out which commands to run.
//
//  The palette floats above FCP as a vibrancy-backed panel with a search field
//  and a table view. It supports favorites (right-click to star), keyboard
//  navigation, and a browse mode when the search field is empty.
//

#import "SpliceKitCommandPalette.h"
#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// These are defined in SpliceKitServer.m — we call them directly to avoid
// going through the TCP socket when executing commands from within the process.
extern NSDictionary *SpliceKit_handleTimelineAction(NSDictionary *params);
extern NSDictionary *SpliceKit_handlePlayback(NSDictionary *params);

#pragma mark - SpliceKitCommand

@implementation SpliceKitCommand
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@/%@>", self.name, self.type, self.action];
}
@end

#pragma mark - Fuzzy Search
//
// Simple fuzzy matcher — walks through the query and target strings in lockstep,
// looking for a subsequence match (every character in the query appears in the
// target in order, but not necessarily adjacent). Scores higher for:
//   - Consecutive matching characters (the "bl" in "blade" beats "b...l...a")
//   - Matches at the start of a word (capital letters, after spaces)
//   - Shorter target strings (exact matches rank above partial ones)
//
// Returns 0 if not all query characters were found.
//

static CGFloat FCPFuzzyScore(NSString *query, NSString *target) {
    if (query.length == 0) return 1.0;
    NSString *q = [query lowercaseString];
    NSString *t = [target lowercaseString];

    NSUInteger qi = 0, ti = 0;
    CGFloat score = 0;
    CGFloat consecutiveBonus = 0;
    BOOL lastMatched = NO;

    while (qi < q.length && ti < t.length) {
        unichar qc = [q characterAtIndex:qi];
        unichar tc = [t characterAtIndex:ti];
        if (qc == tc) {
            score += 1.0;
            if (lastMatched) {
                consecutiveBonus += 0.5;
            }
            // Word-boundary matches are worth more — "cb" matching "Color Board" should score high
            if (ti == 0 || [t characterAtIndex:ti - 1] == ' ' ||
                ([t characterAtIndex:ti - 1] >= 'a' && tc >= 'A' && tc <= 'Z')) {
                score += 0.3;
            }
            lastMatched = YES;
            qi++;
        } else {
            lastMatched = NO;
        }
        ti++;
    }

    if (qi < q.length) return 0;

    score += consecutiveBonus;
    CGFloat normalized = score / (CGFloat)q.length;
    CGFloat lengthPenalty = 1.0 - ((CGFloat)(t.length - q.length) / (CGFloat)(t.length + 10));
    return normalized * lengthPenalty;
}

#pragma mark - Search Field
//
// Custom text field that intercepts arrow keys and forwards them to the
// results table. Without this, pressing Up/Down while typing would move
// the text cursor instead of navigating the command list.
//

@interface SpliceKitCommandSearchField : NSTextField
@property (nonatomic, weak) NSTableView *targetTableView;
@end

@implementation SpliceKitCommandSearchField

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    // Forward up/down arrows to the table view (skip separator rows)
    if (event.type == NSEventTypeKeyDown) {
        unsigned short keyCode = event.keyCode;
        if (keyCode == 126 || keyCode == 125) { // Up or Down
            SpliceKitCommandPalette *palette = [SpliceKitCommandPalette sharedPalette];
            NSInteger row = self.targetTableView.selectedRow;
            NSInteger maxRow = self.targetTableView.numberOfRows - 1;
            if (keyCode == 126 && row > 0) { // Up
                NSInteger newRow = row - 1;
                SpliceKitCommand *cmd = [palette commandForDisplayRow:newRow];
                if (cmd && cmd.isSeparatorRow && newRow > 0) newRow--;
                [self.targetTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:newRow]
                                  byExtendingSelection:NO];
                [self.targetTableView scrollRowToVisible:newRow];
            } else if (keyCode == 125 && row < maxRow) { // Down
                NSInteger newRow = row + 1;
                SpliceKitCommand *cmd = [palette commandForDisplayRow:newRow];
                if (cmd && cmd.isSeparatorRow && newRow < maxRow) newRow++;
                [self.targetTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:newRow]
                                  byExtendingSelection:NO];
                [self.targetTableView scrollRowToVisible:newRow];
            }
            return YES;
        }
    }
    return [super performKeyEquivalent:event];
}

@end

#pragma mark - Command Row View
// Each row shows: [star] Command Name  [category]
//                        description    [shortcut]

@interface SpliceKitCommandRowView : NSTableCellView
@property (nonatomic, strong) NSTextField *starLabel;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *detailLabel;
@property (nonatomic, strong) NSTextField *categoryLabel;
@property (nonatomic, strong) NSTextField *shortcutLabel;
@end

@implementation SpliceKitCommandRowView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Star indicator for favorites
        _starLabel = [NSTextField labelWithString:@""];
        _starLabel.font = [NSFont systemFontOfSize:12];
        _starLabel.textColor = [NSColor systemYellowColor];
        _starLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_starLabel setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

        // Command name
        _nameLabel = [NSTextField labelWithString:@""];
        _nameLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        _nameLabel.textColor = [NSColor labelColor];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;

        // Detail / description
        _detailLabel = [NSTextField labelWithString:@""];
        _detailLabel.font = [NSFont systemFontOfSize:11];
        _detailLabel.textColor = [NSColor secondaryLabelColor];
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;

        // Category badge
        _categoryLabel = [NSTextField labelWithString:@""];
        _categoryLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
        _categoryLabel.textColor = [NSColor tertiaryLabelColor];
        _categoryLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _categoryLabel.alignment = NSTextAlignmentRight;

        // Shortcut hint
        _shortcutLabel = [NSTextField labelWithString:@""];
        _shortcutLabel.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
        _shortcutLabel.textColor = [NSColor tertiaryLabelColor];
        _shortcutLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _shortcutLabel.alignment = NSTextAlignmentRight;

        [self addSubview:_starLabel];
        [self addSubview:_nameLabel];
        [self addSubview:_detailLabel];
        [self addSubview:_categoryLabel];
        [self addSubview:_shortcutLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_starLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [_starLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_starLabel.widthAnchor constraintEqualToConstant:14],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_starLabel.trailingAnchor constant:2],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_categoryLabel.leadingAnchor constant:-8],

            [_detailLabel.leadingAnchor constraintEqualToAnchor:_starLabel.trailingAnchor constant:2],
            [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:1],
            [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_shortcutLabel.leadingAnchor constant:-8],

            [_categoryLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [_categoryLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
            [_categoryLabel.widthAnchor constraintLessThanOrEqualToConstant:100],

            [_shortcutLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [_shortcutLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
            [_shortcutLabel.widthAnchor constraintLessThanOrEqualToConstant:100],
        ]];
    }
    return self;
}

- (void)configureWithCommand:(SpliceKitCommand *)cmd isFavorited:(BOOL)favorited {
    self.nameLabel.stringValue = cmd.name ?: @"";
    self.detailLabel.stringValue = cmd.detail ?: @"";
    self.categoryLabel.stringValue = cmd.categoryName ?: @"";
    self.shortcutLabel.stringValue = cmd.shortcut ?: @"";
    self.starLabel.stringValue = favorited ? @"\u2605" : @"";
}

@end

#pragma mark - AI Result Row

@interface FCPAIResultRowView : NSTableCellView
@property (nonatomic, strong) NSTextField *label;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@end

@implementation FCPAIResultRowView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 16, 16)];
        _spinner.style = NSProgressIndicatorStyleSpinning;
        _spinner.controlSize = NSControlSizeSmall;
        _spinner.translatesAutoresizingMaskIntoConstraints = NO;
        [_spinner startAnimation:nil];

        _label = [NSTextField labelWithString:@"Asking Apple Intelligence..."];
        _label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        _label.textColor = [NSColor controlAccentColor];
        _label.translatesAutoresizingMaskIntoConstraints = NO;

        [self addSubview:_spinner];
        [self addSubview:_label];

        [NSLayoutConstraint activateConstraints:@[
            [_spinner.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [_spinner.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_label.leadingAnchor constraintEqualToAnchor:_spinner.trailingAnchor constant:8],
            [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

@end

#pragma mark - Separator Row View

@interface FCPSeparatorRowView : NSTableCellView
@end

@implementation FCPSeparatorRowView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        NSBox *line = [[NSBox alloc] initWithFrame:NSZeroRect];
        line.boxType = NSBoxSeparator;
        line.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:line];
        [NSLayoutConstraint activateConstraints:@[
            [line.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [line.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [line.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}
@end

#pragma mark - SpliceKitCommandPalette

static NSString * const kCommandRowID = @"SpliceKitCommandRow";
static NSString * const kAIRowID = @"FCPAIRow";

@interface SpliceKitCommandPalette () <NSTableViewDelegate, NSTableViewDataSource,
                                  NSTextFieldDelegate, NSWindowDelegate, NSMenuDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSTextField *searchField;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSVisualEffectView *backgroundView;
@property (nonatomic, strong) NSTextField *statusLabel;

@property (nonatomic, strong) NSArray<SpliceKitCommand *> *allCommands;
@property (nonatomic, strong) NSArray<SpliceKitCommand *> *masterCommands; // original full list
@property (nonatomic, strong) NSArray<SpliceKitCommand *> *filteredCommands;
@property (nonatomic, assign) BOOL aiLoading;
@property (nonatomic, strong) NSString *aiQuery;
@property (nonatomic, strong) NSString *aiCompletedQuery; // query that already has results
@property (nonatomic, strong) NSArray<NSDictionary *> *aiResults;
@property (nonatomic, strong) NSString *aiError;
@property (nonatomic, assign) BOOL inBrowseMode;
@property (nonatomic, strong) NSTimer *aiDebounceTimer;

@property (nonatomic, strong) id localEventMonitor;

// Favorites
@property (nonatomic, strong) NSMutableSet<NSString *> *favoriteKeys; // "type::action" for O(1) lookup
@property (nonatomic, strong) NSArray<SpliceKitCommand *> *rawBrowseCommands; // pre-injection list
@end

static NSString * const kSpliceKitFavoritesKey = @"SpliceKitCommandPaletteFavorites";
static NSString * const kSeparatorRowID = @"FCPSeparatorRow";

@implementation SpliceKitCommandPalette

+ (instancetype)sharedPalette {
    static SpliceKitCommandPalette *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self registerCommands];
        _filteredCommands = _allCommands;
        [self loadFavorites];
    }
    return self;
}

#pragma mark - Command Registry

- (void)registerCommands {
    NSMutableArray<SpliceKitCommand *> *cmds = [NSMutableArray array];

    // Helper to create commands
    void (^add)(NSString *, NSString *, NSString *, SpliceKitCommandCategory, NSString *, NSString *, NSString *, NSArray *) =
        ^(NSString *name, NSString *action, NSString *type, SpliceKitCommandCategory cat,
          NSString *catName, NSString *shortcut, NSString *detail, NSArray *keywords) {
        SpliceKitCommand *cmd = [[SpliceKitCommand alloc] init];
        cmd.name = name;
        cmd.action = action;
        cmd.type = type;
        cmd.category = cat;
        cmd.categoryName = catName;
        cmd.shortcut = shortcut ?: @"";
        cmd.detail = detail ?: @"";
        cmd.keywords = keywords ?: @[];
        [cmds addObject:cmd];
    };

    // --- Editing ---
    add(@"Blade", @"blade", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Cmd+B", @"Split clip at playhead", @[@"cut", @"split", @"razor"]);
    add(@"Blade All", @"bladeAll", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Split all clips at playhead", @[@"cut all", @"split all"]);
    add(@"Delete", @"delete", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Delete", @"Remove selected clip (ripple)", @[@"remove", @"ripple delete"]);
    add(@"Cut", @"cut", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Cmd+X", @"Cut selected to clipboard", @[]);
    add(@"Copy", @"copy", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Cmd+C", @"Copy selected to clipboard", @[]);
    add(@"Paste", @"paste", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Cmd+V", @"Paste from clipboard", @[]);
    add(@"Undo", @"undo", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Cmd+Z", @"Undo last action", @[@"revert"]);
    add(@"Redo", @"redo", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Cmd+Shift+Z", @"Redo last undone action", @[]);
    add(@"Select All", @"selectAll", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Cmd+A", @"Select all clips", @[]);
    add(@"Deselect All", @"deselectAll", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Clear selection", @[@"unselect"]);
    add(@"Select Clip at Playhead", @"selectClipAtPlayhead", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Select the clip under playhead", @[@"select current"]);
    add(@"Select to Playhead", @"selectToPlayhead", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Extend selection to playhead", @[]);
    add(@"Trim to Playhead", @"trimToPlayhead", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Opt+]", @"Trim clip end to playhead position", @[@"shorten"]);
    add(@"Extend Edit to Playhead", @"extendEditToPlayhead", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Extend edit point to playhead", @[]);
    add(@"Insert Gap", @"insertGap", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Insert gap at playhead", @[@"space", @"blank"]);
    add(@"Insert Placeholder", @"insertPlaceholder", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Insert placeholder storyline", @[]);
    add(@"Solo", @"solo", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Solo selected clips", @[@"isolate"]);
    add(@"Disable", @"disable", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"V", @"Disable/enable selected clips", @[@"mute", @"toggle"]);
    add(@"Create Compound Clip", @"createCompoundClip", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Nest selected clips into compound", @[@"nest", @"group"]);

    // --- Navigation ---
    add(@"Next Edit Point", @"nextEdit", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"Down", @"Move to next edit point", @[@"next cut"]);
    add(@"Previous Edit Point", @"previousEdit", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"Up", @"Move to previous edit point", @[@"prev cut"]);

    // --- Playback ---
    add(@"Play / Pause", @"playPause", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Space", @"Toggle playback", @[@"stop", @"start"]);
    add(@"Go to Start", @"goToStart", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Home", @"Jump to beginning of timeline", @[@"beginning", @"rewind"]);
    add(@"Go to End", @"goToEnd", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"End", @"Jump to end of timeline", @[]);
    add(@"Next Frame", @"nextFrame", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Right", @"Step forward one frame", @[@"forward"]);
    add(@"Previous Frame", @"prevFrame", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Left", @"Step backward one frame", @[@"backward", @"back"]);
    add(@"Forward 10 Frames", @"nextFrame10", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Shift+Right", @"Jump forward 10 frames", @[]);
    add(@"Back 10 Frames", @"prevFrame10", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Shift+Left", @"Jump backward 10 frames", @[]);

    // --- Color Correction ---
    add(@"Add Color Board", @"addColorBoard", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Add Color Board effect to selected clip", @[@"color correction", @"grade"]);
    add(@"Add Color Wheels", @"addColorWheels", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Add Color Wheels effect", @[@"color correction"]);
    add(@"Add Color Curves", @"addColorCurves", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Add Color Curves effect", @[@"rgb curves"]);
    add(@"Add Color Adjustment", @"addColorAdjustment", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Add Color Adjustment controls", @[@"brightness", @"contrast", @"saturation"]);
    add(@"Add Hue/Saturation", @"addHueSaturation", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Add Hue/Saturation curves", @[@"hsl"]);
    add(@"Enhance Light and Color", @"addEnhanceLightAndColor", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Auto-enhance lighting and color", @[@"auto color", @"magic"]);

    // --- Speed / Retiming ---
    add(@"Normal Speed (100%)", @"retimeNormal", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Reset to normal speed", @[@"retime", @"1x"]);
    add(@"Fast 2x", @"retimeFast2x", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Double speed", @[@"200%", @"speed up"]);
    add(@"Fast 4x", @"retimeFast4x", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"4x speed", @[@"400%"]);
    add(@"Fast 8x", @"retimeFast8x", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"8x speed", @[@"800%"]);
    add(@"Fast 20x", @"retimeFast20x", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"20x speed", @[@"2000%"]);
    add(@"Slow 50%", @"retimeSlow50", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Half speed", @[@"slow motion", @"slow mo"]);
    add(@"Slow 25%", @"retimeSlow25", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Quarter speed", @[@"slow motion"]);
    add(@"Slow 10%", @"retimeSlow10", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"1/10 speed", @[@"super slow"]);
    add(@"Reverse", @"retimeReverse", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Reverse playback direction", @[@"backwards"]);
    add(@"Hold Frame", @"retimeHold", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Hold current frame", @[@"freeze"]);
    add(@"Freeze Frame", @"freezeFrame", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Create a freeze frame", @[@"still"]);
    add(@"Blade Speed", @"retimeBladeSpeed", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Split speed segment", @[]);

    // --- Markers ---
    add(@"Add Marker", @"addMarker", @"timeline", SpliceKitCommandCategoryMarkers, @"Markers", @"M", @"Add standard marker at playhead", @[@"mark"]);
    add(@"Add To-Do Marker", @"addTodoMarker", @"timeline", SpliceKitCommandCategoryMarkers, @"Markers", nil, @"Add to-do marker", @[@"task"]);
    add(@"Add Chapter Marker", @"addChapterMarker", @"timeline", SpliceKitCommandCategoryMarkers, @"Markers", nil, @"Add chapter marker for export", @[@"chapter"]);
    add(@"Delete Marker", @"deleteMarker", @"timeline", SpliceKitCommandCategoryMarkers, @"Markers", nil, @"Remove marker at playhead", @[]);
    add(@"Delete All Markers", @"deleteMarkersInSelection", @"timeline", SpliceKitCommandCategoryMarkers, @"Markers", nil, @"Remove all markers in selection (select all first)", @[@"remove all markers", @"clear markers"]);
    add(@"Next Marker", @"nextMarker", @"timeline", SpliceKitCommandCategoryMarkers, @"Markers", nil, @"Go to next marker", @[]);
    add(@"Previous Marker", @"previousMarker", @"timeline", SpliceKitCommandCategoryMarkers, @"Markers", nil, @"Go to previous marker", @[]);

    // --- Transitions ---
    add(@"Add Default Transition", @"addTransition", @"timeline", SpliceKitCommandCategoryEffects, @"Transitions", @"Cmd+T", @"Add default transition (Cross Dissolve)", @[@"cross dissolve", @"fade"]);
    add(@"Browse Transitions...", @"browseTransitions", @"transition_browse", SpliceKitCommandCategoryEffects, @"Transitions", nil, @"Search and apply a specific transition by name", @[@"find transition", @"list transitions"]);
    add(@"Browse Effects...", @"browseEffects", @"effect_browse", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Search and apply an effect by name", @[@"find effect", @"filter", @"plugin"]);
    add(@"Browse Generators...", @"browseGenerators", @"generator_browse", SpliceKitCommandCategoryEffects, @"Generators", nil, @"Search and apply a generator", @[@"background", @"solid"]);
    add(@"Browse Titles...", @"browseTitles", @"title_browse", SpliceKitCommandCategoryTitles, @"Titles", nil, @"Search and apply a title template", @[@"text", @"lower third"]);
    add(@"Browse Favorites...", @"browseFavorites", @"favorites_browse", SpliceKitCommandCategoryEffects, @"Favorites", nil, @"View all favorited effects, transitions, and generators", @[@"starred", @"pinned", @"bookmarks"]);

    // --- Titles ---
    add(@"Add Basic Title", @"addBasicTitle", @"timeline", SpliceKitCommandCategoryTitles, @"Titles", nil, @"Insert basic title at playhead", @[@"text"]);
    add(@"Add Lower Third", @"addBasicLowerThird", @"timeline", SpliceKitCommandCategoryTitles, @"Titles", nil, @"Insert lower third title", @[@"name plate", @"super"]);

    // --- Volume ---
    add(@"Volume Up", @"adjustVolumeUp", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Increase clip volume", @[@"louder"]);
    add(@"Volume Down", @"adjustVolumeDown", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Decrease clip volume", @[@"quieter", @"softer"]);

    // --- Keyframes ---
    add(@"Add Keyframe", @"addKeyframe", @"timeline", SpliceKitCommandCategoryKeyframes, @"Keyframes", nil, @"Add keyframe at playhead", @[@"animation"]);
    add(@"Delete Keyframes", @"deleteKeyframes", @"timeline", SpliceKitCommandCategoryKeyframes, @"Keyframes", nil, @"Remove keyframes from selection", @[]);
    add(@"Next Keyframe", @"nextKeyframe", @"timeline", SpliceKitCommandCategoryKeyframes, @"Keyframes", nil, @"Go to next keyframe", @[]);
    add(@"Previous Keyframe", @"previousKeyframe", @"timeline", SpliceKitCommandCategoryKeyframes, @"Keyframes", nil, @"Go to previous keyframe", @[]);

    // --- Export ---
    add(@"Export FCPXML", @"exportXML", @"timeline", SpliceKitCommandCategoryExport, @"Export", nil, @"Export timeline as FCPXML", @[@"xml"]);
    add(@"Share Selection", @"shareSelection", @"timeline", SpliceKitCommandCategoryExport, @"Export", nil, @"Share/export selected range", @[@"render"]);
    add(@"Batch Export", @"batchExport", @"batch_export", SpliceKitCommandCategoryExport, @"Export", nil, @"Export each clip individually using default share destination", @[@"batch", @"export all", @"individual"]);
    add(@"Auto Reframe", @"autoReframe", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Auto-reframe for different aspect ratios", @[@"crop", @"aspect"]);
    add(@"Stabilize Subject", @"stabilize_subject", @"subject_stabilize", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Lock camera onto a subject — keeps it fixed while background moves", @[@"lock on", @"track", @"stabilize", @"pin", @"follow", @"steady"]);

    // --- Generators ---
    add(@"Add Generator", @"addVideoGenerator", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Add a video generator", @[@"background"]);

    // ===================================================================
    // Extended commands (~100 additional everyday editing actions)
    // ===================================================================

    // --- Timeline View ---
    add(@"Zoom to Fit", @"zoomToFit", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Shift+Z", @"Fit entire timeline in view", @[@"fit", @"overview"]);
    add(@"Zoom In", @"zoomIn", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Cmd+=", @"Zoom into timeline", @[@"magnify", @"closer"]);
    add(@"Zoom Out", @"zoomOut", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Cmd+-", @"Zoom out of timeline", @[@"wider"]);
    add(@"Toggle Snapping", @"toggleSnapping", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"N", @"Enable/disable magnetic snapping", @[@"snap", @"magnet"]);
    add(@"Toggle Skimming", @"toggleSkimming", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"S", @"Enable/disable skimming preview", @[@"skim", @"hover"]);
    add(@"Toggle Timeline Index", @"toggleTimelineIndex", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Cmd+Shift+2", @"Show/hide the timeline index panel", @[@"index", @"sidebar", @"clips list"]);
    add(@"Toggle Inspector", @"toggleInspector", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Cmd+4", @"Show/hide the inspector panel", @[@"properties", @"parameters"]);
    add(@"Toggle Event Viewer", @"toggleEventViewer", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Show/hide the event viewer", @[@"dual viewer", @"source"]);
    add(@"Toggle Timeline", @"toggleTimeline", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Show/hide the timeline panel", @[]);

    // --- Clip Operations ---
    add(@"Detach Audio", @"detachAudio", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Separate audio from selected clip", @[@"split audio", @"unlink"]);
    add(@"Break Apart Clip Items", @"breakApartClipItems", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", @"Cmd+Shift+G", @"Break compound or multicam into individual clips", @[@"ungroup", @"flatten", @"decompose"]);
    add(@"Lift from Storyline", @"liftFromPrimaryStoryline", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Lift selected clip from primary storyline", @[@"extract"]);
    add(@"Overwrite to Primary", @"overwriteToPrimaryStoryline", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Overwrite clip onto primary storyline", @[@"stamp"]);
    add(@"Connect to Primary", @"connectClipToPrimaryStoryline", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", @"Q", @"Connect selected clip to primary storyline", @[@"attach"]);
    add(@"Insert at Playhead", @"insertClipAtPlayhead", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", @"W", @"Insert clip at playhead position", @[@"splice"]);
    add(@"Append to Storyline", @"appendToStoryline", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", @"E", @"Append clip to end of storyline", @[@"add to end"]);
    add(@"Replace with Gap", @"replaceWithGap", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Replace selected clip with gap (no ripple)", @[@"lift", @"remove in place"]);
    add(@"Create Storyline", @"createStoryline", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", @"Cmd+G", @"Group connected clips into a storyline", @[@"group", @"storyline"]);
    add(@"Synchronize Clips", @"synchronizeClips", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Sync clips by audio waveform or timecode", @[@"sync", @"multicam"]);
    add(@"Create Audition", @"createAudition", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Create audition from selected clips", @[@"audition", @"alternatives"]);
    add(@"Expand Audio / Video", @"expandAudioVideo", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Expand audio and video into separate lanes", @[@"split components"]);
    add(@"Expand Audio Components", @"expandAudioComponents", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Expand audio into individual channel components", @[@"channels", @"mono"]);
    add(@"Collapse to Clip", @"collapseToClip", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Collapse expanded audio/video back to single clip", @[@"collapse"]);
    add(@"Reference New Parent Clip", @"referenceNewParentClip", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Re-link clip to a new source", @[@"relink", @"reconnect"]);

    // --- Selection & Navigation ---
    add(@"Nudge Left", @"nudgeLeft", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @",", @"Move selected clip left by one frame", @[@"shift left", @"move left"]);
    add(@"Nudge Right", @"nudgeRight", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @".", @"Move selected clip right by one frame", @[@"shift right", @"move right"]);
    add(@"Nudge Left 10 Frames", @"nudgeLeftBig", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"Shift+,", @"Move selected clip left by 10 frames", @[@"shift left big"]);
    add(@"Nudge Right 10 Frames", @"nudgeRightBig", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"Shift+.", @"Move selected clip right by 10 frames", @[@"shift right big"]);
    add(@"Nudge Up", @"nudgeUp", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"Opt+Cmd+Up", @"Move selected clip to lane above", @[@"lane up"]);
    add(@"Nudge Down", @"nudgeDown", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"Opt+Cmd+Down", @"Move selected clip to lane below", @[@"lane down"]);
    add(@"Go to Range Start", @"goToRangeStart", @"playback", SpliceKitCommandCategoryPlayback, @"Navigation", @"Shift+I", @"Jump playhead to start of range selection", @[@"in point"]);
    add(@"Go to Range End", @"goToRangeEnd", @"playback", SpliceKitCommandCategoryPlayback, @"Navigation", @"Shift+O", @"Jump playhead to end of range selection", @[@"out point"]);
    add(@"Set Range Start", @"setRangeStart", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"I", @"Set start point of range selection", @[@"in point", @"mark in"]);
    add(@"Set Range End", @"setRangeEnd", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"O", @"Set end point of range selection", @[@"out point", @"mark out"]);
    add(@"Clear Range", @"clearRange", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"Opt+X", @"Remove range selection", @[@"deselect range"]);

    // --- Audio ---
    add(@"Remove Silences", @"removeSilences", @"silence_options", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Detect and remove silent segments from timeline", @[@"silence", @"quiet", @"dead air", @"gap", @"pause", @"mute"]);
    add(@"Audio Fade In", @"addAudioFadeIn", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Add audio fade-in to selected clip", @[@"ramp up"]);
    add(@"Audio Fade Out", @"addAudioFadeOut", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Add audio fade-out to selected clip", @[@"ramp down"]);
    add(@"Expand Audio Components", @"expandAudioComponents", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Show individual audio channels", @[@"channels"]);
    add(@"Audio Enhancements", @"showAudioEnhancements", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Open audio enhancement controls", @[@"eq", @"noise removal", @"loudness"]);
    add(@"Audio Match", @"matchAudio", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Match audio levels between clips", @[@"normalize"]);

    // --- Effects & Color ---
    add(@"Remove Effects", @"removeEffects", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Remove all effects from selected clip", @[@"clear effects", @"strip"]);
    add(@"Copy Effects", @"copyEffects", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Copy effects from selected clip", @[@"copy grade"]);
    add(@"Paste Effects", @"pasteEffects", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Paste effects onto selected clip", @[@"apply grade"]);
    add(@"Paste Attributes", @"pasteAttributes", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", @"Cmd+Shift+V", @"Choose which attributes to paste", @[@"selective paste"]);
    add(@"Match Color", @"matchColor", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Match color grading between clips", @[@"color match"]);
    add(@"Balance Color", @"balanceColor", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Auto-balance color of selected clip", @[@"auto color", @"white balance"]);
    add(@"Show Color Inspector", @"showColorInspector", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Open color correction inspector", @[@"color grading", @"color panel"]);
    add(@"Reset Effect Parameters", @"resetAllParameters", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Reset all parameters to default values", @[@"defaults", @"clear"]);

    // --- Rendering ---
    add(@"Render Selection", @"renderSelection", @"timeline", SpliceKitCommandCategoryExport, @"Render", @"Ctrl+R", @"Render selected portion of timeline", @[@"process"]);
    add(@"Render All", @"renderAll", @"timeline", SpliceKitCommandCategoryExport, @"Render", nil, @"Render entire timeline", @[@"process all"]);
    add(@"Delete Render Files", @"deleteRenderFiles", @"timeline", SpliceKitCommandCategoryExport, @"Render", nil, @"Delete generated render files to free space", @[@"clean", @"clear cache"]);

    // --- Stabilization & Analysis ---
    add(@"Analyze and Fix", @"analyzeAndFix", @"timeline", SpliceKitCommandCategoryEffects, @"Analysis", nil, @"Analyze clip for problems and fix automatically", @[@"stabilize", @"rolling shutter", @"repair"]);
    add(@"Detect Scene Changes", @"sceneDetect", @"scene_options", SpliceKitCommandCategoryEditing, @"Analysis", nil, @"Find cuts/scene changes and mark or blade them", @[@"shot boundary", @"find cuts", @"scene detection", @"auto marker", @"mark cuts", @"auto cut", @"split at cuts"]);

    // --- Trim & Precision Editing ---
    add(@"Roll Edit Left", @"rollEditLeft", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", nil, @"Roll the edit point one frame left", @[@"trim"]);
    add(@"Roll Edit Right", @"rollEditRight", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", nil, @"Roll the edit point one frame right", @[@"trim"]);
    add(@"Slip Left", @"slipLeft", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", nil, @"Slip clip content one frame left", @[@"slide content"]);
    add(@"Slip Right", @"slipRight", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", nil, @"Slip clip content one frame right", @[@"slide content"]);
    add(@"Ripple Trim Start to Playhead", @"rippleTrimStartToPlayhead", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", nil, @"Ripple-trim clip start to playhead", @[@"top"]);
    add(@"Ripple Trim End to Playhead", @"rippleTrimEndToPlayhead", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", nil, @"Ripple-trim clip end to playhead", @[@"tail"]);

    // --- Multicam ---
    add(@"Switch Angle 1", @"switchAngle01", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Switch to camera angle 1", @[@"cam 1"]);
    add(@"Switch Angle 2", @"switchAngle02", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Switch to camera angle 2", @[@"cam 2"]);
    add(@"Switch Angle 3", @"switchAngle03", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Switch to camera angle 3", @[@"cam 3"]);
    add(@"Switch Angle 4", @"switchAngle04", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Switch to camera angle 4", @[@"cam 4"]);
    add(@"Cut and Switch Angle 1", @"cutAndSwitchAngle01", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Blade and switch to angle 1", @[@"cut cam 1"]);
    add(@"Cut and Switch Angle 2", @"cutAndSwitchAngle02", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Blade and switch to angle 2", @[@"cut cam 2"]);
    add(@"Cut and Switch Angle 3", @"cutAndSwitchAngle03", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Blade and switch to angle 3", @[@"cut cam 3"]);
    add(@"Cut and Switch Angle 4", @"cutAndSwitchAngle04", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Blade and switch to angle 4", @[@"cut cam 4"]);
    add(@"Create Multicam Clip", @"createMulticamClip", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Create multicam clip from selected", @[@"multicamera"]);

    // --- Playback Modes ---
    add(@"Play Around Current", @"playAroundCurrent", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Shift+?", @"Play around the current playhead position", @[@"review"]);
    add(@"Play Selection", @"playSelection", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"/", @"Play the selected range", @[@"preview range"]);
    add(@"Play Full Screen", @"playFullScreen", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Cmd+Shift+F", @"Play timeline in full screen mode", @[@"cinema", @"presentation"]);
    add(@"Loop Playback", @"toggleLoopPlayback", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Cmd+L", @"Toggle loop playback on/off", @[@"repeat"]);
    add(@"Play Reverse", @"playReverse", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"J", @"Play in reverse", @[@"backwards", @"rewind"]);
    add(@"Play Forward 2x", @"playForward2x", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"L L", @"Play forward at double speed", @[@"fast forward"]);

    // --- Project & Library ---
    add(@"New Project", @"newProject", @"timeline", SpliceKitCommandCategoryExport, @"Project", @"Cmd+N", @"Create a new project in the current event", @[@"new timeline"]);
    add(@"New Event", @"newEvent", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"Create a new event in the library", @[]);
    add(@"Import Media", @"importMedia", @"timeline", SpliceKitCommandCategoryExport, @"Project", @"Cmd+I", @"Open the import media dialog", @[@"add files", @"ingest"]);
    add(@"Show Project Properties", @"showProjectProperties", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"View resolution, frame rate, and codec settings", @[@"settings", @"format"]);
    add(@"Consolidate Library Media", @"consolidateMedia", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"Copy external media into the library", @[@"collect", @"gather"]);

    // --- Organization & Rating ---
    add(@"Favorite", @"rateAsFavorite", @"timeline", SpliceKitCommandCategoryEditing, @"Rating", @"F", @"Mark selected clip as favorite", @[@"like", @"star", @"keep"]);
    add(@"Reject", @"rateAsReject", @"timeline", SpliceKitCommandCategoryEditing, @"Rating", @"Delete", @"Mark selected clip as rejected", @[@"dislike", @"bad"]);
    add(@"Remove Rating", @"removeRating", @"timeline", SpliceKitCommandCategoryEditing, @"Rating", @"U", @"Clear favorite/reject rating", @[@"unrate"]);
    add(@"Remove All Ratings", @"removeAllRatings", @"timeline", SpliceKitCommandCategoryEditing, @"Rating", nil, @"Clear all ratings in selection", @[@"reset ratings"]);

    // --- Roles ---
    add(@"Show Role Editor", @"showRoleEditor", @"timeline", SpliceKitCommandCategoryEditing, @"Roles", nil, @"Open the role assignment editor", @[@"roles", @"subroles"]);
    add(@"Assign Default Video Role", @"assignDefaultVideoRole", @"timeline", SpliceKitCommandCategoryEditing, @"Roles", nil, @"Assign default video role to clip", @[@"video role"]);
    add(@"Assign Default Audio Role", @"assignDefaultAudioRole", @"timeline", SpliceKitCommandCategoryEditing, @"Roles", nil, @"Assign default audio role to clip", @[@"audio role"]);

    // --- Captions & Subtitles ---
    add(@"Add Caption", @"addCaption", @"timeline", SpliceKitCommandCategoryTitles, @"Captions", nil, @"Add caption at playhead position", @[@"subtitle", @"text"]);
    add(@"Duplicate Caption", @"duplicateCaption", @"timeline", SpliceKitCommandCategoryTitles, @"Captions", nil, @"Duplicate the selected caption", @[@"copy caption"]);
    add(@"Import Captions", @"importCaptions", @"timeline", SpliceKitCommandCategoryTitles, @"Captions", nil, @"Import captions from SRT/ITT file", @[@"subtitles", @"srt"]);

    // --- Transform & Spatial ---
    add(@"Transform", @"showTransformControls", @"timeline", SpliceKitCommandCategoryEffects, @"Transform", nil, @"Show on-screen transform controls", @[@"position", @"scale", @"rotate"]);
    add(@"Crop", @"showCropControls", @"timeline", SpliceKitCommandCategoryEffects, @"Transform", @"Shift+C", @"Show crop controls on viewer", @[@"trim edges", @"ken burns"]);
    add(@"Distort", @"showDistortControls", @"timeline", SpliceKitCommandCategoryEffects, @"Transform", nil, @"Show corner-pin distort controls", @[@"perspective", @"corner pin"]);

    // --- Clip Appearance ---
    add(@"Increase Clip Height", @"increaseClipHeight", @"timeline", SpliceKitCommandCategoryEditing, @"Appearance", @"Cmd+Shift+=", @"Make timeline clips taller", @[@"bigger", @"larger waveform"]);
    add(@"Decrease Clip Height", @"decreaseClipHeight", @"timeline", SpliceKitCommandCategoryEditing, @"Appearance", @"Cmd+Shift+-", @"Make timeline clips shorter", @[@"smaller", @"compact"]);
    add(@"Show Clip Names", @"showClipNames", @"timeline", SpliceKitCommandCategoryEditing, @"Appearance", nil, @"Toggle clip name display on timeline", @[@"labels"]);
    add(@"Show Audio Waveforms", @"toggleClipAppearanceAudioWaveformsAction", @"timeline", SpliceKitCommandCategoryEditing, @"Appearance", nil, @"Toggle audio waveform display", @[@"waveform"]);

    // --- Compound & Nesting ---
    add(@"Open in Timeline", @"openInTimeline", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Open compound/multicam clip in its own timeline", @[@"dive in", @"enter"]);
    add(@"Back to Parent", @"backToParent", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Return to the parent timeline", @[@"go back", @"exit compound"]);

    // --- Snapping & Guides ---
    add(@"Snapping On", @"toggleSnappingUp", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Force snapping on", @[@"snap on"]);
    add(@"Snapping Off", @"toggleSnappingDown", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Force snapping off", @[@"snap off"]);
    add(@"Skimming On", @"toggleSkimmingUp", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Force skimming on", @[@"skim on"]);
    add(@"Skimming Off", @"toggleSkimmingDown", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Force skimming off", @[@"skim off"]);

    // --- Transcript ---
    add(@"Open Transcript Editor", @"openTranscript", @"transcript", SpliceKitCommandCategoryTranscript, @"Transcript", @"Ctrl+Opt+T", @"Open transcript-based editing panel", @[@"speech", @"captions"]);
    add(@"Close Transcript Editor", @"closeTranscript", @"transcript", SpliceKitCommandCategoryTranscript, @"Transcript", nil, @"Close the transcript panel", @[]);

    // ===================================================================
    // NEW: Comprehensive MCP actions added to command palette
    // ===================================================================

    // --- Edit Modes ---
    add(@"Paste as Connected Clip", @"pasteAsConnected", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Ctrl+V", @"Paste clipboard as connected clip", @[@"paste anchored"]);
    add(@"Copy Timecode", @"copyTimecode", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Copy current timecode to clipboard", @[@"timecode"]);
    add(@"Connect Edit (Audio Only)", @"connectEditAudio", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Connect only audio to primary storyline", @[@"audio only"]);
    add(@"Connect Edit (Video Only)", @"connectEditVideo", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Connect only video to primary storyline", @[@"video only"]);
    add(@"Insert Edit (Audio Only)", @"insertEditAudio", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Insert only audio", @[@"audio only insert"]);
    add(@"Insert Edit (Video Only)", @"insertEditVideo", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Insert only video", @[@"video only insert"]);
    add(@"Append Edit (Audio Only)", @"appendEditAudio", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Append only audio", @[@"audio only append"]);
    add(@"Append Edit (Video Only)", @"appendEditVideo", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Append only video", @[@"video only append"]);
    add(@"Overwrite Edit (Audio Only)", @"overwriteEditAudio", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Overwrite only audio", @[@"audio only overwrite"]);
    add(@"Overwrite Edit (Video Only)", @"overwriteEditVideo", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Overwrite only video", @[@"video only overwrite"]);
    add(@"AV Edit Mode: Audio", @"avEditModeAudio", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Switch to audio-only editing mode", @[@"audio mode"]);
    add(@"AV Edit Mode: Video", @"avEditModeVideo", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Switch to video-only editing mode", @[@"video mode"]);
    add(@"AV Edit Mode: Both", @"avEditModeBoth", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Switch to audio+video editing mode", @[@"av mode", @"both"]);
    add(@"Replace from Start", @"replaceFromStart", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Replace clip from start", @[@"replace edit"]);
    add(@"Replace from End", @"replaceFromEnd", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Replace clip from end", @[@"replace edit backtimed"]);
    add(@"Replace Whole Clip", @"replaceWhole", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Replace entire clip", @[@"swap"]);

    // --- Trim Extras ---
    add(@"Trim Start", @"trimStart", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", @"Opt+[", @"Trim clip start to playhead", @[@"head trim"]);
    add(@"Trim End", @"trimEnd", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", @"Opt+]", @"Trim clip end to playhead", @[@"tail trim"]);
    add(@"Join Through Edit", @"joinClips", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", nil, @"Join clips at edit point (remove through edit)", @[@"heal", @"join edit"]);
    add(@"Set Clip Range", @"setClipRange", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"X", @"Set range to clip boundaries", @[@"select clip range"]);
    add(@"Collapse to Connected Storyline", @"collapseToConnectedStoryline", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Collapse selection to connected storyline", @[@"collapse connected"]);

    // --- Speed Extras ---
    add(@"Custom Speed", @"retimeCustomSpeed", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Set custom speed percentage", @[@"retime custom"]);
    add(@"Instant Replay 50%", @"retimeInstantReplayHalf", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Instant replay at half speed", @[@"replay"]);
    add(@"Instant Replay 25%", @"retimeInstantReplayQuarter", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Instant replay at quarter speed", @[@"slow replay"]);
    add(@"Reset Speed", @"retimeReset", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Remove all retiming from clip", @[@"clear retime"]);
    add(@"Speed Ramp to Zero", @"retimeSpeedRampToZero", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Ramp speed down to freeze", @[@"speed ramp", @"slow down"]);
    add(@"Speed Ramp from Zero", @"retimeSpeedRampFromZero", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Ramp speed up from freeze", @[@"speed ramp", @"speed up"]);
    add(@"Optical Flow", @"retimeOpticalFlow", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Set retime quality to Optical Flow", @[@"high quality retime"]);
    add(@"Frame Blending", @"retimeFrameBlending", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Set retime quality to Frame Blending", @[@"smooth transition"]);
    add(@"Floor Frame (Nearest)", @"retimeFloorFrame", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Set retime quality to nearest frame", @[@"floor frame"]);

    // --- Audio Extras ---
    add(@"Add Channel EQ", @"addChannelEQ", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Add Channel EQ effect", @[@"equalizer"]);
    add(@"Enhance Audio", @"enhanceAudio", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Apply audio enhancement", @[@"audio fix"]);
    add(@"Align Audio to Video", @"alignAudioToVideo", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Synchronize audio to video", @[@"sync audio"]);
    add(@"Mute Volume", @"volumeMute", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Set volume to -infinity (mute)", @[@"silence", @"mute"]);
    add(@"Apply Audio Fades", @"applyAudioFades", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Apply fade in/out to audio", @[@"crossfade"]);
    add(@"Add Default Audio Effect", @"addDefaultAudioEffect", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Add default audio effect", @[@"audio plugin"]);
    add(@"Add Default Video Effect", @"addDefaultVideoEffect", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Add default video effect to selected clip", @[@"video plugin"]);

    // --- Color Extras ---
    add(@"Next Color Effect", @"nextColorEffect", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Go to next color correction", @[@"next grade"]);
    add(@"Previous Color Effect", @"previousColorEffect", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Go to previous color correction", @[@"prev grade"]);
    add(@"Reset Color Board", @"resetColorBoard", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Reset color board pucks to center", @[@"clear color"]);
    add(@"Toggle All Color Off", @"toggleAllColorOff", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Disable/enable all color corrections", @[@"bypass color"]);
    add(@"Add Magnetic Mask", @"addMagneticMask", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Add AI magnetic mask to clip", @[@"object mask", @"isolation"]);
    add(@"Smart Conform", @"smartConform", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Auto-reframe clip for project resolution", @[@"auto crop", @"reframe"]);

    // --- Show/Hide Editors ---
    add(@"Show Video Animation", @"showVideoAnimation", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Ctrl+V", @"Show/hide video animation editor", @[@"keyframe editor"]);
    add(@"Show Audio Animation", @"showAudioAnimation", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Ctrl+A", @"Show/hide audio animation editor", @[@"audio keyframes"]);
    add(@"Solo Animation", @"soloAnimation", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Collapse animation to single lane", @[@"collapse animation"]);
    add(@"Show Tracking Editor", @"showTrackingEditor", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Show object tracking editor", @[@"tracker"]);
    add(@"Show Cinematic Editor", @"showCinematicEditor", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Show cinematic mode editor", @[@"depth", @"focus"]);
    add(@"Show Magnetic Mask Editor", @"showMagneticMaskEditor", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Show magnetic mask editor", @[@"mask editor"]);
    add(@"Enable Beat Detection", @"enableBeatDetection", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Detect beats in audio", @[@"rhythm", @"music"]);
    add(@"Toggle Precision Editor", @"togglePrecisionEditor", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Show/hide precision trim editor", @[@"detailed trim"]);
    add(@"Show Audio Lanes", @"showAudioLanes", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Show audio lanes in timeline", @[@"audio tracks"]);
    add(@"Expand Subroles", @"expandSubroles", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Expand subrole lanes in timeline", @[@"role lanes"]);
    add(@"Show Duplicate Ranges", @"showDuplicateRanges", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Highlight duplicate clip ranges", @[@"duplicates"]);
    add(@"Show Keyword Editor", @"showKeywordEditor", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Cmd+K", @"Open keyword editor panel", @[@"tags"]);

    // --- View Extras ---
    add(@"Vertical Zoom to Fit", @"verticalZoomToFit", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Fit timeline vertically", @[@"vertical fit"]);
    add(@"Zoom to Samples", @"zoomToSamples", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Zoom to audio sample level", @[@"waveform zoom"]);
    add(@"Toggle Clip Skimming", @"toggleClipSkimming", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Enable/disable clip skimming", @[@"item skim"]);
    add(@"Toggle Audio Skimming", @"toggleAudioSkimming", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Opt+S", @"Enable/disable audio preview during skimming", @[@"audio skim", @"scrub audio"]);
    add(@"Toggle Inspector Height", @"toggleInspectorHeight", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Toggle inspector panel height", @[@"tall inspector"]);
    add(@"Beat Detection Grid", @"beatDetectionGrid", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Toggle beat detection grid overlay", @[@"beat grid"]);
    add(@"Timeline Scrolling", @"timelineScrolling", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Toggle timeline auto-scrolling mode", @[@"scroll mode"]);
    add(@"Enter Full Screen", @"enterFullScreen", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Ctrl+Cmd+F", @"Enter full screen mode", @[@"maximize"]);
    add(@"Timeline History Back", @"timelineHistoryBack", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Cmd+[", @"Go back in timeline navigation history", @[@"back"]);
    add(@"Timeline History Forward", @"timelineHistoryForward", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Cmd+]", @"Go forward in timeline navigation history", @[@"forward"]);

    // --- Navigation Go-To ---
    add(@"Go to Inspector", @"goToInspector", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", nil, @"Focus the inspector panel", @[@"focus inspector"]);
    add(@"Go to Timeline", @"goToTimeline", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", nil, @"Focus the timeline", @[@"focus timeline"]);
    add(@"Go to Viewer", @"goToViewer", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", nil, @"Focus the viewer", @[@"focus viewer"]);
    add(@"Go to Color Board", @"goToColorBoard", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Jump to color board panel", @[@"open color"]);

    // --- Keywords ---
    add(@"Apply Keyword Group 1", @"addKeywordGroup1", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", @"Ctrl+1", @"Apply keyword shortcut 1", @[@"tag 1"]);
    add(@"Apply Keyword Group 2", @"addKeywordGroup2", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", @"Ctrl+2", @"Apply keyword shortcut 2", @[@"tag 2"]);
    add(@"Apply Keyword Group 3", @"addKeywordGroup3", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", @"Ctrl+3", @"Apply keyword shortcut 3", @[@"tag 3"]);
    add(@"Apply Keyword Group 4", @"addKeywordGroup4", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", @"Ctrl+4", @"Apply keyword shortcut 4", @[@"tag 4"]);
    add(@"Apply Keyword Group 5", @"addKeywordGroup5", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", @"Ctrl+5", @"Apply keyword shortcut 5", @[@"tag 5"]);
    add(@"Apply Keyword Group 6", @"addKeywordGroup6", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", @"Ctrl+6", @"Apply keyword shortcut 6", @[@"tag 6"]);
    add(@"Apply Keyword Group 7", @"addKeywordGroup7", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", @"Ctrl+7", @"Apply keyword shortcut 7", @[@"tag 7"]);
    add(@"Remove All Keywords", @"removeAllKeywords", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", nil, @"Remove all keywords from selection", @[@"clear tags"]);
    add(@"Remove Analysis Keywords", @"removeAnalysisKeywords", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", nil, @"Remove auto-analysis keywords", @[@"clear analysis"]);

    // --- Clip Extras ---
    add(@"Enable/Disable Clip", @"enableDisable", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Toggle clip enabled/disabled", @[@"toggle clip"]);
    add(@"Make Clips Unique", @"makeClipsUnique", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Make referenced clips independent copies", @[@"independent"]);
    add(@"Rename Clip", @"renameClip", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Rename the selected clip", @[@"name"]);
    add(@"Add to Soloed Clips", @"addToSoloedClips", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Add clip to solo group", @[@"solo group"]);
    add(@"Transcode Media", @"transcodeMedia", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"Transcode clip to optimized or proxy media", @[@"optimize", @"proxy"]);
    add(@"Paste All Attributes", @"pasteAllAttributes", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Paste all attributes from clipboard", @[@"paste everything"]);
    add(@"Remove Attributes", @"removeAttributes", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Remove specific attributes from clip", @[@"strip attributes"]);
    add(@"Toggle Selected Effects Off", @"toggleSelectedEffectsOff", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Disable/enable selected effects", @[@"bypass effects"]);
    add(@"Toggle Duplicate Detection", @"toggleDuplicateDetection", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Show/hide duplicate clip indicators", @[@"dupes"]);

    // --- Audition Extras ---
    add(@"Finalize Audition", @"finalizeAudition", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Finalize audition with current pick", @[@"commit audition"]);
    add(@"Next Audition Pick", @"nextAuditionPick", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Preview next audition variant", @[@"next alternative"]);
    add(@"Previous Audition Pick", @"previousAuditionPick", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Preview previous audition variant", @[@"prev alternative"]);

    // --- Captions Extras ---
    add(@"Split Caption", @"splitCaption", @"timeline", SpliceKitCommandCategoryTitles, @"Captions", nil, @"Split caption at playhead", @[@"break caption"]);
    add(@"Resolve Caption Overlaps", @"resolveOverlaps", @"timeline", SpliceKitCommandCategoryTitles, @"Captions", nil, @"Fix overlapping captions", @[@"fix captions"]);

    // --- Project Extras ---
    add(@"Duplicate Project", @"duplicateProject", @"timeline", SpliceKitCommandCategoryExport, @"Project", @"Cmd+D", @"Duplicate the current project", @[@"copy project"]);
    add(@"Snapshot Project", @"snapshotProject", @"timeline", SpliceKitCommandCategoryExport, @"Project", @"Opt+Cmd+D", @"Save a timestamped snapshot of the project", @[@"backup", @"save version"]);
    add(@"Project Properties", @"projectProperties", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"Show project settings (resolution, frame rate)", @[@"project settings"]);
    add(@"Library Properties", @"libraryProperties", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"Show library storage and settings", @[@"library info"]);
    add(@"Close Library", @"closeLibrary", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"Close the current library", @[@"close lib"]);
    add(@"Merge Events", @"mergeEvents", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"Merge selected events", @[@"combine events"]);
    add(@"Delete Generated Files", @"deleteGeneratedFiles", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"Delete render, proxy, and analysis files", @[@"free space", @"clean up"]);

    // --- Find ---
    add(@"Find", @"find", @"timeline", SpliceKitCommandCategoryEditing, @"Find", @"Cmd+F", @"Open find panel", @[@"search"]);
    add(@"Find and Replace Title Text", @"findAndReplaceTitle", @"timeline", SpliceKitCommandCategoryEditing, @"Find", nil, @"Find and replace text in titles", @[@"replace text"]);

    // --- Reveal ---
    add(@"Reveal Source in Browser", @"revealInBrowser", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", nil, @"Show source clip in browser", @[@"find source"]);
    add(@"Reveal Project in Browser", @"revealProjectInBrowser", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", nil, @"Show project in browser", @[@"find project"]);
    add(@"Reveal in Finder", @"revealInFinder", @"timeline", SpliceKitCommandCategoryExport, @"Project", @"Opt+Cmd+R", @"Show file in macOS Finder", @[@"show in finder"]);
    add(@"Move to Trash", @"moveToTrash", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", @"Cmd+Delete", @"Move selected to trash", @[@"delete permanently"]);

    // --- Playback Extras ---
    add(@"Play from Start", @"playFromStart", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", nil, @"Play from the beginning of timeline", @[@"play beginning"]);
    add(@"Fast Forward", @"fastForward", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"L", @"Fast forward playback", @[@"speed up"]);
    add(@"Rewind", @"rewind", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"J", @"Rewind playback", @[@"reverse play"]);
    add(@"Stop Playing", @"stopPlaying", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"K", @"Stop playback", @[@"pause"]);

    // --- Window & Workspace ---
    add(@"Record Voiceover", @"recordVoiceover", @"timeline", SpliceKitCommandCategoryEditing, @"Window", nil, @"Open voiceover recording panel", @[@"voice", @"microphone", @"narration"]);
    add(@"Background Tasks", @"backgroundTasks", @"timeline", SpliceKitCommandCategoryEditing, @"Window", @"Cmd+9", @"Show background tasks window", @[@"rendering", @"progress"]);
    add(@"Edit Roles", @"editRoles", @"timeline", SpliceKitCommandCategoryEditing, @"Roles", nil, @"Open role editor dialog", @[@"manage roles"]);
    add(@"Hide Clip", @"hideClip", @"timeline", SpliceKitCommandCategoryEditing, @"Rating", nil, @"Hide selected clip in browser", @[@"reject hide"]);
    add(@"Show Preferences", @"showPreferences", @"timeline", SpliceKitCommandCategoryOptions, @"Options", @"Cmd+,", @"Open FCP preferences", @[@"settings"]);
    add(@"Add Adjustment Clip", @"addAdjustmentClip", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Add adjustment layer above timeline", @[@"adjustment layer"]);

    // --- Beat Detection ---
    add(@"Detect Beats in Audio File", @"detect", @"beats", SpliceKitCommandCategoryMusic, @"Music", nil, @"Analyze any MP3/WAV/M4A to detect beats, bars, tempo", @[@"beat detection", @"tempo", @"bpm", @"rhythm", @"onset", @"audio analysis"]);

    // --- FlexMusic (Dynamic Soundtrack) ---
    add(@"Browse FlexMusic Songs", @"listSongs", @"flexmusic", SpliceKitCommandCategoryMusic, @"FlexMusic", nil, @"Browse available dynamic soundtrack songs", @[@"music", @"soundtrack", @"song", @"browse", @"library"]);
    add(@"Add FlexMusic to Timeline", @"addToTimeline", @"flexmusic", SpliceKitCommandCategoryMusic, @"FlexMusic", nil, @"Add a dynamic soundtrack that auto-fits the timeline duration", @[@"music", @"soundtrack", @"background music", @"add song"]);
    add(@"Get Song Beat Timing", @"getTiming", @"flexmusic", SpliceKitCommandCategoryMusic, @"FlexMusic", nil, @"Get beat, bar, and section timestamps for a song", @[@"beats", @"bars", @"rhythm", @"tempo", @"timing"]);
    add(@"Render FlexMusic to File", @"renderToFile", @"flexmusic", SpliceKitCommandCategoryMusic, @"FlexMusic", nil, @"Export a fitted soundtrack as M4A or WAV audio", @[@"export", @"render", @"audio file", @"bounce"]);

    // --- Montage Maker ---
    add(@"Auto Montage", @"auto", @"montage", SpliceKitCommandCategoryMusic, @"Montage", nil, @"Auto-create a montage: analyze clips, pick song, cut to beat", @[@"montage", @"auto edit", @"highlight reel", @"music video", @"auto cut"]);
    add(@"Analyze Clips for Montage", @"analyzeClips", @"montage", SpliceKitCommandCategoryMusic, @"Montage", nil, @"Score and rank clips in the browser for montage creation", @[@"analyze", @"score", @"rank", @"clips"]);
    add(@"Plan Montage Edit", @"planEdit", @"montage", SpliceKitCommandCategoryMusic, @"Montage", nil, @"Create an edit decision list mapping clips to musical beats", @[@"plan", @"edl", @"edit plan", @"beat sync"]);
    add(@"Assemble Montage", @"assemble", @"montage", SpliceKitCommandCategoryMusic, @"Montage", nil, @"Build a montage timeline from an edit plan with transitions and music", @[@"assemble", @"build", @"create", @"timeline"]);

    // --- Options ---
    add(@"SpliceKit Options", @"bridgeOptions", @"bridge_options", SpliceKitCommandCategoryOptions, @"Options", nil, @"Open SpliceKit options panel", @[@"settings", @"preferences", @"config"]);
    add(@"Toggle Effect Drag as Adjustment Clip", @"toggleEffectDragAsAdjustmentClip", @"bridge_toggle", SpliceKitCommandCategoryOptions, @"Options", nil, @"Enable/disable dragging an effect to empty timeline space to create an adjustment clip", @[@"effect drag", @"adjustment layer", @"drop effect", @"effect browser"]);
    add(@"Toggle Viewer Pinch-to-Zoom", @"toggleViewerPinchZoom", @"bridge_toggle", SpliceKitCommandCategoryOptions, @"Options", nil, @"Enable/disable trackpad pinch-to-zoom on the viewer", @[@"trackpad", @"zoom", @"magnify", @"gesture"]);

    self.allCommands = [cmds copy];
    self.masterCommands = self.allCommands;
}

#pragma mark - Panel UI
//
// Builds the floating panel lazily on first show. The panel uses a
// vibrancy background (NSVisualEffectMaterialMenu) to match macOS system
// panels, with a rounded-corner mask for that modern look.
//

- (void)buildPanelIfNeeded {
    if (self.panel) return;

    // Position slightly above center — feels more natural for a command palette
    CGFloat width = 560;
    CGFloat height = 400;
    NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];
    CGFloat x = NSMidX(screenFrame) - width / 2;
    CGFloat y = NSMidY(screenFrame) + 60; // slightly above center
    NSRect frame = NSMakeRect(x, y, width, height);

    NSPanel *panel = [[NSPanel alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                   NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView)
        backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"";
    panel.titleVisibility = NSWindowTitleHidden;
    panel.titlebarAppearsTransparent = YES;
    panel.movableByWindowBackground = YES;
    panel.level = NSFloatingWindowLevel;
    panel.floatingPanel = YES;
    panel.becomesKeyOnlyIfNeeded = NO;
    panel.hidesOnDeactivate = NO;
    panel.releasedWhenClosed = NO;
    panel.delegate = self;
    panel.minSize = NSMakeSize(400, 200);
    panel.backgroundColor = [NSColor clearColor];

    // Vibrancy background
    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:panel.contentView.bounds];
    bg.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    bg.material = NSVisualEffectMaterialMenu;
    bg.state = NSVisualEffectStateActive;
    bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    bg.wantsLayer = YES;
    bg.layer.cornerRadius = 12;
    bg.layer.masksToBounds = YES;
    [panel.contentView addSubview:bg];
    self.backgroundView = bg;

    // Search field
    SpliceKitCommandSearchField *searchField = [[SpliceKitCommandSearchField alloc] initWithFrame:NSZeroRect];
    searchField.placeholderString = @"Type a command or describe what you want to do...";
    searchField.font = [NSFont systemFontOfSize:16];
    searchField.bordered = NO;
    searchField.focusRingType = NSFocusRingTypeNone;
    searchField.drawsBackground = NO;
    searchField.translatesAutoresizingMaskIntoConstraints = NO;
    searchField.delegate = self;
    [bg addSubview:searchField];
    self.searchField = searchField;

    // Separator line
    NSBox *separator = [[NSBox alloc] initWithFrame:NSZeroRect];
    separator.boxType = NSBoxSeparator;
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    [bg addSubview:separator];

    // Table view for results
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    column.resizingMask = NSTableColumnAutoresizingMask;

    NSTableView *tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    [tableView addTableColumn:column];
    tableView.headerView = nil;
    tableView.rowHeight = 40;
    tableView.intercellSpacing = NSMakeSize(0, 1);
    tableView.backgroundColor = [NSColor clearColor];
    tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    tableView.delegate = self;
    tableView.dataSource = self;
    tableView.doubleAction = @selector(executeSelectedCommand:);
    tableView.target = self;

    // Context menu for right-click favorites
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@""];
    contextMenu.delegate = self;
    tableView.menu = contextMenu;

    self.tableView = tableView;
    searchField.targetTableView = tableView;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView = tableView;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [bg addSubview:scroll];
    self.scrollView = scroll;

    // Status label
    NSTextField *statusLabel = [NSTextField labelWithString:@""];
    statusLabel.font = [NSFont systemFontOfSize:10];
    statusLabel.textColor = [NSColor tertiaryLabelColor];
    statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    statusLabel.alignment = NSTextAlignmentCenter;
    [bg addSubview:statusLabel];
    self.statusLabel = statusLabel;

    // Layout
    [NSLayoutConstraint activateConstraints:@[
        [searchField.topAnchor constraintEqualToAnchor:bg.topAnchor constant:38],
        [searchField.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor constant:16],
        [searchField.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor constant:-16],
        [searchField.heightAnchor constraintEqualToConstant:28],

        [separator.topAnchor constraintEqualToAnchor:searchField.bottomAnchor constant:8],
        [separator.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor],

        [scroll.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:0],
        [scroll.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:statusLabel.topAnchor constant:-2],

        [statusLabel.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor constant:12],
        [statusLabel.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor constant:-12],
        [statusLabel.bottomAnchor constraintEqualToAnchor:bg.bottomAnchor constant:-4],
        [statusLabel.heightAnchor constraintEqualToConstant:16],
    ]];

    self.panel = panel;

    // Update status
    [self updateStatusLabel];
}

- (void)updateStatusLabel {
    NSUInteger count = self.filteredCommands.count;
    NSString *text = [NSString stringWithFormat:@"%lu command%@ | Return to execute | Tab for AI | Esc to close",
                      (unsigned long)count, count == 1 ? @"" : @"s"];
    if (self.aiLoading) {
        text = @"Asking Apple Intelligence...";
    } else if (self.aiError) {
        text = [NSString stringWithFormat:@"AI: %@", self.aiError];
    } else if (self.aiResults.count > 0) {
        text = [NSString stringWithFormat:@"AI suggested %lu action%@ | Return to execute",
                (unsigned long)self.aiResults.count, self.aiResults.count == 1 ? @"" : @"s"];
    }
    self.statusLabel.stringValue = text;
}

#pragma mark - Show / Hide

- (void)showPalette {
    [self buildPanelIfNeeded];
    self.searchField.stringValue = @"";
    self.searchField.placeholderString = @"Type a command or describe what you want to do...";
    self.inBrowseMode = NO;
    self.allCommands = self.masterCommands;
    self.filteredCommands = self.allCommands;
    self.aiLoading = NO;
    self.aiQuery = nil;
    self.aiResults = nil;
    self.aiError = nil;
    [self.tableView reloadData];
    [self updateStatusLabel];

    // Restore saved position, or center on active screen
    NSString *savedFrame = [[NSUserDefaults standardUserDefaults] stringForKey:@"SpliceKitCommandPaletteFrame"];
    if (savedFrame) {
        [self.panel setFrameFromString:savedFrame];
    } else {
        NSScreen *screen = [NSScreen mainScreen];
        for (NSWindow *w in [NSApp windows]) {
            if (w.isMainWindow && w.screen) { screen = w.screen; break; }
        }
        CGFloat x = NSMidX(screen.visibleFrame) - self.panel.frame.size.width / 2;
        CGFloat y = NSMidY(screen.visibleFrame) + 60;
        [self.panel setFrameOrigin:NSMakePoint(x, y)];
    }

    [self.panel makeKeyAndOrderFront:nil];
    [self.panel makeFirstResponder:self.searchField];

    // Select first row
    if (self.filteredCommands.count > 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                    byExtendingSelection:NO];
    }

    // Install local event monitor for Escape and Return
    if (!self.localEventMonitor) {
        __weak typeof(self) weakSelf = self;
        self.localEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
            handler:^NSEvent *(NSEvent *event) {
                if (!weakSelf.panel.isVisible) return event;

                // Escape -> go back to main if in browse mode, else close
                if (event.keyCode == 53) {
                    if (weakSelf.inBrowseMode) {
                        [weakSelf exitBrowseMode];
                    } else {
                        [weakSelf hidePalette];
                    }
                    return nil;
                }
                // Return -> execute
                if (event.keyCode == 36) {
                    [weakSelf executeSelectedCommand:nil];
                    return nil;
                }
                // Up/Down arrow -> navigate table (skip separator rows)
                if (event.keyCode == 126) { // Up
                    NSInteger row = weakSelf.tableView.selectedRow;
                    if (row > 0) {
                        NSInteger newRow = row - 1;
                        SpliceKitCommand *cmd = [weakSelf commandForDisplayRow:newRow];
                        if (cmd && cmd.isSeparatorRow && newRow > 0) newRow--;
                        [weakSelf.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:newRow]
                                        byExtendingSelection:NO];
                        [weakSelf.tableView scrollRowToVisible:newRow];
                    }
                    return nil;
                }
                if (event.keyCode == 125) { // Down
                    NSInteger row = weakSelf.tableView.selectedRow;
                    NSInteger max = weakSelf.tableView.numberOfRows - 1;
                    if (row < max) {
                        NSInteger newRow = row + 1;
                        SpliceKitCommand *cmd = [weakSelf commandForDisplayRow:newRow];
                        if (cmd && cmd.isSeparatorRow && newRow < max) newRow++;
                        [weakSelf.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:newRow]
                                        byExtendingSelection:NO];
                        [weakSelf.tableView scrollRowToVisible:newRow];
                    }
                    return nil;
                }
                // Tab -> trigger AI on current query
                if (event.keyCode == 48) {
                    NSString *query = weakSelf.searchField.stringValue;
                    if (query.length > 0) {
                        [weakSelf triggerAI:query];
                    }
                    return nil;
                }
                return event;
            }];
    }
}

- (void)hidePalette {
    // Save position and size
    [[NSUserDefaults standardUserDefaults] setObject:[self.panel stringWithSavedFrame]
                                              forKey:@"SpliceKitCommandPaletteFrame"];
    [self.panel orderOut:nil];
    if (self.localEventMonitor) {
        [NSEvent removeMonitor:self.localEventMonitor];
        self.localEventMonitor = nil;
    }
}

- (void)togglePalette {
    if ([self isVisible]) {
        [self hidePalette];
    } else {
        [self showPalette];
    }
}

- (BOOL)isVisible {
    return self.panel.isVisible;
}

#pragma mark - NSWindowDelegate

- (void)windowWillClose:(NSNotification *)notification {
    [[NSUserDefaults standardUserDefaults] setObject:[self.panel stringWithSavedFrame]
                                              forKey:@"SpliceKitCommandPaletteFrame"];
    if (self.localEventMonitor) {
        [NSEvent removeMonitor:self.localEventMonitor];
        self.localEventMonitor = nil;
    }
}

- (void)windowDidMove:(NSNotification *)notification {
    [[NSUserDefaults standardUserDefaults] setObject:[self.panel stringWithSavedFrame]
                                              forKey:@"SpliceKitCommandPaletteFrame"];
}

- (void)windowDidResize:(NSNotification *)notification {
    [[NSUserDefaults standardUserDefaults] setObject:[self.panel stringWithSavedFrame]
                                              forKey:@"SpliceKitCommandPaletteFrame"];
}

#pragma mark - NSControl Text Editing Delegate (arrow keys)

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    if (commandSelector == @selector(moveUp:)) {
        NSInteger row = self.tableView.selectedRow;
        if (row > 0) {
            NSInteger newRow = row - 1;
            SpliceKitCommand *cmd = [self commandForDisplayRow:newRow];
            if (cmd && cmd.isSeparatorRow && newRow > 0) newRow--;
            [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:newRow]
                        byExtendingSelection:NO];
            [self.tableView scrollRowToVisible:newRow];
        }
        return YES;
    }
    if (commandSelector == @selector(moveDown:)) {
        NSInteger row = self.tableView.selectedRow;
        NSInteger maxRow = self.tableView.numberOfRows - 1;
        if (row < maxRow) {
            NSInteger newRow = row + 1;
            SpliceKitCommand *cmd = [self commandForDisplayRow:newRow];
            if (cmd && cmd.isSeparatorRow && newRow < maxRow) newRow++;
            [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:newRow]
                        byExtendingSelection:NO];
            [self.tableView scrollRowToVisible:newRow];
        }
        return YES;
    }
    if (commandSelector == @selector(insertNewline:)) {
        [self executeSelectedCommand:nil];
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        if (self.inBrowseMode) {
            [self exitBrowseMode];
        } else {
            [self hidePalette];
        }
        return YES;
    }
    return NO;
}

#pragma mark - Search / Filter

- (NSArray<SpliceKitCommand *> *)searchCommands:(NSString *)query {
    if (query.length == 0) return self.allCommands;

    NSMutableArray<SpliceKitCommand *> *results = [NSMutableArray array];
    for (SpliceKitCommand *cmd in self.allCommands) {
        // Score against name
        CGFloat nameScore = FCPFuzzyScore(query, cmd.name);
        // Score against keywords
        CGFloat keywordScore = 0;
        for (NSString *kw in cmd.keywords) {
            CGFloat s = FCPFuzzyScore(query, kw);
            if (s > keywordScore) keywordScore = s;
        }
        // Score against category
        CGFloat catScore = FCPFuzzyScore(query, cmd.categoryName) * 0.5;
        // Score against detail
        CGFloat detailScore = FCPFuzzyScore(query, cmd.detail) * 0.3;

        CGFloat best = MAX(MAX(nameScore, keywordScore), MAX(catScore, detailScore));
        if (best > 0.2) {
            cmd.score = best;
            [results addObject:cmd];
        }
    }

    [results sortUsingComparator:^NSComparisonResult(SpliceKitCommand *a, SpliceKitCommand *b) {
        if (a.score > b.score) return NSOrderedAscending;
        if (a.score < b.score) return NSOrderedDescending;
        return [a.name compare:b.name];
    }];

    return results;
}

- (void)controlTextDidChange:(NSNotification *)notification {
    NSString *query = self.searchField.stringValue;
    if (self.inBrowseMode && self.rawBrowseCommands) {
        if (query.length > 0) {
            // Search raw list (no favorites section) to avoid duplicates
            self.filteredCommands = [self searchCommandsInArray:self.rawBrowseCommands query:query];
        } else {
            // Restore favorites section when search is cleared
            [self injectFavoritesIntoCurrentList];
        }
    } else {
        self.filteredCommands = [self searchCommands:query];
    }
    // Only clear AI state if the query actually changed from what AI answered
    BOOL queryChanged = ![query isEqualToString:self.aiCompletedQuery ?: @""];
    if (queryChanged) {
        self.aiResults = nil;
        self.aiError = nil;
        self.aiCompletedQuery = nil;
        [self.aiDebounceTimer invalidate];
        self.aiDebounceTimer = nil;
    }

    [self.tableView reloadData];
    [self updateStatusLabel];

    // Auto-select first row
    if (self.filteredCommands.count > 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                    byExtendingSelection:NO];
    }

    // Debounced AI auto-trigger: only after 0.8s pause, no matches, and not already answered
    [self.aiDebounceTimer invalidate];
    if (query.length > 10 && [query containsString:@" "] &&
        self.filteredCommands.count == 0 && !self.aiLoading &&
        ![query isEqualToString:self.aiCompletedQuery]) {
        self.aiDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.8
            target:self selector:@selector(aiDebounceTimerFired:)
            userInfo:query repeats:NO];
    }
}

- (void)aiDebounceTimerFired:(NSTimer *)timer {
    NSString *query = timer.userInfo;
    if ([query isEqualToString:self.searchField.stringValue] && !self.aiLoading) {
        [self triggerAI:query];
    }
}

#pragma mark - NSTableView DataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    NSInteger count = (NSInteger)self.filteredCommands.count;
    if (self.aiLoading || self.aiResults.count > 0) count += 1; // AI row
    return count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    // AI loading/result row at the top
    if (self.aiLoading && row == 0) {
        FCPAIResultRowView *cell = [tableView makeViewWithIdentifier:kAIRowID owner:nil];
        if (!cell) {
            cell = [[FCPAIResultRowView alloc] initWithFrame:NSMakeRect(0, 0, 500, 40)];
            cell.identifier = kAIRowID;
        }
        cell.label.stringValue = @"Asking Apple Intelligence...";
        [cell.spinner startAnimation:nil];
        cell.spinner.hidden = NO;
        return cell;
    }

    if (self.aiResults.count > 0 && row == 0) {
        FCPAIResultRowView *cell = [tableView makeViewWithIdentifier:kAIRowID owner:nil];
        if (!cell) {
            cell = [[FCPAIResultRowView alloc] initWithFrame:NSMakeRect(0, 0, 500, 40)];
            cell.identifier = kAIRowID;
        }
        cell.spinner.hidden = YES;
        NSMutableString *desc = [NSMutableString stringWithString:@"AI: "];
        for (NSDictionary *a in self.aiResults) {
            NSString *label = a[@"action"] ?: a[@"name"] ?: nil;
            if (!label && a[@"seconds"]) {
                label = [NSString stringWithFormat:@"%@s", a[@"seconds"]];
            }
            [desc appendFormat:@"%@ %@", a[@"type"], label ?: @"?"];
            if (a != self.aiResults.lastObject) [desc appendString:@" -> "];
        }
        cell.label.stringValue = desc;
        cell.label.textColor = [NSColor controlAccentColor];
        return cell;
    }

    SpliceKitCommand *cmd = [self commandForDisplayRow:row];
    if (!cmd) return nil;

    // Separator row
    if (cmd.isSeparatorRow) {
        FCPSeparatorRowView *cell = [tableView makeViewWithIdentifier:kSeparatorRowID owner:nil];
        if (!cell) {
            cell = [[FCPSeparatorRowView alloc] initWithFrame:NSMakeRect(0, 0, 500, 20)];
            cell.identifier = kSeparatorRowID;
        }
        return cell;
    }

    SpliceKitCommandRowView *cell = [tableView makeViewWithIdentifier:kCommandRowID owner:nil];
    if (!cell) {
        cell = [[SpliceKitCommandRowView alloc] initWithFrame:NSMakeRect(0, 0, 500, 40)];
        cell.identifier = kCommandRowID;
    }

    [cell configureWithCommand:cmd isFavorited:cmd.isFavoritedItem];
    return cell;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    SpliceKitCommand *cmd = [self commandForDisplayRow:row];
    if (cmd && cmd.isSeparatorRow) return 20;
    return 40;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    SpliceKitCommand *cmd = [self commandForDisplayRow:row];
    if (cmd && cmd.isSeparatorRow) return NO;
    return YES;
}

#pragma mark - Execute

- (void)executeSelectedCommand:(id)sender {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0) return;

    // If AI result row is selected
    if ((self.aiLoading || self.aiResults.count > 0) && row == 0) {
        if (self.aiResults.count > 0) {
            [self hidePalette];
            [self executeAIResults:self.aiResults];
        }
        return;
    }

    SpliceKitCommand *cmd = [self commandForDisplayRow:row];
    if (!cmd || cmd.isSeparatorRow) return;

    // Don't hide palette for browse commands — they repopulate it
    if ([cmd.type isEqualToString:@"transition_browse"]) {
        [self enterTransitionBrowseMode];
        return;
    }
    if ([cmd.type isEqualToString:@"effect_browse"]) {
        [self enterEffectBrowseMode:@"filter"];
        return;
    }
    if ([cmd.type isEqualToString:@"generator_browse"]) {
        [self enterEffectBrowseMode:@"generator"];
        return;
    }
    if ([cmd.type isEqualToString:@"title_browse"]) {
        [self enterEffectBrowseMode:@"title"];
        return;
    }
    if ([cmd.type isEqualToString:@"favorites_browse"]) {
        [self enterFavoritesBrowseMode];
        return;
    }
    [self hidePalette];
    [self executeCommand:cmd.action type:cmd.type];
}

- (NSDictionary *)executeCommand:(NSString *)action type:(NSString *)type {
    __block NSDictionary *result = nil;

    if ([type isEqualToString:@"timeline"]) {
        result = SpliceKit_handleTimelineAction(@{@"action": action});
    } else if ([type isEqualToString:@"playback"]) {
        result = SpliceKit_handlePlayback(@{@"action": action});
    } else if ([type isEqualToString:@"transcript"]) {
        SpliceKit_executeOnMainThread(^{
            Class panelClass = objc_getClass("SpliceKitTranscriptPanel");
            if (!panelClass) return;
            id panel = ((id (*)(id, SEL))objc_msgSend)((id)panelClass, @selector(sharedPanel));
            if ([action isEqualToString:@"openTranscript"]) {
                ((void (*)(id, SEL))objc_msgSend)(panel, @selector(showPanel));
            } else if ([action isEqualToString:@"closeTranscript"]) {
                ((void (*)(id, SEL))objc_msgSend)(panel, @selector(hidePanel));
            }
        });
        result = @{@"action": action, @"status": @"ok"};
    } else if ([type isEqualToString:@"transition_browse"]) {
        // Switch palette into transition browsing mode
        [self enterTransitionBrowseMode];
        result = @{@"action": action, @"status": @"ok"};
    } else if ([type isEqualToString:@"transition_apply"]) {
        extern NSDictionary *SpliceKit_handleTransitionsApply(NSDictionary *params);
        result = SpliceKit_handleTransitionsApply(@{@"effectID": action});
    } else if ([type isEqualToString:@"title_apply"] || [type isEqualToString:@"generator_apply"]) {
        extern NSDictionary *SpliceKit_handleTitleInsert(NSDictionary *params);
        result = SpliceKit_handleTitleInsert(@{@"effectID": action});
    } else if ([type isEqualToString:@"effect_apply"]) {
        extern NSDictionary *SpliceKit_handleEffectsApply(NSDictionary *params);
        result = SpliceKit_handleEffectsApply(@{@"effectID": action});
    } else if ([type isEqualToString:@"effect_apply_by_name"]) {
        extern NSDictionary *SpliceKit_handleEffectsApply(NSDictionary *params);
        result = SpliceKit_handleEffectsApply(@{@"name": action});
    } else if ([type isEqualToString:@"subject_stabilize"]) {
        // Run on background thread — tracking takes time
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            extern NSDictionary *SpliceKit_handleSubjectStabilize(NSDictionary *params);
            NSDictionary *r = SpliceKit_handleSubjectStabilize(@{});
            dispatch_async(dispatch_get_main_queue(), ^{
                if (r[@"error"]) {
                    SpliceKit_log(@"[Stabilize] Error: %@", r[@"error"]);
                } else {
                    SpliceKit_log(@"[Stabilize] Complete: %@ keyframes applied", r[@"keyframesApplied"]);
                }
            });
        });
        result = @{@"action": action, @"status": @"started"};
    } else if ([type isEqualToString:@"silence_options"]) {
        [self showSilenceOptionsPanel];
        result = @{@"action": action, @"status": @"started"};
    } else if ([type isEqualToString:@"scene_options"]) {
        [self showSceneDetectionOptionsPanel];
        result = @{@"action": action, @"status": @"started"};
    } else if ([type isEqualToString:@"batch_export"]) {
        extern NSDictionary *SpliceKit_handleBatchExport(NSDictionary *params);
        result = SpliceKit_handleBatchExport(@{@"scope": @"all"});
    } else if ([type isEqualToString:@"bridge_options"]) {
        [self showBridgeOptionsPanel];
        result = @{@"action": action, @"status": @"ok"};
    } else if ([type isEqualToString:@"beats"]) {
        SpliceKit_log(@"[Beats] detect requires filePath. Use via MCP: detect_beats(file_path)");
        result = @{@"status": @"info", @"message": @"Use via MCP: detect_beats(file_path). Provide path to any MP3/WAV/M4A file."};
    } else if ([type isEqualToString:@"flexmusic"]) {
        // FlexMusic commands — dispatch to JSON-RPC handlers
        if ([action isEqualToString:@"listSongs"]) {
            extern NSDictionary *SpliceKit_handleFlexMusicListSongs(NSDictionary *params);
            result = SpliceKit_handleFlexMusicListSongs(@{});
            // Log summary for palette feedback
            NSArray *songs = result[@"songs"];
            if (songs) {
                SpliceKit_log(@"[FlexMusic] Found %lu songs", (unsigned long)songs.count);
            }
        } else if ([action isEqualToString:@"addToTimeline"]) {
            // Needs a song UID — show a message that this should be used via MCP
            SpliceKit_log(@"[FlexMusic] addToTimeline requires songUID parameter. Use via MCP: flexmusic_add_to_timeline(song_uid)");
            result = @{@"status": @"info", @"message": @"Use via MCP: flexmusic_add_to_timeline(song_uid). Run 'Browse FlexMusic Songs' first to find song UIDs."};
        } else if ([action isEqualToString:@"getTiming"]) {
            SpliceKit_log(@"[FlexMusic] getTiming requires songUID and durationSeconds. Use via MCP: flexmusic_get_timing(song_uid, duration_seconds)");
            result = @{@"status": @"info", @"message": @"Use via MCP: flexmusic_get_timing(song_uid, duration_seconds)"};
        } else if ([action isEqualToString:@"renderToFile"]) {
            SpliceKit_log(@"[FlexMusic] renderToFile requires songUID, durationSeconds, outputPath. Use via MCP: flexmusic_render_to_file(...)");
            result = @{@"status": @"info", @"message": @"Use via MCP: flexmusic_render_to_file(song_uid, duration_seconds, output_path)"};
        } else {
            result = @{@"error": [NSString stringWithFormat:@"Unknown flexmusic action: %@", action]};
        }
    } else if ([type isEqualToString:@"montage"]) {
        // Montage commands — dispatch to JSON-RPC handlers
        if ([action isEqualToString:@"auto"]) {
            SpliceKit_log(@"[Montage] auto requires songUID. Use via MCP: montage_auto(song_uid, event_name, style)");
            result = @{@"status": @"info", @"message": @"Use via MCP: montage_auto(song_uid, event_name, style, project_name). Run 'Browse FlexMusic Songs' first."};
        } else if ([action isEqualToString:@"analyzeClips"]) {
            extern NSDictionary *SpliceKit_handleMontageAnalyze(NSDictionary *params);
            result = SpliceKit_handleMontageAnalyze(@{});
            NSArray *clips = result[@"clips"];
            if (clips) {
                SpliceKit_log(@"[Montage] Analyzed %lu clips", (unsigned long)clips.count);
            }
        } else if ([action isEqualToString:@"planEdit"]) {
            SpliceKit_log(@"[Montage] planEdit requires beats, clips, style. Use via MCP: montage_plan_edit(...)");
            result = @{@"status": @"info", @"message": @"Use via MCP: montage_plan_edit(beats, clips, style)"};
        } else if ([action isEqualToString:@"assemble"]) {
            SpliceKit_log(@"[Montage] assemble requires editPlan. Use via MCP: montage_assemble(edit_plan, project_name, song_file)");
            result = @{@"status": @"info", @"message": @"Use via MCP: montage_assemble(edit_plan, project_name, song_file)"};
        } else {
            result = @{@"error": [NSString stringWithFormat:@"Unknown montage action: %@", action]};
        }
    } else if ([type isEqualToString:@"bridge_toggle"]) {
        if ([action isEqualToString:@"toggleEffectDragAsAdjustmentClip"]) {
            BOOL newState = !SpliceKit_isEffectDragAsAdjustmentClipEnabled();
            SpliceKit_setEffectDragAsAdjustmentClipEnabled(newState);
            result = @{@"action": action, @"status": @"ok",
                       @"effectDragAsAdjustmentClip": @(newState)};
        } else if ([action isEqualToString:@"toggleViewerPinchZoom"]) {
            BOOL newState = !SpliceKit_isViewerPinchZoomEnabled();
            SpliceKit_setViewerPinchZoomEnabled(newState);
            result = @{@"action": action, @"status": @"ok",
                       @"viewerPinchZoom": @(newState)};
        } else {
            result = @{@"error": [NSString stringWithFormat:@"Unknown toggle: %@", action]};
        }
    }

    if (!result) {
        result = @{@"error": [NSString stringWithFormat:@"Unknown command type: %@", type]};
    }

    SpliceKit_log(@"Command palette executed: %@ (%@) -> %@", action, type,
                  result[@"error"] ?: @"ok");
    return result;
}

#pragma mark - Processing HUD

- (NSPanel *)showProcessingHUD:(NSString *)message {
    __block NSPanel *hud = nil;
    if ([NSThread isMainThread]) {
        hud = [self _createProcessingHUD:message];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            hud = [self _createProcessingHUD:message];
        });
    }
    return hud;
}

- (NSPanel *)_createProcessingHUD:(NSString *)message {
    NSPanel *hud = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 280, 80)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView)
        backing:NSBackingStoreBuffered defer:NO];
    hud.title = @"";
    hud.titleVisibility = NSWindowTitleHidden;
    hud.titlebarAppearsTransparent = YES;
    hud.level = NSFloatingWindowLevel;
    hud.backgroundColor = [NSColor clearColor];
    hud.movableByWindowBackground = YES;
    hud.releasedWhenClosed = NO;
    [hud center];

    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:hud.contentView.bounds];
    bg.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    bg.material = NSVisualEffectMaterialHUDWindow;
    bg.state = NSVisualEffectStateActive;
    bg.wantsLayer = YES;
    bg.layer.cornerRadius = 12;
    bg.layer.masksToBounds = YES;
    [hud.contentView addSubview:bg];

    NSProgressIndicator *spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 28, 24, 24)];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeRegular;
    [spinner startAnimation:nil];
    [bg addSubview:spinner];

    NSTextField *label = [NSTextField labelWithString:message];
    label.frame = NSMakeRect(52, 28, 210, 24);
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    label.textColor = [NSColor labelColor];
    [bg addSubview:label];

    [hud makeKeyAndOrderFront:nil];
    return hud;
}

- (void)dismissProcessingHUD:(NSPanel *)hud {
    if (!hud) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [hud close];
    });
}

#pragma mark - Remove Silences

- (NSString *)findSilenceDetector {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. Inside the FCP framework bundle (deployed by patcher)
    NSString *buildDir = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Contents/Frameworks/SpliceKit.framework/Versions/A/Resources"];
    NSString *builtPath = [buildDir stringByAppendingPathComponent:@"silence-detector"];
    if ([fm isExecutableFileAtPath:builtPath]) return builtPath;

    // 2. Common deploy directories
    NSString *home = NSHomeDirectory();
    NSArray *paths = @[
        [home stringByAppendingPathComponent:@"Desktop/SpliceKit/build/silence-detector"],
        [home stringByAppendingPathComponent:@"Documents/GitHub/SpliceKit/build/silence-detector"],
        [home stringByAppendingPathComponent:@"SpliceKit/build/silence-detector"],
        [home stringByAppendingPathComponent:@"Library/Caches/SpliceKit/build/silence-detector"],
    ];
    for (NSString *p in paths) {
        if ([fm isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

- (void)showSilenceOptionsPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Build options panel
        NSPanel *opts = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 320)
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
            backing:NSBackingStoreBuffered defer:NO];
        opts.title = @"Remove Silences";
        [opts center];

        NSView *v = opts.contentView;
        CGFloat y = 280;

        // --- Threshold ---
        NSTextField *threshLabel = [NSTextField labelWithString:@"Threshold (dB):"];
        threshLabel.frame = NSMakeRect(20, y, 140, 20);
        [v addSubview:threshLabel];

        NSPopUpButton *threshPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(165, y - 2, 190, 26) pullsDown:NO];
        [threshPop addItemsWithTitles:@[@"Auto (adaptive)", @"-35 dB (aggressive)", @"-40 dB", @"-44 dB", @"-48 dB (conservative)", @"-52 dB (very conservative)"]];
        [threshPop selectItemAtIndex:0];
        [v addSubview:threshPop];

        // --- Min silence duration ---
        y -= 40;
        NSTextField *durLabel = [NSTextField labelWithString:@"Min silence duration:"];
        durLabel.frame = NSMakeRect(20, y, 140, 20);
        [v addSubview:durLabel];

        NSPopUpButton *durPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(165, y - 2, 190, 26) pullsDown:NO];
        [durPop addItemsWithTitles:@[@"0.2s (catch short pauses)", @"0.3s", @"0.5s (default)", @"0.75s", @"1.0s (only long gaps)"]];
        [durPop selectItemAtIndex:1];
        [v addSubview:durPop];

        // --- Padding ---
        y -= 40;
        NSTextField *padLabel = [NSTextField labelWithString:@"Padding:"];
        padLabel.frame = NSMakeRect(20, y, 140, 20);
        [v addSubview:padLabel];

        NSPopUpButton *padPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(165, y - 2, 190, 26) pullsDown:NO];
        [padPop addItemsWithTitles:@[@"0.0s (tight cuts)", @"0.05s", @"0.08s (default)", @"0.1s", @"0.15s (safe)"]];
        [padPop selectItemAtIndex:2];
        [v addSubview:padPop];

        // --- Description ---
        y -= 50;
        NSTextField *desc = [NSTextField wrappingLabelWithString:
            @"Threshold: How quiet audio must be to count as silence. "
            @"Lower values = less aggressive. \"Auto\" analyzes the clip's audio profile.\n\n"
            @"Min duration: Silences shorter than this are ignored.\n\n"
            @"Padding: Audio kept before/after each cut to avoid clipping words."];
        desc.frame = NSMakeRect(20, 60, 340, 120);
        desc.font = [NSFont systemFontOfSize:11];
        desc.textColor = [NSColor secondaryLabelColor];
        [v addSubview:desc];

        // --- Buttons ---
        NSButton *cancelBtn = [NSButton buttonWithTitle:@"Cancel" target:nil action:nil];
        cancelBtn.frame = NSMakeRect(180, 15, 80, 32);
        cancelBtn.bezelStyle = NSBezelStyleRounded;
        [v addSubview:cancelBtn];

        NSButton *runBtn = [NSButton buttonWithTitle:@"Remove" target:nil action:nil];
        runBtn.frame = NSMakeRect(270, 15, 90, 32);
        runBtn.bezelStyle = NSBezelStyleRounded;
        runBtn.keyEquivalent = @"\r";
        [v addSubview:runBtn];

        // Run modal
        __block BOOL didRun = NO;
        cancelBtn.target = opts;
        cancelBtn.action = @selector(close);

        runBtn.target = self;
        runBtn.action = @selector(_silenceOptionsRun:);
        objc_setAssociatedObject(runBtn, "panel", opts, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(runBtn, "threshPop", threshPop, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(runBtn, "durPop", durPop, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(runBtn, "padPop", padPop, OBJC_ASSOCIATION_RETAIN);

        [opts makeKeyAndOrderFront:nil];
    });
}

- (void)_silenceOptionsRun:(NSButton *)sender {
    NSPanel *panel = objc_getAssociatedObject(sender, "panel");
    NSPopUpButton *threshPop = objc_getAssociatedObject(sender, "threshPop");
    NSPopUpButton *durPop = objc_getAssociatedObject(sender, "durPop");
    NSPopUpButton *padPop = objc_getAssociatedObject(sender, "padPop");

    // Parse threshold
    NSString *threshold = @"auto";
    NSArray *threshVals = @[@"auto", @"-35", @"-40", @"-44", @"-48", @"-52"];
    threshold = threshVals[threshPop.indexOfSelectedItem];

    // Parse min duration
    NSArray *durVals = @[@0.2, @0.3, @0.5, @0.75, @1.0];
    double minDur = [durVals[durPop.indexOfSelectedItem] doubleValue];

    // Parse padding
    NSArray *padVals = @[@0.0, @0.05, @0.08, @0.1, @0.15];
    double pad = [padVals[padPop.indexOfSelectedItem] doubleValue];

    [panel close];
    [self performRemoveSilencesWithThreshold:threshold minDuration:minDur padding:pad];
}

- (void)performRemoveSilencesWithThreshold:(NSString *)threshold minDuration:(double)minDuration padding:(double)padding {
    NSPanel *hud = [self showProcessingHUD:@"Analyzing audio for silences..."];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *detector = [self findSilenceDetector];
            if (!detector) {
                [self dismissProcessingHUD:hud];
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSAlert *a = [[NSAlert alloc] init];
                    a.messageText = @"Silence Detector Not Found";
                    a.informativeText = @"Build it with:\n  cd ~/Desktop/SpliceKit && make tools";
                    a.alertStyle = NSAlertStyleWarning;
                    [a runModal];
                });
                return;
            }

            __block NSArray *items = nil;
            __block double fps = 24.0;
            SpliceKit_executeOnMainThread(^{
                extern NSDictionary *SpliceKit_handleTimelineGetDetailedState(NSDictionary *params);
                NSDictionary *s = SpliceKit_handleTimelineGetDetailedState(@{@"limit": @500});
                if (s[@"error"]) return;
                items = s[@"items"];
                if (s[@"frameRate"]) fps = [s[@"frameRate"] doubleValue];
            });

            if (!items.count) {
                [self dismissProcessingHUD:hud];
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSAlert *a = [[NSAlert alloc] init];
                    a.messageText = @"No Clips in Timeline";
                    [a runModal];
                });
                return;
            }

            NSString *minDurStr = [NSString stringWithFormat:@"%.2f", minDuration];
            NSString *padStr = [NSString stringWithFormat:@"%.2f", padding];

            NSMutableArray *silRanges = [NSMutableArray array];
            double tlOff = 0;
            NSInteger analyzed = 0;

            for (NSDictionary *item in items) {
                NSString *cls = item[@"class"] ?: @"";
                double dur = [item[@"duration"][@"seconds"] doubleValue];
                long long lane = [item[@"lane"] longLongValue];
                if (lane != 0 || [cls containsString:@"Transition"]) {
                    if (lane == 0) tlOff += dur;
                    continue;
                }
                NSString *mp = nil;
                NSString *handle = item[@"handle"];
                double trim = [item[@"trimmedOffset"][@"seconds"] doubleValue];
                if (handle) {
                    extern id SpliceKit_resolveHandle(NSString *handleId);
                    id obj = SpliceKit_resolveHandle(handle);
                    if (obj) {
                        @try {
                            id mediaObj = obj;
                            if ([cls containsString:@"Collection"]) {
                                id contained = [obj valueForKey:@"containedItems"];
                                if ([contained isKindOfClass:[NSArray class]] && [(NSArray *)contained count] > 0)
                                    mediaObj = [(NSArray *)contained objectAtIndex:0];
                            }
                            id media = [mediaObj valueForKey:@"media"];
                            if (media) {
                                id rep = [media valueForKey:@"originalMediaRep"];
                                if (rep) {
                                    id url = [rep valueForKey:@"fileURL"];
                                    if (url && [url respondsToSelector:@selector(path)])
                                        mp = ((id (*)(id, SEL))objc_msgSend)(url, @selector(path));
                                }
                            }
                        } @catch (NSException *e) {}
                    }
                }
                if (!mp || ![[NSFileManager defaultManager] fileExistsAtPath:mp]) {
                    tlOff += dur; continue;
                }

                NSTask *t = [[NSTask alloc] init];
                t.executableURL = [NSURL fileURLWithPath:detector];
                t.arguments = @[mp, @"--threshold", threshold, @"--min-duration", minDurStr,
                                @"--padding", padStr,
                                @"--start", [NSString stringWithFormat:@"%.4f", trim],
                                @"--end", [NSString stringWithFormat:@"%.4f", trim + dur]];
                NSPipe *op = [NSPipe pipe];
                t.standardOutput = op;
                t.standardError = [NSPipe pipe];
                NSError *e = nil;
                [t launchAndReturnError:&e];
                if (e) { tlOff += dur; continue; }
                [t waitUntilExit];

                if (t.terminationStatus == 0) {
                    NSData *d = [op.fileHandleForReading readDataToEndOfFile];
                    NSDictionary *r = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                    for (NSDictionary *rng in r[@"silentRanges"]) {
                        double ss = [rng[@"start"] doubleValue], se = [rng[@"end"] doubleValue];
                        double ts = MAX(tlOff + (ss - trim), tlOff);
                        double te = MIN(tlOff + (se - trim), tlOff + dur);
                        if (te > ts) [silRanges addObject:@{@"start": @(ts), @"end": @(te)}];
                    }
                    analyzed++;
                }
                tlOff += dur;
            }

            if (!silRanges.count) {
                [self dismissProcessingHUD:hud];
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSAlert *a = [[NSAlert alloc] init];
                    a.messageText = @"No Silences Found";
                    a.informativeText = [NSString stringWithFormat:
                        @"Analyzed %ld clip%@. No silent segments detected.\nThreshold: %@, Min: %@s",
                        (long)analyzed, analyzed==1?@"":@"s", threshold, minDurStr];
                    [a runModal];
                });
                return;
            }

            [silRanges sortUsingComparator:^(NSDictionary *a, NSDictionary *b) {
                return [b[@"start"] compare:a[@"start"]];
            }];

            __block NSInteger done = 0;
            NSInteger total = silRanges.count;
            SpliceKit_executeOnMainThread(^{
                id app = [NSApplication sharedApplication];
                SEL gs = @selector(gotoStart:), s10 = @selector(stepForward10Frames:), s1 = @selector(stepForward:);
                for (NSDictionary *rng in silRanges) {
                    double silEnd = [rng[@"end"] doubleValue], silStart = [rng[@"start"] doubleValue];
                    [app sendAction:gs to:nil from:nil];
                    int f = (int)round(silEnd * fps);
                    for (int j=0;j<f/10;j++) [app sendAction:s10 to:nil from:nil];
                    for (int j=0;j<f%10;j++) [app sendAction:s1 to:nil from:nil];
                    SpliceKit_handleTimelineAction(@{@"action": @"blade"});
                    [app sendAction:gs to:nil from:nil];
                    f = (int)round(silStart * fps);
                    for (int j=0;j<f/10;j++) [app sendAction:s10 to:nil from:nil];
                    for (int j=0;j<f%10;j++) [app sendAction:s1 to:nil from:nil];
                    SpliceKit_handleTimelineAction(@{@"action": @"blade"});
                    [NSThread sleepForTimeInterval:0.03];
                    SpliceKit_handleTimelineAction(@{@"action": @"selectClipAtPlayhead"});
                    SpliceKit_handleTimelineAction(@{@"action": @"delete"});
                    done++;
                }
            });

            [self dismissProcessingHUD:hud];
            double totSil = 0;
            for (NSDictionary *r in silRanges) totSil += [r[@"end"] doubleValue] - [r[@"start"] doubleValue];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *a = [[NSAlert alloc] init];
                a.messageText = @"Silences Removed";
                a.informativeText = [NSString stringWithFormat:
                    @"Removed %ld of %ld silent segment%@ (%.1fs total).\nThreshold: %@, Min: %@s, Pad: %@s\n\nUse Cmd+Z to undo.",
                    (long)done, (long)total, total==1?@"":@"s", totSil, threshold, minDurStr, padStr];
                a.alertStyle = NSAlertStyleInformational;
                [a runModal];
            });
        }
    });
}

#pragma mark - Scene Detection Options

- (void)showSceneDetectionOptionsPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSPanel *opts = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 340)
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
            backing:NSBackingStoreBuffered defer:NO];
        opts.title = @"Detect Scene Changes";
        [opts center];

        NSView *v = opts.contentView;
        CGFloat y = 300;

        // --- Action ---
        NSTextField *actLabel = [NSTextField labelWithString:@"Action:"];
        actLabel.frame = NSMakeRect(20, y, 140, 20);
        [v addSubview:actLabel];

        NSPopUpButton *actPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(165, y - 2, 190, 26) pullsDown:NO];
        [actPop addItemsWithTitles:@[@"Detect only (report count)", @"Add markers at changes", @"Blade at changes"]];
        [actPop selectItemAtIndex:1];
        [v addSubview:actPop];

        // --- Threshold ---
        y -= 40;
        NSTextField *threshLabel = [NSTextField labelWithString:@"Sensitivity:"];
        threshLabel.frame = NSMakeRect(20, y, 140, 20);
        [v addSubview:threshLabel];

        NSPopUpButton *threshPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(165, y - 2, 190, 26) pullsDown:NO];
        [threshPop addItemsWithTitles:@[@"0.10 (very sensitive)", @"0.15 (sensitive)", @"0.20 (moderate)", @"0.25", @"0.35 (default)", @"0.50 (only major changes)"]];
        [threshPop selectItemAtIndex:2];
        [v addSubview:threshPop];

        // --- Sample interval ---
        y -= 40;
        NSTextField *intLabel = [NSTextField labelWithString:@"Sample interval:"];
        intLabel.frame = NSMakeRect(20, y, 140, 20);
        [v addSubview:intLabel];

        NSPopUpButton *intPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(165, y - 2, 190, 26) pullsDown:NO];
        [intPop addItemsWithTitles:@[@"Every frame (precise)", @"0.05s", @"0.1s", @"0.2s (fast)", @"0.5s (very fast)"]];
        [intPop selectItemAtIndex:0];
        [v addSubview:intPop];

        // --- Description ---
        y -= 50;
        NSTextField *desc = [NSTextField wrappingLabelWithString:
            @"Sensitivity: How different adjacent frames must be to count as a scene change. "
            @"Lower values detect more subtle changes (camera moves, lighting shifts). "
            @"Higher values only detect hard cuts.\n\n"
            @"Sample interval: How often to compare frames. "
            @"\"Every frame\" is most accurate but slower on long clips."];
        desc.frame = NSMakeRect(20, 60, 340, 120);
        desc.font = [NSFont systemFontOfSize:11];
        desc.textColor = [NSColor secondaryLabelColor];
        [v addSubview:desc];

        // --- Buttons ---
        NSButton *cancelBtn = [NSButton buttonWithTitle:@"Cancel" target:opts action:@selector(close)];
        cancelBtn.frame = NSMakeRect(180, 15, 80, 32);
        cancelBtn.bezelStyle = NSBezelStyleRounded;
        [v addSubview:cancelBtn];

        NSButton *runBtn = [NSButton buttonWithTitle:@"Detect" target:self action:@selector(_sceneOptionsRun:)];
        runBtn.frame = NSMakeRect(270, 15, 90, 32);
        runBtn.bezelStyle = NSBezelStyleRounded;
        runBtn.keyEquivalent = @"\r";
        [v addSubview:runBtn];

        objc_setAssociatedObject(runBtn, "panel", opts, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(runBtn, "actPop", actPop, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(runBtn, "threshPop", threshPop, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(runBtn, "intPop", intPop, OBJC_ASSOCIATION_RETAIN);

        [opts makeKeyAndOrderFront:nil];
    });
}

- (void)_sceneOptionsRun:(NSButton *)sender {
    NSPanel *panel = objc_getAssociatedObject(sender, "panel");
    NSPopUpButton *actPop = objc_getAssociatedObject(sender, "actPop");
    NSPopUpButton *threshPop = objc_getAssociatedObject(sender, "threshPop");
    NSPopUpButton *intPop = objc_getAssociatedObject(sender, "intPop");

    NSArray *actVals = @[@"detect", @"markers", @"blade"];
    NSString *action = actVals[actPop.indexOfSelectedItem];

    NSArray *threshVals = @[@0.10, @0.15, @0.20, @0.25, @0.35, @0.50];
    double threshold = [threshVals[threshPop.indexOfSelectedItem] doubleValue];

    NSArray *intVals = @[@0.0, @0.05, @0.1, @0.2, @0.5];
    double interval = [intVals[intPop.indexOfSelectedItem] doubleValue];
    // 0.0 means every frame — pass a very small value
    if (interval < 0.001) interval = 0.001;

    [panel close];

    // Show processing HUD
    NSPanel *hud = [self showProcessingHUD:@"Detecting scene changes..."];

    // Run on background
    extern NSDictionary *SpliceKit_handleDetectSceneChanges(NSDictionary *params);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *r = SpliceKit_handleDetectSceneChanges(@{
            @"action": action,
            @"threshold": @(threshold),
            @"sampleInterval": @(interval),
        });
        [self dismissProcessingHUD:hud];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *a = [[NSAlert alloc] init];
            if (r[@"error"]) {
                a.messageText = @"Scene Detection Error";
                a.informativeText = r[@"error"];
                a.alertStyle = NSAlertStyleWarning;
            } else {
                NSUInteger count = [r[@"count"] unsignedIntegerValue];
                double dur = [r[@"duration"] doubleValue];
                NSString *actionDesc = @"detected";
                if ([action isEqualToString:@"markers"]) actionDesc = @"marked";
                else if ([action isEqualToString:@"blade"]) actionDesc = @"bladed";
                a.messageText = count > 0
                    ? [NSString stringWithFormat:@"Scene Changes %@", [actionDesc capitalizedString]]
                    : @"No Scene Changes Found";
                a.informativeText = [NSString stringWithFormat:
                    @"%lu scene change%@ %@ in %.1fs of media.\n\nSensitivity: %.2f, Interval: %.2fs",
                    (unsigned long)count, count == 1 ? @"" : @"s", actionDesc, dur, threshold, interval];
                if (count == 0) {
                    a.informativeText = [a.informativeText stringByAppendingString:
                        @"\n\nTry lowering the sensitivity value to detect more subtle changes."];
                }
            }
            [a runModal];
        });
    });
}

#pragma mark - Favorites

static NSString *FCPFavoriteKey(NSString *type, NSString *action) {
    return [NSString stringWithFormat:@"%@::%@", type, action];
}

- (void)loadFavorites {
    NSArray *dicts = [[NSUserDefaults standardUserDefaults] arrayForKey:kSpliceKitFavoritesKey];
    _favoriteKeys = [NSMutableSet set];
    for (NSDictionary *d in dicts) {
        NSString *key = FCPFavoriteKey(d[@"type"], d[@"action"]);
        if (key) [_favoriteKeys addObject:key];
    }
}

- (void)saveFavorites {
    // favoriteKeys is the source of truth for membership; rebuild dicts from stored array + any additions
    // We keep the full dicts in NSUserDefaults for name/category metadata
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSArray<NSDictionary *> *)allFavoriteDicts {
    return [[NSUserDefaults standardUserDefaults] arrayForKey:kSpliceKitFavoritesKey] ?: @[];
}

- (BOOL)isFavorite:(SpliceKitCommand *)cmd {
    if (!cmd.type || !cmd.action) return NO;
    return [self.favoriteKeys containsObject:FCPFavoriteKey(cmd.type, cmd.action)];
}

- (void)addFavorite:(SpliceKitCommand *)cmd {
    NSString *key = FCPFavoriteKey(cmd.type, cmd.action);
    if ([self.favoriteKeys containsObject:key]) return; // already favorited
    [self.favoriteKeys addObject:key];

    NSMutableArray *dicts = [[self allFavoriteDicts] mutableCopy];
    [dicts addObject:@{
        @"type": cmd.type ?: @"",
        @"action": cmd.action ?: @"",
        @"name": cmd.name ?: @"",
        @"categoryName": cmd.categoryName ?: @"",
    }];
    [[NSUserDefaults standardUserDefaults] setObject:dicts forKey:kSpliceKitFavoritesKey];
}

- (void)removeFavorite:(SpliceKitCommand *)cmd {
    NSString *key = FCPFavoriteKey(cmd.type, cmd.action);
    [self.favoriteKeys removeObject:key];

    NSMutableArray *dicts = [[self allFavoriteDicts] mutableCopy];
    NSIndexSet *toRemove = [dicts indexesOfObjectsPassingTest:^BOOL(NSDictionary *d, NSUInteger idx, BOOL *stop) {
        return [FCPFavoriteKey(d[@"type"], d[@"action"]) isEqualToString:key];
    }];
    [dicts removeObjectsAtIndexes:toRemove];
    [[NSUserDefaults standardUserDefaults] setObject:dicts forKey:kSpliceKitFavoritesKey];
}

- (SpliceKitCommand *)commandForDisplayRow:(NSInteger)row {
    NSInteger cmdIdx = row;
    if (self.aiLoading || self.aiResults.count > 0) cmdIdx -= 1;
    if (cmdIdx < 0 || cmdIdx >= (NSInteger)self.filteredCommands.count) return nil;
    return self.filteredCommands[cmdIdx];
}

- (NSMenu *)contextMenuForRow:(NSInteger)row {
    // Unused — context menu is now handled by menuNeedsUpdate: delegate
    return nil;
}

#pragma mark - NSMenuDelegate (right-click context menu)

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];

    NSInteger row = self.tableView.clickedRow;
    if (row < 0) return;

    SpliceKitCommand *cmd = [self commandForDisplayRow:row];
    if (!cmd || cmd.isSeparatorRow) return;
    if (!self.inBrowseMode) return;

    static NSSet *favoritableTypes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        favoritableTypes = [NSSet setWithArray:@[
            @"effect_apply", @"transition_apply", @"generator_apply", @"title_apply"
        ]];
    });
    if (![favoritableTypes containsObject:cmd.type]) return;

    BOOL isFav = [self isFavorite:cmd];
    NSMenuItem *item = [[NSMenuItem alloc]
        initWithTitle:isFav ? @"Remove from Favorites" : @"Add to Favorites"
               action:@selector(toggleFavoriteFromMenu:)
        keyEquivalent:@""];
    item.target = self;
    item.representedObject = cmd;
    [menu addItem:item];
}

- (void)toggleFavoriteFromMenu:(NSMenuItem *)sender {
    SpliceKitCommand *cmd = sender.representedObject;
    if ([self isFavorite:cmd]) {
        [self removeFavorite:cmd];
    } else {
        [self addFavorite:cmd];
    }
    [self rebuildBrowseModeListWithFavorites];
}

- (void)injectFavoritesIntoCurrentList {
    if (!self.rawBrowseCommands || self.rawBrowseCommands.count == 0) return;

    NSMutableArray<SpliceKitCommand *> *favoriteCmds = [NSMutableArray array];
    NSMutableArray<SpliceKitCommand *> *regularCmds = [NSMutableArray array];

    for (SpliceKitCommand *cmd in self.rawBrowseCommands) {
        BOOL isFav = [self isFavorite:cmd];
        if (isFav) {
            // Create a copy for the favorites section
            SpliceKitCommand *favCopy = [[SpliceKitCommand alloc] init];
            favCopy.name = cmd.name;
            favCopy.action = cmd.action;
            favCopy.type = cmd.type;
            favCopy.category = cmd.category;
            favCopy.categoryName = cmd.categoryName;
            favCopy.shortcut = cmd.shortcut;
            favCopy.detail = cmd.detail;
            favCopy.keywords = cmd.keywords;
            favCopy.isFavoritedItem = YES;
            [favoriteCmds addObject:favCopy];
        }
        // Mark the original too so the star shows in the main list
        cmd.isFavoritedItem = isFav;
        [regularCmds addObject:cmd];
    }

    if (favoriteCmds.count > 0) {
        NSMutableArray *combined = [NSMutableArray array];
        [combined addObjectsFromArray:favoriteCmds];

        // Add separator
        SpliceKitCommand *separator = [[SpliceKitCommand alloc] init];
        separator.isSeparatorRow = YES;
        separator.name = @"";
        [combined addObject:separator];

        [combined addObjectsFromArray:regularCmds];
        self.allCommands = combined;
    } else {
        self.allCommands = regularCmds;
    }
    self.filteredCommands = self.allCommands;
}

- (void)rebuildBrowseModeListWithFavorites {
    [self injectFavoritesIntoCurrentList];
    NSString *query = self.searchField.stringValue;
    if (query.length > 0) {
        // When searching, use raw list (no favorites section) to avoid duplicates
        self.filteredCommands = [self searchCommandsInArray:self.rawBrowseCommands query:query];
    }
    [self.tableView reloadData];
    if (self.filteredCommands.count > 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                    byExtendingSelection:NO];
    }
}

- (NSArray<SpliceKitCommand *> *)searchCommandsInArray:(NSArray<SpliceKitCommand *> *)commands query:(NSString *)query {
    if (query.length == 0) return commands;

    NSMutableArray<SpliceKitCommand *> *results = [NSMutableArray array];
    for (SpliceKitCommand *cmd in commands) {
        if (cmd.isSeparatorRow) continue;
        CGFloat nameScore = FCPFuzzyScore(query, cmd.name);
        CGFloat keywordScore = 0;
        for (NSString *kw in cmd.keywords) {
            CGFloat s = FCPFuzzyScore(query, kw);
            if (s > keywordScore) keywordScore = s;
        }
        CGFloat catScore = FCPFuzzyScore(query, cmd.categoryName) * 0.5;
        CGFloat detailScore = FCPFuzzyScore(query, cmd.detail) * 0.3;
        CGFloat best = MAX(MAX(nameScore, keywordScore), MAX(catScore, detailScore));
        if (best > 0.2) {
            cmd.score = best;
            cmd.isFavoritedItem = [self isFavorite:cmd];
            [results addObject:cmd];
        }
    }
    [results sortUsingComparator:^NSComparisonResult(SpliceKitCommand *a, SpliceKitCommand *b) {
        if (a.score > b.score) return NSOrderedAscending;
        if (a.score < b.score) return NSOrderedDescending;
        return [a.name compare:b.name];
    }];
    return results;
}

- (void)exitBrowseMode {
    self.inBrowseMode = NO;
    self.rawBrowseCommands = nil;
    self.allCommands = self.masterCommands;
    self.searchField.stringValue = @"";
    self.searchField.placeholderString = @"Type a command or describe what you want to do...";
    self.filteredCommands = self.allCommands;
    [self.tableView reloadData];
    [self updateStatusLabel];
    if (self.filteredCommands.count > 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                    byExtendingSelection:NO];
    }
}

#pragma mark - SpliceKit Options Panel

- (void)showBridgeOptionsPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSPanel *opts = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 290)
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
            backing:NSBackingStoreBuffered defer:NO];
        opts.title = @"SpliceKit Options";
        [opts center];

        NSView *v = opts.contentView;
        CGFloat y = 245;

        // --- Effect Drag as Adjustment Clip ---
        NSButton *effectDragCheck = [NSButton checkboxWithTitle:@"Effect Drag as Adjustment Clip"
                                                         target:self
                                                         action:@selector(_bridgeOptionEffectDragToggled:)];
        effectDragCheck.frame = NSMakeRect(20, y, 340, 20);
        effectDragCheck.state = SpliceKit_isEffectDragAsAdjustmentClipEnabled()
            ? NSControlStateValueOn : NSControlStateValueOff;
        objc_setAssociatedObject(effectDragCheck, "panel", opts, OBJC_ASSOCIATION_RETAIN);
        [v addSubview:effectDragCheck];

        y -= 22;
        NSTextField *effectDragDesc = [NSTextField wrappingLabelWithString:
            @"Allow dragging a video effect from the Effects Browser into empty space above a clip "
            @"to create an adjustment clip with that effect applied."];
        effectDragDesc.frame = NSMakeRect(38, y - 38, 320, 48);
        effectDragDesc.font = [NSFont systemFontOfSize:11];
        effectDragDesc.textColor = [NSColor secondaryLabelColor];
        [v addSubview:effectDragDesc];

        y -= 72;

        // --- Viewer Pinch-to-Zoom ---
        NSButton *pinchCheck = [NSButton checkboxWithTitle:@"Viewer Pinch-to-Zoom"
                                                    target:self
                                                    action:@selector(_bridgeOptionPinchZoomToggled:)];
        pinchCheck.frame = NSMakeRect(20, y, 340, 20);
        pinchCheck.state = SpliceKit_isViewerPinchZoomEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
        objc_setAssociatedObject(pinchCheck, "panel", opts, OBJC_ASSOCIATION_RETAIN);
        [v addSubview:pinchCheck];

        y -= 22;
        NSTextField *pinchDesc = [NSTextField wrappingLabelWithString:
            @"Use trackpad pinch gestures to zoom the viewer. "
            @"Supports any zoom level, not just the preset percentages."];
        pinchDesc.frame = NSMakeRect(38, y - 30, 320, 40);
        pinchDesc.font = [NSFont systemFontOfSize:11];
        pinchDesc.textColor = [NSColor secondaryLabelColor];
        [v addSubview:pinchDesc];

        // --- Close button ---
        NSButton *closeBtn = [NSButton buttonWithTitle:@"Done" target:opts action:@selector(close)];
        closeBtn.frame = NSMakeRect(280, 15, 80, 32);
        closeBtn.bezelStyle = NSBezelStyleRounded;
        closeBtn.keyEquivalent = @"\r";
        [v addSubview:closeBtn];

        [opts makeKeyAndOrderFront:nil];
    });
}

- (void)_bridgeOptionPinchZoomToggled:(NSButton *)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    SpliceKit_setViewerPinchZoomEnabled(enabled);
}

- (void)_bridgeOptionEffectDragToggled:(NSButton *)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    SpliceKit_setEffectDragAsAdjustmentClipEnabled(enabled);
}

- (void)enterTransitionBrowseMode {
    // Show loading state immediately
    self.inBrowseMode = YES;
    self.allCommands = @[];
    self.filteredCommands = @[];
    self.searchField.stringValue = @"";
    self.searchField.placeholderString = @"Loading transitions...";
    [self.tableView reloadData];
    self.statusLabel.stringValue = @"Loading transitions...";

    // Fetch transitions on background thread
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            extern NSDictionary *SpliceKit_handleTransitionsList(NSDictionary *params);
            NSDictionary *r = SpliceKit_handleTransitionsList(@{});
            NSArray *transitions = r[@"transitions"];

            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (!transitions || transitions.count == 0) {
                        self.statusLabel.stringValue = r[@"error"] ?: @"No transitions found";
                        self.searchField.placeholderString = @"No transitions available. Esc to go back.";
                        return;
                    }

                    // Build command list from transitions
                    NSMutableArray<SpliceKitCommand *> *cmds = [NSMutableArray array];
                    for (NSDictionary *t in transitions) {
                        SpliceKitCommand *cmd = [[SpliceKitCommand alloc] init];
                        cmd.name = t[@"name"] ?: @"Unknown";
                        cmd.action = t[@"effectID"] ?: @"";
                        cmd.type = @"transition_apply";
                        cmd.category = SpliceKitCommandCategoryEffects;
                        cmd.categoryName = t[@"category"] ?: @"Transitions";
                        cmd.shortcut = @"";
                        cmd.detail = [NSString stringWithFormat:@"Apply %@ transition", t[@"name"]];
                        cmd.keywords = @[];
                        [cmds addObject:cmd];
                    }

                    self.rawBrowseCommands = cmds;
                    [self injectFavoritesIntoCurrentList];
                    self.searchField.placeholderString = @"Search transitions...";
                    [self.tableView reloadData];
                    self.statusLabel.stringValue = [NSString stringWithFormat:
                        @"%lu transitions | Type to filter | Right-click to favorite | Esc to go back", (unsigned long)cmds.count];

                    if (self.filteredCommands.count > 0) {
                        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                                    byExtendingSelection:NO];
                    }
                } @catch (NSException *e) {
                    SpliceKit_log(@"Exception populating transitions: %@", e.reason);
                    self.statusLabel.stringValue = [NSString stringWithFormat:@"Error: %@", e.reason];
                }
            });
        } @catch (NSException *e) {
            SpliceKit_log(@"Exception fetching transitions: %@", e.reason);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Error: %@", e.reason];
                self.searchField.placeholderString = @"Error loading transitions. Esc to go back.";
            });
        }
    });
}

- (void)enterEffectBrowseMode:(NSString *)effectType {
    // Show loading state
    self.inBrowseMode = YES;
    self.allCommands = @[];
    self.filteredCommands = @[];
    self.searchField.stringValue = @"";

    NSDictionary *labels = @{
        @"filter": @"effects",
        @"generator": @"generators",
        @"title": @"titles",
        @"audio": @"audio effects",
    };
    NSString *label = labels[effectType] ?: @"effects";
    self.searchField.placeholderString = [NSString stringWithFormat:@"Loading %@...", label];
    [self.tableView reloadData];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Loading %@...", label];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            extern NSDictionary *SpliceKit_handleEffectsListAvailable(NSDictionary *params);
            NSDictionary *r = SpliceKit_handleEffectsListAvailable(@{@"type": effectType});
            NSArray *effects = r[@"effects"];

            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (!effects || effects.count == 0) {
                        self.statusLabel.stringValue = r[@"error"] ?: [NSString stringWithFormat:@"No %@ found", label];
                        self.searchField.placeholderString = [NSString stringWithFormat:@"No %@ available. Esc to go back.", label];
                        return;
                    }

                    NSMutableArray<SpliceKitCommand *> *cmds = [NSMutableArray array];
                    for (NSDictionary *e in effects) {
                        SpliceKitCommand *cmd = [[SpliceKitCommand alloc] init];
                        cmd.name = e[@"name"] ?: @"Unknown";
                        cmd.action = e[@"effectID"] ?: @"";
                        // Titles and generators are connected to the timeline via pasteboard,
                        // not applied as filters to selected clips
                        NSString *effType = e[@"type"] ?: @"filter";
                        if ([effType isEqualToString:@"title"]) {
                            cmd.type = @"title_apply";
                        } else if ([effType isEqualToString:@"generator"]) {
                            cmd.type = @"generator_apply";
                        } else {
                            cmd.type = @"effect_apply";
                        }
                        cmd.category = SpliceKitCommandCategoryEffects;
                        cmd.categoryName = e[@"category"] ?: label;
                        cmd.shortcut = @"";
                        cmd.detail = [NSString stringWithFormat:@"Apply %@", e[@"name"]];
                        cmd.keywords = @[];
                        [cmds addObject:cmd];
                    }

                    self.rawBrowseCommands = cmds;
                    [self injectFavoritesIntoCurrentList];
                    self.searchField.placeholderString = [NSString stringWithFormat:@"Search %@...", label];
                    [self.tableView reloadData];
                    self.statusLabel.stringValue = [NSString stringWithFormat:
                        @"%lu %@ | Type to filter | Right-click to favorite | Esc to go back", (unsigned long)cmds.count, label];

                    if (self.filteredCommands.count > 0) {
                        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                                    byExtendingSelection:NO];
                    }
                } @catch (NSException *e) {
                    SpliceKit_log(@"Exception populating effects: %@", e.reason);
                    self.statusLabel.stringValue = [NSString stringWithFormat:@"Error: %@", e.reason];
                }
            });
        } @catch (NSException *e) {
            SpliceKit_log(@"Exception fetching effects: %@", e.reason);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Error: %@", e.reason];
            });
        }
    });
}

- (void)enterFavoritesBrowseMode {
    self.inBrowseMode = YES;
    self.searchField.stringValue = @"";
    self.searchField.placeholderString = @"Search favorites...";

    NSMutableArray<SpliceKitCommand *> *cmds = [NSMutableArray array];
    for (SpliceKitCommand *cmd in self.masterCommands ?: self.allCommands) {
        if (!cmd || cmd.isSeparatorRow) continue;
        if ([self isFavorite:cmd]) {
            [cmds addObject:cmd];
        }
    }

    self.rawBrowseCommands = cmds;
    [self injectFavoritesIntoCurrentList];
    [self.tableView reloadData];

    if (cmds.count == 0) {
        self.statusLabel.stringValue = @"No favorites yet";
        self.searchField.placeholderString = @"No favorites yet. Esc to go back.";
        return;
    }

    self.statusLabel.stringValue = [NSString stringWithFormat:
        @"%lu favorites | Type to filter | Right-click to unfavorite | Esc to go back",
        (unsigned long)cmds.count];
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                    byExtendingSelection:NO];
}

- (NSString *)extractKeywordFromQuery:(NSString *)query {
    // Strip common filler words to get the meaningful keyword
    NSSet *stopWords = [NSSet setWithArray:@[
        @"add", @"apply", @"put", @"use", @"set", @"make", @"do", @"get", @"show",
        @"a", @"an", @"the", @"some", @"my", @"this", @"that", @"it",
        @"to", @"on", @"in", @"for", @"with", @"of",
        @"effect", @"effects", @"filter", @"transition", @"transitions",
        @"clip", @"video", @"audio", @"please", @"want", @"need", @"like",
        @"i", @"me", @"can", @"you",
    ]];
    NSArray *words = [[query lowercaseString] componentsSeparatedByCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *keywords = [NSMutableArray array];
    for (NSString *word in words) {
        if (word.length > 1 && ![stopWords containsObject:word]) {
            [keywords addObject:word];
        }
    }
    return keywords.count > 0 ? [keywords componentsJoinedByString:@" "] : nil;
}

- (void)showMatchingEffects:(NSString *)keyword type:(NSString *)effectType {
    // Search installed effects/transitions matching the keyword and show as selectable rows
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            NSDictionary *r;
            NSString *applyType;
            if ([effectType isEqualToString:@"transition"]) {
                extern NSDictionary *SpliceKit_handleTransitionsList(NSDictionary *params);
                r = SpliceKit_handleTransitionsList(@{@"filter": keyword});
                applyType = @"transition_apply";
            } else {
                extern NSDictionary *SpliceKit_handleEffectsListAvailable(NSDictionary *params);
                r = SpliceKit_handleEffectsListAvailable(@{@"type": effectType, @"filter": keyword});
                applyType = @"effect_apply";
            }

            NSArray *items = r[@"effects"] ?: r[@"transitions"] ?: @[];

            dispatch_async(dispatch_get_main_queue(), ^{
                if (items.count == 0) {
                    // No matches — show the AI result as-is
                    self.statusLabel.stringValue = [NSString stringWithFormat:
                        @"No %@s found matching '%@'", effectType, keyword];
                    return;
                }

                self.inBrowseMode = YES;
                NSMutableArray<SpliceKitCommand *> *cmds = [NSMutableArray array];
                for (NSDictionary *item in items) {
                    SpliceKitCommand *cmd = [[SpliceKitCommand alloc] init];
                    cmd.name = item[@"name"] ?: @"Unknown";
                    cmd.action = item[@"effectID"] ?: @"";
                    cmd.type = applyType;
                    cmd.category = SpliceKitCommandCategoryEffects;
                    cmd.categoryName = item[@"category"] ?: effectType;
                    cmd.shortcut = @"";
                    cmd.detail = [NSString stringWithFormat:@"Apply %@", item[@"name"]];
                    cmd.keywords = @[];
                    [cmds addObject:cmd];
                }

                self.rawBrowseCommands = cmds;
                [self injectFavoritesIntoCurrentList];
                self.aiResults = nil;
                self.aiError = nil;
                self.searchField.placeholderString = [NSString stringWithFormat:@"Showing %@s matching '%@'... Esc to go back", effectType, keyword];
                [self.tableView reloadData];
                self.statusLabel.stringValue = [NSString stringWithFormat:
                    @"%lu match%@ for '%@' | Return to apply | Esc to go back",
                    (unsigned long)cmds.count, cmds.count == 1 ? @"" : @"es", keyword];

                if (self.filteredCommands.count > 0) {
                    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                                byExtendingSelection:NO];
                }
            });
        } @catch (NSException *e) {
            SpliceKit_log(@"Exception in showMatchingEffects: %@", e.reason);
        }
    });
}

- (void)executeAIResults:(NSArray<NSDictionary *> *)actions {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self executeActionList:actions];
    });
}

- (void)executeActionList:(NSArray<NSDictionary *> *)actions {
    for (NSDictionary *action in actions) {
        NSString *type = action[@"type"] ?: @"timeline";
        NSString *name = action[@"action"];
        NSNumber *repeatCount = action[@"repeat"];

        // Handle repeat_pattern: loop through inner actions N times
        if ([type isEqualToString:@"repeat_pattern"]) {
            int patternCount = [action[@"count"] intValue];
            NSArray *innerActions = action[@"actions"];
            if (patternCount > 0 && [innerActions isKindOfClass:[NSArray class]]) {
                SpliceKit_log(@"Executing repeat_pattern x%d (%lu inner actions)",
                              patternCount, (unsigned long)innerActions.count);
                for (int p = 0; p < patternCount; p++) {
                    [self executeActionList:innerActions];
                }
            }
            continue;
        }

        // Handle seek: {"type":"seek","seconds":3.0}
        if ([type isEqualToString:@"seek"]) {
            NSNumber *secs = action[@"seconds"];
            if (secs) {
                extern NSDictionary *SpliceKit_handlePlaybackSeek(NSDictionary *params);
                SpliceKit_handlePlaybackSeek(@{@"seconds": secs});
            }
            continue;
        }

        // Handle effect apply: {"type":"effect","name":"Keyer"}
        if ([type isEqualToString:@"effect"]) {
            NSString *effectName = action[@"name"];
            if (effectName) {
                // Select clip first
                [self executeCommand:@"selectClipAtPlayhead" type:@"timeline"];
                [NSThread sleepForTimeInterval:0.1];
                // Apply the effect
                [self executeCommand:effectName type:@"effect_apply_by_name"];
            }
            continue;
        }

        // Handle transition apply: {"type":"transition","name":"Flow"}
        if ([type isEqualToString:@"transition"]) {
            NSString *transitionName = action[@"name"];
            if (transitionName) {
                extern NSDictionary *SpliceKit_handleTransitionsApply(NSDictionary *params);
                SpliceKit_handleTransitionsApply(@{@"name": transitionName});
                SpliceKit_log(@"AI applied transition: %@", transitionName);
            }
            continue;
        }

        int repeats = repeatCount ? repeatCount.intValue : 1;
        for (int i = 0; i < repeats; i++) {
            [self executeCommand:name type:type];
            if (repeats > 1 && i < repeats - 1) {
                [NSThread sleepForTimeInterval:0.03];
            }
        }
    }
}

#pragma mark - Apple Intelligence (FoundationModels)

- (void)triggerAI:(NSString *)query {
    if (self.aiLoading) return;
    // Don't re-trigger if we already have results for this exact query
    if ([query isEqualToString:self.aiCompletedQuery] && self.aiResults.count > 0) return;

    self.aiLoading = YES;
    self.aiQuery = query;
    self.aiResults = nil;
    self.aiError = nil;
    [self.tableView reloadData];
    [self updateStatusLabel];

    [self executeNaturalLanguage:query completion:^(NSArray<NSDictionary *> *actions, NSString *error) {
        self.aiLoading = NO;
        // Only apply results if the query hasn't changed while we were waiting
        if (![query isEqualToString:self.searchField.stringValue]) return;

        if (error) {
            self.aiError = error;
            self.aiResults = nil;
        } else {
            // Check if the AI result is a single effect or transition request —
            // if so, search installed effects/transitions and show all matches
            if (actions.count == 1) {
                NSDictionary *act = actions[0];
                NSString *actType = act[@"type"];
                NSString *actName = act[@"name"];
                if (actName && ([actType isEqualToString:@"effect"] || [actType isEqualToString:@"transition"])) {
                    self.aiCompletedQuery = query;
                    self.aiLoading = NO;
                    NSString *filterType = [actType isEqualToString:@"transition"] ? @"transition" : @"filter";
                    // Extract keyword from user query for broader search
                    NSString *keyword = [self extractKeywordFromQuery:query];
                    [self showMatchingEffects:keyword ?: actName type:filterType];
                    return;
                }
            }
            self.aiResults = actions;
            self.aiError = nil;
            self.aiCompletedQuery = query;
        }
        [self.tableView reloadData];
        [self updateStatusLabel];
        if (self.aiResults.count > 0) {
            [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                        byExtendingSelection:NO];
        }
    }];
}

- (NSDictionary *)getTimelineContext {
    // Fetch timeline state to give the LLM context about duration, fps, clip count
    extern NSDictionary *SpliceKit_handleTimelineGetDetailedState(NSDictionary *params);
    __block NSDictionary *state = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            state = SpliceKit_handleTimelineGetDetailedState(@{@"limit": @(5)});
        } @catch (NSException *e) {
            SpliceKit_log(@"Failed to get timeline context: %@", e.reason);
        }
    });
    if (!state || state[@"error"]) return nil;

    NSMutableDictionary *ctx = [NSMutableDictionary dictionary];
    NSDictionary *dur = state[@"duration"];
    NSDictionary *playhead = state[@"playheadTime"];
    if (dur[@"seconds"]) ctx[@"durationSeconds"] = dur[@"seconds"];
    if (dur[@"timescale"]) ctx[@"timescale"] = dur[@"timescale"];
    if (playhead[@"seconds"]) ctx[@"playheadSeconds"] = playhead[@"seconds"];
    if (state[@"itemCount"]) ctx[@"clipCount"] = state[@"itemCount"];
    if (state[@"sequenceName"]) ctx[@"sequenceName"] = state[@"sequenceName"];

    // Derive fps from timescale (common: 24000/1001=23.976, 30000/1001=29.97, 24, 30, 60)
    NSNumber *timescale = dur[@"timescale"];
    if (timescale) {
        int ts = timescale.intValue;
        int fps = 24; // default
        if (ts == 30000 || ts == 30) fps = 30;
        else if (ts == 60000 || ts == 60) fps = 60;
        else if (ts == 25 || ts == 25000) fps = 25;
        else if (ts == 24000 || ts == 24) fps = 24;
        ctx[@"fps"] = @(fps);
    }
    return ctx;
}

- (void)executeNaturalLanguage:(NSString *)query
                    completion:(void(^)(NSArray<NSDictionary *> *actions, NSString *error))completion {

    // Fetch timeline context (duration, fps, clip count) for the LLM
    NSDictionary *timelineCtx = [self getTimelineContext];

    // Build a Swift script that uses FoundationModels (Apple Intelligence)
    NSString *swiftScript = [self buildSwiftScript:query timelineContext:timelineCtx];

    // Write script to temp file
    NSString *scriptPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_ai.swift"];
    NSError *writeError = nil;
    [swiftScript writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    if (writeError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSString stringWithFormat:@"Failed to write script: %@", writeError.localizedDescription]);
        });
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/swift"];
        task.arguments = @[scriptPath];

        NSPipe *outputPipe = [NSPipe pipe];
        NSPipe *errorPipe = [NSPipe pipe];
        task.standardOutput = outputPipe;
        task.standardError = errorPipe;

        NSError *launchError = nil;
        [task launchAndReturnError:&launchError];
        if (launchError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSString stringWithFormat:@"Failed to launch AI: %@", launchError.localizedDescription]);
            });
            return;
        }

        [task waitUntilExit];

        NSData *outputData = [outputPipe.fileHandleForReading readDataToEndOfFile];
        NSData *errorData = [errorPipe.fileHandleForReading readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
        NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];

        if (task.terminationStatus != 0) {
            // If FoundationModels isn't available, fall back to keyword matching
            SpliceKit_log(@"AI script failed (status %d): %@", task.terminationStatus, errorOutput);
            NSArray *fallback = [self keywordFallback:query];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (fallback.count > 0) {
                    completion(fallback, nil);
                } else {
                    completion(nil, @"Apple Intelligence not available. Try a more specific command name.");
                }
            });
            return;
        }

        // Parse JSON output
        output = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        // Extract JSON from output (may have extra text around it)
        NSRange jsonStart = [output rangeOfString:@"["];
        NSRange jsonEnd = [output rangeOfString:@"]" options:NSBackwardsSearch];
        if (jsonStart.location != NSNotFound && jsonEnd.location != NSNotFound) {
            NSRange jsonRange = NSMakeRange(jsonStart.location,
                                            jsonEnd.location - jsonStart.location + 1);
            output = [output substringWithRange:jsonRange];
        }

        NSError *jsonError = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:[output dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:0 error:&jsonError];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (jsonError || ![parsed isKindOfClass:[NSArray class]]) {
                // Try keyword fallback
                NSArray *fallback = [self keywordFallback:query];
                if (fallback.count > 0) {
                    completion(fallback, nil);
                } else if ([parsed isKindOfClass:[NSDictionary class]] && parsed[@"error"]) {
                    completion(nil, parsed[@"error"]);
                } else {
                    completion(nil, [NSString stringWithFormat:@"Could not parse AI response: %@",
                                    output.length > 100 ? [output substringToIndex:100] : output]);
                }
                return;
            }
            completion(parsed, nil);
        });
    });
}

- (NSString *)buildSwiftScript:(NSString *)query timelineContext:(NSDictionary *)ctx {
    // Escape the query for embedding in Swift string
    NSString *escaped = [[query stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                          stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

    // Build timeline context string for the prompt
    NSString *timelineInfo = @"No timeline info available.";
    if (ctx) {
        double duration = [ctx[@"durationSeconds"] doubleValue];
        double playhead = [ctx[@"playheadSeconds"] doubleValue];
        int fps = [ctx[@"fps"] intValue] ?: 24;
        int clips = [ctx[@"clipCount"] intValue];
        int totalFrames = (int)(duration * fps);
        timelineInfo = [NSString stringWithFormat:
            @"Current timeline: duration=%.2fs (%d frames), fps=%d, playhead=%.2fs, clips=%d",
            duration, totalFrames, fps, playhead, clips];
    }
    NSString *escapedCtx = [[timelineInfo stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                             stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

    return [NSString stringWithFormat:@
        "import Foundation\n"
        "import FoundationModels\n"
        "\n"
        "let query = \"%@\"\n"
        "let timelineContext = \"%@\"\n"
        "\n"
        "let instructions = \"\"\"\n"
        "You are a Final Cut Pro command interpreter. Given a natural language video editing instruction,\n"
        "return ONLY a JSON array of actions to execute. No explanation, no markdown, just the JSON array.\n"
        "\n"
        "Available action types:\n"
        "1. {\"type\":\"timeline\",\"action\":\"NAME\"} where NAME is one of:\n"
        "   blade, bladeAll, delete, cut, copy, paste, undo, redo, selectAll, deselectAll,\n"
        "   selectClipAtPlayhead, selectToPlayhead, trimToPlayhead, insertGap,\n"
        "   addMarker, addTodoMarker, addChapterMarker, deleteMarker, deleteMarkersInSelection, nextMarker, previousMarker,\n"
        "   addTransition, nextEdit, previousEdit,\n"
        "   addColorBoard, addColorWheels, addColorCurves, addColorAdjustment, addHueSaturation, addEnhanceLightAndColor,\n"
        "   adjustVolumeUp, adjustVolumeDown, addBasicTitle, addBasicLowerThird,\n"
        "   retimeNormal, retimeFast2x, retimeFast4x, retimeFast8x, retimeFast20x,\n"
        "   retimeSlow50, retimeSlow25, retimeSlow10, retimeReverse, retimeHold, freezeFrame, retimeBladeSpeed,\n"
        "   addKeyframe, deleteKeyframes, nextKeyframe, previousKeyframe,\n"
        "   solo, disable, createCompoundClip, removeEffects, detachAudio, breakApartClipItems,\n"
        "   zoomToFit, zoomIn, zoomOut, toggleSnapping, toggleSkimming, renderSelection, renderAll,\n"
        "   analyzeAndFix, exportXML, shareSelection, autoReframe, addVideoGenerator\n"
        "\n"
        "2. {\"type\":\"playback\",\"action\":\"NAME\"} where NAME is one of:\n"
        "   playPause, goToStart, goToEnd, nextFrame, prevFrame, nextFrame10, prevFrame10\n"
        "\n"
        "3. {\"type\":\"seek\",\"seconds\":N} - Move playhead to exact time N (in seconds).\n"
        "   This is INSTANT — no playback. Use this for ALL time-based positioning.\n"
        "   Examples: {\"type\":\"seek\",\"seconds\":0} = go to start,\n"
        "   {\"type\":\"seek\",\"seconds\":3.5} = go to 3.5 seconds\n"
        "\n"
        "4. {\"type\":\"effect\",\"name\":\"EFFECT_NAME\"} - Apply a specific video effect by name.\n"
        "   Automatically selects the clip at playhead first.\n"
        "   Common effects: Gaussian Blur, Sharpen, Keyer, Luma Keyer, Chroma Keyer,\n"
        "   Vignette, Noise Reduction, Broadcast Safe, Letterbox, Flipped, Black & White,\n"
        "   Sepia, Aged Film, Bad TV, Prism, Underwater, Night Vision, X-Ray,\n"
        "   Tilt-Shift, Bloom, Glow, Gloom, Pixellate, Posterize, Invert,\n"
        "   Draw Mask, Shape Mask, Stabilization, Rolling Shutter,\n"
        "   Color Correction, Custom LUT, Bump Map, Light Wrap, Drop Shadow\n"
        "\n"
        "4. {\"type\":\"transition\",\"name\":\"TRANSITION_NAME\"} - Apply a specific transition.\n"
        "   Common transitions: Cross Dissolve, Flow, Fade To Color, Wipe, Push,\n"
        "   Slide, Spin, Doorway, Page Curl, Star, Band, Zoom\n"
        "\n"
        "6. Add \"repeat\":N to repeat an action N times\n"
        "\n"
        "7. {\"type\":\"repeat_pattern\",\"count\":N,\"actions\":[...]} - Repeat inner actions N times.\n"
        "   For time-based repeats, use seek with computed times instead of frame stepping.\n"
        "\n"
        "Key knowledge:\n"
        "- ALWAYS use {\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":N} to move the playhead. NEVER use nextFrame with repeat.\n"
        "- seek is instant. No playback needed. seek seconds=0 goes to start.\n"
        "- For effects: {\\\"type\\\":\\\"effect\\\",\\\"name\\\":\\\"...\\\"} — auto-selects clip.\n"
        "- For transitions: {\\\"type\\\":\\\"transition\\\",\\\"name\\\":\\\"...\\\"}\n"
        "- blade splits at playhead. Delete a segment: seek to start, blade, seek to end, blade, select, delete.\n"
        "- selectClipAtPlayhead selects whatever is under the playhead.\n"
        "- For \\\"every N seconds\\\": use repeat_pattern with seek to computed times.\n"
        "  count = floor(duration/N), each iteration: seek to i*N seconds, then do action.\n"
        "\n"
        "Workflow patterns:\n"
        "- Remove first N seconds: seek 0, blade at N, seek 0, selectClipAtPlayhead, delete\n"
        "- Remove last N seconds: seek (duration-N), blade, seek (duration-N), selectClipAtPlayhead (next clip), delete\n"
        "- Blade at time T: seek T, blade\n"
        "- Marker every N seconds (D sec timeline): repeat_pattern count=floor(D/N), each: seek i*N, addMarker\n"
        "  But since repeat_pattern doesn't give an index, use: seek N, addMarker, seek 2*N, addMarker, etc.\n"
        "  Or better: seek 0, then repeat_pattern with playback nextFrame repeat N*fps + addMarker\n"
        "  Actually best: generate explicit seek+action pairs for each position.\n"
        "- Transitions at every cut: repeat_pattern with nextEdit + addTransition\n"
        "- Select and color correct: selectClipAtPlayhead + addColorBoard\n"
        "- Select Nth clip: goToStart + nextEdit repeat N + selectClipAtPlayhead\n"
        "- Detach audio: selectClipAtPlayhead + detachAudio\n"
        "\n"
        "Common effect names (use with type=effect):\n"
        "  Blur: Gaussian Blur, Zoom Blur, Radial Blur, Prism Blur, Channel Blur, Soft Focus\n"
        "  Keying: Keyer, Luma Keyer, Chroma Keyer\n"
        "  Color: Black & White, Sepia, Tint, Negative, Color Monochrome\n"
        "  Stylize: Vignette, Bloom, Glow, Gloom, Aged Film, Bad TV, Vintage, Film Grain\n"
        "  Distortion: Underwater, Earthquake, Fisheye, Mirror, Kaleidoscope, Pixellate\n"
        "  Sharpen: Sharpen, Unsharp Mask\n"
        "  Light: Light Rays, Lens Flare, Light Wrap\n"
        "  Fix: Noise Reduction, Stabilization, Rolling Shutter, Broadcast Safe\n"
        "  Mask: Draw Mask, Shape Mask, Vignette Mask, Image Mask\n"
        "  Other: Drop Shadow, Letterbox, Flipped, Invert, Posterize, Tilt-Shift, Custom LUT\n"
        "\n"
        "Common transition names (use with type=transition):\n"
        "  Cross Dissolve, Flow, Fade To Color, Wipe, Push, Slide, Spin, Doorway,\n"
        "  Page Curl, Star, Band, Zoom, Bloom, Mosaic\n"
        "\n"
        "Examples:\n"
        "- \\\"add a keyer\\\" -> [{\\\"type\\\":\\\"effect\\\",\\\"name\\\":\\\"Keyer\\\"}]\n"
        "- \\\"blur this clip\\\" -> [{\\\"type\\\":\\\"effect\\\",\\\"name\\\":\\\"Gaussian Blur\\\"}]\n"
        "- \\\"make it black and white\\\" -> [{\\\"type\\\":\\\"effect\\\",\\\"name\\\":\\\"Black & White\\\"}]\n"
        "- \\\"stabilize\\\" -> [{\\\"type\\\":\\\"effect\\\",\\\"name\\\":\\\"Stabilization\\\"}]\n"
        "- \\\"add noise reduction\\\" -> [{\\\"type\\\":\\\"effect\\\",\\\"name\\\":\\\"Noise Reduction\\\"}]\n"
        "- \\\"add film grain\\\" -> [{\\\"type\\\":\\\"effect\\\",\\\"name\\\":\\\"Film Grain\\\"}]\n"
        "- \\\"add a drop shadow\\\" -> [{\\\"type\\\":\\\"effect\\\",\\\"name\\\":\\\"Drop Shadow\\\"}]\n"
        "- \\\"add a lens flare\\\" -> [{\\\"type\\\":\\\"effect\\\",\\\"name\\\":\\\"Lens Flare\\\"}]\n"
        "- \\\"add a flow transition\\\" -> [{\\\"type\\\":\\\"transition\\\",\\\"name\\\":\\\"Flow\\\"}]\n"
        "- \\\"add a wipe transition\\\" -> [{\\\"type\\\":\\\"transition\\\",\\\"name\\\":\\\"Wipe\\\"}]\n"
        "- \\\"cut at 3 seconds\\\" -> [{\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":3},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"blade\\\"}]\n"
        "- \\\"remove the first 2 seconds\\\" -> [{\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":2},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"blade\\\"},{\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":0},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"selectClipAtPlayhead\\\"},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"delete\\\"}]\n"
        "- \\\"remove the last 3 seconds\\\" (10s timeline) -> [{\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":7},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"blade\\\"},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"nextEdit\\\"},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"selectClipAtPlayhead\\\"},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"delete\\\"}]\n"
        "- \\\"add markers every 3 seconds\\\" (12s timeline) -> [{\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":3},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"addMarker\\\"},{\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":6},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"addMarker\\\"},{\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":9},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"addMarker\\\"},{\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":12},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"addMarker\\\"}]\n"
        "- \\\"blade every 5 seconds\\\" (20s timeline) -> [{\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":5},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"blade\\\"},{\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":10},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"blade\\\"},{\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":15},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"blade\\\"}]\n"
        "- \\\"slow to half speed\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"selectClipAtPlayhead\\\"},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"retimeSlow50\\\"}]\n"
        "- \\\"go to 5 seconds\\\" -> [{\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":5}]\n"
        "- \\\"go to the third clip\\\" -> [{\\\"type\\\":\\\"playback\\\",\\\"action\\\":\\\"goToStart\\\"},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"nextEdit\\\",\\\"repeat\\\":3}]\n"
        "- \\\"add transitions at every cut\\\" (5 clips) -> [{\\\"type\\\":\\\"playback\\\",\\\"action\\\":\\\"goToStart\\\"},{\\\"type\\\":\\\"repeat_pattern\\\",\\\"count\\\":4,\\\"actions\\\":[{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"nextEdit\\\"},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"addTransition\\\"}]}]\n"
        "- \\\"strip effects\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"selectClipAtPlayhead\\\"},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"removeEffects\\\"}]\n"
        "- \\\"remove all markers\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"selectAll\\\"},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"deleteMarkersInSelection\\\"}]\n"
        "- \\\"detach audio\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"selectClipAtPlayhead\\\"},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"detachAudio\\\"}]\n"
        "- \\\"detect scene changes\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"selectAll\\\"},{\\\"type\\\":\\\"scene_detect\\\"}]\n"
        "- \\\"add markers at every cut\\\" -> [{\\\"type\\\":\\\"scene_markers\\\"}]\n"
        "- \\\"render the timeline\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"renderAll\\\"}]\n"
        "- \\\"undo\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"undo\\\"}]\n"
        "- \\\"play from the start\\\" -> [{\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":0},{\\\"type\\\":\\\"playback\\\",\\\"action\\\":\\\"playPause\\\"}]\n"
        "\"\"\"\n"
        "\n"
        "let fullQuery = \"\\(timelineContext)\\n\\nUser request: \\(query)\"\n"
        "\n"
        "Task {\n"
        "    do {\n"
        "        let session = LanguageModelSession(instructions: instructions)\n"
        "        let response = try await session.respond(to: fullQuery)\n"
        "        print(response.content)\n"
        "    } catch {\n"
        "        print(\"{\\\"error\\\": \\\"\\(error.localizedDescription)\\\"}\")\n"
        "    }\n"
        "    exit(0)\n"
        "}\n"
        "\n"
        "dispatchMain()\n",
        escaped, escapedCtx];
}

#pragma mark - Keyword Fallback (when AI unavailable)

- (NSArray<NSDictionary *> *)keywordFallback:(NSString *)query {
    NSString *q = [query lowercaseString];
    NSMutableArray *actions = [NSMutableArray array];

    // Simple keyword patterns
    if ([q containsString:@"undo"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"undo"}];
    } else if ([q containsString:@"redo"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"redo"}];
    } else if ([q containsString:@"play"] || [q containsString:@"pause"] || [q containsString:@"stop"]) {
        [actions addObject:@{@"type": @"playback", @"action": @"playPause"}];
    } else if ([q containsString:@"beginning"] || [q containsString:@"start"] || [q containsString:@"rewind"]) {
        [actions addObject:@{@"type": @"playback", @"action": @"goToStart"}];
    } else if ([q containsString:@"end"]) {
        [actions addObject:@{@"type": @"playback", @"action": @"goToEnd"}];
    } else if ([q containsString:@"cut"] || [q containsString:@"split"] || [q containsString:@"blade"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"blade"}];
    } else if ([q containsString:@"delete"] || [q containsString:@"remove"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"delete"}];
    } else if ([q containsString:@"transition"] || [q containsString:@"dissolve"] || [q containsString:@"fade"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"addTransition"}];
    } else if ([q containsString:@"marker"]) {
        if ([q containsString:@"chapter"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"addChapterMarker"}];
        } else if ([q containsString:@"todo"] || [q containsString:@"to-do"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"addTodoMarker"}];
        } else {
            [actions addObject:@{@"type": @"timeline", @"action": @"addMarker"}];
        }
    } else if ([q containsString:@"color"] || [q containsString:@"grade"] || [q containsString:@"correct"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"addColorBoard"}];
    } else if ([q containsString:@"slow"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        if ([q containsString:@"25"] || [q containsString:@"quarter"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"retimeSlow25"}];
        } else {
            [actions addObject:@{@"type": @"timeline", @"action": @"retimeSlow50"}];
        }
    } else if ([q containsString:@"fast"] || [q containsString:@"speed up"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"retimeFast2x"}];
    } else if ([q containsString:@"reverse"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"retimeReverse"}];
    } else if ([q containsString:@"freeze"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
        [actions addObject:@{@"type": @"timeline", @"action": @"freezeFrame"}];
    } else if ([q containsString:@"title"]) {
        if ([q containsString:@"lower"]) {
            [actions addObject:@{@"type": @"timeline", @"action": @"addBasicLowerThird"}];
        } else {
            [actions addObject:@{@"type": @"timeline", @"action": @"addBasicTitle"}];
        }
    } else if ([q containsString:@"volume up"] || [q containsString:@"louder"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"adjustVolumeUp"}];
    } else if ([q containsString:@"volume down"] || [q containsString:@"quieter"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"adjustVolumeDown"}];
    } else if ([q containsString:@"export"] || [q containsString:@"xml"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"exportXML"}];
    } else if ([q containsString:@"select all"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectAll"}];
    } else if ([q containsString:@"select"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"selectClipAtPlayhead"}];
    } else if ([q containsString:@"compound"] || [q containsString:@"nest"] || [q containsString:@"group"]) {
        [actions addObject:@{@"type": @"timeline", @"action": @"createCompoundClip"}];
    }
    // Effect keywords — try to extract the effect name and apply it
    else if ([q containsString:@"keyer"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Keyer"}];
    } else if ([q containsString:@"blur"] || [q containsString:@"gaussian"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Gaussian Blur"}];
    } else if ([q containsString:@"vignette"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Vignette"}];
    } else if ([q containsString:@"sharpen"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Sharpen"}];
    } else if ([q containsString:@"stabiliz"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Stabilization"}];
    } else if ([q containsString:@"noise reduction"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Noise Reduction"}];
    } else if ([q containsString:@"black and white"] || [q containsString:@"b&w"] || [q containsString:@"monochrome"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Black & White"}];
    } else if ([q containsString:@"glow"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Glow"}];
    } else if ([q containsString:@"letterbox"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Letterbox"}];
    } else if ([q containsString:@"drop shadow"]) {
        [actions addObject:@{@"type": @"effect", @"name": @"Drop Shadow"}];
    }

    return actions;
}

@end
