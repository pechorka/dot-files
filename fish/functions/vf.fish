function vf
    set -l file (fzf)
    if test -n "$file"
        nvim "$file"
    end
end
