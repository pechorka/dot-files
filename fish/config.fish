if status is-interactive
    # Commands to run in interactive sessions can go here
end

alias v nvim
alias lg lazygit

set -x RIPGREP_CONFIG_PATH "$HOME/.config/.ripgreprc"
set -gx NO_AT_BRIDGE 1

# Ensure ~/.local/bin is on PATH (vm CLI lives here)
fish_add_path --append "$HOME/.local/bin"

# npm global installs without root
set -gx NPM_CONFIG_PREFIX "$HOME/.npm-global"
fish_add_path --append "$HOME/.npm-global/bin"

__ensure_ssh_agent
