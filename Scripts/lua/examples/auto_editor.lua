--[[
  Auto Editor -- Intelligent Automated Assembly
  ─────────────────────────────────────────────
  Takes a long-form clip (interview, vlog, screen recording) and
  automatically produces a polished edit:

  1. Transcribes the timeline
  2. Removes silences (dead air)
  3. Detects scene changes and adds markers
  4. Applies cross dissolves at natural break points
  5. Auto-balances color on each segment
  6. Generates word-by-word captions

  This is the "one-click rough cut" -- run it and walk away.

  HOW TO USE:
    1. Open a project containing raw, unedited footage.
    2. Review the CONFIG table below and adjust thresholds.
    3. Run:  dofile("examples/auto_editor.lua")
    4. Wait. The script reports progress as it goes.
    5. Review the result; use sk.undo() to step back if needed.

    To skip specific steps, toggle them off in CONFIG:
      CONFIG.add_transitions   = false  -- skip dissolves
      CONFIG.auto_balance      = false  -- skip color
      CONFIG.generate_captions = false  -- skip captions

  PATTERNS USED:
    - Pipeline architecture: the script is a linear sequence of
      independent stages, each guarded by a config toggle. Stages
      communicate through the timeline state (not shared variables).
    - Polling with timeout via wait_for(): a reusable pattern for
      waiting on async operations (transcription, rendering, etc.)
    - sk.rpc("transcript.open/getState/deleteSilences/close") --
      the full transcript lifecycle from open to cleanup
    - sk.rpc("scene.detect", {...}) for visual scene change detection
    - sk.rpc("transitions.apply", {freeze_extend=true}) -- automatically
      creates freeze frames when media handles are insufficient
    - u.is_real_clip() to filter gaps/transitions when iterating
    - Statistics accumulator (stats table) for the final report

  ARCHITECTURE NOTE:
    Each stage re-fetches timeline state rather than caching. This is
    intentional: earlier stages (silence removal, scene blading) change
    the timeline, so cached data would be stale. The bridge calls are
    fast enough that this does not cause a performance problem.
]]

local u = require("skutil")

-- Configuration (adjust to taste)
local CONFIG = {
    -- Silence removal
    silence_min = 1.0,           -- remove silences longer than this (seconds)
    silence_threshold = 0.5,     -- silence detection sensitivity (0-1)

    -- Transitions
    add_transitions = true,      -- add dissolves at scene breaks
    transition_name = "Cross Dissolve",
    scene_threshold = 0.35,      -- scene detection sensitivity (0-1, lower=more sensitive)

    -- Color
    auto_balance = true,         -- auto-balance color on each clip

    -- Captions
    generate_captions = true,    -- generate social-style captions
    caption_style = "clean_minimal",
    caption_grouping = "words",
    caption_max_words = 4,

    -- Title card
    add_title = true,

    -- Limits
    max_wait_transcribe = 120,   -- max seconds to wait for transcription
}

local stats = {
    original_duration = 0,
    final_duration = 0,
    silences_removed = 0,
    scenes_detected = 0,
    transitions_added = 0,
    clips_balanced = 0,
    started_at = os.time(),
}

-----------------------------------------------------------
-- Helper: wait for a condition with timeout.
-- Many SpliceKit operations are async (transcription, rendering).
-- This utility polls a check function at regular intervals until
-- it returns true, or the timeout expires.
--
-- @param check_fn  function  Returns true when the condition is met.
-- @param timeout   number    Maximum seconds to wait.
-- @param interval  number    Seconds between polls (default 2).
-- @return boolean  true if condition was met, false if timed out.
-----------------------------------------------------------
local function wait_for(check_fn, timeout, interval)
    interval = interval or 2
    local elapsed = 0
    while elapsed < timeout do
        if check_fn() then return true end
        sk.sleep(interval)
        elapsed = elapsed + interval
    end
    return false
end

-----------------------------------------------------------
-- Step 1: Measure original timeline
-----------------------------------------------------------
sk.log("[AutoEditor] Starting automated edit...")

local orig_state = sk.rpc("timeline.getDetailedState", {})
local orig_items = orig_state and orig_state.items or {}
stats.original_duration = u.timeline_duration()

if stats.original_duration == 0 then
    sk.log("[AutoEditor] No timeline content found — open a project first")
    return
end

sk.log(string.format("[AutoEditor] Timeline: %.1fs, %d items",
    stats.original_duration, #orig_items))

-----------------------------------------------------------
-- Step 2: Transcribe and remove silences
-- Opens the transcript panel, waits for speech-to-text to finish,
-- then batch-removes silences. This single step can cut 20-40%
-- of a raw interview's duration.
-----------------------------------------------------------
sk.log("[AutoEditor] Step 1/6: Transcribing timeline...")
sk.rpc("transcript.open", {})

-- Wait for transcription to complete (async operation)
local transcribed = wait_for(function()
    local state = sk.rpc("transcript.getState", {})
    return state and state.words and #state.words > 0
end, CONFIG.max_wait_transcribe)

if transcribed then
    local ts = sk.rpc("transcript.getState", {})
    sk.log(string.format("[AutoEditor] Transcription complete: %d words", #(ts.words or {})))

    -- Set silence threshold
    sk.rpc("transcript.setSilenceThreshold", {threshold = CONFIG.silence_threshold})

    -- Count silences before removal
    local search = sk.rpc("transcript.search", {query = "pauses"})
    local silence_count = search and search.count or 0

    -- Remove long silences
    sk.log(string.format("[AutoEditor] Step 2/6: Removing %d silences > %.1fs...",
        silence_count, CONFIG.silence_min))
    sk.rpc("transcript.deleteSilences", {min_duration = CONFIG.silence_min})
    stats.silences_removed = silence_count

    sk.rpc("transcript.close", {})
else
    sk.log("[AutoEditor] Transcription timed out — skipping silence removal")
end

-----------------------------------------------------------
-- Step 3: Detect scenes and add transitions
-- Scene detection compares consecutive frames for visual
-- differences. Combined with silence removal, this gives us
-- natural break points for transitions.
-----------------------------------------------------------
sk.log("[AutoEditor] Step 3/6: Detecting scene changes...")

local scenes = sk.rpc("scene.detect", {
    threshold = CONFIG.scene_threshold,
    sample_interval = 0.1   -- sample every 100ms for good accuracy
})

local scene_times = scenes and scenes.timestamps or {}
stats.scenes_detected = #scene_times

if #scene_times > 0 then
    -- Add markers at scene boundaries
    sk.rpc("timeline.addMarkers", {times = scene_times})
    sk.log(string.format("[AutoEditor] Found %d scene changes, markers added", #scene_times))

    -- Add transitions at scene breaks.
    -- freeze_extend=true tells SpliceKit to create freeze frames at
    -- clip edges if there are not enough media handles for the transition.
    -- Without this, FCP would show a dialog asking to ripple-trim.
    if CONFIG.add_transitions and #scene_times > 0 then
        sk.log("[AutoEditor] Step 4/6: Adding transitions...")
        local added = 0
        for _, t in ipairs(scene_times) do
            sk.seek(t)
            -- nextEdit moves to the nearest edit point (the actual cut),
            -- which may be slightly offset from the scene change timestamp.
            sk.timeline("nextEdit")
            local ok = sk.rpc("transitions.apply", {
                name = CONFIG.transition_name,
                freeze_extend = true
            })
            if ok and not ok.error then
                added = added + 1
            end
        end
        stats.transitions_added = added
        sk.log(string.format("[AutoEditor] Added %d transitions", added))
    end
else
    sk.log("[AutoEditor] No scene changes detected — single continuous shot")
end

-----------------------------------------------------------
-- Step 4: Auto-balance color
-- Re-fetches the timeline state because earlier stages (silence
-- removal, blading, transitions) changed the clip list.
-- Only processes clips > 0.5s to skip flash frames.
-----------------------------------------------------------
if CONFIG.auto_balance then
    sk.log("[AutoEditor] Step 5/6: Balancing color...")

    local state = sk.rpc("timeline.getDetailedState", {})
    local items = state and state.items or {}
    local balanced = 0

    for _, clip in ipairs(items) do
        -- Skip gaps, transitions, and very short clips
        if u.is_real_clip(clip) and u.clip_duration(clip) > 0.5 then
            sk.seek(u.clip_start(clip) + 0.01)
            sk.select_clip()
            sk.timeline("balanceColor")
            balanced = balanced + 1
        end
    end

    stats.clips_balanced = balanced
    sk.log(string.format("[AutoEditor] Balanced %d clips", balanced))
end

-----------------------------------------------------------
-- Step 5: Generate captions
-- The caption pipeline: setStyle (visual look) -> setGrouping
-- (how many words per title) -> generate (create FCPXML titles
-- and paste them onto the timeline as connected clips).
-----------------------------------------------------------
if CONFIG.generate_captions then
    sk.log("[AutoEditor] Step 6/6: Generating captions...")

    sk.rpc("captions.setStyle", {
        preset_id = CONFIG.caption_style,
        position = "bottom",
    })
    sk.rpc("captions.setGrouping", {
        mode = CONFIG.caption_grouping,
        max_words = CONFIG.caption_max_words,
    })
    sk.rpc("captions.generate", {style = CONFIG.caption_style})
    sk.log("[AutoEditor] Captions generated")
end

-----------------------------------------------------------
-- Step 6: Final stats
-----------------------------------------------------------
stats.final_duration = u.timeline_duration()
local elapsed = os.time() - stats.started_at
local saved = stats.original_duration - stats.final_duration

sk.go_to_start()

print("")
print("  AUTO EDITOR COMPLETE")
print("  " .. string.rep("=", 50))
print(string.format("  Original:      %5.1fs", stats.original_duration))
print(string.format("  Final:         %5.1fs", stats.final_duration))
print(string.format("  Time saved:    %5.1fs (%.0f%% tighter)",
    saved, stats.original_duration > 0 and (saved / stats.original_duration * 100) or 0))
print(string.format("  Silences cut:  %5d", stats.silences_removed))
print(string.format("  Scenes found:  %5d", stats.scenes_detected))
print(string.format("  Transitions:   %5d", stats.transitions_added))
print(string.format("  Color balanced:%5d clips", stats.clips_balanced))
print(string.format("  Processing:    %5ds", elapsed))
print("  " .. string.rep("=", 50))

return stats
