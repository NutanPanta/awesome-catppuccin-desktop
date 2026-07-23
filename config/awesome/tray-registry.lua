-- Discover tray apps from systray embed scan + DBus SNI (no hardcoded app list).

local awful = require("awful")
local gears = require("gears")
local menubar_utils = require("menubar.utils")

local M = {}

local SCAN_SCRIPT = os.getenv("HOME") .. "/.config/awesome/scripts/tray-menu-scan.sh"
local CACHE_FILE = os.getenv("HOME") .. "/.cache/awesome/tray-registry.cache.lua"
local REFRESH_WORKER = os.getenv("HOME") .. "/.config/awesome/scripts/tray-registry-worker.sh"
local CACHE_TTL = 30

local match_items

local SYSTEM_TRAY_IDS = {
    pasystray = true,
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

local BUS_LIST_TTL = 8
local bus_list_cache = { at = 0, text = "", lines = {} }
local refresh_ctx
local bad_services = {}
local refresh_inflight = false
local refresh_pending_callbacks = {}
local refresh_pending_full = false
local running_cache = {}
local RUNNING_CACHE_TTL = 5

local BUSCTL_TIMEOUT_S = 1
local BAD_SERVICE_TTL_S = 180
local MAX_BUS_ATTEMPTS = 2

local function shell_output(cmd, timeout)
    timeout = timeout or 0
    if timeout > 0 then
        cmd = "timeout " .. timeout .. " " .. cmd
    end
    local handle = io.popen(cmd .. " 2>/dev/null")
    if not handle then
        return ""
    end
    local out = handle:read("*a") or ""
    handle:close()
    return out
end

local function is_bad_service(service)
    local until_t = bad_services[service]
    if not until_t then
        return false
    end
    if os.time() >= until_t then
        bad_services[service] = nil
        return false
    end
    return true
end

local function mark_bad_service(service)
    bad_services[service] = os.time() + BAD_SERVICE_TTL_S
end

local function get_bus_list_lines()
    if os.time() - bus_list_cache.at < BUS_LIST_TTL and #bus_list_cache.lines > 0 then
        return bus_list_cache.lines, bus_list_cache.text
    end

    local text = shell_output("busctl --user list")
    bus_list_cache.text = text
    bus_list_cache.lines = {}
    for line in text:gmatch("[^\n]+") do
        bus_list_cache.lines[#bus_list_cache.lines + 1] = line
    end
    bus_list_cache.at = os.time()
    return bus_list_cache.lines, bus_list_cache.text
end

local function begin_refresh_ctx(fast)
    refresh_ctx = { trees = {}, introspect = {}, fast = fast ~= false }
    get_bus_list_lines()
end

local function end_refresh_ctx()
    refresh_ctx = nil
end

local function get_bus_tree(service)
    if is_bad_service(service) then
        return ""
    end
    if refresh_ctx and refresh_ctx.trees[service] then
        return refresh_ctx.trees[service]
    end

    local tree = shell_output("busctl --user tree " .. service, BUSCTL_TIMEOUT_S)
    if tree == "" then
        mark_bad_service(service)
    end
    if refresh_ctx then
        refresh_ctx.trees[service] = tree
    end
    return tree
end

local function get_introspect(service, path)
    if is_bad_service(service) then
        return ""
    end
    local key = service .. "\0" .. path
    if refresh_ctx and refresh_ctx.introspect[key] then
        return refresh_ctx.introspect[key]
    end

    local intro = shell_output(string.format("busctl --user introspect %q %q", service, path), BUSCTL_TIMEOUT_S)
    if refresh_ctx then
        refresh_ctx.introspect[key] = intro
    end
    return intro
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
    ), BUSCTL_TIMEOUT_S))
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
    if not icon_name or icon_name == "" then
        return nil
    end

    if icon_name:sub(1, 1) == "/" and file_exists(icon_name) then
        return icon_name
    end

    if not theme_path or theme_path == "" then
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

    if theme_path and theme_path ~= "" and icon_name and icon_name ~= "" then
        local stem = icon_name:match("^([^%-]+)")
        if stem then
            local extra = {
                theme_path .. "/" .. stem .. ".png",
                theme_path .. "/" .. stem .. ".svg",
                theme_path .. "/" .. stem:sub(1, 1):upper() .. stem:sub(2) .. ".png",
                theme_path .. "/" .. stem:sub(1, 1):upper() .. stem:sub(2) .. ".svg",
            }
            for _, path in ipairs(extra) do
                if file_exists(path) then
                    return path
                end
            end
        end
    end
end

local FS_ICON_DIRS = {
    "/usr/share/icons/hicolor",
    (os.getenv("HOME") or "") .. "/.local/share/icons/hicolor",
}
local FS_ICON_SIZES = { "scalable", "48x48", "32x32", "24x24", "22x22", "16x16", "128x128" }
local FS_ICON_EXTS = { "svg", "png" }

local function icon_name_candidates(name)
    if not name or name == "" then
        return {}
    end

    local seen = {}
    local out = {}
    local function add(value)
        if value and value ~= "" then
            value = value:lower()
            if not seen[value] then
                seen[value] = true
                out[#out + 1] = value
            end
        end
    end

    add(name)
    local stem = name:gsub("%-symbolic$", "")
    if stem ~= name then
        add(stem)
    end
    if name:find("%.") then
        add(name:match("([^%.]+)$"))
    end

    return out
end

local function lookup_filesystem_icon(name)
    for _, candidate in ipairs(icon_name_candidates(name)) do
        for _, root in ipairs(FS_ICON_DIRS) do
            if root and root ~= "" then
                for _, size in ipairs(FS_ICON_SIZES) do
                    for _, ext in ipairs(FS_ICON_EXTS) do
                        local path = string.format("%s/%s/apps/%s.%s", root, size, candidate, ext)
                        if file_exists(path) then
                            return path
                        end
                    end
                end
            end
        end
    end
end

local function lookup_icon_name(icon_name, theme_path)
    if not icon_name or icon_name == "" then
        return nil
    end

    local path = resolve_theme_icon(theme_path, icon_name)
    if path then
        return path
    end

    local candidates = { icon_name:lower() }
    local stem = icon_name:gsub("%-symbolic$", "")
    if stem ~= icon_name then
        candidates[#candidates + 1] = stem:lower()
    end
    if icon_name:find("%.") then
        candidates[#candidates + 1] = icon_name:match("([^%.]+)$"):lower()
    end

    for _, name in ipairs(candidates) do
        local found = menubar_utils.lookup_icon_uncached(name)
        if found and found ~= false then
            return found
        end
        found = lookup_filesystem_icon(name)
        if found then
            return found
        end
    end
end

local function identity_tokens(item)
    local tokens = {}
    local seen = {}

    local function add(value)
        if value and value ~= "" then
            value = value:lower()
            if not seen[value] then
                seen[value] = true
                tokens[#tokens + 1] = value
            end
        end
    end

    for _, key in ipairs({ "id", "wm_class", "id_prop", "service" }) do
        add(item[key])
    end
    for _, value in ipairs(item.wm_classes or {}) do
        add(value)
    end

    return tokens
end

local function icon_belongs_to_item(path, item)
    if not path or not item then
        return false
    end

    local path_l = path:lower()
    for _, name in ipairs({
        item.id,
        item.id_prop,
        item.wm_class,
        item.icon_name,
        item.title,
    }) do
        if name and name ~= "" then
            local token = name:lower()
            if #token >= 4 and path_l:find(token, 1, true) then
                return true
            end
            local stem = token:match("([^%.]+)$")
            if stem and #stem >= 4 and path_l:find(stem, 1, true) then
                return true
            end
        end
    end

    for _, name in ipairs(item.wm_classes or {}) do
        if name and name ~= "" then
            local token = name:lower()
            if #token >= 4 and path_l:find(token, 1, true) then
                return true
            end
        end
    end

    return false
end

local function lookup_item_icon(item)
    if not item then
        return nil
    end

    if item.icon_path and file_exists(item.icon_path) then
        if icon_belongs_to_item(item.icon_path, item) then
            return item.icon_path
        end
        item.icon_path = nil
    end

    if item.icon_name and item.icon_name ~= "" then
        local path = lookup_icon_name(item.icon_name, item.icon_theme_path)
        if path then
            return path
        end
    end

    for _, name in ipairs({ item.icon_name, item.id_prop, item.wm_class, item.id, item.title }) do
        if name and name ~= "" then
            local path = menubar_utils.lookup_icon_uncached(name:lower())
            if path and path ~= false then
                return path
            end
            path = lookup_filesystem_icon(name)
            if path then
                return path
            end
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
        local path = lookup_icon_name(icon_name, theme_path)
        if path then
            item.icon_path = path
            return true
        end
    end

    local fallback = lookup_item_icon(item)
    if fallback then
        item.icon_path = fallback
        return true
    end

    return false
end

local function service_on_bus(service)
    if not service or service == "" then
        return false
    end
    if not service:match("^:") then
        return shell_output("busctl --user status " .. service, BUSCTL_TIMEOUT_S) ~= ""
    end
    local _, text = get_bus_list_lines()
    return text:find(service, 1, true) ~= nil
end

local function service_pid(service)
    for _, line in ipairs(get_bus_list_lines()) do
        local bus, pid = line:match("^(%S+)%s+(%d+)")
        if bus == service and pid then
            return tonumber(pid)
        end
    end
end

local function find_sni_path(service)
    local tree = get_bus_tree(service)
    local best
    local best_len = 0

    for line in tree:gmatch("[^\n]+") do
        local path = line:match("(%S+)$")
        if path and path:sub(1, 1) == "/" then
            local ok = (path:find("StatusNotifierItem", 1, true)
                or path:find("NotificationItem", 1, true))
                and not path:find("Menu", 1, true)
                and not path:find("Watcher", 1, true)
            if ok and #path > best_len then
                best = path
                best_len = #path
            end
        end
    end

    if best then
        return best
    end

    if tree:find("/StatusNotifierItem", 1, true) then
        return "/StatusNotifierItem"
    end

    return nil
end

local function find_menu_path(service)
    local tree = get_bus_tree(service)
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
        local intro = get_introspect(service, path)
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

    local handle = io.popen("timeout 2 " .. SCAN_SCRIPT .. " 2>/dev/null")
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

local function skip_duplicate_embed(scan)
    for _, other in ipairs(cache.scan) do
        if other == scan then
            goto continue
        end
        if other.secondary:lower() ~= scan.secondary:lower() then
            goto continue
        end
        if (other.index or 999) < (scan.index or 999) then
            return true
        end
        ::continue::
    end
    return false
end

local function skip_scan_entry(scan)
    local secondary = normalize_id(scan.secondary)
    local primary = normalize_id(scan.primary)
    local name = (scan.name or ""):lower()

    if SYSTEM_TRAY_IDS[secondary] or SYSTEM_TRAY_IDS[primary] then
        return true
    end
    -- Hidden Electron tray embeds; show the real app window instead.
    if scan.primary:find("status_icon", 1, true)
        or scan.secondary:find("status_icon", 1, true)
    then
        return true
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
    if skip_duplicate_embed(scan) then
        return true
    end
    return false
end

local function service_has_sni_path(service)
    local tree = get_bus_tree(service)
    return tree:find("/StatusNotifierItem", 1, true) ~= nil
        or tree:find("NotificationItem", 1, true) ~= nil
end

local function has_sni_at(service, path)
    local intro = get_introspect(service, path)
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

    local bus_lines = get_bus_list_lines()

    for _, scan in ipairs(cache.scan) do
        if skip_scan_entry(scan) then
            goto scan_continue
        end

        local service
        local attempts = 0
        for _, line in ipairs(bus_lines) do
            local bus, _, proc = line:match("^(%S+)%s+(%d+)%s+(%S+)")
            if bus and proc and proc_matches_scan(proc, scan) then
                if not is_bad_service(bus) then
                    attempts = attempts + 1
                    local candidate = resolve_sni_service(bus)
                    if candidate then
                        service = candidate
                        break
                    end
                    if attempts >= MAX_BUS_ATTEMPTS then
                        break
                    end
                end
            end
        end

        if not service then
            attempts = 0
            for _, line in ipairs(bus_lines) do
                local bus = line:match("^(%S+)")
                if bus and bus_matches_scan(bus, scan) then
                    if is_bad_service(bus) then
                        goto bus_continue
                    end
                    attempts = attempts + 1
                    service = resolve_sni_service(bus)
                    if service then
                        break
                    end
                    if attempts >= MAX_BUS_ATTEMPTS then
                        break
                    end
                end
                ::bus_continue::
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

local function attach_embed_metadata(item)
    if not item or item.systray_index ~= nil then
        return item
    end

    local candidates = {
        item.id,
        item.wm_class,
        item.id_prop,
    }

    for _, scan in ipairs(cache.scan) do
        local sec = scan.secondary:lower()
        local pri = scan.primary:lower()
        if not sec:find("status_icon", 1, true) and not pri:find("status_icon", 1, true) then
            goto scan_continue
        end

        local token = sec:match("^(%w+)_status_icon") or pri:match("^(%w+)_status_icon")
        if not token or #token < 3 then
            goto scan_continue
        end

        for _, candidate in ipairs(candidates) do
            if candidate and candidate:lower():find(token, 1, true) then
                item.systray_index = scan.index
                item.embed_primary = scan.primary
                item.tray_host = scan.name or item.tray_host
                item.wm_classes = item.wm_classes or {}
                item.wm_classes[#item.wm_classes + 1] = scan.secondary
                item.wm_classes[#item.wm_classes + 1] = scan.primary
                return item
            end
        end
        ::scan_continue::
    end

    return item
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
    local attempts = 0
    for _, line in ipairs(get_bus_list_lines()) do
        local bus, _, proc = line:match("^(%S+)%s+(%d+)%s+(%S+)")
        if bus and is_bad_service(bus) then
            goto find_continue
        end
        if bus and proc and proc_matches_scan(proc, scan) then
            attempts = attempts + 1
            local candidate = resolve_sni_service(bus)
            if candidate then
                best = candidate
                break
            end
        elseif bus and bus_matches_scan(bus, scan) then
            attempts = attempts + 1
            local candidate = resolve_sni_service(bus)
            if candidate then
                best = candidate
                break
            end
        end
        if attempts >= MAX_BUS_ATTEMPTS then
            break
        end
        ::find_continue::
    end
    return best
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
        sni_path = nil,
        menu_path = nil,
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

    local fast = refresh_ctx and refresh_ctx.fast

    if service then
        item.sni_path = find_sni_path(service) or "/StatusNotifierItem"
        refresh_sni_icon(item)
    end

    if service and not fast then
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
        item.menu_path = find_menu_path(service)
    end

    item.launch = lookup_desktop_exec(item)
    if service and not fast then
        local pid = service_pid(service)
        item.quit = pid and ("kill " .. pid) or ("pkill -fi " .. item.id_prop)
    else
        item.quit = "pkill -fi " .. item.id_prop
    end

    if not item.icon_path then
        item.icon_path = lookup_item_icon(item)
    end

    return item
end

local function tray_identity_relates(a, b)
    if not a or not b then
        return false
    end
    if a.id and b.id and a.id == b.id then
        return true
    end

    local left_tokens = identity_tokens(a)
    local right_tokens = identity_tokens(b)

    for _, left in ipairs(left_tokens) do
        for _, right in ipairs(right_tokens) do
            if left == right then
                return true
            end
            if #left >= 4 and right:find(left, 1, true) then
                return true
            end
            if #right >= 4 and left:find(right, 1, true) then
                return true
            end
        end
    end

    return false
end

local function canonical_tray_id(item)
    local best
    for _, name in ipairs({ item.wm_class, item.id_prop, item.id }) do
        if name and name ~= "" then
            local id = normalize_id(name)
            if id ~= "tray-item" and not id:find("status", 1, true) then
                if not best or #id < #best then
                    best = id
                end
            end
        end
    end
    return best or item.id or "tray-item"
end

local function merge_item(existing, incoming)
    if not existing then
        return incoming
    end

    local primary = item_score(incoming) > item_score(existing) and incoming or existing
    local secondary = primary == incoming and existing or incoming

    primary.icon_path = primary.icon_path or (
        secondary.icon_path and icon_belongs_to_item(secondary.icon_path, secondary) and secondary.icon_path
    )
    primary.service = primary.service or secondary.service
    primary.menu_path = primary.menu_path or secondary.menu_path
    primary.sni_path = primary.sni_path or secondary.sni_path
    primary.launch = primary.launch or secondary.launch
    primary.quit = primary.quit or secondary.quit
    primary.wm_class = primary.wm_class or secondary.wm_class
    primary.id_prop = primary.id_prop or secondary.id_prop

    if primary.systray_index == nil and secondary.systray_index ~= nil then
        primary.systray_index = secondary.systray_index
        primary.embed_primary = secondary.embed_primary or primary.embed_primary
        if secondary.tray_host and secondary.tray_host:lower() ~= "snixembed" then
            primary.wm_class = secondary.wm_class or primary.wm_class
            primary.tray_host = secondary.tray_host
        end
    end

    if primary.service and primary.sni_path and not (refresh_ctx and refresh_ctx.fast) then
        local id_prop = bus_property(primary.service, primary.sni_path, "Id")
        local sni_title = bus_property(primary.service, primary.sni_path, "Title")
        if id_prop and id_prop ~= "" then
            primary.id_prop = id_prop
            primary.id = normalize_id(id_prop)
        end
        if sni_title and sni_title ~= "" then
            primary.title = sni_title
        end
        refresh_sni_icon(primary)
    end

    if not primary.icon_path then
        primary.icon_path = lookup_item_icon(primary)
    end

    return primary
end

local function dedupe_tray_items(items)
    local merged = {}

    for _, item in ipairs(items) do
        local target_key
        for key, existing in pairs(merged) do
            if tray_identity_relates(existing, item) then
                target_key = key
                merged[key] = merge_item(existing, item)
                break
            end
        end
        if not target_key then
            merged[item.id] = item
        end
    end

    local result = {}
    local final_by_id = {}
    for _, item in pairs(merged) do
        item.id = canonical_tray_id(item)
        result[#result + 1] = item
        final_by_id[item.id] = item
    end

    local compact = {}
    for _, item in ipairs(result) do
        local target_key
        for key, existing in pairs(compact) do
            if tray_identity_relates(existing, item) then
                target_key = key
                compact[key] = merge_item(existing, item)
                compact[key].id = canonical_tray_id(compact[key])
                break
            end
        end
        if not target_key then
            compact[item.id] = item
        end
    end

    result = {}
    final_by_id = {}
    for _, item in pairs(compact) do
        item.id = canonical_tray_id(item)
        result[#result + 1] = item
        final_by_id[item.id] = item
    end

    table.sort(result, function(a, b)
        return (a.systray_index or 999) < (b.systray_index or 999)
    end)

    return result, final_by_id
end

local function sni_id_from_service(service)
    return service:match("^org%.kde%.StatusNotifierItem%-(.-)%-%d+$")
end

local DBUS_PROC_SKIP_PATTERNS = {
    "status_icon",
    "portal",
    "polkit",
    "power%-manager",
    "snixembed",
    "nm%-applet",
    "pasystray",
    "xfce4%-power",
    "copyq",
}

local function skip_dbus_proc(proc)
    local proc_l = (proc or ""):lower()
    if proc_l == "" then
        return true
    end
    for _, pattern in ipairs(DBUS_PROC_SKIP_PATTERNS) do
        if proc_l:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

local function skip_dbus_id(id, id_prop)
    local text = ((id or "") .. " " .. (id_prop or "")):lower()
    if text:find("status_icon", 1, true) then
        return true
    end
    for _, pattern in ipairs(DBUS_PROC_SKIP_PATTERNS) do
        if text:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

local function skip_dbus_service(service, proc)
    if not service or service == "" or is_bad_service(service) then
        return true
    end
    if skip_dbus_proc(proc) then
        return true
    end
    local service_l = service:lower()
    if service_l:find("mpris", 1, true) then
        return true
    end
    if service_l:find("portal", 1, true)
        or service_l:find("polkit", 1, true)
        or service_l:find("power%-manager", 1, true)
    then
        return true
    end
    return false
end

local function build_item_from_service(service, proc)
    if skip_dbus_service(service, proc) or not service_has_sni_path(service) then
        return nil
    end

    local sni_path = find_sni_path(service)
    if not sni_path then
        return nil
    end

    local fast = refresh_ctx and refresh_ctx.fast
    local id_prop = sni_id_from_service(service)
    if not id_prop and not fast then
        id_prop = bus_property(service, sni_path, "Id")
    end

    if id_prop and id_prop:lower():find("status_icon", 1, true) then
        if proc and not skip_dbus_proc(proc) and not id_prop:lower():find(proc:lower(), 1, true) then
            id_prop = proc
        else
            return nil
        end
    end

    if (not id_prop or id_prop == "") and proc and not skip_dbus_proc(proc) then
        id_prop = proc
    end

    local wm_class = id_prop or service:match("([^%.]+)$") or service
    local id = normalize_id(id_prop or wm_class)

    if id:match("^%d+$") then
        if proc and not skip_dbus_proc(proc) then
            id_prop = proc
            wm_class = proc
            id = normalize_id(proc)
        else
            return nil
        end
    end

    if SYSTEM_TRAY_IDS[id] or SYSTEM_TRAY_IDS[normalize_id(wm_class)] then
        return nil
    end
    if skip_dbus_id(id, id_prop) then
        return nil
    end

    local GENERIC_IDS = { main = true, unknown = true }
    if GENERIC_IDS[id] or GENERIC_IDS[normalize_id(wm_class or "")] then
        local sni_id = (not id_prop or id_prop == "" or GENERIC_IDS[normalize_id(id_prop)])
            and bus_property(service, sni_path, "Id")
            or id_prop
        if sni_id and sni_id ~= "" and not GENERIC_IDS[normalize_id(sni_id)] then
            id_prop = sni_id
            wm_class = sni_id
            id = normalize_id(sni_id)
        elseif not fast then
            if not service:match("^:") then
                local token = service:match("([^%.]+)$")
                if token and not GENERIC_IDS[normalize_id(token)] then
                    id_prop = token
                    wm_class = token
                    id = normalize_id(token)
                else
                    return nil
                end
            else
                return nil
            end
        elseif not service:match("^:") then
            local token = service:match("([^%.]+)$")
            if token and not GENERIC_IDS[normalize_id(token)] then
                id_prop = token
                wm_class = token
                id = normalize_id(token)
            else
                return nil
            end
        else
            return nil
        end
    end

    local sni_title = not fast and bus_property(service, sni_path, "Title") or nil

    local item = {
        id = id,
        service = service,
        sni_path = sni_path,
        menu_path = nil,
        title = sni_title or wm_class,
        id_prop = id_prop or wm_class,
        wm_class = wm_class,
        wm_classes = { wm_class, wm_class:lower(), id, id_prop or "" },
        systray_index = nil,
        embed_primary = nil,
        tray_host = "dbus",
        launch = nil,
        quit = nil,
        icon_path = nil,
    }

    if not fast then
        item.menu_path = find_menu_path(service)
        refresh_sni_icon(item)
        local pid = service_pid(service)
        item.quit = pid and ("kill " .. pid) or ("pkill -fi " .. item.id_prop)
    else
        item.quit = "pkill -fi " .. item.id_prop
        refresh_sni_icon(item)
    end

    item.launch = lookup_desktop_exec(item)
    return item
end

local function refresh_dbus_items(by_id, by_service)
    local covered = {}
    local seen_tray = {}
    for _, item in pairs(by_id) do
        if item.service then
            covered[item.service] = true
        end
    end

    for _, line in ipairs(get_bus_list_lines()) do
        local bus, pid, proc = line:match("^(%S+)%s+(%d+)%s+(%S+)")
        if not bus or covered[bus] or skip_dbus_service(bus, proc) then
            goto continue
        end
        if bus:match("^:") and proc and proc:lower() == "main" then
            goto continue
        end
        if not service_has_sni_path(bus) then
            goto continue
        end

        local tray_key = (pid or "") .. ":" .. (proc or "")
        if tray_key ~= ":" and seen_tray[tray_key] then
            covered[bus] = true
            goto continue
        end

        local item = build_item_from_service(bus, proc)
        if item then
            if tray_key ~= ":" then
                seen_tray[tray_key] = item.id
            end
            local key = item.id
            if item.service and by_service[item.service] then
                key = by_service[item.service]
            end
            if by_id[key] then
                by_id[key] = merge_item(by_id[key], item)
                if by_id[key].service then
                    covered[by_id[key].service] = true
                end
                goto continue
            end
            by_id[key] = merge_item(by_id[key], item)
            if by_id[key].service then
                by_service[by_id[key].service] = by_id[key].id
                covered[by_id[key].service] = true
            end
        end
        ::continue::
    end
end

function M.refresh(force, full)
    if not force and os.time() - cache.at < CACHE_TTL and #cache.items > 0 then
        return cache.items
    end

    begin_refresh_ctx(full ~= true)
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

    refresh_dbus_items(by_id, by_service)

    for key, item in pairs(by_id) do
        by_id[key] = attach_embed_metadata(item)
    end

    local items = {}
    local final_by_id = {}
    for _, item in pairs(by_id) do
        items[#items + 1] = item
    end

    items, final_by_id = dedupe_tray_items(items)

    cache.items = items
    cache.by_id = final_by_id
    cache.at = os.time()
    end_refresh_ctx()
    return items
end

function M.cache_file_path()
    return CACHE_FILE
end

local function apply_cache_data(data)
    if type(data) ~= "table" or type(data.items) ~= "table" then
        return false
    end

    cache.items = data.items
    cache.by_id = {}
    for _, item in ipairs(cache.items) do
        if item and item.id then
            cache.by_id[item.id] = item
        end
    end
    cache.at = tonumber(data.at) or os.time()
    return true
end

local function write_cache_table(path, data)
    local dir = path:match("^(.*)/")
    if dir and dir ~= "" then
        os.execute("mkdir -p " .. string.format("%q", dir))
    end

    local tmp = path .. ".writing"
    local file = io.open(tmp, "w")
    if not file then
        return false
    end

    file:write("return {\n")
    file:write("  at = ", cache.at, ",\n")
    file:write("  items = {\n")

    for _, item in ipairs(data.items or {}) do
        file:write("    {\n")
        local fields = {
            "id", "service", "sni_path", "menu_path", "title", "id_prop",
            "wm_class", "embed_primary", "tray_host", "launch", "quit", "icon_path",
        }
        for _, key in ipairs(fields) do
            local value = item[key]
            if value ~= nil and value ~= "" then
                file:write("      ", key, " = ", string.format("%q", tostring(value)), ",\n")
            end
        end
        if item.systray_index ~= nil then
            file:write("      systray_index = ", item.systray_index, ",\n")
        end
        if type(item.wm_classes) == "table" and #item.wm_classes > 0 then
            file:write("      wm_classes = {")
            for index, value in ipairs(item.wm_classes) do
                if index > 1 then
                    file:write(", ")
                end
                file:write(string.format("%q", tostring(value)))
            end
            file:write("},\n")
        end
        file:write("    },\n")
    end

    file:write("  },\n")
    file:write("}\n")
    file:close()
    os.rename(tmp, path)
    return true
end

function M.write_cache_file(path)
    path = path or CACHE_FILE
    return write_cache_table(path, {
        items = cache.items,
        at = cache.at,
    })
end

function M.load_cache_from_file(path)
    path = path or CACHE_FILE
    local chunk, err = loadfile(path)
    if not chunk then
        return false
    end

    local ok, data = pcall(chunk)
    if not ok or not apply_cache_data(data) then
        return false
    end
    return true
end

function M.list()
    if #cache.items == 0 and not refresh_inflight then
        M.refresh_async(nil, false)
    end
    return cache.items
end

function M.is_refreshing()
    return refresh_inflight
end

local function finish_refresh_worker(callbacks)
    refresh_inflight = false
    for _, callback in ipairs(callbacks or {}) do
        if callback then
            pcall(callback, cache.items)
        end
    end
    if #refresh_pending_callbacks > 0 or refresh_pending_full then
        M.refresh_async(nil, refresh_pending_full)
    end
end

local function start_refresh_worker()
    refresh_inflight = true
    local mode = refresh_pending_full and "full" or "fast"
    local callbacks = refresh_pending_callbacks
    refresh_pending_callbacks = {}
    refresh_pending_full = false

    awful.spawn.easy_async_with_shell(
        string.format("%q %q %s", REFRESH_WORKER, CACHE_FILE, mode),
        function(_, _, _, exit_code)
            if exit_code == 0 then
                M.load_cache_from_file(CACHE_FILE)
            end
            finish_refresh_worker(callbacks)
        end
    )
end

function M.refresh_async(callback, full)
    if callback then
        refresh_pending_callbacks[#refresh_pending_callbacks + 1] = callback
    end
    if full then
        refresh_pending_full = true
    end
    if refresh_inflight then
        return
    end
    start_refresh_worker()
end

local function clean_tray_title(value)
    if type(value) ~= "string" then
        return nil
    end
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub('^"(.*)"$', "%1")
    if value == "" or not value:match("%S") then
        return nil
    end
    return value
end

function M.items_relate(a, b)
    return tray_identity_relates(a, b)
end

function M.lookup_icon_name(icon_name, theme_path)
    return lookup_icon_name(icon_name, theme_path)
end

function M.resolve_item_icon(item, force)
    if not item then
        return nil
    end
    if force and item.service and item.sni_path then
        refresh_sni_icon(item)
    end
    return lookup_item_icon(item)
end

function M.enrich_item(item)
    if not item or not item.service or item._enriched then
        return item
    end

    if is_bad_service(item.service) then
        item._enriched = true
        return item
    end

    item.sni_path = find_sni_path(item.service)
    local id_prop = bus_property(item.service, item.sni_path, "Id")
    local sni_title = clean_tray_title(bus_property(item.service, item.sni_path, "Title"))
    if id_prop and id_prop:lower():find("status_icon", 1, true) then
        for _, line in ipairs(get_bus_list_lines()) do
            local bus, _, proc = line:match("^(%S+)%s+(%d+)%s+(%S+)")
            if bus == item.service and proc and not skip_dbus_proc(proc)
                and not id_prop:lower():find(proc:lower(), 1, true)
            then
                id_prop = proc
                break
            end
        end
        if id_prop:lower():find("status_icon", 1, true)
            and item.wm_class and not item.wm_class:lower():find("status_icon", 1, true)
        then
            id_prop = item.wm_class
        end
    end
    if id_prop and id_prop ~= "" then
        item.id_prop = id_prop
        item.id = normalize_id(id_prop)
    end
    if sni_title then
        item.title = sni_title
    end
    item.menu_path = find_menu_path(item.service)
    refresh_sni_icon(item)

    local pid = service_pid(item.service)
    if pid then
        item.quit = "kill " .. pid
    end

    item._enriched = true
    item = attach_embed_metadata(item)
    if cache.by_id[item.id] then
        cache.by_id[item.id] = item
    end
    return item
end

function M.attach_embed_metadata(item)
    return attach_embed_metadata(item)
end

function M.cached_items()
    if #cache.items > 0 then
        return cache.items
    end
    return {}
end

function M.is_stale()
    return #cache.items == 0 or os.time() - cache.at >= CACHE_TTL
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
    if not id then
        return nil
    end
    if cache.by_id[id] then
        return cache.by_id[id]
    end
    if #cache.items == 0 and not refresh_inflight then
        M.refresh_async(nil, false)
    end
    return cache.by_id[id]
end

function M.is_running(item)
    if not item then
        return false
    end

    local cache_key = item.id or item.service or item.id_prop
    if cache_key then
        local cached = running_cache[cache_key]
        if cached and os.time() - cached.at < RUNNING_CACHE_TTL then
            return cached.value
        end
    end

    local result = false
    if item.service and service_on_bus(item.service) then
        result = true
    else
        for _, scan in ipairs(cache.scan) do
            if class_matches(item, scan.secondary) or class_matches(item, scan.primary) then
                result = true
                break
            end
        end

        if not result and item.id_prop then
            result = shell_output("pgrep -fx " .. item.id_prop .. " | head -1") ~= ""
        end
    end

    if cache_key then
        running_cache[cache_key] = { at = os.time(), value = result }
    end
    return result
end

function M.show_tray_only(item)
    if not item or not M.is_running(item) then
        return false
    end
    if item.systray_index ~= nil then
        return true
    end
    return item.tray_host == "dbus" and item.service ~= nil
end

function M.set_match_items(items)
    match_items = items
end

local function name_tokens(value)
    local tokens = {}
    local seen = {}
    for token in (value or ""):lower():gmatch("[%w]+") do
        if #token >= 4 and not seen[token] then
            seen[token] = true
            tokens[#tokens + 1] = token
        end
    end
    return tokens
end

local function names_relate(a, b)
    if not a or not b or a == "" or b == "" then
        return false
    end

    a = a:lower()
    b = b:lower()
    if a == b then
        return true
    end

    local min_len = 4
    if #a >= min_len and b:find(a, 1, true) then
        return true
    end
    if #b >= min_len and a:find(b, 1, true) then
        return true
    end

    for _, ta in ipairs(name_tokens(a)) do
        for _, tb in ipairs(name_tokens(b)) do
            if ta == tb then
                return true
            end
            if #ta >= 5 and tb:find(ta, 1, true) then
                return true
            end
            if #tb >= 5 and ta:find(tb, 1, true) then
                return true
            end
        end
    end
    return false
end

function M.match_client(cl, allow_refresh)
    if not cl or not cl.class then
        return nil
    end

    local cls = cl.class:lower()
    local items = match_items or cache.items

    if #items == 0 and allow_refresh ~= false and not refresh_inflight then
        M.refresh_async(nil, false)
    end

    if #items == 0 then
        return nil
    end

    for _, item in ipairs(items) do
        if item.wm_class and item.wm_class:lower() == cls then
            return item
        end

        if item.id_prop and item.id_prop:lower() == cls then
            return item
        end

        if item.wm_class and names_relate(item.wm_class, cls) then
            return item
        end

        if item.id_prop and names_relate(item.id_prop, cls) then
            return item
        end

        if item.id and names_relate(item.id, cls) then
            return item
        end

        for _, candidate in ipairs(item.wm_classes or {}) do
            if candidate and names_relate(candidate, cls) then
                return item
            end
        end
    end

    return nil
end

function M.item_for_app(app_name)
    if not app_name or app_name == "" then
        return nil
    end

    local function item_matches(item)
        if item.id and names_relate(item.id, app_name) then
            return true
        end
        if item.wm_class and names_relate(item.wm_class, app_name) then
            return true
        end
        if item.id_prop and names_relate(item.id_prop, app_name) then
            return true
        end
        for _, candidate in ipairs(item.wm_classes or {}) do
            if candidate and names_relate(candidate, app_name) then
                return true
            end
        end
        return false
    end

    if #cache.items == 0 and not refresh_inflight then
        M.refresh_async(nil, false)
    end

    for _, item in ipairs(cache.items) do
        if item_matches(item) then
            return item
        end
    end

    if M.is_stale() and not refresh_inflight then
        M.refresh_async(nil, false)
    end

    for _, scan in ipairs(cache.scan) do
        if skip_scan_entry(scan) then
            goto scan_continue
        end
        if names_relate(scan.secondary, app_name) or names_relate(scan.primary, app_name) then
            local service = find_service_for_scan(scan)
            return build_item_from_scan(scan, service)
        end
        ::scan_continue::
    end

    return nil
end

function M.systray_index(item)
    if item and item.systray_index ~= nil then
        return item.systray_index
    end
    if item and M.is_stale() and not refresh_inflight then
        M.refresh_async(nil, false)
    end
    return item and item.systray_index or 0
end

M.load_cache_from_file()

return M
