//
//  SpliceKitTranscriptDiagnostics.m
//  SpliceKit - Detailed transcription diagnostics for remote troubleshooting.
//
//  Every function logs structured diagnostics under the [TranscriptDiag] tag.
//  Output goes to ~/Library/Logs/SpliceKit/splicekit.log via SpliceKit_log.
//
//  Usage: call these functions at key stages of transcription to build a
//  complete diagnostic trail. When users report issues, the log tells us
//  exactly what happened — system, binary, clips, coordinates, words, errors.
//

#import "SpliceKitTranscriptDiagnostics.h"
#import "SpliceKit.h"
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - System & Environment

void SpliceKitTranscriptDiag_logSystemInfo(void) {
    SpliceKit_log(@"[TranscriptDiag] ═══════════════════════════════════════════");
    SpliceKit_log(@"[TranscriptDiag] System Information");
    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");

    // macOS version
    NSOperatingSystemVersion ver = [[NSProcessInfo processInfo] operatingSystemVersion];
    SpliceKit_log(@"[TranscriptDiag]   macOS: %ld.%ld.%ld",
                  (long)ver.majorVersion, (long)ver.minorVersion, (long)ver.patchVersion);

    // Chip / CPU
    char cpuBrand[256] = {0};
    size_t len = sizeof(cpuBrand);
    if (sysctlbyname("machdep.cpu.brand_string", cpuBrand, &len, NULL, 0) == 0) {
        SpliceKit_log(@"[TranscriptDiag]   CPU: %s", cpuBrand);
    }

    // Apple Silicon check
    int isTranslated = 0;
    size_t tLen = sizeof(isTranslated);
    if (sysctlbyname("sysctl.proc_translated", &isTranslated, &tLen, NULL, 0) == 0) {
        SpliceKit_log(@"[TranscriptDiag]   Rosetta: %@", isTranslated ? @"YES (running under translation)" : @"NO (native)");
    }

    // RAM
    uint64_t memSize = [[NSProcessInfo processInfo] physicalMemory];
    SpliceKit_log(@"[TranscriptDiag]   RAM: %.1f GB", memSize / 1073741824.0);

    // Available disk space
    NSError *err = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfFileSystemForPath:NSTemporaryDirectory() error:&err];
    if (attrs) {
        uint64_t freeSpace = [attrs[NSFileSystemFreeSize] unsignedLongLongValue];
        SpliceKit_log(@"[TranscriptDiag]   Disk free: %.1f GB", freeSpace / 1073741824.0);
    }

    // Neural Engine availability (via CoreML model config — heuristic)
    // On Apple Silicon, ANE is always present; on Intel, it's absent.
    #if __arm64__
    SpliceKit_log(@"[TranscriptDiag]   Neural Engine: likely available (arm64)");
    #else
    SpliceKit_log(@"[TranscriptDiag]   Neural Engine: not available (x86_64)");
    #endif

    // FluidAudio model cache
    NSString *modelDir = [NSHomeDirectory() stringByAppendingPathComponent:
                          @"Library/Application Support/FluidAudio/Models"];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:modelDir isDirectory:&isDir] && isDir) {
        NSArray *contents = [fm contentsOfDirectoryAtPath:modelDir error:nil];
        uint64_t totalSize = 0;
        for (NSString *name in contents) {
            NSDictionary *fAttrs = [fm attributesOfItemAtPath:
                [modelDir stringByAppendingPathComponent:name] error:nil];
            totalSize += [fAttrs[NSFileSize] unsignedLongLongValue];
        }
        SpliceKit_log(@"[TranscriptDiag]   FluidAudio models: %lu items, %.1f MB total at %@",
                      (unsigned long)contents.count, totalSize / 1048576.0, modelDir);
        for (NSString *name in contents) {
            NSDictionary *fAttrs = [fm attributesOfItemAtPath:
                [modelDir stringByAppendingPathComponent:name] error:nil];
            SpliceKit_log(@"[TranscriptDiag]     %@ (%.1f MB)",
                          name, [fAttrs[NSFileSize] unsignedLongLongValue] / 1048576.0);
        }
    } else {
        SpliceKit_log(@"[TranscriptDiag]   FluidAudio models: NOT FOUND at %@", modelDir);
    }

    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");
}

#pragma mark - Binary Validation

void SpliceKitTranscriptDiag_logBinaryInfo(NSString *binaryPath) {
    SpliceKit_log(@"[TranscriptDiag] Binary Validation");
    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");

    if (!binaryPath) {
        SpliceKit_log(@"[TranscriptDiag]   ✗ Binary path is nil");
        return;
    }

    SpliceKit_log(@"[TranscriptDiag]   Path: %@", binaryPath);

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:binaryPath]) {
        SpliceKit_log(@"[TranscriptDiag]   ✗ File does not exist");
        return;
    }

    // File attributes
    NSError *err = nil;
    NSDictionary *attrs = [fm attributesOfItemAtPath:binaryPath error:&err];
    if (attrs) {
        SpliceKit_log(@"[TranscriptDiag]   Size: %.1f MB",
                      [attrs[NSFileSize] unsignedLongLongValue] / 1048576.0);
        SpliceKit_log(@"[TranscriptDiag]   Modified: %@", attrs[NSFileModificationDate]);
        NSUInteger perms = [attrs[NSFilePosixPermissions] unsignedIntegerValue];
        SpliceKit_log(@"[TranscriptDiag]   Permissions: %lo", (unsigned long)perms);
    }

    // Check executable
    if ([fm isExecutableFileAtPath:binaryPath]) {
        SpliceKit_log(@"[TranscriptDiag]   Executable: YES");
    } else {
        SpliceKit_log(@"[TranscriptDiag]   ✗ Executable: NO — chmod +x needed");
    }

    // Check architecture by reading Mach-O header
    NSData *headerData = [NSData dataWithContentsOfFile:binaryPath
                          options:NSDataReadingMappedIfSafe error:nil];
    if (headerData.length >= 4) {
        uint32_t magic = *(uint32_t *)headerData.bytes;
        if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
            SpliceKit_log(@"[TranscriptDiag]   Architecture: Universal binary (fat)");
        } else if (magic == MH_MAGIC_64) {
            const struct mach_header_64 *hdr = headerData.bytes;
            NSString *arch = (hdr->cputype == CPU_TYPE_ARM64) ? @"arm64" : @"x86_64";
            SpliceKit_log(@"[TranscriptDiag]   Architecture: %@ (single)", arch);
        } else {
            SpliceKit_log(@"[TranscriptDiag]   Architecture: unknown (magic: 0x%08x)", magic);
        }
    }

    // Codesign check
    NSTask *csTask = [[NSTask alloc] init];
    csTask.launchPath = @"/usr/bin/codesign";
    csTask.arguments = @[@"-vvv", binaryPath];
    NSPipe *csPipe = [NSPipe pipe];
    csTask.standardOutput = csPipe;
    csTask.standardError = csPipe;
    @try {
        [csTask launch];
        [csTask waitUntilExit];
        NSData *csOut = [csPipe.fileHandleForReading readDataToEndOfFile];
        NSString *csStr = [[NSString alloc] initWithData:csOut encoding:NSUTF8StringEncoding];
        if (csTask.terminationStatus == 0) {
            SpliceKit_log(@"[TranscriptDiag]   Codesign: valid");
        } else {
            SpliceKit_log(@"[TranscriptDiag]   Codesign: %@",
                          [csStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[TranscriptDiag]   Codesign check failed: %@", e.reason);
    }

    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");
}

#pragma mark - Timeline & Clip Collection

void SpliceKitTranscriptDiag_logClipInfos(NSArray *clipInfos, NSString *engineName) {
    SpliceKit_log(@"[TranscriptDiag] Clip Collection (%@)", engineName);
    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");

    if (!clipInfos || clipInfos.count == 0) {
        SpliceKit_log(@"[TranscriptDiag]   ✗ No clips collected");
        return;
    }

    SpliceKit_log(@"[TranscriptDiag]   Total clips: %lu", (unsigned long)clipInfos.count);

    // Count clips with/without media URLs
    NSUInteger withURL = 0, withoutURL = 0;
    double totalDuration = 0;
    for (NSDictionary *info in clipInfos) {
        if (info[@"mediaURL"]) withURL++; else withoutURL++;
        totalDuration += [info[@"duration"] doubleValue];
    }
    SpliceKit_log(@"[TranscriptDiag]   With media URL: %lu, Without: %lu",
                  (unsigned long)withURL, (unsigned long)withoutURL);
    SpliceKit_log(@"[TranscriptDiag]   Total timeline duration: %.2fs (%.1f min)",
                  totalDuration, totalDuration / 60.0);

    // Detailed per-clip info
    for (NSUInteger i = 0; i < clipInfos.count; i++) {
        NSDictionary *info = clipInfos[i];
        double timelineStart = [info[@"timelineStart"] doubleValue];
        double duration = [info[@"duration"] doubleValue];
        double trimStart = [info[@"trimStart"] doubleValue];
        double mediaOrigin = [info[@"mediaOrigin"] doubleValue];
        NSString *className = info[@"className"] ?: @"unknown";
        NSURL *mediaURL = info[@"mediaURL"];
        NSString *name = info[@"name"] ?: @"(unnamed)";

        SpliceKit_log(@"[TranscriptDiag]   Clip %lu: %@", (unsigned long)(i + 1), name);
        SpliceKit_log(@"[TranscriptDiag]     class=%@, timeline=%.2fs, dur=%.2fs",
                      className, timelineStart, duration);
        SpliceKit_log(@"[TranscriptDiag]     trimStart=%.2fs, mediaOrigin=%.2fs, fileRelativeTrim=%.2fs",
                      trimStart, mediaOrigin, trimStart - mediaOrigin);

        if (mediaURL) {
            SpliceKit_log(@"[TranscriptDiag]     media=%@", mediaURL.path);
            // Check if media file exists and is readable
            BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:mediaURL.path];
            if (!exists) {
                SpliceKit_log(@"[TranscriptDiag]     ✗ MEDIA FILE NOT FOUND");
            } else {
                NSDictionary *fAttrs = [[NSFileManager defaultManager]
                    attributesOfItemAtPath:mediaURL.path error:nil];
                SpliceKit_log(@"[TranscriptDiag]     media size=%.1f MB",
                              [fAttrs[NSFileSize] unsignedLongLongValue] / 1048576.0);
            }
        } else {
            SpliceKit_log(@"[TranscriptDiag]     ✗ No media URL resolved");
        }

        // Flag potential coordinate issues
        if (trimStart > 3600 && mediaOrigin == 0) {
            SpliceKit_log(@"[TranscriptDiag]     ⚠ trimStart > 1hr but mediaOrigin=0 — "
                           "possible embedded timecode not detected");
        }
        if (trimStart > 0 && trimStart == mediaOrigin) {
            SpliceKit_log(@"[TranscriptDiag]     note: trimStart == mediaOrigin (untrimmed clip from timecoded source)");
        }
    }

    // Check for duplicate source files
    NSMutableDictionary *fileCounts = [NSMutableDictionary dictionary];
    for (NSDictionary *info in clipInfos) {
        NSURL *url = info[@"mediaURL"];
        if (url) {
            NSString *path = url.path;
            fileCounts[path] = @([fileCounts[path] integerValue] + 1);
        }
    }
    NSUInteger uniqueFiles = fileCounts.count;
    SpliceKit_log(@"[TranscriptDiag]   Unique source files: %lu", (unsigned long)uniqueFiles);
    for (NSString *path in fileCounts) {
        NSInteger count = [fileCounts[path] integerValue];
        if (count > 1) {
            SpliceKit_log(@"[TranscriptDiag]     %@ appears %ld times (blade splits?)",
                          [path lastPathComponent], (long)count);
        }
    }

    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");
}

#pragma mark - Parakeet Process

void SpliceKitTranscriptDiag_logBatchManifest(NSArray *manifestEntries) {
    SpliceKit_log(@"[TranscriptDiag] Batch Manifest");
    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");
    SpliceKit_log(@"[TranscriptDiag]   Entries: %lu", (unsigned long)manifestEntries.count);

    for (NSUInteger i = 0; i < manifestEntries.count; i++) {
        NSDictionary *entry = manifestEntries[i];
        NSString *file = entry[@"file"] ?: @"(nil)";
        SpliceKit_log(@"[TranscriptDiag]   [%lu] %@", (unsigned long)(i + 1),
                      [file lastPathComponent]);

        // Check file accessibility
        if ([file hasPrefix:@"/"]) {
            BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:file];
            BOOL readable = [[NSFileManager defaultManager] isReadableFileAtPath:file];
            if (!exists) {
                SpliceKit_log(@"[TranscriptDiag]        ✗ FILE NOT FOUND: %@", file);
            } else if (!readable) {
                SpliceKit_log(@"[TranscriptDiag]        ✗ FILE NOT READABLE (permissions): %@", file);
            }
        }
    }

    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");
}

void SpliceKitTranscriptDiag_logProcessLaunch(NSString *binaryPath, NSArray *args) {
    SpliceKit_log(@"[TranscriptDiag] Process Launch");
    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");
    SpliceKit_log(@"[TranscriptDiag]   Binary: %@", binaryPath);
    SpliceKit_log(@"[TranscriptDiag]   Args: %@", [args componentsJoinedByString:@" "]);

    // Log /tmp space (batch manifest is written there)
    NSDictionary *tmpAttrs = [[NSFileManager defaultManager]
        attributesOfFileSystemForPath:NSTemporaryDirectory() error:nil];
    if (tmpAttrs) {
        uint64_t freeSpace = [tmpAttrs[NSFileSystemFreeSize] unsignedLongLongValue];
        SpliceKit_log(@"[TranscriptDiag]   /tmp free: %.1f GB", freeSpace / 1073741824.0);
    }

    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");
}

void SpliceKitTranscriptDiag_logProcessExit(int exitCode, NSData *stdoutData,
                                             NSData *stderrData, NSTimeInterval elapsed) {
    SpliceKit_log(@"[TranscriptDiag] Process Exit");
    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");
    SpliceKit_log(@"[TranscriptDiag]   Exit code: %d %@", exitCode,
                  exitCode == 0 ? @"(success)" : @"(FAILURE)");
    SpliceKit_log(@"[TranscriptDiag]   Elapsed: %.2fs", elapsed);
    SpliceKit_log(@"[TranscriptDiag]   Stdout: %lu bytes", (unsigned long)stdoutData.length);
    SpliceKit_log(@"[TranscriptDiag]   Stderr: %lu bytes", (unsigned long)stderrData.length);

    // Stdout analysis
    if (stdoutData.length > 0) {
        NSString *stdoutStr = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding];
        if (!stdoutStr) {
            SpliceKit_log(@"[TranscriptDiag]   ✗ Stdout is not valid UTF-8");
        } else {
            // Check for known problematic prefixes
            if ([stdoutStr hasPrefix:@"E5RT "]) {
                SpliceKit_log(@"[TranscriptDiag]   ⚠ Stdout has E5RT CoreML error prefix");
            }
            if ([stdoutStr hasPrefix:@"{"]) {
                SpliceKit_log(@"[TranscriptDiag]   Stdout looks like JSON object (expected array)");
            } else if ([stdoutStr hasPrefix:@"["]) {
                SpliceKit_log(@"[TranscriptDiag]   Stdout looks like JSON array (expected)");
            }
            // First/last 200 chars for context
            if (stdoutStr.length <= 400) {
                SpliceKit_log(@"[TranscriptDiag]   Stdout full: %@", stdoutStr);
            } else {
                SpliceKit_log(@"[TranscriptDiag]   Stdout first 200: %@",
                              [stdoutStr substringToIndex:200]);
                SpliceKit_log(@"[TranscriptDiag]   Stdout last 200: %@",
                              [stdoutStr substringFromIndex:stdoutStr.length - 200]);
            }
        }
    }

    // Stderr analysis — look for error patterns
    if (stderrData.length > 0) {
        NSString *stderrStr = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding];
        if (stderrStr) {
            // Extract ERROR: lines
            NSArray *lines = [stderrStr componentsSeparatedByString:@"\n"];
            NSUInteger errorLines = 0, progressLines = 0;
            for (NSString *line in lines) {
                if ([line hasPrefix:@"ERROR:"]) {
                    SpliceKit_log(@"[TranscriptDiag]   Stderr error: %@", line);
                    errorLines++;
                } else if ([line hasPrefix:@"PROGRESS:"]) {
                    progressLines++;
                }
            }
            SpliceKit_log(@"[TranscriptDiag]   Stderr: %lu progress lines, %lu error lines, %lu total lines",
                          (unsigned long)progressLines, (unsigned long)errorLines,
                          (unsigned long)lines.count);

            // Look for known error patterns
            if ([stderrStr containsString:@"memory"]) {
                SpliceKit_log(@"[TranscriptDiag]   ⚠ Stderr mentions 'memory' — possible OOM");
            }
            if ([stderrStr containsString:@"CoreML"] || [stderrStr containsString:@"mlmodel"]) {
                SpliceKit_log(@"[TranscriptDiag]   ⚠ Stderr mentions CoreML/mlmodel");
            }
            if ([stderrStr containsString:@"ANE"] || [stderrStr containsString:@"Neural Engine"]) {
                SpliceKit_log(@"[TranscriptDiag]   ⚠ Stderr mentions ANE/Neural Engine");
            }
            if ([stderrStr containsString:@"FluidAudio"]) {
                SpliceKit_log(@"[TranscriptDiag]   Stderr mentions FluidAudio");
            }
        }
    }

    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");
}

#pragma mark - JSON Parsing

BOOL SpliceKitTranscriptDiag_inspectRawOutput(NSData *stdoutData) {
    BOOL issuesFound = NO;

    SpliceKit_log(@"[TranscriptDiag] Raw Output Inspection");
    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");
    SpliceKit_log(@"[TranscriptDiag]   Size: %lu bytes", (unsigned long)stdoutData.length);

    if (stdoutData.length == 0) {
        SpliceKit_log(@"[TranscriptDiag]   ✗ Empty output (0 bytes)");
        issuesFound = YES;
        return issuesFound;
    }

    NSString *str = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding];
    if (!str) {
        SpliceKit_log(@"[TranscriptDiag]   ✗ Output is not valid UTF-8 — binary garbage?");
        // Hex dump first 64 bytes
        NSUInteger dumpLen = MIN(64, stdoutData.length);
        const uint8_t *bytes = stdoutData.bytes;
        NSMutableString *hex = [NSMutableString string];
        for (NSUInteger i = 0; i < dumpLen; i++) {
            [hex appendFormat:@"%02x ", bytes[i]];
            if ((i + 1) % 16 == 0) [hex appendString:@"\n                              "];
        }
        SpliceKit_log(@"[TranscriptDiag]   Hex dump (first %lu bytes): %@",
                      (unsigned long)dumpLen, hex);
        issuesFound = YES;
        return issuesFound;
    }

    // Check for known prefixes
    if ([str hasPrefix:@"E5RT "]) {
        NSRange bracket = [str rangeOfString:@"["];
        if (bracket.location != NSNotFound) {
            SpliceKit_log(@"[TranscriptDiag]   ⚠ E5RT prefix detected (%lu chars before JSON)",
                          (unsigned long)bracket.location);
            SpliceKit_log(@"[TranscriptDiag]   E5RT message: %@",
                          [[str substringToIndex:bracket.location]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
        } else {
            SpliceKit_log(@"[TranscriptDiag]   ✗ E5RT prefix with no JSON array found in output");
        }
        issuesFound = YES;
    }

    // Check if output starts with expected JSON
    NSString *trimmed = [str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasPrefix:@"["]) {
        SpliceKit_log(@"[TranscriptDiag]   JSON: starts with [ (expected batch array)");
    } else if ([trimmed hasPrefix:@"{"]) {
        SpliceKit_log(@"[TranscriptDiag]   ⚠ JSON: starts with { (expected [, got single object)");
        issuesFound = YES;
    } else if (!issuesFound) {
        NSString *preview = trimmed.length > 100 ? [trimmed substringToIndex:100] : trimmed;
        SpliceKit_log(@"[TranscriptDiag]   ✗ Output doesn't look like JSON: %@", preview);
        issuesFound = YES;
    }

    // Check for truncation
    if (![trimmed hasSuffix:@"]"]) {
        SpliceKit_log(@"[TranscriptDiag]   ⚠ Output may be truncated (doesn't end with ])");
        NSString *suffix = trimmed.length > 50 ? [trimmed substringFromIndex:trimmed.length - 50] : trimmed;
        SpliceKit_log(@"[TranscriptDiag]   Last 50 chars: %@", suffix);
        issuesFound = YES;
    }

    // Check for NUL bytes
    const char *cStr = stdoutData.bytes;
    for (NSUInteger i = 0; i < stdoutData.length; i++) {
        if (cStr[i] == '\0') {
            SpliceKit_log(@"[TranscriptDiag]   ✗ NUL byte at offset %lu — output may be corrupted",
                          (unsigned long)i);
            issuesFound = YES;
            break;
        }
    }

    if (!issuesFound) {
        SpliceKit_log(@"[TranscriptDiag]   Output looks clean");
    }

    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");
    return issuesFound;
}

void SpliceKitTranscriptDiag_logParsedResults(NSArray *batchResults) {
    SpliceKit_log(@"[TranscriptDiag] Parsed Results");
    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");

    if (!batchResults) {
        SpliceKit_log(@"[TranscriptDiag]   ✗ batchResults is nil (JSON parse failed)");
        return;
    }

    SpliceKit_log(@"[TranscriptDiag]   Files in result: %lu", (unsigned long)batchResults.count);

    NSUInteger totalWords = 0;
    for (NSDictionary *result in batchResults) {
        if (![result isKindOfClass:[NSDictionary class]]) {
            SpliceKit_log(@"[TranscriptDiag]   ✗ Non-dictionary entry: %@",
                          NSStringFromClass([result class]));
            continue;
        }

        NSString *file = result[@"file"] ?: @"(no file key)";
        NSArray *words = result[@"words"];

        if (![words isKindOfClass:[NSArray class]]) {
            SpliceKit_log(@"[TranscriptDiag]   %@: ✗ words is %@ (expected array)",
                          [file lastPathComponent],
                          words ? NSStringFromClass([words class]) : @"nil");
            continue;
        }

        NSUInteger wordCount = words.count;
        totalWords += wordCount;

        if (wordCount == 0) {
            SpliceKit_log(@"[TranscriptDiag]   %@: 0 words (empty transcription)",
                          [file lastPathComponent]);
            continue;
        }

        // Time range of returned words
        double minTime = HUGE_VAL, maxTime = -HUGE_VAL;
        double minConf = 1.0, maxConf = 0.0;
        NSUInteger nullSpeakers = 0;
        for (NSDictionary *wd in words) {
            double st = [wd[@"startTime"] doubleValue];
            double conf = [wd[@"confidence"] doubleValue];
            if (st < minTime) minTime = st;
            if (st > maxTime) maxTime = st;
            if (conf < minConf) minConf = conf;
            if (conf > maxConf) maxConf = conf;
            if (!wd[@"speaker"]) nullSpeakers++;
        }

        SpliceKit_log(@"[TranscriptDiag]   %@: %lu words, time range %.2fs–%.2fs, "
                       "confidence %.2f–%.2f%@",
                      [file lastPathComponent], (unsigned long)wordCount,
                      minTime, maxTime, minConf, maxConf,
                      nullSpeakers > 0 ? [NSString stringWithFormat:@", %lu without speaker",
                                          (unsigned long)nullSpeakers] : @"");
    }

    SpliceKit_log(@"[TranscriptDiag]   Total words across all files: %lu", (unsigned long)totalWords);

    if (totalWords == 0 && batchResults.count > 0) {
        SpliceKit_log(@"[TranscriptDiag]   note: All files returned 0 words — "
                       "normal for instrumental/music-only audio, "
                       "otherwise may indicate a silent model failure");
    }

    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");
}

#pragma mark - Word Filtering

void SpliceKitTranscriptDiag_logWordFiltering(NSString *fileName,
                                               NSArray *rawWords,
                                               double trimStart,
                                               double mediaOrigin,
                                               double clipDuration,
                                               NSUInteger wordsAccepted) {
    NSUInteger rawCount = rawWords.count;

    // Skip verbose output when Parakeet returned no words (nothing to filter)
    if (rawCount == 0) {
        SpliceKit_log(@"[TranscriptDiag] Word Filter: %@ — 0 raw words (no speech detected)", fileName);
        return;
    }

    double fileRelativeTrimStart = trimStart - mediaOrigin;
    double filterEnd = fileRelativeTrimStart + clipDuration;

    SpliceKit_log(@"[TranscriptDiag] Word Filter: %@", fileName);
    SpliceKit_log(@"[TranscriptDiag]   FCP trimStart=%.2fs, mediaOrigin=%.2fs, clipDuration=%.2fs",
                  trimStart, mediaOrigin, clipDuration);
    SpliceKit_log(@"[TranscriptDiag]   File-relative filter window: %.2fs – %.2fs",
                  fileRelativeTrimStart, filterEnd);
    SpliceKit_log(@"[TranscriptDiag]   Raw words from Parakeet: %lu", (unsigned long)rawCount);
    SpliceKit_log(@"[TranscriptDiag]   Words accepted by filter: %lu", (unsigned long)wordsAccepted);
    SpliceKit_log(@"[TranscriptDiag]   Words rejected: %lu", (unsigned long)(rawCount - wordsAccepted));

    double minTime = [[rawWords[0] valueForKey:@"startTime"] doubleValue];
    double maxTime = [[rawWords[rawCount - 1] valueForKey:@"startTime"] doubleValue];
    SpliceKit_log(@"[TranscriptDiag]   Word time range: %.2fs – %.2fs", minTime, maxTime);

    // Detect coordinate mismatch
    if (wordsAccepted == 0) {
        if (maxTime < fileRelativeTrimStart) {
            SpliceKit_log(@"[TranscriptDiag]   ✗ ALL %lu words are before filter window "
                           "(max word time %.2fs < filter start %.2fs) — coordinate space mismatch",
                          (unsigned long)rawCount, maxTime, fileRelativeTrimStart);
        } else if (minTime > filterEnd) {
            SpliceKit_log(@"[TranscriptDiag]   ✗ ALL %lu words are after filter window "
                           "(min word time %.2fs > filter end %.2fs)",
                          (unsigned long)rawCount, minTime, filterEnd);
        }
    }

    // Check for suspiciously low acceptance rate
    if (rawCount > 10 && wordsAccepted > 0 && wordsAccepted < rawCount / 10) {
        SpliceKit_log(@"[TranscriptDiag]   ⚠ Very low acceptance rate (%.1f%%) — "
                       "trim window may be too narrow",
                      100.0 * wordsAccepted / rawCount);
    }
}

#pragma mark - Apple Speech

void SpliceKitTranscriptDiag_logAppleSpeechState(void) {
    SpliceKit_log(@"[TranscriptDiag] Apple Speech State");
    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");

    // Check if Speech framework classes are loaded
    Class recognizerClass = objc_getClass("SFSpeechRecognizer");
    Class requestClass = objc_getClass("SFSpeechURLRecognitionRequest");

    SpliceKit_log(@"[TranscriptDiag]   SFSpeechRecognizer: %@",
                  recognizerClass ? @"loaded" : @"NOT LOADED");
    SpliceKit_log(@"[TranscriptDiag]   SFSpeechURLRecognitionRequest: %@",
                  requestClass ? @"loaded" : @"NOT LOADED");

    if (!recognizerClass) {
        SpliceKit_log(@"[TranscriptDiag]   ✗ Speech.framework not available");
        return;
    }

    // Authorization status
    SEL statusSel = NSSelectorFromString(@"authorizationStatus");
    if ([recognizerClass respondsToSelector:statusSel]) {
        NSInteger status = ((NSInteger (*)(Class, SEL))objc_msgSend)(recognizerClass, statusSel);
        NSString *statusName;
        switch (status) {
            case 0: statusName = @"notDetermined"; break;
            case 1: statusName = @"denied"; break;
            case 2: statusName = @"restricted"; break;
            case 3: statusName = @"authorized"; break;
            default: statusName = [NSString stringWithFormat:@"unknown(%ld)", (long)status]; break;
        }
        SpliceKit_log(@"[TranscriptDiag]   Authorization: %@ (%ld)", statusName, (long)status);

        if (status != 3) {
            SpliceKit_log(@"[TranscriptDiag]   ⚠ Not authorized — FCP has no NSSpeechRecognitionUsageDescription, "
                           "so macOS can't show the permission dialog. On-device recognition may still work.");
        }
    }

    // Check recognizer availability
    id recognizer = ((id (*)(id, SEL, id))objc_msgSend)(
        [recognizerClass alloc],
        NSSelectorFromString(@"initWithLocale:"),
        [NSLocale localeWithLocaleIdentifier:@"en-US"]);

    if (recognizer) {
        SEL avail = NSSelectorFromString(@"isAvailable");
        if ([recognizer respondsToSelector:avail]) {
            BOOL isAvailable = ((BOOL (*)(id, SEL))objc_msgSend)(recognizer, avail);
            SpliceKit_log(@"[TranscriptDiag]   Recognizer available (en-US): %@",
                          isAvailable ? @"YES" : @"NO");
        }

        SEL onDevSel = NSSelectorFromString(@"supportsOnDeviceRecognition");
        if ([recognizer respondsToSelector:onDevSel]) {
            BOOL supportsOnDevice = ((BOOL (*)(id, SEL))objc_msgSend)(recognizer, onDevSel);
            SpliceKit_log(@"[TranscriptDiag]   On-device recognition: %@",
                          supportsOnDevice ? @"supported" : @"NOT supported");
        }
    }

    // Check speaker diarization availability (macOS 26+)
    SEL diarSel = NSSelectorFromString(@"setAddsSpeakerAttribution:");
    if (requestClass) {
        id testReq = [[requestClass alloc] init];
        if (testReq && [testReq respondsToSelector:diarSel]) {
            SpliceKit_log(@"[TranscriptDiag]   Speaker diarization: available (macOS 26+)");
        } else {
            SpliceKit_log(@"[TranscriptDiag]   Speaker diarization: not available");
        }
    }

    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");
}

#pragma mark - FCP Native

void SpliceKitTranscriptDiag_logFCPNativeState(NSArray *clipInfos) {
    SpliceKit_log(@"[TranscriptDiag] FCP Native Transcription State");
    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");

    // Check for FFTranscriptionCoordinator
    Class coordClass = objc_getClass("FFTranscriptionCoordinator");
    SpliceKit_log(@"[TranscriptDiag]   FFTranscriptionCoordinator: %@",
                  coordClass ? @"loaded" : @"NOT LOADED");

    if (coordClass) {
        SEL sharedSel = NSSelectorFromString(@"sharedCoordinator");
        if ([coordClass respondsToSelector:sharedSel]) {
            id coordinator = ((id (*)(Class, SEL))objc_msgSend)(coordClass, sharedSel);
            SpliceKit_log(@"[TranscriptDiag]   Shared coordinator: %@",
                          coordinator ? @"available" : @"nil");
        }
    }

    // Check for AASpeechAnalyzer (FCP's internal ASR engine)
    Class analyzerClass = objc_getClass("AASpeechAnalyzer");
    SpliceKit_log(@"[TranscriptDiag]   AASpeechAnalyzer: %@",
                  analyzerClass ? @"loaded" : @"NOT LOADED");

    // Summarize clips that have .assets (transcription source)
    if (clipInfos) {
        NSUInteger withAssets = 0;
        for (NSDictionary *info in clipInfos) {
            id mediaObj = info[@"mediaObject"];
            if (mediaObj && [mediaObj respondsToSelector:NSSelectorFromString(@"assets")]) {
                withAssets++;
            }
        }
        SpliceKit_log(@"[TranscriptDiag]   Clips with .assets selector: %lu / %lu",
                      (unsigned long)withAssets, (unsigned long)clipInfos.count);
        if (withAssets == 0) {
            SpliceKit_log(@"[TranscriptDiag]   ⚠ No clips have .assets — FCP Native transcription "
                           "may not find any speech analysis data");
        }
    }

    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");
}

#pragma mark - Summary

void SpliceKitTranscriptDiag_logSummary(NSString *engineName,
                                         NSTimeInterval totalElapsed,
                                         NSUInteger wordCount,
                                         NSUInteger silenceCount,
                                         NSUInteger clipCount,
                                         NSString *errorMessage) {
    SpliceKit_log(@"[TranscriptDiag] ═══════════════════════════════════════════");
    SpliceKit_log(@"[TranscriptDiag] Transcription Summary");
    SpliceKit_log(@"[TranscriptDiag] ───────────────────────────────────────────");
    SpliceKit_log(@"[TranscriptDiag]   Engine: %@", engineName);
    SpliceKit_log(@"[TranscriptDiag]   Duration: %.2fs", totalElapsed);
    SpliceKit_log(@"[TranscriptDiag]   Clips: %lu", (unsigned long)clipCount);
    SpliceKit_log(@"[TranscriptDiag]   Words: %lu", (unsigned long)wordCount);
    SpliceKit_log(@"[TranscriptDiag]   Silences: %lu", (unsigned long)silenceCount);

    if (errorMessage) {
        SpliceKit_log(@"[TranscriptDiag]   Error: %@", errorMessage);
    }

    // Flag anomalies
    if (wordCount == 0 && !errorMessage) {
        SpliceKit_log(@"[TranscriptDiag]   note: 0 words with no error. "
                       "This is normal for instrumental/music-only audio. "
                       "If speech was expected, check the Word Filter and Parsed Results "
                       "sections above for coordinate mismatches or empty model output.");
    }

    if (wordCount > 0 && silenceCount == 0) {
        SpliceKit_log(@"[TranscriptDiag]   note: No silences detected (continuous speech or "
                       "silence threshold too high)");
    }

    if (totalElapsed > 300) {
        SpliceKit_log(@"[TranscriptDiag]   ⚠ Transcription took >5 minutes — large file or slow model");
    }

    NSString *result = errorMessage ? @"FAILED" : (wordCount > 0 ? @"OK" : @"EMPTY");
    SpliceKit_log(@"[TranscriptDiag]   Result: %@", result);
    SpliceKit_log(@"[TranscriptDiag] ═══════════════════════════════════════════");
}
