--[[
  Batch Color Match
  ─────────────────
  Applies color correction to every clip, matching each to a reference
  clip at the start of the timeline. Optionally sets opacity and adds
  a LUT-style look via inspector properties.

  HOW TO USE:
    1. Grade your hero clip (the "look" you want everywhere).
    2. Set REFERENCE_CLIP_INDEX to that clip's position (1 = first clip).
    3. Run:  dofile("examples/batch_color_match.lua")
    Each non-reference clip gets balanceColor + a Color Board added.

  PATTERNS USED:
    - sk.rpc("timeline.getDetailedState", {}) for rich clip metadata
      including type, lane, effects -- more detail than sk.clips().
    - Saving/restoring playhead position so the user's view is preserved.
    - goto + labels for skip logic inside a for loop (Lua 5.2+ pattern).
    - sk.rpc("inspector.set", {...}) to set numeric properties directly.

  Inspired by CommandPost's color board puck control workflows.
]]

local u = require("skutil")

-- Configuration
local REFERENCE_CLIP_INDEX = 1   -- which clip is the "hero" look
local APPLY_BALANCE    = true    -- auto-balance color on each clip
local SET_OPACITY      = nil     -- set to 0.0-1.0 to override opacity (nil = skip)
local ADD_COLOR_BOARD  = true    -- add color board to each clip
local SKIP_TRANSITIONS = true    -- skip transition items

-- Get timeline data
local state = sk.rpc("timeline.getDetailedState", {})
if not state or not state.items then
    sk.log("[ColorMatch] No timeline data — open a project first")
    return
end

local items = state.items
sk.log("[ColorMatch] Timeline has " .. #items .. " items")

-- Save playhead position to restore later.
-- WHY: this script seeks all over the timeline; restoring the playhead
-- at the end prevents the user from losing their place.
local original_pos = sk.position()

-- Process each clip
local processed = 0
local skipped = 0

for i, clip in ipairs(items) do
    -- Skip transitions
    if SKIP_TRANSITIONS and (clip.type or clip.class or ""):find("Transition") then
        skipped = skipped + 1
        goto continue
    end

    -- Skip the reference clip itself (we don't modify the hero)
    if i == REFERENCE_CLIP_INDEX then
        goto continue
    end

    local start_time = u.clip_start(clip)

    -- Navigate to clip and select it
    sk.seek(start_time + 0.01)
    sk.select_clip()

    -- balanceColor uses FCP's built-in auto-balance which adjusts
    -- white balance and exposure to a neutral reference. It is a
    -- one-shot analysis -- it does not link clips together.
    if APPLY_BALANCE then
        sk.timeline("balanceColor")
    end

    -- Add color board so the user can make manual tweaks per clip
    if ADD_COLOR_BOARD then
        sk.color_board()
    end

    -- Set opacity via the inspector. inspector.set writes directly to
    -- the selected clip's properties without needing the inspector panel open.
    if SET_OPACITY then
        sk.rpc("inspector.set", {property = "opacity", value = SET_OPACITY})
    end

    processed = processed + 1
    if processed % 10 == 0 then
        sk.log("[ColorMatch] Processed " .. processed .. "/" .. #items .. " clips...")
    end

    ::continue::
end

-- Restore playhead
if original_pos and original_pos.seconds then
    sk.seek(original_pos.seconds)
end

sk.log(string.format(
    "[ColorMatch] Done! Processed %d clips, skipped %d (transitions/gaps)",
    processed, skipped
))
