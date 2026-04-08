-- Transcribe timeline and remove silences longer than 1 second
sk.log("[RemoveSilences] Opening transcript...")
sk.rpc("transcript.open", {})
-- Wait for transcription (poll every 1s for up to 120s)
local ready = false
for i = 1, 120 do
    sk.sleep(1)
    local state = sk.rpc("transcript.getState", {})
    if state and state.status == "error" then
        sk.log("[RemoveSilences] Transcription error: " .. (state.errorMessage or "unknown"))
        return
    end
    if state and state.wordCount and state.wordCount > 0 then
        sk.log("[RemoveSilences] Transcription done: " .. state.wordCount .. " words")
        ready = true
        break
    end
end
if not ready then
    sk.log("[RemoveSilences] Timed out waiting for transcription")
    return
end
sk.rpc("transcript.deleteSilences", {min_duration = 1.0})
sk.log("[RemoveSilences] Done — silences > 1s removed")
