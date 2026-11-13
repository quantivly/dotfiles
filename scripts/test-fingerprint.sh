#!/usr/bin/env bash
#
# scripts/test-fingerprint.sh
# ===========================
#
# State table for scripts/setup-fingerprint.sh and what it installs:
# pam/sudo-fingerprint (→ /etc/pam.d/), pam/fingerprint-should-skip
# (→ /usr/local/libexec/), one `@include` line in /etc/pam.d/sudo and sudo-i,
# and two lines in /etc/gdm3/greeter.dconf-defaults.
#
# HERMETIC via a `sudo` stub at the front of PATH. It runs `install`, `mv` and
# `rm` for real, but only under an ABSOLUTE FINGERPRINT_SETUP_PREFIX, and it
# MODELS `systemctl reload gdm.service` without running systemctl: gdm's
# ExecReload is /usr/share/gdm/generate-config, which recompiles
# /var/lib/gdm3/greeter-dconf-defaults, so the stub touches that file under the
# prefix. The machine running this has live PAM stacks; a row that reached a
# real `sudo install` into /etc/pam.d could break sudo for everyone on it.
#
# THE GATE is run the way pam_exec runs it: `env -i` plus the PAM items, so no
# PATH at all, with its lid directory and log file given as ARGUMENTS. Those
# are its only seams, because in PAM its arguments are fixed by a root-owned
# file and its environment is not the caller's to choose.
#
# THE STANZA'S CONTROL FLOW runs through the REAL libpam: pam_start_confdir()
# reads a service from any directory, unprivileged (scripts/pam-stack-probe.py,
# which the installer uses too). The files a real install wrote under the prefix
# are copied there with pam_permit/pam_deny standing in for "this password / this
# finger is right / wrong", and the installed gate still deciding. So
# `[success=1 default=ignore]`, `sufficient` and @include are libpam's semantics,
# not this suite's belief about them. Two rows keep the REAL pam_unix, for an
# account that does not exist, to count prompts: one per attempt, because
# pam_unix reuses the cached password, so a second prompt is the caller's retry.
#
# The fixture /etc is Ubuntu 26.04's own text (sudo-common, polkitd, gdm3),
# trailing spaces included, so every edit is tested against what it will meet.
#
# "Could not run" is exit 2, never a pass. The suite asserts its own row total.
#
# Requires: bash, sh, git, cmp, stat, env, touch, sha256sum, python3 and a
# libpam with pam_start_confdir (Linux-PAM >= 1.4). No sudo, no root, no network.
#
# Usage: scripts/test-fingerprint.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DOTFILES="$(cd "$HERE/.." && pwd -P)"
SETUP="$HERE/setup-fingerprint.sh"
STANZA_SRC="$DOTFILES/pam/sudo-fingerprint"
GATE_SRC="$DOTFILES/pam/fingerprint-should-skip"
PROBE="$HERE/pam-stack-probe.py"
# Where the stanza says the gate lives, and so where the install must put it.
GATE_INSTALLED_PATH="/usr/local/libexec/fingerprint-should-skip"
STANZA_INSTALLED_PATH="/etc/pam.d/sudo-fingerprint"
INCLUDE_LINE="@include sudo-fingerprint"
GREETER_KEY_LINE="enable-fingerprint-authentication=false"
# libpam's return codes, as pam_authenticate and pam_start report them.
PAM_SUCCESS=0
PAM_AUTH_ERR=7
PAM_ABORT=26

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

for f in "$SETUP" "$STANZA_SRC" "$GATE_SRC" "$PROBE"; do
  [[ -r "$f" ]] || fatal "cannot read $f"
done
for t in git cmp stat env touch sh sha256sum python3; do
  command -v "$t" >/dev/null || fatal "$t is required"
done

T="$(mktemp -d)" || fatal "mktemp"
trap 'rm -rf "$T"' EXIT
# git must never find a repository above the fixtures, so a row's answer cannot
# depend on where the suite happens to be checked out.
export GIT_CEILING_DIRECTORIES="$T"
STUBBIN="$T/bin"
export STUBLOG="$T/stub.log"
mkdir -p "$STUBBIN" || fatal setup
: >"$STUBLOG"
ME="$(id -un):$(id -gn)"

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
cat >"$STUBBIN/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$STUBLOG"
pfx="${FINGERPRINT_SETUP_PREFIX:-}"
if [ -z "$pfx" ]; then
  echo "sudo stub: refused (no FINGERPRINT_SETUP_PREFIX, so nothing may be written)" >&2
  exit 1
fi
# A RELATIVE prefix confines nothing: `relative/etc/x` is "inside" it and lands
# in whatever directory the caller is sitting in.
case "$pfx" in
  /*) ;;
  *) echo "sudo stub: REFUSED a relative prefix: $pfx" >&2; exit 97 ;;
esac
inside() { case "$1" in "$pfx"/*) return 0 ;; *) return 1 ;; esac; }
cmd="${1:-}"
shift
case "$cmd" in
  systemctl)
    # Modelled, never executed. gdm's ExecReload only recompiles the greeter
    # config; nothing else here may reach systemctl at all.
    if [ "${1:-}:${2:-}" = "reload:gdm.service" ]; then
      [ "${STUB_GDM_RELOAD_FAIL:-0}" = 1 ] && exit 1
      mkdir -p "$pfx/var/lib/gdm3" && touch "$pfx/var/lib/gdm3/greeter-dconf-defaults" || exit 98
      exit 0
    fi
    echo "sudo stub: unmodelled systemctl call: $*" >&2
    exit 99 ;;
  rm | mv)
    for a in "$@"; do
      case "$a" in
        -*) ;;
        *) inside "$a" || { echo "sudo stub: REFUSED $cmd outside the prefix: $a" >&2; exit 97; } ;;
      esac
    done
    exec "$cmd" "$@" ;;
  install) ;;
  *) echo "sudo stub: unmodelled command: $cmd $*" >&2; exit 96 ;;
esac
has_d=0; flags=(); ops=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o | -g) shift 2 ;;   # cannot work unprivileged; the RECORDED argv keeps them
    -m) flags+=("$1" "${2:-}"); shift 2 ;;
    -d) has_d=1; flags+=("$1"); shift ;;
    -*) flags+=("$1"); shift ;;
    *)  ops+=("$1"); shift ;;
  esac
done
# For `install SRC DST` only the last operand is a target; with -d all are.
if [ "$has_d" -eq 0 ] && [ "${#ops[@]}" -gt 1 ]; then
  targets=("${ops[$((${#ops[@]} - 1))]}")
else
  targets=("${ops[@]}")
fi
for t in "${targets[@]}"; do
  inside "$t" || { echo "sudo stub: REFUSED a destination outside the prefix: $t" >&2; exit 97; }
done
exec install "${flags[@]}" "${ops[@]}"
STUB

# Nothing in the setup may call systemctl except through sudo, and through
# sudo it is modelled above. A direct call is a bug: fail it loudly.
cat >"$STUBBIN/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$STUBLOG"
echo "systemctl stub: called directly, not through sudo: $*" >&2
exit 99
STUB
chmod +x "$STUBBIN"/* || fatal setup

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
# A checkout laid out like the repo, holding only what the installer reads.
mkroot() {
  mkdir -p "$1/scripts" "$1/pam" || fatal "mkroot $1"
  if ! { cp "$SETUP" "$PROBE" "$1/scripts/" && cp -p "$STANZA_SRC" "$GATE_SRC" "$1/pam/"; }; then
    fatal "mkroot $1"
  fi
}
ROOT="$T/root"; mkroot "$ROOT"
# A checkout whose stanza has ONE misspelled control keyword: libpam refuses the
# whole stack for it, correct password or not.
ROOT_BAD="$T/root-bad"; mkroot "$ROOT_BAD"
sed -i 's/^\(auth  \)sufficient\( *pam_unix\)/\1sufficent\2/' "$ROOT_BAD/pam/sudo-fingerprint"
[[ "$(grep -c '^auth  sufficent' "$ROOT_BAD/pam/sudo-fingerprint")" == 1 ]] || fatal "the misspelled-stanza fixture did not apply"
# A checkout without the libpam probe.
ROOT_NO_PROBE="$T/root-no-probe"; mkroot "$ROOT_NO_PROBE"; rm -f "$ROOT_NO_PROBE/scripts/pam-stack-probe.py"

# write_ubuntu_etc <dir> — Ubuntu 26.04's own files, as the install meets them.
write_ubuntu_etc() {
  local p="$1"
  mkdir -p "$p/etc/pam.d" "$p/usr/lib/pam.d" "$p/etc/gdm3" "$p/var/lib/gdm3" \
           "$p/usr/lib/x86_64-linux-gnu/security" || fatal "fixture $p"
  cat >"$p/etc/pam.d/sudo" <<'EOF' || fatal "fixture $p"
#%PAM-1.0

# Set up user limits from /etc/security/limits.conf.
session    required   pam_limits.so

session    required   pam_env.so readenv=1 user_readenv=0
session    required   pam_env.so readenv=1 envfile=/etc/default/locale user_readenv=0

@include common-auth
@include common-account
@include common-session-noninteractive
EOF
  cat >"$p/etc/pam.d/sudo-i" <<'EOF' || fatal "fixture $p"
#%PAM-1.0

# Set up user limits from /etc/security/limits.conf.
session    required   pam_limits.so

session    required   pam_env.so readenv=1 user_readenv=0
session    required   pam_env.so readenv=1 envfile=/etc/default/locale user_readenv=0

@include common-auth
@include common-account
@include common-session
EOF
  cat >"$p/etc/pam.d/common-auth" <<'EOF' || fatal "fixture $p"
#
# /etc/pam.d/common-auth - authentication settings common to all services
#
# here are the per-package modules (the "Primary" block)
auth    [success=2 default=ignore]      pam_unix.so nullok
auth    [success=1 default=ignore]      pam_sss.so use_first_pass
# here's the fallback if no module succeeds
auth    requisite                       pam_deny.so
# prime the stack with a positive return value if there isn't one already;
auth    required                        pam_permit.so
# and here are more per-package modules (the "Additional" block)
auth    optional                        pam_cap.so
# end of pam-auth-update config
EOF
  cat >"$p/etc/pam.d/gdm-fingerprint" <<'EOF' || fatal "fixture $p"
#%PAM-1.0
auth    requisite       pam_nologin.so
auth    required        pam_succeed_if.so user != root quiet_success
auth    required        pam_fprintd.so
auth    optional        pam_gnome_keyring.so
@include common-account
password required       pam_fprintd.so
EOF
  cat >"$p/usr/lib/pam.d/polkit-1" <<'EOF' || fatal "fixture $p"
#%PAM-1.0

@include common-auth
@include common-account
@include common-password
session       required   pam_env.so readenv=1 user_readenv=0
@include common-session-noninteractive
EOF
  # What sudo and sudo-i also include. Never run by pam_authenticate, but libpam
  # aborts a whole stack whose include target is missing, so they must exist.
  printf 'account required pam_permit.so\n' >"$p/etc/pam.d/common-account" || fatal "fixture $p"
  printf 'password required pam_permit.so\n' >"$p/etc/pam.d/common-password" || fatal "fixture $p"
  printf 'session required pam_permit.so\n' >"$p/etc/pam.d/common-session" || fatal "fixture $p"
  printf 'session required pam_permit.so\n' >"$p/etc/pam.d/common-session-noninteractive" || fatal "fixture $p"
  # printf, not a heredoc: four of these lines END IN A SPACE in Ubuntu's file,
  # and a whitespace hook would strip them silently out of a heredoc here.
  printf '%s\n' \
    '# These are the options for the greeter session that can be set ' \
    '# through GSettings. Any GSettings setting that is used by the ' \
    '# greeter session can be set here.' \
    '' \
    '# Note that you must configure the path used by dconf to store the ' \
    '# configuration, not the GSettings path.' \
    '' \
    '' \
    '# Login manager options' \
    '# =====================' \
    '[org/gnome/login-screen]' \
    '# See /usr/share/glib-2.0/schemas/org.gnome.login-screen.gschema.xml' \
    '# - Distro logo shown below the user list or username box' \
    "#logo='/usr/share/images/vendor-logos/logo-text-version-64.png'" \
    '' \
    "# - Don't use a fingerprint reader for authentication" \
    '# enable-fingerprint-authentication=false' \
    '' \
    '# Automatic suspend' \
    '# =================' \
    '[org/gnome/settings-daemon/plugins/power]' \
    '# sleep-inactive-ac-timeout=1200' \
    >"$p/etc/gdm3/greeter.dconf-defaults" || fatal "fixture $p"
  : >"$p/usr/lib/x86_64-linux-gnu/security/pam_fprintd.so" || fatal "fixture $p"
  : >"$p/usr/lib/x86_64-linux-gnu/security/pam_exec.so" || fatal "fixture $p"
  # gdm compiled its greeter config AFTER the file last changed: fresh.
  : >"$p/var/lib/gdm3/greeter-dconf-defaults" || fatal "fixture $p"
  touch -d '2026-01-02 00:00' "$p/etc/gdm3/greeter.dconf-defaults" || fatal "fixture $p"
  touch -d '2026-01-03 00:00' "$p/var/lib/gdm3/greeter-dconf-defaults" || fatal "fixture $p"
}
PRISTINE="$T/pristine"; write_ubuntu_etc "$PRISTINE"

newprefix() { local p; p="$(mktemp -d "$T/prefix.XXXXXX")" || fatal "mktemp prefix"; write_ubuntu_etc "$p"; printf '%s' "$p"; }
logged()    { grep -c -x -F -- "$1" "$STUBLOG"; }
logged_re() { grep -c -E -- "$1" "$STUBLOG"; }
# The first STUBLOG line matching an ERE, as a line number (0 when none).
logged_at() { local n; n="$(grep -n -E -- "$1" "$STUBLOG" | head -1 | cut -d: -f1)"; printf '%s' "${n:-0}"; }
out_has()   { grep -c -F -- "$1" "$T/out"; }
stubs()     { PATH="$STUBBIN:$PATH" "$@"; }
same_as_pristine() { cmp -s "$PRISTINE/$2" "$1/$2" && echo same || echo differs; }
# One hash over every file's path and bytes (not its mtime) under a directory.
tree_hash() {
  (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) | sha256sum | cut -d' ' -f1
}

# run_setup <checkout> <prefix> [args...] — prints the exit status; the output
# lands in $T/out and the stubs' argv in $STUBLOG (cleared first). Variables the
# caller puts in front of it reach the stubs. Runs from inside $T, so nothing a
# row does can land in the directory the suite was started from.
run_setup() {
  local root="$1" pfx="$2"; shift 2
  : >"$STUBLOG"
  ( cd "$T" && PATH="$STUBBIN:$PATH" FINGERPRINT_SETUP_PREFIX="$pfx" \
      bash "$root/scripts/setup-fingerprint.sh" "$@" ) >"$T/out" 2>&1
  echo $?
}
# installed_prefix — a fresh fixture with a successful install on it.
installed_prefix() {
  local p rc
  p="$(newprefix)"
  rc="$(run_setup "$ROOT" "$p")"
  [[ "$rc" == 0 ]] || { cat "$T/out" >&2; fatal "the baseline install failed (exit $rc)"; }
  printf '%s' "$p"
}

# mklid <dir> <name> <state line> — one lid, as /proc/acpi/button/lid shows it.
mklid() { { mkdir -p "$1/$2" && printf '%s\n' "$3" >"$1/$2/state"; } || fatal "mklid $1/$2"; }
LID_OPEN="$T/lid-open";     mklid "$LID_OPEN" LID 'state:      open'
LID_CLOSED="$T/lid-closed"; mklid "$LID_CLOSED" LID 'state:      closed'
GATE_LOG="$T/gate.log"
# The gate's local accounts. fingerprint-test-nobody is local HERE and unknown to
# the real system, so the real pam_unix rows reach the gate's offer.
PASSWD_FIXTURE="$T/passwd"
printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' 'someone:x:1000:1000::/home/someone:/bin/sh' \
  'fingerprint-test-nobody:x:1001:1001::/nonexistent:/bin/sh' >"$PASSWD_FIXTURE" || fatal "passwd fixture"

# run_gate <service|UNSET> <tty|UNSET> <lid-dir> [extra args] — pam_exec's view of
# it: no environment but the PAM items. Prints the exit status (1 offer, 0 skip).
# The user is GATE_USER (UNSET for none), "someone" by default, a local account.
run_gate() {
  local service="$1" tty="$2" lid="$3" user="${GATE_USER:-someone}"; shift 3
  local items=(PAM_TYPE=auth)
  [[ "$user" != UNSET ]] && items+=("PAM_USER=$user")
  [[ "$service" != UNSET ]] && items+=("PAM_SERVICE=$service")
  [[ "$tty" != UNSET ]] && items+=("PAM_TTY=$tty")
  : >"$GATE_LOG"
  env -i "${items[@]}" "$GATE_SRC" --lid-dir "$lid" --passwd-file "$PASSWD_FIXTURE" \
    --log-file "$GATE_LOG" "$@" >/dev/null 2>&1
  echo $?
}
gate_said() { grep -c -F -- "$1" "$GATE_LOG"; }

# ---------------------------------------------------------------------------
printf '\nthe stubs (a stub that cannot fail is decoration; a stub is a claim about the real tool)\n'
check "sudo resolves to the stub" "$(stubs bash -c 'command -v sudo')" "$STUBBIN/sudo"
P="$(newprefix)"
rc="$(FINGERPRINT_SETUP_PREFIX="$P" stubs sudo install -m 644 "$STANZA_SRC" "$T/outside" >/dev/null 2>&1; echo $?)"
check "the sudo stub refuses a destination outside the prefix" \
  "$rc:$([[ -e $T/outside ]] && echo written || echo absent)" "97:absent"
before="$(tree_hash "$P")"
rc="$(FINGERPRINT_SETUP_PREFIX='' stubs sudo install -m 644 "$STANZA_SRC" "$P/etc/x" >/dev/null 2>&1; echo $?)"
check "with no prefix the sudo stub writes nothing" "$rc:$(tree_hash "$P")" "1:$before"
rc="$(cd "$T" && FINGERPRINT_SETUP_PREFIX='rel' stubs sudo install -D -m 644 "$STANZA_SRC" "rel/x" >/dev/null 2>&1; echo $?)"
check "the sudo stub refuses a relative prefix, which confines nothing" \
  "$rc:$([[ -e $T/rel ]] && echo written || echo absent)" "97:absent"
rc="$(FINGERPRINT_SETUP_PREFIX="$P" stubs sudo mv -f "$P/etc/pam.d/sudo" "$T/moved" >/dev/null 2>&1; echo $?)"
check "the sudo stub refuses an mv out of the prefix" \
  "$rc:$([[ -e $T/moved ]] && echo moved || echo absent)" "97:absent"
rc="$(FINGERPRINT_SETUP_PREFIX="$P" stubs sudo systemctl restart gdm.service >/dev/null 2>&1; echo $?)"
check "the sudo stub refuses any systemctl call but a gdm reload (a restart ends the session)" "$rc" 99
rc="$(FINGERPRINT_SETUP_PREFIX="$P" stubs sudo sed -i d "$P/etc/pam.d/sudo" >/dev/null 2>&1; echo $?)"
check "the sudo stub refuses a command it does not model" "$rc:$(same_as_pristine "$P" etc/pam.d/sudo)" "96:same"

# ---------------------------------------------------------------------------
printf '\nthe gate: who is offered a fingerprint (exit 1 offer, 0 skip)\n'
check "sudo, a terminal, the lid open: offered, and logged" \
  "$(run_gate sudo /dev/pts/3 "$LID_OPEN"):$(gate_said 'offer:')" "1:1"
check "sudo -i: offered the same way" "$(run_gate sudo-i /dev/pts/3 "$LID_OPEN")" 1
check "a virtual console (/dev/tty3) is a terminal: offered" "$(run_gate sudo /dev/tty3 "$LID_OPEN")" 1
check "sudo with no PAM_TTY at all (an agent, a background job): skipped, and logged" \
  "$(run_gate sudo UNSET "$LID_OPEN"):$(gate_said 'skip: no terminal')" "0:1"
check "sudo with an empty PAM_TTY: skipped" "$(run_gate sudo '' "$LID_OPEN")" 0
check "sudo with an X display for a tty (:0): skipped" "$(run_gate sudo ':0' "$LID_OPEN")" 0
check "sudo with /dev/null for a tty: skipped" "$(run_gate sudo /dev/null "$LID_OPEN")" 0
check "sudo, a terminal, the lid CLOSED (docked, unreachable): skipped, and logged" \
  "$(run_gate sudo /dev/pts/3 "$LID_CLOSED"):$(gate_said 'skip: lid closed')" "0:1"
check "polkit-1 is never offered, even with a tty and the lid open" \
  "$(run_gate polkit-1 /dev/pts/3 "$LID_OPEN"):$(gate_said 'skip: service is not sudo')" "0:1"
check "login is never offered" "$(run_gate login /dev/tty3 "$LID_OPEN")" 0
check "a service whose name merely starts with sudo is never offered" "$(run_gate sudoedit /dev/pts/3 "$LID_OPEN")" 0
check "no PAM_SERVICE at all: skipped" "$(run_gate UNSET /dev/pts/3 "$LID_OPEN")" 0

printf '\nthe gate: local accounts only (pam_unix, first in the stanza, knows no other)\n'
check "a user not in the passwd file (a domain account a correct password would pass later): skipped, and logged" \
  "$(GATE_USER=stranger run_gate sudo /dev/pts/3 "$LID_OPEN"):$(gate_said 'skip: not a local account')" "0:1"
check "no PAM_USER at all: skipped" "$(GATE_USER=UNSET run_gate sudo /dev/pts/3 "$LID_OPEN")" 0
check "a user whose name is only a prefix of a local one: skipped" "$(GATE_USER=some run_gate sudo /dev/pts/3 "$LID_OPEN")" 0
check "the local account on the passwd file's last line: offered" \
  "$(GATE_USER=fingerprint-test-nobody run_gate sudo /dev/pts/3 "$LID_OPEN")" 1
check "a passwd file that does not exist: skipped" \
  "$(run_gate sudo /dev/pts/3 "$LID_OPEN" --passwd-file "$T/no/such/passwd")" 0

printf '\nthe gate: reading the lid (anything it cannot read is a skip; the password always works)\n'
L="$T/lid-none"; mkdir -p "$L" || fatal "lid fixture"
check "no lid at all (an empty directory): skipped, and logged" \
  "$(run_gate sudo /dev/pts/3 "$L"):$(gate_said 'skip: lid state unknown')" "0:1"
check "a lid directory that does not exist: skipped" "$(run_gate sudo /dev/pts/3 "$T/no/such/lid")" 0
L="$T/lid-garbage"; mklid "$L" LID 'state:      ajar'
check "a state it does not know: skipped" "$(run_gate sudo /dev/pts/3 "$L")" 0
L="$T/lid-empty"; { mkdir -p "$L/LID" && : >"$L/LID/state"; } || fatal "lid fixture"
check "an empty state file: skipped" "$(run_gate sudo /dev/pts/3 "$L")" 0
# The closed one sorts FIRST, so a later "open" overwriting it would be caught.
L="$T/lid-two-one-closed"; mklid "$L" LID0 'state:      closed'; mklid "$L" LID1 'state:      open'
check "two lids, the first closed and the second open: skipped" "$(run_gate sudo /dev/pts/3 "$L")" 0
L="$T/lid-two-open"; mklid "$L" LID0 'state:      open'; mklid "$L" LID1 'state:      open'
check "two lids, both open: offered" "$(run_gate sudo /dev/pts/3 "$L")" 1
L="$T/lid-no-newline"; { mkdir -p "$L/LID" && printf 'state:      open' >"$L/LID/state"; } || fatal "lid fixture"
check "a state line without a final newline still reads as open" "$(run_gate sudo /dev/pts/3 "$L")" 1

printf '\nthe gate: its arguments and its shape\n'
check "an unknown argument: skipped, and logged" \
  "$(run_gate sudo /dev/pts/3 "$LID_OPEN" --bogus):$(gate_said "skip: bad argument '--bogus'")" "0:1"
: >"$GATE_LOG"
rc="$(env -i PAM_SERVICE=sudo PAM_TTY=/dev/pts/3 "$GATE_SRC" --log-file "$GATE_LOG" --lid-dir >/dev/null 2>&1; echo $?)"
check "--lid-dir with no value: skipped, and logged" "$rc:$(gate_said "skip: bad argument '--lid-dir'")" "0:1"
run_gate sudo /dev/pts/3 "$LID_OPEN" >/dev/null
check "one decision is one log line" "$(wc -l <"$GATE_LOG" | tr -d ' ')" 1
check "the gate is executable in the checkout (pam_exec execs it directly)" \
  "$([[ -x "$GATE_SRC" ]] && echo executable || echo not)" executable
check "the gate is POSIX sh: sh -n parses it" "$(sh -n "$GATE_SRC" 2>&1; echo $?)" 0

# ---------------------------------------------------------------------------
printf '\nthe shipped stanza, exactly\n'
want_stanza="auth sufficient pam_unix.so nullok
auth [success=1 default=ignore] pam_exec.so quiet quiet_log $GATE_INSTALLED_PATH
auth sufficient pam_fprintd.so max-tries=2 timeout=10"
check "the password, then the gate, then the fingerprint, and nothing else" \
  "$(grep -v -e '^#' -e '^$' "$STANZA_SRC" | tr -s ' \t' ' ')" "$want_stanza"

# ---------------------------------------------------------------------------
printf '\narguments\n'
check "an unknown argument is exit 2" "$(run_setup "$ROOT" "" --bogus)" 2
rc="$(run_setup "$ROOT" "" --help)"
check "--help is exit 0 and prints the usage" "$rc:$(out_has 'Usage: setup-fingerprint.sh')" "0:1"
check "--check and --remove together is exit 2" "$(run_setup "$ROOT" "" --check --remove)" 2
check "a relative prefix is refused, exit 2" "$(run_setup "$ROOT" "relative/dir")" 2
check "a prefix that does not exist is refused, exit 2" "$(run_setup "$ROOT" "$T/no/such/dir")" 2

# ---------------------------------------------------------------------------
printf '\ninstall\n'
P="$(newprefix)"
rc="$(run_setup "$ROOT" "$P" --check)"
check "--check before any install: exit 1, and blames nothing on libpam (sudo includes no stanza yet)" \
  "$rc:$(out_has 'libpam refuses')" "1:0"
rc="$(run_setup "$ROOT" "$P")"
check "installs, exit 0" "$rc" 0
check "$STANZA_INSTALLED_PATH is a byte-identical copy of pam/sudo-fingerprint" \
  "$(cmp -s "$STANZA_SRC" "$P$STANZA_INSTALLED_PATH" && echo same || echo differs)" same
check "$GATE_INSTALLED_PATH (the path the stanza names) is a byte-identical copy of the gate" \
  "$(cmp -s "$GATE_SRC" "$P$GATE_INSTALLED_PATH" && echo same || echo differs)" same
check "the stanza is installed root-owned 0644" \
  "$(logged_re "^sudo install -m 644 -o root -g root [^ ]+ [^ ]+/etc/pam\.d/sudo-fingerprint\.fingerprint-setup\.tmp$")" 1
check "the gate is installed root-owned 0755" \
  "$(logged_re "^sudo install -m 755 -o root -g root [^ ]+ [^ ]+/usr/local/libexec/fingerprint-should-skip\.fingerprint-setup\.tmp$")" 1
check "every file lands by a rename, so a concurrent sudo never reads half a stack" \
  "$(logged_re '^sudo mv -f [^ ]+\.fingerprint-setup\.tmp [^ ]+$')" 5
gate_at="$(logged_at 'mv -f .*/fingerprint-should-skip$')"
stanza_at="$(logged_at 'mv -f .*/pam\.d/sudo-fingerprint$')"
sudo_at="$(logged_at 'mv -f .*/pam\.d/sudo$')"
check "the gate, then the stanza, then the includes (a missing include target breaks sudo outright)" \
  "$(( gate_at > 0 && gate_at < stanza_at && stanza_at < sudo_at ))" 1
check "/etc/pam.d/sudo: the include sits immediately before @include common-auth" \
  "$(grep -n -x -F -e "$INCLUDE_LINE" -e '@include common-auth' "$P/etc/pam.d/sudo" | cut -d: -f1 | tr '\n' ' ')" "9 10 "
check "/etc/pam.d/sudo: and nothing else changed" \
  "$(grep -v -x -F "$INCLUDE_LINE" "$P/etc/pam.d/sudo" | cmp -s - "$PRISTINE/etc/pam.d/sudo" && echo same || echo differs)" same
check "/etc/pam.d/sudo-i: the include sits immediately before @include common-auth" \
  "$(grep -n -x -F -e "$INCLUDE_LINE" -e '@include common-auth' "$P/etc/pam.d/sudo-i" | cut -d: -f1 | tr '\n' ' ')" "9 10 "
check "/etc/pam.d/sudo-i: and nothing else changed" \
  "$(grep -v -x -F "$INCLUDE_LINE" "$P/etc/pam.d/sudo-i" | cmp -s - "$PRISTINE/etc/pam.d/sudo-i" && echo same || echo differs)" same
check "the greeter: the marker and the key, right after [org/gnome/login-screen]" \
  "$(sed -n '11p;13p' "$P/etc/gdm3/greeter.dconf-defaults"):$(sed -n '12p' "$P/etc/gdm3/greeter.dconf-defaults" | cut -c1-20)" \
  "[org/gnome/login-screen]
$GREETER_KEY_LINE:# fingerprint-setup "
check "the greeter: and nothing else changed (Ubuntu's trailing spaces kept)" \
  "$(sed '12,13d' "$P/etc/gdm3/greeter.dconf-defaults" | cmp -s - "$PRISTINE/etc/gdm3/greeter.dconf-defaults" && echo same || echo differs)" same
check "gdm recompiles the greeter config (reload, all its ExecReload does)" "$(logged 'sudo systemctl reload gdm.service')" 1
check "nothing is ever restarted, started or stopped (a gdm restart ends the session)" \
  "$(logged_re 'systemctl (restart|start|stop)')" 0
check "common-auth, polkit-1 and gdm-fingerprint are untouched" \
  "$(same_as_pristine "$P" etc/pam.d/common-auth) $(same_as_pristine "$P" usr/lib/pam.d/polkit-1) $(same_as_pristine "$P" etc/pam.d/gdm-fingerprint)" \
  "same same same"
rc="$(run_setup "$ROOT" "$P" --check)"
check "--check after the install: exit 0" "$rc" 0
check "--check needs no sudo" "$(logged_re '^sudo ')" 0
check "--check says gdm-fingerprint's own pam_fprintd is fine (GDM runs it beside the password)" \
  "$(out_has 'no PAM stack puts pam_fprintd in front of a password')" 1
check "--check loads the installed sudo stack through the real libpam" \
  "$(out_has 'loads through the real libpam and accepts a correct password')" 1
check "--check finds nothing in common-auth that the early password check would skip" \
  "$(out_has 'common-auth runs nothing a password checked first would skip')" 1
before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "a second install changes no byte: no second include, no second marker" "$rc:$(tree_hash "$P")" "0:$before"
check "... and does not reload gdm, whose compiled config is already fresh" "$(logged 'sudo systemctl reload gdm.service')" 0

# ---------------------------------------------------------------------------
printf '\n--check: each piece out of place (exit 1, and it says which)\n'
P="$(installed_prefix)"; printf '# drift\n' >>"$P$STANZA_INSTALLED_PATH"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the stanza edited in place" "$rc:$(out_has 'sudo-fingerprint DIFFERS')" "1:1"
P="$(installed_prefix)"; ln -sf "$STANZA_SRC" "$P$STANZA_INSTALLED_PATH"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the stanza replaced by a symlink into the checkout" "$rc:$(out_has 'sudo-fingerprint is a SYMLINK')" "1:1"
P="$(installed_prefix)"; rm -f "$P$STANZA_INSTALLED_PATH"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the stanza gone while sudo still includes it: says sudo is BROKEN, and how to repair it" \
  "$rc:$(out_has 'sudo is BROKEN'):$(out_has 'pkexec sed -i')" "1:2:1"
P="$(installed_prefix)"; printf '# drift\n' >>"$P$GATE_INSTALLED_PATH"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the gate edited in place" "$rc:$(out_has 'fingerprint-should-skip DIFFERS')" "1:1"
P="$(installed_prefix)"; rm -f "$P$GATE_INSTALLED_PATH"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the gate gone (pam_exec would fail, which reads as OFFER)" "$rc:$(out_has 'fingerprint-should-skip is not installed')" "1:1"
P="$(installed_prefix)"; chmod 644 "$P$GATE_INSTALLED_PATH"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the gate not executable" "$rc:$(out_has "is $ME 644, not $ME 755")" "1:1"
P="$(installed_prefix)"; sed -i "/^$INCLUDE_LINE\$/d" "$P/etc/pam.d/sudo"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the include gone from sudo" \
  "$rc:$(out_has "$P/etc/pam.d/sudo does not include sudo-fingerprint exactly once")" "1:1"
P="$(installed_prefix)"; sed -i "/^$INCLUDE_LINE\$/d" "$P/etc/pam.d/sudo-i"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the include gone from sudo-i" \
  "$rc:$(out_has "$P/etc/pam.d/sudo-i does not include sudo-fingerprint exactly once")" "1:1"
P="$(installed_prefix)"
sed -i -e "/^$INCLUDE_LINE\$/d" -e "s/^@include common-auth\$/@include common-auth\n$INCLUDE_LINE/" "$P/etc/pam.d/sudo"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the include AFTER common-auth (it would never be reached on a wrong password)" \
  "$rc:$(out_has 'immediately before @include common-auth')" "1:1"
P="$(installed_prefix)"; sed -i "s/^$INCLUDE_LINE\$/&\n&/" "$P/etc/pam.d/sudo"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the include twice" "$rc:$(out_has 'exactly once, immediately before')" "1:1"
P="$(installed_prefix)"; sed -i '12,13d' "$P/etc/gdm3/greeter.dconf-defaults"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the greeter lines gone" "$rc:$(out_has 'does not turn the greeter fingerprint off')" "1:1"
P="$(installed_prefix)"; sed -i "13s/=false/=true/" "$P/etc/gdm3/greeter.dconf-defaults"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the greeter key flipped to true (no longer this setup's line, so a foreign setting)" \
  "$rc:$(out_has 'outside this setup'"'"'s line: enable-fingerprint-authentication=true')" "1:1"
# Cut the file after the login-screen section, so a line appended lands in it.
P="$(installed_prefix)"; sed -i '/^\[org\/gnome\/settings-daemon/,$d' "$P/etc/gdm3/greeter.dconf-defaults"
printf 'enable-fingerprint-authentication=true\n' >>"$P/etc/gdm3/greeter.dconf-defaults"
rc="$(run_setup "$ROOT" "$P" --check)"
check "another line in the login-screen section setting the key (the later one would win)" \
  "$rc:$(out_has 'also sets enable-fingerprint-authentication')" "1:1"
P="$(installed_prefix)"; touch -d '2025-01-01 00:00' "$P/var/lib/gdm3/greeter-dconf-defaults"
rc="$(run_setup "$ROOT" "$P" --check)"
check "gdm's compiled greeter config older than the file (never reloaded)" "$rc:$(out_has 'has not recompiled')" "1:1"
P="$(installed_prefix)"; rm -f "$P/var/lib/gdm3/greeter-dconf-defaults"
rc="$(run_setup "$ROOT" "$P" --check)"
check "gdm's compiled greeter config missing" "$rc:$(out_has 'has not recompiled')" "1:1"
P="$(installed_prefix)"; sed -i '0,/pam_unix/s/^auth.*pam_unix.*/auth [success=end default=ignore] pam_fprintd.so max-tries=1 timeout=10\n&/' "$P/etc/pam.d/common-auth"
rc="$(run_setup "$ROOT" "$P" --check)"
check "common-auth runs pam_fprintd (the stock pam-auth-update profile): names it and the remedy" \
  "$rc:$(out_has 'common-auth puts pam_fprintd where it would delay a password'):$(out_has 'pam-auth-update --disable fprintd')" "1:1:1"
P="$(installed_prefix)"
{ printf 'auth sufficient pam_fprintd.so\n'; cat "$P/usr/lib/pam.d/polkit-1"; } >"$P/etc/pam.d/polkit-1"
rc="$(run_setup "$ROOT" "$P" --check)"
check "an /etc/pam.d/polkit-1 override running pam_fprintd" "$rc:$(out_has 'polkit-1 puts pam_fprintd where it would delay a password')" "1:1"
P="$(installed_prefix)"; sed -i '1a auth sufficient pam_fprintd.so' "$P/usr/lib/pam.d/polkit-1"
rc="$(run_setup "$ROOT" "$P" --check)"
check "the vendor polkit-1 running pam_fprintd, with no override" "$rc:$(out_has 'polkit-1 puts pam_fprintd where it would delay a password')" "1:1"
cp "$PRISTINE/usr/lib/pam.d/polkit-1" "$P/etc/pam.d/polkit-1" || fatal "polkit override fixture"
rc="$(run_setup "$ROOT" "$P" --check)"
check "... but shadowed by a clean /etc/pam.d/polkit-1 it is not effective: exit 0" "$rc" 0
P="$(installed_prefix)"; sed -i '1a # auth sufficient pam_fprintd.so' "$P/etc/pam.d/common-auth"
rc="$(run_setup "$ROOT" "$P" --check)"
check "a COMMENTED pam_fprintd line runs nothing: exit 0" "$rc" 0
P="$(installed_prefix)"; rm -f "$P/usr/lib/x86_64-linux-gnu/security/pam_fprintd.so"
rc="$(run_setup "$ROOT" "$P" --check)"
check "pam_fprintd.so not installed" "$rc:$(out_has 'pam_fprintd.so is not installed')" "1:1"
P="$(installed_prefix)"; sed -i '0,/pam_unix/s/^auth.*pam_unix.*/auth requisite pam_faillock.so preauth\n&/' "$P/etc/pam.d/common-auth"
rc="$(run_setup "$ROOT" "$P" --check)"
check "common-auth gains pam_faillock (a correct password at the stanza would skip its lockout)" \
  "$rc:$(out_has 'pam_faillock.so, which a correct password at the stanza would skip')" "1:1"
P="$(installed_prefix)"; printf '@include common-auth-extra\n' >>"$P/etc/pam.d/common-auth"
rc="$(run_setup "$ROOT" "$P" --check)"
check "common-auth includes another file (what it runs cannot be read from here)" \
  "$rc:$(out_has 'common-auth includes another file')" "1:1"
P="$(installed_prefix)"; cp "$ROOT_BAD/pam/sudo-fingerprint" "$P$STANZA_INSTALLED_PATH"
rc="$(run_setup "$ROOT_BAD" "$P" --check)"
check "an installed stanza libpam cannot load, though it matches its checkout: says sudo refuses everyone" \
  "$rc:$(out_has 'libpam refuses a CORRECT password'):$(out_has 'pkexec sed -i'):$(out_has 'sudo-fingerprint matches this checkout')" \
  "1:2:1:1"

# ---------------------------------------------------------------------------
printf '\ninstall refuses, and writes nothing\n'
P="$(newprefix)"; sed -i '/^@include common-auth$/d' "$P/etc/pam.d/sudo"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "a sudo file with no @include common-auth to put the fingerprint before: exit 2" \
  "$rc:$(tree_hash "$P"):$(logged_re '^sudo '):$(out_has "has no single '@include common-auth'")" "2:$before:0:1"
P="$(newprefix)"; printf '@include common-auth\n' >>"$P/etc/pam.d/sudo-i"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "a sudo-i file with two of them (which one?): exit 2" "$rc:$(tree_hash "$P")" "2:$before"
P="$(newprefix)"; sed -i '0,/pam_unix/s/^auth.*pam_unix.*/auth [success=end default=ignore] pam_fprintd.so\n&/' "$P/etc/pam.d/common-auth"
before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "common-auth already running pam_fprintd: exit 1, names the remedy" \
  "$rc:$(tree_hash "$P"):$(out_has 'pam-auth-update --disable fprintd')" "1:$before:1"
P="$(newprefix)"; sed -i 's/^# enable-fingerprint-authentication=false$/enable-fingerprint-authentication=true/' "$P/etc/gdm3/greeter.dconf-defaults"
before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "the greeter key already set by someone else: exit 1, shows the line" \
  "$rc:$(tree_hash "$P"):$(out_has 'also sets enable-fingerprint-authentication')" "1:$before:1"
P="$(newprefix)"; sed -i 's/^\[org\/gnome\/login-screen\]$/[org\/gnome\/other]/' "$P/etc/gdm3/greeter.dconf-defaults"
before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "a greeter file with no [org/gnome/login-screen] section: exit 2" "$rc:$(tree_hash "$P")" "2:$before"
P="$(newprefix)"; rm -f "$P/etc/gdm3/greeter.dconf-defaults"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "no greeter file at all: exit 2" "$rc:$(tree_hash "$P")" "2:$before"
P="$(newprefix)"; rm -f "$P/usr/lib/x86_64-linux-gnu/security/pam_fprintd.so"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "libpam-fprintd not installed: exit 2" "$rc:$(tree_hash "$P"):$(out_has 'apt install libpam-fprintd')" "2:$before:1"
P="$(newprefix)"; rm -f "$P/etc/pam.d/sudo-i"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "no /etc/pam.d/sudo-i: exit 2" "$rc:$(tree_hash "$P")" "2:$before"
P="$(newprefix)"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT_BAD" "$P")"
check "a stanza libpam cannot load (one misspelled keyword would refuse EVERY sudo): exit 1, nothing written" \
  "$rc:$(tree_hash "$P"):$(logged_re '^sudo '):$(out_has 'libpam refuses a CORRECT password')" "1:$before:0:2"
P="$(newprefix)"; sed -i '0,/pam_unix/s/^auth.*pam_unix.*/auth requisite pam_faillock.so preauth\n&/' "$P/etc/pam.d/common-auth"
before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "common-auth with pam_faillock: exit 1, nothing written" \
  "$rc:$(tree_hash "$P"):$(out_has 'pam_faillock.so, which a correct password at the stanza would skip')" "1:$before:1"
P="$(newprefix)"; truncate -s -1 "$P/etc/pam.d/sudo"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "a sudo file with no final newline (--remove could not restore it byte for byte): exit 2" \
  "$rc:$(tree_hash "$P"):$(out_has 'does not end in a newline')" "2:$before:1"
P="$(newprefix)"; truncate -s -1 "$P/etc/gdm3/greeter.dconf-defaults"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P")"
check "a greeter file with no final newline: exit 2" "$rc:$(tree_hash "$P")" "2:$before"
P="$(newprefix)"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT_NO_PROBE" "$P")"
check "a checkout without the libpam probe (nothing to validate the stack with): exit 2, nothing written" \
  "$rc:$(tree_hash "$P"):$(out_has 'are needed to load the stack')" "2:$before:1"

P="$(newprefix)"
rc="$(STUB_GDM_RELOAD_FAIL=1 run_setup "$ROOT" "$P")"
check "a gdm reload that fails: exit 1, and says the greeter changes at the next boot" \
  "$rc:$(out_has 'at the next boot')" "1:1"

# ---------------------------------------------------------------------------
printf '\n--remove\n'
P="$(installed_prefix)"
rc="$(run_setup "$ROOT" "$P" --remove)"
check "--remove: exit 0" "$rc" 0
check "sudo, sudo-i and the greeter file are byte-identical to before the install" \
  "$(same_as_pristine "$P" etc/pam.d/sudo) $(same_as_pristine "$P" etc/pam.d/sudo-i) $(same_as_pristine "$P" etc/gdm3/greeter.dconf-defaults)" \
  "same same same"
check "the stanza and the gate are gone" \
  "$([[ -e $P$STANZA_INSTALLED_PATH || -e $P$GATE_INSTALLED_PATH ]] && echo present || echo gone)" gone
sudo_at="$(logged_at 'mv -f .*/pam\.d/sudo$')"
stanza_at="$(logged_at '^sudo rm -f .*/pam\.d/sudo-fingerprint$')"
check "the includes come out BEFORE the stanza does (a missing include target breaks sudo outright)" \
  "$(( sudo_at > 0 && sudo_at < stanza_at ))" 1
check "gdm recompiles the greeter config" "$(logged 'sudo systemctl reload gdm.service')" 1
check "--check after --remove: exit 1" "$(run_setup "$ROOT" "$P" --check)" 1
P="$(newprefix)"; before="$(tree_hash "$P")"
rc="$(run_setup "$ROOT" "$P" --remove)"
check "--remove with nothing installed: exit 0, no sudo, no byte changed" \
  "$rc:$(logged_re '^sudo '):$(tree_hash "$P")" "0:0:$before"

# ---------------------------------------------------------------------------
printf '\nthe worktree guard\n'
G=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null)
mkroot "$T/repo"
{ "${G[@]}" -C "$T/repo" init -q -b main && "${G[@]}" -C "$T/repo" add -A \
    && "${G[@]}" -C "$T/repo" commit -q -m fixture \
    && "${G[@]}" -C "$T/repo" worktree add -q -b feature "$T/wt"; } >/dev/null 2>&1 \
  || fatal "could not build the worktree fixtures"
P="$(newprefix)"; before="$(tree_hash "$P")"
rc="$(run_setup "$T/wt" "$P")"
check "from a worktree: exit 1, nothing written, and the refusal names the remedy" \
  "$rc:$(tree_hash "$P"):$(out_has 'cd ~/.dotfiles && fingerprint-setup')" "1:$before:1"
P="$(newprefix)"
rc="$(FINGERPRINT_SETUP_ALLOW_WORKTREE=1 run_setup "$T/wt" "$P")"
check "FINGERPRINT_SETUP_ALLOW_WORKTREE=1 overrides it, with a warning and no red refusal" \
  "$rc:$([[ -f $P$STANZA_INSTALLED_PATH ]] && echo installed):$(out_has 'refusing to install'):$(out_has 'as FINGERPRINT_SETUP_ALLOW_WORKTREE=1 asks')" \
  "0:installed:0:1"
P="$(newprefix)"
rc="$(run_setup "$T/repo" "$P")"
check "the primary checkout of the same repo is not a worktree: installs" "$rc" 0
P="$(newprefix)"
rc="$(run_setup "$T/wt" "$P" --check)"
check "--check runs from a worktree (it writes nothing), and is not refused" \
  "$rc:$(out_has 'refusing to install from a WORKTREE'):$(out_has 'is not installed')" "1:0:2"

# ---------------------------------------------------------------------------
# The installed files, run through the REAL libpam. pam_start_confdir() reads
# the service from a directory of our choosing, so no root and no /etc.
printf '\nthe installed stack, through the real libpam (permit/deny stand in for right/wrong)\n'
P="$(installed_prefix)"
CONF="$T/pamconf"
# stack <first password> <finger> <second password> <lid dir> — the installed
# sudo, stanza and common-auth in $CONF, each real module swapped for its
# stand-in (pam_permit = right, pam_deny = wrong), and the INSTALLED gate.
stack() {
  { rm -rf "$CONF" && mkdir -p "$CONF"; } || fatal "pamconf"
  cp "$P/etc/pam.d/sudo" "$P/etc/pam.d/common-auth" "$P$STANZA_INSTALLED_PATH" "$CONF/" || fatal "pamconf"
  printf 'account required pam_permit.so\n' >"$CONF/common-account"
  printf 'session required pam_permit.so\n' >"$CONF/common-session-noninteractive"
  sed -i -e "s|pam_unix\.so nullok|pam_$1.so|" -e "s|pam_fprintd\.so max-tries=2 timeout=10|pam_$2.so|" \
         -e "s|$GATE_INSTALLED_PATH|$P$GATE_INSTALLED_PATH --lid-dir $4 --passwd-file $PASSWD_FIXTURE --log-file $GATE_LOG|" \
         "$CONF/sudo-fingerprint" || fatal "pamconf"
  sed -i -e "s|pam_unix\.so nullok|pam_$3.so|" -e 's|pam_sss\.so use_first_pass|pam_deny.so|' \
         -e 's|pam_cap\.so|pam_permit.so|' "$CONF/common-auth" || fatal "pamconf"
  : >"$GATE_LOG"
}
# probe [args] — the shared probe on $CONF's sudo: "<result> <prompts>".
probe() { python3 -I "$PROBE" --confdir "$CONF" --service sudo "$@" 2>&1; }
# authenticate <tty> — the result alone, as the local account "someone".
authenticate() { local outcome; outcome="$(probe --user someone --tty "$1")"; printf '%s' "${outcome%% *}"; }

stack permit deny deny "$LID_OPEN"
python3 -I "$PROBE" --confdir "$CONF" --service sudo >/dev/null 2>&1
[[ $? == 2 ]] && fatal "the probe cannot run here: no libpam with pam_start_confdir (Linux-PAM < 1.4)"
check "the stand-ins replaced every real module and the gate path (else this section tests nothing)" \
  "$(cat "$CONF"/* | grep -v '^[[:space:]]*#' | grep -c -E "pam_unix|pam_fprintd|pam_sss|pam_cap| $GATE_INSTALLED_PATH")" 0
result="$(authenticate /dev/pts/3)"
check "the right password first: authenticated, and the gate never even runs" \
  "$result:$(wc -l <"$GATE_LOG" | tr -d ' ')" "$PAM_SUCCESS:0"
stack deny permit deny "$LID_OPEN"
check "a wrong (or empty) password, a terminal, the lid open: the finger authenticates" \
  "$(authenticate /dev/pts/3):$(gate_said 'offer:')" "$PAM_SUCCESS:1"
stack deny deny permit "$LID_OPEN"
check "the finger fails, and common-auth's own check accepts: authenticated (a failed finger decides nothing)" \
  "$(authenticate /dev/pts/3)" "$PAM_SUCCESS"
stack deny permit deny "$LID_CLOSED"
check "lid closed: the finger is never asked, though it would have matched" \
  "$(authenticate /dev/pts/3):$(gate_said 'skip: lid closed')" "$PAM_AUTH_ERR:1"
stack deny deny permit "$LID_CLOSED"
check "lid closed, and common-auth's own check accepts: authenticated (the skip's jump poisons nothing)" \
  "$(authenticate /dev/pts/3)" "$PAM_SUCCESS"
stack deny permit deny "$LID_OPEN"
check "no terminal: the finger is never asked, though it would have matched" \
  "$(authenticate ''):$(gate_said 'skip: no terminal')" "$PAM_AUTH_ERR:1"
stack deny deny deny "$LID_OPEN"
check "everything wrong: refused" "$(authenticate /dev/pts/3)" "$PAM_AUTH_ERR"
stack permit permit permit "$LID_OPEN"; rm -f "$CONF/sudo-fingerprint"
check "the stanza missing while sudo includes it: libpam aborts before any password is asked" \
  "$(authenticate /dev/pts/3)" "start:$PAM_ABORT"
stack deny permit deny "$LID_CLOSED"
sed -i "s|$P$GATE_INSTALLED_PATH|$T/no/such/gate|" "$CONF/sudo-fingerprint"
check "the gate missing: pam_exec's failure reads as OFFER, lid closed or not (why the gate goes in first)" \
  "$(authenticate '')" "$PAM_SUCCESS"

printf '\nthe probe itself (its prompt count is what the next two rows rest on)\n'
PROBE_CONF="$T/probeconf"
mkdir -p "$PROBE_CONF" || fatal "probe fixture"
printf 'auth optional pam_echo.so an info message, not a prompt\nauth required pam_permit.so\n' \
  >"$PROBE_CONF/echo-then-permit" || fatal "probe fixture"
check "an info message (what pam_fprintd's 'Place your finger' is) is not counted as a prompt" \
  "$(python3 -I "$PROBE" --confdir "$PROBE_CONF" --service echo-then-permit 2>&1)" "$PAM_SUCCESS 0"
check "a service that does not exist: pam_start's own refusal, never a result" \
  "$(python3 -I "$PROBE" --confdir "$PROBE_CONF" --service no-such-service 2>&1)" "start:$PAM_ABORT"
check "bad arguments: exit 2 (could not run), never a result" \
  "$(python3 -I "$PROBE" --service no-confdir-given >/dev/null 2>&1; echo $?)" 2

printf '\nthe re-prompt is the caller retrying, not common-auth (the REAL pam_unix, an account it does not know)\n'
stack unix deny unix "$LID_OPEN"
check "one attempt asks ONCE: common-auth's pam_unix re-checks the cached password, and the attempt fails" \
  "$(probe --user fingerprint-test-nobody --tty /dev/pts/3):$(gate_said 'offer:')" "$PAM_AUTH_ERR 1:1"
stack unix deny unix "$LID_OPEN"
check "a second attempt on the same handle (sudo's retry) is what asks again" \
  "$(probe --user fingerprint-test-nobody --tty /dev/pts/3 --attempts 2)" "$PAM_AUTH_ERR 2"

EXPECTED_ROWS=132

# --- the count this suite is documented as running ---------------------------
# Same needle as the other suites: docs/REPO_CHECKS.md, "Where a check count lives".
docs_claim() {
  local f="$HERE/../$1"
  [[ -r "$f" ]] || { printf 'cannot read %s' "$1"; return; }
  tr -s '[:space:]' ' ' <"$f" \
    | grep -c -F "\`scripts/test-fingerprint.sh\` ($EXPECTED_ROWS checks"
}

printf '\nthe count this suite is documented as running\n'
check "docs/FINGERPRINT.md says $EXPECTED_ROWS checks" "$(docs_claim docs/FINGERPRINT.md)" 1
check "a documented file that cannot be read is not a pass" \
      "$(docs_claim no/such/file.md)" "cannot read no/such/file.md"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( PASS + FAIL != EXPECTED_ROWS )); then
  printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
    "$EXPECTED_ROWS" "$((PASS + FAIL))"
  FAIL=$((FAIL + 1))
fi
(( FAIL == 0 ))
