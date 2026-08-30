#!/usr/bin/env bash
#
# scripts/test-backup-external.sh
# ===============================
#
# Exercise the external-HDD steps of setup-backup.sh (3b/3c) against a FAKE
# /etc/fstab, with no root and no real disk. Run it after touching any of
# install_external_fstab / build_external_fstab_candidate / mount_external_now.
#
# Why this exists: an independent review of these ~150 lines found six separate
# ways they installed nothing, or the wrong thing, while reporting success —
# every one of them a guard that only misfires in a state the author's machine
# was not in at the time. That class of bug is invisible to shellcheck and to a
# single hand-run, and it is exactly what a table of states catches.
#
# Requires: util-linux (findmnt), systemd (systemd-escape). No sudo.
#
# Usage: scripts/test-backup-external.sh

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }

# Source the installer without running it (main is guarded), then neuter the
# two things a test must never do for real.
# shellcheck source=/dev/null
source "$DOTFILES/scripts/setup-backup.sh"
# `install -o root -g root` needs CAP_CHOWN, which the test does not have.
# Drop the ownership flags rather than pretend the call succeeded — otherwise
# the assertions pass through a path production never takes.
sudo() {
  if [[ "${1:-}" == install ]]; then
    shift
    local args=()
    while (( $# )); do
      case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
    done
    command install "${args[@]}"
  else
    "$@"
  fi
}
systemctl() { :; }                       # never talk to PID 1
mount()     { return 1; }                # never mount anything
lsblk()     { printf '%s\n' "${FAKE_FSTYPE:-}"; }

UUID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

# Run install_external_fstab against a fresh fake table. $1 = fstab contents,
# $2 = mount point; remaining env comes from the caller. Echoes the resulting
# table so assertions can look at what was actually written.
run_install() {
  local body="$1" mnt="$2"
  FSTAB="$TMPROOT/fstab.$RANDOM"
  printf '%s' "$body" > "$FSTAB"
  BACKUP_EXTERNAL_UUID="$UUID" BACKUP_EXTERNAL_REPO="$mnt/restic" \
    install_external_fstab >"$TMPROOT/out" 2>&1
  cat "$FSTAB"
}

# Did the run install an entry for $UUID targeting $1?
entry_target() { findmnt --fstab --tab-file "$FSTAB" -no TARGET -S "UUID=$UUID" 2>/dev/null; }
entry_fstype() { findmnt --fstab --tab-file "$FSTAB" -no FSTYPE -S "UUID=$UUID" 2>/dev/null; }

echo "=== pure helpers ==="
check "fstab_escape leaves a plain path alone" \
      "$(fstab_escape /media/zvi/Backup)" "/media/zvi/Backup"
check "fstab_escape encodes spaces as \\040" \
      "$(fstab_escape '/media/zvi/My Book')" '/media/zvi/My\040Book'
check "external_mount_unit escapes a dash" \
      "$(external_mount_unit /run/media/zvi/ext-storage2)" 'run-media-zvi-ext\x2dstorage2.mount'
check "external_mount_unit escapes a space" \
      "$(external_mount_unit '/media/zvi/My Book')" 'media-zvi-My\x20Book.mount'
check "fstab_parse_errors counts a clean table" \
      "$(printf 'tmpfs /tmp tmpfs defaults 0 0\n' > "$TMPROOT/t"; fstab_parse_errors "$TMPROOT/t")" "0"
check "fstab_parse_errors flags a broken line" \
      "$(printf 'UUID=x\n' > "$TMPROOT/t2"; [[ "$(fstab_parse_errors "$TMPROOT/t2")" != "0" ]] && echo nonzero)" "nonzero"
check "external_is_mounted is false for a non-mount-point" \
      "$(external_is_mounted "$TMPROOT" && echo yes || echo no)" "no"
check "external_is_mounted is true for /" \
      "$(external_is_mounted / && echo yes || echo no)" "yes"

echo
echo "=== install: the states that must produce an entry ==="
# The two states the review found broken: the disk undocked, and the mount point
# directory absent. Both make findmnt --verify report "unreachable on boot" even
# with nofail, which used to roll the correct entry straight back out again.
run_install "tmpfs /tmp tmpfs defaults 0 0
" /media/zvi/Backup >/dev/null
check "installs with the disk undocked and the mount point absent" \
      "$(entry_target)" "/media/zvi/Backup"
check "  ...falls back to fstype=auto when the disk cannot be read" \
      "$(entry_fstype)" "auto"

FAKE_FSTYPE=exfat run_install "tmpfs /tmp tmpfs defaults 0 0
" /media/zvi/Backup >/dev/null
check "uses the disk's real filesystem type, not a hardcoded ext4" \
      "$(entry_fstype)" "exfat"

run_install "tmpfs /tmp tmpfs defaults 0 0
" '/media/zvi/My Book' >/dev/null
check "a mount point with a space installs and parses back correctly" \
      "$(entry_target)" "/media/zvi/My Book"

# A pre-existing defect elsewhere must not make the step blame itself.
run_install "tmpfs /tmp tmpfs defaults 0 0
/nonexistent-mp /nowhere wumpusfs defaults 0 0
" /media/zvi/Backup >/dev/null
check "installs despite an unrelated broken entry already in the table" \
      "$(entry_target)" "/media/zvi/Backup"

echo
echo "=== install: the states that must NOT produce an entry ==="
out_of() { run_install "$1" "$2" >/dev/null; cat "$TMPROOT/out"; }

before="UUID=$UUID  /media/zvi/Elsewhere  ext4  defaults  0 0
"
run_install "$before" /media/zvi/Backup >/dev/null
check "an entry at the WRONG mount point is reported, not silently accepted" \
      "$(entry_target)" "/media/zvi/Elsewhere"
check "  ...and it warns about the ConditionPathExists mismatch" \
      "$(grep -c 'would skip forever' "$TMPROOT/out")" "1"

# A commented-out entry is not an entry: the old substring grep counted it as
# "already installed" and returned ✓ having done nothing.
run_install "# UUID=$UUID  /media/zvi/Backup  ext4  defaults  0 0
" /media/zvi/Backup >/dev/null
check "a commented-out entry does not count as already installed" \
      "$(entry_target)" "/media/zvi/Backup"

# The old guard built an ERE from the mount point with only '/' escaped, so an
# unrelated path could look like a conflict.
run_install "/dev/sda1  /media/zvi/MyXBackup  ext4  defaults  0 0
" /media/zvi/My.Backup >/dev/null
check "a regex-lookalike path is not mistaken for a conflict" \
      "$(entry_target)" "/media/zvi/My.Backup"

run_install "/dev/sda1  /media/zvi/Backup  ext4  defaults  0 0
" /media/zvi/Backup >/dev/null
check "a real conflict on the mount point is refused" \
      "$(entry_target)" ""
check "  ...with a warning naming the other entry" \
      "$(grep -c 'already targets' "$TMPROOT/out")" "1"

echo
echo "=== install: idempotence ==="
run_install "tmpfs /tmp tmpfs defaults 0 0
" /media/zvi/Backup >/dev/null
first="$(cat "$FSTAB")"
BACKUP_EXTERNAL_UUID="$UUID" BACKUP_EXTERNAL_REPO="/media/zvi/Backup/restic" \
  install_external_fstab >"$TMPROOT/out" 2>&1
check "a second run changes nothing" "$(cat "$FSTAB")" "$first"
check "  ...and says so" "$(grep -c 'already mounts' "$TMPROOT/out")" "1"

echo
echo "=== backup-doctor: which external state gets reported ==="
# The doctor lives in zsh/functions/system.sh, which is zsh. Drive it through
# zsh with the two disk-state predicates stubbed, so the branch SELECTION is
# what is under test — the predicates themselves are checked above.
doctor_state() {
  # $1 mounted?  $2 attached?  $3 repo (blank = unconfigured)
  zsh -c '
    source '"$DOTFILES"'/zsh/functions/system.sh
    _backup_external_mounted()  { [[ "'"$1"'" == yes ]]; }
    _backup_external_attached() { [[ "'"$2"'" == yes ]]; }
    sudo() { return 1; }          # no udev rule, no unit file
    findmnt() { return 1; }       # no fstab entry
    _BD_FAIL=0 _BD_WARN=0
    _backup_doctor_external "'"$DOTFILES"'" "some-uuid" "'"$3"'" "'"${3%/restic}"'"
  ' 2>&1
}

got="$(doctor_state yes yes /mnt/ext/restic)"
check "mounted → docked" \
      "$(printf '%s' "$got" | grep -c 'external HDD docked')" "1"

got="$(doctor_state no yes /mnt/ext/restic)"
check "attached but not mounted → hard failure" \
      "$(printf '%s' "$got" | grep -c '✗ external HDD attached but NOT MOUNTED')" "1"

got="$(doctor_state no no /mnt/ext/restic)"
check "genuinely absent → neutral note, not a failure" \
      "$(printf '%s' "$got" | grep -c '• external HDD not attached')" "1"
check "  ...and nothing claims it is docked" \
      "$(printf '%s' "$got" | grep -c 'external HDD docked')" "0"

got="$(doctor_state no no "")"
check "no repo configured → says so instead of 'not attached'" \
      "$(printf '%s' "$got" | grep -c 'BACKUP_EXTERNAL_REPO blank')" "1"
check "  ...and does not report a disk state it cannot know" \
      "$(printf '%s' "$got" | grep -c 'not attached')" "0"

echo
if (( FAIL > 0 )); then
  printf '\033[1;31m✗ %d failed\033[0m, %d passed\n' "$FAIL" "$PASS"
  exit 1
fi
printf '\033[0;32m✓ all %d checks passed\033[0m\n' "$PASS"
