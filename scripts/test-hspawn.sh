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
# DO-555 moved the herdr layer out of zshrc.company into its own file so it
# can be adopted without the work-specific half. This suite follows it.
HERDRRC="$DOTFILES/zsh/zshrc.herdr"
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
[[ -r "$HERDRRC" ]] || fatal "cannot read $HERDRRC"

# Assert the functions under test are actually DEFINED before asserting on their
# behaviour. Most rows below are "nothing was created / nothing was removed",
# which is also exactly what a suite that loaded nothing produces.
for fn in hspawn hdespawn hreap _hspawn_shell_ready _hspawn_preserve_stale_registry \
          _hspawn_registry_file _hreap_fmt_dur _hreap_fmt_kb; do
    zsh -c "source '$HERDRRC' >/dev/null 2>&1; (( \$+functions[$fn] ))" \
        || fatal "$fn is not defined after sourcing $HERDRRC — the suite would assert nothing"
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
# Per-pane replies. HERDR_STUB_PANE_DIR is the hreap-scan mode: `pane
# process-info` and `pane get` are answered per pane id, and a MISSING
# process-info file is a FAILED call — which is the only way to drive hreap's
# `unqueried` counter, and therefore the only way to tell its census apart from
# one that silently drops a pane it could not ask about. Unset (every hspawn
# row) the single canned reply is served instead: those rows have one pane and
# call process-info many times.
pane_file() {  # $1 = kind, $2 = pane id
    printf '%s/%s-%s.json' "$HERDR_STUB_PANE_DIR" "$1" "$(printf '%s' "$2" | tr ':' '_')"
}
case "$1 $2" in
    "worktree create")   cat "$HERDR_STUB_DIR/worktree-create.json" ;;
    "pane process-info")
        if [ -n "${HERDR_STUB_PANE_DIR:-}" ]; then
            f="$(pane_file procinfo "$4")"      # ... process-info --pane <id>
            [ -f "$f" ] || exit 1
            cat "$f"
        else
            cat "$HERDR_STUB_DIR/process-info.json"
        fi ;;
    "pane get")
        if [ -n "${HERDR_STUB_PANE_DIR:-}" ]; then
            # A pane herdr will not answer about. Distinct from "it answered
            # 'working'": the close loop has to tell those two apart.
            [ -f "$HERDR_STUB_PANE_DIR/getfail-$(printf '%s' "$3" | tr ':' '_')" ] && exit 1
            f="$(pane_file get "$3")"           # ... pane get <id>
            [ -f "$f" ] || f="$HERDR_STUB_PANE_DIR/get-default.json"
            [ -f "$f" ] || exit 1
            cat "$f"
        fi ;;
    "pane close")
        if [ -f "$HERDR_STUB_DIR/close-fails" ]; then
            echo "stub: refusing to close $3" >&2
            exit 1
        fi ;;
    "agent get")         cat "$HERDR_STUB_DIR/agent-get.json" ;;
    "agent read")        [ -f "$HERDR_STUB_DIR/agent-read.txt" ] && cat "$HERDR_STUB_DIR/agent-read.txt" ;;
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
           HERDR_STUB_PANE_DIR="${PANEDIR:-}" \
           zsh -c "source '$HERDRRC' >/dev/null 2>&1; $1" 2>&1)"
    RC=$?
}
# grep -c over the captured output / the stub log, always returning a number.
inout()  { grep -cF -- "$1" <<<"$OUT" || true; }
inargs() { grep -cFx -- "ARG $1" "$LOG" || true; }
incmd()  { grep -cF -- "CMD $1" "$LOG" || true; }
# Every herdr call the run made, deduplicated, sorted, `|`-joined — the whole
# set rather than a count of one command. A count only refuses the failure you
# thought of: `incmd "worktree remove"` is 0 both when hdespawn correctly left a
# foreign workspace alone and when it destroyed it via some other subcommand.
# The set names what DID run, so any extra call fails the row.
herdrcmds() { sed -n 's/^CMD //p' "$LOG" | sort -u | paste -sd'|' -; }
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
# The SLUG is correct here and the pane id would be wrong: both files carry this
# pane id, and hdespawn resolves a pane id to the live <pane>.json, so the pane
# form would finish the NEW spawn. Pinned so a future "convert everything to the
# pane id" sweep has to read the reasoning before changing it.
check "it does NOT advertise the pane" "$(inout "hdespawn wZ:p1")"                  "0"
check "the ambiguous case is named"    "$(inout "matches 2 spawns")"                "1"
# The preserved entry stays reachable by slug: hdespawn's scan globs *.json.
check "the archive keeps .json"       "$(find "$STATE" -maxdepth 1 -name 'wZ_p1.stale-*.json' -print | wc -l | tr -d ' ')" "1"

# H5: the helper is pinned in isolation above and the happy path is pinned, but
# the WIRING was not — a mutation making hspawn ignore this helper's failure
# passed 126/126. That is the F6 defect class in a new function: a status that
# propagates nowhere. Force the unmovable-entry state and assert hspawn's own
# exit code, which is the thing no row asserted.
if [[ "$(id -u)" != "0" ]]; then
    rm -f "$STATE"/*.json
    cat > "$STATE/wZ_p1.json" <<'JSON'
{"pane_id":"wZ:p1","workspace_id":"wZ","slug":"older"}
JSON
    chmod 500 "$STATE"
    run "hspawn '$REPO' slug"
    chmod 700 "$STATE"
    check "unmovable entry: hspawn fails" "$([[ $RC -ne 0 ]] && echo yes || echo no)"  "yes"
    check "unmovable entry: says why"     "$(inout "NOT overwriting it")"              "1"
    check "unmovable entry: entry intact" "$(jq -r .slug "$STATE/wZ_p1.json" 2>/dev/null)" "older"
    rm -f "$STATE"/*.json
fi
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
for b in clean dirty ahead reused orphan foreign; do
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
# There are TWO disown messages and they describe different states; an operator
# reading the wrong one goes looking for a path mismatch that never happened.
check "not the no-path message"       "$(inout "recorded no worktree path")"             "0"
check "no herdr worktree remove"      "$(incmd "worktree remove")"                       "0"
# The whole set, not just the one command: the entry's own path was recorded and
# still resolves, so the snapshot is the ONLY thing herdr is asked for.
check "herdr is asked nothing else"   "$(herdrcmds)"                                     "api snapshot"
check "it works on its own checkout"  "$(inout "worktree:  $TMPROOT/wt-reused")"         "1"
check "the recorded worktree is gone" "$([[ -d "$TMPROOT/wt-reused" ]] && echo yes || echo no)" "no"
check "the entry is dropped"          "$([[ -f "$STATE/wreused_p1.json" ]] && echo yes || echo no)" "no"
check "it exits 0"                    "$RC"                                              "0"
rm -f "$STUBDIR/snapshot.json"

echo
echo "=== hdespawn: a live workspace an entry cannot be PROVEN to own ==="
# The other half of the same guard, and the dangerous one. A registry entry can
# carry an EMPTY .path — a `worktree create` reply without `worktree.path`, or a
# partially-failed run; the whole worktree-path recovery below the guard exists
# because that state occurs. Requiring a non-empty recorded path before disowning
# meant such an entry kept ws_live/live_path set, adopted the LIVE workspace's
# checkout as its own two lines down, and tore that down: `herdr worktree remove
# --workspace` removes another spawn's worktree and closes their pane. On a box
# running a dozen agent sessions that is somebody else's work destroyed.
#
# So: same workspace id, live and holding wt-foreign; this entry recorded no path
# at all. wt-foreign is a REAL, clean worktree, so a mutated hdespawn sails past
# the at-risk guard and reaches the removal — the row has to be reachable to be
# a row.
mkwt "$TMPROOT/wt-orphan" orphan
mkwt "$TMPROOT/wt-foreign" foreign
rm -f "$STATE/wforeign_p1.json"     # wt-foreign is the bystander, not a target
cat > "$STATE/worphan_p1.json" <<JSON
{"pane_id":"worphan:p1","workspace_id":"worphan","branch":"tester/orphan","slug":"orphan",
 "repo":"$REPO","path":"","created_at":"2026-09-01T10:00:00Z","creator_session":"sess-1"}
JSON
cat > "$STUBDIR/snapshot.json" <<JSON
{"result":{"snapshot":{"workspaces":[{"workspace_id":"worphan","label":"someone else",
 "worktree":{"checkout_path":"$TMPROOT/wt-foreign"}}],
 "panes":[{"pane_id":"worphan:p1","agent_status":"idle"}],"agents":[]}}}
JSON
run "hdespawn --yes orphan"
check "the empty path is reported"    "$(inout "recorded no worktree path, so workspace worphan ($TMPROOT/wt-foreign) cannot be shown to be its own")" "1"
check "not the id-reused message"     "$(inout "the id was reused")"                     "0"
check "it says what it will do next"  "$(inout "finishing this entry from its branch")"  "1"
# The adoption itself, which is the defect: wt_path must NOT become the live
# workspace's checkout. The branch lookups are what identify this entry's own.
check "the foreign checkout is not adopted" "$(inout "worktree:  $TMPROOT/wt-foreign")"  "0"
check "the branch lookup finds its own"     "$(inout "worktree:  $TMPROOT/wt-orphan")"   "1"
check "and the workspace reads as gone"     "$(inout "workspace: worphan (not in the current herdr session)")" "1"
# The blast radius, as a set: a snapshot, then the worktree lookup the disown
# forced. No `worktree remove --workspace worphan`, and nothing else either.
check "herdr is never asked to remove"      "$(herdrcmds)"   "api snapshot|worktree list --cwd $REPO"
check "the bystander checkout survives"     "$([[ -d "$TMPROOT/wt-foreign" ]] && echo yes || echo no)" "yes"
# ...and the teardown still COMPLETED against the right path. Disowning must not
# turn into the dead end it replaced: entry dropped with its worktree stranded.
check "its own worktree is removed"         "$(inout "removed:   worktree $TMPROOT/wt-orphan (git worktree remove)")" "1"
check "the dir is really gone"              "$([[ -d "$TMPROOT/wt-orphan" ]] && echo yes || echo no)" "no"
check "the entry is dropped"                "$([[ -f "$STATE/worphan_p1.json" ]] && echo yes || echo no)" "no"
check "it exits 0"                          "$RC"                                        "0"
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
      "$(grep -c 'Finish with: hdespawn \$pane' "$HERDRRC")"                             "1"
# shellcheck disable=SC2016  # ditto: a literal, not an expansion
check "close line does not use \$slug alone" \
      "$(grep -c 'Finish with: hdespawn \${rslug:-\$pane}' "$HERDRRC")"                  "0"
# And the census must not swallow a pane it could not ask about.
check "a failed process-info is counted" \
      "$(grep -c 'unqueried++' "$HERDRRC")"                                              "1"
check "and is reported in the totals" \
      "$(grep -c 'pane(s) that could not be queried' "$HERDRRC")"                        "1"

echo
echo "=== hspawn: the trust dialog, and hspawn's own exit code ==="
# Two gaps at one site. hspawn's exit code was asserted on NO successful spawn
# and on NO bail-out below the argument parser, and the bail-out line here —
# "(registry entry kept; `hdespawn <pane>` tears the worktree down)" — is
# character-for-character identical at four sites in the function, so an
# assertion that merely greps for the sentence cannot tell which one printed it.
# These rows drive the real dialog: `agent get` reports blocked and `agent read`
# returns the dialog text, which is exactly the pair _hspawn_clear_trust_dialog
# tests, and only this site is reachable in that state.
MODE=full; PANEDIR=""; SESS=""
trust_blocked() {
    cat > "$STUBDIR/agent-get.json" <<'JSON'
{"result":{"agent":{"agent_status":"blocked","name":"slug"}}}
JSON
    printf '%s\n' 'Do you trust the files in this folder?' \
                  '  1. Yes, I trust this folder' \
                  '  2. No, exit' > "$STUBDIR/agent-read.txt"
}
trust_clear() {
    cat > "$STUBDIR/agent-get.json" <<'JSON'
{"result":{"agent":{"agent_status":"idle","name":"slug"}}}
JSON
    rm -f "$STUBDIR/agent-read.txt"
}

# The success half first: a bail-out row asserting "it did not print the success
# line" proves nothing unless the success line is known to be printed otherwise.
# The profile path is used because it is the one that renames the agent AFTER
# the trust check, which is how "it stopped exactly there" becomes observable.
trust_clear
rm -f "$STATE"/*.json
run "hspawn -p personal '$REPO' slug"
check "a clean spawn exits 0"           "$RC"                                    "0"
check "and prints the next: line"       "$(inout "herdr agent read wZ:p1")"      "1"
check "an unblocked agent gets no keys" "$(incmd "agent send-keys")"             "0"
check "and it does reach the rename"    "$(incmd "agent rename")"                "1"

# Blocked, but the screen is not the trust dialog: there is nothing to answer,
# so the helper returns 0 and the spawn continues. Without this row a mutation
# dropping the "Yes, I trust this folder" test would be free.
trust_blocked
printf 'Some other approval prompt\n' > "$STUBDIR/agent-read.txt"
rm -f "$STATE"/*.json
run "hspawn -p personal '$REPO' slug"
check "blocked, no trust text: exits 0" "$RC"                                    "0"
check "and still sends no keys"         "$(incmd "agent send-keys")"             "0"

# The bail-out itself.
trust_blocked
rm -f "$STATE"/*.json
run "hspawn -p personal '$REPO' slug"
check "an unanswerable dialog fails"    "$RC"                                    "1"
check "the helper says it gave up"      "$(inout "trust dialog still up after 3 attempts")" "1"
check "it names the teardown command"   "$(inout "(registry entry kept; \`hdespawn wZ:p1\` tears the worktree down)")" "1"
check "and that claim is true"          "$([[ -f "$STATE/wZ_p1.json" ]] && echo yes || echo no)" "yes"
# Three attempts, down-then-enter on each: the loop, not one pass. The dialog
# defaults to "No, exit", so the order of those two keys is the whole answer.
check "down is sent 3 times"            "$(incmd "agent send-keys wZ:p1 down")"  "3"
check "enter is sent 3 times"           "$(incmd "agent send-keys wZ:p1 enter")" "3"
# ORDER, not just counts: the dialog's default is "No, exit", so down-then-enter
# accepts and enter-then-down declines. Two rows that only count the keys pass
# on the sequence that exits the agent.
check "down comes before enter" \
      "$(grep -E '^CMD agent send-keys wZ:p1 (down|enter)$' "$LOG" | head -2 | tr '\n' '|')" \
      "CMD agent send-keys wZ:p1 down|CMD agent send-keys wZ:p1 enter|"
# It stopped THERE — everything below the trust check is unreached.
check "no success line is printed"      "$(inout "next:")"                       "0"
check "the agent is never renamed"      "$(incmd "agent rename")"                "0"
trust_clear
rm -f "$STATE"/*.json

echo
echo "=== hreap: the scan itself, against a recorded snapshot ==="
# Everything above this line about hreap is a pure formatter, a pre-scan flag
# refusal or a grep of the source: a canary printf inside the pane-scan loop
# recorded ZERO executions across a full 131-check run. So the census, the
# Claude-process test, the idle classification, the registry tag, --mine and the
# whole of --close were unpinned — in the one command whose job is to find
# leaked agents on a box where memory is the binding constraint.
#
# The fixture is one snapshot of eleven panes, each of which exists to make a
# different branch of that loop observable, plus one per-pane `process-info`
# reply. A pane with NO reply file makes the stub exit non-zero, which is the
# only way to reach the `unqueried` counter.
MODE=full; SESS=""
PANEDIR="$TMPROOT/panes"; mkdir -p "$PANEDIR"
rm -f "$STATE"/*.json
HNOW="$(date +%s)"

procinfo() {   # $1 pane, $2 pid, $3 process name, $4 argv[0] ("" = no argv), $5 cwd
    local argv="[]"
    [[ -n "$4" ]] && argv="[\"$4\"]"
    cat > "$PANEDIR/procinfo-${1//:/_}.json" <<JSON
{"result":{"process_info":{"pane_id":"$1","shell_pid":$2,"foreground_process_group_id":$2,
 "foreground_processes":[{"pid":$2,"name":"$3","argv":$argv,"cwd":"$5"}]}}}
JSON
}
transcript() {   # $1 cwd, $2 session id, $3 age in seconds — the direct guess
    local d="$FHOME/.claude/projects/${1//[\/.]/-}"
    mkdir -p "$d"; : > "$d/$2.jsonl"; touch -d "@$(( HNOW - $3 ))" "$d/$2.jsonl"
}
clauth_transcript() {   # $1 dir name, $2 session id, $3 age — only the glob finds this
    local d="$FHOME/.clauth/profiles/personal/runtime-9/projects/$1"
    mkdir -p "$d"; : > "$d/$2.jsonl"; touch -d "@$(( HNOW - $3 ))" "$d/$2.jsonl"
}
reg() {   # $1 pane, $2 creator, $3 slug, $4 name, $5 branch, [$6 closed_at]
    local extra=""
    [[ -n "${6:-}" ]] && extra=", \"closed_at\": \"$6\", \"closed_by\": \"someone\""
    cat > "$STATE/${1//:/_}.json" <<JSON
{"pane_id": "$1", "workspace_id": "${1%%:*}", "creator_session": "$2", "slug": "$3",
 "name": "$4", "branch": "$5", "path": "/tmp/wt-$3"$extra}
JSON
}
# Rebuilt before each --close scenario: --close ANNOTATES entries, so a second
# scenario reading the first one's leftovers would be testing a different state
# than the one it names.
build_registry() {
    rm -f "$STATE"/*.json
    reg wA:p1 sess-1 alpha     alpha     tester/alpha
    reg wC:p1 sess-1 worker    worker    tester/worker
    reg wF:p1 sess-1 closedone closedone tester/closedone "2026-08-31T09:00:00Z"
    reg wG:p1 sess-2 other     other     tester/other
    reg wH:p1 sess-1 fresh     freshname tester/fresh
    reg wI:p1 sess-1 notrans   notrans   tester/notrans
    printf 'not json at all'  > "$STATE/wJ_p1.json"
}

# wA  the ordinary case: detected, idle, tagged to this session, 2h idle.
procinfo wA:p1 990001 claude   /home/u/.local/bin/claude          /tmp/proj-a
transcript /tmp/proj-a sess-A 7200
# wB  a herdmates teammate: herdr never detected it, its process name is the
#     bare version, and only the /claude/versions/ path test matches it. This
#     pane is the reason hreap exists.
procinfo wB:p1 990002 2.1.251  /home/u/.local/share/claude/versions/2.1.251 /tmp/proj-b
transcript /tmp/proj-b sess-B 14400
# wC  argv[0] is node and only .name is claude — the third arm of the test.
procinfo wC:p1 990003 claude   /usr/bin/node                      /tmp/proj-c
transcript /tmp/proj-c sess-C 5400
# wD  no reply file: `pane process-info` FAILS, which is the unqueried counter.
# wE  a pane with a shell in it and no agent: must not be counted at all.
procinfo wE:p1 990005 zsh      /usr/bin/zsh                       /tmp/proj-e
# wF  its registry entry carries closed_at: the pane id may have been reissued,
#     so it must read UNTAGGED and its creator must be blanked.
procinfo wF:p1 990006 claude   /home/u/.local/bin/claude          /tmp/proj-f
transcript /tmp/proj-f sess-F 6600
# wG  another session's spawn: listed, but --mine must not see it.
procinfo wG:p1 990007 node     /opt/tools/claude                  /tmp/proj-g
transcript /tmp/proj-g sess-G 6900
# wH  five minutes idle: under the default threshold, and its display name has
#     to come from the registry (no agent name, no terminal title).
procinfo wH:p1 990008 claude   /home/u/.local/bin/claude          /tmp/proj-h
transcript /tmp/proj-h sess-H 300
# wI  no transcript anywhere: idle falls back to process age, marked *. The pid
#     is this suite's own, so `ps -o etimes` actually answers.
procinfo wI:p1 $$     claude   /home/u/.local/bin/claude          /tmp/proj-i
# wJ  a corrupt registry file, a dead pid and no transcript: unknown idle,
#     unknown memory, and NOT tagged (an entry hreap cannot read entitles
#     --close to nothing).
procinfo wJ:p1 990010 claude   /home/u/.local/bin/claude          /tmp/proj-j
# wK  the transcript is only reachable through the ~/.clauth glob fallback.
procinfo wK:p1 990011 claude   /home/u/.local/bin/claude          /tmp/proj-k
clauth_transcript -tmp-proj-k sess-K 10800

cat > "$PANEDIR/get-default.json" <<'JSON'
{"result":{"pane":{"agent_status":"idle"}}}
JSON
cat > "$PANEDIR/get-wA_p1.json" <<'JSON'
{"result":{"pane":{"agent_status":"idle"}}}
JSON
# The close-time re-read disagrees with the scan: this is the whole safety story
# for --close, since there is no override flag.
cat > "$PANEDIR/get-wG_p1.json" <<'JSON'
{"result":{"pane":{"agent_status":"working"}}}
JSON

cat > "$STUBDIR/snapshot.json" <<'JSON'
{"result":{"snapshot":{
 "workspaces":[
  {"workspace_id":"wA","label":"alpha","worktree":{"checkout_path":"/tmp/wt-alpha"}},
  {"workspace_id":"wC","label":"","worktree":{"checkout_path":"/tmp/wt-worker"}},
  {"workspace_id":"wG","label":"","worktree":{"checkout_path":"/tmp/wt-other"}}
 ],
 "agents":[{"pane_id":"wA:p1","name":"alpha"},{"pane_id":"wC:p1","name":"worker"},
           {"pane_id":"wF:p1","name":"closedone"},{"pane_id":"wG:p1","name":"other"},
           {"pane_id":"wI:p1","name":"notrans"}],
 "panes":[
  {"pane_id":"wA:p1","workspace_id":"wA","agent":"alpha","agent_status":"idle",
   "agent_session":{"value":"sess-A"},"terminal_title_stripped":"alpha-title"},
  {"pane_id":"wB:p1","workspace_id":"wB","agent":"","agent_status":"unknown",
   "agent_session":{"value":"sess-B"},"terminal_title_stripped":"teammate-b"},
  {"pane_id":"wC:p1","workspace_id":"wC","agent":"worker","agent_status":"working",
   "agent_session":{"value":"sess-C"}},
  {"pane_id":"wD:p1","workspace_id":"wD","agent":"","agent_status":"idle",
   "agent_session":{"value":"sess-D"}},
  {"pane_id":"wE:p1","workspace_id":"wE","agent":"","agent_status":"idle",
   "agent_session":{"value":"sess-E"}},
  {"pane_id":"wF:p1","workspace_id":"wF","agent":"closedone","agent_status":"idle",
   "agent_session":{"value":"sess-F"}},
  {"pane_id":"wG:p1","workspace_id":"wG","agent":"other","agent_status":"idle",
   "agent_session":{"value":"sess-G"}},
  {"pane_id":"wH:p1","workspace_id":"wH","agent":"","agent_status":"idle",
   "agent_session":{"value":"sess-H"}},
  {"pane_id":"wI:p1","workspace_id":"wI","agent":"notrans","agent_status":"idle",
   "agent_session":{"value":"sess-I"}},
  {"pane_id":"wJ:p1","workspace_id":"wJ","agent":"","agent_status":"idle",
   "agent_session":{"value":"sess-J"}},
  {"pane_id":"wK:p1","workspace_id":"wK","agent":"","agent_status":"idle",
   "agent_session":{"value":"sess-K"},"terminal_title_stripped":"kay-pane"}
 ]}}}
JSON

# A whole table row, as one regular expression. The columns are fixed-width, so
# a row assertion pins the census, the name fallback, the detected flag, the
# status, the idle bucket and the tag in one place — and a per-column assertion
# would pass while the values belonged to a different pane.
rowre() { grep -cE -- "$1" <<<"$OUT" || true; }
ojq()   { printf '%s' "$OUT" | jq -r "$1" 2>/dev/null; }

build_registry
run "hreap"
check "the census counts every Claude proc" \
      "$(inout "of 9 in herdr panes + 1 pane(s) that could not be queried")"      "1"
check "the threshold narrows the listing"   "$(inout "totals:    6 Claude process(es) shown")" "1"
check "a pane it could not ask about"       "$(inout "wD:p1")"                    "0"
check "a pane with no Claude in it"         "$(inout "wE:p1")"                    "0"
check "the undetected teammate IS listed"   "$(inout "wB:p1")"                    "1"
check "a below-threshold pane is not"       "$(inout "wH:p1")"                    "0"
# The full row for the ordinary case: workspace label, agent name winning over
# the terminal title, detected, idle bucket, unknown memory, creator tag.
check "wA: the whole row" \
      "$(rowre '^wA:p1 +wA \(alpha\) +alpha +yes +idle +2h[0-9][0-9]m +\? +sess-1$')" "1"
check "wB: undetected, named by its title" \
      "$(rowre '^wB:p1 +wB +teammate-b +no +unknown +4h[0-9][0-9]m +\? +-$')"      "1"
check "wF: closed_at un-tags the entry" \
      "$(rowre '^wF:p1 +wF +closedone +yes +idle +1h5[0-9]m +\? +-$')"             "1"
check "wG: another session's tag is shown" \
      "$(rowre '^wG:p1 +wG +other +yes +idle +1h5[0-9]m +\? +sess-2$')"            "1"
check "the clauth glob finds a transcript" \
      "$(rowre '^wK:p1 +wK +kay-pane +no +idle +3h[0-9][0-9]m +\? +-$')"           "1"
check "rows are oldest-idle first" \
      "$(grep -oE '^w[A-K]:p1' <<<"$OUT" | tr '\n' ' ')" "wB:p1 wK:p1 wA:p1 wG:p1 wF:p1 wC:p1 "
# Read-only means read-only.
check "a bare hreap closes nothing"         "$(incmd "pane close")"               "0"
check "and does not even re-read a pane"    "$(incmd "pane get")"                 "0"

run "hreap --older 0"
check "--older 0 shows everything"          "$(inout "totals:    9 Claude process(es) shown")" "1"
check "unknown idle: both columns are ?" \
      "$(rowre '^wJ:p1 +wJ +- +no +idle +\? +\? +-$')"                             "1"
check "the registry supplies the name" \
      "$(rowre '^wH:p1 +wH +freshname +no +idle +5m +\? +sess-1$')"                "1"
check "process age is marked with a star"   "$(rowre '^wI:p1 .* [0-9?<][^ ]*\* ')" "1"
check "and the star is explained"           "$(inout "* no transcript found")"     "1"

SESS=sess-1 run "hreap --mine"
check "--mine keeps only this session"      "$(inout "totals:    2 Claude process(es) shown")" "1"
check "--mine drops another session"        "$(inout "wG:p1")"                     "0"
check "--mine drops a closed_at entry"      "$(inout "wF:p1")"                     "0"
check "--mine drops untagged panes"         "$(inout "wB:p1")"                     "0"
check "--mine still reports the full total" "$(inout "of 9 in herdr panes")"       "1"
SESS=sess-1 run "hreap --mine --older 0"
check "--mine --older 0 finds the rest"     "$(inout "totals:    4 Claude process(es) shown")" "1"

run "hreap --json --older 0"
check "--json emits one row per process"    "$(ojq 'length')"                      "9"
check "--json sorts oldest-idle first"      "$(ojq '.[0].pane')"                   "wB:p1"
check "--json puts unknown idle last"       "$(ojq '.[-1].pane')"                  "wJ:p1"
check "--json: the registry tag"            "$(ojq '.[]|select(.pane=="wA:p1")|.tagged')"  "true"
check "--json: the creator"                 "$(ojq '.[]|select(.pane=="wA:p1")|.creator')" "sess-1"
check "--json: the slug"                    "$(ojq '.[]|select(.pane=="wA:p1")|.slug')"    "alpha"
check "--json: the branch"                  "$(ojq '.[]|select(.pane=="wA:p1")|.branch')"  "tester/alpha"
check "--json: the worktree path"           "$(ojq '.[]|select(.pane=="wA:p1")|.worktree_path')" "/tmp/wt-alpha"
check "--json: idle came from a transcript" "$(ojq '.[]|select(.pane=="wA:p1")|.idle_src')" "transcript"
check "--json: the versioned binary"        "$(ojq '.[]|select(.pane=="wB:p1")|.process')" "2.1.251"
check "--json: it is not detected"          "$(ojq '.[]|select(.pane=="wB:p1")|.detected')" "false"
check "--json: closed_at leaves untagged"   "$(ojq '.[]|select(.pane=="wF:p1")|.tagged')"  "false"
# Not merely untagged: the creator has to be BLANKED, or a stale entry keeps
# attributing someone else's live pane to the session that spawned the old one.
check "--json: and blanks the creator"      "$(ojq '.[]|select(.pane=="wF:p1")|.creator')" ""
check "--json: a corrupt entry is untagged" "$(ojq '.[]|select(.pane=="wJ:p1")|.tagged')"  "false"
check "--json: unknown idle is null"        "$(ojq '.[]|select(.pane=="wJ:p1")|.idle_s')"  "null"
check "--json: unknown memory is null"      "$(ojq '.[]|select(.pane=="wJ:p1")|.mem_kb')"  "null"
check "--json: process age is labelled"     "$(ojq '.[]|select(.pane=="wI:p1")|.idle_src')" "process"
check "--json closes nothing"               "$(incmd "pane close")"                "0"
# The whole output has to PARSE. Counting rows does not pin this: jq prints the
# array's length and only then chokes on whatever follows it, so a --json that
# also printed the human table would satisfy every row above this one.
check "--json prints JSON and nothing else" \
      "$(printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 && echo yes || echo no)"          "yes"

echo
echo "=== hreap --close: the blast radius ==="
# The dangerous half. Every close goes through the stub; nothing here can reach
# a real server. What is asserted is not only "wA was closed" but the exact set:
# a single `pane close` in the whole log is the only form of that assertion that
# a mutation widening the filter cannot pass.
build_registry
run "hreap --close"
check "exactly one pane is closed"          "$(incmd "pane close")"                "1"
check "and it is the right one"             "$(incmd "pane close wA:p1")"          "1"
check "a working agent is skipped"          "$(inout "skip:      wC:p1 (worker) — status working, not closing")" "1"
# The re-read at close time: the scan said idle, herdr now says working. There is
# no override flag, so this is the whole safety story and it has to hold at the
# moment of the close, not at scan time.
check "a status that changed is skipped"    "$(inout "skip:      wG:p1 (other) — status changed to working since the scan, not closing")" "1"
check "untagged panes are left alone"       "$(inout "3 untagged row(s) left alone")" "1"
check "the summary counts the close"        "$(inout "reaped:    1 pane(s)")"       "1"
check "the closed line names the pane"      "$(inout "closed:    wA:p1 (alpha, idle 2h")" "1"
check "and how to finish the teardown"      "$(inout "worktree kept: /tmp/wt-alpha (tester/alpha) — may hold uncommitted work. Finish with: hdespawn wA:p1  (slug: alpha)")" "1"
# Annotated, never deleted: hdespawn finishes from this entry.
check "the entry survives the close"        "$([[ -f "$STATE/wA_p1.json" ]] && echo yes || echo no)" "yes"
check "it is stamped closed_at"             "$(jq -r '.closed_at // "none"' "$STATE/wA_p1.json" | grep -cE '^[0-9]{4}-')" "1"
check "and closed_by falls back to hreap"   "$(jq -r '.closed_by // "none"' "$STATE/wA_p1.json")" "hreap"
check "the branch is not touched"           "$(jq -r '.branch' "$STATE/wA_p1.json")" "tester/alpha"
# The claim in the header: a closed spawn leaves TAGGED and --close on the next
# run, because a new pane could reuse the id.
run "hreap --close"
check "a second run closes nothing"         "$(incmd "pane close")"                "0"
check "the closed entry is now untagged"    "$(inout "4 untagged row(s) left alone")" "1"

# --older 0 reaches the tagged rows the default threshold was hiding, and that
# is the only state in which the "no transcript" gate is reachable at all: a
# process's age is an upper bound on how long it has existed, not a measure of
# what it is doing, so closing on it would kill an agent that merely never got a
# transcript.
build_registry
run "hreap --close --older 0"
check "--older 0 closes the tagged rows"    "$(incmd "pane close")"                "2"
check "a five-minute spawn is now closed"   "$(incmd "pane close wH:p1")"          "1"
check "process age alone never closes" \
      "$(inout "skip:      wI:p1 (notrans) — tagged, but no transcript found; not closing on process age alone")" "1"
check "and that pane stays open"            "$(incmd "pane close wI:p1")"          "0"

build_registry
SESS=sess-1 run "hreap --close --mine"
check "--mine --close closes one pane"      "$(incmd "pane close")"                "1"
check "and it is this session's"            "$(incmd "pane close wA:p1")"          "1"
check "another session is not even listed"  "$(inout "wG:p1")"                     "0"
check "so nothing is left untagged"         "$(inout "0 untagged row(s) left alone")" "1"
check "closed_by records the session"       "$(jq -r '.closed_by' "$STATE/wA_p1.json")" "sess-1"

# herdr does not answer the re-read at all. The skip is right either way, but
# WHY it skipped is not: an unanswered `pane get` is not a status change, and an
# operator reading "changed to  since the scan" goes looking for a change that
# never happened. (jq prints nothing at all on empty input, so the `// "unknown"`
# written at that call site never fired — found by this row.)
build_registry
: > "$PANEDIR/getfail-wA_p1"
SESS=sess-1 run "hreap --close --mine"
check "an unanswered re-read skips"         "$(incmd "pane close")"                "0"
check "and says the status is unknown" \
      "$(inout "skip:      wA:p1 (alpha) — status changed to unknown since the scan, not closing")" "1"
check "it does not report a blank status"   "$(inout "changed to  since")"          "0"
check "and the entry is left alone"         "$(jq -r '.closed_at // "none"' "$STATE/wA_p1.json")" "none"
rm -f "$PANEDIR/getfail-wA_p1"

# A close that FAILS must not annotate: an entry stamped closed_at stops tagging
# a live pane, so a failed close that annotated anyway would hide the pane it
# failed to close from every subsequent run.
build_registry
: > "$STUBDIR/close-fails"
SESS=sess-1 run "hreap --close --mine"
check "a failed close is reported"          "$(inout "Error: herdr pane close wA:p1 failed")" "1"
check "and counted as nothing reaped"       "$(inout "reaped:    0 pane(s)")"      "1"
check "the entry is NOT annotated"          "$(jq -r '.closed_at // "none"' "$STATE/wA_p1.json")" "none"
rm -f "$STUBDIR/close-fails" "$STUBDIR/snapshot.json"
rm -f "$STATE"/*.json
PANEDIR=""

echo
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
