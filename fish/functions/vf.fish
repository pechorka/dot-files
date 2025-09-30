function vf
    set -l file (rg --hidden -l "" --glob '!.git/' --glob '!node_modules/' | fzf)
    if test -n "$file"
        nvim "$file"
    end
end
