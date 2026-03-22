function hide_app
    set -l apps_dir "$HOME/.local/share/applications"

    switch "$argv[1]"
        case ls list
            # List currently hidden apps
            for f in $apps_dir/*.desktop
                if grep -q 'NoDisplay=true' "$f" 2>/dev/null
                    basename "$f" .desktop
                end
            end
        case rm unhide
            # Unhide apps by removing the override desktop entry
            if test (count $argv) -lt 2
                echo "Usage: hide_app rm <app> [app...]"
                return 1
            end
            for app in $argv[2..]
                rm -f "$apps_dir/$app.desktop"
                echo "Unhid $app"
            end
        case ''
            echo "Usage: hide_app <app> [app...]"
            echo "       hide_app ls        — list hidden apps"
            echo "       hide_app rm <app>  — unhide an app"
            return 1
        case '*'
            # Hide apps by creating NoDisplay desktop entries
            mkdir -p "$apps_dir"
            for app in $argv
                printf '[Desktop Entry]\nNoDisplay=true\n' >"$apps_dir/$app.desktop"
                echo "Hid $app"
            end
    end
end
