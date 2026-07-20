-- Tray menus: DBus layout popup, native SNI/embed click, or open/quit fallback.

local awful = require("awful")
local gears = require("gears")
local gstring = require("gears.string")
local wibox = require("wibox")
local c = require("theme.catppuccin")
local tray_log = require("tray-log")
local tray_registry = require("tray-registry")

local M = {}

local EMBED_CLICK = os.getenv("HOME") .. "/.config/awesome/scripts/tray-embed-click.sh"

local MENU_W = 280
local ROW_H = 28
local BAR_CLEARANCE = 64
local TOP_BAR_H = 60

local awful_menu_theme = {
    width = MENU_W,
    height = 22,
    font = "JetBrainsMono Nerd Font 10",
    bg_normal = c.base,
    fg_normal = c.text,
    bg_focus = c.surface0,
    fg_focus = c.text,
    border_width = 1,
    border_color = c.surface1,
}

local active_popup
local active_overlay
local active_awful_menu
local menu_keygrabber
local embed_busy = false
local menu_generation = 0

local sni_menu_methods = {
    "org.kde.StatusNotifierItem.ContextMenu",
    "org.freedesktop.StatusNotifierItem.ContextMenu",
    "org.kde.StatusNotifierItem.SecondaryActivate",
}

local function dbus_env_prefix()
    local runtime = os.getenv("XDG_RUNTIME_DIR") or ""
    local bus = os.getenv("DBUS_SESSION_BUS_ADDRESS")
    if not bus or bus == "" then
        bus = "unix:path=" .. runtime .. "/bus"
    end
    return string.format(
        "env XDG_RUNTIME_DIR=%q DBUS_SESSION_BUS_ADDRESS=%q DISPLAY=%q ",
        runtime,
        bus,
        os.getenv("DISPLAY") or ":0"
    )
end

local function shell_output(cmd)
    local handle = io.popen(cmd .. " 2>/dev/null")
    if not handle then
        return ""
    end
    local out = handle:read("*a") or ""
    handle:close()
    return out
end

local function shell_ok(cmd, label, timeout)
    timeout = timeout or 2
    local handle = io.popen("timeout " .. timeout .. " " .. cmd .. " 2>&1; echo __EXIT:$?")
    if not handle then
        tray_log.info((label or "shell") .. ": popen failed")
        return false
    end
    local output = {}
    local code
    for line in handle:lines() do
        local exit_code = line:match("^__EXIT:(%d+)$")
        if exit_code then
            code = exit_code
        else
            output[#output + 1] = line
        end
    end
    handle:close()
    local ok = tonumber(code) == 0
    if label then
        local detail = table.concat(output, " | ")
        if detail ~= "" then
            tray_log.info(string.format("%s: exit=%s %s", label, code or "?", detail))
        else
            tray_log.info(string.format("%s: exit=%s", label, code or "?"))
        end
    end
    return ok
end

local function gdbus_call(service, path, method, ...)
    local args = table.concat({ ... }, " ")
    return shell_output(string.format(
        "%sgdbus call --session -d %q -o %q -m %s -- %s",
        dbus_env_prefix(),
        service,
        path,
        method,
        args
    ))
end

local function menu_event(service, menu_path, item_id)
    local ts = os.time()
    return shell_ok(string.format(
        "%sdbus-send --session --dest=%q --type=method_call %q com.canonical.dbusmenu.Event int32:%d string:clicked variant:byte:0 uint32:%d",
        dbus_env_prefix(),
        service,
        menu_path,
        item_id,
        ts
    ), "menu-event " .. tostring(item_id))
end

local function parse_dbusmenu_layout(output)
    local entries = {}

    for block in output:gmatch("<%b()>") do
        if block:find("'type': <'separator'>", 1, true) then
            entries[#entries + 1] = { separator = true }
        else
            local id = tonumber(block:match("%((%d+)"))
            local label = block:match("'label': <'(.-)'")
            if id and label and label ~= "" then
                entries[#entries + 1] = {
                    id = id,
                    label = label,
                    enabled = not block:find("'enabled': <false>", 1, true),
                }
            end
        end
    end

    return entries
end

local function menu_coords(x, y)
    local s = awful.screen.focused()
    local geo = s.geometry
    local min_y = geo.y + BAR_CLEARANCE
    x = math.floor(x or geo.x)
    y = math.floor(y or min_y)
    if y < min_y then
        y = min_y
    end
    return x, y
end

local function menu_window_near(x, y)
    local out = shell_output(string.format(
        "%sDISPLAY=%q bash -c '"
            .. "x=%d; y=%d; "
            .. "for wid in $(xdotool search --onlyvisible . 2>/dev/null); do "
            .. "[[ -z \"$wid\" ]] && continue; "
            .. "type=$(xprop -id \"$wid\" _NET_WM_WINDOW_TYPE 2>/dev/null || true); "
            .. "[[ \"$type\" == *POPUP* || \"$type\" == *MENU* || \"$type\" == *DROPDOWN* ]] || continue; "
            .. "eval \"$(xdotool getwindowgeometry --shell \\\"$wid\\\" 2>/dev/null)\" || continue; "
            .. "if (( X >= x - 80 && X <= x + 320 && Y >= y - 40 && Y <= y + 520 )); then echo yes; exit 0; fi; "
            .. "done'",
        dbus_env_prefix(),
        os.getenv("DISPLAY") or ":0",
        math.floor(x),
        math.floor(y)
    ))
    return out:find("yes", 1, true) ~= nil
end

local function try_embed_click(item, mx, my)
    local classes = {}
    local seen = {}

    local function add(class_name)
        if class_name and class_name ~= "" then
            local key = class_name:lower()
            if not seen[key] then
                seen[key] = true
                classes[#classes + 1] = class_name
            end
        end
    end

    add(item.wm_class)
    add(item.embed_primary)
    add(item.id_prop)
    add(item.id)

    for _, class_name in ipairs(classes) do
        local ok = shell_ok(string.format(
            "%s%q %q %d %d %d",
            dbus_env_prefix(),
            EMBED_CLICK,
            class_name,
            mx,
            my,
            item.systray_index or 0
        ), "embed " .. item.id)
        if ok then
            return true
        end
    end

    return false
end

local function try_sni_tray_menu(item, x, y)
    if not item.service then
        return false
    end

    local mx, my = menu_coords(x, y)
    local sni_path = item.sni_path or "/StatusNotifierItem"
    local method = "org.kde.StatusNotifierItem.ContextMenu"

    return shell_ok(string.format(
        "%sgdbus call --session -d %q -o %q -m %s -- %d %d",
        dbus_env_prefix(),
        item.service,
        sni_path,
        method,
        mx,
        my
    ), "sni " .. item.id, 2)
end

local function stop_menu_grabber()
    if menu_keygrabber then
        awful.keygrabber.stop(menu_keygrabber)
        menu_keygrabber = nil
    end
end

local function hide_awful_menu()
    if active_awful_menu and active_awful_menu.wibox and active_awful_menu.wibox.visible then
        active_awful_menu:hide()
    end
    active_awful_menu = nil
end

local function hide_menu()
    stop_menu_grabber()
    hide_awful_menu()
    if active_popup then
        active_popup.visible = false
        if active_popup.destroy then
            active_popup:destroy()
        end
        active_popup = nil
    end
    if active_overlay then
        active_overlay.visible = false
        if active_overlay.destroy then
            active_overlay:destroy()
        end
        active_overlay = nil
    end
end

local function menu_row(entry)
    if entry.separator then
        return wibox.widget {
            forced_height = 1,
            bg = c.surface1,
            widget = wibox.container.background,
        }
    end

    local enabled = entry.enabled ~= false
    local fg = enabled and c.text or c.overlay0
    local label = entry.label or ""

    local row = wibox.widget {
        {
            markup = string.format(
                '<span foreground="%s">%s</span>',
                fg,
                gstring.xml_escape(label)
            ),
            widget = wibox.widget.textbox,
        },
        left = 12,
        right = 12,
        top = 6,
        bottom = 6,
        widget = wibox.container.margin,
    }

    local bg = wibox.widget {
        row,
        forced_height = ROW_H,
        bg = c.base,
        widget = wibox.container.background,
    }

    if enabled and entry.action then
        local action = entry.action
        bg:buttons(gears.table.join(
            awful.button({}, 1, function()
                hide_menu()
                action()
            end)
        ))
        bg:connect_signal("mouse::enter", function()
            bg.bg = c.surface0
        end)
        bg:connect_signal("mouse::leave", function()
            bg.bg = c.base
        end)
    end

    return bg
end

local function start_menu_keygrabber()
    stop_menu_grabber()

    menu_keygrabber = awful.keygrabber.run(function(_mod, key, event)
        if event == "release" and key == "Escape" then
            hide_menu()
            return true
        end
        return false
    end)
end

local function show_menu_overlay(screen)
    local geo = screen.geometry

    active_overlay = awful.popup {
        screen = screen,
        visible = false,
        ontop = true,
        border_width = 0,
        bg = "#00000001",
        type = "utility",
        name = "awesome-tray-menu-overlay",
        widget = wibox.widget {
            widget = wibox.container.background,
        },
    }

    active_overlay:geometry {
        x = geo.x,
        y = geo.y + TOP_BAR_H,
        width = geo.width,
        height = math.max(geo.height - TOP_BAR_H, 0),
    }

    active_overlay:buttons(gears.table.join(
        awful.button({}, 1, hide_menu),
        awful.button({}, 3, hide_menu)
    ))
    active_overlay.visible = true
end

local function show_menu(entries, x, y)
    hide_menu()

    x, y = menu_coords(x, y)

    local rows = {}
    for _, entry in ipairs(entries) do
        rows[#rows + 1] = menu_row(entry)
    end

    if #rows == 0 then
        tray_log.info("menu show failed: no rows")
        return
    end

    local s = awful.screen.focused()
    local geo = s.geometry

    local layout = wibox.layout.fixed.vertical()
    for _, row in ipairs(rows) do
        layout:add(row)
    end

    local _, fitted_h = layout:fit(s, MENU_W, geo.height)
    local height = math.max(fitted_h + 8, ROW_H + 8)
    if x + MENU_W > geo.x + geo.width then
        x = geo.x + geo.width - MENU_W
    end
    if y + height > geo.y + geo.height then
        y = geo.y + geo.height - height
    end

    show_menu_overlay(s)

    active_popup = awful.popup {
        screen = s,
        visible = false,
        ontop = true,
        border_width = 1,
        border_color = c.surface1,
        bg = c.base,
        type = "utility",
        name = "awesome-tray-menu",
        shape = function(cr, w, h)
            gears.shape.rounded_rect(cr, w, h, 8)
        end,
        widget = wibox.widget {
            {
                layout,
                left = 4,
                right = 4,
                top = 4,
                bottom = 4,
                widget = wibox.container.margin,
            },
            widget = wibox.container.background,
        },
    }

    active_popup:geometry {
        x = x,
        y = y,
        width = MENU_W,
        height = height,
    }
    active_popup.visible = true

    if active_popup.raise then
        active_popup:raise()
    end

    start_menu_keygrabber()

    tray_log.info(string.format(
        "menu visible at %d,%d size=%dx%d items=%d",
        x,
        y,
        MENU_W,
        height,
        #rows
    ))
end

local function build_dbus_entries(entries, service, menu_path)
    local items = {}

    for _, entry in ipairs(entries) do
        if entry.separator then
            items[#items + 1] = { separator = true }
        else
            local id = entry.id
            items[#items + 1] = {
                label = entry.label,
                enabled = entry.enabled,
                action = function()
                    if entry.enabled then
                        menu_event(service, menu_path, id)
                    end
                end,
            }
        end
    end

    return items
end

local function try_dbus_menu(item, x, y)
    if not item.menu_path then
        return false
    end

    gdbus_call(item.service, item.menu_path, "com.canonical.dbusmenu.AboutToShow", "0")
    local layout_out = gdbus_call(
        item.service,
        item.menu_path,
        "com.canonical.dbusmenu.GetLayout",
        "0",
        "-1",
        "[]"
    )

    if layout_out == "" or layout_out:find("Usage:", 1, true) then
        tray_log.info("dbus " .. item.id .. ": GetLayout empty or usage error")
        return false
    end

    local entries = parse_dbusmenu_layout(layout_out)
    if #entries == 0 then
        tray_log.info("dbus " .. item.id .. ": parsed 0 menu entries")
        return false
    end

    tray_log.info("dbus " .. item.id .. ": showing " .. #entries .. " entries")
    show_menu(build_dbus_entries(entries, item.service, item.menu_path), x, y)
    return true
end

local function show_fallback(item, cl, x, y)
    local label = item.title or item.id
    show_menu({
        {
            label = "Open " .. label,
            enabled = true,
            action = function()
                if cl and cl.valid then
                    cl.minimized = false
                    awful.client.jumpto(cl)
                elseif item.launch then
                    awful.spawn(item.launch)
                end
            end,
        },
        {
            label = "Quit " .. label,
            enabled = true,
            action = function()
                if item.quit then
                    awful.spawn.with_shell(item.quit)
                end
            end,
        },
    }, x, y)
end

local function finish_native_tray_menu(item, x, y, cl, gen, native_ok)
    local pill = require("taskbar-pill")

    local function done()
        if gen ~= menu_generation then
            return
        end
        pill.restore_tray_host()
        embed_busy = false
    end

    if native_ok then
        tray_log.info("tray " .. item.id .. ": native menu triggered")
        gears.timer.start_new(8, done)
        return
    end

    done()
    tray_log.info("tray " .. item.id .. ": no native menu, showing fallback")
    show_fallback(item, cl, x, y)
end

local function try_native_tray_menu(item, x, y, cl, gen)
    if embed_busy then
        tray_log.info("tray " .. item.id .. ": busy, using fallback")
        show_fallback(item, cl, x, y)
        return true
    end

    embed_busy = true
    local mx, my = menu_coords(x, y)
    local pill = require("taskbar-pill")
    pill.prepare_tray_menu(item, mx, my)
    tray_log.info(string.format(
        "tray %s: systray aligned at index %s, %d,%d service=%s",
        item.id,
        tostring(item.systray_index),
        mx,
        my,
        tostring(item.service)
    ))

    local function finish_with(sni_ok, embed_ok)
        gears.timer.start_new(0.15, function()
            if gen ~= menu_generation then
                return
            end
            local native_ok = menu_window_near(mx, my) or sni_ok
            if not native_ok and embed_ok then
                tray_log.info("tray " .. item.id .. ": embed click ok but no menu detected")
            end
            finish_native_tray_menu(item, x, y, cl, gen, native_ok)
        end)
    end

    gears.timer.start_new(0.05, function()
        if gen ~= menu_generation then
            return
        end

        local sni_ok = item.service and try_sni_tray_menu(item, mx, my) or false

        gears.timer.start_new(0.2, function()
            if gen ~= menu_generation then
                return
            end

            if menu_window_near(mx, my) or sni_ok then
                finish_with(sni_ok, false)
                return
            end

            tray_log.info("tray " .. item.id .. ": no popup after sni, trying embed click")
            local embed_ok = try_embed_click(item, mx, my)
            finish_with(sni_ok, embed_ok)
        end)
    end)

    return true
end

function M.show(item, cl, x, y)
    if not item then
        return
    end

    x = math.floor(x or 0)
    y = math.floor(y or 0)
    menu_generation = menu_generation + 1
    local gen = menu_generation

    hide_menu()
    if not item.service and not item.menu_path then
        tray_registry.refresh(true)
    else
        tray_registry.refresh(false)
    end
    item = tray_registry.get(item.id) or item
    tray_log.info(string.format("show %s at %d,%d", item.id, x, y))

    local ok, err = pcall(function()
        if try_dbus_menu(item, x, y) then
            embed_busy = false
            return
        end

        if try_native_tray_menu(item, x, y, cl, gen) then
            return
        end

        show_fallback(item, cl, x, y)
    end)

    if not ok then
        embed_busy = false
        tray_log.info("show " .. item.id .. " error: " .. tostring(err))
        show_fallback(item, cl, x, y)
    end
end

return M
