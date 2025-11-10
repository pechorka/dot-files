function __ssh_candidate_keys --description 'List private SSH key files under ~/.ssh'
    for f in ~/.ssh/*
        if not test -f $f
            continue
        end

        # Skip obvious non-keys
        switch (basename -- $f)
            case '*.pub' 'known_hosts*' 'authorized_keys*' 'config*'
                continue
        end

        # Read first line safely; suppress errors if unreadable
        set -l first
        if not read -l first < $f 2>/dev/null
            continue
        end

        # Heuristic: catches OPENSSH/PKCS#1/PKCS#8/encrypted formats
        if string match -rq '^\s*-----BEGIN .*PRIVATE KEY-----' -- $first
            echo $f
        end
    end
end

