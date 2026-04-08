--[[
  Keyword Manager
  ───────────────
  Save, restore, and apply keyword presets to clips.
  Supports up to 9 keyword presets (matching CommandPost's approach)
  with named presets and batch application.

  HOW TO USE:
    dofile("examples/keyword_manager.lua")

    -- Save a keyword preset to slot 1:
    keywords.save(1, {"Interview", "A-Cam", "Indoor"}, "Interview Setup")

    -- Apply preset 1 to the clip at the playhead:
    keywords.apply(1)

    -- Apply preset 1 to ALL clips on the timeline:
    keywords.apply_all(1)

    -- Auto-tag clips based on rules (name matching + duration):
    keywords.auto_tag({
        {match = "interview", keywords = {"Interview", "A-Roll"}},
        {match = "broll",     keywords = {"B-Roll", "Cutaway"}},
        {duration_lt = 2,     keywords = {"Short", "Insert"}},
        {duration_gt = 30,    keywords = {"Long Take"}},
    })

    -- Auto-rate clips by duration (short = reject, long = favorite):
    keywords.auto_rate({reject_under = 0.5, favorite_over = 10.0})

    -- List or clear presets:
    keywords.list()
    keywords.clear(1)

  PATTERNS USED:
    - Disk-persisted presets using Lua table serialization (same
      pattern as state_save_restore.lua)
    - sk.rpc("timeline.directAction", {action="addKeywords", keywords=...})
      to apply keywords without opening the Keyword Editor panel
    - Rule-based batch processing: iterate clips, test each rule's
      conditions (name pattern, duration threshold), apply matching keywords
    - sk.timeline("favorite") / sk.timeline("reject") for rating clips

  Inspired by CommandPost's keyword preset save/restore system.
]]

local u = require("skutil")

local keywords = {}

local SAVE_DIR = os.getenv("HOME") .. "/Library/Application Support/SpliceKit/lua"
local KW_FILE = SAVE_DIR .. "/keyword_presets.lua"

-----------------------------------------------------------
-- Persistence
-----------------------------------------------------------
local function serialize(val, indent)
    indent = indent or ""
    local t = type(val)
    if t == "string" then return string.format("%q", val)
    elseif t == "number" then return tostring(val)
    elseif t == "boolean" then return tostring(val)
    elseif t == "table" then
        local parts = {}
        local ni = indent .. "  "
        for k, v in pairs(val) do
            local ks = type(k) == "number" and "" or (string.format("[%q]", k) .. " = ")
            table.insert(parts, ni .. ks .. serialize(v, ni))
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
    return "nil"
end

local function load_presets()
    local f = io.open(KW_FILE, "r")
    if not f then return {} end
    local code = f:read("*a")
    f:close()
    local fn = load("return " .. code)
    if fn then
        local ok, result = pcall(fn)
        if ok then return result end
    end
    return {}
end

local function save_presets(presets)
    local f = io.open(KW_FILE, "w")
    if not f then return false end
    f:write(serialize(presets))
    f:close()
    return true
end

-----------------------------------------------------------
-- Save a keyword preset to a numbered slot (1-9).
-- @param slot     number  Slot number (1-9).
-- @param kw_list  table   Array of keyword strings.
-- @param name     string  Optional display name for the preset.
-----------------------------------------------------------
function keywords.save(slot, kw_list, name)
    if type(slot) ~= "number" or slot < 1 or slot > 9 then
        print("Slot must be 1-9")
        return
    end
    if type(kw_list) ~= "table" then
        print("Keywords must be a table: {'keyword1', 'keyword2'}")
        return
    end

    local presets = load_presets()
    presets[slot] = {
        name = name or ("Preset " .. slot),
        keywords = kw_list,
        saved_at = os.date("%Y-%m-%d %H:%M:%S"),
    }
    save_presets(presets)

    print(string.format("Saved preset %d (%s): %s",
        slot, presets[slot].name, table.concat(kw_list, ", ")))
end

-----------------------------------------------------------
-- Apply keyword preset to the currently selected clip.
-- The clip at the playhead must be selected first (sk.select_clip()).
-- @param slot  number  Which preset slot to apply.
-----------------------------------------------------------
function keywords.apply(slot)
    local presets = load_presets()
    local preset = presets[slot]
    if not preset then
        print("Preset " .. slot .. " not set. Use keywords.save(" .. slot .. ", {'kw1','kw2'})")
        return
    end

    -- Apply keywords via direct action
    sk.rpc("timeline.directAction", {
        action = "addKeywords",
        keywords = preset.keywords
    })

    print(string.format("Applied preset %d (%s): %s",
        slot, preset.name, table.concat(preset.keywords, ", ")))
end

-----------------------------------------------------------
-- Apply keyword preset to every real clip on the timeline.
-- Iterates all items, skips gaps and transitions, seeks to each
-- clip's start, selects it, and applies keywords.
-- @param slot  number  Which preset slot to apply.
-----------------------------------------------------------
function keywords.apply_all(slot)
    local presets = load_presets()
    local preset = presets[slot]
    if not preset then
        print("Preset " .. slot .. " not set")
        return
    end

    local state = sk.clips()
    local items = state.items or {}
    local applied = 0

    for _, clip in ipairs(items) do
        local start_t = u.clip_start(clip)
        local clip_type = clip.type or clip.class or ""

        if not clip_type:find("Gap") and not clip_type:find("Transition") then
            sk.seek(start_t + 0.01)
            sk.select_clip()
            sk.rpc("timeline.directAction", {
                action = "addKeywords",
                keywords = preset.keywords
            })
            applied = applied + 1
        end
    end

    print(string.format("Applied preset %d (%s) to %d clips",
        slot, preset.name, applied))
end

-----------------------------------------------------------
-- Apply keywords based on clip properties (rule-based tagging).
-- Each rule is tested independently against every clip. A clip can
-- match multiple rules and accumulate keywords from all of them.
--
-- @param rules  table  Array of rule tables, each with optional fields:
--   .match        string  Pattern to match against clip name (case insensitive)
--   .duration_lt  number  Match clips shorter than this many seconds
--   .duration_gt  number  Match clips longer than this many seconds
--   .keywords     table   Array of keyword strings to apply on match
-----------------------------------------------------------
function keywords.auto_tag(rules)
    local state = sk.clips()
    local items = state.items or {}
    local tagged = 0

    for _, clip in ipairs(items) do
        local clip_name = (clip.name or ""):lower()
        local dur = u.clip_duration(clip)
        local start_t = u.clip_start(clip)
        local clip_type = clip.type or clip.class or ""

        if clip_type:find("Gap") or clip_type:find("Transition") then
            goto next_clip
        end

        for _, rule in ipairs(rules) do
            local matches = false

            if rule.match and clip_name:find(rule.match:lower()) then
                matches = true
            end
            if rule.duration_lt and dur < rule.duration_lt then
                matches = true
            end
            if rule.duration_gt and dur > rule.duration_gt then
                matches = true
            end

            if matches then
                sk.seek(start_t + 0.01)
                sk.select_clip()
                sk.rpc("timeline.directAction", {
                    action = "addKeywords",
                    keywords = rule.keywords
                })
                tagged = tagged + 1
            end
        end

        ::next_clip::
    end

    print(string.format("Auto-tagged %d clips", tagged))
end

-----------------------------------------------------------
-- Rate clips by duration (short = reject, long = favorite).
-- Clips between reject_under and favorite_over are left unrated.
--
-- @param config  table  Optional. Fields:
--   .reject_under   number  Reject clips shorter than this (default 0.5s)
--   .favorite_over  number  Favorite clips longer than this (default 10s)
-----------------------------------------------------------
function keywords.auto_rate(config)
    config = config or {}
    local reject_under = config.reject_under or 0.5    -- reject clips < 0.5s
    local favorite_over = config.favorite_over or 10.0 -- favorite clips > 10s

    local state = sk.clips()
    local items = state.items or {}
    local favorites = 0
    local rejects = 0

    for _, clip in ipairs(items) do
        local dur = u.clip_duration(clip)
        local start_t = u.clip_start(clip)
        local clip_type = clip.type or clip.class or ""

        if clip_type:find("Gap") or clip_type:find("Transition") then
            goto next_clip
        end

        sk.seek(start_t + 0.01)
        sk.select_clip()

        if dur < reject_under then
            sk.timeline("reject")
            rejects = rejects + 1
        elseif dur > favorite_over then
            sk.timeline("favorite")
            favorites = favorites + 1
        end

        ::next_clip::
    end

    print(string.format("Rated %d clips: %d favorites, %d rejects",
        favorites + rejects, favorites, rejects))
end

-----------------------------------------------------------
-- List all presets
-----------------------------------------------------------
function keywords.list()
    local presets = load_presets()

    print("═══ Keyword Presets ═══")
    for slot = 1, 9 do
        local p = presets[slot]
        if p then
            print(string.format("  %d. %-15s  %s  (%s)",
                slot, p.name, table.concat(p.keywords, ", "), p.saved_at or ""))
        else
            print(string.format("  %d. (empty)", slot))
        end
    end
    print("═══════════════════════")
end

-----------------------------------------------------------
-- Clear a preset
-----------------------------------------------------------
function keywords.clear(slot)
    local presets = load_presets()
    presets[slot] = nil
    save_presets(presets)
    print("Cleared preset " .. slot)
end

-- Register globally
_G.keywords = keywords

print("Keyword manager loaded. Commands:")
print("  keywords.save(1, {'Interview','A-Cam'})  -- save preset")
print("  keywords.apply(1)                        -- apply to selected")
print("  keywords.apply_all(1)                    -- apply to all clips")
print("  keywords.auto_tag(rules)                 -- rule-based tagging")
print("  keywords.auto_rate({reject_under=0.5})   -- auto rate by duration")
print("  keywords.list()                          -- show all presets")

return keywords
