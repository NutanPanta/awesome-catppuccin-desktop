local awful = require("awful")
local gears = require("gears")
local wibox = require("wibox")
local c = require("theme.catppuccin")

local M = {}

local SKIP_CLASSES = {
    Polybar = true,
    polybar = true,
    awesome = true,
    Plank = true,
    picom = true,
    xfdesktop = true,
    ["blueman-manager"] = true,
}

local CSD_CLASSES = {
    ["google-chrome"] = true,
    ["Google-chrome"] = true,
    ["Chromium"] = true,
    chromium = true,
    Firefox = true,
    firefox = true,
    code = true,
    Code = true,
    cursor = true,
    Cursor = true,
    kitty = true,
    Kitty = true,
    Alacritty = true,
    alacritty = true,
    WezTerm = true,
    wezterm = true,
}

local SKIP_TYPES = {
    desktop = true,
    dock = true,
    splash = true,
    notification = true,
    toolbar = true,
    menu = true,
    dropdown_menu = true,
    popup_menu = true,
    tooltip = true,
    utility = true,
}

local function should_skip(c)
    if not c or not c.valid then
        return true
    end
    if SKIP_TYPES[c.type] then
        return true
    end
    local cls = c.class or ""
    if SKIP_CLASSES[cls] or SKIP_CLASSES[cls:lower()] then
        return true
    end
    if CSD_CLASSES[cls] or CSD_CLASSES[cls:lower()] then
        return true
    end
    if c.name and c.name:lower():find("polybar", 1, true) then
        return true
    end
    return false
end

local function title_button(icon, tooltip, on_click)
    local widget = wibox.widget {
        {
            markup = string.format(
                '<span font="JetBrainsMono Nerd Font 14" foreground="%s">%s</span>',
                c.subtext0,
                icon
            ),
            align = "center",
            valign = "center",
            widget = wibox.widget.textbox,
        },
        forced_width = 28,
        forced_height = 28,
        widget = wibox.container.place,
    }

    widget:buttons(gears.table.join(
        awful.button({}, 1, function()
            if not c.valid then
                return
            end
            on_click(c)
        end)
    ))

    awful.tooltip {
        objects = { widget },
        text = tooltip,
        timer_delay = 0.2,
    }

    return widget
end

function M.add(c)
    if should_skip(c) or c._custom_titlebar_added then
        return
    end
    c._custom_titlebar_added = true

    awful.titlebar.show(c, "top")

    local titlebar = awful.titlebar(c, {
        size = 34,
        bg_normal = c.mantle,
        bg_focus = c.surface0,
        bg_urgent = c.red,
    })

    local title = wibox.widget {
        markup = "",
        ellipsize = "end",
        widget = wibox.widget.textbox,
    }

    local function update_title()
        if not c.valid then
            return
        end
        local name = c.name or c.class or "Window"
        title:set_markup(string.format(
            '<span foreground="%s">%s</span>',
            c.text,
            gears.string.xml_escape(name)
        ))
    end

    update_title()
    c:connect_signal("property::name", update_title)
    c:connect_signal("property::class", update_title)

    local controls = wibox.widget {
        layout = wibox.layout.fixed.horizontal,
        title_button("󰃀", "Pin on top", function(client)
            client.sticky = not client.sticky
        end),
        title_button("󰖰", "Minimize", function(client)
            client.minimized = true
        end),
        title_button("󰖯", "Maximize", function(client)
            client.maximized = not client.maximized
            client:raise()
        end),
        title_button("󰅖", "Close", function(client)
            client:kill()
        end),
    }

    titlebar:setup {
        {
            {
                {
                    widget = awful.widget.clienticon(c),
                    forced_width = 18,
                    forced_height = 18,
                },
                {
                    title,
                    left = 8,
                    right = 8,
                    widget = wibox.container.margin,
                },
                layout = wibox.layout.fixed.horizontal,
            },
            left = 10,
            right = 4,
            widget = wibox.container.margin,
        },
        nil,
        {
            controls,
            right = 6,
            widget = wibox.container.margin,
        },
        layout = wibox.layout.align.horizontal,
    }
end

return M
