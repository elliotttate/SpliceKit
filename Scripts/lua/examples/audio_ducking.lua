--[[
  Audio Ducking
  ─────────────
  Automatically lowers music volume when dialogue is present.
  Analyzes the timeline for overlapping audio/video clips and
  adjusts volume levels at key points using keyframes.

  Use case: You have a music bed on a connected storyline and
  interview clips on the primary. This script ducks the music
  wherever the interview clips appear.

  HOW TO USE:
    1. Place your music on a connected storyline (lane 1 by default).
    2. Place dialogue/interview clips on the primary storyline (lane 0).
    3. Adjust configuration below if your layout differs.
    4. Run:  dofile("examples/audio_ducking.lua")
    The music volume will ramp down before each dialogue clip and
    ramp back up after.

  PATTERNS USED:
    - sk.rpc("timeline.getDetailedState", {}) for lane-aware clip data
    - Separating clips by lane to identify dialogue vs music
    - Building a "duck point" timeline -- a list of {time, volume} pairs
      that describe the volume envelope over time
    - Merging overlapping duck regions so adjacent dialogue clips
      produce a single continuous duck rather than fighting each other
    - sk.timeline("addKeyframe") + sk.rpc("inspector.set", {...}) to
      create volume automation keyframes at precise times

  Inspired by CommandPost's audio effect workflows.
]]

-- Configuration
local MUSIC_LANE      = 1       -- lane number where music lives (1 = first above primary)
local DUCK_AMOUNT     = -15.0   -- dB to reduce music during dialogue
local FADE_DURATION   = 0.3     -- seconds for fade in/out of duck
local NORMAL_VOLUME   = 0.0     -- dB for music at normal level

local u = require("skutil")

-----------------------------------------------------------
-- Get timeline clips grouped by lane
-----------------------------------------------------------
local state = sk.rpc("timeline.getDetailedState", {})
if not state or not state.items then
    sk.log("[Ducking] No timeline data")
    return
end

local items = state.items
local primary_clips = {}    -- dialogue clips (primary storyline)
local music_regions = {}    -- where music exists

-- Separate clips by lane
for _, clip in ipairs(items) do
    local lane = clip.lane or 0
    local clip_type = clip.type or clip.class or ""

    -- Skip transitions and gaps
    if clip_type:find("Transition") or clip_type:find("Gap") then
        goto skip
    end

    local start_t = u.clip_start(clip)
    local dur = u.clip_duration(clip)

    if lane == 0 then
        -- Primary storyline = dialogue
        table.insert(primary_clips, {
            start = start_t,
            ending = start_t + dur,
            duration = dur,
            name = clip.name or "clip",
        })
    end

    ::skip::
end

if #primary_clips == 0 then
    sk.log("[Ducking] No primary storyline clips found")
    return
end

sk.log(string.format("[Ducking] Found %d dialogue clips", #primary_clips))

-----------------------------------------------------------
-- Build a list of duck points (where volume should change)
-- Each dialogue clip generates 4 keyframe points:
--   normal -> ramp down -> duck (hold) -> ramp up -> normal
-- This creates the classic "sidechain" ducking envelope.
-----------------------------------------------------------
local duck_points = {}

for _, clip in ipairs(primary_clips) do
    -- Pre-duck: start ramping down BEFORE the dialogue begins so the
    -- transition feels natural (not an abrupt drop)
    local duck_start = math.max(0, clip.start - FADE_DURATION)
    local full_duck = clip.start
    local raise_start = clip.ending
    local full_raise = clip.ending + FADE_DURATION

    table.insert(duck_points, {time = duck_start,   volume = NORMAL_VOLUME, label = "pre-duck"})
    table.insert(duck_points, {time = full_duck,     volume = DUCK_AMOUNT,   label = "duck"})
    table.insert(duck_points, {time = raise_start,   volume = DUCK_AMOUNT,   label = "pre-raise"})
    table.insert(duck_points, {time = full_raise,    volume = NORMAL_VOLUME, label = "raise"})
end

-- Sort chronologically so we can detect overlaps
table.sort(duck_points, function(a, b) return a.time < b.time end)

-- Merge overlapping points: when two dialogue clips are close together,
-- their duck envelopes overlap. We collapse points that are within 50ms
-- of each other, keeping the lower (more ducked) volume.
local merged = {}
for _, pt in ipairs(duck_points) do
    if #merged > 0 then
        local prev = merged[#merged]
        if math.abs(pt.time - prev.time) < 0.05 then
            -- Keep the more aggressive duck (more negative dB value)
            if pt.volume < prev.volume then
                prev.volume = pt.volume
            end
            goto next_point
        end
    end
    table.insert(merged, pt)
    ::next_point::
end

-----------------------------------------------------------
-- Apply volume changes via keyframes
-- We must first select the music clip and open the audio
-- animation editor so that addKeyframe + inspector.set
-- operate on the music track's volume, not the video.
-----------------------------------------------------------
sk.log("[Ducking] Applying " .. #merged .. " volume keyframe points...")

-- Select the music lane clip (not the primary storyline)
sk.rpc("timeline.selectClipInLane", {lane = MUSIC_LANE})

-- Show audio animation so volume keyframes are visible and editable
sk.timeline("showAudioAnimation")

-- Apply keyframes by navigating to each point
for i, pt in ipairs(merged) do
    sk.seek(pt.time)

    -- Add keyframe
    sk.timeline("addKeyframe")

    -- Set volume at this keyframe
    sk.rpc("inspector.set", {property = "volume", value = pt.volume})

    if i % 20 == 0 then
        sk.log("[Ducking] Applied " .. i .. "/" .. #merged .. " keyframes...")
    end
end

-----------------------------------------------------------
-- Report
-----------------------------------------------------------
local duck_regions = math.floor(#merged / 4)
print("═══ Audio Ducking Complete ═══")
print(string.format("  Dialogue clips:  %d", #primary_clips))
print(string.format("  Duck regions:    %d", duck_regions))
print(string.format("  Keyframes:       %d", #merged))
print(string.format("  Duck level:      %+.1f dB", DUCK_AMOUNT))
print(string.format("  Fade duration:   %.1fs", FADE_DURATION))
print("══════════════════════════════")
