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
# "Could not run" is exit 2, never a pass: a missing gjs, zsh, find or timeout, or a
# missing tally line (an import error prints none) is fatal. The suite asserts
# its own row total.
#
# Requires: bash, gjs, zsh (for gnome-status), find, timeout. No network, no root.
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
for required_tool in gjs zsh find timeout; do
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

# The shell side runs on the compositor's main loop: no subprocess and no
# synchronous file IO, anywhere in it. service/ is the sampler service, its own
# process outside the shell, so it may read files synchronously; it still starts
# no subprocess. Each Gio call is matched with its "(" so its _async form
# (enumerate_children_async( and so on) does not match.
SUBPROCESS_CALL_PATTERN='Gio.Subprocess|GLib.spawn|Util.spawn'
BLOCKING_CALL_PATTERN="$SUBPROCESS_CALL_PATTERN"'|load_contents\(|file_get_contents|enumerate_children\(|query_info\(|read_bytes\(|load_bytes\(|replace_contents\('
SERVICE_DIRECTORY="$EXT_DIR/service"
# The pattern itself: every forbidden call (a subprocess, synchronous IO) must match, and no _async IO call.
FORBIDDEN_CALLS=('Gio.Subprocess.new(' 'GLib.spawn_command_line_async(' 'Util.spawn([' 'file.load_contents(null)'
  'GLib.file_get_contents(path)' 'file.enumerate_children(attributes, flags, null)' 'file.query_info(attributes, flags, null)'
  'stream.read_bytes(4096, null)' 'file.load_bytes(null)' 'file.replace_contents(bytes, null, false, 0, null)')
ASYNCHRONOUS_IO_CALLS=('file.load_contents_async(null)' 'file.enumerate_children_async(attributes, flags, priority, null)'
  'file.query_info_async(attributes, flags, priority, null)' 'stream.read_bytes_async(4096, priority, null)'
  'file.load_bytes_async(null)' 'file.replace_contents_async(bytes, null, false, 0, null)')
unmatched_forbidden_calls=()
for io_call in "${FORBIDDEN_CALLS[@]}"; do
  [[ "$io_call" =~ $BLOCKING_CALL_PATTERN ]] || unmatched_forbidden_calls+=("$io_call")
done
matched_asynchronous_calls=()
for io_call in "${ASYNCHRONOUS_IO_CALLS[@]}"; do
  [[ "$io_call" =~ $BLOCKING_CALL_PATTERN ]] && matched_asynchronous_calls+=("$io_call")
done
check "the blocking-call pattern matches every forbidden call (subprocess, synchronous IO) and no _async IO call" \
  "missed=[${unmatched_forbidden_calls[*]}] async-matched=[${matched_asynchronous_calls[*]}]" "missed=[] async-matched=[]"
mapfile -d '' EXTENSION_FILE_PATHS < <(find "$EXT_DIR" -type f -print0 2>/dev/null)
row_name="no file in the extension spawns a process, and none outside service/ does synchronous file IO"
if (( ${#EXTENSION_FILE_PATHS[@]} == 0 )); then
  bad "$row_name — found no files under $EXT_DIR"
else
  blocking_calls=()
  for extension_file_path in "${EXTENSION_FILE_PATHS[@]}"; do
    forbidden_call_pattern="$BLOCKING_CALL_PATTERN"
    [[ "$extension_file_path" == "$SERVICE_DIRECTORY"/* ]] && forbidden_call_pattern="$SUBPROCESS_CALL_PATTERN"
    if [[ "$(<"$extension_file_path")" =~ $forbidden_call_pattern ]]; then
      blocking_calls+=("${extension_file_path#"$EXT_DIR"/}: ${BASH_REMATCH[0]}")
    fi
  done
  if (( ${#blocking_calls[@]} == 0 )); then
    ok "$row_name"
  else
    bad "$row_name — ${blocking_calls[*]}"
  fi
fi

# extension.js imports the Shell, so its teardown cannot run here. lib/teardown.js
# (runEveryStep, whose rows are in lifecycle.test.js) guards each step; these
# rows read extension.js for the order of its destroy steps, the card first
# because a card left behind would show frozen numbers as live, and for what
# a failed start says it removed.
EXTENSION_JS="$EXT_DIR/extension.js"
teardown_destroy_order="$(grep -E "run: \(\) => (card|indicator|sampler)\?\.destroy\(\)" "$EXTENSION_JS" 2>/dev/null \
  | sed -E 's/.*=> ([a-z]+)\?\.destroy.*/\1/' | tr '\n' ' ')"
check "extension.js tears down in guarded steps (runEveryStep), destroying the card, then the indicator, then the sampler" \
  "$teardown_destroy_order|$(grep -c -F 'runEveryStep([' "$EXTENSION_JS" 2>/dev/null)" "card indicator sampler |1"
# The sampler's own failures are self-healing, so they stay warnings (as they
# were before the logger was shared); the extension's start and teardown
# failures are errors. Each kind has one limiter that outlives every enable.
check "extension.js hands every sampler one rate-limited logger that writes warnings and spans enables" \
  "$(grep -c -F 'errorLog: this._samplerLog' "$EXTENSION_JS" 2>/dev/null):$(grep -c -E 'this\._samplerLog = new RateLimitedLogger\(\{nowUsec, write: line => console\.warn\(line\)\}\)' "$EXTENSION_JS" 2>/dev/null)" "1:1"
check "indicator.js re-places a shown hover label when its width or the display scale changes" \
  "$(grep -c -E "'notify::(width|scale-factor)'" "$EXT_DIR/indicator.js" 2>/dev/null)" 2
# notify::width is emitted during allocation, and moving an actor then makes
# Clutter warn "Can't update stage views actor ... needs an allocation" (seen in
# the nested shell for the card and the hover label). Both placements on a
# width change go through a BEFORE_REDRAW later instead, which teardown removes:
# the extension in a guarded step of _tearDown (the step itself is counted,
# not just the remove() it calls), the indicator inside _onDestroy.
deferred_placement_summary=""
for glue_file in extension.js indicator.js; do
  glue_path="$EXT_DIR/$glue_file"
  deferred_placement_summary+="$glue_file:$(grep -c -F 'Meta.LaterType.BEFORE_REDRAW' "$glue_path" 2>/dev/null)"
  deferred_placement_summary+="/$(grep -c -F 'get_laters().remove(' "$glue_path" 2>/dev/null)"
  deferred_placement_summary+="/$(grep -c -E "connect(Object)?\('notify::width', \(\) => this\._queue" "$glue_path" 2>/dev/null) "
done
teardown_cancels_placement="$(grep -c -F "{name: 'cancel the pending card placement', run: () => this._cancelCardPlacement()}" "$EXTENSION_JS" 2>/dev/null)"
on_destroy_removes_later="$(sed -n '/^    _onDestroy() {/,/^    }/p' "$EXT_DIR/indicator.js" 2>/dev/null | grep -c -F 'get_laters().remove(')"
check "a width change moves the card and the hover label in a BEFORE_REDRAW later, never during allocation" \
  "$deferred_placement_summary| teardown-step=$teardown_cancels_placement on-destroy=$on_destroy_removes_later" \
  "extension.js:1/1/1 indicator.js:1/1/1 | teardown-step=1 on-destroy=1"
check "extension.js says a failed start removed Resource Pulse, not just the indicator" \
  "$(grep -c -E "^const START_FAILURE_MESSAGE = '.*Resource Pulse.*removed" "$EXTENSION_JS" 2>/dev/null)" 1

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
#
# A stub is only a stub while it is there: if one failed to install, the real
# tool would run on the live session. So every stub is installed by
# install_stub (exit 2 unless it is an executable file, and unless PATH with its
# directory first resolves the tool to it), and every row that runs code which
# can write settings runs it behind LIVE_SETTINGS_BARRIER:
#   - a dead session bus address, so GLib cannot reach the live bus (dconf's
#     writes all go through it);
#   - a private XDG_RUNTIME_DIR, because with no address at all GLib falls back
#     to $XDG_RUNTIME_DIR/bus, which is the live bus;
#   - the in-memory GSettings backend, so even the real gsettings would write
#     to nothing. apply-gnome-settings.sh unsets that one on purpose (it guards
#     against snap terminals forcing it), so for its rows the bus is what holds.
# ---------------------------------------------------------------------------
APPLY_SCRIPT="$DOTFILES/scripts/apply-gnome-settings.sh"
COST_SCRIPT="$DOTFILES/scripts/resource-pulse-cost.sh"
EXTENSION_UUID="resource-pulse@dotfiles"
SHELL_SCHEMA="org.gnome.shell"
WIRING_TMP="$(mktemp -d)" || fatal "mktemp -d failed"
trap 'rm -rf "$WIRING_TMP"' EXIT
LIVE_SETTINGS_BARRIER_RUNTIME_DIR="$WIRING_TMP/barrier-runtime"
LIVE_SETTINGS_BARRIER_BUS="unix:path=$WIRING_TMP/barrier-no-session-bus"
if ! mkdir -p "$LIVE_SETTINGS_BARRIER_RUNTIME_DIR" || ! chmod 700 "$LIVE_SETTINGS_BARRIER_RUNTIME_DIR"; then
  fatal "cannot create the barrier's private runtime dir"
fi
LIVE_SETTINGS_BARRIER=(GSETTINGS_BACKEND=memory "DBUS_SESSION_BUS_ADDRESS=$LIVE_SETTINGS_BARRIER_BUS"
  "XDG_RUNTIME_DIR=$LIVE_SETTINGS_BARRIER_RUNTIME_DIR")
# install_stub <dir> <tool> <source>: writes an executable stub, then exits 2
# unless it is one and PATH with <dir> first resolves <tool> to it.
install_stub() {
  local stub_dir="$1" tool_name="$2" stub_source="$3" resolved_path
  if ! mkdir -p "$stub_dir" || ! printf '%s\n' "$stub_source" >"$stub_dir/$tool_name" || ! chmod +x "$stub_dir/$tool_name"
  then
    fatal "cannot install the $tool_name stub in $stub_dir"
  fi
  [[ -f "$stub_dir/$tool_name" && -x "$stub_dir/$tool_name" ]] || fatal "the $tool_name stub in $stub_dir is not executable"
  # shellcheck disable=SC2016  # Expanded by the child bash, with the stub dir first on its PATH.
  resolved_path="$(env PATH="$stub_dir:$PATH" bash -c 'command -v "$1"' resolve-stub "$tool_name")"
  [[ "$resolved_path" == "$stub_dir/$tool_name" ]] \
    || fatal "PATH with $stub_dir first finds $tool_name at '$resolved_path', not the stub"
}
STUB_BIN="$WIRING_TMP/bin"
STUB_STATE="$WIRING_TMP/gsettings"
mkdir -p "$STUB_BIN" "$STUB_STATE" || fatal "cannot create the gsettings stub directory"
GENABLE_GSETTINGS_STUB="$(cat <<'STUB'
#!/usr/bin/env bash
# Stateful gsettings stand-in: get/set/list-schemas over files under $STUB_STATE.
# Every call is logged to $STUB_CALLS, so a row can prove the stub was the one used,
# and the session bus it was given to $STUB_BUS_SEEN, so a row can prove the barrier held.
printf '%s\n' "$*" >>"$STUB_CALLS"
printf '%s\n' "${DBUS_SESSION_BUS_ADDRESS-unset}" >>"$STUB_BUS_SEEN"
case "$1" in
  list-schemas) cat "$STUB_STATE/schemas" 2>/dev/null ;;
  get)
    if [[ -f "$STUB_STATE/$2/$3" ]]; then cat "$STUB_STATE/$2/$3"
    else
      case "$3" in
        *-extensions)                 echo '@as []' ;;
        disable-user-extensions)      echo 'false' ;;
        allow-extension-installation) echo 'true' ;;
        *)                            echo "''" ;;
      esac
    fi ;;
  set) mkdir -p "$STUB_STATE/$2" && printf '%s\n' "$4" >"$STUB_STATE/$2/$3" ;;
  *) exit 1 ;;
esac
STUB
)"
install_stub "$STUB_BIN" gsettings "$GENABLE_GSETTINGS_STUB"
printf 'genable_extension %s\n' "$EXTENSION_UUID" >"$WIRING_TMP/local-overrides"

STUB_CALLS_LOG="$WIRING_TMP/stub-calls"
STUB_BUS_SEEN_LOG="$WIRING_TMP/stub-bus-seen"

# Reset the stub to a state, run the apply script, leave its stderr+stdout in
# APPLY_OUTPUT and its exit status in APPLY_EXIT.
#   $1 enabled-extensions  $2 disabled-extensions  $3 disable-user-extensions
#   $4 schemas listed by the stub (newline separated)
#   $5 allow-extension-installation (optional; unset, the stub answers true)
run_apply_against_stub() {
  rm -rf "${STUB_STATE:?}"/*
  mkdir -p "$STUB_STATE/$SHELL_SCHEMA"
  printf '%s\n' "$1" >"$STUB_STATE/$SHELL_SCHEMA/enabled-extensions"
  printf '%s\n' "$2" >"$STUB_STATE/$SHELL_SCHEMA/disabled-extensions"
  printf '%s\n' "$3" >"$STUB_STATE/$SHELL_SCHEMA/disable-user-extensions"
  if (( $# >= 5 )); then printf '%s\n' "$5" >"$STUB_STATE/$SHELL_SCHEMA/allow-extension-installation"; fi
  printf '%s' "$4" >"$STUB_STATE/schemas"
  : >"$STUB_CALLS_LOG"
  : >"$STUB_BUS_SEEN_LOG"
  APPLY_OUTPUT="$(env "${LIVE_SETTINGS_BARRIER[@]}" PATH="$STUB_BIN:$PATH" STUB_STATE="$STUB_STATE" \
    STUB_CALLS="$STUB_CALLS_LOG" STUB_BUS_SEEN="$STUB_BUS_SEEN_LOG" XDG_CURRENT_DESKTOP=GNOME \
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
# GNOME 50 reads the user extension dir, where ./install links the extension,
# only while allow-extension-installation is true (extensionSystem.js).
run_apply_against_stub '@as []' '@as []' false "$SHELL_SCHEMA" false
installation_off_warnings="$(grep -c -F 'allow-extension-installation is false' <<<"$APPLY_OUTPUT")"
run_apply_against_stub '@as []' '@as []' false "$SHELL_SCHEMA" true
installation_on_warnings="$(grep -c -F 'allow-extension-installation' <<<"$APPLY_OUTPUT")"
check "genable_extension: allow-extension-installation=false warns by name (GNOME 50 then skips the user dir); true does not" \
  "false=$installation_off_warnings true=$installation_on_warnings" "false=1 true=0"
run_apply_against_stub '@as []' '@as []' false ""
check "genable_extension: an absent org.gnome.shell schema warns" "$(grep -c -F "Schema '$SHELL_SCHEMA' not found" <<<"$APPLY_OUTPUT")" 1
check "genable_extension: an absent schema writes nothing" "$(stub_value enabled-extensions)" "@as []"
check "genable_extension: the apply script still exits 0 without the schema" "$APPLY_EXIT" 0

printf '\ngnome-status (zsh, with gsettings, gnome-extensions and gnome-shell stubs)\n'
# gnome-status (zsh/functions/system.sh) reads gsettings and asks the shell,
# through gnome-extensions, for the extension's State. With the user extension
# dir skipped the shell does not know the extension at all, so the stub answers
# like the real tool does then: nothing listed, and info fails.
GNOME_STATUS_STUB_BIN="$WIRING_TMP/gnome-status-bin"
GNOME_STATUS_HOME="$WIRING_TMP/gnome-status-home"
mkdir -p "$GNOME_STATUS_HOME" || fatal "cannot create gnome-status's fixture home"
install_stub "$GNOME_STATUS_STUB_BIN" gsettings "$GENABLE_GSETTINGS_STUB"
# shellcheck disable=SC2016  # The stub's own source: its variables expand when it runs.
install_stub "$GNOME_STATUS_STUB_BIN" gnome-extensions '#!/usr/bin/env bash
# GNOME_STATUS_SHELL_STATE is the State the shell reports; empty means the shell does not know the extension.
[[ -n "$GNOME_STATUS_SHELL_STATE" ]] || { [[ "$1" == list ]] && exit 0; echo "Extension does not exist" >&2; exit 2; }
case "$1" in
  list) echo resource-pulse@dotfiles ;;
  info) printf "resource-pulse@dotfiles\n  State: %s\n" "$GNOME_STATUS_SHELL_STATE" ;;
esac'
install_stub "$GNOME_STATUS_STUB_BIN" gnome-shell '#!/usr/bin/env bash
echo "GNOME Shell 50.1"'
# gnome_status_hints <enabled-extensions> <allow-extension-installation> <disable-user-extensions> <State or ''>
# prints how many lines name each setting, and gnome-status's exit status.
gnome_status_hints() {
  local status_output status_exit
  rm -rf "${STUB_STATE:?}"/*
  mkdir -p "$STUB_STATE/$SHELL_SCHEMA"
  printf '%s\n' "$1" >"$STUB_STATE/$SHELL_SCHEMA/enabled-extensions"
  printf '%s\n' "$2" >"$STUB_STATE/$SHELL_SCHEMA/allow-extension-installation"
  printf '%s\n' "$3" >"$STUB_STATE/$SHELL_SCHEMA/disable-user-extensions"
  # shellcheck disable=SC2016  # Expanded by zsh.
  status_output="$(env "${LIVE_SETTINGS_BARRIER[@]}" HOME="$GNOME_STATUS_HOME" PATH="$GNOME_STATUS_STUB_BIN:$PATH" \
    STUB_STATE="$STUB_STATE" STUB_CALLS="$STUB_CALLS_LOG" STUB_BUS_SEEN="$STUB_BUS_SEEN_LOG" \
    GNOME_STATUS_SHELL_STATE="$4" zsh -c 'source "$1" && gnome-status' gnome-status \
    "$DOTFILES/zsh/functions/system.sh" 2>&1)"
  status_exit=$?
  printf '%s/%s/rc%s' "$(grep -c -F 'allow-extension-installation is false' <<<"$status_output")" \
    "$(grep -c -F 'disable-user-extensions is true' <<<"$status_output")" "$status_exit"
}
asked_for="['$EXTENSION_UUID']"
gnome_status_summary="installation-off=$(gnome_status_hints "$asked_for" false false '')"
gnome_status_summary+=" user-extensions-off=$(gnome_status_hints "$asked_for" true true '')"
gnome_status_summary+=" running=$(gnome_status_hints "$asked_for" false true ACTIVE)"
gnome_status_summary+=" not-asked-for=$(gnome_status_hints '@as []' false true '')"
check "gnome-status names the setting that keeps an enabled Resource Pulse from loading, and only then" \
  "$gnome_status_summary" "installation-off=1/0/rc0 user-extensions-off=0/1/rc0 running=0/0/rc0 not-asked-for=0/0/rc0"

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

# --cpu-percent over a fake window: `sleep` and `getconf` are stubs on PATH.
# The sleep stub records the window and moves the fake gnome-shell's stat on,
# as the window would; getconf says CLK_TCK is 250, so a hard-coded 100 Hz
# shows. utime (field 14) goes 100 -> 160 and stime (15) 50 -> 80: 90 ticks
# over 2 s at 250 Hz is 18.00% of one core. The neighbours move by other
# amounts (cmajflt 13: +37, cutime 16: +50, cstime 17: +90), so reading the
# wrong fields gives another number, as does dividing by the wrong thing.
CPU_PROC_ROOT="$WIRING_TMP/proc-cpu"
COST_STUB_BIN="$WIRING_TMP/cost-bin"
COST_SLEEP_CALLS="$WIRING_TMP/cost-sleep-calls"
COST_STAT_AFTER="$WIRING_TMP/cost-stat-after"
COST_WINDOW_SECONDS=2
make_fake_proc "$CPU_PROC_ROOT" 4242 gnome-shell "$FAKE_SHELL_RSS_KIB"
printf '4242 (gnome-shell) S 1 1 1 0 -1 0 0 0 0 3 100 50 7 9 20 0 1 0 1 0 0\n' >"$CPU_PROC_ROOT/4242/stat"
printf '4242 (gnome-shell) S 1 1 1 0 -1 0 0 0 5 40 160 80 57 99 20 0 1 0 1 0 0\n' >"$COST_STAT_AFTER"
# shellcheck disable=SC2016  # The stubs' own source: their variables expand when they run.
install_stub "$COST_STUB_BIN" sleep '#!/usr/bin/env bash
printf "%s\n" "$*" >>"$COST_SLEEP_CALLS"
cp "$COST_STAT_AFTER" "$COST_STAT_PATH"'
# shellcheck disable=SC2016
install_stub "$COST_STUB_BIN" getconf '#!/usr/bin/env bash
[[ "$1" == CLK_TCK ]] && echo 250'
: >"$COST_SLEEP_CALLS"
cpu_percent_output="$(PATH="$COST_STUB_BIN:$PATH" GNOME_SHELL_PID=4242 PROC_ROOT="$CPU_PROC_ROOT" \
  COST_SLEEP_CALLS="$COST_SLEEP_CALLS" COST_STAT_AFTER="$COST_STAT_AFTER" COST_STAT_PATH="$CPU_PROC_ROOT/4242/stat" \
  bash "$COST_SCRIPT" --cpu-percent "$COST_WINDOW_SECONDS" 2>&1)"
cpu_percent_exit=$?
check "cost: --cpu-percent is Δ(utime+stime) / (CLK_TCK × window) × 100, over the window it was given" \
  "exit=$cpu_percent_exit percent=$cpu_percent_output slept=$(tr '\n' ' ' <"$COST_SLEEP_CALLS")" \
  "exit=0 percent=18.00 slept=$COST_WINDOW_SECONDS "
# Spelled by pieces so this row's own source is not what it finds in the script.
FORBIDDEN_READS_PATTERN="cmd""line|env""iron\\b|pgre""p|\\bps -"
check "cost: the script never reads an argument list or environment, or runs ps" \
  "$(grep -c -E "$FORBIDDEN_READS_PATTERN" "$COST_SCRIPT" 2>/dev/null)" 0

printf '\nresource-pulse-nested.sh (hermetic: no gnome-shell, nothing is started)\n'
# The nested-shell harness itself needs gnome-shell and a GPU, so it never runs
# here. These rows cover what it decides before anything starts: its usage,
# the bus configs it renders, the environment allowlist, and its refusals. Every
# run of it here has busctl, gsettings and gnome-shell replaced by stubs that
# only record the call (jq too: CI does not install it, and no row here needs
# it to really run), and RESOURCE_PULSE_NESTED_BASE pointed at an empty
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
for stubbed_tool in busctl gsettings gnome-shell jq; do
  # shellcheck disable=SC2016  # The stub's own source: its $* and $NESTED_STUB_CALLS expand when it runs.
  install_stub "$NESTED_STUB_BIN" "$stubbed_tool" "$(printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >>"$NESTED_STUB_CALLS"\nexit 1' "$stubbed_tool")"
done
nested_stub_call_count() { printf '%d' "$(wc -l <"$NESTED_STUB_CALLS")"; }
# nested_run <args...> runs the script against the stubs and the empty base;
# leaves NESTED_OUTPUT and NESTED_EXIT. With NESTED_RUN_DIR set it names that
# run directory (RESOURCE_PULSE_NESTED_DIR); otherwise the script looks for one.
nested_run() {
  : >"$NESTED_STUB_CALLS"
  NESTED_OUTPUT="$(env -u RESOURCE_PULSE_NESTED_DIR "${LIVE_SETTINGS_BARRIER[@]}" \
    ${NESTED_RUN_DIR:+RESOURCE_PULSE_NESTED_DIR="$NESTED_RUN_DIR"} \
    PATH="$NESTED_STUB_BIN:$PATH" NESTED_STUB_CALLS="$NESTED_STUB_CALLS" RESOURCE_PULSE_NESTED_BASE="$NESTED_BASE" \
    bash "$NESTED_SCRIPT" "$@" 2>&1)"
  NESTED_EXIT=$?
}
# make_run_dir <dir> writes a run directory's marker (from its name) and,
# with more arguments, its run.values lines (name=value).
make_run_dir() {
  local run_dir="$1"
  shift
  mkdir -p "$run_dir/state" && chmod 700 "$run_dir"
  printf '%s\n' "${run_dir##*/rpn.}" >"$run_dir/.resource-pulse-nested"
  if (( $# > 0 )); then printf '%s\n' "$@" >"$run_dir/state/run.values"; fi
}
# is_running <pid> succeeds while the process exists and is not a zombie.
is_running() {
  local stat_line
  read -r stat_line 2>/dev/null <"/proc/$1/stat" || return 1
  [[ "${stat_line##*) }" != Z* ]]
}
# starttime_of <pid> prints a process's start time (stat field 22), parsed here
# independently of the script (whose own parser a row pins against this one).
starttime_of() {
  local stat_line
  local -a stat_fields
  read -r stat_line 2>/dev/null <"/proc/$1/stat" || return 0
  read -r -a stat_fields <<<"${stat_line##*) }"
  printf '%s' "${stat_fields[19]:-}"
}
# kill_sacrifice <pid> <comm> <start time> sends SIGTERM only while that pid is
# still the same sacrificial process: same comm, same start time.
kill_sacrifice() {
  local current_comm=""
  read -r current_comm 2>/dev/null <"/proc/$1/comm" || return 0
  [[ "$current_comm" == "$2" && "$(starttime_of "$1")" == "$3" && -n "$3" ]] || return 0
  kill "$1" 2>/dev/null
}
# start_sacrificial_session <command...> starts the command as the leader of a
# new session (setsid, then exec), waits until it runs, and prints its pid,
# which is also the session id. Only rows that must never touch a real session
# signal these.
SACRIFICE_DIR="$WIRING_TMP/sacrifices"
mkdir -p "$SACRIFICE_DIR"
start_sacrificial_session() {
  local pid_file
  pid_file="$(mktemp "$SACRIFICE_DIR/leader.XXXXXX")"
  # shellcheck disable=SC2016  # Expanded by the new session's own bash.
  setsid bash -c 'printf "%s\n" "$$" >"$1"; shift; exec "$@"' sacrifice "$pid_file" "$@" </dev/null >/dev/null 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "$pid_file" ]] && break
    sleep 0.1
  done
  cat "$pid_file"
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
# Named, not looked for: looking skips a run with no live supervisor, which this one has none of.
NESTED_RUN_DIR="$TAMPERED_RUN" nested_run eval '1 + 1'
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
  printf 'supervisor=%s\nsupervisor-starttime=%s\nsession=%s\ngnome-shell=%s\ngnome-shell-starttime=%s\n' \
    "$1" "$(starttime_of "$1")" "$2" "$3" "$(starttime_of "$3")" >"$STALE_RUN/state/run.values"
  NESTED_RUN_DIR="$STALE_RUN" nested_run eval '1 + 1'
  if [[ $NESTED_EXIT == 2 && $(nested_stub_call_count) == 0 ]]; then printf refused
  elif (( $(nested_stub_call_count) > 0 )); then printf reached-busctl
  else printf 'exit-%s' "$NESTED_EXIT"; fi
}
stale_summary="supervisor-gone=$(eval_stale_run "$NEVER_RUNNING_PID" "$test_session_id" "$fake_shell_pid")"
stale_summary+=" other-session=$(eval_stale_run "$$" "$NEVER_RUNNING_PID" "$fake_shell_pid")"
stale_summary+=" not-gnome-shell=$(eval_stale_run "$$" "$test_session_id" "$$")"
stale_summary+=" live=$(eval_stale_run "$$" "$test_session_id" "$fake_shell_pid")"
check "nested: eval refuses a run that is not live: supervisor gone, shell in another session, or not gnome-shell" \
  "$stale_summary" "supervisor-gone=refused other-session=refused not-gnome-shell=refused live=reached-busctl"

# A run that ended without `stop` (its lifetime ran out, or it crashed) next to
# a live one: looking for the live run must skip it, not report "several live
# runs" and steer the user to stop the ended one.
ENDED_RUN="$NESTED_BASE/rpn.Ended001"
make_run_dir "$ENDED_RUN" "launcher=$NEVER_RUNNING_PID" "session=$NEVER_RUNNING_PID" "supervisor=$NEVER_RUNNING_PID"
eval_stale_run "$$" "$test_session_id" "$fake_shell_pid" >/dev/null
nested_run eval '1 + 1'
check "nested: looking for the live run skips one whose supervisor and launcher are gone" \
  "$NESTED_EXIT:$(nested_stub_call_count):$(grep -c -F 'several live runs' <<<"$NESTED_OUTPUT")" "2:1:0"
rm -rf "$ENDED_RUN"

# A run marked ended (its supervisor's exit) or stopped, whose recorded
# processes still look live (the same pids and start times as the live run):
# only the marker can make looking for a live run skip it.
mv "$STALE_RUN" "$NESTED_BASE/rpn.Marked01"
MARKED_ENDED_RUN="$NESTED_BASE/rpn.Marked01"
: >"$MARKED_ENDED_RUN/state/ended"
printf '%s\n' Marked01 >"$MARKED_ENDED_RUN/.resource-pulse-nested"
MARKED_STOPPED_RUN="$NESTED_BASE/rpn.Marked02"
cp -a "$MARKED_ENDED_RUN" "$MARKED_STOPPED_RUN"
rm -f "$MARKED_STOPPED_RUN/state/ended"
: >"$MARKED_STOPPED_RUN/state/stopped"
printf '%s\n' Marked02 >"$MARKED_STOPPED_RUN/.resource-pulse-nested"
nested_run eval '1 + 1'
check "nested: looking for the live run skips a run marked ended or stopped, however live its pids look" \
  "$NESTED_EXIT:$(nested_stub_call_count):$(grep -c -F 'no live run' <<<"$NESTED_OUTPUT")" "2:0:1"
rm -rf "$MARKED_ENDED_RUN" "$MARKED_STOPPED_RUN"

# A pid can be reused once its process ends. A recorded process counts only
# while the same pid runs with the start time recorded for it, so a different
# start time (a reused pid) must never pass: (a) stop leaves a session led by
# a `timeout` it did not record; (b) eval refuses a shell it did not record;
# (c) looking for a live run skips a run whose supervisor is someone else.
reused_pid_session_id="$(start_sacrificial_session timeout 60 sleep 60)"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ "$(cat "/proc/$reused_pid_session_id/comm" 2>/dev/null)" == timeout ]] && break
  sleep 0.1
done
reused_pid_starttime="$(starttime_of "$reused_pid_session_id")"
REUSED_PID_RUN="$NESTED_BASE/rpn.ReusePid"
make_run_dir "$REUSED_PID_RUN" "launcher=$reused_pid_session_id" "launcher-starttime=$((reused_pid_starttime + 1))" \
  "session=$reused_pid_session_id" "supervisor=$reused_pid_session_id" \
  "supervisor-starttime=$((reused_pid_starttime + 1))"
NESTED_RUN_DIR="$REUSED_PID_RUN" nested_run stop
reused_pid_summary="stop=$(is_running "$reused_pid_session_id" && printf left-running || printf signalled)"
kill_sacrifice "$reused_pid_session_id" timeout "$reused_pid_starttime"
SHELL_REUSED_RUN="$NESTED_BASE/rpn.ShellPid"
make_run_dir "$SHELL_REUSED_RUN" "supervisor=$$" "supervisor-starttime=$(starttime_of "$$")" "session=$test_session_id" \
  "gnome-shell=$fake_shell_pid" "gnome-shell-starttime=$(( $(starttime_of "$fake_shell_pid") + 1 ))"
printf '%s\n' "unix:path=$SHELL_REUSED_RUN/bus/session.sock,guid=0123456789abcdef" >"$SHELL_REUSED_RUN/state/session.addr"
NESTED_RUN_DIR="$SHELL_REUSED_RUN" nested_run eval '1 + 1'
reused_pid_summary+=" eval=$([[ $NESTED_EXIT == 2 && $(nested_stub_call_count) == 0 ]] && printf refused || printf 'exit-%s' "$NESTED_EXIT")"
SUPERVISOR_REUSED_RUN="$NESTED_BASE/rpn.SupvPid1"
make_run_dir "$SUPERVISOR_REUSED_RUN" "supervisor=$$" "supervisor-starttime=$(( $(starttime_of "$$") + 1 ))" \
  "session=$test_session_id" "gnome-shell=$fake_shell_pid" "gnome-shell-starttime=$(starttime_of "$fake_shell_pid")"
printf '%s\n' "unix:path=$SUPERVISOR_REUSED_RUN/bus/session.sock,guid=0123456789abcdef" \
  >"$SUPERVISOR_REUSED_RUN/state/session.addr"
rm -rf "$SHELL_REUSED_RUN"
nested_run eval '1 + 1'
reused_pid_summary+=" discovery=$(grep -c -F 'no live run' <<<"$NESTED_OUTPUT")"
check "nested: a recorded pid with another start time (a reused pid) passes nowhere: stop, eval, or looking for a run" \
  "$reused_pid_summary" "stop=left-running eval=refused discovery=1"
rm -rf "$REUSED_PID_RUN" "$SUPERVISOR_REUSED_RUN"
kill "$fake_shell_pid" 2>/dev/null
wait "$fake_shell_pid" 2>/dev/null

# `stop` signals a session only while its leader is this run's recorded
# launcher, `timeout`: a session id is a pid, and once a run's processes are all
# gone another session can take the same id. Each case below runs `stop` on a
# fixture run against a sacrificial session, so even a mutant can only ever
# signal a session made for the row.
# (1) A session led by something else (a reused id): `stop` must leave it
# running, and just clean the run up.
reused_session_id="$(start_sacrificial_session sleep 60)"
reused_session_starttime="$(starttime_of "$reused_session_id")"
REUSED_RUN="$NESTED_BASE/rpn.Reused01"
make_run_dir "$REUSED_RUN" "launcher=$reused_session_id" "launcher-starttime=$reused_session_starttime" \
  "session=$reused_session_id" "supervisor=$reused_session_id" "supervisor-starttime=$reused_session_starttime" \
  "gnome-shell=$reused_session_id" "gnome-shell-starttime=$reused_session_starttime"
NESTED_RUN_DIR="$REUSED_RUN" nested_run stop
reused_summary="exit=$NESTED_EXIT left-running=$(is_running "$reused_session_id" && printf yes || printf no)"
reused_summary+=" stopped=$([[ -e "$REUSED_RUN/state/stopped" ]] && printf yes || printf no)"
kill_sacrifice "$reused_session_id" sleep "$reused_session_starttime"
check "nested: stop leaves a session alone once its leader is not the run's timeout (a reused id), and cleans up" \
  "$reused_summary" "exit=0 left-running=yes stopped=yes"
# (2) A session still led by the run's timeout: `stop` must end all of it.
timeout_session_id="$(start_sacrificial_session timeout 60 sleep 60)"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ "$(cat "/proc/$timeout_session_id/comm" 2>/dev/null)" == timeout ]] && break
  sleep 0.1
done
timeout_session_starttime="$(starttime_of "$timeout_session_id")"
TIMEOUT_RUN="$NESTED_BASE/rpn.Timeout1"
# Recorded as the run's gnome-shell too, so `stop` sends its first SIGTERM to it (timeout passes it on to its child).
make_run_dir "$TIMEOUT_RUN" "launcher=$timeout_session_id" "launcher-starttime=$timeout_session_starttime" \
  "session=$timeout_session_id" "supervisor=$timeout_session_id" "supervisor-starttime=$timeout_session_starttime" \
  "gnome-shell=$timeout_session_id" "gnome-shell-starttime=$timeout_session_starttime"
NESTED_RUN_DIR="$TIMEOUT_RUN" nested_run stop
timeout_summary="exit=$NESTED_EXIT leader-running=$(is_running "$timeout_session_id" && printf yes || printf no)"
timeout_summary+=" session-empty=$([[ -z "$(nested_call pids_in_session /proc "$timeout_session_id")" ]] && printf yes || printf no)"
check "nested: stop ends a session still led by the run's recorded timeout" "$timeout_summary" \
  "exit=0 leader-running=no session-empty=yes"
# Whatever stop did, nothing of the sacrificial session outlives the row (timeout passes the TERM to its child).
kill_sacrifice "$timeout_session_id" timeout "$timeout_session_starttime"
# (3) The caller's own session, and a session id of 1: refused, nothing signalled.
# The caller runs inside a sandbox session led by `timeout` and recorded as the
# launcher, so only the refusal stands between `stop` and that session.
OWN_RUN="$NESTED_BASE/rpn.OwnSess1"
make_run_dir "$OWN_RUN"
cat >"$SACRIFICE_DIR/stop-own-session.sh" <<'SANDBOX'
#!/bin/bash
# Records this sandbox's own session (led by its parent, timeout) as the run's, then runs `stop` from inside it.
run_dir="$1" script="$2"
read -r stat_line <"/proc/$$/stat"
read -r -a stat_fields <<<"${stat_line##*) }"
read -r parent_stat_line <"/proc/$PPID/stat"
read -r -a parent_stat_fields <<<"${parent_stat_line##*) }"
printf 'launcher=%s\nlauncher-starttime=%s\nsession=%s\nsupervisor=%s\nsupervisor-starttime=%s\n' "$PPID" \
  "${parent_stat_fields[19]}" "${stat_fields[3]}" "$PPID" "${parent_stat_fields[19]}" >"$run_dir/state/run.values"
RESOURCE_PULSE_NESTED_DIR="$run_dir" bash "$script" stop
printf 'stop-exit=%s\n' "$?"
SANDBOX
own_session_output="$(setsid timeout 60 bash "$SACRIFICE_DIR/stop-own-session.sh" "$OWN_RUN" "$NESTED_SCRIPT" 2>&1)"
SESSION_ONE_RUN="$NESTED_BASE/rpn.SessOne1"
make_run_dir "$SESSION_ONE_RUN" "launcher=1" "session=1" "supervisor=1"
NESTED_RUN_DIR="$SESSION_ONE_RUN" nested_run stop
refusal_summary="own-session=$(grep -c -x -F 'stop-exit=2' <<<"$own_session_output")/$(grep -c -F "the caller's own session" <<<"$own_session_output")"
refusal_summary+=" session-1=$NESTED_EXIT/$(grep -c -F 'a session id must be above 1' <<<"$NESTED_OUTPUT")"
check "nested: stop refuses the caller's own session and session 1, signalling nothing" \
  "$refusal_summary" "own-session=1/1 session-1=2/1"
# (4) Bash reads a script as it runs it: a run's supervisor waits inside main
# for up to 20 minutes, so the script must exit before reading past main, or an
# edit made meanwhile would run. A copy with a line appended after main must
# never reach that line.
SCRIPT_COPY="$WIRING_TMP/script-copy/scripts/resource-pulse-nested.sh"
mkdir -p "${SCRIPT_COPY%/*}" && cp "$NESTED_SCRIPT" "$SCRIPT_COPY"
printf 'printf "READ-PAST-MAIN\\n" >&2\n' >>"$SCRIPT_COPY"
ENDED_COPY_RUN="$NESTED_BASE/rpn.CopyRun1"
make_run_dir "$ENDED_COPY_RUN" "launcher=$NEVER_RUNNING_PID" "session=$NEVER_RUNNING_PID"
copy_output="$(RESOURCE_PULSE_NESTED_DIR="$ENDED_COPY_RUN" bash "$SCRIPT_COPY" stop 2>&1)"
copy_exit=$?
check "nested: the script exits before reading past main, so an edit made while a run waits never runs" \
  "$copy_exit:$(grep -c -F 'READ-PAST-MAIN' <<<"$copy_output")" "0:0"
rm -rf "$REUSED_RUN" "$TIMEOUT_RUN" "$OWN_RUN" "$SESSION_ONE_RUN" "$ENDED_COPY_RUN"

# The supervisor's exit sweep runs inside the session it sweeps, so it must not
# count itself (or a subshell of itself) as a member left behind: in a sandbox
# session with one child, the sweep must find the session empty and return 0,
# and mark the run ended.
SWEEP_RUN="$NESTED_BASE/rpn.Sweep001"
make_run_dir "$SWEEP_RUN"
cat >"$SACRIFICE_DIR/sweep-own-session.sh" <<'SANDBOX'
#!/bin/bash
# Leads its own session (setsid), starts one child, then runs the supervisor's exit sweep from inside it.
script="$1" run_dir="$2"
source "$script" || exit 99
sleep 60 &
child_pid=$!
session_id="$(session_id_of_process /proc "$$")"
signal_session "$session_id" TERM 1 "$$" "$PPID"
printf 'signal-exit=%s\n' "$?"
end_supervised_session "$run_dir" "$session_id"
printf 'child-running=%s\n' "$(kill -0 "$child_pid" 2>/dev/null && [[ "$(cut -d' ' -f3 "/proc/$child_pid/stat" 2>/dev/null)" != Z ]] && echo yes || echo no)"
SANDBOX
sweep_output="$(setsid bash "$SACRIFICE_DIR/sweep-own-session.sh" "$NESTED_SCRIPT" "$SWEEP_RUN" 2>&1)"
sweep_summary="$(grep -x -E 'signal-exit=[0-9]+|child-running=(yes|no)' <<<"$sweep_output" | tr '\n' ' ')"
sweep_summary+="ended=$([[ -e "$SWEEP_RUN/state/ended" ]] && printf yes || printf no)"
sweep_summary+=" outlived-note=$(grep -c -F 'outlived SIGKILL' <<<"$sweep_output")"
check "nested: the supervisor's exit sweep sees its own session empty, returns 0 and marks the run ended" \
  "$sweep_summary" "signal-exit=0 child-running=no ended=yes outlived-note=0"
rm -rf "$SWEEP_RUN"

# A base directory others can read would make run directories discoverable.
PUBLIC_BASE="$WIRING_TMP/public-base-named-longer-than-any-run-directory-may-be"
mkdir -p "$PUBLIC_BASE" && chmod 755 "$PUBLIC_BASE"
: >"$NESTED_STUB_CALLS"
public_base_output="$(env -u RESOURCE_PULSE_NESTED_DIR "${LIVE_SETTINGS_BARRIER[@]}" PATH="$NESTED_STUB_BIN:$PATH" \
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
mkdir -p "$NESTED_FAKE_PROC/503"
printf '503 (odd) S 1 9 9 (name) S 1 503 503 0 -1 4194304 1 2 3 4 5 6 7 8 20 0 1 0 98765 0 0\n' \
  >"$NESTED_FAKE_PROC/503/stat"
# What start, the supervisor and the in-bus stage call to record a process:
# it must write <name> and <name>-starttime, and then count as running.
RECORD_RUN="$WIRING_TMP/record-run"
mkdir -p "$RECORD_RUN/state"
# shellcheck disable=SC2016  # Expanded by the child bash.
recorded_check="$(bash -c 'source "$1" || exit 99; record_running_process "$2" probe "$3" &&
  is_recorded_process_running "$2" probe && printf running' record-check "$NESTED_SCRIPT" "$RECORD_RUN" "$$")"
recorded_values="$(tr '\n' ' ' <"$RECORD_RUN/state/run.values" 2>/dev/null)"
check "nested: start times are read from stat field 22, even past a comm holding ') ', as this suite reads them" \
  "fake=$(nested_call starttime_of_process "$NESTED_FAKE_PROC" 503) self=$([[ "$(nested_call starttime_of_process /proc "$$")" == "$(starttime_of "$$")" && -n "$(starttime_of "$$")" ]] && printf match || printf differs) recorded=$recorded_check values=$recorded_values" \
  "fake=98765 self=match recorded=running values=probe=$$ probe-starttime=$(starttime_of "$$") "
check "nested: the teardown sweep finds exactly the run's session, even past a comm holding ') '" \
  "$(nested_call pids_in_session "$NESTED_FAKE_PROC" 500 | sort -n | tr '\n' ' ')" "500 501 "

# GNOME 50 scans the user extension dir only while allow-extension-installation
# is on (extensionSystem.js _loadExtensions), and both extensions are copied
# there. So no nested setting may turn it off, or neither extension loads and
# `start` can never succeed. A gsettings stub that records and succeeds stands in.
NESTED_SETTINGS_STUB_BIN="$WIRING_TMP/nested-settings-bin"
NESTED_SETTINGS_CALLS="$WIRING_TMP/nested-settings-calls"
NESTED_SETTINGS_BUS_SEEN="$WIRING_TMP/nested-settings-bus-seen"
# shellcheck disable=SC2016  # The stub's own source.
install_stub "$NESTED_SETTINGS_STUB_BIN" gsettings '#!/usr/bin/env bash
printf "%s\n" "$*" >>"$NESTED_SETTINGS_CALLS"
printf "%s %s\n" "${GSETTINGS_BACKEND-unset}" "${DBUS_SESSION_BUS_ADDRESS-unset}" >>"$NESTED_SETTINGS_BUS_SEEN"'
: >"$NESTED_SETTINGS_CALLS"
: >"$NESTED_SETTINGS_BUS_SEEN"
# write_nested_settings has no guard of its own (the in-bus stage guards it), so the barrier is what stands
# between it and the live dconf should the stub ever be missing.
# shellcheck disable=SC2016  # Expanded by the child bash.
env "${LIVE_SETTINGS_BARRIER[@]}" PATH="$NESTED_SETTINGS_STUB_BIN:$PATH" NESTED_SETTINGS_CALLS="$NESTED_SETTINGS_CALLS" \
  NESTED_SETTINGS_BUS_SEEN="$NESTED_SETTINGS_BUS_SEEN" \
  bash -c 'source "$1" || exit 99; write_nested_settings' nested-settings "$NESTED_SCRIPT"
nested_settings_summary="exit=$?"
nested_settings_summary+=" enabled=$(grep -c -x -F "set org.gnome.shell enabled-extensions ['$UNSAFE_MODE_HELPER_UUID', 'resource-pulse@dotfiles']" "$NESTED_SETTINGS_CALLS")"
nested_settings_summary+=" installation-off=$(grep -c -F 'allow-extension-installation false' "$NESTED_SETTINGS_CALLS")"
nested_settings_summary+=" barrier=$(sort -u "$NESTED_SETTINGS_BUS_SEEN" | tr '\n' ' ')"
USER_EXTENSIONS_DIR="$PREPARED_RUN/data/gnome-shell/extensions"
nested_settings_summary+=" in-user-dir=$([[ -f "$USER_EXTENSIONS_DIR/$UNSAFE_MODE_HELPER_UUID/metadata.json" && -f "$USER_EXTENSIONS_DIR/resource-pulse@dotfiles/metadata.json" ]] && printf both || printf missing)"
check "nested: no nested setting hides the user extension dir, where both extensions are copied" \
  "$nested_settings_summary" "exit=0 enabled=1 installation-off=0 barrier=memory $LIVE_SETTINGS_BARRIER_BUS  in-user-dir=both"

# `start` polls the shell's unsafe mode over busctl. A shell that answers with
# unsafe mode off (Eval's (false, '')) is up but the helper did not load, which
# must fail fast with its own message, not as "did not answer" after 120 s.
probe_summary="ready=$(nested_call classify_unsafe_mode_probe 0 '{"type":"bs","data":[true,"true"]}')"
probe_summary+=" unsafe-off=$(nested_call classify_unsafe_mode_probe 0 '{"type":"bs","data":[false,""]}')"
probe_summary+=" no-shell=$(nested_call classify_unsafe_mode_probe 1 'Call failed: The name org.gnome.Shell was not provided')"
check "nested: start tells a shell that answers with unsafe mode off from one that has not answered yet" \
  "$probe_summary" "ready=ready unsafe-off=unsafe-mode-off no-shell=not-answering"

# The stage that runs inside the private bus writes settings and starts
# gnome-shell (both stubs here). It has two guards, so each call below defeats
# one of them: (a) the live environment with the run's private bus address
# claimed, and (b) the run's isolated environment with no private bus. Each
# must refuse on its own guard, writing no setting and starting no shell.
# Both run behind the barrier; (b) keeps the run's own runtime dir, which is
# already private, so that only its missing private bus is wrong.
: >"$NESTED_STUB_CALLS"
live_env_in_bus_output="$(env -u RESOURCE_PULSE_NESTED_DIR "${LIVE_SETTINGS_BARRIER[@]}" PATH="$NESTED_STUB_BIN:$PATH" \
  NESTED_STUB_CALLS="$NESTED_STUB_CALLS" DBUS_SESSION_BUS_ADDRESS="unix:path=$PREPARED_RUN/bus/session.sock" \
  bash "$NESTED_SCRIPT" __inside-session-bus "$PREPARED_RUN" 2>&1)"
live_env_in_bus_exit=$?
no_bus_in_bus_output="$(nested_call run_isolated "$PREPARED_RUN" \
  env GSETTINGS_BACKEND=memory DBUS_SESSION_BUS_ADDRESS="$LIVE_SETTINGS_BARRIER_BUS" \
  PATH="$NESTED_STUB_BIN:/usr/bin:/bin" NESTED_STUB_CALLS="$NESTED_STUB_CALLS" \
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
check "the apply script called the stub gsettings to set enabled-extensions, behind the dead-bus barrier" \
  "$(grep -c -x -F "set $SHELL_SCHEMA enabled-extensions ['$EXTENSION_UUID']" "$STUB_CALLS_LOG"):$(sort -u "$STUB_BUS_SEEN_LOG" | tr '\n' ' ')" \
  "1:$LIVE_SETTINGS_BARRIER_BUS "

# The guide must state this suite's own row count, as test-dock-wifi.sh does.
docs_claim() {
  local f="$DOTFILES/$1"
  [[ -r "$f" ]] || { printf 'cannot read %s' "$1"; return; }
  tr -s '[:space:]' ' ' <"$f" \
    | grep -c -F "\`scripts/test-resource-pulse.sh\` ($EXPECTED_ROWS checks"
}

EXPECTED_ROWS=352

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
