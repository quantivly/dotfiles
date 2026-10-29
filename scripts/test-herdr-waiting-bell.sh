#!/usr/bin/env bash
#
# scripts/test-herdr-waiting-bell.sh: state table for claude/hooks/herdr-waiting-bell.sh
# and for the config that mutes herdr's per-turn "done" sound.
#
# HERMETIC. The hook is COPIED into a fake repo root, because it finds its player
# and sound by resolving its own real path. In that root the player shim is a
# recorder, and the sound is a placeholder file. PATH holds only stubs (herdr,
# date, and a setsid that runs its command in the foreground so every row is
# deterministic) plus links to the real jq, tac, head, timeout, readlink, flock
# and cat. One row swaps the stub for the real setsid, to prove the hook does
# not wait for the player.
#
# Every row checks the exit status, stdout and whether the bell rang, all three
# at once. A Stop hook that prints to stdout or exits non-zero is a hook that
# can block the stop, so no row may pass on the bell alone.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SUT="$ROOT/claude/hooks/herdr-waiting-bell.sh"
EXPECTED_ROWS=52

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

[[ -r "$SUT" ]] || fatal "cannot read $SUT"
BASH_BIN=$(command -v bash) || fatal "bash is required"
for tool in jq tac head timeout readlink flock cat setsid sleep; do
    command -v "$tool" >/dev/null 2>&1 || fatal "$tool is required"
done

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAKE="$T/root"; BIN="$T/bin"; TOOLS="$T/tools"; REALSETSID="$T/realsetsid"; RUN="$T/run"
PLAYED="$T/played"
mkdir -p "$FAKE/claude/hooks" "$FAKE/config/herdr/shims" "$FAKE/config/herdr/sounds" \
         "$BIN" "$TOOLS" "$REALSETSID" "$RUN"
cp "$SUT" "$FAKE/claude/hooks/herdr-waiting-bell.sh"
HOOK="$FAKE/claude/hooks/herdr-waiting-bell.sh"
SOUND="$FAKE/config/herdr/sounds/request.mp3"
: > "$SOUND"
for tool in jq tac head timeout readlink flock cat sleep; do
    ln -s "$(command -v "$tool")" "$TOOLS/$tool"
done
ln -s "$(command -v setsid)" "$REALSETSID/setsid"

# The player shim: records its arguments, then sleeps PLAYER_SLEEP seconds.
cat > "$FAKE/config/herdr/shims/pw-play" <<'EOF'
#!/bin/sh
sleep "${PLAYER_SLEEP:-0}"
printf '%s\n' "$@" > "$PLAYED"
EOF
chmod +x "$FAKE/config/herdr/shims/pw-play"

# setsid that stays in the foreground: the bell has rung by the time the hook exits.
cat > "$BIN/setsid" <<'EOF'
#!/bin/sh
[ "$1" = -f ] && shift
exec "$@"
EOF
# date: a fixed clock, so turn lengths are exact.
cat > "$BIN/date" <<'EOF'
#!/bin/sh
echo "$FAKE_NOW"
EOF
# herdr: prints HERDR_REPLY, exits HERDR_RC, or hangs when HERDR_HANG is set.
cat > "$BIN/herdr" <<'EOF'
#!/bin/sh
[ -n "${HERDR_HANG:-}" ] && exec sleep 30
printf '%s\n' "$HERDR_REPLY"
exit "${HERDR_RC:-0}"
EOF
chmod +x "$BIN/setsid" "$BIN/date" "$BIN/herdr"

FAKE_NOW=1793306154
iso_at() {  # $1 seconds before FAKE_NOW; always with a fractional part, as Claude Code writes it
    jq -rn --argjson t "$((FAKE_NOW - $1))" '$t | todateiso8601 | sub("Z$"; ".875Z")'
}
UNFOCUSED='{"result":{"pane":{"agent":"claude","focused":false}}}'
FOCUSED='{"result":{"pane":{"agent":"claude","focused":true}}}'
TEAMMATE='{"result":{"pane":{"focused":false}}}'
OTHER_AGENT='{"result":{"pane":{"agent":"codex","focused":false}}}'
ERROR_REPLY='{"error":{"code":"pane_not_found","message":"no such pane"}}'

# Transcripts. A prompt typed N seconds ago, then a tool result and an answer.
transcript() {  # $1 file, $2 prompt age, $3 tool-result age
    {
        jq -cn --arg ts "$(iso_at 900)" '{type:"user",timestamp:$ts,message:{role:"user",content:"an older prompt"}}'
        jq -cn --arg ts "$(iso_at "$2")" '{type:"user",timestamp:$ts,message:{role:"user",content:"do the thing"}}'
        jq -cn --arg ts "$(iso_at "$3")" '{type:"user",timestamp:$ts,message:{role:"user",content:[{type:"tool_result",tool_use_id:"t1",content:"ok"}]}}'
        jq -cn --arg ts "$(iso_at 1)" '{type:"assistant",timestamp:$ts,message:{role:"assistant",content:[{type:"text",text:"done"}]}}'
    } > "$1"
}
transcript "$T/turn29.jsonl" 29 2
transcript "$T/turn30.jsonl" 30 2
transcript "$T/turn40.jsonl" 40 5
# A typed prompt sent as content blocks (text, no tool_result) 40 s ago.
{
    jq -cn --arg ts "$(iso_at 40)" '{type:"user",timestamp:$ts,message:{role:"user",content:[{type:"text",text:"look"}]}}'
    jq -cn --arg ts "$(iso_at 5)" '{type:"user",timestamp:$ts,message:{role:"user",content:[{type:"tool_result",tool_use_id:"t1",content:"ok"}]}}'
} > "$T/blocks40.jsonl"
# A meta entry 5 s ago is not your prompt; the real one is 40 s old.
{
    jq -cn --arg ts "$(iso_at 40)" '{type:"user",timestamp:$ts,message:{role:"user",content:"do the thing"}}'
    jq -cn --arg ts "$(iso_at 5)" '{type:"user",isMeta:true,timestamp:$ts,message:{role:"user",content:"<system note>"}}'
} > "$T/meta40.jsonl"
# A half-written last line must not hide a 10 s turn.
{ cat "$T/turn29.jsonl"; printf '{"type":"assistant","timest'; } > "$T/torn.jsonl"
sed -i "s/$(iso_at 29)/$(iso_at 10)/" "$T/torn.jsonl"
# Only tool results: no turn start can be read.
jq -cn --arg ts "$(iso_at 2)" '{type:"user",timestamp:$ts,message:{role:"user",content:[{type:"tool_result",tool_use_id:"t1",content:"ok"}]}}' > "$T/noprompt.jsonl"

ASK=$'Done with the first half.\n\n**Waiting on you**\n1. Pick A or B.\n\n**Next (mine)**\nImplement it.'
NO_ASK=$'All done.\n\n**Next (mine)**\nNothing further.'

payload() {  # $1 message ("-" for none), $2 transcript path, $3 stop_hook_active
    if [[ "$1" == - ]]; then
        jq -cn --arg tp "$2" --argjson sha "${3:-false}" \
            '{hook_event_name:"Stop",session_id:"s1",transcript_path:$tp,stop_hook_active:$sha}'
    else
        jq -cn --arg m "$1" --arg tp "$2" --argjson sha "${3:-false}" \
            '{hook_event_name:"Stop",session_id:"s1",transcript_path:$tp,stop_hook_active:$sha,last_assistant_message:$m}'
    fi
}

# Runs the hook with $1 as its input. The environment comes from the caller's
# variables: REPLY (herdr's answer), RC, HANG, ENV_HERDR, PANE, AWAY, SETSID_DIR.
# Prints "<exit> <rang|silent>", with " stdout!" added if it printed anything.
ring_or_silent() {
    local input="$1" rc out
    rm -f "$PLAYED"
    env -i PATH="${SETSID_DIR:+$SETSID_DIR:}$BIN:$TOOLS" HOME="$T" PLAYED="$PLAYED" \
        FAKE_NOW="$FAKE_NOW" XDG_RUNTIME_DIR="$RUN" PLAYER_SLEEP="${PLAYER_SLEEP:-0}" \
        HERDR_ENV="${ENV_HERDR-1}" HERDR_PANE_ID="${PANE-w1:p1}" \
        HERDR_REPLY="${REPLY-$UNFOCUSED}" HERDR_RC="${RC:-0}" ${HANG:+HERDR_HANG=1} \
        ${AWAY:+HERDR_BELL_AWAY_AFTER_SECONDS="$AWAY"} \
        "$BASH_BIN" "$HOOK" <<<"$input" > "$T/stdout" 2>/dev/null
    rc=$?
    out="$rc $([[ -f "$PLAYED" ]] && echo rang || echo silent)"
    [[ -s "$T/stdout" ]] && out+=" stdout!"
    echo "$out"
}
RANG="0 rang"; SILENT="0 silent"

printf '\nthe trigger: a **Waiting on you** line\n'
check "no Waiting-on-you block: silent"        "$(ring_or_silent "$(payload "$NO_ASK" "$T/turn40.jsonl")")" "$SILENT"
check "a **Waiting on you** block: rings"      "$(ring_or_silent "$(payload "$ASK" "$T/turn40.jsonl")")" "$RANG"
check "...with the request sound as the only argument" "$(tr '\n' '|' < "$PLAYED")" "$SOUND|"
check "**Waiting on you:** with a colon: rings" \
      "$(ring_or_silent "$(payload $'x\n**Waiting on you:** pick one' "$T/turn40.jsonl")")" "$RANG"
check "a '## Waiting on you' heading: rings" \
      "$(ring_or_silent "$(payload $'x\n## Waiting on you\n1. y' "$T/turn40.jsonl")")" "$RANG"
check "an indented **Waiting on you**: rings" \
      "$(ring_or_silent "$(payload $'x\n  **Waiting on you**' "$T/turn40.jsonl")")" "$RANG"
check "the phrase mid-sentence: silent" \
      "$(ring_or_silent "$(payload 'Nothing is **Waiting on you** now.' "$T/turn40.jsonl")")" "$SILENT"
check "plain 'Waiting on you' with no bold or heading: silent" \
      "$(ring_or_silent "$(payload $'x\nWaiting on you\n1. y' "$T/turn40.jsonl")")" "$SILENT"
check "a bold heading named something else: silent" \
      "$(ring_or_silent "$(payload $'x\n**Waiting on CI**' "$T/turn40.jsonl")")" "$SILENT"
check "no last_assistant_message at all: silent" "$(ring_or_silent "$(payload - "$T/turn40.jsonl")")" "$SILENT"
check "input that is not JSON: silent"         "$(ring_or_silent 'not json')" "$SILENT"

printf '\nguards\n'
check "outside herdr (HERDR_ENV unset): silent" \
      "$(ENV_HERDR="" ring_or_silent "$(payload "$ASK" "$T/turn40.jsonl")")" "$SILENT"
check "HERDR_ENV=0: silent" \
      "$(ENV_HERDR=0 ring_or_silent "$(payload "$ASK" "$T/turn40.jsonl")")" "$SILENT"
check "no HERDR_PANE_ID: silent" \
      "$(PANE="" ring_or_silent "$(payload "$ASK" "$T/turn40.jsonl")")" "$SILENT"
check "a stop-hook continuation: silent" \
      "$(ring_or_silent "$(payload "$ASK" "$T/turn40.jsonl" true)")" "$SILENT"
check "a teammate pane (herdr detects no agent): silent" \
      "$(REPLY="$TEAMMATE" ring_or_silent "$(payload "$ASK" "$T/turn40.jsonl")")" "$SILENT"
check "a pane detected as another agent: silent" \
      "$(REPLY="$OTHER_AGENT" ring_or_silent "$(payload "$ASK" "$T/turn40.jsonl")")" "$SILENT"
mv "$SOUND" "$SOUND.away"
check "no sound file to play: silent, still exit 0" \
      "$(ring_or_silent "$(payload "$ASK" "$T/turn40.jsonl")")" "$SILENT"
mv "$SOUND.away" "$SOUND"
chmod -x "$FAKE/config/herdr/shims/pw-play"
check "a player shim that is not executable: silent, still exit 0" \
      "$(ring_or_silent "$(payload "$ASK" "$T/turn40.jsonl")")" "$SILENT"
chmod +x "$FAKE/config/herdr/shims/pw-play"

printf '\nlikely away: not focused, OR a turn of at least 30 s\n'
check "not focused, a 2 s turn: rings (focus alone decides)" \
      "$(ring_or_silent "$(payload "$ASK" "$T/turn29.jsonl")")" "$RANG"
check "focused, a 29 s turn: silent" \
      "$(REPLY="$FOCUSED" ring_or_silent "$(payload "$ASK" "$T/turn29.jsonl")")" "$SILENT"
check "focused, a 30 s turn: rings" \
      "$(REPLY="$FOCUSED" ring_or_silent "$(payload "$ASK" "$T/turn30.jsonl")")" "$RANG"
check "focused: a tool result 5 s ago is not the turn start (40 s): rings" \
      "$(REPLY="$FOCUSED" ring_or_silent "$(payload "$ASK" "$T/turn40.jsonl")")" "$RANG"
check "focused: a prompt sent as text blocks counts as typed (40 s): rings" \
      "$(REPLY="$FOCUSED" ring_or_silent "$(payload "$ASK" "$T/blocks40.jsonl")")" "$RANG"
check "focused: a meta entry 5 s ago is not the turn start (40 s): rings" \
      "$(REPLY="$FOCUSED" ring_or_silent "$(payload "$ASK" "$T/meta40.jsonl")")" "$RANG"
check "focused: a half-written last line does not hide a 10 s turn: silent" \
      "$(REPLY="$FOCUSED" ring_or_silent "$(payload "$ASK" "$T/torn.jsonl")")" "$SILENT"
check "HERDR_BELL_AWAY_AFTER_SECONDS=60, focused, 40 s: silent" \
      "$(AWAY=60 REPLY="$FOCUSED" ring_or_silent "$(payload "$ASK" "$T/turn40.jsonl")")" "$SILENT"
check "HERDR_BELL_AWAY_AFTER_SECONDS=20, focused, 29 s: rings" \
      "$(AWAY=20 REPLY="$FOCUSED" ring_or_silent "$(payload "$ASK" "$T/turn29.jsonl")")" "$RANG"
check "a non-numeric threshold falls back to 30 (focused, 29 s): silent" \
      "$(AWAY=abc REPLY="$FOCUSED" ring_or_silent "$(payload "$ASK" "$T/turn29.jsonl")")" "$SILENT"
check "a non-numeric threshold falls back to 30 (focused, 40 s): rings" \
      "$(AWAY=abc REPLY="$FOCUSED" ring_or_silent "$(payload "$ASK" "$T/turn40.jsonl")")" "$RANG"

printf '\nfails OPEN: anything it cannot read rings\n'
check "herdr exits 1 with an error reply: rings" \
      "$(REPLY="$ERROR_REPLY" RC=1 ring_or_silent "$(payload "$ASK" "$T/turn29.jsonl")")" "$RANG"
check "herdr exits 0 with an error reply: rings (an error is not a teammate)" \
      "$(REPLY="$ERROR_REPLY" ring_or_silent "$(payload "$ASK" "$T/turn29.jsonl")")" "$RANG"
check "herdr prints something that is not JSON: rings" \
      "$(REPLY="panic" ring_or_silent "$(payload "$ASK" "$T/turn29.jsonl")")" "$RANG"
mv "$BIN/herdr" "$BIN/herdr.away"
check "herdr is not installed: rings" "$(ring_or_silent "$(payload "$ASK" "$T/turn29.jsonl")")" "$RANG"
mv "$BIN/herdr.away" "$BIN/herdr"
SECONDS=0
check "herdr hangs: rings" "$(HANG=1 ring_or_silent "$(payload "$ASK" "$T/turn29.jsonl")")" "$RANG"
check "...after the query timeout, not the hang (under 6 s)" "$(( SECONDS < 6 ))" 1
check "focused, but the transcript is missing: rings" \
      "$(REPLY="$FOCUSED" ring_or_silent "$(payload "$ASK" "$T/no-such.jsonl")")" "$RANG"
check "focused, but no typed prompt in the transcript: rings" \
      "$(REPLY="$FOCUSED" ring_or_silent "$(payload "$ASK" "$T/noprompt.jsonl")")" "$RANG"
check "focused, but no transcript_path given: rings" \
      "$(REPLY="$FOCUSED" ring_or_silent "$(jq -cn --arg m "$ASK" '{last_assistant_message:$m}')")" "$RANG"

printf '\nplays once, and does not wait for the player\n'
# The lock is held on this shell's own descriptor, not by a background `flock
# cmd`: killing that flock would leave its child holding the lock.
exec {lock_fd}>"$RUN/herdr-waiting-bell.lock"
flock "$lock_fd"
check "a bell already ringing (lock held): this one is coalesced" \
      "$(ring_or_silent "$(payload "$ASK" "$T/turn29.jsonl")")" "$SILENT"
exec {lock_fd}>&-
check "...and once it has finished, the next one rings" \
      "$(ring_or_silent "$(payload "$ASK" "$T/turn29.jsonl")")" "$RANG"
SECONDS=0
check "with the real setsid, the hook returns before a 3 s player finishes" \
      "$(SETSID_DIR="$REALSETSID" PLAYER_SLEEP=3 ring_or_silent "$(payload "$ASK" "$T/turn29.jsonl")")" "$SILENT"
check "...in under 2 s" "$(( SECONDS < 2 ))" 1
for _ in $(seq 1 50); do [[ -f "$PLAYED" ]] && break; sleep 0.1; done
check "...and the detached player still rings" "$([[ -f "$PLAYED" ]] && echo rang || echo silent)" rang

printf '\nconfig: herdr'"'"'s own "done" sound is muted, and everything is linked\n'
# Read from inside the [ui.sound] table only, up to the next table header.
done_path=$(sed -n '/^\[ui\.sound\]/,/^\[/s/^done_path[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
            "$ROOT/config/herdr/config.toml")
check "[ui.sound] done_path is the silent file" "$done_path" "sounds/silence.mp3"
check "...which exists in the repo, beside config.toml" \
      "$([[ -f "$ROOT/config/herdr/$done_path" ]] && echo yes || echo no)" yes
check "...and is an mp3 stream (ID3 tag or MPEG frame sync), not a placeholder" \
      "$(head -c 3 "$ROOT/config/herdr/$done_path" | od -An -tx1 | tr -d ' \n' | sed -E 's/^(494433|ff[ef].).*/mp3/')" mp3
check "the hook's own sound, config/herdr/sounds/request.mp3, is in the repo" \
      "$([[ -s "$ROOT/config/herdr/sounds/request.mp3" ]] && echo yes || echo no)" yes
# done_path is relative to the config.toml SYMLINK's directory, ~/.config/herdr,
# so without this link herdr reports "missing sound file" and the beep is back.
for conf in install.conf.yaml install.conf.herdr.yaml; do
    check "$conf links ~/.config/herdr/sounds" \
          "$(grep -c -F -x '    ~/.config/herdr/sounds: config/herdr/sounds' "$ROOT/$conf")" 1
    check "$conf links the hook" \
          "$(grep -c -F -x '    ~/.claude/hooks/herdr-waiting-bell.sh: claude/hooks/herdr-waiting-bell.sh' "$ROOT/$conf")" 1
done

echo
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))"
    FAIL=$((FAIL + 1))
fi
if (( FAIL )); then
    printf '\033[1;31m=== %d passed, %d failed ===\033[0m\n' "$PASS" "$FAIL"
    exit 1
fi
printf '\033[0;32m=== %d passed, %d failed ===\033[0m\n' "$PASS" "$FAIL"
