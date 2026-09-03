#!/usr/bin/env bash
#
# scripts/test-herdr-modular.sh
# =============================
#
# State table for the modular herdr adopter's two commands (DO-563):
#
#   scripts/verify-tools.sh --herdr    the ONE check they run
#   scripts/herdr-claude-wire.sh       the ONE thing they wire by hand
#
# plus the assertion that `herdr-help` lives in the layer a modular adopter
# actually sources.
#
# WHY THIS EXISTS. The team-facing write-up had to tell readers to *ignore* a ✗
# that verify-tools.sh prints, and specifically not to paste the `ln -sfn`
# command it offers — pasting it pins ~25 tools globally. A checker whose output
# needs a prose disclaimer is the permanently-red-checker failure CLAUDE.md
# warns about twice, and prose is not a fix. The rows below pin the scope of
# `--herdr` in BOTH directions: what it must report, and what it must never
# mention.
#
# The second group is the load-bearing one, same as test-secret-guard.sh: a
# checker that reports a fault nobody can act on stops being read, and then the
# faults it *could* have caught go unread with it.
#
# HERMETIC. Fake $HOME per row, and a recording `herdr` STUB at the front of
# PATH — never herdr's absence. The box this was written on has a real herdr
# wired to a live server, so a suite that assumed absence would pass in CI and
# exercise nothing here.
#
# Requires: bash, jq, zsh. No network, no herdr, no Claude Code, no server.
#
# Usage: scripts/test-herdr-modular.sh

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$DOTFILES/scripts/verify-tools.sh"
WIRE="$DOTFILES/scripts/herdr-claude-wire.sh"
HOOK_REL="claude/hooks/session-statusline.sh"

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
has()   { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 — output lacks '$2'"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$1"; then bad "$3 — output still contains '$2'"; else ok "$3"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

for t in jq zsh; do command -v "$t" >/dev/null || fatal "missing required tool: $t"; done

# Most rows below assert that something was NOT written or NOT reported, which
# is also exactly what a suite that failed to load its subjects produces. Assert
# the subjects exist first — otherwise a rename turns this whole table green.
[[ -x "$VERIFY" ]] || fatal "not executable: $VERIFY"
[[ -x "$WIRE"   ]] || fatal "not executable: $WIRE (DO-563 step 3 not implemented)"
[[ -f "$DOTFILES/zsh/zshrc.herdr" ]] || fatal "missing: zsh/zshrc.herdr"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A herdr stub that records its argv and answers the two subcommands these
# scripts use. `--skill` output is marked so a regenerated file is
# distinguishable from a stale one.
STUB_BIN="$WORK/stub-bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${HERDR_STUB_LOG:-/dev/null}"
case "$1" in
  --skill)   printf -- '---\nname: herdr\n---\nSTUB SKILL BODY\n' ;;
  --version) printf 'herdr 9.9.9-stub\n' ;;
  *)         exit 0 ;;
esac
STUB
chmod +x "$STUB_BIN/herdr"

# A pgrep that finds nothing, so the server-env hygiene section takes its
# documented `○ no 'herdr server' process — skipped` path.
#
# WHY A STUB AND NOT ABSENCE (E1, found in review). Without this the suite
# pgrep'd the REAL machine, so on a box whose live server carries a forbidden
# variable the hygiene assertion FAILed and two exit-code rows went red for a
# reason unrelated to the diff — while every row expecting rc=1 passed for the
# WRONG reason, since the 1 came from the server rather than the missing wiring
# the row names. Red for no reason and green for no reason at once, under a
# header claiming "no server". Same argument as test-systemd-reconcile.sh's
# systemctl stub: this box has a real pgrep wired to a live server, so relying
# on pgrep's absence would pass in CI and prove nothing here.
cat >"$STUB_BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$STUB_BIN/pgrep"

# A PATH with herdr but deliberately NO jq. Built by naming the binaries the
# wirer is allowed to use rather than by hiding jq from a full PATH: that keeps
# "jq is absent" honest, and it pins the dependency list — a wirer that starts
# shelling out to python3 or awk will fail this row and have to say so.
NOJQ_BIN="$WORK/nojq-bin"
mkdir -p "$NOJQ_BIN"
ln -s "$STUB_BIN/herdr" "$NOJQ_BIN/herdr"
# bash and env among them: `#!/usr/bin/env bash` resolves bash through PATH, so
# a PATH without it exits 127 before the script's own first line — which is a
# harness fault masquerading as the refusal this row is trying to observe.
for b in bash env mktemp mv rm cat mkdir chmod install; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$NOJQ_BIN/$b"
done

# A fresh fake HOME with the statusline hook in place (dotbot's job, done).
new_home() {
    local h="$WORK/home.$1"
    rm -rf "$h"
    mkdir -p "$h/.claude/hooks"
    # Make the mise-drift branch REACHABLE: a real file (not a symlink) at the
    # active mise path, differing from the repo's .mise.toml. Without this the
    # `ln -sfn` row below passed even with the section gate removed ENTIRELY,
    # because the run took the "no active mise config" branch instead — which
    # prints no ln -sfn. The one row the whole change's rationale rests on was
    # unfailable. Found in review (M5/M9).
    mkdir -p "$h/.config/mise"
    printf '[tools]\nnode = "20"\n' >"$h/.config/mise/config.toml"
    cp "$DOTFILES/$HOOK_REL" "$h/.claude/hooks/session-statusline.sh"
    printf '%s' "$h"
}

# statusLine block as it should end up, for a given HOME.
good_statusline() {
    jq -n --arg c "bash '$1/.claude/hooks/session-statusline.sh'" \
        '{statusLine: {type: "command", command: $c, refreshInterval: 60}}'
}

wire() { PATH="$STUB_BIN:$PATH" HOME="$1" "$WIRE" "${@:2}" 2>&1; }
verify() { PATH="$STUB_BIN:$PATH" HOME="$1" "$VERIFY" "${@:2}" 2>&1; }

echo
echo "=== verify-tools --herdr: what it must NOT mention ==="
# Every line below is something the write-up currently has to apologise for.
H="$(new_home scope)"
good_statusline "$H" >"$H/.claude/settings.json"
mkdir -p "$H/.claude/skills/herdr"; printf 'x\n' >"$H/.claude/skills/herdr/SKILL.md"
OUT_HERDR="$(verify "$H" --herdr)"
hasnt "$OUT_HERDR" "Modern CLI Tools"  "no full-install tool inventory"
hasnt "$OUT_HERDR" "mise config drift" "no mise-drift section"
hasnt "$OUT_HERDR" "ln -sfn"           "never offers the ln -sfn that pins ~25 tools globally"
hasnt "$OUT_HERDR" "Oh-My-Zsh"         "no oh-my-zsh plugin inventory"
hasnt "$OUT_HERDR" "Forgit"            "no forgit section"
hasnt "$OUT_HERDR" "mise install"      "summary does not tell a modular adopter to run mise install"
hasnt "$OUT_HERDR" "CLAUDE.md"         "summary does not point at the full-repo guide"

echo
echo "=== verify-tools --herdr: what it must report ==="
has "$OUT_HERDR" "herdr server environment hygiene"  "keeps server-env hygiene"
has "$OUT_HERDR" "systemd user unit enablement"      "keeps unit-enablement drift"
has "$OUT_HERDR" "herdr SERVER PATH"                 "keeps plugin deps under the server PATH"
has "$OUT_HERDR" "Claude Code wiring"                "adds the Claude Code wiring section"

echo
echo "=== verify-tools: the full run is unchanged, and gains the new section ==="
OUT_FULL="$(verify "$H")"
has "$OUT_FULL" "Modern CLI Tools"   "full run still inventories tools"
has "$OUT_FULL" "mise config drift"  "full run still checks mise drift"
has "$OUT_FULL" "Claude Code wiring" "full run also checks Claude wiring — ./install wires neither"

echo
echo "=== verify-tools: argument handling ==="
rc=0; out="$(verify "$H" --help)" || rc=$?
check "--help exits 0" "$rc" "0"
has "$out" "--herdr" "--help documents --herdr"
rc=0; out="$(PATH="$STUB_BIN:$PATH" HOME="$H" "$VERIFY" --nonsense 2>&1)" || rc=$?
check "unknown flag exits 2" "$rc" "2"

echo
echo "=== Claude Code wiring: every way it is broken must FAIL ==="
# The two most-skipped steps in the install, and until now nothing checked
# either. Both are one command to fix, so both are ✗ rather than ⚠.
wiring_line() { verify "$1" --herdr | awk '/^=== Claude Code wiring/{f=1;next} /^===/{f=0} f'; }

H="$(new_home nosettings)"
mkdir -p "$H/.claude/skills/herdr"; printf 'x\n' >"$H/.claude/skills/herdr/SKILL.md"
out="$(wiring_line "$H")"
has "$out" "✗" "no settings.json at all is a FAIL"
rc=0; verify "$H" --herdr >/dev/null || rc=$?
check "...and takes the exit code with it" "$rc" "1"

H="$(new_home nostatusline)"
mkdir -p "$H/.claude/skills/herdr"; printf 'x\n' >"$H/.claude/skills/herdr/SKILL.md"
printf '{"model":"opus"}\n' >"$H/.claude/settings.json"
has "$(wiring_line "$H")" "✗" "settings.json without statusLine is a FAIL"

H="$(new_home nointerval)"
mkdir -p "$H/.claude/skills/herdr"; printf 'x\n' >"$H/.claude/skills/herdr/SKILL.md"
good_statusline "$H" | jq 'del(.statusLine.refreshInterval)' >"$H/.claude/settings.json"
out="$(wiring_line "$H")"
has "$out" "✗"              "statusLine without refreshInterval is a FAIL"
has "$out" "refreshInterval" "...and the message names refreshInterval"

H="$(new_home noskill)"
good_statusline "$H" >"$H/.claude/settings.json"
has "$(wiring_line "$H")" "✗" "missing SKILL.md is a FAIL"

H="$(new_home emptyskill)"
good_statusline "$H" >"$H/.claude/settings.json"
mkdir -p "$H/.claude/skills/herdr"; : >"$H/.claude/skills/herdr/SKILL.md"
has "$(wiring_line "$H")" "✗" 'empty SKILL.md is a FAIL — "herdr --skill" only prints, so a truncated redirect is the likely state'

echo
echo "=== Claude Code wiring: nothing to wire is SKIPPED, not FAILED ==="
# The permanently-red-checker trap, reproduced in the PR that exists to remove
# one and caught in review. The three sibling herdr sections all degrade to a
# `○ skipped` note when their subject is absent (no server, no linked units, no
# server PATH). This one asserted unconditionally, so a full-install user who
# does not run herdr was red forever with no action available to them, and a
# clean `./install` was red before anyone had a chance to wire anything.
#
# PATH=/usr/bin:/bin has jq but no herdr (herdr lives in ~/.local/bin here), so
# this is "herdr absent" honestly rather than by hiding a stub.
verify_noherdr() { PATH="/usr/bin:/bin" HOME="$1" "$VERIFY" "${@:2}" 2>&1; }
noherdr_section() { verify_noherdr "$1" --herdr | awk '/^=== Claude Code wiring/{f=1;next} /^===/{f=0} f'; }

H="$(new_home noherdr)"          # hook present, but nothing wired and no herdr
out="$(noherdr_section "$H")"
hasnt "$out" "✗" "herdr absent: no FAIL"
has   "$out" "○" "herdr absent: reported as a skip"
has   "$out" "herdr not installed" "...naming herdr as the reason (not incidental text)"
rc=0; verify_noherdr "$H" --herdr >/dev/null || rc=$?
check "herdr absent: exit 0" "$rc" "0"

# Claude Code never ran on this machine: no ~/.claude at all. Nothing to wire,
# so nothing to fail — the wirer would refuse here too (no hook).
H="$WORK/home.noclaude"; rm -rf "$H"; mkdir -p "$H"
out="$(wiring_line "$H")"
hasnt "$out" "✗" "no ~/.claude: no FAIL"
has   "$out" "○" "no ~/.claude: reported as a skip"
rc=0; verify "$H" --herdr >/dev/null || rc=$?
check "no ~/.claude: exit 0" "$rc" "0"

# But the skip must not swallow the real fault: herdr present AND ~/.claude
# present AND unwired is still actionable, so still a FAIL. (Asserted again
# below with the full matrix; this row is here so the two skips above cannot be
# widened into "never fail" without something going red.)
H="$(new_home stillfails)"
has "$(wiring_line "$H")" "✗" "herdr + ~/.claude present but unwired: still a FAIL"

echo
echo "=== Claude Code wiring: correct is green, and unreadable is not green ==="
H="$(new_home good)"
good_statusline "$H" >"$H/.claude/settings.json"
mkdir -p "$H/.claude/skills/herdr"; printf 'body\n' >"$H/.claude/skills/herdr/SKILL.md"
out="$(wiring_line "$H")"
has   "$out" "✓" "correctly wired is a PASS"
hasnt "$out" "✗" "...with nothing else flagged"
rc=0; verify "$H" --herdr >/dev/null || rc=$?
check "...and exits 0" "$rc" "0"

# An empty answer is never agreement: a settings.json jq cannot parse must not
# read as "no statusLine problem found".
H="$(new_home badjson)"
printf '{"statusLine": oops\n' >"$H/.claude/settings.json"
mkdir -p "$H/.claude/skills/herdr"; printf 'body\n' >"$H/.claude/skills/herdr/SKILL.md"
out="$(wiring_line "$H")"
has "$out" "✗" "unparseable settings.json is a FAIL, not a silent pass"

echo
echo "=== herdr-claude-wire: it writes exactly what the checker demands ==="
H="$(new_home wire1)"
rc=0; out="$(HERDR_STUB_LOG="$WORK/stub.log" wire "$H")" || rc=$?
check "exits 0 on a clean machine" "$rc" "0"
check "statusLine.type"    "$(jq -r '.statusLine.type' "$H/.claude/settings.json" 2>/dev/null)" "command"
check "refreshInterval 60" "$(jq -r '.statusLine.refreshInterval' "$H/.claude/settings.json" 2>/dev/null)" "60"
cmd="$(jq -r '.statusLine.command' "$H/.claude/settings.json" 2>/dev/null)"
hasnt "$cmd" '~' "command uses an absolute path, never ~ (it is not reliably expanded here)"
has   "$cmd" "$H/.claude/hooks/session-statusline.sh" "command points at this HOME's hook"
check "SKILL.md written from herdr --skill" \
      "$(grep -c 'STUB SKILL BODY' "$H/.claude/skills/herdr/SKILL.md" 2>/dev/null)" "1"
has "$(cat "$WORK/stub.log")" "--skill" "...by calling herdr --skill"
# And what the checker says about what the wirer just did is the only end-to-end
# assertion that matters: two scripts agreeing with each other.
rc=0; verify "$H" --herdr >/dev/null || rc=$?
check "verify-tools --herdr passes what herdr-claude-wire produced" "$rc" "0"

echo
echo "=== herdr-claude-wire: idempotent, and never destroys a working setup ==="
H="$(new_home wire2)"
wire "$H" >/dev/null
before="$(cat "$H/.claude/settings.json")"
rc=0; out="$(wire "$H")" || rc=$?
check "second run exits 0" "$rc" "0"
check "second run changes nothing" "$(cat "$H/.claude/settings.json")" "$before"

H="$(new_home wire3)"
printf '{"model":"opus","permissions":{"allow":["Bash"]}}\n' >"$H/.claude/settings.json"
wire "$H" >/dev/null
check "unrelated keys preserved" "$(jq -r '.model' "$H/.claude/settings.json")" "opus"
check "nested keys preserved"    "$(jq -r '.permissions.allow[0]' "$H/.claude/settings.json")" "Bash"

# The one thing it must never do: overwrite a statusLine somebody else owns.
# Orca ships its own claude-statusline.sh, and settings.json has exactly one
# statusLine key — so this is a real collision, not a hypothetical one.
H="$(new_home wire4)"
theirs='{"statusLine":{"type":"command","command":"/opt/orca/claude-statusline.sh"}}'
printf '%s\n' "$theirs" >"$H/.claude/settings.json"
rc=0; out="$(wire "$H")" || rc=$?
check "refuses a foreign statusLine" "$rc" "1"
check "...and leaves it untouched" "$(jq -c . "$H/.claude/settings.json")" "$(jq -c . <<<"$theirs")"
has "$out" "statusLine" "...and says which key it refused to touch"

echo
echo "=== Claude Code wiring: states the criteria name but nothing pinned ==="
# All four behave correctly today; none was pinned, so nothing would notice when
# they stop. (Important 7c.)
H="$(new_home foreignobj)"
mkdir -p "$H/.claude/skills/herdr"; printf 'b\n' >"$H/.claude/skills/herdr/SKILL.md"
printf '{"statusLine":{"type":"command","command":"/opt/orca/claude-statusline.sh","refreshInterval":60}}\n' \
    >"$H/.claude/settings.json"
out="$(wiring_line "$H")"
has "$out" "✗"                  "checker: a statusLine owned by another tool is a FAIL"
has "$out" "something else"     "...and says whose it is, not that it is missing"

# jq absent: NOT CHECKED, never a pass.
H="$(new_home nojqcheck)"
out="$(PATH="$NOJQ_BIN" HOME="$H" "$VERIFY" --herdr 2>&1 \
       | awk '/^=== Claude Code wiring/{f=1;next} /^===/{f=0} f')"
has   "$out" "NOT CHECKED" "checker: no jq means NOT CHECKED"
hasnt "$out" "✓ statusLine" "...and never a ✓ for a check it could not run"

# statusLine correct, but dotbot never linked the hook it points at.
H="$(new_home nohookfile)"
mkdir -p "$H/.claude/skills/herdr"; printf 'b\n' >"$H/.claude/skills/herdr/SKILL.md"
good_statusline "$H" >"$H/.claude/settings.json"
rm -f "$H/.claude/hooks/session-statusline.sh"
has "$(wiring_line "$H")" "does not exist" "checker: a statusLine pointing at a missing hook is a FAIL"

# A directory named SKILL.md satisfies -e and -s. It is not a skill file.
H="$(new_home skilldir)"
good_statusline "$H" >"$H/.claude/settings.json"
mkdir -p "$H/.claude/skills/herdr/SKILL.md/oops"
out="$(wiring_line "$H")"
hasnt "$out" "✓ agent skill file present" "checker: a DIRECTORY named SKILL.md is not a skill file"

echo
echo "=== herdr-claude-wire: --print writes nothing ==="
H="$(new_home printmode)"
rc=0; out="$(wire "$H" --print)" || rc=$?
check "--print exits 0"                 "$rc" "0"
check "--print creates no settings.json" "$([[ -e "$H/.claude/settings.json" ]] && echo yes || echo no)" "no"
check "--print creates no SKILL.md"      "$([[ -e "$H/.claude/skills/herdr/SKILL.md" ]] && echo yes || echo no)" "no"
check "--print leaves no temp droppings" "$(find "$H/.claude" -name '*.XXXXXX' -o -name 'settings.json.wire.*' | wc -l)" "0"

echo
echo "=== herdr-claude-wire: a statusLine of the WRONG SHAPE is still not ours ==="
# Found in review. `jq -r '.statusLine.command // ""'` ERRORS on a statusLine
# that is not an object ("Cannot index string with string") and jq's status was
# discarded, so the empty capture read as "no statusLine is set" -- and the
# script then OVERWROTE another tool's entry and printed "Claude Code is wired",
# exit 0. The // operator does not defend against this: it substitutes for null,
# not for a type error. Any non-object shape is somebody else's key.
for shape_desc in string:'"/opt/other/thing.sh"' array:'["a"]' number:'42' bool:'true'; do
  kind="${shape_desc%%:*}"; val="${shape_desc#*:}"
  H="$(new_home "wireshape-$kind")"
  printf '{"model":"opus","statusLine":%s}\n' "$val" >"$H/.claude/settings.json"
  before="$(cat "$H/.claude/settings.json")"
  rc=0; out="$(wire "$H")" || rc=$?
  check "statusLine as a $kind: refuses (exit 1)" "$rc" "1"
  check "statusLine as a $kind: file untouched" "$(cat "$H/.claude/settings.json")" "$before"
  has "$out" "statusLine" "statusLine as a $kind: says which key it refused"
done

echo
echo "=== verify-tools: a wrong-shaped statusLine is a FAIL that names the shape ==="
H="$(new_home shapecheck)"
mkdir -p "$H/.claude/skills/herdr"; printf 'b\n' >"$H/.claude/skills/herdr/SKILL.md"
printf '{"statusLine":"/opt/other/thing.sh"}\n' >"$H/.claude/settings.json"
out="$(wiring_line "$H")"
has   "$out" "✗"            "wrong-shaped statusLine is a FAIL"
has   "$out" "not an object" "...and the message says the shape is wrong, not 'no statusLine'"
# These two rows passed for the WRONG REASON before this was tightened: jq's own
# "Cannot index string with string" error was leaking into the captured output
# and satisfying an assertion that merely looked for the word "string". A
# checker that reports a fault by leaking its parser's stderr is not reporting.
hasnt "$out" "Cannot index" "...without leaking jq's raw error into the report"
hasnt "$out" "no statusLine" "...and without claiming there is no statusLine when there is one"

# An OBJECT statusLine whose command is not ours is still somebody else's key.
# The type check alone does not cover this: {"statusLine":{"command":null}} and
# {"statusLine":{"type":"custom","script":"/opt/x"}} are objects, so .command
# comes back empty and the write path treated them as absent. Flagged in review
# alongside Critical 2.
for od in 'nullcmd:{"command":null}' 'othershape:{"type":"custom","script":"/opt/x"}' 'empty:{}'; do
  kind="${od%%:*}"; val="${od#*:}"
  H="$(new_home "wireobj-$kind")"
  printf '{"model":"opus","statusLine":%s}\n' "$val" >"$H/.claude/settings.json"
  before="$(cat "$H/.claude/settings.json")"
  rc=0; wire "$H" >/dev/null || rc=$?
  check "object statusLine ($kind) that is not ours: refuses" "$rc" "1"
  check "object statusLine ($kind): file untouched" "$(cat "$H/.claude/settings.json")" "$before"
done

echo
echo "=== herdr-claude-wire: it must not half-succeed in silence ==="
# A script that cannot finish its job and exits 0 is the failure mode this whole
# stack is written against.
H="$(new_home noherdr)"
rc=0; out="$(HOME="$H" PATH="/usr/bin:/bin" "$WIRE" 2>&1)" || rc=$?
check "no herdr on PATH exits non-zero" "$rc" "1"
has "$out" "herdr" "...naming herdr as what is missing"
check "...having still written the statusLine it could" \
      "$(jq -r '.statusLine.refreshInterval' "$H/.claude/settings.json" 2>/dev/null)" "60"

H="$(new_home nojq)"
printf '{"model":"opus"}\n' >"$H/.claude/settings.json"
rc=0; out="$(HOME="$H" PATH="$NOJQ_BIN" "$WIRE" 2>&1)" || rc=$?
check "no jq exits non-zero rather than mangling JSON" "$rc" "1"
check "...leaving settings.json byte-identical" "$(cat "$H/.claude/settings.json")" '{"model":"opus"}'

# Wiring a statusLine that points at a file dotbot has not linked yet produces
# a green settings.json and a permanently blank sidebar — so the hook's absence
# is the one thing that must stop the write, not be papered over by it.
H="$WORK/home.nohook"; rm -rf "$H"; mkdir -p "$H/.claude"
rc=0; out="$(wire "$H")" || rc=$?
check "a missing statusline hook exits non-zero" "$rc" "1"
has "$out" "session-statusline.sh" "...naming the file that is not there"
check "...and writes no statusLine at all" \
      "$(jq -r '.statusLine // "none"' "$H/.claude/settings.json" 2>/dev/null || printf none)" "none"

H="$(new_home wirebadjson)"
printf '{"statusLine": oops\n' >"$H/.claude/settings.json"
rc=0; out="$(wire "$H")" || rc=$?
check "unparseable settings.json exits non-zero" "$rc" "1"
check "...and is not overwritten" "$(cat "$H/.claude/settings.json")" '{"statusLine": oops'

echo
echo "=== housekeeping: no droppings, honest messages, honest argument errors ==="
# Minor 12: a signal mid-run left a temp file beside the destination.
H="$(new_home trapped)"
cat >"$STUB_BIN/herdr-slow" <<'STUB'
#!/usr/bin/env bash
case "$1" in --skill) sleep 3 ;; esac
STUB
chmod +x "$STUB_BIN/herdr-slow"
SLOWBIN="$WORK/slowbin"; mkdir -p "$SLOWBIN"
ln -sf "$STUB_BIN/herdr-slow" "$SLOWBIN/herdr"
PATH="$SLOWBIN:$PATH" HOME="$H" timeout -s TERM 1 "$WIRE" >/dev/null 2>&1
check "a signal mid-run leaves no temp droppings" \
      "$(find "$H/.claude" \( -name 'SKILL.md.*' -o -name 'settings.json.wire.*' \) | wc -l)" "0"

# Minor 14: "not valid JSON" was printed for a valid `null` document and for an
# unreadable file alike. Refusing is right; naming the wrong cause is not, since
# the advice is "fix it by hand".
H="$(new_home jsonnull)"
printf 'null\n' >"$H/.claude/settings.json"
out="$(wire "$H")"
hasnt "$out" "not valid JSON" "a valid 'null' document is not described as invalid JSON"

H="$(new_home jsonunreadable)"
printf '{}\n' >"$H/.claude/settings.json"; chmod 000 "$H/.claude/settings.json"
out="$(wire "$H")"
hasnt "$out" "not valid JSON" "an unreadable file is not described as invalid JSON"
has   "$out" "read"           "...it says it could not read it"
chmod 644 "$H/.claude/settings.json"

# Minor 17: the arity error blamed the valid flag rather than the extra word.
rc=0; out="$(PATH="$STUB_BIN:$PATH" HOME="$H" "$VERIFY" --herdr extra 2>&1)" || rc=$?
check "too many arguments exits 2"  "$rc" "2"
hasnt "$out" "unknown argument '--herdr'" "...without blaming the valid flag"

# Minor 18b: a stale SKILL.md is "worse than none, because it looks fine".
H="$(new_home staleskill)"
good_statusline "$H" >"$H/.claude/settings.json"
mkdir -p "$H/.claude/skills/herdr"
printf -- '---\nname: herdr\n---\nOLD CONTENT FROM AN EARLIER HERDR\n' >"$H/.claude/skills/herdr/SKILL.md"
out="$(wiring_line "$H")"
has   "$out" "stale" "a SKILL.md that differs from 'herdr --skill' is reported as stale"
hasnt "$out" "✗"     "...as a ⚠, not a ✗ — regenerating is one command and the file still works"
rc=0; verify "$H" --herdr >/dev/null || rc=$?
check "...and does not fail the run" "$rc" "0"

echo
echo "=== refreshInterval: only a usable number counts ==="
# The documented reason for requiring the key is the 4-minute token TTL, so a
# value of 0 or 600 produces exactly the blanked sidebar rows the check exists
# to catch -- and `jq -r` strips quotes, so the JSON STRING "60" passed a bare
# numeric regex too. All three reported ✓ before this. (Important 5.)
iv_row() {  # <json-value> <expect ok|fail> <label>
  local H; H="$(new_home "iv-$3")"
  mkdir -p "$H/.claude/skills/herdr"; printf 'b\n' >"$H/.claude/skills/herdr/SKILL.md"
  good_statusline "$H" | jq --argjson v "$1" '.statusLine.refreshInterval = $v' \
      >"$H/.claude/settings.json"
  local out; out="$(wiring_line "$H")"
  if [[ "$2" == ok ]]; then
    has   "$out" "✓ statusLine" "refreshInterval $1: accepted"
  else
    has   "$out" "✗"            "refreshInterval $1: rejected"
    hasnt "$out" "✓ statusLine" "refreshInterval $1: no ✓ alongside the ✗"
  fi
}
iv_row 60    ok   good
iv_row '"60"' fail string
iv_row 0     fail zero
iv_row 600   fail toobig

echo
echo "=== the enablement assertion must examine the LIVE deployment ==="
# Deriving DOTFILES_ROOT from BASH_SOURCE fixed a real bug, but it also made this
# assertion vacuous when run from a worktree -- which `dotfiles-work` makes the
# normal place to run it. It skipped with "no units linked from <worktree>" while
# the live deployment had an enabled unit, and exit 0 then meant "not checked" in
# the section whose own comment says a missing checker is not a pass.
# (Important 4.) Resolving the root from the links systemd actually holds also
# makes this row hermetic: the stub below is what gets run, not the real script.
FAKEREPO="$WORK/fakerepo"
mkdir -p "$FAKEREPO/scripts" "$FAKEREPO/systemd"
printf 'x\n' >"$FAKEREPO/systemd/herdr-server.service"
cat >"$FAKEREPO/scripts/reconcile-systemd-units.sh" <<'STUB'
#!/usr/bin/env bash
echo "  ✓ STUB-RECONCILE-RAN in $(cd "$(dirname "$0")/.." && pwd)"
exit 0
STUB
chmod +x "$FAKEREPO/scripts/reconcile-systemd-units.sh"
H="$(new_home enablement)"
mkdir -p "$H/.config/systemd/user" "$H/.claude/skills/herdr"
printf 'b\n' >"$H/.claude/skills/herdr/SKILL.md"
good_statusline "$H" >"$H/.claude/settings.json"
ln -sf "$FAKEREPO/systemd/herdr-server.service" "$H/.config/systemd/user/herdr-server.service"
out="$(verify "$H" --herdr)"
has "$out" "STUB-RECONCILE-RAN" "follows the live unit link to the checkout that owns it"
has "$out" "$FAKEREPO"          "...and names that checkout, not the one it was run from"

# No links at all: skip WITHOUT shelling out, so a fake HOME never reaches the
# real reconcile script (the other half of the hermeticity gap, E1).
H="$(new_home nolinks)"
mkdir -p "$H/.claude/skills/herdr"; printf 'b\n' >"$H/.claude/skills/herdr/SKILL.md"
good_statusline "$H" >"$H/.claude/settings.json"
out="$(verify "$H" --herdr)"
has   "$out" "systemd user unit enablement" "no links: section still reported"
hasnt "$out" "STUB-RECONCILE-RAN"           "no links: nothing was executed"
rc=0; verify "$H" --herdr >/dev/null || rc=$?
check "no links: exit 0" "$rc" "0"

echo
echo "=== a HOME with a single quote must not produce a broken command ==="
# printf '%s' into "bash '$HOOK'" breaks on a quote in $HOME: the script reported
# ✓ while the recorded command did not execute. A HOME with a SPACE was already
# fine. (Minor 13.)
H="$WORK/ho'me"; rm -rf "$H"; mkdir -p "$H/.claude/hooks"
cp "$DOTFILES/$HOOK_REL" "$H/.claude/hooks/session-statusline.sh"
wire "$H" >/dev/null 2>&1
cmd="$(jq -r '.statusLine.command' "$H/.claude/settings.json" 2>/dev/null)"
# The recorded command must parse into words whose target file exists.
if eval "set -- $cmd" 2>/dev/null && [[ -f "${2:-}" ]]; then
  ok "quoted HOME: the recorded command names a real file"
else
  bad "quoted HOME: recorded command does not resolve — got: $cmd"
fi

echo
echo "=== herdr-help belongs to the layer a modular adopter sources ==="
zt() { zsh -c "source '$DOTFILES/$1' >/dev/null 2>&1; whence -w herdr-help" 2>/dev/null; }
check "defined by zsh/zshrc.herdr"     "$(zt zsh/zshrc.herdr)"   "herdr-help: function"
# `whence -w` prints "<name>: none" for an undefined name, not an empty string —
# so asserting "" here would have passed against a broken zt() that returned
# nothing at all, which is the shape of half the bugs this repo has logged.
check "no longer defined by zshrc.help" "$(zt zsh/zshrc.help)"   "herdr-help: none"
# The full install sources both; one definition, not two competing ones.
both="$(zsh -c "source '$DOTFILES/zsh/zshrc.help' >/dev/null 2>&1
                source '$DOTFILES/zsh/zshrc.herdr' >/dev/null 2>&1
                whence -w herdr-help" 2>/dev/null)"
check "full install still gets exactly one" "$both" "herdr-help: function"
if grep -q 'herdr-help' "$DOTFILES/zsh/zshrc.help"; then
    ok "dothelp index still lists herdr-help"
else
    bad "dothelp index no longer lists herdr-help — the index is how it is discovered"
fi
# The cheat sheet was MOVED for the modular adopter (it lived in zshrc.help,
# which only the full install sources), which made its text reachable on a
# modular machine for the first time -- still recommending the bare
# verify-tools.sh run that install and CLAUDE.md now warn that audience against,
# and never mentioning the wiring command at all. Found in review.
helptext="$(zsh -c "source '$DOTFILES/zsh/zshrc.herdr' >/dev/null 2>&1; herdr-help" 2>/dev/null)"
has "$helptext" "verify-tools.sh --herdr"   "cheat sheet recommends --herdr, not the bare run"
has "$helptext" "herdr-claude-wire.sh"      "cheat sheet names the wiring command"

rc=0; zsh -n "$DOTFILES/zsh/zshrc.herdr" || rc=$?
check "zshrc.herdr still parses" "$rc" "0"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
