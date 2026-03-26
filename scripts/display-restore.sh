#!/bin/sh
# display-restore.sh - apply saved sway output config for current monitor combination
# Called by sway via exec_always on startup/reload.
# Exits silently (noop) if no saved config matches the connected monitors.

OUTPUTS_DIR="${HOME}/.config/sway/outputs"

[ -d "$OUTPUTS_DIR" ] || exit 0

OUTPUTS_JSON=$(swaymsg -t get_outputs 2>/dev/null) || exit 0

KEY=$(printf '%s\n' "$OUTPUTS_JSON" \
    | jq -r '[.[] | .name] | sort | join("+")')

[ -z "$KEY" ] && exit 0

CONFIG_FILE="${OUTPUTS_DIR}/${KEY}.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    # No saved config for this combination. Only enable currently disabled
    # outputs so we do not create a no-op output event loop.
    printf '%s\n' "$OUTPUTS_JSON" \
        | jq -r '.[] | select(.active | not) | .name' \
        | while IFS= read -r name; do
            [ -n "$name" ] && swaymsg "output $name enable"
        done
    exit 0
fi

CURRENT_STATE=$(printf '%s\n' "$OUTPUTS_JSON" | jq -r '
    .[] |
    if .active then
        . as $o |
        ($o.current_mode.refresh / 1000) as $hz |
        (if ($hz == ($hz | floor)) then ($hz | floor | tostring) else ($hz | tostring) end) as $hz_str |
        "output \($o.name) resolution \($o.current_mode.width)x\($o.current_mode.height)@\($hz_str)Hz position \($o.rect.x) \($o.rect.y) scale \($o.scale) transform \($o.transform)"
    else
        "output \(.name) disable"
    end
' | sed '/^[[:space:]]*$/d' | sort)

DESIRED_STATE=$(sed '/^[[:space:]]*$/d' "$CONFIG_FILE" | sort)

[ "$CURRENT_STATE" = "$DESIRED_STATE" ] && exit 0

while IFS= read -r line; do
    [ -z "$line" ] && continue
    swaymsg "$line"
done < "$CONFIG_FILE"
