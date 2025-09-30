function tls --description 'Pick a tmux session from outside tmux (fzf if available)'
    # If already inside tmux, open the built-in chooser
    if set -q TMUX
        tmux choose-tree -s
        return
    end

    # Collect existing sessions (names only)
    set -l sessions (tmux ls -F '#S')
    if test $status -ne 0
        echo "No tmux server. Exit..."
        return 1
    end

    set -l choice (printf "%s\n" $sessions | fzf --prompt='tmux sessions> ' --height=40%)
    if test -n "$choice"
      echo "Attaching to $choice..."
      tmux attach -t "$choice"
    else
        echo "Aborted."
        return 1
    end
end

