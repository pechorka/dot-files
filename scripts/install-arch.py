#!/usr/bin/env python3
"""
Arch Linux installer wrapper.

Collects user input, builds archinstall JSON configs,
and hands off to archinstall for the actual installation.

Layout: EFI (1G, /efi) + BTRFS root (rest of disk)
Bootloader: GRUB + grub-btrfs

Usage (from the Arch live ISO):
    python install-arch.py
    python install-arch.py --dry-run
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

from common import bold, die, log, run, warn

TAG = "install-arch"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

BTRFS_SUBVOLUMES = [
    {"name": "@", "mountpoint": "/"},
    {"name": "@home", "mountpoint": "/home"},
    {"name": "@var", "mountpoint": "/var"},
]

EXTRA_PACKAGES = [
    "grub",
    "grub-btrfs",
    "efibootmgr",
    "btrfs-progs",
    "intel-ucode",
    "networkmanager",
    "sudo",
    "vim",
    "git",
    "python",
    "base-devel",
    "snapper",
    "snap-pac",
]

LOCALES = ["en_US", "ru_RU"]


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------


def validate_hostname(name: str) -> bool:
    return bool(re.match(r"^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$", name))


def validate_username(name: str) -> bool:
    return bool(re.match(r"^[a-z_][a-z0-9_-]*$", name))


def validate_timezone(tz: str) -> bool:
    return Path(f"/usr/share/zoneinfo/{tz}").is_file()


def list_disks() -> list[dict]:
    result = subprocess.run(
        ["lsblk", "-d", "-e", "7,11", "-o", "PATH,SIZE,MODEL", "--noheadings"],
        capture_output=True,
        text=True,
        check=True,
    )
    disks = []
    for line in result.stdout.strip().splitlines():
        parts = line.split(None, 2)
        if len(parts) >= 2:
            disks.append({
                "path": parts[0],
                "size": parts[1],
                "model": parts[2].strip() if len(parts) > 2 else "",
            })
    return disks


def disk_has_mounts(path: str) -> bool:
    result = run(
        ["lsblk", "-nrpo", "MOUNTPOINT", path], check=False, capture=True
    )
    return any(line.strip() for line in result.stdout.splitlines())


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------


def prompt(label: str, validator, error_msg: str) -> str:
    while True:
        value = input(f"{label}: ").strip()
        if validator(value):
            return value
        warn(TAG, error_msg)


def collect_inputs() -> dict:
    disks = list_disks()
    log(TAG, "Available disks:")
    for d in disks:
        print(f"  {d['path']:20s} {d['size']:>10s}  {d['model']}")
    print()

    def valid_disk(path: str) -> bool:
        if not Path(path).is_block_device():
            warn(TAG, "Not a valid block device.")
            return False
        if disk_has_mounts(path):
            warn(TAG, "That disk has mounted filesystems. Unmount them first.")
            return False
        return True

    disk = prompt("Install target disk (e.g. /dev/nvme0n1)", valid_disk, "")
    hostname = prompt("Hostname", validate_hostname, "Use letters, numbers, and hyphens.")
    username = prompt("Username", validate_username, "Use a lowercase Linux username.")

    log(TAG, "Timezone examples: Europe/Berlin, America/New_York, Asia/Almaty")
    timezone = prompt("Timezone", validate_timezone, "Not found in /usr/share/zoneinfo.")

    return {
        "disk": disk,
        "hostname": hostname,
        "username": username,
        "timezone": timezone,
    }


def confirm(params: dict) -> None:
    print()
    log(TAG, "Install summary:")
    log(TAG, f"  Disk:       {params['disk']}")
    log(TAG, f"  Hostname:   {params['hostname']}")
    log(TAG, f"  Username:   {params['username']}")
    log(TAG, f"  Timezone:   {params['timezone']}")
    log(TAG, f"  Layout:     EFI 1G (/efi) + BTRFS (rest)")
    log(TAG, f"  Subvolumes: {', '.join(sv['name'] for sv in BTRFS_SUBVOLUMES)}")
    log(TAG, f"  Bootloader: GRUB + grub-btrfs")
    print()
    warn(TAG, f"This will wipe every partition on {bold(params['disk'])}.")

    if input("Type WIPE to continue: ").strip() != "WIPE":
        die(TAG, "Install aborted.")


# ---------------------------------------------------------------------------
# Config generation
# ---------------------------------------------------------------------------


def build_config(params: dict) -> dict:
    return {
        "archinstall-language": "English",
        "audio_config": None,
        "bootloader_config": {
            "bootloader": "Grub",
            "uki": False,
            "removable": False,
        },
        "debug": False,
        "disk_config": {
            "config_type": "manual_partitioning",
            "device_modifications": [
                {
                    "device": params["disk"],
                    "partitions": [
                        {
                            "btrfs": [],
                            "flags": ["boot"],
                            "fs_type": "fat32",
                            "size": {
                                "sector_size": None,
                                "unit": "GiB",
                                "value": 1,
                            },
                            "mount_options": [],
                            "mountpoint": "/efi",
                            "obj_id": str(uuid.uuid4()),
                            "start": {
                                "sector_size": None,
                                "unit": "MiB",
                                "value": 1,
                            },
                            "status": "create",
                            "type": "primary",
                        },
                        {
                            "btrfs": BTRFS_SUBVOLUMES,
                            "flags": [],
                            "fs_type": "btrfs",
                            "size": {
                                "sector_size": None,
                                "unit": "Percent",
                                "value": 100,
                            },
                            "mount_options": ["compress=zstd", "noatime"],
                            "mountpoint": None,
                            "obj_id": str(uuid.uuid4()),
                            "start": {
                                "sector_size": None,
                                "unit": "GiB",
                                "value": 1,
                            },
                            "status": "create",
                            "type": "primary",
                        },
                    ],
                    "wipe": True,
                },
            ],
        },
        "hostname": params["hostname"],
        "kernels": ["linux"],
        "locale_config": {
            "kb_layout": "us",
            "sys_enc": "UTF-8",
            "sys_lang": "en_US",
        },
        "network_config": {"type": "nm"},
        "no_pkg_lookups": False,
        "ntp": True,
        "offline": False,
        "packages": EXTRA_PACKAGES,
        "parallel downloads": 0,
        "swap": True,
        "timezone": params["timezone"],
        "custom-commands": [
            f"sed -i 's/^#{loc}.UTF-8 UTF-8/{loc}.UTF-8 UTF-8/' /etc/locale.gen"
            for loc in LOCALES
        ] + [
            "locale-gen",
            "systemctl enable systemd-resolved",
        ],
    }


def build_creds(params: dict) -> dict:
    return {
        "!users": [
            {
                "!password": None,
                "sudo": True,
                "username": params["username"],
            }
        ]
    }


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------


def preflight() -> None:
    if os.geteuid() != 0:
        die(TAG, "Run this script as root from the Arch live environment.")
    if not Path("/sys/firmware/efi").is_dir():
        die(TAG, "UEFI mode is required.")


def run_archinstall(config: dict, creds: dict) -> None:
    with tempfile.TemporaryDirectory(prefix="archinstall-") as tmpdir:
        config_path = Path(tmpdir) / "user_configuration.json"
        creds_path = Path(tmpdir) / "user_credentials.json"

        config_path.write_text(json.dumps(config, indent=2))
        creds_path.write_text(json.dumps(creds, indent=2))

        log(TAG, f"Config: {config_path}")
        log(TAG, f"Creds:  {creds_path}")
        log(TAG, "Handing off to archinstall...")

        run(["archinstall", "--config", str(config_path), "--creds", str(creds_path)])


def main() -> None:
    dry_run = "--dry-run" in sys.argv

    if not dry_run:
        preflight()

    params = collect_inputs()
    confirm(params)

    config = build_config(params)
    creds = build_creds(params)

    if dry_run:
        log(TAG, "Dry run — generated configs:\n")
        print(bold("=== user_configuration.json ==="))
        print(json.dumps(config, indent=2))
        print()
        print(bold("=== user_credentials.json ==="))
        print(json.dumps(creds, indent=2))
        return

    run_archinstall(config, creds)

    log(TAG, "Install complete.")
    log(TAG, "")
    log(TAG, "Next steps:")
    log(TAG, "  1. Reboot into Arch")
    log(TAG, "  2. Clone dotfiles and run: sudo python system-bootstrap.py")


if __name__ == "__main__":
    main()
