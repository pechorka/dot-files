#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MNT="/mnt/archinstall"

EFI_PART_TYPE="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
LINUX_PART_TYPE="0FC63DAF-8483-4772-8E79-3D69D8477DE4"

INSTALL_DISK=""
INSTALL_HOSTNAME=""
INSTALL_USER=""
INSTALL_TIMEZONE=""
INSTALL_ROOT_PASSWORD=""
INSTALL_USER_PASSWORD=""

EFI_PART=""
ROOT_PART=""

TEMP_CONFIG_PATH=""
TEMP_CREDS_PATH=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[install-arch]${NC} $1"; }
warn() { echo -e "${YELLOW}[install-arch]${NC} $1"; }
error() { echo -e "${RED}[install-arch]${NC} $1" >&2; }
die() { error "$1"; exit 1; }

cleanup_temp_artifacts() {
    if [ -n "$TEMP_CONFIG_PATH" ] && [ -f "$TEMP_CONFIG_PATH" ]; then
        rm -f "$TEMP_CONFIG_PATH"
    fi

    if [ -n "$TEMP_CREDS_PATH" ] && [ -f "$TEMP_CREDS_PATH" ]; then
        rm -f "$TEMP_CREDS_PATH"
    fi
}

cleanup_target_mounts() {
    if mountpoint -q "$MNT"; then
        umount -R "$MNT" 2>/dev/null || umount -Rl "$MNT" 2>/dev/null || \
            warn "Automatic cleanup could not fully unmount $MNT. Run: umount -Rl $MNT"
    fi
}

cleanup_on_exit() {
    local exit_code=$?

    set +e
    cleanup_temp_artifacts

    if [ "$exit_code" -ne 0 ]; then
        warn "Installer exited early. Attempting to clean up mounts..."
        cleanup_target_mounts
    fi
}

trap cleanup_on_exit EXIT

require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

partition_path() {
    local disk="$1"
    local partno="$2"

    case "$disk" in
        *nvme*|*mmcblk*|*loop*)
            printf '%sp%s\n' "$disk" "$partno"
            ;;
        *)
            printf '%s%s\n' "$disk" "$partno"
            ;;
    esac
}

wait_for_block_device() {
    local path="$1"

    for _ in $(seq 1 20); do
        if [ -b "$path" ]; then
            return 0
        fi
        sleep 1
    done

    die "Timed out waiting for block device: $path"
}

subvolume_id() {
    local path="$1"
    btrfs subvolume show "$path" | awk -F': *' '/^Subvolume ID:/ {print $2; exit}'
}

validate_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

validate_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]]
}

validate_timezone() {
    [ -f "/usr/share/zoneinfo/$1" ]
}

validate_target_disk() {
    local disk="$1"

    [ -b "$disk" ] || return 1
    [ "$(lsblk -dnro TYPE "$disk")" = "disk" ] || return 1

    if lsblk -nrpo MOUNTPOINT "$disk" | grep -q '[^[:space:]]'; then
        return 2
    fi

    return 0
}

ensure_archinstall_present() {
    if command -v archinstall >/dev/null 2>&1; then
        return 0
    fi

    log "archinstall not found in the live environment. Installing it..."
    pacman -Sy --noconfirm archlinux-keyring archinstall
}

preflight_checks() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || die "Run this script as root from the Arch live environment."
    [ -d /sys/firmware/efi ] || die "UEFI mode is required."
    [ -f "$DOTFILES_DIR/bootstrap.sh" ] || die "bootstrap.sh not found next to install-arch.sh"

    local required_commands=(
        arch-chroot
        blockdev
        btrfs
        curl
        lsblk
        mkfs.btrfs
        mkfs.fat
        mount
        mountpoint
        openssl
        partprobe
        python
        sfdisk
        udevadm
        umount
        wipefs
    )

    ensure_archinstall_present

    for cmd in "${required_commands[@]}"; do
        require_command "$cmd"
    done

    if mountpoint -q "$MNT"; then
        die "$MNT is already mounted. Unmount it before running the installer."
    fi

    if ! curl -fsI https://archlinux.org/ >/dev/null; then
        die "Internet connectivity is required. Connect to the network and retry."
    fi
}

prompt_for_password() {
    local var_name="$1"
    local label="$2"
    local first=""
    local second=""

    while :; do
        read -r -s -p "$label: " first
        echo
        [ -n "$first" ] || {
            warn "Password cannot be empty."
            continue
        }

        read -r -s -p "Confirm $label: " second
        echo

        if [ "$first" != "$second" ]; then
            warn "Passwords do not match."
            continue
        fi

        printf -v "$var_name" '%s' "$first"
        return 0
    done
}

prompt_for_inputs() {
    log "Available target disks:"
    lsblk -d -e 7,11 -o PATH,SIZE,MODEL
    echo

    while :; do
        local disk_status
        read -r -p "Install target disk (for example /dev/nvme0n1): " INSTALL_DISK
        if validate_target_disk "$INSTALL_DISK"; then
            break
        else
            disk_status=$?
        fi

        case "$disk_status" in
            1) warn "That path is not an installable disk." ;;
            2) warn "That disk has mounted filesystems. Unmount them first." ;;
            *) warn "Unexpected disk validation result." ;;
        esac
    done

    while :; do
        read -r -p "Hostname: " INSTALL_HOSTNAME
        validate_hostname "$INSTALL_HOSTNAME" && break
        warn "Use letters, numbers, and hyphens only."
    done

    while :; do
        read -r -p "Username: " INSTALL_USER
        validate_username "$INSTALL_USER" && break
        warn "Use a lowercase Linux username, for example pechor."
    done

    log "Timezone examples: Europe/Berlin, America/New_York, Asia/Almaty"
    while :; do
        read -r -p "Timezone: " INSTALL_TIMEZONE
        validate_timezone "$INSTALL_TIMEZONE" && break
        warn "That timezone does not exist in /usr/share/zoneinfo."
    done

    prompt_for_password INSTALL_ROOT_PASSWORD "Root password"
    prompt_for_password INSTALL_USER_PASSWORD "Password for $INSTALL_USER"
}

confirm_destructive_action() {
    echo
    log "Install summary:"
    log "  Disk: $INSTALL_DISK"
    log "  Hostname: $INSTALL_HOSTNAME"
    log "  Username: $INSTALL_USER"
    log "  Timezone: $INSTALL_TIMEZONE"
    log "  Layout: EFI 1G, root btrfs (remaining)"

    echo
    warn "This will wipe every partition on $INSTALL_DISK."

    local confirmation
    read -r -p "Type WIPE to continue: " confirmation
    [ "$confirmation" = "WIPE" ] || die "Install aborted."
}

partition_disk() {
    log "Partitioning $INSTALL_DISK..."

    wipefs -af "$INSTALL_DISK"

    sfdisk --wipe always --wipe-partitions always "$INSTALL_DISK" <<EOF
label: gpt

size=1GiB,type=$EFI_PART_TYPE,name="EFI System"
type=$LINUX_PART_TYPE,name="Arch Linux"
EOF

    partprobe "$INSTALL_DISK"
    udevadm settle

    EFI_PART="$(partition_path "$INSTALL_DISK" 1)"
    ROOT_PART="$(partition_path "$INSTALL_DISK" 2)"

    wait_for_block_device "$EFI_PART"
    wait_for_block_device "$ROOT_PART"
}

mount_btrfs_layout() {
    mount -o compress=zstd,noatime "$ROOT_PART" "$MNT"
    mkdir -p "$MNT"/{home,var,nix,.snapshots,boot}
    mount -o subvol=@home,compress=zstd,noatime "$ROOT_PART" "$MNT/home"
    mount -o subvol=@var,compress=zstd,noatime "$ROOT_PART" "$MNT/var"
    mount -o subvol=@nix,compress=zstd,noatime "$ROOT_PART" "$MNT/nix"
    mount -o subvol=@snapshots,compress=zstd,noatime "$ROOT_PART" "$MNT/.snapshots"
    mount "$EFI_PART" "$MNT/boot"
}

format_and_mount_filesystems() {
    log "Formatting target filesystems..."

    mkfs.fat -F 32 -n EFI "$EFI_PART"
    mkfs.btrfs -f -L arch "$ROOT_PART"

    mount "$ROOT_PART" "$MNT"
    btrfs subvolume create "$MNT/@"
    btrfs subvolume create "$MNT/@home"
    btrfs subvolume create "$MNT/@var"
    btrfs subvolume create "$MNT/@nix"
    btrfs subvolume create "$MNT/@snapshots"

    local root_subvol_id
    root_subvol_id="$(subvolume_id "$MNT/@")"
    [ -n "$root_subvol_id" ] || die "Could not determine the initial root subvolume ID."
    btrfs subvolume set-default "$root_subvol_id" "$MNT"
    umount "$MNT"

    mount_btrfs_layout
}

ensure_target_mounted() {
    if mountpoint -q "$MNT"; then
        return 0
    fi

    mkdir -p "$MNT"
    mount_btrfs_layout
}

write_archinstall_inputs() {
    log "Generating archinstall config..."

    TEMP_CONFIG_PATH="$(mktemp /tmp/install-arch.config.XXXXXX.json)"
    TEMP_CREDS_PATH="$(mktemp /tmp/install-arch.creds.XXXXXX.json)"

    local user_password_hash
    user_password_hash="$(openssl passwd -6 "$INSTALL_USER_PASSWORD")"

    export TEMP_CONFIG_PATH
    export TEMP_CREDS_PATH
    export INSTALL_HOSTNAME
    export INSTALL_TIMEZONE
    export INSTALL_USER
    export INSTALL_ROOT_PASSWORD
    export INSTALL_USER_PASSWORD_HASH="$user_password_hash"
    export MNT

    python <<'PY'
import json
import os
from pathlib import Path

config = {
    "additional-repositories": [],
    "archinstall-language": "English",
    "audio_config": None,
    "bootloader_config": {
        "bootloader": "grub",
        "uki": False,
        "removable": False,
    },
    "bootloader": "grub",
    "debug": False,
    "disk_config": {
        "config_type": "pre_mounted_config",
        "mountpoint": os.environ["MNT"],
    },
    "hostname": os.environ["INSTALL_HOSTNAME"],
    "kernels": ["linux"],
    "locale_config": {
        "kb_layout": "us",
        "sys_enc": "UTF-8",
        "sys_lang": "en_US",
    },
    "mirror_config": {},
    "network_config": {},
    "no_pkg_lookups": False,
    "ntp": True,
    "offline": False,
    "packages": [
        "btrfs-progs",
        "efibootmgr",
        "git",
        "grub",
        "intel-ucode",
        "linux-firmware",
        "networkmanager",
        "sudo",
        "vim",
    ],
    "parallel downloads": 0,
    "profile_config": None,
    "save_config": None,
    "script": "guided",
    "silent": True,
    "swap": False,
    "timezone": os.environ["INSTALL_TIMEZONE"],
    "version": "2.6.0",
}

creds = {
    "root_enc_password": os.environ["INSTALL_ROOT_PASSWORD"],
    "users": {
        "username": os.environ["INSTALL_USER"],
        "enc_password": os.environ["INSTALL_USER_PASSWORD_HASH"],
        "sudo": True,
    },
}

Path(os.environ["TEMP_CONFIG_PATH"]).write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
Path(os.environ["TEMP_CREDS_PATH"]).write_text(json.dumps(creds, indent=2) + "\n", encoding="utf-8")
PY
}

run_archinstall() {
    log "Handing the mounted layout to archinstall..."
    archinstall --config "$TEMP_CONFIG_PATH" --creds "$TEMP_CREDS_PATH"
}

post_install_system_tweaks() {
    log "Applying post-install system tweaks..."

    ensure_target_mounted

    arch-chroot "$MNT" /bin/bash -se <<'EOF'
set -euo pipefail

enable_locale() {
    local locale="$1"
    if grep -qx "#$locale" /etc/locale.gen; then
        sed -i "s/^#$locale$/$locale/" /etc/locale.gen
    elif ! grep -qx "$locale" /etc/locale.gen; then
        printf '%s\n' "$locale" >> /etc/locale.gen
    fi
}

enable_locale "ru_RU.UTF-8 UTF-8"
locale-gen

install -d -m 750 /etc/sudoers.d
cat > /etc/sudoers.d/10-wheel <<'SUDOERS'
%wheel ALL=(ALL:ALL) ALL
SUDOERS
chmod 440 /etc/sudoers.d/10-wheel

# Keep root mounted via the btrfs default subvolume so snapper rollback works natively.
awk '
BEGIN { OFS="\t" }
$0 ~ /^[[:space:]]*#/ || NF == 0 { print; next }
$2 == "/" && $3 == "btrfs" {
    n = split($4, opts, ",")
    filtered = ""
    for (i = 1; i <= n; i++) {
        if (opts[i] ~ /^subvol=/ || opts[i] ~ /^subvolid=/) {
            continue
        }
        filtered = filtered (filtered ? "," : "") opts[i]
    }
    $4 = filtered
}
{ print }
' /etc/fstab > /etc/fstab.snapper-native
mv /etc/fstab.snapper-native /etc/fstab

ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable NetworkManager NetworkManager-wait-online systemd-resolved
EOF
}

finalize_install() {
    log "Syncing filesystem state..."
    sync
    cleanup_target_mounts

    log "Install complete."
    log "Reboot into Arch, connect to the network, clone your dotfiles, and run bootstrap.sh once."
}

main() {
    preflight_checks
    prompt_for_inputs
    confirm_destructive_action
    partition_disk
    format_and_mount_filesystems
    write_archinstall_inputs
    run_archinstall
    post_install_system_tweaks
    finalize_install
}

main "$@"
