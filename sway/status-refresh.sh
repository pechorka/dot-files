#!/bin/sh
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/sway-status.pid"

[ -r "$PIDFILE" ] || exit 0
kill -USR1 "$(cat "$PIDFILE")" 2>/dev/null || true
