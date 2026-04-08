-- Auto-balance color on every clip
local u = require("skutil")
local state = sk.rpc("timeline.getDetailedState", {})
local items = state and state.items or {}

local total = 0
for _, c in ipairs(items) do
    if u.is_real_clip(c) and u.clip_duration(c) > 0.5 then total = total + 1 end
end

if total == 0 then
    sk.alert("Balance Color", "No clips found on the timeline.")
    return
end

sk.toast("Balancing color on " .. total .. " clips...")

local count = 0
for _, clip in ipairs(items) do
    if u.is_real_clip(clip) and u.clip_duration(clip) > 0.5 then
        sk.seek(u.clip_start(clip) + 0.01)
        sk.select_clip()
        sk.timeline("balanceColor")
        count = count + 1
    end
end

sk.alert("Balance Color",
    string.format("Balanced %d clips.\n\nUndo with Edit > Undo or sk.undo()", count))
