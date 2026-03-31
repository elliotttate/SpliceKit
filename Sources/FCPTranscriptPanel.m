//
//  FCPTranscriptPanel.m
//  Text-based video editing via speech transcription
//
//  Creates a floating panel inside FCP that shows a transcript of timeline clips.
//  Deleting words removes the corresponding video segments.
//  Dragging words reorders clips on the timeline.
//

#import "FCPTranscriptPanel.h"
#import "FCPBridge.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Speech framework loaded dynamically since FCP doesn't include it
static Class SFSpeechRecognizerClass = nil;
static Class SFSpeechURLRecognitionRequestClass = nil;

static void FCPTranscript_loadSpeechFramework(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *speechBundle = [NSBundle bundleWithPath:
            @"/System/Library/Frameworks/Speech.framework"];
        if ([speechBundle load]) {
            SFSpeechRecognizerClass = objc_getClass("SFSpeechRecognizer");
            SFSpeechURLRecognitionRequestClass = objc_getClass("SFSpeechURLRecognitionRequest");
            FCPBridge_log(@"[Transcript] Speech.framework loaded: recognizer=%@, request=%@",
                          SFSpeechRecognizerClass, SFSpeechURLRecognitionRequestClass);
        } else {
            FCPBridge_log(@"[Transcript] ERROR: Failed to load Speech.framework");
        }
    });
}

#pragma mark - FCPTranscriptWord

@implementation FCPTranscriptWord

- (double)endTime {
    return _startTime + _duration;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"Word[%lu]: \"%@\" %.2f-%.2f (conf:%.0f%%)",
            (unsigned long)_wordIndex, _text, _startTime, self.endTime, _confidence * 100];
}

@end

#pragma mark - Forward Declarations

@interface FCPTranscriptPanel (TextViewCallbacks)
- (void)handleClickAtCharIndex:(NSUInteger)charIdx;
- (void)handleDeleteKeyInTextView;
- (void)handleDropOfWordStart:(NSUInteger)srcStart count:(NSUInteger)srcCount atCharIndex:(NSUInteger)charIdx;
- (NSUInteger)wordIndexAtCharIndex:(NSUInteger)charIdx;
- (NSRange)selectedWordRange;
@end

static NSPasteboardType const FCPTranscriptWordDragType = @"com.fcpbridge.transcript.words";

#pragma mark - Custom Text View for Transcript

@interface FCPTranscriptTextView : NSTextView <NSDraggingSource>
@property (nonatomic, weak) FCPTranscriptPanel *transcriptPanel;
@property (nonatomic) BOOL isDragging;
@property (nonatomic) NSPoint dragOrigin;
@end

@implementation FCPTranscriptTextView

- (void)awakeFromNib {
    [super awakeFromNib];
    [self registerForDraggedTypes:@[FCPTranscriptWordDragType]];
}

- (void)setupDragTypes {
    [self registerForDraggedTypes:@[FCPTranscriptWordDragType]];
}

- (void)mouseDown:(NSEvent *)event {
    self.dragOrigin = [self convertPoint:event.locationInWindow fromView:nil];
    self.isDragging = NO;

    // If clicking inside an existing selection, prepare for potential drag
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSUInteger charIdx = [self characterIndexForInsertionAtPoint:point];
    NSRange sel = self.selectedRange;
    if (sel.length > 0 && charIdx >= sel.location && charIdx < NSMaxRange(sel)) {
        // Inside selection — wait for drag threshold before deciding
        // Don't call super yet; we'll handle in mouseDragged
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
        // If we suppressed super mouseDown (inside selection), treat as click
        NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
        NSUInteger charIdx = [self characterIndexForInsertionAtPoint:point];
        NSRange sel = self.selectedRange;
        if (sel.length > 0 && charIdx >= sel.location && charIdx < NSMaxRange(sel)) {
            // Click inside selection without drag — jump playhead
            [self.transcriptPanel handleClickAtCharIndex:charIdx];
        }
    }
    self.isDragging = NO;
    [super mouseUp:event];
}

- (void)startDragFromSelection:(NSEvent *)event {
    NSRange sel = self.selectedRange;
    if (sel.length == 0) return;

    // Find which words are selected
    NSRange wordRange = [self.transcriptPanel selectedWordRange];
    if (wordRange.length == 0) return;

    // Encode word range into pasteboard data
    NSString *data = [NSString stringWithFormat:@"%lu,%lu",
        (unsigned long)wordRange.location, (unsigned long)wordRange.length];
    NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
    [pbItem setString:data forType:FCPTranscriptWordDragType];

    // Get the text being dragged for the visual
    NSString *dragText = [[self.textStorage string] substringWithRange:sel];

    NSDraggingItem *dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:pbItem];

    // Create a simple drag image from the selected text
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
    if ([pb availableTypeFromArray:@[FCPTranscriptWordDragType]]) {
        return NSDragOperationMove;
    }
    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = [sender draggingPasteboard];
    if ([pb availableTypeFromArray:@[FCPTranscriptWordDragType]]) {
        // Show insertion cursor at drop point
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
    NSString *data = [pb stringForType:FCPTranscriptWordDragType];
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
        // Send as action through NSApp so FCP's player module picks it up
        if ([chars isEqualToString:@" "]) {
            [[NSApp mainWindow] makeKeyWindow]; // give focus back briefly
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

    // Cmd+A (select all), Cmd+Z (undo) → pass through
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        [super keyDown:event];
        return;
    }

    // Block all other typing
    NSBeep();
}

@end

#pragma mark - FCPTranscriptPanel Private

typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } FCPTranscript_CMTime;
typedef struct { FCPTranscript_CMTime start; FCPTranscript_CMTime duration; } FCPTranscript_CMTimeRange;

static double CMTimeToSeconds(FCPTranscript_CMTime t) {
    return (t.timescale > 0) ? (double)t.value / t.timescale : 0;
}

@interface FCPTranscriptPanel () <NSTextViewDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) FCPTranscriptTextView *textView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) NSButton *refreshButton;
@property (nonatomic, strong) NSTimer *playheadTimer;

@property (nonatomic, readwrite) FCPTranscriptStatus status;
@property (nonatomic, readwrite, strong) NSMutableArray<FCPTranscriptWord *> *mutableWords;
@property (nonatomic, readwrite, copy) NSString *fullText;
@property (nonatomic, readwrite, copy) NSString *errorMessage;

// Transcription tracking
@property (nonatomic, strong) NSMutableArray *pendingTranscriptions;
@property (nonatomic) NSUInteger completedTranscriptions;
@property (nonatomic) NSUInteger totalTranscriptions;
@property (nonatomic) BOOL suppressTextViewCallbacks;
@end

@implementation FCPTranscriptPanel

#pragma mark - Singleton

+ (instancetype)sharedPanel {
    static FCPTranscriptPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FCPTranscriptPanel alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _status = FCPTranscriptStatusIdle;
        _mutableWords = [NSMutableArray array];
        _pendingTranscriptions = [NSMutableArray array];
        FCPTranscript_loadSpeechFramework();

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

    FCPBridge_log(@"[Transcript] Setting up panel UI");

    // Create floating panel
    NSRect frame = NSMakeRect(100, 200, 500, 600);
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
    self.panel.minSize = NSMakeSize(350, 300);
    self.panel.delegate = self;
    self.panel.releasedWhenClosed = NO;

    // Content view
    NSView *content = self.panel.contentView;
    content.wantsLayer = YES;
    content.layer.backgroundColor = [NSColor windowBackgroundColor].CGColor;

    // Header area with status
    NSView *header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 50)];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:header];

    // Status label
    self.statusLabel = [NSTextField labelWithString:@"Ready - Open a project and click Transcribe"];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [NSFont systemFontOfSize:12];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    [header addSubview:self.statusLabel];

    // Spinner
    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.hidden = YES;
    [header addSubview:self.spinner];

    // Refresh button
    self.refreshButton = [NSButton buttonWithTitle:@"Transcribe Timeline"
                                            target:self
                                            action:@selector(refreshClicked:)];
    self.refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.refreshButton.bezelStyle = NSBezelStyleRounded;
    [header addSubview:self.refreshButton];

    // Scroll view with text view
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.borderType = NSBezelBorder;
    [content addSubview:self.scrollView];

    // Text view
    NSSize contentSize = self.scrollView.contentSize;
    self.textView = [[FCPTranscriptTextView alloc] initWithFrame:
        NSMakeRect(0, 0, contentSize.width, contentSize.height)];
    self.textView.transcriptPanel = self;
    self.textView.minSize = NSMakeSize(0, contentSize.height);
    self.textView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.textView.verticallyResizable = YES;
    self.textView.horizontallyResizable = NO;
    self.textView.autoresizingMask = NSViewWidthSizable;
    self.textView.textContainer.containerSize = NSMakeSize(contentSize.width, FLT_MAX);
    self.textView.textContainer.widthTracksTextView = YES;
    self.textView.font = [NSFont systemFontOfSize:16];
    self.textView.textColor = [NSColor labelColor];
    self.textView.backgroundColor = [NSColor textBackgroundColor];
    self.textView.editable = YES;
    self.textView.selectable = YES;
    self.textView.richText = YES;
    self.textView.allowsUndo = NO; // We handle our own undo
    self.textView.delegate = self;
    self.textView.textContainerInset = NSMakeSize(12, 12);
    self.scrollView.documentView = self.textView;

    // Register for drag-and-drop of words
    [self.textView setupDragTypes];

    // Instructions text
    NSMutableAttributedString *instructions = [[NSMutableAttributedString alloc]
        initWithString:@"Transcript Editor\n\nClick \"Transcribe Timeline\" to transcribe the audio from your timeline clips.\n\nOnce transcribed:\n  \u2022 Click a word to jump the playhead\n  \u2022 Select words and press Delete to remove those segments\n  \u2022 Drag words to reorder clips\n\nThe transcript stays synced with your timeline."
        attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:14],
            NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
        }];
    [self.textView.textStorage setAttributedString:instructions];

    // Auto Layout
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:content.topAnchor constant:8],
        [header.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [header.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [header.heightAnchor constraintEqualToConstant:40],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [self.spinner.leadingAnchor constraintEqualToAnchor:self.statusLabel.trailingAnchor constant:8],
        [self.spinner.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [self.refreshButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [self.refreshButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [self.scrollView.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
    ]];
}

#pragma mark - Panel Visibility

- (void)showPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setupPanelIfNeeded];
        [self.panel makeKeyAndOrderFront:nil];
    });
}

- (void)hidePanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.panel orderOut:nil];
        [self stopPlayheadTimer];
    });
}

- (BOOL)isVisible {
    return self.panel.isVisible;
}

- (void)windowWillClose:(NSNotification *)notification {
    [self stopPlayheadTimer];
}

#pragma mark - Refresh Button

- (void)refreshClicked:(id)sender {
    [self transcribeTimeline];
}

#pragma mark - Speech Recognition Authorization

- (void)requestSpeechAuthorizationWithCompletion:(void(^)(BOOL authorized))completion {
    if (!SFSpeechRecognizerClass) {
        FCPBridge_log(@"[Transcript] Speech framework not loaded");
        completion(NO);
        return;
    }

    // Skip explicit authorization check/request to avoid TCC crash with ad-hoc signed apps.
    // Instead, just try to create the recognizer. If not authorized, the recognition task
    // will fail with an error that we handle gracefully.
    FCPBridge_log(@"[Transcript] Proceeding with speech recognition (authorization handled by task)");
    completion(YES);
}

#pragma mark - Transcribe Timeline

- (void)transcribeTimeline {
    FCPBridge_log(@"[Transcript] Starting timeline transcription");

    dispatch_async(dispatch_get_main_queue(), ^{
        self.status = FCPTranscriptStatusTranscribing;
        self.errorMessage = nil;
        [self updateStatusUI:@"Analyzing timeline..."];
        self.spinner.hidden = NO;
        [self.spinner startAnimation:nil];
        self.refreshButton.enabled = NO;
    });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self requestSpeechAuthorizationWithCompletion:^(BOOL authorized) {
            if (!authorized) {
                [self setErrorState:@"Speech recognition not authorized. Grant access in System Settings > Privacy > Speech Recognition."];
                return;
            }
            [self performTimelineTranscription];
        }];
    });
}

- (void)collectClipsFrom:(NSArray *)items atTimeline:(double *)timelinePos into:(NSMutableArray *)clipInfos {
    for (id item in items) {
        NSString *className = NSStringFromClass([item class]);

        double clipDuration = 0;
        if ([item respondsToSelector:@selector(duration)]) {
            FCPTranscript_CMTime d = ((FCPTranscript_CMTime (*)(id, SEL))objc_msgSend)(item, @selector(duration));
            clipDuration = CMTimeToSeconds(d);
        }

        BOOL isMedia = [className containsString:@"MediaComponent"];
        BOOL isCollection = [className containsString:@"Collection"] || [className containsString:@"AnchoredClip"];
        BOOL isTransition = [className containsString:@"Transition"];

        if (isMedia && clipDuration > 0) {
            [self addMediaClip:item duration:clipDuration atTimeline:*timelinePos into:clipInfos];
            *timelinePos += clipDuration;

        } else if (isCollection && clipDuration > 0) {
            // A collection wraps media — find the inner media and use the COLLECTION's
            // duration and clippedRange for correct trim info.
            FCPBridge_log(@"[Transcript] Collection: %@ (%.2fs) at %.2fs", className, clipDuration, *timelinePos);

            id innerMedia = [self findFirstMediaInContainer:item];
            if (innerMedia) {
                // Get the collection's clippedRange to find the source-media offset
                double collTrimStart = 0;
                SEL crSel = NSSelectorFromString(@"clippedRange");
                if ([item respondsToSelector:crSel]) {
                    NSMethodSignature *sig = [item methodSignatureForSelector:crSel];
                    if (sig && [sig methodReturnLength] == sizeof(FCPTranscript_CMTimeRange)) {
                        FCPTranscript_CMTimeRange range;
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        [inv setTarget:item];
                        [inv setSelector:crSel];
                        [inv invoke];
                        [inv getReturnValue:&range];
                        collTrimStart = CMTimeToSeconds(range.start);
                        FCPBridge_log(@"[Transcript]   collection clippedRange: start=%.2fs dur=%.2fs",
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
    // Recursively find the first FFAnchoredMediaComponent inside a collection
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
    // For standalone media clips, read trimStart from the clip's own unclippedRange
    double trimStart = 0;
    SEL unclippedSel = NSSelectorFromString(@"unclippedRange");
    if ([clip respondsToSelector:unclippedSel]) {
        NSMethodSignature *sig = [clip methodSignatureForSelector:unclippedSel];
        if (sig && [sig methodReturnLength] == sizeof(FCPTranscript_CMTimeRange)) {
            FCPTranscript_CMTimeRange range;
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
    info[@"handle"] = FCPBridge_storeHandle(clip);
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

    FCPBridge_log(@"[Transcript] Clip at %.2fs (dur=%.2fs, trim=%.2fs): %@ -> %@",
                  timelinePos, clipDuration, trimStart, info[@"name"],
                  mediaURL ? [mediaURL path] : @"(no URL)");

    [clipInfos addObject:info];
}

- (void)performTimelineTranscription {
    // Get timeline clips from FCP
    __block NSArray *clips = nil;
    __block double totalDuration = 0;

    FCPBridge_executeOnMainThread(^{
        @try {
            id timeline = [self getActiveTimelineModule];
            if (!timeline) {
                [self setErrorState:@"No active timeline. Open a project first."];
                return;
            }

            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) {
                [self setErrorState:@"No sequence in timeline."];
                return;
            }

            // Get primaryObject (spine) -> containedItems
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

            // Collect media clips, recursing into collections/compound clips
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
        if (self.status != FCPTranscriptStatusError) {
            [self setErrorState:@"No media clips found on timeline."];
        }
        return;
    }

    FCPBridge_log(@"[Transcript] Found %lu clips, total duration: %.2fs", (unsigned long)clips.count, totalDuration);

    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatusUI:[NSString stringWithFormat:@"Transcribing %lu clip(s)...", (unsigned long)clips.count]];
    });

    // Transcribe each clip
    [self.mutableWords removeAllObjects];
    self.completedTranscriptions = 0;
    self.totalTranscriptions = 0;

    // Count clips that have media URLs
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

    // Transcribe clips one at a time (serialized) to avoid Speech framework conflicts
    // when multiple clips reference the same source file
    [self transcribeClipsSequentially:transcribableClips index:0 completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            // Sort words by timeline start time
            @synchronized (self.mutableWords) {
                [self.mutableWords sortUsingComparator:^NSComparisonResult(FCPTranscriptWord *a, FCPTranscriptWord *b) {
                    if (a.startTime < b.startTime) return NSOrderedAscending;
                    if (a.startTime > b.startTime) return NSOrderedDescending;
                    return NSOrderedSame;
                }];

                // Reassign indices
                for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
                    self.mutableWords[i].wordIndex = i;
                }
            }

            self.status = FCPTranscriptStatusReady;
            [self rebuildTextView];
            [self startPlayheadTimer];

            self.spinner.hidden = YES;
            [self.spinner stopAnimation:nil];
            self.refreshButton.enabled = YES;
            [self updateStatusUI:[NSString stringWithFormat:@"%lu words transcribed",
                (unsigned long)self.mutableWords.count]];

            FCPBridge_log(@"[Transcript] Complete: %lu total words", (unsigned long)self.mutableWords.count);
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
                   completion:^(NSArray<FCPTranscriptWord *> *words, NSError *error) {
        if (error) {
            FCPBridge_log(@"[Transcript] Transcription error for %@: %@", mediaURL.lastPathComponent, error);
        } else {
            @synchronized (self.mutableWords) {
                [self.mutableWords addObjectsFromArray:words];
            }
            FCPBridge_log(@"[Transcript] Transcribed %lu words from %@",
                          (unsigned long)words.count, mediaURL.lastPathComponent);
        }
        self.completedTranscriptions++;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStatusUI:[NSString stringWithFormat:@"Transcribing... (%lu/%lu clips)",
                (unsigned long)self.completedTranscriptions, (unsigned long)self.totalTranscriptions]];
        });

        // Continue to next clip
        [self transcribeClipsSequentially:clips index:idx + 1 completion:completion];
    }];
}

#pragma mark - Media URL Discovery

- (NSURL *)getMediaURLForClip:(id)clip {
    // Try multiple property chains to find the source media file URL
    // Chain 1: clip.media.originalMediaURL (FFAsset direct method)
    @try {
        if ([clip respondsToSelector:NSSelectorFromString(@"media")]) {
            id media = ((id (*)(id, SEL))objc_msgSend)(clip, NSSelectorFromString(@"media"));
            if (media) {
                // Try originalMediaURL
                SEL omSel = NSSelectorFromString(@"originalMediaURL");
                if ([media respondsToSelector:omSel]) {
                    id url = ((id (*)(id, SEL))objc_msgSend)(media, omSel);
                    if (url && [url isKindOfClass:[NSURL class]]) return url;
                }

                // Try originalMediaRep -> fileURLs
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
                        // Try URL property
                        SEL urlSel = NSSelectorFromString(@"URL");
                        if ([rep respondsToSelector:urlSel]) {
                            id url = ((id (*)(id, SEL))objc_msgSend)(rep, urlSel);
                            if ([url isKindOfClass:[NSURL class]]) return url;
                        }
                    }
                }

                // Try currentRep -> fileURLs
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
        FCPBridge_log(@"[Transcript] Exception getting media URL (chain 1): %@", e.reason);
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
        FCPBridge_log(@"[Transcript] Exception getting media URL (chain 2): %@", e.reason);
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

    // Chain 5: navigate media -> iterate properties looking for NSURL
    @try {
        if ([clip respondsToSelector:NSSelectorFromString(@"media")]) {
            id media = ((id (*)(id, SEL))objc_msgSend)(clip, NSSelectorFromString(@"media"));
            if (media) {
                // Get all properties and check for URL types
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
                 completion:(void(^)(NSArray<FCPTranscriptWord *> *, NSError *))completion {

    if (!SFSpeechRecognizerClass || !SFSpeechURLRecognitionRequestClass) {
        completion(nil, [NSError errorWithDomain:@"FCPTranscript" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Speech framework not available"}]);
        return;
    }

    // Verify file exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:audioURL.path]) {
        FCPBridge_log(@"[Transcript] File not found: %@", audioURL.path);
        completion(nil, [NSError errorWithDomain:@"FCPTranscript" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"Media file not found"}]);
        return;
    }

    FCPBridge_log(@"[Transcript] Transcribing: %@ (timeline:%.2f, trim:%.2f, dur:%.2f)",
                  audioURL.lastPathComponent, timelineStart, trimStart, trimDuration);

    // Create recognizer
    id recognizer = ((id (*)(id, SEL, id))objc_msgSend)(
        [SFSpeechRecognizerClass alloc],
        NSSelectorFromString(@"initWithLocale:"),
        [NSLocale localeWithLocaleIdentifier:@"en-US"]);

    if (!recognizer) {
        completion(nil, [NSError errorWithDomain:@"FCPTranscript" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"Could not create speech recognizer"}]);
        return;
    }

    // Check availability
    BOOL isAvailable = ((BOOL (*)(id, SEL))objc_msgSend)(recognizer, NSSelectorFromString(@"isAvailable"));
    if (!isAvailable) {
        completion(nil, [NSError errorWithDomain:@"FCPTranscript" code:4
            userInfo:@{NSLocalizedDescriptionKey: @"Speech recognizer not available"}]);
        return;
    }

    // Create request
    id request = ((id (*)(id, SEL, id))objc_msgSend)(
        [SFSpeechURLRecognitionRequestClass alloc],
        NSSelectorFromString(@"initWithURL:"),
        audioURL);

    if (!request) {
        completion(nil, [NSError errorWithDomain:@"FCPTranscript" code:5
            userInfo:@{NSLocalizedDescriptionKey: @"Could not create recognition request"}]);
        return;
    }

    // Configure request
    ((void (*)(id, SEL, BOOL))objc_msgSend)(request,
        NSSelectorFromString(@"setShouldReportPartialResults:"), NO);

    // Request on-device recognition if available
    SEL onDeviceSel = NSSelectorFromString(@"setRequiresOnDeviceRecognition:");
    if ([request respondsToSelector:onDeviceSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(request, onDeviceSel, NO); // Allow server for better quality
    }

    // Start recognition
    SEL taskSel = NSSelectorFromString(@"recognitionTaskWithRequest:resultHandler:");
    ((id (*)(id, SEL, id, id))objc_msgSend)(recognizer, taskSel, request,
        ^(id result, NSError *error) {
            if (error && !result) {
                completion(nil, error);
                return;
            }

            // Check if final
            BOOL isFinal = ((BOOL (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"isFinal"));
            if (!isFinal) return;

            // Get best transcription
            id transcription = ((id (*)(id, SEL))objc_msgSend)(result,
                NSSelectorFromString(@"bestTranscription"));
            if (!transcription) {
                completion(@[], nil);
                return;
            }

            // Get segments (word-level)
            id segments = ((id (*)(id, SEL))objc_msgSend)(transcription,
                NSSelectorFromString(@"segments"));
            if (!segments || ![segments isKindOfClass:[NSArray class]]) {
                completion(@[], nil);
                return;
            }

            NSMutableArray<FCPTranscriptWord *> *words = [NSMutableArray array];
            for (id segment in (NSArray *)segments) {
                NSString *text = ((id (*)(id, SEL))objc_msgSend)(segment,
                    NSSelectorFromString(@"substring"));
                double timestamp = ((double (*)(id, SEL))objc_msgSend)(segment,
                    NSSelectorFromString(@"timestamp"));
                double duration = ((double (*)(id, SEL))objc_msgSend)(segment,
                    NSSelectorFromString(@"duration"));
                float confidence = ((float (*)(id, SEL))objc_msgSend)(segment,
                    NSSelectorFromString(@"confidence"));

                // Filter to only words within the clip's trim range
                double wordEndInSource = timestamp + duration;
                if (timestamp >= trimStart && timestamp < trimStart + trimDuration) {
                    FCPTranscriptWord *word = [[FCPTranscriptWord alloc] init];
                    word.text = text;
                    // Map source time to timeline time
                    word.startTime = timelineStart + (timestamp - trimStart);
                    word.duration = MIN(duration, (trimStart + trimDuration) - timestamp);
                    word.confidence = confidence;
                    word.clipHandle = clipHandle;
                    word.clipTimelineStart = timelineStart;
                    word.sourceMediaOffset = trimStart;
                    [words addObject:word];
                }
            }

            FCPBridge_log(@"[Transcript] Got %lu words from segments", (unsigned long)words.count);
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

    FCPBridge_log(@"[Transcript] Transcribing file: %@", audioURL.path);

    dispatch_async(dispatch_get_main_queue(), ^{
        self.status = FCPTranscriptStatusTranscribing;
        self.errorMessage = nil;
        [self updateStatusUI:@"Transcribing audio file..."];
        self.spinner.hidden = NO;
        [self.spinner startAnimation:nil];
        self.refreshButton.enabled = NO;
    });

    [self requestSpeechAuthorizationWithCompletion:^(BOOL authorized) {
        if (!authorized) {
            [self setErrorState:@"Speech recognition not authorized."];
            return;
        }

        [self.mutableWords removeAllObjects];

        [self transcribeAudioFile:audioURL
                    timelineStart:timelineStart
                        trimStart:trimStart
                     trimDuration:(trimDuration == HUGE_VAL ? 7200.0 : trimDuration) // 2hr max
                       clipHandle:nil
                       completion:^(NSArray<FCPTranscriptWord *> *words, NSError *error) {
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
                    self.status = FCPTranscriptStatusReady;
                    [self rebuildTextView];
                    [self startPlayheadTimer];
                    [self updateStatusUI:[NSString stringWithFormat:@"%lu words transcribed",
                        (unsigned long)self.mutableWords.count]];
                }

                self.spinner.hidden = YES;
                [self.spinner stopAnimation:nil];
                self.refreshButton.enabled = YES;
            });
        }];
    }];
}

#pragma mark - Text View Display

- (void)rebuildTextView {
    self.suppressTextViewCallbacks = YES;

    NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc] init];
    NSUInteger textPos = 0;

    NSDictionary *normalAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:16],
        NSForegroundColorAttributeName: [NSColor labelColor],
        NSCursorAttributeName: [NSCursor pointingHandCursor],
    };

    NSDictionary *lowConfAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:16],
        NSForegroundColorAttributeName: [NSColor systemOrangeColor],
        NSCursorAttributeName: [NSCursor pointingHandCursor],
    };

    @synchronized (self.mutableWords) {
        for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
            FCPTranscriptWord *word = self.mutableWords[i];

            // Choose attributes based on confidence
            NSDictionary *attrs = (word.confidence < 0.5) ? lowConfAttrs : normalAttrs;

            // Add space before word (except first)
            if (i > 0) {
                // Check if this is a new sentence (prev word ended with punctuation or big time gap)
                FCPTranscriptWord *prev = self.mutableWords[i - 1];
                double gap = word.startTime - prev.endTime;

                if (gap > 2.0) {
                    // Paragraph break for large gaps (>2s)
                    [attrStr appendAttributedString:[[NSAttributedString alloc]
                        initWithString:@"\n\n" attributes:normalAttrs]];
                    textPos += 2;
                } else {
                    [attrStr appendAttributedString:[[NSAttributedString alloc]
                        initWithString:@" " attributes:normalAttrs]];
                    textPos += 1;
                }
            }

            // Record text range for this word
            word.textRange = NSMakeRange(textPos, word.text.length);

            // Add word with tooltip showing time
            NSMutableDictionary *wordAttrs = [attrs mutableCopy];
            wordAttrs[NSToolTipAttributeName] = [NSString stringWithFormat:@"%.2fs - %.2fs (%.0f%%)",
                word.startTime, word.endTime, word.confidence * 100];
            wordAttrs[@"FCPWordIndex"] = @(i);

            [attrStr appendAttributedString:[[NSAttributedString alloc]
                initWithString:word.text attributes:wordAttrs]];
            textPos += word.text.length;
        }
    }

    [self.textView.textStorage setAttributedString:attrStr];
    self.fullText = [attrStr string];

    self.suppressTextViewCallbacks = NO;
}

#pragma mark - Click Handling (Jump Playhead)

- (void)handleClickAtCharIndex:(NSUInteger)charIdx {
    FCPTranscriptWord *word = [self wordAtCharIndex:charIdx];
    if (!word) return;

    FCPBridge_log(@"[Transcript] Clicked word %lu: \"%@\" at %.2fs",
                  (unsigned long)word.wordIndex, word.text, word.startTime);

    // Jump playhead to word's start time
    [self setPlayheadToTime:word.startTime];

    // Highlight the clicked word briefly
    [self highlightWordRange:NSMakeRange(word.wordIndex, 1)
                       color:[NSColor selectedTextBackgroundColor]];
}

- (FCPTranscriptWord *)wordAtCharIndex:(NSUInteger)charIdx {
    @synchronized (self.mutableWords) {
        for (FCPTranscriptWord *word in self.mutableWords) {
            if (charIdx >= word.textRange.location &&
                charIdx < NSMaxRange(word.textRange)) {
                return word;
            }
        }
    }
    return nil;
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
        for (FCPTranscriptWord *word in self.mutableWords) {
            NSRange intersection = NSIntersectionRange(selectedRange, word.textRange);
            if (intersection.length > 0) {
                [wordIndices addIndex:word.wordIndex];
            }
        }
    }

    if (wordIndices.count == 0) {
        NSBeep();
        return;
    }

    NSUInteger startIdx = wordIndices.firstIndex;
    NSUInteger count = wordIndices.lastIndex - wordIndices.firstIndex + 1;

    FCPBridge_log(@"[Transcript] Deleting %lu words starting at index %lu",
                  (unsigned long)count, (unsigned long)startIdx);

    // Perform the delete operation
    NSDictionary *result = [self deleteWordsFromIndex:startIdx count:count];
    FCPBridge_log(@"[Transcript] Delete result: %@", result);
}

#pragma mark - Drag & Drop Word Reordering

- (NSRange)selectedWordRange {
    NSRange sel = self.textView.selectedRange;
    if (sel.length == 0) return NSMakeRange(0, 0);

    NSMutableIndexSet *wordIndices = [NSMutableIndexSet indexSet];
    @synchronized (self.mutableWords) {
        for (FCPTranscriptWord *word in self.mutableWords) {
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
        // Find the word at or just after charIdx
        for (FCPTranscriptWord *word in self.mutableWords) {
            if (charIdx <= word.textRange.location) {
                return word.wordIndex;
            }
            if (charIdx < NSMaxRange(word.textRange)) {
                // Dropped in the middle of a word — decide left or right half
                NSUInteger midpoint = word.textRange.location + word.textRange.length / 2;
                if (charIdx <= midpoint) {
                    return word.wordIndex;
                } else {
                    return word.wordIndex + 1;
                }
            }
        }
    }
    // Past the end
    return self.mutableWords.count;
}

- (void)handleDropOfWordStart:(NSUInteger)srcStart count:(NSUInteger)srcCount atCharIndex:(NSUInteger)charIdx {
    NSUInteger destWordIdx = [self wordIndexAtCharIndex:charIdx];

    // Don't move to the same position
    if (destWordIdx >= srcStart && destWordIdx <= srcStart + srcCount) {
        FCPBridge_log(@"[Transcript] Drop at same position — no-op");
        return;
    }

    FCPBridge_log(@"[Transcript] Drag-drop: words %lu-%lu -> before word %lu",
                  (unsigned long)srcStart, (unsigned long)(srcStart + srcCount - 1),
                  (unsigned long)destWordIdx);

    [self updateStatusUI:@"Moving clips on timeline..."];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = [self moveWordsFromIndex:srcStart count:srcCount toIndex:destWordIdx];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result[@"error"]) {
                [self updateStatusUI:[NSString stringWithFormat:@"Move failed: %@", result[@"error"]]];
                FCPBridge_log(@"[Transcript] Move error: %@", result[@"error"]);
            } else {
                [self updateStatusUI:[NSString stringWithFormat:@"Moved %lu word(s)", (unsigned long)srcCount]];
                FCPBridge_log(@"[Transcript] Move succeeded: %@", result);
            }
        });
    });
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

    // Get the time range to delete
    FCPTranscriptWord *firstWord = self.mutableWords[startIndex];
    FCPTranscriptWord *lastWord = self.mutableWords[startIndex + count - 1];
    double deleteStart = firstWord.startTime;
    double deleteEnd = lastWord.endTime;

    FCPBridge_log(@"[Transcript] Deleting words %lu-%lu: %.2fs - %.2fs",
                  (unsigned long)startIndex, (unsigned long)(startIndex + count - 1),
                  deleteStart, deleteEnd);

    // Perform timeline edit: blade at start, blade at end, select segment, delete
    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
        @try {
            id timeline = [self getActiveTimelineModule];
            if (!timeline) {
                result = @{@"error": @"No active timeline"};
                return;
            }

            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) {
                result = @{@"error": @"No sequence"};
                return;
            }

            // Get frame duration for precision
            double frameDuration = 1.0 / 24.0; // default 24fps
            if ([timeline respondsToSelector:@selector(sequenceFrameDuration)]) {
                FCPTranscript_CMTime fd = ((FCPTranscript_CMTime (*)(id, SEL))objc_msgSend)(
                    timeline, @selector(sequenceFrameDuration));
                if (fd.timescale > 0) frameDuration = (double)fd.value / fd.timescale;
            }

            // Step 1: Move playhead to delete start and blade
            [self setPlayheadToTime:deleteStart];
            // Small delay for UI to update
            [NSThread sleepForTimeInterval:0.05];

            SEL bladeSel = NSSelectorFromString(@"blade:");
            if ([timeline respondsToSelector:bladeSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, bladeSel, nil);
                FCPBridge_log(@"[Transcript] Blade at %.2fs", deleteStart);
            }
            [NSThread sleepForTimeInterval:0.05];

            // Step 2: Move playhead to delete end and blade
            [self setPlayheadToTime:deleteEnd];
            [NSThread sleepForTimeInterval:0.05];

            if ([timeline respondsToSelector:bladeSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, bladeSel, nil);
                FCPBridge_log(@"[Transcript] Blade at %.2fs", deleteEnd);
            }
            [NSThread sleepForTimeInterval:0.05];

            // Step 3: Move playhead to middle of the deleted segment
            double midPoint = (deleteStart + deleteEnd) / 2.0;
            [self setPlayheadToTime:midPoint];
            [NSThread sleepForTimeInterval:0.05];

            // Step 4: Select clip at playhead
            SEL selectSel = NSSelectorFromString(@"selectClipAtPlayhead:");
            if ([timeline respondsToSelector:selectSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, selectSel, nil);
                FCPBridge_log(@"[Transcript] Selected clip at playhead");
            }
            [NSThread sleepForTimeInterval:0.05];

            // Step 5: Delete (ripple delete)
            SEL deleteSel = NSSelectorFromString(@"delete:");
            if ([timeline respondsToSelector:deleteSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, deleteSel, nil);
                FCPBridge_log(@"[Transcript] Deleted segment");
            }

            result = @{@"status": @"ok",
                       @"deletedWords": @(count),
                       @"timeRange": @{@"start": @(deleteStart), @"end": @(deleteEnd)},
                       @"duration": @(deleteEnd - deleteStart)};

        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    if (result[@"error"]) return result;

    // Re-transcribe from timeline to get accurate timestamps after the edit
    [self scheduleRetranscribe];

    return result;
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
        // Can't move to within the source range
        if (destIndex > startIndex && destIndex < startIndex + count) {
            return @{@"error": @"Cannot move to within source range"};
        }
    }

    FCPTranscriptWord *firstWord = self.mutableWords[startIndex];
    FCPTranscriptWord *lastWord = self.mutableWords[startIndex + count - 1];
    double sourceStart = firstWord.startTime;
    double sourceEnd = lastWord.endTime;
    double sourceDuration = sourceEnd - sourceStart;

    // Calculate destination time
    double destTime;
    if (destIndex == 0) {
        destTime = 0;
    } else if (destIndex >= self.mutableWords.count) {
        FCPTranscriptWord *lastW = self.mutableWords.lastObject;
        destTime = lastW.endTime;
    } else {
        destTime = self.mutableWords[destIndex].startTime;
    }

    FCPBridge_log(@"[Transcript] Moving words %lu-%lu (%.2fs-%.2fs) to index %lu (time %.2fs)",
                  (unsigned long)startIndex, (unsigned long)(startIndex + count - 1),
                  sourceStart, sourceEnd, (unsigned long)destIndex, destTime);

    __block NSDictionary *result = nil;
    FCPBridge_executeOnMainThread(^{
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

            // Step 5: Move playhead to destination
            // After cutting, positions shift. Adjust destination if it was after source.
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

    // Re-transcribe from timeline to get accurate timestamps after the edit
    [self scheduleRetranscribe];

    return result;
}

- (void)scheduleRetranscribe {
    // After an edit, wait briefly for FCP to settle then re-transcribe
    // so word timestamps match the new timeline layout
    FCPBridge_log(@"[Transcript] Scheduling re-transcribe after edit...");
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
    if (self.status != FCPTranscriptStatusReady) return;
    if (self.mutableWords.count == 0) return;

    // Get current playhead time
    __block double playheadTime = -1;
    FCPBridge_executeOnMainThread(^{
        @try {
            id timeline = [self getActiveTimelineModule];
            if (!timeline) return;
            if ([timeline respondsToSelector:@selector(playheadTime)]) {
                FCPTranscript_CMTime t = ((FCPTranscript_CMTime (*)(id, SEL))objc_msgSend)(
                    timeline, @selector(playheadTime));
                playheadTime = CMTimeToSeconds(t);
            }
        } @catch (NSException *e) {}
    });

    if (playheadTime >= 0) {
        [self updatePlayheadHighlight:playheadTime];
    }
}

- (void)updatePlayheadHighlight:(double)timeInSeconds {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.suppressTextViewCallbacks) return;
        self.suppressTextViewCallbacks = YES;

        NSTextStorage *storage = self.textView.textStorage;
        NSRange fullRange = NSMakeRange(0, storage.length);

        // Clear all highlights
        [storage removeAttribute:NSBackgroundColorAttributeName range:fullRange];

        // Find current word and highlight it
        @synchronized (self.mutableWords) {
            for (FCPTranscriptWord *word in self.mutableWords) {
                if (timeInSeconds >= word.startTime && timeInSeconds < word.endTime) {
                    if (word.textRange.location + word.textRange.length <= storage.length) {
                        [storage addAttribute:NSBackgroundColorAttributeName
                                        value:[NSColor colorWithCalibratedRed:0.2 green:0.5 blue:1.0 alpha:0.3]
                                        range:word.textRange];
                    }
                    break;
                }
            }
        }

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
            FCPTranscriptWord *word = self.mutableWords[i];
            if (word.textRange.location + word.textRange.length <= storage.length) {
                [storage addAttribute:NSBackgroundColorAttributeName
                                value:color
                                range:word.textRange];
            }
        }

        self.suppressTextViewCallbacks = NO;

        // Clear highlight after 0.5s
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

- (id)getActiveTimelineModule {
    id app = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("NSApplication"), @selector(sharedApplication));
    id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
    if (!delegate) return nil;

    SEL aecSel = @selector(activeEditorContainer);
    if (![delegate respondsToSelector:aecSel]) return nil;
    id container = ((id (*)(id, SEL))objc_msgSend)(delegate, aecSel);
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

    // Get the sequence's timescale
    int32_t timescale = 600; // default (supports 24, 25, 30fps precisely)
    if ([timeline respondsToSelector:@selector(sequenceFrameDuration)]) {
        FCPTranscript_CMTime fd = ((FCPTranscript_CMTime (*)(id, SEL))objc_msgSend)(
            timeline, @selector(sequenceFrameDuration));
        if (fd.timescale > 0) timescale = fd.timescale;
    }

    FCPTranscript_CMTime cmTime = {
        .value = (int64_t)(seconds * timescale),
        .timescale = timescale,
        .flags = 1,
        .epoch = 0
    };

    SEL setPlayheadSel = NSSelectorFromString(@"setPlayheadTime:");
    if ([timeline respondsToSelector:setPlayheadSel]) {
        ((void (*)(id, SEL, FCPTranscript_CMTime))objc_msgSend)(timeline, setPlayheadSel, cmTime);
    }
}

#pragma mark - State

- (NSArray<FCPTranscriptWord *> *)words {
    @synchronized (self.mutableWords) {
        return [self.mutableWords copy];
    }
}

- (NSDictionary *)getState {
    NSMutableDictionary *state = [NSMutableDictionary dictionary];

    switch (self.status) {
        case FCPTranscriptStatusIdle:        state[@"status"] = @"idle"; break;
        case FCPTranscriptStatusTranscribing: state[@"status"] = @"transcribing"; break;
        case FCPTranscriptStatusReady:       state[@"status"] = @"ready"; break;
        case FCPTranscriptStatusError:       state[@"status"] = @"error"; break;
    }

    state[@"visible"] = @(self.isVisible);
    state[@"wordCount"] = @(self.mutableWords.count);

    if (self.errorMessage) {
        state[@"errorMessage"] = self.errorMessage;
    }

    if (self.fullText) {
        state[@"text"] = self.fullText;
    }

    if (self.status == FCPTranscriptStatusTranscribing) {
        state[@"progress"] = @{
            @"completed": @(self.completedTranscriptions),
            @"total": @(self.totalTranscriptions)
        };
    }

    if (self.mutableWords.count > 0) {
        NSMutableArray *wordList = [NSMutableArray array];
        @synchronized (self.mutableWords) {
            for (FCPTranscriptWord *word in self.mutableWords) {
                [wordList addObject:@{
                    @"index": @(word.wordIndex),
                    @"text": word.text ?: @"",
                    @"startTime": @(word.startTime),
                    @"endTime": @(word.endTime),
                    @"duration": @(word.duration),
                    @"confidence": @(word.confidence)
                }];
            }
        }
        state[@"words"] = wordList;
    }

    return state;
}

#pragma mark - UI Helpers

- (void)updateStatusUI:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.stringValue = message;
    });
}

- (void)setErrorState:(NSString *)error {
    FCPBridge_log(@"[Transcript] Error: %@", error);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.status = FCPTranscriptStatusError;
        self.errorMessage = error;
        [self updateStatusUI:[NSString stringWithFormat:@"Error: %@", error]];
        self.spinner.hidden = YES;
        [self.spinner stopAnimation:nil];
        self.refreshButton.enabled = YES;
    });
}

#pragma mark - NSTextView Delegate

- (BOOL)textView:(NSTextView *)textView shouldChangeTextInRange:(NSRange)range
                                               replacementString:(NSString *)string {
    if (self.suppressTextViewCallbacks) return YES;
    // Only allow deletions (empty replacement string), not insertions
    if (string.length > 0) return NO;
    return NO; // Deletions handled by keyDown
}

@end
