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

    wl-copy < $tmpfile
    echo "Copied formatted output to clipboard"
    rm $tmpfile
end
