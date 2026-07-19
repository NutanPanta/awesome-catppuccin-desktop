-- Tray menu debug logging (file + journalctl --user -t awesome-tray).

local M = {}

local log_dir = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/awesome"
local log_file = log_dir .. "/tray-menu.log"
local dir_ready = false

local function ensure_dir()
    if dir_ready then
        return
    end
    os.execute(string.format("mkdir -p %q 2>/dev/null", log_dir))
    dir_ready = true
end

function M.info(msg)
    ensure_dir()
    local line = string.format("[%s] %s\n", os.date("%F %T"), msg)
    local handle = io.open(log_file, "a")
    if handle then
        handle:write(line)
        handle:close()
    end
end

return M
