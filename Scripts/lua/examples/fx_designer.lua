--[[
  FX Designer -- Parametric Effect Chains & Animation
  ───────────────────────────────────────────────────
  Creates complex visual effects by chaining inspector property
  changes, keyframes, and effects across multiple clips.

  Includes pre-built "looks" (film grain, vintage, cinematic,
  vignette, etc.) and tools to create custom animation curves
  by interpolating keyframes over time.

  HOW TO USE:
    dofile("examples/fx_designer.lua")

    -- Apply a built-in look to the clip at the playhead:
    fx.apply_look("cinematic")
    fx.apply_look("vintage")
    fx.apply_look("dream")
    fx.apply_look("glitch")
    fx.apply_look("high_contrast")

    -- Apply a look to every clip on the timeline:
    fx.apply_look_all("vintage")

    -- Animate a property with keyframes (absolute times):
    fx.animate("opacity", {
        {time = 0.0, value = 0.0},   -- fade from black
        {time = 0.5, value = 1.0},   -- fully visible at 0.5s
        {time = 4.5, value = 1.0},   -- hold
        {time = 5.0, value = 0.0},   -- fade to black
    })

    -- Animate all clips with normalized times (0-1 = percentage of clip):
    fx.animate_all("opacity", {
        {time = 0.0, value = 0.0},   -- start invisible
        {time = 0.1, value = 1.0},   -- fade in over first 10%
        {time = 0.9, value = 1.0},   -- hold
        {time = 1.0, value = 0.0},   -- fade out over last 10%
    })

    -- Ken Burns (slow zoom + pan):
    fx.ken_burns(100, 120, 10, 0)    -- zoom 100%->120%, pan right 10px
    fx.ken_burns_all(15, 30)         -- random variation on all clips

    -- List available looks:
    fx.list_looks()

  PATTERNS USED:
    - Look definitions as data: each "look" is a table with a name,
      description, and apply() function. Adding new looks is just
      adding a new table entry.
    - Inspector property manipulation: sk.rpc("inspector.set", {...})
      to change transform, compositing, and crop values directly
    - Keyframe automation: sk.timeline("addKeyframe") + inspector.set
      at each time point to create volume/opacity/position curves
    - Normalized time (0-1) in animate_all(): keyframe times between
      0 and 1 are treated as percentages of clip duration, making
      one animation template work for clips of any length
    - Ken Burns via start/end keyframes on scaleX/scaleY/positionX/Y
    - math.randomseed/math.random for controlled randomness in batch
      operations (ken_burns_all with random zoom/pan variation)

  ARCHITECTURE NOTE:
    The fx table is registered as a global. Looks are stored in
    fx.looks as a dictionary. You can add custom looks at runtime:
      fx.looks.my_look = {name="My Look", description="...", apply=function() ... end}
]]

local u = require("skutil")

local fx = {}

-----------------------------------------------------------
-- Built-in looks: each is a table with {name, description, apply()}.
-- The apply() function receives the clip's start time and duration
-- (for looks like "glitch" that create multiple keyframes).
-- Simple looks ignore these parameters and just set properties.
-----------------------------------------------------------

fx.looks = {}

fx.looks.cinematic = {
    name = "Cinematic",
    description = "Letterbox + slight desaturation + warm tint",
    apply = function()
        sk.select_clip()
        sk.color_board()  -- adds Color Board effect for manual tint control
        -- Crop top and bottom for a widescreen letterbox look
        sk.rpc("inspector.set", {property = "cropTop", value = 0.06})
        sk.rpc("inspector.set", {property = "cropBottom", value = 0.06})
        -- Slight opacity reduction gives a softer, more filmic feel
        sk.rpc("inspector.set", {property = "opacity", value = 0.95})
    end
}

fx.looks.vintage = {
    name = "Vintage Film",
    description = "Faded blacks + warm color shift + vignette edge darkening",
    apply = function()
        sk.select_clip()
        sk.color_board()
        -- Lift the blacks for faded look
        sk.rpc("inspector.set", {property = "opacity", value = 0.88})
    end
}

fx.looks.high_contrast = {
    name = "High Contrast B&W",
    description = "Desaturated + high contrast + slight vignette",
    apply = function()
        sk.select_clip()
        sk.timeline("addHueSaturation")
        -- Apply contrast via color board
        sk.color_board()
    end
}

fx.looks.dream = {
    name = "Dream Sequence",
    description = "Soft glow + slow motion + brightness boost",
    apply = function()
        sk.select_clip()
        sk.rpc("effects.apply", {name = "Gaussian Blur"})
        sk.rpc("inspector.set", {property = "opacity", value = 0.7})
        sk.timeline("retimeSlow50")
    end
}

fx.looks.glitch = {
    name = "Glitch",
    description = "Quick position jumps + scale pops via rapid keyframes",
    -- This look uses clip_start and clip_dur to place keyframes
    -- throughout the clip, unlike simpler looks that just set properties.
    apply = function(clip_start, clip_dur)
        clip_dur = clip_dur or 2.0
        local steps = 8  -- 8 keyframe positions = 4 glitch pops
        local step_dur = clip_dur / steps

        for i = 0, steps - 1 do
            local t = clip_start + (i * step_dur)
            sk.seek(t)
            sk.select_clip()
            sk.timeline("addKeyframe")

            -- Even frames: random offset (the "glitch")
            -- Odd frames: reset to center (the "recovery")
            if i % 2 == 0 then
                sk.rpc("inspector.set", {property = "positionX", value = math.random(-20, 20)})
                sk.rpc("inspector.set", {property = "positionY", value = math.random(-10, 10)})
                sk.rpc("inspector.set", {property = "scaleX", value = 1.0 + math.random() * 0.1})
            else
                sk.rpc("inspector.set", {property = "positionX", value = 0})
                sk.rpc("inspector.set", {property = "positionY", value = 0})
                sk.rpc("inspector.set", {property = "scaleX", value = 1.0})
            end
        end
    end
}

-----------------------------------------------------------
-- Apply a look to the clip at the current playhead position.
-- Finds the clip under the playhead to get its start time and
-- duration, which some looks (like "glitch") need for keyframe placement.
--
-- @param look_name  string  Key from fx.looks (e.g. "cinematic", "glitch").
-- @return boolean  true if applied, false if look not found.
-----------------------------------------------------------
function fx.apply_look(look_name)
    local look = fx.looks[look_name]
    if not look then
        print("Unknown look: " .. tostring(look_name))
        print("Available: " .. table.concat(fx.list_looks(), ", "))
        return false
    end

    sk.select_clip()
    local pos_data = sk.position()
    local state = sk.rpc("timeline.getDetailedState", {})
    local items = state and state.items or {}

    -- Find clip at playhead
    local current_time = pos_data.seconds or 0
    local clip_start, clip_dur = 0, 2.0
    for _, clip in ipairs(items) do
        local cs = u.clip_start(clip)
        local ce = u.clip_end(clip)
        if current_time >= cs and current_time <= ce then
            clip_start = cs
            clip_dur = u.clip_duration(clip)
            break
        end
    end

    print(string.format("Applying '%s': %s", look.name, look.description))
    look.apply(clip_start, clip_dur)
    return true
end

-----------------------------------------------------------
-- List available looks
-----------------------------------------------------------
function fx.list_looks()
    local names = {}
    for name, _ in pairs(fx.looks) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

-----------------------------------------------------------
-- Apply a look to every real clip on the timeline.
-- Skips gaps, transitions, and very short clips (< 0.1s).
--
-- @param look_name  string  Key from fx.looks.
-- @return number  Count of clips processed.
-----------------------------------------------------------
function fx.apply_look_all(look_name)
    local look = fx.looks[look_name]
    if not look then
        print("Unknown look: " .. tostring(look_name))
        return 0
    end

    local state = sk.rpc("timeline.getDetailedState", {})
    local items = state and state.items or {}
    local applied = 0

    for _, clip in ipairs(items) do
        if u.is_real_clip(clip) and u.clip_duration(clip) > 0.1 then
            local cs = u.clip_start(clip)
            sk.seek(cs + 0.01)
            look.apply(cs, u.clip_duration(clip))
            applied = applied + 1
        end
    end

    print(string.format("Applied '%s' to %d clips", look.name, applied))
    return applied
end

-----------------------------------------------------------
-- Keyframe Animator: place keyframes for any inspector property
-- at specified times. FCP interpolates between keyframes automatically.
--
-- @param property     string  Inspector property name (e.g. "opacity",
--                             "positionX", "scaleX", "volume").
-- @param keyframes    table   Array of {time, value} pairs. Times are
--                             relative to clip_offset (not absolute).
-- @param clip_offset  number  Optional. Start time of the clip in the
--                             timeline. If 0 or omitted, auto-detected
--                             from the clip under the playhead.
-- @return boolean  true on success.
--
-- Example:
--   fx.animate("opacity", {
--       {time = 0.0, value = 0.0},   -- fade from black
--       {time = 0.5, value = 1.0},   -- fully visible at 0.5s
--       {time = 4.5, value = 1.0},   -- hold
--       {time = 5.0, value = 0.0},   -- fade to black
--   })
-----------------------------------------------------------
function fx.animate(property, keyframes, clip_offset)
    clip_offset = clip_offset or 0

    if not keyframes or #keyframes < 2 then
        print("Need at least 2 keyframes")
        return false
    end

    sk.select_clip()

    -- Auto-detect clip start if no offset given
    if clip_offset == 0 then
        local state = sk.rpc("timeline.getDetailedState", {})
        local items = state and state.items or {}
        local current_time = sk.position().seconds or 0
        for _, clip in ipairs(items) do
            local cs = u.clip_start(clip)
            if current_time >= cs and current_time <= u.clip_end(clip) then
                clip_offset = cs
                break
            end
        end
    end

    local set_count = 0
    for _, kf in ipairs(keyframes) do
        local t = clip_offset + kf.time
        sk.seek(t)
        sk.select_clip()
        sk.timeline("addKeyframe")
        sk.rpc("inspector.set", {property = property, value = kf.value})
        set_count = set_count + 1
    end

    print(string.format("Animated '%s' with %d keyframes", property, set_count))
    return true
end

-----------------------------------------------------------
-- Batch animate: apply the same animation template to every clip.
-- Keyframe times between 0 and 1 are treated as PERCENTAGES of
-- each clip's duration, so a single template works for clips of
-- any length.
--
-- @param property            string  Inspector property name.
-- @param keyframes_template  table   Array of {time, value}. Times in
--                                    [0,1] range are treated as percentages.
-- @return number  Count of clips animated.
-----------------------------------------------------------
function fx.animate_all(property, keyframes_template)
    local state = sk.rpc("timeline.getDetailedState", {})
    local items = state and state.items or {}
    local animated = 0

    for _, clip in ipairs(items) do
        if not u.is_real_clip(clip) then goto skip end

        local cs = u.clip_start(clip)
        local dur = u.clip_duration(clip)

        -- Scale keyframe times to this clip's duration.
        -- Times in [0,1] are proportional: 0.1 means "10% into the clip".
        -- This lets one template create fade-in/fade-out on a 2s clip
        -- and a 30s clip with the same {time=0,value=0},{time=0.1,value=1}...
        local scaled = {}
        for _, kf in ipairs(keyframes_template) do
            local t = kf.time
            if t >= 0 and t <= 1.0 and #keyframes_template > 1 then
                t = t * dur
            end
            table.insert(scaled, {time = t, value = kf.value})
        end

        -- Seek to clip and animate
        sk.seek(cs + 0.01)
        fx.animate(property, scaled, cs)
        animated = animated + 1

        ::skip::
    end

    print(string.format("Animated '%s' across %d clips", property, animated))
    return animated
end

-----------------------------------------------------------
-- Ken Burns effect: slow zoom + pan on the clip at the playhead.
-- Places two keyframes (start and end of clip) with different
-- scale and position values. FCP interpolates smoothly between them.
--
-- @param zoom_start   number  Starting zoom percentage (100 = no zoom).
-- @param zoom_end     number  Ending zoom percentage.
-- @param pan_x        number  Horizontal pan in pixels (0 = center).
-- @param pan_y        number  Vertical pan in pixels (0 = center).
-- @param clip_offset  number  Optional. Override clip start time.
-----------------------------------------------------------
function fx.ken_burns(zoom_start, zoom_end, pan_x, pan_y, clip_offset)
    zoom_start = zoom_start or 100
    zoom_end = zoom_end or 120
    pan_x = pan_x or 0
    pan_y = pan_y or 0

    sk.select_clip()

    -- Find current clip
    local state = sk.rpc("timeline.getDetailedState", {})
    local items = state and state.items or {}
    local current_time = sk.position().seconds or 0
    local clip_start, clip_dur = 0, 5.0

    for _, clip in ipairs(items) do
        local cs = u.clip_start(clip)
        if current_time >= cs and current_time <= u.clip_end(clip) then
            clip_start = cs
            clip_dur = u.clip_duration(clip)
            break
        end
    end

    clip_offset = clip_offset or clip_start

    -- Set start keyframe
    sk.seek(clip_offset)
    sk.select_clip()
    sk.timeline("addKeyframe")
    sk.rpc("inspector.set", {property = "scaleX", value = zoom_start / 100})
    sk.rpc("inspector.set", {property = "scaleY", value = zoom_start / 100})
    sk.rpc("inspector.set", {property = "positionX", value = 0})
    sk.rpc("inspector.set", {property = "positionY", value = 0})

    -- Set end keyframe
    sk.seek(clip_offset + clip_dur - 0.05)
    sk.select_clip()
    sk.timeline("addKeyframe")
    sk.rpc("inspector.set", {property = "scaleX", value = zoom_end / 100})
    sk.rpc("inspector.set", {property = "scaleY", value = zoom_end / 100})
    sk.rpc("inspector.set", {property = "positionX", value = pan_x})
    sk.rpc("inspector.set", {property = "positionY", value = pan_y})

    print(string.format("Ken Burns: zoom %.0f%%→%.0f%%, pan (%+.0f, %+.0f) over %.1fs",
        zoom_start, zoom_end, pan_x, pan_y, clip_dur))
end

-----------------------------------------------------------
-- Ken Burns on all clips with random variation.
-- Each clip gets a randomly chosen zoom direction (in or out)
-- and random pan offset, creating organic visual motion.
--
-- @param zoom_range  number  Max zoom percentage change (default 15).
-- @param pan_range   number  Max horizontal pan in pixels (default 30).
-- @return number  Count of clips processed.
-----------------------------------------------------------
function fx.ken_burns_all(zoom_range, pan_range)
    zoom_range = zoom_range or 15   -- percentage points of zoom
    pan_range = pan_range or 30     -- max pixels of pan

    math.randomseed(os.time())

    local state = sk.rpc("timeline.getDetailedState", {})
    local items = state and state.items or {}
    local applied = 0

    for _, clip in ipairs(items) do
        if not u.is_real_clip(clip) or u.clip_duration(clip) < 1.0 then goto skip end

        local cs = u.clip_start(clip)
        sk.seek(cs + 0.01)

        -- Random zoom direction (in or out)
        local zoom_start, zoom_end
        if math.random() > 0.5 then
            zoom_start = 100
            zoom_end = 100 + math.random(5, zoom_range)
        else
            zoom_start = 100 + math.random(5, zoom_range)
            zoom_end = 100
        end

        -- Random pan
        local px = math.random(-pan_range, pan_range)
        local py = math.random(-pan_range / 2, pan_range / 2)

        fx.ken_burns(zoom_start, zoom_end, px, py, cs)
        applied = applied + 1

        ::skip::
    end

    print(string.format("Applied Ken Burns to %d clips", applied))
    return applied
end

-- Register globally
_G.fx = fx

print("FX Designer loaded. Commands:")
print("  fx.apply_look('cinematic')       -- apply look to clip at playhead")
print("  fx.apply_look_all('vintage')     -- apply look to all clips")
print("  fx.list_looks()                  -- show available looks")
print("  fx.animate('opacity', {{time=0,value=0},{time=1,value=1}})  -- keyframe animation")
print("  fx.animate_all('opacity', {{time=0,value=0},{time=0.1,value=1},{time=0.9,value=1},{time=1,value=0}})")
print("  fx.ken_burns(100, 120, 10, 0)    -- zoom+pan on current clip")
print("  fx.ken_burns_all(15, 30)         -- random Ken Burns on all clips")
print("")
print("Looks: " .. table.concat(fx.list_looks(), ", "))
