#!/usr/bin/env bash
#
# scripts/test-herdr-quiet.sh — state table for config/herdr/shims/pw-play and
# the herdr() wrapper in zsh/zshrc.herdr that puts it on the client's PATH.
#
# HERMETIC. gsettings and the real player are STUBS, and PATH never contains
# /usr/bin or /bin. On this machine both hold a real gsettings AND a real pw-play
# (/bin is a symlink to /usr/bin), so one stray directory would make every
# "plays" row play the host's player against the host's DND setting: a fixture
# that measures the developer's desktop instead of the branch it names. The
# shim's only other external command is dirname. It gets a tools directory of
# its own holding just that, linked from wherever the host keeps it.
#
# The shim is COPIED into the fixture, never linked: a row that replaced a
# linked file would write through the link into the repo (memory:
# test-fixture-symlink-truncates-the-sut).
#
# Every shim run goes through `timeout`, because the one failure that cannot
# print a wrong answer is an exec loop of the shim into itself. Without the
# timeout, that row would hang the suite rather than fail.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SUT="$ROOT/config/herdr/shims/pw-play"
LAYER="$ROOT/zsh/zshrc.herdr"

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

[[ -r "$SUT" && -x "$SUT" ]] || fatal "cannot run $SUT"
[[ -r "$LAYER" ]] || fatal "cannot read $LAYER"
command -v zsh >/dev/null 2>&1 || fatal "zsh is required"
TIMEOUT=$(command -v timeout) || fatal "timeout is required"
ZSH=$(command -v zsh)
DIRNAME=$(command -v dirname) || fatal "dirname is required"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
SHIMS="$T/shims"; REAL="$T/real"; GS="$T/gs"; TOOLS="$T/tools"; PLAYED="$T/played"
mkdir -p "$SHIMS" "$REAL" "$GS" "$TOOLS"
cp "$SUT" "$SHIMS/pw-play"
ln -s "$DIRNAME" "$TOOLS/dirname"
ln -s "$SHIMS" "$T/shimlink"            # a second spelling of the shim's own directory

# The real player: records each argument on its own line, exits PLAYER_RC.
cat > "$REAL/pw-play" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$PLAYED"
exit "${PLAYER_RC:-0}"
EOF
chmod +x "$REAL/pw-play"

# gsettings: prints GS_OUT, exits GS_RC. "missing" removes it.
set_gsettings() {
    if [[ "$1" == missing ]]; then rm -f "$GS/gsettings"; return; fi
    printf '#!/bin/sh\nprintf "%%s\\n" "%s"\nexit %s\n' "$1" "$2" > "$GS/gsettings"
    chmod +x "$GS/gsettings"
}

# $1 PATH for the shim; rest = arguments. Prints the shim's exit status.
# PLAYED is reset first, so "absent" below means THIS run did not play.
run_shim() {
    local path="$1"; shift
    rm -f "$PLAYED"
    env -i PATH="$path" PLAYED="$PLAYED" PLAYER_RC="${PLAYER_RC:-0}" \
        "$TIMEOUT" 5 "$SHIMS/pw-play" "$@" >/dev/null 2>"$T/stderr"
    echo $?
}
played() { if [[ -f "$PLAYED" ]]; then tr '\n' '|' < "$PLAYED"; else echo absent; fi; }

STD="$SHIMS:$GS:$TOOLS:$REAL"

printf '\nDo Not Disturb ON: nothing plays\n'
set_gsettings false 0
check "exits 0"                          "$(run_shim "$STD" /s/done.mp3)" 0
check "the real player never ran"        "$(played)" absent
# Silenced BEFORE the player lookup: with no player anywhere it is still a quiet 0, not a 127.
check "silenced before looking for a player" "$(run_shim "$SHIMS:$GS:$TOOLS" /s/done.mp3)" 0

printf '\nDo Not Disturb OFF: the real player runs with every argument unchanged\n'
set_gsettings true 0
check "exits 0"                          "$(run_shim "$STD" --volume=0.5 "a b" /s/done.mp3)" 0
check "arguments verbatim, spaces kept"  "$(played)" "--volume=0.5|a b|/s/done.mp3|"
check "the player's exit status is the shim's" "$(PLAYER_RC=3 run_shim "$STD" x)" 3

printf '\nfails OPEN: anything but exactly "false" plays\n'
set_gsettings "" 1
check "gsettings failing: exits 0"       "$(run_shim "$STD" x)" 0
check "gsettings failing: played"        "$(played)" "x|"
set_gsettings missing
check "gsettings missing: played"        "$(run_shim "$STD" x; played)" "$(printf '0\nx|')"
set_gsettings FALSE 0
check "an unexpected value: played"      "$(run_shim "$STD" x; played)" "$(printf '0\nx|')"
# The same command, answering `false` but failing: the shim reads the answer.
set_gsettings false 1
check "false with a failing exit: silent" "$(run_shim "$STD" x; played)" "$(printf '0\nabsent')"

printf '\nfinding the real player\n'
set_gsettings true 0
check "own directory listed twice (one a symlink): no loop, real one plays" \
      "$(run_shim "$T/shimlink:$SHIMS:$GS:$TOOLS:$REAL" x; played)" "$(printf '0\nx|')"
check "empty PATH entries are skipped"   "$(run_shim "$SHIMS::$GS:$TOOLS::$REAL" x; played)" "$(printf '0\nx|')"
check "no real player: 127"              "$(run_shim "$SHIMS:$GS:$TOOLS" x)" 127
check "no real player: says so"          "$(grep -c 'no real pw-play' "$T/stderr")" 1
check "no real player: nothing played"   "$(played)" absent
# A directory holding a NON-executable pw-play is passed over, not exec'd into an error.
mkdir -p "$T/noexec"; printf '#!/bin/sh\n' > "$T/noexec/pw-play"; chmod -x "$T/noexec/pw-play"
check "a non-executable pw-play is skipped" "$(run_shim "$SHIMS:$GS:$TOOLS:$T/noexec:$REAL" x; played)" "$(printf '0\nx|')"

# --- the wrapper -------------------------------------------------------------
# A stub `herdr` prints the first PATH entry it was given, then its arguments,
# and exits HERDR_RC. zsh runs with -f and env -i, so no rc file reaches it.
BIN="$T/bin"; FAKE="$T/root"
mkdir -p "$BIN" "$FAKE/config/herdr/shims"
cat > "$BIN/herdr" <<'EOF'
#!/bin/sh
printf '%s\n' "${PATH%%:*}" "$@"
exit "${HERDR_RC:-0}"
EOF
chmod +x "$BIN/herdr"
wrap() {  # $1 DOTFILES_ROOT, rest = arguments to herdr
    local root="$1"; shift
    env -i HOME="$T" PATH="$BIN:$TOOLS" DOTFILES_ROOT="$root" HERDR_RC="${HERDR_RC:-0}" \
        "$ZSH" -f -c "source '$LAYER' >/dev/null 2>&1; herdr \"\$@\"" herdr "$@" 2>/dev/null
}

printf '\nthe herdr() wrapper in zsh/zshrc.herdr\n'
check "herdr is a function after sourcing the layer" \
      "$(env -i HOME="$T" PATH="$BIN" "$ZSH" -f -c "source '$LAYER' >/dev/null 2>&1; whence -w herdr" 2>/dev/null)" \
      "herdr: function"
check "puts the shims directory first on PATH" "$(wrap "$FAKE" | head -1)" "$FAKE/config/herdr/shims"
check "without that directory, PATH is left alone" "$(wrap "$T/nowhere" | head -1)" "$BIN"
check "arguments pass through verbatim" "$(wrap "$FAKE" pane list "a b" | tail -n +2 | tr '\n' '|')" "pane|list|a b|"
check "...and without the shims directory too" \
      "$(wrap "$T/nowhere" pane list "a b" | tail -n +2 | tr '\n' '|')" "pane|list|a b|"
check "herdr's exit status is the wrapper's" "$(HERDR_RC=4 wrap "$FAKE" >/dev/null; echo $?)" 4

# End to end, against the REPO's shim directory: the wrapper's PATH makes a
# client that runs `pw-play` reach the shim, which obeys the stubbed DND.
cat > "$BIN/herdr" <<'EOF'
#!/bin/sh
pw-play /s/request.mp3
EOF
chmod +x "$BIN/herdr"
e2e() {
    rm -f "$PLAYED"
    env -i HOME="$T" PATH="$BIN:$GS:$TOOLS:$REAL" DOTFILES_ROOT="$ROOT" PLAYED="$PLAYED" \
        "$TIMEOUT" 5 "$ZSH" -f -c "source '$LAYER' >/dev/null 2>&1; herdr" >/dev/null 2>&1
    played
}
set_gsettings false 0
check "end to end, DND on: the client's sound is silenced" "$(e2e)" absent
set_gsettings true 0
check "end to end, DND off: the client's sound plays"      "$(e2e)" "/s/request.mp3|"

# --- the row total, and the count this suite is documented as running --------
# Same contract as scripts/test-buildlimits.sh: the total catches a row that
# VANISHED, and docs_claim pins the documented count to it with a FIXED needle.
EXPECTED_ROWS=27

docs_claim() {
  local f="$ROOT/$1"
  [[ -r "$f" ]] || { printf 'cannot read %s' "$1"; return; }
  tr -s '[:space:]' ' ' <"$f" \
    | grep -c -F "\`scripts/test-herdr-quiet.sh\` ($EXPECTED_ROWS checks"
}

printf '\nthe count this suite is documented as running\n'
check "docs/HERDR_GUIDE.md says $EXPECTED_ROWS checks" "$(docs_claim docs/HERDR_GUIDE.md)" 1
check "a documented file that cannot be read is not a pass" \
      "$(docs_claim no/such/file.md)" "cannot read no/such/file.md"

if (( PASS + FAIL != EXPECTED_ROWS )); then
  printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
    "$EXPECTED_ROWS" "$((PASS + FAIL))"
  FAIL=$((FAIL + 1))
fi

echo
if (( FAIL )); then
    printf '\033[1;31m=== %d passed, %d failed ===\033[0m\n' "$PASS" "$FAIL"
    exit 1
fi
printf '\033[0;32m=== %d passed, %d failed ===\033[0m\n' "$PASS" "$FAIL"
