function __ensure_ssh_agent --description 'Ensure ssh-agent is running and keys are loaded'
    set -l keys (__ssh_candidate_keys)
    if test (count $keys) -gt 0
        keychain --quiet --eval $keys | source
    else
        keychain --quiet --eval | source
    end
end
