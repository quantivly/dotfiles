#!/bin/sh
# pane-reaper timer. Launched detached by on-status-changed.sh (and by itself on
# a re-arm) as: recheck.sh <pane> <terminal_id> <seq> <nonce> <minutes>
#
# After the grace it closes the pane only if nothing about it has changed and
# nobody could still want it. Every other outcome is one log line.
set -u

PR_ROOT="${HERDR_PLUGIN_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}"
# shellcheck source=config/herdr/plugins/local/pane-reaper/lib.sh
. "$PR_ROOT/lib.sh"

[ $# -eq 5 ] || exit 0
pane=$1 term=$2 seq=$3 nonce=$4 min=$5
# 1-4 decimal digits only, then normalized (leading zeros stripped) before
# either value reaches `$(( ))`: dash reads a leading-zero numeral as octal and
# aborts on an invalid digit (e.g. "08"), which would crash this script before
# it could log or reach the nonce/finish machinery.
case "$min" in
    [0-9]|[0-9][0-9]|[0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]) ;;
    *) exit 0 ;;
esac
min=$(pr_uint "$min" 0)
spm=$(pr_uint "${PANE_REAPER_SECONDS_PER_MIN:-60}" 60)

sleep $((min * spm))

# Superseded by a newer arm, or disarmed: not ours to act on any more.
[ "$(pr_slot_nonce "$pane")" = "$nonce" ] || exit 0

finish() {
    [ "$(pr_slot_nonce "$pane")" = "$nonce" ] && rm -f "$(pr_slot_file "$pane")"
    exit 0
}
skip() {
    pr_log "$pane" "skip:$1"
    finish
}
rearm() {
    _n=$(pr_nonce)
    if pr_slot_write "$pane" "$term:$seq" "$_n"; then
        pr_log "$pane" "rearm:$1"
        pr_launch_timer "$pane" "$term" "$seq" "$_n" "$min"
        exit 0
    fi
    pr_log "$pane" "rearm-failed:$1"
    finish
}

a='.result.agent'
json=$(pr_agent_json "$pane") || skip agent-gone
[ "$(pr_field "$json" "$a.pane_id")" = "$pane" ] || skip agent-gone
[ "$(pr_field "$json" "$a.terminal_id")" = "$term" ] || skip terminal-changed
[ "$(pr_field "$json" "$a.tokens.pane_reaper")" = ready ] || skip not-ready
case "$(pr_field "$json" "$a.agent_status")" in
    done|idle) ;;
    *) skip status ;;
esac
[ "$(pr_field "$json" "$a.state_change_seq")" = "$seq" ] || skip seq-changed

# Closing a workspace's last pane closes the workspace. Only a linked worktree's
# workspace may go that way; a primary checkout or plain folder stays.
ws=$(pr_field "$json" "$a.workspace_id")
wjson=$("$PR_HERDR" workspace get "$ws" 2>/dev/null) || skip workspace-unreadable
count=$(pr_field "$wjson" '.result.workspace.pane_count')
case "$count" in ''|*[!0-9]*) skip workspace-unreadable ;; esac
linked=$(printf '%s' "$wjson" | jq -r '.result.workspace.worktree.is_linked_worktree // false' 2>/dev/null)
[ "$count" -eq 1 ] && [ "$linked" != true ] && skip primary-workspace-last-pane

pr_has_bash_children "$pane" && rearm bash-children
[ "$(pr_field "$json" "$a.focused")" = true ] && rearm focused

if out=$("$PR_HERDR" pane close "$pane" 2>/dev/null); then
    pr_log "$pane" closed
else
    code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
    pr_log "$pane" "close-failed:${code:-unknown}"
fi
finish
