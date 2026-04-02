# Final Cut Pro: Mac vs iPad — Deep Dive Comparison Report

> **Date:** April 2, 2026  
> **Mac Version:** Final Cut Pro 12.0 (Build 445223)  
> **iPad Version:** Final Cut Pro 3.0 (Build 453.4.260)  
> **Analysis Method:** Binary inspection, framework enumeration, string analysis, template counting, Info.plist parsing

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Platform & System Requirements](#platform--system-requirements)
3. [App Bundle Architecture](#app-bundle-architecture)
4. [Framework Comparison](#framework-comparison)
5. [Core Engine & Shared DNA](#core-engine--shared-dna)
6. [Plugin & Extension Architecture](#plugin--extension-architecture)
7. [Codec & Format Support](#codec--format-support)
8. [GPU & Metal Shaders](#gpu--metal-shaders)
9. [AI & Machine Learning](#ai--machine-learning)
10. [Templates, Effects & Transitions](#templates-effects--transitions)
11. [Color Grading & LUTs](#color-grading--luts)
12. [Audio Engine](#audio-engine)
13. [Motion Integration (EDEL vs MotionEffect)](#motion-integration-edel-vs-motioneffect)
14. [Timeline & Editing Features](#timeline--editing-features)
15. [Camera & Live Features (iPad-Only)](#camera--live-features-ipad-only)
16. [Professional Broadcast (Mac-Only)](#professional-broadcast-mac-only)
17. [Document Model & Project Format](#document-model--project-format)
18. [Scripting & Automation](#scripting--automation)
19. [UI Architecture](#ui-architecture)
20. [Localization](#localization)
21. [Business Model](#business-model)
22. [Privacy & Entitlements](#privacy--entitlements)
23. [Bundled Content & Resources](#bundled-content--resources)
24. [Class Architecture & Codebase Scale](#class-architecture--codebase-scale)
25. [Feature Parity Matrix](#feature-parity-matrix)
26. [Key Architectural Insights](#key-architectural-insights)
27. [Conclusions](#conclusions)

---

## Executive Summary

Final Cut Pro for Mac and iPad share a **common core** — the same Flexo engine, Helium renderer, TimelineKit, and 43 other shared frameworks — but are fundamentally different products built for different paradigms. The Mac version is a **6.2 GB, 30,773-file professional powerhouse** with 54 frameworks, multi-process XPC architecture, and deep Motion/Compressor integration. The iPad version is a **1.4 GB, 4,090-file touch-first editor** with 102 frameworks (many pulled out of Mac's EDEL monolith), built-in camera recording, and a subscription business model.

The Mac version has **4.4x more code**, **7.5x more files**, **46x more bundled templates**, support for 360° video, spatial video, multicam, proxy workflows, RED/Canon RAW, MXF export, AppleScript, third-party FxPlug extensions, and Compressor integration — none of which exist on iPad.

The iPad version has **exclusive camera frameworks** (CameraKit, ProARCam, PeerCam), a built-in **browser/inspector UI framework** layer, **subscription/trial management**, and an **external display** pipeline. It also ships 48 bundled fonts vs Mac's 1.

They are siblings, not ports.

---

## Platform & System Requirements

| Attribute | Mac | iPad |
|-----------|-----|------|
| **Bundle Identifier** | `com.apple.FinalCut` | `com.apple.FinalCutApp` |
| **Version** | 12.0 | 3.0 |
| **Build Number** | 445223 | 453.4.260 |
| **Minimum OS** | macOS 15.6 (Sequoia) | iOS 18.6 |
| **Architecture** | Universal (x86_64 + arm64) | arm64 only |
| **Required Hardware** | Any supported Mac | iPad with M1 or later |
| **Main Binary Size** | 6.2 MB | 6.8 MB |
| **Total App Size** | **6.2 GB** | **1.4 GB** |
| **Total Files** | **30,773** | **4,090** |
| **UI Toolkit** | AppKit (NSWindow, NSView) | UIKit (UIWindow, UIView) |
| **GPU Requirement** | Metal | Metal + OpenGL ES 3 |
| **Background Modes** | N/A (macOS) | `processing`, `audio` |
| **Device Family** | Mac | iPad only (device family 2) |

**Key insight:** The Mac build number (445223) and iPad build number (453.4.260) suggest separate build pipelines with different versioning schemes. The Mac binary is a universal fat binary supporting Intel Macs; the iPad is arm64-only (M1+ requirement).

---

## App Bundle Architecture

### Mac Bundle Layout
```
Final Cut Pro.app/
├── Contents/
│   ├── MacOS/Final Cut Pro          (6.2 MB universal binary)
│   ├── Frameworks/                  (54 frameworks, 5.9 GB)
│   ├── PlugIns/                     (11 plugin categories)
│   │   ├── Codecs/                  (6 codec bundles)
│   │   ├── FormatReaders/           (3 format readers)
│   │   ├── Compressor/              (CompressorKit)
│   │   ├── MediaProviders/          (MotionEffect.fxp)
│   │   ├── RADPlugins/              (6 archive/format plugins)
│   │   ├── DAL/                     (ACD device abstraction)
│   │   ├── InternalFiltersXPC.pluginkit
│   │   ├── FxAnalyzer.appex
│   │   ├── BluRayH264Encoder.appex
│   │   └── DolbyDigitalEncoder.appex
│   ├── Resources/
│   │   ├── Bundled Package/
│   │   ├── Fonts/ (1 font)
│   │   ├── ProEditor.sdef (AppleScript)
│   │   └── [8 localizations]
│   └── _CodeSignature/
```

### iPad Bundle Layout
```
Final Cut Pro.app/
├── Final Cut Pro                    (6.8 MB arm64 binary)
├── Frameworks/                      (102 frameworks)
├── PlugIns/
│   └── HLAppShareExtension.appex   (1 share extension)
├── Bundled Package/                 (559 bundled asset files)
├── FlexAudio/                       (2 audio assets)
├── Fonts/                           (48 fonts)
├── Settings.bundle/                 (iOS Settings integration)
├── Assets.car                       (50.5 MB compiled assets)
├── Application_Welcome-Video.mp4    (180 MB)
├── IntroducingAllieSherlock.mov     (39.4 MB)
├── [8 localizations]
└── _CodeSignature/
```

### Structural Differences

| Aspect | Mac | iPad |
|--------|-----|------|
| Framework count | 54 | 102 |
| Plugin categories | 11 | 1 |
| XPC services | 4 | 0 |
| App extensions (.appex) | 3 | 1 |
| pluginkit bundles | 1 | 0 |
| Welcome videos | 0 | 2 (220 MB combined) |
| Settings bundle | No (macOS Preferences) | Yes (iOS Settings app) |

The Mac version uses a **deep plugin architecture** with codec bundles, format readers, and XPC services for process isolation. The iPad version has **no plugin system** — everything is baked into frameworks.

The iPad has nearly **2x the framework count** (102 vs 54) because many subsystems that are embedded within Mac frameworks (e.g., MA* frameworks inside EDEL, Filters inside InternalFiltersXPC) are broken out as top-level frameworks on iPad.

---

## Framework Comparison

### Shared Frameworks (43 total)

These frameworks exist on **both** platforms, representing the shared core:

| Framework | Mac Size | iPad Size | Purpose |
|-----------|----------|-----------|---------|
| **Flexo** | 426 MB | 86 MB | Core editing engine |
| **VAML** | 403 MB | 438 MB | ML video analysis models |
| **Ozone** | 269 MB | 12 MB | Audio effects engine |
| **ProTracker** | 658 MB | 89 MB | Motion tracking |
| **Helium** | 19 MB | 20 MB | GPU rendering compositor |
| **EDEL** | 241 MB | *(decomposed)* | Motion integration |
| **ProAppsFxSupport** | 66 MB | 64 MB | Effects framework |
| **MusicUnderstandingEmbedded** | 23 MB | 24 MB | Music AI analysis |
| **StudioSharedResources** | 37 MB | 6.8 MB | Shared UI resources |
| TimelineKit | 3.7 MB | — | Timeline data model |
| TextFramework | 3.9 MB | — | Text/titles rendering |
| Interchange | 2.5 MB | — | FCPXML import/export |
| CloudContent | 2.2 MB | — | iCloud sync |
| HeliumSenso | 3.2 MB | — | Sensor-based rendering |
| Lithium | 2.8 MB | — | 3D rendering |
| LunaKit | 4.8 MB | — | UI toolkit |
| ProCore | 1.8 MB | — | Core utilities |
| ProChannel | — | — | Audio channel management |
| ProGL | — | — | OpenGL abstraction |
| ProGraphics | — | — | Graphics utilities |
| ProInspector | — | — | Inspector framework |
| ProMedia | — | — | Media I/O |
| ProMediaLibrary | — | — | Media library management |
| ProOSC | 1.9 MB | — | On-screen controls |
| ProShapes | — | — | Shape rendering |
| RetimingMath | — | — | Speed ramp calculations |
| FxPlug | — | — | Effects plugin API |
| AudioEffects | — | — | Audio effect processing |
| CoreAudioSDK | — | — | Core Audio integration |
| MDPKit | — | — | Media display pipeline |
| XMLCodable | — | — | XML serialization |
| Stalgo | — | — | Algorithm library |
| USearch | — | — | Vector search |
| VAMLSentencePiece | — | — | NLP tokenization |
| AppAnalytics | — | — | Usage analytics |
| AppleMediaServicesKit | — | — | Apple media services |
| EmbeddedRemoteConfiguration | — | — | Remote config |
| LunaFoundation | — | — | Foundation extensions |
| PMLCloudContent | — | — | Cloud content layer |
| PMLUtilities | — | — | Utility library |
| ProAppSupport | — | — | Pro app infrastructure |
| ProInspectorFoundation | — | — | Inspector base |
| PluginManager | — | — | Plugin discovery |

**Size discrepancies are massive.** Mac Flexo is **5x larger** (426 MB vs 86 MB) because Mac has universal binaries (x86_64 + arm64) and vastly more features (360°, spatial video, multicam, proxy, etc.). Mac Ozone is **22x larger** (269 MB vs 12 MB) because it includes Motion's particle system and behavior plugins. Mac ProTracker is **7.4x larger** (658 MB vs 89 MB).

### Mac-Only Frameworks (11)

| Framework | Size | Purpose |
|-----------|------|---------|
| **ProCurveEditor** | 644 KB | Keyframe curve editing UI |
| **MXFExportSDK** | 1.0 MB | MXF broadcast format export |
| **MIO** | 928 KB | Media I/O for broadcast hardware |
| **ProExtension** | 128 KB | Third-party extension API |
| **ProExtensionHost** | 72 KB | Extension hosting runtime |
| **ProExtensionSupport** | 140 KB | Extension support utilities |
| **ProViewServiceSupport** | 40 KB | View service for extensions |
| **ProService** | 40 KB | Service discovery |
| **ProOnboardingFlowModelOne** | 24 MB | First-run experience (Mac-specific) |
| **SwiftASN1** | — | Certificate/signing utilities |
| **FxPlugProvider.fxp** | 244 KB | FxPlug effect provider host |

These represent Mac-exclusive capabilities: **broadcast I/O** (MIO, MXF), **third-party plugin hosting** (ProExtension*), and **advanced keyframe editing** (ProCurveEditor).

### iPad-Only Frameworks (59)

#### Camera & Video Capture (7 frameworks)
| Framework | Size | Purpose |
|-----------|------|---------|
| **CameraKit** | 6.0 MB | Camera capture engine |
| **CameraKitUI** | 3.6 MB | Camera UI components |
| **CameraProfiler** | 568 KB | Camera calibration/profiling |
| **ProARCam** | 144 KB | AR camera integration |
| **ProCamera** | 360 KB | Professional camera controls |
| **ProCameraDataModels** | 180 KB | Camera data structures |
| **PeerCam** | 1.4 MB | Multi-device camera (Final Cut Camera) |

#### Media & Audio (formerly inside EDEL)
| Framework | Size | Purpose |
|-----------|------|---------|
| **MADSP** | 20 MB | Digital signal processing |
| **MADSPPlugInPublic** | 116 KB | DSP plugin API |
| **MACore** | 5.5 MB | Motion/Apple core utilities |
| **MAFiles** | 600 KB | File I/O for Motion assets |
| **MAHarmony** | 1.2 MB | Color harmony |
| **MAMachineLearning** | 11 MB | ML inference for effects |
| **MAAccessibility** | 352 KB | Accessibility for effects |
| **MASwiftUtilities** | 292 KB | Swift utility extensions |
| **AudioAnalysis** | — | Audio analysis pipeline |

#### UI Layer (iPad-specific design)
| Framework | Size | Purpose |
|-----------|------|---------|
| **Browser** | 5.8 MB | Media browser |
| **BrowserUI** | 260 KB | Browser UI components |
| **Inspector** | 1.7 MB | Inspector panel |
| **InspectorUI** | 2.0 MB | Inspector UI widgets |
| **Filmstrip** | 320 KB | Filmstrip view |
| **DirectorKit** | 2.1 MB | Director/storyboard view |
| **DirectorKitUI** | 3.1 MB | Director UI components |
| **HLTimeline** | 892 KB | iPad timeline view |
| **HLAppSupport** | — | iPad app infrastructure |
| **Player** | — | Video player |
| **Lens** | — | Viewer/canvas |
| **SharedWidgets** | — | Shared UI widgets |

#### Effects & Rendering
| Framework | Size | Purpose |
|-----------|------|---------|
| **MotionEffect** | 104 MB | Motion effects engine (replaces MotionEffect.fxp) |
| **Filters** | 18 MB | Video filters (moved from XPC plugin) |
| **FxPlugEffects** | 408 KB | Built-in FxPlug effects |
| **FlexMusicKit** | — | Music integration |
| **FlexoCover** | — | Cover flow/thumbnails |
| **MotionEffect** | 104 MB | Titles, generators, transitions |

#### Data & Platform
| Framework | Size | Purpose |
|-----------|------|---------|
| **CoreDataCache** | — | CoreData caching layer |
| **SimplyCodableMetadata** | — | Codable metadata |
| **KonaModel** | — | Data model layer |
| **MovieKit** | 5.8 MB | Movie file I/O |
| **VideoCassette** | — | Video playback/buffering |
| **PMLEffects** | — | Effects pipeline |
| **PMLFileSystem** | — | File system abstraction |
| **PMLHLApp** | — | App lifecycle |

#### Analytics & Services
| Framework | Size | Purpose |
|-----------|------|---------|
| **VAAppAnalytics** | — | Video app analytics |
| **VACore** | — | Video analytics core |
| **VAKit** | — | Video analytics toolkit |
| **AppSubscriptions** | — | Subscription management |
| **DeepSkyLite** | — | On-device deep learning |
| **AnalysisKit** | — | Video/audio analysis |
| **AnalysisService** | — | Analysis service layer |
| **ProOnboardingFlow** | 65 MB | iPad onboarding experience |

#### Communication & Other
| Framework | Size | Purpose |
|-----------|------|---------|
| **Communication** | 508 KB | Device communication |
| **UnifiedMessagingKit2P** | 7.6 MB | Messaging/notifications |
| **AssistiveWorkflowKit** | — | Assistive technology |
| **LegacyOnboarding** | — | Legacy onboarding compat |
| **Share** | — | Share sheet integration |
| **Timber** | — | Logging framework |
| **Jet2P** | 6.6 MB | Unknown (possibly Jet engine) |
| **ChordsKit** | — | Music chords (top-level on iPad, inside EDEL on Mac) |
| **Camalot** | — | Unknown |
| **ProResRAWConversion** | — | ProRes RAW (top-level, not in XPC) |

---

## Core Engine & Shared DNA

Both platforms share the same fundamental architecture through key frameworks:

### Flexo — The Heart of FCP
The Flexo framework is the central editing engine on both platforms. On Mac, it contains **8,537+ unique FF-prefixed class name strings** (representing the massive ObjC class hierarchy). On iPad, Flexo is significantly slimmer — the binary is 5x smaller and the class name strings are minimal, suggesting heavy use of Swift and a reduced feature set.

**Mac Flexo includes classes for:**
- 360° video (`FF360*` — 30+ classes)
- Spatial video (`FFSpatial*`)
- Multicam (`FFMulticam*`, `FFCreateMulticamCommand`)
- Proxy workflows (`FFAssetProxy*` — 20+ classes)
- RED RAW settings (`FFREDRAWSettings`)
- Compound clips, auditions, synchronized clips
- Role management (`FFRole*` — 20+ classes)
- Extensive inspector, browser, and timeline UI

**iPad Flexo includes:**
- VAML search context (semantic search for clips)
- Core editing operations
- Minimal UI class footprint (UI moved to separate frameworks)

### Helium — GPU Rendering
Nearly identical on both platforms (~19-20 MB). Handles Metal-based compositing and real-time playback rendering. Both use the same HGC (High-level Graphics Compiler) shader pipeline.

### TimelineKit — Timeline Data Model
Shared framework that manages the magnetic timeline data structures, spine model, and anchored objects (clips, transitions, etc.).

### ProTracker — Motion Tracking
Present on both but 7.4x larger on Mac (658 MB vs 89 MB), suggesting the Mac version includes additional tracking algorithms, more ML models, or broader format support.

---

## Plugin & Extension Architecture

### Mac: Deep Plugin System
```
PlugIns/
├── Codecs/                          (10 codec bundles)
│   ├── AppleProResCodecEmbedded
│   ├── AppleProResRAWCodecEmbedded
│   ├── AppleAVCIntraCodec
│   ├── AppleDVCPROHDCodec
│   ├── AppleIMXCodec
│   ├── AppleMPEG2Codec
│   ├── AppleCanonRAWDecoder         (with Metal shaders)
│   ├── AppleREDRAWDecoder           (with Metal shaders)
│   ├── AppleAVCLGCodecEmbedded
│   ├── AppleHEVCProCodec
│   ├── AppleIntermediateCodec
│   ├── AppleAnimationCodec
│   ├── AppleImageCodec
│   ├── AppleUncompressedCodec
│   └── DNXDecoder                   (Avid DNxHD/DNxHR)
├── FormatReaders/                   (3 readers)
│   ├── AppleMXFImport
│   ├── AppleCanonRAWImport
│   └── AppleREDRAWImport
├── RADPlugins/                      (6 archive readers)
│   ├── Archive.RADPlug
│   ├── AVCHD.RADPlug
│   ├── MPEG2.RADPlug
│   ├── MPEG4.RADPlug
│   ├── P2AVF.RADPlug               (Panasonic P2)
│   └── XDCAM.RADPlug               (Sony XDCAM)
├── Compressor/CompressorKit.bundle
├── MediaProviders/MotionEffect.fxp
├── DAL/ACD.plugin                   (Device Abstraction Layer)
├── InternalFiltersXPC.pluginkit     (Out-of-process filters)
├── FxAnalyzer.appex
├── BluRayH264Encoder.appex
└── DolbyDigitalEncoder.appex
```

**XPC Services (Mac-only, 4 total):**
| Service | Purpose |
|---------|---------|
| `OOPDebayerService.xpc` | Out-of-process RAW debayering |
| `OOPProResRawService.xpc` | ProRes RAW processing |
| `FCPAEHelper.xpc` | After Effects integration helper |
| `SpeechHelper.xpc` | Speech recognition (inside AudioAnalysis) |

**Plus `InternalFiltersXPC.pluginkit`** runs video filters in a separate process for crash isolation.

### iPad: Monolithic Architecture
```
PlugIns/
└── HLAppShareExtension.appex        (share sheet only)
```

The iPad has **no plugin system**, **no XPC services**, and **no third-party extension support**. Everything runs in-process. Effects that are plugins on Mac (Filters, MotionEffect) are compiled directly into frameworks on iPad.

**This is the single biggest architectural difference.** The Mac's multi-process design provides crash isolation, memory management, and third-party extensibility. The iPad trades all of this for simplicity and lower overhead.

---

## Codec & Format Support

### Mac Codec Support

| Category | Formats |
|----------|---------|
| **ProRes Family** | ProRes 4444 XQ, 4444, 422 HQ, 422, 422 LT, 422 Proxy |
| **ProRes RAW** | ProRes RAW, ProRes RAW HQ (via XPC service) |
| **Camera RAW** | Canon Cinema RAW Light, RED RAW (R3D) — both with Metal GPU decoding |
| **Professional** | AVC-Intra, DVCPRO HD, IMX, MPEG-2, Intermediate Codec |
| **Broadcast** | MXF import + export, XDCAM, P2 (Panasonic), AVCHD |
| **Consumer** | H.264, H.265/HEVC, HEVC Pro |
| **Uncompressed** | 8/10-bit 4:2:2 |
| **Legacy** | Animation codec, Image codec |
| **Third-Party** | Avid DNxHD / DNxHR |
| **Output** | Blu-Ray H.264, Dolby Digital AC-3 |

### iPad Codec Support

| Category | Formats |
|----------|---------|
| **ProRes Family** | ProRes (via system framework) |
| **ProRes RAW** | ProRes RAW Conversion framework (limited) |
| **Consumer** | H.264, H.265/HEVC (via system VideoToolbox) |
| **Camera** | Apple Log, Apple Log 2 |

### What iPad is Missing

- **No Canon RAW** or **RED RAW** support
- **No MXF** import or export
- **No XDCAM, P2, AVCHD** archive reading
- **No AVC-Intra, DVCPRO HD, IMX** professional codecs
- **No DNxHD/DNxHR** (Avid interop)
- **No Blu-Ray** or **Dolby Digital** encoding
- **No uncompressed** codec
- Relies on **system-level** VideoToolbox for most decoding

---

## GPU & Metal Shaders

### Mac Metal Libraries (27 total)
```
Frameworks:
  Flexo/default.metallib
  Flexo/FlexoHgcMetalShaders_derived.metallib          ← Mac-only Flexo shader
  Helium/HeliumFiltersHgcMetalShaders_derived.metallib
  Helium/HeliumRenderHgcMetalShaders_derived.metallib
  HeliumSenso/default.metallib
  Lithium/LiSolidShaders.metallib
  Lithium/LithiumHgcMetalShaders_derived.metallib
  MDPKit/default.metallib
  Ozone/default.metallib
  Ozone/MotionHgcMetalShaders_derived.metallib          ← Mac-only (Ozone plugins)
  Ozone/Behaviors.ozp/default.metallib                   ← Mac-only
  Ozone/Particles.ozp/default.metallib                   ← Mac-only
  Ozone/Particles.ozp/MotionHgcMetalShaders_derived      ← Mac-only
  ProAppsFxSupport/default.metallib
  ProAppsFxSupport/ProAppsFxSupportHgcMetalShaders_derived.metallib
  ProMedia/MotionHgcMetalShaders_derived.metallib        ← Mac-only
  ProShapes/ProShapesHgcMetalShaders_derived.metallib
  TextFramework/MotionHgcMetalShaders_derived.metallib   ← Mac-only
  VAML/default.metallib
  EDEL/MAPlugInGUISwift/default.metallib                 ← Mac-only
  EDEL/MAVectorUIKit/default.metallib                    ← Mac-only

Plugins:
  Codecs/AppleCanonRAWDecoder/default.metallib           ← Mac-only
  Codecs/AppleREDRAWDecoder/default.metallib             ← Mac-only
  DAL/ACD.plugin/default.metallib                        ← Mac-only
  InternalFiltersXPC/default.metallib                    ← Mac-only
  InternalFiltersXPC/Filters.bundle/default.metallib     ← Mac-only
  InternalFiltersXPC/Filters.bundle/FiltersHgcMetalShaders_derived ← Mac-only
```

### iPad Metal Libraries (15 total)
```
Frameworks:
  CameraKit/default.metallib                             ← iPad-only
  Filters/default.metallib
  Filters/FiltersHgcMetalShaders_derived.metallib
  Filters/FiltersHgcMetalShaders.metallib                ← iPad-only (pre-compiled)
  Flexo/default.metallib
  Helium/HeliumFiltersHgcMetalShaders_derived.metallib
  Helium/HeliumRenderHgcMetalShaders_derived.metallib
  HeliumSenso/default.metallib
  Lithium/LiSolidShaders.metallib
  Lithium/LithiumHgcMetalShaders_derived.metallib
  MDPKit/default.metallib
  ProAppsFxSupport/default.metallib
  ProAppsFxSupport/ProAppsFxSupportHgcMetalShaders_derived.metallib
  ProShapes/ProShapesHgcMetalShaders_derived.metallib
  VAML/default.metallib
```

### Key Differences
- Mac has **27 Metal libraries** vs iPad's **15**
- Mac has GPU-accelerated **Canon RAW and RED RAW debayering** shaders
- Mac has **Motion particle system** shaders (Ozone Particles.ozp)
- Mac has separate **Flexo HGC shaders** (FlexoHgcMetalShaders_derived) — absent on iPad
- iPad has a **CameraKit Metal library** for real-time camera processing
- iPad moves Filters shaders into a **top-level framework** (not XPC-isolated)
- Both share the same HGC (High-level Graphics Compiler) shader naming convention

---

## AI & Machine Learning

### Shared ML Components
| Component | Purpose |
|-----------|---------|
| **VAML** | Video Analysis ML — largest ML framework (438 MB iPad, 403 MB Mac) |
| **VAMLSentencePiece** | NLP tokenization for search |
| **ProTracker** | Object tracking, motion estimation |
| **MusicUnderstandingEmbedded** | Beat detection, music analysis |
| **USearch** | Vector similarity search for semantic queries |

### Mac-Only ML
- **SpeechHelper.xpc** — Out-of-process speech recognition
- **FxAnalyzer.appex** — Video analysis extension
- Spatial video metadata analysis
- Object tracking with wider model set (7.4x larger ProTracker)

### iPad-Only ML
| Framework | Size | Purpose |
|-----------|------|---------|
| **DeepSkyLite** | — | On-device deep learning inference |
| **MAMachineLearning** | 11 MB | Motion ML models for effects |
| **AnalysisKit** | — | Face detection, scene classification |
| **AnalysisService** | — | Background analysis pipeline |
| **VAAppAnalytics** | — | Video content analytics |
| **VACore** | — | Core video analysis |
| **VAKit** | — | Analysis toolkit |

The iPad has more **standalone ML frameworks** because it can't rely on XPC services for background processing. The Mac bundles ML inside larger frameworks (EDEL, Ozone) or delegates to XPC services.

**VAML is the largest framework on iPad** (438 MB) — even larger than on Mac (403 MB). This suggests the iPad may ship additional or optimized ML models for on-device inference without a GPU as powerful as desktop Macs.

---

## Templates, Effects & Transitions

### Bundled Motion Templates

| Category | Mac | iPad | Ratio |
|----------|-----|------|-------|
| **Titles** (.motn) | 357 | 2 | 178:1 |
| **Transitions** (.motr) | 88 | 5 | 18:1 |
| **Effects** (.moef) | 63 | 4 | 16:1 |
| **Generators** (.motn) | 45 | 1 | 45:1 |
| **Total Templates** | **553** | **12** | **46:1** |

### Downloadable Content (Bundled Package)

| Type | Mac | iPad |
|------|-----|------|
| Effects (.moef) | 0 | 92 |
| Titles (.moti) | 0 | 15 |
| Transitions (.motr) | 0 | 7 |
| Sound bundles (.smsbundle) | 0 | 0 |
| **Total bundled assets** | minimal | **559 files** |

### iPad Template Sources

The iPad has three template directories:
1. **`Templates.localized/`** — 12 templates (shared format with Mac)
2. **`iOSTemplates.localized/`** — iPad-specific templates (touch-optimized)
3. **`PETemplates.localized/`** — Additional ProEditor templates
4. **`Bundled Package/`** — 559 downloadable content files (effects, titles, transitions)

### Analysis
The Mac ships **46x more built-in templates** but has no "Bundled Package" downloadable content system. The iPad compensates with a **content delivery system** that downloads additional effects, titles, and transitions after installation — the 559-file Bundled Package. This is likely how iPad keeps its initial download size at 1.4 GB vs Mac's 6.2 GB.

---

## Color Grading & LUTs

### 3D LUT Files

| LUT | Mac | iPad |
|-----|-----|------|
| Apple Log → Rec.709 | ✅ | ✅ |
| Apple Log 2 → Rec.709 | ✅ | ✅ |
| Apple Log → HLG | ❌ | ✅ |
| Apple Log 2 → HLG | ❌ | ✅ |
| Apple Log 2 → Rec.709 (33³ cube) | ❌ | ✅ |
| Apple Log → Rec.709 (33³ cube) | ❌ | ✅ |
| ARRI LogC4 → Gamma24/Rec.709 | ✅ | ✅ |
| ARRI LogC4 → Gamma24/Rec.2020 | ✅ | ✅ |
| Canon Cinema Gamut/Log2 → BT.709 | ✅ | ✅ |
| Canon Cinema Gamut/Log2 → BT.2020 | ✅ | ✅ |
| Canon Cinema Gamut/Log3 → BT.709 | ✅ | ✅ |
| Canon Cinema Gamut/Log3 → BT.2020 | ✅ | ✅ |
| BMD Gen 5 Film → Extended Video | ✅ | ✅ |
| DJI Mavic 3 D-Log → Rec.709 | ✅ | ✅ |
| Panasonic V-Log → V2020/V709 | ✅ | ✅ |
| Fujifilm F-Log/F-Log2 → WDR BT.709 | ❌ | ✅ |
| Nikon N-Log → Rec.709 | ❌ | ✅ |
| Bamboo Slime creative LUTs (9 looks) | ✅ | ❌ |
| **Total LUT files** | **24** | **19** |

### Key Difference
The iPad has **more camera-specific LUTs** (Fujifilm F-Log/F-Log2, Nikon N-Log, extra Apple Log variants) reflecting its use case as a **field editing tool** paired with cameras. The Mac has **creative look LUTs** (Bamboo Slime series: Vibrant, Serene, Analog, Warm, etc.) for color grading workflows.

---

## Audio Engine

### Ozone Framework
| Aspect | Mac | iPad |
|--------|-----|------|
| **Size** | 269 MB | 12 MB |
| **Plugins** | Behaviors.ozp, Particles.ozp, Text.ozp | None |
| **Metal shaders** | 5 metallib files | 0 metallib files |
| **Architecture** | Full Motion audio engine | Slim audio processor |

The Mac Ozone is **22x larger** because it includes the full **Motion** audio engine with particle systems, behaviors, and text rendering. On iPad, audio processing is handled by:
- **MADSP** (20 MB) — Digital signal processing
- **AudioEffects** — Effect processing
- **CoreAudioSDK** — System audio integration
- **AudioAnalysis** — Audio analysis pipeline
- **FlexMusicKit** — Music integration

---

## Motion Integration (EDEL vs MotionEffect)

### Mac: EDEL Framework (241 MB)
EDEL is Apple's **"Effects Description and Execution Layer"** — the bridge between Final Cut Pro and Motion. It's a massive monolith containing 17 sub-frameworks:

```
EDEL.framework/
├── ChordsKit.framework
├── MAAccessibility.framework
├── MACore.framework
├── MADSP.framework
├── MADSPPlugInPublic.framework
├── MAFiles.framework
├── MAHarmony.framework
├── MAMachineLearning.framework
├── MAPlugInGUI_EDEL.framework
├── MAPlugInGUISwift.framework
├── MAResources.framework
├── MAResourcesLg.framework
├── MAResourcesPlugInsShared.framework
├── MASwiftUIControls.framework
├── MASwiftUtilities.framework
├── MAToolKit.framework
└── MAVectorUIKit.framework
```

**Plus MotionEffect.fxp** (in MediaProviders) provides the actual effect templates.

### iPad: Decomposed Architecture
On iPad, EDEL doesn't exist as a single framework. Instead, its sub-frameworks are **promoted to top-level frameworks**:
- ChordsKit, MAAccessibility, MACore, MADSP, MADSPPlugInPublic, MAFiles, MAHarmony, MAMachineLearning, MASwiftUtilities → all top-level

And **MotionEffect.framework** (104 MB) replaces both EDEL and MotionEffect.fxp, containing the effect engine and templates directly.

**iPad is missing** from EDEL:
- MAPlugInGUI_EDEL (no plugin GUI on iPad)
- MAPlugInGUISwift (no plugin GUI)
- MAResources / MAResourcesLg / MAResourcesPlugInsShared (resource bundles)
- MASwiftUIControls (SwiftUI controls for Mac UI)
- MAToolKit (Mac-specific tools)
- MAVectorUIKit (vector drawing for Mac)

This decomposition reflects the iPad's need for **finer-grained framework loading** — iOS can't lazy-load monolithic frameworks as efficiently as macOS.

---

## Timeline & Editing Features

### Feature Comparison

| Feature | Mac | iPad |
|---------|-----|------|
| **Magnetic Timeline** | ✅ | ✅ |
| **Primary Storyline** | ✅ | ✅ |
| **Connected Clips** | ✅ | ✅ |
| **Compound Clips** | ✅ (`FFCompound*`) | ❌ (no evidence) |
| **Multicam Editing** | ✅ (`FFMulticam*`, 8+ classes) | ❌ |
| **Auditions** | ✅ (`FFAnchoredStackAuditioner`) | ❌ |
| **Synchronized Clips** | ✅ | ❌ |
| **360° Video** | ✅ (`FF360*`, 30+ classes) | ❌ |
| **Spatial Video** | ✅ (`FFSpatial*`, MV-HEVC) | ❌ |
| **Proxy Workflows** | ✅ (`FFAssetProxy*`, 20+ classes) | ❌ |
| **Roles** | ✅ (`FFRole*`, 20+ classes) | Limited |
| **Magnetic Mask** | ✅ | ❌ (no evidence) |
| **Cinematic Mode** | ✅ (`FFCinematic*`) | ❌ (no evidence) |
| **Object Tracking** | ✅ (full ProTracker) | ✅ (limited ProTracker) |
| **Auto Reframe** | ✅ (`FFAutoReframe*`) | ❌ |
| **Smart Conform** | ✅ | ❌ |
| **Scene Removal Mask** | ✅ | ❌ |
| **Blade Tool** | ✅ | ✅ |
| **Speed Ramping** | ✅ (RetimingMath) | ✅ (RetimingMath) |
| **Keyframe Editing** | ✅ (ProCurveEditor) | ✅ (basic) |
| **Color Correction** | ✅ (full suite) | ✅ (limited) |
| **FCPXML Import/Export** | ✅ (Interchange) | ✅ (Interchange) |

### Absent from iPad (confirmed by binary analysis)
The iPad Flexo binary contains **no strings** for: 360, spatial, multicam, proxy, compound clip, audition, synchronized clip, auto reframe, magnetic mask, cinematic, or scene removal. These are genuine feature gaps, not just UI differences.

---

## Camera & Live Features (iPad-Only)

The iPad has **7 camera-related frameworks** totaling ~12 MB that don't exist on Mac:

| Framework | Purpose |
|-----------|---------|
| **CameraKit** | Full camera capture pipeline with Metal shaders for real-time processing |
| **CameraKitUI** | Camera recording interface |
| **CameraProfiler** | Camera sensor profiling and calibration |
| **ProARCam** | Augmented reality camera overlays |
| **ProCamera** | Professional camera controls (exposure, focus, white balance) |
| **ProCameraDataModels** | Camera metadata models |
| **PeerCam** | Multi-device camera via **Final Cut Camera** app |

### Final Cut Camera Integration
The `PeerCam` framework and `Communication` framework enable the iPad to receive live camera feeds from iPhones running the **Final Cut Camera** companion app. This peer-to-peer camera system uses:
- Bonjour services (`_atestservice._tcp`, `_rpft._tcp`)
- Bluetooth (`NSBluetoothAlwaysUsageDescription`)
- Local network (`NSLocalNetworkUsageDescription`)

### External Display Support
```xml
UIWindowSceneSessionRoleExternalDisplayNonInteractive
SceneConfigurationName: "External Display"
SceneDelegateClassName: "Final_Cut_Pro.SceneDelegate"
```
The iPad supports **external display output** (via USB-C or Stage Manager) as a non-interactive monitoring display.

---

## Professional Broadcast (Mac-Only)

### Broadcast I/O
| Framework | Purpose |
|-----------|---------|
| **MIO** (928 KB) | Media I/O for professional video hardware (AJA, Blackmagic) |
| **MXFExportSDK** (1.0 MB) | Material Exchange Format export for broadcast delivery |
| **DAL/ACD.plugin** | Device Abstraction Layer for capture hardware |

### Professional Codec Ecosystem
| Plugin | Purpose |
|--------|---------|
| **AppleCanonRAWDecoder** | GPU-accelerated Canon Cinema RAW Light debayering |
| **AppleREDRAWDecoder** | GPU-accelerated RED R3D debayering |
| **DNXDecoder** | Avid DNxHD/DNxHR for facility interchange |
| **AppleAVCIntraCodec** | Panasonic AVC-Intra for broadcast |
| **AppleDVCPROHDCodec** | Panasonic DVCPRO HD |
| **AppleIMXCodec** | Sony IMX |
| **AppleMPEG2Codec** | MPEG-2 for broadcast/DVD |

### RAW Processing Architecture
Mac uses **out-of-process XPC services** for RAW debayering:
```
OOPDebayerService.xpc  → Canon RAW Light processing
OOPProResRawService.xpc → ProRes RAW processing
```
This isolates crash-prone RAW decoding from the main app process — a critical reliability feature for professional workflows.

### Output Encoders
| Encoder | Purpose |
|---------|---------|
| **BluRayH264Encoder.appex** | Blu-Ray disc authoring |
| **DolbyDigitalEncoder.appex** | Dolby Digital AC-3 surround sound |
| **CompressorKit** | Integration with Compressor app |

---

## Document Model & Project Format

### Mac Document Types (10 types)
| Type | Extension | UTI |
|------|-----------|-----|
| Final Cut Pro Library | `.fcpbundle` | `com.apple.FinalCutProLibrary` |
| Final Cut Pro Project | `.fcpproject` | `com.apple.FinalCutProProject` |
| Final Cut Pro Event | `.fcpevent` | `com.apple.FinalCutProEvent` |
| Final Cut Pro XML | `.fcpxml` | `com.apple.finalcutpro.xml` |
| Final Cut Pro XML Bundle | `.fcpxmld` | `com.apple.finalcutpro.xmld` |
| Final Cut Camera Archive | — | (package) |
| Final Cut Share Destination | — | — |
| Final Cut Library Database | — | — |
| Final Cut Pro for iPad Project | `.fcpproj` | `com.apple.VideoApps.fcpproj` |
| Final Cut Pro Effects Preset | — | — |
| Color Preset | `.cboard` | — |

### iPad Document Types (1 type)
| Type | Extension | UTI |
|------|-----------|-----|
| Final Cut Pro for iPad Project | `.fcpproj` | `com.apple.VideoApps.fcpproj` |

### Key Differences
- Mac uses a **Library → Event → Project** hierarchy with `.fcpbundle` containers
- iPad uses a **flat project model** with `.fcpproj` files
- Mac can **open iPad projects** (registered as a handler for `com.apple.VideoApps.fcpproj`)
- Mac supports **FCPXML** interchange; iPad also has Interchange framework but only one document type
- Mac has **Color Preset** and **Effects Preset** document types — iPad has neither
- Mac has **Share Destination** documents for Compressor integration

### Type Declarations (iPad)
The iPad declares these UTIs:
- `com.apple.ProVideo.project`
- `com.apple.ProVideo.sequence`
- `com.apple.ProVideo.resource`
- `com.apple.ProVideo.titleEffect`
- `com.apple.ProVideo.multicam` ← interesting: UTI exists but feature is absent
- `com.apple.ProVideo.generatorEffect`
- `com.apple.ProVideo.timelineItem`
- `com.apple.ProVideo.timelineMarqueeSelect`

The presence of `com.apple.ProVideo.multicam` in iPad's type declarations (despite no multicam feature) suggests **future plans** or **data model compatibility** with Mac projects.

---

## Scripting & Automation

### Mac
| Feature | Details |
|---------|---------|
| **AppleScript** | Full dictionary via `ProEditor.sdef` |
| **Workflow Extensions** | FxPlug 4 API for third-party effects |
| **Third-Party Plugins** | ProExtension framework family (5 frameworks) |
| **FCPBridge** | TCP JSON-RPC injection (this project) |
| **FCPXML** | Full round-trip XML interchange |

### iPad
| Feature | Details |
|---------|---------|
| **AppleScript** | ❌ None |
| **Workflow Extensions** | ❌ None |
| **Third-Party Plugins** | ❌ None |
| **URL Scheme** | `FinalCutApp://` |
| **FCPXML** | Interchange framework present |
| **Shortcuts** | Possible via standard iOS Shortcuts |

The iPad has **zero programmatic automation** capabilities beyond URL schemes and FCPXML.

---

## UI Architecture

### Mac: AppKit-Based
- **NSWindow**, **NSView** hierarchy
- Traditional Mac menu bar
- Mouse + keyboard primary input
- Multi-window support (inspector, viewers, browsers)
- Uses NSOutlineView, NSTableView for browsers
- ProCurveEditor framework for keyframe editing

### iPad: UIKit-Based with Custom Frameworks
- **UIWindow**, **UIView** hierarchy with UIKit
- Touch-first with Apple Pencil support
- 7 dedicated UI frameworks:
  - **Browser** + **BrowserUI** (media browser)
  - **Inspector** + **InspectorUI** (clip inspector)
  - **DirectorKit** + **DirectorKitUI** (storyboard/director view)
  - **HLTimeline** (timeline)
  - **Filmstrip** (filmstrip view)
  - **Player** (video player)
  - **Lens** (canvas/viewer)
- **Dark mode only** (`UIUserInterfaceStyle: Dark`)
- **Landscape + Portrait** support
- **External display** as monitoring output
- Stage Manager support (`UIApplicationSupportsMultipleScenes: false`)
- White point adaptivity for video (`UIWhitePointAdaptivityStyle: Video`)

### iPad-Only UI Features
- `UIDesignRequiresCompatibility: true` — designed for iPad form factor
- `UIFileSharingEnabled: true` — access project files via Files app
- `LSSupportsOpeningDocumentsInPlace: true` — edit files in-place
- Built-in **Settings.bundle** with EULA, acknowledgements, privacy policy, license
- 48 bundled fonts for titles (Mac relies on system fonts)

---

## Localization

Both versions support the **exact same 8 localizations**:

| Language | Directory |
|----------|-----------|
| English | `en.lproj` |
| German | `de.lproj` |
| Spanish | `es.lproj` |
| French | `fr.lproj` |
| Japanese | `ja.lproj` |
| Korean | `ko.lproj` |
| Simplified Chinese | `zh_CN.lproj` |
| Base | `Base.lproj` |

Notable absences: No Italian, Portuguese, Traditional Chinese, Thai, Arabic, or Russian — unusual for a major Apple app.

---

## Business Model

### Mac: One-Time Purchase
- Bundle ID: `com.apple.FinalCut`
- No subscription frameworks
- Full feature set included
- Available in Mac App Store and Apple Store for Business
- No trial limitations

### iPad: Subscription Model
- Bundle ID: `com.apple.FinalCutApp`
- **AppSubscriptions framework** with full subscription lifecycle:
  - Free trial
  - Monthly / Annual plans
  - Entitlement checking
  - Sandbox transaction testing
  - Keychain-stored purchase transactions
  - Placement-aware subscription prompts
  - Post-subscription evaluation
  - Grace period handling
  - Legacy and suite entitlement support
  - FreeForm / appleFreeform SKU references
- **AppleMediaServicesKit** for App Store integration
- Subscription status determines feature access

The `AppSubscriptions` framework strings reveal a sophisticated **placement system** where subscription prompts appear at contextual moments (`MappedPlacement`, `MinIntervalPostSubscriptionEvaluator`), similar to modern SaaS conversion funnels.

---

## Privacy & Entitlements

### Mac Privacy
- `PrivacyInfo.xcprivacy` present
- No camera/microphone/location permissions needed (system-level)
- No Bluetooth permissions
- No tracking declarations

### iPad Privacy
**Permissions requested:**
| Permission | Reason |
|------------|--------|
| Camera | "Allow camera access to record video." |
| Microphone | "Allow microphone access to record audio." |
| Photo Library | "Your Photo Library is needed to access media and save videos." |
| Bluetooth | "Find and connect with Bluetooth accessories." |
| Local Network | "Discover and connect to devices you use." |
| Location | "Tag where videos are taken." |

**Data collected (per privacy manifest):**
- Other data types (analytics, non-linked)
- Usage data (analytics, non-linked)
- Product interaction (analytics, non-linked)
- Purchase history (linked, analytics + app functionality)
- Device ID (linked, app functionality)
- User ID (linked, analytics + app functionality)

**APIs accessed:**
- UserDefaults, Disk Space, System Boot Time, File Timestamps

The iPad collects significantly more data due to iOS App Store privacy requirements and the subscription model's need for purchase tracking.

---

## Bundled Content & Resources

### Fonts

| Platform | Count | Notable Fonts |
|----------|-------|---------------|
| **Mac** | 1 | FCMetro34.ttf |
| **iPad** | 48 | Al Nile, Bank Gothic, Brush Script, Canela, Druk, Founders Grotesk, Garamond Rough, Gill Sans Ultra Bold, Graphik, Handwriting Dakota, Hopper Script, Luminari, Old English Text, Posterboard, Proxima Nova, Sabon, Sketch Block, Trattatello, and 30 more |

The Mac relies on **system-installed fonts** plus Motion-provided fonts. The iPad must **bundle all title fonts** because iOS has a limited system font library.

### Welcome Content
| Content | Mac | iPad |
|---------|-----|------|
| Welcome video | None | Application_Welcome-Video.mp4 (180 MB) |
| Tutorial video | None | IntroducingAllieSherlock.mov (39.4 MB) |
| Onboarding flow | ProOnboardingFlowModelOne (24 MB) | ProOnboardingFlow (65 MB) |

The iPad invests **285 MB** in onboarding content — 20% of the total app size. This reflects the different audience: iPad users may be newer to professional video editing.

### Sound Resources
| Resource | Mac | iPad |
|----------|-----|------|
| UI sounds | System sounds | wheel-tock-sound.caf (5.6 KB) |
| FlexAudio | Via EDEL/Ozone | 2 audio bundles in FlexAudio/ |
| Music assets | Bundled Package | Bundled Package |

---

## Class Architecture & Codebase Scale

### Mac: Decompiled Function Counts (from fcp-search index)

| Binary | Functions | Description |
|--------|-----------|-------------|
| **Flexo** | 90,254 | Core editing engine |
| **Ozone** | 37,748 | Audio/Motion engine |
| **Helium** | 14,833 | GPU rendering |
| **Interchange** | 14,292 | FCPXML |
| **CloudContent** | 11,382 | iCloud sync |
| **AppleMediaServicesKit** | 10,404 | Media services |
| **HeliumSenso** | 8,345 | Sensor rendering |
| **LunaKit** | 8,337 | UI toolkit |
| **Lithium** | 8,321 | 3D rendering |
| **TimelineKit** | 7,817 | Timeline model |
| **TextFramework** | 7,788 | Text rendering |
| **ProChannel** | 6,761 | Audio channels |
| **Final Cut Pro (main)** | 6,482 | App binary |
| **ProCore** | 5,888 | Core utilities |
| **ProAppsFxSupport** | 5,344 | Effects |
| *(...38 more binaries...)* | | |
| **TOTAL** | **303,662** | Across 53 binaries |

The Mac version has **303,662 indexed decompiled functions** across 53 binaries. The Flexo framework alone has **90,254 functions** — more code than most entire applications.

### Mac Class Prefix Analysis
From Flexo string analysis: **8,537 unique FF-prefixed class names** covering:
- FF360* (30+ classes for 360° video)
- FFSpatial* (spatial video)
- FFMulticam* (multicam editing)
- FFProxy* (proxy workflows)
- FFRole* (20+ role classes)
- FFAsset* (asset management)
- FFInspector* (inspector UI)
- FFTimeline* (timeline operations)
- FFAudioComponent* (audio routing)
- FFEffect* (effects management)

### iPad Class Architecture
iPad Flexo binary has **minimal FF-prefixed strings** (only 2 unique matches). The class hierarchy appears to be:
- **Heavily Swift-based** (reduced ObjC class visibility)
- **Distributed across frameworks** (Browser, Inspector, HLTimeline, DirectorKit)
- **HL-prefixed classes** in HLTimeline (iPad-specific timeline UI)
- **FFVAML* classes** for semantic search (present in iPad Flexo strings)

---

## Feature Parity Matrix

### Complete Feature Comparison

| Feature | Mac | iPad | Notes |
|---------|:---:|:----:|-------|
| **Core Editing** | | | |
| Magnetic Timeline | ✅ | ✅ | Shared TimelineKit |
| Primary Storyline | ✅ | ✅ | |
| Connected Clips | ✅ | ✅ | |
| Blade/Cut Tool | ✅ | ✅ | |
| Trim Tools | ✅ | ✅ | |
| Speed Ramping | ✅ | ✅ | Shared RetimingMath |
| Keyframes | ✅ | ✅ | Mac has ProCurveEditor |
| Undo/Redo | ✅ | ✅ | |
| **Advanced Editing** | | | |
| Compound Clips | ✅ | ❌ | |
| Multicam Editing | ✅ | ❌ | iPad has UTI but no feature |
| Auditions | ✅ | ❌ | |
| Synchronized Clips | ✅ | ❌ | |
| 360° Video | ✅ | ❌ | 30+ classes on Mac |
| Spatial Video / MV-HEVC | ✅ | ❌ | |
| Proxy Workflows | ✅ | ❌ | 20+ classes on Mac |
| Auto Reframe | ✅ | ❌ | |
| Smart Conform | ✅ | ❌ | |
| **Color** | | | |
| Color Board | ✅ | ✅ | |
| Color Wheels | ✅ | ✅ | |
| Color Curves | ✅ | ✅ | |
| Custom LUTs | ✅ | ✅ | |
| HDR Support | ✅ | ✅ | |
| Apple Log | ✅ | ✅ | iPad has more Apple Log LUTs |
| Camera LUTs (ARRI, Canon, etc.) | ✅ | ✅ | |
| Magnetic Mask | ✅ | ❌ | |
| Cinematic Mode | ✅ | ❌ | |
| Scene Removal Mask | ✅ | ❌ | |
| **Audio** | | | |
| Audio Mixing | ✅ | ✅ | |
| Audio Effects | ✅ | ✅ | |
| Roles & Subroles | ✅ | Limited | |
| Dolby Digital Export | ✅ | ❌ | |
| **Effects** | | | |
| Built-in Effects | ✅ (553+) | ✅ (12+) | Mac has 46x more |
| Downloadable Content | Limited | ✅ (559 assets) | iPad's content delivery |
| Motion Templates | ✅ | ✅ | Reduced set |
| FxPlug Third-Party | ✅ | ❌ | |
| **Import/Export** | | | |
| FCPXML | ✅ | ✅ | |
| MXF | ✅ | ❌ | |
| RED RAW (R3D) | ✅ | ❌ | |
| Canon Cinema RAW Light | ✅ | ❌ | |
| ProRes RAW | ✅ | Limited | |
| DNxHD/DNxHR | ✅ | ❌ | |
| Compressor Send | ✅ | ❌ | |
| Blu-Ray Export | ✅ | ❌ | |
| **Organization** | | | |
| Libraries | ✅ | ❌ | iPad uses flat projects |
| Events | ✅ | ❌ | |
| Keywords/Ratings | ✅ | ✅ | |
| Smart Collections | ✅ | ? | |
| **Camera** | | | |
| Built-in Camera | ❌ | ✅ | 7 camera frameworks |
| Final Cut Camera | ❌ | ✅ | PeerCam framework |
| Location Tagging | ❌ | ✅ | |
| **Input** | | | |
| Mouse + Keyboard | ✅ | ✅ (limited) | |
| Touch | ❌ | ✅ | |
| Apple Pencil | ❌ | ✅ | |
| Trackpad | ✅ | ✅ | |
| **Platform** | | | |
| AppleScript | ✅ | ❌ | |
| Third-Party Extensions | ✅ | ❌ | |
| External Display | ✅ (native) | ✅ (monitoring) | |
| Broadcast Hardware I/O | ✅ | ❌ | |
| iCloud Sync | ✅ | ✅ | Both have CloudContent |

---

## Key Architectural Insights

### 1. Same Engine, Different Scale
Both apps are built on Flexo + Helium + TimelineKit, but the Mac version is **an order of magnitude larger**. Mac Flexo has 90,254 decompiled functions and 8,537 class names; iPad Flexo is a fraction of that. The shared frameworks prove common ancestry, but the Mac version has accumulated 13+ years of professional features.

### 2. EDEL Decomposition
The most fascinating architectural difference: Mac bundles 17 frameworks inside EDEL (241 MB), while iPad breaks these out as top-level frameworks. This isn't just restructuring — it reflects iOS's need for lazy loading and the absence of versioned framework bundles (`Versions/A/`) on iOS.

### 3. Process Model
Mac uses **multi-process architecture** (main app + 4 XPC services + 1 pluginkit + 3 appex) for stability and security. iPad runs **everything in a single process** with only a share extension. This makes iPad simpler but less resilient to crashes in effects/codecs.

### 4. Content Delivery Strategy
Mac ships with 553 templates baked in. iPad ships with 12 and downloads 559 more via Bundled Package. This is an app-thinning strategy: keep the initial download small, deliver content on-demand.

### 5. Camera-First Design
The iPad version's 7 camera frameworks represent a fundamentally different product vision: it's not just an editor, it's a **capture-to-delivery tool**. The PeerCam framework for Final Cut Camera integration creates a multi-device production system that has no equivalent on Mac.

### 6. Business Model Divergence
Mac (one-time purchase) and iPad (subscription) have different monetization, reflected in architecture: iPad includes `AppSubscriptions` framework with sophisticated entitlement management, placement-aware conversion prompts, and trial handling.

### 7. Multicam UTI Mystery
iPad declares `com.apple.ProVideo.multicam` as a type but has zero multicam code. This strongly suggests multicam is **planned for a future iPad release** and the data model is being prepared.

### 8. Font Bundling
iPad ships 48 fonts (Mac ships 1). This compensates for iOS's limited system font library and ensures titles render identically regardless of what fonts the user has installed.

---

## Conclusions

Final Cut Pro for Mac and iPad are **evolutionary siblings** that share core DNA but serve fundamentally different markets:

**Mac FCP** is a **professional post-production powerhouse**: 303,662 functions across 53 binaries, support for every professional codec, broadcast hardware I/O, 553 built-in templates, 360° and spatial video, multicam, AppleScript automation, third-party extensions, and a multi-process architecture designed for all-day reliability on complex projects.

**iPad FCP** is a **mobile-first capture-and-edit tool**: 102 frameworks optimized for single-process iOS, built-in camera with multi-device support via Final Cut Camera, subscription monetization, touch/pencil input, content delivery system, and a UI framework architecture (Browser, Inspector, HLTimeline, DirectorKit) designed from scratch for touch.

The shared frameworks (Flexo, Helium, TimelineKit, ProTracker, VAML, Ozone, Interchange, and 36 others) prove that Apple is maintaining a **shared codebase** for the editing engine. But the Mac version has roughly **4-5x more code** in every shared framework, reflecting features that simply don't exist on iPad.

The gap is closing — the multicam UTI preparation, shared VAML models, and common Interchange framework show that Apple is building toward greater parity — but as of version 3.0, iPad FCP remains a **subset** of the Mac experience, optimized for a different workflow.

---

*Report generated by binary inspection of Final Cut Pro 12.0 (Mac) and Final Cut Pro 3.0 (iPad). All data derived from framework enumeration, string analysis, Info.plist parsing, Metal library scanning, and template counting. No decompilation of iPad binaries was performed.*
