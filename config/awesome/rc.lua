pcall(require, "luarocks.loader")

local gears = require("gears")
local awful = require("awful")
require("awful.autofocus")
local beautiful = require("beautiful")
local naughty = require("naughty")
local hotkeys_popup = require("awful.hotkeys_popup")
require("awful.hotkeys_popup.keys")
local taskbar_pill = require("taskbar-pill")
local volume_slider = require("volume-slider")
local awesome_log = require("awesome-log")

-- Error handling
if awesome.startup_errors then
    awesome_log.error("startup", awesome.startup_errors)
    awesome_log.notify("Startup errors", awesome.startup_errors, { id = "startup" })
end

do
    local in_error = false
    awesome.connect_signal("debug::error", function(err)
        if in_error then
            return
        end
        in_error = true
        awesome_log.error("awesome", err)
        awesome_log.notify("Awesome error", tostring(err), { id = "debug-error" })
        in_error = false
    end)
end

beautiful.init("~/.config/awesome/theme/theme.lua")

terminal = "kitty"
editor = os.getenv("EDITOR") or "nvim"
lock_screen = os.getenv("HOME") .. "/.local/bin/lock-screen"
modkey = "Mod4"

local function cycle_client(delta)
    local tag = awful.screen.focused().selected_tag
    if not tag then
        return
    end

    local visible = {}
    for _, c in ipairs(tag:clients()) do
        if awful.client.focus.filter(c) and not c.minimized then
            visible[#visible + 1] = c
        end
    end

    if #visible == 0 then
        return
    end

    local current = 1
    for i, c in ipairs(visible) do
        if c == client.focus then
            current = i
            break
        end
    end

    local next_index = current
    if #visible > 1 then
        next_index = current + delta
        while next_index < 1 do
            next_index = next_index + #visible
        end
        while next_index > #visible do
            next_index = next_index - #visible
        end
    end

    local target = visible[next_index]
    if target.minimized then
        target.minimized = false
    end
    target:raise()
    client.focus = target
end

awful.layout.layouts = {
    awful.layout.suit.tile,
    awful.layout.suit.floating,
    awful.layout.suit.fair,
    awful.layout.suit.max,
}

local function set_wallpaper(s)
    if beautiful.wallpaper then
        local wallpaper = beautiful.wallpaper
        if type(wallpaper) == "function" then wallpaper = wallpaper(s) end
        gears.wallpaper.maximized(wallpaper, s, true)
    end
end

screen.connect_signal("property::geometry", set_wallpaper)

awful.screen.connect_for_each_screen(function(s)
    set_wallpaper(s)
    awful.tag({ "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" }, s, awful.layout.layouts[1])

    local ok, err = pcall(taskbar_pill.create, s)
    if not ok then
        awesome_log.error("taskbar-pill.create", err)
        awesome_log.notify(
            "Taskbar pill unavailable",
            "The center app bar failed to start. Polybar and window management still work.",
            { id = "taskbar-pill-create" }
        )
    end

    ok, err = pcall(volume_slider.create, s)
    if not ok then
        awesome_log.error("volume-slider.create", err)
        awesome_log.notify(
            "Volume slider unavailable",
            tostring(err),
            { id = "volume-slider-create" }
        )
    end
end)

root.buttons(gears.table.join(
    awful.button({}, 4, awful.tag.viewnext),
    awful.button({}, 5, awful.tag.viewprev)
))

globalkeys = gears.table.join(
    awful.key({ modkey }, "s", hotkeys_popup.show_help, { description = "show help", group = "awesome" }),
    awful.key({ modkey, "Shift" }, "r", awesome.restart, { description = "reload awesome", group = "awesome" }),
    awful.key({ modkey, "Shift" }, "Escape", awesome.restart, { description = "panic reload awesome", group = "awesome" }),

    -- Justus-style app launchers
    awful.key({ modkey }, "Return", function() awful.spawn(terminal) end, { description = "terminal", group = "launcher" }),
    awful.key({ modkey }, "b", function() awful.spawn("google-chrome-stable") end, { description = "browser", group = "launcher" }),
    awful.key({ modkey }, "e", function() awful.spawn("thunar") end, { description = "file manager", group = "launcher" }),
    awful.key({ modkey }, "d", function() awful.spawn("rofi -show calc -modi calc -no-show-match -no-sort") end, { description = "calculator", group = "launcher" }),
    awful.key({ modkey }, "o", function() awful.spawn("rofi -modi ssh,run -show ssh") end, { description = "ssh", group = "launcher" }),
    awful.key({ modkey }, "p", function() awful.spawn("rofi -modi drun,run -show drun") end, { description = "app launcher", group = "launcher" }),
    awful.key({ modkey }, "w", function() awful.spawn(os.getenv("HOME") .. "/.config/rofi/scripts/wallpaper-picker.sh") end, { description = "wallpaper picker", group = "launcher" }),
    awful.key({ "Mod1" }, "Tab", function() awful.spawn("rofi -modi window,run -show window") end, { description = "window switcher", group = "launcher" }),

    -- Screen lock
    awful.key({ modkey, "Control" }, "l", function()
        awful.spawn(lock_screen)
    end, { description = "lock screen", group = "system" }),

    -- Window management
    awful.key({ modkey, "Shift" }, "c", function()
        local c = client.focus
        if c then c:kill() end
    end, { description = "close window", group = "client" }),
    awful.key({ modkey }, "f", function()
        local c = client.focus
        if c then
            c.fullscreen = not c.fullscreen
            c:raise()
        end
    end, { description = "fullscreen", group = "client" }),
    awful.key({ modkey, "Control" }, "space", awful.client.floating.toggle, { description = "toggle floating", group = "client" }),

    -- Focus (vim-style spatial + cycle windows on current tag)
    awful.key({ modkey }, "j", function() cycle_client(1) end, { description = "next window on tag", group = "client" }),
    awful.key({ modkey }, "k", function() cycle_client(-1) end, { description = "previous window on tag", group = "client" }),
    awful.key({ modkey }, "h", function() awful.client.focus.bydirection("left") end, { description = "focus left", group = "client" }),
    awful.key({ modkey }, "l", function() awful.client.focus.bydirection("right") end, { description = "focus right", group = "client" }),
    awful.key({ modkey }, "Left", function() awful.client.focus.bydirection("left") end, { description = "focus left", group = "client" }),
    awful.key({ modkey }, "Down", function() awful.client.focus.bydirection("down") end, { description = "focus down", group = "client" }),
    awful.key({ modkey }, "Up", function() awful.client.focus.bydirection("up") end, { description = "focus up", group = "client" }),
    awful.key({ modkey }, "Right", function() awful.client.focus.bydirection("right") end, { description = "focus right", group = "client" }),

    -- Move windows
    awful.key({ modkey, "Shift" }, "h", function()
        local c = client.focus
        if c then c:move_to_screen(c.screen.index - 1) end
    end, { description = "move to prev screen", group = "client" }),
    awful.key({ modkey, "Shift" }, "l", function()
        local c = client.focus
        if c then c:move_to_screen(c.screen.index + 1) end
    end, { description = "move to next screen", group = "client" }),

    -- Layout
    awful.key({ modkey }, "space", function() awful.layout.inc(1) end, { description = "next layout", group = "layout" }),
    awful.key({ modkey, "Shift" }, "space", function() awful.layout.inc(-1) end, { description = "previous layout", group = "layout" }),

    -- Screenshots
    awful.key({ modkey }, "n", function() awful.spawn("flameshot gui") end, { description = "screenshot area", group = "screenshot" }),
    awful.key({ modkey, "Shift" }, "s", function() awful.spawn("flameshot gui") end, { description = "screenshot area", group = "screenshot" }),
    awful.key({ modkey }, "m", function() awful.spawn("flameshot screen") end, { description = "screenshot screen", group = "screenshot" }),
    awful.key({ modkey, "Shift" }, "F23", function() awful.spawn("flameshot gui") end, { description = "copilot key screenshot", group = "screenshot" }),
    awful.key({}, "XF86Assistant", function() awful.spawn("flameshot gui") end, { description = "copilot key screenshot", group = "screenshot" }),
    awful.key({}, "F23", function() awful.spawn("flameshot gui") end, { description = "copilot key screenshot", group = "screenshot" }),
    awful.key({}, "Print", function() awful.spawn("flameshot gui") end, { description = "screenshot area", group = "screenshot" }),

    -- Audio
    awful.key({}, "XF86AudioRaiseVolume", function()
        awful.spawn.with_shell("pactl set-sink-volume @DEFAULT_SINK@ +5%")
    end, { description = "volume up", group = "audio" }),
    awful.key({}, "XF86AudioLowerVolume", function()
        awful.spawn.with_shell("pactl set-sink-volume @DEFAULT_SINK@ -5%")
    end, { description = "volume down", group = "audio" }),
    awful.key({}, "XF86AudioMute", function()
        awful.spawn.with_shell("pactl set-sink-mute @DEFAULT_SINK@ toggle")
    end, { description = "mute", group = "audio" })
)

clientkeys = gears.table.join(
    awful.key({ modkey, "Control" }, "m", function(c)
        c.maximized = not c.maximized
        c:raise()
    end, { description = "maximize", group = "client" }),
    awful.key({ modkey, "Shift" }, "n", function(c) c.minimized = true end, { description = "minimize", group = "client" })
)

for i = 1, 9 do
    globalkeys = gears.table.join(globalkeys,
        awful.key({ modkey }, "#" .. i + 9, function()
            local tag = awful.screen.focused().tags[i]
            if tag then tag:view_only() end
        end, { description = "view tag #" .. i, group = "tag" }),
        awful.key({ modkey, "Shift" }, "#" .. i + 9, function()
            if client.focus then
                local tag = client.focus.screen.tags[i]
                if tag then client.focus:move_to_tag(tag) end
            end
        end, { description = "move to tag #" .. i, group = "tag" })
    )
end

globalkeys = gears.table.join(globalkeys,
    awful.key({ modkey }, "#" .. 19, function()
        local tag = awful.screen.focused().tags[10]
        if tag then tag:view_only() end
    end, { description = "view tag 0", group = "tag" })
)

clientbuttons = gears.table.join(
    awful.button({}, 1, function(c)
        c:emit_signal("request::activate", "mouse_click", { raise = true })
    end),
    awful.button({ modkey }, 1, function(c)
        c:emit_signal("request::activate", "mouse_click", { raise = true })
        awful.mouse.client.move(c)
    end),
    awful.button({ modkey }, 3, function(c)
        c:emit_signal("request::activate", "mouse_click", { raise = true })
        awful.mouse.client.resize(c)
    end)
)

root.keys(globalkeys)

awful.rules.rules = {
    {
        rule = {},
        properties = {
            border_width = 0,
            focus = awful.client.focus.filter,
            raise = true,
            keys = clientkeys,
            buttons = clientbuttons,
            screen = awful.screen.preferred,
            placement = awful.placement.no_overlap + awful.placement.no_offscreen,
            titlebars_enabled = false,
        }
    },
    {
        rule_any = {
            class = {
                "Arandr", "Blueman-manager", "Pavucontrol", "Nm-connection-editor",
                "Gpick", "Kruler", "MessageWin", "Sxiv", "flameshot",
            },
            instance = { "copyq", "pinentry" },
            role = { "pop-up" },
        },
        properties = { floating = true, placement = awful.placement.centered }
    },
    {
        rule_any = {
            type = { "popup_menu", "dropdown_menu", "menu", "tooltip" },
        },
        properties = {
            ontop = true,
            focus = true,
            raise = true,
            border_width = 0,
        },
    },
}

client.connect_signal("manage", function(c)
    -- Plank uses a full-width bottom window that blocks clicks in Awesome.
    if c.class == "Plank" then
        c:kill()
        return
    end

    if c.type == "popup_menu" or c.type == "dropdown_menu" or c.type == "menu" then
        c.ontop = true
        c:raise()
    end

    if awesome.startup and not c.size_hints.user_position and not c.size_hints.program_position then
        awful.placement.no_offscreen(c)
    end
end)

awful.spawn.with_shell("~/.config/awesome/autostart.sh")
