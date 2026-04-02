---
layout: default
title: FCP Application Internals
---

# Final Cut Pro Application Internals

> **Version**: Final Cut Pro 11.1 (macOS) — April 2026  
> **Binary analysis**: 53 binaries, 303,662 decompiled functions, ~78,000+ ObjC classes

This document provides a comprehensive technical reference to the internal architecture of Apple's Final Cut Pro. It is based on static analysis of the application bundle, decompilation of all embedded binaries, and runtime introspection via FCPBridge.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Application Binary](#application-binary)
- [Framework Dependency Graph](#framework-dependency-graph)
- [Core Frameworks](#core-frameworks)
  - [Flexo](#flexo)
  - [Ozone](#ozone)
  - [Helium](#helium)
  - [HeliumSenso](#heliumsenso)
  - [Lithium](#lithium)
  - [LunaKit](#lunakit)
  - [TimelineKit](#timelinekit)
  - [Interchange](#interchange)
  - [TextFramework](#textframework)
  - [ProChannel](#prochannel)
  - [ProCore](#procore)
  - [MIO](#mio)
  - [AudioMixEngine](#audiomixengine)
  - [FxPlug](#fxplug)
  - [ProAppsFxSupport](#proappsfxsupport)
- [Machine Learning Frameworks](#machine-learning-frameworks)
  - [VAML](#vaml)
  - [VAMLSentencePiece](#vamlsentencepiece)
  - [USearch](#usearch)
  - [ProTracker](#protracker)
  - [MusicUnderstandingEmbedded](#musicunderstandingembedded)
- [Rendering & Graphics Frameworks](#rendering--graphics-frameworks)
  - [ProGL](#progl)
  - [ProGraphics](#prographics)
  - [MDPKit](#mdpkit)
  - [ProOSC](#proosc)
  - [ProShapes](#proshapes)
  - [ProCurveEditor](#procurveeditor)
  - [Stalgo](#stalgo)
- [UI & Inspector Frameworks](#ui--inspector-frameworks)
  - [LunaFoundation](#lunafoundation)
  - [ProInspector](#proinspector)
  - [ProInspectorFoundation](#proinspectorfoundation)
  - [StudioSharedResources](#studiosharedresources)
- [Media & Export Frameworks](#media--export-frameworks)
  - [ProMedia](#promedia)
  - [ProMediaLibrary](#promedialibrary)
  - [MXFExportSDK](#mxfexportsdk)
  - [XMLCodable](#xmlcodable)
- [Cloud & Services Frameworks](#cloud--services-frameworks)
  - [CloudContent](#cloudcontent)
  - [PMLCloudContent](#pmlcloudcontent)
  - [AppleMediaServicesKit](#applemediaserviceskit)
  - [EmbeddedRemoteConfiguration](#embeddedremoteconfiguration)
- [Application Support Frameworks](#application-support-frameworks)
  - [ProAppSupport](#proappsupport)
  - [ProOnboardingFlowModelOne](#proonboardingflowmodelone)
  - [AppAnalytics](#appanalytics)
  - [SwiftASN1](#swiftasn1)
  - [RetimingMath](#retimingmath)
  - [AudioEffects](#audioeffects)
  - [CoreAudioSDK](#coreaudiosdk)
  - [PMLUtilities](#pmlutilities)
- [Extension System](#extension-system)
  - [ProExtension](#proextension)
  - [ProExtensionHost](#proextensionhost)
  - [ProExtensionSupport](#proextensionsupport)
  - [ProService](#proservice)
  - [ProViewServiceSupport](#proviewservicesupport)
- [Plugins](#plugins)
  - [FCP-DAL](#fcp-dal)
  - [FxPlug Plugins](#fxplug-plugins)
  - [RADPlugins](#radplugins)
  - [InternalFiltersXPC](#internalfiltersxpc)
  - [MediaProviders](#mediaproviders)
  - [CompressorKit](#compressorkit)
- [Key Class Reference](#key-class-reference)
  - [Application Controller](#application-controller)
  - [Timeline & Editing](#timeline--editing)
  - [Library & Media Management](#library--media-management)
  - [Effects & Color](#effects--color)
  - [Playback & Rendering](#playback--rendering)
  - [Export & Sharing](#export--sharing)
- [Data Model](#data-model)
  - [The Spine Architecture](#the-spine-architecture)
  - [Core Data Model](#core-data-model)
  - [Undo System](#undo-system)
- [Historical Context](#historical-context)

---

## Architecture Overview

Final Cut Pro is built as a modular macOS application composed of 53 dynamically-linked binaries organized into a deep framework hierarchy. The architecture is shared across Apple's Pro Apps ecosystem — many frameworks are identical between Final Cut Pro, Apple Motion, and to a lesser extent iMovie on macOS/iOS and Clips on iOS.

**Key architectural principles:**

1. **Helium render graph**: All video processing flows through Helium, a tiled GPU renderer that builds a directed acyclic graph (DAG) of render nodes and evaluates regions-of-interest for optimal GPU utilization. Originally CPU-focused (from Shake), it now targets Metal exclusively on Apple Silicon.

2. **Module-based UI**: The interface is composed of `LKViewModule` subclasses managed by `LKModuleLayoutManager`. Each panel (timeline, viewer, inspector, browser, scopes) is an independent module that can be rearranged, hidden, or swapped.

3. **Channel parameter system**: All animatable properties (position, opacity, color wheels, etc.) are represented by `CHChannel` objects from ProChannel. This unified system handles keyframing, value interpolation, undo, and inspector binding for every parameter in the application.

4. **On-device ML pipeline**: Starting with FCP 10.8, Apple integrated substantial machine learning infrastructure — VAML for semantic visual search, ProTracker for transformer-based object tracking and segmentation, MusicUnderstandingEmbedded for beat detection, and USearch for vector similarity indexing. All inference runs on-device via CoreML and the Apple Neural Engine (ANE).

5. **XPC isolation**: Effects rendering, Compressor encoding, and third-party plugins run in sandboxed XPC processes. `FxRemotePluginCoordinator` and `OZFxXPCAPIMediator` manage the cross-process communication. This prevents plugin crashes from taking down the host application.

**Binary scale:**

| Metric | Count |
|--------|-------|
| Total binaries | 53 |
| Total decompiled functions | 303,662 |
| ObjC classes (approx.) | 78,000+ |
| Largest binary (Flexo) | 90,254 functions |

---

## Application Binary

**Binary**: `Final Cut Pro` (6,482 functions)

The main application binary is relatively thin — it serves as the entry point and top-level controller layer that wires together the framework stack. Nearly all business logic lives in the frameworks (primarily Flexo).

### Key Classes

| Class | Methods | Role |
|-------|---------|------|
| `PEAppController` | 489 | Main application controller. Manages window layout, preferences, menu state, and coordinates all top-level modules. |
| `PEPlayerContainerModule` | 276 | Container for the viewer/player panel. Manages playback controls, timecode display, and video output routing. |
| `PEEditorContainerModule` | 235 | Container for the timeline editor. Hosts the timeline view, index sidebar, and editing tools. |
| `PEInspectorContainerModule` | 63 | Container for the inspector panel. Routes between video, audio, info, and generator inspector tabs. |
| `PEScopesContainerModule` | 60 | Container for video scopes (waveform, vectorscope, histogram). |
| `PEMainWindowModule` | 69 | Top-level window module. Manages the main window frame, toolbar, and workspace layouts. |
| `PEDocument` | 58 | Document model for the application. Manages library file references and document lifecycle. |
| `PEMediaBrowserContainerModule` | 57 | Container for the media browser (photos, music, sound effects). |
| `PEImportOptionsModule` | 66 | Import settings UI (transcoding, analysis, keyword assignment). |
| `PEColorModule` | 31 | Color correction workspace module. |
| `PESegmentationMaskEditorContainerModule` | 21 | Container for the Magnetic Mask editor. |
| `PETrackingEditorContainerModule` | 19 | Container for the object tracking editor. |
| `PEVariantsContainerModule` | 28 | Manages variant views (e.g., different workspace configurations). |
| `PEPerformanceController` | 24 | Monitors render performance and adjusts quality dynamically. |
| `PESelectionManager` | 24 | Tracks selection state across all panels. |
| `CloudContentCatalog` | 22 | Swift class managing downloadable content from Apple's servers. |
| `PEViewerDFRController` | 32 | Touch Bar integration for the viewer. |
| `PEPlayerDFRController` | 25 | Touch Bar integration for playback controls. |
| `PEVoiceOverWindowController` | 120 | Controls the voiceover recording interface. |

---

## Framework Dependency Graph

The framework hierarchy flows roughly as follows (simplified):

```
Final Cut Pro (app binary)
├── Flexo (core logic, 90K functions)
│   ├── Helium (GPU render engine)
│   │   ├── HeliumSenso (optical flow / stabilization)
│   │   ├── HeliumFilters (GPU filter shaders)
│   │   └── HeliumRender (render pipeline shaders)
│   ├── Ozone (Motion engine, compositing)
│   │   └── AudioMixEngine
│   ├── LunaKit (UI framework)
│   │   └── LunaFoundation (timecode, formatters)
│   ├── TimelineKit (magnetic timeline)
│   ├── Interchange (FCPXML)
│   │   └── XMLCodable (XML parser)
│   ├── ProChannel (parameter channels)
│   ├── ProCore (shared utilities)
│   ├── TextFramework (titles, text rendering)
│   ├── Lithium (3D / depth rendering)
│   ├── MIO (media I/O, devices)
│   ├── ProAppsFxSupport (effects, LUTs)
│   ├── FxPlug (plugin API)
│   ├── ProTracker (ML object tracking)
│   ├── VAML (ML visual search)
│   │   ├── VAMLSentencePiece (tokenizer)
│   │   └── USearch (vector index)
│   ├── MusicUnderstandingEmbedded (beat detection)
│   ├── CloudContent (downloadable content)
│   ├── ProMedia (RAW, media handling)
│   ├── MXFExportSDK (MXF export)
│   ├── MDPKit (Metal 2D drawing)
│   ├── ProGL (OpenGL context)
│   ├── ProGraphics (graphics utils)
│   ├── ProOSC (on-screen controls)
│   ├── ProShapes (shape editing)
│   ├── ProCurveEditor (keyframe curves)
│   ├── ProInspector (inspector UI)
│   ├── ProMediaLibrary (library organizer)
│   ├── EmbeddedRemoteConfiguration (feature flags)
│   ├── AppAnalytics (telemetry)
│   └── ProAppSupport (app identity, logging)
├── ProOnboardingFlowModelOne (purchase/trial flow)
├── AppleMediaServicesKit (App Store services)
├── SwiftASN1 (receipt validation)
├── ProExtension / ProExtensionHost / ProExtensionSupport
└── Stalgo (computational geometry)
```

---

## Core Frameworks

### Flexo

**Functions**: 90,254 — **The largest and most critical framework in Final Cut Pro.**

Flexo is the core logic framework that contains virtually all of FCP's editing engine, data model, effects pipeline, media management, sharing, and UI controllers. If a feature exists in Final Cut Pro, its implementation almost certainly lives in Flexo.

**What Flexo contains:**

- **Timeline data model**: `FFAnchoredSequence` (1,148 methods), `FFAnchoredObject` (914), `FFAnchoredCollection` (298), `FFAnchoredMediaComponent` (128), `FFAnchoredTransition` (81), `FFAnchoredTimeMarker` (49), `FFAnchoredCaption` (93), `FFAnchoredStack` (227), `FFAnchoredAngle` (80)
- **Timeline editing module**: `FFAnchoredTimelineModule` — the single largest class in the entire application with **1,442 methods**. This class handles every editing action: blade, trim, insert, overwrite, ripple, roll, slip, slide, undo, redo, markers, speed changes, transitions, and more.
- **Effects pipeline**: `FFEffect` (522), `FFEffectStack` (481), `FFHeColorEffect` (142), `FFColorSecondaryEffect` (68), `FFBalanceColorBaseEffect` (58), `FFNoiseReduction` (58), `FFStabilizationEffect` (76), `FFRetimingEffect` (106), `FFMaskedEffectBase` (100), `FFMicaTitle` (75)
- **Cinematic mode editing**: `FFHeCinematicEffect` (83) — handles Apple's Cinematic video mode, including depth-based focus manipulation, focus point tracking, and f-number adjustment. Loads cinematography scripts and renders depth-of-field effects.
- **Magnetic Mask / segmentation**: `FFSegmentationMask` (94), `FFSegmentationMaskOSC` (81), `FFSegmentationMaskEditorLayer` (46) — ML-powered subject isolation with on-screen editing controls. `FFIsolationMask` (74) provides hue/saturation/luma-based color isolation masking.
- **Stabilization & motion analysis**: `FFStabilizationEffect` (76), `FFDominantMotionMediaRep` (81) — video stabilization using optical flow analysis from HeliumSenso. Supports InertiaCam, tripod mode, and smooth cam algorithms with per-axis translation/rotation/scale smoothing.
- **Auto Reframe**: `FFDestAutoReframe` — intelligent content-aware reframing using face detection, spatial clustering, and importance scoring. Uses `FFVideoAnalysisCollatedFace` and `FFVideoAnalysisCollatedItem` for spatial clustering of detected subjects.
- **Object tracking**: `FFTrackerManager` (120), `FFTrackerUtils` (84) — coordinates with ProTracker for ML-based object tracking.
- **Library management**: `FFLibrary` (239), `FFLibraryDocument` (277), `FFLibraryItem` (100), `FFLibraryContainer` (84), `FFLibraryTask` (84), `FFStorageManager` (48), `FFConsolidateLibraryFilesController` (48)
- **Media handling**: `FFAsset` (373), `FFMedia` (136), `FFMediaRef` (58), `FFMediaRep` (176), `FFImage` (140), `FFProvider` (86), `FFProviderCG` (52), `FFProviderFig` (47), `FFSourceVideoFig` (97)
- **Import/Export**: `FFXMLImporter` (302), `FFXMLExporter` (172), `FFXML`, `FFXMLSettingsExporter`, `FFSequenceSettingsExporter` (51), `FFMXFWriter` (51)
- **Sharing**: `FFShareDestination` (140), `FFSharePanel` (96), `FFBaseSharePanel` (150), `FFShareDestinationExportMediaController` (146), `FFBackgroundShareOperation` (62)
- **Browser/organizer**: `FFOrganizerFilmstripModule` (640), `FFOrganizerFilmstripView` (380), `FFOrganizerFilmListViewController` (366), `FFEventLibraryModule` (194), `FFMediaSidebarController` (119)
- **Inspector controllers**: `FFInspectorTabModule` (89), `FFInspectorModuleMetadata` (112), `FFInspectorModuleChannels` (80), `FFInspectorModuleCaptionEditor` (176)
- **Player/viewer**: `FFPlayerVideoModule` (379), `FFPlayer` (251), `FFPlayerModule` (193), `FFPlayerView` (110), `FFPlayerScheduledData` (171)
- **Color correction**: `FFColorSettingsTool` (48), `FFInlineColorBoardInspectorController` (79), `FFPentaSliderThumbCell` (56), `FFVideoScopesView` (73)
- **Retiming**: `FFRetimingEffect` (106), `FFRetimeSettingsTool` (79), `FFSpeedSegmentLayer` (98)
- **Captions**: `FFAnchoredCaption` (93), `FFCaptionTextBlock` (85), `FFCaptionTextBlockController` (63), `FFCaptionExportFileSelector` (59), `FFCaptionImportFileSelector` (45)
- **Multicam**: `FFMultiAngleManager` (92), `FFMultiAngleItem` (72), `FFMCSwitcherVideoSource`
- **Duplicate detection**: `EDTDupeDetector` (71), `FFDupeDetectionMediaUsage` (74), `FFUpdateDupesOperation` (60), `EDTStoryModel`
- **Roles**: `FFRole` (103), `FFRoleEditorController` (180), `FFRoleColorScheme` (83)
- **Workspaces**: `FFWorkspace` (57)
- **Background rendering**: `FFBackgroundRenderManager` (50), `FFBackgroundTaskQueue` (93), `FFBackgroundTask` (60), `FFRenderStateTracker` (66), `FFHGRendererManager` (45)
- **Video output**: `FFDestVideo` (62), `FFDestVideoDisplay` (78), `FFDestVideoCMIO` (51), `FFDestVideoCMIODirect` (63), `FFDestQTExporter` (55)
- **Pasteboard**: `FFPasteboard` (76), `FFPasteEffectsWindowController` (53), `FFPasteAttributesOperation` (52)
- **Undo**: `FFUndoHandler` (54) — routes through FCP's `FFUndoManager`, not the standard NSUndoManager responder chain.
- **Theater**: `FFTheaterModule` (194), `FFTheaterDatabase` (107), `FFTheaterItem` (72) — manages the Theater feature for sharing projects to Apple TV.
- **Video format**: `FFVideoFormat` (66), `FFVideoProps` (212), `FFPixelFormat` (78)
- **RED camera support**: `FFREDSettings` (96), `FFREDRAWSettingsController` (68), `FFVTRAWSettingsHud` (50) — ProRes RAW and RED RAW decode settings.
- **Keywords**: `FFKeywordEditor` (84), `FFMediaEventKeyword` (56)
- **Voiceover**: `FFVoiceOverController` (178) — voiceover recording directly to the timeline.
- **Semantic search integration**: `FFVAMLSearchContext` (73) — bridges the VAML ML framework into the browser search.
- **Smart Collections**: `FFMediaEventSmartCollection` (70), `FFOrganizerFilterHUDUtils` (85)
- **Photos import**: `FFPhotosImportTask` (65) — direct import from Photos library.
- **iMovie import**: `FFIMovieImporter` (131), `FFIMovieIOSImporter` (62), `FFIMovieIOSEdits` (78), `FFIMovieIOSv5EditTransformer` (47) — import projects from iMovie (macOS and iOS).

**Embedded sub-frameworks within Flexo:**

- **DeepSkyLite**: Core Data interface. Contains the compiled `.momd` (Managed Object Model) files that define the persistent data schema for FCP libraries (`.fcpbundle`). All timeline items, events, projects, keywords, and metadata are stored as Core Data entities.
- **FaceCoreEmbedded**: Apple's face recognition framework (acquired from Polar Rose). Powers the People smart collection and face-based shot analysis.

**Embedded resources within Flexo:**

- Default `.audio.effectBundle` and `.effectBundle` files for built-in audio and video effects
- FCPXML Document Type Definitions (DTD) from version 1.0 through the current version
- Compressor presets for FCPX Bundles, Library XMLs, and Project XMLs
- 72+ fonts used internally by Final Cut Pro and iMovie
- 3D LUTs (e.g., `VLog_to_V709_forV35_ver100.3dlut`, `VLog_to_V2020_forV35_20160707.3dlut`)
- Trailer templates, themes, titles, and map assets
- Metadata definitions (DPP Editorial Services, DPP Media, MXF Metadata)
- Color presets in `.cboard` format
- Nib files for the full range of FCP and iMovie windows and modules
- `FFLocalizable.strings` — UI strings for both iMovie and Final Cut Pro
- `ProMSRendererTool` — a video and audio rendering engine utility

---

### Ozone

**Functions**: 37,748

Ozone is the **Apple Motion compositing and render engine**, shared identically between Final Cut Pro and Motion. Within FCP, Ozone handles the rendering of Motion templates (titles, generators, transitions, effects), 3D compositing, particle systems, behaviors, and the FxPlug plugin host environment.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `OZViewer` | 285 | Motion viewer — renders composited frames for display. |
| `OZDocumentKeyResponder` | 264 | Key event routing for Motion-based editing. |
| `OZFxPlugParameterHandler` | 236 | Manages FxPlug plugin parameters. Handles value reads, writes, keyframing, and type conversion. |
| `OZCanvasModule` | 233 | The Motion canvas — the 2D/3D compositing workspace. |
| `OZTimelineView` | 194 | Motion's timeline view (used for motion template editing). |
| `OZViewerOSC` | 189 | On-screen controls in the Motion viewer. |
| `OZLibraryEntry` | 171 | An entry in the Motion template library. |
| `OZOSCObjectDelegate` | 161 | Delegate for on-screen control interaction. |
| `OZLibraryModuleBase` | 153 | Base class for the Motion library browser. |
| `OZObjCDocument` | 135 | Motion document model. |
| `OZTimelineModule` | 111 | Motion timeline module. |
| `OZFxPlugTimingAPI` | 64 | Timing/synchronization API for FxPlug plugins. |
| `OZFxXPCAPIMediator` | 47 | XPC bridge for out-of-process FxPlug plugin communication. |
| `OZSegmentationMaskOSC` | 54 | Segmentation mask on-screen control (for Motion's mask tools). |
| `OZMetalLayerView` | 53 | Metal-backed view for hardware-accelerated rendering. |
| `OZDragManager` | 53 | Drag-and-drop coordination. |
| `OZShareManager` | 47 | Export/sharing from Motion context. |
| `OZTimingCoordinator` | 75 | Synchronizes timing between layers and compositions. |
| `OZHUDManager` | 46 | Manages heads-up display overlays. |
| `OZRotoshapeOnscreenControl` | 93 | Rotoscoping shape controls. |

**Embedded sub-frameworks:**

- **AudioMixEngine** — see [AudioMixEngine](#audiomixengine)

**Embedded plugins:**

| Plugin | Purpose |
|--------|---------|
| `Behaviors.ozp` | Motion behavior system (gravity, random motion, attract/repel, etc.) |
| `Navigator.ozp` | Camera/view navigation behaviors |
| `Particles.ozp` | Particle emitter system |
| `Text.ozp` | Text animation behaviors |

**Embedded resources:**

- Environment maps (OpenEXR format) for 3D lighting and reflections
- Physical layer assets (OpenEXR) for realistic material simulation
- Motion template project settings and presets

---

### Helium

**Functions**: 14,833

Helium is the **GPU-accelerated video processing engine** at the heart of Final Cut Pro's render pipeline. Originally developed by the "Nothing Real" team in Santa Monica (Arnaud Hervas, Emmanuel Mogenet, and Christophe Souchard — co-founders of Shake), Helium implements automatic tiled rendering across all available GPU compute resources.

**Architecture:**

Helium builds a **render graph** — a directed acyclic graph of processing nodes. Before rendering, it evaluates the graph to:

1. Determine optimal tile sizes based on convolution kernel dimensions and shader requirements
2. Compute regions-of-interest (ROI) so that only necessary pixels are processed
3. Schedule tiles across available GPU resources
4. Handle precision differences between processing units (CPU rounding vs GPU rounding)

The renderer ensures tiles merge seamlessly, even when filters require pixel neighborhoods beyond tile boundaries. This was the original technical breakthrough from Shake's architecture.

**Current state (2026):**

Helium has transitioned almost entirely to **Metal**. The codebase contains extensive Metal shader functions (`metal_sample2d0_sv` through `metal_sample2d7_sv` and half-precision variants), while legacy OpenGL shim symbols remain for backward compatibility. The single ObjC class `HeliumRenderHgcMetalShadersHelper` (3 methods) manages Metal shader compilation and caching.

**Key subsystems:**

- **HGRenderNode** — individual nodes in the render graph. `SetRenderNodeDestinationInfo` configures output targets, backing buffers, and image requests.
- **HGCVBitmap** — GPU-backed bitmap representation used throughout the pipeline
- **HCache** — render cache plugin for frame reuse
- **HConverter** — format conversion plugin (color space, pixel format, resolution)
- **Metal samplers** — 2D texture sampling in multiple precision modes (float, half) for various filter configurations
- **FFHGAsyncQueue** — asynchronous render task queue (defined in Flexo, consumed by Helium)

**Embedded sub-frameworks:**

| Framework | Purpose |
|-----------|---------|
| **HeliumFilters** | GPU shader library for built-in video filters (blur, sharpen, color operations, distortion, etc.) |
| **HeliumRender** | Core render pipeline shaders (compositing, blending, format conversion) |
| **HeliumSenso** | Optical flow and motion estimation engine — see [HeliumSenso](#heliumsenso) |
| **HeliumSensoCore** | Low-level optical flow GPU compute functions |
| **HeliumSensoCore2** | Higher-level optical flow interface layer |

---

### HeliumSenso

**Functions**: 8,345

HeliumSenso is the **optical flow and motion estimation engine** that powers FCP's stabilization, retiming (Optical Flow quality), SmoothCam, and 360° camera motion analysis. Originally based on Senso technology acquired by Apple (from Christophe Souchard), it has evolved into a sophisticated GPU-accelerated computer vision pipeline.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `HORBExtractionIntermediateBuffers` | 63 | ORB (Oriented FAST and Rotated BRIEF) feature extraction buffers |
| `HVideoFrameWriterQueue` | 48 | Queues frames for optical flow analysis |
| `HMetalRANSACDispatcher` | 34 | GPU-accelerated RANSAC for robust homography estimation |
| `HMetalFAST9BRIEF` | 25 | FAST-9 corner detection + BRIEF descriptor computation on Metal |
| `HStabilizationSuccessClassifier` | 16 | Classifies whether stabilization is achieving acceptable results |
| `HICFlowControlBasic` | 9 | Basic flow control for iterative computation |
| `HImageHomographyResampler` | 7 | Resamples images using estimated homography transforms |

**Core algorithms:**

1. **Optical flow estimation**: `HFOpticalFlowAnalyzerSimple` and `HFOpticalFlowAnalyzerSimpleInterface` compute dense optical flow between frame pairs. Supports both standard and 360° video.

2. **Feature matching**: FAST-9 corner detection and BRIEF binary descriptors (`HMetalFAST9BRIEF`) provide sparse feature correspondences, which are robustly filtered by `HMetalRANSACDispatcher`.

3. **Motion estimation**: `OZOpticalFlow::Private::MotionEstimator` computes global camera motion from optical flow fields.

4. **Flow warping**: `soComputeKernel_OF_FlowWarpOneImageWithResampleFlow` and `FlowWarpTwoImagesWithResampleFlow` — GPU compute kernels that warp images using flow fields for frame interpolation during retiming.

5. **360° camera motion**: `so360CameraMotionFromOFlow_Prep::EstimateFlowOnViews` estimates camera motion for spherical/equirectangular video across multiple viewpoints.

6. **ISP integration**: `ISPOpticalFlowAnalyzerMPNode` and `ISPOpticalFlowAnalyzerRetimerMPNode` integrate optical flow analysis into the image signal processing pipeline for retiming operations.

---

### Lithium

**Functions**: 8,321

Lithium is the **3D rendering engine** used for stereoscopic/spatial video, depth compositing, and 3D text effects. While it historically used OpenGL Shading Language (GLSL), the modern implementation is Metal-based.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `LiPersonDepthWriter` | 13 | Writes person-segmented depth maps for spatial video output |
| `DummyForBundle` | 1 | Bundle loader |

**Key subsystems (C++ namespaces):**

- **Li3DEngineImageSource** — 3D rendering engine with shadow casting, light-to-world transforms, and polygon/geometry management
- **LiLight, LiGeode, LiPolygon** — scene graph objects for 3D compositing
- **PCMatrix44Tmpl** — 4x4 matrix operations for 3D transforms (shared with ProCore)

**GLSL shaders:**

| Shader | Purpose |
|--------|---------|
| `shadow.glsl` | Shadow map generation for 3D objects |
| `ShadowBlurFragShader.glsl` | Soft shadow blurring |

**Spatial video support:**

Lithium handles Apple's Spatial Video format (stereoscopic MV-HEVC). `LiPersonDepthWriter` processes person depth maps to generate the disparity data needed for Apple Vision Pro playback. `FFHeS3DAdjustEffect` in Flexo provides stereoscopic convergence, depth, and eye-swap controls.

---

### LunaKit

**Functions**: 8,337

LunaKit is the **UI framework** that provides all of Final Cut Pro's custom interface components — windows, toolbars, browsers, audio meters, timecode displays, color wells, scrubbers, and the module layout system. It is shared between Final Cut Pro, Motion, and iMovie.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `SRColor` | 1,335 | **Second-largest class.** Comprehensive color definition system for the entire UI. Defines named colors for every UI element (waveforms, scopes, timeline items, backgrounds, etc.) |
| `LKColor` | 1,321 | UI color definitions. Parallel to SRColor but for a different theme context. |
| `TLKColor` | 107 | Timeline-specific color definitions. |
| `LKSegmentedScrubberCell` | 212 | Segmented scrubber control (e.g., the filmstrip timeline scrubber). |
| `LKModuleLayoutManager` | 188 | **Core layout engine.** Manages the arrangement of all UI modules (viewer, timeline, browser, inspector) within the workspace. |
| `LKViewModule` | 185 | Base class for all UI panels. Every major UI area is a `LKViewModule` subclass. |
| `LKTileView` | 165 | Tiled view for efficient rendering of large scrollable content. |
| `LKContainerView` | 114 | Container for composing multiple views. |
| `LKCommandsController` | 82 | Manages the Command Editor — key binding customization. |
| `LKWelcomeScreenWindowController` | 96 | The welcome/getting-started screen. |
| `LKScrubberCell` | 83 | Individual cell in a scrubber control. |
| `LKContainerNode` | 83 | Node in the view hierarchy tree. |
| `LKContainerModule` | 59 | Module that contains other modules. |
| `LKWindowModule` | 58 | Top-level window module. |
| `LKKeyboardView` | 53 | Virtual keyboard display for the Command Editor. |
| `LKColorWell` | 49 | Custom color picker control. |
| `LKTimecode` | 45 | Timecode display component. |
| `LKPreferences` | 40 | Preferences management. |
| `LKCommand` | 36 | Represents a single keyboard command binding. |
| `LKCommandSet` | 36 | A complete set of keyboard command bindings. |
| `LKCoachTipManager` | 21 | Coach tips / onboarding UI hints. |

**Embedded resources:**

| Resource | Contents |
|----------|----------|
| `AppThemeBits.car` | CoreUI archive with PSD-based UI element graphics |
| `AppThemeBitsB.car` | Retina-resolution variant |
| `Assets.car` | Mouse cursor images |
| `NOX.car` | Standard controls (checkboxes, buttons, steppers, text fields) |
| `NOXConsumer.car` | iMovie-specific control variants |
| `NOXHud_MOTION.car` | Motion HUD graphics |
| `NOXHud.car` | Final Cut Pro HUD graphics |
| `NOXInspector.car` | Inspector panel graphics |
| `NOXViewer.car` | Viewer panel graphics |
| `NOXToolbar.car` | Toolbar graphics and loading animations |

**Configuration plists:**

| File | Purpose |
|------|---------|
| `LKColor.plist` | Named color definitions for HUD and general UI elements |
| `SRColor.plist` | Named color definitions for audio waveforms, timeline elements, etc. |
| `TLKColor.plist` | Timeline-specific color definitions |
| `LKCursor.plist` | Cursor hotspot positions |
| `SRCursor.plist` | Additional cursor definitions |
| `Container.moduleLayout` | Default module layout configuration |

**Diagnostic tools:**

- `viddiagnose.pl` — A Perl script that generates diagnostic reports for Apple's support/engineering teams.

---

### TimelineKit

**Functions**: 7,817

TimelineKit (TLK) implements the **magnetic timeline** — FCP's signature editing paradigm. It handles all visual representation, user interaction, and layout computation for the timeline view. This framework is shared between Final Cut Pro, iMovie, and Motion (for Motion's simpler timeline).

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `TLKTimelineView` | 670 | **Main timeline view.** Handles drawing, hit-testing, scrolling, zooming, and all visual rendering of the timeline. |
| `TLKDragItemsHandler` | 188 | Manages drag-and-drop of clips, effects, and transitions onto the timeline. Implements magnetic snap behavior. |
| `TLKItemLayer` | 179 | CALayer subclass representing a single clip/item in the timeline. |
| `TLKEventDispatcher` | 176 | Translates mouse/keyboard events into editing operations. This is the "backend" of the magnetic timeline — it converts user gestures into semantic editing actions. |
| `TLKLayoutDatabase` | 147 | Stores computed layout positions for all timeline items. |
| `TLKLayoutManager` | 130 | Computes the spatial layout of clips, lanes, and containers in the timeline. |
| `TLKLayerManager` | 116 | Manages the creation, recycling, and positioning of CALayers for timeline items. |
| `TLKItemComponentInfo` | 116 | Metadata about a clip's visual components (filmstrip, waveform, role indicator). |
| `TLKDragEdgesHandler` | 109 | Handles edge-dragging for trim operations (ripple, roll, slip, slide). |
| `TLKTimelineHandler` | 101 | Base handler for timeline interaction events. |
| `TLKDataSourceProxy` | 98 | Proxy between the data model and the timeline view. |
| `TLKTimelineLayer` | 83 | Root CALayer for the timeline content area. |
| `TLKContainerInfo` | 75 | Layout info for compound clips, multicam clips, and storylines. |
| `TLKPlayhead` | 57 | The playhead indicator — position, drawing, and hit-testing. |
| `TLKSelectionManager` | 48 | Tracks which clips/ranges are selected. |
| `TLKTimingModel` | 52 | Maps between timeline coordinates and time values. |
| `TLKPrecisionEditor` | 46 | The precision editor (double-click an edit point to open). |
| `TLKMarkerLayer` | 50 | Renders markers on the timeline. |
| `TLKRulerLane` | 50 | The timecode ruler at the top of the timeline. |
| `TLKTimecodeDisplayView` | 48 | Timecode display in the timeline header. |
| `TLKAccessibilityLayer` | 50 | VoiceOver/accessibility support for timeline items. |

**Supporting classes:**

- `ERLRelationalObject` (43) / `ERLRelationalTable` (38) — An embedded relational data structure used by TimelineKit for efficient item-to-layout mapping.
- `TLKSyncItemsOperation` (57) / `TLKDataSyncOperation` (51) — Background operations that synchronize the timeline view with the data model after edits.
- `TLKUserDefaults` (48) — Timeline-specific user preferences (clip height, waveform display, snapping behavior).

---

### Interchange

**Functions**: 14,292

Interchange is the **FCPXML processing framework**, written primarily in **Swift**. It handles the bidirectional conversion between FCP's internal data model and the FCPXML interchange format, supporting all versions of the DTD.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `IXAssetClip` | 89 | FCPXML representation of an asset clip |
| `IXClip` | 83 | Base FCPXML clip type |
| `IXReferenceClip` | 81 | Reference clip (compound/multicam reference) |
| `IXSyncClip` | 81 | Synchronized clip |
| `IXVideo` | 71 | Video element |
| `IXLiveDrawing` | 69 | Live Drawing annotations |
| `IXTitle` | 69 | Title element |
| `IXAsset` | 52 | Media asset reference |
| `IXMulticamClip` | 49 | Multicam clip |
| `IXParameter` | 44 | Effect/generator parameter |
| `IXEditContainer` | 44 | Container for edit elements (spine, sequence) |
| `IXAudio` | 43 | Audio element |
| `IXAudioChannelSource` | 41 | Audio channel source/routing |
| `IXTransform360` | 39 | 360° transform parameters |
| `IXSequence` | 30 | Sequence/project |
| `IXDocument` | 28 | Top-level FCPXML document |
| `IXCaption` | 25 | Caption/subtitle element |
| `IXTransition` | 23 | Transition element |
| `IXMaskIsolation` | 18 | Mask isolation parameters |
| `IXStereo3D` | — | Stereoscopic 3D parameters (convergence, auto-scale, eye swap, depth) |
| `IXSpine` | 16 | Primary storyline spine |
| `IXXMLPasteboardType` | 18 | FCPXML pasteboard support for copy/paste |

**Swift FCPXML converter:**

- `FCPXMLConverter` — The main converter class. Methods include `xmlDataFromParameters(_:version:)`, `xmlDocument(from:)`, and `validateDocument(_:version:)`. Supports all FCPXML versions.

**Audio channel routing (Swift):**

- `AudioChannelLayoutItem` — Represents a channel layout with name, channel map, and routings
- `AudioChannelLayoutRouting` — Individual routing entry
- `AudioChannelLayoutRoutingMap` — Complete routing map for multi-channel audio

---

### TextFramework

**Functions**: 7,788

TextFramework provides all **text rendering, title animation, and typography** capabilities. It powers both FCP's built-in titles (basic title, lower third) and the full range of Motion-designed text templates.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `TXTextTool` | 147 | Primary text editing tool — handles text input, selection, formatting. |
| `TXGlyphOSC` | 78 | On-screen controls for individual glyph manipulation. |
| `TXMaterialController` | 75 | 3D text material assignment (surface textures, lighting). |
| `TXMaterialAssignmentController` | 51 | UI controller for material layer assignment. |
| `TXTextPathOSC` | 46 | On-screen controls for text-on-a-path. |
| `TXTextViewController` | 41 | Text editing view controller. |
| `TXRulersOverlay` | 41 | Text alignment rulers. |
| `TXSequenceOSC` | 40 | Text sequence/animation on-screen controls. |
| `OZTextInspectorController` | 36 | Inspector panel for text properties. |
| `TXStylePreviewController` | 33 | Preview rendering for text style presets. |
| `TXGlyphMotionPathOnScreenControl` | 21 | Per-glyph motion path editing. |
| `TXGlyphAnimationPathOnScreenControl` | 21 | Per-glyph animation path editing. |

TextFramework uses Metal 1.0+ for GPU-accelerated text rendering and 3D text effects.

---

### ProChannel

**Functions**: 6,761

ProChannel implements the **unified parameter channel system** used by both Final Cut Pro and Motion. Every animatable property in the application — from position and scale to color wheel values and audio levels — is represented as a `CHChannel` object.

**Channel type hierarchy:**

| Class | Methods | Description |
|-------|---------|-------------|
| `CHChannel` | 76 | Base channel type |
| `CHChannelBase` | 74 | Abstract base with value storage |
| `CHChannelFolder` | 36 | Group of related channels |
| `CHChannelDouble` | 28 | Double-precision floating-point value |
| `CHChannelEnum` | 26 | Enumerated value (dropdown) |
| `CHChannelUint32` | 25 | Unsigned 32-bit integer |
| `CHChannelBool` | 25 | Boolean toggle |
| `CHChannelUint16` | 25 | Unsigned 16-bit integer |
| `CHChannelColorNoAlpha` | 23 | RGB color without alpha |
| `CHChannelIntegral` | 22 | Integer value |
| `CHChannelBool3D` | 19 | 3D boolean (e.g., axis enable/disable) |
| `CHChannelQuad` | 16 | 4-component value |
| `CHChannel3D` | 16 | 3D vector (x, y, z) |
| `CHChannelShear` | 15 | Shear transform |
| `CHChannelRotation3D` | 15 | 3D rotation (Euler angles) |
| `CHChannel2D` | 15 | 2D vector (x, y) |
| `CHChannelPosition3D` | 14 | 3D position |
| `CHChannelHistogram` | 14 | Histogram data |
| `CHChannelScale3D` | 13 | 3D scale |
| `CHChannelColor` | 12 | RGBA color |
| `CHChannelGradientFolder` | 11 | Gradient parameter group |
| `CHCompoundChannel` | 10 | Compound channel (multiple sub-channels) |
| `CHChannelTransformSwitch` | 9 | Transform mode selector |
| `CHChannelLevels` | 9 | Levels adjustment |
| `CHChannelButton` | 8 | Button action trigger |
| `CHChannelCurve` | 6 | Bezier curve data |
| `CHChannelText` | 7 | Text string parameter |
| `CHChannelGradient` | 7 | Gradient definition |
| `CHChannelDecibel` | 4 | Audio level in decibels |

The channel system provides:
- **Keyframe interpolation** with configurable easing curves
- **Undo integration** via `CHChannelUndoState`
- **Inspector binding** — the inspector automatically generates UI for any channel tree
- **XML serialization** for FCPXML export/import
- **Notification dispatch** when values change, triggering re-render

---

### ProCore

**Functions**: 5,888

ProCore is a **shared utility framework** used by both Motion and Final Cut Pro. It provides foundational types, math utilities, color space operations, and caption support.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `PCMotionBundle` | 154 | Reads and manages Motion template bundles (`.motn`, `.moef`, `.motr`, `.moti`). |
| `PCMatrix44Double` | 55 | 4×4 double-precision matrix for 3D transforms. |
| `PCChangeLog` | 49 | Tracks changes for undo/sync. |
| `PCHMDRender` | 43 | Head-mounted display rendering (Apple Vision Pro). |
| `PCApp` | 37 | Application-level utilities. |
| `PCMapLocation` | 26 | Geographic location for map-based generators. |
| `PCCaption` | 26 | Caption data model. |
| `PCSRTCaptionsImporter` | 20 | SRT subtitle file importer. |
| `PCCaptionCEA608` | 20 | CEA-608 closed caption support. |
| `PCCaptioniTT` | 18 | iTT (iTunes Timed Text) caption format. |
| `PCMotionProjectXMLParser` | 22 | Parses Motion project XML files. |
| `PCVersionedFilename` | 17 | Handles versioned file naming. |
| `HMDFramerate` | 11 | Frame rate handling for VR/spatial content. |
| `FigTimeRangeObj` / `FigTimePairObj` / `FigTimeObj` | — | Time range and time value wrappers around CMTime. |

---

### MIO

**Functions**: 3,444

MIO (**Media I/O**) handles all **media ingestion, device communication, and codec access**. It manages tape-based capture, file-based import from camera cards (P2, XDCAM, AVCHD), direct device connections (Thunderbolt, USB), and PTP (Picture Transfer Protocol) device downloads.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `MIORADClip` | 194 | A clip from a RAD (Random Access Device) volume — camera card or archive. |
| `MIOInputSubSegment` | 143 | Sub-segment of an input stream (e.g., a portion of a tape capture). |
| `MIODeviceConnection` | 100 | Manages connection to a capture/playback device. |
| `MIOAVFInputFrameProcessor` | 97 | Processes input frames via AVFoundation. |
| `MIORADClipDataSourceContainer` | 96 | Data source for browsing clips on a RAD volume. |
| `MIOInputDevice` | 95 | A connected input device (camera, deck). |
| `MIORADSpannedClip` | 88 | A clip that spans multiple volumes/cards. |
| `MIODeck` | 67 | Tape deck control (transport, timecode). |
| `MIOCaptureCore` | 67 | Core capture engine. |
| `MIORADCore` | 61 | Core RAD volume access. |
| `MIOAssetImportQueue` | 58 | Queues media for background import/transcode. |
| `MIORADVolume` | 57 | A mounted camera card/archive volume. |
| `MIORADManager` | 55 | Manages all connected RAD volumes. |
| `MIOTimecode` | 51 | Timecode reading/conversion. |
| `MIOPTPDownloadQueue` | 41 | PTP device download queue (for direct camera connection). |
| `MIODeviceManager` | 45 | Enumerates and manages all connected devices. |
| `MIOHALDevice` | 31 | CoreMediaIO HAL (Hardware Abstraction Layer) device. |
| `MIOOutputDevice` | 21 | A/V output device for monitoring. |
| `MIOOutputFrameProcessor` | 35 | Processes frames for output to external devices. |
| `MIOAudioChannel` | 21 | Audio channel mapping for import. |
| `MIORADPluginManager` | 18 | Manages RAD codec plugins. |
| `MIOOP1aReader` | 28 | OP1a MXF file reader. |

---

### AudioMixEngine

**Functions**: 1,951

AudioMixEngine handles **real-time audio mixing, routing, and processing**. It is embedded within the Ozone framework and manages the audio render pipeline for both FCP and Motion.

Despite having no ObjC classes exposed (all C/C++ implementation), it provides:

- Multi-channel audio mixing and bus routing
- Sample rate conversion
- Audio level metering
- Surround sound panning (including spatial audio)
- Audio effect chain processing
- Real-time audio monitoring output

---

### FxPlug

**Functions**: 1,635

FxPlug is Apple's **plugin architecture** for image processing effects in Final Cut Pro and Motion. Third-party developers use the FxPlug SDK to create filters, generators, and transitions.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `FxRemoteParameterHandler` | 91 | Handles parameter values for out-of-process plugins. |
| `FxAPIManagerShim` | 90 | API compatibility shim between plugin versions. |
| `FxRemotePluginCoordinator` | 77 | Coordinates XPC communication with sandboxed plugin processes. |
| `FxImage` | 61 | Image data passed to/from plugins. |
| `FxImageTile` | 35 | A tile of image data for tiled rendering. |
| `FxRemoteTiming` | 34 | Timing/sync data for remote plugins. |
| `FxParameterTransaction` | 30 | Batched parameter read/write transaction. |
| `FxPrincipal` | 30 | Plugin principal class loader. |
| `FxRemotePlugin` | 23 | Proxy for an out-of-process plugin instance. |
| `FxBitmap` | 19 | CPU-backed bitmap for plugin I/O. |
| `FxTexture` | 19 | GPU texture for Metal/OpenGL plugin rendering. |
| `FxMatrix44` | 19 | 4×4 transform matrix for 3D effects. |
| `FxServiceViewController` | 17 | UI view controller for plugin settings. |

**Plugin isolation model:**

FxPlug 4+ plugins run in **sandboxed XPC service processes**. This means:
- Plugin crashes don't crash Final Cut Pro
- Plugins have restricted file system access
- GPU resources are shared via IOSurface
- Parameter values are serialized across process boundaries

---

### ProAppsFxSupport

**Functions**: 5,344

ProAppsFxSupport provides **built-in effect implementations, LUT management, and color correction UI components**. It bridges between Flexo's effect model and the FxPlug rendering system.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `PAECurve` | 179 | Bezier curve editor for color curves, custom LUTs, and parameter remapping. |
| `PAEColorWheel` | 148 | Color wheel control (Color Board, Color Wheels interface). |
| `PAETileableXPCPlugIn` | 134 | Manages tiled rendering of XPC-hosted effects. |
| `PAEColorQualifier` | 78 | Hue/saturation/luma qualifier for secondary color correction. |
| `PAEAngleOSC` | 52 | Angle/rotation on-screen control. |
| `FxPlugAPIHandler` | 46 | Handles FxPlug API calls from the host side. |
| `PAEFxTransactionProcessor` | 46 | Processes batched effect parameter transactions. |
| `PAELUTRepositoryController` | 43 | Manages the LUT library (import, organize, apply custom LUTs). |
| `PAERepository` | 38 | Base repository for effect presets and LUTs. |

**Embedded resources:**

- Noise textures (Blue, Gaussian, Pink, TV Static, White) in TIFF format — used by noise generators and film grain effects
- Effect preset definitions

---

## Machine Learning Frameworks

Final Cut Pro 10.8+ introduced substantial on-device machine learning capabilities. These frameworks work together to provide semantic search, object tracking, background matting, color neutralization, auto-cropping, and music analysis — all running locally via CoreML and the Apple Neural Engine.

### VAML

**Functions**: 1,926 — **Visual/Audio Machine Learning**

VAML is the ML framework that powers FCP's **semantic search** ("Find People," "Find blue sky," natural-language clip search) and **ML-powered image analysis** (color neutralization, background matting, auto-cropping).

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `VAMLConnectedComponent` | 49 | Connected component analysis for segmentation |
| `VAMLColorNeutralizerResults` | 41 | Results from color neutralization analysis |
| `VAMLAutoCrop` | 35 | Automatic content-aware cropping |
| `VAMLSearchContext` | 17 | Main search context — manages visual and transcription search indexes |
| `VAMLVisualSearchAnalyzer` | 10 | Analyzes video frames to generate visual embeddings |
| `VAMLTranscriptionSearchAnalyzer` | 6 | Generates text embeddings from transcription data |
| `VAMLColorNeutralizerFactory` | 21 | Creates color neutralizer instances for different color spaces |
| `VAMLVideoEncoder` | 17 | Encodes video frames into embedding vectors |
| `VAMLTextEncoder` | 17 | Encodes text queries into embedding vectors |
| `VAMLSearchSafetyClassifier` | 17 | Safety classifier to filter inappropriate search queries |
| `VAMLSearchCalibrator` | 17 | Calibrates search scores for relevance ranking |
| `VAMLBackgroundMatting` | 16 | Generates background/foreground mattes from video |
| `VAMLBackgroundMattingModel` | 17 | CoreML model for background matting |
| `VAMLAutoCropModel` | 17 | CoreML model for auto-crop boundary detection |
| `VAMLPixelBufferContainer` | 17 | Efficient pixel buffer management for ML inference |
| `VAMLColorNeutralizerPixelConverter` | 16 | Pixel format conversion for color neutralizer input |

**Color neutralizer models** (separate CoreML models for each color space):

| Model Class | Target |
|-------------|--------|
| `VAMLColorNeutralizer_709_SDRModel` | Rec. 709 SDR content |
| `VAMLColorNeutralizer_2020_HDRModel` | Rec. 2020 HDR content |
| `VAMLColorNeutralizer_2020_SDRModel` | Rec. 2020 SDR content |
| `VAMLColorNeutralizer_2020PQ1k_HDRModel` | Rec. 2020 PQ 1000-nit HDR content |

**Search pipeline:**

1. **Indexing**: `VAMLVisualSearchAnalyzer` processes video frames through `VAMLVideoEncoder` to produce embedding vectors, which are stored in a USearch index.
2. **Query**: User text is encoded by `VAMLTextEncoder` via a SentencePiece tokenizer, then compared against the visual index using cosine similarity.
3. **Safety**: `VAMLSearchSafetyClassifier` filters queries before execution.
4. **Calibration**: `VAMLSearchCalibrator` adjusts raw scores into calibrated relevance scores.
5. **Results**: Matched clips are returned to Flexo's `FFVAMLSearchContext` for display in the browser.

---

### VAMLSentencePiece

**Functions**: 3,029

A wrapper around Google's **SentencePiece** tokenization library. Provides the `SentencePieceModel` class (4 methods) that tokenizes natural-language search queries into subword tokens for the VAML text encoder.

---

### USearch

**Functions**: 590

**USearch** is a high-performance **vector similarity search** library. FCP uses it to build and query indexes of visual and text embeddings generated by VAML.

**Key class:**

| Class | Methods | Role |
|-------|---------|------|
| `USearchIndex` | 27 | Vector index — add embeddings, search by similarity, save/load to disk |

USearch enables sub-millisecond nearest-neighbor lookup across thousands of clip embeddings, making the semantic search feel instantaneous.

---

### ProTracker

**Functions**: 2,914

ProTracker provides **ML-powered object tracking, segmentation, and face detection** using transformer-based neural networks running on the Apple Neural Engine.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `OZCorrelationTrackerOSC` | 39 | On-screen tracking controls using correlation-based tracking |
| `VideoSegmentation` | 36 | Video segmentation pipeline — generates per-frame masks |
| `OZObjectTrackerOSC` | 35 | On-screen controls for object tracking |
| `OZTrackerOSCAPI` | 29 | API for tracker on-screen controls |
| `OZClassifyBoundingBox` | 24 | Classifies detected bounding boxes |
| `OZTapToBoundingBox` | 18 | Tap-to-track: converts a user tap to a bounding box |
| `OZTapToSegmentation` | 12 | Tap-to-segment: one-click subject segmentation |
| `tracker_ANE` | 15 | ANE (Apple Neural Engine) tracker model |
| `tracker_ANEInput` | 17 | Input tensor preparation for ANE tracker |
| `template_ANE` | 15 | Template matching model for ANE |
| `TransformerTrackerMPS` | 13 | Metal Performance Shaders implementation of transformer tracker |
| `TransformerTracker` | 7 | High-level transformer tracker interface |
| `TransformerTrackerUtilities` | 6 | Utility functions (crop, resize, extend, normalize) |
| `model_tap_to_box_v2p1` | 15 | Tap-to-bounding-box CoreML model (v2.1) |
| `segmentationModelv2_0` | 15 | Segmentation CoreML model (v2.0) |
| `OZRecognizedObjectObservation` | 9 | A recognized object detection result |
| `OZTap2DetectObservation` | 7 | A tap-to-detect observation |
| `VNFaceObservation` | 7 | Face detection result (wrapping Vision framework) |

**Tracking pipeline:**

1. User taps an object → `OZTapToBoundingBox` converts the tap point into a bounding box using `model_tap_to_box_v2p1`
2. `TransformerTracker` initializes a template from the bounding box region
3. Frame-by-frame tracking uses `tracker_ANE` on the Neural Engine with `template_ANE` for reference matching
4. `TransformerTrackerMPS` provides a Metal fallback for non-ANE devices
5. `VideoSegmentation` generates per-frame segmentation masks using `segmentationModelv2_0`
6. Tracked data feeds into Flexo's `FFTrackerManager` for keyframe generation

---

### MusicUnderstandingEmbedded

**Functions**: 5,538

An on-device **music analysis** framework that provides beat detection, instrument activity recognition, and structural feature extraction.

**Key classes (Swift):**

| Class | Role |
|-------|------|
| `DownbeatTrackerInput` / `DownbeatTrackerOutput` | Beat/downbeat detection model I/O |
| `InstrumentActivityInput` / `InstrumentActivityOutput` | Instrument classification model I/O |
| `StructuralFeaturesInput` / `StructuralFeaturesOutput` | Music structure analysis (verse, chorus, bridge) |

This framework powers:
- **Beat markers** — automatic placement of markers on musical beats
- **Smart music editing** — cutting to beat boundaries
- **Beat detection grid** in the timeline

---

## Rendering & Graphics Frameworks

### ProGL

**Functions**: 1,293

ProGL manages **OpenGL context creation and lifecycle**. Historically it created `NSOpenGLContext` objects for all GPU rendering. On modern Apple Silicon systems, it primarily serves as a compatibility layer — new rendering paths go through Metal, but the OpenGL context infrastructure remains for legacy effects and shaders.

Key class: `PGShutDownRenderQueue` (2 methods) — manages orderly shutdown of render queues.

---

### ProGraphics

**Functions**: 1,058

A shared graphics utility framework between Motion and Final Cut Pro. Provides common graphics operations, color space helpers, and image processing primitives. Primarily C/C++ implementation with minimal ObjC surface area.

---

### MDPKit

**Functions**: 1,221 — **Metal Drawing Primitives**

MDPKit is the **GPU-accelerated 2D drawing framework** that renders timeline elements, waveforms, curves, and UI overlays using Metal.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `MDPMultiline` | 59 | Renders multi-segment line paths (waveforms, curves) |
| `MDPLine` | 54 | Single line drawing |
| `MDPQuadTexture` | 42 | Textured quad rendering |
| `MDPScreenspaceTexture` | 41 | Screen-space textured elements |
| `MDPArc` | 41 | Arc/circular drawing |
| `MDPRenderController` | 36 | Central render controller for all drawing operations |
| `MDPSubmesh` | 31 | Mesh subdivision |
| `MDPMesh` | 30 | General mesh rendering |
| `MDPCompositeView` | 27 | Composited view rendering |
| `MDPMetalDrawPrimitive` | 27 | Base Metal draw primitive |
| `MDPText` | 26 | GPU-rendered text |
| `MetalDrawingView` | 19 | NSView subclass backed by Metal for hardware-accelerated drawing |
| `MDPRenderingContext` | 24 | Per-frame render context |
| `MDPBrush` | 15 | Brush stroke rendering |
| `MDPRenderPipelineStateCache` | 8 | Caches compiled Metal pipeline states |
| `MDPSamplerStateCache` | 11 | Caches Metal sampler states |

MDPKit replaced the older CoreGraphics-based drawing path for timeline rendering, providing significantly better performance for complex timelines with hundreds of clips.

---

### ProOSC

**Functions**: 2,583

ProOSC (**On-Screen Controls**) implements all **direct-manipulation controls** that appear over the viewer — handles, bounding boxes, transform gizmos, crop corners, distortion points, motion paths, and mask controls.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `POMotionPathBase` | 140 | Base class for motion path on-screen controls |
| `POOnScreenControl` | 96 | Abstract base for all on-screen controls |
| `OZRotoshapeOnscreenControl` | 93 | Rotoscoping/mask shape controls (Bézier paths) |
| `POCombinedCrop` | 59 | Combined crop/trim rectangle control |
| `OZTransformOSC` | 55 | 2D transform controls (position, scale, rotation) |
| `OZShapeOSC` | 47 | Shape manipulation controls |
| `PODistort` | 26 | Four-corner distortion control |
| `POAnimationPath` | 24 | Keyframe animation path visualization |
| `POColorIsolation` | 15 | Color isolation (hue/sat/luma qualifier) on-screen control |
| `POPivot` | 19 | Anchor point/pivot control |
| `POScale3D` | 17 | 3D scale control |
| `PORotate3D` | 17 | 3D rotation control |
| `POMove3D` | 22 | 3D position control |

**GLSL shaders (legacy, transitioning to Metal):**

| Shader | Purpose |
|--------|---------|
| `GammaLineFragment.glsl` | Gamma-correct line rendering |
| `RGBBackgroundFragment.glsl` / `RGBForegroundFragment.glsl` | RGB overlay rendering |
| `RGBMaskFillBackgroundFragment.glsl` / `RGBMaskFillForegroundFragment.glsl` | Mask fill overlays |
| `ShapeDashFragment.glsl` / `ShapeDashVertex.glsl` | Dashed line rendering for shapes |
| `ShapeSmoothFragment.glsl` / `ShapeSmoothVertex.glsl` | Anti-aliased smooth shape rendering |

---

### ProShapes

**Functions**: 1,417

ProShapes implements **vector shape editing** — rectangles, ellipses, super-ellipses, Bézier paths, and vertex manipulation used by Motion's shape tools and FCP's mask editors.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `OZVertexPosition3DController` | 21 | 3D vertex position editing |
| `OZShapeVertexController` | 18 | Individual vertex control |
| `OZVertex2DController` | 14 | 2D vertex editing |
| `OZVerticesController` | 12 | Manages a collection of vertices |
| `CHChannelShape` | 3 | Channel type for shape data |

Uses Metal 1.0+ and the Helium renderer for GPU-accelerated shape rasterization.

---

### ProCurveEditor

**Functions**: 1,310

Provides the **keyframe curve editor** used in both the Video Animation editor and the standalone keyframe editor. Referenced through Ozone's `OZCurveEditorCtrl` (136 methods), `OZCurveEditorCtrlBase` (139), `OZCurveEditorViewBase` (169), and `OZCurveEditorChannelItem` (58).

---

### Stalgo

**Functions**: 774

**STALGO** (Straight Skeleton Algorithm) is an industrial-strength C++ library for computing **straight skeletons and mitered offset-curves**. In FCP/Motion context, it's used for:

- Generating offset paths for text outlines
- Computing mitered corners for shape strokes
- Geometric operations on vector paths

The library is pure C++ with no ObjC classes.

---

## UI & Inspector Frameworks

### LunaFoundation

**Functions**: 681

LunaFoundation provides **timecode parsing, formatting, and display** utilities used throughout the application.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `LKVideoTimecode` | 111 | Video-specific timecode (drop-frame, non-drop-frame) |
| `LKTimecodeFormatter` | 93 | Formats timecode for display |
| `LKExtendedTimecode` | 86 | Extended precision timecode |
| `LKTimecode` | 44 | Base timecode type |
| `LKScrubbableNumberFormatter` | 42 | Number formatter that supports drag-to-scrub interaction |

**Format deputies** (specialized formatters):

| Deputy | Format |
|--------|--------|
| `LKSMPTETimecodeFormatDeputy` | SMPTE timecode (HH:MM:SS:FF) |
| `LKMeasuredTimecodeFormatDeputy` | Duration display |
| `LKFFTimecodeFormatDeputy` | Frames-only display |
| `LKHMSTimecodeFormatDeputy` | Hours:Minutes:Seconds |
| `LKOneDTimeTimecodeFormatDeputy` | Seconds with decimal |
| `LKOneDFramesTimecodeFormatDeputy` | Frame count |

---

### ProInspector

**Functions**: 1,946

ProInspector implements the **inspector panel UI** — the property editor that appears in the right sidebar. It dynamically generates UI from the ProChannel channel tree.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `OZViewController` | 131 | Base view controller for inspector sections |
| `PIBuildContext` | 123 | Builds inspector UI from channel descriptions |
| `OZViewControllerGroup` | 120 | Groups related inspector controllers |
| `OZFlippedView` | 101 | Flipped-coordinate view (top-left origin) |
| `OZAnimStatusCell` | 78 | Keyframe animation status indicator |
| `OZChan3DController` | 38 | 3D channel editor (x, y, z fields) |
| `OZChanDoubleController` | 34 | Double-precision value editor |
| `OZChan2DController` | 34 | 2D channel editor |
| `OZChanEnumController` | 27 | Dropdown/enum editor |
| `OZChanFolderController` | 28 | Expandable folder group |
| `OZGradientEditor` | 25 | Gradient parameter editor |
| `PIMapLocationPickerViewController` | 33 | Map location picker (for map generators/titles) |

---

### ProInspectorFoundation

**Functions**: 27

Minimal base types for the inspector system.

---

### StudioSharedResources

**Functions**: 15

A resource-only framework containing **shared UI images and assets** used by both Motion and Final Cut Pro. Provides common icons, symbols, and graphics.

---

## Media & Export Frameworks

### ProMedia

**Functions**: 2,502

ProMedia handles **advanced media format support**, including RAW image processing (ProRes RAW, RED RAW, Blackmagic RAW), OpenEXR, and Metal-accelerated decoding.

Key class: `PMCachedBitmapObject` (3 methods) — cached bitmap for decoded media frames.

Uses Metal 1.0+ for GPU-accelerated RAW processing.

---

### ProMediaLibrary

**Functions**: 1,115

Provides **media library organization** functionality.

Key class: `LibraryOrganizer` (Swift, 2 methods) — organizes media within libraries.

---

### MXFExportSDK

**Functions**: 3,377

Implements **MXF (Material Exchange Format) export** for professional broadcast delivery.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `IMPCompositionPlaylist` | 52 | IMF Composition Playlist generation |
| `IMPCPLToFileWriter` | 22 | Writes CPL to file |
| `MXFFileWriter` | 17 | Low-level MXF file writing |
| `CPMExportTrack` | 12 | Individual export track (video/audio) |
| `IMPAssetDecoder` | 5 | Decodes assets for MXF wrapping |

The MXF export pipeline generates broadcast-standard MXF files with proper OP1a structure, essential for broadcast delivery workflows.

---

### XMLCodable

**Functions**: 1,167

A **Swift XML parsing and encoding** library used by the Interchange framework for FCPXML processing.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `IXXMLParserElement` | 39 | Parsed XML element |
| `IXXMLParserDocument` | 17 | Parsed XML document |
| `IXXMLParserHeader` | 13 | XML declaration header |
| `IXXMLParserAttribute` | 10 | XML attribute |
| `XMLTreeParser` | 7 | Tree-based XML parser |
| `IXElementContext` | 5 | Parsing context for element processing |

---

## Cloud & Services Frameworks

### CloudContent

**Functions**: 11,382

CloudContent manages **downloadable content from Apple's servers** — titles, effects, transitions, sound effects, music, and other creative assets that can be installed on-demand.

**Key classes (Swift):**

| Class | Methods | Role |
|-------|---------|------|
| `CCAsset` | 38 | A downloadable content asset |
| `CCMetadataTag` | 25 | Metadata tagging for content |
| `CCFlexMusicStyle` | 22 | Flex music style definition |
| `CCContentType` | 22 | Content type classification |
| `CCClipsLabelItem` | 22 | Label for Clips-compatible content |
| `CCLabelItem` | 22 | General content label |
| `CCContentTag` | 20 | Content discovery tag |
| `CCStyleItem` | 18 | Style preset |
| `CCTitleEffectItem` | 17 | Title effect content |
| `CCFilterEffectType` | 16 | Filter effect category |
| `CCClipsPosterItem` / `CCPosterItem` | 15 | Poster frame content |
| `CCFinalCutAppFlexMusicItem` | 14 | FCP-specific flex music |
| `CCiMovieFlexMusicItem` | 15 | iMovie-specific flex music |
| `CCDownloadProgress` | 8 | Download progress tracking |
| `CCNotification` | 10 | Content update notifications |
| `Catalog` | 10 | Content catalog management |
| `CCSupportedMediaPairs` | 9 | Supported media format pairs |

---

### PMLCloudContent

**Functions**: 1,549

Bridges CloudContent into the **Pro Media Library** system.

**Key classes (Swift):**

| Class | Methods | Role |
|-------|---------|------|
| `CloudContentFlexMusicProvider` | 6 | Provides flex music from cloud content |
| `CloudContentLibraryManager` | 5 | Manages cloud content library integration |

---

### AppleMediaServicesKit

**Functions**: 10,404

Apple's **media services SDK** (AMSC — Apple Media Services Client). Handles App Store integration, receipt validation, content licensing, and in-app purchase verification.

Key class prefix: `AMSCB2P` — "Apple Media Services Client Bridge to Platform"

This framework manages:
- App Store receipt validation
- Content entitlement checks
- HTTP request/response handling for Apple services
- Bag policies and endpoint configuration
- Media token management
- Privacy/consent flows

---

### EmbeddedRemoteConfiguration

**Functions**: 1,470

A **feature flag and remote configuration** system that allows Apple to enable/disable features, configure thresholds, and manage A/B testing without app updates.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `RCEConfigurationSettings` | 128 | Configuration settings store |
| `RCEConfigurationManager` | 54 | Manages configuration lifecycle |
| `RCEConfigurationResource` | 44 | A single configuration resource |
| `RCEKeyValueStore` | 66 | Key-value persistence |
| `RCEURLFetchOperation` | 55 | Fetches configuration from Apple servers |
| `RCEDeviceInfo` | 25 | Device capability information |
| `RCEUserSegmentationConfiguration` | 17 | User segment targeting |
| `RCEBackgroundFetchConfiguration` | 20 | Background refresh settings |
| `RCEDebugOverrides` | 17 | Debug/development overrides |

---

## Application Support Frameworks

### ProAppSupport

**Functions**: 824

Provides **application identity, logging, and shared constants** across the Pro Apps suite.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `PASLogCategory` | 29 | Structured logging categories |
| `PASAppIdentity` | 27 | Application identification |
| `PASAppInfo` | 10 | Application metadata |
| `PASApp` | 9 | App-level utilities |
| `PASLog` | 8 | Logging infrastructure |

**App identity classes** — factory pattern producing specific identities:

- `FinalCutProIdentity` (5 methods)
- `MotionIdentity` (5 methods)
- `CompressorIdentity` (7 methods)
- `IMovieIdentity` (4 methods)

---

### ProOnboardingFlowModelOne

**Functions**: 2,712

Manages the **purchase, trial, and onboarding flow** for Final Cut Pro.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `POFStoreManagerAdapter` | 17 | App Store integration adapter |
| `POFOnboardingConfiguration` | 14 | Onboarding flow configuration |
| `POFDesktopOnboardingCoordinator` | 14 | Coordinates the onboarding UI sequence |
| `POFBypassPurchaseStorage` | 10 | Trial/bypass purchase state |
| `POFOnboardingEventController` | 10 | Tracks onboarding events |
| `PurchasingViewModel` | 2 | SwiftUI view model for purchase UI |
| `ReceiptValidator` | 2 | App Store receipt validation |
| `ReceiptParser` | 1 | Receipt data parsing |
| `ReceiptDeviceHashValidator` | 1 | Device-specific receipt verification |
| `POFPrivacyAcknowledgementGate` | 3 | Privacy consent gate |

---

### AppAnalytics

**Functions**: 7,102

Apple's **analytics and telemetry** framework for tracking usage patterns, feature adoption, and performance metrics.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `AATracker` | 58 | Main analytics tracker |
| `AAAccessTracker` | 31 | Feature access tracking |
| `AASessionManager` | 25 | Analytics session lifecycle |
| `AATrackingConsent` | 12 | User consent management |
| `AAClient` | 11 | Analytics data transmission |
| `AATimestampJitter` | 9 | Timestamp privacy jitter |
| `AAPrivacyValidation` | 7 | Validates data against privacy requirements |
| `AADiagnosticsConsentProvider` | 7 | Diagnostics sharing consent |

Analytics data is subject to differential privacy (timestamp jitter, aggregation) and requires user consent.

---

### SwiftASN1

**Functions**: 1,330

A Swift implementation of **ASN.1 (Abstract Syntax Notation One)** encoding/decoding. Used for **App Store receipt parsing and validation** — receipts use PKCS#7/CMS format which requires ASN.1 parsing.

---

### RetimingMath

**Functions**: 372

A **C++ template library** for retiming calculations. Provides interval set mathematics (`IntervalSet<T>`), time mapping functions, and speed ramp computations. Used by Ozone's `OZOpticalFlow::Private::MotionEstimator` and Flexo's `FFRetimingEffect`.

---

### AudioEffects

**Functions**: 906

Implements **built-in audio effects** (EQ, compression, noise reduction, etc.). Pure C/C++ implementation with no ObjC classes.

---

### CoreAudioSDK

**Functions**: 652

Wrapper around Apple's **Core Audio** framework. Provides audio unit hosting, sample rate management, and audio device enumeration.

---

### PMLUtilities

**Functions**: 317

General utility functions for the Pro Media Library.

---

## Extension System

Final Cut Pro uses Apple's extension architecture for modularity and third-party integration.

### ProExtension

**Functions**: 280

Base framework defining the **extension protocol and registration**.

Key class: `PXRegisterProExtension` (10 methods) — registers extensions with the host.

### ProExtensionHost

**Functions**: 140

**Hosts extensions** within the FCP process.

Key class: `PXProExtensionHost` (22 methods) — manages extension lifecycle, discovery, and communication.

### ProExtensionSupport

**Functions**: 426

Provides **Compressor integration and analysis extension support**.

**Key classes:**

| Class | Methods | Role |
|-------|---------|------|
| `ProCompressorEncoderHostContext` | 62 | Hosts Compressor encoder extensions |
| `ProAnalysisHostContext` | 32 | Hosts analysis extensions (e.g., third-party media analysis) |
| `PXProServiceExtension` | 25 | Base class for service extensions |
| `PXProServicePlugin` | 18 | Plugin wrapper for service extensions |
| `ProCompressorEncoderExtension` | 12 | Compressor encoder extension interface |
| `ProCompressorEncoderHostViewController` | 14 | UI for Compressor encoder settings |

### ProService

**Functions**: 41

Minimal service protocol definitions.

### ProViewServiceSupport

**Functions**: 32

Support for view-based service extensions (remote view hosting).

---

## Plugins

### FCP-DAL

Contains `ACD.plugin` — a **CoreMediaIO Device Abstraction Layer** plugin that enables the "A/V Output" feature in Final Cut Pro (sending video to external monitors via Thunderbolt, HDMI, or SDI devices).

The CoreMediaIO DAL is analogous to Core Audio's HAL (Hardware Abstraction Layer). Just as the HAL handles audio streams from audio hardware, the DAL manages video and muxed streams from video devices.

### FxPlug Plugins

Located in the `FxPlug/` directory:

| Plugin | Purpose |
|--------|---------|
| `FiltersLegacyPath.bundle` | Legacy filter implementations (including Primatte keyer) still used by Motion and FCP |
| `PAECIAdaptor.fxplug` | Core Image adaptor — wraps CIFilter-based effects in the FxPlug interface |

### RADPlugins

**RAD (Random Access Device)** plugins provide codec and container format support for professional camera formats:

| Plugin | Format |
|--------|--------|
| `Archive.RADPlug` | Archive/backup volumes |
| `AVCHD.RADPlug` | AVCHD (Sony, Panasonic, Canon consumer cameras) |
| `MPEG2.RADPlug` | MPEG-2 transport/program streams |
| `MPEG4.RADPlug` | MPEG-4/H.264 containers |
| `P2.RADPlug` | Panasonic P2 (AVC-Intra, DVCPRO HD) |
| `P2AVF.RADPlug` | Panasonic P2 via AVFoundation |
| `XDCAM.RADPlug` | Sony XDCAM (disc-based) |
| `XDCAMFormat.RADPlug` | Sony XDCAM format definitions |

These plugins are managed by `MIORADPluginManager` in the MIO framework.

### InternalFiltersXPC

`InternalFiltersXPC.pluginkit` — Internal filters running in a sandboxed **XPC service process** for crash isolation. These are the built-in video effects that benefit from out-of-process execution.

### MediaProviders

`MotionEffect.fxp` — Contains Motion particle images, material textures, and text style presets used by Motion-based effects and titles within FCP.

### CompressorKit

`CompressorKit.bundle` — The **Compressor encoding engine**, also found in Compressor.app and Motion. Provides hardware-accelerated encoding to ProRes, H.264, H.265/HEVC, and other formats.

---

## Key Class Reference

### Application Controller

| Class | Binary | Methods | Description |
|-------|--------|---------|-------------|
| `PEAppController` | Final Cut Pro | 489 | Top-level app controller. Manages menus, windows, preferences, and global state. |
| `PEDocument` | Final Cut Pro | 58 | Document model. Library file reference and lifecycle management. |
| `PEMainWindowModule` | Final Cut Pro | 69 | Main window layout and toolbar. |
| `PESelectionManager` | Final Cut Pro | 24 | Cross-panel selection tracking. |
| `FFWorkspace` | Flexo | 57 | Workspace layout presets (Default, Organize, Color & Effects). |
| `LKModuleLayoutManager` | LunaKit | 188 | Module arrangement engine. |
| `LKCommandsController` | LunaKit | 82 | Keyboard shortcut management. |

### Timeline & Editing

| Class | Binary | Methods | Description |
|-------|--------|---------|-------------|
| `FFAnchoredTimelineModule` | Flexo | 1,442 | **All editing operations.** Blade, trim, insert, overwrite, markers, speed changes, etc. |
| `FFAnchoredSequence` | Flexo | 1,148 | Timeline data model. Contains the primary storyline and all connected items. |
| `FFAnchoredObject` | Flexo | 914 | Base class for all timeline items. |
| `FFAnchoredCollection` | Flexo | 298 | Collection of anchored items (primary storyline, compound clip contents). |
| `FFAnchoredMediaComponent` | Flexo | 128 | A video or audio clip in the timeline. |
| `FFAnchoredTransition` | Flexo | 81 | A transition between clips. |
| `FFAnchoredStack` | Flexo | 227 | Stacked items (auditions, connected clips). |
| `FFAnchoredAngle` | Flexo | 80 | A multicam angle. |
| `FFAnchoredCaption` | Flexo | 93 | A caption/subtitle item. |
| `FFAnchoredTimeMarker` | Flexo | 49 | A marker (standard, to-do, chapter). |
| `FFAnchoredClip` | Flexo | 48 | A clip reference. |
| `FFStoryTimelinePresentation` | Flexo | 139 | Presentation layer between data model and timeline view. |
| `TLKTimelineView` | TimelineKit | 670 | Timeline visual rendering and interaction. |
| `TLKEventDispatcher` | TimelineKit | 176 | User interaction → editing action translation. |
| `TLKLayoutManager` | TimelineKit | 130 | Timeline layout computation. |
| `TLKPlayhead` | TimelineKit | 57 | Playhead position and rendering. |
| `TLKSelectionManager` | TimelineKit | 48 | Timeline selection state. |
| `FFUndoHandler` | Flexo | 54 | Undo/redo via FFUndoManager. |
| `FFPasteboard` | Flexo | 76 | Copy/paste operations. |

### Library & Media Management

| Class | Binary | Methods | Description |
|-------|--------|---------|-------------|
| `FFLibrary` | Flexo | 239 | An FCP library (`.fcpbundle`). |
| `FFLibraryDocument` | Flexo | 277 | Library document controller. Manages open/close, auto-save. |
| `FFLibraryItem` | Flexo | 100 | Base class for items within a library. |
| `FFLibraryContainer` | Flexo | 84 | Container within a library (event, folder). |
| `FFMediaEventProject` | Flexo | 258 | A project within an event. |
| `FFMediaEventFolder` | Flexo | 84 | A folder within an event. |
| `FFMediaEventSmartCollection` | Flexo | 70 | A smart collection with filter criteria. |
| `FFAsset` | Flexo | 373 | A media asset (source file reference). |
| `FFMedia` | Flexo | 136 | Media data representation. |
| `FFMediaRef` | Flexo | 58 | Reference to media on disk. |
| `FFMediaRep` | Flexo | 176 | A specific representation (resolution/format) of media. |
| `FFRole` | Flexo | 103 | An audio or video role. |
| `FFKeywordEditor` | Flexo | 84 | Keyword management. |
| `FFOrganizerFilmstripModule` | Flexo | 640 | Browser filmstrip view. |

### Effects & Color

| Class | Binary | Methods | Description |
|-------|--------|---------|-------------|
| `FFEffect` | Flexo | 522 | Base effect class. |
| `FFEffectStack` | Flexo | 481 | Stack of effects applied to a clip. |
| `FFHeColorEffect` | Flexo | 142 | Helium-rendered color effect. |
| `FFColorSecondaryEffect` | Flexo | 68 | Secondary color correction. |
| `FFBalanceColorBaseEffect` | Flexo | 58 | Auto balance color. |
| `FFIntrinsicColorConformEffect` | Flexo | 53 | Color space conforming. |
| `FFHeCinematicEffect` | Flexo | 83 | Cinematic mode depth editing. |
| `FFSegmentationMask` | Flexo | 94 | ML-powered segmentation mask (Magnetic Mask). |
| `FFIsolationMask` | Flexo | 74 | Color-based isolation mask. |
| `FFMaskedEffectBase` | Flexo | 100 | Base for effects that use masks. |
| `FFStabilizationEffect` | Flexo | 76 | Video stabilization. |
| `FFNoiseReduction` | Flexo | 58 | Noise reduction (spatial + temporal). |
| `FFRetimingEffect` | Flexo | 106 | Speed/retiming effect. |
| `FFRollingShutterEffect` | Flexo | 55 | Rolling shutter correction. |
| `FFMicaTitle` | Flexo | 75 | Mica title system (animated titles). |
| `PAEColorWheel` | ProAppsFxSupport | 148 | Color wheel UI control. |
| `PAEColorQualifier` | ProAppsFxSupport | 78 | HSL qualifier for color isolation. |
| `PAECurve` | ProAppsFxSupport | 179 | Curve editor for color grading. |
| `PAELUTRepositoryController` | ProAppsFxSupport | 43 | Custom LUT management. |

### Playback & Rendering

| Class | Binary | Methods | Description |
|-------|--------|---------|-------------|
| `FFPlayer` | Flexo | 251 | Core playback engine. |
| `FFPlayerVideoModule` | Flexo | 379 | Video playback module. |
| `FFPlayerModule` | Flexo | 193 | Player module coordinator. |
| `FFPlayerScheduledData` | Flexo | 171 | Scheduled render/decode data for playback. |
| `FFRenderer` | Flexo | 45 | Render coordinator. |
| `FFBackgroundRenderManager` | Flexo | 50 | Background render task management. |
| `FFScheduleTokenVTDecode` | Flexo | 87 | VideoToolbox decode scheduling. |
| `FFDestVideo` | Flexo | 62 | Video output destination. |
| `FFDestVideoDisplay` | Flexo | 78 | On-screen video display. |
| `FFDestVideoCMIO` | Flexo | 51 | CoreMediaIO video output (external monitors). |
| `FFHGRendererManager` | Flexo | 45 | Helium GPU renderer management. |
| `PEPerformanceController` | Final Cut Pro | 24 | Dynamic quality adjustment for real-time playback. |

### Export & Sharing

| Class | Binary | Methods | Description |
|-------|--------|---------|-------------|
| `FFShareDestination` | Flexo | 140 | Export destination definition. |
| `FFShareDestinationExportMediaController` | Flexo | 146 | Media export controller. |
| `FFSharePanel` | Flexo | 96 | Share dialog UI. |
| `FFBaseSharePanel` | Flexo | 150 | Base share panel. |
| `FFBackgroundShareOperation` | Flexo | 62 | Background export operation. |
| `FFDestQTExporter` | Flexo | 55 | QuickTime/ProRes export. |
| `FFXMLExporter` | Flexo | 172 | FCPXML export. |
| `FFXMLImporter` | Flexo | 302 | FCPXML import. |
| `FFSequenceSettingsExporter` | Flexo | 51 | Project settings export. |
| `FFMXFWriter` | Flexo | 51 | MXF file writing. |
| `FFTheaterDatabase` | Flexo | 107 | Theater (Apple TV) sharing. |

---

## Data Model

### The Spine Architecture

FCP's timeline is organized around the **spine** — a primary storyline that acts as the structural backbone of a sequence.

```
FFAnchoredSequence
└── primaryObject: FFAnchoredCollection (the spine)
    └── containedItems: [FFAnchoredObject]
        ├── FFAnchoredMediaComponent (video/audio clips)
        ├── FFAnchoredTransition (transitions between clips)
        ├── FFAnchoredStack (compound clips, auditions)
        │   └── containedItems: [FFAnchoredAngle]
        │       └── containedItems: [FFAnchoredMediaComponent]
        ├── FFAnchoredCaption (captions/subtitles)
        └── FFAnchoredTimeMarker (markers)
```

**Connected clips** (B-roll, titles, sound effects) are "anchored" to items in the primary storyline. When the primary storyline item moves, connected clips move with it — this is the core of the "magnetic" behavior.

**Key properties on FFAnchoredObject:**

- `offset` — position within the parent container (CMTime)
- `duration` — clip duration (CMTime)
- `start` — media start time (for trimmed clips)
- `anchoredItems` — array of connected clips
- `effectStack` — the FFEffectStack containing all applied effects

### Core Data Model

FCP libraries (`.fcpbundle`) use **Core Data** for persistent storage. The compiled managed object model (`.momd`) lives in the DeepSkyLite sub-framework of Flexo.

Key entity types (from `_AnchoredObjectRecord` and related classes):

- All timeline items are stored as Core Data entities with their relationships
- `keptStateExtendedData` stores additional state that doesn't fit the standard model
- Library-level metadata (events, smart collections, keywords, ratings) are separate entities
- The Theater database (`FFTheaterDatabase`) uses its own Core Data store, with iCloud sync support

### Undo System

FCP uses a custom undo manager (`FFUndoManager`) rather than the standard `NSUndoManager` responder chain. This is accessed through `FFUndoHandler` (54 methods in Flexo).

The undo system:
- Records timeline edits as invertible operations
- Groups rapid edits (e.g., multi-frame blade operations) into single undo steps
- Integrates with Core Data's change tracking for persistent undo
- Supports undo across multiple editing operations including effects, color, and retiming changes

---

## Historical Context

### Origins (2007–2011)

Final Cut Pro X (now simply "Final Cut Pro") was built from the ground up starting around 2007, drawing on technology from several Apple acquisitions and internal projects:

- **Shake / Nothing Real**: The Helium render engine was developed by the "mad Frenchmen" team in Santa Monica — Arnaud Hervas (co-founder of Nothing Real), Emmanuel Mogenet, and Christophe Souchard. The key innovation was automatic tiled rendering using all available compute resources, handling precision differences between CPU and GPU math. Arnaud is now working on camera alignment software; Emmanuel is an executive at Google Research in Switzerland.

- **Senso Technology**: Acquired from Christophe Souchard, Senso was the first Intel-based library for advanced image scaling and frame-rate conversion using motion vector estimation. At Apple, Souchard introduced methods using partial differential equations for prototype tools 15 years before similar features appeared in competing products. His position was labeled "Applied Magic." He now works at Unity Technologies on AR.

- **Polar Rose**: The face detection technology (`FaceCoreEmbedded`) came from Apple's acquisition of the Swedish company Polar Rose.

- **Randy Ubillos**: The "father of FCP" (and close to Steve Jobs) drove many of the creative decisions. He had a rule that no operation should take longer than one second per frame to render, which shaped the real-time-first philosophy of the application.

### Architecture Evolution

- **10.0–10.3** (2011–2016): Initial release through stabilization. OpenGL-based rendering. Core Data for library persistence. Magnetic timeline introduced.
- **10.4** (2017): HEVC/H.265 support, 360° VR editing, HDR color processing (Rec. 2020/HLG/PQ). Major Helium renderer updates.
- **10.5** (2020): Apple Silicon native support. Metal renderer optimization for M1 GPU architecture.
- **10.6** (2021–2023): Object tracking (`ProTracker`), Cinematic mode editing (`FFHeCinematicEffect`), ProRes RAW, Duplicate Detection (`EDTDupeDetector`), multicam improvements.
- **10.7–10.8** (2023–2024): Magnetic Mask (ML segmentation), semantic visual search (VAML/USearch), spatial video for Apple Vision Pro (`LiPersonDepthWriter`), auto-reframe improvements, MusicUnderstandingEmbedded.
- **11.0+** (2025–2026): Further ML integration, cloud content expansion, Live Drawing, enhanced spatial video workflows, beat detection refinements.

### Shared Framework Heritage

Most frameworks within Final Cut Pro are also found in:
- **Apple Motion** — shares Ozone, Helium, LunaKit, TimelineKit, ProChannel, ProCore, ProOSC, ProShapes, ProInspector, ProCurveEditor, TextFramework, ProGL, ProGraphics, Lithium, AudioMixEngine, Stalgo, FxPlug, and ProAppsFxSupport
- **iMovie (macOS)** — shares Flexo (with consumer-specific code paths), LunaKit, TimelineKit, ProCore, and several other frameworks
- **iMovie (iOS) / Clips (iOS)** — shares some Flexo data model code and media handling
- **Compressor** — shares ProExtensionSupport, CompressorKit, ProCore, and media encoding infrastructure

---

*This document was generated from static analysis of Final Cut Pro's application bundle, decompilation of all 53 embedded binaries (303,662 functions), and runtime introspection via FCPBridge. Class method counts and binary function counts are derived from the decompiled codebase.*
