#!/usr/bin/env bash

export DISPLAY="${DISPLAY:-:0}"

awesome-client "
local awful = require('awful')
local items = {}
for _, layout in ipairs(awful.layout.layouts) do
    items[#items + 1] = {
        layout.name,
        function()
            awful.layout.set(layout)
        end,
    }
end
awful.menu.show({ items = items })
"
