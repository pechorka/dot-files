function cpdiff
    set base main
    if test (count $argv) -ge 1
        set base $argv[1]
    end

    if not git rev-parse --is-inside-work-tree >/dev/null 2>&1
        echo "Error: not inside a git repository" >&2
        return 1
    end

    set current_branch (git branch --show-current 2>/dev/null)
    set untracked_files (git ls-files --others --exclude-standard)
    set has_worktree_changes 0
    if not git diff --quiet --no-ext-diff HEAD --
        set has_worktree_changes 1
    else if test (count $untracked_files) -gt 0
        set has_worktree_changes 1
    end

    # If the requested base is the current local branch, diff against its upstream
    # so direct commits on that branch still produce a useful patch.
    set base_ref $base
    set diff_ref
    set diff_label
    if test "$base" = "$current_branch"
        set upstream_ref (git rev-parse --abbrev-ref --symbolic-full-name "$base@{upstream}" 2>/dev/null)
        if test -n "$upstream_ref"
            set base_ref $upstream_ref
        else if git rev-parse --verify --quiet "origin/$base^{commit}" >/dev/null 2>&1
            set base_ref "origin/$base"
        else if test $has_worktree_changes -eq 1
            set diff_ref HEAD
            set diff_label HEAD
        else if git rev-parse --verify --quiet "HEAD~1^{commit}" >/dev/null 2>&1
            set diff_ref HEAD~1
            set diff_label HEAD~1
        else
            set diff_ref HEAD
            set diff_label HEAD
        end
    else if not git rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1
        if git rev-parse --verify --quiet "origin/$base^{commit}" >/dev/null 2>&1
            set base_ref "origin/$base"
        else
            echo "Error: '$base' is not a valid git ref" >&2
            return 1
        end
    end

    if test -z "$diff_ref"
        set diff_ref (git merge-base $base_ref HEAD 2>/dev/null)
        if test -z "$diff_ref"
            echo "Error: could not determine merge-base for '$base_ref' and HEAD" >&2
            return 1
        end

        set diff_label $base_ref
    end

    set tmpfile (mktemp)

    echo '```diff' > $tmpfile
    git diff --no-ext-diff $diff_ref -- >> $tmpfile

    for path in $untracked_files
        echo >> $tmpfile
        git diff --no-ext-diff --no-index -- /dev/null "$path" >> $tmpfile
    end

    echo >> $tmpfile
    echo '```' >> $tmpfile

    wl-copy < $tmpfile
    echo "Copied diff against $diff_label to clipboard"
    rm $tmpfile
end
