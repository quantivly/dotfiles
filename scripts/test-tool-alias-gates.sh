#!/usr/bin/env bash
#
# scripts/test-tool-alias-gates.sh — state table for the duf and cheat gates in
# zsh/zshrc.conditionals.tools (DO-848)
#
# WHY. zsh's `command -v NAME` is satisfied by an alias or a function of that
# name, not only by a binary. zshrc.aliases, which loads first, defined
# duf='du -sh *', so `if command -v duf` always passed and `df` became
# df -> duf -> du -sh *: a directory listing instead of disk usage, with or
# without duf installed. The tldr block's cheat='tldr' did the same to the
# cheat gate: with tldr alone, cs/csl/cse were defined and ran tldr.
#
# The rule pinned here: `df` runs duf when the duf binary is on PATH and the
# real df otherwise, and cs/csl/cse exist only for a real cheat binary and run
# it. Each row RUNS the command and reads which stub answered, so an alias that
# chains to the wrong binary fails even when the gate looks right.
#
# HERMETIC. zsh -f, env -i, and a from-scratch PATH holding only the stubs the
# row names, so no rc file or installed tool of the developer's reaches it. The
# two modules are sourced in zshrc's order (aliases, then conditionals.tools)
# from a probe file, because zsh parses a whole `-c` string before running it
# and an alias defined there would not expand on its later lines.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ALIASES="$ROOT/zsh/zshrc.aliases"
TOOLS="$ROOT/zsh/zshrc.conditionals.tools"

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

[[ -r "$ALIASES" && -r "$TOOLS" ]] || fatal "cannot read $ALIASES or $TOOLS"
command -v zsh >/dev/null 2>&1 || fatal "zsh is required"
ZSH_BIN=$(command -v zsh)

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# One stub, linked under each tool's name. It prints the name it was called by,
# then each argument bracketed: `df -h` -> df[-h].
STUBS="$TMPROOT/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/stub" <<'EOF'
#!/bin/sh
printf %s "${0##*/}"
for a in "$@"; do printf '[%s]' "$a"; done
echo
EOF
chmod +x "$STUBS/stub"
for name in df du duf tldr cheat; do ln -s stub "$STUBS/$name"; done

# $1 the space-separated stubs on PATH, $2 the code to run after both modules.
# AGENT=1 makes the row an agent shell. CLAUDECODE is never inherited: run from
# a Claude Code session it is set, and every row would silently be an agent row.
# PRELUDE is zsh run between the two modules, standing in for anything else
# that defines a same-named alias before the gates run.
run() {
    local bin probe name
    bin=$(mktemp -d "$TMPROOT/bin.XXXX"); probe="$bin.zsh"
    for name in $1; do ln -s "$STUBS/$name" "$bin/$name"; done
    printf 'source %q\n%s\nsource %q\n%s\n' "$ALIASES" "${PRELUDE:-}" "$TOOLS" "$2" > "$probe"
    (cd "$TMPROOT" && env -i HOME="$TMPROOT" PATH="$bin" CLAUDECODE="${AGENT:-}" \
        "$ZSH_BIN" -f "$probe" 2>/dev/null)
}

echo "duf not installed"
check "df runs the real df"                  "$(run 'df du' 'df')"               "df[-h]"
check "duf is not defined at all"            "$(run 'df du' 'whence -w duf')"    "duf: none"
check "a duf alias alone does not pass the gate" \
    "$(PRELUDE="alias duf='du -sh'" run 'df du' 'df')" "df[-h]"

echo "duf installed"
check "df runs duf"                          "$(run 'df du duf' 'df')"           "duf"
check "duf-json runs duf --json"             "$(run 'df du duf' 'duf-json')"     "duf[--json]"
check "an agent shell's df is the real df"   "$(AGENT=1 run 'df du duf' 'df')" "df"

echo "tldr installed, cheat not"
check "cheat falls back to tldr"             "$(run 'tldr' 'cheat x')"           "tldr[x]"
check "cs is not defined"                    "$(run 'tldr' 'whence -w cs')"      "cs: none"

echo "tldr and cheat installed"
check "cheat runs cheat"                     "$(run 'tldr cheat' 'cheat x')"     "cheat[x]"
check "cs runs cheat"                        "$(run 'tldr cheat' 'cs x')"        "cheat[x]"
check "csl runs cheat -l"                    "$(run 'tldr cheat' 'csl')"         "cheat[-l]"

echo "cheat installed, tldr not"
check "cs runs cheat"                        "$(run 'cheat' 'cs x')"             "cheat[x]"

echo "neither installed"
check "cs is not defined"                    "$(run '' 'whence -w cs')"          "cs: none"

EXPECTED_ROWS=13
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
