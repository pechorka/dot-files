#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Bootstrap Script
# Turns a fresh Arch install into a fully configured development workstation.
#
# Usage:
#   ./bootstrap.sh
#   ./bootstrap.sh --context arch-chroot --target-user your-username
#
# Safe to run multiple times (idempotent).
# =============================================================================

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTEXT="installed-system"
TARGET_USER=""
TARGET_HOME=""
TARGET_GROUP=""
CURRENT_USER="$(id -un)"
LOCAL_BIN=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[bootstrap]${NC} $1"; }
warn() { echo -e "${YELLOW}[bootstrap]${NC} $1"; }
error() { echo -e "${RED}[bootstrap]${NC} $1" >&2; }
die() { error "$1"; exit 1; }

usage() {
    cat <<'EOF'
Usage: ./bootstrap.sh [--context installed-system|arch-chroot] [--target-user USER]

Options:
  --context      Execution context. Defaults to installed-system.
  --target-user  Login user that should own user-scoped setup.
  -h, --help     Show this help text.
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --context)
                [ "$#" -ge 2 ] || die "--context requires a value"
                CONTEXT="$2"
                shift 2
                ;;
            --target-user)
                [ "$#" -ge 2 ] || die "--target-user requires a value"
                TARGET_USER="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done
}

is_chroot_context() {
    [ "$CONTEXT" = "arch-chroot" ]
}

as_root() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

run_as_target_user() {
    if [ "${EUID:-$(id -u)}" -ne 0 ] && [ "$CURRENT_USER" = "$TARGET_USER" ] && [ "${HOME:-}" = "$TARGET_HOME" ]; then
        "$@"
    else
        sudo -u "$TARGET_USER" -H "$@"
    fi
}

resolve_runtime() {
    case "$CONTEXT" in
        installed-system|arch-chroot)
            ;;
        *)
            die "Unsupported context: $CONTEXT"
            ;;
    esac

    if [ -z "$TARGET_USER" ]; then
        TARGET_USER="${SUDO_USER:-$USER}"
    fi

    id "$TARGET_USER" >/dev/null 2>&1 || die "Target user does not exist: $TARGET_USER"

    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    [ -n "$TARGET_HOME" ] || die "Could not determine home directory for $TARGET_USER"

    TARGET_GROUP="$(id -gn "$TARGET_USER")"
    LOCAL_BIN="$TARGET_HOME/.local/bin"
}

install_managed_file() {
    local src="$1"
    local dest="$2"
    local mode="${3:-644}"

    if [ ! -f "$src" ]; then
        warn "Missing managed file: $src"
        return 1
    fi

    if as_root test -L "$dest"; then
        as_root rm -f "$dest"
    fi

    as_root install -Dm"$mode" "$src" "$dest"
}

install_target_user_file() {
    local src="$1"
    local dest="$2"
    local mode="${3:-644}"

    if [ ! -f "$src" ]; then
        warn "Missing managed file: $src"
        return 1
    fi

    if [ "${EUID:-$(id -u)}" -ne 0 ] && [ "$CURRENT_USER" = "$TARGET_USER" ]; then
        if [ -L "$dest" ]; then
            rm -f "$dest"
        fi
        install -Dm"$mode" "$src" "$dest"
        return 0
    fi

    if as_root test -L "$dest"; then
        as_root rm -f "$dest"
    fi

    as_root install -o "$TARGET_USER" -g "$TARGET_GROUP" -Dm"$mode" "$src" "$dest"
}

set_snapper_value() {
    local key="$1"
    local value="$2"

    as_root sed -i "s/^${key}=.*/${key}=\"${value}\"/" /etc/snapper/configs/root
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
        return
    fi

    if is_chroot_context; then
        as_root systemctl enable "$svc" &>/dev/null
    else
        as_root systemctl enable --now "$svc" &>/dev/null
    fi
    log "  Enabled $svc"
}

disable_system_service() {
    local svc="$1"

    if is_chroot_context; then
        if systemctl is-enabled "$svc" &>/dev/null; then
            as_root systemctl disable "$svc" &>/dev/null || true
            log "  Disabled $svc"
        else
            log "  $svc already disabled"
        fi
        return
    fi

    if systemctl is-enabled "$svc" &>/dev/null || systemctl is-active "$svc" &>/dev/null; then
        as_root systemctl disable --now "$svc" &>/dev/null || as_root systemctl disable "$svc" &>/dev/null || true
        log "  Disabled $svc"
    else
        log "  $svc already disabled"
    fi
}

enable_global_user_service() {
    local svc="$1"

    if as_root systemctl --global is-enabled "$svc" &>/dev/null; then
        log "  $svc (global user) already enabled"
    else
        as_root systemctl --global enable "$svc" &>/dev/null
        log "  Enabled $svc for future user logins"
    fi
}

ensure_yay() {
    if command -v yay &>/dev/null; then
        log "yay already installed, skipping."
        return
    fi

    log "Installing yay (AUR helper)..."
    run_as_target_user bash <<'EOF'
set -euo pipefail
yay_tmp=$(mktemp -d)
trap 'rm -rf "$yay_tmp"' EXIT
git clone https://aur.archlinux.org/yay.git "$yay_tmp/yay"
cd "$yay_tmp/yay"
makepkg -si --noconfirm
EOF
}

# =============================================================================
# Stage 1 — System Packages (pacman + AUR)
# =============================================================================
stage_1_packages() {
    log "Stage 1 — Installing packages via pacman..."

    log "Refreshing package databases and upgrading the base system..."
    as_root pacman -Syyu --noconfirm

    # Resolve iptables conflict (needed by some packages)
    if pacman -Qi iptables &>/dev/null && ! pacman -Qi iptables-nft &>/dev/null; then
        log "Replacing iptables with iptables-nft..."
        as_root pacman -S --needed --noconfirm --ask 4 iptables-nft
    fi

    # Pre-install noto-fonts to satisfy ttf-font dependency without prompt
    as_root pacman -S --needed --noconfirm noto-fonts

    local packages=(
        # Display & compositor
        sway
        swaylock
        swayidle
        xdg-desktop-portal-wlr
        xorg-xwayland
        wdisplays

        # Audio
        pipewire
        pipewire-pulse
        pipewire-jack
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
        crun
        podman

        # Virtual machines (quickemu / qemu extras)
        qemu-ui-gtk
        qemu-chardev-spice
        qemu-audio-pipewire
        qemu-hw-display-virtio-vga
        qemu-ui-spice-core
        spice-gtk
        qemu-hw-display-virtio-gpu
        qemu-hw-usb-redirect

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
        cups
        system-config-printer
        avahi
        nss-mdns
        ipp-usb
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

    as_root pacman -S --needed --noconfirm "${packages[@]}"

    ensure_yay

    local aur_packages=(ghostty yq-go neovim-nightly-bin quickemu handy)
    for pkg in "${aur_packages[@]}"; do
        if ! pacman -Qi "$pkg" &>/dev/null; then
            log "Installing $pkg from AUR..."
            run_as_target_user yay -S --needed --noconfirm "$pkg"
        fi
    done

    # Initialize Rust toolchain via rustup (pacman installs rustup, not rustc directly)
    if ! run_as_target_user rustup show active-toolchain &>/dev/null; then
        log "Installing Rust stable toolchain..."
        run_as_target_user rustup default stable
        run_as_target_user rustup component add rust-analyzer clippy rustfmt
    fi

    # Configure snapper for btrfs root snapshots
    if [ ! -f /etc/snapper/configs/root ]; then
        log "Configuring snapper..."

        # Snapper create-config expects /.snapshots not to already be mounted/present
        if mountpoint -q /.snapshots; then
            as_root umount /.snapshots
        fi

        if [ -e /.snapshots ]; then
            as_root rm -rf /.snapshots
        fi

        as_root snapper -c root create-config /

        # Replace Snapper-created subvolume with our dedicated @snapshots subvolume
        if as_root btrfs subvolume show /.snapshots &>/dev/null 2>&1; then
            as_root btrfs subvolume delete /.snapshots
        else
            as_root rm -rf /.snapshots 2>/dev/null || true
        fi

        as_root mkdir -p /.snapshots

        local root_dev
        root_dev="$(findmnt -n -o SOURCE /)"
        root_dev="${root_dev%%\[*}"
        as_root mount -o subvol=@snapshots,compress=zstd,noatime "$root_dev" /.snapshots

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

    as_root install -d -o "$TARGET_USER" -g "$TARGET_GROUP" "$LOCAL_BIN"

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

    if is_chroot_context; then
        log "  Skipping live service activation in arch-chroot context"
    else
        as_root systemctl daemon-reload
        if as_root systemctl start systemd-zram-setup@zram0.service; then
            log "  Activated zram swap"
        else
            warn "  Failed to activate zram swap"
        fi
    fi

    if run_as_target_user fish -c "hide_app avahi-discover btop bssh bvnc jconsole-java-openjdk jshell-java-openjdk nvim qv4l2 qvidcap vim"; then
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
            echo "$fish_path" | as_root tee -a /etc/shells >/dev/null
            log "  Added $fish_path to /etc/shells"
        fi

        local current_shell
        current_shell="$(getent passwd "$TARGET_USER" | cut -d: -f7)"

        if [ "$current_shell" != "$fish_path" ]; then
            if is_chroot_context || [ "$CURRENT_USER" != "$TARGET_USER" ]; then
                as_root usermod -s "$fish_path" "$TARGET_USER"
            else
                chsh -s "$fish_path"
            fi
            log "  Default shell changed to fish for $TARGET_USER"
        fi
    else
        warn "fish not found — skipping shell change."
    fi

    if [ -f "$DOTFILES_DIR/git/gitconfig" ]; then
        install_target_user_file "$DOTFILES_DIR/git/gitconfig" "$TARGET_HOME/.gitconfig"
        log "  Installed $TARGET_HOME/.gitconfig"
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
        cups.service
        avahi-daemon.service
        bluetooth.service
        snapper-cleanup.timer
        tlp.service
    )

    for svc in "${services[@]}"; do
        enable_system_service "$svc"
    done

    if is_chroot_context; then
        log "  Skipping tlp.service restart in arch-chroot context"
    elif as_root systemctl restart tlp.service &>/dev/null; then
        log "  Reapplied tlp.service"
    else
        warn "  Failed to reapply tlp.service"
    fi

    local user_services=(pipewire pipewire-pulse wireplumber)
    if is_chroot_context; then
        for svc in "${user_services[@]}"; do
            enable_global_user_service "$svc"
        done
    else
        for svc in "${user_services[@]}"; do
            if systemctl --user is-enabled "$svc" &>/dev/null; then
                log "  $svc (user) already enabled"
            else
                systemctl --user enable --now "$svc" 2>/dev/null || log "  $svc (user) — enable on next graphical login"
            fi
        done
    fi

    log "Stage 4 complete."
}

# =============================================================================
# Main
# =============================================================================
main() {
    parse_args "$@"
    resolve_runtime

    log "========================================="
    log "Bootstrap starting..."
    log "Dotfiles: $DOTFILES_DIR"
    log "Context: $CONTEXT"
    log "Target user: $TARGET_USER"
    log "========================================="

    stage_1_packages
    stage_2_system
    stage_3_shell
    stage_4_services

    log "========================================="
    log "Bootstrap complete!"
    log "========================================="
    log ""

    if is_chroot_context; then
        log "Next steps:"
        log "  1. Exit the installer environment"
        log "  2. Reboot into Arch"
        log "  3. Log in as $TARGET_USER and start Sway from TTY: sway"
        log "  4. Optional: run ./bootstrap-fingerprint.sh after first login"
    else
        log "Next steps:"
        log "  1. Log out and back in (for fish shell)"
        log "  2. Start Sway from TTY: sway"
        log "  3. Optional: run ./bootstrap-fingerprint.sh for swaylock + sudo fingerprint auth"
    fi
}

main "$@"
