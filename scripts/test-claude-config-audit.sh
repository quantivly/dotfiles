#!/usr/bin/env bash
#
# scripts/test-claude-config-audit.sh
# ===================================
#
# State table for scripts/claude-config-audit.sh: collecting every agent host's
# Claude Code configuration into one workspace, and reporting where hosts agree.
#
# HERMETIC. Every row runs against a workspace under mktemp -d. Nothing here
# reaches a real host: ssh is replaced through CLAUDE_CONFIG_AUDIT_SSH where a row
# needs it, and the argument-validation rows below stop before any ssh happens.
# Requires: bash, jq, tar, sha256sum.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$DOTFILES/scripts/claude-config-audit.sh"
TMPROOT="$(mktemp -d)"
# Some fixtures hold read-only (555) directories, which rm -rf alone cannot empty.
trap 'find "$TMPROOT" -type d -exec chmod u+rwx {} + 2>/dev/null; rm -rf "$TMPROOT"' EXIT

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
# Stub ssh: skip `-o VALUE` pairs, take the next argument as the alias and the rest as the
# remote command, run it under the alias's fixture HOME with stdin passed through.
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
export AUDIT_FIXTURE_HOSTS="$FIXTURE_HOSTS" AUDIT_REMOTE_TMPDIR="$REMOTE_TMPDIR"
export CLAUDE_CONFIG_AUDIT_SSH="$STUB_BIN/ssh"

# Built at runtime so the repo's gitleaks hook never sees a credential-shaped literal.
FIXTURE_LINEAR_KEY="lin_api_""FIXTUREVALUE0123456789abcdefXYZ"
FIXTURE_NAMED_SECRET="fixture-named-""secret-value"
FIXTURE_CREDENTIAL='FIXTURE-CRED'
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
    # the workspace: one path per prune, each holding the credential literal.
    local repo_claude="$host_home/quantivly/hub/.claude" excluded_path
    for excluded_path in "$cfg/skills/rabota/.credentials.json" "$cfg/skills/rabota/.claude.json.backup" \
            "$repo_claude/.credentials.json" "$repo_claude/.claude.json.backup" "$repo_claude/old.jsonl" \
            "$repo_claude/sessions/s" "$repo_claude/shell-snapshots/s" "$repo_claude/file-history/f" \
            "$repo_claude/paste-cache/p" "$repo_claude/debug/d" "$repo_claude/cache/x" \
            "$repo_claude/backups/b" "$repo_claude/downloads/d" "$repo_claude/telemetry/t" \
            "$repo_claude/security/s" "$repo_claude/hook.signature" "$repo_claude/plugins/cache/c" \
            "$repo_claude/plugins/marketplaces/m" "$repo_claude/plugins/repos/r" \
            "$repo_claude/plugins/data/d" "$repo_claude/plugins/store/s" "$repo_claude/plugins/synced/s" \
            "$repo_claude/skills/synced/SKILL.md" "$repo_claude/worktrees/w/CLAUDE.md"; do
        mkdir -p "$(dirname "$excluded_path")"
        printf '%s\n' "$FIXTURE_CREDENTIAL" > "$excluded_path"
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

printf 'collect: credentials, .claude.json, transcripts, sessions, plugin cache and synced skills are never copied\n'
h1_collected=no; [[ -f $W/h1/facts.tsv ]] && h1_collected=yes
credential_files=$(grep -rlF -- "$FIXTURE_CREDENTIAL" "$W" 2>/dev/null)
excluded_entries=$(find "$W/h1" \( -name '*.jsonl' -o -name sessions -o -path '*/plugins/cache' \
    -o -path '*/skills/synced' \) -print 2>/dev/null)
check "excluded: nothing credential, transcript or cache-shaped collected" \
    "$h1_collected|$credential_files|$excluded_entries" "yes||"

printf 'collect: a credential-shaped string in a collected file is redacted\n'
redacted_count=$(grep -c REDACTED "$W/h1/cfg/CLAUDE.md" 2>/dev/null)
literal_present=no
for fixture_secret in "$FIXTURE_LINEAR_KEY" "$FIXTURE_NAMED_SECRET"; do
    grep -qF -- "$fixture_secret" "$W/h1/cfg/CLAUDE.md" 2>/dev/null && literal_present=yes
done
check "redacted: by shape and by name after an invalid byte, in a UTF-8 locale" \
    "$redacted_count $literal_present" "2 no"

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
check "no agents/, no ~/toysim: exit 0, both logged absent" "$rc $agents_absent $toysim_absent" "0 yes yes"

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
"$SUT" --collect --workspace "$W_RERUN" --host rerun=rerun:.claude >/dev/null 2>&1
rm "$FIXTURE_HOSTS/rerun/.claude/agents/x.md"
"$SUT" --collect --workspace "$W_RERUN" --host rerun=rerun:.claude >/dev/null 2>&1; rerun_rc=$?
stale_agent=absent; [[ -e $W_RERUN/rerun/cfg/agents/x.md ]] && stale_agent=present
rerun_rows=$(wc -l 2>/dev/null < "$W_RERUN/hosts.tsv")
"$SUT" --collect --workspace "$W_RERUN" --host rerun=down:.claude >/dev/null 2>&1; failed_rc=$?
earlier_tree_kept=no
[[ -f $W_RERUN/rerun/facts.tsv && -f $W_RERUN/rerun/cfg/CLAUDE.md ]] && earlier_tree_kept=yes
failed_status=$(cut -f1,2,5 "$W_RERUN/hosts.tsv" 2>/dev/null | tr '\n' '|')
check "re-collect: stale file gone, one hosts.tsv row; a failed one keeps the earlier tree, hosts.tsv says failed" \
    "$rerun_rc $stale_agent $rerun_rows $failed_rc $earlier_tree_kept $failed_status" \
    "0 absent 1 2 yes rerun${TAB}down${TAB}failed|"

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
"$SUT" --collect --workspace "$W_READONLY" --host rotree=rotree:.claude --host rodir=rodir:.claude \
    >/dev/null 2>&1; rc=$?
staging_left=$(find "$W_READONLY" -name '.collecting-*' -print)
unredacted_left=$(grep -rlF -- "$FIXTURE_LINEAR_KEY" "$W_READONLY" 2>/dev/null)
binaries_left=$(find "$W_READONLY" -name blob.bin -print)
both_collected=no; [[ -f $W_READONLY/rotree/cfg/hooks/locked/text.sh && -f $W_READONLY/rodir/cfg/locked/text.sh ]] \
    && both_collected=yes
check "read-only dirs: both hosts collected; no staging dir, unredacted literal or binary left" \
    "$rc $both_collected|$staging_left|$unredacted_left|$binaries_left" "0 yes|||"

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

printf 'collect: the host tree is unchanged\n'
H1_TREE_AFTER=$(host_tree_listing "$H1")
tree_listing_size=$(wc -l <<<"$H1_TREE_BEFORE")
tree_unchanged=no; [[ "$H1_TREE_BEFORE" == "$H1_TREE_AFTER" ]] && tree_unchanged=yes
# The listing must cover the fixture (>20 entries), or "unchanged" compares two empty strings.
listing_covers_fixture=no; (( tree_listing_size > 20 )) && listing_covers_fixture=yes
remote_tmp_leftovers=$(find "$REMOTE_TMPDIR" -mindepth 1 -print)
check "read-only: h1's tree identical after every collect above, remote temp dir removed" \
    "$tree_unchanged $listing_covers_fixture|$remote_tmp_leftovers" "yes yes|"

printf '\n'
EXPECTED_ROWS=20
if (( PASS + FAIL != EXPECTED_ROWS )); then
    fatal "expected $EXPECTED_ROWS rows, $((PASS + FAIL)) ran — a check vanished or was added without updating EXPECTED_ROWS"
fi
if (( FAIL )); then printf '\033[1;31m%d of %d failed\033[0m\n' "$FAIL" "$((PASS + FAIL))"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$PASS"
