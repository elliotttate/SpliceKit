--[[
  Conform Tool -- EDL/CSV-Driven Timeline Assembly
  ────────────────────────────────────────────────
  Reads an edit decision list (CSV or structured table) and
  conforms the timeline to match: blade at specified times,
  reorder clips, apply speed changes, add markers, and set
  in/out ranges.

  Supports:
  - CSV-based conform lists
  - Marker-based chapter creation (YouTube/podcast)
  - Speed map application (variable speed across timeline)
  - Clip removal by name pattern or time range
  - Timeline restructuring from a shot list

  This is a "programmable edit" -- define your edit as data,
  then execute it.

  HOW TO USE:
    dofile("examples/conform_tool.lua")

    -- Apply an EDL from CSV text:
    conform.apply_edl(
      "action,time,name\n" ..
      "chapter,00:00:00,Intro\n" ..
      "chapter,00:05:00,Topic 1\n" ..
      "blade,00:10:30\n" ..
      "speed,00:12:00,0.5\n" ..
      "remove_range,00:15:00,00:16:00\n"
    )

    -- Create YouTube chapters from a table:
    conform.create_chapters({
        {time = 0,    title = "Intro"},
        {time = 300,  title = "Setup"},
        {time = 600,  title = "Main Topic"},
        {time = 1200, title = "Wrap Up"},
    })

    -- Apply variable speed across the timeline:
    conform.apply_speed_map({
        {time = 0,  speed = 1.0},   -- normal
        {time = 10, speed = 2.0},   -- fast forward
        {time = 20, speed = 0.5},   -- slow motion
        {time = 30, speed = 1.0},   -- back to normal
    })

    -- Remove clips by name pattern or time range:
    conform.remove_clips({pattern = "b-roll"})
    conform.remove_clips({from = 10.0, to = 20.0})
    conform.remove_clips({shorter_than = 1.0})
    conform.remove_clips({lane = 1})

    -- Generate a storyboard with thumbnails:
    conform.storyboard("/tmp/my_storyboard")

  PATTERNS USED:
    - Data-driven editing: edits are described as data structures
      (CSV rows, Lua tables), not imperative code. This makes edits
      reproducible, versionable, and shareable.
    - conform.parse_csv(): lightweight CSV parser that auto-converts
      numeric fields and supports optional headers
    - conform.parse_tc(): multi-format timecode parser that handles
      HH:MM:SS:FF, HH:MM:SS.mmm, MM:SS, and raw seconds
    - Reverse-order deletion in remove_clips() so position shifts
      from ripple-delete do not affect unprocessed items
    - Speed map: blade at each speed-change point first, then set
      rates on the resulting segments (two-pass approach because
      blading must happen before retiming)
    - Storyboard generation: seek to each clip's midpoint, screenshot
      the viewer, and write an index file

  ARCHITECTURE NOTE:
    All functions are methods on the `conform` table, registered as
    a global. They are designed to be composed: you can call
    remove_clips() followed by create_chapters() followed by
    apply_speed_map() in any order.
]]

local u = require("skutil")

local conform = {}

-----------------------------------------------------------
-- Parse a CSV string into a table of records.
-- If the first row looks like a header (has_header ~= false),
-- it becomes the keys for each record table. Otherwise records
-- are numerically indexed.
--
-- @param csv_text    string   Raw CSV text.
-- @param has_header  boolean  Default true. Set false if no header row.
-- @return table  Array of record tables.
-----------------------------------------------------------
function conform.parse_csv(csv_text, has_header)
    local lines = {}
    for line in csv_text:gmatch("[^\n]+") do
        table.insert(lines, line)
    end

    local headers = nil
    local start_idx = 1

    if has_header ~= false and #lines > 0 then
        headers = {}
        for field in lines[1]:gmatch("[^,]+") do
            table.insert(headers, field:match("^%s*(.-)%s*$"))
        end
        start_idx = 2
    end

    local records = {}
    for i = start_idx, #lines do
        local fields = {}
        local idx = 1
        for field in lines[i]:gmatch("[^,]+") do
            field = field:match("^%s*(.-)%s*$")
            -- Try to convert to number
            local num = tonumber(field)
            if headers then
                fields[headers[idx]] = num or field
            else
                fields[idx] = num or field
            end
            idx = idx + 1
        end
        table.insert(records, fields)
    end

    return records
end

-----------------------------------------------------------
-- Parse timecode string to seconds.
-- Supports multiple formats, tried in order of specificity:
--   "01:02:03:15" -> HH:MM:SS:FF (frame-based, needs fps)
--   "01:02:03.500" -> HH:MM:SS.mmm (millisecond-based)
--   "02:03.5"     -> MM:SS.mmm
--   "123.4"       -> raw seconds
--   123.4         -> passthrough (already a number)
--
-- @param tc_str  string|number  Timecode string or seconds.
-- @param fps     number         Frame rate for :FF conversion (default 30).
-- @return number  Time in seconds.
-----------------------------------------------------------
function conform.parse_tc(tc_str, fps)
    fps = fps or 30
    if type(tc_str) == "number" then return tc_str end
    if not tc_str or tc_str == "" then return 0 end

    -- HH:MM:SS:FF format (4 colon-separated groups)
    local h, m, s, f = tc_str:match("(%d+):(%d+):(%d+):(%d+)")
    if h then
        return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) + tonumber(f) / fps
    end

    -- HH:MM:SS.mmm format (3 groups, last may have decimal)
    local h2, m2, s2 = tc_str:match("(%d+):(%d+):([%d%.]+)")
    if h2 then
        return tonumber(h2) * 3600 + tonumber(m2) * 60 + tonumber(s2)
    end

    -- MM:SS format (2 groups)
    local m3, s3 = tc_str:match("(%d+):([%d%.]+)")
    if m3 then
        return tonumber(m3) * 60 + tonumber(s3)
    end

    -- Raw number (seconds)
    return tonumber(tc_str) or 0
end

-----------------------------------------------------------
-- Apply a speed map: [{time, speed}, ...]
-- Two-pass approach: first blade at every speed-change point
-- to create segment boundaries, then set the rate on each segment.
-- WHY two passes: retiming changes clip duration, which would shift
-- the positions of subsequent blade points. Blading first at all
-- positions avoids this issue.
--
-- @param speed_map  table  Array of {time=seconds, speed=rate}.
-- @return number  Count of speed changes applied.
-----------------------------------------------------------
function conform.apply_speed_map(speed_map)
    if not speed_map or #speed_map == 0 then
        print("No speed map provided")
        return
    end

    -- Sort by time
    table.sort(speed_map, function(a, b) return a.time < b.time end)

    -- Blade at each point first
    sk.log("[Conform] Blading at " .. #speed_map .. " speed change points...")
    for _, entry in ipairs(speed_map) do
        sk.seek(entry.time)
        sk.blade()
    end

    -- Pass 2: apply speeds (work forwards -- blade positions are stable
    -- because we bladed ALL points first before retiming any segment).
    local applied = 0
    for _, entry in ipairs(speed_map) do
        local speed = entry.speed or 1.0
        if speed ~= 1.0 then
            sk.seek(entry.time + 0.01)
            sk.select_clip()

            -- Use named retime actions for common presets (these use FCP's
            -- optimized retime path), fall back to directAction for arbitrary rates.
            if speed == 0.5 then
                sk.timeline("retimeSlow50")
            elseif speed == 0.25 then
                sk.timeline("retimeSlow25")
            elseif speed == 2.0 then
                sk.timeline("retimeFast2x")
            elseif speed == 4.0 then
                sk.timeline("retimeFast4x")
            elseif speed == 8.0 then
                sk.timeline("retimeFast8x")
            else
                -- directAction.retimeSetRate accepts any float rate.
                -- ripple=false prevents the rest of the timeline from shifting.
                sk.rpc("timeline.directAction", {
                    action = "retimeSetRate",
                    rate = speed,
                    ripple = false
                })
            end
            applied = applied + 1
        end
    end

    sk.log(string.format("[Conform] Applied %d speed changes", applied))
    return applied
end

-----------------------------------------------------------
-- Create chapter markers from a chapter list.
-- Accepts times as timecodes or seconds. Creates FCP chapter
-- markers (which export to YouTube chapters, podcast chapters, etc.)
--
-- @param chapters  table   Array of {time, title}. time can be
--                          string timecode or number (seconds).
-- @param fps       number  Frame rate for timecode parsing (default 30).
-- @return number   Count of chapters created.
-----------------------------------------------------------
function conform.create_chapters(chapters, fps)
    fps = fps or 30
    if not chapters or #chapters == 0 then
        print("No chapters provided")
        return
    end

    local created = 0
    for _, ch in ipairs(chapters) do
        local t = conform.parse_tc(ch.time or ch.tc or ch.timecode, fps)
        local title = ch.title or ch.name or ("Chapter " .. (created + 1))

        sk.seek(t)
        sk.timeline("addChapterMarker")

        -- Rename marker
        sk.rpc("timeline.directAction", {
            action = "changeMarkerName",
            name = title
        })

        created = created + 1
    end

    sk.log(string.format("[Conform] Created %d chapter markers", created))
    return created
end

-----------------------------------------------------------
-- Remove clips matching a pattern or time range.
-- Multiple criteria can be combined. A clip is removed if ANY
-- criterion matches (OR logic).
--
-- @param criteria  table  Filter criteria (all optional, OR-combined):
--   .pattern       string  Case-insensitive name substring match
--   .from/.to      number  Remove clips within this time range
--   .shorter_than  number  Remove clips shorter than N seconds
--   .longer_than   number  Remove clips longer than N seconds
--   .lane          number  Remove clips in this lane only
-- @return number   Count of clips removed.
-----------------------------------------------------------
function conform.remove_clips(criteria)
    local state = sk.rpc("timeline.getDetailedState", {})
    local items = state and state.items or {}
    local removed = 0
    local to_remove = {}

    -- Build removal list
    for _, clip in ipairs(items) do
        if not u.is_real_clip(clip) then goto skip end

        local dominated = false
        local name = (clip.name or ""):lower()
        local start_t = u.clip_start(clip)
        local end_t = u.clip_end(clip)

        -- Pattern match on name
        if criteria.pattern then
            if name:find(criteria.pattern:lower()) then
                dominated = true
            end
        end

        -- Time range match
        if criteria.from and criteria.to then
            if start_t >= criteria.from and end_t <= criteria.to then
                dominated = true
            end
        end

        -- Duration filter
        if criteria.shorter_than then
            if u.clip_duration(clip) < criteria.shorter_than then
                dominated = true
            end
        end

        if criteria.longer_than then
            if u.clip_duration(clip) > criteria.longer_than then
                dominated = true
            end
        end

        -- Lane filter
        if criteria.lane then
            if (clip.lane or 0) == criteria.lane then
                dominated = true
            end
        end

        if dominated then
            table.insert(to_remove, {start = start_t, name = clip.name})
        end

        ::skip::
    end

    -- Remove in reverse order (latest first) so that ripple-delete
    -- does not shift the start times of clips we have not yet processed.
    table.sort(to_remove, function(a, b) return a.start > b.start end)

    for _, r in ipairs(to_remove) do
        sk.seek(r.start + 0.01)
        sk.select_clip()
        sk.timeline("delete")
        removed = removed + 1
    end

    sk.log(string.format("[Conform] Removed %d clips", removed))
    return removed
end

-----------------------------------------------------------
-- Apply an edit decision list from CSV.
-- Each row describes one action. Supported actions:
--   blade         -- cut at the given time
--   marker        -- add a standard marker (with optional name)
--   chapter       -- add a chapter marker (with optional name)
--   speed         -- blade + set speed on the segment
--   remove_range  -- delete everything between time and end_time
--
-- CSV columns: action, time, [name or speed or end_time]
--
-- @param csv_text  string  CSV text (with or without header row).
-- @param fps       number  Frame rate for timecode parsing (default: auto).
-- @return number   Count of EDL entries applied.
-----------------------------------------------------------
function conform.apply_edl(csv_text, fps)
    fps = fps or sk.position().frameRate or 30
    local records = conform.parse_csv(csv_text)
    local applied = 0

    for _, rec in ipairs(records) do
        local action = rec.action or rec[1]
        local time_str = rec.time or rec.tc or rec[2]
        local t = conform.parse_tc(time_str, fps)

        if action == "blade" then
            sk.seek(t)
            sk.blade()
            applied = applied + 1

        elseif action == "marker" then
            sk.seek(t)
            sk.add_marker()
            local name = rec.name or rec.title or rec[3]
            if name then
                sk.rpc("timeline.directAction", {
                    action = "changeMarkerName", name = name
                })
            end
            applied = applied + 1

        elseif action == "chapter" then
            sk.seek(t)
            sk.timeline("addChapterMarker")
            local name = rec.name or rec.title or rec[3]
            if name then
                sk.rpc("timeline.directAction", {
                    action = "changeMarkerName", name = name
                })
            end
            applied = applied + 1

        elseif action == "speed" then
            local spd = tonumber(rec.speed or rec[3]) or 1.0
            sk.seek(t)
            sk.blade()
            sk.seek(t + 0.01)
            sk.select_clip()
            sk.rpc("timeline.directAction", {
                action = "retimeSetRate", rate = spd, ripple = false
            })
            applied = applied + 1

        elseif action == "remove_range" then
            local end_str = rec.end_time or rec[3]
            local end_t = conform.parse_tc(end_str, fps)
            conform.remove_clips({from = t, to = end_t})
            applied = applied + 1
        end
    end

    sk.log(string.format("[Conform] Applied %d EDL entries", applied))
    return applied
end

-----------------------------------------------------------
-- Build a storyboard: capture a representative thumbnail from
-- each clip and write an index file listing all clips with
-- timecodes.
--
-- @param output_dir  string  Directory to save thumbnails and index
--                            (default: /tmp/storyboard).
-- @return table  Array of {index, name, start, duration, thumbnail, ...}.
-----------------------------------------------------------
function conform.storyboard(output_dir)
    output_dir = output_dir or (os.tmpname():match("(.+)/") .. "/storyboard")

    -- Create output directory
    sk.eval("[[NSFileManager defaultManager] createDirectoryAtPath:@'" ..
            output_dir .. "' withIntermediateDirectories:YES attributes:nil error:nil]")

    local state = sk.rpc("timeline.getDetailedState", {})
    local items = state and state.items or {}
    local fps = sk.position().frameRate or 30

    local board = {}
    local clip_idx = 0

    for _, clip in ipairs(items) do
        if not u.is_real_clip(clip) then goto skip end

        clip_idx = clip_idx + 1
        local start_t = u.clip_start(clip)
        local dur = u.clip_duration(clip)
        local mid = start_t + dur / 2

        -- Capture thumbnail at middle of clip
        sk.seek(mid)
        sk.sleep(0.15)
        local thumb_path = string.format("%s/clip_%03d.png", output_dir, clip_idx)
        sk.rpc("viewer.capture", {path = thumb_path})

        table.insert(board, {
            index = clip_idx,
            name = clip.name or "clip",
            start = start_t,
            duration = dur,
            start_tc = u.timecode(start_t, fps),
            end_tc = u.timecode(start_t + dur, fps),
            lane = clip.lane or 0,
            thumbnail = thumb_path,
        })

        ::skip::
    end

    -- Write index file
    local idx_path = output_dir .. "/index.txt"
    local f = io.open(idx_path, "w")
    if f then
        f:write("STORYBOARD — " .. os.date() .. "\n")
        f:write(string.rep("=", 60) .. "\n\n")
        for _, entry in ipairs(board) do
            f:write(string.format("#%d  %s\n", entry.index, entry.name))
            f:write(string.format("    TC: %s → %s  (%.1fs)\n",
                entry.start_tc, entry.end_tc, entry.duration))
            f:write(string.format("    Thumb: %s\n\n", entry.thumbnail))
        end
        f:close()
    end

    sk.log(string.format("[Conform] Storyboard: %d clips, saved to %s", #board, output_dir))

    print(string.format("Storyboard created: %d clips", #board))
    print("  Output: " .. output_dir)
    print("  Index:  " .. idx_path)

    return board
end

-- Register globally
_G.conform = conform

print("Conform tool loaded. Commands:")
print("  conform.apply_edl(csv)                -- apply EDL from CSV")
print("  conform.apply_speed_map(map)          -- variable speed across timeline")
print("  conform.create_chapters(list)         -- create chapter markers")
print("  conform.remove_clips({pattern='...'}) -- remove matching clips")
print("  conform.storyboard('/path')           -- capture storyboard thumbnails")
print("  conform.parse_tc('01:30:00:00', 24)   -- parse timecode to seconds")
print("")
print("EDL CSV format: action,time,param  (actions: blade, marker, chapter, speed)")

return conform
