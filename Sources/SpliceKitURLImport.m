//
//  SpliceKitURLImport.m
//  Native URL ingest pipeline for SpliceKit.
//

#import "SpliceKitURLImport.h"
#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>

extern NSDictionary *SpliceKit_handleRequest(NSDictionary *request);
extern id SpliceKit_getActiveTimelineModule(void);

#if defined(__x86_64__)
#define SPLICEKIT_URLIMPORT_STRET_MSG objc_msgSend_stret
#else
#define SPLICEKIT_URLIMPORT_STRET_MSG objc_msgSend
#endif

static NSString * const SpliceKitURLImportStateQueued = @"queued";
static NSString * const SpliceKitURLImportStateResolving = @"resolving";
static NSString * const SpliceKitURLImportStateDownloading = @"downloading";
static NSString * const SpliceKitURLImportStateNormalizing = @"normalizing";
static NSString * const SpliceKitURLImportStateImporting = @"importing";
static NSString * const SpliceKitURLImportStateInserting = @"inserting";
static NSString * const SpliceKitURLImportStateCompleted = @"completed";
static NSString * const SpliceKitURLImportStateFailed = @"failed";
static NSString * const SpliceKitURLImportStateCancelled = @"cancelled";

static NSString *SpliceKitURLImportStringFromData(NSData *data);

static NSString *SpliceKitURLImportString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSString *SpliceKitURLImportDiagnosticString(id value) {
    if (!value || value == [NSNull null]) return @"";
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSString *message = SpliceKitURLImportString(value[@"message"]);
        if (message.length > 0) return message;
        if ([NSJSONSerialization isValidJSONObject:value]) {
            NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
            NSString *jsonString = SpliceKitURLImportStringFromData(json);
            if (jsonString.length > 0) return jsonString;
        }
    }
    if ([value isKindOfClass:[NSArray class]] && [NSJSONSerialization isValidJSONObject:value]) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        NSString *jsonString = SpliceKitURLImportStringFromData(json);
        if (jsonString.length > 0) return jsonString;
    }
    NSString *description = [[value description] copy];
    return [description isKindOfClass:[NSString class]] ? description : @"";
}

static NSString *SpliceKitURLImportTrimmedString(id value) {
    return [SpliceKitURLImportString(value)
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *SpliceKitURLImportNormalizeURLString(id value) {
    NSString *raw = SpliceKitURLImportTrimmedString(value);
    if (raw.length == 0) return @"";

    NSError *detectorError = nil;
    NSDataDetector *detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink
                                                               error:&detectorError];
    if (!detectorError && detector) {
        NSTextCheckingResult *match = [detector firstMatchInString:raw
                                                           options:0
                                                             range:NSMakeRange(0, raw.length)];
        if (match.URL.absoluteString.length > 0) {
            return match.URL.absoluteString;
        }
    }

    NSArray<NSString *> *parts = [raw componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableString *joined = [NSMutableString string];
    for (NSString *part in parts) {
        if (part.length > 0) [joined appendString:part];
    }
    return [joined copy];
}

static NSString *SpliceKitURLImportSanitizeFilename(NSString *input) {
    NSString *trimmed = SpliceKitURLImportTrimmedString(input);
    if (trimmed.length == 0) return @"Imported Clip";

    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>"];
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByCharactersInSet:bad];
    NSString *joined = [[parts componentsJoinedByString:@"-"]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    while ([joined containsString:@"  "]) {
        joined = [joined stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    while ([joined containsString:@"--"]) {
        joined = [joined stringByReplacingOccurrencesOfString:@"--" withString:@"-"];
    }

    if (joined.length == 0) return @"Imported Clip";
    return joined;
}

static NSString *SpliceKitURLImportEscapeXML(NSString *input) {
    NSString *s = SpliceKitURLImportString(input);
    s = [s stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    s = [s stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    s = [s stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    s = [s stringByReplacingOccurrencesOfString:@"'" withString:@"&apos;"];
    return s;
}

static NSString *SpliceKitURLImportCMTimeString(CMTime time, NSString *fallback) {
    if (CMTIME_IS_VALID(time) && !CMTIME_IS_INDEFINITE(time) && time.timescale > 0 && time.value >= 0) {
        return [NSString stringWithFormat:@"%lld/%ds", time.value, time.timescale];
    }
    return fallback ?: @"2400/2400s";
}

static BOOL SpliceKitURLImportIsDirectMediaExtension(NSString *extension) {
    static NSSet<NSString *> *allowed = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowed = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"webm"]];
    });
    return [allowed containsObject:[extension lowercaseString]];
}

static NSString *SpliceKitURLImportEnsureDirectory(NSString *path) {
    if (path.length == 0) return @"";
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return path;
}

static NSString *SpliceKitURLImportToolsDirectory(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/SpliceKit/tools"];
}

static NSString *SpliceKitURLImportSharedBaseDirectory(void) {
    return SpliceKitURLImportEnsureDirectory([NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support/SpliceKit/URLImports"]);
}

static NSString *SpliceKitURLImportSharedDownloadsDirectory(void) {
    return SpliceKitURLImportEnsureDirectory([SpliceKitURLImportSharedBaseDirectory()
        stringByAppendingPathComponent:@"downloads"]);
}

static NSString *SpliceKitURLImportExecutablePath(NSArray<NSString *> *candidates) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in candidates) {
        if ([fm isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

static NSString *SpliceKitURLImportYTDLPPath(void) {
    NSString *tools = SpliceKitURLImportToolsDirectory();
    return SpliceKitURLImportExecutablePath(@[
        [tools stringByAppendingPathComponent:@"yt-dlp"],
        @"/opt/homebrew/bin/yt-dlp",
        @"/usr/local/bin/yt-dlp",
        @"/usr/bin/yt-dlp",
    ]);
}

static NSString *SpliceKitURLImportFFmpegPath(void) {
    NSString *tools = SpliceKitURLImportToolsDirectory();
    return SpliceKitURLImportExecutablePath(@[
        [tools stringByAppendingPathComponent:@"ffmpeg"],
        @"/opt/homebrew/bin/ffmpeg",
        @"/usr/local/bin/ffmpeg",
        @"/usr/bin/ffmpeg",
    ]);
}

static NSString *SpliceKitURLImportProviderDependencyMessage(NSString *provider) {
    NSString *label = provider.length > 0 ? provider : @"Provider";
    return [NSString stringWithFormat:
        @"%@ import requires yt-dlp and ffmpeg. Install them with `brew install yt-dlp ffmpeg`, then re-run `make deploy` so SpliceKit can see them in ~/Applications/SpliceKit/tools/.",
        label];
}

static NSString *SpliceKitURLImportStringFromData(NSData *data) {
    if (data.length == 0) return @"";
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (string.length > 0) return string;
    string = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return string ?: @"";
}

static NSDictionary *SpliceKitURLImportProviderMetadata(NSString *ytDLP,
                                                        NSURL *url,
                                                        NSString *provider,
                                                        NSString **outError) {
    if (ytDLP.length == 0 || !url) {
        if (outError) *outError = @"Provider metadata check could not start.";
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:ytDLP];
    task.arguments = @[
        @"--skip-download",
        @"--no-playlist",
        @"--no-warnings",
        @"--print", @"%(live_status)s\t%(is_live)s\t%(was_live)s\t%(title)s",
        url.absoluteString ?: @""
    ];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (outError) {
            *outError = launchError.localizedDescription ?: @"Could not launch yt-dlp metadata check.";
        }
        return nil;
    }

    [task waitUntilExit];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = SpliceKitURLImportTrimmedString(SpliceKitURLImportStringFromData(data));
    if (task.terminationStatus != 0) {
        if (outError) {
            *outError = output.length > 0
                ? output
                : [NSString stringWithFormat:@"%@ metadata check failed.", provider ?: @"Provider"];
        }
        return nil;
    }

    NSArray<NSString *> *lines = [output componentsSeparatedByCharactersInSet:
        [NSCharacterSet newlineCharacterSet]];
    NSString *lastLine = @"";
    for (NSString *line in [lines reverseObjectEnumerator]) {
        NSString *trimmed = SpliceKitURLImportTrimmedString(line);
        if (trimmed.length > 0) {
            lastLine = trimmed;
            break;
        }
    }

    if (lastLine.length == 0) return @{};

    NSArray<NSString *> *parts = [lastLine componentsSeparatedByString:@"\t"];
    NSString *liveStatus = parts.count > 0 ? SpliceKitURLImportTrimmedString(parts[0]) : @"";
    NSString *isLive = parts.count > 1 ? SpliceKitURLImportTrimmedString(parts[1]) : @"";
    NSString *wasLive = parts.count > 2 ? SpliceKitURLImportTrimmedString(parts[2]) : @"";
    NSString *title = @"";
    if (parts.count > 3) {
        title = [[parts subarrayWithRange:NSMakeRange(3, parts.count - 3)]
            componentsJoinedByString:@"\t"];
        title = SpliceKitURLImportTrimmedString(title);
    }

    return @{
        @"live_status": liveStatus ?: @"",
        @"is_live": isLive ?: @"",
        @"was_live": wasLive ?: @"",
        @"title": title ?: @""
    };
}

static double SpliceKitURLImportPercentFromLine(NSString *line) {
    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"([0-9]+(?:\\.[0-9]+)?)%"
                                                         options:0
                                                           error:nil];
    });
    NSTextCheckingResult *match = [regex firstMatchInString:line
                                                    options:0
                                                      range:NSMakeRange(0, line.length)];
    if (!match || match.numberOfRanges < 2) return -1.0;
    NSString *number = [line substringWithRange:[match rangeAtIndex:1]];
    return [number doubleValue];
}

static NSString *SpliceKitURLImportDownloadedFileMatchingPrefix(NSString *directory, NSString *prefix) {
    if (directory.length == 0 || prefix.length == 0) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:directory error:nil];
    NSString *bestPath = nil;
    NSDate *bestDate = nil;

    for (NSString *name in entries) {
        if (![name hasPrefix:prefix]) continue;
        if ([name hasSuffix:@".part"] || [name hasSuffix:@".ytdl"] || [name hasSuffix:@".tmp"]) continue;

        NSString *path = [directory stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        if ([attrs[NSFileType] isEqualToString:NSFileTypeDirectory]) continue;

        NSDate *modDate = attrs[NSFileModificationDate] ?: [NSDate distantPast];
        if (!bestPath || [modDate compare:bestDate] == NSOrderedDescending) {
            bestPath = path;
            bestDate = modDate;
        }
    }

    return bestPath;
}

@interface SpliceKitURLImportJob : NSObject
@property (nonatomic, copy) NSString *jobID;
@property (nonatomic, copy) NSString *sourceURL;
@property (nonatomic, copy) NSString *sourceType;
@property (nonatomic, copy) NSString *state;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSString *mode;
@property (nonatomic, copy) NSString *targetEvent;
@property (nonatomic, copy) NSString *titleOverride;
@property (nonatomic, copy) NSString *clipName;
@property (nonatomic, copy) NSString *downloadPath;
@property (nonatomic, copy) NSString *normalizedPath;
@property (nonatomic, copy) NSString *errorMessage;
@property (nonatomic, assign) double progress;
@property (nonatomic, assign) BOOL success;
@property (nonatomic, assign) BOOL imported;
@property (nonatomic, assign) BOOL timelineInserted;
@property (nonatomic, assign) BOOL transcoded;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, strong) NSDate *createdAt;
@property (nonatomic, strong) NSDate *updatedAt;
@property (nonatomic, strong) NSTask *resolverTask;
@property (nonatomic, strong) NSURLSessionDownloadTask *downloadTask;
@property (nonatomic, strong) AVAssetExportSession *exportSession;
@property (nonatomic) dispatch_semaphore_t completionSemaphore;
- (NSDictionary *)snapshot;
- (BOOL)isFinished;
@end

@implementation SpliceKitURLImportJob

- (instancetype)init {
    self = [super init];
    if (self) {
        _createdAt = [NSDate date];
        _updatedAt = [NSDate date];
        _completionSemaphore = dispatch_semaphore_create(0);
        _state = SpliceKitURLImportStateQueued;
        _message = @"Queued";
    }
    return self;
}

- (NSDictionary *)snapshot {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"job_id"] = self.jobID ?: @"";
    result[@"success"] = @(self.success);
    result[@"state"] = SpliceKitURLImportDiagnosticString(self.state);
    result[@"progress"] = @((self.progress < 0.0) ? 0.0 : (self.progress > 1.0 ? 1.0 : self.progress));
    result[@"source_url"] = SpliceKitURLImportDiagnosticString(self.sourceURL);
    result[@"source_type"] = SpliceKitURLImportDiagnosticString(self.sourceType ?: @"unknown");
    result[@"mode"] = SpliceKitURLImportDiagnosticString(self.mode ?: @"import_only");
    result[@"target_event"] = SpliceKitURLImportDiagnosticString(self.targetEvent);
    result[@"title"] = SpliceKitURLImportDiagnosticString(self.clipName);
    result[@"download_path"] = SpliceKitURLImportDiagnosticString(self.downloadPath);
    result[@"normalized_path"] = SpliceKitURLImportDiagnosticString(self.normalizedPath);
    result[@"transcoded"] = @(self.transcoded);
    result[@"imported"] = @(self.imported);
    result[@"timeline_inserted"] = @(self.timelineInserted);
    result[@"message"] = SpliceKitURLImportDiagnosticString(self.message);
    result[@"created_at"] = @([self.createdAt timeIntervalSince1970]);
    result[@"updated_at"] = @([self.updatedAt timeIntervalSince1970]);
    NSString *errorText = SpliceKitURLImportDiagnosticString(self.errorMessage);
    if (errorText.length > 0) result[@"error"] = errorText;
    return result;
}

- (BOOL)isFinished {
    return [self.state isEqualToString:SpliceKitURLImportStateCompleted] ||
           [self.state isEqualToString:SpliceKitURLImportStateFailed] ||
           [self.state isEqualToString:SpliceKitURLImportStateCancelled];
}

@end

typedef void (^SpliceKitURLImportResolverProgressBlock)(NSString *message, double progress);
typedef void (^SpliceKitURLImportResolverCompletionBlock)(NSURL *downloadURL,
                                                          NSString *resolvedTitle,
                                                          NSString *localPath,
                                                          NSString *errorMessage);

@protocol SpliceKitURLResolver <NSObject>
- (NSString *)sourceType;
- (BOOL)canResolveURL:(NSURL *)url;
- (void)resolveURL:(NSURL *)url
               job:(SpliceKitURLImportJob *)job
          progress:(SpliceKitURLImportResolverProgressBlock)progress
        completion:(SpliceKitURLImportResolverCompletionBlock)completion;
@end

@interface SpliceKitDirectFileResolver : NSObject <SpliceKitURLResolver>
@end

@interface SpliceKitYouTubeResolver : NSObject <SpliceKitURLResolver>
@end

@interface SpliceKitVimeoResolver : NSObject <SpliceKitURLResolver>
@end

static void SpliceKitURLImportResolveProviderURL(NSString *provider,
                                                 NSURL *url,
                                                 SpliceKitURLImportJob *job,
                                                 SpliceKitURLImportResolverProgressBlock progress,
                                                 SpliceKitURLImportResolverCompletionBlock completion) {
    NSString *ytDLP = SpliceKitURLImportYTDLPPath();
    NSString *ffmpeg = SpliceKitURLImportFFmpegPath();
    if (ytDLP.length == 0 || ffmpeg.length == 0) {
        completion(nil, nil, nil, SpliceKitURLImportProviderDependencyMessage(provider));
        return;
    }

    if (progress) {
        progress([NSString stringWithFormat:@"Resolving %@ stream...", provider ?: @"provider"], 0.04);
    }
    SpliceKit_log(@"[URLImport] Starting %@ resolve for %@", provider ?: @"provider", url.absoluteString ?: @"");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (job.cancelled) {
            completion(nil, nil, nil, @"URL import was cancelled.");
            return;
        }
        NSString *resolvedTitle = nil;

        if (progress) {
            progress([NSString stringWithFormat:@"Checking %@ stream metadata...", provider ?: @"provider"], 0.05);
        }

        NSString *metadataError = nil;
        NSDictionary *metadata = SpliceKitURLImportProviderMetadata(ytDLP, url, provider, &metadataError);
        NSString *liveStatus = [SpliceKitURLImportTrimmedString(metadata[@"live_status"]) lowercaseString];
        NSString *isLive = [SpliceKitURLImportTrimmedString(metadata[@"is_live"]) lowercaseString];
        NSString *wasLive = [SpliceKitURLImportTrimmedString(metadata[@"was_live"]) lowercaseString];
        NSString *metadataTitle = SpliceKitURLImportTrimmedString(metadata[@"title"]);
        if (metadataTitle.length > 0) resolvedTitle = metadataTitle;

        BOOL providerIsLive = [liveStatus isEqualToString:@"is_live"] ||
                              [liveStatus isEqualToString:@"is_upcoming"] ||
                              [isLive isEqualToString:@"true"] ||
                              [isLive isEqualToString:@"yes"] ||
                              [isLive isEqualToString:@"1"];
        BOOL providerWasLive = [liveStatus isEqualToString:@"post_live"] ||
                               [wasLive isEqualToString:@"true"] ||
                               [wasLive isEqualToString:@"yes"] ||
                               [wasLive isEqualToString:@"1"];

        if (providerIsLive && !providerWasLive) {
            NSString *label = resolvedTitle.length > 0 ? resolvedTitle : (provider ?: @"This URL");
            NSString *detail = [NSString stringWithFormat:
                @"%@ is a live or upcoming stream. SpliceKit URL Import currently supports finished videos, not active live streams.",
                label];
            SpliceKit_log(@"[URLImport] %@ metadata rejected live stream: %@", provider ?: @"Provider", detail);
            completion(nil, resolvedTitle, nil, detail);
            return;
        }

        if (metadataError.length > 0) {
            SpliceKit_log(@"[URLImport] %@ metadata probe failed, continuing with download path: %@",
                          provider ?: @"Provider", metadataError);
        }

        NSString *baseName = job.titleOverride.length > 0
            ? job.titleOverride
            : (resolvedTitle.length > 0 ? resolvedTitle : job.clipName);
        baseName = SpliceKitURLImportSanitizeFilename(baseName);
        NSString *prefix = [NSString stringWithFormat:@"%@-%@",
            baseName,
            [[[NSUUID UUID] UUIDString] substringToIndex:8]];
        NSString *downloadsDir = SpliceKitURLImportSharedDownloadsDirectory();
        NSString *outputTemplate = [downloadsDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.%%(ext)s", prefix]];

        NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:
            @"--newline",
            @"--no-playlist",
            @"--restrict-filenames",
            @"--no-warnings",
            @"--output", outputTemplate,
            @"-f", @"b[ext=mp4]/bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b",
            @"--merge-output-format", @"mp4",
            @"--ffmpeg-location", [ffmpeg stringByDeletingLastPathComponent],
            url.absoluteString ?: @"",
            nil];

        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:ytDLP];
        task.arguments = args;

        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = pipe;

        NSMutableString *logBuffer = [NSMutableString string];
        __block double lastMappedProgress = 0.08;
        __block BOOL sawFragmentedDownload = NO;
        NSFileHandle *readHandle = [pipe fileHandleForReading];
        readHandle.readabilityHandler = ^(NSFileHandle *handle) {
            NSData *data = [handle availableData];
            if (data.length == 0) return;

            NSString *chunk = SpliceKitURLImportStringFromData(data);
            if (chunk.length == 0) return;

            @synchronized (logBuffer) {
                [logBuffer appendString:chunk];
            }

            NSArray<NSString *> *lines = [chunk componentsSeparatedByCharactersInSet:
                [NSCharacterSet newlineCharacterSet]];
            for (NSString *rawLine in lines) {
                NSString *line = SpliceKitURLImportTrimmedString(rawLine);
                if (line.length == 0) continue;

                double percent = SpliceKitURLImportPercentFromLine(line);
                if (percent >= 0.0) {
                    double mapped = 0.08 + MIN(MAX(percent, 0.0), 100.0) / 100.0 * 0.64;
                    if (progress && (mapped - lastMappedProgress >= 0.01 || mapped >= 0.72)) {
                        lastMappedProgress = mapped;
                        progress([NSString stringWithFormat:@"Downloading %@ media...", provider ?: @"provider"],
                                 mapped);
                    }
                    continue;
                }

                NSString *lower = [line lowercaseString];
                if ([lower containsString:@"extracting url"] || [lower containsString:@"downloading webpage"]) {
                    if (progress) progress([NSString stringWithFormat:@"Resolving %@ stream...", provider ?: @"provider"], 0.05);
                } else if ([lower containsString:@"fragment"] ||
                           [lower containsString:@".part-frag"] ||
                           [lower containsString:@"hls"]) {
                    sawFragmentedDownload = YES;
                    double mapped = MIN(MAX(lastMappedProgress, 0.72) + 0.01, 0.79);
                    if (progress && mapped - lastMappedProgress >= 0.005) {
                        lastMappedProgress = mapped;
                        progress([NSString stringWithFormat:@"Downloading %@ media fragments...", provider ?: @"provider"],
                                 mapped);
                    }
                } else if ([lower containsString:@"recoding video"] ||
                           [lower containsString:@"post-process"] ||
                           [lower containsString:@"merging formats"]) {
                    lastMappedProgress = MAX(lastMappedProgress, 0.82);
                    if (progress) progress(@"Converting provider download to MP4...", lastMappedProgress);
                }
            }
        };

        task.terminationHandler = ^(__unused NSTask *finishedTask) {
            readHandle.readabilityHandler = nil;
            NSData *tail = [readHandle readDataToEndOfFile];
            if (tail.length > 0) {
                NSString *tailString = SpliceKitURLImportStringFromData(tail);
                @synchronized (logBuffer) {
                    [logBuffer appendString:tailString ?: @""];
                }
            }

            @synchronized (job) {
                job.resolverTask = nil;
            }

            if (job.cancelled) {
                completion(nil, resolvedTitle, nil, @"URL import was cancelled.");
                return;
            }

            NSString *fullLog = nil;
            @synchronized (logBuffer) {
                fullLog = [logBuffer copy];
            }
            NSString *trimmedLog = SpliceKitURLImportTrimmedString(fullLog);

            if (task.terminationStatus != 0) {
                NSString *detail = trimmedLog.length > 0
                    ? trimmedLog
                    : [NSString stringWithFormat:@"%@ download failed through yt-dlp.", provider ?: @"Provider"];
                SpliceKit_log(@"[URLImport] %@ download failed: %@", provider ?: @"Provider", detail);
                completion(nil, resolvedTitle, nil, detail);
                return;
            }

            NSString *downloadedFile = SpliceKitURLImportDownloadedFileMatchingPrefix(downloadsDir, prefix);
            if (downloadedFile.length == 0) {
                SpliceKit_log(@"[URLImport] %@ download completed but no file matched prefix %@", provider ?: @"Provider", prefix);
                completion(nil, resolvedTitle, nil,
                           @"yt-dlp finished, but SpliceKit could not locate the downloaded file in its cache.");
                return;
            }

            SpliceKit_log(@"[URLImport] %@ download complete: %@", provider ?: @"Provider", downloadedFile);
            if (progress) {
                double finalDownloadProgress = sawFragmentedDownload ? 0.84 : 0.76;
                progress(@"Provider download complete. Inspecting media...", finalDownloadProgress);
            }
            completion(nil, resolvedTitle, downloadedFile, nil);
        };

        NSError *launchError = nil;
        @synchronized (job) {
            job.resolverTask = task;
        }
        SpliceKit_log(@"[URLImport] Launching %@ download task via yt-dlp for %@",
                      provider ?: @"provider", url.absoluteString ?: @"");
        if (![task launchAndReturnError:&launchError]) {
            readHandle.readabilityHandler = nil;
            @synchronized (job) {
                job.resolverTask = nil;
            }
            completion(nil,
                       resolvedTitle,
                       nil,
                       launchError.localizedDescription ?: @"Could not launch yt-dlp download task.");
            return;
        }
    });
}

@implementation SpliceKitDirectFileResolver

- (NSString *)sourceType { return @"direct_file"; }

- (BOOL)canResolveURL:(NSURL *)url {
    NSString *ext = [[url pathExtension] lowercaseString];
    return SpliceKitURLImportIsDirectMediaExtension(ext);
}

- (void)resolveURL:(NSURL *)url
               job:(SpliceKitURLImportJob *)job
          progress:(SpliceKitURLImportResolverProgressBlock)progress
        completion:(SpliceKitURLImportResolverCompletionBlock)completion {
    (void)job;
    (void)progress;
    NSString *candidate = [[url lastPathComponent] stringByDeletingPathExtension];
    completion(url, candidate, nil, nil);
}

@end

@implementation SpliceKitYouTubeResolver

- (NSString *)sourceType { return @"youtube"; }

- (BOOL)canResolveURL:(NSURL *)url {
    NSString *host = [[url host] lowercaseString];
    return [host containsString:@"youtube.com"] || [host containsString:@"youtu.be"];
}

- (void)resolveURL:(NSURL *)url
               job:(SpliceKitURLImportJob *)job
          progress:(SpliceKitURLImportResolverProgressBlock)progress
        completion:(SpliceKitURLImportResolverCompletionBlock)completion {
    SpliceKitURLImportResolveProviderURL(@"YouTube", url, job, progress, completion);
}

@end

@implementation SpliceKitVimeoResolver

- (NSString *)sourceType { return @"vimeo"; }

- (BOOL)canResolveURL:(NSURL *)url {
    NSString *host = [[url host] lowercaseString];
    return [host containsString:@"vimeo.com"];
}

- (void)resolveURL:(NSURL *)url
               job:(SpliceKitURLImportJob *)job
          progress:(SpliceKitURLImportResolverProgressBlock)progress
        completion:(SpliceKitURLImportResolverCompletionBlock)completion {
    SpliceKitURLImportResolveProviderURL(@"Vimeo", url, job, progress, completion);
}

@end

@interface SpliceKitURLImportService : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, SpliceKitURLImportJob *> *jobs;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *taskToJob;
@property (nonatomic, strong) NSArray<id<SpliceKitURLResolver>> *resolvers;
+ (instancetype)sharedService;
- (NSDictionary *)startImportWithParams:(NSDictionary *)params waitForCompletion:(BOOL)wait;
- (NSDictionary *)statusForJobID:(NSString *)jobID;
- (NSDictionary *)cancelJobID:(NSString *)jobID;
@end

@implementation SpliceKitURLImportService

+ (instancetype)sharedService {
    static SpliceKitURLImportService *service = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        service = [[self alloc] init];
    });
    return service;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateQueue = dispatch_queue_create("com.splicekit.urlimport.state", DISPATCH_QUEUE_SERIAL);
        _jobs = [NSMutableDictionary dictionary];
        _taskToJob = [NSMutableDictionary dictionary];
        _resolvers = @[
            [[SpliceKitDirectFileResolver alloc] init],
            [[SpliceKitYouTubeResolver alloc] init],
            [[SpliceKitVimeoResolver alloc] init],
        ];

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 120.0;
        config.timeoutIntervalForResource = 1800.0;
        config.HTTPMaximumConnectionsPerHost = 4;

        NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
        delegateQueue.maxConcurrentOperationCount = 1;
        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:delegateQueue];
    }
    return self;
}

- (NSString *)baseDirectory {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/SpliceKit/URLImports"];
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return path;
}

- (NSString *)downloadsDirectory {
    NSString *path = [[self baseDirectory] stringByAppendingPathComponent:@"downloads"];
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return path;
}

- (NSString *)normalizedDirectory {
    NSString *path = [[self baseDirectory] stringByAppendingPathComponent:@"normalized"];
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return path;
}

- (void)updateJob:(SpliceKitURLImportJob *)job
            state:(NSString *)state
          message:(NSString *)message
         progress:(double)progress {
    dispatch_async(self.stateQueue, ^{
        NSString *safeState = SpliceKitURLImportDiagnosticString(state);
        NSString *safeMessage = SpliceKitURLImportDiagnosticString(message);
        if (safeState.length > 0) job.state = safeState;
        if (safeMessage.length > 0) job.message = safeMessage;
        if (progress >= 0.0) job.progress = progress;
        job.updatedAt = [NSDate date];
    });
}

- (void)finishJob:(SpliceKitURLImportJob *)job
          success:(BOOL)success
            state:(NSString *)state
          message:(NSString *)message
            error:(NSString *)errorMessage {
    dispatch_async(self.stateQueue, ^{
        job.success = success;
        NSString *safeState = SpliceKitURLImportDiagnosticString(state);
        NSString *safeMessage = SpliceKitURLImportDiagnosticString(message);
        NSString *safeError = SpliceKitURLImportDiagnosticString(errorMessage);
        job.state = safeState.length > 0
            ? safeState
            : (success ? SpliceKitURLImportStateCompleted : SpliceKitURLImportStateFailed);
        job.message = safeMessage.length > 0
            ? safeMessage
            : (success ? @"Completed" : @"Failed");
        job.errorMessage = safeError;
        job.progress = success ? 1.0 : job.progress;
        job.updatedAt = [NSDate date];
        dispatch_semaphore_signal(job.completionSemaphore);
    });
}

- (NSDictionary *)validationError:(NSString *)message {
    return @{@"success": @NO, @"error": message ?: @"Invalid request"};
}

- (NSString *)resolvedModeFromParams:(NSDictionary *)params {
    NSString *mode = [SpliceKitURLImportTrimmedString(params[@"mode"]) lowercaseString];
    NSString *timelineAction = [SpliceKitURLImportTrimmedString(params[@"timeline_action"]) lowercaseString];

    if (timelineAction.length > 0 && ![timelineAction isEqualToString:@"none"]) {
        if ([timelineAction isEqualToString:@"append"] ||
            [timelineAction isEqualToString:@"append_to_timeline"]) {
            return @"append_to_timeline";
        }
        if ([timelineAction isEqualToString:@"start"] ||
            [timelineAction isEqualToString:@"insert_at_start"] ||
            [timelineAction isEqualToString:@"insert_at_timeline_start"]) {
            return @"insert_at_timeline_start";
        }
        if ([timelineAction isEqualToString:@"insert"] ||
            [timelineAction isEqualToString:@"insert_at_playhead"]) {
            return @"insert_at_playhead";
        }
    }

    if ([mode isEqualToString:@"append"] || [mode isEqualToString:@"append_to_timeline"]) {
        return @"append_to_timeline";
    }
    if ([mode isEqualToString:@"start"] || [mode isEqualToString:@"insert_at_start"] ||
        [mode isEqualToString:@"insert_at_timeline_start"]) {
        return @"insert_at_timeline_start";
    }
    if ([mode isEqualToString:@"insert"] || [mode isEqualToString:@"insert_at_playhead"] ||
        [mode isEqualToString:@"timeline"]) {
        return @"insert_at_playhead";
    }
    return @"import_only";
}

- (id<SpliceKitURLResolver>)resolverForURL:(NSURL *)url {
    for (id<SpliceKitURLResolver> resolver in self.resolvers) {
        if ([resolver canResolveURL:url]) {
            return resolver;
        }
    }
    return nil;
}

- (NSString *)defaultClipNameForURL:(NSURL *)url titleOverride:(NSString *)titleOverride {
    if (titleOverride.length > 0) return SpliceKitURLImportSanitizeFilename(titleOverride);

    NSString *fromPath = [[url lastPathComponent] stringByDeletingPathExtension];
    if (fromPath.length > 0) return SpliceKitURLImportSanitizeFilename(fromPath);

    NSString *host = url.host ?: @"Imported Clip";
    return SpliceKitURLImportSanitizeFilename(host);
}

- (NSString *)currentTimelineEventName {
    __block NSString *eventName = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) return;
            SEL seqSel = NSSelectorFromString(@"sequence");
            id sequence = (timeline && [timeline respondsToSelector:seqSel])
                ? ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel) : nil;

            SEL eventSel = NSSelectorFromString(@"event");
            SEL containerEventSel = NSSelectorFromString(@"containerEvent");
            id event = nil;
            if (sequence && [sequence respondsToSelector:eventSel]) {
                event = ((id (*)(id, SEL))objc_msgSend)(sequence, eventSel);
            } else if (sequence && [sequence respondsToSelector:containerEventSel]) {
                event = ((id (*)(id, SEL))objc_msgSend)(sequence, containerEventSel);
            }
            if (!event) {
                @try { event = [sequence valueForKey:@"event"]; } @catch (__unused NSException *e) {}
            }
            if (!event) {
                @try { event = [sequence valueForKey:@"containerEvent"]; } @catch (__unused NSException *e) {}
            }
            if (event && [event respondsToSelector:@selector(displayName)]) {
                eventName = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName));
            }
            SpliceKit_log(@"[URLImport] currentTimelineEventName resolved to '%@'", eventName ?: @"");
        } @catch (NSException *e) {
            SpliceKit_log(@"[URLImport] Failed to read current event: %@", e.reason);
        }
    });
    return eventName;
}

- (BOOL)hasActiveTimeline {
    __block BOOL hasTimeline = NO;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            hasTimeline = (timeline != nil);
        } @catch (NSException *e) {
            SpliceKit_log(@"[URLImport] Failed to detect active timeline: %@", e.reason);
        }
    });
    return hasTimeline;
}

- (NSString *)pathForFilename:(NSString *)filename directory:(NSString *)directory {
    NSString *base = [[filename stringByDeletingPathExtension] copy];
    NSString *ext = [[filename pathExtension] lowercaseString];
    NSString *candidate = filename;
    NSInteger suffix = 1;

    while ([[NSFileManager defaultManager] fileExistsAtPath:[directory stringByAppendingPathComponent:candidate]]) {
        candidate = ext.length > 0
            ? [NSString stringWithFormat:@"%@-%ld.%@", base, (long)suffix, ext]
            : [NSString stringWithFormat:@"%@-%ld", base, (long)suffix];
        suffix++;
    }

    return [directory stringByAppendingPathComponent:candidate];
}

- (NSString *)filenameForJob:(SpliceKitURLImportJob *)job response:(NSURLResponse *)response {
    NSString *suggested = response.suggestedFilename ?: @"";
    NSString *ext = [[suggested pathExtension] lowercaseString];
    if (ext.length == 0) {
        ext = [[[NSURL URLWithString:job.sourceURL] pathExtension] lowercaseString];
    }
    if (ext.length == 0) ext = @"mp4";
    NSString *base = SpliceKitURLImportSanitizeFilename(job.clipName ?: @"Imported Clip");
    return [NSString stringWithFormat:@"%@.%@", base, ext];
}

- (NSDictionary *)inspectMediaAtPath:(NSString *)path {
    NSString *safePath = SpliceKitURLImportTrimmedString(path);
    if (safePath.length == 0) {
        SpliceKit_log(@"[URLImport] inspectMediaAtPath received an empty path");
        return @{@"error": @"Downloaded media did not produce a usable local file path"};
    }

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:safePath];
    if (!exists) {
        SpliceKit_log(@"[URLImport] inspectMediaAtPath missing file at %@", safePath);
        return @{@"error": @"Downloaded media file could not be found on disk"};
    }

    SpliceKit_log(@"[URLImport] Inspecting media at %@", safePath);

    NSURL *url = [NSURL fileURLWithPath:safePath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    NSArray<AVAssetTrack *> *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    CMTime duration = asset.duration;

    if (!CMTIME_IS_VALID(duration) || CMTIME_IS_INDEFINITE(duration) || duration.timescale <= 0 || duration.value <= 0) {
        return @{@"error": @"Downloaded media has no readable duration"};
    }

    AVAssetTrack *videoTrack = videoTracks.firstObject;
    AVAssetTrack *audioTrack = audioTracks.firstObject;
    NSString *ext = [[safePath pathExtension] lowercaseString];
    BOOL requiresNormalization = !([@[@"mp4", @"mov", @"m4v"] containsObject:ext]);

    int width = 1920;
    int height = 1080;
    NSString *frameDuration = @"100/2400s";

    if (videoTrack) {
        CGSize size = CGSizeApplyAffineTransform(videoTrack.naturalSize, videoTrack.preferredTransform);
        width = (int)fabs(size.width);
        height = (int)fabs(size.height);
        if (width <= 0) width = 1920;
        if (height <= 0) height = 1080;

        CMTime minFrameDuration = videoTrack.minFrameDuration;
        if (CMTIME_IS_VALID(minFrameDuration) && !CMTIME_IS_INDEFINITE(minFrameDuration) &&
            minFrameDuration.value > 0 && minFrameDuration.timescale > 0) {
            frameDuration = SpliceKitURLImportCMTimeString(minFrameDuration, frameDuration);
        } else if (videoTrack.nominalFrameRate > 0.0f) {
            int timescale = 2400;
            int value = (int)lrint((double)timescale / videoTrack.nominalFrameRate);
            if (value > 0) {
                frameDuration = [NSString stringWithFormat:@"%d/%ds", value, timescale];
            }
        }
    }

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"duration"] = SpliceKitURLImportCMTimeString(duration, @"2400/2400s");
    info[@"width"] = @(width);
    info[@"height"] = @(height);
    info[@"frameDuration"] = frameDuration;
    info[@"hasVideo"] = @(videoTrack != nil);
    info[@"hasAudio"] = @(audioTrack != nil);
    info[@"audioRate"] = @(audioTrack ? 48000 : 0);
    info[@"requiresNormalization"] = @(requiresNormalization);
    return info;
}

- (NSString *)importXMLForJob:(SpliceKitURLImportJob *)job
                     mediaInfo:(NSDictionary *)mediaInfo
                     eventName:(NSString *)eventName {
    NSString *uid = [[NSUUID UUID] UUIDString];
    NSString *fmtID = [NSString stringWithFormat:@"fmt_%@", [uid substringToIndex:8]];
    NSString *assetID = [NSString stringWithFormat:@"asset_%@", [uid substringToIndex:8]];
    NSString *clipName = SpliceKitURLImportEscapeXML(job.clipName ?: @"Imported Clip");
    NSString *escapedEvent = SpliceKitURLImportEscapeXML(eventName ?: @"URL Imports");
    NSString *mediaURL = [[[NSURL fileURLWithPath:(job.normalizedPath ?: job.downloadPath)] absoluteURL] absoluteString];
    NSString *duration = mediaInfo[@"duration"] ?: @"2400/2400s";
    NSString *frameDuration = mediaInfo[@"frameDuration"] ?: @"100/2400s";
    int width = [mediaInfo[@"width"] intValue] ?: 1920;
    int height = [mediaInfo[@"height"] intValue] ?: 1080;
    BOOL hasVideo = [mediaInfo[@"hasVideo"] boolValue];
    BOOL hasAudio = [mediaInfo[@"hasAudio"] boolValue];
    int audioRate = [mediaInfo[@"audioRate"] intValue] ?: 48000;

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<!DOCTYPE fcpxml>\n"];
    [xml appendString:@"<fcpxml version=\"1.14\">\n"];
    [xml appendString:@"    <resources>\n"];
    [xml appendFormat:@"        <format id=\"%@\" frameDuration=\"%@\" width=\"%d\" height=\"%d\" name=\"FFVideoFormat%dx%dp\"/>\n",
        fmtID, frameDuration, width, height, width, height];
    [xml appendFormat:@"        <asset id=\"%@\" name=\"%@\" uid=\"%@\" start=\"0s\" duration=\"%@\" hasVideo=\"%@\" hasAudio=\"%@\" format=\"%@\" audioSources=\"%@\" audioChannels=\"2\" audioRate=\"%d\">\n",
        assetID, clipName, uid, duration, hasVideo ? @"1" : @"0", hasAudio ? @"1" : @"0",
        fmtID, hasAudio ? @"1" : @"0", audioRate];
    [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n", mediaURL];
    [xml appendString:@"        </asset>\n"];
    [xml appendString:@"    </resources>\n"];
    [xml appendFormat:@"    <event name=\"%@\">\n", escapedEvent];
    [xml appendFormat:@"        <asset-clip ref=\"%@\" name=\"%@\" duration=\"%@\" start=\"0s\"/>\n",
        assetID, clipName, duration];
    [xml appendString:@"    </event>\n"];
    [xml appendString:@"</fcpxml>\n"];
    return xml;
}

- (id)findClipNamed:(NSString *)clipName inEventNamed:(NSString *)eventName {
    __block id foundClip = nil;
    NSString *needle = [clipName lowercaseString];
    NSString *eventNeedle = [eventName lowercaseString];

    SpliceKit_executeOnMainThread(^{
        @try {
            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                return;
            }

            id library = [(NSArray *)libs firstObject];
            SEL eventsSel = NSSelectorFromString(@"events");
            id events = [library respondsToSelector:eventsSel]
                ? ((id (*)(id, SEL))objc_msgSend)(library, eventsSel) : nil;
            if (![events isKindOfClass:[NSArray class]]) return;

            for (id event in (NSArray *)events) {
                NSString *candidateEvent = @"";
                if ([event respondsToSelector:@selector(displayName)]) {
                    candidateEvent = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName)) ?: @"";
                }
                if (eventNeedle.length > 0 &&
                    ![[candidateEvent lowercaseString] containsString:eventNeedle]) {
                    continue;
                }

                id clips = nil;
                SEL displayClipsSel = NSSelectorFromString(@"displayOwnedClips");
                SEL ownedClipsSel = NSSelectorFromString(@"ownedClips");
                SEL childItemsSel = NSSelectorFromString(@"childItems");
                if ([event respondsToSelector:displayClipsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, displayClipsSel);
                } else if ([event respondsToSelector:ownedClipsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, ownedClipsSel);
                } else if ([event respondsToSelector:childItemsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, childItemsSel);
                }
                if ([clips isKindOfClass:[NSSet class]]) clips = [(NSSet *)clips allObjects];
                if (![clips isKindOfClass:[NSArray class]]) continue;

                for (id clip in [(NSArray *)clips reverseObjectEnumerator]) {
                    if (![clip respondsToSelector:@selector(displayName)]) continue;
                    NSString *candidateName = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName)) ?: @"";
                    if ([[candidateName lowercaseString] isEqualToString:needle]) {
                        foundClip = clip;
                        return;
                    }
                }
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[URLImport] Clip lookup failed: %@", e.reason);
        }
    });
    return foundClip;
}

- (BOOL)selectClipInBrowser:(id)clip {
    __block BOOL selected = NO;
    if (!clip) return NO;

    SpliceKit_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
            if (!delegate) return;

            id browserContainer = nil;
            SEL browserSel = NSSelectorFromString(@"mediaBrowserContainerModule");
            if ([delegate respondsToSelector:browserSel]) {
                browserContainer = ((id (*)(id, SEL))objc_msgSend)(delegate, browserSel);
            }

            Class rangeObjClass = objc_getClass("FigTimeRangeAndObject");
            if (!rangeObjClass) return;

            CMTimeRange clipRange = kCMTimeRangeZero;
            SEL clippedRangeSel = NSSelectorFromString(@"clippedRange");
            SEL durationSel = NSSelectorFromString(@"duration");
            if ([clip respondsToSelector:clippedRangeSel]) {
                clipRange = ((CMTimeRange (*)(id, SEL))SPLICEKIT_URLIMPORT_STRET_MSG)(clip, clippedRangeSel);
            } else if ([clip respondsToSelector:durationSel]) {
                CMTime dur = ((CMTime (*)(id, SEL))SPLICEKIT_URLIMPORT_STRET_MSG)(clip, durationSel);
                clipRange = CMTimeRangeMake(kCMTimeZero, dur);
            }

            SEL rangeAndObjSel = NSSelectorFromString(@"rangeAndObjectWithRange:andObject:");
            if (![(id)rangeObjClass respondsToSelector:rangeAndObjSel]) return;
            id mediaRange = ((id (*)(id, SEL, CMTimeRange, id))objc_msgSend)(
                (id)rangeObjClass, rangeAndObjSel, clipRange, clip);
            if (!mediaRange) return;

            id filmstrip = nil;
            SEL filmstripSel = NSSelectorFromString(@"filmstripModule");
            if (browserContainer && [browserContainer respondsToSelector:filmstripSel]) {
                filmstrip = ((id (*)(id, SEL))objc_msgSend)(browserContainer, filmstripSel);
            }
            if (!filmstrip) {
                SEL orgSel = NSSelectorFromString(@"organizerModule");
                id organizer = [delegate respondsToSelector:orgSel]
                    ? ((id (*)(id, SEL))objc_msgSend)(delegate, orgSel) : nil;
                SEL itemsSel = NSSelectorFromString(@"itemsModule");
                if (organizer && [organizer respondsToSelector:itemsSel]) {
                    filmstrip = ((id (*)(id, SEL))objc_msgSend)(organizer, itemsSel);
                }
            }
            SEL selectSel = NSSelectorFromString(@"_selectMediaRanges:");
            if (filmstrip && [filmstrip respondsToSelector:selectSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(filmstrip, selectSel, @[mediaRange]);
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
                selected = YES;
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[URLImport] Browser selection failed: %@", e.reason);
        }
    });

    return selected;
}

- (NSDictionary *)performMediaInsertAction:(NSString *)selectorName {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            BOOL sent = ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
                app, @selector(sendAction:to:from:),
                NSSelectorFromString(selectorName), nil, nil);
            result = sent
                ? @{@"status": @"ok", @"action": selectorName}
                : @{@"error": [NSString stringWithFormat:@"No responder handled %@", selectorName]};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to execute media insert action"};
}

- (void)performTimelineInsertionForJob:(SpliceKitURLImportJob *)job {
    if (![self hasActiveTimeline]) {
        [self finishJob:job
                success:YES
                  state:SpliceKitURLImportStateCompleted
                message:@"Imported to event, but there is no active project to place it into."
                  error:nil];
        return;
    }

    [self updateJob:job state:SpliceKitURLImportStateInserting
            message:@"Placing imported clip into the active timeline..."
           progress:0.97];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id clip = nil;
        for (NSInteger attempt = 0; attempt < 12 && !clip; attempt++) {
            clip = [self findClipNamed:job.clipName inEventNamed:job.targetEvent];
            if (!clip) [NSThread sleepForTimeInterval:0.25];
        }

        if (!clip) {
            [self finishJob:job
                    success:YES
                      state:SpliceKitURLImportStateCompleted
                    message:@"Imported to the event, but could not find the new browser clip to place on the timeline."
                      error:nil];
            return;
        }

        NSString *clipHandle = SpliceKit_storeHandle(clip);
        if (clipHandle.length == 0) {
            [self finishJob:job
                    success:YES
                      state:SpliceKitURLImportStateCompleted
                    message:@"Imported to the event, but could not prepare the browser clip for timeline placement."
                      error:nil];
            return;
        }

        if ([job.mode isEqualToString:@"insert_at_timeline_start"]) {
            NSDictionary *seekResponse = SpliceKit_handleRequest(@{
                @"method": @"playback.seekToTime",
                @"params": @{@"seconds": @0}
            });
            NSDictionary *seekResult = seekResponse[@"result"] ?: seekResponse;
            if (seekResult[@"error"]) {
                [self finishJob:job
                        success:YES
                          state:SpliceKitURLImportStateCompleted
                        message:@"Imported to the event, but could not move the playhead to the timeline start."
                          error:seekResult[@"error"]];
                return;
            }
            [NSThread sleepForTimeInterval:0.1];
        }

        NSString *method = [job.mode isEqualToString:@"append_to_timeline"]
            ? @"browser.appendClip"
            : @"browser.insertClip";
        NSDictionary *insertResponse = SpliceKit_handleRequest(@{
            @"method": method,
            @"params": @{@"handle": clipHandle}
        });
        NSDictionary *insertResult = insertResponse[@"result"] ?: insertResponse;
        if (insertResult[@"error"]) {
            [self finishJob:job
                    success:YES
                      state:SpliceKitURLImportStateCompleted
                    message:@"Imported to the event, but timeline placement failed."
                      error:insertResult[@"error"]];
            return;
        }

        dispatch_async(self.stateQueue, ^{
            job.timelineInserted = YES;
        });
        NSString *message = nil;
        if ([job.mode isEqualToString:@"append_to_timeline"]) {
            message = @"Downloaded, imported, and appended to the active timeline.";
        } else if ([job.mode isEqualToString:@"insert_at_timeline_start"]) {
            message = @"Downloaded, imported, and inserted at the timeline start.";
        } else {
            message = @"Downloaded, imported, and inserted at the playhead.";
        }
        [self finishJob:job success:YES state:SpliceKitURLImportStateCompleted message:message error:nil];
    });
}

- (void)importJobIntoFinalCut:(SpliceKitURLImportJob *)job mediaInfo:(NSDictionary *)mediaInfo {
    [self updateJob:job state:SpliceKitURLImportStateImporting
            message:@"Importing media into Final Cut Pro..."
           progress:0.92];

    NSString *eventName = job.targetEvent.length > 0 ? job.targetEvent : [self currentTimelineEventName];
    if (eventName.length == 0) eventName = @"URL Imports";
    dispatch_async(self.stateQueue, ^{
        job.targetEvent = eventName;
    });

    NSString *xml = [self importXMLForJob:job mediaInfo:mediaInfo eventName:eventName];
    NSDictionary *response = SpliceKit_handleRequest(@{
        @"method": @"fcpxml.import",
        @"params": @{@"xml": xml, @"internal": @YES}
    });
    NSDictionary *result = response[@"result"] ?: response;
    if (result[@"error"]) {
        [self finishJob:job
                success:NO
                  state:SpliceKitURLImportStateFailed
                message:@"Final Cut import failed."
                  error:result[@"error"]];
        return;
    }

    dispatch_async(self.stateQueue, ^{
        job.imported = YES;
    });

    if ([job.mode isEqualToString:@"import_only"]) {
        [self finishJob:job
                success:YES
                  state:SpliceKitURLImportStateCompleted
                message:@"Downloaded and imported into the current event."
                  error:nil];
        return;
    }

    [self performTimelineInsertionForJob:job];
}

- (void)normalizeJob:(SpliceKitURLImportJob *)job {
    NSString *sourcePath = SpliceKitURLImportTrimmedString(job.downloadPath);
    SpliceKit_log(@"[URLImport] normalizeJob starting for %@ with path %@",
                  job.jobID ?: @"<unknown>", sourcePath);
    NSDictionary *mediaInfo = [self inspectMediaAtPath:sourcePath];
    if (mediaInfo[@"error"]) {
        [self finishJob:job
                success:NO
                  state:SpliceKitURLImportStateFailed
                message:@"Downloaded file could not be inspected."
                  error:mediaInfo[@"error"]];
        return;
    }

    BOOL requiresNormalization = [mediaInfo[@"requiresNormalization"] boolValue];
    if (!requiresNormalization) {
        job.normalizedPath = sourcePath;
        [self importJobIntoFinalCut:job mediaInfo:mediaInfo];
        return;
    }

    [self updateJob:job state:SpliceKitURLImportStateNormalizing
            message:@"Normalizing media for Final Cut Pro..."
           progress:0.82];

    NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:sourceURL options:nil];
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:asset
                                                                    presetName:AVAssetExportPresetHighestQuality];
    if (!export) {
        [self finishJob:job
                success:NO
                  state:SpliceKitURLImportStateFailed
                message:@"Media normalization could not start."
                  error:@"Could not create AVAssetExportSession for this file."];
        return;
    }

    NSString *outputName = [NSString stringWithFormat:@"%@.mov",
        SpliceKitURLImportSanitizeFilename(job.clipName ?: @"Imported Clip")];
    NSString *outputPath = [self pathForFilename:outputName directory:[self normalizedDirectory]];
    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

    export.outputURL = [NSURL fileURLWithPath:outputPath];
    export.outputFileType = [export.supportedFileTypes containsObject:AVFileTypeQuickTimeMovie]
        ? AVFileTypeQuickTimeMovie
        : export.supportedFileTypes.firstObject;
    export.shouldOptimizeForNetworkUse = YES;

    dispatch_async(self.stateQueue, ^{
        job.exportSession = export;
    });

    [export exportAsynchronouslyWithCompletionHandler:^{
        switch (export.status) {
            case AVAssetExportSessionStatusCompleted: {
                dispatch_async(self.stateQueue, ^{
                    job.normalizedPath = outputPath;
                    job.transcoded = YES;
                    job.exportSession = nil;
                });
                NSMutableDictionary *normalizedInfo = [mediaInfo mutableCopy];
                normalizedInfo[@"requiresNormalization"] = @NO;
                [self importJobIntoFinalCut:job mediaInfo:normalizedInfo];
                break;
            }
            case AVAssetExportSessionStatusCancelled:
                [self finishJob:job
                        success:NO
                          state:SpliceKitURLImportStateCancelled
                        message:@"URL import was cancelled during normalization."
                          error:nil];
                break;
            default: {
                NSString *errorMessage = export.error.localizedDescription ?: @"Media normalization failed.";
                [self finishJob:job
                        success:NO
                          state:SpliceKitURLImportStateFailed
                        message:@"Media normalization failed."
                          error:errorMessage];
                break;
            }
        }
    }];
}

- (void)beginDownloadForJob:(SpliceKitURLImportJob *)job downloadURL:(NSURL *)downloadURL {
    [self updateJob:job state:SpliceKitURLImportStateDownloading
            message:@"Downloading media..."
           progress:0.05];
    NSURLSessionDownloadTask *task = [self.session downloadTaskWithURL:downloadURL];
    dispatch_async(self.stateQueue, ^{
        job.downloadTask = task;
        self.taskToJob[@(task.taskIdentifier)] = job.jobID;
    });
    [task resume];
}

- (NSDictionary *)startImportWithParams:(NSDictionary *)params waitForCompletion:(BOOL)wait {
    NSString *rawURLString = SpliceKitURLImportTrimmedString(params[@"url"]);
    NSString *urlString = SpliceKitURLImportNormalizeURLString(params[@"url"]);
    if (urlString.length == 0) return [self validationError:@"url parameter required"];
    if (rawURLString.length > 0 && ![rawURLString isEqualToString:urlString]) {
        SpliceKit_log(@"[URLImport] Normalized pasted URL from '%@' to '%@'", rawURLString, urlString);
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || url.scheme.length == 0 || url.host.length == 0) {
        return [self validationError:@"Invalid URL. Provide a full https:// or http:// media URL."];
    }

    id<SpliceKitURLResolver> resolver = [self resolverForURL:url];
    if (!resolver) {
        return [self validationError:
            @"Unsupported URL source. This build supports direct .mp4/.mov/.m4v/.webm links plus YouTube and Vimeo URLs through yt-dlp."];
    }

    SpliceKitURLImportJob *job = [[SpliceKitURLImportJob alloc] init];
    job.jobID = [[NSUUID UUID] UUIDString];
    job.sourceURL = urlString;
    job.sourceType = [resolver sourceType];
    job.mode = [self resolvedModeFromParams:params];
    job.targetEvent = SpliceKitURLImportTrimmedString(params[@"target_event"]);
    job.titleOverride = SpliceKitURLImportTrimmedString(params[@"title"]);
    job.clipName = [self defaultClipNameForURL:url titleOverride:job.titleOverride];
    job.progress = 0.01;
    job.message = @"Resolving URL...";
    job.state = SpliceKitURLImportStateResolving;

    dispatch_sync(self.stateQueue, ^{
        self.jobs[job.jobID] = job;
    });

    [resolver resolveURL:url
                     job:job
                progress:^(NSString *message, double progress) {
                    NSString *state = SpliceKitURLImportStateResolving;
                    NSString *lowerMessage = [SpliceKitURLImportString(message) lowercaseString];
                    if ([lowerMessage containsString:@"downloading"]) {
                        state = SpliceKitURLImportStateDownloading;
                    } else if ([lowerMessage containsString:@"converting"] ||
                               [lowerMessage containsString:@"normalizing"] ||
                               [lowerMessage containsString:@"inspecting media"]) {
                        state = SpliceKitURLImportStateNormalizing;
                    }
                    [self updateJob:job
                              state:state
                            message:message
                           progress:progress];
                }
              completion:^(NSURL *downloadURL,
                           NSString *resolvedTitle,
                           NSString *localPath,
                           NSString *errorMessage) {
        if (job.cancelled) return;

        if (errorMessage.length > 0 || (!downloadURL && localPath.length == 0)) {
            [self finishJob:job
                    success:NO
                      state:SpliceKitURLImportStateFailed
                    message:@"Could not resolve the media URL."
                      error:errorMessage ?: @"Resolver returned no download URL."];
            return;
        }

        if (resolvedTitle.length > 0 && job.titleOverride.length == 0) {
            job.clipName = SpliceKitURLImportSanitizeFilename(resolvedTitle);
        }

        if (localPath.length > 0) {
            job.downloadPath = localPath;
            if (job.titleOverride.length == 0) {
                NSString *downloadName = [[localPath lastPathComponent] stringByDeletingPathExtension];
                if (downloadName.length > 0) {
                    job.clipName = SpliceKitURLImportSanitizeFilename(downloadName);
                }
            }
            [self updateJob:job
                      state:SpliceKitURLImportStateNormalizing
                    message:@"Download complete. Inspecting media..."
                   progress:0.78];
            [self normalizeJob:job];
            return;
        }

        [self beginDownloadForJob:job downloadURL:downloadURL];
    }];

    if (!wait) {
        return [job snapshot];
    }

    NSTimeInterval timeout = 900.0;
    NSNumber *timeoutNum = params[@"timeout_seconds"];
    if ([timeoutNum respondsToSelector:@selector(doubleValue)] && [timeoutNum doubleValue] > 0) {
        timeout = [timeoutNum doubleValue];
    }

    long waitResult = dispatch_semaphore_wait(job.completionSemaphore,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    if (waitResult != 0) {
        [self finishJob:job
                success:NO
                  state:SpliceKitURLImportStateFailed
                message:@"Timed out waiting for URL import to finish."
                  error:@"Timed out waiting for URL import to finish."];
    }
    return [self statusForJobID:job.jobID];
}

- (NSDictionary *)statusForJobID:(NSString *)jobID {
    __block NSDictionary *snapshot = nil;
    dispatch_sync(self.stateQueue, ^{
        SpliceKitURLImportJob *job = self.jobs[jobID];
        snapshot = job ? [job snapshot] : nil;
    });
    return snapshot ?: @{@"success": @NO, @"error": @"Unknown job_id"};
}

- (NSDictionary *)cancelJobID:(NSString *)jobID {
    __block NSDictionary *snapshot = nil;
    dispatch_sync(self.stateQueue, ^{
        SpliceKitURLImportJob *job = self.jobs[jobID];
        if (!job) {
            snapshot = @{@"success": @NO, @"error": @"Unknown job_id"};
            return;
        }

        job.cancelled = YES;
        @synchronized (job) {
            if (job.resolverTask) {
                [job.resolverTask terminate];
                job.resolverTask = nil;
            }
            if (job.downloadTask) {
                [job.downloadTask cancel];
                job.downloadTask = nil;
            }
            if (job.exportSession) {
                [job.exportSession cancelExport];
                job.exportSession = nil;
            }
        }
        if (![job isFinished]) {
            job.state = SpliceKitURLImportStateCancelled;
            job.message = @"Cancelled";
            job.updatedAt = [NSDate date];
            dispatch_semaphore_signal(job.completionSemaphore);
        }
        snapshot = [job snapshot];
    });
    return snapshot;
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didWriteData:(int64_t)bytesWritten
totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    (void)session;
    __block SpliceKitURLImportJob *job = nil;
    dispatch_sync(self.stateQueue, ^{
        NSString *jobID = self.taskToJob[@(downloadTask.taskIdentifier)];
        job = jobID ? self.jobs[jobID] : nil;
    });
    if (!job || totalBytesExpectedToWrite <= 0) return;

    double fraction = (double)totalBytesWritten / (double)totalBytesExpectedToWrite;
    double progress = 0.05 + MIN(MAX(fraction, 0.0), 1.0) * 0.65;
    NSString *message = [NSString stringWithFormat:@"Downloading media... %.0f%%", fraction * 100.0];
    [self updateJob:job state:SpliceKitURLImportStateDownloading message:message progress:progress];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    (void)session;
    __block SpliceKitURLImportJob *job = nil;
    dispatch_sync(self.stateQueue, ^{
        NSString *jobID = self.taskToJob[@(downloadTask.taskIdentifier)];
        job = jobID ? self.jobs[jobID] : nil;
        [self.taskToJob removeObjectForKey:@(downloadTask.taskIdentifier)];
        if (job) job.downloadTask = nil;
    });
    if (!job || job.cancelled) return;

    NSString *filename = [self filenameForJob:job response:downloadTask.response];
    NSString *destinationPath = [self pathForFilename:filename directory:[self downloadsDirectory]];
    NSError *moveError = nil;
    [[NSFileManager defaultManager] removeItemAtPath:destinationPath error:nil];
    [[NSFileManager defaultManager] moveItemAtURL:location
                                            toURL:[NSURL fileURLWithPath:destinationPath]
                                            error:&moveError];
    if (moveError) {
        [self finishJob:job
                success:NO
                  state:SpliceKitURLImportStateFailed
                message:@"Downloaded file could not be moved into the SpliceKit cache."
                  error:moveError.localizedDescription];
        return;
    }

    job.downloadPath = destinationPath;
    if (job.titleOverride.length == 0) {
        NSString *downloadName = [[destinationPath lastPathComponent] stringByDeletingPathExtension];
        if (downloadName.length > 0) {
            job.clipName = SpliceKitURLImportSanitizeFilename(downloadName);
        }
    }

    [self normalizeJob:job];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    (void)session;
    if (!error) return;

    __block SpliceKitURLImportJob *job = nil;
    dispatch_sync(self.stateQueue, ^{
        NSString *jobID = self.taskToJob[@(task.taskIdentifier)];
        job = jobID ? self.jobs[jobID] : nil;
        [self.taskToJob removeObjectForKey:@(task.taskIdentifier)];
        if (job) job.downloadTask = nil;
    });
    if (!job || [job isFinished]) return;

    NSString *state = (error.code == NSURLErrorCancelled || job.cancelled)
        ? SpliceKitURLImportStateCancelled
        : SpliceKitURLImportStateFailed;
    NSString *message = [state isEqualToString:SpliceKitURLImportStateCancelled]
        ? @"URL import was cancelled."
        : @"Download failed.";
    [self finishJob:job
            success:NO
              state:state
            message:message
              error:[state isEqualToString:SpliceKitURLImportStateCancelled] ? nil : error.localizedDescription];
}

@end

NSDictionary *SpliceKitURLImport_start(NSDictionary *params) {
    return [[SpliceKitURLImportService sharedService] startImportWithParams:params waitForCompletion:NO];
}

NSDictionary *SpliceKitURLImport_importSync(NSDictionary *params) {
    return [[SpliceKitURLImportService sharedService] startImportWithParams:params waitForCompletion:YES];
}

NSDictionary *SpliceKitURLImport_status(NSDictionary *params) {
    NSString *jobID = SpliceKitURLImportTrimmedString(params[@"job_id"]);
    if (jobID.length == 0) return @{@"success": @NO, @"error": @"job_id parameter required"};
    return [[SpliceKitURLImportService sharedService] statusForJobID:jobID];
}

NSDictionary *SpliceKitURLImport_cancel(NSDictionary *params) {
    NSString *jobID = SpliceKitURLImportTrimmedString(params[@"job_id"]);
    if (jobID.length == 0) return @{@"success": @NO, @"error": @"job_id parameter required"};
    return [[SpliceKitURLImportService sharedService] cancelJobID:jobID];
}
