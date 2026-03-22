if status is-interactive
    # Commands to run in interactive sessions can go here
end

alias v nvim
alias lg lazygit

set -x RIPGREP_CONFIG_PATH "$HOME/.config/.ripgreprc"
set -gx NO_AT_BRIDGE 1
set -gx SSH_AUTH_SOCK (gpgconf --list-dirs agent-ssh-socket)

# Ensure ~/.local/bin is on PATH (vm CLI lives here)
fish_add_path --prepend "$HOME/.local/bin"
