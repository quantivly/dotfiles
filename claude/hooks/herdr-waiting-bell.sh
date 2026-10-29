#!/usr/bin/env bash
# claude/hooks/herdr-waiting-bell.sh: a Claude Code Stop hook that rings herdr's
# "needs you" sound when a turn ends with a question for you and you are likely away.
#
# WHY IT EXISTS. herdr makes a sound for two things. `request` means the agent is
# blocked on a dialog (permission prompt, AskUserQuestion, plan approval). `done`
# means a turn ended. config/herdr/config.toml mutes `done`, because one beep per
# turn per agent was the noise. That leaves one case silent that should not be: a
# turn that ENDS by asking you something in prose. To herdr that is just `done`.
# The global CLAUDE.md makes every agent close with a status block, and its
# **Waiting on you** heading appears only when something is blocking on you. That
# heading is the signal this hook reads.
#
# WHEN IT RINGS. All of these hold:
#   - The session runs in a herdr pane (HERDR_ENV=1 and HERDR_PANE_ID set).
#   - This is not a stop-hook continuation (stop_hook_active is not true).
#   - A line of last_assistant_message starts with **Waiting on you** (a trailing
#     colon is allowed) or is a markdown heading "Waiting on you". The phrase in the
#     middle of a sentence does not count.
#   - herdr detects the pane as claude. herdmates teammates are not detected, and
#     their "Waiting on you" is addressed to their lead, not to you.
#   - You are likely away: the pane is not focused in herdr, OR the turn took at
#     least HERDR_BELL_AWAY_AFTER_SECONDS (default 30). A quick back-and-forth in
#     the pane you are typing into stays silent. A long task rings even in the
#     focused pane, because you have probably switched to something else.
#
# FAILS OPEN. If herdr cannot be asked, or the turn start cannot be read from the
# transcript (its format is undocumented and may change), it rings. A bell that
# went quiet on its own errors would be a mute nobody chose. The same rule as
# config/herdr/shims/pw-play.
#
# HOW IT PLAYS. Through config/herdr/shims/pw-play, so GNOME's Do Not Disturb
# silences it like every other herdr sound, with herdr's own request.mp3 so a
# prose question and a blocked dialog sound the same. It does not use
# `herdr notification show --sound request`: with toast delivery "herdr" that
# call plays nothing while any toast is showing, and herdr's own "finished" toast
# is showing at exactly this moment. The player is detached (setsid) so the hook
# returns at once. A lock held while it plays makes bells that fire together ring
# once.
#
# NEVER BLOCKS THE STOP. It always exits 0 and writes nothing to stdout. A Stop
# hook's stdout is parsed as a decision.
#
# Registered in ~/.claude/settings.json by scripts/herdr-claude-wire.sh.
# State table: scripts/test-herdr-waiting-bell.sh. docs/HERDR_GUIDE.md section 7.

set -uo pipefail
exec >/dev/null 2>&1
# Read the hook input before any early exit, so Claude Code never writes into a
# closed pipe.
hook_input=$(cat)

AWAY_AFTER_SECONDS="${HERDR_BELL_AWAY_AFTER_SECONDS:-30}"
HERDR_QUERY_TIMEOUT_SECONDS=2
TRANSCRIPT_READ_TIMEOUT_SECONDS=3
WAITING_ON_YOU_LINE='^[[:space:]]*(\*\*Waiting on you:?\*\*|#{1,6}[[:space:]]+Waiting on you)'

[[ "${HERDR_ENV:-}" == 1 && -n "${HERDR_PANE_ID:-}" ]] || exit 0
command -v jq >/dev/null || exit 0
[[ "$AWAY_AFTER_SECONDS" =~ ^[0-9]+$ ]] || AWAY_AFTER_SECONDS=30

hook_real_path=$(readlink -f "${BASH_SOURCE[0]}") || exit 0
repo_root=$(cd "${hook_real_path%/*}/../.." && pwd -P) || exit 0
player_shim="$repo_root/config/herdr/shims/pw-play"
bell_sound="$repo_root/config/herdr/sounds/request.mp3"
[[ -x "$player_shim" && -f "$bell_sound" ]] || exit 0

[[ "$(jq -r '.stop_hook_active // false' <<<"$hook_input")" == true ]] && exit 0

last_message=$(jq -r '.last_assistant_message // empty' <<<"$hook_input")
asks_for_you=0
while IFS= read -r message_line; do
    if [[ "$message_line" =~ $WAITING_ON_YOU_LINE ]]; then
        asks_for_you=1
        break
    fi
done <<<"$last_message"
(( asks_for_you )) || exit 0

# One query answers both "is this a teammate?" and "are you looking at it?".
# The reply's type is checked before it is indexed: an error reply is a failed
# query (ring), never an undetected pane (silent).
is_focused=0
if pane_json=$(timeout "$HERDR_QUERY_TIMEOUT_SECONDS" herdr pane get "$HERDR_PANE_ID") \
   && [[ "$(jq -r '.result.pane | type' <<<"$pane_json")" == object ]]; then
    [[ "$(jq -r '.result.pane.agent // ""' <<<"$pane_json")" == claude ]] || exit 0
    [[ "$(jq -r '.result.pane.focused' <<<"$pane_json")" == true ]] && is_focused=1
fi

is_likely_away=1
if (( is_focused )); then
    # Turn start: the newest prompt you typed. Tool results are also "user"
    # entries, so an entry carrying a tool_result is skipped, as are meta entries.
    transcript_path=$(jq -r '.transcript_path // empty' <<<"$hook_input")
    turn_started_epoch=""
    if [[ -n "$transcript_path" && -r "$transcript_path" ]]; then
        turn_started_epoch=$(
            timeout "$TRANSCRIPT_READ_TIMEOUT_SECONDS" tac "$transcript_path" \
              | jq -R -r 'fromjson?
                  | select(.type == "user" and (.isMeta | not))
                  | select(.message.content
                           | if type == "string" then true
                             else (any(.[]?; .type == "tool_result") | not) end)
                  | .timestamp // empty
                  | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // empty' \
              | head -n 1
        )
    fi
    if [[ "$turn_started_epoch" =~ ^[0-9]+$ ]]; then
        turn_seconds=$(( $(date +%s) - turn_started_epoch ))
        (( turn_seconds >= AWAY_AFTER_SECONDS )) || is_likely_away=0
    fi
fi
(( is_likely_away )) || exit 0

bell_lock="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/herdr-waiting-bell.lock"
setsid -f flock -n "$bell_lock" "$player_shim" "$bell_sound" </dev/null
exit 0
