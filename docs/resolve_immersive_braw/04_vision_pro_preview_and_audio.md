# Vision Pro Preview And Audio

## Vision Pro is treated as a live preview target, not only a delivery device

The workflow guide says Resolve can stream to Apple Vision Pro from:

- Edit
- Color
- Deliver

through `Workspace > Stream to visionOS`.

Evidence: `DaVinci_Resolve_Immersive_Workflow_Guide.txt`, around lines `824-830`.

The 20.2 feature guide adds that Fusion can also stream immersive content directly to Vision Pro.

Evidence: `DaVinci_Resolve_20.2_New_Features_Guide.txt`, around lines `93-99`.

That already tells us the product intent: Vision Pro is part of the interactive workflow, not only the last-mile playback step.

## The reverse-engineered remote-preview stack is real and explicit

`ImmersiveVideoToolbox` exposes a cluster of types around headset preview:

- `IVTRemotePreviewSessionBase`
- `IVTMppRemotePreviewSession`
- `IVTRemotePreviewClientBase`
- `IVTRemotePreviewClientProxy`
- `IVTRemotePreviewVideoSource`
- `PeerDiscovery`
- `_ivtpreviewclient._tcp`

Evidence:

- strings extracted from the framework
- decompile index entries in `analysis/resolve_immersive_braw/ImmersiveVideoToolbox-full/_INDEX.txt`

The decompiled [`-[IVTRemotePreviewSessionBase start]`](../../analysis/resolve_immersive_braw/ImmersiveVideoToolbox-full/-[_TtC21ImmersiveVideoToolbox27IVTRemotePreviewSessionBase%20start].c) calls into a function that:

- logs "Preview session [%s] is starting"
- touches a `discovery` object
- invokes `sub_313A0`, which is associated with `PeerDiscovery`

The decompiled [`sub_EC120.c`](../../analysis/resolve_immersive_braw/ImmersiveVideoToolbox-full/sub_EC120.c), reached via `pushWithVideoFrame:pts:duration:`, appears to:

- access an `IVTSession`
- fetch an `IVTDynamicMetadataPlayer`
- compute commands around the current time
- inspect `AIVSetCameraCommand`
- update the current camera id when the dynamic command stream changes

That is exactly the kind of logic you would expect for live immersive playback:

- video frames are pushed into the preview session
- time-based dynamic metadata is evaluated alongside the frame stream
- camera changes or shot-flop transitions can be applied during playback

## Preview is projection-aware and camera-aware

The framework also exposes:

- `IVTPreviewRenderer`
- `PreviewProjectionSpace`
- `MetalRenderer`
- `PoseProvider`
- `ImmersiveRigData`
- `StereoRigParams`
- `STMapGenerator`
- `STMapImageWarper`

This suggests the preview subsystem knows about:

- different projection spaces
- stereoscopic camera geometry
- head or camera pose
- ST-map generation and image warping

That lines up with the product behavior described in the guide:

- native immersive lens-space view
- alternate `LatLong` and `Viewport` views
- Vision Pro monitoring and streaming

## Static metadata is AIME-based

`IVTStaticMetadata` has decompiled constructors for:

- `initWithAimeUrl:device:error:`
- `initWithData:device:error:`
- `saveTo:error:`

Relevant artifacts:

- [`initWithAimeUrl:device:error:`](../../analysis/resolve_immersive_braw/ImmersiveVideoToolbox-full/-[_TtC21ImmersiveVideoToolbox17IVTStaticMetadata%20initWithAimeUrl_device_error_].c)
- [`saveTo:error:`](../../analysis/resolve_immersive_braw/ImmersiveVideoToolbox-full/-[_TtC21ImmersiveVideoToolbox17IVTStaticMetadata%20saveTo_error_].c)

The index also includes:

- `IVTStaticMetadata.getCameraGeometries(cameraId:)`
- `IVTStaticMetadata.add(camera:)`

This suggests AIME or AIME-like static metadata is the canonical representation for:

- camera identities
- rig geometry
- lens/calibration state
- possibly mask and venue descriptors

That is exactly the kind of structure SpliceKit's existing Vision Pro work already gestures toward. Resolve appears to ship a full implementation of the same idea.

## Dynamic metadata appears to be command-oriented

`ImmersiveVideoToolbox` exports timed command types such as:

- `AIVSetCameraCommand`
- `AIVShotFlopCommand`

and a player:

- `IVTDynamicMetadataPlayer`

This is important because it implies dynamic immersive playback is not just a bag of frame annotations. It looks like a time-addressed command stream controlling viewpoint-relevant state.

For FCP, that could map naturally to:

- camera switches
- shot flips
- comfort-related view changes
- future presentation commands beyond those currently named

## The product format itself is Vision Pro-specific

The workflow guide says Apple Immersive Video has:

- `90 fps playback`
- `up to 4320 x 4320 per eye`
- `a unique metadata system for mapping the original camera image into the 180 environment`
- `Apple Spatial Audio Format` for 3D sound

and that Apple Vision Pro is currently the only device that supports the format.

Evidence: `DaVinci_Resolve_Immersive_Workflow_Guide.txt`, around lines `875-885`.

That explains why the runtime is so specialized. Resolve is not targeting a generic 180 stereo container only; it is targeting Apple's immersive media model.

## Audio is its own immersive subsystem

The official guide describes:

- `AIA` as the broader container family
- `ASAF` as the raw working audio format
- `APAC` as encoded `.mp4`
- export options for `ASAF` in WAV or MP4
- binaural monitoring with head tracking through Apple devices

Evidence: `DaVinci_Resolve_Immersive_Workflow_Guide.txt`, around lines `784-805`.

The guide also notes an important limitation:

- ASAF can be exported, but cannot currently be imported or played back within Resolve

The strings in `libImmersiveAudioBridge.dylib` line up with that story. They reference:

- `Binaural`
- `ADM`
- object, scene, renderer concepts
- MPEG-H / S-ADM / MXF / PMD conversion paths
- APAC / immersive-audio export infrastructure

This means the audio layer is not superficial. Resolve ships a serious immersive-audio bridge even if some flows remain export-only.

## What FCP would need to match

For serious Vision Pro parity, FCP likely needs:

1. A remote preview session type that can discover headsets and push immersive frames live.
2. Static metadata objects that can load and save AIME or an equivalent camera/rig descriptor.
3. Dynamic metadata playback, probably command-oriented.
4. Projection-aware local preview modes.
5. An immersive-audio bridge or at least an export boundary for ASAF/AIA-class outputs.

Without those layers, FCP could perhaps export files, but it would not match DaVinci's working preview and monitoring model.
