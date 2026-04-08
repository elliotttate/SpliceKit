-- Auto-balance color on every clip
local u = require("skutil")
local state = sk.rpc("timeline.getDetailedState", {})
local items = state and state.items or {}
local count = 0
sk.toast("Balancing color...")
for _, clip in ipairs(items) do
    if u.is_real_clip(clip) and u.clip_duration(clip) > 0.5 then
        sk.seek(u.clip_start(clip) + 0.01)
        sk.select_clip()
        sk.timeline("balanceColor")
        count = count + 1
    end
end
sk.alert("Balance Color", string.format("Balanced %d clips", count))
