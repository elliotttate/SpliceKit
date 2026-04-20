//
//  SpliceKitSentry.m
//  Crash and error reporting for the injected runtime.
//

#import "SpliceKitSentry.h"
#import "SpliceKit.h"
#import <Sentry/Sentry.h>
#import <dlfcn.h>

static BOOL sRuntimeStarted = NO;
static BOOL sRuntimeEnabled = NO;
static NSString *sRuntimeLaunchPhase = @"constructor";
static NSString *sRuntimeLastRPCMethod = nil;
static NSDictionary *sRuntimeConfig = nil;
static NSString * const kSpliceKitSentryDSN =
    @"https://56fa8ecde3c66d354606805ac2064c54@o4511243520966656.ingest.us.sentry.io/4511243525423104";

static NSString *SpliceKit_sentryScrubString(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) {
        return value;
    }
    NSString *result = [value copy];
    NSString *home = NSHomeDirectory();
    if (home.length > 0) {
        result = [result stringByReplacingOccurrencesOfString:home withString:@"~"];
    }
    return result;
}

static id SpliceKit_sentryScrubObject(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        return SpliceKit_sentryScrubString(value);
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *items = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            [items addObject:SpliceKit_sentryScrubObject(item) ?: [NSNull null]];
        }
        return items;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        for (id key in (NSDictionary *)value) {
            NSString *stringKey = [key isKindOfClass:[NSString class]] ? key : [key description];
            id scrubbed = SpliceKit_sentryScrubObject(((NSDictionary *)value)[key]);
            if (scrubbed) {
                dict[stringKey] = scrubbed;
            }
        }
        return dict;
    }
    return value;
}

static NSString *SpliceKit_sentryFrameworkResourcePath(void) {
    Dl_info info;
    if (dladdr((const void *)&SpliceKit_sentryStartRuntime, &info) == 0 || info.dli_fname == NULL) {
        return nil;
    }

    NSString *binaryPath = [NSString stringWithUTF8String:info.dli_fname];
    if (binaryPath.length == 0) {
        return nil;
    }

    return [[[binaryPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Resources"]
        stringByAppendingPathComponent:@"SpliceKitSentryConfig.plist"];
}

static NSDictionary *SpliceKit_loadRuntimeConfig(void) {
    if (sRuntimeConfig) {
        return sRuntimeConfig;
    }

    NSMutableDictionary *config = [NSMutableDictionary dictionary];

    NSArray<NSString *> *candidates = @[
        NSProcessInfo.processInfo.environment[@"SPLICEKIT_SENTRY_CONFIG"] ?: @"",
        SpliceKit_sentryFrameworkResourcePath() ?: @"",
        [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"SpliceKitSentryConfig.plist"] ?: @"",
        [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/SpliceKit"]
            stringByAppendingPathComponent:@"SpliceKitSentryConfig.plist"]
    ];

    for (NSString *candidate in candidates) {
        if (candidate.length == 0) continue;
        NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:candidate];
        if (loaded.count > 0) {
            [config addEntriesFromDictionary:loaded];
            break;
        }
    }

    NSString *environment = NSProcessInfo.processInfo.environment[@"SPLICEKIT_SENTRY_ENVIRONMENT"];
    if (environment.length > 0) config[@"Environment"] = environment;

    if (![config[@"ReleaseName"] isKindOfClass:[NSString class]] || [config[@"ReleaseName"] length] == 0) {
        config[@"ReleaseName"] = [NSString stringWithFormat:@"splicekit@%s", SPLICEKIT_VERSION];
    }
    if (![config[@"Environment"] isKindOfClass:[NSString class]] || [config[@"Environment"] length] == 0) {
        config[@"Environment"] = @"production";
    }

    sRuntimeConfig = [config copy];
    return sRuntimeConfig;
}

static NSString *SpliceKit_runtimeLogTail(NSString *name, NSUInteger maxCharacters) {
    NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit"]
        stringByAppendingPathComponent:name];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0) {
        return nil;
    }
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length <= maxCharacters) {
        return SpliceKit_sentryScrubString(trimmed);
    }
    return SpliceKit_sentryScrubString([trimmed substringFromIndex:trimmed.length - maxCharacters]);
}

static NSString *SpliceKit_runtimeCacheDirectory(void) {
    NSString *cacheDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/SpliceKit/Sentry/runtime"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return cacheDir;
}

static BOOL SpliceKit_eventTouchesSpliceKit(SentryEvent *event) {
    BOOL (^frameMatches)(SentryFrame *) = ^BOOL(SentryFrame *frame) {
        NSArray<NSString *> *parts = @[
            frame.package ?: @"",
            frame.module ?: @"",
            frame.function ?: @"",
            frame.fileName ?: @""
        ];
        for (NSString *part in parts) {
            if ([part rangeOfString:@"SpliceKit" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return YES;
            }
        }
        return NO;
    };

    for (SentryThread *thread in event.threads ?: @[]) {
        for (SentryFrame *frame in thread.stacktrace.frames ?: @[]) {
            if (frameMatches(frame)) {
                return YES;
            }
        }
    }
    for (SentryException *exception in event.exceptions ?: @[]) {
        for (SentryFrame *frame in exception.stacktrace.frames ?: @[]) {
            if (frameMatches(frame)) {
                return YES;
            }
        }
    }
    return NO;
}

static SentryEvent *SpliceKit_runtimeBeforeSend(SentryEvent *event) {
    event.user = nil;

    NSMutableDictionary<NSString *, NSString *> *tags = [event.tags mutableCopy] ?: [NSMutableDictionary dictionary];
    tags[@"component"] = @"runtime";
    tags[@"splicekit_loaded"] = @"true";
    tags[@"startup_phase"] = sRuntimeLaunchPhase ?: @"unknown";
    tags[@"splicekit_in_stack"] = SpliceKit_eventTouchesSpliceKit(event) ? @"true" : @"false";
    if (sRuntimeLastRPCMethod.length > 0) {
        tags[@"last_rpc_method"] = SpliceKit_sentryScrubString(sRuntimeLastRPCMethod);
    }
    event.tags = tags;

    NSMutableDictionary *extra = [event.extra mutableCopy] ?: [NSMutableDictionary dictionary];
    extra[@"splicekit_launch_phase"] = sRuntimeLaunchPhase ?: @"unknown";
    if (sRuntimeLastRPCMethod.length > 0) {
        extra[@"splicekit_last_rpc_method"] = SpliceKit_sentryScrubString(sRuntimeLastRPCMethod);
    }
    event.extra = SpliceKit_sentryScrubObject(extra);

    if (event.message.message.length > 0) {
        event.message.message = SpliceKit_sentryScrubString(event.message.message);
    }
    if (event.logger.length > 0) {
        event.logger = SpliceKit_sentryScrubString(event.logger);
    }
    if (event.extra) {
        event.extra = SpliceKit_sentryScrubObject(event.extra);
    }

    return event;
}

static void SpliceKit_configureRuntimeScope(SentryScope *scope, NSString *context, NSDictionary *data) {
    [scope setTagValue:@"runtime" forKey:@"component"];
    [scope setTagValue:@"true" forKey:@"splicekit_loaded"];
    [scope setTagValue:sRuntimeLaunchPhase ?: @"unknown" forKey:@"startup_phase"];
    if (context.length > 0) {
        [scope setTagValue:SpliceKit_sentryScrubString(context) forKey:@"splicekit_context"];
    }
    if (sRuntimeLastRPCMethod.length > 0) {
        [scope setTagValue:SpliceKit_sentryScrubString(sRuntimeLastRPCMethod) forKey:@"last_rpc_method"];
    }
    if (data.count > 0) {
        [scope setContextValue:SpliceKit_sentryScrubObject(data) forKey:@"splicekit"];
    }
}

BOOL SpliceKit_sentryRuntimeEnabled(void) {
    return sRuntimeEnabled;
}

void SpliceKit_sentrySetLaunchPhase(NSString *phase) {
    sRuntimeLaunchPhase = phase.length > 0 ? [phase copy] : @"unknown";
    if (!sRuntimeEnabled) return;
    [SentrySDK configureScope:^(SentryScope *scope) {
        [scope setTagValue:sRuntimeLaunchPhase forKey:@"startup_phase"];
    }];
}

void SpliceKit_sentrySetLastRPCMethod(NSString *method) {
    sRuntimeLastRPCMethod = method.length > 0 ? [method copy] : nil;
    if (!sRuntimeEnabled || method.length == 0) return;
    [SentrySDK configureScope:^(SentryScope *scope) {
        [scope setTagValue:SpliceKit_sentryScrubString(method) forKey:@"last_rpc_method"];
    }];
}

void SpliceKit_sentryAddBreadcrumb(NSString *category, NSString *message, NSDictionary *data) {
    if (!sRuntimeEnabled || message.length == 0) return;

    SentryBreadcrumb *crumb = [[SentryBreadcrumb alloc] initWithLevel:kSentryLevelInfo
                                                             category:category.length > 0 ? category : @"splicekit"];
    crumb.type = @"default";
    crumb.origin = @"splicekit.runtime";
    crumb.message = SpliceKit_sentryScrubString(message);
    if (data.count > 0) {
        crumb.data = SpliceKit_sentryScrubObject(data);
    }
    [SentrySDK addBreadcrumb:crumb];
}

void SpliceKit_sentryCaptureMessage(NSString *message, NSString *context, NSDictionary *data) {
    if (!sRuntimeEnabled || message.length == 0) return;
    [SentrySDK captureMessage:SpliceKit_sentryScrubString(message) withScopeBlock:^(SentryScope *scope) {
        SpliceKit_configureRuntimeScope(scope, context, data);
        [scope setLevel:kSentryLevelError];
    }];
}

void SpliceKit_sentryCaptureException(NSException *exception, NSString *context, NSDictionary *data) {
    if (!sRuntimeEnabled || exception == nil) return;
    [SentrySDK captureException:exception withScopeBlock:^(SentryScope *scope) {
        SpliceKit_configureRuntimeScope(scope, context, data);
        [scope setLevel:kSentryLevelError];
    }];
}

void SpliceKit_sentryCaptureNSError(NSError *error, NSString *context, NSDictionary *data) {
    if (!sRuntimeEnabled || error == nil) return;
    [SentrySDK captureError:error withScopeBlock:^(SentryScope *scope) {
        SpliceKit_configureRuntimeScope(scope, context, data);
        [scope setLevel:kSentryLevelError];
    }];
}

void SpliceKit_sentryStartRuntime(void) {
    if (sRuntimeStarted) {
        return;
    }
    sRuntimeStarted = YES;

    NSDictionary *config = SpliceKit_loadRuntimeConfig();
    NSString *releaseName = config[@"ReleaseName"];
    NSString *environment = config[@"Environment"];
    NSString *cacheDirectoryPath = SpliceKit_runtimeCacheDirectory();
    __block BOOL crashedLastRun = NO;
    __block NSDictionary *crashSummary = nil;

    [SentrySDK startWithConfigureOptions:^(SentryOptions *options) {
        options.dsn = kSpliceKitSentryDSN;
        options.debug = YES;
        options.releaseName = releaseName;
        options.environment = environment;
        options.dist = [NSString stringWithUTF8String:SPLICEKIT_VERSION];
        options.cacheDirectoryPath = cacheDirectoryPath;
        options.sendDefaultPii = YES;
        options.sampleRate = @1.0;
        options.enableCrashHandler = YES;
        options.enableUncaughtNSExceptionReporting = YES;
        options.enableSwizzling = YES;
        options.enableAutoSessionTracking = NO;
        options.enableNetworkBreadcrumbs = NO;
        options.enableNetworkTracking = NO;
        options.enableCaptureFailedRequests = NO;
        options.enableAppHangTracking = NO;
        options.enableMetricKit = NO;
        options.tracesSampleRate = @0;
        options.maxBreadcrumbs = 150;
        options.beforeSend = ^SentryEvent *_Nullable(SentryEvent *event) {
            return SpliceKit_runtimeBeforeSend(event);
        };
        options.onLastRunStatusDetermined = ^(enum SentryLastRunStatus status, SentryEvent * _Nullable crashEvent) {
            if (status == SentryLastRunStatusDidCrash) {
                crashedLastRun = YES;
                if (crashEvent.message.message.length > 0) {
                    crashSummary = @{@"message": SpliceKit_sentryScrubString(crashEvent.message.message)};
                }
            }
        };
    }];

    sRuntimeEnabled = [SentrySDK isEnabled];
    if (!sRuntimeEnabled) {
        SpliceKit_log(@"Sentry runtime failed to start");
        return;
    }

    [SentrySDK configureScope:^(SentryScope *scope) {
        [scope setTagValue:@"runtime" forKey:@"component"];
        [scope setTagValue:@"Final Cut Pro" forKey:@"host_app"];
        [scope setTagValue:@"true" forKey:@"splicekit_loaded"];
        [scope setTagValue:[NSString stringWithUTF8String:SPLICEKIT_VERSION] forKey:@"splicekit_version"];
        [scope setTagValue:sRuntimeLaunchPhase forKey:@"startup_phase"];
        NSDictionary *fcpInfo = [[NSBundle mainBundle] infoDictionary];
        NSString *fcpVersion = [NSString stringWithFormat:@"%@ (%@)",
                                fcpInfo[@"CFBundleShortVersionString"] ?: @"?",
                                fcpInfo[@"CFBundleVersion"] ?: @"?"];
        [scope setTagValue:SpliceKit_sentryScrubString(fcpVersion) forKey:@"fcp_version"];
        [scope setEnvironment:environment];
    }];

    if (crashedLastRun) {
        NSMutableDictionary *data = [NSMutableDictionary dictionary];
        NSString *tail = SpliceKit_runtimeLogTail(@"splicekit.previous.log", 4000);
        if (tail.length > 0) {
            data[@"previous_log_tail"] = tail;
        }
        if (crashSummary.count > 0) {
            data[@"previous_crash_summary"] = crashSummary;
        }
        SpliceKit_sentryCaptureMessage(@"SpliceKit detected that Final Cut Pro crashed on the previous run",
                                       @"runtime.last_run_crash",
                                       data);
    }

    SpliceKit_log(@"Sentry runtime enabled (%@)", environment);
}
