#!/usr/bin/env bash
wid="${1:?}"
awesome-client "for _, c in ipairs(client.get()) do if c.window == ${wid} then c:emit_signal('request::activate', 'tasklist', { raise = true }); break end end"
