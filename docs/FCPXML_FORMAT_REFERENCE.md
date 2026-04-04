# FCPXML Format Reference

Complete reference for Final Cut Pro's XML interchange format. FCPXML describes media
assets, projects, editing decisions, and metadata exchanged between apps and Final Cut Pro.

FCPBridge uses FCPXML for project creation (`generate_fcpxml`), import (`import_fcpxml`),
and export (`export_xml`).

---

## Table of Contents

1. [Overview](#overview)
2. [Document Structure](#document-structure)
3. [Resources](#resources)
4. [Story Elements](#story-elements)
5. [Clips and Media References](#clips-and-media-references)
6. [Timing Attributes](#timing-attributes)
7. [Effects and Transitions](#effects-and-transitions)
8. [Markers, Keywords, and Metadata](#markers-keywords-and-metadata)
9. [Adjustment Attributes and Effect Parameters](#adjustment-attributes-and-effect-parameters)
10. [Predefined Video Formats](#predefined-video-formats)
11. [FCPXML Bundles](#fcpxml-bundles)
12. [Security-Scoped Bookmarks](#security-scoped-bookmarks)
13. [Practical Examples](#practical-examples)

---

## Overview

FCPXML uses standard XML with specialized elements to describe:

- **Media assets** — files, formats, effects referenced by clips
- **Projects** — timeline sequences with editing decisions
- **Metadata** — ratings, keywords, markers, custom fields
- **Editing decisions** — clip arrangement, timing, effects, transitions

### Version Requirements

| FCPXML Version | Minimum FCP Version |
|---------------|---------------------|
| 1.9 | Final Cut Pro 10.4.9 |
| 1.10 | Final Cut Pro 10.5 |
| 1.11 | Final Cut Pro 10.6 |

> FCPXML describes certain aspects of projects and events but is not a substitute
> for native FCP library bundles. It's designed for interchange, not archival.

### Useful Resources

- [Final Cut Pro User Guide](https://support.apple.com/guide/final-cut-pro/welcome/mac)
- [Final Cut Pro Resources](https://www.apple.com/final-cut-pro/resources/)
- [XML Specification](https://www.xml.com/axml/testaxml.htm)

---

## Document Structure

Every FCPXML document follows this hierarchy:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>

<fcpxml version="1.11">
    <resources>
        <!-- Shared resources: assets, formats, effects -->
    </resources>
    
    <!-- One of: library, event, or project -->
    <library location="file:///path/to/Library.fcpbundle/">
        <event name="My Event" uid="...">
            <project name="My Project" uid="...">
                <sequence duration="..." format="r1">
                    <spine>
                        <!-- Story elements (clips, gaps, etc.) -->
                    </spine>
                </sequence>
            </project>
        </event>
    </library>
</fcpxml>
```

### Root Element: `<fcpxml>`

| Attribute | Description |
|-----------|-------------|
| `version` | FCPXML version (e.g., "1.11") |

Contains: `<resources>` followed by `<library>`, `<event>`, or `<project>`.

### `<resources>`

Container for shared resources that events and projects reference by ID:

```xml
<resources>
    <format id="r1" name="FFVideoFormat1080p2398"
            frameDuration="1001/24000s"
            width="1920" height="1080"
            colorSpace="1-1-1 (Rec. 709)"/>
    
    <asset id="r2" name="MyClip" uid="..."
           start="0s" duration="300300/24000s"
           hasVideo="1" hasAudio="1"
           format="r1" audioSources="1" audioChannels="2">
        <media-rep kind="original-media"
                   src="file:///path/to/clip.mov">
            <bookmark>...</bookmark>
        </media-rep>
    </asset>
    
    <effect id="r3" name="Cross Dissolve" uid="..."/>
</resources>
```

### `<library>`

Top-level container for events:

| Attribute | Description |
|-----------|-------------|
| `location` | File URL to the `.fcpbundle` |

### `<event>`

Container for clips and projects within a library:

| Attribute | Description |
|-----------|-------------|
| `name` | Event name |
| `uid` | Unique identifier |

### `<project>`

Represents a project timeline:

| Attribute | Description |
|-----------|-------------|
| `name` | Project name |
| `uid` | Unique identifier |

Contains a single `<sequence>` element.

### `<sequence>`

The timeline itself:

| Attribute | Description |
|-----------|-------------|
| `duration` | Total duration (rational time, e.g., "300300/24000s") |
| `format` | Reference to a format resource |
| `tcStart` | Starting timecode |
| `tcFormat` | Timecode format: "NDF" (non-drop), "DF" (drop frame) |
| `audioLayout` | "mono", "stereo", or "surround" |
| `audioRate` | "44.1k", "48k", or "96k" |

Contains a `<spine>` element.

---

## Resources

### `<format>` — Video Format Definition

```xml
<format id="r1" name="FFVideoFormat1080p2398"
        frameDuration="1001/24000s"
        width="1920" height="1080"
        colorSpace="1-1-1 (Rec. 709)"/>
```

| Attribute | Description |
|-----------|-------------|
| `id` | Resource ID for referencing |
| `name` | Predefined format name (see [Predefined Video Formats](#predefined-video-formats)) |
| `frameDuration` | Duration of one frame as rational time |
| `width` / `height` | Frame dimensions in pixels |
| `colorSpace` | Color space identifier |

### `<asset>` — Media Asset

Defines file-based media managed in a library:

```xml
<asset id="r2" name="Interview" uid="A1B2C3D4"
       start="0s" duration="600600/24000s"
       hasVideo="1" hasAudio="1"
       format="r1"
       audioSources="1" audioChannels="2"
       audioRate="48000">
    <media-rep kind="original-media"
               src="file:///Volumes/Media/Interview.mov">
        <bookmark>BASE64_ENCODED_BOOKMARK_DATA</bookmark>
    </media-rep>
</asset>
```

| Attribute | Description |
|-----------|-------------|
| `id` | Resource ID |
| `name` | Display name |
| `uid` | Globally unique identifier |
| `start` | Media start time |
| `duration` | Total media duration |
| `hasVideo` / `hasAudio` | "1" or "0" |
| `format` | Reference to format resource |
| `audioSources` | Number of audio sources |
| `audioChannels` | Channels per source |
| `audioRate` | Sample rate in Hz |

### `<media-rep>` — Media Representation

```xml
<media-rep kind="original-media" src="file:///path/to/file.mov">
    <bookmark>...</bookmark>
</media-rep>
```

| `kind` Value | Description |
|-------------|-------------|
| `original-media` | Original source file |
| `proxy-media` | Proxy resolution version |
| `optimized-media` | ProRes optimized version |

### `<effect>` — Effect Reference

```xml
<effect id="r3" name="Cross Dissolve"
        uid=".../Transitions.localized/Dissolves.localized/Cross Dissolve.effectBundle"/>
```

References visual, audio, or custom effects by name and UID.

### `<media>` — Compound/Multicam Media

Describes compound clip or multi-camera media definitions containing sequences,
audio, and video tracks.

---

## Story Elements

Story elements are the building blocks of a timeline sequence. They go inside a
`<spine>` element and are ordered sequentially in time.

### `<spine>` — Primary Storyline

Contains elements ordered sequentially:

```xml
<spine>
    <asset-clip ref="r2" duration="120120/24000s" .../>
    <transition ref="r3" duration="24024/24000s" .../>
    <asset-clip ref="r4" duration="180180/24000s" .../>
    <gap duration="48048/24000s" .../>
    <title ref="r5" duration="72072/24000s" .../>
</spine>
```

### Anchoring and Lanes

Any story element can have other story elements **anchored** to it:

- Positive `lane` index → composites **above** the base element (video overlays)
- Negative `lane` index → composites **below** (background elements)
- Lane `0` (implied) → contained items inside the element

For video, lane order determines compositing order (higher over lower).
For audio, lane order has no effect on mixing.

```xml
<asset-clip ref="r2" duration="120120/24000s">
    <!-- Anchored title above this clip -->
    <title ref="r5" lane="1" offset="24024/24000s" duration="48048/24000s">
        <text>Hello World</text>
    </title>
</asset-clip>
```

### Story Element Types

| Element | Description |
|---------|-------------|
| `<clip>` | Basic unit of editing |
| `<asset-clip>` | References a single media asset |
| `<ref-clip>` | References a compound clip media |
| `<sync-clip>` | Synchronized clip with contained items |
| `<mc-clip>` | References multicam media |
| `<gap>` | Placeholder with no intrinsic media |
| `<title>` | Title/text element |
| `<audio>` | Audio data from asset or effect |
| `<video>` | Video data from asset or effect |
| `<audition>` | Container with one active + alternative clips |

### `<clip>` — Basic Clip

```xml
<clip name="Interview" duration="120120/24000s"
      start="0s" offset="0s"
      format="r1" tcFormat="NDF">
    <video ref="r2" duration="120120/24000s"/>
    <audio ref="r2" duration="120120/24000s" role="dialogue"/>
</clip>
```

### `<asset-clip>` — Asset Reference Clip

The most common clip type — directly references a media asset:

```xml
<asset-clip ref="r2" name="Interview"
            offset="0s" duration="120120/24000s"
            start="48048/24000s"
            audioRole="dialogue"/>
```

| Attribute | Description |
|-----------|-------------|
| `ref` | Resource ID of the asset |
| `offset` | Position in the timeline |
| `duration` | Duration in timeline |
| `start` | Start point within the source media |
| `audioRole` | Audio role assignment |

### `<gap>` — Gap Element

```xml
<gap name="Gap" duration="48048/24000s" start="0s"/>
```

Placeholder that takes up time but has no audio or video content.

### `<title>` — Title Element

```xml
<title ref="r5" name="Basic Title"
       offset="0s" duration="72072/24000s">
    <text>
        <text-style ref="ts1">My Title Text</text-style>
    </text>
</title>
```

### `<audition>` — Audition Container

Contains one active story element followed by alternatives:

```xml
<audition>
    <asset-clip ref="r2" .../>  <!-- Active pick -->
    <asset-clip ref="r3" .../>  <!-- Alternative 1 -->
    <asset-clip ref="r4" .../>  <!-- Alternative 2 -->
</audition>
```

---

## Timing Attributes

All timing in FCPXML uses **rational time** expressed as fractions with an "s" suffix.

### Rational Time Format

```
value/timescale s
```

Examples:
- `1001/24000s` = one frame at 23.976 fps
- `1/24s` = one frame at 24 fps
- `1001/30000s` = one frame at 29.97 fps
- `0s` = zero / start
- `300300/24000s` = 12.5125 seconds at 23.976 fps

### Core Timing Attributes

| Attribute | Description |
|-----------|-------------|
| `offset` | Position of the element in its parent timeline |
| `duration` | Length of the element in the timeline |
| `start` | Start point within the source media (in-point) |
| `tcStart` | Starting timecode for the sequence |

### Relationship Between Attributes

```
Source Media:  [============================]
               ^start                       ^start+duration

Timeline:      [........|==========|........]
                        ^offset    ^offset+duration
```

- `start` determines where in the **source** to begin
- `offset` determines where in the **timeline** the clip appears
- `duration` determines how long it plays

### Speed Changes

Use `<timeMap>` for variable speed or `<rate>` for constant speed changes:

```xml
<!-- Constant speed change -->
<asset-clip ref="r2" duration="240240/24000s">
    <adjust-speed speed="0.5"/>  <!-- 50% speed = 2x duration -->
</asset-clip>
```

---

## Effects and Transitions

### `<effect>` Element (in Resources)

```xml
<effect id="r10" name="Gaussian Blur"
        uid=".../Filters.localized/Blur.localized/Gaussian.effectBundle"/>
```

### Applying Effects to Clips

Effects are child elements of clips:

```xml
<asset-clip ref="r2" duration="120120/24000s">
    <filter-video ref="r10" name="Gaussian Blur">
        <param name="Amount" key="9999/100/100/1/0/0" value="15"/>
    </filter-video>
</asset-clip>
```

### `<transition>` Element

Transitions go between clips in a spine and overlap both:

```xml
<spine>
    <asset-clip ref="r2" duration="120120/24000s"/>
    <transition ref="r3" name="Cross Dissolve"
                duration="24024/24000s" offset="108108/24000s"/>
    <asset-clip ref="r4" duration="180180/24000s"/>
</spine>
```

| Attribute | Description |
|-----------|-------------|
| `ref` | Reference to effect resource |
| `name` | Transition name |
| `duration` | Transition overlap duration |
| `offset` | Position relative to edit point |

### Adjustment Elements

```xml
<!-- Color correction -->
<asset-clip ref="r2" duration="120120/24000s">
    <adjust-colorConformLUT enabled="1">
        <param name="Input Transform" key="..." value="..."/>
    </adjust-colorConformLUT>
</asset-clip>
```

### Common Adjustment Types

| Element | Effect |
|---------|--------|
| `<adjust-transform>` | Position, rotation, scale |
| `<adjust-crop>` | Crop controls |
| `<adjust-corners>` | Corner pinning |
| `<adjust-conform>` | Pixel aspect ratio |
| `<adjust-blend>` | Blend modes |
| `<adjust-volume>` | Audio volume |
| `<adjust-eq>` | Audio equalization |
| `<adjust-panner>` | Audio panning |
| `<adjust-stabilization>` | Video stabilization |
| `<adjust-rollingShutter>` | Rolling shutter correction |
| `<adjust-360-transform>` | 360 video transforms |
| `<adjust-cinematic>` | Cinematic mode editing |
| `<adjust-loudness>` | Loudness analysis/correction |
| `<adjust-noisereduction>` | Audio noise reduction |
| `<adjust-humreduction>` | Hum removal |
| `<adjust-matcheq>` | Audio match EQ |
| `<adjust-reorient>` | Automatic reorientation |
| `<adjust-orientation>` | Image rotation |

---

## Markers, Keywords, and Metadata

### `<marker>` — Standard Marker

```xml
<asset-clip ref="r2" duration="120120/24000s">
    <marker start="48048/24000s" duration="1001/24000s"
            value="Review this section"/>
</asset-clip>
```

| Attribute | Description |
|-----------|-------------|
| `start` | Position within the clip |
| `duration` | Marker duration (usually one frame) |
| `value` | Marker text/name |

### `<chapter-marker>` — Chapter Marker

```xml
<chapter-marker start="0s" duration="1001/24000s"
                value="Chapter 1"
                posterOffset="12012/24000s"/>
```

| Attribute | Description |
|-----------|-------------|
| `posterOffset` | Offset for chapter thumbnail |

### `<keyword>` — Keyword Annotation

```xml
<asset-clip ref="r2" duration="120120/24000s">
    <keyword start="0s" duration="120120/24000s" value="interview, main"/>
</asset-clip>
```

### `<rating>` — Media Rating

```xml
<rating name="favorite" start="0s" duration="120120/24000s" value="favorite"/>
```

| `value` | Meaning |
|---------|---------|
| `favorite` | Marked as favorite |
| `reject` | Marked as rejected |

### `<note>` — Text Annotation

```xml
<note>This clip needs color correction</note>
```

### `<metadata>` — Custom Metadata

```xml
<metadata>
    <md key="com.apple.proapps.studio.reel" value="Reel 1"/>
    <md key="com.apple.proapps.studio.scene" value="Scene 5"/>
    <md key="com.apple.proapps.studio.shot" value="Take 3"/>
</metadata>
```

### Analysis Markers

```xml
<analysis-marker start="24024/24000s" duration="1001/24000s"
                 type="excessive shake"/>
```

Types include: excessive shake, person detected, etc.

### Object Tracker

```xml
<object-tracker>
    <tracking-shape name="Face 1" type="auto-analysis"
                    offset="0s" duration="120120/24000s">
        <!-- Tracking keyframe data -->
    </tracking-shape>
</object-tracker>
```

---

## Adjustment Attributes and Effect Parameters

### Transform Properties

```xml
<adjust-transform position="100 50"
                   anchor="0 0"
                   scale="1.2 1.2"
                   rotation="15"/>
```

| Attribute | Description |
|-----------|-------------|
| `position` | X Y offset from center |
| `anchor` | Anchor point for transforms |
| `scale` | X Y scale factors |
| `rotation` | Degrees of rotation |

### Compositing

```xml
<adjust-blend amount="0.8" mode="multiply"/>
```

Blend modes: normal, subtract, darken, multiply, color burn, linear burn,
add, lighten, screen, color dodge, linear dodge, overlay, soft light,
hard light, vivid light, linear light, pin light, hard mix, difference,
exclusion, stencil alpha, stencil luma, silhouette alpha, silhouette luma,
behind.

### Volume and Audio

```xml
<adjust-volume amount="-6dB"/>

<audio-channel-source srcCh="1, 2" role="dialogue.dialogue-1">
    <adjust-volume amount="0dB"/>
</audio-channel-source>
```

### Effect Parameters

Parameters are specified as `<param>` children of effect elements:

```xml
<filter-video ref="r10" name="Gaussian Blur" enabled="1">
    <param name="Amount" key="9999/100/100/1/0/0" value="15"/>
    <param name="Falloff" key="9999/100/100/2/0/0" value="0.5"/>
</filter-video>
```

### Keyframed Parameters

```xml
<param name="Opacity" key="...">
    <keyframe time="0s" value="0"/>
    <keyframe time="24024/24000s" value="1" curve="smooth"/>
    <keyframe time="120120/24000s" value="1"/>
    <keyframe time="144144/24000s" value="0" curve="smooth"/>
</param>
```

Curve types: `linear`, `smooth` (ease in/out), `ease-in`, `ease-out`.

### Roles

```xml
<asset-clip ref="r2" audioRole="dialogue"
            videoRole="video.video-1">
```

Audio roles: `dialogue`, `music`, `effects`
Video roles: `video`, `titles`

Custom roles can be defined and assigned.

---

## Predefined Video Formats

FCP recognizes these standard format names in `<format>` elements:

### HD Formats

| Name | Resolution | Frame Rate |
|------|-----------|------------|
| `FFVideoFormat1080p2398` | 1920x1080 | 23.976 fps |
| `FFVideoFormat1080p24` | 1920x1080 | 24 fps |
| `FFVideoFormat1080p25` | 1920x1080 | 25 fps |
| `FFVideoFormat1080p2997` | 1920x1080 | 29.97 fps |
| `FFVideoFormat1080p30` | 1920x1080 | 30 fps |
| `FFVideoFormat1080p50` | 1920x1080 | 50 fps |
| `FFVideoFormat1080p5994` | 1920x1080 | 59.94 fps |
| `FFVideoFormat1080p60` | 1920x1080 | 60 fps |
| `FFVideoFormat1080i50` | 1920x1080 | 25 fps interlaced |
| `FFVideoFormat1080i5994` | 1920x1080 | 29.97 fps interlaced |
| `FFVideoFormat1080i60` | 1920x1080 | 30 fps interlaced |
| `FFVideoFormat720p2398` | 1280x720 | 23.976 fps |
| `FFVideoFormat720p25` | 1280x720 | 25 fps |
| `FFVideoFormat720p2997` | 1280x720 | 29.97 fps |
| `FFVideoFormat720p50` | 1280x720 | 50 fps |
| `FFVideoFormat720p5994` | 1280x720 | 59.94 fps |
| `FFVideoFormat720p60` | 1280x720 | 60 fps |

### 4K / UHD Formats

| Name | Resolution | Frame Rate |
|------|-----------|------------|
| `FFVideoFormatRateUHD2160p2398` | 3840x2160 | 23.976 fps |
| `FFVideoFormatRateUHD2160p24` | 3840x2160 | 24 fps |
| `FFVideoFormatRateUHD2160p25` | 3840x2160 | 25 fps |
| `FFVideoFormatRateUHD2160p2997` | 3840x2160 | 29.97 fps |
| `FFVideoFormatRateUHD2160p30` | 3840x2160 | 30 fps |
| `FFVideoFormatRateUHD2160p50` | 3840x2160 | 50 fps |
| `FFVideoFormatRateUHD2160p5994` | 3840x2160 | 59.94 fps |
| `FFVideoFormatRateUHD2160p60` | 3840x2160 | 60 fps |
| `FFVideoFormatRate4096x2160p2398` | 4096x2160 | 23.976 fps |
| `FFVideoFormatRate4096x2160p24` | 4096x2160 | 24 fps |
| `FFVideoFormatRate4096x2160p25` | 4096x2160 | 25 fps |
| `FFVideoFormatRate4096x2160p2997` | 4096x2160 | 29.97 fps |
| `FFVideoFormatRate4096x2160p30` | 4096x2160 | 30 fps |
| `FFVideoFormatRate4096x2160p50` | 4096x2160 | 50 fps |
| `FFVideoFormatRate4096x2160p5994` | 4096x2160 | 59.94 fps |
| `FFVideoFormatRate4096x2160p60` | 4096x2160 | 60 fps |

### SD Formats

| Name | Resolution | Notes |
|------|-----------|-------|
| `FFVideoFormatNTSC` | 720x480 | NTSC SD |
| `FFVideoFormatPAL` | 720x576 | PAL SD |
| `FFVideoFormatNTSCWide` | 720x480 | 16:9 NTSC |
| `FFVideoFormatPALWide` | 720x576 | 16:9 PAL |

### Frame Duration Reference

| Frame Rate | `frameDuration` Value |
|-----------|----------------------|
| 23.976 fps | `1001/24000s` |
| 24 fps | `100/2400s` |
| 25 fps | `100/2500s` |
| 29.97 fps | `1001/30000s` |
| 30 fps | `100/3000s` |
| 50 fps | `100/5000s` |
| 59.94 fps | `1001/60000s` |
| 60 fps | `100/6000s` |

---

## FCPXML Bundles

An FCPXML bundle (`.fcpxmld`) keeps an FCPXML document and its referenced files together:

```
MyExchange.fcpxmld/
├── Info.plist
├── MyExchange.fcpxml     ← The FCPXML document
└── Media/                ← Referenced media files
    ├── clip1.mov
    ├── clip2.mov
    └── ...
```

### Info.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.myapp.fcpxmld</string>
    <key>CFBundleName</key>
    <string>MyExchange</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
</dict>
</plist>
```

### Media References in Bundles

When media is inside the bundle, use relative paths in `src` attributes:

```xml
<media-rep kind="original-media" src="Media/clip1.mov"/>
```

Bundles are useful for:
- Transferring projects between systems
- Archiving projects with media
- Sharing edits with collaborators

---

## Security-Scoped Bookmarks

Sandboxed applications need security-scoped bookmarks to access media files.
FCPXML includes base64-encoded bookmark data in `<bookmark>` elements.

### Reading Bookmarks

```objc
// 1. Decode base64 bookmark data
NSData *decoded = [[NSData alloc]
    initWithBase64EncodedString:bookmarkString
    options:NSDataBase64DecodingIgnoreUnknownCharacters];

// 2. Resolve to security-scoped URL
NSError *err = nil;
NSURL *url = [NSURL URLByResolvingBookmarkData:decoded
    options:NSURLBookmarkResolutionWithSecurityScope
    relativeToURL:sourceURL
    bookmarkDataIsStale:nil
    error:&err];

// 3. Access the resource
[url startAccessingSecurityScopedResource];
// ... use the file ...
[url stopAccessingSecurityScopedResource];
```

### Creating Bookmarks

```objc
// For FCPXML files (document-scoped)
[assetURL startAccessingSecurityScopedResource];
NSData *bookmark = [assetURL
    bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
    includingResourceValuesForKeys:nil
    relativeToURL:documentURL
    error:&err];
[assetURL stopAccessingSecurityScopedResource];

// For drag-and-drop (unscoped)
NSData *bookmark = [assetURL
    bookmarkDataWithOptions:0
    includingResourceValuesForKeys:nil
    relativeToURL:nil
    error:&err];
```

### Required Entitlements

```xml
<key>com.apple.security.files.bookmarks.document-scope</key>
<true/>
```

| Entitlement | Use |
|------------|-----|
| `com.apple.security.files.bookmarks.app-scope` | App-scoped bookmarks |
| `com.apple.security.files.bookmarks.document-scope` | Document-scoped bookmarks |

---

## Practical Examples

### Example 1: Simple Project with Clips

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>
<fcpxml version="1.11">
    <resources>
        <format id="r1" name="FFVideoFormat1080p2398"
                frameDuration="1001/24000s"
                width="1920" height="1080"
                colorSpace="1-1-1 (Rec. 709)"/>
        <asset id="r2" name="Shot_01" uid="ABC123"
               start="0s" duration="240240/24000s"
               hasVideo="1" hasAudio="1" format="r1"
               audioSources="1" audioChannels="2">
            <media-rep kind="original-media"
                       src="file:///Users/editor/Media/Shot_01.mov"/>
        </asset>
        <asset id="r3" name="Shot_02" uid="DEF456"
               start="0s" duration="360360/24000s"
               hasVideo="1" hasAudio="1" format="r1"
               audioSources="1" audioChannels="2">
            <media-rep kind="original-media"
                       src="file:///Users/editor/Media/Shot_02.mov"/>
        </asset>
    </resources>
    <event name="My Event">
        <project name="My Project">
            <sequence duration="600600/24000s" format="r1"
                      tcStart="0s" tcFormat="NDF"
                      audioLayout="stereo" audioRate="48k">
                <spine>
                    <asset-clip ref="r2" offset="0s"
                                duration="240240/24000s"
                                audioRole="dialogue"/>
                    <asset-clip ref="r3" offset="240240/24000s"
                                duration="360360/24000s"
                                audioRole="dialogue"/>
                </spine>
            </sequence>
        </project>
    </event>
</fcpxml>
```

### Example 2: Clips with Transitions and Markers

```xml
<spine>
    <asset-clip ref="r2" offset="0s" duration="120120/24000s">
        <marker start="24024/24000s" duration="1001/24000s"
                value="Good take"/>
        <keyword start="0s" duration="120120/24000s"
                 value="interview"/>
    </asset-clip>
    
    <transition ref="r5" duration="24024/24000s"/>
    
    <asset-clip ref="r3" offset="96096/24000s" duration="180180/24000s">
        <adjust-volume amount="-3dB"/>
        <chapter-marker start="0s" duration="1001/24000s"
                        value="Chapter 2"/>
    </asset-clip>
</spine>
```

### Example 3: Title with Styling

```xml
<resources>
    <effect id="r10" name="Basic Title"
            uid=".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"/>
</resources>

<!-- In spine: -->
<title ref="r10" name="Opening Title"
       offset="0s" duration="120120/24000s">
    <text>
        <text-style ref="ts1">Welcome to the Show</text-style>
    </text>
    <text-style-def id="ts1">
        <text-style font="Helvetica Neue" fontSize="72"
                    fontFace="Bold" fontColor="1 1 1 1"
                    alignment="center"/>
    </text-style-def>
</title>
```

### Example 4: Using with FCPBridge

```python
# Generate FCPXML with FCPBridge
xml = generate_fcpxml(
    project_name="Auto Edit",
    frame_rate="24",
    items='[
        {"type":"gap","duration":2},
        {"type":"title","text":"Introduction","duration":5},
        {"type":"transition","duration":1},
        {"type":"gap","duration":10},
        {"type":"marker","time":5,"name":"Chapter 1","kind":"chapter"},
        {"type":"marker","time":12,"name":"Review Point"}
    ]'
)

# Import into FCP (no restart needed)
import_fcpxml(xml, internal=True)

# Export current project as FCPXML
export_xml()
```

### Example 5: Collections and Smart Collections

```xml
<event name="My Event">
    <!-- Keyword collection -->
    <keyword-collection name="Best Takes">
        <asset-clip ref="r2" .../>
        <asset-clip ref="r5" .../>
    </keyword-collection>
    
    <!-- Smart collection (filter-based) -->
    <smart-collection name="Favorites" match="all">
        <match-ratings value="favorites"/>
    </smart-collection>
    
    <!-- Collection folder -->
    <collection-folder name="Selects">
        <keyword-collection name="A-Roll" .../>
        <keyword-collection name="B-Roll" .../>
    </collection-folder>
</event>
```

---

*Based on Apple's FCPXML documentation and the Professional Video Applications framework.*
