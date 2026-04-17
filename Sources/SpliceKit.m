//
//  SpliceKit.m
//  Main entry point — this is where everything starts.
//
//  The __attribute__((constructor)) at the bottom fires before FCP's main() runs.
//  From there we: set up logging, patch out crash-prone code paths (CloudContent,
//  shutdown hang), and wait for the app to finish launching. Once it does, we
//  install our menu, toolbar buttons, feature swizzles, and spin up the server.
//

#import "SpliceKit.h"
#import "SpliceKitLua.h"
#import "SpliceKitPlugins.h"
#import "SpliceKitCommandPalette.h"
#import "SpliceKitDebugUI.h"
#import "SpliceKitSentry.h"
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Security/Security.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <math.h>
#import <signal.h>
#import <execinfo.h>
#import <time.h>
#import <setjmp.h>
#import <pthread.h>

extern NSDictionary *SpliceKit_handleTimelineAction(NSDictionary *params);
extern NSDictionary *SpliceKit_handleFCPXMLExport(NSDictionary *params);
extern NSDictionary *SpliceKit_handleFCPXMLImport(NSDictionary *params);
extern NSDictionary *SpliceKit_handleProjectOpen(NSDictionary *params);
extern void SpliceKit_installMixerSkimHooks(void);
extern void SpliceKit_installBRAWProviderShim(void);
extern void SpliceKit_bootstrapBRAWAtLaunchPhase(NSString *phase);

#pragma mark - Logging
//
// We log to both NSLog (shows up in Console.app) and a file on disk.
// The file is invaluable for debugging crashes that happened while you
// weren't looking at Console — just `cat ~/Library/Logs/SpliceKit/splicekit.log`.
//

static NSString *sLogPath = nil;
static NSFileHandle *sLogHandle = nil;
static dispatch_queue_t sLogQueue = nil;

static NSString *SpliceKit_logTimestamp(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);

    struct tm localTime;
    localtime_r(&ts.tv_sec, &localTime);

    char buffer[32];
    strftime(buffer, sizeof(buffer), "%H:%M:%S", &localTime);
    return [NSString stringWithFormat:@"%s.%03ld", buffer, ts.tv_nsec / 1000000L];
}

static void SpliceKit_initLogging(void) {
    sLogQueue = dispatch_queue_create("com.splicekit.log", DISPATCH_QUEUE_SERIAL);

    NSString *logDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit"];
    [[NSFileManager defaultManager] createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:nil];
    sLogPath = [logDir stringByAppendingPathComponent:@"splicekit.log"];

    // Rotate: keep the previous launch's log so crash-on-startup is diagnosable.
    // splicekit.log -> splicekit.previous.log (overwrite), then start fresh.
    NSString *prevPath = [logDir stringByAppendingPathComponent:@"splicekit.previous.log"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:prevPath error:nil];
    [fm moveItemAtPath:sLogPath toPath:prevPath error:nil];

    [fm createFileAtPath:sLogPath contents:nil attributes:nil];
    sLogHandle = [NSFileHandle fileHandleForWritingAtPath:sLogPath];
    [sLogHandle seekToEndOfFile];
}

void SpliceKit_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    BOOL includeThreadInfo = [[NSUserDefaults standardUserDefaults] boolForKey:@"LogThread"];
    NSString *threadLabel = @"";
    if (includeThreadInfo) {
        NSThread *thread = [NSThread currentThread];
        NSString *name = thread.isMainThread ? @"main" : thread.name;
        if (name.length == 0) {
            name = [NSString stringWithFormat:@"%p", thread];
        }
        threadLabel = [NSString stringWithFormat:@"[%@] ", name];
    }

    NSString *consolePrefix = threadLabel.length
        ? [NSString stringWithFormat:@"[SpliceKit] %@", threadLabel]
        : @"[SpliceKit] ";
    NSLog(@"%@%@", consolePrefix, message);

    // Append to log file on a serial queue so we don't block the caller
    if (sLogHandle && sLogQueue) {
        NSString *timestamp = SpliceKit_logTimestamp();
        NSString *line = [NSString stringWithFormat:@"[%@] [SpliceKit] %@%@\n",
                          timestamp, threadLabel, message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        dispatch_async(sLogQueue, ^{
            [sLogHandle writeData:data];
            [sLogHandle synchronizeFile];
        });
    }

    SpliceKit_sentryAddBreadcrumb(@"splicekit.log", message, nil);
}

#pragma mark - Startup Diagnostics
//
// Track swizzle results, capture crashes, and collect system info so that
// user bug reports include everything we need to diagnose remotely.
//

// Swizzle result tracker — records every swizzle attempt and outcome so
// bridge_status can report exactly which patches are active.
static NSMutableDictionary *sSwizzleResults = nil;

static void SpliceKit_trackSwizzle(NSString *name, BOOL success) {
    if (!sSwizzleResults) {
        sSwizzleResults = [NSMutableDictionary new];
    }
    sSwizzleResults[name] = @(success);
}

NSDictionary *SpliceKit_getSwizzleResults(void) {
    return sSwizzleResults ? [sSwizzleResults copy] : @{};
}

static NSString *SpliceKit_swizzleStateDescription(NSString *name) {
    NSNumber *value = sSwizzleResults[name];
    if (!value) return @"unset";
    return value.boolValue ? @"YES" : @"NO";
}

static void SpliceKit_logCloudContentGuardSummary(NSString *phase) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL firstLaunchDone = [defaults boolForKey:@"CloudContentFirstLaunchCompleted"];
    BOOL cloudContentDisabled = [defaults boolForKey:@"FFCloudContentDisabled"];
    SpliceKit_log(@"CloudContent guard (%@): firstLaunch=%@ disabled=%@ featureFlag=%@ catalog=%@ helper=%@ helperCompletion=%@",
                  phase,
                  firstLaunchDone ? @"YES" : @"NO",
                  cloudContentDisabled ? @"YES" : @"NO",
                  SpliceKit_swizzleStateDescription(@"CloudContentFeatureFlag.isEnabled"),
                  SpliceKit_swizzleStateDescription(@"CloudContentCatalog.updateCatalogAndRegistry"),
                  SpliceKit_swizzleStateDescription(@"CloudContentFirstLaunchHelper.setupAndPresent"),
                  SpliceKit_swizzleStateDescription(@"CloudContentFirstLaunchHelper.setupAndPresent(completion:)"));
}

// Global uncaught exception handler — logs the exception and full stack trace
// to the log file BEFORE the process terminates. Apple's crash reporter doesn't
// capture our log, so this is the last chance to write diagnostic info.
static NSUncaughtExceptionHandler *sPreviousExceptionHandler = nil;

static void SpliceKit_uncaughtExceptionHandler(NSException *exception) {
    SpliceKit_log(@"!!! UNCAUGHT EXCEPTION !!!");
    SpliceKit_log(@"Name: %@", exception.name);
    SpliceKit_log(@"Reason: %@", exception.reason);
    NSArray *symbols = [exception callStackSymbols];
    for (NSString *frame in symbols) {
        SpliceKit_log(@"  %@", frame);
    }
    SpliceKit_log(@"UserInfo: %@", exception.userInfo);

    // Flush log synchronously so it hits disk before we die
    if (sLogHandle) {
        [sLogHandle synchronizeFile];
    }

    // Forward to previous handler if one was installed
    if (sPreviousExceptionHandler) {
        sPreviousExceptionHandler(exception);
    }
}

// Signal handler for fatal signals — captures stack trace to log file.
// Handles SIGTRAP (CloudKit entitlement crashes), SIGABRT, SIGSEGV, SIGBUS.
static void SpliceKit_signalHandler(int sig) {
    const char *sigName = "UNKNOWN";
    switch (sig) {
        case SIGTRAP:  sigName = "SIGTRAP";  break;
        case SIGABRT:  sigName = "SIGABRT";  break;
        case SIGSEGV:  sigName = "SIGSEGV";  break;
        case SIGBUS:   sigName = "SIGBUS";   break;
    }

    // Can't use SpliceKit_log (not async-signal-safe), write directly.
    if (sLogHandle) {
        void *frames[64];
        int count = backtrace(frames, 64);
        char **symbols = backtrace_symbols(frames, count);

        char header[256];
        snprintf(header, sizeof(header),
                 "\n!!! FATAL SIGNAL: %s (signal %d) !!!\nStack trace:\n", sigName, sig);
        write([sLogHandle fileDescriptor], header, strlen(header));

        if (symbols) {
            for (int i = 0; i < count; i++) {
                write([sLogHandle fileDescriptor], "  ", 2);
                write([sLogHandle fileDescriptor], symbols[i], strlen(symbols[i]));
                write([sLogHandle fileDescriptor], "\n", 1);
            }
            free(symbols);
        }
        fsync([sLogHandle fileDescriptor]);
    }

    // Re-raise with default handler so macOS crash reporter also gets it
    signal(sig, SIG_DFL);
    raise(sig);
}

static void SpliceKit_installCrashHandlers(void) {
    sPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(SpliceKit_uncaughtExceptionHandler);

    signal(SIGTRAP, SpliceKit_signalHandler);
    signal(SIGABRT, SpliceKit_signalHandler);
    signal(SIGSEGV, SpliceKit_signalHandler);
    signal(SIGBUS,  SpliceKit_signalHandler);
}

// Dump applied entitlements — critical for diagnosing signing issues
static void SpliceKit_logEntitlements(void) {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) {
        SpliceKit_log(@"Entitlements: could not create SecTask");
        return;
    }

    // Check the specific entitlements we care about
    struct { const char *key; const char *label; } checks[] = {
        {"com.apple.security.app-sandbox",                        "sandbox"},
        {"com.apple.security.cs.disable-library-validation",      "no-lib-val"},
        {"com.apple.security.cs.allow-dyld-environment-variables","dyld-env"},
        {"com.apple.security.get-task-allow",                     "task-allow"},
        {"com.apple.developer.icloud-services",                   "icloud"},
    };

    NSMutableArray *parts = [NSMutableArray new];
    for (int i = 0; i < 5; i++) {
        CFTypeRef val = SecTaskCopyValueForEntitlement(
            task, (__bridge CFStringRef)@(checks[i].key), NULL);
        if (val) {
            [parts addObject:[NSString stringWithFormat:@"%s=%@",
                              checks[i].label, (__bridge id)val]];
            CFRelease(val);
        }
    }
    CFRelease(task);

    if (parts.count > 0) {
        SpliceKit_log(@"Entitlements: %@", [parts componentsJoinedByString:@", "]);
    } else {
        SpliceKit_log(@"Entitlements: none detected (unsigned or missing)");
    }
}

// Log all loaded Mach-O images from FCP's app bundle (not system frameworks)
// to identify which FCP frameworks are present — useful for version differences.
static void SpliceKit_logLoadedFrameworks(void) {
    uint32_t count = _dyld_image_count();
    NSString *appPath = [[NSBundle mainBundle] bundlePath];
    NSMutableArray *fcpFrameworks = [NSMutableArray new];

    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = @(name);
        if ([path hasPrefix:appPath] && [path containsString:@".framework"]) {
            // Extract framework name from path
            NSString *fw = [[path lastPathComponent] stringByDeletingPathExtension];
            if (!fw) fw = [path lastPathComponent];
            [fcpFrameworks addObject:fw];
        }
    }

    [fcpFrameworks sortUsingSelector:@selector(compare:)];
    SpliceKit_log(@"FCP frameworks loaded (%lu): %@",
                  (unsigned long)fcpFrameworks.count,
                  [fcpFrameworks componentsJoinedByString:@", "]);
}

// Measure and log startup timing for each phase
static CFAbsoluteTime sConstructorStart = 0;
static CFAbsoluteTime sWillLaunchTime = 0;
static CFAbsoluteTime sDidLaunchTime = 0;
static CFAbsoluteTime sServerReadyTime = 0;

void SpliceKit_markServerReady(void) {
    sServerReadyTime = CFAbsoluteTimeGetCurrent();
    SpliceKit_sentrySetLaunchPhase(@"server-ready");
    double total = sServerReadyTime - sConstructorStart;
    double toLaunch = sDidLaunchTime - sConstructorStart;
    double toServer = sServerReadyTime - sDidLaunchTime;
    SpliceKit_log(@"Startup timing: constructor->launch=%.2fs, launch->server=%.2fs, total=%.2fs",
                  toLaunch, toServer, total);
}

#pragma mark - Socket Path
//
// FCP runs in a partial sandbox. Our entitlements grant read-write to "/",
// so /tmp usually works. But on some setups it doesn't — the sandbox silently
// denies the write. We probe for it and fall back to the app's cache dir.
//

static char sSocketPath[1024] = {0};

const char *SpliceKit_getSocketPath(void) {
    if (sSocketPath[0] != '\0') return sSocketPath;

    NSString *path = @"/tmp/splicekit.sock";

    // Quick write test to see if the sandbox lets us use /tmp
    NSString *testPath = @"/tmp/splicekit_test";
    BOOL canWrite = [[NSFileManager defaultManager] createFileAtPath:testPath
                                                            contents:[@"test" dataUsingEncoding:NSUTF8StringEncoding]
                                                          attributes:nil];
    if (canWrite) {
        [[NSFileManager defaultManager] removeItemAtPath:testPath error:nil];
    } else {
        // /tmp blocked — use the container instead
        NSString *cacheDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/SpliceKit"];
        [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];
        path = [cacheDir stringByAppendingPathComponent:@"splicekit.sock"];
        SpliceKit_log(@"Using fallback socket path: %@", path);
    }

    strncpy(sSocketPath, [path UTF8String], sizeof(sSocketPath) - 1);
    return sSocketPath;
}

#pragma mark - Cached Class References
//
// We look these up once and stash them globally. Most of these come from Flexo.framework
// (FCP's core editing engine). If Apple renames them in a future version, the compatibility
// check below will tell us exactly which ones are missing.
//

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

// Runs after FCP finishes loading all its frameworks.
// Looks up each critical class by name and caches the reference.
// If something's missing, we log it but keep going — partial functionality
// is better than no functionality.
static void SpliceKit_checkCompatibility(void) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = info[@"CFBundleShortVersionString"];
    NSString *build = info[@"CFBundleVersion"];
    SpliceKit_log(@"FCP version %@ (build %@)", version, build);

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
            // Log the method count as a quick sanity check — if it's wildly
            // different from what we expect, the class might have been gutted
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
//
// We add our own top-level "SpliceKit" menu to FCP's menu bar, right before Help.
// It has entries for the transcript editor, command palette, and a submenu of
// toggleable options (effect drag, pinch zoom, etc).
//

@interface SpliceKitMenuController : NSObject <NSMenuDelegate>
+ (instancetype)shared;
- (void)toggleTranscriptPanel:(id)sender;
- (void)toggleCaptionPanel:(id)sender;
- (void)toggleSections:(id)sender;
- (void)toggleCommandPalette:(id)sender;
- (void)toggleLuaPanel:(id)sender;
- (void)runLuaScript:(id)sender;
- (void)openLuaScriptsFolder:(id)sender;
- (void)toggleEffectDragAsAdjustmentClip:(id)sender;
- (void)toggleViewerPinchZoom:(id)sender;
- (void)toggleVideoOnlyKeepsAudioDisabled:(id)sender;
- (void)toggleSuppressAutoImport:(id)sender;
- (void)editLLadder:(id)sender;
- (void)editJLadder:(id)sender;
- (void)setDefaultConformFit:(id)sender;
- (void)setDefaultConformFill:(id)sender;
- (void)setDefaultConformNone:(id)sender;
- (void)openSecondaryTimeline:(id)sender;
- (void)syncSecondaryTimelineRoot:(id)sender;
- (void)openSelectedInSecondaryTimeline:(id)sender;
- (void)focusPrimaryTimeline:(id)sender;
- (void)focusSecondaryTimeline:(id)sender;
- (void)closeSecondaryTimeline:(id)sender;
- (void)toggleSecondaryBrowser:(id)sender;
- (void)toggleSecondaryTimelineIndex:(id)sender;
- (void)toggleSecondaryAudioMeters:(id)sender;
- (void)toggleSecondaryEffectsBrowser:(id)sender;
- (void)toggleSecondaryTransitionsBrowser:(id)sender;
- (void)toggleMixerPanel:(id)sender;
- (void)toggleMuteAudio:(id)sender;
- (void)exportOTIO:(id)sender;
- (void)importOTIO:(id)sender;
@property (nonatomic, weak) NSButton *toolbarButton;
@property (nonatomic, weak) NSButton *paletteToolbarButton;
@property (nonatomic, strong) NSMenu *luaScriptsMenu;
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

- (void)toggleCaptionPanel:(id)sender {
    Class panelClass = objc_getClass("SpliceKitCaptionPanel");
    if (!panelClass) {
        SpliceKit_log(@"SpliceKitCaptionPanel class not found");
        return;
    }
    id panel = ((id (*)(id, SEL))objc_msgSend)((id)panelClass, @selector(sharedPanel));
    BOOL visible = ((BOOL (*)(id, SEL))objc_msgSend)(panel, @selector(isVisible));
    if (visible) {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(hidePanel));
    } else {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(showPanel));
    }
}

- (void)toggleMixerPanel:(id)sender {
    Class panelClass = objc_getClass("SpliceKitMixerPanel");
    if (!panelClass) {
        SpliceKit_log(@"SpliceKitMixerPanel class not found");
        return;
    }
    id panel = ((id (*)(id, SEL))objc_msgSend)((id)panelClass, @selector(sharedPanel));
    BOOL visible = ((BOOL (*)(id, SEL))objc_msgSend)(panel, @selector(isVisible));
    if (visible) {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(hidePanel));
    } else {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(showPanel));
    }
}

- (void)toggleCommandPalette:(id)sender {
    [[SpliceKitCommandPalette sharedPalette] togglePalette];
}

- (void)toggleLuaPanel:(id)sender {
    Class panelClass = objc_getClass("SpliceKitLuaPanel");
    if (!panelClass) {
        SpliceKit_log(@"SpliceKitLuaPanel class not found");
        return;
    }
    id panel = ((id (*)(id, SEL))objc_msgSend)((id)panelClass, @selector(sharedPanel));
    BOOL visible = ((BOOL (*)(id, SEL))objc_msgSend)(panel, @selector(isVisible));
    if (visible) {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(hidePanel));
    } else {
        ((void (*)(id, SEL))objc_msgSend)(panel, @selector(showPanel));
    }
}

- (void)toggleSections:(id)sender {
    // Toggle the sections bar. If it's visible, hide it. If hidden, show it
    // (loading saved sections from the current project if available).
    NSDictionary *state = SpliceKit_handleSectionsGet(@{});
    BOOL installed = [state[@"installed"] boolValue];
    if (installed) {
        SpliceKit_handleSectionsHide(@{});
    } else {
        SpliceKit_handleSectionsShow(@{});
    }
}

- (void)toggleMuteAudio:(id)sender {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SpliceKit_handleTimelineAction(@{@"action": @"toggleMuteAudio"});
    });
}

#pragma mark - OpenTimelineIO Native Conversion

// ---- OTIO → FCPXML helpers ----

static NSString *otio_esc(id value) {
    if (!value || value == (id)kCFNull) return @"";
    NSString *str = [value isKindOfClass:[NSString class]] ? value : [value description];
    NSMutableString *s = [str mutableCopy];
    [s replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, s.length)];
    return s;
}

static long long otio_gcd(long long a, long long b) {
    a = llabs(a); b = llabs(b);
    while (b) { long long t = b; b = a % b; a = t; }
    return a ?: 1;
}

/// Convert OTIO RationalTime dict {value, rate} to FCPXML time string (e.g. "385385/24000s").
/// Uses canonical SMPTE timebases to keep frame-exact alignment.
static NSString *otio_time(NSDictionary *rt) {
    if (!rt) return @"0s";
    double val = [rt[@"value"] doubleValue];
    double rate = [rt[@"rate"] doubleValue];
    if (rate <= 0 || val == 0) return @"0s";

    // Map known SMPTE rates to canonical numerator multiplier and denominator.
    // OTIO stores frame counts at the clip rate. FCPXML needs rational seconds
    // aligned to the sequence timebase so every time lands on a frame boundary.
    // For 23.976fps: value * 1001 / 24000 = exact seconds
    //
    // IMPORTANT: Do NOT GCD-simplify for known rates. FCP requires the canonical
    // denominator (e.g. 24000) — simplified fractions like 1001/800 (= 30030/24000)
    // cause "unexpected value" errors even though they're mathematically equal.
    long long frameVal = (long long)round(val);
    long long num, den;
    BOOL canonical = NO;

    if (fabs(rate - 24000.0/1001.0) < 0.01) {       // 23.976
        num = frameVal * 1001; den = 24000; canonical = YES;
    } else if (fabs(rate - 24.0) < 0.01) {
        num = frameVal * 100;  den = 2400;  canonical = YES;
    } else if (fabs(rate - 25.0) < 0.01) {
        num = frameVal * 100;  den = 2500;  canonical = YES;
    } else if (fabs(rate - 30000.0/1001.0) < 0.01) { // 29.97
        num = frameVal * 1001; den = 30000; canonical = YES;
    } else if (fabs(rate - 30.0) < 0.01) {
        num = frameVal * 100;  den = 3000;  canonical = YES;
    } else if (fabs(rate - 50.0) < 0.01) {
        num = frameVal * 100;  den = 5000;  canonical = YES;
    } else if (fabs(rate - 60000.0/1001.0) < 0.01) { // 59.94
        num = frameVal * 1001; den = 60000; canonical = YES;
    } else if (fabs(rate - 60.0) < 0.01) {
        num = frameVal * 100;  den = 6000;  canonical = YES;
    } else {
        // Unknown rate — GCD-simplify
        num = (long long)round(val * 1000.0);
        den = (long long)round(rate * 1000.0);
    }

    if (!canonical) {
        long long g = otio_gcd(num, den);
        num /= g; den /= g;
    }
    if (num == 0) return @"0s";
    if (den == 1) return [NSString stringWithFormat:@"%llds", num];
    return [NSString stringWithFormat:@"%lld/%llds", num, den];
}

/// Convert OTIO RationalTime to seconds.
static double otio_sec(NSDictionary *rt) {
    if (!rt) return 0;
    double val = [rt[@"value"] doubleValue];
    double rate = [rt[@"rate"] doubleValue];
    return (rate > 0) ? val / rate : 0;
}

/// Get the media reference from an OTIO Clip dict.
static NSDictionary *otio_mediaRef(NSDictionary *clip) {
    NSDictionary *refs = clip[@"media_references"];
    NSString *key = clip[@"active_media_reference_key"] ?: @"DEFAULT_MEDIA";
    NSDictionary *ref = refs[key];
    if (!ref) ref = clip[@"media_reference"];
    return ref;
}

/// Check if a media reference is a usable external file.
static BOOL otio_isExternal(NSDictionary *ref) {
    NSString *schema = ref[@"OTIO_SCHEMA"] ?: @"";
    return [schema hasPrefix:@"ExternalReference."] && ref[@"target_url"] != nil;
}

/// Normalize OTIO media references to valid FCPXML URLs.
/// Some producers write absolute POSIX paths into target_url even though FCPXML
/// expects URL strings. FCP can silently drop clips when these are not encoded.
static NSString *otio_mediaSrcURL(NSString *targetURL) {
    if (!targetURL || targetURL.length == 0) return @"";
    if ([targetURL containsString:@"://"]) return targetURL;
    if ([targetURL hasPrefix:@"/"]) {
        return [NSURL fileURLWithPath:targetURL].absoluteString;
    }
    return targetURL;
}

/// Compute clip source start relative to asset start=0.
/// Returns the in-point in seconds for the start= attribute.
static double otio_sourceStart(NSDictionary *clip) {
    NSDictionary *sr = clip[@"source_range"];
    NSDictionary *ref = otio_mediaRef(clip);
    double srStart = otio_sec(sr[@"start_time"]);
    if (ref && ref[@"available_range"]) {
        double arStart = otio_sec(ref[@"available_range"][@"start_time"]);
        return srStart - arStart;
    }
    // No available_range → use 0 (safer than absolute Premiere timecodes)
    if (!otio_isExternal(ref)) return 0;
    return srStart;
}

/// Return FCPXML-specific metadata using either the modern upstream key ("fcpx")
/// or the older contrib adapter namespace ("fcpx_xml").
static NSDictionary *otio_fcpxMeta(NSDictionary *obj) {
    NSDictionary *metadata = [obj[@"metadata"] isKindOfClass:[NSDictionary class]] ? obj[@"metadata"] : @{};
    NSDictionary *fcpx = [metadata[@"fcpx"] isKindOfClass:[NSDictionary class]] ? metadata[@"fcpx"] : nil;
    if (fcpx) return fcpx;
    NSDictionary *fcpxXml = [metadata[@"fcpx_xml"] isKindOfClass:[NSDictionary class]] ? metadata[@"fcpx_xml"] : nil;
    return fcpxXml ?: @{};
}

static NSDictionary *otio_dict(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSArray *otio_array(id value) {
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static NSString *otio_string(id value) {
    if (!value || value == (id)kCFNull) return nil;
    return [value isKindOfClass:[NSString class]] ? value : [value description];
}

/// Read values from both SpliceKit's older flat metadata and PR #7's
/// structured metadata shape, e.g. fcpx.asset.attrs.uid or fcpx.effect.resource.uid.
static id otio_fcpxNestedValue(NSDictionary *meta, NSString *section, NSString *key) {
    id flat = meta[key];
    if (flat) return flat;
    NSDictionary *sectionDict = otio_dict(meta[section]);
    id sectionValue = sectionDict[key];
    if (sectionValue) return sectionValue;
    NSDictionary *attrs = otio_dict(sectionDict[@"attrs"]);
    id attrValue = attrs[key];
    if (attrValue) return attrValue;
    NSDictionary *resource = otio_dict(sectionDict[@"resource"]);
    return resource[key];
}

static NSString *otio_fcpxAssetValue(NSDictionary *meta, NSString *key) {
    return otio_string(otio_fcpxNestedValue(meta, @"asset", key));
}

static NSArray *otio_fcpxAssetMediaReps(NSDictionary *meta) {
    NSArray *mediaReps = otio_array(meta[@"media_reps"]);
    if (mediaReps) return mediaReps;
    NSDictionary *asset = otio_dict(meta[@"asset"]);
    return otio_array(asset[@"media_reps"]) ?: @[];
}

static NSString *otio_fcpxEffectRef(NSDictionary *meta) {
    return otio_string(
        meta[@"ref"] ?:
        otio_dict(meta[@"attrs"])[@"ref"] ?:
        otio_dict(meta[@"resource"])[@"id"] ?:
        otio_fcpxNestedValue(meta, @"effect", @"ref")
    );
}

static NSString *otio_fcpxEffectUID(NSDictionary *meta) {
    return otio_string(
        meta[@"uid"] ?:
        otio_dict(meta[@"resource"])[@"uid"] ?:
        otio_fcpxNestedValue(meta, @"effect", @"uid")
    );
}

static NSString *otio_fcpxEffectName(NSDictionary *effect, NSDictionary *meta) {
    return otio_string(
        effect[@"effect_name"] ?:
        effect[@"name"] ?:
        meta[@"name"] ?:
        otio_dict(meta[@"resource"])[@"name"] ?:
        otio_fcpxNestedValue(meta, @"effect", @"name")
    ) ?: @"";
}

static NSString *otio_fcpxEffectElement(NSDictionary *meta) {
    return otio_string(meta[@"element"] ?: meta[@"type"] ?: otio_fcpxNestedValue(meta, @"effect", @"element"));
}

static id otio_fcpxEffectParams(NSDictionary *meta) {
    return meta[@"params"] ?: otio_fcpxNestedValue(meta, @"effect", @"params");
}

static void otio_appendParams(NSMutableString *xml, id params, NSString *indent) {
    if ([params isKindOfClass:[NSDictionary class]]) {
        for (NSString *pName in (NSDictionary *)params) {
            [xml appendFormat:@"%@<param name=\"%@\" value=\"%@\"/>",
                indent, otio_esc(pName), otio_esc([(NSDictionary *)params objectForKey:pName])];
        }
        return;
    }

    if (![params isKindOfClass:[NSArray class]]) return;
    for (NSDictionary *param in (NSArray *)params) {
        if (![param isKindOfClass:[NSDictionary class]]) continue;
        NSMutableString *attrs = [NSMutableString string];
        for (NSString *key in param) {
            id val = param[key];
            if (!val || val == (id)kCFNull) continue;
            [attrs appendFormat:@" %@=\"%@\"", key, otio_esc(val)];
        }
        if (attrs.length > 0) {
            [xml appendFormat:@"%@<param%@/>", indent, attrs];
        }
    }
}

/// Return GeneratorReference parameters if present.
static NSDictionary *otio_generatorParams(NSDictionary *ref) {
    NSDictionary *params = [ref[@"parameters"] isKindOfClass:[NSDictionary class]] ? ref[@"parameters"] : nil;
    return params ?: @{};
}

/// Identify generator references that should roundtrip as FCP titles.
static BOOL otio_isTitleGenerator(NSDictionary *ref) {
    NSString *schema = ref[@"OTIO_SCHEMA"] ?: @"";
    if (![schema hasPrefix:@"GeneratorReference."]) return NO;

    NSString *kind = ref[@"generator_kind"] ?: @"";
    if ([kind isEqualToString:@"Title"] ||
        [kind isEqualToString:@"title"] ||
        [kind isEqualToString:@"fcpx.title"]) {
        return YES;
    }

    NSDictionary *params = otio_generatorParams(ref);
    return params[@"text_xml"] != nil || params[@"text_style_def_xml"] != nil;
}

// ---- Main converter ----

/// Extract text from Premiere-style GeneratorReference clips.
/// Premiere stores title text as base64-encoded AE binary blobs.
static NSString *otio_extractPremiereText(NSDictionary *clip) {
    NSArray *effects = clip[@"effects"] ?: @[];
    for (NSDictionary *effect in effects) {
        NSDictionary *ppro = effect[@"metadata"][@"PremierePro_OTIO"] ?: @{};
        if (![ppro[@"MatchName"] isEqualToString:@"AE.ADBE Text"]) continue;
        for (NSDictionary *param in ppro[@"Parameters"] ?: @[]) {
            if (![param[@"DisplayName"] isEqualToString:@"Source Text"]) continue;
            id val = param[@"StartValue"];
            if ([val isKindOfClass:[NSDictionary class]]) val = val[@"Value"];
            if (![val isKindOfClass:[NSString class]]) continue;
            NSData *decoded = [[NSData alloc] initWithBase64EncodedString:(NSString *)val options:0];
            if (!decoded || decoded.length == 0) continue;
            // Scan for ASCII text fragments — the longest meaningful one is the title text
            const uint8_t *bytes = decoded.bytes;
            NSUInteger len = decoded.length;
            NSMutableArray *fragments = [NSMutableArray array];
            NSUInteger i = 0;
            while (i < len) {
                if (bytes[i] >= 0x20 && bytes[i] < 0x7f) {
                    NSUInteger start = i;
                    while (i < len && bytes[i] >= 0x20 && bytes[i] < 0x7f) i++;
                    NSString *seg = [[NSString alloc] initWithBytes:bytes + start
                                                             length:i - start
                                                           encoding:NSASCIIStringEncoding];
                    if (seg && seg.length >= 2) {
                        // Filter out known font names and binary metadata
                        NSArray *skipPrefixes = @[@"Adobe", @"Myriad", @"Mini", @"Kozuka",
                                                  @"Source", @"Times", @"Arial", @"Helvet"];
                        BOOL skip = NO;
                        for (NSString *prefix in skipPrefixes) {
                            if ([seg hasPrefix:prefix]) { skip = YES; break; }
                        }
                        if (!skip) [fragments addObject:seg];
                    }
                } else {
                    i++;
                }
            }
            // Return the last meaningful fragment (Premiere puts text near the end)
            return fragments.lastObject;
        }
    }
    return nil;
}

/// Build a <title> FCPXML element string from an OTIO GeneratorReference clip.
/// titleEffectRef is the resource ID for the Basic Title effect (e.g. "r4").
static NSString *otio_buildTitleElement(NSDictionary *child, NSDictionary *ref,
                                        NSString *offsetStr, NSString *durationStr,
                                        int *tsCounter, NSString *titleEffectRef) {
    NSDictionary *genMeta = otio_fcpxMeta(ref);
    NSDictionary *params = otio_generatorParams(ref);
    NSString *clipName = otio_esc(child[@"name"] ?: @"Title");

    // Get text content: FCPXML metadata > Premiere extraction > clip name
    NSString *text = genMeta[@"text"] ?: params[@"text"];
    if (!text || text.length == 0) {
        text = otio_extractPremiereText(child);
    }
    if (!text || text.length == 0) {
        text = child[@"name"] ?: @"Title";
    }

    NSMutableString *xml = [NSMutableString string];

    // Build text-style-def and text body
    NSArray *paramXml = [params[@"param_xml"] isKindOfClass:[NSArray class]] ? params[@"param_xml"] : nil;
    NSArray *rawTextXml = [params[@"text_xml"] isKindOfClass:[NSArray class]] ? params[@"text_xml"] : nil;
    NSArray *rawStyleDefs = [params[@"text_style_def_xml"] isKindOfClass:[NSArray class]] ? params[@"text_style_def_xml"] : nil;
    NSArray *textSegments = genMeta[@"text_segments"];
    NSArray *styleDefs = genMeta[@"text_style_defs"];

    NSString *tsId = [NSString stringWithFormat:@"ts%d", (*tsCounter)++];

    // Use round-tripped ref or fall back to Basic Title effect
    NSString *effectRef = genMeta[@"ref"] ?: titleEffectRef;
    [xml appendFormat:@"<title name=\"%@\" ref=\"%@\" offset=\"%@\" duration=\"%@\" start=\"3600s\"",
        clipName, effectRef, offsetStr, durationStr];

    // Add role if present
    NSString *role = genMeta[@"role"] ?: params[@"role"];
    if (role) [xml appendFormat:@" role=\"%@\"", otio_esc(role)];
    [xml appendString:@">\n"];

    // Motion/title parameters must precede text blocks.
    if (paramXml && paramXml.count > 0) {
        for (NSString *raw in paramXml) {
            if (![raw isKindOfClass:[NSString class]] || raw.length == 0) continue;
            [xml appendFormat:@"                            %@\n", raw];
        }
    }

    // Text content
    if (rawTextXml && rawTextXml.count > 0) {
        for (NSString *raw in rawTextXml) {
            if (![raw isKindOfClass:[NSString class]] || raw.length == 0) continue;
            [xml appendFormat:@"                            %@\n", raw];
        }
    } else if (textSegments && [textSegments isKindOfClass:[NSArray class]] && textSegments.count > 0) {
        [xml appendString:@"                            <text>"];
        for (NSDictionary *seg in textSegments) {
            NSString *segRef = seg[@"ref"] ?: @"";
            NSString *segText = seg[@"text"] ?: @"";
            [xml appendFormat:@"<text-style ref=\"%@\">%@</text-style>",
                otio_esc(segRef), otio_esc(segText)];
        }
        [xml appendString:@"</text>\n"];
    } else {
        [xml appendFormat:@"                            <text><text-style ref=\"%@\">%@</text-style></text>\n",
            tsId, otio_esc(text)];
    }

    // Text style definitions
    if (rawStyleDefs && rawStyleDefs.count > 0) {
        for (NSString *raw in rawStyleDefs) {
            if (![raw isKindOfClass:[NSString class]] || raw.length == 0) continue;
            [xml appendFormat:@"                            %@\n", raw];
        }
    } else if (styleDefs && [styleDefs isKindOfClass:[NSArray class]] && styleDefs.count > 0) {
        for (NSDictionary *sd in styleDefs) {
            NSString *sdId = sd[@"id"] ?: tsId;
            NSDictionary *attrs = sd[@"attrs"] ?: @{};
            NSMutableString *attrStr = [NSMutableString string];
            for (NSString *key in attrs) {
                [attrStr appendFormat:@" %@=\"%@\"", key, otio_esc(attrs[key])];
            }
            [xml appendFormat:@"                            <text-style-def id=\"%@\">"
                @"<text-style%@/></text-style-def>\n", otio_esc(sdId), attrStr];
        }
    } else {
        // Default style — matches FCP's own Basic Title output
        [xml appendFormat:@"                            <text-style-def id=\"%@\">"
            @"<text-style font=\"Helvetica\" fontSize=\"63\" fontFace=\"Regular\" fontColor=\"1 1 1 1\" alignment=\"center\"/>"
            @"</text-style-def>\n", tsId];
    }

    // Restore adjust-transform if present
    NSDictionary *adjTransform = genMeta[@"adjust_transform"];
    if (adjTransform && [adjTransform isKindOfClass:[NSDictionary class]]) {
        NSMutableString *attrStr = [NSMutableString string];
        for (NSString *key in adjTransform) {
            [attrStr appendFormat:@" %@=\"%@\"", key, otio_esc(adjTransform[key])];
        }
        [xml appendFormat:@"                            <adjust-transform%@/>\n", attrStr];
    }

    [xml appendString:@"                        </title>"];
    return xml;
}

/// Parse a .otio JSON file and convert to FCPXML 1.14 string.
/// Handles multi-track, transitions, titles, markers, source trimming, connected clips.
NSString *SpliceKit_otioToFCPXML(NSString *otioPath) {
    NSData *data = [NSData dataWithContentsOfFile:otioPath];
    if (!data) { SpliceKit_log(@"[OTIO] Could not read: %@", otioPath); return nil; }

    NSError *jsonErr = nil;
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
    if (!root || jsonErr) { SpliceKit_log(@"[OTIO] JSON error: %@", jsonErr); return nil; }
    if (![root[@"OTIO_SCHEMA"] hasPrefix:@"Timeline."]) { SpliceKit_log(@"[OTIO] Not a Timeline"); return nil; }

    NSString *projectName = root[@"name"] ?: @"";
    if (![projectName isKindOfClass:[NSString class]] || projectName.length == 0) {
        projectName = otioPath.lastPathComponent.stringByDeletingPathExtension ?: @"Imported";
    }
    NSArray *tracks = root[@"tracks"][@"children"] ?: @[];

    // Resolution from metadata (Premiere stores it in PremierePro_OTIO)
    NSDictionary *stackMeta = root[@"tracks"][@"metadata"] ?: @{};
    NSDictionary *pMeta = stackMeta[@"PremierePro_OTIO"] ?: @{};
    int width = [pMeta[@"VideoResolution"][@"width"] intValue] ?: 1920;
    int height = [pMeta[@"VideoResolution"][@"height"] intValue] ?: 1080;

    // Separate video/audio tracks
    NSMutableArray *videoTracks = [NSMutableArray array];
    NSMutableArray *audioTracks = [NSMutableArray array];
    for (NSDictionary *t in tracks) {
        if ([t[@"kind"] isEqualToString:@"Audio"]) [audioTracks addObject:t];
        else [videoTracks addObject:t];
    }

    // Detect fps from first video clip
    double fps = 24.0;
    for (NSDictionary *t in videoTracks) {
        for (NSDictionary *c in t[@"children"] ?: @[]) {
            double r = [c[@"source_range"][@"duration"][@"rate"] doubleValue];
            if (r > 1) { fps = r; goto found; }
        }
    }
    found:;

    // FCP format name + frame duration
    NSString *fmtName, *frameDur;
    struct { double lo, hi; const char *name; const char *dur; } fmts[] = {
        {23.9, 24.0, "2398", "1001/24000s"}, {24.0, 24.1, "24", "100/2400s"},
        {24.9, 25.1, "25", "100/2500s"}, {29.9, 30.0, "2997", "1001/30000s"},
        {30.0, 30.1, "30", "100/3000s"}, {49.9, 50.1, "50", "100/5000s"},
        {59.9, 60.0, "5994", "1001/60000s"}, {60.0, 60.1, "60", "100/6000s"},
    };
    fmtName = [NSString stringWithFormat:@"FFVideoFormat%dp%d", height, (int)round(fps)];
    frameDur = [NSString stringWithFormat:@"100/%ds", (int)round(fps * 100)];
    for (int i = 0; i < 8; i++) {
        if (fps >= fmts[i].lo && fps < fmts[i].hi) {
            fmtName = [NSString stringWithFormat:@"FFVideoFormat%dp%s", height, fmts[i].name];
            frameDur = @(fmts[i].dur);
            break;
        }
    }

    // ---- Effect resources ----
    // Standard FCP effect IDs (stable across all installations).
    // r2 = Cross Dissolve, r3 = Audio Crossfade, r4 = Basic Title
    NSString *crossDissolveEffectId = @"r2";
    NSString *audioCrossfadeEffectId = @"r3";
    NSString *basicTitleEffectId = @"r4";

    // ---- Collect unique assets ----
    NSMutableDictionary *assets = [NSMutableDictionary dictionary]; // targetUrl → assetId
    NSMutableString *assetXml = [NSMutableString string];
    NSMutableDictionary *effectRefs = [NSMutableDictionary dictionary]; // effectRef → effectId
    NSMutableString *effectXml = [NSMutableString string];
    int resCounter = 5; // r1=format, r2=cross dissolve, r3=audio crossfade, r4=basic title

    for (NSDictionary *t in tracks) {
        for (NSDictionary *c in t[@"children"] ?: @[]) {
            if (![c[@"OTIO_SCHEMA"] hasPrefix:@"Clip."]) continue;
            NSDictionary *ref = otio_mediaRef(c);
            if (!otio_isExternal(ref)) continue;
            NSString *url = ref[@"target_url"];
            if (assets[url]) continue;

            NSString *aid = [NSString stringWithFormat:@"r%d", resCounter++];
            assets[url] = aid;

            // Duration from available_range or source_range
            NSDictionary *durRT = ref[@"available_range"] ? ref[@"available_range"][@"duration"] : c[@"source_range"][@"duration"];
            NSString *durStr = otio_time(durRT);

            // hasVideo/hasAudio: check track kind
            NSString *kind = t[@"kind"] ?: @"Video";
            BOOL isVideo = [kind isEqualToString:@"Video"];

            // Preserve asset metadata from FCPXML round-trip (uid, audioChannels, etc.)
            NSDictionary *refMeta = otio_fcpxMeta(ref);
            NSMutableString *assetAttrs = [NSMutableString stringWithFormat:
                @"        <asset name=\"%@\" format=\"r1\" id=\"%@\" duration=\"%@\" start=\"0s\" hasVideo=\"%d\" hasAudio=\"1\"",
                otio_esc(c[@"name"] ?: @"Clip"), aid, durStr, isVideo ? 1 : 0];
            // Optional metadata attributes
            for (NSString *metaKey in @[@"uid", @"audioSources", @"audioChannels",
                                        @"audioRate", @"videoSources"]) {
                id val = otio_fcpxAssetValue(refMeta, metaKey);
                if (val) [assetAttrs appendFormat:@" %@=\"%@\"", metaKey, val];
            }
            [assetAttrs appendString:@">\n"];
            [assetXml appendString:assetAttrs];

            // Preserve media-rep attributes from FCPXML adapter PR #7 metadata.
            // Fall back to target_url when the OTIO came from another producer.
            NSString *uidVal = otio_fcpxAssetValue(refMeta, @"uid");
            NSString *srcURL = otio_mediaSrcURL(url);
            NSDictionary *mediaRep = nil;
            for (NSDictionary *rep in otio_fcpxAssetMediaReps(refMeta)) {
                if (![rep isKindOfClass:[NSDictionary class]]) continue;
                if (!mediaRep || [rep[@"kind"] isEqualToString:@"original-media"]) {
                    mediaRep = rep;
                }
                if ([rep[@"kind"] isEqualToString:@"original-media"]) break;
            }
            if (mediaRep) {
                NSMutableString *repAttrs = [NSMutableString string];
                NSMutableSet *seenRepKeys = [NSMutableSet set];
                for (NSString *key in mediaRep) {
                    id val = mediaRep[key];
                    if (!val || val == (id)kCFNull) continue;
                    [seenRepKeys addObject:key];
                    [repAttrs appendFormat:@" %@=\"%@\"", key, otio_esc(val)];
                }
                if (![seenRepKeys containsObject:@"src"]) {
                    [repAttrs appendFormat:@" src=\"%@\"", otio_esc(srcURL)];
                }
                if (uidVal.length > 0 && ![seenRepKeys containsObject:@"sig"]) {
                    [repAttrs appendFormat:@" sig=\"%@\"", otio_esc(uidVal)];
                }
                [assetXml appendFormat:@"            <media-rep%@/>\n        </asset>\n", repAttrs];
            } else if (uidVal && uidVal.length > 0) {
                [assetXml appendFormat:
                    @"            <media-rep kind=\"original-media\" sig=\"%@\" src=\"%@\"/>\n"
                    @"        </asset>\n", otio_esc(uidVal), otio_esc(srcURL)];
            } else {
                [assetXml appendFormat:
                    @"            <media-rep kind=\"original-media\" src=\"%@\"/>\n"
                    @"        </asset>\n", otio_esc(srcURL)];
            }

            // Collect effect resources from clip effects
            for (NSDictionary *eff in c[@"effects"] ?: @[]) {
                NSDictionary *fcpxMeta = otio_fcpxMeta(eff);
                NSString *eRef = otio_fcpxEffectRef(fcpxMeta);
                NSString *eName = otio_fcpxEffectName(eff, fcpxMeta);
                // Skip adjust-* (not effect resources) and empty refs
                if (!eRef || eRef.length == 0) continue;
                if ([eName hasPrefix:@"adjust-"]) continue;
                if (effectRefs[eRef]) continue;
                NSString *eid = [NSString stringWithFormat:@"r%d", resCounter++];
                effectRefs[eRef] = eid;
                NSString *uid = otio_fcpxEffectUID(fcpxMeta) ?: @"";
                if (uid.length > 0) {
                    [effectXml appendFormat:
                        @"        <effect id=\"%@\" name=\"%@\" uid=\"%@\"/>\n",
                        eid, otio_esc(eName), otio_esc(uid)];
                } else {
                    [effectXml appendFormat:
                        @"        <effect id=\"%@\" name=\"%@\"/>\n",
                        eid, otio_esc(eName)];
                }
            }
        }
    }

    // ---- Build spine items array from primary video track ----
    // Accumulate frame counts (not seconds) to preserve frame-exact alignment.
    NSDictionary *primaryTrack = videoTracks.firstObject;
    NSMutableArray *spineItems = [NSMutableArray array];

    // Helper: build an offset RationalTime dict from accumulated frames
    // Uses the primary track's rate for all offsets so they align to the sequence timebase.
    double (^frameVal)(NSDictionary *) = ^double(NSDictionary *rt) {
        return rt ? [rt[@"value"] doubleValue] : 0;
    };
    double (^frameRate)(NSDictionary *) = ^double(NSDictionary *rt) {
        double r = rt ? [rt[@"rate"] doubleValue] : 0;
        return r > 0 ? r : fps;
    };

    double runFrames = 0; // accumulated offset in frames at primary track rate

    // Pre-scan: for each clip, determine how many frames are eaten by
    // adjacent transitions (in_offset from following transition, out_offset from preceding).
    NSArray *primaryChildren = primaryTrack[@"children"] ?: @[];
    NSInteger pCount = primaryChildren.count;

    for (NSInteger ci = 0; ci < pCount; ci++) {
        NSDictionary *child = primaryChildren[ci];
        NSString *schema = child[@"OTIO_SCHEMA"] ?: @"";
        NSDictionary *srDur = child[@"source_range"][@"duration"];
        double durFrames = frameVal(srDur);
        double rate = frameRate(srDur);
        double durSec = (rate > 0) ? durFrames / rate : 0;

        // All time strings use the clip's native RationalTime directly
        // (no seconds→frames round-trip). For offsets, build from accumulated frames.
        NSDictionary *offRT = @{@"value": @(runFrames), @"rate": @(rate)};

        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"timelineStartSec"] = @(runFrames / rate);
        item[@"timelineDurSec"] = @(durSec);
        item[@"rate"] = @(rate);
        item[@"childXml"] = [NSMutableString string];

        if ([schema hasPrefix:@"Transition."]) {
            NSDictionary *inRT = child[@"in_offset"];
            NSDictionary *outRT = child[@"out_offset"];
            double inFrames = frameVal(inRT);
            double outFrames = frameVal(outRT);
            double totalFrames = inFrames + outFrames;
            double tRate = frameRate(inRT);
            NSDictionary *durRT = @{@"value": @(totalFrames), @"rate": @(tRate)};
            NSDictionary *transOffRT = @{@"value": @(runFrames - inFrames), @"rate": @(tRate)};

            item[@"type"] = @"transition";
            if (inFrames == 0 && outFrames > 0) {
                // Fade-in from black (no effect reference needed)
                item[@"openTag"] = [NSString stringWithFormat:
                    @"<transition offset=\"%@\" duration=\"%@\">\n"
                    @"                        <filter-video ref=\"%@\" enabled=\"0\"/>\n"
                    @"                    </transition>",
                    otio_time(transOffRT), otio_time(durRT), crossDissolveEffectId];
            } else if (inFrames > 0 && outFrames == 0) {
                // Fade-out to black
                item[@"openTag"] = [NSString stringWithFormat:
                    @"<transition offset=\"%@\" duration=\"%@\">\n"
                    @"                        <filter-video ref=\"%@\" enabled=\"0\"/>\n"
                    @"                    </transition>",
                    otio_time(transOffRT), otio_time(durRT), crossDissolveEffectId];
            } else {
                // Cross dissolve — needs effect references
                item[@"openTag"] = [NSString stringWithFormat:
                    @"<transition name=\"Cross Dissolve\" offset=\"%@\" duration=\"%@\">\n"
                    @"                        <filter-video ref=\"%@\" name=\"Cross Dissolve\"/>\n"
                    @"                        <filter-audio ref=\"%@\" name=\"Audio Crossfade\"/>\n"
                    @"                    </transition>",
                    otio_time(transOffRT), otio_time(durRT),
                    crossDissolveEffectId, audioCrossfadeEffectId];
            }
            // Transitions overlap — do NOT advance runFrames
        } else if ([schema hasPrefix:@"Gap."]) {
            item[@"type"] = @"gap";
            item[@"sourceStartSec"] = @(3600.0);
            item[@"openTag"] = [NSString stringWithFormat:
                @"<gap name=\"Gap\" offset=\"%@\" duration=\"%@\" start=\"3600s\">",
                otio_time(offRT), otio_time(srDur)];
            runFrames += durFrames;
        } else if ([schema hasPrefix:@"Clip."]) {
            NSDictionary *ref = otio_mediaRef(child);
            NSString *refSchema = ref[@"OTIO_SCHEMA"] ?: @"";
            if (otio_isTitleGenerator(ref)) {
                // Title generator clip — build <title> element
                static int tsCounter = 1;
                NSString *titleXml = otio_buildTitleElement(child, ref,
                    otio_time(offRT), otio_time(srDur), &tsCounter, basicTitleEffectId);
                item[@"type"] = @"title";
                item[@"sourceStartSec"] = @(3600.0);
                item[@"openTag"] = titleXml;
                runFrames += durFrames;
                goto clipDone;
            } else if ([refSchema hasPrefix:@"GeneratorReference."]) {
                // Non-title generators do not map cleanly to FCPXML in this path.
                item[@"type"] = @"gap";
                item[@"sourceStartSec"] = @(3600.0);
                item[@"openTag"] = [NSString stringWithFormat:
                    @"<gap name=\"%@\" offset=\"%@\" duration=\"%@\" start=\"3600s\">",
                    otio_esc(child[@"name"] ?: @"Gap"), otio_time(offRT), otio_time(srDur)];
            } else if (!otio_isExternal(ref)) {
                item[@"type"] = @"gap";
                item[@"sourceStartSec"] = @(3600.0);
                item[@"openTag"] = [NSString stringWithFormat:
                    @"<gap name=\"%@\" offset=\"%@\" duration=\"%@\" start=\"3600s\">",
                    otio_esc(child[@"name"] ?: @"Gap"), otio_time(offRT), otio_time(srDur)];
            } else {
                NSString *aid = assets[ref[@"target_url"]] ?: @"r2";
                double srcStartSec = otio_sourceStart(child);
                double srcStartFrames = round(srcStartSec * rate);
                BOOL enabled = child[@"enabled"] == nil || [child[@"enabled"] boolValue];

                // Check for adjacent transitions that eat into this clip's duration.
                // A preceding transition's out_offset eats from this clip's start.
                // A following transition's in_offset eats from this clip's end.
                double eatFromStart = 0; // frames eaten from start by preceding transition
                double eatFromEnd = 0;   // frames eaten from end by following transition
                if (ci > 0) {
                    NSDictionary *prev = primaryChildren[ci - 1];
                    if ([prev[@"OTIO_SCHEMA"] hasPrefix:@"Transition."]) {
                        double outOff = frameVal(prev[@"out_offset"]);
                        if (outOff > 0 && frameVal(prev[@"in_offset"]) > 0) {
                            eatFromStart = outOff; // cross-dissolve eats from our start
                        }
                    }
                }
                if (ci + 1 < pCount) {
                    NSDictionary *next = primaryChildren[ci + 1];
                    if ([next[@"OTIO_SCHEMA"] hasPrefix:@"Transition."]) {
                        double inOff = frameVal(next[@"in_offset"]);
                        if (inOff > 0 && frameVal(next[@"out_offset"]) > 0) {
                            eatFromEnd = inOff; // cross-dissolve eats from our end
                        }
                    }
                }

                // Adjusted duration and source start for transition overlap
                double adjDurFrames = durFrames - eatFromStart - eatFromEnd;
                double adjSrcStartFrames = srcStartFrames + eatFromStart;
                NSDictionary *adjDurRT = @{@"value": @(adjDurFrames), @"rate": @(rate)};
                NSDictionary *adjSrcStartRT = @{@"value": @(adjSrcStartFrames), @"rate": @(rate)};

                // Use <clip> with nested <video> (not <asset-clip>) for spine items.
                // <asset-clip> has a restricted DTD that doesn't allow markers,
                // filter-video, filter-audio, or connected clips as children.
                NSMutableString *tag = [NSMutableString stringWithFormat:
                    @"<clip name=\"%@\" offset=\"%@\" duration=\"%@\" start=\"%@\" format=\"r1\"",
                    otio_esc(child[@"name"] ?: @"Clip"),
                    otio_time(offRT), otio_time(adjDurRT), otio_time(adjSrcStartRT)];
                if (!enabled) [tag appendString:@" enabled=\"0\""];
                [tag appendString:@">"];

                item[@"type"] = @"clip";
                item[@"sourceStartSec"] = @(srcStartSec);
                item[@"assetUrl"] = ref[@"target_url"] ?: @"";
                item[@"openTag"] = tag;

                NSMutableString *cx = item[@"childXml"];

                // DTD requires strict ordering inside <clip>:
                //   1. adjust-* elements (conform, transform, blend, etc.)
                //   2. adjust-volume, adjust-panner
                //   3. timeMap / frame-sampling
                //   4. <video> (with filter-video/filter-audio as children)
                //   5. markers, then connected clips/titles (added later by secondary track loop)

                // Phase 1: adjust-* elements (before timeMap/video)
                NSMutableString *filterXml = [NSMutableString string]; // filters go inside <video>
                NSMutableString *timeMapXml = [NSMutableString string];
                for (NSDictionary *eff in child[@"effects"] ?: @[]) {
                    NSDictionary *fcpxMeta = otio_fcpxMeta(eff);
                    NSString *eName = otio_fcpxEffectName(eff, fcpxMeta);
                    NSString *fcpxElement = otio_fcpxEffectElement(fcpxMeta);
                    NSString *eSchema = eff[@"OTIO_SCHEMA"] ?: @"";

                    if ([eName hasPrefix:@"adjust-"]) {
                        // Adjust elements go directly on <clip>
                        NSMutableString *attrStr = [NSMutableString string];
                        NSDictionary *attrs = otio_dict(fcpxMeta[@"attrs"]) ?: fcpxMeta;
                        for (NSString *key in attrs) {
                            if ([key isEqualToString:@"params"]) continue;
                            if ([key isEqualToString:@"element"]) continue;
                            if ([key isEqualToString:@"resource"]) continue;
                            id val = attrs[key];
                            if ([val isKindOfClass:[NSString class]]) {
                                [attrStr appendFormat:@" %@=\"%@\"", key, otio_esc(val)];
                            }
                        }
                        [cx appendFormat:@"\n                        <%@%@", eName, attrStr];
                        id params = otio_fcpxEffectParams(fcpxMeta);
                        BOOL hasParams = ([params isKindOfClass:[NSDictionary class]] && [(NSDictionary *)params count] > 0) ||
                                         ([params isKindOfClass:[NSArray class]] && [(NSArray *)params count] > 0);
                        if (hasParams) {
                            [cx appendString:@">"];
                            otio_appendParams(cx, params, @"\n                            ");
                            [cx appendFormat:@"\n                        </%@>", eName];
                        } else {
                            [cx appendString:@"/>"];
                        }
                    } else if (fcpxMeta[@"time_map"]) {
                        id rawTimeMap = fcpxMeta[@"time_map"];
                        NSArray *rawEntries = [rawTimeMap isKindOfClass:[NSArray class]] ? rawTimeMap : nil;
                        if ([rawTimeMap isKindOfClass:[NSString class]]) rawEntries = @[rawTimeMap];
                        for (NSString *raw in rawEntries ?: @[]) {
                            if (![raw isKindOfClass:[NSString class]] || raw.length == 0) continue;
                            [timeMapXml appendFormat:@"\n                        %@", raw];
                        }
                    } else if ([eSchema hasPrefix:@"FreezeFrame."]) {
                        [timeMapXml appendFormat:
                            @"\n                        <timeMap>"
                            @"\n                            <timept time=\"0s\" value=\"0s\" interp=\"linear\"/>"
                            @"\n                            <timept time=\"%@\" value=\"0s\" interp=\"linear\"/>"
                            @"\n                        </timeMap>",
                            otio_time(adjDurRT)];
                    } else if ([eSchema hasPrefix:@"LinearTimeWarp."]) {
                        double timeScalar = [eff[@"time_scalar"] doubleValue];
                        if (timeScalar != 0.0 && timeScalar != 1.0) {
                            NSDictionary *mappedEndRT = @{
                                @"value": @(llround((double)adjDurFrames * fabs(timeScalar))),
                                @"rate": adjDurRT[@"rate"] ?: @1
                            };
                            NSString *startValue = timeScalar < 0.0 ? otio_time(mappedEndRT) : @"0s";
                            NSString *endValue = timeScalar < 0.0 ? @"0s" : otio_time(mappedEndRT);
                            [timeMapXml appendFormat:
                                @"\n                        <timeMap>"
                                @"\n                            <timept time=\"0s\" value=\"%@\" interp=\"linear\"/>"
                                @"\n                            <timept time=\"%@\" value=\"%@\" interp=\"linear\"/>"
                                @"\n                        </timeMap>",
                                startValue, otio_time(adjDurRT), endValue];
                        }
                    } else if ([fcpxElement isEqualToString:@"filter-audio"] ||
                               [fcpxMeta[@"type"] isEqualToString:@"audio"]) {
                        // filter-audio goes inside <video> — skip if no valid ref
                        NSString *eRef = otio_fcpxEffectRef(fcpxMeta) ?: @"";
                        if (eRef.length == 0) continue;
                        NSString *mappedRef = effectRefs[eRef] ?: eRef;
                        [filterXml appendFormat:
                            @"\n                            <filter-audio name=\"%@\" ref=\"%@\"/>",
                            otio_esc(eName), mappedRef];
                    } else if (eName.length > 0) {
                        // filter-video goes inside <video> — skip if no valid ref
                        NSString *eRef = otio_fcpxEffectRef(fcpxMeta) ?: @"";
                        if (eRef.length == 0) continue;
                        NSString *mappedRef = effectRefs[eRef] ?: eRef;
                        [filterXml appendFormat:
                            @"\n                            <filter-video name=\"%@\" ref=\"%@\"",
                            otio_esc(eName), mappedRef];
                        id params = otio_fcpxEffectParams(fcpxMeta);
                        BOOL hasParams = ([params isKindOfClass:[NSDictionary class]] && [(NSDictionary *)params count] > 0) ||
                                         ([params isKindOfClass:[NSArray class]] && [(NSArray *)params count] > 0);
                        if (hasParams) {
                            [filterXml appendString:@">"];
                            otio_appendParams(filterXml, params, @"\n                                ");
                            [filterXml appendString:@"\n                            </filter-video>"];
                        } else {
                            [filterXml appendString:@"/>"];
                        }
                    }
                }

                // Phase 2: retime metadata before <video>
                if (timeMapXml.length > 0) {
                    [cx appendString:timeMapXml];
                }

                // Phase 3: <video> child with filters nested inside
                if (filterXml.length > 0) {
                    [cx appendFormat:
                        @"\n                        <video offset=\"%@\" ref=\"%@\" duration=\"%@\">%@"
                        @"\n                        </video>",
                        otio_time(adjSrcStartRT), aid, otio_time(adjDurRT), filterXml];
                } else {
                    [cx appendFormat:
                        @"\n                        <video offset=\"%@\" ref=\"%@\" duration=\"%@\"/>",
                        otio_time(adjSrcStartRT), aid, otio_time(adjDurRT)];
                }

                // Phase 4: Markers (after video, before connected clips)
                for (NSDictionary *m in child[@"markers"] ?: @[]) {
                    NSDictionary *fcpxMeta = otio_fcpxMeta(m);
                    NSString *markerType = fcpxMeta[@"marker_type"] ?: @"marker";
                    NSString *startStr = otio_time(m[@"marked_range"][@"start_time"]);
                    NSString *durStr = otio_time(m[@"marked_range"][@"duration"]);
                    NSString *name = otio_esc(m[@"name"] ?: @"Marker");

                    if ([markerType isEqualToString:@"chapter-marker"]) {
                        NSString *posterOff = fcpxMeta[@"posterOffset"] ?: @"0s";
                        [cx appendFormat:
                            @"\n                        <chapter-marker start=\"%@\" duration=\"%@\" value=\"%@\" posterOffset=\"%@\"/>",
                            startStr, durStr, name, posterOff];
                    } else {
                        NSMutableString *attrs = [NSMutableString stringWithFormat:
                            @"start=\"%@\" duration=\"%@\" value=\"%@\"", startStr, durStr, name];
                        NSString *color = m[@"color"];
                        if ([color isEqualToString:@"RED"]) {
                            [attrs appendString:@" completed=\"0\""];
                        } else if ([color isEqualToString:@"GREEN"]) {
                            [attrs appendString:@" completed=\"1\""];
                        }
                        [cx appendFormat:@"\n                        <%@ %@/>", markerType, attrs];
                    }
                }
                // Phase 5: Connected clips/titles are added later by the secondary track loop

                // Advance by adjusted duration (transitions eat into clip edges)
                runFrames += adjDurFrames;
                goto clipDone;
            }
            runFrames += durFrames; // non-external clips (gaps)
            clipDone:;
        } else {
            // Unknown schema — treat as gap
            runFrames += durFrames;
        }
        [spineItems addObject:item];
    }

    // ---- Attach connected clips from secondary video tracks (lane 1, 2, ...) ----
    for (NSInteger ti = 1; ti < videoTracks.count; ti++) {
        NSDictionary *secTrack = videoTracks[ti];
        int lane = (int)ti;
        double secOff = 0; // in seconds

        for (NSDictionary *child in secTrack[@"children"] ?: @[]) {
            NSString *schema = child[@"OTIO_SCHEMA"] ?: @"";
            double durSec = otio_sec(child[@"source_range"][@"duration"]);
            double clipRate = [child[@"source_range"][@"duration"][@"rate"] doubleValue] ?: fps;

            if ([schema hasPrefix:@"Clip."]) {
                NSDictionary *ref = otio_mediaRef(child);
                NSString *refSchema = ref[@"OTIO_SCHEMA"] ?: @"";

                if (otio_isTitleGenerator(ref)) {
                    // Connected title clip — build <title> with lane attribute
                    for (NSMutableDictionary *si in spineItems) {
                        double siStart = [si[@"timelineStartSec"] doubleValue];
                        double siEnd = siStart + [si[@"timelineDurSec"] doubleValue];
                        if (secOff >= siStart - 0.001 && secOff < siEnd + 0.001) {
                            double relOffSec = [si[@"sourceStartSec"] doubleValue] + (secOff - siStart);
                            double relOffFrames = round(relOffSec * clipRate);
                            NSDictionary *offRT = @{@"value": @(relOffFrames), @"rate": @(clipRate)};
                            NSDictionary *durRT = child[@"source_range"][@"duration"];

                            static int connTsCounter = 100;
                            NSString *titleXml = otio_buildTitleElement(child, ref,
                                otio_time(offRT), otio_time(durRT), &connTsCounter, basicTitleEffectId);
                            // Inject lane attribute into the title opening tag
                            NSString *connTitle = [titleXml stringByReplacingOccurrencesOfString:@" start=\"3600s\""
                                withString:[NSString stringWithFormat:@" lane=\"%d\" start=\"3600s\"", lane]];
                            NSMutableString *cx = si[@"childXml"];
                            [cx appendFormat:@"\n                        %@", connTitle];
                            break;
                        }
                    }
                } else if ([refSchema hasPrefix:@"GeneratorReference."]) {
                    // Ignore non-title generators on secondary lanes for now.
                } else if (otio_isExternal(ref)) {
                    NSString *aid = assets[ref[@"target_url"]] ?: @"r2";
                    double srcStart = otio_sourceStart(child);

                    for (NSMutableDictionary *si in spineItems) {
                        double siStart = [si[@"timelineStartSec"] doubleValue];
                        double siEnd = siStart + [si[@"timelineDurSec"] doubleValue];
                        if (secOff >= siStart - 0.001 && secOff < siEnd + 0.001) {
                            double relOffSec = [si[@"sourceStartSec"] doubleValue] + (secOff - siStart);
                            double relOffFrames = round(relOffSec * clipRate);
                            NSDictionary *offRT = @{@"value": @(relOffFrames), @"rate": @(clipRate)};
                            NSDictionary *srcRT = @{@"value": @(round(srcStart * clipRate)), @"rate": @(clipRate)};

                            NSMutableString *cx = si[@"childXml"];
                            [cx appendFormat:
                                @"\n                        <asset-clip name=\"%@\" ref=\"%@\" lane=\"%d\""
                                @" offset=\"%@\" duration=\"%@\" format=\"r1\"",
                                otio_esc(child[@"name"] ?: @"Clip"), aid, lane,
                                otio_time(offRT), otio_time(child[@"source_range"][@"duration"])];
                            if (srcStart > 0.001) {
                                [cx appendFormat:@" start=\"%@\"", otio_time(srcRT)];
                            }
                            [cx appendString:@"/>"];
                            break;
                        }
                    }
                }
            }
            if (![schema hasPrefix:@"Transition."]) secOff += durSec;
        }
    }

    // ---- Attach connected audio clips (lane -1, -2, ...) ----
    // Match audio to spine items by asset reference (same source media)
    // rather than by timeline position — transitions cause position drift
    // between video and audio tracks.
    for (NSInteger ai = 0; ai < audioTracks.count; ai++) {
        NSDictionary *aTrack = audioTracks[ai];
        int lane = -(int)(ai + 1);

        for (NSDictionary *child in aTrack[@"children"] ?: @[]) {
            NSString *schema = child[@"OTIO_SCHEMA"] ?: @"";
            if (![schema hasPrefix:@"Clip."]) continue;

            NSDictionary *ref = otio_mediaRef(child);
            if (!otio_isExternal(ref)) continue;

            NSString *audioUrl = ref[@"target_url"];
            NSString *aid = assets[audioUrl] ?: @"r2";
            double clipRate = [child[@"source_range"][@"duration"][@"rate"] doubleValue] ?: fps;
            double audioSrcStart = otio_sourceStart(child);

            // Find the spine item that uses the SAME asset (matched by URL)
            for (NSMutableDictionary *si in spineItems) {
                NSString *siAssetUrl = si[@"assetUrl"];
                if (!siAssetUrl || ![siAssetUrl isEqualToString:audioUrl]) continue;

                // Audio offset = same as the parent clip's source start
                double srcStartFrames = round([si[@"sourceStartSec"] doubleValue] * clipRate);
                NSDictionary *offRT = @{@"value": @(srcStartFrames), @"rate": @(clipRate)};

                NSMutableString *cx = si[@"childXml"];
                [cx appendFormat:
                    @"\n                        <audio ref=\"%@\" lane=\"%d\""
                    @" offset=\"%@\" duration=\"%@\" role=\"dialogue\"/>",
                    aid, lane, otio_time(offRT),
                    otio_time(child[@"source_range"][@"duration"])];
                break;
            }
        }
    }

    // ---- Assemble FCPXML ----
    // runFrames is total frames accumulated from the primary track
    double totalRate = fps;
    // Find the rate from the primary track's first clip for consistency
    for (NSDictionary *child in primaryTrack[@"children"] ?: @[]) {
        double r = [child[@"source_range"][@"duration"][@"rate"] doubleValue];
        if (r > 0) { totalRate = r; break; }
    }
    NSDictionary *seqDurRT = @{@"value": @(runFrames), @"rate": @(totalRate)};
    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n"];
    [xml appendFormat:@"<fcpxml version=\"1.14\">\n    <resources>\n"];
    [xml appendFormat:@"        <format id=\"r1\" frameDuration=\"%@\" width=\"%d\" height=\"%d\" name=\"%@\"/>\n",
        frameDur, width, height, fmtName];
    [xml appendFormat:@"        <effect id=\"%@\" name=\"Cross Dissolve\" uid=\"FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265\"/>\n", crossDissolveEffectId];
    [xml appendFormat:@"        <effect id=\"%@\" name=\"Audio Crossfade\" uid=\"FFAudioTransition\"/>\n", audioCrossfadeEffectId];
    [xml appendFormat:@"        <effect id=\"%@\" name=\"Basic Title\" uid=\".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti\"/>\n", basicTitleEffectId];
    [xml appendString:effectXml]; // clip effect resources
    [xml appendString:assetXml];
    [xml appendString:@"    </resources>\n"];
    [xml appendFormat:@"    <event name=\"%@\">\n", otio_esc(projectName)];

    // Asset-clip browser items (so clips appear in FCP's event browser)
    for (NSString *url in assets) {
        NSString *aid = assets[url];
        // Find the clip to get its name and duration
        for (NSDictionary *t in tracks) {
            for (NSDictionary *c in t[@"children"] ?: @[]) {
                NSDictionary *cRef = otio_mediaRef(c);
                if (cRef && [cRef[@"target_url"] isEqualToString:url]) {
                    NSDictionary *durRT = cRef[@"available_range"] ?
                        cRef[@"available_range"][@"duration"] : c[@"source_range"][@"duration"];
                    [xml appendFormat:
                        @"        <asset-clip name=\"%@\" ref=\"%@\" format=\"r1\" duration=\"%@\"/>\n",
                        otio_esc(c[@"name"] ?: @"Clip"), aid, otio_time(durRT)];
                    goto nextAsset;
                }
            }
        }
        nextAsset:;
    }

    [xml appendFormat:@"        <project name=\"%@\">\n", otio_esc(projectName)];
    [xml appendFormat:@"            <sequence format=\"r1\" duration=\"%@\" tcStart=\"0s\" tcFormat=\"NDF\">\n",
        otio_time(seqDurRT)];
    [xml appendString:@"                <spine>\n"];

    for (NSDictionary *si in spineItems) {
        NSString *type = si[@"type"];
        NSString *openTag = si[@"openTag"];
        NSString *childXml = si[@"childXml"];

        if ([type isEqualToString:@"transition"] || [type isEqualToString:@"title"]) {
            // Transitions and titles are self-contained elements (already have closing tags)
            [xml appendFormat:@"                    %@\n", openTag];
        } else {
            BOOL hasChildren = childXml.length > 0;
            if (hasChildren) {
                [xml appendFormat:@"                    %@%@\n", openTag, childXml];
                // Close tag: determine element name from opening tag
                NSString *closeTag = [openTag hasPrefix:@"<asset-clip"] ? @"</asset-clip>" :
                                     [openTag hasPrefix:@"<gap"] ? @"</gap>" : @"</clip>";
                [xml appendFormat:@"                    %@\n", closeTag];
            } else {
                // Self-close
                NSString *selfClose = [openTag stringByReplacingOccurrencesOfString:@">" withString:@"/>"
                    options:NSBackwardsSearch range:NSMakeRange(openTag.length - 1, 1)];
                [xml appendFormat:@"                    %@\n", selfClose];
            }
        }
    }

    [xml appendString:@"                </spine>\n"];
    [xml appendString:@"            </sequence>\n"];
    [xml appendString:@"        </project>\n"];
    [xml appendString:@"    </event>\n"];
    [xml appendString:@"</fcpxml>\n"];

    SpliceKit_log(@"[OTIO] Converted %@ → FCPXML (%lu bytes, %lu spine items, %lu assets)",
        otioPath.lastPathComponent, (unsigned long)xml.length,
        (unsigned long)spineItems.count, (unsigned long)assets.count);
    return xml;
}

#pragma mark - OpenTimelineIO Import / Export

- (void)exportOTIO:(id)sender {
    // Step 1: Export FCPXML from FCP to a temp file
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *tmpFcpxml = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_otio_menu_export.fcpxml"];
        NSDictionary *exportResult = SpliceKit_handleFCPXMLExport(@{@"path": tmpFcpxml});
        if (exportResult[@"error"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Export Failed";
                alert.informativeText = [NSString stringWithFormat:@"Could not export timeline: %@", exportResult[@"error"]];
                alert.alertStyle = NSAlertStyleWarning;
                [alert addButtonWithTitle:@"OK"];
                [alert runModal];
            });
            return;
        }

        // Step 2: Show save panel on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            NSSavePanel *panel = [NSSavePanel savePanel];
            panel.title = @"Export Timeline (OpenTimelineIO)";
            panel.nameFieldStringValue = @"Timeline.otio";
            panel.allowedContentTypes = @[
                [UTType typeWithFilenameExtension:@"otio"],
                [UTType typeWithFilenameExtension:@"otioz"],
                [UTType typeWithFilenameExtension:@"otiod"],
                [UTType typeWithFilenameExtension:@"fcpxml"],
                [UTType typeWithFilenameExtension:@"fcpxmld"],
                [UTType typeWithFilenameExtension:@"edl"],
                [UTType typeWithFilenameExtension:@"aaf"],
            ];
            panel.allowsOtherFileTypes = YES;

            if ([panel runModal] != NSModalResponseOK || !panel.URL) {
                [[NSFileManager defaultManager] removeItemAtPath:tmpFcpxml error:nil];
                return;
            }

            NSString *outPath = panel.URL.path;
            NSString *ext = outPath.pathExtension.lowercaseString;

            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSFileManager *fm = [NSFileManager defaultManager];

                if ([ext isEqualToString:@"fcpxml"] || [ext isEqualToString:@"fcpxmld"]) {
                    NSError *fileErr = nil;
                    [fm removeItemAtPath:outPath error:nil];

                    if ([ext isEqualToString:@"fcpxml"]) {
                        [fm copyItemAtPath:tmpFcpxml toPath:outPath error:&fileErr];
                    } else {
                        NSString *infoPath = [outPath stringByAppendingPathComponent:@"Info.fcpxml"];
                        [fm createDirectoryAtPath:outPath withIntermediateDirectories:YES attributes:nil error:&fileErr];
                        if (!fileErr) {
                            [fm copyItemAtPath:tmpFcpxml toPath:infoPath error:&fileErr];
                        }
                    }

                    [fm removeItemAtPath:tmpFcpxml error:nil];

                    if (fileErr) {
                        SpliceKit_log(@"[OTIO] Export error: %@", fileErr.localizedDescription);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            NSAlert *alert = [[NSAlert alloc] init];
                            alert.messageText = @"Export Failed";
                            alert.informativeText = fileErr.localizedDescription ?: @"Could not write the exported file.";
                            alert.alertStyle = NSAlertStyleWarning;
                            [alert addButtonWithTitle:@"OK"];
                            [alert runModal];
                        });
                    } else {
                        SpliceKit_log(@"[OTIO] Exported to %@ (%@)", outPath, ext.uppercaseString);
                    }
                    return;
                }

                // Step 3: Convert FCPXML → target format using Python/OTIO
                NSString *pyScript =
                    @"import sys\n"
                    @"import opentimelineio as otio\n"
                    @"\n"
                    @"def pick_fcpx_adapter():\n"
                    @"    preferred = ('fcpxml', 'fcpx_xml')\n"
                    @"    try:\n"
                    @"        available = set(otio.adapters.available_adapter_names())\n"
                    @"    except Exception:\n"
                    @"        available = set()\n"
                    @"    for name in preferred:\n"
                    @"        if name in available:\n"
                    @"            return name\n"
                    @"    return preferred[0]\n"
                    @"\n"
                    @"src_path, dst_path = sys.argv[1:3]\n"
                    @"with open(src_path, 'r', encoding='utf-8') as fh:\n"
                    @"    result = otio.adapters.read_from_string(fh.read(), pick_fcpx_adapter())\n"
                    @"timeline = result\n"
                    @"if hasattr(result, '__iter__') and not isinstance(result, otio.schema.Timeline):\n"
                    @"    for item in result:\n"
                    @"        if isinstance(item, otio.schema.Timeline):\n"
                    @"            timeline = item\n"
                    @"            break\n"
                    @"otio.adapters.write_to_file(timeline, dst_path)\n"
                    @"print('OK')\n";

                NSTask *task = [[NSTask alloc] init];
                task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
                task.arguments = @[@"python3", @"-c", pyScript, tmpFcpxml, outPath];
                NSPipe *outPipe = [NSPipe pipe];
                NSPipe *errPipe = [NSPipe pipe];
                task.standardOutput = outPipe;
                task.standardError = errPipe;

                NSError *err = nil;
                [task launchAndReturnError:&err];
                if (err) {
                    SpliceKit_log(@"[OTIO] Export launch error: %@", err);
                    [[NSFileManager defaultManager] removeItemAtPath:tmpFcpxml error:nil];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSAlert *alert = [[NSAlert alloc] init];
                        alert.messageText = @"Export Failed";
                        alert.informativeText = [NSString stringWithFormat:@"Could not launch Python: %@", err.localizedDescription];
                        [alert addButtonWithTitle:@"OK"];
                        [alert runModal];
                    });
                    return;
                }
                [task waitUntilExit];

                NSString *stdoutStr = [[NSString alloc] initWithData:[outPipe.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
                NSString *stderrStr = [[NSString alloc] initWithData:[errPipe.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];

                [[NSFileManager defaultManager] removeItemAtPath:tmpFcpxml error:nil];

                if (task.terminationStatus != 0 || ![stdoutStr containsString:@"OK"]) {
                    SpliceKit_log(@"[OTIO] Export error: %@", stderrStr);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSAlert *alert = [[NSAlert alloc] init];
                        alert.messageText = @"Export Failed";
                        alert.informativeText = stderrStr.length > 0 ? stderrStr : @"Unknown error during OTIO conversion";
                        alert.alertStyle = NSAlertStyleWarning;
                        [alert addButtonWithTitle:@"OK"];
                        [alert runModal];
                    });
                } else {
                    SpliceKit_log(@"[OTIO] Exported to %@ (%@)", outPath, ext.uppercaseString);
                }
            });
        });
    });
}

- (void)importOTIO:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Import Timeline (OpenTimelineIO)";
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"otio"],
        [UTType typeWithFilenameExtension:@"otioz"],
        [UTType typeWithFilenameExtension:@"otiod"],
        [UTType typeWithFilenameExtension:@"edl"],
        [UTType typeWithFilenameExtension:@"aaf"],
        [UTType typeWithFilenameExtension:@"fcpxml"],
        [UTType typeWithFilenameExtension:@"fcpxmld"],
    ];
    panel.allowsOtherFileTypes = YES;
    panel.allowsMultipleSelection = NO;

    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;

    NSString *inPath = panel.URL.path;
    NSString *ext = inPath.pathExtension.lowercaseString;

    // .fcpxml/.fcpxmld files → import directly into the active library.
    if ([ext isEqualToString:@"fcpxml"] || [ext isEqualToString:@"fcpxmld"]) {
        NSString *openPath = inPath;
        if ([ext isEqualToString:@"fcpxmld"]) {
            openPath = [inPath stringByAppendingPathComponent:@"Info.fcpxml"];
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *readErr = nil;
            NSString *fcpxmlStr = [NSString stringWithContentsOfFile:openPath
                                                             encoding:NSUTF8StringEncoding
                                                                error:&readErr];
            if (!fcpxmlStr) {
                SpliceKit_log(@"[OTIO] Import read error: %@", readErr.localizedDescription);
                return;
            }
            NSDictionary *importResult = SpliceKit_handleFCPXMLImport(@{
                @"xml": fcpxmlStr,
                @"internal": @YES
            });
            if (importResult[@"error"]) {
                SpliceKit_log(@"[OTIO] Import error: %@", importResult[@"error"]);
            } else {
                SpliceKit_log(@"[OTIO] Imported %@ from %@", ext.uppercaseString, inPath);
            }
        });
        return;
    }

    // .otio files → native ObjC conversion to FCPXML, then direct import.
    if ([ext isEqualToString:@"otio"]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *fcpxmlStr = SpliceKit_otioToFCPXML(inPath);
            if (!fcpxmlStr) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSAlert *alert = [[NSAlert alloc] init];
                    alert.messageText = @"Import Failed";
                    alert.informativeText = @"Could not convert .otio to FCPXML. Check the log for details.";
                    alert.alertStyle = NSAlertStyleWarning;
                    [alert addButtonWithTitle:@"OK"];
                    [alert runModal];
                });
                return;
            }

            SpliceKit_log(@"[OTIO] Converted %@ → FCPXML (%lu bytes)",
                          inPath.lastPathComponent, (unsigned long)fcpxmlStr.length);
            NSDictionary *importResult = SpliceKit_handleFCPXMLImport(@{
                @"xml": fcpxmlStr,
                @"internal": @YES
            });
            if (importResult[@"error"]) {
                SpliceKit_log(@"[OTIO] Import error: %@", importResult[@"error"]);
            } else {
                SpliceKit_log(@"[OTIO] Imported .otio from %@", inPath);
            }
        });
        return;
    }

    // Other OTIO formats (.otioz/.otiod/.edl/.aaf) → Python/OTIO conversion to FCPXML, then import
    if ([ext isEqualToString:@"otioz"] ||
        [ext isEqualToString:@"otiod"] ||
        [ext isEqualToString:@"edl"] ||
        [ext isEqualToString:@"aaf"]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_otio_import.fcpxml"];
            NSString *pyScript =
                @"import sys\n"
                @"import opentimelineio as otio\n"
                @"\n"
                @"def pick_fcpx_adapter():\n"
                @"    preferred = ('fcpxml', 'fcpx_xml')\n"
                @"    try:\n"
                @"        available = set(otio.adapters.available_adapter_names())\n"
                @"    except Exception:\n"
                @"        available = set()\n"
                @"    for name in preferred:\n"
                @"        if name in available:\n"
                @"            return name\n"
                @"    return preferred[0]\n"
                @"\n"
                @"src_path, dst_path = sys.argv[1:3]\n"
                @"result = otio.adapters.read_from_file(src_path)\n"
                @"timeline = result\n"
                @"if hasattr(result, '__iter__') and not isinstance(result, otio.schema.Timeline):\n"
                @"    for item in result:\n"
                @"        if isinstance(item, otio.schema.Timeline):\n"
                @"            timeline = item\n"
                @"            break\n"
                @"xml = otio.adapters.write_to_string(timeline, pick_fcpx_adapter())\n"
                @"with open(dst_path, 'w', encoding='utf-8') as fh:\n"
                @"    fh.write(xml)\n"
                @"print('OK')\n";

            NSTask *task = [[NSTask alloc] init];
            task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
            task.arguments = @[@"python3", @"-c", pyScript, inPath, tmpPath];
            NSPipe *outPipe = [NSPipe pipe];
            NSPipe *errPipe = [NSPipe pipe];
            task.standardOutput = outPipe;
            task.standardError = errPipe;

            NSError *launchErr = nil;
            [task launchAndReturnError:&launchErr];
            if (launchErr) {
                SpliceKit_log(@"[OTIO] Import launch error: %@", launchErr.localizedDescription);
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSAlert *alert = [[NSAlert alloc] init];
                    alert.messageText = @"Import Failed";
                    alert.informativeText = launchErr.localizedDescription ?: @"Could not launch Python for OTIO import.";
                    alert.alertStyle = NSAlertStyleWarning;
                    [alert addButtonWithTitle:@"OK"];
                    [alert runModal];
                });
                return;
            }

            [task waitUntilExit];
            NSString *stdoutStr = [[NSString alloc] initWithData:[outPipe.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
            NSString *stderrStr = [[NSString alloc] initWithData:[errPipe.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];

            if (task.terminationStatus != 0 || ![stdoutStr containsString:@"OK"]) {
                [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
                SpliceKit_log(@"[OTIO] Import conversion error: %@", stderrStr);
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSAlert *alert = [[NSAlert alloc] init];
                    alert.messageText = @"Import Failed";
                    alert.informativeText = stderrStr.length > 0 ? stderrStr : @"Unknown error during OTIO conversion";
                    alert.alertStyle = NSAlertStyleWarning;
                    [alert addButtonWithTitle:@"OK"];
                    [alert runModal];
                });
                return;
            }

            NSURL *fcpxmlURL = [NSURL fileURLWithPath:tmpPath];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSWorkspace sharedWorkspace] openURLs:@[fcpxmlURL]
                               withApplicationAtURL:[[NSBundle mainBundle] bundleURL]
                                      configuration:[NSWorkspaceOpenConfiguration configuration]
                                  completionHandler:^(NSRunningApplication *app, NSError *openErr) {
                    if (openErr) {
                        SpliceKit_log(@"[OTIO] Import error: %@", openErr.localizedDescription);
                    } else {
                        SpliceKit_log(@"[OTIO] Imported %@ from %@", ext.uppercaseString, inPath);
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                        dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                        [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
                    });
                }];
            });
        });
        return;
    }

    // Unsupported format
    SpliceKit_log(@"[OTIO] Unsupported format: .%@", ext);
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(toggleSections:)) {
        NSDictionary *state = SpliceKit_handleSectionsGet(@{});
        menuItem.state = [state[@"installed"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    return YES;
}

#pragma mark - Lua Scripts Menu

// Run a .lua script when its menu item is clicked.
// The full path is stored in the menu item's representedObject.
- (void)runLuaScript:(id)sender {
    NSMenuItem *item = (NSMenuItem *)sender;
    NSString *path = item.representedObject;
    if (!path) return;

    SpliceKit_log(@"[Lua] Running script: %@", [path lastPathComponent]);

    // Run on a background thread so the menu dismisses immediately
    // and the main thread stays free for SpliceKit_executeOnMainThread callbacks.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = SpliceKitLua_executeFile(path);
        NSString *error = result[@"error"];
        NSString *output = result[@"output"];
        if (error) {
            SpliceKit_log(@"[Lua] Error in %@: %@", [path lastPathComponent], error);
        } else if (output.length > 0) {
            SpliceKit_log(@"[Lua] %@: %@", [path lastPathComponent], output);
        } else {
            SpliceKit_log(@"[Lua] %@ completed", [path lastPathComponent]);
        }
    });
}

// Open the scripts folder in Finder so the user can add/edit scripts.
- (void)openLuaScriptsFolder:(id)sender {
    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *scriptsDir = [appSupport stringByAppendingPathComponent:@"SpliceKit/lua/menu"];
    // Create the directory if it doesn't exist yet
    [[NSFileManager defaultManager] createDirectoryAtPath:scriptsDir
                              withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:scriptsDir]];
}

// NSMenuDelegate — rebuild the Lua Scripts submenu every time it opens.
// This picks up newly added/removed scripts without restarting FCP.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != self.luaScriptsMenu) return;

    [menu removeAllItems];

    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *menuDir = [appSupport stringByAppendingPathComponent:@"SpliceKit/lua/menu"];

    // Create the directory if it doesn't exist
    [[NSFileManager defaultManager] createDirectoryAtPath:menuDir
                              withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];

    // Enumerate .lua files, sorted alphabetically
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:menuDir error:nil];
    NSMutableArray *luaFiles = [NSMutableArray array];
    for (NSString *file in files) {
        if ([file.pathExtension isEqualToString:@"lua"]) {
            [luaFiles addObject:file];
        }
    }
    [luaFiles sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    if (luaFiles.count == 0) {
        NSMenuItem *emptyItem = [[NSMenuItem alloc]
            initWithTitle:@"No scripts — add .lua files to menu/ folder"
                   action:nil
            keyEquivalent:@""];
        emptyItem.enabled = NO;
        [menu addItem:emptyItem];
    } else {
        for (NSString *file in luaFiles) {
            // Display name: strip .lua extension and leading numbers/underscores
            // "01_blade_every_2s.lua" → "blade every 2s"
            NSString *displayName = [file stringByDeletingPathExtension];
            // Strip leading "01_", "02_" etc. for ordering without showing numbers
            NSRegularExpression *regex = [NSRegularExpression
                regularExpressionWithPattern:@"^\\d+[_\\-\\s]+"
                                     options:0 error:nil];
            displayName = [regex stringByReplacingMatchesInString:displayName
                                                         options:0
                                                           range:NSMakeRange(0, displayName.length)
                                                withTemplate:@""];
            // Replace underscores with spaces
            displayName = [displayName stringByReplacingOccurrencesOfString:@"_" withString:@" "];

            NSString *fullPath = [menuDir stringByAppendingPathComponent:file];

            NSMenuItem *item = [[NSMenuItem alloc]
                initWithTitle:displayName
                       action:@selector(runLuaScript:)
                keyEquivalent:@""];
            item.target = [SpliceKitMenuController shared];
            item.representedObject = fullPath;
            item.enabled = YES;

            // Read the first comment line for a tooltip
            NSString *content = [NSString stringWithContentsOfFile:fullPath
                                                         encoding:NSUTF8StringEncoding
                                                            error:nil];
            if (content) {
                // Look for first "-- " comment line
                for (NSString *line in [content componentsSeparatedByString:@"\n"]) {
                    NSString *trimmed = [line stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
                    if ([trimmed hasPrefix:@"-- "] && trimmed.length > 3) {
                        item.toolTip = [trimmed substringFromIndex:3];
                        break;
                    } else if ([trimmed hasPrefix:@"--[["]) {
                        // Multi-line comment — grab the next non-empty line
                        continue;
                    } else if (trimmed.length > 0 && ![trimmed hasPrefix:@"--"]) {
                        break; // hit code, stop looking
                    } else if (trimmed.length > 2 && [trimmed hasPrefix:@"  "]) {
                        // Indented line inside --[[ block — use as tooltip
                        item.toolTip = [trimmed stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
                        break;
                    }
                }
            }

            [menu addItem:item];
        }
    }

    [menu addItem:[NSMenuItem separatorItem]];

    // "Open Scripts Folder" item at the bottom
    NSMenuItem *openFolderItem = [[NSMenuItem alloc]
        initWithTitle:@"Open Scripts Folder..."
               action:@selector(openLuaScriptsFolder:)
        keyEquivalent:@""];
    openFolderItem.target = [SpliceKitMenuController shared];
    openFolderItem.enabled = YES;
    [menu addItem:openFolderItem];
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

- (void)toggleSuppressAutoImport:(id)sender {
    BOOL newState = !SpliceKit_isSuppressAutoImportEnabled();
    SpliceKit_setSuppressAutoImportEnabled(newState);
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        [(NSMenuItem *)sender setState:newState ? NSControlStateValueOn : NSControlStateValueOff];
    }
}

// --- Playback Speed ladder editors ---

static NSString *SpliceKit_ladderToString(NSArray<NSNumber *> *ladder) {
    NSMutableArray *strs = [NSMutableArray array];
    for (NSNumber *n in ladder) {
        float v = [n floatValue];
        if (v == (int)v) [strs addObject:[NSString stringWithFormat:@"%d", (int)v]];
        else [strs addObject:[NSString stringWithFormat:@"%.1f", v]];
    }
    return [strs componentsJoinedByString:@", "];
}

static NSArray<NSNumber *> *SpliceKit_parseLadderString(NSString *str) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *part in [str componentsSeparatedByString:@","]) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length > 0) {
            float val = [trimmed floatValue];
            if (val > 0.0f) [result addObject:@(val)];
        }
    }
    // Sort ascending
    [result sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [a compare:b];
    }];
    return result;
}

- (void)editLLadder:(id)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"L Key Speeds";
        alert.informativeText = @"Each press of L advances to the next speed.\nEnter values separated by commas:";
        [alert addButtonWithTitle:@"Save"];
        [alert addButtonWithTitle:@"Cancel"];
        NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
        input.stringValue = SpliceKit_ladderToString(SpliceKit_getLLadder());
        alert.accessoryView = input;
        [alert.window makeFirstResponder:input];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            NSArray *speeds = SpliceKit_parseLadderString(input.stringValue);
            if (speeds.count > 0) {
                SpliceKit_setLLadder(speeds);
                if ([sender isKindOfClass:[NSMenuItem class]])
                    [(NSMenuItem *)sender setTitle:
                        [NSString stringWithFormat:@"L Speeds: %@", SpliceKit_ladderToString(speeds)]];
            }
        }
    });
}

- (void)editJLadder:(id)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"J Key Speeds";
        alert.informativeText = @"Each press of J advances to the next reverse speed.\nEnter values separated by commas:";
        [alert addButtonWithTitle:@"Save"];
        [alert addButtonWithTitle:@"Cancel"];
        NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
        input.stringValue = SpliceKit_ladderToString(SpliceKit_getJLadder());
        alert.accessoryView = input;
        [alert.window makeFirstResponder:input];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            NSArray *speeds = SpliceKit_parseLadderString(input.stringValue);
            if (speeds.count > 0) {
                SpliceKit_setJLadder(speeds);
                if ([sender isKindOfClass:[NSMenuItem class]])
                    [(NSMenuItem *)sender setTitle:
                        [NSString stringWithFormat:@"J Speeds: %@", SpliceKit_ladderToString(speeds)]];
            }
        }
    });
}

- (void)setDefaultConformFit:(id)sender {
    SpliceKit_setDefaultSpatialConformType(@"fit");
    [self _updateConformMenuFromSender:sender];
}

- (void)setDefaultConformFill:(id)sender {
    SpliceKit_setDefaultSpatialConformType(@"fill");
    [self _updateConformMenuFromSender:sender];
}

- (void)setDefaultConformNone:(id)sender {
    SpliceKit_setDefaultSpatialConformType(@"none");
    [self _updateConformMenuFromSender:sender];
}

- (void)openSecondaryTimeline:(id)sender {
    NSDictionary *result = SpliceKit_dualTimelineOpen(@{});
    if (result[@"error"]) {
        SpliceKit_log(@"[DualTimeline] Open failed: %@", result[@"error"]);
        NSBeep();
    }
}

- (void)syncSecondaryTimelineRoot:(id)sender {
    NSDictionary *result = SpliceKit_dualTimelineSyncRoot(@{});
    if (result[@"error"]) {
        SpliceKit_log(@"[DualTimeline] Sync root failed: %@", result[@"error"]);
        NSBeep();
    }
}

- (void)openSelectedInSecondaryTimeline:(id)sender {
    NSDictionary *result = SpliceKit_dualTimelineOpenSelectedInSecondary(@{});
    if (result[@"error"]) {
        SpliceKit_log(@"[DualTimeline] Open selected failed: %@", result[@"error"]);
        NSBeep();
    }
}

- (void)focusPrimaryTimeline:(id)sender {
    NSDictionary *result = SpliceKit_dualTimelineFocus(@{@"pane": @"primary"});
    if (result[@"error"]) {
        SpliceKit_log(@"[DualTimeline] Focus primary failed: %@", result[@"error"]);
        NSBeep();
    }
}

- (void)focusSecondaryTimeline:(id)sender {
    NSDictionary *result = SpliceKit_dualTimelineFocus(@{@"pane": @"secondary"});
    if (result[@"error"]) {
        SpliceKit_log(@"[DualTimeline] Focus secondary failed: %@", result[@"error"]);
        NSBeep();
    }
}

- (void)closeSecondaryTimeline:(id)sender {
    NSDictionary *result = SpliceKit_dualTimelineClose(@{});
    if (result[@"error"]) {
        SpliceKit_log(@"[DualTimeline] Close failed: %@", result[@"error"]);
        NSBeep();
    }
}

- (void)_toggleSecondaryPanelNamed:(NSString *)panel {
    NSDictionary *result = SpliceKit_dualTimelineTogglePanel(@{
        @"pane": @"secondary",
        @"panel": panel ?: @"",
    });
    if (result[@"error"]) {
        SpliceKit_log(@"[DualTimeline] Toggle %@ failed: %@", panel ?: @"panel", result[@"error"]);
        NSBeep();
    }
}

- (void)toggleSecondaryBrowser:(id)sender {
    [self _toggleSecondaryPanelNamed:@"browser"];
}

- (void)toggleSecondaryTimelineIndex:(id)sender {
    [self _toggleSecondaryPanelNamed:@"timelineIndex"];
}

- (void)toggleSecondaryAudioMeters:(id)sender {
    [self _toggleSecondaryPanelNamed:@"audioMeters"];
}

- (void)toggleSecondaryEffectsBrowser:(id)sender {
    [self _toggleSecondaryPanelNamed:@"effectsBrowser"];
}

- (void)toggleSecondaryTransitionsBrowser:(id)sender {
    [self _toggleSecondaryPanelNamed:@"transitionsBrowser"];
}

- (void)_updateConformMenuFromSender:(id)sender {
    if (![sender isKindOfClass:[NSMenuItem class]]) return;
    NSMenu *menu = [(NSMenuItem *)sender menu];
    if (!menu) return;
    NSString *current = SpliceKit_getDefaultSpatialConformType();
    for (NSMenuItem *item in menu.itemArray) {
        NSString *tag = nil;
        if (item.action == @selector(setDefaultConformFit:)) tag = @"fit";
        else if (item.action == @selector(setDefaultConformFill:)) tag = @"fill";
        else if (item.action == @selector(setDefaultConformNone:)) tag = @"none";
        if (tag) {
            item.state = [current isEqualToString:tag] ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
}

- (void)updateToolbarButtonState:(BOOL)active {
    NSButton *btn = self.toolbarButton;
    if (!btn) return;
    btn.state = active ? NSControlStateValueOn : NSControlStateValueOff;
    // Match FCP's native toolbar style — active buttons get a blue accent tint
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

    // Create "Enhancements" top-level menu
    NSMenu *bridgeMenu = [[NSMenu alloc] initWithTitle:@"Enhancements"];

    NSMenuItem *transcriptItem = [[NSMenuItem alloc]
        initWithTitle:@"Transcript Editor"
               action:@selector(toggleTranscriptPanel:)
        keyEquivalent:@"t"];
    transcriptItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    transcriptItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:transcriptItem];

    NSMenuItem *captionItem = [[NSMenuItem alloc]
        initWithTitle:@"Social Captions"
               action:@selector(toggleCaptionPanel:)
        keyEquivalent:@"c"];
    captionItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    captionItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:captionItem];

    NSMenuItem *paletteItem = [[NSMenuItem alloc]
        initWithTitle:@"Command Palette"
               action:@selector(toggleCommandPalette:)
        keyEquivalent:@"p"];
    paletteItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    paletteItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:paletteItem];

    NSMenuItem *luaItem = [[NSMenuItem alloc]
        initWithTitle:@"Lua REPL"
               action:@selector(toggleLuaPanel:)
        keyEquivalent:@"l"];
    luaItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    luaItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:luaItem];

    NSMenuItem *sectionsItem = [[NSMenuItem alloc]
        initWithTitle:@"Sections"
               action:@selector(toggleSections:)
        keyEquivalent:@"s"];
    sectionsItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    sectionsItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:sectionsItem];

    NSMenuItem *mixerItem = [[NSMenuItem alloc]
        initWithTitle:@"Audio Mixer"
               action:@selector(toggleMixerPanel:)
        keyEquivalent:@"m"];
    mixerItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    mixerItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:mixerItem];

    [bridgeMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *muteAudioItem = [[NSMenuItem alloc]
        initWithTitle:@"Mute Audio"
               action:@selector(toggleMuteAudio:)
        keyEquivalent:@"m"];
    muteAudioItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    muteAudioItem.target = [SpliceKitMenuController shared];
    [bridgeMenu addItem:muteAudioItem];

    // --- Lua Scripts submenu (dynamically populated) ---
    NSMenu *luaScriptsMenu = [[NSMenu alloc] initWithTitle:@"Lua Scripts"];
    luaScriptsMenu.delegate = [SpliceKitMenuController shared];
    luaScriptsMenu.autoenablesItems = NO;
    [SpliceKitMenuController shared].luaScriptsMenu = luaScriptsMenu;
    NSMenuItem *luaScriptsMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Lua Scripts"
               action:nil
        keyEquivalent:@""];
    luaScriptsMenuItem.submenu = luaScriptsMenu;
    [bridgeMenu addItem:luaScriptsMenuItem];

    // --- Dual Timeline submenu ---
    [bridgeMenu addItem:[NSMenuItem separatorItem]];

    NSMenu *dualTimelineMenu = [[NSMenu alloc] initWithTitle:@"Dual Timeline"];
    SpliceKitMenuController *mc = [SpliceKitMenuController shared];

    NSMenuItem *openSecondaryItem = [[NSMenuItem alloc]
        initWithTitle:@"Open Secondary Timeline"
               action:@selector(openSecondaryTimeline:)
        keyEquivalent:@""];
    openSecondaryItem.target = mc;
    [dualTimelineMenu addItem:openSecondaryItem];

    NSMenuItem *syncRootItem = [[NSMenuItem alloc]
        initWithTitle:@"Clone Primary Root to Secondary"
               action:@selector(syncSecondaryTimelineRoot:)
        keyEquivalent:@""];
    syncRootItem.target = mc;
    [dualTimelineMenu addItem:syncRootItem];

    NSMenuItem *openSelectedItem = [[NSMenuItem alloc]
        initWithTitle:@"Open Selection in Secondary"
               action:@selector(openSelectedInSecondaryTimeline:)
        keyEquivalent:@""];
    openSelectedItem.target = mc;
    [dualTimelineMenu addItem:openSelectedItem];

    [dualTimelineMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *focusPrimaryItem = [[NSMenuItem alloc]
        initWithTitle:@"Focus Primary Timeline"
               action:@selector(focusPrimaryTimeline:)
        keyEquivalent:@""];
    focusPrimaryItem.target = mc;
    [dualTimelineMenu addItem:focusPrimaryItem];

    NSMenuItem *focusSecondaryItem = [[NSMenuItem alloc]
        initWithTitle:@"Focus Secondary Timeline"
               action:@selector(focusSecondaryTimeline:)
        keyEquivalent:@""];
    focusSecondaryItem.target = mc;
    [dualTimelineMenu addItem:focusSecondaryItem];

    NSMenuItem *closeSecondaryItem = [[NSMenuItem alloc]
        initWithTitle:@"Close Secondary Timeline"
               action:@selector(closeSecondaryTimeline:)
        keyEquivalent:@""];
    closeSecondaryItem.target = mc;
    [dualTimelineMenu addItem:closeSecondaryItem];

    [dualTimelineMenu addItem:[NSMenuItem separatorItem]];

    NSMenu *secondaryWindowMenu = [[NSMenu alloc] initWithTitle:@"Secondary Window"];

    NSMenuItem *secondaryBrowserItem = [[NSMenuItem alloc]
        initWithTitle:@"Toggle Browser"
               action:@selector(toggleSecondaryBrowser:)
        keyEquivalent:@""];
    secondaryBrowserItem.target = mc;
    [secondaryWindowMenu addItem:secondaryBrowserItem];

    NSMenuItem *secondaryTimelineIndexItem = [[NSMenuItem alloc]
        initWithTitle:@"Toggle Timeline Index"
               action:@selector(toggleSecondaryTimelineIndex:)
        keyEquivalent:@""];
    secondaryTimelineIndexItem.target = mc;
    [secondaryWindowMenu addItem:secondaryTimelineIndexItem];

    NSMenuItem *secondaryAudioMetersItem = [[NSMenuItem alloc]
        initWithTitle:@"Toggle Audio Meters"
               action:@selector(toggleSecondaryAudioMeters:)
        keyEquivalent:@""];
    secondaryAudioMetersItem.target = mc;
    [secondaryWindowMenu addItem:secondaryAudioMetersItem];

    NSMenuItem *secondaryEffectsItem = [[NSMenuItem alloc]
        initWithTitle:@"Toggle Effects Browser"
               action:@selector(toggleSecondaryEffectsBrowser:)
        keyEquivalent:@""];
    secondaryEffectsItem.target = mc;
    [secondaryWindowMenu addItem:secondaryEffectsItem];

    NSMenuItem *secondaryTransitionsItem = [[NSMenuItem alloc]
        initWithTitle:@"Toggle Transitions Browser"
               action:@selector(toggleSecondaryTransitionsBrowser:)
        keyEquivalent:@""];
    secondaryTransitionsItem.target = mc;
    [secondaryWindowMenu addItem:secondaryTransitionsItem];

    NSMenuItem *secondaryWindowMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Secondary Window"
               action:nil
        keyEquivalent:@""];
    secondaryWindowMenuItem.submenu = secondaryWindowMenu;
    [dualTimelineMenu addItem:secondaryWindowMenuItem];

    NSMenuItem *dualTimelineMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Dual Timeline"
               action:nil
        keyEquivalent:@""];
    dualTimelineMenuItem.submenu = dualTimelineMenu;
    [bridgeMenu addItem:dualTimelineMenuItem];

    // --- Playback Speed submenu ---
    [bridgeMenu addItem:[NSMenuItem separatorItem]];

    NSMenu *speedMenu = [[NSMenu alloc] initWithTitle:@"Playback Speed"];

    NSMenuItem *lItem = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"L Speeds: %@",
                       SpliceKit_ladderToString(SpliceKit_getLLadder())]
               action:@selector(editLLadder:)
        keyEquivalent:@""];
    lItem.target = mc;
    [speedMenu addItem:lItem];

    NSMenuItem *jItem = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"J Speeds: %@",
                       SpliceKit_ladderToString(SpliceKit_getJLadder())]
               action:@selector(editJLadder:)
        keyEquivalent:@""];
    jItem.target = mc;
    [speedMenu addItem:jItem];

    NSMenuItem *speedMenuItem = [[NSMenuItem alloc] initWithTitle:@"Playback Speed" action:nil keyEquivalent:@""];
    speedMenuItem.submenu = speedMenu;
    [bridgeMenu addItem:speedMenuItem];

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

    NSMenuItem *suppressAutoImportItem = [[NSMenuItem alloc]
        initWithTitle:@"Suppress Auto Import Window on Device Connect"
               action:@selector(toggleSuppressAutoImport:)
        keyEquivalent:@""];
    suppressAutoImportItem.target = [SpliceKitMenuController shared];
    suppressAutoImportItem.state = SpliceKit_isSuppressAutoImportEnabled()
        ? NSControlStateValueOn : NSControlStateValueOff;
    [optionsMenu addItem:suppressAutoImportItem];

    // --- Default Spatial Conform submenu ---
    NSMenu *conformMenu = [[NSMenu alloc] initWithTitle:@"Default Spatial Conform"];
    NSString *currentConform = SpliceKit_getDefaultSpatialConformType();

    NSMenuItem *conformFitItem = [[NSMenuItem alloc]
        initWithTitle:@"Fit (Default)" action:@selector(setDefaultConformFit:) keyEquivalent:@""];
    conformFitItem.target = [SpliceKitMenuController shared];
    conformFitItem.state = [currentConform isEqualToString:@"fit"] ? NSControlStateValueOn : NSControlStateValueOff;
    [conformMenu addItem:conformFitItem];

    NSMenuItem *conformFillItem = [[NSMenuItem alloc]
        initWithTitle:@"Fill" action:@selector(setDefaultConformFill:) keyEquivalent:@""];
    conformFillItem.target = [SpliceKitMenuController shared];
    conformFillItem.state = [currentConform isEqualToString:@"fill"] ? NSControlStateValueOn : NSControlStateValueOff;
    [conformMenu addItem:conformFillItem];

    NSMenuItem *conformNoneItem = [[NSMenuItem alloc]
        initWithTitle:@"None" action:@selector(setDefaultConformNone:) keyEquivalent:@""];
    conformNoneItem.target = [SpliceKitMenuController shared];
    conformNoneItem.state = [currentConform isEqualToString:@"none"] ? NSControlStateValueOn : NSControlStateValueOff;
    [conformMenu addItem:conformNoneItem];

    NSMenuItem *conformMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Default Spatial Conform" action:nil keyEquivalent:@""];
    conformMenuItem.submenu = conformMenu;
    [optionsMenu addItem:conformMenuItem];

    NSMenuItem *optionsMenuItem = [[NSMenuItem alloc] initWithTitle:@"Options" action:nil keyEquivalent:@""];
    optionsMenuItem.submenu = optionsMenu;
    [bridgeMenu addItem:optionsMenuItem];

    // Add the menu to the menu bar (before the last item which is usually "Help")
    NSMenuItem *bridgeMenuItem = [[NSMenuItem alloc] initWithTitle:@"Enhancements" action:nil keyEquivalent:@""];
    bridgeMenuItem.submenu = bridgeMenu;

    NSInteger helpIndex = [mainMenu indexOfItemWithTitle:@"Help"];
    if (helpIndex >= 0) {
        [mainMenu insertItem:bridgeMenuItem atIndex:helpIndex];
    } else {
        [mainMenu addItem:bridgeMenuItem];
    }

    // --- Add OTIO Import/Export items to FCP's File menu ---
    // FCP's File menu structure:
    //   File > Import (submenu) > Media..., XML..., Captions...
    //   File > Export XML...
    // We add "OpenTimelineIO..." into the Import submenu (after XML...)
    // and "Export to OpenTimelineIO..." after "Export XML..."
    NSMenu *fileMenu = nil;
    for (NSMenuItem *item in mainMenu.itemArray) {
        if ([item.title isEqualToString:@"File"] && item.submenu) {
            fileMenu = item.submenu;
            break;
        }
    }
    if (fileMenu) {
        NSMenuItem *importOTIOItem = [[NSMenuItem alloc]
            initWithTitle:@"OpenTimelineIO..."
                   action:@selector(importOTIO:)
            keyEquivalent:@""];
        importOTIOItem.target = [SpliceKitMenuController shared];

        NSMenuItem *exportOTIOItem = [[NSMenuItem alloc]
            initWithTitle:@"Export OpenTimelineIO..."
                   action:@selector(exportOTIO:)
            keyEquivalent:@""];
        exportOTIOItem.target = [SpliceKitMenuController shared];

        // Find the "Import" submenu and add our item after "XML..."
        for (NSInteger i = 0; i < fileMenu.numberOfItems; i++) {
            NSMenuItem *item = [fileMenu itemAtIndex:i];
            if ([item.title isEqualToString:@"Import"] && item.submenu) {
                NSMenu *importSubmenu = item.submenu;
                // Find "XML..." to insert after it
                NSInteger xmlIndex = -1;
                for (NSInteger j = 0; j < importSubmenu.numberOfItems; j++) {
                    if ([[importSubmenu itemAtIndex:j].title containsString:@"XML"]) {
                        xmlIndex = j;
                        break;
                    }
                }
                if (xmlIndex >= 0) {
                    [importSubmenu insertItem:importOTIOItem atIndex:xmlIndex + 1];
                } else {
                    [importSubmenu addItem:importOTIOItem];
                }
                break;
            }
        }

        // Find "Export XML..." and add our export after it
        for (NSInteger i = 0; i < fileMenu.numberOfItems; i++) {
            NSString *title = [fileMenu itemAtIndex:i].title;
            if ([title containsString:@"Export XML"]) {
                [fileMenu insertItem:exportOTIOItem atIndex:i + 1];
                break;
            }
        }

        SpliceKit_log(@"OTIO import/export added to File menu");
    }

    SpliceKit_log(@"SpliceKit menu installed (Ctrl+Option+T Transcript, Ctrl+Option+C Captions, Cmd+Shift+P Palette, Ctrl+Option+L Lua REPL)");
}

static NSString * const kSpliceKitTranscriptToolbarID = @"SpliceKitTranscriptItemID";
static NSString * const kSpliceKitPaletteToolbarID = @"SpliceKitPaletteItemID";
static IMP sOriginalToolbarItemForIdentifier = NULL;

// We swizzle FCP's toolbar delegate so it knows about our custom toolbar items.
// When FCP asks "what item goes at this identifier?", we intercept our IDs and
// return our buttons. Everything else passes through to the original handler.
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
    // FCP's main window isn't ready immediately at launch — we need to wait
    // for it. We use a two-pronged approach: listen for the notification,
    // and also poll as a fallback in case we missed it.
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
        // 30 seconds is plenty. If there's no toolbar by now, something's wrong.
        SpliceKit_log(@"No main window for toolbar button after %d attempts", attempt);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // FCP sometimes has multiple windows — check all of them
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

        // We need to teach FCP's toolbar delegate about our custom item IDs.
        // The cleanest way is to swizzle the delegate's itemForItemIdentifier: method.
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

        // Guard against double-insertion — can happen if both the notification
        // and the polling fallback fire. Also clean up stale items (no view).
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

        // Insert our buttons just before the flexible space — that's where
        // they look most natural, grouped with FCP's own tool buttons.
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
//
// This fires once FCP is fully loaded and its UI is ready. We can't do most of
// our setup in the constructor because FCP's frameworks aren't loaded yet at that
// point — you'll get nil back from objc_getClass for anything in Flexo.framework.
//

// ---------------------------------------------------------------------------
// Safe install wrapper — catches SIGSEGV/SIGBUS during feature install so a
// single broken swizzle doesn't bring down the whole process.
//
// Uses sigsetjmp/siglongjmp: set a recovery point, temporarily swap the signal
// handler, call the install function.  If it crashes, the handler longjmps back,
// logs which feature failed, and startup continues with the next one.
//
// Only used during startup on the main thread.  Thread identity is checked in
// the handler so a stray crash on another thread still hits the normal path.
// ---------------------------------------------------------------------------

static sigjmp_buf sSafeInstallJmpBuf;
static pthread_t  sSafeInstallThread;
static volatile sig_atomic_t sSafeInstallActive = 0;

static void SpliceKit_safeInstallHandler(int sig, siginfo_t *info, void *ctx) {
    if (sSafeInstallActive && pthread_equal(pthread_self(), sSafeInstallThread)) {
        sSafeInstallActive = 0;
        siglongjmp(sSafeInstallJmpBuf, sig);
    }
    // Not our context — restore default and re-raise so the normal crash
    // handler (or macOS crash reporter) picks it up.
    signal(sig, SIG_DFL);
    raise(sig);
}

BOOL SpliceKit_safeInstall(const char *featureName, void (^block)(void)) {
    NSString *feature = featureName ? [NSString stringWithUTF8String:featureName] : @"unknown";
    struct sigaction sa, prevSEGV, prevBUS;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = SpliceKit_safeInstallHandler;
    sa.sa_flags     = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);

    sigaction(SIGSEGV, &sa, &prevSEGV);
    sigaction(SIGBUS,  &sa, &prevBUS);

    sSafeInstallThread = pthread_self();
    sSafeInstallActive = 1;

    int sig = sigsetjmp(sSafeInstallJmpBuf, 1);
    if (sig == 0) {
        // Normal path — attempt the install
        @try {
            block();
        } @catch (NSException *e) {
            sSafeInstallActive = 0;
            sigaction(SIGSEGV, &prevSEGV, NULL);
            sigaction(SIGBUS,  &prevBUS,  NULL);
            SpliceKit_log(@"[SafeInstall] %s threw %@: %@ — feature disabled",
                          featureName, e.name, e.reason);
            SpliceKit_sentryCaptureException(e,
                                             @"runtime.safe_install.exception",
                                             @{@"feature": feature});
            return NO;
        }
        sSafeInstallActive = 0;
        sigaction(SIGSEGV, &prevSEGV, NULL);
        sigaction(SIGBUS,  &prevBUS,  NULL);
        return YES;
    } else {
        // Crash recovery — handler did siglongjmp back here.
        // Unblock the signal (blocked automatically during handler execution).
        sigset_t unblock;
        sigemptyset(&unblock);
        sigaddset(&unblock, SIGSEGV);
        sigaddset(&unblock, SIGBUS);
        pthread_sigmask(SIG_UNBLOCK, &unblock, NULL);

        sigaction(SIGSEGV, &prevSEGV, NULL);
        sigaction(SIGBUS,  &prevBUS,  NULL);
        SpliceKit_log(@"[SafeInstall] %s crashed (signal %d) — feature auto-disabled",
                      featureName, sig);
        SpliceKit_sentryCaptureMessage([NSString stringWithFormat:@"Safe install crashed for %s (signal %d)",
                                        featureName, sig],
                                       @"runtime.safe_install.signal",
                                       @{@"feature": feature, @"signal": @(sig)});
        return NO;
    }
}

// FCP registers Apple's AUSoundIsolation AU but hides it in the UI. Re-apply
// the visibility override after launch once the effect registry is ready so the
// effect browser can surface it on every startup.
static NSString *SpliceKit_soundIsolationEffectID(void) {
    Class effectStackClass = objc_getClass("FFEffectStack");
    SEL voiceIsolationSel = NSSelectorFromString(@"voiceIsolationEffectID");
    if (effectStackClass && [effectStackClass respondsToSelector:voiceIsolationSel]) {
        id effectID = ((id (*)(id, SEL))objc_msgSend)(effectStackClass, voiceIsolationSel);
        if ([effectID isKindOfClass:[NSString class]] && [effectID length] > 0) {
            return effectID;
        }
    }

    Class auEffectClass = objc_getClass("FFAudioUnitEffect");
    SEL identifierSel = NSSelectorFromString(@"effectIdentifierForType:subType:manufacturer:");
    if (auEffectClass && [auEffectClass respondsToSelector:identifierSel]) {
        id effectID = ((id (*)(id, SEL, unsigned int, unsigned int, unsigned int))objc_msgSend)(
            auEffectClass, identifierSel, 1635083896U, 1987012979U, 1634758764U);
        if ([effectID isKindOfClass:[NSString class]] && [effectID length] > 0) {
            return effectID;
        }
    }

    return @"AudioUnit: 0x61756678766f69736170706c";
}

static BOOL SpliceKit_tryUnhideSoundIsolationNow(void) {
    Class ffEffectClass = objc_getClass("FFEffect");
    if (!ffEffectClass) {
        SpliceKit_log(@"SoundIsolation unhide: FFEffect class not available yet");
        return NO;
    }

    SEL ensureSel = NSSelectorFromString(@"ensureEffectsRegistered");
    if ([ffEffectClass respondsToSelector:ensureSel]) {
        ((void (*)(id, SEL))objc_msgSend)(ffEffectClass, ensureSel);
    }

    NSString *effectID = SpliceKit_soundIsolationEffectID();
    if (effectID.length == 0) {
        SpliceKit_log(@"SoundIsolation unhide: could not resolve effect ID");
        return NO;
    }

    SEL registeredSel = NSSelectorFromString(@"effectIDIsRegistered:");
    if (![ffEffectClass respondsToSelector:registeredSel]) {
        SpliceKit_log(@"SoundIsolation unhide: FFEffect is missing effectIDIsRegistered:");
        return NO;
    }

    BOOL isRegistered = ((BOOL (*)(id, SEL, id))objc_msgSend)(ffEffectClass, registeredSel, effectID);
    if (!isRegistered) {
        SpliceKit_log(@"SoundIsolation unhide: %@ not registered yet", effectID);
        return NO;
    }

    SEL propertiesSel = NSSelectorFromString(@"propertiesForEffect:");
    NSDictionary *beforeProps = nil;
    if ([ffEffectClass respondsToSelector:propertiesSel]) {
        beforeProps = ((id (*)(id, SEL, id))objc_msgSend)(ffEffectClass, propertiesSel, effectID);
    }

    BOOL wasHidden = [beforeProps[@"FFEffectProperty_HiddenInUI"] boolValue];
    SEL updateHiddenSel = NSSelectorFromString(@"updatePropertyHiddenInUI:onEffectIDs:");
    if (![ffEffectClass respondsToSelector:updateHiddenSel]) {
        SpliceKit_log(@"SoundIsolation unhide: FFEffect is missing updatePropertyHiddenInUI:onEffectIDs:");
        return NO;
    }

    BOOL updated = ((BOOL (*)(id, SEL, BOOL, id))objc_msgSend)(
        ffEffectClass, updateHiddenSel, NO, @[effectID]);

    NSDictionary *afterProps = nil;
    if ([ffEffectClass respondsToSelector:propertiesSel]) {
        afterProps = ((id (*)(id, SEL, id))objc_msgSend)(ffEffectClass, propertiesSel, effectID);
    }

    BOOL isHidden = [afterProps[@"FFEffectProperty_HiddenInUI"] boolValue];
    if (!updated && isHidden) {
        SpliceKit_log(@"SoundIsolation unhide: update call failed for %@", effectID);
        return NO;
    }

    SpliceKit_log(@"SoundIsolation unhide: %@ hidden=%@ -> %@",
                  effectID,
                  wasHidden ? @"YES" : @"NO",
                  isHidden ? @"hidden" : @"visible");
    return !isHidden;
}

static void SpliceKit_scheduleSoundIsolationUnhideAttempt(NSUInteger attempt) {
    const NSUInteger kMaxAttempts = 20;
    if (attempt >= kMaxAttempts) {
        SpliceKit_log(@"SoundIsolation unhide: giving up after %lu attempts",
                      (unsigned long)attempt);
        return;
    }

    NSTimeInterval delay = (attempt == 0) ? 0.25 : 1.0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [NSThread sleepForTimeInterval:delay];
        __block BOOL success = NO;
        __block BOOL didThrow = NO;
        @try {
            SpliceKit_executeOnMainThread(^{
                @try {
                    success = SpliceKit_tryUnhideSoundIsolationNow();
                } @catch (NSException *e) {
                    didThrow = YES;
                    SpliceKit_log(@"SoundIsolation unhide attempt %lu threw %@: %@",
                                  (unsigned long)attempt, e.name, e.reason);
                }
            });
        } @catch (NSException *e) {
            didThrow = YES;
            SpliceKit_log(@"SoundIsolation unhide dispatch %lu threw %@: %@",
                          (unsigned long)attempt, e.name, e.reason);
        }
        if (!success) {
            SpliceKit_scheduleSoundIsolationUnhideAttempt(attempt + 1);
        }
    });
}

static void SpliceKit_appDidLaunch(void) {
    SpliceKit_sentrySetLaunchPhase(@"did-finish-launching");
    SpliceKit_log(@"================================================");
    SpliceKit_log(@"App launched. Starting control server...");
    SpliceKit_log(@"================================================");

    // Run compatibility check now that all frameworks are loaded
    SpliceKit_checkCompatibility();

    SpliceKit_bootstrapBRAWAtLaunchPhase(@"did-launch");

    // Install focused editor routing before commands and menus start querying
    // activeEditorContainer, so the secondary timeline can participate in the
    // normal responder path.
    SpliceKit_safeInstall("DualTimeline", ^{
        SpliceKit_installDualTimeline();
        SpliceKit_installDualTimelineCrossWindowDrag();
    });

    // Count total loaded classes
    unsigned int classCount = 0;
    Class *allClasses = objc_copyClassList(&classCount);
    free(allClasses);
    SpliceKit_log(@"Total ObjC classes in process: %u", classCount);

    // Install Enhancements menu in the menu bar
    SpliceKit_installMenu();

    // Install toolbar button in FCP's main window
    [SpliceKitMenuController installToolbarButton];

    // Install transition freeze-extend swizzle (adds "Use Freeze Frames" button
    // to the "not enough extra media" dialog)
    SpliceKit_installTransitionFreezeExtendSwizzle();

    // Install effect-drag-as-adjustment-clip swizzle (allows dragging effects
    // to empty timeline space to create adjustment clips)
    SpliceKit_safeInstall("EffectDragAsAdjustmentClip", ^{
        SpliceKit_installEffectDragAsAdjustmentClip();
    });

    // Install viewer pinch-to-zoom if previously enabled
    if (SpliceKit_isViewerPinchZoomEnabled()) {
        SpliceKit_installViewerPinchZoom();
    }

    // Install video-only-keeps-audio-disabled swizzle if previously enabled
    if (SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled()) {
        SpliceKit_installVideoOnlyKeepsAudioDisabled();
    }

    // Install suppress-auto-import swizzle if previously enabled. The mount-notification
    // observers were already set up at FCP launch before our dylib loaded, so we have
    // to intercept the handler methods themselves rather than the observer registration.
    if (SpliceKit_isSuppressAutoImportEnabled()) {
        SpliceKit_installSuppressAutoImport();
    }

    // Spring-loaded blade disabled — intercepting Option key breaks FCP's native
    // Option+click (extend edit) and Option+drag (copy clip) behaviors.
    if (SpliceKit_isSpringLoadedBladeEnabled()) {
        SpliceKit_setSpringLoadedBladeEnabled(NO);
        SpliceKit_log(@"  Spring-loaded blade auto-disabled (conflicts with Option+click editing)");
    }

    // Install default spatial conform swizzle if set to non-default value
    if (![SpliceKit_getDefaultSpatialConformType() isEqualToString:@"fit"]) {
        SpliceKit_installDefaultSpatialConformType();
    }

    // Install effect browser favorites context menu (always on)
    SpliceKit_installEffectFavoritesSwizzle();

    // Latch skim state off the methods FCP actually calls so the mixer can
    // meter live skims even when isToolSkimming stays false.
    SpliceKit_installMixerSkimHooks();

    // Restore persisted social caption text after relaunch once a real sequence is
    // active. Automatic repair is intentionally limited to the Motion effect text
    // field API so relaunch does not wake the heavier channel/document machinery.
    Class captionPanelClass = objc_getClass("SpliceKitCaptionPanel");
    if (captionPanelClass) {
        id captionPanel = ((id (*)(id, SEL))objc_msgSend)((id)captionPanelClass, @selector(sharedPanel));
        SEL enableAutoRestoreSel = NSSelectorFromString(@"enableAutomaticRestore");
        if (captionPanel && [captionPanel respondsToSelector:enableAutoRestoreSel]) {
            ((void (*)(id, SEL))objc_msgSend)(captionPanel, enableAutoRestoreSel);
        }
    }

    // Install FCPXML direct paste support (converts FCPXML on pasteboard
    // to native clipboard format so pasteAnchored: can handle it)
    SpliceKit_installFCPXMLPasteSwizzle();

    // Swizzle J/L to use configurable speed ladders
    SpliceKit_installPlaybackSpeedSwizzle();

    // Rebuild FCP's hidden Debug pane + Debug menu bar (Apple strips the NIB
    // and leaves the menu unassigned in release builds; we reconstruct both).
    SpliceKit_installDebugSettingsPanel();
    SpliceKit_installDebugMenuBar();

    // Install right-click context menu for structure block color changes
    SpliceKit_safeInstall("StructureBlockContextMenu", ^{
        SpliceKit_installStructureBlockContextMenu();
    });

    // Start the control server on a background thread
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SpliceKit_startControlServer();
    });

    // Initialize Lua scripting VM
    SpliceKit_safeInstall("LuaVM", ^{
        SpliceKitLua_initialize();
    });

    // Load plugins from ~/Library/Application Support/SpliceKit/plugins/
    // Native plugins load independently of Lua — don't gate on Lua success.
    SpliceKitPlugins_loadAll();

    SpliceKit_log(@"SoundIsolation unhide: scheduling startup attempts");
    SpliceKit_scheduleSoundIsolationUnhideAttempt(0);
}

#pragma mark - Crash Prevention & Startup Fixes
//
// FCP has a few code paths that crash or hang when running outside its normal
// signed/entitled environment. We patch them out before they have a chance to fire.
//
// These swizzles are applied in the constructor (before main), so they need to
// target classes that are available early — mostly Swift classes in the main
// binary and ProCore framework classes.
//

// Replacement IMPs for blocking problematic methods
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

// Silent variant — no logging. Used for high-frequency swizzles like isSPVEnabled
// which gets called dozens of times during startup.
static BOOL returnNO_silent(id self, SEL _cmd) {
    return NO;
}

static void noopMethodWith2Args(id self, SEL _cmd, id arg1, id arg2) {}

// PCUserDefaultsMigrator runs on quit and calls copyDataFromSource:toTarget:,
// which walks a potentially massive media directory tree via getattrlistbulk.
// On large libraries this hangs for 30+ seconds, making FCP feel like it froze.
// Since we don't need the migration, we just no-op it.
static void SpliceKit_fixShutdownHang(void) {
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

// Brute-force CloudContent neutralizer: enumerates all registered ObjC classes and
// swizzles any class whose name contains "CloudContent" or "CloudContentCatalog" etc.
// This avoids guessing Swift mangled names which vary by FCP version.
// Called at constructor time AND at WillFinishLaunching (Swift lazy class registration
// means classes may not be available until frameworks finish loading).
static void SpliceKit_swizzleCloudContentClasses(const char *phase) {
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return;

    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    objc_getClassList(classes, numClasses);

    for (int i = 0; i < numClasses; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;

        // CloudContentFirstLaunchHelper (or any future rename containing this)
        if (strstr(name, "CloudContentFirstLaunchHelper")) {
            SpliceKit_log(@"  [%s] Found class: %s", phase, name);
            SEL sel1 = NSSelectorFromString(@"setupAndPresentFirstLaunchIfNeeded");
            Method m1 = class_getInstanceMethod(classes[i], sel1);
            if (m1) {
                method_setImplementation(m1, (IMP)noopMethod);
                SpliceKit_log(@"  [%s] Swizzled %s -setupAndPresentFirstLaunchIfNeeded", phase, name);
                SpliceKit_trackSwizzle(@"CloudContentFirstLaunchHelper.setupAndPresent", YES);
            } else {
                SpliceKit_log(@"  [%s] WARNING: %s exists but -setupAndPresentFirstLaunchIfNeeded not found", phase, name);
                // Dump all instance methods so we can see what's available
                unsigned int methodCount = 0;
                Method *methods = class_copyMethodList(classes[i], &methodCount);
                for (unsigned int j = 0; j < methodCount && j < 30; j++) {
                    SpliceKit_log(@"    method: %@", NSStringFromSelector(method_getName(methods[j])));
                }
                if (methods) free(methods);
                SpliceKit_trackSwizzle(@"CloudContentFirstLaunchHelper.setupAndPresent", NO);
            }
            SEL sel2 = NSSelectorFromString(@"setupAndPresentFirstLaunchIfNeededWithCompletionHandler:");
            Method m2 = class_getInstanceMethod(classes[i], sel2);
            if (m2) {
                method_setImplementation(m2, (IMP)noopMethodWithArg);
                SpliceKit_log(@"  [%s] Swizzled %s -setupAndPresentFirstLaunchIfNeeded(completion:)", phase, name);
                SpliceKit_trackSwizzle(@"CloudContentFirstLaunchHelper.setupAndPresent(completion:)", YES);
            }
        }

        // CloudContentCatalog — the actual crashing method
        if (strstr(name, "CloudContentCatalog")) {
            SpliceKit_log(@"  [%s] Found class: %s", phase, name);
            SEL sel = NSSelectorFromString(@"updateCatalogAndRegistry");
            Method m = class_getInstanceMethod(classes[i], sel);
            if (m) {
                method_setImplementation(m, (IMP)noopMethod);
                SpliceKit_log(@"  [%s] Swizzled %s -updateCatalogAndRegistry", phase, name);
                SpliceKit_trackSwizzle(@"CloudContentCatalog.updateCatalogAndRegistry", YES);
            } else {
                SpliceKit_log(@"  [%s] WARNING: %s exists but -updateCatalogAndRegistry not found", phase, name);
                unsigned int methodCount = 0;
                Method *methods = class_copyMethodList(classes[i], &methodCount);
                for (unsigned int j = 0; j < methodCount && j < 30; j++) {
                    SpliceKit_log(@"    method: %@", NSStringFromSelector(method_getName(methods[j])));
                }
                if (methods) free(methods);
                SpliceKit_trackSwizzle(@"CloudContentCatalog.updateCatalogAndRegistry", NO);
            }
        }

        // CloudContentFeatureFlag — prevent the entire code path
        if (strstr(name, "CloudContentFeatureFlag")) {
            SpliceKit_log(@"  [%s] Found class: %s", phase, name);
            Method m = class_getClassMethod(classes[i], @selector(isEnabled));
            if (m) {
                method_setImplementation(m, (IMP)returnNO);
                SpliceKit_log(@"  [%s] Swizzled %s +isEnabled -> NO", phase, name);
                SpliceKit_trackSwizzle(@"CloudContentFeatureFlag.isEnabled", YES);
            } else {
                SpliceKit_log(@"  [%s] WARNING: %s exists but +isEnabled not found", phase, name);
                SpliceKit_trackSwizzle(@"CloudContentFeatureFlag.isEnabled", NO);
            }
        }
    }

    free(classes);
}

// CloudContent/ImagePlayground crashes at launch because:
//   PEAppController.presentMainWindowOnAppLaunch: checks CloudContentFeatureFlag.isEnabled,
//   which triggers CloudContentCatalog.shared -> CCFirstLaunchHelper -> CloudKit.
//   Without proper iCloud entitlements, CloudKit throws an uncaught exception.
//
// Fix: make the feature flag return NO so the entire code path is skipped.
// Same deal with FFImagePlayground.isAvailable — it goes through a similar CloudKit path.
static void SpliceKit_disableCloudContent(void) {
    SpliceKit_log(@"Disabling CloudContent/ImagePlayground...");

    // Swift class names get mangled. Try the mangled name first, then the demangled form.
    Class ccFlag = objc_getClass("_TtC13Final_Cut_Pro23CloudContentFeatureFlag");
    if (!ccFlag) {
        ccFlag = objc_getClass("Final_Cut_Pro.CloudContentFeatureFlag");
    }

    if (ccFlag) {
        Method m = class_getClassMethod(ccFlag, @selector(isEnabled));
        if (m) {
            method_setImplementation(m, (IMP)returnNO);
            SpliceKit_log(@"  Swizzled +[CloudContentFeatureFlag isEnabled] -> NO");
            SpliceKit_trackSwizzle(@"CloudContentFeatureFlag.isEnabled", YES);
        } else {
            SpliceKit_log(@"  WARNING: +isEnabled not found on CloudContentFeatureFlag");
            SpliceKit_trackSwizzle(@"CloudContentFeatureFlag.isEnabled", NO);
        }
    } else {
        SpliceKit_log(@"  WARNING: CloudContentFeatureFlag class not found");
        SpliceKit_trackSwizzle(@"CloudContentFeatureFlag.isEnabled", NO);
    }

    Class ipClass = objc_getClass("_TtC5Flexo17FFImagePlayground");
    if (!ipClass) ipClass = objc_getClass("Flexo.FFImagePlayground");
    if (ipClass) {
        Method m = class_getClassMethod(ipClass, @selector(isAvailable));
        if (m) {
            method_setImplementation(m, (IMP)returnNO);
            SpliceKit_log(@"  Swizzled +[FFImagePlayground isAvailable] -> NO");
        }
    }

    // Handle the first-launch helper directly — the feature flag swizzle may not
    // take effect on all FCP versions, so we also noop the helper that triggers
    // CloudKit (which requires iCloud entitlements lost after re-signing).
    //
    // FCP < 12.2: ObjC class CCFirstLaunchHelper, method -setupAndPresentFirstLaunchIfNeededWithCompletionHandler:
    // FCP >= 12.2: Swift class CloudContentFirstLaunchHelper, method -setupAndPresentFirstLaunchIfNeeded
    Class ccHelper = objc_getClass("CCFirstLaunchHelper");
    if (ccHelper) {
        SEL sel = NSSelectorFromString(@"setupAndPresentFirstLaunchIfNeededWithCompletionHandler:");
        Method m = class_getInstanceMethod(ccHelper, sel);
        if (m) {
            method_setImplementation(m, (IMP)noopMethodWithArg);
            SpliceKit_log(@"  Handled CCFirstLaunchHelper (CloudKit entitlements fix)");
            SpliceKit_trackSwizzle(@"CloudContentFirstLaunchHelper.setupAndPresent(completion:)", YES);
        } else {
            SpliceKit_trackSwizzle(@"CloudContentFirstLaunchHelper.setupAndPresent(completion:)", NO);
        }
    }

    // Brute-force scan: enumerate ALL registered ObjC classes and swizzle anything
    // with CloudContent in the name. This avoids guessing Swift mangled names, which
    // vary by FCP version and compiler. At constructor time Swift classes may not be
    // registered yet (lazy loading), so we also retry this in WillFinishLaunching.
    SpliceKit_swizzleCloudContentClasses("constructor");

    SpliceKit_log(@"CloudContent/ImagePlayground disabled.");
}

#pragma mark - App Store Receipt Validation
//
// Validates the App Store receipt from the original (unmodded) FCP installation.
// The receipt is a PKCS7-signed ASN.1 blob from Apple. We verify the signature
// via CMSDecoder and parse the payload to extract the bundle ID, confirming the
// user legitimately downloaded the app from the App Store.
//
// This runs locally — no network calls, no Apple servers.
//

#import <Security/CMSDecoder.h>

// Read a DER length field. Returns bytes consumed (0 on error).
static size_t SpliceKit_readDERLength(const uint8_t *buf, size_t bufLen, size_t *outLen) {
    if (bufLen == 0) return 0;
    uint8_t first = buf[0];
    if (!(first & 0x80)) {
        *outLen = first;
        return 1;
    }
    size_t numBytes = first & 0x7F;
    if (numBytes == 0 || numBytes > 4 || numBytes >= bufLen) return 0;
    size_t len = 0;
    for (size_t i = 0; i < numBytes; i++)
        len = (len << 8) | buf[1 + i];
    *outLen = len;
    return 1 + numBytes;
}

// Parse the ASN.1 receipt payload and extract the bundle ID (attribute type 2).
// Receipt structure: SET { SEQUENCE { INTEGER type, INTEGER version, OCTET STRING value } ... }
static NSString *SpliceKit_extractBundleIdFromPayload(NSData *payload) {
    const uint8_t *buf = payload.bytes;
    size_t total = payload.length;
    if (total < 2) return nil;

    // Outer SET (tag 0x31)
    if (buf[0] != 0x31) return nil;
    size_t setLen = 0;
    size_t off = 1 + SpliceKit_readDERLength(buf + 1, total - 1, &setLen);
    size_t setEnd = off + setLen;
    if (setEnd > total) setEnd = total;

    while (off < setEnd) {
        // Each entry is a SEQUENCE (tag 0x30)
        if (buf[off] != 0x30) break;
        size_t seqLen = 0;
        size_t hdr = 1 + SpliceKit_readDERLength(buf + off + 1, setEnd - off - 1, &seqLen);
        size_t seqStart = off + hdr;
        size_t seqEnd = seqStart + seqLen;
        if (seqEnd > setEnd) break;

        // Parse: INTEGER type
        size_t p = seqStart;
        if (p >= seqEnd || buf[p] != 0x02) { off = seqEnd; continue; }
        p++;
        size_t intLen = 0;
        p += SpliceKit_readDERLength(buf + p, seqEnd - p, &intLen);
        int attrType = 0;
        for (size_t i = 0; i < intLen && i < 4; i++)
            attrType = (attrType << 8) | buf[p + i];
        p += intLen;

        // Skip: INTEGER version
        if (p >= seqEnd || buf[p] != 0x02) { off = seqEnd; continue; }
        p++;
        size_t verLen = 0;
        p += SpliceKit_readDERLength(buf + p, seqEnd - p, &verLen);
        p += verLen;

        // OCTET STRING value
        if (p >= seqEnd || buf[p] != 0x04) { off = seqEnd; continue; }
        p++;
        size_t valLen = 0;
        p += SpliceKit_readDERLength(buf + p, seqEnd - p, &valLen);

        // Type 2 = Bundle Identifier. The value is a UTF8String (tag 0x0C) inside the OCTET STRING.
        if (attrType == 2 && p + valLen <= seqEnd) {
            const uint8_t *val = buf + p;
            if (valLen >= 2 && val[0] == 0x0C) {
                size_t strLen = 0;
                size_t strHdr = 1 + SpliceKit_readDERLength(val + 1, valLen - 1, &strLen);
                if (strHdr + strLen <= valLen) {
                    return [[NSString alloc] initWithBytes:val + strHdr
                                                    length:strLen
                                                  encoding:NSUTF8StringEncoding];
                }
            }
        }

        off = seqEnd;
    }
    return nil;
}

// Log diagnostic details about a receipt (PKCS7 signature, bundle ID).
// This is informational only — the result does not gate app launch.
static void SpliceKit_logReceiptDiagnostics(NSData *receiptData, NSString *receiptPath) {
    CMSDecoderRef decoder = NULL;
    OSStatus status = CMSDecoderCreate(&decoder);
    if (status != noErr) {
        SpliceKit_log(@"[Receipt] CMSDecoderCreate failed: %d", (int)status);
        return;
    }

    status = CMSDecoderUpdateMessage(decoder, receiptData.bytes, receiptData.length);
    if (status != noErr) {
        SpliceKit_log(@"[Receipt] CMSDecoderUpdateMessage failed: %d", (int)status);
        CFRelease(decoder);
        return;
    }

    status = CMSDecoderFinalizeMessage(decoder);
    if (status != noErr) {
        SpliceKit_log(@"[Receipt] CMSDecoderFinalizeMessage failed: %d", (int)status);
        CFRelease(decoder);
        return;
    }

    size_t numSigners = 0;
    CMSDecoderGetNumSigners(decoder, &numSigners);
    if (numSigners == 0) {
        SpliceKit_log(@"[Receipt] No signers in receipt");
        CFRelease(decoder);
        return;
    }

    SecPolicyRef policy = SecPolicyCreateBasicX509();
    CMSSignerStatus signerStatus = kCMSSignerUnsigned;
    SecTrustRef trust = NULL;
    OSStatus certVerifyResult = 0;

    status = CMSDecoderCopySignerStatus(decoder, 0, policy, TRUE,
                                        &signerStatus, &trust, &certVerifyResult);

    BOOL signatureValid = (status == noErr && signerStatus == kCMSSignerValid);
    SpliceKit_log(@"[Receipt] Signature: %@ (signerStatus=%d certVerify=%d)",
        signatureValid ? @"VALID" : @"INVALID", (int)signerStatus, (int)certVerifyResult);

    if (trust) CFRelease(trust);
    if (policy) CFRelease(policy);

    CFDataRef contentRef = NULL;
    status = CMSDecoderCopyContent(decoder, &contentRef);
    CFRelease(decoder);

    if (status != noErr || !contentRef) {
        SpliceKit_log(@"[Receipt] Failed to extract payload: %d", (int)status);
        return;
    }

    NSData *payload = (__bridge_transfer NSData *)contentRef;
    NSString *bundleId = SpliceKit_extractBundleIdFromPayload(payload);
    if (bundleId) {
        BOOL bundleIdMatch = [bundleId isEqualToString:@"com.apple.FinalCut"] ||
                             [bundleId isEqualToString:@"com.apple.FinalCutApp"];
        SpliceKit_log(@"[Receipt] Bundle ID: \"%@\" %@",
            bundleId, bundleIdMatch ? @"MATCH" : @"MISMATCH");
    } else {
        SpliceKit_log(@"[Receipt] Could not extract bundle ID from payload");
    }
}

// Paths checked during the last receipt search (used in error reporting).
static NSArray *sCheckedReceiptPaths = nil;

// Search for an App Store receipt file at known locations.
// Returns YES if a receipt file is found (file existence is sufficient).
// PKCS7/signature details are logged for diagnostics but do not gate the result.
static BOOL SpliceKit_findReceiptFile(void) {
    NSMutableArray *paths = [NSMutableArray array];

    // 1. Running app's own receipt (patcher copies it into the modded bundle)
    NSURL *receiptURL = [[NSBundle mainBundle] appStoreReceiptURL];
    if (receiptURL.path) {
        [paths addObject:receiptURL.path];
    }

    // 2. Original Creator Studio install
    [paths addObject:
        @"/Applications/Final Cut Pro Creator Studio.app/Contents/_MASReceipt/receipt"];

    // 3. Standard FCP install (user may have both editions)
    [paths addObject:
        @"/Applications/Final Cut Pro.app/Contents/_MASReceipt/receipt"];

    sCheckedReceiptPaths = [paths copy];

    for (NSString *path in paths) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data.length > 0) {
            SpliceKit_log(@"[Receipt] Found: %@ (%lu bytes)", path, (unsigned long)data.length);
            SpliceKit_logReceiptDiagnostics(data, path);
            return YES;
        }
    }

    SpliceKit_log(@"[Receipt] No App Store receipt found. Checked:");
    for (NSString *path in paths) {
        SpliceKit_log(@"[Receipt]   %@", path);
    }
    return NO;
}

// Handle subscription validation based on which FCP edition is running.
// - Standard FCP (com.apple.FinalCut): perpetual license, no receipt check needed.
// - Creator Studio (com.apple.FinalCutApp): subscription-based, verify receipt file exists.
// - Unknown: proceed without blocking (future-proofing).
//
// Creator Studio uses an online subscription validation flow (SPV) at launch.
// After ad-hoc re-signing for dylib injection, the entitlements required for that
// online check are lost, causing a "Cannot Connect" error on startup. We route
// around it by making isSPVEnabled return NO.
static void SpliceKit_handleSubscriptionValidation(void) {
    SpliceKit_log(@"Checking subscription status...");

    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    SpliceKit_log(@"  Bundle identifier: %@", bundleId ?: @"(nil)");

    BOOL isCreatorStudio = [bundleId isEqualToString:@"com.apple.FinalCutApp"];
    BOOL isStandardFCP   = [bundleId isEqualToString:@"com.apple.FinalCut"];

    if (isStandardFCP) {
        // Standard FCP is a perpetual license — no subscription to validate.
        SpliceKit_log(@"  Standard FCP detected — skipping receipt validation");
    } else if (isCreatorStudio) {
        // Creator Studio requires a subscription. Verify the App Store receipt
        // file exists to confirm the user downloaded it from the App Store.
        SpliceKit_log(@"  Creator Studio detected — checking for App Store receipt");
        BOOL receiptFound = SpliceKit_findReceiptFile();
        if (!receiptFound) {
            SpliceKit_log(@"  No App Store receipt found");
            [[NSNotificationCenter defaultCenter]
                addObserverForName:NSApplicationDidFinishLaunchingNotification
                object:nil queue:nil usingBlock:^(NSNotification *note) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSMutableString *info = [NSMutableString stringWithString:
                            @"SpliceKit could not find an App Store receipt for "
                            @"Final Cut Pro Creator Studio.\n\nChecked locations:\n"];
                        for (NSString *path in sCheckedReceiptPaths) {
                            [info appendFormat:@"  \u2022 %@\n", path];
                        }
                        [info appendString:
                            @"\nPossible causes:\n"
                            @"  \u2022 Final Cut Pro was not installed from the App Store\n"
                            @"  \u2022 The original app was deleted before patching\n"
                            @"  \u2022 Volume license or MDM installation (no App Store receipt)\n"
                            @"\nPlease reinstall Final Cut Pro Creator Studio from the "
                            @"App Store, then re-run the SpliceKit patcher."];

                        NSAlert *alert = [[NSAlert alloc] init];
                        [alert setMessageText:@"No Valid Subscription Found"];
                        [alert setInformativeText:info];
                        [alert setAlertStyle:NSAlertStyleCritical];
                        [alert addButtonWithTitle:@"Quit"];
                        [alert runModal];
                        [NSApp terminate:nil];
                    });
                }];
            return;
        }
        SpliceKit_log(@"  Receipt found — proceeding with offline validation");
    } else {
        // Unknown bundle ID — don't block. Could be a renamed app or future edition.
        SpliceKit_log(@"  Unknown bundle ID \"%@\" — proceeding without receipt check", bundleId);
    }

    // Route the subscription check through the standard (non-online) launch path.
    // For standard FCP this is a harmless no-op. For Creator Studio it bypasses
    // the broken online SPV check.
    Class flexo = objc_getClass("Flexo");
    if (flexo) {
        Method m = class_getClassMethod(flexo, @selector(isSPVEnabled));
        if (m) {
            method_setImplementation(m, (IMP)returnNO_silent);
            SpliceKit_log(@"  Configured offline subscription validation");
        }
    }

    Class pcFeature = objc_getClass("PCAppFeature");
    if (pcFeature) {
        Method m = class_getClassMethod(pcFeature, @selector(isSPVEnabled));
        if (m)
            method_setImplementation(m, (IMP)returnNO_silent);
    }

    // The standard launch path triggers a CloudContent first-launch flow that
    // requires CloudKit entitlements (lost after re-signing). Mark it as already
    // completed to prevent the CloudKit crash.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"CloudContentFirstLaunchCompleted"];
    [defaults setBool:YES forKey:@"FFCloudContentDisabled"];

    SpliceKit_log(@"  Subscription validation configured");
    SpliceKit_logCloudContentGuardSummary(@"subscription-validation");
}

#pragma mark - Constructor
//
// __attribute__((constructor)) means this runs automatically when the dylib is loaded,
// before FCP's main() function. At this point most of FCP's frameworks aren't loaded
// yet, so we can only do early setup: logging, crash prevention patches, and
// registering for the "app finished launching" notification where the real work happens.
//

__attribute__((constructor))
static void SpliceKit_init(void) {
    SpliceKit_initLogging();
    SpliceKit_sentrySetLaunchPhase(@"constructor");

    SpliceKit_log(@"================================================");
    SpliceKit_log(@"SpliceKit v%s initializing...", SPLICEKIT_VERSION);
    SpliceKit_log(@"PID: %d", getpid());
    SpliceKit_log(@"Home: %@", NSHomeDirectory());

    // Log OS + FCP version early (before any swizzles) so crash logs are diagnosable.
    // SpliceKit_checkCompatibility logs FCP version too, but runs at didFinishLaunching
    // which is too late if the app crashes during startup.
    NSOperatingSystemVersion osv = [[NSProcessInfo processInfo] operatingSystemVersion];
    SpliceKit_log(@"macOS: %ld.%ld.%ld", (long)osv.majorVersion, (long)osv.minorVersion, (long)osv.patchVersion);
    NSDictionary *fcpInfo = [[NSBundle mainBundle] infoDictionary];
    SpliceKit_log(@"FCP: %@ (build %@)",
                  fcpInfo[@"CFBundleShortVersionString"] ?: @"?",
                  fcpInfo[@"CFBundleVersion"] ?: @"?");

    // Log signing status — critical for diagnosing CloudKit/entitlement crashes
    SecStaticCodeRef staticCode = NULL;
    OSStatus codeErr = SecStaticCodeCreateWithPath(
        (__bridge CFURLRef)[[NSBundle mainBundle] bundleURL], kSecCSDefaultFlags, &staticCode);
    if (codeErr == errSecSuccess && staticCode) {
        CFDictionaryRef signingInfo = NULL;
        OSStatus infoErr = SecCodeCopySigningInformation(
            (SecCodeRef)staticCode, kSecCSSigningInformation, &signingInfo);
        if (infoErr == errSecSuccess && signingInfo) {
            NSString *teamID = ((__bridge NSDictionary *)signingInfo)[@"teamid"];
            NSNumber *flags  = ((__bridge NSDictionary *)signingInfo)[@"flags"];
            SpliceKit_log(@"Signing: team=%@, flags=%@",
                          teamID ?: @"(ad-hoc)", flags ?: @"?");
            CFRelease(signingInfo);
        } else {
            SpliceKit_log(@"Signing: could not read (err=%d)", (int)infoErr);
        }
        CFRelease(staticCode);
    } else {
        SpliceKit_log(@"Signing: no static code (err=%d)", (int)codeErr);
    }

    // Log entitlements applied to this binary
    SpliceKit_logEntitlements();

    SpliceKit_log(@"================================================");

    sConstructorStart = CFAbsoluteTimeGetCurrent();

    SpliceKit_sentryStartRuntime();
    if (SpliceKit_sentryRuntimeEnabled()) {
        SpliceKit_log(@"Sentry runtime crash handling enabled");
    } else {
        // Fall back to the legacy crash logger when Sentry isn't configured.
        SpliceKit_installCrashHandlers();
        SpliceKit_log(@"Legacy crash handlers installed (NSException + SIGTRAP/SIGABRT/SIGSEGV/SIGBUS)");
    }

    // These patches need to land before FCP's own init code runs
    SpliceKit_disableCloudContent();
    SpliceKit_handleSubscriptionValidation();
    SpliceKit_fixShutdownHang();

    // Retry CloudContent swizzles at WillFinishLaunching — Swift classes that were
    // lazily registered at constructor time should be available now. This fires BEFORE
    // DidFinishLaunching where the CloudContent first-launch flow runs.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationWillFinishLaunchingNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            sWillLaunchTime = CFAbsoluteTimeGetCurrent();
            SpliceKit_sentrySetLaunchPhase(@"will-finish-launching");
            SpliceKit_log(@"WillFinishLaunching (%.2fs after constructor)",
                          sWillLaunchTime - sConstructorStart);
            SpliceKit_swizzleCloudContentClasses("willLaunch");
            SpliceKit_logCloudContentGuardSummary(@"will-launch");
            SpliceKit_logLoadedFrameworks();
            SpliceKit_bootstrapBRAWAtLaunchPhase(@"will-launch");
        }];

    // Everything else waits for the app to finish launching
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidFinishLaunchingNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            sDidLaunchTime = CFAbsoluteTimeGetCurrent();
            SpliceKit_appDidLaunch();
        }];

    SpliceKit_log(@"Constructor complete. Waiting for app launch...");
}
