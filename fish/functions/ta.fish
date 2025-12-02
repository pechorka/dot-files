function ta
    # Get the current directory name (basename)
    set session_name (basename (pwd))

    # Check if tmux session exists
    if tmux has-session -t $session_name 2>/dev/null
        echo "Attaching to existing session: $session_name"
        tmux attach-session -t $session_name
    else
        echo "Creating new session with 4 windows: $session_name"
        tmux new-session -d -s $session_name -n editor \;\
            new-window -n agent \;\
            new-window -n run \;\
            new-window -n misc
        tmux attach-session -t $session_name
    end
end
