#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MNT="/mnt"

EFI_PART_TYPE="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
LINUX_PART_TYPE="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
ALPINE_RELEASES_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/"

INSTALL_DISK=""
INSTALL_HOSTNAME=""
INSTALL_USER=""
INSTALL_TIMEZONE=""

EFI_PART=""
RECOVERY_PART=""
ROOT_PART=""

ALPINE_ARCHIVE=""
TEMP_SUDOERS_PATH=""

BASE_PACKAGES=(
    base
    linux
    linux-firmware
    intel-ucode
    btrfs-progs
    networkmanager
    sudo
    vim
    git
    snapper
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[install-arch]${NC} $1"; }
warn() { echo -e "${YELLOW}[install-arch]${NC} $1"; }
error() { echo -e "${RED}[install-arch]${NC} $1" >&2; }
die() { error "$1"; exit 1; }

cleanup_temp_artifacts() {
    if [ -n "$TEMP_SUDOERS_PATH" ] && [ -e "$TEMP_SUDOERS_PATH" ]; then
        rm -f "$TEMP_SUDOERS_PATH"
    fi

    if [ -n "$ALPINE_ARCHIVE" ] && [ -f "$ALPINE_ARCHIVE" ]; then
        rm -f "$ALPINE_ARCHIVE"
    fi
}

trap cleanup_temp_artifacts EXIT

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

preflight_checks() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || die "Run this script as root from the Arch live environment."
    [ -d /sys/firmware/efi ] || die "UEFI mode is required."
    [ -f "$DOTFILES_DIR/bootstrap.sh" ] || die "bootstrap.sh not found next to install-arch.sh"

    local required_commands=(
        arch-chroot
        blkid
        btrfs
        chroot
        curl
        genfstab
        lsblk
        mkfs.btrfs
        mkfs.ext4
        mkfs.fat
        mount
        mountpoint
        pacman-key
        pacstrap
        partprobe
        sfdisk
        tar
        udevadm
        umount
        wipefs
    )

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
}

confirm_destructive_action() {
    echo
    log "Install summary:"
    log "  Disk: $INSTALL_DISK"
    log "  Hostname: $INSTALL_HOSTNAME"
    log "  Username: $INSTALL_USER"
    log "  Timezone: $INSTALL_TIMEZONE"
    log "  Layout: EFI 1G, Recovery 2G (Alpine), root btrfs (remaining)"
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
size=2GiB,type=$LINUX_PART_TYPE,name="Recovery"
type=$LINUX_PART_TYPE,name="Arch Linux"
EOF

    partprobe "$INSTALL_DISK"
    udevadm settle

    EFI_PART="$(partition_path "$INSTALL_DISK" 1)"
    RECOVERY_PART="$(partition_path "$INSTALL_DISK" 2)"
    ROOT_PART="$(partition_path "$INSTALL_DISK" 3)"

    wait_for_block_device "$EFI_PART"
    wait_for_block_device "$RECOVERY_PART"
    wait_for_block_device "$ROOT_PART"
}

format_and_mount_filesystems() {
    log "Formatting target filesystems..."

    mkfs.fat -F 32 "$EFI_PART"
    mkfs.ext4 -L recovery "$RECOVERY_PART"
    mkfs.btrfs -f -L arch "$ROOT_PART"

    mount "$ROOT_PART" "$MNT"
    btrfs subvolume create "$MNT/@"
    btrfs subvolume create "$MNT/@home"
    btrfs subvolume create "$MNT/@var"
    btrfs subvolume create "$MNT/@nix"
    btrfs subvolume create "$MNT/@snapshots"
    umount "$MNT"

    mount -o subvol=@,compress=zstd,noatime "$ROOT_PART" "$MNT"
    mkdir -p "$MNT"/{home,var,nix,.snapshots,boot,recovery}
    mount -o subvol=@home,compress=zstd,noatime "$ROOT_PART" "$MNT/home"
    mount -o subvol=@var,compress=zstd,noatime "$ROOT_PART" "$MNT/var"
    mount -o subvol=@nix,compress=zstd,noatime "$ROOT_PART" "$MNT/nix"
    mount -o subvol=@snapshots,compress=zstd,noatime "$ROOT_PART" "$MNT/.snapshots"
    mount "$EFI_PART" "$MNT/boot"
    mount "$RECOVERY_PART" "$MNT/recovery"
}

install_arch_base() {
    log "Installing Arch base system..."

    pacman-key --init
    pacman-key --populate archlinux
    pacstrap -K "$MNT" "${BASE_PACKAGES[@]}"
    genfstab -U "$MNT" > "$MNT/etc/fstab"
}

configure_arch_system() {
    log "Configuring the installed Arch system..."

    arch-chroot "$MNT" /usr/bin/env \
        TARGET_HOSTNAME="$INSTALL_HOSTNAME" \
        TARGET_USER="$INSTALL_USER" \
        TARGET_TIMEZONE="$INSTALL_TIMEZONE" \
        /bin/bash -se <<'EOF'
set -euo pipefail

ensure_locale_enabled() {
    local locale="$1"

    if grep -qx "#$locale" /etc/locale.gen; then
        sed -i "s/^#$locale$/$locale/" /etc/locale.gen
    elif ! grep -qx "$locale" /etc/locale.gen; then
        printf '%s\n' "$locale" >> /etc/locale.gen
    fi
}

ln -sf "/usr/share/zoneinfo/$TARGET_TIMEZONE" /etc/localtime
hwclock --systohc

ensure_locale_enabled "en_US.UTF-8 UTF-8"
ensure_locale_enabled "ru_RU.UTF-8 UTF-8"
locale-gen

printf 'LANG=en_US.UTF-8\n' > /etc/locale.conf
printf '%s\n' "$TARGET_HOSTNAME" > /etc/hostname

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    useradd -m -G wheel -s /bin/bash "$TARGET_USER"
fi

install -d -m 750 /etc/sudoers.d
cat > /etc/sudoers.d/10-wheel <<'SUDOERS'
%wheel ALL=(ALL:ALL) ALL
SUDOERS
chmod 440 /etc/sudoers.d/10-wheel

bootctl install
EOF
}

set_arch_passwords() {
    log "Set the root password for the new Arch install."
    arch-chroot "$MNT" passwd root

    log "Set the password for $INSTALL_USER."
    arch-chroot "$MNT" passwd "$INSTALL_USER"
}

copy_repo_into_target() {
    local target_repo="$MNT/home/$INSTALL_USER/.config"

    log "Copying this repo into the new system..."
    rm -rf "$target_repo"
    cp -aT "$DOTFILES_DIR" "$target_repo"
    arch-chroot "$MNT" chown -R "$INSTALL_USER:$INSTALL_USER" "/home/$INSTALL_USER/.config"
}

write_arch_boot_entry() {
    local root_uuid
    root_uuid="$(blkid -s UUID -o value "$ROOT_PART")"

    mkdir -p "$MNT/boot/loader/entries"
    cat > "$MNT/boot/loader/entries/arch.conf" <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=UUID=$root_uuid rootflags=subvol=@ rw
EOF
}

install_temporary_bootstrap_sudoers() {
    TEMP_SUDOERS_PATH="$MNT/etc/sudoers.d/99-bootstrap-nopasswd"
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$INSTALL_USER" > "$TEMP_SUDOERS_PATH"
    chmod 440 "$TEMP_SUDOERS_PATH"
}

remove_temporary_bootstrap_sudoers() {
    if [ -n "$TEMP_SUDOERS_PATH" ] && [ -e "$TEMP_SUDOERS_PATH" ]; then
        rm -f "$TEMP_SUDOERS_PATH"
    fi
    TEMP_SUDOERS_PATH=""
}

run_bootstrap_in_chroot() {
    log "Running bootstrap inside arch-chroot..."

    install_temporary_bootstrap_sudoers
    arch-chroot "$MNT" /bin/bash -lc "cd /home/$INSTALL_USER/.config && ./bootstrap.sh --context arch-chroot --target-user $INSTALL_USER"
    remove_temporary_bootstrap_sudoers
}

find_latest_alpine_minrootfs() {
    curl -fsSL "$ALPINE_RELEASES_URL" \
        | grep -oE 'alpine-minirootfs-[0-9.]+-x86_64\.tar\.gz' \
        | sort -V \
        | tail -n1
}

cleanup_recovery_bind_mounts() {
    local path
    for path in run sys proc dev; do
        if mountpoint -q "$MNT/recovery/$path"; then
            umount "$MNT/recovery/$path"
        fi
    done
}

write_recovery_boot_entry() {
    local recovery_uuid
    recovery_uuid="$(blkid -s UUID -o value "$RECOVERY_PART")"

    mkdir -p "$MNT/boot/loader/entries"
    cat > "$MNT/boot/loader/entries/recovery.conf" <<EOF
title   Recovery (Alpine)
linux   /alpine/vmlinuz-alpine
initrd  /alpine/initramfs-alpine
options root=UUID=$recovery_uuid rw
EOF
}

install_alpine_recovery() {
    log "Installing Alpine recovery system..."

    local archive_name
    archive_name="$(find_latest_alpine_minrootfs)"
    [ -n "$archive_name" ] || die "Could not determine the latest Alpine minirootfs filename."

    ALPINE_ARCHIVE="$(mktemp /tmp/alpine-minirootfs.XXXXXX.tar.gz)"
    curl -fL "$ALPINE_RELEASES_URL$archive_name" -o "$ALPINE_ARCHIVE"
    tar xzf "$ALPINE_ARCHIVE" -C "$MNT/recovery"

    (
        trap cleanup_recovery_bind_mounts EXIT

        mount --bind /dev "$MNT/recovery/dev"
        mount --bind /proc "$MNT/recovery/proc"
        mount --bind /sys "$MNT/recovery/sys"
        mount --bind /run "$MNT/recovery/run"

        cp /etc/resolv.conf "$MNT/recovery/etc/resolv.conf"
        chroot "$MNT/recovery" /bin/sh -ec 'apk update && apk add btrfs-progs vim e2fsprogs dosfstools util-linux linux-lts'

        log "Set the root password for Alpine recovery."
        chroot "$MNT/recovery" /bin/sh -c 'passwd root'
    )

    mkdir -p "$MNT/boot/alpine"
    cp "$MNT/recovery/boot/vmlinuz-lts" "$MNT/boot/alpine/vmlinuz-alpine"
    cp "$MNT/recovery/boot/initramfs-lts" "$MNT/boot/alpine/initramfs-alpine"
    write_recovery_boot_entry
}

finalize_install() {
    log "Syncing filesystem state..."
    sync

    if mountpoint -q "$MNT"; then
        umount -R "$MNT"
    fi

    log "Install complete."
    log "Remove the USB drive and run: reboot"
}

main() {
    preflight_checks
    prompt_for_inputs
    confirm_destructive_action
    partition_disk
    format_and_mount_filesystems
    install_arch_base
    configure_arch_system
    set_arch_passwords
    copy_repo_into_target
    write_arch_boot_entry
    install_alpine_recovery
    run_bootstrap_in_chroot
    finalize_install
}

main "$@"
