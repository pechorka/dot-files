#!/bin/sh
# display-restore.sh - apply saved sway output config for current monitor combination
# Called by sway via exec_always on startup/reload.
# Exits silently (noop) if no saved config matches the connected monitors.

OUTPUTS_DIR="${HOME}/.config/sway/outputs"

[ -d "$OUTPUTS_DIR" ] || exit 0

KEY=$(swaymsg -t get_outputs 2>/dev/null \
    | jq -r '[.[] | .name] | sort | join("+")')

[ -z "$KEY" ] && exit 0

CONFIG_FILE="${OUTPUTS_DIR}/${KEY}.conf"
[ -f "$CONFIG_FILE" ] || exit 0

while IFS= read -r line; do
    [ -z "$line" ] && continue
    swaymsg "$line"
done < "$CONFIG_FILE"
