--[[
  Blade Every N Seconds
  ─────────────────────
  Cuts the timeline at regular time intervals. Useful for chopping
  a long take into uniform segments or preparing clips for a montage.

  HOW TO USE:
    1. Open a project with content on the timeline.
    2. Set the 'interval' variable below to your desired spacing.
    3. Run:  dofile("examples/blade_every_n_seconds.lua")
    4. Undo all cuts:  sk.undo()  (one undo per blade)

  PATTERNS USED:
    - sk.go_to_start() / sk.seek(t) / sk.blade() -- the seek-then-act pattern
    - u.seconds() to safely extract duration from sk.position()
    - While-loop stepping through time (avoids frame-counting math)
]]

local u = require("skutil")

local interval = 2.0  -- seconds between cuts (change this to taste)

-- Start from the very beginning so our time math is absolute
sk.go_to_start()
local pos = sk.position()
-- u.seconds() handles CMTime tables and nil gracefully
local dur = u.seconds(pos.duration)
if dur == 0 then dur = 10 end  -- fallback when duration is unknown

local t = interval
local count = 0
while t < dur do
    sk.seek(t)    -- move playhead to exact time (faster than frame-stepping)
    sk.blade()    -- blade at playhead; equivalent to pressing B in the UI
    count = count + 1
    t = t + interval
end

sk.log("Bladed " .. count .. " times at " .. interval .. "s intervals")
return count
