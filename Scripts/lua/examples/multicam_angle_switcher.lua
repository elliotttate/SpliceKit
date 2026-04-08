--[[
  Multicam Angle Switcher
  ───────────────────────
  Automatically switches multicam angles based on rules:
  - Switch angles at regular intervals
  - Alternate between two cameras (A/B pattern)
  - Switch on beat markers
  - Random angle selection

  HOW TO USE:
    1. Create a Multicam Clip in FCP (File > New > Multicam Clip).
    2. Place it on the timeline and open it (double-click).
    3. Choose a MODE and ANGLES below.
    4. Run:  dofile("examples/multicam_angle_switcher.lua")

    Modes:
      "alternating" -- A, B, A, B pattern across existing clips
      "interval"    -- blade every N seconds, then alternate angles
      "markers"     -- switch at each marker position on the timeline
      "random"      -- random angle per clip (good for music videos)

  PATTERNS USED:
    - sk.rpc("menu.execute", {...}) to access FCP's menu commands
      (Clip > Switch Angle) for multicam angle switching
    - Multiple mode implementations sharing a common switch_angle()
      helper -- demonstrates how to structure mode-based scripts
    - Table of marker times collected from clip metadata
    - math.randomseed + math.random for non-deterministic variation

  Inspired by CommandPost's multicam cut-and-switch workflows.
]]

-- Configuration
local MODE = "alternating"  -- "alternating", "interval", "markers", "random"
local ANGLES = {1, 2}       -- which angles to use (1-based)
local INTERVAL = 4.0        -- seconds between cuts (for "interval" mode)
local BLADE_FIRST = true    -- blade before switching (creates cut point)

local u = require("skutil")

-----------------------------------------------------------
-- Helper: get clip info at current position
-----------------------------------------------------------
local function current_clip()
    sk.select_clip()
    return sk.selected()
end

-----------------------------------------------------------
-- Switch angle at current playhead position.
-- Blades first (if enabled) so each angle switch creates a
-- distinct clip boundary in the multicam timeline.
-----------------------------------------------------------
local function switch_angle(angle_num)
    if BLADE_FIRST then
        sk.blade()  -- create cut point at playhead
    end
    sk.select_clip()
    -- FCP's multicam angle switching is only accessible via the menu
    -- (no direct ObjC selector for this). menu.execute navigates the
    -- full menu path: Clip > Switch Angle > Video and Audio > Angle N.
    sk.rpc("menu.execute", {
        path = {"Clip", "Switch Angle", "Video and Audio", "Angle " .. angle_num}
    })
end

-----------------------------------------------------------
-- Mode: Alternating (A, B, A, B, ...)
-----------------------------------------------------------
local function run_alternating()
    local state = sk.clips()
    local items = state.items or {}
    if #items == 0 then
        sk.log("[Multicam] No clips on timeline")
        return
    end

    sk.go_to_start()
    local angle_idx = 1

    for i, clip in ipairs(items) do
        local start = u.clip_start(clip)
        sk.seek(start + 0.01)
        local angle = ANGLES[angle_idx]
        switch_angle(angle)

        -- Alternate
        angle_idx = angle_idx + 1
        if angle_idx > #ANGLES then angle_idx = 1 end
    end

    sk.log("[Multicam] Alternating pattern applied to " .. #items .. " clips")
end

-----------------------------------------------------------
-- Mode: Interval (cut every N seconds)
-----------------------------------------------------------
local function run_interval()
    local pos = sk.position()
    local duration = u.seconds(pos.duration)
    if duration == 0 then duration = 60 end

    sk.go_to_start()
    local t = 0
    local angle_idx = 1
    local cuts = 0

    while t < duration do
        sk.seek(t)
        local angle = ANGLES[angle_idx]
        switch_angle(angle)
        cuts = cuts + 1

        angle_idx = angle_idx + 1
        if angle_idx > #ANGLES then angle_idx = 1 end
        t = t + INTERVAL
    end

    sk.log("[Multicam] Made " .. cuts .. " cuts at " .. INTERVAL .. "s intervals")
end

-----------------------------------------------------------
-- Mode: Markers (switch at each marker position)
-----------------------------------------------------------
local function run_markers()
    -- Get timeline state which includes marker info
    local state = sk.rpc("timeline.getDetailedState", {})
    local items = state.items or {}

    -- Collect marker positions
    local marker_times = {}
    for _, item in ipairs(items) do
        if item.markers then
            for _, marker in ipairs(item.markers) do
                if marker.time then
                    table.insert(marker_times, marker.time)
                end
            end
        end
    end

    table.sort(marker_times)

    if #marker_times == 0 then
        sk.log("[Multicam] No markers found — add markers first")
        return
    end

    local angle_idx = 1
    for _, t in ipairs(marker_times) do
        sk.seek(t)
        local angle = ANGLES[angle_idx]
        switch_angle(angle)

        angle_idx = angle_idx + 1
        if angle_idx > #ANGLES then angle_idx = 1 end
    end

    sk.log("[Multicam] Switched at " .. #marker_times .. " marker positions")
end

-----------------------------------------------------------
-- Mode: Random
-----------------------------------------------------------
local function run_random()
    math.randomseed(os.time())

    local state = sk.clips()
    local items = state.items or {}

    for _, clip in ipairs(items) do
        local start = u.clip_start(clip)
        sk.seek(start + 0.01)
        local angle = ANGLES[math.random(#ANGLES)]
        switch_angle(angle)
    end

    sk.log("[Multicam] Random angles applied to " .. #items .. " clips")
end

-----------------------------------------------------------
-- Run selected mode
-----------------------------------------------------------
sk.log("[Multicam] Running in '" .. MODE .. "' mode with angles: " ..
       table.concat(ANGLES, ", "))

if MODE == "alternating" then
    run_alternating()
elseif MODE == "interval" then
    run_interval()
elseif MODE == "markers" then
    run_markers()
elseif MODE == "random" then
    run_random()
else
    sk.log("[Multicam] Unknown mode: " .. MODE)
end
