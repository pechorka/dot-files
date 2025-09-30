function fp
    set selected_file (fzf)
    
    if test -z "$selected_file"
        return 0
    end
    
    set current_dir (dirname (realpath "$selected_file"))
    
    set git_root ""
    set temp_dir "$current_dir"
    
    while test "$temp_dir" != "/"
        if test -d "$temp_dir/.git"
            set git_root "$temp_dir"
            break
        end
        set temp_dir (dirname "$temp_dir")
    end
    
    # If no git root found, do nothing
    if test -z "$git_root"
        echo "No .git directory found in any parent directory"
        return 0
    end
    
    # Get the session name from the root folder name
    set session_name (basename "$git_root")
    
    # Check if tmux session already exists
    if tmux has-session -t "$session_name" 2>/dev/null
        # Session exists, attach to it
        if test -n "$TMUX"
            # If we're already in tmux, switch to the session
            tmux switch-client -t "$session_name"
        else
            # If we're not in tmux, attach to the session
            tmux attach-session -t "$session_name"
        end
    else
        # Session doesn't exist, create it
        if test -n "$TMUX"
            # If we're already in tmux, create new session and switch to it
            tmux new-session -d -s "$session_name" -c "$git_root"
            tmux switch-client -t "$session_name"
        else
            # If we're not in tmux, create and attach to new session
            tmux new-session -s "$session_name" -c "$git_root"
        end
    end
end
