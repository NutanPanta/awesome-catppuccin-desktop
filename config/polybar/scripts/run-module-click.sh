#!/usr/bin/env bash
# Detach polybar click handlers so the bar keeps accepting input.
if ((${#@} == 0)); then
    exit 1
fi

exec setsid -f "$@" </dev/null >/dev/null 2>&1
