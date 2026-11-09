#!/usr/bin/env bash
#
# scripts/resource-pulse-module-closure.sh
# ========================================
#
# Prints the static import closure of one module of the Resource Pulse GNOME
# Shell extension (gnome-shell/extensions/resource-pulse@dotfiles): the module
# itself and every module it imports, directly or through another, one per
# line, relative to the extension directory. The extension has two sides that
# load code at different times, and each stale-code check follows its own side
# (ruling R23):
#   - the shell side, extension.js and what it imports, is loaded once per
#     login: gnome-status's "the desktop runs an older copy" ⚠
#     (zsh/functions/system.sh);
#   - the service side, service/main.js and what it imports, runs in
#     resource-pulse.service: the refresh step's try-restart
#     (scripts/resource-pulse-service-refresh.sh) and gnome-status's "runs
#     older code" ⚠.
# So a module both import (lib/protocol.js) counts for both, one only the
# service imports (lib/cadence.js) never makes the desktop's copy older, and
# one only the shell imports (lib/visibility.js) never restarts the service.
#
# What it follows:
#   - a static `import … from '<specifier>';` on one line or several (a comment
#     line inside is skipped), a side-effect `import '<specifier>';`, and a
#     re-export `export {…} from '<specifier>';` or `export * from …`, each
#     starting its line and ending at its `;`;
#   - a dynamic `import('<specifier>')` whose argument is one string literal;
#   - a relative specifier (./ or ../), resolved against the importing module's
#     directory. Any other (gi://, resource:///, a bare name such as system)
#     names no file of the extension and is skipped.
# What it does not: a line that is a comment (it starts with //, /* or *, as
# every JSDoc line here does), so a type like `import('./x.js').Foo` in JSDoc
# is no import; and `import.meta`.
#
# Anything else that says `import`, or a stray `from './x.js'`, is a shape it
# does not understand: a dynamic import of a computed specifier, an import not
# starting its line, one that never reaches its `;`, an import it cannot parse.
# So is a relative import naming no file, or leaving the extension directory,
# and an absolute or file: specifier. Each is exit 2 with a line on stderr
# naming the module and its line, and nothing on stdout: a closure missing a
# module would silently skip a stale-code check, so it never prints a partial
# one. Its own rows are in scripts/test-resource-pulse.sh.
#
# Pure bash, with no grep (a ugrep shim here), awk (mawk) or find, so it runs
# wherever the refresh step does.
#
# Usage: scripts/resource-pulse-module-closure.sh <extension dir> <module>
#   <module> is relative to <extension dir>: extension.js, or service/main.js.
# Exit: 0 with the closure printed; 2 when it cannot say.

set -uo pipefail

EXIT_CANNOT_SAY=2
SCRIPT_NAME="resource-pulse-module-closure"
# A line that is all comment: JSDoc lines start with *, block comments with /*.
COMMENT_LINE_PATTERN='^[[:space:]]*(//|/\*|\*)'
# A trailing line comment after a statement's closing `;`.
TRAILING_COMMENT_PATTERN=';[[:space:]]*//.*$'
# The start of a statement that imports: an import, or an export list that may
# re-export from another module.
IMPORT_STATEMENT_START_PATTERN="^import([[:space:]{*'\"]|\$)"
EXPORT_LIST_START_PATTERN='^export[[:space:]]*[{*]'
# A whole statement, its lines joined: `import|export <no quote> from '<spec>';`,
# or a side-effect `import '<spec>';`. No quote may come before `from`, so two
# statements that ran together (a missing `;`) never parse as one.
FROM_SINGLE_QUOTED_PATTERN="^(import|export)[^'\"]*[^A-Za-z0-9_\$]from[[:space:]]*'([^']+)'[[:space:]]*;\$"
FROM_DOUBLE_QUOTED_PATTERN="^(import|export)[^'\"]*[^A-Za-z0-9_\$]from[[:space:]]*\"([^\"]+)\"[[:space:]]*;\$"
SIDE_EFFECT_SINGLE_QUOTED_PATTERN="^import[[:space:]]*'([^']+)'[[:space:]]*;\$"
SIDE_EFFECT_DOUBLE_QUOTED_PATTERN="^import[[:space:]]*\"([^\"]+)\"[[:space:]]*;\$"
# An export list that names no module: `export {a, b};`, which imports nothing.
LOCAL_EXPORT_LIST_PATTERN="^export[[:space:]]*\{[^'\"]*\}[[:space:]]*;\$"
# Inside any other line: a dynamic import of one string literal, import.meta,
# the word import itself (not part of a longer name, nor a property), and a
# `from` naming a relative module.
DYNAMIC_SINGLE_QUOTED_PATTERN="import[[:space:]]*\([[:space:]]*'([^']+)'[[:space:]]*\)"
DYNAMIC_DOUBLE_QUOTED_PATTERN="import[[:space:]]*\([[:space:]]*\"([^\"]+)\"[[:space:]]*\)"
IMPORT_META_PATTERN='import\.meta'
IMPORT_WORD_PATTERN='(^|[^A-Za-z0-9_$.])import([^A-Za-z0-9_$]|$)'
RELATIVE_FROM_PATTERN="(^|[^A-Za-z0-9_\$.])from[[:space:]]*['\"]\.\.?/"
RELATIVE_SPECIFIER_PATTERN='^\.\.?/'
FILE_SPECIFIER_PATTERN='^(/|file:)'

# fail <message>: one line on stderr, then exit 2 with nothing printed.
fail() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$EXIT_CANNOT_SAY"
}

# normalized_module_path <path>: the path with . and .. resolved, relative to the
# extension directory; fails when it is empty or leaves that directory.
normalized_module_path() {
  local joined_path="$1" path_segment
  local -a raw_segments normalized_segments=()
  IFS='/' read -r -a raw_segments <<<"$joined_path"
  for path_segment in "${raw_segments[@]}"; do
    case "$path_segment" in
      '' | '.') ;;
      '..')
        (( ${#normalized_segments[@]} > 0 )) || return 1
        unset 'normalized_segments[-1]'
        ;;
      *) normalized_segments+=("$path_segment") ;;
    esac
  done
  (( ${#normalized_segments[@]} > 0 )) || return 1
  local IFS='/'
  printf '%s\n' "${normalized_segments[*]}"
}

# queue_specifier <importing module> <line number> <specifier>: queues the module
# a relative specifier names, once; skips one that names no file of the
# extension; fails on one it cannot place.
queue_specifier() {
  local importing_module="$1" line_number="$2" specifier="$3" importing_directory="" imported_module
  if [[ "$specifier" =~ $FILE_SPECIFIER_PATTERN ]]; then
    fail "$importing_module:$line_number: cannot place the absolute specifier '$specifier'"
  fi
  [[ "$specifier" =~ $RELATIVE_SPECIFIER_PATTERN ]] || return 0
  [[ "$importing_module" == */* ]] && importing_directory="${importing_module%/*}"
  if ! imported_module="$(normalized_module_path "$importing_directory/$specifier")"; then
    fail "$importing_module:$line_number: '$specifier' leaves the extension directory"
  fi
  if [[ ! -f "$EXTENSION_DIR/$imported_module" || ! -r "$EXTENSION_DIR/$imported_module" ]]; then
    fail "$importing_module:$line_number: '$specifier' names no readable file ($imported_module)"
  fi
  if [[ -z "${IS_QUEUED[$imported_module]:-}" ]]; then
    IS_QUEUED[$imported_module]=1
    MODULE_QUEUE+=("$imported_module")
  fi
}

# finish_statement <module> <line number> <statement>: queues what a whole
# import or export statement imports; fails on one it cannot parse.
finish_statement() {
  local module="$1" line_number="$2" statement="$3"
  statement="${statement%"${statement##*[![:space:]]}"}"
  if [[ "$statement" =~ $FROM_SINGLE_QUOTED_PATTERN || "$statement" =~ $FROM_DOUBLE_QUOTED_PATTERN ]]; then
    queue_specifier "$module" "$line_number" "${BASH_REMATCH[2]}"
  elif [[ "$statement" =~ $SIDE_EFFECT_SINGLE_QUOTED_PATTERN || "$statement" =~ $SIDE_EFFECT_DOUBLE_QUOTED_PATTERN ]]; then
    queue_specifier "$module" "$line_number" "${BASH_REMATCH[1]}"
  elif [[ ! "$statement" =~ $LOCAL_EXPORT_LIST_PATTERN ]]; then
    fail "$module:$line_number: cannot parse the statement: $statement"
  fi
}

# check_code_line <module> <line number> <line>: queues the literal dynamic
# imports in a line that starts no statement, and fails when anything else in it
# says import, or names a relative module after from.
check_code_line() {
  local module="$1" line_number="$2" remaining_line="$3" dynamic_import_text dynamic_specifier
  while [[ "$remaining_line" =~ $DYNAMIC_SINGLE_QUOTED_PATTERN || "$remaining_line" =~ $DYNAMIC_DOUBLE_QUOTED_PATTERN ]]; do
    # Read before queue_specifier, whose own matches replace BASH_REMATCH.
    dynamic_import_text="${BASH_REMATCH[0]}"
    dynamic_specifier="${BASH_REMATCH[1]}"
    queue_specifier "$module" "$line_number" "$dynamic_specifier"
    remaining_line="${remaining_line/"$dynamic_import_text"/ }"
  done
  while [[ "$remaining_line" =~ $IMPORT_META_PATTERN ]]; do
    remaining_line="${remaining_line/"${BASH_REMATCH[0]}"/ }"
  done
  if [[ "$remaining_line" =~ $IMPORT_WORD_PATTERN || "$remaining_line" =~ $RELATIVE_FROM_PATTERN ]]; then
    fail "$module:$line_number: an import shape it does not understand: $3"
  fi
}

# scan_module <module>: queues every module one module imports.
scan_module() {
  local module="$1" line line_number=0 statement="" statement_line_number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    [[ "$line" =~ $COMMENT_LINE_PATTERN ]] && continue
    if [[ -n "$statement" ]]; then
      statement+=" $line"
    elif [[ "$line" =~ $IMPORT_STATEMENT_START_PATTERN || "$line" =~ $EXPORT_LIST_START_PATTERN ]]; then
      statement="$line"
      statement_line_number="$line_number"
    else
      check_code_line "$module" "$line_number" "$line"
      continue
    fi
    if [[ "$line" == *';'* ]]; then
      [[ "$statement" =~ $TRAILING_COMMENT_PATTERN ]] && statement="${statement%%"${BASH_REMATCH[0]}"};"
      finish_statement "$module" "$statement_line_number" "$statement"
      statement=""
    fi
  done <"$EXTENSION_DIR/$module"
  if [[ -n "$statement" ]]; then
    fail "$module:$statement_line_number: the statement never reaches its ;: $statement"
  fi
}

main() {
  (( $# == 2 )) || fail "usage: resource-pulse-module-closure.sh <extension dir> <module>"
  EXTENSION_DIR="$1"
  local entry_module module_index=0
  [[ -d "$EXTENSION_DIR" ]] || fail "no extension directory at $EXTENSION_DIR"
  entry_module="$(normalized_module_path "$2")" || fail "the module '$2' is not inside $EXTENSION_DIR"
  [[ -f "$EXTENSION_DIR/$entry_module" && -r "$EXTENSION_DIR/$entry_module" ]] \
    || fail "$entry_module: no readable file under $EXTENSION_DIR"
  declare -gA IS_QUEUED=(["$entry_module"]=1)
  MODULE_QUEUE=("$entry_module")
  while (( module_index < ${#MODULE_QUEUE[@]} )); do
    scan_module "${MODULE_QUEUE[module_index]}"
    module_index=$((module_index + 1))
  done
  printf '%s\n' "${MODULE_QUEUE[@]}"
}

main "$@"
