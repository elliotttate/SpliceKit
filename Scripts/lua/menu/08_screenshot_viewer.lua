-- Capture a screenshot of the viewer to Desktop
local path = os.getenv("HOME") .. "/Desktop/viewer_" .. os.date("%Y%m%d_%H%M%S") .. ".png"
sk.rpc("viewer.capture", {path = path})
sk.toast("Screenshot saved to Desktop")
