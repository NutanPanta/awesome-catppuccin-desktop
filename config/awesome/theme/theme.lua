local c = require("theme.catppuccin")

local theme = {}

theme.font = "JetBrainsMono Nerd Font 10"
theme.wallpaper = os.getenv("HOME") .. "/.config/wallpapers/Eva Mocha.png"

theme.useless_gap = 15
theme.border_width = 0
theme.border_radius = 8

theme.fg_normal  = c.text
theme.fg_focus   = c.text
theme.fg_urgent  = c.red
theme.fg_minimize = c.overlay0

theme.bg_normal  = c.base
theme.bg_focus   = c.surface0
theme.bg_urgent  = c.red
theme.bg_minimize = c.mantle

theme.border_normal = c.surface1
theme.border_focus  = c.mauve
theme.border_marked = c.peach

theme.taglist_fg_normal   = c.subtext0
theme.taglist_fg_focus    = c.base
theme.taglist_fg_urgent   = c.base
theme.taglist_fg_empty    = c.overlay0
theme.taglist_fg_volatile = c.red

theme.taglist_bg_normal   = c.base
theme.taglist_bg_focus    = c.mauve
theme.taglist_bg_urgent   = c.red
theme.taglist_bg_empty    = c.base
theme.taglist_bg_volatile = c.red

theme.tasklist_fg_normal  = c.text
theme.tasklist_fg_focus   = c.mauve
theme.tasklist_fg_urgent  = c.red
theme.tasklist_fg_minimize = c.overlay0

theme.tasklist_bg_normal  = c.base
theme.tasklist_bg_focus   = c.surface0
theme.tasklist_bg_urgent  = c.red
theme.tasklist_bg_minimize = c.mantle

theme.titlebar_fg_normal  = c.text
theme.titlebar_fg_focus   = c.mauve
theme.titlebar_fg_urgent  = c.red

theme.titlebar_bg_normal  = c.mantle
theme.titlebar_bg_focus   = c.surface0
theme.titlebar_bg_urgent  = c.red

theme.titlebar_fg_normal_inactive  = c.subtext0
theme.titlebar_fg_focus_inactive   = c.subtext0
theme.titlebar_fg_urgent_inactive = c.red

theme.titlebar_bg_normal_inactive  = c.mantle
theme.titlebar_bg_focus_inactive   = c.mantle
theme.titlebar_bg_urgent_inactive  = c.red

theme.menu_fg_normal  = c.text
theme.menu_fg_focus   = c.base
theme.menu_fg_urgent  = c.red

theme.menu_bg_normal  = c.base
theme.menu_bg_focus   = c.mauve
theme.menu_bg_urgent  = c.red

theme.menu_submenu_bg = c.mantle
theme.menu_border_color = c.surface1
theme.menu_border_width = 1
theme.menu_height = 22
theme.menu_width  = 200

theme.hotkeys_modifiers_fg = c.mauve
theme.hotkeys_fg = c.text
theme.hotkeys_description = c.subtext0
theme.hotkeys_group = c.lavender
theme.hotkeys_label = c.text
theme.hotkeys_geometry = { width = 900, height = 600 }

theme.notification_fg = c.text
theme.notification_bg = c.base
theme.notification_border_color = c.mauve
theme.notification_border_width = 2
theme.notification_icon_size = 48
theme.notification_margin = 12
theme.notification_spacing = 8

theme.systray_icon_spacing = 8

theme.wibar_bg = c.mantle
theme.wibar_fg = c.text
theme.wibar_border_color = c.crust
theme.wibar_border_width = 0
theme.wibar_height = 28

theme.prompt_fg = c.text
theme.prompt_bg = c.surface0
theme.prompt_border_color = c.mauve
theme.prompt_border_width = 1

theme.colors = c

return theme
