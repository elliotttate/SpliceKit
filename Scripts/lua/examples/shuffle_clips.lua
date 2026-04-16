--[[
  Shuffle Timeline Clips
  ──────────────────────
  Randomly reorders all clips on the timeline using direct spine
  manipulation. Transitions are removed (they don't make sense after
  reordering) but can be re-added afterward.

  Uses spine.reorder — a direct mutation of the containedItems array
  on the primary storyline (FFAnchoredCollection). No cut/paste, no
  FCPXML roundtrip, no clip loss. Undoable with Cmd+Z.

  Also available from the command palette: search "Shuffle" or "Reverse".

  HOW TO USE:
    dofile("examples/shuffle_clips.lua")

    shuffle_clips()             -- random shuffle
    shuffle_clips(42)           -- fixed seed for reproducibility
    reverse_clips()             -- reverse clip order

  PATTERNS USED:
    - Fisher-Yates shuffle: O(n) unbiased random permutation
    - spine.reorder: direct containedItems mutation with undo support
    - spine.getItems: read spine items with handles and metadata
]]

-- Get clip indices from spine (filters out transitions)
local function get_clip_indices()
    local state = sk.rpc("spine.getItems", {})
    if not state or state.error then
        return nil, tostring(state and state.error or "no spine")
    end
    local items = state.items or {}
    local indices = {}
    for _, item in ipairs(items) do
        if not (item.class or ""):find("Transition") then
            table.insert(indices, #indices)  -- 0-based
        end
    end
    return indices
end

function shuffle_clips(seed)
    math.randomseed(seed or os.time())

    local indices, err = get_clip_indices()
    if not indices then
        sk.toast("Error: " .. err)
        return
    end
    if #indices < 2 then
        sk.toast("Need at least 2 clips to shuffle")
        return
    end

    -- Fisher-Yates shuffle
    for i = #indices, 2, -1 do
        local j = math.random(1, i)
        indices[i], indices[j] = indices[j], indices[i]
    end

    local result = sk.rpc("spine.reorder", {order = indices})
    if result and result.status == "ok" then
        local msg = string.format("Shuffled %d clips", result.clipsReordered or #indices)
        sk.toast(msg)
        print(msg)
        return result.clipsReordered
    else
        print("Shuffle failed: " .. tostring(result and result.error))
    end
end

function reverse_clips()
    local indices, err = get_clip_indices()
    if not indices then
        sk.toast("Error: " .. err)
        return
    end
    if #indices < 2 then
        sk.toast("Need at least 2 clips to reverse")
        return
    end

    -- Reverse the index array
    local reversed = {}
    for i = #indices, 1, -1 do
        table.insert(reversed, indices[i])
    end

    local result = sk.rpc("spine.reorder", {order = reversed})
    if result and result.status == "ok" then
        local msg = string.format("Reversed %d clips", result.clipsReordered or #indices)
        sk.toast(msg)
        print(msg)
        return result.clipsReordered
    else
        print("Reverse failed: " .. tostring(result and result.error))
    end
end

-- Run immediately when loaded
shuffle_clips()
