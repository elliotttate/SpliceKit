--[[
  Project Snapshot & Diff
  ───────────────────────
  Takes a snapshot of the current timeline state and compares it
  to a previous snapshot. Shows what changed: added clips, removed
  clips, moved clips, duration changes, new effects.

  Useful for tracking edit progress, reviewing changes before
  client review, or building an edit history log.

  HOW TO USE:
    dofile("examples/project_snapshot_diff.lua")

    -- Take a baseline snapshot:
    snapshot.take("before_client_notes")

    -- ... make edits ...

    -- Compare current state against the baseline:
    snapshot.diff("before_client_notes")

    -- Compare two named snapshots against each other:
    snapshot.diff("v1_rough", "v2_fine")

    -- Manage snapshots:
    snapshot.list()
    snapshot.delete("old_one")

  PATTERNS USED:
    - Disk-persisted Lua table serialization (same as state_save_restore
      and keyword_manager) for snapshot storage
    - Composite key matching: clips are matched between snapshots using
      a "name@startTime" key. This detects added/removed clips and
      duration changes on clips that stayed in place.
    - Capturing the full clip list (name, type, start, duration, lane)
      in a single snapshot for offline comparison
    - Sorting snapshots by epoch time for chronological listing

  Inspired by CommandPost's project state management and
  snapshot capabilities.
]]

local u = require("skutil")
local snapshot = {}

local SAVE_DIR = os.getenv("HOME") .. "/Library/Application Support/SpliceKit/lua"
local SNAP_FILE = SAVE_DIR .. "/timeline_snapshots.lua"

-----------------------------------------------------------
-- Serialize/deserialize
-----------------------------------------------------------
local function serialize(val, indent)
    indent = indent or ""
    local t = type(val)
    if t == "nil" then return "nil"
    elseif t == "boolean" then return tostring(val)
    elseif t == "number" then return string.format("%.6f", val)
    elseif t == "string" then return string.format("%q", val)
    elseif t == "table" then
        local parts = {}
        local ni = indent .. "  "
        -- Array part
        local is_array = #val > 0
        if is_array then
            for i, v in ipairs(val) do
                table.insert(parts, ni .. serialize(v, ni))
            end
        end
        -- Hash part
        for k, v in pairs(val) do
            if not (is_array and type(k) == "number" and k >= 1 and k <= #val) then
                local ks = type(k) == "string" and string.format("[%q]", k) or ("[" .. tostring(k) .. "]")
                table.insert(parts, ni .. ks .. " = " .. serialize(v, ni))
            end
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
    return "nil"
end

local function load_snapshots()
    local f = io.open(SNAP_FILE, "r")
    if not f then return {} end
    local code = f:read("*a")
    f:close()
    local fn = load("return " .. code)
    if fn then
        local ok, result = pcall(fn)
        if ok and type(result) == "table" then return result end
    end
    return {}
end

local function save_snapshots(snaps)
    local f = io.open(SNAP_FILE, "w")
    if not f then return false end
    f:write(serialize(snaps))
    f:close()
    return true
end

-----------------------------------------------------------
-- Capture current timeline state
-----------------------------------------------------------
local function capture_timeline()
    local state = sk.rpc("timeline.getDetailedState", {})
    local pos = sk.position()

    local clips = {}
    if state and state.items then
        for _, item in ipairs(state.items) do
            table.insert(clips, {
                name = item.name or "unnamed",
                type = item.type or item.class or "unknown",
                start = u.clip_start(item),
                duration = u.clip_duration(item),
                lane = item.lane or 0,
            })
        end
    end

    return {
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        epoch = os.time(),
        clip_count = #clips,
        total_duration = u.timeline_duration(),
        frame_rate = pos.frameRate or 30,
        clips = clips,
    }
end

-----------------------------------------------------------
-- Take a snapshot of the current timeline state.
-- @param name  string  Optional. If omitted, generates a timestamp-based name.
-- @return string  The name the snapshot was saved under.
-----------------------------------------------------------
function snapshot.take(name)
    name = name or os.date("snap_%Y%m%d_%H%M%S")

    local data = capture_timeline()
    data.name = name

    local snaps = load_snapshots()
    snaps[name] = data
    save_snapshots(snaps)

    print(string.format("Snapshot '%s': %d clips, %.1fs duration",
        name, data.clip_count, data.total_duration))
    return name
end

-----------------------------------------------------------
-- List snapshots
-----------------------------------------------------------
function snapshot.list()
    local snaps = load_snapshots()
    local sorted = {}
    for name, s in pairs(snaps) do
        table.insert(sorted, {name = name, data = s})
    end
    table.sort(sorted, function(a, b)
        return (a.data.epoch or 0) > (b.data.epoch or 0)
    end)

    print("═══ Timeline Snapshots ═══")
    for _, entry in ipairs(sorted) do
        local s = entry.data
        print(string.format("  %-25s  %3d clips  %6.1fs  %s",
            entry.name, s.clip_count, s.total_duration, s.timestamp or ""))
    end
    if #sorted == 0 then print("  (none)") end
    print(string.format("═══ %d snapshots ═══", #sorted))
end

-----------------------------------------------------------
-- Compare two snapshots (or current state vs a saved snapshot).
-- If only name_a is given, compares that snapshot against the
-- current live timeline. If both are given, compares the two
-- saved snapshots.
--
-- @param name_a  string  Name of the first (older) snapshot.
-- @param name_b  string  Optional. Name of the second snapshot.
-- @return table  {added, removed, modified, duration_change, clip_count_change}
-----------------------------------------------------------
function snapshot.diff(name_a, name_b)
    local snaps = load_snapshots()

    local a, b
    if name_b then
        a = snaps[name_a]
        b = snaps[name_b]
        if not a then print("Snapshot '" .. name_a .. "' not found"); return end
        if not b then print("Snapshot '" .. name_b .. "' not found"); return end
    else
        -- Compare named snapshot against current state
        a = snaps[name_a]
        if not a then print("Snapshot '" .. name_a .. "' not found"); return end
        b = capture_timeline()
        b.name = "(current)"
    end

    -- Build clip lookup by name+start for matching.
    -- WHY name+start: a clip's name alone is not unique (you can have
    -- multiple copies of the same clip). Combining name with start time
    -- gives a reasonable identity for matching across snapshots.
    local function clip_key(clip)
        return string.format("%s@%.3f", clip.name, clip.start)
    end

    local a_clips = {}
    for _, c in ipairs(a.clips or {}) do
        a_clips[clip_key(c)] = c
    end

    local b_clips = {}
    for _, c in ipairs(b.clips or {}) do
        b_clips[clip_key(c)] = c
    end

    -- Find added, removed, modified clips
    local added = {}
    local removed = {}
    local modified = {}

    for key, bc in pairs(b_clips) do
        if not a_clips[key] then
            table.insert(added, bc)
        else
            local ac = a_clips[key]
            if math.abs(ac.duration - bc.duration) > 0.01 then
                table.insert(modified, {
                    name = bc.name,
                    old_dur = ac.duration,
                    new_dur = bc.duration,
                    start = bc.start,
                })
            end
        end
    end

    for key, ac in pairs(a_clips) do
        if not b_clips[key] then
            table.insert(removed, ac)
        end
    end

    -- Report
    print("")
    print("╔══════════════════════════════════════════════╗")
    print("║            TIMELINE DIFF REPORT              ║")
    print("╠══════════════════════════════════════════════╣")
    print(string.format("║  From: %-20s (%s)  ║", a.name or "?", a.timestamp or ""))
    print(string.format("║  To:   %-20s (%s)  ║", b.name or "?", b.timestamp or ""))
    print("╠══════════════════════════════════════════════╣")

    local dur_diff = (b.total_duration or 0) - (a.total_duration or 0)
    local clip_diff = (b.clip_count or 0) - (a.clip_count or 0)

    print(string.format("║  Clips:    %d → %d (%+d)                  ║",
        a.clip_count or 0, b.clip_count or 0, clip_diff))
    print(string.format("║  Duration: %.1fs → %.1fs (%+.1fs)        ║",
        a.total_duration or 0, b.total_duration or 0, dur_diff))

    if #added > 0 then
        print("╠══════════════════════════════════════════════╣")
        print(string.format("║  + ADDED (%d clips):                         ║", #added))
        for _, c in ipairs(added) do
            print(string.format("║    + %-25s at %6.1fs  ║", c.name:sub(1,25), c.start))
        end
    end

    if #removed > 0 then
        print("╠══════════════════════════════════════════════╣")
        print(string.format("║  - REMOVED (%d clips):                       ║", #removed))
        for _, c in ipairs(removed) do
            print(string.format("║    - %-25s at %6.1fs  ║", c.name:sub(1,25), c.start))
        end
    end

    if #modified > 0 then
        print("╠══════════════════════════════════════════════╣")
        print(string.format("║  ~ MODIFIED (%d clips):                      ║", #modified))
        for _, c in ipairs(modified) do
            print(string.format("║    ~ %-20s %.1fs → %.1fs   ║",
                c.name:sub(1,20), c.old_dur, c.new_dur))
        end
    end

    if #added == 0 and #removed == 0 and #modified == 0 then
        print("╠══════════════════════════════════════════════╣")
        print("║  No clip changes detected                    ║")
    end

    print("╚══════════════════════════════════════════════╝")

    return {
        added = added,
        removed = removed,
        modified = modified,
        duration_change = dur_diff,
        clip_count_change = clip_diff,
    }
end

-----------------------------------------------------------
-- Delete a snapshot
-----------------------------------------------------------
function snapshot.delete(name)
    local snaps = load_snapshots()
    if snaps[name] then
        snaps[name] = nil
        save_snapshots(snaps)
        print("Deleted snapshot '" .. name .. "'")
    else
        print("Snapshot '" .. name .. "' not found")
    end
end

-- Register globally
_G.snapshot = snapshot

print("Snapshot system loaded. Commands:")
print("  snapshot.take('name')            -- save current state")
print("  snapshot.list()                  -- list all snapshots")
print("  snapshot.diff('name')            -- compare snapshot vs current")
print("  snapshot.diff('name1', 'name2')  -- compare two snapshots")
print("  snapshot.delete('name')          -- remove a snapshot")

return snapshot
