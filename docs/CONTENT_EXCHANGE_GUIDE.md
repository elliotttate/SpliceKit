# Content Exchange with Final Cut Pro

How to send media, metadata, and editing decisions between your app and Final Cut Pro.
Covers all exchange mechanisms: FCPXML, drag-and-drop, Apple Events, growing files,
and custom share destinations.

---

## Table of Contents

1. [Overview](#overview)
2. [Exchange Architecture](#exchange-architecture)
3. [Sending Media to Final Cut Pro](#sending-media-to-final-cut-pro)
4. [Drag and Drop: Sending to FCP](#drag-and-drop-sending-to-fcp)
5. [Drag and Drop: Receiving from FCP](#drag-and-drop-receiving-from-fcp)
6. [Programmatic Sending via Apple Events](#programmatic-sending-via-apple-events)
7. [Growing Files (Live Recording)](#growing-files-live-recording)
8. [Custom Share Destinations](#custom-share-destinations)
9. [Associating Metadata with Media](#associating-metadata-with-media)
10. [Effect Templates for FCP](#effect-templates-for-fcp)
11. [Encoder Extensions](#encoder-extensions)
12. [Integration with FCPBridge](#integration-with-fcpbridge)

---

## Overview

Final Cut Pro supports bidirectional data exchange:

**Your App → FCP:**
- Send media assets with metadata (ratings, keywords, markers)
- Send timeline sequences as FCPXML
- Send media as it's being recorded (growing files)
- Drag clips directly into FCP's browser or timeline

**FCP → Your App:**
- Receive rendered media (movies) via share destinations
- Receive editing decisions as FCPXML
- Drag clips/sequences from FCP into your app
- Export FCPXML for processing

All exchange uses **FCPXML** as the interchange format (see [FCPXML Format Reference](FCPXML_FORMAT_REFERENCE.md)).

---

## Exchange Architecture

```
┌─────────────────────┐                    ┌─────────────────────┐
│     Your App        │                    │   Final Cut Pro     │
│                     │                    │                     │
│  ┌───────────────┐  │   FCPXML + Media   │  ┌───────────────┐ │
│  │ Media Assets  │──┼───────────────────►│  │ Browser       │ │
│  │ + Metadata    │  │   Drag & Drop      │  │ (Events)      │ │
│  └───────────────┘  │   Apple Events     │  └───────────────┘ │
│                     │                    │                     │
│  ┌───────────────┐  │   Share Dest.      │  ┌───────────────┐ │
│  │ Processing    │◄─┼───────────────────┤  │ Timeline      │ │
│  │ Pipeline      │  │   FCPXML Export    │  │ (Projects)    │ │
│  └───────────────┘  │   Drag & Drop     │  └───────────────┘ │
└─────────────────────┘                    └─────────────────────┘
```

---

## Sending Media to Final Cut Pro

### Basic Media Send with FCPXML

Create an FCPXML document describing the media and metadata, then have FCP open it:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>
<fcpxml version="1.11">
    <resources>
        <format id="r1" name="FFVideoFormat1080p2398"
                frameDuration="1001/24000s"
                width="1920" height="1080"/>
        <asset id="r2" name="Interview_A" uid="UNIQUE-ID-1"
               start="0s" duration="600600/24000s"
               hasVideo="1" hasAudio="1" format="r1"
               audioSources="1" audioChannels="2">
            <media-rep kind="original-media"
                       src="file:///Volumes/Media/Interview_A.mov"/>
        </asset>
    </resources>
    <event name="Imported Media">
        <asset-clip ref="r2" name="Interview_A"
                    duration="600600/24000s"
                    audioRole="dialogue">
            <keyword start="0s" duration="600600/24000s"
                     value="interview, camera-a"/>
            <rating start="48048/24000s" duration="120120/24000s"
                    value="favorite"/>
            <marker start="96096/24000s" duration="1001/24000s"
                    value="Best moment"/>
        </asset-clip>
    </event>
</fcpxml>
```

### What You Can Attach

| Metadata | Element | Scope |
|----------|---------|-------|
| Keywords | `<keyword>` | Time range within clip |
| Ratings | `<rating>` | Time range (favorite/reject) |
| Markers | `<marker>` | Specific timecode |
| Chapter markers | `<chapter-marker>` | Specific timecode |
| Notes | `<note>` | Clip-level text |
| Custom metadata | `<metadata>` | Key-value pairs |
| Roles | `audioRole` / `videoRole` attr | Clip attribute |

---

## Drag and Drop: Sending to FCP

### File URL Drag

The simplest approach — drag file URLs that FCP imports directly:

```swift
class MediaItemView: NSView, NSDraggingSource {
    var mediaURL: URL?
    
    override func mouseDown(with event: NSEvent) {
        guard let url = mediaURL else { return }
        
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: thumbnail)
        
        beginDraggingSession(with: [item], event: event, source: self)
    }
    
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .copy
    }
}
```

### FCPXML Drag (with metadata)

For richer imports with keywords, markers, and ratings:

```swift
func writeToPasteboard(_ pasteboard: NSPasteboard) {
    let pasteboardType = NSPasteboard.PasteboardType("com.apple.finalcutpro.xml")
    
    pasteboard.declareTypes([pasteboardType, .fileURL], owner: self)
    
    // FCPXML with metadata
    let fcpxml = buildFCPXMLWithMetadata()
    pasteboard.setString(fcpxml, forType: pasteboardType)
    
    // Also provide file URL as fallback
    pasteboard.setString(mediaURL.absoluteString, forType: .fileURL)
}
```

### Multiple Items

Drag multiple clips at once by including multiple asset-clips in the FCPXML:

```xml
<event name="Batch Import">
    <asset-clip ref="r2" name="Shot 01" .../>
    <asset-clip ref="r3" name="Shot 02" .../>
    <asset-clip ref="r4" name="Shot 03" .../>
</event>
```

### Timeline Sequences

Send pre-built timelines for FCP to open as projects:

```xml
<event name="Assembly">
    <project name="Rough Cut">
        <sequence duration="..." format="r1">
            <spine>
                <asset-clip ref="r2" .../>
                <transition ref="r10" .../>
                <asset-clip ref="r3" .../>
            </spine>
        </sequence>
    </project>
</event>
```

---

## Drag and Drop: Receiving from FCP

### Registering for FCP Data

```swift
class DropTargetView: NSView {
    override func awakeFromNib() {
        super.awakeFromNib()
        registerForDraggedTypes([
            NSPasteboard.PasteboardType("com.apple.finalcutpro.xml"),
            NSPasteboard.PasteboardType("com.apple.finalcutpro.xml.v2"),
            .fileURL
        ])
    }
}
```

### Handling the Drop

```swift
override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let pasteboard = sender.draggingPasteboard
    
    // Try FCPXML first (richest data)
    let xmlType = NSPasteboard.PasteboardType("com.apple.finalcutpro.xml")
    if let xmlString = pasteboard.string(forType: xmlType) {
        return processFCPXML(xmlString)
    }
    
    // Fall back to file URLs
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                         options: nil) as? [URL] {
        return processFileURLs(urls)
    }
    
    return false
}

func processFCPXML(_ xml: String) -> Bool {
    // Parse the FCPXML to extract:
    // - Media file references
    // - Clip in/out points
    // - Keywords, markers, ratings
    // - Editing decisions (if dropping a project)
    let parser = XMLParser(data: xml.data(using: .utf8)!)
    // ... parse and process ...
    return true
}
```

### What FCP Sends

When dragging from FCP's browser, the pasteboard contains FCPXML describing:
- Asset references with media file paths
- Clip ranges (in/out points)
- Keywords, ratings, and markers
- Audio role assignments

When dragging from the timeline, it includes editing decisions (sequences with spine
elements).

---

## Programmatic Sending via Apple Events

### Batch Media Import

For automated workflows, send media to FCP using Apple Events without user interaction:

```objc
// Create the Apple Event
NSAppleEventDescriptor *event = [NSAppleEventDescriptor
    appleEventWithEventClass:'PVap'
    eventID:'ImXD'
    targetDescriptor:fcpDescriptor
    returnID:kAutoGenerateReturnID
    transactionID:kAnyTransactionID];

// Attach FCPXML data
NSData *xmlData = [fcpxmlString dataUsingEncoding:NSUTF8StringEncoding];
NSAppleEventDescriptor *xmlDesc = [NSAppleEventDescriptor descriptorWithDescriptorType:'ImXD'
    data:xmlData];
[event setParamDescriptor:xmlDesc forKeyword:'ImXD'];

// Send
NSError *error = nil;
[event sendEventWithOptions:kAENoReply timeout:kAEDefaultTimeout error:&error];
```

### Requirements

- Your app needs a scripting definition (`.sdef`) file
- FCP must be running
- The FCPXML must be valid and reference accessible media files

---

## Growing Files (Live Recording)

Send media to FCP while it's still being recorded — FCP can start editing
before the recording finishes.

### How It Works

1. Start recording to a file (e.g., QuickTime movie)
2. Send FCPXML to FCP referencing the file
3. FCP opens the file and begins ingesting
4. As new frames are written, FCP sees the growing file
5. Editors can work with the available portion immediately

### FCPXML for Growing Files

```xml
<asset id="r2" name="Live Recording" uid="..."
       start="0s" duration="0s"
       hasVideo="1" hasAudio="1" format="r1">
    <media-rep kind="original-media"
               src="file:///Volumes/Record/live_feed.mov"/>
</asset>
```

The `duration="0s"` indicates the file is still growing. FCP periodically checks
for new data.

### Requirements

- The recording format must support incremental writing (QuickTime MOV)
- The file must be accessible on a shared or local volume
- FCP must be able to read partial files of the codec used

---

## Custom Share Destinations

Register your app as a share destination so users can export from FCP directly
to your app.

### Architecture

```
FCP Share Dialog → Your Share Destination → Your App
                   (rendered media +
                    FCPXML metadata)
```

### 1. Create a Scripting Definition (.sdef)

Define the Apple Events your app handles:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE dictionary SYSTEM "file://localhost/System/Library/DTDs/sdef.dtd">
<dictionary title="My App Scripting">
    <suite name="Final Cut Pro Suite" code="PVap"
           description="Commands from Final Cut Pro">
        <command name="open" code="aevtodoc"
                 description="Open a document from Final Cut Pro">
            <direct-parameter description="The file to open"
                              type="file"/>
        </command>
    </suite>
</dictionary>
```

### 2. Handle Apple Events

```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication,
                     open urls: [URL]) {
        for url in urls {
            if url.pathExtension == "fcpxml" || url.pathExtension == "fcpxmld" {
                // FCP sent us FCPXML with editing decisions
                processExportedFCPXML(url)
            } else {
                // FCP sent us rendered media
                processRenderedMedia(url)
            }
        }
    }
}
```

### 3. Register as Share Destination

In your app's Info.plist:

```xml
<key>CFBundleDocumentTypes</key>
<array>
    <dict>
        <key>CFBundleTypeName</key>
        <string>FCPXML Document</string>
        <key>CFBundleTypeExtensions</key>
        <array>
            <string>fcpxml</string>
            <string>fcpxmld</string>
        </array>
        <key>CFBundleTypeRole</key>
        <string>Viewer</string>
    </dict>
</array>
```

### What You Receive

| From FCP | Content |
|----------|---------|
| Rendered media | Movie file (ProRes, H.264, HEVC, etc.) |
| FCPXML | Editing decisions, clip list, metadata |
| Both | Complete export package |

Users configure the share destination in FCP's Share menu (File > Share > Add Destination).

---

## Associating Metadata with Media

### Keywords

Apply to time ranges within clips:

```xml
<asset-clip ref="r2" duration="600600/24000s">
    <!-- Multiple keywords on overlapping ranges -->
    <keyword start="0s" duration="600600/24000s" value="interview"/>
    <keyword start="0s" duration="120120/24000s" value="intro"/>
    <keyword start="240240/24000s" duration="120120/24000s" value="key-point"/>
</asset-clip>
```

### Ratings

Mark ranges as favorites or rejects:

```xml
<asset-clip ref="r2" duration="600600/24000s">
    <rating start="48048/24000s" duration="120120/24000s" value="favorite"/>
    <rating start="360360/24000s" duration="48048/24000s" value="reject"/>
</asset-clip>
```

### Markers

Point-in-time annotations:

```xml
<asset-clip ref="r2" duration="600600/24000s">
    <marker start="0s" duration="1001/24000s" value="Slate"/>
    <marker start="96096/24000s" duration="1001/24000s" value="Action starts"/>
    <chapter-marker start="240240/24000s" duration="1001/24000s"
                    value="Part 2" posterOffset="12012/24000s"/>
</asset-clip>
```

### Custom Metadata

Standard keys recognized by FCP:

| Key | Description |
|-----|-------------|
| `com.apple.proapps.studio.reel` | Reel name |
| `com.apple.proapps.studio.scene` | Scene number |
| `com.apple.proapps.studio.shot` | Shot/take info |
| `com.apple.proapps.studio.angle` | Camera angle |
| `com.apple.proapps.mio.cameraName` | Camera identifier |
| `com.apple.proapps.mio.cameraAngle` | Camera angle name |

```xml
<asset-clip ref="r2" duration="600600/24000s">
    <metadata>
        <md key="com.apple.proapps.studio.reel" value="Reel_001"/>
        <md key="com.apple.proapps.studio.scene" value="12A"/>
        <md key="com.apple.proapps.studio.shot" value="Take 3"/>
    </metadata>
</asset-clip>
```

### Audio Roles

Assign audio roles for organization:

```xml
<asset-clip ref="r2" audioRole="dialogue.interview-1"/>
<asset-clip ref="r3" audioRole="music.score"/>
<asset-clip ref="r4" audioRole="effects.ambience"/>
```

Standard roles: `dialogue`, `music`, `effects`
Custom subroles: `dialogue.interview-1`, `music.score`, etc.

---

## Effect Templates for FCP

Package custom FxPlug effects as Motion templates for use in Final Cut Pro.

### Creating a Template

1. **Open Motion** and create a new project matching your effect type:
   - Filter template → for video effects
   - Generator template → for generators
   - Title template → for titles
   - Transition template → for transitions

2. **Apply your FxPlug effect** to content in the Motion project

3. **Configure defaults** — set parameter values, add behaviors, adjust timing

4. **Publish parameters** — Control-click parameters and choose "Publish" to expose
   them in FCP's inspector

5. **Save as template**: File > Save as Template
   - Choose a category (existing or new)
   - Set a theme if applicable
   - The template is saved to `~/Movies/Motion Templates/`

### Template Location

```
~/Movies/Motion Templates/
├── Effects.localized/
│   └── My Category.localized/
│       └── My Effect.localized/
│           └── My Effect.moef
├── Generators.localized/
├── Titles.localized/
└── Transitions.localized/
```

### Distribution

Distribute templates by:
- Packaging in a `.pkg` installer that copies to the correct directory
- Including in your FxPlug app bundle's Resources
- Providing manual installation instructions

---

## Encoder Extensions

Add custom output formats to FCP's export pipeline via Compressor.

### Overview

Encoder extensions are Compressor plugins that add custom transcoding formats.
When installed, these formats appear in FCP's share destinations.

### Architecture

```
FCP Share → Compressor → Your Encoder Extension → Custom Output File
```

### Key Points

- Built using the Compressor SDK (Objective-C only)
- Distributed inside a macOS app
- Can use Qmaster distributed processing
- Custom format appears in Compressor's Settings interface
- Users can select it as an FCP share destination

### Use Cases

- Proprietary video formats
- Custom container formats
- Direct upload to specific platforms
- Specialized compression for broadcast

---

## Integration with FCPBridge

FCPBridge provides deeper integration than the standard exchange mechanisms:

### Import FCPXML

```python
# Generate FCPXML programmatically
xml = generate_fcpxml(
    project_name="Auto Edit",
    frame_rate="24",
    items='[
        {"type":"title","text":"Chapter 1","duration":5},
        {"type":"gap","duration":10},
        {"type":"marker","time":5,"name":"Review"}
    ]'
)

# Import without restart
import_fcpxml(xml, internal=True)
```

### Export FCPXML

```python
# Export current project
export_xml()
```

### Media Import

```python
# Import media files
import_media(["/path/to/clip1.mov", "/path/to/clip2.mov"])
```

### Pasteboard Integration

FCPBridge can work with FCP's native pasteboard for attribute-preserving operations
(see [FCP Pasteboard & Media Linking](FCP_PASTEBOARD_MEDIA_LINKING.md)):

```python
# Copy/paste with attributes preserved
timeline_action("selectClipAtPlayhead")
timeline_action("copy")
# ... navigate ...
timeline_action("paste")
```

### Batch Export

```python
# Export each clip individually with effects baked in
batch_export()                    # All clips
batch_export(scope="selected")    # Selected clips only
```

### Combining Approaches

For the richest workflow, combine standard exchange with FCPBridge:

1. **Ingest**: Use FCPXML to send media with metadata to FCP
2. **Automate**: Use FCPBridge to apply effects, color, and edits
3. **Export**: Use FCPBridge's batch_export or share_project
4. **Process**: Receive output via custom share destination

---

*Based on Apple's Content and Metadata Exchange documentation for Final Cut Pro.*
