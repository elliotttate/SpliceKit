# SpliceKit Caption System — Complete Technical Internals

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Data Flow: End-to-End Pipeline](#2-data-flow-end-to-end-pipeline)
3. [Data Models](#3-data-models)
   - [SpliceKitCaptionStyle](#31-splicekitcaptionstyle)
   - [SpliceKitCaptionSegment](#32-splicekitcaptionsegment)
   - [SpliceKitTranscriptWord (shared)](#33-splicekittranscriptword-shared)
4. [Transcription Engine Integration](#4-transcription-engine-integration)
5. [Word Segmentation Algorithm](#5-word-segmentation-algorithm)
6. [FCPXML Generation — The Core Engine](#6-fcpxml-generation--the-core-engine)
   - [Timeline Property Detection](#61-timeline-property-detection)
   - [Rational Time Conversion](#62-rational-time-conversion)
   - [FCPXML Document Structure](#63-fcpxml-document-structure)
   - [Word-by-Word Highlight Mode](#64-word-by-word-highlight-mode)
   - [Non-Highlight Mode](#65-non-highlight-mode)
   - [Text Style XML Generation](#66-text-style-xml-generation)
   - [Position Calculation](#67-position-calculation)
7. [The Dedicated Caption Lane — Lane 1 System](#7-the-dedicated-caption-lane--lane-1-system)
   - [How FCPXML Lanes Work](#71-how-fcpxml-lanes-work)
   - [The Gap Anchor Pattern](#72-the-gap-anchor-pattern)
   - [Title Clips as Connected Items](#73-title-clips-as-connected-items)
   - [Why Lane 1 Specifically](#74-why-lane-1-specifically)
8. [Import Mechanism — NSOpenPanel Swizzling](#8-import-mechanism--nsopenpanel-swizzling)
9. [Style Preset System](#9-style-preset-system)
10. [UI Architecture — The Floating Panel](#10-ui-architecture--the-floating-panel)
11. [RPC Server Integration](#11-rpc-server-integration)
12. [MCP Tool Definitions](#12-mcp-tool-definitions)
13. [Export Formats](#13-export-formats)
14. [Reusing This System for Another Caption Engine](#14-reusing-this-system-for-another-caption-engine)
    - [Integration Points](#141-integration-points)
    - [Minimal Implementation: Injecting Words](#142-minimal-implementation-injecting-words)
    - [Custom Style: Extending the Preset System](#143-custom-style-extending-the-preset-system)
    - [Alternative Import Strategies](#144-alternative-import-strategies)
    - [Building a New Panel That Reuses the FCPXML Generator](#145-building-a-new-panel-that-reuses-the-fcpxml-generator)
    - [Using the Lane System for Non-Caption Overlays](#146-using-the-lane-system-for-non-caption-overlays)
15. [Thread Safety & Concurrency](#15-thread-safety--concurrency)
16. [Color Conversion Utilities](#16-color-conversion-utilities)
17. [File Manifest](#17-file-manifest)

---

## 1. Architecture Overview

The SpliceKit caption system generates social-media-style, word-by-word highlighted
caption titles and imports them into Final Cut Pro's timeline. It is built as an
in-process ObjC panel injected into FCP's address space.

**Core design philosophy:** Captions are not FCP's built-in subtitle/caption objects
(`FFAnchoredCaption`). Instead, they are **Basic Title generator clips** — full
FCPXML `<title>` elements with styled text, positioned on **lane 1** (a connected
storyline above the primary storyline). This gives complete control over typography,
colors, outlines, shadows, and word-by-word highlight animations that FCP's native
caption system doesn't support.

**Key components:**

```
┌─────────────────────────────────────────────────────────────┐
│  MCP Server (Python)                                        │
│  mcp/server.py — tool definitions                           │
│  open_captions(), generate_captions(), set_caption_style()  │
│         │  JSON-RPC over TCP :9876                          │
├─────────┼───────────────────────────────────────────────────┤
│  RPC Server (ObjC)                                          │
│  SpliceKitServer.m — captions.* namespace dispatch          │
│  SpliceKit_handleCaptionsGenerate(), etc.                   │
│         │  Direct ObjC calls                                │
├─────────┼───────────────────────────────────────────────────┤
│  Caption Panel (ObjC)                                       │
│  SpliceKitCaptionPanel.h/m                                  │
│  ┌──────────────────────────────────────────────┐           │
│  │ Style System        │ Segmentation Engine    │           │
│  │ 12 presets           │ 4 grouping modes       │           │
│  │ Custom overrides     │ Silence-gap detection   │           │
│  ├──────────────────────┼────────────────────────┤           │
│  │ FCPXML Generator     │ Import Engine           │           │
│  │ Title elements       │ NSOpenPanel swizzle     │           │
│  │ Text style defs      │ importCaptions: action  │           │
│  │ Lane 1 placement     │ SRT file intermediary   │           │
│  └──────────────────────┴────────────────────────┘           │
│         │  Notification delegate                             │
├─────────┼───────────────────────────────────────────────────┤
│  Transcript Panel (ObjC)                                    │
│  SpliceKitTranscriptPanel.h/m                               │
│  Parakeet/Apple Speech/FCP Native engines                   │
│  Word-level timing extraction                                │
└─────────────────────────────────────────────────────────────┘
```

**Files involved:**

| File | Role |
|------|------|
| `Sources/SpliceKitCaptionPanel.h` | Interface, enums, model classes |
| `Sources/SpliceKitCaptionPanel.m` | Full implementation (~1800 lines) |
| `Sources/SpliceKitTranscriptPanel.h` | Transcript word model, engine enum |
| `Sources/SpliceKitTranscriptPanel.m` | Transcription engine, word extraction |
| `Sources/SpliceKitServer.m` | RPC handlers (lines 4107-4242, dispatch 15594-15614) |
| `mcp/server.py` | MCP tool definitions (lines 3362-3625) |

---

## 2. Data Flow: End-to-End Pipeline

```
User calls generate_captions(style="bold_pop")
    │
    ▼
MCP server.py: generate_captions() ──────────────────────────────
    │  bridge.call("captions.generate", style="bold_pop", ...)
    ▼
SpliceKitServer.m: SpliceKit_handleCaptionsGenerate()
    │  1. Resolve preset → SpliceKitCaptionStyle object
    │  2. Merge parameter overrides via dictionary round-trip
    │  3. [panel setStyle:style]
    │  4. dispatch_async(global queue) → [panel generateCaptions]
    ▼
SpliceKitCaptionPanel.m: generateCaptions()
    │
    │  Step 1: Validate words exist (from prior transcription)
    │  Step 2: [self regroupSegments] — organize words into segments
    │  Step 3: [self detectTimelineProperties] — frame rate, resolution
    │  Step 4: Build FCPXML document:
    │     │
    │     │  For each segment:
    │     │    ┌─ Word-by-word highlight mode? ──────────────────────┐
    │     │    │ YES: One <title> per word, full segment text shown  │
    │     │    │      Active word gets highlightColor, others normal │
    │     │    │ NO:  One <title> per segment, uniform text color    │
    │     │    └────────────────────────────────────────────────────┘
    │     │    Each <title>:
    │     │      - ref="r2" (Basic Title effect)
    │     │      - lane="1" (connected storyline, above primary)
    │     │      - offset, duration in rational frames
    │     │      - <text> with <text-style> refs
    │     │      - <text-style-def> for normal + highlight colors
    │     │      - <adjust-transform position="0 Y"/>
    │     │
    │  Step 5: Write FCPXML to /tmp/splicekit_captions.fcpxml
    │  Step 6: [self exportSRT:srtPath] — SRT for import
    │  Step 7: Swizzle NSOpenPanel (URLs, URL, runModal)
    │  Step 8: Send "importCaptions:" through responder chain
    │  Step 9: FCP imports SRT → captions on timeline
    │  Step 10: Clear swizzle URL after 1 second
    │
    ▼
Result: { titleCount, segmentCount, fcpxmlPath, srtPath, message }
```

---

## 3. Data Models

### 3.1 SpliceKitCaptionStyle

Defined in `SpliceKitCaptionPanel.h:53-98`. The style model captures every visual
property of the caption text.

```objc
@interface SpliceKitCaptionStyle : NSObject <NSCopying>

// Identity
@property (nonatomic, copy) NSString *name;              // "Bold Pop"
@property (nonatomic, copy) NSString *presetID;          // "bold_pop"

// Typography
@property (nonatomic, copy) NSString *font;              // "Futura-Bold"
@property (nonatomic) CGFloat fontSize;                   // 60-80 typical
@property (nonatomic, copy) NSString *fontFace;           // "Bold", "Regular"

// Text colors (NSColor objects, converted to "R G B A" for FCPXML)
@property (nonatomic, copy) NSColor *textColor;           // default white
@property (nonatomic, copy) NSColor *highlightColor;      // active word (nil = no highlight)

// Outline/stroke
@property (nonatomic, copy) NSColor *outlineColor;
@property (nonatomic) CGFloat outlineWidth;               // 0-5

// Drop shadow
@property (nonatomic, copy) NSColor *shadowColor;
@property (nonatomic) CGFloat shadowBlurRadius;           // 0-20
@property (nonatomic) CGFloat shadowOffsetX;
@property (nonatomic) CGFloat shadowOffsetY;

// Background (pseudo via stroke)
@property (nonatomic, copy) NSColor *backgroundColor;     // nil = no background
@property (nonatomic) CGFloat backgroundPadding;          // stroke width for bg effect

// Position & Animation
@property (nonatomic) SpliceKitCaptionPosition position;  // bottom/center/top/custom
@property (nonatomic) CGFloat customYOffset;              // for custom position
@property (nonatomic) SpliceKitCaptionAnimation animation;
@property (nonatomic) CGFloat animationDuration;          // seconds (0.15-0.5)

// Formatting
@property (nonatomic) BOOL allCaps;                       // force uppercase
@property (nonatomic) BOOL wordByWordHighlight;           // karaoke mode

// Serialization
- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;

// Presets
+ (NSArray<SpliceKitCaptionStyle *> *)builtInPresets;
+ (instancetype)presetWithID:(NSString *)presetID;

@end
```

**Default values** (from `init`, line 71-96):

| Property | Default |
|----------|---------|
| font | "Helvetica Neue" |
| fontSize | 60 |
| fontFace | "Bold" |
| textColor | white (1 1 1 1) |
| highlightColor | yellow (1 0.85 0 1) |
| outlineColor | black (0 0 0 1) |
| outlineWidth | 2.0 |
| shadowColor | black @ 80% (0 0 0 0.8) |
| shadowBlurRadius | 4.0 |
| position | Bottom |
| animation | Fade |
| animationDuration | 0.2 |
| allCaps | YES |
| wordByWordHighlight | YES |

### 3.2 SpliceKitCaptionSegment

Defined in `SpliceKitCaptionPanel.h:103-111`. A segment is a group of words that
will be shown together on screen at the same time (the "current line" of the caption).

```objc
@interface SpliceKitCaptionSegment : NSObject
@property (nonatomic, strong) NSArray<SpliceKitTranscriptWord *> *words;
@property (nonatomic) double startTime;          // first word's startTime
@property (nonatomic) double endTime;            // last word's endTime
@property (nonatomic) double duration;           // endTime - startTime
@property (nonatomic, copy) NSString *text;      // all words joined with spaces
@property (nonatomic) NSUInteger segmentIndex;   // 0-based index
- (NSDictionary *)toDictionary;
@end
```

The `toDictionary` serialization (line 424-443) includes nested word objects:

```json
{
    "index": 0,
    "text": "THE QUICK BROWN",
    "startTime": 1.5,
    "endTime": 2.8,
    "duration": 1.3,
    "wordCount": 3,
    "words": [
        {"text": "THE", "startTime": 1.5, "endTime": 1.8, "duration": 0.3},
        {"text": "QUICK", "startTime": 1.85, "endTime": 2.2, "duration": 0.35},
        {"text": "BROWN", "startTime": 2.25, "endTime": 2.8, "duration": 0.55}
    ]
}
```

### 3.3 SpliceKitTranscriptWord (shared)

Defined in `SpliceKitTranscriptPanel.h`. This model is shared between the transcript
and caption systems — it's the common data currency.

```objc
@interface SpliceKitTranscriptWord : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) double startTime;        // seconds from timeline start
@property (nonatomic) double duration;
@property (nonatomic) double endTime;          // computed: startTime + duration
@property (nonatomic) double confidence;       // 0.0-1.0 from ASR engine
@property (nonatomic) NSUInteger wordIndex;    // position in full transcript
@property (nonatomic) NSRange textRange;       // range in joined fullText

// Source tracking
@property (nonatomic, copy) NSString *clipHandle;
@property (nonatomic) double clipTimelineStart;
@property (nonatomic) double sourceMediaOffset;
@property (nonatomic, copy) NSString *sourceMediaPath;

// Speaker diarization
@property (nonatomic, copy) NSString *speaker;
@end
```

**This is the key integration point.** Any system that can produce an array of
`SpliceKitTranscriptWord` objects (or dictionaries with `text`, `startTime`,
`duration`) can feed into the caption generator.

---

## 4. Transcription Engine Integration

The caption panel does NOT transcribe audio itself. It delegates to
`SpliceKitTranscriptPanel` and reuses its word timing data.

**Code path** (`SpliceKitCaptionPanel.m:1170-1224`):

```objc
- (void)transcribeTimeline {
    self.status = SpliceKitCaptionStatusTranscribing;
    // ... update UI ...

    SpliceKitTranscriptPanel *tp = [SpliceKitTranscriptPanel sharedPanel];

    // Optimization: if transcript panel already has words, reuse them
    if (tp.status == SpliceKitTranscriptStatusReady && tp.words.count > 0) {
        [self importWordsFromTranscriptPanel];
        return;
    }

    // Register for completion notification
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(transcriptDidComplete:)
        name:@"SpliceKitTranscriptDidComplete"
        object:nil];

    // Force Parakeet for best word-level timing
    tp.engine = SpliceKitTranscriptEngineParakeet;
    [tp transcribeTimeline];
}
```

When transcription completes, `transcriptDidComplete:` fires and calls
`importWordsFromTranscriptPanel`:

```objc
- (void)importWordsFromTranscriptPanel {
    SpliceKitTranscriptPanel *tp = [SpliceKitTranscriptPanel sharedPanel];
    @synchronized (self.mutableWords) {
        [self.mutableWords removeAllObjects];
        [self.mutableWords addObjectsFromArray:tp.words ?: @[]];
    }
    self.status = SpliceKitCaptionStatusReady;
    [self regroupSegments];
    // ... update UI ...
}
```

**Alternative: Manual word injection** (bypass transcription entirely):

```objc
- (void)setWordsManually:(NSArray<NSDictionary *> *)wordDicts {
    @synchronized (self.mutableWords) {
        [self.mutableWords removeAllObjects];
        for (NSUInteger i = 0; i < wordDicts.count; i++) {
            NSDictionary *d = wordDicts[i];
            SpliceKitTranscriptWord *w = [[SpliceKitTranscriptWord alloc] init];
            w.text = d[@"text"] ?: @"";
            w.startTime = [d[@"startTime"] doubleValue];
            w.duration = [d[@"duration"] doubleValue];
            w.endTime = w.startTime + w.duration;
            w.confidence = 1.0;
            w.wordIndex = i;
            [self.mutableWords addObject:w];
        }
    }
    self.status = SpliceKitCaptionStatusReady;
    [self regroupSegments];
}
```

This is accessible via the MCP `set_caption_words()` tool and the JSON-RPC
`captions.setWords` method. It's the entry point for external transcription services.

---

## 5. Word Segmentation Algorithm

Defined in `SpliceKitCaptionPanel.m:1247-1326`. Segmentation groups words into
display chunks — each segment becomes one "line" of captions on screen.

### Grouping Modes

```objc
typedef NS_ENUM(NSInteger, SpliceKitCaptionGrouping) {
    SpliceKitCaptionGroupingByWordCount = 0,   // max N words per segment (default 5)
    SpliceKitCaptionGroupingBySentence,        // break on .!?; punctuation (max 8 fallback)
    SpliceKitCaptionGroupingByTime,            // max N seconds per segment (default 3.0)
    SpliceKitCaptionGroupingByCharCount,       // max N chars per segment (default 40)
};
```

### Algorithm (pseudocode)

```
function regroupSegments():
    segments = []
    group = []
    segIdx = 0

    for each word in words:
        shouldBreak = false

        // RULE 1: Force break on large silence gaps (> 1.0 second)
        if group is not empty:
            gap = word.startTime - group.last.endTime
            if gap > 1.0:
                shouldBreak = true

        // RULE 2: Check grouping mode
        if not shouldBreak and group is not empty:
            switch groupingMode:
                case ByWordCount:
                    shouldBreak = (group.count >= maxWordsPerSegment)   // default 5

                case BySentence:
                    lastWord = group.last.text
                    shouldBreak = lastWord ends with "." or "!" or "?" or ";"
                    if not shouldBreak:
                        shouldBreak = (group.count >= 8)               // hard limit

                case ByTime:
                    groupStart = group.first.startTime
                    shouldBreak = (word.endTime - groupStart) > maxSecondsPerSegment  // default 3.0

                case ByCharCount:
                    totalChars = sum of (w.text.length + 1) for w in group
                    shouldBreak = (totalChars + word.text.length > maxCharsPerSegment) // default 40

        if shouldBreak and group is not empty:
            segments.append(createSegment(group, segIdx++))
            group = []

        group.append(word)

    // Flush remaining words
    if group is not empty:
        segments.append(createSegment(group, segIdx))

    return segments
```

### Segment creation

```objc
- (SpliceKitCaptionSegment *)segmentFromWords:(NSArray *)words index:(NSUInteger)idx {
    SpliceKitCaptionSegment *seg = [[SpliceKitCaptionSegment alloc] init];
    seg.words = [words copy];
    seg.startTime = words.firstObject.startTime;
    seg.endTime = words.lastObject.endTime;
    seg.duration = seg.endTime - seg.startTime;
    seg.text = [[words valueForKey:@"text"] componentsJoinedByString:@" "];
    seg.segmentIndex = idx;
    return seg;
}
```

---

## 6. FCPXML Generation — The Core Engine

This is the heart of the caption system. Located at `SpliceKitCaptionPanel.m:1445-1702`.

### 6.1 Timeline Property Detection

Before generating FCPXML, the system introspects the active timeline to match
its frame rate and resolution. Located at lines 1335-1396.

```objc
- (void)detectTimelineProperties {
    id timelineModule = SpliceKit_getActiveTimelineModule();
    id sequence = objc_msgSend(timelineModule, @selector(sequence));

    // Frame duration — CMTime struct (24 bytes on ARM64)
    // Returns something like {value=100, timescale=2400} for 24fps
    typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } CMTimeStruct;
    CMTimeStruct fd = objc_msgSend(timelineModule, @selector(sequenceFrameDuration));
    self.fdNum = (int)fd.value;       // numerator (e.g., 100)
    self.fdDen = fd.timescale;         // denominator (e.g., 2400)
    self.frameRate = (double)fd.timescale / fd.value;  // e.g., 24.0

    // Resolution — NSSize from sequence
    NSSize size = objc_msgSend(sequence, @selector(renderSize));
    self.videoWidth = (int)size.width;    // e.g., 1920
    self.videoHeight = (int)size.height;  // e.g., 1080
}
```

**Default fallback values** (used when detection fails):
- Frame duration: 100/2400 → 24fps
- Resolution: 1920x1080

**Why this matters:** FCPXML uses rational time (e.g., `3600/2400s`), and positions
are in pixels relative to the video frame center. Wrong values would cause captions
to be misaligned or timed incorrectly.

### 6.2 Rational Time Conversion

FCPXML uses rational fractions for all timing, not floating-point seconds.
The conversion function (line 1398-1403):

```objc
static NSString *SpliceKitCaption_durRational(double seconds, int fdNum, int fdDen) {
    if (seconds <= 0) return @"0s";
    long long frames = (long long)round(seconds * fdDen / fdNum);
    if (frames <= 0) frames = 1;
    return [NSString stringWithFormat:@"%lld/%ds", frames * fdNum, fdDen];
}
```

**Example conversions** at 24fps (fdNum=100, fdDen=2400):

| Seconds | Frames | FCPXML |
|---------|--------|--------|
| 0.042 | 1 | `100/2400s` |
| 0.5 | 12 | `1200/2400s` |
| 1.0 | 24 | `2400/2400s` |
| 1.5 | 36 | `3600/2400s` |
| 3.0 | 72 | `7200/2400s` |

### 6.3 FCPXML Document Structure

The generated FCPXML follows this structure:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>

<fcpxml version="1.11">
    <resources>
        <!-- Video format matching the active timeline -->
        <format id="r1" name="FFVideoFormat1920x1080p24"
                frameDuration="100/2400s" width="1920" height="1080"/>

        <!-- FCP's built-in Basic Title motion template -->
        <effect id="r2" name="Basic Title"
                uid=".../Titles.localized/Bumper:Opener.localized/
                     Basic Title.localized/Basic Title.moti"/>
    </resources>

    <library>
        <event name="Captions">
            <project name="Social Captions">
                <sequence format="r1" duration="72000/2400s"
                          tcStart="0s" tcFormat="NDF"
                          audioLayout="stereo" audioRate="48k">
                    <spine>
                        <!--
                          The gap is the "anchor" for all caption titles.
                          Its duration spans the entire timeline.
                          All <title> elements are placed inside this gap
                          as connected clips on lane 1.
                        -->
                        <gap name="CaptionAnchor" offset="0s"
                             duration="72000/2400s" start="0s">

                            <!-- Title clips here (see sections below) -->

                        </gap>
                    </spine>
                </sequence>
            </project>
        </event>
    </library>
</fcpxml>
```

**Key points:**
- `format id="r1"` matches the active timeline's exact frame rate and resolution
- `effect id="r2"` references FCP's Basic Title, which supports styled `<text>` content
- The entire spine is a single `<gap>` that serves as the anchor
- All titles sit inside the gap with `lane="1"` — this is the "dedicated caption lane"

### 6.4 Word-by-Word Highlight Mode

When `style.wordByWordHighlight == YES && style.highlightColor != nil && segment.words.count > 1`:

**For each segment, one `<title>` is generated per word.** Each title shows the
complete segment text, but only the "active" word is highlighted — the others
use the normal text color.

This creates a **karaoke effect**: as playback progresses through the segment,
successive title clips overlap such that the highlighted word sweeps left to right.

**Code** (lines 1508-1553):

```objc
// Word-by-word mode: one title per word
for (NSUInteger wi = 0; wi < seg.words.count; wi++) {
    SpliceKitTranscriptWord *activeWord = seg.words[wi];
    double wordStart = activeWord.startTime;
    double wordDur = activeWord.duration;

    // Extend last word to segment end to avoid gaps
    if (wi == seg.words.count - 1) {
        wordDur = seg.endTime - wordStart;
    }
    if (wordDur <= 0) wordDur = 0.1;

    // Build mixed text: all words shown, active word highlighted
    NSMutableString *textXML = [NSMutableString string];
    [textXML appendString:@"<text>"];
    for (NSUInteger j = 0; j < seg.words.count; j++) {
        NSString *wordText = seg.words[j].text;
        if (s.allCaps) wordText = [wordText uppercaseString];
        NSString *suffix = (j < seg.words.count - 1) ? @" " : @"";
        // Active word gets highlight ref, others get normal ref
        NSString *ref = (j == wi) ? highlightTSID : normalTSID;
        [textXML appendFormat:@"<text-style ref=\"%@\">%@%@</text-style>",
            ref, escapeXML(wordText), suffix];
    }
    [textXML appendString:@"</text>"];
}
```

**Example output** for segment "THE QUICK BROWN" with word index 1 (QUICK) active:

```xml
<title ref="r2" lane="1" name="Cap001_w2" offset="1200/2400s"
       duration="800/2400s" start="3600s">
    <text>
        <text-style ref="ts1_n">THE </text-style>
        <text-style ref="ts1_h">QUICK </text-style>
        <text-style ref="ts1_n">BROWN</text-style>
    </text>
    <text-style-def id="ts1_n">
        <text-style font="Futura-Bold" fontSize="72" fontColor="1.000 1.000 1.000 1.000"
                    strokeColor="0.000 0.000 0.000 1.000" strokeWidth="3.0"
                    shadowColor="0.000 0.000 0.000 0.800" shadowOffset="0.0 0.0"
                    shadowBlurRadius="4.0" alignment="center"/>
    </text-style-def>
    <text-style-def id="ts1_h">
        <text-style font="Futura-Bold" fontSize="72" fontColor="1.000 0.850 0.000 1.000"
                    bold="1" strokeColor="0.000 0.000 0.000 1.000" strokeWidth="3.0"
                    shadowColor="0.000 0.000 0.000 0.800" shadowOffset="0.0 0.0"
                    shadowBlurRadius="4.0" alignment="center"/>
    </text-style-def>
    <adjust-transform position="0 -346"/>
</title>
```

**How the karaoke effect works visually:**

```
Timeline:  ─────────────────────────────────────────────►

Segment:   THE QUICK BROWN
           ├─word1─┤├─word2──┤├──word3──┤

Title 1:   [THE] QUICK BROWN
           ├─────────┤

Title 2:   THE [QUICK] BROWN
                ├──────────┤

Title 3:   THE QUICK [BROWN]
                      ├───────────┤    (extended to segment end)

Playback:  At any given time, exactly one title is visible,
           and its active word [in brackets] has the highlight color.
```

The last word's title duration is explicitly extended to `seg.endTime - wordStart`
to prevent gaps at the segment boundary (line 1516-1518).

### 6.5 Non-Highlight Mode

When `wordByWordHighlight == NO` or `highlightColor == nil` or the segment has
only one word:

**One `<title>` per segment**, uniform text color.

```objc
// Non-highlight mode: one title per segment
NSString *text = s.allCaps ? [seg.text uppercaseString] : seg.text;
NSString *offStr = SpliceKitCaption_durRational(seg.startTime, fdN, fdD);
NSString *durStr = SpliceKitCaption_durRational(seg.duration, fdN, fdD);

[xml appendFormat:@"<title ref=\"%@\" lane=\"1\" name=\"Cap%03lu\" "
    @"offset=\"%@\" duration=\"%@\" start=\"3600s\">\n",
    titleEffectId, seg.segmentIndex + 1, offStr, durStr];
[xml appendFormat:@"<text><text-style ref=\"%@\">%@</text-style></text>\n",
    tsID, escapeXML(text)];
[xml appendFormat:@"%@\n", tsDef];
[xml appendFormat:@"<adjust-transform position=\"0 %.0f\"/>\n", yOffset];
[xml appendString:@"</title>\n"];
```

### 6.6 Text Style XML Generation

The `textStyleXMLWithID:color:isHighlight:` method (lines 1405-1426) builds the
`<text-style-def>` element that defines font, color, outline, and shadow properties.

```objc
- (NSString *)textStyleXMLWithID:(NSString *)tsID
                           color:(NSColor *)color
                     isHighlight:(BOOL)highlight {
    SpliceKitCaptionStyle *s = self.style;
    NSMutableString *xml = [NSMutableString string];

    [xml appendFormat:@"<text-style-def id=\"%@\"><text-style", tsID];
    [xml appendFormat:@" font=\"%@\"", escapeXML(s.font)];
    [xml appendFormat:@" fontSize=\"%.0f\"", s.fontSize];
    if (s.fontFace)
        [xml appendFormat:@" fontFace=\"%@\"", escapeXML(s.fontFace)];
    [xml appendFormat:@" fontColor=\"%@\"", colorToFCPXML(color)];

    // Highlight words get bold="1" for extra visual weight
    if (highlight)
        [xml appendString:@" bold=\"1\""];

    // Outline (stroke)
    if (s.outlineColor && s.outlineWidth > 0) {
        [xml appendFormat:@" strokeColor=\"%@\"", colorToFCPXML(s.outlineColor)];
        [xml appendFormat:@" strokeWidth=\"%.1f\"", s.outlineWidth];
    }

    // Shadow
    if (s.shadowColor && s.shadowBlurRadius > 0) {
        [xml appendFormat:@" shadowColor=\"%@\"", colorToFCPXML(s.shadowColor)];
        [xml appendFormat:@" shadowOffset=\"%.1f %.1f\"", s.shadowOffsetX, s.shadowOffsetY];
        [xml appendFormat:@" shadowBlurRadius=\"%.1f\"", s.shadowBlurRadius];
    }

    [xml appendString:@" alignment=\"center\""];
    [xml appendString:@"/></text-style-def>"];
    return xml;
}
```

**FCPXML text-style attributes mapping:**

| Style Property | FCPXML Attribute | Example |
|---------------|-----------------|---------|
| font | `font` | `"Futura-Bold"` |
| fontSize | `fontSize` | `"72"` |
| fontFace | `fontFace` | `"Bold"` |
| textColor/highlightColor | `fontColor` | `"1.000 0.850 0.000 1.000"` |
| (highlight only) | `bold` | `"1"` |
| outlineColor | `strokeColor` | `"0.000 0.000 0.000 1.000"` |
| outlineWidth | `strokeWidth` | `"3.0"` |
| shadowColor | `shadowColor` | `"0.000 0.000 0.000 0.800"` |
| shadowOffset | `shadowOffset` | `"0.0 0.0"` |
| shadowBlurRadius | `shadowBlurRadius` | `"4.0"` |
| (always) | `alignment` | `"center"` |

### 6.7 Position Calculation

Captions are vertically positioned using `<adjust-transform position="X Y"/>`
on each title. X is always 0 (horizontally centered). Y is calculated as a
percentage of video height:

```objc
- (CGFloat)yOffsetForPosition {
    switch (self.style.position) {
        case SpliceKitCaptionPositionBottom:
            return -(self.videoHeight * 0.32);   // -345.6 for 1080p
        case SpliceKitCaptionPositionCenter:
            return 0;
        case SpliceKitCaptionPositionTop:
            return (self.videoHeight * 0.32);    // +345.6 for 1080p
        case SpliceKitCaptionPositionCustom:
            return self.style.customYOffset;
    }
    return -(self.videoHeight * 0.32);
}
```

**Position values for common resolutions:**

| Resolution | Bottom Y | Center Y | Top Y |
|-----------|----------|----------|-------|
| 1920x1080 | -345.6 | 0 | +345.6 |
| 3840x2160 (4K) | -691.2 | 0 | +691.2 |
| 1280x720 | -230.4 | 0 | +230.4 |

The coordinate system origin is the center of the frame. Negative Y moves down,
positive Y moves up.

---

## 7. The Dedicated Caption Lane — Lane 1 System

This is the most important architectural concept for reuse. The caption system
uses FCPXML's **lane** attribute to create a connected storyline dedicated to captions.

### 7.1 How FCPXML Lanes Work

In FCPXML, the `<spine>` is the primary storyline — sequential clips on lane 0
(the default). Any item inside a spine element (like `<gap>` or `<clip>`) can
have **connected items** placed on numbered lanes:

```
Lane 2:  ┌──────┐                    ┌──────┐
         │Title │                    │Title │
Lane 1:  │──────│──┌──────┐──────────│──────│──────
         │      │  │Title │          │      │
Lane 0:  ├══════╪══╪══════╪══════════╪══════╪══════  ← Primary storyline
(spine)  │ Gap  │  │ Clip │          │ Clip │
         └──────┘  └──────┘          └──────┘

Lane -1: Connected clips BELOW the primary storyline
```

- **Lane 0** (implicit): Items in the `<spine>` itself
- **Lane 1+**: Connected items ABOVE the primary storyline
- **Lane -1 and below**: Connected items below

Connected items are **magnetically anchored** to their parent spine item. When
the parent moves, all connected items on all lanes move with it.

### 7.2 The Gap Anchor Pattern

The caption system uses a specific pattern: a single gap clip in the spine
serves as the anchor for ALL caption titles.

```xml
<spine>
    <gap name="CaptionAnchor" offset="0s" duration="72000/2400s" start="0s">
        <!-- ALL title clips are children of this gap -->
        <title lane="1" offset="..."  duration="..." />
        <title lane="1" offset="..."  duration="..." />
        <title lane="1" offset="..."  duration="..." />
        <!-- ... hundreds of titles ... -->
    </gap>
</spine>
```

**Why a gap?** The `<gap>` is a transparent, silent placeholder that FCP treats
as empty timeline space. By making it span the entire timeline duration, it
provides a single anchor point for all connected caption titles. This is simpler
and more reliable than anchoring titles to individual video clips (which would
require finding the right parent clip for each caption's time range).

**Why not anchor to video clips?** If captions were anchored to individual video
clips, they would need to be distributed across multiple parent clips. If the
editor later reorders clips, the captions would move with them — which might or
might not be desired. The gap anchor pattern keeps all captions independent of
the video edit.

### 7.3 Title Clips as Connected Items

Each `<title>` element represents a single caption display moment:

```xml
<title ref="r2"         ← references the Basic Title effect (resource r2)
       lane="1"         ← places this on lane 1 (above primary storyline)
       name="Cap001_w2" ← human-readable name (segment 1, word 2)
       offset="1200/2400s"   ← timeline position (0.5 seconds)
       duration="800/2400s"  ← how long it's visible (0.33 seconds)
       start="3600s">        ← internal start (always 3600s for Basic Title)

    <text>
        <text-style ref="ts1_n">THE </text-style>
        <text-style ref="ts1_h">QUICK </text-style>   ← highlighted word
        <text-style ref="ts1_n">BROWN</text-style>
    </text>

    <text-style-def id="ts1_n">...</text-style-def>   ← normal color
    <text-style-def id="ts1_h">...</text-style-def>   ← highlight color

    <adjust-transform position="0 -346"/>              ← Y position
</title>
```

**The `start="3600s"` attribute:** This is not the timeline position — that's
`offset`. The `start` attribute is the internal media start time for the Basic
Title generator. FCP's Basic Title always uses `3600s` (1 hour) as its internal
origin. This is hardcoded and must be exactly this value.

### 7.4 Why Lane 1 Specifically

Lane 1 is the first lane above the primary storyline. This means:

1. **Captions render on top of video** — they composite above all lane 0 content
2. **They don't interfere with the primary edit** — moving or deleting primary
   clips doesn't break captions (they're anchored to the gap, not to clips)
3. **Lane 1 is visible in FCP's timeline** — users can see, select, and
   manually adjust caption clips just like any other connected clip
4. **Multiple caption systems can coexist** — a second system could use lane 2,
   and both would render independently

If a different system needs to place items BELOW the video (e.g., a background
graphic), it would use lane -1 instead.

---

## 8. Import Mechanism — NSOpenPanel Swizzling

The caption FCPXML is generated but **not directly imported via pasteboard**.
Instead, the system uses a clever SRT-based import strategy with method swizzling
to automate the user interaction.

### Why SRT instead of FCPXML?

FCP's `importCaptions:` responder action expects an SRT file selected via
NSOpenPanel. There is no direct ObjC API to programmatically import captions.
Rather than reverse-engineering FCP's internal import pipeline, SpliceKit
generates an SRT file and tricks FCP into thinking the user selected it.

### The Swizzling Strategy

**Three methods are swizzled** on `NSOpenPanel` (lines 1598-1679):

```objc
// Static variable holds the URL we want FCP to "select"
static NSURL *sAutoSelectURL = nil;
sAutoSelectURL = [NSURL fileURLWithPath:srtPath];

// 1. Swizzle -[NSOpenPanel URLs] → return our SRT file
Method urlsM = class_getInstanceMethod([NSOpenPanel class], @selector(URLs));
sOrigURLs = method_getImplementation(urlsM);
IMP newURLs = imp_implementationWithBlock(^NSArray *(NSOpenPanel *panel) {
    if (sAutoSelectURL) return @[sAutoSelectURL];
    return ((NSArray *(*)(id, SEL))sOrigURLs)(panel, @selector(URLs));
});
method_setImplementation(urlsM, newURLs);

// 2. Swizzle -[NSOpenPanel URL] → return our SRT file
Method urlM = class_getInstanceMethod([NSOpenPanel class], @selector(URL));
IMP origURL = method_getImplementation(urlM);
IMP newURL = imp_implementationWithBlock(^NSURL *(NSOpenPanel *panel) {
    if (sAutoSelectURL) return sAutoSelectURL;
    return ((NSURL *(*)(id, SEL))origURL)(panel, @selector(URL));
});
method_setImplementation(urlM, newURL);

// 3. Swizzle -[NSOpenPanel runModal] → return OK without showing dialog
Method m = class_getInstanceMethod([NSOpenPanel class], @selector(runModal));
sOrigRunModal2 = method_getImplementation(m);
IMP newImpl = imp_implementationWithBlock(^NSModalResponse(NSOpenPanel *panel) {
    if (sAutoSelectURL) return NSModalResponseOK;
    return ((NSModalResponse (*)(id, SEL))sOrigRunModal2)(panel, @selector(runModal));
});
method_setImplementation(m, newImpl);
```

### Triggering the Import

After swizzling, the import is triggered via the responder chain:

```objc
SEL importSel = NSSelectorFromString(@"importCaptions:");
id app = [NSApplication sharedApplication];
BOOL sent = objc_msgSend(app, @selector(sendAction:to:from:),
                          importSel, nil, nil);
```

This calls FCP's built-in "File > Import > Captions..." handler, which:
1. Creates an NSOpenPanel to ask the user to select a file
2. Our swizzled `runModal` returns `NSModalResponseOK` immediately (no dialog shown)
3. FCP reads the file URLs from the panel — our swizzled `URLs` returns the SRT
4. FCP processes the SRT and adds captions to the timeline

### Cleanup

The `sAutoSelectURL` is cleared after a 1-second delay to restore normal
NSOpenPanel behavior:

```objc
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
               dispatch_get_main_queue(), ^{
    sAutoSelectURL = nil;
});
```

The method implementations remain swizzled permanently, but they fall through
to the original implementations when `sAutoSelectURL` is nil — so normal
NSOpenPanel usage is unaffected.

---

## 9. Style Preset System

12 built-in presets are defined as static objects in `SpliceKitCaptionPanel.m:217-408`.
They're created once via `dispatch_once` and cached.

| # | ID | Name | Font | Size | Text Color | Highlight Color | Outline | Shadow | Position | Animation |
|---|-----|------|------|------|-----------|----------------|---------|--------|----------|-----------|
| 1 | `bold_pop` | Bold Pop | Futura-Bold | 72 | White | Yellow (1 .85 0) | Black 3px | Black 4px blur | Bottom | Pop 0.2s |
| 2 | `neon_glow` | Neon Glow | Avenir-Heavy | 68 | Cyan (0 1 1) | Magenta (1 0 1) | None | Blue 15px blur | Bottom | Fade 0.25s |
| 3 | `clean_minimal` | Clean Minimal | HelveticaNeue-Bold | 60 | White | Light Blue (.4 .7 1) | None | Black 3px blur | Bottom | Fade 0.2s |
| 4 | `handwritten` | Handwritten | Bradley Hand | 64 | Cream (.95 .95 .9) | Orange (1 .6 .2) | None | Brown 4px blur | Bottom | None |
| 5 | `gradient_fire` | Gradient Fire | HelveticaNeue-Bold | 70 | Orange (1 .6 .1) | Red (1 .2 .1) | Black 2px | Orange 6px blur | Bottom | Pop 0.2s |
| 6 | `outline_bold` | Outline Bold | Impact | 76 | White | Yellow (1 1 0) | Black 4px | None | Bottom | None |
| 7 | `shadow_deep` | Shadow Deep | Futura-Bold | 68 | White | Green (.2 1 .4) | None | Black 8px blur, offset 4,4 | Bottom | Fade 0.25s |
| 8 | `karaoke` | Karaoke | GillSans-Bold | 66 | Gray (.5 .5 .5) | White | Black 2px | Black 4px blur | Center | None |
| 9 | `typewriter` | Typewriter | Courier-Bold | 54 | Green (.2 1 .2) | White | None | None | Bottom | Typewriter |
| 10 | `bounce_fun` | Bounce Fun | AvenirNext-Heavy | 72 | White | Magenta (1 .4 .7) | Black 2px | None | Bottom | Bounce 0.3s |
| 11 | `subtitle_pro` | Subtitle Pro | HelveticaNeue-Medium | 48 | White | None (no highlight) | Black 1.5px | Black 2px blur | Bottom | Fade 0.15s |
| 12 | `social_bold` | Social Bold | HelveticaNeue-Bold | 80 | White | Yellow (1 .9 0) | Black 3px | Black 5px blur | Center | Pop 0.2s |

**Preset loading:**

```objc
+ (instancetype)presetWithID:(NSString *)presetID {
    for (SpliceKitCaptionStyle *s in [self builtInPresets]) {
        if ([s.presetID isEqualToString:presetID]) return [s copy];
    }
    return nil;  // nil = unknown preset
}
```

**Style merging** (used by `handleCaptionsSetStyle` and `handleCaptionsGenerate`):
Presets can be used as a base with individual parameter overrides:

```objc
SpliceKitCaptionStyle *style = [SpliceKitCaptionStyle presetWithID:@"bold_pop"];
NSMutableDictionary *merged = [[style toDictionary] mutableCopy];
for (NSString *key in params) {
    merged[key] = params[key];  // override individual properties
}
style = [SpliceKitCaptionStyle fromDictionary:merged];
```

---

## 10. UI Architecture — The Floating Panel

The caption panel is an `NSPanel` (utility floating window) injected into FCP's
process. Defined in lines 522-926.

**Window properties:**

```objc
NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(100, 150, 480, 680)
                                            styleMask:NSWindowStyleMaskTitled |
                                                      NSWindowStyleMaskClosable |
                                                      NSWindowStyleMaskResizable |
                                                      NSWindowStyleMaskUtilityWindow
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
panel.title = @"Social Captions";
panel.floatingPanel = YES;              // always on top of FCP
panel.becomesKeyOnlyIfNeeded = NO;      // can receive keyboard input
panel.hidesOnDeactivate = NO;           // stays visible when FCP loses focus
panel.level = NSFloatingWindowLevel;    // floating above normal windows
panel.minSize = NSMakeSize(400, 500);
panel.releasedWhenClosed = NO;          // singleton reuse
panel.appearance = NSAppearanceNameDarkAqua;  // dark mode to match FCP
```

**UI layout (top to bottom):**

```
┌─────────────────────────────────────────────┐
│ Social Captions                        [×]  │
├─────────────────────────────────────────────┤
│ Style    [Bold Pop        ▼]                │
├─────────────────────────────────────────────┤
│ ┌─────────────────────────────────────────┐ │
│ │                                         │ │
│ │     The QUICK brown fox                 │ │  ← Live preview (140px)
│ │                                         │ │
│ └─────────────────────────────────────────┘ │
├─────────────────────────────────────────────┤
│ Font     [Futura                   ▼]       │
│ Size     [────────●────────] [72]           │
│ Colors   [■]Text [■]Highlight [■]Outline    │
│          [■]Shadow                          │
│ Outline W [────●───────────]                │
│ Shadow Bl [───────●────────]                │
│ Position [Bottom         ▼]                 │
│ Animation [Pop           ▼]                 │
│ ☑ ALL CAPS   ☑ Word-by-word highlight       │
├╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤
│ Grouping [By Words ▼] [5] max per group     │
├╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤
│ [Transcribe] [Generate Captions] [SRT][TXT] │
├─────────────────────────────────────────────┤
│ ○ Ready — 245 words, 49 segments            │  ← Status bar (fixed)
└─────────────────────────────────────────────┘
```

**Live preview** (lines 1015-1061): The preview area renders attributed text
with the current style applied, showing "The QUICK brown fox" with the second
word highlighted. It updates in real-time as style properties change.

**UI actions** (lines 1064-1098): Each control has a simple action method that
updates the style model and refreshes the preview:

```objc
- (void)presetChanged:(id)sender {
    NSArray *presets = [SpliceKitCaptionStyle builtInPresets];
    self.style = [presets[self.presetPopup.indexOfSelectedItem] copy];
    [self syncUIFromStyle];
}

- (void)fontChanged:(id)sender {
    self.style.font = self.fontPopup.titleOfSelectedItem;
    [self updatePreview];
}

- (void)colorChanged:(id)sender {
    self.style.textColor = self.textColorWell.color;
    self.style.highlightColor = self.highlightColorWell.color;
    // ... etc
    [self updatePreview];
}
```

---

## 11. RPC Server Integration

The `captions.*` namespace is dispatched in `SpliceKitServer.m` at lines 15594-15614:

```objc
else if ([method isEqualToString:@"captions.open"])
    result = SpliceKit_handleCaptionsOpen(params);
else if ([method isEqualToString:@"captions.close"])
    result = SpliceKit_handleCaptionsClose(params);
else if ([method isEqualToString:@"captions.getState"])
    result = SpliceKit_handleCaptionsGetState(params);
else if ([method isEqualToString:@"captions.getStyles"])
    result = SpliceKit_handleCaptionsGetStyles(params);
else if ([method isEqualToString:@"captions.setStyle"])
    result = SpliceKit_handleCaptionsSetStyle(params);
else if ([method isEqualToString:@"captions.setGrouping"])
    result = SpliceKit_handleCaptionsSetGrouping(params);
else if ([method isEqualToString:@"captions.generate"])
    result = SpliceKit_handleCaptionsGenerate(params);
else if ([method isEqualToString:@"captions.exportSRT"])
    result = SpliceKit_handleCaptionsExportSRT(params);
else if ([method isEqualToString:@"captions.exportTXT"])
    result = SpliceKit_handleCaptionsExportTXT(params);
else if ([method isEqualToString:@"captions.setWords"])
    result = SpliceKit_handleCaptionsSetWords(params);
```

### Handler details

**`captions.open`** (line 4114-4131): Opens the panel on the main thread (with
a 0.5s delay for FCP UI readiness), applies an optional preset, and starts
transcription if no words are loaded yet.

**`captions.generate`** (lines 4190-4222): The most complex handler. Supports
"one-shot" usage where style + grouping + generation happen in a single call:

```objc
static NSDictionary *SpliceKit_handleCaptionsGenerate(NSDictionary *params) {
    SpliceKitCaptionPanel *panel = [SpliceKitCaptionPanel sharedPanel];

    // One-shot: apply style if provided
    if (params[@"style"] || params[@"presetID"]) {
        NSString *pid = params[@"style"] ?: params[@"presetID"];
        SpliceKitCaptionStyle *style = [SpliceKitCaptionStyle presetWithID:pid];
        if (style) {
            // Merge overrides via serialization round-trip
            NSMutableDictionary *merged = [[style toDictionary] mutableCopy];
            for (NSString *key in params) {
                if (![key isEqualToString:@"style"] && ...) {
                    merged[key] = params[key];
                }
            }
            style = [SpliceKitCaptionStyle fromDictionary:merged];
            [panel setStyle:style];
        }
    }
    if (params[@"maxWords"]) {
        panel.maxWordsPerSegment = [params[@"maxWords"] unsignedIntegerValue];
        [panel regroupSegments];
    }

    // Run on background thread to avoid blocking RPC response
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *genResult = [panel generateCaptions];
    });

    return @{@"status": @"ok", @"message": @"Caption generation started..."};
}
```

**`captions.setStyle`** (lines 4153-4172): Supports preset-as-base with parameter
overrides — the dictionary merge pattern.

**`captions.setWords`** (lines 4236-4242): Direct word injection from external sources:

```objc
static NSDictionary *SpliceKit_handleCaptionsSetWords(NSDictionary *params) {
    NSArray *wordDicts = params[@"words"];
    if (!wordDicts || ![wordDicts isKindOfClass:[NSArray class]])
        return @{@"error": @"words array required"};
    [[SpliceKitCaptionPanel sharedPanel] setWordsManually:wordDicts];
    return @{@"status": @"ok", @"wordCount": @(wordDicts.count)};
}
```

---

## 12. MCP Tool Definitions

The MCP tools in `mcp/server.py` (lines 3362-3625) provide the external API.
Each tool maps to a `captions.*` JSON-RPC call.

| MCP Tool | RPC Method | Purpose |
|----------|-----------|---------|
| `open_captions(file_url, style)` | `captions.open` | Open panel, start transcription |
| `close_captions()` | `captions.close` | Close the panel |
| `get_caption_state()` | `captions.getState` | Status, words, segments, style |
| `get_caption_styles()` | `captions.getStyles` | List all 12 presets |
| `set_caption_style(preset_id, font, ...)` | `captions.setStyle` | Configure style |
| `set_caption_grouping(mode, max_words, ...)` | `captions.setGrouping` | Configure segmentation |
| `generate_captions(style, position, ...)` | `captions.generate` | Generate + import |
| `export_captions_srt(path)` | `captions.exportSRT` | Export SRT file |
| `export_captions_txt(path)` | `captions.exportTXT` | Export plain text |
| `set_caption_words(words)` | `captions.setWords` | Inject external words |

### Example MCP usage flow

```python
# 1. Open panel and transcribe
open_captions(style="bold_pop")

# 2. Wait for transcription
get_caption_state()  # poll until status="ready"

# 3. Adjust style
set_caption_style(preset_id="neon_glow", font_size=80, position="center")

# 4. Adjust grouping
set_caption_grouping(mode="words", max_words=3)

# 5. Generate and import
generate_captions()

# 6. Export
export_captions_srt(path="/tmp/my_captions.srt")
```

### One-shot usage

```python
# Set words manually (bypass transcription)
set_caption_words(words='[
    {"text": "Hello", "startTime": 0.0, "duration": 0.5},
    {"text": "world", "startTime": 0.6, "duration": 0.4}
]')

# Generate in one call with all parameters
generate_captions(style="social_bold", position="center",
                  word_highlight=True, max_words=4, all_caps=True)
```

---

## 13. Export Formats

### SRT Export (lines 1706-1731)

Standard SubRip subtitle format:

```
1
00:00:01,500 --> 00:00:02,800
THE QUICK BROWN

2
00:00:02,900 --> 00:00:04,100
FOX JUMPS OVER

3
00:00:04,200 --> 00:00:05,500
THE LAZY DOG
```

**Timestamp format:** `HH:MM:SS,mmm` (hours, minutes, seconds, milliseconds)

```objc
- (NSString *)srtTimestamp:(double)seconds {
    int h = (int)(seconds / 3600);
    int m = (int)(fmod(seconds, 3600) / 60);
    int s = (int)fmod(seconds, 60);
    int ms = (int)((seconds - floor(seconds)) * 1000);
    return [NSString stringWithFormat:@"%02d:%02d:%02d,%03d", h, m, s, ms];
}
```

Empty segments (whitespace-only text after trimming) are skipped.

### TXT Export (lines 1733-1751)

One line per segment, no timecodes:

```
THE QUICK BROWN
FOX JUMPS OVER
THE LAZY DOG
```

Both formats respect the `allCaps` style setting.

---

## 14. Reusing This System for Another Caption Engine

The caption system is designed with clear separation of concerns. Here's how
another caption system could reuse different parts.

### 14.1 Integration Points

```
┌───────────────────────────────────────────────────────┐
│                    YOUR SYSTEM                         │
│                                                       │
│  ┌─────────────┐    ┌──────────────┐    ┌──────────┐ │
│  │ Your        │───>│ Word Array   │───>│ FCPXML   │ │
│  │ Transcriber │    │ Interface    │    │ Generator│ │
│  │ (Whisper,   │    │              │    │          │ │
│  │  Rev.ai,    │    │ [text,       │    │ Reusable │ │
│  │  Deepgram)  │    │  startTime,  │    │ as-is    │ │
│  │             │    │  duration]   │    │          │ │
│  └─────────────┘    └──────────────┘    └──────────┘ │
│         ↓                   ↓                  ↓     │
│    REPLACEABLE        INTEGRATION          REUSABLE   │
│                         POINT                         │
└───────────────────────────────────────────────────────┘
```

### 14.2 Minimal Implementation: Injecting Words

The simplest way to use the caption system with a different transcription
engine is via `set_caption_words`:

```python
import json, subprocess

# 1. Run your own transcription engine
result = your_whisper_transcribe("/path/to/audio.wav")

# 2. Format as word array
words = []
for word in result.words:
    words.append({
        "text": word.text,
        "startTime": word.start_time,  # seconds (float)
        "duration": word.end_time - word.start_time
    })

# 3. Inject into SpliceKit's caption system
set_caption_words(words=json.dumps(words))

# 4. Generate captions using existing style system
generate_captions(style="bold_pop")
```

**What you provide:** Just an array of `{text, startTime, duration}` dictionaries.

**What you get:** Full FCPXML generation, styling, segmentation, lane placement,
and FCP import — all handled by the existing system.

### 14.3 Custom Style: Extending the Preset System

To add new presets, modify `builtInPresets` in `SpliceKitCaptionPanel.m`:

```objc
// 13. Your Custom Style
{
    SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
    s.presetID = @"my_custom_style";
    s.name = @"My Custom Style";
    s.font = @"SF Pro Display";
    s.fontSize = 64;
    s.fontFace = @"Bold";
    s.textColor = [NSColor colorWithRed:0.9 green:0.9 blue:0.9 alpha:1];
    s.highlightColor = [NSColor colorWithRed:0 green:0.8 blue:0.4 alpha:1];
    s.outlineColor = nil;
    s.outlineWidth = 0;
    s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.6];
    s.shadowBlurRadius = 6;
    s.position = SpliceKitCaptionPositionBottom;
    s.animation = SpliceKitCaptionAnimationFade;
    s.animationDuration = 0.15;
    s.allCaps = NO;
    s.wordByWordHighlight = YES;
    [list addObject:s];
}
```

Or use `set_caption_style` with custom parameters at runtime (no code change):

```python
set_caption_style(
    font="SF Pro Display",
    font_size=64,
    text_color="0.9 0.9 0.9 1",
    highlight_color="0 0.8 0.4 1",
    outline_width=0,
    position="bottom",
    animation="fade",
    word_highlight=True,
    all_caps=False
)
```

### 14.4 Alternative Import Strategies

The current system uses NSOpenPanel swizzling + SRT import. Alternative
strategies that could be implemented:

#### A. Pasteboard FCPXML Import

SpliceKit already has a pasteboard import handler in `SpliceKitServer.m`
(the `SpliceKit_handlePasteboardImportXML` function referenced at line 32).
Instead of the SRT swizzle, you could import the FCPXML directly:

```objc
// Write FCPXML to pasteboard with FCP's custom type
NSPasteboard *pb = [NSPasteboard generalPasteboard];
[pb declareTypes:@[@"IXXMLPasteboardType"] owner:nil];
[pb setString:fcpxmlString forType:@"IXXMLPasteboardType"];

// Trigger paste
SEL pasteSel = NSSelectorFromString(@"paste:");
[NSApp sendAction:pasteSel to:nil from:nil];
```

This would import the FCPXML titles directly into the current timeline position,
preserving all styling information (which the SRT import loses).

#### B. Direct FFAnchoredCaption Creation

For native FCP captions (not styled titles), you could create `FFAnchoredCaption`
objects directly:

```objc
// Find the class
Class captionClass = NSClassFromString(@"FFAnchoredCaption");
// Create and configure...
```

This would use FCP's built-in caption system but loses the rich styling.

#### C. File-Based FCPXML Import

```objc
// Write FCPXML to file, then import via File > Import > XML
[fcpxml writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
NSURL *url = [NSURL fileURLWithPath:path];

// Use FCP's XML import action
SEL importSel = NSSelectorFromString(@"importXML:");
// ... swizzle and trigger
```

### 14.5 Building a New Panel That Reuses the FCPXML Generator

To build a completely new caption UI that reuses the generation engine:

```objc
@interface MyCaptionSystem : NSObject

- (void)generateFromWords:(NSArray<NSDictionary *> *)wordDicts
                 withStyle:(SpliceKitCaptionStyle *)style {

    // 1. Inject words into the shared caption panel
    SpliceKitCaptionPanel *panel = [SpliceKitCaptionPanel sharedPanel];
    [panel setWordsManually:wordDicts];

    // 2. Set your style
    [panel setStyle:style];

    // 3. Configure segmentation
    panel.groupingMode = SpliceKitCaptionGroupingByWordCount;
    panel.maxWordsPerSegment = 4;
    [panel regroupSegments];

    // 4. Generate — this builds FCPXML and imports to timeline
    NSDictionary *result = [panel generateCaptions];
    // result contains titleCount, segmentCount, fcpxmlPath, srtPath
}

@end
```

### 14.6 Using the Lane System for Non-Caption Overlays

The lane 1 pattern can be adapted for any connected storyline content:

**Lower thirds:**

```xml
<title ref="r2" lane="1" name="LowerThird_001"
       offset="2400/2400s" duration="12000/2400s" start="3600s">
    <text>
        <text-style ref="ts1">JOHN SMITH</text-style>
        <text-style ref="ts2">Senior Engineer</text-style>
    </text>
    <adjust-transform position="0 -400"/>
</title>
```

**Watermarks (use a different lane to avoid conflicts):**

```xml
<title ref="r2" lane="2" name="Watermark"
       offset="0s" duration="72000/2400s" start="3600s">
    <text>
        <text-style ref="ts1">DRAFT</text-style>
    </text>
    <adjust-transform position="500 400"/>  <!-- top-right corner -->
</title>
```

**Progress indicators, chapter titles, score overlays** — anything that
needs to be time-positioned above the primary video can use the same
gap-anchor + lane N + title element pattern.

---

## 15. Thread Safety & Concurrency

The caption system uses several threading strategies:

**Mutable arrays** (`mutableWords`, `mutableSegments`): Protected by
`@synchronized(self.mutableWords)` when reading or writing.

**UI updates**: Always dispatched to main thread via `dispatch_async(dispatch_get_main_queue(), ...)`.

**FCPXML generation** (`generateCaptions`): Called from a background thread
(QOS_CLASS_USER_INITIATED) by the RPC handler. The method itself is thread-safe
because it copies the word/segment arrays and style before building XML.

**NSOpenPanel swizzling**: Must happen on the main thread. The `generateCaptions`
method uses `dispatch_sync(dispatch_get_main_queue(), ...)` for this critical section.

**Timeline property detection**: Uses `objc_msgSend` to call FCP's ObjC methods.
These must be called from any thread but the returned values are copied to
instance variables immediately.

---

## 16. Color Conversion Utilities

Two helper functions handle conversion between NSColor and FCPXML's
`"R G B A"` space-separated float format:

```objc
// NSColor → FCPXML string (e.g., "1.000 0.850 0.000 1.000")
static NSString *SpliceKitCaption_colorToFCPXML(NSColor *color) {
    if (!color) return @"1 1 1 1";
    NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!rgb) rgb = color;
    return [NSString stringWithFormat:@"%.3f %.3f %.3f %.3f",
            rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent];
}

// FCPXML string → NSColor
static NSColor *SpliceKitCaption_colorFromString(NSString *str) {
    if (!str || str.length == 0) return [NSColor whiteColor];
    NSArray *parts = [str componentsSeparatedByString:@" "];
    if (parts.count < 3) return [NSColor whiteColor];
    CGFloat r = [parts[0] doubleValue];
    CGFloat g = [parts[1] doubleValue];
    CGFloat b = [parts[2] doubleValue];
    CGFloat a = parts.count >= 4 ? [parts[3] doubleValue] : 1.0;
    return [NSColor colorWithRed:r green:g blue:b alpha:a];
}
```

**Important:** Colors are converted to sRGB color space before extraction. This
ensures consistent results regardless of the user's display profile or the
NSColor's original color space.

An XML escaping function handles special characters in text content:

```objc
static NSString *SpliceKitCaption_escapeXML(NSString *str) {
    if (!str) return @"";
    NSMutableString *s = [str mutableCopy];
    [s replaceOccurrencesOfString:@"&" withString:@"&amp;" ...];
    [s replaceOccurrencesOfString:@"<" withString:@"&lt;" ...];
    [s replaceOccurrencesOfString:@">" withString:@"&gt;" ...];
    [s replaceOccurrencesOfString:@"\"" withString:@"&quot;" ...];
    [s replaceOccurrencesOfString:@"'" withString:@"&apos;" ...];
    return s;
}
```

---

## 17. File Manifest

| File | Lines | Content |
|------|-------|---------|
| `Sources/SpliceKitCaptionPanel.h` | 155 | Interface, enums, SpliceKitCaptionStyle, SpliceKitCaptionSegment, SpliceKitCaptionPanel |
| `Sources/SpliceKitCaptionPanel.m` | 1798 | Full implementation: UI, style presets, segmentation, FCPXML generation, import, export |
| `Sources/SpliceKitTranscriptPanel.h` | 102 | SpliceKitTranscriptWord model, engine enum, panel interface |
| `Sources/SpliceKitTranscriptPanel.m` | ~4000 | Transcription engines, word extraction, silence detection |
| `Sources/SpliceKitServer.m:4107-4242` | 136 | RPC handlers for `captions.*` namespace |
| `Sources/SpliceKitServer.m:15594-15614` | 21 | RPC dispatch table for `captions.*` |
| `mcp/server.py:3362-3625` | 264 | MCP tool definitions for external API |

### Line-level index of key functions in SpliceKitCaptionPanel.m

| Lines | Function |
|-------|----------|
| 37-43 | `SpliceKitCaption_colorToFCPXML()` — NSColor → FCPXML string |
| 45-54 | `SpliceKitCaption_colorFromString()` — FCPXML string → NSColor |
| 56-65 | `SpliceKitCaption_escapeXML()` — XML entity escaping |
| 69-97 | `SpliceKitCaptionStyle -init` — default style values |
| 217-408 | `+builtInPresets` — all 12 style presets |
| 411-416 | `+presetWithID:` — preset lookup |
| 422-445 | `SpliceKitCaptionSegment -toDictionary` |
| 491-518 | `SpliceKitCaptionPanel -init` — defaults (24fps, 1920x1080) |
| 522-547 | `-setupPanelIfNeeded` — NSPanel creation |
| 549-926 | `-buildUI:` — complete UI layout |
| 969-1013 | `-syncUIFromStyle` — UI ← style model sync |
| 1015-1061 | `-updatePreview` — live preview rendering |
| 1170-1196 | `-transcribeTimeline` — delegate to transcript panel |
| 1204-1224 | `-importWordsFromTranscriptPanel` — word transfer |
| 1226-1243 | `-setWordsManually:` — external word injection |
| 1247-1313 | `-regroupSegments` — segmentation algorithm |
| 1335-1396 | `-detectTimelineProperties` — frame rate + resolution |
| 1398-1403 | `SpliceKitCaption_durRational()` — seconds → rational time |
| 1405-1426 | `-textStyleXMLWithID:color:isHighlight:` — text-style-def |
| 1428-1436 | `-yOffsetForPosition` — vertical position calculation |
| 1445-1702 | **`-generateCaptions`** — THE CORE: FCPXML build + import |
| 1706-1731 | `-exportSRT:` — SRT subtitle export |
| 1733-1751 | `-exportTXT:` — plain text export |
| 1753-1759 | `-srtTimestamp:` — seconds → HH:MM:SS,mmm |
| 1763-1796 | `-getState` — current panel state as dictionary |

---
---

# Part II: Plan — Social-Media-Quality Word-by-Word Captions

## 18. Problem Statement & Current Gaps

The current caption system generates word-by-word highlighted FCPXML titles and
imports them into FCP's timeline. This is functional but falls short of what
creators expect from TikTok, YouTube Shorts, and Instagram Reels-style captions.

### What social media captions look like today

The visual language of social media captions has converged on a specific set of
conventions across platforms. Creators and audiences expect:

```
┌─────────────────────────────────┐
│                                 │
│                                 │
│                                 │
│          ┌───────────────┐      │
│          │  I LITERALLY  │      │  ← 2-3 words per line
│          │  [CANNOT]     │      │  ← active word highlighted
│          │  BELIEVE IT   │      │  ← stacked lines, centered
│          └───────────────┘      │
│               ▲                 │
│          background box         │
│          with rounded corners   │
│                                 │
└─────────────────────────────────┘
```

Key characteristics:
1. **Short segments** — 2-3 words per display group, NOT 5
2. **Stacked multi-line** — words wrap to 2-3 lines, max ~15 chars wide
3. **Active word highlight** — color change + often a scale bump on the active word
4. **Background box** — semi-transparent rounded rectangle behind text
5. **Entrance/exit animations** — pop-in on segment start, fade out on segment end
6. **Center-screen position** — slightly below center, not at the very bottom
7. **Very large fonts** — 80-120pt, designed to be readable on phones
8. **Heavy outlines** — 3-5px black stroke for contrast on any background
9. **ALL CAPS** — almost universally uppercase for impact
10. **Tight timing** — captions appear at the exact moment each word is spoken

### Current system gaps

| Feature | Current State | Target |
|---------|--------------|--------|
| Words per segment | 5 (too many) | 2-3 |
| Animations | Stubbed out (returns `""`) | Pop, fade, bounce, slide |
| Background box | Property exists, not in FCPXML | Rounded rect behind text |
| Multi-line layout | Single line, auto-wrap by FCP | Intentional 2-3 line stacking |
| Import path | SRT swizzle (loses styling) | Pasteboard FCPXML (preserves all) |
| Active word scale | Same size as others | Scale bump on highlight word |
| Segment transitions | Hard cut between segments | Fade-out old, pop-in new |
| Font size for social | 60-80pt | 80-120pt |
| Emphasis detection | None | Auto-detect key words for extra styling |

---

## 19. Technical Constraints in FCPXML 1.11

Before planning, here are the hard constraints the implementation must work within.

### What FCPXML 1.11 CAN do with titles

| Capability | How |
|-----------|-----|
| Static position | `<adjust-transform position="X Y"/>` |
| Static scale | `<adjust-transform scale="1.2 1.2"/>` |
| Static rotation | `<adjust-transform rotation="15"/>` |
| Static opacity | `<adjust-blend amount="0.8"/>` |
| Rich text styling | `<text-style font="..." fontColor="..." strokeColor="..." shadowColor="..."/>` |
| Per-word color changes | Multiple `<text-style ref="tsX">` within one `<text>` element |
| Bold flag per word | `bold="1"` on highlight text-style-def |
| Lane placement | `lane="1"` on each `<title>` |
| Precise timing | Rational time `frames*fdNum/fdDen` |

### What FCPXML 1.11 CANNOT do with titles

| Limitation | Impact | Workaround |
|-----------|--------|------------|
| No keyframed position/scale/rotation on `<adjust-transform>` | Can't animate entrance/exit with position or scale ramps | Use overlapping title clips at different scales/opacities |
| No keyframed opacity on `<adjust-blend>` | Can't fade in/out smoothly | Use overlapping title clips with different static opacity values |
| No per-character transforms | Can't scale individual words differently | Use separate `<title>` clips per word with different `<adjust-transform scale="..."/>` |
| No background rectangles | Can't draw a box behind text | Use a separate title clip on the same lane with a block character (e.g., `█████`) or use a Generator |
| No Motion template params via FCPXML | Can't control Motion's built-in text animations | Use Basic Title only, simulate everything with clip layering |
| No `\n` line breaks in text | Can't force line wrapping | FCP auto-wraps based on text width; control via short segment text + large font |

### The fundamental workaround pattern

Every animation must be simulated by generating **multiple overlapping title clips**
with different static properties. Instead of one title that animates from 0%→100%
opacity, we generate two clips:

```
Clip A: opacity=0.0, duration=0 (instant, just a placeholder)
Clip B: opacity=1.0, starts at word time, full duration
```

For more granular fades, we generate intermediate steps:

```
Clip 1: opacity=0.3, duration=2 frames
Clip 2: opacity=0.6, duration=2 frames
Clip 3: opacity=1.0, duration=rest of word
```

This is analogous to how the current word-by-word highlight works — it's already
generating one title per word to simulate the color sweep animation.

---

## 20. Implementation Plan

### Phase 1: Social Media Defaults & Pasteboard Import

**Goal:** Fix the defaults so captions look right for social media out of the box,
and switch to the superior pasteboard FCPXML import path.

#### 1a. Social media segment defaults

Change the defaults that matter most for social media look:

**File: `SpliceKitCaptionPanel.m` — `-init` (line 502-518)**

```objc
// Current defaults:
_maxWordsPerSegment = 5;     // → change to 3
_maxCharsPerSegment = 40;    // → change to 20

// Current default style is bold_pop which is already good, but:
// - fontSize should be 80+ for social
// - position should be center (not bottom) for Reels/TikTok
```

**File: `SpliceKitCaptionPanel.m` — `builtInPresets` (lines 217-408)**

Add a new preset optimized for social media short-form content:

```objc
// 13. Social Reels — optimized for 9:16 vertical video
{
    SpliceKitCaptionStyle *s = [[SpliceKitCaptionStyle alloc] init];
    s.presetID = @"social_reels";
    s.name = @"Social Reels";
    s.font = @"HelveticaNeue-Bold";
    s.fontSize = 100;  // very large for phone screens
    s.fontFace = @"Bold";
    s.textColor = [NSColor whiteColor];
    s.highlightColor = [NSColor colorWithRed:1 green:0.9 blue:0 alpha:1];
    s.outlineColor = [NSColor blackColor];
    s.outlineWidth = 4.0;  // heavy outline for contrast
    s.shadowColor = [NSColor colorWithRed:0 green:0 blue:0 alpha:0.9];
    s.shadowBlurRadius = 6;
    s.position = SpliceKitCaptionPositionCenter;  // center, not bottom
    s.animation = SpliceKitCaptionAnimationPop;
    s.animationDuration = 0.15;
    s.allCaps = YES;
    s.wordByWordHighlight = YES;
    [list addObject:s];
}
```

#### 1b. Switch to pasteboard FCPXML import

The current import path generates an SRT file and uses NSOpenPanel swizzling.
This **loses all FCPXML styling** because SRT is plain text with timecodes.
FCP then renders SRT captions using its built-in caption styling, not our styled
titles.

**The fix:** Use `SpliceKit_handlePasteboardImportXML()` which is already
implemented in `SpliceKitServer.m:1018`. This writes FCPXML to NSPasteboard
with FCP's custom `IXXMLPasteboardType`, then triggers `FFXMLTranslationTask`
to import it directly. No dialogs, no file I/O, and **all styling is preserved**.

**Change in `generateCaptions` (line 1589-1679):**

Replace the SRT-export + NSOpenPanel-swizzle block with:

```objc
// Import via pasteboard (preserves all FCPXML styling)
NSDictionary *importResult = SpliceKit_handlePasteboardImportXML(@{@"xml": xml});
BOOL importOK = (importResult[@"error"] == nil);
```

This is a single function call replacing ~80 lines of swizzle code.

#### 1c. Update MCP generate_captions defaults

**File: `mcp/server.py` — `generate_captions()` (line 3535)**

```python
def generate_captions(style: str = "", position: str = "center",  # was "bottom"
                      animation: str = "pop",                      # was "fade"
                      word_highlight: bool = True,
                      max_words: int = 3,                          # was 5
                      all_caps: bool = True) -> str:               # was False
```

---

### Phase 2: Implement Entrance/Exit Animations via Clip Layering

**Goal:** Implement the 5 animation types that are currently stubbed out.

The `animationXMLForSegmentDuration:` method at line 1438 currently returns `""`.
The approach: instead of trying to add keyframes (which FCPXML doesn't support
on adjust-transform), **generate additional overlapping title clips** that
simulate the animation.

#### Strategy: Pre-roll and post-roll clips

For each visible caption title, generate 2-4 additional "animation frame" titles
that precede and/or follow it, each with a slightly different static opacity
and/or scale:

```
Timeline for one word with "pop" animation:

Frame 1 (2 frames):  scale=0.5, opacity=0.3  ← "growing in"
Frame 2 (2 frames):  scale=0.8, opacity=0.7
Frame 3 (rest):      scale=1.0, opacity=1.0  ← "fully visible"
Frame 4 (2 frames):  scale=0.9, opacity=0.5  ← "fading out" (only on last word of segment)
```

#### Implementation for each animation type

**Fade** — Opacity ramp only:

```objc
// Pre-roll: 3-4 frames at increasing opacity
// Post-roll: 3-4 frames at decreasing opacity (last word only)
titles += titleWithBlend(0.0, duration: 1frame)
titles += titleWithBlend(0.33, duration: 1frame)
titles += titleWithBlend(0.66, duration: 1frame)
titles += titleWithBlend(1.0, duration: restOfWord)
```

**Pop** — Scale + opacity:

```objc
// Pre-roll: 3 frames, scale ramps from 0.5→1.0, opacity 0→1
titles += titleWithScale(0.5, blend: 0.0, duration: 1frame)
titles += titleWithScale(0.75, blend: 0.5, duration: 1frame)
titles += titleWithScale(1.0, blend: 1.0, duration: restOfWord)
```

**Bounce** — Scale overshoot:

```objc
// Pre-roll + overshoot: scale 0.7→1.15→1.0
titles += titleWithScale(0.7, blend: 0.5, duration: 1frame)
titles += titleWithScale(1.15, blend: 1.0, duration: 2frames) // overshoot
titles += titleWithScale(1.0, blend: 1.0, duration: restOfWord) // settle
```

**Slide Up** — Y position + opacity:

```objc
// Pre-roll: Y starts 30px below, ramps to final position
CGFloat finalY = [self yOffsetForPosition];
titles += titleAtY(finalY - 30, blend: 0.0, duration: 1frame)
titles += titleAtY(finalY - 15, blend: 0.5, duration: 1frame)
titles += titleAtY(finalY, blend: 1.0, duration: restOfWord)
```

**Typewriter** — Progressive word reveal:

This one is special. Instead of showing all words and highlighting one,
it progressively reveals words one at a time:

```
Time 0.0s: "THE"
Time 0.3s: "THE QUICK"
Time 0.6s: "THE QUICK BROWN"
```

Each title shows only the words revealed so far, with the latest word
highlighted. This is a different text content per frame, not just styling.

#### Code location

**New method** to replace the stub at line 1438:

```objc
- (NSArray<NSString *> *)animationTitlesForWord:(SpliceKitTranscriptWord *)word
                                      inSegment:(SpliceKitCaptionSegment *)seg
                                      wordIndex:(NSUInteger)wi
                                         textXML:(NSString *)textXML
                                     normalTSDef:(NSString *)normalTSDef
                                  highlightTSDef:(NSString *)highlightTSDef {

    NSMutableArray *titles = [NSMutableArray array];
    SpliceKitCaptionStyle *s = self.style;
    CGFloat yOffset = [self yOffsetForPosition];
    int fdN = self.fdNum, fdD = self.fdDen;
    double animDur = s.animationDuration; // typically 0.15-0.3s

    switch (s.animation) {
        case SpliceKitCaptionAnimationPop: {
            // Generate 3 pre-roll frames
            int animFrames = (int)round(animDur * self.frameRate);
            if (animFrames < 2) animFrames = 2;
            double frameTime = 1.0 / self.frameRate;

            for (int f = 0; f < animFrames; f++) {
                double t = (double)(f + 1) / animFrames; // 0→1
                double scale = 0.5 + 0.5 * t;            // 0.5→1.0
                double opacity = t;                       // 0→1
                double fStart = word.startTime + f * frameTime;
                double fDur = frameTime;

                [titles addObject:[self titleXMLWithRef:@"r2"
                    offset:SpliceKitCaption_durRational(fStart, fdN, fdD)
                    duration:SpliceKitCaption_durRational(fDur, fdN, fdD)
                    textXML:textXML normalTSDef:normalTSDef highlightTSDef:highlightTSDef
                    position:yOffset scale:scale opacity:opacity
                    name:[NSString stringWithFormat:@"Anim_f%d", f]]];
            }

            // Main title starts after animation
            double mainStart = word.startTime + animFrames * frameTime;
            double mainDur = word.duration - animFrames * frameTime;
            if (mainDur > 0) {
                [titles addObject:[self titleXMLWithRef:@"r2"
                    offset:SpliceKitCaption_durRational(mainStart, fdN, fdD)
                    duration:SpliceKitCaption_durRational(mainDur, fdN, fdD)
                    textXML:textXML normalTSDef:normalTSDef highlightTSDef:highlightTSDef
                    position:yOffset scale:1.0 opacity:1.0
                    name:@"Main"]];
            }
            break;
        }
        // ... cases for Fade, Bounce, SlideUp, Typewriter
    }
    return titles;
}
```

**New helper** for building a title with scale + opacity:

```objc
- (NSString *)titleXMLWithRef:(NSString *)ref
                       offset:(NSString *)offStr
                     duration:(NSString *)durStr
                      textXML:(NSString *)textXML
                  normalTSDef:(NSString *)normalTSDef
               highlightTSDef:(NSString *)highlightTSDef
                     position:(CGFloat)yOffset
                        scale:(double)scale
                      opacity:(double)opacity
                         name:(NSString *)name {

    NSMutableString *xml = [NSMutableString string];
    [xml appendFormat:@"<title ref=\"%@\" lane=\"1\" name=\"%@\" "
        @"offset=\"%@\" duration=\"%@\" start=\"3600s\">\n", ref, name, offStr, durStr];
    [xml appendFormat:@"    %@\n", textXML];
    [xml appendFormat:@"    %@\n", normalTSDef];
    if (highlightTSDef) [xml appendFormat:@"    %@\n", highlightTSDef];

    // Scale and position via adjust-transform
    if (fabs(scale - 1.0) > 0.01) {
        [xml appendFormat:@"    <adjust-transform position=\"0 %.0f\" scale=\"%.2f %.2f\"/>\n",
            yOffset, scale, scale];
    } else {
        [xml appendFormat:@"    <adjust-transform position=\"0 %.0f\"/>\n", yOffset];
    }

    // Opacity via adjust-blend
    if (opacity < 0.99) {
        [xml appendFormat:@"    <adjust-blend amount=\"%.2f\"/>\n", opacity];
    }

    [xml appendString:@"</title>\n"];
    return xml;
}
```

#### When to apply animation

- **Entrance animation**: First word of each segment gets pre-roll frames
- **Exit animation**: Last word of each segment gets post-roll frames (fade-out)
- **Middle words**: No animation frames, just the karaoke highlight swap
- **Single-word segments**: Both entrance AND exit on the same word

---

### Phase 3: Background Box System

**Goal:** Add a semi-transparent rounded rectangle behind caption text, matching
the visual style of TikTok/Reels captions.

#### Approach: Background generator on a separate sub-lane

FCPXML doesn't support drawing rectangles. But FCP's Basic Title can render a
block character (`█`) or use a **Custom Generator** as a colored background.

**Option A: Block character title (simpler)**

Generate a separate `<title>` on the same lane but overlapping the text title,
containing a large block of filled characters styled with the background color:

```xml
<!-- Background box: solid block characters behind text -->
<title ref="r2" lane="1" name="BG_001"
       offset="3600/2400s" duration="2400/2400s" start="3600s">
    <text>
        <text-style ref="bg_ts">████████████</text-style>
    </text>
    <text-style-def id="bg_ts">
        <text-style font="Helvetica Neue" fontSize="90"
                    fontColor="0 0 0 0.7"
                    alignment="center"/>
    </text-style-def>
    <adjust-transform position="0 -346"/>
</title>

<!-- Foreground text: actual caption words ON TOP of background -->
<title ref="r2" lane="2" name="Cap001_w1"
       offset="3600/2400s" duration="2400/2400s" start="3600s">
    <!-- ... caption text ... -->
    <adjust-transform position="0 -346"/>
</title>
```

The background goes on lane 1, the text on lane 2. Lane 2 renders on top of
lane 1, so text appears above the background box.

**Option B: Custom generator (more control)**

FCP has a built-in "Custom" generator that can produce solid color frames.
Reference it as an `<effect>` and use it as a connected clip:

```xml
<resources>
    <effect id="r3" name="Custom"
            uid=".../Generators.localized/Solids.localized/Custom.localized/Custom.motn"/>
</resources>

<!-- Background as a generator clip, scaled down and positioned -->
<video ref="r3" lane="1" name="BG_001"
       offset="3600/2400s" duration="2400/2400s" start="0s">
    <adjust-transform position="0 -346" scale="0.5 0.15"/>
    <adjust-blend amount="0.7"/>
</video>
```

This gives a colored rectangle at 50% width and 15% height of the frame,
centered at the caption position, at 70% opacity. However, it doesn't have
rounded corners.

**Option C: ObjC runtime approach (most control)**

Instead of trying to encode the background in FCPXML, use the ObjC runtime to
add an `NSView`-based overlay in FCP's viewer, or create a CALayer-based
background that tracks the caption position. This would be rendered by SpliceKit,
not by FCP's compositing engine, so it would only be visible during playback —
not in exports.

**Recommendation: Option A** for shipped captions (block character background).
It's simple, exports correctly, and the `█` character at large size with a
background color creates a convincing box effect. The size and color are fully
controllable via text-style-def attributes.

#### Implementation

**New property on SpliceKitCaptionStyle:**

```objc
@property (nonatomic) BOOL showBackground;           // default YES for social presets
@property (nonatomic) CGFloat backgroundCornerRadius; // for future Motion template
```

**New method in SpliceKitCaptionPanel.m:**

```objc
- (NSString *)backgroundTitleXMLForSegment:(SpliceKitCaptionSegment *)seg {
    if (!self.style.backgroundColor || !self.style.showBackground) return @"";

    // Calculate block character count based on text width
    NSUInteger charCount = seg.text.length + 4; // pad 2 chars each side
    NSMutableString *blocks = [NSMutableString string];
    for (NSUInteger i = 0; i < charCount; i++) [blocks appendString:@"█"];

    NSString *offStr = SpliceKitCaption_durRational(seg.startTime, self.fdNum, self.fdDen);
    NSString *durStr = SpliceKitCaption_durRational(seg.duration, self.fdNum, self.fdDen);
    CGFloat yOffset = [self yOffsetForPosition];

    NSMutableString *xml = [NSMutableString string];
    // Background on lane 1, text will go on lane 2
    [xml appendFormat:@"<title ref=\"r2\" lane=\"1\" name=\"BG_%03lu\" "
        @"offset=\"%@\" duration=\"%@\" start=\"3600s\">\n",
        (unsigned long)seg.segmentIndex, offStr, durStr];
    [xml appendFormat:@"    <text><text-style ref=\"bg_ts\">%@</text-style></text>\n",
        SpliceKitCaption_escapeXML(blocks)];
    [xml appendFormat:@"    <text-style-def id=\"bg_ts\"><text-style "
        @"font=\"%@\" fontSize=\"%.0f\" fontColor=\"%@\" alignment=\"center\""
        @"/></text-style-def>\n",
        SpliceKitCaption_escapeXML(self.style.font),
        self.style.fontSize * 1.3, // slightly larger than text
        SpliceKitCaption_colorToFCPXML(self.style.backgroundColor)];
    [xml appendFormat:@"    <adjust-transform position=\"0 %.0f\"/>\n", yOffset];
    [xml appendString:@"</title>\n"];
    return xml;
}
```

When background is enabled, text titles move to `lane="2"` and background
titles go to `lane="1"`.

---

### Phase 4: Smart Segmentation for Social Media

**Goal:** Segment words in a way that creates natural, punchy caption groups
optimized for short-form video.

#### 4a. New grouping mode: "Social"

Add a new `SpliceKitCaptionGroupingSocial` mode that combines multiple heuristics:

```objc
case SpliceKitCaptionGroupingSocial: {
    // Target: 2-3 words per segment
    // Break on: 3 words, sentence punctuation, 1s+ silence, emphasis words
    BOOL sentenceEnd = [prevText hasSuffix:@"."] || [prevText hasSuffix:@"!"]
                    || [prevText hasSuffix:@"?"];
    BOOL hitMax = (group.count >= 3);
    BOOL longSilence = (gap > 0.5);  // shorter threshold than default 1.0s
    shouldBreak = sentenceEnd || hitMax || longSilence;
    break;
}
```

#### 4b. Emphasis word detection

Detect words that should receive extra visual emphasis (larger font, different
color, emoji). Heuristics:

- Words in ALL CAPS in the original transcript
- Words with high confidence that follow a pause
- Profanity/exclamation words ("literally", "insane", "amazing", "wow")
- Words preceded by "so", "very", "really", "absolutely"
- Words that are significantly longer than average (compound words, names)

```objc
@interface SpliceKitTranscriptWord (Emphasis)
@property (nonatomic) BOOL isEmphasis;  // set during segmentation
@end
```

Emphasis words get the highlight color AND `bold="1"` even when they're not
the "active" word in the karaoke sweep.

#### 4c. Multi-line segment layout

For segments longer than ~10 characters, insert a line break (using a second
`<text-style>` element with a newline character, or by splitting into two
overlapping titles at different Y positions):

```
Segment: "I LITERALLY CANNOT BELIEVE IT"

Layout as 2 stacked titles on the same lane at the same time:
  Title A at Y=-320:  "I LITERALLY"
  Title B at Y=-370:  "CANNOT BELIEVE IT"
  (with active word highlighted in whichever title contains it)
```

This gives explicit control over line breaks rather than depending on FCP's
automatic wrapping.

---

### Phase 5: Active Word Scale Bump

**Goal:** The currently-spoken word should be visually larger than surrounding
words, not just a different color.

#### Approach: Per-word titles with different scales

Instead of one title showing all words (with color differences), generate
each word as its own title clip:

```
Segment: "THE QUICK BROWN"
Active word: QUICK

Lane 2:  ┌──────────┐
         │ THE      │  scale=1.0, opacity=0.7, normal color
         └──────────┘
Lane 2:      ┌──────────┐
             │  QUICK   │  scale=1.15, opacity=1.0, highlight color
             └──────────┘
Lane 2:          ┌──────────┐
                 │   BROWN  │  scale=1.0, opacity=0.7, normal color
                 └──────────┘
```

Each word gets its own `<title>` with its own `<adjust-transform>`:

```xml
<!-- Active word: slightly larger, full opacity -->
<title ref="r2" lane="2" name="W_QUICK" offset="..." duration="..." start="3600s">
    <text><text-style ref="ts_h">QUICK</text-style></text>
    <text-style-def id="ts_h">...</text-style-def>
    <adjust-transform position="0 -346" scale="1.15 1.15"/>
    <adjust-blend amount="1.0"/>
</title>

<!-- Inactive words: normal size, dimmed -->
<title ref="r2" lane="2" name="W_THE" offset="..." duration="..." start="3600s">
    <text><text-style ref="ts_n">THE</text-style></text>
    <text-style-def id="ts_n">...</text-style-def>
    <adjust-transform position="-80 -346" scale="1.0 1.0"/>
    <adjust-blend amount="0.7"/>
</title>
```

**Challenge:** Positioning individual words requires calculating X offsets
based on character widths. This needs a font metrics calculation:

```objc
- (CGFloat)widthOfText:(NSString *)text {
    NSFont *font = [NSFont fontWithName:self.style.font size:self.style.fontSize]
                   ?: [NSFont boldSystemFontOfSize:self.style.fontSize];
    NSDictionary *attrs = @{NSFontAttributeName: font};
    return [text sizeWithAttributes:attrs].width;
}
```

This is complex but would produce the most visually compelling result. Consider
implementing this as an opt-in "premium" mode, while keeping the simpler
same-title-different-color approach as the default.

---

### Phase 6: Direct FCPXML Import (Bypass SRT Entirely)

**Goal:** Eliminate the SRT intermediary and import styled titles directly via
the pasteboard FCPXML path.

The current pipeline is:

```
Words → FCPXML (styled titles) → SRT (loses styling) → NSOpenPanel swizzle → FCP import
```

With pasteboard import:

```
Words → FCPXML (styled titles) → NSPasteboard (IXXMLPasteboardType) → FFXMLTranslationTask → FCP import
```

#### Implementation

The core change is in `generateCaptions` at line 1589. Replace the entire
SRT-export + NSOpenPanel-swizzle block (lines 1589-1679) with:

```objc
// Import via pasteboard — clean path, preserves all styling
__block BOOL importOK = NO;
dispatch_sync(dispatch_get_main_queue(), ^{
    NSDictionary *importResult = SpliceKit_handlePasteboardImportXML(@{@"xml": xml});
    importOK = (importResult[@"error"] == nil);
    if (!importOK) {
        SpliceKit_log(@"[Captions] Pasteboard import failed: %@", importResult[@"error"]);
    }
});
```

This replaces ~80 lines of swizzle code with a single function call.

**Benefits:**
- All FCPXML styling preserved (font, color, outline, shadow, scale, opacity)
- No SRT generation needed
- No NSOpenPanel method swizzling (cleaner, less fragile)
- Background boxes work (SRT can't represent them)
- Animation frame clips work (SRT can't represent overlapping clips)
- Scale/opacity adjustments preserved

**Fallback:** Keep the SRT path as a fallback if pasteboard import fails (FCP
version differences, pasteboard type changes):

```objc
if (!importOK) {
    SpliceKit_log(@"[Captions] Falling back to SRT import");
    // ... existing SRT + swizzle code ...
}
```

---

### Phase 7: Custom Motion Template for Premium Captions

**Goal:** For the highest-quality animations that FCPXML clip layering can't achieve
(smooth bezier curves, spring physics, particle effects), create a custom Motion
template.

#### Approach

1. **Create a Motion project** (`.motn`) with:
   - Text layer with published parameters for: text content, font, size, colors
   - Keyframed entrance behavior: scale 0→overshoot→1.0 with spring curve
   - Keyframed exit behavior: opacity 1→0 with ease-out
   - Background rectangle behavior: scale to fit text, rounded corners
   - Published parameter for highlight word index

2. **Save as title template** (`.moti`) to:
   `~/Movies/Motion Templates.localized/Titles.localized/SpliceKit.localized/Social Caption.localized/Social Caption.moti`

3. **Reference in FCPXML:**
   ```xml
   <effect id="r2" name="Social Caption"
           uid=".../Titles.localized/SpliceKit.localized/
                Social Caption.localized/Social Caption.moti"/>
   ```

4. **Pass parameters via FCPXML** (if Motion supports it for this template):
   ```xml
   <title ref="r2" lane="1" offset="..." duration="..." start="3600s">
       <param name="Text" key="9999/..." value="THE QUICK BROWN"/>
       <param name="Highlight Word" key="9999/..." value="2"/>
       <param name="Text Color" key="9999/..." value="1 1 1 1"/>
       <param name="Highlight Color" key="9999/..." value="1 0.85 0 1"/>
   </title>
   ```

#### When to use this vs. clip layering

| Feature | Clip Layering (Phase 2) | Motion Template (Phase 7) |
|---------|------------------------|--------------------------|
| Smooth animations | Stepped (2-4 frames) | True bezier curves |
| Spring/bounce physics | Approximated | Native Motion behaviors |
| Background box | Block characters | True rounded rectangle |
| Performance | Many small clips (heavy) | Single clip per segment (light) |
| Portability | Works everywhere | Requires template installed |
| Complexity | Pure FCPXML generation | Requires Motion.app to design |
| Parameter control | Full (in code) | Must publish params in Motion |

**Recommendation:** Implement Phase 2 (clip layering) first because it works
everywhere with no dependencies. Phase 7 is an enhancement for users who want
the absolute best quality and are willing to install the Motion template.

---

### Phase 8: Speaker-Aware Styling

**Goal:** Use Parakeet's speaker diarization to style different speakers differently.

The transcript system already supports speaker labels via `SpliceKitTranscriptWord.speaker`.
Extend the caption system to map speakers to visual styles.

#### Implementation

**New model:**

```objc
@interface SpliceKitCaptionSpeakerStyle : NSObject
@property (nonatomic, copy) NSString *speakerID;       // "Speaker 1"
@property (nonatomic, copy) NSColor *textColor;        // unique per speaker
@property (nonatomic, copy) NSColor *highlightColor;   // unique per speaker
@property (nonatomic) SpliceKitCaptionPosition position; // different Y for different speakers
@end
```

**New style property:**

```objc
@property (nonatomic, strong) NSDictionary<NSString *, SpliceKitCaptionSpeakerStyle *> *speakerStyles;
```

**In FCPXML generation:** Check each segment's words for speaker labels. If all
words in a segment have the same speaker, apply that speaker's color scheme.
If speakers change mid-segment, force a segment break.

**Default speaker colors:**

| Speaker | Text Color | Highlight Color |
|---------|-----------|----------------|
| Speaker 1 | White | Yellow |
| Speaker 2 | White | Cyan |
| Speaker 3 | White | Magenta |
| Speaker 4 | White | Lime Green |

---

## 21. Implementation Priority & Dependencies

```
Phase 1: Social Defaults + Pasteboard Import    ← DO FIRST (foundation)
    │
    ├── Phase 2: Entrance/Exit Animations        ← HIGH VALUE (visual impact)
    │       │
    │       └── Phase 5: Active Word Scale       ← NICE TO HAVE (polish)
    │
    ├── Phase 3: Background Box System           ← HIGH VALUE (social standard)
    │
    ├── Phase 4: Smart Segmentation              ← MEDIUM VALUE (better defaults)
    │       │
    │       └── Phase 8: Speaker-Aware Styling   ← MEDIUM VALUE (multi-speaker)
    │
    └── Phase 6: Direct FCPXML Import            ← HIGH VALUE (enables phases 2,3,5)
            │
            └── Phase 7: Motion Template         ← FUTURE (premium quality)
```

**Critical path:** Phases 1 → 6 → 2 → 3. Phase 6 (pasteboard import) must come
before phases 2 and 3 because the SRT import path can't represent animation
frame clips or background boxes.

**Estimated scope per phase:**

| Phase | Files Modified | New Lines | Complexity |
|-------|---------------|-----------|-----------|
| 1 | CaptionPanel.m, server.py | ~50 | Low |
| 2 | CaptionPanel.m | ~200 | Medium |
| 3 | CaptionPanel.m, CaptionPanel.h | ~100 | Medium |
| 4 | CaptionPanel.m, CaptionPanel.h | ~80 | Low |
| 5 | CaptionPanel.m | ~150 | High (font metrics) |
| 6 | CaptionPanel.m | -60 (net removal) | Low |
| 7 | New .motn file, CaptionPanel.m | ~100 + Motion project | High |
| 8 | CaptionPanel.m, CaptionPanel.h, server.py | ~120 | Medium |

---

## 22. FCPXML Examples: Before & After

### Current output (5 words, no animation, no background)

```xml
<gap name="CaptionAnchor" offset="0s" duration="72000/2400s" start="0s">

    <!-- Segment 1: "I LITERALLY CANNOT BELIEVE THIS" — 5 words, one line -->
    <!-- Word 1 active -->
    <title ref="r2" lane="1" name="Cap001_w1"
           offset="3600/2400s" duration="800/2400s" start="3600s">
        <text>
            <text-style ref="ts1_h">I </text-style>
            <text-style ref="ts1_n">LITERALLY CANNOT BELIEVE THIS</text-style>
        </text>
        <text-style-def id="ts1_n"><text-style font="Futura-Bold" fontSize="72"
            fontColor="1 1 1 1" alignment="center"/></text-style-def>
        <text-style-def id="ts1_h"><text-style font="Futura-Bold" fontSize="72"
            fontColor="1 0.85 0 1" bold="1" alignment="center"/></text-style-def>
        <adjust-transform position="0 -346"/>
    </title>

    <!-- Word 2 active (same pattern, different highlight) -->
    <!-- ... 3 more titles for words 3, 4, 5 ... -->
</gap>
```

### Target output (3 words, pop animation, background box)

```xml
<gap name="CaptionAnchor" offset="0s" duration="72000/2400s" start="0s">

    <!-- ===== Segment 1: "I LITERALLY CANNOT" ===== -->

    <!-- Background box (lane 1, below text) -->
    <title ref="r2" lane="1" name="BG_001"
           offset="3600/2400s" duration="3600/2400s" start="3600s">
        <text>
            <text-style ref="bg_ts">████████████████████</text-style>
        </text>
        <text-style-def id="bg_ts"><text-style font="Futura-Bold" fontSize="94"
            fontColor="0 0 0 0.7" alignment="center"/></text-style-def>
        <adjust-transform position="0 0"/>
    </title>

    <!-- Word 1: "I" — with pop entrance animation -->

    <!-- Animation frame 1: scale=0.5, opacity=0.3, duration=1 frame -->
    <title ref="r2" lane="2" name="Cap001_w1_f1"
           offset="3600/2400s" duration="100/2400s" start="3600s">
        <text>
            <text-style ref="ts1_h">I </text-style>
            <text-style ref="ts1_n">LITERALLY CANNOT</text-style>
        </text>
        <text-style-def id="ts1_n"><text-style font="Futura-Bold" fontSize="100"
            fontColor="1 1 1 1" strokeColor="0 0 0 1" strokeWidth="4"
            alignment="center"/></text-style-def>
        <text-style-def id="ts1_h"><text-style font="Futura-Bold" fontSize="100"
            fontColor="1 0.85 0 1" bold="1" strokeColor="0 0 0 1" strokeWidth="4"
            alignment="center"/></text-style-def>
        <adjust-transform position="0 0" scale="0.5 0.5"/>
        <adjust-blend amount="0.3"/>
    </title>

    <!-- Animation frame 2: scale=0.75, opacity=0.7, duration=1 frame -->
    <title ref="r2" lane="2" name="Cap001_w1_f2"
           offset="3700/2400s" duration="100/2400s" start="3600s">
        <!-- same text content -->
        <adjust-transform position="0 0" scale="0.75 0.75"/>
        <adjust-blend amount="0.7"/>
    </title>

    <!-- Animation frame 3: scale=1.0, opacity=1.0, rest of word duration -->
    <title ref="r2" lane="2" name="Cap001_w1"
           offset="3800/2400s" duration="600/2400s" start="3600s">
        <!-- same text content, full size -->
        <adjust-transform position="0 0"/>
    </title>

    <!-- Word 2: "LITERALLY" — no entrance (mid-segment), just highlight swap -->
    <title ref="r2" lane="2" name="Cap001_w2"
           offset="4400/2400s" duration="1200/2400s" start="3600s">
        <text>
            <text-style ref="ts2_n">I </text-style>
            <text-style ref="ts2_h">LITERALLY </text-style>
            <text-style ref="ts2_n">CANNOT</text-style>
        </text>
        <!-- ... style defs ... -->
        <adjust-transform position="0 0"/>
    </title>

    <!-- Word 3: "CANNOT" — with fade-out at end (last word of segment) -->
    <title ref="r2" lane="2" name="Cap001_w3"
           offset="5600/2400s" duration="1000/2400s" start="3600s">
        <!-- main display: full opacity -->
        <adjust-transform position="0 0"/>
    </title>

    <!-- Fade-out frame 1 -->
    <title ref="r2" lane="2" name="Cap001_w3_out1"
           offset="6600/2400s" duration="100/2400s" start="3600s">
        <adjust-transform position="0 0"/>
        <adjust-blend amount="0.5"/>
    </title>

    <!-- ===== Segment 2: "BELIEVE THIS" ===== -->
    <!-- ... same pattern: background + pop entrance + highlight sweep + fade exit ... -->

</gap>
```

### Clip count analysis

| Content | Current (5 words/seg) | Target (3 words/seg + animation) |
|---------|----------------------|----------------------------------|
| 100-word transcript | ~100 titles | ~180 titles (3 anim frames/entrance + 2/exit) |
| 300-word transcript | ~300 titles | ~540 titles |
| With background boxes | N/A | +~33 background titles (100 words / 3 per seg) |

FCP handles hundreds of title clips efficiently. The timeline will look busy
in the editor but renders smoothly at playback. The titles on the same lane
at the same time simply composite in order.

---

## 23. Summary: What "Good Social Media Captions" Means for SpliceKit

The current system is architecturally sound. The lane-based FCPXML generation,
word timing pipeline, and style system are all well-designed and extensible.
The gaps are:

1. **Defaults are wrong for social** — too many words per segment, font too small,
   position too low. Fix: Phase 1 (trivial).

2. **No animations** — the stub returns `""`. Fix: Phase 2 (medium — generate
   overlapping clips with varying scale/opacity).

3. **No background box** — the property exists but isn't used. Fix: Phase 3
   (medium — block character titles on a lower lane).

4. **Import loses styling** — SRT can't carry font/color/outline info. Fix:
   Phase 6 (easy — switch to pasteboard import that already exists).

5. **No active word scale** — all words same size. Fix: Phase 5 (hard — requires
   font metrics for per-word X positioning).

The first four can be implemented incrementally. Each phase produces a usable
improvement. Phase 6 (pasteboard import) is the linchpin — without it, phases
2, 3, and 5 produce FCPXML that gets thrown away during SRT conversion.

---
---

# Part III: mCaptions Reverse Engineering & Replication Plan

## 24. mCaptions Architecture (from Decompilation)

mCaptions is a commercial FCP Workflow Extension that generates
word-by-word highlighted captions. Its decompiled binaries reveal a three-tier
architecture that we can replicate — with advantages — using SpliceKit's
in-process approach.

### Three-tier architecture

```
┌──────────────────────────────────────────────────────────────┐
│ Final Cut Pro (Host Application)                              │
│                                                              │
│  Loads mCaptions.appex as a Workflow Extension               │
│  Provides ProExtensionHostProtocol for FCP ↔ Extension IPC  │
│  Receives FCPXML via Flexo pasteboard on caption apply       │
└───────────────────────┬──────────────────────────────────────┘
                        │ ProExtension APIs
                        ▼
┌──────────────────────────────────────────────────────────────┐
│ mCaptions Workflow Extension (.appex)                         │
│                                                              │
│  UI Layer:                                                    │
│  • mCaptionsExtensionViewController (NIB-based UI)          │
│  • TranscriptionViewController, PreviewViewModel             │
│  • LanguageViewModel, MoreOptionsViewModel                   │
│  • TemplatesViewModel, OutputViewModel, DialogsViewModel     │
│                                                              │
│  Model Layer:                                                 │
│  • TranscriptionModel — settings, language, caption IDs      │
│  • InputModel — file/pasteboard import, state machine         │
│  • AnalysisModel — transcription orchestration                │
│  • TemplatesModel — Motion template catalog management       │
│  • OutputModel — FCPXML generation + export                  │
│  • PreviewModel — real-time styled preview                    │
│  • MoreOptionsModel — advanced styling options               │
│                                                              │
│  Infrastructure:                                              │
│  • DependencyContainer — IoC for all models/viewmodels       │
│  • XPCServiceConnection — daemon IPC management              │
│  • LauncherRunner — daemon lifecycle (launchd)                │
│  • ExtensionHost — FCP host protocol bridge                  │
│  • TranscriptionRepository — persistence (JSON)              │
│  • Sentry — crash/error reporting                            │
└───────────────────────┬──────────────────────────────────────┘
                        │ XPC (mCaptionsDaemon)
                        ▼
┌──────────────────────────────────────────────────────────────┐
│ mCaptionsDaemon (Background LaunchAgent)                     │
│                                                              │
│  24 ObjC classes, 263 methods, 64 properties, 6 protocols   │
│  (Decompilation failed — analysis from IDA metadata only)    │
│                                                              │
│  Inferred responsibilities:                                   │
│  • Whisper speech-to-text engine (GPU-accelerated + CPU)     │
│  • Word-level timestamp extraction                            │
│  • Motion template rendering/application                     │
│  • FCPXML generation with NSXMLDocument                      │
│  • Style application to caption segments                     │
│  • SRT format export                                          │
└──────────────────────────────────────────────────────────────┘
```

### Key discoveries from decompilation

**1. Whisper for transcription (local, not cloud)**

```
String evidence:
  "WhisperRunning"              ← Whisper engine state
  "MissingModel"                ← ML model download state
  "GPU model not supported. Processing on CPU."  ← GPU/CPU fallback
  "mCaptionsAI"                 ← Product name references AI
  "mCaptionsAIAnalysisEnded"    ← Analysis completion notification
```

No HTTP API endpoints, no API keys, no cloud URLs found in any binary. All
transcription is on-device using Whisper models. This matches SpliceKit's
Parakeet-based approach.

**2. Motion Templates for styled captions (NOT Basic Title)**

```
String evidence:
  "/Motion Templates.localized/Titles.localized/mCaptions"  ← template path
  "Font %@ used by the selected template is unavailable"     ← font validation
  "You don't have any templates in the mCaptions directory"  ← template presence check
  "DesignStudio:mCaptions"                                    ← design studio branding
  "com.apple.motionapp"                                       ← Motion.app integration
```

mCaptions ships **custom Motion Templates** (`.moti` files) installed to
`~/Movies/Motion Templates.localized/Titles.localized/mCaptions/`. These
templates contain the visual styling, animations, background boxes, and
highlight effects. The daemon fills in text content and word timing, then
generates FCPXML referencing these templates.

**This is the key architectural difference from SpliceKit.** SpliceKit uses
the built-in Basic Title and constructs styling via `<text-style-def>` in the
FCPXML. mCaptions uses pre-designed Motion templates with published parameters,
which gives them:
- Smooth bezier-curve entrance/exit animations (designed in Motion)
- True rounded-rectangle background boxes (Motion shape layer)
- Per-character animation behaviors (Motion text behaviors)
- Spring physics, particle effects, 3D transforms (Motion behaviors)

**3. Flexo pasteboard for FCP insertion**

```
String evidence:
  "com.apple.flexo.proFFPasteboardUTI"  ← FCP's internal pasteboard type
```

mCaptions writes generated FCPXML to NSPasteboard using FCP's Flexo UTI type,
then FCP reads it and inserts the caption clips. SpliceKit already has this
capability via `SpliceKit_handlePasteboardImportXML()`.

**4. State machine for import pipeline**

```
States: Importing → ImportingFinished
        CaptionsExtracting → CaptionsExtractingFinished
        AudioFilesExtracting → AudioFilesExtractingFinished
```

mCaptions has a well-defined state machine for tracking the import/transcribe
pipeline. SpliceKit's simpler status enum (`Idle/Transcribing/Ready/Generating/Error`)
covers the same ground.

**5. Word-level timestamp approximation**

```
"Imported captions don't contain word-by-word timestamps, timings will be approximated."
```

When mCaptions imports SRT files (which have segment-level timing but not
per-word timing), it approximates word timestamps. This is likely done by
distributing the segment duration proportionally across words by character count.
SpliceKit doesn't need this because Parakeet provides native word-level timing.

**6. FPS validation**

```
"FPS missmatch\n (timeline %@ vs %@ selected)"
```

mCaptions validates that the timeline frame rate matches the export settings.
SpliceKit detects timeline properties automatically via `detectTimelineProperties()`,
so this validation is inherent.

**7. XPC daemon with launchd lifecycle**

```
Service: mCaptionsDaemon
Plist:   mCaptionsDaemon-Launchd.plist
Helper:  mCaptionsLauncher.app
Kill:    mCaptionsTerminator.app

Lifecycle: LauncherRunner.initializeDaemonResources
         → LauncherRunner.loadDaemonWithError:
         → LauncherRunner.launchAndVerifyDaemon:
         → XPCServiceConnection.newConnectionToService
         → XPCServiceConnection.startStateCheckTimers (health checks)
         → [On failure] LauncherRunner.relaunchDaemon:message:error:
```

mCaptions uses a separate daemon process because Workflow Extensions run
out-of-process from FCP and have limited capabilities. The daemon handles
heavy GPU compute (Whisper) and FCPXML generation.

**SpliceKit doesn't need this** — it runs in-process within FCP, so it has
direct access to the GPU, the timeline data model, and can call ObjC methods
on FCP's own objects. This is a significant architectural advantage.

**8. Project dimensions tracking**

```
"ProjectWidth", "ProjectHeight"
```

mCaptions stores video dimensions for proper caption positioning. SpliceKit
reads these directly from the active timeline via `renderSize`.

---

## 25. Comparison: mCaptions vs. SpliceKit Caption System

| Aspect | mCaptions | SpliceKit (Current) | SpliceKit (Planned) |
|--------|-----------|-------------------|-------------------|
| **Architecture** | Out-of-process Workflow Extension + XPC daemon | In-process dylib (direct FCP access) | Same |
| **Transcription** | Whisper (GPU + CPU fallback) | Parakeet TDT 0.6B (GPU via FluidAudio) | Same |
| **Word timing** | Whisper word timestamps + SRT approximation | Parakeet native word timing | Same |
| **Caption styling** | Custom Motion Templates (.moti) | Basic Title + text-style-def in FCPXML | Motion Templates (Phase 7) |
| **Animations** | Designed in Motion (bezier curves, behaviors) | Stubbed out (returns "") | Clip layering (Phase 2) + Motion (Phase 7) |
| **Background box** | Motion shape layer in template | Not implemented | Block chars (Phase 3) or Motion (Phase 7) |
| **FCP integration** | Flexo pasteboard (proFFPasteboardUTI) | SRT + NSOpenPanel swizzle | Pasteboard FCPXML (Phase 6) |
| **Timeline detection** | Manual ProjectWidth/ProjectHeight settings | Automatic via objc_msgSend introspection | Same |
| **Preview** | Real-time in extension UI | Live NSAttributedString in panel | Same |
| **Export** | SRT, FCP Captions, FCPXML | SRT, TXT, FCPXML | Same |
| **Language support** | Multi-language via Whisper | 25 languages via Parakeet v3 | Same |
| **Speaker diarization** | Unknown (daemon code not decompiled) | Parakeet + FluidAudio OfflineDiarizer | Same |
| **Template system** | DesignStudio catalog, font validation | 12 built-in presets, custom via API | Motion Templates (Phase 7) |
| **Error reporting** | Sentry integration | SpliceKit_log() | Same |

### SpliceKit's inherent advantages

1. **In-process access** — Direct `objc_msgSend` calls to FCP's runtime. No XPC
   serialization overhead, no daemon lifecycle management, no connection health checks.

2. **Automatic timeline detection** — Frame rate, resolution, and sequence properties
   are read directly from the active `FFAnchoredTimelineModule`. mCaptions must
   receive these as parameters from the Workflow Extension host.

3. **Instant import** — The pasteboard FCPXML import function
   (`SpliceKit_handlePasteboardImportXML`) already exists and can insert styled
   FCPXML directly without the Workflow Extension roundtrip.

4. **No daemon needed** — SpliceKit runs in FCP's process, so it has direct GPU
   access for transcription and can call FCP's APIs synchronously.

5. **Real-time timeline access** — SpliceKit can read clip positions, playhead time,
   and selected clips in real time. mCaptions only gets information when the
   Workflow Extension is opened and must go through ProExtension protocol methods.

### mCaptions' advantages to replicate

1. **Motion Templates** — Pre-designed visual templates with smooth animations,
   background boxes, and per-character effects that FCPXML alone can't express.

2. **Template marketplace** — DesignStudio integration for users to browse and
   install new caption styles.

3. **Font validation** — Checks that fonts used by templates are installed.

---

## 26. Replication Plan: Building an mCaptions-Equivalent System

### What to build

A caption generation system within SpliceKit that:
1. Transcribes audio with word-level timing (already done via Parakeet)
2. Styles captions using Motion Templates (new — currently uses Basic Title)
3. Generates FCPXML with template references and word timing parameters
4. Imports via pasteboard FCPXML (switch from SRT swizzle)
5. Supports background boxes, entrance/exit animations, word-by-word highlight

### Phase A: Motion Template Creation

**Goal:** Create a set of `.moti` title templates in Apple Motion that support
parameterized word-by-word captions.

#### Template design requirements

Each Motion template needs these **published parameters** (accessible via FCPXML):

| Parameter | Type | Purpose |
|-----------|------|---------|
| Caption Text | Text | The full segment text |
| Highlight Index | Integer | Which word to highlight (0-based, or -1 for none) |
| Text Color | Color | Base text color |
| Highlight Color | Color | Active word color |
| Background Enabled | Checkbox | Show/hide background box |
| Background Color | Color | Box fill color |
| Background Opacity | Slider | Box transparency |
| Position Y | Slider | Vertical position offset |
| Font Size | Slider | Text size |

#### Template structure in Motion

```
Project: "SpliceKit Bold Pop" (1920x1080, match FCP project)
├── Group: Background
│   └── Rectangle (rounded corners)
│       ├── Width: linked to text width + padding
│       ├── Height: linked to text height + padding
│       ├── Fill Color: published parameter
│       ├── Opacity: published parameter
│       └── Corner Radius: 12px
├── Group: Text
│   └── Text Layer
│       ├── Text: published parameter
│       ├── Face: published parameter (font, size, color)
│       └── Behaviors:
│           ├── Build In: Scale Up (0.5→1.0, 6 frames, ease-out)
│           └── Build Out: Fade Out (1.0→0.0, 4 frames, ease-in)
└── Group: Highlight Overlay
    └── Text Layer (duplicate, tracks main text position)
        ├── Text: same published text parameter
        ├── Color: highlight color parameter
        ├── Visibility: controlled by highlight index logic
        └── Behaviors:
            └── Text Sequence: Sequential word reveal
```

#### Installation path

```
~/Movies/Motion Templates.localized/
    Titles.localized/
        SpliceKit.localized/
            Bold Pop.localized/
                Bold Pop.moti
            Neon Glow.localized/
                Neon Glow.moti
            Clean Minimal.localized/
                Clean Minimal.moti
            ... (one per preset)
```

#### FCPXML reference

```xml
<effect id="r2" name="Bold Pop"
        uid=".../Titles.localized/SpliceKit.localized/
             Bold Pop.localized/Bold Pop.moti"/>
```

### Phase B: FCPXML Generation with Template Parameters

**Goal:** Modify `generateCaptions` to reference Motion Templates and pass
parameters instead of building text-style-def elements manually.

#### New FCPXML structure per segment

```xml
<title ref="r2" lane="1" name="Cap001"
       offset="3600/2400s" duration="3600/2400s" start="3600s">

    <!-- Published parameters filled by SpliceKit -->
    <param name="Caption Text" key="9999/101/101/1"
           value="THE QUICK BROWN"/>
    <param name="Highlight Index" key="9999/101/101/2"
           value="1"/>
    <param name="Text Color" key="9999/101/101/3"
           value="1 1 1 1"/>
    <param name="Highlight Color" key="9999/101/101/4"
           value="1 0.85 0 1"/>
    <param name="Background Enabled" key="9999/101/101/5"
           value="1"/>
    <param name="Background Color" key="9999/101/101/6"
           value="0 0 0 0.7"/>
    <param name="Font Size" key="9999/101/101/7"
           value="80"/>

    <adjust-transform position="0 -200"/>
</title>
```

**For word-by-word highlight with Motion Templates**, the approach changes
significantly. Instead of generating one title per word (the current clip-layering
approach), we generate **one title per word per segment** but with a different
`Highlight Index` parameter:

```xml
<!-- Word 1 active -->
<title ref="r2" lane="1" name="Cap001_w1" offset="..." duration="...">
    <param name="Caption Text" value="THE QUICK BROWN"/>
    <param name="Highlight Index" value="0"/>  <!-- highlight "THE" -->
</title>

<!-- Word 2 active -->
<title ref="r2" lane="1" name="Cap001_w2" offset="..." duration="...">
    <param name="Caption Text" value="THE QUICK BROWN"/>
    <param name="Highlight Index" value="1"/>  <!-- highlight "QUICK" -->
</title>

<!-- Word 3 active -->
<title ref="r2" lane="1" name="Cap001_w3" offset="..." duration="...">
    <param name="Caption Text" value="THE QUICK BROWN"/>
    <param name="Highlight Index" value="2"/>  <!-- highlight "BROWN" -->
</title>
```

The Motion template's internal logic (using Text Sequence behaviors or
expression-based visibility) handles the visual highlighting based on the
parameter value.

**Alternative approach — single title per segment with keyframed parameter:**

If Motion supports keyframing published parameters via FCPXML:

```xml
<title ref="r2" lane="1" name="Cap001" offset="..." duration="...">
    <param name="Caption Text" value="THE QUICK BROWN"/>
    <param name="Highlight Index" key="9999/101/101/2">
        <keyframe time="0s" value="0"/>          <!-- highlight word 0 -->
        <keyframe time="800/2400s" value="1"/>   <!-- highlight word 1 -->
        <keyframe time="1600/2400s" value="2"/>  <!-- highlight word 2 -->
    </param>
</title>
```

This would reduce the clip count dramatically (one per segment instead of
one per word) but requires testing whether FCPXML supports keyframing
published Motion template parameters.

### Phase C: Pasteboard FCPXML Import

**Goal:** Use the existing pasteboard import path instead of SRT swizzling.

Already detailed in Phase 6 above. The key change:

```objc
// Replace lines 1589-1679 in generateCaptions with:
NSDictionary *importResult = SpliceKit_handlePasteboardImportXML(@{@"xml": xml});
```

### Phase D: Template Discovery & Management

**Goal:** Detect installed Motion Templates and let users browse/select them.

#### Template scanner

```objc
- (NSArray<NSDictionary *> *)discoverInstalledTemplates {
    NSString *templatesDir = [NSHomeDirectory()
        stringByAppendingPathComponent:
        @"Movies/Motion Templates.localized/Titles.localized/SpliceKit.localized"];

    NSArray *contents = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:templatesDir error:nil];

    NSMutableArray *templates = [NSMutableArray array];
    for (NSString *item in contents) {
        if ([item hasSuffix:@".localized"]) {
            NSString *motiPath = /* find .moti inside */;
            NSString *thumbPath = /* find thumbnail */;
            [templates addObject:@{
                @"name": [item stringByDeletingPathExtension],
                @"path": motiPath,
                @"uid": /* extract UID from moti bundle */,
                @"thumbnail": thumbPath ?: [NSNull null],
            }];
        }
    }
    return templates;
}
```

#### Font validation (from mCaptions)

mCaptions validates that fonts used by templates are installed:

```objc
- (BOOL)validateFontAvailability:(NSString *)fontName {
    NSFont *font = [NSFont fontWithName:fontName size:12];
    if (!font) {
        SpliceKit_log(@"[Captions] Font %@ used by template is unavailable", fontName);
        return NO;
    }
    return YES;
}
```

### Phase E: Hybrid Approach (Templates + Fallback)

**Goal:** Use Motion Templates when installed, fall back to Basic Title + text-style-def
when templates are not available.

```objc
- (NSDictionary *)generateCaptions {
    // Check if SpliceKit Motion Templates are installed
    NSArray *templates = [self discoverInstalledTemplates];
    NSDictionary *activeTemplate = [self templateForPresetID:self.style.presetID
                                                  templates:templates];

    if (activeTemplate) {
        // Motion Template path: reference template, pass parameters
        return [self generateCaptionsWithMotionTemplate:activeTemplate];
    } else {
        // Fallback path: Basic Title + text-style-def (current approach)
        return [self generateCaptionsWithBasicTitle];
    }
}
```

This ensures the caption system works everywhere, with enhanced visual quality
when templates are installed.

---

## 27. Architecture Comparison: How SpliceKit Wins

```
mCaptions Architecture:
┌─────────┐    ┌──────────┐    ┌──────────┐    ┌─────────┐
│  FCP    │◄──►│ Extension│◄──►│  Daemon  │    │ Motion  │
│  Host   │ProEx│   UI    │ XPC│ Whisper  │    │Templates│
│         │    │  Models  │    │ Generate │───►│ .moti   │
│Pasteboard│   │  XPC Mgr │    │ FCPXML   │    │         │
└─────────┘    └──────────┘    └──────────┘    └─────────┘
    3 processes, XPC serialization, daemon lifecycle management

SpliceKit Architecture:
┌─────────────────────────────────────────────────────────┐
│  FCP Process (everything in one address space)           │
│                                                         │
│  ┌─────────────┐  ┌─────────────┐  ┌────────────────┐ │
│  │ SpliceKit   │  │ Caption     │  │ Transcript     │ │
│  │ Server      │  │ Panel       │  │ Panel          │ │
│  │ (JSON-RPC)  │──│ (FCPXML gen)│──│ (Parakeet ASR) │ │
│  └─────────────┘  └──────┬──────┘  └────────────────┘ │
│                          │                              │
│                  ┌───────┴───────┐                      │
│                  │ Pasteboard    │                      │
│                  │ FCPXML Import │                      │
│                  │ (direct ObjC) │                      │
│                  └───────────────┘                      │
│                                                         │
│  Direct access to: FFAnchoredTimelineModule, NSApp,     │
│  NSPasteboard, IXXMLPasteboardType, GPU (Metal/ANE)    │
└─────────────────────────────────────────────────────────┘
    1 process, zero IPC overhead, direct runtime access
```

**SpliceKit's approach eliminates:**
- XPC serialization/deserialization overhead
- Daemon process launch, health monitoring, and restart logic
- ProExtension protocol negotiation
- Workflow Extension sandbox restrictions
- The need for mCaptionsLauncher, mCaptionsTerminator helper apps
- State synchronization between 3 separate processes

**SpliceKit adds:**
- Direct `objc_msgSend` access to all 78,000+ FCP classes
- Automatic timeline property detection (no manual settings)
- Real-time playhead tracking for live caption preview
- Direct NSPasteboard access for instant FCPXML import
- In-process GPU access for transcription (no XPC GPU proxy)

---

## 28. Implementation Roadmap

Combining the social media caption plan (Part II) with the mCaptions replication
plan (Part III):

```
NOW ─────────────────────────────────────────────────────────────► FUTURE

Phase 1: Social Defaults        ← 1 day     (change maxWords=3, fontSize=100)
Phase 6: Pasteboard Import      ← 1 day     (replace SRT swizzle with 1 function call)
Phase 2: Clip-Layer Animations  ← 3 days    (pop/fade/bounce via overlapping titles)
Phase 3: Background Box (chars) ← 2 days    (block char titles on lane 1, text on lane 2)
Phase 4: Smart Segmentation     ← 1 day     (social grouping mode)
Phase A: Motion Templates       ← 1 week    (design in Motion, publish parameters)
Phase B: Template FCPXML Gen    ← 3 days    (param-based generation, template discovery)
Phase E: Hybrid Fallback        ← 1 day     (template if installed, Basic Title otherwise)
Phase 5: Active Word Scale      ← 3 days    (per-word titles with font metrics)
Phase 8: Speaker Styling        ← 2 days    (color-per-speaker from diarization)
Phase D: Template Management    ← 2 days    (scanner, font validation, UI)
```

**Critical path:** Phase 1 → Phase 6 → Phase 2 → Phase 3 → Phase A → Phase B → Phase E

The early phases (1, 6, 2, 3) produce an mCaptions-equivalent result using
only FCPXML clip layering — no Motion Templates needed. The later phases
(A, B, E) add Motion Template support for premium visual quality that matches
or exceeds mCaptions.

---

## 29. Files to Create or Modify

| File | Action | Purpose |
|------|--------|---------|
| `Sources/SpliceKitCaptionPanel.m` | Modify | Default changes, pasteboard import, animation generation, background box, template support |
| `Sources/SpliceKitCaptionPanel.h` | Modify | New properties (showBackground, templatePath), new enum values |
| `Sources/SpliceKitServer.m` | Modify | New RPC methods for template management |
| `mcp/server.py` | Modify | New MCP tools, updated defaults |
| `templates/Bold Pop.motn` | Create | Motion project for Bold Pop template |
| `templates/Neon Glow.motn` | Create | Motion project for Neon Glow template |
| `templates/Social Reels.motn` | Create | Motion project for Social Reels template |
| `tools/install-caption-templates.sh` | Create | Script to install Motion templates to ~/Movies/ |
| `docs/CAPTION_TEMPLATES_GUIDE.md` | Create | Guide for designing custom Motion templates |
