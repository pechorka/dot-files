#!/usr/bin/env bash
set -euo pipefail

# bootstrap.sh
# Goal:
#   Debian (no DE) -> install minimal system deps -> install Nix -> run nix sync
#   -> set fish default shell + ghostty default terminal -> reboot -> sway session.
#
# Run:
#   sudo ./bootstrap.sh

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run this with sudo:  sudo ./bootstrap.sh"
  exit 1
fi

if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == "root" ]]; then
  echo "ERROR: Run via sudo from your normal user (not as root directly)."
  exit 1
fi

TARGET_USER="${SUDO_USER}"
TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Target user: ${TARGET_USER}"
echo "==> Target home: ${TARGET_HOME}"
echo "==> Dotfiles dir (script dir): ${SCRIPT_DIR}"

# Debian packages: keep this minimal and only for system services / basics.
# - NetworkManager daemon (GUI applet comes from Nix)
# - BlueZ daemon (GUI manager comes from Nix)
# - policykit for auth dialogs (agent comes from Nix)
# - pipewire stack for sound (pavucontrol comes from Nix)
export DEBIAN_FRONTEND=noninteractive

echo "==> Installing minimal system packages (apt)..."
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl xz-utils git \
  dbus-user-session \
  network-manager \
  bluez \
  policykit-1 \
  pipewire pipewire-pulse wireplumber

echo "==> Enabling system services..."
systemctl enable --now NetworkManager bluetooth || true

echo "==> Adding user to useful groups (wifi/bluetooth/backlight)..."
for grp in netdev bluetooth video; do
  if getent group "${grp}" >/dev/null; then
    usermod -aG "${grp}" "${TARGET_USER}" || true
  fi
done

# Install Nix (multi-user / daemon). Recommended for Linux+systemd. :contentReference[oaicite:1]{index=1}
# --yes makes it non-interactive. :contentReference[oaicite:2]{index=2}
if [[ ! -x /nix/var/nix/profiles/default/bin/nix ]]; then
  echo "==> Installing Nix (daemon, non-interactive)..."
  sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --daemon --yes
else
  echo "==> Nix already installed; skipping."
fi

NIX_BIN="/nix/var/nix/profiles/default/bin/nix"
if [[ ! -x "${NIX_BIN}" ]]; then
  echo "ERROR: nix not found at ${NIX_BIN}"
  exit 1
fi

# Make sure nix is in PATH for the child process; home-manager will need it.
export PATH="/nix/var/nix/profiles/default/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echo "==> Running initial sync (git pull + home-manager switch)..."
# Run as the target user so HOME/XDG are correct.
sudo -u "${TARGET_USER}" -H env PATH="${PATH}" \
  bash -lc "cd '${SCRIPT_DIR}/nix' && '${NIX_BIN}' run .#sync"

# Set fish as default login shell (fish installed via Nix during sync).
FISH_BIN="${TARGET_HOME}/.nix-profile/bin/fish"
if [[ -x "${FISH_BIN}" ]]; then
  echo "==> Setting fish as default shell: ${FISH_BIN}"
  grep -qxF "${FISH_BIN}" /etc/shells || echo "${FISH_BIN}" >> /etc/shells
  chsh -s "${FISH_BIN}" "${TARGET_USER}" || true
else
  echo "WARNING: fish not found at ${FISH_BIN}. Did sync succeed?"
fi

# Set Ghostty as the "default terminal" via /etc/environment (PAM reads this on login).
# Sway config also uses Ghostty directly (so this is mostly for other tools).
ensure_env_kv() {
  local key="$1"
  local val="$2"
  local file="/etc/environment"
  touch "${file}"
  if grep -qE "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${val}|g" "${file}"
  else
    echo "${key}=${val}" >> "${file}"
  fi
}

echo "==> Setting global login env vars (TERMINAL/EDITOR)..."
ensure_env_kv "TERMINAL" "ghostty"
ensure_env_kv "EDITOR" "nvim"

echo
echo "==> DONE."
echo "Next:"
echo "  1) Reboot (group/shell changes need a new login)."
echo "  2) Log in on TTY1 -> fish will auto-start sway."
echo "  3) Update later with:  cd ~/.config && nix run .#sync"
