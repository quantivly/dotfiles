#!/usr/bin/env bash
#
# scripts/test-dev-sync.sh
# ========================
#
# State table for scripts/dev-sync: keeping dev's tooling level with the laptop's.
#
# dev is shared with the team's platform stack, so the rows are about two
# questions. Does --check report exactly the drift there is, and change nothing?
# Does --apply fix only what it reported, and refuse rather than guess at
# anything a person must decide: a checkout off main, local edits, a linked
# plugin, a foreign directory, a sign-in, sudo? A second --apply on a level
# machine must change nothing, which is the "no-op" the plan's B1 promises.
#
# HERMETIC. Every case builds a fresh fake $HOME that is LEVEL, then breaks one
# thing. claude, herdr, mise and systemctl are stubs in $HOME/.local/bin (which
# dev-sync puts first on PATH itself), each recording its calls. git is real,
# against bare repos served over file://. The npm registry is a file:// JSON. No
# network, no real ~/.claude, nothing outside mktemp -d.
# Requires: bash, zsh, git, jq, curl, flock.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$DOTFILES/scripts/dev-sync"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
has()   { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 — '$3' not in: ${2:0:600}"; fi; }
hasnt() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 — '$3' unexpectedly in: ${2:0:600}"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

for tool in bash zsh git jq curl flock; do command -v "$tool" >/dev/null || fatal "$tool is required"; done
[[ -x "$SUT" ]] || fatal "$SUT is not executable — every row below would assert nothing"
if git -C "$TMPROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
    fatal "$TMPROOT is inside a git repository; the fixture repos would resolve against it"
fi

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

V_LAPTOP="2.1.296"
HV="0.9.1"            # the laptop's herdr
ARCH="$(uname -m)"
FAKE_KEY="lin_api_FIXTUREVALUE0123456789abcdefXYZ"
MUTATING='claude install|claude plugin (marketplace add|marketplace update|install|enable|disable|update)|herdr plugin install|systemctl --user enable|systemctl --user restart|daemon-reload|^sudo '

# ---------------------------------------------------------------------------------------------
# Stubs. Each logs "<tool> <args>" to $HOME/stub/calls.
# ---------------------------------------------------------------------------------------------

write_stubs() {   # $1 = HOME
    local b="$1/.local/bin"; mkdir -p "$b" "$1/stub/go/bin"
    cat >"$b/claude" <<'STUB'
#!/usr/bin/env bash
S="$HOME/stub"; echo "claude $*" >>"$S/calls"
P="$HOME/.claude/plugins"; SET="$HOME/.claude/settings.json"; IP="$P/installed_plugins.json"; KM="$P/known_marketplaces.json"
jqi() { local f=$1; shift; jq "$@" "$f" >"$f.tmp" && mv "$f.tmp" "$f"; }
case "$1" in
    --version) echo "$(cat "$S/claude-version") (Claude Code)" ;;
    install) [[ -e "$S/claude-install-fails" ]] && exit 1; echo "$2" >"$S/claude-version" ;;
    mcp) cat "$S/mcp-list" 2>/dev/null ;;
    plugin)
        shift
        case "$1 $2" in
            "marketplace add")
                jqi "$KM" --arg l "$3" '.dotfiles={source:{source:"directory",path:$l},installLocation:$l,lastUpdated:(now|todate)}' ;;
            "marketplace update")
                [[ -e "$S/market-update-fails" ]] && exit 1
                jqi "$KM" --arg n "$3" '.[$n].lastUpdated=(now|todate)'
                if [[ -e "$S/market-$3.json" ]]; then
                    cp "$S/market-$3.json" "$(jq -r --arg n "$3" '.[$n].installLocation' "$KM")/.claude-plugin/marketplace.json"
                fi ;;
            install*)
                [[ -e "$S/install-fails-$2" ]] && exit 1
                jqi "$IP" --arg p "$2" '.plugins[$p]=[{scope:"user",version:"1.0.0"}]'
                jqi "$SET" --arg p "$2" '.enabledPlugins[$p]=true' ;;
            enable*) jqi "$SET" --arg p "$2" '.enabledPlugins[$p]=true' ;;
            disable*) jqi "$SET" --arg p "$2" '.enabledPlugins[$p]=false' ;;
            update*)
                v="$(jq -r .version "$HOME/.dotfiles/claude/plugins/linear-key/.claude-plugin/plugin.json")"
                jqi "$IP" --arg p "$2" --arg v "$v" '(.plugins[$p][] | select(.scope == "user") | .version) = $v' ;;
        esac ;;
esac
STUB
    cat >"$b/herdr" <<'STUB'
#!/usr/bin/env bash
S="$HOME/stub"; echo "herdr $*" >>"$S/calls"
V="${V:-$(cat "$S/herdr-version")}"   # a release "asset" built from this stub pins V on line 2
case "$1 ${2:-}" in
    "--version "*) echo "herdr $V" ;;
    "--skill "*) [[ -e "$S/skill-empty" ]] || echo "skill for $V" ;;
    "status server") printf 'status: running\nversion: %s\n' "$(cat "$S/server-version")" ;;
    "agent list") printf '{"result":{"agents":[%s]}}\n' "$(cat "$S/agents" 2>/dev/null)" ;;
    "pane list") printf '{"result":{"panes":[%s]}}\n' "$(cat "$S/panes" 2>/dev/null)" ;;
    "plugin list") [[ -e "$S/draft-down" ]] && exit 1; cat "$S/draft.json" ;;
    "plugin install")
        echo "$PATH" >"$S/herdr-install-path"
        command -v go >/dev/null || exit 1
        [[ -e "$S/draft-install-fails" ]] && exit 1
        printf '{"result":{"plugins":[{"source":{"kind":"github","resolved_commit":"%s","requested_ref":"%s"}}]}}\n' "$5" "$5" >"$S/draft.json" ;;
esac
STUB
    cat >"$b/mise" <<'STUB'
#!/usr/bin/env bash
echo "mise $*" >>"$HOME/stub/calls"
[[ "$1 $2" == "which go" ]] && echo "$HOME/stub/go/bin/go"
STUB
    printf '#!/bin/sh\nexit 0\n' >"$1/stub/go/bin/go"
    cat >"$b/systemctl" <<'STUB'
#!/usr/bin/env bash
S="$HOME/stub"; echo "systemctl $*" >>"$S/calls"
[[ "$1" == --user ]] && shift
case "$1" in
    is-enabled) cat "$S/timer-enabled" 2>/dev/null || { echo disabled; exit 1; } ;;
    is-active) cat "$S/timer-active" 2>/dev/null || { echo inactive; exit 3; } ;;
    daemon-reload) ;;
    restart) [[ -e "$S/restart-fails" ]] && exit 1; "$HOME/.local/bin/herdr" --version | awk '{print $2}' >"$S/server-version" ;;
    enable) [[ -e "$S/enable-fails" ]] && exit 1; echo enabled >"$S/timer-enabled"; echo active >"$S/timer-active" ;;
    list-units) cat "$S/units" 2>/dev/null ;;
    show)
        case "$2:$4" in
            agents.slice:FragmentPath) [[ -e "$S/no-slice" ]] || echo "$HOME/.config/systemd/user/agents.slice" ;;
            agents.slice:MemoryHigh) echo 12884901888 ;;
            agents.slice:MemoryMax) echo 17179869184 ;;
            agents.slice:DropInPaths) echo "/x/50-MemoryHigh.conf /x/50-MemoryMax.conf" ;;
            dev-sync.timer:*) echo "Wed 2026-10-14 05:12:00 EDT" ;;
            session-*:MemoryCurrent) cat "$S/mem-$2" 2>/dev/null ;;
            session-*:Slice) cat "$S/slice-$2" 2>/dev/null || echo "user-$(id -u).slice" ;;
        esac ;;
esac
STUB
    # dev-sync must never run sudo; a logging stub makes a call visible to the rows.
    # shellcheck disable=SC2016  # expanded by the stub, deliberately
    printf '#!/bin/sh\necho "sudo $*" >>"$HOME/stub/calls"\nexit 1\n' >"$b/sudo"
    chmod +x "$b"/* "$1/stub/go/bin/go"
}

# ---------------------------------------------------------------------------------------------
# A LEVEL dev, per case: C = case dir, H = its $HOME, GH = its fake GitHub.
# ---------------------------------------------------------------------------------------------

bare() {   # $1 = owner/repo -> a bare repo with one commit, under $GH
    local b="$GH/$1.git" w="$C/seed-${1//\//-}"
    git init -q -b main "$w"; echo "$1" >"$w/README"
    git -C "$w" add -A; git -C "$w" commit -q -m init
    git clone -q --bare "$w" "$b"; rm -rf "$w"
}

new_case() {
    CASE=$((CASE + 1)); C="$TMPROOT/c$CASE"; H="$C/home"; GH="$C/gh"
    mkdir -p "$H/stub" "$GH" "$H/.claude/plugins/marketplaces" "$H/.config/systemd/user" "$H/.config/dev-sync" "$H/quantivly"
    write_stubs "$H"
    echo "$V_LAPTOP" >"$H/stub/claude-version"; echo "$HV" >"$H/stub/herdr-version"; echo "$HV" >"$H/stub/server-version"
    # herdr's "release": the stub with its version pinned, served over file://
    mkdir -p "$C/releases/v$HV"; sed "2i V=$HV" "$H/.local/bin/herdr" >"$C/releases/v$HV/herdr-linux-$ARCH"
    HSHA="$(sha256sum "$C/releases/v$HV/herdr-linux-$ARCH" | cut -c1-64)"
    mkdir -p "$H/.claude/skills/herdr"; echo old >"$H/.claude/skills/herdr/SKILL.md"
    : >"$H/stub/calls"

    # dotfiles: origin with an install script and the linear-key plugin; dev at origin/main.
    local w="$C/seed-dotfiles"
    git init -q -b main "$w"
    mkdir -p "$w/claude/plugins/linear-key/.claude-plugin" "$w/claude/plugins/.claude-plugin"
    # shellcheck disable=SC2016  # expanded by the inner shell, deliberately
    printf '#!/usr/bin/env bash\n[[ -e "$HOME/stub/install-fails" ]] && exit 1\necho ran >>"$HOME/stub/install-ran"\n' >"$w/install"
    echo '{"name":"linear-key","version":"1.0.0"}' >"$w/claude/plugins/linear-key/.claude-plugin/plugin.json"
    echo '{"name":"dotfiles","plugins":[{"name":"linear-key"}]}' >"$w/claude/plugins/.claude-plugin/marketplace.json"
    echo one >"$w/a.txt"
    git -C "$w" add -A; git -C "$w" commit -q -m init
    mkdir -p "$GH/quantivly"; git clone -q --bare "$w" "$GH/quantivly/dotfiles.git"; rm -rf "$w"
    git clone -q "$GH/quantivly/dotfiles.git" "$H/.dotfiles"
    mkdir -p "$H/.local/state/dev-sync"
    git -C "$H/.dotfiles" rev-parse HEAD >"$H/.local/state/dev-sync/installed-head"

    # timer armed
    : >"$H/.config/dev-sync/armed"; : >"$H/.config/systemd/user/dev-sync.timer"
    echo enabled >"$H/stub/timer-enabled"; echo active >"$H/stub/timer-active"

    # herdr-draft at the target commit
    bare ZviBaratz/herdr-draft
    DRAFT="$(git --git-dir="$GH/ZviBaratz/herdr-draft.git" rev-parse HEAD)"
    printf '{"result":{"plugins":[{"source":{"kind":"github","resolved_commit":"%s","requested_ref":"%s"}}]}}\n' \
        "$DRAFT" "$DRAFT" >"$H/stub/draft.json"

    # marketplaces, fresh, listing what is wanted; plugins installed and enabled
    local m
    for m in claude-plugins-official quantivly; do mkdir -p "$H/.claude/plugins/marketplaces/$m/.claude-plugin"; done
    echo '{"plugins":[{"name":"slack"},{"name":"notion"},{"name":"linear"}]}' \
        >"$H/.claude/plugins/marketplaces/claude-plugins-official/.claude-plugin/marketplace.json"
    echo '{"plugins":[{"name":"quantivly-conventions"}]}' \
        >"$H/.claude/plugins/marketplaces/quantivly/.claude-plugin/marketplace.json"
    jq -n --arg h "$H" '{
        "claude-plugins-official": {installLocation: ($h + "/.claude/plugins/marketplaces/claude-plugins-official"), lastUpdated: (now|todate)},
        "quantivly": {installLocation: ($h + "/.claude/plugins/marketplaces/quantivly"), lastUpdated: (now|todate)},
        "dotfiles": {installLocation: ($h + "/.dotfiles/claude/plugins"), lastUpdated: "2020-01-01T00:00:00Z"}
    }' >"$H/.claude/plugins/known_marketplaces.json"
    jq -n '{plugins: {
        "quantivly-conventions@quantivly": [{scope: "user", version: "1"}],
        "slack@claude-plugins-official": [{scope: "user", version: "1"}],
        "notion@claude-plugins-official": [{scope: "user", version: "1"}],
        "linear-key@dotfiles": [{scope: "user", version: "1.0.0"}],
        "linear@claude-plugins-official": [{scope: "user", version: "1"}]}}' >"$H/.claude/plugins/installed_plugins.json"
    jq -n '{theme: "dark", enabledPlugins: {
        "quantivly-conventions@quantivly": true, "slack@claude-plugins-official": true,
        "notion@claude-plugins-official": true, "linear-key@dotfiles": true,
        "linear@claude-plugins-official": false}}' >"$H/.claude/settings.json"
    printf 'plugin:slack:slack: https://x (HTTP) - ✔ Connected\nplugin:Notion:notion: https://y (HTTP) - ✔ Connected\n' >"$H/stub/mcp-list"
    printf 'export LINEAR_API_KEY=%s\n' "$FAKE_KEY" >"$H/.zshrc.local"

    # one fresh clone; a worktree of it, which must be ignored
    bare quantivly/alpha
    git clone -q "$GH/quantivly/alpha.git" "$H/quantivly/alpha"
    git -C "$H/quantivly/alpha" fetch -q origin
    git -C "$H/quantivly/alpha" worktree add -q "$H/quantivly/alpha-wt" -b wt 2>/dev/null
    bare quantivly/beta   # exists on "GitHub", not on dev
}

# Facts a laptop run would send for a level dev.
facts() { printf '%s\n' --claude-version "$V_LAPTOP" --herdr-version "$HV" --herdr-arch "$ARCH" --herdr-sha256 "$HSHA" \
    --dotfiles-sha "$(git --git-dir="$GH/quantivly/dotfiles.git" rev-parse main)" --clone alpha=quantivly/alpha; }

# OUT / RC as globals, never inside $( ): an exit code assigned in a subshell dies with it.
run() {   # $@ = dev-sync args after --here
    OUT="$(env -u LINEAR_API_KEY HOME="$H" DEV_SYNC_GITHUB_BASE="file://$GH" DEV_SYNC_NPM_URL="file://$C/npm.json" \
        DEV_SYNC_HERDR_RELEASES="file://$C/releases" \
        PATH="/usr/local/bin:/usr/bin:/bin" bash "$SUT" --here "$@" 2>&1)"
    RC=$?
}
run_level() { local m="$1"; shift; mapfile -t F < <(facts); run "$m" "${F[@]}" "$@"; }
calls() { cat "$H/stub/calls"; }
mutations() { grep -cE "$MUTATING" "$H/stub/calls"; }
reset_calls() { : >"$H/stub/calls"; }
head_of() { git -C "$1" rev-parse HEAD; }
push_origin() {   # add a commit to dotfiles' origin: $1 = file, $2 = content
    local w="$C/push"; rm -rf "$w"; git clone -q "$GH/quantivly/dotfiles.git" "$w"
    echo "$2" >"$w/$1"; git -C "$w" add -A; git -C "$w" commit -q -m "$1"; git -C "$w" push -q origin main
}

CASE=0

echo "== a level dev"
new_case
run_level --check
check "level --check exits 0" "$RC" 0
has   "level --check says Level." "$OUT" "Level."
hasnt "level --check has no ✗ row" "$OUT" "✗"
check "level --check calls nothing mutating" "$(mutations)" 0
hasnt "--check takes no lock" "$(ls "$H/.local/state/dev-sync")" "lock"
hasnt "the LINEAR_API_KEY value is never printed" "$OUT" "$FAKE_KEY"
has   "the key is reported present, by name" "$OUT" "LINEAR_API_KEY is set"
has   "the slice row reads the effective cap" "$OUT" "MemoryHigh=12.0G MemoryMax=16.0G (2 drop-in(s))"
hasnt "a worktree under ~/quantivly is not counted as a clone" "$OUT" "2 clones"
reset_calls
run_level --apply
check "--apply on a level dev exits 0" "$RC" 0
check "--apply on a level dev calls nothing mutating" "$(mutations)" 0
check "--apply on a level dev does not re-run ./install" "$([[ -e "$H/stub/install-ran" ]] && echo ran || echo no)" no

echo "== --check writes nothing"
# Every kind of drift at once, so every step's apply path is one gate away. The stub log is the
# only file allowed to change: git, curl, mkdir and jq rewrites are invisible to $MUTATING.
new_case
push_origin b.txt two
echo 2.1.272 >"$H/stub/claude-version"; echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"
printf '{"result":{"plugins":[{"source":{"kind":"github","resolved_commit":"%s"}}]}}\n' "$(printf 'a%.0s' {1..40})" >"$H/stub/draft.json"
jq '.["quantivly"].lastUpdated = "2026-01-01T00:00:00Z" | del(.dotfiles)' "$H/.claude/plugins/known_marketplaces.json" >"$C/k" &&
    mv "$C/k" "$H/.claude/plugins/known_marketplaces.json"
jq '.enabledPlugins["quantivly-pr-conventions@quantivly"] = true | .enabledPlugins["linear@claude-plugins-official"] = true' \
    "$H/.claude/settings.json" >"$C/s" && mv "$C/s" "$H/.claude/settings.json"
rm -rf "$H/.local/state/dev-sync" "$H/.config/dev-sync/armed"; touch -d '3 days ago' "$H/quantivly/alpha/.git/FETCH_HEAD"
snapshot() { find "$H" -path "$H/stub" -prune -o -printf '%p %s %m %T@\n' | sort; }
before="$(snapshot)"
run_level --check --clone beta=quantivly/beta
check "a fully drifted --check exits 1" "$RC" 1
check "--check changes no file, directory or mode under \$HOME" "$(diff <(echo "$before") <(snapshot) | head -n 5)" ""

echo "== dotfiles"
new_case
before="$(head_of "$H/.dotfiles")"; push_origin b.txt two
run_level --check
check "behind: --check exits 1" "$RC" 1
has   "behind: --check does not fetch, so without the laptop's count it says ?" "$OUT" "? commits behind origin/main"
check "behind: --check does not move HEAD" "$(head_of "$H/.dotfiles")" "$before"
run_level --apply
check "behind: --apply exits 0" "$RC" 0
check "behind: --apply fast-forwards to origin/main" "$(head_of "$H/.dotfiles")" "$(git --git-dir="$GH/quantivly/dotfiles.git" rev-parse main)"
check "behind: --apply runs ./install exactly once" "$(wc -l <"$H/stub/install-ran")" 1
check "behind: the stamp records the new HEAD" "$(cat "$H/.local/state/dev-sync/installed-head")" "$(head_of "$H/.dotfiles")"
run_level --apply
check "second --apply does not re-run ./install" "$(wc -l <"$H/stub/install-ran")" 1
hasnt "second --apply has no ✗ row" "$OUT" "✗"

new_case
run --check --dotfiles-sha "$(printf 'f%.0s' {1..40})" --dotfiles-behind 73
has   "a target dev has not fetched shows the laptop's count" "$OUT" "73 commits behind origin/main"

new_case
push_origin a.txt upstream; echo local >"$H/.dotfiles/a.txt"; before="$(head_of "$H/.dotfiles")"
run_level --apply
has   "local edits to a file origin changes: ⚠, named" "$OUT" "local edits to a.txt"
check "local edits: HEAD is not moved" "$(head_of "$H/.dotfiles")" "$before"
check "local edits: the edit survives" "$(cat "$H/.dotfiles/a.txt")" local

new_case
push_origin b.txt upstream; echo local >"$H/.dotfiles/a.txt"
run_level --apply
check "an unrelated local edit does not block the fast-forward" "$(head_of "$H/.dotfiles")" "$(git --git-dir="$GH/quantivly/dotfiles.git" rev-parse main)"

new_case
git -C "$H/.dotfiles" checkout -q -b feature; before="$(head_of "$H/.dotfiles")"; push_origin b.txt x
run_level --apply
has   "off main: ⚠ and not moved" "$OUT" "on 'feature', not main"
check "off main: still on the branch" "$(git -C "$H/.dotfiles" symbolic-ref --short HEAD)" feature

new_case
echo extra >"$H/.dotfiles/c.txt"; git -C "$H/.dotfiles" add c.txt; git -C "$H/.dotfiles" commit -q -m local
run_level --apply
has   "unpushed commits on dev: ⚠ AHEAD, not touched" "$OUT" "is AHEAD of origin/main"

new_case
rm "$H/.local/state/dev-sync/installed-head"; touch "$H/stub/install-fails"
run_level --apply
check "./install failing: exit 1" "$RC" 1
has   "./install failing: ✗ names the log" "$OUT" "./install failed"
check "./install failing: no stamp is written" "$([[ -e "$H/.local/state/dev-sync/installed-head" ]] && echo yes || echo no)" no

echo "== claude"
new_case
echo 2.1.272 >"$H/stub/claude-version"
run_level --check
has   "older claude: ✗ with both versions" "$OUT" "2.1.272, laptop has $V_LAPTOP"
run_level --apply
has   "older claude: --apply installs the laptop's exact version" "$(calls)" "claude install $V_LAPTOP"
check "older claude: now at the laptop's version" "$(cat "$H/stub/claude-version")" "$V_LAPTOP"
new_case
echo 2.1.300 >"$H/stub/claude-version"
run_level --apply
has   "newer claude: ✓ ahead" "$OUT" "ahead of laptop $V_LAPTOP (never downgraded)"
hasnt "newer claude: never downgraded" "$(calls)" "claude install"
new_case
echo '{"version":"2.1.400"}' >"$C/npm.json"
mapfile -t F < <(facts | grep -v -e --claude-version -e "^$V_LAPTOP\$")
run --check "${F[@]}"
has   "no laptop facts: targets the registry's latest" "$OUT" "$V_LAPTOP, latest has 2.1.400"
new_case
mapfile -t F < <(facts | grep -v -e --claude-version -e "^$V_LAPTOP\$")
run --check "${F[@]}"
has   "an unreachable registry is ✗, not a silent ✓" "$OUT" "could not determine the latest version"

echo "== herdr-draft"
new_case
printf '{"result":{"plugins":[{"source":{"kind":"github","resolved_commit":"%s","requested_ref":"v0.1.0"}}]}}\n' \
    "$(printf 'a%.0s' {1..40})" >"$H/stub/draft.json"
run_level --check
has   "stale herdr-draft: ✗ names the ref, against main" "$OUT" "(ref v0.1.0), main at"
run_level --apply
has   "stale herdr-draft: installs with the FULL sha and --yes" "$(calls)" "herdr plugin install ZviBaratz/herdr-draft --ref $DRAFT --yes"
has   "stale herdr-draft: the build sees mise's Go on PATH" "$(cat "$H/stub/herdr-install-path")" "$H/stub/go/bin"
has   "stale herdr-draft: ✓ after" "$OUT" "→ ${DRAFT:0:7}"
new_case
echo '{"result":{"plugins":[{"source":{"kind":"local"}}]}}' >"$H/stub/draft.json"
run_level --apply
has   "linked herdr-draft: ⚠" "$OUT" "linked from a local checkout"
hasnt "linked herdr-draft: never replaced" "$(calls)" "herdr plugin install"
new_case
touch "$H/stub/draft-down"
run_level --check
has   "herdr server down: ⚠, not ✓" "$OUT" "did not answer"

echo "== herdr itself"
new_case
echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"
run_level --check
has   "older herdr: ✗ with both versions" "$OUT" "0.9.0, laptop has $HV (server 0.9.0)"
hasnt "older herdr: --check restarts nothing" "$(calls)" "systemctl --user restart"
check "older herdr: --check leaves the binary" "$(HOME="$H" "$H/.local/bin/herdr" --version)" "herdr 0.9.0"
run_level --apply
check "older herdr: --apply installs the laptop's exact version" "$(HOME="$H" "$H/.local/bin/herdr" --version)" "herdr $HV"
has   "older herdr, no panes: the server is restarted through the unit" "$(calls)" "systemctl --user restart herdr-server.service"
has   "older herdr, no panes: ✓ restarted" "$OUT" "server restarted on $HV (no panes were open)"
check "older herdr: the agent skill is regenerated" "$(cat "$H/.claude/skills/herdr/SKILL.md")" "skill for $HV"
check "older herdr: the previous binary is kept" "$([[ -e "$H/.local/state/dev-sync/herdr-0.9.0" ]] && echo yes || echo no)" yes
reset_calls; run_level --apply
check "second --apply after a herdr upgrade calls nothing mutating" "$(mutations)" 0
new_case
echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"; echo '{"pane_id":"w1:p1"}' >"$H/stub/panes"
run_level --apply
check "a pane open but NO agent: the binary is not swapped" "$(HOME="$H" "$H/.local/bin/herdr" --version)" "herdr 0.9.0"
hasnt "a pane open but no agent: the server is NOT restarted" "$(calls)" "systemctl --user restart"
has   "a pane open: ⚠ says the upgrade waits, and why" "$OUT" "0.9.0 → $HV waits: 1 pane(s) open on dev's herdr (0 agent(s))"
check "a pane open: the upgrade waiting is a person's step, not a failure" "$RC" 0
new_case
echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"
mv "$H/.local/bin/herdr" "$C/herdr-bin"; ln -s "$C/herdr-bin" "$H/.local/bin/herdr"
run_level --apply
has   "herdr is a symlink: ⚠, never replaced" "$OUT" "is a symlink; dev-sync does not replace a link"
check "herdr is a symlink: still a symlink" "$([[ -L "$H/.local/bin/herdr" ]] && echo link || echo file)" link
new_case
echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"; touch "$H/stub/skill-empty"
run_level --apply
check "an empty --skill output never replaces the agent skill" "$(cat "$H/.claude/skills/herdr/SKILL.md")" old
new_case
echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"
: >"$H/.local/state/dev-sync/lock"; chmod 555 "$H/.local/state/dev-sync"   # the backup copy cannot be written
run_level --apply
chmod 755 "$H/.local/state/dev-sync"
has   "no backup of the old binary: ✗, not installed" "$OUT" "could not keep a copy of the 0.9.0 binary; not installed"
check "no backup of the old binary: still the old binary" "$(HOME="$H" "$H/.local/bin/herdr" --version)" "herdr 0.9.0"
new_case
echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"; touch "$H/stub/restart-fails"
run_level --apply
has   "server not back after the restart: ✗ prints the rollback" "$OUT" "to roll back: mv ~/.local/state/dev-sync/herdr-0.9.0 ~/.local/bin/herdr"
check "server not back: exit 1" "$RC" 1
new_case
echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"
echo tampered >>"$C/releases/v$HV/herdr-linux-$ARCH"
run_level --apply
has   "an asset that does not match the laptop's hash: ✗" "$OUT" "does not match the laptop's binary"
check "an asset that does not match: not installed" "$(HOME="$H" "$H/.local/bin/herdr" --version)" "herdr 0.9.0"
new_case
echo 0.9.0 >"$H/stub/herdr-version"
mapfile -t F < <(facts); F=("${F[@]/#$ARCH/other_arch}")
run --apply "${F[@]}"
has   "laptop on another architecture: ⚠, never an unverified binary" "$OUT" "cannot vouch for a $ARCH asset"
new_case
echo 0.9.4 >"$H/stub/herdr-version"; echo 0.9.4 >"$H/stub/server-version"
run_level --apply
has   "newer herdr on dev: never downgraded" "$OUT" "0.9.4, ahead of laptop $HV"
new_case
echo 0.9.0 >"$H/stub/server-version"
run_level --check
has   "binary current, server old: ✗ restart pending" "$OUT" "server runs 0.9.0, binary $HV: restart pending"
echo '{"pane_id":"w1:p1"}' >"$H/stub/panes"; run_level --apply
hasnt "binary current, server old, a pane open: no restart" "$(calls)" "systemctl --user restart"
new_case
echo 0.9.0 >"$H/stub/herdr-version"
mapfile -t F < <(facts | grep -v -e '^--herdr' -e "^$HV\$" -e "^$ARCH\$" -e "^$HSHA\$")
run --apply "${F[@]}"
has   "no laptop facts (the timer): herdr is only reported" "$OUT" "version parity is laptop-driven"
hasnt "no laptop facts: no restart" "$(calls)" "systemctl --user restart"

echo "== plugins"
new_case
jq '.["quantivly"].lastUpdated = "2026-01-01T00:00:00Z"' "$H/.claude/plugins/known_marketplaces.json" >"$C/k" &&
    mv "$C/k" "$H/.claude/plugins/known_marketplaces.json"
run_level --check
has   "stale marketplace: ✗ with its age" "$OUT" "quantivly: last updated"
run_level --apply
has   "stale marketplace: --apply updates it" "$(calls)" "claude plugin marketplace update quantivly"
has   "stale marketplace: ✓ once the update has moved it" "$OUT" "✓ marketplace    quantivly (was: last updated"
new_case
jq '.["quantivly"].lastUpdated = "2026-01-01T00:00:00Z"' "$H/.claude/plugins/known_marketplaces.json" >"$C/k" &&
    mv "$C/k" "$H/.claude/plugins/known_marketplaces.json"
touch "$H/stub/market-update-fails"
run_level --apply
has   "a marketplace update that fails: ✗, re-checked, never ✓" "$OUT" "quantivly: still last updated"
check "a marketplace update that fails: exit 1" "$RC" 1
new_case
jq 'del(.dotfiles)' "$H/.claude/plugins/known_marketplaces.json" >"$C/k" && mv "$C/k" "$H/.claude/plugins/known_marketplaces.json"
run_level --apply
has   "missing dotfiles marketplace: added from the checkout path" "$(calls)" "claude plugin marketplace add $H/.dotfiles/claude/plugins --scope user"
new_case
jq '.enabledPlugins["quantivly-pr-conventions@quantivly"] = true' "$H/.claude/settings.json" >"$C/s" && mv "$C/s" "$H/.claude/settings.json"
run_level --check
has   "superseded plugin enabled: ✗" "$OUT" "quantivly-pr-conventions@quantivly is enabled but superseded"
run_level --apply
check "superseded plugin: set false in settings.json" "$(jq -r '.enabledPlugins["quantivly-pr-conventions@quantivly"]' "$H/.claude/settings.json")" false
check "superseded plugin: the rest of settings.json survives" "$(jq -r .theme "$H/.claude/settings.json")" dark
check "superseded plugin: a backup is kept" "$([[ -e "$H/.local/state/dev-sync/settings.json.before-dev-sync" ]] && echo yes || echo no)" yes
hasnt "superseded plugin: no CLI call names it" "$(calls)" "quantivly-pr-conventions"
new_case
jq 'del(.plugins["slack@claude-plugins-official"])' "$H/.claude/plugins/installed_plugins.json" >"$C/i" && mv "$C/i" "$H/.claude/plugins/installed_plugins.json"
jq 'del(.enabledPlugins["slack@claude-plugins-official"])' "$H/.claude/settings.json" >"$C/s" && mv "$C/s" "$H/.claude/settings.json"
run_level --check
has   "missing plugin: ✗ not installed" "$OUT" "slack@claude-plugins-official not installed"
run_level --apply
has   "missing plugin: installed at USER scope" "$(calls)" "claude plugin install slack@claude-plugins-official --scope user"
new_case
jq '.plugins["slack@claude-plugins-official"] = [{scope: "project", projectPath: "/x", version: "1"}]' \
    "$H/.claude/plugins/installed_plugins.json" >"$C/i" && mv "$C/i" "$H/.claude/plugins/installed_plugins.json"
run_level --check
has   "a PROJECT-scope install only: not installed for the user" "$OUT" "slack@claude-plugins-official not installed"
new_case
jq '.plugins["linear-key@dotfiles"] = [{scope: "project", projectPath: "/x", version: "0.1.0"}, {scope: "user", version: "1.0.0"}]' \
    "$H/.claude/plugins/installed_plugins.json" >"$C/i" && mv "$C/i" "$H/.claude/plugins/installed_plugins.json"
run_level --check
hasnt "a project entry listed first: the USER entry's version is read" "$OUT" "0.1.0 installed"
new_case
jq '.enabledPlugins["notion@claude-plugins-official"] = false' "$H/.claude/settings.json" >"$C/s" && mv "$C/s" "$H/.claude/settings.json"
run_level --apply
has   "disabled plugin: enabled, not reinstalled" "$(calls)" "claude plugin enable notion@claude-plugins-official --scope user"
new_case
jq '.enabledPlugins["linear@claude-plugins-official"] = true | del(.enabledPlugins["linear-key@dotfiles"])' "$H/.claude/settings.json" >"$C/s" && mv "$C/s" "$H/.claude/settings.json"
jq 'del(.plugins["linear-key@dotfiles"])' "$H/.claude/plugins/installed_plugins.json" >"$C/i" && mv "$C/i" "$H/.claude/plugins/installed_plugins.json"
run_level --apply
check "official linear: disabled once linear-key is on" "$(jq -r '.enabledPlugins["linear@claude-plugins-official"]' "$H/.claude/settings.json")" false
check "official linear: disabled AFTER linear-key was installed" \
    "$(grep -nE 'install linear-key|disable linear@' "$H/stub/calls" | cut -d: -f2- | tr '\n' '|')" \
    "claude plugin install linear-key@dotfiles --scope user|claude plugin disable linear@claude-plugins-official --scope user|"
new_case
jq '.enabledPlugins["linear@claude-plugins-official"] = true | del(.enabledPlugins["linear-key@dotfiles"])' "$H/.claude/settings.json" >"$C/s" && mv "$C/s" "$H/.claude/settings.json"
jq 'del(.plugins["linear-key@dotfiles"])' "$H/.claude/plugins/installed_plugins.json" >"$C/i" && mv "$C/i" "$H/.claude/plugins/installed_plugins.json"
touch "$H/stub/install-fails-linear-key@dotfiles"
run_level --apply
check "linear-key install failing: official linear is LEFT ON" "$(jq -r '.enabledPlugins["linear@claude-plugins-official"]' "$H/.claude/settings.json")" true
has   "linear-key install failing: ✗ says why" "$OUT" "must not end up with neither"
new_case
echo '{"name":"linear-key","version":"1.1.0"}' >"$H/.dotfiles/claude/plugins/linear-key/.claude-plugin/plugin.json"
run_level --check
has   "linear-key copy older than the checkout: ✗" "$OUT" "linear-key@dotfiles 1.0.0 installed, checkout has 1.1.0"
run_level --apply
has   "linear-key copy: --apply runs plugin update" "$(calls)" "claude plugin update linear-key@dotfiles --scope user"

echo "== MCP sign-ins and LINEAR_API_KEY"
new_case
printf 'plugin:slack:slack: https://x (HTTP) - ! Needs authentication\nplugin:Notion:notion: https://y (HTTP) - ✔ Connected\n' >"$H/stub/mcp-list"
run_level --check
has   "slack needs a sign-in: ⚠ with the /mcp step" "$OUT" "⚠ mcp            slack needs a sign-in on dev"
has   "a sign-in step is counted as a person's step" "$OUT" "1 step(s) need a person"
check "a sign-in step alone does not fail --check" "$RC" 0
reset_calls; run_level --check --no-mcp
hasnt "--no-mcp: claude mcp list is not run" "$(calls)" "claude mcp list"
new_case
: >"$H/.zshrc.local"
run_level --check
has   "no LINEAR_API_KEY on dev: ⚠" "$OUT" "LINEAR_API_KEY is not in dev's ~/.zshrc.local"
mapfile -t F < <(facts)
OUT="$(LINEAR_API_KEY=inherited HOME="$H" PATH="/usr/local/bin:/usr/bin:/bin" bash "$SUT" --here --check "${F[@]}" 2>&1)"
has   "a key in the CALLER's environment does not read as in the file" "$OUT" "LINEAR_API_KEY is not in dev's ~/.zshrc.local"

echo "== clones"
new_case
run_level --check --clone beta=quantivly/beta
has   "missing clone: ✗ names the laptop's repo" "$OUT" "beta missing (laptop: quantivly/beta)"
check "missing clone: --check does not clone" "$([[ -e "$H/quantivly/beta" ]] && echo yes || echo no)" no
run_level --apply --clone beta=quantivly/beta
check "missing clone: --apply clones it" "$(git -C "$H/quantivly/beta" remote get-url origin 2>/dev/null)" "file://$GH/quantivly/beta.git"
check "missing clone: fetched in the same run, so it reads as fresh" "$([[ -e "$H/quantivly/beta/.git/FETCH_HEAD" ]] && echo yes || echo no)" yes
reset_calls; run_level --apply --clone beta=quantivly/beta
hasnt "missing clone: second --apply has no ✗" "$OUT" "✗"
new_case
mkdir -p "$H/quantivly/beta"; git -C "$H/quantivly/beta" init -q; git -C "$H/quantivly/beta" remote add origin https://github.com/someone/else.git
run_level --apply --clone beta=quantivly/beta
has   "a directory with another origin: ⚠, not touched" "$OUT" "beta is someone/else here and quantivly/beta on the laptop"
new_case
touch -d '3 days ago' "$H/quantivly/alpha/.git/FETCH_HEAD"
run_level --check
has   "stale fetch: ✗ with its age" "$OUT" "1 of 1 not fetched in 36h (oldest: alpha, 3d ago)"
before="$(head_of "$H/quantivly/alpha")"
run_level --apply
check "stale fetch: --apply refreshes FETCH_HEAD" "$(( $(date +%s) - $(stat -c %Y "$H/quantivly/alpha/.git/FETCH_HEAD") < 60 ))" 1
check "stale fetch: the checkout is not changed" "$(head_of "$H/quantivly/alpha")" "$before"
new_case
touch -d '25 hours ago' "$H/quantivly/alpha/.git/FETCH_HEAD"
run_level --check
has   "a day-old fetch (timer jitter) is not drift" "$OUT" "1 clones under ~/quantivly fetched within 36h"
run_level --apply
check "a day-old fetch: --apply refreshes it anyway" "$(( $(date +%s) - $(stat -c %Y "$H/quantivly/alpha/.git/FETCH_HEAD") < 60 ))" 1
new_case
rm -rf "$H/quantivly"
run_level --check --clone beta=quantivly/beta
check "no ~/quantivly: --check does not create it" "$([[ -e "$H/quantivly" ]] && echo yes || echo no)" no
new_case
run --check --clone 'x;rm=quantivly/x'
check "an unsafe --clone dir is refused (64)" "$RC" 64

echo "== timer"
new_case
rm "$H/.config/dev-sync/armed" "$H/stub/timer-enabled" "$H/stub/timer-active"
reset_calls; run_level --apply
check "unarmed dev, --apply without --arm: refused (2)" "$RC" 2
check "unarmed dev: nothing mutating was called" "$(mutations)" 0
run_level --check
has   "unarmed dev: --check shows the ✗" "$OUT" "dev-sync.timer not armed"
run_level --apply --arm
check "--arm: the marker is written" "$([[ -e "$H/.config/dev-sync/armed" ]] && echo yes || echo no)" yes
has   "--arm: enable, never reenable" "$(calls)" "systemctl --user enable --now dev-sync.timer"
hasnt "--arm: no reenable or disable" "$(grep -E '(re|dis)able' "$H/stub/calls")" "dev-sync.timer"
new_case
rm "$H/.config/dev-sync/armed" "$H/stub/timer-enabled" "$H/stub/timer-active"; : >"$H/.config/dev-sync/disarmed"
reset_calls; run_level --apply --arm
check "disarmed by hand: --arm does not write the marker" "$([[ -e "$H/.config/dev-sync/armed" ]] && echo yes || echo no)" no
hasnt "disarmed by hand: the timer is not enabled" "$(calls)" "enable --now dev-sync.timer"
has   "disarmed by hand: · says so, and it is not drift" "$OUT" "· timer          disarmed by hand"
check "disarmed by hand: the rest still syncs, and exits 0" "$RC" 0

echo "== hygiene: abandoned sessions, slice"
new_case
printf 'session-%s.scope loaded active %s Session\n' 1 abandoned 2 abandoned 3 running 4 abandoned 5 abandoned >"$H/stub/units"
echo $((300 * 1048576)) >"$H/stub/mem-session-1.scope"; echo $((100 * 1048576)) >"$H/stub/mem-session-2.scope"
echo $((900 * 1048576)) >"$H/stub/mem-session-3.scope"; echo $((900 * 1048576)) >"$H/stub/mem-session-4.scope"
echo $((250 * 1048576)) >"$H/stub/mem-session-5.scope"; echo "user-4242.slice" >"$H/stub/slice-session-4.scope"
run_level --apply
has   "abandoned scope over 200 MB: ⚠ names it" "$OUT" "session-1.scope 0.3G"
hasnt "abandoned scope under 200 MB: not listed" "$OUT" "session-2.scope"
hasnt "a RUNNING session is never listed" "$OUT" "session-3.scope"
hasnt "another user's abandoned scope is never listed" "$OUT" "session-4.scope"
has   "the stop command names exactly the listed units" "$OUT" "sudo systemctl stop session-1.scope session-5.scope"$'\n'
hasnt "--apply never runs it (sudo is stubbed and logs)" "$(calls)" "sudo"
new_case
touch "$H/stub/no-slice"
run_level --check
has   "no agents.slice unit file: ⚠, not MemoryMax=infinity read as fine" "$OUT" "agents.slice has no unit file"

echo "== the laptop half"
new_case
L="$C/laptop"; mkdir -p "$L/quantivly" "$L/stub"; write_stubs "$L"
echo "$V_LAPTOP" >"$L/stub/claude-version"; echo 0.9.1 >"$L/stub/herdr-version"; cp "$H/stub/draft.json" "$L/stub/draft.json"
mk() { git init -q "$L/quantivly/$1"; [[ -n "${2:-}" ]] && git -C "$L/quantivly/$1" remote add origin "$2"; }
mk alpha git@github-work:quantivly/alpha.git
mk Gamma https://github.com/Quantivly/Gamma.git
mk other https://github.com/someone/other.git
mk dots git@github-work:quantivly/dotfiles.git
mk lab https://gitlab.com/quantivly/lab.git
mk noremote
mkdir -p "$L/quantivly/plain"
git init -q "$L/quantivly/.hidden"; git -C "$L/quantivly/.hidden" remote add origin https://github.com/quantivly/hidden.git
git -C "$L/quantivly/alpha" commit -q --allow-empty -m init
git -C "$L/quantivly/alpha" worktree add -q "$L/quantivly/alpha-wt" -b wt   # a REAL worktree: .git is a file, origin resolves
FACTS_OUT="$(HOME="$L" PATH="/usr/local/bin:/usr/bin:/bin" DEV_SYNC_DOTFILES_REMOTE="file://$GH/quantivly/dotfiles.git" \
    DEV_SYNC_GITHUB_BASE="file://$GH" bash "$SUT" --print-facts 2>&1)"
has   "facts: the laptop's Claude version" "$FACTS_OUT" "--claude-version $V_LAPTOP"
hasnt "facts: no herdr-draft commit (laptop and timer both target main)" "$FACTS_OUT" "--draft-sha"
has   "facts: the laptop herdr binary's sha256, for dev to verify against" "$FACTS_OUT" "--herdr-sha256 $(sha256sum "$L/.local/bin/herdr" | cut -c1-64)"
has   "facts: dotfiles main from the remote" "$FACTS_OUT" "--dotfiles-sha $(git --git-dir="$GH/quantivly/dotfiles.git" rev-parse main)"
has   "facts: a host-alias origin is normalised" "$FACTS_OUT" "--clone alpha=quantivly/alpha"
has   "facts: owner case is normalised, dir name kept" "$FACTS_OUT" "--clone Gamma=quantivly/gamma"
check "facts: exactly the two work clones (no other owner, dotfiles, gitlab, worktree, hidden)" \
    "$(grep -c -- '--clone' <<<"$FACTS_OUT")" 2

# End to end through a fake ssh that runs the remote command in zsh, dev's login shell, so
# the quoting of the facts is exercised as it will be on dev.
# shellcheck disable=SC2016  # expanded by the inner shell, deliberately
printf '#!/usr/bin/env bash\nshift\nexec env HOME="%s" zsh -f -c "$1"\n' "$H" >"$C/fakessh"; chmod +x "$C/fakessh"
echo 2.1.272 >"$H/stub/claude-version"
E2E="$(HOME="$L" PATH="/usr/local/bin:/usr/bin:/bin" DEV_SYNC_SSH="$C/fakessh" DEV_SYNC_NO_SCOPE=1 \
    DEV_SYNC_DOTFILES_REMOTE="file://$GH/quantivly/dotfiles.git" DEV_SYNC_GITHUB_BASE="file://$GH" \
    DEV_SYNC_NPM_URL="file://$C/npm.json" bash "$SUT" --check 2>&1)"; E2E_RC=$?
check "end to end --check: exit 1 on drift" "$E2E_RC" 1
has   "end to end --check: the laptop's version reached dev" "$E2E" "2.1.272, laptop has $V_LAPTOP"
has   "end to end --check: a laptop-only clone reads as missing" "$E2E" "Gamma missing (laptop: quantivly/gamma)"
E2E="$(HOME="$L" PATH="/usr/local/bin:/usr/bin:/bin" DEV_SYNC_SSH="$C/fakessh" DEV_SYNC_NO_SCOPE=1 \
    DEV_SYNC_DOTFILES_REMOTE="file://$GH/quantivly/dotfiles.git" DEV_SYNC_GITHUB_BASE="file://$GH" \
    DEV_SYNC_NPM_URL="file://$C/npm.json" bash "$SUT" --apply 2>&1)"; E2E_RC=$?
has   "end to end --apply: claude raised to the laptop's" "$(cat "$H/stub/claude-version")" "$V_LAPTOP"
has   "end to end --apply: the clone failure is reported, not hidden" "$E2E" "Gamma: git clone quantivly/gamma failed"
check "end to end --apply: so it exits 1" "$E2E_RC" 1
# Reachable, and the dotfiles probe answers; only the run itself dies, as an OOM kill would.
# shellcheck disable=SC2016  # expanded by the inner shell, deliberately
printf '#!/usr/bin/env bash\n[[ "$*" == *"bash -s"* ]] && { cat >/dev/null; exit 137; }\nexec "%s" "$@"\n' "$C/fakessh" >"$C/oomssh"
chmod +x "$C/oomssh"
OUT="$(HOME="$L" PATH="/usr/local/bin:/usr/bin:/bin" DEV_SYNC_SSH="$C/oomssh" DEV_SYNC_NO_SCOPE=1 \
    DEV_SYNC_DOTFILES_REMOTE="file://$GH/quantivly/dotfiles.git" DEV_SYNC_GITHUB_BASE="file://$GH" \
    bash "$SUT" --check 2>&1)"; RC=$?
check "the remote run killed (137): exit 2, never read as drift" "$RC" 2
has   "the remote run killed: says so" "$OUT" "ended with status 137"

printf '\n'
EXPECTED_ROWS=149
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '\033[1;31mROW COUNT\033[0m: expected %d rows, %d ran — a check vanished or was added without updating EXPECTED_ROWS\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))" >&2
    exit 1
fi
if (( FAIL )); then printf '\033[1;31m%d of %d failed\033[0m\n' "$FAIL" "$((PASS + FAIL))"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$PASS"
