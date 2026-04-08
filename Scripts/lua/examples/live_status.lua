--[[
  Live Status Monitor
  ───────────────────
  Displays playhead position, clip count, and playback state.

  HOW TO USE:
    Copy this file into the auto/ directory so it re-runs every time
    you save any Lua script. Each invocation prints a single status
    line to the console, giving you a live dashboard while editing.

      cp live_status.lua ../auto/

    Or run it once manually from the REPL:
      dofile("examples/live_status.lua")

  PATTERNS USED:
    - sk.position()  -- query playhead time, duration, and play state
    - sk.clips()     -- fetch the current timeline's clip list
    - Defensive table access (clips may be a flat array or {items=...})
]]

-- sk.position() returns a table with .seconds, .duration, .isPlaying, .frameRate
local pos = sk.position()

-- sk.clips() may return {items={...}} or a plain array depending on bridge version,
-- so we normalize to a flat list. The "or {}" guards against nil/non-table results.
local clips = sk.clips()
local items = (type(clips) == "table") and (clips.items or clips) or {}

sk.log(string.format(
    "Playhead: %.2fs | Clips: %d | Playing: %s",
    pos.seconds or 0,
    #items,
    tostring(pos.isPlaying or false)
))
