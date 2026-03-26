#!/bin/sh
# display-watch.sh - watch for output changes and auto-restore display config
# Run once at sway startup via exec (not exec_always, to avoid accumulation).

DIR="$(dirname "$0")"

swaymsg -m -t subscribe '["output"]' 2>/dev/null | while IFS= read -r _line; do
    sleep 1  # let sway settle before querying output state
    "$DIR/display-restore.sh"
done
