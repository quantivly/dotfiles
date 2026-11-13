#!/usr/bin/env bash
# setup-fingerprint.sh — let sudo take a fingerprint AFTER the password, and keep
# the greeter password-only, without ever putting a fingerprint wait in front of
# a password anywhere.
#
#   /etc/pam.d/sudo-fingerprint        from pam/   root 0644
#       the password first, then (gated) the fingerprint
#   /usr/local/libexec/fingerprint-should-skip   from pam/   root 0755
#       the gate: sudo or sudo-i only, a real terminal, the lid open
#   /etc/pam.d/sudo, /etc/pam.d/sudo-i           ONE line each, edited in place
#       `@include sudo-fingerprint` immediately before
#       `@include common-auth`. Both are sudo-common conffiles: one line, never a
#       replaced file.
#   /etc/gdm3/greeter.dconf-defaults             TWO lines, edited in place
#       enable-fingerprint-authentication=false for the GREETER only, because a
#       fingerprint login leaves the GNOME keyring locked. The lock screen reads
#       the same key from your own dconf and keeps the fingerprint.
#
# The lock screen needs nothing here: GDM runs gdm-fingerprint BESIDE
# gdm-password, the one place both can be offered at once. common-auth, polkit,
# su and login are NOT touched, and --check fails if any PAM service other than
# gdm-fingerprint and this stanza ever runs pam_fprintd, which the stock
# `pam-auth-update --enable fprintd` would do in front of every password on the
# machine. Why each piece is shaped as it is: docs/FINGERPRINT.md.
#
# BEFORE THE FIRST WRITE, the sudo stack the install would leave is loaded
# through the REAL libpam (scripts/pam-stack-probe.py, pam_start_confdir) with a
# correct password standing in, and the install refuses unless it authenticates:
# one misspelled keyword in a stanza makes libpam refuse every sudo, correct
# password or not (measured: PAM_PERM_DENIED). --check loads the installed stack
# the same way. It also refuses a common-auth with any auth module outside a
# known set: the stanza's pam_unix runs BEFORE common-auth, so a correct password
# returns before a lockout check (pam_faillock) or a second factor there runs.
#
# Copied root-owned, never symlinked: root's PAM reads them. Every write is a
# root-owned temporary file RENAMED into place, so a concurrent sudo never reads
# half a stack. The ORDER is load-bearing, because libpam aborts the whole stack
# when an @include cannot be opened (measured: PAM_ABORT, before any prompt).
# So the gate and the stanza go in before any include, and every include comes
# out before the stanza does.
#
# Run via `fingerprint-setup` (zsh/functions/system.sh). NEVER by ./install —
# ./install never uses sudo. Idempotent: re-run it to resync after editing the
# repo copies. gdm is RELOADED (its ExecReload only recompiles the greeter
# config), never restarted, because a restart ends the session.
#
# Usage: setup-fingerprint.sh [--check | --remove]
#   --check   read-only, needs no sudo: is every piece installed as this checkout
#             says, does the installed sudo stack load through libpam and accept
#             a correct password, has gdm compiled the greeter change, and does no
#             PAM stack put pam_fprintd in front of a password? Exit 1 if not.
#   --remove  take every piece out again. The edited files return
#             byte-identical to what they were before the install.
#
# FINGERPRINT_SETUP_PREFIX is a TEST SEAM, not an operational knob: it prefixes
# every path so the state table can run the install for real. It is refused
# unless it is an absolute path to an existing directory, and it says so loudly
# on every run where it is set.
set -euo pipefail

MODE=install
for arg in "$@"; do
  case "$arg" in
    --check | --remove)
      if [[ "$MODE" != install ]]; then
        echo "--check and --remove cannot be combined" >&2; exit 2
      fi
      MODE="${arg#--}" ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' \
      "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# A test seam, validated rather than trusted. Empty in every real run.
PREFIX="${FINGERPRINT_SETUP_PREFIX:-}"
if [[ -n "$PREFIX" ]]; then
  [[ "$PREFIX" == /* && -d "$PREFIX" ]] || {
    echo "FINGERPRINT_SETUP_PREFIX must be an absolute path to an existing directory, got '$PREFIX'" >&2
    exit 2; }
fi

STANZA_NAME="sudo-fingerprint"
STANZA_SRC="${DOTFILES}/pam/${STANZA_NAME}"
GATE_SRC="${DOTFILES}/pam/fingerprint-should-skip"
PAM_ETC_DIR="${PREFIX}/etc/pam.d"
PAM_VENDOR_DIR="${PREFIX}/usr/lib/pam.d"
STANZA_DST="${PAM_ETC_DIR}/${STANZA_NAME}"
GATE_DIR="${PREFIX}/usr/local/libexec"
GATE_DST="${GATE_DIR}/fingerprint-should-skip"
SUDO_SERVICES=("${PAM_ETC_DIR}/sudo" "${PAM_ETC_DIR}/sudo-i")
GREETER_CONFIG="${PREFIX}/etc/gdm3/greeter.dconf-defaults"
# What gdm's generate-config compiles GREETER_CONFIG into, at every gdm start
# and on `systemctl reload gdm.service`.
GREETER_COMPILED="${PREFIX}/var/lib/gdm3/greeter-dconf-defaults"
GDM_UNIT="gdm.service"
# Every write lands at <dst>${TMP_SUFFIX} first and is renamed over <dst>.
TMP_SUFFIX=".fingerprint-setup.tmp"

INCLUDE_LINE="@include ${STANZA_NAME}"
INCLUDE_RE="^[[:space:]]*@include[[:space:]]+${STANZA_NAME}[[:space:]]*$"
COMMON_AUTH_RE='^[[:space:]]*@include[[:space:]]+common-auth[[:space:]]*$'
GREETER_SECTION='[org/gnome/login-screen]'
GREETER_MARKER='# fingerprint-setup (~/.dotfiles): no fingerprint at the greeter, so the keyring unlocks at login. docs/FINGERPRINT.md'
GREETER_KEY_LINE='enable-fingerprint-authentication=false'
GREETER_KEY_RE='^[[:space:]]*enable-fingerprint-authentication[[:space:]]*='
SECTION_HEADER_RE='^[[:space:]]*\['
COMMENT_RE='^[[:space:]]*#'
FPRINTD_MODULE_RE='(^|[[:space:]/])pam_fprintd(\.so)?([[:space:]]|$)'
# The only services that may run pam_fprintd, each where it cannot delay a
# password: GDM runs gdm-fingerprint beside gdm-password, and this stanza runs
# it after a password has already failed.
FPRINTD_ALLOWED_SERVICES=(gdm-fingerprint "$STANZA_NAME")
REQUIRED_PAM_MODULES=(pam_fprintd.so pam_exec.so)
COMMON_AUTH="${PAM_ETC_DIR}/common-auth"
# The auth modules common-auth may run. The stanza's pam_unix runs before all of
# them, so each must be one a correct password may skip: the password checks
# themselves, the stack's own deny/permit, and pam_cap (capability.conf is
# `none *` here). pam_sss is known because the gate skips non-local accounts.
# pam_fprintd is the other guard's to report, not this one's.
KNOWN_COMMON_AUTH_MODULES=(pam_unix.so pam_sss.so pam_deny.so pam_permit.so pam_cap.so pam_fprintd.so)
AUTH_LINE_RE='^[[:space:]]*-?auth[[:space:]]+(\[[^]]*\]|[^[:space:]]+)[[:space:]]+([^[:space:]]+)'
ANY_INCLUDE_RE='^[[:space:]]*@include'
BLANK_RE='^[[:space:]]*$'
PROBE="${DOTFILES}/scripts/pam-stack-probe.py"
PAM_SUCCESS=0

# Owner and mode of an installed copy. Under the test seam nothing can be
# chowned to root, so the copies belong to whoever runs the suite.
OWNER="root:root"
[[ -n "$PREFIX" ]] && OWNER="$(id -un):$(id -gn)"
STANZA_STAT="${OWNER} 644"
GATE_STAT="${OWNER} 755"

if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; BLUE=''; RED=''; RESET=''
fi
log() {
  local level="$1"; shift; local msg="$*"
  case "$level" in
    INFO)    echo -e "${BLUE}▶${RESET} $msg" ;;
    SUCCESS) echo -e "${GREEN}✓${RESET} $msg" ;;
    WARNING) echo -e "${YELLOW}⚠${RESET} $msg" >&2 ;;
    ERROR)   echo -e "${RED}✗${RESET} $msg" >&2 ;;
  esac
}

for f in "$STANZA_SRC" "$GATE_SRC"; do
  [[ -r "$f" ]] || { log ERROR "missing $f"; exit 1; }
done

if [[ -n "$PREFIX" ]]; then
  log WARNING "FINGERPRINT_SETUP_PREFIX=$PREFIX — working under a prefix, NOT on the real /etc"
fi

WORK="$(mktemp -d)" || { log ERROR "mktemp failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Rendering: what each edited file should say, computed from what it says now.
# Pure bash line loops, so a file's other bytes (trailing spaces included)
# survive untouched and nothing depends on which awk or grep is installed.
# ---------------------------------------------------------------------------

# count_matching_lines <file> <ERE> — how many lines match.
count_matching_lines() {
  local file="$1" pattern="$2" line count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $pattern ]]; then count=$((count + 1)); fi
  done <"$file"
  printf '%s\n' "$count"
}

# render_sudo_service <file> <with|without> — the file with every include of
# the stanza removed, and with one put back immediately before the single
# common-auth include.
render_sudo_service() {
  local file="$1" want="$2" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $INCLUDE_RE ]]; then continue; fi
    if [[ "$want" == with && "$line" =~ $COMMON_AUTH_RE ]]; then
      printf '%s\n' "$INCLUDE_LINE"
    fi
    printf '%s\n' "$line"
  done <"$file"
  return 0
}

# render_greeter <file> <with|without> — the file with this setup's marker (and
# the key line right after it) removed, and with both put back immediately
# after the login-screen section header.
render_greeter() {
  local file="$1" want="$2" line is_after_marker=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( is_after_marker )); then
      is_after_marker=0
      if [[ "$line" == "$GREETER_KEY_LINE" ]]; then continue; fi
    fi
    if [[ "$line" == "$GREETER_MARKER" ]]; then is_after_marker=1; continue; fi
    printf '%s\n' "$line"
    if [[ "$want" == with && "$line" == "$GREETER_SECTION" ]]; then
      printf '%s\n%s\n' "$GREETER_MARKER" "$GREETER_KEY_LINE"
    fi
  done <"$file"
  return 0
}

# foreign_greeter_settings <file> — every line in the login-screen section that
# sets the key, other than this setup's own: printed, one per line.
foreign_greeter_settings() {
  local line is_in_section=0
  while IFS= read -r line; do
    if [[ "$line" =~ $SECTION_HEADER_RE ]]; then
      is_in_section=0
      if [[ "$line" == "$GREETER_SECTION" ]]; then is_in_section=1; fi
      continue
    fi
    if (( is_in_section )) && [[ "$line" =~ $GREETER_KEY_RE ]]; then printf '%s\n' "$line"; fi
  done < <(render_greeter "$1" without)
  return 0
}

# is_fprintd_allowed <service-name> — may this service run pam_fprintd?
is_fprintd_allowed() {
  local allowed
  for allowed in "${FPRINTD_ALLOWED_SERVICES[@]}"; do
    if [[ "$1" == "$allowed" ]]; then return 0; fi
  done
  return 1
}

# fprintd_in_front_of_a_password — every EFFECTIVE PAM service file that runs
# pam_fprintd where it could delay a password, printed "<file> puts ...: <line>".
# A file in /etc/pam.d shadows the vendor file of the same name (pam.d(5)), so
# a vendor file with an /etc twin is not read. A file that cannot be read cannot
# be cleared, so it is reported too.
fprintd_in_front_of_a_password() {
  local file name line
  local -A is_seen=()
  for file in "$PAM_ETC_DIR"/* "$PAM_VENDOR_DIR"/*; do
    [[ -f "$file" ]] || continue
    name="${file##*/}"
    if [[ -n "${is_seen[$name]:-}" ]]; then continue; fi
    is_seen[$name]=1
    if is_fprintd_allowed "$name"; then continue; fi
    if [[ ! -r "$file" ]]; then
      printf '%s cannot be read, so it cannot be cleared of pam_fprintd\n' "$file"
      continue
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ $COMMENT_RE ]]; then continue; fi
      if [[ "$line" =~ $FPRINTD_MODULE_RE ]]; then
        printf '%s puts pam_fprintd where it would delay a password: %s\n' "$file" "$line"
      fi
    done <"$file"
  done
  return 0
}

# is_pam_module_installed <name.so> — in any of the directories libpam loads from.
is_pam_module_installed() {
  local dir
  for dir in "${PREFIX}"/usr/lib/*/security "${PREFIX}"/lib/*/security \
             "${PREFIX}/usr/lib/security" "${PREFIX}/lib/security"; do
    if [[ -f "$dir/$1" ]]; then return 0; fi
  done
  return 1
}

# is_greeter_compiled_stale — gdm has not recompiled since the file changed.
is_greeter_compiled_stale() {
  [[ ! -e "$GREETER_COMPILED" || "$GREETER_COMPILED" -ot "$GREETER_CONFIG" ]]
}

# does_end_in_newline <file> — every edit rewrites whole lines, so a file whose
# last line is unterminated could not be restored byte for byte.
does_end_in_newline() {
  [[ -z "$(tail -c1 "$1")" ]]
}

# is_known_common_auth_module <name.so>
is_known_common_auth_module() {
  local known
  for known in "${KNOWN_COMMON_AUTH_MODULES[@]}"; do
    if [[ "$1" == "$known" ]]; then return 0; fi
  done
  return 1
}

# modules_the_stanza_would_skip — every auth module in common-auth outside the
# known set, one line each. An include is unknown too: what it runs cannot be
# read from here.
modules_the_stanza_would_skip() {
  local line module
  if [[ ! -r "$COMMON_AUTH" ]]; then
    printf '%s cannot be read, so what it runs cannot be known\n' "$COMMON_AUTH"
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $COMMENT_RE || "$line" =~ $BLANK_RE ]]; then continue; fi
    if [[ "$line" =~ $ANY_INCLUDE_RE ]]; then
      printf '%s includes another file, whose modules a correct password at the stanza would skip: %s\n' "$COMMON_AUTH" "$line"
      continue
    fi
    if [[ ! "$line" =~ $AUTH_LINE_RE ]]; then continue; fi
    module="${BASH_REMATCH[2]##*/}"
    if is_known_common_auth_module "$module"; then continue; fi
    printf '%s has %s, which a correct password at the stanza would skip: %s\n' "$COMMON_AUTH" "$module" "$line"
  done <"$COMMON_AUTH"
  return 0
}

# build_probe_confdir <target|installed> — prints a directory holding this
# machine's PAM configuration as libpam reads it (vendor files, then /etc/pam.d
# over them), with sudo, sudo-i and the stanza as the install WOULD leave them
# (target) or as they ARE (installed), and the stanza's modules swapped for
# stand-ins: pam_permit for pam_unix (a correct password) and for the gate,
# pam_deny for pam_fprintd (no reader is touched).
build_probe_confdir() {
  local mode="$1" confdir="$WORK/pamconf" file service
  rm -rf "$confdir"
  mkdir -p "$confdir"
  for file in "$PAM_VENDOR_DIR"/* "$PAM_ETC_DIR"/*; do
    if [[ -f "$file" && -r "$file" ]]; then cp "$file" "$confdir/"; fi
  done
  if [[ "$mode" == target ]]; then
    cp "$STANZA_SRC" "$confdir/$STANZA_NAME"
    for service in "${SUDO_SERVICES[@]}"; do
      render_sudo_service "$service" with >"$confdir/${service##*/}"
    done
  fi
  if [[ -f "$confdir/$STANZA_NAME" ]]; then
    sed -i -e 's/pam_unix\.so/pam_permit.so/g' -e 's/pam_exec\.so/pam_permit.so/g' \
           -e 's/pam_fprintd\.so/pam_deny.so/g' "$confdir/$STANZA_NAME"
  fi
  printf '%s\n' "$confdir"
}

# sudo_stack_problems <target|installed> — sudo and sudo-i, loaded through the
# REAL libpam from build_probe_confdir with a correct password standing in: one
# line per service that does not authenticate. In installed mode a service that
# does not include the stanza is not this setup's to judge, and is passed over.
sudo_stack_problems() {
  local mode="$1" confdir service name outcome
  confdir="$(build_probe_confdir "$mode")"
  for service in "${SUDO_SERVICES[@]}"; do
    name="${service##*/}"
    if [[ "$mode" == installed ]] && [[ ! -r "$service" ]]; then continue; fi
    if [[ "$mode" == installed ]] && (( $(count_matching_lines "$service" "$INCLUDE_RE") == 0 )); then
      continue
    fi
    if ! outcome="$(python3 -I "$PROBE" --confdir "$confdir" --service "$name" 2>&1)"; then
      printf '%s could not be loaded through libpam: %s\n' "$name" "$outcome"
      continue
    fi
    if [[ "${outcome%% *}" != "$PAM_SUCCESS" ]]; then
      printf '%s: libpam refuses a CORRECT password through this stack (result %s)\n' "$name" "$outcome"
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# --check: the INSTALLED STATE, not the install's exit status.
# ---------------------------------------------------------------------------

# check_copy <src> <dst> <want-stat> — a regular file (a symlink back into this
# checkout would hand root a file you can write), byte-identical, owned and
# moded as wanted.
check_copy() {
  local src="$1" dst="$2" want="$3" st
  if [[ -L "$dst" ]]; then
    log ERROR "$dst is a SYMLINK — root would read a file you can write; re-run: fingerprint-setup"
    return 1
  elif [[ ! -e "$dst" ]]; then
    log ERROR "$dst is not installed — run: fingerprint-setup"
    return 1
  elif ! cmp -s "$src" "$dst"; then
    log ERROR "$dst DIFFERS from $src — re-run: fingerprint-setup"
    return 1
  fi
  st="$(stat -c '%U:%G %a' "$dst")"
  if [[ "$st" != "$want" ]]; then
    log ERROR "$dst is ${st}, not ${want} — re-run: fingerprint-setup"
    return 1
  fi
  log SUCCESS "$dst matches this checkout (${st})"
}

# check_sudo_service <file> — returns 1 on drift, 2 when sudo is BROKEN (it
# includes a stanza that is not there, so libpam aborts every sudo).
check_sudo_service() {
  local file="$1" rendered="$WORK/rendered-sudo"
  if [[ ! -r "$file" ]]; then
    log ERROR "$file cannot be read"
    return 1
  fi
  if (( $(count_matching_lines "$file" "$INCLUDE_RE") > 0 )) && [[ ! -e "$STANZA_DST" ]]; then
    log ERROR "$file includes $STANZA_NAME but $STANZA_DST is MISSING — sudo is BROKEN"
    return 2
  fi
  if (( $(count_matching_lines "$file" "$COMMON_AUTH_RE") != 1 )); then
    log ERROR "$file has no single '@include common-auth' line"
    return 1
  fi
  render_sudo_service "$file" with >"$rendered"
  if ! cmp -s "$rendered" "$file"; then
    log ERROR "$file does not include $STANZA_NAME exactly once, immediately before @include common-auth — re-run: fingerprint-setup"
    return 1
  fi
  log SUCCESS "$file asks for the password first, then a gated fingerprint"
}

check_greeter() {
  local rendered="$WORK/rendered-greeter" foreign
  if [[ ! -r "$GREETER_CONFIG" ]]; then
    log ERROR "$GREETER_CONFIG cannot be read"
    return 1
  fi
  foreign="$(foreign_greeter_settings "$GREETER_CONFIG")"
  if [[ -n "$foreign" ]]; then
    log ERROR "$GREETER_CONFIG also sets enable-fingerprint-authentication outside this setup's line: $foreign"
    return 1
  fi
  render_greeter "$GREETER_CONFIG" with >"$rendered"
  if ! cmp -s "$rendered" "$GREETER_CONFIG"; then
    log ERROR "$GREETER_CONFIG does not turn the greeter fingerprint off (this setup's two lines, right after $GREETER_SECTION) — re-run: fingerprint-setup"
    return 1
  fi
  if is_greeter_compiled_stale; then
    log ERROR "gdm has not recompiled its greeter config since $GREETER_CONFIG changed"
    log ERROR "  sudo systemctl reload $GDM_UNIT   (it only recompiles; never restart gdm, that ends the session)"
    return 1
  fi
  log SUCCESS "the greeter is password-only, and gdm has compiled it"
}

check_no_fprintd_in_front() {
  local violations
  violations="$(fprintd_in_front_of_a_password)"
  if [[ -n "$violations" ]]; then
    while IFS= read -r line; do log ERROR "$line"; done <<<"$violations"
    log ERROR "  the stock profile does this to common-auth: sudo pam-auth-update --disable fprintd"
    return 1
  fi
  log SUCCESS "no PAM stack puts pam_fprintd in front of a password (gdm-fingerprint runs beside one)"
}

check_sudo_stack_loads() {
  local problems line
  problems="$(sudo_stack_problems installed)"
  if [[ -n "$problems" ]]; then
    while IFS= read -r line; do log ERROR "$line"; done <<<"$problems"
    return 1
  fi
  log SUCCESS "the installed sudo stack loads through the real libpam and accepts a correct password"
}

check_common_auth_known() {
  local problems line
  problems="$(modules_the_stanza_would_skip)"
  if [[ -n "$problems" ]]; then
    while IFS= read -r line; do log ERROR "$line"; done <<<"$problems"
    log ERROR "  the stanza checks the password BEFORE common-auth; known modules: ${KNOWN_COMMON_AUTH_MODULES[*]}"
    log ERROR "  remove fingerprint-setup (--remove) or that module; docs/FINGERPRINT.md says why"
    return 1
  fi
  log SUCCESS "common-auth runs nothing a password checked first would skip"
}

check_pam_modules() {
  local module bad=0
  for module in "${REQUIRED_PAM_MODULES[@]}"; do
    if ! is_pam_module_installed "$module"; then
      log ERROR "$module is not installed (apt install libpam-fprintd libpam-modules)"
      bad=1
    fi
  done
  (( bad == 0 )) && log SUCCESS "pam_fprintd.so and pam_exec.so are installed"
  return "$bad"
}

check_installed() {
  local bad=0 is_sudo_broken=0 service rc
  check_copy "$GATE_SRC" "$GATE_DST" "$GATE_STAT" || bad=1
  check_copy "$STANZA_SRC" "$STANZA_DST" "$STANZA_STAT" || bad=1
  for service in "${SUDO_SERVICES[@]}"; do
    rc=0
    check_sudo_service "$service" || rc=$?
    (( rc == 0 )) || bad=1
    (( rc == 2 )) && is_sudo_broken=1
  done
  # A stack libpam refuses is as broken as a missing stanza: either way sudo
  # refuses everyone, and the repair goes through the untouched polkit, ONCE.
  if ! check_sudo_stack_loads; then
    bad=1
    is_sudo_broken=1
  fi
  if (( is_sudo_broken )); then
    log ERROR "  sudo refuses everyone until this is fixed; repair it from a GNOME dialog (polkit is untouched):"
    log ERROR "    pkexec sed -i '/^@include ${STANZA_NAME}\$/d' ${SUDO_SERVICES[*]}"
  fi
  check_common_auth_known || bad=1
  check_greeter || bad=1
  check_no_fprintd_in_front || bad=1
  check_pam_modules || bad=1
  return "$bad"
}

if [[ "$MODE" == check ]]; then
  check_installed   # a plain call: under set -e a failed check exits 1 right here
  exit 0
fi

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

# install_by_rename <mode> <src> <dst> — root-owned <dst>, never half-written.
# Exits on failure rather than returning: it is reached through `||` lists,
# where bash suspends set -e for the whole function body, and a failed write
# must never read as "nothing to do".
install_by_rename() {
  local mode="$1" src="$2" dst="$3"
  if ! sudo install -m "$mode" -o root -g root "$src" "${dst}${TMP_SUFFIX}"; then
    log ERROR "could not write ${dst}${TMP_SUFFIX} — $dst is unchanged"
    exit 1
  fi
  if ! sudo mv -f "${dst}${TMP_SUFFIX}" "$dst"; then
    log ERROR "could not rename ${dst}${TMP_SUFFIX} over $dst — $dst is unchanged"
    exit 1
  fi
}

# replace_if_changed <rendered> <dst> — install <rendered> over <dst> unless they
# already match. Returns 0 when it wrote, 1 when there was nothing to do.
replace_if_changed() {
  local rendered="$1" dst="$2"
  if cmp -s "$rendered" "$dst"; then return 1; fi
  install_by_rename 644 "$rendered" "$dst"
  log SUCCESS "edited $dst"
}

# reload_gdm — recompile the greeter config. RELOAD, never restart: gdm's
# ExecReload is only generate-config, and a restart ends every session.
reload_gdm() {
  if sudo systemctl reload "$GDM_UNIT"; then
    log SUCCESS "gdm recompiled its greeter config"
  else
    log WARNING "could not reload $GDM_UNIT; the greeter changes at the next boot (gdm recompiles when it starts)"
  fi
}

if [[ "$MODE" == remove ]]; then
  is_greeter_changed=0
  # Includes FIRST: a sudo file that includes a stanza that is gone aborts.
  for service in "${SUDO_SERVICES[@]}"; do
    [[ -f "$service" ]] || continue
    render_sudo_service "$service" without >"$WORK/rendered"
    replace_if_changed "$WORK/rendered" "$service" || true
  done
  if [[ -f "$GREETER_CONFIG" ]]; then
    render_greeter "$GREETER_CONFIG" without >"$WORK/rendered"
    if replace_if_changed "$WORK/rendered" "$GREETER_CONFIG"; then is_greeter_changed=1; fi
  fi
  for dst in "$STANZA_DST" "$GATE_DST"; do
    if [[ -e "$dst" || -L "$dst" ]]; then
      sudo rm -f "$dst"
      log SUCCESS "removed $dst"
    fi
  done
  (( is_greeter_changed )) && reload_gdm
  log SUCCESS "fingerprint-setup is removed; sudo and the greeter ask for the password only"
  exit 0
fi

# REFUSE to install out of a worktree, as setup-dock-lid.sh does: root would
# read a copy taken from an unreviewed branch, and --check from the live
# checkout would then report it as drift.
git_dir="$(git -C "$DOTFILES" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
common_dir="$(git -C "$DOTFILES" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [[ -n "$git_dir" && -n "$common_dir" && "$git_dir" != "$common_dir" ]]; then
  # With the override set, the refusal is not printed: a wall of red ✗ lines
  # above a successful install reads as a failure (measured on the first live run).
  if [[ "${FINGERPRINT_SETUP_ALLOW_WORKTREE:-0}" == "1" ]]; then
    log WARNING "installing from a WORKTREE ($DOTFILES), as FINGERPRINT_SETUP_ALLOW_WORKTREE=1 asks"
  else
    log ERROR "refusing to install from a WORKTREE: $DOTFILES"
    log ERROR "  Run this from the live checkout:"
    log ERROR "    cd ~/.dotfiles && fingerprint-setup"
    log ERROR "  (set FINGERPRINT_SETUP_ALLOW_WORKTREE=1 to override, e.g. to test a branch.)"
    exit 1
  fi
fi

# EVERY PRECONDITION BEFORE THE FIRST WRITE. A refusal leaves the machine as it
# was; there is no half-installed state to reason about.
log INFO "Checking what the install will meet"
for module in "${REQUIRED_PAM_MODULES[@]}"; do
  if ! is_pam_module_installed "$module"; then
    log ERROR "$module is not installed (apt install libpam-fprintd libpam-modules) — nothing installed"
    exit 2
  fi
done
if ! command -v python3 >/dev/null || [[ ! -r "$PROBE" ]]; then
  log ERROR "python3 and $PROBE are needed to load the stack through libpam before installing it — nothing installed"
  exit 2
fi
for service in "${SUDO_SERVICES[@]}"; do
  if [[ ! -r "$service" ]]; then
    log ERROR "$service is missing or unreadable — nothing installed"
    exit 2
  fi
  if ! does_end_in_newline "$service"; then
    log ERROR "$service does not end in a newline, so --remove could not restore it byte for byte — nothing installed"
    exit 2
  fi
  if (( $(count_matching_lines "$service" "$COMMON_AUTH_RE") != 1 )); then
    log ERROR "$service has no single '@include common-auth' line to put the fingerprint before — nothing installed"
    exit 2
  fi
done
if [[ ! -r "$GREETER_CONFIG" ]]; then
  log ERROR "$GREETER_CONFIG is missing or unreadable (is gdm3 installed?) — nothing installed"
  exit 2
fi
if ! does_end_in_newline "$GREETER_CONFIG"; then
  log ERROR "$GREETER_CONFIG does not end in a newline, so --remove could not restore it byte for byte — nothing installed"
  exit 2
fi
if (( $(count_matching_lines "$GREETER_CONFIG" "^\\[org/gnome/login-screen\\]$") != 1 )); then
  log ERROR "$GREETER_CONFIG has no single $GREETER_SECTION section — nothing installed"
  exit 2
fi
foreign="$(foreign_greeter_settings "$GREETER_CONFIG")"
if [[ -n "$foreign" ]]; then
  log ERROR "$GREETER_CONFIG also sets enable-fingerprint-authentication outside this setup's line: $foreign"
  log ERROR "  remove that line first — nothing installed"
  exit 1
fi
violations="$(fprintd_in_front_of_a_password)"
if [[ -n "$violations" ]]; then
  while IFS= read -r line; do log ERROR "$line"; done <<<"$violations"
  log ERROR "  that already delays a password; the stock profile is removed with:"
  log ERROR "    sudo pam-auth-update --disable fprintd"
  log ERROR "  — nothing installed"
  exit 1
fi
skipped_modules="$(modules_the_stanza_would_skip)"
if [[ -n "$skipped_modules" ]]; then
  while IFS= read -r line; do log ERROR "$line"; done <<<"$skipped_modules"
  log ERROR "  the stanza checks the password BEFORE common-auth; known modules: ${KNOWN_COMMON_AUTH_MODULES[*]}"
  log ERROR "  — nothing installed"
  exit 1
fi
stack_problems="$(sudo_stack_problems target)"
if [[ -n "$stack_problems" ]]; then
  while IFS= read -r line; do log ERROR "$line"; done <<<"$stack_problems"
  log ERROR "  that is the stack this install would leave; installing it would refuse every sudo — nothing installed"
  exit 1
fi

log INFO "Installing"
# The gate, then the stanza, then the includes: never an include before its target.
[[ -d "$GATE_DIR" ]] || sudo install -d -m 755 -o root -g root "$GATE_DIR"
install_by_rename 755 "$GATE_SRC" "$GATE_DST"
log SUCCESS "installed $GATE_DST"
install_by_rename 644 "$STANZA_SRC" "$STANZA_DST"
log SUCCESS "installed $STANZA_DST"
for service in "${SUDO_SERVICES[@]}"; do
  render_sudo_service "$service" with >"$WORK/rendered"
  replace_if_changed "$WORK/rendered" "$service" || log SUCCESS "$service already includes $STANZA_NAME"
done
render_greeter "$GREETER_CONFIG" with >"$WORK/rendered"
replace_if_changed "$WORK/rendered" "$GREETER_CONFIG" || log SUCCESS "$GREETER_CONFIG already turns the greeter fingerprint off"
is_greeter_compiled_stale && reload_gdm

echo
check_installed || exit 1
echo
log SUCCESS "Done. Enrol a finger (Settings → System → Users → Fingerprint Login, or"
log SUCCESS "  fprintd-enroll), then: sudo -k; sudo true — press Enter at the password"
log SUCCESS "  prompt to switch to the reader. Each decision is in: journalctl -t fingerprint-gate"
