#!/usr/bin/env bash
#
# scripts/test-wt-gc-sweep.sh
# ===========================
#
# State table for scripts/wt-gc-sweep.sh.
#
# HERMETIC via a recording `wt-gc` STUB at the front of PATH — never by relying
# on wt-gc being absent. This machine has a real one at ~/.local/bin/wt-gc that
# scans every repository it owns and, with --apply, DELETES worktrees and
# branches. A suite that depended on absence would pass on a CI runner and reap
# this machine.
#
# The rows that matter are the two the wrapper exists for: the argv it builds
# (that is the whole policy — scope, grace, branches) and the exit status it
# derives, because wt-gc exits 1 for a warning and for a real failure alike.
#
# "Could not run" is exit 2, never a pass.
#
# Usage: scripts/test-wt-gc-sweep.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="${SWEEP:-$HERE/wt-gc-sweep.sh}"

PASS=0; FAIL=0
ok()  { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
[[ -x "$SWEEP" ]] || { printf 'FATAL: not executable: %s\n' "$SWEEP" >&2; exit 2; }

T="$(mktemp -d)" || { printf 'FATAL: no temp dir\n' >&2; exit 2; }
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/scope" "$T/state" || { printf 'FATAL: setup\n' >&2; exit 2; }

# The stub records CMD (the joined line) and one ARG per argument. A joined line
# alone cannot fail the way that matters: a mangled argument differs from a
# correct one only in where the boundaries fall.
cat > "$T/bin/wt-gc" <<'STUB'
#!/usr/bin/env bash
{ printf 'CMD %s\n' "$*"; for a in "$@"; do printf 'ARG %s\n' "$a"; done; } >> "$STUB_LOG"
[[ -n "${STUB_OUT:-}" && -r "${STUB_OUT:-}" ]] && cat "$STUB_OUT"
[[ -n "${STUB_ERR:-}" && -r "${STUB_ERR:-}" ]] && cat "$STUB_ERR" >&2
exit "${STUB_RC:-0}"
STUB
chmod +x "$T/bin/wt-gc" || { printf 'FATAL: setup\n' >&2; exit 2; }

# A report with one of every row type, then the action rows an --apply adds. The
# path on the last REMOVED row contains the words the counter looks for, so a
# counter that greps the line instead of testing field 1 over-counts.
printf '%s\n' \
  "REAP	/home/zvi/.herdr/worktrees/x/a	zvi/a	MERGED	0	0	3	PR merged; clean" \
  "KEEP	/home/zvi/.herdr/worktrees/x/b	zvi/b	none	0	0	0	in use by 1 process(es)" \
  "DANGLING	/home/zvi/Projects/x	zvi/c	REAP	PR merged; every commit on a remote" \
  "STRAY	/home/zvi/loose" \
  "REMOVED	/home/zvi/.herdr/worktrees/x/a	12M" \
  "DELETED	zvi/c	~/Projects/x" \
  "SKIPPED	/home/zvi/.herdr/worktrees/x/b	in use by 1 process(es) since the scan" \
  "PRUNED	/home/zvi/Projects/x" \
  "REMOVED	/home/zvi/.herdr/worktrees/x/FAILED-DELETED-PRUNED	1M" \
  > "$T/report.tsv"
# %b, not %s: printf interprets escapes in the FORMAT, never in an argument, so
# %s here writes literal backslash-t and the fixture silently has no columns.
printf '%b\n' \
  "WOULD-REMOVE\t/home/zvi/.herdr/worktrees/x/a\t12M" \
  "WOULD-DELETE\tzvi/a\t~/Projects/x" \
  "WOULD-REMOVE\t/home/zvi/.herdr/worktrees/x/c\t4M" \
  "WOULD-DELETE\tzvi/c\t~/Projects/x" \
  "WOULD-DELETE\tzvi/d\t~/Projects/x" \
  "WOULD-SKIP\t/home/zvi/.herdr/worktrees/x/b\tlanded 0d ago, under the 2-day grace" \
  > "$T/plan.tsv"
printf 'wt-gc: warning: could not list the worktrees of /home/zvi/quantivly/ci: fatal\n' > "$T/warn.txt"
printf 'FAILED	/home/zvi/.herdr/worktrees/x/a	is not a working tree\n' > "$T/failed.tsv"

run() {  # run [env assignments via caller] -- args...
  : > "$T/log"
  STUB_LOG="$T/log" PATH="$T/bin:$PATH" \
  WT_GC_SWEEP_SCOPE="${SCOPE_OVERRIDE:-$T/scope}" \
  WT_GC_SWEEP_MIN_AGE="${MIN_AGE_OVERRIDE:-2}" \
  WT_GC_SWEEP_STATE="$T/state" \
  STUB_OUT="${OUT_OVERRIDE:-$T/report.tsv}" STUB_ERR="${ERR_OVERRIDE:-}" STUB_RC="${RC_OVERRIDE:-0}" \
    "$SWEEP" "$@" >"$T/out" 2>"$T/err"
  echo $?
}
args()  { sed -n 's/^ARG //p' "$T/log" | paste -sd'|' -; }
ncalls() { grep -c '^CMD ' "$T/log"; }

printf 'the argv the policy builds\n'
rc="$(run)"
check "exits 0 on a clean run" "$rc" 0
check "wt-gc is called once" "$(ncalls)" 1
check "the full argument list, boundaries included" "$(args)" \
  "--tsv|--branches|--scope|$T/scope|--min-age|2|--apply"

rc="$(run --dry-run)"
check "--dry-run drops --apply and changes nothing else" "$(args)" \
  "--tsv|--branches|--scope|$T/scope|--min-age|2"
check "--dry-run still exits 0" "$rc" 0
# Counting only the action rows logged all zeros for a dry run that had just
# planned 201 removals — a line indistinguishable from a real sweep that found
# nothing, which is the one thing the audit trail must never be.
rc="$(OUT_OVERRIDE="$T/plan.tsv" run --dry-run)"
check "a dry run logs what it PLANNED, and says it was a dry run" \
  "$(sed -n '$s/^[^ ]* //p' "$T/state/log")" \
  "mode=dry removed=2 branches=3 pruned=0 skipped=1 failed=0 warnings=0"

rc="$(MIN_AGE_OVERRIDE=7 run)"
check "the grace period is configurable" "$(args)" \
  "--tsv|--branches|--scope|$T/scope|--min-age|7|--apply"

printf '\nexit status: wt-gc exits 1 for a warning AND for a failure\n'
rc="$(RC_OVERRIDE=1 ERR_OVERRIDE="$T/warn.txt" run)"
check "wt-gc 1 with warnings and no FAILED row -> 0" "$rc" 0
check "... and the warning reaches stderr" "$(grep -c 'could not list the worktrees' "$T/err")" 1

cat "$T/report.tsv" "$T/failed.tsv" > "$T/report-failed.tsv"
rc="$(RC_OVERRIDE=1 OUT_OVERRIDE="$T/report-failed.tsv" run)"
check "wt-gc 1 with a FAILED row -> 1" "$rc" 1

rc="$(RC_OVERRIDE=2 run)"
check "wt-gc 2 (a usage error, ours) -> 1" "$rc" 1
rc="$(RC_OVERRIDE=7 run)"
check "any other exit -> 1" "$rc" 1
rc="$(RC_OVERRIDE=0 ERR_OVERRIDE="$T/warn.txt" run)"
check "wt-gc 0 with a warning -> 0" "$rc" 0

printf '\nthe audit trail\n'
rc="$(run)"
check "the log line counts what the run reported" \
  "$(sed -n '$s/^[^ ]* //p' "$T/state/log")" \
  "mode=apply removed=2 branches=1 pruned=1 skipped=1 failed=0 warnings=0"
check "the full report is kept for later" \
  "$(grep -c '^DANGLING' "$T/state/last-run.tsv")" 1
check "the log line is timestamped in UTC" \
  "$(sed -n '$s/\(.\{20\}\).*/\1/p' "$T/state/log" | grep -c '^[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T.*Z$')" 1

printf '\nrefusals\n'
rc="$(SCOPE_OVERRIDE="$T/no-such-dir" run)"
check "a scope that does not exist -> 0, and says so" "$rc" 0
check "... and wt-gc is never called" "$(ncalls)" 0
rc="$(run --nope)"
check "an unknown argument -> 2" "$rc" 2
check "... and wt-gc is never called" "$(ncalls)" 0

: > "$T/log"
rc="$(PATH="$T/empty-bin:/usr/bin:/bin" WT_GC_SWEEP_SCOPE="$T/scope" WT_GC_SWEEP_STATE="$T/state" \
      WT_GC_SWEEP_BIN=wt-gc "$SWEEP" >/dev/null 2>"$T/err"; echo $?)"
check "no wt-gc on PATH -> 1" "$rc" 1
check "... and it names ~/.dotfiles-local rather than just failing" \
  "$(grep -c 'dotfiles-local' "$T/err")" 1

EXPECTED_ROWS=24

# --- the count this suite is documented as running ---------------------------
# docs_claim pins the number the prose quotes to EXPECTED_ROWS: it greps for a
# FIXED needle built from that number rather than parsing a count out of
# markdown, because a regex has to guess the shape of an English sentence and
# fails by matching nothing, which reads exactly like a pass. Whitespace is
# squashed because the sentence wraps. Which page owns this count and why:
# docs/REPO_CHECKS.md, "Where a check count lives".
docs_claim() {
  local f="$HERE/../$1"
  [[ -r "$f" ]] || { printf 'cannot read %s' "$1"; return; }
  tr -s '[:space:]' ' ' <"$f" \
    | grep -c -F "\`scripts/test-wt-gc-sweep.sh\` ($EXPECTED_ROWS checks"
}

printf '\nthe count this suite is documented as running\n'
check "docs/WORKTREE_SWEEP.md says $EXPECTED_ROWS checks" \
      "$(docs_claim docs/WORKTREE_SWEEP.md)" 1
# The unreadable branch needs a row of its own or nothing ever takes it, and an
# untaken branch is free to be wrong: in DO-698 a sweep caught this branch
# reporting "could not run" as a PASS, with every other row still green.
check "a documented file that cannot be read is not a pass" \
      "$(docs_claim no/such/file.md)" "cannot read no/such/file.md"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( PASS + FAIL != EXPECTED_ROWS )); then
  printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
    "$EXPECTED_ROWS" "$((PASS + FAIL))"
  FAIL=$((FAIL + 1))
fi
(( FAIL == 0 ))
