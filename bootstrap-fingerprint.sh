#!/usr/bin/env bash
set -euo pipefail

PAM_FILE="/etc/pam.d/system-login"
PAM_BACKUP="/etc/pam.d/system-login.pre-fingerprint-bootstrap.bak"
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

verify_pam_chain() {
    [[ -f "$PAM_FILE" ]] || die "Missing PAM file: $PAM_FILE"
    [[ -f /etc/pam.d/login ]] || die "Missing PAM file: /etc/pam.d/login"
    [[ -f /etc/pam.d/system-local-login ]] || die "Missing PAM file: /etc/pam.d/system-local-login"
    [[ -f /etc/pam.d/swaylock ]] || die "Missing PAM file: /etc/pam.d/swaylock"

    require_pam_line "$PAM_FILE" '^auth[[:space:]]+requisite[[:space:]]+pam_nologin\.so([[:space:]].*)?$' \
        "Expected pam_nologin anchor"
    require_pam_line "$PAM_FILE" '^auth[[:space:]]+include[[:space:]]+system-auth([[:space:]].*)?$' \
        "Expected system-auth include"
    require_pam_line /etc/pam.d/system-local-login '^auth[[:space:]]+include[[:space:]]+system-login([[:space:]].*)?$' \
        "Expected system-login include"
    require_pam_line /etc/pam.d/login '^auth[[:space:]]+include[[:space:]]+system-local-login([[:space:]].*)?$' \
        "Expected system-local-login include"
    require_pam_line /etc/pam.d/swaylock '^auth[[:space:]]+include[[:space:]]+login([[:space:]].*)?$' \
        "Expected login include"
}

ensure_backup() {
    if sudo test -f "$PAM_BACKUP"; then
        log "Existing PAM backup found at $PAM_BACKUP"
        return
    fi

    sudo cp -a "$PAM_FILE" "$PAM_BACKUP"
    log "Backed up $PAM_FILE to $PAM_BACKUP"
}

rewrite_pam_file() {
    local tmp
    local status=0
    tmp="$(mktemp)"

    awk \
        -v begin="$BEGIN_MARKER" \
        -v end="$END_MARKER" \
        -v managed_line="$PAM_LINE" '
        $0 == begin { in_block = 1; next }
        $0 == end { in_block = 0; next }
        in_block { next }
        {
            print
            if (!inserted && $0 ~ /^auth[[:space:]]+requisite[[:space:]]+pam_nologin\.so([[:space:]].*)?$/) {
                print begin
                print managed_line
                print end
                inserted = 1
            }
        }
        END {
            if (!inserted) {
                exit 2
            }
        }
        ' "$PAM_FILE" > "$tmp" || status=$?

    if [[ "$status" -eq 2 ]]; then
        rm -f "$tmp"
        die "Could not find the pam_nologin anchor in $PAM_FILE"
    elif [[ "$status" -ne 0 ]]; then
        rm -f "$tmp"
        die "Failed to render updated PAM file"
    fi

    if cmp -s "$tmp" "$PAM_FILE"; then
        rm -f "$tmp"
        log "$PAM_FILE already contains the managed fingerprint block"
        return
    fi

    sudo install -m 644 "$tmp" "$PAM_FILE"
    rm -f "$tmp"
    log "Updated $PAM_FILE"
}

print_next_steps() {
    cat <<EOF

Next steps:
  1. Enroll a fingerprint:
     fprintd-enroll
  2. Verify matching works:
     fprintd-verify
  3. Test a fresh TTY login before relying on it day-to-day.
  4. Test swaylock with Mod4+Escape.

Scope:
  - Enabled for TTY login and swaylock through the existing PAM include chain.
  - Left sudo password-only on purpose.

Rollback:
  sudo cp "$PAM_BACKUP" "$PAM_FILE"
EOF
}

main() {
    local target_user managed_begin_count managed_end_count

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

    log "Verifying PAM include chain for TTY login and swaylock..."
    verify_pam_chain

    managed_begin_count="$(grep -cF "$BEGIN_MARKER" "$PAM_FILE" || true)"
    managed_end_count="$(grep -cF "$END_MARKER" "$PAM_FILE" || true)"
    if [[ "$managed_begin_count" -gt 1 || "$managed_end_count" -gt 1 ]]; then
        die "Found multiple managed fingerprint blocks in $PAM_FILE"
    fi
    if [[ "$managed_begin_count" -ne "$managed_end_count" ]]; then
        die "Found an incomplete managed fingerprint block in $PAM_FILE"
    fi
    if grep -q 'pam_fprintd\.so' "$PAM_FILE" && [[ "$managed_begin_count" -eq 0 ]]; then
        die "$PAM_FILE already references pam_fprintd.so outside the managed block; review it manually first."
    fi

    ensure_backup
    rewrite_pam_file

    log "Fingerprint PAM setup is ready for $target_user"
    print_next_steps
}

main "$@"
