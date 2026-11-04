#!/usr/bin/env bash
#
# scripts/test-claude-config-audit.sh
# ===================================
#
# State table for scripts/claude-config-audit.sh: collecting every agent host's
# Claude Code configuration into one workspace, and reporting where hosts agree.
#
# HERMETIC. Every row runs against a workspace under mktemp -d. Nothing here
# reaches a real host or the real $HOME: ssh is replaced through CLAUDE_CONFIG_AUDIT_SSH
# where a row needs it, the whole table runs under an empty fixture HOME (the local-collect
# rows under fixtures of their own), and the argument-validation rows below stop before any
# ssh happens.
# Requires: bash, jq, tar, sha256sum.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$DOTFILES/scripts/claude-config-audit.sh"
TMPROOT="$(mktemp -d)"
# Some fixtures hold read-only (555) directories, which rm -rf alone cannot empty.
trap 'find "$TMPROOT" -type d -exec chmod u+rwx {} + 2>/dev/null; rm -rf "$TMPROOT"' EXIT

# The SUT's default hosts lead with this machine (laptop=local) and its default workspace is
# under $HOME, so a row that leaves out --host or --workspace would read and write the real
# home. An empty fixture HOME for the whole table makes that impossible; rows that need a
# particular home set their own.
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

for tool in bash jq tar sha256sum; do command -v "$tool" >/dev/null || fatal "$tool is required"; done
[[ -x "$SUT" ]] || fatal "$SUT is not executable — every row below would assert nothing"
if git -C "$TMPROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
    fatal "$TMPROOT is inside a git repository; the fixtures would resolve against it"
fi

# ---------------------------------------------------------------------------------------------
# Fixture hosts and the stub ssh
# ---------------------------------------------------------------------------------------------
#
# Each fixture host is a HOME under $FIXTURE_HOSTS/<alias>. The stub ssh runs the remote
# command there with HOME pointed at it and PATH=/usr/bin:/bin — dev's non-interactive PATH,
# which has no ~/.local/bin — so the remote script cannot find claude or herdr on PATH.

FIXTURE_HOSTS="$TMPROOT/hosts"
STUB_BIN="$TMPROOT/bin"
mkdir -p "$FIXTURE_HOSTS" "$STUB_BIN"
cat > "$STUB_BIN/ssh" <<'STUB'
#!/usr/bin/env bash
# Stub ssh: record the call, skip `-o VALUE` pairs, take the next argument as the alias and
# the rest as the remote command, run it under the alias's fixture HOME with stdin passed through.
printf '%s\n' "$*" >> "$AUDIT_SSH_CALLS"
while [[ "${1:-}" == -o ]]; do shift 2; done
alias_name="$1"; shift
fixture_home="$AUDIT_FIXTURE_HOSTS/$alias_name"
if [[ "$alias_name" == down || ! -d "$fixture_home" ]]; then
    printf 'ssh: connect to host %s port 22: Connection refused\n' "$alias_name" >&2
    exit 255
fi
# A host holding a canned stream sends it as-is, directory members and their modes included,
# in place of what the remote script would send.
if [[ -d "$fixture_home/canned-stream" ]]; then
    exec tar -c -f - -C "$fixture_home/canned-stream" .
fi
run_remote() { env HOME="$fixture_home" PATH=/usr/bin:/bin TMPDIR="$AUDIT_REMOTE_TMPDIR" bash -c "$*"; }
# `interrupt` sends its whole stream, then SIGTERMs the collect (this stub's parent) while
# the collect is still waiting on the pipeline, as a Ctrl-C or a kill would.
if [[ "$alias_name" == interrupt ]]; then
    run_remote "$@"
    kill -TERM "$PPID"
    exit 0
fi
run_remote "$@"
STUB
chmod +x "$STUB_BIN/ssh"
# The remote's one write is its own mktemp -d, so the "remote" gets a TMPDIR of its own that
# the read-only row asserts is empty again afterwards.
REMOTE_TMPDIR="$TMPROOT/remote-tmp"
mkdir -p "$REMOTE_TMPDIR"
# Every stub ssh call, one line each: the local-collect row asserts it made none.
SSH_CALLS="$TMPROOT/ssh-calls"
export AUDIT_FIXTURE_HOSTS="$FIXTURE_HOSTS" AUDIT_REMOTE_TMPDIR="$REMOTE_TMPDIR" AUDIT_SSH_CALLS="$SSH_CALLS"
# With an option, as the SUT's own default has three: SSH_CMD is word-split on purpose, and a
# quoted "$SSH_CMD" would run a command named "<stub> -o StubOption=yes" and fail every host.
export CLAUDE_CONFIG_AUDIT_SSH="$STUB_BIN/ssh -o StubOption=yes"

# A recording rm, put first on PATH for one run: each argument it is given, one per line, then
# the real rm. The re-collect row reads it to show the earlier tree is never removed in place.
RM_RECORDER_BIN="$TMPROOT/rm-recorder"
mkdir -p "$RM_RECORDER_BIN"
cat > "$RM_RECORDER_BIN/rm" <<'RM_RECORDER'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$AUDIT_RM_CALLS"
exec "$AUDIT_REAL_RM" "$@"
RM_RECORDER
chmod +x "$RM_RECORDER_BIN/rm"
RM_CALLS="$TMPROOT/rm-calls"
AUDIT_REAL_RM=$(type -P rm) || fatal "rm is not on PATH"
export AUDIT_RM_CALLS="$RM_CALLS" AUDIT_REAL_RM

# An interrupting mv, put first on PATH for one run: it makes the move, then SIGTERMs the
# collect (its parent) when the source was AUDIT_INTERRUPT_AFTER_MOVING, as a Ctrl-C landing
# between install_collect's two renames would.
MV_INTERRUPTER_BIN="$TMPROOT/mv-interrupter"
mkdir -p "$MV_INTERRUPTER_BIN"
cat > "$MV_INTERRUPTER_BIN/mv" <<'MV_INTERRUPTER'
#!/usr/bin/env bash
mv_arguments=("$@")
"$AUDIT_REAL_MV" "$@"
move_status=$?
if (( $# >= 2 )) && [[ "${mv_arguments[$# - 2]}" == "$AUDIT_INTERRUPT_AFTER_MOVING" ]]; then
    kill -TERM "$PPID"
fi
exit "$move_status"
MV_INTERRUPTER
chmod +x "$MV_INTERRUPTER_BIN/mv"
AUDIT_REAL_MV=$(type -P mv) || fatal "mv is not on PATH"
export AUDIT_REAL_MV

# A restoring mv, put first on PATH for one run: it makes the move, then moves it straight back
# when the source was AUDIT_RESTORE_AFTER_MOVING, as a second --collect's startup sweep would put
# back an aside it found mid-swap. The host dir is then there again when the new collect lands.
MV_RESTORER_BIN="$TMPROOT/mv-restorer"
mkdir -p "$MV_RESTORER_BIN"
cat > "$MV_RESTORER_BIN/mv" <<'MV_RESTORER'
#!/usr/bin/env bash
mv_arguments=("$@")
"$AUDIT_REAL_MV" "$@"
move_status=$?
if (( move_status == 0 && $# >= 2 )) && [[ "${mv_arguments[$# - 2]}" == "$AUDIT_RESTORE_AFTER_MOVING" ]]; then
    "$AUDIT_REAL_MV" -T "${mv_arguments[$# - 1]}" "${mv_arguments[$# - 2]}"
fi
exit "$move_status"
MV_RESTORER
chmod +x "$MV_RESTORER_BIN/mv"

# Built at runtime so the repo's gitleaks hook never sees a credential-shaped literal.
FIXTURE_LINEAR_KEY="lin_api_""FIXTUREVALUE0123456789abcdefXYZ"
FIXTURE_NAMED_SECRET="fixture-named-""secret-value"
FIXTURE_CREDENTIAL='FIXTURE-CRED'
# Held by name in JSON and shaped like no credential, so only the collect's JSON pass can find
# them: the line redactor needs NAME=value with real whitespace around it.
FIXTURE_JSON_ENV_VALUE="json-held-env-""value-0123"
FIXTURE_JSON_NAMED_VALUE="json-held-named-""value-4567"
JSON_REDACTED_VALUE='<REDACTED:json-name>'
# A UTF-8 locale on every host, so the redaction row holds whatever locale CI runs in.
UTF8_LOCALE='C.UTF-8'

make_host() {   # ALIAS → a fixture HOME at $FIXTURE_HOSTS/ALIAS
    local host_alias="$1"
    local host_home="$FIXTURE_HOSTS/$host_alias"
    local cfg="$host_home/.claude"
    local project_dir="$cfg/projects/-home-$host_alias-quantivly-hub"
    local dotfiles_hooks="$host_home/.dotfiles/claude/hooks"
    mkdir -p "$cfg/hooks" "$cfg/skills/rabota" "$cfg/skills/synced" "$cfg/agents" \
        "$cfg/plugins/cache" "$cfg/sessions" "$project_dir/memory" \
        "$host_home/quantivly/hub/.claude" "$host_home/.local/bin" "$dotfiles_hooks"
    printf '# global instructions on %s\n' "$host_alias" > "$cfg/CLAUDE.md"
    printf '{"permissions":{"allow":["Bash(ls)"]}}\n' > "$cfg/settings.json"
    printf '{"permissions":{"allow":[]}}\n' > "$cfg/settings.local.json"
    printf '{"bindings":[]}\n' > "$cfg/keybindings.json"
    printf '#!/bin/sh\necho hook-a\n' > "$cfg/hooks/a.sh"
    printf '#!/bin/sh\necho hook-b-from-dotfiles\n' > "$dotfiles_hooks/b.sh"
    ln -s "$dotfiles_hooks/b.sh" "$cfg/hooks/b.sh"
    printf -- '---\nname: rabota\n---\n' > "$cfg/skills/rabota/SKILL.md"
    printf -- '---\nname: synced\n---\n' > "$cfg/skills/synced/SKILL.md"
    printf -- '---\nname: x\n---\n' > "$cfg/agents/x.md"
    printf '{}\n' > "$cfg/plugins/known_marketplaces.json"
    printf '{}\n' > "$cfg/plugins/installed_plugins.json"
    printf 'cached plugin\n' > "$cfg/plugins/cache/junk"
    printf -- '- [Fact one](fact-one.md)\n' > "$project_dir/memory/MEMORY.md"
    printf -- '---\ndescription: fact one\n---\n' > "$project_dir/memory/fact-one.md"
    # A transcript beside memory/ and one inside it: neither may be collected.
    printf '{"msg":"%s"}\n' "$FIXTURE_CREDENTIAL" > "$project_dir/0001.jsonl"
    printf '{"msg":"%s"}\n' "$FIXTURE_CREDENTIAL" > "$project_dir/memory/stray.jsonl"
    printf '%s\n' "$FIXTURE_CREDENTIAL" > "$cfg/.credentials.json"
    printf '%s\n' "$FIXTURE_CREDENTIAL" > "$host_home/.claude.json"
    printf 'session\n' > "$cfg/sessions/s"
    printf '# quantivly root\n' > "$host_home/quantivly/CLAUDE.md"
    printf '{"hub":true}\n' > "$host_home/quantivly/hub/.claude/settings.json"
    # Inside the trees collected whole, only the EXCLUDE_NAMES prunes stand between these and
    # the workspace: one path per by-name prune, each holding the credential literal.
    local repo_claude="$host_home/quantivly/hub/.claude" excluded_path top_level_name
    for excluded_path in "$cfg/skills/rabota/.credentials.json" "$cfg/skills/rabota/.claude.json.backup" \
            "$repo_claude/.credentials.json" "$repo_claude/.claude.json.backup" "$repo_claude/old.jsonl" \
            "$repo_claude/hook.signature" "$repo_claude/plugins/cache/c" \
            "$repo_claude/plugins/marketplaces/m" "$repo_claude/plugins/repos/r" \
            "$repo_claude/plugins/data/d" "$repo_claude/plugins/store/s" "$repo_claude/plugins/synced/s" \
            "$repo_claude/skills/synced/SKILL.md" "$repo_claude/worktrees/w/CLAUDE.md"; do
        mkdir -p "$(dirname "$excluded_path")"
        printf '%s\n' "$FIXTURE_CREDENTIAL" > "$excluded_path"
    done
    # Claude Code's own dirs, where it writes them: directly under the config dir. The include set
    # never walks that level, and EXCLUDE_TOP_LEVEL_NAMES would prune them there if it did.
    for top_level_name in sessions shell-snapshots file-history paste-cache debug cache backups \
            downloads telemetry security; do
        mkdir -p "$cfg/$top_level_name"
        printf '%s\n' "$FIXTURE_CREDENTIAL" > "$cfg/$top_level_name/f"
    done
    printf '#!/bin/sh\necho "2.1.300 (Claude Code)"\n' > "$host_home/.local/bin/claude"
    printf '#!/bin/sh\necho "herdr 0.9.5"\n' > "$host_home/.local/bin/herdr"
    chmod +x "$host_home/.local/bin/claude" "$host_home/.local/bin/herdr"
}

# The host tree, every entry's type, mode, mtime and link target, then every file's hash:
# any write the collect makes under the fixture HOME changes this listing.
host_tree_listing() {   # DIR
    find "$1" -printf '%y %m %T@ %p %l\n' | sort
    find "$1" -type f -print0 | sort -z | xargs -0 sha256sum
}

has_line() {   # FILE LINE → yes if FILE holds LINE exactly, else no
    if grep -qFx -- "$2" "$1" 2>/dev/null; then printf yes; else printf no; fi
}

TAB=$'\t'

# ---------------------------------------------------------------------------------------------
# Usage and argument validation
# ---------------------------------------------------------------------------------------------

printf 'usage: no verb → exit 64 and the usage text\n'
out=$("$SUT" 2>&1); rc=$?
# This line appears only in the usage block; usage_error's own message never contains it.
USAGE_ONLY_NEEDLE='--host NAME=ALIAS:CFGDIR'
prints_usage=no; [[ "$out" == *"$USAGE_ONLY_NEEDLE"* ]] && prints_usage=yes
check "no verb: exit 64, usage text printed" "$rc $prints_usage" "64 yes"

printf 'usage: --help → exit 0\n'
help_stdout=$("$SUT" --help 2>/dev/null); rc=$?
help_prints_usage=no; [[ "$help_stdout" == *"$USAGE_ONLY_NEEDLE"* ]] && help_prints_usage=yes
check "--help: exit 0, usage text on stdout" "$rc $help_prints_usage" "0 yes"

printf 'usage: a host alias with a space or semicolon, or a leading dash → exit 64, nothing created\n'
WS_NEVER="$TMPROOT/ws-never"
"$SUT" --collect --workspace "$WS_NEVER" --host 'x=bad host;rm:.claude' >/dev/null 2>&1; rc=$?
# ssh would read -Fevil as an option: a config file, ProxyCommand included.
"$SUT" --collect --workspace "$WS_NEVER" --host 'x=-Fevil:.claude' >/dev/null 2>&1; dash_rc=$?
workspace_state=absent; [[ -e "$WS_NEVER" ]] && workspace_state=exists
check "bad alias: exit 64 for both, and no workspace created" "$rc $dash_rc $workspace_state" "64 64 absent"

printf 'usage: a config dir not starting with a dot, or one that is only dots → exit 64\n'
"$SUT" --collect --workspace "$WS_NEVER" --host 'x=x:claude' >/dev/null 2>&1; rc=$?
"$SUT" --collect --workspace "$WS_NEVER" --host 'x=x:..' >/dev/null 2>&1; dots_rc=$?
check "config dir without a leading dot, or ..: exit 64" "$rc $dots_rc" "64 64"

printf 'usage: a duplicate host name → exit 64\n'
# A workspace of its own, so an earlier row's failure cannot fail this one.
WS_NEVER_DUPLICATE="$TMPROOT/ws-never-duplicate"
out=$("$SUT" --collect --workspace "$WS_NEVER_DUPLICATE" --host 'a=x:.claude' --host 'a=y:.claude' 2>&1); rc=$?
names_duplicate=no; [[ "$out" == *"host name 'a' is given twice"* ]] && names_duplicate=yes
workspace_state=absent; [[ -e "$WS_NEVER_DUPLICATE" ]] && workspace_state=exists
check "duplicate host name: exit 64, named, no workspace" "$rc $names_duplicate $workspace_state" "64 yes absent"

# ---------------------------------------------------------------------------------------------
# --collect against a remote host
# ---------------------------------------------------------------------------------------------

make_host h1
H1="$FIXTURE_HOSTS/h1"
printf 'linear key: %s\n' "$FIXTURE_LINEAR_KEY" >> "$H1/.claude/CLAUDE.md"
# A by-name secret whose value starts with an invalid UTF-8 byte: in a UTF-8 locale the
# redactor's [^[:space:]]+ stops at that byte and leaves the value whole.
printf 'FIXTURE_TOKEN=\xe9%s\n' "$FIXTURE_NAMED_SECRET" >> "$H1/.claude/CLAUDE.md"
printf 'BLOB\0BINARY\n' > "$H1/.claude/hooks/blob.bin"
# Text with no character on any line: `grep -Iq .` would call these binary.
: > "$H1/.claude/hooks/empty.sh"
printf '\n\n' > "$H1/.claude/hooks/blank.sh"
# The dotfiles checkout's own .claude: dot-named, so no ROOT/*/.claude glob reaches it.
mkdir -p "$H1/.dotfiles/.claude/skills/x"
printf -- '---\nname: x\n---\n' > "$H1/.dotfiles/.claude/skills/x/SKILL.md"
# A repo skill named like one of Claude Code's own dirs, which only a top-level prune leaves alone.
H1_DEBUG_SKILL="$H1/quantivly/hub/.claude/skills/debug/SKILL.md"
mkdir -p "$(dirname "$H1_DEBUG_SKILL")"
printf -- '---\nname: debug\n---\n' > "$H1_DEBUG_SKILL"
# Credentials held by name in JSON: in the settings env block, and under a key deeper in a repo's.
jq -n --arg env_value "$FIXTURE_JSON_ENV_VALUE" \
    '{permissions: {allow: ["Bash(ls)"]}, model: "opus", env: {MY_API_TOKEN: $env_value}}' > "$H1/.claude/settings.json"
jq -n --arg named_value "$FIXTURE_JSON_NAMED_VALUE" \
    '{hub: true, mcp: {SOME_SECRET: $named_value}}' > "$H1/quantivly/hub/.claude/settings.json"
H1_TREE_BEFORE=$(host_tree_listing "$H1")

W="$TMPROOT/ws"
LC_ALL="$UTF8_LOCALE" "$SUT" --collect --workspace "$W" --host h1=h1:.claude >/dev/null 2>&1; rc=$?
H1_COLLECT_RC=$rc

printf 'collect: include set lands under cfg/ with the layout\n'
layout_complete=no
if [[ -f $W/h1/cfg/CLAUDE.md && -f $W/h1/cfg/hooks/a.sh && -f $W/h1/cfg/skills/rabota/SKILL.md \
   && -f $W/h1/cfg/agents/x.md && -f $W/h1/cfg/plugins/known_marketplaces.json \
   && -f $W/h1/memory/-home-h1-quantivly-hub/fact-one.md && -f $W/h1/roots/quantivly.CLAUDE.md \
   && -f $W/h1/repos/quantivly/hub/.claude/settings.json ]]; then
    layout_complete=yes
fi
check "include set: exit 0 and every layout path present" "$H1_COLLECT_RC $layout_complete" "0 yes"

printf "collect: the dotfiles checkout's own .claude is collected\n"
dotfiles_skill_state=absent
cmp -s "$H1/.dotfiles/.claude/skills/x/SKILL.md" "$W/h1/repos/home/.dotfiles/.claude/skills/x/SKILL.md" \
    && dotfiles_skill_state=copied
check "dotfiles .claude: its skill lands under repos/home/.dotfiles/.claude/" "$dotfiles_skill_state" "copied"

printf 'collect: credentials, .claude.json, transcripts, sessions, plugin cache and synced skills are never copied\n'
h1_collected=no; [[ -f $W/h1/facts.tsv ]] && h1_collected=yes
credential_files=$(grep -rlF -- "$FIXTURE_CREDENTIAL" "$W" 2>/dev/null)
excluded_entries=$(find "$W/h1" \( -name '*.jsonl' -o -name sessions -o -path '*/plugins/cache' \
    -o -path '*/skills/synced' \) -print 2>/dev/null)
check "excluded: nothing credential, transcript or cache-shaped collected" \
    "$h1_collected|$credential_files|$excluded_entries" "yes||"

printf 'collect: every pruned path is named in collect.log\n'
missing_excluded_lines=""
for expected_excluded_path in cfg/skills/rabota/.credentials.json repos/quantivly/hub/.claude/plugins/cache \
        memory/-home-h1-quantivly-hub/stray.jsonl; do
    [[ $(has_line "$W/h1/collect.log" "excluded${TAB}$expected_excluded_path") == yes ]] \
        || missing_excluded_lines+=" (missing: $expected_excluded_path)"
done
excluded_lines_logged=yes; [[ -z "$missing_excluded_lines" ]] || excluded_lines_logged="no$missing_excluded_lines"
check "excluded log: a by-name prune in cfg/, repos/ and memory/ each logged by layout path" \
    "$excluded_lines_logged" "yes"

printf "collect: a repo skill named like one of Claude Code's own dirs is collected\n"
debug_skill_state=absent
cmp -s "$H1_DEBUG_SKILL" "$W/h1/repos/quantivly/hub/.claude/skills/debug/SKILL.md" && debug_skill_state=copied
debug_skill_logged=$(has_line "$W/h1/collect.log" "excluded${TAB}repos/quantivly/hub/.claude/skills/debug")
check "top-level prunes: repos/.../.claude/skills/debug/SKILL.md copied, not logged as excluded" \
    "$debug_skill_state $debug_skill_logged" "copied no"

printf 'collect: a credential-shaped string in a collected file is redacted\n'
redacted_count=$(grep -c REDACTED "$W/h1/cfg/CLAUDE.md" 2>/dev/null)
literal_present=no
for fixture_secret in "$FIXTURE_LINEAR_KEY" "$FIXTURE_NAMED_SECRET"; do
    grep -qF -- "$fixture_secret" "$W/h1/cfg/CLAUDE.md" 2>/dev/null && literal_present=yes
done
check "redacted: by shape and by name after an invalid byte, in a UTF-8 locale" \
    "$redacted_count $literal_present" "2 no"

printf 'collect: a credential held by name in JSON is redacted\n'
json_literals_left=$(grep -rlF -e "$FIXTURE_JSON_ENV_VALUE" -e "$FIXTURE_JSON_NAMED_VALUE" "$W" 2>/dev/null)
env_value_now=$(jq -r '.env.MY_API_TOKEN' "$W/h1/cfg/settings.json" 2>/dev/null)
model_value_now=$(jq -r '.model' "$W/h1/cfg/settings.json" 2>/dev/null)
named_value_now=$(jq -r '.mcp.SOME_SECRET' "$W/h1/repos/quantivly/hub/.claude/settings.json" 2>/dev/null)
# The fixtures must be ones the line redactor passes whole, or this row would not reach the JSON pass.
line_redactor_misses=no
if "$DOTFILES/scripts/redact-secrets.sh" < "$H1/.claude/settings.json" | grep -qF -- "$FIXTURE_JSON_ENV_VALUE" \
   && "$DOTFILES/scripts/redact-secrets.sh" < "$H1/quantivly/hub/.claude/settings.json" \
        | grep -qF -- "$FIXTURE_JSON_NAMED_VALUE"; then
    line_redactor_misses=yes
fi
check "JSON names: the env value and a SOME_SECRET value replaced, nowhere in the workspace; model kept" \
    "$line_redactor_misses|$json_literals_left|$env_value_now $named_value_now $model_value_now" \
    "yes||$JSON_REDACTED_VALUE $JSON_REDACTED_VALUE opus"

printf 'collect: binary file is skipped and logged\n'
blob_state=absent; [[ -e $W/h1/cfg/hooks/blob.bin ]] && blob_state=present
blob_logged=$(has_line "$W/h1/collect.log" "binary-skipped${TAB}cfg/hooks/blob.bin")
empty_text_kept=no
[[ -f $W/h1/cfg/hooks/empty.sh && -f $W/h1/cfg/hooks/blank.sh ]] && empty_text_kept=yes
check "binary: not in the workspace, named in collect.log; empty and blank-line text kept" \
    "$blob_state $blob_logged $empty_text_kept" "absent yes yes"

printf 'collect: symlinks are dereferenced and recorded\n'
link_target="$H1/.dotfiles/claude/hooks/b.sh"
b_kind=missing
if [[ -L $W/h1/cfg/hooks/b.sh ]]; then b_kind=symlink
elif [[ -f $W/h1/cfg/hooks/b.sh ]] && cmp -s "$W/h1/cfg/hooks/b.sh" "$link_target"; then b_kind=copy-of-target
fi
b_recorded=$(has_line "$W/h1/links.tsv" "cfg/hooks/b.sh${TAB}$link_target")
check "symlink: a regular copy of the target, recorded in links.tsv" "$b_kind $b_recorded" "copy-of-target yes"

printf 'collect: facts.tsv carries hostname, user, home, cfgdir, claude_version 2.1.300, herdr_version 0.9.5\n'
fact_keys=$(cut -f1 "$W/h1/facts.tsv" 2>/dev/null | tr '\n' ' ')
facts_match=yes
for expected_fact in "hostname${TAB}$(uname -n)" "user${TAB}$(id -un)" "home${TAB}$H1" \
        "cfgdir${TAB}.claude" "claude_version${TAB}2.1.300" "herdr_version${TAB}0.9.5"; do
    [[ $(has_line "$W/h1/facts.tsv" "$expected_fact") == yes ]] || facts_match="no (missing: $expected_fact)"
done
collected_at_shape=no
grep -qE "^collected_at${TAB}[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\$" "$W/h1/facts.tsv" 2>/dev/null \
    && collected_at_shape=yes
check "facts: the seven keys in order, each value right" "$fact_keys|$facts_match|$collected_at_shape" \
    "hostname user home cfgdir claude_version herdr_version collected_at |yes|yes"

printf 'collect: claude version falls back to unknown\n'
make_host noclaude
rm "$FIXTURE_HOSTS/noclaude/.local/bin/claude"
W_NOCLAUDE="$TMPROOT/ws-noclaude"
"$SUT" --collect --workspace "$W_NOCLAUDE" --host noclaude=noclaude:.claude >/dev/null 2>&1; rc=$?
claude_unknown=$(has_line "$W_NOCLAUDE/noclaude/facts.tsv" "claude_version${TAB}unknown")
check "no ~/.local/bin/claude: exit 0, claude_version unknown" "$rc $claude_unknown" "0 yes"

printf 'collect: absent paths do not fail the collect\n'
make_host noagents
rm -r "$FIXTURE_HOSTS/noagents/.claude/agents"
W_NOAGENTS="$TMPROOT/ws-noagents"
"$SUT" --collect --workspace "$W_NOAGENTS" --host noagents=noagents:.claude >/dev/null 2>&1; rc=$?
agents_absent=$(has_line "$W_NOAGENTS/noagents/collect.log" "absent${TAB}agents")
toysim_absent=$(has_line "$W_NOAGENTS/noagents/collect.log" "absent${TAB}toysim")
dotfiles_claude_absent=$(has_line "$W_NOAGENTS/noagents/collect.log" "absent${TAB}.dotfiles/.claude")
check "no agents/, no ~/toysim, no ~/.dotfiles/.claude: exit 0, each logged absent" \
    "$rc $agents_absent $toysim_absent $dotfiles_claude_absent" "0 yes yes yes"

printf 'collect: an unreachable host exits 2, names it, and the reachable host is still collected\n'
W_DOWN="$TMPROOT/ws-down"
err=$("$SUT" --collect --workspace "$W_DOWN" --host down=down:.claude --host h1=h1:.claude 2>&1 >/dev/null); rc=$?
names_down=no; [[ "$err" == *"collect of down failed"* ]] && names_down=yes
h1_beside_down=no; [[ -f $W_DOWN/h1/facts.tsv ]] && h1_beside_down=yes
host_statuses=$(cut -f1,2,3,5 "$W_DOWN/hosts.tsv" 2>/dev/null | tr '\n' '|')
check "unreachable: exit 2, named, h1 collected, hosts.tsv says failed then ok" \
    "$rc $names_down $h1_beside_down $host_statuses" \
    "2 yes yes down${TAB}down${TAB}.claude${TAB}failed|h1${TAB}h1${TAB}.claude${TAB}ok|"

printf 'collect: a re-collect replaces the earlier one on success and keeps it on failure\n'
make_host rerun
W_RERUN="$TMPROOT/ws-rerun"
# Two hosts, so the two re-collects below swap twice in one run.
"$SUT" --collect --workspace "$W_RERUN" --host rerun=rerun:.claude --host rerun2=rerun:.claude >/dev/null 2>&1
rm "$FIXTURE_HOSTS/rerun/.claude/agents/x.md"
# The replacing collect runs with the recording rm: an interrupt inside an rm of the earlier
# tree would leave a partial tree that still looks like a collect, so it is renamed aside instead.
rm -f "$RM_CALLS"
PATH="$RM_RECORDER_BIN:$PATH" "$SUT" --collect --workspace "$W_RERUN" --host rerun=rerun:.claude \
    --host rerun2=rerun:.claude >/dev/null 2>&1; rerun_rc=$?
rm_recorder_live=no; [[ -s $RM_CALLS ]] && rm_recorder_live=yes
earlier_removed_in_place=$(has_line "$RM_CALLS" "$W_RERUN/rerun")
# ...and each earlier tree, once set aside, is removed by the swap that replaced it, not left to
# the exit trap (which knows only the last swap of the run).
aside_left=$(find "$W_RERUN" -name '.collecting-*' -print)
stale_agent=absent; [[ -e $W_RERUN/rerun/cfg/agents/x.md ]] && stale_agent=present
rerun_rows=$(wc -l 2>/dev/null < "$W_RERUN/hosts.tsv")
"$SUT" --collect --workspace "$W_RERUN" --host rerun=down:.claude >/dev/null 2>&1; failed_rc=$?
earlier_tree_kept=no
[[ -f $W_RERUN/rerun/facts.tsv && -f $W_RERUN/rerun/cfg/CLAUDE.md ]] && earlier_tree_kept=yes
failed_status=$(cut -f1,2,5 "$W_RERUN/hosts.tsv" 2>/dev/null | tr '\n' '|')
check "re-collect: stale file gone, earlier trees swapped out not rm'd, one hosts.tsv row per host; a failed one keeps the earlier tree" \
    "$rerun_rc $stale_agent $rm_recorder_live $earlier_removed_in_place|$aside_left|$rerun_rows $failed_rc $earlier_tree_kept $failed_status" \
    "0 absent yes no||2 2 yes rerun${TAB}down${TAB}failed|rerun2${TAB}rerun${TAB}ok|"

printf 'collect: a workspace entry that is not an earlier collect is never replaced\n'
W_FOREIGN="$TMPROOT/ws-foreign"
mkdir -p "$W_FOREIGN/h1"
printf 'not a collect\n' > "$W_FOREIGN/h1/keep.txt"
err=$("$SUT" --collect --workspace "$W_FOREIGN" --host h1=h1:.claude 2>&1 >/dev/null); rc=$?
names_foreign=no; [[ "$err" == *"is not an earlier collect"* ]] && names_foreign=yes
foreign_kept=no; [[ -f $W_FOREIGN/h1/keep.txt && ! -e $W_FOREIGN/h1/cfg ]] && foreign_kept=yes
check "foreign dir: exit 2, named, left exactly as it was" "$rc $names_foreign $foreign_kept" "2 yes yes"

printf 'collect: a config dir missing on the host fails that host\n'
W_NOCFG="$TMPROOT/ws-nocfg"
err=$("$SUT" --collect --workspace "$W_NOCFG" --host nocfg=h1:.claude-missing 2>&1 >/dev/null); rc=$?
names_missing_cfgdir=no; [[ "$err" == *"has no .claude-missing"* ]] && names_missing_cfgdir=yes
nocfg_facts=absent; [[ -e $W_NOCFG/nocfg/facts.tsv ]] && nocfg_facts=present
check "missing config dir: exit 2, named, no facts.tsv" "$rc $names_missing_cfgdir $nocfg_facts" "2 yes absent"

printf 'collect: a read-only directory, or a staging dir a killed run left, leaves nothing unredacted\n'
W_READONLY="$TMPROOT/ws-readonly"
# What a SIGKILLed collect leaves: a staging dir of raw host content, a 555 directory inside.
stale_staging_dir="$W_READONLY/.collecting-killed.AbC123"
mkdir -p "$stale_staging_dir/cfg/locked"
printf 'linear key: %s\n' "$FIXTURE_LINEAR_KEY" > "$stale_staging_dir/cfg/locked/CLAUDE.md"
chmod 555 "$stale_staging_dir/cfg/locked"
# A real host with a 555 directory in its include set, through the remote script...
make_host rotree
rotree_locked="$FIXTURE_HOSTS/rotree/.claude/hooks/locked"
mkdir -p "$rotree_locked"
printf 'linear key: %s\n' "$FIXTURE_LINEAR_KEY" > "$rotree_locked/text.sh"
printf 'BLOB\0BINARY\n' > "$rotree_locked/blob.bin"
chmod 555 "$rotree_locked"
# ...and a stream that carries the 555 directory as a member, which GNU tar unpacks as 555.
canned_locked="$FIXTURE_HOSTS/rodir/canned-stream/cfg/locked"
mkdir -p "$canned_locked"
printf 'hostname\trodir\n' > "$FIXTURE_HOSTS/rodir/canned-stream/facts.tsv"
: > "$FIXTURE_HOSTS/rodir/canned-stream/links.tsv"
: > "$FIXTURE_HOSTS/rodir/canned-stream/collect.log"
printf 'linear key: %s\n' "$FIXTURE_LINEAR_KEY" > "$canned_locked/text.sh"
printf 'BLOB\0BINARY\n' > "$canned_locked/blob.bin"
chmod 555 "$canned_locked"
# The stream's `./` member gets this mode, set rather than left to mkdir's umask...
chmod 755 "$FIXTURE_HOSTS/rodir/canned-stream"
# ...and the collect runs under a pinned permissive umask, because GNU tar run by a non-root
# user applies the umask when it extracts a member: under 077 the staging dir would come out
# 700 with or without the collect's own chmod, and the mode check below would prove nothing.
PERMISSIVE_UMASK=022
( umask "$PERMISSIVE_UMASK"
  "$SUT" --collect --workspace "$W_READONLY" --host rotree=rotree:.claude --host rodir=rodir:.claude ) \
    >/dev/null 2>&1; rc=$?
staging_left=$(find "$W_READONLY" -name '.collecting-*' -print)
unredacted_left=$(grep -rlF -- "$FIXTURE_LINEAR_KEY" "$W_READONLY" 2>/dev/null)
binaries_left=$(find "$W_READONLY" -name blob.bin -print)
both_collected=no; [[ -f $W_READONLY/rotree/cfg/hooks/locked/text.sh && -f $W_READONLY/rodir/cfg/locked/text.sh ]] \
    && both_collected=yes
# The canned stream's `./` member is 755, which tar extracts as 755 under the umask above: kept,
# it would open the staging dir, unredacted content and all, to other users.
rodir_mode=$(find "$W_READONLY/rodir" -maxdepth 0 -printf '%m' 2>/dev/null)
check "read-only dirs: both hosts collected, rodir's dir 700; no staging dir, unredacted literal or binary left" \
    "$rc $both_collected $rodir_mode|$staging_left|$unredacted_left|$binaries_left" "0 yes 700|||"

printf 'collect: an interrupted collect leaves no staging directory\n'
make_host interrupt
printf 'linear key: %s\n' "$FIXTURE_LINEAR_KEY" >> "$FIXTURE_HOSTS/interrupt/.claude/CLAUDE.md"
W_INTERRUPT="$TMPROOT/ws-interrupt"
"$SUT" --collect --workspace "$W_INTERRUPT" --host interrupt=interrupt:.claude >/dev/null 2>&1; rc=$?
staging_left=$(find "$W_INTERRUPT" -name '.collecting-*' -print)
unredacted_left=$(grep -rlF -- "$FIXTURE_LINEAR_KEY" "$W_INTERRUPT" 2>/dev/null)
interrupted_host_installed=no; [[ -e $W_INTERRUPT/interrupt ]] && interrupted_host_installed=yes
check "interrupt: exit 143, nothing staged or unredacted left, host not installed" \
    "$rc $interrupted_host_installed|$staging_left|$unredacted_left" "143 no||"

printf 'collect: an interrupt between the two renames puts the earlier collect back\n'
make_host swap
W_SWAP="$TMPROOT/ws-swap"
"$SUT" --collect --workspace "$W_SWAP" --host swap=swap:.claude >/dev/null 2>&1
# Only the new collect would carry this file, so its absence says the tree in place is the earlier one.
printf -- '---\nname: new\n---\n' > "$FIXTURE_HOSTS/swap/.claude/agents/new.md"
PATH="$MV_INTERRUPTER_BIN:$PATH" AUDIT_INTERRUPT_AFTER_MOVING="$W_SWAP/swap" \
    "$SUT" --collect --workspace "$W_SWAP" --host swap=swap:.claude >/dev/null 2>&1; rc=$?
earlier_collect_state=missing
if [[ -f $W_SWAP/swap/facts.tsv && -f $W_SWAP/swap/cfg/agents/x.md ]]; then
    earlier_collect_state=earlier
    [[ -e $W_SWAP/swap/cfg/agents/new.md ]] && earlier_collect_state=new
fi
swap_leftovers=$(find "$W_SWAP" -name '.collecting-*' -print)
check "mid-swap interrupt: exit 143, the earlier collect back in place, no staging or aside left" \
    "$rc $earlier_collect_state|$swap_leftovers" "143 earlier|"

printf "collect: a killed run's set-aside collect is put back if its host dir is missing, else removed\n"
W_KILLED_SWAP="$TMPROOT/ws-killed-swap"
"$SUT" --collect --workspace "$W_KILLED_SWAP" --host lost=h1:.claude --host kept=h1:.claude >/dev/null 2>&1
# What a SIGKILL leaves: between the two renames, the host dir gone and its collect aside...
mv "$W_KILLED_SWAP/lost" "$W_KILLED_SWAP/.collecting-lost.replaced"
# ...and after them, the new collect in place with the earlier one still aside.
cp -R "$W_KILLED_SWAP/kept" "$W_KILLED_SWAP/.collecting-kept.replaced"
# Any run's startup sweep settles them; this one's own host is unreachable.
"$SUT" --collect --workspace "$W_KILLED_SWAP" --host down=down:.claude >/dev/null 2>&1; rc=$?
lost_restored=no; [[ -f $W_KILLED_SWAP/lost/facts.tsv && -f $W_KILLED_SWAP/lost/cfg/CLAUDE.md ]] && lost_restored=yes
kept_intact=no; [[ -f $W_KILLED_SWAP/kept/facts.tsv ]] && kept_intact=yes
# An aside moved onto an existing host dir would land inside it, so this searches the whole workspace.
killed_swap_leftovers=$(find "$W_KILLED_SWAP" -name '.collecting-*' -print)
check "killed mid-swap: the next run puts lost/ back, keeps kept/, and leaves no aside anywhere" \
    "$rc $lost_restored $kept_intact|$killed_swap_leftovers" "2 yes yes|"

printf 'collect: a second --collect on a locked workspace exits 2 and names the run holding the lock\n'
W_LOCKED="$TMPROOT/ws-locked"
mkdir -p "$W_LOCKED"
LOCKED_WORKSPACE_LOCK="$W_LOCKED/.collect.lock"
LOCK_HOLDER_READY="$TMPROOT/lock-holder-ready"
# What a running --collect holds: the lock, its pid written in. exec keeps the pid and the lock.
( exec 9>>"$LOCKED_WORKSPACE_LOCK"
  flock -n 9 || exit 1
  printf '%s\n' "$BASHPID" > "$LOCKED_WORKSPACE_LOCK"
  : > "$LOCK_HOLDER_READY"
  exec sleep 60 ) &
lock_holder_pid=$!
LOCK_HOLDER_WAIT_TENTHS=100
for (( waited_tenths = 0; waited_tenths < LOCK_HOLDER_WAIT_TENTHS; waited_tenths++ )); do
    [[ -e $LOCK_HOLDER_READY ]] && break
    sleep 0.1
done
[[ -e $LOCK_HOLDER_READY ]] || fatal "the lock holder never took $LOCKED_WORKSPACE_LOCK; the lock row would be hollow"
err=$("$SUT" --collect --workspace "$W_LOCKED" --host h1=h1:.claude 2>&1 >/dev/null); rc=$?
kill "$lock_holder_pid" 2>/dev/null
wait "$lock_holder_pid" 2>/dev/null
names_lock_holder=no
[[ "$err" == *"another --collect (pid $lock_holder_pid) holds $LOCKED_WORKSPACE_LOCK"* ]] && names_lock_holder=yes
locked_host_collected=no; [[ -e $W_LOCKED/h1 ]] && locked_host_collected=yes
check "lock: exit 2, the lock and its holder's pid named, nothing collected" \
    "$rc $names_lock_holder $locked_host_collected" "2 yes no"

printf 'collect: a host dir that reappears mid-swap is never installed into\n'
make_host nest
W_NEST="$TMPROOT/ws-nest"
"$SUT" --collect --workspace "$W_NEST" --host nest=nest:.claude >/dev/null 2>&1
# Only the new collect would carry this file.
printf -- '---\nname: new\n---\n' > "$FIXTURE_HOSTS/nest/.claude/agents/new.md"
err=$(PATH="$MV_RESTORER_BIN:$PATH" AUDIT_RESTORE_AFTER_MOVING="$W_NEST/nest" \
    "$SUT" --collect --workspace "$W_NEST" --host nest=nest:.claude 2>&1 >/dev/null); rc=$?
names_nest=no; [[ "$err" == *"cannot replace $W_NEST/nest"* ]] && names_nest=yes
nest_tree_state=missing
if [[ -f $W_NEST/nest/facts.tsv ]]; then
    nest_tree_state=earlier
    [[ -e $W_NEST/nest/cfg/agents/new.md ]] && nest_tree_state=new
fi
# A plain mv would have put the new collect inside the host dir under its staging name.
nest_leftovers=$(find "$W_NEST" -name '.collecting-*' -print)
nest_status=$(cut -f1,5 "$W_NEST/hosts.tsv" 2>/dev/null | tr '\n' '|')
check "reappeared host dir: exit 2, named, the earlier tree whole with nothing nested in it, status failed" \
    "$rc $names_nest $nest_tree_state|$nest_leftovers|$nest_status" "2 yes earlier||nest${TAB}failed|"

printf 'collect: a stream member that is neither a file nor a directory fails the host\n'
LINK_MEMBER_STREAM="$FIXTURE_HOSTS/linkmember/canned-stream"
mkdir -p "$LINK_MEMBER_STREAM/cfg"
printf 'hostname\tlinkmember\n' > "$LINK_MEMBER_STREAM/facts.tsv"
: > "$LINK_MEMBER_STREAM/links.tsv"
: > "$LINK_MEMBER_STREAM/collect.log"
printf '# instructions\n' > "$LINK_MEMBER_STREAM/cfg/CLAUDE.md"
LINK_MEMBER_TARGET="$TMPROOT/outside-the-stream"
printf 'outside\n' > "$LINK_MEMBER_TARGET"
ln -s "$LINK_MEMBER_TARGET" "$LINK_MEMBER_STREAM/cfg/link-out"
W_LINK_MEMBER="$TMPROOT/ws-link-member"
err=$("$SUT" --collect --workspace "$W_LINK_MEMBER" --host linkmember=linkmember:.claude 2>&1 >/dev/null); rc=$?
names_link_member=no
[[ "$err" == *"collect of linkmember failed: the stream carried cfg/link-out, which is neither a regular file nor a directory"* ]] \
    && names_link_member=yes
link_member_installed=no; [[ -e $W_LINK_MEMBER/linkmember ]] && link_member_installed=yes
link_member_leftovers=$(find "$W_LINK_MEMBER" -name '.collecting-*' -print)
check "member type: a symlink member exits 2, host and member named, nothing installed or staged" \
    "$rc $names_link_member $link_member_installed|$link_member_leftovers" "2 yes no|"

# ---------------------------------------------------------------------------------------------
# --collect on this machine (alias `local`)
# ---------------------------------------------------------------------------------------------
#
# The laptop is collected without ssh, under the caller's HOME — here the fixture `lap`. Its
# account dirs each hold a settings.json: q1 a real copy holding a credential, q2 a symlink to
# ~/.claude/settings.json, and q3 a symlinked seat dir (as personal -> personal-0 is).

make_host lap
LAP="$FIXTURE_HOSTS/lap"
LAP_ACCOUNT_DIRS="$LAP/.local/state/claude-account-dirs"
mkdir -p "$LAP_ACCOUNT_DIRS/q1" "$LAP_ACCOUNT_DIRS/q2"
printf '{"env":{"LINEAR_API_KEY":"%s"}}\n' "$FIXTURE_LINEAR_KEY" > "$LAP_ACCOUNT_DIRS/q1/settings.json"
ln -s "$LAP/.claude/settings.json" "$LAP_ACCOUNT_DIRS/q2/settings.json"
ln -s q1 "$LAP_ACCOUNT_DIRS/q3"
LAP_TREE_BEFORE=$(host_tree_listing "$LAP")
W_LAPTOP="$TMPROOT/ws-laptop"
ssh_recorder_live=no; [[ -s $SSH_CALLS ]] && ssh_recorder_live=yes
rm -f "$SSH_CALLS"
# The collect script's one write is its own mktemp -d, on whichever machine runs it.
HOME="$LAP" TMPDIR="$REMOTE_TMPDIR" "$SUT" --collect --workspace "$W_LAPTOP" --host laptop=local:.claude \
    >/dev/null 2>&1; LAPTOP_COLLECT_RC=$?

printf 'collect: local host uses no ssh\n'
ssh_calls_made=none; [[ -s $SSH_CALLS ]] && ssh_calls_made=some
laptop_cfg_collected=no; [[ -f $W_LAPTOP/laptop/cfg/CLAUDE.md ]] && laptop_cfg_collected=yes
laptop_home_fact=$(has_line "$W_LAPTOP/laptop/facts.tsv" "home${TAB}$LAP")
check "local: exit 0, no ssh call (the stub recorded the earlier ones), cfg/ collected from the caller's HOME" \
    "$LAPTOP_COLLECT_RC $ssh_recorder_live $ssh_calls_made $laptop_cfg_collected $laptop_home_fact" \
    "0 yes none yes yes"

printf 'collect: account-dir copies are collected and compared\n'
q1_state=absent; [[ -f $W_LAPTOP/laptop/account-dirs/q1/settings.json ]] && q1_state=present
linked_seats_state=absent
[[ -e $W_LAPTOP/laptop/account-dirs/q2 || -e $W_LAPTOP/laptop/account-dirs/q3 ]] && linked_seats_state=present
q2_logged=$(has_line "$W_LAPTOP/laptop/collect.log" "account-dir-link${TAB}q2")
q3_logged=$(has_line "$W_LAPTOP/laptop/collect.log" "account-dir-link${TAB}q3")
check "account dirs: q1's real copy collected; q2 (linked file) and q3 (linked seat) absent and logged" \
    "$q1_state $linked_seats_state $q2_logged $q3_logged" "present absent yes yes"

printf 'collect: local collect redacts too\n'
q1_redacted=no; grep -qF REDACTED "$W_LAPTOP/laptop/account-dirs/q1/settings.json" 2>/dev/null && q1_redacted=yes
laptop_unredacted=$(grep -rlF -- "$FIXTURE_LINEAR_KEY" "$W_LAPTOP" 2>/dev/null)
check "local redaction: q1's credential is REDACTED, the literal nowhere in the workspace" \
    "$q1_redacted|$laptop_unredacted" "yes|"

printf 'collect: a machine with no account dirs logs them absent\n'
make_host noseats
W_NOSEATS="$TMPROOT/ws-noseats"
HOME="$FIXTURE_HOSTS/noseats" TMPDIR="$REMOTE_TMPDIR" "$SUT" --collect --workspace "$W_NOSEATS" \
    --host laptop=local:.claude >/dev/null 2>&1; rc=$?
account_dirs_absent=$(has_line "$W_NOSEATS/laptop/collect.log" \
    "absent${TAB}.local/state/claude-account-dirs/*/settings.json")
account_dirs_layout=absent; [[ -e $W_NOSEATS/laptop/account-dirs ]] && account_dirs_layout=present
check "no ~/.local/state/claude-account-dirs: exit 0, logged absent, no account-dirs/ in the collect" \
    "$rc $account_dirs_absent $account_dirs_layout" "0 yes absent"

printf 'collect: the host tree is unchanged\n'
H1_TREE_AFTER=$(host_tree_listing "$H1")
LAP_TREE_AFTER=$(host_tree_listing "$LAP")
tree_listing_size=$(wc -l <<<"$H1_TREE_BEFORE")
tree_unchanged=no; [[ "$H1_TREE_BEFORE" == "$H1_TREE_AFTER" ]] && tree_unchanged=yes
lap_tree_unchanged=no; [[ "$LAP_TREE_BEFORE" == "$LAP_TREE_AFTER" ]] && lap_tree_unchanged=yes
# The listing must cover the fixture (>20 entries), or "unchanged" compares two empty strings.
listing_covers_fixture=no; (( tree_listing_size > 20 )) && listing_covers_fixture=yes
remote_tmp_leftovers=$(find "$REMOTE_TMPDIR" -mindepth 1 -print)
check "read-only: h1's and lap's trees identical after every collect above, the collect script's temp dir removed" \
    "$tree_unchanged $lap_tree_unchanged $listing_covers_fixture|$remote_tmp_leftovers" "yes yes yes|"

# ---------------------------------------------------------------------------------------------
# --matrix
# ---------------------------------------------------------------------------------------------
#
# Three fixture hosts, named h1 h2 h3 in the workspace and collected from the fixture homes mh1
# mh2 mh3 (the collect rows' h1 stays as it was), through the stub ssh in the order h3 h1 h2.
# That order is the column order, and it puts h3's files in the workspace FIRST: a newest:h3 can
# then come only from the hosts' own mtimes, never from the order the collect wrote them in.

make_host mh1; make_host mh2; make_host mh3
MH1="$FIXTURE_HOSTS/mh1"; MH2="$FIXTURE_HOSTS/mh2"; MH3="$FIXTURE_HOSTS/mh3"
for matrix_host_home in "$MH1" "$MH2" "$MH3"; do
    printf '# global instructions\n' > "$matrix_host_home/.claude/CLAUDE.md"
done
# cfg/agents/x.md only on h2: h1 keeps an empty agents/, h3 has no agents/ at all.
rm "$MH1/.claude/agents/x.md"
rm -r "$MH3/.claude/agents"
rm "$MH3/.claude/keybindings.json"
# cfg/hooks/a.sh: h3's copy differs and is the newest by the hosts' own clocks.
OLDER_MTIME_STAMP=202601010000
NEWER_MTIME_STAMP=202606010000
printf '#!/bin/sh\necho hook-a-changed-on-h3\n' > "$MH3/.claude/hooks/a.sh"
touch -t "$OLDER_MTIME_STAMP" "$MH1/.claude/hooks/a.sh" "$MH2/.claude/hooks/a.sh"
touch -t "$NEWER_MTIME_STAMP" "$MH3/.claude/hooks/a.sh"
# cfg/hooks/b.sh: a link into dotfiles on h1 and h3 (make_host), a real copy on h2.
rm "$MH2/.claude/hooks/b.sh"
cp "$MH2/.dotfiles/claude/hooks/b.sh" "$MH2/.claude/hooks/b.sh"
# On h1 a whole skill dir is a link, and one file inside it is a link of its own.
MH1_SHARED_SKILL="$MH1/.dotfiles/claude/skills/shared"
MH1_SHARED_REFERENCE="$MH1/.dotfiles/docs/ref.md"
mkdir -p "$MH1_SHARED_SKILL" "$(dirname "$MH1_SHARED_REFERENCE")"
printf -- '---\nname: shared\n---\n' > "$MH1_SHARED_SKILL/SKILL.md"
printf 'reference\n' > "$MH1_SHARED_REFERENCE"
ln -s "$MH1_SHARED_REFERENCE" "$MH1_SHARED_SKILL/ref.md"
ln -s "$MH1_SHARED_SKILL" "$MH1/.claude/skills/shared"
# Memory: h3's user is ec2.user, so its projects key has a dash where the user name has a dot.
MATRIX_STORE='quantivly-hub'
H3_USER='ec2.user'
mv "$MH3/.claude/projects/-home-mh3-$MATRIX_STORE" "$MH3/.claude/projects/-home-ec2-user-$MATRIX_STORE"
MH1_MEMORY="$MH1/.claude/projects/-home-mh1-$MATRIX_STORE/memory"
MH2_MEMORY="$MH2/.claude/projects/-home-mh2-$MATRIX_STORE/memory"
MH3_MEMORY="$MH3/.claude/projects/-home-ec2-user-$MATRIX_STORE/memory"
# fact-one.md: one name, two bodies (h2's differs), and h3's copy (h1's body) as new as h2's: a
# tie for newest names both.
printf -- '---\ndescription: fact one\n---\nrewritten on h2\n' > "$MH2_MEMORY/fact-one.md"
touch -t "$OLDER_MTIME_STAMP" "$MH1_MEMORY/fact-one.md"
touch -t "$NEWER_MTIME_STAMP" "$MH2_MEMORY/fact-one.md" "$MH3_MEMORY/fact-one.md"
# One fact under two names, its description spelled with other case, spacing and quotes...
printf -- '---\nname: fact two\ndescription: The Same  Fact\n---\nbody on h1\n' > "$MH1_MEMORY/fact-two.md"
printf -- '---\ndescription:   "the same fact"\n---\nbody on h2\n' > "$MH2_MEMORY/fact-2.md"
# ...and a note with no frontmatter, which must not pair with MEMORY.md over two empty descriptions,
# and one whose body (not its frontmatter) states the same description, which must not join them.
printf 'a note with no frontmatter\n' > "$MH1_MEMORY/notes.md"
printf -- '---\nname: body mention\n---\ndescription: the same fact\n' > "$MH2_MEMORY/body-mention.md"
# settings.json: allow rules a,b,d / b,c,d / b; the hook x.sh run three ways and y.sh only on h2;
# a plugin's boolean, a marketplace's source and one other key differ; h2 orders statusLine's keys
# differently, which is no difference.
cat > "$MH1/.claude/settings.json" <<'JSON'
{"permissions": {"allow": ["Bash(rule-a)", "Bash(rule-b)", "Bash(rule-d)"], "defaultMode": "auto"},
 "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash '/home/h1/.claude/hooks/x.sh'"}]}]},
 "enabledPlugins": {"tool@market": true},
 "extraKnownMarketplaces": {"market": {"source": {"source": "github", "repo": "owner/repo"}}},
 "statusLine": {"type": "command", "command": "status-line"},
 "autoMode": {"environment": "org-wide notes, long enough to print as a label"},
 "model": "opus", "theme": "dark"}
JSON
cat > "$MH2/.claude/settings.json" <<'JSON'
{"theme": "light", "model": "opus", "statusLine": {"command": "status-line", "type": "command"},
 "autoMode": {"environment": "laptop notes written against the home directory"},
 "permissions": {"defaultMode": "auto", "allow": ["Bash(rule-b)", "Bash(rule-c)", "Bash(rule-d)"]},
 "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
   {"type": "command", "command": "f=\"$HOME/.claude/hooks/x.sh\"; [ -r \"$f\" ] && exec bash \"$f\"; exit 0"},
   {"type": "command", "command": "python3 \"$HOME/.claude/hooks/y.sh\""}]}]},
 "enabledPlugins": {"tool@market": false},
 "extraKnownMarketplaces": {"market": {"source": {"source": "directory", "path": "/srv/market"}}}}
JSON
cat > "$MH3/.claude/settings.json" <<'JSON'
{"permissions": {"allow": ["Bash(rule-b)"], "defaultMode": "auto"},
 "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/home/h3/.claude/hooks/x.sh"}]}]},
 "enabledPlugins": {"tool@market": true},
 "statusLine": {"type": "command", "command": "status-line"},
 "autoMode": {"environment": "org-wide notes, long enough to print as a label"},
 "model": "opus", "theme": "dark"}
JSON

W_MATRIX="$TMPROOT/ws-matrix"
"$SUT" --collect --workspace "$W_MATRIX" --host h3=mh3:.claude --host h1=mh1:.claude --host h2=mh2:.claude \
    >/dev/null 2>&1 || fatal "the --matrix fixture collect failed; every --matrix row below would be hollow"

# The stub runs every host as this user, so each collect's facts.tsv says so; the user each
# fixture's projects key was made for is written in its place.
set_fact_user() {   # HOST_DIR USER
    awk -F'\t' -v OFS='\t' -v user_name="$2" '$1 == "user" { $2 = user_name } 1' "$1/facts.tsv" > "$1/facts.tsv.new" \
        && mv "$1/facts.tsv.new" "$1/facts.tsv"
}
set_fact_user "$W_MATRIX/h1" mh1
set_fact_user "$W_MATRIX/h2" mh2
set_fact_user "$W_MATRIX/h3" "$H3_USER"

# Copies made before the matrix runs, so no report is in them yet.
W_MATRIX_NO_FACTS="$TMPROOT/ws-matrix-no-facts"
W_MATRIX_FAILED_HOST="$TMPROOT/ws-matrix-failed-host"
W_MATRIX_READ_ONLY="$TMPROOT/ws-matrix-read-only"
W_MATRIX_UNNAMED="$TMPROOT/ws-matrix-unnamed"
W_MATRIX_EMPTY_FIELD="$TMPROOT/ws-matrix-empty-field"
for matrix_workspace_copy in "$W_MATRIX_NO_FACTS" "$W_MATRIX_FAILED_HOST" "$W_MATRIX_READ_ONLY" \
        "$W_MATRIX_UNNAMED" "$W_MATRIX_EMPTY_FIELD"; do
    cp -R "$W_MATRIX" "$matrix_workspace_copy"
done

MATRIX_REPORTS=(matrix.tsv matrix.md settings-matrix.md memory-matrix.tsv memory-matrix.md)
workspace_listing() { find "$1" -mindepth 1 -printf '%y %T@ %P\n' | LC_ALL=C sort; }   # DIR
MATRIX_LISTING_BEFORE=$(workspace_listing "$W_MATRIX")
matrix_ssh_recorder_live=no; [[ -s $SSH_CALLS ]] && matrix_ssh_recorder_live=yes
rm -f "$SSH_CALLS"
"$SUT" --matrix --workspace "$W_MATRIX" >/dev/null 2>&1; MATRIX_RC=$?
MATRIX_LISTING_AFTER=$(workspace_listing "$W_MATRIX")
M_TSV="$W_MATRIX/matrix.tsv"
M_SETTINGS="$W_MATRIX/settings-matrix.md"
M_MEMORY="$W_MATRIX/memory-matrix.tsv"

tsv_row() {   # FILE FIRST_FIELD [SECOND_FIELD] → the first line whose leading field(s) match
    awk -F'\t' -v first_field="$2" -v second_field="${3-}" \
        '$1 == first_field && (second_field == "" || $2 == second_field) { print; exit }' "$1" 2>/dev/null
}
tsv_status() { tsv_row "$1" "$2" | cut -f2; }   # MATRIX_TSV ARTIFACT
# matrix.tsv columns: artifact, status, then h3 h1 h2 (hosts.tsv order).
H3_COLUMN=3; H1_COLUMN=4

printf 'matrix: identical / only-on / missing-on / differs are each classified\n'
check "classified: CLAUDE.md identical, x.md only on h2, keybindings missing on h3, a.sh differs and h3 is newest" \
    "$(tsv_status "$M_TSV" cfg/CLAUDE.md)|$(tsv_status "$M_TSV" cfg/agents/x.md)|$(tsv_status "$M_TSV" cfg/keybindings.json)|$(tsv_status "$M_TSV" cfg/hooks/a.sh)" \
    "identical|only-on:h2|missing-on:h3|differs newest:h3"

printf 'matrix: identical content, link on one host, copy on the other, is identical with provenance\n'
b_row_expected="cfg/hooks/b.sh${TAB}identical${TAB}h3:link→$MH3/.dotfiles/claude/hooks/b.sh"
b_row_expected+="${TAB}h1:link→$MH1/.dotfiles/claude/hooks/b.sh${TAB}h2:copy"
b_row_matches=no; [[ "$(tsv_row "$M_TSV" cfg/hooks/b.sh)" == "$b_row_expected" ]] && b_row_matches=yes
# A file under a linked directory is that directory's target plus its own path, unless it is a
# link itself: the nearest link wins.
shared_skill_cell=$(tsv_row "$M_TSV" cfg/skills/shared/SKILL.md | cut -f"$H1_COLUMN")
shared_reference_cell=$(tsv_row "$M_TSV" cfg/skills/shared/ref.md | cut -f"$H1_COLUMN")
check "provenance: b.sh identical, h3 and h1 links, h2 a copy; a linked dir's files resolve through the nearest link" \
    "$b_row_matches|$shared_skill_cell|$shared_reference_cell" \
    "yes|h1:link→$MH1_SHARED_SKILL/SKILL.md|h1:link→$MH1_SHARED_REFERENCE"

printf 'matrix: missing is a status, not an abort\n'
expected_artifact_count=$(for matrix_host in h1 h2 h3; do
    ( cd "$W_MATRIX/$matrix_host" && find cfg roots repos account-dirs -type f 2>/dev/null )
done | LC_ALL=C sort -u | wc -l)
artifact_row_count=$(awk 'NR > 1' "$M_TSV" 2>/dev/null | wc -l)
rows_with_h3_cell=$(awk -F'\t' -v h3_column="$H3_COLUMN" 'NR > 1 && index($h3_column, "h3:") == 1' "$M_TSV" 2>/dev/null | wc -l)
x_on_h3=$(tsv_row "$M_TSV" cfg/agents/x.md | cut -f"$H3_COLUMN")
# The fixture's artifact count, so equal row counts cannot be two zeros.
MIN_FIXTURE_ARTIFACTS=10
fixture_has_artifacts=no; (( expected_artifact_count > MIN_FIXTURE_ARTIFACTS )) && fixture_has_artifacts=yes
check "missing: exit 1 (drift, not 2), one row per artifact of any host, each with an h3 cell; x.md is h3:absent" \
    "$MATRIX_RC $fixture_has_artifacts $artifact_row_count $rows_with_h3_cell $x_on_h3" \
    "1 yes $expected_artifact_count $expected_artifact_count h3:absent"

printf 'matrix: a declared host without facts.tsv exits 2 and names it\n'
rm "$W_MATRIX_NO_FACTS/h2/facts.tsv"
err=$("$SUT" --matrix --workspace "$W_MATRIX_NO_FACTS" 2>&1 >/dev/null); no_facts_rc=$?
names_h2=no; [[ "$err" == *"h2 has no facts.tsv"* ]] && names_h2=yes
no_facts_reports=$(cd "$W_MATRIX_NO_FACTS" && ls "${MATRIX_REPORTS[@]}" 2>/dev/null)
# hosts.tsv is the authority on which collects are valid: a failed one is refused the same way.
awk -F'\t' -v OFS='\t' '$1 == "h3" { $5 = "failed" } 1' "$W_MATRIX_FAILED_HOST/hosts.tsv" \
    > "$W_MATRIX_FAILED_HOST/hosts.tsv.new" && mv "$W_MATRIX_FAILED_HOST/hosts.tsv.new" "$W_MATRIX_FAILED_HOST/hosts.tsv"
err=$("$SUT" --matrix --workspace "$W_MATRIX_FAILED_HOST" 2>&1 >/dev/null); failed_host_rc=$?
names_h3=no; [[ "$err" == *"h3: hosts.tsv says its collect failed"* ]] && names_h3=yes
failed_host_reports=$(cd "$W_MATRIX_FAILED_HOST" && ls "${MATRIX_REPORTS[@]}" 2>/dev/null)
check "no facts.tsv, or hosts.tsv status failed: exit 2, the host named, no report written" \
    "$no_facts_rc $names_h2|$no_facts_reports|$failed_host_rc $names_h3|$failed_host_reports" "2 yes||2 yes|"

printf 'matrix: settings permissions.allow is reported as set differences\n'
missing_allow_lines=""
# shellcheck disable=SC2016  # the backticks are Markdown code spans, not command substitutions
for expected_line in '| `Bash(rule-a)` | only h1 | — | ✓ | — |' '| `Bash(rule-b)` | same | ✓ | ✓ | ✓ |' \
        '| `Bash(rule-c)` | only h2 | — | — | ✓ |' '| `Bash(rule-d)` | missing on h3 | — | ✓ | ✓ |'; do
    [[ $(has_line "$M_SETTINGS" "$expected_line") == yes ]] || missing_allow_lines+=" (missing: $expected_line)"
done
allow_lines_present=yes; [[ -z "$missing_allow_lines" ]] || allow_lines_present="no$missing_allow_lines"
check "allow: rule-a only h1, rule-b same, rule-c only h2, rule-d missing on h3" "$allow_lines_present" "yes"

printf 'matrix: settings hooks are compared by basename\n'
# shellcheck disable=SC2016  # the backticks are Markdown code spans, not command substitutions
x_hook_same=$(has_line "$M_SETTINGS" '| `PreToolUse x.sh` | same | ✓ | ✓ | ✓ |')
# shellcheck disable=SC2016  # the backticks are Markdown code spans, not command substitutions
y_hook_only_h2=$(has_line "$M_SETTINGS" '| `PreToolUse y.sh` | only h2 | — | — | ✓ |')
check "hooks: x.sh same though each host runs it differently, y.sh only h2" "$x_hook_same $y_hook_only_h2" "yes yes"

printf 'matrix: settings enabledPlugins, extraKnownMarketplaces and the other keys are compared by value\n'
# A value of 40 characters or more prints as a label and the first 8 characters of the sha256 of
# its JSON, object keys sorted.
canonical_json_digest() { printf '%s' "$(jq -cS . <<<"$1")" | sha256sum | cut -c1-8; }   # JSON
status_line_digest=$(canonical_json_digest '{"type": "command", "command": "status-line"}')
org_notes_digest=$(canonical_json_digest '{"environment": "org-wide notes, long enough to print as a label"}')
laptop_notes_digest=$(canonical_json_digest '{"environment": "laptop notes written against the home directory"}')
missing_other_settings_lines=""
# shellcheck disable=SC2016  # the backticks are Markdown code spans, not command substitutions
for expected_line in '| `tool@market` | differs | true | true | false |' '| `market` | differs | — | github | directory |' \
        '| `model` | same | "opus" | "opus" | "opus" |' '| `theme` | differs | "dark" | "dark" | "light" |' \
        '| `permissions.defaultMode` | same | "auto" | "auto" | "auto" |' \
        "| \`statusLine\` | same | v1 ($status_line_digest) | v1 ($status_line_digest) | v1 ($status_line_digest) |" \
        "| \`autoMode\` | differs | v1 ($org_notes_digest) | v1 ($org_notes_digest) | v2 ($laptop_notes_digest) |"; do
    [[ $(has_line "$M_SETTINGS" "$expected_line") == yes ]] || missing_other_settings_lines+=" (missing: $expected_line)"
done
other_settings_present=yes; [[ -z "$missing_other_settings_lines" ]] || other_settings_present="no$missing_other_settings_lines"
check "settings: plugin boolean differs, marketplace source differs; short values printed, long ones labelled, key order ignored" \
    "$other_settings_present" "yes"

printf 'matrix: memory stores meet across homes\n'
memory_index_row=$(has_line "$M_MEMORY" \
    "$MATRIX_STORE${TAB}MEMORY.md${TAB}identical${TAB}h3:present${TAB}h1:present${TAB}h2:present")
home_keyed_stores=$(awk -F'\t' 'NR > 1 && index($1, "-home-") == 1 { print $1 }' "$M_MEMORY" 2>/dev/null | LC_ALL=C sort -u)
check "memory: three homes' quantivly-hub stores are one store; no row keeps a -home- key" \
    "$memory_index_row|$home_keyed_stores" "yes|"

printf 'matrix: a memory topic file with one name and two bodies is differs; one description under two names is flagged\n'
fact_one_status=$(tsv_row "$M_MEMORY" "$MATRIX_STORE" fact-one.md | cut -f3)
same_fact_rows=$(awk -F'\t' '$2 == "same-fact?"' "$M_MEMORY" 2>/dev/null)
check "memory: fact-one.md differs, newest tied on h3 and h2; exactly one same-fact? row, fact-two.md~fact-2.md, naming the host of each" \
    "$fact_one_status|$same_fact_rows" \
    "differs newest:h3,h2|$MATRIX_STORE${TAB}same-fact?${TAB}fact-two.md~fact-2.md${TAB}h3:absent${TAB}h1:fact-two.md${TAB}h2:fact-2.md"

printf 'matrix: account-dir settings copies are compared against cfg/settings.json\n'
make_host mlap
MLAP_ACCOUNT_DIRS="$FIXTURE_HOSTS/mlap/.local/state/claude-account-dirs"
mkdir -p "$MLAP_ACCOUNT_DIRS/q1" "$MLAP_ACCOUNT_DIRS/q2"
printf '{"model":"sonnet"}\n' > "$MLAP_ACCOUNT_DIRS/q1/settings.json"
cp "$FIXTURE_HOSTS/mlap/.claude/settings.json" "$MLAP_ACCOUNT_DIRS/q2/settings.json"
W_MATRIX_LAPTOP="$TMPROOT/ws-matrix-laptop"
HOME="$FIXTURE_HOSTS/mlap" TMPDIR="$REMOTE_TMPDIR" "$SUT" --collect --workspace "$W_MATRIX_LAPTOP" \
    --host laptop=local:.claude >/dev/null 2>&1
"$SUT" --matrix --workspace "$W_MATRIX_LAPTOP" >/dev/null 2>&1
q1_differs=$(has_line "$W_MATRIX_LAPTOP/matrix.tsv" \
    "account-dirs/q1/settings.json${TAB}differs-from:cfg/settings.json${TAB}laptop:present")
q2_same=$(has_line "$W_MATRIX_LAPTOP/matrix.tsv" \
    "account-dirs/q2/settings.json${TAB}same-as:cfg/settings.json${TAB}laptop:present")
check "account dirs: q1 differs-from cfg/settings.json, q2 same-as it" "$q1_differs $q2_same" "yes yes"

printf 'matrix: exit 0 when every artifact is identical, 1 when any row is not\n'
# One fixture HOME collected twice as two hosts: every file the same on both, including an
# account-dir copy equal to cfg/settings.json, which is no drift.
make_host msame
mkdir -p "$FIXTURE_HOSTS/msame/.local/state/claude-account-dirs/q1"
cp "$FIXTURE_HOSTS/msame/.claude/settings.json" "$FIXTURE_HOSTS/msame/.local/state/claude-account-dirs/q1/settings.json"
W_MATRIX_SAME_COLLECT="$TMPROOT/ws-matrix-same-collect"
HOME="$FIXTURE_HOSTS/msame" TMPDIR="$REMOTE_TMPDIR" "$SUT" --collect --workspace "$W_MATRIX_SAME_COLLECT" \
    --host a=local:.claude --host b=local:.claude >/dev/null 2>&1
# The identical copy sits at a path with a backslash followed by n: awk -v would turn that into a
# newline, so a check comparing FILENAME with a -v copy of the path would never match it. (The
# collect is made at a plain path: tar -C reads the same escape.)
W_MATRIX_SAME="$TMPROOT/"'ws-matrix\new-same'
W_MATRIX_CFG_DRIFT="$TMPROOT/ws-matrix-cfg-drift"
W_MATRIX_MEMORY_DRIFT="$TMPROOT/ws-matrix-memory-drift"
for matrix_workspace_copy in "$W_MATRIX_SAME" "$W_MATRIX_CFG_DRIFT" "$W_MATRIX_MEMORY_DRIFT"; do
    cp -R "$W_MATRIX_SAME_COLLECT" "$matrix_workspace_copy"
done
"$SUT" --matrix --workspace "$W_MATRIX_SAME" >/dev/null 2>&1; identical_rc=$?
same_row_count=$(awk 'NR > 1' "$W_MATRIX_SAME/matrix.tsv" 2>/dev/null | wc -l)
same_has_rows=no; (( same_row_count > MIN_FIXTURE_ARTIFACTS )) && same_has_rows=yes
printf 'changed on b\n' >> "$W_MATRIX_CFG_DRIFT/b/cfg/CLAUDE.md"
"$SUT" --matrix --workspace "$W_MATRIX_CFG_DRIFT" >/dev/null 2>&1; cfg_drift_rc=$?
# A drift in memory alone, which matrix.tsv does not carry.
printf 'changed on b\n' >> "$W_MATRIX_MEMORY_DRIFT/b/memory/-home-msame-quantivly-hub/fact-one.md"
"$SUT" --matrix --workspace "$W_MATRIX_MEMORY_DRIFT" >/dev/null 2>&1; memory_drift_rc=$?
check "exit: 0 with every artifact identical (rows present), 1 on a cfg drift, 1 on a memory-only drift" \
    "$identical_rc $same_has_rows $cfg_drift_rc $memory_drift_rc" "0 yes 1 1"

printf 'matrix: it writes its five reports and nothing else, and reaches no host\n'
new_workspace_entries=$(LC_ALL=C comm -13 <(cut -d' ' -f3- <<<"$MATRIX_LISTING_BEFORE" | LC_ALL=C sort) \
    <(cut -d' ' -f3- <<<"$MATRIX_LISTING_AFTER" | LC_ALL=C sort) | tr '\n' ' ')
expected_new_entries=$(printf '%s\n' "${MATRIX_REPORTS[@]}" | LC_ALL=C sort | tr '\n' ' ')
# Every entry that was there before is still there, with its type and mtime.
changed_workspace_entries=$(LC_ALL=C comm -23 <(printf '%s\n' "$MATRIX_LISTING_BEFORE") \
    <(printf '%s\n' "$MATRIX_LISTING_AFTER") | tr '\n' ' ')
matrix_ssh_calls=none; [[ -s $SSH_CALLS ]] && matrix_ssh_calls=some
check "writes: exactly the five reports added, nothing else changed, no ssh call (the recorder saw the collect's)" \
    "$new_workspace_entries|$changed_workspace_entries|$matrix_ssh_recorder_live $matrix_ssh_calls" \
    "$expected_new_entries||yes none"

printf 'matrix: --host is refused, the matrix reports on every host in hosts.tsv\n'
err=$("$SUT" --matrix --workspace "$W_MATRIX" --host h1=mh1:.claude 2>&1 >/dev/null); rc=$?
names_collect_only=no; [[ "$err" == *"--host applies to --collect only"* ]] && names_collect_only=yes
check "--matrix --host: exit 64, says --host is for --collect" "$rc $names_collect_only" "64 yes"

printf 'matrix: an unwritable workspace exits 2 and claims no report\n'
chmod 555 "$W_MATRIX_READ_ONLY"
"$SUT" --matrix --workspace "$W_MATRIX_READ_ONLY" >"$TMPROOT/read-only.out" 2>"$TMPROOT/read-only.err"; read_only_rc=$?
chmod 755 "$W_MATRIX_READ_ONLY"
read_only_stdout=$(<"$TMPROOT/read-only.out")
names_unwritable_report=no
[[ $(<"$TMPROOT/read-only.err") == *"cannot write $W_MATRIX_READ_ONLY/matrix.tsv"* ]] && names_unwritable_report=yes
check "unwritable: exit 2, the report it could not write named, no 'reports in' line on stdout" \
    "$read_only_rc $names_unwritable_report|$read_only_stdout" "2 yes|"

printf 'matrix: a collect in the workspace that hosts.tsv does not name exits 2 and names it\n'
cp -R "$W_MATRIX_UNNAMED/h1" "$W_MATRIX_UNNAMED/h4"
err=$("$SUT" --matrix --workspace "$W_MATRIX_UNNAMED" 2>&1 >/dev/null); unnamed_rc=$?
names_h4=no; [[ "$err" == *"$W_MATRIX_UNNAMED/h4 holds a collect that hosts.tsv does not name"* ]] && names_h4=yes
unnamed_reports=$(cd "$W_MATRIX_UNNAMED" && ls "${MATRIX_REPORTS[@]}" 2>/dev/null)
check "unnamed collect: exit 2, h4 named, no report written" "$unnamed_rc $names_h4|$unnamed_reports" "2 yes|"

printf 'matrix: hosts.tsv is split by field, so an empty field keeps its place; a short row is refused\n'
# A row with an empty alias: read through a tab IFS, the fields after it would shift left and
# the status read would be the empty last one, a "failed" collect.
awk -F'\t' -v OFS='\t' '$1 == "h1" { $2 = "" } 1' "$W_MATRIX_EMPTY_FIELD/hosts.tsv" \
    > "$W_MATRIX_EMPTY_FIELD/hosts.tsv.new" && mv "$W_MATRIX_EMPTY_FIELD/hosts.tsv.new" "$W_MATRIX_EMPTY_FIELD/hosts.tsv"
"$SUT" --matrix --workspace "$W_MATRIX_EMPTY_FIELD" >/dev/null 2>&1; empty_field_rc=$?
# A row of four fields stops --collect before any host is collected, and the file is left alone.
W_SHORT_ROW="$TMPROOT/ws-short-row"
mkdir -p "$W_SHORT_ROW"
printf 'h1\tmh1\t.claude\tok\n' > "$W_SHORT_ROW/hosts.tsv"
short_row_before=$(<"$W_SHORT_ROW/hosts.tsv")
err=$("$SUT" --collect --workspace "$W_SHORT_ROW" --host h2=mh2:.claude 2>&1 >/dev/null); short_row_rc=$?
names_unparseable=no; [[ "$err" == *"cannot parse $W_SHORT_ROW/hosts.tsv"* ]] && names_unparseable=yes
short_row_collected=no; [[ -e $W_SHORT_ROW/h2 ]] && short_row_collected=yes
short_row_kept=no; [[ "$(<"$W_SHORT_ROW/hosts.tsv")" == "$short_row_before" ]] && short_row_kept=yes
check "hosts.tsv fields: an empty alias still reads status ok (exit 1, drift); a 4-field row stops --collect, nothing collected" \
    "$empty_field_rc|$short_row_rc $names_unparseable $short_row_collected $short_row_kept" "1|2 yes no yes"

printf "collect: hosts.tsv is merged, so re-collecting one host keeps every other host's row\n"
W_MERGE="$TMPROOT/ws-merge"
"$SUT" --collect --workspace "$W_MERGE" --host h1=mh1:.claude --host h2=mh2:.claude --host h3=down:.claude \
    >/dev/null 2>&1; first_merge_rc=$?
merge_rows_before=$(head -n 2 "$W_MERGE/hosts.tsv" 2>/dev/null)
"$SUT" --collect --workspace "$W_MERGE" --host h3=mh3:.claude >/dev/null 2>&1; second_merge_rc=$?
merged_hosts=$(cut -f1,2,3,5 "$W_MERGE/hosts.tsv" 2>/dev/null | tr '\n' '|')
earlier_rows_kept=no; [[ -n "$merge_rows_before" && "$(head -n 2 "$W_MERGE/hosts.tsv")" == "$merge_rows_before" ]] \
    && earlier_rows_kept=yes
merge_leftovers=$(find "$W_MERGE" -maxdepth 1 -name '.collecting-*' -print)
check "merge: h3 failed then re-collected alone; h1 and h2 rows kept as they were, h3 now ok, no temp file left" \
    "$first_merge_rc $second_merge_rc $earlier_rows_kept|$merged_hosts|$merge_leftovers" \
    "2 0 yes|h1${TAB}mh1${TAB}.claude${TAB}ok|h2${TAB}mh2${TAB}.claude${TAB}ok|h3${TAB}mh3${TAB}.claude${TAB}ok||"

printf 'matrix: each Markdown section names its count of rows not identical, and lists them first\n'
markdown_section_shape() {   # FILE HEADING_PREFIX → one letter per table row of that section: D not identical, I identical
    awk -F'|' -v heading_prefix="$2" '
        index($0, "## ") == 1 { in_section = (index($0, heading_prefix) == 1); next }
        in_section && index($0, "| `") == 1 { row_status = $3; gsub(/ /, "", row_status); printf "%s", (row_status == "identical" ? "I" : "D") }
    ' "$1" 2>/dev/null
}
cfg_heading=$(has_line "$W_MATRIX/matrix.md" '## cfg/ (6 of 12 not identical)')
cfg_shape=$(markdown_section_shape "$W_MATRIX/matrix.md" '## cfg/ (')
store_heading=$(has_line "$W_MATRIX/memory-matrix.md" "## $MATRIX_STORE (6 of 7 not identical)")
store_shape=$(markdown_section_shape "$W_MATRIX/memory-matrix.md" "## $MATRIX_STORE (")
check "sections: cfg/ 6 of 12 and quantivly-hub 6 of 7 in their headings, rows not identical first" \
    "$cfg_heading $cfg_shape|$store_heading $store_shape" "yes DDDDDDIIIIII|yes DDDDDDI"

printf '\n'
EXPECTED_ROWS=51
if (( PASS + FAIL != EXPECTED_ROWS )); then
    fatal "expected $EXPECTED_ROWS rows, $((PASS + FAIL)) ran — a check vanished or was added without updating EXPECTED_ROWS"
fi
if (( FAIL )); then printf '\033[1;31m%d of %d failed\033[0m\n' "$FAIL" "$((PASS + FAIL))"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$PASS"
