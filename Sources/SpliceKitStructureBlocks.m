//
//  SpliceKitStructureBlocks.m
//  SpliceKit
//
//  Creates color-coded section blocks above the timeline showing song structure
//  (verse, chorus, bridge, intro, outro). Uses the same runtime storyline pipeline
//  as the caption panel: FFAnchoredCollection with Basic Title generators, archived
//  to pasteboard, pasted as a connected storyline.
//
//  Also installs a right-click context menu on timeline items for changing block colors.
//

#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// --- CMTime struct (matches Core Media layout) ---
typedef struct {
    int64_t  value;
    int32_t  timescale;
    uint32_t flags;
    int64_t  epoch;
} SB_CMTime;

typedef struct {
    SB_CMTime start;
    SB_CMTime duration;
} SB_CMTimeRange;

// On ARM64, structs <= 16 bytes return in registers; our CMTime is 24 bytes so
// we always use objc_msgSend (ARM64 passes large structs via hidden pointer).
#if defined(__arm64__)
#define SB_STRET_MSG objc_msgSend
#else
#define SB_STRET_MSG objc_msgSend_stret
#endif

// --- Constants ---
static NSString * const kStructureStorylineName = @"SpliceKit Structure";
static NSString * const kBasicTitleTemplate =
    @"Bumper:Opener.localized/Basic Title.localized/Basic Title.moti";

// --- Color definitions (RGBA) ---
typedef struct { CGFloat r, g, b, a; } SBColor;

static SBColor SBColorForLabel(NSString *label) {
    NSString *lower = [label lowercaseString];
    if ([lower hasPrefix:@"intro"])     return (SBColor){0.40, 0.45, 0.55, 0.90};
    if ([lower hasPrefix:@"outro"])     return (SBColor){0.40, 0.45, 0.55, 0.90};
    if ([lower hasPrefix:@"verse"])     return (SBColor){0.20, 0.50, 0.85, 0.90};
    if ([lower hasPrefix:@"chorus"])    return (SBColor){0.95, 0.55, 0.10, 0.90};
    if ([lower hasPrefix:@"bridge"])    return (SBColor){0.55, 0.25, 0.75, 0.90};
    if ([lower hasPrefix:@"drop"])      return (SBColor){0.90, 0.15, 0.15, 0.90};
    if ([lower hasPrefix:@"pre-chorus"])return (SBColor){0.80, 0.45, 0.15, 0.90};
    if ([lower hasPrefix:@"breakdown"]) return (SBColor){0.30, 0.60, 0.50, 0.90};
    return (SBColor){0.50, 0.50, 0.50, 0.80}; // default gray
}

// --- Frame arithmetic helpers ---

static long long SB_frameCount(double seconds, int fdNum, int fdDen, BOOL roundUp) {
    if (fdNum <= 0 || fdDen <= 0) { fdNum = 100; fdDen = 2400; }
    double fps = (double)fdDen / (double)fdNum;
    long long frames = roundUp ? (long long)ceil(seconds * fps) : (long long)floor(seconds * fps);
    if (frames < 0) frames = 0;
    return frames;
}

static SB_CMTime SB_makeTime(long long frames, int fdNum, int fdDen) {
    SB_CMTime t;
    t.value = frames * MAX(fdNum, 1);
    t.timescale = MAX(fdDen, 1);
    t.flags = 1;
    t.epoch = 0;
    return t;
}

// --- Gap and generator creation ---

static id SB_newGap(SB_CMTime duration, SB_CMTime sampleDuration) {
    Class gapClass = objc_getClass("FFAnchoredGapGeneratorComponent");
    if (!gapClass) return nil;
    SEL gapSel = NSSelectorFromString(@"newGap:ofSampleDuration:");
    if (![gapClass respondsToSelector:gapSel]) return nil;
    return ((id (*)(id, SEL, SB_CMTime, SB_CMTime))objc_msgSend)(
        gapClass, gapSel, duration, sampleDuration);
}

static id SB_newTitleGenerator(long long durationFrames, int fdNum, int fdDen) {
    Class genClass = objc_getClass("FFAnchoredGeneratorComponent");
    if (!genClass) return nil;
    SEL createSel = NSSelectorFromString(@"newGeneratorForEffectIDContainingSubstring:duration:sampleDuration:");
    if (![genClass respondsToSelector:createSel]) return nil;
    SB_CMTime sampleDuration = SB_makeTime(1, fdNum, fdDen);
    SB_CMTime duration = SB_makeTime(MAX(durationFrames, 1), fdNum, fdDen);
    return ((id (*)(id, SEL, id, SB_CMTime, SB_CMTime))objc_msgSend)(
        genClass, createSel, kBasicTitleTemplate, duration, sampleDuration);
}

// --- Text and color application ---

static BOOL SB_setGeneratorText(id generator, NSString *text) {
    if (!generator || !text) return NO;
    SEL effectSel = NSSelectorFromString(@"effect");
    if (![generator respondsToSelector:effectSel]) return NO;
    id effect = ((id (*)(id, SEL))objc_msgSend)(generator, effectSel);
    if (!effect) return NO;

    // Try setText:forField: on the effect
    SEL setTextSel = NSSelectorFromString(@"setText:forField:");
    if ([effect respondsToSelector:setTextSel]) {
        NSAttributedString *attr = [[NSAttributedString alloc] initWithString:text attributes:@{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:36],
            NSForegroundColorAttributeName: [NSColor whiteColor],
        }];
        // Normalize if possible
        SEL normSel = NSSelectorFromString(@"_newAttributedString:forField:");
        if ([effect respondsToSelector:normSel]) {
            id normalized = ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(effect, normSel, attr, 0);
            if (normalized) attr = normalized;
        }
        @try {
            ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(effect, setTextSel, attr, 0);
            // Persist
            SEL saveSel = NSSelectorFromString(@"saveDirtyTextToEffectValues");
            if ([effect respondsToSelector:saveSel]) {
                ((void (*)(id, SEL))objc_msgSend)(effect, saveSel);
            }
            return YES;
        } @catch (NSException *e) {}
    }

    // Fallback: try CHChannelText
    SEL chFolderSel = NSSelectorFromString(@"channelFolder");
    if (![effect respondsToSelector:chFolderSel]) return NO;
    id folder = ((id (*)(id, SEL))objc_msgSend)(effect, chFolderSel);
    if (!folder) return NO;

    Class textChannelClass = objc_getClass("CHChannelText");
    if (!textChannelClass) return NO;

    SEL subchannelsSel = NSSelectorFromString(@"subchannels");
    if (![folder respondsToSelector:subchannelsSel]) return NO;
    NSArray *subchannels = ((id (*)(id, SEL))objc_msgSend)(folder, subchannelsSel);

    for (id ch in subchannels) {
        if ([ch isKindOfClass:textChannelClass]) {
            SEL setAttrSel = NSSelectorFromString(@"setAttributedString:");
            if ([ch respondsToSelector:setAttrSel]) {
                NSAttributedString *attr = [[NSAttributedString alloc] initWithString:text attributes:@{
                    NSFontAttributeName: [NSFont boldSystemFontOfSize:36],
                    NSForegroundColorAttributeName: [NSColor whiteColor],
                }];
                ((void (*)(id, SEL, id))objc_msgSend)(ch, setAttrSel, attr);
                return YES;
            }
        }
    }
    return NO;
}

// --- Removal ---

static id SB_currentSequence(void) {
    id tm = SpliceKit_getActiveTimelineModule();
    if (!tm) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(tm, @selector(sequence));
}

static id SB_primaryObject(id sequence) {
    if (!sequence) return nil;
    SEL sel = NSSelectorFromString(@"primaryObject");
    if (![sequence respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(sequence, sel);
}

static NSUInteger SB_removeStoryline(id sequence, NSString *name) {
    id primary = SB_primaryObject(sequence);
    if (!primary) return 0;

    SEL itemsSel = NSSelectorFromString(@"containedItems");
    NSArray *items = [primary respondsToSelector:itemsSel]
        ? ((id (*)(id, SEL))objc_msgSend)(primary, itemsSel) : nil;
    if (![items isKindOfClass:[NSArray class]]) return 0;

    NSUInteger removed = 0;
    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    SEL displayNameSel = NSSelectorFromString(@"displayName");
    SEL removeSel1 = NSSelectorFromString(@"removeAnchoredItemsObject:");
    SEL removeSel2 = NSSelectorFromString(@"removeAnchoredObject:");

    for (id item in items) {
        if (![item respondsToSelector:anchoredSel]) continue;
        id anchoredRaw = ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel);
        NSArray *anchored = nil;
        if ([anchoredRaw isKindOfClass:[NSSet class]])
            anchored = [(NSSet *)anchoredRaw allObjects];
        else if ([anchoredRaw isKindOfClass:[NSArray class]])
            anchored = anchoredRaw;
        if (!anchored.count) continue;

        for (id obj in anchored) {
            NSString *className = NSStringFromClass([obj class]) ?: @"";
            if (![className containsString:@"Collection"]) continue;

            NSString *dn = nil;
            @try {
                if ([obj respondsToSelector:displayNameSel]) {
                    id n = ((id (*)(id, SEL))objc_msgSend)(obj, displayNameSel);
                    if ([n isKindOfClass:[NSString class]]) dn = n;
                }
            } @catch (NSException *e) {}

            if (name.length > 0 && ![dn isEqualToString:name]) continue;

            if ([item respondsToSelector:removeSel1]) {
                ((void (*)(id, SEL, id))objc_msgSend)(item, removeSel1, obj);
                removed++;
            } else if ([item respondsToSelector:removeSel2]) {
                ((void (*)(id, SEL, id))objc_msgSend)(item, removeSel2, obj);
                removed++;
            }
        }
    }
    return removed;
}

static BOOL SB_hasStoryline(id sequence) {
    id primary = SB_primaryObject(sequence);
    if (!primary) return NO;
    SEL itemsSel = NSSelectorFromString(@"containedItems");
    NSArray *items = [primary respondsToSelector:itemsSel]
        ? ((id (*)(id, SEL))objc_msgSend)(primary, itemsSel) : nil;
    if (![items isKindOfClass:[NSArray class]]) return NO;

    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    SEL displayNameSel = NSSelectorFromString(@"displayName");
    for (id item in items) {
        if (![item respondsToSelector:anchoredSel]) continue;
        id anchoredRaw = ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel);
        NSArray *anchored = nil;
        if ([anchoredRaw isKindOfClass:[NSSet class]])
            anchored = [(NSSet *)anchoredRaw allObjects];
        else if ([anchoredRaw isKindOfClass:[NSArray class]])
            anchored = anchoredRaw;
        for (id obj in anchored) {
            NSString *className = NSStringFromClass([obj class]) ?: @"";
            if (![className containsString:@"Collection"]) continue;
            @try {
                if ([obj respondsToSelector:displayNameSel]) {
                    id n = ((id (*)(id, SEL))objc_msgSend)(obj, displayNameSel);
                    if ([n isKindOfClass:[NSString class]] && [n isEqualToString:kStructureStorylineName])
                        return YES;
                }
            } @catch (NSException *e) {}
        }
    }
    return NO;
}

// =================================================================
// Generate Structure Captions (caption lane approach)
// =================================================================
// Creates native FCP captions (FFAnchoredCaption) that appear in the
// dedicated thin caption lane above the timeline. Uses FCPXML import
// with <caption> elements, then copy/paste from temp project.

// Forward-declare the FCPXML import handler from SpliceKitServer.m
extern NSDictionary *SpliceKit_handleFCPXMLImport(NSDictionary *params);

// Forward-declare helpers we need from the caption panel patterns
static id SB_findSequenceByPrefix(NSString *prefix) {
    Class libDocClass = objc_getClass("FFLibraryDocument");
    if (!libDocClass) return nil;
    SEL copySel = NSSelectorFromString(@"copyActiveLibraries");
    if (![libDocClass respondsToSelector:copySel]) return nil;
    NSArray *libs = ((id (*)(id, SEL))objc_msgSend)((id)libDocClass, copySel);
    if (![libs isKindOfClass:[NSArray class]]) return nil;

    for (id lib in libs) {
        SEL deepSel = NSSelectorFromString(@"_deepLoadedSequences");
        if (![lib respondsToSelector:deepSel]) continue;
        id seqSet = ((id (*)(id, SEL))objc_msgSend)(lib, deepSel);
        if (!seqSet) continue;
        NSArray *seqs = [seqSet isKindOfClass:[NSSet class]]
            ? [(NSSet *)seqSet allObjects]
            : ([seqSet isKindOfClass:[NSArray class]] ? seqSet : nil);
        for (id seq in seqs) {
            SEL dnSel = NSSelectorFromString(@"displayName");
            if (![seq respondsToSelector:dnSel]) continue;
            NSString *name = ((id (*)(id, SEL))objc_msgSend)(seq, dnSel);
            if ([name hasPrefix:prefix]) return seq;
        }
    }
    return nil;
}

static void SB_deleteSequence(id sequence) {
    if (!sequence) return;
    SEL removeSel = NSSelectorFromString(@"removeFromParent");
    if ([sequence respondsToSelector:removeSel]) {
        ((void (*)(id, SEL))objc_msgSend)(sequence, removeSel);
    }
}

NSDictionary *SpliceKit_handleStructureGenerateCaptions(NSDictionary *params) {
    NSArray *sections = params[@"sections"];
    if (!sections || ![sections isKindOfClass:[NSArray class]] || sections.count == 0)
        return @{@"error": @"sections array required (each: {label, start, end})"};

    // Get timeline frame duration
    __block int fdN = 100, fdD = 2400;
    __block NSString *userSequenceName = nil;

    SpliceKit_executeOnMainThread(^{
        id tm = SpliceKit_getActiveTimelineModule();
        if (!tm) return;
        id seq = ((id (*)(id, SEL))objc_msgSend)(tm, @selector(sequence));
        if (!seq) return;

        SEL fdSel = NSSelectorFromString(@"frameDuration");
        if ([seq respondsToSelector:fdSel]) {
            SB_CMTime fd = ((SB_CMTime (*)(id, SEL))SB_STRET_MSG)(seq, fdSel);
            if (fd.timescale > 0) { fdN = (int)fd.value; fdD = fd.timescale; }
        }
        SEL dnSel = NSSelectorFromString(@"displayName");
        if ([seq respondsToSelector:dnSel]) {
            userSequenceName = ((id (*)(id, SEL))objc_msgSend)(seq, dnSel);
        }
    });

    if (!userSequenceName) return @{@"error": @"No active timeline"};

    // Build FCPXML with <caption> elements
    double totalDur = 0;
    for (NSDictionary *s in sections) {
        double end = [s[@"end"] doubleValue];
        if (end > totalDur) totalDur = end;
    }
    totalDur += 1.0;

    long long totalFrames = (long long)ceil(totalDur * fdD / fdN);
    NSString *totalDurStr = [NSString stringWithFormat:@"%lld/%ds",
        totalFrames * fdN, fdD];

    NSString *tempName = [NSString stringWithFormat:@"SK Structure %u",
        (unsigned)(arc4random() % 10000)];

    // Map section types to unique caption roles — each role gets its own color
    // in FCP's caption lane, giving us color-coded sections.
    // Using SRT format with language codes as color differentiators.
    NSDictionary *sectionRoleMap = @{
        @"intro":      @"SRT.intro",
        @"verse":      @"SRT.verse",
        @"chorus":     @"SRT.chorus",
        @"bridge":     @"SRT.bridge",
        @"outro":      @"SRT.outro",
        @"drop":       @"SRT.drop",
        @"pre-chorus": @"SRT.prechorus",
        @"breakdown":  @"SRT.breakdown",
    };

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<!DOCTYPE fcpxml>\n\n"];
    [xml appendString:@"<fcpxml version=\"1.11\">\n"];
    [xml appendString:@"    <resources>\n"];
    [xml appendFormat:@"        <format id=\"r1\" frameDuration=\"%d/%ds\" width=\"1920\" height=\"1080\"/>\n",
        fdN, fdD];
    [xml appendString:@"    </resources>\n"];
    [xml appendString:@"    <library>\n"];
    [xml appendString:@"        <event name=\"SpliceKit Structure\">\n"];
    [xml appendFormat:@"            <project name=\"%@\">\n", tempName];
    [xml appendFormat:@"                <sequence format=\"r1\" duration=\"%@\" "
        @"tcStart=\"0s\" tcFormat=\"NDF\" audioLayout=\"stereo\" audioRate=\"48k\">\n", totalDurStr];
    [xml appendString:@"                    <spine>\n"];
    [xml appendFormat:@"                        <gap name=\"placeholder\" duration=\"%@\" start=\"0s\">\n",
        totalDurStr];

    NSUInteger captionCount = 0;
    NSMutableSet *usedLanes = [NSMutableSet set];
    NSMutableDictionary *roleLaneMap = [NSMutableDictionary dictionary];
    int nextLane = 1;

    for (NSDictionary *s in sections) {
        NSString *label = [s[@"label"] uppercaseString] ?: @"SECTION";
        NSString *rawLabel = [s[@"label"] lowercaseString] ?: @"section";
        double startSec = [s[@"start"] doubleValue];
        double durSec = [s[@"end"] doubleValue] - startSec;
        if (durSec <= 0) continue;

        long long startFrames = (long long)round(startSec * fdD / fdN);
        long long durFrames = (long long)round(durSec * fdD / fdN);
        if (durFrames <= 0) durFrames = 1;

        // Find the base section type (strip numbers: "verse1" -> "verse")
        NSString *baseType = rawLabel;
        NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
        while (baseType.length > 0 && [digits characterIsMember:[baseType characterAtIndex:baseType.length - 1]]) {
            baseType = [baseType substringToIndex:baseType.length - 1];
        }

        // Get the role for this section type
        NSString *captionRole = sectionRoleMap[baseType] ?: @"SRT.section";

        // Assign lanes — same role type shares the same lane
        if (!roleLaneMap[captionRole]) {
            roleLaneMap[captionRole] = @(nextLane);
            nextLane++;
        }
        int lane = [roleLaneMap[captionRole] intValue];

        NSString *offsetStr = [NSString stringWithFormat:@"%lld/%ds", startFrames * fdN, fdD];
        NSString *durStr = [NSString stringWithFormat:@"%lld/%ds", durFrames * fdN, fdD];

        [xml appendFormat:@"                            <caption lane=\"%d\" offset=\"%@\" "
            @"name=\"%@\" duration=\"%@\" role=\"%@\">\n"
            @"                                <text>%@</text>\n"
            @"                            </caption>\n",
            lane, offsetStr, label, durStr, captionRole, label];
        captionCount++;
    }

    [xml appendString:@"                        </gap>\n"];
    [xml appendString:@"                    </spine>\n"];
    [xml appendString:@"                </sequence>\n"];
    [xml appendString:@"            </project>\n"];
    [xml appendString:@"        </event>\n"];
    [xml appendString:@"    </library>\n"];
    [xml appendString:@"</fcpxml>\n"];

    SpliceKit_log(@"[Structure] Built FCPXML with %lu <caption> elements", (unsigned long)captionCount);

    // Import FCPXML
    NSDictionary *importResult = SpliceKit_handleFCPXMLImport(@{@"xml": xml, @"internal": @YES});
    if (importResult[@"error"]) {
        return @{@"error": [NSString stringWithFormat:@"Import failed: %@", importResult[@"error"]]};
    }

    // Wait for temp project to appear
    __block id tempSeq = nil;
    for (int i = 0; i < 15; i++) {
        [NSThread sleepForTimeInterval:0.5];
        SpliceKit_executeOnMainThread(^{
            tempSeq = SB_findSequenceByPrefix(tempName);
        });
        if (tempSeq) break;
    }
    if (!tempSeq) {
        return @{@"error": @"Temp project not found after import"};
    }
    SpliceKit_log(@"[Structure] Found temp project: %@", tempName);

    // Load temp project
    SpliceKit_executeOnMainThread(^{
        id appDelegate = [NSApp delegate];
        id editorContainer = ((id (*)(id, SEL))objc_msgSend)(appDelegate,
            NSSelectorFromString(@"activeEditorContainer"));
        if (editorContainer) {
            SEL loadSel = NSSelectorFromString(@"loadEditorForSequence:");
            if ([editorContainer respondsToSelector:loadSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(editorContainer, loadSel, tempSeq);
            }
        }
    });

    // Wait for temp timeline to be active
    for (int i = 0; i < 10; i++) {
        [NSThread sleepForTimeInterval:0.5];
        __block BOOL ready = NO;
        SpliceKit_executeOnMainThread(^{
            id tm = SpliceKit_getActiveTimelineModule();
            if (!tm) return;
            id seq = ((id (*)(id, SEL))objc_msgSend)(tm, @selector(sequence));
            if (!seq) return;
            NSString *name = ((id (*)(id, SEL))objc_msgSend)(seq, NSSelectorFromString(@"displayName"));
            ready = [name hasPrefix:tempName];
        });
        if (ready) break;
    }

    [NSThread sleepForTimeInterval:0.5];

    // Select all + copy
    SpliceKit_executeOnMainThread(^{
        [NSApp sendAction:NSSelectorFromString(@"selectAll:") to:nil from:nil];
    });
    [NSThread sleepForTimeInterval:0.3];
    SpliceKit_executeOnMainThread(^{
        [NSApp sendAction:NSSelectorFromString(@"copy:") to:nil from:nil];
    });
    [NSThread sleepForTimeInterval:0.3];

    // Switch back to user's project
    SpliceKit_executeOnMainThread(^{
        id userSeq = nil;
        Class libDocClass = objc_getClass("FFLibraryDocument");
        if (libDocClass) {
            SEL copySel = NSSelectorFromString(@"copyActiveLibraries");
            NSArray *libs = ((id (*)(id, SEL))objc_msgSend)((id)libDocClass, copySel);
            for (id lib in libs) {
                SEL deepSel = NSSelectorFromString(@"_deepLoadedSequences");
                if (![lib respondsToSelector:deepSel]) continue;
                id seqSet = ((id (*)(id, SEL))objc_msgSend)(lib, deepSel);
                NSArray *seqs = [seqSet isKindOfClass:[NSSet class]]
                    ? [(NSSet *)seqSet allObjects] : seqSet;
                for (id seq in seqs) {
                    NSString *name = ((id (*)(id, SEL))objc_msgSend)(seq,
                        NSSelectorFromString(@"displayName"));
                    if ([name isEqualToString:userSequenceName]) {
                        userSeq = seq;
                        break;
                    }
                }
                if (userSeq) break;
            }
        }

        if (userSeq) {
            id appDelegate = [NSApp delegate];
            id editorContainer = ((id (*)(id, SEL))objc_msgSend)(appDelegate,
                NSSelectorFromString(@"activeEditorContainer"));
            if (editorContainer) {
                SEL loadSel = NSSelectorFromString(@"loadEditorForSequence:");
                if ([editorContainer respondsToSelector:loadSel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(editorContainer, loadSel, userSeq);
                }
            }
        }
    });

    // Wait for user project to be active
    for (int i = 0; i < 10; i++) {
        [NSThread sleepForTimeInterval:0.5];
        __block BOOL ready = NO;
        SpliceKit_executeOnMainThread(^{
            id tm = SpliceKit_getActiveTimelineModule();
            if (!tm) return;
            id seq = ((id (*)(id, SEL))objc_msgSend)(tm, @selector(sequence));
            if (!seq) return;
            NSString *name = ((id (*)(id, SEL))objc_msgSend)(seq, NSSelectorFromString(@"displayName"));
            ready = [name isEqualToString:userSequenceName];
        });
        if (ready) break;
    }

    [NSThread sleepForTimeInterval:0.5];

    // Paste captions
    SpliceKit_executeOnMainThread(^{
        [NSApp sendAction:NSSelectorFromString(@"deselectAll:") to:nil from:nil];
    });
    [NSThread sleepForTimeInterval:0.2];
    SpliceKit_executeOnMainThread(^{
        [NSApp sendAction:NSSelectorFromString(@"paste:") to:nil from:nil];
    });
    [NSThread sleepForTimeInterval:0.5];

    // Clean up temp project
    SpliceKit_executeOnMainThread(^{
        id tempToDelete = SB_findSequenceByPrefix(tempName);
        if (tempToDelete) SB_deleteSequence(tempToDelete);
    });

    SpliceKit_log(@"[Structure] Done: %lu captions placed in caption lane", (unsigned long)captionCount);

    return @{
        @"status": @"ok",
        @"captionCount": @(captionCount),
        @"roles": [roleLaneMap allKeys],
    };
}

// =================================================================
// Generate Structure Blocks (connected storyline approach)
// =================================================================
// Takes an array of sections [{label, start, end}] and creates a
// connected storyline of colored title blocks above the primary.

NSDictionary *SpliceKit_handleStructureGenerateBlocks(NSDictionary *params) {
    NSArray *sections = params[@"sections"];
    if (!sections || ![sections isKindOfClass:[NSArray class]] || sections.count == 0)
        return @{@"error": @"sections array required (each: {label, start, end})"};

    __block NSDictionary *result = nil;
    __block NSData *nativePasteboardData = nil;
    __block int titleCount = 0;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }
            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) { result = @{@"error": @"No sequence in timeline"}; return; }

            // Get frame duration
            int fdN = 100, fdD = 2400; // default 24fps
            SEL fdSel = NSSelectorFromString(@"frameDuration");
            if ([sequence respondsToSelector:fdSel]) {
                SB_CMTime fd = ((SB_CMTime (*)(id, SEL))SB_STRET_MSG)(sequence, fdSel);
                if (fd.timescale > 0) { fdN = (int)fd.value; fdD = fd.timescale; }
            }

            // Create the storyline collection
            Class collClass = objc_getClass("FFAnchoredCollection");
            if (!collClass) { result = @{@"error": @"FFAnchoredCollection not found"}; return; }

            id storyline = ((id (*)(id, SEL, id))objc_msgSend)(
                ((id (*)(id, SEL))objc_msgSend)(collClass, @selector(alloc)),
                NSSelectorFromString(@"initWithDisplayName:"),
                kStructureStorylineName);
            if (!storyline) { result = @{@"error": @"Failed to create storyline"}; return; }

            SEL setIsSpineSel = NSSelectorFromString(@"setIsSpine:");
            if ([storyline respondsToSelector:setIsSpineSel])
                ((void (*)(id, SEL, BOOL))objc_msgSend)(storyline, setIsSpineSel, YES);

            SEL setContentCreatedSel = NSSelectorFromString(@"setContentCreated:");
            if ([storyline respondsToSelector:setContentCreatedSel])
                ((void (*)(id, SEL, id))objc_msgSend)(storyline, setContentCreatedSel, [NSDate date]);

            SEL setAngleIDSel = NSSelectorFromString(@"setAngleID:");
            if ([storyline respondsToSelector:setAngleIDSel])
                ((void (*)(id, SEL, id))objc_msgSend)(storyline, setAngleIDSel, @"");

            SEL setUnclippedStartSel = NSSelectorFromString(@"setUnclippedStart:");
            if ([storyline respondsToSelector:setUnclippedStartSel])
                ((void (*)(id, SEL, SB_CMTime))objc_msgSend)(storyline, setUnclippedStartSel,
                    SB_makeTime(0, fdN, fdD));

            SEL addContainedSel = NSSelectorFromString(@"addObjectToContainedItems:");
            if (![storyline respondsToSelector:addContainedSel]) {
                result = @{@"error": @"Storyline cannot accept contained items"};
                return;
            }

            // Build title blocks for each section
            long long cursorFrames = 0;
            for (NSDictionary *sec in sections) {
                NSString *label = sec[@"label"] ?: @"Section";
                double startSec = [sec[@"start"] doubleValue];
                double endSec = [sec[@"end"] doubleValue];
                double durSec = endSec - startSec;
                if (durSec <= 0) continue;

                long long startFrames = SB_frameCount(startSec, fdN, fdD, YES);
                if (startFrames < cursorFrames) startFrames = cursorFrames;
                long long durationFrames = SB_frameCount(durSec, fdN, fdD, NO);
                if (durationFrames <= 0) durationFrames = 1;

                // Insert gap if needed
                if (startFrames > cursorFrames) {
                    id gap = SB_newGap(
                        SB_makeTime(startFrames - cursorFrames, fdN, fdD),
                        SB_makeTime(1, fdN, fdD));
                    if (gap) {
                        ((void (*)(id, SEL, id))objc_msgSend)(storyline, addContainedSel, gap);
                    }
                }

                // Create a gap component as the section block.
                // Gaps render as thin bars in the timeline (much thinner than title generators),
                // making the structure lane compact and non-obtrusive.
                id block = SB_newGap(
                    SB_makeTime(durationFrames, fdN, fdD),
                    SB_makeTime(1, fdN, fdD));
                if (!block) {
                    SpliceKit_log(@"[Structure] Failed to create gap block for '%@'", label);
                    continue;
                }

                // Set display name so the section label shows in the timeline
                NSString *displayLabel = [label uppercaseString];
                SEL setDisplayNameSel = NSSelectorFromString(@"setDisplayName:");
                if ([block respondsToSelector:setDisplayNameSel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(block, setDisplayNameSel, displayLabel);
                }

                ((void (*)(id, SEL, id))objc_msgSend)(storyline, addContainedSel, block);
                cursorFrames = startFrames + durationFrames;
                titleCount++;
            }

            if (titleCount == 0) {
                result = @{@"error": @"No structure blocks could be created"};
                return;
            }

            // Archive the storyline
            NSDictionary *archiveRoot = @{@"objects": @[storyline]};
            NSError *archiveError = nil;
            NSData *archiveData = [NSKeyedArchiver archivedDataWithRootObject:archiveRoot
                                                        requiringSecureCoding:NO
                                                                       error:&archiveError];
            if (!archiveData) {
                result = @{@"error": archiveError.localizedDescription ?: @"Archive failed"};
                return;
            }

            // Build pasteboard plist
            NSDictionary *pbDict = @{
                @"ffpasteboardcopiedtypes": @{@"pb_anchoredObject": @{@"count": @1}},
                @"ffpasteboardobject": archiveData,
                @"kffmodelobjectIDs": @[],
            };
            NSError *plistError = nil;
            nativePasteboardData = [NSPropertyListSerialization dataWithPropertyList:pbDict
                                                                              format:NSPropertyListBinaryFormat_v1_0
                                                                             options:0
                                                                               error:&plistError];
            if (!nativePasteboardData) {
                result = @{@"error": plistError.localizedDescription ?: @"Pasteboard serialization failed"};
                return;
            }

            SpliceKit_log(@"[Structure] Built storyline with %d blocks (%lu bytes)",
                          titleCount, (unsigned long)nativePasteboardData.length);

            // Remove existing structure storyline
            NSUInteger removed = SB_removeStoryline(sequence, kStructureStorylineName);
            if (removed > 0) {
                SpliceKit_log(@"[Structure] Removed %lu existing structure storyline(s)",
                              (unsigned long)removed);
            }

        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    if (result) return result;
    if (!nativePasteboardData) return @{@"error": @"No pasteboard data produced"};

    // Paste as connected storyline
    __block BOOL pasteOk = NO;

    SpliceKit_executeOnMainThread(^{
        id tm = SpliceKit_getActiveTimelineModule();
        id seq = tm ? ((id (*)(id, SEL))objc_msgSend)(tm, @selector(sequence)) : nil;
        int fdN = 100, fdD = 2400;
        SEL fdSel = NSSelectorFromString(@"frameDuration");
        if (seq && [seq respondsToSelector:fdSel]) {
            SB_CMTime fd = ((SB_CMTime (*)(id, SEL))SB_STRET_MSG)(seq, fdSel);
            if (fd.timescale > 0) { fdN = (int)fd.value; fdD = fd.timescale; }
        }

        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setData:nativePasteboardData forType:@"com.apple.flexo.proFFPasteboardUTI"];

        // Seek to start
        if (tm) {
            SEL setSel = NSSelectorFromString(@"setPlayheadTime:");
            if ([tm respondsToSelector:setSel]) {
                ((void (*)(id, SEL, SB_CMTime))objc_msgSend)(tm, setSel, SB_makeTime(0, fdN, fdD));
            }
        }
        [[NSApplication sharedApplication] sendAction:NSSelectorFromString(@"deselectAll:")
                                                   to:nil from:nil];
    });

    [NSThread sleepForTimeInterval:0.2];

    SpliceKit_executeOnMainThread(^{
        pasteOk = [[NSApplication sharedApplication]
            sendAction:NSSelectorFromString(@"pasteAnchored:")
                    to:nil from:nil];
    });

    [NSThread sleepForTimeInterval:0.6];

    SpliceKit_log(@"[Structure] Paste as connected: %@", pasteOk ? @"YES" : @"NO");

    return @{
        @"status": pasteOk ? @"ok" : @"paste_failed",
        @"blocks": @(titleCount),
        @"storylineName": kStructureStorylineName,
    };
}

// =================================================================
// Remove Structure Blocks
// =================================================================

NSDictionary *SpliceKit_handleStructureRemove(NSDictionary *params) {
    __block NSUInteger removed = 0;
    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        id sequence = SB_currentSequence();
        if (!sequence) { result = @{@"error": @"No active timeline"}; return; }
        removed = SB_removeStoryline(sequence, kStructureStorylineName);
    });

    if (result) return result;
    return @{
        @"status": @"ok",
        @"removed": @(removed),
    };
}

// =================================================================
// Toggle Structure Blocks
// =================================================================

NSDictionary *SpliceKit_handleStructureToggle(NSDictionary *params) {
    __block BOOL exists = NO;
    SpliceKit_executeOnMainThread(^{
        id sequence = SB_currentSequence();
        if (sequence) exists = SB_hasStoryline(sequence);
    });

    if (exists) {
        return SpliceKit_handleStructureRemove(params);
    } else {
        // Need sections to regenerate — check if they were passed
        if (params[@"sections"]) {
            return SpliceKit_handleStructureGenerateBlocks(params);
        }
        return @{@"error": @"No structure blocks to toggle. Pass sections array to create."};
    }
}

// =================================================================
// Context Menu — Right-click to change section color
// =================================================================

// Color presets for the context menu
static NSArray<NSDictionary *> *SB_colorPresets(void) {
    return @[
        @{@"name": @"Blue (Verse)",    @"r": @0.20, @"g": @0.50, @"b": @0.85},
        @{@"name": @"Orange (Chorus)", @"r": @0.95, @"g": @0.55, @"b": @0.10},
        @{@"name": @"Purple (Bridge)", @"r": @0.55, @"g": @0.25, @"b": @0.75},
        @{@"name": @"Gray (Intro)",    @"r": @0.40, @"g": @0.45, @"b": @0.55},
        @{@"name": @"Red (Drop)",      @"r": @0.90, @"g": @0.15, @"b": @0.15},
        @{@"name": @"Green",           @"r": @0.20, @"g": @0.70, @"b": @0.30},
        @{@"name": @"Teal",            @"r": @0.15, @"g": @0.65, @"b": @0.65},
        @{@"name": @"Pink",            @"r": @0.90, @"g": @0.35, @"b": @0.55},
        @{@"name": @"Yellow",          @"r": @0.95, @"g": @0.80, @"b": @0.10},
    ];
}

// Find a CHChannelText node in the generator's effect channel tree
static id SB_findTextChannel(id generator) {
    SEL effectSel = NSSelectorFromString(@"effect");
    if (![generator respondsToSelector:effectSel]) return nil;
    id effect = ((id (*)(id, SEL))objc_msgSend)(generator, effectSel);
    if (!effect) return nil;

    SEL chFolderSel = NSSelectorFromString(@"channelFolder");
    if (![effect respondsToSelector:chFolderSel]) return nil;
    id folder = ((id (*)(id, SEL))objc_msgSend)(effect, chFolderSel);
    if (!folder) return nil;

    Class textChannelClass = objc_getClass("CHChannelText");
    if (!textChannelClass) return nil;

    SEL subchannelsSel = NSSelectorFromString(@"subchannels");
    if (![folder respondsToSelector:subchannelsSel]) return nil;
    NSArray *subchannels = ((id (*)(id, SEL))objc_msgSend)(folder, subchannelsSel);

    for (id ch in subchannels) {
        if ([ch isKindOfClass:textChannelClass]) return ch;
    }
    return nil;
}

// Apply a new font color to a structure block generator
static void SB_applyColorToGenerator(id generator, CGFloat r, CGFloat g, CGFloat b) {
    id textChannel = SB_findTextChannel(generator);
    if (!textChannel) return;

    SEL getAttrSel = NSSelectorFromString(@"attributedString");
    if (![textChannel respondsToSelector:getAttrSel]) return;
    NSAttributedString *existing = ((id (*)(id, SEL))objc_msgSend)(textChannel, getAttrSel);
    if (!existing || existing.length == 0) return;

    NSString *text = existing.string;
    NSColor *newColor = [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];

    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    // Preserve existing font
    NSDictionary *existingAttrs = [existing attributesAtIndex:0 effectiveRange:NULL];
    if (existingAttrs[NSFontAttributeName]) attrs[NSFontAttributeName] = existingAttrs[NSFontAttributeName];
    else attrs[NSFontAttributeName] = [NSFont boldSystemFontOfSize:36];
    attrs[NSForegroundColorAttributeName] = newColor;

    NSAttributedString *newAttr = [[NSAttributedString alloc] initWithString:text attributes:attrs];

    SEL setAttrSel = NSSelectorFromString(@"setAttributedString:");
    if ([textChannel respondsToSelector:setAttrSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(textChannel, setAttrSel, newAttr);
    }
}

// --- Context menu target (handles color change actions) ---

@interface SpliceKitStructureMenuHandler : NSObject
+ (instancetype)shared;
- (void)changeColor:(NSMenuItem *)sender;
@end

@implementation SpliceKitStructureMenuHandler {
    id _targetGenerator;
}

+ (instancetype)shared {
    static SpliceKitStructureMenuHandler *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)setTargetGenerator:(id)gen { _targetGenerator = gen; }

- (void)changeColor:(NSMenuItem *)sender {
    if (!_targetGenerator) return;
    NSDictionary *preset = sender.representedObject;
    if (!preset) return;

    CGFloat r = [preset[@"r"] doubleValue];
    CGFloat g = [preset[@"g"] doubleValue];
    CGFloat b = [preset[@"b"] doubleValue];
    SB_applyColorToGenerator(_targetGenerator, r, g, b);
    SpliceKit_log(@"[Structure] Changed block color to %@ (%.1f, %.1f, %.1f)",
                  preset[@"name"], r, g, b);
}

@end

// --- TLKTimelineView menuForEvent: swizzle ---

static IMP sOrigMenuForEvent = NULL;

// Check if a clicked item belongs to the structure storyline
static id SB_findStructureGeneratorAtClick(id timelineView, NSEvent *event) {
    // Get the timeline module and check selected items
    id tm = SpliceKit_getActiveTimelineModule();
    if (!tm) return nil;

    SEL selItemsSel = NSSelectorFromString(@"selectedItems");
    if (![tm respondsToSelector:selItemsSel]) return nil;
    NSArray *selectedItems = ((id (*)(id, SEL))objc_msgSend)(tm, selItemsSel);
    if (![selectedItems isKindOfClass:[NSArray class]] || selectedItems.count == 0) return nil;

    // Check if any selected item is a generator inside our structure storyline
    SEL displayNameSel = NSSelectorFromString(@"displayName");
    SEL parentSel = NSSelectorFromString(@"anchoredToObject");
    for (id item in selectedItems) {
        NSString *className = NSStringFromClass([item class]) ?: @"";
        if (![className containsString:@"Generator"]) continue;

        // Walk up to find the parent storyline
        if ([item respondsToSelector:parentSel]) {
            id parent = ((id (*)(id, SEL))objc_msgSend)(item, parentSel);
            // The parent might be a collection (our storyline) or a clip in the primary
            // Check if the parent collection is our structure storyline
            while (parent) {
                NSString *pClass = NSStringFromClass([parent class]) ?: @"";
                if ([pClass containsString:@"Collection"]) {
                    @try {
                        if ([parent respondsToSelector:displayNameSel]) {
                            id name = ((id (*)(id, SEL))objc_msgSend)(parent, displayNameSel);
                            if ([name isKindOfClass:[NSString class]] &&
                                [name isEqualToString:kStructureStorylineName]) {
                                return item;
                            }
                        }
                    } @catch (NSException *e) {}
                }
                // Walk up further
                if ([parent respondsToSelector:parentSel]) {
                    id nextParent = ((id (*)(id, SEL))objc_msgSend)(parent, parentSel);
                    if (nextParent == parent) break; // avoid infinite loop
                    parent = nextParent;
                } else {
                    break;
                }
            }
        }
    }
    return nil;
}

static NSMenu *SB_swizzled_menuForEvent(id self, SEL _cmd, NSEvent *event) {
    // Call the original menuForEvent: first
    NSMenu *menu = sOrigMenuForEvent
        ? ((NSMenu *(*)(id, SEL, NSEvent *))sOrigMenuForEvent)(self, _cmd, event)
        : nil;

    // Check if we right-clicked a structure block
    id structGen = SB_findStructureGeneratorAtClick(self, event);
    if (structGen) {
        [[SpliceKitStructureMenuHandler shared] setTargetGenerator:structGen];

        if (!menu) menu = [[NSMenu alloc] initWithTitle:@""];

        // Add separator if menu already has items
        if (menu.numberOfItems > 0) [menu addItem:[NSMenuItem separatorItem]];

        // Add "Section Color" submenu
        NSMenuItem *colorItem = [[NSMenuItem alloc] initWithTitle:@"Section Color"
                                                           action:nil
                                                    keyEquivalent:@""];
        NSMenu *colorMenu = [[NSMenu alloc] initWithTitle:@"Section Color"];

        for (NSDictionary *preset in SB_colorPresets()) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:preset[@"name"]
                                                          action:@selector(changeColor:)
                                                   keyEquivalent:@""];
            item.target = [SpliceKitStructureMenuHandler shared];
            item.representedObject = preset;

            // Create a color swatch image for the menu item
            NSImage *swatch = [[NSImage alloc] initWithSize:NSMakeSize(14, 14)];
            [swatch lockFocus];
            NSColor *c = [NSColor colorWithSRGBRed:[preset[@"r"] doubleValue]
                                             green:[preset[@"g"] doubleValue]
                                              blue:[preset[@"b"] doubleValue]
                                             alpha:1.0];
            [c setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1, 1, 12, 12)
                                            xRadius:2 yRadius:2] fill];
            [swatch unlockFocus];
            item.image = swatch;

            [colorMenu addItem:item];
        }

        colorItem.submenu = colorMenu;
        [menu addItem:colorItem];
    }

    return menu;
}

// --- Install the context menu swizzle ---

void SpliceKit_installStructureBlockContextMenu(void) {
    Class cls = objc_getClass("TLKTimelineView");
    if (!cls) {
        SpliceKit_log(@"[Structure] TLKTimelineView not found, skipping context menu");
        return;
    }

    Method m = class_getInstanceMethod(cls, @selector(menuForEvent:));
    if (!m) {
        SpliceKit_log(@"[Structure] menuForEvent: not found on TLKTimelineView");
        return;
    }

    sOrigMenuForEvent = method_getImplementation(m);
    method_setImplementation(m, (IMP)SB_swizzled_menuForEvent);
    SpliceKit_log(@"[Structure] Installed TLKTimelineView menuForEvent: swizzle for section colors");
}
