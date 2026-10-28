#!/usr/bin/env bash
#
# scripts/test-dev-link.sh
# ========================
#
# State table for scripts/dev-link-probe.sh (the probes) and `dev-link-doctor` in
# zsh/functions/system.sh (the verdicts). docs/DEV_LINK.md is the record.
#
# Why this exists: the agent path to dev (ssh over an SSM ProxyCommand) failed for
# a month in a way nothing reported. The credential behind it expired every 12 h,
# the mux hid the expiry for ten minutes, and the one surface that noticed --
# rabota's census -- wrote "unreachable" with ssh's generic error. Every row here
# is written against the state that LOOKS healthy: a profile that resolves to the
# wrong identity, a key-age check that is denied and reads as fine, a probe that
# reuses a live master and never exercises the credential, an ssh that hangs
# instead of failing.
#
# HERMETIC: `aws`, `ssh`, `ssh-add`, `systemctl` and `ip` are recording STUBS at
# the front of a PATH built from scratch, and $HOME is a fixture. This box has a
# real `aws` wired to live credentials and a real `ssh dev` that opens an SSM
# session; a row that reached either would spend a session on a real instance
# or, worse, pass for reasons having nothing to do with the code under test.
#
# "Could not run" is exit 2, never a pass. The suite asserts its own row total.
#
# Requires: bash, zsh, jq, timeout. No network, no sudo, no AWS, no dev.
#
# Usage: scripts/test-dev-link.sh
#   DEV_LINK_PROBE_SH=/tmp/mutant.sh scripts/test-dev-link.sh   # run against a mutant

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DOTFILES="$(cd "$HERE/.." && pwd -P)"
PROBE="${DEV_LINK_PROBE_SH:-$HERE/dev-link-probe.sh}"
SYSTEMSH="${DEV_LINK_SYSTEM_SH:-$DOTFILES/zsh/functions/system.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }
want_out() { if [[ "$OUT" == *"$2"* ]]; then ok "$1"; else bad "$1 — expected output to contain '$2'"; fi; }
no_out()   { if [[ "$OUT" != *"$2"* ]]; then ok "$1"; else bad "$1 — output must NOT contain '$2'"; fi; }
want_rc()  { if [[ "$RC" == "$2" ]]; then ok "$1"; else bad "$1 — expected exit $2, got $RC"; fi; }
# A line-anchored field assertion: `key=value` must appear as a whole line.
want_field() { if grep -qxF -- "$2" <<<"$OUT"; then ok "$1"; else bad "$1 — expected a line '$2' in: $(tr '\n' '|' <<<"$OUT" | cut -c1-200)"; fi; }

for tool in bash zsh jq timeout; do
  command -v "$tool" >/dev/null || fatal "$tool is required"
done
[[ -r "$PROBE" ]] || fatal "cannot read $PROBE"
[[ -x "$PROBE" ]] || fatal "$PROBE is not executable"
[[ -r "$SYSTEMSH" ]] || fatal "cannot read $SYSTEMSH"

# A PATH built from scratch: the stubs, then exactly the binaries the probe and
# the doctor use. Inheriting $PATH would find the real aws and the real ssh.
STUBBIN="$TMPROOT/bin"; SYSBIN="$TMPROOT/sysbin"; mkdir -p "$STUBBIN" "$SYSBIN"
for t in bash zsh jq timeout date grep sed awk sort uniq head tail cut tr wc cat printf stat \
         mktemp rm mkdir dirname basename readlink chmod sleep env true false; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$SYSBIN/$t"
done
[[ -x "$SYSBIN/zsh" && -x "$SYSBIN/jq" && -x "$SYSBIN/timeout" ]] || fatal "could not stage the fixture PATH"
NOAWSBIN="$TMPROOT/noawsbin"; mkdir -p "$NOAWSBIN"   # the stubs minus aws, for the could-not-run row

STUB_LOG="$TMPROOT/stub.log"
FHOME="$TMPROOT/home"; mkdir -p "$FHOME/.aws"; chmod 700 "$FHOME/.aws"
printf '[dev-ssm]\naws_access_key_id = STUBKEYID\naws_secret_access_key = STUBSECRET\n' > "$FHOME/.aws/credentials"
chmod 600 "$FHOME/.aws/credentials"

# ---------------------------------------------------------------------------
# Stubs. Each records its argv (and the one env var that matters) to STUB_LOG
# and answers from STUB_* variables, so a row states the world it wants in env.
# ---------------------------------------------------------------------------
cat > "$STUBBIN/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "${STUB_LOG:?}"
if [[ "${1:-}" == "-G" ]]; then
  [[ -n "${STUB_SSH_G_RC:-}" ]] && exit "$STUB_SSH_G_RC"
  cat "${STUB_SSH_G_FILE:?}"; exit 0
fi
if [[ "${1:-}" == "-O" ]]; then
  if [[ "${STUB_SSH_MASTER_RC:-255}" == 0 ]]; then echo "Master running (pid=1)" >&2; exit 0; fi
  echo "Control socket connect: No such file or directory" >&2; exit 255
fi
sleep "${STUB_SSH_SLEEP:-0}"
[[ -n "${STUB_SSH_STDERR:-}" ]] && printf '%b\n' "$STUB_SSH_STDERR" >&2
exit "${STUB_SSH_RC:-0}"
EOF
cat > "$STUBBIN/aws" <<'EOF'
#!/usr/bin/env bash
printf 'aws %s [AWS_EC2_METADATA_DISABLED=%s]\n' "$*" "${AWS_EC2_METADATA_DISABLED:-unset}" >> "${STUB_LOG:?}"
args=" $* "
if [[ "$args" == *" sts get-caller-identity "* ]]; then
  if [[ "${STUB_AWS_STS_RC:-0}" != 0 ]]; then printf '%s\n' "${STUB_AWS_STS_ERR:-Unable to locate credentials. You can configure credentials by running "aws configure".}" >&2; exit "$STUB_AWS_STS_RC"; fi
  printf '{"UserId": "AIDASTUBSTUBSTUBSTUB", "Account": "123456789012", "Arn": "%s"}\n' "${STUB_AWS_ARN:-arn:aws:iam::123456789012:user/cilantro-dev-ssm}"; exit 0
fi
if [[ "$args" == *" ssm describe-instance-information "* ]]; then
  case "${STUB_AWS_SSM_MODE:-online}" in
    online) echo '{"InstanceInformationList": [{"InstanceId": "i-0c97f437d3da87e51", "PingStatus": "Online", "AgentVersion": "3.3.4793.0"}]}' ;;
    lost)   echo '{"InstanceInformationList": [{"InstanceId": "i-0c97f437d3da87e51", "PingStatus": "ConnectionLost"}]}' ;;
    empty)  echo '{"InstanceInformationList": []}' ;;
    denied) echo "An error occurred (AccessDeniedException) when calling the DescribeInstanceInformation operation: User is not authorized" >&2; exit 254 ;;
    *)      echo "An error occurred (EndpointConnectionError): Could not connect" >&2; exit 255 ;;
  esac; exit 0
fi
if [[ "$args" == *" iam list-access-keys "* ]]; then
  case "${STUB_AWS_KEYS_MODE:-ours}" in
    ours)  printf '{"AccessKeyMetadata": [{"AccessKeyId": "%s", "Status": "Active", "CreateDate": "%s"}]}\n' "${STUB_KEY_ID:?}" "${STUB_KEY_DATE:?}" ;;
    two)   printf '{"AccessKeyMetadata": [{"AccessKeyId": "%s", "Status": "Active", "CreateDate": "%s"}, {"AccessKeyId": "AKIAOTHERKEYOTHERKEY", "Status": "Active", "CreateDate": "%s"}]}\n' "${STUB_KEY_ID:?}" "${STUB_KEY_DATE:?}" "${STUB_KEY_DATE:?}" ;;
    other) printf '{"AccessKeyMetadata": [{"AccessKeyId": "AKIAOTHERKEYOTHERKEY", "Status": "Active", "CreateDate": "%s"}]}\n' "${STUB_KEY_DATE:?}" ;;
    denied) echo "An error occurred (AccessDenied) when calling the ListAccessKeys operation: User is not authorized" >&2; exit 254 ;;
    *)      echo "An error occurred (EndpointConnectionError): Could not connect" >&2; exit 255 ;;
  esac; exit 0
fi
if [[ "$args" == *" configure get aws_access_key_id "* ]]; then printf '%s\n' "${STUB_KEY_ID:?}"; exit 0; fi
if [[ "$args" == *" --version "* ]]; then echo "aws-cli/2.34.29 stub"; exit 0; fi
echo "aws stub: unexpected invocation: $*" >&2; exit 99
EOF
cat > "$STUBBIN/ssh-add" <<'EOF'
#!/usr/bin/env bash
printf 'ssh-add %s\n' "$*" >> "${STUB_LOG:?}"
sleep "${STUB_AGENT_SLEEP:-0}"
if [[ "${STUB_AGENT_RC:-0}" == 0 ]]; then echo "256 SHA256:stub (cilantro) (ED25519)"; exit 0; fi
echo "Error connecting to agent: No such file or directory" >&2; exit "${STUB_AGENT_RC}"
EOF
cat > "$STUBBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${STUB_LOG:?}"
args=" $* "
case "$args" in
  *" -p LoadState "*)   printf '%s\n' "${STUB_UNIT_LOAD:-not-found}" ;;
  *" is-enabled "*)     printf '%s\n' "${STUB_UNIT_ENABLED:-disabled}"; [[ "${STUB_UNIT_ENABLED:-disabled}" == enabled ]] || exit 1 ;;
  *" -p ActiveState "*) printf '%s\n' "${STUB_UNIT_ACTIVE:-inactive}" ;;
  *" -p Result "*)      printf '%s\n' "${STUB_UNIT_RESULT:-success}" ;;
  *) exit 1 ;;
esac
EOF
cat > "$STUBBIN/ip" <<'EOF'
#!/usr/bin/env bash
printf 'ip %s\n' "$*" >> "${STUB_LOG:?}"
args=" $* "
case "$args" in
  *" -j link "*)   printf '%s\n' "${STUB_IP_LINK:-[]}" ;;
  *" -j route "*)  printf '%s\n' "${STUB_IP_JROUTE:-[]}" ;;
  *" route show "*) printf '%s' "${STUB_IP_ROUTES:-}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUBBIN"/*
cp -a "$STUBBIN/." "$NOAWSBIN/"; rm -f "$NOAWSBIN/aws"

# ssh -G fixtures: what the real `ssh -G dev` prints, trimmed to the keys that matter.
G_SSM="$TMPROOT/g-ssm";        printf 'hostname i-0c97f437d3da87e51\nuser ubuntu\nhostkeyalias 54.166.22.221\nproxycommand aws ssm start-session --profile dev-ssm --region us-east-1 --target %%h --document-name AWS-StartSSHSession --parameters portNumber=%%p\ncontrolpersist 600\n' > "$G_SSM"
G_SSM_NOPROF="$TMPROOT/g-ssm-noprof"; printf 'hostname i-0c97f437d3da87e51\nuser ubuntu\nproxycommand aws ssm start-session --region us-east-1 --target %%h --document-name AWS-StartSSHSession --parameters portNumber=%%p\n' > "$G_SSM_NOPROF"
G_SSM_EQ="$TMPROOT/g-ssm-eq";  printf 'hostname i-0c97f437d3da87e51\nproxycommand aws ssm start-session --profile=dev-ssm --target %%h\n' > "$G_SSM_EQ"
G_OTHER="$TMPROOT/g-other";    printf 'hostname 54.166.22.221\nproxycommand nc -X connect -x proxy:8080 %%h %%p\n' > "$G_OTHER"
G_NONE="$TMPROOT/g-none";      printf 'hostname 54.166.22.221\nuser ubuntu\nproxycommand none\n' > "$G_NONE"

run_probe() {   # run_probe <args...>  -> OUT, RC; env from the caller's STUB_* exports
  local base="${PROBE_BIN:-$STUBBIN}"
  : > "$STUB_LOG"
  OUT="$(env -i PATH="$base:$SYSBIN" HOME="$FHOME" STUB_LOG="$STUB_LOG" \
           STUB_SSH_G_FILE="${STUB_SSH_G_FILE:-$G_SSM}" STUB_SSH_G_RC="${STUB_SSH_G_RC:-}" \
           STUB_SSH_RC="${STUB_SSH_RC:-0}" STUB_SSH_STDERR="${STUB_SSH_STDERR:-}" STUB_SSH_SLEEP="${STUB_SSH_SLEEP:-0}" \
           STUB_AWS_STS_RC="${STUB_AWS_STS_RC:-0}" STUB_AWS_STS_ERR="${STUB_AWS_STS_ERR:-}" STUB_AWS_ARN="${STUB_AWS_ARN:-}" \
           STUB_AWS_SSM_MODE="${STUB_AWS_SSM_MODE:-online}" STUB_AWS_KEYS_MODE="${STUB_AWS_KEYS_MODE:-ours}" \
           STUB_KEY_ID="${STUB_KEY_ID:-AKIASTUBSTUBSTUBSTUB}" STUB_KEY_DATE="${STUB_KEY_DATE:-2026-10-18T00:00:00+00:00}" \
           DEV_LINK_NOW="${DEV_LINK_NOW:-1793145600}" DEV_LINK_SSH_TIMEOUT="${DEV_LINK_SSH_TIMEOUT:-40}" \
           DEV_LINK_AWS_TIMEOUT="${DEV_LINK_AWS_TIMEOUT:-15}" DEV_LINK_REDACTOR="$HERE/redact-secrets.sh" \
           bash "$PROBE" "$@" 2>&1)"; RC=$?
}

# =============================================================================
section "A. --resolve: what ssh -G says the dev path is"
# The profile and instance id are READ from the live ssh config, never carried as
# constants, so the doctor and the config cannot disagree about which profile
# the ProxyCommand will actually use.
run_probe --resolve dev
want_rc   "resolve: exits 0 on a readable config" 0
want_field "resolve: an SSM ProxyCommand is proxy=ssm" "proxy=ssm"
want_field "resolve: the --profile the ProxyCommand pins" "profile=dev-ssm"
want_field "resolve: the instance id the ProxyCommand targets" "instance=i-0c97f437d3da87e51"
want_field "resolve: the HostKeyAlias (the IP the VPN fallback uses)" "hostkeyalias=54.166.22.221"
check "resolve: asked ssh -G about the host it was given" "$(grep -c '^ssh -G dev$' "$STUB_LOG")" 1
STUB_SSH_G_FILE="$G_SSM_NOPROF" run_probe --resolve dev
want_field "resolve: no --profile is an EMPTY profile, not a guess" "profile="
want_field "resolve: ...and still proxy=ssm" "proxy=ssm"
STUB_SSH_G_FILE="$G_SSM_EQ" run_probe --resolve dev
want_field "resolve: the --profile=NAME spelling is read too" "profile=dev-ssm"
STUB_SSH_G_FILE="$G_OTHER" run_probe --resolve dev
want_field "resolve: a non-SSM ProxyCommand is proxy=other" "proxy=other"
want_field "resolve: a hostname that is not an instance id gives instance= empty" "instance="
STUB_SSH_G_FILE="$G_NONE" run_probe --resolve dev
want_field "resolve: 'proxycommand none' is proxy=none" "proxy=none"
want_field "resolve: no HostKeyAlias is hostkeyalias= empty, never the hostname" "hostkeyalias="
STUB_SSH_G_RC=255 run_probe --resolve dev
want_rc   "resolve: ssh -G failing is COULD NOT RUN (exit 2)" 2
no_out    "resolve: ...and prints no proxy= line to be misread" "proxy="
run_probe --resolve
check "resolve: the host defaults to dev" "$(grep -c '^ssh -G dev$' "$STUB_LOG")" 1

# =============================================================================
section "B. --api: the credential and dev's SSM registration"
run_probe --api dev-ssm i-0c97f437d3da87e51
want_rc   "api: exits 0 when both probes answered" 0
want_field "api: identity=ok" "identity=ok"
want_field "api: the principal is printed as user/<name> only" "principal=user/cilantro-dev-ssm"
no_out    "api: the account id never appears" "123456789012"
want_field "api: dev's SSM PingStatus" "ping=Online"
check "api: sts was called with --profile dev-ssm" "$(grep -c -- '--profile dev-ssm sts get-caller-identity' "$STUB_LOG")" 1
check "api: ...with the instance metadata service DISABLED (a missing profile must not stall on IMDS)" "$(grep -c 'AWS_EC2_METADATA_DISABLED=true' "$STUB_LOG")" 2
STUB_AWS_ARN='arn:aws:iam::123456789012:user/AdminZvi' run_probe --api dev-ssm i-0c97f437d3da87e51
want_field "api: an admin principal is reported faithfully (the doctor decides)" "principal=user/AdminZvi"
STUB_AWS_ARN='arn:aws:sts::123456789012:assumed-role/Deploy/session' run_probe --api dev-ssm i-0c97f437d3da87e51
want_field "api: an assumed-role ARN keeps role and session, drops the account" "principal=assumed-role/Deploy/session"
STUB_AWS_STS_RC=255 STUB_AWS_STS_ERR='Unable to locate credentials. You can configure credentials by running "aws configure".' run_probe --api dev-ssm i-0c97f437d3da87e51
want_rc   "api: a failed identity call is still a probe that RAN (exit 0)" 0
want_field "api: identity=fail" "identity=fail"
want_out  "api: ...with the CLI's first stderr line as the reason" "reason=Unable to locate credentials"
no_out    "api: ...and no ping= line (nothing was asked without an identity)" "ping="
STUB_AWS_SSM_MODE=lost run_probe --api dev-ssm i-0c97f437d3da87e51
want_field "api: ConnectionLost is reported as the status, not as unregistered" "ping=ConnectionLost"
STUB_AWS_SSM_MODE=empty run_probe --api dev-ssm i-0c97f437d3da87e51
want_field "api: an empty list is ping=unregistered" "ping=unregistered"
STUB_AWS_SSM_MODE=denied run_probe --api dev-ssm i-0c97f437d3da87e51
want_field "api: AccessDenied on the registration read is ping=denied, not unregistered" "ping=denied"
STUB_AWS_SSM_MODE=fail run_probe --api dev-ssm i-0c97f437d3da87e51
want_field "api: any other failure is ping=fail" "ping=fail"
run_probe --api dev-ssm
no_out    "api: no instance id means no ping= line, not a probe of nothing" "ping="
PROBE_BIN="$NOAWSBIN" run_probe --api dev-ssm i-0c97f437d3da87e51
want_rc   "api: aws missing from PATH is COULD NOT RUN (exit 2)" 2
no_out    "api: ...and prints no identity= verdict" "identity="
STUB_AWS_STS_RC=255 STUB_AWS_STS_ERR='error for AKIAIOSFODNN7EXAMPLE' run_probe --api dev-ssm
no_out    "api: a key id in the CLI's stderr is redacted before it is printed" "AKIAIOSFODNN7EXAMPLE"

# =============================================================================
section "C. --keys: the age of the key the profile actually uses"
# The profile's own key id is read in-shell and matched against IAM's list; the
# id itself is never printed. 0 matches means the profile's key is not this
# user's -- the identity pin is wrong -- and that is the row that matters.
STUB_KEY_DATE='2026-10-18T00:00:00+00:00' run_probe --keys dev-ssm      # DEV_LINK_NOW = 2026-10-28
want_field "keys: our key, one active, 10 days old" "keys=ok"
want_field "keys: matches=1" "matches=1"
want_field "keys: active=1" "active=1"
want_field "keys: age_days=10" "age_days=10"
no_out    "keys: the key id is never printed" "AKIASTUBSTUBSTUBSTUB"
STUB_AWS_KEYS_MODE=two run_probe --keys dev-ssm
want_field "keys: two active keys on the user (rotation in progress)" "active=2"
want_field "keys: ...still matches=1" "matches=1"
STUB_AWS_KEYS_MODE=other run_probe --keys dev-ssm
want_field "keys: the profile's key is not among this user's keys: matches=0" "matches=0"
STUB_AWS_KEYS_MODE=denied run_probe --keys dev-ssm
want_field "keys: AccessDenied is keys=denied (the doctor must not read it as fresh)" "keys=denied"
STUB_AWS_KEYS_MODE=fail run_probe --keys dev-ssm
want_field "keys: any other failure is keys=fail" "keys=fail"
check "keys: list-access-keys was asked with --profile dev-ssm" "$(grep -c -- '--profile dev-ssm iam list-access-keys' "$STUB_LOG")" 1

# =============================================================================
section "D. --ssh: a FRESH connection, never the mux"
# ControlPersist 10m means an open master answers `ssh dev true` for ten minutes
# after the credential behind it has died. The probe must bypass it, and must
# fail rather than hang when the ProxyCommand stalls before or after the banner.
run_probe --ssh dev
want_rc   "ssh: exits 0 on success" 0
want_field "ssh: ssh=ok" "ssh=ok"
check "ssh: a latency in ms is printed" "$(grep -cE '^ms=[0-9]+$' <<<"$OUT")" 1
check "ssh: the connection bypasses the control socket" "$(grep -c -- '-o ControlPath=none' "$STUB_LOG")" 1
check "ssh: ...and does not open a new master either" "$(grep -c -- '-o ControlMaster=no' "$STUB_LOG")" 1
check "ssh: ...and can never prompt (BatchMode=yes)" "$(grep -c -- '-o BatchMode=yes' "$STUB_LOG")" 1
check "ssh: the host is the one given, and the remote command is true" "$(grep -c -- ' -- dev true$' "$STUB_LOG")" 1
run_probe --ssh
check "ssh: the host defaults to dev" "$(grep -c -- ' -- dev true$' "$STUB_LOG")" 1
STUB_SSH_RC=255 STUB_SSH_STDERR='kex_exchange_identification: Connection closed by remote host\nConnection closed by UNKNOWN port 65535' run_probe --ssh dev
want_rc   "ssh: a failed probe still exits 0 (the verdict is in the output)" 0
want_field "ssh: ssh=fail" "ssh=fail"
want_field "ssh: 'UNKNOWN port 65535' is the ProxyCommand dying: cause=proxy" "cause=proxy"
want_field "ssh: the exit code is reported" "rc=255"
STUB_SSH_RC=255 STUB_SSH_STDERR='ubuntu@i-0c97f437d3da87e51: Permission denied (publickey).' run_probe --ssh dev
want_field "ssh: Permission denied (publickey) is the agent or key: cause=auth" "cause=auth"
STUB_SSH_RC=255 STUB_SSH_STDERR='ssh: connect to host 54.166.22.221 port 22: Connection timed out' run_probe --ssh dev
want_field "ssh: anything else is cause=network" "cause=network"
DEV_LINK_SSH_TIMEOUT=1 STUB_SSH_SLEEP=3 run_probe --ssh dev
want_field "ssh: a probe that outlives DEV_LINK_SSH_TIMEOUT is killed: cause=timeout" "cause=timeout"
want_field "ssh: ...with rc=124" "rc=124"
STUB_SSH_RC=255 STUB_SSH_STDERR='debug: token AKIAIOSFODNN7EXAMPLE leaked\nConnection closed by UNKNOWN port 65535' run_probe --ssh dev
want_out  "ssh: the LAST stderr line is the detail" "detail=Connection closed by UNKNOWN port 65535"
STUB_SSH_RC=255 STUB_SSH_STDERR='Connection closed by UNKNOWN port 65535 AKIAIOSFODNN7EXAMPLE' run_probe --ssh dev
no_out    "ssh: a key id in stderr is redacted before it is printed" "AKIAIOSFODNN7EXAMPLE"

# =============================================================================
section "E. --once: the composed probe, one line, exit 0 whatever dev's state"
# A timer-activated oneshot that exits non-zero when dev is down would make
# check-timer-health.sh report the TIMER broken. Dev's state is the line's job.
run_probe --once dev
want_rc   "once: all good is exit 0" 0
check "once: exactly one line" "$(wc -l <<<"$OUT")" 1
check "once: the line is epoch, api=, ssh=, ms=, cause=, detail= in that order" \
  "$(grep -cE '^[0-9]+	api=ok	ssh=ok	ms=[0-9]+	cause=ok	detail=$' <<<"$OUT")" 1
check "once: the epoch is DEV_LINK_NOW" "$(cut -f1 <<<"$OUT")" "1793145600"
STUB_AWS_STS_RC=255 run_probe --once dev
want_rc   "once: a dead credential is still exit 0" 0
want_out  "once: ...reported as api=fail" "	api=fail	"
want_out  "once: ...and ssh is SKIPPED, not attempted with a credential known dead" "	ssh=skipped	"
want_out  "once: ...with cause=credential" "	cause=credential	"
check "once: no ssh probe ran" "$(grep -c -- 'ControlPath=none' "$STUB_LOG")" 0
STUB_SSH_RC=255 STUB_SSH_STDERR='Connection closed by UNKNOWN port 65535' run_probe --once dev
want_rc   "once: a dead link is exit 0" 0
want_out  "once: ...reported as ssh=fail with cause=proxy" "	ssh=fail	"
want_out  "once: ...cause=proxy" "	cause=proxy	"
STUB_SSH_G_FILE="$G_NONE" run_probe --once dev
want_out  "once: a host with no ProxyCommand skips the api probe (nothing to ask)" "	api=skipped	"
want_out  "once: ...and still probes ssh" "	ssh=ok	"
PROBE_BIN="$NOAWSBIN" run_probe --once dev
want_rc   "once: aws missing is COULD NOT RUN (exit 2), no line" 2
run_probe --bogus
want_rc   "an unknown mode is exit 2" 2
run_probe --help
want_rc   "--help exits 0" 0
want_out  "--help prints the usage header" "Usage"


# A session-manager-plugin stub: the doctor's first row only asks whether it is on PATH.
printf '#!/usr/bin/env bash\necho "stub 1.2.835.0"\n' > "$STUBBIN/session-manager-plugin"; chmod +x "$STUBBIN/session-manager-plugin"
cp -a "$STUBBIN/session-manager-plugin" "$NOAWSBIN/"
NOPLUGINBIN="$TMPROOT/nopluginbin"; mkdir -p "$NOPLUGINBIN"; cp -a "$STUBBIN/." "$NOPLUGINBIN/"; rm -f "$NOPLUGINBIN/session-manager-plugin"

# Assert the functions under test are DEFINED before asserting on their output:
# most doctor rows below are "this line appears", which a suite that loaded
# nothing would also fail, but the helper rows are "this prints X", which an
# undefined function fails with a shell error that reads like a wrong verdict.
for fn in dev-link-doctor _devlink_root _devlink_identity_verdict _devlink_key_verdict _devlink_ping_verdict; do
  zsh -c "source '$SYSTEMSH' >/dev/null 2>&1; (( \$+functions[$fn] ))" \
    || fatal "$fn is not defined after sourcing $SYSTEMSH — the suite would assert nothing"
done

zf() {   # zf <function> <args...> -> stdout of the zsh helper, sourced fresh
  local fn="$1"; shift
  local -a q=(); local a
  for a in "$@"; do q+=("'${a//\'/\'\\\'\'}'"); done
  zsh -c "source '$SYSTEMSH' >/dev/null 2>&1; $fn ${q[*]}" 2>&1
}

# =============================================================================
section "F. verdict helpers: pure functions of their arguments"
check "identity: the expected user is ok" "$(zf _devlink_identity_verdict user/cilantro-dev-ssm cilantro-dev-ssm)" ok
check "identity: another user is mismatch" "$(zf _devlink_identity_verdict user/AdminZvi cilantro-dev-ssm)" mismatch
check "identity: an assumed role is mismatch too, never ok by accident" "$(zf _devlink_identity_verdict assumed-role/Deploy/s cilantro-dev-ssm)" mismatch
check "identity: no expected user is unpinned, not ok" "$(zf _devlink_identity_verdict user/cilantro-dev-ssm '')" unpinned
check "identity: an empty principal is unreadable" "$(zf _devlink_identity_verdict '' cilantro-dev-ssm)" unreadable
check "key: ours, one active, 10 days: ok" "$(zf _devlink_key_verdict ok 1 1 10)" ok
check "key: 90 days is aging" "$(zf _devlink_key_verdict ok 1 1 90)" aging
check "key: 89 days is still ok" "$(zf _devlink_key_verdict ok 1 1 89)" ok
check "key: 180 days is old" "$(zf _devlink_key_verdict ok 1 1 180)" old
check "key: denied is unknown, never ok" "$(zf _devlink_key_verdict denied '' '' '')" unknown
check "key: a failed read is unknown" "$(zf _devlink_key_verdict fail '' '' '')" unknown
check "key: zero matches is not-ours, whatever the age" "$(zf _devlink_key_verdict ok 0 1 10)" not-ours
check "key: two active keys outrank age" "$(zf _devlink_key_verdict ok 1 2 200)" two-keys
check "key: an unparseable age is unknown" "$(zf _devlink_key_verdict ok 1 1 '')" unknown
check "ping: Online is online" "$(zf _devlink_ping_verdict Online)" online
check "ping: ConnectionLost is offline" "$(zf _devlink_ping_verdict ConnectionLost)" offline
check "ping: Inactive is offline" "$(zf _devlink_ping_verdict Inactive)" offline
check "ping: unregistered stays unregistered" "$(zf _devlink_ping_verdict unregistered)" unregistered
check "ping: denied stays denied" "$(zf _devlink_ping_verdict denied)" denied
check "ping: fail stays fail" "$(zf _devlink_ping_verdict fail)" fail
check "ping: an empty status is unregistered, not online" "$(zf _devlink_ping_verdict '')" unregistered

# =============================================================================
section "G. dev-link-doctor: the verdicts a human reads"
run_doctor() {   # run_doctor <args...> -> OUT, RC; the probe script is THIS checkout's
  local base="${DOCTOR_BIN:-$STUBBIN}"
  : > "$STUB_LOG"
  local -a pin=()
  if [[ -n "${PIN_USER-x}" ]]; then pin=("DEV_LINK_AWS_USER=${PIN_USER-cilantro-dev-ssm}"); fi
  OUT="$(env -i PATH="$base:$SYSBIN" HOME="$FHOME" DOTFILES_ROOT="$DOTFILES" DEV_LINK_ROOT="$DOTFILES" \
           DEV_LINK_PROBE="$PROBE" "${pin[@]}" STUB_LOG="$STUB_LOG" \
           STUB_SSH_G_FILE="${STUB_SSH_G_FILE:-$G_SSM}" STUB_SSH_G_RC="${STUB_SSH_G_RC:-}" \
           STUB_SSH_RC="${STUB_SSH_RC:-0}" STUB_SSH_STDERR="${STUB_SSH_STDERR:-}" STUB_SSH_SLEEP="${STUB_SSH_SLEEP:-0}" \
           STUB_SSH_MASTER_RC="${STUB_SSH_MASTER_RC:-255}" \
           STUB_AWS_STS_RC="${STUB_AWS_STS_RC:-0}" STUB_AWS_STS_ERR="${STUB_AWS_STS_ERR:-}" STUB_AWS_ARN="${STUB_AWS_ARN:-}" \
           STUB_AWS_SSM_MODE="${STUB_AWS_SSM_MODE:-online}" STUB_AWS_KEYS_MODE="${STUB_AWS_KEYS_MODE:-ours}" \
           STUB_KEY_ID="${STUB_KEY_ID:-AKIASTUBSTUBSTUBSTUB}" STUB_KEY_DATE="${STUB_KEY_DATE:-2026-10-18T00:00:00+00:00}" \
           STUB_AGENT_RC="${STUB_AGENT_RC:-0}" STUB_AGENT_SLEEP="${STUB_AGENT_SLEEP:-0}" \
           STUB_UNIT_LOAD="${STUB_UNIT_LOAD:-loaded}" STUB_UNIT_ENABLED="${STUB_UNIT_ENABLED:-enabled}" \
           STUB_UNIT_ACTIVE="${STUB_UNIT_ACTIVE:-active}" STUB_UNIT_RESULT="${STUB_UNIT_RESULT:-success}" \
           STUB_IP_LINK="${STUB_IP_LINK:-[]}" STUB_IP_ROUTES="${STUB_IP_ROUTES:-}" \
           DEV_LINK_NOW="${DEV_LINK_NOW:-1793145600}" DEV_LINK_SSH_TIMEOUT="${DEV_LINK_SSH_TIMEOUT:-40}" \
           DEV_LINK_AWS_TIMEOUT="${DEV_LINK_AWS_TIMEOUT:-15}" DEV_LINK_REDACTOR="$HERE/redact-secrets.sh" \
           XDG_RUNTIME_DIR="$TMPROOT/run" XDG_STATE_HOME="$FHOME/.local/state" \
           zsh -c "source '$SYSTEMSH' >/dev/null 2>&1; dev-link-doctor $*" 2>&1)"; RC=$?
}
mkdir -p "$TMPROOT/run" "$FHOME/.local/state"

run_doctor
want_rc   "doctor: a healthy link exits 0" 0
want_out  "doctor: row 1, the tools" "✓ aws and session-manager-plugin are on PATH"
want_out  "doctor: row 2, the ProxyCommand and its pinned profile" "✓ ssh dev goes over aws ssm start-session with --profile dev-ssm"
want_out  "doctor: row 3, the identity, as user/<name>" "✓ profile dev-ssm is user/cilantro-dev-ssm"
want_out  "doctor: row 4, the key age" "✓ the profile's access key is 10 days old"
want_out  "doctor: row 5, dev's SSM registration" "✓ dev (i-0c97f437d3da87e51) is registered with SSM: Online"
want_out  "doctor: row 6, the credential file's permissions" "✓ ~/.aws is mode 700 and credentials is mode 600"
want_out  "doctor: row 7, the ssh agent" "✓ the ssh agent answers"
want_out  "doctor: row 8, a FRESH ssh, timed" "✓ fresh ssh to dev succeeded in "
want_out  "doctor: row 9, the mux, as information" "· no control master is open for dev"
want_out  "doctor: row 10, the VPN, as information only" "· VPN tunnel: DOWN (irrelevant to SSM)"
want_out  "doctor: row 11, the probe timer" "✓ dev-link-probe.timer is active"
want_out  "doctor: the summary" "✓ dev link is healthy."
no_out    "doctor: the account id never appears" "123456789012"
no_out    "doctor: no key id appears" "AKIASTUBSTUBSTUBSTUB"
check "doctor: row 8 used the script's fresh-ssh probe, not an ssh of its own" "$(grep -c -- '-o ControlPath=none' "$STUB_LOG")" 1
check "doctor: ...and the identity probe pinned the profile" "$(grep -c -- '--profile dev-ssm sts get-caller-identity' "$STUB_LOG")" 1
# The row that compared grep -n's order with its sorted order was hollow: grep -n
# prints in file order, so the two lists were always equal (mutant M13, which
# moved the agent block after the ssh block, survived it). Compare the two line
# NUMBERS instead.
agent_line="$(grep -nF 'the ssh agent answers' <<<"$OUT" | cut -d: -f1 | head -1)"
ssh_line="$(grep -nF 'fresh ssh to dev' <<<"$OUT" | cut -d: -f1 | head -1)"
check "doctor: the agent is asked BEFORE the fresh ssh (a locked vault must not read as a credential fault)" \
  "$([[ -n "$agent_line" && -n "$ssh_line" ]] && (( agent_line < ssh_line )) && echo before || echo "agent@${agent_line:-none} ssh@${ssh_line:-none}")" before

STUB_AWS_ARN='arn:aws:iam::123456789012:user/AdminZvi' run_doctor
want_rc   "doctor: the WRONG identity fails" 1
want_out  "doctor: ...named, with both names, no account id" "✗ profile dev-ssm is user/AdminZvi, expected user/cilantro-dev-ssm"
want_out  "doctor: ...and it is the only failure" "✗ 1 failure(s), 0 warning(s)"
PIN_USER='' run_doctor
want_rc   "doctor: an unpinned identity is a warning, not a pass" 0
want_out  "doctor: ...saying what to set" "⚠ profile dev-ssm is user/cilantro-dev-ssm — set DEV_LINK_AWS_USER in ~/.zshrc.local to pin it"
want_out  "doctor: ...counted as a warning" "⚠ 1 warning(s)"
STUB_AWS_STS_RC=255 run_doctor
want_out  "doctor: a profile that resolves no identity fails, with the CLI's reason" "✗ profile dev-ssm resolves no identity: Unable to locate credentials"
no_out    "doctor: ...and the rows that need an identity are not asked (no ✓ key age)" "✓ the profile's access key"

STUB_AWS_KEYS_MODE=denied run_doctor
want_out  "doctor: a denied key-age read is UNVERIFIED, never a tick" "⚠ the key's age is UNVERIFIED (iam:ListAccessKeys denied)"
no_out    "doctor: ...no ✓ on the key row" "✓ the profile's access key"
STUB_AWS_KEYS_MODE=other run_doctor
want_out  "doctor: a key that is not this user's is the pin being wrong" "✗ the profile's access key is not among user/cilantro-dev-ssm's keys"
STUB_AWS_KEYS_MODE=two run_doctor
want_out  "doctor: two active keys is a warning (rotation in progress?)" "⚠ user/cilantro-dev-ssm has 2 active access keys"
STUB_KEY_DATE='2026-07-20T00:00:00+00:00' run_doctor
want_out  "doctor: a 100-day key warns" "⚠ the profile's access key is 100 days old — rotate it before 180"
STUB_KEY_DATE='2026-04-11T00:00:00+00:00' run_doctor
want_out  "doctor: a 200-day key fails" "✗ the profile's access key is 200 days old — rotate it"

STUB_AWS_SSM_MODE=lost run_doctor
want_out  "doctor: an SSM agent that is not Online fails, with the status" "✗ dev's SSM agent is ConnectionLost — is the instance stopped?"
STUB_AWS_SSM_MODE=empty run_doctor
want_out  "doctor: an unregistered instance fails" "✗ dev (i-0c97f437d3da87e51) is not registered with SSM"
STUB_AWS_SSM_MODE=denied run_doctor
want_out  "doctor: a denied registration read is UNVERIFIED" "⚠ dev's SSM registration is UNVERIFIED (ssm:DescribeInstanceInformation denied)"

chmod 775 "$FHOME/.aws"; run_doctor; chmod 700 "$FHOME/.aws"
want_out  "doctor: a group-writable ~/.aws fails (anyone in the group can replace the key)" "✗ ~/.aws is mode 775 — chmod 700"
chmod 644 "$FHOME/.aws/credentials"; run_doctor; chmod 600 "$FHOME/.aws/credentials"
want_out  "doctor: world-readable credentials fail" "✗ ~/.aws/credentials is mode 644 — chmod 600"

STUB_AGENT_RC=2 run_doctor
want_out  "doctor: an agent that does not answer names the vault" "✗ the ssh agent did not answer — unlock the Bitwarden vault"
STUB_AGENT_SLEEP=3 run_doctor
want_out  "doctor: an agent that HANGS is the same failure, bounded at 2 s" "✗ the ssh agent did not answer"
STUB_AGENT_RC=1 run_doctor
want_out  "doctor: an agent with no keys" "✗ the ssh agent has no keys (ssh-add -l)"

STUB_SSH_RC=255 STUB_SSH_STDERR='Connection closed by UNKNOWN port 65535' run_doctor
want_rc   "doctor: a dead link fails" 1
want_out  "doctor: ...and the cause is the ProxyCommand" "✗ fresh ssh to dev FAILED: the ProxyCommand (SSM) failed — Connection closed by UNKNOWN port 65535"
STUB_SSH_RC=255 STUB_SSH_STDERR='ubuntu@dev: Permission denied (publickey).' run_doctor
want_out  "doctor: ...or the key" "✗ fresh ssh to dev FAILED: the agent or key was refused — "
DEV_LINK_SSH_TIMEOUT=1 STUB_SSH_SLEEP=3 run_doctor
want_out  "doctor: ...or a hang, which is a failure and not a hang" "✗ fresh ssh to dev FAILED: timed out after 1 s"
STUB_SSH_MASTER_RC=0 run_doctor
want_out  "doctor: an open master is named: it hides a dead credential" "· a control master is open for dev: plain ssh answers from it for up to 10 min after the credential dies"

run_doctor --offline
want_rc   "doctor --offline: exits 0 with the local rows green" 0
check "doctor --offline: no aws call" "$(grep -c '^aws ' "$STUB_LOG")" 0
check "doctor --offline: no fresh ssh" "$(grep -c -- 'ControlPath=none' "$STUB_LOG")" 0
want_out  "doctor --offline: the skipped rows say so" "· identity, key age, SSM registration and the fresh ssh skipped (--offline)"
no_out    "doctor --offline: ...and never claim ✓" "✓ profile dev-ssm is"

STUB_SSH_G_FILE="$G_NONE" run_doctor
want_out  "doctor: a dev that is not over SSM says so, and the credential rows do not apply" "⚠ ssh dev is not an SSM ProxyCommand (proxy=none) — the credential rows do not apply"
check "doctor: ...and asks aws nothing" "$(grep -c '^aws ' "$STUB_LOG")" 0
STUB_SSH_G_FILE="$G_SSM_NOPROF" run_doctor
want_out  "doctor: no --profile is the 12-hour trap, named" "⚠ the ProxyCommand pins no --profile: the default profile is an aws login session, capped at 12 h by AWS"
STUB_SSH_G_RC=255 run_doctor
want_out  "doctor: an unreadable ssh config fails the resolve row" "✗ ssh -G dev failed"

DOCTOR_BIN="$NOPLUGINBIN" run_doctor --offline
want_out  "doctor: a missing session-manager-plugin fails row 1" "✗ session-manager-plugin is not on PATH"

STUB_UNIT_LOAD=not-found run_doctor
want_out  "doctor: a probe timer that is not linked" "⚠ dev-link-probe.timer is not linked — run ./install"
STUB_UNIT_ENABLED=disabled run_doctor
want_out  "doctor: linked but not enabled is a decision, spelled out" "· dev-link-probe.timer linked, not enabled — arming it is a decision:"
STUB_UNIT_ACTIVE=inactive run_doctor
want_out  "doctor: enabled but not active fails" "✗ dev-link-probe.timer is enabled but inactive"
STUB_UNIT_RESULT=exit-code run_doctor
want_out  "doctor: a probe service whose last run failed" "✗ the last dev-link-probe run ended with exit-code"

# Counter leak: the emitters count into dynamically scoped locals, so a doctor
# that forgets to declare them would count into the caller's shell.
check "doctor: _DOCTOR_FAIL does not leak into the caller" \
  "$(env -i PATH="$STUBBIN:$SYSBIN" HOME="$FHOME" DOTFILES_ROOT="$DOTFILES" DEV_LINK_ROOT="$DOTFILES" DEV_LINK_PROBE="$PROBE" STUB_LOG="$STUB_LOG" STUB_SSH_G_FILE="$G_SSM" STUB_SSH_RC=255 STUB_KEY_ID=AKIASTUBSTUBSTUBSTUB STUB_KEY_DATE=2026-10-18T00:00:00+00:00 DEV_LINK_NOW=1793145600 DEV_LINK_REDACTOR="$HERE/redact-secrets.sh" XDG_RUNTIME_DIR="$TMPROOT/run" \
       zsh -c "source '$SYSTEMSH' >/dev/null 2>&1; _DOCTOR_FAIL=7; dev-link-doctor >/dev/null 2>&1; echo \$_DOCTOR_FAIL")" 7
check "doctor: _DOCTOR_WARN does not leak into the caller" \
  "$(env -i PATH="$STUBBIN:$SYSBIN" HOME="$FHOME" DOTFILES_ROOT="$DOTFILES" DEV_LINK_ROOT="$DOTFILES" DEV_LINK_PROBE="$PROBE" STUB_LOG="$STUB_LOG" STUB_SSH_G_FILE="$G_SSM_NOPROF" STUB_KEY_ID=AKIASTUBSTUBSTUBSTUB STUB_KEY_DATE=2026-10-18T00:00:00+00:00 DEV_LINK_NOW=1793145600 DEV_LINK_REDACTOR="$HERE/redact-secrets.sh" XDG_RUNTIME_DIR="$TMPROOT/run" \
       zsh -c "source '$SYSTEMSH' >/dev/null 2>&1; _DOCTOR_WARN=5; dev-link-doctor >/dev/null 2>&1; echo \$_DOCTOR_WARN")" 5

EXPECTED_ROWS=168

# --- the count this suite is documented as running ---------------------------
# Same needle as the other suites: docs/REPO_CHECKS.md, "Where a check count lives".
docs_claim() {
  local f="$HERE/../$1"
  [[ -r "$f" ]] || { printf 'cannot read %s' "$1"; return; }
  tr -s '[:space:]' ' ' <"$f" \
    | grep -c -F "\`scripts/test-dev-link.sh\` ($EXPECTED_ROWS checks"
}
section "the count this suite is documented as running"
check "docs/DEV_LINK.md says $EXPECTED_ROWS checks" "$(docs_claim docs/DEV_LINK.md)" 1
check "a documented file that cannot be read is not a pass" \
      "$(docs_claim no/such/file.md)" "cannot read no/such/file.md"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( PASS + FAIL != EXPECTED_ROWS )); then
  printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
    "$EXPECTED_ROWS" "$((PASS + FAIL))"
  FAIL=$((FAIL + 1))
fi
(( FAIL == 0 ))
