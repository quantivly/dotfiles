#!/usr/bin/env bash
#
# scripts/dev-link-probe.sh
# =========================
#
# The probes behind `dev-link-doctor` and the dev-link-probe timer: is the
# laptop's path to dev (ssh over an AWS SSM ProxyCommand) alive RIGHT NOW, and
# if not, which of its three dependencies failed -- the AWS credential, the SSH
# agent and key, or the network and dev itself?
#
# Why this exists
# ---------------
# `ssh dev` goes over `aws ssm start-session`. Until 2026-10 the AWS profile
# behind that command was an `aws login` console session, which AWS caps at
# 12 hours, so twice a day every new connection died with "Connection closed by
# UNKNOWN port 65535" and nothing said why: ControlPersist answered interactive
# shells from an open master for ten more minutes, and rabota's census wrote
# "unreachable" with ssh's generic text. The record is docs/DEV_LINK.md.
#
# ONE DEFINITION OF EACH PROBE
# ----------------------------
# The doctor (zsh) and the timer (this script, --once) must agree on what a
# fresh connection is and what a dead credential looks like, so both call the
# modes below rather than carrying their own copy. The ssh argv in mode_ssh is
# the only place it is written.
#
# Everything printed is key=value lines. External text (the CLI's stderr, ssh's
# stderr) passes through scripts/redact-secrets.sh first, and the identity is
# printed as `user/<name>` -- never the ARN, which carries the account id.
#
# Usage:
#   dev-link-probe.sh --resolve [HOST]          what `ssh -G HOST` says: proxy=, profile=, instance=, hostkeyalias=
#   dev-link-probe.sh --api PROFILE [INSTANCE]  identity= / principal= from sts, then ping= from SSM
#   dev-link-probe.sh --keys PROFILE            keys= matches= active= age_days= of the profile's own key
#   dev-link-probe.sh --ssh [HOST]              one FRESH ssh (no mux): ssh= ms= [rc= cause= detail=]
#   dev-link-probe.sh --once [HOST]             resolve, api, ssh; one TSV line for the probe log
#   dev-link-probe.sh --help
#
# Exit codes
#   0  the probe ran (dev's state is in the OUTPUT, never the exit code: a
#      timer-activated oneshot that exits non-zero when dev is down would make
#      check-timer-health.sh report the timer itself as broken)
#   2  COULD NOT RUN -- a missing tool, an unreadable ssh config, a bad argument
#
# Seams (what makes the state table hermetic):
#   DEV_LINK_AWS_TIMEOUT  default 15   seconds per aws call
#   DEV_LINK_SSH_TIMEOUT  default 40   seconds for the whole fresh ssh, banner included
#   DEV_LINK_NOW          epoch seconds to use as "now" (the --once line, key age)
#   DEV_LINK_REDACTOR     path to redact-secrets.sh (default: next to this script)

set -uo pipefail

HOST_DEFAULT="dev"
AWS_TIMEOUT="${DEV_LINK_AWS_TIMEOUT:-15}"
SSH_TIMEOUT="${DEV_LINK_SSH_TIMEOUT:-40}"
# ConnectTimeout covers connect plus banner on current OpenSSH; the outer
# `timeout` covers the aws CLI stalling BEFORE it (DNS, STS) and the plugin's
# data channel stalling AFTER it, which ConnectTimeout cannot see.
SSH_CONNECT_TIMEOUT=20
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REDACTOR="${DEV_LINK_REDACTOR:-$HERE/redact-secrets.sh}"
SECONDS_PER_DAY=86400

err() { printf 'dev-link-probe: %s\n' "$*" >&2; }

for _v in AWS_TIMEOUT SSH_TIMEOUT; do
    if [[ ! "${!_v}" =~ ^[0-9]+$ ]] || (( ${!_v} < 1 )); then
        err "DEV_LINK_${_v} must be a positive integer, got '${!_v}'"
        exit 2
    fi
done

# One name per call: `command -v a b` is a silent pass in bash with b missing.
need() { command -v "$1" >/dev/null 2>&1 || { err "$1 not found on PATH; cannot run"; exit 2; }; }

now() { printf '%s\n' "${DEV_LINK_NOW:-$(date +%s)}"; }
# Milliseconds for latency only. uutils date ignores %3N, so take %N and slice.
now_ms() {
    local raw
    raw="$(date +%s%N 2>/dev/null)"
    if [[ "$raw" =~ ^[0-9]{19}$ ]]; then printf '%s\n' "${raw:0:13}"; else printf '%s000\n' "$(date +%s)"; fi
}

# External text is redacted before it is printed; a missing redactor is a
# could-not-run, not a reason to print the text raw.
redact_line() {
    [[ -x "$REDACTOR" ]] || { err "redactor not found at $REDACTOR; cannot print external text"; exit 2; }
    printf '%s\n' "$1" | "$REDACTOR" 2>/dev/null | head -1
}

# The --profile the ProxyCommand pins, in either spelling, or empty.
proxy_profile() {
    local word prev=""
    for word in $1; do
        if [[ "$prev" == "--profile" ]]; then printf '%s\n' "$word"; return 0; fi
        if [[ "$word" == --profile=* ]]; then printf '%s\n' "${word#--profile=}"; return 0; fi
        prev="$word"
    done
    printf '\n'
}

# Which of the link's dependencies an ssh failure names.
ssh_cause() {
    local rc="$1" text="$2"
    if (( rc == 124 )); then printf 'timeout\n'
    elif [[ "$text" == *"UNKNOWN port 65535"* || "$text" == *"kex_exchange_identification"* ]]; then printf 'proxy\n'
    elif [[ "$text" == *"Permission denied (publickey"* ]]; then printf 'auth\n'
    else printf 'network\n'
    fi
}

mode_resolve() {
    local host="$1" cfg hostname alias pc proxy profile="" instance=""
    need ssh
    cfg="$(ssh -G "$host" 2>/dev/null)" || { err "ssh -G $host failed; cannot read the ssh config"; return 2; }
    hostname="$(awk '$1=="hostname"{print $2; exit}' <<<"$cfg")"
    alias="$(awk '$1=="hostkeyalias"{print $2; exit}' <<<"$cfg")"
    pc="$(awk '$1=="proxycommand"{$1=""; sub(/^ /,""); print; exit}' <<<"$cfg")"
    if [[ -z "$pc" || "$pc" == "none" ]]; then
        proxy="none"
    elif [[ "$pc" == *"aws "*"ssm start-session"* ]]; then
        proxy="ssm"; profile="$(proxy_profile "$pc")"
    else
        proxy="other"
    fi
    [[ "$hostname" =~ ^i-[0-9a-f]{8,17}$ ]] && instance="$hostname"
    printf 'proxy=%s\nprofile=%s\ninstance=%s\nhostname=%s\nhostkeyalias=%s\n' \
        "$proxy" "$profile" "$instance" "$hostname" "$alias"
}

# aws with the profile pinned (an explicit --profile also makes botocore ignore
# AWS_ACCESS_KEY_ID / AWS_PROFILE from the environment) and IMDS disabled, so a
# missing profile fails in milliseconds instead of stalling on 169.254.169.254.
aws_call() {
    local profile="$1"; shift
    local -a pin=()
    [[ -n "$profile" ]] && pin=(--profile "$profile")
    AWS_EC2_METADATA_DISABLED=true timeout "$AWS_TIMEOUT" aws "${pin[@]}" "$@" --output json --no-cli-pager
}

mode_api() {
    local profile="$1" instance="${2:-}" errf out rc arn status
    need aws; need jq
    errf="$(mktemp)"
    out="$(aws_call "$profile" sts get-caller-identity 2>"$errf")"; rc=$?
    if (( rc != 0 )); then
        local reason; reason="$(head -1 "$errf")"
        (( rc == 124 )) && [[ -z "$reason" ]] && reason="timed out after ${AWS_TIMEOUT}s"
        printf 'identity=fail\nreason=%s\n' "$(redact_line "$reason")"
        rm -f "$errf"; return 0
    fi
    arn="$(jq -r '.Arn // empty' <<<"$out")"
    # Everything after the last colon: user/<name> or assumed-role/<role>/<session>.
    # The account id lives before it and is never printed.
    printf 'identity=ok\nprincipal=%s\n' "${arn##*:}"
    if [[ -n "$instance" ]]; then
        out="$(aws_call "$profile" ssm describe-instance-information --filters "Key=InstanceIds,Values=$instance" 2>"$errf")"; rc=$?
        if (( rc != 0 )); then
            if grep -q 'AccessDenied' "$errf"; then
                printf 'ping=denied\n'
            else
                printf 'ping=fail\nreason=%s\n' "$(redact_line "$(head -1 "$errf")")"
            fi
        else
            status="$(jq -r '.InstanceInformationList[0].PingStatus // empty' <<<"$out")"
            printf 'ping=%s\n' "${status:-unregistered}"
        fi
    fi
    rm -f "$errf"
    return 0
}

mode_keys() {
    local profile="$1" ourid errf out rc matches active created age=""
    need aws; need jq
    # Read in-shell, compared in jq, never printed.
    ourid="$(aws configure get aws_access_key_id --profile "$profile" 2>/dev/null)"
    if [[ -z "$ourid" ]]; then
        printf 'keys=fail\nreason=profile %s has no aws_access_key_id\n' "$profile"; return 0
    fi
    errf="$(mktemp)"
    out="$(aws_call "$profile" iam list-access-keys 2>"$errf")"; rc=$?
    if (( rc != 0 )); then
        if grep -q 'AccessDenied' "$errf"; then
            printf 'keys=denied\n'
        else
            printf 'keys=fail\nreason=%s\n' "$(redact_line "$(head -1 "$errf")")"
        fi
        rm -f "$errf"; return 0
    fi
    rm -f "$errf"
    matches="$(jq --arg id "$ourid" '[.AccessKeyMetadata[] | select(.AccessKeyId == $id)] | length' <<<"$out")"
    active="$(jq '[.AccessKeyMetadata[] | select(.Status == "Active")] | length' <<<"$out")"
    created="$(jq -r --arg id "$ourid" '[.AccessKeyMetadata[] | select(.AccessKeyId == $id) | .CreateDate][0] // empty' <<<"$out")"
    if [[ -n "$created" ]]; then
        local epoch
        if epoch="$(date -d "$created" +%s 2>/dev/null)"; then
            age=$(( ( $(now) - epoch ) / SECONDS_PER_DAY ))
        fi
    fi
    printf 'keys=ok\nmatches=%s\nactive=%s\nage_days=%s\n' "$matches" "$active" "$age"
}

mode_ssh() {
    local host="$1" errf rc t0 t1 ms cause detail
    need ssh; need timeout
    errf="$(mktemp)"
    t0="$(now_ms)"
    # THE fresh connection. ControlMaster=no + ControlPath=none: never answered
    # by a master that outlived its credential. BatchMode=yes: never a prompt.
    timeout "$SSH_TIMEOUT" ssh -o ControlMaster=no -o ControlPath=none -o BatchMode=yes \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" -- "$host" true >/dev/null 2>"$errf"; rc=$?
    t1="$(now_ms)"
    ms=$(( t1 - t0 ))
    if (( rc == 0 )); then
        printf 'ssh=ok\nms=%s\n' "$ms"; rm -f "$errf"; return 0
    fi
    cause="$(ssh_cause "$rc" "$(cat "$errf")")"
    detail="$(grep -v '^$' "$errf" | tail -1)"
    rm -f "$errf"
    printf 'ssh=fail\nrc=%s\ncause=%s\nms=%s\ndetail=%s\n' "$rc" "$cause" "$ms" "$(redact_line "$detail")"
    return 0
}

field() { awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' <<<"$2"; }

mode_once() {
    local host="$1" res proxy profile instance api="skipped" ssh="skipped" ms="" cause="ok" detail="" out
    need aws; need ssh; need jq
    res="$(mode_resolve "$host")" || return 2
    proxy="$(field proxy "$res")"; profile="$(field profile "$res")"; instance="$(field instance "$res")"
    if [[ "$proxy" == "ssm" ]]; then
        out="$(mode_api "$profile" "$instance")" || return 2
        if [[ "$(field identity "$out")" == "ok" ]]; then
            api="ok"
        else
            api="fail"; cause="credential"; detail="$(field reason "$out")"
        fi
    fi
    if [[ "$api" != "fail" ]]; then
        out="$(mode_ssh "$host")" || return 2
        ssh="$(field ssh "$out")"; ms="$(field ms "$out")"
        if [[ "$ssh" != "ok" ]]; then
            cause="$(field cause "$out")"; detail="$(field detail "$out")"
        fi
    fi
    printf '%s\tapi=%s\tssh=%s\tms=%s\tcause=%s\tdetail=%s\n' "$(now)" "$api" "$ssh" "$ms" "$cause" "$detail"
    return 0
}

usage() {
    awk 'NR < 3 { next } /^#/ { sub(/^#[[:space:]]?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

main() {
    case "${1:-}" in
        --resolve) mode_resolve "${2:-$HOST_DEFAULT}"; exit $? ;;
        --api)     [[ $# -ge 2 ]] || { err "--api needs a PROFILE (may be empty) and an optional INSTANCE"; exit 2; }
                   mode_api "$2" "${3:-}"; exit $? ;;
        --keys)    [[ $# -ge 2 && -n "$2" ]] || { err "--keys needs a PROFILE"; exit 2; }
                   mode_keys "$2"; exit $? ;;
        --ssh)     mode_ssh "${2:-$HOST_DEFAULT}"; exit $? ;;
        --once)    mode_once "${2:-$HOST_DEFAULT}"; exit $? ;;
        --help|-h) usage; exit 0 ;;
        *)         err "unknown mode: ${1:-<none>}"; usage >&2; exit 2 ;;
    esac
}

main "$@"
