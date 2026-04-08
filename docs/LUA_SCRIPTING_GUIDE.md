# SpliceKit Lua Scripting Guide

A hands-on guide for writing your own Lua scripts to automate Final Cut Pro.
Covers everything from "Hello World" to building multi-step production pipelines.
Read this after skimming the [SDK Reference](LUA_SDK_REFERENCE.md) for the API surface.

---

## Table of Contents

1. [Your First Script](#1-your-first-script)
2. [Understanding the Data Model](#2-understanding-the-data-model)
3. [Working with Clips](#3-working-with-clips)
4. [The skutil Library](#4-the-skutil-library)
5. [Building Reusable Modules](#5-building-reusable-modules)
6. [Persisting Data to Disk](#6-persisting-data-to-disk)
7. [Async Operations & Polling](#7-async-operations--polling)
8. [Data-Driven Workflows](#8-data-driven-workflows)
9. [Keyframe Animation](#9-keyframe-animation)
10. [Clip Iteration Patterns](#10-clip-iteration-patterns)
11. [Error Handling & Recovery](#11-error-handling--recovery)
12. [Statistics & Reporting](#12-statistics--reporting)
13. [Performance & Optimization](#13-performance--optimization)
14. [Multi-Step Pipelines](#14-multi-step-pipelines)
15. [Anatomy of Every Example Script](#15-anatomy-of-every-example-script)

---

## 1. Your First Script

### The REPL

Open the Lua REPL inside FCP: **Ctrl+Option+L** (or Enhancements > Lua REPL).

Type a line and press Enter:

```lua
> sk.position()
```

The REPL returns whatever you type as an expression. Multi-statement code works too:

```lua
> for i = 1, 3 do sk.next_frame() end
```

### Your First File

Create a file anywhere — let's use the scripts directory:

```
~/Library/Application Support/SpliceKit/lua/my_first_script.lua
```

```lua
-- my_first_script.lua
local pos = sk.position()
print("Playhead is at " .. pos.seconds .. " seconds")
print("Frame rate: " .. pos.frameRate .. " fps")
```

Run it from the REPL:

```lua
> dofile("my_first_script.lua")
Playhead is at 12.50 seconds
Frame rate: 24.0 fps
```

Or use the JSON-RPC method:

```json
{"method": "lua.executeFile", "params": {"path": "my_first_script.lua"}}
```

### Live Coding

Save a file to the `auto/` subdirectory and it re-executes every time you save:

```
~/Library/Application Support/SpliceKit/lua/auto/monitor.lua
```

```lua
-- Runs every time you save this file
sk.log("Clips: " .. #(sk.clips().items or {}) .. " | " .. os.date())
```

Open the file in your editor, make a change, save — the output appears in the
SpliceKit log instantly. This is the fastest way to iterate.

---

## 2. Understanding the Data Model

### What `sk.position()` Returns

```lua
local pos = sk.position()
-- pos.seconds    → 12.5        (playhead position in seconds)
-- pos.frameRate  → 24.0        (timeline frame rate)
-- pos.isPlaying  → false       (whether playback is active)
-- pos.rate       → 0.0         (current playback speed, 0 when stopped)
```

Note: `pos.seconds` is a plain number. Other time fields in FCP data may be
**CMTime tables** (see below).

### CMTime Tables

FCP stores time values internally as `{value, timescale}` pairs. When you get
clip data from `sk.rpc("timeline.getDetailedState", {})`, time fields come back
as tables:

```lua
local state = sk.rpc("timeline.getDetailedState", {})
local clip = state.items[1]

-- These are TABLES, not numbers:
print(type(clip.duration))     -- "table"
print(type(clip.startTime))    -- "table"

-- Inside the table:
-- clip.duration = {seconds = 5.0, value = 120, timescale = 24}
-- clip.startTime = {seconds = 0.0, value = 0, timescale = 24}
```

**Never assume a time field is a number.** Always use the `skutil` library
(Section 4) or check the type:

```lua
local function safe_seconds(val)
    if type(val) == "number" then return val end
    if type(val) == "table" then return val.seconds or 0 end
    return 0
end
```

### Clip Fields

Clips from `getDetailedState` have these fields:

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Clip name (may contain unicode) |
| `class` | string | ObjC class (e.g. `FFAnchoredMediaComponent`) |
| `duration` | CMTime table | Clip length |
| `startTime` | CMTime table | Position on timeline |
| `endTime` | CMTime table | End position |
| `lane` | number | 0 = primary storyline, 1+ = above, -1 = below |
| `handle` | string | ObjC handle ID (`obj_16`) |
| `selected` | number | 1 if selected |
| `index` | number | Position in parent container |

Some responses use different field names (`start` vs `startTime`, `offset`, `type` vs `class`).
This is why `skutil` exists — it handles all the variations.

### The Two State Methods

| Method | Speed | Detail Level |
|--------|-------|-------------|
| `sk.clips()` | Fast | Basic: sequence name, hasItems, playhead |
| `sk.rpc("timeline.getDetailedState", {})` | Slower | Full: every clip with handles, timing, lanes |

Use `sk.clips()` for quick checks. Use `getDetailedState` when you need to
iterate clips with timing data.

---

## 3. Working with Clips

### The Select-Then-Act Pattern

FCP requires a clip to be **selected** before you can modify it. Almost every
editing operation follows this pattern:

```lua
-- 1. Navigate to the clip
sk.seek(clip_start + 0.01)   -- +0.01 to ensure we're inside the clip

-- 2. Select it
sk.select_clip()

-- 3. Act on it
sk.timeline("addColorBoard")
```

The `+0.01` offset is important — seeking to the exact clip boundary may
select the wrong clip or the transition between clips.

### Selecting Connected Clips

Connected clips live above or below the primary storyline in lanes:

```lua
-- Select clip in lane 1 (first above primary)
sk.rpc("timeline.selectClipInLane", {lane = 1})

-- Select clip in lane -1 (first below primary)
sk.rpc("timeline.selectClipInLane", {lane = -1})

-- Select primary storyline clip (same as sk.select_clip())
sk.rpc("timeline.selectClipInLane", {lane = 0})
```

### Reading Inspector Properties

After selecting a clip, you can read and write its properties:

```lua
sk.select_clip()

-- Read all properties
local props = sk.rpc("inspector.get", {})

-- Read a specific section
local transform = sk.rpc("inspector.get", {section = "transform"})

-- Write a property
sk.rpc("inspector.set", {property = "opacity", value = 0.5})
sk.rpc("inspector.set", {property = "positionX", value = 100.0})
```

---

## 4. The skutil Library

Every script that touches clip data should use `skutil`. It handles all the
quirks of FCP's internal data formats.

### Loading

```lua
local u = require("skutil")
```

This works because `~/Library/Application Support/SpliceKit/lua/lib/` is on
Lua's `package.path`.

### Functions

```lua
-- Convert anything to seconds (handles numbers, CMTime tables, nil)
u.seconds(5.0)                          -- → 5.0
u.seconds({seconds=3.2, value=96})      -- → 3.2
u.seconds(nil)                          -- → 0

-- Get clip timing (handles startTime, start, offset field names)
u.clip_start(clip)                      -- → seconds
u.clip_duration(clip)                   -- → seconds
u.clip_end(clip)                        -- → seconds

-- Get total timeline duration (makes an RPC call)
u.timeline_duration()                   -- → seconds

-- Check if clip is a real clip (not a gap or transition)
u.is_real_clip(clip)                    -- → true/false

-- Format timecode
u.timecode(3723.5, 24)                  -- → "01:02:03:12"
```

### Why It Matters

Without `skutil`:

```lua
-- WRONG: clip.duration is a table, not a number
if clip.duration < 1.0 then  -- ERROR: attempt to compare table with number
```

With `skutil`:

```lua
-- CORRECT: u.clip_duration() always returns a number
if u.clip_duration(clip) < 1.0 then  -- works perfectly
```

**Rule: Always use `u.clip_start()`, `u.clip_duration()`, and `u.seconds()`
when working with clip timing data.**

---

## 5. Building Reusable Modules

### The Module Pattern

Scripts that provide reusable functions should follow this pattern:

```lua
--[[ my_tool.lua — description ]]

local u = require("skutil")   -- load shared utilities

local tool = {}               -- create a local table for your functions

function tool.do_something()
    -- your code here
end

function tool.do_another_thing(arg1, arg2)
    -- your code here
end

-- Register globally so it persists across REPL calls
_G.tool = tool

-- Print usage help when loaded
print("My Tool loaded. Commands:")
print("  tool.do_something()")
print("  tool.do_another_thing(x, y)")

return tool
```

Then load it:

```lua
> dofile("examples/my_tool.lua")
My Tool loaded. Commands:
  tool.do_something()
  tool.do_another_thing(x, y)

> tool.do_something()
```

### Why `_G.tool = tool`?

Without it, the `tool` table exists only during the `dofile` call. After the
file finishes executing, `tool` goes out of scope and gets garbage collected.
Setting it as a global keeps it alive between REPL calls.

### The `lib/` Directory for Shared Code

Put reusable modules in `lib/` so they can be loaded with `require()`:

```
~/Library/Application Support/SpliceKit/lua/lib/my_helpers.lua
```

```lua
-- lib/my_helpers.lua
local M = {}

function M.blade_at_times(times)
    for _, t in ipairs(times) do
        sk.seek(t)
        sk.blade()
    end
    return #times
end

return M
```

Use from any script:

```lua
local helpers = require("my_helpers")
helpers.blade_at_times({2, 4, 6, 8})
```

---

## 6. Persisting Data to Disk

### The Serialize Pattern

Many scripts need to save data between sessions (presets, snapshots, history).
Lua doesn't have built-in JSON, but you can serialize tables as Lua code:

```lua
local function serialize(val, indent)
    indent = indent or ""
    local t = type(val)
    if t == "nil" then return "nil"
    elseif t == "boolean" then return tostring(val)
    elseif t == "number" then return tostring(val)
    elseif t == "string" then return string.format("%q", val)
    elseif t == "table" then
        local parts = {}
        local ni = indent .. "  "
        for k, v in pairs(val) do
            local ks = type(k) == "string"
                and string.format("[%q]", k) or ("[" .. tostring(k) .. "]")
            table.insert(parts, ni .. ks .. " = " .. serialize(v, ni))
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
    return "nil"
end
```

### Save and Load

```lua
local SAVE_DIR = os.getenv("HOME") ..
    "/Library/Application Support/SpliceKit/lua"
local SAVE_FILE = SAVE_DIR .. "/my_data.lua"

-- Save
local function save_data(data)
    local f = io.open(SAVE_FILE, "w")
    if not f then return false end
    f:write(serialize(data))
    f:close()
    return true
end

-- Load
local function load_data()
    local f = io.open(SAVE_FILE, "r")
    if not f then return {} end
    local code = f:read("*a")
    f:close()
    local fn = load("return " .. code)
    if fn then
        local ok, result = pcall(fn)
        if ok and type(result) == "table" then return result end
    end
    return {}
end
```

### Used By

This exact pattern is used in `state_save_restore.lua`, `keyword_manager.lua`,
and `project_snapshot_diff.lua`. Each stores its data as a Lua table in a `.lua`
file under the scripts directory.

---

## 7. Async Operations & Polling

Some operations take time (transcription, beat detection, scene analysis).
You need to poll for completion.

### The Polling Pattern

```lua
local function wait_for(check_fn, timeout, interval)
    interval = interval or 2    -- check every 2 seconds
    local elapsed = 0
    while elapsed < timeout do
        if check_fn() then return true end
        sk.sleep(interval)
        elapsed = elapsed + interval
    end
    return false  -- timed out
end
```

### Example: Wait for Transcription

```lua
sk.rpc("transcript.open", {})

local ready = wait_for(function()
    local state = sk.rpc("transcript.getState", {})
    return state and state.words and #state.words > 0
end, 120)  -- 2-minute timeout

if ready then
    print("Transcription done!")
else
    print("Timed out waiting for transcription")
end
```

### Example: Wait for Beat Detection

```lua
local beats = sk.rpc("beats.detect", {
    file_path = "/path/to/song.mp3",
    sensitivity = 0.7
})
-- beats.detect is synchronous — it blocks until done
-- No polling needed, but it can take 10-30 seconds
```

### Progress Logging

For long operations, log progress so the user knows something is happening:

```lua
for i = 1, max_attempts do
    sk.sleep(2)
    local state = sk.rpc("transcript.getState", {})
    if state and state.words and #state.words > 0 then
        return true
    end
    -- Log every 30 seconds
    if i % 15 == 0 then
        sk.log("Still waiting for transcription... (" .. (i * 2) .. "s)")
    end
end
```

---

## 8. Data-Driven Workflows

Instead of hardcoding edit decisions in your script, define them as data and
write code that executes the data. This makes scripts reusable and composable.

### CSV-Based Edit Decisions

The `conform_tool.lua` script demonstrates this pattern:

```lua
local csv = [[
action,time,name
blade,5.0,cut1
marker,10.0,intro_end
chapter,60.0,Topic 1
speed,120.0,0.5
blade,180.0,cut2
]]

conform.apply_edl(csv)
```

### Parsing CSV in Lua

```lua
function parse_csv(text, has_header)
    local lines = {}
    for line in text:gmatch("[^\n]+") do
        table.insert(lines, line)
    end

    local headers = nil
    local start_idx = 1

    if has_header ~= false and #lines > 0 then
        headers = {}
        for field in lines[1]:gmatch("[^,]+") do
            table.insert(headers, field:match("^%s*(.-)%s*$"))  -- trim
        end
        start_idx = 2
    end

    local records = {}
    for i = start_idx, #lines do
        local fields = {}
        local idx = 1
        for field in lines[i]:gmatch("[^,]+") do
            field = field:match("^%s*(.-)%s*$")
            local num = tonumber(field)
            if headers then
                fields[headers[idx]] = num or field
            else
                fields[idx] = num or field
            end
            idx = idx + 1
        end
        table.insert(records, fields)
    end

    return records
end
```

### Configuration Tables

Define configurable behavior as tables, not hardcoded values:

```lua
-- GOOD: data-driven
local looks = {
    cinematic = {
        name = "Cinematic",
        crop_top = 0.06,
        crop_bottom = 0.06,
        opacity = 0.95,
    },
    vintage = {
        name = "Vintage",
        opacity = 0.88,
    },
}

-- Apply by name
function apply_look(name)
    local look = looks[name]
    if look.crop_top then
        sk.rpc("inspector.set", {property = "cropTop", value = look.crop_top})
    end
    -- etc.
end
```

### Format Definitions

The `social_media_toolkit.lua` uses this for multi-format export:

```lua
local formats = {
    reels = {name = "Instagram Reels", max_duration = 60, caption_style = "social_reels"},
    tiktok = {name = "TikTok", max_duration = 180, caption_style = "bold_pop"},
    shorts = {name = "YouTube Shorts", max_duration = 60, caption_style = "clean_minimal"},
}

-- Same code works for every format
function prepare(format_id)
    local fmt = formats[format_id]
    -- generic code that uses fmt.max_duration, fmt.caption_style, etc.
end
```

---

## 9. Keyframe Animation

### Adding Keyframes

Navigate to the time, select the clip, add keyframe, set value:

```lua
sk.seek(time)
sk.select_clip()
sk.timeline("addKeyframe")
sk.rpc("inspector.set", {property = "opacity", value = 0.5})
```

### Multi-Keyframe Animation

Define keyframes as a table and loop through them:

```lua
local keyframes = {
    {time = 0.0, value = 0.0},   -- start invisible
    {time = 0.5, value = 1.0},   -- fade in over 0.5s
    {time = 4.5, value = 1.0},   -- hold visible
    {time = 5.0, value = 0.0},   -- fade out
}

local clip_start = 10.0  -- absolute timeline position of clip

for _, kf in ipairs(keyframes) do
    sk.seek(clip_start + kf.time)
    sk.select_clip()
    sk.timeline("addKeyframe")
    sk.rpc("inspector.set", {property = "opacity", value = kf.value})
end
```

### Percentage-Based Keyframes

Scale keyframe times to the clip's actual duration:

```lua
-- Keyframes defined as percentages (0.0 to 1.0)
local template = {
    {time = 0.0,  value = 0.0},   -- start
    {time = 0.1,  value = 1.0},   -- 10% in: fully visible
    {time = 0.9,  value = 1.0},   -- 90% in: still visible
    {time = 1.0,  value = 0.0},   -- end: invisible
}

-- Scale to actual clip duration
local clip_dur = u.clip_duration(clip)
for _, kf in ipairs(template) do
    local actual_time = clip_start + (kf.time * clip_dur)
    sk.seek(actual_time)
    sk.select_clip()
    sk.timeline("addKeyframe")
    sk.rpc("inspector.set", {property = "opacity", value = kf.value})
end
```

### Ken Burns Effect

Combine scale + position keyframes for slow zoom with pan:

```lua
local function ken_burns(clip_start, clip_dur, zoom_start, zoom_end, pan_x, pan_y)
    -- Start keyframe
    sk.seek(clip_start)
    sk.select_clip()
    sk.timeline("addKeyframe")
    sk.rpc("inspector.set", {property = "scaleX", value = zoom_start / 100})
    sk.rpc("inspector.set", {property = "scaleY", value = zoom_start / 100})
    sk.rpc("inspector.set", {property = "positionX", value = 0})
    sk.rpc("inspector.set", {property = "positionY", value = 0})

    -- End keyframe
    sk.seek(clip_start + clip_dur - 0.05)
    sk.select_clip()
    sk.timeline("addKeyframe")
    sk.rpc("inspector.set", {property = "scaleX", value = zoom_end / 100})
    sk.rpc("inspector.set", {property = "scaleY", value = zoom_end / 100})
    sk.rpc("inspector.set", {property = "positionX", value = pan_x})
    sk.rpc("inspector.set", {property = "positionY", value = pan_y})
end

-- Usage: slow zoom from 100% to 120% with slight rightward pan
ken_burns(clip_start, clip_dur, 100, 120, 30, 0)
```

---

## 10. Clip Iteration Patterns

### Forward Iteration (Reading)

Safe for reading state. Do not modify the timeline during forward iteration.

```lua
local u = require("skutil")
local state = sk.rpc("timeline.getDetailedState", {})
local items = state.items or {}

for i, clip in ipairs(items) do
    if u.is_real_clip(clip) then
        print(i, clip.name, u.clip_start(clip), u.clip_duration(clip))
    end
end
```

### Reverse Iteration (Deleting)

When deleting clips, work backwards. Otherwise, deleting clip #3 shifts clip #4
into position #3, and you skip it or hit the wrong clip.

```lua
-- CORRECT: reverse iteration for deletion
local to_remove = {}
for _, clip in ipairs(items) do
    if u.clip_duration(clip) < 0.1 then
        table.insert(to_remove, clip)
    end
end

-- Sort by start time descending
table.sort(to_remove, function(a, b)
    return u.clip_start(a) > u.clip_start(b)
end)

-- Delete from end to start
for _, clip in ipairs(to_remove) do
    sk.seek(u.clip_start(clip) + 0.01)
    sk.select_clip()
    sk.timeline("delete")
end
```

### Lane-Based Filtering

Separate clips by storyline lane:

```lua
local primary = {}    -- lane 0
local connected = {}  -- lane != 0

for _, clip in ipairs(items) do
    if not u.is_real_clip(clip) then goto skip end

    if (clip.lane or 0) == 0 then
        table.insert(primary, clip)
    else
        table.insert(connected, clip)
    end

    ::skip::
end
```

### Type-Based Filtering

Filter by clip class/type:

```lua
for _, clip in ipairs(items) do
    local class = clip.class or clip.type or ""

    if class:find("Transition") then
        -- it's a transition
    elseif class:find("Gap") then
        -- it's a gap
    elseif class:find("Title") or class:find("Generator") then
        -- it's a title or generator
    else
        -- it's a media clip
    end
end
```

### Skip Logic with goto

Lua's `goto` with labels is the cleanest way to skip items in a loop:

```lua
for _, clip in ipairs(items) do
    if not u.is_real_clip(clip) then goto continue end
    if u.clip_duration(clip) < 0.5 then goto continue end

    -- ... process clip ...

    ::continue::
end
```

---

## 11. Error Handling & Recovery

### Safe RPC Calls

RPC calls return nil or error tables when they fail. Always check:

```lua
local result = sk.rpc("effects.apply", {name = "Nonexistent Effect"})
if result and result.error then
    print("Effect failed: " .. result.error)
end
```

### pcall for Critical Operations

Wrap operations that might fail in `pcall`:

```lua
local ok, err = pcall(function()
    sk.seek(time)
    sk.select_clip()
    sk.timeline("addColorBoard")
end)
if not ok then
    sk.log("Failed at " .. time .. ": " .. tostring(err))
end
```

### Save and Restore Playhead

Always save the playhead position before batch operations and restore it after:

```lua
local original_pos = sk.position().seconds or 0

-- ... do a bunch of seeks and edits ...

sk.seek(original_pos)  -- restore playhead
```

### Graceful Degradation

When a feature isn't available, skip it instead of crashing:

```lua
-- Try to apply effect, but don't die if it fails
local fx_result = sk.rpc("effects.apply", {name = "Gaussian Blur"})
if fx_result and not fx_result.error then
    sk.log("Effect applied")
else
    sk.log("Effect not available, skipping")
end
```

### Undo as Safety Net

Tell users they can undo:

```lua
print(string.format("Modified %d clips (undo with sk.undo())", count))
```

For critical operations, you can implement multi-level undo:

```lua
-- Undo everything we just did
for i = 1, num_operations do
    sk.undo()
end
```

---

## 12. Statistics & Reporting

### Collecting Stats

Accumulate stats during processing:

```lua
local stats = {
    processed = 0,
    skipped = 0,
    errors = 0,
    total_duration = 0,
}

for _, clip in ipairs(items) do
    local dur = u.clip_duration(clip)
    if dur < 0.1 then
        stats.skipped = stats.skipped + 1
        goto continue
    end

    -- process...
    stats.processed = stats.processed + 1
    stats.total_duration = stats.total_duration + dur

    ::continue::
end
```

### Formatted Reports

Use box-drawing characters for professional-looking output:

```lua
print("╔════════════════════════════════════╗")
print("║          REPORT TITLE              ║")
print("╠════════════════════════════════════╣")
print(string.format("║  Clips:    %4d                    ║", stats.processed))
print(string.format("║  Duration: %6.1fs                 ║", stats.total_duration))
print("╚════════════════════════════════════╝")
```

### Text Histograms

Visualize distributions with text bars:

```lua
local buckets = {12, 45, 23, 8, 3}  -- counts per category
local labels = {"<1s", "1-3s", "3-10s", "10-30s", ">30s"}
local max_count = math.max(table.unpack(buckets))

for i, count in ipairs(buckets) do
    local bar_len = max_count > 0 and math.floor(count / max_count * 25) or 0
    print(string.format("  %-6s  %s %d",
        labels[i], string.rep("#", bar_len), count))
end
```

Output:
```
  <1s    ######ÊÊ 12
  1-3s   ######################### 45
  3-10s  ############ 23
  10-30s #### 8
  >30s   # 3
```

### Progress Logging for Long Operations

```lua
for i, clip in ipairs(items) do
    -- process clip...

    -- Log every 10 clips
    if i % 10 == 0 then
        sk.log(string.format("[MyScript] %d/%d clips processed...", i, #items))
    end
end
```

---

## 13. Performance & Optimization

### Minimize RPC Calls

Each `sk.rpc()` call crosses from the Lua queue to the main thread and back.
This takes ~1-5ms per call. For batch operations, this adds up.

```lua
-- SLOW: 3 RPC calls per clip
for _, clip in ipairs(items) do
    sk.seek(u.clip_start(clip))
    sk.select_clip()
    sk.timeline("addColorBoard")
end

-- FASTER: batch blading uses one call for all times
sk.rpc("timeline.addMarkers", {times = all_times})  -- 1 RPC call
```

### Use Batch Operations When Available

```lua
-- Instead of individual marker adds:
for _, t in ipairs(times) do
    sk.seek(t)
    sk.add_marker()
end

-- Use the batch endpoint:
sk.rpc("timeline.addMarkers", {times = times})
```

### Cache Timeline State

Don't call `getDetailedState` repeatedly in a loop:

```lua
-- BAD: calls RPC inside every iteration
for i = 1, 100 do
    local state = sk.rpc("timeline.getDetailedState", {})
    -- ...
end

-- GOOD: cache the state
local state = sk.rpc("timeline.getDetailedState", {})
local items = state.items or {}
for _, clip in ipairs(items) do
    -- ...
end
```

### Sampling for Change Detection

If you're monitoring for changes (like `edit_timer.lua`), don't check every
call — sample periodically:

```lua
local last_check = 0
local CHECK_INTERVAL = 5  -- seconds

-- Only check if enough time has passed
local now = os.time()
if now - last_check < CHECK_INTERVAL then
    return  -- skip this run
end
last_check = now
```

### Sleep Judiciously

`sk.sleep()` blocks the Lua queue. Use it only when waiting for async operations.
Never use it as a substitute for proper polling:

```lua
-- BAD: arbitrary sleep and hope it's ready
sk.rpc("transcript.open", {})
sk.sleep(30)

-- GOOD: poll until ready
sk.rpc("transcript.open", {})
wait_for(function()
    local state = sk.rpc("transcript.getState", {})
    return state and state.words and #state.words > 0
end, 120)
```

---

## 14. Multi-Step Pipelines

### Pipeline Architecture

Complex scripts chain multiple operations. Structure them as numbered steps
with clear logging:

```lua
local function run_pipeline()
    local stats = {started_at = os.time()}

    -- Step 1
    sk.log("[Pipeline] Step 1/4: Transcribing...")
    -- ... transcription code ...

    -- Step 2
    sk.log("[Pipeline] Step 2/4: Removing silences...")
    -- ... silence removal ...

    -- Step 3
    sk.log("[Pipeline] Step 3/4: Adding transitions...")
    -- ... transition code ...

    -- Step 4
    sk.log("[Pipeline] Step 4/4: Generating captions...")
    -- ... caption code ...

    -- Report
    local elapsed = os.time() - stats.started_at
    sk.log(string.format("[Pipeline] Done in %ds", elapsed))
    return stats
end
```

### Skip Options

Let users skip steps they don't need:

```lua
function produce(title, options)
    options = options or {}

    if not options.skip_transcribe then
        -- step 1: transcribe
    end

    if not options.skip_cleanup then
        -- step 2: clean audio
    end

    -- step 3: always runs
    -- ...
end

-- Usage:
produce("My Video", {skip_transcribe = true})
```

### Pipeline with Full Produce Function

See `auto_editor.lua` and `podcast_producer.lua` for complete pipeline
implementations. Both follow this structure:

1. **Measure** — record initial state
2. **Process** — multi-step transformation
3. **Report** — show what changed
4. **Return** — stats table for programmatic use

---

## 15. Anatomy of Every Example Script

### Starter Scripts

| Script | Lines | Pattern | What to Learn |
|--------|-------|---------|---------------|
| `live_status.lua` | 13 | Auto-run monitor | Minimal auto/ script, `sk.log()` |
| `marker_report.lua` | 20 | Read + print | Simple clip iteration, `skutil` usage |
| `blade_every_n_seconds.lua` | 22 | Timed loop | `sk.seek()` + `sk.blade()` in a while loop |
| `color_grade_all.lua` | 26 | Batch apply | Select-then-act pattern on every clip |
| `select_every_other.lua` | 27 | Filtered delete | Reverse iteration for safe deletion |

### Workflow Automations

| Script | Lines | Pattern | What to Learn |
|--------|-------|---------|---------------|
| `rough_cut_from_transcript.lua` | 71 | Linear pipeline | Polling for async operations, transcript API |
| `batch_color_match.lua` | 90 | Batch with config | Configuration block, skip logic, progress logging |
| `edit_timer.lua` | 130 | Persistent monitor | Global state across calls, sampling, delta detection |
| `music_video_editor.lua` | 138 | Beat-synced | Beat detection, batch blading, alternating effects |
| `audio_ducking.lua` | 147 | Lane analysis | Lane separation, temporal keyframe generation, merging |
| `timeline_cleaner.lua` | 150 | Analysis + fix | Issue categorization, two-phase (report then fix) |
| `watch_and_import.lua` | 155 | File system | ObjC bridge for NSFileManager, dialog automation |
| `batch_export_clips.lua` | 165 | Dry run mode | Naming schemes, DRY_RUN flag, range marking |
| `multicam_angle_switcher.lua` | 178 | Mode selection | Multiple algorithms, menu execution for angles |
| `scene_detective.lua` | 188 | Detection + report | Scene detection, thumbnail capture, visual report |

### Toolkit Scripts (Load Once, Use from REPL)

| Script | Lines | Pattern | What to Learn |
|--------|-------|---------|---------------|
| `state_save_restore.lua` | 193 | Module + persist | Serialize/deserialize, file I/O, global registration |
| `social_media_toolkit.lua` | 200 | Format-driven | Declarative format definitions, format-agnostic code |
| `debug_timeline_inspector.lua` | 235 | Introspection | Inspector reading, class hierarchy, debug presets |
| `keyword_manager.lua` | 285 | CRUD + rules | Preset slots, rule-based auto-tagging, persistence |
| `project_snapshot_diff.lua` | 295 | Diff algorithm | Snapshot capture, key-based clip matching, diff report |

### Complex Pipelines

| Script | Lines | Pattern | What to Learn |
|--------|-------|---------|---------------|
| `auto_editor.lua` | 175 | Full pipeline | 6-step orchestration, wait_for polling, stats tracking |
| `podcast_producer.lua` | 265 | Production chain | Speaker labeling, chapter generation, multi-format export |
| `fx_designer.lua` | 300 | Parametric FX | Declarative looks, keyframe interpolation, Ken Burns |
| `conform_tool.lua` | 315 | Data-driven | CSV parsing, timecode parsing, EDL execution, storyboard |
| `timeline_arranger.lua` | 310 | Structural | Reverse/shuffle/extract, Fisher-Yates, pacing analysis |

### Reading Order for Learning

If you're new to SpliceKit Lua scripting, read the scripts in this order:

1. **`live_status.lua`** — understand `sk.position()` and `sk.log()`
2. **`marker_report.lua`** — understand clip iteration and `skutil`
3. **`blade_every_n_seconds.lua`** — understand seek + action loops
4. **`batch_color_match.lua`** — understand config blocks and skip logic
5. **`state_save_restore.lua`** — understand modules and persistence
6. **`timeline_cleaner.lua`** — understand analysis and reporting
7. **`auto_editor.lua`** — understand multi-step pipelines
8. **`conform_tool.lua`** — understand data-driven workflows
9. **`fx_designer.lua`** — understand keyframe animation
10. **`timeline_arranger.lua`** — understand structural transforms

After these 10, you'll have seen every pattern used across all 25 scripts.

---

## Quick Reference: Common Patterns

### Get all real clips with timing

```lua
local u = require("skutil")
local state = sk.rpc("timeline.getDetailedState", {})
for _, clip in ipairs(state.items or {}) do
    if u.is_real_clip(clip) then
        local start = u.clip_start(clip)
        local dur = u.clip_duration(clip)
        -- do something with start, dur
    end
end
```

### Apply something to every clip

```lua
for _, clip in ipairs(items) do
    if not u.is_real_clip(clip) then goto skip end
    sk.seek(u.clip_start(clip) + 0.01)
    sk.select_clip()
    -- sk.timeline("addColorBoard")
    -- sk.rpc("inspector.set", {property = "opacity", value = 0.5})
    ::skip::
end
```

### Delete clips matching criteria (reverse order)

```lua
local to_remove = {}
for _, clip in ipairs(items) do
    if u.clip_duration(clip) < 0.1 then
        table.insert(to_remove, clip)
    end
end
table.sort(to_remove, function(a, b)
    return u.clip_start(a) > u.clip_start(b)
end)
for _, clip in ipairs(to_remove) do
    sk.seek(u.clip_start(clip) + 0.01)
    sk.select_clip()
    sk.timeline("delete")
end
```

### Save and restore playhead

```lua
local saved = sk.position().seconds or 0
-- ... work ...
sk.seek(saved)
```

### Poll for async completion

```lua
local ready = false
for i = 1, 60 do
    sk.sleep(2)
    local state = sk.rpc("some.method", {})
    if state and state.done then ready = true; break end
end
```

### Make a reusable module

```lua
local u = require("skutil")
local M = {}
function M.my_function(arg) --[[ ... ]] end
_G.my_module = M
print("Loaded. Use: my_module.my_function()")
return M
```

### Persist data to disk

```lua
-- Save: io.open(..., "w"), write serialize(data), close
-- Load: io.open(..., "r"), read all, load("return " .. code), pcall
```
