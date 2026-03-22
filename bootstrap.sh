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

install_managed_file() {
    local src="$1"
    local dest="$2"
    local mode="${3:-644}"

    if [ ! -f "$src" ]; then
        warn "Missing managed file: $src"
        return 1
    fi

    if sudo test -L "$dest"; then
        sudo rm -f "$dest"
    fi

    sudo install -Dm"$mode" "$src" "$dest"
}

set_snapper_value() {
    local key="$1"
    local value="$2"

    sudo sed -i "s/^${key}=.*/${key}=\"${value}\"/" /etc/snapper/configs/root
}

configure_snapper_policy() {
    if [ ! -f /etc/snapper/configs/root ]; then
        warn "Snapper root config not found — skipping retention policy"
        return
    fi

    set_snapper_value TIMELINE_CREATE no
    set_snapper_value NUMBER_LIMIT 3
    set_snapper_value NUMBER_LIMIT_IMPORTANT 3
    log "Applied Snapper cleanup-only retention policy"
}

enable_system_service() {
    local svc="$1"

    if systemctl is-enabled "$svc" &>/dev/null; then
        log "  $svc already enabled"
    else
        sudo systemctl enable --now "$svc"
        log "  Enabled $svc"
    fi
}

disable_system_service() {
    local svc="$1"

    if systemctl is-enabled "$svc" &>/dev/null || systemctl is-active "$svc" &>/dev/null; then
        sudo systemctl disable --now "$svc" &>/dev/null || sudo systemctl disable "$svc" &>/dev/null || true
        log "  Disabled $svc"
    else
        log "  $svc already disabled"
    fi
}

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
        xdg-desktop-portal-wlr
        xorg-xwayland

        # Audio
        pipewire
        pipewire-pulse
        sof-firmware
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

        # Laptop power management
        tlp

        # Snapshot management
        snapper
        snap-pac

        # Shells & editors
        fish
        tmux

        # CLI tools
        ripgrep
        fzf
        fd
        jq
        bat
        curl
        wget
        lazygit
        openssh
        less
        btop

        # Development — Go
        go
        gopls

        # Development — Rust
        rustup

        # Development — JS/TS
        nodejs
        pnpm
        npm

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
        satty

        # System applets
        networkmanager
        blueman
        pavucontrol
        lxqt-policykit 

        # Fonts
        noto-fonts-emoji
        ttf-font-awesome
        ttf-liberation

        # Sandboxing (for future per-project isolation)
        bubblewrap
        mise

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
    local aur_packages=(ghostty yq-go neovim-nightly-bin)
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

        log "Snapper configured"
    else
        log "Snapper already configured, applying policy."
    fi

    configure_snapper_policy

    log "Stage 1 complete."
}

# =============================================================================
# Stage 2 — System Configs
# =============================================================================
stage_2_system() {
    log "Stage 2 — Installing system configs..."

    mkdir -p "$LOCAL_BIN"

    if [ -f "$DOTFILES_DIR/system/zram-generator.conf" ]; then
        install_managed_file "$DOTFILES_DIR/system/zram-generator.conf" /etc/systemd/zram-generator.conf
        log "  Installed zram-generator config"
    fi

    if [ -f "$DOTFILES_DIR/system/loader.conf" ]; then
        install_managed_file "$DOTFILES_DIR/system/loader.conf" /boot/loader/loader.conf
        log "  Installed systemd-boot loader config"
    fi

    if [ -f "$DOTFILES_DIR/system/tlp.d/10-laptop-power.conf" ]; then
        install_managed_file "$DOTFILES_DIR/system/tlp.d/10-laptop-power.conf" /etc/tlp.d/10-laptop-power.conf
        log "  Installed TLP power policy"
    fi

    sudo systemctl daemon-reload
    if sudo systemctl start systemd-zram-setup@zram0.service; then
        log "  Activated zram swap"
    else
        warn "  Failed to activate zram swap"
    fi

    if fish -c "hide_app avahi-discover btop bssh bvnc jconsole-java-openjdk jshell-java-openjdk nvim qv4l2 qvidcap vim"; then
        log "  Hidden default apps from launcher"
    else
        warn "  Failed to hide one or more launcher entries"
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

    local disabled_services=(
        power-profiles-daemon.service
        NetworkManager-wait-online.service
        snapper-timeline.timer
    )
    for svc in "${disabled_services[@]}"; do
        disable_system_service "$svc"
    done

    local services=(
        systemd-resolved
        NetworkManager
        bluetooth.service
        snapper-cleanup.timer
        tlp.service
    )

    for svc in "${services[@]}"; do
        enable_system_service "$svc"
    done

    if sudo systemctl restart tlp.service &>/dev/null; then
        log "  Reapplied tlp.service"
    else
        warn "  Failed to reapply tlp.service"
    fi

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
    log "  3. Optional: run ./bootstrap-fingerprint.sh for TTY login + swaylock fingerprint auth"
}

main "$@"
