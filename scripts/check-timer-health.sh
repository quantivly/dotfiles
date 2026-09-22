#!/usr/bin/env bash
#
# scripts/check-timer-health.sh
# =============================
#
# Assert that the systemd USER units this checkout owns are actually RUNNING —
# not merely enabled, and not merely un-failed.
#
# Why this exists
# ---------------
# Enablement was already checked (scripts/reconcile-systemd-units.sh --check,
# wired into scripts/verify-tools.sh). Nothing checked whether an enabled unit
# ever ran, or what happened when it did. On 2026-09-22 a grep for
# `state=failed|--failed|is-failed` across scripts/ and zsh/ returned exactly one
# line — backup-doctor's, scoped to `*restic*` and to the SYSTEM manager. So a
# claude-cred-reconcile, rabota-precompute@ or wt-gc-sweep that started failing
# every night sat failed indefinitely, visible only to someone who happened to
# type `systemctl --user --state=failed`.
#
# That became urgent the same day: wt-gc-sweep.timer was armed (DO-677), and it
# DELETES worktrees and local branches unattended at 04:00. Its wrapper was built
# so that only a real FAILED row exits non-zero — a deliberately loud failure,
# armed into a system with nothing listening.
#
# The three questions, each of which can be false while the other two look fine
# -----------------------------------------------------------------------------
#   1. ENABLED      — already answered by reconcile-systemd-units.sh --check.
#                     Not duplicated here; a unit that is linked but not enabled
#                     is a DECISION (wt-gc-sweep ships that way) and is skipped.
#   2. SUCCEEDED    — Result / ExecMainStatus / ActiveState of the last run.
#   3. STILL RUNNING— the timer is firing at all, on its own schedule.
#
# (3) is the one worth the most and the one easiest to get wrong. An unmet
# ConditionPathExists makes systemd SKIP the unit, and a skipped unit is not a
# failed one: no error, nothing in --state=failed, and Result STAYS success.
# wt-gc-sweep.service has exactly such a condition
# (ConditionPathExists=%h/.local/bin/wt-gc, and wt-gc lives in the private
# ~/.dotfiles-local), so this is not hypothetical.
#
# What was measured before any of this was written (2026-09-22, systemd 259)
# -------------------------------------------------------------------------
# Every one of these is a way for this checker to report health it did not
# measure, and every one is a row in scripts/test-timer-health.sh.
#
#   * `systemctl --user show <typo>.service -p Result` exits 0 and prints
#     Result=success, ConditionResult=no, LoadState=not-found. A unit that was
#     renamed away reads as BOTH healthy and skipped. LoadState is therefore
#     tested first, and a not-found unit is a FAIL.
#   * ConditionResult=no is ALSO the value on a loaded unit that has never
#     started. Skip-detection on ConditionResult alone false-fails every freshly
#     enabled timer, so it is gated on ConditionTimestamp being non-empty.
#   * `systemctl --user show 'rabota-precompute@.timer'` ERRORS ("neither a valid
#     invocation ID nor unit name"). dotbot links the bare template, so
#     --list-managed returns it; bare templates are dropped here.
#   * NextElapseUSecRealtime is EMPTY for a monotonic timer (claude-cred-reconcile
#     is OnUnitActiveSec=2min), and NextElapseUSecMonotonic is a pretty duration
#     string ("4h 46min 39.259192s") with no raw companion — unparseable.
#   * `systemctl --user list-timers --all -o json` answers all of it: next/last as
#     epoch MICROSECONDS (last=0 means never fired), the unit, and the service it
#     activates — and it lists only real template INSTANCES. It is the source of
#     truth here. (`--json=short` is not a valid flag on this systemctl; `-o json`
#     is.)
#   * list-timers lists only LOADED timers. A managed timer that is enabled and
#     absent from that list is a real fault, not an absence.
#
# Freshness is DERIVED, never tabulated
# -------------------------------------
#   anchor = last, or the timer's ActiveEnterTimestamp when it has never fired
#   stale  = now > next + (next - anchor)
#
# i.e. one full projected cycle past the next scheduled run. For a 2-minute timer
# that fired at T this is `now > T + 4min`; for wt-gc-sweep, armed 14:32 with its
# first run at 04:11 the next morning, it is ~17:50 the day after. It tunes itself
# from systemd's own schedule, so there is no per-unit table of expected periods
# to drift out of sync with the unit files — which is the same reason
# reconcile-systemd-units.sh derives its unit list instead of hardcoding one.
#
# The HORIZON check is not redundant with it. A mis-specified OnCalendar pushes
# next_elapse years out; the derived cycle is then years wide and the staleness
# test can never fire again. So a next run further away than
# TIMER_HEALTH_MAX_HORIZON_DAYS is its own failure.
#
# Scope: REPO-OWNED USER UNITS ONLY
# ---------------------------------
# Derived from reconcile-systemd-units.sh --list-managed — symlinks in the
# systemd user dir resolving inside the checkout — rather than re-derived here,
# because two definitions of "ours" drift and only that one knows about the
# physical-path trap in its DOTFILES_DIR. This machine also runs nanoclaw-*,
# ubuntu-insights-* and snap.* user timers; this repo has no standing to call
# those broken, and a checker that is red about a unit it cannot fix is the
# permanently-red checker this repo's records warn about three times. The restic
# units are SYSTEM-manager units and belong to backup-doctor.
#
# Usage
# -----
#   check-timer-health.sh            report; exit 1 if a managed unit is unhealthy
#   check-timer-health.sh --check    the same (the name the callers use)
#   check-timer-health.sh --help     this header
#
# EXIT CODE
#   0  everything healthy, or there is nothing here to look at
#   1  a managed unit failed, stalled, or is being silently skipped
#   2  COULD NOT RUN — jq missing, or the ownership list could not be obtained.
#      Never a pass. scripts/verify-tools.sh maps both 1 and 2 to a FAIL.
#
#   Exit 0 when no systemd user manager is reachable is deliberate and matches
#   reconcile-systemd-units.sh: a server, a container and a CI runner all
#   legitimately have none, and a check that fails there is one people learn to
#   ignore. It says "skipped" rather than printing a pass.
#
# Test-suite overrides (also make it hermetic):
#   SYSTEMD_USER_DIR            default ~/.config/systemd/user
#   TIMER_HEALTH_ROOT           skip live-checkout resolution, use this checkout
#   TIMER_HEALTH_RECONCILER     the --list-managed provider, when it is not the
#                               one inside TIMER_HEALTH_ROOT. Exists because this
#                               script and that flag ship together: run from a
#                               worktree against the LIVE units, the deployed
#                               reconciler is the older one and has no
#                               --list-managed, which is correctly an exit 2.
#   TIMER_HEALTH_MAX_HORIZON_DAYS   default 14
#   TIMER_HEALTH_NOW            epoch seconds to use as "now"

set -uo pipefail

SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-${HOME}/.config/systemd/user}"
HORIZON_DAYS="${TIMER_HEALTH_MAX_HORIZON_DAYS:-14}"
# Validated, not trusted: every use of these is inside (( )), where a non-numeric
# value is a silent 0 in bash — a horizon of zero days would fail every unit and
# a "now" of zero would pass every one of them. Either way the checker would be
# answering a question nobody asked. Exit 2, never a pass.
if [[ ! "$HORIZON_DAYS" =~ ^[0-9]+$ ]] || (( HORIZON_DAYS <= 0 )); then
    printf 'check-timer-health: TIMER_HEALTH_MAX_HORIZON_DAYS must be a positive integer, got %s\n' \
        "$HORIZON_DAYS" >&2
    exit 2
fi
if [[ -n "${TIMER_HEALTH_NOW:-}" && ! "${TIMER_HEALTH_NOW}" =~ ^[0-9]+$ ]]; then
    printf 'check-timer-health: TIMER_HEALTH_NOW must be epoch seconds, got %s\n' "$TIMER_HEALTH_NOW" >&2
    exit 2
fi

case "${1:-}" in
    ""|--check) ;;
    --help|-h)
        awk 'NR < 3 { next } /^#/ { sub(/^#[[:space:]]?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
        exit 0 ;;
    *)  printf 'usage: %s [--check]\n' "${0##*/}" >&2; exit 2 ;;
esac

fail=0
note_fail() { fail=1; }

# ---------------------------------------------------------------------------
# Which checkout owns the units systemd actually holds
# ---------------------------------------------------------------------------
# NOT this script's own checkout. `dotfiles-work` makes a worktree the normal
# place to run repo scripts from, and no symlink points into a worktree — so
# deriving the root from BASH_SOURCE makes this vacuous exactly where it is most
# likely to be run, printing "nothing linked — skipped" and exiting 0 while the
# live deployment has a failing unit. scripts/verify-tools.sh hit this exact bug
# in review and resolves from the links for the same reason.
#
# Sets FOUND_LINK=1 when a unit IS linked out of some checkout, whether or not
# that checkout can be asked about it. Without that flag, "units are linked from
# a checkout with no reconciler" printed the same sentence as "nothing is linked
# at all" and exited 0 — an unanswerable question resolving to the answer it
# would have had if everything were fine. verify-tools.sh separates exactly these
# two cases (enable_found_link vs enable_root) after the same bug.
#
# Assigns to the globals FOUND_LINK and LIVE_ROOT rather than printing, because a
# `$(...)` caller is a SUBSHELL and FOUND_LINK set inside one never comes back —
# which is precisely how the state it distinguishes went on reporting an empty
# machine for two more runs of the suite.
FOUND_LINK=0
LIVE_ROOT=""
resolve_live_checkout() {
    local u t cand
    FOUND_LINK=0; LIVE_ROOT=""
    for u in "$SYSTEMD_USER_DIR"/*; do
        [[ -L "$u" ]] || continue
        t="$(readlink -f "$u" 2>/dev/null)" || continue
        [[ "$t" == */systemd/* ]] || continue
        FOUND_LINK=1
        cand="${t%/systemd/*}"
        [[ -x "$cand/scripts/reconcile-systemd-units.sh" ]] || continue
        LIVE_ROOT="$cand"
        return 0
    done
    return 1
}

have_user_manager() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [[ -n "${XDG_RUNTIME_DIR:-}" ]] || return 1
    systemctl --user show-environment >/dev/null 2>&1
}

# A bare template (foo@.service) is not a unit systemd can be asked about — it
# errors out. Its INSTANCES are real and arrive through list-timers.
is_bare_template() { [[ "${1%.*}" == *@ ]]; }

# One `show` per unit, as KEY=value lines, timestamps normalised to @<epoch>.
# --timestamp=unix is what makes LastTriggerUSec and ActiveEnterTimestamp
# comparable without parsing "Tue 2026-09-22 15:13:59 IDT".
unit_props() {
    systemctl --user show --timestamp=unix "$1" \
        -p LoadState -p ActiveState -p UnitFileState -p Result \
        -p ExecMainStatus -p ConditionResult -p ConditionTimestamp \
        -p ActiveEnterTimestamp 2>/dev/null
}
prop() { sed -n "s/^$2=//p" <<<"$1" | head -1; }

# @<epoch> -> seconds. Empty, "0" and a bare "@" all mean "no timestamp", and are
# reported as 0 so callers test one thing.
epoch_of() {
    local v="${1#@}"
    [[ "$v" =~ ^[0-9]+$ ]] || { printf '0\n'; return 0; }
    printf '%s\n' "$v"
}

fmt_time() {
    local s="$1"
    (( s > 0 )) || { printf 'never\n'; return 0; }
    date -d "@$s" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s\n' "$s"
}

fmt_ago() {
    local s="$1" d=$(( NOW - $1 ))
    (( s > 0 )) || { printf 'never\n'; return 0; }
    if   (( d < 0 ));      then printf 'in %dm\n' $(( -d / 60 ))
    elif (( d < 3600 ));   then printf '%dm ago\n' $(( d / 60 ))
    elif (( d < 172800 )); then printf '%dh ago\n' $(( d / 3600 ))
    else                        printf '%dd ago\n' $(( d / 86400 )); fi
}

is_enabled() { [[ "$(systemctl --user is-enabled "$1" 2>/dev/null)" == "enabled" ]]; }

# The ConditionPathExists= (or other Condition*) a skipped unit is being held
# back by, read from the unit file so the message names the actual path rather
# than telling the reader to go and look.
# An INSTANCE of a template has no unit file of its own — dotbot links only
# `foo@.service` — so falling back to the template is what makes this print
# anything at all for rabota-precompute@quantivly.service.
condition_lines() {
    local f="$SYSTEMD_USER_DIR/$1"
    if [[ ! -r "$f" && "$1" == *@*.* ]]; then
        f="$SYSTEMD_USER_DIR/${1%%@*}@.${1##*.}"
    fi
    [[ -r "$f" ]] || return 0
    grep -hE '^[[:space:]]*(Condition|Assert)[A-Za-z]+=' "$f" 2>/dev/null | sed 's/^[[:space:]]*//'
}

# ---------------------------------------------------------------------------
# The three assertions
# ---------------------------------------------------------------------------

# Everything about the SERVICE a timer activates (or a standalone oneshot).
# LoadState is tested FIRST and on its own: a not-found unit answers `success` to
# every other question asked of it.
check_service() {
    local svc="$1" why="$2" props load active result status cres cts line
    props="$(unit_props "$svc")"
    load="$(prop "$props" LoadState)"
    if [[ "$load" != "loaded" ]]; then
        note_fail
        printf '  ✗ %s: LoadState=%s — %s names a unit systemd cannot load.\n' "$svc" "${load:-unknown}" "$why"
        printf '      A renamed or deleted unit still answers Result=success to every\n'
        printf '      question, so this is checked first. Fix: ./install, then\n'
        printf '      systemctl --user daemon-reload\n'
        return 1
    fi

    active="$(prop "$props" ActiveState)"
    result="$(prop "$props" Result)"
    status="$(prop "$props" ExecMainStatus)"
    if [[ "$active" == "failed" || ( -n "$result" && "$result" != "success" ) || ( -n "$status" && "$status" != "0" ) ]]; then
        note_fail
        printf '  ✗ %s: last run FAILED (ActiveState=%s Result=%s ExecMainStatus=%s)\n' \
               "$svc" "${active:-?}" "${result:-?}" "${status:-?}"
        printf '      journalctl --user -u %s -e\n' "$svc"
        return 1
    fi

    # The silent one. ConditionResult=no with a ConditionTimestamp means systemd
    # reached this unit and declined to run it — no error, no failed state, and
    # Result still `success`. Only meaningful once it has been reached at least
    # once, which is what the timestamp gate is for.
    cres="$(prop "$props" ConditionResult)"
    cts="$(epoch_of "$(prop "$props" ConditionTimestamp)")"
    if [[ "$cres" == "no" ]] && (( cts > 0 )); then
        note_fail
        printf '  ✗ %s: armed but SKIPPED since %s — a condition stopped matching.\n' "$svc" "$(fmt_time "$cts")"
        while IFS= read -r line; do
            [[ -n "$line" ]] && printf '      %s\n' "$line"
        done < <(condition_lines "$svc")
        printf '      A skipped unit is NOT a failed one: no error, nothing in\n'
        printf '      --state=failed, Result=success. journalctl --user -u %s -e\n' "$svc"
        return 1
    fi
    return 0
}

check_timer() {
    local unit="$1" next_us="$2" last_us="$3" svc="$4"
    local props active next last anchor cycle limit

    props="$(unit_props "$unit")"
    active="$(prop "$props" ActiveState)"
    if [[ "$active" != "active" ]]; then
        note_fail
        printf '  ✗ %s: enabled but ActiveState=%s — it will not fire.\n' "$unit" "${active:-unknown}"
        printf '      systemctl --user status %s\n' "$unit"
        return 0
    fi

    next=$(( next_us / 1000000 ))
    last=$(( last_us / 1000000 ))

    if (( next <= 0 )); then
        note_fail
        printf '  ✗ %s: active with NO next run scheduled — it has stopped firing.\n' "$unit"
        printf '      systemctl --user list-timers --all %s\n' "$unit"
        return 0
    fi

    if (( next - NOW > HORIZON_DAYS * 86400 )); then
        note_fail
        printf '  ✗ %s: next run is %s, more than %sd away — check its OnCalendar.\n' \
               "$unit" "$(fmt_time "$next")" "$HORIZON_DAYS"
        printf '      A calendar spec that resolves years out leaves an active, healthy-\n'
        printf '      looking timer that never runs, and makes the staleness test below\n'
        printf '      unfireable (its derived cycle becomes years wide).\n'
        return 0
    fi

    # Never fired: anchor on when the TIMER became active, so a freshly armed
    # timer is young rather than infinitely stale. wt-gc-sweep.timer was in
    # exactly this state on the day this was written.
    anchor="$last"
    if (( anchor <= 0 )); then
        anchor="$(epoch_of "$(prop "$props" ActiveEnterTimestamp)")"
    fi
    if (( anchor > 0 && anchor < next )); then
        cycle=$(( next - anchor ))
        limit=$(( next + cycle ))
        if (( NOW > limit )); then
            note_fail
            printf '  ✗ %s: STALE — last run %s, next was due %s.\n' \
                   "$unit" "$(fmt_ago "$last")" "$(fmt_time "$next")"
            printf '      More than one full cycle (%dm) past its own schedule.\n' $(( cycle / 60 ))
            printf '      systemctl --user list-timers --all %s\n' "$unit"
            return 0
        fi
    fi

    # The service verdict goes ON the timer's line. Printing nothing when the
    # service is healthy would leave a reader unable to tell "checked and fine"
    # from "never looked at", which is the distinction this whole file exists to
    # keep.
    local svc_note=""
    if [[ -n "$svc" ]]; then
        if check_service "$svc" "$unit activates it"; then
            svc_note=" ($svc ok)"
        else
            svc_note=" ($svc: see above)"
        fi
    fi
    printf '  ✓ %s: active, last run %s, next %s%s\n' \
           "$unit" "$(fmt_ago "$last")" "$(fmt_time "$next")" "$svc_note"
    return 0
}

# A managed service no managed timer activates — herdr-server.service today.
# There is no freshness question for a Type=simple daemon; the question is
# whether it is up. Its environment and ExecStart have their own two sections in
# verify-tools.sh and are not repeated here.
check_standalone_service() {
    local svc="$1" props load active
    props="$(unit_props "$svc")"
    load="$(prop "$props" LoadState)"
    if [[ "$load" != "loaded" ]]; then
        note_fail
        printf '  ✗ %s: enabled but LoadState=%s — systemd cannot load it. Fix: ./install\n' "$svc" "${load:-unknown}"
        return 0
    fi
    active="$(prop "$props" ActiveState)"
    if [[ "$active" == "active" || "$active" == "activating" ]]; then
        printf '  ✓ %s: %s\n' "$svc" "$active"
        return 0
    fi
    note_fail
    printf '  ✗ %s: enabled but ActiveState=%s (Result=%s)\n' "$svc" "${active:-unknown}" "$(prop "$props" Result)"
    printf '      journalctl --user -u %s -e\n' "$svc"
    return 0
}

# ---------------------------------------------------------------------------
main() {
    local root managed unit timers_json rows
    local -a managed_timers=() managed_services=()

    root="${TIMER_HEALTH_ROOT:-}"
    if [[ -z "$root" ]]; then
        resolve_live_checkout
        root="$LIVE_ROOT"
        if [[ -z "$root" ]]; then
            if (( FOUND_LINK )); then
                printf '  ✗ units are linked into %s, but the checkout they point into has no\n' "$SYSTEMD_USER_DIR"
                printf '      scripts/reconcile-systemd-units.sh — unit OWNERSHIP is unknown, so timer\n'
                printf '      health is UNCHECKED. That is not a pass. Fix: ./install\n'
                return 2
            fi
            printf '  ○ no managed systemd user units linked into %s — skipped\n' "$SYSTEMD_USER_DIR"
            return 0
        fi
    fi
    local reconciler="${TIMER_HEALTH_RECONCILER:-$root/scripts/reconcile-systemd-units.sh}"
    if [[ ! -x "$reconciler" ]]; then
        printf '  ✗ %s missing — unit OWNERSHIP unknown,\n' "$reconciler"
        printf '      so timer health is UNCHECKED. That is not a pass.\n'
        return 2
    fi

    managed="$(SYSTEMD_USER_DIR="$SYSTEMD_USER_DIR" DOTFILES_DIR="$root" \
               "$reconciler" --list-managed 2>/dev/null)" || {
        printf '  ✗ %s could not answer --list-managed — unit OWNERSHIP unknown, so\n' "$reconciler"
        printf '      timer health is UNCHECKED. That is not a pass.\n'
        printf '      Most likely the DEPLOYED reconciler predates this flag: the question is\n'
        printf '      about the LIVE units, so it is the live checkout that is asked, not the\n'
        printf '      one this script was run from. Deploy both together:\n'
        printf '        git -C %s fetch origin main && git -C %s merge --ff-only origin/main\n' "$root" "$root"
        return 2
    }

    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        is_bare_template "$unit" && continue
        case "$unit" in
            *.timer)   managed_timers+=("$unit") ;;
            *.service) managed_services+=("$unit") ;;
        esac
    done <<<"$managed"

    if (( ${#managed_timers[@]} == 0 && ${#managed_services[@]} == 0 )); then
        printf '  ○ %s owns no systemd user units on this machine — skipped\n' "$root"
        return 0
    fi

    if ! have_user_manager; then
        # Deliberately not a failure — see EXIT CODE in the header.
        printf '  ○ no systemd user manager reachable — timer health skipped\n'
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        printf '  ✗ jq is required to read "systemctl --user list-timers -o json" —\n'
        printf '      timer health UNCHECKED. That is not a pass. Install jq.\n'
        return 2
    fi

    timers_json="$(systemctl --user list-timers --all -o json 2>/dev/null)"
    rows="$(jq -r '.[] | [.unit, (.activates // ""), (.next // 0), (.last // 0)] | @tsv' <<<"$timers_json" 2>/dev/null)" || rows=""

    local -A tnext=() tlast=() tsvc=()
    local u n l s
    while IFS=$'\t' read -r u s n l; do
        [[ -n "$u" ]] || continue
        tnext["$u"]="${n:-0}"; tlast["$u"]="${l:-0}"; tsvc["$u"]="${s:-}"
    done <<<"$rows"

    local -A activated=()
    for unit in "${managed_timers[@]}"; do
        if ! is_enabled "$unit"; then
            # "linked but not enabled" is a DECISION, not drift — the reconciler
            # says so explicitly and wt-gc-sweep depends on it. Not checked, and
            # said out loud so the silence is not mistaken for a pass.
            printf '  · %s: linked, not enabled — not checked\n' "$unit"
            continue
        fi
        if [[ -z "${tnext[$unit]:-}" ]]; then
            note_fail
            printf '  ✗ %s: enabled, but systemd does not list it as a timer at all.\n' "$unit"
            printf '      list-timers reports every LOADED timer, so this one did not load.\n'
            printf '      systemctl --user status %s\n' "$unit"
            continue
        fi
        [[ -n "${tsvc[$unit]}" ]] && activated["${tsvc[$unit]}"]=1
        check_timer "$unit" "${tnext[$unit]}" "${tlast[$unit]}" "${tsvc[$unit]}"
    done

    for unit in "${managed_services[@]}"; do
        [[ -n "${activated[$unit]:-}" ]] && continue
        if ! is_enabled "$unit"; then
            printf '  · %s: linked, not enabled — not checked\n' "$unit"
            continue
        fi
        check_standalone_service "$unit"
    done
    return 0
}

NOW="${TIMER_HEALTH_NOW:-$(date +%s)}"
main
rc=$?
(( rc == 2 )) && exit 2
exit "$fail"
