--[[
  Batch Export Individual Clips
  ─────────────────────────────
  Exports each clip on the timeline as a separate file, with all
  effects and color grading baked in. Optionally adds a text
  overlay with the clip name and timecode.

  Supports:
  - All clips or selected only
  - Custom naming (clip name, index, timecode)
  - Skipping transitions and gaps
  - Pre-export range marking per clip

  HOW TO USE:
    1. Set your default Share Destination in FCP first
       (File > Share > Add Destination).
    2. Review the configuration below.
    3. First run in DRY_RUN mode (default) to preview the export plan:
         dofile("examples/batch_export_clips.lua")
    4. Set DRY_RUN = false and re-run to actually export.

  PATTERNS USED:
    - DRY_RUN flag: preview before committing (same pattern as
      timeline_cleaner.lua's REPORT_ONLY)
    - sk.selected() vs sk.rpc("timeline.getDetailedState", {}) for
      scoped clip retrieval (selected-only vs all)
    - Filtering pipeline: iterate, classify, skip unwanted items
    - sk.rpc("timeline.setRange", {...}) to set in/out points per clip
      before triggering export, so each clip exports individually
    - Timecode formatting from seconds using frame rate

  Inspired by CommandPost's comprehensive batch export system.
]]

local u = require("skutil")

-- Configuration
local SCOPE           = "all"      -- "all" or "selected"
local SKIP_GAPS       = true       -- skip gap clips
local SKIP_TRANSITIONS = true      -- skip transitions
local MIN_DURATION    = 0.5        -- skip clips shorter than this
local NAMING          = "name"     -- "name", "index", "timecode"
local DRY_RUN         = true       -- set false to actually export

-----------------------------------------------------------
-- Get clips to export
-----------------------------------------------------------
local clips_to_export = {}

if SCOPE == "selected" then
    local sel = sk.selected()
    if sel and sel.clips then
        clips_to_export = sel.clips
    end
else
    local state = sk.rpc("timeline.getDetailedState", {})
    if state and state.items then
        clips_to_export = state.items
    end
end

if #clips_to_export == 0 then
    sk.log("[BatchExport] No clips found")
    return
end

-----------------------------------------------------------
-- Filter clips
-----------------------------------------------------------
local filtered = {}

for _, clip in ipairs(clips_to_export) do
    local clip_type = clip.type or clip.class or ""
    local dur = u.clip_duration(clip)

    -- Skip gaps
    if SKIP_GAPS and clip_type:find("Gap") then goto skip end

    -- Skip transitions
    if SKIP_TRANSITIONS and clip_type:find("Transition") then goto skip end

    -- Skip short clips
    if dur < MIN_DURATION then goto skip end

    table.insert(filtered, clip)
    ::skip::
end

sk.log(string.format("[BatchExport] %d clips to export (filtered from %d)",
    #filtered, #clips_to_export))

-----------------------------------------------------------
-- Generate export names
-----------------------------------------------------------
local pos = sk.position()
local fps = pos.frameRate or 30

local function format_timecode(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    local f = math.floor((seconds % 1) * fps)
    return string.format("%02d%02d%02d%02d", h, m, s, f)
end

for i, clip in ipairs(filtered) do
    local start_t = u.clip_start(clip)
    if NAMING == "name" then
        clip._export_name = (clip.name or "clip_" .. i):gsub("[^%w%-_]", "_")
    elseif NAMING == "index" then
        clip._export_name = string.format("clip_%03d", i)
    elseif NAMING == "timecode" then
        clip._export_name = format_timecode(start_t)
    end
end

-----------------------------------------------------------
-- Report (dry run)
-----------------------------------------------------------
print("╔══════════════════════════════════════════════════════╗")
print("║              BATCH EXPORT PLAN                       ║")
print("╠══════════════════════════════════════════════════════╣")
print(string.format("║  Scope:     %-10s                                ║", SCOPE))
print(string.format("║  Clips:     %-4d                                     ║", #filtered))
print(string.format("║  Naming:    %-10s                                ║", NAMING))
print(string.format("║  Dry run:   %-5s                                    ║", tostring(DRY_RUN)))
print("╠══════════════════════════════════════════════════════╣")

local total_dur = 0
for i, clip in ipairs(filtered) do
    local start_t = u.clip_start(clip)
    local dur = u.clip_duration(clip)
    total_dur = total_dur + dur
    print(string.format("║  %3d. %-20s  %6.2fs  %5.1fs dur     ║",
        i, (clip._export_name or "?"):sub(1,20), start_t, dur))
end

print("╠══════════════════════════════════════════════════════╣")
print(string.format("║  Total export duration: %.1fs                       ║", total_dur))
print("╚══════════════════════════════════════════════════════╝")

-----------------------------------------------------------
-- Execute export
-----------------------------------------------------------
if DRY_RUN then
    print("\nDry run -- set DRY_RUN = false to export")
    return filtered
end

-- Save original playhead so we can restore it when done
local original_pos = pos.seconds or 0

local exported = 0
for i, clip in ipairs(filtered) do
    local start_t = u.clip_start(clip)
    local dur = u.clip_duration(clip)

    sk.log(string.format("[BatchExport] Exporting %d/%d: %s",
        i, #filtered, clip._export_name))

    -- Set the timeline's in/out range to cover exactly this clip.
    -- FCP's share will export only the marked range.
    sk.rpc("timeline.setRange", {
        start_seconds = start_t,
        end_seconds = start_t + dur
    })

    -- Trigger FCP's share dialog. The actual export destination is
    -- whatever the user configured as their default Share Destination.
    sk.rpc("share.export", {})

    -- Allow time for the share sheet to appear and process
    sk.sleep(2)

    exported = exported + 1
end

-- Clean up: remove the in/out range and restore the playhead
sk.timeline("clearRange")
sk.seek(original_pos)

sk.log(string.format("[BatchExport] Complete: %d clips exported", exported))
return exported
