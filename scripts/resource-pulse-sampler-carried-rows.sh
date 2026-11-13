#!/usr/bin/env bash
#
# scripts/resource-pulse-sampler-carried-rows.sh
# ===============================================
#
# Checks that every row of the gjs sampler's tests is carried over to the Rust
# crate or exempted with a reason. The list of titles is
# resource-pulse-sampler/tests/carried-rows.txt (regenerate it with
# scripts/resource-pulse-sampler-carried-rows-generate.py). Each title must be
# found EXACTLY ONCE, as one of:
#   - a `/// row: <title>` doc comment, at the start of a line (indentation allowed), on a Rust test,
#     anywhere under the crate; or
#   - a line `<title><TAB><reason>` in resource-pulse-sampler/tests/carried-rows-exempt.txt.
# A title found nowhere, twice, or both ported and exempt fails; so does an
# exempt line, or a `/// row:` marker, naming a title the list does not have (a port under a
# misspelled title would otherwise pass while the real title still reads as exempt).
#
# Output: one line per finding, `CARRIED-ROW pass|fail <what>: <title>`, which
# scripts/test-resource-pulse-sampler.sh counts.
# Exit: 0 all carried; 1 a title is missing, duplicated, double-counted or
# unknown (in the exempt file or in a marker); 2 a file cannot be read (never a pass).
#
# Flags (for the state table's fixtures; the defaults are the crate's own):
#   --crate-dir <dir>   --list <file>   --exempt <file>
# An unknown flag, or a list with no titles, is exit 2.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CRATE_DIR="$HERE/../resource-pulse-sampler"
LIST_FILE=""
EXEMPT_FILE=""
# The marker a Rust test carries to say which gjs row it ports: a doc comment at the start of a line.
# (A regular expression for rg, and the same text for awk to cut off the title.)
PORTED_ROW_MARKER_PATTERN='^\s*/// row: '
PORTED_ROW_MARKER_AWK_PATTERN='^[ \t]*/// row: '

fatal() { printf 'CARRIED-ROWS: %s\n' "$*" >&2; exit 2; }

while (( $# > 0 )); do
  case "$1" in
    --crate-dir|--list|--exempt)
      (( $# >= 2 )) || fatal "$1 needs a value"
      case "$1" in
        --crate-dir) CRATE_DIR="$2" ;;
        --list) LIST_FILE="$2" ;;
        --exempt) EXEMPT_FILE="$2" ;;
      esac
      shift 2 ;;
    *) fatal "unknown argument: $1" ;;
  esac
done
LIST_FILE="${LIST_FILE:-$CRATE_DIR/tests/carried-rows.txt}"
EXEMPT_FILE="${EXEMPT_FILE:-$CRATE_DIR/tests/carried-rows-exempt.txt}"

command -v rg >/dev/null || fatal "rg is required"
command -v awk >/dev/null || fatal "awk is required"
[[ -r "$LIST_FILE" ]] || fatal "cannot read the list $LIST_FILE"
[[ -r "$EXEMPT_FILE" ]] || fatal "cannot read the exempt file $EXEMPT_FILE"
rg -q -v -e '^#' -e '^$' "$LIST_FILE" || fatal "the list $LIST_FILE holds no titles"
[[ -d "$CRATE_DIR" ]] || fatal "no crate directory at $CRATE_DIR"

PORTED_LINES_FILE="$(mktemp)" || fatal "mktemp failed"
trap 'rm -f "$PORTED_LINES_FILE"' EXIT
# rg exits 1 for "no match" (an empty crate is a valid state) and 2 for an error.
rg --no-filename --no-line-number --no-messages --glob '*.rs' -e "$PORTED_ROW_MARKER_PATTERN" "$CRATE_DIR" >"$PORTED_LINES_FILE"
rg_status=$?
(( rg_status <= 1 )) || fatal "rg failed (exit $rg_status) reading $CRATE_DIR"

# POSIX awk (mawk here): count each title in the three sources, then judge.
awk -v marker_pattern="$PORTED_ROW_MARKER_AWK_PATTERN" '
  BEGIN { FS = "\t" }
  FILENAME == ARGV[1] {
    if ($0 == "" || substr($0, 1, 1) == "#") next
    titleCount++; titleAt[titleCount] = $0; inList[$0] = 1; next
  }
  FILENAME == ARGV[2] {
    if ($0 == "") next
    if (NF < 2 || $2 == "") { malformed = malformed "\n" $0; next }
    exemptCount[$1]++; next
  }
  {
    title = $0
    if (!sub(marker_pattern, "", title)) next
    portedCount[title]++
  }
  END {
    if (malformed != "") { printf "CARRIED-ROWS: exempt line without a reason:%s\n", malformed > "/dev/stderr"; exit 2 }
    failures = 0
    for (index_ = 1; index_ <= titleCount; index_++) {
      title = titleAt[index_]; ported = portedCount[title] + 0; exempt = exemptCount[title] + 0
      if (ported == 1 && exempt == 0) status = "pass ported"
      else if (ported == 0 && exempt == 1) status = "pass exempt"
      else if (ported > 0 && exempt > 0) status = "fail ported-and-exempt"
      else if (ported > 1 || exempt > 1) status = "fail duplicated"
      else status = "fail missing"
      if (substr(status, 1, 4) == "fail") failures++
      printf "CARRIED-ROW %s: %s\n", status, title
    }
    for (title in exemptCount) {
      if (!(title in inList)) { printf "CARRIED-ROW fail unknown-exempt: %s\n", title; failures++ }
    }
    for (title in portedCount) {
      if (!(title in inList)) { printf "CARRIED-ROW fail unknown-ported: %s\n", title; failures++ }
    }
    exit failures > 0 ? 1 : 0
  }
' "$LIST_FILE" "$EXEMPT_FILE" "$PORTED_LINES_FILE"
