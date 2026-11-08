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

REAL_ENABLED_BEFORE="$(gsettings get "$SHELL_SCHEMA" enabled-extensions 2>&1)"

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
  APPLY_OUTPUT="$(PATH="$STUB_BIN:$PATH" STUB_STATE="$STUB_STATE" XDG_CURRENT_DESKTOP=GNOME \
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

printf '\nthe real session was not touched\n'
check "the real enabled-extensions is unchanged by this run" \
  "$(gsettings get "$SHELL_SCHEMA" enabled-extensions 2>&1)" "$REAL_ENABLED_BEFORE"

# The guide must state this suite's own row count, as test-dock-wifi.sh does.
docs_claim() {
  local f="$DOTFILES/$1"
  [[ -r "$f" ]] || { printf 'cannot read %s' "$1"; return; }
  tr -s '[:space:]' ' ' <"$f" \
    | grep -c -F "\`scripts/test-resource-pulse.sh\` ($EXPECTED_ROWS checks"
}

EXPECTED_ROWS=170

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
