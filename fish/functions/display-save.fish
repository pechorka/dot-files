function display-save --description "Save current sway display configuration"
    set -l outputs_dir ~/.config/sway/outputs
    mkdir -p $outputs_dir

    # Auto-detect correct sway socket if SWAYSOCK is stale/missing
    if not swaymsg -t get_version &>/dev/null
        set -l uid (id -u)
        set -l socket (ls -t /run/user/$uid/sway-ipc.$uid.*.sock 2>/dev/null | head -1)
        if test -n "$socket"
            set -x SWAYSOCK $socket
        end
    end

    # Fetch output state once, fail early if sway IPC is unavailable
    set -l outputs_json (swaymsg -t get_outputs 2>/dev/null)
    if test $status -ne 0
        echo "display-save: cannot connect to sway IPC (is sway running?)" >&2
        return 1
    end

    # Key = ALL connected output names sorted and joined with +
    # Includes disabled outputs so the combo key reflects physical connections
    set -l key (echo $outputs_json | jq -r '
        [.[] | .name] | sort | join("+")
    ')

    if test -z "$key"
        echo "display-save: no outputs found" >&2
        return 1
    end

    set -l config_file $outputs_dir/$key.conf

    # Keep one backup before overwriting
    if test -f $config_file
        cp $config_file $config_file.bak
        echo "display-save: backed up to $config_file.bak"
    end

    # Generate sway output directives; disabled outputs get "disable"
    echo $outputs_json | jq -r '
        .[] |
        if .active then
            . as $o |
            ($o.current_mode.refresh / 1000) as $hz |
            (if ($hz == ($hz | floor)) then ($hz | floor | tostring) else ($hz | tostring) end) as $hz_str |
            "output \($o.name) resolution \($o.current_mode.width)x\($o.current_mode.height)@\($hz_str)Hz position \($o.rect.x),\($o.rect.y) scale \($o.scale) transform \($o.transform)"
        else
            "output \(.name) disable"
        end
    ' > $config_file

    echo "display-save: saved '$key' → $config_file"
end
