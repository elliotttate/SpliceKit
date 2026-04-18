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
static NSArray *SpliceKitURLImportArrayFromContainer(id value);

static NSString *SpliceKitURLImportString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSArray *SpliceKitURLImportArrayFromContainer(id value) {
    if (!value || value == (id)kCFNull) return @[];
    if ([value isKindOfClass:[NSArray class]]) return value;

    SEL allObjectsSel = NSSelectorFromString(@"allObjects");
    if ([value respondsToSelector:allObjectsSel]) {
        id allObjects = ((id (*)(id, SEL))objc_msgSend)(value, allObjectsSel);
        if ([allObjects isKindOfClass:[NSArray class]]) return allObjects;
    }

    SEL countSel = @selector(count);
    SEL objectAtIndexSel = @selector(objectAtIndex:);
    if ([value respondsToSelector:countSel] && [value respondsToSelector:objectAtIndexSel]) {
        NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(value, countSel);
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; i++) {
            id item = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(value, objectAtIndexSel, i);
            if (item) [items addObject:item];
        }
        return items;
    }

    return @[];
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
        allowed = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"webm", @"mkv"]];
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

static NSString *SpliceKitURLImportSharedNormalizedDirectory(void) {
    return SpliceKitURLImportEnsureDirectory([SpliceKitURLImportSharedBaseDirectory()
        stringByAppendingPathComponent:@"normalized"]);
}

static BOOL SpliceKitURLImportPathIsWithinDirectory(NSString *path, NSString *directory) {
    NSString *standardPath = [SpliceKitURLImportTrimmedString(path) stringByStandardizingPath];
    NSString *standardDirectory = [SpliceKitURLImportTrimmedString(directory) stringByStandardizingPath];
    if (standardPath.length == 0 || standardDirectory.length == 0) return NO;
    if ([standardPath isEqualToString:standardDirectory]) return YES;
    NSString *prefix = [standardDirectory hasSuffix:@"/"]
        ? standardDirectory
        : [standardDirectory stringByAppendingString:@"/"];
    return [standardPath hasPrefix:prefix];
}

static NSArray<NSString *> *SpliceKitURLImportUniqueStrings(id base, NSArray<NSString *> *extras) {
    NSMutableOrderedSet<NSString *> *values = [NSMutableOrderedSet orderedSet];
    for (id item in SpliceKitURLImportArrayFromContainer(base)) {
        if ([item isKindOfClass:[NSString class]] && ((NSString *)item).length > 0) {
            [values addObject:item];
        }
    }
    for (NSString *item in extras) {
        if (item.length > 0) {
            [values addObject:item];
        }
    }
    return values.array ?: @[];
}

static NSString *SpliceKitURLImportUniquePathForFilename(NSString *filename, NSString *directory) {
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

static void SpliceKitURLImportAddExecutableCandidate(NSMutableOrderedSet<NSString *> *candidates,
                                                     NSString *path) {
    NSString *trimmed = [SpliceKitURLImportTrimmedString(path) stringByStandardizingPath];
    if (trimmed.length > 0) [candidates addObject:trimmed];
}

static NSString *SpliceKitURLImportExecutablePath(NSArray<NSString *> *candidates) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in candidates) {
        if ([fm isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

static NSString *SpliceKitURLImportExecutablePathFromLoginShell(NSString *name) {
    NSString *trimmedName = SpliceKitURLImportTrimmedString(name);
    if (trimmedName.length == 0) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableOrderedSet<NSString *> *shells = [NSMutableOrderedSet orderedSet];
    NSString *preferredShell = [NSProcessInfo processInfo].environment[@"SHELL"];
    if ([fm isExecutableFileAtPath:preferredShell]) {
        [shells addObject:[preferredShell stringByStandardizingPath]];
    }
    for (NSString *candidate in @[@"/bin/zsh", @"/bin/bash", @"/bin/sh"]) {
        if ([fm isExecutableFileAtPath:candidate]) [shells addObject:candidate];
    }

    NSString *command = [NSString stringWithFormat:@"command -v %@ 2>/dev/null || which %@ 2>/dev/null",
                         trimmedName, trimmedName];
    for (NSString *shellPath in shells) {
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:shellPath];
        task.arguments = @[@"-lc", command];

        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = pipe;

        NSError *launchError = nil;
        if (![task launchAndReturnError:&launchError]) {
            continue;
        }

        [task waitUntilExit];
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *output = SpliceKitURLImportStringFromData(data);
        NSArray<NSString *> *lines = [output componentsSeparatedByCharactersInSet:
            [NSCharacterSet newlineCharacterSet]];
        for (NSString *line in lines) {
            NSString *resolved = [SpliceKitURLImportTrimmedString(line) stringByStandardizingPath];
            if ([fm isExecutableFileAtPath:resolved]) return resolved;
        }
    }

    return nil;
}

static NSString *SpliceKitURLImportDependencyPath(NSString *toolName,
                                                  NSString *overrideEnvVar) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableOrderedSet<NSString *> *candidates = [NSMutableOrderedSet orderedSet];
    NSString *home = NSHomeDirectory();
    NSString *tools = SpliceKitURLImportToolsDirectory();

    SpliceKitURLImportAddExecutableCandidate(candidates,
        [NSProcessInfo processInfo].environment[overrideEnvVar]);
    SpliceKitURLImportAddExecutableCandidate(candidates,
        [tools stringByAppendingPathComponent:toolName]);

    NSString *processPath = [NSProcessInfo processInfo].environment[@"PATH"];
    for (NSString *directory in [processPath componentsSeparatedByString:@":"]) {
        NSString *trimmed = SpliceKitURLImportTrimmedString(directory);
        if (trimmed.length == 0) continue;
        SpliceKitURLImportAddExecutableCandidate(candidates,
            [trimmed stringByAppendingPathComponent:toolName]);
    }

    for (NSString *directory in @[
        [home stringByAppendingPathComponent:@".local/bin"],
        [home stringByAppendingPathComponent:@".pyenv/shims"],
        [home stringByAppendingPathComponent:@".asdf/shims"],
        [home stringByAppendingPathComponent:@".nix-profile/bin"],
        @"/nix/var/nix/profiles/default/bin",
        @"/opt/homebrew/bin",
        @"/usr/local/bin",
        @"/opt/local/bin",
        @"/usr/bin",
    ]) {
        SpliceKitURLImportAddExecutableCandidate(candidates,
            [directory stringByAppendingPathComponent:toolName]);
    }

    NSString *resolvedFromShell = SpliceKitURLImportExecutablePathFromLoginShell(toolName);
    if ([fm isExecutableFileAtPath:resolvedFromShell]) {
        SpliceKitURLImportAddExecutableCandidate(candidates, resolvedFromShell);
    }

    return SpliceKitURLImportExecutablePath(candidates.array);
}

static NSString *SpliceKitURLImportYTDLPPath(void) {
    return SpliceKitURLImportDependencyPath(@"yt-dlp", @"SPLICEKIT_YTDLP_PATH");
}

static NSString *SpliceKitURLImportFFmpegPath(void) {
    return SpliceKitURLImportDependencyPath(@"ffmpeg", @"SPLICEKIT_FFMPEG_PATH");
}

static NSString *SpliceKitURLImportFFprobePath(void) {
    return SpliceKitURLImportDependencyPath(@"ffprobe", @"SPLICEKIT_FFPROBE_PATH");
}

static FourCharCode SpliceKitURLImportTrackCodecType(AVAssetTrack *track) {
    if (!track) return 0;
    NSArray *formatDescriptions = track.formatDescriptions;
    id firstDescription = formatDescriptions.firstObject;
    if (!firstDescription) return 0;
    return CMFormatDescriptionGetMediaSubType((CMFormatDescriptionRef)firstDescription);
}

static FourCharCode SpliceKitURLImportVideoCodecType(AVAssetTrack *videoTrack) {
    return SpliceKitURLImportTrackCodecType(videoTrack);
}

static FourCharCode SpliceKitURLImportAudioCodecType(AVAssetTrack *audioTrack) {
    return SpliceKitURLImportTrackCodecType(audioTrack);
}

static NSString *SpliceKitURLImportFourCCString(FourCharCode code) {
    if (code == 0) return @"";
    char chars[5] = {
        (char)((code >> 24) & 0xFF),
        (char)((code >> 16) & 0xFF),
        (char)((code >> 8) & 0xFF),
        (char)(code & 0xFF),
        0
    };
    return [NSString stringWithUTF8String:chars] ?: @"";
}

static BOOL SpliceKitURLImportCanonicalFrameTimingForRate(double fps,
                                                          int *outTimescale,
                                                          int *outFrameTicks) {
    if (!(fps > 0.0) || !isfinite(fps)) return NO;

    struct {
        double fps;
        int timescale;
        int frameTicks;
    } knownRates[] = {
        { 24000.0 / 1001.0, 24000, 1001 },
        { 24.0,             24000, 1000 },
        { 25.0,             25000, 1000 },
        { 30000.0 / 1001.0, 30000, 1001 },
        { 30.0,             30000, 1000 },
        { 50.0,             50000, 1000 },
        { 60000.0 / 1001.0, 60000, 1001 },
        { 60.0,             60000, 1000 },
    };

    for (size_t i = 0; i < sizeof(knownRates) / sizeof(knownRates[0]); ++i) {
        if (fabs(fps - knownRates[i].fps) <= 0.05) {
            if (outTimescale) *outTimescale = knownRates[i].timescale;
            if (outFrameTicks) *outFrameTicks = knownRates[i].frameTicks;
            return YES;
        }
    }

    int timescale = (int)lrint(fps * 1000.0);
    if (timescale <= 0) return NO;
    if (outTimescale) *outTimescale = timescale;
    if (outFrameTicks) *outFrameTicks = 1000;
    return YES;
}

static BOOL SpliceKitURLImportCanonicalFrameTimingForTrack(AVAssetTrack *videoTrack,
                                                           int *outTimescale,
                                                           int *outFrameTicks) {
    if (!videoTrack) return NO;
    if (SpliceKitURLImportCanonicalFrameTimingForRate(videoTrack.nominalFrameRate,
                                                      outTimescale,
                                                      outFrameTicks)) {
        return YES;
    }

    CMTime minFrameDuration = videoTrack.minFrameDuration;
    if (CMTIME_IS_VALID(minFrameDuration) && !CMTIME_IS_INDEFINITE(minFrameDuration) &&
        minFrameDuration.value > 0 && minFrameDuration.timescale > 0) {
        double fps = (double)minFrameDuration.timescale / (double)minFrameDuration.value;
        return SpliceKitURLImportCanonicalFrameTimingForRate(fps, outTimescale, outFrameTicks);
    }
    return NO;
}

static BOOL SpliceKitURLImportCMTimeMatchesRational(CMTime time, int value, int timescale) {
    if (!CMTIME_IS_VALID(time) || CMTIME_IS_INDEFINITE(time) ||
        time.value <= 0 || time.timescale <= 0 ||
        value <= 0 || timescale <= 0) {
        return NO;
    }
    return (int64_t)time.value * (int64_t)timescale == (int64_t)value * (int64_t)time.timescale;
}

static BOOL SpliceKitURLImportNormalizationModeUsesStreamCopy(NSString *mode) {
    NSString *normalized = SpliceKitURLImportTrimmedString(mode);
    return [normalized isEqualToString:@"rewrite_timestamps"] ||
           [normalized isEqualToString:@"remux_copy"] ||
           [normalized isEqualToString:@"remux_copy_rewrite_timestamps"];
}

static BOOL SpliceKitURLImportNormalizationModeNeedsTimestampRewrite(NSString *mode) {
    NSString *normalized = SpliceKitURLImportTrimmedString(mode);
    return [normalized isEqualToString:@"rewrite_timestamps"] ||
           [normalized isEqualToString:@"remux_copy_rewrite_timestamps"];
}

static NSString *SpliceKitURLImportOutputExtensionForNormalizationMode(NSString *mode) {
    NSString *normalized = SpliceKitURLImportTrimmedString(mode);
    if ([normalized isEqualToString:@"rewrite_timestamps"] ||
        [normalized isEqualToString:@"remux_copy"] ||
        [normalized isEqualToString:@"remux_copy_rewrite_timestamps"]) {
        return @"mp4";
    }
    return @"mov";
}

static NSString *SpliceKitURLImportProviderDependencyMessage(NSString *provider,
                                                            NSString *ytDLP,
                                                            NSString *ffmpeg) {
    NSString *label = provider.length > 0 ? provider : @"Provider";
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    if (ytDLP.length == 0) [missing addObject:@"yt-dlp"];
    if (ffmpeg.length == 0) [missing addObject:@"ffmpeg"];
    NSString *missingList = missing.count > 0
        ? [missing componentsJoinedByString:@" and "]
        : @"yt-dlp and ffmpeg";
    return [NSString stringWithFormat:
        @"%@ import requires %@. SpliceKit looks in ~/Applications/SpliceKit/tools, your PATH, and common package-manager locations. If they're already installed somewhere custom, run `make url-import-tools` or symlink them into ~/Applications/SpliceKit/tools/.",
        label, missingList];
}

static NSString *SpliceKitURLImportStringFromData(NSData *data) {
    if (data.length == 0) return @"";
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (string.length > 0) return string;
    string = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return string ?: @"";
}

static double SpliceKitURLImportParseFractionString(NSString *value) {
    NSString *trimmed = SpliceKitURLImportTrimmedString(value);
    if (trimmed.length == 0) return 0.0;

    NSRange slashRange = [trimmed rangeOfString:@"/"];
    if (slashRange.location != NSNotFound) {
        NSString *numeratorString = [trimmed substringToIndex:slashRange.location];
        NSString *denominatorString = [trimmed substringFromIndex:(slashRange.location + 1)];
        double numerator = numeratorString.doubleValue;
        double denominator = denominatorString.doubleValue;
        if (numerator > 0.0 && denominator > 0.0 && isfinite(numerator) && isfinite(denominator)) {
            return numerator / denominator;
        }
        return 0.0;
    }

    double scalar = trimmed.doubleValue;
    return (scalar > 0.0 && isfinite(scalar)) ? scalar : 0.0;
}

static NSString *SpliceKitURLImportCMTimeStringFromSeconds(double seconds, NSString *fallback) {
    if (!(seconds >= 0.0) || !isfinite(seconds)) return fallback ?: @"2400/2400s";
    int32_t timescale = 1000;
    int64_t value = llround(seconds * (double)timescale);
    if (value < 0) value = 0;
    return [NSString stringWithFormat:@"%lld/%ds", value, timescale];
}

static NSDictionary *SpliceKitURLImportFFprobeJSONForPath(NSString *path, NSString **outError) {
    NSString *ffprobe = SpliceKitURLImportFFprobePath();
    if (ffprobe.length == 0) {
        if (outError) {
            *outError = @"SpliceKit could not find ffprobe to inspect this Matroska/WebM source. Run `make url-import-tools` or put ffprobe in ~/Applications/SpliceKit/tools/.";
        }
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:ffprobe];
    task.arguments = @[
        @"-v", @"error",
        @"-show_streams",
        @"-show_format",
        @"-print_format", @"json",
        path,
    ];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (outError) {
            *outError = launchError.localizedDescription ?: @"Could not launch ffprobe to inspect the source media.";
        }
        return nil;
    }

    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *output = SpliceKitURLImportTrimmedString(SpliceKitURLImportStringFromData(data));
    if (task.terminationStatus != 0) {
        if (outError) {
            *outError = output.length > 0 ? output : @"ffprobe failed while inspecting the source media.";
        }
        return nil;
    }

    if (output.length == 0) {
        if (outError) *outError = @"ffprobe returned no metadata for the source media.";
        return nil;
    }

    NSData *jsonData = [output dataUsingEncoding:NSUTF8StringEncoding];
    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];
    if (![object isKindOfClass:[NSDictionary class]]) {
        if (outError) {
            *outError = jsonError.localizedDescription ?: @"ffprobe returned malformed JSON.";
        }
        return nil;
    }
    return (NSDictionary *)object;
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
        completion(nil, nil, nil, SpliceKitURLImportProviderDependencyMessage(provider, ytDLP, ffmpeg));
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
                    double clamped = MIN(MAX(percent, 0.0), 100.0);
                    double mapped = 0.08 + clamped / 100.0 * 0.64;
                    if (progress && (mapped - lastMappedProgress >= 0.002 || mapped >= 0.72)) {
                        lastMappedProgress = mapped;
                        progress([NSString stringWithFormat:@"Downloading %@ media… %.1f%%",
                                  provider ?: @"provider", clamped],
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
- (NSDictionary *)inspectMediaAtPath:(NSString *)path;
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
    return SpliceKitURLImportSharedNormalizedDirectory();
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
    return SpliceKitURLImportUniquePathForFilename(filename, directory);
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

    NSString *ext = [[safePath pathExtension] lowercaseString];
    BOOL isMP4Family = [@[@"mp4", @"mov", @"m4v"] containsObject:ext];
    BOOL isMatroskaFamily = [@[@"mkv", @"webm"] containsObject:ext];
    if (isMatroskaFamily) {
        NSString *probeError = nil;
        NSDictionary *probe = SpliceKitURLImportFFprobeJSONForPath(safePath, &probeError);
        if (![probe isKindOfClass:[NSDictionary class]]) {
            return @{@"error": probeError ?: @"SpliceKit could not inspect this Matroska/WebM source."};
        }

        NSArray *streams = [probe[@"streams"] isKindOfClass:[NSArray class]] ? probe[@"streams"] : @[];
        NSDictionary *format = [probe[@"format"] isKindOfClass:[NSDictionary class]] ? probe[@"format"] : @{};
        NSDictionary *videoStream = nil;
        NSDictionary *audioStream = nil;
        for (id item in streams) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *stream = (NSDictionary *)item;
            NSString *codecType = SpliceKitURLImportTrimmedString(stream[@"codec_type"]).lowercaseString;
            if (!videoStream && [codecType isEqualToString:@"video"]) {
                videoStream = stream;
            } else if (!audioStream && [codecType isEqualToString:@"audio"]) {
                audioStream = stream;
            }
        }

        if (!videoStream && !audioStream) {
            return @{@"error": @"Matroska/WebM source has no readable audio or video streams."};
        }

        NSString *videoCodecName = SpliceKitURLImportTrimmedString(videoStream[@"codec_name"]).lowercaseString;
        NSString *audioCodecName = SpliceKitURLImportTrimmedString(audioStream[@"codec_name"]).lowercaseString;
        BOOL audioIsAACOrAbsent = (audioStream == nil) || [audioCodecName containsString:@"aac"];
        BOOL canStreamCopyToMP4 = ([videoCodecName isEqualToString:@"vp9"] ||
                                   [videoCodecName isEqualToString:@"vp8"]) &&
                                  audioIsAACOrAbsent;

        double fps = SpliceKitURLImportParseFractionString(videoStream[@"avg_frame_rate"]);
        if (!(fps > 0.0)) {
            fps = SpliceKitURLImportParseFractionString(videoStream[@"r_frame_rate"]);
        }

        int canonicalTimescale = 0;
        int canonicalFrameTicks = 0;
        BOOL hasCanonicalTiming = SpliceKitURLImportCanonicalFrameTimingForRate(fps,
                                                                                &canonicalTimescale,
                                                                                &canonicalFrameTicks);
        BOOL frameTimingLooksCanonical = hasCanonicalTiming &&
            fabs(fps - ((double)canonicalTimescale / (double)canonicalFrameTicks)) <= 0.05;

        NSString *duration = SpliceKitURLImportCMTimeStringFromSeconds([format[@"duration"] doubleValue],
                                                                       @"2400/2400s");
        NSString *frameDuration = hasCanonicalTiming
            ? [NSString stringWithFormat:@"%d/%ds", canonicalFrameTicks, canonicalTimescale]
            : @"100/2400s";

        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[@"duration"] = duration;
        info[@"width"] = @([videoStream[@"width"] intValue] ?: 1920);
        info[@"height"] = @([videoStream[@"height"] intValue] ?: 1080);
        info[@"frameDuration"] = frameDuration;
        info[@"hasVideo"] = @(videoStream != nil);
        info[@"hasAudio"] = @(audioStream != nil);
        info[@"audioRate"] = @([audioStream[@"sample_rate"] intValue]);
        info[@"videoCodec"] = videoCodecName ?: @"";
        if (audioCodecName.length > 0) info[@"audioCodec"] = audioCodecName;
        if (canonicalTimescale > 0) info[@"canonicalFrameTimescale"] = @(canonicalTimescale);
        if (canonicalFrameTicks > 0) info[@"canonicalFrameTicks"] = @(canonicalFrameTicks);
        info[@"frameTimingLooksCanonical"] = @(frameTimingLooksCanonical);
        info[@"canStreamCopyToMP4"] = @(canStreamCopyToMP4);

        if (canStreamCopyToMP4) {
            info[@"requiresNormalization"] = @YES;
            // Matroska + VP9/VP8: ALWAYS rewrite timestamps to canonical CFR
            // rather than trusting avg_frame_rate to be representative.
            // MKV packets are typically millisecond-quantized, so individual
            // frame deltas alternate (42ms, 41ms, 42ms, ...) even when the
            // average looks like a clean 24000/1001. If we just stream-copy
            // those timestamps into MP4 (time_base ends up 1/16000), FCP
            // plays back with visible pacing artifacts. The setts bsf gives
            // us a proper 24000/1001 time_base with uniform deltas.
            info[@"normalizationMode"] = hasCanonicalTiming
                ? @"remux_copy_rewrite_timestamps"
                : @"remux_copy";
        } else {
            info[@"requiresNormalization"] = @YES;
            info[@"normalizationMode"] = @"transcode";
        }
        return info;
    }

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
    BOOL requiresNormalization = !isMP4Family;
    NSString *normalizationMode = requiresNormalization ? @"transcode" : @"none";

    int width = 1920;
    int height = 1080;
    NSString *frameDuration = @"100/2400s";
    FourCharCode videoCodecType = SpliceKitURLImportVideoCodecType(videoTrack);
    NSString *videoCodec = SpliceKitURLImportFourCCString(videoCodecType);
    FourCharCode audioCodecType = SpliceKitURLImportAudioCodecType(audioTrack);
    NSString *audioCodec = SpliceKitURLImportFourCCString(audioCodecType);
    int canonicalTimescale = 0;
    int canonicalFrameTicks = 0;
    BOOL frameTimingLooksCanonical = NO;
    NSString *audioCodecLower = audioCodec.lowercaseString ?: @"";
    BOOL audioIsAACOrAbsent = (audioTrack == nil) ||
        [audioCodecLower containsString:@"aac"] ||
        [audioCodecLower isEqualToString:@"mp4a"];
    BOOL canStreamCopyToMP4 = (videoCodecType == 'vp09' || videoCodecType == 'vp08') &&
        audioIsAACOrAbsent;

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

        if (SpliceKitURLImportCanonicalFrameTimingForTrack(videoTrack,
                                                           &canonicalTimescale,
                                                           &canonicalFrameTicks) &&
            (videoCodecType == 'vp09' || videoCodecType == 'vp08')) {
            frameDuration = [NSString stringWithFormat:@"%d/%ds",
                             canonicalFrameTicks,
                             canonicalTimescale];
            frameTimingLooksCanonical = SpliceKitURLImportCMTimeMatchesRational(minFrameDuration,
                                                                                canonicalFrameTicks,
                                                                                canonicalTimescale);
            if (isMatroskaFamily && canStreamCopyToMP4) {
                requiresNormalization = YES;
                normalizationMode = frameTimingLooksCanonical
                    ? @"remux_copy"
                    : @"remux_copy_rewrite_timestamps";
            } else if (isMP4Family && !frameTimingLooksCanonical) {
                requiresNormalization = YES;
                normalizationMode = @"rewrite_timestamps";
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
    info[@"normalizationMode"] = normalizationMode;
    if (videoCodec.length > 0) info[@"videoCodec"] = videoCodec;
    if (audioCodec.length > 0) info[@"audioCodec"] = audioCodec;
    if (canonicalTimescale > 0) info[@"canonicalFrameTimescale"] = @(canonicalTimescale);
    if (canonicalFrameTicks > 0) info[@"canonicalFrameTicks"] = @(canonicalFrameTicks);
    info[@"frameTimingLooksCanonical"] = @(frameTimingLooksCanonical);
    info[@"canStreamCopyToMP4"] = @(canStreamCopyToMP4);
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
    NSString *mediaURL = SpliceKitURLImportEscapeXML(
        [[[NSURL fileURLWithPath:(job.normalizedPath ?: job.downloadPath)] absoluteURL] absoluteString]);
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
    NSString *normalizationMode = SpliceKitURLImportTrimmedString(mediaInfo[@"normalizationMode"]);
    if (!requiresNormalization) {
        job.normalizedPath = sourcePath;
        [self importJobIntoFinalCut:job mediaInfo:mediaInfo];
        return;
    }

    if (SpliceKitURLImportNormalizationModeUsesStreamCopy(normalizationMode)) {
        NSString *ffmpeg = SpliceKitURLImportFFmpegPath();
        if (ffmpeg.length == 0) {
            NSString *operationLabel = [normalizationMode isEqualToString:@"remux_copy"] ||
                                       [normalizationMode isEqualToString:@"remux_copy_rewrite_timestamps"]
                ? @"stream-copy remuxing"
                : @"VP9 timestamp normalization";
            [self finishJob:job
                    success:NO
                      state:SpliceKitURLImportStateFailed
                    message:[NSString stringWithFormat:@"%@ requires ffmpeg.",
                             [operationLabel capitalizedString]]
                      error:@"SpliceKit could not find ffmpeg to normalize this media without transcoding. Run `make url-import-tools` or put ffmpeg in ~/Applications/SpliceKit/tools/."];
            return;
        }

        BOOL needsTimestampRewrite = SpliceKitURLImportNormalizationModeNeedsTimestampRewrite(normalizationMode);
        NSNumber *timescaleValue = mediaInfo[@"canonicalFrameTimescale"];
        NSNumber *frameTicksValue = mediaInfo[@"canonicalFrameTicks"];
        int canonicalTimescale = timescaleValue.intValue;
        int canonicalFrameTicks = frameTicksValue.intValue;
        if (needsTimestampRewrite && (canonicalTimescale <= 0 || canonicalFrameTicks <= 0)) {
            [self finishJob:job
                    success:NO
                      state:SpliceKitURLImportStateFailed
                    message:@"VP9 timestamp normalization could not determine a stable frame rate."
                      error:@"SpliceKit could not derive a canonical CFR time base for this VP9 source."];
            return;
        }

        NSString *progressMessage = nil;
        if ([normalizationMode isEqualToString:@"remux_copy_rewrite_timestamps"]) {
            progressMessage = @"Remuxing into MP4 and rewriting VP9 timestamps for Final Cut Pro...";
        } else if ([normalizationMode isEqualToString:@"remux_copy"]) {
            progressMessage = @"Remuxing into MP4 for Final Cut Pro...";
        } else {
            progressMessage = @"Rewriting VP9 timestamps for smoother Final Cut playback...";
        }
        [self updateJob:job state:SpliceKitURLImportStateNormalizing
                message:progressMessage
               progress:0.82];

        NSString *outputExtension = SpliceKitURLImportOutputExtensionForNormalizationMode(normalizationMode);
        NSString *outputName = [NSString stringWithFormat:@"%@.%@",
            SpliceKitURLImportSanitizeFilename(job.clipName ?: @"Imported Clip"),
            outputExtension];
        NSString *outputPath = [self pathForFilename:outputName directory:[self normalizedDirectory]];
        [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:ffmpeg];
        NSMutableArray *arguments = [NSMutableArray arrayWithArray:@[
            @"-hide_banner",
            @"-y",
            @"-i", sourcePath,
            @"-map", @"0",
            @"-c", @"copy",
        ]];
        if (needsTimestampRewrite) {
            NSString *settsArg = [NSString stringWithFormat:
                @"setts=pts=N*%d:dts=N*%d:duration=%d:time_base=1/%d",
                canonicalFrameTicks,
                canonicalFrameTicks,
                canonicalFrameTicks,
                canonicalTimescale];
            [arguments addObjectsFromArray:@[@"-bsf:v", settsArg]];
        }
        [arguments addObjectsFromArray:@[@"-movflags", @"+faststart", outputPath]];
        task.arguments = arguments;

        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = pipe;

        NSMutableString *logBuffer = [NSMutableString string];
        NSFileHandle *readHandle = [pipe fileHandleForReading];
        readHandle.readabilityHandler = ^(NSFileHandle *handle) {
            NSData *data = [handle availableData];
            if (data.length == 0) return;
            NSString *chunk = SpliceKitURLImportStringFromData(data);
            if (chunk.length == 0) return;
            @synchronized (logBuffer) {
                [logBuffer appendString:chunk];
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
                if (job.resolverTask == task) job.resolverTask = nil;
            }

            if (job.cancelled) {
                [self finishJob:job
                        success:NO
                          state:SpliceKitURLImportStateCancelled
                        message:@"URL import was cancelled during media normalization."
                          error:nil];
                return;
            }

            NSString *fullLog = nil;
            @synchronized (logBuffer) {
                fullLog = [logBuffer copy];
            }
            NSString *trimmedLog = SpliceKitURLImportTrimmedString(fullLog);

            if (task.terminationStatus != 0) {
                [self finishJob:job
                        success:NO
                          state:SpliceKitURLImportStateFailed
                        message:@"Media normalization failed."
                          error:(trimmedLog.length > 0 ? trimmedLog : @"ffmpeg failed while normalizing the source media.")];
                return;
            }

            NSDictionary *rewrittenInfo = [self inspectMediaAtPath:outputPath];
            if (rewrittenInfo[@"error"]) {
                [self finishJob:job
                        success:NO
                          state:SpliceKitURLImportStateFailed
                        message:@"Normalized media could not be inspected."
                          error:rewrittenInfo[@"error"]];
                return;
            }

            dispatch_async(self.stateQueue, ^{
                job.normalizedPath = outputPath;
                job.updatedAt = [NSDate date];
            });

            NSMutableDictionary *normalizedInfo = [rewrittenInfo mutableCopy];
            normalizedInfo[@"requiresNormalization"] = @NO;
            normalizedInfo[@"normalizationMode"] = @"none";
            [self importJobIntoFinalCut:job mediaInfo:normalizedInfo];
        };

        NSError *launchError = nil;
        @synchronized (job) {
            job.resolverTask = task;
        }
        if (![task launchAndReturnError:&launchError]) {
            @synchronized (job) {
                if (job.resolverTask == task) job.resolverTask = nil;
            }
            [self finishJob:job
                    success:NO
                      state:SpliceKitURLImportStateFailed
                    message:@"Media normalization could not start."
                      error:(launchError.localizedDescription ?: @"Could not launch ffmpeg for stream-copy normalization.")];
            return;
        }
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
            @"Unsupported URL source. This build supports direct .mp4/.mov/.m4v/.webm/.mkv links plus YouTube and Vimeo URLs through yt-dlp."];
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

static id (*sSpliceKitURLImportOriginalNewClipFromURLManageFileType)(id, SEL, id, int) = NULL;
static id (*sSpliceKitURLImportOriginalFFFileImporterImportToEvent)(id, SEL, id, int, BOOL, BOOL, id *) = NULL;
static id (*sSpliceKitURLImportOriginalFFFileImporterImportFileURLs)(id, SEL, id, id, id, int, BOOL, BOOL, id, id, id) = NULL;
static BOOL (*sSpliceKitURLImportOriginalFFFileImporterValidateURLs)(id, SEL, id, id, id, BOOL, id, BOOL, id *, id) = NULL;
static void (*sSpliceKitURLImportOriginalFFFileImporterScanURLForFiles)(id, SEL, id, id, id, id, id, id, void *) = NULL;
static NSDragOperation (*sSpliceKitURLImportOriginalTLKTimelineViewDraggingEntered)(id, SEL, id) = NULL;
static char (*sSpliceKitURLImportOriginalTLKTimelineViewPerformDragOperation)(id, SEL, id) = NULL;
static IMP sSpliceKitURLImportOriginalProviderFigExtensionsIMP = NULL;
static IMP sSpliceKitURLImportOriginalProviderFigUTIsIMP = NULL;
static BOOL sSpliceKitURLImportVP9ImportHookInstalled = NO;
static BOOL sSpliceKitURLImportProviderShimInstalled = NO;

static NSDictionary *SpliceKitURLImportRewriteVP9TimestampsSynchronously(NSString *sourcePath,
                                                                         NSString *clipName,
                                                                         NSDictionary *mediaInfo,
                                                                         NSString **outError) {
    NSString *ffmpeg = SpliceKitURLImportFFmpegPath();
    if (ffmpeg.length == 0) {
        if (outError) {
            *outError = @"SpliceKit could not find ffmpeg to normalize this media during import.";
        }
        return nil;
    }

    NSString *normalizationMode = SpliceKitURLImportTrimmedString(mediaInfo[@"normalizationMode"]);
    BOOL needsTimestampRewrite = SpliceKitURLImportNormalizationModeNeedsTimestampRewrite(normalizationMode);
    if (!SpliceKitURLImportNormalizationModeUsesStreamCopy(normalizationMode)) {
        if (outError) {
            *outError = @"SpliceKit could not stream-copy normalize this source.";
        }
        return nil;
    }

    int canonicalTimescale = [mediaInfo[@"canonicalFrameTimescale"] intValue];
    int canonicalFrameTicks = [mediaInfo[@"canonicalFrameTicks"] intValue];
    if (needsTimestampRewrite && (canonicalTimescale <= 0 || canonicalFrameTicks <= 0)) {
        if (outError) {
            *outError = @"SpliceKit could not derive a canonical CFR time base for this VP9 source.";
        }
        return nil;
    }

    NSString *safeName = SpliceKitURLImportSanitizeFilename(clipName.length > 0
        ? clipName
        : [[sourcePath lastPathComponent] stringByDeletingPathExtension]);
    NSString *outputExtension = SpliceKitURLImportOutputExtensionForNormalizationMode(normalizationMode);
    NSString *outputName = [NSString stringWithFormat:@"%@.%@", safeName, outputExtension];
    NSString *outputPath = SpliceKitURLImportUniquePathForFilename(outputName,
                                                                   SpliceKitURLImportSharedNormalizedDirectory());
    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:ffmpeg];
    NSMutableArray *arguments = [NSMutableArray arrayWithArray:@[
        @"-hide_banner",
        @"-y",
        @"-i", sourcePath,
        @"-map", @"0",
        @"-c", @"copy",
    ]];
    if (needsTimestampRewrite) {
        NSString *settsArg = [NSString stringWithFormat:
            @"setts=pts=N*%d:dts=N*%d:duration=%d:time_base=1/%d",
            canonicalFrameTicks,
            canonicalFrameTicks,
            canonicalFrameTicks,
            canonicalTimescale];
        [arguments addObjectsFromArray:@[@"-bsf:v", settsArg]];
    }
    [arguments addObjectsFromArray:@[@"-movflags", @"+faststart", outputPath]];
    task.arguments = arguments;

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (outError) {
            *outError = launchError.localizedDescription ?: @"Could not launch ffmpeg for VP9 timestamp normalization.";
        }
        return nil;
    }

    NSData *logData = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *ffmpegLog = SpliceKitURLImportTrimmedString(SpliceKitURLImportStringFromData(logData));
    if (task.terminationStatus != 0) {
        if (outError) {
            *outError = ffmpegLog.length > 0 ? ffmpegLog : @"ffmpeg failed while rewriting VP9 timestamps.";
        }
        return nil;
    }

    NSDictionary *rewrittenInfo = [[SpliceKitURLImportService sharedService] inspectMediaAtPath:outputPath];
    if (rewrittenInfo[@"error"]) {
        if (outError) *outError = rewrittenInfo[@"error"];
        return nil;
    }

    return @{
        @"path": outputPath,
        @"mediaInfo": rewrittenInfo,
    };
}

static id SpliceKitURLImportProviderFigExtensions(id self, SEL _cmd) {
    id base = sSpliceKitURLImportOriginalProviderFigExtensionsIMP
        ? ((id (*)(id, SEL))sSpliceKitURLImportOriginalProviderFigExtensionsIMP)(self, _cmd)
        : nil;
    return [SpliceKitURLImportUniqueStrings(base, @[@"mkv", @"webm"]) copy];
}

static id SpliceKitURLImportProviderFigUTIs(id self, SEL _cmd) {
    id base = sSpliceKitURLImportOriginalProviderFigUTIsIMP
        ? ((id (*)(id, SEL))sSpliceKitURLImportOriginalProviderFigUTIsIMP)(self, _cmd)
        : nil;
    return [SpliceKitURLImportUniqueStrings(base,
                                            @[@"org.matroska.mkv",
                                              @"org.webmproject.webm"]) copy];
}

static BOOL SpliceKitURLImport_installProviderShim(void) {
    if (sSpliceKitURLImportProviderShimInstalled) return YES;

    Class providerFigClass = objc_getClass("FFProviderFig");
    if (!providerFigClass) {
        SpliceKit_log(@"[VP9Import] FFProviderFig unavailable; Matroska provider shim not installed");
        return NO;
    }

    @try {
        Method extensionsMethod = class_getClassMethod(providerFigClass, @selector(extensions));
        Method utisMethod = class_getClassMethod(providerFigClass, @selector(utis));
        if (!extensionsMethod || !utisMethod) {
            SpliceKit_log(@"[VP9Import] FFProviderFig missing extensions/utis methods; Matroska provider shim not installed");
            return NO;
        }

        if (!sSpliceKitURLImportOriginalProviderFigExtensionsIMP) {
            sSpliceKitURLImportOriginalProviderFigExtensionsIMP = method_setImplementation(
                extensionsMethod,
                (IMP)SpliceKitURLImportProviderFigExtensions);
        }
        if (!sSpliceKitURLImportOriginalProviderFigUTIsIMP) {
            sSpliceKitURLImportOriginalProviderFigUTIsIMP = method_setImplementation(
                utisMethod,
                (IMP)SpliceKitURLImportProviderFigUTIs);
        }

        sSpliceKitURLImportProviderShimInstalled =
            (sSpliceKitURLImportOriginalProviderFigExtensionsIMP != NULL) &&
            (sSpliceKitURLImportOriginalProviderFigUTIsIMP != NULL);
        if (sSpliceKitURLImportProviderShimInstalled) {
            SpliceKit_log(@"[VP9Import] Installed FFProviderFig Matroska/WebM provider shim");
        } else {
            SpliceKit_log(@"[VP9Import] FFProviderFig Matroska/WebM provider shim incomplete");
        }
        return sSpliceKitURLImportProviderShimInstalled;
    } @catch (NSException *e) {
        SpliceKit_log(@"[VP9Import] Exception installing Matroska/WebM provider shim: %@", e.reason);
        return NO;
    }
}

static NSURL *SpliceKitURLImportMaybeRewriteLocalFileURL(NSURL *fileURL,
                                                         NSString **outError) {
    if (![fileURL isKindOfClass:[NSURL class]] || !fileURL.isFileURL) return fileURL;

    NSString *sourcePath = fileURL.path.stringByStandardizingPath;
    if (SpliceKitURLImportPathIsWithinDirectory(sourcePath,
                                                SpliceKitURLImportSharedNormalizedDirectory())) {
        return fileURL;
    }

    NSDictionary *mediaInfo = [[SpliceKitURLImportService sharedService] inspectMediaAtPath:sourcePath];
    NSString *normalizationMode = SpliceKitURLImportTrimmedString(mediaInfo[@"normalizationMode"]);
    if (!SpliceKitURLImportNormalizationModeUsesStreamCopy(normalizationMode)) return fileURL;

    NSString *clipName = [[sourcePath lastPathComponent] stringByDeletingPathExtension];
    NSDictionary *rewriteResult = SpliceKitURLImportRewriteVP9TimestampsSynchronously(sourcePath,
                                                                                      clipName,
                                                                                      mediaInfo,
                                                                                      outError);
    NSString *rewrittenPath = SpliceKitURLImportTrimmedString(rewriteResult[@"path"]);
    if (rewrittenPath.length == 0) return fileURL;
    return [NSURL fileURLWithPath:rewrittenPath];
}

static NSArray<NSURL *> *SpliceKitURLImportFileURLsFromPasteboard(NSPasteboard *pasteboard) {
    if (![pasteboard isKindOfClass:[NSPasteboard class]]) return @[];

    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[[NSURL class]]
                                                       options:@{ NSPasteboardURLReadingFileURLsOnlyKey : @YES }];
    if (urls.count > 0) return urls;

    NSArray *filenamePaths = [pasteboard propertyListForType:NSFilenamesPboardType];
    if (![filenamePaths isKindOfClass:[NSArray class]] || filenamePaths.count == 0) return @[];

    NSMutableArray<NSURL *> *fileURLs = [NSMutableArray arrayWithCapacity:filenamePaths.count];
    for (id item in filenamePaths) {
        if (![item isKindOfClass:[NSString class]]) continue;
        [fileURLs addObject:[NSURL fileURLWithPath:[(NSString *)item stringByStandardizingPath]]];
    }
    return [fileURLs copy];
}

static BOOL SpliceKitURLImportRewriteFileURLsOnPasteboard(NSPasteboard *pasteboard) {
    NSArray<NSURL *> *fileURLs = SpliceKitURLImportFileURLsFromPasteboard(pasteboard);
    if (fileURLs.count == 0) return NO;

    NSMutableArray<NSURL *> *rewrittenURLs = [NSMutableArray arrayWithCapacity:fileURLs.count];
    BOOL changed = NO;

    for (NSURL *fileURL in fileURLs) {
        NSString *errorText = nil;
        NSURL *rewrittenURL = SpliceKitURLImportMaybeRewriteLocalFileURL(fileURL, &errorText);
        if (rewrittenURL && ![rewrittenURL isEqual:fileURL]) {
            changed = YES;
            SpliceKit_log(@"[VP9Import] Rewrote dragged URL %@ -> %@",
                          fileURL.path, rewrittenURL.path);
        } else if (errorText.length > 0) {
            SpliceKit_log(@"[VP9Import] Drag rewrite failed for %@: %@. Falling back to original file.",
                          fileURL.path, errorText);
        }
        [rewrittenURLs addObject:rewrittenURL ?: fileURL];
    }

    if (!changed) return NO;

    @try {
        [pasteboard clearContents];
        BOOL wrote = [pasteboard writeObjects:rewrittenURLs];
        if (!wrote) {
            SpliceKit_log(@"[VP9Import] Failed to write rewritten dragged URLs back to pasteboard");
            return NO;
        }
        SpliceKit_log(@"[VP9Import] Rewrote %lu dragged file URL(s) on pasteboard",
                      (unsigned long)rewrittenURLs.count);
        return YES;
    } @catch (NSException *e) {
        SpliceKit_log(@"[VP9Import] Exception while rewriting drag pasteboard: %@", e.reason);
        return NO;
    }
}

static id SpliceKitURLImportRemapObject(id value, NSDictionary<NSURL *, NSURL *> *rewriteMap) {
    if (!value || rewriteMap.count == 0) return value;

    if ([value isKindOfClass:[NSURL class]]) {
        NSURL *mapped = rewriteMap[(NSURL *)value];
        return mapped ?: value;
    }

    if ([value isKindOfClass:[NSString class]]) {
        NSString *stringValue = (NSString *)value;
        for (NSURL *originalURL in rewriteMap) {
            NSURL *rewrittenURL = rewriteMap[originalURL];
            if ([stringValue isEqualToString:originalURL.path] ||
                [stringValue isEqualToString:originalURL.absoluteString]) {
                return [stringValue isEqualToString:originalURL.path]
                    ? rewrittenURL.path
                    : rewrittenURL.absoluteString;
            }
        }
        return value;
    }

    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)value;
        NSMutableArray *mapped = [NSMutableArray arrayWithCapacity:array.count];
        BOOL changed = NO;
        for (id item in array) {
            id remapped = SpliceKitURLImportRemapObject(item, rewriteMap);
            if (remapped != item) changed = YES;
            [mapped addObject:remapped ?: [NSNull null]];
        }
        if (!changed) return value;
        return [value isKindOfClass:[NSMutableArray class]] ? mapped : [mapped copy];
    }

    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = (NSDictionary *)value;
        NSMutableDictionary *mapped = [NSMutableDictionary dictionaryWithCapacity:dictionary.count];
        BOOL changed = NO;
        for (id key in dictionary) {
            id remappedKey = SpliceKitURLImportRemapObject(key, rewriteMap) ?: [NSNull null];
            id remappedValue = SpliceKitURLImportRemapObject(dictionary[key], rewriteMap) ?: [NSNull null];
            if (remappedKey != key || remappedValue != dictionary[key]) changed = YES;
            mapped[remappedKey] = remappedValue;
        }
        if (!changed) return value;
        return [value isKindOfClass:[NSMutableDictionary class]] ? mapped : [mapped copy];
    }

    return value;
}

static id SpliceKitURLImportRewriteURLCollection(id urlCollection,
                                                 NSMutableDictionary<NSURL *, NSURL *> *rewriteMap) {
    if (![urlCollection isKindOfClass:[NSArray class]]) return urlCollection;

    NSArray *urls = (NSArray *)urlCollection;
    NSMutableArray *rewritten = [NSMutableArray arrayWithCapacity:urls.count];
    BOOL changed = NO;

    for (id item in urls) {
        id newItem = item;
        if ([item isKindOfClass:[NSURL class]] && ((NSURL *)item).isFileURL) {
            NSURL *existingRewrite = rewriteMap[(NSURL *)item];
            if (existingRewrite) {
                newItem = existingRewrite;
                changed = YES;
            } else {
                NSString *errorText = nil;
                NSURL *rewrittenURL = SpliceKitURLImportMaybeRewriteLocalFileURL((NSURL *)item, &errorText);
                if (rewrittenURL && ![rewrittenURL isEqual:item]) {
                    rewriteMap[(NSURL *)item] = rewrittenURL;
                    newItem = rewrittenURL;
                    changed = YES;
                    SpliceKit_log(@"[VP9Import] Rewrote importer URL %@ -> %@",
                                  ((NSURL *)item).path, rewrittenURL.path);
                } else if (errorText.length > 0) {
                    SpliceKit_log(@"[VP9Import] Importer rewrite failed for %@: %@. Falling back to original file.",
                                  ((NSURL *)item).path, errorText);
                }
            }
        }
        [rewritten addObject:newItem ?: [NSNull null]];
    }

    if (!changed) return urlCollection;
    return [urlCollection isKindOfClass:[NSMutableArray class]] ? rewritten : [rewritten copy];
}

static void SpliceKitURLImportRewriteFFFileImporterIvarsIfNeeded(id importer) {
    if (!importer) return;

    @try {
        Class importerClass = object_getClass(importer);
        Ivar importURLsIvar = class_getInstanceVariable(importerClass, "_importURLs");
        Ivar acceptedURLsIvar = class_getInstanceVariable(importerClass, "_acceptedURLs");
        Ivar importURLsInfoIvar = class_getInstanceVariable(importerClass, "_importURLsInfo");

        NSMutableDictionary<NSURL *, NSURL *> *rewriteMap = [NSMutableDictionary dictionary];

        if (importURLsIvar) {
            id originalImportURLs = object_getIvar(importer, importURLsIvar);
            id rewrittenImportURLs = SpliceKitURLImportRewriteURLCollection(originalImportURLs, rewriteMap);
            if (rewrittenImportURLs != originalImportURLs) {
                object_setIvar(importer, importURLsIvar, rewrittenImportURLs);
            }
        }

        if (acceptedURLsIvar) {
            id originalAcceptedURLs = object_getIvar(importer, acceptedURLsIvar);
            id rewrittenAcceptedURLs = SpliceKitURLImportRewriteURLCollection(originalAcceptedURLs, rewriteMap);
            if (rewrittenAcceptedURLs != originalAcceptedURLs) {
                object_setIvar(importer, acceptedURLsIvar, rewrittenAcceptedURLs);
            }
        }

        if (rewriteMap.count > 0 && importURLsInfoIvar) {
            id originalURLsInfo = object_getIvar(importer, importURLsInfoIvar);
            id rewrittenURLsInfo = SpliceKitURLImportRemapObject(originalURLsInfo, rewriteMap);
            if (rewrittenURLsInfo != originalURLsInfo) {
                object_setIvar(importer, importURLsInfoIvar, rewrittenURLsInfo);
            }
            SpliceKit_log(@"[VP9Import] Rewrote %lu importer pending URL(s) before Media Import ingest",
                          (unsigned long)rewriteMap.count);
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[VP9Import] Exception while rewriting FFFileImporter ivars: %@", e.reason);
    }
}

static id SpliceKitURLImport_swizzled_newClipFromURL_manageFileType(id self,
                                                                    SEL _cmd,
                                                                    id sourceURL,
                                                                    int manageFileType) {
    id importURL = sourceURL;

    @try {
        if ([sourceURL isKindOfClass:[NSURL class]] && ((NSURL *)sourceURL).isFileURL) {
            NSURL *fileURL = (NSURL *)sourceURL;
            NSString *sourcePath = fileURL.path.stringByStandardizingPath;
            NSDictionary *mediaInfo = [[SpliceKitURLImportService sharedService] inspectMediaAtPath:sourcePath];
            NSString *normalizationMode = SpliceKitURLImportTrimmedString(mediaInfo[@"normalizationMode"]);
            if (SpliceKitURLImportNormalizationModeUsesStreamCopy(normalizationMode)) {
                SpliceKit_log(@"[VP9Import] Preparing local import %@ with mode %@",
                              sourcePath, normalizationMode);
                NSString *errorText = nil;
                NSString *clipName = [[sourcePath lastPathComponent] stringByDeletingPathExtension];
                NSDictionary *rewriteResult = SpliceKitURLImportRewriteVP9TimestampsSynchronously(sourcePath,
                                                                                                  clipName,
                                                                                                  mediaInfo,
                                                                                                  &errorText);
                NSString *rewrittenPath = SpliceKitURLImportTrimmedString(rewriteResult[@"path"]);
                if (rewrittenPath.length > 0) {
                    importURL = [NSURL fileURLWithPath:rewrittenPath];
                    SpliceKit_log(@"[VP9Import] Rewrote local import %@ -> %@",
                                  sourcePath, rewrittenPath);
                } else if (errorText.length > 0) {
                    SpliceKit_log(@"[VP9Import] Stream-copy normalization failed for %@: %@. Falling back to original file.",
                                  sourcePath, errorText);
                }
            }
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[VP9Import] Exception while preparing local import: %@", e.reason);
    }

    if (sSpliceKitURLImportOriginalNewClipFromURLManageFileType) {
        return sSpliceKitURLImportOriginalNewClipFromURLManageFileType(self, _cmd, importURL, manageFileType);
    }
    return nil;
}

static id SpliceKitURLImport_swizzled_FFFileImporter_importToEvent(id self,
                                                                   SEL _cmd,
                                                                   id event,
                                                                   int manageFileType,
                                                                   BOOL processNow,
                                                                   BOOL warnClipsAlreadyExist,
                                                                   id *error) {
    SpliceKitURLImportRewriteFFFileImporterIvarsIfNeeded(self);
    if (sSpliceKitURLImportOriginalFFFileImporterImportToEvent) {
        return sSpliceKitURLImportOriginalFFFileImporterImportToEvent(self,
                                                                      _cmd,
                                                                      event,
                                                                      manageFileType,
                                                                      processNow,
                                                                      warnClipsAlreadyExist,
                                                                      error);
    }
    return nil;
}

static NSDragOperation SpliceKitURLImport_swizzled_TLKTimelineView_draggingEntered(id self,
                                                                                    SEL _cmd,
                                                                                    id draggingInfo) {
    @try {
        id pasteboard = [draggingInfo respondsToSelector:@selector(draggingPasteboard)]
            ? [draggingInfo draggingPasteboard]
            : nil;
        if (SpliceKitURLImportRewriteFileURLsOnPasteboard(pasteboard)) {
            SpliceKit_log(@"[VP9Import] Rewrote timeline drag pasteboard before draggingEntered");
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[VP9Import] Exception in timeline draggingEntered rewrite: %@", e.reason);
    }

    if (sSpliceKitURLImportOriginalTLKTimelineViewDraggingEntered) {
        return sSpliceKitURLImportOriginalTLKTimelineViewDraggingEntered(self, _cmd, draggingInfo);
    }
    return NSDragOperationNone;
}

static char SpliceKitURLImport_swizzled_TLKTimelineView_performDragOperation(id self,
                                                                              SEL _cmd,
                                                                              id draggingInfo) {
    @try {
        id pasteboard = [draggingInfo respondsToSelector:@selector(draggingPasteboard)]
            ? [draggingInfo draggingPasteboard]
            : nil;
        if (SpliceKitURLImportRewriteFileURLsOnPasteboard(pasteboard)) {
            SpliceKit_log(@"[VP9Import] Rewrote timeline drag pasteboard before performDragOperation");
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[VP9Import] Exception in timeline performDragOperation rewrite: %@", e.reason);
    }

    if (sSpliceKitURLImportOriginalTLKTimelineViewPerformDragOperation) {
        return sSpliceKitURLImportOriginalTLKTimelineViewPerformDragOperation(self, _cmd, draggingInfo);
    }
    return 0;
}

static BOOL SpliceKitURLImport_swizzled_FFFileImporter_validateURLs(id self,
                                                                    SEL _cmd,
                                                                    id urls,
                                                                    id urlsInfo,
                                                                    id importLocation,
                                                                    BOOL showWarnings,
                                                                    id window,
                                                                    BOOL copyFiles,
                                                                    id *acceptedURLs,
                                                                    id options) {
    NSMutableDictionary<NSURL *, NSURL *> *rewriteMap = [NSMutableDictionary dictionary];
    id rewrittenURLs = SpliceKitURLImportRewriteURLCollection(urls, rewriteMap);
    id rewrittenURLsInfo = rewriteMap.count > 0
        ? SpliceKitURLImportRemapObject(urlsInfo, rewriteMap)
        : urlsInfo;

    NSUInteger inputCount = [urls respondsToSelector:@selector(count)] ? [urls count] : 0;
    if (rewriteMap.count > 0) {
        SpliceKit_log(@"[VP9Import] Rewrote %lu of %lu URL(s) before FFFileImporter validation",
                      (unsigned long)rewriteMap.count, (unsigned long)inputCount);
    }

    BOOL result = NO;
    if (sSpliceKitURLImportOriginalFFFileImporterValidateURLs) {
        result = sSpliceKitURLImportOriginalFFFileImporterValidateURLs(self,
                                                                       _cmd,
                                                                       rewrittenURLs,
                                                                       rewrittenURLsInfo,
                                                                       importLocation,
                                                                       showWarnings,
                                                                       window,
                                                                       copyFiles,
                                                                       acceptedURLs,
                                                                       options);
    }

    // FCP's downstream processFiles:/_importBackgroundTask path accesses
    // keywordSets[i] in parallel with fileURLs[i]. If validation rejected any
    // URL, the counts diverge and -[__NSArrayM removeObjectsInRange:] (or
    // objectAtIndexedSubscript:) throws NSRangeException. This is an FCP
    // latent bug that surfaces any time our rewrite leads to a rejection —
    // even when the rewritten MP4 is technically valid, FCP's preflight can
    // still reject edge cases.
    //
    // Mitigation: after the real validateURLs runs, log counts so we can
    // diagnose mismatches, and normalize the ivars to match our rewriteMap.
    // The accepted-URL rewrite in importToEvent only fires on the instance
    // import path; mirror it here so the class-method path gets it too.
    if (rewriteMap.count > 0) {
        @try {
            NSUInteger acceptedCount =
                (acceptedURLs && *acceptedURLs && [(id)*acceptedURLs respondsToSelector:@selector(count)])
                    ? [(id)*acceptedURLs count] : 0;
            SpliceKit_log(@"[VP9Import] validateURLs returned result=%d acceptedURLs.count=%lu input.count=%lu",
                          (int)result, (unsigned long)acceptedCount, (unsigned long)inputCount);
            if (acceptedCount != inputCount) {
                SpliceKit_log(@"[VP9Import] WARNING: acceptedURLs.count != input.count — FCP rejected some rewrites. _importBackgroundTask may crash on keywordSets[i] overrun.");
            }

            Ivar importURLsIvar = class_getInstanceVariable(object_getClass(self), "_importURLs");
            Ivar acceptedURLsIvar = class_getInstanceVariable(object_getClass(self), "_acceptedURLs");
            if (importURLsIvar) {
                NSUInteger c = [(id)object_getIvar(self, importURLsIvar) respondsToSelector:@selector(count)]
                    ? [(id)object_getIvar(self, importURLsIvar) count] : 0;
                SpliceKit_log(@"[VP9Import] post-validate _importURLs.count=%lu", (unsigned long)c);
            }
            if (acceptedURLsIvar) {
                NSUInteger c = [(id)object_getIvar(self, acceptedURLsIvar) respondsToSelector:@selector(count)]
                    ? [(id)object_getIvar(self, acceptedURLsIvar) count] : 0;
                SpliceKit_log(@"[VP9Import] post-validate _acceptedURLs.count=%lu", (unsigned long)c);
            }

            // Rewrite ivars to fold any remaining original-MKV paths into our
            // shadow-MP4 paths. Safe even if FCP already rewrote — idempotent.
            SpliceKitURLImportRewriteFFFileImporterIvarsIfNeeded(self);
        } @catch (NSException *e) {
            SpliceKit_log(@"[VP9Import] Exception in post-validate instrumentation: %@", e.reason);
        }
    }

    return result;
}

static void SpliceKitURLImport_swizzled_FFFileImporter_scanURLForFiles(id self,
                                                                       SEL _cmd,
                                                                       id url,
                                                                       id fileURLs,
                                                                       id keywordSets,
                                                                       id keywords,
                                                                       id rejectedURLs,
                                                                       id rejectedURLExtensions,
                                                                       void *rejectedReasons) {
    id scannedURL = url;
    @try {
        if ([url isKindOfClass:[NSURL class]] && ((NSURL *)url).isFileURL) {
            NSString *errorText = nil;
            NSURL *rewrittenURL = SpliceKitURLImportMaybeRewriteLocalFileURL((NSURL *)url, &errorText);
            if (rewrittenURL && ![rewrittenURL isEqual:url]) {
                scannedURL = rewrittenURL;
                SpliceKit_log(@"[VP9Import] Rewrote scanned URL %@ -> %@",
                              ((NSURL *)url).path, rewrittenURL.path);
            } else if (errorText.length > 0) {
                SpliceKit_log(@"[VP9Import] Scan rewrite failed for %@: %@. Falling back to original file.",
                              ((NSURL *)url).path, errorText);
            }
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[VP9Import] Exception while rewriting scan URL: %@", e.reason);
    }

    if (sSpliceKitURLImportOriginalFFFileImporterScanURLForFiles) {
        sSpliceKitURLImportOriginalFFFileImporterScanURLForFiles(self,
                                                                 _cmd,
                                                                 scannedURL,
                                                                 fileURLs,
                                                                 keywordSets,
                                                                 keywords,
                                                                 rejectedURLs,
                                                                 rejectedURLExtensions,
                                                                 rejectedReasons);
    }
}

// Pads a parallel-per-URL array to the URL count so FCP's
// +_importBackgroundTask: can do array[i] without NSRangeException.
// `fill` is the value to use for missing slots — must be a type FCP will
// actually send messages to downstream (e.g. NSSet for keywords, NSDictionary
// for metadata). NSNull survives the index access but crashes in forwarding
// when FCP later calls set/dictionary selectors on it.
static id SpliceKitURLImportPadParallelArray(id candidate,
                                             NSUInteger targetCount,
                                             id fill,
                                             NSString *label) {
    if (targetCount == 0) return candidate;
    if (!candidate || ![candidate isKindOfClass:[NSArray class]]) {
        NSMutableArray *padded = [NSMutableArray arrayWithCapacity:targetCount];
        for (NSUInteger i = 0; i < targetCount; i++) {
            [padded addObject:fill];
        }
        SpliceKit_log(@"[VP9Import] Materialized missing %@ array (%lu entries)",
                      label, (unsigned long)targetCount);
        return padded;
    }

    NSArray *array = (NSArray *)candidate;
    if (array.count >= targetCount) return candidate;

    NSMutableArray *padded = [array mutableCopy];
    NSUInteger missing = targetCount - array.count;
    for (NSUInteger i = 0; i < missing; i++) {
        [padded addObject:fill];
    }
    SpliceKit_log(@"[VP9Import] Padded %@ %lu -> %lu to match URL count",
                  label, (unsigned long)array.count, (unsigned long)targetCount);
    return padded;
}

static id SpliceKitURLImport_swizzled_FFFileImporter_importFileURLs(id self,
                                                                    SEL _cmd,
                                                                    id fileURLs,
                                                                    id fileURLsInfo,
                                                                    id event,
                                                                    int manageFileType,
                                                                    BOOL processNow,
                                                                    BOOL warnClipsAlreadyExist,
                                                                    id keywordSets,
                                                                    id metadataArray,
                                                                    id completionBlock) {
    NSMutableDictionary<NSURL *, NSURL *> *rewriteMap = [NSMutableDictionary dictionary];
    id rewrittenURLs = SpliceKitURLImportRewriteURLCollection(fileURLs, rewriteMap);
    id rewrittenURLsInfo = rewriteMap.count > 0
        ? SpliceKitURLImportRemapObject(fileURLsInfo, rewriteMap)
        : fileURLsInfo;

    if (rewriteMap.count > 0) {
        SpliceKit_log(@"[VP9Import] Rewrote %lu Media Import URL(s) before FFFileImporter class import",
                      (unsigned long)rewriteMap.count);
    }

    // FCP's +_importBackgroundTask: iterates fileURLs and does
    //   keywordSets[i] and metadataArray[i]
    // under the assumption that keywordSets.count == metadataArray.count ==
    // fileURLs.count. When the Media Import UI never prepared keywords for
    // a greyed row (common for our remuxed MKVs), keywordSets can be an
    // empty array and keywordSets[0] throws NSRangeException — which
    // surfaces as a confusing -[__NSArrayM removeObjectsInRange:] crash
    // after exception unwinding. Force-pad both arrays to the URL count so
    // the parallel-index access always stays in range.
    NSUInteger urlCount = [rewrittenURLs respondsToSelector:@selector(count)]
        ? [rewrittenURLs count] : 0;
    // keywords per URL → empty NSSet; metadata per URL → empty NSDictionary.
    // FCP's downstream -newAnchoredSequenceFromAssetRef:...keywords:... sends
    // set-shaped selectors to each entry; handing it NSNull triggers the
    // `_CF_forwarding_prep_0` forwarding-failure crash.
    id safeKeywordSets = SpliceKitURLImportPadParallelArray(keywordSets,
                                                             urlCount,
                                                             [NSSet set],
                                                             @"keywordSets");
    id safeMetadataArray = SpliceKitURLImportPadParallelArray(metadataArray,
                                                               urlCount,
                                                               @{},
                                                               @"metadataArray");

    if (sSpliceKitURLImportOriginalFFFileImporterImportFileURLs) {
        return sSpliceKitURLImportOriginalFFFileImporterImportFileURLs(self,
                                                                       _cmd,
                                                                       rewrittenURLs,
                                                                       rewrittenURLsInfo,
                                                                       event,
                                                                       manageFileType,
                                                                       processNow,
                                                                       warnClipsAlreadyExist,
                                                                       safeKeywordSets,
                                                                       safeMetadataArray,
                                                                       completionBlock);
    }
    return nil;
}

void SpliceKitURLImport_installVP9ImportHook(void) {
    if (sSpliceKitURLImportVP9ImportHookInstalled) return;

    (void)SpliceKitURLImport_installProviderShim();

    Class projectClass = objc_getClass("FFMediaEventProject");
    SEL selector = NSSelectorFromString(@"newClipFromURL:manageFileType:");
    Method method = projectClass ? class_getInstanceMethod(projectClass, selector) : NULL;
    if (!method) {
        SpliceKit_log(@"[VP9Import] FFMediaEventProject.newClipFromURL:manageFileType: not available");
        return;
    }

    sSpliceKitURLImportOriginalNewClipFromURLManageFileType =
        (id (*)(id, SEL, id, int))method_setImplementation(
            method,
            (IMP)SpliceKitURLImport_swizzled_newClipFromURL_manageFileType);

    Class fileImporterClass = objc_getClass("FFFileImporter");
    SEL importToEventSelector = NSSelectorFromString(@"importToEvent:manageFileType:processNow:warnClipsAlreadyExist:error:");
    Method importToEventMethod = fileImporterClass ? class_getInstanceMethod(fileImporterClass, importToEventSelector) : NULL;
    if (importToEventMethod) {
        sSpliceKitURLImportOriginalFFFileImporterImportToEvent =
            (id (*)(id, SEL, id, int, BOOL, BOOL, id *))method_setImplementation(
                importToEventMethod,
                (IMP)SpliceKitURLImport_swizzled_FFFileImporter_importToEvent);
    } else {
        SpliceKit_log(@"[VP9Import] FFFileImporter.importToEvent:... not available");
    }

    SEL validateURLsSelector = NSSelectorFromString(@"validateURLs:withURLsInfo:forImportToLocation:showWarnings:window:copyFiles:acceptedURLs:options:");
    Method validateURLsMethod = fileImporterClass ? class_getInstanceMethod(fileImporterClass, validateURLsSelector) : NULL;
    if (validateURLsMethod) {
        sSpliceKitURLImportOriginalFFFileImporterValidateURLs =
            (BOOL (*)(id, SEL, id, id, id, BOOL, id, BOOL, id *, id))method_setImplementation(
                validateURLsMethod,
                (IMP)SpliceKitURLImport_swizzled_FFFileImporter_validateURLs);
    } else {
        SpliceKit_log(@"[VP9Import] FFFileImporter.validateURLs:... not available");
    }

    SEL scanURLSelector = NSSelectorFromString(@"scanURLForFiles:fileURLs:keywordSets:keywords:rejectedURLs:rejectedURLExtensions:rejectedReasons:");
    Method scanURLMethod = fileImporterClass ? class_getInstanceMethod(fileImporterClass, scanURLSelector) : NULL;
    if (scanURLMethod) {
        sSpliceKitURLImportOriginalFFFileImporterScanURLForFiles =
            (void (*)(id, SEL, id, id, id, id, id, id, void *))method_setImplementation(
                scanURLMethod,
                (IMP)SpliceKitURLImport_swizzled_FFFileImporter_scanURLForFiles);
    } else {
        SpliceKit_log(@"[VP9Import] FFFileImporter.scanURLForFiles:... not available");
    }

    // Re-enabled with keywordSets/metadataArray padding. The earlier crash at
    // +_importBackgroundTask + 420 surfaced as -[__NSArrayM removeObjectsInRange:]
    // after exception unwinding, but the real cause is FCP reading
    // keywordSets[i] and metadataArray[i] in parallel with fileURLs — and
    // those parallel arrays are under-populated when the Media Import UI
    // treated a file as greyed/not-importable. Our swizzle now pads them.
    SEL importFileURLsSelector = NSSelectorFromString(@"importFileURLs:fileURLsInfo:toEvent:manageFileType:processNow:warnClipsAlreadyExist:keywordSets:metadataArray:completionBlock:");
    Method importFileURLsMethod = fileImporterClass ? class_getClassMethod(fileImporterClass, importFileURLsSelector) : NULL;
    if (importFileURLsMethod) {
        sSpliceKitURLImportOriginalFFFileImporterImportFileURLs =
            (id (*)(id, SEL, id, id, id, int, BOOL, BOOL, id, id, id))method_setImplementation(
                importFileURLsMethod,
                (IMP)SpliceKitURLImport_swizzled_FFFileImporter_importFileURLs);
    } else {
        SpliceKit_log(@"[VP9Import] FFFileImporter.importFileURLs:... not available");
    }

    Class timelineViewClass = objc_getClass("TLKTimelineView");
    Method draggingEnteredMethod = timelineViewClass
        ? class_getInstanceMethod(timelineViewClass, @selector(draggingEntered:))
        : NULL;
    if (draggingEnteredMethod) {
        sSpliceKitURLImportOriginalTLKTimelineViewDraggingEntered =
            (NSDragOperation (*)(id, SEL, id))method_setImplementation(
                draggingEnteredMethod,
                (IMP)SpliceKitURLImport_swizzled_TLKTimelineView_draggingEntered);
    } else {
        SpliceKit_log(@"[VP9Import] TLKTimelineView.draggingEntered: not available");
    }

    Method performDragOperationMethod = timelineViewClass
        ? class_getInstanceMethod(timelineViewClass, @selector(performDragOperation:))
        : NULL;
    if (performDragOperationMethod) {
        sSpliceKitURLImportOriginalTLKTimelineViewPerformDragOperation =
            (char (*)(id, SEL, id))method_setImplementation(
                performDragOperationMethod,
                (IMP)SpliceKitURLImport_swizzled_TLKTimelineView_performDragOperation);
    } else {
        SpliceKit_log(@"[VP9Import] TLKTimelineView.performDragOperation: not available");
    }

    sSpliceKitURLImportVP9ImportHookInstalled = YES;
    SpliceKit_log(@"[VP9Import] Installed local-file + Media Import VP9 hooks");
}

void SpliceKitURLImport_bootstrapAtLaunchPhase(NSString *phase) {
    NSString *phaseName = [SpliceKitURLImportTrimmedString(phase) lowercaseString];
    if (phaseName.length == 0) phaseName = @"did-launch";

    if ([phaseName isEqualToString:@"will-launch"] ||
        [phaseName isEqualToString:@"will-finish-launching"]) {
        (void)SpliceKitURLImport_installProviderShim();
        return;
    }

    SpliceKitURLImport_installVP9ImportHook();
}

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

NSURL *SpliceKitURLImport_CopyShadowURL(NSURL *fileURL, NSString **outError) {
    return SpliceKitURLImportMaybeRewriteLocalFileURL(fileURL, outError);
}
