-- Generate social-style captions on the timeline
sk.toast("Generating captions...")
sk.rpc("captions.setStyle", {preset_id = "bold_pop", position = "bottom"})
sk.rpc("captions.setGrouping", {mode = "social"})
local r = sk.rpc("captions.generate", {style = "bold_pop"})
if r and r.error then
    sk.alert("Captions", "Error: " .. tostring(r.error))
else
    sk.alert("Captions", "Captions generated and placed on timeline")
end
