--[[
  skutil — Shared Helpers for SpliceKit Lua Scripts
  ──────────────────────────────────────────────────
  Normalizes the many ways FCP returns time values (raw numbers,
  CMTime tables with value/timescale, or tables with a .seconds
  field) and provides convenience accessors that every example
  script depends on.

  HOW TO USE:
    local u = require("skutil")
    local secs = u.seconds(some_time_value)  -- always returns a number
    local start = u.clip_start(clip)         -- works regardless of field name
    local tc   = u.timecode(42.5, 24)        -- "00:00:42:12"

  PATTERNS USED:
    - Polymorphic time normalization (CMTime, number, table)
    - Defensive field lookup across varying bridge response shapes
    - Computing derived timeline metrics from raw item data

  WHY THIS EXISTS:
    The SpliceKit bridge returns time in different formats depending
    on the endpoint (e.g. sk.position() gives .seconds as a number,
    but clip items may carry CMTime tables with .value/.timescale).
    Every script would need the same nil-checks and conversions, so
    skutil centralizes them in one place.
]]

local M = {}

--- Extract seconds from a value that might be a number, a CMTime table, or nil.
--  CMTime tables come from FCP's Core Media layer and look like:
--    {value = 48000, timescale = 24000}  -- equals 2.0 seconds
--  Some bridge responses already decode them to {seconds = 2.0}.
--  This function handles all three cases plus nil.
--
-- @param val  number | table | nil  The time value to normalize.
-- @return number  Always returns a plain Lua number (seconds).
function M.seconds(val)
    if val == nil then return 0 end
    if type(val) == "number" then return val end
    if type(val) == "table" then
        -- Pre-decoded seconds field (most common in bridge responses)
        if val.seconds then return tonumber(val.seconds) or 0 end
        -- Raw CMTime: value / timescale
        if val.value and val.timescale and val.timescale ~= 0 then
            return val.value / val.timescale
        end
    end
    -- Last resort: try coercing a string-like value
    return tonumber(val) or 0
end

--- Get clip start time in seconds from various field names.
--  Different bridge endpoints use different keys for the same concept:
--  "start", "startTime", or "offset". This tries each in priority order.
--
-- @param clip  table  A clip item from sk.clips() or timeline.getDetailedState.
-- @return number  Start time in seconds.
function M.clip_start(clip)
    return M.seconds(clip.start or clip.startTime or clip.offset or 0)
end

--- Get clip duration in seconds.
--
-- @param clip  table  A clip item table.
-- @return number  Duration in seconds.
function M.clip_duration(clip)
    return M.seconds(clip.duration or 0)
end

--- Get clip end time in seconds.
--  Uses the pre-computed endTime field if available, otherwise
--  derives it from start + duration.
--
-- @param clip  table  A clip item table.
-- @return number  End time in seconds.
function M.clip_end(clip)
    if clip.endTime then return M.seconds(clip.endTime) end
    return M.clip_start(clip) + M.clip_duration(clip)
end

--- Get timeline total duration in seconds.
--  There is no single bridge call for this, so we walk every item
--  and find the latest end time. This is why the function makes its
--  own RPC call -- it needs the full item list.
--
-- @return number  The rightmost end time across all timeline items.
function M.timeline_duration()
    local state = sk.rpc("timeline.getDetailedState", {})
    if not state or not state.items then return 0 end
    local max_end = 0
    for _, item in ipairs(state.items) do
        local e = M.clip_end(item)
        if e > max_end then max_end = e end
    end
    return max_end
end

--- Check if a timeline item is a real clip (not a gap or transition).
--  Gaps and transitions are structural items that most scripts want
--  to skip when iterating over "clips the user cares about."
--
-- @param clip  table  A clip item table.
-- @return boolean  true if this is a real media clip.
function M.is_real_clip(clip)
    local t = clip.type or clip.class or ""
    if t:find("Transition") then return false end
    if t:find("Gap") then return false end
    return true
end

--- Format seconds as HH:MM:SS:FF timecode.
--
-- @param secs  number  Time in seconds.
-- @param fps   number  Frame rate (default 30). Determines the :FF part.
-- @return string  Formatted timecode, e.g. "00:01:23:15".
function M.timecode(secs, fps)
    fps = fps or 30
    secs = secs or 0
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = math.floor(secs % 60)
    local f = math.floor((secs % 1) * fps)
    return string.format("%02d:%02d:%02d:%02d", h, m, s, f)
end

return M
