function __ensure_ssh_agent --description 'Ensure ssh-agent is running and keys are loaded'
    # Choose socket path
    if set -q XDG_RUNTIME_DIR
        set -gx SSH_AUTH_SOCK "$XDG_RUNTIME_DIR/ssh-agent.sock"
    else
        set -gx SSH_AUTH_SOCK "$HOME/.ssh/ssh-agent.sock"
    end

    # Preferred: keychain (one agent, reused across logins)
    if type -q keychain
        set -l keys (__ssh_candidate_keys)
        if test (count $keys) -gt 0
            keychain --quiet --agents ssh --eval $keys | source
        else
            keychain --quiet --agents ssh --eval | source
        end
        return
    end

    # Fallback: DIY agent tied to $SSH_AUTH_SOCK
    if not test -S $SSH_AUTH_SOCK
        rm -f $SSH_AUTH_SOCK
        ssh-agent -a $SSH_AUTH_SOCK >/dev/null 2>&1
    else if not ssh-add -l >/dev/null 2>&1
        rm -f $SSH_AUTH_SOCK
        ssh-agent -a $SSH_AUTH_SOCK >/dev/null 2>&1
    end

    # Add all candidate keys (will prompt if they have passphrases)
    for key in (__ssh_candidate_keys)
        ssh-add -q $key >/dev/null 2>&1
    end
end
