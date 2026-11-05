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

for tool in bash jq cmp sha256sum stat; do command -v "$tool" >/dev/null || fatal "$tool is required"; done
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

# The base fragment is public and lands on every host, so it may carry only what this repo owns:
# its own hooks, the statusLine, its own marketplace and the one plugin that marketplace serves.
# Anything tenant-specific (another marketplace, a plugin, permissions, the auto-mode block) belongs
# in the private overlays; a key added here would reach every host and every teammate.
BASE_FRAGMENT="$DOTFILES/claude/settings/base.json"
check "base: the public fragment carries only the repo's own keys" \
    "$(jq -c '[keys, (.extraKnownMarketplaces | keys), (.enabledPlugins | keys), .statusLine.refreshInterval]' "$BASE_FRAGMENT" 2>&1)" \
    '[["enabledPlugins","extraKnownMarketplaces","hooks","statusLine"],["dotfiles"],["linear-key@dotfiles"],120]'

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

# ---------------------------------------------------------------------------------------------
# The writer. Each row renders its own settings file, under the fixture HOME, with --settings.
# The drift fixture is a live `theme: light` against a common fragment's `theme: dark`, so the
# render differs from the live file in a declared key. Backups land in the fixture HOME's state
# dir, which every row empties first.
# ---------------------------------------------------------------------------------------------

BACKUPS_DIR="$HOME/.local/state/claude-settings-render"
BACKUP_NAME_PREFIX='settings.json.before-'
BACKUP_NAME_RE='^settings\.json\.before-[0-9]{8}T[0-9]{6}Z'
TEMP_FILE_PATTERN='.settings.json.render.*'

# writer_settings_path ROW_NAME — reset the overlay fragments, empty the backups dir, make a fresh
# directory for the row and print the path of its settings file (not created).
writer_settings_path() {
    local row_dir="$HOME/writer/$1"
    rm -rf "$row_dir" "$BACKUPS_DIR"
    mkdir -p "$row_dir"
    reset_merge_fixture
    printf '%s/settings.json\n' "$row_dir"
}
# write_drift_fixture SETTINGS_PATH — a live `theme: light`, and a common fragment that sets dark.
write_drift_fixture() {
    write_json "$COMMON_FRAGMENT" <<< '{"theme": "dark"}'
    write_json "$1" <<< '{"theme": "light"}'
}
# matching_count PATTERN — how many paths match the glob PATTERN (0 when none).
matching_count() {
    local matches=()
    mapfile -t matches < <(compgen -G "$1")
    printf '%d' "${#matches[@]}"
}
# backup_files — the backups, oldest first (their names sort in creation order), into BACKUP_FILES.
backup_files() { mapfile -t BACKUP_FILES < <(compgen -G "$BACKUPS_DIR/$BACKUP_NAME_PREFIX*" | LC_ALL=C sort); }
# fingerprint PATH — the content hash and inode of PATH, so a row can tell "rewritten" from "kept".
fingerprint() { printf '%s:%s' "$(sha256sum < "$1")" "$(stat -c %i "$1")"; }
# same_or_changed BEFORE AFTER → same|changed
same_or_changed() { [[ "$1" == "$2" ]] && printf same || printf changed; }
# seed_backups STAMP_PREFIX COUNT — COUNT backups in the script's own name shape,
# settings.json.before-<STAMP_PREFIX><two-digit second>Z, each holding its own name.
seed_backups() {
    local index seed_name
    mkdir -p "$BACKUPS_DIR"
    for (( index = 0; index < $2; index++ )); do
        printf -v seed_name '%s%s%02dZ' "$BACKUP_NAME_PREFIX" "$1" "$index"
        printf '{"seed": "%s"}\n' "$seed_name" > "$BACKUPS_DIR/$seed_name"
    done
}
# backups_listing — every name in the backups dir, sorted, on one line.
backups_listing() { compgen -G "$BACKUPS_DIR/*" | LC_ALL=C sort | tr '\n' ' '; }
# reformat_as_equal PATH — rewrite PATH as the same JSON value in other bytes: compact, with the
# top-level keys reversed. The writer compares canonical forms, so this must never count as drift.
reformat_as_equal() {
    jq -c 'to_entries | reverse | from_entries' "$1" > "$1.reformatted" && mv "$1.reformatted" "$1"
}

printf 'writer: --apply, --check and --print\n'
target=$(writer_settings_path mode)
write_drift_fixture "$target"
chmod 640 "$target"
inode_before=$(stat -c %i "$target")
run_sut --apply --settings "$target"
existing_target="$RC|$(contains "$OUT" "wrote $target (backup $BACKUPS_DIR/")|$(stat -c %a "$target")|$(same_or_changed "$inode_before" "$(stat -c %i "$target")")|$(matching_count "$(dirname "$target")/$TEMP_FILE_PATTERN")|$(jq -r .theme "$target")"
new_target=$(writer_settings_path mode-new)
run_sut --apply --settings "$new_target"
new_file="$RC|$(stat -c %a "$new_target" 2>/dev/null)|$(matching_count "$(dirname "$new_target")/$TEMP_FILE_PATTERN")"
# A backups dir that cannot be made (a file stands in its place) fails the write after the temp
# file exists: exit 2, the settings file as it was, and no temp file left beside it.
failing_target=$(writer_settings_path mode-failed-backup)
write_drift_fixture "$failing_target"
mkdir -p "$(dirname "$BACKUPS_DIR")"
: > "$BACKUPS_DIR"
failing_before=$(fingerprint "$failing_target")
run_sut --apply --settings "$failing_target"
failed_backup="$RC|$(contains "$OUT" "could not create the backups dir $BACKUPS_DIR")|$(same_or_changed "$failing_before" "$(fingerprint "$failing_target")")|$(matching_count "$(dirname "$failing_target")/$TEMP_FILE_PATTERN")"
# A rename that fails (a mv that exits 1) after the backup is made: exit 2, the settings file as it
# was, no temp file, and the backups dir exactly as it was: no stray copy, and none pruned. The ten
# seeded backups are older than today, so a prune that ran before the rename would drop one.
FAILING_MV_BIN="$TMPROOT/failing-mv-bin"
mkdir -p "$FAILING_MV_BIN"
printf '#!/bin/sh\nexit 1\n' > "$FAILING_MV_BIN/mv"
chmod +x "$FAILING_MV_BIN/mv"
failing_target=$(writer_settings_path mode-failed-rename)
write_drift_fixture "$failing_target"
seed_backups 20200101T0000 10
failing_before=$(fingerprint "$failing_target")
backups_before=$(backups_listing)
PATH="$FAILING_MV_BIN:$PATH" run_sut --apply --settings "$failing_target"
failed_rename="$RC|$(contains "$OUT" "could not rename")|$(same_or_changed "$failing_before" "$(fingerprint "$failing_target")")|$(matching_count "$(dirname "$failing_target")/$TEMP_FILE_PATTERN")|$(same_or_changed "$backups_before" "$(backups_listing)")"
# The inode changes only when the file is replaced by a rename; an in-place write keeps it.
check "apply: writes by temp file and rename, mode preserved (a new file: 600; a failed backup or rename leaves no trace)" \
    "$existing_target|$new_file|$failed_backup|$failed_rename" \
    "0|yes|640|changed|0|dark|0|600|0|2|yes|same|0|2|yes|same|0|same"

# A clock frozen at one second, so all twelve backups share a stamp: the names then differ only by
# their counter, and a name pruning frees must not be reused (it would sort first, and be pruned
# next, in place of the oldest). The real date runs, so the backup names keep the script's format.
FROZEN_CLOCK_BIN="$TMPROOT/frozen-clock-bin"
FROZEN_EPOCH_SECONDS=1793880000   # 2026-11-05T12:00:00Z
mkdir -p "$FROZEN_CLOCK_BIN"
printf '#!/bin/sh\nexec "%s" -d @%s "$@"\n' "$(command -v date)" "$FROZEN_EPOCH_SECONDS" > "$FROZEN_CLOCK_BIN/date"
chmod +x "$FROZEN_CLOCK_BIN/date"
BACKUP_APPLY_RUNS=12
target=$(writer_settings_path backups)
write_json "$COMMON_FRAGMENT" <<< '{"theme": "dark"}'
apply_codes=''
last_live_before_apply="$TMPROOT/last-live-before-apply.json"
for (( run = 1; run <= BACKUP_APPLY_RUNS; run++ )); do
    # fixtureRun (an undeclared key) tells the backups apart. Editing it alone would not make the
    # render differ, since the render copies it, so each run also reverts the declared theme.
    jq -n --argjson run "$run" '{"theme": "light", "fixtureRun": $run}' > "$target"
    cp "$target" "$last_live_before_apply"
    PATH="$FROZEN_CLOCK_BIN:$PATH" run_sut --apply --settings "$target"
    apply_codes+="$RC"
done
backup_files
backup_names_dated=yes
for backup in "${BACKUP_FILES[@]}"; do
    [[ "$(basename "$backup")" =~ $BACKUP_NAME_RE ]] || backup_names_dated=no
done
newest_backup=/dev/null
(( ${#BACKUP_FILES[@]} )) && newest_backup=${BACKUP_FILES[-1]}
newest_backup_exact=$(cmp -s "$newest_backup" "$last_live_before_apply" && echo exact || echo differs)
# Oldest first: the runs whose previous file each backup holds. Ten remain; runs 1 and 2 are gone.
check "apply: keeps a dated backup, at most 10" \
    "$apply_codes|${#BACKUP_FILES[@]}|$(jq -cs '[.[].fixtureRun]' "${BACKUP_FILES[@]}" 2>/dev/null < /dev/null)|$backup_names_dated|$newest_backup_exact|$(stat -c %a "${BACKUP_FILES[@]}" 2>/dev/null | sort -u | tr '\n' ' ')" \
    "000000000000|10|[3,4,5,6,7,8,9,10,11,12]|yes|exact|600 "

# Ten backups stamped a day AFTER the frozen clock (a clock stepped back), and one file the script
# did not make, named to sort before everything. Pruning by name alone would remove both the new
# backup (it sorts before the ten) and the foreign file (it sorts first of all).
WROTE_BACKUP_RE='\(backup ([^)]+)\)'
target=$(writer_settings_path prune-guard)
write_drift_fixture "$target"
seed_backups 20261106T1200 10
foreign_file="$BACKUPS_DIR/${BACKUP_NAME_PREFIX}20261105T115959Z.orig"
printf '{"foreign": true}\n' > "$foreign_file"
foreign_before=$(fingerprint "$foreign_file")
cp "$target" "$last_live_before_apply"
PATH="$FROZEN_CLOCK_BIN:$PATH" run_sut --apply --settings "$target"
named_backup=''
[[ "$OUT" =~ $WROTE_BACKUP_RE ]] && named_backup=${BASH_REMATCH[1]}
own_shape_backups=0
for backup in "$BACKUPS_DIR"/*; do
    [[ "$(basename "$backup")" =~ ${BACKUP_NAME_RE}(\.[0-9]{3})?$ ]] && own_shape_backups=$((own_shape_backups + 1))
done
# The ten kept are the new backup and the nine newest seeds: the oldest seed is the one pruned.
check "apply: the prune never removes the backup just written, nor a file the script did not make" \
    "$RC|$([[ -n "$named_backup" && -e "$named_backup" ]] && echo exists || echo missing)|$(cmp -s "${named_backup:-/dev/null}" "$last_live_before_apply" && echo exact || echo differs)|$(same_or_changed "$foreign_before" "$(fingerprint "$foreign_file" 2>/dev/null)")|$own_shape_backups|$([[ -e "$BACKUPS_DIR/${BACKUP_NAME_PREFIX}20261106T120000Z" ]] && echo kept || echo pruned)" \
    "0|exists|exact|same|10|pruned"

target=$(writer_settings_path symlink)
link_destination="$(dirname "$target")/real-settings.json"
write_json "$link_destination" <<< '{"theme": "light"}'
ln -s "$link_destination" "$target"
destination_before=$(sha256sum < "$link_destination")
run_sut --apply --settings "$target"
live_link="$RC|$(contains "$OUT" "$target is a symlink; refusing to write through it")|$([[ -L "$target" ]] && echo link)|$(same_or_changed "$destination_before" "$(sha256sum < "$link_destination")")"
dangling_link="$(dirname "$target")/dangling.json"
dangling_destination="$(dirname "$target")/absent-settings.json"
ln -s "$dangling_destination" "$dangling_link"
run_sut --apply --settings "$dangling_link"
dangling_apply="$RC|$(contains "$OUT" "$dangling_link is a symlink; refusing to write through it")|$([[ -L "$dangling_link" ]] && echo link)|$([[ -e "$dangling_destination" ]] && echo created || echo absent)"
# --check too: a dangling link read as an absent file would report drift (exit 1), not refuse.
run_sut --check --settings "$dangling_link"
dangling_check="$RC|$(contains "$OUT" "$dangling_link is a symlink; refusing to write through it")"
check "apply: refuses a symlinked settings.json (exit 2)" \
    "$live_link|$dangling_apply|$dangling_check" "2|yes|link|same|2|yes|link|absent|2|yes"

target=$(writer_settings_path non-object)
: > "$target"
run_sut --apply --settings "$target"
empty_file="$RC|$(contains "$OUT" "$target is not readable as one JSON object")|$(stat -c %s "$target")"
write_json "$target" <<< '[{"theme": "light"}]'
array_before=$(fingerprint "$target")
run_sut --apply --settings "$target"
array_file="$RC|$(contains "$OUT" "$target is not readable as one JSON object")|$(same_or_changed "$array_before" "$(fingerprint "$target")")"
check "apply: refuses a non-object file (exit 2)" "$empty_file|$array_file" "2|yes|0|2|yes|same"

target=$(writer_settings_path check)
write_drift_fixture "$target"
live_before=$(fingerprint "$target")
run_sut --check --settings "$target"
drift="$RC|$(contains "$OUT" $'--- live\n+++ rendered\n@@')|$(contains "$OUT" $'\n-  "theme": "light"')|$(contains "$OUT" $'\n+  "theme": "dark"')|$(same_or_changed "$live_before" "$(fingerprint "$target")")|$(matching_count "$BACKUPS_DIR/*")"
run_sut --apply --settings "$target"
run_sut --check --settings "$target"
level="$RC|$(contains "$OUT" "claude-settings-render: $target is rendered")|$(contains "$OUT" '+++ rendered')"
reformat_as_equal "$target"
run_sut --check --settings "$target"
reformatted_level="$RC|$(contains "$OUT" "claude-settings-render: $target is rendered")"
check "check: exit 1 with a unified diff on drift, 0 when rendered == live" \
    "$drift|$level|$reformatted_level" "1|yes|yes|yes|same|0|0|yes|no|0|yes"

target=$(writer_settings_path print)
write_drift_fixture "$target"
live_before=$(fingerprint "$target")
printed=$(CLAUDE_SETTINGS_RENDER_MARKER="$MARKER" CLAUDE_SETTINGS_RENDER_OVERLAY="$OVERLAY" \
    "$SUT" --print --settings "$target" 2>/dev/null); print_rc=$?
check "print: rendered JSON on stdout, nothing written" \
    "$print_rc|$(jq -r .theme <<< "$printed" 2>/dev/null)|$(same_or_changed "$live_before" "$(fingerprint "$target")")|$([[ -e "$BACKUPS_DIR" ]] && echo backups || echo no-backups)|$(matching_count "$(dirname "$target")/$TEMP_FILE_PATTERN")" \
    "0|dark|same|no-backups|0"

target=$(writer_settings_path twice)
write_drift_fixture "$target"
run_sut --apply --settings "$target"
first_apply="$RC|$(contains "$OUT" "wrote $target")"
after_first_apply=$(fingerprint "$target")
backups_after_first_apply=$(matching_count "$BACKUPS_DIR/$BACKUP_NAME_PREFIX*")
run_sut --apply --settings "$target"
second_apply="$RC|$(contains "$OUT" "claude-settings-render: $target is rendered")|$(contains "$OUT" 'wrote')|$(same_or_changed "$after_first_apply" "$(fingerprint "$target")")|$(matching_count "$BACKUPS_DIR/$BACKUP_NAME_PREFIX*")"
# The same value in other bytes is still level: the reformatted file is kept as it is.
reformat_as_equal "$target"
after_reformat=$(fingerprint "$target")
run_sut --apply --settings "$target"
reformatted_apply="$RC|$(contains "$OUT" "claude-settings-render: $target is rendered")|$(same_or_changed "$after_reformat" "$(fingerprint "$target")")|$(matching_count "$BACKUPS_DIR/$BACKUP_NAME_PREFIX*")"
check "apply twice: second run is a no-op (same bytes, no new backup), and so is one after a reformat" \
    "$first_apply|$backups_after_first_apply|$second_apply|$reformatted_apply" "0|yes|1|0|yes|no|same|1|0|yes|same|1"

# A PATH with what the script needs before its jq check (bash for env, dirname, sed for --help),
# and no jq.
NO_JQ_BIN="$TMPROOT/no-jq-bin"
mkdir -p "$NO_JQ_BIN"
for tool in bash dirname sed; do ln -s "$(command -v "$tool")" "$NO_JQ_BIN/$tool"; done
target=$(writer_settings_path no-jq)
write_drift_fixture "$target"
live_before=$(fingerprint "$target")
OUT=$(PATH="$NO_JQ_BIN" CLAUDE_SETTINGS_RENDER_MARKER="$MARKER" CLAUDE_SETTINGS_RENDER_OVERLAY="$OVERLAY" \
    "$SUT" --apply --settings "$target" 2>&1); RC=$?
no_jq_apply="$RC|$(contains "$OUT" 'claude-settings-render: jq is required')|$(same_or_changed "$live_before" "$(fingerprint "$target")")"
OUT=$(PATH="$NO_JQ_BIN" "$SUT" --help 2>&1); RC=$?
no_jq_help="$RC|$(contains "$OUT" '--apply')"
check "jq missing → exit 2 (--help still works)" "$no_jq_apply|$no_jq_help" "2|yes|same|0|yes"

printf '\n'
EXPECTED_ROWS=31
if (( PASS + FAIL != EXPECTED_ROWS )); then
    fatal "expected $EXPECTED_ROWS rows, $((PASS + FAIL)) ran — a check vanished or was added without updating EXPECTED_ROWS"
fi
if (( FAIL )); then printf '\033[1;31m%d of %d failed\033[0m\n' "$FAIL" "$((PASS + FAIL))"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$PASS"
