-- Shared Awesome error logging and fail-soft guards.

local naughty = require("naughty")

local M = {}

local log_dir = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/awesome"
local error_file = log_dir .. "/errors.log"
local dir_ready = false
local notify_at = {}

local function ensure_dir()
    if dir_ready then
        return
    end
    os.execute(string.format("mkdir -p %q 2>/dev/null", log_dir))
    dir_ready = true
end

function M.error(context, err)
    ensure_dir()
    local line = string.format("[%s] %s: %s\n", os.date("%F %T"), context, tostring(err))
    local handle = io.open(error_file, "a")
    if handle then
        handle:write(line)
        handle:close()
    end
end

function M.notify(title, text, opts)
    opts = opts or {}
    local key = opts.id or title
    local cooldown = opts.cooldown or 60
    local now = os.time()

    if notify_at[key] and now - notify_at[key] < cooldown then
        return
    end
    notify_at[key] = now

    naughty.notify {
        preset = naughty.config.presets.critical,
        title = title,
        text = text,
    }
end

function M.guard(context, fn, opts)
    opts = opts or {}
    local failures = 0
    local max_failures = opts.max_failures or 3
    local tripped = false

    return function(...)
        if tripped then
            return
        end

        local packed = table.pack(pcall(fn, ...))
        if packed[1] then
            failures = 0
            return table.unpack(packed, 2, packed.n)
        end

        local err = packed[2]
        failures = failures + 1
        M.error(context, err)

        if failures >= max_failures then
            tripped = true
            M.notify(
                opts.title or "Feature disabled",
                opts.message or tostring(err),
                { id = context, cooldown = opts.cooldown or 120 }
            )
            if opts.on_trip then
                opts.on_trip(err)
            end
        end
    end
end

return M
