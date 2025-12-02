function webrepo --description 'Open current git repo origin in the browser'
    # Ensure we are in a git repo
    if not git rev-parse --is-inside-work-tree >/dev/null 2>&1
        echo "webrepo: not inside a Git repository."
        return 1
    end

    # Get origin URL
    set -l remote (git remote get-url origin 2>/dev/null)
    if test -z "$remote"
        echo "webrepo: remote 'origin' not found."
        return 1
    end

    # Strip any scheme (https://, ssh://, etc.)
    set -l cleaned (string replace -r '^[^:]+://' '' -- $remote)

    # Convert SSH/HTTPS style to https://host/path (and drop .git)
    set -l url (string replace -r '^(git@)?([^:/]+)[:/](.+?)(\.git)?$' 'https://$2/$3' -- $cleaned)

    # If conversion failed, bail out
    if not string match -q 'https://*' -- $url
        echo "webrepo: unsupported remote URL format: $remote"
        return 1
    end

    # Try to open in a browser
    if type -q xdg-open
        xdg-open $url >/dev/null 2>&1
    else if type -q open
        # macOS
        open $url >/dev/null 2>&1
    else
        # Fallback: just print the URL
        echo $url
    end
end
