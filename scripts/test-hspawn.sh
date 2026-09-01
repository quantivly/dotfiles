#!/usr/bin/env bash
#
# scripts/test-hspawn.sh
# ======================
#
# State table for the hspawn / hdespawn / hreap family in zsh/zshrc.company.
#
# Why this exists: these three commands create worktrees, type into agent panes
# and DELETE worktrees, and every failure mode found in them so far was silent —
# a spawn that returned 0 with its agent parked on a dialog, a registry entry
# overwritten without a word, a `--yes` refusal over commits that were already
# pushed, a census that quietly undercounted. None of that shows up as an error,
# so each way it can be wrong is a row here.
#
# HERMETIC, and deliberately so in one specific way: a `herdr` STUB is put at
# the front of PATH for every single run. Not "no herdr on PATH" — this box has
# a real one at ~/.local/bin/herdr talking to a live server with ten agent
# sessions in it, and hdespawn's whole job is to remove workspaces. A suite that
# depended on `herdr` being absent would pass on a CI runner and destroy a
# workspace on the machine the code was written on. The stub records every
# invocation and answers from canned JSON; the snapshots and process-info
# replies are shapes recorded from herdr 0.8.2 (`herdr api schema --json`).
#
# The git rows use a throwaway repo with a real bare "origin", because the
# unpushed-commit count is the guard that decides whether a worktree is removed
# and the 2026-08-31 overcount bug lived exactly in which refs it compared.
#
# Requires: zsh, bash, git, jq. No sudo, no network, no herdr, no real panes.
#
# Usage: scripts/test-hspawn.sh

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPANY="$DOTFILES/zsh/zshrc.company"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

for tool in zsh git jq; do
    command -v "$tool" >/dev/null || fatal "$tool is required"
done
[[ -r "$COMPANY" ]] || fatal "cannot read $COMPANY"

# Assert the functions under test are actually DEFINED before asserting on their
# behaviour. Most rows below are "nothing was created / nothing was removed",
# which is also exactly what a suite that loaded nothing produces.
for fn in hspawn hdespawn hreap _hspawn_shell_ready _hspawn_preserve_stale_registry \
          _hspawn_registry_file _hreap_fmt_dur _hreap_fmt_kb; do
    zsh -c "source '$COMPANY' >/dev/null 2>&1; (( \$+functions[$fn] ))" \
        || fatal "$fn is not defined after sourcing $COMPANY — the suite would assert nothing"
done

FHOME="$TMPROOT/home";    mkdir -p "$FHOME/.clauth/profiles/personal"
STUBBIN="$TMPROOT/bin";   mkdir -p "$STUBBIN"
STUBDIR="$TMPROOT/stub";  mkdir -p "$STUBDIR"
STATE="$TMPROOT/state";   mkdir -p "$STATE"
LOG="$TMPROOT/herdr.log"

#-----------------------------------------------------------------------------
# The herdr stub
#-----------------------------------------------------------------------------
cat > "$STUBBIN/herdr" <<'STUB'
#!/bin/sh
# Fake `herdr` for scripts/test-hspawn.sh. Records every invocation, answers a
# handful of subcommands from canned JSON. CMD is the whole line (readable);
# ARG is one line per argument, which is what the (@q) quoting rows assert on —
# a mangled command string differs from a correct one only in where the argument
# boundaries fall.
{
    printf 'CMD %s\n' "$*"
    for a in "$@"; do printf 'ARG %s\n' "$a"; done
} >> "$HERDR_STUB_LOG"
case "${HERDR_STUB_MODE:-full}" in
    dead) exit 1 ;;                       # every call fails: "no herdr here"
    fail-create)
        if [ "$1 $2" = "worktree create" ]; then
            echo '{"error":{"code":"stub","message":"stub refuses"}}' >&2
            exit 1
        fi ;;
esac
case "$1 $2" in
    "worktree create")   cat "$HERDR_STUB_DIR/worktree-create.json" ;;
    "pane process-info") cat "$HERDR_STUB_DIR/process-info.json" ;;
    "agent get")         cat "$HERDR_STUB_DIR/agent-get.json" ;;
    "api snapshot")      [ -f "$HERDR_STUB_DIR/snapshot.json" ] && cat "$HERDR_STUB_DIR/snapshot.json" || exit 1 ;;
    "worktree list")     exit 1 ;;
esac
exit 0
STUB
chmod +x "$STUBBIN/herdr"

WT="$TMPROOT/wt/tester-slug"
cat > "$STUBDIR/worktree-create.json" <<JSON
{"result":{"workspace":{"workspace_id":"wZ"},"tab":{},"root_pane":{"pane_id":"wZ:p1"},
 "worktree":{"path":"$WT"}}}
JSON
# Recorded from a live pane sitting at a zsh prompt (2026-09-01, herdr 0.8.2):
# the foreground process GROUP is the shell itself.
cat > "$STUBDIR/process-info.json" <<'JSON'
{"result":{"process_info":{"pane_id":"wZ:p1","shell_pid":2922200,
 "foreground_process_group_id":2922200,
 "foreground_processes":[{"pid":2922200,"name":"zsh","argv":["/usr/bin/zsh"],"cwd":"/tmp"}]}}}
JSON
cat > "$STUBDIR/agent-get.json" <<'JSON'
{"result":{"agent":{"agent_status":"idle","name":"slug"}}}
JSON

REPO="$TMPROOT/repo"
mkdir -p "$REPO"

# $1 = zsh code. Runs it with the fixture environment and the stub on PATH.
OUT=""; RC=0
run() {
    : > "$LOG"
    OUT="$(HOME="$FHOME" PATH="$STUBBIN:$PATH" HSPAWN_STATE_DIR="$STATE" \
           HSPAWN_BRANCH_PREFIX=tester HERDR_STUB_LOG="$LOG" HERDR_STUB_DIR="$STUBDIR" \
           HERDR_STUB_MODE="${MODE:-full}" CLAUDE_CODE_SESSION_ID="${SESS:-}" \
           zsh -c "source '$COMPANY' >/dev/null 2>&1; $1" 2>&1)"
    RC=$?
}
# grep -c over the captured output / the stub log, always returning a number.
inout()  { grep -cF -- "$1" <<<"$OUT" || true; }
inargs() { grep -cFx -- "ARG $1" "$LOG" || true; }
incmd()  { grep -cF -- "CMD $1" "$LOG" || true; }
# The work summary, anchored to its own line: the same sentence is repeated
# inside the --yes refusal, so an unanchored count is 2 and an assertion written
# as "at least one" would pass on either line, including the wrong one.
inwork() { grep -cE "^work: +$1" <<<"$OUT" || true; }

echo "=== _hspawn_shell_ready: is the pane's shell at its prompt? ==="
# The pids are real, recorded from live panes. The predicate replaced a
# hardcoded five-name shell list that made readiness UNREACHABLE for any other
# shell — hspawn then aborted at 60 s with the worktree, workspace and registry
# entry already created.
ready() { run "_hspawn_shell_ready '$1'"; printf '%s' "$OUT"; }
check "shell in the fg group -> ready" \
      "$(ready '{"result":{"process_info":{"shell_pid":2922200,"foreground_process_group_id":2922200,"foreground_processes":[{"name":"zsh"}]}}}')" "true"
check "claude in the fg group -> not ready" \
      "$(ready '{"result":{"process_info":{"shell_pid":2922445,"foreground_process_group_id":2927498,"foreground_processes":[{"name":"claude"}]}}}')" "false"
# The row the fix exists for: a shell nobody put in the list.
check "an exotic shell is still ready" \
      "$(ready '{"result":{"process_info":{"shell_pid":10,"foreground_process_group_id":10,"foreground_processes":[{"name":"nu"}]}}}')" "true"
# A pipeline: several processes in the fg group, none of them the shell.
check "a busy pipeline is not ready" \
      "$(ready '{"result":{"process_info":{"shell_pid":10,"foreground_process_group_id":44,"foreground_processes":[{"name":"grep"},{"name":"sed"}]}}}')" "false"
check "no pids: falls back to the name" \
      "$(ready '{"result":{"process_info":{"foreground_processes":[{"name":"bash"}]}}}')" "true"
check "no pids, two processes: not ready" \
      "$(ready '{"result":{"process_info":{"foreground_processes":[{"name":"bash"},{"name":"grep"}]}}}')" "false"
check "an empty reply is never ready" "$(ready '')" ""

echo
echo "=== hspawn: the argument parser (nothing calls herdr until it is done) ==="
MODE=fail-create
run "hspawn --profile= '$REPO' slug"
check "--profile= errors"            "$RC"                                  "1"
check "--profile= says why"          "$(inout "needs a non-empty value")"   "1"
# The important half: an empty profile must not fall through to the no-profile
# path, which the code's own comment says burns whatever account holds the
# global credentials. "It printed an error" is not that assertion — "it never
# reached herdr" is.
check "--profile= reaches no herdr"  "$(wc -l < "$LOG" | tr -d ' ')"        "0"
run "hspawn -p '' '$REPO' slug"
check "-p '' errors"                 "$RC"                                  "1"
check "-p '' reaches no herdr"       "$(wc -l < "$LOG" | tr -d ' ')"        "0"
run "hspawn -p"
check "-p with no value errors"      "$RC"                                  "1"
run "hspawn '$REPO'"
check "one positional -> usage"      "$RC"                                  "1"
check "usage names the twins"        "$(inout "Twins: hdespawn")"           "1"
run "hspawn -h"
check "--help exits 0"               "$RC"                                  "0"
run "hspawn --nonsense '$REPO' slug"
check "unknown option errors"        "$RC"                                  "1"
check "unknown option names it"      "$(inout "unknown option '--nonsense'")" "1"
run "hspawn '$TMPROOT/not-a-dir' slug"
check "missing repo dir errors"      "$RC"                                  "1"
check "missing repo reaches no herdr" "$(wc -l < "$LOG" | tr -d ' ')"       "0"
run "hspawn --mode bypassPermissions '$REPO' slug"
check "bypassPermissions refused"    "$RC"                                  "1"
check "refusal says unattended"      "$(inout "run unattended")"            "1"
check "bypassPermissions: no herdr"  "$(wc -l < "$LOG" | tr -d ' ')"        "0"
run "hspawn --mode nonsense '$REPO' slug"
check "unknown mode errors"          "$RC"                                  "1"
# The validator accepts `manual`; an error message that omits it sends the user
# to re-read --help for a value that was already right.
check "the mode error names manual"  "$(inout "auto, acceptEdits, plan, dontAsk, manual or default")" "1"
run "hspawn --name Bad '$REPO' slug"
check "--name Bad refused"           "$RC"                                  "1"
run "hspawn --name 9lives '$REPO' slug"
check "--name 9lives refused"        "$RC"                                  "1"
run "hspawn -b somebase '$REPO' slug"
check "-b reaches worktree create"   "$(inargs "--base")"                   "1"
check "-b passes its value"          "$(inargs "somebase")"                 "1"
check "no -b, no --base"             "$(run "hspawn '$REPO' slug"; inargs "--base")" "0"
check "the branch is prefix/slug"    "$(run "hspawn '$REPO' slug"; inargs "tester/slug")" "1"
check "the label is the slug"        "$(run "hspawn '$REPO' slug"; inargs "--label")"     "1"

echo
echo "=== hspawn: the deprecated positional [profile|-] slot, and -- ==="
MODE=full
run "hspawn '$REPO' slug personal a prompt"
check "legacy profile is taken"      "$(inout "deprecated: the positional")"  "1"
check "legacy profile runs clauth"   "$(inargs "clauth start personal --permission-mode auto")" "1"
check "legacy profile drops the slot" "$(inargs "a prompt")"                 "1"
run "hspawn '$REPO' slug - a prompt"
check "legacy - is taken"            "$(inout "deprecated: the positional")"  "1"
check "legacy - starts no clauth"    "$(incmd "pane run")"                    "0"
check "legacy - drops the slot"      "$(inargs "a prompt")"                   "1"
# `--` has to switch the slot OFF. It did not: the slot triggers on a literal
# "-", which is exactly the argument `--` exists to protect, so `--` printed a
# deprecation note the user had just opted out of and ate the dash.
run "hspawn -- '$REPO' slug - a prompt"
check "after --: no deprecation"     "$(inout "deprecated: the positional")"  "0"
check "after --: the dash survives"  "$(inargs "- a prompt")"                 "1"
run "hspawn -- '$REPO' slug personal a prompt"
check "after --: no legacy profile"  "$(incmd "pane run")"                    "0"
check "after --: profile word kept"  "$(inargs "personal a prompt")"          "1"
# Option parsing stops at the first positional, so a dash inside the prompt is
# prompt text and not an option.
run "hspawn '$REPO' slug Fix the -v flag"
check "a -v inside the prompt"       "$(inargs "Fix the -v flag")"            "1"
check "a -v is not an option"        "$(inout "unknown option")"              "0"
# --opt=value re-splits through `set -- ... \"\${(@)argv[2,-1]}\"`; the rows after
# the option have to survive that.
run "hspawn --profile=personal '$REPO' slug word1 word2"
check "--opt=value keeps later args" "$(inargs "word1 word2")"                "1"
check "--opt=value sets the profile" "$(inargs "clauth start personal --permission-mode auto")" "1"
check "--opt=value: no deprecation"  "$(inout "deprecated: the positional")"  "0"

echo
echo "=== hspawn: quoting the claude args for the shell \`pane run\` types into ==="
# MEMORY.md records this exact zsh trap. Inside double quotes zsh joins an array
# BEFORE applying (q), so \${(q)arr} yields ONE backslash-escaped word; \${arr[*]}
# joins without quoting and loses the argument boundaries. Only
# \${(j: :)\${(@q)arr}} quotes each element and then joins.
run "hspawn -p personal -m opus -e high '$REPO' slug"
check "plain args are not escaped" \
      "$(inargs "clauth start personal --permission-mode auto --model opus --effort high")" "1"
# The row that catches \${arr[*]}: a value with a space in it must arrive as ONE
# word at the far end, i.e. quoted, i.e. backslash-escaped here.
run "hspawn -p personal -m 'opus latest' '$REPO' slug"
check "a value with a space is quoted" \
      "$(inargs 'clauth start personal --permission-mode auto --model opus\ latest')" "1"
run "hspawn -p 'two words' '$REPO' slug"
check "the profile is quoted too" \
      "$(inargs 'clauth start two\ words --permission-mode auto')" "1"
# The no-profile path hands claude's args to `agent start` as real argv, where
# no quoting is involved and none must appear.
run "hspawn --mode default '$REPO' slug"
check "--mode default maps to manual" "$(inargs "manual")"                    "1"
check "agent start gets a bare arg"   "$(inargs "--permission-mode")"         "1"
run "hspawn '$REPO' ENG-1939"
check "the agent name is folded down" "$(inargs "eng-1939")"                  "1"
run "hspawn '$REPO' 9lives"
check "a digit-leading slug gets w-"  "$(inargs "w-9lives")"                  "1"
run "hspawn '$REPO' aaaaaaaaaabbbbbbbbbbccccccccccddddddddddd"
check "a long name is cut to 32"      "$(inargs "aaaaaaaaaabbbbbbbbbbccccccccccdd")" "1"

echo
echo "=== hspawn: a reused pane id must not clobber an un-torn-down entry ==="
# herdr allocates workspace ids from a short alphabet whose counter lives only
# in the running server, so a restart reissues them: this box's own server log
# has w4, w5, wN and wP each created twice in five days, and every new
# workspace's first pane is p1. The registry outlives restarts, so "wZ:p1" is
# not a unique key — and it was written with a bare `>`.
rm -f "$STATE"/*.json
cat > "$STATE/wZ_p1.json" <<'JSON'
{"pane_id":"wZ:p1","workspace_id":"wZ","branch":"tester/older","slug":"older",
 "repo":"/tmp/older","path":"/tmp/older-wt","created_at":"2026-08-30T10:00:00Z"}
JSON
run "hspawn '$REPO' slug"
stale_count() { find "$STATE" -maxdepth 1 -name 'wZ_p1.stale-*.json' | wc -l | tr -d ' '; }
check "the old entry is preserved"    "$(stale_count)"                                   "1"
check "it is the OLD one that moved"  "$(jq -r .slug "$STATE"/wZ_p1.stale-*.json)"       "older"
check "the new entry is written"      "$(jq -r .slug "$STATE/wZ_p1.json")"               "slug"
check "the clobber is reported"       "$(inout "pane id reused")"                        "1"
check "and names how to finish it"    "$(inout "hdespawn older")"                        "1"
# The preserved entry stays reachable by slug: hdespawn's scan globs *.json.
check "the archive keeps .json"       "$(find "$STATE" -maxdepth 1 -name 'wZ_p1.stale-*.json' -print | wc -l | tr -d ' ')" "1"
if [[ "$(id -u)" != "0" ]]; then
    rm -f "$STATE"/*.json; mkdir -p "$STATE/ro"
    cat > "$STATE/ro/wZ_p1.json" <<'JSON'
{"pane_id":"wZ:p1","workspace_id":"wZ","slug":"older"}
JSON
    chmod 500 "$STATE/ro"
    run "HSPAWN_STATE_DIR='$STATE/ro' _hspawn_preserve_stale_registry '$STATE/ro/wZ_p1.json'"
    check "an unmovable entry fails"   "$RC"                                             "1"
    check "and is NOT overwritten"     "$(jq -r .slug "$STATE/ro/wZ_p1.json")"            "older"
    chmod 700 "$STATE/ro"
else
    ok "unmovable-entry rows skipped (running as root)"; ok "(skipped)"
fi
rm -f "$STATE"/*.json

echo
echo "=== hdespawn: the at-risk guard, against a real git worktree ==="
# `dead` mode: every herdr call fails, which is the state after `hreap --close`
# (or a server restart) — the workspace is gone and hdespawn has to finish the
# teardown from disk alone. It is also the only mode that can be trusted not to
# touch a live server.
MODE=dead
git init -q --bare "$TMPROOT/origin.git"
git init -q "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REPO" remote add origin "$TMPROOT/origin.git"
git -C "$REPO" push -q origin HEAD:refs/heads/main
# One commit ahead of main, so a branch cut from here HAS a lead over main. That
# is the whole point: the fixed count asks "on no origin branch" and gets 0,
# while the bug's `origin/main..HEAD` gets 1 and refuses to remove the worktree.
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
# ONE BRANCH PER WORKTREE. git refuses to check the same branch out twice, and
# with that error swallowed the fixture silently produced no directory at all —
# at which point "the worktree dir is gone" passes because it was never there.
# (Found by mutation: reverting the fix under test did not fail that row.)
# Pushed WITHOUT -u: no upstream, which is the normal state of an hspawn branch.
for b in clean dirty ahead reused; do
    git -C "$REPO" branch -q "tester/$b" HEAD
    git -C "$REPO" push -q origin "tester/$b"
done
mkwt() {   # $1 = dir, $2 = slug; the branch is tester/<slug>
    git -C "$REPO" worktree add -q "$1" "tester/$2" \
        || fatal "fixture: could not create the worktree $1"
    [[ -d "$1" ]] || fatal "fixture: $1 was not created — every 'it is gone' row below would pass for free"
    cat > "$STATE/w${2}_p1.json" <<JSON
{"pane_id":"w$2:p1","workspace_id":"w$2","branch":"tester/$2","slug":"$2","repo":"$REPO",
 "path":"$1","created_at":"2026-09-01T10:00:00Z","creator_session":"sess-1"}
JSON
}

# Clean worktree on a branch that IS on origin, with no upstream configured.
# `rev-list HEAD --not --remotes=origin` counts 0; the old `origin/main..HEAD`
# counted this branch's lead over main and refused to remove it (2026-08-31).
mkwt "$TMPROOT/wt-clean" clean
run "hdespawn --yes clean"
check "a pushed branch counts 0"      "$(inwork "clean \(0 uncommitted, 0 not on any origin branch")" "1"
check "and is removed"                "$RC"                                              "0"
check "the worktree dir is gone"      "$([[ -d "$TMPROOT/wt-clean" ]] && echo yes || echo no)" "no"
check "the registry entry is gone"    "$([[ -f "$STATE/wclean_p1.json" ]] && echo yes || echo no)" "no"
check "the branch is NOT deleted"     "$(git -C "$REPO" branch --list tester/clean | wc -l | tr -d ' ')" "1"

# Dirty worktree: --yes alone must refuse and change nothing.
mkwt "$TMPROOT/wt-dirty" dirty
echo scratch > "$TMPROOT/wt-dirty/untracked.txt"
run "hdespawn --yes dirty"
check "--yes refuses dirty work"      "$RC"                                              "1"
check "it says what it refused"       "$(inout "refusing --yes")"                        "1"
check "it counts the dirty path"      "$(inwork "1 uncommitted path\(s\), 0 commit\(s\)")" "1"
check "the worktree dir survives"     "$([[ -d "$TMPROOT/wt-dirty" ]] && echo yes || echo no)" "yes"
check "the registry entry survives"   "$([[ -f "$STATE/wdirty_p1.json" ]] && echo yes || echo no)" "yes"
run "hdespawn --yes --force dirty"
check "--force removes it"            "$RC"                                              "0"
check "the dir is gone"               "$([[ -d "$TMPROOT/wt-dirty" ]] && echo yes || echo no)" "no"
check "the entry is gone"             "$([[ -f "$STATE/wdirty_p1.json" ]] && echo yes || echo no)" "no"

# A commit on no origin branch at all is at-risk, upstream or not.
mkwt "$TMPROOT/wt-ahead" ahead
git -C "$TMPROOT/wt-ahead" -c user.email=t@t -c user.name=t commit -q --allow-empty -m local
run "hdespawn --yes ahead"
check "an unpushed commit refuses"    "$RC"                                              "1"
check "it counts the commit"          "$(inwork "0 uncommitted path\(s\), 1 commit\(s\) not on any origin branch")" "1"
check "the dir survives"              "$([[ -d "$TMPROOT/wt-ahead" ]] && echo yes || echo no)" "yes"

echo
echo "=== hdespawn: the ways it must refuse to act at all ==="
run "hdespawn --yes ahead extra"
check "two targets refused"           "$RC"                                              "1"
check "it names both"                 "$(inout "got 'ahead' and 'extra'")"               "1"
check "and touched nothing"           "$([[ -d "$TMPROOT/wt-ahead" ]] && echo yes || echo no)" "yes"
run "hdespawn --yes"
check "no target -> usage"            "$RC"                                              "1"
run "hdespawn --yes no-such-slug"
check "unknown slug refused"          "$RC"                                              "1"
check "and names the registry"        "$(inout "no hspawn registry entry")"              "1"
: > "$STATE/empty_p1.json"
run "hdespawn --yes empty_p1"
check "a 0-byte entry refuses"        "$RC"                                              "1"
check "it says no workspace_id"       "$(inout "no workspace_id")"                       "1"
check "and keeps the file"            "$([[ -f "$STATE/empty_p1.json" ]] && echo yes || echo no)" "yes"
printf 'not json at all' > "$STATE/corrupt_p1.json"
run "hdespawn --yes corrupt_p1"
check "a corrupt entry refuses"       "$RC"                                              "1"
check "and keeps the file"            "$([[ -f "$STATE/corrupt_p1.json" ]] && echo yes || echo no)" "yes"
rm -f "$STATE/empty_p1.json" "$STATE/corrupt_p1.json"
# Two entries, one slug — which `hreap --close` manufactures by design, since it
# keeps the entry so hdespawn can finish later.
cat > "$STATE/dup1_p1.json" <<JSON
{"pane_id":"wD:p1","workspace_id":"wD","branch":"b1","slug":"dup","repo":"$REPO","path":"/tmp/x1"}
JSON
cat > "$STATE/dup2_p1.json" <<JSON
{"pane_id":"wD:p1","workspace_id":"wE","branch":"b2","slug":"dup","repo":"$REPO","path":"/tmp/x2"}
JSON
run "hdespawn --yes dup"
check "an ambiguous slug refuses"     "$RC"                                              "1"
check "it says how many matched"      "$(inout "matches 2 spawns")"                      "1"
# Both entries carry the SAME pane id here — reused, exactly as herdr reuses
# them — so the pane id disambiguates nothing and the FILE has to be named.
check "it names the first file"       "$(inout "dup1_p1.json")"                          "1"
check "it names the second file"      "$(inout "dup2_p1.json")"                          "1"
rm -f "$STATE/dup1_p1.json" "$STATE/dup2_p1.json"

echo
echo "=== hdespawn: @sh hardening — the registry is just a file on disk ==="
# The only eval on file content in this family. @sh single-quotes STRINGS only:
# an array becomes several bare shell words and a number one unquoted word, so
# every field is forced through tostring first.
cat > "$STATE/wS_p1.json" <<'JSON'
{"pane_id":1,"workspace_id":"wS","branch":["b","c"],"slug":["a","b"],
 "repo":"/tmp/no-such-repo","path":""}
JSON
run "hdespawn --yes wS:p1"
check "an array slug stays one word"  "$(inout 'hdespawn: ["a","b"]')"                    "1"
check "a numeric pane id survives"    "$(inout "pane:      1")"                           "1"
check "it finishes cleanly"           "$RC"                                               "0"

echo
echo "=== hdespawn: same id, different worktree ==="
# The id was reused while this entry was stranded. Refusing outright is safe but
# dead-ends: the entry's own worktree stays on disk and nothing will ever finish
# it. So the live workspace is disowned and the teardown continues from disk —
# and herdr must not be asked to remove anything.
MODE=full
mkwt "$TMPROOT/wt-reused" reused
cat > "$STUBDIR/snapshot.json" <<JSON
{"result":{"snapshot":{"workspaces":[{"workspace_id":"wreused","label":"other",
 "worktree":{"checkout_path":"/somewhere/else"}}],
 "panes":[{"pane_id":"wreused:p1","agent_status":"idle"}],"agents":[]}}}
JSON
run "hdespawn --yes reused"
check "the reuse is reported"         "$(inout "the id was reused")"                     "1"
check "no herdr worktree remove"      "$(incmd "worktree remove")"                       "0"
check "the recorded worktree is gone" "$([[ -d "$TMPROOT/wt-reused" ]] && echo yes || echo no)" "no"
check "the entry is dropped"          "$([[ -f "$STATE/wreused_p1.json" ]] && echo yes || echo no)" "no"
check "it exits 0"                    "$RC"                                              "0"
rm -f "$STUBDIR/snapshot.json"

echo
echo "=== hreap: the pure formatters and the flag refusals ==="
MODE=dead
fmtd() { run "_hreap_fmt_dur $1"; printf '%s' "$OUT"; }
fmtk() { run "_hreap_fmt_kb $1"; printf '%s' "$OUT"; }
check "dur 59"     "$(fmtd 59)"     "<1m"
check "dur 60"     "$(fmtd 60)"     "1m"
check "dur 3599"   "$(fmtd 3599)"   "59m"
check "dur 3600"   "$(fmtd 3600)"   "1h00m"
check "dur 86399"  "$(fmtd 86399)"  "23h59m"
check "dur 86400"  "$(fmtd 86400)"  "1d00h"
check "dur junk"   "$(fmtd nope)"   "?"
check "kb 1023"    "$(fmtk 1023)"   "1023K"
check "kb 1024"    "$(fmtk 1024)"   "1M"
check "kb 1048575" "$(fmtk 1048575)" "1023M"
check "kb 1048576" "$(fmtk 1048576)" "1.0G"
check "kb junk"    "$(fmtk nope)"   "?"
run "hreap --json --close"
check "--json --close refused"        "$RC"                                              "1"
check "it says why"                   "$(inout "read-only")"                             "1"
SESS="" run "hreap --mine"
check "--mine without a session id"   "$RC"                                              "1"
check "it names the variable"         "$(inout "CLAUDE_CODE_SESSION_ID")"                "1"
run "hreap --older abc"
check "--older abc refused"           "$RC"                                              "1"
run "hreap --nonsense"
check "an unknown flag refused"       "$RC"                                              "1"
run "hreap -h"
check "-h exits 0"                    "$RC"                                              "0"
check "-h warns about machine-wide"   "$(inout "machine-wide")"                          "1"

echo
echo "=== hreap: what it advertises after a --close ==="
# The line has to name the PANE ID. The registry is keyed on it, so that lookup
# is exact, while `hdespawn <slug>` scans and refuses when two entries share a
# slug — which is precisely what --close manufactures by keeping the entry.
# shellcheck disable=SC2016  # the literal string `$pane` is what is grepped for
check "close line uses the pane id" \
      "$(grep -c 'Finish with: hdespawn \$pane' "$COMPANY")"                             "1"
# shellcheck disable=SC2016  # ditto: a literal, not an expansion
check "close line does not use \$slug alone" \
      "$(grep -c 'Finish with: hdespawn \${rslug:-\$pane}' "$COMPANY")"                  "0"
# And the census must not swallow a pane it could not ask about.
check "a failed process-info is counted" \
      "$(grep -c 'unqueried++' "$COMPANY")"                                              "1"
check "and is reported in the totals" \
      "$(grep -c 'pane(s) that could not be queried' "$COMPANY")"                        "1"

echo
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
