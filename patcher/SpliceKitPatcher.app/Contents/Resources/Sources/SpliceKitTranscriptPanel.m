//
//  SpliceKitTranscriptPanel.m
//  Text-based video editing via speech transcription
//
//  Creates a floating panel inside FCP that shows a transcript of timeline clips.
//  Features: silence detection with [...] markers, speaker segments with timestamps,
//  search/filter, batch silence removal, and Premiere-style UI.
//
//  Deleting words removes the corresponding video segments.
//  Dragging words reorders clips on the timeline.
//

#import "SpliceKitTranscriptPanel.h"
#import "SpliceKit.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Speech framework loaded dynamically since FCP doesn't include it
static Class SFSpeechRecognizerClass = nil;
static Class SFSpeechURLRecognitionRequestClass = nil;

static void SpliceKitTranscript_loadSpeechFramework(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *speechBundle = [NSBundle bundleWithPath:
            @"/System/Library/Frameworks/Speech.framework"];
        if ([speechBundle load]) {
            SFSpeechRecognizerClass = objc_getClass("SFSpeechRecognizer");
            SFSpeechURLRecognitionRequestClass = objc_getClass("SFSpeechURLRecognitionRequest");
            SpliceKit_log(@"[Transcript] Speech.framework loaded: recognizer=%@, request=%@",
                          SFSpeechRecognizerClass, SFSpeechURLRecognitionRequestClass);
        } else {
            SpliceKit_log(@"[Transcript] ERROR: Failed to load Speech.framework");
        }
    });
}

// macOS 26+ check for speaker diarization support
static BOOL SpliceKitTranscript_isSpeakerDiarizationAvailable(void) {
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    // macOS 26 (Darwin 25.x) added SFSpeechRecognitionRequest.addsSpeakerAttribution
    return v.majorVersion >= 26;
}

#pragma mark - Timecode Formatting

static NSString *SpliceKitTranscript_timecodeFromSeconds(double seconds, double fps) {
    if (fps <= 0) fps = 24;
    if (seconds < 0) seconds = 0;
    int totalFrames = (int)(seconds * fps + 0.5);
    int fpsInt = (int)(fps + 0.5);
    if (fpsInt <= 0) fpsInt = 24;
    int frames = totalFrames % fpsInt;
    int totalSecs = totalFrames / fpsInt;
    int secs = totalSecs % 60;
    int mins = (totalSecs / 60) % 60;
    int hours = totalSecs / 3600;
    return [NSString stringWithFormat:@"%02d:%02d:%02d:%02d", hours, mins, secs, frames];
}

#pragma mark - SpliceKitTranscriptWord

@implementation SpliceKitTranscriptWord

- (instancetype)init {
    self = [super init];
    if (self) {
        _speaker = @"Unknown";
    }
    return self;
}

- (double)endTime {
    return _startTime + _duration;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"Word[%lu]: \"%@\" %.2f-%.2f (conf:%.0f%% speaker:%@)",
            (unsigned long)_wordIndex, _text, _startTime, self.endTime, _confidence * 100, _speaker];
}

@end

#pragma mark - SpliceKitTranscriptSilence

@implementation SpliceKitTranscriptSilence

- (NSString *)description {
    return [NSString stringWithFormat:@"Silence: %.2f-%.2f (%.2fs) after word %lu",
            _startTime, _endTime, _duration, (unsigned long)_afterWordIndex];
}

@end

#pragma mark - Forward Declarations

@interface SpliceKitTranscriptPanel (TextViewCallbacks)
- (void)handleClickAtCharIndex:(NSUInteger)charIdx;
- (void)handleDeleteKeyInTextView;
- (void)handleDropOfWordStart:(NSUInteger)srcStart count:(NSUInteger)srcCount atCharIndex:(NSUInteger)charIdx;
- (NSUInteger)wordIndexAtCharIndex:(NSUInteger)charIdx;
- (NSRange)selectedWordRange;
- (void)focusSearchField;
@end

static NSPasteboardType const SpliceKitTranscriptWordDragType = @"com.splicekit.transcript.words";

// Custom attribute keys for tracking what's at each position in the text view
static NSString *const FCPAttrItemType = @"FCPItemType";
static NSString *const FCPAttrWordIndex = @"FCPWordIndex";
static NSString *const FCPAttrSilenceIndex = @"FCPSilenceIndex";
static NSString *const FCPAttrSpeakerName = @"FCPSpeakerName";
static NSString *const FCPAttrSegmentStartIndex = @"FCPSegmentStartIndex";
static NSString *const FCPAttrSegmentEndIndex = @"FCPSegmentEndIndex";

#pragma mark - Custom Text View for Transcript

@interface SpliceKitTranscriptTextView : NSTextView <NSDraggingSource>
@property (nonatomic, weak) SpliceKitTranscriptPanel *transcriptPanel;
@property (nonatomic) BOOL isDragging;
@property (nonatomic) NSPoint dragOrigin;
@end

@implementation SpliceKitTranscriptTextView

- (void)awakeFromNib {
    [super awakeFromNib];
    [self registerForDraggedTypes:@[SpliceKitTranscriptWordDragType]];
}

- (void)setupDragTypes {
    [self registerForDraggedTypes:@[SpliceKitTranscriptWordDragType]];
}

- (void)mouseDown:(NSEvent *)event {
    self.dragOrigin = [self convertPoint:event.locationInWindow fromView:nil];
    self.isDragging = NO;

    // If clicking inside an existing selection, prepare for potential drag
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSUInteger charIdx = [self characterIndexForInsertionAtPoint:point];
    NSRange sel = self.selectedRange;
    if (sel.length > 0 && charIdx >= sel.location && charIdx < NSMaxRange(sel)) {
        return;
    }

    // Normal click — let NSTextView handle selection, then jump playhead
    [super mouseDown:event];
    charIdx = [self characterIndexForInsertionAtPoint:point];
    [self.transcriptPanel handleClickAtCharIndex:charIdx];
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat dx = point.x - self.dragOrigin.x;
    CGFloat dy = point.y - self.dragOrigin.y;

    // Check drag threshold (5px)
    if (!self.isDragging && (dx*dx + dy*dy) > 25) {
        NSRange sel = self.selectedRange;
        if (sel.length > 0) {
            self.isDragging = YES;
            [self startDragFromSelection:event];
            return;
        }
    }

    if (!self.isDragging) {
        [super mouseDragged:event];
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (!self.isDragging) {
        NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
        NSUInteger charIdx = [self characterIndexForInsertionAtPoint:point];
        NSRange sel = self.selectedRange;
        if (sel.length > 0 && charIdx >= sel.location && charIdx < NSMaxRange(sel)) {
            [self.transcriptPanel handleClickAtCharIndex:charIdx];
        }
    }
    self.isDragging = NO;
    [super mouseUp:event];
}

- (void)startDragFromSelection:(NSEvent *)event {
    NSRange sel = self.selectedRange;
    if (sel.length == 0) return;

    NSRange wordRange = [self.transcriptPanel selectedWordRange];
    if (wordRange.length == 0) return;

    NSString *data = [NSString stringWithFormat:@"%lu,%lu",
        (unsigned long)wordRange.location, (unsigned long)wordRange.length];
    NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
    [pbItem setString:data forType:SpliceKitTranscriptWordDragType];

    NSString *dragText = [[self.textStorage string] substringWithRange:sel];

    NSDraggingItem *dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:pbItem];

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:16],
        NSForegroundColorAttributeName: [NSColor labelColor],
        NSBackgroundColorAttributeName: [NSColor colorWithCalibratedRed:0.2 green:0.5 blue:1.0 alpha:0.3],
    };
    NSAttributedString *dragAttr = [[NSAttributedString alloc] initWithString:dragText attributes:attrs];
    NSSize textSize = [dragAttr size];
    textSize.width = MIN(textSize.width, 300);
    textSize.height = MAX(textSize.height, 20);
    NSImage *dragImage = [[NSImage alloc] initWithSize:textSize];
    [dragImage lockFocus];
    [dragAttr drawInRect:NSMakeRect(0, 0, textSize.width, textSize.height)];
    [dragImage unlockFocus];

    NSPoint dragPoint = [self convertPoint:event.locationInWindow fromView:nil];
    [dragItem setDraggingFrame:NSMakeRect(dragPoint.x, dragPoint.y - textSize.height,
                                           textSize.width, textSize.height)
                      contents:dragImage];

    [self beginDraggingSessionWithItems:@[dragItem] event:event source:self];
}

// NSDraggingSource
- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return NSDragOperationMove;
}

- (void)draggingSession:(NSDraggingSession *)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {
    self.isDragging = NO;
}

// NSDraggingDestination
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = [sender draggingPasteboard];
    if ([pb availableTypeFromArray:@[SpliceKitTranscriptWordDragType]]) {
        return NSDragOperationMove;
    }
    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = [sender draggingPasteboard];
    if ([pb availableTypeFromArray:@[SpliceKitTranscriptWordDragType]]) {
        NSPoint point = [self convertPoint:[sender draggingLocation] fromView:nil];
        NSUInteger charIdx = [self characterIndexForInsertionAtPoint:point];
        [self setSelectedRange:NSMakeRange(charIdx, 0)];
        return NSDragOperationMove;
    }
    return NSDragOperationNone;
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    return YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = [sender draggingPasteboard];
    NSString *data = [pb stringForType:SpliceKitTranscriptWordDragType];
    if (!data) return NO;

    NSArray *parts = [data componentsSeparatedByString:@","];
    if (parts.count != 2) return NO;

    NSUInteger srcStart = [parts[0] integerValue];
    NSUInteger srcCount = [parts[1] integerValue];

    NSPoint point = [self convertPoint:[sender draggingLocation] fromView:nil];
    NSUInteger charIdx = [self characterIndexForInsertionAtPoint:point];

    [self.transcriptPanel handleDropOfWordStart:srcStart count:srcCount atCharIndex:charIdx];
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    // Backspace / forward-delete → word deletion
    if (event.keyCode == 51 || event.keyCode == 117) {
        [self.transcriptPanel handleDeleteKeyInTextView];
        return;
    }

    // Spacebar and transport keys (J/K/L) → forward to FCP via responder chain
    NSString *chars = event.charactersIgnoringModifiers;
    if ([chars isEqualToString:@" "] ||
        [chars isEqualToString:@"j"] || [chars isEqualToString:@"k"] || [chars isEqualToString:@"l"]) {
        if ([chars isEqualToString:@" "]) {
            [[NSApp mainWindow] makeKeyWindow];
            ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
                [NSApp class] == nil ? nil : NSApp,
                @selector(sendAction:to:from:),
                NSSelectorFromString(@"playPause:"), nil, nil);
        } else {
            [[NSApp mainWindow] makeKeyWindow];
            [NSApp sendEvent:event];
        }
        return;
    }

    // Arrow keys → let NSTextView handle for cursor/selection
    if (event.keyCode >= 123 && event.keyCode <= 126) {
        [super keyDown:event];
        return;
    }

    // Cmd+A (select all), Cmd+Z (undo), Cmd+F (find) → pass through
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        // Cmd+F → focus search field
        if ([chars isEqualToString:@"f"]) {
            [self.transcriptPanel focusSearchField];
            return;
        }
        [super keyDown:event];
        return;
    }

    // Block all other typing
    NSBeep();
}

@end

#pragma mark - SpliceKitTranscriptPanel Private

typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } SpliceKitTranscript_CMTime;
typedef struct { SpliceKitTranscript_CMTime start; SpliceKitTranscript_CMTime duration; } SpliceKitTranscript_CMTimeRange;

static double CMTimeToSeconds(SpliceKitTranscript_CMTime t) {
    return (t.timescale > 0) ? (double)t.value / t.timescale : 0;
}

@interface SpliceKitTranscriptPanel () <NSTextViewDelegate, NSWindowDelegate, NSSearchFieldDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) SpliceKitTranscriptTextView *textView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) NSButton *refreshButton;
@property (nonatomic, strong) NSTimer *playheadTimer;

// Search & Filter UI
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSPopUpButton *filterPopup;
@property (nonatomic, strong) NSButton *deleteResultsButton;
@property (nonatomic, strong) NSButton *deleteSilencesButton;
@property (nonatomic, strong) NSTextField *resultCountLabel;
@property (nonatomic, strong) NSButton *prevResultButton;
@property (nonatomic, strong) NSButton *nextResultButton;

// Data
@property (nonatomic, readwrite) SpliceKitTranscriptStatus status;
@property (nonatomic, readwrite, strong) NSMutableArray<SpliceKitTranscriptWord *> *mutableWords;
@property (nonatomic, readwrite, strong) NSMutableArray<SpliceKitTranscriptSilence *> *mutableSilences;
@property (nonatomic, readwrite, copy) NSString *fullText;
@property (nonatomic, readwrite, copy) NSString *errorMessage;

// Transcription tracking
@property (nonatomic, strong) NSMutableArray *pendingTranscriptions;
@property (nonatomic) NSUInteger completedTranscriptions;
@property (nonatomic) NSUInteger totalTranscriptions;
@property (nonatomic) BOOL suppressTextViewCallbacks;

// Search state
@property (nonatomic, strong) NSMutableArray<NSValue *> *searchResultRanges; // NSRange values
@property (nonatomic) NSInteger currentSearchIndex;
@property (nonatomic, copy) NSString *currentSearchQuery;
@property (nonatomic, copy) NSString *currentFilter; // "all", "pauses", "lowConfidence"

// Progress bar
@property (nonatomic, strong) NSProgressIndicator *progressBar;

// Playhead tracking — stores the last highlighted word range to avoid clearing the whole document
@property (nonatomic) NSRange lastPlayheadHighlightRange;

// Options menu
@property (nonatomic, strong) NSPopUpButton *enginePopup;
@property (nonatomic, copy) NSString *parakeetModelVersion; // "v3" (default, multilingual) or "v2" (English-optimized)

// Speaker diarization (macOS 26+)
@property (nonatomic, strong) NSButton *speakerDetectionCheckbox;
@property (nonatomic) BOOL speakerDetectionEnabled;

// Frame rate for timecodes
@property (nonatomic) double frameRate;
@end

@implementation SpliceKitTranscriptPanel

#pragma mark - Singleton

+ (instancetype)sharedPanel {
    static SpliceKitTranscriptPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SpliceKitTranscriptPanel alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _status = SpliceKitTranscriptStatusIdle;
        _mutableWords = [NSMutableArray array];
        _mutableSilences = [NSMutableArray array];
        _pendingTranscriptions = [NSMutableArray array];
        _searchResultRanges = [NSMutableArray array];
        _currentSearchIndex = -1;
        _currentFilter = @"all";
        _silenceThreshold = 0.3; // 300ms default
        _frameRate = 24.0;
        _engine = SpliceKitTranscriptEngineParakeet; // Default to Parakeet (fastest, most accurate)
        _parakeetModelVersion = @"v3"; // v3 = multilingual, v2 = English-optimized
        _lastPlayheadHighlightRange = NSMakeRange(NSNotFound, 0);

        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSApplicationWillTerminateNotification
            object:nil queue:nil usingBlock:^(NSNotification *note) {
                [self stopPlayheadTimer];
                [self.panel orderOut:nil];
            }];
    }
    return self;
}

#pragma mark - Panel UI Setup

- (void)setupPanelIfNeeded {
    if (self.panel) return;

    SpliceKit_log(@"[Transcript] Setting up panel UI");

    // Create floating panel — wider for segment layout
    NSRect frame = NSMakeRect(100, 150, 620, 700);
    NSUInteger styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow;

    self.panel = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:styleMask
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"Transcript Editor";
    self.panel.floatingPanel = YES;
    self.panel.becomesKeyOnlyIfNeeded = NO;
    self.panel.hidesOnDeactivate = NO;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.minSize = NSMakeSize(420, 350);
    self.panel.delegate = self;
    self.panel.releasedWhenClosed = NO;

    // Dark appearance to match FCP
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSView *content = self.panel.contentView;
    content.wantsLayer = YES;

    // ──── Row 1: Search + Filter + Transcribe ────
    NSView *row1 = [[NSView alloc] init];
    row1.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:row1];

    // Search field
    self.searchField = [[NSSearchField alloc] init];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.placeholderString = @"Search transcript...";
    self.searchField.delegate = self;
    self.searchField.sendsSearchStringImmediately = YES;
    self.searchField.sendsWholeSearchString = NO;
    [row1 addSubview:self.searchField];

    // Filter popup
    self.filterPopup = [[NSPopUpButton alloc] init];
    self.filterPopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.filterPopup addItemsWithTitles:@[@"All", @"Pauses", @"Low Confidence"]];
    self.filterPopup.target = self;
    self.filterPopup.action = @selector(filterChanged:);
    [self.filterPopup setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row1 addSubview:self.filterPopup];

    // Engine selector
    self.enginePopup = [[NSPopUpButton alloc] init];
    self.enginePopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.enginePopup addItemsWithTitles:@[@"FCP Native", @"Apple Speech", @"Parakeet v3", @"Parakeet v2"]];
    self.enginePopup.target = self;
    self.enginePopup.action = @selector(engineChanged:);
    self.enginePopup.font = [NSFont systemFontOfSize:11];
    self.enginePopup.controlSize = NSControlSizeSmall;
    [self.enginePopup setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.enginePopup selectItemAtIndex:2]; // Default to Parakeet v3
    [row1 addSubview:self.enginePopup];

    // Speaker detection checkbox
    self.speakerDetectionCheckbox = [NSButton checkboxWithTitle:@"Speakers"
                                                        target:self
                                                        action:@selector(speakerDetectionToggled:)];
    self.speakerDetectionCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    self.speakerDetectionCheckbox.font = [NSFont systemFontOfSize:11];
    self.speakerDetectionCheckbox.controlSize = NSControlSizeSmall;
    [self.speakerDetectionCheckbox setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row1 addSubview:self.speakerDetectionCheckbox];
    // Initial state: disabled when FCP Native is default engine
    [self updateSpeakerCheckboxState];

    // Transcribe button
    self.refreshButton = [NSButton buttonWithTitle:@"Transcribe"
                                            target:self
                                            action:@selector(refreshClicked:)];
    self.refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.refreshButton.bezelStyle = NSBezelStyleRounded;
    [self.refreshButton setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row1 addSubview:self.refreshButton];

    // ──── Row 2: Delete buttons + Status/Spinner + Result nav ────
    NSView *row2 = [[NSView alloc] init];
    row2.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:row2];

    // Delete results button
    self.deleteResultsButton = [NSButton buttonWithTitle:@"Delete"
                                                  target:self
                                                  action:@selector(deleteResultsClicked:)];
    self.deleteResultsButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.deleteResultsButton.bezelStyle = NSBezelStyleRounded;
    self.deleteResultsButton.image = [NSImage imageWithSystemSymbolName:@"trash" accessibilityDescription:@"Delete"];
    self.deleteResultsButton.imagePosition = NSImageLeading;
    self.deleteResultsButton.enabled = NO;
    [self.deleteResultsButton setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row2 addSubview:self.deleteResultsButton];

    // Delete silences button
    self.deleteSilencesButton = [NSButton buttonWithTitle:@"Delete Silences"
                                                   target:self
                                                   action:@selector(deleteSilencesClicked:)];
    self.deleteSilencesButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.deleteSilencesButton.bezelStyle = NSBezelStyleRounded;
    self.deleteSilencesButton.enabled = NO;
    [self.deleteSilencesButton setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row2 addSubview:self.deleteSilencesButton];

    // Status label + spinner
    self.statusLabel = [NSTextField labelWithString:@"Ready"];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row2 addSubview:self.statusLabel];

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.hidden = YES;
    [row2 addSubview:self.spinner];

    // Result count
    self.resultCountLabel = [NSTextField labelWithString:@""];
    self.resultCountLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.resultCountLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.resultCountLabel.textColor = [NSColor secondaryLabelColor];
    self.resultCountLabel.alignment = NSTextAlignmentRight;
    [self.resultCountLabel setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row2 addSubview:self.resultCountLabel];

    // Prev/Next buttons
    self.prevResultButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.up" accessibilityDescription:@"Previous"]
                                               target:self
                                               action:@selector(prevResultClicked:)];
    self.prevResultButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.prevResultButton.bezelStyle = NSBezelStyleRounded;
    self.prevResultButton.bordered = NO;
    self.prevResultButton.enabled = NO;
    [row2 addSubview:self.prevResultButton];

    self.nextResultButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:@"Next"]
                                               target:self
                                               action:@selector(nextResultClicked:)];
    self.nextResultButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.nextResultButton.bezelStyle = NSBezelStyleRounded;
    self.nextResultButton.bordered = NO;
    self.nextResultButton.enabled = NO;
    [row2 addSubview:self.nextResultButton];

    // ──── Progress bar (hidden by default, shown during transcription) ────
    self.progressBar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressBar.style = NSProgressIndicatorStyleBar;
    self.progressBar.controlSize = NSControlSizeSmall;
    self.progressBar.indeterminate = NO;
    self.progressBar.minValue = 0;
    self.progressBar.maxValue = 1.0;
    self.progressBar.doubleValue = 0;
    self.progressBar.hidden = YES;
    [content addSubview:self.progressBar];

    // ──── Scroll view with text view ────
    // Create scroll view with a real initial frame so NSTextView can read contentSize.
    // Auto Layout will override the frame later, but the initial size lets the text view
    // configure its autoresizing geometry correctly.
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 600, 500)];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.borderType = NSNoBorder;
    self.scrollView.drawsBackground = YES;
    self.scrollView.backgroundColor = [NSColor colorWithCalibratedWhite:0.15 alpha:1.0];
    [content addSubview:self.scrollView];

    // Text view — created using scrollView.contentSize so the initial frame matches
    // the clip view. lineFragmentPadding provides left/right text padding within the
    // text container; textContainerInset provides top/bottom only.
    NSSize cs = self.scrollView.contentSize;
    self.textView = [[SpliceKitTranscriptTextView alloc] initWithFrame:
        NSMakeRect(0, 0, cs.width, cs.height)];
    self.textView.transcriptPanel = self;
    self.textView.minSize = NSMakeSize(0, cs.height);
    self.textView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.textView.verticallyResizable = YES;
    self.textView.horizontallyResizable = NO;
    self.textView.autoresizingMask = NSViewWidthSizable;
    self.textView.textContainer.containerSize = NSMakeSize(cs.width, FLT_MAX);
    self.textView.textContainer.widthTracksTextView = YES;
    self.textView.textContainer.lineFragmentPadding = 16;
    self.textView.font = [NSFont systemFontOfSize:15];
    self.textView.textColor = [NSColor labelColor];
    self.textView.backgroundColor = [NSColor colorWithCalibratedWhite:0.15 alpha:1.0];
    self.textView.insertionPointColor = [NSColor whiteColor];
    self.textView.editable = YES;
    self.textView.selectable = YES;
    self.textView.richText = YES;
    self.textView.allowsUndo = NO;
    self.textView.delegate = self;
    self.textView.textContainerInset = NSMakeSize(0, 12);
    self.scrollView.documentView = self.textView;

    [self.textView setupDragTypes];

    // Instructions text
    NSMutableAttributedString *instructions = [[NSMutableAttributedString alloc]
        initWithString:@"Transcript Editor\n\nClick \"Transcribe\" to transcribe audio from your timeline clips.\n\nOnce transcribed:\n  \u2022 Click a word to jump the playhead\n  \u2022 Select words and press Delete to remove those segments\n  \u2022 Drag words to reorder clips\n  \u2022 Use Search to find text or filter Pauses\n  \u2022 Click \"Delete Silences\" to batch-remove pauses\n\nSilences are shown as [\u22ef] markers between words."
        attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:14],
            NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
        }];
    [self.textView.textStorage setAttributedString:instructions];

    // ──── Auto Layout ────

    // Row 1
    [NSLayoutConstraint activateConstraints:@[
        [row1.topAnchor constraintEqualToAnchor:content.topAnchor constant:10],
        [row1.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [row1.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [row1.heightAnchor constraintEqualToConstant:28],

        [self.searchField.leadingAnchor constraintEqualToAnchor:row1.leadingAnchor],
        [self.searchField.centerYAnchor constraintEqualToAnchor:row1.centerYAnchor],

        [self.filterPopup.leadingAnchor constraintEqualToAnchor:self.searchField.trailingAnchor constant:8],
        [self.filterPopup.centerYAnchor constraintEqualToAnchor:row1.centerYAnchor],
        [self.filterPopup.widthAnchor constraintGreaterThanOrEqualToConstant:100],

        [self.enginePopup.leadingAnchor constraintEqualToAnchor:self.filterPopup.trailingAnchor constant:6],
        [self.enginePopup.centerYAnchor constraintEqualToAnchor:row1.centerYAnchor],

        [self.speakerDetectionCheckbox.leadingAnchor constraintEqualToAnchor:self.enginePopup.trailingAnchor constant:6],
        [self.speakerDetectionCheckbox.centerYAnchor constraintEqualToAnchor:row1.centerYAnchor],

        [self.refreshButton.leadingAnchor constraintEqualToAnchor:self.speakerDetectionCheckbox.trailingAnchor constant:6],
        [self.refreshButton.trailingAnchor constraintEqualToAnchor:row1.trailingAnchor],
        [self.refreshButton.centerYAnchor constraintEqualToAnchor:row1.centerYAnchor],

        [self.searchField.trailingAnchor constraintEqualToAnchor:self.filterPopup.leadingAnchor constant:-8],
    ]];

    // Row 2
    [NSLayoutConstraint activateConstraints:@[
        [row2.topAnchor constraintEqualToAnchor:row1.bottomAnchor constant:6],
        [row2.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [row2.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [row2.heightAnchor constraintEqualToConstant:24],

        [self.deleteResultsButton.leadingAnchor constraintEqualToAnchor:row2.leadingAnchor],
        [self.deleteResultsButton.centerYAnchor constraintEqualToAnchor:row2.centerYAnchor],

        [self.deleteSilencesButton.leadingAnchor constraintEqualToAnchor:self.deleteResultsButton.trailingAnchor constant:6],
        [self.deleteSilencesButton.centerYAnchor constraintEqualToAnchor:row2.centerYAnchor],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.deleteSilencesButton.trailingAnchor constant:8],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:row2.centerYAnchor],

        [self.spinner.leadingAnchor constraintEqualToAnchor:self.statusLabel.trailingAnchor constant:4],
        [self.spinner.centerYAnchor constraintEqualToAnchor:row2.centerYAnchor],

        [self.nextResultButton.trailingAnchor constraintEqualToAnchor:row2.trailingAnchor],
        [self.nextResultButton.centerYAnchor constraintEqualToAnchor:row2.centerYAnchor],
        [self.nextResultButton.widthAnchor constraintEqualToConstant:24],

        [self.prevResultButton.trailingAnchor constraintEqualToAnchor:self.nextResultButton.leadingAnchor constant:-2],
        [self.prevResultButton.centerYAnchor constraintEqualToAnchor:row2.centerYAnchor],
        [self.prevResultButton.widthAnchor constraintEqualToConstant:24],

        [self.resultCountLabel.trailingAnchor constraintEqualToAnchor:self.prevResultButton.leadingAnchor constant:-6],
        [self.resultCountLabel.centerYAnchor constraintEqualToAnchor:row2.centerYAnchor],

        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.resultCountLabel.leadingAnchor constant:-8],
    ]];

    // Progress bar (full width, thin, between toolbar and scroll view)
    [NSLayoutConstraint activateConstraints:@[
        [self.progressBar.topAnchor constraintEqualToAnchor:row2.bottomAnchor constant:6],
        [self.progressBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [self.progressBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [self.progressBar.heightAnchor constraintEqualToConstant:4],
    ]];

    // Scroll view
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.progressBar.bottomAnchor constant:4],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];
}

#pragma mark - Panel Visibility

- (void)showPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setupPanelIfNeeded];
        [self.panel makeKeyAndOrderFront:nil];
        if (self.status == SpliceKitTranscriptStatusReady && self.mutableWords.count > 0) {
            [self startPlayheadTimer];
        }
    });
}

- (void)hidePanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.panel orderOut:nil];
    });
}

- (BOOL)isVisible {
    return self.panel.isVisible;
}

- (void)windowWillClose:(NSNotification *)notification {
    // Don't stop timer — user may reopen and expect sync
}

- (void)focusSearchField {
    [self.panel makeKeyAndOrderFront:nil];
    [self.searchField becomeFirstResponder];
}

#pragma mark - Button Actions

- (void)refreshClicked:(id)sender {
    [self transcribeTimeline];
}

- (void)engineChanged:(id)sender {
    NSString *selected = self.enginePopup.titleOfSelectedItem;
    if ([selected isEqualToString:@"Apple Speech"]) {
        self.engine = SpliceKitTranscriptEngineAppleSpeech;
        SpliceKit_log(@"[Transcript] Engine switched to Apple Speech (SFSpeechRecognizer)");
    } else if ([selected hasPrefix:@"Parakeet"]) {
        self.engine = SpliceKitTranscriptEngineParakeet;
        if ([selected isEqualToString:@"Parakeet v2"]) {
            self.parakeetModelVersion = @"v2";
            SpliceKit_log(@"[Transcript] Engine switched to Parakeet v2 (English-optimized)");
        } else {
            self.parakeetModelVersion = @"v3";
            SpliceKit_log(@"[Transcript] Engine switched to Parakeet v3 (Multilingual)");
        }
    } else {
        self.engine = SpliceKitTranscriptEngineFCPNative;
        SpliceKit_log(@"[Transcript] Engine switched to FCP Native (AASpeechAnalyzer)");
    }
    [self updateSpeakerCheckboxState];
}

- (void)speakerDetectionToggled:(id)sender {
    self.speakerDetectionEnabled = (self.speakerDetectionCheckbox.state == NSControlStateValueOn);
    SpliceKit_log(@"[Transcript] Speaker detection %@", self.speakerDetectionEnabled ? @"enabled" : @"disabled");
}

- (void)updateSpeakerCheckboxState {
    BOOL macOS26 = SpliceKitTranscript_isSpeakerDiarizationAvailable();
    BOOL isAppleSpeech = (self.engine == SpliceKitTranscriptEngineAppleSpeech);
    BOOL isParakeet = (self.engine == SpliceKitTranscriptEngineParakeet);

    if (isParakeet) {
        // Parakeet has built-in diarization via FluidAudio — always available
        self.speakerDetectionCheckbox.enabled = YES;
        self.speakerDetectionCheckbox.state = NSControlStateValueOn;
        self.speakerDetectionEnabled = YES;
        self.speakerDetectionCheckbox.toolTip = @"Detect different speakers (FluidAudio diarization)";
    } else if (isAppleSpeech && macOS26) {
        self.speakerDetectionCheckbox.enabled = YES;
        self.speakerDetectionCheckbox.state = NSControlStateValueOn;
        self.speakerDetectionEnabled = YES;
        self.speakerDetectionCheckbox.toolTip = @"Detect different speakers (macOS 26+)";
    } else if (isAppleSpeech) {
        self.speakerDetectionCheckbox.enabled = NO;
        self.speakerDetectionCheckbox.state = NSControlStateValueOff;
        self.speakerDetectionEnabled = NO;
        self.speakerDetectionCheckbox.toolTip = @"Speaker detection requires macOS 26 or later";
    } else {
        // FCP Native: no diarization
        self.speakerDetectionCheckbox.enabled = NO;
        self.speakerDetectionCheckbox.state = NSControlStateValueOff;
        self.speakerDetectionEnabled = NO;
        self.speakerDetectionCheckbox.toolTip = @"Speaker detection not available with FCP Native engine";
    }
}

- (void)filterChanged:(id)sender {
    NSString *selected = self.filterPopup.titleOfSelectedItem;
    if ([selected isEqualToString:@"Pauses"]) {
        self.currentFilter = @"pauses";
        self.searchField.stringValue = @"";
        self.currentSearchQuery = @"";
    } else if ([selected isEqualToString:@"Low Confidence"]) {
        self.currentFilter = @"lowConfidence";
        self.searchField.stringValue = @"";
        self.currentSearchQuery = @"";
    } else {
        self.currentFilter = @"all";
    }
    [self rebuildTextView];
    [self performSearchHighlighting];
}

- (void)deleteResultsClicked:(id)sender {
    if (self.searchResultRanges.count == 0) return;

    // If filter is pauses, delete all silences
    if ([self.currentFilter isEqualToString:@"pauses"]) {
        [self deleteSilencesClicked:sender];
        return;
    }

    // Delete selected search result words
    // Collect word indices from search results (reverse order for safe deletion)
    NSMutableArray<NSNumber *> *wordIndicesToDelete = [NSMutableArray array];
    @synchronized (self.mutableWords) {
        for (NSValue *rangeVal in self.searchResultRanges) {
            NSRange range = rangeVal.rangeValue;
            for (SpliceKitTranscriptWord *word in self.mutableWords) {
                NSRange intersection = NSIntersectionRange(range, word.textRange);
                if (intersection.length > 0) {
                    [wordIndicesToDelete addObject:@(word.wordIndex)];
                }
            }
        }
    }

    if (wordIndicesToDelete.count == 0) return;

    // Sort descending so we delete from end first
    [wordIndicesToDelete sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [b compare:a];
    }];

    [self updateStatusUI:@"Deleting search results..."];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (NSNumber *idx in wordIndicesToDelete) {
            [self deleteWordsFromIndex:idx.unsignedIntegerValue count:1];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStatusUI:@"Deleted search results"];
        });
    });
}

- (void)deleteSilencesClicked:(id)sender {
    [self deleteAllSilences];
}

- (void)prevResultClicked:(id)sender {
    if (self.searchResultRanges.count == 0) return;
    self.currentSearchIndex--;
    if (self.currentSearchIndex < 0) {
        self.currentSearchIndex = (NSInteger)self.searchResultRanges.count - 1;
    }
    [self scrollToCurrentSearchResult];
}

- (void)nextResultClicked:(id)sender {
    if (self.searchResultRanges.count == 0) return;
    self.currentSearchIndex++;
    if (self.currentSearchIndex >= (NSInteger)self.searchResultRanges.count) {
        self.currentSearchIndex = 0;
    }
    [self scrollToCurrentSearchResult];
}

#pragma mark - Search

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == self.searchField) {
        self.currentSearchQuery = self.searchField.stringValue;
        // Reset filter to All when typing in search
        if (self.currentSearchQuery.length > 0 && ![self.currentFilter isEqualToString:@"all"]) {
            self.currentFilter = @"all";
            [self.filterPopup selectItemWithTitle:@"All"];
        }
        [self performSearchHighlighting];
    }
}

- (void)performSearchHighlighting {
    [self.searchResultRanges removeAllObjects];
    self.currentSearchIndex = -1;

    NSTextStorage *storage = self.textView.textStorage;
    NSRange fullRange = NSMakeRange(0, storage.length);
    if (fullRange.length == 0) {
        [self updateSearchResultsUI];
        return;
    }

    // Clear previous search highlighting
    self.suppressTextViewCallbacks = YES;
    [storage removeAttribute:NSBackgroundColorAttributeName range:fullRange];

    NSString *query = self.currentSearchQuery;
    BOOL filterPauses = [self.currentFilter isEqualToString:@"pauses"];
    BOOL filterLowConf = [self.currentFilter isEqualToString:@"lowConfidence"];

    if (filterPauses) {
        // Highlight all silence markers
        for (SpliceKitTranscriptSilence *silence in self.mutableSilences) {
            if (silence.textRange.location + silence.textRange.length <= storage.length) {
                [self.searchResultRanges addObject:[NSValue valueWithRange:silence.textRange]];
                [storage addAttribute:NSBackgroundColorAttributeName
                                value:[NSColor colorWithCalibratedRed:0.9 green:0.7 blue:0.2 alpha:0.5]
                                range:silence.textRange];
            }
        }
    } else if (filterLowConf) {
        // Highlight low confidence words
        @synchronized (self.mutableWords) {
            for (SpliceKitTranscriptWord *word in self.mutableWords) {
                if (word.confidence < 0.5 && word.textRange.location + word.textRange.length <= storage.length) {
                    [self.searchResultRanges addObject:[NSValue valueWithRange:word.textRange]];
                    [storage addAttribute:NSBackgroundColorAttributeName
                                    value:[NSColor colorWithCalibratedRed:0.9 green:0.5 blue:0.2 alpha:0.4]
                                    range:word.textRange];
                }
            }
        }
    } else if (query.length > 0) {
        // Text search
        NSString *text = [storage string];
        NSRange searchRange = NSMakeRange(0, text.length);
        NSStringCompareOptions options = NSCaseInsensitiveSearch;

        while (searchRange.location < text.length) {
            NSRange foundRange = [text rangeOfString:query options:options range:searchRange];
            if (foundRange.location == NSNotFound) break;

            [self.searchResultRanges addObject:[NSValue valueWithRange:foundRange]];
            [storage addAttribute:NSBackgroundColorAttributeName
                            value:[NSColor colorWithCalibratedRed:0.9 green:0.7 blue:0.2 alpha:0.4]
                            range:foundRange];

            searchRange.location = NSMaxRange(foundRange);
            searchRange.length = text.length - searchRange.location;
        }
    }

    self.suppressTextViewCallbacks = NO;

    if (self.searchResultRanges.count > 0) {
        self.currentSearchIndex = 0;
        [self scrollToCurrentSearchResult];
    }

    [self updateSearchResultsUI];
}

- (void)scrollToCurrentSearchResult {
    if (self.currentSearchIndex < 0 || self.currentSearchIndex >= (NSInteger)self.searchResultRanges.count) return;

    NSRange range = self.searchResultRanges[self.currentSearchIndex].rangeValue;

    // Highlight current result more prominently
    NSTextStorage *storage = self.textView.textStorage;
    self.suppressTextViewCallbacks = YES;

    // Reset all to standard highlight color
    for (NSValue *rv in self.searchResultRanges) {
        NSRange r = rv.rangeValue;
        if (r.location + r.length <= storage.length) {
            [storage addAttribute:NSBackgroundColorAttributeName
                            value:[NSColor colorWithCalibratedRed:0.9 green:0.7 blue:0.2 alpha:0.4]
                            range:r];
        }
    }

    // Highlight current with brighter color
    if (range.location + range.length <= storage.length) {
        [storage addAttribute:NSBackgroundColorAttributeName
                        value:[NSColor colorWithCalibratedRed:1.0 green:0.8 blue:0.2 alpha:0.7]
                        range:range];
    }

    self.suppressTextViewCallbacks = NO;

    // Scroll to visible
    [self.textView scrollRangeToVisible:range];

    [self updateSearchResultsUI];
}

- (void)updateSearchResultsUI {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger total = self.searchResultRanges.count;
        if (total > 0) {
            self.resultCountLabel.stringValue = [NSString stringWithFormat:@"%ld/%lu",
                (long)(self.currentSearchIndex + 1), (unsigned long)total];
            self.prevResultButton.enabled = YES;
            self.nextResultButton.enabled = YES;
            self.deleteResultsButton.enabled = YES;
        } else {
            self.resultCountLabel.stringValue = @"";
            self.prevResultButton.enabled = NO;
            self.nextResultButton.enabled = NO;
            self.deleteResultsButton.enabled = (self.currentSearchQuery.length > 0 ||
                                                ![self.currentFilter isEqualToString:@"all"]);
        }
    });
}

- (NSDictionary *)searchTranscript:(NSString *)query {
    if (!query || query.length == 0) {
        return @{@"error": @"Query cannot be empty"};
    }

    NSMutableArray *results = [NSMutableArray array];

    // Check for special keywords
    if ([[query lowercaseString] isEqualToString:@"pauses"] ||
        [[query lowercaseString] isEqualToString:@"silences"]) {
        for (SpliceKitTranscriptSilence *silence in self.mutableSilences) {
            [results addObject:@{
                @"type": @"silence",
                @"startTime": @(silence.startTime),
                @"endTime": @(silence.endTime),
                @"duration": @(silence.duration),
                @"afterWordIndex": @(silence.afterWordIndex)
            }];
        }
        return @{@"query": query, @"resultCount": @(results.count), @"results": results};
    }

    // Text search through words
    @synchronized (self.mutableWords) {
        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            if ([word.text rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [results addObject:@{
                    @"type": @"word",
                    @"index": @(word.wordIndex),
                    @"text": word.text,
                    @"startTime": @(word.startTime),
                    @"endTime": @(word.endTime),
                    @"confidence": @(word.confidence),
                    @"speaker": word.speaker ?: @"Unknown"
                }];
            }
        }
    }

    // Also update the UI search
    dispatch_async(dispatch_get_main_queue(), ^{
        self.searchField.stringValue = query;
        self.currentSearchQuery = query;
        [self performSearchHighlighting];
    });

    return @{@"query": query, @"resultCount": @(results.count), @"results": results};
}

#pragma mark - Speech Recognition Authorization

- (void)requestSpeechAuthorizationWithCompletion:(void(^)(BOOL authorized))completion {
    if (!SFSpeechRecognizerClass) {
        SpliceKit_log(@"[Transcript] Speech framework not loaded");
        completion(NO);
        return;
    }

    // Check current authorization status
    // SFSpeechRecognizerAuthorizationStatus: 0=notDetermined, 1=denied, 2=restricted, 3=authorized
    SEL statusSel = NSSelectorFromString(@"authorizationStatus");
    NSInteger status = ((NSInteger (*)(Class, SEL))objc_msgSend)(SFSpeechRecognizerClass, statusSel);
    SpliceKit_log(@"[Transcript] Speech authorization status: %ld", (long)status);

    if (status == 3) { // authorized
        completion(YES);
        return;
    }

    if (status == 0) { // notDetermined — request it, which should trigger the system dialog
        SpliceKit_log(@"[Transcript] Requesting speech recognition authorization...");
        SEL reqSel = NSSelectorFromString(@"requestAuthorization:");
        ((void (*)(Class, SEL, id))objc_msgSend)(SFSpeechRecognizerClass, reqSel,
            ^(NSInteger newStatus) {
                SpliceKit_log(@"[Transcript] Authorization callback: %ld", (long)newStatus);
                completion(newStatus == 3);
            });
        return;
    }

    // denied or restricted — still try, on-device recognition may work without full authorization
    SpliceKit_log(@"[Transcript] Speech auth status %ld, attempting anyway (on-device may work)", (long)status);
    completion(YES);
}

#pragma mark - Transcribe Timeline

- (void)transcribeTimeline {
    SpliceKit_log(@"[Transcript] Starting timeline transcription");

    dispatch_async(dispatch_get_main_queue(), ^{
        self.status = SpliceKitTranscriptStatusTranscribing;
        self.errorMessage = nil;
        [self updateStatusUI:@"Analyzing timeline..."];
        self.spinner.hidden = NO;
        [self.spinner startAnimation:nil];
        self.progressBar.hidden = NO;
        self.progressBar.indeterminate = YES;
        [self.progressBar startAnimation:nil];
        self.refreshButton.enabled = NO;
        self.deleteSilencesButton.enabled = NO;
    });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (self.engine == SpliceKitTranscriptEngineFCPNative || self.engine == SpliceKitTranscriptEngineParakeet) {
            // FCP Native and Parakeet don't need Apple speech authorization
            [self performTimelineTranscription];
        } else {
            [self requestSpeechAuthorizationWithCompletion:^(BOOL authorized) {
                if (!authorized) {
                    [self openSpeechRecognitionSettings];
                    [self setErrorState:@"Speech recognition denied. Grant access in Settings > Privacy > Speech Recognition, or use FCP Native engine."];
                    return;
                }
                [self performTimelineTranscription];
            }];
        }
    });
}

- (void)collectClipsFrom:(NSArray *)items atTimeline:(double *)timelinePos into:(NSMutableArray *)clipInfos {
    for (id item in items) {
        NSString *className = NSStringFromClass([item class]);

        double clipDuration = 0;
        if ([item respondsToSelector:@selector(duration)]) {
            SpliceKitTranscript_CMTime d = ((SpliceKitTranscript_CMTime (*)(id, SEL))objc_msgSend)(item, @selector(duration));
            clipDuration = CMTimeToSeconds(d);
        }

        BOOL isMedia = [className containsString:@"MediaComponent"];
        BOOL isCollection = [className containsString:@"Collection"] || [className containsString:@"AnchoredClip"];
        BOOL isTransition = [className containsString:@"Transition"];

        if (isMedia && clipDuration > 0) {
            [self addMediaClip:item duration:clipDuration atTimeline:*timelinePos into:clipInfos];
            *timelinePos += clipDuration;

        } else if (isCollection && clipDuration > 0) {
            SpliceKit_log(@"[Transcript] Collection: %@ (%.2fs) at %.2fs", className, clipDuration, *timelinePos);

            id innerMedia = [self findFirstMediaInContainer:item];
            if (innerMedia) {
                double collTrimStart = 0;
                SEL crSel = NSSelectorFromString(@"clippedRange");
                if ([item respondsToSelector:crSel]) {
                    NSMethodSignature *sig = [item methodSignatureForSelector:crSel];
                    if (sig && [sig methodReturnLength] == sizeof(SpliceKitTranscript_CMTimeRange)) {
                        SpliceKitTranscript_CMTimeRange range;
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        [inv setTarget:item];
                        [inv setSelector:crSel];
                        [inv invoke];
                        [inv getReturnValue:&range];
                        collTrimStart = CMTimeToSeconds(range.start);
                        SpliceKit_log(@"[Transcript]   collection clippedRange: start=%.2fs dur=%.2fs",
                                      collTrimStart, CMTimeToSeconds(range.duration));
                    }
                }
                [self addMediaClip:innerMedia duration:clipDuration trimStart:collTrimStart
                        atTimeline:*timelinePos into:clipInfos];
            }
            *timelinePos += clipDuration;

        } else if (!isTransition) {
            *timelinePos += clipDuration;
        }
    }
}

- (id)findFirstMediaInContainer:(id)container {
    id subItems = nil;
    if ([container respondsToSelector:@selector(containedItems)]) {
        subItems = ((id (*)(id, SEL))objc_msgSend)(container, @selector(containedItems));
    }
    if ((!subItems || ![subItems isKindOfClass:[NSArray class]] || [(NSArray *)subItems count] == 0) &&
        [container respondsToSelector:@selector(primaryObject)]) {
        id primary = ((id (*)(id, SEL))objc_msgSend)(container, @selector(primaryObject));
        if (primary && [primary respondsToSelector:@selector(containedItems)]) {
            subItems = ((id (*)(id, SEL))objc_msgSend)(primary, @selector(containedItems));
        }
    }
    if (!subItems || ![subItems isKindOfClass:[NSArray class]]) return nil;

    for (id sub in (NSArray *)subItems) {
        NSString *cls = NSStringFromClass([sub class]);
        if ([cls containsString:@"MediaComponent"]) return sub;
        if ([cls containsString:@"Collection"] || [cls containsString:@"AnchoredClip"]) {
            id found = [self findFirstMediaInContainer:sub];
            if (found) return found;
        }
    }
    return nil;
}

- (void)addMediaClip:(id)clip duration:(double)clipDuration atTimeline:(double)timelinePos into:(NSMutableArray *)clipInfos {
    double trimStart = 0;
    SEL unclippedSel = NSSelectorFromString(@"unclippedRange");
    if ([clip respondsToSelector:unclippedSel]) {
        NSMethodSignature *sig = [clip methodSignatureForSelector:unclippedSel];
        if (sig && [sig methodReturnLength] == sizeof(SpliceKitTranscript_CMTimeRange)) {
            SpliceKitTranscript_CMTimeRange range;
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:clip];
            [inv setSelector:unclippedSel];
            [inv invoke];
            [inv getReturnValue:&range];
            trimStart = CMTimeToSeconds(range.start);
        }
    }
    [self addMediaClip:clip duration:clipDuration trimStart:trimStart atTimeline:timelinePos into:clipInfos];
}

- (void)addMediaClip:(id)clip duration:(double)clipDuration trimStart:(double)trimStart
          atTimeline:(double)timelinePos into:(NSMutableArray *)clipInfos {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"timelineStart"] = @(timelinePos);
    info[@"duration"] = @(clipDuration);
    info[@"handle"] = SpliceKit_storeHandle(clip);
    info[@"className"] = NSStringFromClass([clip class]);
    info[@"trimStart"] = @(trimStart);

    if ([clip respondsToSelector:@selector(displayName)]) {
        id name = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
        info[@"name"] = name ?: @"Untitled";
    }

    NSURL *mediaURL = [self getMediaURLForClip:clip];
    if (mediaURL) {
        info[@"mediaURL"] = mediaURL;
    }

    SpliceKit_log(@"[Transcript] Clip at %.2fs (dur=%.2fs, trim=%.2fs): %@ -> %@",
                  timelinePos, clipDuration, trimStart, info[@"name"],
                  mediaURL ? [mediaURL path] : @"(no URL)");

    [clipInfos addObject:info];
}

- (void)performTimelineTranscription {
    if (self.engine == SpliceKitTranscriptEngineFCPNative) {
        [self performFCPNativeTranscription];
    } else if (self.engine == SpliceKitTranscriptEngineParakeet) {
        [self performParakeetTranscription];
    } else {
        [self performAppleSpeechTranscription];
    }
}

#pragma mark - FCP Native Transcription (AASpeechAnalyzer via FFTranscriptionCoordinator)

- (void)performFCPNativeTranscription {
    SpliceKit_log(@"[Transcript] Using FCP Native engine (FFTranscriptionCoordinator)");

    // Gather assets from timeline clips on the main thread.
    // FCP's own startBackgroundTranscriptionForClips: iterates clips and calls
    // [clip assets] (an NSSet of FFAsset) then unions them all together.
    // We replicate that exact pattern here.
    __block NSArray *assetArray = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = [self getActiveTimelineModule];
            if (!timeline) {
                [self setErrorState:@"No active timeline. Open a project first."];
                return;
            }

            // Detect frame rate
            if ([timeline respondsToSelector:@selector(sequenceFrameDuration)]) {
                SpliceKitTranscript_CMTime fd = ((SpliceKitTranscript_CMTime (*)(id, SEL))objc_msgSend)(
                    timeline, @selector(sequenceFrameDuration));
                if (fd.timescale > 0 && fd.value > 0) {
                    self.frameRate = (double)fd.timescale / fd.value;
                }
            }

            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) {
                [self setErrorState:@"No sequence in timeline."];
                return;
            }

            id primaryObj = nil;
            if ([sequence respondsToSelector:@selector(primaryObject)]) {
                primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
            }
            if (!primaryObj) {
                [self setErrorState:@"No primary object in sequence."];
                return;
            }

            id items = nil;
            if ([primaryObj respondsToSelector:@selector(containedItems)]) {
                items = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
            }
            if (!items || ![items isKindOfClass:[NSArray class]]) {
                [self setErrorState:@"No items on timeline."];
                return;
            }

            // modalTranscriptsForClips expects objects that respond to `assets`
            // (like FFAnchoredObject subclasses). It internally calls [clip assets]
            // to get FFAsset objects. We pass the containedItems directly.
            // Also include the sequence itself as a fallback.
            NSMutableArray *clipObjects = [NSMutableArray array];
            SEL assetsSel = NSSelectorFromString(@"assets");

            for (id item in (NSArray *)items) {
                if ([item respondsToSelector:assetsSel]) {
                    id itemAssets = ((id (*)(id, SEL))objc_msgSend)(item, assetsSel);
                    if ([itemAssets isKindOfClass:[NSSet class]] && [(NSSet *)itemAssets count] > 0) {
                        [clipObjects addObject:item];
                        SpliceKit_log(@"[Transcript] Item %@ has %lu assets",
                            NSStringFromClass([item class]), (unsigned long)[(NSSet *)itemAssets count]);
                    }
                }
            }

            // If no items had assets, try the sequence itself
            if (clipObjects.count == 0 && [sequence respondsToSelector:assetsSel]) {
                [clipObjects addObject:sequence];
                SpliceKit_log(@"[Transcript] Using sequence as clip source");
            }

            assetArray = clipObjects;
            SpliceKit_log(@"[Transcript] Collected %lu clip objects for transcription",
                (unsigned long)assetArray.count);

        } @catch (NSException *e) {
            [self setErrorState:[NSString stringWithFormat:@"Error reading timeline: %@", e.reason]];
        }
    });

    if (!assetArray || assetArray.count == 0) {
        if (self.status != SpliceKitTranscriptStatusError) {
            [self setErrorState:@"No assets found on timeline. Try Apple Speech engine instead."];
        }
        return;
    }

    SpliceKit_log(@"[Transcript] Found %lu assets for FCP native transcription", (unsigned long)assetArray.count);

    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatusUI:[NSString stringWithFormat:@"Transcribing %lu asset(s) via FCP engine...",
            (unsigned long)assetArray.count]];
        self.progressBar.hidden = NO;
        self.progressBar.indeterminate = YES;
        [self.progressBar startAnimation:nil];
    });

    [self.mutableWords removeAllObjects];
    [self.mutableSilences removeAllObjects];

    // Call FFTranscriptionCoordinator.modalTranscriptsForClips:locale:
    // This must run off the main thread (the decompiled code asserts this)
    @try {
        Class coordClass = objc_getClass("FFTranscriptionCoordinator");
        if (!coordClass) {
            [self setErrorState:@"FFTranscriptionCoordinator not found. FCP Native engine unavailable."];
            return;
        }

        // Check if platform supports transcription
        BOOL supported = ((BOOL (*)(id, SEL))objc_msgSend)(coordClass,
            NSSelectorFromString(@"platformSupportsTranscription"));
        if (!supported) {
            [self setErrorState:@"Transcription not supported on this platform. Try Apple Speech engine."];
            return;
        }

        id coordinator = ((id (*)(id, SEL))objc_msgSend)(coordClass,
            NSSelectorFromString(@"sharedCoordinator"));
        if (!coordinator) {
            [self setErrorState:@"Could not get FFTranscriptionCoordinator. Try Apple Speech engine."];
            return;
        }

        // Get the system language or default to en-US
        NSString *locale = [[NSLocale currentLocale] languageCode] ?: @"en";
        NSString *localeID = [[NSLocale currentLocale] localeIdentifier] ?: @"en-US";

        SpliceKit_log(@"[Transcript] Calling modalTranscriptsForClips with %lu assets, locale=%@",
                      (unsigned long)assetArray.count, localeID);

        // modalTranscriptsForClips:locale: — synchronous, must be called off main thread
        // It internally calls [clip assets] on each item, so we pass the assets array
        SEL modalSel = NSSelectorFromString(@"modalTranscriptsForClips:locale:");
        id resultMap = ((id (*)(id, SEL, id, id))objc_msgSend)(coordinator, modalSel, assetArray, localeID);

        if (!resultMap) {
            [self setErrorState:@"FCP transcription returned no results. Try Apple Speech engine."];
            return;
        }

        SpliceKit_log(@"[Transcript] FCP transcription complete, processing results...");

        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStatusUI:@"Processing transcript..."];
            self.progressBar.indeterminate = NO;
            self.progressBar.doubleValue = 0.5;
        });

        // Extract words from the FFTranscript objects in the result map
        // resultMap is an NSMapTable: FFAsset -> FFTranscript
        NSUInteger totalWords = 0;

        @try {
            // NSMapTable enumeration
            id keyEnumerator = ((id (*)(id, SEL))objc_msgSend)(resultMap,
                NSSelectorFromString(@"keyEnumerator"));

            id asset;
            while ((asset = ((id (*)(id, SEL))objc_msgSend)(keyEnumerator, @selector(nextObject)))) {
                id transcript = ((id (*)(id, SEL, id))objc_msgSend)(resultMap,
                    NSSelectorFromString(@"objectForKey:"), asset);
                if (!transcript) continue;

                // Get phrases from transcript
                id phrases = ((id (*)(id, SEL))objc_msgSend)(transcript,
                    NSSelectorFromString(@"phrases"));
                if (!phrases || ![phrases isKindOfClass:[NSArray class]]) continue;

                for (id phrase in (NSArray *)phrases) {
                    // Get words from phrase
                    id phraseWords = ((id (*)(id, SEL))objc_msgSend)(phrase,
                        NSSelectorFromString(@"words"));
                    if (!phraseWords || ![phraseWords isKindOfClass:[NSArray class]]) continue;

                    for (id fcpWord in (NSArray *)phraseWords) {
                        NSString *text = ((id (*)(id, SEL))objc_msgSend)(fcpWord,
                            NSSelectorFromString(@"text"));
                        if (!text || text.length == 0) continue;

                        // Get timeRange (CMTimeRange struct)
                        SEL trSel = NSSelectorFromString(@"timeRange");
                        NSMethodSignature *sig = [fcpWord methodSignatureForSelector:trSel];
                        if (!sig || [sig methodReturnLength] != sizeof(SpliceKitTranscript_CMTimeRange)) continue;

                        SpliceKitTranscript_CMTimeRange timeRange;
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        [inv setTarget:fcpWord];
                        [inv setSelector:trSel];
                        [inv invoke];
                        [inv getReturnValue:&timeRange];

                        double startTime = CMTimeToSeconds(timeRange.start);
                        double duration = CMTimeToSeconds(timeRange.duration);

                        if (duration <= 0) continue;

                        SpliceKitTranscriptWord *word = [[SpliceKitTranscriptWord alloc] init];
                        word.text = text;
                        word.startTime = startTime;
                        word.duration = duration;
                        word.confidence = 1.0; // FCP native doesn't provide per-word confidence
                        word.speaker = @"Unknown";
                        word.sourceMediaTime = startTime; // FCP native times are source-relative

                        @synchronized (self.mutableWords) {
                            [self.mutableWords addObject:word];
                        }
                        totalWords++;
                    }
                }
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[Transcript] Exception extracting results: %@", e.reason);
        }

        SpliceKit_log(@"[Transcript] Extracted %lu words from FCP native transcription", (unsigned long)totalWords);

        // Finalize on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (self.mutableWords) {
                [self.mutableWords sortUsingComparator:^NSComparisonResult(SpliceKitTranscriptWord *a, SpliceKitTranscriptWord *b) {
                    if (a.startTime < b.startTime) return NSOrderedAscending;
                    if (a.startTime > b.startTime) return NSOrderedDescending;
                    return NSOrderedSame;
                }];

                for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
                    self.mutableWords[i].wordIndex = i;
                }
            }

            [self detectSilences];
            [self assignSpeakers];

            self.status = SpliceKitTranscriptStatusReady;
            [self rebuildTextView];
            [self startPlayheadTimer];

            self.spinner.hidden = YES;
            [self.spinner stopAnimation:nil];
            self.progressBar.hidden = YES;
            self.refreshButton.enabled = YES;
            self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);

            NSUInteger silenceCount = self.mutableSilences.count;
            [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses (FCP Native)",
                (unsigned long)self.mutableWords.count, (unsigned long)silenceCount]];

            SpliceKit_log(@"[Transcript] FCP Native complete: %lu words, %lu silences",
                          (unsigned long)self.mutableWords.count, (unsigned long)silenceCount);
        });

    } @catch (NSException *e) {
        [self setErrorState:[NSString stringWithFormat:@"FCP Native error: %@. Try Apple Speech engine.", e.reason]];
    }
}

#pragma mark - Apple Speech Transcription (SFSpeechRecognizer fallback)

- (void)performAppleSpeechTranscription {
    SpliceKit_log(@"[Transcript] Using Apple Speech engine (SFSpeechRecognizer)");
    SpliceKitTranscript_loadSpeechFramework();

    __block NSArray *clips = nil;
    __block double totalDuration = 0;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = [self getActiveTimelineModule];
            if (!timeline) {
                [self setErrorState:@"No active timeline. Open a project first."];
                return;
            }

            // Detect frame rate
            if ([timeline respondsToSelector:@selector(sequenceFrameDuration)]) {
                SpliceKitTranscript_CMTime fd = ((SpliceKitTranscript_CMTime (*)(id, SEL))objc_msgSend)(
                    timeline, @selector(sequenceFrameDuration));
                if (fd.timescale > 0 && fd.value > 0) {
                    self.frameRate = (double)fd.timescale / fd.value;
                }
            }

            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) {
                [self setErrorState:@"No sequence in timeline."];
                return;
            }

            id primaryObj = nil;
            if ([sequence respondsToSelector:@selector(primaryObject)]) {
                primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
            }
            if (!primaryObj) {
                [self setErrorState:@"No primary object in sequence."];
                return;
            }

            id items = nil;
            if ([primaryObj respondsToSelector:@selector(containedItems)]) {
                items = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
            }
            if (!items || ![items isKindOfClass:[NSArray class]]) {
                [self setErrorState:@"No items on timeline."];
                return;
            }

            NSMutableArray *clipInfos = [NSMutableArray array];
            double timelinePos = 0;

            [self collectClipsFrom:(NSArray *)items
                       atTimeline:&timelinePos
                             into:clipInfos];

            totalDuration = timelinePos;
            clips = [clipInfos copy];

        } @catch (NSException *e) {
            [self setErrorState:[NSString stringWithFormat:@"Error reading timeline: %@", e.reason]];
        }
    });

    if (!clips || clips.count == 0) {
        if (self.status != SpliceKitTranscriptStatusError) {
            [self setErrorState:@"No media clips found on timeline."];
        }
        return;
    }

    SpliceKit_log(@"[Transcript] Found %lu clips, total duration: %.2fs", (unsigned long)clips.count, totalDuration);

    [self.mutableWords removeAllObjects];
    [self.mutableSilences removeAllObjects];
    self.completedTranscriptions = 0;
    self.totalTranscriptions = 0;

    NSMutableArray *transcribableClips = [NSMutableArray array];
    for (NSDictionary *clipInfo in clips) {
        if (clipInfo[@"mediaURL"]) {
            [transcribableClips addObject:clipInfo];
        }
    }

    if (transcribableClips.count == 0) {
        [self setErrorState:@"Could not find source media files for any clips. Try providing a file path directly."];
        return;
    }

    self.totalTranscriptions = transcribableClips.count;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatusUI:[NSString stringWithFormat:@"Transcribing clip 1/%lu...",
            (unsigned long)self.totalTranscriptions]];
        self.progressBar.hidden = NO;
        self.progressBar.indeterminate = NO;
        self.progressBar.doubleValue = 0;
    });

    [self transcribeClipsSequentially:transcribableClips index:0 completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (self.mutableWords) {
                [self.mutableWords sortUsingComparator:^NSComparisonResult(SpliceKitTranscriptWord *a, SpliceKitTranscriptWord *b) {
                    if (a.startTime < b.startTime) return NSOrderedAscending;
                    if (a.startTime > b.startTime) return NSOrderedDescending;
                    return NSOrderedSame;
                }];

                for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
                    self.mutableWords[i].wordIndex = i;
                }
            }

            // Detect silences and assign speakers
            [self detectSilences];
            [self assignSpeakers];

            self.status = SpliceKitTranscriptStatusReady;
            [self rebuildTextView];
            [self startPlayheadTimer];

            self.spinner.hidden = YES;
            [self.spinner stopAnimation:nil];
            self.progressBar.hidden = YES;
            self.refreshButton.enabled = YES;
            self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);

            NSUInteger silenceCount = self.mutableSilences.count;
            [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses",
                (unsigned long)self.mutableWords.count, (unsigned long)silenceCount]];

            SpliceKit_log(@"[Transcript] Complete: %lu words, %lu silences",
                          (unsigned long)self.mutableWords.count, (unsigned long)silenceCount);
        });
    }];
}

- (void)transcribeClipsSequentially:(NSArray *)clips index:(NSUInteger)idx completion:(void(^)(void))completion {
    if (idx >= clips.count) {
        completion();
        return;
    }

    NSDictionary *clipInfo = clips[idx];
    NSURL *mediaURL = clipInfo[@"mediaURL"];
    double timelineStart = [clipInfo[@"timelineStart"] doubleValue];
    double trimStart = [clipInfo[@"trimStart"] doubleValue];
    double clipDuration = [clipInfo[@"duration"] doubleValue];
    NSString *clipHandle = clipInfo[@"handle"];

    [self transcribeAudioFile:mediaURL
                timelineStart:timelineStart
                    trimStart:trimStart
                 trimDuration:clipDuration
                   clipHandle:clipHandle
                   completion:^(NSArray<SpliceKitTranscriptWord *> *words, NSError *error) {
        if (error) {
            SpliceKit_log(@"[Transcript] Transcription error for %@: %@", mediaURL.lastPathComponent, error);
        } else {
            @synchronized (self.mutableWords) {
                [self.mutableWords addObjectsFromArray:words];
            }
            SpliceKit_log(@"[Transcript] Transcribed %lu words from %@",
                          (unsigned long)words.count, mediaURL.lastPathComponent);
        }
        self.completedTranscriptions++;

        dispatch_async(dispatch_get_main_queue(), ^{
            double progress = (double)self.completedTranscriptions / MAX(self.totalTranscriptions, 1);
            self.progressBar.doubleValue = progress;

            if (self.completedTranscriptions < self.totalTranscriptions) {
                [self updateStatusUI:[NSString stringWithFormat:@"Transcribing clip %lu/%lu (%lu words so far)...",
                    (unsigned long)(self.completedTranscriptions + 1),
                    (unsigned long)self.totalTranscriptions,
                    (unsigned long)self.mutableWords.count]];
            } else {
                [self updateStatusUI:[NSString stringWithFormat:@"Processing %lu words...",
                    (unsigned long)self.mutableWords.count]];
            }
        });

        [self transcribeClipsSequentially:clips index:idx + 1 completion:completion];
    }];
}

#pragma mark - Parakeet Transcription (NVIDIA Parakeet TDT via CLI tool)

- (NSString *)parakeetTranscriberPath {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. Inside the FCP framework bundle (deployed by patcher)
    NSString *buildDir = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Contents/Frameworks/SpliceKit.framework/Versions/A/Resources"];
    NSString *builtPath = [buildDir stringByAppendingPathComponent:@"parakeet-transcriber"];
    if ([fm fileExistsAtPath:builtPath]) return builtPath;

    // 2. Common deploy directories (matching silence-detector pattern)
    NSString *home = NSHomeDirectory();
    NSArray *searchPaths = @[
        [home stringByAppendingPathComponent:@"Desktop/SpliceKit/build/parakeet-transcriber"],
        [home stringByAppendingPathComponent:@"Documents/GitHub/SpliceKit/build/parakeet-transcriber"],
        [home stringByAppendingPathComponent:@"Desktop/SpliceKit/tools/parakeet-transcriber/.build/release/parakeet-transcriber"],
        [home stringByAppendingPathComponent:@"Documents/GitHub/SpliceKit/tools/parakeet-transcriber/.build/release/parakeet-transcriber"],
        [home stringByAppendingPathComponent:@"SpliceKit/tools/parakeet-transcriber/.build/release/parakeet-transcriber"],
        [home stringByAppendingPathComponent:@"Library/Caches/SpliceKit/tools/parakeet-transcriber/.build/release/parakeet-transcriber"],
    ];
    for (NSString *path in searchPaths) {
        if ([fm fileExistsAtPath:path]) return path;
    }

    return nil;
}

- (NSString *)findParakeetTranscriberProjectDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *home = NSHomeDirectory();
    NSArray *candidates = @[
        [home stringByAppendingPathComponent:@"Documents/GitHub/SpliceKit/tools/parakeet-transcriber"],
        [home stringByAppendingPathComponent:@"Desktop/SpliceKit/tools/parakeet-transcriber"],
        [home stringByAppendingPathComponent:@"SpliceKit/tools/parakeet-transcriber"],
        [home stringByAppendingPathComponent:@"Library/Caches/SpliceKit/tools/parakeet-transcriber"],
    ];
    for (NSString *path in candidates) {
        if ([fm fileExistsAtPath:[path stringByAppendingPathComponent:@"Package.swift"]]) {
            return path;
        }
    }
    return nil;
}

- (BOOL)buildParakeetTranscriberWithStatus:(void(^)(NSString *status))statusUpdate {
    NSString *projectDir = [self findParakeetTranscriberProjectDir];
    if (!projectDir) {
        SpliceKit_log(@"[Transcript] Parakeet transcriber project not found in any known location");
        return NO;
    }

    statusUpdate(@"Building Parakeet transcriber (first time only)...");
    SpliceKit_log(@"[Transcript] Building Parakeet transcriber...");

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/swift";
    task.arguments = @[@"build", @"-c", @"release"];
    task.currentDirectoryPath = projectDir;

    NSPipe *outputPipe = [NSPipe pipe];
    task.standardOutput = outputPipe;
    task.standardError = outputPipe;

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        SpliceKit_log(@"[Transcript] Failed to launch swift build: %@", e.reason);
        return NO;
    }

    NSData *outputData = [outputPipe.fileHandleForReading readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];

    if (task.terminationStatus != 0) {
        SpliceKit_log(@"[Transcript] Parakeet build failed (exit code %d)", task.terminationStatus);
        // Log last 500 chars of build output for diagnostics
        NSString *tail = output.length > 500 ? [output substringFromIndex:output.length - 500] : output;
        SpliceKit_log(@"[Transcript] Build output (last 500 chars): %@", tail);

        // Check for specific build failures
        if ([output containsString:@"xcrun: error"] || [output containsString:@"xcode-select"]) {
            SpliceKit_log(@"[Transcript] CAUSE: Xcode Command Line Tools not installed");
        } else if ([output containsString:@"no such module"]) {
            SpliceKit_log(@"[Transcript] CAUSE: Swift package dependency resolution failed — check network");
        } else if ([output containsString:@"No space left"]) {
            SpliceKit_log(@"[Transcript] CAUSE: Disk full during build");
        } else if ([output containsString:@"Cannot find"]) {
            SpliceKit_log(@"[Transcript] CAUSE: Source files may be corrupted — re-run patcher");
        }
        return NO;
    }

    SpliceKit_log(@"[Transcript] Parakeet transcriber built successfully");
    return YES;
}

- (void)performParakeetTranscription {
    SpliceKit_log(@"[Transcript] Using Parakeet engine (FluidAudio)");

    // Check / build the CLI tool
    NSString *binaryPath = [self parakeetTranscriberPath];
    if (!binaryPath) {
        __block BOOL buildOK = NO;
        buildOK = [self buildParakeetTranscriberWithStatus:^(NSString *status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateStatusUI:status];
                self.progressBar.indeterminate = YES;
            });
        }];
        if (!buildOK) {
            // Check for common causes
            NSString *xcodeCheck = @"";
            NSTask *xcTask = [[NSTask alloc] init];
            xcTask.launchPath = @"/usr/bin/xcode-select";
            xcTask.arguments = @[@"-p"];
            NSPipe *xcPipe = [NSPipe pipe];
            xcTask.standardOutput = xcPipe;
            xcTask.standardError = xcPipe;
            @try {
                [xcTask launch];
                [xcTask waitUntilExit];
                if (xcTask.terminationStatus != 0) {
                    xcodeCheck = @" Xcode Command Line Tools are NOT installed — run: xcode-select --install";
                }
            } @catch (NSException *e) {
                xcodeCheck = @" Could not check for Xcode CLT.";
            }

            [self setErrorState:[NSString stringWithFormat:
                @"Failed to build Parakeet transcriber.%@ Re-run the SpliceKit Patcher to fix this.", xcodeCheck]];
            SpliceKit_log(@"[Transcript] Parakeet build failed.%@ Searched: ~/Library/Caches/SpliceKit/tools/parakeet-transcriber/", xcodeCheck);
            return;
        }
        binaryPath = [self parakeetTranscriberPath];
        if (!binaryPath) {
            [self setErrorState:@"Parakeet transcriber binary not found after build."];
            return;
        }
    }

    SpliceKit_log(@"[Transcript] Using parakeet-transcriber at: %@", binaryPath);

    // Collect clips from timeline (reuse existing logic)
    __block NSArray *clips = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = [self getActiveTimelineModule];
            if (!timeline) {
                [self setErrorState:@"No active timeline. Open a project first."];
                return;
            }

            // Detect frame rate
            if ([timeline respondsToSelector:@selector(sequenceFrameDuration)]) {
                SpliceKitTranscript_CMTime fd = ((SpliceKitTranscript_CMTime (*)(id, SEL))objc_msgSend)(
                    timeline, @selector(sequenceFrameDuration));
                if (fd.timescale > 0 && fd.value > 0) {
                    self.frameRate = (double)fd.timescale / fd.value;
                }
            }

            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) { [self setErrorState:@"No sequence in timeline."]; return; }

            id primaryObj = nil;
            if ([sequence respondsToSelector:@selector(primaryObject)]) {
                primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
            }
            if (!primaryObj) { [self setErrorState:@"No primary object in sequence."]; return; }

            id items = nil;
            if ([primaryObj respondsToSelector:@selector(containedItems)]) {
                items = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
            }
            if (!items || ![items isKindOfClass:[NSArray class]]) {
                [self setErrorState:@"No items on timeline."]; return;
            }

            NSMutableArray *clipInfos = [NSMutableArray array];
            double timelinePos = 0;
            [self collectClipsFrom:(NSArray *)items atTimeline:&timelinePos into:clipInfos];
            clips = [clipInfos copy];
        } @catch (NSException *e) {
            [self setErrorState:[NSString stringWithFormat:@"Error reading timeline: %@", e.reason]];
        }
    });

    if (!clips || clips.count == 0) {
        if (self.status != SpliceKitTranscriptStatusError) {
            [self setErrorState:@"No media clips found on timeline."];
        }
        return;
    }

    // Filter to clips with media URLs
    NSMutableArray *transcribableClips = [NSMutableArray array];
    for (NSDictionary *clipInfo in clips) {
        if (clipInfo[@"mediaURL"]) {
            [transcribableClips addObject:clipInfo];
        }
    }

    if (transcribableClips.count == 0) {
        [self setErrorState:@"Could not find source media files for any clips."];
        return;
    }

    [self.mutableWords removeAllObjects];
    [self.mutableSilences removeAllObjects];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatusUI:[NSString stringWithFormat:@"Transcribing %lu clips with Parakeet...",
            (unsigned long)transcribableClips.count]];
        self.progressBar.hidden = NO;
        self.progressBar.indeterminate = NO;
        self.progressBar.doubleValue = 0;
    });

    // Build batch manifest — deduplicate so each source file is transcribed only once
    NSString *manifestPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_batch.json"];
    NSMutableOrderedSet *uniqueFiles = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *clipInfo in transcribableClips) {
        NSURL *mediaURL = clipInfo[@"mediaURL"];
        [uniqueFiles addObject:mediaURL.path];
    }
    NSMutableArray *manifestEntries = [NSMutableArray array];
    for (NSString *file in uniqueFiles) {
        [manifestEntries addObject:@{@"file": file}];
    }
    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifestEntries options:0 error:nil];
    [manifestData writeToFile:manifestPath atomically:YES];

    SpliceKit_log(@"[Transcript] Parakeet batch: %lu clips, %lu unique files",
        (unsigned long)transcribableClips.count, (unsigned long)uniqueFiles.count);

    // Build arguments for batch mode
    NSMutableArray *taskArgs = [NSMutableArray arrayWithObjects:@"--batch", manifestPath, @"--progress", nil];
    if (self.speakerDetectionEnabled) {
        [taskArgs addObject:@"--speakers"];
    }
    [taskArgs addObject:@"--model"];
    [taskArgs addObject:self.parakeetModelVersion ?: @"v3"];

    // Run the CLI tool with streaming stderr for progress
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = binaryPath;
    task.arguments = taskArgs;

    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;

    // Read stdout asynchronously to prevent pipe buffer deadlock
    __block NSMutableData *stdoutAccum = [NSMutableData data];
    stdoutPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length > 0) {
            @synchronized (stdoutAccum) {
                [stdoutAccum appendData:data];
            }
        }
    };

    // Read stderr asynchronously for live progress updates
    NSUInteger totalClips = transcribableClips.count;
    stderrPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) return;

        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) return;

        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"PROGRESS:"]) {
                NSArray *parts = [line componentsSeparatedByString:@":"];
                if (parts.count >= 3) {
                    double frac = [parts[1] doubleValue];
                    NSString *msg = [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)]
                        componentsJoinedByString:@":"];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.progressBar.indeterminate = NO;
                        self.progressBar.doubleValue = frac;
                        [self updateStatusUI:[NSString stringWithFormat:@"Parakeet: %@", msg]];
                    });
                }
            } else if ([line hasPrefix:@"ERROR:"]) {
                NSString *errMsg = [line substringFromIndex:6];
                SpliceKit_log(@"[Transcript] Parakeet: %@", errMsg);
                // Show actionable errors in the UI too
                if ([errMsg containsString:@"Network"] || [errMsg containsString:@"network"] ||
                    [errMsg containsString:@"connect"] || [errMsg containsString:@"internet"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self updateStatusUI:@"Parakeet: Network error — check internet connection"];
                    });
                } else if ([errMsg containsString:@"rate-limited"] || [errMsg containsString:@"rate limit"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self updateStatusUI:@"Parakeet: Download rate-limited — wait a few minutes and retry"];
                    });
                } else if ([errMsg containsString:@"disk"] || [errMsg containsString:@"space"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self updateStatusUI:@"Parakeet: Not enough disk space (~475 MB needed)"];
                    });
                } else if ([errMsg containsString:@"INFO:"]) {
                    // Informational, just log
                } else if ([errMsg containsString:@"TIP:"]) {
                    SpliceKit_log(@"[Transcript] %@", errMsg);
                }
            }
        }
    };

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        SpliceKit_log(@"[Transcript] Parakeet task failed: %@", e.reason);
        stdoutPipe.fileHandleForReading.readabilityHandler = nil;
        stderrPipe.fileHandleForReading.readabilityHandler = nil;
        [self setErrorState:[NSString stringWithFormat:@"Parakeet failed: %@", e.reason]];
        return;
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = nil;
    stderrPipe.fileHandleForReading.readabilityHandler = nil;

    NSData *remaining = [stdoutPipe.fileHandleForReading readDataToEndOfFile];
    if (remaining.length > 0) {
        @synchronized (stdoutAccum) {
            [stdoutAccum appendData:remaining];
        }
    }

    // Clean up manifest
    [[NSFileManager defaultManager] removeItemAtPath:manifestPath error:nil];

    if (task.terminationStatus != 0) {
        SpliceKit_log(@"[Transcript] Parakeet process exited with code %d", task.terminationStatus);
        // Read any remaining stderr for clues
        NSData *stderrRemaining = [stderrPipe.fileHandleForReading readDataToEndOfFile];
        NSString *stderrText = [[NSString alloc] initWithData:stderrRemaining encoding:NSUTF8StringEncoding] ?: @"";
        if (stderrText.length > 0) {
            SpliceKit_log(@"[Transcript] Parakeet final stderr: %@", stderrText);
        }

        // Build a user-friendly error from whatever we know
        NSString *userError = @"Parakeet transcription failed.";
        if ([stderrText containsString:@"network"] || [stderrText containsString:@"connect"]) {
            userError = @"Parakeet failed — could not download model. Check your internet connection.";
        } else if ([stderrText containsString:@"rate-limited"]) {
            userError = @"Parakeet failed — download rate-limited. Wait a few minutes and try again.";
        } else if ([stderrText containsString:@"disk"] || [stderrText containsString:@"space"]) {
            userError = @"Parakeet failed — not enough disk space for model (~475 MB required).";
        } else if ([stderrText containsString:@"memory"] || [stderrText containsString:@"Memory"]) {
            userError = @"Parakeet failed — not enough memory. Close other apps and try again.";
        } else if ([stderrText containsString:@"Intel"] || [stderrText containsString:@"Neural Engine"]) {
            userError = @"Parakeet requires Apple Silicon (M1+). Use Apple Speech engine instead.";
        }
        [self setErrorState:[NSString stringWithFormat:@"%@ Check ~/Library/Logs/SpliceKit/splicekit.log for details.", userError]];
        return;
    }

    // Parse batch JSON output: [{"file":"path","words":[...]}, ...]
    NSData *jsonData;
    @synchronized (stdoutAccum) {
        jsonData = [stdoutAccum copy];
    }
    NSArray *batchResults = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];

    if (![batchResults isKindOfClass:[NSArray class]]) {
        SpliceKit_log(@"[Transcript] Parakeet returned invalid batch JSON");
        [self setErrorState:@"Parakeet returned invalid output."];
        return;
    }

    // Map results back to clips by file path
    NSMutableDictionary *resultsByFile = [NSMutableDictionary dictionary];
    for (NSDictionary *result in batchResults) {
        NSString *file = result[@"file"];
        NSArray *words = result[@"words"];
        if (file && [words isKindOfClass:[NSArray class]]) {
            resultsByFile[file] = words;
        }
    }

    // Process results for each clip
    @synchronized (self.mutableWords) {
        for (NSDictionary *clipInfo in transcribableClips) {
            NSURL *mediaURL = clipInfo[@"mediaURL"];
            double timelineStart = [clipInfo[@"timelineStart"] doubleValue];
            double trimStart = [clipInfo[@"trimStart"] doubleValue];
            double clipDuration = [clipInfo[@"duration"] doubleValue];
            NSString *clipHandle = clipInfo[@"handle"];

            NSArray *wordDicts = resultsByFile[mediaURL.path];
            if (!wordDicts) {
                SpliceKit_log(@"[Transcript] No results for %@", mediaURL.lastPathComponent);
                continue;
            }

            NSUInteger wordsAdded = 0;
            for (NSDictionary *wd in wordDicts) {
                NSString *text = wd[@"word"];
                double startTime = [wd[@"startTime"] doubleValue];
                double endTime = [wd[@"endTime"] doubleValue];
                double confidence = [wd[@"confidence"] doubleValue];
                NSString *speaker = wd[@"speaker"] ?: @"Unknown";

                if (startTime >= trimStart && startTime < trimStart + clipDuration) {
                    SpliceKitTranscriptWord *word = [[SpliceKitTranscriptWord alloc] init];
                    word.text = text;
                    word.startTime = timelineStart + (startTime - trimStart);
                    word.duration = MIN(endTime - startTime, (trimStart + clipDuration) - startTime);
                    word.confidence = confidence;
                    word.clipHandle = clipHandle;
                    word.clipTimelineStart = timelineStart;
                    word.sourceMediaOffset = trimStart;
                    word.sourceMediaTime = startTime;
                    word.sourceMediaPath = mediaURL.path;
                    word.speaker = speaker;
                    [self.mutableWords addObject:word];
                    wordsAdded++;
                }
            }

            SpliceKit_log(@"[Transcript] Parakeet got %lu words from %@",
                (unsigned long)wordsAdded, mediaURL.lastPathComponent);
        }
    }

    // Finalize — sort, index, detect silences, build UI
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self.mutableWords) {
            [self.mutableWords sortUsingComparator:^NSComparisonResult(SpliceKitTranscriptWord *a, SpliceKitTranscriptWord *b) {
                if (a.startTime < b.startTime) return NSOrderedAscending;
                if (a.startTime > b.startTime) return NSOrderedDescending;
                return NSOrderedSame;
            }];
            for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
                self.mutableWords[i].wordIndex = i;
            }
        }

        [self detectSilences];
        [self assignSpeakers];

        self.status = SpliceKitTranscriptStatusReady;
        [self rebuildTextView];
        [self startPlayheadTimer];

        self.spinner.hidden = YES;
        [self.spinner stopAnimation:nil];
        self.progressBar.hidden = YES;
        self.refreshButton.enabled = YES;
        self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);

        [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses (Parakeet)",
            (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSilences.count]];

        SpliceKit_log(@"[Transcript] Parakeet transcription complete: %lu words, %lu silences",
            (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSilences.count);
    });
}

#pragma mark - Silence Detection

- (void)detectSilences {
    [self.mutableSilences removeAllObjects];

    @synchronized (self.mutableWords) {
        if (self.mutableWords.count < 2) return;

        for (NSUInteger i = 0; i < self.mutableWords.count - 1; i++) {
            SpliceKitTranscriptWord *current = self.mutableWords[i];
            SpliceKitTranscriptWord *next = self.mutableWords[i + 1];

            double gap = next.startTime - current.endTime;
            if (gap >= self.silenceThreshold) {
                SpliceKitTranscriptSilence *silence = [[SpliceKitTranscriptSilence alloc] init];
                silence.startTime = current.endTime;
                silence.endTime = next.startTime;
                silence.duration = gap;
                silence.afterWordIndex = i;
                [self.mutableSilences addObject:silence];
            }
        }
    }

    SpliceKit_log(@"[Transcript] Detected %lu silences (threshold: %.2fs)",
                  (unsigned long)self.mutableSilences.count, self.silenceThreshold);
}

#pragma mark - Speaker Assignment

- (void)assignSpeakers {
    // If speaker diarization provided real labels (macOS 26+), keep them.
    // Otherwise label unknown words as "Unknown" (same as Premiere Pro).
    // Users can always manually override via setSpeaker:forWordsFrom:count:.
    @synchronized (self.mutableWords) {
        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            if (!word.speaker || word.speaker.length == 0) {
                word.speaker = @"Unknown";
            }
        }
    }
}

- (void)setSpeaker:(NSString *)speaker forWordsFrom:(NSUInteger)startIndex count:(NSUInteger)count {
    @synchronized (self.mutableWords) {
        NSUInteger end = MIN(startIndex + count, self.mutableWords.count);
        for (NSUInteger i = startIndex; i < end; i++) {
            self.mutableWords[i].speaker = speaker;
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self rebuildTextView];
    });
}

#pragma mark - Media URL Discovery

- (NSURL *)getMediaURLForClip:(id)clip {
    // Chain 1: clip.media.originalMediaURL
    @try {
        if ([clip respondsToSelector:NSSelectorFromString(@"media")]) {
            id media = ((id (*)(id, SEL))objc_msgSend)(clip, NSSelectorFromString(@"media"));
            if (media) {
                SEL omSel = NSSelectorFromString(@"originalMediaURL");
                if ([media respondsToSelector:omSel]) {
                    id url = ((id (*)(id, SEL))objc_msgSend)(media, omSel);
                    if (url && [url isKindOfClass:[NSURL class]]) return url;
                }

                SEL omrSel = NSSelectorFromString(@"originalMediaRep");
                if ([media respondsToSelector:omrSel]) {
                    id rep = ((id (*)(id, SEL))objc_msgSend)(media, omrSel);
                    if (rep) {
                        SEL fuSel = NSSelectorFromString(@"fileURLs");
                        if ([rep respondsToSelector:fuSel]) {
                            id urls = ((id (*)(id, SEL))objc_msgSend)(rep, fuSel);
                            if ([urls isKindOfClass:[NSArray class]] && [(NSArray *)urls count] > 0) {
                                id url = [(NSArray *)urls firstObject];
                                if ([url isKindOfClass:[NSURL class]]) return url;
                            }
                        }
                        SEL urlSel = NSSelectorFromString(@"URL");
                        if ([rep respondsToSelector:urlSel]) {
                            id url = ((id (*)(id, SEL))objc_msgSend)(rep, urlSel);
                            if ([url isKindOfClass:[NSURL class]]) return url;
                        }
                    }
                }

                SEL crSel = NSSelectorFromString(@"currentRep");
                if ([media respondsToSelector:crSel]) {
                    id rep = ((id (*)(id, SEL))objc_msgSend)(media, crSel);
                    if (rep) {
                        SEL fuSel = NSSelectorFromString(@"fileURLs");
                        if ([rep respondsToSelector:fuSel]) {
                            id urls = ((id (*)(id, SEL))objc_msgSend)(rep, fuSel);
                            if ([urls isKindOfClass:[NSArray class]] && [(NSArray *)urls count] > 0) {
                                id url = [(NSArray *)urls firstObject];
                                if ([url isKindOfClass:[NSURL class]]) return url;
                            }
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Transcript] Exception getting media URL (chain 1): %@", e.reason);
    }

    // Chain 2: clip.assetMediaReference -> resolvedURL
    @try {
        SEL amrSel = NSSelectorFromString(@"assetMediaReference");
        if ([clip respondsToSelector:amrSel]) {
            id ref = ((id (*)(id, SEL))objc_msgSend)(clip, amrSel);
            if (ref) {
                SEL ruSel = NSSelectorFromString(@"resolvedURL");
                if ([ref respondsToSelector:ruSel]) {
                    id url = ((id (*)(id, SEL))objc_msgSend)(ref, ruSel);
                    if ([url isKindOfClass:[NSURL class]]) return url;
                }
            }
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Transcript] Exception getting media URL (chain 2): %@", e.reason);
    }

    // Chain 3: KVC path clip.media.fileURL
    @try {
        id url = [clip valueForKeyPath:@"media.fileURL"];
        if ([url isKindOfClass:[NSURL class]]) return url;
    } @catch (NSException *e) {}

    // Chain 4: KVC path clip.clipInPlace.asset.originalMediaURL
    @try {
        id url = [clip valueForKeyPath:@"clipInPlace.asset.originalMediaURL"];
        if ([url isKindOfClass:[NSURL class]]) return url;
    } @catch (NSException *e) {}

    // Chain 5: iterate properties looking for NSURL
    @try {
        if ([clip respondsToSelector:NSSelectorFromString(@"media")]) {
            id media = ((id (*)(id, SEL))objc_msgSend)(clip, NSSelectorFromString(@"media"));
            if (media) {
                unsigned int propCount = 0;
                Class cls = [media class];
                while (cls && cls != [NSObject class]) {
                    objc_property_t *props = class_copyPropertyList(cls, &propCount);
                    for (unsigned int i = 0; i < propCount; i++) {
                        NSString *propName = @(property_getName(props[i]));
                        if ([propName.lowercaseString containsString:@"url"] ||
                            [propName.lowercaseString containsString:@"path"] ||
                            [propName.lowercaseString containsString:@"file"]) {
                            @try {
                                id val = [media valueForKey:propName];
                                if ([val isKindOfClass:[NSURL class]]) {
                                    free(props);
                                    return val;
                                }
                                if ([val isKindOfClass:[NSString class]] &&
                                    [(NSString *)val hasPrefix:@"/"]) {
                                    NSURL *url = [NSURL fileURLWithPath:val];
                                    if ([[NSFileManager defaultManager] fileExistsAtPath:val]) {
                                        free(props);
                                        return url;
                                    }
                                }
                            } @catch (NSException *e) {}
                        }
                    }
                    free(props);
                    cls = class_getSuperclass(cls);
                }
            }
        }
    } @catch (NSException *e) {}

    return nil;
}

#pragma mark - Speech Transcription

- (void)transcribeAudioFile:(NSURL *)audioURL
              timelineStart:(double)timelineStart
                  trimStart:(double)trimStart
               trimDuration:(double)trimDuration
                 clipHandle:(NSString *)clipHandle
                 completion:(void(^)(NSArray<SpliceKitTranscriptWord *> *, NSError *))completion {

    if (!SFSpeechRecognizerClass || !SFSpeechURLRecognitionRequestClass) {
        completion(nil, [NSError errorWithDomain:@"SpliceKitTranscript" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Speech framework not available"}]);
        return;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:audioURL.path]) {
        SpliceKit_log(@"[Transcript] File not found: %@", audioURL.path);
        completion(nil, [NSError errorWithDomain:@"SpliceKitTranscript" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"Media file not found"}]);
        return;
    }

    SpliceKit_log(@"[Transcript] Transcribing: %@ (timeline:%.2f, trim:%.2f, dur:%.2f)",
                  audioURL.lastPathComponent, timelineStart, trimStart, trimDuration);

    id recognizer = ((id (*)(id, SEL, id))objc_msgSend)(
        [SFSpeechRecognizerClass alloc],
        NSSelectorFromString(@"initWithLocale:"),
        [NSLocale localeWithLocaleIdentifier:@"en-US"]);

    if (!recognizer) {
        completion(nil, [NSError errorWithDomain:@"SpliceKitTranscript" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"Could not create speech recognizer"}]);
        return;
    }

    BOOL isAvailable = ((BOOL (*)(id, SEL))objc_msgSend)(recognizer, NSSelectorFromString(@"isAvailable"));
    if (!isAvailable) {
        completion(nil, [NSError errorWithDomain:@"SpliceKitTranscript" code:4
            userInfo:@{NSLocalizedDescriptionKey: @"Speech recognizer not available"}]);
        return;
    }

    id request = ((id (*)(id, SEL, id))objc_msgSend)(
        [SFSpeechURLRecognitionRequestClass alloc],
        NSSelectorFromString(@"initWithURL:"),
        audioURL);

    if (!request) {
        completion(nil, [NSError errorWithDomain:@"SpliceKitTranscript" code:5
            userInfo:@{NSLocalizedDescriptionKey: @"Could not create recognition request"}]);
        return;
    }

    // Enable partial results so we get streaming progress for long clips
    ((void (*)(id, SEL, BOOL))objc_msgSend)(request,
        NSSelectorFromString(@"setShouldReportPartialResults:"), YES);

    // Use on-device recognition — faster, no network needed, and avoids stricter
    // authorization requirements that can prevent the app from appearing in Settings
    SEL onDeviceSel = NSSelectorFromString(@"setRequiresOnDeviceRecognition:");
    if ([request respondsToSelector:onDeviceSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(request, onDeviceSel, YES);
    }

    // macOS 26+: Enable speaker diarization if user opted in
    __block BOOL useSpeakerDiarization = NO;
    if (self.speakerDetectionEnabled && SpliceKitTranscript_isSpeakerDiarizationAvailable()) {
        SEL speakerSel = NSSelectorFromString(@"setAddsSpeakerAttribution:");
        if ([request respondsToSelector:speakerSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(request, speakerSel, YES);
            useSpeakerDiarization = YES;
            SpliceKit_log(@"[Transcript] Speaker diarization enabled (macOS 26+)");
        } else {
            SpliceKit_log(@"[Transcript] Speaker diarization selector not available on this request");
        }
    }

    // Track last partial word count for progress updates
    __block NSUInteger lastPartialCount = 0;

    SEL taskSel = NSSelectorFromString(@"recognitionTaskWithRequest:resultHandler:");
    ((id (*)(id, SEL, id, id))objc_msgSend)(recognizer, taskSel, request,
        ^(id result, NSError *error) {
            if (error && !result) {
                completion(nil, error);
                return;
            }

            BOOL isFinal = ((BOOL (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"isFinal"));

            id transcription = ((id (*)(id, SEL))objc_msgSend)(result,
                NSSelectorFromString(@"bestTranscription"));
            if (!transcription) {
                if (isFinal) completion(@[], nil);
                return;
            }

            id segments = ((id (*)(id, SEL))objc_msgSend)(transcription,
                NSSelectorFromString(@"segments"));
            if (!segments || ![segments isKindOfClass:[NSArray class]]) {
                if (isFinal) completion(@[], nil);
                return;
            }

            NSUInteger segCount = [(NSArray *)segments count];

            // Update progress on partial results (throttled to every 10 new words)
            if (!isFinal) {
                if (segCount > lastPartialCount + 10) {
                    lastPartialCount = segCount;
                    // Estimate progress based on latest word timestamp vs clip duration
                    double latestTime = 0;
                    if (segCount > 0) {
                        id lastSeg = [(NSArray *)segments lastObject];
                        latestTime = ((double (*)(id, SEL))objc_msgSend)(lastSeg,
                            NSSelectorFromString(@"timestamp"));
                    }
                    double progressFraction = (trimDuration > 0) ? (latestTime - trimStart) / trimDuration : 0;
                    progressFraction = MIN(MAX(progressFraction, 0), 0.99);

                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.progressBar.indeterminate = NO;
                        self.progressBar.doubleValue = progressFraction;
                        [self updateStatusUI:[NSString stringWithFormat:@"Transcribing... %lu words (%.0f%%)",
                            (unsigned long)segCount, progressFraction * 100]];
                    });
                }
                return; // Wait for final result
            }

            // Final result — extract all words
            NSMutableArray<SpliceKitTranscriptWord *> *words = [NSMutableArray array];
            NSMutableSet *speakerNames = [NSMutableSet set];

            for (id segment in (NSArray *)segments) {
                NSString *text = ((id (*)(id, SEL))objc_msgSend)(segment,
                    NSSelectorFromString(@"substring"));
                double timestamp = ((double (*)(id, SEL))objc_msgSend)(segment,
                    NSSelectorFromString(@"timestamp"));
                double duration = ((double (*)(id, SEL))objc_msgSend)(segment,
                    NSSelectorFromString(@"duration"));
                float confidence = ((float (*)(id, SEL))objc_msgSend)(segment,
                    NSSelectorFromString(@"confidence"));

                // macOS 26+: Extract speaker label from segment
                NSString *speakerLabel = @"Unknown";
                if (useSpeakerDiarization) {
                    // Try speakerAttribution property (SFSpeakerAttribution object)
                    SEL attrSel = NSSelectorFromString(@"speakerAttribution");
                    if ([segment respondsToSelector:attrSel]) {
                        id attribution = ((id (*)(id, SEL))objc_msgSend)(segment, attrSel);
                        if (attribution) {
                            // SFSpeakerAttribution has a 'speaker' property (SFSpeaker)
                            SEL speakerSel = NSSelectorFromString(@"speaker");
                            if ([attribution respondsToSelector:speakerSel]) {
                                id speaker = ((id (*)(id, SEL))objc_msgSend)(attribution, speakerSel);
                                if (speaker) {
                                    // SFSpeaker has identifier/name
                                    SEL nameSel = NSSelectorFromString(@"identifier");
                                    if ([speaker respondsToSelector:nameSel]) {
                                        NSString *name = ((id (*)(id, SEL))objc_msgSend)(speaker, nameSel);
                                        if (name.length > 0) {
                                            speakerLabel = [NSString stringWithFormat:@"Speaker %@", name];
                                        }
                                    }
                                    if ([speakerLabel isEqualToString:@"Unknown"]) {
                                        // Fallback: try description or displayName
                                        SEL dispSel = NSSelectorFromString(@"displayName");
                                        if ([speaker respondsToSelector:dispSel]) {
                                            NSString *dn = ((id (*)(id, SEL))objc_msgSend)(speaker, dispSel);
                                            if (dn.length > 0) speakerLabel = dn;
                                        }
                                    }
                                }
                            }
                            // Fallback: attribution might directly have speakerIdentifier
                            if ([speakerLabel isEqualToString:@"Unknown"]) {
                                SEL idSel = NSSelectorFromString(@"speakerIdentifier");
                                if ([attribution respondsToSelector:idSel]) {
                                    NSString *sid = ((id (*)(id, SEL))objc_msgSend)(attribution, idSel);
                                    if (sid.length > 0) {
                                        speakerLabel = [NSString stringWithFormat:@"Speaker %@", sid];
                                    }
                                }
                            }
                        }
                    }
                    [speakerNames addObject:speakerLabel];
                }

                if (timestamp >= trimStart && timestamp < trimStart + trimDuration) {
                    SpliceKitTranscriptWord *word = [[SpliceKitTranscriptWord alloc] init];
                    word.text = text;
                    word.startTime = timelineStart + (timestamp - trimStart);
                    word.duration = MIN(duration, (trimStart + trimDuration) - timestamp);
                    word.confidence = confidence;
                    word.clipHandle = clipHandle;
                    word.clipTimelineStart = timelineStart;
                    word.sourceMediaOffset = trimStart;
                    word.sourceMediaTime = timestamp; // raw time in source file (immutable)
                    word.sourceMediaPath = audioURL.path;
                    word.speaker = speakerLabel;
                    [words addObject:word];
                }
            }

            if (useSpeakerDiarization) {
                SpliceKit_log(@"[Transcript] Got %lu words with %lu unique speakers from segments",
                    (unsigned long)words.count, (unsigned long)speakerNames.count);
            } else {
                SpliceKit_log(@"[Transcript] Got %lu words from segments", (unsigned long)words.count);
            }
            completion(words, nil);
        });
}

- (void)transcribeFromURL:(NSURL *)audioURL {
    [self transcribeFromURL:audioURL timelineStart:0 trimStart:0 trimDuration:HUGE_VAL];
}

- (void)transcribeFromURL:(NSURL *)audioURL
       timelineStart:(double)timelineStart
       trimStart:(double)trimStart
       trimDuration:(double)trimDuration {

    SpliceKit_log(@"[Transcript] Transcribing file: %@", audioURL.path);

    dispatch_async(dispatch_get_main_queue(), ^{
        self.status = SpliceKitTranscriptStatusTranscribing;
        self.errorMessage = nil;
        [self updateStatusUI:@"Transcribing audio file..."];
        self.spinner.hidden = NO;
        [self.spinner startAnimation:nil];
        self.progressBar.hidden = NO;
        self.progressBar.indeterminate = YES;
        [self.progressBar startAnimation:nil];
        self.refreshButton.enabled = NO;
        self.deleteSilencesButton.enabled = NO;
    });

    [self requestSpeechAuthorizationWithCompletion:^(BOOL authorized) {
        if (!authorized) {
            [self openSpeechRecognitionSettings];
            [self setErrorState:@"Speech recognition not authorized. Opening System Settings..."];
            return;
        }

        [self.mutableWords removeAllObjects];
        [self.mutableSilences removeAllObjects];

        [self transcribeAudioFile:audioURL
                    timelineStart:timelineStart
                        trimStart:trimStart
                     trimDuration:(trimDuration == HUGE_VAL ? 7200.0 : trimDuration)
                       clipHandle:nil
                       completion:^(NSArray<SpliceKitTranscriptWord *> *words, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) {
                    [self setErrorState:[NSString stringWithFormat:@"Transcription error: %@",
                        error.localizedDescription]];
                } else {
                    @synchronized (self.mutableWords) {
                        [self.mutableWords addObjectsFromArray:words];
                        for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
                            self.mutableWords[i].wordIndex = i;
                        }
                    }

                    [self detectSilences];
                    [self assignSpeakers];

                    self.status = SpliceKitTranscriptStatusReady;
                    [self rebuildTextView];
                    [self startPlayheadTimer];
                    self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);

                    NSUInteger silenceCount = self.mutableSilences.count;
                    [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses",
                        (unsigned long)self.mutableWords.count, (unsigned long)silenceCount]];
                }

                self.spinner.hidden = YES;
                [self.spinner stopAnimation:nil];
                self.progressBar.hidden = YES;
                self.refreshButton.enabled = YES;
            });
        }];
    }];
}

#pragma mark - Text View Display

- (void)rebuildTextView {
    self.suppressTextViewCallbacks = YES;
    self.lastPlayheadHighlightRange = NSMakeRange(NSNotFound, 0);

    NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc] init];
    NSUInteger textPos = 0;

    // Color definitions
    NSColor *normalColor = [NSColor colorWithCalibratedWhite:0.9 alpha:1.0];
    NSColor *lowConfColor = [NSColor systemOrangeColor];
    NSColor *headerSpeakerColor = [NSColor colorWithCalibratedRed:0.6 green:0.75 blue:1.0 alpha:1.0];
    NSColor *headerTimeColor = [NSColor colorWithCalibratedWhite:0.5 alpha:1.0];
    NSColor *silenceBgColor = [NSColor colorWithCalibratedRed:0.82 green:0.62 blue:0.17 alpha:1.0];
    NSColor *silenceFgColor = [NSColor colorWithCalibratedWhite:0.1 alpha:1.0];

    NSFont *normalFont = [NSFont systemFontOfSize:15];
    NSFont *headerSpeakerFont = [NSFont boldSystemFontOfSize:13];
    NSFont *headerTimeFont = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    NSFont *silenceFont = [NSFont boldSystemFontOfSize:13];

    NSDictionary *normalAttrs = @{
        NSFontAttributeName: normalFont,
        NSForegroundColorAttributeName: normalColor,
        NSCursorAttributeName: [NSCursor pointingHandCursor],
        FCPAttrItemType: @"word",
    };

    NSDictionary *lowConfAttrs = @{
        NSFontAttributeName: normalFont,
        NSForegroundColorAttributeName: lowConfColor,
        NSCursorAttributeName: [NSCursor pointingHandCursor],
        FCPAttrItemType: @"word",
    };

    // Build silence lookup: afterWordIndex -> silence
    NSMutableDictionary<NSNumber *, SpliceKitTranscriptSilence *> *silenceMap = [NSMutableDictionary dictionary];
    for (SpliceKitTranscriptSilence *s in self.mutableSilences) {
        silenceMap[@(s.afterWordIndex)] = s;
    }

    @synchronized (self.mutableWords) {
        if (self.mutableWords.count == 0) {
            self.suppressTextViewCallbacks = NO;
            return;
        }

        // Compute segments: group by speaker + large time gaps
        NSMutableArray *segments = [NSMutableArray array];
        NSMutableDictionary *currentSegment = nil;
        NSString *currentSpeaker = nil;

        for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
            SpliceKitTranscriptWord *word = self.mutableWords[i];
            BOOL newSegment = NO;

            if (i == 0) {
                newSegment = YES;
            } else {
                SpliceKitTranscriptWord *prev = self.mutableWords[i - 1];
                double gap = word.startTime - prev.endTime;
                // New segment on sentence-level pauses (>1s) or speaker change.
                // 1 second is a natural sentence/thought boundary that creates
                // readable paragraph-sized chunks matching Premiere's layout.
                if (gap > 1.0 || ![word.speaker isEqualToString:currentSpeaker]) {
                    newSegment = YES;
                }
            }

            if (newSegment) {
                currentSegment = [NSMutableDictionary dictionaryWithDictionary:@{
                    @"speaker": word.speaker ?: @"Unknown",
                    @"startWordIndex": @(i),
                    @"startTime": @(word.startTime),
                }];
                [segments addObject:currentSegment];
                currentSpeaker = word.speaker;
            }

            currentSegment[@"endWordIndex"] = @(i);
            currentSegment[@"endTime"] = @(word.endTime);
        }

        // Build the attributed string segment by segment
        for (NSDictionary *segment in segments) {
            NSUInteger segStart = [segment[@"startWordIndex"] unsignedIntegerValue];
            NSUInteger segEnd = [segment[@"endWordIndex"] unsignedIntegerValue];
            NSString *speaker = segment[@"speaker"];
            double segStartTime = [segment[@"startTime"] doubleValue];
            double segEndTime = [segment[@"endTime"] doubleValue];

            // Add spacing before segment (except first)
            if (segStart > 0) {
                [attrStr appendAttributedString:[[NSAttributedString alloc]
                    initWithString:@"\n\n" attributes:@{
                        NSFontAttributeName: [NSFont systemFontOfSize:8],
                        FCPAttrItemType: @"spacer",
                    }]];
                textPos += 2;
            }

            // ── Segment Header: "Speaker 1        00:00:00:00 - 00:00:15:19" ──
            NSString *startTC = SpliceKitTranscript_timecodeFromSeconds(segStartTime, self.frameRate);
            NSString *endTC = SpliceKitTranscript_timecodeFromSeconds(segEndTime, self.frameRate);

            // Speaker name (clickable to rename)
            NSString *speakerStr = [NSString stringWithFormat:@"%@", speaker];
            [attrStr appendAttributedString:[[NSAttributedString alloc]
                initWithString:speakerStr attributes:@{
                    NSFontAttributeName: headerSpeakerFont,
                    NSForegroundColorAttributeName: headerSpeakerColor,
                    NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
                    NSCursorAttributeName: [NSCursor pointingHandCursor],
                    FCPAttrItemType: @"speakerLabel",
                    FCPAttrSpeakerName: speaker,
                    FCPAttrSegmentStartIndex: @(segStart),
                    FCPAttrSegmentEndIndex: @(segEnd),
                }]];
            textPos += speakerStr.length;

            // Spacer between speaker and timecode
            NSString *spacer = @"        ";
            [attrStr appendAttributedString:[[NSAttributedString alloc]
                initWithString:spacer attributes:@{
                    NSFontAttributeName: headerTimeFont,
                    FCPAttrItemType: @"header",
                }]];
            textPos += spacer.length;

            // Timecode range
            NSString *timeStr = [NSString stringWithFormat:@"%@ - %@", startTC, endTC];
            [attrStr appendAttributedString:[[NSAttributedString alloc]
                initWithString:timeStr attributes:@{
                    NSFontAttributeName: headerTimeFont,
                    NSForegroundColorAttributeName: headerTimeColor,
                    FCPAttrItemType: @"header",
                }]];
            textPos += timeStr.length;

            // Newline after header
            [attrStr appendAttributedString:[[NSAttributedString alloc]
                initWithString:@"\n" attributes:@{
                    NSFontAttributeName: normalFont,
                    FCPAttrItemType: @"header",
                }]];
            textPos += 1;

            // ── Words in this segment ──
            for (NSUInteger i = segStart; i <= segEnd; i++) {
                SpliceKitTranscriptWord *word = self.mutableWords[i];

                // Check for silence before this word
                if (i > 0) {
                    SpliceKitTranscriptSilence *silence = silenceMap[@(i - 1)];
                    if (silence) {
                        // Insert silence marker: " [···] "
                        NSString *silenceStr = @" [\u22EF] ";

                        NSMutableDictionary *silenceAttrs = [NSMutableDictionary dictionaryWithDictionary:@{
                            NSFontAttributeName: silenceFont,
                            NSForegroundColorAttributeName: silenceFgColor,
                            NSBackgroundColorAttributeName: silenceBgColor,
                            FCPAttrItemType: @"silence",
                            FCPAttrSilenceIndex: @([self.mutableSilences indexOfObject:silence]),
                            NSToolTipAttributeName: [NSString stringWithFormat:@"Pause: %.1fs (%@ - %@)",
                                silence.duration,
                                SpliceKitTranscript_timecodeFromSeconds(silence.startTime, self.frameRate),
                                SpliceKitTranscript_timecodeFromSeconds(silence.endTime, self.frameRate)],
                        }];

                        silence.textRange = NSMakeRange(textPos, silenceStr.length);

                        [attrStr appendAttributedString:[[NSAttributedString alloc]
                            initWithString:silenceStr attributes:silenceAttrs]];
                        textPos += silenceStr.length;
                    } else if (i > segStart) {
                        // Regular space between words within the same segment
                        [attrStr appendAttributedString:[[NSAttributedString alloc]
                            initWithString:@" " attributes:normalAttrs]];
                        textPos += 1;
                    }
                } else if (i > segStart) {
                    [attrStr appendAttributedString:[[NSAttributedString alloc]
                        initWithString:@" " attributes:normalAttrs]];
                    textPos += 1;
                }

                // Word
                NSDictionary *attrs = (word.confidence < 0.5) ? lowConfAttrs : normalAttrs;
                word.textRange = NSMakeRange(textPos, word.text.length);

                NSMutableDictionary *wordAttrs = [attrs mutableCopy];
                wordAttrs[NSToolTipAttributeName] = [NSString stringWithFormat:@"%@ - %@ (%.0f%%)",
                    SpliceKitTranscript_timecodeFromSeconds(word.startTime, self.frameRate),
                    SpliceKitTranscript_timecodeFromSeconds(word.endTime, self.frameRate),
                    word.confidence * 100];
                wordAttrs[FCPAttrWordIndex] = @(i);

                [attrStr appendAttributedString:[[NSAttributedString alloc]
                    initWithString:word.text attributes:wordAttrs]];
                textPos += word.text.length;
            }
        }
    }

    [self.textView.textStorage setAttributedString:attrStr];
    self.fullText = [attrStr string];

    self.suppressTextViewCallbacks = NO;

    // Re-apply search highlighting if active
    if (self.currentSearchQuery.length > 0 || ![self.currentFilter isEqualToString:@"all"]) {
        [self performSearchHighlighting];
    }
}

#pragma mark - Click Handling (Jump Playhead)

- (void)handleClickAtCharIndex:(NSUInteger)charIdx {
    if (charIdx >= self.textView.textStorage.length) return;

    // Check what type of item was clicked
    NSDictionary *attrs = [self.textView.textStorage attributesAtIndex:charIdx effectiveRange:nil];
    NSString *itemType = attrs[FCPAttrItemType];

    if ([itemType isEqualToString:@"word"]) {
        SpliceKitTranscriptWord *word = [self wordAtCharIndex:charIdx];
        if (!word) return;

        SpliceKit_log(@"[Transcript] Clicked word %lu: \"%@\" at %.2fs",
                      (unsigned long)word.wordIndex, word.text, word.startTime);

        [self setPlayheadToTime:word.startTime];
        [self highlightWordRange:NSMakeRange(word.wordIndex, 1)
                           color:[NSColor selectedTextBackgroundColor]];

    } else if ([itemType isEqualToString:@"speakerLabel"]) {
        NSString *currentName = attrs[FCPAttrSpeakerName];
        NSUInteger segStart = [attrs[FCPAttrSegmentStartIndex] unsignedIntegerValue];
        NSUInteger segEnd = [attrs[FCPAttrSegmentEndIndex] unsignedIntegerValue];
        if (currentName) {
            [self showSpeakerRenamePopoverForSpeaker:currentName
                                        segmentStart:segStart
                                          segmentEnd:segEnd
                                         atCharIndex:charIdx];
        }

    } else if ([itemType isEqualToString:@"silence"]) {
        NSNumber *silenceIdx = attrs[FCPAttrSilenceIndex];
        if (silenceIdx && silenceIdx.unsignedIntegerValue < self.mutableSilences.count) {
            SpliceKitTranscriptSilence *silence = self.mutableSilences[silenceIdx.unsignedIntegerValue];
            SpliceKit_log(@"[Transcript] Clicked silence at %.2fs (%.1fs duration)",
                          silence.startTime, silence.duration);
            [self setPlayheadToTime:silence.startTime];
        }
    }
}

- (SpliceKitTranscriptWord *)wordAtCharIndex:(NSUInteger)charIdx {
    @synchronized (self.mutableWords) {
        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            if (charIdx >= word.textRange.location &&
                charIdx < NSMaxRange(word.textRange)) {
                return word;
            }
        }
    }
    return nil;
}

#pragma mark - Speaker Rename Popover

- (void)showSpeakerRenamePopoverForSpeaker:(NSString *)currentName
                              segmentStart:(NSUInteger)segStart
                                segmentEnd:(NSUInteger)segEnd
                               atCharIndex:(NSUInteger)charIdx {

    // Build the popover content view
    NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 80)];

    // Text field for new name
    NSTextField *nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 44, 256, 24)];
    nameField.stringValue = currentName;
    nameField.placeholderString = @"Enter speaker name...";
    nameField.font = [NSFont systemFontOfSize:13];
    nameField.bezelStyle = NSTextFieldRoundedBezel;
    [nameField selectText:nil];
    [contentView addSubview:nameField];

    // "Rename all" checkbox
    NSButton *renameAllCheckbox = [NSButton checkboxWithTitle:
        [NSString stringWithFormat:@"Rename all \"%@\" instances", currentName]
                                                      target:nil action:nil];
    renameAllCheckbox.frame = NSMakeRect(12, 12, 200, 20);
    renameAllCheckbox.font = [NSFont systemFontOfSize:11];
    renameAllCheckbox.state = NSControlStateValueOn;
    [contentView addSubview:renameAllCheckbox];

    // Apply button
    NSButton *applyButton = [NSButton buttonWithTitle:@"Rename" target:nil action:nil];
    applyButton.frame = NSMakeRect(214, 8, 56, 28);
    applyButton.bezelStyle = NSBezelStyleRounded;
    applyButton.keyEquivalent = @"\r"; // Enter key
    [contentView addSubview:applyButton];

    // Create popover
    NSPopover *popover = [[NSPopover alloc] init];
    popover.behavior = NSPopoverBehaviorTransient;
    popover.contentSize = NSMakeSize(280, 80);

    NSViewController *vc = [[NSViewController alloc] init];
    vc.view = contentView;
    popover.contentViewController = vc;

    // Wire up the apply action
    __weak typeof(self) weakSelf = self;
    __weak NSPopover *weakPopover = popover;
    applyButton.target = self;
    applyButton.action = @selector(_speakerRenameApply:);

    // Store context for the action via objc_setAssociatedObject
    objc_setAssociatedObject(applyButton, "nameField", nameField, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(applyButton, "renameAll", renameAllCheckbox, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(applyButton, "oldName", currentName, OBJC_ASSOCIATION_COPY);
    objc_setAssociatedObject(applyButton, "segStart", @(segStart), OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(applyButton, "segEnd", @(segEnd), OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(applyButton, "popover", popover, OBJC_ASSOCIATION_RETAIN);

    // Show popover relative to the clicked text
    NSRange glyphRange = [self.textView.layoutManager glyphRangeForCharacterRange:NSMakeRange(charIdx, 1) actualCharacterRange:nil];
    NSRect rect = [self.textView.layoutManager boundingRectForGlyphRange:glyphRange inTextContainer:self.textView.textContainer];
    rect.origin.x += self.textView.textContainerOrigin.x;
    rect.origin.y += self.textView.textContainerOrigin.y;

    [popover showRelativeToRect:rect ofView:self.textView preferredEdge:NSMaxYEdge];

    // Focus the text field
    dispatch_async(dispatch_get_main_queue(), ^{
        [nameField selectText:nil];
        [nameField.window makeFirstResponder:nameField];
    });
}

- (void)_speakerRenameApply:(NSButton *)sender {
    NSTextField *nameField = objc_getAssociatedObject(sender, "nameField");
    NSButton *renameAllCheckbox = objc_getAssociatedObject(sender, "renameAll");
    NSString *oldName = objc_getAssociatedObject(sender, "oldName");
    NSNumber *segStartNum = objc_getAssociatedObject(sender, "segStart");
    NSNumber *segEndNum = objc_getAssociatedObject(sender, "segEnd");
    NSPopover *popover = objc_getAssociatedObject(sender, "popover");

    NSString *newName = nameField.stringValue;
    if (newName.length == 0 || [newName isEqualToString:oldName]) {
        [popover close];
        return;
    }

    BOOL renameAll = (renameAllCheckbox.state == NSControlStateValueOn);

    @synchronized (self.mutableWords) {
        if (renameAll) {
            // Rename all words with this speaker name
            for (SpliceKitTranscriptWord *word in self.mutableWords) {
                if ([word.speaker isEqualToString:oldName]) {
                    word.speaker = newName;
                }
            }
            SpliceKit_log(@"[Transcript] Renamed all \"%@\" -> \"%@\"", oldName, newName);
        } else {
            // Rename only this segment
            NSUInteger start = segStartNum.unsignedIntegerValue;
            NSUInteger end = segEndNum.unsignedIntegerValue;
            for (NSUInteger i = start; i <= end && i < self.mutableWords.count; i++) {
                self.mutableWords[i].speaker = newName;
            }
            SpliceKit_log(@"[Transcript] Renamed segment %lu-%lu \"%@\" -> \"%@\"",
                (unsigned long)start, (unsigned long)end, oldName, newName);
        }
    }

    [popover close];
    [self rebuildTextView];
}

#pragma mark - Delete Words (Text-Based Editing)

- (void)handleDeleteKeyInTextView {
    NSRange selectedRange = self.textView.selectedRange;
    if (selectedRange.length == 0) {
        NSBeep();
        return;
    }

    // Find all words that overlap with the selection
    NSMutableIndexSet *wordIndices = [NSMutableIndexSet indexSet];
    @synchronized (self.mutableWords) {
        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            NSRange intersection = NSIntersectionRange(selectedRange, word.textRange);
            if (intersection.length > 0) {
                [wordIndices addIndex:word.wordIndex];
            }
        }
    }

    // Also check if any silences are fully selected (for deleting pauses)
    NSMutableArray<SpliceKitTranscriptSilence *> *selectedSilences = [NSMutableArray array];
    for (SpliceKitTranscriptSilence *silence in self.mutableSilences) {
        NSRange intersection = NSIntersectionRange(selectedRange, silence.textRange);
        if (intersection.length > 0) {
            [selectedSilences addObject:silence];
        }
    }

    if (wordIndices.count == 0 && selectedSilences.count == 0) {
        NSBeep();
        return;
    }

    // If only silences selected (no words), delete those silence segments
    if (wordIndices.count == 0 && selectedSilences.count > 0) {
        [self updateStatusUI:@"Deleting pauses..."];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            // Delete from end to start to avoid position shifts
            NSArray *sorted = [selectedSilences sortedArrayUsingComparator:^NSComparisonResult(SpliceKitTranscriptSilence *a, SpliceKitTranscriptSilence *b) {
                return (a.startTime > b.startTime) ? NSOrderedAscending : NSOrderedDescending;
            }];
            double totalRemoved = 0;
            for (SpliceKitTranscriptSilence *silence in sorted) {
                // Adjust for already-removed time
                double adjStart = silence.startTime - totalRemoved;
                double adjEnd = silence.endTime - totalRemoved;
                [self deleteTimelineRange:adjStart end:adjEnd];
                double removed = silence.duration;
                totalRemoved += removed;

                // Shift all words after this silence earlier
                @synchronized (self.mutableWords) {
                    for (SpliceKitTranscriptWord *word in self.mutableWords) {
                        if (word.startTime > silence.startTime - (totalRemoved - removed)) {
                            word.startTime -= removed;
                        }
                    }
                }
            }

            [self detectSilences];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self rebuildTextView];
                self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);
                [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses",
                    (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSilences.count]];
            });
        });
        return;
    }

    NSUInteger startIdx = wordIndices.firstIndex;
    NSUInteger count = wordIndices.lastIndex - wordIndices.firstIndex + 1;

    SpliceKit_log(@"[Transcript] Deleting %lu words starting at index %lu",
                  (unsigned long)count, (unsigned long)startIdx);

    NSDictionary *result = [self deleteWordsFromIndex:startIdx count:count];
    SpliceKit_log(@"[Transcript] Delete result: %@", result);
}

#pragma mark - Drag & Drop Word Reordering

- (NSRange)selectedWordRange {
    NSRange sel = self.textView.selectedRange;
    if (sel.length == 0) return NSMakeRange(0, 0);

    NSMutableIndexSet *wordIndices = [NSMutableIndexSet indexSet];
    @synchronized (self.mutableWords) {
        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            NSRange intersection = NSIntersectionRange(sel, word.textRange);
            if (intersection.length > 0) {
                [wordIndices addIndex:word.wordIndex];
            }
        }
    }

    if (wordIndices.count == 0) return NSMakeRange(0, 0);

    NSUInteger first = wordIndices.firstIndex;
    NSUInteger last = wordIndices.lastIndex;
    return NSMakeRange(first, last - first + 1);
}

- (NSUInteger)wordIndexAtCharIndex:(NSUInteger)charIdx {
    @synchronized (self.mutableWords) {
        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            if (charIdx <= word.textRange.location) {
                return word.wordIndex;
            }
            if (charIdx < NSMaxRange(word.textRange)) {
                NSUInteger midpoint = word.textRange.location + word.textRange.length / 2;
                if (charIdx <= midpoint) {
                    return word.wordIndex;
                } else {
                    return word.wordIndex + 1;
                }
            }
        }
    }
    return self.mutableWords.count;
}

- (void)handleDropOfWordStart:(NSUInteger)srcStart count:(NSUInteger)srcCount atCharIndex:(NSUInteger)charIdx {
    NSUInteger destWordIdx = [self wordIndexAtCharIndex:charIdx];

    if (destWordIdx >= srcStart && destWordIdx <= srcStart + srcCount) {
        SpliceKit_log(@"[Transcript] Drop at same position — no-op");
        return;
    }

    SpliceKit_log(@"[Transcript] Drag-drop: words %lu-%lu -> before word %lu",
                  (unsigned long)srcStart, (unsigned long)(srcStart + srcCount - 1),
                  (unsigned long)destWordIdx);

    [self updateStatusUI:@"Moving clips on timeline..."];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = [self moveWordsFromIndex:srcStart count:srcCount toIndex:destWordIdx];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result[@"error"]) {
                [self updateStatusUI:[NSString stringWithFormat:@"Move failed: %@", result[@"error"]]];
                SpliceKit_log(@"[Transcript] Move error: %@", result[@"error"]);
            } else {
                [self updateStatusUI:[NSString stringWithFormat:@"Moved %lu word(s)", (unsigned long)srcCount]];
                SpliceKit_log(@"[Transcript] Move succeeded: %@", result);
            }
        });
    });
}

#pragma mark - Timeline Editing Operations

- (NSDictionary *)deleteTimelineRange:(double)deleteStart end:(double)deleteEnd {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = [self getActiveTimelineModule];
            if (!timeline) {
                result = @{@"error": @"No active timeline"};
                return;
            }

            // Blade at start
            [self setPlayheadToTime:deleteStart];
            [NSThread sleepForTimeInterval:0.05];

            SEL bladeSel = NSSelectorFromString(@"blade:");
            if ([timeline respondsToSelector:bladeSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, bladeSel, nil);
            }
            [NSThread sleepForTimeInterval:0.05];

            // Blade at end
            [self setPlayheadToTime:deleteEnd];
            [NSThread sleepForTimeInterval:0.05];

            if ([timeline respondsToSelector:bladeSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, bladeSel, nil);
            }
            [NSThread sleepForTimeInterval:0.05];

            // Select clip at midpoint
            double midPoint = (deleteStart + deleteEnd) / 2.0;
            [self setPlayheadToTime:midPoint];
            [NSThread sleepForTimeInterval:0.05];

            SEL selectSel = NSSelectorFromString(@"selectClipAtPlayhead:");
            if ([timeline respondsToSelector:selectSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, selectSel, nil);
            }
            [NSThread sleepForTimeInterval:0.05];

            // Delete (ripple delete)
            SEL deleteSel = NSSelectorFromString(@"delete:");
            if ([timeline respondsToSelector:deleteSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, deleteSel, nil);
            }

            result = @{@"status": @"ok",
                       @"timeRange": @{@"start": @(deleteStart), @"end": @(deleteEnd)},
                       @"duration": @(deleteEnd - deleteStart)};

        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

- (NSDictionary *)deleteWordsFromIndex:(NSUInteger)startIndex count:(NSUInteger)count {
    @synchronized (self.mutableWords) {
        if (startIndex >= self.mutableWords.count) {
            return @{@"error": @"startIndex out of range"};
        }
        if (startIndex + count > self.mutableWords.count) {
            count = self.mutableWords.count - startIndex;
        }
    }

    SpliceKitTranscriptWord *firstWord = self.mutableWords[startIndex];
    SpliceKitTranscriptWord *lastWord = self.mutableWords[startIndex + count - 1];
    double deleteStart = firstWord.startTime;
    double deleteEnd = lastWord.endTime;
    double deletedDuration = deleteEnd - deleteStart;

    SpliceKit_log(@"[Transcript] Deleting words %lu-%lu: %.2fs - %.2fs (%.2fs)",
                  (unsigned long)startIndex, (unsigned long)(startIndex + count - 1),
                  deleteStart, deleteEnd, deletedDuration);

    NSDictionary *result = [self deleteTimelineRange:deleteStart end:deleteEnd];

    if (result[@"error"]) return result;

    // Remove deleted words from the data model
    @synchronized (self.mutableWords) {
        [self.mutableWords removeObjectsInRange:NSMakeRange(startIndex, count)];
        for (NSUInteger i = startIndex; i < self.mutableWords.count; i++) {
            self.mutableWords[i].wordIndex = i;
        }
    }

    // Resync timestamps from the actual FCP timeline state
    [self resyncTimestampsFromTimeline];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self rebuildTextView];
        self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);
        [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses",
            (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSilences.count]];
    });

    NSMutableDictionary *fullResult = [result mutableCopy];
    fullResult[@"deletedWords"] = @(count);
    return fullResult;
}

#pragma mark - Delete Silences (Batch)

- (NSDictionary *)deleteAllSilences {
    return [self deleteSilencesLongerThan:0];
}

- (NSDictionary *)deleteSilencesLongerThan:(double)minDuration {
    // Collect silences to delete (filter by minimum duration)
    NSMutableArray<SpliceKitTranscriptSilence *> *toDelete = [NSMutableArray array];
    for (SpliceKitTranscriptSilence *silence in self.mutableSilences) {
        if (silence.duration >= minDuration) {
            [toDelete addObject:silence];
        }
    }

    if (toDelete.count == 0) {
        return @{@"status": @"ok", @"deletedCount": @0, @"message": @"No silences to delete"};
    }

    SpliceKit_log(@"[Transcript] Batch deleting %lu silences (min duration: %.2fs)",
                  (unsigned long)toDelete.count, minDuration);

    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatusUI:[NSString stringWithFormat:@"Deleting %lu pauses...", (unsigned long)toDelete.count]];
        self.spinner.hidden = NO;
        [self.spinner startAnimation:nil];
        self.deleteSilencesButton.enabled = NO;
    });

    // Sort by startTime descending (delete from end first to avoid position shifts)
    [toDelete sortUsingComparator:^NSComparisonResult(SpliceKitTranscriptSilence *a, SpliceKitTranscriptSilence *b) {
        return (a.startTime > b.startTime) ? NSOrderedAscending : NSOrderedDescending;
    }];

    __block NSUInteger deletedCount = 0;
    __block NSString *lastError = nil;
    double totalTimeRemoved = 0;

    for (SpliceKitTranscriptSilence *silence in toDelete) {
        // Adjust times for already-removed content
        double adjStart = silence.startTime - totalTimeRemoved;
        double adjEnd = silence.endTime - totalTimeRemoved;

        NSDictionary *result = [self deleteTimelineRange:adjStart end:adjEnd];
        if (result[@"error"]) {
            lastError = result[@"error"];
            SpliceKit_log(@"[Transcript] Error deleting silence at %.2fs: %@", adjStart, lastError);
        } else {
            deletedCount++;
            totalTimeRemoved += silence.duration;
        }
        [NSThread sleepForTimeInterval:0.1];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStatusUI:[NSString stringWithFormat:@"Deleting pauses... %lu/%lu",
                (unsigned long)deletedCount, (unsigned long)toDelete.count]];
        });
    }

    // Update data model locally: shift all word times by cumulative removed durations
    @synchronized (self.mutableWords) {
        // Rebuild all word times from scratch based on which silences were removed
        // Go through silences in forward order (original times) and compute shift
        double cumulativeShift = 0;
        NSUInteger silIdx = 0;

        // toDelete is sorted descending, reverse it for forward processing
        NSArray *forwardSilences = [[toDelete reverseObjectEnumerator] allObjects];

        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            // Advance past silences that ended before this word
            while (silIdx < forwardSilences.count) {
                SpliceKitTranscriptSilence *s = forwardSilences[silIdx];
                if (s.endTime <= word.startTime) {
                    cumulativeShift += s.duration;
                    silIdx++;
                } else {
                    break;
                }
            }
            word.startTime -= cumulativeShift;
        }

        // Re-index
        for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
            self.mutableWords[i].wordIndex = i;
        }
    }

    [self detectSilences];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self rebuildTextView];
        self.spinner.hidden = YES;
        [self.spinner stopAnimation:nil];
        self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);
        [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses — removed %lu silences",
            (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSilences.count,
            (unsigned long)deletedCount]];
    });

    NSMutableDictionary *response = [NSMutableDictionary dictionary];
    response[@"status"] = lastError ? @"partial" : @"ok";
    response[@"deletedCount"] = @(deletedCount);
    response[@"totalSilences"] = @(toDelete.count);
    response[@"timeRemoved"] = @(totalTimeRemoved);
    if (lastError) response[@"lastError"] = lastError;

    return response;
}

#pragma mark - Move Words (Drag to Reorder)

- (NSDictionary *)moveWordsFromIndex:(NSUInteger)startIndex count:(NSUInteger)count toIndex:(NSUInteger)destIndex {
    @synchronized (self.mutableWords) {
        if (startIndex >= self.mutableWords.count || destIndex > self.mutableWords.count) {
            return @{@"error": @"Index out of range"};
        }
        if (startIndex + count > self.mutableWords.count) {
            count = self.mutableWords.count - startIndex;
        }
        if (destIndex > startIndex && destIndex < startIndex + count) {
            return @{@"error": @"Cannot move to within source range"};
        }
    }

    SpliceKitTranscriptWord *firstWord = self.mutableWords[startIndex];
    SpliceKitTranscriptWord *lastWord = self.mutableWords[startIndex + count - 1];
    double sourceStart = firstWord.startTime;
    double sourceEnd = lastWord.endTime;
    double sourceDuration = sourceEnd - sourceStart;

    double destTime;
    if (destIndex == 0) {
        destTime = 0;
    } else if (destIndex >= self.mutableWords.count) {
        SpliceKitTranscriptWord *lastW = self.mutableWords.lastObject;
        destTime = lastW.endTime;
    } else {
        destTime = self.mutableWords[destIndex].startTime;
    }

    SpliceKit_log(@"[Transcript] Moving words %lu-%lu (%.2fs-%.2fs) to index %lu (time %.2fs)",
                  (unsigned long)startIndex, (unsigned long)(startIndex + count - 1),
                  sourceStart, sourceEnd, (unsigned long)destIndex, destTime);

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = [self getActiveTimelineModule];
            if (!timeline) {
                result = @{@"error": @"No active timeline"};
                return;
            }

            // Step 1: Blade at source start
            [self setPlayheadToTime:sourceStart];
            [NSThread sleepForTimeInterval:0.05];
            SEL bladeSel = NSSelectorFromString(@"blade:");
            ((void (*)(id, SEL, id))objc_msgSend)(timeline, bladeSel, nil);
            [NSThread sleepForTimeInterval:0.05];

            // Step 2: Blade at source end
            [self setPlayheadToTime:sourceEnd];
            [NSThread sleepForTimeInterval:0.05];
            ((void (*)(id, SEL, id))objc_msgSend)(timeline, bladeSel, nil);
            [NSThread sleepForTimeInterval:0.05];

            // Step 3: Select the source segment
            double midPoint = (sourceStart + sourceEnd) / 2.0;
            [self setPlayheadToTime:midPoint];
            [NSThread sleepForTimeInterval:0.05];

            SEL selectSel = NSSelectorFromString(@"selectClipAtPlayhead:");
            ((void (*)(id, SEL, id))objc_msgSend)(timeline, selectSel, nil);
            [NSThread sleepForTimeInterval:0.05];

            // Step 4: Cut
            SEL cutSel = NSSelectorFromString(@"cut:");
            ((void (*)(id, SEL, id))objc_msgSend)(timeline, cutSel, nil);
            [NSThread sleepForTimeInterval:0.1];

            // Step 5: Move playhead to destination (adjust for position shift)
            double adjustedDestTime = destTime;
            if (destTime > sourceStart) {
                adjustedDestTime -= sourceDuration;
            }
            [self setPlayheadToTime:adjustedDestTime];
            [NSThread sleepForTimeInterval:0.05];

            // Step 6: Paste
            SEL pasteSel = NSSelectorFromString(@"paste:");
            ((void (*)(id, SEL, id))objc_msgSend)(timeline, pasteSel, nil);

            result = @{@"status": @"ok",
                       @"movedWords": @(count),
                       @"from": @{@"start": @(sourceStart), @"end": @(sourceEnd)},
                       @"to": @(destTime)};

        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    if (result[@"error"]) return result;

    // Update data model locally: reorder words in the array
    @synchronized (self.mutableWords) {
        NSArray *movedWords = [self.mutableWords subarrayWithRange:NSMakeRange(startIndex, count)];
        [self.mutableWords removeObjectsInRange:NSMakeRange(startIndex, count)];

        NSUInteger adjustedDest = destIndex;
        if (destIndex > startIndex) {
            adjustedDest -= count;
        }
        adjustedDest = MIN(adjustedDest, self.mutableWords.count);

        NSIndexSet *insertIndices = [NSIndexSet indexSetWithIndexesInRange:
            NSMakeRange(adjustedDest, count)];
        [self.mutableWords insertObjects:movedWords atIndexes:insertIndices];

        // Re-index
        for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
            self.mutableWords[i].wordIndex = i;
        }
    }

    // Resync timestamps from the actual FCP timeline state
    [self resyncTimestampsFromTimeline];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self rebuildTextView];
        self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);
        [self updateStatusUI:[NSString stringWithFormat:@"Moved %lu words — %lu words, %lu pauses",
            (unsigned long)count, (unsigned long)self.mutableWords.count,
            (unsigned long)self.mutableSilences.count]];
    });

    return result;
}

- (void)scheduleRetranscribe {
    SpliceKit_log(@"[Transcript] Scheduling re-transcribe after edit...");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatusUI:@"Refreshing transcript..."];
        self.spinner.hidden = NO;
        [self.spinner startAnimation:nil];
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self performTimelineTranscription];
    });
}

#pragma mark - Resync Timestamps from Timeline

- (void)resyncTimestampsFromTimeline {
    // After edits (move, delete), re-read actual clip positions from FCP's timeline.
    // Each word has an immutable sourceMediaTime (its position in the source file).
    // We match each word to the clip that contains its source time, then compute:
    //   word.startTime = clip.timelineStart + (word.sourceMediaTime - clip.trimStart)
    SpliceKit_log(@"[Transcript] Resyncing timestamps from timeline...");

    // Give FCP a moment to settle after the edit
    [NSThread sleepForTimeInterval:0.3];

    __block NSArray *clipInfos = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = [self getActiveTimelineModule];
            if (!timeline) return;

            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) return;

            id primaryObj = nil;
            if ([sequence respondsToSelector:@selector(primaryObject)]) {
                primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
            }
            if (!primaryObj) return;

            id items = nil;
            if ([primaryObj respondsToSelector:@selector(containedItems)]) {
                items = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
            }
            if (!items || ![items isKindOfClass:[NSArray class]]) return;

            NSMutableArray *infos = [NSMutableArray array];
            double timelinePos = 0;
            [self collectClipsFrom:(NSArray *)items atTimeline:&timelinePos into:infos];
            clipInfos = [infos copy];
        } @catch (NSException *e) {
            SpliceKit_log(@"[Transcript] Resync error: %@", e.reason);
        }
    });

    if (!clipInfos || clipInfos.count == 0) {
        SpliceKit_log(@"[Transcript] Resync: no clips found");
        return;
    }

    // Build actual clip segments with media paths for matching
    NSMutableArray *actualClips = [NSMutableArray array];
    for (NSDictionary *info in clipInfos) {
        NSURL *mediaURL = info[@"mediaURL"];
        if (mediaURL) {
            [actualClips addObject:@{
                @"timelineStart": info[@"timelineStart"] ?: @0,
                @"trimStart": info[@"trimStart"] ?: @0,
                @"duration": info[@"duration"] ?: @0,
                @"path": mediaURL.path ?: @"",
            }];
        }
    }

    SpliceKit_log(@"[Transcript] Resync: found %lu clips on timeline", (unsigned long)actualClips.count);

    @synchronized (self.mutableWords) {
        if (self.mutableWords.count == 0) return;

        NSUInteger matched = 0, unmatched = 0;

        for (SpliceKitTranscriptWord *word in self.mutableWords) {
            double smt = word.sourceMediaTime;
            NSString *path = word.sourceMediaPath;
            BOOL found = NO;

            // Find the clip on the timeline that contains this word's source media time.
            // After blade operations, the original clip may be split into multiple
            // clips with different trimStart/duration ranges.
            for (NSDictionary *clip in actualClips) {
                double clipTrimStart = [clip[@"trimStart"] doubleValue];
                double clipDuration = [clip[@"duration"] doubleValue];
                double clipTimelineStart = [clip[@"timelineStart"] doubleValue];
                NSString *clipPath = clip[@"path"];

                // Match by source media path and source time within clip's trim range
                BOOL pathMatch = (!path || !clipPath || path.length == 0 ||
                                  [path isEqualToString:clipPath]);
                BOOL timeMatch = (smt >= clipTrimStart - 0.01 &&
                                  smt < clipTrimStart + clipDuration + 0.01);

                if (pathMatch && timeMatch) {
                    double newStartTime = clipTimelineStart + (smt - clipTrimStart);
                    word.startTime = newStartTime;
                    word.clipTimelineStart = clipTimelineStart;
                    word.sourceMediaOffset = clipTrimStart;
                    found = YES;
                    matched++;
                    break;
                }
            }

            if (!found) {
                unmatched++;
            }
        }

        SpliceKit_log(@"[Transcript] Resync: matched %lu words, %lu unmatched",
                      (unsigned long)matched, (unsigned long)unmatched);
    }

    [self detectSilences];
    SpliceKit_log(@"[Transcript] Resync complete");
}

#pragma mark - Playhead Sync

- (void)startPlayheadTimer {
    [self stopPlayheadTimer];
    self.playheadTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                         target:self
                                                       selector:@selector(playheadTimerFired:)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)stopPlayheadTimer {
    [self.playheadTimer invalidate];
    self.playheadTimer = nil;
}

- (void)playheadTimerFired:(NSTimer *)timer {
    if (self.status != SpliceKitTranscriptStatusReady) return;
    if (self.mutableWords.count == 0) return;
    if (!self.panel.isVisible) return;

    __block double playheadTime = -1;
    @try {
        id timeline = [self getActiveTimelineModule];
        if (!timeline) return;

        SEL currentTimeSel = NSSelectorFromString(@"currentSequenceTime");
        if ([timeline respondsToSelector:currentTimeSel]) {
            SpliceKitTranscript_CMTime t = ((SpliceKitTranscript_CMTime (*)(id, SEL))objc_msgSend)(
                timeline, currentTimeSel);
            double secs = CMTimeToSeconds(t);
            if (secs >= 0) playheadTime = secs;
        }

        if (playheadTime < 0 && [timeline respondsToSelector:@selector(playheadTime)]) {
            SpliceKitTranscript_CMTime t = ((SpliceKitTranscript_CMTime (*)(id, SEL))objc_msgSend)(
                timeline, @selector(playheadTime));
            playheadTime = CMTimeToSeconds(t);
        }

        if (playheadTime < 0) {
            id container = [self getEditorContainer];
            SEL pstSel = NSSelectorFromString(@"playheadSequenceTime");
            if (container && [container respondsToSelector:pstSel]) {
                SpliceKitTranscript_CMTime t = ((SpliceKitTranscript_CMTime (*)(id, SEL))objc_msgSend)(
                    container, pstSel);
                playheadTime = CMTimeToSeconds(t);
            }
        }
    } @catch (NSException *e) {}

    if (playheadTime >= 0) {
        [self updatePlayheadHighlight:playheadTime];
    }
}

- (void)updatePlayheadHighlight:(double)timeInSeconds {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.suppressTextViewCallbacks) return;
        if (self.searchResultRanges.count > 0) return;

        NSTextStorage *storage = self.textView.textStorage;
        NSUInteger storageLen = storage.length;
        if (storageLen == 0) return;

        // Find which word the playhead is on
        NSRange newRange = NSMakeRange(NSNotFound, 0);
        @synchronized (self.mutableWords) {
            for (SpliceKitTranscriptWord *word in self.mutableWords) {
                if (timeInSeconds >= word.startTime && timeInSeconds < word.endTime) {
                    if (word.textRange.location + word.textRange.length <= storageLen) {
                        newRange = word.textRange;
                    }
                    break;
                }
            }
        }

        // Skip update if same word is already highlighted
        if (NSEqualRanges(newRange, self.lastPlayheadHighlightRange)) return;

        self.suppressTextViewCallbacks = YES;

        // Clear only the previous highlight (not the whole document)
        if (self.lastPlayheadHighlightRange.location != NSNotFound &&
            self.lastPlayheadHighlightRange.location + self.lastPlayheadHighlightRange.length <= storageLen) {
            [storage removeAttribute:NSBackgroundColorAttributeName
                               range:self.lastPlayheadHighlightRange];
        }

        // Apply new highlight
        if (newRange.location != NSNotFound) {
            [storage addAttribute:NSBackgroundColorAttributeName
                            value:[NSColor colorWithCalibratedRed:0.2 green:0.5 blue:1.0 alpha:0.3]
                            range:newRange];
        }

        self.lastPlayheadHighlightRange = newRange;
        self.suppressTextViewCallbacks = NO;
    });
}

- (void)highlightWordRange:(NSRange)wordRange color:(NSColor *)color {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.mutableWords.count == 0) return;
        self.suppressTextViewCallbacks = YES;

        NSTextStorage *storage = self.textView.textStorage;
        NSUInteger end = MIN(wordRange.location + wordRange.length, self.mutableWords.count);

        for (NSUInteger i = wordRange.location; i < end; i++) {
            SpliceKitTranscriptWord *word = self.mutableWords[i];
            if (word.textRange.location + word.textRange.length <= storage.length) {
                [storage addAttribute:NSBackgroundColorAttributeName
                                value:color
                                range:word.textRange];
            }
        }

        self.suppressTextViewCallbacks = NO;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            self.suppressTextViewCallbacks = YES;
            [storage removeAttribute:NSBackgroundColorAttributeName
                               range:NSMakeRange(0, storage.length)];
            self.suppressTextViewCallbacks = NO;
        });
    });
}

#pragma mark - FCP Integration Helpers

- (id)getEditorContainer {
    id app = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("NSApplication"), @selector(sharedApplication));
    id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
    if (!delegate) return nil;

    SEL aecSel = @selector(activeEditorContainer);
    if (![delegate respondsToSelector:aecSel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(delegate, aecSel);
}

- (id)getActiveTimelineModule {
    id container = [self getEditorContainer];
    if (!container) return nil;

    SEL tmSel = NSSelectorFromString(@"timelineModule");
    if ([container respondsToSelector:tmSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(container, tmSel);
    }
    return nil;
}

- (void)setPlayheadToTime:(double)seconds {
    id timeline = [self getActiveTimelineModule];
    if (!timeline) return;

    int32_t timescale = 600;
    if ([timeline respondsToSelector:@selector(sequenceFrameDuration)]) {
        SpliceKitTranscript_CMTime fd = ((SpliceKitTranscript_CMTime (*)(id, SEL))objc_msgSend)(
            timeline, @selector(sequenceFrameDuration));
        if (fd.timescale > 0) timescale = fd.timescale;
    }

    SpliceKitTranscript_CMTime cmTime = {
        .value = (int64_t)(seconds * timescale),
        .timescale = timescale,
        .flags = 1,
        .epoch = 0
    };

    SEL setPlayheadSel = NSSelectorFromString(@"setPlayheadTime:");
    if ([timeline respondsToSelector:setPlayheadSel]) {
        ((void (*)(id, SEL, SpliceKitTranscript_CMTime))objc_msgSend)(timeline, setPlayheadSel, cmTime);
    }
}

#pragma mark - State

- (NSArray<SpliceKitTranscriptWord *> *)words {
    @synchronized (self.mutableWords) {
        return [self.mutableWords copy];
    }
}

- (NSArray<SpliceKitTranscriptSilence *> *)silences {
    return [self.mutableSilences copy];
}

- (NSDictionary *)getState {
    NSMutableDictionary *state = [NSMutableDictionary dictionary];

    switch (self.status) {
        case SpliceKitTranscriptStatusIdle:        state[@"status"] = @"idle"; break;
        case SpliceKitTranscriptStatusTranscribing: state[@"status"] = @"transcribing"; break;
        case SpliceKitTranscriptStatusReady:       state[@"status"] = @"ready"; break;
        case SpliceKitTranscriptStatusError:       state[@"status"] = @"error"; break;
    }

    state[@"visible"] = @(self.isVisible);
    state[@"wordCount"] = @(self.mutableWords.count);
    state[@"silenceCount"] = @(self.mutableSilences.count);
    state[@"silenceThreshold"] = @(self.silenceThreshold);
    state[@"frameRate"] = @(self.frameRate);
    state[@"engine"] = (self.engine == SpliceKitTranscriptEngineFCPNative) ? @"fcpNative" :
                       (self.engine == SpliceKitTranscriptEngineParakeet) ? @"parakeet" : @"appleSpeech";
    if (self.engine == SpliceKitTranscriptEngineParakeet) {
        state[@"parakeetModel"] = self.parakeetModelVersion ?: @"v3";
    }
    state[@"speakerDetectionAvailable"] = @(SpliceKitTranscript_isSpeakerDiarizationAvailable());
    state[@"speakerDetectionEnabled"] = @(self.speakerDetectionEnabled);

    if (self.errorMessage) {
        state[@"errorMessage"] = self.errorMessage;
    }

    if (self.fullText) {
        state[@"text"] = self.fullText;
    }

    if (self.status == SpliceKitTranscriptStatusTranscribing) {
        state[@"progress"] = @{
            @"completed": @(self.completedTranscriptions),
            @"total": @(self.totalTranscriptions)
        };
    }

    if (self.mutableWords.count > 0) {
        NSMutableArray *wordList = [NSMutableArray array];
        @synchronized (self.mutableWords) {
            for (SpliceKitTranscriptWord *word in self.mutableWords) {
                [wordList addObject:@{
                    @"index": @(word.wordIndex),
                    @"text": word.text ?: @"",
                    @"startTime": @(word.startTime),
                    @"endTime": @(word.endTime),
                    @"duration": @(word.duration),
                    @"confidence": @(word.confidence),
                    @"speaker": word.speaker ?: @"Unknown"
                }];
            }
        }
        state[@"words"] = wordList;
    }

    if (self.mutableSilences.count > 0) {
        NSMutableArray *silenceList = [NSMutableArray array];
        for (SpliceKitTranscriptSilence *silence in self.mutableSilences) {
            [silenceList addObject:@{
                @"startTime": @(silence.startTime),
                @"endTime": @(silence.endTime),
                @"duration": @(silence.duration),
                @"afterWordIndex": @(silence.afterWordIndex),
                @"startTimecode": SpliceKitTranscript_timecodeFromSeconds(silence.startTime, self.frameRate),
                @"endTimecode": SpliceKitTranscript_timecodeFromSeconds(silence.endTime, self.frameRate),
            }];
        }
        state[@"silences"] = silenceList;
    }

    return state;
}

#pragma mark - UI Helpers

- (void)updateStatusUI:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.stringValue = message;
    });
}

- (void)openSpeechRecognitionSettings {
    dispatch_async(dispatch_get_main_queue(), ^{
        // macOS 13+ uses the new System Settings URL scheme
        NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"];
        [[NSWorkspace sharedWorkspace] openURL:url];
    });
}

- (void)setErrorState:(NSString *)error {
    SpliceKit_log(@"[Transcript] Error: %@", error);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.status = SpliceKitTranscriptStatusError;
        self.errorMessage = error;
        [self updateStatusUI:[NSString stringWithFormat:@"Error: %@", error]];
        self.spinner.hidden = YES;
        [self.spinner stopAnimation:nil];
        self.progressBar.hidden = YES;
        self.refreshButton.enabled = YES;
        self.deleteSilencesButton.enabled = NO;
    });
}

#pragma mark - NSTextView Delegate

- (BOOL)textView:(NSTextView *)textView shouldChangeTextInRange:(NSRange)range
                                               replacementString:(NSString *)string {
    if (self.suppressTextViewCallbacks) return YES;
    if (string.length > 0) return NO;
    return NO; // Deletions handled by keyDown
}

@end
