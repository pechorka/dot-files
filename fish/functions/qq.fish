function qq --description 'Ask Codex or Claude for a direct one-shot answer'
    set -l usage \
        'Usage: qq [--claude|--codex] [-m MODEL|--model MODEL] [QUESTION...]' \
        '       qq [--claude|--codex] [-m MODEL|--model MODEL] < prompt.txt' \
        '' \
        'Examples:' \
        '  qq why is my boot slow' \
        '  git diff | qq summarize this diff in 3 bullets'

    argparse -n qq h/help claude codex m/model= -- $argv
    or begin
        printf '%s\n' $usage >&2
        return 2
    end

    if set -q _flag_help
        printf '%s\n' $usage
        return 0
    end

    if set -q _flag_claude; and set -q _flag_codex
        printf 'qq: choose only one provider: --claude or --codex\n' >&2
        printf '%s\n' $usage >&2
        return 2
    end

    set -l provider codex
    if set -q _flag_claude
        set provider claude
    end

    set -l model
    if set -q _flag_model
        set model $_flag_model
    else if test "$provider" = codex
        set model gpt-5.4-mini
    else
        set model haiku
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

    if test "$provider" = codex
        if not type -q codex
            printf 'qq: codex is not installed\n' >&2
            return 127
        end
    else
        if not type -q claude
            printf 'qq: claude is not installed\n' >&2
            return 127
        end
    end

    set -l instruction 'Answer directly and concretely. No chatty preamble, no small talk, and no follow-up questions. If the best response is code or commands, output only that.'
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

    set -l prompt_file (command mktemp)
    or begin
        command rm -f -- "$answer_file" "$error_file"
        printf 'qq: failed to create a temporary file\n' >&2
        return 1
    end

    printf '%s' "$prompt" > "$prompt_file"
    or begin
        command rm -f -- "$answer_file" "$error_file" "$prompt_file"
        printf 'qq: failed to write the prompt\n' >&2
        return 1
    end

    set -l cleanup_files "$answer_file" "$error_file" "$prompt_file"
    set -l exit_code 0

    if test "$provider" = codex
        set -l stdout_file (command mktemp)
        or begin
            command rm -f -- $cleanup_files
            printf 'qq: failed to create a temporary file\n' >&2
            return 1
        end
        set cleanup_files $cleanup_files "$stdout_file"

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
    else
        if command claude \
            -p \
            --no-session-persistence \
            --output-format text \
            --model "$model" \
            --tools Read,Grep,Glob \
            <"$prompt_file" \
            >"$answer_file" \
            2>"$error_file"
            if test -s "$answer_file"
                command cat "$answer_file"
            else
                printf 'qq: claude returned no output\n' >&2
                if test -s "$error_file"
                    command cat "$error_file" >&2
                end
                set exit_code 1
            end
        else
            set exit_code $status
            if test -s "$error_file"
                command cat "$error_file" >&2
            end
        end
    end

    command rm -f -- $cleanup_files
    return $exit_code
end
