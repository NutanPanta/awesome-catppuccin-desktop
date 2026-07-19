-- Discover tray apps from systray embed scan + DBus SNI (no hardcoded app list).

local menubar_utils = require("menubar.utils")

local M = {}

local SCAN_SCRIPT = os.getenv("HOME") .. "/.config/awesome/scripts/tray-menu-scan.sh"
local CACHE_TTL = 30

local match_items

local SYSTEM_TRAY_IDS = {
    pasystray = true,
    blueman = true,
    ["nm-applet"] = true,
    copyq = true,
    snixembed = true,
    electron = true,
    awesome = true,
    unknown = true,
    ["xdg-desktop-portal-gtk"] = true,
    ["xdg-desktop-portal-xapp"] = true,
    ["xfce4-power-manager"] = true,
    ["polkit-gnome-authentication-agent-1"] = true,
    chromium = true,
    thunar = true,
    bamfdaemon = true,
    flameshot = true,
}

local SKIP_ID_PATTERNS = {
    "portal",
    "bamf",
    "polkit",
    "power%-manager",
    "snixembed",
}

local cache = {
    items = {},
    by_id = {},
    scan = {},
    sni = {},
    at = 0,
}

local function shell_output(cmd)
    local handle = io.popen(cmd .. " 2>/dev/null")
    if not handle then
        return ""
    end
    local out = handle:read("*a") or ""
    handle:close()
    return out
end

local function normalize_id(value)
    value = (value or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    if value == "" then
        return "tray-item"
    end
    return value
end

local function parse_property_string(output)
    if not output or output == "" then
        return nil
    end

    output = output:gsub("^%s+", ""):gsub("%s+$", "")

    -- busctl: s "value"
    local value = output:match('^%S+%s+"([^"]+)"')
    if value then
        return value
    end

    value = output:match('^%S+%s+(%S+)')
    if value then
        return value
    end

    return output:match('"%s+"%s+"([^"]+)"')
        or output:match('"%s+"%s-([^%s"]+)')
end

local function bus_property(service, path, prop)
    return parse_property_string(shell_output(string.format(
        "busctl --user get-property %q %q org.kde.StatusNotifierItem %q",
        service,
        path,
        prop
    )))
end

local TRAY_ICON_SIZES = { 22, 24, 32, 16, 48, 64, 256 }

local function file_exists(path)
    if not path or path == "" then
        return false
    end
    local handle = io.open(path, "r")
    if handle then
        handle:close()
        return true
    end
    return false
end

local function resolve_theme_icon(theme_path, icon_name)
    if not theme_path or theme_path == "" or not icon_name or icon_name == "" then
        return nil
    end

    local candidates = {
        theme_path .. "/" .. icon_name .. ".png",
        theme_path .. "/" .. icon_name .. ".svg",
    }

    for _, size in ipairs(TRAY_ICON_SIZES) do
        candidates[#candidates + 1] = string.format(
            "%s/hicolor/%dx%d/apps/%s.png",
            theme_path,
            size,
            size,
            icon_name
        )
        candidates[#candidates + 1] = string.format(
            "%s/hicolor/%dx%d/apps/%s.svg",
            theme_path,
            size,
            size,
            icon_name
        )
    end

    for _, path in ipairs(candidates) do
        if file_exists(path) then
            return path
        end
    end
end

local function refresh_sni_icon(item)
    if not item or not item.service or not item.sni_path then
        return false
    end

    local icon_name = bus_property(item.service, item.sni_path, "IconName")
    local theme_path = bus_property(item.service, item.sni_path, "IconThemePath")
    local icon_key = (icon_name or "") .. "|" .. (theme_path or "")
    if item.icon_key == icon_key and item.icon_path then
        return false
    end

    item.icon_key = icon_key
    item.icon_name = icon_name

    if icon_name and icon_name ~= "" then
        local path = resolve_theme_icon(theme_path, icon_name)
        if not path then
            path = menubar_utils.lookup_icon_uncached(icon_name:lower())
            if path == false then
                path = nil
            end
        end
        if path then
            item.icon_path = path
            return true
        end
    end

    return false
end

local function service_on_bus(service)
    if not service or service == "" then
        return false
    end
    if not service:match("^:") then
        return shell_output("busctl --user status " .. service) ~= ""
    end
    return shell_output("busctl --user list"):find(service, 1, true) ~= nil
end

local function service_pid(service)
    for line in shell_output("busctl --user list"):gmatch("[^\n]+") do
        local bus, pid = line:match("^(%S+)%s+(%d+)")
        if bus == service and pid then
            return tonumber(pid)
        end
    end
end

local function find_sni_path(service)
    local tree = shell_output("busctl --user tree " .. service)
    local best

    for line in tree:gmatch("[^\n]+") do
        local path = line:match("(%S+)$")
        if path and path:sub(1, 1) == "/" then
            if path:find("StatusNotifierItem", 1, true) and not path:find("Menu", 1, true) then
                best = path
            elseif path:find("NotificationItem", 1, true)
                and not path:find("Menu", 1, true)
                and not path:find("Watcher", 1, true)
            then
                best = path
            end
        end
    end

    if best then
        return best
    end

    if tree:find("/StatusNotifierItem", 1, true) then
        return "/StatusNotifierItem"
    end

    return "/StatusNotifierItem"
end

local function find_menu_path(service)
    local tree = shell_output("busctl --user tree " .. service)
    local candidates = {}

    for line in tree:gmatch("[^\n]+") do
        local path = line:match("(%S+)$")
        if path and path:sub(1, 1) == "/" then
            if path:find("Menu", 1, true) or path:find("DbusMenu", 1, true) then
                candidates[#candidates + 1] = path
            end
        end
    end

    table.insert(candidates, 1, "/com/canonical/dbusmenu")

    for _, path in ipairs(candidates) do
        local intro = shell_output(string.format("busctl --user introspect %q %q", service, path))
        if intro:find("com.canonical.dbusmenu", 1, true)
            or intro:find("DbusMenu", 1, true)
        then
            return path
        end
    end
end

local function lookup_desktop_exec(item)
    local desktop = M.find_desktop_path(item)
    if desktop then
        local exec_line = shell_output("grep '^Exec=' " .. desktop .. " | head -1")
        local exec = exec_line:match("^Exec=(.-)$")
        if exec then
            exec = exec:gsub("%%[uUfF]", ""):gsub('"', "")
            return exec
        end
    end

    return item.id_prop or item.wm_class
end

function M.find_desktop_path(item)
    local home = os.getenv("HOME") or ""
    local queries = {}

    local function add_query(field, value)
        if value and value ~= "" then
            queries[#queries + 1] = string.format(
                "grep -ril '%s=%s' %s/.local/share/applications /usr/share/applications 2>/dev/null | head -1",
                field,
                value,
                home
            )
        end
    end

    add_query("StartupWMClass", item.wm_class)
    add_query("StartupWMClass", item.id_prop)
    add_query("Name", item.title)

    for _, query in ipairs(queries) do
        local desktop = shell_output(query):match("^[^\n]+")
        if desktop and desktop ~= "" then
            return desktop
        end
    end
end

local function desktop_is_user_app(desktop_path)
    local cats = shell_output("grep '^Categories=' " .. desktop_path):lower()
    if cats == "" then
        return false
    end

    local allow = {
        "chat",
        "network",
        "instantmessaging",
        "audiovideo",
        "audio",
        "video",
        "office",
        "email",
        "game",
        "projectmanagement",
    }

    for _, cat in ipairs(allow) do
        if cats:find(cat, 1, true) then
            return true
        end
    end

    return false
end

local function refresh_scan()
    cache.scan = {}

    local handle = io.popen(SCAN_SCRIPT .. " 2>/dev/null")
    if not handle then
        return
    end

    for line in handle:lines() do
        local index, primary, secondary, name = line:match("^(%d+)%s+(%S+)%s+(%S+)%s*(.*)$")
        if index then
            cache.scan[#cache.scan + 1] = {
                index = tonumber(index),
                primary = primary,
                secondary = secondary,
                name = (name or ""):gsub("%s+$", ""),
            }
        end
    end

    handle:close()
end

local function skip_scan_entry(scan)
    local secondary = normalize_id(scan.secondary)
    local primary = normalize_id(scan.primary)
    local name = (scan.name or ""):lower()

    if SYSTEM_TRAY_IDS[secondary] or SYSTEM_TRAY_IDS[primary] then
        return true
    end
    if scan.primary:find("status_icon", 1, true) then
        -- Electron apps (Cursor, Chrome) expose real tray menus via status icons.
        if not scan.secondary:lower():find("cursor", 1, true)
            and not scan.secondary:lower():find("chrome", 1, true)
        then
            return true
        end
    end
    if scan.secondary:lower() == "snixembed" or scan.primary:lower() == "snixembed" then
        return true
    end
    if scan.primary:lower() == "unknown" then
        return true
    end
    if name:find("clipboard", 1, true) then
        return true
    end
    local id = normalize_id(scan.secondary)
    for _, pattern in ipairs(SKIP_ID_PATTERNS) do
        if id:find(pattern) or scan.secondary:lower():find(pattern, 1, true) then
            return true
        end
    end
    return false
end

local function service_has_sni_path(service)
    local tree = shell_output("busctl --user tree " .. service)
    return tree:find("/StatusNotifierItem", 1, true) ~= nil
        or tree:find("NotificationItem", 1, true) ~= nil
end

local function has_sni_at(service, path)
    local intro = shell_output(string.format("busctl --user introspect %q %q", service, path))
    if intro:find("StatusNotifierItem", 1, true) then
        return true
    end
    if path == "/StatusNotifierItem" and service_has_sni_path(service) then
        return true
    end
    return false
end

local function resolve_sni_service(bus)
    if service_has_sni_path(bus) then
        return bus
    end
end

local function proc_matches_scan(proc, scan)
    local proc_l = proc:lower()
    local sec_l = scan.secondary:lower()
    local pri_l = scan.primary:lower()
    if proc_l == sec_l or proc_l == pri_l then
        return true
    end
    if proc_l:find(sec_l, 1, true) or sec_l:find(proc_l, 1, true) then
        return true
    end
    if proc_l:find(pri_l, 1, true) then
        return true
    end
    return false
end

local function bus_matches_scan(bus, scan)
    local bus_l = bus:lower()
    local keys = {
        normalize_id(scan.secondary),
        normalize_id(scan.primary),
        scan.secondary:lower(),
        scan.primary:lower(),
    }

    for _, key in ipairs(keys) do
        if key ~= "" and bus_l:find(key, 1, true) then
            return true
        end
    end

    for token in scan.secondary:lower():gmatch("[%w]+") do
        if #token >= 5 and bus_l:find(token, 1, true) then
            return true
        end
    end

    for token in bus_l:gmatch("[%w]+") do
        if #token >= 5 and scan.secondary:lower():find(token, 1, true) then
            return true
        end
    end

    local app = scan.secondary:lower():match("^(%w+)_status")
    if app and #app >= 3 and bus_l:find(app, 1, true) then
        return true
    end

    return false
end

local function refresh_sni_map()
    cache.sni = {}
    if #cache.scan == 0 then
        return
    end

    local bus_lines = {}
    for line in shell_output("busctl --user list"):gmatch("[^\n]+") do
        bus_lines[#bus_lines + 1] = line
    end

    for _, scan in ipairs(cache.scan) do
        if skip_scan_entry(scan) then
            goto scan_continue
        end

        local service
        for _, line in ipairs(bus_lines) do
            local bus, _, proc = line:match("^(%S+)%s+(%d+)%s+(%S+)")
            if bus and proc and proc_matches_scan(proc, scan) then
                local candidate = resolve_sni_service(bus)
                if candidate then
                    service = candidate
                end
            end
        end

        if not service then
            for _, line in ipairs(bus_lines) do
                local bus = line:match("^(%S+)")
                if bus and bus_matches_scan(bus, scan) then
                    service = resolve_sni_service(bus)
                    if service then
                        break
                    end
                end
            end
        end

        if service then
            cache.sni[scan.secondary:lower()] = service
            cache.sni[normalize_id(scan.secondary)] = service
            for part in service:gmatch("[^%.]+") do
                cache.sni[part:lower()] = service
            end
        end

        ::scan_continue::
    end
end

local function item_score(item)
    local score = 0
    if item.service then
        score = score + 100
    end
    if item.menu_path then
        score = score + 50
    end
    if item.wm_class and not item.wm_class:lower():find("status_icon", 1, true) then
        score = score + 20
    end
    if item.tray_host and item.tray_host:lower() == "snixembed" then
        score = score - 40
    end
    if item.systray_index then
        score = score + item.systray_index
    end
    return score
end

local function is_pill_tray_app(scan)
    return not skip_scan_entry(scan)
end

local function find_service_for_scan(scan)
    local keys = {
        scan.secondary:lower(),
        scan.primary:lower(),
        normalize_id(scan.secondary),
        normalize_id(scan.primary),
    }

    for _, key in ipairs(keys) do
        if cache.sni[key] then
            return cache.sni[key]
        end
    end

    local best
    for line in shell_output("busctl --user list"):gmatch("[^\n]+") do
        local bus, _, proc = line:match("^(%S+)%s+(%d+)%s+(%S+)")
        if bus and proc and proc_matches_scan(proc, scan) then
            local candidate = resolve_sni_service(bus)
            if candidate then
                best = candidate
            end
        end
    end
    if best then
        return best
    end

    for line in shell_output("busctl --user list"):gmatch("[^\n]+") do
        local bus = line:match("^(%S+)")
        if bus and bus_matches_scan(bus, scan) then
            local candidate = resolve_sni_service(bus)
            if candidate then
                return candidate
            end
        end
    end
end

local function class_matches(item, class_name)
    if not class_name or class_name == "" then
        return false
    end
    class_name = class_name:lower()
    for _, candidate in ipairs(item.wm_classes or {}) do
        if candidate and candidate:lower() == class_name then
            return true
        end
    end
    if item.id and class_name:find(item.id, 1, true) then
        return true
    end
    return false
end

local function build_item_from_scan(scan, service)
    local title = scan.secondary
    if scan.name and scan.name ~= "" and scan.name:lower() ~= scan.secondary:lower() then
        title = scan.secondary
    end

    local id = normalize_id(scan.secondary)
    if SYSTEM_TRAY_IDS[id] then
        return nil
    end

    local item = {
        id = id,
        service = service,
        sni_path = service and find_sni_path(service) or "/StatusNotifierItem",
        menu_path = service and find_menu_path(service) or nil,
        title = title,
        id_prop = scan.secondary,
        wm_class = scan.secondary,
        wm_classes = {
            scan.secondary,
            scan.primary,
            scan.secondary:lower(),
            scan.primary:lower(),
        },
        systray_index = scan.index,
        embed_primary = scan.primary,
        tray_host = scan.name,
        launch = nil,
        quit = nil,
        icon_path = nil,
    }

    if service then
        local id_prop = bus_property(service, item.sni_path, "Id")
        local sni_title = bus_property(service, item.sni_path, "Title")
        if id_prop and id_prop ~= "" then
            item.id_prop = id_prop
            item.id = normalize_id(id_prop)
            item.wm_classes[#item.wm_classes + 1] = id_prop
        end
        if sni_title and sni_title ~= "" then
            item.title = sni_title
        end
        if not item.menu_path then
            item.menu_path = find_menu_path(service)
        end
    end

    item.launch = lookup_desktop_exec(item)
    local pid = service and service_pid(service)
    item.quit = pid and ("kill " .. pid) or ("pkill -fi " .. item.id_prop)

    if service then
        refresh_sni_icon(item)
    end

    if not item.icon_path then
        for _, name in ipairs({ item.id, item.id_prop, item.wm_class, item.title, item.icon_name }) do
            if name and name ~= "" then
                local path = menubar_utils.lookup_icon_uncached(name:lower())
                if path and path ~= false then
                    item.icon_path = path
                    break
                end
            end
        end
    end

    return item
end

local function merge_item(existing, incoming)
    if not existing then
        return incoming
    end

    local primary = item_score(incoming) > item_score(existing) and incoming or existing
    local secondary = primary == incoming and existing or incoming

    primary.icon_path = primary.icon_path or secondary.icon_path
    primary.service = primary.service or secondary.service
    primary.menu_path = primary.menu_path or secondary.menu_path
    primary.sni_path = primary.sni_path or secondary.sni_path
    primary.launch = primary.launch or secondary.launch
    primary.quit = primary.quit or secondary.quit

    if (secondary.systray_index or 0) > (primary.systray_index or 0) then
        primary.systray_index = secondary.systray_index
        primary.embed_primary = secondary.embed_primary or primary.embed_primary
        if secondary.tray_host and secondary.tray_host:lower() ~= "snixembed" then
            primary.wm_class = secondary.wm_class or primary.wm_class
            primary.tray_host = secondary.tray_host
        end
    end

    if primary.service and primary.sni_path then
        local id_prop = bus_property(primary.service, primary.sni_path, "Id")
        local sni_title = bus_property(primary.service, primary.sni_path, "Title")
        if id_prop and id_prop ~= "" then
            primary.id_prop = id_prop
            primary.id = normalize_id(id_prop)
        end
        if sni_title and sni_title ~= "" then
            primary.title = sni_title
        end
    end

    refresh_sni_icon(primary)

    return primary
end

function M.refresh(force)
    if not force and os.time() - cache.at < CACHE_TTL and #cache.items > 0 then
        return cache.items
    end

    refresh_scan()
    refresh_sni_map()

    local by_id = {}
    local by_service = {}

    for _, scan in ipairs(cache.scan) do
        if not skip_scan_entry(scan) then
            local service = find_service_for_scan(scan)
            local item = build_item_from_scan(scan, service)
            if item and is_pill_tray_app(scan) then
                local key = item.id
                if item.service and by_service[item.service] then
                    key = by_service[item.service]
                end
                by_id[key] = merge_item(by_id[key], item)
                if by_id[key].service then
                    by_service[by_id[key].service] = by_id[key].id
                end
            end
        end
    end

    local items = {}
    local final_by_id = {}
    for _, item in pairs(by_id) do
        items[#items + 1] = item
        final_by_id[item.id] = item
    end

    table.sort(items, function(a, b)
        return (a.systray_index or 0) < (b.systray_index or 0)
    end)

    cache.items = items
    cache.by_id = final_by_id
    cache.at = os.time()
    return items
end

function M.list()
    return M.refresh(false)
end

function M.refresh_icons()
    local changed = false
    for _, item in ipairs(cache.items) do
        if refresh_sni_icon(item) then
            changed = true
            cache.by_id[item.id] = item
        end
    end
    return changed
end

function M.get(id)
    M.refresh(false)
    return cache.by_id[id]
end

function M.is_running(item)
    if not item then
        return false
    end
    if item.service and service_on_bus(item.service) then
        return true
    end

    if os.time() - cache.at >= CACHE_TTL then
        refresh_scan()
    end

    for _, scan in ipairs(cache.scan) do
        if class_matches(item, scan.secondary) or class_matches(item, scan.primary) then
            return true
        end
    end

    if item.id_prop then
        return shell_output("pgrep -fi " .. item.id_prop .. " | head -1") ~= ""
    end

    return false
end

local function app_tokens(value)
    local tokens = {}
    local stop = {
        status = true,
        icon = true,
        desktop = true,
        client = true,
        snixembed = true,
        electron = true,
        unknown = true,
    }

    local function add(token)
        token = (token or ""):lower():gsub("[^%w]", "")
        if token and #token >= 3 and not stop[token] then
            tokens[token] = true
        end
    end

    value = (value or ""):lower()
    add(value:match("^(%w+)_status"))
    add(value:match("^(%w+)"))
    for part in value:gmatch("[%w]+") do
        add(part)
    end

    return tokens
end

local function tokens_overlap(left, right)
    for token in pairs(left) do
        if right[token] then
            return true
        end
    end
    return false
end

function M.set_match_items(items)
    match_items = items
end

function M.match_client(cl)
    if not cl or not cl.class then
        return nil
    end

    local cls = cl.class:lower()
    local cls_tokens = app_tokens(cl.class)
    local items = match_items or cache.items

    if #items == 0 then
        items = M.list()
    end

    for _, item in ipairs(items) do
        for _, candidate in ipairs(item.wm_classes or {}) do
            if candidate and candidate:lower() == cls then
                return item
            end
        end

        if cls == (item.service or ""):lower() then
            return item
        end

        local item_tokens = {}
        for _, name in ipairs({
            item.id,
            item.id_prop,
            item.wm_class,
            item.title,
            item.service,
            table.unpack(item.wm_classes or {}),
        }) do
            for token in pairs(app_tokens(name)) do
                item_tokens[token] = true
            end
        end

        if tokens_overlap(cls_tokens, item_tokens) then
            return item
        end
    end
end

function M.systray_index(item)
    if item and item.systray_index ~= nil then
        return item.systray_index
    end
    M.refresh(false)
    return item and item.systray_index or 0
end

return M
