-- Show clip count, duration, and playhead position
local u = require("skutil")
local pos = sk.position()
local state = sk.rpc("timeline.getDetailedState", {})
local items = state and state.items or {}
local real = 0
local total_dur = 0
for _, c in ipairs(items) do
    if u.is_real_clip(c) then
        real = real + 1
        total_dur = total_dur + u.clip_duration(c)
    end
end
sk.alert("Timeline Report",
    string.format("Clips: %d\nDuration: %s\nPlayhead: %s\nFrame Rate: %.0f fps",
    real, u.timecode(total_dur), u.timecode(pos.seconds or 0), pos.frameRate or 0))
