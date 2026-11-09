#!/usr/bin/env bash
#
# scripts/test-check-links.sh
# ===========================
#
# State table for scripts/check-links.sh.
#
# The row this file exists for is "regular file, content differs" — the exact
# state `~/.config/claude-tenants.zsh` was in on 2026-09-15, where the tracked
# source was inert, nothing failed, and the next `./install` would have silently
# restored a stale Claude account pool. Every other row is here to stop the
# checker shrinking: a parser that skips an entry shape, or a precondition that
# resolves "I cannot tell" to "fine", reports a green tick over the same silence
# the checker was written to break.
#
# Hermetic: every row builds its own REPO_ROOT and HOME under a temp dir, so
# nothing reads or writes the real machine.
#
# Usage: scripts/test-check-links.sh

# The manifest targets are the literal text "~/..." (the checker expands them), so the
# quoted tildes in the rows below are deliberate.
# shellcheck disable=SC2088
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${CHECK:-$HERE/check-links.sh}"

PASS=0; FAIL=0
ok()  { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1 — output lacked '$3'"; fi; }
hasnt(){ if grep -qF -- "$3" <<<"$2"; then bad "$1 — output contained '$3'"; else ok "$1"; fi; }
[[ -x "$CHECK" ]] || { printf 'FATAL: not executable: %s\n' "$CHECK" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
n=0

# Build a fixture: $1 = manifest body. SETS the globals R (repo) and H (home).
#
# It sets globals rather than echoing a pair to be read back, because
# `read R H <<< "$(fixture …)"` runs fixture in a SUBSHELL — where `n` does
# increment, and then dies with it. Every row got `r1`/`h1`, inheriting the
# previous row's symlink, and 13 rows failed for a reason that was nowhere near
# the code under test. Worth keeping as a comment: the harness was the thing
# producing confident wrong answers, which is exactly what the checker exists to
# stop happening elsewhere.
fixture() {
  n=$((n+1))
  R="$TMP/r$n"; H="$TMP/h$n"
  mkdir -p "$R/claude" "$H"
  printf 'POOL=original\n' > "$R/claude/tenants.zsh"
  printf '%s' "$1" > "$R/install.conf.yaml"
}

MANIFEST='- defaults:
    link:
      relink: true

- link:
    ~/.config/claude-tenants.zsh: claude/tenants.zsh
'

run() { REPO_ROOT="$1" HOME="$2" bash "$CHECK" 2>&1; }
rc_of() { REPO_ROOT="$1" HOME="$2" bash "$CHECK" >/dev/null 2>&1; printf '%s' "$?"; }

echo
echo "=== the healthy state ==="

fixture "$MANIFEST"
mkdir -p "$H/.config"; ln -s "$R/claude/tenants.zsh" "$H/.config/claude-tenants.zsh"
out="$(run "$R" "$H")"
check "correct symlink: exit 0" "$(rc_of "$R" "$H")" "0"
has   "correct symlink: reports all clear" "$out" "all 1 declared links are symlinks"

echo
echo "=== THE ROW THIS FILE EXISTS FOR: a regular file whose content has diverged ==="

# 2026-09-15 exactly: the live copy carries an edit, the repo source does not,
# and `./install` is about to overwrite the live copy with the stale source.
fixture "$MANIFEST"
mkdir -p "$H/.config"; printf 'POOL=edited-live-only\n' > "$H/.config/claude-tenants.zsh"
out="$(run "$R" "$H")"
check "diverged copy: exit 1"                    "$(rc_of "$R" "$H")" "1"
has   "diverged copy: names the real condition"  "$out" "is a REGULAR FILE, not a symlink"
has   "diverged copy: says the source is inert"  "$out" "INERT"
has   "diverged copy: warns install will clobber" "$out" "BACK IT UP AND OVERWRITE IT"
has   "diverged copy: tells you to save the edit first" "$out" "copy any wanted edits into"

echo
echo "=== a regular file whose content still matches ==="

# Same fault, lower stakes, and it must NOT claim an edit is about to be lost —
# a checker that cries the same wolf for both teaches you to ignore the loud one.
fixture "$MANIFEST"
mkdir -p "$H/.config"; printf 'POOL=original\n' > "$H/.config/claude-tenants.zsh"
out="$(run "$R" "$H")"
check "identical copy: still exit 1"          "$(rc_of "$R" "$H")" "1"
has   "identical copy: still names the fault" "$out" "is a REGULAR FILE, not a symlink"
has   "identical copy: says nothing lost yet" "$out" "nothing is lost yet"
hasnt "identical copy: does NOT cry clobber"  "$out" "BACK IT UP AND OVERWRITE IT"

echo
echo "=== the other ways a link can be wrong ==="

# Missing entirely — declared but never installed.
fixture "$MANIFEST"
out="$(run "$R" "$H")"
check "missing target: exit 1"   "$(rc_of "$R" "$H")" "1"
has   "missing target: named"    "$out" "is missing — declared but never installed"

# A symlink, but into somewhere else entirely — e.g. a worktree or an old checkout.
fixture "$MANIFEST"
mkdir -p "$H/.config" "$TMP/elsewhere"; printf 'POOL=other\n' > "$TMP/elsewhere/tenants.zsh"
ln -s "$TMP/elsewhere/tenants.zsh" "$H/.config/claude-tenants.zsh"
out="$(run "$R" "$H")"
check "wrong-target symlink: exit 1" "$(rc_of "$R" "$H")" "1"
has   "wrong-target symlink: named"  "$out" "not to claude/tenants.zsh in this checkout"

# A declared source that is not in the tree. Unasserted, this NARROWS the check
# instead of failing it: a renamed source drops the file from coverage and the
# run still prints a green tick.
fixture "$MANIFEST"
rm -f "$R/claude/tenants.zsh"
mkdir -p "$H/.config"; ln -s "$R/claude/tenants.zsh" "$H/.config/claude-tenants.zsh"
out="$(run "$R" "$H")"
check "absent source: exit 1" "$(rc_of "$R" "$H")" "1"
has   "absent source: named"  "$out" "does not exist in this checkout"

echo
echo "=== an unanswerable question is a FAIL, never a pass ==="

# No manifest at all. "Zero faults found" is true and worthless here.
fixture "$MANIFEST"
rm -f "$R/install.conf.yaml"
out="$(run "$R" "$H")"
check "no manifest: exit 2 (could not run), not 1" "$(rc_of "$R" "$H")" "2"
has   "no manifest: says UNCHECKED" "$out" "links UNCHECKED"

# A link: block the parser cannot read. Same trap, one layer in.
fixture '- link:
'
out="$(run "$R" "$H")"
check "empty link block: exit 2 (could not run), not 1" "$(rc_of "$R" "$H")" "2"
has   "empty link block: refuses to call it clean" "$out" "declares nothing this parser recognises"

echo
echo "=== both entry shapes are parsed (the nested form is not skipped) ==="

# The manifest uses `target: source` AND `target:` + nested `path:`. A parser
# that ends the nested block at `path:` reads the sibling `relink:`/`backup:`
# keys as further link entries — measured: 7 entries from a 5-entry manifest,
# two fabricated failures naming sources "true" and "false".
fixture '- link:
    ~/.config/claude-tenants.zsh: claude/tenants.zsh

    ~/.config/nested.sh:
      path: claude/nested.sh
      relink: true
      backup: false
'
printf 'x\n' > "$R/claude/nested.sh"
mkdir -p "$H/.config"
ln -s "$R/claude/tenants.zsh" "$H/.config/claude-tenants.zsh"
ln -s "$R/claude/nested.sh"   "$H/.config/nested.sh"
out="$(run "$R" "$H")"
check "nested form: exit 0"                  "$(rc_of "$R" "$H")" "0"
has   "nested form: exactly 2 links counted" "$out" "manifest: 2 declared links"
has   "nested form: the nested entry IS checked" "$out" "→ claude/nested.sh"
hasnt "nested form: 'relink' is not an entry" "$out" "relink —"
hasnt "nested form: 'backup' is not an entry" "$out" "backup —"

echo
echo "=== a conditional entry is still checked, not dropped ==="

# There is no `if:` entry today. When one is added it must not vanish from the
# check — a checker that quietly shrinks is the failure mode being fixed. But it
# must not be judged as BROKEN when absent either: dotbot only creates a
# conditional link when its `if:` succeeds, this checker does not evaluate that
# condition, and a correct absence reported as a fault is how a checker becomes
# one nobody reads. So: visible, counted, and not a failure.
CONDMANIFEST='- link:
    ~/.config/cond.sh:
      path: claude/cond.sh
      if: "true"
'
fixture "$CONDMANIFEST"
printf 'x\n' > "$R/claude/cond.sh"
out="$(run "$R" "$H")"
check "conditional absent: exit 0, not judged" "$(rc_of "$R" "$H")" "0"
has   "conditional absent: still counted"      "$out" "manifest: 1 declared links"
has   "conditional absent: visible, not silent" "$out" "its entry is conditional — not judged"

# Present, but a regular file: a conditional entry gets no free pass once it
# exists. This is the row that stops "conditional" becoming "unchecked".
fixture "$CONDMANIFEST"
printf 'x\n' > "$R/claude/cond.sh"
mkdir -p "$H/.config"; printf 'y\n' > "$H/.config/cond.sh"
out="$(run "$R" "$H")"
check "conditional present: exit 1"      "$(rc_of "$R" "$H")" "1"
has   "conditional present: fully checked" "$out" "is a REGULAR FILE, not a symlink"

# A NON-conditional entry that is absent is still a hard failure — the note
# above must be keyed on `if:`, not handed to every missing target.
fixture "$MANIFEST"
out="$(run "$R" "$H")"
check "plain absent: still exit 1" "$(rc_of "$R" "$H")" "1"
hasnt "plain absent: gets no conditional excuse" "$out" "not judged"

echo
echo "=== --quiet ==="

fixture "$MANIFEST"
out="$(REPO_ROOT="$R" HOME="$H" bash "$CHECK" --quiet 2>&1)"
REPO_ROOT="$R" HOME="$H" bash "$CHECK" --quiet >/dev/null 2>&1; qrc=$?
check "quiet: prints nothing" "$out" ""
check "quiet: keeps the exit code" "$qrc" "1"

echo
echo "=== --tsv: one line per declared entry, one state each ==="

tsv_of() { REPO_ROOT="$1" HOME="$2" bash "$CHECK" --tsv 2>/dev/null; }
state_of() { awk -F'\t' -v t="$2" '$2 == t { print $1 }' <<<"$1"; }

# Every state in one fixture: seven entries, seven distinct states.
STATES_MANIFEST='- link:
    ~/.ok: claude/ok
    ~/.missing: claude/missing-target
    ~/.wrong: claude/wrong
    ~/.same: claude/same
    ~/.differs: claude/differs
    ~/.gone: claude/does-not-exist
    ~/.cond:
      path: claude/cond
      if: "true"
'
fixture "$STATES_MANIFEST"
for f in ok missing-target wrong same differs cond; do printf 'src-%s\n' "$f" > "$R/claude/$f"; done
ln -s "$R/claude/ok" "$H/.ok"
mkdir -p "$TMP/elsewhere$n"; printf 'other\n' > "$TMP/elsewhere$n/wrong"
ln -s "$TMP/elsewhere$n/wrong" "$H/.wrong"
printf 'src-same\n' > "$H/.same"
printf 'live-edit\n' > "$H/.differs"
tsv="$(tsv_of "$R" "$H")"
check "--tsv prints one state per declared entry" "$(wc -l <<<"$tsv" | tr -d ' ')" "7"
check "--tsv: ok"                 "$(state_of "$tsv" '~/.ok')"      "ok"
check "--tsv: missing"            "$(state_of "$tsv" '~/.missing')" "missing"
check "--tsv: wrong-target"       "$(state_of "$tsv" '~/.wrong')"   "wrong-target"
check "--tsv: a regular file with identical content is regular-identical" "$(state_of "$tsv" '~/.same')" "regular-identical"
check "--tsv: a regular file with other content is regular-differs"       "$(state_of "$tsv" '~/.differs')" "regular-differs"
check "--tsv: source-missing"     "$(state_of "$tsv" '~/.gone')"    "source-missing"
check "--tsv: a conditional entry that is absent is conditional-absent"   "$(state_of "$tsv" '~/.cond')" "conditional-absent"
check "--tsv: the source column is the declared source" "$(awk -F'\t' '$2 == "~/.ok" { print $3 }' <<<"$tsv")" "claude/ok"
check "--tsv: faults make exit 1" "$(REPO_ROOT="$R" HOME="$H" bash "$CHECK" --tsv >/dev/null 2>&1; printf '%s' "$?")" "1"
check "--tsv prints nothing but entry lines" "$(awk -F'\t' 'NF != 3 { bad++ } END { print bad + 0 }' <<<"$tsv")" "0"

# A conditional entry that IS present is checked like any other.
fixture "$CONDMANIFEST"
printf 'x\n' > "$R/claude/cond.sh"; mkdir -p "$H/.config"; ln -s "$R/claude/cond.sh" "$H/.config/cond.sh"
check "--tsv: a conditional entry that is present is checked (ok)" "$(awk -F'\t' '{print $1}' <<<"$(tsv_of "$R" "$H")")" "ok"

# One linked entry plus one ABSENT conditional one, under --tsv: exit 0, both states.
fixture '- link:
    ~/.linked: claude/linked
    ~/.absent-cond:
      path: claude/absent-cond
      if: "true"
'
printf 'x\n' > "$R/claude/linked"; printf 'y\n' > "$R/claude/absent-cond"; ln -s "$R/claude/linked" "$H/.linked"
check "--tsv: only ok and conditional-absent is exit 0" "$(REPO_ROOT="$R" HOME="$H" bash "$CHECK" --tsv >/dev/null 2>&1; printf '%s' "$?")" "0"
check "--tsv: that run shows both states" "$(tsv_of "$R" "$H" | awk -F'\t' '{print $1}' | sort | tr '\n' ' ')" "conditional-absent ok "

echo
echo "=== --config and --root ==="

# --config points the parser at another manifest; the default manifest here is
# absent, so only the flag can make this exit 0.
fixture "$MANIFEST"
mkdir -p "$H/.config"; ln -s "$R/claude/tenants.zsh" "$H/.config/claude-tenants.zsh"
mv "$R/install.conf.yaml" "$R/other-manifest.yaml"
configrc="$(HOME="$H" bash "$CHECK" --root "$R" --config "$R/other-manifest.yaml" >/dev/null 2>&1; printf '%s' "$?")"
check "--config points the parser at another manifest" "$configrc" "0"
check "--config: a relative path is taken from the root" \
    "$(cd "$TMP" && HOME="$H" bash "$CHECK" --root "$R" --config other-manifest.yaml >/dev/null 2>&1; printf '%s' "$?")" "0"
check "without --config the default manifest is <root>/install.conf.yaml (absent: exit 2)" \
    "$(HOME="$H" bash "$CHECK" --root "$R" >/dev/null 2>&1; printf '%s' "$?")" "2"

# --root resolves sources against that checkout: the same link is right for one
# checkout and wrong for another.
fixture "$MANIFEST"
mkdir -p "$H/.config"; ln -s "$R/claude/tenants.zsh" "$H/.config/claude-tenants.zsh"
OTHER_CHECKOUT="$TMP/other-checkout$n"
mkdir -p "$OTHER_CHECKOUT/claude"; printf 'POOL=original\n' > "$OTHER_CHECKOUT/claude/tenants.zsh"
cp "$R/install.conf.yaml" "$OTHER_CHECKOUT/install.conf.yaml"
check "--root resolves sources against that checkout (its own: ok)" \
    "$(HOME="$H" bash "$CHECK" --root "$R" --tsv 2>/dev/null | awk -F'\t' '{print $1}')" "ok"
check "--root resolves sources against that checkout (another: wrong-target)" \
    "$(HOME="$H" bash "$CHECK" --root "$OTHER_CHECKOUT" --tsv 2>/dev/null | awk -F'\t' '{print $1}')" "wrong-target"
check "--root beats REPO_ROOT" \
    "$(REPO_ROOT="$OTHER_CHECKOUT" HOME="$H" bash "$CHECK" --root "$R" --tsv 2>/dev/null | awk -F'\t' '{print $1}')" "ok"

echo
echo "=== could not run is exit 2 in both modes, and --tsv prints no state ==="

fixture "$MANIFEST"; rm -f "$R/install.conf.yaml"
check "an unreadable config is exit 2, not 1 (--tsv)" "$(REPO_ROOT="$R" HOME="$H" bash "$CHECK" --tsv >/dev/null 2>&1; printf '%s' "$?")" "2"
check "an unreadable config prints no TSV line" "$(tsv_of "$R" "$H")" ""
fixture '- link:
'
check "a parser that recognises nothing is exit 2 (--tsv)" "$(REPO_ROOT="$R" HOME="$H" bash "$CHECK" --tsv >/dev/null 2>&1; printf '%s' "$?")" "2"
check "a parser that recognises nothing prints no TSV line" "$(tsv_of "$R" "$H")" ""
# An empty value must never fall back to the default: that would report another repository's links.
# The fixture must be a READABLE manifest, or the fallback would also exit 2 and the row prove nothing.
fixture "$MANIFEST"
EMPTY_ROOT_OUT="$(REPO_ROOT="$R" HOME="$H" bash "$CHECK" --root "" --tsv 2>/dev/null; printf 'rc=%s' "$?")"
check '--root "" is could-not-run (2) with empty stdout' "$EMPTY_ROOT_OUT" "rc=2"
EMPTY_CONFIG_OUT="$(REPO_ROOT="$R" HOME="$H" bash "$CHECK" --config "" --tsv 2>/dev/null; printf 'rc=%s' "$?")"
check '--config "" is could-not-run (2) with empty stdout' "$EMPTY_CONFIG_OUT" "rc=2"

# The could-not-run message is on stderr, and stdout stays empty, in both quiet modes.
fixture "$MANIFEST"; rm -f "$R/install.conf.yaml"
for mode in --tsv --quiet; do
    stdout_text="$(REPO_ROOT="$R" HOME="$H" bash "$CHECK" "$mode" 2>/dev/null)"
    stderr_text="$(REPO_ROOT="$R" HOME="$H" bash "$CHECK" "$mode" 2>&1 >/dev/null)"
    check "$mode: unreadable config leaves stdout empty" "$stdout_text" ""
    has   "$mode: unreadable config names the fault on stderr" "$stderr_text" "links UNCHECKED"
done
check "an unknown flag is exit 2" "$(REPO_ROOT="$R" HOME="$H" bash "$CHECK" --bogus >/dev/null 2>&1; printf '%s' "$?")" "2"

echo
echo "=== the public manifest shape ==="

# The shape install.conf.yaml really has: defaults, plain entries, and a key with
# a nested path, relink, backup and if. Two top-level blocks must not bleed.
fixture '- defaults:
    link:
      create: true
      relink: true

- clean: ["~"]

- link:
    ~/.plain: claude/tenants.zsh
    ~/.nested:
      path: claude/nested.sh
      relink: true
      if: "[ -d ~/.config ]"
    ~/.after: claude/tenants.zsh

- shell:
    - [true, x]
'
printf 'x\n' > "$R/claude/nested.sh"
ln -s "$R/claude/tenants.zsh" "$H/.plain"; ln -s "$R/claude/nested.sh" "$H/.nested"
tsv="$(tsv_of "$R" "$H")"
check "the public manifest shape (a key with a nested path and if) parses: 3 entries" "$(wc -l <<<"$tsv" | tr -d ' ')" "3"
check "the nested entry is checked, not conditional-absent" "$(state_of "$tsv" '~/.nested')" "ok"
check "the entry after the nested one is still read (as missing)" "$(state_of "$tsv" '~/.after')" "missing"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
EXPECTED_ROWS=69
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '\033[1;31mROW COUNT\033[0m: expected %d rows, %d ran — a check vanished or was added without updating EXPECTED_ROWS\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))" >&2
    exit 1
fi
[[ "$FAIL" -eq 0 ]]
