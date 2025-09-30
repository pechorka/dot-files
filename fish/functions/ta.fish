function ta
    # Get the current directory name (basename)
    set session_name (basename (pwd))
    
    # Check if tmux server is running and if the session exists
    if tmux list-sessions 2>/dev/null | grep -q "^$session_name:"
        # Session exists, attach to it
        echo "Attaching to existing session: $session_name"
        tmux attach-session -t $session_name
    else
        # Session doesn't exist, create it
        echo "Creating new session: $session_name"
        tmux new-session -s $session_name
    end
end
