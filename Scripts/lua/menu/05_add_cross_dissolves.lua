-- Add Cross Dissolve at every edit point
sk.toast("Adding cross dissolves...")
sk.go_to_start()
local added = 0
for i = 1, 200 do
    sk.timeline("nextEdit")
    local r = sk.rpc("transitions.apply", {name = "Cross Dissolve", freeze_extend = true})
    if r and not r.error then
        added = added + 1
    else
        break
    end
end

sk.alert("Cross Dissolves",
    string.format("Added %d Cross Dissolves at edit points.\n\nUndo with Edit > Undo.", added))
