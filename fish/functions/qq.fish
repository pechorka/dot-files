function __qq_os_name
    set -l os (command uname -s)
    if test "$os" = Linux; and test -f /etc/os-release
        set -l distro (string match -r 'PRETTY_NAME="?([^"]*)"?' < /etc/os-release)[2]
        test -n "$distro"; and set os "$distro"
    else if test "$os" = Darwin
        set -l ver (command sw_vers -productVersion 2>/dev/null)
        test -n "$ver"; and set os "macOS $ver"
    end
    echo $os
end

function __qq_pkg_manager
    for pm in pacman apt dnf brew zypper apk
        if type -q $pm
            echo $pm
            return
        end
    end
    echo unknown
end

function __qq_system_context
    printf '%s, %s, fish shell, %s' (__qq_os_name) (command uname -m) (__qq_pkg_manager)
end

function qq --description 'Ask Codex for a direct one-shot answer'
    set -l usage \
        'Usage: qq [-m MODEL|--model MODEL] [QUESTION...]' \
        '       qq [-m MODEL|--model MODEL] < prompt.txt' \
        '' \
        'Examples:' \
        '  qq why is my boot slow' \
        '  git diff | qq summarize this diff in 3 bullets'

    argparse -n qq h/help m/model= -- $argv
    or begin
        printf '%s\n' $usage >&2
        return 2
    end

    if set -q _flag_help
        printf '%s\n' $usage
        return 0
    end

    set -l model
    if set -q _flag_model
        set model $_flag_model
    else
        set model gpt-5.4-mini
    end

    set -l piped_text
    if not isatty stdin
        set piped_text (string collect <&0)
    end

    set -l question
    set -l context_text
    if test (count $argv) -gt 0
        set question (string join ' ' -- $argv)
        if test -n "$piped_text"
            set context_text $piped_text
        end
    else if test -n "$piped_text"
        set question $piped_text
    else
        printf 'qq: missing question\n' >&2
        printf '%s\n' $usage >&2
        return 2
    end

    if not type -q codex
        printf 'qq: codex is not installed\n' >&2
        return 127
    end

    set -l instruction "The user is on: "(__qq_system_context)". Answer directly and concretely. No chatty preamble, no small talk, and no follow-up questions. If the best response is code or commands, output only that."
    set -l prompt (printf '%s\n\nQuestion:\n%s' "$instruction" "$question")
    if test -n "$context_text"
        set prompt (printf '%s\n\nContext:\n%s' "$prompt" "$context_text")
    end

    set -l answer_file (command mktemp)
    or begin
        printf 'qq: failed to create a temporary file\n' >&2
        return 1
    end

    set -l error_file (command mktemp)
    or begin
        command rm -f -- "$answer_file"
        printf 'qq: failed to create a temporary file\n' >&2
        return 1
    end

    set -l stdout_file (command mktemp)
    or begin
        command rm -f -- "$answer_file" "$error_file"
        printf 'qq: failed to create a temporary file\n' >&2
        return 1
    end

    set -l cleanup_files "$answer_file" "$error_file" "$stdout_file"
    set -l exit_code 0

    if command codex exec \
        --skip-git-repo-check \
        --ephemeral \
        --sandbox read-only \
        --color never \
        --model "$model" \
        -c 'service_tier="fast"' \
        -c 'model_reasoning_effort="low"' \
        -o "$answer_file" \
        "$prompt" \
        >"$stdout_file" \
        2>"$error_file"
        if test -s "$answer_file"
            command cat "$answer_file"
        else if test -s "$stdout_file"
            command cat "$stdout_file"
        else
            printf 'qq: codex returned no output\n' >&2
            if test -s "$error_file"
                command cat "$error_file" >&2
            end
            set exit_code 1
        end
    else
        set exit_code $status
        if test -s "$error_file"
            command cat "$error_file" >&2
        else if test -s "$stdout_file"
            command cat "$stdout_file" >&2
        end
    end

    command rm -f -- $cleanup_files
    return $exit_code
end
