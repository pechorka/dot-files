#!/usr/bin/env bash
# System bootstrap.
#
# Turns a fresh Arch install into a fully configured development workstation.
# Run once after first boot. Safe to run multiple times (idempotent).
#
# Usage:
#   sudo bash system-bootstrap.sh

set -euo pipefail

GREEN='\033[0;32m' YELLOW='\033[1;33m' RED='\033[0;31m' NC='\033[0m'
log()  { printf "${GREEN}[bootstrap]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[bootstrap]${NC} %s\n" "$*"; }
die()  { printf "${RED}[bootstrap]${NC} %s\n" "$*" >&2; exit 1; }

(( EUID == 0 )) || die "Run with sudo: sudo bash system-bootstrap.sh"

USER="${SUDO_USER:?run with sudo, not as root directly}"
USER_HOME="$(eval echo "~$USER")"
USER_ID="$(id -u "$USER")"
GROUP_ID="$(id -g "$USER")"
DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"

run_as_user() { sudo -u "$USER" -H -- "$@"; }
is_pkg()      { pacman -Qi "$1" &>/dev/null; }

install_system_file() {
  local src="$1" dest="$2" mode="${3:-644}"
  [[ -f "$src" ]] || return 1
  mkdir -p "$(dirname "$dest")"
  [[ -L "$dest" ]] && rm -f "$dest"
  cp -a "$src" "$dest" && chmod "$mode" "$dest"
}

install_user_file() {
  install_system_file "$@" || return 1
  chown "$USER_ID:$GROUP_ID" "$2"
}

log "Bootstrap starting... (dotfiles: $DOTFILES_DIR, user: $USER)"

# ── Packages ─────────────────────────────────────────────────────────────────

PACMAN_PACKAGES=(
  # Display & compositor
  sway swaylock swayidle xdg-desktop-portal-wlr xorg-xwayland wdisplays
  # Audio
  pipewire pipewire-pulse pipewire-jack sof-firmware wireplumber
  # Graphics (Intel)
  mesa vulkan-intel intel-media-driver
  # Browsers
  firefox chromium
  # Swap & power
  zram-generator tlp
  # Snapshots
  snapper snap-pac
  # Shells & editors
  ghostty fish tmux
  # CLI tools
  ripgrep fzf fd jq bat curl wget lazygit openssh less btop
  # Go
  go gopls
  # Rust
  rustup
  # JS/TS
  nodejs pnpm npm
  # JVM
  jdk-openjdk kotlin gradle
  # DB clients
  sqlite pgcli
  # Containers
  crun podman
  # QEMU / quickemu
  qemu-ui-gtk qemu-chardev-spice qemu-audio-pipewire
  qemu-hw-display-virtio-vga qemu-ui-spice-core spice-gtk
  qemu-hw-display-virtio-gpu qemu-hw-usb-redirect
  # Wayland tools
  wofi mako grim slurp wl-clipboard brightnessctl playerctl pamixer satty
  # System applets
  networkmanager cups system-config-printer avahi nss-mdns ipp-usb
  blueman pavucontrol lxqt-policykit
  # Fonts
  noto-fonts noto-fonts-emoji ttf-font-awesome ttf-liberation
  # Misc
  bubblewrap mise base-devel keychain
  # AUR (via chaotic-aur)
  neovim-nightly-bin quickemu
)

log "Upgrading system..."
pacman -Syyu --noconfirm

# ── Chaotic-AUR ─────────────────────────────────────────────────────────────

if ! grep -q '^\[chaotic-aur\]' /etc/pacman.conf; then
  log "Setting up chaotic-aur..."
  pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
  pacman-key --lsign-key 3056513887B78AEB
  pacman -U --noconfirm \
    'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
    'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
  printf '[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist\n' >> /etc/pacman.conf
  pacman -Sy --noconfirm
  log "Chaotic-AUR configured."
else
  log "Chaotic-AUR already configured."
fi

if is_pkg iptables && ! is_pkg iptables-nft; then
  log "Replacing iptables with iptables-nft..."
  pacman -S --needed --noconfirm --ask 4 iptables-nft
fi

log "Installing pacman packages..."
pacman -S --needed --noconfirm "${PACMAN_PACKAGES[@]}"

if run_as_user rustup show active-toolchain &>/dev/null; then
  log "Rust toolchain already configured"
else
  log "Installing Rust stable toolchain..."
  run_as_user rustup default stable
  run_as_user rustup component add rust-analyzer clippy rustfmt
fi

# ── Snapper ──────────────────────────────────────────────────────────────────

[[ -f /etc/snapper/configs/root ]] || snapper -c root create-config /
sed -i \
  -e 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' \
  -e 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="3"/' \
  -e 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="3"/' \
  /etc/snapper/configs/root
log "Snapper retention policy applied"

# ── System configs ───────────────────────────────────────────────────────────

mkdir -p "$USER_HOME/.local/bin"
chown "$USER_ID:$GROUP_ID" "$USER_HOME/.local/bin"

install_system_file "$DOTFILES_DIR/system/zram-generator.conf" /etc/systemd/zram-generator.conf \
  && log "Installed zram-generator config"
install_system_file "$DOTFILES_DIR/system/tlp.d/10-laptop-power.conf" /etc/tlp.d/10-laptop-power.conf \
  && log "Installed TLP power policy"

systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service 2>/dev/null \
  && log "Activated zram swap" \
  || warn "Failed to activate zram swap"

HIDDEN_APPS=(avahi-discover btop bssh bvnc jconsole-java-openjdk jshell-java-openjdk nvim qv4l2 qvidcap vim)
command -v fish &>/dev/null \
  && run_as_user fish -c "hide_app ${HIDDEN_APPS[*]}" 2>/dev/null \
  && log "Hidden desktop entries from launcher" || true

# ── Shell ────────────────────────────────────────────────────────────────────

if command -v fish &>/dev/null; then
  grep -qxF /usr/bin/fish /etc/shells || echo /usr/bin/fish >> /etc/shells
  current_shell="$(getent passwd "$USER" | cut -d: -f7)"
  if [[ "$current_shell" != "/usr/bin/fish" ]]; then
    usermod -s /usr/bin/fish "$USER"
    log "Default shell set to fish"
  fi
else
  warn "fish not found, skipping shell change"
fi

install_user_file "$DOTFILES_DIR/git/gitconfig" "$USER_HOME/.gitconfig" \
  && log "Installed .gitconfig"

# ── Services ─────────────────────────────────────────────────────────────────

for svc in power-profiles-daemon.service NetworkManager-wait-online.service snapper-timeline.timer; do
  systemctl disable --now "$svc" 2>/dev/null || true
done
log "Disabled unwanted services"

for svc in systemd-resolved NetworkManager cups.service avahi-daemon.service bluetooth.service snapper-cleanup.timer tlp.service; do
  systemctl enable --now "$svc" 2>/dev/null || true
done
log "Enabled system services"

systemctl restart tlp.service 2>/dev/null || true

for svc in pipewire pipewire-pulse wireplumber; do
  systemctl --global enable "$svc" 2>/dev/null || true
done
log "Enabled user services (global)"

# ── Done ─────────────────────────────────────────────────────────────────────

log "Bootstrap complete!"
log ""
log "Next steps:"
log "  1. Log out and back in (for fish shell)"
log "  2. Start Sway from TTY: sway"
log "  3. Optional: run ./bootstrap-fingerprint.sh"
