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
    - Cut-and-paste reordering: FCP does not have a "move clip to
      position" API, so we use cut -> seek to target -> paste. This
      is O(n^2) but undo-safe (each cut/paste is a single undo step).
    - Fisher-Yates shuffle: the standard unbiased shuffle algorithm
      used to randomize clip indices before reordering.
    - Reverse iteration for deletion: standard pattern for removing
      items without invalidating indices.
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
-- Strategy: starting from the last clip, cut it and paste at
-- the beginning. Repeat for each clip from back to front.
-- This is O(n) cuts and pastes.
--
-- WHY cut+paste: FCP has no "move clip to index" API. Cut removes
-- the clip and places it on the clipboard; paste inserts it at the
-- playhead. By always pasting at the start, we build the reversed
-- order one clip at a time.
--
-- @return number  Count of clips reversed.
-----------------------------------------------------------
function arranger.reverse()
    local clips = get_real_clips()
    if #clips < 2 then
        print("Need at least 2 clips to reverse")
        return
    end

    sk.log("[Arranger] Reversing " .. #clips .. " clips...")

    -- Strategy: blade between every clip, then reverse order
    -- by cutting from end and pasting at start repeatedly.
    -- Simpler approach: use undo-able sequence of operations.

    -- Record the clip order (we'll use cut+paste approach)
    local count = #clips

    -- Work from the last clip backwards: cut it and paste at start
    for i = count, 2, -1 do
        -- Re-read state (positions shift after each operation)
        local current = get_real_clips()
        if i > #current then goto skip end

        local clip = current[i]
        sk.seek(clip.start + 0.01)
        sk.select_clip()
        sk.timeline("cut")

        -- Go to start and paste
        sk.go_to_start()
        sk.timeline("paste")

        ::skip::
    end

    sk.log(string.format("[Arranger] Reversed %d clips", count))
    print(string.format("Reversed %d clips (undo with sk.undo())", count))
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
        print("Need at least 2 clips to shuffle")
        return
    end

    sk.log("[Arranger] Shuffling " .. #clips .. " clips...")

    -- Fisher-Yates shuffle: iterate from end to start, swapping each
    -- element with a random earlier element. This produces an unbiased
    -- permutation in O(n) time.
    local indices = {}
    for i = 1, #clips do indices[i] = i end
    for i = #indices, 2, -1 do
        local j = math.random(1, i)
        indices[i], indices[j] = indices[j], indices[i]
    end

    -- Execute the permutation via cut+paste.
    -- WHY O(n^2): each cut/paste changes positions, so we must re-read
    -- state. But n is typically small (< 100 clips) and each step is
    -- individually undoable.
    local moved = 0
    for target_pos = 1, #indices do
        local source_idx = indices[target_pos]
        if source_idx ~= target_pos then
            -- Re-read current state
            local current = get_real_clips()
            if source_idx <= #current and target_pos <= #current then
                local source_clip = current[source_idx]
                local target_clip = current[target_pos]

                -- Cut the source clip
                sk.seek(source_clip.start + 0.01)
                sk.select_clip()
                sk.timeline("cut")

                -- Paste at target position
                sk.seek(target_clip.start)
                sk.timeline("paste")
                moved = moved + 1
            end
        end
    end

    sk.log(string.format("[Arranger] Shuffled %d clips (%d moves)", #clips, moved))
    print(string.format("Shuffled %d clips (undo with sk.undo())", #clips))
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
        print("Not enough clips for every-" .. n)
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
    print(string.format("Kept %d clips, removed %d", kept, #to_remove))
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
        print("Usage: arranger.loop_section(start_sec, end_sec, reps)")
        return
    end
    if repetitions < 1 or repetitions > 50 then
        print("Repetitions must be 1-50")
        return
    end

    local section_dur = end_time - start_time
    if section_dur <= 0 then
        print("End time must be after start time")
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
    print(string.format("Looped %.1fs section %d times (added %.1fs)",
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

    print(string.format("Extracted %d clips, removed %d", #keep, #remove))
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
        print("No clips to analyze")
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

    print("")
    print("  TIMELINE PACING ANALYSIS")
    print("  " .. string.rep("=", 45))
    print(string.format("  Clips:     %d", #clips))
    print(string.format("  Total:     %.1fs (%.0f min)", total, total / 60))
    print(string.format("  Mean:      %.2fs", mean))
    print(string.format("  Median:    %.2fs", median))
    print(string.format("  Std dev:   %.2fs", stddev))
    print(string.format("  Shortest:  %.2fs", shortest))
    print(string.format("  Longest:   %.2fs", longest))
    print("")
    print("  Duration Distribution:")
    local max_bucket = math.max(table.unpack(buckets))
    for i, count in ipairs(buckets) do
        local bar_len = max_bucket > 0 and math.floor(count / max_bucket * 25) or 0
        print(string.format("    %-6s  %s %d",
            bucket_labels[i],
            string.rep("#", bar_len),
            count))
    end

    -- Pacing assessment based on average cut length.
    -- These thresholds are borrowed from film editing theory:
    -- action/music videos < 2s, documentaries 5-15s, etc.
    print("")
    if mean < 2 then
        print("  Pacing: FAST (avg < 2s per cut)")
    elseif mean < 5 then
        print("  Pacing: MODERATE (avg 2-5s per cut)")
    elseif mean < 15 then
        print("  Pacing: SLOW (avg 5-15s per cut)")
    else
        print("  Pacing: VERY SLOW (avg > 15s per cut)")
    end

    -- Rhythm: coefficient of variation (stddev/mean).
    -- Low CV = cuts are similar lengths; high CV = mixed short and long.
    if stddev / mean > 1.0 then
        print("  Rhythm:  IRREGULAR (high variation)")
    elseif stddev / mean > 0.5 then
        print("  Rhythm:  VARIED (moderate variation)")
    else
        print("  Rhythm:  CONSISTENT (low variation)")
    end
    print("  " .. string.rep("=", 45))

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

print("Timeline Arranger loaded. Commands:")
print("  arranger.reverse()                     -- reverse clip order")
print("  arranger.shuffle()                     -- randomize clip order")
print("  arranger.every_nth(3)                  -- keep every 3rd clip")
print("  arranger.every_nth(2, 'delete')        -- delete every 2nd clip")
print("  arranger.loop_section(10, 15, 4)       -- loop 10-15s section 4 times")
print("  arranger.extract({min_duration=3.0})   -- keep only clips >= 3s")
print("  arranger.analyze()                     -- pacing & rhythm analysis")

return arranger
