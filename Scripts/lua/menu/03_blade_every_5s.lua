-- Blade the timeline every 5 seconds
local u = require("skutil")
sk.go_to_start()
local dur = u.timeline_duration()
if dur == 0 then sk.alert("Blade Every 5s", "No timeline content"); return end
sk.toast("Blading every 5s...")
local cuts = 0
for t = 5, dur - 1, 5 do
    sk.seek(t)
    sk.blade()
    cuts = cuts + 1
end
sk.alert("Blade Every 5s", string.format("Made %d cuts across %s", cuts, u.timecode(dur)))
