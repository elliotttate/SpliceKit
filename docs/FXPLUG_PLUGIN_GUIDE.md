# FxPlug 4 Plugin Development Guide

Complete guide to building FxPlug video effect plugins for Final Cut Pro and Motion.
FCPBridge includes a reference LUT plugin implementation in `LUTPlugin/`.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Development Setup](#development-setup)
3. [Project Structure](#project-structure)
4. [Info.plist Configuration](#infoplist-configuration)
5. [Adding Parameters](#adding-parameters)
6. [Plugin State and Rendering](#plugin-state-and-rendering)
7. [Metal Rendering Pipeline](#metal-rendering-pipeline)
8. [Thread Safety](#thread-safety)
9. [Color Space and Gamut](#color-space-and-gamut)
10. [Pixel Transforms and Optimization](#pixel-transforms-and-optimization)
11. [Tiled Rendering](#tiled-rendering)
12. [Custom Parameter Views](#custom-parameter-views)
13. [Onscreen Controls](#onscreen-controls)
14. [Media Analysis](#media-analysis)
15. [Time and Scheduling](#time-and-scheduling)
16. [Undo and Host Commands](#undo-and-host-commands)
17. [Versioning and Migration](#versioning-and-migration)
18. [Preparing Plugins for Final Cut Pro](#preparing-plugins-for-final-cut-pro)
19. [Testing](#testing)
20. [Notarization and Distribution](#notarization-and-distribution)
21. [Reference: FCPBridge LUT Plugin](#reference-fcpbridge-lut-plugin)
22. [API Quick Reference](#api-quick-reference)

---

## Architecture Overview

FxPlug 4 plugins run **out-of-process** via XPC services. The plugin runs in a dedicated
process outside the host app (Final Cut Pro or Motion), communicating over interprocess
communication using **IOSurface** for zero-copy texture sharing.

```
┌─────────────────────┐         XPC / IOSurface         ┌──────────────────────┐
│   Host Application  │◄───────────────────────────────►│   Plugin XPC Service │
│  (FCP / Motion)     │                                  │  (Your Plugin)       │
│                     │  1. PlugInKit discovers plugin   │                      │
│  - Manages params   │  2. Host sends param state       │  - Renders frames    │
│  - Displays UI      │  3. Plugin renders to IOSurface  │  - Stateless design  │
│  - Composites       │  4. Host composites result       │  - Metal shaders     │
└─────────────────────┘                                  └──────────────────────┘
```

### Key Principles

- **Stateless XPC**: XPC services can become invalid at any point without affecting the host.
  They should remain stateless — all render state is passed via the plugin state `NSData` blob.
- **No API access at render time**: You cannot call `FxParameterRetrievalAPI` during rendering.
  All parameter values must be packed into the plugin state beforehand.
- **IOSurface-backed images**: All image data arrives as `FxImageTile` objects backed by
  `IOSurface`, replacing the old `FxTexture`/`FxBitmap` types from FxPlug 3.
- **PlugInKit discovery**: macOS uses PlugInKit to discover and register plugins. After building,
  launch the wrapper app once to register with PlugInKit.

### Startup Best Practices

- Avoid long-running tasks on startup — don't block the host's response.
- Push background work (font enumeration, server connections) to background threads.
- Don't display dialogs on startup — this stops host playback.
- Don't initialize resources until the user actually needs them.
- If using dynamic registration, load all plugin classes on restart.

---

## Development Setup

### Prerequisites

| Software | Minimum Version |
|----------|----------------|
| Xcode | 15 or newer |
| FxPlug 4 SDK | [Download from Apple](https://developer.apple.com/download/all/?q=FxPlug) |
| Motion | 5.6.4 or newer |
| Final Cut Pro | 10.6.6 or newer |

### Creating a Project from Template

1. Launch Xcode, choose "Create a new Xcode project"
2. Select **macOS** category, find **FxPlug 4** template, click Next
3. Enter Product Name, Organization ID, choose Swift or Objective-C
4. Build and run with "Wrapper Application" as the active scheme
5. Quit the wrapper app — macOS now recognizes the plugin

> The wrapper app only needs to be launched once for PlugInKit registration.
> After that, the host app discovers it automatically.

### Testing in Motion

1. Launch Motion, create a new project
2. Add content (e.g., a Checkerboard generator from Library > Generators)
3. With content selected, go to Library > Filters, search for your plugin name
4. Apply and adjust parameters in the Inspector

---

## Project Structure

An FxPlug 4 plugin is an application bundle containing an embedded XPC service:

```
MyPlugin.app/
├── Contents/
│   ├── Info.plist              ← App bundle plist (minimal)
│   ├── MacOS/
│   │   └── MyPlugin            ← App binary (wrapper, rarely used)
│   ├── Resources/
│   │   └── MainMenu.xib
│   └── XPCServices/
│       └── MyPluginXPC.xpc/
│           ├── Contents/
│           │   ├── Info.plist   ← XPC plist (critical - plugin config)
│           │   ├── MacOS/
│           │   │   └── MyPluginXPC
│           │   └── Resources/
│           │       └── default.metallib
│           └── ...
```

The XPC service is where all the real work happens — the wrapper app is just a container
for registration purposes.

---

## Info.plist Configuration

The XPC service's `Info.plist` is critical. It tells PlugInKit how to find and categorize
your plugin.

### Required PlugInKit Keys

```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.pluginkit.pv</string>
    <key>NSExtensionAttributes</key>
    <dict>
        <key>com.apple.protocol</key>
        <string>FxPlug</string>
        <key>com.apple.version</key>
        <string>4</string>
    </dict>
    <key>NSExtensionPrincipalClass</key>
    <string>FxPrincipal</string>
    <key>Protocol</key>
    <string>PROXPCProtocol</string>
    <key>RunLoopType</key>
    <string>_NSApplication</string>
    <key>JoinExistingSession</key>
    <true/>
    <key>_AdditionalSubServices</key>
    <dict>
        <key>viewbridge</key>
        <true/>
    </dict>
</dict>
```

### Plugin Registration Keys

```xml
<!-- Plugin group (appears in host's browser) -->
<key>ProPlugPlugInGroupList</key>
<array>
    <dict>
        <key>groupName</key>
        <string>My Plugin Group</string>
        <key>groupUUID</key>
        <string>XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX</string>
    </dict>
</array>

<!-- Plugin definition -->
<key>ProPlugPlugInList</key>
<array>
    <dict>
        <key>className</key>
        <string>MyPluginClass</string>
        <key>displayName</key>
        <string>My Effect</string>
        <key>infoString</key>
        <string>A custom video effect</string>
        <key>plugInUUID</key>
        <string>YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY</string>
        <key>groupUUID</key>
        <string>XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX</string>
        <key>protocolNames</key>
        <array>
            <string>FxFilter</string>  <!-- or FxGenerator -->
        </array>
        <key>version</key>
        <integer>1</integer>
    </dict>
</array>
```

> Generate unique UUIDs from Terminal with `uuidgen`. Every plugin needs its own UUID.

### Static vs Dynamic Registration

By default, plugins use **static registration** — the host reads the plist and
loads plugins automatically. This is preferred for performance.

**Dynamic registration** (`ProPlugDynamicRegistration = YES`) lets your principal class
register plugins at runtime. This incurs a scanning performance hit but allows
runtime-determined plugin lists. If using dynamic registration, also add:
- `ProPlugDynamicRegistrationPrincipalClass` — name of the registrar class
- `ProPlugDictionaryVersion` — version number

---

## Adding Parameters

When the host instantiates your plugin, it calls `addParameters()` to build the
inspector UI. Use `FxParameterCreationAPI_v5` to add parameters.

### Standard Parameter Types

| Type | Method | Notes |
|------|--------|-------|
| Float slider | `addFloatSlider` | Min/max/default range |
| Integer slider | `addIntSlider` | Discrete integer values |
| Percent slider | `addPercentSlider` | 0–100% range |
| Angle slider | `addAngleSlider` | Rotation in degrees |
| Toggle (checkbox) | `addToggleButton` | Boolean on/off |
| Color (RGB/RGBA) | `addColorParameter` | Color picker in inspector |
| Point | `addPointParameter` | XY coordinate |
| Popup menu | `addPopupMenu` | Dropdown selection |
| String | `addStringParameter` | Text input |
| Gradient | `addGradient` | Gradient editor |
| Font menu | `addFontMenu` | System font picker |
| Image reference | `addImageReference` | Image well for drop targets |
| Group | `addParameterGroup` | Visual grouping in inspector |
| Push button | `addPushButton` | Clickable button |
| Help button | `addHelpButton` | Links to documentation |
| Histogram | `addHistogram` | Channel histogram display |
| Path picker | `addPathPicker` | Path/mask selection |

### Example: Simple Brightness Filter

```swift
func addParameters() throws {
    guard let api = apiManager?.api(for: FxParameterCreationAPI_v5.self)
            as? FxParameterCreationAPI_v5 else { return }
    
    api.addFloatSlider(
        withName: "Brightness",
        parameterID: 1,
        defaultValue: 1.0,
        parameterMin: 0.0,
        parameterMax: 2.0,
        sliderMin: 0.0,
        sliderMax: 2.0,
        delta: 0.01,
        parameterFlags: []
    )
}
```

> **Parameter IDs must be in the range [1, 9998].** IDs outside this range are invalid.

> A Mix slider is automatically added to filter plugins. A Publish OSC toggle is
> added in Motion for plugins with onscreen controls.

### Custom Parameters

For opaque data types, use `addCustomParameter`. Each custom parameter requires an
associated custom view (see [Custom Parameter Views](#custom-parameter-views)).

### Parameter Change Callbacks

When users change a parameter, the host calls `parameterChanged(_:at:)`. Use this to
react to changes — hide/reveal other parameters, update dependent values, etc.

### Parameter Flags

Control parameter display and behavior:

| Flag | Effect |
|------|--------|
| `kFxParameterFlag_COLLAPSED` | Start collapsed in inspector |
| `kFxParameterFlag_HIDDEN` | Hide from inspector |
| `kFxParameterFlag_DISABLED` | Show but disable interaction |
| `kFxParameterFlag_CUSTOM_UI` | Use custom view |
| `kFxParameterFlag_DONT_REMAP_COLORS` | Don't convert color values |

---

## Plugin State and Rendering

This is the most critical concept in FxPlug 4: **you cannot access host APIs at render
time**. All information must be prepared beforehand in the plugin state.

### The Plugin State Pattern

```
  ┌──────────────────┐       ┌──────────────────┐       ┌─────────────────┐
  │  pluginState()   │──────►│   NSData blob     │──────►│ renderDest...() │
  │                  │       │                   │       │                 │
  │  - Query params  │       │  Serialized       │       │  - Unpack data  │
  │  - Calculate     │       │  struct/values    │       │  - Set uniforms │
  │  - Pack NSData   │       │                   │       │  - Draw metal   │
  └──────────────────┘       └──────────────────┘       └─────────────────┘
       Host process              Passed via XPC              Plugin process
```

### Step 1: Gather State (pluginState)

```swift
struct RenderParams {
    var brightness: Float
    var contrast: Float
    var saturation: Float
}

func pluginState(_ pluginState: AutoreleasingUnsafeMutablePointer<NSData?>,
                 at renderTime: CMTime,
                 quality qualityLevel: UInt) throws {
    guard let api = apiManager?.api(for: FxParameterRetrievalAPI_v6.self)
            as? FxParameterRetrievalAPI_v6 else { return }
    
    var params = RenderParams()
    api.getFloatValue(&params.brightness, fromParameter: 1, at: renderTime)
    api.getFloatValue(&params.contrast, fromParameter: 2, at: renderTime)
    api.getFloatValue(&params.saturation, fromParameter: 3, at: renderTime)
    
    pluginState.pointee = NSData(bytes: &params, length: MemoryLayout<RenderParams>.size)
}
```

### Step 2: Render (renderDestinationImage)

```swift
func renderDestinationImage(_ destinationImage: FxImageTile,
                            sourceImages: [FxImageTile],
                            pluginState: NSData?,
                            at renderTime: CMTime) throws {
    guard let data = pluginState else { return }
    
    let params = data.withUnsafeBytes { ptr in
        ptr.load(as: RenderParams.self)
    }
    
    // Use params.brightness, params.contrast, etc. with Metal rendering
    let deviceID = destinationImage.deviceRegistryID
    // ... Metal rendering code ...
}
```

### Rendering Steps (Always in This Order)

1. **Gather state** — Query parameters, make calculations, pack into `NSData`
2. **Set output bounds** — Tell the host what the output area will be
3. **Request input tiles** — For each output tile, specify which input tiles you need
4. **Draw** — Render each output tile using Metal (or other frameworks)

---

## Metal Rendering Pipeline

FxPlug 4 uses `IOSurface`-backed `FxImageTile` objects for all image data. Metal is
the recommended rendering approach.

### Device Management

Each `FxImageTile` has a `deviceRegistryID` identifying which GPU holds the texture.
Cache Metal pipeline state per device and per pixel format.

```swift
class MetalDeviceCache {
    struct DeviceEntry {
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        var pipelineStates: [MTLPixelFormat: MTLRenderPipelineState]
    }
    
    var entries: [UInt64: DeviceEntry] = [:]  // Keyed by deviceRegistryID
    
    func device(for registryID: UInt64) -> MTLDevice? {
        if let entry = entries[registryID] { return entry.device }
        // Find matching device from MTLCopyAllDevices()
        for device in MTLCopyAllDevices() {
            if device.registryID == registryID {
                let queue = device.makeCommandQueue()!
                entries[registryID] = DeviceEntry(
                    device: device, commandQueue: queue, pipelineStates: [:]
                )
                return device
            }
        }
        return nil
    }
}
```

### Working with IOSurface Textures

```swift
// Get input/output IOSurfaces
let inputSurface = sourceImages[0].ioSurface
let outputSurface = destinationImage.ioSurface

// Create Metal textures from IOSurfaces
let textureDesc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba16Float,
    width: IOSurfaceGetWidth(inputSurface),
    height: IOSurfaceGetHeight(inputSurface),
    mipmapped: false
)
let inputTexture = device.makeTexture(descriptor: textureDesc, iosurface: inputSurface, plane: 0)
```

### Common Pixel Formats

| Format | Use Case |
|--------|----------|
| `.rgba32Float` | Full precision (32-bit per channel) |
| `.rgba16Float` | Standard HDR workflow |
| `.bgra8Unorm` | Standard dynamic range |

### Storage Mode

Check for unified memory (Apple Silicon) to optimize:

```swift
let storageMode: MTLResourceOptions = device.hasUnifiedMemory
    ? .storageModeShared
    : .storageModeManaged
```

> **Performance note**: Avoid setting `kIOSurfacePixelSizeCastingAllowed` on IOSurfaces
> unless absolutely necessary (e.g., 4:4:4 to 4:2:2 conversion). It causes the host to
> copy input/output surfaces, hurting performance.

---

## Thread Safety

FxPlug 4 handles host requests on a **serial queue** on a background thread, but many
requests move to a **concurrent queue** for processing. This means multiple threads can
call your plugin methods simultaneously.

### Two-Phase Rendering Pipeline

The host rendering system works in two phases on **different threads**:

1. **Graph building** — Generates a render graph of objects to composite
2. **Rendering** — Actually renders and composites those objects

On multi-GPU systems, the host may build graphs for frames `n` and `n+1` while rendering
frames `n-2` and `n-1`. This means your plugin must be fully thread-safe.

### Thread Safety Strategies

#### 1. Use Immutable Data

Data that can't be modified is safe across threads. Use `NSArray`/`NSDictionary` instead
of their mutable variants. Design custom classes with immutable variants.

#### 2. Copy Per-Thread

If you need mutable data, have each thread create its own copy:

```swift
// Each thread gets its own copy
func processFrame() {
    var localData = sharedTemplate.copy()  // Thread-local copy
    // Mutate localData safely
}
```

#### 3. Synchronize with Locks

When copying isn't feasible, protect shared data with locks:

```swift
private let positionLock = NSLock()
private var lastPosition: CGPoint = .zero

func mouseDown(atPositionX x: Double, positionY y: Double, ...) {
    positionLock.lock()
    lastPosition = CGPoint(x: x, y: y)
    positionLock.unlock()
}
```

### Methods Called on Background Threads

All of these can be called concurrently:
- `pluginState(_:at:quality:)`
- `parameterChanged(_:at:)`
- `renderDestinationImage(_:sourceImages:pluginState:at:)`
- Most other `FxTileableEffect` protocol methods

---

## Color Space and Gamut

Final Cut Pro and Motion use a **color-managed pipeline**. Input images and colors are
converted to the *working color space* before reaching your plugin.

### Working Color Space

The working color space is determined by two factors:

1. **Plugin's desired color space** — gamma-corrected or linear
2. **Project's color gamut** — Rec. 709 or Rec. 2020 (user-controlled)

Set your preferred color space in the properties dictionary:

```swift
func properties(_ properties: AutoreleasingUnsafeMutablePointer<NSDictionary>) throws {
    properties.pointee = [
        kFxPropertyKey_DesiredProcessingColorInfo: kFxImageColorInfo_RGB_LINEAR
    ]
}
```

### Working Color Space Matrix

|  | Rec. 709 Gamut | Rec. 2020 Gamut |
|--|----------------|-----------------|
| **Linear** | Linear Rec. 709 | Linear Rec. 2020 |
| **Gamma-corrected** | Rec. 709 | Rec. 2020 |

### Color Value Handling

- Default color parameter values are specified in **sRGB**
- At retrieval time, host converts to working color space automatically
- Example: sRGB `(0.5, 0.5, 0.5)` → Linear Rec. 709 `(0.214, 0.214, 0.214)`
- Use `kFxParameterFlag_DONT_REMAP_COLORS` for non-color data stored in color params

### Out-of-Gamut Colors

Your plugin **must handle** color values outside `[0, 1]`:
- Values > 1.0 = brighter/more saturated (intuitive)
- Negative values = higher saturation (counterintuitive: `(1, 1, -0.2)` is hyper-saturated yellow)
- Negative components can skew luminance calculations — handle appropriately

Options: clamp, absolute value, or sophisticated gamut mapping.

### RGB ↔ YCbCr Conversion

Use `FxColorGamutAPI_v2` for conversion matrices:

```swift
guard let gamutAPI = apiManager?.api(for: FxColorGamutAPI_v2.self)
        as? FxColorGamutAPI_v2 else { return }

var rgbToYCbCr = FxMatrix44()
gamutAPI.colorMatrixFromDesiredRGBToYCbCr(&rgbToYCbCr)

// For luminance only: dot product of first row with RGB color
```

---

## Pixel Transforms and Optimization

Pixel transforms are 4x4 matrices created by the host containing transformation
information about the media. They handle proxy resolution, thumbnails, non-square
pixels, and 3D transforms automatically.

### Declaring Transform Support

```swift
func properties(_ properties: AutoreleasingUnsafeMutablePointer<NSDictionary>) throws {
    properties.pointee = [
        kFxPropertyKey_PixelTransformSupport: kFxPixelTransform_Full,
        kFxPropertyKey_PixelIndependent: true  // For pure color filters
    ]
}
```

| Transform Level | Supports |
|----------------|----------|
| `kFxPixelTransform_Scale` | Non-uniform scaling only (default) |
| `kFxPixelTransform_ScaleTranslate` | Scaling + translation |
| `kFxPixelTransform_Full` | Any affine or perspective transform |

`kFxPropertyKey_PixelIndependent` = true means each output pixel depends on exactly one
input pixel at the same location (e.g., color correction). This enables major optimizations.

### Using Pixel Transforms in Shaders

1. Get the inverse pixel transform from the input `FxImageTile`
2. Transform current pixel coordinate → document space (full-res, square pixels)
3. Do your calculations in document space
4. Transform back via forward pixel transform → pixel space
5. Sample from the input texture

This approach means you never need special-case code for thumbnails, proxy resolution,
or non-square pixel aspect ratios.

---

## Tiled Rendering

The host may request rendering of only portions of the output (tiles) for efficiency.

### Setting Output Bounds

Tell the host what your output area will be given the input:

```swift
func destinationImageRect(_ destinationImageRect: UnsafeMutablePointer<FxRect>,
                          sourceImages: [FxImageTile],
                          destinationImage: FxImageTile,
                          pluginState: NSData?,
                          at renderTime: CMTime) throws {
    // For most filters: output = input
    destinationImageRect.pointee = sourceImages[0].imagePixelBounds
}
```

### Requesting Input Tiles

For each output tile the host requests, specify which input region you need:

```swift
func sourceTileRect(_ sourceTileRect: UnsafeMutablePointer<FxRect>,
                    sourceImageIndex: UInt,
                    sourceImages: [FxImageTile],
                    destinationTileRect: FxRect,
                    destinationImage: FxImageTile,
                    pluginState: NSData?,
                    at renderTime: CMTime) throws {
    // For simple filters: need same region as output
    sourceTileRect.pointee = destinationTileRect
    
    // For blur: expand by blur radius
    // sourceTileRect.pointee = expandRect(destinationTileRect, by: blurRadius)
}
```

---

## Custom Parameter Views

Custom views let you draw your own UI in the inspector. They run in the XPC view service.

### Implementation

1. Conform to `FxCustomParameterViewHost_v2`
2. Implement `createView(forParameterID:)` returning an `NSView` subclass
3. The view draws itself and handles mouse/key/tablet events
4. On user interaction, call parameter setting APIs

### Critical XPC Considerations

Custom views run in the XPC view service, which imposes constraints:

- **Draw directly** — avoid complex subview hierarchies for XPC compatibility
- **No storyboards** — use programmatic layout or XIB files in Resources
- Before accessing parameters, call `startAction(_:)` on `FxCustomParameterActionAPI_v4`
- After finishing, call `endAction(_:)`

```swift
func createView(forParameterID paramID: UInt32) -> NSView? {
    let view = MyCustomView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
    view.apiManager = apiManager
    view.parameterID = paramID
    return view
}

// In the custom view:
func handleUserAction() {
    guard let actionAPI = apiManager?.api(for: FxCustomParameterActionAPI_v4.self)
            as? FxCustomParameterActionAPI_v4 else { return }
    
    actionAPI.startAction(self)
    // Set parameter values...
    actionAPI.endAction(self)
}
```

### Keyframing Custom Parameters

Implement `FxCustomParameterInterpolation_v2` to support keyframe animation on
custom parameter types. The host calls your interpolation methods to compute
intermediate values between keyframes.

---

## Onscreen Controls

Onscreen controls (OSCs) draw directly on the host's canvas, letting users manipulate
plugin parameters visually (e.g., dragging a circle to resize a blur region).

### Implementation

Create an `NSObject` subclass implementing `FxOnScreenControl_v4`:

```swift
class MyOSC: NSObject, FxOnScreenControl_v4 {
    var apiManager: PROAPIAccessing?
    
    init(apiManager: PROAPIAccessing) {
        self.apiManager = apiManager
        super.init()
    }
    
    func drawingCoordinates() -> FxDrawingCoordinates {
        return .kFxDrawingCoordinates_CANVAS  // Best UX
    }
}
```

### Drawing Spaces

| Space | Description | Origin |
|-------|-------------|--------|
| Canvas | Host app's viewer area, varies with zoom/window | (0,0) at bottom-left |
| Object | Normalized 0–1 space of the applied object | (0,0) = bottom-left, (1,1) = top-right |
| Document | Centered at scene origin, project pixel units | (-w/2,-h/2) to (w/2,h/2) |

> Use **canvas space** for the best user experience. Draw control parts in object space
> for alignment, but draw handles in canvas space so they stay a consistent size.

### Drawing Controls

```swift
func draw(with
    api: FxOnScreenControlAPI,
    pluginState: NSData?,
    image: FxImageTile?,
    at renderTime: CMTime) {
    // Convert between spaces:
    var canvasX: Double = 0, canvasY: Double = 0
    api.convertPoint(
        fromSpace: .kFxDrawingCoordinates_OBJECT,
        fromX: 0.5, fromY: 0.5,
        toSpace: .kFxDrawingCoordinates_CANVAS,
        toX: &canvasX, toY: &canvasY
    )
    // Draw at (canvasX, canvasY)...
}
```

### Event Handling

```swift
// Hit testing - return non-zero part ID if mouse is on a control
func hitTest(atPositionX x: Double, positionY y: Double, ...) -> UInt32

// Mouse events
func mouseDown(atPositionX:positionY:activePart:modifiers:forceUpdate:at:)
func mouseDragged(atPositionX:positionY:activePart:modifiers:forceUpdate:at:)
func mouseUp(atPositionX:positionY:activePart:modifiers:forceUpdate:at:)

// Keyboard events
func keyDown(atPositionX:positionY:keyPressed:modifiers:forceUpdate:didHandle:at:)
func keyUp(atPositionX:positionY:keyPressed:modifiers:forceUpdate:didHandle:at:)

// Optional mouse tracking
func mouseMoved(atPositionX:positionY:activePart:modifiers:forceUpdate:at:)
func mouseEntered(atPositionX:positionY:modifiers:forceUpdate:at:)
func mouseExited(atPositionX:positionY:modifiers:forceUpdate:at:)
```

### Registering OSCs

Add a separate entry in `ProPlugPlugInList` for the OSC class with its own UUID.
Link it to the effect plugin via the group UUID.

---

## Media Analysis

Use `FxAnalysisAPI` for frame-by-frame analysis before rendering — useful for
stabilization, object tracking, and other multi-pass effects.

### Implementing the Analyzer

```swift
class MyPlugin: NSObject, FxTileableEffect, FxAnalyzer {
    func analyzeFrame(_ image: FxImageTile,
                      at time: CMTime,
                      pluginState: NSData?) throws {
        // Analyze this frame (e.g., detect motion, track objects)
        // Store analysis results for use during rendering
    }
}
```

### Requesting Analysis

```swift
guard let analysisAPI = apiManager?.api(for: FxAnalysisAPI_v2.self)
        as? FxAnalysisAPI_v2 else { return }

// Forward analysis (start to end)
analysisAPI.startForwardAnalysis(.kFxAnalysisLocation_CPU)

// Backward analysis (end to start)
analysisAPI.startBackwardAnalysis(.kFxAnalysisLocation_CPU)

// Check state
let state = analysisAPI.analysisStateForEffect()
// States: requested, started, completed, interrupted
```

Analysis runs in the background with a progress UI. The host calls `analyzeFrame`
for each frame, which your plugin uses to build up analysis data (motion vectors,
tracking points, etc.) before rendering begins.

### Analysis from Image Wells

`FxAnalysisAPI_v2` adds support for analyzing frames from image well parameters:

```swift
analysisAPI.startForwardAnalysis(.kFxAnalysisLocation_GPU, ofParameter: imageParamID)
```

---

## Time and Scheduling

### Time Representation

FxPlug uses `CMTime` for all time values:

```swift
let time = CMTime(value: 1001, timescale: 30000)  // ~33.37ms at 29.97fps
```

### Frame Duration

Query via `FxTimingAPI_v4`:

```swift
guard let timingAPI = apiManager?.api(for: FxTimingAPI_v4.self)
        as? FxTimingAPI_v4 else { return }

let frameDuration = timingAPI.frameDuration()
// frameDuration.value / frameDuration.timescale = seconds per frame
```

### Scheduling Media at Arbitrary Times

Use the scheduling APIs to retrieve frames at times other than the current render time.
This is essential for time-based effects (echo, trails, time displacement):

```swift
// Request a frame at a different time during pluginState gathering
// Pack the needed time information into your plugin state
```

---

## Undo and Host Commands

### Undo API

```swift
guard let undoAPI = apiManager?.api(for: FxUndoAPI.self)
        as? FxUndoAPI else { return }

undoAPI.startUndoGroup("My Change")
// Make changes...
undoAPI.endUndoGroup()
```

> Not all host apps implement this protocol. Check for nil.

### Host Commands

```swift
guard let commandAPI = apiManager?.api(for: FxCommandAPI_v2.self)
        as? FxCommandAPI_v2 else { return }

// Perform a host command
commandAPI.perform(.play)

// Move playhead to specific time
commandAPI.movePlayhead(to: CMTime(value: 100, timescale: 24))
```

### Command Handler

Implement `FxCommandHandler` to receive notifications about the host's key bindings
for common commands, allowing your plugin to respond to keyboard shortcuts.

---

## Versioning and Migration

### Parameter Versioning

As you update your plugin, parameters may change. Use `FxVersioningAPI` to maintain
backward compatibility:

```swift
func addParameters() throws {
    guard let versionAPI = apiManager?.api(for: FxVersioningAPI.self)
            as? FxVersioningAPI else { return }
    
    let createdVersion = versionAPI.versionAtCreation()
    
    // Version 1: original brightness slider
    api.addFloatSlider(withName: "Brightness", parameterID: 1, ...)
    
    if createdVersion >= 2 {
        // Version 2: added contrast
        api.addFloatSlider(withName: "Contrast", parameterID: 2, ...)
    }
}
```

### Obsoleting Old Plugins

When a plugin is fundamentally redesigned, you can mark old versions as obsolete.
Projects using the old version still work, but new instances use the new version.

### Migrating from FxPlug 3 to FxPlug 4

Key changes:
- `FxTexture`/`FxBitmap` → `FxImageTile` (IOSurface-backed)
- In-process → Out-of-process XPC
- API access at render time → Plugin state pattern
- `needsToBeNonReentrant` property → No longer works; use thread-safe patterns
- FxPlug 4 only supports latest API versions

---

## Preparing Plugins for Final Cut Pro

Plugins work directly in Motion. For Final Cut Pro, you must wrap them in a
**Motion effect template**:

1. Open Motion and create a new project matching your plugin type (Filter, Generator, etc.)
2. Apply your plugin to content in the Motion project
3. Configure default parameter values and any Motion behaviors
4. Save as a template: File > Save as Template
5. The template appears in Final Cut Pro's effects browser

This packaging step lets FCP users apply your effect without needing Motion open.
The template defines how the effect appears in FCP's browser, including its category,
icon, and default settings.

---

## Testing

### Testing Matrix

Test your plugin across these conditions:

| Condition | Why |
|-----------|-----|
| Proxy resolution | Pixel transforms must work at lower resolutions |
| Non-square pixel aspect ratios | 4:3 SD footage, anamorphic |
| Field handling | Interlaced footage (1080i, 480i) |
| Thumbnail generation | Small previews in browser |
| Multiple GPUs | Pipeline state per device |
| Large images | Memory and tiling behavior |
| Missing media | Graceful degradation |

### Debugging Tools

- **Console.app** — Filter by your plugin's process name for log output
- **Activity Monitor** — Monitor your XPC service's memory/CPU usage
- **Xcode Debugger** — Attach to the XPC service process
- **FCPBridge debug tools** — Use `debug_enable_preset("render_debug")` to isolate
  rendering issues in the FCP pipeline

### Resilience Testing

- Kill your XPC service while it's rendering — the host should recover gracefully
- Test with very large and very small parameter values
- Rapidly change parameters during playback
- Apply to clips of varying frame rates and codecs

---

## Notarization and Distribution

### Code Signing

1. Obtain a **Developer ID Application** certificate from Apple
2. Enable **Hardened Runtime** in Xcode's Signing & Capabilities
3. Sign both the wrapper app and XPC service

### Notarization

1. Archive your plugin in Xcode (Product > Archive)
2. Distribute with Developer ID (not App Store)
3. Xcode submits to Apple's notarization service automatically
4. Apple scans for malware and returns a ticket
5. Staple the ticket: `xcrun stapler staple MyPlugin.app`

Alternatively, from the command line:

```bash
# Create a ZIP for notarization
ditto -c -k --keepParent "MyPlugin.app" "MyPlugin.zip"

# Submit
xcrun notarytool submit "MyPlugin.zip" \
    --keychain-profile "MyProfile" \
    --wait

# Staple
xcrun stapler staple "MyPlugin.app"
```

### Distribution

Distribute the signed, notarized `.app` bundle. Users install by:
1. Moving the app to `/Applications` (or any location)
2. Launching it once to register with PlugInKit
3. The plugin appears in Motion/FCP immediately

---

## Reference: FCPBridge LUT Plugin

The `LUTPlugin/` directory contains a complete FxPlug 4 plugin implementing 3D LUT
color grading. Use it as a reference for real-world patterns.

### Architecture

```
LUTPlugin/
├── FCPBridgeLUT/                    # Wrapper app (minimal)
│   ├── AppDelegate.swift
│   └── Info.plist
├── FCPBridgeLUTXPC/                 # XPC Service (all the work)
│   ├── LUTPlugIn.swift              # Core plugin: params, state, rendering
│   ├── CubeParser.swift             # .cube file parser (text + binary)
│   ├── LUTFileData.swift            # NSSecureCoding param container
│   ├── LUTCustomView.swift          # Inspector custom view (direct drawing)
│   ├── MetalDeviceCache.swift       # Per-device/format pipeline cache
│   ├── LUTShaders.metal             # 3D LUT lookup (trilinear/tetrahedral)
│   ├── main.swift                   # Entry point
│   ├── Entitlements.entitlements    # XPC sandbox
│   └── Info.plist                   # Plugin config
└── Modules/                         # Framework bridging
    ├── FxPlug/module.modulemap
    └── PluginManager/module.modulemap
```

### Key Patterns Demonstrated

| Pattern | Implementation |
|---------|---------------|
| Plugin state serialization | `LUTPlugIn.swift` — struct packed to NSData |
| Custom parameter with NSSecureCoding | `LUTFileData.swift` — survives project save/load |
| Direct-draw custom view for XPC | `LUTCustomView.swift` — no subviews, NSOpenPanel |
| Per-device Metal pipeline cache | `MetalDeviceCache.swift` — registry ID keyed |
| 3D texture from file data | `CubeParser.swift` — SIMD Float32→Float16 via Accelerate |
| Dual interpolation modes | `LUTShaders.metal` — trilinear + tetrahedral |
| Configurable logging | `LUTPlugIn.swift` — FCPBRIDGE_LUT_LOG env var |

### Logging

Set `FCPBRIDGE_LUT_LOG` environment variable:
- `oslog` — OSLog output (view in Console.app)
- `file` — Write to file
- `both` — Both outputs

---

## API Quick Reference

### Core Protocols (Plugin-Implemented)

| Protocol | Purpose |
|----------|---------|
| `FxTileableEffect` | Main plugin protocol — params, state, rendering |
| `FxOnScreenControl_v4` | Onscreen canvas controls |
| `FxAnalyzer` | Frame-by-frame analysis |
| `FxCustomParameterViewHost_v2` | Custom inspector views |
| `FxCustomParameterInterpolation_v2` | Custom parameter keyframing |
| `FxCommandHandler` | Host key binding notifications |

### Host APIs (Host-Implemented, Plugin-Consumed)

| API | Purpose |
|-----|---------|
| `FxParameterCreationAPI_v5` | Add parameters to inspector |
| `FxParameterRetrievalAPI_v6` / `v7` | Read parameter values (not at render time!) |
| `FxParameterSettingAPI_v5` / `v6` | Set parameter values and flags |
| `FxDynamicParameterAPI_v3` | Create parameters at runtime |
| `FxCustomParameterActionAPI_v4` | Start/end actions for custom views |
| `FxOnScreenControlAPI` / `v2` / `v3` / `v4` | Drawing and coordinate conversion |
| `FxTimingAPI_v4` | Frame duration and timing queries |
| `FxKeyframeAPI_v3` | Keyframe manipulation |
| `FxAnalysisAPI` / `v2` | Analysis state and requests |
| `FxColorGamutAPI_v2` | Color primaries and conversion matrices |
| `FxUndoAPI` | Undo group management |
| `FxCommandAPI` / `v2` | Host commands and playhead control |
| `Fx3DAPI_v5` | 3D scene graph access |
| `FxLightingAPI_v3` | 3D lighting setup |
| `FxPathAPI_v3` | Path, shape, and mask retrieval |
| `FxRemoteWindowAPI` / `v2` | Request host-managed windows |

### XPC Service Protocols

| Protocol | Purpose |
|----------|---------|
| `FxPrincipal` | Singleton that starts the XPC service |
| `FxPrincipalAPI` | Host retrieves XPC proxy object |
| `FxPrincipalDelegate` | Info about the host that launched the XPC |
| `PROXPCProtocol` | XPC communication protocol |

### Key Image Types

| Type | Description |
|------|-------------|
| `FxImageTile` | IOSurface-backed image with bounds, transforms, field info |
| `FxMatrix44` | 4x4 transformation matrix |
| `FxPixelTransform` | Pixel-space transformation info |

### Error Codes

| Error | Meaning |
|-------|---------|
| `kFxError_Success` | Operation completed |
| `kFxError_OutOfMemory` | Memory allocation failed |
| `kFxError_LostConnection` | XPC connection invalid |
| `kFxError_InvalidParameter` | Bad parameter ID or value |
| `kFxError_NotSupported` | Host doesn't support this API |

---

*Based on Apple's Professional Video Applications documentation and the FxPlug 4 SDK.*
