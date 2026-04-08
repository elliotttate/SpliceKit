--[[
  State Save & Restore
  ────────────────────
  Saves the current editing state (playhead, selection, range,
  zoom level, viewer zoom, inspector values) and restores it later.
  Useful as a "bookmark" system for complex edits.

  HOW TO USE:
    -- Load the module (registers global "state_mgr"):
    dofile("examples/state_save_restore.lua")

    -- Save current state as "my_bookmark":
    state_mgr.save("my_bookmark")

    -- ... do other work ...

    -- Restore to saved state:
    state_mgr.restore("my_bookmark")

    -- List all saved states:
    state_mgr.list()

    -- Delete a specific state or all states:
    state_mgr.delete("my_bookmark")
    state_mgr.clear()

  States are persisted to disk (as serialized Lua) so they survive
  VM resets and FCP restarts.

  PATTERNS USED:
    - Disk persistence using Lua's own syntax: tables are serialized
      as valid Lua code and loaded back with load(). This avoids
      needing a JSON library.
    - Module pattern: state_mgr is a local table with function fields,
      registered as a global (_G.state_mgr) so it is callable from the
      REPL after the script finishes.
    - sk.rpc("viewer.getZoom", {}) / sk.rpc("viewer.setZoom", {...})
      for capturing and restoring viewer zoom level.
    - Separation of capture() (reads FCP state) from save() (writes
      to disk) for testability.

  Inspired by CommandPost's layout save/restore and browser state management.
]]

local state_mgr = {}

-- Persistence file
local SAVE_DIR = os.getenv("HOME") .. "/Library/Application Support/SpliceKit/lua"
local SAVE_FILE = SAVE_DIR .. "/saved_states.lua"

-----------------------------------------------------------
-- Internal: serialize a Lua value to valid Lua source code.
-- WHY Lua format: we can reload it with load() without needing
-- a JSON parser. The output is human-readable and editable.
-----------------------------------------------------------
local function serialize(val, indent)
    indent = indent or ""
    local t = type(val)
    if t == "nil" then return "nil"
    elseif t == "boolean" then return tostring(val)
    elseif t == "number" then return tostring(val)
    elseif t == "string" then return string.format("%q", val)
    elseif t == "table" then
        local parts = {}
        local next_indent = indent .. "  "
        for k, v in pairs(val) do
            local key_str
            if type(k) == "string" then
                key_str = string.format("[%q]", k)
            else
                key_str = "[" .. tostring(k) .. "]"
            end
            table.insert(parts, next_indent .. key_str .. " = " .. serialize(v, next_indent))
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
    return "nil"
end

-----------------------------------------------------------
-- Internal: load saved states from disk.
-- The file contains a Lua table literal. We prepend "return "
-- and use load() + pcall() to safely evaluate it.
-----------------------------------------------------------
local function load_states()
    local f = io.open(SAVE_FILE, "r")
    if not f then return {} end
    local code = f:read("*a")
    f:close()
    if code == "" then return {} end
    -- load() compiles the string into a Lua function; pcall() runs
    -- it in protected mode so corrupt files do not crash the script.
    local fn = load("return " .. code)
    if fn then
        local ok, result = pcall(fn)
        if ok and type(result) == "table" then return result end
    end
    return {}
end

-----------------------------------------------------------
-- Internal: persist states to disk
-----------------------------------------------------------
local function save_states(states)
    local f = io.open(SAVE_FILE, "w")
    if not f then
        sk.log("[State] Cannot write to " .. SAVE_FILE)
        return false
    end
    f:write(serialize(states))
    f:close()
    return true
end

-----------------------------------------------------------
-- Capture current FCP state
-----------------------------------------------------------
local function capture()
    local pos = sk.position()
    local viewer = sk.rpc("viewer.getZoom", {})

    return {
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        playhead = pos.seconds or 0,
        frame_rate = pos.frameRate or 30,
        is_playing = pos.isPlaying or false,
        viewer_zoom = viewer and viewer.zoom or 0,
    }
end

-----------------------------------------------------------
-- Public API
-- Each function loads fresh from disk (not cached) so that
-- multiple scripts or REPL sessions stay in sync.
-----------------------------------------------------------

--- Save the current FCP state under a named bookmark.
-- @param name  string  A unique bookmark name.
function state_mgr.save(name)
    if not name or name == "" then
        print("Usage: state_mgr.save('name')")
        return
    end

    local states = load_states()
    states[name] = capture()
    save_states(states)

    local s = states[name]
    print(string.format("Saved '%s': playhead=%.2fs, zoom=%.1f",
        name, s.playhead, s.viewer_zoom))
end

--- Restore a previously saved state by name.
-- @param name  string  The bookmark name to restore.
function state_mgr.restore(name)
    if not name or name == "" then
        print("Usage: state_mgr.restore('name')")
        return
    end

    local states = load_states()
    local s = states[name]
    if not s then
        print("State '" .. name .. "' not found. Use state_mgr.list()")
        return
    end

    -- Restore playhead
    sk.seek(s.playhead)

    -- Restore viewer zoom
    if s.viewer_zoom then
        sk.rpc("viewer.setZoom", {zoom = s.viewer_zoom})
    end

    print(string.format("Restored '%s': playhead=%.2fs", name, s.playhead))
end

--- List all saved bookmarks with their playhead positions and timestamps.
function state_mgr.list()
    local states = load_states()
    local count = 0
    print("═══ Saved States ═══")
    for name, s in pairs(states) do
        print(string.format("  %-20s  %.2fs  zoom=%.1f  (%s)",
            name, s.playhead, s.viewer_zoom or 0, s.timestamp or "?"))
        count = count + 1
    end
    if count == 0 then
        print("  (none)")
    end
    print(string.format("═══ %d states ═══", count))
end

--- Delete a single saved bookmark.
-- @param name  string  The bookmark name to delete.
function state_mgr.delete(name)
    local states = load_states()
    if states[name] then
        states[name] = nil
        save_states(states)
        print("Deleted '" .. name .. "'")
    else
        print("State '" .. name .. "' not found")
    end
end

--- Delete ALL saved bookmarks.
function state_mgr.clear()
    save_states({})
    print("All saved states cleared")
end

-- Register globally so it persists
_G.state_mgr = state_mgr

print("State manager loaded. Commands:")
print("  state_mgr.save('name')    -- save current state")
print("  state_mgr.restore('name') -- restore saved state")
print("  state_mgr.list()          -- show all saves")
print("  state_mgr.delete('name')  -- delete a save")
print("  state_mgr.clear()         -- delete all saves")

return state_mgr
