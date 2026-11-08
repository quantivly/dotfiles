#!/usr/bin/env bash
#
# scripts/test-resource-pulse.sh
# ==============================
#
# State table for the Resource Pulse GNOME Shell extension
# (gnome-shell/extensions/resource-pulse@dotfiles). The rows live in plain-gjs
# test files under gnome-shell/tests/, imported by a static list in run.js;
# this wrapper runs them, echoes their output and folds the ONE anchored
# `JS-TALLY pass=<n> fail=<n>` line into its own PASS/FAIL.
#
# Its own rows, after the tally, cover what plain gjs cannot run: the Shell
# glue (extension.js, indicator.js, card.js) must parse and get as far as its
# first `resource:///org/gnome/shell` import, the pure modules must import no
# Shell module, nothing may block the shell's main loop, and metadata.json must
# say what GNOME 50 needs. Those rows read the files, and a missing file makes
# them FAIL, never pass.
#
# "Could not run" is exit 2, never a pass: a missing gjs, find or timeout, or a
# missing tally line (an import error prints none) is fatal. The suite asserts
# its own row total.
#
# Requires: bash, gjs, find, timeout. No network, no root.
#
# Usage: scripts/test-resource-pulse.sh
#   RESOURCE_PULSE_EXT_DIR=<dir> points the file rows at a copy of the
#   extension (for a mutation trial); the JS rows always test the tree.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DOTFILES="$(cd "$HERE/.." && pwd -P)"
RUNNER="$DOTFILES/gnome-shell/tests/run.js"
TALLY_PATTERN='^JS-TALLY pass=([0-9]+) fail=([0-9]+)$'
EXT_DIR="${RESOURCE_PULSE_EXT_DIR:-$DOTFILES/gnome-shell/extensions/resource-pulse@dotfiles}"

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

[[ -r "$RUNNER" ]] || fatal "cannot read $RUNNER"
[[ -d "$EXT_DIR" ]] || fatal "no extension directory at $EXT_DIR"
for required_tool in gjs find timeout; do
  command -v "$required_tool" >/dev/null || fatal "$required_tool is required"
done

JS_OUTPUT="$(gjs -m "$RUNNER" 2>&1)"
JS_EXIT=$?
printf '%s\n' "$JS_OUTPUT"

# The tally is read from ONE anchored line, never by counting marks: a row
# name may contain one.
TALLY_LINE=""
while IFS= read -r line; do
  if [[ "$line" =~ $TALLY_PATTERN ]]; then
    TALLY_LINE="$line"
    JS_PASS="${BASH_REMATCH[1]}"
    JS_FAIL="${BASH_REMATCH[2]}"
  fi
done <<<"$JS_OUTPUT"
[[ -n "$TALLY_LINE" ]] || fatal "no JS-TALLY line in the gjs output (exit $JS_EXIT): the tests did not run"

PASS=$((PASS + JS_PASS))
FAIL=$((FAIL + JS_FAIL))
# A non-zero gjs exit with a clean tally means the runner itself broke.
if (( JS_EXIT != 0 && JS_FAIL == 0 )); then
  printf '  \033[1;31m✗\033[0m gjs exited %d with no failing row\n' "$JS_EXIT"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# The Shell glue and the packaging: what plain gjs cannot run
# ---------------------------------------------------------------------------
printf '\nShell glue and packaging (%s)\n' "$EXT_DIR"

# The Shell modules do not exist outside gnome-shell, so plain gjs stops at the
# first one. Getting there proves the file parsed; both shapes were measured
# on gjs 1.88: a Shell import fails with "ImportError: Unable to load file
# from: resource:///…", a parse error says "SyntaxError" and never gets there.
SHELL_IMPORT_NEEDLE='resource:///org/gnome/shell'
SYNTAX_ERROR_NEEDLE='SyntaxError'
GLUE_PARSE_TIMEOUT_SECONDS=20
for glue_file in extension.js indicator.js card.js; do
  glue_path="$EXT_DIR/$glue_file"
  row_name="$glue_file parses and gets as far as its Shell imports"
  if [[ ! -r "$glue_path" ]]; then
    bad "$row_name — cannot read $glue_path"
    continue
  fi
  parse_output="$(timeout "$GLUE_PARSE_TIMEOUT_SECONDS" gjs -m "$glue_path" 2>&1)"
  if [[ "$parse_output" == *"$SYNTAX_ERROR_NEEDLE"* ]]; then
    bad "$row_name — gjs reported a SyntaxError: $parse_output"
  elif [[ "$parse_output" != *"$SHELL_IMPORT_NEEDLE"* ]]; then
    bad "$row_name — gjs never reached a $SHELL_IMPORT_NEEDLE import: $parse_output"
  else
    ok "$row_name"
  fi
done

# lib/, sampler.js and graph.js run under plain gjs in the JS rows above, which
# only works while they import nothing from the Shell. A listed file that is
# missing fails the row: an absent file contains nothing, which is not a pass.
PURE_MODULE_PATHS=("$EXT_DIR/sampler.js" "$EXT_DIR/graph.js")
mapfile -d '' LIB_MODULE_PATHS < <(find "$EXT_DIR/lib" -type f -name '*.js' -print0 2>/dev/null)
row_name="lib/, sampler.js and graph.js import nothing from resource:///"
if (( ${#LIB_MODULE_PATHS[@]} == 0 )); then
  bad "$row_name — found no lib/*.js under $EXT_DIR"
else
  pure_module_problems=()
  for module_path in "${PURE_MODULE_PATHS[@]}" "${LIB_MODULE_PATHS[@]}"; do
    if [[ ! -r "$module_path" ]]; then
      pure_module_problems+=("cannot read ${module_path#"$EXT_DIR"/}")
    elif [[ "$(<"$module_path")" == *'resource:///'* ]]; then
      pure_module_problems+=("${module_path#"$EXT_DIR"/} mentions resource:///")
    fi
  done
  if (( ${#pure_module_problems[@]} == 0 )); then
    ok "$row_name"
  else
    bad "$row_name — ${pure_module_problems[*]}"
  fi
fi

# The extension runs on the compositor's main loop: no subprocess and no
# synchronous file read, anywhere in it.
BLOCKING_CALL_PATTERN='Gio.Subprocess|GLib.spawn|Util.spawn|load_contents\(|file_get_contents'
mapfile -d '' EXTENSION_FILE_PATHS < <(find "$EXT_DIR" -type f -print0 2>/dev/null)
row_name="no file in the extension spawns a process or reads a file synchronously"
if (( ${#EXTENSION_FILE_PATHS[@]} == 0 )); then
  bad "$row_name — found no files under $EXT_DIR"
else
  blocking_calls=()
  for extension_file_path in "${EXTENSION_FILE_PATHS[@]}"; do
    if [[ "$(<"$extension_file_path")" =~ $BLOCKING_CALL_PATTERN ]]; then
      blocking_calls+=("${extension_file_path#"$EXT_DIR"/}: ${BASH_REMATCH[0]}")
    fi
  done
  if (( ${#blocking_calls[@]} == 0 )); then
    ok "$row_name"
  else
    bad "$row_name — ${blocking_calls[*]}"
  fi
fi

# metadata.json, parsed as JSON by gjs (never grepped). Each field is printed
# on its own prefixed line, so an unreadable or malformed file prints none and
# every row below fails rather than passes.
METADATA_PATH="$EXT_DIR/metadata.json"
# shellcheck disable=SC2016  # JavaScript source: $ and backticks are gjs's, not bash's.
READ_METADATA_JS='
const [metadataPath] = ARGV;
const [, metadataBytes] = imports.gi.GLib.file_get_contents(metadataPath);
const metadata = JSON.parse(new TextDecoder().decode(metadataBytes));
print(`uuid=${metadata.uuid}`);
print(`shell-version=${JSON.stringify(metadata["shell-version"])}`);
print(`session-modes=${Object.hasOwn(metadata, "session-modes") ? "present" : "absent"}`);
'
metadata_output="$(timeout "$GLUE_PARSE_TIMEOUT_SECONDS" gjs -c "$READ_METADATA_JS" "$METADATA_PATH" 2>&1)"
metadata_uuid=""; metadata_shell_version=""; metadata_session_modes=""
while IFS= read -r metadata_line; do
  case "$metadata_line" in
    uuid=*)          metadata_uuid="${metadata_line#uuid=}" ;;
    shell-version=*) metadata_shell_version="${metadata_line#shell-version=}" ;;
    session-modes=*) metadata_session_modes="${metadata_line#session-modes=}" ;;
  esac
done <<<"$metadata_output"
[[ -n "$metadata_uuid" ]] || printf '    (gjs read of %s said: %s)\n' "$METADATA_PATH" "$metadata_output"
check "metadata.json: uuid equals the directory name" "$metadata_uuid" "$(basename "$EXT_DIR")"
check 'metadata.json: shell-version is exactly ["50"]' "$metadata_shell_version" '["50"]'
check "metadata.json: no session-modes key, so the lock screen disables it" "$metadata_session_modes" "absent"

# ---------------------------------------------------------------------------
# Repo wiring: the opt-in helper, the link, the template and the cost script.
# Every genable_extension row runs apply-gnome-settings.sh against a STATEFUL
# gsettings stub on PATH (values under $WIRING_TMP/gsettings/<schema>/<key>), so
# nothing here can reach the real session's dconf database.
# ---------------------------------------------------------------------------
APPLY_SCRIPT="$DOTFILES/scripts/apply-gnome-settings.sh"
COST_SCRIPT="$DOTFILES/scripts/resource-pulse-cost.sh"
EXTENSION_UUID="resource-pulse@dotfiles"
SHELL_SCHEMA="org.gnome.shell"
WIRING_TMP="$(mktemp -d)" || fatal "mktemp -d failed"
trap 'rm -rf "$WIRING_TMP"' EXIT
STUB_BIN="$WIRING_TMP/bin"
STUB_STATE="$WIRING_TMP/gsettings"
mkdir -p "$STUB_BIN" "$STUB_STATE" || fatal "cannot create the gsettings stub directory"
cat >"$STUB_BIN/gsettings" <<'STUB'
#!/usr/bin/env bash
# Stateful gsettings stand-in: get/set/list-schemas over files under $STUB_STATE.
# Every call is logged to $STUB_CALLS, so a row can prove the stub was the one used.
printf '%s\n' "$*" >>"$STUB_CALLS"
case "$1" in
  list-schemas) cat "$STUB_STATE/schemas" 2>/dev/null ;;
  get)
    if [[ -f "$STUB_STATE/$2/$3" ]]; then cat "$STUB_STATE/$2/$3"
    else
      case "$3" in
        *-extensions)            echo '@as []' ;;
        disable-user-extensions) echo 'false' ;;
        *)                       echo "''" ;;
      esac
    fi ;;
  set) mkdir -p "$STUB_STATE/$2" && printf '%s\n' "$4" >"$STUB_STATE/$2/$3" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/gsettings"
printf 'genable_extension %s\n' "$EXTENSION_UUID" >"$WIRING_TMP/local-overrides"

STUB_CALLS_LOG="$WIRING_TMP/stub-calls"

# Reset the stub to a state, run the apply script, leave its stderr+stdout in
# APPLY_OUTPUT and its exit status in APPLY_EXIT.
#   $1 enabled-extensions  $2 disabled-extensions  $3 disable-user-extensions
#   $4 schemas listed by the stub (newline separated)
run_apply_against_stub() {
  rm -rf "${STUB_STATE:?}"/*
  mkdir -p "$STUB_STATE/$SHELL_SCHEMA"
  printf '%s\n' "$1" >"$STUB_STATE/$SHELL_SCHEMA/enabled-extensions"
  printf '%s\n' "$2" >"$STUB_STATE/$SHELL_SCHEMA/disabled-extensions"
  printf '%s\n' "$3" >"$STUB_STATE/$SHELL_SCHEMA/disable-user-extensions"
  printf '%s' "$4" >"$STUB_STATE/schemas"
  : >"$STUB_CALLS_LOG"
  APPLY_OUTPUT="$(PATH="$STUB_BIN:$PATH" STUB_STATE="$STUB_STATE" STUB_CALLS="$STUB_CALLS_LOG" XDG_CURRENT_DESKTOP=GNOME \
    GNOME_LOCAL_OVERRIDES="$WIRING_TMP/local-overrides" bash "$APPLY_SCRIPT" 2>&1)"
  APPLY_EXIT=$?
}
stub_value() { cat "$STUB_STATE/$SHELL_SCHEMA/$1" 2>/dev/null; }

printf '\ngenable_extension (stateful gsettings stub)\n'
run_apply_against_stub '@as []' '@as []' false "$SHELL_SCHEMA"
check "genable_extension: an empty list becomes just the uuid" "$(stub_value enabled-extensions)" "['$EXTENSION_UUID']"
run_apply_against_stub "['ding@rastersoft.com']" '@as []' false "$SHELL_SCHEMA"
check "genable_extension: appends and keeps the existing entry first" "$(stub_value enabled-extensions)" "['ding@rastersoft.com', '$EXTENSION_UUID']"
run_apply_against_stub "['ding@rastersoft.com', '$EXTENSION_UUID']" '@as []' false "$SHELL_SCHEMA"
check "genable_extension: an already-present uuid leaves the list unchanged" "$(stub_value enabled-extensions)" "['ding@rastersoft.com', '$EXTENSION_UUID']"
check "genable_extension: no change prints no enabled-extensions line" "$(grep -c -F 'enabled-extensions →' <<<"$APPLY_OUTPUT")" 0
run_apply_against_stub '@as []' "['$EXTENSION_UUID', 'x@y']" false "$SHELL_SCHEMA"
check "genable_extension: removes the uuid from disabled-extensions, which wins in GNOME 50" "$(stub_value disabled-extensions)" "['x@y']"
run_apply_against_stub '@as []' '@as []' true "$SHELL_SCHEMA"
check "genable_extension: disable-user-extensions=true warns by name" "$(grep -c -F 'disable-user-extensions' <<<"$APPLY_OUTPUT")" 1
run_apply_against_stub '@as []' '@as []' false ""
check "genable_extension: an absent org.gnome.shell schema warns" "$(grep -c -F "Schema '$SHELL_SCHEMA' not found" <<<"$APPLY_OUTPUT")" 1
check "genable_extension: an absent schema writes nothing" "$(stub_value enabled-extensions)" "@as []"
check "genable_extension: the apply script still exits 0 without the schema" "$APPLY_EXIT" 0

printf '\nlink and template\n'
check "install.conf.yaml links the extension directory" \
  "$(grep -c -x -F "    ~/.local/share/gnome-shell/extensions/$EXTENSION_UUID: gnome-shell/extensions/$EXTENSION_UUID" "$DOTFILES/install.conf.yaml")" 1
check "the template carries a commented genable_extension line" \
  "$(grep -c -x -F "# genable_extension $EXTENSION_UUID" "$DOTFILES/examples/gnome-settings.local.template")" 1

printf '\nresource-pulse-cost.sh (fake PROC_ROOT)\n'
# make_fake_proc <root> <pid> <comm> <vmrss_kib> builds one process entry.
make_fake_proc() {
  mkdir -p "$1/$2"
  printf '%s\n' "$3" >"$1/$2/comm"
  printf 'Name:\t%s\nVmRSS:\t%s kB\n' "$3" "$4" >"$1/$2/status"
  printf '%s (%s) S 1 1 1 0 -1 0 0 0 0 0 100 50 0 0 20 0 1 0 1 0 0\n' "$2" "$3" >"$1/$2/stat"
}
ONE_SHELL_ROOT="$WIRING_TMP/proc-one"
TWO_SHELLS_ROOT="$WIRING_TMP/proc-two"
NO_SHELL_ROOT="$WIRING_TMP/proc-none"
FAKE_SHELL_RSS_KIB=400000
make_fake_proc "$ONE_SHELL_ROOT" 4242 gnome-shell "$FAKE_SHELL_RSS_KIB"
make_fake_proc "$ONE_SHELL_ROOT" 4300 bash 1000
make_fake_proc "$TWO_SHELLS_ROOT" 4242 gnome-shell "$FAKE_SHELL_RSS_KIB"
make_fake_proc "$TWO_SHELLS_ROOT" 4243 gnome-shell "$FAKE_SHELL_RSS_KIB"
make_fake_proc "$NO_SHELL_ROOT" 4300 bash 1000
cost_run() { # <proc root> <args...>; leaves COST_OUTPUT and COST_EXIT
  local proc_root="$1"; shift
  COST_OUTPUT="$(env -u GNOME_SHELL_PID PROC_ROOT="$proc_root" bash "$COST_SCRIPT" "$@" 2>&1)"
  COST_EXIT=$?
}
cost_run "$ONE_SHELL_ROOT" --rss-kib
check "cost: --rss-kib prints the VmRSS of the one gnome-shell" "$COST_OUTPUT" "$FAKE_SHELL_RSS_KIB"
cost_run "$ONE_SHELL_ROOT" --rss-check 380000
check "cost: growth inside the tolerance exits 0" "$COST_EXIT" 0
cost_run "$ONE_SHELL_ROOT" --rss-check 300000
check "cost: growth beyond the tolerance exits 1" "$COST_EXIT" 1
check "cost: a failed check prints both the baseline and the current number" \
  "$(grep -c -F '300000' <<<"$COST_OUTPUT")$(grep -c -F "$FAKE_SHELL_RSS_KIB" <<<"$COST_OUTPUT")" 11
cost_run "$TWO_SHELLS_ROOT" --rss-kib
check "cost: two gnome-shell candidates exit 2" "$COST_EXIT" 2
cost_run "$NO_SHELL_ROOT" --rss-kib
check "cost: no gnome-shell candidate exits 2" "$COST_EXIT" 2
# Spelled by pieces so this row's own source is not what it finds in the script.
FORBIDDEN_READS_PATTERN="cmd""line|env""iron\\b|pgre""p|\\bps -"
check "cost: the script never reads an argument list or environment, or runs ps" \
  "$(grep -c -E "$FORBIDDEN_READS_PATTERN" "$COST_SCRIPT" 2>/dev/null)" 0

printf '\nresource-pulse-nested.sh (hermetic: no gnome-shell, nothing is started)\n'
# The nested-shell harness itself needs gnome-shell and a GPU, so it never runs
# here. These rows cover what it decides before anything starts: its usage,
# the bus configs it renders, the environment allowlist, and its refusals. Every
# run of it here has busctl, gsettings and gnome-shell replaced by stubs that
# only record the call, and RESOURCE_PULSE_NESTED_BASE pointed at an empty
# directory, so a row that must refuse proves it reached none of them.
#
# That directory's name is deliberately longer than the script allows a run
# directory to be (48 characters, for its sockets). `start` launches through
# `env -i` with its own PATH, where these stubs do not reach, so a mutant that
# fell through to `start` could otherwise launch a real nested shell from this
# suite; with this base it refuses at the length check before launching.
NESTED_SCRIPT="$DOTFILES/scripts/resource-pulse-nested.sh"
NESTED_FILES="$DOTFILES/gnome-shell/tests/nested"
NESTED_BASE="$WIRING_TMP/nested-base-named-longer-than-any-run-directory-may-be"
NESTED_STUB_BIN="$WIRING_TMP/nested-bin"
NESTED_STUB_CALLS="$WIRING_TMP/nested-stub-calls"
UNSAFE_MODE_HELPER_UUID="resource-pulse-nested-unsafe-mode@local"
mkdir -p "$NESTED_BASE" "$NESTED_STUB_BIN" || fatal "cannot create the nested-harness fixture directories"
# A base directory must be private to the user, as `start` requires of one.
chmod 700 "$NESTED_BASE" || fatal "cannot make the nested-harness base private"
for stubbed_tool in busctl gsettings gnome-shell; do
  # shellcheck disable=SC2016  # The stub's own source: its $* and $NESTED_STUB_CALLS expand when it runs.
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >>"$NESTED_STUB_CALLS"\nexit 1\n' "$stubbed_tool" \
    >"$NESTED_STUB_BIN/$stubbed_tool"
  chmod +x "$NESTED_STUB_BIN/$stubbed_tool"
done
nested_stub_call_count() { printf '%d' "$(wc -l <"$NESTED_STUB_CALLS")"; }
# nested_run <args...> runs the script against the stubs and the empty base;
# leaves NESTED_OUTPUT and NESTED_EXIT.
nested_run() {
  : >"$NESTED_STUB_CALLS"
  NESTED_OUTPUT="$(env -u RESOURCE_PULSE_NESTED_DIR PATH="$NESTED_STUB_BIN:$PATH" \
    NESTED_STUB_CALLS="$NESTED_STUB_CALLS" RESOURCE_PULSE_NESTED_BASE="$NESTED_BASE" \
    bash "$NESTED_SCRIPT" "$@" 2>&1)"
  NESTED_EXIT=$?
}
# nested_call <function> <args...> sources the script (which then runs nothing)
# and calls one of its functions. A missing script exits 99, never 0.
nested_call() {
  bash -c 'source "$1" || exit 99; shift; "$@"' nested-call "$NESTED_SCRIPT" "$@"
}

check "nested: the script parses (bash -n)" "$(bash -n "$NESTED_SCRIPT" 2>&1; printf 'rc=%d' $?)" "rc=0"

nested_run
no_subcommand_exit=$NESTED_EXIT
nested_run launch
check "nested: no subcommand and an unknown one both exit 2, say why, and create nothing" \
  "$no_subcommand_exit:$NESTED_EXIT:$(grep -c -F "unknown subcommand: 'launch'" <<<"$NESTED_OUTPUT"):$(find "$NESTED_BASE" -mindepth 1 | wc -l)" \
  "2:2:1:0"

nested_run eval '1 + 1'
check "nested: eval with no run refuses (exit 2) and never calls busctl" \
  "$NESTED_EXIT:$(nested_stub_call_count):$(grep -c -F 'no live run' <<<"$NESTED_OUTPUT")" "2:0:1"

# A run directory whose recorded address is the LIVE session bus: the address
# check, not the run lookup, must be what refuses it.
TAMPERED_SUFFIX="Tamper01"
TAMPERED_RUN="$NESTED_BASE/rpn.$TAMPERED_SUFFIX"
mkdir -p "$TAMPERED_RUN/state" && chmod 700 "$TAMPERED_RUN"
printf '%s\n' "$TAMPERED_SUFFIX" >"$TAMPERED_RUN/.resource-pulse-nested"
printf '%s\n' "unix:path=/run/user/$(id -u)/bus" >"$TAMPERED_RUN/state/session.addr"
nested_run eval '1 + 1'
check "nested: a run whose recorded address is not its private bus is refused before busctl" \
  "$NESTED_EXIT:$(nested_stub_call_count):$(grep -c -F "not this run's private session bus" <<<"$NESTED_OUTPUT")" "2:0:1"
rm -rf "$TAMPERED_RUN"

# A run whose recorded address IS its private bus, but which is not live: eval
# and screenshot must refuse unless the supervisor runs and the recorded
# gnome-shell runs in the run's own session under that name. Each case below
# defeats one requirement; the last meets them all and so reaches busctl (the
# stub), which proves the fixture is otherwise good.
STALE_SUFFIX="Stale001"
STALE_RUN="$NESTED_BASE/rpn.$STALE_SUFFIX"
mkdir -p "$STALE_RUN/state" && chmod 700 "$STALE_RUN"
printf '%s\n' "$STALE_SUFFIX" >"$STALE_RUN/.resource-pulse-nested"
printf '%s\n' "unix:path=$STALE_RUN/bus/session.sock,guid=0123456789abcdef" >"$STALE_RUN/state/session.addr"
# A pid above the kernel's largest (2^22) is never running.
NEVER_RUNNING_PID=4194305
# A process whose comm is gnome-shell: the kernel names a #! script's process after the script file.
FAKE_SHELL_DIR="$WIRING_TMP/fake-shell"
mkdir -p "$FAKE_SHELL_DIR" && mkfifo "$FAKE_SHELL_DIR/block"
# shellcheck disable=SC2016  # The fake shell's own source: its $1 expands when it runs.
printf '#!/bin/bash\n# Stands in for a running gnome-shell; blocks until signalled.\nread -r _ <>"$1"\n' \
  >"$FAKE_SHELL_DIR/gnome-shell"
chmod +x "$FAKE_SHELL_DIR/gnome-shell"
"$FAKE_SHELL_DIR/gnome-shell" "$FAKE_SHELL_DIR/block" &
fake_shell_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ "$(cat "/proc/$fake_shell_pid/comm" 2>/dev/null)" == gnome-shell ]] && break
  sleep 0.2
done
test_session_id="$(nested_call session_id_of_process /proc "$$")"
# eval_stale_run <supervisor> <session> <gnome-shell pid> prints refused or reached-busctl.
eval_stale_run() {
  printf 'supervisor=%s\nsession=%s\ngnome-shell=%s\n' "$1" "$2" "$3" >"$STALE_RUN/state/run.values"
  nested_run eval '1 + 1'
  if [[ $NESTED_EXIT == 2 && $(nested_stub_call_count) == 0 ]]; then printf refused
  elif (( $(nested_stub_call_count) > 0 )); then printf reached-busctl
  else printf 'exit-%s' "$NESTED_EXIT"; fi
}
stale_summary="supervisor-gone=$(eval_stale_run "$NEVER_RUNNING_PID" "$test_session_id" "$fake_shell_pid")"
stale_summary+=" other-session=$(eval_stale_run "$$" "$NEVER_RUNNING_PID" "$fake_shell_pid")"
stale_summary+=" not-gnome-shell=$(eval_stale_run "$$" "$test_session_id" "$$")"
stale_summary+=" live=$(eval_stale_run "$$" "$test_session_id" "$fake_shell_pid")"
kill "$fake_shell_pid" 2>/dev/null
wait "$fake_shell_pid" 2>/dev/null
check "nested: eval refuses a run that is not live: supervisor gone, shell in another session, or not gnome-shell" \
  "$stale_summary" "supervisor-gone=refused other-session=refused not-gnome-shell=refused live=reached-busctl"
rm -rf "$STALE_RUN"

# A base directory others can read would make run directories discoverable.
PUBLIC_BASE="$WIRING_TMP/public-base-named-longer-than-any-run-directory-may-be"
mkdir -p "$PUBLIC_BASE" && chmod 755 "$PUBLIC_BASE"
: >"$NESTED_STUB_CALLS"
public_base_output="$(env -u RESOURCE_PULSE_NESTED_DIR PATH="$NESTED_STUB_BIN:$PATH" \
  NESTED_STUB_CALLS="$NESTED_STUB_CALLS" RESOURCE_PULSE_NESTED_BASE="$PUBLIC_BASE" \
  bash "$NESTED_SCRIPT" start 2>&1)"
public_base_exit=$?
check "nested: start refuses a base directory others can read, before making anything" \
  "$public_base_exit:$(grep -c -F 'is not private' <<<"$public_base_output"):$(find "$PUBLIC_BASE" -mindepth 1 | wc -l):$(nested_stub_call_count)" \
  "2:1:0:0"

nested_run screenshot ../escape.png
check "nested: a screenshot name with a / in it is refused before anything runs" \
  "$NESTED_EXIT:$(nested_stub_call_count):$(grep -c -F 'a screenshot name is a plain file name' <<<"$NESTED_OUTPUT")" "2:0:1"

# One run directory, prepared exactly as `start` prepares it but never started.
PREPARED_SUFFIX="Prep0001"
PREPARED_RUN="$WIRING_TMP/prepared/rpn.$PREPARED_SUFFIX"
mkdir -p "$PREPARED_RUN" && chmod 700 "$PREPARED_RUN"
nested_call prepare_run_directory "$PREPARED_RUN" "$PREPARED_SUFFIX"
prepare_exit=$?
SESSION_BUS_CONF="$PREPARED_RUN/bus/session-bus.conf"
SESSION_SERVICES_DIR="$PREPARED_RUN/bus/session-services"
session_bus_summary="prepare=$prepare_exit"
session_bus_summary+=" servicedirs=$(grep -c -F '<servicedir>' "$SESSION_BUS_CONF" 2>/dev/null)"
session_bus_summary+=" ours=$(grep -c -F "<servicedir>$SESSION_SERVICES_DIR</servicedir>" "$SESSION_BUS_CONF" 2>/dev/null)"
session_bus_summary+=" standard=$(grep -c -E 'standard_(session|system)_servicedirs|<include' "$SESSION_BUS_CONF" 2>/dev/null)"
session_bus_summary+=" services=$(find "$SESSION_SERVICES_DIR" -mindepth 1 -printf '%f,' 2>/dev/null)"
session_bus_summary+=" dconf=$(grep -c -x -F 'Name=ca.desrt.dconf' "$SESSION_SERVICES_DIR/ca.desrt.dconf.service" 2>/dev/null)"
check "nested: the private session bus can activate dconf and nothing else" "$session_bus_summary" \
  "prepare=0 servicedirs=1 ours=1 standard=0 services=ca.desrt.dconf.service, dconf=1"

WIDENED_SESSION_BUS_CONF="$WIRING_TMP/widened-session-bus.conf"
{ grep -v -F '</busconfig>' "$SESSION_BUS_CONF"; printf '  <standard_session_servicedirs/>\n</busconfig>\n'; } \
  >"$WIDENED_SESSION_BUS_CONF" 2>/dev/null
nested_call session_bus_config_permits_only_dconf "$SESSION_BUS_CONF" "$SESSION_SERVICES_DIR"
accepts_rendered_session_bus=$?
nested_call session_bus_config_permits_only_dconf "$WIDENED_SESSION_BUS_CONF" "$SESSION_SERVICES_DIR"
accepts_widened_session_bus=$?
check "nested: the start-time check accepts that session bus and refuses one with the standard service dirs" \
  "$accepts_rendered_session_bus:$accepts_widened_session_bus" "0:1"

SYSTEM_BUS_CONF="$PREPARED_RUN/bus/system-bus.conf"
WIDENED_SYSTEM_BUS_CONF="$WIRING_TMP/widened-system-bus.conf"
{ grep -v -F '</busconfig>' "$SYSTEM_BUS_CONF"; printf '  <standard_system_servicedirs/>\n</busconfig>\n'; } \
  >"$WIDENED_SYSTEM_BUS_CONF" 2>/dev/null
system_bus_summary="listen=$(grep -c -F "<listen>unix:path=$PREPARED_RUN/bus/system.sock</listen>" "$SYSTEM_BUS_CONF" 2>/dev/null)"
system_bus_summary+=" activatable=$(grep -c -E '<servicedir|standard_(session|system)_servicedirs|<include|<servicehelper' "$SYSTEM_BUS_CONF" 2>/dev/null)"
nested_call system_bus_config_activates_nothing "$SYSTEM_BUS_CONF"
system_bus_summary+=" check-rendered=$?"
nested_call system_bus_config_activates_nothing "$WIDENED_SYSTEM_BUS_CONF"
system_bus_summary+=" check-widened=$?"
check "nested: the fake system bus can activate nothing, and the start-time check says so" "$system_bus_summary" \
  "listen=1 activatable=0 check-rendered=0 check-widened=1"

# Both buses listen on path sockets inside the 0700 run directory: an abstract
# socket has no file permissions, so any process in the network namespace (a
# confined app included) could connect, or claim the name once the run ends.
socket_summary="session-path=$(grep -c -F "<listen>unix:path=$PREPARED_RUN/bus/session.sock</listen>" "$SESSION_BUS_CONF" 2>/dev/null)"
socket_summary+=" system-path=$(grep -c -F "<listen>unix:path=$PREPARED_RUN/bus/system.sock</listen>" "$SYSTEM_BUS_CONF" 2>/dev/null)"
socket_summary+=" abstract=$(cat "$SESSION_BUS_CONF" "$SYSTEM_BUS_CONF" 2>/dev/null | grep -c -F 'unix:abstract=')"
socket_summary+=" listens=$(cat "$SESSION_BUS_CONF" "$SYSTEM_BUS_CONF" 2>/dev/null | grep -c -F '<listen>')"
socket_summary+=" eavesdrop=$(cat "$SESSION_BUS_CONF" "$SYSTEM_BUS_CONF" 2>/dev/null | grep -c -F 'eavesdrop')"
# Without an allow-receive rule dbus-daemon rejects every reply (measured), so dropping eavesdrop needs this.
socket_summary+=" allow-receive=$(cat "$SESSION_BUS_CONF" "$SYSTEM_BUS_CONF" 2>/dev/null | grep -c -F '<allow receive_sender="*"/>')"
check "nested: both buses listen only on path sockets in the run directory, with no abstract socket or eavesdropping" \
  "$socket_summary" "session-path=1 system-path=1 abstract=0 listens=2 eavesdrop=0 allow-receive=2"

NESTED_ENVIRONMENT="$(nested_call nested_environment_assignments "$PREPARED_RUN")"
NESTED_ENVIRONMENT_NAMES="$(cut -d= -f1 <<<"$NESTED_ENVIRONMENT")"
FORBIDDEN_NESTED_NAMES_PATTERN='^(WAYLAND_DISPLAY|DISPLAY|DBUS_SESSION_BUS_ADDRESS|SSH_AUTH_SOCK)$|TOKEN|SECRET|PASSWORD|API_KEY|CREDENTIAL'
check "nested: the environment allowlist names no display, no live session bus and no credential" \
  "$(grep -c -E "$FORBIDDEN_NESTED_NAMES_PATTERN" <<<"$NESTED_ENVIRONMENT_NAMES"):$(wc -l <<<"$NESTED_ENVIRONMENT_NAMES")" "0:22"

poisoned_child_environment="$(WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 GH_TOKEN=poison-not-a-token \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" \
  nested_call run_isolated "$PREPARED_RUN" env)"
check "nested: a process started isolated inherits none of the live display, bus or token" \
  "$(grep -c -E '^(WAYLAND_DISPLAY|DISPLAY|DBUS_SESSION_BUS_ADDRESS|GH_TOKEN)=' <<<"$poisoned_child_environment"):$(grep -c -x -F "XDG_RUNTIME_DIR=$PREPARED_RUN/run" <<<"$poisoned_child_environment")" "0:1"

dirs_outside_the_run=""
for isolated_variable in HOME TMPDIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR; do
  isolated_value="$(grep -E "^$isolated_variable=" <<<"$NESTED_ENVIRONMENT" | cut -d= -f2-)"
  [[ "$isolated_value" == "$PREPARED_RUN/"* ]] || dirs_outside_the_run+="$isolated_variable='$isolated_value' "
done
check "nested: HOME, TMPDIR and every XDG home and runtime dir are in the run; the system bus is the fake one" \
  "${dirs_outside_the_run:-none}:$(grep -c -x -F "DBUS_SYSTEM_BUS_ADDRESS=unix:path=$PREPARED_RUN/bus/system.sock" <<<"$NESTED_ENVIRONMENT")" "none:1"

# fake_gdm_verdict <run dir or ''> <address> prints refused, or whatever else happened.
FAKE_GDM_REFUSAL='refusing to connect to anything but the fake system bus'
fake_gdm_verdict() {
  local fake_gdm_output
  fake_gdm_output="$(env -u RESOURCE_PULSE_NESTED_DIR ${1:+RESOURCE_PULSE_NESTED_DIR="$1"} \
    timeout "$GLUE_PARSE_TIMEOUT_SECONDS" gjs -m "$NESTED_FILES/fake-gdm.js" "$2" 2>&1)"
  if [[ "$fake_gdm_output" == *"$FAKE_GDM_REFUSAL"* ]]; then printf refused; else printf 'tried-to-connect'; fi
}
fake_gdm_summary="no-run=$(fake_gdm_verdict '' 'unix:path=/run/dbus/system_bus_socket')"
fake_gdm_summary+=" real-bus=$(fake_gdm_verdict "$PREPARED_RUN" 'unix:path=/run/dbus/system_bus_socket')"
# The run's own (absent) socket: accepted, so it tries to connect and fails there instead.
fake_gdm_summary+=" own-bus=$(fake_gdm_verdict "$PREPARED_RUN" "unix:path=$PREPARED_RUN/bus/system.sock")"
check "nested: fake-gdm.js refuses any bus but its run's fake one, before connecting" \
  "$fake_gdm_summary" "no-run=refused real-bus=refused own-bus=tried-to-connect"

# The two apps whose presence makes GNOME 50 check extensions.gnome.org for
# updates (extensionSystem.js updatesSupported): masked, and copied into the run.
masked_update_apps=0
for update_app_id in org.gnome.Extensions com.mattjakeman.ExtensionManager; do
  if [[ "$(grep -c -x -F 'Hidden=true' "$NESTED_FILES/applications/$update_app_id.desktop" 2>/dev/null)" == 1 &&
        -f "$PREPARED_RUN/data/applications/$update_app_id.desktop" ]]; then
    masked_update_apps=$((masked_update_apps + 1))
  fi
done
check "nested: both apps that make the shell check extensions.gnome.org are masked in the run" "$masked_update_apps" 2

UNSAFE_MODE_HELPER_JS="$NESTED_FILES/$UNSAFE_MODE_HELPER_UUID/extension.js"
# The FIRST line that sets unsafe mode must come after the guard.
helper_guard_line="$(grep -n -m 1 -F 'if (!isInsideNestedRun())' "$UNSAFE_MODE_HELPER_JS" 2>/dev/null | cut -d: -f1)"
helper_unsafe_line="$(grep -n -m 1 -F 'global.context.unsafe_mode = true' "$UNSAFE_MODE_HELPER_JS" 2>/dev/null | cut -d: -f1)"
helper_placement="$([[ -d "$PREPARED_RUN/data/gnome-shell/extensions/$UNSAFE_MODE_HELPER_UUID" ]] && printf run)"
helper_placement+="$([[ -e "$DOTFILES/gnome-shell/extensions/$UNSAFE_MODE_HELPER_UUID" ]] && printf +linkable)"
check "nested: the unsafe-mode helper checks for a nested run first, and lives only in the run's data dir" \
  "$(( ${helper_guard_line:-0} > 0 && ${helper_unsafe_line:-0} > ${helper_guard_line:-0} )):$helper_placement" "1:run"

# make_fake_stat <pid> <comm> <session> writes one /proc/<pid>/stat.
NESTED_FAKE_PROC="$WIRING_TMP/nested-proc"
make_fake_stat() {
  mkdir -p "$NESTED_FAKE_PROC/$1"
  printf '%s (%s) S 1 %s %s 0 -1 4194304\n' "$1" "$2" "$1" "$3" >"$NESTED_FAKE_PROC/$1/stat"
}
make_fake_stat 500 gnome-shell 500
make_fake_stat 501 'odd) S 1 9 9 (name' 500
make_fake_stat 502 bash 777
check "nested: the teardown sweep finds exactly the run's session, even past a comm holding ') '" \
  "$(nested_call pids_in_session "$NESTED_FAKE_PROC" 500 | sort -n | tr '\n' ' ')" "500 501 "

# The stage that runs inside the private bus writes settings and starts
# gnome-shell (both stubs here). It has two guards, so each call below defeats
# one of them: (a) the live environment with the run's private bus address
# claimed, and (b) the run's isolated environment with no private bus. Each
# must refuse on its own guard, writing no setting and starting no shell.
: >"$NESTED_STUB_CALLS"
live_env_in_bus_output="$(env -u RESOURCE_PULSE_NESTED_DIR PATH="$NESTED_STUB_BIN:$PATH" \
  NESTED_STUB_CALLS="$NESTED_STUB_CALLS" DBUS_SESSION_BUS_ADDRESS="unix:path=$PREPARED_RUN/bus/session.sock" \
  bash "$NESTED_SCRIPT" __inside-session-bus "$PREPARED_RUN" 2>&1)"
live_env_in_bus_exit=$?
no_bus_in_bus_output="$(nested_call run_isolated "$PREPARED_RUN" \
  env PATH="$NESTED_STUB_BIN:/usr/bin:/bin" NESTED_STUB_CALLS="$NESTED_STUB_CALLS" \
  bash "$NESTED_SCRIPT" __inside-session-bus "$PREPARED_RUN" 2>&1)"
no_bus_in_bus_exit=$?
in_bus_summary="live-env=$live_env_in_bus_exit/$(grep -c -F 'the in-bus stage is not isolated' <<<"$live_env_in_bus_output")"
in_bus_summary+=" no-private-bus=$no_bus_in_bus_exit/$(grep -c -F "is not this run's private one" <<<"$no_bus_in_bus_output")"
in_bus_summary+=" stub-calls=$(nested_stub_call_count)"
in_bus_summary+=" address=$([[ -e "$PREPARED_RUN/state/session.addr" ]] && printf recorded || printf none)"
check "nested: the in-bus stage refuses a live environment and a missing private bus, each on its own guard" \
  "$in_bus_summary" "live-env=2/1 no-private-bus=2/1 stub-calls=0 address=none"

printf '\nthe stub, never the real session, answered gsettings\n'
run_apply_against_stub '@as []' '@as []' false "$SHELL_SCHEMA"
check "the apply script called the stub gsettings to set enabled-extensions" \
  "$(grep -c -x -F "set $SHELL_SCHEMA enabled-extensions ['$EXTENSION_UUID']" "$STUB_CALLS_LOG")" 1

# The guide must state this suite's own row count, as test-dock-wifi.sh does.
docs_claim() {
  local f="$DOTFILES/$1"
  [[ -r "$f" ]] || { printf 'cannot read %s' "$1"; return; }
  tr -s '[:space:]' ' ' <"$f" \
    | grep -c -F "\`scripts/test-resource-pulse.sh\` ($EXPECTED_ROWS checks"
}

EXPECTED_ROWS=192

printf '\nthe count this suite is documented as running\n'
check "docs/GNOME_CONFIGURATION_GUIDE.md says $EXPECTED_ROWS checks" "$(docs_claim docs/GNOME_CONFIGURATION_GUIDE.md)" 1
check "a documented file that cannot be read is not a pass" "$(docs_claim no/such/file.md)" "cannot read no/such/file.md"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( PASS + FAIL != EXPECTED_ROWS )); then
  printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
    "$EXPECTED_ROWS" "$((PASS + FAIL))"
  FAIL=$((FAIL + 1))
fi
(( FAIL == 0 ))
