//
//  SpliceKitVisionProPanel.m
//  SpliceKit — connect and stream to a Vision Pro via ImmersiveVideoToolbox.
//
//  Panel layout:
//   - Header: IVT availability + session status
//   - Display name text field + Start / Stop buttons
//   - Two tables side-by-side: Available Clients | Active Clients
//   - Manual "Add by host/IP" field for networks where Bonjour fails
//   - AIME metadata controls: Load, Send, Export, Current Camera
//   - Bottom bar: status message
//

#import "SpliceKitVisionProPanel.h"
#import "SpliceKitVisionPro.h"
#import "SpliceKit.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static UTType *AimeUTType(void) {
    if (@available(macOS 11.0, *)) {
        return [UTType typeWithFilenameExtension:@"aime"] ?: UTTypeData;
    }
    return nil;
}

#pragma mark - Panel

@interface SpliceKitVisionProPanel () <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *displayNameField;
@property (nonatomic, strong) NSButton *startStopButton;
@property (nonatomic, strong) NSTableView *availableTable;
@property (nonatomic, strong) NSTableView *activeTable;
@property (nonatomic, strong) NSTextField *manualField;
@property (nonatomic, strong) NSButton *manualAddButton;
@property (nonatomic, strong) NSTextField *aimeLabel;
@property (nonatomic, strong) NSButton *loadAimeButton;
@property (nonatomic, strong) NSButton *sendAimeButton;
@property (nonatomic, strong) NSButton *exportAimeButton;
@property (nonatomic, strong) NSTextField *cameraField;
@property (nonatomic, strong) NSTextField *messageLabel;

@property (nonatomic, strong) NSArray<NSString *> *availableClients;
@property (nonatomic, strong) NSArray<NSString *> *activeClients;
@property (nonatomic, copy) NSString *loadedAimePath;
@end

@implementation SpliceKitVisionProPanel

+ (instancetype)sharedPanel {
    static SpliceKitVisionProPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _availableClients = @[];
    _activeClients = @[];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(stateDidChange:)
                                                 name:SpliceKitVisionProStateDidChangeNotification
                                               object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)isVisible { return self.panel && self.panel.isVisible; }

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
    [self refreshFromModel];
    [self.panel makeKeyAndOrderFront:nil];
}

- (void)hidePanel {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self hidePanel]; });
        return;
    }
    [self.panel orderOut:nil];
}

#pragma mark - Setup

- (void)setupPanelIfNeeded {
    if (self.panel) return;

    CGFloat width = 620.0, height = 520.0;
    NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];
    NSRect frame = NSMakeRect(NSMidX(screenFrame) - width / 2.0,
                              NSMidY(screenFrame) - height / 2.0,
                              width, height);
    self.panel = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:(NSWindowStyleMaskTitled |
                                                       NSWindowStyleMaskClosable |
                                                       NSWindowStyleMaskResizable |
                                                       NSWindowStyleMaskUtilityWindow)
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"Vision Pro Preview";
    self.panel.floatingPanel = YES;
    self.panel.becomesKeyOnlyIfNeeded = NO;
    self.panel.hidesOnDeactivate = NO;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.minSize = NSMakeSize(520.0, 420.0);
    self.panel.releasedWhenClosed = NO;
    self.panel.delegate = self;
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorCanJoinAllSpaces;

    NSView *content = self.panel.contentView;

    // --- Status label ---
    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [NSFont boldSystemFontOfSize:13];
    [content addSubview:self.statusLabel];

    // --- Display name + start/stop ---
    NSTextField *displayNameLabel = [NSTextField labelWithString:@"Display name:"];
    displayNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:displayNameLabel];

    self.displayNameField = [NSTextField textFieldWithString:@"SpliceKit"];
    self.displayNameField.translatesAutoresizingMaskIntoConstraints = NO;
    self.displayNameField.placeholderString = @"SpliceKit";
    [content addSubview:self.displayNameField];

    self.startStopButton = [NSButton buttonWithTitle:@"Start Discovery"
                                              target:self
                                              action:@selector(startStopClicked:)];
    self.startStopButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.startStopButton.bezelStyle = NSBezelStyleRounded;
    [content addSubview:self.startStopButton];

    // --- Section: Clients ---
    NSTextField *availableHeader = [NSTextField labelWithString:@"Discovered (Bonjour)"];
    availableHeader.translatesAutoresizingMaskIntoConstraints = NO;
    availableHeader.font = [NSFont boldSystemFontOfSize:12];
    [content addSubview:availableHeader];

    NSTextField *activeHeader = [NSTextField labelWithString:@"Connected"];
    activeHeader.translatesAutoresizingMaskIntoConstraints = NO;
    activeHeader.font = [NSFont boldSystemFontOfSize:12];
    [content addSubview:activeHeader];

    self.availableTable = [self makeTableView];
    self.activeTable = [self makeTableView];
    NSScrollView *availScroll = [self scrollWrapForTable:self.availableTable];
    NSScrollView *activeScroll = [self scrollWrapForTable:self.activeTable];
    [content addSubview:availScroll];
    [content addSubview:activeScroll];

    NSButton *connectButton = [NSButton buttonWithTitle:@"Connect →"
                                                 target:self
                                                 action:@selector(connectSelectedClicked:)];
    connectButton.translatesAutoresizingMaskIntoConstraints = NO;
    connectButton.bezelStyle = NSBezelStyleRounded;
    [content addSubview:connectButton];

    NSButton *disconnectButton = [NSButton buttonWithTitle:@"← Disconnect"
                                                    target:self
                                                    action:@selector(disconnectSelectedClicked:)];
    disconnectButton.translatesAutoresizingMaskIntoConstraints = NO;
    disconnectButton.bezelStyle = NSBezelStyleRounded;
    [content addSubview:disconnectButton];

    // --- Manual add ---
    NSTextField *manualLabel = [NSTextField labelWithString:@"Add manually (host or IP):"];
    manualLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:manualLabel];

    self.manualField = [NSTextField textFieldWithString:@""];
    self.manualField.translatesAutoresizingMaskIntoConstraints = NO;
    self.manualField.placeholderString = @"e.g. Vision-Pro.local or 192.168.1.42";
    [content addSubview:self.manualField];

    self.manualAddButton = [NSButton buttonWithTitle:@"Add"
                                              target:self
                                              action:@selector(manualAddClicked:)];
    self.manualAddButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.manualAddButton.bezelStyle = NSBezelStyleRounded;
    [content addSubview:self.manualAddButton];

    // --- AIME metadata ---
    NSTextField *aimeHeader = [NSTextField labelWithString:@"Immersive Metadata (AIME)"];
    aimeHeader.translatesAutoresizingMaskIntoConstraints = NO;
    aimeHeader.font = [NSFont boldSystemFontOfSize:12];
    [content addSubview:aimeHeader];

    self.aimeLabel = [NSTextField labelWithString:@"No .aime loaded"];
    self.aimeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.aimeLabel.textColor = [NSColor secondaryLabelColor];
    self.aimeLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [content addSubview:self.aimeLabel];

    self.loadAimeButton = [NSButton buttonWithTitle:@"Load .aime…" target:self action:@selector(loadAimeClicked:)];
    self.loadAimeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadAimeButton.bezelStyle = NSBezelStyleRounded;
    [content addSubview:self.loadAimeButton];

    self.sendAimeButton = [NSButton buttonWithTitle:@"Send to Headset" target:self action:@selector(sendAimeClicked:)];
    self.sendAimeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.sendAimeButton.bezelStyle = NSBezelStyleRounded;
    [content addSubview:self.sendAimeButton];

    self.exportAimeButton = [NSButton buttonWithTitle:@"Export…" target:self action:@selector(exportAimeClicked:)];
    self.exportAimeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.exportAimeButton.bezelStyle = NSBezelStyleRounded;
    [content addSubview:self.exportAimeButton];

    NSTextField *cameraLabel = [NSTextField labelWithString:@"Current camera ID:"];
    cameraLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:cameraLabel];

    self.cameraField = [NSTextField textFieldWithString:@""];
    self.cameraField.translatesAutoresizingMaskIntoConstraints = NO;
    self.cameraField.placeholderString = @"optional — set after loading AIME";
    self.cameraField.target = self;
    self.cameraField.action = @selector(cameraFieldCommitted:);
    [content addSubview:self.cameraField];

    // --- Message label (bottom) ---
    self.messageLabel = [NSTextField labelWithString:@""];
    self.messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.messageLabel.font = [NSFont systemFontOfSize:11];
    self.messageLabel.textColor = [NSColor secondaryLabelColor];
    self.messageLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [content addSubview:self.messageLabel];

    // --- Layout ---
    CGFloat P = 12.0;
    [NSLayoutConstraint activateConstraints:@[
        // Status header
        [self.statusLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:P],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:P],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-P],

        // Display name row
        [displayNameLabel.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:10],
        [displayNameLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:P],
        [displayNameLabel.widthAnchor constraintEqualToConstant:92],

        [self.displayNameField.centerYAnchor constraintEqualToAnchor:displayNameLabel.centerYAnchor],
        [self.displayNameField.leadingAnchor constraintEqualToAnchor:displayNameLabel.trailingAnchor constant:6],
        [self.displayNameField.trailingAnchor constraintEqualToAnchor:self.startStopButton.leadingAnchor constant:-8],

        [self.startStopButton.centerYAnchor constraintEqualToAnchor:displayNameLabel.centerYAnchor],
        [self.startStopButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-P],
        [self.startStopButton.widthAnchor constraintGreaterThanOrEqualToConstant:140],

        // Table headers
        [availableHeader.topAnchor constraintEqualToAnchor:displayNameLabel.bottomAnchor constant:14],
        [availableHeader.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:P],
        [activeHeader.topAnchor constraintEqualToAnchor:availableHeader.topAnchor],
        [activeHeader.leadingAnchor constraintEqualToAnchor:content.centerXAnchor constant:4],

        // Tables
        [availScroll.topAnchor constraintEqualToAnchor:availableHeader.bottomAnchor constant:4],
        [availScroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:P],
        [availScroll.trailingAnchor constraintEqualToAnchor:content.centerXAnchor constant:-4],
        [availScroll.heightAnchor constraintEqualToConstant:140],

        [activeScroll.topAnchor constraintEqualToAnchor:availScroll.topAnchor],
        [activeScroll.leadingAnchor constraintEqualToAnchor:content.centerXAnchor constant:4],
        [activeScroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-P],
        [activeScroll.heightAnchor constraintEqualToConstant:140],

        [connectButton.topAnchor constraintEqualToAnchor:availScroll.bottomAnchor constant:6],
        [connectButton.leadingAnchor constraintEqualToAnchor:availScroll.leadingAnchor],
        [disconnectButton.centerYAnchor constraintEqualToAnchor:connectButton.centerYAnchor],
        [disconnectButton.leadingAnchor constraintEqualToAnchor:activeScroll.leadingAnchor],

        // Manual add
        [manualLabel.topAnchor constraintEqualToAnchor:connectButton.bottomAnchor constant:12],
        [manualLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:P],
        [self.manualField.centerYAnchor constraintEqualToAnchor:manualLabel.centerYAnchor],
        [self.manualField.leadingAnchor constraintEqualToAnchor:manualLabel.trailingAnchor constant:6],
        [self.manualField.trailingAnchor constraintEqualToAnchor:self.manualAddButton.leadingAnchor constant:-8],
        [self.manualAddButton.centerYAnchor constraintEqualToAnchor:manualLabel.centerYAnchor],
        [self.manualAddButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-P],

        // AIME section
        [aimeHeader.topAnchor constraintEqualToAnchor:manualLabel.bottomAnchor constant:16],
        [aimeHeader.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:P],

        [self.aimeLabel.topAnchor constraintEqualToAnchor:aimeHeader.bottomAnchor constant:6],
        [self.aimeLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:P],
        [self.aimeLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-P],

        [self.loadAimeButton.topAnchor constraintEqualToAnchor:self.aimeLabel.bottomAnchor constant:6],
        [self.loadAimeButton.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:P],
        [self.sendAimeButton.centerYAnchor constraintEqualToAnchor:self.loadAimeButton.centerYAnchor],
        [self.sendAimeButton.leadingAnchor constraintEqualToAnchor:self.loadAimeButton.trailingAnchor constant:8],
        [self.exportAimeButton.centerYAnchor constraintEqualToAnchor:self.loadAimeButton.centerYAnchor],
        [self.exportAimeButton.leadingAnchor constraintEqualToAnchor:self.sendAimeButton.trailingAnchor constant:8],

        // Camera
        [cameraLabel.topAnchor constraintEqualToAnchor:self.loadAimeButton.bottomAnchor constant:10],
        [cameraLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:P],
        [cameraLabel.widthAnchor constraintEqualToConstant:120],
        [self.cameraField.centerYAnchor constraintEqualToAnchor:cameraLabel.centerYAnchor],
        [self.cameraField.leadingAnchor constraintEqualToAnchor:cameraLabel.trailingAnchor constant:6],
        [self.cameraField.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-P],

        // Message (bottom)
        [self.messageLabel.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-P],
        [self.messageLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:P],
        [self.messageLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-P],
    ]];
}

- (NSTableView *)makeTableView {
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    col.title = @"Display Name";
    col.width = 240;
    [table addTableColumn:col];
    table.headerView = nil;
    table.usesAlternatingRowBackgroundColors = YES;
    table.dataSource = self;
    table.delegate = self;
    table.allowsMultipleSelection = NO;
    table.rowHeight = 22;
    return table;
}

- (NSScrollView *)scrollWrapForTable:(NSTableView *)table {
    NSScrollView *s = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    s.translatesAutoresizingMaskIntoConstraints = NO;
    s.documentView = table;
    s.hasVerticalScroller = YES;
    s.borderType = NSBezelBorder;
    return s;
}

#pragma mark - Table data source

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.availableTable) return (NSInteger)self.availableClients.count;
    if (tableView == self.activeTable)    return (NSInteger)self.activeClients.count;
    return 0;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSArray *src = (tableView == self.availableTable) ? self.availableClients : self.activeClients;
    return (row >= 0 && row < (NSInteger)src.count) ? src[row] : nil;
}

#pragma mark - Actions

- (void)startStopClicked:(id)sender {
    SpliceKitVisionPro *vp = [SpliceKitVisionPro shared];
    if (vp.isRunning) {
        [vp stop];
        [self setMessage:@"Stopped."];
    } else {
        NSError *err = nil;
        BOOL ok = [vp startWithDisplayName:self.displayNameField.stringValue error:&err];
        if (ok) [self setMessage:@"Discovery started — Vision Pro devices will appear shortly."];
        else    [self setMessage:[NSString stringWithFormat:@"Failed to start: %@", err.localizedDescription]];
    }
    [self refreshFromModel];
}

- (void)connectSelectedClicked:(id)sender {
    NSInteger row = self.availableTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.availableClients.count) {
        [self setMessage:@"Select a discovered device first."];
        return;
    }
    NSString *host = self.availableClients[row];
    NSError *err = nil;
    if (![[SpliceKitVisionPro shared] addClientWithHostName:host error:&err]) {
        [self setMessage:[NSString stringWithFormat:@"Connect failed: %@", err.localizedDescription]];
    } else {
        [self setMessage:[NSString stringWithFormat:@"Connecting to %@…", host]];
    }
}

- (void)disconnectSelectedClicked:(id)sender {
    NSInteger row = self.activeTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.activeClients.count) {
        [self setMessage:@"Select a connected device first."];
        return;
    }
    NSString *host = self.activeClients[row];
    [[SpliceKitVisionPro shared] removeClientWithHostName:host];
    [self setMessage:[NSString stringWithFormat:@"Disconnected %@.", host]];
}

- (void)manualAddClicked:(id)sender {
    NSString *entry = [self.manualField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (entry.length == 0) {
        [self setMessage:@"Enter a host name (foo.local) or IP address."];
        return;
    }
    SpliceKitVisionPro *vp = [SpliceKitVisionPro shared];
    if (!vp.isRunning) {
        NSError *err = nil;
        if (![vp startWithDisplayName:self.displayNameField.stringValue error:&err]) {
            [self setMessage:[NSString stringWithFormat:@"Failed to start: %@", err.localizedDescription]];
            return;
        }
    }
    NSError *err = nil;
    BOOL isIP = [self looksLikeIPAddress:entry];
    BOOL ok = isIP ? [vp addClientWithIpAddress:entry error:&err]
                   : [vp addClientWithHostName:entry error:&err];
    if (ok) {
        [self setMessage:[NSString stringWithFormat:@"Added %@.", entry]];
        self.manualField.stringValue = @"";
    } else {
        [self setMessage:[NSString stringWithFormat:@"Add failed: %@", err.localizedDescription]];
    }
}

- (BOOL)looksLikeIPAddress:(NSString *)s {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
                               @"^(\\d{1,3}\\.){3}\\d{1,3}$|^[0-9a-fA-F:]+$"
                                                                        options:0 error:nil];
    return [re numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] > 0;
}

- (void)loadAimeClicked:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    if (@available(macOS 11.0, *)) {
        panel.allowedContentTypes = @[ AimeUTType() ];
    }
    panel.allowsMultipleSelection = NO;
    panel.title = @"Load Apple Immersive Metadata Envelope";
    [panel beginSheetModalForWindow:self.panel completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || panel.URL == nil) return;
        SpliceKitVisionPro *vp = [SpliceKitVisionPro shared];
        if (!vp.isRunning) {
            NSError *startErr = nil;
            if (![vp startWithDisplayName:self.displayNameField.stringValue error:&startErr]) {
                [self setMessage:[NSString stringWithFormat:@"Failed to start: %@", startErr.localizedDescription]];
                return;
            }
        }
        NSError *err = nil;
        BOOL ok = [vp loadAimeFileURL:panel.URL error:&err];
        if (ok) {
            self.loadedAimePath = panel.URL.path;
            self.aimeLabel.stringValue = self.loadedAimePath;
            [self setMessage:@"AIME loaded."];
        } else {
            [self setMessage:[NSString stringWithFormat:@"Load failed: %@", err.localizedDescription]];
        }
    }];
}

- (void)sendAimeClicked:(id)sender {
    SpliceKitVisionPro *vp = [SpliceKitVisionPro shared];
    NSError *err = nil;
    BOOL ok = self.loadedAimePath
        ? [vp sendAimeFileURL:[NSURL fileURLWithPath:self.loadedAimePath] error:&err]
        : [vp sendLoadedAimeWithError:&err];
    [self setMessage:ok ? @"Sent AIME to active clients." :
        [NSString stringWithFormat:@"Send failed: %@", err.localizedDescription]];
}

- (void)exportAimeClicked:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    if (@available(macOS 11.0, *)) {
        panel.allowedContentTypes = @[ AimeUTType() ];
    }
    panel.nameFieldStringValue = @"export.aime";
    panel.title = @"Export Apple Immersive Metadata Envelope";
    [panel beginSheetModalForWindow:self.panel completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || panel.URL == nil) return;
        NSError *err = nil;
        BOOL ok = [[SpliceKitVisionPro shared] exportAimeFileURL:panel.URL error:&err];
        [self setMessage:ok ? [NSString stringWithFormat:@"Exported to %@", panel.URL.path] :
            [NSString stringWithFormat:@"Export failed: %@", err.localizedDescription]];
    }];
}

- (void)cameraFieldCommitted:(id)sender {
    NSString *val = self.cameraField.stringValue;
    [[SpliceKitVisionPro shared] setCurrentCameraId:val.length ? val : nil];
    [self setMessage:val.length ? [NSString stringWithFormat:@"Current camera → %@", val]
                                : @"Current camera cleared."];
}

#pragma mark - Refresh

- (void)stateDidChange:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{ [self refreshFromModel]; });
}

- (void)refreshFromModel {
    if (!self.panel) return;

    SpliceKitVisionPro *vp = [SpliceKitVisionPro shared];
    NSDictionary *state = [vp stateSnapshot];

    BOOL ivtAvailable = [state[@"ivtAvailable"] boolValue];
    BOOL running = [state[@"isRunning"] boolValue];
    BOOL streaming = [state[@"isStreaming"] boolValue];

    NSString *statusText;
    NSColor *statusColor;
    if (!ivtAvailable) {
        statusText = @"⚠️ ImmersiveVideoToolbox not installed — install Apple Immersive Video Utility.";
        statusColor = [NSColor systemOrangeColor];
    } else if (!running) {
        statusText = @"Ready. Press Start Discovery to look for Vision Pro devices.";
        statusColor = [NSColor secondaryLabelColor];
    } else if (streaming) {
        NSUInteger n = [state[@"activeClients"] count];
        statusText = [NSString stringWithFormat:@"● Streaming to %lu headset%@", (unsigned long)n, n == 1 ? @"" : @"s"];
        statusColor = [NSColor systemGreenColor];
    } else {
        NSUInteger n = [state[@"availableClients"] count];
        statusText = [NSString stringWithFormat:@"Discovering… %lu device%@ found", (unsigned long)n, n == 1 ? @"" : @"s"];
        statusColor = [NSColor labelColor];
    }
    self.statusLabel.stringValue = statusText;
    self.statusLabel.textColor = statusColor;

    self.startStopButton.title = running ? @"Stop Discovery" : @"Start Discovery";
    [self.startStopButton setEnabled:ivtAvailable];

    self.availableClients = state[@"availableClients"] ?: @[];
    self.activeClients = state[@"activeClients"] ?: @[];
    [self.availableTable reloadData];
    [self.activeTable reloadData];

    NSString *camId = state[@"currentCameraId"];
    if ([camId isKindOfClass:[NSString class]] && ![self.cameraField.stringValue isEqualToString:camId]) {
        if (!self.cameraField.currentEditor) self.cameraField.stringValue = camId;
    }
    if (self.loadedAimePath.length) self.aimeLabel.stringValue = self.loadedAimePath;

    NSString *lastError = state[@"lastError"];
    if ([lastError isKindOfClass:[NSString class]] && lastError.length) {
        self.messageLabel.stringValue = lastError;
        self.messageLabel.textColor = [NSColor systemRedColor];
    }
}

- (void)setMessage:(NSString *)msg {
    self.messageLabel.textColor = [NSColor secondaryLabelColor];
    self.messageLabel.stringValue = msg ?: @"";
}

#pragma mark - Window delegate

- (BOOL)windowShouldClose:(NSWindow *)sender {
    // Don't tear down the session when closing the panel — user might still be
    // streaming from an MCP call or another SpliceKit feature.
    return YES;
}

@end
