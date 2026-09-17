#!/usr/bin/env bash
#
# scripts/test-pane-reaper.sh
# ===========================
#
# State table for the pane-reaper herdr plugin
# (config/herdr/plugins/local/pane-reaper). The plugin CLOSES PANES, so every
# run puts a recording `herdr` stub on HERDR_BIN_PATH: this machine has a real
# herdr talking to a live server, and a suite that fell through to it would
# close real agents. Timers are recorded via PANE_REAPER_LAUNCH_LOG instead of
# spawned, except in the one row that proves the detach itself.
#
# Requires: bash, sh, jq, awk, timeout. No herdr, no network, no real panes.
#
# Usage: scripts/test-pane-reaper.sh

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$DOTFILES/config/herdr/plugins/local/pane-reaper"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

for tool in sh jq awk timeout; do
    command -v "$tool" >/dev/null || fatal "$tool is required"
done

STUBBIN="$TMPROOT/bin"; SD="$TMPROOT/sd"
mkdir -p "$STUBBIN" "$SD"
cat > "$STUBBIN/herdr" <<'SH'
#!/bin/sh
d="$PANE_REAPER_STUB_DIR"
printf '%s\n' "$*" >> "$d/calls"
case "$1 $2" in
  "agent get")
    if [ -f "$d/agent.json" ]; then cat "$d/agent.json"; exit 0; fi
    printf '{"error":{"code":"agent_not_found","message":"not found"}}\n'; exit 1 ;;
  "workspace get")     cat "$d/workspace.json" ;;
  "pane process-info") cat "$d/procinfo.json" ;;
  "pane close")
    if [ -f "$d/close-fails" ]; then cat "$d/close-fails"; exit 1; fi ;;
  "pane report-metadata")
    if [ -f "$d/metadata-fails" ]; then cat "$d/metadata-fails"; exit 1; fi ;;
  *) exit 2 ;;
esac
SH
chmod +x "$STUBBIN/herdr"

reset() {
    rm -rf "$SD" "$TMPROOT/slots" "$TMPROOT/xdg" "$TMPROOT/launch"
    mkdir -p "$SD"; : > "$SD/calls"; : > "$SD/ps.txt"
}
# agent <status> <pane_reaper> <focused> <seq> <terminal_id> <pane_reaper_min>
agent() {
    jq -n --arg s "$1" --arg r "$2" --argjson f "$3" --argjson q "$4" --arg t "$5" --arg m "$6" \
      '{result:{agent:{pane_id:"w1:p1", workspace_id:"w1", terminal_id:$t,
        state_change_seq:$q, agent_status:$s, focused:$f,
        tokens:((if $r == "" then {} else {pane_reaper:$r} end)
              + (if $m == "" then {} else {pane_reaper_min:$m} end))}}}' > "$SD/agent.json"
}
# workspace <pane_count> <is_linked_worktree: true|false|null>
workspace() {
    local wt=null
    [[ "$2" != null ]] && wt="{\"is_linked_worktree\":$2}"
    printf '{"result":{"workspace":{"workspace_id":"w1","pane_count":%s,"worktree":%s}}}\n' "$1" "$wt" > "$SD/workspace.json"
}
procinfo() {
    printf '{"result":{"process_info":{"pane_id":"w1:p1","foreground_processes":[{"pid":100,"name":"claude"}]}}}\n' > "$SD/procinfo.json"
}
# pstable: stdin lines "pid ppid args"
pstable() { cat > "$SD/ps.txt"; }
envrun() {
    env HERDR_BIN_PATH="$STUBBIN/herdr" HERDR_PLUGIN_ROOT="$PLUGIN" \
        PANE_REAPER_STUB_DIR="$SD" PANE_REAPER_SLOT_DIR="$TMPROOT/slots" \
        XDG_STATE_HOME="$TMPROOT/xdg" PANE_REAPER_PS_FILE="$SD/ps.txt" "$@"
}
event() { printf '{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1","agent_status":"%s"}}' "$1"; }
hook() {
    envrun PANE_REAPER_LAUNCH_LOG="$TMPROOT/launch" HERDR_PLUGIN_EVENT_JSON="$(event "$1")" \
        sh "$PLUGIN/on-status-changed.sh"
}
recheck() { envrun PANE_REAPER_LAUNCH_LOG="$TMPROOT/launch" sh "$PLUGIN/recheck.sh" "$@"; }
seed_slot() { mkdir -p "$TMPROOT/slots"; printf '%s %s\n' "$1" "$2" > "$TMPROOT/slots/w1_p1"; }
slot()     { cat "$TMPROOT/slots/w1_p1" 2>/dev/null; }
lastlog()  { tail -n1 "$TMPROOT/xdg/pane-reaper/log" 2>/dev/null | cut -d' ' -f3-; }
closes()   { grep -c '^pane close' "$SD/calls" || true; }
clears()   { grep -c -- '--clear-token pane_reaper' "$SD/calls" || true; }
ncalls()   { wc -l < "$SD/calls" | tr -d ' '; }
launches() { if [[ -f "$TMPROOT/launch" ]]; then wc -l < "$TMPROOT/launch" | tr -d ' '; else echo 0; fi; }
lastlaunch_min() { tail -n1 "$TMPROOT/launch" 2>/dev/null | awk '{print $NF}'; }

echo "=== hook: filter and arm ==="
reset; agent "done" ready false 7 T ""
hook unknown
check "unknown status: herdr is not called"      "$(ncalls)"    "0"
reset; agent "done" "" false 7 T ""
hook "done"
check "done, not ready: no timer"                "$(launches)"  "0"
reset; agent "done" ready false 7 T ""
hook "done"
check "done + ready: one timer"                  "$(launches)"  "1"
check "done + ready: logged armed:5m"            "$(lastlog)"   "armed:5m"
check "slot holds the generation"                "$(slot | cut -d' ' -f1)" "T:7"
hook idle
check "same generation again: no second timer"   "$(launches)"  "1"
agent idle ready false 8 T ""
hook idle
check "new seq: a second timer"                  "$(launches)"  "2"
check "slot moved to the new generation"         "$(slot | cut -d' ' -f1)" "T:8"
# shellcheck disable=SC2016 # must stay unexpanded: it's a raw pane_reaper_min value under test, not an eval'd command
for raw in "" abc '5;$(id)'; do
    reset; agent "done" ready false 7 T "$raw"
    hook "done"
    check "pane_reaper_min='$raw' falls back to 5"  "$(lastlaunch_min)" "5"
done
reset; agent "done" ready false 7 T 2
hook "done"
check "pane_reaper_min=2 is honoured"            "$(lastlaunch_min)" "2"

echo
echo "=== hook: disarm on a new turn ==="
reset; agent working ready false 9 T ""
hook working
check "working, never armed: herdr is not called" "$(ncalls)"   "0"
reset; agent working ready false 7 T ""; seed_slot T:7 N1
hook working
check "same seq (presentation-only): token kept" "$(clears)"    "0"
check "same seq: slot kept"                      "$(slot)"      "T:7 N1"
reset; agent working ready false 9 T ""; seed_slot T:7 N1
hook working
check "new turn on an armed pane: token cleared" "$(clears)"    "1"
check "new turn: slot removed"                   "$(slot)"      ""
check "new turn: logged"                         "$(lastlog)"   "disarmed:new-turn"
reset; agent blocked ready false 9 T ""; seed_slot T:7 N1
hook blocked
check "blocked counts as a new turn"             "$(clears)"    "1"

reset; agent working ready false 9 T ""; seed_slot T:7 N1
printf '%s\n' '{"error":{"code":"server_unavailable","message":"x"}}' > "$SD/metadata-fails"
hook working
check "failed clear: logged"                     "$(lastlog)"   "disarm-failed:server_unavailable"
check "failed clear: slot marked disarmed"       "$(slot | cut -d' ' -f1)" "disarmed"
agent "done" ready false 10 T ""
hook "done"
check "failed clear: refuses to re-arm"          "$(launches)"  "0"
rm -f "$SD/metadata-fails"
agent working ready false 11 T ""
hook working
check "retry after clear works: logged"          "$(lastlog)"   "disarmed:new-turn"
check "retry after clear works: slot removed"    "$(slot)"      ""

echo
echo "=== recheck: gates ==="
# The standard ready pane: done, ready, unfocused, seq 7, terminal T, in a
# 2-pane linked-worktree workspace, running claude as pid 100 with no children.
base() { reset; agent "done" ready false 7 T ""; workspace 2 true; procinfo; seed_slot T:7 N1; }

base; recheck w1:p1 T 7 N1 0
check "happy path: closed"                       "$(closes)"    "1"
check "happy path: logged"                       "$(lastlog)"   "closed"
check "happy path: slot cleared"                 "$(slot)"      ""
base; seed_slot T:7 OTHER; recheck w1:p1 T 7 N1 0
check "superseded timer: herdr not called"       "$(ncalls)"    "0"
check "superseded timer: slot untouched"         "$(slot)"      "T:7 OTHER"
base; rm -f "$SD/agent.json"; recheck w1:p1 T 7 N1 0
check "agent gone: skip"                         "$(lastlog)"   "skip:agent-gone"
check "agent gone: no close"                     "$(closes)"    "0"
base; agent "done" ready false 7 T2 ""; recheck w1:p1 T 7 N1 0
check "terminal changed: skip"                   "$(lastlog)"   "skip:terminal-changed"
base; agent "done" "" false 7 T ""; recheck w1:p1 T 7 N1 0
check "token removed: skip"                      "$(lastlog)"   "skip:not-ready"
base; agent working ready false 7 T ""; recheck w1:p1 T 7 N1 0
check "working: skip"                            "$(lastlog)"   "skip:status"
base; agent idle ready false 8 T ""; recheck w1:p1 T 7 N1 0
check "seq changed: skip"                        "$(lastlog)"   "skip:seq-changed"
check "seq changed: no close"                    "$(closes)"    "0"

base
pstable <<'PS'
100 1 claude --settings {}
200 100 /usr/bin/zsh -c source /home/u/.claude/shell-snapshots/snapshot-zsh-1.sh && gh pr checks --watch
300 200 gh pr checks --watch
PS
recheck w1:p1 T 7 N1 0
check "bash job alive: rearm"                    "$(lastlog)"   "rearm:bash-children"
check "bash job alive: no close"                 "$(closes)"    "0"
check "bash job alive: a new timer"              "$(launches)"  "1"
check "bash job alive: slot has a new nonce"     "$([[ "$(slot)" == "T:7 "* && "$(slot)" != "T:7 N1" ]] && echo yes)" "yes"
base
pstable <<'PS'
100 1 claude --settings {}
210 100 node /opt/mcp/server.js
900 1 /usr/bin/zsh -c source /x/shell-snapshots/snapshot-zsh-9.sh
PS
recheck w1:p1 T 7 N1 0
check "only MCP children (and someone else's job): closed" "$(closes)" "1"
base; agent "done" ready true 7 T ""; recheck w1:p1 T 7 N1 0
check "focused: rearm"                           "$(lastlog)"   "rearm:focused"
check "focused: no close"                        "$(closes)"    "0"
base; workspace 1 null; recheck w1:p1 T 7 N1 0
check "last pane of a plain workspace: skip"     "$(lastlog)"   "skip:primary-workspace-last-pane"
base; workspace 1 false; recheck w1:p1 T 7 N1 0
check "last pane of a primary checkout: skip"    "$(lastlog)"   "skip:primary-workspace-last-pane"
base; workspace 1 true; recheck w1:p1 T 7 N1 0
check "last pane of a linked worktree: closed"   "$(closes)"    "1"
base; printf '{"error":{"code":"confirmation_required","message":"x"}}\n' > "$SD/close-fails"
recheck w1:p1 T 7 N1 0
check "close refused: logged with its code"      "$(lastlog)"   "close-failed:confirmation_required"
check "close refused: tried once"                "$(closes)"    "1"
base; recheck w1:p1 T 7 N1 'x;1'
check "non-numeric minutes: herdr not called"    "$(ncalls)"    "0"

# Task 3 appends the detach row here.

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
