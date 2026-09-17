#!/bin/sh
# pane-reaper hook — pane.agent_status_changed.
#
# Closes nothing itself. It arms a timer (recheck.sh) for a pane whose worker
# marked itself `pane_reaper=ready` and then went done/idle, and disarms one
# when that pane starts a new turn. It runs on EVERY status change of every
# pane on the machine, so the common path is: parse, and exit.
set -u

PR_ROOT="${HERDR_PLUGIN_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}"
# shellcheck source=config/herdr/plugins/local/pane-reaper/lib.sh
. "$PR_ROOT/lib.sh"

ev="${HERDR_PLUGIN_EVENT_JSON:-}"
# herdr JSON-escapes every string value, so these keys cannot be spoofed by a
# terminal title.
pane=$(printf '%s' "$ev" | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p')
status=$(printf '%s' "$ev" | sed -n 's/.*"agent_status":"\([^"]*\)".*/\1/p')
[ -n "$pane" ] || exit 0

case "$status" in
    working|blocked)
        # Never armed (e.g. the worker's own final turn, during which it set
        # `ready`): nothing to disarm, and no socket call.
        [ -f "$(pr_slot_file "$pane")" ] || exit 0
        json=$(pr_agent_json "$pane") || exit 0
        a='.result.agent'
        gen="$(pr_field "$json" "$a.terminal_id"):$(pr_field "$json" "$a.state_change_seq")"
        # Same generation: a presentation-only event, not a new turn.
        [ "$(pr_slot_gen "$pane")" != "$gen" ] || exit 0
        if [ "$(pr_field "$json" "$a.tokens.pane_reaper")" != ready ]; then
            # Someone else already cleared the token: nothing left to disarm.
            rm -f "$(pr_slot_file "$pane")"
            exit 0
        fi
        # Clear the token before dropping the slot. A failed clear must not
        # lose the slot: the next done/idle would otherwise re-arm from the
        # stale `ready` token. Mark the slot "disarmed" instead — it can
        # never equal a real "<terminal_id>:<seq>" generation, so it blocks
        # a re-arm (see the arm path below) and a later working/blocked event
        # naturally retries the clear.
        if clear_out=$("$PR_HERDR" pane report-metadata "$pane" --source pane-reaper \
                --clear-token pane_reaper 2>&1); then
            rm -f "$(pr_slot_file "$pane")"
            pr_log "$pane" "disarmed:new-turn"
        else
            code=$(pr_field "$clear_out" '.error.code')
            [ -n "$code" ] || code=unknown
            pr_slot_write "$pane" disarmed "$(pr_nonce)"
            pr_log "$pane" "disarm-failed:$code"
        fi
        exit 0 ;;
    done|idle) ;;
    *) exit 0 ;;
esac

json=$(pr_agent_json "$pane") || exit 0
a='.result.agent'
[ "$(pr_field "$json" "$a.tokens.pane_reaper")" = ready ] || exit 0
# A failed disarm left the slot marked "disarmed": don't re-arm from a token
# we're still trying to clear.
[ "$(pr_slot_gen "$pane")" != disarmed ] || exit 0
term=$(pr_field "$json" "$a.terminal_id")
seq=$(pr_field "$json" "$a.state_change_seq")
[ -n "$term" ] || exit 0
case "$seq" in ''|*[!0-9]*) exit 0 ;; esac

gen="$term:$seq"
# Already armed for exactly this state: keep that timer's deadline.
[ "$(pr_slot_gen "$pane")" = "$gen" ] && exit 0

min=$(pr_minutes "$(pr_field "$json" "$a.tokens.pane_reaper_min")")
nonce=$(pr_nonce)
pr_slot_write "$pane" "$gen" "$nonce" || exit 0
pr_log "$pane" "armed:${min}m"
pr_launch_timer "$pane" "$term" "$seq" "$nonce" "$min"
exit 0
