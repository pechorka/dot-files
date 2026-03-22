# Arch Linux Installation Guide

## Context
This documents the installation of Arch Linux on a laptop (i7-1365U, 32GB RAM, fresh 2TB SSD) as the foundation for the developer PC architecture described in the companion requirements document. The root filesystem will be btrfs with zstd compression. Includes an Alpine Linux recovery partition for rollback without a USB drive.

---

## Phase 1 — Create Bootable USB (Windows)

### 1.1 Download Arch ISO
- Go to https://archlinux.org/download/
- Download the latest ISO (e.g., `archlinux-2026.03.01-x86_64.iso`)
- Optionally verify the checksum (SHA256 listed on the download page)

### 1.2 Download Rufus
- Go to https://rufus.ie/
- Download the latest portable version (no install needed)

### 1.3 Burn ISO to USB
- Plug in the 57GB USB drive
- Open Rufus
- Device: select your USB drive (Disk 2, ~57GB)
- Boot selection: click SELECT, choose the Arch ISO
- Partition scheme: **GPT**
- Target system: **UEFI (non CSM)**
- File system: leave default (Rufus handles this)
- Click START
- If prompted for write mode, choose **Write in ISO Image mode (Recommended)**
- Wait for completion — Rufus will wipe the existing EFI partition and unallocated space, this is fine
- Click CLOSE when done

---

## Phase 2 — Boot into Arch Live Environment

### 2.1 Enter BIOS/UEFI
- Reboot the laptop with USB plugged in
- Press the BIOS key during boot (usually F2, F12, DEL, or ESC — depends on your laptop manufacturer)
- Disable Secure Boot if enabled (Arch doesn't ship signed bootloaders by default)
- Set USB as first boot priority, or use the one-time boot menu (usually F12)
- Save and exit

### 2.2 Boot the USB
- Select "Arch Linux install medium" from the boot menu
- Wait for the live environment to load — you'll land at a root shell prompt

### 2.3 Verify UEFI Mode
```bash
cat /sys/firmware/efi/fw_platform_size
```
Should output `64`. If the file doesn't exist, you're in BIOS/legacy mode — go back to BIOS settings and make sure UEFI is enabled.

### 2.4 Connect to Internet
**Wired (easiest):** Should work automatically. Test with:
```bash
ping -c 3 archlinux.org
```

**WiFi:**
```bash
iwctl
station wlan0 scan
station wlan0 get-networks
station wlan0 connect "YourNetworkName"
# Enter password when prompted
exit
```
Then verify:
```bash
ping -c 3 archlinux.org
```

### 2.5 Update System Clock
```bash
timedatectl set-ntp true
```

---

## Phase 3 — Partition the 2TB SSD

### 3.1 Identify the Disk
```bash
lsblk
```
The 2TB SSD will likely be `/dev/nvme0n1` (NVMe) or `/dev/sda` (SATA). The guide assumes `/dev/nvme0n1` — substitute your actual device.

### 3.2 Partition Layout

| Partition | Size | Purpose |
|-----------|------|---------|
| nvme0n1p1 | 1 GB | EFI System (FAT32) |
| nvme0n1p2 | 2 GB | Recovery (Alpine Linux, ext4) |
| nvme0n1p3 | ~1.997 TB | Root (btrfs, zstd compression) |

No swap partition — zram (compressed swap in RAM) is configured later via bootstrap.sh. This avoids SSD wear and keeps the partition layout simple.

### 3.3 Partition with fdisk
```bash
fdisk /dev/nvme0n1
```

Create the partition table and partitions:
- Type `g` — create a new GPT partition table (wipes everything)
- Type `n` — new partition (EFI)
  - Partition number: 1 (default)
  - First sector: default
  - Last sector: `+1G`
- Type `t` — change partition type
  - Type: `1` (EFI System)
- Type `n` — new partition (Recovery)
  - Partition number: 2 (default)
  - First sector: default
  - Last sector: `+2G`
- Type `n` — new partition (Root — rest of disk)
  - Partition number: 3 (default)
  - First sector: default
  - Last sector: default (uses remaining space)
- Type `w` — write and exit

### 3.4 Verify Partitions
```bash
lsblk /dev/nvme0n1
```
Expected output:
```
nvme0n1        2TB
├─nvme0n1p1    1G     (EFI)
├─nvme0n1p2    2G     (Recovery)
└─nvme0n1p3    ~1.997T (Root)
```

---

## Phase 4 — Format Partitions

### 4.1 Format EFI Partition
```bash
mkfs.fat -F 32 /dev/nvme0n1p1
```

### 4.2 Format Recovery Partition
```bash
mkfs.ext4 -L recovery /dev/nvme0n1p2
```

### 4.3 Format Root as btrfs
```bash
mkfs.btrfs -f -L arch /dev/nvme0n1p3
```

### 4.4 Create btrfs Subvolumes
Mount the root partition first:
```bash
mount /dev/nvme0n1p3 /mnt
```

Create subvolumes for a clean snapshot/rollback layout:
```bash
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@nix
btrfs subvolume create /mnt/@snapshots
```

Unmount and remount with subvolumes and compression:
```bash
umount /mnt
mount -o subvol=@,compress=zstd,noatime /dev/nvme0n1p3 /mnt
mkdir -p /mnt/{home,var,nix,.snapshots,boot,recovery}
mount -o subvol=@home,compress=zstd,noatime /dev/nvme0n1p3 /mnt/home
mount -o subvol=@var,compress=zstd,noatime /dev/nvme0n1p3 /mnt/var
mount -o subvol=@nix,compress=zstd,noatime /dev/nvme0n1p3 /mnt/nix
mount -o subvol=@snapshots,compress=zstd,noatime /dev/nvme0n1p3 /mnt/.snapshots
```

### 4.5 Mount EFI and Recovery Partitions
```bash
mount /dev/nvme0n1p1 /mnt/boot
mount /dev/nvme0n1p2 /mnt/recovery
```

### 4.6 Verify Mounts
```bash
lsblk /dev/nvme0n1
```
Confirm all partitions are mounted to the right places.

---

## Phase 5 — Install Arch Base System

### 5.1 Initialize Pacman Keyring
The live environment's keyring may not be populated. Initialize and populate it before installing packages:
```bash
pacman-key --init
pacman-key --populate archlinux
```

### 5.2 Install Essential Packages
```bash
pacstrap -K /mnt base linux linux-firmware intel-ucode btrfs-progs networkmanager sudo vim git snapper
```

Breakdown:
- `base` — minimal Arch system
- `linux` — kernel
- `linux-firmware` — firmware blobs
- `intel-ucode` — microcode updates for i7-1365U
- `btrfs-progs` — btrfs filesystem tools
- `networkmanager` — networking (WiFi + wired)
- `sudo` — for non-root user
- `vim` — editor for post-install config (minimal, available before Nix)
- `git` — needed to clone dotfiles after first boot
- `snapper` — automatic btrfs snapshot management (pre-update rollback)

### 5.3 Generate fstab
```bash
genfstab -U /mnt >> /mnt/etc/fstab
```

Verify it looks correct:
```bash
cat /mnt/etc/fstab
```
Should show the btrfs subvolumes with `compress=zstd,noatime` options, the EFI partition, and the recovery partition.

---

## Phase 6 — Configure Arch

### 6.1 Chroot into New System
```bash
arch-chroot /mnt
```

### 6.2 Timezone
```bash
ln -sf /usr/share/zoneinfo/Region/City /etc/localtime
hwclock --systohc
```
Replace `Region/City` with your timezone (e.g., `Europe/Berlin`, `America/New_York`).

### 6.3 Locale
Edit `/etc/locale.gen` and uncomment both English and Russian locales:
```bash
vim /etc/locale.gen
```
Uncomment these two lines:
```
en_US.UTF-8 UTF-8
ru_RU.UTF-8 UTF-8
```

Generate locales:
```bash
locale-gen
```

Set system locale (English as default — Russian is available for apps that need it):
```bash
echo "LANG=en_US.UTF-8" > /etc/locale.conf
```

Note: keyboard layout switching (US/Russian) is configured in the Sway config, which lives in dotfiles and is set up during bootstrap.

### 6.4 Hostname
```bash
echo "your-hostname" > /etc/hostname
```

### 6.5 Root Password
```bash
passwd
```

### 6.6 Create User
```bash
useradd -m -G wheel -s /bin/bash your-username
passwd your-username
```

Enable sudo for wheel group:
```bash
EDITOR=vim visudo
```
Uncomment the line: `%wheel ALL=(ALL:ALL) ALL`

Note: the shell is bash for now — fish will come from Nix later and you'll change the default shell after bootstrap.

### 6.7 Snapper
Snapper configuration (config creation, snapshot subvolume fixup, limits, and snap-pac installation) is handled by `bootstrap.sh`. The bootstrap keeps `snapper-cleanup.timer` enabled, disables timeline snapshots, and caps retained `number` / `important` snapshots at `3` each.

### 6.8 Boot Loader (systemd-boot)
```bash
bootctl install
```

Create the Arch boot entry:
```bash
vim /boot/loader/entries/arch.conf
```

Contents (replace UUID with your root partition's UUID — get it with `blkid /dev/nvme0n1p3`):
```
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=UUID=YOUR-ROOT-UUID rootflags=subvol=@ rw
```

Set default entry:
```bash
vim /boot/loader/loader.conf
```

Contents:
```
default arch.conf
timeout 3
console-mode max
editor no
```

### 6.9 Enable Services
```bash
systemctl enable NetworkManager
systemctl enable systemd-resolved
systemctl enable snapper-cleanup.timer
```

Note: enabling `NetworkManager` also enables `NetworkManager-wait-online.service` via the packaged unit. `bootstrap.sh` disables that wait-online unit on the workstation profile after first boot.

### 6.10 Exit Chroot
```bash
exit
```

---

## Phase 7 — Install Alpine Recovery

This phase installs a minimal Alpine Linux on the recovery partition. You do this from the Arch live USB environment, NOT from inside the Arch chroot.

### 7.1 Download Alpine Mini Root Filesystem
```bash
cd /tmp
curl -LO https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/alpine-minirootfs-3.21.3-x86_64.tar.gz
```
Check https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/ for the exact latest filename.

### 7.2 Extract to Recovery Partition
The recovery partition should still be mounted at `/mnt/recovery`:
```bash
tar xzf /tmp/alpine-minirootfs-*.tar.gz -C /mnt/recovery
```

### 7.3 Set Up Alpine
Chroot into Alpine to configure it:
```bash
mount --bind /dev /mnt/recovery/dev
mount --bind /proc /mnt/recovery/proc
mount --bind /sys /mnt/recovery/sys
mount --bind /run /mnt/recovery/run
cp /etc/resolv.conf /mnt/recovery/etc/resolv.conf
chroot /mnt/recovery /bin/sh
```

Inside the Alpine chroot:
```sh
# Initialize package manager
apk update

# Install essential recovery tools
apk add btrfs-progs vim e2fsprogs dosfstools util-linux linux-lts

# Set root password (for emergency login)
passwd

# Exit Alpine chroot
exit
```

### 7.4 Clean Up Chroot Mounts
```bash
umount /mnt/recovery/{dev,proc,sys,run}
```

### 7.5 Install Alpine Kernel to EFI Partition
Alpine needs its own kernel on the EFI partition for systemd-boot to find it:
```bash
mkdir -p /mnt/boot/alpine
cp /mnt/recovery/boot/vmlinuz-lts /mnt/boot/alpine/vmlinuz-alpine
cp /mnt/recovery/boot/initramfs-lts /mnt/boot/alpine/initramfs-alpine
```

### 7.6 Create Recovery Boot Entry
```bash
vim /mnt/boot/loader/entries/recovery.conf
```

Contents (replace UUID with your recovery partition's UUID — get it with `blkid /dev/nvme0n1p2`):
```
title   Recovery (Alpine)
linux   /alpine/vmlinuz-alpine
initrd  /alpine/initramfs-alpine
options root=UUID=YOUR-RECOVERY-UUID rw
```

### 7.7 Verify Boot Entries
```bash
ls /mnt/boot/loader/entries/
```
Should show: `arch.conf` and `recovery.conf`

---

## Phase 8 — Reboot into Arch

### 8.1 Unmount and Reboot
```bash
umount -R /mnt
reboot
```

Remove the USB drive when the system restarts.

### 8.2 First Login
At the systemd-boot menu you'll see two entries:
- **Arch Linux** — select this for normal use
- **Recovery (Alpine)** — for emergency rollback

Log in to Arch with the user account you created. Verify internet:
```bash
ping -c 3 archlinux.org
```

If WiFi:
```bash
nmcli device wifi connect "YourNetworkName" password "YourPassword"
```

---

## Phase 9 — Post-Install (Before Bootstrap)

At this point you have a minimal Arch system with bash, vim, git, snapper, and internet. The next step is to clone your dotfiles and run bootstrap.sh, which handles everything else (Sway, Nix, Ghostty, Incus, the `vm` CLI, zram setup, etc.) as described in the requirements document.

### 9.1 Clone Dotfiles
```bash
git clone https://github.com/your-username/dotfiles.git ~/dotfiles
```

### 9.2 Run Bootstrap
```bash
cd ~/dotfiles
./bootstrap.sh
```

This script installs the managed `zram-generator` and `systemd-boot` config files, applies the Snapper cleanup-only policy, enables the core workstation services, disables `NetworkManager-wait-online.service` plus `snapper-timeline.timer`, installs `tlp`, applies a managed laptop power policy from `/etc/tlp.d/10-laptop-power.conf`, disables `power-profiles-daemon.service` if present, and restores the Lenovo battery thresholds to `40/80`. After it completes, reboot into your fully configured Sway environment.

### 9.3 Optional Fingerprint Setup
If the laptop has a supported fingerprint reader, run:
```bash
./bootstrap-fingerprint.sh
```

This optional script installs `fprintd` and `libfprint`, confirms the current PAM targets, removes any older TTY-login fingerprint block from `/etc/pam.d/system-login`, and enables fingerprint as an alternative to password for both `/etc/pam.d/swaylock` and `/etc/pam.d/sudo`.

After the script finishes:
```bash
fprintd-enroll
fprintd-verify
```

Then test:
```bash
sudo -k
sudo true
```

And test `swaylock` unlock before depending on fingerprint day to day. If `swaylock` does not start scanning immediately, press Enter once to start PAM. TTY login remains password-only.

### 9.4 Verify Bootstrap State
```bash
zramctl
cat /proc/swaps
systemctl list-unit-files --state=enabled | rg 'NetworkManager|systemd-resolved|snapper|tlp'
systemctl is-enabled NetworkManager-wait-online.service snapper-timeline.timer power-profiles-daemon.service 2>/dev/null || true
sudo tlp-stat -c | rg 'START_CHARGE_THRESH_BAT0|STOP_CHARGE_THRESH_BAT0|CPU_ENERGY_PERF_POLICY|PLATFORM_PROFILE'
cat /sys/class/power_supply/BAT0/charge_control_start_threshold
cat /sys/class/power_supply/BAT0/charge_control_end_threshold
systemd-analyze
```

Expected results:
- `zram0` exists and appears in `/proc/swaps`
- `NetworkManager.service`, `systemd-resolved.service`, `snapper-cleanup.timer`, and `tlp.service` are enabled
- `NetworkManager-wait-online.service` and `snapper-timeline.timer` are not enabled
- `power-profiles-daemon.service` is disabled or absent
- `tlp-stat -c` shows `START_CHARGE_THRESH_BAT0=40`, `STOP_CHARGE_THRESH_BAT0=80`, `CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance`, `CPU_ENERGY_PERF_POLICY_ON_BAT=balance_power`, `PLATFORM_PROFILE_ON_AC=performance`, and `PLATFORM_PROFILE_ON_BAT=balanced`
- the sysfs threshold files read back `40` and `80`
- boot no longer waits on a long `systemd-boot` menu timeout

---

## How to Roll Back a Bad Update

If a `pacman -Syu` breaks your system (won't boot, Sway crashes, etc.):

### From Arch (if it still boots)
```bash
# List available snapshots
snapper -c root list

# Identify the pre-update snapshot number (e.g., snapshot 5)
# Rollback by replacing @ with the snapshot
sudo mount /dev/nvme0n1p3 /mnt
sudo btrfs subvolume delete /mnt/@
sudo btrfs subvolume snapshot /mnt/.snapshots/5/snapshot /mnt/@
sudo umount /mnt
sudo reboot
```

### From Recovery (if Arch won't boot)
1. Reboot, select **Recovery (Alpine)** from the systemd-boot menu
2. Log in as root
3. Mount the btrfs partition and roll back:
```bash
mount /dev/nvme0n1p3 /mnt

# List snapshots
ls /mnt/@snapshots/

# Find the pre-update snapshot (look inside each for info.xml)
cat /mnt/@snapshots/5/info.xml

# Replace broken @ with the snapshot
btrfs subvolume delete /mnt/@
btrfs subvolume snapshot /mnt/@snapshots/5/snapshot /mnt/@

umount /mnt
reboot
```
4. Select **Arch Linux** — you're back on the pre-update state

---

## Partition Summary

| Partition | Size | Type | Filesystem | Mount Point |
|-----------|------|------|------------|-------------|
| nvme0n1p1 | 1 GB | EFI System | FAT32 | /boot |
| nvme0n1p2 | 2 GB | Linux filesystem | ext4 | /recovery |
| nvme0n1p3 | ~1.997 TB | Linux filesystem | btrfs (zstd) | / (subvol=@) |

No swap partition — zram configured via bootstrap.sh (compressed swap in RAM, no SSD wear).

### btrfs Subvolumes on nvme0n1p3

| Subvolume | Mount Point | Purpose |
|-----------|-------------|---------|
| @ | / | Root filesystem |
| @home | /home | User data (dotfiles, vm metadata, project secrets) |
| @var | /var | Variable data (logs, caches, Incus VM storage) |
| @nix | /nix | Nix store — excluded from root snapshots (large, fully reproducible) |
| @snapshots | /.snapshots | Snapper snapshots for rollback |

Incus will create its own btrfs storage pool for VMs within this filesystem.
