# Workflow Extensions Guide

Build extensions that embed directly inside Final Cut Pro's UI, interact with the
timeline, and exchange data with the editing workflow.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Building a Workflow Extension](#building-a-workflow-extension)
4. [Timeline Interaction](#timeline-interaction)
5. [Timeline Proxy Objects](#timeline-proxy-objects)
6. [Observing Timeline Changes](#observing-timeline-changes)
7. [Design Guidelines](#design-guidelines)
8. [Data Exchange Patterns](#data-exchange-patterns)
9. [Comparison: Extensions vs FCPBridge](#comparison-extensions-vs-fcpbridge)

---

## Overview

Workflow extensions are macOS app extensions that appear as floating windows inside
Final Cut Pro. They let third-party developers embed custom UI directly into the
FCP workspace for tasks like:

- Asset management and media browsing
- Review and approval workflows
- Cloud rendering and delivery
- Frame.io-style collaboration
- Custom metadata management
- AI-powered clip analysis

Workflow extensions use the **ProExtensionHost** framework to communicate with FCP.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Final Cut Pro                                            │
│                                                           │
│  ┌──────────────────────────────────────────────────┐    │
│  │  Workflow Extension Window (floating)              │    │
│  │                                                    │    │
│  │  ┌──────────────────────────────────────────┐     │    │
│  │  │  Your Extension View Controller           │     │    │
│  │  │  (NSViewController subclass)              │     │    │
│  │  │                                           │     │    │
│  │  │  ProExtensionHostSingleton() → FCPXHost   │     │    │
│  │  │       └── .timeline → FCPXTimeline        │     │    │
│  │  │            ├── .activeSequence             │     │    │
│  │  │            ├── .playheadTime()             │     │    │
│  │  │            ├── .movePlayhead(to:)          │     │    │
│  │  │            └── .add(observer)              │     │    │
│  │  └──────────────────────────────────────────┘     │    │
│  └──────────────────────────────────────────────────┘    │
│                                                           │
│  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐     │
│  │  Timeline    │  │  Viewer     │  │  Inspector   │     │
│  └─────────────┘  └─────────────┘  └──────────────┘     │
└──────────────────────────────────────────────────────────┘
```

The extension runs in its own process but appears as part of FCP's window hierarchy.
Communication with FCP happens through the ProExtensionHost framework's proxy objects.

---

## Building a Workflow Extension

### Prerequisites

- Xcode with the Workflow Extension SDK template
- Final Cut Pro 10.4.4 or later
- macOS 10.14.4 or later

### Project Setup

1. Create a new Xcode project using the **Workflow Extension** template
2. The template creates a container app and the extension target

### Info.plist Configuration

The extension's `Info.plist` needs these keys:

```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.FinalCut.WorkflowExtension</string>
    
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).ExtensionViewController</string>
    
    <key>NSExtensionAttributes</key>
    <dict>
        <!-- Minimum window size -->
        <key>ProExtensionMinWidth</key>
        <integer>400</integer>
        <key>ProExtensionMinHeight</key>
        <integer>300</integer>
    </dict>
</dict>
```

### Principal View Controller

Your extension's entry point is an `NSViewController` subclass:

```swift
import Cocoa
import ProExtensionHost

class ExtensionViewController: NSViewController {
    
    var host: FCPXHost? {
        return ProExtensionHostSingleton() as? FCPXHost
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Access the host
        guard let host = host else {
            print("Not running inside Final Cut Pro")
            return
        }
        
        print("Host: \(host.name) v\(host.versionString)")
        print("Bundle ID: \(host.bundleIdentifier)")
        
        // Access the timeline
        let timeline = host.timeline
        
        // Register as observer
        timeline.add(self)
    }
}
```

### Debugging

Debug workflow extensions by:
1. Setting the extension target as the active scheme
2. Setting "Final Cut Pro" as the launch target in scheme settings
3. Running from Xcode — it launches FCP and attaches the debugger
4. Open the extension from FCP's Window > Extensions menu

---

## Timeline Interaction

### Accessing the Timeline

```swift
guard let host = ProExtensionHostSingleton() as? FCPXHost else { return }
let timeline = host.timeline
```

### FCPXTimeline Methods

| Method/Property | Description |
|----------------|-------------|
| `activeSequence` | Currently active sequence in the timeline |
| `sequenceTimeRange` | Time range of the active sequence |
| `playheadTime()` | Current playhead position as CMTime |
| `movePlayhead(to:)` | Move the playhead to a specific time |
| `add(_:)` | Register an observer for timeline changes |
| `remove(_:)` | Unregister an observer |

### Moving the Playhead

```swift
import CoreMedia

// Jump to 5 seconds at 24fps
let time = CMTime(value: 120, timescale: 24)
timeline.movePlayhead(to: time)

// Jump to start
let start = timeline.activeSequence?.startTime ?? CMTime.zero
timeline.movePlayhead(to: start)
```

### Reading Sequence Details

```swift
if let sequence = timeline.activeSequence {
    print("Name: \(sequence.name)")
    print("Duration: \(sequence.duration)")
    print("Frame duration: \(sequence.frameDuration)")
    print("Start time: \(sequence.startTime)")
    print("Timecode format: \(sequence.timecodeFormat)")
}
```

---

## Timeline Proxy Objects

The ProExtensionHost framework provides proxy objects representing FCP's timeline
hierarchy:

```
FCPXHost
└── timeline: FCPXTimeline
    └── activeSequence: FCPXSequence
        └── container: FCPXObject
            └── FCPXProject
                └── container: FCPXObject
                    └── FCPXEvent
                        └── container: FCPXObject
                            └── FCPXLibrary
```

### FCPXHost

| Property | Type | Description |
|----------|------|-------------|
| `bundleIdentifier` | String | Host app bundle ID |
| `name` | String | Host app name |
| `versionString` | String | Host app version |
| `timeline` | FCPXTimeline | Timeline proxy |

### FCPXSequence

| Property | Type | Description |
|----------|------|-------------|
| `name` | String | Sequence name |
| `duration` | CMTime | Total sequence duration |
| `frameDuration` | CMTime | Duration of one frame |
| `startTime` | CMTime | Sequence start timecode |
| `timecodeFormat` | FCPXSequenceTimecodeFormat | NDF or DF |

### FCPXProject

| Property | Type | Description |
|----------|------|-------------|
| `name` | String | Project name |
| `uid` | String | Unique identifier |
| `sequence` | FCPXSequence | The project's sequence |

### FCPXEvent

| Property | Type | Description |
|----------|------|-------------|
| `name` | String | Event name |
| `uid` | String | Unique identifier |

### FCPXLibrary

| Property | Type | Description |
|----------|------|-------------|
| `name` | String | Library name |
| `url` | URL | File system location |

### FCPXObject (Base Class)

| Property | Type | Description |
|----------|------|-------------|
| `container` | FCPXObject? | Parent container |
| `objectType` | FCPXObjectType | Type enum |

### FCPXObjectType Enum

| Value | Description |
|-------|-------------|
| `.sequence` | A timeline sequence |
| `.project` | A project |
| `.event` | An event |
| `.library` | A library |

### Navigating the Hierarchy

```swift
guard let sequence = timeline.activeSequence else { return }

// Walk up to the library
var current: FCPXObject? = sequence
while let obj = current {
    switch obj.objectType {
    case .sequence:
        print("Sequence: \((obj as! FCPXSequence).name)")
    case .project:
        print("Project: \((obj as! FCPXProject).name)")
    case .event:
        print("Event: \((obj as! FCPXEvent).name)")
    case .library:
        let lib = obj as! FCPXLibrary
        print("Library: \(lib.name) at \(lib.url)")
    @unknown default:
        break
    }
    current = obj.container
}
```

---

## Observing Timeline Changes

Implement `FCPXTimelineObserver` to react to timeline state changes:

```swift
extension ExtensionViewController: FCPXTimelineObserver {
    
    /// Called when the user opens a different project/sequence
    func activeSequenceChanged() {
        guard let sequence = host?.timeline.activeSequence else {
            // No sequence open
            updateUI(for: nil)
            return
        }
        updateUI(for: sequence)
    }
    
    /// Called when the playhead moves (scrubbing, playback, jumping)
    func playheadTimeChanged() {
        let time = host?.timeline.playheadTime()
        updatePlayheadDisplay(time)
    }
    
    /// Called when the sequence duration changes (edits, insertions)
    func sequenceTimeRangeChanged() {
        let range = host?.timeline.sequenceTimeRange
        updateTimelineRange(range)
    }
}
```

### Registration

```swift
// Start observing
host?.timeline.add(self)

// Stop observing (e.g., in deinit or viewWillDisappear)
host?.timeline.remove(self)
```

> **Important**: Register the observer before reading timeline properties.
> Accessing properties before FCP invokes the observer may return `nil`.

---

## Design Guidelines

### Window Size

Workflow extensions appear as resizable floating windows within FCP. Respect the
minimum size constraints and design for the constrained space:

- Set minimum width/height in Info.plist (`ProExtensionMinWidth`, `ProExtensionMinHeight`)
- Design for the extension to be resized by the user
- Don't assume a fixed aspect ratio

### UX Best Practices

- **Don't block the main thread** — FCP's UI remains interactive while your extension runs
- **Respect the editing workflow** — extensions supplement, don't replace, FCP's tools
- **Handle disconnection** — FCP may close your extension; save state appropriately
- **Use native macOS controls** — blend with FCP's interface style
- **Minimize modal dialogs** — use inline UI where possible
- **Provide feedback** — show progress for long operations (uploads, processing)

### Light/Dark Mode

Support both appearance modes since FCP uses a dark interface:

```swift
override func viewDidLoad() {
    super.viewDidLoad()
    view.appearance = NSAppearance(named: .darkAqua)
}
```

---

## Data Exchange Patterns

Workflow extensions can exchange data with FCP through several mechanisms:

### 1. FCPXML via Pasteboard

Write FCPXML to the system pasteboard for FCP to import:

```swift
let fcpxml = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>
<fcpxml version="1.11">
    <resources>...</resources>
    <event name="From Extension">...</event>
</fcpxml>
"""

let pasteboard = NSPasteboard.general
pasteboard.clearContents()
pasteboard.setString(fcpxml, forType: NSPasteboard.PasteboardType("com.apple.finalcutpro.xml"))
```

### 2. Drag and Drop to FCP

Support dragging media from your extension into FCP:

```swift
// In your dragging source
func draggingSession(_ session: NSDraggingSession,
                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    return .copy
}

// Write FCPXML or file URLs to the dragging pasteboard
func writeToPasteboard(_ pasteboard: NSPasteboard) {
    // Option A: File URLs
    pasteboard.writeObjects([mediaURL as NSURL])
    
    // Option B: FCPXML with metadata
    let fcpxml = buildFCPXMLForDrag()
    pasteboard.setString(fcpxml,
        forType: NSPasteboard.PasteboardType("com.apple.finalcutpro.xml"))
}
```

### 3. Drag and Drop from FCP

Receive data dragged from FCP's browser or timeline:

```swift
// Register for drag types
view.registerForDraggedTypes([
    NSPasteboard.PasteboardType("com.apple.finalcutpro.xml"),
    .fileURL
])

func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let pasteboard = sender.draggingPasteboard
    
    // Check for FCPXML data
    if let xml = pasteboard.string(forType:
            NSPasteboard.PasteboardType("com.apple.finalcutpro.xml")) {
        processFCPXML(xml)
        return true
    }
    
    // Check for file URLs
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
        processFiles(urls)
        return true
    }
    
    return false
}
```

### 4. Apple Events (Programmatic)

Send media to FCP programmatically using Apple Events:

```swift
// Requires scripting definition (.sdef) for the sending app
let fcpURL = NSWorkspace.shared.urlForApplication(
    withBundleIdentifier: "com.apple.FinalCut"
)
// Send Apple Event with FCPXML payload
```

### 5. Custom Share Destinations

Register your app as a share destination to receive rendered output from FCP:

1. Create a scripting definition (`.sdef`) file
2. Implement Apple Event handlers for the share events
3. Register as a share destination in your app's Info.plist

FCP sends rendered media and editing decisions (as FCPXML) to your destination.

---

## Comparison: Extensions vs FCPBridge

| Capability | Workflow Extension | FCPBridge |
|-----------|-------------------|-----------|
| **Architecture** | App extension (sandboxed) | Injected dylib (in-process) |
| **UI** | Floating window in FCP | External (MCP/JSON-RPC) |
| **Timeline read** | Sequence metadata only | Full clip/effect access |
| **Timeline write** | Via FCPXML import | Direct method calls |
| **Playhead control** | `movePlayhead(to:)` | `playback_action()` |
| **Editing actions** | None (import FCPXML) | 200+ actions (blade, color, etc.) |
| **Effect parameters** | None | Full inspector read/write |
| **Internal classes** | Not accessible | All 78,000+ ObjC classes |
| **Distribution** | App Store / Developer ID | Requires injection |
| **Stability** | Stable public API | Private API (may break) |
| **Sandboxing** | Required | Not applicable |

### When to Use Each

**Use Workflow Extensions when:**
- You need a UI embedded in FCP
- You're distributing through the App Store
- You only need sequence-level metadata and playhead control
- Your workflow is primarily about media management / external services

**Use FCPBridge when:**
- You need programmatic control of editing actions
- You need to read/write effect parameters
- You need access to FCP's internal class hierarchy
- You're building automation, AI editing, or batch processing tools

**Use Both Together:**
- Extension provides the UI, FCPBridge provides the deep integration
- Extension handles the user-facing workflow, FCPBridge executes the edits

---

*Based on Apple's ProExtensionHost framework documentation and the Workflow Extension SDK.*
