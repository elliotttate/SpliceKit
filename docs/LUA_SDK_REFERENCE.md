# SpliceKit Lua SDK Reference

Lua 5.4 scripting engine embedded directly inside Final Cut Pro. Write scripts,
save them, and they execute in-process with zero latency — no network, no
AppleScript, no UI automation. Just direct ObjC runtime calls.

## Quick Start

Open the Lua REPL in FCP: **Ctrl+Option+L** (Enhancements > Lua REPL)

```lua
-- Blade every 2 seconds
sk.go_to_start()
for t = 2, 30, 2 do
    sk.seek(t)
    sk.blade()
end
```

Or save scripts to `~/Library/Application Support/SpliceKit/lua/auto/` and they
execute automatically every time you save.

---

## Table of Contents

1. [Core Concepts](#1-core-concepts)
2. [sk Module — Quick Reference](#2-sk-module--quick-reference)
3. [Playback & Navigation](#3-playback--navigation)
4. [Timeline Editing](#4-timeline-editing)
5. [Timeline State & Queries](#5-timeline-state--queries)
6. [Color Correction](#6-color-correction)
7. [Effects & Transitions](#7-effects--transitions)
8. [Speed & Retiming](#8-speed--retiming)
9. [Audio](#9-audio)
10. [Titles & Generators](#10-titles--generators)
11. [Markers](#11-markers)
12. [Keyframes](#12-keyframes)
13. [Captions & Subtitles](#13-captions--subtitles)
14. [Transcript-Based Editing](#14-transcript-based-editing)
15. [Inspector Properties](#15-inspector-properties)
16. [FCPXML Import/Export](#16-fcpxml-importexport)
17. [Project & Library Management](#17-project--library-management)
18. [View & Workspace](#18-view--workspace)
19. [User Interface (Alerts, Toasts, Prompts)](#19-user-interface-alerts-toasts-prompts)
20. [Menu Commands](#20-menu-commands)
21. [Dialog Automation](#21-dialog-automation)
22. [ObjC Runtime Bridge](#22-objc-runtime-bridge)
23. [File Watcher & Live Coding](#23-file-watcher--live-coding)
24. [REPL Panel](#24-repl-panel)
25. [Safety & Limits](#25-safety--limits)
26. [Cookbook: Complete Workflow Examples](#26-cookbook-complete-workflow-examples)

---

## 1. Core Concepts

### The `sk` Module

Every Lua script has access to a global `sk` table. It provides:

- **Direct functions** — `sk.blade()`, `sk.seek(5.0)`, `sk.clips()` — zero-overhead
  wrappers around SpliceKit's internal handlers.
- **Dynamic dispatch** — Any FCP timeline or playback action can be called by name.
  `sk.addColorBoard()` works even though it's not an explicit function — the
  `__index` metamethod resolves it at runtime.
- **snake_case or camelCase** — Both `sk.go_to_start()` and `sk.goToStart()` work.
- **`sk.rpc(method, params)`** — Universal passthrough to any of SpliceKit's 140+
  JSON-RPC methods.

### Persistent State

The Lua VM is persistent — variables, functions, and modules survive between calls:

```lua
-- Call 1
clips_cache = sk.clips()

-- Call 2 (seconds or hours later)
print(clips_cache.sequence)  -- still there
```

Use `lua.reset` to clear all state and start fresh.

### Main Thread Safety

FCP's UI must be modified on the main thread. The `sk` module handles this
automatically — every bridge function dispatches to main, executes, and returns
the result. You never need to think about threading.

### Error Handling

Lua errors are caught and returned, never propagated as crashes:

```lua
-- This returns an error, doesn't kill FCP
local ok, err = pcall(function()
    error("something broke")
end)
print(ok, err)  -- false   ...something broke
```

---

## 2. sk Module — Quick Reference

### Explicit Functions

| Function | Description |
|----------|-------------|
| `sk.blade()` | Blade at playhead |
| `sk.undo()` | Undo last action |
| `sk.redo()` | Redo |
| `sk.play()` | Toggle play/pause |
| `sk.go_to_start()` | Jump to timeline start |
| `sk.go_to_end()` | Jump to timeline end |
| `sk.next_frame(n)` | Advance n frames (default 1) |
| `sk.prev_frame(n)` | Go back n frames (default 1) |
| `sk.seek(seconds)` | Jump to exact time |
| `sk.select_clip()` | Select clip at playhead |
| `sk.add_marker()` | Add marker at playhead |
| `sk.color_board()` | Add color board to selected clip |
| `sk.clips()` | Get timeline clips as Lua table |
| `sk.position()` | Get playhead position/state |
| `sk.selected()` | Get selected clips |
| `sk.timeline(action)` | Execute any timeline action by name |
| `sk.playback(action)` | Execute any playback action by name |
| `sk.rpc(method, params)` | Call any SpliceKit RPC method |
| `sk.eval(expr)` | Evaluate ObjC expression |
| `sk.call(target, sel, args)` | Call ObjC method |
| `sk.release(handle)` | Release object handle |
| `sk.release_all()` | Release all handles |
| `sk.log(msg)` | Log to SpliceKit console |
| `sk.alert(title, msg, [btn1], [btn2])` | Show modal dialog, returns button clicked |
| `sk.toast(msg, [duration])` | Show floating HUD notification (auto-dismisses) |
| `sk.prompt(title, msg, [default])` | Show text input dialog, returns string or nil |
| `sk.sleep(sec)` | Pause execution (max 60s) |

### Dynamic Functions (via `__index`)

Any timeline or playback action can be called directly:

```lua
sk.bladeAll()
sk.addTransition()
sk.retimeSlow50()
sk.freezeFrame()
sk.toggleSnapping()
-- ... 120+ actions available
```

Snake_case versions also work:

```lua
sk.blade_all()
sk.add_transition()
sk.retime_slow_50()
sk.freeze_frame()
sk.toggle_snapping()
```

---

## 3. Playback & Navigation

### Basic Playback

```lua
sk.play()                   -- toggle play/pause
sk.go_to_start()            -- jump to beginning
sk.go_to_end()              -- jump to end
sk.playback("playAroundCurrent")  -- play around current position
```

### Frame-Accurate Navigation

```lua
sk.next_frame()             -- advance 1 frame
sk.next_frame(10)           -- advance 10 frames
sk.prev_frame(5)            -- go back 5 frames
sk.playback("nextFrame10")  -- advance 10 frames (built-in action)
sk.playback("prevFrame10")  -- go back 10 frames
```

### Seeking to Exact Times

```lua
sk.seek(5.0)                -- jump to 5 seconds
sk.seek(0)                  -- jump to start
sk.seek(120.5)              -- jump to 2:00.5
```

### Getting Playhead Position

```lua
local pos = sk.position()
print(pos.seconds)          -- 48.92 (current time in seconds)
print(pos.frameRate)        -- 30.0
print(pos.isPlaying)        -- false
```

### Navigating Between Edits

```lua
sk.timeline("nextEdit")     -- jump to next edit point
sk.timeline("previousEdit") -- jump to previous edit point
```

---

## 4. Timeline Editing

### Blade (Cut)

```lua
sk.blade()                  -- blade at playhead (primary storyline)
sk.blade_all()              -- blade all connections at playhead
```

### Delete & Replace

```lua
sk.select_clip()            -- select clip at playhead first
sk.timeline("delete")       -- ripple delete selection
sk.timeline("replaceWithGap")  -- replace with gap (no ripple)
sk.timeline("cut")          -- cut to clipboard
sk.timeline("copy")         -- copy to clipboard
sk.timeline("paste")        -- paste from clipboard
sk.timeline("pasteAsConnected")  -- paste as connected clip
```

### Insert & Append

```lua
sk.timeline("insertGap")          -- insert gap at playhead
sk.timeline("insertPlaceholder")  -- insert placeholder clip
sk.timeline("insertEdit")         -- insert edit mode
sk.timeline("appendEdit")         -- append edit mode
sk.timeline("overwriteEdit")      -- overwrite edit mode
sk.timeline("connectToPrimaryStoryline")  -- connect to primary
```

### Trim

```lua
sk.timeline("trimToPlayhead")         -- trim end to playhead
sk.timeline("extendEditToPlayhead")   -- extend edit to playhead
sk.timeline("trimStart")             -- trim start
sk.timeline("trimEnd")               -- trim end
sk.timeline("joinClips")             -- join adjacent clips
```

### Nudge

```lua
sk.timeline("nudgeLeft")   -- nudge left
sk.timeline("nudgeRight")  -- nudge right
sk.timeline("nudgeUp")     -- nudge up (to higher lane)
sk.timeline("nudgeDown")   -- nudge down (to lower lane)
```

### Selection

```lua
sk.select_clip()                     -- select clip at playhead
sk.timeline("selectAll")             -- select all clips
sk.timeline("deselectAll")           -- deselect all
sk.timeline("selectToPlayhead")      -- extend selection to playhead
```

### Range Selection

```lua
sk.timeline("setRangeStart")   -- mark in at playhead
sk.timeline("setRangeEnd")     -- mark out at playhead
sk.timeline("clearRange")      -- clear range selection
sk.timeline("setClipRange")    -- set range to clip boundaries
```

Or programmatically:

```lua
sk.rpc("timeline.setRange", {start_seconds = 5.0, end_seconds = 10.0})
```

### Undo / Redo

```lua
sk.undo()                    -- undo last action
sk.redo()                    -- redo
-- Undo is unlimited — call multiple times to step back
for i = 1, 5 do sk.undo() end
```

### Compound Clips & Storylines

```lua
sk.timeline("createCompoundClip")
sk.timeline("breakApartClipItems")
sk.timeline("createStoryline")
sk.timeline("liftFromPrimaryStoryline")
sk.timeline("overwriteToPrimaryStoryline")
sk.timeline("collapseToConnectedStoryline")
```

### Auditions

```lua
sk.timeline("createAudition")
sk.timeline("finalizeAudition")
sk.timeline("nextAuditionPick")
sk.timeline("previousAuditionPick")
```

### Clip Operations

```lua
sk.timeline("solo")           -- solo clip
sk.timeline("disable")        -- disable clip
sk.timeline("openClip")       -- open compound clip
sk.timeline("renameClip")     -- rename clip
sk.timeline("changeDuration") -- change clip duration
sk.timeline("autoReframe")    -- auto reframe for aspect ratio
sk.timeline("synchronizeClips") -- synchronize clips
```

---

## 5. Timeline State & Queries

### Get All Clips

```lua
local state = sk.clips()
print(state.sequence)        -- sequence name
print(state.hasItems)        -- true/false

-- Iterate items
local items = state.items or {}
for i, clip in ipairs(items) do
    print(i, clip.name, clip.start, clip.duration)
end
```

### Get Detailed State

```lua
local detailed = sk.rpc("timeline.getDetailedState", {})
-- Returns full clip metadata including effects, handles, lanes
```

### Get Selected Clips

```lua
local sel = sk.selected()
-- Returns currently selected clips with their properties
```

### Select Clip in Specific Lane

```lua
sk.rpc("timeline.selectClipInLane", {lane = 1})    -- connected above
sk.rpc("timeline.selectClipInLane", {lane = -1})   -- connected below
sk.rpc("timeline.selectClipInLane", {lane = 0})    -- primary storyline
```

### Get Clip Effects

```lua
sk.select_clip()
local effects = sk.rpc("effects.getClipEffects", {})
```

---

## 6. Color Correction

Always select a clip first:

```lua
sk.select_clip()
sk.color_board()             -- add Color Board
sk.color_wheels()            -- add Color Wheels
sk.color_curves()            -- add Color Curves
```

### All Color Tools

```lua
sk.timeline("addColorBoard")
sk.timeline("addColorWheels")
sk.timeline("addColorCurves")
sk.timeline("addColorAdjustment")
sk.timeline("addHueSaturation")
sk.timeline("addEnhanceLightAndColor")
sk.timeline("balanceColor")
sk.timeline("matchColor")
sk.timeline("addMagneticMask")
sk.timeline("smartConform")
```

### Example: Color Grade Every Clip

```lua
sk.go_to_start()
local state = sk.clips()
local items = state.items or {}

for i, clip in ipairs(items) do
    if clip.start then
        sk.seek(clip.start + 0.01)
        sk.select_clip()
        sk.color_board()
    end
end
```

---

## 7. Effects & Transitions

### List Available Effects

```lua
local effects = sk.rpc("effects.listAvailable", {})
-- Returns all available effects with names and IDs

local filtered = sk.rpc("effects.listAvailable", {filter = "blur"})
```

### Apply Effect

```lua
sk.select_clip()
sk.rpc("effects.apply", {name = "Gaussian Blur"})
```

### List Transitions

```lua
local trans = sk.rpc("transitions.list", {})
-- Returns 376+ transitions

local dissolved = sk.rpc("transitions.list", {filter = "dissolve"})
```

### Apply Transition

```lua
sk.timeline("nextEdit")  -- navigate to edit point first
sk.rpc("transitions.apply", {name = "Cross Dissolve"})
sk.rpc("transitions.apply", {name = "Flow"})
sk.rpc("transitions.apply", {effectID = "HEFlowTransition"})
```

### Freeze Extend (When Not Enough Handles)

```lua
sk.rpc("transitions.apply", {name = "Cross Dissolve", freeze_extend = true})
```

### Remove Effects

```lua
sk.select_clip()
sk.timeline("removeEffects")
sk.timeline("removeAttributes")
```

### Copy/Paste Effects Between Clips

```lua
-- Select source clip
sk.seek(2.0)
sk.select_clip()
sk.timeline("copyAttributes")

-- Select target clip
sk.seek(8.0)
sk.select_clip()
sk.timeline("pasteAttributes")
```

---

## 8. Speed & Retiming

Select a clip first, then apply:

```lua
sk.select_clip()

-- Preset speeds
sk.timeline("retimeSlow50")       -- 50% speed
sk.timeline("retimeSlow25")       -- 25% speed
sk.timeline("retimeSlow10")       -- 10% speed
sk.timeline("retimeFast2x")       -- 2x speed
sk.timeline("retimeFast4x")       -- 4x speed
sk.timeline("retimeFast8x")       -- 8x speed
sk.timeline("retimeFast20x")      -- 20x speed
sk.timeline("retimeNormal")       -- restore normal speed
sk.timeline("retimeReverse")      -- reverse playback
sk.timeline("retimeHold")         -- hold frame
sk.timeline("freezeFrame")        -- freeze frame

-- Speed ramps
sk.timeline("retimeSpeedRampToZero")    -- ramp down to 0
sk.timeline("retimeSpeedRampFromZero")  -- ramp up from 0
sk.timeline("retimeBladeSpeed")         -- blade speed segment
```

### Direct Retime Control

```lua
sk.rpc("timeline.directAction", {
    action = "retimeSetRate",
    rate = 0.75,         -- 75% speed
    ripple = true
})

sk.rpc("timeline.directAction", {
    action = "retimeInstantReplay",
    rate = 0.5,
    addTitle = true
})

sk.rpc("timeline.directAction", {
    action = "retimeJumpCut",
    framesToJump = 5
})
```

---

## 9. Audio

### Volume

```lua
sk.timeline("adjustVolumeUp")
sk.timeline("adjustVolumeDown")
```

### Precise Volume

```lua
sk.rpc("timeline.directAction", {
    action = "changeAudioVolume",
    amount = -6.0,
    relative = true
})
```

### Audio Fades

```lua
sk.rpc("timeline.directAction", {
    action = "applyAudioFadesDirect",
    fadeIn = true,
    duration = 0.5
})
```

### Audio Tools

```lua
sk.timeline("expandAudio")
sk.timeline("expandAudioComponents")
sk.timeline("addChannelEQ")
sk.timeline("enhanceAudio")
sk.timeline("matchAudio")
sk.timeline("detachAudio")
```

### Set Volume via Inspector

```lua
sk.select_clip()
sk.rpc("inspector.set", {property = "volume", value = -6.0})
```

---

## 10. Titles & Generators

### Insert Titles

```lua
sk.timeline("addBasicTitle")
sk.timeline("addBasicLowerThird")
```

### Insert Specific Title

```lua
sk.rpc("titles.insert", {name = "Custom Lower Third"})
```

### Read Title Text

```lua
sk.select_clip()
local text = sk.rpc("inspector.getTitle", {})
print(text.text, text.fontFamily, text.fontSize)
```

### Adjustment Layers

```lua
sk.timeline("addAdjustmentClip")
```

---

## 11. Markers

### Add Markers

```lua
sk.add_marker()                              -- standard marker
sk.timeline("addTodoMarker")                 -- to-do marker
sk.timeline("addChapterMarker")              -- chapter marker
```

### Navigate Markers

```lua
sk.timeline("nextMarker")
sk.timeline("previousMarker")
```

### Delete Markers

```lua
sk.timeline("deleteMarker")
sk.timeline("deleteMarkersInSelection")
```

### Batch Add Markers at Specific Times

```lua
sk.rpc("timeline.addMarkers", {
    times = {1.0, 5.5, 10.0, 15.5, 20.0}
})
```

### Direct Marker Manipulation

```lua
sk.rpc("timeline.directAction", {
    action = "changeMarkerType",
    type = "chapter"
})

sk.rpc("timeline.directAction", {
    action = "changeMarkerName",
    name = "Introduction"
})

sk.rpc("timeline.directAction", {
    action = "markMarkerCompleted",
    completed = true
})
```

### Import SRT as Markers

```lua
sk.rpc("timeline.importSRT", {
    srt_content = "1\n00:00:05,000 --> 00:00:10,000\nSubtitle text"
})
```

---

## 12. Keyframes

```lua
sk.timeline("addKeyframe")
sk.timeline("deleteKeyframes")
sk.timeline("nextKeyframe")
sk.timeline("previousKeyframe")
```

---

## 13. Captions & Subtitles

### Social Media Captions (Word-by-Word Animated)

```lua
-- Open caption panel and transcribe
sk.rpc("captions.open", {})
sk.rpc("captions.open", {style = "bold_pop"})

-- Check transcription progress
local state = sk.rpc("captions.getState", {})

-- List available styles
local styles = sk.rpc("captions.getStyles", {})
-- Returns: bold_pop, neon_glow, clean_minimal, handwritten,
--   gradient_fire, outline_bold, shadow_deep, karaoke, typewriter,
--   bounce_fun, subtitle_pro, social_bold, social_reels

-- Apply a style
sk.rpc("captions.setStyle", {
    preset_id = "neon_glow",
    font_size = 80,
    position = "center"
})

-- Set word grouping
sk.rpc("captions.setGrouping", {
    mode = "words",    -- "social", "words", "sentence", "time", "chars"
    max_words = 4
})

-- Generate captions and paste to timeline
sk.rpc("captions.generate", {style = "bold_pop"})

-- Export
sk.rpc("captions.exportSRT", {path = "/tmp/captions.srt"})
sk.rpc("captions.exportTXT", {path = "/tmp/captions.txt"})

-- Verify generated captions
sk.rpc("captions.verify", {})

-- Close panel
sk.rpc("captions.close", {})
```

### Native FCP Captions

```lua
sk.rpc("nativeCaptions.generate", {})
sk.rpc("nativeCaptions.verify", {})
```

### Timeline Caption Actions

```lua
sk.timeline("addCaption")
sk.timeline("splitCaption")
sk.timeline("resolveOverlaps")
```

---

## 14. Transcript-Based Editing

### Open & Transcribe

```lua
-- Transcribe all clips on timeline
sk.rpc("transcript.open", {})

-- Transcribe a specific file
sk.rpc("transcript.open", {file_url = "/path/to/video.mp4"})

-- Set transcription engine
sk.rpc("transcript.setEngine", {engine = "parakeet_v3"})
-- Options: parakeet_v3 (default), parakeet_v2, apple_speech, fcp_native
```

### Get Transcript

```lua
local transcript = sk.rpc("transcript.getState", {})
-- Returns words with timestamps, speakers, and silences
```

### Search Transcript

```lua
local results = sk.rpc("transcript.search", {query = "hello"})
local pauses = sk.rpc("transcript.search", {query = "pauses"})
```

### Edit via Transcript (Text-Based Editing)

```lua
-- Delete words (removes corresponding video)
sk.rpc("transcript.deleteWords", {start_index = 5, count = 3})

-- Move/reorder words (rearranges clips)
sk.rpc("transcript.moveWords", {
    start_index = 10,
    count = 2,
    dest_index = 3
})
```

### Remove Silences

```lua
-- Delete all silences
sk.rpc("transcript.deleteSilences", {})

-- Delete only long silences
sk.rpc("transcript.deleteSilences", {min_duration = 1.0})

-- Set silence detection threshold
sk.rpc("transcript.setSilenceThreshold", {threshold = 0.5})
```

### Speaker Labels

```lua
sk.rpc("transcript.setSpeaker", {
    start_index = 0,
    count = 50,
    speaker = "Host"
})
```

---

## 15. Inspector Properties

### Read Properties

```lua
sk.select_clip()

local props = sk.rpc("inspector.get", {})              -- all properties
local transform = sk.rpc("inspector.get", {section = "transform"})
local compositing = sk.rpc("inspector.get", {section = "compositing"})
```

### Set Properties

```lua
sk.select_clip()

sk.rpc("inspector.set", {property = "opacity", value = 0.5})
sk.rpc("inspector.set", {property = "volume", value = -6.0})
sk.rpc("inspector.set", {property = "positionX", value = 100.0})
sk.rpc("inspector.set", {property = "positionY", value = -50.0})
sk.rpc("inspector.set", {property = "scaleX", value = 1.2})
sk.rpc("inspector.set", {property = "rotation", value = 45.0})
```

---

## 16. FCPXML Import/Export

### Export Current Project

```lua
-- Export to default path
sk.rpc("fcpxml.export", {})

-- Export to specific path
sk.rpc("fcpxml.export", {path = "/tmp/my_project.fcpxml"})
```

### Generate FCPXML

```lua
local xml = sk.rpc("fcpxml.generate", {
    project_name = "My Project",
    frame_rate = "24",
    items = '[{"type":"gap","duration":10},{"type":"title","text":"Intro","duration":5}]'
})
```

### Import FCPXML

```lua
sk.rpc("fcpxml.import", {xml = xml_string, internal = true})
```

### Paste via FCPXML

```lua
sk.rpc("fcpxml.pasteImport", {xml = xml_string})
```

---

## 17. Project & Library Management

### Open a Project

```lua
sk.rpc("project.open", {name = "My Project"})
sk.rpc("project.open", {name = "Edit v2", event = "4-5-26"})
```

### Create New

```lua
sk.rpc("project.create", {})
sk.rpc("project.createEvent", {})
sk.rpc("project.createLibrary", {})
```

### Library Info

```lua
sk.timeline("projectProperties")
sk.timeline("closeLibrary")
sk.timeline("duplicateProject")
sk.timeline("snapshotProject")
```

### Get Active Libraries

```lua
local libs = sk.rpc("browser.listClips", {})
```

---

## 18. View & Workspace

### Toggle Panels

```lua
sk.rpc("view.toggle", {panel = "inspector"})
sk.rpc("view.toggle", {panel = "videoScopes"})
sk.rpc("view.toggle", {panel = "effectsBrowser"})
sk.rpc("view.toggle", {panel = "timeline"})
```

### Switch Workspace

```lua
sk.rpc("view.workspace", {name = "colorEffects"})
```

### Timeline View

```lua
sk.timeline("zoomToFit")
sk.timeline("zoomIn")
sk.timeline("zoomOut")
sk.timeline("verticalZoomToFit")
sk.timeline("toggleSnapping")
sk.timeline("toggleSkimming")
sk.timeline("toggleInspector")
sk.timeline("toggleTimeline")
sk.timeline("toggleTimelineIndex")
```

### Select Tool

```lua
sk.rpc("tool.select", {tool = "blade"})
sk.rpc("tool.select", {tool = "trim"})
sk.rpc("tool.select", {tool = "range"})
sk.rpc("tool.select", {tool = "transform"})
sk.rpc("tool.select", {tool = "select"})  -- default arrow
```

### Viewer

```lua
sk.rpc("viewer.getZoom", {})           -- current zoom level
sk.rpc("viewer.setZoom", {zoom = 0.0}) -- fit to window
sk.rpc("viewer.setZoom", {zoom = 1.0}) -- 100%
sk.rpc("viewer.setZoom", {zoom = 2.0}) -- 200%

-- Screenshot the viewer
sk.rpc("viewer.capture", {})
sk.rpc("viewer.capture", {path = "/tmp/frame.png"})
```

---

## 19. User Interface (Alerts, Toasts, Prompts)

### Alert Dialog (Modal)

Blocks execution until the user clicks a button. Returns the button text.

```lua
sk.alert("Title", "Message body here.\nSupports newlines.")

-- With custom buttons
local btn = sk.alert("Confirm", "Delete all clips?", "Delete", "Cancel")
if btn == "Delete" then
    -- user confirmed
end

-- Show a report
sk.alert("Timeline Report", string.format(
    "Clips: %d\nDuration: %.1fs\nFrame rate: %.0f fps",
    clip_count, duration, fps
))
```

### Toast Notification (Non-Blocking)

Shows a floating HUD at the top of the screen that auto-dismisses.
Does not block script execution.

```lua
sk.toast("Processing complete!")
sk.toast("Exporting 5 clips...", 5)    -- custom duration (seconds)
sk.toast("Quick note", 1.5)           -- brief flash
```

### Text Input Prompt (Modal)

Shows a dialog with a text field. Returns the entered text, or `nil` if cancelled.

```lua
local name = sk.prompt("Project Name", "Enter a name for the export:", "My Project")
if name then
    print("User entered: " .. name)
else
    print("User cancelled")
end

-- Use for configuration
local interval = sk.prompt("Blade Interval", "Seconds between cuts:", "5")
if interval then
    local n = tonumber(interval)
    if n and n > 0 then
        -- blade every n seconds
    end
end
```

---

## 20. Menu Commands

Execute any FCP menu item:

```lua
sk.rpc("menu.execute", {path = {"File", "New", "Project"}})
sk.rpc("menu.execute", {path = {"Modify", "Balance Color"}})
sk.rpc("menu.execute", {path = {"View", "Playback", "Loop"}})
```

Discover available menus:

```lua
sk.rpc("menu.list", {menu = "File"})
sk.rpc("menu.list", {menu = "Modify", depth = 3})
```

---

## 21. Dialog Automation

```lua
-- Detect open dialogs
local dlg = sk.rpc("dialog.detect", {})

-- Click buttons
sk.rpc("dialog.click", {button = "OK"})
sk.rpc("dialog.click", {button = "Cancel"})
sk.rpc("dialog.click", {index = 0})

-- Fill text fields
sk.rpc("dialog.fill", {value = "My Project"})

-- Toggle checkboxes
sk.rpc("dialog.checkbox", {label = "Use custom settings", checked = true})

-- Select from dropdowns
sk.rpc("dialog.popup", {select = "4K"})

-- Dismiss
sk.rpc("dialog.dismiss", {action = "default"})
sk.rpc("dialog.dismiss", {action = "cancel"})
```

---

## 22. ObjC Runtime Bridge

### Evaluate Property Chains

```lua
local r = sk.eval("NSApp.delegate._targetLibrary.displayName")
print(r.result)  -- "My Library"
print(r.class)   -- "NSString"
```

### Call ObjC Methods

```lua
-- Class method (no arguments)
local libs = sk.call("FFLibraryDocument", "copyActiveLibraries")
print(libs.handle)  -- "obj_1"
print(libs.class)   -- "__NSArrayM"

-- Instance method with arguments
local lib = sk.rpc("system.callMethodWithArgs", {
    target = "obj_1",
    selector = "objectAtIndex:",
    args = {{type = "int", value = 0}},
    returnHandle = true
})

-- Read properties
local name = sk.rpc("object.getProperty", {
    handle = "obj_1",
    property = "displayName"
})
```

### Argument Types for `system.callMethodWithArgs`

| Type | Example | Notes |
|------|---------|-------|
| `string` | `{type="string", value="hello"}` | NSString |
| `int` | `{type="int", value=42}` | Integer types |
| `double` | `{type="double", value=3.14}` | Double/float |
| `bool` | `{type="bool", value=true}` | BOOL |
| `handle` | `{type="handle", value="obj_1"}` | ObjC object ref |
| `cmtime` | `{type="cmtime", value=5.0}` | CMTime (video time) |
| `selector` | `{type="selector", value="doThing:"}` | SEL |
| `nil` | `{type="nil"}` | nil argument |

### Handle Management

```lua
local h = sk.call("FFLibraryDocument", "copyActiveLibraries")
-- ... use h.handle ...
sk.release(h.handle)     -- release one handle
sk.release_all()         -- release all handles (max 2000)
```

### Runtime Introspection

```lua
-- Find classes
local classes = sk.rpc("system.getClasses", {filter = "FFColor"})

-- Get methods on a class
local methods = sk.rpc("system.getMethods", {className = "FFAnchoredTimelineModule"})

-- Get inheritance chain
local chain = sk.rpc("system.getSuperchain", {className = "FFAnchoredTimelineModule"})

-- Get properties
local props = sk.rpc("system.getProperties", {className = "FFAnchoredSequence"})

-- Get instance variables
local ivars = sk.rpc("system.getIvars", {className = "FFPlayer"})

-- Get protocols
local protos = sk.rpc("system.getProtocols", {className = "FFAnchoredMediaComponent"})
```

---

## 23. File Watcher & Live Coding

### Directory Structure

```
~/Library/Application Support/SpliceKit/lua/
  auto/       <-- Scripts here execute every time you save
  lib/        <-- Lua modules available via require()
  examples/   <-- Bundled example scripts
```

### How It Works

1. Save a `.lua` file to the `auto/` directory
2. SpliceKit detects the change via FSEvents (100ms debounce)
3. The script executes inside FCP automatically
4. Output and errors appear in the SpliceKit log

### Live Coding Workflow

```bash
# Terminal: edit your script
vim ~/Library/Application\ Support/SpliceKit/lua/auto/my_script.lua
```

```lua
-- my_script.lua — runs every time you save
local pos = sk.position()
sk.log(string.format("Playhead at %.2fs", pos.seconds))

-- Do something based on playhead position
if pos.seconds > 10 then
    sk.add_marker()
end
```

Save the file, and it executes immediately in FCP.

### Managing Watch Paths

```lua
-- List watched directories
sk.rpc("lua.watch", {action = "list"})

-- Watch additional directory
sk.rpc("lua.watch", {action = "add", path = "/path/to/scripts"})

-- Stop watching
sk.rpc("lua.watch", {action = "remove", path = "/path/to/scripts"})
```

### Using lib/ for Shared Modules

```lua
-- ~/Library/Application Support/SpliceKit/lua/lib/helpers.lua
local M = {}

function M.blade_at_times(times)
    for _, t in ipairs(times) do
        sk.seek(t)
        sk.blade()
    end
end

function M.select_and_apply(time, action)
    sk.seek(time + 0.01)
    sk.select_clip()
    sk.timeline(action)
end

return M
```

```lua
-- In any script:
local helpers = require("helpers")
helpers.blade_at_times({2, 4, 6, 8, 10})
```

---

## 24. REPL Panel

Open: **Ctrl+Option+L** or Enhancements > Lua REPL

### Features

- **Enter** executes code
- **Up/Down arrows** navigate command history (persisted across sessions)
- **Escape** cancels multiline input
- **Multiline support** — incomplete blocks (`if`, `for`, `function`, `do`, `repeat`)
  automatically continue on the next line
- **Run File...** button — pick and execute a .lua file
- **Reset VM** button — clear all state
- **Clear** button — clear output

### Colors

- Blue (`>`) — your input
- White — print() output
- Green — return values
- Red — errors

---

## 25. Safety & Limits

| Protection | Limit | Behavior |
|------------|-------|----------|
| Execution timeout | 30 seconds | Script aborted with error |
| Memory limit | 256 MB | Lua out-of-memory error |
| `os.exit()` | Blocked | Returns error message |
| `os.execute()` | Blocked | Returns error message |
| `io.popen()` | Blocked | Returns error message |
| `debug.debug()` | Removed | Not available |

Safe functions that ARE available: `io.open`, `io.read`, `io.write`, `os.clock`,
`os.date`, `os.time`, `os.tmpname`, all of `math`, `string`, `table`, `utf8`,
`coroutine`, `require`.

---

## 26. Cookbook: Complete Workflow Examples

### Blade at Every Scene Change

```lua
-- Detect scenes and blade at each cut point
local scenes = sk.rpc("scene.detect", {
    threshold = 0.3,
    sample_interval = 0.1
})

if scenes.timestamps then
    for _, t in ipairs(scenes.timestamps) do
        sk.seek(t)
        sk.blade()
    end
    sk.log("Bladed at " .. #scenes.timestamps .. " scene changes")
end
```

### Apply Cross Dissolve Between All Clips

```lua
sk.go_to_start()
local state = sk.clips()
local items = state.items or {}

for i = 2, #items do
    sk.timeline("nextEdit")
    sk.rpc("transitions.apply", {name = "Cross Dissolve"})
end
```

### Remove All Short Clips (Flash Frames)

```lua
local state = sk.clips()
local items = state.items or {}
local removed = 0

-- Work backwards to preserve positions
for i = #items, 1, -1 do
    local clip = items[i]
    if clip.duration and clip.duration < 0.1 then  -- < 3 frames at 30fps
        sk.seek(clip.start + 0.01)
        sk.select_clip()
        sk.timeline("delete")
        removed = removed + 1
    end
end

sk.log("Removed " .. removed .. " flash frames")
```

### Batch Color Grade with Specific Settings

```lua
local state = sk.clips()
local items = state.items or {}

for i, clip in ipairs(items) do
    sk.seek(clip.start + 0.01)
    sk.select_clip()
    sk.color_board()
    -- Set opacity for a faded look
    sk.rpc("inspector.set", {property = "opacity", value = 0.85})
end
```

### Export Individual Clips

```lua
-- Export all clips individually with effects baked in
sk.rpc("timeline.batchExport", {})

-- Or just selected clips
sk.rpc("timeline.batchExport", {scope = "selected"})
```

### Music-Driven Montage

```lua
-- Detect beats in a music file
local beats = sk.rpc("beats.detect", {
    file_path = "/path/to/song.mp3",
    sensitivity = 0.7
})

-- Add markers at every beat
if beats.beats then
    sk.rpc("timeline.addMarkers", {times = beats.beats})
end

-- Or auto-assemble a montage from beats + clips
sk.rpc("montage.auto", {
    music_path = "/path/to/song.mp3",
    style = "energetic"
})
```

### Automated Rough Cut from Transcript

```lua
-- Transcribe the timeline
sk.rpc("transcript.open", {})

-- Wait for transcription to finish
sk.sleep(5)

-- Remove all silences over 0.5 seconds
sk.rpc("transcript.deleteSilences", {min_duration = 0.5})

-- Remove filler words
local transcript = sk.rpc("transcript.getState", {})
-- ... search and remove "um", "uh", etc.
```

### Screenshot Timeline State

```lua
-- Capture viewer frame at each clip
local state = sk.clips()
local items = state.items or {}

for i, clip in ipairs(items) do
    sk.seek(clip.start + 0.5)  -- half second into each clip
    sk.rpc("viewer.capture", {
        path = string.format("/tmp/frame_%03d.png", i)
    })
end
sk.log("Captured " .. #items .. " frames")
```

### Project Stats Reporter (Live Coding)

Save to `auto/stats.lua` — runs on every save:

```lua
local pos = sk.position()
local state = sk.clips()
local items = state.items or {}

local total_dur = 0
local clip_count = 0
for _, clip in ipairs(items) do
    if clip.duration then
        total_dur = total_dur + clip.duration
        clip_count = clip_count + 1
    end
end

sk.log(string.format(
    "[Stats] %d clips | %.1fs total | playhead %.1fs | %s",
    clip_count,
    total_dur,
    pos.seconds or 0,
    pos.isPlaying and "PLAYING" or "stopped"
))
```

### Custom Speed Ladder

```lua
-- Step through clips and apply different speeds
local speeds = {1.0, 0.5, 2.0, 0.25, 4.0}
local state = sk.clips()
local items = state.items or {}

for i, clip in ipairs(items) do
    local speed = speeds[((i - 1) % #speeds) + 1]
    sk.seek(clip.start + 0.01)
    sk.select_clip()

    if speed == 0.5 then
        sk.timeline("retimeSlow50")
    elseif speed == 0.25 then
        sk.timeline("retimeSlow25")
    elseif speed == 2.0 then
        sk.timeline("retimeFast2x")
    elseif speed == 4.0 then
        sk.timeline("retimeFast4x")
    end
end
```

### Debug: Inspect FCP Internals

```lua
-- What class is the current sequence?
local r = sk.eval("NSApp.delegate.activeEditorContainer")
print(r.class, r.result)

-- How many classes does FCP have?
local classes = sk.rpc("system.getClasses", {filter = "FF"})
print("Flexo classes:", #(classes.classes or {}))

-- Trace a method to see when it's called
sk.rpc("debug.traceMethod", {
    action = "add",
    className = "FFAnchoredTimelineModule",
    selector = "blade:",
    logStack = true
})
-- ... now blade in FCP and check the trace log
sk.rpc("debug.traceMethod", {action = "getLog", limit = 5})
```

---

## Appendix: All Timeline Actions

Every string below can be passed to `sk.timeline(action)`:

**Blade:** blade, bladeAll

**Markers:** addMarker, addTodoMarker, addChapterMarker, deleteMarker, nextMarker,
previousMarker, deleteMarkersInSelection

**Transitions:** addTransition

**Navigation:** nextEdit, previousEdit, selectClipAtPlayhead, selectToPlayhead

**Selection:** selectAll, deselectAll

**Edit:** delete, cut, copy, paste, undo, redo, pasteAsConnected, replaceWithGap,
copyTimecode

**Edit Modes:** connectToPrimaryStoryline, insertEdit, appendEdit, overwriteEdit

**Effects:** pasteEffects, pasteAttributes, removeAttributes, copyAttributes,
removeEffects

**Insert:** insertGap, insertPlaceholder, addAdjustmentClip

**Trim:** trimToPlayhead, extendEditToPlayhead, trimStart, trimEnd, joinClips,
nudgeLeft, nudgeRight, nudgeUp, nudgeDown

**Color:** addColorBoard, addColorWheels, addColorCurves, addColorAdjustment,
addHueSaturation, addEnhanceLightAndColor, balanceColor, matchColor,
addMagneticMask, smartConform

**Volume:** adjustVolumeUp, adjustVolumeDown

**Audio:** expandAudio, expandAudioComponents, addChannelEQ, enhanceAudio,
matchAudio, detachAudio

**Titles:** addBasicTitle, addBasicLowerThird

**Speed:** retimeNormal, retimeFast2x, retimeFast4x, retimeFast8x, retimeFast20x,
retimeSlow50, retimeSlow25, retimeSlow10, retimeReverse, retimeHold, freezeFrame,
retimeBladeSpeed, retimeSpeedRampToZero, retimeSpeedRampFromZero

**Keyframes:** addKeyframe, deleteKeyframes, nextKeyframe, previousKeyframe

**Rating:** favorite, reject, unrate

**Range:** setRangeStart, setRangeEnd, clearRange, setClipRange

**Clip Ops:** solo, disable, createCompoundClip, autoReframe, breakApartClipItems,
synchronizeClips, openClip, renameClip, changeDuration

**Storyline:** createStoryline, liftFromPrimaryStoryline,
overwriteToPrimaryStoryline, collapseToConnectedStoryline

**Audition:** createAudition, finalizeAudition, nextAuditionPick, previousAuditionPick

**Captions:** addCaption, splitCaption, resolveOverlaps

**Multicam:** createMulticamClip

**View:** zoomToFit, zoomIn, zoomOut, verticalZoomToFit, toggleSnapping,
toggleSkimming, toggleInspector, toggleTimeline, toggleTimelineIndex

**Project:** duplicateProject, snapshotProject, projectProperties, closeLibrary

**Render:** renderSelection, renderAll

**Export:** exportXML, shareSelection

**Find:** find, findAndReplaceTitle

**Reveal:** revealInBrowser, revealInFinder

## Appendix: All Playback Actions

Every string below can be passed to `sk.playback(action)`:

playPause, goToStart, goToEnd, nextFrame, prevFrame, nextFrame10, prevFrame10,
playAroundCurrent
