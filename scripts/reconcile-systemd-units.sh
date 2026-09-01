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
#   * **`reenable` and `disable` MUST NOT be used here.** `disable` removes every
#     symlink in the unit search path that points at the unit — and for a unit
#     installed by dotbot, the entry in ~/.config/systemd/user IS such a symlink,
#     into this checkout. So `reenable` (= disable + enable) deletes the unit from
#     the search path, and the `enable` half then fails with "Unit does not
#     exist", leaving the unit neither linked nor enabled. Verified twice: once on
#     this machine, by following advice that said to run it, and once on a probe
#     built to reproduce it. An earlier probe used a real FILE rather than a
#     symlink and therefore showed `reenable` working perfectly — the fixture
#     differed from production in the one property that decided the outcome.
#   * what is safe: `enable` (it only ADDS .wants links and leaves the unit
#     symlink alone), plus removing the stale .wants links by hand. Enable first,
#     remove second, so a failure leaves the unit enabled under the old target
#     rather than not enabled at all.
#   * the reconcile path is gated on the unit already being enabled, so this
#     script reconciles a decision and never makes one.
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
#   reconcile-systemd-units.sh           reconcile (daemon-reload, then enable +
#                                        prune the stale .wants links)
#   reconcile-systemd-units.sh --check   report only; exit 1 if anything drifted
#   reconcile-systemd-units.sh --plan    list the units --apply would ENABLE,
#                                        computed from the filesystem alone
#   reconcile-systemd-units.sh --plan-stale
#                                        list the .wants symlinks --apply would
#                                        REMOVE — never the unit symlink itself
#
# States a managed unit can be in (--check reports each one differently, and
# only the last three are drift):
#
#   ok            enabled under exactly the targets its [Install] declares
#   not-enabled   declares targets, nobody enabled it — a decision, not drift
#   static        no [Install] WantedBy= and no .wants link — nothing to do
#   drifted       enabled under targets its file no longer declares
#   orphan-wants  its [Install] declares nothing, yet a .wants link still starts
#                 it — the same drift, with the file having moved to "never"
#   broken        the unit symlink resolves to a file that is not there
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
DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
# PHYSICAL on both sides, and canonicalised even when handed in by the caller.
# bash's `cd`/`pwd` are LOGICAL: they keep the symlinks you walked through. The
# containment test below compares against `readlink -f`, which is physical, so
# with the ordinary layout `~/.dotfiles -> ~/src/dotfiles` (and DOTFILES_ROOT
# exists as an override precisely because the checkout moves) containment could
# never hold, managed_units() returned nothing, and --check printed "no systemd
# user units linked … — skipped" and exited 0 on a machine with real drift.
DOTFILES_DIR="$(readlink -f "$DOTFILES_DIR" 2>/dev/null || printf '%s' "$DOTFILES_DIR")"
# The `-P` above is belt-and-braces and is deliberately not separately pinned:
# reverting it alone passes the suite, because this line canonicalises the
# result either way. It stays because it makes the DERIVED default right on its
# own terms, and because this line is the one that also has to handle a
# DOTFILES_DIR handed in by the caller — which the `-P` cannot reach. Reverting
# BOTH is caught (row: "invoked through a symlinked checkout path").

# Every unit suffix systemd knows (`man 5 systemd.unit`). Derived rather than
# hardcoded to ".service and .timer": the header above argues that a unit added
# later must be covered the moment dotbot links it, and then the first version
# of this file hardcoded two suffixes anyway — a drifted .socket, .path or
# .target read as "no systemd user units linked … — skipped", exit 0.
UNIT_SUFFIXES='service socket device mount automount swap target path timer slice scope'

# ---------------------------------------------------------------------------
# Pure filesystem logic. No systemd needed for any of this, which is the point:
# the defect being guarded against is a symlink in the wrong directory, and that
# is fully observable — and therefore fully testable — without a running manager.
# ---------------------------------------------------------------------------

# Units in SYSTEMD_USER_DIR that are symlinks resolving INSIDE this checkout.
# Deriving the list rather than hardcoding one means a unit added later is
# covered the moment dotbot links it; hardcoding is how the next one gets missed.
managed_units() {
    local p target base
    for p in "$SYSTEMD_USER_DIR"/*; do
        # -e OR -L. `-e` follows the symlink, so on its own it also skips a unit
        # symlink whose target is GONE — rename systemd/herdr-server.service in
        # the repo without re-running ./install and --check said "no systemd user
        # units linked … — skipped", exit 0, indistinguishable from an empty
        # machine, while the .wants link still pointed at the missing file and
        # the server did not start.
        [[ -e "$p" || -L "$p" ]] || continue      # unmatched glob
        base="${p##*/}"
        [[ "$base" == *.* ]] || continue
        [[ " $UNIT_SUFFIXES " == *" ${base##*.} "* ]] || continue
        # Containment below is what actually enforces "ours": a plain file in this
        # directory is at this directory's path, so it can never resolve inside the
        # checkout. This stays as a cheap statement of intent, not as the guard.
        [[ -L "$p" ]] || continue
        target="$(readlink -f "$p" 2>/dev/null)" || continue
        [[ "$target" == "$DOTFILES_DIR"/* ]] || continue
        printf '%s\n' "$base"
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
        # -e OR -L again: a .wants link whose target was renamed away is still a
        # link systemd walks at boot, and it is exactly the state F-A describes.
        [[ -e "$d/$unit" || -L "$d/$unit" ]] || continue
        name="${d##*/}"
        printf '%s\n' "${name%.wants}"
    done | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# ok | drifted | not-enabled | static | orphan-wants | broken
#
# "static" is a unit with no WantedBy AND no .wants link: nothing to reconcile,
# and calling that drift would make this permanently red on a unit that is
# started by hand or pulled in by another unit's Wants=.
#
# "orphan-wants" is the same unit WITH a live .wants link. Deleting a unit's
# [Install] section says "stop starting this automatically"; the leftover link
# still starts it at every login, and the reviewed file says it should not.
# Folding that into "static" printed "· no WantedBy= — nothing to reconcile"
# and exited 0 while the machine kept starting the unit (F-B).
#
# "broken" is a unit symlink resolving to nothing — the file it names was
# renamed or deleted in the checkout and ./install was never re-run. It cannot
# be enabled and its declared targets cannot be read, so it is reported and
# never acted on.
unit_enablement_state() {
    local unit="$1" declared actual
    if [[ -L "$SYSTEMD_USER_DIR/$unit" && ! -e "$SYSTEMD_USER_DIR/$unit" ]]; then
        printf 'broken'
        return 0
    fi
    declared="$(declared_targets "$SYSTEMD_USER_DIR/$unit")"
    actual="$(actual_targets "$unit")"
    if [[ -z "$declared" && -z "$actual" ]]; then
        printf 'static'
    elif [[ -z "$declared" ]]; then
        printf 'orphan-wants'
    elif [[ -z "$actual" ]]; then
        printf 'not-enabled'
    elif [[ "$declared" == "$actual" ]]; then
        printf 'ok'
    else
        printf 'drifted'
    fi
}

# The .wants symlinks --apply removes: every target the unit is currently enabled
# under that its file no longer declares. Emitted as full paths, and deliberately
# NEVER the unit symlink in SYSTEMD_USER_DIR itself — deleting that is exactly
# what `systemctl disable` does to a dotbot-installed unit, and it is the bug
# this function exists to avoid repeating. The test suite asserts that absence.
stale_wants_links() {
    local unit="$1" declared actual t
    declared=" $(declared_targets "$SYSTEMD_USER_DIR/$unit") "
    actual="$(actual_targets "$unit")"
    for t in $actual; do
        [[ "$declared" == *" $t "* ]] && continue
        printf '%s\n' "$SYSTEMD_USER_DIR/${t}.wants/${unit}"
    done
}

do_plan_stale() {
    local unit
    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        stale_wants_links "$unit"
    done < <(units_to_reenable; units_with_orphan_wants)
    return 0
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
            broken)
                drifted=1
                printf '  ✗ %s: the unit symlink resolves to nothing —\n' "$unit"
                printf '      %s -> %s is dangling, so systemd has no unit file to load.\n' \
                       "$SYSTEMD_USER_DIR/$unit" "$(readlink "$SYSTEMD_USER_DIR/$unit" 2>/dev/null)"
                printf '      The source was renamed or removed in the checkout and ./install\n'
                printf '      was never re-run. Fix: ./install\n'
                ;;
            orphan-wants)
                drifted=1
                printf '  ✗ %s: enabled under %s, but its unit file declares no [Install]\n' "$unit" "$actual"
                printf '      WantedBy= at all. The file says it should not start on its own;\n'
                printf '      the leftover .wants link starts it anyway, at every login.\n'
                printf '      Fix: ./install — NOT systemctl disable, which deletes the unit\n'
                printf '      symlink this repo installs.\n'
                ;;
            drifted)
                drifted=1
                printf '  ✗ %s: enabled under %s, but its unit file declares %s\n' "$unit" "${actual:-nothing}" "$declared"
                printf '      The file changed and the enablement did not follow, so what starts is\n'
                printf '      still the OLD target. Fix: ./install — NOT systemctl reenable,\n'
                printf '      whose disable half deletes the unit symlink this repo installs.\n'
                ;;
        esac

        # A unit systemd has not re-read is drift of the same kind: the file on
        # disk is under review, the loaded unit is what actually runs. Skipped
        # for 'broken': there is no file to compare a load timestamp against,
        # and the ✗ above already says the real thing.
        if [[ "$state" != "broken" ]] && have_user_manager; then
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

# Units whose [Install] declares nothing yet still hold a .wants link. Kept
# SEPARATE from units_to_reenable() on purpose: `systemctl enable` on a unit
# with no [Install] fails ("has no installation config"), so these are pruned
# and never enabled — and keeping the two lists apart keeps the safety gate in
# units_to_reenable() a single readable line.
units_with_orphan_wants() {
    local unit
    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        [[ "$(unit_enablement_state "$unit")" == "orphan-wants" ]] || continue
        printf '%s\n' "$unit"
    done < <(managed_units)
}

do_plan() {
    units_to_reenable
    return 0
}

# Remove the .wants links stale_wants_links() names. Returns non-zero if ANY
# removal failed, so the caller does not print a ✓ over it: `rm -f` succeeds
# loudly and fails quietly, and an unwritable <target>.wants/ (or an entry that
# is not a plain link) left the stale link in place while the caller printed
# "✓ enablement moved to …" — the silent-success class this whole file is about.
prune_stale_wants() {
    local unit="$1" link rc=0
    while IFS= read -r link; do
        [[ -n "$link" ]] || continue
        rm -f "$link" 2>/dev/null && continue
        rc=1
        printf '  ⚠ %s: could not remove the stale link %s\n' "$unit" "$link" >&2
        printf '    It still starts the unit under that target. Remove it by hand —\n' >&2
        printf '    NOT with systemctl --user disable, whose reach includes the unit\n' >&2
        printf '    symlink this repo installs.\n' >&2
    done < <(stale_wants_links "$unit")
    return "$rc"
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
        # enable FIRST: it only adds .wants links and leaves the unit symlink
        # alone, so a failure here leaves the unit enabled under the old target
        # rather than not enabled at all. Never `reenable` — see the header.
        if systemctl --user enable "$unit" >/dev/null 2>&1; then
            if prune_stale_wants "$unit"; then
                printf '  ✓ %s: enablement moved to %s\n' "$unit" "$(declared_targets "$SYSTEMD_USER_DIR/$unit")"
                if [[ "$(systemctl --user is-active "$unit" 2>/dev/null)" == "active" ]]; then
                    printf '    NOTE: the RUNNING instance still has the old unit and environment.\n'
                    printf '    That changes only on restart, which ENDS EVERY AGENT SESSION:\n'
                    printf '      systemctl --user restart %s   # from a PLAIN terminal, not a pane\n' "$unit"
                fi
            fi
        else
            printf '  ⚠ %s: enable failed — run: systemctl --user enable %s\n' "$unit" "$unit" >&2
            printf '    Do NOT use systemctl --user reenable: its disable half deletes the\n' >&2
            printf '    unit symlink this repo installs, and the enable half then cannot find it.\n' >&2
        fi
    done < <(units_to_reenable)

    # Prune-only pass: a unit whose [Install] now declares nothing cannot be
    # `enable`d (systemd rejects it), and does not need to be — the file says
    # "do not start on your own" and the only thing contradicting it is the
    # leftover link. This still reconciles a decision rather than making one:
    # the state can exist only because someone enabled the unit earlier and the
    # FILE then changed under it, which is the same drift as 'drifted'.
    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        if prune_stale_wants "$unit"; then
            printf '  ✓ %s: no [Install] WantedBy= — its leftover .wants link removed,\n' "$unit"
            printf '    so it no longer starts on its own. It is still linked and startable\n'
            printf '    by hand: systemctl --user start %s\n' "$unit"
        fi
    done < <(units_with_orphan_wants)
    return 0
}

case "${1:-}" in
    --check)      do_check ;;
    --plan)       do_plan ;;
    --plan-stale) do_plan_stale ;;
    ""|--apply)   do_reconcile ;;
    # Print the WHOLE leading comment block, not a hardcoded line range. The
    # range was `3,50p`, and the header outgrew it: help stopped mid-sentence
    # inside the --plan description, so --plan-stale and the exit-code paragraph
    # were never printed by the flag whose only job is to print them.
    --help|-h)    awk 'NR < 3 { next } /^#/ { sub(/^#[[:space:]]?/, ""); print; next } { exit }' \
                      "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            printf 'usage: %s [--check|--plan|--plan-stale|--apply]\n' "${0##*/}" >&2; exit 2 ;;
esac
