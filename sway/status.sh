#!/bin/sh
RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp}
[ -w "$RUNTIME_DIR" ] || RUNTIME_DIR=/tmp
PIDFILE="${RUNTIME_DIR}/sway-status.pid"

print_status() {
    LAYOUT=$(swaymsg -t get_inputs -r 2>/dev/null \
        | jq -r 'map(select(.type == "keyboard" and .xkb_active_layout_name != null))[0].xkb_active_layout_name // "??"' \
        | cut -c1-2 | tr '[:upper:]' '[:lower:]')
    [ -n "$LAYOUT" ] || LAYOUT="??"

    VOL=$(pamixer --get-volume-human 2>/dev/null)
    [ -n "$VOL" ] || VOL="n/a"
    [ "$VOL" = "muted" ] && VOL="vol mute" || VOL="vol $VOL"

    MEM=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%.0fG",(t-a)/1024/1024}' /proc/meminfo)

    ROOT_INFO=$(df -hP / 2>/dev/null | awk 'NR==2{print $1 " " $4}')
    ROOT_FS=${ROOT_INFO%% *}
    ROOT_FREE=${ROOT_INFO#* }
    [ "$ROOT_FREE" = "$ROOT_INFO" ] && ROOT_FREE="n/a"

    case "${ROOT_FS##*/}" in
        *p[0-9]*)
            ROOT_LABEL=$(printf '%s' "${ROOT_FS##*/}" | sed -E 's/^.*(p[0-9]+)$/\1/')
            ;;
        *[0-9])
            ROOT_LABEL="p$(printf '%s' "${ROOT_FS##*/}" | sed -E 's/^.*([0-9]+)$/\1/')"
            ;;
        *)
            ROOT_LABEL="disk"
            ;;
    esac
    DISK="${ROOT_LABEL} ${ROOT_FREE}"

    set -- /sys/class/power_supply/BAT*
    if [ -r "$1/capacity" ]; then
        CAP=$(cat "$1/capacity")
        STATUS=$(cat "$1/status")
        [ "$STATUS" = "Charging" ] && BAT="bat ${CAP}%+" || BAT="bat ${CAP}%"
    else
        BAT="ac"
    fi

    printf '%s | %s | %s | %s | %s | %s\n' "$LAYOUT" "$VOL" "$MEM" "$DISK" "$BAT" "$(date '+%H:%M  %Y-%m-%d')"
}

printf '%s\n' "$$" > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT HUP INT TERM
trap 'print_status' USR1

while :; do
    print_status
    sleep 2 &
    wait
done
