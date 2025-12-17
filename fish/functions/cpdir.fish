function cpdir
    if test (count $argv) -ne 1
        echo "Usage: cpdir DIR" >&2
        return 1
    end

    set base (realpath $argv[1])

    if not test -d $base
        echo "Error: '$base' is not a directory" >&2
        return 1
    end

    set tmpfile (mktemp)

    for file in (find $base -type f)
        set rel (string replace -r "^$base/" "" $file)
        echo "```$rel" >> $tmpfile
        cat $file >> $tmpfile
        echo >> $tmpfile
        echo '```' >> $tmpfile
    end

    if type -q xclip
        cat $tmpfile | xclip -selection clipboard
        echo "✅ Copied formatted output to clipboard (via xclip)"
    else if type -q xsel
        cat $tmpfile | xsel --clipboard --input
        echo "✅ Copied formatted output to clipboard (via xsel)"
    else
        echo "⚠️ Neither xclip nor xsel found. Output saved to $tmpfile"
        echo "Install one with: sudo apt install xclip"
    end

    rm $tmpfile
end
