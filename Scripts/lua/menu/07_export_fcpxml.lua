-- Export current project as FCPXML to Desktop
local path = os.getenv("HOME") .. "/Desktop/export_" .. os.date("%Y%m%d_%H%M%S") .. ".fcpxml"
local r = sk.rpc("fcpxml.export", {path = path})
if r and r.error then
    sk.alert("Export FCPXML", "Failed: " .. tostring(r.error))
else
    sk.alert("Export FCPXML", "Saved to Desktop\n" .. (r.bytes or 0) .. " bytes")
end
