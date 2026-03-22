#!/bin/sh
RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp}
[ -w "$RUNTIME_DIR" ] || RUNTIME_DIR=/tmp
PIDFILE="${RUNTIME_DIR}/sway-status.pid"

[ -r "$PIDFILE" ] || exit 0
kill -USR1 "$(cat "$PIDFILE")" 2>/dev/null || true
