#!/bin/sh
print_status() {
    LANG=$(swaymsg -t get_inputs 2>/dev/null \
        | grep -m1 '"xkb_active_layout_name"' \
        | sed 's/.*": "\([^"]*\)".*/\1/' \
        | cut -c1-2 | tr '[:upper:]' '[:lower:]')

    if [ "$(pamixer --get-mute)" = "true" ]; then
        VOL="vol mute"
    else
        VOL="vol $(pamixer --get-volume)%"
    fi

    MEM=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%.0fG",(t-a)/1024/1024}' /proc/meminfo)

    CAP=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -1)
    STATUS=$(cat /sys/class/power_supply/BAT*/status 2>/dev/null | head -1)
    [ "$STATUS" = "Charging" ] && BAT="bat ${CAP}%" || BAT="${CAP}%"

    TIME=$(date +"%H:%M  %Y-%m-%d")

    echo "$LANG | $VOL | $MEM | $BAT | $TIME"
}

trap 'print_status' USR1

while true; do
    print_status
    sleep 1 &
    wait
done
