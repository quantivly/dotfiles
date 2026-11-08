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

EXPECTED_ROWS=149

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( PASS + FAIL != EXPECTED_ROWS )); then
  printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
    "$EXPECTED_ROWS" "$((PASS + FAIL))"
  FAIL=$((FAIL + 1))
fi
(( FAIL == 0 ))
