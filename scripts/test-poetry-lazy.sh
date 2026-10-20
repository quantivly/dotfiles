#!/usr/bin/env bash
#
# scripts/test-poetry-lazy.sh — state table for zshrc's lazy `poetry()` wrapper
#
# WHY. Outside a Python project zshrc defines `poetry()`, which sources the
# oh-my-zsh poetry plugin on first use and then runs the real binary. Claude
# Code's shell snapshot copies that function into every Bash-tool shell, but not
# the non-exported $ZSH_CACHE_DIR. Since oh-my-zsh 95ba6ae (pulled 2026-10-02)
# the plugin runs `=( poetry completions zsh )` with TMPPREFIX under
# $ZSH_CACHE_DIR/completions, which is then `/completions/` — and zsh 5.9 aborts
# when `=( )` cannot create its temp file. The child is disowned, so nothing
# fails visibly: the only symptom was an apport "zsh crashed" popup, 50+ times
# from 2026-10-09. docs/TROUBLESHOOTING.md has the evidence.
#
# The rule pinned here: the plugin is sourced in an INTERACTIVE shell only, and
# the real poetry runs, with its arguments and exit status, either way.
#
# HERMETIC. The block is cut out of zshrc and run by `zsh -f`, so no rc file of
# the developer's reaches it. `poetry` is a STUB on a from-scratch PATH, and
# $ZSH is a fake oh-my-zsh whose poetry plugin only records that it was sourced,
# so a row reads "sourced or not" rather than racing a background crash.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SUT="$ROOT/zshrc"

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

[[ -r "$SUT" ]] || fatal "cannot read $SUT"
command -v zsh >/dev/null 2>&1 || fatal "zsh is required"
ZSH_BIN=$(command -v zsh)

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
BIN="$TMPROOT/bin"; OMZ="$TMPROOT/omz"; WORK="$TMPROOT/work"; LOG="$TMPROOT/sourced"
mkdir -p "$BIN" "$OMZ/plugins/poetry" "$WORK"

# The block, from `if command -v poetry` to its closing top-level `fi`. A cut
# that misses the wrapper is "could not run", never a pass. The anchors are the
# block's frame only: one on the wrapper's body made a mutant of that body exit
# 2 here instead of reaching a row.
BLOCK="$TMPROOT/block.zsh"
awk '/^if command -v poetry /{on=1} on{print} on && /^fi$/{exit}' "$SUT" > "$BLOCK"
if ! grep -q '^    poetry() {$' "$BLOCK" || [[ "$(tail -n 1 "$BLOCK")" != 'fi' ]]; then
    fatal "could not cut the poetry block out of $SUT"
fi

# Each arg bracketed, so a dropped empty arg or a split one shows.
cat > "$BIN/poetry" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '[%s]' "$a"; done; echo
exit "${STUB_RC:-0}"
EOF
chmod +x "$BIN/poetry"

printf 'print -r -- sourced >> %q\n' "$LOG" > "$OMZ/plugins/poetry/poetry.plugin.zsh"

# $1 "i" for an interactive shell, anything else for `zsh -c`; $2 the code to run
# after the block. Empty dir as cwd so the block takes its lazy branch.
run() {
    local flags=(-f); [[ "$1" == i ]] && flags+=(-i)
    rm -f "$LOG"
    (cd "$WORK" && env -i HOME="$TMPROOT" PATH="$BIN" ZSH="$OMZ" STUB_RC="${STUB_RC:-0}" \
        "$ZSH_BIN" "${flags[@]}" -c "source '$BLOCK'; $2" 2>/dev/null)
}
sourced() { if [[ -f "$LOG" ]]; then grep -c . "$LOG"; else echo 0; fi; }

echo "non-interactive (a Claude Code Bash-tool shell)"
check "the lazy wrapper is defined"            "$(run c 'whence -w poetry')"                  "poetry: function"
check "poetry runs the real command"           "$(run c 'poetry --version')"                  "[--version]"
run c 'poetry --version' >/dev/null
check "the plugin is NOT sourced"              "$(sourced)"                                   "0"
check "arguments pass through verbatim"        "$(run c "poetry run 'a b' ''")"               "[run][a b][]"
check "the exit status propagates"             "$(STUB_RC=3 run c 'poetry x >/dev/null; print $?')" "3"
check "the wrapper removes itself"             "$(run c 'poetry x >/dev/null; whence -w poetry')" "poetry: command"
run c 'poetry a | cat >/dev/null; poetry b | cat >/dev/null' >/dev/null
check "not sourced when each call is a pipeline" "$(sourced)"                                 "0"

echo "interactive"
run i 'poetry --version' >/dev/null
check "the plugin IS sourced, once"            "$(sourced)"                                   "1"
check "poetry runs the real command"           "$(run i 'poetry --version')"                  "[--version]"
check "the exit status propagates"             "$(STUB_RC=3 run i 'poetry x >/dev/null; print $?')" "3"

EXPECTED_ROWS=10
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '\033[1;31mFATAL\033[0m: expected %d rows, ran %d\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))" >&2
    exit 2
fi
echo
if (( FAIL )); then
    printf '\033[1;31m%d of %d checks failed\033[0m\n' "$FAIL" "$((PASS + FAIL))"
    exit 1
fi
printf '\033[0;32mall %d checks passed\033[0m\n' "$PASS"
