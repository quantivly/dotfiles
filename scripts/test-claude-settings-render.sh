#!/usr/bin/env bash
#
# scripts/test-claude-settings-render.sh
# ======================================
#
# State table for scripts/claude-settings-render.sh: rendering ~/.claude/settings.json from the
# public base fragment plus the private tenant overlays of the host's profile.
#
# HERMETIC. Every row runs against fixtures under mktemp -d. The whole table runs under a
# fixture HOME, and the marker, the overlay root and the settings path are always given
# explicitly, so nothing here reads or writes the real home.
# Requires: bash, jq.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$DOTFILES/scripts/claude-settings-render.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

HOME="$TMPROOT/home"
mkdir -p "$HOME"
export HOME

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
has()   { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 — '$3' not in: ${2:0:600}"; fi; }
hasnt() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 — '$3' unexpectedly in: ${2:0:600}"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

for tool in bash jq; do command -v "$tool" >/dev/null || fatal "$tool is required"; done
[[ -x "$SUT" ]] || fatal "$SUT is not executable — every row below would assert nothing"

# ---------------------------------------------------------------------------------------------
# Fixtures: a marker, an overlay root, and a settings file the SUT must never touch in these rows
# ---------------------------------------------------------------------------------------------

OVERLAY="$TMPROOT/overlay"
MARKER="$TMPROOT/marker"
SETTINGS="$TMPROOT/settings.json"
mkdir -p "$OVERLAY/hosts" "$OVERLAY/claude/settings"
printf '{}\n' > "$OVERLAY/claude/settings/common.json"
printf '{}\n' > "$OVERLAY/claude/settings/alpha.json"
printf '{}\n' > "$OVERLAY/claude/settings/beta.json"
printf '{"tenants":["alpha","beta"]}\n' > "$OVERLAY/hosts/laptop.json"
printf '{"tenants":["alpha","gamma"]}\n' > "$OVERLAY/hosts/missing-tenant.json"
printf '{"live":"settings"}\n' > "$SETTINGS"

# run_sut ARGS… → combined output in $OUT, exit status in $RC. The marker is named per call by
# $MARKER_FILE (default: the fixture marker), so a row can point at an absent one.
MARKER_FILE="$MARKER"
run_sut() {
    OUT=$(CLAUDE_SETTINGS_RENDER_MARKER="$MARKER_FILE" CLAUDE_SETTINGS_RENDER_OVERLAY="$OVERLAY" \
        "$SUT" "$@" 2>&1); RC=$?
}

contains() { [[ "$1" == *"$2"* ]] && printf yes || printf no; }   # HAYSTACK NEEDLE → yes|no

printf 'usage: the verb is required, and --help prints the usage\n'
run_sut
check "usage: no verb → exit 64" "$RC" "64"
run_sut --help
check "usage: --help → exit 0 with the usage text naming every verb" \
    "$RC|$(contains "$OUT" '--check')$(contains "$OUT" '--print')$(contains "$OUT" '--apply')$(contains "$OUT" '--list-fragments')" \
    "0|yesyesyesyes"

printf 'profile: marker, profile file, tenants and fragment order\n'
before=$(sha256sum "$SETTINGS")
MARKER_FILE="$TMPROOT/no-such-marker"
run_sut --apply --settings "$SETTINGS"
after=$(sha256sum "$SETTINGS")
check "no marker → exit 0, prints \"no host profile\", writes nothing" \
    "$RC|$(contains "$OUT" "no host profile at $TMPROOT/no-such-marker; nothing to render")|$([[ $before == "$after" ]] && echo untouched)" \
    "0|yes|untouched"

MARKER_FILE="$MARKER"
printf 'ghost\n' > "$MARKER"
run_sut --list-fragments
check "marker names a profile with no file → exit 2 naming the path" \
    "$RC|$(contains "$OUT" "$OVERLAY/hosts/ghost.json")" "2|yes"

printf 'missing-tenant\n' > "$MARKER"
run_sut --list-fragments
check "profile lists a tenant without a fragment → exit 2 naming the tenant" \
    "$RC|$(contains "$OUT" 'gamma')" "2|yes"

printf 'laptop\n' > "$MARKER"
run_sut --list-fragments
expected_order="$DOTFILES/claude/settings/base.json
$OVERLAY/claude/settings/common.json
$OVERLAY/claude/settings/alpha.json
$OVERLAY/claude/settings/beta.json"
check "fragments load in order base, common, tenants (profile order)" "$RC|$OUT" "0|$expected_order"

printf '\n'
EXPECTED_ROWS=6
if (( PASS + FAIL != EXPECTED_ROWS )); then
    fatal "expected $EXPECTED_ROWS rows, $((PASS + FAIL)) ran — a check vanished or was added without updating EXPECTED_ROWS"
fi
if (( FAIL )); then printf '\033[1;31m%d of %d failed\033[0m\n' "$FAIL" "$((PASS + FAIL))"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$PASS"
