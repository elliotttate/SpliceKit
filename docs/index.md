---
layout: default
title: SpliceKit Documentation
---

# SpliceKit Documentation

## Plugin & Extension Development

- [FxPlug 4 Plugin Development Guide](FXPLUG_PLUGIN_GUIDE.md) — Complete guide to building FxPlug video effects: XPC architecture, Metal rendering, parameters, plugin state, thread safety, color management, onscreen controls, testing, and notarization. Includes the LUT plugin as a reference implementation
- [Workflow Extensions Guide](WORKFLOW_EXTENSIONS_GUIDE.md) — Build extensions that embed inside FCP's UI: ProExtensionHost framework, timeline proxy objects, observer pattern, data exchange, and comparison with SpliceKit
- [FCPXML Format Reference](FCPXML_FORMAT_REFERENCE.md) — Complete XML interchange format reference: document structure, story elements, assets, timing attributes, effects, transitions, markers, video formats, bundles, and bookmarks
- [Content Exchange Guide](CONTENT_EXCHANGE_GUIDE.md) — Sending and receiving media between apps and FCP: FCPXML, drag-and-drop, Apple Events, growing files, custom share destinations, metadata, roles, and encoder extensions

## Features & Capabilities

- [Transcript-Based Editing Guide](TRANSCRIPT_EDITING_GUIDE.md) — Text-based video editing via speech transcription: multiple engines (Parakeet, Apple Speech, FCP Native), speaker diarization, silence detection and batch removal, drag-to-reorder, delete-to-cut
- [Command Palette & AI Guide](COMMAND_PALETTE_GUIDE.md) — Quick-access command palette with fuzzy search and Apple Intelligence natural language: 120+ commands, favorites, keyboard navigation
- [Scene & Beat Detection Guide](SCENE_BEAT_DETECTION_GUIDE.md) — Automatic scene change detection via histogram analysis and audio beat/tempo detection for rhythm-based editing and montage creation
- [Dialog Automation Guide](DIALOG_AUTOMATION_GUIDE.md) — Detect, inspect, and interact with FCP dialogs, sheets, and alerts programmatically: buttons, text fields, checkboxes, popup menus
- [Runtime Introspection Guide](RUNTIME_INTROSPECTION_GUIDE.md) — Explore FCP's 78,000+ ObjC classes at runtime: methods, properties, ivars, protocols, inheritance, symbol analysis, and IDA Pro export
- [FlexMusic & Montage Maker Guide](FLEXMUSIC_AND_MONTAGE_GUIDE.md) — Dynamic soundtracks and auto-edit-to-beat montage creation: browse songs, get beat timing, render audio, and assemble montages

## Technical Deep Dives

- [FCP Pasteboard & Media Linking](FCP_PASTEBOARD_MEDIA_LINKING.md) — How to restore clips to the FCP timeline with volume/attributes preserved, bypassing the offline media problem
- [Beat Detection Internals Guide](BEAT_DETECTION_INTERNALS.md) — How FCP's built-in beat grid is validated, why A/V clips fail, how timing metadata is written, and when to use SpliceKit's external `detect_beats()` tool instead

## Reports

- [FCP Application Internals](FCP_APPLICATION_INTERNALS.md) — Comprehensive technical reference to FCP's internal architecture: all 53 binaries, 303K+ functions, frameworks, ML pipeline, render engine, and data model
- [FCP Mac vs iPad: Deep Dive Comparison](FCP_Mac_vs_iPad_Comparison.md) — Comprehensive binary-level analysis comparing Final Cut Pro 12.0 (Mac) with Final Cut Pro 3.0 (iPad)
- [FCP API Reference](FCP_API_REFERENCE.md) — Complete API reference for all key classes, methods, properties, and patterns
