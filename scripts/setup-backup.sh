#!/usr/bin/env bash
#
# scripts/setup-backup.sh
# =======================
#
# One-time, guided, IDEMPOTENT installer for the workstation backup system
# (restic + resticprofile → external HDD + Backblaze B2). Run it via `backup-setup`.
#
# This is the sudo-using counterpart to ./install (which stays sudo-free and only
# drops the ~/.backup.local template). Everything here is re-runnable: each step
# detects "already done" and skips. Run it again after editing ~/.backup.local.
#
# What it does:
#   1.  Install restic (root PATH) + resticprofile (the orchestrator)
#   2.  Generate the restic repo key  → /etc/restic/repo.key  (+ store in Bitwarden)
#   3.  Lay down /etc/restic + /etc/resticprofile (configs COPIED, never symlinked)
#   4.  restic init the external + B2 repositories
#   5.  Install systemd timers (backup, dock trigger, weekly verification)
#   6.  Guide the ransomware-resistant B2 key + lifecycle setup
#   7.  Install Timeshift (+ optional apt pre-upgrade autosnap)
#   8.  Back up the LUKS header (re-taken when stale)
#   9.  Build the offline emergency kit (age)
#   10. Validate + dry-run + alerting check (run `backup-doctor` to confirm)
#
# See docs/BACKUP_AND_RESTORE_GUIDE.md for the full picture.

set -euo pipefail

# --- paths ------------------------------------------------------------------
DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ETC_RESTIC="/etc/restic"
REPO_KEY="${ETC_RESTIC}/repo.key"
ENV_FILE="${ETC_RESTIC}/backup.local"
RP_DIR="/etc/resticprofile"
RP_CONFIG="${RP_DIR}/profiles.toml"
USER_CONFIG="${HOME}/.backup.local"
# Overridable so the external-drive logic can be exercised against a fake table
# without root — see scripts/test-backup-external.sh. Never set in normal use.
FSTAB="${FSTAB:-/etc/fstab}"

# --- pretty logging (mirrors scripts/apply-gnome-settings.sh) ---------------
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
fi
log() {
  local level="$1"; shift; local msg="$*"
  case "$level" in
    INFO)    echo -e "${BLUE}▶${RESET} $msg" ;;
    SUCCESS) echo -e "${GREEN}✓${RESET} $msg" ;;
    WARNING) echo -e "${YELLOW}⚠${RESET} $msg" >&2 ;;
    STEP)    echo -e "\n${CYAN}${BOLD}➜ $msg${RESET}" ;;
  esac
}
confirm() {
  local message="${1:-Proceed?}"; printf "%s [y/N] " "$message"; read -r r
  case "$r" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}
has_command() { command -v "$1" &>/dev/null; }

# Render a __BACKUP_*__ template (user/home/hostname) to stdout. backup-doctor
# runs the SAME script for its drift compare, so keep all substitution there.
render() { bash "$DOTFILES/scripts/backup-render.sh" "$1"; }

# Same renderer with the external-drive placeholders supplied: $1 UUID,
# $2 escaped .mount unit, $3 template. `env` rather than a bare assignment
# prefix so the values cannot leak into the rest of the script.
render_external() {
  env BACKUP_RENDER_EXTERNAL_UUID="$1" BACKUP_RENDER_EXTERNAL_MOUNT_UNIT="$2" \
      bash "$DOTFILES/scripts/backup-render.sh" "$3"
}

# Render template $1 to root-owned $2 with mode $3 (default 644).
#
# NEVER `render ... | sudo tee /etc/...`: tee truncates the destination the
# instant the pipeline starts, long before the renderer's exit status is known,
# so a render that fails — an unresolved __BACKUP_*__ placeholder (a hard error
# since #87), a missing `hostname` under `set -e` — leaves a ZERO-BYTE file in
# /etc. An empty includes.txt backs up nothing; an empty .service is a unit that
# does nothing. Both install "successfully" and read as present forever.
render_install() {
  local tpl="$1" dest="$2" mode="${3:-644}" tmp
  tmp="$(mktemp)"
  if ! render "$tpl" > "$tmp"; then
    rm -f "$tmp"
    log WARNING "could not render $tpl — $dest left unchanged."
    return 1
  fi
  if ! sudo install -m "$mode" -o root -g root "$tmp" "$dest"; then
    rm -f "$tmp"
    log WARNING "could not install $dest."
    return 1
  fi
  rm -f "$tmp"
}

# ===========================================================================
# 0. Preflight
# ===========================================================================
preflight() {
  log STEP "Preflight"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    log WARNING "Run as your normal user (it calls sudo as needed), not as root."
    exit 1
  fi
  if ! sudo -v; then
    log WARNING "sudo is required."
    exit 1
  fi
  if [[ ! -f "$USER_CONFIG" ]]; then
    log WARNING "$USER_CONFIG not found. Run 'backup-init' first, edit it, then re-run."
    exit 1
  fi
  # Load the user's machine config (repo URLs, B2 creds, UUID, notify settings).
  set -a; # shellcheck source=/dev/null
  source "$USER_CONFIG"; set +a
  log SUCCESS "Loaded $USER_CONFIG"
}

# ===========================================================================
# 1. Install restic + resticprofile
# ===========================================================================
install_tools() {
  log STEP "1. Install restic + resticprofile"

  if has_command restic; then
    log SUCCESS "restic present: $(restic version 2>/dev/null | head -1)"
  else
    log INFO "Installing restic via apt (reliable on root PATH for systemd)…"
    sudo apt-get update -qq && sudo apt-get install -y restic
  fi
  # Ensure restic is on the ROOT PATH (systemd runs as root). If only a mise shim
  # exists in the user's PATH, symlink the resolved binary into /usr/local/bin.
  if ! sudo test -x /usr/bin/restic && ! sudo test -x /usr/local/bin/restic; then
    local rbin; rbin="$(command -v restic || true)"
    [[ -n "$rbin" ]] && sudo ln -sf "$rbin" /usr/local/bin/restic
  fi

  if has_command resticprofile; then
    log SUCCESS "resticprofile present: $(resticprofile version 2>/dev/null | head -1)"
  else
    log INFO "Installing resticprofile to /usr/local/bin (official installer)…"
    if confirm "Download and run the resticprofile install script?"; then
      curl -fsSL https://raw.githubusercontent.com/creativeprojects/resticprofile/master/install.sh \
        | sudo sh -s -- -b /usr/local/bin
    else
      log WARNING "Skipped. Install resticprofile manually, then re-run."
      exit 1
    fi
  fi
}

# ===========================================================================
# 2. restic repo key (random) → /etc/restic/repo.key + Bitwarden
# ===========================================================================
setup_repo_key() {
  log STEP "2. restic repository key"
  sudo install -d -m 700 -o root -g root "$ETC_RESTIC"

  if sudo test -s "$REPO_KEY"; then
    log SUCCESS "$REPO_KEY already exists — keeping it."
    return 0
  fi

  local key; key="$(openssl rand -base64 48 2>/dev/null || head -c 36 /dev/urandom | base64)"
  echo
  log INFO "A new restic repository password has been generated. STORE IT FIRST:"
  echo
  echo "    Bitwarden → new Secure Note: 'restic repo key — $(hostname)'"
  echo
  echo "    $key"
  echo
  log WARNING "Without this key your backups are UNRECOVERABLE. Save it to Bitwarden"
  log WARNING "AND into the offline emergency kit (step 9) before continuing."
  if confirm "Saved the key to Bitwarden?"; then
    printf '%s' "$key" | sudo tee "$REPO_KEY" >/dev/null
    sudo chown root:root "$REPO_KEY"; sudo chmod 600 "$REPO_KEY"
    log SUCCESS "Wrote $REPO_KEY (root 0600)."
  else
    log WARNING "Aborted — nothing written. Re-run when ready to save the key."
    exit 1
  fi
}

# ===========================================================================
# 3. Lay down /etc configs (COPIED, root-owned — never symlinked)
# ===========================================================================
install_configs() {
  log STEP "3. Install /etc configs + helper scripts"

  # Rendered (not copied): restic reads these verbatim — no $HOME expansion —
  # so the user's home is baked in here. Aborting on a failed render is the
  # point: an empty includes.txt is a backup of nothing, and it would install
  # cleanly and keep reporting as present.
  render_install "$DOTFILES/examples/backup-includes.txt" "$ETC_RESTIC/includes.txt" \
    || { log WARNING "aborting — restic would back up NOTHING with an unrendered includes.txt."; return 1; }
  render_install "$DOTFILES/examples/backup-excludes.txt" "$ETC_RESTIC/excludes.txt" \
    || { log WARNING "aborting — an unrendered excludes.txt would sweep in caches and VMs."; return 1; }
  log SUCCESS "includes.txt / excludes.txt rendered → $ETC_RESTIC"

  # Root-readable copy of the secrets/URLs env file (the timers load this).
  sudo install -m 600 -o root -g root "$USER_CONFIG" "$ENV_FILE"
  log SUCCESS "$USER_CONFIG → $ENV_FILE (root 0600)"

  # resticprofile config — COPIED root-owned (root runs its hooks; a user-writable
  # config executed by root would be a privilege-escalation hole).
  sudo install -d -m 755 "$RP_DIR"
  sudo install -m 644 -o root -g root "$DOTFILES/resticprofile/profiles.toml" "$RP_CONFIG"
  log SUCCESS "profiles.toml → $RP_CONFIG (root-owned copy)"

  # Hook + helper scripts on the root PATH.
  sudo install -m 755 "$DOTFILES/scripts/backup-manifest.sh" /usr/local/bin/backup-manifest.sh
  sudo install -m 755 "$DOTFILES/scripts/restic-notify.sh"   /usr/local/bin/restic-notify
  sudo install -m 755 "$DOTFILES/scripts/backup-verify.sh"   /usr/local/bin/backup-verify.sh
  log SUCCESS "backup-manifest.sh / restic-notify / backup-verify.sh → /usr/local/bin"
}

# ===========================================================================
# 3b. External HDD: make it mount at boot, and mount it now
# ===========================================================================

# The restic repo lives one level under the mount point, and that is the ONLY
# place the mount point is recorded — restic-backup-external.service gates on
# "$repo/config", so the two must agree or the unit skips forever.
external_mount_point() { dirname "${BACKUP_EXTERNAL_REPO:?}"; }

# The escaped .mount unit name is COMPUTED, never hand-written: a path with a
# dash needs \x2d and a space needs \x20, and a wrong name yields a udev rule
# (or an After=) that validates cleanly and then never fires.
external_mount_unit() { systemd-escape -p --suffix=mount "$1"; }

# Is $1 actually a mount point? findmnt reads /proc/self/mountinfo, so this is
# exact and needs no root. `test -e "$repo/config"` is NOT equivalent: a
# leftover directory on the ROOT filesystem satisfies it while the disk sits
# unmounted, and the caller then reports "docked" while writes land on the
# internal disk.
external_is_mounted() { findmnt -rno TARGET --mountpoint "$1" >/dev/null 2>&1; }

# Refuse a mount point that would shadow live data. BACKUP_EXTERNAL_REPO is
# hand-edited in ~/.backup.local and the mount point is merely its dirname, so a
# repo path one level too shallow (the drive root instead of a directory on it)
# resolves to /media/<user>, and an ordinary typo resolves to $HOME. Everything
# downstream then passes: nothing else claims the path, the generated line
# parses, and it resolves back out of the table — so the external disk gets
# mounted over the user's home at every boot, hiding everything in it. `nofail`
# is no help; the mount succeeds. Until this check the string went straight into
# a permanent, privileged /etc/fstab write with no floor at all.
#
# Prints the account name and returns 0 when $1 is exactly <parent>/<account>
# for a parent whose children are per-user directories the SYSTEM creates: udisks2
# makes /media/<user> and /run/media/<user> on its own and mounts removable media
# inside them, and /home/<user> is the same shape. A disk mounted over one of
# those hides whatever the owning user puts there, at every boot.
#
# Asked of the system rather than of a list, for two reasons. It covers EVERY
# account, not just the one running the installer — /media/<someone-else> is no
# safer — and it needs no identity resolution at all, so the class of bug where
# `$USER` is empty and the per-user deny entries collapse to "/media/" cannot
# recur in it.
#
# REGULAR LOGIN ACCOUNTS ONLY, which is the whole discriminator. udisks makes
# these directories for accounts that log in to a desktop session; it has never
# made one for `backup` (uid 34), `games` (uid 5) or `nobody` (uid 65534). And
# /media/backup is a thoroughly plausible hand-made mount point for a backup
# disk — the guide advertises /media/backup-hdd, two characters away. Refusing
# it would not merely skip a step: install_external_udev treats an unusable
# mount point as a reason to REMOVE the hotplug rule, so a working install would
# quietly lose its remount-on-dock. The uid bounds come from the machine's own
# login.defs, with shadow-utils' defaults as the fallback.
#
# Deliberately pure, like its caller: no sudo, no writes.
path_is_account_directory() {
  local path="$1" parent leaf pw rest uid tmo k v rc
  local uid_min=1000 uid_max=60000
  if [[ -r /etc/login.defs ]]; then
    while read -r k v _; do
      case "$k" in
        UID_MIN) [[ "$v" =~ ^[0-9]+$ ]] && uid_min="$v" ;;
        UID_MAX) [[ "$v" =~ ^[0-9]+$ ]] && uid_max="$v" ;;
      esac
    done < /etc/login.defs
  fi
  # getent goes through NSS, so an LDAP/SSSD account has its parent protected
  # too — but on a host whose directory server is unreachable a lookup blocks for
  # the NSS timeout, and the installer would sit there with no output. Bound it.
  # If `timeout` itself is missing, call getent directly rather than let every
  # lookup come back empty: that would switch this entire rule off with no sign,
  # which is the failure mode this file exists to refuse.
  tmo="$(command -v timeout 2>/dev/null)" || tmo=""
  for parent in /home /media /run/media; do
    [[ "$path" == "$parent"/* ]] || continue
    leaf="${path#"$parent"/}"
    # One component only: /media/<user>/<label> is the CORRECT answer, not a hit.
    [[ -n "$leaf" && "$leaf" != */* ]] || continue
    # No pipe into `head`: under the `set -o pipefail` this file declares, head's
    # early exit would SIGPIPE getent and the assignment would fail the installer.
    rc=0
    if [[ -n "$tmo" ]]; then
      pw="$("$tmo" 2 getent passwd -- "$leaf" 2>/dev/null)" || rc=$?
    else
      pw="$(getent passwd -- "$leaf" 2>/dev/null)" || rc=$?
    fi
    # ONLY getent's exit 2 means "no such key". Every other failure is "the
    # question was never answered": 124 because timeout(1) fired when the
    # directory server did not reply, 127 because getent is not installed.
    # Folding those into the empty-output case reports "not an account" for a
    # lookup that never ran, which switches this entire rule off in silence on
    # exactly the hosts the timeout above was added for. Report a third outcome
    # and let the caller decide; it must not look like a clean "no".
    # Print the leaf even here: the caller's message has to name the thing whose
    # lookup hung, and the second call site checks $real, not $path.
    (( rc == 0 || rc == 2 )) || { printf '%s' "$leaf"; return 2; }
    (( rc == 0 )) || pw=""
    # Compare the NAME field back. `getent passwd 1000` resolves a numeric key to
    # a real account, and /media/1000 is not a directory udisks would ever make.
    [[ -n "$pw" && "${pw%%:*}" == "$leaf" ]] || continue
    rest="${pw#*:}"; rest="${rest#*:}"; uid="${rest%%:*}"
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    (( uid >= uid_min && uid <= uid_max )) || continue
    printf '%s' "$leaf"
    return 0
  done
  return 1
}

# Deliberately pure — no sudo, no writes — so scripts/test-backup-external.sh
# can exercise every rejection without root.
external_mount_point_sane() {
  local mnt="$1" me real p acct
  local acctrc=0
  local -a deny
  if [[ "$mnt" != /* ]]; then
    log WARNING "mount point '$mnt' is not an absolute path — check BACKUP_EXTERNAL_REPO in $USER_CONFIG."
    return 1
  fi
  # Every rejection below is a STRING compare, so any component that resolves to
  # something other than what it spells has to be refused up front: `/media/./x`
  # IS `/media/x` to the kernel but matches no deny-list entry. `*/./*` is not
  # decoration — it is a form a plausible hand-edit actually produces, and it
  # lands on exactly the directory the deny-list exists to protect.
  if [[ "$mnt" == *//* || "$mnt" == */. || "$mnt" == */./* \
     || "$mnt" == */.. || "$mnt" == */../* ]]; then
    log WARNING "mount point '$mnt' is not a normalised path — check BACKUP_EXTERNAL_REPO in $USER_CONFIG."
    return 1
  fi
  if [[ -L "$mnt" ]]; then
    log WARNING "mount point '$mnt' is a symlink — mount(8) resolves it elsewhere, so the string cannot be checked. Point BACKUP_EXTERNAL_REPO at the real directory."
    return 1
  fi
  # Directories a removable disk must never be mounted over. $HOME and the two
  # udisks parents are where a plausible BACKUP_EXTERNAL_REPO typo actually lands.
  deny=( / /boot /dev /etc /home /media /mnt /opt /proc /root /run /run/media
         /srv /sys /tmp /usr /var "$HOME" )
  # Kept as belt-and-braces, no longer load-bearing: path_is_account_directory
  # below is what actually refuses the udisks parents. These two stay because
  # they cost nothing and still fire if getent is unavailable or times out.
  # `id -un`, never $USER: $USER is set by login/PAM, not by the shell, so it is
  # empty under `sudo -u`, `env -i`, a systemd unit or a bare container shell —
  # and "/media/${USER:-}" is then "/media/", which matches nothing and silently
  # drops the two likeliest typo targets out of the deny-list.
  # scripts/backup-render.sh resolves the same identity the same way.
  me="$(id -un 2>/dev/null)" || me=""
  [[ -n "$me" ]] && deny+=( "/media/$me" "/run/media/$me" )
  # The resolved path is checked too, so a symlink among the PARENT components
  # cannot smuggle a denied directory past the string compare.
  real="$(realpath -m -- "$mnt" 2>/dev/null)" || real=""
  : "${real:=$mnt}"
  # The list above can only refuse spellings someone thought of, and for every
  # entry on it EXCEPT the udisks parents that does not matter: /etc, /usr and
  # $HOME are non-empty, so the content checks below refuse them whether or not
  # anyone listed them. The parents are the one case where content proves
  # nothing — /media/<user> is legitimately EMPTY whenever no drive is docked,
  # and is also legitimately the parent of the right answer — so there, and only
  # there, the string list is load-bearing and alone. Both holes found in it so
  # far (an empty $USER, and `/media/./<user>`) were in exactly that spot.
  #
  # So stop enumerating and ask the system. This still accepts /media/backup-hdd,
  # /mnt/store and /srv/backup: a hand-made directory that happens to sit under
  # one of these parents is refused only when its name is an actual account.
  acct="$(path_is_account_directory "$mnt")" || acctrc=$?
  if [[ -z "$acct" && "$acctrc" -ne 2 && "$real" != "$mnt" ]]; then
    acct="$(path_is_account_directory "$real")" || acctrc=$?
  fi
  if [[ "$acctrc" -eq 2 ]]; then
    # Not "this path is wrong" but "this run could not find out", and the two
    # need different words because they have different fixes — repair name-service
    # resolution, do not edit BACKUP_EXTERNAL_REPO. Refusing is still the answer:
    # an unverified path is the thing this whole function exists to refuse, and
    # the correct configuration is one component under /media too, so accepting
    # on a failed lookup waves through /media/<another-login-user> as readily as
    # /media/<label>. The distinct status matters at the call sites that install
    # persistent state: see install_external_udev, which must not delete a rule
    # an earlier successful run got right just because NSS hiccuped today.
    log WARNING "cannot tell whether $mnt is a per-user directory — the account lookup for '$acct' did not complete (name service unreachable, or getent missing)."
    log WARNING "Refusing rather than guessing. Fix name-service resolution and re-run, or point BACKUP_EXTERNAL_REPO outside /home, /media and /run/media."
    return 2
  fi
  if [[ -n "$acct" ]]; then
    # Name the account. Without it the refusal is baffling — the offending thing
    # is the NAME of the last component, which the path alone does not advertise.
    log WARNING "refusing to mount the external HDD over $mnt — '$acct' is a login account on this machine, so that is a per-user directory udisks creates and mounts removable media inside."
    log WARNING "BACKUP_EXTERNAL_REPO must point at a directory ON the drive (e.g. $mnt/<label>/restic), not one level up."
    return 1
  fi
  for p in "${deny[@]}"; do
    if [[ "$mnt" == "$p" || "$real" == "$p" ]]; then
      log WARNING "refusing to mount the external HDD over $mnt."
      log WARNING "BACKUP_EXTERNAL_REPO must point at a directory ON the drive (e.g. $mnt/<label>/restic), not one level up."
      return 1
    fi
  done
  # An existing non-empty directory that is not already a mount point is live
  # data on the internal disk. Mounting over it hides it at every boot, and the
  # hidden files keep consuming the root filesystem invisibly.
  if [[ -d "$mnt" ]] && ! external_is_mounted "$mnt"; then
    # "Cannot list it" is NOT "it is empty". This runs unprivileged (preflight
    # refuses to run as root), so `ls -A` on a 0700 root-owned directory —
    # /etc/ssl/private, /var/lib/private, any DynamicUser state dir — yields
    # nothing, and the emptiness test below would wave a full directory through.
    if [[ ! -r "$mnt" || ! -x "$mnt" ]]; then
      log WARNING "$mnt exists but its contents cannot be listed as ${me:-this user} — refusing to mount over a directory that cannot be checked."
      log WARNING "Point BACKUP_EXTERNAL_REPO at the drive's own mount point. Skipping."
      return 1
    fi
    if [[ -n "$(ls -A "$mnt" 2>/dev/null)" ]]; then
      log WARNING "$mnt already contains files and is not a mount point — mounting the external HDD there would hide them."
      log WARNING "Point BACKUP_EXTERNAL_REPO at the drive's own mount point, or empty/rename $mnt first. Skipping."
      return 1
    fi
  fi
  return 0
}

# Where table file $1 mounts UUID $2, or empty. Never grep /etc/fstab: a
# substring match counts a commented-out or wrong-mount-point entry as present,
# and a regex built from the mount point matches unrelated paths whenever the
# label contains . + * ? [ or (.
#
# TWO queries, because `-S UUID=x` resolves the tag through /dev/disk/by-uuid
# and therefore matches a `/dev/disk/by-uuid/x` entry — the form Ubuntu's own
# installer writes, and the form used for /boot on this machine — ONLY while the
# disk is attached. Undocked, which is the state this whole feature exists for,
# it reports "no entry" for a perfectly correct fstab; callers then add a
# duplicate, refuse the udev rule, and warn that the entry is missing. The
# second query is a literal string match on the table, so it works either way.
#
# EVERY distinct target is reported, space-joined, never just the first. Two
# entries for one UUID at two mount points is a real /etc/fstab defect, and
# `head -1` would hand back whichever came first — so if that one happened to
# match the configured mount point the caller would say "already installed ✓"
# and go on to install the udev rule, with the conflicting second entry never
# mentioned. A multi-target answer can equal no single mount point, so the
# callers' `!= "$mnt"` comparison reports it by construction.
fstab_target_for_uuid() {
  local table="$1" uuid="$2" out
  out="$(LC_ALL=C findmnt --fstab --tab-file "$table" -no TARGET -S "UUID=$uuid" 2>/dev/null | sort -u | tr '\n' ' ')"
  if [[ -z "${out// /}" ]]; then
    out="$(LC_ALL=C findmnt --fstab --tab-file "$table" -no TARGET -S "/dev/disk/by-uuid/$uuid" 2>/dev/null | sort -u | tr '\n' ' ')"
  fi
  printf '%s' "${out% }"
}

# fstab escaping. mount(8) unescapes \ooo octal, and fstab(5) requires it for
# every character that would otherwise be read as structure: space (\040), tab
# (\011), newline (\012) and backslash itself (\134). Raw, the line parses as a
# different and shorter entry, or not at all — and labels with spaces are the
# factory default on consumer drives ("My Book").
#
# The backslash MUST be substituted first, or it would re-escape the backslashes
# the later substitutions just introduced.
fstab_escape() {
  local s="$1"
  s="${s//\\/\\134}"
  s="${s// /\\040}"
  s="${s//$'\t'/\\011}"
  s="${s//$'\n'/\\012}"
  printf '%s' "$s"
}

# Number of "N parse errors" findmnt --verify reports for the table file $1.
# Parse errors are the ONLY class that matters when validating what we write.
# An entry carrying `nofail` is *expected* to report "unreachable on boot" when
# the disk is undocked or its mount point does not exist yet, so gating on
# findmnt's exit code would reject every correct entry, in exactly the two
# states this step exists to fix. Prints 999 when findmnt emits no summary at
# all (it cannot process the table), so callers treat that as unusable.
#
# LC_ALL=C is load-bearing, not hygiene: both summary strings are gettext-marked
# in util-linux and shipped translated in Ubuntu's language packs. Under a
# translated locale neither pattern below matches, every clean table returns the
# 999 sentinel, and the step refuses to install anything — permanently, on every
# re-run, for an /etc/fstab with no defect at all.
fstab_parse_errors() {
  local out n
  out="$(LC_ALL=C findmnt --verify --tab-file "$1" 2>&1 || true)"
  # findmnt has TWO summary shapes: the counted one ("N parse errors, M errors,
  # K warnings") whenever it has anything to report, and a bare "Success, no
  # errors or warnings detected" when it does not. Reading only the first makes
  # a perfectly clean table look unparseable.
  if printf '%s\n' "$out" | grep -q '^Success, no errors'; then
    printf '0\n'
    return 0
  fi
  n="$(printf '%s\n' "$out" | sed -n 's/^\([0-9][0-9]*\) parse errors,.*/\1/p' | head -1)"
  printf '%s\n' "${n:-999}"
}

install_external_fstab() {
  log STEP "3b. External HDD auto-mount (/etc/fstab)"

  # preflight() sourced $USER_CONFIG with `set -a`, so these are already exported.
  local uuid="${BACKUP_EXTERNAL_UUID:-}"
  local repo="${BACKUP_EXTERNAL_REPO:-}"
  local mnt existing claimed

  if [[ -z "$uuid" ]]; then
    log WARNING "BACKUP_EXTERNAL_UUID blank — the external HDD will NOT mount automatically."
    log WARNING "Find it with: lsblk -o NAME,UUID,LABEL  → set BACKUP_EXTERNAL_UUID in $USER_CONFIG, re-run."
    return 0
  fi
  if [[ -z "$repo" ]]; then
    log WARNING "BACKUP_EXTERNAL_REPO blank — cannot derive a mount point. Skipping."
    return 0
  fi
  mnt="$(external_mount_point)"
  external_mount_point_sane "$mnt" || return 0

  existing="$(fstab_target_for_uuid "$FSTAB" "$uuid")"
  if [[ -n "$existing" && "$existing" != "$mnt" ]]; then
    log WARNING "/etc/fstab mounts UUID=$uuid at $existing, but $USER_CONFIG implies $mnt."
    log WARNING "restic-backup-external.service gates on $repo/config, so it would skip forever — resolve by hand. Skipping."
    return 0
  fi
  if [[ -n "$existing" ]]; then
    log SUCCESS "/etc/fstab already mounts UUID=$uuid at $mnt"
  else
    claimed="$(LC_ALL=C findmnt --fstab --tab-file "$FSTAB" -no SOURCE --target "$mnt" 2>/dev/null || true)"
    if [[ -n "$claimed" ]]; then
      log WARNING "another /etc/fstab entry ($claimed) already targets $mnt — resolve by hand. Skipping."
      return 0
    fi
    write_external_fstab_entry "$uuid" "$mnt" || return 0
  fi

  # Deliberately OUTSIDE the "we just wrote it" branch. Re-running backup-setup
  # is the documented way to fix a broken external target, and the drive is
  # commonly attached-but-unmounted at that moment — which is the state this
  # whole step exists to fix, and which makes init_repos (step 4) skip the
  # external repo entirely.
  mount_external_now "$uuid" "$mnt"
}

# Build a validated candidate fstab into $4: the table $3 plus an entry for
# UUID $1 at mount point $2. Returns non-zero (with a WARNING) rather than
# producing a file that is worse than what is already there.
#
# Deliberately pure — no sudo, no writes anywhere but $4 — so every decision it
# makes can be exercised without root by scripts/test-backup-external.sh.
build_external_fstab_candidate() {
  local uuid="$1" mnt="$2" table="$3" cand="$4"
  local fstype line base after got

  base="$(fstab_parse_errors "$table")"
  if (( base >= 999 )); then
    log WARNING "findmnt cannot process $table — fix it by hand first. Skipping."
    return 1
  fi

  # Read the real filesystem type off the disk. Hardcoding ext4 produces an
  # entry that findmnt --verify ACCEPTS (a type mismatch is only a warning) and
  # that then fails to mount with "wrong fs type" — which `nofail` turns into
  # the silent non-mount this step exists to prevent. External backup drives
  # are commonly exFAT/NTFS (cross-machine readable) or btrfs/xfs. `auto` when
  # the disk is not attached to be read: mount(8) probes at mount time.
  fstype="$(lsblk -no FSTYPE "/dev/disk/by-uuid/$uuid" 2>/dev/null | head -1)"
  : "${fstype:=auto}"

  # nofail                       : an absent external disk must never break boot
  # x-systemd.device-timeout=10s : don't stall boot waiting for a sleeping USB disk
  # nosuid,nodev                 : a removable disk must not be able to bring in
  #                                setuid binaries or device nodes. NOT noexec —
  #                                this is a general-purpose external volume that
  #                                happens to host the repo, not a repo-only mount,
  #                                so blocking execution there would be a surprise.
  # 0 0                          : no boot fsck — a periodic check on a multi-TB
  #                                disk can add minutes to boot; restic's own
  #                                weekly `check` covers repository integrity.
  line="UUID=$uuid  $(fstab_escape "$mnt")  $fstype  defaults,nofail,nosuid,nodev,x-systemd.device-timeout=10s  0  0"

  {
    cat "$table"
    printf '\n# External backup HDD (restic). nofail: absence must not break boot.\n%s\n' "$line"
  } > "$cand"

  # Gate 1: we must not ADD a parse error. Compared against the baseline rather
  # than requiring zero, so a pre-existing defect elsewhere in the user's fstab
  # (a removed NAS share, an old swap line) cannot make this step blame itself
  # and install nothing, forever.
  after="$(fstab_parse_errors "$cand")"
  if (( after > base )); then
    log WARNING "the generated entry does not parse — not installing. Line was:"
    log WARNING "  $line"
    return 1
  fi
  # Gate 2: the entry must resolve back OUT of the parsed table, at exactly the
  # mount point intended. This is what actually proves the line is well-formed —
  # field count, \040 escaping and all — without depending on whether the disk
  # happens to be attached right now.
  got="$(fstab_target_for_uuid "$cand" "$uuid")"
  if [[ "$got" != "$mnt" ]]; then
    log WARNING "the generated entry parses as '${got:-nothing}', not '$mnt' — not installing."
    return 1
  fi

  log INFO "entry: $line"
}

# Write the entry for UUID $1 at mount point $2. Validates a CANDIDATE file and
# only then installs it, so $FSTAB is never left in a state we have not already
# checked — no rollback to get wrong, and no .bak litter from failed attempts.
write_external_fstab_entry() {
  local uuid="$1" mnt="$2" cand bak

  cand="$(mktemp)"
  if ! build_external_fstab_candidate "$uuid" "$mnt" "$FSTAB" "$cand"; then
    rm -f "$cand"
    return 1
  fi

  bak="${FSTAB}.bak-$(date +%Y%m%d-%H%M%S)"
  # Install atomically: stage alongside the original (same filesystem) and
  # rename(2) over it, with fstab's conventional 644 root:root. A half-written
  # /etc/fstab is a broken boot, so it must never exist even for an instant.
  #
  # Checked explicitly rather than left to `set -e`: this function is called as
  # `write_external_fstab_entry ... || return 0`, and errexit does not apply
  # inside a command that is the left operand of ||.
  if ! sudo cp -a "$FSTAB" "$bak" \
     || ! sudo install -m 644 -o root -g root "$cand" "${FSTAB}.new" \
     || ! sudo mv -f "${FSTAB}.new" "$FSTAB"; then
    sudo rm -f "${FSTAB}.new"
    rm -f "$cand"
    log WARNING "could not write $FSTAB — the original is untouched (backup: $bak)."
    return 1
  fi
  rm -f "$cand"
  sudo systemctl daemon-reload
  log SUCCESS "fstab entry added (mounts at boot). Previous file: $bak"
}

# Mount the drive right now if it is attached but not mounted, so the next
# scheduled run finds it instead of waiting for a reboot.
mount_external_now() {
  local uuid="$1" mnt="$2"
  if external_is_mounted "$mnt"; then
    log SUCCESS "$mnt is mounted"
    return 0
  fi
  if [[ ! -e "/dev/disk/by-uuid/$uuid" ]]; then
    log INFO "external HDD not attached — it will mount on dock (udev, step 3c) or at boot (fstab)."
    return 0
  fi
  # mount(8) will not create the mount point. systemd's fstab generator does,
  # so the boot path works without this; the on-demand path does not.
  #
  # Record EVERY level `mkdir -p` is about to create, deepest first, not just the
  # leaf. The harm being undone below is a root-owned 0755 directory where udisks
  # expects to create its own user-owned 0700 one — and that is the PARENT,
  # /run/media/<user>, at least as often as the leaf.
  local d created=""
  if [[ ! -d "$mnt" ]]; then
    d="$mnt"
    while [[ "$d" != "/" && "$d" != "." && ! -d "$d" ]]; do
      created+="$d"$'\n'
      d="$(dirname "$d")"
    done
    sudo mkdir -p "$mnt" || { log WARNING "could not create $mnt — skipping the immediate mount."; return 0; }
  fi
  if sudo mount "$mnt"; then
    log SUCCESS "mounted $mnt"
    return 0
  fi
  log WARNING "could not mount $mnt — see: sudo mount -v $mnt (wrong filesystem type? fsck needed?)"
  # Undo the directories we just made. udisks2 owns /run/media/<user> and manages
  # /media/<user>/<label>, creating them user-owned 0700; a leftover root-owned
  # 0755 one can block or alter the desktop's own mount of the same drive. It
  # is also precisely the "leftover directory on the internal disk" that makes
  # `test -e "$repo/config"` report a docked drive that is not there.
  # rmdir only, leaf first: it cannot touch a directory that has content, so a
  # level something else has meanwhile populated is left exactly as it is.
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    sudo rmdir "$d" 2>/dev/null || break
  done <<< "$created"
}

# ===========================================================================
# 3c. External HDD: remount it whenever it comes back
# ===========================================================================
# The one place the rule's path is written down, so the install and removal
# halves cannot drift apart.
EXT_UDEV_RULES=/etc/udev/rules.d/99-backup-external.rules

# Drop a previously installed hotplug rule, saying why. Silent when there is
# nothing to remove, so it is safe on every skip path.
remove_external_udev() {
  sudo test -f "$EXT_UDEV_RULES" || return 0
  sudo rm -f "$EXT_UDEV_RULES"
  sudo udevadm control --reload 2>/dev/null || true
  log WARNING "removed the stale udev hotplug rule ($EXT_UDEV_RULES): $1."
}

install_external_udev() {
  log STEP "3c. External HDD hotplug remount (udev)"

  local uuid="${BACKUP_EXTERNAL_UUID:-}"
  local repo="${BACKUP_EXTERNAL_REPO:-}"
  local mnt unit tmp fstabmnt
  local sanerc=0

  # Every path that declines because the CONFIGURATION no longer supports a rule
  # (below) removes any rule a previous run left behind. A stale rule names a
  # UUID that may now belong to a different disk and a .mount unit that may no
  # longer exist; it keeps passing `udevadm verify` and simply never fires, and
  # nothing else would ever mention it — the doctor's drift check has to be told
  # what to compare against, which is exactly what is missing in this state.
  #
  # The two later bail-outs (render failure, udevadm rejection) deliberately do
  # NOT remove: there the configuration is still valid and only this run could
  # not produce a rule, so an installed rule is more likely correct than absent.
  # They are covered instead by the doctor's drift compare, which runs whenever
  # a UUID and mount point are configured — i.e. exactly in those two states.
  if [[ -z "$uuid" || -z "$repo" ]]; then
    log INFO "UUID/repo not set — skipping (see step 3b)."
    remove_external_udev "UUID/repo no longer configured"
    return 0
  fi
  mnt="$(external_mount_point)"
  external_mount_point_sane "$mnt" || sanerc=$?
  if (( sanerc == 2 )); then
    # Only THIS run failed to check the path. Removing the rule here would turn a
    # name-service hiccup into a permanent loss of remount-on-dock, and a rule a
    # previous run installed is likelier right than absent — the same call the
    # render and udevadm bail-outs below already make. backup-doctor's drift
    # compare is what catches a rule that really has gone stale.
    log WARNING "leaving any existing udev rule in place — the mount point could not be checked on this run."
    return 0
  elif (( sanerc != 0 )); then
    remove_external_udev "mount point is not usable"
    return 0
  fi
  # The rule starts the unit /etc/fstab generates for $mnt, so it is only
  # meaningful if fstab really mounts this UUID there. Installing it anyway
  # would produce a rule that validates and then starts a unit that does not
  # exist — the exact silent no-op this step exists to remove.
  fstabmnt="$(fstab_target_for_uuid "$FSTAB" "$uuid")"
  if [[ -z "$fstabmnt" ]]; then
    log WARNING "no /etc/fstab entry for UUID=$uuid — skipping the udev rule, which only starts the fstab-generated unit."
    remove_external_udev "no matching /etc/fstab entry"
    return 0
  fi
  if [[ "$fstabmnt" != "$mnt" ]]; then
    log WARNING "/etc/fstab mounts UUID=$uuid at $fstabmnt, not $mnt (see step 3b) — skipping the udev rule."
    remove_external_udev "/etc/fstab disagrees with the configured mount point"
    return 0
  fi
  unit="$(external_mount_unit "$mnt")"

  tmp="$(mktemp)"
  if ! render_external "$uuid" "$unit" "$DOTFILES/udev/99-backup-external.rules" > "$tmp"; then
    rm -f "$tmp"
    log WARNING "could not render udev/99-backup-external.rules — skipping (hotplug remount not installed)."
    return 0
  fi

  # `udevadm verify` only exists from systemd v254; Ubuntu 22.04 ships 249, and
  # there the missing subcommand's non-zero exit would otherwise read as "the
  # rule is bad" and silently drop hotplug remount on the older supported release.
  if udevadm verify --help >/dev/null 2>&1; then
    if ! udevadm verify "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp"
      log WARNING "udevadm rejected the generated rule — skipping (hotplug remount not installed)."
      return 0
    fi
  else
    log INFO "udevadm verify unavailable (systemd < 254) — installing the rule unchecked."
  fi

  if [[ -f "$EXT_UDEV_RULES" ]] && sudo cmp -s "$tmp" "$EXT_UDEV_RULES"; then
    rm -f "$tmp"
    log SUCCESS "udev rule already installed and current"
    return 0
  fi

  sudo install -m 644 -o root -g root "$tmp" "$EXT_UDEV_RULES"
  rm -f "$tmp"
  sudo udevadm control --reload
  log SUCCESS "udev hotplug remount installed → $EXT_UDEV_RULES"
}

# Run resticprofile as root with the config env available (for {{ .Env.* }}).
# Source /etc/restic/backup.local INSIDE the root shell (already written by
# install_configs) rather than passing creds on the command line, so the B2
# secret never shows up in `ps`/`/proc`. Mirrors _backup_rp in system.sh.
rp() {
  sudo bash -c '
    set -a; . /etc/restic/backup.local 2>/dev/null; set +a
    : "${RESTIC_PASSWORD_FILE:=/etc/restic/repo.key}"
    : "${RESTIC_COMPRESSION:=auto}"
    export RESTIC_PASSWORD_FILE RESTIC_COMPRESSION
    cfg="$1"; shift
    exec resticprofile -c "$cfg" "$@"' _ "$RP_CONFIG" "$@"
}

# restic init helper (idempotent): $1 = label, $2 = repository.
# Sources the env file inside the root shell so the B2 secret stays out of argv;
# the repo URL ($1, not a secret) is passed positionally.
init_repo() {
  local label="$1" repo="$2"
  [[ -n "$repo" ]] || { log WARNING "$label repo not set in ~/.backup.local — skipping init."; return 0; }
  if sudo bash -c '
       set -a; . /etc/restic/backup.local 2>/dev/null; set +a
       : "${RESTIC_PASSWORD_FILE:=/etc/restic/repo.key}"; export RESTIC_PASSWORD_FILE
       export RESTIC_REPOSITORY="$1"
       restic cat config >/dev/null 2>&1' _ "$repo"; then
    log SUCCESS "$label repo already initialized."
  else
    log INFO "Initializing $label repo: $repo"
    if sudo bash -c '
       set -a; . /etc/restic/backup.local 2>/dev/null; set +a
       : "${RESTIC_PASSWORD_FILE:=/etc/restic/repo.key}"; export RESTIC_PASSWORD_FILE
       export RESTIC_REPOSITORY="$1"
       restic init --repository-version 2' _ "$repo"; then
      log SUCCESS "$label repo initialized."
    else
      log WARNING "$label init failed (repo unreachable / creds / drive not docked) — re-run later."
    fi
  fi
}

# ===========================================================================
# 4. Initialize repositories
# ===========================================================================
init_repos() {
  log STEP "4. Initialize restic repositories"
  local extmnt=""
  [[ -n "${BACKUP_EXTERNAL_REPO:-}" ]] && extmnt="$(external_mount_point)"
  # The SAME floor step 3b applies before touching /etc/fstab has to apply here,
  # because this is the step that creates the repository. `external_is_mounted`
  # alone is not a floor: a BACKUP_EXTERNAL_REPO of "/restic" derives the mount
  # point "/", which IS mounted, so restic would initialise the "external"
  # repository on the ROOT filesystem — and /restic/config then satisfies the
  # unit's ConditionPathExists forever, so every 6-hourly "external" run writes
  # to the internal disk while backup-status reports "docked ✓".
  # External: only if the drive is currently docked/mounted.
  if [[ -z "$extmnt" ]]; then
    log INFO "BACKUP_EXTERNAL_REPO not set — skipping external init."
  elif ! external_mount_point_sane "$extmnt"; then
    log WARNING "external mount point unusable (see above) — skipping external init."
  elif external_is_mounted "$extmnt"; then
    sudo install -d -o root -g root "$BACKUP_EXTERNAL_REPO" 2>/dev/null || true
    init_repo "external" "$BACKUP_EXTERNAL_REPO"
  else
    log INFO "External drive not docked — skipping external init (dock it and re-run, or it inits on first dock backup)."
  fi
  init_repo "b2" "${BACKUP_B2_REPO:-}"
}

# ===========================================================================
# 5. Install systemd timers + the dock trigger
# ===========================================================================
install_schedules() {
  log STEP "5. Install systemd timers + dock trigger"

  log INFO "Validating resticprofile config…"
  if rp profiles >/dev/null; then
    log SUCCESS "profiles.toml parses."
  else
    log WARNING "resticprofile could not parse $RP_CONFIG — fix and re-run."; return 1
  fi

  log INFO "Installing schedules (systemd timers, Persistent=true)…"
  if rp schedule --all; then
    log SUCCESS "Timers installed (see: systemctl list-timers)."
  else
    log WARNING "Scheduling failed — check 'resticprofile -c $RP_CONFIG schedule --all'."
  fi

  # resticprofile's systemd-drop-in-files does NOT reliably inject an EnvironmentFile
  # into its generated @-template units (DO-448), so wire it in explicitly — otherwise
  # the scheduled services run with an empty env and {{ .Env.* }} renders "<no value>"
  # ("repository does not exist").
  for tmpl in resticprofile-backup resticprofile-check; do
    sudo install -d -m 755 "/etc/systemd/system/${tmpl}@.service.d"
    printf '[Service]\nEnvironmentFile=%s\n' "$ENV_FILE" \
      | sudo tee "/etc/systemd/system/${tmpl}@.service.d/10-backup-env.conf" >/dev/null
  done
  sudo systemctl daemon-reload
  log SUCCESS "EnvironmentFile drop-in wired into scheduled backup/check services."

  # External backup: a timer drives a ConditionPathExists-gated oneshot, so it
  # backs up only when the drive is docked (loop-free; no .path unit).
  #
  # Its own function, called `|| true`, because a failure here must NOT abort
  # install_schedules: `return 1` propagates through `set -e` in main() and would
  # skip everything after it — the weekly verification timer, the LUKS header
  # backup and, worst, build_emergency_kit, the one asset a restore cannot start
  # without. One optional unit failing to render is not a reason to leave the
  # cold-start kit unbuilt.
  install_external_schedule || true

  # Weekly verification (content + restore canary), DECOUPLED from [b2.check] so a
  # verify failure can never abort the integrity check (independent failure domains).
  sudo install -m 644 "$DOTFILES/systemd/restic-verify.service" /etc/systemd/system/restic-verify.service
  sudo install -m 644 "$DOTFILES/systemd/restic-verify.timer"   /etc/systemd/system/restic-verify.timer
  sudo systemctl daemon-reload
  if sudo systemctl enable --now restic-verify.timer; then
    log SUCCESS "Verification timer armed (weekly; proves backups are complete + restorable). On demand: backup-drill."
  else
    log WARNING "Could not enable restic-verify.timer."
  fi
}

# The external half of step 5: the ConditionPathExists-gated oneshot, its
# 6-hourly timer and the After= drop-in. Split out of install_schedules so a
# failure can be reported and stepped over instead of aborting the installer.
install_external_schedule() {
  # Clean up the obsolete looping .path unit if a previous run installed it.
  sudo systemctl disable --now restic-backup-external.path 2>/dev/null || true
  sudo rm -f /etc/systemd/system/restic-backup-external.path
  render_install "$DOTFILES/systemd/restic-backup-external.service" \
                 /etc/systemd/system/restic-backup-external.service \
    || { log WARNING "external backup unit not installed — external runs will not happen."; return 1; }
  sudo install -m 644 "$DOTFILES/systemd/restic-backup-external.timer"   /etc/systemd/system/restic-backup-external.timer
  local extdropin=/etc/systemd/system/restic-backup-external.service.d
  # Gated on the same floor as steps 3b/4: pointing ConditionPathExists and the
  # After= unit at a mount point that must never be mounted over would arm a
  # 6-hourly run against the internal disk. Left ungated, the shipped
  # ConditionPathExists names a path that does not exist, so the unit skips —
  # which is the safe outcome.
  if [[ -n "${BACKUP_EXTERNAL_REPO:-}" ]] && external_mount_point_sane "$(external_mount_point)"; then
    sudo sed -i "s|ConditionPathExists=.*|ConditionPathExists=${BACKUP_EXTERNAL_REPO}/config|" /etc/systemd/system/restic-backup-external.service
    # Order the run AFTER the external .mount unit. `nofail` deliberately takes
    # that mount out of local-fs.target's ordering, so at boot the timer's
    # Persistent=true catch-up can fire while the USB disk is still enumerating
    # (18-21s, measured) — ConditionPathExists is then false and systemd SKIPS
    # the unit, which is the silent non-run this whole step exists to prevent.
    #
    # Ordering ONLY. Requires= / RequiresMountsFor= would make an undocked disk
    # a FAILED unit on every 6-hourly window instead of a clean skip, which is
    # the false "Backup FAILED" alarm the ConditionPathExists design was chosen
    # to avoid. A drop-in rather than an edit: the escaped unit name contains
    # backslashes that sed's `a` command would eat.
    sudo install -d -m 755 "$extdropin"
    printf '[Unit]\nAfter=%s\n' "$(external_mount_unit "$(external_mount_point)")" \
      | sudo tee "$extdropin/10-external-mount.conf" >/dev/null
  else
    sudo rm -f "$extdropin/10-external-mount.conf"
  fi
  sudo systemctl daemon-reload
  if sudo systemctl enable --now restic-backup-external.timer; then
    log SUCCESS "External timer armed (every 6h; runs only when docked). Immediate: backup-now external."
  else
    log WARNING "Could not enable restic-backup-external.timer."
  fi
}

# ===========================================================================
# 6. Ransomware-resistant B2 (guidance — append-only key + lifecycle)
# ===========================================================================
guide_b2_hardening() {
  log STEP "6. Ransomware-resistant B2 (append-only key + lifecycle)"
  cat <<'EOF'
  Do this once in the Backblaze console / b2 CLI (it cannot be safely automated here):

  a) BACKUP (timer) key — APPEND-ONLY (the key stored in ~/.backup.local):
       capabilities: listBuckets,listFiles,readFiles,writeFiles   (NO deleteFiles)
     A stolen laptop key then cannot destroy your cloud history.

  b) RESTORE/PRUNE key — FULL access (read+delete). Keep it ONLY in the offline
     emergency kit, never on this machine. Used by `backup-prune` and on restore day.

  c) Lifecycle rule on the bucket (reaps versions restic "hides", 30-day window):
       b2 bucket update <bucket> allPrivate \
         --lifecycleRule '{"daysFromHidingToDeleting":30,"daysFromUploadingToHiding":null,"fileNamePrefix":""}'

  NOTE: do NOT enable Object Lock — it conflicts with restic's dedup and breaks prune.
EOF
  if has_command b2; then
    confirm "Open the lifecycle docs reminder noted above is enough — continue?" || true
  fi
}

# ===========================================================================
# 7. Timeshift (local file-level rollback)
# ===========================================================================
install_timeshift() {
  log STEP "7. Timeshift (local file-level rollback)"
  if has_command timeshift; then
    log SUCCESS "Timeshift already installed."
  elif confirm "Install Timeshift (rsync mode) for quick local rollback of bad /etc or apt changes?"; then
    sudo apt-get install -y timeshift
    log SUCCESS "Timeshift installed."
  else
    log INFO "Skipped Timeshift."
    return 0
  fi
  log WARNING "Timeshift on this LVM-on-LUKS layout is for FILE-LEVEL rollback only —"
  log WARNING "do NOT rely on it for bare-metal restore (known LVM-on-LUKS restore bug)."
  log INFO "Configure snapshots + schedule in the Timeshift GUI (RSYNC mode; exclude the same caches)."

  # Optional: auto-snapshot before every apt transaction (one-click rollback of a
  # bad upgrade). Opt-in + low priority — the brick was hardware, not a bad upgrade,
  # and Timeshift can't help a dead disk. timeshift-autosnap may need a PPA, so skip
  # gracefully if apt can't find it.
  if has_command timeshift && ! dpkg -s timeshift-autosnap >/dev/null 2>&1; then
    if confirm "Also auto-snapshot before every apt upgrade (install timeshift-autosnap)?"; then
      if sudo apt-get install -y timeshift-autosnap 2>/dev/null; then
        log SUCCESS "timeshift-autosnap installed — snapshots run before apt operations."
      else
        log WARNING "timeshift-autosnap not available via apt — skipping (optional; needs a PPA on Ubuntu)."
      fi
    fi
  fi
}

# ===========================================================================
# 8. LUKS header backup
# ===========================================================================
backup_luks_header() {
  log STEP "8. LUKS header backup"
  local dev
  dev="$(lsblk -rno NAME,FSTYPE | awk '$2=="crypto_LUKS"{print "/dev/"$1; exit}')"
  if [[ -z "$dev" ]]; then
    log WARNING "No crypto_LUKS device found — skipping (is this disk encrypted?)."
    return 0
  fi
  local out; out="/root/luks-header-$(hostname).img"
  local stale=0
  if sudo test -s "$out"; then
    local agedays; agedays=$(( ( $(date +%s) - $(sudo stat -c %Y "$out") ) / 86400 ))
    if (( agedays > 180 )); then
      log WARNING "LUKS header backup is ${agedays}d old — re-taking (a passphrase change would make it stale)."
      stale=1
    else
      log SUCCESS "LUKS header backup exists at $out (${agedays}d old)."
    fi
  else
    stale=1
  fi
  if (( stale )); then
    # cryptsetup refuses to overwrite, so write to .new and swap — never lose the
    # existing good header if the re-take fails.
    log INFO "Backing up LUKS header of $dev → $out"
    if sudo cryptsetup luksHeaderBackup "$dev" --header-backup-file "${out}.new"; then
      sudo mv -f "${out}.new" "$out"
      log SUCCESS "LUKS header saved."
    else
      sudo rm -f "${out}.new" 2>/dev/null || true
      log WARNING "Header backup failed."
    fi
  fi
  log WARNING "COPY $out into the offline emergency kit. A corrupt header = total data"
  log WARNING "loss even with the right passphrase. Re-take it after any passphrase change."
}

# ===========================================================================
# 9. Offline emergency kit (age) — breaks the cold-start lockout
# ===========================================================================
build_emergency_kit() {
  log STEP "9. Offline emergency kit (age-encrypted)"
  if ! has_command age; then
    log INFO "age not found — installing via apt for the emergency kit…"
    sudo apt-get install -y age 2>/dev/null || true
  fi
  has_command age || { log WARNING "age unavailable — skipping kit. Install age (mise use age / apt install age), then re-run backup-setup."; return 0; }

  local id="${HOME}/.config/age/emergency-kit-identity.txt"
  if [[ -f "$id" ]]; then
    log SUCCESS "age identity already exists: $id"
  elif confirm "Generate an age identity for the emergency kit?"; then
    mkdir -p "$(dirname "$id")" && chmod 700 "$(dirname "$id")"
    age-keygen -o "$id" 2>/dev/null && chmod 600 "$id"
    log SUCCESS "age identity created: $id"
    log WARNING "PRINT this identity on paper (or QR) AND copy it to an OFFLINE USB."
    log WARNING "It is the ONLY thing that must live outside every encrypted/online system."
  fi

  local recipient=""; [[ -f "$id" ]] && recipient="$(age-keygen -y "$id" 2>/dev/null || true)"
  local kit="${HOME}/emergency-kit.txt"
  if [[ ! -f "$kit" && ! -f "${kit%.txt}.age" ]]; then
    cat >"$kit" <<EOF
EMERGENCY KIT — $(hostname)   (fill in, then encrypt, then SHRED this plaintext)
============================================================================
restic repo password        : (from Bitwarden 'restic repo key — $(hostname)')
B2 FULL-access key id/secret : (read+delete key — restore & prune)
B2 account login + 2FA codes :
Bitwarden master pw + 2FA recovery code :
LUKS passphrase(s)          :
LUKS header backup location : /root/luks-header-$(hostname).img (also copy to USB)
Home/office WiFi PSK        :
GitHub PAT (HTTPS clone)    :
Runbook                     : docs/BACKUP_AND_RESTORE_GUIDE.md (Disaster Recovery)
EOF
    chmod 600 "$kit"
    log SUCCESS "Kit template written: $kit"
    [[ -n "$recipient" ]] && {
      echo "  Fill it in, then encrypt and destroy the plaintext:"
      echo "      age -r $recipient -o ${kit%.txt}.age $kit && shred -u $kit"
      echo "  Store emergency-kit.age on the OFFLINE USB and inside the restic repo."
    }
  else
    log INFO "Emergency kit already present — leaving it."
  fi
}

# ===========================================================================
# 10. Validate + dry run
# ===========================================================================
final_checks() {
  log STEP "10. Validate + dry-run"
  if [[ -n "${BACKUP_B2_REPO:-}" && -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    log INFO "Dry-run backup to B2 (no data written)…"
    rp -n b2 backup --dry-run --verbose || log WARNING "Dry-run reported an issue — review above."
  fi

  # Make the alerting non-theoretical: a blank dead-man's-switch URL means you will
  # NOT be told when backups/verification stop — the silent-failure trap.
  if [[ -z "${BACKUP_HC_URL_B2:-}" || -z "${BACKUP_HC_URL_VERIFY:-}" ]]; then
    log WARNING "Healthcheck URL(s) blank in ~/.backup.local — overdue-backup/verify alerting is INERT."
    log WARNING "Create checks at https://healthchecks.io, set BACKUP_HC_URL_B2 / BACKUP_HC_URL_VERIFY, then re-run."
  fi

  echo
  log SUCCESS "Backup setup complete."
  log INFO "Next: dock the 'Backup' HDD (auto-runs external) • check 'backup-status' • 'systemctl list-timers'"
  log INFO "Verify the whole chain:  backup-doctor   •   prove a restore works:  backup-drill"
  log INFO "Finish the offline kit (step 9) and read docs/BACKUP_AND_RESTORE_GUIDE.md (run a restore drill!)."
}

main() {
  preflight
  install_tools
  setup_repo_key
  install_configs
  install_external_fstab
  install_external_udev
  init_repos
  install_schedules
  guide_b2_hardening
  install_timeshift
  backup_luks_header
  build_emergency_kit
  final_checks
}

# Sourced (BASH_SOURCE != $0) by scripts/test-backup-external.sh, which
# exercises the external-drive steps against a fake fstab. Running the installer
# from a test would be catastrophic, so guard the entrypoint rather than relying
# on the test to be careful.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
