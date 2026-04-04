# FCP Pasteboard & Media Linking: Restoring Clips with Attributes

## The Problem

When building an extension that saves SFX (or any clips) from the FCP timeline and later restores them, you hit a fundamental conflict in how Final Cut Pro handles clipboard data:

**Path A — Paste via file URL**: FCP accepts the file and places the clip on the timeline, but **ignores saved volume, effects, and other attributes**. It treats the URL as a fresh media import and creates a new clip with default properties.

**Path B — Paste stored FCP clipboard data**: The native clipboard data has volume, effects, and attributes baked in, but FCP **rejects it if the referenced media file isn't already linked in the project**. The clip appears offline.

The root cause is that FCP's native clipboard format stores **media references** (document IDs, parent object IDs, persistent IDs), not the actual media. At paste time, FCP resolves these references against the current project library. If the media isn't linked, resolution fails.

---

## How FCP's Pasteboard System Works

### Three-Layer Architecture

1. **IXXMLPasteboardType** (Interchange framework) — Defines UTI type strings for FCPXML data on the pasteboard. Class methods like `current`, `previous`, `generic`, `string` each return a UTI string for a specific FCPXML version.

2. **FFPasteboardItem** (Flexo framework) — The serialized clipboard item. Implements `NSPasteboardWriting`, `NSPasteboardReading`, and `NSSecureCoding`. Stores encoded clip data as a property list.

3. **FFPasteboard** (Flexo framework) — The coordinator with 76 methods. Reads/writes `FFPasteboardItem` objects to/from the underlying `NSPasteboard`.

### Native Clipboard Data Format

When FCP writes clips to the pasteboard, `FFPasteboardItem` serializes them as an `NSPropertyList` dictionary with these keys:

| Key | Type | Purpose |
|-----|------|---------|
| `ffpasteboardobject` | NSData | FFCoder-encoded clip objects (the actual clip data with all attributes) |
| `ffpasteboardcopiedtypes` | NSDictionary | Metadata about what was copied (`anchoredObject`, `edit`, `media`, etc.) |
| `ffpasteboarddocumentID` | NSString | Source library's unique identifier |
| `ffpasteboardparentobjectID` | NSString | Parent container's persistent ID |
| `ffpasteboardoptions` | NSDictionary | Paste options |
| `kffmodelobjectIDs` | NSArray | Object identifiers for lazy/promise resolution |

The `ffpasteboardobject` data is encoded by `FFCoder.encodeData:options:error:` with `FFXMLAssetUsageKey = 0`.

### The UTI Types

**Native (internal)**: `com.apple.flexo.proFFPasteboardUTI` (Pro version). A separate consumer/iMovie variant exists. A promise UTI also exists for deferred data loading.

**FCPXML (public, documented by Apple)**:
- **Generic**: `com.apple.finalcutpro.xml` — always supported
- **Version-specific** (FCP 10.5+): `com.apple.finalcutpro.xml.v1-8`, `.v1-9`, `.v1-10`, `.v1-11`, `.v1-12`, `.v1-13`, `.v1-14`
- FCP looks for the **highest version-specific type** first; falls back to generic if not found
- When writing, FCP places the current DTD version on both the generic type and all versioned types

These public UTI strings are what `IXXMLPasteboardType.current`, `.generic`, etc. return internally. You can use the public strings directly without runtime discovery.

### Readable Types (What FCP Accepts on Paste)

FCP's `+[FFPasteboard readableTypes]` registers these types in order:

1. `FFPasteboardUTI` (native FCP format — pro or consumer)
2. `NSPasteboardTypeURL` (file URLs)
3. `[IXXMLPasteboardType all]` (all FCPXML version UTIs — the `com.apple.finalcutpro.xml.*` types listed above)
4. `NSFilePromiseReceiver` readable types

---

## The Two Paste Paths (Critical Discovery)

FCP's core paste decoder (`_newObjectsWithProjectCore:assetFlags:fromURL:options:userInfoMap:`) has **two completely separate code paths**:

### Path 1: Native FFPasteboardItem

```
If pasteboard contains FFPasteboardUTI type:
  1. Read FFPasteboardItem objects from pasteboard
  2. Resolve documentID against open library documents
  3. Decode via FFCoder → FCP model objects
  4. If documentID doesn't match current library → OFFLINE / FAIL
```

This is why your stored clipboard data fails — the `documentID` and `parentObjectID` reference a library state that no longer matches, or the media asset isn't registered in the current project.

### Path 2: FCPXML on Pasteboard

```
If pasteboard does NOT contain FFPasteboardItem
  BUT pasteboard contains XML (IXXMLPasteboardType):
    1. Create FFXMLTranslationTask from pasteboard data
    2. Validate contentType == sequence/clip data
    3. Create FFXMLImportOptions:
       - incrementalImport = YES (adds to existing library)
       - conflictResolutionType = 3 (merge, don't replace)
       - Target = current project's defaultMediaEvent
    4. Run importClipsWithOptions:taskDelegate:
    5. MEDIA IS AUTOMATICALLY IMPORTED from src= URLs
    6. Return imported clips as FigTimeRangeAndObject items
```

**This is the key**: when FCP finds FCPXML on the pasteboard instead of native `FFPasteboardItem` data, it runs the **full XML import pipeline** — which handles media file linking automatically.

---

## Solution 1: FCPXML Pasteboard (Recommended)

Write FCPXML data directly to `NSPasteboard` using `IXXMLPasteboardType` UTI strings. FCP's XML paste path will import the media and preserve all attributes declared in the XML.

### Step 1: Use the Public FCPXML Pasteboard UTI

Apple documents these pasteboard types publicly. No runtime discovery needed:

```objc
// Public UTI strings — documented by Apple for workflow extensions and drag-and-drop
NSString *genericType = @"com.apple.finalcutpro.xml";           // Always works
NSString *versionType = @"com.apple.finalcutpro.xml.v1-11";    // Version-specific

// Alternatively, resolve at runtime from FCP's Interchange framework:
Class IXType = objc_getClass("IXXMLPasteboardType");
NSString *currentType = [IXType performSelector:@selector(current)];
NSArray  *allTypes    = [IXType performSelector:@selector(all)];
```

FCP checks for the highest version-specific type first, then falls back to generic. For maximum compatibility, write to both the versioned type and the generic type.

### Step 2: Build FCPXML with Asset + Attributes

```objc
NSString *fcpxml = [NSString stringWithFormat:
    @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    @"<!DOCTYPE fcpxml>\n"
    @"<fcpxml version=\"1.11\">\n"
    @"  <resources>\n"
    @"    <format id=\"r0\" frameDuration=\"1/24s\" width=\"1920\" height=\"1080\"/>\n"
    @"    <asset id=\"r1\" hasAudio=\"1\" hasVideo=\"0\"\n"
    @"           audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\">\n"
    @"      <media-rep kind=\"original-media\" src=\"%@\"/>\n"
    @"    </asset>\n"
    @"  </resources>\n"
    @"  <library>\n"
    @"    <event name=\"Restored SFX\">\n"
    @"      <project name=\"_paste_temp\">\n"
    @"        <sequence format=\"r0\" duration=\"%@\">\n"
    @"          <spine>\n"
    @"            <asset-clip ref=\"r1\" name=\"%@\" duration=\"%@\"\n"
    @"                        start=\"0s\" format=\"r0\"\n"
    @"                        audioRole=\"effects\">\n"
    @"              <adjust-volume amount=\"%@dB\"/>\n"
    @"            </asset-clip>\n"
    @"          </spine>\n"
    @"        </sequence>\n"
    @"      </project>\n"
    @"    </event>\n"
    @"  </library>\n"
    @"</fcpxml>",
    fileURL,          // file:///path/to/sfx.wav
    durationStr,      // e.g., "240/24s" or "10s"
    clipName,         // display name
    durationStr,      // clip duration
    volumeStr];       // e.g., "-6" for -6dB
```

> **Note**: The `<media-rep>` element inside `<asset>` is the official way to reference media files (per Apple's FCPXML spec). The `kind="original-media"` attribute tells FCP this is the original source file. The `audioRole` attribute on `<asset-clip>` assigns the audio role (e.g., `dialogue`, `music`, `effects`).

FCPXML supports a wide range of attributes:

```xml
<!-- Volume -->
<adjust-volume amount="-6dB"/>

<!-- Audio Panning (mode: 0=Default, 1=Stereo L/R, 2=Create Space, 3=Dialogue, 4=Music, 5=Ambience) -->
<adjust-panner mode="1" amount="-50"/>

<!-- Effects (ref points to an effect resource) -->
<filter-video ref="r2" name="Gaussian Blur">
    <param name="Amount" key="9999/gaussianBlur/radius" value="10"/>
</filter-video>
<filter-audio ref="r3" name="Channel EQ">
    <data key="effectData">[base64-encoded AU state]</data>
</filter-audio>

<!-- Transform (position/scale as % of frame height, rotation in degrees) -->
<adjust-transform position="100 50" scale="1.2 1.2" rotation="15" anchor="0 0"/>

<!-- Opacity / Blend Mode (amount: 0.0-1.0, mode: integer — see blend mode table) -->
<adjust-blend amount="0.75" mode="14"/>
```

### Step 3: Write to Pasteboard

```objc
NSData *xmlData = [fcpxml dataUsingEncoding:NSUTF8StringEncoding];
NSPasteboard *pb = [NSPasteboard generalPasteboard];
[pb clearContents];

// Write to both generic and version-specific types for maximum compatibility
[pb setData:xmlData forType:@"com.apple.finalcutpro.xml"];
[pb setData:xmlData forType:@"com.apple.finalcutpro.xml.v1-11"];
```

### Step 3 (Alternative): Use the Official Promise Pattern

Apple's documented approach for workflow extensions uses `NSPasteboardItemDataProvider` to lazily provide FCPXML data. This is the official way to drag clips into FCP:

```objc
// In your data provider class:
@interface MyPasteboardProvider : NSObject <NSPasteboardItemDataProvider>
@property (nonatomic, copy) NSString *fcpxml;
@end

@implementation MyPasteboardProvider
- (void)pasteboard:(NSPasteboard *)pasteboard
              item:(NSPasteboardItem *)item
provideDataForType:(NSPasteboardType)type {
    NSData *xmlData = [self.fcpxml dataUsingEncoding:NSUTF8StringEncoding];
    [item setData:xmlData forType:type];
}
@end

// Usage:
NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
MyPasteboardProvider *provider = [[MyPasteboardProvider alloc] init];
provider.fcpxml = fcpxml;
[pbItem setDataProvider:provider
               forTypes:@[@"com.apple.finalcutpro.xml",
                          @"com.apple.finalcutpro.xml.v1-11"]];

NSPasteboard *pb = [NSPasteboard generalPasteboard];
[pb clearContents];
[pb writeObjects:@[pbItem]];
```

This is particularly useful for drag-and-drop: FCP requests the FCPXML only when the drop occurs, not when the drag starts.

### Step 4: Trigger Paste

Either let the user Cmd+V, or programmatically:

```objc
id timelineModule = /* get active FFAnchoredTimelineModule */;
[timelineModule performSelector:@selector(paste:) withObject:nil];
```

### What Happens Internally

1. FCP checks for `FFPasteboardItem` → not found
2. Checks for XML types via `containsXML` → found (your FCPXML data)
3. `FFXMLTranslationTask` reads the XML, tries types in order: `current`, `previous`, `previousPrevious`, `generic`, falls back to `string`
4. Parses with `FFXML.importXMLData:version:contentType:error:`
5. Creates `FFXMLImportOptions` with `incrementalImport:YES`, `conflictResolutionType:3`
6. Sets target to the current project's `defaultMediaEvent`
7. Runs `importClipsWithOptions:taskDelegate:` — this resolves the `src=` URL, imports the media file, creates `FFAsset` entries
8. Returns imported clips ready for timeline insertion

### FCP Drop/Paste Behavior (per Apple docs)

How FCP handles FCPXML content depends on what the XML describes:

| FCPXML Contains | FCP Does |
|-----------------|----------|
| Clips dragged to timeline | Adds to event containing open project; inserts at drop/playhead point |
| Events | Merges into library; handles naming conflicts with numerical suffixes |
| Clips/projects to event | Adds items; prompts on name conflicts |
| Clips/projects to library | Creates dated event (e.g., "06-29-19"); adds items |
| Library | Merges all content using naming conflict rules |

### Advantages

- Single operation: media import + attribute restoration in one paste
- No offline clips — FCP handles media linking through its standard XML import pipeline
- Volume, effects, transforms, roles all survive via FCPXML attributes
- Incremental import — merges into existing project, doesn't create a new library
- Conflict resolution set to merge — safe for repeated operations

### Limitations

- Only attributes expressible in FCPXML are preserved (covers most common ones)
- Very complex custom effect parameters may require additional FCPXML authoring
- The paste creates a temporary project/event structure; clips land in the timeline but an event may also appear in the library sidebar

---

## Solution 2: Two-Step Import Then Paste (Fallback)

If you need to preserve the exact native clipboard data (with complex attributes that FCPXML can't express), import the media first so the native paste succeeds.

### Step 1: Import Media to Library

Import the file into the current project's library so FCP creates an `FFAsset` for it:

```objc
// Option A: Via FFPasteboard with URL
NSPasteboard *tempPB = [NSPasteboard pasteboardWithUniqueName];
[tempPB clearContents];
[tempPB writeObjects:@[[NSURL fileURLWithPath:sfxFilePath]]];

Class FFPasteboardClass = objc_getClass("FFPasteboard");
id ffpb = [[FFPasteboardClass alloc]
    performSelector:@selector(initWithPasteboard:) withObject:tempPB];

id timelineModule = /* active timeline module */;
id sequence = [timelineModule performSelector:@selector(sequence)];

// This imports the media into the project library
[ffpb performSelector:@selector(newMediaWithSequence:fromURL:options:)
           withObject:sequence withObject:nil withObject:nil];
```

```objc
// Option B: Via FCPXML file import (more reliable)
// Write a minimal FCPXML to a temp file, then:
id appController = [NSApp performSelector:@selector(delegate)];
NSURL *xmlURL = /* temp FCPXML file URL */;
[appController performSelector:@selector(openXMLDocumentWithURL:bundleURL:display:sender:)
                    withObject:xmlURL withObject:nil withObject:@NO withObject:nil];
```

### Step 2: Patch documentID (If Needed)

Your stored clipboard data may have a `documentID` from a different library session. Patch it:

```objc
// Read the current library's unique identifier
id currentProject = /* current project */;
id projectDoc = [currentProject performSelector:@selector(projectDocument)];
NSString *currentDocID = [projectDoc performSelector:@selector(uniqueIdentifier)];

// Decode your stored plist, update the documentID, re-encode
NSMutableDictionary *plist = [NSPropertyListSerialization
    propertyListWithData:storedPlistData
    options:NSPropertyListMutableContainers
    format:NULL error:NULL];
plist[@"ffpasteboarddocumentID"] = currentDocID;

NSData *updatedData = [NSPropertyListSerialization
    dataFromPropertyList:plist
    format:NSPropertyListBinaryFormat_v1_0
    errorDescription:NULL];
```

### Step 3: Write Updated Data and Paste

```objc
NSPasteboard *pb = [NSPasteboard generalPasteboard];
[pb clearContents];

NSString *pasteboardUTI = @"com.apple.flexo.proFFPasteboardUTI";
[pb setData:updatedData forType:pasteboardUTI];

// Paste
[timelineModule performSelector:@selector(paste:) withObject:nil];
```

### Advantages

- Preserves the exact native clipboard data with all attributes
- Works for complex effect stacks that FCPXML can't fully express

### Limitations

- Two-step process — import may briefly flash media in the browser
- `documentID` patching is fragile; the internal `ffpasteboardobject` data (FFCoder-encoded) may also contain embedded references that need the correct library context
- The `ffpasteboardobject` is opaque FFCoder data — you can't easily modify individual attributes within it

---

## Solution 3: File URL + Programmatic Attribute Restore (Simplest Fallback)

The most pragmatic approach if you just need volume and a few properties.

### Step 1: Paste via File URL

```objc
// Write the file URL to the pasteboard
NSPasteboard *pb = [NSPasteboard generalPasteboard];
[pb clearContents];
[pb writeObjects:@[[NSURL fileURLWithPath:sfxFilePath]]];

// Paste — FCP imports and places the clip with default attributes
[timelineModule performSelector:@selector(paste:) withObject:nil];
```

### Step 2: Select and Restore Attributes

After paste, the clip is on the timeline with default properties. Restore saved attributes:

```python
# Via FCPBridge JSON-RPC:

# Select the just-pasted clip
timeline_action("selectClipAtPlayhead")

# Restore volume
set_inspector_property("volume", -6.0)

# Restore other properties
set_inspector_property("opacity", 0.75)
set_inspector_property("positionX", 100.0)
set_inspector_property("positionY", 50.0)

# Restore effects (if you saved effect IDs)
# Apply via menu or effect browser
execute_menu_command(["Edit", "Paste Effects"])
```

### Advantages

- Simple, well-understood, no pasteboard hacking
- Works reliably — URL paste always succeeds
- Each attribute restoration is individually verifiable

### Limitations

- Multi-step — possible timing issues between paste and attribute application
- Can't easily restore complex effect stacks with custom parameters
- Relies on inspector property access for each attribute

---

## Solution 4: Intercept with `mediaByReferenceOnly:NO` (Advanced)

The `newEditsWithProject:mediaByReferenceOnly:options:` method on `FFPasteboard` has a boolean flag that controls media resolution behavior.

When `mediaByReferenceOnly` is YES, it sets `assetFlags` bit 14 (0x4000), meaning "only create references, expect media already linked." When NO (assetFlags = 0), and the pasteboard contains file URLs, FCP enters a different code path that uses `FFFileImporter` to actually import the media files.

### How It Works

```objc
Class FFPasteboardClass = objc_getClass("FFPasteboard");
id ffpb = [[FFPasteboardClass alloc]
    performSelector:@selector(initWithPasteboard:)
         withObject:[NSPasteboard generalPasteboard]];

id project = /* current project */;

// Call with mediaByReferenceOnly:NO to trigger media import
id edits = [ffpb performSelector:@selector(newEditsWithProject:mediaByReferenceOnly:options:)
                      withObject:project
                      withObject:@NO     // force media import
                      withObject:nil];
```

### When This Works

This path activates when the pasteboard has **file URLs** alongside other data. It:

1. Validates URLs via `FFFileImporter.validateURLs:withURLsInfo:forImportToLocation:...`
2. Imports via `FFFileImporter.importToEvent:manageFileType:processNow:...`
3. Returns imported clips as `FigTimeRangeAndObject` items

### Limitations

- Only helps when file URLs are on the pasteboard — won't rescue pure native clipboard data with missing media
- The returned objects still need to be inserted into the timeline
- More complex to orchestrate than the FCPXML approach

---

## Comparison Matrix

| Approach | Media Import | Attributes Preserved | Complexity | Reliability |
|----------|-------------|---------------------|------------|-------------|
| **1. FCPXML Pasteboard** | Automatic | All FCPXML-expressible | Medium | High |
| **2. Import + Native Paste** | Manual first step | All (native format) | High | Medium (fragile IDs) |
| **3. URL + Attribute Restore** | Automatic | Manual per-property | Low | High |
| **4. mediaByReferenceOnly** | URL-dependent | Depends on source | High | Medium |

---

## Appendix A: Complete FCPXML Attribute Reference

All attributes below can be embedded in FCPXML for Solution 1. Based on Apple's official FCPXML DTD documentation.

### Asset Definition

```xml
<asset id="r1" uid="optional-unique-id"
       hasVideo="1" hasAudio="1"
       audioSources="1" audioChannels="2" audioRate="48000"
       videoSources="1"
       colorSpaceOverride="1-1-1"
       customLUTOverride="64 (Panasonic_VLog_VGamut)"
       projectionOverride="none"
       stereoscopicOverride="mono">
    <media-rep kind="original-media" src="file:///path/to/media.mov"/>
</asset>
```

**Color space triplets** (primaries-transfer-matrix): `1-1-1` (Rec. 709), `6-1-6` (Rec. 601 NTSC), `5-1-6` (Rec. 601 PAL), `9-1-9` (Rec. 2020), `9-16-9` (Rec. 2020 PQ), `9-18-9` (Rec. 2020 HLG).

### Audio Adjustments

```xml
<!-- Volume in dB -->
<adjust-volume amount="-6dB"/>

<!-- Volume with keyframe animation -->
<adjust-volume>
    <param name="amount">
        <keyframeAnimation>
            <keyframe time="0s" value="-12dB" curve="smooth"/>
            <keyframe time="2s" value="0dB" curve="smooth"/>
        </keyframeAnimation>
    </param>
</adjust-volume>

<!-- Panning (mode: 0=Default, 1=Stereo L/R, 2=Create Space, 3=Dialogue,
     4=Music, 5=Ambience, 6=Circle, 7=Rotate, 8=Back to Front,
     9=Left Surround to Right Front, 10=Right Surround to Left Front) -->
<adjust-panner mode="1" amount="-50"
    left_right_mix="0" front_back_mix="0" LFE_balance="0"
    surround_width="0" rotation="0" stereo_spread="0"/>

<!-- EQ -->
<adjust-EQ/>

<!-- Noise reduction (amount: 0-100) -->
<adjust-noiseReduction amount="50"/>

<!-- Hum reduction (frequency: 50 or 60 Hz) -->
<adjust-humReduction frequency="60"/>

<!-- Loudness -->
<adjust-loudness amount="0"/>

<!-- Match EQ (binary format) -->
<adjust-matchEQ>
    <data key="effectData">[base64]</data>
</adjust-matchEQ>
```

### Video Adjustments

```xml
<!-- Transform (position/scale as % of frame height, rotation in degrees) -->
<adjust-transform enabled="1"
    position="0 0" anchor="0 0" scale="1 1" rotation="0"
    tracking="tracking-shape-ref"/>

<!-- Opacity and blend mode (see blend mode table below) -->
<adjust-blend amount="1.0" mode="0"/>

<!-- Crop -->
<adjust-crop mode="trim" enabled="1">
    <crop-rect left="0" right="0" top="0" bottom="0"/>
</adjust-crop>

<!-- Corners (four-corner distortion) -->
<adjust-corners enabled="1"
    botLeft="0 0" botRight="0 0" topLeft="0 0" topRight="0 0"/>

<!-- Stabilization -->
<adjust-stabilization type="automatic"/>

<!-- Rolling shutter reduction -->
<adjust-rollingShutter amount="0"/>

<!-- Conform (how image fills frame) -->
<adjust-conform type="fit"/>
```

### Blend Mode Values

| Value | Mode | Value | Mode |
|-------|------|-------|------|
| 0 | Normal | 17 | Vivid Light |
| 2 | Subtract | 18 | Linear Light |
| 3 | Darken | 19 | Pin Light |
| 4 | Multiply | 20 | Hard Mix |
| 5 | Color Burn | 22 | Difference |
| 6 | Linear Burn | 23 | Exclusion |
| 8 | Add | 25 | Stencil Alpha |
| 9 | Lighten | 26 | Stencil Luma |
| 10 | Screen | 27 | Silhouette Alpha |
| 11 | Color Dodge | 28 | Silhouette Luma |
| 12 | Linear Dodge | 29 | Behind |
| 14 | Overlay | 31 | Alpha Add |
| 15 | Soft Light | 32 | Premultiplied Mix |
| 16 | Hard Light | | |

### Effects

```xml
<!-- Video filter (ref points to effect resource) -->
<filter-video ref="r2" name="Gaussian Blur">
    <param name="Amount" key="9999/gaussianBlur/radius" value="10"/>
</filter-video>

<!-- Audio filter -->
<filter-audio ref="r3" name="Channel EQ">
    <data key="effectData">[base64-encoded Audio Unit state]</data>
    <data key="effectConfig">[base64-encoded configuration]</data>
</filter-audio>

<!-- Color correction with ASC CDL (exports as XML comment) -->
<filter-video ref="r4" name="Color Correction">
    <!-- info-asc-cdl: slope="1.05 1.05 1.05" offset="0.0275 0.0275 0.0275" power="1.25 1.2 1" -->
</filter-video>

<!-- Masked filter (shape mask on video effect) -->
<filter-video ref="r5" name="Blur">
    <filter-video-mask>
        <mask-shape/>
    </filter-video-mask>
</filter-video>
```

### Speed / Retime

```xml
<!-- timeMap: maps output time → source time -->
<timeMap>
    <timept time="0s" value="0s" interp="smooth2"/>
    <timept time="10s" value="5s" interp="smooth2"/>  <!-- 50% speed -->
</timeMap>

<!-- Reverse playback -->
<timeMap>
    <timept time="0s" value="10s" interp="linear"/>
    <timept time="10s" value="0s" interp="linear"/>
</timeMap>

<!-- Frame sampling (for retime quality) -->
<frame-sampling value="floor"/>  <!-- or "nearest-neighbor", "frame-blending", "optical-flow" -->
```

### Markers, Keywords, Ratings

```xml
<!-- Standard marker -->
<marker start="3s" duration="1/24s" value="Important moment"/>

<!-- Chapter marker -->
<chapter-marker start="5s" duration="1/24s" value="Chapter 1"
    posterOffset="0s"/>

<!-- To-do marker -->
<marker start="8s" duration="1/24s" value="Fix audio">
    <marker-completion completed="0"/>
</marker>

<!-- Keywords -->
<keyword start="0s" duration="10s" value="SFX, Foley"/>

<!-- Rating (value: "favorite" or "reject") -->
<rating start="0s" duration="10s" value="favorite"/>

<!-- Audio role assignment -->
<audio-role-source role="dialogue.dialogue-1"/>
```

### Timing Attributes (All Story Elements)

Time values use rational seconds: `1001/30000s` (29.97fps), `1001/60000s` (59.94fps), or whole seconds `5s`.

```xml
<asset-clip ref="r1" name="Clip"
    offset="10s"       <!-- position in parent timeline -->
    start="5s"         <!-- start of local timeline -->
    duration="15s"     <!-- extent in parent time -->
    audioRole="effects"
    videoRole="video.video-1">
```

### 360 Video Adjustments

```xml
<adjust-360-transform enabled="1"/>
<adjust-orientation enabled="1"/>
<adjust-reorient enabled="1"/>
```

---

## Appendix B: Public Pasteboard Types & Discovery

### Known Public UTI Strings (Apple-Documented)

These are documented by Apple for workflow extensions and drag-and-drop integration:

| UTI String | Purpose |
|------------|---------|
| `com.apple.finalcutpro.xml` | Generic FCPXML — always supported |
| `com.apple.finalcutpro.xml.v1-8` | FCPXML 1.8 (FCP 10.4) |
| `com.apple.finalcutpro.xml.v1-9` | FCPXML 1.9 (FCP 10.4.1) |
| `com.apple.finalcutpro.xml.v1-10` | FCPXML 1.10 (FCP 10.5) |
| `com.apple.finalcutpro.xml.v1-11` | FCPXML 1.11 (FCP 10.6) |
| `com.apple.finalcutpro.xml.v1-12` | FCPXML 1.12 |
| `com.apple.finalcutpro.xml.v1-13` | FCPXML 1.13 |
| `com.apple.finalcutpro.xml.v1-14` | FCPXML 1.14 |

**Best practice** (per Apple docs): Support the generic type (current DTD at your release) and also version-specific types for current and previous DTD versions.

### Runtime Discovery (Optional)

If you want to confirm what the running FCP version supports:

```objc
// From within FCP's process (e.g., via injected dylib or FCPBridge)
Class IXType = objc_getClass("IXXMLPasteboardType");

NSLog(@"=== IXXMLPasteboardType UTIs ===");
NSLog(@"current:          %@", [IXType current]);
NSLog(@"previous:         %@", [IXType previous]);
NSLog(@"previousPrevious: %@", [IXType previousPrevious]);
NSLog(@"generic:          %@", [IXType generic]);
NSLog(@"string:           %@", [IXType string]);
NSLog(@"all:              %@", [IXType all]);
```

### Paste Priority Order

FCP's `FFXMLTranslationTask` checks pasteboard types in this order:
1. `IXXMLPasteboardType.current` (highest version)
2. `IXXMLPasteboardType.previous`
3. `IXXMLPasteboardType.previousPrevious`
4. `IXXMLPasteboardType.generic`
5. Falls back to `IXXMLPasteboardType.string` (reads as plain text, converts to data)

When writing, use both the generic type and the version-specific type matching your FCPXML version for maximum compatibility.

---

## Appendix C: Key Internal Classes

| Class | Methods | Role |
|-------|---------|------|
| `FFPasteboard` | 76 | Clipboard read/write coordinator |
| `FFPasteboardItem` | ~20 | Serialized clipboard item (NSPasteboardWriting/Reading) |
| `FFPasteboardItemPromise` | ~15 | Lazy-loaded clipboard data (NSPasteboardItemDataProvider) |
| `FFXMLTranslationTask` | ~10 | Converts FCPXML pasteboard data for import |
| `FFXMLImportOptions` | ~15 | Configuration for XML import (incremental, conflict resolution) |
| `FFFileImporter` | ~20 | File-based media import |
| `IXXMLPasteboardType` | 18 | FCPXML pasteboard UTI type definitions |
| `FFCoder` | ~10 | Encodes/decodes FCP model objects to NSData |

---

## Appendix D: Workflow Extension Timeline API

If you're building a workflow extension (`.appex`), you have official API access to the FCP timeline. This is relevant for Solution 3 (programmatic attribute restoration) and for monitoring when clips are pasted.

### Timeline Access Pattern

```swift
import ProExtension

// 1. Get host singleton
guard let host = ProExtensionHostSingleton() as? FCPXHost else { return }

// 2. Access timeline
guard let timeline = host.timeline else { return }

// 3. Register for changes
timeline.add(self) // self conforms to FCPXTimelineObserver

// 4. Read current state
let sequence = timeline.activeSequence       // FCPXSequence?
let playhead = timeline.playheadTime()       // CMTime
let range = timeline.sequenceTimeRange       // CMTimeRange

// 5. Move playhead
let newPos = timeline.movePlayhead(to: targetTime)  // returns confirmed CMTime
```

### Observer Callbacks

```swift
extension MyViewController: FCPXTimelineObserver {
    func activeSequenceChanged() {
        // New sequence loaded — refresh UI
        let seq = host.timeline?.activeSequence
        print("Sequence: \(seq?.name), duration: \(seq?.duration)")
    }
    
    func playheadTimeChanged() {
        // Playhead moved (click, drag, or playback stop — NOT during playback)
        let time = host.timeline?.playheadTime()
    }
    
    func sequenceTimeRangeChanged() {
        // Timeline bounds changed
        let range = host.timeline?.sequenceTimeRange
    }
}
```

### Navigating the Container Hierarchy

```swift
let sequence = timeline.activeSequence          // FCPXSequence
let project = sequence?.container as? FCPXProject  // FCPXProject
let event = project?.container as? FCPXEvent       // FCPXEvent (uid, name)
let library = event?.container as? FCPXLibrary     // FCPXLibrary (url, name)
```

### Security-Scoped Bookmarks

If your extension needs to access media files on disk, you need security-scoped bookmark entitlements:

```xml
<!-- In your .entitlements file -->
<key>com.apple.security.files.bookmarks.app-scope</key>
<true/>
<key>com.apple.security.files.bookmarks.document-scope</key>
<true/>
```

When receiving bookmark data (e.g., from FCPXML drag-out from FCP):
1. Decode Base64-encoded bookmark data
2. Resolve to security-scoped URL with `NSURLBookmarkResolutionWithSecurityScope`
3. Call `startAccessingSecurityScopedResource()` before file access
4. Call `stopAccessingSecurityScopedResource()` when done

### Key Limitations

- Workflow extensions run **out-of-process** — no direct access to FCP's internal classes
- The `FCPXTimeline` API is read-only for sequence/playhead; you can move the playhead but can't directly modify clips
- To modify the timeline, you must go through FCPXML (paste/import) or Apple Events
- FCP terminates extensions when the floating window closes — save state to persistent storage

---

## Appendix E: Debugging Pasteboard Contents

To inspect what's currently on the pasteboard:

```objc
NSPasteboard *pb = [NSPasteboard generalPasteboard];
NSLog(@"Types on pasteboard: %@", [pb types]);

for (NSString *type in [pb types]) {
    NSData *data = [pb dataForType:type];
    NSLog(@"Type: %@ — %lu bytes", type, (unsigned long)data.length);
    
    // Try to decode as plist (works for FFPasteboardItem data)
    id plist = [NSPropertyListSerialization
        propertyListWithData:data
        options:0 format:NULL error:NULL];
    if (plist) {
        NSLog(@"  Plist: %@", plist);
    }
    
    // Try to decode as string (works for FCPXML string type)
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (str && str.length < 2000) {
        NSLog(@"  String: %@", str);
    }
}
```

This is especially useful for capturing what FCP writes to the pasteboard when you copy a clip — you can see the exact structure of `ffpasteboardobject`, `ffpasteboardcopiedtypes`, `ffpasteboarddocumentID`, etc.
