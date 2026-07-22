#!/usr/bin/env bash
# Verify taskbar pill logic against the live Awesome session.
set -euo pipefail

PILL="${HOME}/.config/awesome/taskbar-pill.lua"
REGISTRY="${HOME}/.config/awesome/tray-registry.lua"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "OK: $*"
}

[[ -f "$PILL" ]] || fail "missing $PILL"
[[ -f "$REGISTRY" ]] || fail "missing $REGISTRY"

grep -q 'include_client(cl, true)' "$PILL" \
    || fail "refresh_apps still excludes tray windows (expected include_client(cl, true))"
grep -q 'matched_tray_ids' "$PILL" \
    || fail "refresh_apps should track tray-matched windows separately"
grep -q 'refresh_dbus_items' "$REGISTRY" \
    || fail "missing DBus-only tray discovery"

if ! command -v awesome-client >/dev/null 2>&1; then
    fail "awesome-client not available"
fi

result="$(awesome-client 2>&1 <<'LUA' | tail -1 | sed 's/^   string "//; s/"$//'
package.loaded["tray-registry"] = nil
package.loaded["tray-menu"] = nil
local tray_registry = require("tray-registry")
tray_registry.refresh(true, false)
local tray_items = tray_registry.cached_items()
tray_registry.set_match_items(tray_items)

local     skip = {
    plank = true, polybar = true, awesome = true, picom = true,
    xfdesktop = true,
    ["blueman-manager"] = true,
}

local function include_client(cl, fast)
    if not cl.valid or not cl.class or cl.class == "" then return false end
    if cl.type == "desktop" or cl.type == "dock" then return false end
    if skip[cl.class:lower()] then return false end
    if cl.name and cl.name:lower():find("polybar", 1, true) then return false end
    if fast then
        local cls = (cl.class or ""):lower()
        if cls:find("status_icon", 1, true) or cls == "snixembed" then return false end
        local w, h = cl.width, cl.height
        if w and h and w > 0 and h > 0 and w <= 64 and h <= 64 then return false end
    end
    return true
end

local lines = {}
local matched_tray_ids = {}
local matched_tray_items = {}
local shown_tray_only = {}

for _, cl in ipairs(client.get()) do
    if not include_client(cl, true) then goto cont end
    local item = tray_registry.match_client(cl, false)
    if item then
        matched_tray_ids[item.id] = (matched_tray_ids[item.id] or 0) + 1
        matched_tray_items[item.id] = item
        lines[#lines + 1] = "CLIENT-TRAY " .. item.id .. " (" .. cl.class .. ")"
    else
        lines[#lines + 1] = "CLIENT " .. cl.class
    end
    ::cont::
end

for _, item in ipairs(tray_items) do
    if matched_tray_ids[item.id] then goto cont2 end
    for _, shown in ipairs(shown_tray_only) do
        if tray_registry.items_relate(item, shown) then goto cont2 end
    end
    if tray_registry.show_tray_only(item) then
        shown_tray_only[#shown_tray_only + 1] = item
        lines[#lines + 1] = "TRAY-ONLY " .. item.id
    end
    ::cont2::
end

local tray_only_seen = {}
for _, line in ipairs(lines) do
    if line:match("^TRAY%-ONLY ") then
        local id = line:match("^TRAY%-ONLY ([%w%-]+)")
        if id then
            for seen_id in pairs(tray_only_seen) do
                if tray_registry.items_relate({ id = id }, { id = seen_id }) then
                    return "DUPLICATE-TRAY-ID " .. id .. "+" .. seen_id
                end
            end
            if tray_only_seen[id] then
                return "DUPLICATE-TRAY-ID " .. id
            end
            tray_only_seen[id] = true
        end
    end
end

local tray_menu = require("tray-menu")

local function shell_line(cmd)
    local handle = io.popen(cmd .. " 2>/dev/null")
    if not handle then
        return ""
    end
    local out = handle:read("*a") or ""
    handle:close()
    return out
end

local function proc_running(name, exec_pat)
    if shell_line("pgrep -x " .. name .. " | head -1"):match("%S") then
        return true
    end
    if exec_pat then
        return shell_line("pgrep -af " .. exec_pat .. " | grep -v pgrep | head -1"):match("%S") ~= nil
    end
    return shell_line("pgrep -x " .. name:lower() .. " | head -1"):match("%S") ~= nil
end

local function add_menu_line(label, item)
    local kind, detail = tray_menu.inspect_menu(item)
    lines[#lines + 1] = string.format("MENU %s kind=%s detail=%s", label, kind, tostring(detail))
end

local menu_labels = {}
for id, item in pairs(matched_tray_items) do
    if not menu_labels[id] then
        add_menu_line(id, item)
        menu_labels[id] = true
    end
end
for _, line in ipairs(lines) do
    if not line:match("^TRAY%-ONLY ") then goto menu_continue end
    local id = line:match("^TRAY%-ONLY ([%w%-]+)")
    local item = nil
    for _, candidate in ipairs(tray_items) do
        if candidate.id == id then
            item = candidate
            break
        end
    end
    if item and not menu_labels[id] then
        add_menu_line(id, item)
        menu_labels[id] = true
    end
    ::menu_continue::
end

local WATCH = {
    { key = "postman", proc = "postman", exec_pat = "Postman" },
    { key = "claude", proc = "Claude", exec_pat = "/Claude" },
    { key = "cursor", proc = "cursor", exec_pat = "/usr/.*/cursor" },
}

for _, watch in ipairs(WATCH) do
    if menu_labels[watch.key] then
        goto watch_continue
    end
    if not proc_running(watch.proc, watch.exec_pat) then
        lines[#lines + 1] = string.format("MENU %s kind=skipped detail=not-running", watch.key)
        menu_labels[watch.key] = true
        goto watch_continue
    end
    local item = tray_registry.item_for_app(watch.key)
    if item then
        add_menu_line(watch.key, item)
        menu_labels[watch.key] = true
    else
        lines[#lines + 1] = string.format("MENU %s kind=missing detail=no-tray-item", watch.key)
        menu_labels[watch.key] = true
    end
    ::watch_continue::
end

return table.concat(lines, "|")
LUA
)"

if [[ "$result" == DUPLICATE-TRAY-ID* ]]; then
    fail "$result"
fi

echo "${result//|/$'\n'}" | grep -v '^MENU ' || true
echo
menu_lines="$(echo "${result//|/$'\n'}" | grep '^MENU ' || true)"
if [[ -z "$menu_lines" ]]; then
    pass "no tray apps in pill to inspect menus"
else
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        id="${line#MENU }"
        id="${id%% kind=*}"
        kind="${line#*kind=}"
        kind="${kind%% detail=*}"
        detail="${line#*detail=}"
        case "$kind" in
            dbus)
                pass "${id} menu=dbus (${detail} items)"
                ;;
            embed)
                pass "${id} menu=embed (systray index ${detail})"
                ;;
            sni)
                pass "${id} menu=sni (ContextMenu via DBus)"
                ;;
            fallback)
                pass "${id} menu=fallback (default Open/Quit only)"
                ;;
            missing)
                pass "${id} menu=missing (running, no tray item in registry/scan)"
                ;;
            skipped)
                pass "${id} not running (menu check skipped)"
                ;;
            *)
                fail "${id} menu=unknown (${kind}, detail=${detail})"
                ;;
        esac
    done <<<"$menu_lines"
fi
echo
pass "simulated pill entries (no duplicates)"
if [[ "$result" == *"CLIENT-TRAY hubstaff"* ]] && [[ "$result" != *"TRAY-ONLY hubstaff"* ]]; then
    pass "hubstaff window shown with tray menu available"
else
    fail "hubstaff tray layout unexpected: $result"
fi
if [[ "$result" == *"CLIENT-TRAY spotify-client"* ]] && [[ "$result" != *"TRAY-ONLY spotify-client"* ]]; then
    pass "spotify window shown with tray menu available"
elif [[ "$result" != *"spotify"* ]]; then
    pass "spotify not running (skipped)"
else
    fail "spotify tray layout unexpected: $result"
fi
if pgrep -x blueman-applet >/dev/null 2>&1; then
    if [[ "$result" == *"blueman"* ]] || [[ "$result" == *"TRAY-ONLY blueman"* ]]; then
        pass "blueman tray visible in pill while applet is running"
    else
        fail "blueman-applet is running but missing from pill: $result"
    fi
else
    pass "blueman-applet not running (skipped)"
fi
if pgrep -x Telegram >/dev/null 2>&1 || pgrep -fi telegram-desktop >/dev/null 2>&1; then
    telegram_slots="$(echo "${result//|/$'\n'}" | grep -ci 'telegram' || true)"
    if [[ "${telegram_slots:-0}" -eq 1 ]]; then
        pass "telegram has one tray slot while running"
    elif [[ "${telegram_slots:-0}" -gt 1 ]]; then
        fail "telegram appears more than once in pill: $result"
    else
        fail "telegram is running but missing from pill: $result"
    fi
else
    pass "telegram not running (skipped)"
fi
if pgrep -fi viber >/dev/null 2>&1; then
    if [[ "$result" == *"viber"* ]] || [[ "$result" == *"Viber"* ]]; then
        pass "viber visible in pill while running"
    else
        fail "viber is running but missing from pill: $result"
    fi
else
    pass "viber not running (skipped)"
fi
if pgrep -x slack >/dev/null 2>&1; then
    if [[ "$result" == *"slack"* ]] || [[ "$result" == *"TRAY+WIN"*Slack* ]] || [[ "$result" == *"TRAY-ONLY slack"* ]]; then
        pass "slack tray slot visible while slack is running"
    else
        fail "slack is running but missing from pill: $result"
    fi
else
    pass "slack not running (skipped)"
fi
if [[ "$result" == *"CLIENT-TRAY protonvpn"* ]] || [[ "$result" == *"CLIENT-TRAY proton-vpn"* ]]; then
    pass "proton vpn window linked to tray menu"
elif [[ "$result" != *"proton"* ]]; then
    pass "proton vpn not running (skipped)"
else
    fail "proton vpn is not linked to its open window: $result"
fi
cursor_count="$(echo "${result//|/$'\n'}" | grep -c 'CLIENT-TRAY cursor' || true)"
if pgrep -x cursor >/dev/null 2>&1; then
    open_cursor="$(awesome-client 'local n=0; for _,cl in ipairs(client.get()) do if cl.class and cl.class:lower()=="cursor" and cl.type~="desktop" then n=n+1 end end; return n' 2>/dev/null | tail -1 | sed 's/^   double //; s/^   string "//; s/"$//' || echo 0)"
    if [[ "${open_cursor:-0}" -ge 2 ]] && [[ "${cursor_count:-0}" -ge 2 ]]; then
        pass "each open cursor window has its own pill slot (${cursor_count})"
    elif [[ "${open_cursor:-0}" -le 1 ]]; then
        pass "single cursor window check skipped"
    else
        fail "expected ${open_cursor} cursor pill slots, got ${cursor_count}: $result"
    fi
fi

hubstaff_icon="$(awesome-client 2>&1 <<'LUA' | tail -1 | sed 's/^   string "//; s/"$//'
package.loaded["tray-registry"] = nil
local tr = require("tray-registry")
tr.refresh(true, false)
for _, item in ipairs(tr.cached_items()) do
  if item.id == "hubstaff" then
    return item.icon_path or ""
  end
end
return ""
LUA
)"
if [[ -n "$hubstaff_icon" ]] && [[ -f "$hubstaff_icon" ]]; then
    pass "hubstaff tray icon resolved ($hubstaff_icon)"
else
    fail "hubstaff tray icon missing (got: ${hubstaff_icon:-none})"
fi

pass "verification complete"
