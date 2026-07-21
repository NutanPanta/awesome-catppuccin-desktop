-- HyDE-style center pill: pinned launchers + real app icons
local awful = require("awful")
local gears = require("gears")
local wibox = require("wibox")
local beautiful = require("beautiful")
local menubar_utils = require("menubar.utils")
local tray_menu = require("tray-menu")
local tray_registry = require("tray-registry")
local awesome_log = require("awesome-log")
local c = require("theme.catppuccin")

local M = {}

local systray_widget
local pill_refreshers = {}
local last_tray_icons = {}
local live_icon_cache = {}

local ICON = 22

local function shell_line(cmd)
    local handle = io.popen(cmd .. " 2>/dev/null")
    if not handle then
        return ""
    end
    local out = handle:read("*a") or ""
    handle:close()
    return out:gsub("^%s+", ""):gsub("%s+$", "")
end

local function parse_bus_string(output)
    if not output or output == "" then
        return nil
    end
    return output:match('^%S+%s+"([^"]+)"') or output:match("^%S+%s+(%S+)")
end

local function resolve_tray_icon_file(theme_path, icon_name)
    if not theme_path or theme_path == "" or not icon_name or icon_name == "" then
        return nil
    end

    for _, size in ipairs({ ICON, 24, 32, 16, 48 }) do
        local path = string.format(
            "%s/hicolor/%dx%d/apps/%s.png",
            theme_path,
            size,
            size,
            icon_name
        )
        local handle = io.open(path, "r")
        if handle then
            handle:close()
            return path
        end
    end
end

local function live_tray_icon(item, force)
    if not item then
        return nil
    end

    if not item.service or not item.sni_path then
        return item.icon_path
    end

    local cache_key = item.service .. item.sni_path
    local icon_name = parse_bus_string(shell_line(string.format(
        "busctl --user get-property %q %q org.kde.StatusNotifierItem IconName",
        item.service,
        item.sni_path
    )))
    local theme_path = parse_bus_string(shell_line(string.format(
        "busctl --user get-property %q %q org.kde.StatusNotifierItem IconThemePath",
        item.service,
        item.sni_path
    )))
    local icon_key = (icon_name or "") .. "|" .. (theme_path or "")
    local cached = live_icon_cache[cache_key]

    if not force and cached and cached.icon_key == icon_key then
        item.icon_name = cached.icon_name
        item.icon_path = cached.icon_path
        return cached.icon_path
    end

    local path = resolve_tray_icon_file(theme_path, icon_name)
    if path then
        item.icon_name = icon_name
        item.icon_path = path
        live_icon_cache[cache_key] = {
            icon_key = icon_key,
            icon_name = icon_name,
            icon_path = path,
        }
        return path
    end

    return item.icon_path
end

local function poll_tray_icons()
    local items = tray_registry.cached_items()
    if #items == 0 then
        return false
    end

    local changed = tray_registry.refresh_icons()

    for _, item in ipairs(items) do
        local path = live_tray_icon(item, true)
        if path and last_tray_icons[item.id] ~= path then
            last_tray_icons[item.id] = path
            changed = true
        end
    end

    if changed then
        for _, refresh in pairs(pill_refreshers) do
            refresh()
        end
    end

    return changed
end

local function stop_pill_timers()
    if M._icon_poll_timer then
        M._icon_poll_timer:stop()
    end
    if M._tray_timer then
        M._tray_timer:stop()
    end
end

local function pill_guard(step, fn, max_failures)
    return awesome_log.guard("taskbar-pill/" .. step, fn, {
        max_failures = max_failures or 2,
        title = "Taskbar pill disabled",
        message = "The center app bar hit repeated errors and stopped updating. "
            .. "Polybar, tags, and windows still work. Reload with Super+Shift+r.",
        on_trip = stop_pill_timers,
    })
end

local safe_poll_tray_icons = pill_guard("poll", poll_tray_icons, 3)

local function ensure_icon_poll_timer()
    if M._icon_poll_timer then
        return
    end

    M._icon_poll_timer = gears.timer {
        timeout = 4,
        autostart = true,
        callback = function()
            safe_poll_tray_icons()
        end,
    }
end

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
    hubstaff = "󰄉",
    ["netsoft-com.netsoft.hubstaff"] = "󰄉",
}

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

local function prettify_class(class)
    if not class or class == "" then
        return nil
    end
    local name = class:gsub("_", " "):gsub("-", " ")
    return name:sub(1, 1):upper() .. name:sub(2)
end

local function clean_label(text)
    if type(text) ~= "string" then
        return nil
    end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    text = text:gsub('^"(.*)"$', "%1")
    if text == "" or not text:match("%S") then
        return nil
    end
    if #text > 80 then
        text = text:sub(1, 77) .. "..."
    end
    return text
end

local function first_label(...)
    for i = 1, select("#", ...) do
        local label = clean_label(select(i, ...))
        if label then
            return label
        end
    end
end

local function label_for_client(cl)
    if not cl then
        return "Window"
    end
    return first_label(cl.name, prettify_class(cl.class)) or "Window"
end

local function label_for_tray(item, cl, entry)
    return first_label(
        cl and cl.name,
        entry and entry.name,
        item and item.title,
        item and item.id_prop,
        item and item.id and item.id:gsub("-", " "),
        item and item.wm_class and prettify_class(item.wm_class)
    ) or "App"
end

local function tooltip_text(text)
    return clean_label(text) or "App"
end

local function is_tray_app(cl)
    return tray_registry.match_client(cl, false) ~= nil
end

local function is_obvious_tray_embed(cl)
    if not cl.valid then
        return false
    end

    local cls = (cl.class or ""):lower()
    if cls:find("status_icon", 1, true) or cls == "snixembed" then
        return true
    end

    local w, h = cl.width, cl.height
    if w and h and w > 0 and h > 0 and w <= 64 and h <= 64 then
        return true
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

local function include_client(cl, fast)
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
    if fast then
        if is_obvious_tray_embed(cl) then
            return false
        end
    elseif is_tray_app(cl) then
        return false
    end
    return true
end

local function ensure_systray(s)
    if not systray_widget then
        beautiful.bg_systray = "#00000000"
        systray_widget = wibox.widget.systray()
        systray_widget:set_horizontal(true)
        systray_widget:set_base_size(ICON)

        if not M._systray_connected then
            awesome.connect_signal("systray::update", function()
                if not M._systray_refresh_pending then
                    M._systray_refresh_pending = true
                    gears.timer.start_new(0.3, function()
                        M._systray_refresh_pending = false
                        safe_poll_tray_icons()
                        for _, refresh in pairs(pill_refreshers) do
                            refresh()
                        end
                    end)
                end
            end)
            M._systray_connected = true
        end
    end

    systray_widget:set_screen(s)
    return systray_widget
end

function M.prepare_tray_menu(item, x, y)
    if not M._tray_host or not item then
        return
    end

    local index = tray_registry.systray_index(item)

    if not M._tray_restore_geo then
        M._tray_restore_geo = {
            x = M._tray_host.x,
            y = M._tray_host.y,
            width = M._tray_host.width,
            height = M._tray_host.height,
            ontop = M._tray_host.ontop,
        }
    end

    M._tray_host.ontop = true
    M._tray_host:geometry {
        x = math.floor(x - index * (ICON + 4) - ICON / 2),
        y = math.floor(y - ITEM / 2),
        width = math.max((ICON + 4) * math.max(awesome.systray(), 1), 200),
        height = ITEM,
    }

    if M._tray_host.raise then
        M._tray_host:raise()
    end
end

function M.restore_tray_host()
    if M._tray_host and M._tray_restore_geo then
        M._tray_host.ontop = M._tray_restore_geo.ontop
        M._tray_host:geometry {
            x = M._tray_restore_geo.x,
            y = M._tray_restore_geo.y,
            width = M._tray_restore_geo.width,
            height = M._tray_restore_geo.height,
        }
        M._tray_restore_geo = nil
    end
end

local function ensure_hidden_tray_host(s)
    if M._tray_host or s ~= screen.primary then
        return
    end

    local tray = ensure_systray(s)
    M._tray_host = wibox {
        screen = s,
        name = "awesome-tray-host",
        visible = true,
        opacity = 0,
        type = "utility",
        ontop = false,
        border_width = 0,
        bg = "#00000000",
        width = 480,
        height = ITEM,
        widget = tray,
    }
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

local function build_icon_widget(theme_icon, nerd_icon, cl)
    if theme_icon then
        local surface = gears.surface.load(theme_icon, false)
        return wibox.widget {
            image = surface or theme_icon,
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

function M.create(s)
    local open_apps = wibox.widget {
        spacing = ITEM_GAP,
        layout = wibox.layout.fixed.horizontal,
    }

    local tracked = {}
    local highlight_widgets = {}
    local place
    local layout_pill
    local refresh_debounce
    local safe_layout_pill
    local safe_refresh_apps

    local function update_focus_highlights()
        for _, entry in ipairs(highlight_widgets) do
            if entry.widget and entry.get_color then
                entry.widget.bg = entry.get_color()
            end
        end
    end

    local function schedule_refresh()
        if refresh_debounce then
            refresh_debounce:again()
            return
        end
        refresh_debounce = gears.timer {
            timeout = 0.08,
            autostart = true,
            single_shot = true,
            callback = function()
                refresh_debounce = nil
                if safe_refresh_apps then
                    safe_refresh_apps()
                end
                if safe_layout_pill then
                    safe_layout_pill()
                end
            end,
        }
    end

    local function schedule_layout()
        if not layout_pill then
            return
        end
        gears.timer.delayed_call(function()
            local fn = safe_layout_pill or layout_pill
            if fn then
                fn()
            end
        end)
    end

    pill_refreshers[s.index] = schedule_refresh
    ensure_hidden_tray_host(s)

    local function remember_tray_client(cl, item)
        local entry = tracked[item.id] or {}
        entry.name = label_for_tray(item, cl, entry)
        entry.theme_icon = item.icon_path or lookup_app_icon(cl) or entry.theme_icon
        entry.nerd_icon = icon_for(cl)
        entry.item = item
        tracked[item.id] = entry
    end

    local function make_client_item(cl)
        local icon = build_icon_widget(lookup_app_icon(cl), icon_for(cl), cl)
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
                local tray_item = tray_registry.match_client(cl)
                if tray_item then
                    local coords = mouse.coords()
                    tray_menu.show(tray_item, cl, coords.x, coords.y)
                    return
                end
                awful.menu.client_list { theme = { width = 260 } }
            end)
        ))

        highlight_widgets[#highlight_widgets + 1] = {
            widget = bg,
            get_color = function()
                return (cl == client.focus) and c.mauve or c.surface1
            end,
        }

        awful.tooltip {
            objects = { bg },
            timer_delay = 0.2,
            text = tooltip_text(label_for_client(cl)),
        }

        return bg
    end

    local function make_tray_item(item, cl)
        local entry = tracked[item.id] or {
            theme_icon = item.icon_path,
            nerd_icon = (cl and icon_for(cl))
                or fallback_icons[(item.id_prop or item.id or ""):lower():match("^(%w+)")]
                or "󰖟",
            item = item,
        }

        entry.name = label_for_tray(item, cl, entry)
        entry.theme_icon = item.icon_path or entry.theme_icon
        entry.item = item
        tracked[item.id] = entry

        local has_window = cl and cl.valid
        local icon = build_icon_widget(
            entry.theme_icon,
            entry.nerd_icon,
            entry.theme_icon and nil or cl
        )
        local bg_color = has_window and ((cl == client.focus) and c.mauve or c.surface1) or c.mantle

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
                    awful.spawn(item.launch)
                end
            end),
            awful.button({}, 3, function()
                local coords = mouse.coords()
                tray_menu.show(entry.item or item, cl, coords.x, coords.y)
            end)
        ))

        highlight_widgets[#highlight_widgets + 1] = {
            widget = bg,
            get_color = function()
                if not has_window then
                    return c.mantle
                end
                return (cl == client.focus) and c.mauve or c.surface1
            end,
        }

        awful.tooltip {
            objects = { bg },
            timer_delay = 0.2,
            text = tooltip_text(entry.name),
        }

        return bg
    end

    local function refresh_clients_only()
        local items = {}
        highlight_widgets = {}

        for _, cl in ipairs(client.get()) do
            if include_client(cl, true) then
                items[#items + 1] = make_client_item(cl)
            end
        end

        open_apps:set_children(items)
        update_focus_highlights()
    end

    local function refresh_apps()
        local items = {}
        local tray_with_window = {}
        highlight_widgets = {}

        local tray_items = tray_registry.cached_items()
        if #tray_items == 0 then
            if not tray_registry.is_refreshing() then
                tray_registry.refresh_async(function()
                    schedule_refresh()
                end)
            end
        else
            tray_items = tray_registry.list()
        end
        tray_registry.set_match_items(tray_items)

        local clients = client.get()
        for _, cl in ipairs(clients) do
            if include_client(cl) then
                items[#items + 1] = make_client_item(cl)
            end
        end

        for _, cl in ipairs(clients) do
            local item = tray_registry.match_client(cl)
            if item then
                remember_tray_client(cl, item)
                tray_with_window[item.id] = cl
                local widget = make_tray_item(item, cl)
                if widget then
                    items[#items + 1] = widget
                end
            end
        end

        for _, item in ipairs(tray_items) do
            if not tray_with_window[item.id] and tray_registry.is_running(item) then
                tracked[item.id] = tracked[item.id] or {
                    nerd_icon = fallback_icons[item.id]
                        or fallback_icons[(item.id_prop or ""):lower():match("^(%w+)")]
                        or "󰖟",
                }
                tracked[item.id].name = label_for_tray(item, nil, tracked[item.id])
                tracked[item.id].theme_icon = item.icon_path
                tracked[item.id].item = item
                if item.icon_path then
                    last_tray_icons[item.id] = item.icon_path
                end
                local widget = make_tray_item(item, nil)
                if widget then
                    items[#items + 1] = widget
                end
            elseif not tray_registry.is_running(item) then
                tracked[item.id] = nil
            end
        end

        tray_registry.set_match_items(nil)
        open_apps:set_children(items)
        update_focus_highlights()
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

    layout_pill = function()
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

        if M._tray_host and s == screen.primary then
            M._tray_host:geometry {
                x = geo.x - 600,
                y = y,
                width = 480,
                height = ITEM,
            }
        end
    end

    safe_refresh_apps = pill_guard("refresh", refresh_apps)
    safe_layout_pill = pill_guard("layout", layout_pill)

    local startup_pending = true

    place = pill_guard("place", function()
        if startup_pending then
            startup_pending = false
            refresh_clients_only()
            safe_layout_pill()
            gears.timer.start_new(0.15, function()
                if not tray_registry.is_refreshing() then
                    tray_registry.refresh_async(function()
                        if safe_refresh_apps then
                            safe_refresh_apps()
                        end
                        if safe_layout_pill then
                            safe_layout_pill()
                        end
                    end)
                end
            end)
            return
        end

        safe_refresh_apps()
        safe_layout_pill()
    end)

    place()

    ensure_icon_poll_timer()

    if not M._tray_timer then
        M._tray_timer = gears.timer {
            timeout = 30,
            autostart = true,
            callback = function()
                if safe_poll_tray_icons() then
                    for _, refresh in pairs(pill_refreshers) do
                        refresh()
                    end
                end
            end,
        }
    end

    local function on_client_list_change()
        schedule_refresh()
    end

    s:connect_signal("property::workarea", schedule_layout)
    s:connect_signal("property::geometry", schedule_layout)
    client.connect_signal("manage", on_client_list_change)
    client.connect_signal("unmanage", on_client_list_change)
    client.connect_signal("focus", update_focus_highlights)
    client.connect_signal("property::minimized", on_client_list_change)
    client.connect_signal("property::class", on_client_list_change)
    client.connect_signal("property::icon", on_client_list_change)
end

return M
