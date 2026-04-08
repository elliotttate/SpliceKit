//
//  SpliceKitLuaPanel.m
//  SpliceKit — Floating Lua REPL panel inside FCP.
//
//  Provides an interactive REPL for writing and testing Lua scripts.
//  Follows the same NSPanel pattern as SpliceKitLogPanel.
//

#import "SpliceKitLuaPanel.h"
#import "SpliceKitLua.h"
#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const kHistoryKey = @"SpliceKitLuaREPLHistory";
static const NSUInteger kMaxHistoryItems = 200;
static const NSUInteger kMaxOutputLines = 5000;

// ============================================================================
#pragma mark - Font Helper
// ============================================================================

static NSFont *SpliceKitLuaPanel_monoFont(CGFloat size) {
    if (@available(macOS 15.0, *)) {
        return [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
    }
    return [NSFont userFixedPitchFontOfSize:size] ?: [NSFont systemFontOfSize:size];
}

// ============================================================================
#pragma mark - Input Field (handles Up/Down for history)
// ============================================================================

@class SpliceKitLuaPanel;

@interface SpliceKitLuaInputField : NSTextField
@property (nonatomic, weak) SpliceKitLuaPanel *luaPanel;
@end

@implementation SpliceKitLuaInputField

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown) {
        unsigned short keyCode = event.keyCode;
        // Up arrow = 126, Down arrow = 125
        if (keyCode == 126) {
            [self.luaPanel performSelector:@selector(historyUp)];
            return YES;
        }
        if (keyCode == 125) {
            [self.luaPanel performSelector:@selector(historyDown)];
            return YES;
        }
    }
    return [super performKeyEquivalent:event];
}

@end

// ============================================================================
#pragma mark - Panel
// ============================================================================

@interface SpliceKitLuaPanel () <NSWindowDelegate, NSTextFieldDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSTextView *outputView;
@property (nonatomic, strong) SpliceKitLuaInputField *inputField;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSMutableArray<NSString *> *history;
@property (nonatomic) NSInteger historyIndex;
@property (nonatomic, copy) NSString *pendingInput;  // saved when browsing history
@property (nonatomic, strong) NSMutableString *multilineBuffer;
@property (nonatomic) NSUInteger outputLineCount;
@end

@implementation SpliceKitLuaPanel

+ (instancetype)sharedPanel {
    static SpliceKitLuaPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.history = [[[NSUserDefaults standardUserDefaults] arrayForKey:kHistoryKey] mutableCopy]
                    ?: [NSMutableArray array];
    self.historyIndex = -1;
    self.multilineBuffer = nil;
    self.outputLineCount = 0;
    return self;
}

- (BOOL)isVisible {
    return self.panel && self.panel.isVisible;
}

- (void)togglePanel {
    if (self.isVisible) [self hidePanel];
    else [self showPanel];
}

- (void)showPanel {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self showPanel]; });
        return;
    }
    [self setupPanelIfNeeded];
    [self.panel makeKeyAndOrderFront:nil];
    [self.panel makeFirstResponder:self.inputField];
}

- (void)hidePanel {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self hidePanel]; });
        return;
    }
    [self.panel orderOut:nil];
}

// ============================================================================
#pragma mark - Panel Setup
// ============================================================================

- (void)setupPanelIfNeeded {
    if (self.panel) return;

    CGFloat width = 700.0, height = 480.0;
    NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];
    CGFloat x = NSMaxX(screenFrame) - width - 40.0;
    CGFloat y = NSMidY(screenFrame) - height / 2.0;
    NSRect frame = NSMakeRect(MAX(x, 60.0), MAX(y, 80.0), width, height);

    self.panel = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:(NSWindowStyleMaskTitled |
                                                       NSWindowStyleMaskClosable |
                                                       NSWindowStyleMaskResizable |
                                                       NSWindowStyleMaskUtilityWindow)
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"Lua REPL";
    self.panel.floatingPanel = YES;
    self.panel.becomesKeyOnlyIfNeeded = NO;
    self.panel.hidesOnDeactivate = NO;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.minSize = NSMakeSize(400.0, 250.0);
    self.panel.releasedWhenClosed = NO;
    self.panel.delegate = self;
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorCanJoinAllSpaces;

    NSView *content = self.panel.contentView;

    // --- Output area ---
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.borderType = NSNoBorder;
    self.scrollView.drawsBackground = YES;
    self.scrollView.backgroundColor = [NSColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:1.0];
    [content addSubview:self.scrollView];

    NSTextView *outputView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    outputView.editable = NO;
    outputView.richText = YES;
    outputView.selectable = YES;
    outputView.automaticQuoteSubstitutionEnabled = NO;
    outputView.automaticDashSubstitutionEnabled = NO;
    outputView.automaticTextReplacementEnabled = NO;
    outputView.allowsUndo = NO;
    outputView.importsGraphics = NO;
    outputView.drawsBackground = YES;
    outputView.backgroundColor = [NSColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:1.0];
    outputView.textColor = [NSColor whiteColor];
    outputView.font = SpliceKitLuaPanel_monoFont(12);
    outputView.textContainerInset = NSMakeSize(8.0, 8.0);
    self.scrollView.documentView = outputView;
    self.outputView = outputView;

    // --- Bottom bar (input + buttons) ---
    NSView *bottomBar = [[NSView alloc] initWithFrame:NSZeroRect];
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:bottomBar];

    // Prompt label
    NSTextField *prompt = [NSTextField labelWithString:@">"];
    prompt.translatesAutoresizingMaskIntoConstraints = NO;
    prompt.font = SpliceKitLuaPanel_monoFont(13);
    prompt.textColor = [NSColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:1.0];
    [bottomBar addSubview:prompt];

    // Input field
    SpliceKitLuaInputField *inputField = [[SpliceKitLuaInputField alloc] initWithFrame:NSZeroRect];
    inputField.luaPanel = self;
    inputField.translatesAutoresizingMaskIntoConstraints = NO;
    inputField.font = SpliceKitLuaPanel_monoFont(12);
    inputField.textColor = [NSColor whiteColor];
    inputField.backgroundColor = [NSColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:1.0];
    inputField.drawsBackground = YES;
    inputField.bordered = YES;
    inputField.bezeled = YES;
    inputField.bezelStyle = NSTextFieldRoundedBezel;
    inputField.focusRingType = NSFocusRingTypeNone;
    inputField.placeholderString = @"sk.blade()  -- press Enter to execute";
    inputField.delegate = self;
    inputField.target = self;
    inputField.action = @selector(inputSubmitted:);
    [bottomBar addSubview:inputField];
    self.inputField = inputField;

    // Buttons
    NSButton *runFileButton = [NSButton buttonWithTitle:@"Run File..."
                                                target:self
                                                action:@selector(runFileClicked:)];
    runFileButton.translatesAutoresizingMaskIntoConstraints = NO;
    runFileButton.bezelStyle = NSBezelStyleRounded;
    [bottomBar addSubview:runFileButton];

    NSButton *resetButton = [NSButton buttonWithTitle:@"Reset VM"
                                               target:self
                                               action:@selector(resetClicked:)];
    resetButton.translatesAutoresizingMaskIntoConstraints = NO;
    resetButton.bezelStyle = NSBezelStyleRounded;
    [bottomBar addSubview:resetButton];

    NSButton *clearButton = [NSButton buttonWithTitle:@"Clear"
                                               target:self
                                               action:@selector(clearClicked:)];
    clearButton.translatesAutoresizingMaskIntoConstraints = NO;
    clearButton.bezelStyle = NSBezelStyleRounded;
    [bottomBar addSubview:clearButton];

    // --- Layout ---
    [NSLayoutConstraint activateConstraints:@[
        // Output fills top area
        [self.scrollView.topAnchor constraintEqualToAnchor:content.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:bottomBar.topAnchor constant:-4.0],

        // Bottom bar
        [bottomBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:8.0],
        [bottomBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-8.0],
        [bottomBar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-8.0],
        [bottomBar.heightAnchor constraintEqualToConstant:30.0],

        // Prompt
        [prompt.leadingAnchor constraintEqualToAnchor:bottomBar.leadingAnchor],
        [prompt.centerYAnchor constraintEqualToAnchor:bottomBar.centerYAnchor],
        [prompt.widthAnchor constraintEqualToConstant:16.0],

        // Input field
        [inputField.leadingAnchor constraintEqualToAnchor:prompt.trailingAnchor constant:2.0],
        [inputField.centerYAnchor constraintEqualToAnchor:bottomBar.centerYAnchor],

        // Buttons (right side)
        [clearButton.trailingAnchor constraintEqualToAnchor:bottomBar.trailingAnchor],
        [clearButton.centerYAnchor constraintEqualToAnchor:bottomBar.centerYAnchor],

        [resetButton.trailingAnchor constraintEqualToAnchor:clearButton.leadingAnchor constant:-6.0],
        [resetButton.centerYAnchor constraintEqualToAnchor:bottomBar.centerYAnchor],

        [runFileButton.trailingAnchor constraintEqualToAnchor:resetButton.leadingAnchor constant:-6.0],
        [runFileButton.centerYAnchor constraintEqualToAnchor:bottomBar.centerYAnchor],

        // Input stretches between prompt and buttons
        [inputField.trailingAnchor constraintEqualToAnchor:runFileButton.leadingAnchor constant:-8.0],
    ]];

    // Welcome message
    [self appendOutput:@"Lua REPL — type Lua code and press Enter\n"
                 color:[NSColor colorWithRed:0.5 green:0.5 blue:0.55 alpha:1.0]];
    [self appendOutput:@"Use sk.blade(), sk.clips(), sk.seek(5.0), sk.rpc(...), etc.\n"
                 color:[NSColor colorWithRed:0.5 green:0.5 blue:0.55 alpha:1.0]];
    [self appendOutput:@"Type 'sk' to see available functions.\n\n"
                 color:[NSColor colorWithRed:0.5 green:0.5 blue:0.55 alpha:1.0]];
}

// ============================================================================
#pragma mark - Output
// ============================================================================

- (void)appendOutput:(NSString *)text color:(NSColor *)color {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendOutput:text color:color];
        });
        return;
    }
    if (!self.outputView) return;

    NSDictionary *attrs = @{
        NSFontAttributeName: SpliceKitLuaPanel_monoFont(12),
        NSForegroundColorAttributeName: color ?: [NSColor whiteColor],
    };
    NSAttributedString *attrStr = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    [self.outputView.textStorage appendAttributedString:attrStr];

    // Trim excess lines
    self.outputLineCount += [[text componentsSeparatedByString:@"\n"] count] - 1;
    if (self.outputLineCount > kMaxOutputLines) {
        [self trimOutput];
    }

    // Scroll to bottom
    [self.outputView scrollToEndOfDocument:nil];
}

- (void)appendExecutionResult:(NSDictionary *)result sourceLabel:(NSString *)sourceLabel {
    NSString *output = result[@"output"];
    NSString *resultVal = result[@"result"];
    NSString *error = result[@"error"];
    NSNumber *durationMs = result[@"durationMs"];
    BOOL succeeded = (error.length == 0);

    if (output.length > 0) {
        [self appendOutput:output color:[NSColor whiteColor]];
    }
    if (resultVal.length > 0) {
        [self appendOutput:[NSString stringWithFormat:@"%@\n", resultVal]
                     color:[NSColor colorWithRed:0.6 green:0.9 blue:0.6 alpha:1.0]];
    }

    NSString *label = sourceLabel.length > 0 ? sourceLabel : @"code";
    NSString *durationSuffix = durationMs ? [NSString stringWithFormat:@" (%@ ms)", durationMs] : @"";
    NSString *statusLine = [NSString stringWithFormat:@"%@ %@%@\n",
                            label,
                            succeeded ? @"ok" : @"failed",
                            durationSuffix];
    NSColor *statusColor = succeeded
        ? [NSColor colorWithRed:0.6 green:0.9 blue:0.6 alpha:1.0]
        : [NSColor colorWithRed:1.0 green:0.4 blue:0.4 alpha:1.0];
    [self appendOutput:statusLine color:statusColor];

    if (error.length > 0) {
        [self appendOutput:[NSString stringWithFormat:@"error: %@\n", error]
                     color:[NSColor colorWithRed:1.0 green:0.4 blue:0.4 alpha:1.0]];
    }
}

- (void)trimOutput {
    NSString *text = self.outputView.textStorage.string;
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    if (lines.count <= kMaxOutputLines) return;
    NSUInteger removeCount = lines.count - kMaxOutputLines;
    NSUInteger charCount = 0;
    for (NSUInteger i = 0; i < removeCount; i++) {
        charCount += [lines[i] length] + 1;
    }
    if (charCount > 0 && charCount <= self.outputView.textStorage.length) {
        [self.outputView.textStorage deleteCharactersInRange:NSMakeRange(0, charCount)];
        self.outputLineCount = kMaxOutputLines;
    }
}

// ============================================================================
#pragma mark - Input Handling
// ============================================================================

- (void)inputSubmitted:(id)sender {
    (void)sender;
    NSString *input = [self.inputField.stringValue copy];
    if (input.length == 0) return;

    self.inputField.stringValue = @"";

    // Check for multiline continuation
    if (self.multilineBuffer) {
        [self.multilineBuffer appendFormat:@"\n%@", input];
        if ([self isComplete:self.multilineBuffer]) {
            NSString *code = [self.multilineBuffer copy];
            self.multilineBuffer = nil;
            [self appendOutput:[NSString stringWithFormat:@"... %@\n", input]
                         color:[NSColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:1.0]];
            [self executeCode:code];
        } else {
            [self appendOutput:[NSString stringWithFormat:@"... %@\n", input]
                         color:[NSColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:1.0]];
            self.inputField.placeholderString = @"... (continue or press Escape to cancel)";
        }
        return;
    }

    // Show input in output
    [self appendOutput:[NSString stringWithFormat:@"> %@\n", input]
                 color:[NSColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:1.0]];

    // Check if this starts an incomplete construct
    if (![self isComplete:input]) {
        self.multilineBuffer = [input mutableCopy];
        self.inputField.placeholderString = @"... (continue or press Escape to cancel)";
        return;
    }

    [self executeCode:input];
}

- (void)executeCode:(NSString *)code {
    // Add to history
    if (code.length > 0) {
        [self.history removeObject:code];
        [self.history addObject:code];
        if (self.history.count > kMaxHistoryItems) {
            [self.history removeObjectAtIndex:0];
        }
        [[NSUserDefaults standardUserDefaults] setObject:self.history forKey:kHistoryKey];
    }
    self.historyIndex = -1;
    self.pendingInput = nil;
    self.inputField.placeholderString = @"sk.blade()  -- press Enter to execute";

    // Execute on background
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = SpliceKitLua_execute(code);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendExecutionResult:result sourceLabel:@"code"];
        });
    });
}

// Check if Lua code is a complete chunk (no unclosed blocks)
- (BOOL)isComplete:(NSString *)code {
    if (!SpliceKitLua_isInitialized()) return YES;
    // Try to compile: if it fails with <eof> in the error, it's incomplete
    NSDictionary *result = SpliceKitLua_execute(
        [NSString stringWithFormat:@"return load(%@)", [self luaQuote:code]]);
    // If load() returned nil + error containing <eof>, it's incomplete
    NSString *output = result[@"output"];
    NSString *error = result[@"error"];
    if (error && [error containsString:@"<eof>"]) return NO;
    if (output && [output containsString:@"<eof>"]) return NO;
    return YES;
}

- (NSString *)luaQuote:(NSString *)s {
    // Use long string literals to avoid escaping issues
    // Find the right level of = signs
    NSString *delim = @"[[";
    NSString *endDelim = @"]]";
    int level = 0;
    while ([s containsString:endDelim]) {
        level++;
        delim = [NSString stringWithFormat:@"[%@[", [@"" stringByPaddingToLength:level withString:@"=" startingAtIndex:0]];
        endDelim = [NSString stringWithFormat:@"]%@]", [@"" stringByPaddingToLength:level withString:@"=" startingAtIndex:0]];
    }
    return [NSString stringWithFormat:@"%@%@%@", delim, s, endDelim];
}

// ============================================================================
#pragma mark - History Navigation
// ============================================================================

- (void)historyUp {
    if (self.history.count == 0) return;
    if (self.historyIndex < 0) {
        self.pendingInput = [self.inputField.stringValue copy];
        self.historyIndex = (NSInteger)self.history.count - 1;
    } else if (self.historyIndex > 0) {
        self.historyIndex--;
    }
    self.inputField.stringValue = self.history[self.historyIndex];
    // Move cursor to end
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.inputField.currentEditor selectAll:nil];
        [self.inputField.currentEditor moveToEndOfLine:nil];
    });
}

- (void)historyDown {
    if (self.historyIndex < 0) return;
    if (self.historyIndex < (NSInteger)self.history.count - 1) {
        self.historyIndex++;
        self.inputField.stringValue = self.history[self.historyIndex];
    } else {
        self.historyIndex = -1;
        self.inputField.stringValue = self.pendingInput ?: @"";
    }
}

// ============================================================================
#pragma mark - NSTextFieldDelegate (Escape to cancel multiline)
// ============================================================================

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    if (commandSelector == @selector(cancelOperation:)) {
        if (self.multilineBuffer) {
            self.multilineBuffer = nil;
            self.inputField.placeholderString = @"sk.blade()  -- press Enter to execute";
            [self appendOutput:@"(multiline cancelled)\n"
                         color:[NSColor colorWithRed:0.5 green:0.5 blue:0.55 alpha:1.0]];
            return YES;
        }
    }
    return NO;
}

// ============================================================================
#pragma mark - Button Actions
// ============================================================================

- (void)runFileClicked:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"lua"]];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.message = @"Select a Lua script to execute";

    [panel beginSheetModalForWindow:self.panel completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL.path) {
            NSString *path = panel.URL.path;
            [self appendOutput:[NSString stringWithFormat:@"> dofile(%@)\n", [path lastPathComponent]]
                         color:[NSColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:1.0]];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSDictionary *fileResult = SpliceKitLua_executeFile(path);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self appendExecutionResult:fileResult sourceLabel:[path lastPathComponent]];
                });
            });
        }
    }];
}

- (void)resetClicked:(id)sender {
    (void)sender;
    SpliceKitLua_reset();
    [self appendOutput:@"--- VM reset ---\n"
                 color:[NSColor colorWithRed:1.0 green:0.8 blue:0.3 alpha:1.0]];
}

- (void)clearClicked:(id)sender {
    (void)sender;
    [self.outputView.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
    self.outputLineCount = 0;
}

@end
