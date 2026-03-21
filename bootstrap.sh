#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Bootstrap Script
# Turns a fresh Arch install into a fully configured development workstation.
# See docs/requirements.md and docs/arch-installation-guide.md
#
# Prerequisites (from Arch install):
#   - Arch base system booting (btrfs, snapper configured)
#   - Alpine recovery partition installed
#   - User account with sudo access
#   - Internet connectivity
#   - Git installed
#
# Usage: ./bootstrap.sh
# Safe to run multiple times (idempotent).
# =============================================================================

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_REPO="$DOTFILES_DIR/nix"  # Shared Nix flake (lives in dotfiles)
LOCAL_BIN="$HOME/.local/bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[bootstrap]${NC} $1"; }
warn() { echo -e "${YELLOW}[bootstrap]${NC} $1"; }
error() { echo -e "${RED}[bootstrap]${NC} $1"; }

# =============================================================================
# Stage 1 — System Packages (pacman)
# =============================================================================
stage_1_system_packages() {
    log "Stage 1 — Installing system packages via pacman..."

    local packages=(
        # Display & compositor
        sway
        swaylock
        swayidle
        swaybg
        xdg-desktop-portal-wlr

        # Audio
        pipewire
        pipewire-pulse
        wireplumber

        # Graphics (Intel i7-1365U — Iris Xe integrated)
        mesa
        vulkan-intel
        intel-media-driver

        # VM infrastructure
        incus

        # Swap (compressed, in RAM)
        zram-generator

        # Build tools (needed for AUR helper)
        base-devel
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

    log "Stage 1 complete."
}

# =============================================================================
# Stage 2 — Nix Installation
# =============================================================================
stage_2_nix() {
    log "Stage 2 — Installing Nix..."

    if command -v nix &>/dev/null; then
        log "Nix already installed, skipping."
    else
        sh <(curl -L https://nixos.org/nix/install) --daemon --yes

        # Source nix in current shell
        # shellcheck disable=SC1091
        if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
            . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
        fi
    fi

    # Enable flakes and nix-command (idempotent)
    local nix_conf="/etc/nix/nix.conf"
    if ! grep -q "experimental-features" "$nix_conf" 2>/dev/null; then
        log "Enabling Nix flakes and nix-command..."
        echo "experimental-features = nix-command flakes" | sudo tee -a "$nix_conf" >/dev/null
        sudo systemctl restart nix-daemon.service
    else
        log "Nix flakes already enabled, skipping."
    fi

    log "Stage 2 complete."
}

# =============================================================================
# Stage 3 — Userspace Tooling (Nix)
# =============================================================================
stage_3_nix_tooling() {
    log "Stage 3 — Installing userspace tooling via Nix..."

    nix profile install "$FLAKE_REPO#host" || {
        warn "Nix profile install failed — the flake repo may not exist yet."
        warn "Create the flake at $FLAKE_REPO and re-run bootstrap."
        warn "Continuing with remaining stages..."
        return 0
    }

    log "Stage 3 complete."
}

# =============================================================================
# Stage 4 — System Configs & Build vm CLI
# =============================================================================
stage_4_system_and_vm() {
    log "Stage 4 — Installing system configs and building vm CLI..."

    mkdir -p "$LOCAL_BIN"

    # --- System configs (sudo needed, can't live in ~/.config) ---
    if [ -f "$DOTFILES_DIR/system/resolved-incus-dns.conf" ]; then
        sudo mkdir -p /etc/systemd/resolved.conf.d
        sudo ln -sfn "$DOTFILES_DIR/system/resolved-incus-dns.conf" /etc/systemd/resolved.conf.d/incus-dns.conf
        log "  Linked resolved incus-dns config"
    fi

    if [ -f "$DOTFILES_DIR/system/zram-generator.conf" ]; then
        sudo ln -sfn "$DOTFILES_DIR/system/zram-generator.conf" /etc/systemd/zram-generator.conf
        log "  Linked zram-generator config"
    fi

    # --- Build vm CLI ---
    if command -v go &>/dev/null && [ -d "$DOTFILES_DIR/vm" ]; then
        log "Building vm CLI..."
        (cd "$DOTFILES_DIR/vm" && go build -o "$LOCAL_BIN/vm")
        log "  Built vm → $LOCAL_BIN/vm"
    else
        warn "Go not available or vm/ source not found — skipping vm CLI build."
    fi

    # --- Set fish as default shell ---
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

    log "Stage 4 complete."
}

# =============================================================================
# Stage 5 — Incus Initialization
# =============================================================================
stage_5_incus() {
    log "Stage 5 — Initializing Incus..."

    if ! groups | grep -q incus-admin; then
        sudo usermod -aG incus-admin "$USER"
        warn "Added $USER to incus-admin group. Takes effect on next login."
    fi

    local preseed="$DOTFILES_DIR/system/incus-preseed.yaml"
    if [ -f "$preseed" ]; then
        if sudo incus profile show default 2>/dev/null | grep -q "eth0"; then
            log "Incus already initialized, skipping."
        else
            sudo systemctl enable --now incus
            sleep 2
            cat "$preseed" | sudo incus admin init --preseed
            log "  Incus initialized from preseed"
        fi
    else
        warn "Incus preseed not found — skipping."
    fi

    log "Stage 5 complete."
}

# =============================================================================
# Stage 6 — systemd Services
# =============================================================================
stage_6_services() {
    log "Stage 6 — Enabling systemd services..."

    local services=(
        incus
        systemd-resolved
        NetworkManager
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

    # Pipewire runs as user service
    local user_services=(pipewire pipewire-pulse wireplumber)
    for svc in "${user_services[@]}"; do
        if systemctl --user is-enabled "$svc" &>/dev/null; then
            log "  $svc (user) already enabled"
        else
            systemctl --user enable --now "$svc" 2>/dev/null || log "  $svc (user) — enable on next graphical login"
        fi
    done

    sudo systemctl restart systemd-resolved

    log "Stage 6 complete."
}

# =============================================================================
# Stage 7 — Golden Image Build (optional)
# =============================================================================
stage_7_images() {
    log "Stage 7 — Golden image build (skipped — run manually when ready)"
    log "  vm image build personal v1.0.0"
    log "  vm image build work v1.0.0"
}

# =============================================================================
# Main
# =============================================================================
main() {
    log "========================================="
    log "Bootstrap starting..."
    log "Dotfiles: $DOTFILES_DIR"
    log "========================================="

    stage_1_system_packages
    stage_2_nix
    stage_3_nix_tooling
    stage_4_system_and_vm
    stage_5_incus
    stage_6_services
    stage_7_images

    log "========================================="
    log "Bootstrap complete!"
    log "========================================="
    log ""
    log "Next steps:"
    log "  1. Log out and back in (group membership + fish shell)"
    log "  2. Start Sway from TTY: sway"
    log "  3. Build golden images: vm image build personal v1.0.0"
    log "  4. First project: vm start myproject --repo <url>"
}

main "$@"
