-- Show a report of the current timeline
local u = require("skutil")
local pos = sk.position()
local state = sk.rpc("timeline.getDetailedState", {})
local items = state and state.items or {}

local real = 0
local transitions = 0
local gaps = 0
local total_dur = 0
local shortest = math.huge
local longest = 0

for _, c in ipairs(items) do
    local dur = u.clip_duration(c)
    local cls = c.class or c.type or ""
    if cls:find("Transition") then
        transitions = transitions + 1
    elseif cls:find("Gap") then
        gaps = gaps + 1
    else
        real = real + 1
        total_dur = total_dur + dur
        if dur > 0 and dur < shortest then shortest = dur end
        if dur > longest then longest = dur end
    end
end

if shortest == math.huge then shortest = 0 end
local avg = real > 0 and (total_dur / real) or 0

local report = string.format(
    "Clips:          %d\n" ..
    "Transitions:    %d\n" ..
    "Gaps:           %d\n" ..
    "Total duration: %.1fs (%.0fm %02ds)\n" ..
    "Average clip:   %.1fs\n" ..
    "Shortest clip:  %.2fs\n" ..
    "Longest clip:   %.1fs\n" ..
    "Frame rate:     %.0f fps\n" ..
    "Playhead:       %.1fs",
    real, transitions, gaps,
    total_dur, math.floor(total_dur / 60), math.floor(total_dur % 60),
    avg, shortest, longest,
    pos.frameRate or 0, pos.seconds or 0
)

sk.alert("Timeline Report", report)
