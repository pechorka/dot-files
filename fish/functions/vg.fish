function vg
    if test (count $argv) -eq 0
        read -P "Search pattern: " pattern
        if test -z "$pattern"
            return 1
        end
    else
        set pattern $argv[1]
    end

    set results (
        rg --hidden --vimgrep --color=always --no-heading --smart-case $pattern . \
        | fzf \
            --ansi \
            --delimiter=':' \
            --preview='bat --style=numbers --color=always --highlight-line {2} {1}' \
            --preview-window='right:60%,border-left'
    )

    if test -z "$results"
        return
    end

    set parts (string split ":" -- $results)
    set file  $parts[1]
    set line  $parts[2]

    nvim +$line "$file"
end
