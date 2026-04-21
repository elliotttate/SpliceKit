# Resolve Immersive BRAW Notes

This document set captures how DaVinci Resolve appears to handle Apple Immersive / Vision Pro workflows around immersive `.braw` media, based on two evidence sources:

1. Official Blackmagic workflow documentation extracted to text under `analysis/resolve_immersive_braw/source_pdfs/`.
2. Headless IDA output produced from Resolve's shipped binaries and frameworks under `analysis/resolve_immersive_braw/`.

The main binaries examined were:

| Binary | Role |
| --- | --- |
| `Contents/MacOS/Resolve` | App-level orchestration, timeline settings, delivery toggles, and high-level immersive feature wiring. |
| `Contents/Frameworks/BlackmagicRawAPI.framework/BlackmagicRawAPI` | BRAW decode, multi-video and immersive clip surfaces, immersive per-frame metadata, and camera/lens/motion metadata handling. |
| `Contents/Frameworks/ImmersiveVideoToolbox.framework/ImmersiveVideoToolbox` | Static metadata, dynamic metadata, Final Cut XML parsing, projection/ST-map utilities, preview rendering, and Vision Pro remote preview sessions. |
| `Contents/Libraries/libImmersiveAudioBridge.dylib` | ASAF / AIA / APAC / ADM / binaural and immersive-audio export infrastructure. |

The current artifact snapshot is:

| Artifact | Status |
| --- | --- |
| `analysis/resolve_immersive_braw/BlackmagicRawAPI-full` | Complete full-framework decompile. |
| `analysis/resolve_immersive_braw/ImmersiveVideoToolbox-full` | Complete full-framework decompile. |
| `analysis/resolve_immersive_braw/Resolve-targeted` | In progress at the time of writing; IDA database exists but targeted `.c` export had not finished yet. |
| `analysis/resolve_immersive_braw/test-ivt-targeted` | Successful targeted proof-of-work run for `ImmersiveVideoToolbox`. |

## Document map

- [01 Architecture And Binaries](./01_architecture_and_binaries.md)
- [02 Media Ingest And Metadata](./02_media_ingest_and_metadata.md)
- [03 Editing Fusion And Delivery](./03_editing_fusion_and_delivery.md)
- [04 Vision Pro Preview And Audio](./04_vision_pro_preview_and_audio.md)
- [05 FCP Support Gap Analysis](./05_fcp_support_gap_analysis.md)

## Short version

- Resolve does not appear to treat immersive BRAW as "just stereo video". The BRAW layer exposes separate immersive, multi-video, geometry, orientation, and motion surfaces.
- The Apple-specific immersive stack is concentrated in `ImmersiveVideoToolbox`, which owns AIME/static metadata, FCPXML-derived dynamic metadata, ST-map generation, Metal rendering, and remote preview transport to Vision Pro.
- Blackmagic's official workflow aligns with the reverse-engineered structure: enable immersive project mode first, ingest `.braw` with both eyes and metadata intact, edit with immersive-specific viewer and transition rules, composite through paired undistort/redistort tools, then preview or deliver through Vision Pro-specific paths.
- Full FCP support will require more than decode. It needs a new data model for paired-eye + lens-calibrated media, immersive-aware editing constraints, a Vision Pro preview path, and an immersive-audio/export story.
