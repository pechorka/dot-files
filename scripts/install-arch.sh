#!/usr/bin/env bash
# Arch Linux installer wrapper.
#
# Collects user input, builds archinstall JSON configs,
# hands off to archinstall, then copies the dotfiles repo
# into the new user's ~/.config so it's ready for bootstrap.
#
# Layout: EFI (1G, /efi) + BTRFS root (rest of disk)
# Bootloader: GRUB + grub-btrfs
#
# Usage (from the Arch live ISO, inside the cloned repo):
#   bash install-arch.sh
#   bash install-arch.sh --dry-run

set -euo pipefail

GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m' RED=$'\033[0;31m' BOLD=$'\033[1m' NC=$'\033[0m'
log()  { printf "${GREEN}[install-arch]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[install-arch]${NC} %s\n" "$*"; }
die()  { printf "${RED}[install-arch]${NC} %s\n" "$*" >&2; exit 1; }

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

if ! $DRY_RUN; then
  (( EUID == 0 )) || die "Run this script as root from the Arch live environment."
  [[ -d /sys/firmware/efi ]] || die "UEFI mode is required."
fi

# ── Input ────────────────────────────────────────────────────────────────────

prompt() {
  local label="$1" var="$2" validator="$3" errmsg="$4"
  while true; do
    read -rp "$label: " "$var"
    $validator "${!var}" && return
    warn "$errmsg"
  done
}

valid_hostname() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]]; }
valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]; }
valid_timezone() { [[ -f "/usr/share/zoneinfo/$1" ]]; }
valid_disk() {
  [[ -b "$1" ]] || { warn "Not a valid block device."; return 1; }
  lsblk -nrpo MOUNTPOINT "$1" 2>/dev/null | grep -q . && { warn "Disk has mounted filesystems. Unmount first."; return 1; }
  return 0
}

log "Available disks:"
lsblk -d -e 7,11 -o PATH,SIZE,MODEL --noheadings
echo

prompt "Install target disk (e.g. /dev/nvme0n1)" DISK    valid_disk     ""
prompt "Hostname"                                HOSTNAME valid_hostname "Use letters, numbers, and hyphens."
prompt "Username"                                USERNAME valid_username "Use a lowercase Linux username."
log "Timezone examples: Europe/Berlin, America/New_York, Asia/Almaty"
prompt "Timezone"                                TIMEZONE valid_timezone "Not found in /usr/share/zoneinfo."

echo
read -rp "Root password: " ROOT_PASSWORD
read -rp "User password (for $USERNAME): " USER_PASSWORD

# ── Confirm ──────────────────────────────────────────────────────────────────

echo
log "Install summary:"
log "  Disk:       $DISK"
log "  Hostname:   $HOSTNAME"
log "  Username:   $USERNAME"
log "  Timezone:   $TIMEZONE"
log "  Layout:     EFI 1G (/efi) + BTRFS (rest)"
log "  Subvolumes: @, @home, @log, @pkg"
log "  Bootloader: GRUB + grub-btrfs"
log "  Dotfiles:   $DOTFILES_DIR → /home/$USERNAME/.config/dot-files"
echo
warn "This will wipe every partition on ${BOLD}${DISK}${NC}."
read -rp "Type WIPE to continue: " answer
[[ "$answer" == "WIPE" ]] || die "Install aborted."

# ── Generate configs ─────────────────────────────────────────────────────────

UUID1=$(cat /proc/sys/kernel/random/uuid)
UUID2=$(cat /proc/sys/kernel/random/uuid)

# Compute BTRFS partition size: total disk minus 1 GiB for EFI minus 2 MiB for GPT backup header
DISK_BYTES=$(lsblk -bdno SIZE "$DISK" | head -1)
BTRFS_SIZE_MIB=$(( (DISK_BYTES / 1048576) - (1024 * 2) ))

CONFIG=$(cat <<EOF
{
  "archinstall-language": "English",
  "audio_config": null,
  "bootloader_config": { "bootloader": "Grub", "uki": false, "removable": false },
  "debug": false,
  "disk_config": {
    "config_type": "manual_partitioning",
    "device_modifications": [{
      "device": "$DISK",
      "partitions": [
        {
          "dev_path": null,
          "btrfs": [], "flags": ["Boot", "ESP"], "fs_type": "fat32",
          "size": { "sector_size": { "value": 512, "unit": "B" }, "unit": "GiB", "value": 1 },
          "mount_options": [], "mountpoint": "/efi",
          "obj_id": "$UUID1",
          "start": { "sector_size": { "value": 512, "unit": "B" }, "unit": "MiB", "value": 1 },
          "status": "create", "type": "primary"
        },
        {
          "dev_path": null,
          "btrfs": [
            { "name": "@",     "mountpoint": "/" },
            { "name": "@home", "mountpoint": "/home" },
            { "name": "@log",  "mountpoint": "/var/log" },
            { "name": "@pkg",  "mountpoint": "/var/cache/pacman/pkg" }
          ],
          "flags": [], "fs_type": "btrfs",
          "size": { "sector_size": { "value": 512, "unit": "B" }, "unit": "MiB", "value": $BTRFS_SIZE_MIB },
          "mount_options": ["compress=zstd", "noatime"],
          "mountpoint": null,
          "obj_id": "$UUID2",
          "start": { "sector_size": { "value": 512, "unit": "B" }, "unit": "MiB", "value": 1025 },
          "status": "create", "type": "primary"
        }
      ],
      "wipe": true
    }]
  },
  "hostname": "$HOSTNAME",
  "kernels": ["linux"],
  "locale_config": { "kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "en_US" },
  "network_config": { "type": "nm" },
  "no_pkg_lookups": false,
  "ntp": true,
  "offline": false,
  "packages": [
    "grub", "grub-btrfs", "efibootmgr", "btrfs-progs", "intel-ucode",
    "networkmanager", "sudo", "vim", "git", "python", "base-devel",
    "snapper", "snap-pac"
  ],
  "parallel downloads": 0,
  "swap": true,
  "timezone": "$TIMEZONE",
  "custom-commands": [
    "sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen",
    "sed -i 's/^#ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen",
    "locale-gen",
    "systemctl enable systemd-resolved",
    "pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com",
    "pacman-key --lsign-key 3056513887B78AEB",
    "pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'",
    "pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'",
    "printf '[chaotic-aur]\\nInclude = /etc/pacman.d/chaotic-mirrorlist\\n' >> /etc/pacman.conf"
  ]
}
EOF
)

CREDS=$(cat <<EOF
{
  "!root-password": "$ROOT_PASSWORD",
  "!users": [{ "!password": "$USER_PASSWORD", "sudo": true, "username": "$USERNAME" }]
}
EOF
)

# ── Run ──────────────────────────────────────────────────────────────────────

if $DRY_RUN; then
  log "Dry run — generated configs:"
  echo -e "\n${BOLD}=== user_configuration.json ===${NC}"
  echo "$CONFIG"
  echo -e "\n${BOLD}=== user_credentials.json ===${NC}"
  echo "$CREDS"
  exit 0
fi

tmpdir=$(mktemp -d --tmpdir archinstall-XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT

echo "$CONFIG" > "$tmpdir/user_configuration.json"
echo "$CREDS"  > "$tmpdir/user_credentials.json"

log "Handing off to archinstall..."
archinstall --config "$tmpdir/user_configuration.json" --creds "$tmpdir/user_credentials.json" --silent

# ── Copy dotfiles into the new system ────────────────────────────────────────

MOUNT_ROOT="/mnt/archinstall"
DEST="$MOUNT_ROOT/home/$USERNAME/.config/dot-files"

if [[ -d "$MOUNT_ROOT/home/$USERNAME" ]]; then
  log "Copying dotfiles to $DEST..."
  mkdir -p "$DEST"
  cp -a "$DOTFILES_DIR/." "$DEST/"
  arch-chroot "$MOUNT_ROOT" chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config/dot-files"
  log "Dotfiles installed."
else
  warn "$MOUNT_ROOT/home/$USERNAME not found — copy dotfiles manually after reboot."
fi

log "Install complete."
log ""
log "Next steps:"
log "  1. Reboot into Arch"
log "  2. Run: sudo bash ~/.config/dot-files/scripts/system-bootstrap.sh"
