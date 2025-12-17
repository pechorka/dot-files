function cpdiff
    # Optional: allow specifying base branch, default to "main"
    set base main
    if test (count $argv) -ge 1
        set base $argv[1]
    end

    if not type -q git
        echo "Error: git not found in PATH" >&2
        return 1
    end

    if not git rev-parse --is-inside-work-tree >/dev/null 2>&1
        echo "Error: not inside a git repository" >&2
        return 1
    end

    # Resolve base branch: prefer local branch, fall back to origin/<base>
    set base_ref $base
    if not git show-ref --verify --quiet "refs/heads/$base"
        if git show-ref --verify --quiet "refs/remotes/origin/$base"
            set base_ref "origin/$base"
        else
            echo "Error: base branch '$base' or 'origin/$base' not found" >&2
            return 1
        end
    end

    set tmpfile (mktemp)

    # Wrap diff in a code block for easy LLM pasting
    echo '```diff' > $tmpfile
    git diff $base_ref...HEAD >> $tmpfile
    echo >> $tmpfile
    echo '```' >> $tmpfile

    if type -q xclip
        xclip -selection clipboard < $tmpfile
        echo "Copied diff against $base_ref to clipboard (via xclip)"
        rm $tmpfile
    else if type -q xsel
        xsel --clipboard --input < $tmpfile
        echo "Copied diff against $base_ref to clipboard (via xsel)"
        rm $tmpfile
    else
        echo "Warning: neither xclip nor xsel found. Diff saved to $tmpfile" >&2
        echo "Install one with: sudo apt install xclip" >&2
        # leave tmpfile so you can inspect/copy manually
    end
end
