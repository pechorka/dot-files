#!/usr/bin/env python3
"""
System bootstrap.

Turns a fresh Arch install into a fully configured development workstation.
Run once after first boot.

Usage:
    sudo python system-bootstrap.py
    sudo python system-bootstrap.py --user pechor

Safe to run multiple times (idempotent).
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from common import (
    UserInfo,
    command_exists,
    die,
    disable_service,
    enable_service,
    enable_user_service,
    install_system_file,
    install_user_file,
    is_package_installed,
    log,
    pacman_install,
    pacman_upgrade,
    run,
    run_as_root,
    run_as_user,
    warn,
)

TAG = "bootstrap"
DOTFILES_DIR = Path(__file__).resolve().parent

# ---------------------------------------------------------------------------
# Package lists
# ---------------------------------------------------------------------------

PACMAN_PACKAGES = [
    # Display & compositor
    "sway",
    "swaylock",
    "swayidle",
    "xdg-desktop-portal-wlr",
    "xorg-xwayland",
    "wdisplays",
    # Audio
    "pipewire",
    "pipewire-pulse",
    "pipewire-jack",
    "sof-firmware",
    "wireplumber",
    # Graphics (Intel)
    "mesa",
    "vulkan-intel",
    "intel-media-driver",
    # Browsers
    "firefox",
    "chromium",
    # Swap
    "zram-generator",
    # Power management
    "tlp",
    # Snapshots
    "snapper",
    "snap-pac",
    # Shells & editors
    "fish",
    "tmux",
    # CLI tools
    "ripgrep",
    "fzf",
    "fd",
    "jq",
    "bat",
    "curl",
    "wget",
    "lazygit",
    "openssh",
    "less",
    "btop",
    # Go
    "go",
    "gopls",
    # Rust
    "rustup",
    # JS/TS
    "nodejs",
    "pnpm",
    "npm",
    # JVM
    "jdk-openjdk",
    "kotlin",
    "gradle",
    # DB clients
    "sqlite",
    "pgcli",
    # Containers
    "crun",
    "podman",
    # QEMU / quickemu
    "qemu-ui-gtk",
    "qemu-chardev-spice",
    "qemu-audio-pipewire",
    "qemu-hw-display-virtio-vga",
    "qemu-ui-spice-core",
    "spice-gtk",
    "qemu-hw-display-virtio-gpu",
    "qemu-hw-usb-redirect",
    # Wayland tools
    "wofi",
    "mako",
    "grim",
    "slurp",
    "wl-clipboard",
    "brightnessctl",
    "playerctl",
    "pamixer",
    "satty",
    # System applets
    "networkmanager",
    "cups",
    "system-config-printer",
    "avahi",
    "nss-mdns",
    "ipp-usb",
    "blueman",
    "pavucontrol",
    "lxqt-policykit",
    # Fonts
    "noto-fonts",
    "noto-fonts-emoji",
    "ttf-font-awesome",
    "ttf-liberation",
    # Misc
    "bubblewrap",
    "mise",
    "base-devel",
    "keychain",
]

AUR_PACKAGES = [
    "ghostty",
    "yq-go",
    "neovim-nightly-bin",
    "quickemu",
    "handy",
]

RUST_COMPONENTS = ["rust-analyzer", "clippy", "rustfmt"]

ENABLE_SERVICES = [
    "systemd-resolved",
    "NetworkManager",
    "cups.service",
    "avahi-daemon.service",
    "bluetooth.service",
    "snapper-cleanup.timer",
    "tlp.service",
]

DISABLE_SERVICES = [
    "power-profiles-daemon.service",
    "NetworkManager-wait-online.service",
    "snapper-timeline.timer",
]

USER_SERVICES = ["pipewire", "pipewire-pulse", "wireplumber"]

HIDDEN_APPS = [
    "avahi-discover",
    "btop",
    "bssh",
    "bvnc",
    "jconsole-java-openjdk",
    "jshell-java-openjdk",
    "nvim",
    "qv4l2",
    "qvidcap",
    "vim",
]


# ---------------------------------------------------------------------------
# Stage 1: Packages
# ---------------------------------------------------------------------------


def ensure_yay(user: UserInfo) -> None:
    if command_exists("yay"):
        log(TAG, "yay already installed")
        return

    log(TAG, "Installing yay...")
    script = (
        "set -euo pipefail\n"
        "yay_tmp=$(mktemp -d)\n"
        'trap \'rm -rf "$yay_tmp"\' EXIT\n'
        'git clone https://aur.archlinux.org/yay.git "$yay_tmp/yay"\n'
        'cd "$yay_tmp/yay"\n'
        "makepkg -si --noconfirm\n"
    )
    run_as_user(["bash", "-c", script], user.name)


def setup_rust(user: UserInfo) -> None:
    result = run_as_user(
        ["rustup", "show", "active-toolchain"], user.name, check=False, capture=True
    )
    if result.returncode == 0:
        log(TAG, "Rust toolchain already configured")
        return

    log(TAG, "Installing Rust stable toolchain...")
    run_as_user(["rustup", "default", "stable"], user.name)
    run_as_user(["rustup", "component", "add", *RUST_COMPONENTS], user.name)


def configure_snapper() -> None:
    config_path = Path("/etc/snapper/configs/root")

    if not config_path.exists():
        log(TAG, "Creating snapper root config...")
        run_as_root(["snapper", "-c", "root", "create-config", "/"])

    def set_value(key: str, value: str) -> None:
        run_as_root(
            ["sed", "-i", f's/^{key}=.*/{key}="{value}"/', str(config_path)]
        )

    set_value("TIMELINE_CREATE", "no")
    set_value("NUMBER_LIMIT", "3")
    set_value("NUMBER_LIMIT_IMPORTANT", "3")
    log(TAG, "Snapper retention policy applied")


def stage_packages(user: UserInfo) -> None:
    log(TAG, "=== Stage 1: Packages ===")

    log(TAG, "Upgrading system...")
    pacman_upgrade()

    # Resolve iptables conflict
    if is_package_installed("iptables") and not is_package_installed("iptables-nft"):
        log(TAG, "Replacing iptables with iptables-nft...")
        run_as_root(
            ["pacman", "-S", "--needed", "--noconfirm", "--ask", "4", "iptables-nft"]
        )

    log(TAG, "Installing pacman packages...")
    pacman_install(PACMAN_PACKAGES)

    ensure_yay(user)

    for pkg in AUR_PACKAGES:
        if not is_package_installed(pkg):
            log(TAG, f"Installing {pkg} from AUR...")
            run_as_user(["yay", "-S", "--needed", "--noconfirm", pkg], user.name)

    setup_rust(user)
    configure_snapper()
    log(TAG, "Stage 1 complete")


# ---------------------------------------------------------------------------
# Stage 2: System configs
# ---------------------------------------------------------------------------


def stage_system(user: UserInfo) -> None:
    log(TAG, "=== Stage 2: System configs ===")

    local_bin = user.home / ".local" / "bin"
    local_bin.mkdir(parents=True, exist_ok=True)
    os.chown(local_bin, user.uid, user.gid)

    src = DOTFILES_DIR / "system" / "zram-generator.conf"
    if install_system_file(src, Path("/etc/systemd/zram-generator.conf")):
        log(TAG, "Installed zram-generator config")

    src = DOTFILES_DIR / "system" / "tlp.d" / "10-laptop-power.conf"
    if install_system_file(src, Path("/etc/tlp.d/10-laptop-power.conf")):
        log(TAG, "Installed TLP power policy")

    run_as_root(["systemctl", "daemon-reload"])
    result = run_as_root(
        ["systemctl", "start", "systemd-zram-setup@zram0.service"], check=False
    )
    if result.returncode == 0:
        log(TAG, "Activated zram swap")
    else:
        warn(TAG, "Failed to activate zram swap")

    if command_exists("fish"):
        result = run_as_user(
            ["fish", "-c", f"hide_app {' '.join(HIDDEN_APPS)}"],
            user.name,
            check=False,
        )
        if result.returncode == 0:
            log(TAG, "Hidden desktop entries from launcher")

    log(TAG, "Stage 2 complete")


# ---------------------------------------------------------------------------
# Stage 3: Shell setup
# ---------------------------------------------------------------------------


def stage_shell(user: UserInfo) -> None:
    log(TAG, "=== Stage 3: Shell setup ===")

    fish_path = "/usr/bin/fish"
    if command_exists("fish"):
        shells = Path("/etc/shells").read_text()
        if fish_path not in shells:
            run(f"echo '{fish_path}' | sudo tee -a /etc/shells", shell=True)
            log(TAG, f"Added {fish_path} to /etc/shells")

        current_shell = run(
            ["getent", "passwd", user.name], capture=True
        ).stdout.strip().split(":")[-1]

        if current_shell != fish_path:
            run_as_root(["usermod", "-s", fish_path, user.name])
            log(TAG, f"Default shell set to fish for {user.name}")
    else:
        warn(TAG, "fish not found, skipping shell change")

    src = DOTFILES_DIR / "git" / "gitconfig"
    if install_user_file(src, user.home / ".gitconfig", user):
        log(TAG, "Installed .gitconfig")

    log(TAG, "Stage 3 complete")


# ---------------------------------------------------------------------------
# Stage 4: Services
# ---------------------------------------------------------------------------


def stage_services() -> None:
    log(TAG, "=== Stage 4: Services ===")

    for svc in DISABLE_SERVICES:
        disable_service(svc)
        log(TAG, f"  Disabled {svc}")

    for svc in ENABLE_SERVICES:
        enable_service(svc)
        log(TAG, f"  Enabled {svc}")

    run_as_root(["systemctl", "restart", "tlp.service"], check=False)

    for svc in USER_SERVICES:
        enable_user_service(svc)
        log(TAG, f"  Enabled {svc} (global user)")

    log(TAG, "Stage 4 complete")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Bootstrap a fresh Arch install into a dev workstation."
    )
    parser.add_argument(
        "--user",
        default=None,
        help="Target user (default: SUDO_USER or current user).",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    if os.geteuid() != 0:
        die(TAG, "Run with sudo: sudo python system-bootstrap.py")

    user = UserInfo.from_name(args.user) if args.user else UserInfo.current()

    log(TAG, "=========================================")
    log(TAG, "Bootstrap starting...")
    log(TAG, f"Dotfiles: {DOTFILES_DIR}")
    log(TAG, f"Target:   {user.name}")
    log(TAG, "=========================================")

    stage_packages(user)
    stage_system(user)
    stage_shell(user)
    stage_services()

    log(TAG, "=========================================")
    log(TAG, "Bootstrap complete!")
    log(TAG, "=========================================")
    log(TAG, "")
    log(TAG, "Next steps:")
    log(TAG, "  1. Log out and back in (for fish shell)")
    log(TAG, "  2. Start Sway from TTY: sway")
    log(TAG, "  3. Optional: run ./bootstrap-fingerprint.sh")


if __name__ == "__main__":
    main()
