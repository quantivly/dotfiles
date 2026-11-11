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
# The sampler service's D-Bus rows (gnome-shell/tests/run-private-bus.js) and
# its entry point run inside `dbus-run-session`, on a private bus of this run,
# and refuse to run on any other: never on the live session bus. The service's
# install step runs against a systemctl stub, never the live user manager.
#
# "Could not run" is exit 2, never a pass: a missing gjs, zsh, find, timeout,
# dbus-run-session, gdbus or script, a fake herdr client that did not come up,
# or a missing tally line (an import error prints none) is fatal. The suite
# asserts its own row total.
#
# Requires: bash, gjs, zsh (for gnome-status), find, timeout, dbus-run-session
# (Ubuntu: dbus-daemon), gdbus (libglib2.0-bin; gnome-status asks the real
# service through it), script (util-linux's, from bsdutils: it gives the fake
# herdr client of the FocusSession rows a terminal), and for the card-width row
# the Pango typelibs (gir1.2-pango-1.0) and the card's font, Ubuntu Sans
# (fonts-ubuntu): without them that row fails, never passes; and for the two
# rows on perf's probe answers, jq: without it they fail, never pass. No
# network, no root.
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
for required_tool in gjs zsh find timeout dbus-run-session gdbus script; do
  command -v "$required_tool" >/dev/null || fatal "$required_tool is required"
done
# Every fixture this run writes lives here, from the placement rows on; removed on exit.
WIRING_TMP="$(mktemp -d)" || fatal "mktemp -d failed"
trap 'rm -rf "$WIRING_TMP"' EXIT

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
for glue_file in extension.js indicator.js card.js cockpitTooltip.js cockpitCards.js cockpitLayer.js; do
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

# list_files_under <directory> <array name> <find test>...: fills the named
# array with every path find lists under the directory with those tests, and
# returns non-zero when find does. find exits non-zero when it cannot read a
# directory, and a file it never listed is a file no scan read, so a scan fails
# then rather than passing over it; find's own message is left on stderr,
# naming the directory. The listing goes through a file: a process
# substitution would lose find's status.
list_files_under() {
  local search_dir="$1" listing_path
  local -n listed_paths="$2"
  shift 2
  listed_paths=()
  listing_path="$(mktemp -p "$WIRING_TMP" file-listing.XXXXXX)" || return 2
  if ! find "$search_dir" "$@" -print0 >"$listing_path"; then
    rm -f "$listing_path"
    return 1
  fi
  # listed_paths is a nameref: filling it fills the caller's array, which ShellCheck reads as never used.
  # shellcheck disable=SC2034
  mapfile -d '' listed_paths <"$listing_path"
  rm -f "$listing_path"
  return 0
}
# list_shell_side_javascript <extension dir> <array name>: fills the named
# array with every .js file under the extension directory outside the top-level
# service/, and returns non-zero when the tree cannot be listed
# (list_files_under).
list_shell_side_javascript() {
  local extension_dir="$1" javascript_path
  local -n shell_side_paths="$2"
  local -a javascript_paths=()
  shell_side_paths=()
  list_files_under "$extension_dir" javascript_paths -type f -name '*.js' || return
  for javascript_path in "${javascript_paths[@]}"; do
    [[ "$javascript_path" == "$extension_dir/service/"* ]] || shell_side_paths+=("$javascript_path")
  done
  return 0
}
# shell_side_files_matching <extension dir> <how>: one line per shell-side .js
# file (list_shell_side_javascript) whose text matches: with "literal:<text>"
# when it contains the text, with "pattern:<ERE>" when the regular expression
# matches it (newlines included, so a call may span lines). One line per such
# file that cannot be read (an unread file is not a clean one), and a line when
# the tree cannot be listed or holds no shell-side JavaScript.
shell_side_files_matching() {
  local extension_dir="$1" match_rule="$2" extension_file_path relative_path extension_file_text
  local -a extension_file_paths=()
  if ! list_shell_side_javascript "$extension_dir" extension_file_paths; then
    printf 'cannot list the JavaScript under %s\n' "$extension_dir"
    return
  fi
  if (( ${#extension_file_paths[@]} == 0 )); then
    printf 'found no shell-side JavaScript under %s\n' "$extension_dir"
    return
  fi
  for extension_file_path in "${extension_file_paths[@]}"; do
    relative_path="${extension_file_path#"$extension_dir"/}"
    if [[ ! -r "$extension_file_path" ]] || ! extension_file_text="$(<"$extension_file_path")"; then
      printf 'cannot read %s\n' "$relative_path"
    elif [[ "$match_rule" == literal:* && "$extension_file_text" == *"${match_rule#literal:}"* ]]; then
      printf '%s\n' "$relative_path"
    elif [[ "$match_rule" == pattern:* && "$extension_file_text" =~ ${match_rule#pattern:} ]]; then
      printf '%s\n' "$relative_path"
    fi
  done
}

# lib/, pulseClient.js, serviceLink.js, cockpitClient.js, displayConfig.js and
# graph.js run under plain gjs in the JS rows above, which only works while they
# import nothing from the Shell. A listed file that is missing fails the row: an
# absent file contains nothing, which is not a pass.
PURE_MODULE_PATHS=("$EXT_DIR/pulseClient.js" "$EXT_DIR/serviceLink.js" "$EXT_DIR/cockpitClient.js"
  "$EXT_DIR/displayConfig.js" "$EXT_DIR/graph.js")
row_name="lib/, pulseClient.js, serviceLink.js, cockpitClient.js, displayConfig.js and graph.js"
row_name+=" import nothing from resource:///"
if ! list_files_under "$EXT_DIR/lib" LIB_MODULE_PATHS -type f -name '*.js'; then
  bad "$row_name — cannot list the JavaScript under $EXT_DIR/lib"
elif (( ${#LIB_MODULE_PATHS[@]} == 0 )); then
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
# synchronous IO (file or D-Bus), anywhere in it. service/ is the sampler
# service, its own process outside the shell, so it may read files
# synchronously; it still starts no subprocess. Each Gio call is matched with
# its "(" so its _async form (enumerate_children_async( and so on) does not
# match, and _sync( and Sync( catch every synchronous D-Bus call (call_sync,
# new_sync, bus_get_sync, a proxy wrapper's GetStateSync) without catching an
# _async or Async one.
SUBPROCESS_CALL_PATTERN='Gio.Subprocess|GLib.spawn|Util.spawn|util_spawn'
SYNCHRONOUS_IO_CALL_PATTERN='load_contents\(|file_get_contents|enumerate_children\(|query_info\(|read_bytes\(|load_bytes\('
SYNCHRONOUS_IO_CALL_PATTERN+='|replace_contents\(|next_file\(|next_files\(|query_exists\(|query_file_type\(|GLib\.file_test'
SYNCHRONOUS_IO_CALL_PATTERN+='|read_all\(|GLib\.Dir\.open|\.read\(null\)|\.close\(null\)|_sync\('
# A GJS proxy wrapper (Gio.DBusProxy.makeProxyWrapper) gives each method an XxxSync( besides XxxRemote( and
# XxxAsync(; the capital S keeps Async( out.
SYNCHRONOUS_IO_CALL_PATTERN+='|Sync\('
BLOCKING_CALL_PATTERN="$SUBPROCESS_CALL_PATTERN|$SYNCHRONOUS_IO_CALL_PATTERN"
# blocking_calls_in <extension dir>: one line, "<path>: <call>", for each file
# making a call its place forbids: a subprocess anywhere, synchronous IO
# anywhere but the top-level service/. A tree that cannot be listed
# (list_files_under), or holds no files, is a line too.
blocking_calls_in() {
  local extension_dir="$1" extension_file_path forbidden_call_pattern
  local -a extension_file_paths=()
  if ! list_files_under "$extension_dir" extension_file_paths -type f; then
    printf 'cannot list the files under %s\n' "$extension_dir"
    return 1
  fi
  if (( ${#extension_file_paths[@]} == 0 )); then
    printf 'found no files under %s\n' "$extension_dir"
    return 0
  fi
  for extension_file_path in "${extension_file_paths[@]}"; do
    forbidden_call_pattern="$BLOCKING_CALL_PATTERN"
    [[ "$extension_file_path" == "$extension_dir/service/"* ]] && forbidden_call_pattern="$SUBPROCESS_CALL_PATTERN"
    if [[ "$(<"$extension_file_path")" =~ $forbidden_call_pattern ]]; then
      printf '%s: %s\n' "${extension_file_path#"$extension_dir"/}" "${BASH_REMATCH[0]}"
    fi
  done
  return 0
}
# The pattern itself: every forbidden call (a subprocess, synchronous IO) must
# match, and no asynchronous call, IO or D-Bus, that the shell side makes.
FORBIDDEN_CALLS=('Gio.Subprocess.new(' 'GLib.spawn_command_line_async(' 'Util.spawn([' 'file.load_contents(null)'
  'GLib.file_get_contents(path)' 'file.enumerate_children(attributes, flags, null)' 'file.query_info(attributes, flags, null)'
  'stream.read_bytes(4096, null)' 'file.load_bytes(null)' 'file.replace_contents(bytes, null, false, 0, null)'
  'enumerator.next_file(null)' 'enumerator.next_files(64, null)' 'file.query_exists(null)'
  'file.query_file_type(flags, null)' 'GLib.file_test(path, GLib.FileTest.EXISTS)' 'stream.read_all(buffer, null)'
  'GLib.Dir.open(path, 0)' 'file.read(null)' 'stream.close(null)' 'Shell.util_spawn_async(workingDirectory, argv, envp, flags)'
  'connection.call_sync(busName, objectPath, interfaceName, methodName, null, null, flags, timeoutMs, null)'
  'Gio.DBusProxy.new_sync(connection, flags, null, busName, objectPath, interfaceName, null)' 'proxy.GetStateSync()')
ASYNCHRONOUS_CALLS=('file.load_contents_async(null)' 'file.enumerate_children_async(attributes, flags, priority, null)'
  'file.query_info_async(attributes, flags, priority, null)' 'stream.read_bytes_async(4096, priority, null)'
  'file.load_bytes_async(null)' 'file.replace_contents_async(bytes, null, false, 0, null)'
  'enumerator.next_files_async(64, priority, null)' 'file.read_async(priority, null)' 'stream.close_async(priority, null)'
  'enumerator.close_async(priority, null)' 'Gio.bus_get(busType, cancellable, callback)' 'Gio.bus_get_finish(result)'
  'Gio.DBusProxy.new(connection, flags, null, busName, objectPath, interfaceName, cancellable, callback)'
  'Gio.DBusProxy.new_finish(result)' 'proxy.call(methodName, null, flags, timeoutMs, cancellable, callback)'
  'proxy.call_finish(result)' 'connection.call(busName, objectPath, interfaceName, methodName, parameters, replyType, flags, timeoutMs, cancellable, callback)'
  'connection.call_finish(result)' 'proxy.GetStateAsync()' 'proxy.GetStateRemote(callback)')
unmatched_forbidden_calls=()
for io_call in "${FORBIDDEN_CALLS[@]}"; do
  [[ "$io_call" =~ $BLOCKING_CALL_PATTERN ]] || unmatched_forbidden_calls+=("$io_call")
done
matched_asynchronous_calls=()
for io_call in "${ASYNCHRONOUS_CALLS[@]}"; do
  [[ "$io_call" =~ $BLOCKING_CALL_PATTERN ]] && matched_asynchronous_calls+=("$io_call")
done
check "the blocking-call pattern matches every forbidden call (subprocess, synchronous IO) and no asynchronous IO or D-Bus call" \
  "missed=[${unmatched_forbidden_calls[*]}] async-matched=[${matched_asynchronous_calls[*]}]" "missed=[] async-matched=[]"
row_name="no file in the extension spawns a process, and none outside service/ does synchronous IO (file or D-Bus)"
# The scan's own exit status is read too: a scan that could not run prints
# nothing, which is not a pass.
blocking_calls="$(blocking_calls_in "$EXT_DIR")"
blocking_scan_status=$?
if (( blocking_scan_status == 0 )) && [[ -z "$blocking_calls" ]]; then
  ok "$row_name"
else
  bad "$row_name — scan exit $blocking_scan_status: $(tr '\n' ' ' <<<"$blocking_calls")"
fi
# The scan's scoping, on a fixture tree: service/ (and only the top-level one)
# may read files synchronously, nothing may spawn, and an asynchronous D-Bus call
# is fine anywhere.
PLACEMENT_FIXTURE_DIR="$WIRING_TMP/placement-fixture"
mkdir -p "$PLACEMENT_FIXTURE_DIR/service" "$PLACEMENT_FIXTURE_DIR/lib/service" \
  || fatal "cannot create the placement fixture under $PLACEMENT_FIXTURE_DIR"
printf '%s\n' 'const [, contents] = file.load_contents(null);' >"$PLACEMENT_FIXTURE_DIR/service/reads.js"
printf '%s\n' 'const process = Gio.Subprocess.new(argv, flags);' >"$PLACEMENT_FIXTURE_DIR/service/spawns.js"
printf '%s\n' 'const [, contents] = file.load_contents(null);' >"$PLACEMENT_FIXTURE_DIR/lib/service/reads.js"
printf '%s\n' 'const fileInfo = enumerator.next_file(null);' >"$PLACEMENT_FIXTURE_DIR/lib/lists.js"
printf '%s\n' 'proxy.call(methodName, null, flags, timeoutMs, cancellable, callback);' >"$PLACEMENT_FIXTURE_DIR/client.js"
check "the placement scan lets the top-level service/ read files but not spawn, and nothing else read (a fixture tree)" \
  "$(blocking_calls_in "$PLACEMENT_FIXTURE_DIR" | LC_ALL=C sort | tr '\n' ' ')" \
  "lib/lists.js: next_file( lib/service/reads.js: load_contents( service/spawns.js: Gio.Subprocess "

# A shell-side module that imports anything from service/ would load the
# sampler, with its synchronous reads, into gnome-shell. GNOME loads only
# extension.js and what it imports, so service/ stays out of the shell only
# while nothing outside service/ imports it, statically or dynamically: a
# from, import or import( whose quoted specifier starts with service/ or
# reaches it after a slash. Comments that name service/ files are not imports.
SERVICE_IMPORT_PATTERN="(from|import)[[:space:]]*[(]?[[:space:]]*['\"]([^'\"]*/)?service/"
# service_imports_in <extension dir>: one line per .js file outside the
# top-level service/ that imports from service/ (shell_side_files_matching). A
# tree that cannot be listed or holds no shell-side JavaScript, and a file that
# cannot be read, are a line too.
service_imports_in() { shell_side_files_matching "$1" "pattern:$SERVICE_IMPORT_PATTERN"; }
row_name="no file outside service/ imports service/, so gnome-shell never loads the sampler"
service_importers="$(service_imports_in "$EXT_DIR")"
service_import_scan_status=$?
if (( service_import_scan_status == 0 )) && [[ -z "$service_importers" ]]; then
  ok "$row_name"
else
  bad "$row_name — scan exit $service_import_scan_status: $(tr '\n' ' ' <<<"$service_importers")"
fi
SERVICE_IMPORT_FIXTURE_DIR="$WIRING_TMP/service-import-fixture"
mkdir -p "$SERVICE_IMPORT_FIXTURE_DIR/service" "$SERVICE_IMPORT_FIXTURE_DIR/lib" \
  || fatal "cannot create the service-import fixture under $SERVICE_IMPORT_FIXTURE_DIR"
printf '%s\n' "import {ServiceSampler} from './service/sampler.js';" >"$SERVICE_IMPORT_FIXTURE_DIR/extension.js"
printf '%s\n' "const serviceModule = await import('../service/main.js');" >"$SERVICE_IMPORT_FIXTURE_DIR/lib/loader.js"
printf '%s\n' '// The service (service/sampler.js) publishes these.' "import {PROTOCOL_VERSION} from './lib/protocol.js';" \
  >"$SERVICE_IMPORT_FIXTURE_DIR/card.js"
# service/ may import itself, even by a path that leaves and re-enters it.
printf '%s\n' "import {ServiceSampler} from './sampler.js';" "import {RingBuffer} from '../lib/history.js';" \
  "import {ResourcePulseDBusService} from '../service/dbusService.js';" >"$SERVICE_IMPORT_FIXTURE_DIR/service/main.js"
check "the service/ import scan finds a static and a dynamic import of service/, and neither a comment nor service/'s own" \
  "$(service_imports_in "$SERVICE_IMPORT_FIXTURE_DIR" | LC_ALL=C sort | tr '\n' ' ')" "extension.js lib/loader.js "

# A D-Bus proxy object owned only by JavaScript, with handlers connected, is
# referenced by GDBus on every incoming signal, and that makes GJS schedule a
# forced full garbage collection on the compositor thread 10 s later: once per
# Sample. So no shell-side file (every .js outside the top-level service/) may
# name one, not even in a comment: the client follows the service through
# serviceLink.js's name watch and subscription. The service, a process of its
# own, may.
DBUS_PROXY_LITERAL='Gio.DBusProxy'
# dbus_proxy_mentions_in <extension dir>: one line per shell-side .js file that
# contains DBUS_PROXY_LITERAL, comments included (shell_side_files_matching).
dbus_proxy_mentions_in() { shell_side_files_matching "$1" "literal:$DBUS_PROXY_LITERAL"; }
row_name="no shell-side file names Gio.DBusProxy"
dbus_proxy_mentions="$(dbus_proxy_mentions_in "$EXT_DIR")"
if [[ -z "$dbus_proxy_mentions" ]]; then
  ok "$row_name"
else
  bad "$row_name — $(tr '\n' ' ' <<<"$dbus_proxy_mentions")"
fi
# The planted twin, on a copy of the extension: a call at the top level and a
# comment in lib/ are found; service/, whose sources use proxies, is not.
DBUS_PROXY_FIXTURE_DIR="$WIRING_TMP/dbus-proxy-fixture"
cp -R "$EXT_DIR" "$DBUS_PROXY_FIXTURE_DIR" || fatal "cannot copy $EXT_DIR to $DBUS_PROXY_FIXTURE_DIR"
printf '%s\n' 'Gio.DBusProxy.new(connection, flags, null, busName, objectPath, interfaceName, cancellable, callback);' \
  >>"$DBUS_PROXY_FIXTURE_DIR/pulseClient.js"
printf '%s\n' '// Built with Gio.DBusProxy.new(connection, ...), once.' >>"$DBUS_PROXY_FIXTURE_DIR/lib/wiring.js"
check "a planted Gio.DBusProxy.new( in a shell-side copy is found" \
  "$(dbus_proxy_mentions_in "$DBUS_PROXY_FIXTURE_DIR" | LC_ALL=C sort | tr '\n' ' ')" "lib/wiring.js pulseClient.js "

# While Samples flow they are the shell's tick, and a timer at the same rate
# costs about as much as handling one (the card's old cover re-check timer did,
# measured), so nothing shell-side may wake on the sampler's interval: no
# shell-side file adds a timeout whose arguments name SAMPLE_INTERVAL_SECONDS,
# whether a GLib timeout of any kind, the client's injectable addSeconds or
# addMilliseconds, or setTimeout or setInterval. The call is matched up to the
# end of its statement, across lines, comments included. service/, the sampler,
# ticks at that interval by design.
SAMPLE_INTERVAL_TIMEOUT_PATTERN='(timeout_add[a-z_]*|addSeconds|addMilliseconds|setTimeout|setInterval)\([^;]*'
SAMPLE_INTERVAL_TIMEOUT_PATTERN+='SAMPLE_INTERVAL_SECONDS'
# sample_interval_timeouts_in <extension dir>: one line per shell-side .js file
# that adds such a timeout (shell_side_files_matching).
sample_interval_timeouts_in() { shell_side_files_matching "$1" "pattern:$SAMPLE_INTERVAL_TIMEOUT_PATTERN"; }
row_name="no shell-side file adds a timeout of SAMPLE_INTERVAL_SECONDS"
sample_interval_timeouts="$(sample_interval_timeouts_in "$EXT_DIR")"
if [[ -z "$sample_interval_timeouts" ]]; then
  ok "$row_name"
else
  bad "$row_name — $(tr '\n' ' ' <<<"$sample_interval_timeouts")"
fi
# The planted twin, on a copy of the extension: the cover re-check timer this
# row replaced, put back in extension.js with its interval on the next line, and
# a watchdog-style addMilliseconds in lib/, are found; the same timeout in
# service/ is not.
SAMPLE_TIMEOUT_FIXTURE_DIR="$WIRING_TMP/sample-timeout-fixture"
cp -R "$EXT_DIR" "$SAMPLE_TIMEOUT_FIXTURE_DIR" || fatal "cannot copy $EXT_DIR to $SAMPLE_TIMEOUT_FIXTURE_DIR"
printf '%s\n' 'this._coverRecheckSourceId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT,' \
  '    SAMPLE_INTERVAL_SECONDS, () => this._onCoverRecheckTimeout());' >>"$SAMPLE_TIMEOUT_FIXTURE_DIR/extension.js"
printf '%s\n' 'this._timeouts.addMilliseconds(SAMPLE_INTERVAL_SECONDS * 1000, () => this._onTick());' \
  >>"$SAMPLE_TIMEOUT_FIXTURE_DIR/lib/wiring.js"
printf '%s\n' 'GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, SAMPLE_INTERVAL_SECONDS, () => this._onTimeout());' \
  >>"$SAMPLE_TIMEOUT_FIXTURE_DIR/service/sampler.js"
check "no shell-side file adds a timeout of SAMPLE_INTERVAL_SECONDS: a planted one is found" \
  "$(sample_interval_timeouts_in "$SAMPLE_TIMEOUT_FIXTURE_DIR" | LC_ALL=C sort | tr '\n' ' ')" \
  "extension.js lib/wiring.js "

# A repeating timer in the shell while Samples flow is a budget no measurement
# here catches: perf's count budgets do not move for a timer that draws nothing,
# and the row above knows a timer only by the sampler's interval. So every
# timeout the shell side adds is pinned, by file and count: the one line of
# cockpitClient.js's injectable GLIB_TIMEOUTS seam (1), whose one-shot timeouts
# are the steps of its StartUnit chain (the wait for the service to appear, and
# the retry delay), each returning SOURCE_REMOVE; cockpitTooltip.js's show delay
# (1), one-shot; cockpitLayer.js's fallback that draws a Changed the next Sample
# did not (1), one-shot, of COCKPIT_CHANGED_APPLY_FALLBACK_SECONDS, armed only
# while a Changed waits and removed by each Sample; extension.js's cover fallback
# (1), indicator.js's hover label delay (1), and the two lines of
# pulseClient.js's injectable GLIB_TIMEOUTS seam (2). One more anywhere, a new
# file included, fails the row until it is counted here. GJS's own setTimeout(
# and setInterval( are timeouts too and are counted with GLib's two calls (the
# shell side uses neither today); a method whose name merely ends that way (a
# letter, digit, _ or . before "set") is not one. The
# call text is counted on code lines only: a line that starts as a comment (//,
# /* or a JSDoc *) is not a call.
SHELL_SIDE_GLIB_TIMEOUT_CALL_PATTERN='GLib[.]timeout_add(_seconds)?[(]|(^|[^A-Za-z0-9_.])set(Timeout|Interval)[(]'
EXPECTED_SHELL_SIDE_GLIB_TIMEOUT_CALLS='cockpitClient.js:1 cockpitLayer.js:1 cockpitTooltip.js:1 extension.js:1 indicator.js:1 '
EXPECTED_SHELL_SIDE_GLIB_TIMEOUT_CALLS+='pulseClient.js:2 '
# glib_timeout_calls_in <extension dir>: one line, "<file>:<count>", per
# shell-side .js file (list_shell_side_javascript) whose code lines add GLib
# timeouts; one per such file awk cannot read, and one when the tree cannot be
# listed or holds no shell-side JavaScript.
glib_timeout_calls_in() {
  local extension_dir="$1" extension_file_path relative_path timeout_call_count
  local -a extension_file_paths=()
  if ! list_shell_side_javascript "$extension_dir" extension_file_paths; then
    printf 'cannot list the JavaScript under %s\n' "$extension_dir"
    return
  fi
  if (( ${#extension_file_paths[@]} == 0 )); then
    printf 'found no shell-side JavaScript under %s\n' "$extension_dir"
    return
  fi
  for extension_file_path in "${extension_file_paths[@]}"; do
    relative_path="${extension_file_path#"$extension_dir"/}"
    if ! timeout_call_count="$(awk -v call_pattern="$SHELL_SIDE_GLIB_TIMEOUT_CALL_PATTERN" '
        /^[ \t]*(\/\/|\/\*|\*)/ { next }
        { code_line = $0; call_count += gsub(call_pattern, "", code_line) }
        END { print call_count + 0 }' "$extension_file_path")"; then
      printf 'cannot read %s\n' "$relative_path"
    elif (( timeout_call_count > 0 )); then
      printf '%s:%s\n' "$relative_path" "$timeout_call_count"
    fi
  done
}
check "the shell side adds a timeout in the places the table knows, and nowhere else" \
  "$(glib_timeout_calls_in "$EXT_DIR" | LC_ALL=C sort | tr '\n' ' ')" "$EXPECTED_SHELL_SIDE_GLIB_TIMEOUT_CALLS"
# The planted twin, on a copy of the extension: one GLib.timeout_add( and one
# setInterval( in card.js, which adds none today, are the one difference the row
# sees; a row blind to either form would count 1 there, not 2. A method named
# resetTimeout( planted beside them is not a timeout and is not counted.
GLIB_TIMEOUT_FIXTURE_DIR="$WIRING_TMP/glib-timeout-fixture"
cp -R "$EXT_DIR" "$GLIB_TIMEOUT_FIXTURE_DIR" || fatal "cannot copy $EXT_DIR to $GLIB_TIMEOUT_FIXTURE_DIR"
printf '%s\n' 'this._pollSourceId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 2000, () => GLib.SOURCE_CONTINUE);' \
  '    setInterval(() => this._poll(), 2000);' 'this.resetTimeout(5);' >>"$GLIB_TIMEOUT_FIXTURE_DIR/card.js"
check "the shell side adds a timeout in the places the table knows, and nowhere else: planted ones in card.js are found" \
  "$(glib_timeout_calls_in "$GLIB_TIMEOUT_FIXTURE_DIR" | LC_ALL=C sort | tr '\n' ' ')" \
  "card.js:2 $EXPECTED_SHELL_SIDE_GLIB_TIMEOUT_CALLS"

# The compositor repaints every actor of the card's layer on each frame a window draws over it, because actors there
# are not culled, so the card draws through an offscreen texture (one cached rectangle for those frames): _init sets
# the redirect to ALWAYS. card.js imports the Shell and cannot run here, so the row reads its text. The call is
# counted inside _init's body only: a call elsewhere in the file does not redirect a card at construction.
OFFSCREEN_REDIRECT_CALL='this.set_offscreen_redirect(Clutter.OffscreenRedirect.ALWAYS);'
# offscreen_redirect_calls_in_init <card.js>: how many times _init's body (from its signature to the closing brace
# at the method's indentation) holds a line that IS OFFSCREEN_REDIRECT_CALL: nothing but whitespace before it and
# nothing after it, so a call in a // or /* */ comment is not counted. awk does it all, so a zero is an answer and
# an unreadable file is awk's failure status (returned), not an empty count; "no _init body" when there is none.
offscreen_redirect_calls_in_init() {
  awk -v call="$OFFSCREEN_REDIRECT_CALL" '
    /^    _init\(client\) \{$/ { in_init = 1 }
    in_init { line = $0; sub(/^[ \t]+/, "", line); if (line == call) found++ }
    in_init && /^    \}$/ { exit }
    END { if (in_init) print found + 0; else print "no _init body" }' "$1"
}
real_card_redirect_calls="$(offscreen_redirect_calls_in_init "$EXT_DIR/card.js")"
check "card.js sets the offscreen redirect to ALWAYS in _init" "$real_card_redirect_calls" 1
# The planted twin, on copies of card.js: the call deleted, the call moved out of _init to the end of the file, and
# the call commented out with // in place, each count 0 (neither a call outside _init nor a commented one may satisfy
# the row).
OFFSCREEN_FIXTURE_DIR="$WIRING_TMP/offscreen-fixture"
mkdir "$OFFSCREEN_FIXTURE_DIR" || fatal "cannot create $OFFSCREEN_FIXTURE_DIR"
awk -v call="$OFFSCREEN_REDIRECT_CALL" 'index($0, call) == 0' "$EXT_DIR/card.js" \
  >"$OFFSCREEN_FIXTURE_DIR/deleted.js" || fatal "cannot write $OFFSCREEN_FIXTURE_DIR/deleted.js"
awk -v call="$OFFSCREEN_REDIRECT_CALL" 'index($0, call) { print "        // " call; next } { print }' \
  "$EXT_DIR/card.js" >"$OFFSCREEN_FIXTURE_DIR/commented.js" || fatal "cannot write $OFFSCREEN_FIXTURE_DIR/commented.js"
{ cat "$OFFSCREEN_FIXTURE_DIR/deleted.js"; printf '    %s\n' "$OFFSCREEN_REDIRECT_CALL"; } \
  >"$OFFSCREEN_FIXTURE_DIR/moved.js"
deleted_card_redirect_calls="$(offscreen_redirect_calls_in_init "$OFFSCREEN_FIXTURE_DIR/deleted.js")"
moved_card_redirect_calls="$(offscreen_redirect_calls_in_init "$OFFSCREEN_FIXTURE_DIR/moved.js")"
check "card.js sets the offscreen redirect to ALWAYS in _init: a deleted call and a moved one are not counted" \
  "$deleted_card_redirect_calls|$moved_card_redirect_calls" "0|0"
commented_card_redirect_calls="$(offscreen_redirect_calls_in_init "$OFFSCREEN_FIXTURE_DIR/commented.js")"
check "card.js sets the offscreen redirect to ALWAYS in _init: a commented-out call is not counted" \
  "$commented_card_redirect_calls" 0

# A JavaScript paint override runs in the compositor's paint path on every frame the actor draws, and GJS cannot
# do that cheaply: no shell-side file overrides the paint vfunc or its node variant. The scan matches the text
# anywhere, comments included, so no comment spells it either; the literal below also covers the _node variant.
PAINT_OVERRIDE_LITERAL='vfunc_paint'
# paint_overrides_in <extension dir>: one line per shell-side .js file that contains PAINT_OVERRIDE_LITERAL
# (shell_side_files_matching).
paint_overrides_in() { shell_side_files_matching "$1" "literal:$PAINT_OVERRIDE_LITERAL"; }
row_name="no shell-side file overrides vfunc_paint or vfunc_paint_node"
paint_overrides="$(paint_overrides_in "$EXT_DIR")"
if [[ -z "$paint_overrides" ]]; then
  ok "$row_name"
else
  bad "$row_name — $(tr '\n' ' ' <<<"$paint_overrides")"
fi
# The planted twin, on a copy of the extension: an override in the card and a node override in lib/ are found;
# service/ is not scanned.
PAINT_OVERRIDE_FIXTURE_DIR="$WIRING_TMP/paint-override-fixture"
cp -R "$EXT_DIR" "$PAINT_OVERRIDE_FIXTURE_DIR" || fatal "cannot copy $EXT_DIR to $PAINT_OVERRIDE_FIXTURE_DIR"
printf '%s\n' '    vfunc_paint(paintContext) { super.vfunc_paint(paintContext); }' \
  >>"$PAINT_OVERRIDE_FIXTURE_DIR/card.js"
printf '%s\n' '    vfunc_paint_node() {}' >>"$PAINT_OVERRIDE_FIXTURE_DIR/lib/wiring.js"
printf '%s\n' '    vfunc_paint(paintContext) {}' >>"$PAINT_OVERRIDE_FIXTURE_DIR/service/sampler.js"
check "no shell-side file overrides vfunc_paint or vfunc_paint_node: a planted override is found" \
  "$(paint_overrides_in "$PAINT_OVERRIDE_FIXTURE_DIR" | LC_ALL=C sort | tr '\n' ' ')" "card.js lib/wiring.js "

# extension.js imports the Shell, so its teardown cannot run here. lib/teardown.js
# (runEveryStep, whose rows are in lifecycle.test.js) guards each step; these
# rows read extension.js for the order of its destroy steps, the card first
# because a card left behind would show frozen numbers as live.
EXTENSION_JS="$EXT_DIR/extension.js"
teardown_destroy_order="$(grep -E "run: \(\) => (card|indicator|client)\?\.destroy\(\)" "$EXTENSION_JS" 2>/dev/null \
  | sed -E 's/.*=> ([a-z]+)\?\.destroy.*/\1/' | tr '\n' ' ')"
check "extension.js tears down in guarded steps (runEveryStep), destroying the card, then the indicator, then the client" \
  "$teardown_destroy_order|$(grep -c -F 'runEveryStep([' "$EXTENSION_JS" 2>/dev/null)" "card indicator client |1"
# The client's own failures (a StartUnit refused, a call timed out) heal by
# themselves, so they stay warnings; the extension's teardown failures are
# errors. Each kind has one limiter that outlives every enable.
check "extension.js hands every client one rate-limited logger that writes warnings and spans enables" \
  "$(grep -c -F 'errorLog: this._clientLog' "$EXTENSION_JS" 2>/dev/null):$(grep -c -E 'this\._clientLog = new RateLimitedLogger\(\{nowUsec, write: line => console\.warn\(line\)\}\)' "$EXTENSION_JS" 2>/dev/null)" "1:1"
# A client lives for one enable (every unlock and blank makes a new one), so the
# last good clock label is kept in the extension, as the loggers are: set once,
# saved from the client before teardown destroys it and never reset there, and
# seeded into each new client. After an unlock with the service down the
# surfaces then say "no data since HH:MM", not a bare "no data". The bodies are
# read from each method's declaration line to the closing brace at its indent.
method_body_lines() { sed -n "/^    $1 {\$/,/^    }\$/p" "$EXTENSION_JS" 2>/dev/null | sed 's/^[[:space:]]*//'; }
LAST_GOOD_LABEL_SAVE_STATEMENT='this._lastGoodClockLabel = client?.lastGoodClockLabel ?? this._lastGoodClockLabel;'
CLIENT_DESTROY_STEP="{name: 'destroy the client', run: () => client?.destroy()},"
teardown_lines="$(method_body_lines '_tearDown()')"
label_save_line_number="$(grep -n -x -F "$LAST_GOOD_LABEL_SAVE_STATEMENT" <<<"$teardown_lines" | head -n 1 | cut -d: -f1)"
client_destroy_line_number="$(grep -n -x -F "$CLIENT_DESTROY_STEP" <<<"$teardown_lines" | head -n 1 | cut -d: -f1)"
label_saved_before_destroy="no"
if [[ -n "$label_save_line_number" && -n "$client_destroy_line_number" ]] \
  && (( label_save_line_number < client_destroy_line_number )); then
  label_saved_before_destroy="yes"
fi
check "extension.js keeps the last good clock label across enables: set once, saved from the client before teardown destroys it, never reset there, and seeded into each new client" \
  "set=$(method_body_lines 'constructor(metadata)' | grep -c -x -F 'this._lastGoodClockLabel = null;') saved-before-destroy=$label_saved_before_destroy reset-in-teardown=$(grep -c -E '^this\._lastGoodClockLabel = null;' <<<"$teardown_lines") seeded=$(method_body_lines 'enable()' | grep -c -F 'lastGoodClockLabel: this._lastGoodClockLabel')" \
  "set=1 saved-before-destroy=yes reset-in-teardown=0 seeded=1"
check "indicator.js re-places a shown hover label when its width or the display scale changes" \
  "$(grep -c -E "'notify::(width|scale-factor)'" "$EXT_DIR/indicator.js" 2>/dev/null)" 2
# notify::width is emitted during allocation, and moving an actor then makes
# Clutter warn "Can't update stage views actor ... needs an allocation" (seen in
# the nested shell for the card and the hover label). Both placements on a
# width change go through a BEFORE_REDRAW later instead, which teardown removes:
# the extension in a guarded step of _tearDown (the step itself is counted,
# not just the remove() it calls), the indicator inside _onDestroy. extension.js
# has a second later, the coalesced cover check, pinned by its own row in
# gnome-shell/tests/visibility.test.js. cockpitLayer.js queues no later and
# follows no width: the extension places it, in its own later (0/0/0).
deferred_placement_summary=""
for glue_file in extension.js indicator.js cockpitLayer.js; do
  glue_path="$EXT_DIR/$glue_file"
  deferred_placement_summary+="$glue_file:$(grep -c -F 'Meta.LaterType.BEFORE_REDRAW' "$glue_path" 2>/dev/null)"
  deferred_placement_summary+="/$(grep -c -F 'get_laters().remove(' "$glue_path" 2>/dev/null)"
  deferred_placement_summary+="/$(grep -c -E "connect(Object)?\('notify::width', \(\) => this\._queue" "$glue_path" 2>/dev/null) "
done
teardown_cancels_placement="$(grep -c -F "{name: 'cancel the pending card placement', run: () => this._cancelCardPlacement()}" "$EXTENSION_JS" 2>/dev/null)"
on_destroy_removes_later="$(sed -n '/^    _onDestroy() {/,/^    }/p' "$EXT_DIR/indicator.js" 2>/dev/null | grep -c -F 'get_laters().remove(')"
check "a width change moves the card and the hover label in a BEFORE_REDRAW later, never during allocation" \
  "$deferred_placement_summary| teardown-step=$teardown_cancels_placement on-destroy=$on_destroy_removes_later" \
  "extension.js:2/2/1 indicator.js:1/1/1 cockpitLayer.js:0/0/0 | teardown-step=1 on-destroy=1"

# The top bar asks for a frame only when a graph's columns change by a whole
# device pixel, and only while the indicator is mapped. The arithmetic is
# lib/topbarColumns.js, with its rows in gnome-shell/tests/topbarColumns.test.js;
# the glue runs only inside gnome-shell, so these rows read it. A drawing area's
# queue_repaint() is neither cheap nor lazy, so indicator.js calls it in exactly
# one place, behind the decision that compares columns: one call more, anywhere,
# redraws identical pixels on every tick, as the top bar did before.
REPAINT_CALL_NEEDLE='queue_repaint('
REPAINT_DECISION_DECLARATION='_isRepaintNeeded(topbarGraph)'
# indicator_method_lines <indicator.js path> <declaration>: the method's body,
# from its declaration line to the closing brace at its indent, each line
# trimmed. A missing file or method is no lines, so every count below is 0.
indicator_method_lines() { sed -n "/^    $2 {\$/,/^    }\$/p" "$1" 2>/dev/null | sed 's/^[[:space:]]*//'; }
# count_occurrences <text> <needle>: how many times the text contains the
# needle. Counted in the text, not by grep -c, which counts lines: two on one
# line are two.
count_occurrences() {
  local text="$1" needle="$2" text_without_needle
  text_without_needle="${text//"$needle"/}"
  printf '%s' "$(( (${#text} - ${#text_without_needle}) / ${#needle} ))"
}
# repaint_call_summary <indicator.js path>: how many times the file says
# queue_repaint(, the trimmed line before each one, and how many lines of the
# decision method compare columns (lib/topbarColumns.js isGraphRepaintNeeded).
# An unreadable file is a line of its own.
repaint_call_summary() {
  local indicator_path="$1" indicator_text guard_lines comparison_count
  if [[ ! -r "$indicator_path" ]] || ! indicator_text="$(<"$indicator_path")"; then
    printf 'cannot read %s' "$indicator_path"
    return
  fi
  guard_lines="$(awk -v needle="$REPAINT_CALL_NEEDLE" '
    index($0, needle) { sub(/^[ \t]+/, "", previous_line); guards = guards separator previous_line; separator = "|" }
    { previous_line = $0 }
    END { print guards }' "$indicator_path")"
  comparison_count="$(indicator_method_lines "$indicator_path" "$REPAINT_DECISION_DECLARATION" \
    | grep -c -F 'isGraphRepaintNeeded(')"
  printf 'calls=%s guards=[%s] compares=%s' "$(count_occurrences "$indicator_text" "$REPAINT_CALL_NEEDLE")" \
    "$guard_lines" "$comparison_count"
}
check "indicator.js calls queue_repaint( in one place, behind the column comparison" \
  "$(repaint_call_summary "$EXT_DIR/indicator.js")" \
  "calls=1 guards=[if (this._isRepaintNeeded(topbarGraph))] compares=1"
# The planted twin, on a copy of the extension: the unguarded call the history
# listener made before, put back, is found.
TOPBAR_REPAINT_FIXTURE_DIR="$WIRING_TMP/topbar-repaint-fixture"
cp -R "$EXT_DIR" "$TOPBAR_REPAINT_FIXTURE_DIR" || fatal "cannot copy $EXT_DIR to $TOPBAR_REPAINT_FIXTURE_DIR"
awk '{ print } $0 == "    _onHistoriesChanged() {" { print "        this._cpuGraph.drawingArea.queue_repaint();" }' \
  "$EXT_DIR/indicator.js" >"$TOPBAR_REPAINT_FIXTURE_DIR/indicator.js" \
  || fatal "cannot plant an unguarded repaint in $TOPBAR_REPAINT_FIXTURE_DIR/indicator.js"
check "a planted unguarded queue_repaint( in a copy of indicator.js is found" \
  "$(repaint_call_summary "$TOPBAR_REPAINT_FIXTURE_DIR/indicator.js")" \
  "calls=2 guards=[if (this._isRepaintNeeded(topbarGraph))|_onHistoriesChanged() {] compares=1"
# A repaint skipped while the indicator is unmapped is owed: the decision
# answers false then and leaves the columns last drawn as they are, and
# notify::mapped runs the same comparison again, so a graph whose columns
# changed while it was hidden draws once when it is shown.
MAPPED_HANDLER_CONNECT="this.connect('notify::mapped', () => this._onMappedChanged());"
# mapped_repaint_summary <indicator.js path>: how many lines connect
# notify::mapped to _onMappedChanged, how many lines of that handler ask the
# changed graphs to repaint, and how many lines of the decision skip while
# unmapped.
mapped_repaint_summary() {
  local indicator_path="$1"
  printf 'connected=%s draws-there=%s skips-while-unmapped=%s' \
    "$(grep -c -F "$MAPPED_HANDLER_CONNECT" "$indicator_path" 2>/dev/null)" \
    "$(indicator_method_lines "$indicator_path" '_onMappedChanged()' \
      | grep -c -x -F 'this._queueRepaintsOfChangedGraphs();')" \
    "$(indicator_method_lines "$indicator_path" "$REPAINT_DECISION_DECLARATION" \
      | grep -c -x -F 'if (this._client === null || !this.mapped)')"
}
check "indicator.js connects notify::mapped and draws the owed repaint there" \
  "$(mapped_repaint_summary "$EXT_DIR/indicator.js")" "connected=1 draws-there=1 skips-while-unmapped=1"
# The planted twin, on a copy: a notify::mapped handler that only follows the
# hover label, as it did before, is found.
TOPBAR_MAPPED_FIXTURE_DIR="$WIRING_TMP/topbar-mapped-fixture"
cp -R "$EXT_DIR" "$TOPBAR_MAPPED_FIXTURE_DIR" || fatal "cannot copy $EXT_DIR to $TOPBAR_MAPPED_FIXTURE_DIR"
awk '
  $0 == "    _onMappedChanged() {" { is_inside_handler = 1 }
  is_inside_handler && $0 == "        this._queueRepaintsOfChangedGraphs();" { next }
  $0 == "    }" { is_inside_handler = 0 }
  { print }' "$EXT_DIR/indicator.js" >"$TOPBAR_MAPPED_FIXTURE_DIR/indicator.js" \
  || fatal "cannot plant a handler that does not draw in $TOPBAR_MAPPED_FIXTURE_DIR/indicator.js"
check "a copy of indicator.js whose notify::mapped handler does not draw is found" \
  "$(mapped_repaint_summary "$TOPBAR_MAPPED_FIXTURE_DIR/indicator.js")" \
  "connected=1 draws-there=0 skips-while-unmapped=1"
# St lets a drawing area report its surface size, and hand out its cairo
# context, only inside its repaint handler: anywhere else it logs a CRITICAL and
# the size reads 0, which made the column comparison see a change on every tick.
# So indicator.js reads each exactly once, in _paintGraph, and compares at the
# height its last paint recorded. Counted over the whole file, comments
# included, as the Gio.DBusProxy row does (indicator.js's comments never spell
# either call): a comment only adds to the counts, so it cannot hide a read
# outside the handler.
SURFACE_READ_NEEDLES=('get_surface_size(' 'get_context(')
PAINT_HANDLER_DECLARATION='_paintGraph(topbarGraph)'
# surface_reads_summary <indicator.js path>: for each needle, how many times the
# file says it and how many times _paintGraph's body does. An unreadable file is
# a line of its own.
surface_reads_summary() {
  local indicator_path="$1" indicator_text paint_handler_text needle summary="" separator=""
  if [[ ! -r "$indicator_path" ]] || ! indicator_text="$(<"$indicator_path")"; then
    printf 'cannot read %s' "$indicator_path"
    return
  fi
  paint_handler_text="$(indicator_method_lines "$indicator_path" "$PAINT_HANDLER_DECLARATION")"
  for needle in "${SURFACE_READ_NEEDLES[@]}"; do
    summary+="$separator$needle file=$(count_occurrences "$indicator_text" "$needle")"
    summary+=" repaint=$(count_occurrences "$paint_handler_text" "$needle")"
    separator="; "
  done
  printf '%s' "$summary"
}
check "indicator.js reads the drawing area's surface size and context only inside the repaint handler" \
  "$(surface_reads_summary "$EXT_DIR/indicator.js")" \
  "get_surface_size( file=1 repaint=1; get_context( file=1 repaint=1"
# The planted twin, on a copy: the surface read the decision made at tick time,
# put back, is found.
TOPBAR_SURFACE_FIXTURE_DIR="$WIRING_TMP/topbar-surface-fixture"
cp -R "$EXT_DIR" "$TOPBAR_SURFACE_FIXTURE_DIR" || fatal "cannot copy $EXT_DIR to $TOPBAR_SURFACE_FIXTURE_DIR"
awk '{ print } $0 == "    _isRepaintNeeded(topbarGraph) {" {
  print "        const [, heightPx] = topbarGraph.drawingArea.get_surface_size();" }' \
  "$EXT_DIR/indicator.js" >"$TOPBAR_SURFACE_FIXTURE_DIR/indicator.js" \
  || fatal "cannot plant a surface read in $TOPBAR_SURFACE_FIXTURE_DIR/indicator.js"
check "a planted get_surface_size( outside the repaint handler in a copy of indicator.js is found" \
  "$(surface_reads_summary "$TOPBAR_SURFACE_FIXTURE_DIR/indicator.js")" \
  "get_surface_size( file=2 repaint=1; get_context( file=1 repaint=1"

# The desktop card's cover check runs on the Samples and the window signals,
# with no timer while Samples flow. extension.js's one timer is the fallback
# that checks a covered card while the service is silent (when it runs is
# lib/visibility.js coverFallbackTimerChange, its wiring pinned in
# gnome-shell/tests/visibility.test.js): every timeout the file adds, of any
# kind, is counted in the text, and the one there is must be of
# COVER_FALLBACK_INTERVAL_SECONDS.
FALLBACK_TIMEOUT_CALL='GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, COVER_FALLBACK_INTERVAL_SECONDS,'
# extension_timeouts_summary <extension.js path>: how many times the file says
# timeout_add (any kind), setTimeout( or setInterval(, and how many times it
# adds the fallback timeout. An unreadable file is a line of its own.
extension_timeouts_summary() {
  local extension_path="$1" extension_text timeout_count
  if [[ ! -r "$extension_path" ]] || ! extension_text="$(<"$extension_path")"; then
    printf 'cannot read %s' "$extension_path"
    return
  fi
  timeout_count=$(( $(count_occurrences "$extension_text" 'timeout_add') \
    + $(count_occurrences "$extension_text" 'setTimeout(') + $(count_occurrences "$extension_text" 'setInterval(') ))
  printf 'timeouts=%s fallback=%s' "$timeout_count" "$(count_occurrences "$extension_text" "$FALLBACK_TIMEOUT_CALL")"
}
check "extension.js's one timeout_add_seconds uses COVER_FALLBACK_INTERVAL_SECONDS" \
  "$(extension_timeouts_summary "$EXTENSION_JS")" "timeouts=1 fallback=1"
# Teardown removes what the covered check adds while the card is covered, each
# in a guarded step of its own (runEveryStep): the fallback timeout, and every
# covering window's position-changed, size-changed, workspace-changed and
# unmanaged.
FALLBACK_TEARDOWN_STEP="{name: 'remove the cover fallback timeout', run: () => this._removeCoverFallbackTimer()},"
COVERING_WINDOWS_TEARDOWN_STEP="{name: 'disconnect from the covering windows', run: () => "
COVERING_WINDOWS_TEARDOWN_STEP+="this._disconnectCoveringWindows()},"
fallback_teardown_steps="$(grep -c -x -F "$FALLBACK_TEARDOWN_STEP" <<<"$teardown_lines")"
covering_windows_teardown_steps="$(grep -c -x -F "$COVERING_WINDOWS_TEARDOWN_STEP" <<<"$teardown_lines")"
check "_tearDown removes the fallback timeout and disconnects the covering windows" \
  "fallback=$fallback_teardown_steps covering-windows=$covering_windows_teardown_steps" "fallback=1 covering-windows=1"

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
RESOURCE_PULSE_BUS_NAME='io.github.quantivly.dotfiles.ResourcePulse1'
RESOURCE_PULSE_OBJECT_PATH='/io/github/quantivly/dotfiles/ResourcePulse1'
SHELL_SCHEMA="org.gnome.shell"
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
DING_UUID="ding@rastersoft.com"
# The local layer for the gdisable_extension rows: the helper called twice in one run,
# so one run also proves the second call is a no-op.
printf 'gdisable_extension %s\ngdisable_extension %s\n' "$DING_UUID" "$DING_UUID" >"$WIRING_TMP/local-overrides-disable"
APPLY_OVERRIDES_FILE="$WIRING_TMP/local-overrides"

STUB_CALLS_LOG="$WIRING_TMP/stub-calls"
STUB_BUS_SEEN_LOG="$WIRING_TMP/stub-bus-seen"

# Reset the stub to a state, run the apply script, leave its stderr+stdout in
# APPLY_OUTPUT and its exit status in APPLY_EXIT.
#   $1 enabled-extensions  $2 disabled-extensions  $3 disable-user-extensions
#   $4 schemas listed by the stub (newline separated)
#   $5 allow-extension-installation (optional; unset, the stub answers true)
# The local layer it runs is $APPLY_OVERRIDES_FILE (genable_extension unless a block switches it).
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
    GNOME_LOCAL_OVERRIDES="$APPLY_OVERRIDES_FILE" bash "$APPLY_SCRIPT" 2>&1)"
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

printf '\ngdisable_extension (stateful gsettings stub)\n'
APPLY_OVERRIDES_FILE="$WIRING_TMP/local-overrides-disable"
run_apply_against_stub '@as []' '@as []' false "$SHELL_SCHEMA"
check "gdisable_extension: an empty disabled list becomes just the uuid, once, though the helper ran twice" \
  "$(stub_value disabled-extensions)" "['$DING_UUID']"
check "gdisable_extension: the second call prints no second disabled-extensions line" \
  "$(grep -c -F 'disabled-extensions →' <<<"$APPLY_OUTPUT")" 1
run_apply_against_stub '@as []' "['$DING_UUID']" false "$SHELL_SCHEMA"
check "gdisable_extension: an already-disabled uuid leaves the list unchanged" "$(stub_value disabled-extensions)" "['$DING_UUID']"
check "gdisable_extension: no change prints no disabled-extensions line, and says so at INFO" \
  "arrow=$(grep -c -F 'disabled-extensions →' <<<"$APPLY_OUTPUT") info=$(grep -c -F "$DING_UUID is already in disabled-extensions" <<<"$APPLY_OUTPUT")" "arrow=0 info=2"
run_apply_against_stub '@as []' "['x@y']" false "$SHELL_SCHEMA"
check "gdisable_extension: appends and keeps the existing disabled entry first" "$(stub_value disabled-extensions)" "['x@y', '$DING_UUID']"
run_apply_against_stub "['a@b', '$DING_UUID', 'c@d']" '@as []' false "$SHELL_SCHEMA"
check "gdisable_extension: removes the uuid from enabled-extensions and keeps the others in order" \
  "$(stub_value enabled-extensions)" "['a@b', 'c@d']"
check "gdisable_extension: an enabled uuid is also appended to disabled-extensions, which wins in GNOME 50" \
  "$(stub_value disabled-extensions)" "['$DING_UUID']"
run_apply_against_stub "['a@b']" '@as []' false "$SHELL_SCHEMA"
check "gdisable_extension: an uuid absent from enabled-extensions leaves that list alone, with no write" \
  "list=$(stub_value enabled-extensions) writes=$(grep -c -F 'enabled-extensions →' <<<"$APPLY_OUTPUT")" "list=['a@b'] writes=0"
run_apply_against_stub "['$DING_UUID']" '@as []' false ""
check "gdisable_extension: an absent org.gnome.shell schema warns" "$(grep -c -F "Schema '$SHELL_SCHEMA' not found" <<<"$APPLY_OUTPUT")" 2
check "gdisable_extension: an absent schema writes nothing" \
  "enabled=$(stub_value enabled-extensions) disabled=$(stub_value disabled-extensions)" "enabled=['$DING_UUID'] disabled=@as []"
check "gdisable_extension: the apply script still exits 0 without the schema" "$APPLY_EXIT" 0
APPLY_OVERRIDES_FILE="$WIRING_TMP/local-overrides"

printf '\nresource-pulse-module-closure.sh (which modules each side runs: ruling R23)\n'
# The two stale-code checks (gnome-status's ⚠ lines and the refresh step's
# try-restart) follow each side's static import closure: the shell side is
# extension.js and what it imports, the service side service/main.js and what
# it imports. The helper is pure bash; these rows run it on the real tree and on
# fixtures, and a shape it does not understand must be exit 2 with nothing on
# stdout, never a partial closure that would skip a check.
CLOSURE_SCRIPT="$DOTFILES/scripts/resource-pulse-module-closure.sh"
# sorted_closure <extension dir> <entry module>: the closure, sorted, on one line,
# then "exit=<n>".
sorted_closure() {
  local closure_output closure_exit
  closure_output="$(bash "$CLOSURE_SCRIPT" "$1" "$2" 2>/dev/null)"
  closure_exit=$?
  printf '%sexit=%s' "$(LC_ALL=C sort <<<"$closure_output" | tr '\n' ' ')" "$closure_exit"
}
# Read from the import lines of today's tree, by hand: the shell side's
# twenty-three modules and the service side's seventeen, seven of them
# (constants, errorLog, history, jsonFields, pressure, protocol, teardown) on
# both. The shell side reaches cockpitCards.js and its three lib modules
# (cockpitFormat, cockpitProtocol, cockpitStaleness) through indicator.js's
# Resources helpers.
EXPECTED_SHELL_CLOSURE='card.js cockpitCards.js extension.js graph.js indicator.js lib/cardRepaint.js '
EXPECTED_SHELL_CLOSURE+='lib/cockpitFormat.js lib/cockpitProtocol.js lib/cockpitStaleness.js lib/constants.js lib/errorLog.js '
EXPECTED_SHELL_CLOSURE+='lib/format.js lib/history.js lib/jsonFields.js lib/layout.js lib/pressure.js lib/protocol.js '
EXPECTED_SHELL_CLOSURE+='lib/teardown.js lib/topbarColumns.js lib/visibility.js lib/wiring.js '
EXPECTED_SHELL_CLOSURE+='pulseClient.js serviceLink.js '
EXPECTED_SERVICE_CLOSURE='lib/apps.js lib/cadence.js lib/cgroupParsers.js lib/constants.js lib/cpu.js lib/errorLog.js lib/history.js lib/jsonFields.js lib/memory.js lib/pressure.js lib/procParsers.js lib/protocol.js lib/teardown.js service/dbusService.js service/fileIo.js service/main.js service/sampler.js '
check "closure: on the real tree, extension.js and service/main.js each give exactly the modules they import, directly or not" \
  "shell=[$(sorted_closure "$EXT_DIR" extension.js)] service=[$(sorted_closure "$EXT_DIR" service/main.js)]" \
  "shell=[${EXPECTED_SHELL_CLOSURE}exit=0] service=[${EXPECTED_SERVICE_CLOSURE}exit=0]"
# cockpit.service's closure decides its own restarts: it holds the file helpers
# both services share (service/fileIo.js), never the sampler's modules, so a
# sampler-only change never restarts the cockpit (ruling R13).
cockpit_closure="$(sorted_closure "$EXT_DIR" service/cockpit.js)"
cockpit_closure_summary="exit=${cockpit_closure##*exit=}"
for closure_probe in service/cockpit.js service/fileIo.js service/main.js service/sampler.js service/dbusService.js; do
  if [[ " $cockpit_closure" == *" $closure_probe "* ]]; then
    cockpit_closure_summary+=" +$closure_probe"
  else
    cockpit_closure_summary+=" -$closure_probe"
  fi
done
check "closure: on the real tree, service/cockpit.js holds itself and the shared service/fileIo.js, never the sampler's service/main.js, sampler.js or dbusService.js" \
  "$cockpit_closure_summary" \
  "exit=0 +service/cockpit.js +service/fileIo.js -service/main.js -service/sampler.js -service/dbusService.js"

# A fixture of every shape it follows, and of what it must not: a JSDoc type
# and a comment naming import('./x.js') are no imports; a multi-line import
# (with a comment inside), a side-effect import, a re-export, and a dynamic
# import of a string literal are; import.meta is not; gi:// and resource:///
# name no file of the extension.
CLOSURE_FIXTURE_DIR="$WIRING_TMP/closure-fixture"
mkdir -p "$CLOSURE_FIXTURE_DIR/lib" || fatal "cannot create $CLOSURE_FIXTURE_DIR"
printf '%s\n' \
  "// A comment naming import('./commented.js') is no import." \
  '/**' \
  " * @param {import('./jsdoc-only.js').Thing} thing - A JSDoc type, no import." \
  ' */' \
  "import Gio from 'gi://Gio';" \
  "import * as Main from 'resource:///org/gnome/shell/ui/main.js';" \
  'import {' \
  '    first,' \
  '    // A comment inside the list.' \
  '    second,' \
  "} from './lib/multi-line.js';" \
  "import './side-effect.js';" \
  'export {third} from "./re-exported.js";' \
  "const lazyModule = await import('./lazy.js');" \
  'const moduleUrl = import.meta.url;' >"$CLOSURE_FIXTURE_DIR/entry.js"
printf '%s\n' "import {shared} from '../shared.js';" >"$CLOSURE_FIXTURE_DIR/lib/multi-line.js"
printf '%s\n' "import {shared} from './shared.js';" >"$CLOSURE_FIXTURE_DIR/re-exported.js"
for closure_fixture_module in side-effect.js lazy.js shared.js jsdoc-only.js commented.js; do
  : >"$CLOSURE_FIXTURE_DIR/$closure_fixture_module"
done
check "closure: follows multi-line, side-effect, re-exported and literal dynamic imports; never a JSDoc type, a comment, import.meta or gi://" \
  "$(sorted_closure "$CLOSURE_FIXTURE_DIR" entry.js)" \
  "entry.js lazy.js lib/multi-line.js re-exported.js shared.js side-effect.js exit=0"

# An import written after block comments that close on the same line is a real
# import, and the closure must name its file (a change to it restarts the
# service that loads it); a line that is all comment, closed or not, hides what
# it says, and so does a block comment left open on its line.
CLOSURE_BLOCK_FIXTURE_DIR="$WIRING_TMP/closure-block-fixture"
rm -rf "$CLOSURE_BLOCK_FIXTURE_DIR"
mkdir -p "$CLOSURE_BLOCK_FIXTURE_DIR" || fatal "cannot create $CLOSURE_BLOCK_FIXTURE_DIR"
printf '%s\n' \
  "/* note */ import {after_one} from './after-one.js';" \
  "/* first */ /* second */ import {after_two} from './after-two.js';" \
  "/* import {all_comment} from './all-comment.js'; */" \
  "/* a */ // import {x} from './line-hidden.js';" >"$CLOSURE_BLOCK_FIXTURE_DIR/entry.js"
for closure_block_module in after-one.js after-two.js all-comment.js line-hidden.js; do
  : >"$CLOSURE_BLOCK_FIXTURE_DIR/$closure_block_module"
done
check "closure: an import after a block comment closed on its own line is followed" \
  "$(sorted_closure "$CLOSURE_BLOCK_FIXTURE_DIR" entry.js)" \
  "after-one.js after-two.js entry.js exit=0"
CLOSURE_OPEN_COMMENT_FIXTURE_DIR="$WIRING_TMP/closure-open-comment-fixture"
rm -rf "$CLOSURE_OPEN_COMMENT_FIXTURE_DIR"
mkdir -p "$CLOSURE_OPEN_COMMENT_FIXTURE_DIR" || fatal "cannot create $CLOSURE_OPEN_COMMENT_FIXTURE_DIR"
printf '%s\n' \
  "/* import {hidden} from './hidden.js'; this comment closes on a later line" \
  ' */' \
  "/* closed */ /* import {also_hidden} from './also-hidden.js'; still open" \
  ' */' >"$CLOSURE_OPEN_COMMENT_FIXTURE_DIR/entry.js"
for closure_open_comment_module in hidden.js also-hidden.js; do
  : >"$CLOSURE_OPEN_COMMENT_FIXTURE_DIR/$closure_open_comment_module"
done
check "closure: a block comment that does not close on its line still hides the line" \
  "$(sorted_closure "$CLOSURE_OPEN_COMMENT_FIXTURE_DIR" entry.js)" \
  "entry.js exit=0"

# Each shape it cannot follow: exit 2, nothing on stdout, and a line on stderr
# naming the module and its line.
# closure_refusal <module source>: "<exit>/<stdout lines>/<stderr names entry.js:line>".
closure_refusal() {
  local refusal_dir="$WIRING_TMP/closure-refusal" refusal_stdout refusal_stderr_path refusal_exit
  rm -rf "$refusal_dir"
  mkdir -p "$refusal_dir" || fatal "cannot create $refusal_dir"
  printf '%s\n' "$1" >"$refusal_dir/entry.js"
  : >"$refusal_dir/present.js"
  refusal_stderr_path="$refusal_dir/stderr"
  refusal_stdout="$(bash "$CLOSURE_SCRIPT" "$refusal_dir" entry.js 2>"$refusal_stderr_path")"
  refusal_exit=$?
  printf '%s/%s/%s' "$refusal_exit" "$(grep -c . <<<"$refusal_stdout")" \
    "$(grep -c -E '^resource-pulse-module-closure: entry\.js:[0-9]+: ' "$refusal_stderr_path")"
}
closure_refusals="dynamic=$(closure_refusal 'const loaded = await import(modulePath);')"
closure_refusals+=" unterminated=$(closure_refusal "import {present} from './present.js'")"
closure_refusals+=" indented=$(closure_refusal "    import {present} from './present.js';")"
closure_refusals+=" missing=$(closure_refusal "import {missing} from './missing.js';")"
# '../present.js' climbs out of the extension directory, though present.js exists
# inside it: a resolver that let .. pass the top would find it and say exit 0.
closure_refusals+=" outside=$(closure_refusal "import {present} from '../present.js';")"
check "closure: a dynamic import of a computed specifier, an import with no ;, one not starting its line, and one naming no file in the extension are each exit 2 with nothing on stdout" \
  "$closure_refusals" "dynamic=2/0/1 unterminated=2/0/1 indented=2/0/1 missing=2/0/1 outside=2/0/1"

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
  # XDG_CONFIG_HOME pinned empty, as in gnome_status_run below.
  # shellcheck disable=SC2016  # Expanded by zsh.
  status_output="$(env "${LIVE_SETTINGS_BARRIER[@]}" HOME="$GNOME_STATUS_HOME" XDG_CONFIG_HOME= \
    PATH="$GNOME_STATUS_STUB_BIN:$PATH" STUB_STATE="$STUB_STATE" STUB_CALLS="$STUB_CALLS_LOG" STUB_BUS_SEEN="$STUB_BUS_SEEN_LOG" \
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

# The service half of the block: systemctl, gdbus, pgrep and date are stubs too.
# Each answers from GNOME_STATUS_* variables and logs its call to
# GNOME_STATUS_CALLS; systemctl answers only the properties gnome-status reads
# (in systemd's own order, measured: LoadState, ActiveState, SubState,
# ConditionResult, whatever order -p names them) or hangs; gdbus answers
# GetState in its own text form, ('<json>',), or a given reply word for word;
# and date answers `+%s%N` with a fixed now (anything else goes to the real
# date). The cockpit unit answers from GNOME_STATUS_COCKPIT_* variables, and
# unset it is skipped, as for anyone without its config file: loaded, inactive,
# ConditionResult=no.
GNOME_STATUS_CALLS="$WIRING_TMP/gnome-status-calls"
REAL_DATE_PATH="$(command -v date)" || fatal "date is required"
GNOME_STATUS_SYSTEMCTL_STUB="$(cat <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"${GNOME_STATUS_CALLS:-/dev/null}"
[[ "${GNOME_STATUS_SYSTEMCTL_MODE:-}" != hang ]] || exec sleep 30
[[ "${GNOME_STATUS_SYSTEMCTL_MODE:-}" != hang-on-start-time || "$*" != *ActiveEnterTimestamp* ]] || exec sleep 30
# default_sub_state <ActiveState>: the SubState systemd shows beside it.
default_sub_state() {
  case "$1" in
    active) echo running ;;
    failed) echo failed ;;
    activating) echo start ;;
    *) echo dead ;;
  esac
}
# default_condition_result <ActiveState>: no while inactive (skipped, or never
# started: systemd's default before any check), yes once a start got past it.
default_condition_result() {
  if [[ "$1" == inactive ]]; then echo no; else echo yes; fi
}
active_state="${GNOME_STATUS_SERVICE_ACTIVE_STATE-inactive}"
cockpit_active_state="${GNOME_STATUS_COCKPIT_ACTIVE_STATE-inactive}"
case "$*" in
  "--user show -p LoadState -p ActiveState -p SubState resource-pulse.service")
    [[ -z "${GNOME_STATUS_NO_MANAGER:-}" ]] || { echo "Failed to connect to user scope bus" >&2; exit 1; }
    printf 'LoadState=%s\nActiveState=%s\nSubState=%s\n' "${GNOME_STATUS_SERVICE_LOAD_STATE:-loaded}" \
      "$active_state" "${GNOME_STATUS_SERVICE_SUB_STATE:-$(default_sub_state "$active_state")}" ;;
  "--user show -p ActiveEnterTimestamp --value --timestamp=unix resource-pulse.service")
    printf '%s\n' "${GNOME_STATUS_SERVICE_STARTED_AT-}" ;;
  "--user show -p FragmentPath --value resource-pulse.service")
    printf '%s\n' "${GNOME_STATUS_SERVICE_UNIT_FILE-}" ;;
  "--user show -p FragmentPath --value cockpit.service")
    printf '%s\n' "${GNOME_STATUS_COCKPIT_UNIT_FILE-}" ;;
  "--user show -p LoadState -p ActiveState -p SubState -p ConditionResult cockpit.service")
    [[ -z "${GNOME_STATUS_NO_MANAGER:-}" ]] || { echo "Failed to connect to user scope bus" >&2; exit 1; }
    printf 'LoadState=%s\nActiveState=%s\nSubState=%s\nConditionResult=%s\n' "${GNOME_STATUS_COCKPIT_LOAD_STATE:-loaded}" \
      "$cockpit_active_state" "${GNOME_STATUS_COCKPIT_SUB_STATE:-$(default_sub_state "$cockpit_active_state")}" \
      "${GNOME_STATUS_COCKPIT_CONDITION_RESULT:-$(default_condition_result "$cockpit_active_state")}" ;;
  "--user show -p ActiveEnterTimestamp --value --timestamp=unix cockpit.service")
    printf '%s\n' "${GNOME_STATUS_COCKPIT_STARTED_AT-}" ;;
  *) printf 'unexpected systemctl call: %s\n' "$*" >&2; exit 64 ;;
esac
STUB
)"
install_stub "$GNOME_STATUS_STUB_BIN" systemctl "$GNOME_STATUS_SYSTEMCTL_STUB"
GNOME_STATUS_GDBUS_STUB="$(cat <<'STUB'
#!/usr/bin/env bash
# answer: GetState's JSON as gdbus prints it when no string holds an apostrophe
# or a backslash; verbatim: the given reply as it is; hang: never answers;
# anything else: no owner. The sampler's call answers from GNOME_STATUS_GDBUS_MODE,
# GNOME_STATUS_STATE_JSON and GNOME_STATUS_GDBUS_REPLY, the cockpit's (its
# --dest) from the GNOME_STATUS_COCKPIT_ variables of the same names.
printf 'gdbus %s\n' "$*" >>"${GNOME_STATUS_CALLS:-/dev/null}"
gdbus_mode="${GNOME_STATUS_GDBUS_MODE:-fail}"
state_json="${GNOME_STATUS_STATE_JSON-}"
verbatim_reply="${GNOME_STATUS_GDBUS_REPLY-}"
if [[ " $* " == *" --dest io.github.quantivly.dotfiles.Cockpit1 "* ]]; then
  gdbus_mode="${GNOME_STATUS_COCKPIT_GDBUS_MODE:-fail}"
  state_json="${GNOME_STATUS_COCKPIT_STATE_JSON-}"
  verbatim_reply="${GNOME_STATUS_COCKPIT_GDBUS_REPLY-}"
fi
case "$gdbus_mode" in
  answer) printf "('%s',)\n" "$state_json" ;;
  verbatim) printf '%s\n' "$verbatim_reply" ;;
  hang) exec sleep 30 ;;
  *) echo "Error: GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown: The name is not activatable" >&2; exit 1 ;;
esac
STUB
)"
install_stub "$GNOME_STATUS_STUB_BIN" gdbus "$GNOME_STATUS_GDBUS_STUB"
GNOME_STATUS_PGREP_STUB="$(cat <<'STUB'
#!/usr/bin/env bash
printf 'pgrep %s\n' "$*" >>"${GNOME_STATUS_CALLS:-/dev/null}"
[[ -n "${GNOME_STATUS_SHELL_PID:-}" ]] || exit 1
printf '%s\n' "$GNOME_STATUS_SHELL_PID"
STUB
)"
install_stub "$GNOME_STATUS_STUB_BIN" pgrep "$GNOME_STATUS_PGREP_STUB"
# shellcheck disable=SC2016  # The stub's own source: its variables expand when it runs.
install_stub "$GNOME_STATUS_STUB_BIN" date "$(printf '#!/usr/bin/env bash\nif [[ "$1" == "+%%s%%N" && -n "${GNOME_STATUS_NOW_NSEC:-}" ]]; then\n  printf "%%s\\n" "$GNOME_STATUS_NOW_NSEC"\n  exit 0\nfi\nexec %q "$@"' "$REAL_DATE_PATH")"

# suite_started_at_epoch: this suite's own start, in whole seconds since the
# epoch (/proc/stat btime + stat field 22 / CLK_TCK), read here independently of
# gnome-status. The suite's own pid stands in for the desktop's gnome-shell.
suite_started_at_epoch() {
  local stat_line boot_epoch="" ticks_per_second key value _rest
  local -a stat_fields
  read -r stat_line <"/proc/$$/stat" || return 1
  read -r -a stat_fields <<<"${stat_line##*) }"
  while read -r key value _rest; do
    [[ "$key" == btime ]] && boot_epoch="$value"
  done </proc/stat
  ticks_per_second="$(getconf CLK_TCK)" || return 1
  [[ "$boot_epoch" =~ ^[0-9]+$ && "${stat_fields[19]:-}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$(( boot_epoch + stat_fields[19] / ticks_per_second ))"
}
SUITE_STARTED_AT_EPOCH="$(suite_started_at_epoch)" || fatal "cannot read this suite's own start time from /proc"
# Two seconds either side of it, so whole-second rounding can never decide a row.
BEFORE_SHELL_START_EPOCH=$((SUITE_STARTED_AT_EPOCH - 2))
AFTER_SHELL_START_EPOCH=$((SUITE_STARTED_AT_EPOCH + 2))
SERVICE_STARTED_LONG_AFTER_EPOCH=$((SUITE_STARTED_AT_EPOCH + 1000))

# A home where the extension is linked (a symlink, as ./install makes it) to a
# fixture extension whose files carry chosen mtimes.
GNOME_STATUS_LINKED_HOME="$WIRING_TMP/gnome-status-linked-home"
STATUS_EXTENSION_DIR="$WIRING_TMP/gnome-status-extension"
mkdir -p "$GNOME_STATUS_LINKED_HOME/.local/share/gnome-shell/extensions" \
  || fatal "cannot create gnome-status's linked fixture home"
ln -s "$STATUS_EXTENSION_DIR" "$GNOME_STATUS_LINKED_HOME/.local/share/gnome-shell/extensions/$EXTENSION_UUID" \
  || fatal "cannot link gnome-status's fixture extension"
# reset_status_extension <card.js mtime> <lib/format.js mtime> <service/main.js mtime>
# [<stylesheet.css mtime>] (epoch seconds); extension.js, metadata.json and the
# other lib/ modules are always older than the shell, and the stylesheet is too
# unless given. The modules import one another as the real ones do, in small:
# extension.js imports card.js (which imports lib/format.js), lib/visibility.js
# and lib/protocol.js; service/main.js imports lib/protocol.js, lib/cadence.js,
# service/sampler.js and service/fileIo.js; service/cockpit.js imports
# lib/cockpitProtocol.js and service/fileIo.js. So lib/format.js and
# lib/visibility.js are the shell's alone, lib/cadence.js and service/sampler.js
# the sampler's alone, lib/cockpitProtocol.js the cockpit's alone,
# lib/protocol.js the shell's and the sampler's, and service/fileIo.js both
# services'.
reset_status_extension() {
  local stylesheet_mtime="${4:-$BEFORE_SHELL_START_EPOCH}"
  rm -rf "$STATUS_EXTENSION_DIR"
  mkdir -p "$STATUS_EXTENSION_DIR/lib" "$STATUS_EXTENSION_DIR/service" || fatal "cannot create $STATUS_EXTENSION_DIR"
  printf '%s\n' "import {PulseCard} from './card.js';" "import {isCardCovered} from './lib/visibility.js';" \
    "import {PROTOCOL_VERSION} from './lib/protocol.js';" >"$STATUS_EXTENSION_DIR/extension.js"
  : >"$STATUS_EXTENSION_DIR/metadata.json"
  printf '%s\n' "import {cardText} from './lib/format.js';" >"$STATUS_EXTENSION_DIR/card.js"
  : >"$STATUS_EXTENSION_DIR/stylesheet.css"
  : >"$STATUS_EXTENSION_DIR/lib/format.js"
  : >"$STATUS_EXTENSION_DIR/lib/visibility.js"
  : >"$STATUS_EXTENSION_DIR/lib/protocol.js"
  : >"$STATUS_EXTENSION_DIR/lib/cadence.js"
  : >"$STATUS_EXTENSION_DIR/lib/cockpitProtocol.js"
  : >"$STATUS_EXTENSION_DIR/service/sampler.js"
  : >"$STATUS_EXTENSION_DIR/service/fileIo.js"
  printf '%s\n' "import {PROTOCOL_VERSION} from '../lib/protocol.js';" "import {decideAppScan} from '../lib/cadence.js';" \
    "import {Sampler} from './sampler.js';" "import {readTextFile} from './fileIo.js';" \
    >"$STATUS_EXTENSION_DIR/service/main.js"
  printf '%s\n' "import {COCKPIT_BUS_NAME} from '../lib/cockpitProtocol.js';" "import {readTextFile} from './fileIo.js';" \
    >"$STATUS_EXTENSION_DIR/service/cockpit.js"
  touch -d "@$BEFORE_SHELL_START_EPOCH" "$STATUS_EXTENSION_DIR/extension.js" "$STATUS_EXTENSION_DIR/metadata.json" \
    "$STATUS_EXTENSION_DIR/lib/visibility.js" "$STATUS_EXTENSION_DIR/lib/protocol.js" "$STATUS_EXTENSION_DIR/lib/cadence.js" \
    "$STATUS_EXTENSION_DIR/lib/cockpitProtocol.js" "$STATUS_EXTENSION_DIR/service/sampler.js" \
    "$STATUS_EXTENSION_DIR/service/fileIo.js" "$STATUS_EXTENSION_DIR/service/cockpit.js" \
    || fatal "touch -d failed"
  touch -d "@$1" "$STATUS_EXTENSION_DIR/card.js" || fatal "touch -d @$1 failed"
  touch -d "@$2" "$STATUS_EXTENSION_DIR/lib/format.js" || fatal "touch -d @$2 failed"
  touch -d "@$3" "$STATUS_EXTENSION_DIR/service/main.js" || fatal "touch -d @$3 failed"
  touch -d "@$stylesheet_mtime" "$STATUS_EXTENSION_DIR/stylesheet.css" || fatal "touch -d @$stylesheet_mtime failed"
}
reset_status_extension "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH"
# status_extension_with_change <module>: the fixture with every file older than
# the shell but that one module, which is newer.
status_extension_with_change() {
  reset_status_extension "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH"
  touch -d "@$AFTER_SHELL_START_EPOCH" "$STATUS_EXTENSION_DIR/$1" || fatal "touch -d @$AFTER_SHELL_START_EPOCH failed"
}

# A fixed now, and GetState answers whose latest sample is some seconds before it.
# Each carries a decoy of the same key inside the snapshot, after the top-level
# one: only the FIRST match is the service's.
STATUS_NOW_EPOCH=1794000100
STATUS_NOW_NSEC="${STATUS_NOW_EPOCH}000000000"
STATUS_USEC_PER_SECOND=1000000
STATUS_NOW_USEC=$((STATUS_NOW_EPOCH * STATUS_USEC_PER_SECOND))
DECOY_APP_NAME='decoy'
# state_json_usec_before <microseconds before now | null | absent> [app name]: a
# GetState JSON whose top CPU app has that name.
state_json_usec_before() {
  local latest_field app_name="${2:-$DECOY_APP_NAME}"
  case "$1" in
    absent) latest_field='' ;;
    null) latest_field='"latestSampledAtUsec":null,' ;;
    *) latest_field="\"latestSampledAtUsec\":$((STATUS_NOW_USEC - $1))," ;;
  esac
  printf '{"protocol":1,"serviceStartedAtUsec":1793990000000000,%s"sequence":42,"snapshot":{"apps":{"topCpu":{"name":"%s","latestSampledAtUsec":5}}},"histories":{"cpu":[],"memory":[]}}' \
    "$latest_field" "$app_name"
}
# state_json_sampled <seconds before now | null | absent>: the same, in whole seconds.
state_json_sampled() {
  case "$1" in
    absent | null) state_json_usec_before "$1" ;;
    *) state_json_usec_before "$(( $1 * STATUS_USEC_PER_SECOND ))" ;;
  esac
}
# The cockpit's GetState, shaped as gnome-shell/tests/cockpitProtocol.test.js's
# FULL_STATE (synthetic values), with each source stamped some whole seconds
# before the fixed now. Its sources sample every 5, 10 and 30 s, so each is
# stale past 15, 30 and 90 s (three intervals).
COCKPIT_FRESH_PUBLISH_AGE_SECONDS=4
# cockpit_usec_before <seconds>: the fixed now less that many seconds, in microseconds.
cockpit_usec_before() { printf '%s' "$(( STATUS_NOW_USEC - $1 * STATUS_USEC_PER_SECOND ))"; }
# cockpit_state_json <sessions age> <network age> <mounts age> [<configError as JSON> [<latest publish age>]]:
# ages in seconds before now; "absent" leaves that source out, as a service from
# before it would. configError defaults to null, the latest publish to 4 s ago.
cockpit_state_json() {
  local config_error_json="${4:-null}" publish_age_seconds="${5:-$COCKPIT_FRESH_PUBLISH_AGE_SECONDS}"
  local sessions_json network_json mounts_json source_list
  local -a source_entries=()
  if [[ "$1" != absent ]]; then
    sessions_json="\"sessions\":{\"sampledAtUsec\":$(cockpit_usec_before "$1"),\"intervalSeconds\":5,\"herdrRunning\":true,\"totalMemoryBytes\":4000000000,\"counts\":{\"working\":1,\"blocked\":1,\"idle\":0,\"done\":0,\"unknown\":0},\"rows\":[{\"id\":\"w1:p1\",\"name\":\"host-sync\",\"state\":\"working\",\"idleSeconds\":12,\"idleFromProcessAge\":false,\"memoryBytes\":3000000000,\"workspaceId\":\"w1\",\"paneId\":\"p1\",\"account\":\"quantivly-1\",\"contextPercent\":42}]}"
    source_entries+=("$sessions_json")
  fi
  if [[ "$2" != absent ]]; then
    network_json="\"network\":{\"sampledAtUsec\":$(cockpit_usec_before "$2"),\"intervalSeconds\":10,\"uplink\":{\"kind\":\"wired\",\"connectivity\":\"full\",\"wifiEnabled\":false},\"vpn\":{\"isUp\":true,\"interfaceName\":\"tun0\"},\"sshMasterCount\":2}"
    source_entries+=("$network_json")
  fi
  if [[ "$3" != absent ]]; then
    mounts_json="\"mounts\":{\"sampledAtUsec\":$(cockpit_usec_before "$3"),\"intervalSeconds\":30,\"rows\":[{\"mountPoint\":\"/media/user/BACKUP\",\"label\":\"BACKUP\",\"kind\":\"removable\",\"filesystemType\":\"ext4\",\"freeBytes\":500000000000,\"totalBytes\":2000000000000}]}"
    source_entries+=("$mounts_json")
  fi
  source_list="$(IFS=,; printf '%s' "${source_entries[*]}")"
  printf '{"protocol":1,"serviceStartedAtUsec":1793990000000000,"latestPublishedAtUsec":%s,"layout":{"monitor":{"vendor":"DEL","product":"DELL U2723QE"},"groups":[{"id":"machine","caption":"MACHINE","columns":2,"cards":["system","apps"]},{"id":"agents","caption":"AGENTS","columns":1,"cards":["sessions"]}]},"configError":%s,"sources":{%s}}' \
    "$(cockpit_usec_before "$publish_age_seconds")" "$config_error_json" "$source_list"
}
# DOTFILES_ROOT is this checkout, where gnome-status finds the closure helper.
# The cockpit unit keeps the stub's default (skipped) unless a row says otherwise.
GNOME_STATUS_STUB_DEFAULTS=("DOTFILES_ROOT=$DOTFILES" GNOME_STATUS_SHELL_STATE=ACTIVE GNOME_STATUS_SERVICE_ACTIVE_STATE=active
  GNOME_STATUS_GDBUS_MODE=answer "GNOME_STATUS_STATE_JSON=$(state_json_sampled 3)"
  GNOME_STATUS_COCKPIT_GDBUS_MODE=answer "GNOME_STATUS_COCKPIT_STATE_JSON=$(cockpit_state_json 3 3 2)"
  "GNOME_STATUS_NOW_NSEC=$STATUS_NOW_NSEC" "GNOME_STATUS_SERVICE_STARTED_AT=@$SERVICE_STARTED_LONG_AFTER_EPOCH"
  "GNOME_STATUS_SHELL_PID=$$")
# gnome_status_run <enabled-extensions> <allow-extension-installation> [NAME=value...]
# runs gnome-status against every stub, settings reset to those two, with the
# defaults above overridden by the assignments (HOME=... included). Leaves its
# output in GNOME_STATUS_OUTPUT; the stubs' calls are in GNOME_STATUS_CALLS.
# disabled-extensions is STATUS_DISABLED_EXTENSIONS when set (the stub's empty list otherwise).
gnome_status_run() {
  rm -rf "${STUB_STATE:?}"/*
  mkdir -p "$STUB_STATE/$SHELL_SCHEMA"
  printf '%s\n' "$1" >"$STUB_STATE/$SHELL_SCHEMA/enabled-extensions"
  printf '%s\n' "$2" >"$STUB_STATE/$SHELL_SCHEMA/allow-extension-installation"
  if [[ -n "${STATUS_DISABLED_EXTENSIONS:-}" ]]; then
    printf '%s\n' "$STATUS_DISABLED_EXTENSIONS" >"$STUB_STATE/$SHELL_SCHEMA/disabled-extensions"
  fi
  shift 2
  : >"$GNOME_STATUS_CALLS"
  # shellcheck disable=SC2016  # Expanded by zsh.
  # XDG_CONFIG_HOME is pinned empty, so the cockpit's config file is looked for
  # under the row's HOME, never the caller's config home; a row may set it.
  GNOME_STATUS_OUTPUT="$(env "${LIVE_SETTINGS_BARRIER[@]}" HOME="$GNOME_STATUS_HOME" XDG_CONFIG_HOME= \
    PATH="$GNOME_STATUS_STUB_BIN:$PATH" \
    STUB_STATE="$STUB_STATE" STUB_CALLS="$STUB_CALLS_LOG" STUB_BUS_SEEN="$STUB_BUS_SEEN_LOG" \
    GNOME_STATUS_CALLS="$GNOME_STATUS_CALLS" "${GNOME_STATUS_STUB_DEFAULTS[@]}" "$@" \
    zsh -c 'source "$1" && gnome-status' gnome-status "$DOTFILES/zsh/functions/system.sh" 2>&1)"
}
# The parts of GNOME_STATUS_OUTPUT the rows compare.
status_enabled_field() { sed -n 's/^Resource Pulse: linked=[a-z]* enabled=\(.*\) state=.*$/\1/p' <<<"$GNOME_STATUS_OUTPUT"; }
status_service_line() { sed -n 's/^  service: //p' <<<"$GNOME_STATUS_OUTPUT"; }
status_cockpit_line() { sed -n 's/^  cockpit: //p' <<<"$GNOME_STATUS_OUTPUT"; }
status_warnings_naming() { grep -F '  ⚠ ' <<<"$GNOME_STATUS_OUTPUT" | grep -c -F "$1"; }
status_warning_count() { grep -c -F '  ⚠ ' <<<"$GNOME_STATUS_OUTPUT"; }
status_gdbus_calls() { grep -c '^gdbus ' "$GNOME_STATUS_CALLS"; }
ASKED_FOR_SETTING="['$EXTENSION_UUID']"
NOT_ASKED_FOR_SETTING='@as []'

enabled_summary=""
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_SHELL_STATE=
enabled_summary+="unknown-to-shell=[$(status_enabled_field)]"
gnome_status_run "$ASKED_FOR_SETTING" true
enabled_summary+=" known=[$(status_enabled_field)]"
gnome_status_run "$ASKED_FOR_SETTING" false GNOME_STATUS_SHELL_STATE=
enabled_summary+=" kept-out=[$(status_enabled_field)]"
gnome_status_run "$NOT_ASKED_FOR_SETTING" true GNOME_STATUS_SHELL_STATE=
enabled_summary+=" not-asked-for=[$(status_enabled_field)]"
check "gnome-status: enabled= reads enabled-extensions, and says it starts at next login while the shell does not know it" \
  "$enabled_summary" "unknown-to-shell=[yes (starts at next login)] known=[yes] kept-out=[yes] not-asked-for=[no]"

gnome_status_run "$ASKED_FOR_SETTING" true
check "gnome-status: a running service shows its state, protocol and the age of its last sample (the top-level field), from GetState" \
  "line=[$(status_service_line)] warnings=$(status_warning_count) call=[$(grep '^gdbus ' "$GNOME_STATUS_CALLS")]" \
  "line=[active, protocol 1, last sample 3 s ago] warnings=0 call=[gdbus call --session --dest $RESOURCE_PULSE_BUS_NAME --object-path $RESOURCE_PULSE_OBJECT_PATH --method $RESOURCE_PULSE_BUS_NAME.GetState --timeout 2]"

stall_summary=""
# Ages in microseconds: 6.9 s is past the extension's 6 s though it shows as 6 s.
for sample_age_usec in 6000000 6900000 7000000 60000000 150000000; do
  gnome_status_run "$ASKED_FOR_SETTING" true "GNOME_STATUS_STATE_JSON=$(state_json_usec_before "$sample_age_usec")"
  stall_summary+="$sample_age_usec=[$(status_service_line)]/$(status_warnings_naming 'has not sampled') "
done
check "gnome-status: a last sample more than the extension's 6 s old is a ⚠ (6.9 s too), exactly 6 s is not; from 120 s it reads in minutes" \
  "$stall_summary" \
  "6000000=[active, protocol 1, last sample 6 s ago]/0 6900000=[active, protocol 1, last sample 6 s ago]/1 7000000=[active, protocol 1, last sample 7 s ago]/1 60000000=[active, protocol 1, last sample 60 s ago]/1 150000000=[active, protocol 1, last sample 2 min ago]/1 "

# A string holding an apostrophe makes gdbus print the reply in double quotes,
# escaping every " and \ inside it. The reply is printed by GLib itself
# (GLib.Variant.print, which gdbus uses), from a JSON whose app name holds ', "
# and \, with a sample ten minutes old.
APOSTROPHE_APP_NAME_JSON='Bob'"'"'s \"quoted\" \\ app'
TEN_MINUTES_USEC=600000000
# shellcheck disable=SC2016  # JavaScript source.
apostrophe_reply="$(gjs -c 'const {GLib} = imports.gi; print(new GLib.Variant("(s)", [ARGV[0]]).print(true));' \
  "$(state_json_usec_before "$TEN_MINUTES_USEC" "$APOSTROPHE_APP_NAME_JSON")")"
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_GDBUS_MODE=verbatim "GNOME_STATUS_GDBUS_REPLY=$apostrophe_reply"
check "gnome-status: a reply gdbus prints in double quotes (a string holding an apostrophe) still gives the protocol, the age and the stall ⚠" \
  "double-quoted=$([[ "$apostrophe_reply" == '("{\"protocol\":1,'* ]] && printf yes || printf no) line=[$(status_service_line)] stalled=$(status_warnings_naming 'has not sampled')" \
  "double-quoted=yes line=[active, protocol 1, last sample 10 min ago] stalled=1"

gnome_status_run "$ASKED_FOR_SETTING" true "GNOME_STATUS_STATE_JSON=$(state_json_sampled null)"
unsampled_summary="null=[$(status_service_line)]/$(status_warning_count)"
gnome_status_run "$ASKED_FOR_SETTING" true "GNOME_STATUS_STATE_JSON=$(state_json_sampled absent)"
unsampled_summary+=" absent=[$(status_service_line)]/$(status_warning_count)"
check "gnome-status: a null latestSampledAtUsec is no sample yet, and none at all (an older service) is not reported; neither warns" \
  "$unsampled_summary" \
  "null=[active, protocol 1, no sample yet]/0 absent=[active, protocol 1, last sample not reported (a service from before it was)]/0"

gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_GDBUS_MODE=fail
no_answer_summary="fail=[$(status_service_line)]/$(status_warnings_naming 'did not answer GetState')"
# gnome-status bounds the call at 3 s; the hanging stub would take 30.
HUNG_CALL_BOUND_SECONDS=10
hang_started_seconds=$SECONDS
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_GDBUS_MODE=hang
hang_elapsed_seconds=$((SECONDS - hang_started_seconds))
no_answer_summary+=" hang=[$(status_service_line)]/$(status_warnings_naming 'did not answer GetState')"
no_answer_summary+=" bounded=$( (( hang_elapsed_seconds < HUNG_CALL_BOUND_SECONDS )) && printf yes || printf 'no-%ss' "$hang_elapsed_seconds")"
check "gnome-status: an active service that does not answer, or hangs, is 'no answer' and a ⚠, and the call ends within its limit" \
  "$no_answer_summary" "fail=[active, no answer]/1 hang=[active, no answer]/1 bounded=yes"

not_running_summary=""
for state_and_setting in "failed:$ASKED_FOR_SETTING" "failed:$NOT_ASKED_FOR_SETTING" "inactive:$ASKED_FOR_SETTING" \
  "inactive:$NOT_ASKED_FOR_SETTING" "activating:$ASKED_FOR_SETTING"; do
  gnome_status_run "${state_and_setting#*:}" true "GNOME_STATUS_SERVICE_ACTIVE_STATE=${state_and_setting%%:*}"
  enabled_flag="$([[ "${state_and_setting#*:}" == "$ASKED_FOR_SETTING" ]] && printf enabled || printf off)"
  not_running_summary+="${state_and_setting%%:*}/$enabled_flag=[$(status_service_line)]/$(status_warning_count)/$(status_gdbus_calls) "
done
# Enabled, but before the first login after linking: the extension has not run yet.
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_SERVICE_ACTIVE_STATE=inactive GNOME_STATUS_SHELL_STATE=
not_running_summary+="inactive/before-login=[$(status_service_line)]/$(status_warning_count)/$(status_gdbus_calls) "
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_NO_MANAGER=1
not_running_summary+="no-manager=[$(status_service_line)]/$(status_warning_count)/$(status_gdbus_calls)"
check "gnome-status: a failed service always warns, one not running only while enabled and loaded, no manager never; none is asked GetState" \
  "$not_running_summary" \
  "failed/enabled=[failed (not running)]/1/0 failed/off=[failed (not running)]/1/0 inactive/enabled=[inactive (not running)]/1/0 inactive/off=[inactive (not running)]/0/0 activating/enabled=[activating (start)]/1/0 inactive/before-login=[inactive (not running)]/0/0 no-manager=[unknown (no systemd user manager answered)]/0/0"

# Each state gets its own remedy: a unit not found (merged without ./install)
# says to run ./install; one restarting after a crash says so; only a loaded,
# inactive unit suggests starting it.
status_remedies() {
  printf '[%s]/%s/start=%s/install=%s/restarting=%s/status=%s' "$(status_service_line)" "$(status_warning_count)" \
    "$(status_warnings_naming 'systemctl --user start')" "$(status_warnings_naming 'run ./install')" \
    "$(status_warnings_naming 'restarting after a failure')" "$(status_warnings_naming 'systemctl --user status')"
}
remedies_summary=""
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_SERVICE_LOAD_STATE=not-found GNOME_STATUS_SERVICE_ACTIVE_STATE=inactive
remedies_summary+="not-found/enabled=$(status_remedies) "
gnome_status_run "$NOT_ASKED_FOR_SETTING" true GNOME_STATUS_SERVICE_LOAD_STATE=not-found GNOME_STATUS_SERVICE_ACTIVE_STATE=inactive
remedies_summary+="not-found/off=$(status_remedies) "
gnome_status_run "$NOT_ASKED_FOR_SETTING" true GNOME_STATUS_SERVICE_ACTIVE_STATE=activating GNOME_STATUS_SERVICE_SUB_STATE=auto-restart
remedies_summary+="auto-restart/off=$(status_remedies) "
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_SERVICE_ACTIVE_STATE=activating
remedies_summary+="starting/enabled=$(status_remedies) "
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_SERVICE_ACTIVE_STATE=inactive
remedies_summary+="inactive/enabled=$(status_remedies) "
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_SERVICE_LOAD_STATE=bad-setting GNOME_STATUS_SERVICE_ACTIVE_STATE=inactive
remedies_summary+="bad-setting/enabled=$(status_remedies)"
check "gnome-status: a missing unit says run ./install, a crashed one that it is restarting, and only a loaded inactive one to start it" \
  "$remedies_summary" \
  "not-found/enabled=[not installed (LoadState=not-found)]/1/start=0/install=1/restarting=0/status=0 not-found/off=[not installed (LoadState=not-found)]/0/start=0/install=0/restarting=0/status=0 auto-restart/off=[activating (auto-restart: restarting after a failure)]/1/start=0/install=0/restarting=1/status=0 starting/enabled=[activating (start)]/1/start=0/install=0/restarting=0/status=0 inactive/enabled=[inactive (not running)]/1/start=1/install=0/restarting=0/status=0 bad-setting/enabled=[cannot load (LoadState=bad-setting)]/1/start=0/install=0/restarting=0/status=1"

hung_systemctl_started_seconds=$SECONDS
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_SYSTEMCTL_MODE=hang
hung_systemctl_elapsed_seconds=$((SECONDS - hung_systemctl_started_seconds))
hung_systemctl_summary="state-call=[$(status_service_line)]/$( (( hung_systemctl_elapsed_seconds < HUNG_CALL_BOUND_SECONDS )) && printf bounded || printf 'after-%ss' "$hung_systemctl_elapsed_seconds")"
# The start-time call (linked, so the data-side check runs) is bounded too.
hung_systemctl_started_seconds=$SECONDS
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME" GNOME_STATUS_SYSTEMCTL_MODE=hang-on-start-time
hung_systemctl_elapsed_seconds=$((SECONDS - hung_systemctl_started_seconds))
hung_systemctl_summary+=" start-time-call=[$(status_service_line)]/$( (( hung_systemctl_elapsed_seconds < HUNG_CALL_BOUND_SECONDS )) && printf bounded || printf 'after-%ss' "$hung_systemctl_elapsed_seconds")"
check "gnome-status: a systemctl that hangs is bounded like gdbus, in both of its calls" \
  "$hung_systemctl_summary" \
  "state-call=[unknown (no systemd user manager answered)]/bounded start-time-call=[active, protocol 1, last sample 3 s ago]/bounded"

# Asked for in enabled-extensions but also in disabled-extensions, which wins in
# GNOME 50: a load hint, like the other two, and the service is not blamed.
disabled_summary=""
STATUS_DISABLED_EXTENSIONS="$ASKED_FOR_SETTING" gnome_status_run "$ASKED_FOR_SETTING" true \
  GNOME_STATUS_SHELL_STATE=INACTIVE GNOME_STATUS_SERVICE_ACTIVE_STATE=inactive
disabled_summary+="known=[$(status_enabled_field)]/hint=$(grep -c -F '  disabled-extensions also lists it' <<<"$GNOME_STATUS_OUTPUT")/warnings=$(status_warning_count)"
STATUS_DISABLED_EXTENSIONS="$ASKED_FOR_SETTING" gnome_status_run "$ASKED_FOR_SETTING" true \
  GNOME_STATUS_SHELL_STATE= GNOME_STATUS_SERVICE_ACTIVE_STATE=inactive
disabled_summary+=" unknown-to-shell=[$(status_enabled_field)]/hint=$(grep -c -F '  disabled-extensions also lists it' <<<"$GNOME_STATUS_OUTPUT")/warnings=$(status_warning_count)"
check "gnome-status: an extension also in disabled-extensions gets a load hint, and the service is not blamed" \
  "$disabled_summary" "known=[yes]/hint=1/warnings=0 unknown-to-shell=[yes]/hint=1/warnings=0"

# The service side is service/main.js and what it imports (ruling R23): the
# shared lib/protocol.js and the service's own lib/cadence.js count, the shell's
# own lib/visibility.js and lib/format.js and the drawing code do not. Each
# changed module is counted by a needle naming it, so a ⚠ naming another fails.
older_code_summary=""
STATUS_SERVICE_STARTED_AT="GNOME_STATUS_SERVICE_STARTED_AT=@$SUITE_STARTED_AT_EPOCH"
for changed_module in service/main.js lib/cadence.js lib/protocol.js lib/visibility.js lib/format.js card.js; do
  status_extension_with_change "$changed_module"
  gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME" "$STATUS_SERVICE_STARTED_AT"
  older_code_summary+="$changed_module=$(status_warnings_naming "runs older code: $changed_module changed after it started")/$(status_warnings_naming 'runs older code') "
done
reset_status_extension "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH"
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME" "$STATUS_SERVICE_STARTED_AT"
older_code_summary+="unchanged=$(status_warnings_naming 'runs older code')"
check "gnome-status: a module service/main.js runs (itself, lib/cadence.js, or the shared lib/protocol.js) changed after the service started is a ⚠ that it runs older code; a shell-only module or drawing code is not" \
  "$older_code_summary" \
  "service/main.js=1/1 lib/cadence.js=1/1 lib/protocol.js=1/1 lib/visibility.js=0/0 lib/format.js=0/0 card.js=0/0 unchanged=0"

older_copy_summary=""
OLDER_COPY_NEEDLE='the desktop runs an older copy; takes effect at next login'
reset_status_extension "$AFTER_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH"
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME"
older_copy_summary+="card=$(status_warnings_naming "$OLDER_COPY_NEEDLE (card.js changed after this login)")"
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME" GNOME_STATUS_SHELL_PID=
older_copy_summary+=" no-shell=$(status_warnings_naming "$OLDER_COPY_NEEDLE")"
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME" GNOME_STATUS_SHELL_STATE=
older_copy_summary+=" unknown-to-shell=$(status_warnings_naming "$OLDER_COPY_NEEDLE")"
reset_status_extension "$BEFORE_SHELL_START_EPOCH" "$AFTER_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH"
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME"
older_copy_summary+=" lib=$(status_warnings_naming "$OLDER_COPY_NEEDLE (lib/format.js changed after this login)")"
reset_status_extension "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH" "$AFTER_SHELL_START_EPOCH"
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME"
older_copy_summary+=" service-only=$(status_warnings_naming "$OLDER_COPY_NEEDLE")"
# GNOME re-reads the stylesheet at every enable, so a CSS-only change is not an older copy (ruling R20).
reset_status_extension "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH" \
  "$AFTER_SHELL_START_EPOCH"
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME"
older_copy_summary+=" css-only=$(status_warnings_naming "$OLDER_COPY_NEEDLE")"
reset_status_extension "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH"
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME"
older_copy_summary+=" unchanged=$(status_warnings_naming "$OLDER_COPY_NEEDLE")"
older_copy_summary+=" pgrep=[$(grep '^pgrep ' "$GNOME_STATUS_CALLS")]"
check "gnome-status: drawing code (*.js, lib/) newer than the desktop's gnome-shell says the desktop runs an older copy, and only then" \
  "$older_copy_summary" \
  "card=1 no-shell=0 unknown-to-shell=0 lib=1 service-only=0 css-only=0 unchanged=0 pgrep=[pgrep -o -x -u $(id -u) gnome-shell]"
# The shell side is extension.js and what it imports (ruling R23): a module only
# the service runs never makes the desktop's copy older.
older_copy_by_side_summary=""
for changed_module in lib/cadence.js lib/visibility.js lib/protocol.js; do
  status_extension_with_change "$changed_module"
  gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME"
  older_copy_by_side_summary+="$changed_module=$(status_warnings_naming "$OLDER_COPY_NEEDLE ($changed_module changed")/$(status_warnings_naming "$OLDER_COPY_NEEDLE") "
done
check "gnome-status: the older copy follows extension.js's imports: a service-only module (lib/cadence.js) is none, a shell-only (lib/visibility.js) or shared one (lib/protocol.js) is one" \
  "$older_copy_by_side_summary" "lib/cadence.js=0/0 lib/visibility.js=1/1 lib/protocol.js=1/1 "
# A closure it cannot work out (a shape the helper refuses, or no helper at all)
# must say so on each side: silence would read as "the code is current".
CANNOT_TELL_COPY_NEEDLE='cannot tell whether the desktop runs an older copy'
CANNOT_TELL_CODE_NEEDLE='cannot tell whether resource-pulse.service runs older code'
cannot_tell_summary=""
reset_status_extension "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH"
printf '%s\n' 'const loaded = await import(modulePath);' >"$STATUS_EXTENSION_DIR/extension.js"
printf '%s\n' 'const loaded = await import(modulePath);' >"$STATUS_EXTENSION_DIR/service/main.js"
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME" "$STATUS_SERVICE_STARTED_AT"
cannot_tell_summary+="refused=$(status_warnings_naming "$CANNOT_TELL_COPY_NEEDLE")/$(status_warnings_naming "$CANNOT_TELL_CODE_NEEDLE")"
reset_status_extension "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH"
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME" "$STATUS_SERVICE_STARTED_AT" \
  "DOTFILES_ROOT=$WIRING_TMP/no-such-checkout"
cannot_tell_summary+=" no-helper=$(status_warnings_naming "$CANNOT_TELL_COPY_NEEDLE")/$(status_warnings_naming "$CANNOT_TELL_CODE_NEEDLE")"
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME" "$STATUS_SERVICE_STARTED_AT"
cannot_tell_summary+=" working=$(status_warnings_naming 'cannot tell')"
check "gnome-status: an import closure it cannot work out (the helper refuses a shape, or there is none) is a ⚠ on each side that it cannot tell, never silence" \
  "$cannot_tell_summary" "refused=1/1 no-helper=1/1 working=0"
# Until the next login the desktop may run the previous release, which samples
# by itself and never starts the service: while the older copy is reported, a
# service not running is not blamed as well. With the current copy it is.
NOT_RUNNING_NEEDLE='is not running while the extension is enabled'
not_running_beside_older_copy_summary=""
status_extension_with_change card.js
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME" GNOME_STATUS_SERVICE_ACTIVE_STATE=inactive
not_running_beside_older_copy_summary+="older-copy=$(status_warnings_naming "$OLDER_COPY_NEEDLE")/$(status_warnings_naming "$NOT_RUNNING_NEEDLE")"
reset_status_extension "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH"
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME" GNOME_STATUS_SERVICE_ACTIVE_STATE=inactive
not_running_beside_older_copy_summary+=" current-copy=$(status_warnings_naming "$OLDER_COPY_NEEDLE")/$(status_warnings_naming "$NOT_RUNNING_NEEDLE")"
check "gnome-status: while the desktop runs an older copy (which may be the previous release, sampling by itself), a service not running is not blamed; with the current copy it is" \
  "$not_running_beside_older_copy_summary" "older-copy=1/0 current-copy=0/1"

# The cockpit unit, cockpit.service: opt-in by file, so for anyone without
# ~/.config/resource-pulse/cockpit.json systemd skips every start (loaded,
# inactive, ConditionResult=no), which is no fault. A unit never started reads
# ConditionResult=no too (systemd's default before any check, measured on a
# system unit), so with the file present that state is a unit not started.
GNOME_STATUS_COCKPIT_HOME="$WIRING_TMP/gnome-status-cockpit-home"
if ! mkdir -p "$GNOME_STATUS_COCKPIT_HOME/.config/resource-pulse" ||
  ! cp "$DOTFILES/examples/resource-pulse-cockpit.json.template" "$GNOME_STATUS_COCKPIT_HOME/.config/resource-pulse/cockpit.json"; then
  fatal "cannot create gnome-status's opted-in fixture home"
fi
COCKPIT_DEST_NEEDLE='--dest io.github.quantivly.dotfiles.Cockpit1 '
COCKPIT_JOURNAL_HINT='journalctl --user -u cockpit.service -e'
status_cockpit_gdbus_calls() { grep -c -F -e "$COCKPIT_DEST_NEEDLE" "$GNOME_STATUS_CALLS"; }
cockpit_skipped_summary=""
gnome_status_run "$ASKED_FOR_SETTING" true
cockpit_skipped_summary+="no-config=[$(status_cockpit_line)]/$(status_warning_count)/$(status_cockpit_gdbus_calls)"
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_COCKPIT_HOME"
cockpit_skipped_summary+=" config-never-started=[$(status_cockpit_line)]/$(status_warnings_naming 'cockpit.service is not running though ~/.config/resource-pulse/cockpit.json exists — systemctl --user start cockpit.service')/$(status_cockpit_gdbus_calls)"
check "gnome-status: a cockpit unit skipped by its condition reads skipped while the config file is absent, and warns nothing; with the file, the same state is a unit not started, with the start remedy" \
  "$cockpit_skipped_summary" \
  "no-config=[skipped (no ~/.config/resource-pulse/cockpit.json)]/0/0 config-never-started=[inactive (not running)]/1/0"
# The unit's condition (%E) and the service (GLib's user config dir) both look
# under $XDG_CONFIG_HOME when it is set, so gnome-status does too: the file under
# it opts in from a HOME without one, and a HOME's file does not count past it.
cockpit_config_home_summary=""
gnome_status_run "$ASKED_FOR_SETTING" true "XDG_CONFIG_HOME=$GNOME_STATUS_COCKPIT_HOME/.config"
cockpit_config_home_summary+="file-under-it=[$(status_cockpit_line)]"
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_COCKPIT_HOME" "XDG_CONFIG_HOME=$WIRING_TMP/no-such-config-home"
cockpit_config_home_summary+=" file-only-in-home=[$(status_cockpit_line)]"
check "gnome-status: with XDG_CONFIG_HOME set, the cockpit's config file is the one under it, as the unit's %E and the service read it" \
  "$cockpit_config_home_summary" \
  "file-under-it=[inactive (not running)] file-only-in-home=[skipped (no ~/.config/resource-pulse/cockpit.json)]"

# Fresh: sources 3, 3 and 2 s old, the latest publish 4 s ago. The latest
# publish is the latest Changed (or the start), so a quiet service's is old,
# and that is no fault.
QUIET_PUBLISH_AGE_SECONDS=2100
cockpit_fresh_summary=""
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_COCKPIT_ACTIVE_STATE=active
cockpit_fresh_summary+="fresh=[$(status_cockpit_line)]/$(status_warning_count)"
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_COCKPIT_ACTIVE_STATE=active \
  "GNOME_STATUS_COCKPIT_STATE_JSON=$(cockpit_state_json 3 3 2 null "$QUIET_PUBLISH_AGE_SECONDS")"
cockpit_fresh_summary+=" quiet=[$(status_cockpit_line)]/$(status_warning_count)"
check "gnome-status: an active cockpit shows its protocol, the age of its last publish and no stale source, from GetState; a quiet one's old publish is no fault" \
  "$cockpit_fresh_summary" \
  "fresh=[active, protocol 1, last publish 4 s ago, stale: none]/0 quiet=[active, protocol 1, last publish 35 min ago, stale: none]/0"

# A source is stale past three of its own intervals (mounts: 3 × 30 s = 90 s),
# each read from its own object: mounts comes last, so a read of the first
# stamp in the sources for every source would find none stale.
cockpit_stale_summary=""
for stale_case in "at-limit:3 3 90" "past-limit:3 3 91" "two:16 3 91" "network-absent:3 absent 91"; do
  read -r -a stale_case_ages <<<"${stale_case#*:}"
  gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_COCKPIT_ACTIVE_STATE=active \
    "GNOME_STATUS_COCKPIT_STATE_JSON=$(cockpit_state_json "${stale_case_ages[@]}")"
  cockpit_stale_summary+="${stale_case%%:*}=[$(status_cockpit_line)]/$(status_warning_count) "
done
check "gnome-status: a cockpit source last sampled more than three of its intervals ago is listed as stale, read from its own object; exactly three is not, and one GetState does not carry is not listed" \
  "$cockpit_stale_summary" \
  "at-limit=[active, protocol 1, last publish 4 s ago, stale: none]/0 past-limit=[active, protocol 1, last publish 4 s ago, stale: mounts]/0 two=[active, protocol 1, last publish 4 s ago, stale: sessions, mounts]/0 network-absent=[active, protocol 1, last publish 4 s ago, stale: mounts]/0 "

# configError is the parser's text (FULL_STATE's holds apostrophes, so gdbus
# prints the reply in double quotes; another holds JSON-escaped quotes), or
# "missing" when the file vanished while the service runs. Each reply is
# printed by GLib itself, as gdbus prints it.
APOSTROPHE_CONFIG_ERROR="groups[2].cards[0]: unknown card id 'weather'"
QUOTED_CONFIG_ERROR='groups[0]: "caption" must be a string'
QUOTED_CONFIG_ERROR_JSON='"groups[0]: \"caption\" must be a string"'
COCKPIT_CONFIG_INVALID_NEEDLE='cockpit: config invalid: '
# cockpit_config_run <configError as JSON>: gnome-status with an active cockpit whose GetState carries it.
cockpit_config_run() {
  local glib_printed_reply
  # shellcheck disable=SC2016  # JavaScript source.
  glib_printed_reply="$(gjs -c 'const {GLib} = imports.gi; print(new GLib.Variant("(s)", [ARGV[0]]).print(true));' \
    "$(cockpit_state_json 3 3 2 "$1")")"
  gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_COCKPIT_ACTIVE_STATE=active \
    GNOME_STATUS_COCKPIT_GDBUS_MODE=verbatim "GNOME_STATUS_COCKPIT_GDBUS_REPLY=$glib_printed_reply"
}
cockpit_config_summary=""
cockpit_config_run "\"$APOSTROPHE_CONFIG_ERROR\""
cockpit_config_summary+="apostrophe=$(status_warnings_naming "$COCKPIT_CONFIG_INVALID_NEEDLE$APOSTROPHE_CONFIG_ERROR — ")/[$(status_cockpit_line)]"
cockpit_config_run "$QUOTED_CONFIG_ERROR_JSON"
cockpit_config_summary+=" quote=$(status_warnings_naming "$COCKPIT_CONFIG_INVALID_NEEDLE$QUOTED_CONFIG_ERROR — ")"
cockpit_config_run '"missing"'
cockpit_config_summary+=" missing=$(status_warnings_naming "${COCKPIT_CONFIG_INVALID_NEEDLE}missing — ")"
cockpit_config_run null
cockpit_config_summary+=" valid=$(status_warnings_naming "$COCKPIT_CONFIG_INVALID_NEEDLE")"
check "gnome-status: a configError in the cockpit's GetState is a ⚠ quoting it whole (apostrophes, escaped quotes, or missing), beside its line; none without one" \
  "$cockpit_config_summary" \
  "apostrophe=1/[active, protocol 1, last publish 4 s ago, stale: none] quote=1 missing=1 valid=0"

cockpit_not_installed_summary=""
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_COCKPIT_LOAD_STATE=not-found
cockpit_not_installed_summary+="no-config=[$(status_cockpit_line)]/$(status_warning_count)"
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_COCKPIT_HOME" GNOME_STATUS_COCKPIT_LOAD_STATE=not-found
cockpit_not_installed_summary+=" config=[$(status_cockpit_line)]/$(status_warnings_naming 'cockpit.service is not installed though ~/.config/resource-pulse/cockpit.json exists — run ./install')"
check "gnome-status: a cockpit unit not found reads not installed, never skipped, and says to run ./install only while the config file exists" \
  "$cockpit_not_installed_summary" \
  "no-config=[not installed (LoadState=not-found)]/0 config=[not installed (LoadState=not-found)]/1"

cockpit_fault_summary=""
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_COCKPIT_ACTIVE_STATE=failed
cockpit_fault_summary+="failed=[$(status_cockpit_line)]/$(status_warnings_naming "cockpit.service failed — $COCKPIT_JOURNAL_HINT")/$(status_cockpit_gdbus_calls) "
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_COCKPIT_ACTIVE_STATE=activating GNOME_STATUS_COCKPIT_SUB_STATE=auto-restart
cockpit_fault_summary+="restarting=[$(status_cockpit_line)]/$(status_warnings_naming "cockpit.service is restarting after a failure — $COCKPIT_JOURNAL_HINT")/$(status_cockpit_gdbus_calls) "
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_COCKPIT_ACTIVE_STATE=active GNOME_STATUS_COCKPIT_GDBUS_MODE=fail
cockpit_fault_summary+="no-answer=[$(status_cockpit_line)]/$(status_warnings_naming "cockpit.service is active but did not answer GetState within 3 s — $COCKPIT_JOURNAL_HINT")/$(status_cockpit_gdbus_calls)"
check "gnome-status: a failed, restarting or silent cockpit is a ⚠ naming its journal, as for the sampler; only the active one is asked GetState" \
  "$cockpit_fault_summary" \
  "failed=[failed (not running)]/1/0 restarting=[activating (auto-restart: restarting after a failure)]/1/0 no-answer=[active, no answer]/1/1"

# The cockpit's side is service/cockpit.js and what it imports (ruling R13):
# its own lib/cockpitProtocol.js and the shared service/fileIo.js count, the
# sampler's service/main.js and service/sampler.js do not. The sampler's count
# beside each shows the change was seen, so a cockpit zero is not a blind one.
cockpit_older_code_summary=""
COCKPIT_STARTED_AT="GNOME_STATUS_COCKPIT_STARTED_AT=@$SUITE_STARTED_AT_EPOCH"
for changed_module in service/cockpit.js lib/cockpitProtocol.js service/fileIo.js service/sampler.js service/main.js; do
  status_extension_with_change "$changed_module"
  gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME" "$STATUS_SERVICE_STARTED_AT" \
    GNOME_STATUS_COCKPIT_ACTIVE_STATE=active "$COCKPIT_STARTED_AT"
  cockpit_older_code_summary+="$changed_module=$(status_warnings_naming "cockpit.service runs older code: $changed_module changed after it started — systemctl --user try-restart cockpit.service")/$(status_warnings_naming 'cockpit.service runs older code')/sampler:$(status_warnings_naming 'resource-pulse.service runs older code') "
done
reset_status_extension "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH"
gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME" "$STATUS_SERVICE_STARTED_AT" \
  GNOME_STATUS_COCKPIT_ACTIVE_STATE=active "$COCKPIT_STARTED_AT"
cockpit_older_code_summary+="unchanged=$(status_warnings_naming 'runs older code')"
check "gnome-status: a module service/cockpit.js runs (itself, lib/cockpitProtocol.js, or the shared service/fileIo.js) changed after the cockpit started is a ⚠ that it runs older code; a sampler-only module is not" \
  "$cockpit_older_code_summary" \
  "service/cockpit.js=1/1/sampler:0 lib/cockpitProtocol.js=1/1/sampler:0 service/fileIo.js=1/1/sampler:1 service/sampler.js=0/0/sampler:1 service/main.js=0/0/sampler:1 unchanged=0"

# The unit file as systemd sees it is the link's TARGET (the checkout's systemd/<unit>): the link in the
# user's unit directory is created now, so its own time is always after the unit started and would hide
# the difference. FragmentPath names the link; the target's time is the one that counts.
UNIT_FILE_FIXTURE_DIR="$WIRING_TMP/gnome-status-unit-files"
# unit_files_with_target_mtime <epoch>: fresh unit-file links whose targets carry that mtime.
unit_files_with_target_mtime() {
  local unit_name
  rm -rf "$UNIT_FILE_FIXTURE_DIR"
  mkdir -p "$UNIT_FILE_FIXTURE_DIR/checkout" "$UNIT_FILE_FIXTURE_DIR/unit-dir" || fatal "cannot create $UNIT_FILE_FIXTURE_DIR"
  for unit_name in resource-pulse.service cockpit.service; do
    : >"$UNIT_FILE_FIXTURE_DIR/checkout/$unit_name"
    touch -d "@$1" "$UNIT_FILE_FIXTURE_DIR/checkout/$unit_name" || fatal "touch -d @$1 failed"
    ln -s "$UNIT_FILE_FIXTURE_DIR/checkout/$unit_name" "$UNIT_FILE_FIXTURE_DIR/unit-dir/$unit_name" || fatal "cannot link $unit_name"
  done
}
# status_unit_file_run <cockpit ActiveState> <sampler ActiveState>: gnome-status over the linked extension, both
# units started when the suite started, their unit files as the fixture left them.
status_unit_file_run() {
  reset_status_extension "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH" "$BEFORE_SHELL_START_EPOCH"
  gnome_status_run "$ASKED_FOR_SETTING" true "HOME=$GNOME_STATUS_LINKED_HOME" "$STATUS_SERVICE_STARTED_AT" \
    "GNOME_STATUS_SERVICE_ACTIVE_STATE=$2" "GNOME_STATUS_COCKPIT_ACTIVE_STATE=$1" "$COCKPIT_STARTED_AT" \
    "GNOME_STATUS_SERVICE_UNIT_FILE=$UNIT_FILE_FIXTURE_DIR/unit-dir/resource-pulse.service" \
    "GNOME_STATUS_COCKPIT_UNIT_FILE=$UNIT_FILE_FIXTURE_DIR/unit-dir/cockpit.service"
}
status_unit_file_warnings_naming() { status_warnings_naming "$1 runs an older unit file"; }
unit_file_newer_summary=""
unit_files_with_target_mtime "$AFTER_SHELL_START_EPOCH"
status_unit_file_run active active
for unit_name in resource-pulse.service cockpit.service; do
  unit_file_newer_summary+="$unit_name=$(status_warnings_naming "$unit_name runs an older unit file: it changed after the unit started — systemctl --user daemon-reload && systemctl --user try-restart $unit_name")/$(status_unit_file_warnings_naming "$unit_name") "
done
unit_file_newer_summary+="total=$(status_warning_count)"
check "gnome-status: a unit file (the link's target) changed after its unit started is one ⚠ naming daemon-reload and try-restart, for the sampler and for the cockpit" \
  "$unit_file_newer_summary" "resource-pulse.service=1/1 cockpit.service=1/1 total=2"

unit_file_older_summary=""
unit_files_with_target_mtime "$BEFORE_SHELL_START_EPOCH"
status_unit_file_run active active
unit_file_older_summary+="older=$(status_warnings_naming 'runs an older unit file') "
# Changed in the very second the unit started: not newer.
unit_files_with_target_mtime "$SUITE_STARTED_AT_EPOCH"
status_unit_file_run active active
unit_file_older_summary+="same-second=$(status_warnings_naming 'runs an older unit file')"
check "gnome-status: a unit file older than its unit's start, or changed in the same second, is no ⚠ (the link's own newer time does not count)" \
  "$unit_file_older_summary" "older=0 same-second=0"

unit_file_stopped_summary=""
unit_files_with_target_mtime "$AFTER_SHELL_START_EPOCH"
status_unit_file_run inactive inactive
unit_file_stopped_summary+="stopped=$(status_warnings_naming 'runs an older unit file')"
check "gnome-status: a unit that is not running gets no older-unit-file ⚠ even when its file is newer than its last start" \
  "$unit_file_stopped_summary" "stopped=0"

cockpit_gdbus_summary=""
gnome_status_run "$ASKED_FOR_SETTING" true
cockpit_gdbus_summary+="skipped=$(status_gdbus_calls)"
gnome_status_run "$ASKED_FOR_SETTING" true GNOME_STATUS_COCKPIT_ACTIVE_STATE=active
cockpit_gdbus_summary+=" active=$(status_gdbus_calls) cockpit-call=[$(grep -F -e "$COCKPIT_DEST_NEEDLE" "$GNOME_STATUS_CALLS")]"
check "gnome-status: an active cockpit makes exactly one more gdbus call than a skipped one, Cockpit1's GetState with gdbus's reply timeout" \
  "$cockpit_gdbus_summary" \
  "skipped=1 active=2 cockpit-call=[gdbus call --session --dest io.github.quantivly.dotfiles.Cockpit1 --object-path /io/github/quantivly/dotfiles/Cockpit1 --method io.github.quantivly.dotfiles.Cockpit1.GetState --timeout 2]"

# Spelled by pieces so this row's own source is not what it finds.
GNOME_STATUS_FORBIDDEN_PATTERN="cmd""line|env""iron\\b|\\bps -|pgre""p -[a-z]*[al]\\b"
gnome_status_source="$(sed -n '/^gnome-status() {$/,/^}$/p' "$DOTFILES/zsh/functions/system.sh")"
# The range must reach the service block (its GetState call), or an empty range would pass.
check "gnome-status reads no argument list or environment, and runs no ps or pgrep -a/-l" \
  "reaches-service-block=$(grep -c -F 'gdbus call --session' <<<"$gnome_status_source") forbidden=$(grep -c -E "$GNOME_STATUS_FORBIDDEN_PATTERN" <<<"$gnome_status_source")" \
  "reaches-service-block=1 forbidden=0"

printf '\nlink and template\n'
check "install.conf.yaml links the extension directory" \
  "$(grep -c -x -F "    ~/.local/share/gnome-shell/extensions/$EXTENSION_UUID: gnome-shell/extensions/$EXTENSION_UUID" "$DOTFILES/install.conf.yaml")" 1
check "the template carries a commented genable_extension line" \
  "$(grep -c -x -F "# genable_extension $EXTENSION_UUID" "$DOTFILES/examples/gnome-settings.local.template")" 1
TEMPLATE_FILE="$DOTFILES/examples/gnome-settings.local.template"
check "the template carries a commented gdisable_extension line for ding, and never calls it uncommented" \
  "commented=$(grep -c -x -F "# gdisable_extension $DING_UUID" "$TEMPLATE_FILE") live=$(grep -c -E '^[[:space:]]*gdisable_extension' "$TEMPLATE_FILE")" "commented=1 live=0"
# The cockpit's background, for the desktop and the lock screen, in gset's own
# value form (as `gsettings get` prints it, so a second gnome-apply is a no-op).
COCKPIT_BACKGROUND_LINE_PATTERN="^# gset org\\.gnome\\.desktop\\.(background|screensaver) +(picture-options +\"'none'\"|primary-color +\"'#121a1a'\")\$"
check "the template carries the cockpit's background lines for the desktop and the lock screen, commented, and points at the cockpit's config template" \
  "background=$(grep -c -E "$COCKPIT_BACKGROUND_LINE_PATTERN" "$DOTFILES/examples/gnome-settings.local.template") pointer=$(grep -c -F 'examples/resource-pulse-cockpit.json.template ~/.config/resource-pulse/cockpit.json' "$DOTFILES/examples/gnome-settings.local.template")" \
  "background=4 pointer=1"

# ---------------------------------------------------------------------------
# The sampler service: its D-Bus face, its entry point, its unit and its
# install step.
#
# Every row that needs a message bus runs inside `dbus-run-session` on a bus of
# its own (on_private_bus): a path socket in a 0700 directory of this run, and no
# service directory, so nothing on it can be activated. Each program run there
# refuses to start unless DBUS_SESSION_BUS_ADDRESS is that socket, and all of it
# runs behind LIVE_SETTINGS_BARRIER, so even a program that ignored the address
# would find no live bus to fall back to.
# ---------------------------------------------------------------------------
SERVICE_MAIN_PATH="$EXT_DIR/service/main.js"
PRIVATE_BUS_DIR="$WIRING_TMP/private-bus"
PRIVATE_BUS_CONFIG="$WIRING_TMP/private-bus.conf"
PRIVATE_BUS_RUNNER="$DOTFILES/gnome-shell/tests/run-private-bus.js"
PRIVATE_BUS_TIMEOUT_SECONDS=150
PRIVATE_BUS_KILL_AFTER_SECONDS=10
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
  </policy>
</busconfig>
BUS_CONFIG
# on_private_bus <command...> runs a command on its own private bus, behind the
# barrier. GIO_USE_VFS=local keeps GIO from even asking that bus for gvfs. It
# runs in a session of its own (setsid), and timeout signals its whole process
# group, KILL 10 s after TERM: a timeout ends the private dbus-daemon and any
# service/main.js with it, never only dbus-run-session.
on_private_bus() {
  env "${LIVE_SETTINGS_BARRIER[@]}" RESOURCE_PULSE_TEST_BUS_DIR="$PRIVATE_BUS_DIR" GIO_USE_VFS=local \
    setsid --wait timeout --kill-after="$PRIVATE_BUS_KILL_AFTER_SECONDS" "$PRIVATE_BUS_TIMEOUT_SECONDS" \
    dbus-run-session --config-file="$PRIVATE_BUS_CONFIG" -- "$@"
}
# is_private_bus_address <address> <bus dir>: the drivers' twin of
# requirePrivateBusAddress (gnome-shell/tests/service-dbus.test.js): one path
# socket inside the bus dir, and nothing that could lead it out of it: an
# address list (;), a /../ segment, or a percent escape (D-Bus decodes %2e%2e
# to ..). Exported, so a driver run under on_private_bus checks its bus with
# this same function.
is_private_bus_address() {
  local address="$1" bus_dir="$2"
  [[ -n "$bus_dir" && "$address" == "unix:path=$bus_dir/"* ]] || return 1
  [[ "$address" != *';'* && "$address" != *'/../'* && "$address" != *'%'* ]]
}
export -f is_private_bus_address

printf '\nthe service D-Bus layer on a private bus (gnome-shell/tests/run-private-bus.js)\n'
# The runner's own guard, first: outside its private bus it must refuse (exit 2)
# before a row runs. Every address below is a socket that does not exist, so
# even a runner without the guard could reach nothing: (a) the barrier's dead
# bus, outside the private bus directory; (b) the live bus's socket name under
# XDG_RUNTIME_DIR, with the bus directory set to that runtime dir; then three
# that start inside the private bus directory but lead out of it: (c) an
# address list (;) whose second entry is elsewhere, (d) a /../ segment, and
# (e) a percent escape, which D-Bus decodes (%2e%2e is ..).
runner_guard_summary=""
runner_guard_output="$(env "${LIVE_SETTINGS_BARRIER[@]}" RESOURCE_PULSE_TEST_BUS_DIR="$PRIVATE_BUS_DIR" \
  timeout "$PRIVATE_BUS_TIMEOUT_SECONDS" gjs -m "$PRIVATE_BUS_RUNNER" 2>&1)"
runner_guard_summary+="outside=$?/$(grep -c -F 'refusing to run' <<<"$runner_guard_output")"
runner_guard_summary+="/$(grep -c -F 'JS-TALLY' <<<"$runner_guard_output")"
runner_guard_output="$(env "${LIVE_SETTINGS_BARRIER[@]}" RESOURCE_PULSE_TEST_BUS_DIR="$LIVE_SETTINGS_BARRIER_RUNTIME_DIR" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=$LIVE_SETTINGS_BARRIER_RUNTIME_DIR/bus" \
  timeout "$PRIVATE_BUS_TIMEOUT_SECONDS" gjs -m "$PRIVATE_BUS_RUNNER" 2>&1)"
runner_guard_summary+=" runtime-bus=$?/$(grep -c -F 'refusing to run' <<<"$runner_guard_output")"
runner_guard_summary+="/$(grep -c -F 'JS-TALLY' <<<"$runner_guard_output")"
ESCAPING_BUS_ADDRESSES=(
  "list=unix:path=$PRIVATE_BUS_DIR/no-bus;$LIVE_SETTINGS_BARRIER_BUS"
  "dotdot=unix:path=$PRIVATE_BUS_DIR/../barrier-no-session-bus"
  "escaped=unix:path=$PRIVATE_BUS_DIR/%2e%2e/barrier-no-session-bus"
)
for escaping_entry in "${ESCAPING_BUS_ADDRESSES[@]}"; do
  runner_guard_output="$(env "${LIVE_SETTINGS_BARRIER[@]}" RESOURCE_PULSE_TEST_BUS_DIR="$PRIVATE_BUS_DIR" \
    DBUS_SESSION_BUS_ADDRESS="${escaping_entry#*=}" timeout "$PRIVATE_BUS_TIMEOUT_SECONDS" gjs -m "$PRIVATE_BUS_RUNNER" 2>&1)"
  runner_guard_summary+=" ${escaping_entry%%=*}=$?/$(grep -c -F 'refusing to run' <<<"$runner_guard_output")"
  runner_guard_summary+="/$(grep -c -F 'JS-TALLY' <<<"$runner_guard_output")"
done
check "the private-bus runner refuses (exit 2, no row run) a bus outside its directory, the live bus, ;, /../ and %" \
  "$runner_guard_summary" "outside=2/1/0 runtime-bus=2/1/0 list=2/1/0 dotdot=2/1/0 escaped=2/1/0"
# The drivers' twin of that guard, which every bash driver below runs first.
private_bus_check_summary=""
PRIVATE_BUS_CHECK_CASES=(
  "own=unix:path=$PRIVATE_BUS_DIR/dbus-0123456789,guid=0123456789abcdef"
  "list=unix:path=$PRIVATE_BUS_DIR/dbus-0123456789;unix:path=/run/user/0/bus"
  "dotdot=unix:path=$PRIVATE_BUS_DIR/../bus"
  "escaped=unix:path=$PRIVATE_BUS_DIR/%2e%2e/bus"
  "elsewhere=unix:path=$WIRING_TMP/bus"
)
for check_case in "${PRIVATE_BUS_CHECK_CASES[@]}"; do
  if is_private_bus_address "${check_case#*=}" "$PRIVATE_BUS_DIR"; then check_verdict=accepted; else check_verdict=refused; fi
  private_bus_check_summary+="${check_case%%=*}=$check_verdict "
done
check "the drivers' bus check accepts its own socket and refuses a list (;), a /../ segment, a % escape and elsewhere" \
  "$private_bus_check_summary" "own=accepted list=refused dotdot=refused escaped=refused elsewhere=refused "
PRIVATE_BUS_JS_OUTPUT="$(on_private_bus gjs -m "$PRIVATE_BUS_RUNNER" 2>&1)"
PRIVATE_BUS_JS_EXIT=$?
printf '%s\n' "$PRIVATE_BUS_JS_OUTPUT"
PRIVATE_BUS_TALLY_LINE=""
while IFS= read -r line; do
  if [[ "$line" =~ $TALLY_PATTERN ]]; then
    PRIVATE_BUS_TALLY_LINE="$line"
    PRIVATE_BUS_JS_PASS="${BASH_REMATCH[1]}"
    PRIVATE_BUS_JS_FAIL="${BASH_REMATCH[2]}"
  fi
done <<<"$PRIVATE_BUS_JS_OUTPUT"
[[ -n "$PRIVATE_BUS_TALLY_LINE" ]] \
  || fatal "no JS-TALLY line from the private-bus rows (exit $PRIVATE_BUS_JS_EXIT): they did not run"
PASS=$((PASS + PRIVATE_BUS_JS_PASS))
FAIL=$((FAIL + PRIVATE_BUS_JS_FAIL))
if (( PRIVATE_BUS_JS_EXIT != 0 && PRIVATE_BUS_JS_FAIL == 0 )); then
  bad "the private-bus runner exited $PRIVATE_BUS_JS_EXIT with no failing row"
fi

printf '\nservice/main.js on a private bus (the real sampler, reading this machine'"'"'s /proc and /sys)\n'
# Asks the service for its state until it has published a sample, for up to
# its last argument's seconds, and prints what it found on one line.
# shellcheck disable=SC2016  # JavaScript source: $ and backticks are gjs's, not bash's.
SERVICE_STATE_PROBE_JS='
const {Gio, GLib} = imports.gi;
const [busName, objectPath, interfaceName, waitSecondsText] = ARGV;
const RETRY_INTERVAL_USEC = 100000;
const CALL_TIMEOUT_MS = 2000;
const USEC_PER_SECOND = 1000000;
const deadlineUsec = GLib.get_monotonic_time() + Number(waitSecondsText) * USEC_PER_SECOND;
const connection = Gio.bus_get_sync(Gio.BusType.SESSION, null);
let verdict = "no answer";
while (GLib.get_monotonic_time() < deadlineUsec) {
    try {
        const reply = connection.call_sync(busName, objectPath, interfaceName, "GetState", null,
            new GLib.VariantType("(s)"), Gio.DBusCallFlags.NO_AUTO_START, CALL_TIMEOUT_MS, null);
        const state = JSON.parse(reply.deepUnpack()[0]);
        const hasSample = state.sequence >= 1;
        const sampleText = hasSample ? "yes" : "no";
        const memoryText = state.snapshot?.memory ? "yes" : "no";
        verdict = `protocol=${state.protocol} sample=${sampleText} memory=${memoryText}`;
        if (hasSample)
            break;
    } catch (error) {
        verdict = `no answer: ${error.message}`;
    }
    GLib.usleep(RETRY_INTERVAL_USEC);
}
print(verdict);
'
SERVICE_LOG="$WIRING_TMP/service.log"
: >"$SERVICE_LOG"
# gnome-status with its gdbus and date real, so it asks the driver's private bus
# (whose address dbus-run-session sets) and reads gdbus's real text; every other
# tool it calls is the stub of the rows above.
GNOME_STATUS_REAL_BUS_STUB_BIN="$WIRING_TMP/gnome-status-real-bus-bin"
for real_bus_stubbed_tool in gsettings gnome-extensions gnome-shell systemctl pgrep; do
  install_stub "$GNOME_STATUS_REAL_BUS_STUB_BIN" "$real_bus_stubbed_tool" \
    "$(<"$GNOME_STATUS_STUB_BIN/$real_bus_stubbed_tool")"
done
GNOME_STATUS_REAL_BUS_OUTPUT="$WIRING_TMP/gnome-status-real-bus.out"
# shellcheck disable=SC2016  # Expanded by zsh.
# XDG_CONFIG_HOME pinned empty, as in gnome_status_run.
GNOME_STATUS_REAL_BUS_COMMAND=(env HOME="$GNOME_STATUS_HOME" XDG_CONFIG_HOME= PATH="$GNOME_STATUS_REAL_BUS_STUB_BIN:$PATH"
  STUB_STATE="$STUB_STATE" STUB_CALLS="$STUB_CALLS_LOG" STUB_BUS_SEEN="$STUB_BUS_SEEN_LOG"
  GNOME_STATUS_SHELL_STATE=ACTIVE GNOME_STATUS_SERVICE_ACTIVE_STATE=active
  zsh -c 'source "$1" && gnome-status' gnome-status "$DOTFILES/zsh/functions/system.sh")
# The driver starts one service, probes it, starts a second one (which must
# find the name taken), probes the first again, runs gnome-status against it,
# then sends it SIGTERM and waits at most 10 s. Every wait is bounded, so a
# service that ignores SIGTERM ends the row as "hung" rather than hanging the
# suite.
# shellcheck disable=SC2016  # The driver's own source: its variables expand when it runs.
SERVICE_DRIVER_OUTPUT="$(on_private_bus bash -c '
set -u
service_main="$1" service_log="$2" state_probe="$3" bus_name="$4" object_path="$5" gnome_status_output="$6"
shift 6
is_private_bus_address "${DBUS_SESSION_BUS_ADDRESS:-}" "${RESOURCE_PULSE_TEST_BUS_DIR:-}" \
  || { printf "refused: %s is not the private bus\n" "${DBUS_SESSION_BUS_ADDRESS:-unset}"; exit 97; }
# still_running <pid>: the process exists and is not a zombie (the state after the last ") " of its stat).
still_running() {
  local stat_line process_state
  read -r stat_line 2>/dev/null <"/proc/$1/stat" || return 1
  process_state="${stat_line##*) }"
  [[ "${process_state%% *}" != Z ]]
}
gjs -m "$service_main" >>"$service_log" 2>&1 &
first_pid=$!
printf "first=%s\n" "$(gjs -c "$state_probe" "$bus_name" "$object_path" "$bus_name" 30)"
timeout 30 gjs -m "$service_main" >>"$service_log" 2>&1
printf "second-exit=%s\n" "$?"
printf "after-second=%s\n" "$(gjs -c "$state_probe" "$bus_name" "$object_path" "$bus_name" 5)"
"$@" >"$gnome_status_output" 2>&1
printf "gnome-status-exit=%s\n" "$?"
kill -TERM "$first_pid" 2>/dev/null
for (( attempt = 0; attempt < 100; attempt++ )); do
  still_running "$first_pid" || break
  sleep 0.1
done
if still_running "$first_pid"; then
  kill -KILL "$first_pid"
  wait "$first_pid"
  printf "first-exit=hung\n"
else
  wait "$first_pid"
  printf "first-exit=%s\n" "$?"
fi
' service-driver "$SERVICE_MAIN_PATH" "$SERVICE_LOG" "$SERVICE_STATE_PROBE_JS" "$RESOURCE_PULSE_BUS_NAME" \
  "$RESOURCE_PULSE_OBJECT_PATH" "$GNOME_STATUS_REAL_BUS_OUTPUT" "${GNOME_STATUS_REAL_BUS_COMMAND[@]}" 2>&1)"
service_first=""; service_second_exit=""; service_after_second=""; service_first_exit=""; gnome_status_real_bus_exit=""
while IFS= read -r driver_line; do
  case "$driver_line" in
    first=*)        service_first="${driver_line#first=}" ;;
    second-exit=*)  service_second_exit="${driver_line#second-exit=}" ;;
    after-second=*) service_after_second="${driver_line#after-second=}" ;;
    gnome-status-exit=*) gnome_status_real_bus_exit="${driver_line#gnome-status-exit=}" ;;
    first-exit=*)   service_first_exit="${driver_line#first-exit=}" ;;
  esac
done <<<"$SERVICE_DRIVER_OUTPUT"
service_first_summary="$service_first first-exit=$service_first_exit"
SERVICE_FIRST_EXPECTED="protocol=1 sample=yes memory=yes first-exit=0"
check "service/main.js owns the name, answers GetState with protocol 1 and a sample, and exits 0 on SIGTERM" \
  "$service_first_summary" "$SERVICE_FIRST_EXPECTED"
check "a second service/main.js finds the name taken and exits 1, while the first keeps serving" \
  "second-exit=$service_second_exit after-second=$service_after_second" \
  "second-exit=1 after-second=protocol=1 sample=yes memory=yes"
# The age is the real one, so its shape is compared, not its number: any whole
# number of seconds, so under 2 minutes, a bound generous enough for a loaded CI
# runner. For the same reason a stall ⚠ is left out of the count here; the
# stubbed rows above pin the 6 s threshold.
REAL_BUS_SERVICE_LINE_PATTERN='^  service: active, protocol 1, last sample [0-9]+ s ago$'
real_bus_service_line="$(grep -E '^  service: ' "$GNOME_STATUS_REAL_BUS_OUTPUT" 2>/dev/null)"
real_bus_line_shape="$([[ "$real_bus_service_line" =~ $REAL_BUS_SERVICE_LINE_PATTERN ]] && printf ok || printf '[%s]' "$real_bus_service_line")"
real_bus_other_warnings="$(grep -F '  ⚠ ' "$GNOME_STATUS_REAL_BUS_OUTPUT" 2>/dev/null | grep -c -v -F 'has not sampled')"
check "gnome-status reads the real service's GetState through the real gdbus: protocol 1 and a recent last sample, no other ⚠" \
  "exit=$gnome_status_real_bus_exit shape=$real_bus_line_shape warnings=$real_bus_other_warnings" \
  "exit=0 shape=ok warnings=0"
# Warnings of gjs and GLib themselves only (a deprecated API, a misused call,
# an uncaught error): the service's own lines are Gjs-Console-*, and a read
# this runner's kernel refuses may well log one of those.
ENGINE_WARNING_PATTERN='(Gjs|GLib|GLib-GIO|GLib-GObject)-(WARNING|CRITICAL)|JS ERROR|Unhandled promise rejection'
check "service/main.js logged no gjs or GLib warning, critical or uncaught error" \
  "$(grep -c -E "$ENGINE_WARNING_PATTERN" "$SERVICE_LOG")" 0
# A stopped sampler still scans on a watch start, so every shutdown must destroy
# it. That is invisible from outside a process that exits next, so it is read
# from the source: the shutdown step, and no stop() call anywhere.
check "service/main.js's shutdown destroys the sampler, and nothing in it only stops it" \
  "destroy=$(grep -c -F "{name: 'destroy the sampler', run: () => this._sampler?.destroy()}" "$SERVICE_MAIN_PATH") stop=$(grep -c -E '_sampler\??\.stop\(' "$SERVICE_MAIN_PATH")" \
  "destroy=1 stop=0"
if [[ "$service_first_summary" != "$SERVICE_FIRST_EXPECTED" ]]; then
  printf '    (driver said: %s)\n' "$SERVICE_DRIVER_OUTPUT"
  sed 's/^/    service log: /' "$SERVICE_LOG"
fi

printf '\nservice/cockpit.js on a private bus (the real sources, under a home of this run and no system bus)\n'
# The cockpit's entry point runs twice, each time under a HOME, XDG_CONFIG_HOME
# and XDG_STATE_HOME of this run: the config home holds the shipped template as
# resource-pulse/cockpit.json, the state home no hspawn registry, the home no
# ~/.ssh. DBUS_SYSTEM_BUS_ADDRESS names a socket that does not exist, so
# NetworkManager and UPower are absent, as on a runner with no system bus at
# all. The first run has no herdr socket; the second has a fake herdr at
# <config home>/herdr/herdr.sock, so FocusSession never reaches the live herdr,
# and beside it a fake herdr client: a process named herdr in a terminal of its
# own, whose pid and its terminal's FocusSession must name, on any machine.
# Neither is in fixture mode: the first sets RESOURCE_PULSE_COCKPIT_FIXTURE
# empty, the second unsets it. A third run sets it to a copy of
# gnome-shell/tests/fixtures/cockpit/nested-state.json, under a config home with
# no config and no herdr socket, so what it serves can only be the fixture's.
# A fourth runs a copy of the extension whose listing of /proc throws a plain
# Error (a fault, not IO), with a fake herdr of its own.
COCKPIT_MAIN_PATH="$EXT_DIR/service/cockpit.js"
COCKPIT_BUS_NAME='io.github.quantivly.dotfiles.Cockpit1'
COCKPIT_OBJECT_PATH='/io/github/quantivly/dotfiles/Cockpit1'
COCKPIT_CONFIG_TEMPLATE="$DOTFILES/examples/resource-pulse-cockpit.json.template"
COCKPIT_CONFIG_RELATIVE_PATH='resource-pulse/cockpit.json'
COCKPIT_NO_SYSTEM_BUS="unix:path=$WIRING_TMP/cockpit-no-system-bus"
COCKPIT_RUN_DIR="$WIRING_TMP/cockpit"
COCKPIT_SERVE_LOG="$COCKPIT_RUN_DIR/cockpit-serve.log"
COCKPIT_FOCUS_LOG="$COCKPIT_RUN_DIR/cockpit-focus.log"
COCKPIT_HERDR_REQUEST_LOG="$COCKPIT_RUN_DIR/herdr-requests.log"
COCKPIT_FAKE_HERDR_LOG="$COCKPIT_RUN_DIR/fake-herdr.log"
COCKPIT_FIXTURE_LOG="$COCKPIT_RUN_DIR/cockpit-fixture.log"
COCKPIT_BAD_FIXTURE_LOG="$COCKPIT_RUN_DIR/cockpit-bad-fixture.log"
COCKPIT_NESTED_FIXTURE="$DOTFILES/gnome-shell/tests/fixtures/cockpit/nested-state.json"
# The fixture the third run serves, and two rewrites of it: the network source
# changed alone (2 ssh masters become 3), then the layout alone as well (the
# third group's caption WORK becomes LATER).
COCKPIT_FIXTURE_PATH="$COCKPIT_RUN_DIR/cockpit-fixture.json"
COCKPIT_FIXTURE_NETWORK_REWRITE="$COCKPIT_RUN_DIR/cockpit-fixture-network.json"
COCKPIT_FIXTURE_LAYOUT_REWRITE="$COCKPIT_RUN_DIR/cockpit-fixture-layout.json"
# The same fixture, readable and valid, under a stat-only directory (/.ssh/, one
# of lib/constants.js's STAT_ONLY_PATH_FRAGMENTS): the service must refuse it
# unopened, so serving it, or failing to read it, both fail its row.
COCKPIT_REFUSED_FIXTURE_PATH="$COCKPIT_RUN_DIR/fixture-home/.ssh/cockpit-fixture.json"
COCKPIT_REFUSED_FIXTURE_LOG="$COCKPIT_RUN_DIR/cockpit-refused-fixture.log"
# service/cockpit.js's COCKPIT_FIXTURE_REFUSED_ERROR: the reason its shutdown line gives.
COCKPIT_FIXTURE_REFUSED_REASON='refused before opening it: its path names a file the cockpit may stat, never open'
# The fake herdr client: a /bin/sh script whose file name is herdr, which the
# kernel takes as its comm (a copied binary cannot be renamed that way). The
# driver runs it under script(1), which gives it a pseudo-terminal (a non-zero
# tty_nr) and stays its parent, as a terminal emulator would. It writes its pid
# to the file it is given and sleeps until killed, or at most
# FAKE_CLIENT_LIFETIME_SECONDS should every cleanup be skipped; it never reaches
# any herdr socket. It lives in this run's directory, never on PATH.
COCKPIT_FAKE_CLIENT_DIR="$COCKPIT_RUN_DIR/fake-herdr-client"
COCKPIT_FAKE_CLIENT_PATH="$COCKPIT_FAKE_CLIENT_DIR/herdr"
COCKPIT_FAKE_CLIENT_PID_FILE="$COCKPIT_FAKE_CLIENT_DIR/client.pid"
COCKPIT_FAKE_CLIENT_LOG="$COCKPIT_RUN_DIR/fake-herdr-client.log"
# The /proc-fault run: a copy of the extension in which service/sources/sourceIo.js
# re-exports the real module (moved beside it) but listEntryNames throws a plain
# Error for /proc. Under the real tree the scan never meets such an Error, so
# this is the one way to drive the fault path of service/cockpit.js itself.
COCKPIT_PROC_FAULT_EXT_DIR="$COCKPIT_RUN_DIR/proc-fault-extension"
COCKPIT_PROC_FAULT_SOURCE_IO="$COCKPIT_PROC_FAULT_EXT_DIR/service/sources/sourceIo.js"
COCKPIT_PROC_FAULT_REAL_SOURCE_IO="$COCKPIT_PROC_FAULT_EXT_DIR/service/sources/sourceIoWithoutFault.js"
COCKPIT_PROC_FAULT_MAIN_PATH="$COCKPIT_PROC_FAULT_EXT_DIR/service/cockpit.js"
COCKPIT_PROC_FAULT_LOG="$COCKPIT_RUN_DIR/cockpit-proc-fault.log"
COCKPIT_PROC_FAULT_HERDR_REQUEST_LOG="$COCKPIT_RUN_DIR/proc-fault-herdr-requests.log"
COCKPIT_PROC_FAULT_MESSAGE='injected fault: listing /proc'
for cockpit_run_name in serve focus; do
  for cockpit_home_kind in home config state; do
    mkdir -p "$COCKPIT_RUN_DIR/$cockpit_run_name-$cockpit_home_kind" \
      || fatal "cannot create $COCKPIT_RUN_DIR/$cockpit_run_name-$cockpit_home_kind"
  done
  cockpit_config_path="$COCKPIT_RUN_DIR/$cockpit_run_name-config/$COCKPIT_CONFIG_RELATIVE_PATH"
  if ! mkdir -p "$(dirname "$cockpit_config_path")" || ! cp "$COCKPIT_CONFIG_TEMPLATE" "$cockpit_config_path"; then
    fatal "cannot place the config template at $cockpit_config_path"
  fi
done
mkdir -p "$COCKPIT_RUN_DIR/focus-config/herdr" || fatal "cannot create the fake herdr's directory"
for cockpit_home_kind in home config state; do
  mkdir -p "$COCKPIT_RUN_DIR/fixture-$cockpit_home_kind" "$COCKPIT_RUN_DIR/proc-fault-$cockpit_home_kind" \
    || fatal "cannot create the fixture and /proc-fault $cockpit_home_kind directories under $COCKPIT_RUN_DIR"
done
mkdir -p "$COCKPIT_RUN_DIR/proc-fault-config/herdr" "${COCKPIT_REFUSED_FIXTURE_PATH%/*}" "$COCKPIT_FAKE_CLIENT_DIR" \
  || fatal "cannot create the /proc-fault fake herdr's, the refused fixture's or the fake client's directory"
cp -- "$COCKPIT_NESTED_FIXTURE" "$COCKPIT_REFUSED_FIXTURE_PATH" || fatal "cannot copy $COCKPIT_NESTED_FIXTURE"
cat >"$COCKPIT_FAKE_CLIENT_PATH" <<'FAKE_HERDR_CLIENT' || fatal "cannot write $COCKPIT_FAKE_CLIENT_PATH"
#!/bin/sh
# A stand-in for a herdr client, for scripts/test-resource-pulse.sh: see
# COCKPIT_FAKE_CLIENT_PATH there. $1 is the file its pid goes to.
FAKE_CLIENT_LIFETIME_SECONDS=300
printf '%s\n' "$$" >"$1"
trap 'kill "$sleep_pid" 2>/dev/null; exit 0' TERM HUP INT
sleep "$FAKE_CLIENT_LIFETIME_SECONDS" &
sleep_pid=$!
wait "$sleep_pid"
FAKE_HERDR_CLIENT
chmod +x "$COCKPIT_FAKE_CLIENT_PATH" || fatal "cannot make $COCKPIT_FAKE_CLIENT_PATH executable"
if ! cp -R -- "$EXT_DIR" "$COCKPIT_PROC_FAULT_EXT_DIR" \
  || ! mv -- "$COCKPIT_PROC_FAULT_SOURCE_IO" "$COCKPIT_PROC_FAULT_REAL_SOURCE_IO"; then
  fatal "cannot copy the extension to $COCKPIT_PROC_FAULT_EXT_DIR, or move its sourceIo.js aside"
fi
# A module's own export shadows the same name from export *, so every other
# helper is the real one.
cat >"$COCKPIT_PROC_FAULT_SOURCE_IO" <<PROC_FAULT_SOURCE_IO || fatal "cannot write $COCKPIT_PROC_FAULT_SOURCE_IO"
// scripts/test-resource-pulse.sh's /proc-fault copy of sourceIo.js: the real
// module, but a listing of PROC_ROOT_PATH throws a plain Error.
import {PROC_ROOT_PATH} from '../../lib/constants.js';
import {listEntryNames as listEntryNamesWithoutFault} from './${COCKPIT_PROC_FAULT_REAL_SOURCE_IO##*/}';

export * from './${COCKPIT_PROC_FAULT_REAL_SOURCE_IO##*/}';

export function listEntryNames(directoryPath) {
    if (directoryPath === PROC_ROOT_PATH)
        throw new Error('$COCKPIT_PROC_FAULT_MESSAGE');
    return listEntryNamesWithoutFault(directoryPath);
}
PROC_FAULT_SOURCE_IO
cp -- "$COCKPIT_NESTED_FIXTURE" "$COCKPIT_FIXTURE_PATH" || fatal "cannot copy $COCKPIT_NESTED_FIXTURE"
sed 's/"sshMasterCount": 2/"sshMasterCount": 3/' "$COCKPIT_FIXTURE_PATH" >"$COCKPIT_FIXTURE_NETWORK_REWRITE" \
  || fatal "cannot write $COCKPIT_FIXTURE_NETWORK_REWRITE"
sed 's/"caption": "WORK"/"caption": "LATER"/' "$COCKPIT_FIXTURE_NETWORK_REWRITE" >"$COCKPIT_FIXTURE_LAYOUT_REWRITE" \
  || fatal "cannot write $COCKPIT_FIXTURE_LAYOUT_REWRITE"
# A rewrite that changed nothing (the fixture's text moved on) would leave the
# rewrite rows comparing a file with itself.
if cmp -s "$COCKPIT_FIXTURE_PATH" "$COCKPIT_FIXTURE_NETWORK_REWRITE" \
  || cmp -s "$COCKPIT_FIXTURE_NETWORK_REWRITE" "$COCKPIT_FIXTURE_LAYOUT_REWRITE"; then
  fatal "a rewrite of $COCKPIT_NESTED_FIXTURE changed nothing: its ssh master count or WORK caption moved"
fi
: >"$COCKPIT_SERVE_LOG"; : >"$COCKPIT_FOCUS_LOG"; : >"$COCKPIT_HERDR_REQUEST_LOG"; : >"$COCKPIT_FAKE_HERDR_LOG"
: >"$COCKPIT_FIXTURE_LOG"; : >"$COCKPIT_BAD_FIXTURE_LOG"; : >"$COCKPIT_REFUSED_FIXTURE_LOG"
: >"$COCKPIT_FAKE_CLIENT_LOG"; : >"$COCKPIT_PROC_FAULT_LOG"; : >"$COCKPIT_PROC_FAULT_HERDR_REQUEST_LOG"
# Decodes a gdbus call's reply (GLib.Variant text, as gdbus prints it, holding
# one JSON string). For `reply` it prints the JSON compactly (FocusSession's);
# `client-reply` does the same, but a focused reply's windowPidCandidates print
# as fake-client-then-script when they hold the fake herdr client's pid with its
# terminal's (script's) right after it, the two pids given after the text, and
# hold no pid 1; as themselves otherwise. Other herdr clients may come before or
# after (this machine's own), so only those two are asked for. For `state` it
# prints the GetState fields named after the text, as <name>=<value> separated
# by spaces, in the order asked.
# shellcheck disable=SC2016  # JavaScript source: $ and backticks are gjs's, not bash's.
COCKPIT_REPLY_DECODER_JS='
const {GLib} = imports.gi;
const [replyKind, gdbusReplyText, ...fieldNames] = ARGV;
const SOURCE_NAMES = ["sessions", "network", "mounts"];
const SINGLE_STRING_TYPE = new GLib.VariantType("(s)");
const FAKE_CLIENT_CANDIDATES_TAG = "fake-client-then-script";
const INIT_PID = 1;
function holdsFakeClientThenScript(candidates, fakeClientPid, fakeClientScriptPid) {
    const fakeClientIndex = candidates.indexOf(fakeClientPid);
    return fakeClientIndex >= 0 && candidates[fakeClientIndex + 1] === fakeClientScriptPid &&
        !candidates.includes(INIT_PID);
}
function kindOf(value) {
    if (value === null || value === undefined)
        return "null";
    return Array.isArray(value) ? "list" : typeof value;
}
function stateFieldTexts(state) {
    const sources = state.sources ?? {};
    const sessions = sources.sessions ?? {};
    const uplink = sources.network?.uplink ?? {};
    const sourceKinds = SOURCE_NAMES.map(sourceName => kindOf(sources[sourceName]));
    const uplinkValues = [uplink.kind, uplink.connectivity, uplink.wifiEnabled].map(String);
    const intervals = SOURCE_NAMES.map(sourceName => String(sources[sourceName]?.intervalSeconds));
    const groupCount = state.layout?.groups?.length;
    const network = sources.network ?? {};
    return {
        protocol: String(state.protocol),
        sources: sourceKinds.join("/"),
        layout: kindOf(state.layout),
        groups: String(groupCount ?? "none"),
        configError: JSON.stringify(state.configError ?? null),
        published: String(state.latestPublishedAtUsec),
        herdrRunning: String(sessions.herdrRunning),
        sessionRows: String(sessions.rows?.length),
        mounts: kindOf(sources.mounts),
        mountsRows: kindOf(sources.mounts?.rows),
        uplink: uplinkValues.join("/"),
        intervals: intervals.join("/"),
        captions: (state.layout?.groups ?? []).map(group => group.caption).join("/"),
        sessionIds: (sessions.rows ?? []).map(row => row.id).join(","),
        vpn: String(network.vpn?.isUp),
        sshMasters: String(network.sshMasterCount),
        mountRowCount: String(sources.mounts?.rows?.length),
    };
}
let decoded;
try {
    const [replyJson] = GLib.Variant.parse(SINGLE_STRING_TYPE, gdbusReplyText, null, null).deepUnpack();
    const reply = JSON.parse(replyJson);
    const candidates = reply.windowPidCandidates;
    const [fakeClientPid, fakeClientScriptPid] = fieldNames.map(Number);
    if (replyKind === "client-reply" && reply.focused === true && Array.isArray(candidates) &&
            holdsFakeClientThenScript(candidates, fakeClientPid, fakeClientScriptPid))
        reply.windowPidCandidates = FAKE_CLIENT_CANDIDATES_TAG;
    if (replyKind === "reply" || replyKind === "client-reply") {
        decoded = JSON.stringify(reply);
    } else {
        const fieldTexts = stateFieldTexts(reply);
        decoded = fieldNames.map(fieldName => `${fieldName}=${fieldTexts[fieldName]}`).join(" ");
    }
} catch (error) {
    decoded = `unreadable reply: ${error.message}`;
}
print(decoded);
'
# A fake herdr on <socket path>, speaking herdr's framing (one JSON request
# line {id, method, params}, one reply line, then close: see
# service/herdrSocket.js). It logs each request as `<method> <params JSON>` to
# <request log>. Its snapshot holds four claude panes: w1:p1; w1:p2, whose
# pane.focus it rejects as herdr does a pane that is gone; p3, in no
# workspace; and one with no pane at all, whose row id is its session id.
# shellcheck disable=SC2016  # JavaScript source: $ and backticks are gjs's, not bash's.
COCKPIT_FAKE_HERDR_JS='
const {Gio, GLib} = imports.gi;
const [socketPath, requestLogPath] = ARGV;
const PANE_HERDR_REJECTS = "p2";
const SNAPSHOT = {
    workspaces: [{workspace_id: "w1", label: "alpha"}],
    agents: [
        {agent: "claude", agent_status: "working", workspace_id: "w1", pane_id: "p1", agent_session: {value: "s1"}},
        {agent: "claude", agent_status: "idle", workspace_id: "w1", pane_id: PANE_HERDR_REJECTS,
            agent_session: {value: "s2"}},
        {agent: "claude", agent_status: "idle", pane_id: "p3", cwd: "/work/beta", agent_session: {value: "s3"}},
        {agent: "claude", agent_status: "idle", cwd: "/work/gamma", agent_session: {value: "s4"}},
    ],
};
const requestLines = [];
function answerFor(method, params) {
    switch (method) {
    case "session.snapshot":
        return {result: {type: "session_snapshot", snapshot: SNAPSHOT}};
    case "pane.process_info":
        return {result: {type: "pane_process_info", process_info: {pane_id: params.pane_id, foreground_processes: []}}};
    case "workspace.focus":
        return {result: {type: "ok"}};
    case "pane.focus":
        if (params.pane_id === PANE_HERDR_REJECTS)
            return {error: {code: "pane_not_found", message: "pane not found"}};
        return {result: {type: "ok"}};
    default:
        return {error: {code: "invalid_request", message: "unknown method"}};
    }
}
function replyTextFor(requestLine) {
    const request = JSON.parse(requestLine);
    const params = request.params ?? {};
    requestLines.push(`${request.method} ${JSON.stringify(params)}`);
    GLib.file_set_contents(requestLogPath, `${requestLines.join("\n")}\n`);
    return JSON.stringify({id: request.id, ...answerFor(request.method, params)});
}
const socketService = new Gio.SocketService();
socketService.add_address(Gio.UnixSocketAddress.new(socketPath), Gio.SocketType.STREAM, Gio.SocketProtocol.DEFAULT,
    null);
socketService.connect("incoming", (_service, connection) => {
    const lineReader = new Gio.DataInputStream({base_stream: connection.get_input_stream()});
    lineReader.read_line_async(GLib.PRIORITY_DEFAULT, null, (_stream, readResult) => {
        let replyText = "";
        try {
            const [requestLine] = lineReader.read_line_finish_utf8(readResult);
            replyText = replyTextFor(requestLine);
        } catch (error) {
            printerr(`fake herdr: cannot answer: ${error.message}`);
        }
        const replyBytes = new GLib.Bytes(new TextEncoder().encode(`${replyText}\n`));
        connection.get_output_stream().write_bytes_async(replyBytes, GLib.PRIORITY_DEFAULT, null,
            (outputStream, writeResult) => {
                try {
                    if (outputStream.write_bytes_finish(writeResult) !== replyBytes.get_size())
                        printerr("fake herdr: a reply went out in part");
                } catch (error) {
                    printerr(`fake herdr: cannot reply: ${error.message}`);
                }
                connection.close(null);
            });
    });
    return true;
});
socketService.start();
new GLib.MainLoop(null, false).run();
'
# The driver. The serve run: owns the name, answers GetState, a second copy
# exits 1, then the config is rewritten unchanged (GetState's latest publish
# time read around it), overwritten with "{", deleted and renamed back into
# place, each followed by GetState for up to 3 s; then SIGTERM. The focus run: a
# fake herdr and the fake herdr client first, then the service, then one
# FocusSession per kind of row, each followed by the focus requests the fake
# herdr saw for it; then the fake herdr stopped and one more FocusSession, which
# finds herdr unreachable; then SIGTERM. The /proc-fault run: its own fake herdr,
# the faulty copy of the service, one FocusSession, SIGTERM; then the fake herdr
# client is stopped (and by the EXIT trap on every other path). The fixture run:
# GetState, two FocusSessions, then the fixture renamed over twice (the network
# rewrite, then the layout one), each followed by GetState for up to 3 s, with
# the Changed signals watched on the bus; then SIGTERM; then a fixture that does
# not exist, one that is not JSON and one under a stat-only path, each ending
# the service at its start. Every wait is bounded.
# shellcheck disable=SC2016  # The driver's own source: its variables expand when it runs.
COCKPIT_DRIVER_OUTPUT="$(on_private_bus bash -c '
set -u
cockpit_main="$1" decoder_js="$2" fake_herdr_js="$3" bus_name="$4" object_path="$5" run_dir="$6"
config_template="$7" config_relative_path="$8" no_system_bus="$9"
serve_log="${10}" focus_log="${11}" request_log="${12}" fake_herdr_log="${13}"
fixture_path="${14}" fixture_network_rewrite="${15}" fixture_layout_rewrite="${16}" fixture_log="${17}"
bad_fixture_log="${18}" refused_fixture_path="${19}" refused_fixture_log="${20}"
fake_client_path="${21}" fake_client_pid_file="${22}" fake_client_log="${23}"
proc_fault_main="${24}" proc_fault_log="${25}" proc_fault_request_log="${26}"
is_private_bus_address "${DBUS_SESSION_BUS_ADDRESS:-}" "${RESOURCE_PULSE_TEST_BUS_DIR:-}" \
  || { printf "refused: %s is not the private bus\n" "${DBUS_SESSION_BUS_ADDRESS:-unset}"; exit 97; }
USEC_PER_SECOND=1000000
FOCUS_REQUEST_PATTERN="^(workspace|pane)\.focus "
# still_running <pid>: the process exists and is not a zombie (the state after the last ") " of its stat).
still_running() {
  local stat_line process_state
  read -r stat_line 2>/dev/null <"/proc/$1/stat" || return 1
  process_state="${stat_line##*) }"
  [[ "${process_state%% *}" != Z ]]
}
now_usec() { printf "%s" "${EPOCHREALTIME/./}"; }
# layout_changed_count <file>: the Changed signals gdbus monitor wrote to <file>
# that carry the key configError, which only a layout change adds.
layout_changed_count() {
  grep -c -E 'Changed.*configError' "$1"
}
# changed_count <file>: the Changed signals gdbus monitor wrote to <file>.
changed_count() {
  grep -c -F ".Changed (" "$1"
}
# changed_summary <file>: what each Changed signal gdbus monitor wrote to
# <file> names, in order, joined by |: layout when it carries configError,
# which only a layout change adds, then each source it carries.
changed_summary() {
  local monitor_line changed_names summary="" source_name
  while IFS= read -r monitor_line; do
    [[ "$monitor_line" == *".Changed ("* ]] || continue
    changed_names=""
    [[ "$monitor_line" == *\"configError\"* ]] && changed_names+="+layout"
    for source_name in sessions network mounts; do
      [[ "$monitor_line" == *\"$source_name\":* ]] && changed_names+="+$source_name"
    done
    summary+="|${changed_names#+}"
  done <"$1"
  printf "%s" "${summary#|}"
}
# wait_for_changed <file> <count>: waits at most 3 s for <count> Changed
# signals in <file>.
wait_for_changed() {
  local attempt
  for (( attempt = 0; attempt < 30; attempt++ )); do
    (( $(changed_count "$1") >= $2 )) && break
    sleep 0.1
  done
}
# start_fake_herdr_client: runs the fake herdr client under script(1), through
# an exec in the shell script starts, so that script is its parent; waits at
# most 5 s for its pid; sets fake_client_pid and fake_client_script_pid.
# SHELL=/bin/sh, so no login shell of this machine reads its rc files. Prints
# fake-herdr-client=ready, or "could not run" and why when it wrote no pid, or
# is not named herdr, has no terminal or is not the child of script.
start_fake_herdr_client() {
  local attempt client_stat_line client_comm client_state="could not run: it wrote no pid within 5 s"
  local -a client_stat_fields=()
  : >"$fake_client_pid_file"
  env SHELL=/bin/sh script -qec "exec \"$fake_client_path\" \"$fake_client_pid_file\"" /dev/null \
    </dev/null >>"$fake_client_log" 2>&1 &
  fake_client_script_pid=$!
  for (( attempt = 0; attempt < 50; attempt++ )); do
    [[ -s "$fake_client_pid_file" ]] && break
    sleep 0.1
  done
  read -r fake_client_pid 2>/dev/null <"$fake_client_pid_file" || fake_client_pid=""
  [[ -n "$fake_client_pid" ]] && client_state="could not run: no /proc/$fake_client_pid/stat"
  if [[ -n "$fake_client_pid" ]] && read -r client_stat_line 2>/dev/null <"/proc/$fake_client_pid/stat"; then
    client_comm="${client_stat_line#*(}"
    client_comm="${client_comm%)*}"
    read -r -a client_stat_fields <<<"${client_stat_line##*) }"
    client_state="could not run: comm=$client_comm ppid=${client_stat_fields[1]-} tty_nr=${client_stat_fields[4]-}"
    [[ "$client_comm" == herdr && "${client_stat_fields[1]-}" == "$fake_client_script_pid" \
      && "${client_stat_fields[4]-0}" != 0 ]] && client_state=ready
  fi
  printf "fake-herdr-client=%s\n" "$client_state"
}
# stop_fake_herdr_client: SIGTERM to the fake herdr client, while its pid is
# still a process named herdr, and to script; then at most 5 s for script to
# end, and SIGKILL only while it still runs; safe when neither runs.
stop_fake_herdr_client() {
  local attempt client_stat_line=""
  [[ -n "$fake_client_pid" ]] && read -r client_stat_line 2>/dev/null <"/proc/$fake_client_pid/stat"
  [[ "$client_stat_line" == *" (herdr) "* ]] && kill -TERM "$fake_client_pid" 2>/dev/null
  if [[ -n "$fake_client_script_pid" ]]; then
    still_running "$fake_client_script_pid" && kill -TERM "$fake_client_script_pid" 2>/dev/null
    for (( attempt = 0; attempt < 50; attempt++ )); do
      still_running "$fake_client_script_pid" || break
      sleep 0.1
    done
    still_running "$fake_client_script_pid" && kill -KILL "$fake_client_script_pid" 2>/dev/null
    wait "$fake_client_script_pid" 2>/dev/null
  fi
  fake_client_pid="" fake_client_script_pid=""
}
# wait_for_banner <file>: waits at most 5 s for the first line of gdbus monitor
# (its "Monitoring signals" banner, the readiness signal) in <file>.
wait_for_banner() {
  local attempt
  for (( attempt = 0; attempt < 50; attempt++ )); do
    [[ -s "$1" ]] && break
    sleep 0.1
  done
}
# probe_state <seconds> <needle> <field...>: asks GetState through gdbus until
# the decoded fields hold <needle>, for at most <seconds>; prints the last
# decoding, or "no answer" when gdbus never answered.
probe_state() {
  local wait_seconds="$1" needle="$2" deadline_usec decoded="no answer" reply
  shift 2
  deadline_usec=$(( $(now_usec) + wait_seconds * USEC_PER_SECOND ))
  while :; do
    if reply="$(gdbus call --session --dest "$bus_name" --object-path "$object_path" \
        --method "$bus_name.GetState" --timeout 2 2>/dev/null)"; then
      decoded="$(gjs -c "$decoder_js" state "$reply" "$@")"
      [[ "$decoded" == *"$needle"* ]] && break
    fi
    (( $(now_usec) >= deadline_usec )) && break
    sleep 0.1
  done
  printf "%s" "$decoded"
}
# stop_process <label> <pid>: SIGTERM, then at most 10 s; prints <label>=<exit status>, or hung.
stop_process() {
  local label="$1" pid="$2" attempt
  kill -TERM "$pid" 2>/dev/null
  for (( attempt = 0; attempt < 100; attempt++ )); do
    still_running "$pid" || break
    sleep 0.1
  done
  if still_running "$pid"; then
    kill -KILL "$pid"
    wait "$pid"
    printf "%s=hung\n" "$label"
  else
    wait "$pid"
    printf "%s=%s\n" "$label" "$?"
  fi
}
# focus_session <id> [label] [decoding]: one FocusSession through gdbus;
# prints, under "focus <label>" (the id by default), the reply as the decoding
# <decoding> of the decoder gives it (client-reply, against the fake herdr
# client running now, by default) and the focus requests the fake herdr saw for
# it in request_log, joined by |.
focus_session() {
  local session_id="$1" label="${2:-$1}" reply_decoding="${3:-client-reply}" requests_before reply decoded requests
  requests_before="$(grep -c -E "$FOCUS_REQUEST_PATTERN" "$request_log")"
  if reply="$(gdbus call --session --dest "$bus_name" --object-path "$object_path" \
      --method "$bus_name.FocusSession" "\"$session_id\"" --timeout 5 2>&1)"; then
    decoded="$(gjs -c "$decoder_js" "$reply_decoding" "$reply" "$fake_client_pid" "$fake_client_script_pid")"
  else
    decoded="D-Bus error: ${reply%%$'"'"'\n'"'"'*}"
  fi
  requests="$(grep -E "$FOCUS_REQUEST_PATTERN" "$request_log" | tail -n "+$(( requests_before + 1 ))" | tr "\n" "|")"
  printf "focus %s=reply=%s requests=[%s]\n" "$label" "$decoded" "${requests%|}"
  return 0
}

serve_config="$run_dir/serve-config/$config_relative_path"
serve_environment=(env HOME="$run_dir/serve-home" XDG_CONFIG_HOME="$run_dir/serve-config"
  XDG_STATE_HOME="$run_dir/serve-state" DBUS_SYSTEM_BUS_ADDRESS="$no_system_bus" RESOURCE_PULSE_COCKPIT_FIXTURE=)
"${serve_environment[@]}" gjs -m "$cockpit_main" >>"$serve_log" 2>&1 &
serve_pid=$!
printf "served=%s\n" "$(probe_state 15 "sources=object/object/object" \
  protocol sources groups configError herdrRunning mountsRows)"
printf "no-system-bus=%s\n" "$(probe_state 2 "uplink=" uplink intervals)"
"${serve_environment[@]}" timeout 30 gjs -m "$cockpit_main" >>"$serve_log" 2>&1
printf "second-exit=%s\n" "$?"
printf "after-second=%s\n" "$(probe_state 5 "protocol=1" protocol)"
# A monitor on the the service bus name, attached (its first output line, the
# "Monitoring signals" banner, is the readiness signal) before any rewrite. Only a
# layout change adds the key configError to Changed, so counting those lines
# says whether a rewrite published a layout; a mounts resample cannot move it.
monitor_log="$run_dir/layout-monitor.log"
: >"$monitor_log"
gdbus monitor --session --dest "$bus_name" >"$monitor_log" 2>&1 &
monitor_pid=$!
fixture_monitor_pid=""
fake_client_pid="" fake_client_script_pid=""
trap '"'"'kill "$monitor_pid" ${fixture_monitor_pid:+"$fixture_monitor_pid"} 2>/dev/null; stop_fake_herdr_client'"'"' EXIT
wait_for_banner "$monitor_log"
cp -- "$config_template" "$serve_config"
sleep 1
layout_changes_after_same_text="$(layout_changed_count "$monitor_log")"
printf "{" >"$serve_config"
printf "malformed=%s\n" "$(probe_state 3 "layout=null" layout configError mounts)"
for (( attempt = 0; attempt < 30; attempt++ )); do
  (( $(layout_changed_count "$monitor_log") >= 1 )) && break
  sleep 0.1
done
layout_changes_after_new_text="$(layout_changed_count "$monitor_log")"
kill "$monitor_pid" 2>/dev/null
printf "layout-changes=same-text=%s new-text=%s\n" \
  "$layout_changes_after_same_text" "$layout_changes_after_new_text"
rm -f -- "$serve_config"
printf "deleted=%s\n" "$(probe_state 3 "configError=\"missing\"" layout configError mounts)"
cp -- "$config_template" "$serve_config.new" && mv -- "$serve_config.new" "$serve_config"
printf "renamed-in=%s\n" "$(probe_state 3 "groups=3" layout groups configError)"
stop_process serve-exit "$serve_pid"

herdr_socket="$run_dir/focus-config/herdr/herdr.sock"
gjs -c "$fake_herdr_js" "$herdr_socket" "$request_log" >>"$fake_herdr_log" 2>&1 &
fake_herdr_pid=$!
for (( attempt = 0; attempt < 50; attempt++ )); do
  [[ -S "$herdr_socket" ]] && break
  sleep 0.1
done
start_fake_herdr_client
focus_environment=(env -u RESOURCE_PULSE_COCKPIT_FIXTURE HOME="$run_dir/focus-home"
  XDG_CONFIG_HOME="$run_dir/focus-config" XDG_STATE_HOME="$run_dir/focus-state"
  DBUS_SYSTEM_BUS_ADDRESS="$no_system_bus")
"${focus_environment[@]}" gjs -m "$cockpit_main" >>"$focus_log" 2>&1 &
focus_pid=$!
printf "focus-ready=%s\n" "$(probe_state 15 "sessionRows=4" herdrRunning sessionRows)"
for session_id in w1:p1 p3 w1:p2 w1:p9 s4; do
  focus_session "$session_id"
done
# The rows stay those of the start sample: unwatched, sessions resamples only
# after 60 s, so w1:p1 is still a row once herdr is gone.
kill -TERM "$fake_herdr_pid" 2>/dev/null
wait "$fake_herdr_pid" 2>/dev/null
focus_session w1:p1 "w1:p1 without herdr"
stop_process focus-exit "$focus_pid"

# The first fake herdr is gone, so the /proc-fault run has its own, logging to
# its own request log. The fake herdr client still runs: a scan that did not
# fault would name it.
request_log="$proc_fault_request_log"
proc_fault_herdr_socket="$run_dir/proc-fault-config/herdr/herdr.sock"
gjs -c "$fake_herdr_js" "$proc_fault_herdr_socket" "$request_log" >>"$fake_herdr_log" 2>&1 &
proc_fault_herdr_pid=$!
for (( attempt = 0; attempt < 50; attempt++ )); do
  [[ -S "$proc_fault_herdr_socket" ]] && break
  sleep 0.1
done
proc_fault_environment=(env -u RESOURCE_PULSE_COCKPIT_FIXTURE HOME="$run_dir/proc-fault-home"
  XDG_CONFIG_HOME="$run_dir/proc-fault-config" XDG_STATE_HOME="$run_dir/proc-fault-state"
  DBUS_SYSTEM_BUS_ADDRESS="$no_system_bus")
"${proc_fault_environment[@]}" gjs -m "$proc_fault_main" >>"$proc_fault_log" 2>&1 &
proc_fault_pid=$!
printf "proc-fault-ready=%s\n" "$(probe_state 15 "sessionRows=4" herdrRunning sessionRows)"
focus_session w1:p1 "proc-fault w1:p1" reply
stop_process proc-fault-exit "$proc_fault_pid"
kill -TERM "$proc_fault_herdr_pid" 2>/dev/null
wait "$proc_fault_herdr_pid" 2>/dev/null
stop_fake_herdr_client

fixture_environment=(env HOME="$run_dir/fixture-home" XDG_CONFIG_HOME="$run_dir/fixture-config"
  XDG_STATE_HOME="$run_dir/fixture-state" DBUS_SYSTEM_BUS_ADDRESS="$no_system_bus")
"${fixture_environment[@]}" RESOURCE_PULSE_COCKPIT_FIXTURE="$fixture_path" gjs -m "$cockpit_main" \
  >>"$fixture_log" 2>&1 &
fixture_pid=$!
printf "fixture-served=%s\n" "$(probe_state 15 "sessionIds=w1:p1,w1:p2" \
  groups configError herdrRunning sessionIds uplink vpn sshMasters mountRowCount intervals)"
focus_session w1:p1 "fixture w1:p1" reply
focus_session w1:p9 "fixture w1:p9" reply
fixture_monitor_log="$run_dir/fixture-monitor.log"
: >"$fixture_monitor_log"
gdbus monitor --session --dest "$bus_name" >"$fixture_monitor_log" 2>&1 &
fixture_monitor_pid=$!
wait_for_banner "$fixture_monitor_log"
cp -- "$fixture_network_rewrite" "$fixture_path.new" && mv -- "$fixture_path.new" "$fixture_path"
printf "fixture-network-rewrite=%s\n" "$(probe_state 3 "sshMasters=3" sshMasters captions)"
wait_for_changed "$fixture_monitor_log" 1
cp -- "$fixture_layout_rewrite" "$fixture_path.new" && mv -- "$fixture_path.new" "$fixture_path"
printf "fixture-layout-rewrite=%s\n" "$(probe_state 3 "captions=MACHINE/AGENTS/LATER" sshMasters captions)"
wait_for_changed "$fixture_monitor_log" 2
kill "$fixture_monitor_pid" 2>/dev/null
printf "fixture-changes=%s\n" "$(changed_summary "$fixture_monitor_log")"
stop_process fixture-exit "$fixture_pid"
"${fixture_environment[@]}" RESOURCE_PULSE_COCKPIT_FIXTURE="$run_dir/no-such-fixture.json" \
  timeout 30 gjs -m "$cockpit_main" >>"$bad_fixture_log" 2>&1
printf "missing-fixture-exit=%s\n" "$?"
printf "{" >"$run_dir/malformed-fixture.json"
"${fixture_environment[@]}" RESOURCE_PULSE_COCKPIT_FIXTURE="$run_dir/malformed-fixture.json" \
  timeout 30 gjs -m "$cockpit_main" >>"$bad_fixture_log" 2>&1
printf "malformed-fixture-exit=%s\n" "$?"
"${fixture_environment[@]}" RESOURCE_PULSE_COCKPIT_FIXTURE="$refused_fixture_path" \
  timeout 30 gjs -m "$cockpit_main" >>"$refused_fixture_log" 2>&1
printf "refused-fixture-exit=%s\n" "$?"
' cockpit-driver "$COCKPIT_MAIN_PATH" "$COCKPIT_REPLY_DECODER_JS" "$COCKPIT_FAKE_HERDR_JS" "$COCKPIT_BUS_NAME" \
  "$COCKPIT_OBJECT_PATH" "$COCKPIT_RUN_DIR" "$COCKPIT_CONFIG_TEMPLATE" "$COCKPIT_CONFIG_RELATIVE_PATH" \
  "$COCKPIT_NO_SYSTEM_BUS" "$COCKPIT_SERVE_LOG" "$COCKPIT_FOCUS_LOG" "$COCKPIT_HERDR_REQUEST_LOG" \
  "$COCKPIT_FAKE_HERDR_LOG" "$COCKPIT_FIXTURE_PATH" "$COCKPIT_FIXTURE_NETWORK_REWRITE" \
  "$COCKPIT_FIXTURE_LAYOUT_REWRITE" "$COCKPIT_FIXTURE_LOG" "$COCKPIT_BAD_FIXTURE_LOG" \
  "$COCKPIT_REFUSED_FIXTURE_PATH" "$COCKPIT_REFUSED_FIXTURE_LOG" "$COCKPIT_FAKE_CLIENT_PATH" \
  "$COCKPIT_FAKE_CLIENT_PID_FILE" "$COCKPIT_FAKE_CLIENT_LOG" "$COCKPIT_PROC_FAULT_MAIN_PATH" \
  "$COCKPIT_PROC_FAULT_LOG" "$COCKPIT_PROC_FAULT_HERDR_REQUEST_LOG" 2>&1)"
declare -A cockpit_driver_said=()
while IFS= read -r driver_line; do
  [[ "$driver_line" == *=* ]] && cockpit_driver_said["${driver_line%%=*}"]="${driver_line#*=}"
done <<<"$COCKPIT_DRIVER_OUTPUT"
# Without the fake herdr client the FocusSession rows would check nothing, so a
# client that did not come up is "could not run", never a row of its own.
cockpit_fake_client_state="${cockpit_driver_said[fake-herdr-client]-never started}"
[[ "$cockpit_fake_client_state" == ready ]] \
  || fatal "the fake herdr client of the FocusSession rows: $cockpit_fake_client_state (driver said: $COCKPIT_DRIVER_OUTPUT)"
cockpit_fail_count_before=$FAIL
check "service/cockpit.js, with RESOURCE_PULSE_COCKPIT_FIXTURE set empty (no fixture), owns Cockpit1 within 15 s and its GetState says protocol 1, the template's three groups, herdr not running and a list of mount rows" \
  "${cockpit_driver_said[served]-}" "protocol=1 sources=object/object/object groups=3 configError=null herdrRunning=false mountsRows=list"
check "with no system bus it serves all the same: no uplink known, and every cadence off battery (sessions 60 s unwatched, network 10 s, mounts 30 s)" \
  "${cockpit_driver_said[no-system-bus]-}" "uplink=null/null/null intervals=60/10/30"
check "a second service/cockpit.js finds the name taken and exits 1, while the first keeps serving" \
  "second-exit=${cockpit_driver_said[second-exit]-} after-second=${cockpit_driver_said[after-second]-}" \
  "second-exit=1 after-second=protocol=1"
check "the config rewritten with the same text publishes no layout change, and with a new text publishes one (Changed signals carrying configError, watched on the bus)" \
  "${cockpit_driver_said[layout-changes]-}" "same-text=0 new-text=1"
check "the config overwritten with '{' reads within 3 s as no layout and the parse error, and the sources keep serving" \
  "${cockpit_driver_said[malformed]-}" 'layout=null configError="config: malformed JSON" mounts=object'
check "the config deleted reads within 3 s as no layout and the error missing, and the sources keep serving" \
  "${cockpit_driver_said[deleted]-}" 'layout=null configError="missing" mounts=object'
check "the config renamed back into place (an atomic editor's save) reads within 3 s as the layout again" \
  "${cockpit_driver_said[renamed-in]-}" "layout=object groups=3 configError=null"
check "SIGTERM ends service/cockpit.js with exit 0, in all three runs" \
  "serve=${cockpit_driver_said[serve-exit]-} focus=${cockpit_driver_said[focus-exit]-} fixture=${cockpit_driver_said[fixture-exit]-}" \
  "serve=0 focus=0 fixture=0"
check "service/cockpit.js logged its serving line once, with the protocol" \
  "$(grep -c -F "cockpit: serving $COCKPIT_BUS_NAME (protocol 1)" "$COCKPIT_SERVE_LOG")" 1
check "service/cockpit.js logged no gjs or GLib warning, critical or uncaught error, in any run (the fixture's, the bad and refused fixtures' and the /proc-fault run's included)" \
  "$(cat "$COCKPIT_SERVE_LOG" "$COCKPIT_FOCUS_LOG" "$COCKPIT_FIXTURE_LOG" "$COCKPIT_BAD_FIXTURE_LOG" \
    "$COCKPIT_REFUSED_FIXTURE_LOG" "$COCKPIT_PROC_FAULT_LOG" | grep -c -E "$ENGINE_WARNING_PATTERN")" 0
# A focused reply's windowPidCandidates come from /proc: every herdr client (a
# process named herdr with a terminal) and its parents. The driver's own fake
# client is one on any machine, CI included, so the decoder prints
# fake-client-then-script only when the reply names its pid with its terminal's
# (script's) right after it, and no pid 1. This machine's real herdr clients may
# add their own chains around it, so nothing else in the list is asked for;
# lib/processTree.js's rows pin the order, the repeats and the bounds.
check "FocusSession, with RESOURCE_PULSE_COCKPIT_FIXTURE unset, focuses the row's own workspace, then its pane, over the herdr socket: focused true, windowPid null, and window candidates naming the fake herdr client, then its terminal, and never pid 1" \
  "ready=${cockpit_driver_said[focus-ready]-} ${cockpit_driver_said[focus w1:p1]-}" \
  'ready=herdrRunning=true sessionRows=4 reply={"focused":true,"windowPid":null,"error":null,"windowPidCandidates":"fake-client-then-script"} requests=[workspace.focus {"workspace_id":"w1"}|pane.focus {"pane_id":"p1"}]'
check "FocusSession on a row in no workspace sends pane.focus alone, and names the fake herdr client, then its terminal, and never pid 1" \
  "${cockpit_driver_said[focus p3]-}" \
  'reply={"focused":true,"windowPid":null,"error":null,"windowPidCandidates":"fake-client-then-script"} requests=[pane.focus {"pane_id":"p3"}]'
# A herdr rejection is an answer, not a fault: the cockpit replies with its
# code itself, so the D-Bus face's fault line never appears for it. herdr's own
# text goes to the journal alone (ruling R18).
check "a herdr rejection of pane.focus answers focused false and the code herdr-rejected, not a D-Bus error nor herdr's text, which is logged, not as a fault" \
  "${cockpit_driver_said[focus w1:p2]-} logged=$(grep -c -F 'cockpit: focus: w1:p2: herdr: pane_not_found: pane not found' "$COCKPIT_FOCUS_LOG") faults=$(grep -c -F 'cockpit: FocusSession failed' "$COCKPIT_FOCUS_LOG")" \
  'reply={"focused":false,"windowPid":null,"error":"herdr-rejected","windowPidCandidates":[]} requests=[workspace.focus {"workspace_id":"w1"}|pane.focus {"pane_id":"p2"}] logged=1 faults=0'
check "an unknown id, and a row with no pane, answer focused false with the codes unknown-session and no-pane and ask herdr nothing" \
  "unknown: ${cockpit_driver_said[focus w1:p9]-} no-pane: ${cockpit_driver_said[focus s4]-}" \
  'unknown: reply={"focused":false,"windowPid":null,"error":"unknown-session","windowPidCandidates":[]} requests=[] no-pane: reply={"focused":false,"windowPid":null,"error":"no-pane","windowPidCandidates":[]} requests=[]'
check "with the fake herdr stopped, a row answers focused false and the code herdr-unreachable, and herdr's text goes to the journal" \
  "${cockpit_driver_said[focus w1:p1 without herdr]-} logged=$(grep -c -F 'cockpit: focus: w1:p1: herdr: ' "$COCKPIT_FOCUS_LOG")" \
  'reply={"focused":false,"windowPid":null,"error":"herdr-unreachable","windowPidCandidates":[]} requests=[] logged=1'
# The /proc-fault copy throws a plain Error listing /proc, once herdr focused
# the pane. The pane is focused all the same, so the reply must say so, naming
# no window (the fake client still runs, so the scan would otherwise name it),
# with the fault logged once, never answered as the face's internal error.
check "a fault (not IO) while naming the window candidates leaves the reply focused, with no candidates, the fault logged once and never as the face's internal error" \
  "ready=${cockpit_driver_said[proc-fault-ready]-} ${cockpit_driver_said[focus proc-fault w1:p1]-} logged=$(grep -c -F "cockpit: focus: window candidates: $COCKPIT_PROC_FAULT_MESSAGE" "$COCKPIT_PROC_FAULT_LOG") faults=$(grep -c -F 'cockpit: FocusSession failed' "$COCKPIT_PROC_FAULT_LOG") exit=${cockpit_driver_said[proc-fault-exit]-}" \
  'ready=herdrRunning=true sessionRows=4 reply={"focused":true,"windowPid":null,"error":null,"windowPidCandidates":[]} requests=[workspace.focus {"workspace_id":"w1"}|pane.focus {"pane_id":"p1"}] logged=1 faults=0 exit=0'
# The fixture run's config home holds no config and no herdr socket: serving the
# config would read as no layout and the error missing, serving the sources as
# herdr not running, no session rows and no uplink.
check "with RESOURCE_PULSE_COCKPIT_FIXTURE naming nested-state.json, GetState within 15 s serves the fixture's layout and sources, neither the config's nor the real sources'" \
  "${cockpit_driver_said[fixture-served]-}" \
  'groups=3 configError=null herdrRunning=true sessionIds=w1:p1,w1:p2 uplink=wired/full/false vpn=false sshMasters=2 mountRowCount=1 intervals=10/10/30'
check "with the fixture, FocusSession answers its focusReply, windowPidCandidates [4242] included, for a row's id and an unknown one alike" \
  "${cockpit_driver_said[focus fixture w1:p1]-} ${cockpit_driver_said[focus fixture w1:p9]-}" \
  'reply={"focused":true,"windowPid":null,"error":null,"windowPidCandidates":[4242]} requests=[] reply={"focused":true,"windowPid":null,"error":null,"windowPidCandidates":[4242]} requests=[]'
check "the fixture renamed over with another network source reads within 3 s as the new one, and then with another layout as the new layout" \
  "network=${cockpit_driver_said[fixture-network-rewrite]-} layout=${cockpit_driver_said[fixture-layout-rewrite]-}" \
  'network=sshMasters=3 captions=MACHINE/AGENTS/WORK layout=sshMasters=3 captions=MACHINE/AGENTS/LATER'
check "each fixture rewrite publishes one Changed naming what changed: the network source alone, then the layout alone" \
  "${cockpit_driver_said[fixture-changes]-}" 'network|layout'
check "with the fixture, service/cockpit.js logs its serving line and the fixture's path once each" \
  "serving=$(grep -c -F "cockpit: serving $COCKPIT_BUS_NAME (protocol 1)" "$COCKPIT_FIXTURE_LOG") fixture=$(grep -c -F "cockpit: serving a fixture ($COCKPIT_FIXTURE_PATH)" "$COCKPIT_FIXTURE_LOG")" \
  'serving=1 fixture=1'
check "a fixture that does not exist, or that is not JSON, ends service/cockpit.js at its start with exit 1, saying why, before it serves" \
  "missing=${cockpit_driver_said[missing-fixture-exit]-} malformed=${cockpit_driver_said[malformed-fixture-exit]-} logged=$(grep -c -F 'cockpit: shutting down: cannot serve the fixture (' "$COCKPIT_BAD_FIXTURE_LOG") served=$(grep -c -F 'cockpit: serving' "$COCKPIT_BAD_FIXTURE_LOG")" \
  'missing=1 malformed=1 logged=2 served=0'
# The fixture at that path is readable and valid: reading it would serve it,
# and only the refusing reader's refusal ends the start, with its own reason.
check "a readable, valid fixture under a stat-only path (/.ssh/) is refused unopened: service/cockpit.js exits 1 at its start, saying so, and never serves" \
  "exit=${cockpit_driver_said[refused-fixture-exit]-} logged=$(grep -c -F "cockpit: shutting down: cannot serve the fixture ($COCKPIT_REFUSED_FIXTURE_PATH): $COCKPIT_FIXTURE_REFUSED_REASON" "$COCKPIT_REFUSED_FIXTURE_LOG") served=$(grep -c -F 'cockpit: serving' "$COCKPIT_REFUSED_FIXTURE_LOG")" \
  'exit=1 logged=1 served=0'
if (( FAIL > cockpit_fail_count_before )); then
  printf '    (driver said: %s)\n' "$COCKPIT_DRIVER_OUTPUT"
  sed 's/^/    serve log: /' "$COCKPIT_SERVE_LOG"
  sed 's/^/    focus log: /' "$COCKPIT_FOCUS_LOG"
  sed 's/^/    fake herdr log: /' "$COCKPIT_FAKE_HERDR_LOG"
  sed 's/^/    fixture log: /' "$COCKPIT_FIXTURE_LOG"
  sed 's/^/    bad fixture log: /' "$COCKPIT_BAD_FIXTURE_LOG"
  sed 's/^/    refused fixture log: /' "$COCKPIT_REFUSED_FIXTURE_LOG"
  sed 's/^/    \/proc-fault log: /' "$COCKPIT_PROC_FAULT_LOG"
  sed 's/^/    fake herdr client log: /' "$COCKPIT_FAKE_CLIENT_LOG"
fi

printf '\nthe stat-only paths (named nowhere under service/ or lib/ but their list)\n'
# The cockpit service may stat these files, never open them (the spec's "stat,
# never open" list): its file reader (service/sources/sourceIo.js) refuses a
# path holding a fragment of lib/constants.js's STAT_ONLY_PATH_FRAGMENTS. So no
# file under service/ or lib/ may name one anywhere else, in a path it reads or
# one it builds; the list itself is the one place that does, and only its own
# lines are passed over. The names are the spec's, so the row does not lean on
# the list it guards.
# shellcheck disable=SC2088  # The ~ is text the row searches for, never a path to expand.
STAT_ONLY_NAMES=('.credentials' '.aws/' '.zshrc.local' '.gitconfig.local' '.backup.local' '~/.ssh/')
STAT_ONLY_LIST_FIRST_LINE='export const STAT_ONLY_PATH_FRAGMENTS = ['
STAT_ONLY_LIST_LAST_LINE='];'
STAT_ONLY_LIST_MODULE='lib/constants.js'
# stat_only_mentions <extension dir>: "named-in=[<file> ...] list=<state>": the
# files under service/ and lib/ (relative, sorted) naming one of STAT_ONLY_NAMES
# outside the list, and whether lib/constants.js held the list, closed. A tree
# that cannot be listed, or holds no file, says so instead of naming none.
stat_only_mentions() {
  local extension_dir="$1" listing_path="$WIRING_TMP/stat-only-listing" module_path relative_path
  local module_line stat_only_name list_state="absent" inside_list named_in=""
  local -a module_paths=()
  find "$extension_dir/service" "$extension_dir/lib" -type f -print0 >"$listing_path" 2>/dev/null \
    || { printf 'cannot list service/ and lib/ under %s' "$extension_dir"; return; }
  mapfile -d '' module_paths < <(LC_ALL=C sort -z "$listing_path")
  (( ${#module_paths[@]} > 0 )) || { printf 'no file under service/ or lib/ in %s' "$extension_dir"; return; }
  for module_path in "${module_paths[@]}"; do
    relative_path="${module_path#"$extension_dir"/}"
    inside_list=false
    while IFS= read -r module_line || [[ -n "$module_line" ]]; do
      if [[ "$relative_path" == "$STAT_ONLY_LIST_MODULE" ]]; then
        if [[ "$module_line" == "$STAT_ONLY_LIST_FIRST_LINE" ]]; then
          inside_list=true; list_state="unclosed"; continue
        fi
        if [[ "$inside_list" == true ]]; then
          [[ "$module_line" == "$STAT_ONLY_LIST_LAST_LINE" ]] && { inside_list=false; list_state="closed"; }
          continue
        fi
      fi
      for stat_only_name in "${STAT_ONLY_NAMES[@]}"; do
        if [[ "$module_line" == *"$stat_only_name"* ]]; then
          named_in+="$relative_path "
          continue 3
        fi
      done
    done <"$module_path"
  done
  printf 'named-in=[%s] list=%s' "${named_in% }" "$list_state"
}
# The fixture: the real lib/constants.js with one name planted after its list,
# a source that load_contents a planted path, and a clean module beside it.
STAT_ONLY_FIXTURE_DIR="$WIRING_TMP/stat-only-fixture"
mkdir -p "$STAT_ONLY_FIXTURE_DIR/lib" "$STAT_ONLY_FIXTURE_DIR/service/sources" \
  || fatal "cannot create $STAT_ONLY_FIXTURE_DIR"
cp "$EXT_DIR/$STAT_ONLY_LIST_MODULE" "$STAT_ONLY_FIXTURE_DIR/$STAT_ONLY_LIST_MODULE" \
  || fatal "cannot copy $STAT_ONLY_LIST_MODULE into $STAT_ONLY_FIXTURE_DIR"
printf '%s\n' "export const PLANTED_CONFIG_PATH = '${STAT_ONLY_NAMES[5]}config';" \
  >>"$STAT_ONLY_FIXTURE_DIR/$STAT_ONLY_LIST_MODULE"
printf '%s\n' "import Gio from 'gi://Gio';" "import GLib from 'gi://GLib';" \
  "const plantedPath = GLib.build_filenamev([GLib.get_home_dir(), '${STAT_ONLY_NAMES[1]}config']);" \
  "const [, plantedBytes] = Gio.File.new_for_path(plantedPath).load_contents(null);" \
  >"$STAT_ONLY_FIXTURE_DIR/service/sources/planted.js"
printf '%s\n' "export const CLEAN_INTERVAL_SECONDS = 10;" >"$STAT_ONLY_FIXTURE_DIR/service/clean.js"
check "no file under service/ or lib/ names a stat-only path outside lib/constants.js's list; a planted load_contents of one, or a name after the list, is found" \
  "real: $(stat_only_mentions "$EXT_DIR") fixture: $(stat_only_mentions "$STAT_ONLY_FIXTURE_DIR")" \
  "real: named-in=[] list=closed fixture: named-in=[lib/constants.js service/sources/planted.js] list=closed"

printf '\nthe unit (systemd/resource-pulse.service)\n'
SERVICE_UNIT="$DOTFILES/systemd/resource-pulse.service"
SERVICE_MAIN_RELATIVE_PATH='gnome-shell/extensions/resource-pulse@dotfiles/service/main.js'
UNIT_DOTFILES_PREFIX='%h/.dotfiles/'
UNIT_INTERPRETER='/usr/bin/gjs -m'
EXPECTED_UNIT_SETTINGS=(
  '[Unit]Description=<set>'
  '[Unit]PartOf=graphical-session.target'
  '[Unit]StartLimitIntervalSec=300'
  '[Unit]StartLimitBurst=5'
  '[Service]Type=dbus'
  "[Service]BusName=$RESOURCE_PULSE_BUS_NAME"
  "[Service]ExecStart=$UNIT_INTERPRETER $UNIT_DOTFILES_PREFIX$SERVICE_MAIN_RELATIVE_PATH"
  '[Service]Restart=on-failure'
  '[Service]RestartSec=5'
  '[Service]Slice=background.slice'
  '[Service]Nice=10'
  '[Service]CPUQuota=10%'
  '[Service]MemoryHigh=96M'
  '[Service]MemoryMax=128M'
)
# read_unit_settings <unit file>: reads each setting as "[Section]Key=value",
# comments and blank lines aside, into unit_settings; the section headers, in
# order, into unit_sections; and the ExecStart value into unit_exec_start. A
# Description's text is not pinned, only that it is set. An unreadable file
# leaves no settings and says so in unit_sections.
read_unit_settings() {
  local unit_path="$1" unit_section="" unit_line
  unit_sections=""; unit_settings=(); unit_exec_start=""
  if [[ ! -r "$unit_path" ]]; then
    unit_sections="cannot read $unit_path"
    return
  fi
  while IFS= read -r unit_line || [[ -n "$unit_line" ]]; do
    case "$unit_line" in
      ''|'#'*|';'*) ;;
      '['*']') unit_section="$unit_line"; unit_sections+="$unit_line " ;;
      Description=?*) unit_settings+=("${unit_section}Description=<set>") ;;
      *)
        unit_settings+=("$unit_section$unit_line")
        [[ "$unit_line" == ExecStart=* ]] && unit_exec_start="${unit_line#ExecStart=}"
        ;;
    esac
  done <"$unit_path"
}
sorted_settings() { printf '%s\n' "$@" | LC_ALL=C sort | tr '\n' '|'; }
# unit_exec_resolution <entry path relative to the checkout>: resolves the
# unit_exec_start that read_unit_settings left: the script it names under
# ~/.dotfiles, found in this checkout, is that entry. Prints the entry relative
# to the extension directory when it is, "unresolved" otherwise.
unit_exec_resolution() {
  local expected_entry_path="$1" exec_script exec_script_in_checkout
  exec_script="${unit_exec_start#"$UNIT_INTERPRETER "}"
  exec_script_in_checkout="$DOTFILES/${exec_script#"$UNIT_DOTFILES_PREFIX"}"
  if [[ "$exec_script" == "$UNIT_DOTFILES_PREFIX"* && -f "$exec_script_in_checkout" \
    && "$exec_script_in_checkout" -ef "$DOTFILES/$expected_entry_path" ]]; then
    printf '%s' "${expected_entry_path#"gnome-shell/extensions/$EXTENSION_UUID/"}"
  else
    printf 'unresolved'
  fi
}
# verify checks that ExecStart's command exists, and ~/.dotfiles is not this
# checkout on a runner, so it verifies a copy pointed at this checkout: the same
# unit text with a command that exists. The rows above pin the real path.
# --user mode refuses to start with no XDG_RUNTIME_DIR ("Failed to lookup
# RuntimeDirectory path", measured), which a CI runner need not have, so it runs
# behind the barrier, whose private runtime dir is all it needs. It still exits
# 1 for an unknown key and for a missing command (both measured).
UNIT_COPY_DIR="$WIRING_TMP/unit-copy"
# check_unit_verifies <unit file> <what verify's complaints about it contain> <row name>:
# one row, systemd-analyze --user verify on that copy.
check_unit_verifies() {
  local unit_path="$1" complaint_needle="$2" row_name="$3" unit_copy_path verify_output verify_exit
  # An empty copy of a missing unit is not one that verifies.
  if [[ ! -r "$unit_path" ]]; then
    bad "$row_name — cannot read $unit_path"
  elif command -v systemd-analyze >/dev/null 2>&1; then
    unit_copy_path="$UNIT_COPY_DIR/${unit_path##*/}"
    mkdir -p "$UNIT_COPY_DIR" || fatal "cannot create $UNIT_COPY_DIR"
    sed -e "/^ExecStart=/s#$UNIT_DOTFILES_PREFIX#$DOTFILES/#" "$unit_path" >"$unit_copy_path" 2>/dev/null
    verify_output="$(env "${LIVE_SETTINGS_BARRIER[@]}" systemd-analyze --user verify --man=no \
      --recursive-errors=no "$unit_copy_path" 2>&1)"
    verify_exit=$?
    check "$row_name" "$verify_exit:[$(grep -F "$complaint_needle" <<<"$verify_output")]" "0:[]"
  elif [[ -n "${CI:-}" ]]; then
    # CI is where this row is meant to run, so a runner without the tool is a failure, never a skip.
    bad "$row_name — systemd-analyze is missing on CI"
  else
    ok "systemd-analyze absent here; CI verifies ${unit_path##*/}"
  fi
}
read_unit_settings "$SERVICE_UNIT"
check "the unit has a [Unit] and a [Service] section and no [Install], so nothing can ever enable it" \
  "$unit_sections" "[Unit] [Service] "
check "the unit's settings are exactly the design's: Type=dbus on its bus name, PartOf, restart and its limit, caps" \
  "$(sorted_settings "${unit_settings[@]}")" "$(sorted_settings "${EXPECTED_UNIT_SETTINGS[@]}")"
# The ExecStart above is pinned as text; this row resolves it: the script it
# names under ~/.dotfiles must be this checkout's service/main.js.
check "the unit's ExecStart runs, under $UNIT_INTERPRETER, the checkout's own service/main.js" \
  "${unit_exec_start%% "$UNIT_DOTFILES_PREFIX"*}|$(unit_exec_resolution "$SERVICE_MAIN_RELATIVE_PATH")" \
  "$UNIT_INTERPRETER|service/main.js"
check_unit_verifies "$SERVICE_UNIT" 'resource-pulse' \
  "systemd-analyze --user verify accepts the unit (ExecStart pointed at this checkout) and says nothing of it"

printf '\nthe cockpit unit (systemd/cockpit.service)\n'
COCKPIT_UNIT="$DOTFILES/systemd/cockpit.service"
COCKPIT_MAIN_RELATIVE_PATH="gnome-shell/extensions/$EXTENSION_UUID/service/cockpit.js"
# The opt-in: for anyone without the layout file, systemd skips the unit.
COCKPIT_UNIT_CONDITION_KEY='ConditionPathExists'
# %E is $XDG_CONFIG_HOME (or ~/.config), where GLib's user config dir, and so the
# service, looks for the file too.
COCKPIT_UNIT_CONDITION="$COCKPIT_UNIT_CONDITION_KEY=%E/$COCKPIT_CONFIG_RELATIVE_PATH"
EXPECTED_COCKPIT_UNIT_SETTINGS=(
  '[Unit]Description=<set>'
  '[Unit]PartOf=graphical-session.target'
  '[Unit]StartLimitIntervalSec=300'
  '[Unit]StartLimitBurst=5'
  "[Unit]$COCKPIT_UNIT_CONDITION"
  '[Service]Type=dbus'
  "[Service]BusName=$COCKPIT_BUS_NAME"
  "[Service]ExecStart=$UNIT_INTERPRETER $UNIT_DOTFILES_PREFIX$COCKPIT_MAIN_RELATIVE_PATH"
  # Fixture mode is the nested harness's alone: the unit never inherits its variable.
  '[Service]UnsetEnvironment=RESOURCE_PULSE_COCKPIT_FIXTURE'
  '[Service]Restart=on-failure'
  '[Service]RestartSec=5'
  '[Service]Slice=background.slice'
  '[Service]Nice=10'
  '[Service]CPUQuota=10%'
  '[Service]MemoryHigh=64M'
  '[Service]MemoryMax=96M'
)
read_unit_settings "$COCKPIT_UNIT"
check "cockpit.service has a [Unit] and a [Service] section and no [Install], so nothing can ever enable it" \
  "$unit_sections" "[Unit] [Service] "
check "cockpit.service's settings are exactly the design's: Type=dbus on Cockpit1, PartOf, its condition, the fixture variable unset, restart and its limit, caps" \
  "$(sorted_settings "${unit_settings[@]}")" "$(sorted_settings "${EXPECTED_COCKPIT_UNIT_SETTINGS[@]}")"
# Counted over every section, so a second condition anywhere (a stricter or a
# looser one, in [Service] by mistake) shows, and so does the right one missing.
cockpit_condition_count=0; cockpit_exact_condition_count=0
for unit_setting in "${unit_settings[@]}"; do
  [[ "$unit_setting" == *"]$COCKPIT_UNIT_CONDITION_KEY="* ]] && cockpit_condition_count=$((cockpit_condition_count + 1))
  [[ "$unit_setting" == "[Unit]$COCKPIT_UNIT_CONDITION" ]] && cockpit_exact_condition_count=$((cockpit_exact_condition_count + 1))
done
check "cockpit.service has exactly one $COCKPIT_UNIT_CONDITION_KEY, in [Unit], on %E/$COCKPIT_CONFIG_RELATIVE_PATH (\$XDG_CONFIG_HOME, or ~/.config)" \
  "conditions=$cockpit_condition_count exact=$cockpit_exact_condition_count" "conditions=1 exact=1"
check "cockpit.service's ExecStart runs, under $UNIT_INTERPRETER, the checkout's own service/cockpit.js" \
  "${unit_exec_start%% "$UNIT_DOTFILES_PREFIX"*}|$(unit_exec_resolution "$COCKPIT_MAIN_RELATIVE_PATH")" \
  "$UNIT_INTERPRETER|service/cockpit.js"
check_unit_verifies "$COCKPIT_UNIT" 'cockpit.service' \
  "systemd-analyze --user verify accepts cockpit.service (ExecStart pointed at this checkout) and says nothing of it"

printf '\nthe service'"'"'s install wiring\n'
check "install.conf.yaml links the service unit" \
  "$(grep -c -x -F '    ~/.config/systemd/user/resource-pulse.service: systemd/resource-pulse.service' \
    "$DOTFILES/install.conf.yaml")" 1
check "install.conf.yaml links the cockpit unit" \
  "$(grep -c -x -F '    ~/.config/systemd/user/cockpit.service: systemd/cockpit.service' \
    "$DOTFILES/install.conf.yaml")" 1
# Linked and started by the extension, never enabled: no line of ./install or of
# its config (comments aside) may enable either unit.
if [[ -r "$DOTFILES/install" && -r "$DOTFILES/install.conf.yaml" ]]; then
  service_enabling_lines="$(cat "$DOTFILES/install" "$DOTFILES/install.conf.yaml" | grep -v '^[[:space:]]*#' \
    | grep -c -E 'enable.*(resource-pulse|cockpit)')"
else
  service_enabling_lines="install or install.conf.yaml is unreadable"
fi
check "install.conf.yaml runs the refresh step, and nothing in ./install or its config enables either unit" \
  "refresh=$(grep -c -x -F '        bash scripts/resource-pulse-service-refresh.sh' "$DOTFILES/install.conf.yaml") enabling=$service_enabling_lines" \
  "refresh=1 enabling=0"

printf '\nresource-pulse-service-refresh.sh (systemctl stub; never the live user manager)\n'
# Every row runs the script against a recording systemctl stub first on PATH,
# behind the barrier (a dead bus and a private runtime dir, so a real
# systemctl --user could reach no manager), over a fixture extension directory
# whose files carry chosen mtimes. The stub answers only the exact calls the
# script makes; any other call is an error the row sees.
REFRESH_SCRIPT="$DOTFILES/scripts/resource-pulse-service-refresh.sh"
REFRESH_STUB_BIN="$WIRING_TMP/refresh-bin"
REFRESH_NO_SYSTEMCTL_BIN="$WIRING_TMP/refresh-no-systemctl-bin"
REFRESH_CALLS="$WIRING_TMP/refresh-systemctl-calls"
REFRESH_EXTENSION_DIR="$WIRING_TMP/refresh-extension"
# The fixture's own copies of systemd/resource-pulse.service and
# systemd/cockpit.service, with chosen mtimes.
REFRESH_UNIT_FILE="$WIRING_TMP/refresh-unit/resource-pulse.service"
REFRESH_COCKPIT_UNIT_FILE="$WIRING_TMP/refresh-unit/cockpit.service"
UNIT_STARTED_AT_EPOCH=1700000100
BEFORE_START_EPOCH=1700000000
AFTER_START_EPOCH=1700000200
mkdir -p "$REFRESH_NO_SYSTEMCTL_BIN" || fatal "cannot create $REFRESH_NO_SYSTEMCTL_BIN"
# shellcheck disable=SC2016  # The stub's own source: its variables expand when it runs.
install_stub "$REFRESH_STUB_BIN" systemctl '#!/usr/bin/env bash
# Records each call, and answers from the REFRESH_STUB_* variables. cockpit.service
# is inactive unless REFRESH_STUB_COCKPIT_ACTIVE_STATE says otherwise, as for
# anyone without its layout file, whose unit systemd skips.
printf "%s\n" "$*" >>"$REFRESH_CALLS"
case "$*" in
  "--user show-environment") exit "$REFRESH_STUB_MANAGER_EXIT" ;;
  "--user daemon-reload") exit "$REFRESH_STUB_RELOAD_EXIT" ;;
  "--user show resource-pulse.service -p ActiveState --value")
    printf "%s\n" "$REFRESH_STUB_ACTIVE_STATE"
    exit "${REFRESH_STUB_STATE_EXIT:-0}" ;;
  "--user show resource-pulse.service -p ActiveEnterTimestamp --value --timestamp=unix")
    printf "%s\n" "$REFRESH_STUB_STARTED_AT" ;;
  "--user try-restart resource-pulse.service") exit "$REFRESH_STUB_RESTART_EXIT" ;;
  "--user show cockpit.service -p ActiveState --value")
    printf "%s\n" "${REFRESH_STUB_COCKPIT_ACTIVE_STATE:-inactive}" ;;
  "--user show cockpit.service -p ActiveEnterTimestamp --value --timestamp=unix")
    printf "%s\n" "${REFRESH_STUB_COCKPIT_STARTED_AT:-}" ;;
  "--user try-restart cockpit.service") exit "${REFRESH_STUB_COCKPIT_RESTART_EXIT:-0}" ;;
  *) printf "unexpected systemctl call: %s\n" "$*" >&2; exit 64 ;;
esac'
# reset_refresh_extension <service/main.js mtime> <lib/protocol.js mtime> <outside mtime>:
# a fixture extension directory whose service/main.js, lib/protocol.js, and files
# outside service/ and lib/ carry those epoch mtimes ('' leaves that file out).
# Its modules import one another as the real ones do, in small: service/main.js
# imports lib/protocol.js, lib/cadence.js and service/fileIo.js; service/cockpit.js
# (cockpit.service's entry) imports service/fileIo.js and lib/sessions.js;
# extension.js imports lib/protocol.js and lib/visibility.js. All but the three
# chosen are older than the start, and so is the cockpit unit's file.
reset_refresh_extension() {
  rm -rf "$REFRESH_EXTENSION_DIR"
  mkdir -p "$REFRESH_EXTENSION_DIR/lib" "$REFRESH_EXTENSION_DIR/service" || fatal "cannot create $REFRESH_EXTENSION_DIR"
  if [[ -n "$1" ]]; then
    printf '%s\n' "import {PROTOCOL_VERSION} from '../lib/protocol.js';" \
      "import {decideAppScan} from '../lib/cadence.js';" \
      "import {readFileToEnd} from './fileIo.js';" >"$REFRESH_EXTENSION_DIR/service/main.js"
    touch -d "@$1" "$REFRESH_EXTENSION_DIR/service/main.js" || fatal "touch -d @$1 failed"
  fi
  printf '%s\n' "import {readFileToEnd} from './fileIo.js';" \
    "import {buildSessionRows} from '../lib/sessions.js';" >"$REFRESH_EXTENSION_DIR/service/cockpit.js"
  : >"$REFRESH_EXTENSION_DIR/service/fileIo.js"
  : >"$REFRESH_EXTENSION_DIR/lib/sessions.js"
  touch -d "@$BEFORE_START_EPOCH" "$REFRESH_EXTENSION_DIR/service/cockpit.js" "$REFRESH_EXTENSION_DIR/service/fileIo.js" \
    "$REFRESH_EXTENSION_DIR/lib/sessions.js" || fatal "touch -d @$BEFORE_START_EPOCH failed"
  if [[ -n "$2" ]]; then
    : >"$REFRESH_EXTENSION_DIR/lib/protocol.js"
    touch -d "@$2" "$REFRESH_EXTENSION_DIR/lib/protocol.js" || fatal "touch -d @$2 failed"
  fi
  : >"$REFRESH_EXTENSION_DIR/lib/cadence.js"
  : >"$REFRESH_EXTENSION_DIR/lib/visibility.js"
  touch -d "@$BEFORE_START_EPOCH" "$REFRESH_EXTENSION_DIR/lib/cadence.js" "$REFRESH_EXTENSION_DIR/lib/visibility.js" \
    || fatal "touch -d @$BEFORE_START_EPOCH failed"
  printf '%s\n' "import {PROTOCOL_VERSION} from './lib/protocol.js';" \
    "import {isCardCovered} from './lib/visibility.js';" >"$REFRESH_EXTENSION_DIR/extension.js"
  : >"$REFRESH_EXTENSION_DIR/stylesheet.css"
  touch -d "@$3" "$REFRESH_EXTENSION_DIR/extension.js" "$REFRESH_EXTENSION_DIR/stylesheet.css" \
    || fatal "touch -d @$3 failed"
  mkdir -p "${REFRESH_UNIT_FILE%/*}" || fatal "cannot create ${REFRESH_UNIT_FILE%/*}"
  : >"$REFRESH_UNIT_FILE"
  : >"$REFRESH_COCKPIT_UNIT_FILE"
  touch -d "@$BEFORE_START_EPOCH" "$REFRESH_UNIT_FILE" "$REFRESH_COCKPIT_UNIT_FILE" \
    || fatal "touch -d @$BEFORE_START_EPOCH failed"
}
# refresh_extension_with_change <module>: the fixture with every file older than
# the unit's start but that one module, which is newer.
refresh_extension_with_change() {
  reset_refresh_extension "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH"
  touch -d "@$AFTER_START_EPOCH" "$REFRESH_EXTENSION_DIR/$1" || fatal "touch -d @$AFTER_START_EPOCH failed"
}
# run_refresh <manager exit> <reload exit> <ActiveState> <ActiveEnterTimestamp> <try-restart exit> [stub bin]
# prints "exit=<n> calls=[<call>;...] output=[<stdout+stderr>]". The arguments
# answer for resource-pulse.service; cockpit.service answers from the
# REFRESH_STUB_COCKPIT_* variables of the caller's environment (inactive without).
run_refresh() {
  local refresh_output refresh_exit stub_bin="${6:-$REFRESH_STUB_BIN}"
  : >"$REFRESH_CALLS"
  refresh_output="$(env "${LIVE_SETTINGS_BARRIER[@]}" PATH="$stub_bin:$PATH" REFRESH_CALLS="$REFRESH_CALLS" \
    REFRESH_STUB_MANAGER_EXIT="$1" REFRESH_STUB_RELOAD_EXIT="$2" REFRESH_STUB_ACTIVE_STATE="$3" \
    REFRESH_STUB_STARTED_AT="$4" REFRESH_STUB_RESTART_EXIT="$5" \
    RESOURCE_PULSE_EXTENSION_DIR="$REFRESH_EXTENSION_DIR" RESOURCE_PULSE_UNIT_FILE="$REFRESH_UNIT_FILE" \
    RESOURCE_PULSE_COCKPIT_UNIT_FILE="$REFRESH_COCKPIT_UNIT_FILE" \
    "$BASH" "$REFRESH_SCRIPT" 2>&1)"
  refresh_exit=$?
  printf 'exit=%s calls=[%s] output=[%s]' "$refresh_exit" "$(tr '\n' ';' <"$REFRESH_CALLS")" "$refresh_output"
}
STARTED_AT="@$UNIT_STARTED_AT_EPOCH"
# warnings_naming <summary> <step>: how many ⚠ lines of a run name that step.
warnings_naming() { grep -F '⚠' <<<"$1" | grep -c -F "$2"; }
# Each unit's calls in the order the script makes them: its state, then (active)
# its start time, then (changed) its try-restart; resource-pulse.service first.
REFRESH_PREAMBLE_CALLS='--user show-environment;--user daemon-reload;'
SAMPLER_STATE_CALL='--user show resource-pulse.service -p ActiveState --value;'
SAMPLER_START_TIME_CALL='--user show resource-pulse.service -p ActiveEnterTimestamp --value --timestamp=unix;'
SAMPLER_RESTART_CALL='--user try-restart resource-pulse.service;'
COCKPIT_STATE_CALL='--user show cockpit.service -p ActiveState --value;'
COCKPIT_START_TIME_CALL='--user show cockpit.service -p ActiveEnterTimestamp --value --timestamp=unix;'
COCKPIT_RESTART_CALL='--user try-restart cockpit.service;'
# The sampler's rows below leave cockpit.service inactive, so each run that gets
# past the reload ends with its one state call, and says nothing of it.
CALLS_UP_TO_STATE="$REFRESH_PREAMBLE_CALLS$SAMPLER_STATE_CALL$COCKPIT_STATE_CALL"
CALLS_UP_TO_START_TIME="$REFRESH_PREAMBLE_CALLS$SAMPLER_STATE_CALL$SAMPLER_START_TIME_CALL$COCKPIT_STATE_CALL"
CALLS_WITH_RESTART="$REFRESH_PREAMBLE_CALLS$SAMPLER_STATE_CALL$SAMPLER_START_TIME_CALL$SAMPLER_RESTART_CALL$COCKPIT_STATE_CALL"

reset_refresh_extension "$AFTER_START_EPOCH" "$AFTER_START_EPOCH" "$AFTER_START_EPOCH"
check "refresh: no user manager (a server) is silent and exits 0, asking nothing more" \
  "$(run_refresh 1 0 active "$STARTED_AT" 0)" "exit=0 calls=[--user show-environment;] output=[]"
# Without systemctl on PATH at all (a container): the script is run by bash's own path, so PATH can be empty of tools.
no_systemctl_output="$(env "${LIVE_SETTINGS_BARRIER[@]}" PATH="$REFRESH_NO_SYSTEMCTL_BIN" \
  RESOURCE_PULSE_EXTENSION_DIR="$REFRESH_EXTENSION_DIR" "$BASH" "$REFRESH_SCRIPT" 2>&1)"
no_systemctl_exit=$?
check "refresh: no systemctl at all (a container) is silent and exits 0" \
  "exit=$no_systemctl_exit output=[$no_systemctl_output]" "exit=0 output=[]"
refresh_not_active_summary=""
for refresh_active_state in inactive failed activating; do
  refresh_not_active_summary+="$refresh_active_state:$(run_refresh 0 0 "$refresh_active_state" "$STARTED_AT" 0) "
done
check "refresh: a unit not active (inactive, failed, activating) is reloaded for, then left alone, silently" \
  "$refresh_not_active_summary" \
  "inactive:exit=0 calls=[$CALLS_UP_TO_STATE] output=[] failed:exit=0 calls=[$CALLS_UP_TO_STATE] output=[] activating:exit=0 calls=[$CALLS_UP_TO_STATE] output=[] "
reset_refresh_extension "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH"
check "refresh: an active unit with nothing in its import closure changed since it started is left alone, silently" \
  "$(run_refresh 0 0 active "$STARTED_AT" 0)" "exit=0 calls=[$CALLS_UP_TO_START_TIME] output=[]"
reset_refresh_extension "$AFTER_START_EPOCH" "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH"
service_changed_summary="$(run_refresh 0 0 active "$STARTED_AT" 0)"
reset_refresh_extension "$BEFORE_START_EPOCH" "$AFTER_START_EPOCH" "$BEFORE_START_EPOCH"
lib_changed_summary="$(run_refresh 0 0 active "$STARTED_AT" 0)"
check "refresh: a file in the unit's import closure newer than the unit's start try-restarts it, after the reload, and says so" \
  "service:${service_changed_summary%% output=*} $(grep -c -F 'restarted' <<<"$service_changed_summary") lib:${lib_changed_summary%% output=*} $(grep -c -F 'restarted' <<<"$lib_changed_summary")" \
  "service:exit=0 calls=[$CALLS_WITH_RESTART] 1 lib:exit=0 calls=[$CALLS_WITH_RESTART] 1"
reset_refresh_extension "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH" "$AFTER_START_EPOCH"
check "refresh: a change outside service/ and lib/ (the drawing side) never restarts it, so the histories survive" \
  "$(run_refresh 0 0 active "$STARTED_AT" 0)" "exit=0 calls=[$CALLS_UP_TO_START_TIME] output=[]"
# Only the modules the service runs count (ruling R23): service/main.js and what
# it imports, whether the service alone imports a module or both sides do.
refresh_by_side_summary=""
for changed_module in lib/cadence.js lib/visibility.js lib/protocol.js; do
  refresh_extension_with_change "$changed_module"
  refresh_side_run="$(run_refresh 0 0 active "$STARTED_AT" 0)"
  refresh_by_side_summary+="$changed_module:${refresh_side_run%% output=*} "
done
check "refresh: a module only the service runs (lib/cadence.js) or a shared one (lib/protocol.js) restarts it; one only the shell runs (lib/visibility.js) does not" \
  "$refresh_by_side_summary" \
  "lib/cadence.js:exit=0 calls=[$CALLS_WITH_RESTART] lib/visibility.js:exit=0 calls=[$CALLS_UP_TO_START_TIME] lib/protocol.js:exit=0 calls=[$CALLS_WITH_RESTART] "
reset_refresh_extension "$UNIT_STARTED_AT_EPOCH" "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH"
same_second_summary="$(run_refresh 0 0 active "$STARTED_AT" 0)"
reset_refresh_extension "$((UNIT_STARTED_AT_EPOCH + 1))" "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH"
next_second_summary="$(run_refresh 0 0 active "$STARTED_AT" 0)"
check "refresh: a file last changed exactly at the unit's start is not newer; one second later is" \
  "same:${same_second_summary%% output=*} next:${next_second_summary%% output=*}" \
  "same:exit=0 calls=[$CALLS_UP_TO_START_TIME] next:exit=0 calls=[$CALLS_WITH_RESTART]"
reset_refresh_extension "$AFTER_START_EPOCH" "$AFTER_START_EPOCH" "$AFTER_START_EPOCH"
reload_failed_summary="$(run_refresh 0 1 active "$STARTED_AT" 0)"
# Every failure below warns with a ⚠ line naming the step, restarts nothing, and
# still returns 0: under `set -e` an exit 1 would abort the rest of ./install
# for every desktop user (ruling R12; reconcile-systemd-units.sh does the same).
# The reload is one step for both units, so its one line names both.
check "refresh: a failed daemon-reload warns once, naming it and both units, restarts nothing and returns 0" \
  "${reload_failed_summary%% output=*} warned=$(warnings_naming "$reload_failed_summary" daemon-reload) names-both=$(grep -c -F '⚠ resource-pulse.service, cockpit.service: daemon-reload failed' <<<"$reload_failed_summary")" \
  "exit=0 calls=[$REFRESH_PREAMBLE_CALLS] warned=1 names-both=1"
# A state that cannot be read must not pass for "not active", which is silent.
state_unreadable_summary="$(REFRESH_STUB_STATE_EXIT=1 run_refresh 0 0 active "$STARTED_AT" 0)"
check "refresh: a state it cannot read warns, naming it, restarts nothing and returns 0" \
  "${state_unreadable_summary%% output=*} warned=$(warnings_naming "$state_unreadable_summary" ActiveState)" \
  "exit=0 calls=[$CALLS_UP_TO_STATE] warned=1"
unreadable_start_summary=""
UNREADABLE_START_TIMES=('' 'n/a' '@' '@12x')
for unreadable_started_at in "${UNREADABLE_START_TIMES[@]}"; do
  unreadable_summary="$(run_refresh 0 0 active "$unreadable_started_at" 0)"
  unreadable_start_summary+="${unreadable_summary%% output=*} warned=$(warnings_naming "$unreadable_summary" ActiveEnterTimestamp) "
done
expected_unreadable_start_summary=""
for _ in "${UNREADABLE_START_TIMES[@]}"; do
  expected_unreadable_start_summary+="exit=0 calls=[$CALLS_UP_TO_START_TIME] warned=1 "
done
check "refresh: an active unit whose start time cannot be parsed warns, naming it, restarts nothing, returns 0" \
  "$unreadable_start_summary" "$expected_unreadable_start_summary"
restart_failed_summary="$(run_refresh 0 0 active "$STARTED_AT" 1)"
check "refresh: a failed try-restart warns, naming it, and returns 0" \
  "${restart_failed_summary%% output=*} warned=$(warnings_naming "$restart_failed_summary" try-restart)" \
  "exit=0 calls=[$CALLS_WITH_RESTART] warned=1"
# The unit file counts too: after the daemon-reload has loaded a newer one, its
# [Service] settings (a cap, the ExecStart) apply only from the next start. A
# missing one, beside a newer module, is a search that failed: a partial answer
# never decides a restart.
unit_file_summary=""
reset_refresh_extension "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH"
touch -d "@$AFTER_START_EPOCH" "$REFRESH_UNIT_FILE" || fatal "touch -d @$AFTER_START_EPOCH failed"
unit_file_run="$(run_refresh 0 0 active "$STARTED_AT" 0)"
unit_file_summary+="newer:${unit_file_run%% output=*} said=$(grep -c -F 'restarted: its unit file changed since it started' <<<"$unit_file_run")"
reset_refresh_extension "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH"
unit_file_run="$(run_refresh 0 0 active "$STARTED_AT" 0)"
unit_file_summary+=" older:${unit_file_run%% output=*}"
reset_refresh_extension "$BEFORE_START_EPOCH" "$AFTER_START_EPOCH" "$BEFORE_START_EPOCH"
rm -f "$REFRESH_UNIT_FILE"
unit_file_run="$(run_refresh 0 0 active "$STARTED_AT" 0)"
unit_file_summary+=" missing:${unit_file_run%% output=*} warned=$(warnings_naming "$unit_file_run" 'cannot search')"
check "refresh: a unit file newer than the unit's start try-restarts it, after the reload, and says so; an older one does not; a missing one warns and restarts nothing, though a module changed" \
  "$unit_file_summary" \
  "newer:exit=0 calls=[$CALLS_WITH_RESTART] said=1 older:exit=0 calls=[$CALLS_UP_TO_START_TIME] missing:exit=0 calls=[$CALLS_UP_TO_START_TIME] warned=1"
# service/main.js missing while lib/ holds a newer module: which modules the
# service runs cannot be worked out, and a partial answer must never decide a
# restart.
reset_refresh_extension '' "$AFTER_START_EPOCH" "$BEFORE_START_EPOCH"
unlistable_summary="$(run_refresh 0 0 active "$STARTED_AT" 0)"
check "refresh: when it cannot work out which modules the service runs (service/main.js missing, a newer lib/ module beside it), it warns, naming that, restarts nothing and returns 0" \
  "${unlistable_summary%% output=*} warned=$(warnings_naming "$unlistable_summary" 'cannot work out which modules it runs')" \
  "exit=0 calls=[$CALLS_UP_TO_START_TIME] warned=1"
# A find that warns on stderr yet succeeds, listing nothing: its warning must
# reach the terminal, and never be read as a changed file.
REFRESH_FIND_WARNING_BIN="$WIRING_TMP/refresh-find-warning-bin"
install_stub "$REFRESH_FIND_WARNING_BIN" find '#!/usr/bin/env bash
printf "find: warning: a stand-in warning on stderr\n" >&2
exit 0'
reset_refresh_extension "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH"
find_warning_summary="$(run_refresh 0 0 active "$STARTED_AT" 0 "$REFRESH_FIND_WARNING_BIN:$REFRESH_STUB_BIN")"
check "refresh: a warning find prints on stderr while succeeding is shown, and never read as a changed file" \
  "${find_warning_summary%% output=*} shown=$(grep -c -F 'stand-in warning' <<<"$find_warning_summary")" \
  "exit=0 calls=[$CALLS_UP_TO_START_TIME] shown=1"

# cockpit.service is the step's second unit: its own entry (service/cockpit.js),
# its own closure and its own unit file, decided alone after the one reload, and
# every line names its unit. A module both closures hold (service/fileIo.js)
# restarts both; one only the sampler runs never restarts the cockpit, nor the
# reverse.
# run_refresh_both_active [sampler state exit] [cockpit start time]: both units
# active since UNIT_STARTED_AT_EPOCH, every call succeeding.
run_refresh_both_active() {
  REFRESH_STUB_STATE_EXIT="${1:-0}" REFRESH_STUB_COCKPIT_ACTIVE_STATE=active \
    REFRESH_STUB_COCKPIT_STARTED_AT="${2:-$STARTED_AT}" run_refresh 0 0 active "$STARTED_AT" 0
}
SAMPLER_CHECKED_CALLS="$SAMPLER_STATE_CALL$SAMPLER_START_TIME_CALL"
COCKPIT_CHECKED_CALLS="$COCKPIT_STATE_CALL$COCKPIT_START_TIME_CALL"
CALLS_BOTH_UNCHANGED="$REFRESH_PREAMBLE_CALLS$SAMPLER_CHECKED_CALLS$COCKPIT_CHECKED_CALLS"
CALLS_COCKPIT_RESTARTED="$REFRESH_PREAMBLE_CALLS$SAMPLER_CHECKED_CALLS$COCKPIT_CHECKED_CALLS$COCKPIT_RESTART_CALL"
CALLS_SAMPLER_RESTARTED="$REFRESH_PREAMBLE_CALLS$SAMPLER_CHECKED_CALLS$SAMPLER_RESTART_CALL$COCKPIT_CHECKED_CALLS"
CALLS_BOTH_RESTARTED="$REFRESH_PREAMBLE_CALLS$SAMPLER_CHECKED_CALLS$SAMPLER_RESTART_CALL$COCKPIT_CHECKED_CALLS$COCKPIT_RESTART_CALL"
# restart_lines <summary>: the ✓ lines of a run's output (what follows
# "output=[", its closing bracket dropped), joined by |.
restart_lines() {
  local run_output="${1#* output=\[}"
  grep -F '✓' <<<"${run_output%]}" | tr '\n' '|'
}
COCKPIT_ENTRY_RESTART_LINE='  ✓ cockpit.service restarted: service/cockpit.js changed since it started|'
SAMPLER_ENTRY_RESTART_LINE='  ✓ resource-pulse.service restarted: service/main.js changed since it started (its histories start again)|'
reset_refresh_extension "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH"
both_unchanged_run="$(run_refresh_both_active)"
check "refresh: both units active and nothing changed since their starts: one reload, both checked, neither restarted, nothing said" \
  "${both_unchanged_run%% output=*} said=[$(restart_lines "$both_unchanged_run")]" \
  "exit=0 calls=[$CALLS_BOTH_UNCHANGED] said=[]"
refresh_extension_with_change service/cockpit.js
cockpit_entry_changed_run="$(run_refresh_both_active)"
check "refresh: service/cockpit.js newer than cockpit.service's start try-restarts cockpit.service and leaves resource-pulse.service alone, in a line naming cockpit.service" \
  "${cockpit_entry_changed_run%% output=*} said=[$(restart_lines "$cockpit_entry_changed_run")]" \
  "exit=0 calls=[$CALLS_COCKPIT_RESTARTED] said=[$COCKPIT_ENTRY_RESTART_LINE]"
refresh_extension_with_change service/main.js
sampler_entry_changed_run="$(run_refresh_both_active)"
check "refresh: service/main.js newer than resource-pulse.service's start try-restarts it and leaves an active cockpit.service alone" \
  "${sampler_entry_changed_run%% output=*} said=[$(restart_lines "$sampler_entry_changed_run")]" \
  "exit=0 calls=[$CALLS_SAMPLER_RESTARTED] said=[$SAMPLER_ENTRY_RESTART_LINE]"
refresh_by_closure_summary=""
for changed_module in service/fileIo.js lib/sessions.js lib/cadence.js; do
  refresh_extension_with_change "$changed_module"
  refresh_closure_run="$(run_refresh_both_active)"
  refresh_by_closure_summary+="$changed_module:${refresh_closure_run%% output=*} "
done
reset_refresh_extension "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH"
touch -d "@$AFTER_START_EPOCH" "$REFRESH_COCKPIT_UNIT_FILE" || fatal "touch -d @$AFTER_START_EPOCH failed"
refresh_closure_run="$(run_refresh_both_active)"
refresh_by_closure_summary+="cockpit-unit-file:${refresh_closure_run%% output=*} said=[$(restart_lines "$refresh_closure_run")]"
check "refresh: a module both run (service/fileIo.js) restarts both units; one only the cockpit runs (lib/sessions.js), or cockpit.service's own unit file, restarts only it; one only the sampler runs (lib/cadence.js) only the sampler" \
  "$refresh_by_closure_summary" \
  "service/fileIo.js:exit=0 calls=[$CALLS_BOTH_RESTARTED] lib/sessions.js:exit=0 calls=[$CALLS_COCKPIT_RESTARTED] lib/cadence.js:exit=0 calls=[$CALLS_SAMPLER_RESTARTED] cockpit-unit-file:exit=0 calls=[$CALLS_COCKPIT_RESTARTED] said=[  ✓ cockpit.service restarted: its unit file changed since it started|]"
# Without ~/.config/resource-pulse/cockpit.json, systemd skips cockpit.service
# on its condition and reports it inactive: however new its code, the step
# leaves it alone and says nothing of it, while the sampler is still decided.
reset_refresh_extension "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH" "$BEFORE_START_EPOCH"
touch -d "@$AFTER_START_EPOCH" "$REFRESH_EXTENSION_DIR/service/cockpit.js" "$REFRESH_COCKPIT_UNIT_FILE" \
  || fatal "touch -d @$AFTER_START_EPOCH failed"
check "refresh: an inactive (condition-skipped) cockpit.service, with newer code and unit file, is left alone, silently, after the sampler is decided" \
  "$(run_refresh 0 0 active "$STARTED_AT" 0)" "exit=0 calls=[$REFRESH_PREAMBLE_CALLS$SAMPLER_CHECKED_CALLS$COCKPIT_STATE_CALL] output=[]"
# A failure on one unit warns naming that unit, and the other is still decided.
refresh_failure_isolation_summary=""
refresh_extension_with_change service/cockpit.js
refresh_isolation_run="$(run_refresh_both_active 1)"
refresh_failure_isolation_summary+="sampler-state-unreadable:${refresh_isolation_run%% output=*} warned=$(grep -c -F '⚠ resource-pulse.service: cannot read its state' <<<"$refresh_isolation_run") said=[$(restart_lines "$refresh_isolation_run")]"
refresh_extension_with_change service/main.js
refresh_isolation_run="$(run_refresh_both_active 0 'n/a')"
refresh_failure_isolation_summary+=" cockpit-start-unparseable:${refresh_isolation_run%% output=*} warned=$(grep -c -F '⚠ cockpit.service: cannot parse when it started' <<<"$refresh_isolation_run") said=[$(restart_lines "$refresh_isolation_run")]"
check "refresh: a failure deciding one unit warns in a line naming that unit, and the other is still decided and restarted" \
  "$refresh_failure_isolation_summary" \
  "sampler-state-unreadable:exit=0 calls=[$REFRESH_PREAMBLE_CALLS$SAMPLER_STATE_CALL$COCKPIT_CHECKED_CALLS$COCKPIT_RESTART_CALL] warned=1 said=[$COCKPIT_ENTRY_RESTART_LINE] cockpit-start-unparseable:exit=0 calls=[$CALLS_SAMPLER_RESTARTED] warned=1 said=[$SAMPLER_ENTRY_RESTART_LINE]"

printf '\nresource-pulse-cost.sh (fake PROC_ROOT)\n'
# make_fake_proc <root> <pid> <comm> <vmrss_kib> builds one process entry. Its
# stat carries clock ticks (utime 100, stime 50), which the cost script must
# never read for CPU: reading them, or falling back to them, gives a reading
# where a row expects a different one or exit 2.
make_fake_proc() {
  mkdir -p "$1/$2"
  printf '%s\n' "$3" >"$1/$2/comm"
  printf 'Name:\t%s\nVmRSS:\t%s kB\n' "$3" "$4" >"$1/$2/status"
  printf '%s (%s) S 1 1 1 0 -1 0 0 0 0 0 100 50 0 0 20 0 1 0 1 0 0\n' "$2" "$3" >"$1/$2/stat"
}
# write_fake_schedstat <root> <pid> <tid> <line> writes one thread's <root>/<pid>/task/<tid>/schedstat: the
# scheduler's time on a CPU (ns), time waiting (ns) and timeslices.
write_fake_schedstat() {
  mkdir -p "$1/$2/task/$3" && printf '%s\n' "$4" >"$1/$2/task/$3/schedstat"
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

# CPU comes from the scheduler's own nanosecond counters, one per thread
# (<proc>/<pid>/task/<tid>/schedstat, first field), never from stat's clock
# ticks. `sleep` is a stub on PATH: it records each call's argument and, on its
# Nth call, copies <steps dir>/<N>/ over the fake proc root, as that much of the
# window would move the counters on.
COST_STUB_BIN="$WIRING_TMP/cost-bin"
COST_SLEEP_CALLS="$WIRING_TMP/cost-sleep-calls"
COST_WINDOW_SECONDS=2
# shellcheck disable=SC2016  # The stub's own source: its variables expand when it runs.
install_stub "$COST_STUB_BIN" sleep '#!/usr/bin/env bash
printf "%s\n" "$*" >>"$COST_SLEEP_CALLS"
sleep_call_number=$(( $(wc -l <"$COST_SLEEP_CALLS") ))
step_dir="$COST_SLEEP_STEPS/$sleep_call_number"
if [[ -d "$step_dir" ]]; then cp -R "$step_dir/." "$COST_SLEEP_PROC_ROOT/"; fi'
# cost_steps_run <proc root> <steps dir> <args...> runs the cost script against
# a fake proc root (GNOME_SHELL_PID names its gnome-shell, 4242), the sleep stub
# moving it through the steps; leaves COST_OUTPUT, COST_EXIT and the sleep calls.
cost_steps_run() {
  local proc_root="$1" steps_dir="$2"
  shift 2
  : >"$COST_SLEEP_CALLS"
  COST_OUTPUT="$(PATH="$COST_STUB_BIN:$PATH" GNOME_SHELL_PID=4242 PROC_ROOT="$proc_root" \
    COST_SLEEP_CALLS="$COST_SLEEP_CALLS" COST_SLEEP_STEPS="$steps_dir" COST_SLEEP_PROC_ROOT="$proc_root" \
    bash "$COST_SCRIPT" "$@" 2>&1)"
  COST_EXIT=$?
}
# --cpu-percent over a fake window, two threads: 4 ms and 6 ms on a CPU before,
# each 5 ms more after, so 10 ms over 2 s is 0.500% of one core (one thread
# alone reads 0.250). The other two fields (time waiting, timeslices) move by
# other amounts, so reading the wrong field gives another number.
CPU_PROC_ROOT="$WIRING_TMP/proc-cpu"
CPU_SLEEP_STEPS="$WIRING_TMP/cost-cpu-steps"
make_fake_proc "$CPU_PROC_ROOT" 4242 gnome-shell "$FAKE_SHELL_RSS_KIB"
write_fake_schedstat "$CPU_PROC_ROOT" 4242 4242 '4000000 0 1'
write_fake_schedstat "$CPU_PROC_ROOT" 4242 4243 '6000000 0 1'
write_fake_schedstat "$CPU_SLEEP_STEPS/1" 4242 4242 '9000000 3000000 4'
write_fake_schedstat "$CPU_SLEEP_STEPS/1" 4242 4243 '11000000 8000000 9'
cost_steps_run "$CPU_PROC_ROOT" "$CPU_SLEEP_STEPS" --cpu-percent "$COST_WINDOW_SECONDS"
check "cost: --cpu-percent is every thread's Δ schedstat time on a CPU (ns) / the window × 100, over the window it was given" \
  "exit=$COST_EXIT percent=$COST_OUTPUT slept=$(tr '\n' ' ' <"$COST_SLEEP_CALLS")" \
  "exit=0 percent=0.500 slept=$COST_WINDOW_SECONDS "

# --tick-median reads the main thread (its tid is the pid) once a tick, at the
# extension's SAMPLE_INTERVAL_SECONDS (read here from lib/constants.js, so the
# cost script's copy of it cannot drift unseen), and prints the median of its
# CPU per tick in ms. Five ticks of 3, 1, 40 (a collection), 1.5 and 2.5 ms: the
# median is 2.50 and the mean 9.60; the other thread's 100 ms a tick shows if
# every thread were read. A window under one tick is a usage error.
SAMPLE_INTERVAL_SECONDS_IN_CONSTANTS="$(sed -n 's/^export const SAMPLE_INTERVAL_SECONDS = \([0-9][0-9]*\);$/\1/p' \
  "$EXT_DIR/lib/constants.js" 2>/dev/null)"
[[ "$SAMPLE_INTERVAL_SECONDS_IN_CONSTANTS" =~ ^[1-9][0-9]*$ ]] \
  || fatal "cannot read SAMPLE_INTERVAL_SECONDS from $EXT_DIR/lib/constants.js"
TICK_PROC_ROOT="$WIRING_TMP/proc-tick"
TICK_SLEEP_STEPS="$WIRING_TMP/cost-tick-steps"
TICK_MAIN_THREAD_NANOSECONDS=(3000000 1000000 40000000 1500000 2500000)
TICK_OTHER_THREAD_NANOSECONDS=100000000
make_fake_proc "$TICK_PROC_ROOT" 4242 gnome-shell "$FAKE_SHELL_RSS_KIB"
write_fake_schedstat "$TICK_PROC_ROOT" 4242 4242 '1000000 0 1'
write_fake_schedstat "$TICK_PROC_ROOT" 4242 4243 '0 0 1'
tick_main_thread_total=1000000
tick_other_thread_total=0
expected_tick_sleeps=""
for tick_index in "${!TICK_MAIN_THREAD_NANOSECONDS[@]}"; do
  tick_main_thread_total=$((tick_main_thread_total + TICK_MAIN_THREAD_NANOSECONDS[tick_index]))
  tick_other_thread_total=$((tick_other_thread_total + TICK_OTHER_THREAD_NANOSECONDS))
  write_fake_schedstat "$TICK_SLEEP_STEPS/$((tick_index + 1))" 4242 4242 "$tick_main_thread_total 0 1"
  write_fake_schedstat "$TICK_SLEEP_STEPS/$((tick_index + 1))" 4242 4243 "$tick_other_thread_total 0 1"
  expected_tick_sleeps+="$SAMPLE_INTERVAL_SECONDS_IN_CONSTANTS "
done
tick_window_seconds=$(( ${#TICK_MAIN_THREAD_NANOSECONDS[@]} * SAMPLE_INTERVAL_SECONDS_IN_CONSTANTS ))
cost_steps_run "$TICK_PROC_ROOT" "$TICK_SLEEP_STEPS" --tick-median "$tick_window_seconds"
tick_median_summary="exit=$COST_EXIT median=$COST_OUTPUT slept=$(tr '\n' ' ' <"$COST_SLEEP_CALLS")"
# An even count, as perf's 30 ticks are: the first four ticks, 3, 1, 40 and 1.5 ms, sort to 1, 1.5, 3, 40, and the
# script reports the UPPER of the two middle ones, 3.00 (the lower would be 1.50, their mean 2.25).
write_fake_schedstat "$TICK_PROC_ROOT" 4242 4242 '1000000 0 1'
write_fake_schedstat "$TICK_PROC_ROOT" 4242 4243 '0 0 1'
cost_steps_run "$TICK_PROC_ROOT" "$TICK_SLEEP_STEPS" --tick-median $(( 4 * SAMPLE_INTERVAL_SECONDS_IN_CONSTANTS ))
tick_median_summary+=" even-count=$COST_EXIT/$COST_OUTPUT"
cost_steps_run "$TICK_PROC_ROOT" "$TICK_SLEEP_STEPS" --tick-median $((SAMPLE_INTERVAL_SECONDS_IN_CONSTANTS - 1))
tick_median_summary+=" under-one-tick=$COST_EXIT/$(grep -c -F 'needs at least one tick' <<<"$COST_OUTPUT")"
check "cost: --tick-median prints the median ms of the main thread's CPU per tick, read every SAMPLE_INTERVAL_SECONDS of lib/constants.js; under one tick is a usage error" \
  "$tick_median_summary" "exit=0 median=2.50 slept=$expected_tick_sleeps even-count=0/3.00 under-one-tick=2/1"

# A counter that cannot be read is exit 2, never a reading of 0: a thread
# listed with no schedstat (a kernel that keeps none), a process with no task
# directory, and a first field that is not a number, in both modes. Each case
# prints its exit and whether any number came out.
MISSING_SCHEDSTAT_PROC_ROOT="$WIRING_TMP/proc-no-schedstat"
NO_TASK_DIR_PROC_ROOT="$WIRING_TMP/proc-no-task-dir"
MALFORMED_SCHEDSTAT_PROC_ROOT="$WIRING_TMP/proc-malformed-schedstat"
NO_COST_STEPS="$WIRING_TMP/cost-no-steps"
make_fake_proc "$MISSING_SCHEDSTAT_PROC_ROOT" 4242 gnome-shell "$FAKE_SHELL_RSS_KIB"
mkdir -p "$MISSING_SCHEDSTAT_PROC_ROOT/4242/task/4242"
write_fake_schedstat "$MISSING_SCHEDSTAT_PROC_ROOT" 4242 4243 '6000000 0 1'
make_fake_proc "$NO_TASK_DIR_PROC_ROOT" 4242 gnome-shell "$FAKE_SHELL_RSS_KIB"
make_fake_proc "$MALFORMED_SCHEDSTAT_PROC_ROOT" 4242 gnome-shell "$FAKE_SHELL_RSS_KIB"
write_fake_schedstat "$MALFORMED_SCHEDSTAT_PROC_ROOT" 4242 4242 'n/a 0 1'
# unreadable_counter_verdict <proc root> <mode> prints exit/no-reading, or exit/the reading it printed.
unreadable_counter_verdict() {
  cost_steps_run "$1" "$NO_COST_STEPS" "$2" "$COST_WINDOW_SECONDS"
  if grep -q -E '^[0-9]+(\.[0-9]+)?$' <<<"$COST_OUTPUT"; then
    printf '%s/reading-%s' "$COST_EXIT" "$(grep -E '^[0-9]+(\.[0-9]+)?$' <<<"$COST_OUTPUT" | head -n 1)"
  else
    printf '%s/no-reading' "$COST_EXIT"
  fi
}
unreadable_counter_summary=""
for unreadable_mode in --cpu-percent --tick-median; do
  unreadable_counter_summary+="${unreadable_mode#--}:"
  unreadable_counter_summary+=" no-schedstat=$(unreadable_counter_verdict "$MISSING_SCHEDSTAT_PROC_ROOT" \
    "$unreadable_mode")"
  unreadable_counter_summary+=" no-task-dir=$(unreadable_counter_verdict "$NO_TASK_DIR_PROC_ROOT" "$unreadable_mode")"
  unreadable_counter_summary+=" malformed=$(unreadable_counter_verdict "$MALFORMED_SCHEDSTAT_PROC_ROOT" \
    "$unreadable_mode") "
done
check "cost: a schedstat that is missing, a process with no task dir and a counter that is not a number are exit 2 in both modes, never a reading" \
  "$unreadable_counter_summary" \
  "cpu-percent: no-schedstat=2/no-reading no-task-dir=2/no-reading malformed=2/no-reading tick-median: no-schedstat=2/no-reading no-task-dir=2/no-reading malformed=2/no-reading "

# --service measures the sampler service the same way, found by its unit's
# MainPID: a systemctl stub answers that one property and records the call,
# behind the barrier, so no real user manager is ever asked. The fake root
# holds a gnome-shell too, named by GNOME_SHELL_PID, which --service must never
# measure. The service's main thread goes from 10 ms to 28 ms on a CPU: 18 ms
# over 2 s is 0.900% of one core; gnome-shell's moves by 50 ms (2.500%), so
# measuring it instead shows.
SERVICE_PROC_ROOT="$WIRING_TMP/proc-service"
SERVICE_SLEEP_STEPS="$WIRING_TMP/cost-service-steps"
FAKE_SERVICE_PID=5151
FAKE_SERVICE_RSS_KIB=52000
SERVICE_UNIT_NAME="resource-pulse.service"
FAKE_SCHEDSTAT_BEFORE='10000000 0 1'
make_fake_proc "$SERVICE_PROC_ROOT" 4242 gnome-shell "$FAKE_SHELL_RSS_KIB"
make_fake_proc "$SERVICE_PROC_ROOT" "$FAKE_SERVICE_PID" gjs "$FAKE_SERVICE_RSS_KIB"
write_fake_schedstat "$SERVICE_SLEEP_STEPS/1" "$FAKE_SERVICE_PID" "$FAKE_SERVICE_PID" '28000000 4000000 7'
write_fake_schedstat "$SERVICE_SLEEP_STEPS/1" 4242 4242 '60000000 9000000 11'
COST_SYSTEMCTL_STUB_BIN="$WIRING_TMP/cost-systemctl-bin"
COST_SYSTEMCTL_CALLS="$WIRING_TMP/cost-systemctl-calls"
# shellcheck disable=SC2016  # The stub's own source: its variables expand when it runs.
install_stub "$COST_SYSTEMCTL_STUB_BIN" systemctl '#!/usr/bin/env bash
printf "%s\n" "$*" >>"$COST_SYSTEMCTL_CALLS"
case "$*" in
  "--user show -p MainPID --value resource-pulse.service") printf "%s\n" "$COST_SERVICE_MAIN_PID" ;;
  "--user show -p MainPID --value cockpit.service") printf "%s\n" "${COST_COCKPIT_MAIN_PID:-0}" ;;
  *) printf "unexpected systemctl call: %s\n" "$*" >&2; exit 64 ;;
esac
exit "${COST_SYSTEMCTL_EXIT:-0}"'
# cost_service_run <MainPID answer> <args...> [-- with COST_SYSTEMCTL_EXIT in the
# caller's environment]; leaves COST_OUTPUT, COST_EXIT and the systemctl calls.
# Each run starts the service's and gnome-shell's counters from "before", which
# the sleep stub moves on.
cost_service_run() {
  local main_pid_answer="$1"
  shift
  if ! write_fake_schedstat "$SERVICE_PROC_ROOT" "$FAKE_SERVICE_PID" "$FAKE_SERVICE_PID" "$FAKE_SCHEDSTAT_BEFORE" ||
    ! write_fake_schedstat "$SERVICE_PROC_ROOT" 4242 4242 "$FAKE_SCHEDSTAT_BEFORE"; then
    fatal "cannot reset the fake service's and gnome-shell's schedstat"
  fi
  : >"$COST_SYSTEMCTL_CALLS"
  : >"$COST_SLEEP_CALLS"
  COST_OUTPUT="$(env "${LIVE_SETTINGS_BARRIER[@]}" PATH="$COST_STUB_BIN:$COST_SYSTEMCTL_STUB_BIN:$PATH" \
    GNOME_SHELL_PID=4242 PROC_ROOT="$SERVICE_PROC_ROOT" COST_SYSTEMCTL_CALLS="$COST_SYSTEMCTL_CALLS" \
    COST_SERVICE_MAIN_PID="$main_pid_answer" COST_SLEEP_CALLS="$COST_SLEEP_CALLS" \
    COST_SLEEP_STEPS="$SERVICE_SLEEP_STEPS" COST_SLEEP_PROC_ROOT="$SERVICE_PROC_ROOT" \
    bash "$COST_SCRIPT" "$@" 2>&1)"
  COST_EXIT=$?
}
SERVICE_MAIN_PID_CALL="--user show -p MainPID --value $SERVICE_UNIT_NAME;"
cost_service_run "$FAKE_SERVICE_PID" --service --rss-kib
check "cost: --service --rss-kib prints the service's VmRSS, found by its unit's MainPID, never gnome-shell's" \
  "exit=$COST_EXIT rss=$COST_OUTPUT calls=[$(tr '\n' ';' <"$COST_SYSTEMCTL_CALLS")]" \
  "exit=0 rss=$FAKE_SERVICE_RSS_KIB calls=[$SERVICE_MAIN_PID_CALL]"
cost_service_run "$FAKE_SERVICE_PID" --service --cpu-percent "$COST_WINDOW_SECONDS"
check "cost: --service --cpu-percent measures the service's own schedstat over the window, as for gnome-shell" \
  "exit=$COST_EXIT percent=$COST_OUTPUT slept=$(tr '\n' ' ' <"$COST_SLEEP_CALLS")" \
  "exit=0 percent=0.900 slept=$COST_WINDOW_SECONDS "
cost_unmeasurable_summary=""
cost_service_run 0 --service --rss-kib
cost_unmeasurable_summary+="not-running=$COST_EXIT/$(grep -c -F 'is not running' <<<"$COST_OUTPUT")"
cost_service_run '' --service --rss-kib
cost_unmeasurable_summary+=" empty=$COST_EXIT/$(grep -c -F 'MainPID is not a number' <<<"$COST_OUTPUT")"
COST_SYSTEMCTL_EXIT=1 cost_service_run "$FAKE_SERVICE_PID" --service --rss-kib
cost_unmeasurable_summary+=" no-manager=$COST_EXIT/$(grep -c -F 'systemctl --user show' <<<"$COST_OUTPUT")"
check "cost: --service exits 2 and says why when the service is not running, its MainPID is unreadable, or systemctl fails" \
  "$cost_unmeasurable_summary" "not-running=2/1 empty=2/1 no-manager=2/1"
cost_service_usage_summary=""
cost_service_run "$FAKE_SERVICE_PID" --service --rss-check 50000
cost_service_usage_summary+="rss-check=$COST_EXIT/$(grep -c -F -- '--service --rss-kib' <<<"$COST_OUTPUT")"
cost_service_run "$FAKE_SERVICE_PID" --service
cost_service_usage_summary+=" alone=$COST_EXIT/$(grep -c -F 'usage:' <<<"$COST_OUTPUT")"
check "cost: --service --rss-check is refused (the service's RSS budget is absolute), and --service alone is a usage error" \
  "$cost_service_usage_summary calls=$(wc -l <"$COST_SYSTEMCTL_CALLS")" "rss-check=2/1 alone=2/1 calls=0"
# --service anywhere on the line: after the mode, it must still measure the
# service, never silently gnome-shell.
cost_flag_order_summary=""
cost_service_run "$FAKE_SERVICE_PID" --rss-kib --service
cost_flag_order_summary+="rss-kib=$COST_EXIT/$COST_OUTPUT"
cost_service_run "$FAKE_SERVICE_PID" --cpu-percent "$COST_WINDOW_SECONDS" --service
cost_flag_order_summary+=" cpu-percent=$COST_EXIT/$COST_OUTPUT"
check "cost: --service after the mode still measures the service" \
  "$cost_flag_order_summary" "rss-kib=0/$FAKE_SERVICE_RSS_KIB cpu-percent=0/0.900"
# --cockpit measures cockpit.service the same way, by its own unit's MainPID:
# the fake root holds the sampler's process as well as gnome-shell, and the
# stub answers both units, so measuring either neighbour shows as its number.
FAKE_COCKPIT_PID=6161
FAKE_COCKPIT_RSS_KIB=31000
# The design's budget for the cockpit's resident memory, 48 MiB, written out.
COCKPIT_RSS_BUDGET_KIB=49152
make_fake_proc "$SERVICE_PROC_ROOT" "$FAKE_COCKPIT_PID" gjs "$FAKE_COCKPIT_RSS_KIB"
COST_COCKPIT_MAIN_PID="$FAKE_COCKPIT_PID" cost_service_run "$FAKE_SERVICE_PID" --cockpit --rss-kib
check "cost: --cockpit --rss-kib prints cockpit.service's VmRSS, found by its own unit's MainPID, never the sampler's or gnome-shell's" \
  "exit=$COST_EXIT rss=$COST_OUTPUT calls=[$(tr '\n' ';' <"$COST_SYSTEMCTL_CALLS")]" \
  "exit=0 rss=$FAKE_COCKPIT_RSS_KIB calls=[--user show -p MainPID --value cockpit.service;]"
cost_cockpit_usage_summary=""
COST_COCKPIT_MAIN_PID="$FAKE_COCKPIT_PID" cost_service_run "$FAKE_SERVICE_PID" --cockpit --rss-check 30000
cost_cockpit_usage_summary+="rss-check=$COST_EXIT/$(grep -c -F -- "--cockpit --rss-kib must read at most $COCKPIT_RSS_BUDGET_KIB" <<<"$COST_OUTPUT")"
COST_COCKPIT_MAIN_PID="$FAKE_COCKPIT_PID" cost_service_run "$FAKE_SERVICE_PID" --service --cockpit --rss-kib
cost_cockpit_usage_summary+=" both-flags=$COST_EXIT/$(grep -c -F 'usage:' <<<"$COST_OUTPUT")"
check "cost: --cockpit --rss-check is refused, naming the cockpit's own budget ($COCKPIT_RSS_BUDGET_KIB KiB), and --service with --cockpit is a usage error" \
  "$cost_cockpit_usage_summary calls=$(wc -l <"$COST_SYSTEMCTL_CALLS")" "rss-check=2/1 both-flags=2/1 calls=0"
# Anything left over is a usage error, never ignored.
cost_leftover_summary=""
cost_service_run "$FAKE_SERVICE_PID" --rss-kib --serivce
cost_leftover_summary+="misspelt-flag=$COST_EXIT/$(grep -c -F 'usage:' <<<"$COST_OUTPUT")"
cost_service_run "$FAKE_SERVICE_PID" --service --cpu-percent "$COST_WINDOW_SECONDS" 60
cost_leftover_summary+=" extra-number=$COST_EXIT/$(grep -c -F 'usage:' <<<"$COST_OUTPUT")"
cost_run "$ONE_SHELL_ROOT" --rss-check 380000 extra
cost_leftover_summary+=" rss-check-extra=$COST_EXIT/$(grep -c -F 'usage:' <<<"$COST_OUTPUT")"
check "cost: an unknown or leftover argument is a usage error (exit 2), never ignored" \
  "$cost_leftover_summary calls=$(wc -l <"$COST_SYSTEMCTL_CALLS")" \
  "misspelt-flag=2/1 extra-number=2/1 rss-check-extra=2/1 calls=0"
# Spelled by pieces so this row's own source is not what it finds in the script.
FORBIDDEN_READS_PATTERN="cmd""line|env""iron\\b|pgre""p|\\bps -"
check "cost: the script never reads an argument list or environment, or runs ps" \
  "$(grep -c -E "$FORBIDDEN_READS_PATTERN" "$COST_SCRIPT" 2>/dev/null)" 0

printf '\nresource-pulse-nested.sh (hermetic: no gnome-shell, nothing is started)\n'
# The nested-shell harness itself needs gnome-shell and a GPU, so it never runs
# here. These rows cover what it decides before anything starts: its usage,
# the bus configs it renders, the environment allowlist, and its refusals. Every
# run of it here has busctl, gsettings and gnome-shell replaced by stubs that
# only record the call (jq too: no run of the script here needs it to really
# run; the two rows that do, on perf's probe answers, call the functions
# themselves with the real jq), and RESOURCE_PULSE_NESTED_BASE pointed at an empty
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

# The usage block, as a usage error prints it: whole lines, so a line that merely mentions an option is not enough.
nested_run
usage_summary="start=$(grep -c -x -F 'usage: scripts/resource-pulse-nested.sh start [--gc-log] [--replay]' <<<"$NESTED_OUTPUT")"
usage_summary+=" scenario=$(grep -c -x -F '       scripts/resource-pulse-nested.sh scenario <idle|light|busy>' <<<"$NESTED_OUTPUT")"
check "nested: the usage lists start's --gc-log and --replay, and the scenario request" "$usage_summary" \
  "start=1 scenario=1"

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

# `scenario` takes exactly one of three words, and refuses any other before it
# looks for a run. Each case prints exit/its own message/whether it looked.
# scenario_word_verdict <needle> <args...>
scenario_word_verdict() {
  local scenario_needle="$1"
  shift
  nested_run scenario "$@"
  printf '%s/%s/%s' "$NESTED_EXIT" "$(grep -c -F "$scenario_needle" <<<"$NESTED_OUTPUT")" \
    "$(grep -c -F 'no live run' <<<"$NESTED_OUTPUT")"
}
scenario_word_summary="heavy=$(scenario_word_verdict "not a scenario: 'heavy'" heavy)"
scenario_word_summary+=" upper-case=$(scenario_word_verdict "not a scenario: 'IDLE'" IDLE)"
scenario_word_summary+=" empty=$(scenario_word_verdict "not a scenario: ''" '')"
scenario_word_summary+=" two-words=$(scenario_word_verdict 'scenario takes one word' idle light)"
scenario_word_summary+=" no-word=$(scenario_word_verdict 'scenario takes one word')"
# The list the request accepts, read by sourcing the script: a fourth word added there fails this row.
# shellcheck disable=SC2016  # Expanded by the child bash.
scenario_word_summary+=" words=[$(bash -c 'source "$1" || exit 99; printf "%s " "${REPLAY_SCENARIO_NAMES[@]}"' \
  scenario-words "$NESTED_SCRIPT")]"
check "nested: scenario takes exactly idle, light or busy, and refuses any other word (exit 2) before looking for a run" \
  "$scenario_word_summary" \
  "heavy=2/1/0 upper-case=2/1/0 empty=2/1/0 two-words=2/1/0 no-word=2/1/0 words=[idle light busy ]"

# `scenario idle` on a run recorded with the given values; each case defeats
# one requirement: replay=1 recorded, the run live (its supervisor, and its
# gnome-shell in its session), and its replay service running. The last meets
# them all and so writes the word, which proves the fixture otherwise good.
# The file holds the word, then a token new to each request, so the replay
# service restarts even for the word already playing: asked again, the same
# word must come with a new token, and no staging file may be left behind.
SCENARIO_RUN="$NESTED_BASE/rpn.Scenari1"
SCENARIO_FILE="$SCENARIO_RUN/run/rp-scenario"
# scenario_file_summary prints the scenario file's first field and whether a request token follows it, or none.
scenario_file_summary() {
  local scenario_word="" request_id=""
  [[ -e "$SCENARIO_FILE" ]] || { printf none; return 0; }
  read -r scenario_word request_id _ <"$SCENARIO_FILE"
  printf '%s+%s' "$scenario_word" "$([[ -n "$request_id" ]] && printf token || printf no-token)"
}
# scenario_run_verdict <needle> <run values...> prints exit/needle count/what the file holds.
scenario_run_verdict() {
  local scenario_needle="$1"
  shift
  rm -rf "$SCENARIO_RUN"
  make_run_dir "$SCENARIO_RUN" "$@"
  mkdir -p "$SCENARIO_RUN/run"
  NESTED_RUN_DIR="$SCENARIO_RUN" nested_run scenario idle
  printf '%s/%s/%s' "$NESTED_EXIT" "$(grep -c -F "$scenario_needle" <<<"$NESTED_OUTPUT")" "$(scenario_file_summary)"
}
live_supervisor_values=("supervisor=$$" "supervisor-starttime=$(starttime_of "$$")")
live_shell_values=("session=$test_session_id" "gnome-shell=$fake_shell_pid"
  "gnome-shell-starttime=$(starttime_of "$fake_shell_pid")")
live_service_values=("service=$$" "service-starttime=$(starttime_of "$$")")
scenario_run_summary="no-replay=$(scenario_run_verdict 'was not started with --replay' \
  "${live_supervisor_values[@]}" "${live_shell_values[@]}" "${live_service_values[@]}")"
scenario_run_summary+=" not-live=$(scenario_run_verdict 'is not live' "supervisor=$NEVER_RUNNING_PID" \
  "${live_shell_values[@]}" "${live_service_values[@]}" replay=1)"
scenario_run_summary+=" service-gone=$(scenario_run_verdict 'replay service is not running' \
  "${live_supervisor_values[@]}" "${live_shell_values[@]}" "service=$NEVER_RUNNING_PID" replay=1)"
scenario_run_summary+=" live=$(scenario_run_verdict 'replay service takes' \
  "${live_supervisor_values[@]}" "${live_shell_values[@]}" "${live_service_values[@]}" replay=1)"
first_scenario_request="$(cat "$SCENARIO_FILE" 2>/dev/null)"
NESTED_RUN_DIR="$SCENARIO_RUN" nested_run scenario idle
scenario_run_summary+=" again=$NESTED_EXIT/$(scenario_file_summary)"
scenario_run_summary+="/$([[ -n "$first_scenario_request" && "$(cat "$SCENARIO_FILE" 2>/dev/null)" != "$first_scenario_request" ]] && printf new-request || printf same-request)"
scenario_run_summary+=" staging-left=$(find "$SCENARIO_RUN/run" -mindepth 1 -name 'rp-scenario.*' | wc -l)"
check "nested: scenario refuses a run without replay=1, one not live and one whose replay service is gone (exit 2); a live replay run gets the word and a new request token in run/rp-scenario" \
  "$scenario_run_summary" \
  "no-replay=2/1/none not-live=2/1/none service-gone=2/1/none live=0/1/idle+token again=0/idle+token/new-request staging-left=0"
rm -rf "$SCENARIO_RUN"

# `perf` acts only on a live run started with --gc-log and --replay whose
# replay service runs, with gnome-calculator on PATH, and a shell log holding a
# collection line of the run's gnome-shell (the GC log is on). Each case below
# defeats one requirement; the last meets them all and so reaches busctl (the
# stub), which proves the fixture otherwise good. No case may start
# gnome-calculator (its stub records any call). Each prints exit/its own
# message/busctl calls/gnome-calculator calls.
PERF_RUN="$NESTED_BASE/rpn.PerfRun1"
PERF_CALCULATOR_STUB_BIN="$WIRING_TMP/perf-calculator-bin"
PERF_CALCULATOR_CALLS="$WIRING_TMP/perf-calculator-calls"
# The real gnome-calculator is in /usr/bin beside every tool, so the case
# without it runs on a PATH of the stubs and only what perf runs before it looks
# for gnome-calculator.
PERF_MINIMAL_BIN="$WIRING_TMP/perf-minimal-bin"
mkdir -p "$PERF_MINIMAL_BIN" || fatal "cannot create $PERF_MINIMAL_BIN"
for perf_minimal_tool in bash readlink dirname stat; do
  ln -sf "$(command -v "$perf_minimal_tool")" "$PERF_MINIMAL_BIN/$perf_minimal_tool" \
    || fatal "cannot link $perf_minimal_tool into $PERF_MINIMAL_BIN"
done
# Its calls file is written into its source: a launch under `env -i` would carry no variable naming it.
install_stub "$PERF_CALCULATOR_STUB_BIN" gnome-calculator \
  "$(printf '#!/bin/bash\nprintf "gnome-calculator %%s\\n" "$*" >>%q' "$PERF_CALCULATOR_CALLS")"
PERF_STUBBED_PATH="$PERF_CALCULATOR_STUB_BIN:$NESTED_STUB_BIN:$PATH"
# The case without jq: gnome-calculator's stub, busctl's stub alone (the stub dir holds a jq stub too), and the
# minimal tools; jq is the next tool perf looks for.
PERF_BUSCTL_ONLY_BIN="$WIRING_TMP/perf-busctl-only-bin"
if ! mkdir -p "$PERF_BUSCTL_ONLY_BIN" || ! ln -sf "$NESTED_STUB_BIN/busctl" "$PERF_BUSCTL_ONLY_BIN/busctl"; then
  fatal "cannot lay out $PERF_BUSCTL_ONLY_BIN"
fi
PERF_WITHOUT_JQ_PATH="$PERF_CALCULATOR_STUB_BIN:$PERF_BUSCTL_ONLY_BIN:$PERF_MINIMAL_BIN"
# A collection line of the run's gnome-shell, and a log with none: only another process's line, and a word.
PERF_COLLECTING_LOG="MinorGC:   $fake_shell_pid 0x5f2aea7ebe60   0.015299 OUT_OF_NURSERY         8.1%    256    512"
PERF_SILENT_LOG="$(printf 'gnome-shell started\nMajorGC:   %s 0x5f2aea7ebe60  10.918717 MEM_PRESSURE\n' \
  "$NEVER_RUNNING_PID")"
# perf_refusal_verdict <needle> <PATH> <shell log> [run values...] prints exit/needle count/busctl
# calls/gnome-calculator calls for `perf` on the fixture run made with these values, named; with no values there is
# no run, and none is named.
perf_refusal_verdict() {
  local perf_needle="$1" perf_path="$2" perf_shell_log="$3" perf_output perf_exit
  shift 3
  rm -rf "$PERF_RUN"
  : >"$NESTED_STUB_CALLS"
  : >"$PERF_CALCULATOR_CALLS"
  if (( $# > 0 )); then
    make_run_dir "$PERF_RUN" "$@"
    mkdir -p "$PERF_RUN/log" "$PERF_RUN/run" || fatal "cannot lay out $PERF_RUN"
    printf '%s\n' "unix:path=$PERF_RUN/bus/session.sock,guid=0123456789abcdef" >"$PERF_RUN/state/session.addr"
    printf '%s\n' "$perf_shell_log" >"$PERF_RUN/log/shell.log"
  fi
  perf_output="$(env -u RESOURCE_PULSE_NESTED_DIR "${LIVE_SETTINGS_BARRIER[@]}" \
    ${1:+RESOURCE_PULSE_NESTED_DIR="$PERF_RUN"} PATH="$perf_path" NESTED_STUB_CALLS="$NESTED_STUB_CALLS" \
    RESOURCE_PULSE_NESTED_BASE="$NESTED_BASE" bash "$NESTED_SCRIPT" perf 2>&1)"
  perf_exit=$?
  printf '%s/%s/%s/%s' "$perf_exit" "$(grep -c -F "$perf_needle" <<<"$perf_output")" \
    "$(grep -c '^busctl ' "$NESTED_STUB_CALLS")" "$(wc -l <"$PERF_CALCULATOR_CALLS")"
}
perf_live_run_values=("${live_supervisor_values[@]}" "${live_shell_values[@]}" "${live_service_values[@]}")
nested_run perf now
perf_refusal_summary="extra-argument=$NESTED_EXIT/$(grep -c -F 'perf takes no arguments' <<<"$NESTED_OUTPUT")"
perf_refusal_summary+=" no-run=$(perf_refusal_verdict 'no live run' "$PERF_STUBBED_PATH" '')"
perf_refusal_summary+=" not-live=$(perf_refusal_verdict 'is not live' "$PERF_STUBBED_PATH" "$PERF_COLLECTING_LOG" \
  "supervisor=$NEVER_RUNNING_PID" "${live_shell_values[@]}" "${live_service_values[@]}" gc-log=1 replay=1)"
perf_refusal_summary+=" no-gc-log=$(perf_refusal_verdict 'was not started with --gc-log' "$PERF_STUBBED_PATH" \
  "$PERF_COLLECTING_LOG" "${perf_live_run_values[@]}" replay=1)"
perf_refusal_summary+=" no-replay=$(perf_refusal_verdict 'was not started with --replay' "$PERF_STUBBED_PATH" \
  "$PERF_COLLECTING_LOG" "${perf_live_run_values[@]}" gc-log=1)"
perf_refusal_summary+=" service-gone=$(perf_refusal_verdict 'replay service is not running' "$PERF_STUBBED_PATH" \
  "$PERF_COLLECTING_LOG" "${live_supervisor_values[@]}" "${live_shell_values[@]}" "service=$NEVER_RUNNING_PID" \
  gc-log=1 replay=1)"
perf_refusal_summary+=" no-calculator=$(perf_refusal_verdict 'gnome-calculator is required' \
  "$NESTED_STUB_BIN:$PERF_MINIMAL_BIN" "$PERF_COLLECTING_LOG" "${perf_live_run_values[@]}" gc-log=1 replay=1)"
perf_refusal_summary+=" no-jq=$(perf_refusal_verdict 'jq is required' "$PERF_WITHOUT_JQ_PATH" \
  "$PERF_COLLECTING_LOG" "${perf_live_run_values[@]}" gc-log=1 replay=1)"
perf_refusal_summary+=" gc-log-silent=$(perf_refusal_verdict 'holds no collection line' "$PERF_STUBBED_PATH" \
  "$PERF_SILENT_LOG" "${perf_live_run_values[@]}" gc-log=1 replay=1)"
perf_refusal_summary+=" all-met=$(perf_refusal_verdict 'the Eval call failed' "$PERF_STUBBED_PATH" \
  "$PERF_COLLECTING_LOG" "${perf_live_run_values[@]}" gc-log=1 replay=1)"
perf_refusal_summary+=" usage=$(grep -c -x -F '       scripts/resource-pulse-nested.sh perf' <<<"$NESTED_OUTPUT")"
check "nested: perf refuses (exit 2), before busctl and without starting gnome-calculator, a run that is not live, one without gc-log=1 or replay=1, a stopped replay service, no gnome-calculator or jq on PATH and a silent GC log" \
  "$perf_refusal_summary" \
  "extra-argument=2/1 no-run=2/1/0/0 not-live=2/1/0/0 no-gc-log=2/1/0/0 no-replay=2/1/0/0 service-gone=2/1/0/0 no-calculator=2/1/0/0 no-jq=2/1/0/0 gc-log-silent=2/1/0/0 all-met=2/1/1/0 usage=1"
rm -rf "$PERF_RUN"
kill "$fake_shell_pid" 2>/dev/null
wait "$fake_shell_pid" 2>/dev/null

# perf counts a window's major collections in the shell's log (SpiderMonkey's
# MajorGC: lines, as `start --gc-log` makes it write them): only the lines past
# the byte offset the window began at, and only those whose PID column is the
# nested shell's, never the column header, a MinorGC: line, another process's
# line or one that merely mentions MajorGC:. A log it cannot read is a failure,
# never a count of 0.
PERF_GC_LOG="$WIRING_TMP/perf-gc-shell.log"
PERF_GC_SHELL_PID=3353150
PERF_GC_HEADER='MajorGC: PID     Runtime        Timestamp  Reason               States FSNR SizeKB'
perf_gc_line() { printf '%s:   %s 0x5f2aea7ebe60  %s %s         0 -> 0 F N      5772\n' "$1" "$2" "$3" "$4"; }
{
  printf '%s\n' "$PERF_GC_HEADER"
  perf_gc_line MajorGC "$PERF_GC_SHELL_PID" 1.002 MEM_PRESSURE
} >"$PERF_GC_LOG"
perf_gc_window_offset="$(stat -c %s "$PERF_GC_LOG")"
{
  printf '%s\n' "$PERF_GC_HEADER"
  perf_gc_line MajorGC "$PERF_GC_SHELL_PID" 10.918 MEM_PRESSURE
  perf_gc_line MinorGC "$PERF_GC_SHELL_PID" 11.002 OUT_OF_NURSERY
  perf_gc_line MajorGC 3353318 12.500 ALLOC_TRIGGER
  printf 'JS LOG: resource-pulse: MajorGC:   %s seen\n' "$PERF_GC_SHELL_PID"
  perf_gc_line MajorGC "$PERF_GC_SHELL_PID" 20.950 MEM_PRESSURE
} >>"$PERF_GC_LOG"
perf_gc_summary="window=$(nested_call count_major_collections_since "$PERF_GC_LOG" "$perf_gc_window_offset" \
  "$PERF_GC_SHELL_PID")"
perf_gc_summary+=" whole-log=$(nested_call count_major_collections_since "$PERF_GC_LOG" 0 "$PERF_GC_SHELL_PID")"
if nested_call count_major_collections_since "$WIRING_TMP/no-such-shell.log" 0 "$PERF_GC_SHELL_PID" >/dev/null 2>&1
then perf_gc_summary+=" unreadable=passed"
else perf_gc_summary+=" unreadable=failed"; fi
check "nested: perf counts the MajorGC: lines of the shell's own pid past the window's start, never the header, a MinorGC: line or another process's; an unreadable log fails" \
  "$perf_gc_summary" "window=2 whole-log=3 unreadable=failed"

# perf's verdict, a pure function of the counts. The disabled state shows 4
# major collections and 2 frames; each enabled state is "<major collections>
# <frames> <Samples> <top-bar paints> <card redirect>", in perf's order:
# covered-idle, covered-busy, topbar-hidden-covered, visible-busy. The in-budget
# counts sit on every bound's edge, and the disabled state's frames are above
# zero, so a comparison off by one either way, or a frame bound that leaves the
# disabled state's frames out, moves a row: the disabled state's own collections
# on their absolute bound, 4; an enabled state's 4 + 1 = 5; frames 30 Samples +
# 2 + 2 = 34, and covered-idle's 2 + 3 = 5; no top-bar paint while hidden.
PERF_VERDICT_DISABLED_MAJORS=4
PERF_VERDICT_DISABLED_FRAMES=2
PERF_VERDICT_DISABLED_COUNTS=("$PERF_VERDICT_DISABLED_MAJORS" "$PERF_VERDICT_DISABLED_FRAMES")
PERF_VERDICT_EDGE_MAJORS=5
PERF_VERDICT_STATE_NAMES=(covered-idle covered-busy topbar-hidden-covered visible-busy)
PERF_VERDICT_EDGE_RECORDS=("$PERF_VERDICT_EDGE_MAJORS 5 30 0 ALWAYS" "$PERF_VERDICT_EDGE_MAJORS 34 30 30 ALWAYS"
  "$PERF_VERDICT_EDGE_MAJORS 34 30 0 ALWAYS" "$PERF_VERDICT_EDGE_MAJORS 34 30 60 ALWAYS")
# perf_verdict_run <records...> runs the verdict on the disabled counts and these records; leaves
# PERF_VERDICT_OUTPUT and PERF_VERDICT_EXIT.
perf_verdict_run() {
  PERF_VERDICT_OUTPUT="$(nested_call perf_count_verdict "${PERF_VERDICT_DISABLED_COUNTS[@]}" "$@" 2>&1)"
  PERF_VERDICT_EXIT=$?
}
# perf_breach_verdict <state index> <record> <needle> runs the verdict with one state's record replaced, and prints
# exit/needle count/whether the line names exactly one broken budget.
perf_breach_verdict() {
  local -a breach_records=("${PERF_VERDICT_EDGE_RECORDS[@]}")
  breach_records[$1]="$2"
  perf_verdict_run "${breach_records[@]}"
  printf '%s/%s/%s' "$PERF_VERDICT_EXIT" "$(grep -c -F "$3" <<<"$PERF_VERDICT_OUTPUT")" \
    "$(grep -c -F 'FAIL: 1 count budget broken: ' <<<"$PERF_VERDICT_OUTPUT")"
}
perf_verdict_run "${PERF_VERDICT_EDGE_RECORDS[@]}"
check "nested: perf's verdict passes (exit 0) counts on every budget's edge, in one line" \
  "exit=$PERF_VERDICT_EXIT lines=$(wc -l <<<"$PERF_VERDICT_OUTPUT") [$PERF_VERDICT_OUTPUT]" \
  "exit=0 lines=1 [perf: PASS: every count within its budget]"

# The disabled state's own collections one past their absolute bound: a defect that outlives disable() raises
# the disabled state with the enabled ones, and every relative budget then holds. Only this budget breaks: the
# enabled states' 5 stay within 5 + 1.
PERF_VERDICT_DISABLED_COUNTS=($((PERF_VERDICT_DISABLED_MAJORS + 1)) "$PERF_VERDICT_DISABLED_FRAMES")
perf_disabled_breach_needle="disabled-collections: disabled had 5 major collections, more than 4: something outlives"
perf_disabled_breach_needle+=" disable(), or the run is not idle"
perf_verdict_run "${PERF_VERDICT_EDGE_RECORDS[@]}"
PERF_VERDICT_DISABLED_COUNTS=("$PERF_VERDICT_DISABLED_MAJORS" "$PERF_VERDICT_DISABLED_FRAMES")
check "nested: perf's verdict fails (exit 1) a disabled state with one more major collection than its absolute bound of 4, naming only that budget" \
  "$PERF_VERDICT_EXIT/$(grep -c -F "$perf_disabled_breach_needle" <<<"$PERF_VERDICT_OUTPUT")/$(grep -c -F 'FAIL: 1 count budget broken: ' <<<"$PERF_VERDICT_OUTPUT")" \
  "1/1/1"

perf_collections_summary=""
perf_frames_summary=""
perf_redirect_summary=""
for perf_state_index in "${!PERF_VERDICT_STATE_NAMES[@]}"; do
  perf_state_name="${PERF_VERDICT_STATE_NAMES[perf_state_index]}"
  read -r _ edge_frames edge_samples edge_paints _ <<<"${PERF_VERDICT_EDGE_RECORDS[perf_state_index]}"
  collections_breach_needle="collections: $perf_state_name had 6 major collections, more than the disabled state's"
  collections_breach_needle+=" 4 plus 1"
  perf_collections_summary+=" $perf_state_name=$(perf_breach_verdict "$perf_state_index" \
    "6 $edge_frames $edge_samples $edge_paints ALWAYS" "$collections_breach_needle")"
  # One frame past Samples + 2 + 2. In covered-idle that is with no Sample at all, so that its own tighter bound
  # (the disabled state's 2 frames + 3) still holds and only this one breaks.
  if [[ "$perf_state_name" == covered-idle ]]; then frames_breach_record="$PERF_VERDICT_EDGE_MAJORS 5 0 0 ALWAYS"
  else frames_breach_record="$PERF_VERDICT_EDGE_MAJORS 35 30 $edge_paints ALWAYS"; fi
  read -r _ breach_frames breach_samples _ _ <<<"$frames_breach_record"
  frames_breach_needle="frames-per-sample: $perf_state_name drew $breach_frames frames, more than its"
  frames_breach_needle+=" $breach_samples Samples plus the disabled state's 2 frames plus 2"
  perf_frames_summary+=" $perf_state_name=$(perf_breach_verdict "$perf_state_index" "$frames_breach_record" \
    "$frames_breach_needle")"
  perf_redirect_summary+=" $perf_state_name=$(perf_breach_verdict "$perf_state_index" \
    "$PERF_VERDICT_EDGE_MAJORS $edge_frames $edge_samples $edge_paints 0" \
    "card-redirect: $perf_state_name found the card's offscreen redirect 0, not ALWAYS")"
done
check "nested: perf's verdict fails (exit 1) one more major collection than the disabled state's + 1 in any enabled state, naming it" \
  "$perf_collections_summary" " covered-idle=1/1/1 covered-busy=1/1/1 topbar-hidden-covered=1/1/1 visible-busy=1/1/1"
check "nested: perf's verdict fails (exit 1) one more frame than Samples + the disabled state's frames + 2 in any enabled state, naming it" \
  "$perf_frames_summary" " covered-idle=1/1/1 covered-busy=1/1/1 topbar-hidden-covered=1/1/1 visible-busy=1/1/1"
covered_idle_breach_needle="covered-idle-frames: covered-idle drew 6 frames, more than the disabled state's 2 frames"
covered_idle_breach_needle+=" plus 3"
check "nested: perf's verdict fails (exit 1) covered-idle at one more frame than the disabled state's frames + 3, naming it" \
  "$(perf_breach_verdict 0 "$PERF_VERDICT_EDGE_MAJORS 6 30 0 ALWAYS" "$covered_idle_breach_needle")" "1/1/1"
hidden_paint_breach_needle="hidden-topbar-paints: topbar-hidden-covered painted the top bar while it was hidden"
hidden_paint_breach_needle+=" (top-bar paints 1, allowed 0)"
check "nested: perf's verdict fails (exit 1) one top-bar paint while the top bar is hidden, naming it" \
  "$(perf_breach_verdict 2 "$PERF_VERDICT_EDGE_MAJORS 34 30 1 ALWAYS" "$hidden_paint_breach_needle")" "1/1/1"
check "nested: perf's verdict fails (exit 1) a card whose offscreen redirect is not ALWAYS in any enabled state, naming it" \
  "$perf_redirect_summary" " covered-idle=1/1/1 covered-busy=1/1/1 topbar-hidden-covered=1/1/1 visible-busy=1/1/1"

# Counts it cannot judge are exit 2, never a pass or a breach: a state missing,
# a count that is not a whole number, a record short or long by a field, and a
# visible-busy window in which the probe counted no frame, no Sample or no
# paint, where each must happen (a probe that is not counting reads as clean).
# perf_unjudgeable_verdict <records...> prints exit/whether it said it could not judge.
perf_unjudgeable_verdict() {
  perf_verdict_run "$@"
  printf '%s/%s' "$PERF_VERDICT_EXIT" "$(grep -c -F 'perf: could not judge the counts: ' <<<"$PERF_VERDICT_OUTPUT")"
}
PERF_VERDICT_OTHER_EDGE_RECORDS=("${PERF_VERDICT_EDGE_RECORDS[@]:1}")
perf_unjudgeable_summary="state-missing=$(perf_unjudgeable_verdict "${PERF_VERDICT_EDGE_RECORDS[@]:0:3}")"
perf_unjudgeable_summary+=" not-a-number=$(perf_unjudgeable_verdict '5 x 30 0 ALWAYS' \
  "${PERF_VERDICT_OTHER_EDGE_RECORDS[@]}")"
# A leading zero, which bash arithmetic would read as octal (08 is not a number to it).
perf_unjudgeable_summary+=" leading-zero=$(perf_unjudgeable_verdict '5 08 30 0 ALWAYS' \
  "${PERF_VERDICT_OTHER_EDGE_RECORDS[@]}")"
perf_unjudgeable_summary+=" short-record=$(perf_unjudgeable_verdict '5 5 30 ALWAYS' \
  "${PERF_VERDICT_OTHER_EDGE_RECORDS[@]}")"
perf_unjudgeable_summary+=" long-record=$(perf_unjudgeable_verdict '5 5 30 0 ALWAYS 9' \
  "${PERF_VERDICT_OTHER_EDGE_RECORDS[@]}")"
for perf_dead_counter in frames Samples paints; do
  case "$perf_dead_counter" in
    frames) perf_dead_record='5 0 30 60 ALWAYS' ;;
    Samples) perf_dead_record='5 34 0 60 ALWAYS' ;;
    paints) perf_dead_record='5 34 30 0 ALWAYS' ;;
  esac
  perf_unjudgeable_summary+=" visible-busy-no-$perf_dead_counter=$(perf_unjudgeable_verdict \
    "${PERF_VERDICT_EDGE_RECORDS[@]:0:3}" "$perf_dead_record")"
done
PERF_VERDICT_DISABLED_COUNTS=("$PERF_VERDICT_DISABLED_MAJORS" '')
perf_unjudgeable_summary+=" disabled-frames-empty=$(perf_unjudgeable_verdict "${PERF_VERDICT_EDGE_RECORDS[@]}")"
PERF_VERDICT_DISABLED_COUNTS=("$PERF_VERDICT_DISABLED_MAJORS" "$PERF_VERDICT_DISABLED_FRAMES")
check "nested: perf's verdict cannot judge (exit 2, never 0 or 1) a missing state, a count that is not a whole number, a record of the wrong length, or a visible-busy window with no frame, Sample or paint" \
  "$perf_unjudgeable_summary" \
  "state-missing=2/1 not-a-number=2/1 leading-zero=2/1 short-record=2/1 long-record=2/1 visible-busy-no-frames=2/1 visible-busy-no-Samples=2/1 visible-busy-no-paints=2/1 disabled-frames-empty=2/1"

# What a probe answer must show before perf takes the request for done: a JSON
# object, no refusal, and the mode the request ran in (.attached after an
# attach, .mode after a read) the one expected. An answer lost on the way (empty,
# null) must fail at the attach, not nine minutes later at the verdict. Each case
# prints the check's status; only the four real answers succeed. This row runs
# the real jq (the stub is only for runs of the script): without jq it fails.
# perf_probe_answer_status <request> <expected mode> <answer> prints the check's status.
perf_probe_answer_status() {
  nested_call is_successful_perf_probe_answer "$1" "$2" "$3" 2>/dev/null
  printf '%s' "$?"
}
PERF_ENABLED_READ_ANSWER='{"mode":"enabled","frames":2,"samples":3,"topbarPaints":3,"cardRedirect":"ALWAYS"}'
perf_answer_summary="attached-enabled=$(perf_probe_answer_status attach-enabled enabled \
  '{"attached":"enabled","reattached":true}')"
perf_answer_summary+=" attached-disabled=$(perf_probe_answer_status attach-disabled disabled \
  '{"attached":"disabled","counts":"frames only: with the extension disabled there is no client"}')"
perf_answer_summary+=" read-enabled=$(perf_probe_answer_status read enabled "$PERF_ENABLED_READ_ANSWER")"
perf_answer_summary+=" read-disabled=$(perf_probe_answer_status read disabled '{"mode":"disabled","frames":1}')"
perf_answer_summary+=" empty=$(perf_probe_answer_status attach-enabled enabled '')"
perf_answer_summary+=" null=$(perf_probe_answer_status attach-enabled enabled 'null')"
perf_answer_summary+=" empty-object=$(perf_probe_answer_status attach-enabled enabled '{}')"
perf_answer_summary+=" other-mode=$(perf_probe_answer_status attach-enabled enabled '{"attached":"disabled"}')"
perf_answer_summary+=" read-with-attach-sign=$(perf_probe_answer_status read enabled '{"attached":"enabled"}')"
perf_answer_summary+=" read-other-mode=$(perf_probe_answer_status read disabled "$PERF_ENABLED_READ_ANSWER")"
perf_answer_summary+=" refused=$(perf_probe_answer_status attach-enabled enabled \
  '{"refused":"missing the card","missing":["card"]}')"
perf_answer_summary+=" not-an-object=$(perf_probe_answer_status attach-enabled enabled '"enabled"')"
perf_empty_answer_output="$(nested_call is_successful_perf_probe_answer attach-enabled enabled '' 2>&1)"
perf_answer_summary+=" says-why=$(grep -c -F 'shows no sign that it ran' <<<"$perf_empty_answer_output")"
check "nested: perf takes a probe answer for done only when it shows the mode it ran in; an empty, null, refused or other answer fails at once (needs jq)" \
  "$perf_answer_summary" \
  "attached-enabled=0 attached-disabled=0 read-enabled=0 read-disabled=0 empty=1 null=1 empty-object=1 other-mode=1 read-with-attach-sign=1 read-other-mode=1 refused=1 not-an-object=1 says-why=1"

# perf takes an enabled state's counts only when the probe's two facts, read at
# the end of its window, show the state set up as it is named: the card covered
# (not visible) in the three covered states and visible in visible-busy; the top
# bar's indicator unmapped in topbar-hidden-covered and mapped in the other three.
# A window that did not maximize or minimize, or a top bar not hidden or not shown
# again, would otherwise report its counts under the wrong name. A mismatch is
# exit 2, naming the state and what was expected, with no line of readings: never
# a pass and never a breach. So is a fact that is not true or false (null, or the
# string "false"). Each case prints exit/its needle's count/the state's readings
# lines, from record_perf_state on a read answer with in-budget counts. This row
# runs the real jq: without it, it fails.
PERF_SETUP_ANSWER_COUNTS='"mode":"enabled","frames":34,"samples":30,"topbarPaints":30,"cardRedirect":"ALWAYS"'
# perf_setup_verdict <state> <isCardVisible, as JSON> <isIndicatorMapped, as JSON> <needle> prints the case.
perf_setup_verdict() {
  local setup_state="$1" setup_needle="$4" setup_answer setup_output setup_exit
  setup_answer="{$PERF_SETUP_ANSWER_COUNTS,\"isCardVisible\":$2,\"isIndicatorMapped\":$3}"
  setup_output="$(nested_call record_perf_state "$setup_state" "$setup_answer" 2>&1)"
  setup_exit=$?
  printf '%s/%s/%s' "$setup_exit" "$(grep -c -F "$setup_needle" <<<"$setup_output")" \
    "$(grep -c -F "$setup_state: cpu=" <<<"$setup_output")"
}
# perf_setup_mismatch_needle <state> <what was expected, and found> prints the line a mismatch must print.
perf_setup_mismatch_needle() { printf 'perf: could not measure %s: it was not set up as named: %s' "$1" "$2"; }
PERF_SETUP_PROBLEM_NEEDLE='perf: could not measure'
PERF_SETUP_CARD_COVERED_MISMATCH='expected the card covered (not visible), and it counts as visible'
PERF_SETUP_CARD_VISIBLE_MISMATCH='expected the card visible, and it counts as covered'
PERF_SETUP_INDICATOR_UNMAPPED_MISMATCH='expected the top bar indicator unmapped (hidden), and it is mapped'
PERF_SETUP_INDICATOR_MAPPED_MISMATCH='expected the top bar indicator mapped (shown), and it is unmapped'
PERF_SETUP_NOT_A_FACT_NEEDLE="perf: could not measure covered-busy: the probe's facts are not true or false"
perf_setup_summary="set-up:"
perf_setup_summary+=" $(perf_setup_verdict covered-idle false true "$PERF_SETUP_PROBLEM_NEEDLE")"
perf_setup_summary+=" $(perf_setup_verdict covered-busy false true "$PERF_SETUP_PROBLEM_NEEDLE")"
perf_setup_summary+=" $(perf_setup_verdict topbar-hidden-covered false false "$PERF_SETUP_PROBLEM_NEEDLE")"
perf_setup_summary+=" $(perf_setup_verdict visible-busy true true "$PERF_SETUP_PROBLEM_NEEDLE")"
perf_setup_summary+=" card-visible-while-covered:"
perf_setup_summary+=" $(perf_setup_verdict covered-idle true true \
  "$(perf_setup_mismatch_needle covered-idle "$PERF_SETUP_CARD_COVERED_MISMATCH")")"
perf_setup_summary+=" $(perf_setup_verdict covered-busy true true \
  "$(perf_setup_mismatch_needle covered-busy "$PERF_SETUP_CARD_COVERED_MISMATCH")")"
perf_setup_summary+=" $(perf_setup_verdict topbar-hidden-covered true false \
  "$(perf_setup_mismatch_needle topbar-hidden-covered "$PERF_SETUP_CARD_COVERED_MISMATCH")")"
perf_setup_summary+=" card-covered-in-visible-busy:"
perf_setup_summary+=" $(perf_setup_verdict visible-busy false true \
  "$(perf_setup_mismatch_needle visible-busy "$PERF_SETUP_CARD_VISIBLE_MISMATCH")")"
perf_setup_summary+=" indicator-mapped-while-hidden:"
perf_setup_summary+=" $(perf_setup_verdict topbar-hidden-covered false true \
  "$(perf_setup_mismatch_needle topbar-hidden-covered "$PERF_SETUP_INDICATOR_UNMAPPED_MISMATCH")")"
perf_setup_summary+=" indicator-unmapped-while-shown:"
perf_setup_summary+=" $(perf_setup_verdict covered-idle false false \
  "$(perf_setup_mismatch_needle covered-idle "$PERF_SETUP_INDICATOR_MAPPED_MISMATCH")")"
perf_setup_summary+=" $(perf_setup_verdict covered-busy false false \
  "$(perf_setup_mismatch_needle covered-busy "$PERF_SETUP_INDICATOR_MAPPED_MISMATCH")")"
perf_setup_summary+=" $(perf_setup_verdict visible-busy true false \
  "$(perf_setup_mismatch_needle visible-busy "$PERF_SETUP_INDICATOR_MAPPED_MISMATCH")")"
perf_setup_summary+=" not-a-fact:"
perf_setup_summary+=" $(perf_setup_verdict covered-busy null true "$PERF_SETUP_NOT_A_FACT_NEEDLE")"
perf_setup_summary+=" $(perf_setup_verdict covered-busy '"false"' true "$PERF_SETUP_NOT_A_FACT_NEEDLE")"
expected_perf_setup_summary="set-up: 0/0/1 0/0/1 0/0/1 0/0/1 card-visible-while-covered: 2/1/0 2/1/0 2/1/0"
expected_perf_setup_summary+=" card-covered-in-visible-busy: 2/1/0 indicator-mapped-while-hidden: 2/1/0"
expected_perf_setup_summary+=" indicator-unmapped-while-shown: 2/1/0 2/1/0 2/1/0 not-a-fact: 2/1/0 2/1/0"
check "nested: perf takes an enabled state's counts only when the probe shows it set up as named (the card covered in the covered states and visible in visible-busy, the indicator unmapped only in topbar-hidden-covered); a mismatch, or a fact that is not true or false, is exit 2 naming the state and what was expected (needs jq)" \
  "$perf_setup_summary" "$expected_perf_setup_summary"

# perf's exit (end_perf_run, its EXIT trap) on a fixture, from inside one bash
# that plays perf: two children of it stand in for the window (recorded with
# no start time, as when it could not be read) and the background measurement
# job, and busctl is the stub, which fails every call, so each restore step
# fails. Every step must still run: both children ended, and busctl asked once
# to enable the extension and once to show the top bar. A recorded window that
# is not perf's child (a process of another session) must be left alone. And
# perf installs it as its EXIT trap.
PERF_CLEANUP_ADDRESS="unix:path=$WIRING_TMP/perf-cleanup/bus/session.sock"
# perf_cleanup_verdict <own-child | the pid of a process that is not its child> prints, for the window then the
# measurement job, ended or left-running, then end_perf_run's status.
perf_cleanup_verdict() {
  : >"$NESTED_STUB_CALLS"
  # shellcheck disable=SC2016  # Expanded by the child bash, which plays perf.
  env "${LIVE_SETTINGS_BARRIER[@]}" PATH="$NESTED_STUB_BIN:$PATH" NESTED_STUB_CALLS="$NESTED_STUB_CALLS" \
    bash -c '
      source "$1" || exit 99
      sleep 300 &
      own_window_pid=$!
      sleep 300 &
      PERF_COST_JOB_PID=$!
      cost_job_pid=$PERF_COST_JOB_PID
      if [[ "$2" == own-child ]]; then PERF_WINDOW_PID=$own_window_pid; else PERF_WINDOW_PID=$2; fi
      PERF_WINDOW_STARTTIME=""
      PERF_ADDRESS="$3"
      end_perf_run 2>/dev/null
      cleanup_status=$?
      # A child ended by a signal is a zombie until reaped, which read_stat_fields does not count as running.
      process_fate() {
        local poll
        for poll in 1 2 3 4 5 6 7 8 9 10; do
          read_stat_fields /proc "$1" || { printf ended; return 0; }
          sleep 0.1
        done
        printf left-running
      }
      printf "window=%s cost-job=%s status=%s" "$(process_fate "$PERF_WINDOW_PID")" \
        "$(process_fate "$cost_job_pid")" "$cleanup_status"
      kill "$own_window_pid" "$cost_job_pid" 2>/dev/null
    ' perf-cleanup "$NESTED_SCRIPT" "$1" "$PERF_CLEANUP_ADDRESS"
}
perf_cleanup_summary="own-child: $(perf_cleanup_verdict own-child)"
perf_cleanup_summary+=" busctl=$(grep -c '^busctl ' "$NESTED_STUB_CALLS")"
perf_cleanup_summary+=" enable=$(grep -c -F 'Main.extensionManager.enableExtension(' "$NESTED_STUB_CALLS")"
perf_cleanup_summary+=" show=$(grep -c -F 'indicator?.show()' "$NESTED_STUB_CALLS")"
other_session_process_id="$(start_sacrificial_session sleep 60)"
other_session_process_starttime="$(starttime_of "$other_session_process_id")"
perf_cleanup_summary+=" not-a-child: $(perf_cleanup_verdict "$other_session_process_id")"
kill_sacrifice "$other_session_process_id" sleep "$other_session_process_starttime"
perf_cleanup_summary+=" installed=$(grep -c -x -F '    trap end_perf_run EXIT' "$NESTED_SCRIPT")"
check "nested: perf's exit ends its window (by pid when its start time is unknown, only if it is perf's child) and its measurement job, then asks to enable the extension and show the top bar, each step despite a failed one" \
  "$perf_cleanup_summary" \
  "own-child: window=ended cost-job=ended status=0 busctl=2 enable=1 show=1 not-a-child: window=left-running cost-job=ended status=0 installed=1"

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

# `start` against that public base: options it accepts reach its first refusal
# (the base is not private), and options it does not are a usage error before
# it. Each case prints exit/its own message/whether it reached that refusal.
# start_options_verdict <needle> <options...>
start_options_verdict() {
  local start_needle="$1" start_options_output start_options_exit
  shift
  start_options_output="$(env -u RESOURCE_PULSE_NESTED_DIR "${LIVE_SETTINGS_BARRIER[@]}" PATH="$NESTED_STUB_BIN:$PATH" \
    NESTED_STUB_CALLS="$NESTED_STUB_CALLS" RESOURCE_PULSE_NESTED_BASE="$PUBLIC_BASE" \
    bash "$NESTED_SCRIPT" start "$@" 2>&1)"
  start_options_exit=$?
  printf '%s/%s/%s' "$start_options_exit" "$(grep -c -F "$start_needle" <<<"$start_options_output")" \
    "$(grep -c -F 'is not private' <<<"$start_options_output")"
}
: >"$NESTED_STUB_CALLS"
start_options_summary="both=$(start_options_verdict 'usage:' --gc-log --replay)"
start_options_summary+=" reversed=$(start_options_verdict 'usage:' --replay --gc-log)"
start_options_summary+=" gc-log=$(start_options_verdict 'usage:' --gc-log)"
start_options_summary+=" replay=$(start_options_verdict 'usage:' --replay)"
start_options_summary+=" twice=$(start_options_verdict 'start takes --gc-log at most once' --gc-log --replay --gc-log)"
start_options_summary+=" unknown=$(start_options_verdict "start takes only --gc-log and --replay, got: '--verbose'" --verbose)"
start_options_summary+=" extra=$(start_options_verdict "start takes only --gc-log and --replay, got: 'now'" --replay now)"
start_options_summary+=" created=$(find "$PUBLIC_BASE" -mindepth 1 | wc -l) stub-calls=$(nested_stub_call_count)"
check "nested: start takes --gc-log and --replay in either order, each once; anything else is a usage error (exit 2) before anything runs" \
  "$start_options_summary" \
  "both=2/0/1 reversed=2/0/1 gc-log=2/0/1 replay=2/0/1 twice=2/1/0 unknown=2/1/0 extra=2/1/0 created=0 stub-calls=0"

# What `start` records for its options, where the in-bus stage and `scenario`
# read them: the run's state/run.values. (Run here on a scratch run directory:
# `start` itself never gets as far as recording them in this suite.)
START_VALUES_RUN="$WIRING_TMP/start-values"
# recorded_start_values <options...> prints the values recorded for these options, space-separated.
recorded_start_values() {
  rm -rf "$START_VALUES_RUN"
  mkdir -p "$START_VALUES_RUN/state" && : >"$START_VALUES_RUN/state/run.values"
  # shellcheck disable=SC2016  # Expanded by the child bash.
  bash -c 'source "$1" || exit 99; run_dir="$2"; shift 2
    parse_start_options "$@" && record_requested_start_options "$run_dir"' \
    start-values "$NESTED_SCRIPT" "$START_VALUES_RUN" "$@" || printf 'exit-%s ' "$?"
  tr '\n' ' ' <"$START_VALUES_RUN/state/run.values"
}
check "nested: start records gc-log=1 and replay=1 in state/run.values for the options given, and nothing for the others" \
  "both=[$(recorded_start_values --replay --gc-log)] gc-log=[$(recorded_start_values --gc-log)] replay=[$(recorded_start_values --replay)] none=[$(recorded_start_values)]" \
  "both=[replay=1 gc-log=1 ] gc-log=[gc-log=1 ] replay=[replay=1 ] none=[]"

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

# perf's window is a GUI process, so it must reach the nested shell and nothing
# else: started any other way it would open on the live desktop. start_perf_window
# launches a stand-in gnome-calculator (by the path perf resolves) on a prepared
# run, from a caller whose environment carries a decoy variable, a display, a
# Wayland display and an X authority. The stand-in records the names in its
# environment and the values its isolation rests on. Its names must be exactly
# the run's allowlist, the three perf adds and bash's own (PWD, SHLVL); its
# runtime dir and session bus the run's; its Wayland display the nested one.
PERF_WINDOW_RUN="$WIRING_TMP/perf-window/rpn.PerfWin1"
PERF_WINDOW_STAND_IN_DIR="$WIRING_TMP/perf-window-bin"
PERF_WINDOW_STAND_IN="$PERF_WINDOW_STAND_IN_DIR/gnome-calculator"
# What the stand-in writes, beside itself: under `env -i` no variable could name another place.
PERF_WINDOW_ENV_NAMES="$PERF_WINDOW_STAND_IN_DIR/env-names"
PERF_WINDOW_ENV_VALUES="$PERF_WINDOW_STAND_IN_DIR/env-values"
PERF_WINDOW_RUN_BUS="unix:path=$PERF_WINDOW_RUN/bus/session.sock"
if ! mkdir -p "$PERF_WINDOW_RUN" "$PERF_WINDOW_STAND_IN_DIR" || ! chmod 700 "$PERF_WINDOW_RUN" ||
  ! nested_call prepare_run_directory "$PERF_WINDOW_RUN" PerfWin1; then
  fatal "cannot prepare $PERF_WINDOW_RUN"
fi
cat >"$PERF_WINDOW_STAND_IN" <<'STAND_IN'
#!/bin/bash
# Stands in for gnome-calculator: records the names in its environment, and the values perf relies on, beside itself.
record_dir="${BASH_SOURCE[0]%/*}"
compgen -e >"$record_dir/env-names"
printf '%s\n' "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR-unset}" "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS-unset}" \
  "WAYLAND_DISPLAY=${WAYLAND_DISPLAY-unset}" "GDK_BACKEND=${GDK_BACKEND-unset}" >"$record_dir/env-values"
STAND_IN
chmod +x "$PERF_WINDOW_STAND_IN" || fatal "cannot make $PERF_WINDOW_STAND_IN executable"
: >"$PERF_WINDOW_ENV_NAMES"
: >"$PERF_WINDOW_ENV_VALUES"
# shellcheck disable=SC2016  # Expanded by the child bash.
env "${LIVE_SETTINGS_BARRIER[@]}" PERF_WINDOW_DECOY=decoy-must-not-arrive DISPLAY=:99 WAYLAND_DISPLAY=wayland-decoy \
  XAUTHORITY="$WIRING_TMP/decoy-xauthority" \
  bash -c 'source "$1" || exit 99; shift; start_perf_window "$@" && wait "$PERF_WINDOW_PID"' perf-window \
  "$NESTED_SCRIPT" "$PERF_WINDOW_RUN" "$PERF_WINDOW_RUN_BUS" "$PERF_WINDOW_STAND_IN"
perf_window_summary="exit=$?"
# bash exports PWD and SHLVL itself; `_` only when it inherits one, which `env -i` never gives it.
perf_window_expected_names="$( { nested_call nested_environment_assignments "$PERF_WINDOW_RUN" | cut -d= -f1
  printf '%s\n' WAYLAND_DISPLAY GDK_BACKEND DBUS_SESSION_BUS_ADDRESS PWD SHLVL
} | LC_ALL=C sort -u)"
perf_window_seen_names="$(LC_ALL=C sort -u "$PERF_WINDOW_ENV_NAMES")"
perf_window_summary+=" unexpected=[$(LC_ALL=C comm -13 <(printf '%s\n' "$perf_window_expected_names") \
  <(printf '%s\n' "$perf_window_seen_names") | tr '\n' ' ')]"
perf_window_summary+=" missing=[$(LC_ALL=C comm -23 <(printf '%s\n' "$perf_window_expected_names") \
  <(printf '%s\n' "$perf_window_seen_names") | tr '\n' ' ')]"
perf_window_summary+=" values=[$(tr '\n' ' ' <"$PERF_WINDOW_ENV_VALUES")]"
check "nested: perf's window starts with only the run's allowlist plus its Wayland display, Wayland backend and private bus: nothing of the caller's display, X authority or other variables" \
  "$perf_window_summary" \
  "exit=0 unexpected=[] missing=[] values=[XDG_RUNTIME_DIR=$PERF_WINDOW_RUN/run DBUS_SESSION_BUS_ADDRESS=$PERF_WINDOW_RUN_BUS WAYLAND_DISPLAY=rp-nested-0 GDK_BACKEND=wayland ]"

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

# The replay service owns the real service's bus name, so it must never serve on
# any bus but its run's private one. Every address below that is not the run's
# is the barrier's dead bus, so even a broken guard reaches nothing live. A D-Bus
# address can be a list, tried in order: the run's bus followed by another one
# is not the run's bus.
REPLAY_SERVICE_REFUSAL='refusing to serve on anything but the private session bus'
REPLAY_SERVICE_CONNECT_FAILURE='cannot connect to'
REPLAY_EXTENSION_DIR="$PREPARED_RUN/data/gnome-shell/extensions/$EXTENSION_UUID"
# replay_service_verdict <run dir or ''> <session bus address> prints refused, tried-to-connect, or other.
replay_service_verdict() {
  local replay_service_output
  replay_service_output="$(env -u RESOURCE_PULSE_NESTED_DIR "${LIVE_SETTINGS_BARRIER[@]}" \
    ${1:+RESOURCE_PULSE_NESTED_DIR="$1"} DBUS_SESSION_BUS_ADDRESS="$2" \
    timeout "$GLUE_PARSE_TIMEOUT_SECONDS" gjs -m "$NESTED_FILES/replay-service.js" "$REPLAY_EXTENSION_DIR" 2>&1)"
  if [[ "$replay_service_output" == *"$REPLAY_SERVICE_REFUSAL"* ]]; then printf refused
  elif [[ "$replay_service_output" == *"$REPLAY_SERVICE_CONNECT_FAILURE"* ]]; then printf tried-to-connect
  else printf other; fi
}
REPLAY_RUN_BUS="unix:path=$PREPARED_RUN/bus/session.sock"
replay_guard_summary="no-run=$(replay_service_verdict '' "$REPLAY_RUN_BUS")"
replay_guard_summary+=" other-bus=$(replay_service_verdict "$PREPARED_RUN" "$LIVE_SETTINGS_BARRIER_BUS")"
replay_guard_summary+=" address-list=$(replay_service_verdict "$PREPARED_RUN" "$REPLAY_RUN_BUS;$LIVE_SETTINGS_BARRIER_BUS")"
replay_guard_summary+=" bad-guid=$(replay_service_verdict "$PREPARED_RUN" "$REPLAY_RUN_BUS,guid=0123456789abcdef,x=1")"
# A run directory the harness could never make, with the address built from it as the bus: one that is itself an
# address list (the run's socket, then another dead one), and one outside the shell's safe-path rule (a space).
# Either would otherwise match its own address exactly.
CRAFTED_REPLAY_RUN_DIR="$PREPARED_RUN/bus/session.sock;unix:path=$WIRING_TMP/crafted-replay-run"
replay_guard_summary+=" crafted-dir=$(replay_service_verdict "$CRAFTED_REPLAY_RUN_DIR" "unix:path=$CRAFTED_REPLAY_RUN_DIR/bus/session.sock")"
UNSAFE_REPLAY_RUN_DIR="$WIRING_TMP/unsafe replay run"
replay_guard_summary+=" unsafe-dir=$(replay_service_verdict "$UNSAFE_REPLAY_RUN_DIR" "unix:path=$UNSAFE_REPLAY_RUN_DIR/bus/session.sock")"
# The run's own (absent) socket, as dbus-run-session names it: accepted, so it tries to connect and fails there.
replay_guard_summary+=" own-bus=$(replay_service_verdict "$PREPARED_RUN" "$REPLAY_RUN_BUS,guid=0123456789abcdef")"
check "nested: replay-service.js refuses any bus but its run's private session bus, and any run directory the harness could not make, before connecting" \
  "$replay_guard_summary" \
  "no-run=refused other-bus=refused address-list=refused bad-guid=refused crafted-dir=refused unsafe-dir=refused own-bus=tried-to-connect"

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

# The in-bus stage's service step, run for real against stubs: gsettings
# succeeds; gjs stands in for each service (it records its arguments, the names
# in its environment and the bus it was given, under its entry module's file
# name, then waits, or exits at once; like gjs, it exits at once when its module
# is not there); busctl says a name is owned once the stand-in for the module
# that owns it has started; gnome-shell records the names in its environment,
# the two collection-log variables' values, and whether each service was
# recorded before it, then exits. The stage runs in its isolated environment
# with the run's private bus address (a socket nobody listens on), inside
# `setsid timeout`, from a caller whose own environment carries a display, the
# live bus and a token.
NESTED_SERVICE_STUB_BIN="$WIRING_TMP/nested-service-bin"
NESTED_SERVICE_CALLS="$WIRING_TMP/nested-service-calls"
# Each of the next three is a prefix: a stand-in writes <prefix>.<its entry module's file name>, and the
# gnome-shell stand-in writes <env names prefix>.gnome-shell.
NESTED_SERVICE_ENV_NAMES="$WIRING_TMP/nested-service-env-names"
NESTED_SERVICE_BUS_SEEN="$WIRING_TMP/nested-service-bus-seen"
NESTED_SERVICE_STARTED="$WIRING_TMP/nested-service-started"
NESTED_SERVICE_RUN_LIMIT_SECONDS=30
NESTED_SERVICE_STAND_IN_TEXT='stand-in service started'
SAMPLER_ENTRY_FILE_NAME='main.js'
COCKPIT_ENTRY_FILE_NAME='cockpit.js'
REPLAY_ENTRY_FILE_NAME='replay-service.js'
NESTED_SHELL_ENV_NAMES_SUFFIX='gnome-shell'
# Which bus name the stand-in for each entry module owns once started (file name=bus name, space-separated).
NESTED_SERVICE_BUS_NAME_BY_ENTRY="$SAMPLER_ENTRY_FILE_NAME=$RESOURCE_PULSE_BUS_NAME $COCKPIT_ENTRY_FILE_NAME=$COCKPIT_BUS_NAME"
NESTED_SERVICE_BUS_NAME_BY_ENTRY+=" $REPLAY_ENTRY_FILE_NAME=$RESOURCE_PULSE_BUS_NAME"
# Pinned here, not read from the script: the run's own copies of the two services, of the replay service, and of
# the extension the replay service is given.
NESTED_SERVICE_MAIN_RELATIVE_PATH="data/gnome-shell/extensions/$EXTENSION_UUID/service/$SAMPLER_ENTRY_FILE_NAME"
NESTED_COCKPIT_MAIN_RELATIVE_PATH="data/gnome-shell/extensions/$EXTENSION_UUID/service/$COCKPIT_ENTRY_FILE_NAME"
NESTED_REPLAY_MAIN_RELATIVE_PATH="replay/$REPLAY_ENTRY_FILE_NAME"
NESTED_EXTENSION_RELATIVE_PATH="data/gnome-shell/extensions/$EXTENSION_UUID"
# nested_constant_text <name>: one of the script's readonly values, read by sourcing it; empty when it has none.
nested_constant_text() {
  # shellcheck disable=SC2016  # Expanded by the child bash.
  bash -c 'source "$1" || exit 99; printf "%s" "${!2:-}"' nested-constant "$NESTED_SCRIPT" "$1"
}
# nested_constant <name>: one of the script's readonly numbers; exits 2 unless it is one.
nested_constant() {
  local constant_value
  constant_value="$(nested_constant_text "$1")"
  [[ "$constant_value" =~ ^[0-9]+$ ]] || fatal "cannot read $1 from $NESTED_SCRIPT"
  printf '%s' "$constant_value"
}
NESTED_SERVICE_START_TIMEOUT_SECONDS="$(nested_constant SERVICE_START_TIMEOUT_SECONDS)" || exit 2
NESTED_STOP_GRACE_SECONDS="$(nested_constant STOP_GRACE_SECONDS)" || exit 2
# shellcheck disable=SC2016  # The stubs' own source: their variables expand when they run.
install_stub "$NESTED_SERVICE_STUB_BIN" gsettings '#!/usr/bin/env bash
printf "gsettings %s\n" "$*" >>"$NESTED_SERVICE_CALLS"'
# shellcheck disable=SC2016
install_stub "$NESTED_SERVICE_STUB_BIN" gjs '#!/usr/bin/env bash
# Stands in for a service: records how it was started, then waits to be signalled (or exits at once).
entry_file_name="${2##*/}"
printf "gjs %s\n" "$*" >>"$NESTED_SERVICE_CALLS"
compgen -e >"$NESTED_SERVICE_ENV_NAMES.$entry_file_name"
printf "%s\n" "$DBUS_SESSION_BUS_ADDRESS" >"$NESTED_SERVICE_BUS_SEEN.$entry_file_name"
# As gjs -m does with a module it cannot load.
[[ -r "$2" ]] || { printf "stand-in: no module at %s\n" "$2"; exit 1; }
printf "%s\n" "$NESTED_SERVICE_STAND_IN_TEXT"
[[ "$NESTED_SERVICE_MODE" == exits ]] && exit 1
for entry_and_bus_name in $NESTED_SERVICE_BUS_NAME_BY_ENTRY; do
  [[ "${entry_and_bus_name%%=*}" == "$entry_file_name" ]] && : >"$NESTED_SERVICE_STARTED.${entry_and_bus_name#*=}"
done
exec sleep 60'
# shellcheck disable=SC2016
install_stub "$NESTED_SERVICE_STUB_BIN" busctl '#!/usr/bin/env bash
# The name asked about is the last argument of NameHasOwner.
printf "busctl %s\n" "$*" >>"$NESTED_SERVICE_CALLS"
if [[ -e "$NESTED_SERVICE_STARTED.${!#}" ]]; then echo "b true"; else echo "b false"; fi'
# shellcheck disable=SC2016
install_stub "$NESTED_SERVICE_STUB_BIN" gnome-shell '#!/usr/bin/env bash
printf "gnome-shell %s\n" "$*" >>"$NESTED_SERVICE_CALLS"
compgen -e >"$NESTED_SERVICE_ENV_NAMES.gnome-shell"
printf "shell-gc-variables=JS_GC_PROFILE=%s,JS_GC_PROFILE_NURSERY=%s\n" "${JS_GC_PROFILE-unset}" \
  "${JS_GC_PROFILE_NURSERY-unset}" >>"$NESTED_SERVICE_CALLS"
for process_name in service cockpit; do
  printf "%s-recorded-before-the-shell=%s\n" "$process_name" \
    "$(grep -c "^$process_name=" "$RESOURCE_PULSE_NESTED_DIR/state/run.values")" >>"$NESTED_SERVICE_CALLS"
done'
# make_service_run <suffix>: a run directory laid out as `start` lays it out, with
# the nested dconf already written (the gsettings stub writes nothing).
make_service_run() {
  local run_dir="$WIRING_TMP/service-runs/rpn.$1"
  if ! mkdir -p "$run_dir" || ! chmod 700 "$run_dir"; then
    fatal "cannot create $run_dir"
  fi
  nested_call prepare_run_directory "$run_dir" "$1" || fatal "cannot prepare $run_dir"
  if ! mkdir -p "$run_dir/config/dconf" || ! printf 'nested settings\n' >"$run_dir/config/dconf/user"; then
    fatal "cannot write $run_dir's nested dconf"
  fi
  printf '%s' "$run_dir"
}
# run_in_bus_stage_with_service <run dir> <stand-in mode: waits | exits>; leaves
# NESTED_SERVICE_EXIT and NESTED_SERVICE_ELAPSED_SECONDS.
run_in_bus_stage_with_service() {
  local run_dir="$1" started_seconds=$SECONDS entry_file_name
  rm -f "$NESTED_SERVICE_STARTED".*
  : >"$NESTED_SERVICE_CALLS"
  for entry_file_name in "$SAMPLER_ENTRY_FILE_NAME" "$COCKPIT_ENTRY_FILE_NAME" "$REPLAY_ENTRY_FILE_NAME"; do
    : >"$NESTED_SERVICE_ENV_NAMES.$entry_file_name"; : >"$NESTED_SERVICE_BUS_SEEN.$entry_file_name"
  done
  : >"$NESTED_SERVICE_ENV_NAMES.$NESTED_SHELL_ENV_NAMES_SUFFIX"
  # shellcheck disable=SC2016  # Expanded by the child bash.
  WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 GH_TOKEN=poison-not-a-token DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" \
    setsid --wait timeout "$NESTED_SERVICE_RUN_LIMIT_SECONDS" \
    bash -c 'source "$1" || exit 99; shift; "$@"' nested-call "$NESTED_SCRIPT" run_isolated "$run_dir" \
    env GSETTINGS_BACKEND=memory DBUS_SESSION_BUS_ADDRESS="unix:path=$run_dir/bus/session.sock" \
    PATH="$NESTED_SERVICE_STUB_BIN:/usr/bin:/bin" NESTED_SERVICE_CALLS="$NESTED_SERVICE_CALLS" \
    NESTED_SERVICE_ENV_NAMES="$NESTED_SERVICE_ENV_NAMES" NESTED_SERVICE_BUS_SEEN="$NESTED_SERVICE_BUS_SEEN" \
    NESTED_SERVICE_STARTED="$NESTED_SERVICE_STARTED" NESTED_SERVICE_STAND_IN_TEXT="$NESTED_SERVICE_STAND_IN_TEXT" \
    NESTED_SERVICE_BUS_NAME_BY_ENTRY="$NESTED_SERVICE_BUS_NAME_BY_ENTRY" \
    NESTED_SERVICE_MODE="$2" bash "$NESTED_SCRIPT" __inside-session-bus "$run_dir" >/dev/null 2>&1
  NESTED_SERVICE_EXIT=$?
  NESTED_SERVICE_ELAPSED_SECONDS=$((SECONDS - started_seconds))
}
# end_recorded_stand_ins <run dir>: the stand-ins wait after the stage ends; end
# each, only while it is still the process the run recorded.
end_recorded_stand_ins() {
  local process_name stand_in_pid stand_in_starttime
  for process_name in service cockpit; do
    stand_in_pid="$(grep "^$process_name=" "$1/state/run.values" 2>/dev/null | cut -d= -f2)"
    stand_in_starttime="$(grep "^$process_name-starttime=" "$1/state/run.values" 2>/dev/null | cut -d= -f2)"
    [[ -n "$stand_in_pid" ]] && kill_sacrifice "$stand_in_pid" sleep "$stand_in_starttime"
  done
  return 0
}

SERVICE_RUN="$(make_service_run Service1)"
run_in_bus_stage_with_service "$SERVICE_RUN" waits
SERVICE_RUN_PRIVATE_BUS="unix:path=$SERVICE_RUN/bus/session.sock"
SAMPLER_ENV_NAMES_SEEN="$NESTED_SERVICE_ENV_NAMES.$SAMPLER_ENTRY_FILE_NAME"
COCKPIT_ENV_NAMES_SEEN="$NESTED_SERVICE_ENV_NAMES.$COCKPIT_ENTRY_FILE_NAME"
# What a service may see: the allowlist, the private bus, and what this row
# itself passes the stubs (PWD, SHLVL and _ are bash's own). Byte order for both
# sort and comm: uutils comm compares bytes whatever the locale's collation.
ALLOWED_SERVICE_ENV_NAMES="$( { nested_call nested_environment_assignments "$SERVICE_RUN" | cut -d= -f1
  printf '%s\n' DBUS_SESSION_BUS_ADDRESS GSETTINGS_BACKEND NESTED_SERVICE_CALLS NESTED_SERVICE_ENV_NAMES \
    NESTED_SERVICE_BUS_SEEN NESTED_SERVICE_STARTED NESTED_SERVICE_STAND_IN_TEXT NESTED_SERVICE_BUS_NAME_BY_ENTRY \
    NESTED_SERVICE_MODE PWD SHLVL _
} | LC_ALL=C sort -u)"
ALLOWLIST_ENV_NAMES="$(nested_call nested_environment_assignments "$SERVICE_RUN" | cut -d= -f1 | LC_ALL=C sort -u)"
# unexpected_env_names <env names file>: the names in it that are not allowed, space-separated.
unexpected_env_names() {
  LC_ALL=C sort -u "$1" | LC_ALL=C comm -23 - <(printf '%s\n' "$ALLOWED_SERVICE_ENV_NAMES") | tr '\n' ' '
}
# allowlist_names_seen_in <env names file>: how many of the allowlist's names it holds. An empty
# record would have no unexpected name either: the whole allowlist must be there.
allowlist_names_seen_in() {
  LC_ALL=C sort -u "$1" | LC_ALL=C comm -12 - <(printf '%s\n' "$ALLOWLIST_ENV_NAMES") | wc -l
}
service_start_summary="exit=$NESTED_SERVICE_EXIT"
service_start_summary+=" gjs=[$(grep -m 1 '^gjs ' "$NESTED_SERVICE_CALLS")]"
service_start_summary+=" bus=$([[ "$(<"$NESTED_SERVICE_BUS_SEEN.$SAMPLER_ENTRY_FILE_NAME")" == "$SERVICE_RUN_PRIVATE_BUS" ]] && printf private || printf other)"
service_start_summary+=" allowlist-seen=$(allowlist_names_seen_in "$SAMPLER_ENV_NAMES_SEEN") unexpected=[$(unexpected_env_names "$SAMPLER_ENV_NAMES_SEEN")]"
service_start_summary+=" recorded=$(grep -c -E '^service(-starttime)?=[0-9]+$' "$SERVICE_RUN/state/run.values")"
service_start_summary+=" $(grep '^service-recorded-before-the-shell=' "$NESTED_SERVICE_CALLS")"
service_start_summary+=" asked-the-private-bus=$(grep -c -x -F "busctl --address=$SERVICE_RUN_PRIVATE_BUS call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus NameHasOwner s $RESOURCE_PULSE_BUS_NAME" "$NESTED_SERVICE_CALLS" | sed 's/^[1-9][0-9]*$/yes/')"
service_start_summary+=" logged=$(grep -c -x -F "$NESTED_SERVICE_STAND_IN_TEXT" "$SERVICE_RUN/log/service.log" 2>/dev/null)"
check "nested: the in-bus stage starts the run's copy of the service on the private bus, with only the allowlist, before the shell" \
  "$service_start_summary" \
  "exit=0 gjs=[gjs -m $SERVICE_RUN/$NESTED_SERVICE_MAIN_RELATIVE_PATH] bus=private allowlist-seen=22 unexpected=[] recorded=2 service-recorded-before-the-shell=1 asked-the-private-bus=yes logged=1"

# The same run, for the cockpit: started second, from the run's copy of
# service/cockpit.js, with the same allowlist and bus, recorded as `cockpit`
# before the shell, its own name asked for, and its own log.
cockpit_start_summary="exit=$NESTED_SERVICE_EXIT"
cockpit_start_summary+=" starts=[$(grep '^gjs ' "$NESTED_SERVICE_CALLS" | sed "s|^gjs -m $SERVICE_RUN/||" | tr '\n' ' ')]"
cockpit_start_summary+=" bus=$([[ "$(<"$NESTED_SERVICE_BUS_SEEN.$COCKPIT_ENTRY_FILE_NAME")" == "$SERVICE_RUN_PRIVATE_BUS" ]] && printf private || printf other)"
cockpit_start_summary+=" allowlist-seen=$(allowlist_names_seen_in "$COCKPIT_ENV_NAMES_SEEN") unexpected=[$(unexpected_env_names "$COCKPIT_ENV_NAMES_SEEN")]"
cockpit_start_summary+=" recorded=$(grep -c -E '^cockpit(-starttime)?=[0-9]+$' "$SERVICE_RUN/state/run.values")"
cockpit_start_summary+=" $(grep '^cockpit-recorded-before-the-shell=' "$NESTED_SERVICE_CALLS")"
cockpit_start_summary+=" asked-the-private-bus=$(grep -c -x -F "busctl --address=$SERVICE_RUN_PRIVATE_BUS call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus NameHasOwner s $COCKPIT_BUS_NAME" "$NESTED_SERVICE_CALLS" | sed 's/^[1-9][0-9]*$/yes/')"
cockpit_start_summary+=" logged=$(grep -c -x -F "$NESTED_SERVICE_STAND_IN_TEXT" "$SERVICE_RUN/log/cockpit.log" 2>/dev/null)"
end_recorded_stand_ins "$SERVICE_RUN"
check "nested: the in-bus stage starts the run's copy of service/cockpit.js after the sampler, on the private bus, before the shell" \
  "$cockpit_start_summary" \
  "exit=0 starts=[$NESTED_SERVICE_MAIN_RELATIVE_PATH $NESTED_COCKPIT_MAIN_RELATIVE_PATH ] bus=private allowlist-seen=22 unexpected=[] recorded=2 cockpit-recorded-before-the-shell=1 asked-the-private-bus=yes logged=1"

check "nested: the harness names the run's copy of service/cockpit.js and the cockpit's bus name, beside the sampler's" \
  "entry=$(nested_constant_text COCKPIT_MAIN_RELATIVE_PATH) bus=$(nested_constant_text COCKPIT_BUS_NAME)" \
  "entry=$NESTED_COCKPIT_MAIN_RELATIVE_PATH bus=$COCKPIT_BUS_NAME"

# The cockpit reads its layout from <XDG_CONFIG_HOME>/resource-pulse/cockpit.json:
# the run's config home, as the run's environment names it, holds the template.
SERVICE_RUN_CONFIG_HOME="$(nested_call nested_environment_assignments "$SERVICE_RUN" | sed -n 's/^XDG_CONFIG_HOME=//p')"
check "nested: the run's XDG_CONFIG_HOME holds the cockpit config template as resource-pulse/cockpit.json" \
  "$(cmp -s "$COCKPIT_CONFIG_TEMPLATE" "$SERVICE_RUN_CONFIG_HOME/$COCKPIT_CONFIG_RELATIVE_PATH" && printf same || printf differs-or-missing)" \
  same

# The collection log: the nested gnome-shell's environment, as its stand-in
# recorded it, beyond the allowlist and what this row passes the stubs. The run
# above was started with neither option; the next records gc-log=1, as
# `start --gc-log` does. The two variables are the shell's alone: both services
# start before they are set.
NESTED_SHELL_ENV_NAMES_SEEN="$NESTED_SERVICE_ENV_NAMES.$NESTED_SHELL_ENV_NAMES_SUFFIX"
# shell_environment_summary prints the shell's unexpected names, how many allowlist names it held, and the two
# variables' values.
shell_environment_summary() {
  printf 'unexpected=[%s] allowlist=%s %s' "$(unexpected_env_names "$NESTED_SHELL_ENV_NAMES_SEEN")" \
    "$(allowlist_names_seen_in "$NESTED_SHELL_ENV_NAMES_SEEN")" "$(grep '^shell-gc-variables=' "$NESTED_SERVICE_CALLS")"
}
gc_log_summary="without: exit=$NESTED_SERVICE_EXIT $(shell_environment_summary)"
GC_LOG_RUN="$(make_service_run GcLog001)"
printf 'gc-log=1\n' >>"$GC_LOG_RUN/state/run.values" || fatal "cannot record gc-log=1 in $GC_LOG_RUN"
run_in_bus_stage_with_service "$GC_LOG_RUN" waits
gc_log_summary+=" with: exit=$NESTED_SERVICE_EXIT $(shell_environment_summary)"
gc_log_summary+=" sampler=[$(unexpected_env_names "$SAMPLER_ENV_NAMES_SEEN")]"
gc_log_summary+=" cockpit=[$(unexpected_env_names "$COCKPIT_ENV_NAMES_SEEN")]"
end_recorded_stand_ins "$GC_LOG_RUN"
check "nested: with gc-log=1 the nested gnome-shell gets exactly JS_GC_PROFILE=0 and JS_GC_PROFILE_NURSERY=0 beyond the allowlist, without it neither, and the services never" \
  "$gc_log_summary" \
  "without: exit=0 unexpected=[] allowlist=22 shell-gc-variables=JS_GC_PROFILE=unset,JS_GC_PROFILE_NURSERY=unset with: exit=0 unexpected=[JS_GC_PROFILE JS_GC_PROFILE_NURSERY ] allowlist=22 shell-gc-variables=JS_GC_PROFILE=0,JS_GC_PROFILE_NURSERY=0 sampler=[] cockpit=[]"

# Fixed input: with replay=1 recorded, as `start --replay` does, the run's copy
# of the replay service starts in place of service/main.js, given the run's copy
# of the extension, on the private bus with only the allowlist, recorded and
# logged as the service (so `stop` ends it), before the cockpit and the shell.
REPLAY_SERVICE_RUN="$(make_service_run Replay01)"
printf 'replay=1\n' >>"$REPLAY_SERVICE_RUN/state/run.values" || fatal "cannot record replay=1 in $REPLAY_SERVICE_RUN"
run_in_bus_stage_with_service "$REPLAY_SERVICE_RUN" waits
REPLAY_ENV_NAMES_SEEN="$NESTED_SERVICE_ENV_NAMES.$REPLAY_ENTRY_FILE_NAME"
replay_start_summary="exit=$NESTED_SERVICE_EXIT"
replay_start_summary+=" starts=[$(grep '^gjs ' "$NESTED_SERVICE_CALLS" | sed "s|$REPLAY_SERVICE_RUN/||g" | tr '\n' ';')]"
replay_start_summary+=" copies=$(cmp -s "$NESTED_FILES/$REPLAY_ENTRY_FILE_NAME" "$REPLAY_SERVICE_RUN/$NESTED_REPLAY_MAIN_RELATIVE_PATH" &&
  cmp -s "$NESTED_FILES/replayGenerator.js" "$REPLAY_SERVICE_RUN/replay/replayGenerator.js" && printf same || printf differ)"
replay_start_summary+=" bus=$([[ "$(<"$NESTED_SERVICE_BUS_SEEN.$REPLAY_ENTRY_FILE_NAME")" == "unix:path=$REPLAY_SERVICE_RUN/bus/session.sock" ]] && printf private || printf other)"
replay_start_summary+=" allowlist-seen=$(allowlist_names_seen_in "$REPLAY_ENV_NAMES_SEEN") unexpected=[$(unexpected_env_names "$REPLAY_ENV_NAMES_SEEN")]"
replay_start_summary+=" recorded=$(grep -c -E '^service(-starttime)?=[0-9]+$' "$REPLAY_SERVICE_RUN/state/run.values")"
replay_start_summary+=" $(grep '^service-recorded-before-the-shell=' "$NESTED_SERVICE_CALLS")"
replay_start_summary+=" asked-the-private-bus=$(grep -c -x -F "busctl --address=unix:path=$REPLAY_SERVICE_RUN/bus/session.sock call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus NameHasOwner s $RESOURCE_PULSE_BUS_NAME" "$NESTED_SERVICE_CALLS" | sed 's/^[1-9][0-9]*$/yes/')"
replay_start_summary+=" logged=$(grep -c -x -F "$NESTED_SERVICE_STAND_IN_TEXT" "$REPLAY_SERVICE_RUN/log/service.log" 2>/dev/null)"
end_recorded_stand_ins "$REPLAY_SERVICE_RUN"
check "nested: with replay=1 the in-bus stage starts the run's copy of replay-service.js in place of service/main.js, given the run's extension, on the private bus, as the service" \
  "$replay_start_summary" \
  "exit=0 starts=[gjs -m $NESTED_REPLAY_MAIN_RELATIVE_PATH $NESTED_EXTENSION_RELATIVE_PATH;gjs -m $NESTED_COCKPIT_MAIN_RELATIVE_PATH;] copies=same bus=private allowlist-seen=22 unexpected=[] recorded=2 service-recorded-before-the-shell=1 asked-the-private-bus=yes logged=1"

# A run whose copy of the extension has no service/cockpit.js: the cockpit's
# stand-in exits at once, as gjs does, and the run must refuse, naming it.
MISSING_COCKPIT_RUN="$(make_service_run Service3)"
rm -f -- "${MISSING_COCKPIT_RUN:?}/$NESTED_COCKPIT_MAIN_RELATIVE_PATH" || fatal "cannot remove the run's service/cockpit.js"
run_in_bus_stage_with_service "$MISSING_COCKPIT_RUN" waits
missing_cockpit_summary="exit=$NESTED_SERVICE_EXIT"
missing_cockpit_summary+=" refused=$(grep -c -F "the service at $NESTED_COCKPIT_MAIN_RELATIVE_PATH did not take $COCKPIT_BUS_NAME" "$MISSING_COCKPIT_RUN/state/refused" 2>/dev/null)"
missing_cockpit_summary+=" shell-started=$(grep -c '^gnome-shell ' "$NESTED_SERVICE_CALLS")"
missing_cockpit_summary+=" address=$([[ -e "$MISSING_COCKPIT_RUN/state/session.addr" ]] && printf recorded || printf none)"
missing_cockpit_summary+=" at-once=$( (( NESTED_SERVICE_ELAPSED_SECONDS < NESTED_SERVICE_START_TIMEOUT_SECONDS )) && printf yes || printf 'no-%ss' "$NESTED_SERVICE_ELAPSED_SECONDS")"
end_recorded_stand_ins "$MISSING_COCKPIT_RUN"
check "nested: a run with no service/cockpit.js refuses at once, naming the cockpit, and the shell never starts" \
  "$missing_cockpit_summary" "exit=2 refused=1 shell-started=0 address=none at-once=yes"

EXITING_SERVICE_RUN="$(make_service_run Service2)"
run_in_bus_stage_with_service "$EXITING_SERVICE_RUN" exits
exiting_service_summary="exit=$NESTED_SERVICE_EXIT"
exiting_service_summary+=" refused=$(grep -c -F "the service at $NESTED_SERVICE_MAIN_RELATIVE_PATH did not take $RESOURCE_PULSE_BUS_NAME" "$EXITING_SERVICE_RUN/state/refused" 2>/dev/null)"
exiting_service_summary+=" shell-started=$(grep -c '^gnome-shell ' "$NESTED_SERVICE_CALLS")"
exiting_service_summary+=" address=$([[ -e "$EXITING_SERVICE_RUN/state/session.addr" ]] && printf recorded || printf none)"
exiting_service_summary+=" at-once=$( (( NESTED_SERVICE_ELAPSED_SECONDS < NESTED_SERVICE_START_TIMEOUT_SECONDS )) && printf yes || printf 'no-%ss' "$NESTED_SERVICE_ELAPSED_SECONDS")"
check "nested: a service that exits before owning its name refuses the run at once, and the shell never starts" \
  "$exiting_service_summary" "exit=2 refused=1 shell-started=0 address=none at-once=yes"

# stop_with_recorded_sleep_in_session <process name> <run suffix>: a session led
# by the run's timeout, whose child bash runs a `sleep` recorded as <process
# name>, is stopped. Prints stop's exit, whether that sleep ended, and whether
# stop returned before STOP_GRACE_SECONDS: without its own SIGTERM the sleep
# would linger that long, until the session sweep.
stop_with_recorded_sleep_in_session() {
  local process_name="$1" run_dir="$NESTED_BASE/rpn.$2" sleep_pid_file="$SACRIFICE_DIR/$1-sleep.pid"
  local session_id session_starttime sleep_pid sleep_starttime stop_started_seconds stop_elapsed_seconds
  local sleep_fate stop_timing
  # shellcheck disable=SC2016  # Expanded by the sacrificial session's own bash.
  session_id="$(start_sacrificial_session timeout 60 bash -c 'sleep 60 & printf "%s\n" "$!" >"$1"; wait' \
    "sacrificial-$process_name" "$sleep_pid_file")"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "$sleep_pid_file" && "$(cat "/proc/$session_id/comm" 2>/dev/null)" == timeout ]] && break
    sleep 0.1
  done
  sleep_pid="$(cat "$sleep_pid_file")"
  session_starttime="$(starttime_of "$session_id")"
  sleep_starttime="$(starttime_of "$sleep_pid")"
  make_run_dir "$run_dir" "launcher=$session_id" "launcher-starttime=$session_starttime" \
    "session=$session_id" "supervisor=$session_id" "supervisor-starttime=$session_starttime" \
    "$process_name=$sleep_pid" "$process_name-starttime=$sleep_starttime"
  stop_started_seconds=$SECONDS
  NESTED_RUN_DIR="$run_dir" nested_run stop
  stop_elapsed_seconds=$((SECONDS - stop_started_seconds))
  sleep_fate="$(is_running "$sleep_pid" && printf left-running || printf ended)"
  stop_timing="$( (( stop_elapsed_seconds < NESTED_STOP_GRACE_SECONDS )) && printf at-once || printf 'after-%ss' "$stop_elapsed_seconds")"
  kill_sacrifice "$sleep_pid" sleep "$sleep_starttime"
  kill_sacrifice "$session_id" timeout "$session_starttime"
  rm -rf "$run_dir"
  printf '%s/%s/%s' "$NESTED_EXIT" "$sleep_fate" "$stop_timing"
}

# `stop` ends the recorded service in the run's session at once, and never one
# outside it. (1) A session led by the run's timeout, whose child bash runs a
# `sleep` recorded as the service. (2) A session led by the run's timeout (also
# recorded as its gnome-shell, so it ends at once), whose recorded service is a
# process of ANOTHER session: that one must be left running.
service_stop_summary="in-session=$(stop_with_recorded_sleep_in_session service SvcStop1)"
outside_service_id="$(start_sacrificial_session sleep 60)"
outside_service_starttime="$(starttime_of "$outside_service_id")"
outside_run_session_id="$(start_sacrificial_session timeout 60 sleep 60)"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ "$(cat "/proc/$outside_run_session_id/comm" 2>/dev/null)" == timeout ]] && break
  sleep 0.1
done
outside_run_session_starttime="$(starttime_of "$outside_run_session_id")"
OUTSIDE_SERVICE_RUN="$NESTED_BASE/rpn.SvcStop2"
make_run_dir "$OUTSIDE_SERVICE_RUN" "launcher=$outside_run_session_id" \
  "launcher-starttime=$outside_run_session_starttime" "session=$outside_run_session_id" \
  "supervisor=$outside_run_session_id" "supervisor-starttime=$outside_run_session_starttime" \
  "gnome-shell=$outside_run_session_id" "gnome-shell-starttime=$outside_run_session_starttime" \
  "service=$outside_service_id" "service-starttime=$outside_service_starttime"
NESTED_RUN_DIR="$OUTSIDE_SERVICE_RUN" nested_run stop
service_stop_summary+=" outside=$NESTED_EXIT/$(is_running "$outside_service_id" && printf left-running || printf ended)"
kill_sacrifice "$outside_service_id" sleep "$outside_service_starttime"
kill_sacrifice "$outside_run_session_id" timeout "$outside_run_session_starttime"
check "nested: stop ends the run's recorded service in its session at once, and leaves one in another session alone" \
  "$service_stop_summary" "in-session=0/ended/at-once outside=0/left-running"
rm -rf "$OUTSIDE_SERVICE_RUN"

check "nested: stop ends the run's recorded cockpit in its session at once" \
  "$(stop_with_recorded_sleep_in_session cockpit CkptStop1)" "0/ended/at-once"

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

EXPECTED_ROWS=1017

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
