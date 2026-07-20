#!/usr/bin/env bash

close_volume_popup() {
    command -v awesome-client >/dev/null || return 0
    awesome-client "pcall(function() require('volume-slider').hide() end)" >/dev/null 2>&1 || true
}

close_volume_popup
