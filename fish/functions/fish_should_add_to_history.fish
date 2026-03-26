function fish_should_add_to_history --description 'Skip selected commands from fish history'
    set -l cmdline "$argv[1]"

    # Preserve fish's default behavior for commands prefixed with whitespace.
    string match -qr '^\s' -- "$cmdline"
    and return 1

    # Hide qq invocations, including when qq appears in a pipeline or after a separator.
    string match -qr '(^|[|;&]\s*)qq(\s|$)' -- "$cmdline"
    and return 1

    return 0
end
