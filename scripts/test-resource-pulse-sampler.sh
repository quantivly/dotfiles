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
#     double-counted title, an unknown exempt title, and an unreadable list;
#   - the program's flags and exit statuses, and its bus rows: the program served
#     on a PRIVATE bus of this run (gnome-shell/tests/run-sampler-program.js under
#     `dbus-run-session`), holding the reply order, the start-up order, the name
#     flags and the answer to every call, and rows proving that runner refuses any
#     other bus;
#   - the bus link's rules, deterministically: the #[ignore]d tests of
#     resource-pulse-sampler/tests/bus_link.rs, each run with --ignored in a process
#     and on a private bus of its own (one row per test, as cargo's others), and a
#     row proving they refuse off it;
#   - a row that fails if zbus is built with its object server (`service`).
# Nothing here touches the live session bus. Every run of the program outside
# `dbus-run-session` gets BUS_BARRIER (a session bus address nobody listens on,
# in this run's directory, and a runtime directory of its own), so a program that
# tried to connect there could reach no bus at all; on the private bus it gets
# that bus's address, checked by the runner. Nothing reads a process's command line.
#
# "Could not run" is exit 2, never a pass: a missing cargo, gjs, dbus-run-session,
# rg, python3, setsid, timeout or script, a cargo run that prints no `test result:`
# line, or a bus runner that prints no tally, is fatal or a failed row. The suite
# asserts its own row total.
#
# Requires: bash, cargo, gjs, dbus-run-session (Ubuntu: dbus-daemon), setsid and
# timeout (util-linux, coreutils), rg, python3. Needs the network the first time
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
PRIVATE_BUS_RUNNER="$DOTFILES/gnome-shell/tests/run-sampler-program.js"
# The bus rows take about 15 s; the cap ends a hang, and KILL follows TERM for whatever outlives it.
PRIVATE_BUS_TIMEOUT_SECONDS=300
PRIVATE_BUS_KILL_AFTER_SECONDS=10
# The exit code libtest gives when a test failed (a cargo test run with a failing test exits 101).
LIBTEST_FAILED_EXIT_CODE=101
# How many constant names the program prints and the gjs comparison tallies.
EXPECTED_CONSTANT_NAME_COUNT=26
TALLY_PATTERN='^JS-TALLY pass=([0-9]+) fail=([0-9]+)$'

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

for required_tool in cargo gjs dbus-run-session setsid timeout rg python3 awk; do
  command -v "$required_tool" >/dev/null || fatal "$required_tool is required"
done
[[ -r "$MANIFEST_PATH" ]] || fatal "cannot read $MANIFEST_PATH"
[[ -r "$CONSTANTS_COMPARISON" ]] || fatal "cannot read $CONSTANTS_COMPARISON"
[[ -x "$CARRIED_ROWS_CHECK" ]] || fatal "cannot run $CARRIED_ROWS_CHECK"
[[ -r "$CARRIED_ROWS_GENERATOR" ]] || fatal "cannot read $CARRIED_ROWS_GENERATOR"
[[ -r "$PRIVATE_BUS_RUNNER" ]] || fatal "cannot read $PRIVATE_BUS_RUNNER"

# Workers for cargo's build and its tests when the caller's environment sets neither. The interactive cap comes from
# zsh/zshrc.buildlimits (which exports both variables); this is only the fallback for a non-interactive run.
FALLBACK_WORKER_COUNT=4
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$FALLBACK_WORKER_COUNT}"
export RUST_TEST_THREADS="${RUST_TEST_THREADS:-$FALLBACK_WORKER_COUNT}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/resource-pulse/cargo-target}"

WORK_DIR="$(mktemp -d)" || fatal "mktemp -d failed"
trap 'rm -rf "$WORK_DIR"' EXIT

# BUS_BARRIER: the environment of every program run outside the private bus. Its session bus address is a socket
# nobody listens on, and its runtime directory is this run's own, so neither the address nor the fallback under
# XDG_RUNTIME_DIR can lead to the live session bus.
BARRIER_RUNTIME_DIR="$WORK_DIR/barrier-runtime"
BARRIER_BUS_ADDRESS="unix:path=$WORK_DIR/barrier-no-session-bus"
if ! mkdir -p "$BARRIER_RUNTIME_DIR" || ! chmod 700 "$BARRIER_RUNTIME_DIR"; then
  fatal "cannot create the barrier's runtime directory $BARRIER_RUNTIME_DIR"
fi
BUS_BARRIER=(GSETTINGS_BACKEND=memory "DBUS_SESSION_BUS_ADDRESS=$BARRIER_BUS_ADDRESS" "XDG_RUNTIME_DIR=$BARRIER_RUNTIME_DIR")
# off_bus <command...> runs a command behind BUS_BARRIER.
off_bus() { env "${BUS_BARRIER[@]}" "$@"; }

# count_cargo_test_rows <label> <output> <exit status>: one row per test a cargo test run passed and one failed row
# per test it failed (the sums of its `test result: ... N passed; M failed;` lines: unit, integration and doc test
# binaries each print one), a failed row when it printed no such line (it did not run, which is a failure and not
# zero rows), and one when it exited non-zero with no failed test counted.
count_cargo_test_rows() {
  local test_label="$1" test_output="$2" test_exit="$3" passed_count failed_count result_line_count row
  read -r passed_count failed_count result_line_count < <(
    printf '%s\n' "$test_output" | awk '
      /^test result: / {
        lines++
        for (i = 1; i <= NF; i++) {
          if ($i == "passed;") passed += $(i - 1)
          if ($i == "failed;") failed += $(i - 1)
        }
      }
      END { printf "%d %d %d\n", passed, failed, lines }')
  if (( result_line_count == 0 )); then
    printf '%s\n' "$test_output" | tail -15
    bad "$test_label printed no \`test result:\` line (exit $test_exit): it did not run, which is a failure and not zero rows"
    return
  fi
  for ((row = 0; row < passed_count; row++)); do ok "$test_label $((row + 1)) of $passed_count passed"; done
  for ((row = 0; row < failed_count; row++)); do bad "$test_label failed ($((row + 1)) of $failed_count)"; done
  if (( test_exit != 0 && failed_count == 0 )); then
    printf '%s\n' "$test_output" | tail -15
    bad "$test_label exited $test_exit with no failed test counted"
  fi
  # Each failing test's name, and each panic with the three lines after it (an assert_eq! message takes three).
  (( failed_count == 0 )) || printf '%s\n' "$test_output" | rg --no-context-separator -A 3 "^(test .* FAILED|thread '[^']*'.* panicked at )"
}

printf 'cargo test: one row per test\n'
# Behind the barrier: a test that reached for a bus here, outside the #[ignore]d private-bus tests below, finds none.
CARGO_TEST_OUTPUT="$(off_bus cargo test --locked --manifest-path "$MANIFEST_PATH" 2>&1)"
count_cargo_test_rows "cargo test" "$CARGO_TEST_OUTPUT" "$?"

printf '\nthe program\n'
if cargo build --locked --manifest-path "$MANIFEST_PATH" >"$WORK_DIR/build.log" 2>&1; then
  ok "cargo build --locked builds the program"
else
  tail -15 "$WORK_DIR/build.log"
  bad "cargo build --locked failed"
fi
# zbus's object server answers calls on a task of its own, which would break the rule that one thread sends every
# message; it exists only with zbus's `service` feature, and with that off `#[interface]` and `serve_at` do not even
# compile. The features are read from cargo's own resolution of the graph, not from Cargo.toml's text, and the
# resolution must name `default-rt` (which the crate asks for), so a tree that could not be read is a failure.
ZBUS_FEATURE_TREE="$(off_bus cargo tree --locked --manifest-path "$MANIFEST_PATH" -e features -i zbus 2>&1)"
ZBUS_FEATURE_TREE_EXIT=$?
ZBUS_ENABLED_FEATURES=" $(printf '%s\n' "$ZBUS_FEATURE_TREE" | rg -o 'zbus feature "[^"]+"' | sed 's/^zbus feature "//; s/"$//' \
  | sort -u | tr '\n' ' ')"
zbus_resolution_verdict=unresolved
[[ "$ZBUS_ENABLED_FEATURES" == *" default-rt "* ]] && zbus_resolution_verdict=resolved
zbus_service_verdict=no-service
[[ "$ZBUS_ENABLED_FEATURES" == *" service "* ]] && zbus_service_verdict=service
check "zbus is built without its object server: cargo tree resolves its features, and \"service\" is not one" \
  "$ZBUS_FEATURE_TREE_EXIT/$zbus_resolution_verdict/$zbus_service_verdict" "0/resolved/no-service"
PROGRAM_PATH="$CARGO_TARGET_DIR/debug/resource-pulse-sampler"
[[ -x "$PROGRAM_PATH" ]] || fatal "no program at $PROGRAM_PATH"
off_bus "$PROGRAM_PATH" --print-constants >/dev/null
check "--print-constants exits 0" "$?" 0
off_bus "$PROGRAM_PATH" --tick-interval-ms >/dev/null 2>"$WORK_DIR/usage.err"
check "--tick-interval-ms without a number: exit 2" "$?" 2
check "--tick-interval-ms without a number: one line on stderr, and it is the usage" \
  "$(wc -l <"$WORK_DIR/usage.err" | tr -d ' '):$(rg -c '^usage: resource-pulse-sampler ' "$WORK_DIR/usage.err")" "1:1"
tick_interval_refusals=""
for refused_interval in 0 twenty -5 18446744073709551616; do
  off_bus "$PROGRAM_PATH" --tick-interval-ms "$refused_interval" >/dev/null 2>&1
  tick_interval_refusals+="$refused_interval=$? "
done
check "--tick-interval-ms refuses zero, a word, a negative and an overflow: exit 2 each" \
  "$tick_interval_refusals" "0=2 twenty=2 -5=2 18446744073709551616=2 "
off_bus "$PROGRAM_PATH" --nonsense >/dev/null 2>&1
check "an unknown argument: exit 2" "$?" 2
off_bus "$PROGRAM_PATH" >/dev/null 2>"$WORK_DIR/no-bus.err"
check "no flag and no bus to reach: exit 1, with one line on stderr" \
  "$?:$(wc -l <"$WORK_DIR/no-bus.err" | tr -d ' ')" "1:1"

# run_constants_comparison <program> runs the gjs comparison against <program>, which it runs with --print-constants,
# and sets COMPARISON_EXIT and COMPARISON_OUTPUT; a run that printed no tally is a failed row. Behind the barrier: a
# program whose --print-constants fell through to serving would find no bus, and exit 1 at once.
run_constants_comparison() {
  COMPARISON_OUTPUT="$(off_bus gjs -m "$CONSTANTS_COMPARISON" "$1" 2>&1)"
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
check "the comparison printed its tally of $EXPECTED_CONSTANT_NAME_COUNT names and exited 0" \
  "$(printf '%s\n' "$COMPARISON_OUTPUT" | rg -c -x "CONSTANT-TALLY names=$EXPECTED_CONSTANT_NAME_COUNT"):$COMPARISON_EXIT" "1:0"

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
UNKNOWN_PORTED_FIXTURE="$(write_carried_fixture unknown-ported $'Beta row\tnot yet ported\nGamma row\tnot yet ported\n' $'/// row: Alpha row\n/// row: Delta row\n')"
run_carried_fixture "$UNKNOWN_PORTED_FIXTURE"
check "a port under a title the list lacks: exit 1, named as unknown" "$FIXTURE_EXIT:$(printf '%s\n' "$FIXTURE_OUTPUT" | rg -c -x 'CARRIED-ROW fail unknown-ported: Delta row')" "1:1"
NOT_A_DOC_COMMENT_FIXTURE="$(write_carried_fixture not-a-doc-comment $'Beta row\tnot yet ported\nGamma row\tnot yet ported\n' $'/// row: Alpha row\nlet note = 1; /// row: Beta row\n')"
run_carried_fixture "$NOT_A_DOC_COMMENT_FIXTURE"
check "a marker inside a line is not a port: exit 0, Beta still exempt only" "$FIXTURE_EXIT:$(printf '%s\n' "$FIXTURE_OUTPUT" | rg -c -x 'CARRIED-ROW pass exempt: Beta row')" "0:1"
run_carried_fixture "$BASELINE_FIXTURE" "$WORK_DIR/no-such-list.txt"
check "a list that cannot be read: exit 2, no pass line" "$FIXTURE_EXIT:$(printf '%s\n' "$FIXTURE_OUTPUT" | rg '^CARRIED-ROW ' | wc -l | tr -d ' ')" "2:0"

EMPTY_FIXTURE="$(write_carried_fixture empty $'' $'')"
printf '# only a heading\n' >"$EMPTY_FIXTURE/tests/carried-rows.txt"
run_carried_fixture "$EMPTY_FIXTURE"
check "a list with no titles: exit 2, no pass line" "$FIXTURE_EXIT:$(printf '%s\n' "$FIXTURE_OUTPUT" | rg '^CARRIED-ROW ' | wc -l | tr -d ' ')" "2:0"
"$CARRIED_ROWS_CHECK" --no-such-flag >/dev/null 2>&1
check "an unknown flag: exit 2" "$?" 2

printf '\nthe program on a private bus (gnome-shell/tests/run-sampler-program.js)\n'
# The bus is this run's own: a path socket in a 0700 directory, and no service directory, so nothing on it can be
# activated. The runner refuses to start unless DBUS_SESSION_BUS_ADDRESS is that socket, and it all runs behind
# BUS_BARRIER, so even a program that ignored the address would find no live bus to fall back to.
PRIVATE_BUS_DIR="$WORK_DIR/private-bus"
PRIVATE_BUS_CONFIG="$WORK_DIR/private-bus.conf"
if ! mkdir -p "$PRIVATE_BUS_DIR" || ! chmod 700 "$PRIVATE_BUS_DIR"; then
  fatal "cannot create the private bus directory $PRIVATE_BUS_DIR"
fi
cat >"$PRIVATE_BUS_CONFIG" <<BUS_CONFIG || fatal "cannot write $PRIVATE_BUS_CONFIG"
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:dir=$PRIVATE_BUS_DIR</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
    <!-- A stock bus drops a reply nobody asked for (dbus-daemon(1), requested_reply), so a reply to a call flagged
         "no reply expected" could not be seen there; this one passes it, for bus_link.rs's no-reply test. -->
    <allow send_type="method_return" send_requested_reply="false"/>
    <allow send_type="error" send_requested_reply="false"/>
    <allow receive_type="method_return" receive_requested_reply="false"/>
    <allow receive_type="error" receive_requested_reply="false"/>
  </policy>
</busconfig>
BUS_CONFIG
# on_private_bus <command...> runs a command on its own private bus, behind the barrier. GIO_USE_VFS=local keeps GIO
# from asking that bus for gvfs. It runs in a session of its own (setsid), and timeout signals its whole process
# group, so a time-out ends the private dbus-daemon and every copy of the program with it.
on_private_bus() {
  env "${BUS_BARRIER[@]}" RESOURCE_PULSE_TEST_BUS_DIR="$PRIVATE_BUS_DIR" GIO_USE_VFS=local \
    setsid --wait timeout --kill-after="$PRIVATE_BUS_KILL_AFTER_SECONDS" "$PRIVATE_BUS_TIMEOUT_SECONDS" \
    dbus-run-session --config-file="$PRIVATE_BUS_CONFIG" -- "$@"
}
# The runner's own guards first. Outside its private bus (the barrier's dead socket, outside the bus directory) it
# must refuse before a row runs; on the bus but with no program, it must refuse too.
RUNNER_GUARD_OUTPUT="$(off_bus RESOURCE_PULSE_TEST_BUS_DIR="$PRIVATE_BUS_DIR" \
  timeout "$PRIVATE_BUS_TIMEOUT_SECONDS" gjs -m "$PRIVATE_BUS_RUNNER" "$PROGRAM_PATH" 2>&1)"
check "the runner refuses a bus outside its private directory: exit 2, no row run" \
  "$?/$(rg -c -F 'refusing to run' <<<"$RUNNER_GUARD_OUTPUT")/$(rg -c '^JS-TALLY' <<<"$RUNNER_GUARD_OUTPUT")" "2/1/"
RUNNER_GUARD_OUTPUT="$(on_private_bus gjs -m "$PRIVATE_BUS_RUNNER" 2>&1)"
check "the runner refuses to start with no program to run: exit 2, no row run" \
  "$?/$(rg -c -F 'no executable sampler program' <<<"$RUNNER_GUARD_OUTPUT")/$(rg -c '^JS-TALLY' <<<"$RUNNER_GUARD_OUTPUT")" \
  "2/1/"
# The bus link's rules, deterministically (resource-pulse-sampler/tests/bus_link.rs). Its tests are #[ignore]d, so the
# cargo test step above lists them as ignored and runs nothing on any bus; here they run with --ignored. They are taken
# from the binary's own list, so a test added to the file cannot be left out.
BUS_LINK_TEST_COMMAND=(cargo test --locked --manifest-path "$MANIFEST_PATH" --test bus_link -- --ignored)
mapfile -t BUS_LINK_TEST_NAMES < <(off_bus "${BUS_LINK_TEST_COMMAND[@]}" --list 2>/dev/null | sed -n 's/: test$//p')
BUS_LINK_TEST_COUNT=${#BUS_LINK_TEST_NAMES[@]}
(( BUS_LINK_TEST_COUNT > 0 )) || bad "cargo test --test bus_link listed no tests: they did not run"
# Off the private bus every one must refuse before it connects: under BUS_BARRIER, whose address is outside the
# private bus directory, each fails with the guard's own message, and none passes.
BUS_LINK_GUARD_OUTPUT="$(off_bus RESOURCE_PULSE_TEST_BUS_DIR="$PRIVATE_BUS_DIR" "${BUS_LINK_TEST_COMMAND[@]}" 2>&1)"
BUS_LINK_GUARD_EXIT=$?
BUS_LINK_GUARD_RESULT_PATTERN="^test result: FAILED\\. 0 passed; $BUS_LINK_TEST_COUNT failed;"
check "off the private bus every bus_link test refuses: a failing exit, one refusal each, none passed" \
  "$BUS_LINK_GUARD_EXIT/$(rg -c '^refusing to run: ' <<<"$BUS_LINK_GUARD_OUTPUT")/$(rg -c "$BUS_LINK_GUARD_RESULT_PATTERN" <<<"$BUS_LINK_GUARD_OUTPUT")" \
  "$LIBTEST_FAILED_EXIT_CODE/$BUS_LINK_TEST_COUNT/1"
# On the private bus each test runs in a process and on a bus of its own: a link's connection lives as long as its
# receiving thread, so in one process a link one test leaves behind could make another fail for its reason and not
# its own.
for bus_link_test_name in "${BUS_LINK_TEST_NAMES[@]}"; do
  BUS_LINK_OUTPUT="$(on_private_bus "${BUS_LINK_TEST_COMMAND[@]}" --exact "$bus_link_test_name" 2>&1)"
  count_cargo_test_rows "cargo test --test bus_link $bus_link_test_name" "$BUS_LINK_OUTPUT" "$?"
done

PROGRAM_BUS_OUTPUT="$(on_private_bus gjs -m "$PRIVATE_BUS_RUNNER" "$PROGRAM_PATH" 2>&1)"
PROGRAM_BUS_EXIT=$?
printf '%s\n' "$PROGRAM_BUS_OUTPUT"
PROGRAM_BUS_TALLY_LINE=""
while IFS= read -r program_bus_line; do
  if [[ "$program_bus_line" =~ $TALLY_PATTERN ]]; then
    PROGRAM_BUS_TALLY_LINE="$program_bus_line"
    PROGRAM_BUS_PASS="${BASH_REMATCH[1]}"
    PROGRAM_BUS_FAIL="${BASH_REMATCH[2]}"
  fi
done <<<"$PROGRAM_BUS_OUTPUT"
[[ -n "$PROGRAM_BUS_TALLY_LINE" ]] \
  || fatal "no JS-TALLY line from the program's bus rows (exit $PROGRAM_BUS_EXIT): they did not run"
PASS=$((PASS + PROGRAM_BUS_PASS))
FAIL=$((FAIL + PROGRAM_BUS_FAIL))
if (( PROGRAM_BUS_EXIT != 0 && PROGRAM_BUS_FAIL == 0 )); then
  bad "the program's bus runner exited $PROGRAM_BUS_EXIT with no failing row"
fi

# 25 cargo unit tests (2 of the constants, 23 of the parsers) + 1 build + 1 zbus feature row + 6 program flag rows
# + 26 constants + 1 comparison tally + 5 comparison-fails rows + 179 carried titles + 3 carried-list checks
# + 10 carried-check fixtures + 2 runner guards + 1 bus_link guard + 8 bus_link tests
# + 11 rows of the program on a private bus.
EXPECTED_ROWS=279

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( PASS + FAIL != EXPECTED_ROWS )); then
  printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
    "$EXPECTED_ROWS" "$((PASS + FAIL))"
  FAIL=$((FAIL + 1))
fi
(( FAIL == 0 ))
