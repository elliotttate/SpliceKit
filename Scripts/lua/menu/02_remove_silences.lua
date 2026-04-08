-- Transcribe timeline and remove silences longer than 1 second
sk.toast("Opening transcript...")
sk.rpc("transcript.open", {})
-- Wait for transcription (poll every 1s for up to 120s)
local ready = false
for i = 1, 120 do
    sk.sleep(1)
    local state = sk.rpc("transcript.getState", {})
    if state and state.status == "error" then
        sk.alert("Remove Silences", "Transcription error: " .. (state.errorMessage or "unknown"))
        return
    end
    if state and state.wordCount and state.wordCount > 0 then
        sk.toast("Transcription done: " .. state.wordCount .. " words")
        ready = true
        break
    end
end
if not ready then
    sk.alert("Remove Silences", "Timed out waiting for transcription")
    return
end
sk.rpc("transcript.deleteSilences", {min_duration = 1.0})
sk.alert("Remove Silences", "Done — silences longer than 1s removed")
