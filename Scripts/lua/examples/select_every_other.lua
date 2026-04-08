--[[
  Select (and Delete) Every Other Clip
  ─────────────────────────────────────
  Ripple-deletes every other clip on the timeline. Useful for removing
  alternating shots or cleaning up a checkerboard edit.

  HOW TO USE:
    dofile("examples/select_every_other.lua")
    -- To undo: call sk.undo() once per deleted clip, or Cmd-Z in FCP.

  WARNING: This is destructive! It deletes clips from your timeline.

  PATTERNS USED:
    - Iterating backwards through the clip list so that ripple-delete
      does not shift the positions of clips we have not yet processed.
      (If we deleted forwards, clip N+1's start time would change after
      clip N is removed, and our stale position data would be wrong.)
    - sk.timeline("delete") performs a ripple delete (FCP's default),
      closing the gap left by the removed clip.
]]

local u = require("skutil")

local clips = sk.clips()
if type(clips) ~= "table" then
    print("No timeline data")
    return
end

local items = clips.items or clips
local deleted = 0

-- Work backwards so that each deletion's ripple does not invalidate
-- the start times of clips earlier in the array.
for i = #items, 1, -2 do
    local clip = items[i]
    local start = u.clip_start(clip)
    sk.seek(start + 0.01)  -- land inside the clip
    sk.select_clip()
    sk.timeline("delete")  -- ripple delete
    deleted = deleted + 1
end

print(string.format("Deleted %d clips (undo with sk.undo())", deleted))
return deleted
