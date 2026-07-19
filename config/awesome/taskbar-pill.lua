-- HyDE-style center pill: pinned launchers + real app icons
local awful = require("awful")
local gears = require("gears")
local wibox = require("wibox")
local menubar_utils = require("menubar.utils")
local c = require("theme.catppuccin")

local M = {}

local ICON = 22
local ITEM = 40
local LAUNCHER_ICON = 18
local ITEM_GAP = 8
local PILL_PAD_X = 22
local PILL_MIN_W = 420
local PILL_BOTTOM_GAP = 8
local PILL_H = ITEM + 6
local RADIUS = 14
local BAR_HEIGHT = 60

local fallback_icons = {
    ["google-chrome"] = "󰊯",
    ["google-chrome-stable"] = "󰊯",
    chromium = "󰊯",
    firefox = "󰈹",
    kitty = "󰆍",
    alacritty = "󰆍",
    wezterm = "󰆍",
    thunar = "󰉋",
    code = "󰨞",
    ["code-oss"] = "󰨞",
    cursor = "󰨞",
    nvim = "󰈮",
    spotify = "󰓇",
    slack = "󰒱",
    discord = "󰙯",
    telegram = "󰚇",
    ["netsoft-com.netsoft.hubstaff"] = "󰄉",
}

-- Map WM class names to .desktop Icon= names when they differ.
local icon_aliases = {
    pgadmin4 = "pgadmin4",
    pgadmin = "pgadmin4",
    ["pgadmin-4"] = "pgadmin4",
    viber = "viber",
    viberpc = "viber",
}

local function client_icon_candidates(cl)
    local candidates = {}
    local seen = {}

    local function add(name)
        if not name or name == "" then
            return
        end
        name = name:lower()
        if seen[name] then
            return
        end
        seen[name] = true
        candidates[#candidates + 1] = name
    end

    local cls = (cl.class or ""):lower()
    add(icon_aliases[cls])
    add(cls)
    add(cl.instance and cl.instance:lower())
    if cl.startup_id then
        add(cl.startup_id:match("^([^_]+)"))
    end
    if cl.name then
        add(cl.name:lower():gsub("%s+", "-"))
    end

    return candidates
end

local function lookup_app_icon(cl)
    for _, name in ipairs(client_icon_candidates(cl)) do
        local path = menubar_utils.lookup_icon_uncached(name)
        if path and path ~= false then
            return path
        end
    end
end

local function client_has_wm_icon(cl)
    return cl.icon_sizes and #cl.icon_sizes > 0
end

local function icon_for(cl)
    return fallback_icons[(cl.class or ""):lower()] or "󰖟"
end

-- Tray-style apps that keep running after their window is closed.
local persistent_apps = {
    slack = {
        launch = "slack",
        quit = "pkill -x slack 2>/dev/null; pkill -f '/usr/bin/slack' 2>/dev/null",
        pgrep = { "slack" },
    },
    viber = {
        launch = "viber",
        quit = "pkill -x Viber 2>/dev/null; pkill -f '/usr/bin/viber' 2>/dev/null",
        pgrep = { "Viber", "viber" },
    },
    viberpc = {
        launch = "viber",
        quit = "pkill -x Viber 2>/dev/null; pkill -f '/usr/bin/viber' 2>/dev/null",
        pgrep = { "Viber", "viber" },
    },
    telegramdesktop = {
        launch = "Telegram",
        quit = "Telegram -quit",
        pgrep = { "Telegram" },
    },
    discord = {
        launch = "discord",
        quit = "pkill -x Discord 2>/dev/null; pkill -f '/usr/bin/discord' 2>/dev/null",
        pgrep = { "Discord", "discord" },
    },
    spotify = {
        launch = "spotify",
        quit = "pkill -x spotify 2>/dev/null",
        pgrep = { "spotify" },
    },
}

local function persistent_key(cl)
    return persistent_apps[(cl.class or ""):lower()] and (cl.class or ""):lower() or nil
end

local function process_running(key)
    local conf = persistent_apps[key]
    if not conf then
        return false
    end

    for _, name in ipairs(conf.pgrep or {}) do
        local handle = io.popen("pgrep -x " .. name .. " 2>/dev/null | head -1")
        if handle then
            local pid = handle:read("*l")
            handle:close()
            if pid and pid ~= "" then
                return true
            end
        end
    end

    return false
end

local skip = {
    plank = true,
    polybar = true,
    awesome = true,
    picom = true,
    xfdesktop = true,
    pavucontrol = true,
}

local function include_client(cl)
    if not cl.valid or not cl.class or cl.class == "" then
        return false
    end
    if cl.type == "desktop" or cl.type == "dock" then
        return false
    end
    if skip[cl.class:lower()] then
        return false
    end
    if cl.name and cl.name:lower():find("polybar", 1, true) then
        return false
    end
    return true
end

local function launcher(icon, cmd, tip)
    local w = wibox.widget {
        {
            markup = string.format(
                '<span font="JetBrainsMono Nerd Font %d" foreground="%s">%s</span>',
                LAUNCHER_ICON, c.text, icon
            ),
            align = "center",
            valign = "center",
            widget = wibox.widget.textbox,
        },
        forced_width = ITEM,
        forced_height = ITEM,
        widget = wibox.container.place,
    }
    w:buttons(gears.table.join(
        awful.button({}, 1, function() awful.spawn(cmd) end)
    ))
    awful.tooltip { objects = { w }, text = tip, timer_delay = 0.2 }
    return w
end

local function separator()
    return wibox.widget {
        {
            forced_width = 1,
            forced_height = ICON - 4,
            bg = c.overlay0,
            widget = wibox.container.background,
        },
        margins = { left = 12, right = 12, top = 8, bottom = 8 },
        widget = wibox.container.margin,
    }
end

local function pill_shape(cr, w, h)
    gears.shape.partially_rounded_rect(cr, w, h, true, true, false, false, RADIUS)
end

function M.create(s)
    local open_apps = wibox.widget {
        spacing = ITEM_GAP,
        layout = wibox.layout.fixed.horizontal,
    }

    local tracked = {}
    local place

    local function schedule_refresh()
        if place then
            gears.timer.delayed_call(place)
        end
    end

    local function remember_client(cl)
        local key = persistent_key(cl)
        if not key then
            return
        end

        local entry = tracked[key] or {
            pids = {},
        }

        entry.name = cl.name or cl.class
        entry.theme_icon = lookup_app_icon(cl) or entry.theme_icon
        entry.nerd_icon = icon_for(cl)
        if cl.pid then
            entry.pids[cl.pid] = true
        end

        tracked[key] = entry
    end

    local function drop_tracked(key)
        tracked[key] = nil
    end

    local function build_icon(theme_icon, nerd_icon, cl)
        if theme_icon then
            return wibox.widget {
                image = theme_icon,
                forced_width = ICON,
                forced_height = ICON,
                resize = true,
                widget = wibox.widget.imagebox,
            }
        end

        if cl and client_has_wm_icon(cl) then
            local widget = wibox.widget {
                forced_width = ICON,
                forced_height = ICON,
                widget = awful.widget.clienticon,
            }
            widget.client = cl
            return widget
        end

        return wibox.widget {
            {
                markup = string.format(
                    '<span font="JetBrainsMono Nerd Font %d" foreground="%s">%s</span>',
                    ICON, c.text, nerd_icon or "󰖟"
                ),
                align = "center",
                valign = "center",
                widget = wibox.widget.textbox,
            },
            forced_width = ICON,
            forced_height = ICON,
            widget = wibox.container.place,
        }
    end

    local function show_persistent_menu(key, cl)
        local conf = persistent_apps[key]
        local entry = tracked[key]
        if not conf or not entry then
            return
        end

        local items = {}

        if not cl or not cl.valid then
            items[#items + 1] = {
                "Open",
                function()
                    awful.spawn(conf.launch)
                    schedule_refresh()
                end,
            }
        end

        items[#items + 1] = {
            "Quit completely",
            function()
                awful.spawn.with_shell(conf.quit)
                drop_tracked(key)
                schedule_refresh()
            end,
        }

        awful.menu({
            theme = { width = 220 },
            items = items,
        }):show()
    end

    local function make_persistent_item(key, cl)
        local conf = persistent_apps[key]
        local entry = tracked[key]
        if not conf or not entry then
            return nil
        end

        local has_window = cl and cl.valid
        local icon = build_icon(entry.theme_icon, entry.nerd_icon, cl)
        local bg_color = c.mantle

        if has_window then
            bg_color = (cl == client.focus) and c.mauve or c.surface1
        end

        local bg = wibox.widget {
            {
                icon,
                left = 8,
                right = 8,
                top = 5,
                bottom = 5,
                widget = wibox.container.margin,
            },
            forced_width = ITEM,
            forced_height = ITEM,
            bg = bg_color,
            shape = function(cr, w, h)
                gears.shape.rounded_rect(cr, w, h, 8)
            end,
            widget = wibox.container.background,
        }

        bg:buttons(gears.table.join(
            awful.button({}, 1, function()
                if has_window then
                    if cl == client.focus and not cl.minimized then
                        cl.minimized = true
                    else
                        cl.minimized = false
                        awful.client.jumpto(cl)
                    end
                else
                    awful.spawn(conf.launch)
                end
            end),
            awful.button({}, 3, function()
                show_persistent_menu(key, cl)
            end)
        ))

        awful.tooltip {
            objects = { bg },
            timer_delay = 0.2,
            text = entry.name or (cl and (cl.name or cl.class)) or key,
        }

        return bg
    end

    local function make_client_item(cl)
        local icon
        local theme_icon = lookup_app_icon(cl)

        if theme_icon then
            icon = wibox.widget {
                image = theme_icon,
                forced_width = ICON,
                forced_height = ICON,
                resize = true,
                widget = wibox.widget.imagebox,
            }
        elseif client_has_wm_icon(cl) then
            icon = wibox.widget {
                forced_width = ICON,
                forced_height = ICON,
                widget = awful.widget.clienticon,
            }
            icon.client = cl
        else
            icon = wibox.widget {
                {
                    markup = string.format(
                        '<span font="JetBrainsMono Nerd Font %d" foreground="%s">%s</span>',
                        ICON, c.text, icon_for(cl)
                    ),
                    align = "center",
                    valign = "center",
                    widget = wibox.widget.textbox,
                },
                forced_width = ICON,
                forced_height = ICON,
                widget = wibox.container.place,
            }
        end

        local bg = wibox.widget {
            {
                icon,
                left = 8,
                right = 8,
                top = 5,
                bottom = 5,
                widget = wibox.container.margin,
            },
            forced_width = ITEM,
            forced_height = ITEM,
            bg = (cl == client.focus) and c.mauve or c.surface1,
            shape = function(cr, w, h)
                gears.shape.rounded_rect(cr, w, h, 8)
            end,
            widget = wibox.container.background,
        }

        bg:buttons(gears.table.join(
            awful.button({}, 1, function()
                if not cl.valid then
                    return
                end
                if cl == client.focus and not cl.minimized then
                    cl.minimized = true
                else
                    cl.minimized = false
                    awful.client.jumpto(cl)
                end
            end),
            awful.button({}, 3, function()
                awful.menu.client_list { theme = { width = 260 } }
            end)
        ))

        awful.tooltip {
            objects = { bg },
            timer_delay = 0.2,
            text = cl.name or cl.class,
        }

        return bg
    end

    local function refresh_apps()
        local items = {}
        local persistent_with_window = {}

        for _, cl in ipairs(client.get()) do
            if include_client(cl) then
                local key = persistent_key(cl)
                if key then
                    remember_client(cl)
                    persistent_with_window[key] = cl
                    local widget = make_persistent_item(key, cl)
                    if widget then
                        items[#items + 1] = widget
                    end
                else
                    items[#items + 1] = make_client_item(cl)
                end
            end
        end

        for key in pairs(tracked) do
            if not persistent_with_window[key] then
                if process_running(key) then
                    local widget = make_persistent_item(key, nil)
                    if widget then
                        items[#items + 1] = widget
                    end
                else
                    drop_tracked(key)
                end
            end
        end

        open_apps:set_children(items)
    end

    local launchers = wibox.widget {
        spacing = ITEM_GAP,
        layout = wibox.layout.fixed.horizontal,
        launcher("󰀻", "rofi -modi drun,run -show drun", "Apps"),
        launcher("󰉋", "thunar", "Files"),
        launcher("󰆍", os.getenv("TERMINAL") or "kitty", "Terminal"),
    }

    local pill_row = wibox.widget {
        layout = wibox.layout.fixed.horizontal,
        launchers,
        separator(),
        open_apps,
    }

    local pill = wibox.widget {
        {
            pill_row,
            left = PILL_PAD_X,
            right = PILL_PAD_X,
            top = 3,
            bottom = 3,
            widget = wibox.container.margin,
        },
        bg = c.surface0,
        shape = pill_shape,
        widget = wibox.container.background,
    }

    s.pill_bar = awful.popup {
        screen = s,
        widget = pill,
        ontop = true,
        visible = true,
        type = "dock",
        border_width = 0,
    }

    s.pill_bar:struts { left = 0, right = 0, top = 0, bottom = 0 }

    place = function()
        refresh_apps()
        local geo = s.geometry
        local w = select(1, pill:fit(s, geo.width, geo.height)) or 220
        w = math.max(PILL_MIN_W, math.ceil(w))
        local h = select(2, pill:fit(s, geo.width, geo.height)) or PILL_H
        h = math.max(PILL_H, math.ceil(h))
        local bar_h = BAR_HEIGHT
        local y = geo.y + bar_h - PILL_BOTTOM_GAP - h

        s.pill_bar:geometry {
            x = geo.x + math.floor((geo.width - w) / 2),
            y = y,
            width = w,
            height = h,
        }
    end

    place()

    gears.timer {
        timeout = 5,
        autostart = true,
        callback = function()
            if next(tracked) then
                place()
            end
        end,
    }

    local function on_client_change()
        schedule_refresh()
    end

    s:connect_signal("property::workarea", place)
    s:connect_signal("property::geometry", place)
    client.connect_signal("manage", on_client_change)
    client.connect_signal("unmanage", on_client_change)
    client.connect_signal("focus", on_client_change)
    client.connect_signal("property::minimized", on_client_change)
    client.connect_signal("property::hidden", on_client_change)
    client.connect_signal("property::class", on_client_change)
    client.connect_signal("property::icon", on_client_change)
    client.connect_signal("tagged", on_client_change)
    client.connect_signal("untagged", on_client_change)
end

return M
