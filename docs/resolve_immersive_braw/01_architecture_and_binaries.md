# Architecture And Binaries

## What appears to be split where

Resolve's immersive stack is not monolithic. The evidence strongly suggests four distinct layers:

| Layer | Primary binary | What it appears to do |
| --- | --- | --- |
| Raw media ingest and decode | `BlackmagicRawAPI.framework/BlackmagicRawAPI` | Reads immersive BRAW container structures, extracts left/right video and immersive timed metadata, exposes camera geometry and motion surfaces. |
| Immersive metadata, projection, rendering, and streaming | `ImmersiveVideoToolbox.framework/ImmersiveVideoToolbox` | Builds static and dynamic immersive metadata, renders preview projections, generates ST maps, and streams preview frames to Vision Pro peers. |
| App-level product behavior | `Contents/MacOS/Resolve` | Wires immersive project setup, Fusion features, delivery presets, and overall UX. |
| Immersive audio bridge | `libImmersiveAudioBridge.dylib` | Owns ASAF / AIA / APAC / ADM import-export and binaural / object / scene audio infrastructure. |

That split is visible both in the official docs and in the binary surfaces.

## Evidence from binary dependencies

`Resolve` directly links the immersive framework stack:

- `BlackmagicRawAPI.framework/BlackmagicRawAPI`
- `ImmersiveVideoToolbox.framework/ImmersiveVideoToolbox`
- weak `ImmersiveMediaSupport.framework`

That matters because it means immersive support is not implemented purely in app code. Resolve depends on reusable lower-level frameworks for the media model and playback path.

## BlackmagicRawAPI is the immersive-BRAW media layer

The strongest signals in `BlackmagicRawAPI` are the exported or embedded interface names:

- `IBlackmagicRawClipMultiVideo`
- `IBlackmagicRawClipImmersiveVideo`
- `IBlackmagicRawClipGeometry`
- `IBlackmagicRawClipGyroscopeMotion`
- `IBlackmagicRawClipOrientationMotion`
- `IBlackmagicRawFrameMultiVideo`

Source: `strings` output against `BlackmagicRawAPI` and decompile artifacts under `analysis/resolve_immersive_braw/BlackmagicRawAPI-full/`.

This is important for FCP support because it implies Resolve is not flattening immersive BRAW into one decoded raster plus side metadata. The raw API appears to expose:

- a multi-video abstraction
- an immersive clip abstraction
- explicit clip geometry
- explicit gyroscope/orientation motion streams

That is consistent with an import path that preserves both eyes, lens parameters, and per-frame motion/comfort metadata all the way through edit and delivery.

## ImmersiveVideoToolbox is the Apple-immersive control plane

The `ImmersiveVideoToolbox` surfaces are much more application-meaningful. The framework exports or references:

- `IVTStaticMetadata`
- `IVTDynamicMetadata`
- `FinalCutXMLParser`
- `IVTOutputProcessor`
- `IVTPreviewRenderer`
- `PreviewProjectionSpace`
- `ImmersiveRigData`
- `StereoRigParams`
- `IVTRemotePreviewSessionBase`
- `IVTRemotePreviewClientProxy`
- `IVTRemotePreviewVideoSource`
- `STMapGenerator`
- `STMapImageWarper`
- `_ivtpreviewclient._tcp`
- `mdta/com.apple.quicktime.video.presentation.immersive-media`

Evidence:

- full-framework decompile under `analysis/resolve_immersive_braw/ImmersiveVideoToolbox-full/`
- targeted strings dump from the shipping framework

The structure is readable even before you dig through full Swift bodies:

- `IVTStaticMetadata` has constructors from AIME URL or raw data and a `saveTo:error:` path.
- `IVTDynamicMetadata` can be created from FCPXML.
- `FinalCutXMLParser` appears to build dynamic and possibly static immersive metadata from `.fcpxml` / `.fcpxmld`.
- `IVTRemotePreviewSessionBase` owns peer discovery, active client lists, and frame pushing.
- `IVTPreviewRenderer`, `MetalRenderer`, `PoseProvider`, and ST-map classes suggest a local preview stack that understands immersive projections rather than just flat video output.

## The audio story is separate and heavy

`libImmersiveAudioBridge.dylib` is full of strings around:

- `ImmersiveAudioBridge`
- `ImmersiveAudioBridgeInterface`
- `ASAF`
- `APAC`
- `ADM`
- `Binaural`
- scene/object/renderer language

This is a separate subsystem, which is exactly what you would want if FCP eventually needs Apple-immersive parity. Immersive audio is not a small option toggle on a stereo pipeline. Resolve appears to ship a dedicated bridge that speaks multiple immersive-audio interchange and delivery formats.

## The app binary still matters

The top-level `Resolve` binary contains product-level strings such as:

- `ProtoVideoProcParamsBRAW`
- `isspatialvideo`
- `projectionformat`
- `stereoscopicmode`

Those strings point to a Resolve-specific parameter and serialization layer on top of the two frameworks. In other words:

- `BlackmagicRawAPI` and `ImmersiveVideoToolbox` appear to provide the media and preview primitives.
- Resolve still adds timeline, node, delivery, and UI policy above those primitives.

## Practical conclusion for FCP

If you want full immersive BRAW support inside FCP, the DaVinci model suggests you need at least three technical layers, not one:

1. A decode/import layer that preserves both eyes plus immersive lens and motion metadata.
2. A runtime metadata and rendering layer that understands Apple immersive static and dynamic metadata, projection space, and headset preview.
3. An edit-policy layer that applies immersive-specific constraints to titles, transitions, backdrops, monitoring, and delivery.

Trying to bolt immersive BRAW onto FCP as "stereo decode plus custom exporter" would almost certainly miss the actual product architecture Resolve is using.
