#!/usr/bin/env bash
#
# claude/hooks/secret-emission-guard.sh
# =====================================
#
# Claude Code PreToolUse hook (matcher: Bash). Refuses the handful of commands
# that PRINT credentials, unless their output is piped through
# scripts/redact-secrets.sh.
#
# Why: on 2026-09-01 both of this machine's live GitHub tokens were found in
# plaintext in five session transcripts, two written days earlier. Transcripts
# are conversation context, so the values had left the host as well. No single
# dramatic mistake — just ordinary diagnostics (`ps` on a process started with
# `-e GH_TOKEN=…`, a `printf` of `$GH_TOKEN`, a bare `gh auth token`), and
# everything printed is recorded. Rotation does not fix that: it is manual,
# browser-only for GitHub, and undone by the next capture.
#
# DENY, not ask. This fires on a small set of command shapes an agent runs while
# investigating, and the remedy is mechanical (add ` | redact-secrets`), so a
# prompt would only train the human to click through. `ask` would also make the
# guard the most annoying thing on the machine, and an annoying guard gets
# deleted — which is the failure mode every checker in this repo is written
# against.
#
# FAIL OPEN. Any error here — bad JSON, missing jq, an unreadable payload —
# allows the command. A hook that blocks the shell when it breaks is a hook that
# gets disabled wholesale, taking its protection with it. The cost of failing
# open is a missed redaction; the cost of failing closed is no guard at all.
#
# SCOPE, stated plainly so nobody mistakes it for a boundary: this stops the
# CAPTURES THAT KEEP HAPPENING, not a determined leak. Any command can print a
# secret, and this knows about six shapes. It is a papercut guard, and the real
# fixes are shorter-lived credentials and narrower scopes.
#
# Contract: reads the hook payload on stdin, writes a permissionDecision JSON on
# stdout. https://docs.claude.com/en/docs/claude-code/hooks

set -uo pipefail

allow() { exit 0; }   # silence == allow

command -v jq >/dev/null 2>&1 || allow

payload="$(cat)" || allow
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)" || allow
[[ -n "$cmd" ]] || allow

# Already routed through the redactor (by name, so either the repo path or the
# ~/.local/bin symlink counts) — nothing to do.
[[ "$cmd" == *redact-secrets* ]] && allow

# Strip quoted strings before matching, so a command that merely MENTIONS one of
# these shapes in a message or a grep pattern is not refused. Without this the
# guard blocks `git commit -m "stop ps from leaking"`, which is the kind of
# false positive that gets a hook turned off.
probe="$(printf '%s' "$cmd" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")"

why=""
case "$probe" in
  # Prints a token to stdout. That is its entire purpose.
  *"gh auth token"*)                 why="\`gh auth token\` prints a credential" ;;
  *"gh auth status"*--show-token*)   why="\`gh auth status --show-token\` prints a credential" ;;
esac
if [[ -z "$why" ]]; then
  # Full command lines of other processes: /proc/<pid>/cmdline is world-readable
  # and routinely contains `-e VAR=<secret>` from whatever launched a daemon.
  # Narrow on purpose — `ps -o comm=` and `ps -p N` show no arguments and are
  # not matched.
  if [[ "$probe" =~ (^|[|;&[:space:]])ps([[:space:]]+-[A-Za-z]*[efl][A-Za-z]*|[[:space:]]+aux|[[:space:]]+-o[[:space:]]*[^|;&]*(args|cmd|command)) ]]; then
    why="\`ps\` with full command lines can show another process's secrets"
  elif [[ "$probe" =~ (^|[|;&[:space:]])pgrep([[:space:]]+-[A-Za-z]*a|[[:space:]]+--list-full) ]]; then
    why="\`pgrep -a\` prints full command lines"
  # A bare dump. `env VAR=x cmd` and `env -u VAR cmd` SET the environment for a
  # child and print nothing — they must not be caught, and are not.
  elif [[ "$probe" =~ (^|[|;&[:space:]])(env|printenv)[[:space:]]*($|[|;&]) ]]; then
    why="a bare \`${BASH_REMATCH[2]}\` dumps every variable, including exported tokens"
  elif [[ "$probe" == */proc/*cmdline* || "$probe" == */proc/*environ* ]]; then
    why="/proc command lines and environments contain other processes' secrets"
  # Reading a file that HOLDS credentials, which every rule above misses: they
  # all match a command that prints a secret it fetched, not one that prints a
  # file. CLAUDE.md's Security Rules send every secret on the machine to
  # ~/.zshrc.local, so this guard covered every emission shape except the
  # documented home of all of them. On 2026-09-07 a `tail -8 ~/.zshrc.local`,
  # run to find where to append a PATH line, put a live LINEAR_API_KEY and a
  # NOTION_PAT into a transcript. Same class as the incident that created this
  # hook; this rule is that gap closed.
  #
  # TWO conditions, and the split between them is load-bearing:
  #
  #   the PATH matches on "$cmd", the RAW command, because $probe has had quoted
  #   strings stripped -- and `cat "$HOME/.zshrc.local"` is the most natural way
  #   to write it, so matching the path on $probe would miss exactly that.
  #
  #   the VERB matches on $probe, and both must hold. Path-alone on the raw
  #   command refuses `git commit -m "move flyctl out of zshrc.local"` -- a
  #   message merely NAMING the file -- which is precisely the false positive
  #   this file's header says costs the whole guard.
  #
  # Metadata-only commands (ls, stat, test -f, readlink) print no content and are
  # deliberately not verbs here. A python3 heredoc that opens the file is not
  # caught either: it prints nothing by default, and blocking it would refuse
  # ordinary edits to the very file people are told to put their secrets in.
  elif [[ "$cmd" =~ (\.zshrc\.local|\.gitconfig\.local|\.backup\.local|\.credentials\.json) ]] \
     && [[ "$probe" =~ (^|[|;\&[:space:]])(cat|tac|head|tail|less|more|bat|batcat|nl|od|xxd|strings|grep|egrep|fgrep|rg|sed|awk|source|\.)([[:space:]]|$) ]]; then
    why="\`${BASH_REMATCH[2]}\` on a file that holds credentials (CLAUDE.md sends every secret to ~/.zshrc.local)"
  fi
fi

[[ -n "$why" ]] || allow

jq -n --arg why "$why" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ($why + ". Pipe it through the redactor: `<command> 2>&1 | ~/.dotfiles/scripts/redact-secrets.sh`. Everything printed here is recorded in the session transcript, which is why this is refused rather than warned about.")
  }
}'
