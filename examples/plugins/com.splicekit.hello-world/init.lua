-- Hello World Plugin for SpliceKit
-- Demonstrates: method registration, persistent config, RPC passthrough

-- greet: simple method that returns a greeting
sk.register("greet", function(params)
    local name = params.name or "world"
    return { message = "Hello, " .. name .. "!" }
end, {
    description = "Returns a greeting message",
    readOnly = true,
    params = { name = { type = "string", required = false } }
})

-- counter: demonstrates persistent state via sk.get_config/set_config
sk.register("counter", function(params)
    local count = sk.get_config("counter_value") or 0
    count = count + 1
    sk.set_config("counter_value", count)
    return { count = count }
end, {
    description = "Increment and return a persistent counter"
})

-- timeline_summary: demonstrates calling other SpliceKit methods from a plugin
sk.register("timeline_summary", function(params)
    local clips = sk.rpc("timeline.getDetailedState", {})
    if not clips then
        return { error = "No timeline data available" }
    end
    return {
        summary = "Timeline data retrieved",
        data = clips
    }
end, {
    description = "Get a quick summary of the current timeline",
    readOnly = true
})

sk.log("[Hello World] Plugin loaded!")
