--[[
  Marker / Clip Report
  ────────────────────
  Prints a table of every item on the timeline with its position and
  duration. Useful for verifying edits or building a paper cut.

  HOW TO USE:
    dofile("examples/marker_report.lua")

  Output looks like:
    Timeline: 5 items
    --------------------------------------------------
     1. Interview_A.mov                0.00s  (12.50s)
     2. B-Roll_1.mov                  12.50s  ( 3.20s)
     ...

  PATTERNS USED:
    - require("skutil") for portable time extraction
    - sk.clips() to fetch the full clip list
    - Normalizing the response shape (clips.items vs flat array)
]]

local u = require("skutil")

local clips = sk.clips()
if type(clips) ~= "table" then
    print("No timeline data")
    return
end

-- Normalize: some bridge versions wrap the array in {items = {...}}
local items = clips.items or clips
print(string.format("Timeline: %d items", #items))
print(string.rep("-", 50))

for i, clip in ipairs(items) do
    -- Prefer the human-readable name; fall back to type or ObjC class
    local name = clip.name or clip.type or clip.class or "unknown"
    local start = u.clip_start(clip)
    local dur = u.clip_duration(clip)
    print(string.format("%2d. %-30s %6.2fs  (%.2fs)", i, name, start, dur))
end
