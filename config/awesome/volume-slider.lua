local awful = require("awful")
local gears = require("gears")
local wibox = require("wibox")
local c = require("theme.catppuccin")

local M = {}

local POPUP_W = 340
local POPUP_H = 108
local POPUP_Y = 62
local POPUP_X_OFFSET = 24

local by_screen = {}

local function run_volume(cmd)
    awful.spawn.with_shell(cmd)
end

local function get_volume(callback)
    awful.spawn.easy_async_with_shell([[
        if command -v wpctl >/dev/null 2>&1; then
            wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null
        else
            pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | head -1
        fi
    ]], function(out)
        if not out or out == "" then
            callback(false, 0)
            return
        end

        local muted = out:match("%[MUTED%]") ~= nil
        local pct = 0
        local vol = out:match("([0-9]+)%%")

        if vol then
            pct = tonumber(vol)
        else
            vol = out:match("([0-9%.]+)")
            if vol then
                pct = math.floor(tonumber(vol) * 100 + 0.5)
            end
        end

        callback(muted, math.max(0, math.min(100, pct)))
    end)
end

local function set_volume(pct)
    pct = math.max(0, math.min(100, pct))
    run_volume(string.format(
        "wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 2>/dev/null; "
            .. "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ %.2f 2>/dev/null || "
            .. "pactl set-sink-mute @DEFAULT_SINK@ 0; "
            .. "pactl set-sink-volume @DEFAULT_SINK@ %d%%",
        pct / 100,
        pct
    ))
end

local function set_mute(muted)
    if muted then
        run_volume("wpctl set-mute @DEFAULT_AUDIO_SINK@ 1 2>/dev/null || pactl set-sink-mute @DEFAULT_SINK@ 1")
    else
        run_volume("wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 2>/dev/null || pactl set-sink-mute @DEFAULT_SINK@ 0")
    end
end

local function contains(geo, x, y)
    return x >= geo.x
        and x <= geo.x + geo.width
        and y >= geo.y
        and y <= geo.y + geo.height
end

function M.create(s)
    if by_screen[s] then
        return by_screen[s]
    end

    local state = {
        updating = false,
        muted = false,
    }

    local level_label = wibox.widget {
        markup = "0%",
        align = "right",
        widget = wibox.widget.textbox,
    }

    local slider = wibox.widget {
        bar_color = c.base,
        bar_active = c.sky,
        handle_color = c.sky,
        minimum = 0,
        maximum = 100,
        value = 0,
        forced_width = 300,
        forced_height = 20,
        widget = wibox.widget.slider,
    }

    local mute_label = wibox.widget {
        markup = string.format('<span foreground="%s">Mute</span>', c.text),
        widget = wibox.widget.textbox,
    }

    slider:connect_signal("property::value", function()
        if state.updating then
            return
        end
        local value = math.floor(slider.value + 0.5)
        level_label:set_markup(string.format('<span foreground="%s">%d%%</span>', c.sky, value))
        set_volume(value)
        state.muted = false
        mute_label:set_markup(string.format(
            '<span foreground="%s">Mute</span>',
            c.text
        ))
    end)

    local mute_btn = wibox.widget {
        {
            mute_label,
            left = 12,
            right = 12,
            top = 4,
            bottom = 4,
            widget = wibox.container.margin,
        },
        bg = c.base,
        shape = function(cr, w, h)
            gears.shape.rounded_rect(cr, w, h, 6)
        end,
        widget = wibox.container.background,
    }

    mute_btn:buttons(gears.table.join(
        awful.button({}, 1, function()
            state.muted = not state.muted
            set_mute(state.muted)
            if state.muted then
                state.updating = true
                slider.value = 0
                level_label:set_markup(string.format('<span foreground="%s">0%%</span>', c.sky))
                mute_label:set_markup(string.format('<span foreground="%s">Unmute</span>', c.text))
                state.updating = false
            else
                get_volume(function(_, pct)
                    state.updating = true
                    local restore = math.max(pct, 30)
                    slider.value = restore
                    level_label:set_markup(string.format('<span foreground="%s">%d%%</span>', c.sky, restore))
                    set_volume(restore)
                    mute_label:set_markup(string.format('<span foreground="%s">Mute</span>', c.text))
                    state.muted = false
                    state.updating = false
                end)
            end
        end)
    ))

    local popup = awful.popup {
        screen = s,
        visible = false,
        ontop = true,
        border_width = 1,
        border_color = c.mauve,
        bg = c.surface0,
        shape = function(cr, w, h)
            gears.shape.rounded_rect(cr, w, h, 10)
        end,
        widget = {
            {
                {
                    layout = wibox.layout.fixed.vertical,
                    {
                        {
                            {
                                markup = string.format(
                                    '<span foreground="%s" font="DejaVu Sans Bold 11">Speaker volume</span>',
                                    c.text
                                ),
                                widget = wibox.widget.textbox,
                            },
                            level_label,
                            layout = wibox.layout.flex.horizontal,
                        },
                        top = 12,
                        bottom = 10,
                        left = 14,
                        right = 14,
                        widget = wibox.container.margin,
                    },
                    {
                        slider,
                        left = 14,
                        right = 14,
                        widget = wibox.container.margin,
                    },
                    {
                        mute_btn,
                        left = 14,
                        right = 14,
                        top = 10,
                        bottom = 12,
                        widget = wibox.container.margin,
                    },
                },
                widget = wibox.container.margin,
            },
            widget = wibox.container.background,
        },
    }

    popup:struts { left = 0, right = 0, top = 0, bottom = 0 }

    local function place()
        local geo = s.geometry
        popup:geometry {
            x = geo.x + geo.width - POPUP_W - POPUP_X_OFFSET,
            y = geo.y + POPUP_Y,
            width = POPUP_W,
            height = POPUP_H,
        }
    end

    local function stop_grabbers()
        if state.keygrabber then
            awful.keygrabber.stop(state.keygrabber)
            state.keygrabber = nil
        end
        if state.mousegrabber then
            gears.timer.delayed_call(function()
                if state.mousegrabber then
                    mousegrabber.stop()
                    state.mousegrabber = false
                end
            end)
        end
    end

    local function hide()
        popup.visible = false
        stop_grabbers()
    end

    local function start_grabbers()
        if state.keygrabber then
            awful.keygrabber.stop(state.keygrabber)
            state.keygrabber = nil
        end
        if state.mousegrabber then
            mousegrabber.stop()
            state.mousegrabber = false
        end
        state.mousegrabber = true

        mousegrabber.run(function(m)
            if not popup.visible then
                return false
            end

            if m.buttons[1] or m.buttons[2] or m.buttons[3] then
                local geo = popup:geometry()
                if not contains(geo, m.x, m.y) then
                    hide()
                    return false
                end
            end

            return true
        end, "arrow")

        state.keygrabber = awful.keygrabber.run(function(_mod, key, event)
            if event == "release" and key == "Escape" then
                hide()
                return true
            end
            return false
        end)
    end

    local function show()
        get_volume(function(muted, pct)
            state.updating = true
            state.muted = muted
            slider.value = muted and 0 or pct
            level_label:set_markup(string.format(
                '<span foreground="%s">%d%%</span>',
                c.sky,
                muted and 0 or pct
            ))
            mute_label:set_markup(string.format(
                '<span foreground="%s">%s</span>',
                c.text,
                muted and "Unmute" or "Mute"
            ))
            state.updating = false

            place()
            popup.visible = true
            if popup.raise then
                popup:raise()
            end

            -- Opening click lands on polybar; delay grabber so we do not instantly dismiss.
            gears.timer.start_new(0.2, function()
                if popup.visible then
                    start_grabbers()
                end
                return false
            end)
        end)
    end

    s:connect_signal("property::geometry", function()
        if popup.visible then
            place()
        end
    end)

    by_screen[s] = {
        popup = popup,
        show = show,
        hide = hide,
        toggle = function()
            if popup.visible then
                hide()
            else
                show()
            end
        end,
    }
end

function M.toggle()
    local s = awful.screen.focused()
    if not s then
        return
    end

    if not by_screen[s] then
        M.create(s)
    end

    by_screen[s].toggle()
end

function M.hide()
    local s = awful.screen.focused()
    if not s or not by_screen[s] then
        return
    end

    by_screen[s].hide()
end

return M
