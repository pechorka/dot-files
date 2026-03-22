function ta
    # Normalize the current directory name into a tmux-safe session name.
    set -l session_name (basename (pwd))
    if string match -q '.*' -- $session_name
        set session_name "dot-"(string sub -s 2 -- $session_name)
    end
    set session_name (string replace -a -- . - $session_name)
    set -l target_session "=$session_name"

    # Check if tmux session exists
    if tmux has-session -t "$target_session" 2>/dev/null
        echo "Attaching to existing session: $session_name"
        tmux attach-session -t "$target_session"
    else
        echo "Creating new session with 4 windows: $session_name"
        tmux new-session -d -s "$session_name" -n editor \;\
            new-window -n agent \;\
            new-window -n run \;\
            new-window -n misc
        tmux attach-session -t "$target_session"
    end
end
