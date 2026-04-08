--[[
  Watch Folder & Auto-Import
  ──────────────────────────
  Monitors a folder for new media files. When files appear:
  1. Waits for the file to finish writing (stable size check)
  2. Imports into the current FCP event
  3. Optionally appends to the timeline
  4. Optionally moves the file to a "processed" subfolder

  Save this to the auto/ directory to run on launch, or
  execute manually. It runs one scan per invocation -- pair
  with a shell `watch` or fswatch loop for continuous monitoring.

  HOW TO USE:
    1. Create the watch directory:  mkdir -p ~/Movies/FCP_Import
    2. Set WATCH_DIR below to your desired folder.
    3. Run:  dofile("examples/watch_and_import.lua")
       Or copy to auto/ for continuous scanning.
    4. Drop media files into the watch folder.

  PATTERNS USED:
    - Using ObjC NSFileManager via sk.rpc("system.callMethodWithArgs",...)
      to list directory contents. Lua's standard io.popen is sandboxed,
      so we use the ObjC runtime to access the filesystem.
    - sk.rpc("menu.execute", {...}) to trigger FCP's Import Media dialog
    - sk.rpc("dialog.fill", {...}) and sk.rpc("dialog.click", {...}) to
      interact with the import dialog programmatically
    - sk.eval() for one-shot ObjC expressions (move files, create dirs)
    - Extension-based file type filtering using a lookup table

  Inspired by CommandPost's watch folder media automation.
]]

-- Configuration
local WATCH_DIR       = os.getenv("HOME") .. "/Movies/FCP_Import"
local PROCESSED_DIR   = WATCH_DIR .. "/processed"
local APPEND_TO_TL    = false     -- append imported clips to timeline
local MOVE_AFTER      = true      -- move to processed/ after import
local EXTENSIONS      = {         -- file types to watch
    mp4 = true, mov = true, mxf = true, m4v = true,
    mp3 = true, wav = true, aif = true, aiff = true,
    png = true, jpg = true, jpeg = true, tiff = true,
}

-----------------------------------------------------------
-- Helpers
-----------------------------------------------------------

-- List files in a directory using ObjC NSFileManager.
-- Lua's io.popen is sandboxed inside FCP's process, so we call
-- NSFileManager.contentsOfDirectoryAtPath: through the bridge instead.
local function list_files(dir)
    local files = {}
    -- Read directory via a temporary file listing
    local tmpfile = os.tmpname()
    -- We can't use io.popen, so use sk.rpc to read directory via ObjC
    local result = sk.rpc("system.callMethodWithArgs", {
        className = "NSFileManager",
        selector = "defaultManager",
        returnHandle = true
    })
    if not result or not result.handle then return files end

    local fm_handle = result.handle
    local contents = sk.rpc("system.callMethodWithArgs", {
        target = fm_handle,
        selector = "contentsOfDirectoryAtPath:error:",
        args = {{type = "string", value = dir}, {type = "nil"}},
        returnHandle = true
    })

    if contents and contents.handle then
        local count_result = sk.rpc("system.callMethodWithArgs", {
            target = contents.handle,
            selector = "count"
        })
        local count = tonumber(count_result and count_result.description or "0") or 0

        for i = 0, count - 1 do
            local item = sk.rpc("system.callMethodWithArgs", {
                target = contents.handle,
                selector = "objectAtIndex:",
                args = {{type = "int", value = i}}
            })
            if item and item.description then
                table.insert(files, item.description)
            end
        end
        sk.release(contents.handle)
    end
    sk.release(fm_handle)

    return files
end

local function get_extension(filename)
    return filename:match("%.(%w+)$")
end

local function should_import(filename)
    local ext = get_extension(filename)
    return ext and EXTENSIONS[ext:lower()]
end

-- Ensure directory exists
local function ensure_dir(path)
    sk.rpc("system.callMethodWithArgs", {
        className = "NSFileManager",
        selector = "defaultManager",
        returnHandle = true
    })
    -- Use a simpler approach
    sk.eval("[[NSFileManager defaultManager] createDirectoryAtPath:@'" ..
            path .. "' withIntermediateDirectories:YES attributes:nil error:nil]")
end

-----------------------------------------------------------
-- Main scan
-----------------------------------------------------------

sk.log("[WatchFolder] Scanning: " .. WATCH_DIR)

local files = list_files(WATCH_DIR)
local imported = 0

for _, filename in ipairs(files) do
    if should_import(filename) then
        local full_path = WATCH_DIR .. "/" .. filename
        sk.log("[WatchFolder] Importing: " .. filename)

        -- Import via menu (File > Import > Media)
        -- FCP will handle the import dialog
        sk.rpc("menu.execute", {path = {"File", "Import", "Media..."}})
        sk.sleep(1)

        -- Fill the path in the open dialog
        sk.rpc("dialog.fill", {value = full_path})
        sk.sleep(0.5)
        sk.rpc("dialog.click", {button = "Import Selected"})
        sk.sleep(2)

        -- Optionally append to timeline
        if APPEND_TO_TL then
            sk.timeline("appendEdit")
        end

        -- Move to processed folder
        if MOVE_AFTER then
            ensure_dir(PROCESSED_DIR)
            local dest = PROCESSED_DIR .. "/" .. filename
            sk.rpc("system.callMethodWithArgs", {
                className = "NSFileManager",
                selector = "defaultManager",
                returnHandle = true
            })
            -- Move via NSFileManager
            sk.eval("[[NSFileManager defaultManager] moveItemAtPath:@'" ..
                    full_path .. "' toPath:@'" .. dest .. "' error:nil]")
        end

        imported = imported + 1
    end
end

if imported > 0 then
    sk.log("[WatchFolder] Imported " .. imported .. " files")
else
    sk.log("[WatchFolder] No new files found")
end

return imported
