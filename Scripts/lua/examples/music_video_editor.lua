--[[
  Music Video Editor
  ──────────────────
  Beat-synced editing: detects beats in a music track, then blades
  the timeline at beat positions and applies alternating effects
  (speed ramps, transitions, zoom pulses) synced to the music.

  Workflow:
  1. Detect beats in the audio track
  2. Add markers at beat/bar positions
  3. Blade at each bar (every 4 beats)
  4. Apply alternating effects to create visual rhythm

  HOW TO USE:
    1. Import your music track and video footage into the timeline.
    2. Optionally set MUSIC_FILE to an audio file path; leave nil to
       use whatever audio is already on the timeline.
    3. Run:  dofile("examples/music_video_editor.lua")
    The script will detect tempo, cut at bar lines, and apply
    alternating transitions and speed ramps.

  PATTERNS USED:
    - sk.rpc("beats.detect", {...}) -- external beat detection tool
      that returns {bpm, beats=[], bars=[], sections=[]}
    - sk.rpc("timeline.addMarkers", {times=...}) -- batch marker creation
      (much faster than seeking to each position and adding one-by-one)
    - sk.rpc("transitions.apply", {name=...}) -- apply a named transition
      at the current edit point
    - sk.rpc("timeline.directAction", {...}) -- call Flexo's internal
      action methods directly with typed parameters
    - Modulo-based alternation (i % 4, i % 8) to create visual patterns

  Inspired by CommandPost's beat detection and marker tools.
]]

-- Configuration
local MUSIC_FILE      = nil  -- set to path, or nil to use timeline audio
local BPM_MIN         = 80   -- constrain BPM detection range for accuracy
local BPM_MAX         = 180
local SENSITIVITY     = 0.7  -- 0.0-1.0; higher = more beats detected
local BLADE_ON        = "bars"    -- "beats", "bars", "sections"
local APPLY_EFFECTS   = true
local TRANSITION_NAME = "Flow"    -- try "Cross Dissolve", "Flow", etc.

local u = require("skutil")

-----------------------------------------------------------
-- Step 1: Detect beats
-----------------------------------------------------------
sk.log("[MusicVideo] Detecting beats...")

local beat_params = {
    sensitivity = SENSITIVITY,
    min_bpm = BPM_MIN,
    max_bpm = BPM_MAX,
}
if MUSIC_FILE then
    beat_params.file_path = MUSIC_FILE
end

local beats = sk.rpc("beats.detect", beat_params)

if not beats or not beats.beats then
    sk.log("[MusicVideo] Beat detection failed — make sure audio is available")
    return
end

local bpm = beats.bpm or 120
sk.log(string.format("[MusicVideo] Detected %d BPM, %d beats, %d bars",
    bpm, #(beats.beats or {}), #(beats.bars or {})))

-----------------------------------------------------------
-- Step 2: Add markers at beats and bars
-----------------------------------------------------------
if beats.beats and #beats.beats > 0 then
    sk.rpc("timeline.addMarkers", {times = beats.beats})
    sk.log("[MusicVideo] Added " .. #beats.beats .. " beat markers")
end

-----------------------------------------------------------
-- Step 3: Blade at chosen positions
-- Choose granularity: "beats" gives a cut per beat (fast cutting),
-- "bars" gives one per bar (4 beats), "sections" for major changes.
-----------------------------------------------------------
local cut_times = {}
if BLADE_ON == "beats" then
    cut_times = beats.beats or {}
elseif BLADE_ON == "bars" then
    cut_times = beats.bars or {}
elseif BLADE_ON == "sections" then
    -- Fall back to bars if the detector did not identify sections
    cut_times = beats.sections or beats.bars or {}
end

if #cut_times > 0 then
    for _, t in ipairs(cut_times) do
        -- seek + blade is the standard "cut at time" pattern
        sk.seek(t)
        sk.blade()
    end
    sk.log("[MusicVideo] Bladed at " .. #cut_times .. " positions")
end

-----------------------------------------------------------
-- Step 4: Apply alternating effects
-----------------------------------------------------------
if APPLY_EFFECTS and #cut_times > 1 then
    sk.log("[MusicVideo] Applying effects...")

    -- Navigate edit-by-edit and add transitions on every 4th edit.
    -- WHY every 4th: adding a transition at every cut looks chaotic;
    -- spacing them out creates visual breathing room.
    sk.go_to_start()
    for i = 1, #cut_times do
        sk.timeline("nextEdit")  -- jump to next edit point
        if i % 4 == 1 then
            sk.rpc("transitions.apply", {name = TRANSITION_NAME})
        end
    end

    -- Apply speed variation to alternating segments.
    -- Re-fetch clips because blading changed the item list.
    local state = sk.clips()
    local items = state.items or {}

    for i, clip in ipairs(items) do
        local start = u.clip_start(clip)

        sk.seek(start + 0.01)
        sk.select_clip()

        -- Every 4th clip: slow motion for dramatic emphasis
        if i % 4 == 0 then
            -- directAction calls Flexo's retimeSetRate directly with a
            -- float rate; ripple=false avoids shifting the rest of the timeline.
            sk.rpc("timeline.directAction", {
                action = "retimeSetRate",
                rate = 0.5,
                ripple = false
            })
        -- Every 8th clip: freeze frame for a beat-hit moment
        elseif i % 8 == 0 then
            sk.timeline("freezeFrame")
        end

        ::next_clip::
    end

    sk.log("[MusicVideo] Effects applied")
end

-----------------------------------------------------------
-- Report
-----------------------------------------------------------
print(string.format("═══ Music Video Edit Complete ═══"))
print(string.format("  BPM:        %d", bpm))
print(string.format("  Beats:      %d", #(beats.beats or {})))
print(string.format("  Bars:       %d", #(beats.bars or {})))
print(string.format("  Cuts made:  %d", #cut_times))
print(string.format("  Cut mode:   %s", BLADE_ON))
print(string.format("═════════════════════════════════"))
