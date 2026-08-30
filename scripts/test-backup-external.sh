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
source "$DOTFILES/scripts/setup-backup.sh" || {
  printf '\033[1;31mFATAL\033[0m: could not source %s\n' "$DOTFILES/scripts/setup-backup.sh" >&2
  exit 1
}
# The installer's own `set -euo pipefail` ran during that source, so errexit is
# now live in THIS shell. A suite whose whole job is to run things that are
# expected to fail cannot have it: `got="$(something_that_returns_1)"` is an
# assignment, so its non-zero status kills the run silently, mid-table, with the
# remaining checks simply never executed and no failure count printed. Restore
# the options this file declared for itself.
set +e
set -uo pipefail

# Assert the code under test is actually loaded, before asserting anything about
# what it does. Many checks below are of the form "no entry was installed" or
# "nothing claims the disk is docked" — and absence is precisely what a suite
# that sourced nothing produces. A review demonstrated this file printing seven
# green ticks from a directory where the source above had failed and every
# helper was "command not found". A suite for silent failures must not have one.
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

# Fail loudly on a missing dependency rather than letting every check that
# depends on it quietly report the "nothing happened" answer it expects.
missing=()
for tool in findmnt systemd-escape zsh; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
(( ${#missing[@]} == 0 )) || fatal "required tool(s) not installed: ${missing[*]}"

missing=()
for fn in install_external_fstab build_external_fstab_candidate \
          write_external_fstab_entry mount_external_now install_external_udev \
          remove_external_udev external_mount_point external_mount_unit \
          external_is_mounted external_mount_point_sane fstab_escape \
          fstab_parse_errors fstab_target_for_uuid render_install; do
  declare -F "$fn" >/dev/null || missing+=("$fn")
done
(( ${#missing[@]} == 0 )) || fatal "not defined after sourcing setup-backup.sh: ${missing[*]}"
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
#
# Single-query on purpose: it must see ONLY the `UUID=` form this installer
# writes. It cannot see a `/dev/disk/by-uuid/` entry while the disk is absent —
# that asymmetry is the bug fstab_target_for_uuid exists to fix, so assertions
# about that form check the installer's own log, not this helper.
entry_target() { findmnt --fstab --tab-file "$FSTAB" -no TARGET -S "UUID=$UUID" 2>/dev/null; }
entry_fstype() { findmnt --fstab --tab-file "$FSTAB" -no FSTYPE -S "UUID=$UUID" 2>/dev/null; }

echo "=== pure helpers ==="
check "fstab_escape leaves a plain path alone" \
      "$(fstab_escape /media/zvi/Backup)" "/media/zvi/Backup"
check "fstab_escape encodes spaces as \\040" \
      "$(fstab_escape '/media/zvi/My Book')" '/media/zvi/My\040Book'
check "fstab_escape encodes a tab as \\011" \
      "$(fstab_escape "$(printf '/mnt/a\tb')")" '/mnt/a\011b'
check "fstab_escape encodes a backslash as \\134" \
      "$(fstab_escape '/mnt/a\b')" '/mnt/a\134b'
check "fstab_escape escapes the backslash BEFORE the space (no double-escape)" \
      "$(fstab_escape '/mnt/a\ b')" '/mnt/a\134\040b'
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

# `-S UUID=x` resolves the tag through /dev/disk/by-uuid, so on its own it finds
# a `/dev/disk/by-uuid/x` entry — the form Ubuntu's installer writes — only while
# the disk is ATTACHED. Undocked (always, for this fake UUID) it reports nothing,
# and every caller then concludes a correct fstab has no entry.
printf 'UUID=%s /media/zvi/Backup ext4 defaults,nofail 0 0\n' "$UUID" > "$TMPROOT/t3"
check "fstab_target_for_uuid finds a UUID= entry" \
      "$(fstab_target_for_uuid "$TMPROOT/t3" "$UUID")" "/media/zvi/Backup"
printf '/dev/disk/by-uuid/%s /media/zvi/Backup ext4 defaults,nofail 0 0\n' "$UUID" > "$TMPROOT/t4"
check "fstab_target_for_uuid finds a /dev/disk/by-uuid entry with the disk absent" \
      "$(fstab_target_for_uuid "$TMPROOT/t4" "$UUID")" "/media/zvi/Backup"
printf 'tmpfs /tmp tmpfs defaults 0 0\n' > "$TMPROOT/t5"
check "fstab_target_for_uuid finds nothing when there is nothing" \
      "$(fstab_target_for_uuid "$TMPROOT/t5" "$UUID")" ""

echo
echo "=== the mount-point sanity floor ==="
# The mount point is only ever a dirname of a hand-edited repo path, and before
# this floor it went straight into a permanent, privileged /etc/fstab write.
check "a normal drive path is accepted" \
      "$(external_mount_point_sane /media/zvi/Backup 2>/dev/null && echo ok)" "ok"
check "\$HOME is refused" \
      "$(external_mount_point_sane "$HOME" 2>/dev/null && echo ok)" ""
check "  ...and says why" \
      "$(external_mount_point_sane "$HOME" 2>&1 | grep -c 'refusing to mount')" "1"
check "/ is refused"      "$(external_mount_point_sane / 2>/dev/null && echo ok)" ""
check "/home is refused"  "$(external_mount_point_sane /home 2>/dev/null && echo ok)" ""
check "/media is refused" "$(external_mount_point_sane /media 2>/dev/null && echo ok)" ""
check "/media/\$USER (repo path one level too shallow) is refused" \
      "$(external_mount_point_sane "/media/${USER:-nobody}" 2>/dev/null && echo ok)" ""
check "a relative path is refused" \
      "$(external_mount_point_sane relative/path 2>/dev/null && echo ok)" ""
check "an unnormalised path is refused" \
      "$(external_mount_point_sane /media/zvi/../Backup 2>/dev/null && echo ok)" ""
mkdir -p "$TMPROOT/populated" && : > "$TMPROOT/populated/live-data"
check "an existing non-empty directory is refused (mounting over it hides data)" \
      "$(external_mount_point_sane "$TMPROOT/populated" 2>/dev/null && echo ok)" ""
check "  ...and says why" \
      "$(external_mount_point_sane "$TMPROOT/populated" 2>&1 | grep -c 'would hide them')" "1"
mkdir -p "$TMPROOT/empty"
check "an existing EMPTY directory is fine (the normal undocked case)" \
      "$(external_mount_point_sane "$TMPROOT/empty" 2>/dev/null && echo ok)" "ok"

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

# The dangerous one. A repo path one level too shallow, or a plain typo, used to
# resolve to a live directory and get mounted over at every boot.
run_install "tmpfs /tmp tmpfs defaults 0 0
" "$HOME" >/dev/null
check "a mount point of \$HOME is refused, not written to fstab" \
      "$(entry_target)" ""
check "  ...with a warning explaining what BACKUP_EXTERNAL_REPO should be" \
      "$(grep -c 'refusing to mount the external HDD over' "$TMPROOT/out")" "1"
run_install "tmpfs /tmp tmpfs defaults 0 0
" "/media/${USER:-nobody}" >/dev/null
check "a mount point of /media/\$USER is refused" "$(entry_target)" ""

# The by-uuid form is what Ubuntu's own installer writes. Undocked, the old
# single query saw nothing here and the step added a SECOND entry for the same
# disk at the same mount point.
run_install "/dev/disk/by-uuid/$UUID  /media/zvi/Backup  ext4  defaults,nofail  0 0
" /media/zvi/Backup >/dev/null
check "an existing /dev/disk/by-uuid entry counts as already installed" \
      "$(grep -c 'already mounts' "$TMPROOT/out")" "1"
check "  ...and no duplicate line is appended" \
      "$(grep -c "$UUID" "$FSTAB")" "1"

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
  # $4 BACKUP_EXTERNAL_UUID (blank = never set; the state every pre-existing
  #    install is in, since the key went unread for the whole life of the system)
  local uuid="${4-some-uuid}"
  zsh -c '
    source '"$DOTFILES"'/zsh/functions/system.sh
    _backup_external_mounted()  { [[ "'"$1"'" == yes ]]; }
    _backup_external_attached() { [[ "'"$2"'" == yes ]]; }
    sudo() { return 1; }          # no udev rule, no unit file
    findmnt() { return 1; }       # no fstab entry
    sed() { return 1; }           # no ConditionPathExists to read
    _BD_FAIL=0 _BD_WARN=0
    _backup_doctor_external "'"$DOTFILES"'" "'"$uuid"'" "'"$3"'" "'"${3%/restic}"'"
  ' 2>&1
}

# Same guard as on the bash side, for the same reason: if system.sh fails to
# source, doctor_state returns an error message and every `grep -c` below
# dutifully reports 0 — which is exactly what two of these checks expect.
# Captured, not piped into `grep -q`: grep exits on the first match, and under
# `set -o pipefail` the resulting SIGPIPE on the producer makes the pipeline
# report failure even when the string is present.
got="$(doctor_state yes yes /mnt/ext/restic)"
case "$got" in
  *'external HDD docked'*) ;;
  *) fatal "_backup_doctor_external produced no usable output:
$got" ;;
esac

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

got="$(doctor_state no no "" "")"
check "no repo configured → says so instead of 'not attached'" \
      "$(printf '%s' "$got" | grep -c 'BACKUP_EXTERNAL_REPO blank')" "1"
check "  ...and does not report a disk state it cannot know" \
      "$(printf '%s' "$got" | grep -c 'not attached')" "0"
# One non-configuration, one warning. Telling a user with no external drive to
# set up auto-mount for a target that does not exist is noise, and noise in a
# checker teaches people to skim it.
check "  ...and does not warn twice about the same non-configuration" \
      "$(printf '%s' "$got" | grep -c 'BACKUP_EXTERNAL_UUID blank')" "0"
check "  ...while a configured repo with no UUID still gets that warning" \
      "$(doctor_state no no /mnt/ext/restic "" | grep -c 'BACKUP_EXTERNAL_UUID blank')" "1"

echo
echo "=== render_install: a failed render must not damage the destination ==="
# backup-render.sh became fallible when unresolved placeholders were made a hard
# error, but three call sites still piped it into `sudo tee` over a live /etc
# file. tee truncates the moment the pipeline starts, so a failed render left a
# ZERO-BYTE includes.txt (restic backs up nothing) or .service (a unit that does
# nothing) — installed, and reading as present forever.
printf 'PRE-EXISTING CONTENT\n' > "$TMPROOT/dest"
printf 'needs __BACKUP_EXTERNAL_UUID__\n' > "$TMPROOT/tpl.txt"
check "a template with an unresolved placeholder is refused" \
      "$(render_install "$TMPROOT/tpl.txt" "$TMPROOT/dest" 2>/dev/null && echo ok || echo refused)" "refused"
check "  ...and the destination is left exactly as it was" \
      "$(cat "$TMPROOT/dest")" "PRE-EXISTING CONTENT"
check "  ...where 'render | tee' would have left it empty (why this helper exists)" \
      "$( { render "$TMPROOT/tpl.txt" | tee "$TMPROOT/dest2" >/dev/null; } 2>/dev/null; stat -c %s "$TMPROOT/dest2")" "0"
check "a template that renders cleanly is installed" \
      "$(printf 'plain\n' > "$TMPROOT/tpl2.txt"
         render_install "$TMPROOT/tpl2.txt" "$TMPROOT/dest3" >/dev/null 2>&1
         cat "$TMPROOT/dest3" 2>/dev/null)" "plain"

echo
echo "=== the udev rule template ==="
rendered="$(BACKUP_RENDER_EXTERNAL_UUID="$UUID" \
            BACKUP_RENDER_EXTERNAL_MOUNT_UNIT='mnt-ext.mount' \
            bash "$DOTFILES/scripts/backup-render.sh" \
                 "$DOTFILES/udev/99-backup-external.rules")"
check "renders with no placeholder left behind" \
      "$(printf '%s' "$rendered" | grep -c '__BACKUP_')" "0"
check "renders exactly one rule line" \
      "$(printf '%s\n' "$rendered" | grep -vc '^\s*\(#.*\)\?$')" "1"
check "substitutes the UUID into ENV{ID_FS_UUID}" \
      "$(printf '%s' "$rendered" | grep -c "ENV{ID_FS_UUID}==\"$UUID\"")" "1"
# The renderer replaces every occurrence of a token, comments included, so a
# header that spelled the placeholders out had its own explanation overwritten
# with the values in the only copy an administrator ever opens.
check "the header still explains what is substituted" \
      "$(printf '%s' "$rendered" | grep -c 'ENV{SYSTEMD_WANTS}  <- systemd-escape')" "1"
check "an unset placeholder is a hard error, not a blank substitution" \
      "$(bash "$DOTFILES/scripts/backup-render.sh" \
              "$DOTFILES/udev/99-backup-external.rules" >/dev/null 2>&1 && echo ok || echo refused)" "refused"

echo
if (( FAIL > 0 )); then
  printf '\033[1;31m✗ %d failed\033[0m, %d passed\n' "$FAIL" "$PASS"
  exit 1
fi
printf '\033[0;32m✓ all %d checks passed\033[0m\n' "$PASS"
