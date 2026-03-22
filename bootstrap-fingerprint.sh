#!/usr/bin/env bash
set -euo pipefail

PAM_SYSTEM_LOGIN="/etc/pam.d/system-login"
PAM_SWAYLOCK="/etc/pam.d/swaylock"
PAM_SUDO="/etc/pam.d/sudo"
BEGIN_MARKER="# >>> fingerprint bootstrap managed block >>>"
END_MARKER="# <<< fingerprint bootstrap managed block <<<"
PAM_LINE="auth       sufficient  pam_fprintd.so      max-tries=3 timeout=10"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[fingerprint]${NC} $1"; }
warn() { echo -e "${YELLOW}[fingerprint]${NC} $1"; }
error() { echo -e "${RED}[fingerprint]${NC} $1" >&2; }
die() { error "$1"; exit 1; }

backup_path_for() {
    local file="$1"
    printf '%s.pre-fingerprint-bootstrap.bak\n' "$file"
}

require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

require_pam_line() {
    local file="$1"
    local pattern="$2"
    local description="$3"

    grep -Eq "$pattern" "$file" || die "$description not found in $file"
}

find_fingerprint_device() {
    local dev props vendor_id product_id vendor_db model_db manufacturer product

    for dev in /sys/bus/usb/devices/*; do
        [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue

        props="$(udevadm info -q property -p "$dev" 2>/dev/null || true)"
        vendor_id="$(tr '[:upper:]' '[:lower:]' < "$dev/idVendor")"
        product_id="$(tr '[:upper:]' '[:lower:]' < "$dev/idProduct")"
        vendor_db="$(printf '%s\n' "$props" | sed -n 's/^ID_VENDOR_FROM_DATABASE=//p' | head -n1)"
        model_db="$(printf '%s\n' "$props" | sed -n 's/^ID_MODEL_FROM_DATABASE=//p' | head -n1)"
        manufacturer="$(cat "$dev/manufacturer" 2>/dev/null || true)"
        product="$(cat "$dev/product" 2>/dev/null || true)"

        if printf '%s\n%s\n%s\n%s\n' \
            "$vendor_db" "$model_db" "$manufacturer" "$product" \
            | grep -qiE 'fingerprint|synaptics|validity|goodix|elan|egis|authentec|fpc|prometheus'; then
            FINGERPRINT_DEVICE="${vendor_id}:${product_id} ${vendor_db:-${manufacturer:-unknown vendor}} ${model_db:-${product:-unknown model}}"
            return 0
        fi
    done

    return 1
}

verify_pam_targets() {
    [[ -f "$PAM_SYSTEM_LOGIN" ]] || die "Missing PAM file: $PAM_SYSTEM_LOGIN"
    [[ -f "$PAM_SWAYLOCK" ]] || die "Missing PAM file: $PAM_SWAYLOCK"
    [[ -f "$PAM_SUDO" ]] || die "Missing PAM file: $PAM_SUDO"

    require_pam_line "$PAM_SYSTEM_LOGIN" '^auth[[:space:]]+include[[:space:]]+system-auth([[:space:]].*)?$' \
        "Expected system-auth include in $PAM_SYSTEM_LOGIN"
    require_pam_line "$PAM_SWAYLOCK" '^auth[[:space:]]+include[[:space:]]+login([[:space:]].*)?$' \
        "Expected login include in $PAM_SWAYLOCK"
    require_pam_line "$PAM_SUDO" '^auth[[:space:]]+include[[:space:]]+system-auth([[:space:]].*)?$' \
        "Expected system-auth include in $PAM_SUDO"
}

ensure_backup() {
    local file="$1"
    local backup

    backup="$(backup_path_for "$file")"
    if sudo test -f "$backup"; then
        log "Existing PAM backup found at $backup"
        return
    fi

    sudo cp -a "$file" "$backup"
    log "Backed up $file to $backup"
}

ensure_managed_block_integrity() {
    local file="$1"
    local begin_count end_count

    begin_count="$(grep -cF "$BEGIN_MARKER" "$file" || true)"
    end_count="$(grep -cF "$END_MARKER" "$file" || true)"

    if [[ "$begin_count" -gt 1 || "$end_count" -gt 1 ]]; then
        die "Found multiple managed fingerprint blocks in $file"
    fi

    if [[ "$begin_count" -ne "$end_count" ]]; then
        die "Found an incomplete managed fingerprint block in $file"
    fi
}

has_managed_block() {
    local file="$1"
    grep -qF "$BEGIN_MARKER" "$file"
}

has_unmanaged_pam_fprintd() {
    local file="$1"

    awk \
        -v begin="$BEGIN_MARKER" \
        -v end="$END_MARKER" '
        $0 == begin { in_block = 1; next }
        $0 == end { in_block = 0; next }
        !in_block && /pam_fprintd\.so/ { found = 1 }
        END { exit(found ? 0 : 1) }
        ' "$file"
}

render_without_managed_block() {
    local file="$1"
    local tmp="$2"

    awk \
        -v begin="$BEGIN_MARKER" \
        -v end="$END_MARKER" '
        $0 == begin { in_block = 1; next }
        $0 == end { in_block = 0; next }
        !in_block { print }
        ' "$file" > "$tmp"
}

remove_managed_block() {
    local file="$1"
    local tmp

    if ! has_managed_block "$file"; then
        log "$file already leaves fingerprint auth unmanaged"
        return
    fi

    tmp="$(mktemp)"
    render_without_managed_block "$file" "$tmp"

    if cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        log "$file already has the desired contents"
        return
    fi

    sudo install -m 644 "$tmp" "$file"
    rm -f "$tmp"
    log "Removed managed fingerprint block from $file"
}

insert_managed_block_before() {
    local file="$1"
    local anchor_regex="$2"
    local anchor_description="$3"
    local tmp status

    tmp="$(mktemp)"
    status=0

    awk \
        -v begin="$BEGIN_MARKER" \
        -v end="$END_MARKER" \
        -v managed_line="$PAM_LINE" \
        -v anchor_regex="$anchor_regex" '
        $0 == begin { in_block = 1; next }
        $0 == end { in_block = 0; next }
        in_block { next }
        {
            if (!inserted && $0 ~ anchor_regex) {
                print begin
                print managed_line
                print end
                inserted = 1
            }
            print
        }
        END {
            if (!inserted) {
                exit 2
            }
        }
        ' "$file" > "$tmp" || status=$?

    if [[ "$status" -eq 2 ]]; then
        rm -f "$tmp"
        die "Could not find the $anchor_description in $file"
    elif [[ "$status" -ne 0 ]]; then
        rm -f "$tmp"
        die "Failed to render updated PAM file for $file"
    fi

    if cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        log "$file already contains the managed fingerprint block"
        return
    fi

    sudo install -m 644 "$tmp" "$file"
    rm -f "$tmp"
    log "Updated $file"
}

print_next_steps() {
    cat <<EOF

Next steps:
  1. Enroll a fingerprint:
     fprintd-enroll
  2. Verify matching works:
     fprintd-verify
  3. Test sudo with a fresh prompt:
     sudo -k
     sudo true
  4. Test swaylock with Mod4+Escape.

Scope:
  - Enabled for swaylock and sudo with password fallback.
  - TTY login remains password-only.

Notes:
  - If swaylock does not begin scanning immediately, press Enter once to start PAM.

Rollback:
  sudo cp "$(backup_path_for "$PAM_SYSTEM_LOGIN")" "$PAM_SYSTEM_LOGIN"
  sudo cp "$(backup_path_for "$PAM_SWAYLOCK")" "$PAM_SWAYLOCK"
  sudo cp "$(backup_path_for "$PAM_SUDO")" "$PAM_SUDO"
EOF
}

main() {
    local target_user

    if [[ "${EUID:-$(id -u)}" -eq 0 && -z "${SUDO_USER:-}" ]]; then
        die "Run this script as your normal user so enrollment targets the right account."
    fi

    target_user="${SUDO_USER:-$USER}"

    require_command sudo
    require_command pacman
    require_command udevadm
    require_command awk
    require_command grep
    require_command mktemp
    require_command cmp

    log "Checking for an internal fingerprint reader..."
    if ! find_fingerprint_device; then
        die "No obvious USB fingerprint reader detected. This script is intended for machines with a supported internal reader."
    fi
    log "Detected fingerprint device: $FINGERPRINT_DEVICE"

    log "Installing fingerprint packages if needed..."
    sudo pacman -S --needed --noconfirm fprintd libfprint

    log "Verifying PAM targets for swaylock, sudo, and TTY migration..."
    verify_pam_targets

    ensure_managed_block_integrity "$PAM_SYSTEM_LOGIN"
    ensure_managed_block_integrity "$PAM_SWAYLOCK"
    ensure_managed_block_integrity "$PAM_SUDO"

    if has_unmanaged_pam_fprintd "$PAM_SYSTEM_LOGIN"; then
        die "$PAM_SYSTEM_LOGIN already references pam_fprintd.so outside the managed block; review it manually first."
    fi
    if has_unmanaged_pam_fprintd "$PAM_SWAYLOCK"; then
        die "$PAM_SWAYLOCK already references pam_fprintd.so outside the managed block; review it manually first."
    fi
    if has_unmanaged_pam_fprintd "$PAM_SUDO"; then
        die "$PAM_SUDO already references pam_fprintd.so outside the managed block; review it manually first."
    fi

    ensure_backup "$PAM_SYSTEM_LOGIN"
    remove_managed_block "$PAM_SYSTEM_LOGIN"

    ensure_backup "$PAM_SWAYLOCK"
    insert_managed_block_before "$PAM_SWAYLOCK" \
        '^auth[[:space:]]+include[[:space:]]+login([[:space:]].*)?$' \
        "login include"

    ensure_backup "$PAM_SUDO"
    insert_managed_block_before "$PAM_SUDO" \
        '^auth[[:space:]]+include[[:space:]]+system-auth([[:space:]].*)?$' \
        "system-auth include"

    log "Fingerprint PAM setup is ready for $target_user"
    print_next_steps
}

main "$@"
