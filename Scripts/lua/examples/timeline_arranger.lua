--[[
  Timeline Arranger -- Structural Editing Operations
  ─────────────────────────────────────────────────
  High-level operations that restructure the timeline:

  - Reverse the entire timeline (or a selection)
  - Shuffle clips into random order
  - Duplicate a section N times (loop builder)
  - Create an "every Nth clip" highlight reel
  - Extract only clips matching criteria (filter by duration/name/lane)
  - Analyze pacing (duration stats, histogram, rhythm assessment)

  These are structural transforms -- they change clip ORDER,
  not clip content. Undo-safe (each step can be reverted).

  HOW TO USE:
    dofile("examples/timeline_arranger.lua")

    -- Reverse all clips:
    arranger.reverse()

    -- Shuffle clips randomly:
    arranger.shuffle()
    arranger.shuffle(42)         -- with fixed seed for reproducibility

    -- Keep every 3rd clip, delete the rest:
    arranger.every_nth(3)
    arranger.every_nth(2, "delete")  -- delete every 2nd clip instead

    -- Loop a section 4 times (e.g. a music bar):
    arranger.loop_section(10.0, 15.0, 4)  -- loop 10s-15s x4

    -- Extract only clips matching criteria:
    arranger.extract({min_duration = 3.0})  -- keep clips >= 3s
    arranger.extract({name_pattern = "interview", lane = 0})

    -- Analyze pacing and rhythm:
    arranger.analyze()

    -- All operations are undo-safe:
    sk.undo()  -- reverts the last operation

  PATTERNS USED:
    - get_real_clips() helper: filters out gaps and transitions to
      get only "real" media clips with timing data. Used by every
      operation in this module.
    - Build-from-left reordering: FCP's magnetic timeline ripples
      positions on every cut/paste. We build the target order from
      left to right — clips 1..step are finalized, the rest are
      unsorted. Each step cuts from the unsorted portion and inserts
      at the build cursor. This is O(n) re-reads but correct.
    - Identity-based clip tracking: shuffle matches clips by
      (name, duration) rather than index, since indices become
      stale after each edit.
    - Fisher-Yates shuffle: the standard unbiased shuffle algorithm
      used to randomize the desired clip order.
    - Reverse iteration for deletion: standard pattern for removing
      items without invalidating indices (every_nth, extract).
    - Range-based operations: loop_section uses setRange + copy + paste
      to duplicate a time range without touching individual clips.
    - Statistical analysis: mean, median, standard deviation, histogram
      bucketing for pacing assessment.

  ARCHITECTURE NOTE:
    All functions re-read the timeline state (via get_real_clips())
    before and/or during operation, because earlier steps in the same
    operation may have changed clip positions. This makes each function
    self-contained and composable.
]]

local u = require("skutil")

local arranger = {}

-----------------------------------------------------------
-- Helper: get real clips (skip gaps/transitions) with timing.
-- Returns a clean array of {name, start, duration, ending, lane, class}
-- for every media clip on the timeline. This is the foundation
-- for all structural operations in this module.
-----------------------------------------------------------
local function get_real_clips()
    local state = sk.rpc("timeline.getDetailedState", {})
    local items = state and state.items or {}
    local clips = {}

    for _, item in ipairs(items) do
        if u.is_real_clip(item) then
            table.insert(clips, {
                name = item.name or "clip",
                start = u.clip_start(item),
                duration = u.clip_duration(item),
                ending = u.clip_end(item),
                lane = item.lane or 0,
                class = item.class or item.type or "unknown",
                handle = item.handle,
            })
        end
    end

    return clips
end

-----------------------------------------------------------
-- Helper: export current timeline as FCPXML, manipulate,
-- reimport. This is the nuclear option for reordering.
-----------------------------------------------------------
local function save_playhead()
    return sk.position().seconds or 0
end

-----------------------------------------------------------
-- Reverse: reverse clip order on the timeline.
-- Strategy: build the reversed order from left to right.
-- On each step, cut the LAST remaining unsorted clip and insert
-- it at the next build position. After step i, the first i clips
-- are in their final reversed positions.
--
-- @return number  Count of clips reversed.
-----------------------------------------------------------
function arranger.reverse()
    local clips = get_real_clips()
    if #clips < 2 then
        sk.alert("Arranger", "Need at least 2 clips to reverse")
        return
    end

    local count = #clips
    sk.log("[Arranger] Reversing " .. count .. " clips...")

    -- Build the reversed order from left to right. On each step,
    -- cut the LAST remaining unsorted clip and insert it at the
    -- next build position. After step i, clips 1..i are in their
    -- final reversed positions.
    --
    -- Trace for [A,B,C,D,E]:
    --   step 1: cut E (last), paste at start     → [E, A,B,C,D]
    --   step 2: cut D (last), paste after E      → [E,D, A,B,C]
    --   step 3: cut C (last), paste after D      → [E,D,C, A,B]
    --   step 4: cut B (last), paste after C      → [E,D,C,B, A]

    for step = 1, count - 1 do
        local current = get_real_clips()
        local last_clip = current[#current]

        -- Cut the last unsorted clip
        sk.seek(last_clip.start + 0.01)
        sk.select_clip()
        sk.timeline("cut")

        -- Insert at the build position
        if step == 1 then
            sk.go_to_start()
        else
            local current2 = get_real_clips()
            sk.seek(current2[step].start)
        end
        sk.timeline("paste")
    end

    sk.log(string.format("[Arranger] Reversed %d clips", count))
    sk.alert("Arranger", string.format("Reversed %d clips\n\nUndo with sk.undo()", count))
    return count
end

-----------------------------------------------------------
-- Shuffle: randomize clip order using Fisher-Yates algorithm.
-- Pass a fixed seed for reproducible results (useful for testing
-- or re-creating a specific random order).
--
-- @param seed  number  Optional RNG seed. Default: os.time().
-- @return number  Count of move operations performed.
-----------------------------------------------------------
function arranger.shuffle(seed)
    math.randomseed(seed or os.time())

    local clips = get_real_clips()
    if #clips < 2 then
        sk.alert("Arranger", "Need at least 2 clips to shuffle")
        return
    end

    local count = #clips
    sk.log("[Arranger] Shuffling " .. count .. " clips...")

    -- Record clip identities (name + duration) and Fisher-Yates shuffle them.
    -- We track identity rather than indices because indices become stale
    -- after each cut/paste operation on the magnetic timeline.
    local desired = {}
    for i, c in ipairs(clips) do
        desired[i] = {name = c.name, duration = c.duration}
    end
    for i = #desired, 2, -1 do
        local j = math.random(1, i)
        desired[i], desired[j] = desired[j], desired[i]
    end

    -- Build the shuffled order from left to right. For each target
    -- position, find the desired clip among the remaining unsorted
    -- clips (positions step..n), cut it, and insert at position step.
    -- Clips at positions 1..step-1 are already placed and untouched.
    local moved = 0
    for step = 1, count - 1 do
        local current = get_real_clips()
        local target = desired[step]

        -- Find the matching clip from position step onward
        local found_at = nil
        for j = step, #current do
            if current[j].name == target.name
               and math.abs(current[j].duration - target.duration) < 0.01 then
                found_at = j
                break
            end
        end

        if found_at and found_at ~= step then
            -- Cut the clip from its current position
            sk.seek(current[found_at].start + 0.01)
            sk.select_clip()
            sk.timeline("cut")

            -- Insert at the build position
            if step == 1 then
                sk.go_to_start()
            else
                local current2 = get_real_clips()
                sk.seek(current2[step].start)
            end
            sk.timeline("paste")
            moved = moved + 1
        end
    end

    sk.log(string.format("[Arranger] Shuffled %d clips (%d moves)", count, moved))
    sk.alert("Arranger", string.format("Shuffled %d clips (%d moves)\n\nUndo with sk.undo()", count, moved))
    return moved
end

-----------------------------------------------------------
-- Highlight reel: keep every Nth clip, delete the rest.
-- Two modes:
--   "keep"   -- keep every Nth clip, delete all others (default)
--   "delete" -- delete every Nth clip, keep all others
--
-- @param n               number  The interval (default 3).
-- @param keep_or_delete  string  "keep" or "delete" (default "keep").
-- @return number  Count of clips retained.
-----------------------------------------------------------
function arranger.every_nth(n, keep_or_delete)
    n = n or 3
    keep_or_delete = keep_or_delete or "keep"

    local clips = get_real_clips()
    if #clips < n then
        sk.alert("Arranger", "Not enough clips for every-" .. n)
        return
    end

    local to_remove = {}
    for i, clip in ipairs(clips) do
        local is_nth = (i % n == 0)
        local should_remove = (keep_or_delete == "keep" and not is_nth) or
                              (keep_or_delete == "delete" and is_nth)
        if should_remove then
            table.insert(to_remove, clip)
        end
    end

    -- Remove in reverse order
    table.sort(to_remove, function(a, b) return a.start > b.start end)
    for _, clip in ipairs(to_remove) do
        sk.seek(clip.start + 0.01)
        sk.select_clip()
        sk.timeline("delete")
    end

    local kept = #clips - #to_remove
    sk.log(string.format("[Arranger] Kept %d, removed %d (every %d, mode: %s)",
        kept, #to_remove, n, keep_or_delete))
    sk.alert("Arranger", string.format("Kept %d clips, removed %d", kept, #to_remove))
    return kept
end

-----------------------------------------------------------
-- Loop section: duplicate a time range N times.
-- Useful for music videos (loop a bar), presentations (repeat
-- a section), or creating a rhythmic pattern.
--
-- Strategy: set the timeline range, select all, copy, then paste
-- at the end of the range N times. Each paste inserts a copy
-- of the entire range.
--
-- @param start_time   number  Start of the section to loop (seconds).
-- @param end_time     number  End of the section (seconds).
-- @param repetitions  number  How many copies to add (1-50).
-- @return number  Count of repetitions added.
-----------------------------------------------------------
function arranger.loop_section(start_time, end_time, repetitions)
    if not start_time or not end_time or not repetitions then
        sk.alert("Arranger", "Usage: arranger.loop_section(start_sec, end_sec, reps)")
        return
    end
    if repetitions < 1 or repetitions > 50 then
        sk.alert("Arranger", "Repetitions must be 1-50")
        return
    end

    local section_dur = end_time - start_time
    if section_dur <= 0 then
        sk.alert("Arranger", "End time must be after start time")
        return
    end

    sk.log(string.format("[Arranger] Looping %.1fs-%.1fs x%d...",
        start_time, end_time, repetitions))

    -- Set range, copy, then paste N times at the end of the range
    sk.rpc("timeline.setRange", {
        start_seconds = start_time,
        end_seconds = end_time
    })
    sk.timeline("selectAll")
    sk.timeline("copy")
    sk.timeline("clearRange")

    -- Paste at the end of the section, N times
    local paste_point = end_time
    for i = 1, repetitions do
        sk.seek(paste_point)
        sk.timeline("paste")
        paste_point = paste_point + section_dur
    end

    local total_added = section_dur * repetitions
    sk.alert("Arranger", string.format("Looped %.1fs section %d times (added %.1fs)",
        section_dur, repetitions, total_added))
    return repetitions
end

-----------------------------------------------------------
-- Extract: keep only clips matching criteria, delete the rest.
-- The result is a continuous sequence of matching clips with
-- all gaps ripple-deleted.
--
-- @param criteria  table  Filter criteria (all conditions are AND-combined):
--   .min_duration  number  Keep clips >= this duration
--   .max_duration  number  Keep clips <= this duration
--   .name_pattern  string  Keep clips whose name contains this (case insensitive)
--   .lane          number  Keep clips in this lane only
-- @return number  Count of clips retained.
-----------------------------------------------------------
function arranger.extract(criteria)
    criteria = criteria or {}

    local clips = get_real_clips()
    local keep = {}
    local remove = {}

    for _, clip in ipairs(clips) do
        local dominated = true

        if criteria.min_duration and clip.duration < criteria.min_duration then
            dominated = false
        end
        if criteria.max_duration and clip.duration > criteria.max_duration then
            dominated = false
        end
        if criteria.name_pattern then
            if not clip.name:lower():find(criteria.name_pattern:lower()) then
                dominated = false
            end
        end
        if criteria.lane and clip.lane ~= criteria.lane then
            dominated = false
        end

        if dominated then
            table.insert(keep, clip)
        else
            table.insert(remove, clip)
        end
    end

    -- Remove non-matching clips in reverse order
    table.sort(remove, function(a, b) return a.start > b.start end)
    for _, clip in ipairs(remove) do
        sk.seek(clip.start + 0.01)
        sk.select_clip()
        sk.timeline("delete")
    end

    sk.alert("Arranger", string.format("Extracted %d clips, removed %d", #keep, #remove))
    return #keep
end

-----------------------------------------------------------
-- Analyze timing: compute statistics and show a histogram of
-- clip durations. Reports pacing (fast/moderate/slow) and
-- rhythm (consistent/varied/irregular) based on the data.
--
-- @return table  {count, total, mean, median, stddev, shortest, longest}
-----------------------------------------------------------
function arranger.analyze()
    local clips = get_real_clips()
    if #clips == 0 then
        sk.alert("Arranger", "No clips to analyze")
        return
    end

    -- Compute stats
    local durations = {}
    local total = 0
    local shortest = math.huge
    local longest = 0

    for _, clip in ipairs(clips) do
        table.insert(durations, clip.duration)
        total = total + clip.duration
        if clip.duration < shortest then shortest = clip.duration end
        if clip.duration > longest then longest = clip.duration end
    end

    table.sort(durations)
    local median = durations[math.ceil(#durations / 2)]
    local mean = total / #clips

    -- Standard deviation: measures how varied the cut lengths are.
    -- Low stddev = consistent pacing; high stddev = irregular rhythm.
    local sq_diff_sum = 0
    for _, d in ipairs(durations) do
        sq_diff_sum = sq_diff_sum + (d - mean) ^ 2
    end
    local stddev = math.sqrt(sq_diff_sum / #clips)

    -- Duration histogram: 5 buckets covering typical editing ranges
    local buckets = {0, 0, 0, 0, 0}
    local bucket_labels = {"<1s", "1-3s", "3-10s", "10-30s", ">30s"}
    for _, d in ipairs(durations) do
        if d < 1 then buckets[1] = buckets[1] + 1
        elseif d < 3 then buckets[2] = buckets[2] + 1
        elseif d < 10 then buckets[3] = buckets[3] + 1
        elseif d < 30 then buckets[4] = buckets[4] + 1
        else buckets[5] = buckets[5] + 1 end
    end

    -- Build output string for alert display
    local lines = {}
    local function add(s) lines[#lines + 1] = s end

    add(string.format("Clips:      %d", #clips))
    add(string.format("Total:      %.1fs (%.0f min)", total, total / 60))
    add(string.format("Mean:       %.2fs", mean))
    add(string.format("Median:     %.2fs", median))
    add(string.format("Std dev:    %.2fs", stddev))
    add(string.format("Shortest:   %.2fs", shortest))
    add(string.format("Longest:    %.2fs", longest))
    add("")
    add("Duration Distribution:")
    local max_bucket = math.max(table.unpack(buckets))
    for i, count in ipairs(buckets) do
        local bar_len = max_bucket > 0 and math.floor(count / max_bucket * 20) or 0
        add(string.format("  %-6s  %s %d",
            bucket_labels[i],
            string.rep("#", bar_len),
            count))
    end

    -- Pacing assessment based on average cut length.
    add("")
    if mean < 2 then
        add("Pacing:  FAST (avg < 2s per cut)")
    elseif mean < 5 then
        add("Pacing:  MODERATE (avg 2-5s per cut)")
    elseif mean < 15 then
        add("Pacing:  SLOW (avg 5-15s per cut)")
    else
        add("Pacing:  VERY SLOW (avg > 15s per cut)")
    end

    -- Rhythm: coefficient of variation (stddev/mean).
    if stddev / mean > 1.0 then
        add("Rhythm:  IRREGULAR (high variation)")
    elseif stddev / mean > 0.5 then
        add("Rhythm:  VARIED (moderate variation)")
    else
        add("Rhythm:  CONSISTENT (low variation)")
    end

    sk.alert("Pacing Analysis", table.concat(lines, "\n"))

    return {
        count = #clips,
        total = total,
        mean = mean,
        median = median,
        stddev = stddev,
        shortest = shortest,
        longest = longest,
    }
end

-- Register globally
_G.arranger = arranger

sk.alert("Timeline Arranger",
    "arranger.reverse()                    — reverse clip order\n" ..
    "arranger.shuffle()                    — randomize clip order\n" ..
    "arranger.every_nth(3)                 — keep every 3rd clip\n" ..
    "arranger.every_nth(2, 'delete')       — delete every 2nd clip\n" ..
    "arranger.loop_section(10, 15, 4)      — loop 10-15s x4\n" ..
    "arranger.extract({min_duration=3.0})  — keep clips >= 3s\n" ..
    "arranger.analyze()                    — pacing & rhythm analysis")

return arranger
