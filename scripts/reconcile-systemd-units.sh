#!/usr/bin/env bash
#
# scripts/reconcile-systemd-units.sh
# ==================================
#
# Reconcile the ENABLEMENT of this repo's systemd *user* units with the unit
# files dotbot links — and, in --check mode, report when the two have drifted.
#
# Why this exists
# ---------------
# A linked unit is not a reconciled unit. systemd records the `[Install]` section
# at `enable` time, as a symlink under `<target>.target.wants/`. Editing
# `WantedBy=` in the unit file afterwards changes NOTHING about what starts:
#
#   * `daemon-reload` re-reads the unit but does NOT move the .wants/ symlink
#     (verified: loaded WantedBy stayed at the old target).
#   * only `reenable` moves it — and, unlike `restart`, it leaves the running
#     process alone (verified: same MainPID, unit still active).
#   * `reenable` on a *disabled* unit ENABLES it (verified), which is why the
#     reconcile path below is gated on the unit already being enabled. This
#     script reconciles a decision; it must never make one.
#
# The drift is silent, and this repo produces it routinely, because `git
# checkout` here IS the deploy (CLAUDE.md, "The checkout IS the deployment"):
# HEAD moves, the linked unit file changes under systemd, and nothing reloads or
# re-enables anything. `./install` is not in that path at all — which is exactly
# why `--check` exists and is wired into scripts/verify-tools.sh, where it runs
# whenever anyone asks about the machine rather than only at install time.
#
# It cannot make a change take effect on a RUNNING server: that needs a restart,
# which ends every agent session on the machine. It says so instead of printing a
# success nobody can act on.
#
# Usage
# -----
#   reconcile-systemd-units.sh           reconcile (daemon-reload, then reenable)
#   reconcile-systemd-units.sh --check   report only; exit 1 if anything drifted
#   reconcile-systemd-units.sh --plan    list the units --apply would re-enable,
#                                        computed from the filesystem alone
#
# Exit code: 0 when nothing drifted (or there is nothing to look at); 1 from
# --check when a managed unit's enablement does not match its unit file. Never
# non-zero merely because no systemd user manager is reachable — a server, a
# container and a CI runner all legitimately have none, and a check that fails
# there is one people learn to ignore.
#
# Test-suite overrides (also make it hermetic):
#   SYSTEMD_USER_DIR   default ~/.config/systemd/user
#   DOTFILES_DIR       default the checkout this script lives in
#   RECONCILE_NO_SYSTEMCTL=1   pretend no manager is reachable

set -uo pipefail

SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-${HOME}/.config/systemd/user}"
DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ---------------------------------------------------------------------------
# Pure filesystem logic. No systemd needed for any of this, which is the point:
# the defect being guarded against is a symlink in the wrong directory, and that
# is fully observable — and therefore fully testable — without a running manager.
# ---------------------------------------------------------------------------

# Units in SYSTEMD_USER_DIR that are symlinks resolving INSIDE this checkout.
# Deriving the list rather than hardcoding one means a unit added later is
# covered the moment dotbot links it; hardcoding is how the next one gets missed.
managed_units() {
    local p target
    for p in "$SYSTEMD_USER_DIR"/*.service "$SYSTEMD_USER_DIR"/*.timer; do
        [[ -e "$p" ]] || continue          # unmatched glob
        # Containment below is what actually enforces "ours": a plain file in this
        # directory is at this directory's path, so it can never resolve inside the
        # checkout. This stays as a cheap statement of intent, not as the guard.
        [[ -L "$p" ]] || continue
        target="$(readlink -f "$p" 2>/dev/null)" || continue
        [[ "$target" == "$DOTFILES_DIR"/* ]] || continue
        printf '%s\n' "${p##*/}"
    done
}

# Every target named by a WantedBy= inside the [Install] section, space
# separated. Only [Install] is read: a WantedBy in a comment or another section
# is not an enablement instruction. systemd allows several WantedBy= lines and a
# space-separated list on each, so both are flattened.
declared_targets() {
    local file="$1"
    [[ -r "$file" ]] || return 0
    awk '
        /^[[:space:]]*\[/ { in_install = ($0 ~ /^[[:space:]]*\[Install\][[:space:]]*$/); next }
        !in_install { next }
        # No comment rule is needed and none is written: this pattern is anchored,
        # so "# WantedBy=x" cannot match it. A rule that cannot fire would read as
        # coverage while pinning nothing (mutation-tested — removing a comment
        # skip changed no result, which is how it was found).
        /^[[:space:]]*WantedBy[[:space:]]*=/ {
            sub(/^[[:space:]]*WantedBy[[:space:]]*=[[:space:]]*/, "")
            gsub(/,/, " ")
            print
        }
    ' "$file" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# The targets whose .wants/ directory currently holds a link for this unit.
actual_targets() {
    local unit="$1" d name
    for d in "$SYSTEMD_USER_DIR"/*.wants; do
        [[ -d "$d" ]] || continue
        [[ -e "$d/$unit" ]] || continue
        name="${d##*/}"
        printf '%s\n' "${name%.wants}"
    done | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# ok | drifted | not-enabled | static
#
# "static" is a unit with no WantedBy at all: nothing to reconcile, and calling
# that drift would make this permanently red on a unit that is started by hand
# or pulled in by another unit's Wants=.
unit_enablement_state() {
    local unit="$1" declared actual
    declared="$(declared_targets "$SYSTEMD_USER_DIR/$unit")"
    actual="$(actual_targets "$unit")"
    if [[ -z "$declared" ]]; then
        printf 'static'
    elif [[ -z "$actual" ]]; then
        printf 'not-enabled'
    elif [[ "$declared" == "$actual" ]]; then
        printf 'ok'
    else
        printf 'drifted'
    fi
}

# ---------------------------------------------------------------------------
# systemd interaction
# ---------------------------------------------------------------------------

have_user_manager() {
    [[ -z "${RECONCILE_NO_SYSTEMCTL:-}" ]] || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    [[ -n "${XDG_RUNTIME_DIR:-}" ]] || return 1
    systemctl --user show-environment >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

do_check() {
    local unit state declared actual drifted=0 seen=0 reload=""

    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        seen=1
        state="$(unit_enablement_state "$unit")"
        declared="$(declared_targets "$SYSTEMD_USER_DIR/$unit")"
        actual="$(actual_targets "$unit")"
        case "$state" in
            ok)          printf '  ✓ %s: enabled under %s, as its unit file declares\n' "$unit" "$declared" ;;
            static)      printf '  · %s: no WantedBy= — nothing to reconcile\n' "$unit" ;;
            not-enabled) printf '  · %s: not enabled (declares %s) — enable it if you want it\n' "$unit" "$declared" ;;
            drifted)
                drifted=1
                printf '  ✗ %s: enabled under %s, but its unit file declares %s\n' "$unit" "${actual:-nothing}" "$declared"
                printf '      The file changed and the enablement did not follow, so what starts is\n'
                printf '      still the OLD target. Fix: systemctl --user reenable %s\n' "$unit"
                ;;
        esac

        # A unit systemd has not re-read is drift of the same kind: the file on
        # disk is under review, the loaded unit is what actually runs.
        if have_user_manager; then
            reload="$(systemctl --user show "$unit" -p NeedDaemonReload --value 2>/dev/null)"
            if [[ "$reload" == "yes" ]]; then
                drifted=1
                printf '  ✗ %s: systemd has not re-read this unit (NeedDaemonReload=yes) —\n' "$unit"
                printf '      the loaded unit is NOT the file in this checkout.\n'
                printf '      Fix: systemctl --user daemon-reload\n'
            fi
        fi
    done < <(managed_units)

    if (( ! seen )); then
        printf '  ○ no systemd user units linked from %s — skipped\n' "$DOTFILES_DIR"
    fi
    return "$drifted"
}

# The units reconcile would act on. Split out so the decision is observable
# without a systemd manager: `reenable` on a disabled unit ENABLES it, so "only
# already-enabled units" is the one safety-critical line here, and it was
# unpinnable while it lived inside a manager-gated loop (found by mutation).
units_to_reenable() {
    local unit
    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        [[ "$(unit_enablement_state "$unit")" == "drifted" ]] || continue
        printf '%s\n' "$unit"
    done < <(managed_units)
}

do_plan() {
    units_to_reenable
    return 0
}

do_reconcile() {
    local unit
    if ! have_user_manager; then
        # A server, a container and a CI runner all legitimately have none.
        printf '  ○ no systemd user manager reachable — skipping unit reconciliation\n'
        return 0
    fi

    systemctl --user daemon-reload 2>/dev/null || {
        printf '  ⚠ daemon-reload failed — run: systemctl --user daemon-reload\n' >&2
        return 0
    }

    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        if systemctl --user reenable "$unit" >/dev/null 2>&1; then
            printf '  ✓ %s: enablement moved to %s\n' "$unit" "$(declared_targets "$SYSTEMD_USER_DIR/$unit")"
            if [[ "$(systemctl --user is-active "$unit" 2>/dev/null)" == "active" ]]; then
                printf '    NOTE: the RUNNING instance still has the old unit and environment.\n'
                printf '    That changes only on restart, which ENDS EVERY AGENT SESSION:\n'
                printf '      systemctl --user restart %s   # from a PLAIN terminal, not a pane\n' "$unit"
            fi
        else
            printf '  ⚠ %s: reenable failed — run: systemctl --user reenable %s\n' "$unit" "$unit" >&2
        fi
    done < <(units_to_reenable)
    return 0
}

case "${1:-}" in
    --check)      do_check ;;
    --plan)       do_plan ;;
    ""|--apply)   do_reconcile ;;
    --help|-h)    sed -n '3,50p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            printf 'usage: %s [--check|--plan|--apply]\n' "${0##*/}" >&2; exit 2 ;;
esac
