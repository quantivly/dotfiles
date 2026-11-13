#!/usr/bin/env bash
#
# scripts/test-resource-pulse-sampler.sh
# =======================================
#
# State table for the compiled Resource Pulse sampler (resource-pulse-sampler/).
# It counts each cargo test as a row (the sum of cargo's `test result:` lines),
# then runs the checks each later task adds:
#   - one row per constant, comparing the program's `--print-constants` with the
#     gjs lib/constants.js and lib/protocol.js (gnome-shell/tests/sampler-constants.js),
#     and rows proving that comparison fails when a value changes on one side;
#   - one row per gjs test title the crate must carry over (scripts/resource-pulse-sampler-carried-rows.sh),
#     and rows proving that check fails for a missing, a duplicated and a
#     double-counted title, an unknown exempt title, and an unreadable list.
# The program is not run by anything on the machine; nothing here starts a
# service, touches the session bus or reads a process's command line.
#
# "Could not run" is exit 2, never a pass: a missing cargo, gjs, dbus-run-session,
# rg, python3 or script, or a cargo run that prints no `test result:` line, is
# fatal or a failed row. The suite asserts its own row total.
#
# Requires: bash, cargo, gjs, dbus-run-session (Ubuntu: dbus-daemon; later tasks
# run the program on a private bus), rg, python3. Needs the network the first time
# (crates.io); no root.
#
# Usage: scripts/test-resource-pulse-sampler.sh
#   CARGO_TARGET_DIR   cargo's build directory (default: ${XDG_CACHE_HOME:-$HOME/.cache}/resource-pulse/cargo-target)
#   CARGO_BUILD_JOBS, RUST_TEST_THREADS   worker caps (default: FALLBACK_WORKER_COUNT; an interactive shell has zshrc.buildlimits's)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DOTFILES="$(cd "$HERE/.." && pwd -P)"
CRATE_DIR="$DOTFILES/resource-pulse-sampler"
MANIFEST_PATH="$CRATE_DIR/Cargo.toml"
CONSTANTS_COMPARISON="$DOTFILES/gnome-shell/tests/sampler-constants.js"
CARRIED_ROWS_CHECK="$HERE/resource-pulse-sampler-carried-rows.sh"
CARRIED_ROWS_GENERATOR="$HERE/resource-pulse-sampler-carried-rows-generate.py"
CARRIED_ROWS_LIST_FILE="$CRATE_DIR/tests/carried-rows.txt"

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

for required_tool in cargo gjs dbus-run-session rg python3 awk; do
  command -v "$required_tool" >/dev/null || fatal "$required_tool is required"
done
[[ -r "$MANIFEST_PATH" ]] || fatal "cannot read $MANIFEST_PATH"
[[ -r "$CONSTANTS_COMPARISON" ]] || fatal "cannot read $CONSTANTS_COMPARISON"
[[ -x "$CARRIED_ROWS_CHECK" ]] || fatal "cannot run $CARRIED_ROWS_CHECK"
[[ -r "$CARRIED_ROWS_GENERATOR" ]] || fatal "cannot read $CARRIED_ROWS_GENERATOR"

# Workers for cargo's build and its tests when the caller's environment sets neither. The interactive cap comes from
# zsh/zshrc.buildlimits (which exports both variables); this is only the fallback for a non-interactive run.
FALLBACK_WORKER_COUNT=4
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$FALLBACK_WORKER_COUNT}"
export RUST_TEST_THREADS="${RUST_TEST_THREADS:-$FALLBACK_WORKER_COUNT}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/resource-pulse/cargo-target}"

WORK_DIR="$(mktemp -d)" || fatal "mktemp -d failed"
trap 'rm -rf "$WORK_DIR"' EXIT

printf 'cargo test: one row per test\n'
CARGO_TEST_OUTPUT="$(cargo test --locked --manifest-path "$MANIFEST_PATH" 2>&1)"
CARGO_TEST_EXIT=$?
# Sum every `test result: ... N passed; M failed;` line (unit, integration and doc test binaries each print one).
read -r CARGO_PASSED CARGO_FAILED CARGO_RESULT_LINES < <(
  printf '%s\n' "$CARGO_TEST_OUTPUT" | awk '
    /^test result: / {
      lines++
      for (i = 1; i <= NF; i++) {
        if ($i == "passed;") passed += $(i - 1)
        if ($i == "failed;") failed += $(i - 1)
      }
    }
    END { printf "%d %d %d\n", passed, failed, lines }')
if (( CARGO_RESULT_LINES == 0 )); then
  printf '%s\n' "$CARGO_TEST_OUTPUT" | tail -15
  bad "cargo test printed no \`test result:\` line (exit $CARGO_TEST_EXIT): it did not run, which is a failure and not zero rows"
else
  for ((row = 0; row < CARGO_PASSED; row++)); do ok "cargo test $((row + 1)) of $CARGO_PASSED passed"; done
  for ((row = 0; row < CARGO_FAILED; row++)); do bad "cargo test failed ($((row + 1)) of $CARGO_FAILED)"; done
  if (( CARGO_TEST_EXIT != 0 && CARGO_FAILED == 0 )); then
    printf '%s\n' "$CARGO_TEST_OUTPUT" | tail -15
    bad "cargo test exited $CARGO_TEST_EXIT with no failed test counted"
  fi
  (( CARGO_FAILED == 0 )) || printf '%s\n' "$CARGO_TEST_OUTPUT" | rg '^(test .* FAILED|failures:)'
fi

printf '\nthe program\n'
if cargo build --locked --manifest-path "$MANIFEST_PATH" >"$WORK_DIR/build.log" 2>&1; then
  ok "cargo build --locked builds the program"
else
  tail -15 "$WORK_DIR/build.log"
  bad "cargo build --locked failed"
fi
PROGRAM_PATH="$CARGO_TARGET_DIR/debug/resource-pulse-sampler"
[[ -x "$PROGRAM_PATH" ]] || fatal "no program at $PROGRAM_PATH"
"$PROGRAM_PATH" --print-constants >/dev/null
check "--print-constants exits 0" "$?" 0
"$PROGRAM_PATH" >/dev/null 2>"$WORK_DIR/usage.err"
check "no argument: exit 2" "$?" 2
check "no argument: a one-line usage on stderr" "$(wc -l <"$WORK_DIR/usage.err" | tr -d ' ')" 1
"$PROGRAM_PATH" --nonsense >/dev/null 2>&1
check "an unknown argument: exit 2" "$?" 2

# print_constant_rows <program> runs the gjs comparison against <program> and turns each CONSTANT-ROW line into a row.
# It sets COMPARISON_EXIT and COMPARISON_OUTPUT; a run that printed no tally is a failed row.
run_constants_comparison() {
  COMPARISON_OUTPUT="$(gjs -m "$CONSTANTS_COMPARISON" "$1" 2>&1)"
  COMPARISON_EXIT=$?
}
printf '\nthe constants, one row per name, against lib/constants.js and lib/protocol.js\n'
run_constants_comparison "$PROGRAM_PATH"
while IFS= read -r comparison_line; do
  case "$comparison_line" in
    "CONSTANT-ROW pass "*) ok "constant ${comparison_line#CONSTANT-ROW pass }" ;;
    "CONSTANT-ROW fail "*) bad "constant ${comparison_line#CONSTANT-ROW fail }" ;;
  esac
done <<<"$COMPARISON_OUTPUT"
check "the comparison printed its tally of 26 names and exited 0" \
  "$(printf '%s\n' "$COMPARISON_OUTPUT" | rg -c -x 'CONSTANT-TALLY names=26'):$COMPARISON_EXIT" "1:0"

# A stand-in program that prints the real program's constants after an `sed` edit, to prove the comparison can fail.
make_edited_program() {
  local stand_in_path="$WORK_DIR/$1" sed_script="$2"
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # the stand-in's own $1 must stay literal
    printf 'if [[ "$1" != --print-constants ]]; then exit 2; fi\n'
    printf '"%s" --print-constants | sed -e %q\n' "$PROGRAM_PATH" "$sed_script"
  } >"$stand_in_path"
  chmod +x "$stand_in_path"
  printf '%s' "$stand_in_path"
}
printf '\nthe constants comparison fails when one side changes\n'
run_constants_comparison "$(make_edited_program changed-value 's/^BURST_COOLDOWN_TICKS=2$/BURST_COOLDOWN_TICKS=3/')"
check "a value changed on the Rust side: exit 1, that one name fails" \
  "$COMPARISON_EXIT:$(printf '%s\n' "$COMPARISON_OUTPUT" | rg -c '^CONSTANT-ROW fail BURST_COOLDOWN_TICKS javascript 2 but program 3$')" "1:1"
run_constants_comparison "$(make_edited_program lacking-name '/^KERNEL_LABEL=/d')"
check "a name the program lacks: exit 1, it fails as not printed" \
  "$COMPARISON_EXIT:$(printf '%s\n' "$COMPARISON_OUTPUT" | rg -c '^CONSTANT-ROW fail KERNEL_LABEL the program does not print it$')" "1:1"
# shellcheck disable=SC2016 # `$a` is sed's address for the last line
run_constants_comparison "$(make_edited_program extra-name '$a EXTRA_ONLY_ON_RUST_SIDE=1')"
check "a name only the program has: exit 1, it fails as not listed" \
  "$COMPARISON_EXIT:$(printf '%s\n' "$COMPARISON_OUTPUT" | rg -c '^CONSTANT-ROW fail EXTRA_ONLY_ON_RUST_SIDE the program prints it and the comparison does not list it$')" "1:1"
run_constants_comparison "$(make_edited_program changed-list 's/\[10,25,50\]/[10,25,51]/')"
check "a list changed on the Rust side: exit 1" \
  "$COMPARISON_EXIT:$(printf '%s\n' "$COMPARISON_OUTPUT" | rg -c '^CONSTANT-ROW fail PRESSURE_BAND_THRESHOLDS_PERCENT ')" "1:1"
run_constants_comparison "$WORK_DIR/no-such-program"
check "a program that cannot run is exit 2, never a pass" "$COMPARISON_EXIT" 2

printf '\nthe gjs rows the crate must carry over\n'
CARRIED_OUTPUT="$("$CARRIED_ROWS_CHECK" 2>&1)"
CARRIED_EXIT=$?
while IFS= read -r carried_line; do
  case "$carried_line" in
    "CARRIED-ROW pass "*) ok "${carried_line#CARRIED-ROW pass }" ;;
    "CARRIED-ROW fail "*) bad "${carried_line#CARRIED-ROW fail }" ;;
  esac
done <<<"$CARRIED_OUTPUT"
check "the carried-rows check exits 0" "$CARRIED_EXIT" 0
check "the list holds 179 titles: 55, 9, 16, 22, 41, 36" \
  "$(rg -c -v '^#' "$CARRIED_ROWS_LIST_FILE"):$(for file_stem in service-sampler service-dbus parsers math apps cadence; do awk -v heading="# $file_stem" '$0 == heading { inside = 1; next } /^#/ { inside = 0 } inside { count++ } END { printf "%d ", count }' "$CARRIED_ROWS_LIST_FILE"; done)" \
  "179:55 9 16 22 41 36 "
check "the list is exactly what the generator writes from the six gjs files" \
  "$(python3 -I "$CARRIED_ROWS_GENERATOR" | cmp -s - "$CARRIED_ROWS_LIST_FILE" && echo same || echo different)" same

printf '\nthe carried-rows check fails when it should\n'
FIXTURE_TITLES=$'# fixture\nAlpha row\nBeta row\nGamma row'
# write_carried_fixture <name> <exempt text> <rust text> builds a crate directory of its own and prints its path.
write_carried_fixture() {
  local fixture_dir="$WORK_DIR/$1"
  mkdir -p "$fixture_dir/src" "$fixture_dir/tests"
  printf '%s\n' "$FIXTURE_TITLES" >"$fixture_dir/tests/carried-rows.txt"
  printf '%s' "$2" >"$fixture_dir/tests/carried-rows-exempt.txt"
  printf '%s' "$3" >"$fixture_dir/src/lib.rs"
  printf '%s' "$fixture_dir"
}
# run_carried_fixture <dir> runs the check on a fixture crate; sets FIXTURE_OUTPUT and FIXTURE_EXIT.
run_carried_fixture() {
  FIXTURE_OUTPUT="$("$CARRIED_ROWS_CHECK" --crate-dir "$1" --list "${2:-$1/tests/carried-rows.txt}" --exempt "$1/tests/carried-rows-exempt.txt" 2>&1)"
  FIXTURE_EXIT=$?
}
BASELINE_FIXTURE="$(write_carried_fixture baseline $'Beta row\tnot yet ported\nGamma row\tnot yet ported\n' $'/// row: Alpha row\n')"
run_carried_fixture "$BASELINE_FIXTURE"
check "one ported, two exempt: exit 0, three passing lines" "$FIXTURE_EXIT:$(printf '%s\n' "$FIXTURE_OUTPUT" | rg -c '^CARRIED-ROW pass ')" "0:3"
MISSING_FIXTURE="$(write_carried_fixture missing $'Beta row\tnot yet ported\n' $'/// row: Alpha row\n')"
run_carried_fixture "$MISSING_FIXTURE"
check "a title found nowhere: exit 1, named as missing" "$FIXTURE_EXIT:$(printf '%s\n' "$FIXTURE_OUTPUT" | rg -c -x 'CARRIED-ROW fail missing: Gamma row')" "1:1"
DUPLICATED_FIXTURE="$(write_carried_fixture duplicated $'Beta row\tnot yet ported\nGamma row\tnot yet ported\n' $'/// row: Alpha row\n/// row: Alpha row\n')"
run_carried_fixture "$DUPLICATED_FIXTURE"
check "a title ported twice: exit 1, named as duplicated" "$FIXTURE_EXIT:$(printf '%s\n' "$FIXTURE_OUTPUT" | rg -c -x 'CARRIED-ROW fail duplicated: Alpha row')" "1:1"
BOTH_FIXTURE="$(write_carried_fixture both $'Alpha row\tnot yet ported\nBeta row\tnot yet ported\nGamma row\tnot yet ported\n' $'/// row: Alpha row\n')"
run_carried_fixture "$BOTH_FIXTURE"
check "a title both ported and exempt: exit 1, named as such" "$FIXTURE_EXIT:$(printf '%s\n' "$FIXTURE_OUTPUT" | rg -c -x 'CARRIED-ROW fail ported-and-exempt: Alpha row')" "1:1"
UNKNOWN_FIXTURE="$(write_carried_fixture unknown $'Beta row\tnot yet ported\nGamma row\tnot yet ported\nDelta row\tnot a gjs row\n' $'/// row: Alpha row\n')"
run_carried_fixture "$UNKNOWN_FIXTURE"
check "an exempt title the list lacks: exit 1, named as unknown" "$FIXTURE_EXIT:$(printf '%s\n' "$FIXTURE_OUTPUT" | rg -c -x 'CARRIED-ROW fail unknown-exempt: Delta row')" "1:1"
run_carried_fixture "$BASELINE_FIXTURE" "$WORK_DIR/no-such-list.txt"
check "a list that cannot be read: exit 2, no pass line" "$FIXTURE_EXIT:$(printf '%s\n' "$FIXTURE_OUTPUT" | rg '^CARRIED-ROW ' | wc -l | tr -d ' ')" "2:0"

EMPTY_FIXTURE="$(write_carried_fixture empty $'' $'')"
printf '# only a heading\n' >"$EMPTY_FIXTURE/tests/carried-rows.txt"
run_carried_fixture "$EMPTY_FIXTURE"
check "a list with no titles: exit 2, no pass line" "$FIXTURE_EXIT:$(printf '%s\n' "$FIXTURE_OUTPUT" | rg '^CARRIED-ROW ' | wc -l | tr -d ' ')" "2:0"
"$CARRIED_ROWS_CHECK" --no-such-flag >/dev/null 2>&1
check "an unknown flag: exit 2" "$?" 2

EXPECTED_ROWS=229

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( PASS + FAIL != EXPECTED_ROWS )); then
  printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
    "$EXPECTED_ROWS" "$((PASS + FAIL))"
  FAIL=$((FAIL + 1))
fi
(( FAIL == 0 ))
