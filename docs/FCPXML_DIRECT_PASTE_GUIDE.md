# FCPXML Direct Paste — Technical Guide

> **Status**: WIP (pipeline working end-to-end in logs, visual paste verification pending)
> **Added**: April 2026, FCP 12.0, macOS Sequoia 15.4
> **Improvements**: Screen freeze (#3), caching (#6), consolidated function (#7),
> paste: support (#8), playhead restore (#10) — all implemented

---

## Problem

FCP's `pasteAnchored:` only handles native `proFFPasteboardUTI` clipboard data —
a binary `NSKeyedArchiver` plist containing serialized `FFPasteboardItem` objects.
When FCPXML is on the pasteboard (from `paste_fcpxml`, `generate_captions`, or
external tools), `pasteAnchored:` silently ignores it.

The caption system previously worked around this with a 6-step pipeline:
1. Build FCPXML with titles
2. Import via `FFXMLTranslationTask` → creates temp project
3. `loadEditorForSequence:` → switch to temp project
4. `selectAll:` + `copy:` → serialize to native clipboard
5. `loadEditorForSequence:` → switch back to user project
6. `pasteAnchored:` → paste native data

This took ~6 seconds with visible project switching, multiple sleep/poll cycles,
and fragile state management.

## Solution: `pasteAnchored:` Swizzle

SpliceKit swizzles `-[FFAnchoredTimelineModule pasteAnchored:]` to transparently
convert FCPXML to native clipboard format before the original paste runs.

### How It Works

```
User calls paste_fcpxml() or timeline_action("pasteAsConnected") / ("paste")
  → pasteAnchored: or paste: fires
    → SpliceKit_handleFCPXMLPaste() checks hasEdits: on pasteboard
      → YES: call original (normal native paste)
      → NO: call SpliceKit_convertFCPXMLToNativeClipboard()
        → Check containsXML? NO → return, call original
        → Check cache (FNV-1a hash of XML + library UUID)
          → HIT: write cached native data to pasteboard, return YES
          → MISS: continue with import pipeline
        → Save playhead position
        → Freeze screen (NSDisableScreenUpdates + 8s safety timeout)
        → Inject unique project name (_SKPaste_XXXXX)
        → Import via FFXMLTranslationTask
        → Poll _deepLoadedSequences for new project (by name)
        → loadEditorForSequence: → switch to temp project
        → selectAll: + copy: → native data on pasteboard
        → Cache the native data for future pastes
        → Switch back to user project, restore playhead
        → Clean up temp project
        → Unfreeze screen
      → Call original paste (now finds native data)
```

### Key Design Decisions

**Shared conversion function** (`SpliceKit_convertFCPXMLToNativeClipboard`)

The core conversion logic is a standalone function callable from both the
paste swizzles and the caption system. Declared in `SpliceKit.h` for use
by `SpliceKitCaptionPanel.m`. Returns YES if native data is on the pasteboard.

**Both paste modes swizzled** (Improvement #8)

`pasteAnchored:` (paste as connected) and `paste:` (insert paste) are both
swizzled through a shared handler `SpliceKit_handleFCPXMLPaste()`. Both go
through the same `_addItemsWithPasteboard:` internal path with different
`pasteMode` values.

**Screen freeze** (Improvement #3)

`NSDisableScreenUpdates()` hides the brief project switch flicker. A
`dispatch_after` safety timeout of 8 seconds ensures the screen unfreezes
even if the pipeline hangs.

**Caching** (Improvement #6)

Native clipboard data is cached in an `NSCache` keyed by `libraryUUID_hash`.
The FNV-1a hash of the FCPXML string provides fast, collision-resistant
lookup. Cache has a 50MB cost limit (~3,000 typical clips). Repeat pastes
of the same FCPXML skip the entire import pipeline.

**Playhead restoration** (Improvement #10)

The playhead position is saved before the project switch and restored after
switching back, ensuring pastes land at the expected timeline position.

**Swizzle point: `pasteAnchored:`/`paste:` not `editsFromPasteboard:`**

`editsFromPasteboard:` is called while holding FFModelLock's write lock.
Switching projects while holding that lock would deadlock. The paste methods
are called before the lock, giving us freedom to switch projects.

**Unique project name injection**

The FCPXML's `<project name="...">` is replaced with `_SKPaste_XXXXX` via
regex before import. This ensures we find our exact temp project in
`_deepLoadedSequences`, even when the library contains dozens of old
temp projects from previous caption runs.

**Run loop pumping instead of sleep**

The swizzle runs on the main thread. Using `[NSThread sleep:]` would block
the run loop and prevent FCP from processing the import. We use
`[[NSRunLoop currentRunLoop] runUntilDate:]` to pump events between polls.

### Consolidation with Caption System (Improvement #7)

`addCaptionTitlesDirectlyToTimeline` in `SpliceKitCaptionPanel.m` has its own
import-switch-copy-paste pipeline. It can be refactored to use the shared
`SpliceKit_convertFCPXMLToNativeClipboard()`, keeping only the caption-specific
post-processing (position offset, text verification). See the NOTE comment
at the top of that method for the refactoring plan.

## FCP Internal Architecture (from decompilation)

### The Paste Call Chain

```
pasteAnchored:
  v7 = NSPasteboardNameGeneral
  skimmingTime → atTime
  _addItemsWithPasteboard:atTime:pasteMode:backtimed:useSelectedRange:
    trackType:container:changesUnderActionHandler:
      FFPasteboard.initWithName: (wraps general pasteboard)
      FFModelLock._writeLock
      FFAnchoredSequence.editsFromPasteboard:trackType:videoProps:
        displayDropFrame:isLoneTransition:userInfoMap:
          FFPasteboard.hasEdits: → checks for native data categories
          FFPasteboard.newEditsWithProject:mediaByReferenceOnly:options:
            → _newObjectsWithProject:assetFlags:fromURL:options:userInfoMap:
              → _newObjectsWithProjectCore: (THE CORE)
      FFPasteboard.newMarkersWithProject:options:
      FFModelLock._writeUnlock
      FFAnchoredSequence.actionAddItemsOnPasteboard:editsToAdd:videoProps:
        displayDropFrame:atTime:pasteMode:backtimed:rangeOfMedia:rootItem:
        needsMediaReferencesChecking:needsConsolidatedEffectsChecking:error:
```

### FCP's Built-in FCPXML Paste Path (Blocked)

`_newObjectsWithProjectCore:` at address `0x4B5640` in Flexo actually HAS
complete FCPXML import handling:

```c
// At LABEL_59: No FFPasteboardItem found
if ([pasteboard containsXML]) {
    task = [FFXMLTranslationTask translationTaskForPasteboard:pb];
    if (task && !task.error && task.contentType == 2) {
        // Set up import options, import, get clips
        [task importClipsWithOptions:options taskDelegate:delegate];
        imported = [task clipsAndRangesImportedInEvent:targetEvent];
        for (item in imported) {
            if (!item.object.isProject) result.add(item);
        }
    }
}
```

**Three gates prevent this from working:**

| Gate | Where | What blocks |
|------|-------|-------------|
| `hasEdits:` | `editsFromPasteboard:` | Returns NO for FCPXML → `newEditsWithProject:` never called |
| `contentType == 2` | `_newObjectsWithProjectCore:` | Only `<project>`-rooted FCPXML passes (not `<library>` wrapped) |
| `!isProject` filter | `_newObjectsWithProjectCore:` | Imported project objects are excluded → 0 clips returned |

No FCPXML structure satisfies all three simultaneously:
- `<library>` wrapped → contentType=0 (fails gate 2)
- `<event>` wrapped → contentType=1 (fails gate 2)
- `<project>` only → contentType=2 (passes gate 2, but all imports are project objects → fails gate 3)
- Spine-only → contentType varies, rejected by `importClipsWithOptions:` entirely

### Native Clipboard Format

When FCP copies clips, the pasteboard contains exactly one type:
`com.apple.flexo.proFFPasteboardUTI`

The data is an `NSKeyedArchiver` binary plist (~15KB) with three top-level keys:

| Key | Content |
|-----|---------|
| `ffpasteboardobject` | NSKeyedArchiver data (FFAnchoredMediaComponent, FFAsset, FFEffectStack, etc.) |
| `ffpasteboardcopiedtypes` | Metadata dict (e.g. `{"pb_anchoredObject": {"count": 1}}`) |
| `kffmodelobjectIDs` | Empty array |

The library document ID is embedded inside the NSKeyedArchiver data, not at top level.

### Key Methods

| Method | Class | Purpose |
|--------|-------|---------|
| `hasEdits:` | FFPasteboard | Checks for native edit/anchoredObject categories |
| `newEditsWithProject:mediaByReferenceOnly:options:userInfoMap:` | FFPasteboard | Deserializes native data → clip objects |
| `writeAnchoredObjects:options:` | FFPasteboard | Serializes clip objects → native pasteboard format |
| `containsXML` | NSPasteboard (Interchange) | Checks for FCPXML on pasteboard |
| `initForPasteboard:` | FFXMLTranslationTask | Parses FCPXML from pasteboard |
| `importClipsWithOptions:` | FFXMLTranslationTask | Imports parsed FCPXML into library |
| `importedEvents` | FFXMLTranslationTask | Returns FFMediaEventProject array of imported events |
| `allImportedClipsAndRanges` | FFXMLTranslationTask | Returns FigTimeRangeAndObject set (often empty) |
| `editsFromPasteboard:trackType:videoProps:displayDropFrame:isLoneTransition:userInfoMap:` | FFAnchoredSequence | Main paste pipeline entry point |
| `loadEditorForSequence:` | PEEditorContainerModule | Switches active timeline |
| `_deepLoadedSequences` | FFLibrary | Returns all loaded sequences in library |

### FCPXML Pasteboard Types

| Type | UTI String | Required? |
|------|-----------|-----------|
| Generic | `com.apple.finalcutpro.xml` | YES — must be present for paste |
| v1-12 | `com.apple.finalcutpro.xml.v1-12` | Optional |
| v1-13 | `com.apple.finalcutpro.xml.v1-13` | Optional |
| v1-14 | `com.apple.finalcutpro.xml.v1-14` | Optional (FCP 11.1+) |

Note: v1-11 and earlier are NOT in FCP's readable types. Generic alone is sufficient.
Version-specific UTI alone (without generic) does NOT enable paste.

### FCPXML contentType Values

| Value | Root element | Result |
|-------|-------------|--------|
| 0 | `<library>` | Rejected by contentType check |
| 1 | `<event>` | Rejected by contentType check |
| 2 | `<project>` | Passes check but imports as project (filtered out) |

## Files

| File | What |
|------|------|
| `Sources/SpliceKitServer.m` | Swizzle implementation (`SpliceKit_swizzled_pasteAnchored`) |
| `Sources/SpliceKit.h` | Function declaration (`SpliceKit_installFCPXMLPasteSwizzle`) |
| `Sources/SpliceKit.m` | Install call in `SpliceKit_appDidLaunch()` |

## Tested Approaches (What Didn't Work)

| # | Approach | Result |
|---|----------|--------|
| 1 | Spine-only FCPXML → `importClipsWithOptions:` | Rejected — needs `<library>` wrapper |
| 2 | FCPXML on pasteboard → `pasteAnchored:` directly | Silently ignored — needs native format |
| 3 | Full FCPXML matching existing project name | Creates separate project, no merge |
| 4 | FCPXML → `anchorWithPasteboard:` | No effect (expects effect IDs, not XML) or crash |
| 5 | `FFXMLTranslationTask.exportToPasteboard:` → paste | Exports XML format, not native |
| 6 | Direct model copy (`addAnchoredItemsObject:`) | Objects can't be moved between sequences |
| 7 | `timelineView:addItems:toPasteboardWithName:` | Items from unloaded sequences are empty stubs |
| 8 | `writeAnchoredObjects:options:` with spine items | Writes native data but spine gaps don't paste as connected |
| 9 | Swizzle `hasEdits:` to unlock built-in FCPXML path | contentType + isProject gates still block |

## Related Documentation

- `docs/FCP_PASTEBOARD_MEDIA_LINKING.md` — Pasteboard format testing results
- `docs/CAPTION_SYSTEM_INTERNALS.md` — Caption system architecture
- `docs/FCPXML_FORMAT_REFERENCE.md` — FCPXML specification
