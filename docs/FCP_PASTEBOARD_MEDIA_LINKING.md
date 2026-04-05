# FCP Pasteboard & Media Linking: Restoring Clips with Attributes

> **Tested**: April 2026, FCP 11.1, macOS Sequoia 15.4. Findings from programmatic
> testing via NSPasteboard (Swift) + AppleScript automation against a live FCP instance.

---

## Tested Findings Summary

### What Works

| Approach | Result |
|----------|--------|
| FCPXML on `com.apple.finalcutpro.xml` (generic UTI) | **Works** — media imported, project created |
| FCPXML on generic + versioned UTIs (recommended) | **Works** |
| FCPXML version 1.14 with `v1-14` UTI | **Works** |
| FCPXML audio clip with `adjust-volume` | **Works** — volume restored via bridge post-import |
| FCPXML video clip with `adjust-volume` | **Works** — video + audio imported correctly |
| FCPXML with `audioRole="effects"` | **Works** |
| FCPXML with multiple clips (3 different assets) | **Works** — all clips imported |
| FCPXML with `<marker>` and `<chapter-marker>` | **Works** — markers preserved at correct times (verified via nextMarker navigation) |
| FCPXML with connected clips (`lane="1"`) | **Works** — primary + connected clip imported |
| FCPXML with `<timeMap>` (retiming/speed) | **Works** — clip imported (speed verification pending) |
| Volume restore via `inspector.set` after import | **Works** — `inspector.set("volume", -8)` confirmed |

### What Doesn't Work

| Approach | Result |
|----------|--------|
| Version-specific UTI alone (e.g., `v1-11` without generic) | Paste NOT enabled |
| FCPXML as `public.utf8-plain-text` | Paste NOT enabled |
| `adjust-blend` (opacity) on audio-only clip | **Import fails** — "The dragged XML could not be imported" |
| `adjust-blend` on video clip | **Import fails** — same error (even with valid video asset) |
| File URL paste via bridge `paste:` | **Does not add clips** — bridge paste: ignores URLs |
| `newEditsWithProject:mediaByReferenceOnly:` | **Crashes FCP** — causes TLKMarkerLayer exception |
| Multi-clip per-clip volume (different volumes each) | **Partial** — all clips imported but bridge applies last volume to all selected |
| `adjust-volume` preserved by import itself | **No** — always defaults to 0dB, must use post-import `inspector.set` |

### Crashes Found

- **Markers + layout**: Importing FCPXML with markers can crash FCP during timeline layout.
  Crash in `TLKMarkerLayer layoutSublayers` → `CALayer setPosition:` with NaN/Inf position.
  The markers are imported correctly (verified via `nextMarker`) but can crash on render.
- **`newEditsWithProject:mediaByReferenceOnly:options:`**: Calling this on FFPasteboard with FCPXML
  data crashes FCP. This method is not a viable path for timeline insertion.

### Native Clipboard Format (Corrections from Testing)

When FCP copies a clip, the pasteboard contains **exactly one type**: `com.apple.flexo.proFFPasteboardUTI`.
No FCPXML types are written. No promise types.

The plist has **only 3 keys** (not 6 as originally documented):

| Key | Observed |
|-----|----------|
| `ffpasteboardobject` | **NSKeyedArchiver** binary plist (15K+ bytes), NOT FFCoder |
| `ffpasteboardcopiedtypes` | e.g., `{"pb_anchoredObject": {"count": 1}}` |
| `kffmodelobjectIDs` | Empty array `[]` |

**Not observed at top level**: `ffpasteboarddocumentID`, `ffpasteboardparentobjectID`, `ffpasteboardoptions`.
The library document ID IS embedded inside the `ffpasteboardobject` NSKeyedArchiver data (confirmed by
finding the library UUID `2418FDEA-...` matching the active library).

The NSKeyedArchiver data contains 265 objects including these classes:
`FFAnchoredMediaComponent`, `FFAnchoredCollection`, `FFAsset`, `FFAssetRef`, `FFEffectStack`,
`FFHeColorEffect`, `FFHeConformEffect`, `FFIntrinsicColorConformEffect`, `FFMediaRep`,
`FFMediaResource`, `FFMediaResourceMap`, `FFAudioClipComponentsLayoutMap`, `FFObjectDict`.

### Behavioral Notes

- **No new event created**: FCPXML paste with `<library><event name="Paste Test">` does NOT create
  a visible event in the sidebar. Clips are appended directly to the current timeline's spine.
- **Undo name varies**: FCP reports the paste as "Append to Storyline" or "Add Media" depending
  on timeline state and whether a project was active.
- **Generic UTI is required**: The versioned UTI (e.g., `com.apple.finalcutpro.xml.v1-11`) alone
  is NOT sufficient — FCP's paste handler requires the generic `com.apple.finalcutpro.xml`.
- **Attribute preservation FAILED**: Inspector verification (via flexo bridge) confirms that
  `adjust-volume amount="-10dB"` in FCPXML is **NOT applied** after import. The clip's volume
  reads as 1.0 (0dB) — default. The import creates the project/clip correctly but ignores
  per-clip adjustments like volume. This means Solution 1's FCPXML attributes require
  post-import restoration via `set_inspector_property()` (same as Solution 3).
- **Bridge `paste:` doesn't handle FCPXML**: The bridge's `timeline.action("paste")` sends `paste:`
  to the editor container, which only handles native `FFPasteboardItem` data. FCPXML on the pasteboard
  is silently ignored. **Fix added**: The bridge now detects FCPXML on the pasteboard and routes
  through `FFXMLTranslationTask.initForPasteboard:` + `importClipsWithOptions:` instead.
- **`fcpxml.import` triggers library dialog**: The `openXMLDocumentWithURL:` path shows a blocking
  "Which library?" dialog. The new `fcpxml.pasteImport` method bypasses this by importing directly
  into the current project's event.
- **FFPasteboard readable types (FCP 11.1)**: v1-12, v1-13, v1-14 only. v1-11 and earlier are NOT
  in the readable types list. Use v1-14 for current FCP versions.
- **`containsXML` confirmed working**: NSPasteboard extension from Interchange framework correctly
  detects FCPXML data. `isNative` correctly returns NO for non-native content.

---

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

When FCP writes clips to the pasteboard, `FFPasteboardItem` serializes them as an `NSPropertyList` dictionary.

**Observed keys** (tested April 2026, FCP 11.1):

| Key | Type | Purpose |
|-----|------|---------|
| `ffpasteboardobject` | NSData | **NSKeyedArchiver**-encoded clip objects (all attributes, media refs, effects) |
| `ffpasteboardcopiedtypes` | NSDictionary | Metadata about what was copied (e.g., `{"pb_anchoredObject": {"count": 1}}`) |
| `kffmodelobjectIDs` | NSArray | Object identifiers for lazy/promise resolution (observed: empty array) |

**Not observed at top level** (may appear in other copy contexts or older FCP versions):

| Key | Type | Purpose |
|-----|------|---------|
| `ffpasteboarddocumentID` | NSString | Source library's unique identifier (embedded inside `ffpasteboardobject` instead) |
| `ffpasteboardparentobjectID` | NSString | Parent container's persistent ID |
| `ffpasteboardoptions` | NSDictionary | Paste options |

> **Correction**: The `ffpasteboardobject` data uses **NSKeyedArchiver** (binary plist with `$version`,
> `$archiver`, `$top`, `$objects` keys), not FFCoder. The archive contains a full object graph with
> classes like `FFAnchoredMediaComponent`, `FFAsset`, `FFEffectStack`, etc. The library document ID
> is embedded inside this archive, not as a separate top-level key.

### The UTI Types

**Native (internal)**: `com.apple.flexo.proFFPasteboardUTI` (Pro version). A separate consumer/iMovie variant exists. A promise UTI also exists for deferred data loading.

**FCPXML (public, documented by Apple)**:
- **Generic**: `com.apple.finalcutpro.xml` — always supported
- **Version-specific** (FCP 10.5+): `com.apple.finalcutpro.xml.v1-8`, `.v1-9`, `.v1-10`, `.v1-11`, `.v1-12`, `.v1-13`, `.v1-14`
- FCP looks for the **highest version-specific type** first; falls back to generic if not found
- When writing, FCP places the current DTD version on both the generic type and all versioned types
- **Tested**: The generic UTI `com.apple.finalcutpro.xml` is **required** for paste. A version-specific
  UTI alone (e.g., only `com.apple.finalcutpro.xml.v1-11`) does NOT enable FCP's paste command.

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
  3. Decode via NSKeyedUnarchiver → FCP model objects
  4. If documentID doesn't match current library → OFFLINE / FAIL
```

> **Tested**: When FCP copies a clip, it places **exactly one type** on the pasteboard:
> `com.apple.flexo.proFFPasteboardUTI`. No FCPXML types, no promise types, no file URLs.
> The data is 15K+ bytes of NSKeyedArchiver-encoded objects (not FFCoder).

This is why stored clipboard data fails — the `documentID` (embedded inside the NSKeyedArchiver
data) and other object references target a library state that no longer matches, or the media
asset isn't registered in the current project.

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

## Solution 1: FCPXML Pasteboard (Recommended) ✅ TESTED

Write FCPXML data directly to `NSPasteboard` using `IXXMLPasteboardType` UTI strings. FCP's XML paste path will import the media and preserve all attributes declared in the XML.

> **Tested April 2026**: This approach works. FCPXML on the generic pasteboard UTI
> `com.apple.finalcutpro.xml` enables FCP's paste command and triggers the "Append to Storyline"
> or "Add Media" undo action. Tested with audio files (system sounds), volume adjustments,
> opacity, and audioRole attributes. No new events are created in the sidebar — clips go
> directly into the active timeline's spine.

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

> **Tested**: The generic UTI is **mandatory**. Writing only `com.apple.finalcutpro.xml.v1-11`
> (without the generic type) leaves FCP's Paste menu item disabled. Always include the generic type.

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

> **Tested behavior**: Steps confirmed. The entire cycle takes ~2 seconds for a small audio
> file. The undo action is "Append to Storyline" (sometimes "Add Media"). No separate event
> is created in the library sidebar despite the FCPXML containing `<event name="Paste Test">` —
> the clips are merged directly into the active timeline.

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

- **Tested**: Media import works — clips are created with correct media references
- **Tested**: No offline clips — FCP resolves `src=` URLs and imports media automatically
- **Tested**: No library selection dialog when `setLibrary:` is set on FFXMLImportOptions
- **Tested**: Incremental import — merges into existing library

### Limitations

- **Tested**: Per-clip attributes (`adjust-volume`, `adjust-blend`, etc.) are **NOT preserved** by the import.
  Inspector shows default values (volume=1.0, opacity=1.0) after import despite FCPXML containing adjustments.
  Attributes must be restored programmatically after import via `set_inspector_property()`.
- **Tested**: Import creates a **new project/sequence** — it does NOT insert clips into the current timeline.
  Each import creates a new project entry in the library sidebar.
- **Tested**: The generic UTI `com.apple.finalcutpro.xml` must always be included. Versioned UTI alone doesn't work.
- Very complex custom effect parameters may require additional FCPXML authoring.

---

## Solution 2: Two-Step Import Then Paste (Fallback) — NOT TESTED

If you need to preserve the exact native clipboard data (with complex attributes that FCPXML can't express), import the media first so the native paste succeeds.

> **Note**: This approach requires modifying internal FCP data structures. The native clipboard
> format uses NSKeyedArchiver (not FFCoder as originally assumed), making the `ffpasteboardobject`
> data harder to manipulate than a simple plist. The document ID patching described below may not
> work as written because the ID is inside the NSKeyedArchiver archive, not a top-level plist key.

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

> **⚠️ Correction from testing**: The `ffpasteboarddocumentID` key was NOT observed as a
> top-level plist key in FCP 11.1. The document ID is embedded INSIDE the `ffpasteboardobject`
> NSKeyedArchiver data. Simple plist-level patching as shown below may not work. You would need
> to decode the NSKeyedArchiver, find the UUID string in the `$objects` array, replace it, and
> re-encode. This is fragile.

```objc
// Read the current library's unique identifier
id currentProject = /* current project */;
id projectDoc = [currentProject performSelector:@selector(projectDocument)];
NSString *currentDocID = [projectDoc performSelector:@selector(uniqueIdentifier)];

// ⚠️ This simple approach may not work — documentID is inside NSKeyedArchiver, not top-level
NSMutableDictionary *plist = [NSPropertyListSerialization
    propertyListWithData:storedPlistData
    options:NSPropertyListMutableContainers
    format:NULL error:NULL];
plist[@"ffpasteboarddocumentID"] = currentDocID;  // May not exist as a key

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
- `documentID` patching is fragile; the internal `ffpasteboardobject` data (**NSKeyedArchiver**-encoded) contains embedded references that need the correct library context
- **Tested correction**: The `ffpasteboardobject` is opaque NSKeyedArchiver data (not FFCoder). The archive contains a full object graph with 265+ objects. Modifying individual attributes requires NSKeyedUnarchiver/NSKeyedArchiver round-tripping, which requires FCP's private classes to be registered.

---

## Solution 3: File URL + Programmatic Attribute Restore (Simplest Fallback) — PARTIALLY TESTED

The most pragmatic approach if you just need volume and a few properties.

> **Tested**: File URL paste enables FCP's paste command. The clip lands on the timeline.
> Attribute restoration via inspector was not verified (requires flexo bridge connection).

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
# Via SpliceKit JSON-RPC:

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

## Solution 4: Intercept with `mediaByReferenceOnly:NO` (Advanced) — NOT TESTED

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

| Approach | Media Import | Attributes Preserved | Complexity | Reliability | Tested |
|----------|-------------|---------------------|------------|-------------|--------|
| **1. FCPXML Pasteboard** | Automatic | ❌ NOT preserved (defaults) | Medium | High | ✅ Import works, attributes lost |
| **2. Import + Native Paste** | Manual first step | All (native format) | High | Low (NSKeyedArchiver) | ❌ Not tested |
| **3. URL + Attribute Restore** | Automatic | Manual per-property | Low | High | ⚠️ Partial |
| **4. mediaByReferenceOnly** | URL-dependent | Depends on source | High | Medium | ❌ Not tested |

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
// From within FCP's process (e.g., via injected dylib or SpliceKit)
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

> **Tested findings**:
> - Generic UTI (`com.apple.finalcutpro.xml`) alone: **works** — paste enabled, clip imported
> - Versioned UTI alone (`com.apple.finalcutpro.xml.v1-11`): **does NOT work** — paste disabled
> - Both generic + versioned: **works** (recommended)
> - FCPXML as `public.utf8-plain-text`: **does NOT work** — paste disabled (despite step 5 suggesting string fallback, this only applies to the FCP XML-specific string type, not general plain text)
> - FCP does NOT write FCPXML types when copying clips — only `com.apple.flexo.proFFPasteboardUTI`

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
| `FFCoder` | ~10 | Encodes/decodes FCP model objects to NSData (⚠️ clipboard uses NSKeyedArchiver instead) |

---

## Recommended Approach: FCPXML Import + Automatic Attribute Restore ✅ TESTED

FCP's `importClipsWithOptions:` does not preserve per-clip attributes (`adjust-volume`,
`adjust-blend`, effects). The import code exists in FCP's `FFXMLImporter` but the
`importClipsWithOptions:` path skips audio parameter application.

**SpliceKit solves this automatically**: the `fcpxml.pasteImport` method parses attributes
from the FCPXML before import, imports the media, then applies the attributes via the
inspector. This is a single API call — the two-step process is handled internally.

### From SpliceKit — Single Call (tested, working):

```python
# fcpxml.pasteImport handles everything:
# 1. Parses adjust-volume, adjust-blend from the FCPXML
# 2. Imports the clip via FFXMLTranslationTask (media linking)
# 3. Loads the new project, selects clips
# 4. Applies parsed attributes via inspector.set
#
# Returns: {"status": "ok", "importOK": true, "restoredAttributes": ["volume=-8dB"]}

fcpxml.pasteImport(xml='''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>
<fcpxml version="1.14">
  <resources>
    <format id="r0" frameDuration="100/2400s" width="1920" height="1080"/>
    <asset id="r1" hasAudio="1" hasVideo="0"
           audioSources="1" audioChannels="2" audioRate="48000">
      <media-rep kind="original-media" src="file:///path/to/sfx.wav"/>
    </asset>
  </resources>
  <library>
    <event name="SFX">
      <project name="My SFX">
        <sequence format="r0" duration="2400/2400s">
          <spine>
            <asset-clip ref="r1" name="SFX" duration="2400/2400s"
                        start="0s" format="r0">
              <adjust-volume amount="-8dB"/>
            </asset-clip>
          </spine>
        </sequence>
      </project>
    </event>
  </library>
</fcpxml>''')
```

### How the Bridge Does It (implementation detail)

The `SpliceKit_handlePasteboardImportXML` function in `SpliceKitServer.m`:

1. **Writes FCPXML to the system pasteboard** using `IXXMLPasteboardType.generic` and `.current` UTIs
2. **Creates `FFXMLTranslationTask`** from the pasteboard via `initForPasteboard:`
3. **Configures `FFXMLImportOptions`** with:
   - `setIncrementalImport:YES` — merge into existing library
   - `setConflictResolutionType:3` — merge, don't replace
   - `setLibrary:` — targets the active library (prevents "Which library?" dialog)
   - `setTargetEvent:` — targets the current timeline's event
4. **Calls `importClipsWithOptions:`** — imports media, creates project
5. **Parses the original FCPXML** with `NSXMLDocument`:
   - Extracts `adjust-volume amount=` → dB value
   - Extracts `adjust-blend amount=` → opacity value
6. **Finds and loads the new project** by matching the `<project name=...>` from the FCPXML
7. **Selects all clips** in the new timeline
8. **Calls `inspector.set`** for each parsed attribute (volume, opacity)
9. **Returns** `{"status":"ok", "restoredAttributes": ["volume=-8dB"]}`

### Building a Workflow Extension That Uses This

A workflow extension (`.appex`) runs out-of-process but can communicate with SpliceKit
over TCP. Here's a complete implementation:

#### 1. Extension View Controller (SwiftUI)

```swift
import SwiftUI
import ProExtension

struct SFXItem: Identifiable {
    let id = UUID()
    let name: String
    let filePath: String
    let volumeDB: Double      // e.g., -8.0
    let opacity: Double?       // e.g., 0.75 (nil = don't change)
}

class SFXViewModel: ObservableObject {
    @Published var items: [SFXItem] = []
    
    func addToTimeline(_ item: SFXItem) {
        // Build FCPXML with attributes embedded
        let fcpxml = buildFCPXML(item: item)
        
        // Send to SpliceKit — it handles import + attribute restoration
        SpliceKitClient.shared.pasteImport(xml: fcpxml) { result in
            print("Import result: \(result)")
        }
    }
    
    func buildFCPXML(item: SFXItem) -> String {
        let src = URL(fileURLWithPath: item.filePath).absoluteString
        let projName = "SFX_\(item.name)_\(Int.random(in: 1000...9999))"
        
        var adjustments = ""
        adjustments += "\n              <adjust-volume amount=\"\(item.volumeDB)dB\"/>"
        if let opa = item.opacity {
            // Only include adjust-blend for video clips
            adjustments += "\n              <adjust-blend amount=\"\(opa)\" mode=\"0\"/>"
        }
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.14">
          <resources>
            <format id="r0" frameDuration="100/2400s" width="1920" height="1080"/>
            <asset id="r1" hasAudio="1" hasVideo="0"
                   audioSources="1" audioChannels="2" audioRate="48000">
              <media-rep kind="original-media" src="\(src)"/>
            </asset>
          </resources>
          <library>
            <event name="SFX Import">
              <project name="\(projName)">
                <sequence format="r0" duration="2400/2400s">
                  <spine>
                    <asset-clip ref="r1" name="\(item.name)" duration="2400/2400s"
                                start="0s" format="r0">\(adjustments)
                    </asset-clip>
                  </spine>
                </sequence>
              </project>
            </event>
          </library>
        </fcpxml>
        """
    }
}
```

#### 2. SpliceKit TCP Client (for use inside the extension)

```swift
import Foundation

class SpliceKitClient {
    static let shared = SpliceKitClient()
    
    private let host = "127.0.0.1"
    private let port: UInt16 = 9876
    private var requestID = 0
    
    /// Import FCPXML with automatic attribute restoration.
    /// The bridge parses adjust-volume/adjust-blend from the XML,
    /// imports the clip, then applies the attributes via inspector.
    func pasteImport(xml: String, completion: @escaping ([String: Any]) -> Void) {
        call(method: "fcpxml.pasteImport", params: ["xml": xml], completion: completion)
    }
    
    /// Set a single inspector property on the selected clip.
    func setInspectorProperty(_ property: String, value: Any,
                              completion: @escaping ([String: Any]) -> Void) {
        call(method: "inspector.set",
             params: ["property": property, "value": value],
             completion: completion)
    }
    
    /// Execute a timeline action (selectAll, paste, blade, etc.)
    func timelineAction(_ action: String, completion: @escaping ([String: Any]) -> Void) {
        call(method: "timeline.action", params: ["action": action], completion: completion)
    }
    
    // MARK: - JSON-RPC Transport
    
    private func call(method: String, params: [String: Any],
                      completion: @escaping ([String: Any]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            requestID += 1
            let request: [String: Any] = [
                "jsonrpc": "2.0",
                "method": method,
                "params": params,
                "id": requestID
            ]
            
            guard let data = try? JSONSerialization.data(withJSONObject: request),
                  var message = String(data: data, encoding: .utf8) else {
                completion(["error": "Failed to serialize request"])
                return
            }
            message += "\n"
            
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                completion(["error": "Failed to create socket"])
                return
            }
            defer { close(sock) }
            
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr(host)
            
            let connectResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connectResult == 0 else {
                completion(["error": "Cannot connect to SpliceKit"])
                return
            }
            
            // Set 30s timeout
            var tv = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            
            // Send
            message.withCString { ptr in
                _ = send(sock, ptr, strlen(ptr), 0)
            }
            
            // Receive until newline
            var buffer = Data()
            var byte = UInt8(0)
            while recv(sock, &byte, 1, 0) == 1 {
                if byte == 0x0A { break }  // newline
                buffer.append(byte)
            }
            
            guard let response = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] else {
                completion(["error": "Invalid response"])
                return
            }
            
            if let error = response["error"] {
                completion(["error": error])
            } else {
                completion(response["result"] as? [String: Any] ?? [:])
            }
        }
    }
}
```

#### 3. Drag-and-Drop Alternative (for timeline insertion)

If you prefer drag-and-drop over the `fcpxml.pasteImport` API call, provide FCPXML
via `NSPasteboardItemDataProvider` and restore attributes after the drop:

```swift
class SFXDragProvider: NSObject, NSPasteboardItemDataProvider {
    let item: SFXItem
    
    init(item: SFXItem) { self.item = item }
    
    func pasteboard(_ pasteboard: NSPasteboard,
                    item pbItem: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        let fcpxml = SFXViewModel().buildFCPXML(item: self.item)
        if let data = fcpxml.data(using: .utf8) {
            pbItem.setData(data, forType: type)
        }
    }
    
    // After drop completes, restore attributes
    func restoreAttributes() {
        // Small delay to let FCP process the drop
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            SpliceKitClient.shared.timelineAction("selectClipAtPlayhead") { _ in
                SpliceKitClient.shared.setInspectorProperty("volume", value: self.item.volumeDB) { _ in
                    if let opa = self.item.opacity {
                        SpliceKitClient.shared.setInspectorProperty("opacity", value: opa) { _ in }
                    }
                }
            }
        }
    }
}

// Start drag:
let provider = SFXDragProvider(item: sfxItem)
let pbItem = NSPasteboardItem()
pbItem.setDataProvider(provider,
    forTypes: [.init("com.apple.finalcutpro.xml")])
// ... start drag session with pbItem
// Call provider.restoreAttributes() when drag completes
```

### Important Notes

- **Audio-only clips** must NOT include `<adjust-blend>` (opacity) — this causes import failure
- **Video clips** can include both `<adjust-volume>` and `<adjust-blend>`
- The bridge's `fcpxml.pasteImport` creates a **new project** per import, not a clip in the
  current timeline. The project name is taken from `<project name=...>` in the FCPXML.
- Use unique project names to avoid conflicts (add a random suffix)
- `adjust-volume amount` uses dB format (e.g., `"-8dB"`)
- The `inspector.set` value for volume uses the dB scale directly (e.g., `-8.0`)

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

This is especially useful for capturing what FCP writes to the pasteboard when you copy a clip — you can see the exact structure of `ffpasteboardobject`, `ffpasteboardcopiedtypes`, etc.

> **Tested**: When you copy a clip from FCP's timeline, only one type appears:
> `com.apple.flexo.proFFPasteboardUTI` (15,438 bytes for a single video clip). No FCPXML types.
> The plist has 3 keys: `ffpasteboardobject` (NSKeyedArchiver, 15,263 bytes),
> `ffpasteboardcopiedtypes`, `kffmodelobjectIDs` (empty array).

### Decoding NSKeyedArchiver Clipboard Data (Tested)

To decode the inner `ffpasteboardobject` data, decode it as a second binary plist:

```objc
NSData *objData = plist[@"ffpasteboardobject"];
// It's NSKeyedArchiver format — decode as plist to inspect
NSDictionary *archive = [NSPropertyListSerialization
    propertyListWithData:objData options:0 format:NULL error:NULL];
NSArray *objects = archive[@"$objects"];  // Array of 265+ encoded objects
// objects contains: strings (UUIDs, names, paths), class dictionaries,
// NSData blobs, numbers, etc.

// Find class names:
for (id obj in objects) {
    if ([obj isKindOfClass:[NSDictionary class]] && obj[@"$classname"]) {
        NSLog(@"Class: %@", obj[@"$classname"]);
    }
}
// Classes found: FFAnchoredMediaComponent, FFAnchoredCollection, FFAsset,
// FFAssetRef, FFEffectStack, FFHeColorEffect, FFHeConformEffect,
// FFIntrinsicColorConformEffect, FFMediaRep, FFMediaResource,
// FFMediaResourceMap, FFAudioClipComponentsLayoutMap, FFObjectDict
```

---

## Appendix F: Test Methodology

Tests were conducted April 2026 against FCP 11.1 on macOS Sequoia 15.4 using:

1. **Swift CLI tool** for NSPasteboard manipulation (write FCPXML/URLs, read back native data)
2. **AppleScript** (via `NSAppleScript`) for FCP interaction (activate, Cmd+V paste, Cmd+Z undo, menu inspection)
3. **MCP bridge tools** for FCP state queries (library/event/project listing) when bridge was connected

### Test procedure for each pasteboard variant:
1. Write data to `NSPasteboard.general` with specific UTI types
2. Activate FCP via AppleScript
3. Send Cmd+V keystroke
4. Wait 2.5 seconds for import processing
5. Read Edit menu's Undo/Redo item names to confirm paste action
6. Send Cmd+Z to undo and restore timeline state

### Confirmed test environment:
- Library: "Untitled" with events "4-3-26", "Montage"
- Active project: "Here We Go Montage" (29.75s, 24fps, 1920x1080)
- Test media: `/System/Library/Sounds/Basso.aiff` (0.77s audio-only)
