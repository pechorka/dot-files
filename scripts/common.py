"""
Shared utilities for install-arch.py and bootstrap.py.

Provides logging, command execution, file management,
and systemd service helpers.
"""

from __future__ import annotations

import grp
import os
import pwd
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_GREEN = "\033[0;32m"
_YELLOW = "\033[1;33m"
_RED = "\033[0;31m"
_BOLD = "\033[1m"
_NC = "\033[0m"


def bold(text: str) -> str:
    return f"{_BOLD}{text}{_NC}"


def log(tag: str, msg: str) -> None:
    print(f"{_GREEN}[{tag}]{_NC} {msg}")


def warn(tag: str, msg: str) -> None:
    print(f"{_YELLOW}[{tag}]{_NC} {msg}")


def die(tag: str, msg: str) -> None:
    print(f"{_RED}[{tag}]{_NC} {msg}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------


def run(
    cmd: list[str] | str,
    *,
    check: bool = True,
    capture: bool = False,
    env: dict[str, str] | None = None,
    shell: bool = False,
) -> subprocess.CompletedProcess:
    """Run a command, optionally capturing output."""
    merged_env = {**os.environ, **(env or {})}
    return subprocess.run(
        cmd,
        check=check,
        capture_output=capture,
        text=True,
        env=merged_env,
        shell=shell,
    )


def run_as_root(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    """Run a command as root, prefixing with sudo if necessary."""
    if os.geteuid() == 0:
        return run(cmd, **kwargs)
    return run(["sudo", *cmd], **kwargs)


def run_as_user(
    cmd: list[str], user: str, **kwargs
) -> subprocess.CompletedProcess:
    """Run a command as a specific user."""
    current_uid = os.geteuid()
    target_uid = pwd.getpwnam(user).pw_uid

    if current_uid == target_uid:
        return run(cmd, **kwargs)
    return run(["sudo", "-u", user, "-H", *cmd], **kwargs)


def command_exists(name: str) -> bool:
    return shutil.which(name) is not None


def is_package_installed(pkg: str) -> bool:
    """Check if a pacman package is installed."""
    result = run(["pacman", "-Qi", pkg], check=False, capture=True)
    return result.returncode == 0


# ---------------------------------------------------------------------------
# User info
# ---------------------------------------------------------------------------


@dataclass
class UserInfo:
    name: str
    home: Path
    group: str
    uid: int
    gid: int

    @classmethod
    def from_name(cls, username: str) -> UserInfo:
        pw = pwd.getpwnam(username)
        gr = grp.getgrgid(pw.pw_gid)
        return cls(
            name=username,
            home=Path(pw.pw_dir),
            group=gr.gr_name,
            uid=pw.pw_uid,
            gid=pw.pw_gid,
        )

    @classmethod
    def current(cls) -> UserInfo:
        name = os.environ.get("SUDO_USER") or os.environ.get("USER", "")
        if not name:
            die("common", "Cannot determine current user")
        return cls.from_name(name)


# ---------------------------------------------------------------------------
# File management
# ---------------------------------------------------------------------------


def install_system_file(src: Path, dest: Path, mode: int = 0o644) -> bool:
    """Install a file owned by root. Returns False if src is missing."""
    if not src.is_file():
        return False

    dest.parent.mkdir(parents=True, exist_ok=True)

    if dest.is_symlink():
        dest.unlink()

    shutil.copy2(src, dest)
    dest.chmod(mode)
    return True


def install_user_file(
    src: Path, dest: Path, user: UserInfo, mode: int = 0o644
) -> bool:
    """Install a file owned by the target user. Returns False if src is missing."""
    if not src.is_file():
        return False

    dest.parent.mkdir(parents=True, exist_ok=True)

    if dest.is_symlink():
        dest.unlink()

    shutil.copy2(src, dest)
    dest.chmod(mode)
    os.chown(dest, user.uid, user.gid)
    return True


# ---------------------------------------------------------------------------
# systemd service helpers
# ---------------------------------------------------------------------------


def is_service_enabled(service: str) -> bool:
    result = run(
        ["systemctl", "is-enabled", service], check=False, capture=True
    )
    return result.returncode == 0


def enable_service(service: str, *, now: bool = True) -> None:
    """Enable (and optionally start) a systemd service."""
    if is_service_enabled(service):
        return
    cmd = ["systemctl", "enable"]
    if now:
        cmd.append("--now")
    cmd.append(service)
    run_as_root(cmd, check=False)


def disable_service(service: str, *, now: bool = True) -> None:
    """Disable (and optionally stop) a systemd service."""
    if not is_service_enabled(service):
        return
    cmd = ["systemctl", "disable"]
    if now:
        cmd.append("--now")
    cmd.append(service)
    run_as_root(cmd, check=False)


def enable_user_service(service: str) -> None:
    """Enable a user-scoped service globally for all future logins."""
    result = run(
        ["systemctl", "--global", "is-enabled", service],
        check=False,
        capture=True,
    )
    if result.returncode == 0:
        return
    run_as_root(["systemctl", "--global", "enable", service], check=False)


# ---------------------------------------------------------------------------
# pacman helpers
# ---------------------------------------------------------------------------


def pacman_install(packages: list[str]) -> None:
    """Install packages with pacman (idempotent via --needed)."""
    if not packages:
        return
    run_as_root(["pacman", "-S", "--needed", "--noconfirm", *packages])


def pacman_upgrade() -> None:
    """Full system upgrade."""
    run_as_root(["pacman", "-Syyu", "--noconfirm"])
