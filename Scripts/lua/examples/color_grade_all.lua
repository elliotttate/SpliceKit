--[[
  Color Grade All Clips
  ─────────────────────
  Adds a Color Board to every clip on the timeline. The Color Board
  opens FCP's color correction inspector so you can tweak color,
  saturation, and exposure per clip.

  HOW TO USE:
    1. Open a project in FCP.
    2. Run:  dofile("examples/color_grade_all.lua")
    Each clip gets a Color Board effect added. You can then adjust
    individual pucks in the inspector.

  PATTERNS USED:
    - The "seek + select + act" pattern: many FCP actions require
      the playhead to be ON a clip and that clip to be SELECTED.
    - Seeking to start + 0.01s so the playhead lands inside the clip
      (not on the exact edit point, which can be ambiguous).
    - sk.color_board() as a convenience wrapper for adding color
      correction (equivalent to timeline_action("addColorBoard")).
]]

local u = require("skutil")

sk.go_to_start()
local clips = sk.clips()

if type(clips) ~= "table" then
    sk.log("No clips found on timeline")
    return
end

local items = clips.items or clips
local count = 0

for i, clip in ipairs(items) do
    local start = u.clip_start(clip)
    -- Seek slightly past the clip's start so the playhead is unambiguously
    -- inside this clip rather than on the boundary between two clips.
    sk.seek(start + 0.01)
    -- FCP requires an explicit selection before applying effects
    sk.select_clip()
    sk.color_board()
    count = count + 1
end

sk.log("Applied color board to " .. count .. " clips")
return count
