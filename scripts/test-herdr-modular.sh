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
rc=0; zsh -n "$DOTFILES/zsh/zshrc.herdr" || rc=$?
check "zshrc.herdr still parses" "$rc" "0"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
