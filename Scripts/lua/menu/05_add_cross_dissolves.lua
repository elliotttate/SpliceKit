-- Add Cross Dissolve at every edit point
sk.go_to_start()
local added = 0
local skipped = 0
local last_pos = -1
for i = 1, 200 do
    sk.timeline("nextEdit")
    local pos = sk.position()
    local now = pos.seconds or 0
    if now <= last_pos then break end  -- no more edit points
    last_pos = now
    local r = sk.rpc("transitions.apply", {name = "Cross Dissolve", freeze_extend = true})
    if r and not r.error then
        added = added + 1
    else
        skipped = skipped + 1
    end
end
sk.log(string.format("[Transitions] Added %d Cross Dissolves (%d skipped)", added, skipped))
