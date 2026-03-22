function cpdiff
    set base main
    if test (count $argv) -ge 1
        set base $argv[1]
    end

    if not git rev-parse --is-inside-work-tree >/dev/null 2>&1
        echo "Error: not inside a git repository" >&2
        return 1
    end

    # Resolve base ref: try as-is, then fall back to origin/<base> for branch names
    set base_ref $base
    if not git rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1
        if git rev-parse --verify --quiet "origin/$base^{commit}" >/dev/null 2>&1
            set base_ref "origin/$base"
        else
            echo "Error: '$base' is not a valid git ref" >&2
            return 1
        end
    end

    set tmpfile (mktemp)

    echo '```diff' > $tmpfile
    git diff $base_ref...HEAD >> $tmpfile
    echo >> $tmpfile
    echo '```' >> $tmpfile

    wl-copy < $tmpfile
    echo "Copied diff against $base_ref to clipboard"
    rm $tmpfile
end
