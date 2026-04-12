# Arch Linux Installation Guide

## Summary
This repo now uses a split install model:

- `install-arch.sh` owns the disk layout and hands the mounted target to `archinstall`
- `bootstrap.sh` owns workstation policy: packages, zram, GRUB snapshot integration, services, shell, and dotfiles
- GRUB + `grub-btrfs` replaces the old `systemd-boot` + Alpine recovery design

The install script gets you to a bootable base system. After first login, you run `bootstrap.sh` manually once.

## What The Installer Does
`./install-arch.sh` now performs these steps:

1. Validates that you are in the Arch live environment with UEFI and internet.
2. Partitions the target disk as:
   - `EFI` 1 GiB, FAT32
   - `root` remaining space, Btrfs labeled `arch`
3. Creates the Btrfs subvolumes:
   - `@`
   - `@home`
   - `@var`
   - `@nix`
   - `@snapshots`
4. Sets `@` as the initial Btrfs default subvolume so root boots in a Snapper-native way.
5. Mounts that layout at `/mnt/archinstall`.
6. Generates temporary `archinstall` config + creds files and runs `archinstall` in `pre_mounted_config` mode.
7. Applies a few post-install system tweaks in chroot: enables `NetworkManager` and `systemd-resolved`, restores the `wheel` sudo rule, ensures `ru_RU.UTF-8` is also generated, and removes any root `subvol=` pinning from `/etc/fstab`.

## Recommended Path

### 1. Boot The Official Arch ISO
Boot in UEFI mode and connect to the internet first.

For WiFi:

```bash
iwctl
station wlan0 scan
station wlan0 get-networks
station wlan0 connect "YourNetworkName"
exit
```

Verify connectivity:

```bash
ping -c 3 archlinux.org
```

### 2. Clone The Repo
```bash
git clone https://github.com/your-username/dotfiles.git ~/.config
cd ~/.config
```

### 3. Run The Installer
```bash
./install-arch.sh
```

It prompts for:

- target disk
- hostname
- username
- timezone
- root password
- user password

It will wipe the chosen disk.

### 4. Reboot
When the script finishes:

```bash
reboot
```

Remove the USB drive.

### 5. Run Bootstrap Manually Once
After the first reboot, log in, connect to the network if needed, clone the repo again into the installed system, and run:

```bash
git clone https://github.com/your-username/dotfiles.git ~/.config
cd ~/.config
./bootstrap.sh
```

## Bootstrap Outcome
`bootstrap.sh` now installs and configures:

- workstation packages
- `zram-generator`
- `snapper` + `snap-pac`
- GRUB defaults for a visible boot menu
- `grub-btrfs` + `grub-btrfsd.service`
- the `grub-btrfs-overlayfs` `mkinitcpio` hook
- the managed TLP config

It also:

- regenerates initramfs images
- regenerates `/boot/grub/grub.cfg`
- enables `grub-btrfsd.service` and `snapper-cleanup.timer`
- disables `snapper-timeline.timer`
- disables `NetworkManager-wait-online.service` after bootstrap is done
- sets the user GTK/libadwaita preference to dark so portals and browsers can expose `prefers-color-scheme: dark`

The retention policy is cleanup-only with `NUMBER_LIMIT=6` and `NUMBER_LIMIT_IMPORTANT=6`.

## Recovery Model
There is no separate Alpine recovery partition anymore.

Recovery now relies on:

- Btrfs root snapshots in `@snapshots`
- GRUB snapshot entries created by `grub-btrfs`
- overlayfs rescue boots via the `grub-btrfs-overlayfs` initramfs hook
- `snapper rollback` as the built-in way to promote a snapshot back into the normal boot path

That gives you on-device recovery without a USB stick, while keeping a single-OS disk layout.

### Rescue Boot
After snapshot-aware bootstrap has completed, GRUB shows a snapshots submenu.

Use it to boot a read-only rescue snapshot when the normal root is broken.

### Promote A Snapshot Back To Writable Root
With the root filesystem mounted via the Btrfs default subvolume, the built-in restore path is `snapper rollback`.

If you know the snapshot number you want:

```bash
sudo snapper -c root list
sudo snapper -c root rollback 12
sudo reboot
```

If you booted a read-only rescue snapshot from the GRUB snapshots menu and decided "this is the one I want to keep", run:

```bash
sudo snapper -c root rollback
sudo reboot
```

That creates a new writable snapshot and sets it as the Btrfs default subvolume for the next boot.

Your normal `/home` subvolume is not rolled back by this flow.

## Verification
After the manual bootstrap completes, verify:

```bash
zramctl
cat /proc/swaps
systemctl list-unit-files --state=enabled | rg 'NetworkManager|systemd-resolved|cups|avahi|grub-btrfs|snapper|tlp'
systemctl is-enabled NetworkManager-wait-online.service snapper-timeline.timer power-profiles-daemon.service 2>/dev/null || true
snapper -c root list
btrfs subvolume get-default /
grep '^HOOKS=' /etc/mkinitcpio.conf
grep '^GRUB_TIMEOUT' /etc/default/grub
grep '^GRUB_TIMEOUT_STYLE' /etc/default/grub
```

Expected results:

- `zram0` exists and is active swap
- `grub-btrfsd.service` and `snapper-cleanup.timer` are enabled
- `NetworkManager-wait-online.service` is no longer enabled
- `snapper-timeline.timer` is not enabled
- `btrfs subvolume get-default /` points at the current bootable root subvolume
- `/etc/mkinitcpio.conf` includes `grub-btrfs-overlayfs`
- `/etc/default/grub` uses a visible timeout-based menu

## Partition Layout

| Partition | Size | Filesystem | Mount |
|-----------|------|------------|-------|
| `p1` | 1 GiB | FAT32 | `/boot` |
| `p2` | rest of disk | Btrfs | `/` via the Btrfs default subvolume, initially `@` |

### Btrfs Subvolumes

| Subvolume | Mount Point | Purpose |
|-----------|-------------|---------|
| `@` | initial default for `/` | initial writable root |
| `@home` | `/home` | user data |
| `@var` | `/var` | variable state |
| `@nix` | `/nix` | reserved separate subtree |
| `@snapshots` | `/.snapshots` | Snapper snapshots |

No swap partition is created. Swap is provided by zram after bootstrap.
