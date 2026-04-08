-- Export current project as FCPXML to Desktop
local path = os.getenv("HOME") .. "/Desktop/export_" .. os.date("%Y%m%d_%H%M%S") .. ".fcpxml"
sk.rpc("fcpxml.export", {path = path})
sk.alert("Export FCPXML", "Saved to:\n" .. path)
