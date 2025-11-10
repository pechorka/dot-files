function __ssh_candidate_keys --description 'List private SSH key files under ~/.ssh'
    set -l keys
    for f in ~/.ssh/*
        if test -f $f
            # Skip obvious non-keys
            if string match -q -- "*.pub" $f; or string match -q -- "*known_hosts*" $f; or string match -q -- "*authorized_keys*" $f; or string match -q -- "*config*" $f
                continue
            end
            # Heuristic: check PEM header for private keys
            set -l first (head -n 1 $f ^/dev/null)
            if string match -rq '^-----BEGIN .*PRIVATE KEY-----' -- $first
                set -a keys $f
            end
        end
    end
    printf "%s\n" $keys
end
