#!/usr/bin/env bash
# shellcheck disable=SC2016  # fixtures and jq filters carry $HOME and jq's own $variables literally
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

# ---------------------------------------------------------------------------------------------
# The merge. Each row writes a live settings file and the overlay fragments, renders with --print
# and asserts on the render with jq. The base fragment is the checkout's own, so a row asserts
# only on keys and hook scripts that base does not carry.
# ---------------------------------------------------------------------------------------------

LIVE="$TMPROOT/live-settings.json"
COMMON_FRAGMENT="$OVERLAY/claude/settings/common.json"
ALPHA_FRAGMENT="$OVERLAY/claude/settings/alpha.json"
BETA_FRAGMENT="$OVERLAY/claude/settings/beta.json"
# The row's fixtures, bound by name for `expected`, in the order that function passes them.
FIXTURE_BINDINGS='[inputs] as [$live, $common, $alpha, $beta] | '

# reset_merge_fixture — an empty live file and three empty overlay fragments, under profile laptop.
reset_merge_fixture() {
    local fixture
    for fixture in "$LIVE" "$COMMON_FRAGMENT" "$ALPHA_FRAGMENT" "$BETA_FRAGMENT"; do
        printf '{}\n' > "$fixture"
    done
    printf 'laptop\n' > "$MARKER"
}
# write_json PATH — stdin to PATH. Fixtures are quoted heredocs, so `$HOME` and quotes stay literal.
write_json() { cat > "$1"; }
# render — --print against $LIVE: the render in $OUT, the exit status in $RC.
render() { run_sut --print --settings "$LIVE"; }
# rendered JQ_ARGS… — jq -cS over the render, or "unparseable" when it is not JSON (an error text).
rendered() { jq -cS "$@" <<< "$OUT" 2>/dev/null || printf 'unparseable'; }
# expected FILTER — jq -cS over the row's own fixtures, bound as $live $common $alpha $beta, so a
# row names the entry it expects instead of quoting it a second time.
expected() {
    jq -cS -n "$FIXTURE_BINDINGS$1" "$LIVE" "$COMMON_FRAGMENT" "$ALPHA_FRAGMENT" "$BETA_FRAGMENT"
}

printf 'merge: lists, objects and scalars\n'
reset_merge_fixture
write_json "$LIVE" <<'JSON'
{"permissions": {"allow": ["Bash(ls:*)", "Read", "Bash(git:*)"]}}
JSON
write_json "$COMMON_FRAGMENT" <<'JSON'
{"permissions": {"allow": ["Read", "Edit"]}}
JSON
write_json "$ALPHA_FRAGMENT" <<'JSON'
{"permissions": {"allow": ["Edit", "WebFetch", "Bash(ls:*)"]}}
JSON
render
check "lists: permissions.allow is the union, live order first, no duplicates" \
    "$RC|$(rendered '.permissions.allow')" '0|["Bash(ls:*)","Read","Bash(git:*)","Edit","WebFetch"]'

reset_merge_fixture
write_json "$LIVE" <<'JSON'
{"modelSettings": {"opus": {"effort": "low", "keptFromLive": true}, "sonnet": {"effort": "medium"}}}
JSON
write_json "$COMMON_FRAGMENT" <<'JSON'
{"modelSettings": {"opus": {"effort": "high"}, "haiku": {"effort": "low"}}}
JSON
write_json "$ALPHA_FRAGMENT" <<'JSON'
{"modelSettings": {"opus": {"effort": "max"}}}
JSON
render
check "objects: modelSettings deep-merges, a later fragment wins a scalar" \
    "$RC|$(rendered '.modelSettings')" \
    '0|{"haiku":{"effort":"low"},"opus":{"effort":"max","keptFromLive":true},"sonnet":{"effort":"medium"}}'

reset_merge_fixture
write_json "$LIVE" <<< '{"theme": "light"}'
write_json "$COMMON_FRAGMENT" <<< '{"theme": "dark"}'
write_json "$ALPHA_FRAGMENT" <<< '{"theme": "dark-daltonized"}'
write_json "$BETA_FRAGMENT" <<< '{"theme": "light-ansi"}'
render
check "scalars: theme from the highest fragment" "$RC|$(rendered '.theme')" '0|"light-ansi"'

printf 'merge: hooks are keyed by the basename of their script, or by their executable\n'
reset_merge_fixture
write_json "$LIVE" <<'JSON'
{"hooks": {"PreToolUse": [
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash '/home/h1/.claude/hooks/x.sh'"}]}
]}}
JSON
write_json "$ALPHA_FRAGMENT" <<'JSON'
{"hooks": {"PreToolUse": [
  {"matcher": "Bash", "hooks": [{"type": "command", "timeout": 5,
    "command": "f=\"$HOME/.claude/hooks/x.sh\"; [ -r \"$f\" ] && exec bash \"$f\"; exit 0"}]}
]}}
JSON
render
# The first entry (the live entry's place) is the fragment's, and it is the only x.sh entry.
check "hooks: a fragment entry replaces the live entry with the same basename" \
    "$RC|$(rendered '[.hooks.PreToolUse[0].hooks[0].command, ([.hooks.PreToolUse[].hooks[0].command | select(contains("/x.sh"))] | length)]')" \
    "0|$(expected '[$alpha.hooks.PreToolUse[0].hooks[0].command, 1]')"

reset_merge_fixture
write_json "$LIVE" <<'JSON'
{"hooks": {"PostToolUse": [
  {"hooks": [{"type": "command", "command": "bash '/home/ubuntu/.claude/hooks/y.sh' session"}]},
  {"hooks": [{"type": "command", "command": "bash '/home/ubuntu/.claude/hooks/w.sh'"}]},
  {"hooks": [{"type": "command", "command": "bash \"$HOME/.claude/hooks/y.sh\" session"}]}
]}}
JSON
write_json "$COMMON_FRAGMENT" <<'JSON'
{"hooks": {"PostToolUse": [
  {"hooks": [{"type": "command", "command": "f=\"$HOME/.claude/hooks/y.sh\"; [ -r \"$f\" ] && exec bash \"$f\" session; exit 0"}]}
]}}
JSON
render
# y.sh under two paths collapses to the fragment's entry, in the first one's place; w.sh, which no
# fragment names, stays.
check "hooks: two spellings of one script become one entry" \
    "$RC|$(rendered '[.hooks.PostToolUse[].hooks[0].command | select(test("/[wy][.]sh"))]')" \
    "0|$(expected '[$common.hooks.PostToolUse[0].hooks[0].command, $live.hooks.PostToolUse[1].hooks[0].command]')"

reset_merge_fixture
write_json "$LIVE" <<'JSON'
{"hooks": {"TeammateIdle": [
  {"hooks": [{"type": "command", "command": "herdmates hook TeammateIdle"}]},
  {"hooks": [{"type": "command", "command": "other-tool hook TeammateIdle"}]}
]}}
JSON
write_json "$ALPHA_FRAGMENT" <<'JSON'
{"hooks": {"TeammateIdle": [
  {"hooks": [{"type": "command", "command": "command -v herdmates > /dev/null 2>&1 && exec herdmates hook TeammateIdle; exit 0"}]}
]}}
JSON
render
# Keyed `herdmates` (not `command`, not `null` from /dev/null): the fragment's entry replaces the bare
# live one, and other-tool, a different executable, stays.
check "hooks: a no-path command is keyed by its executable" \
    "$RC|$(rendered '[.hooks.TeammateIdle[].hooks[0].command | select(test("herdmates|other-tool"))]')" \
    "0|$(expected '[$alpha.hooks.TeammateIdle[0].hooks[0].command, $live.hooks.TeammateIdle[1].hooks[0].command]')"

reset_merge_fixture
write_json "$LIVE" <<'JSON'
{"hooks": {"PreToolUse": [
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/x.sh"}]},
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash \"${HOME}/.claude/hooks/x.sh\""}]}
]}}
JSON
write_json "$ALPHA_FRAGMENT" <<'JSON'
{"hooks": {"PreToolUse": [
  {"matcher": "Bash", "hooks": [{"type": "command",
    "command": "f=\"$HOME/.claude/hooks/x.sh\"; [ -r \"$f\" ] && exec bash \"$f\"; exit 0"}]}
]}}
JSON
render
# Both live spellings are x.sh, not `bash`: the fragment's entry is the only x.sh entry left.
check "hooks: a live entry spelled with ~/ or \${HOME}/ collapses onto the fragment's" \
    "$RC|$(rendered '[.hooks.PreToolUse[].hooks[0].command | select(contains("/x.sh"))]')" \
    "0|$(expected '[$alpha.hooks.PreToolUse[0].hooks[0].command]')"

reset_merge_fixture
write_json "$LIVE" <<'JSON'
{"hooks": {"UserPromptSubmit": [
  {"hooks": [{"type": "command", "command": "bash '/home/ubuntu/.claude/hooks/q.sh'"}]},
  {"matcher": "*", "hooks": [{"type": "command", "command": "bash \"$HOME/.claude/hooks/q.sh\""}]},
  {"hooks": [{"type": "command", "command": "herdmates hook UserPromptSubmit"}]}
]}}
JSON
write_json "$ALPHA_FRAGMENT" <<'JSON'
{"hooks": {"Stop": [
  {"hooks": [{"type": "command", "command": "f=\"$HOME/.claude/hooks/q.sh\"; [ -r \"$f\" ] && exec bash \"$f\"; exit 0"}]}
]}}
JSON
render
# q.sh twice and herdmates are keys the fragments use under OTHER events; here they stay as found.
check "hooks: an event no fragment declares is left as found" \
    "$RC|$(rendered '.hooks.UserPromptSubmit')" "0|$(expected '$live.hooks.UserPromptSubmit')"

printf 'merge: only the org-wide block of autoMode.environment is replaced\n'
reset_merge_fixture
write_json "$LIVE" <<'JSON'
{"autoMode": {"environment": ["Host preamble", "### Org-wide", "Old org line 1", "Old org line 2",
  "### User-specific", "User line 1", "User line 2"]}}
JSON
write_json "$ALPHA_FRAGMENT" <<'JSON'
{"autoMode": {"environment": ["### Org-wide", "New org line"]}}
JSON
render
check "autoMode: only the org-wide block is replaced" \
    "$RC|$(rendered '.autoMode.environment')" \
    '0|["Host preamble","### Org-wide","New org line","### User-specific","User line 1","User line 2"]'

reset_merge_fixture
write_json "$LIVE" <<'JSON'
{"autoMode": {"environment": ["Host preamble", "### Org-wide", "Old org line"]}}
JSON
write_json "$ALPHA_FRAGMENT" <<'JSON'
{"autoMode": {"environment": ["### Org-wide", "New org line"]}}
JSON
render
check "autoMode: no user-specific half" \
    "$RC|$(rendered '.autoMode.environment')" '0|["Host preamble","### Org-wide","New org line"]'

# render_twice — render, write the render back as the live file, render again. Sets
# FIRST_ENVIRONMENT to the first render's "rc|autoMode.environment" and SECOND_RENDER to
# "identical" when the second render is byte-identical to the first, else "differs".
render_twice() {
    local first_render
    render
    first_render=$OUT
    FIRST_ENVIRONMENT="$RC|$(rendered '.autoMode.environment')"
    printf '%s\n' "$first_render" > "$LIVE"
    render
    SECOND_RENDER=$([[ "$RC" == 0 && "$OUT" == "$first_render" ]] && echo identical || echo differs)
}
# With no live `### Org-wide`, the block goes first and `### User-specific` follows it (moved up,
# or added), so the next render finds both headings and keeps every host line. Two live shapes:
# no heading at all, and a user-specific heading with a host line above it.
reset_merge_fixture
write_json "$LIVE" <<< '{"autoMode": {"environment": ["Host line 1", "Host line 2"]}}'
write_json "$ALPHA_FRAGMENT" <<< '{"autoMode": {"environment": ["### Org-wide", "New org line"]}}'
render_twice
no_heading_renders="$FIRST_ENVIRONMENT|$SECOND_RENDER"
write_json "$LIVE" <<< '{"autoMode": {"environment": ["Host preamble", "### User-specific", "User line"]}}'
render_twice
user_heading_only_renders="$FIRST_ENVIRONMENT|$SECOND_RENDER"
check "autoMode: no live org-wide heading — the second render equals the first" \
    "$no_heading_renders|$user_heading_only_renders" \
    '0|["### Org-wide","New org line","### User-specific","Host line 1","Host line 2"]|identical|0|["### Org-wide","New org line","### User-specific","Host preamble","User line"]|identical'

reset_merge_fixture
write_json "$ALPHA_FRAGMENT" <<< '{"autoMode": {"environment": ["New org line"]}}'
render
block_without_heading="$RC|$(contains "$OUT" "$ALPHA_FRAGMENT: autoMode.environment does not start with the line ### Org-wide")"
reset_merge_fixture
write_json "$BETA_FRAGMENT" <<< '{"autoMode": {"environment": ["### Org-wide", "New org line", "### User-specific", "Host line"]}}'
render
block_with_user_heading="$RC|$(contains "$OUT" "$BETA_FRAGMENT: autoMode.environment holds the line ### User-specific")"
check "autoMode: a fragment block without the org-wide heading, or with the user-specific one, is refused (exit 2)" \
    "$block_without_heading|$block_with_user_heading" "2|yes|2|yes"

printf 'merge: $HOME in marketplace paths, and the keys no fragment declares\n'
reset_merge_fixture
write_json "$ALPHA_FRAGMENT" <<'JSON'
{"extraKnownMarketplaces": {"fixture-market": {"source": {"source": "directory", "path": "$HOME/fixture/plugins"}}},
 "hooks": {"Stop": [{"hooks": [{"type": "command",
   "command": "f=\"$HOME/.claude/hooks/fixture-bell.sh\"; [ -r \"$f\" ] && exec bash \"$f\"; exit 0"}]}]},
 "statusLine": {"type": "command", "command": "bash \"$HOME/.claude/hooks/fixture-statusline.sh\""}}
JSON
render
check "home: \$HOME substituted in the marketplace path only" \
    "$RC|$(rendered '.extraKnownMarketplaces["fixture-market"].source.path')|$(rendered '[(.hooks.Stop[].hooks[0].command | select(contains("fixture-bell"))), .statusLine.command]')" \
    "0|\"$HOME/fixture/plugins\"|$(expected '[$alpha.hooks.Stop[0].hooks[0].command, $alpha.statusLine.command]')"

reset_merge_fixture
write_json "$LIVE" <<'JSON'
{"env": {"FIXTURE_FLAG": "1", "FIXTURE_NESTED": "{\"a\": 1}"},
 "feedbackSurveyState": {"lastShownTime": 1730000000000},
 "skipWorkflowUsageWarning": true,
 "tui": {"recent": ["b", "a", "b"]},
 "theme": "light"}
JSON
write_json "$COMMON_FRAGMENT" <<< '{"theme": "dark"}'
render
check "undeclared keys survive byte-for-byte" \
    "$RC|$(rendered '{env, feedbackSurveyState, skipWorkflowUsageWarning, tui}')" \
    "0|$(expected '$live | {env, feedbackSurveyState, skipWorkflowUsageWarning, tui}')"

# --check compares the render with the live file, so a file rendered once and then rewritten by
# clauth (a new env) must render back to itself, byte for byte. The first render must also have
# changed something, or a merge that returns the live file untouched would pass. The prompt hook
# has no command and its keys are unsorted, so it must match the sorted copy the render wrote.
reset_merge_fixture
write_json "$LIVE" <<'JSON'
{"env": {"CLAUTH_PROFILE": "alpha-0"}, "feedbackSurveyState": {"lastShownTime": 1},
 "permissions": {"allow": ["Read"]},
 "hooks": {"SessionStart": [{"matcher": "*", "hooks": [{"type": "command",
   "command": "bash '/home/ubuntu/.claude/hooks/herdr-agent-state.sh' session"}]}]},
 "autoMode": {"environment": ["### Org-wide", "Old org line", "### User-specific", "User line"]}}
JSON
write_json "$COMMON_FRAGMENT" <<< '{"permissions": {"allow": ["Edit"]}, "theme": "dark"}'
write_json "$ALPHA_FRAGMENT" <<'JSON'
{"autoMode": {"environment": ["### Org-wide", "New org line"]},
 "hooks": {"Stop": [{"hooks": [{"type": "prompt", "prompt": "Fixture prompt hook"}]}]},
 "extraKnownMarketplaces": {"fixture-market": {"source": {"source": "directory", "path": "$HOME/fixture/plugins"}}}}
JSON
live_before_render=$(jq -S --indent 2 . "$LIVE")
render
first_render_rc=$RC
first_render_change=$([[ "$OUT" != "$live_before_render" ]] && echo changed || echo unchanged)
jq -S --indent 2 '.env = {"CLAUTH_PROFILE": "alpha-1"} | .feedbackSurveyState.lastShownTime = 2' \
    <<< "$OUT" > "$LIVE" 2>/dev/null
rewritten_live=$(cat "$LIVE")
render
check "check: undeclared keys never count as drift" \
    "$first_render_rc|$first_render_change|$RC|$([[ "$OUT" == "$rewritten_live" ]] && echo identical || echo differs)" \
    "0|changed|0|identical"

printf '\n'
EXPECTED_ROWS=21
if (( PASS + FAIL != EXPECTED_ROWS )); then
    fatal "expected $EXPECTED_ROWS rows, $((PASS + FAIL)) ran — a check vanished or was added without updating EXPECTED_ROWS"
fi
if (( FAIL )); then printf '\033[1;31m%d of %d failed\033[0m\n' "$FAIL" "$((PASS + FAIL))"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$PASS"
