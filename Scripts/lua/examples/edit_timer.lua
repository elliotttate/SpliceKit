--[[
  Edit Timer & Productivity Tracker
  ──────────────────────────────────
  Tracks editing activity by periodically sampling the timeline.
  Records: clips added/removed, total edits, time spent, and
  generates a productivity report.

  HOW TO USE:
    1. Copy to auto/ so it runs on every save:
         cp edit_timer.lua ../auto/
    2. Edit normally in FCP. The tracker logs each detected change.
    3. When ready, view the report:
         edit_report()     -- prints a formatted session report

    Or run manually:
      dofile("examples/edit_timer.lua")   -- initializes tracker
      -- ... edit ...
      dofile("examples/edit_timer.lua")   -- samples again
      edit_report()                       -- show results

  PATTERNS USED:
    - _G._edit_tracker: using Lua globals to persist state between
      script invocations. The Lua VM stays alive across runs within
      the same FCP session, so globals survive.
    - Rate-limiting with os.time(): only sample every 5 seconds so
      auto/ scripts that fire rapidly do not spam the bridge.
    - Delta detection: comparing current clip count and duration to
      the previous sample to infer when an edit occurred.
    - Registering global functions (_G.edit_report) so they can be
      called from the REPL after the script finishes.

  Inspired by CommandPost's notification and activity tracking.
]]

local u = require("skutil")

-- Initialize tracker state (persists across calls via globals).
-- On first run, we snapshot the timeline baseline. Subsequent runs
-- only take a new sample and compare it to the previous one.
if not _G._edit_tracker then
    _G._edit_tracker = {
        start_time = os.time(),
        samples = {},
        total_edits = 0,
        session_start_clips = 0,
        last_clip_count = 0,
        last_duration = 0,
        last_sample_time = 0,
    }

    -- Take initial sample
    local state = sk.clips()
    local items = state.items or {}
    _G._edit_tracker.session_start_clips = #items
    _G._edit_tracker.last_clip_count = #items
    local pos = sk.position()
    _G._edit_tracker.last_duration = u.seconds(pos.duration)

    sk.log("[EditTimer] Session started at " .. os.date())
end

local tracker = _G._edit_tracker

-----------------------------------------------------------
-- Sample current state
-----------------------------------------------------------
local now = os.time()
local elapsed = now - tracker.start_time

-- Rate-limit: if this script is in auto/ it fires on every file save.
-- We skip the RPC calls if less than 5 seconds have elapsed since the
-- last sample, keeping bridge traffic low.
if now - tracker.last_sample_time < 5 then
    return
end
tracker.last_sample_time = now

local state = sk.clips()
local items = state.items or {}
local pos = sk.position()
local current_clips = #items
local current_duration = u.seconds(pos.duration)

-- Detect changes
local clip_delta = current_clips - tracker.last_clip_count
local dur_delta = current_duration - tracker.last_duration

if clip_delta ~= 0 or math.abs(dur_delta) > 0.1 then
    tracker.total_edits = tracker.total_edits + 1
    table.insert(tracker.samples, {
        time = elapsed,
        clips = current_clips,
        duration = current_duration,
        clip_delta = clip_delta,
        dur_delta = dur_delta,
    })

    -- Log significant changes
    if math.abs(clip_delta) >= 1 then
        local action = clip_delta > 0 and "added" or "removed"
        sk.log(string.format("[EditTimer] %s %d clip(s) (total: %d, duration: %.1fs)",
            action, math.abs(clip_delta), current_clips, current_duration))
    end
end

tracker.last_clip_count = current_clips
tracker.last_duration = current_duration

-----------------------------------------------------------
-- Report function (call manually from the REPL)
-- Registered as a global so you can call edit_report() at any time.
-----------------------------------------------------------
function edit_report()
    local t = _G._edit_tracker
    local elapsed_min = (os.time() - t.start_time) / 60
    local net_clips = t.last_clip_count - t.session_start_clips

    print("")
    print("╔════════════════════════════════════════╗")
    print("║       EDITING SESSION REPORT           ║")
    print("╠════════════════════════════════════════╣")
    print(string.format("║  Session started: %s  ║", os.date("%H:%M:%S", t.start_time)))
    print(string.format("║  Duration:        %.0f minutes          ║", elapsed_min))
    print(string.format("║  Total edits:     %d                   ║", t.total_edits))
    print(string.format("║  Edits/minute:    %.1f                 ║",
        elapsed_min > 0 and (t.total_edits / elapsed_min) or 0))
    print(string.format("║  Starting clips:  %d                   ║", t.session_start_clips))
    print(string.format("║  Current clips:   %d (%+d)             ║",
        t.last_clip_count, net_clips))
    print(string.format("║  Timeline length: %.1fs               ║", t.last_duration))
    print("╠════════════════════════════════════════╣")

    -- Activity timeline (last 20 edits)
    local recent = {}
    local start_idx = math.max(1, #t.samples - 19)
    for i = start_idx, #t.samples do
        table.insert(recent, t.samples[i])
    end

    if #recent > 0 then
        print("║  Recent activity:                      ║")
        for _, s in ipairs(recent) do
            local mins = math.floor(s.time / 60)
            local secs = s.time % 60
            local icon = s.clip_delta > 0 and "+" or (s.clip_delta < 0 and "-" or "~")
            print(string.format("║    %s %02d:%02d  clips=%d (%+d)  dur=%.1fs ║",
                icon, mins, secs, s.clips, s.clip_delta, s.duration))
        end
    else
        print("║  No edits recorded yet                 ║")
    end

    print("╚════════════════════════════════════════╝")
end

-- Make report function global
_G.edit_report = edit_report
