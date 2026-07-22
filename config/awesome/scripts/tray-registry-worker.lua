#!/usr/bin/env lua
-- Run tray discovery outside Awesome so reload stays responsive.

local cache_path = arg[1]
local mode = arg[2] or "full"
local home = os.getenv("HOME") or ""

if not cache_path or cache_path == "" then
    io.stderr:write("usage: tray-registry-worker.lua CACHE_PATH [fast|full]\n")
    os.exit(2)
end

package.path = home .. "/.config/awesome/?.lua;" .. package.path

package.loaded["gears"] = {
    timer = {
        start_new = function(_, callback)
            if callback then
                callback()
            end
        end,
    },
}

package.loaded["menubar.utils"] = {
    lookup_icon = function()
        return nil
    end,
    lookup_icon_uncached = function()
        return nil
    end,
}

package.loaded["awful"] = {
    spawn = {},
}

package.loaded["tray-registry"] = nil

local tray_registry = require("tray-registry")
-- Always use the discovery path that matches live verification (refresh fast ctx).
tray_registry.refresh(true, false)
tray_registry.write_cache_file(cache_path)
