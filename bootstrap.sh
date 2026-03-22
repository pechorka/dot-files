#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Bootstrap Script
# Turns a fresh Arch install into a fully configured development workstation.
#
# Prerequisites (from Arch install):
#   - Arch base system booting (btrfs with subvolumes)
#   - Alpine recovery partition installed
#   - User account with sudo access
#   - Internet connectivity
#   - Git installed
#
# Usage: ./bootstrap.sh
# Safe to run multiple times (idempotent).
# =============================================================================

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BIN="$HOME/.local/bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[bootstrap]${NC} $1"; }
warn() { echo -e "${YELLOW}[bootstrap]${NC} $1"; }
error() { echo -e "${RED}[bootstrap]${NC} $1"; }

# =============================================================================
# Stage 1 — System Packages (pacman + AUR)
# =============================================================================
stage_1_packages() {
    log "Stage 1 — Installing packages via pacman..."

    # Resolve iptables conflict (needed by some packages)
    if pacman -Qi iptables &>/dev/null && ! pacman -Qi iptables-nft &>/dev/null; then
        log "Replacing iptables with iptables-nft..."
        sudo pacman -S --needed --noconfirm --ask 4 iptables-nft
    fi

    # Pre-install noto-fonts to satisfy ttf-font dependency without prompt
    sudo pacman -S --needed --noconfirm noto-fonts

    local packages=(
        # Display & compositor
        sway
        swaylock
        swayidle
        swaybg
        xdg-desktop-portal-wlr
        xorg-xwayland

        # Audio
        pipewire
        pipewire-pulse
        wireplumber

        # Graphics (Intel i7-1365U)
        mesa
        vulkan-intel
        intel-media-driver

        # Browsers (GPU-dependent, must be pacman not Nix)
        firefox
        chromium

        # Swap (compressed, in RAM)
        zram-generator

        # Snapshot management
        snapper
        snap-pac

        # Shells & editors
        fish
        neovim
        tmux

        # CLI tools
        ripgrep
        fzf
        fd
        jq
        htop
        bat
        curl
        wget
        lazygit
        openssh
        less

        # Development — Go
        go
        gopls

        # Development — Rust
        rustup

        # Development — JS/TS
        nodejs
        pnpm

        # Development — JVM
        jdk-openjdk
        kotlin
        gradle

        # DB clients
        sqlite
        pgcli

        # Containers
        podman

        # Wayland desktop tools
        wofi
        mako
        grim
        slurp
        wl-clipboard
        brightnessctl
        playerctl
        pamixer
        sway-contrib
        satty

        # System applets
        networkmanager
        network-manager-applet
        blueman
        pavucontrol
        polkit-gnome

        # Fonts
        noto-fonts-emoji
        ttf-font-awesome
        ttf-liberation

        # Sandboxing (for future per-project isolation)
        bubblewrap

        # Build tools
        base-devel

        # ssh
        keychain
    )

    sudo pacman -S --needed --noconfirm "${packages[@]}"

    # Install yay (AUR helper) if not present
    if ! command -v yay &>/dev/null; then
        log "Installing yay (AUR helper)..."
        local yay_tmp
        yay_tmp=$(mktemp -d)
        git clone https://aur.archlinux.org/yay.git "$yay_tmp/yay"
        (cd "$yay_tmp/yay" && makepkg -si --noconfirm)
        rm -rf "$yay_tmp"
    else
        log "yay already installed, skipping."
    fi

    # AUR packages
    local aur_packages=(ghostty yq-go)
    for pkg in "${aur_packages[@]}"; do
        if ! pacman -Qi "$pkg" &>/dev/null; then
            log "Installing $pkg from AUR..."
            yay -S --needed --noconfirm "$pkg"
        fi
    done

    # Initialize Rust toolchain via rustup (pacman installs rustup, not rustc directly)
    if ! rustup show active-toolchain &>/dev/null 2>&1; then
        log "Installing Rust stable toolchain..."
        rustup default stable
        rustup component add rust-analyzer clippy rustfmt
    fi

    # Configure snapper for btrfs root snapshots
    if [ ! -f /etc/snapper/configs/root ]; then
        log "Configuring snapper..."

        # Snapper create-config expects /.snapshots not to already be mounted/present
        if mountpoint -q /.snapshots; then
          sudo umount /.snapshots
        fi

        if [ -e /.snapshots ]; then
          sudo rm -rf /.snapshots
        fi

        sudo snapper -c root create-config /

        # Replace Snapper-created subvolume with our dedicated @snapshots subvolume
        if sudo btrfs subvolume show /.snapshots &>/dev/null 2>&1; then
          sudo btrfs subvolume delete /.snapshots
        else
          sudo rm -rf /.snapshots 2>/dev/null || true
        fi

        sudo mkdir -p /.snapshots

        root_dev=$(findmnt -n -o SOURCE /)
        root_dev=$(echo "$root_dev" | sed 's/\[.*\]//')
        sudo mount -o subvol=@snapshots,compress=zstd,noatime "$root_dev" /.snapshots

        sudo sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' /etc/snapper/configs/root
        sudo sed -i 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="5"/' /etc/snapper/configs/root
        sudo sed -i 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="5"/' /etc/snapper/configs/root

        log "Snapper configured"
    else
        log "Snapper already configured, skipping."
    fi

    log "Stage 1 complete."
}

# =============================================================================
# Stage 2 — System Configs
# =============================================================================
stage_2_system() {
    log "Stage 2 — Installing system configs..."

    mkdir -p "$LOCAL_BIN"

    if [ -f "$DOTFILES_DIR/system/zram-generator.conf" ]; then
        sudo ln -sfn "$DOTFILES_DIR/system/zram-generator.conf" /etc/systemd/zram-generator.conf
        log "  Linked zram-generator config"
    fi

    log "Stage 2 complete."
}

# =============================================================================
# Stage 3 — Shell Setup
# =============================================================================
stage_3_shell() {
    log "Stage 3 — Setting up fish shell..."

    local fish_path
    fish_path="$(command -v fish 2>/dev/null || echo "")"
    if [ -n "$fish_path" ]; then
        if ! grep -qF "$fish_path" /etc/shells; then
            echo "$fish_path" | sudo tee -a /etc/shells >/dev/null
            log "  Added $fish_path to /etc/shells"
        fi
        if [ "$SHELL" != "$fish_path" ]; then
            chsh -s "$fish_path"
            log "  Default shell changed to fish (takes effect on next login)"
        fi
    else
        warn "fish not found — skipping shell change."
    fi

    log "Stage 3 complete."
}

# =============================================================================
# Stage 4 — systemd Services
# =============================================================================
stage_4_services() {
    log "Stage 4 — Enabling systemd services..."

    local services=(
        systemd-resolved
        NetworkManager
        bluetooth.service
        snapper-cleanup.timer
    )

    for svc in "${services[@]}"; do
        if systemctl is-enabled "$svc" &>/dev/null; then
            log "  $svc already enabled"
        else
            sudo systemctl enable --now "$svc"
            log "  Enabled $svc"
        fi
    done

    local user_services=(pipewire pipewire-pulse wireplumber)
    for svc in "${user_services[@]}"; do
        if systemctl --user is-enabled "$svc" &>/dev/null; then
            log "  $svc (user) already enabled"
        else
            systemctl --user enable --now "$svc" 2>/dev/null || log "  $svc (user) — enable on next graphical login"
        fi
    done

    log "Stage 4 complete."
}

# =============================================================================
# Main
# =============================================================================
main() {
    log "========================================="
    log "Bootstrap starting..."
    log "Dotfiles: $DOTFILES_DIR"
    log "========================================="

    stage_1_packages
    stage_2_system
    stage_3_shell
    stage_4_services

    log "========================================="
    log "Bootstrap complete!"
    log "========================================="
    log ""
    log "Next steps:"
    log "  1. Log out and back in (for fish shell)"
    log "  2. Start Sway from TTY: sway"
}

main "$@"
