#!/usr/bin/env bash
#
# scripts/test-host-sync.sh
# ========================
#
# State table for scripts/host-sync: keeping dev's tooling level with the laptop's.
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
# host-sync puts first on PATH itself), each recording its calls. git is real,
# against bare repos served over file://. The npm registry is a file:// JSON. No
# network, no real ~/.claude, nothing outside mktemp -d.
# Requires: bash, zsh, git, jq, curl, flock.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$DOTFILES/scripts/host-sync"
WRAPPER="$DOTFILES/scripts/dev-sync"
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
# The profile marker's override (the settings renderer's name) and the overlay's: a row sets what
# it means to, so a caller's own (a real ~/.config/claude-host-profile, a real remote) never reaches one.
unset CLAUDE_SETTINGS_RENDER_MARKER HOST_SYNC_DOTFILES_LOCAL_REPO HOST_SYNC_DOTFILES_LOCAL_REMOTE PROFILE_MARKER_PATH

V_LAPTOP="2.1.296"
HV="0.9.1"            # the laptop's herdr
ARCH="$(uname -m)"
FAKE_KEY="lin_api_FIXTUREVALUE0123456789abcdefXYZ"
# Built at runtime so no token-shaped literal sits in the repo for a scanner to flag.
FAKE_TOK="sk-ant-""oat01-FIXTUREtokenNOTREAL0123456789abcdef"
MUTATING='claude install|claude plugin (marketplace add|marketplace update|install|enable|disable|update)|herdr plugin install|systemctl --user enable|systemctl --user restart|systemctl --user stop|daemon-reload|^sudo |claude-settings-render.sh --apply'

# ---------------------------------------------------------------------------------------------
# Stubs. Each logs "<tool> <args>" to $HOME/stub/calls.
# ---------------------------------------------------------------------------------------------

write_stubs() {   # $1 = HOME
    local b="$1/.local/bin"; mkdir -p "$b" "$1/stub/go/bin"
    cat >"$b/claude" <<'STUB'
#!/usr/bin/env bash
S="$HOME/stub"; echo "claude $*" >>"$S/calls"
# Which calls ran with the long-lived token in their environment, by name only.
[[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && echo "claude $*" >>"$S/calls-with-token"
# The lock case: whether --apply's lock is held while this child runs (a fresh open, so the
# descriptor this child may have inherited does not count) ...
if [[ -e "$S/daemonize" ]]; then
    { flock -n "$HOME/.local/state/host-sync/lock" true && echo free || echo held; } >>"$S/lock-during"
fi
# ... and a child that daemonizes, as an ssh-agent started under a `claude` call does: it closes
# 0-2 and keeps every other descriptor it inherited. It stops on its stop file, or once the
# case directory is gone, so a failed run never leaves it behind.
if [[ -e "$S/daemonize" && ! -e "$S/daemon.pid" ]]; then
    setsid bash -c 'until [[ -e "$1" || ! -d "${1%/*}" ]]; do sleep 0.1; done' _ "$S/daemon-stop" \
        </dev/null >/dev/null 2>&1 &
    echo "$!" >"$S/daemon.pid"
fi
P="$HOME/.claude/plugins"; SET="$HOME/.claude/settings.json"; IP="$P/installed_plugins.json"; KM="$P/known_marketplaces.json"
jqi() { local f=$1; shift; jq "$@" "$f" >"$f.tmp" && mv "$f.tmp" "$f"; }
case "$1" in
    --version) echo "$(cat "$S/claude-version") (Claude Code)" ;;
    install) [[ -e "$S/claude-install-fails" ]] && exit 1; echo "$2" >"$S/claude-version" ;;
    mcp) cat "$S/mcp-list" 2>/dev/null ;;
    -p)   # claude-oauth-store's check of a token: shapes measured against claude 2.1.299
        # Whether the store's lock is free while this probe child runs (a fresh open).
        [[ -d "$HOME/.config/claude-oauth" ]] &&
            { flock -n "$HOME/.config/claude-oauth/.lock" true && echo free || echo held; } >>"$S/store-lock-during"
        if [[ -e "$S/token-rejected" ]]; then
            echo '{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate. API Error: 401 OAuth access token is invalid."}'
            exit 1
        fi
        echo '{"type":"result","subtype":"success","is_error":false,"result":"OK"}' ;;
    auth)
        [[ -e "$S/auth-fails" ]] && exit 1
        if [[ -e "$S/no-login" ]]; then echo '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'
        elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" && ! -e "$S/ignores-token" ]]; then
            echo '{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}'
        else echo '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'; fi ;;
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
    cat >"$b/ssh-add" <<'STUB'
#!/usr/bin/env bash
S="$HOME/stub"; echo "$(readlink -f "${SSH_AUTH_SOCK:-/none}" 2>/dev/null || echo "${SSH_AUTH_SOCK:-unset}")" >>"$S/ssh-add-calls"
[[ -e "$S/ssh-add-hangs" ]] && sleep 10
exit "$(cat "$S/ssh-add-rc" 2>/dev/null || echo 1)"
STUB
    cat >"$b/ssh-agent" <<'STUB'
#!/usr/bin/env bash
echo "ssh-agent $*" >>"$HOME/stub/calls"
STUB
    chmod +x "$b/ssh-add" "$b/ssh-agent"
    cat >"$b/herdr" <<'STUB'
#!/usr/bin/env bash
S="$HOME/stub"; echo "herdr $*" >>"$S/calls"
V="${V:-$(cat "$S/herdr-version")}"   # a release "asset" built from this stub pins V on line 2
case "$1 ${2:-}" in
    "--version "*) echo "herdr $V" ;;
    "--skill "*) [[ -e "$S/skill-empty" ]] || echo "skill for $V" ;;
    "status server") printf 'status: running\nversion: %s\n' "$(cat "$S/server-version")" ;;
    "agent list") printf '{"result":{"agents":[%s]}}\n' "$(cat "$S/agents" 2>/dev/null)" ;;
    "pane list") [[ -e "$S/panes-down" ]] && exit 1; printf '{"result":{"panes":[%s]}}\n' "$(cat "$S/panes" 2>/dev/null)" ;;
    "pane process-info")   # idle at its prompt unless the case says otherwise
        [[ -e "$S/proc-down" ]] && exit 1
        cat "$S/proc-$4" 2>/dev/null || echo '{"result":{"process_info":{"shell_pid":10,"foreground_process_group_id":10}}}' ;;
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
# State is per unit: is-enabled reads $S/enabled-<unit>, is-active $S/active-<unit>. A unit enabled
# through WantedBy= stays enabled only while its .wants link exists, as with systemd, which reads the
# links at query time: once the link is gone a dotbot-linked unit reads `linked`, whatever the file
# says. Without that, a pruned dev-sync.timer would read enabled forever.
WANTS="$HOME/.config/systemd/user/default.target.wants"
[[ "$1" == --user ]] && shift
case "$1" in
    is-enabled)
        state="$(cat "$S/enabled-$2" 2>/dev/null)" || { echo disabled; exit 1; }
        [[ "$state" == enabled && ! -L "$WANTS/$2" ]] && state=linked
        echo "$state"; [[ "$state" == enabled ]] ;;
    is-active) cat "$S/active-$2" 2>/dev/null || { echo inactive; exit 3; } ;;
    daemon-reload) ;;
    restart) [[ -e "$S/restart-fails" ]] && exit 1; "$HOME/.local/bin/herdr" --version | awk '{print $2}' >"$S/server-version" ;;
    enable)   # enable --now <unit>: the unit is named last
        [[ -e "$S/enable-fails" ]] && exit 1
        unit="${!#}"; echo enabled >"$S/enabled-$unit"; echo active >"$S/active-$unit"; ln -sfn "../$unit" "$WANTS/$unit" ;;
    stop) echo inactive >"$S/active-$2" ;;
    list-units) cat "$S/units" 2>/dev/null ;;
    show)
        case "$2:$4" in
            agents.slice:FragmentPath) [[ -e "$S/no-slice" ]] || echo "$HOME/.config/systemd/user/agents.slice" ;;
            agents.slice:MemoryHigh) echo 12884901888 ;;
            agents.slice:MemoryMax) echo 17179869184 ;;
            agents.slice:DropInPaths) echo "/x/50-MemoryHigh.conf /x/50-MemoryMax.conf" ;;
            host-sync.timer:*) echo "Wed 2026-10-14 05:12:00 EDT" ;;
            session-*:MemoryCurrent) cat "$S/mem-$2" 2>/dev/null ;;
            session-*:Slice) cat "$S/slice-$2" 2>/dev/null || echo "user-$(id -u).slice" ;;
        esac ;;
esac
STUB
    # host-sync must never run sudo; a logging stub makes a call visible to the rows.
    # shellcheck disable=SC2016  # expanded by the stub, deliberately
    printf '#!/bin/sh\necho "sudo $*" >>"$HOME/stub/calls"\nexit 1\n' >"$b/sudo"
    chmod +x "$b"/* "$1/stub/go/bin/go"
}

# A seed repo's ./install: it refuses on its fail flag, logs that it ran, then does dotbot's link
# step in miniature for the `~/target: source` lines of its own install.conf.yaml. A regular file at
# a target is first moved aside under dotbot's backup name (install.conf.yaml's `backup: true`;
# dotbot/src/dotbot/plugins/link.py, _backup: <path>.dotbot-backup.<YYYYMMDD-HHMMSS>, local time).
write_install_stub() {   # $1 = the file, $2 = its fail flag, $3 = its install-order word, $4 = its ran log
    {
        printf '#!/usr/bin/env bash\nFAIL_FLAG=%q ORDER_WORD=%q RAN_LOG=%q\n' "$2" "$3" "$4"
        cat <<'STUB'
[[ -e "$HOME/stub/$FAIL_FLAG" ]] && exit 1
echo "$ORDER_WORD" >>"$HOME/stub/install-order"
echo ran >>"$HOME/stub/$RAN_LOG"
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
while IFS=$'\t' read -r target source; do
    live="$HOME/${target#\~/}"
    mkdir -p "$(dirname "$live")"
    [[ -e "$live" && ! -L "$live" ]] && mv "$live" "$live.dotbot-backup.$(date +%Y%m%d-%H%M%S)"
    ln -sfn "$PWD/$source" "$live"
done < <(awk '/^ +~\// { sub(/^ +/, ""); i = index($0, ": "); print substr($0, 1, i - 1) "\t" substr($0, i + 2) }' install.conf.yaml)
STUB
    } >"$1"
    chmod +x "$1"
}

# The settings renderer: --check exits $HOME/stub/render-rc (0 when there is none) and at 2 says
# why on stderr, as the real one does; --apply renders, so the next --check is level. Two flags
# break --apply: render-apply-fails (it cannot write: exit 2, with its reason) and
# render-apply-no-op (exit 0, the file left as it was).
write_render_stub() {   # $1 = the file
    cat >"$1" <<'STUB'
#!/usr/bin/env bash
S="$HOME/stub"; echo "claude-settings-render.sh $*" >>"$S/calls"
case "$1" in
    --check)
        rc="$(cat "$S/render-rc" 2>/dev/null || echo 0)"
        [[ "$rc" == 2 ]] && echo "claude-settings-render: settings.json is a symlink" >&2
        exit "$rc" ;;
    --apply)
        if [[ -e "$S/render-apply-fails" ]]; then
            echo "claude-settings-render: could not back up settings.json" >&2
            exit 2
        fi
        [[ -e "$S/render-apply-no-op" ]] || echo 0 >"$S/render-rc" ;;
esac
STUB
    chmod +x "$1"
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
    mkdir -p "$H/stub" "$GH" "$H/.claude/plugins/marketplaces" "$H/.config/systemd/user" "$H/.config/host-sync" "$H/quantivly"
    write_stubs "$H"
    echo "$V_LAPTOP" >"$H/stub/claude-version"; echo "$HV" >"$H/stub/herdr-version"; echo "$HV" >"$H/stub/server-version"
    # herdr's "release": the stub with its version pinned, served over file://
    mkdir -p "$C/releases/v$HV"; sed "2i V=$HV" "$H/.local/bin/herdr" >"$C/releases/v$HV/herdr-linux-$ARCH"
    HSHA="$(sha256sum "$C/releases/v$HV/herdr-linux-$ARCH" | cut -c1-64)"
    mkdir -p "$H/.claude/skills/herdr"; echo old >"$H/.claude/skills/herdr/SKILL.md"
    : >"$H/stub/calls"

    # dotfiles: origin with an install script, two declared links, the linear-key plugin, the
    # settings renderer (a stub) and the REAL link checker, all tracked; dev at origin/main.
    local w="$C/seed-dotfiles"
    git init -q -b main "$w"
    mkdir -p "$w/claude/plugins/linear-key/.claude-plugin" "$w/claude/plugins/.claude-plugin" "$w/config" "$w/scripts"
    # install-order is shared with dotfiles-local's stub, so a row can read which ran first.
    write_install_stub "$w/install" install-fails public install-ran
    printf -- '- link:\n    ~/.x: config/x\n    ~/.config/fixture/y.conf: config/y.conf\n' >"$w/install.conf.yaml"
    echo x >"$w/config/x"; echo y >"$w/config/y.conf"
    cp "$DOTFILES/scripts/check-links.sh" "$w/scripts/check-links.sh"
    write_render_stub "$w/scripts/claude-settings-render.sh"
    echo '{"name":"linear-key","version":"1.0.0"}' >"$w/claude/plugins/linear-key/.claude-plugin/plugin.json"
    echo '{"name":"dotfiles","plugins":[{"name":"linear-key"}]}' >"$w/claude/plugins/.claude-plugin/marketplace.json"
    echo one >"$w/a.txt"
    git -C "$w" add -A; git -C "$w" commit -q -m init
    mkdir -p "$GH/quantivly"; git clone -q --bare "$w" "$GH/quantivly/dotfiles.git"; rm -rf "$w"
    git clone -q "$GH/quantivly/dotfiles.git" "$H/.dotfiles"
    mkdir -p "$H/.local/state/host-sync"
    git -C "$H/.dotfiles" rev-parse HEAD >"$H/.local/state/host-sync/installed-head"

    # dotfiles-local, the private overlay, with the host profile `p` marked: an install stub of the
    # same shape, a manifest declaring two links and the profile itself; cloned and installed, as a
    # level host has it.
    w="$C/seed-dotfiles-local"
    git init -q -b main "$w"; mkdir -p "$w/hosts" "$w/claude" "$w/config"
    write_install_stub "$w/install" install-fails-local local local-install-ran
    printf -- '- link:\n    ~/.claude/CLAUDE.md: claude/CLAUDE.md\n    ~/.config/overlay/note.txt: config/note.txt\n' >"$w/install.conf.yaml"
    echo '# the overlay instructions' >"$w/claude/CLAUDE.md"; echo note >"$w/config/note.txt"
    echo '{"tenants":["quantivly"]}' >"$w/hosts/p.json"
    git -C "$w" add -A; git -C "$w" commit -q -m init
    mkdir -p "$GH/ZviBaratz"; git clone -q --bare "$w" "$GH/ZviBaratz/dotfiles-local.git"; rm -rf "$w"
    git clone -q "$GH/ZviBaratz/dotfiles-local.git" "$H/.dotfiles-local"
    git -C "$H/.dotfiles-local" rev-parse HEAD >"$H/.local/state/host-sync/installed-head-dotfiles-local"
    echo p >"$H/.config/claude-host-profile"
    # A level host has run both ./installs, so every declared link is in place. Their logs are
    # cleared, so a row reads only what the run under test did.
    { (cd "$H/.dotfiles" && HOME="$H" bash ./install) && (cd "$H/.dotfiles-local" && HOME="$H" bash ./install); } ||
        fatal "the fixture's ./install stubs could not link the declared links"
    rm -f "$H/stub/install-order" "$H/stub/install-ran" "$H/stub/local-install-ran"

    # timer armed. ./install links both units on every host (plain files stand in for the links);
    # only host-sync.timer is enabled, which puts its link in the .wants directory.
    WANTS="$H/.config/systemd/user/default.target.wants"; mkdir -p "$WANTS"
    : >"$H/.config/host-sync/armed"
    : >"$H/.config/systemd/user/host-sync.timer"; : >"$H/.config/systemd/user/dev-sync.timer"
    stub_timer_live host-sync.timer

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

    # the long-lived token, stored 10 days ago; one Claude process, carrying it
    store_token "$(date -d '10 days ago' +%F)"
    fake_proc 4101 claude 1

    # one fresh clone; a worktree of it, which must be ignored
    bare quantivly/alpha
    git clone -q "$GH/quantivly/alpha.git" "$H/quantivly/alpha"
    git -C "$H/quantivly/alpha" fetch -q origin
    git -C "$H/quantivly/alpha" worktree add -q "$H/quantivly/alpha-wt" -b wt 2>/dev/null
    bare quantivly/beta   # exists on "GitHub", not on dev
}

# A timer enabled and active, as `systemctl --user enable --now` leaves it: both stub files, and
# the .wants link the stub's is-enabled requires. timer_off undoes all three.
stub_timer_live() {   # $1 = unit
    echo enabled >"$H/stub/enabled-$1"; echo active >"$H/stub/active-$1"; ln -sfn "../$1" "$WANTS/$1"
}
timer_off() { rm -f "$H/stub/enabled-$1" "$H/stub/active-$1" "$WANTS/$1"; }

# A host on the release before the rename: dev-sync's marker, its state dir (install stamp
# included) and its timer, armed and live; host-sync.timer linked by ./install, never enabled.
legacy_case() {
    new_case
    mv "$H/.config/host-sync" "$H/.config/dev-sync"
    mv "$H/.local/state/host-sync" "$H/.local/state/dev-sync"
    timer_off host-sync.timer
    stub_timer_live dev-sync.timer
}
# Which marker dirs hold an `armed` file: host-sync, dev-sync, both or none.
armed_where() {
    local new="$H/.config/host-sync/armed" legacy="$H/.config/dev-sync/armed"
    if [[ -e "$new" && -e "$legacy" ]]; then echo both
    elif [[ -e "$new" ]]; then echo host-sync
    elif [[ -e "$legacy" ]]; then echo dev-sync
    else echo none; fi
}
present() { if [[ -e "$1" || -L "$1" ]]; then echo present; else echo gone; fi; }
# From the stub log, by line: the enable of host-sync.timer, the first is-enabled read-back after
# it, and the stop of dev-sync.timer must come in that order.
arming_order() {
    awk '
        !enable_at && $0 == "systemctl --user enable --now host-sync.timer" { enable_at = NR }
        enable_at && !readback_at && NR > enable_at && $0 == "systemctl --user is-enabled host-sync.timer" { readback_at = NR }
        !stop_at && $0 == "systemctl --user stop dev-sync.timer" { stop_at = NR }
        END {
            if (enable_at && readback_at && stop_at && enable_at < readback_at && readback_at < stop_at) print "enable, read back, then stop"
            else print "out of order: enable at " enable_at ", read-back at " readback_at ", stop at " stop_at
        }' "$H/stub/calls"
}
# The .wants link is removed between the stop and the reload, so a reload after the stop is one
# after the removal.
reload_after_stop() {
    awk '
        $0 == "systemctl --user stop dev-sync.timer" { stop_at = NR }
        $0 == "systemctl --user daemon-reload" { reload_at = NR }
        END { if (stop_at && reload_at > stop_at) print "after"; else print "not after" }' "$H/stub/calls"
}

store_token() {   # $1 = the created date; writes what claude-oauth-store writes
    mkdir -p "$H/.config/claude-oauth"; chmod 700 "$H/.config/claude-oauth"
    printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$FAKE_TOK" >"$H/.config/claude-oauth/token.env"
    chmod 600 "$H/.config/claude-oauth/token.env"
    echo "$1" >"$H/.config/claude-oauth/created"
}
# The seat layout PR B's --adopt makes (docs/HERDR_GUIDE.md, "Working on dev"): the token moves to
# seats/$1.env with its date beside it, and token.env becomes a link to it. The legacy `created` is
# left behind dated 300 days ago, so a row can tell which date was read.
link_token() {   # $1 = seat name
    local d="$H/.config/claude-oauth"
    mkdir -p "$d/seats"; chmod 700 "$d/seats"
    mv "$d/token.env" "$d/seats/$1.env"; mv "$d/created" "$d/seats/$1.created"
    date -d '300 days ago' +%F >"$d/created"
    ln -s "seats/$1.env" "$d/token.env"
}
# A credentials file holding a fake /login, or not: only the key's presence may ever be read.
FAKE_LOGIN="FIXTURErefreshNOTREAL0123456789"
# A row's glyph and area, as host-sync's row() prints them, so a needle also pins ✓ against ⚠.
AUTH_OK="$(printf '✓ %-14s ' auth)"; AUTH_OPER="$(printf '⚠ %-14s ' auth)"
creds() {   # $1 = login | none | garbage
    case "$1" in
        login) printf '{"claudeAiOauth":{"refreshToken":"%s"},"mcpOAuth":{}}\n' "$FAKE_LOGIN" ;;
        none) printf '{"mcpOAuth":{"x":"%s"}}\n' "$FAKE_LOGIN" ;;
        garbage) printf '{"claudeAiOauth": %s\n' "$FAKE_LOGIN" ;;
    esac >"$H/.claude/.credentials.json"
    chmod 600 "$H/.claude/.credentials.json"
}
ntok() { if [[ -e "$H/stub/calls-with-token" ]]; then wc -l <"$H/stub/calls-with-token"; else echo 0; fi; }
fake_proc() {   # $1 = pid, $2 = comm, $3 = 1 if its environment carries the token
    local d="$C/proc/$1"; mkdir -p "$d"; echo "$2" >"$d/comm"
    if [[ "$3" == 1 ]]; then printf 'HOME=/x\0CLAUDE_CODE_OAUTH_TOKEN=%s\0TERM=y\0' "$FAKE_TOK" >"$d/environ"
    else printf 'HOME=/x\0TERM=y\0' >"$d/environ"; fi
}

# Facts a laptop run would send for a level dev.
facts() { printf '%s\n' --claude-version "$V_LAPTOP" --herdr-version "$HV" --herdr-arch "$ARCH" --herdr-sha256 "$HSHA" \
    --dotfiles-sha "$(git --git-dir="$GH/quantivly/dotfiles.git" rev-parse main)" --clone alpha=quantivly/alpha; }

# OUT / RC as globals, never inside $( ): an exit code assigned in a subshell dies with it.
# PROFILE_MARKER_PATH, when a row sets it, is where CLAUDE_SETTINGS_RENDER_MARKER points instead of
# the default path, so a row can tell an honoured override from a hard-coded default.
run() {   # $@ = host-sync args after --here; XTRACE=1 traces it to $C/xtrace
    # The trace goes to its own fd, as a person debugging with BASH_XTRACEFD would see it: a
    # command's own 2>/dev/null then hides nothing from it.
    local xt=(); [[ -n "${XTRACE:-}" ]] && xt=(BASH_XTRACEFD=3)
    # No SSH_AUTH_SOCK, as over `ssh dev` with ForwardAgent no: the caller's own must not leak in.
    OUT="$(env -u LINEAR_API_KEY -u SSH_AUTH_SOCK "${xt[@]}" HOME="$H" HOST_SYNC_GITHUB_BASE="file://$GH" HOST_SYNC_NPM_URL="file://$C/npm.json" \
        HOST_SYNC_HERDR_RELEASES="file://$C/releases" HOST_SYNC_PROC="$C/proc" XDG_RUNTIME_DIR="$C/run" \
        CLAUDE_SETTINGS_RENDER_MARKER="${PROFILE_MARKER_PATH:-$H/.config/claude-host-profile}" \
        PATH="/usr/local/bin:/usr/bin:/bin" bash ${XTRACE:+-x} "$SUT" --here "$@" 2>&1 3>"$C/xtrace")"
    RC=$?
}
run_level() { local m="$1"; shift; mapfile -t F < <(facts); run "$m" "${F[@]}" "$@"; }
calls() { cat "$H/stub/calls"; }
mutations() { grep -cE "$MUTATING" "$H/stub/calls"; }
reset_calls() { : >"$H/stub/calls"; }
head_of() { git -C "$1" rev-parse HEAD; }
push_to() {   # add a commit to a fixture origin: $1 = owner/repo, $2 = file, $3 = content
    local w="$C/push"; rm -rf "$w"; git clone -q "$GH/$1.git" "$w"
    echo "$3" >"$w/$2"; git -C "$w" add -A; git -C "$w" commit -q -m "$2"; git -C "$w" push -q origin main
}
push_origin() { push_to quantivly/dotfiles "$@"; }   # add a commit to dotfiles' origin: $1 = file, $2 = content
overlay_main() { git --git-dir="$GH/ZviBaratz/dotfiles-local.git" rev-parse main; }
# How many rows of $OUT are in area $1, whatever their glyph: row() pads the area to 14.
area_rows() {
    local line glyph prefix n=0 prefixes=()
    for glyph in ✓ ✗ ⚠ ·; do prefixes+=("$(printf '  %s %-14s ' "$glyph" "$1")"); done
    while IFS= read -r line; do
        for prefix in "${prefixes[@]}"; do [[ "$line" == "$prefix"* ]] && n=$((n + 1)); done
    done <<<"$OUT"
    echo "$n"
}
line_of() {   # the number of the first line of $OUT that holds $1; 0 when none does
    local line n=0
    while IFS= read -r line; do
        n=$((n + 1))
        [[ "$line" == *"$1"* ]] && { echo "$n"; return; }
    done <<<"$OUT"
    echo 0
}

CASE=0

echo "== a level dev"
new_case
run_level --check
check "level --check exits 0" "$RC" 0
has   "level --check says Level." "$OUT" "Level."
hasnt "level --check has no ✗ row" "$OUT" "✗"
check "level --check calls nothing mutating" "$(mutations)" 0
hasnt "--check takes no lock" "$(ls "$H/.local/state/host-sync")" "lock"
hasnt "the LINEAR_API_KEY value is never printed" "$OUT" "$FAKE_KEY"
has   "the key is reported present, by name" "$OUT" "LINEAR_API_KEY is set"
has   "the slice row reads the effective cap" "$OUT" "MemoryHigh=12.0G MemoryMax=16.0G (2 drop-in(s))"
hasnt "a worktree under ~/quantivly is not counted as a clone" "$OUT" "2 clones"
reset_calls
run_level --apply
check "--apply on a level dev exits 0" "$RC" 0
check "--apply on a level dev calls nothing mutating" "$(mutations)" 0
check "--apply on a level dev does not re-run ./install" "$([[ -e "$H/stub/install-ran" ]] && echo ran || echo no)" no

echo "== the lock: one --apply at a time, and no child keeps it"
# dev, 10-17 to 11-03: an ssh-agent started under one --apply inherited the lock's fd 9, kept it for
# its whole life, and every later run was refused. Here the stub claude leaves such a daemon behind.
new_case
LOCK="$H/.local/state/host-sync/lock"
exec 8>"$LOCK"; flock -n 8 || fatal "could not take $LOCK for the refusal row"
run_level --apply
exec 8>&-
check "a second --apply while one holds the lock: exit 2" "$RC" 2
has   "a second --apply while one holds the lock: refused, by name" "$OUT" "another run holds"
touch "$H/stub/daemonize"
run_level --apply
check "a daemonizing child: the --apply exits 0" "$RC" 0
check "a daemonizing child: the lock is held while children run" "$(sort -u "$H/stub/lock-during" 2>/dev/null)" held
DPID="$(cat "$H/stub/daemon.pid" 2>/dev/null)"
check "a daemonizing child: it outlives the run (else the rows below prove nothing)" \
    "$([[ -n "$DPID" ]] && kill -0 "$DPID" 2>/dev/null && echo alive || echo gone)" alive
check "a daemonizing child: the lock is free once the run ends" "$(flock -n "$LOCK" true && echo free || echo held)" free
run_level --apply
check "a daemonizing child: the next --apply is not refused" "$RC" 0
touch "$H/stub/daemon-stop"

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
rm -rf "$H/.local/state/host-sync" "$H/.config/host-sync/armed"; touch -d '3 days ago' "$H/quantivly/alpha/.git/FETCH_HEAD"
echo 1 >"$H/stub/render-rc"; rm "$H/.x"   # settings and a link, each one gate from its apply path
# Every path under $HOME with its size, mode and mtime, less the stub log and any path given.
snapshot() {   # $@ = further paths to leave out
    local leave_out=(-path "$H/stub") path
    for path in "$@"; do leave_out+=(-o -path "$path"); done
    find "$H" \( "${leave_out[@]}" \) -prune -o -printf '%p %s %m %T@\n' | sort
}
before="$(snapshot)"
run_level --check --clone beta=quantivly/beta
check "a fully drifted --check exits 1" "$RC" 1
check "--check changes no file, directory or mode under \$HOME" "$(diff <(echo "$before") <(snapshot) | head -n 5)" ""
check "a fully drifted --check calls nothing mutating and runs no ./install" \
    "$(mutations)/$(present "$H/stub/install-ran")/$(present "$H/stub/local-install-ran")" 0/gone/gone

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
check "behind: the stamp records the new HEAD" "$(cat "$H/.local/state/host-sync/installed-head")" "$(head_of "$H/.dotfiles")"
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
has   "unpushed commits on this host: ⚠ AHEAD, not touched" "$OUT" "is AHEAD of origin/main"

new_case
rm "$H/.local/state/host-sync/installed-head"; touch "$H/stub/install-fails"
run_level --apply
check "./install failing: exit 1" "$RC" 1
has   "./install failing: ✗ names the log" "$OUT" "./install failed"
check "./install failing: no stamp is written" "$([[ -e "$H/.local/state/host-sync/installed-head" ]] && echo yes || echo no)" no

echo "== the host profile and the private overlay (dotfiles-local)"
# The rows' glyph and area, as row() prints them, so a needle also pins the glyph.
PROFILE_INFO="$(printf '· %-14s ' profile)"; PROFILE_OPER="$(printf '⚠ %-14s ' profile)"
OVERLAY_OK="$(printf '✓ %-14s ' dotfiles-local)"; OVERLAY_DRIFT="$(printf '✗ %-14s ' dotfiles-local)"
OVERLAY_OPER="$(printf '⚠ %-14s ' dotfiles-local)"
new_case
run_level --check
has   "level: the profile row names the profile and its tenants" "$OUT" "${PROFILE_INFO}p (tenants: quantivly)"

new_case
rm "$H/.config/claude-host-profile"
run_level --check
has   "no marker: the overlay rows are skipped" "$OUT" \
    "${PROFILE_INFO}no host profile marker (~/.config/claude-host-profile); dotfiles-local, settings, memory stores and retire are not managed here"
check "no marker: the overlay rows are skipped: no dotfiles-local row, exit 0" "$(area_rows dotfiles-local)/$RC" 0/0
check "no profile: the work clones row still runs" "$(area_rows clones)" 1

new_case
echo ../x >"$H/.config/claude-host-profile"; rm -rf "$H/.dotfiles-local"
run_level --check
has   "a marker with an unusable name is a person's step" "$OUT" \
    "${PROFILE_OPER}the marker holds an unusable profile name (the renderer's rule: letters, digits, dots, dashes and underscores)"
run_level --apply
check "a marker with an unusable name: no clone attempted in --apply" "$(present "$H/.dotfiles-local")/$(area_rows dotfiles-local)" gone/0

new_case
rm "$H/.dotfiles-local/hosts/p.json"
run_level --check
has   "marker names a profile dotfiles-local lacks" "$OUT" "${PROFILE_OPER}no hosts/p.json in ~/.dotfiles-local"
echo '{"tenant":"quantivly"}' >"$H/.dotfiles-local/hosts/p.json"
run_level --check
has   "a profile file with no .tenants list is a person's step" \
    "$OUT" "${PROFILE_OPER}hosts/p.json in ~/.dotfiles-local cannot be read, or has no .tenants list of names"
check "a profile file with no .tenants list: the work clones still run" "$(area_rows clones)" 1
chmod 000 "$H/.config/claude-host-profile"
run_level --check
has   "an unreadable marker is a person's step, named" "$OUT" "${PROFILE_OPER}the marker ~/.config/claude-host-profile is not readable by"

# The marker's override is the renderer's own variable: a marker that exists only there is read, and
# a path outside $HOME is shown as it is, never with a ~ in front of it.
new_case
rm "$H/.config/claude-host-profile"; echo p >"$C/marker-elsewhere"
PROFILE_MARKER_PATH="$C/marker-elsewhere" run_level --check
has   "profile: the marker override is honoured" "$OUT" "${PROFILE_INFO}p (tenants: quantivly)"
rm "$C/marker-elsewhere"
PROFILE_MARKER_PATH="$C/marker-elsewhere" run_level --check
has   "profile: the marker override is honoured: a path outside \$HOME is shown absolute" "$OUT" \
    "${PROFILE_INFO}no host profile marker ($C/marker-elsewhere)"

new_case
rm -rf "$H/.dotfiles-local"
run_level --check
has   "dotfiles-local absent: --check ✗, nothing cloned" "$OUT" "${OVERLAY_DRIFT}not cloned (origin would be ZviBaratz/dotfiles-local)"
check "dotfiles-local absent: --check ✗, nothing cloned: exit 1, still absent" "$RC/$(present "$H/.dotfiles-local")" 1/gone
has   "dotfiles-local absent: the profile row says its tenants are unknown" "$OUT" \
    "${PROFILE_INFO}p: ~/.dotfiles-local is not cloned yet, so its tenants are unknown until --apply clones it"
check "profile named but overlay missing: the work clones row still runs" "$(area_rows clones)" 1

# Step 7's first minute: a marker written by hand on a host with no overlay yet. The public
# ./install renders settings, and the renderer refuses a marker with no overlay, so the overlay
# must be cloned before that install runs, and its profile read in the same run.
new_case
# A host that never had the overlay has no stamp for it, and a stale public one.
rm -rf "$H/.dotfiles-local" "$H/.local/state/host-sync/installed-head-dotfiles-local"
printf '%040d\n' 0 >"$H/.local/state/host-sync/installed-head"
run_level --apply
check "marker before the overlay: the overlay is cloned before the public ./install: a clone on main" \
    "$(git -C "$H/.dotfiles-local" symbolic-ref --short HEAD 2>/dev/null)" main
check "marker before the overlay: the overlay is cloned before the public ./install: public, then local" \
    "$(paste -sd' ' "$H/stub/install-order" 2>/dev/null)" "public local"
clone_at="$(line_of "${OVERLAY_OK}cloned from ZviBaratz/dotfiles-local")"; public_at="$(line_of "$(printf '✓ %-14s ' dotfiles)")"
check "marker before the overlay: the overlay is cloned before the public ./install: its ✓ row before the dotfiles row" \
    "$(( clone_at > 0 && clone_at < public_at ))" 1
has   "marker before the overlay: the profile is read after the clone" "$OUT" "${PROFILE_INFO}p (tenants: quantivly)"

# The overlay's origin unreachable: the clone is ✗, and its tenants stay unknown.
new_case
rm -rf "$H/.dotfiles-local" "$H/.local/state/host-sync/installed-head-dotfiles-local"
mv "$GH/ZviBaratz/dotfiles-local.git" "$GH/ZviBaratz/dotfiles-local.unreachable"
run_level --apply
has   "overlay: a clone that fails is ✗ and the profile stays unread: the ✗ row" "$OUT" \
    "${OVERLAY_DRIFT}git clone ZviBaratz/dotfiles-local failed"
hasnt "overlay: a clone that fails is ✗ and the profile stays unread: no tenants read" "$OUT" "${PROFILE_INFO}p (tenants"
check "overlay: a clone that fails is ✗ and the profile stays unread: exit 1" "$RC" 1

# The overlay's ./install fails: ✗ with its log, and no stamp, so the next run tries it again.
new_case
rm "$H/.local/state/host-sync/installed-head-dotfiles-local"; touch "$H/stub/install-fails-local"
run_level --apply
has   "overlay: a failing ./install of dotfiles-local is ✗ and writes no stamp: the ✗ row" "$OUT" \
    "${OVERLAY_DRIFT}./install failed at $(head_of "$H/.dotfiles-local" | cut -c1-7); log: ~/.local/state/host-sync/install-dotfiles-local.log"
check "overlay: a failing ./install of dotfiles-local is ✗ and writes no stamp: no stamp" \
    "$(present "$H/.local/state/host-sync/installed-head-dotfiles-local")" gone

new_case
echo '{"tenants":["personal"]}' >"$H/.dotfiles-local/hosts/p.json"
run_level --check
check "profile without quantivly: the work clones row is skipped" "$(( $(area_rows clone) + $(area_rows clones) ))" 0
rm -rf "$H/quantivly"
run_level --apply
check "profile without quantivly: --apply does not create ~/quantivly" "$(present "$H/quantivly")" gone

# The laptop's facts carry dotfiles-local's main and how far behind it the host is, like dotfiles'.
new_case
push_to ZviBaratz/dotfiles-local c.txt two
run_level --check --dotfiles-local-sha "$(overlay_main)" --dotfiles-local-behind 1
has   "dotfiles-local behind: --check ✗ with the laptop's count" "$OUT" "${OVERLAY_DRIFT}1 commits behind origin/main"
run_level --apply
check "dotfiles-local behind: --apply fast-forwards to its origin's main" "$(head_of "$H/.dotfiles-local")" "$(overlay_main)"
check "dotfiles-local behind: --apply runs its ./install once, and only its own" \
    "$(paste -sd' ' "$H/stub/install-order" 2>/dev/null)/$( { wc -l <"$H/stub/local-install-ran"; } 2>/dev/null)" local/1
check "dotfiles-local behind: the stamp records the new HEAD" \
    "$(cat "$H/.local/state/host-sync/installed-head-dotfiles-local")" "$(head_of "$H/.dotfiles-local")"

new_case
git -C "$H/.dotfiles-local" checkout -q -b feature; push_to ZviBaratz/dotfiles-local c.txt x
run_level --apply
has   "dotfiles-local off main: not touched" "$OUT" "${OVERLAY_OPER}on 'feature', not main"
check "dotfiles-local off main: not touched: still on the branch" "$(git -C "$H/.dotfiles-local" symbolic-ref --short HEAD)" feature

new_case
push_to ZviBaratz/dotfiles-local claude/CLAUDE.md upstream; echo local >"$H/.dotfiles-local/claude/CLAUDE.md"
before="$(head_of "$H/.dotfiles-local")"
run_level --apply
has   "dotfiles-local with an overlapping local edit: not merged" "$OUT" \
    "${OVERLAY_OPER}local edits to claude/CLAUDE.md that origin/main also changes; not merged"
check "dotfiles-local with an overlapping local edit: not merged: HEAD is not moved" "$(head_of "$H/.dotfiles-local")" "$before"

# Validated before any of it reaches a command, and a good value still passes.
new_case
run --check --dotfiles-local-sha "$(printf 'g%.0s' {1..40})"; bad_rc="$RC"
run_level --check --dotfiles-local-sha "$(overlay_main)"
check "a bad --dotfiles-local-sha over the wire is refused (64); a good one is not" "$bad_rc/$RC" 64/0
run --check --dotfiles-local-behind '1;x'; bad_rc="$RC"
run_level --check --dotfiles-local-sha "$(overlay_main)" --dotfiles-local-behind 0
check "a bad --dotfiles-local-behind over the wire is refused (64); a count is not" "$bad_rc/$RC" 64/0
run --check --dotfiles-behind '1;x'
check "a bad --dotfiles-behind over the wire is refused (64)" "$RC" 64

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
has   "older herdr: ✗ with both versions and what is busy" "$OUT" "0.9.0, laptop has $HV (server 0.9.0, 0 pane(s), 0 busy; --apply upgrades only when none is)"
hasnt "older herdr: --check restarts nothing" "$(calls)" "systemctl --user restart"
check "older herdr: --check leaves the binary" "$(HOME="$H" "$H/.local/bin/herdr" --version)" "herdr 0.9.0"
run_level --apply
check "older herdr: --apply installs the laptop's exact version" "$(HOME="$H" "$H/.local/bin/herdr" --version)" "herdr $HV"
has   "older herdr, no panes: the server is restarted through the unit" "$(calls)" "systemctl --user restart herdr-server.service"
has   "older herdr, no panes: ✓ restarted" "$OUT" "server restarted on $HV (0 idle pane(s) closed)"
check "older herdr: the agent skill is regenerated" "$(cat "$H/.claude/skills/herdr/SKILL.md")" "skill for $HV"
check "older herdr: the previous binary is kept" "$([[ -e "$H/.local/state/host-sync/herdr-0.9.0" ]] && echo yes || echo no)" yes
reset_calls; run_level --apply
check "second --apply after a herdr upgrade calls nothing mutating" "$(mutations)" 0
new_case
echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"; echo '{"pane_id":"w1:p1"}' >"$H/stub/panes"
run_level --apply
check "an idle shell pane (herdr recreates one): the binary is upgraded" "$(HOME="$H" "$H/.local/bin/herdr" --version)" "herdr $HV"
has   "an idle shell pane: the server restarts, and the row says it closed" "$OUT" "server restarted on $HV (1 idle pane(s) closed)"
new_case
echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"
echo '{"pane_id":"w1:p1"},{"pane_id":"w1:p2"}' >"$H/stub/panes"
echo '{"result":{"process_info":{"shell_pid":10,"foreground_process_group_id":22}}}' >"$H/stub/proc-w1:p2"
run_level --apply
check "a pane running something, but NO agent: the binary is not swapped" "$(HOME="$H" "$H/.local/bin/herdr" --version)" "herdr 0.9.0"
hasnt "a busy pane: the server is NOT restarted" "$(calls)" "systemctl --user restart"
has   "a busy pane: ⚠ says the upgrade waits, and why" "$OUT" "0.9.0 → $HV waits: 0 agent(s), 1 of 2 pane(s) busy on this host's herdr"
check "a busy pane: the upgrade waiting is a person's step, not a failure" "$RC" 0
new_case
echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"; echo '{"pane_id":"w1:p1"}' >"$H/stub/panes"
touch "$H/stub/proc-down"
run_level --apply
hasnt "a pane whose process info cannot be read counts as busy" "$(calls)" "systemctl --user restart"
new_case
echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"; touch "$H/stub/panes-down"
run_level --apply
hasnt "a pane list that cannot be read holds the upgrade" "$(calls)" "systemctl --user restart"
new_case
echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"; echo '{"pane_id":"w1:p1"}' >"$H/stub/panes"
echo '{"pane_id":"w1:p1"}' >"$H/stub/agents"
run_level --apply
has   "an agent at its prompt still holds the upgrade" "$OUT" "waits: 1 agent(s), 0 of 1 pane(s) busy"
new_case
echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"
mv "$H/.local/bin/herdr" "$C/herdr-bin"; ln -s "$C/herdr-bin" "$H/.local/bin/herdr"
run_level --apply
has   "herdr is a symlink: ⚠, never replaced" "$OUT" "is a symlink; host-sync does not replace a link"
check "herdr is a symlink: still a symlink" "$([[ -L "$H/.local/bin/herdr" ]] && echo link || echo file)" link
new_case
echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"; touch "$H/stub/skill-empty"
run_level --apply
check "an empty --skill output never replaces the agent skill" "$(cat "$H/.claude/skills/herdr/SKILL.md")" old
new_case
echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"
: >"$H/.local/state/host-sync/lock"; chmod 555 "$H/.local/state/host-sync"   # the backup copy cannot be written
run_level --apply
chmod 755 "$H/.local/state/host-sync"
has   "no backup of the old binary: ✗, not installed" "$OUT" "could not keep a copy of the 0.9.0 binary; not installed"
check "no backup of the old binary: still the old binary" "$(HOME="$H" "$H/.local/bin/herdr" --version)" "herdr 0.9.0"
new_case
echo 0.9.0 >"$H/stub/herdr-version"; echo 0.9.0 >"$H/stub/server-version"; touch "$H/stub/restart-fails"
run_level --apply
has   "server not back after the restart: ✗ prints the rollback" "$OUT" "to roll back: mv ~/.local/state/host-sync/herdr-0.9.0 ~/.local/bin/herdr"
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
has   "newer herdr on this host: never downgraded" "$OUT" "0.9.4, ahead of laptop $HV"
new_case
echo 0.9.0 >"$H/stub/server-version"
run_level --check
has   "binary current, server old: ✗ restart pending" "$OUT" "server runs 0.9.0, binary $HV: restart pending"
echo '{"pane_id":"w1:p1"}' >"$H/stub/panes"
echo '{"result":{"process_info":{"shell_pid":10,"foreground_process_group_id":22}}}' >"$H/stub/proc-w1:p1"
run_level --apply
hasnt "binary current, server old, a busy pane: no restart" "$(calls)" "systemctl --user restart"
new_case
echo 0.9.0 >"$H/stub/herdr-version"
mapfile -t F < <(facts | grep -v -e '^--herdr' -e "^$HV\$" -e "^$ARCH\$" -e "^$HSHA\$")
run --apply "${F[@]}"
has   "no laptop facts (the timer): herdr is only reported" "$OUT" "version parity is laptop-driven"
hasnt "no laptop facts: no restart" "$(calls)" "systemctl --user restart"

echo "== settings and links"
# The rows' glyph and area, as row() prints them, so a needle also pins the glyph.
SETTINGS_OK="$(printf '✓ %-14s ' settings)"; SETTINGS_DRIFT="$(printf '✗ %-14s ' settings)"
SETTINGS_OPER="$(printf '⚠ %-14s ' settings)"; SETTINGS_INFO="$(printf '· %-14s ' settings)"
LINKS_OK="$(printf '✓ %-14s ' links)"; LINKS_DRIFT="$(printf '✗ %-14s ' links)"; LINKS_OPER="$(printf '⚠ %-14s ' links)"
LINKS_AREA="$(printf '%-14s ' links)"
renderer_calls() { grep '^claude-settings-render.sh' "$H/stub/calls" | paste -sd'|'; }
ran_count() { if [[ -e "$H/stub/$1" ]]; then wc -l <"$H/stub/$1"; else echo 0; fi; }   # $1 = a stub's ran log
# What a second --apply may change besides the stub log: the state dir, and the fetch bookkeeping
# every --apply leaves in both checkouts (FETCH_HEAD, the objects dir's mtime).
leave_out_for_second_apply() {
    printf '%s\n' "$H/.local/state/host-sync" "$H/.dotfiles/.git/FETCH_HEAD" "$H/.dotfiles/.git/objects" \
        "$H/.dotfiles-local/.git/FETCH_HEAD" "$H/.dotfiles-local/.git/objects"
}

new_case
run_level --check
has   "settings: level → ✓" "$OUT" "${SETTINGS_OK}settings.json renders to itself (profile p)"
check "settings: level → ✓: the renderer is called once, with --check" "$(renderer_calls)" "claude-settings-render.sh --check"
has   "links: level → one ✓ per repo: dotfiles" "$OUT" "${LINKS_OK}dotfiles: 2 declared links in place"
has   "links: level → one ✓ per repo: dotfiles-local" "$OUT" "${LINKS_OK}dotfiles-local: 2 declared links in place"

new_case
rm "$H/.config/claude-host-profile"
run_level --apply
has   "settings: no marker → · and the renderer is not called: the · row" "$OUT" \
    "${SETTINGS_INFO}no host profile; settings.json is not rendered here"
check "settings: no marker → · and the renderer is not called: not even by --apply" "$(renderer_calls)" ""

new_case
echo 1 >"$H/stub/render-rc"
run_level --check
has   "settings: drift → ✗ in --check, --apply renders then re-checks: the ✗ row" "$OUT" \
    "${SETTINGS_DRIFT}settings.json differs from its render"
check "settings: drift → ✗ in --check, --apply renders then re-checks: --check renders nothing, exit 1" \
    "$(renderer_calls)/$RC" "claude-settings-render.sh --check/1"
reset_calls; run_level --apply
check "settings: drift → ✗ in --check, --apply renders then re-checks: --check, --apply, --check" "$(renderer_calls)" \
    "claude-settings-render.sh --check|claude-settings-render.sh --apply|claude-settings-render.sh --check"
has   "settings: drift → ✗ in --check, --apply renders then re-checks: the ✓ row" "$OUT" "${SETTINGS_OK}rendered (profile p)"
check "settings: drift → ✗ in --check, --apply renders then re-checks: exit 0" "$RC" 0

new_case
echo 1 >"$H/stub/render-rc"; touch "$H/stub/render-apply-no-op"
run_level --apply
has   "settings: an --apply that leaves drift is ✗" "$OUT" \
    "${SETTINGS_DRIFT}settings.json still differs from its render after claude-settings-render --apply"
echo 1 >"$H/stub/render-rc"; touch "$H/stub/render-apply-fails"
reset_calls; run_level --apply
has   "settings: an --apply that cannot run → ⚠ with its first line, not re-checked" "$OUT" \
    "${SETTINGS_OPER}claude-settings-render could not run: claude-settings-render: could not back up settings.json"
check "settings: an --apply that cannot run → ⚠ with its first line, not re-checked: the calls" "$(renderer_calls)" \
    "claude-settings-render.sh --check|claude-settings-render.sh --apply"

new_case
echo 2 >"$H/stub/render-rc"
run_level --apply
has   "settings: a renderer that cannot run → ⚠ with its first line, no --apply" "$OUT" \
    "${SETTINGS_OPER}claude-settings-render could not run: claude-settings-render: settings.json is a symlink"
check "settings: a renderer that cannot run → ⚠ with its first line, no --apply: only --check, exit 0" \
    "$(renderer_calls)/$RC" "claude-settings-render.sh --check/0"

new_case
rm "$H/.dotfiles/scripts/claude-settings-render.sh"
run_level --check
has   "settings: a renderer that is not there → ⚠ could not run (exit 127)" "$OUT" \
    "${SETTINGS_OPER}claude-settings-render could not run (exit 127)"

new_case
rm -rf "$H/.dotfiles-local"
run_level --check
check "links: dotfiles-local absent → no dotfiles-local links row: the public one's only" "$(area_rows links)" 1
hasnt "links: dotfiles-local absent → no dotfiles-local links row" "$OUT" "${LINKS_AREA}dotfiles-local:"

new_case
rm "$H/.x"
run_level --check
has   "links: a missing link is drift; --apply runs that repo's ./install and re-checks: the ✗ row" "$OUT" \
    "${LINKS_DRIFT}dotfiles: 1 link(s) to fix: ~/.x"
check "links: a missing link is drift; --apply runs that repo's ./install and re-checks: --check runs no ./install, exit 1" \
    "$(ran_count install-ran)/$(present "$H/.x")/$RC" 0/gone/1
run_level --apply
check "links: a missing link is drift; --apply runs that repo's ./install and re-checks: that repo's ./install, once" \
    "$(ran_count install-ran)/$(ran_count local-install-ran)" 1/0
check "links: a missing link is drift; --apply runs that repo's ./install and re-checks: the link" \
    "$(readlink "$H/.x")" "$H/.dotfiles/config/x"
has   "links: a missing link is drift; --apply runs that repo's ./install and re-checks: the ✓ row" "$OUT" \
    "${LINKS_OK}dotfiles: 1 link(s) relinked"
check "links: a missing link is drift; --apply runs that repo's ./install and re-checks: exit 0" "$RC" 0
mapfile -t LEAVE_OUT < <(leave_out_for_second_apply)
reset_calls; before="$(snapshot "${LEAVE_OUT[@]}")"
run_level --apply
check "links: a second --apply after a relink runs no ./install, nothing mutating" \
    "$(ran_count install-ran)/$(mutations)" 1/0
check "links: a second --apply after a relink changes no file" \
    "$(diff <(echo "$before") <(snapshot "${LEAVE_OUT[@]}") | head -n 5)" ""

new_case
rm "$H/.x"; cp "$H/.dotfiles/config/x" "$H/.x"
run_level --check
has   "links: a regular file with identical content is drift ./install fixes: the ✗ row" "$OUT" \
    "${LINKS_DRIFT}dotfiles: 1 link(s) to fix: ~/.x"
run_level --apply
check "links: a regular file with identical content is drift ./install fixes: relinked" "$(readlink "$H/.x")" "$H/.dotfiles/config/x"

# An older backup is already beside it, from some earlier relink: the row names this run's.
new_case
rm "$H/.x"; echo edited >"$H/.x"; echo older >"$H/.x.dotbot-backup.20200101-000000"
run_level --check
has   "links: a regular file with other content is relinked and its backup named: the ✗ row" "$OUT" \
    "${LINKS_DRIFT}dotfiles: ~/.x is a regular file whose content differs from the repo; ./install backs it up beside it and relinks"
run_level --apply
backups=("$H"/.x.dotbot-backup.*); newest_backup="${backups[-1]}"
check "links: a regular file with other content is relinked and its backup named: the link" "$(readlink "$H/.x")" "$H/.dotfiles/config/x"
check "links: a regular file with other content is relinked and its backup named: a new backup, with the old content" \
    "${#backups[@]}/$(cat "$newest_backup")" 2/edited
has   "links: a regular file with other content is relinked and its backup named: the ✓ row names the newest" "$OUT" \
    "${LINKS_OK}dotfiles: 1 link(s) relinked; the old ~/.x is kept as ~${newest_backup#"$H"}"

new_case
rm "$H/.dotfiles/config/y.conf"
run_level --apply
has   "links: a source missing from the checkout is a person's step: ⚠ naming the source" "$OUT" \
    "${LINKS_OPER}dotfiles: config/y.conf is declared but not in the checkout"
check "links: a source missing from the checkout is a person's step: ./install not run for it alone, exit 0" \
    "$(ran_count install-ran)/$RC" 0/0

new_case
rm "$H/.dotfiles/install.conf.yaml"
run_level --apply
has   "links: a checker that cannot run → ⚠ (exit 2)" "$OUT" "${LINKS_OPER}dotfiles: check-links could not run (exit 2)"
has   "links: a checker that cannot run → ⚠ (exit 2): its reason on the line below" "$OUT" \
    "$(printf '\n        ')COULD NOT RUN: $H/.dotfiles/install.conf.yaml is missing or unreadable"
check "links: a checker that cannot run → ⚠ (exit 2): no ./install, exit 0" "$(ran_count install-ran)/$RC" 0/0
rm "$H/.dotfiles/scripts/check-links.sh"
run_level --check
has   "links: a checker that is not there → ⚠ (exit 127)" "$OUT" "${LINKS_OPER}dotfiles: check-links could not run (exit 127)"

# A state added to the checker after host-sync: exit 1 with nothing this script can classify.
new_case
printf '#!/bin/sh\nprintf "a-new-state\\t~/.x\\tconfig/x\\n"\nexit 1\n' >"$H/.dotfiles/scripts/check-links.sh"
run_level --check
has   "links: a fault in a state host-sync does not know is ⚠, never ✓" "$OUT" \
    "${LINKS_OPER}dotfiles: check-links reports a fault in a state host-sync does not know (exit 1)"

new_case
rm "$H/.x"; ln -sfn "$C/elsewhere" "$H/.config/fixture/y.conf"; rm "$H/.claude/CLAUDE.md"
run_level --check
has   "links: several faults in one repo are one ✗ row" "$OUT" \
    "${LINKS_DRIFT}dotfiles: 2 link(s) to fix: ~/.x, ~/.config/fixture/y.conf"
run_level --apply
check "links: ./install runs once per repo per run even with several faults" \
    "$(ran_count install-ran)/$(ran_count local-install-ran)" 1/1
has   "links: ./install runs once per repo per run even with several faults: both relinked" "$OUT" \
    "${LINKS_OK}dotfiles: 2 link(s) relinked"

new_case
rm "$H/.x"; touch "$H/stub/install-fails"
run_level --apply
has   "links: an ./install that leaves a link out of place is ✗, naming its log" "$OUT" \
    "${LINKS_DRIFT}dotfiles: still 1 to fix after ./install (~/.x); log: ~/.local/state/host-sync/install-links-dotfiles.log"
check "links: an ./install that leaves a link out of place is ✗, naming its log: exit 1" "$RC" 1

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
has   "superseded plugin: ✓ disabled, read back as false (jq // treats false as missing)" "$OUT" "✓ plugin         quantivly-pr-conventions@quantivly disabled (superseded)"
check "superseded plugin: --apply exits 0" "$RC" 0
check "superseded plugin: set false in settings.json" "$(jq -r '.enabledPlugins["quantivly-pr-conventions@quantivly"]' "$H/.claude/settings.json")" false
check "superseded plugin: the rest of settings.json survives" "$(jq -r .theme "$H/.claude/settings.json")" dark
check "superseded plugin: a backup is kept" "$([[ -e "$H/.local/state/host-sync/settings.json.before-host-sync" ]] && echo yes || echo no)" yes
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
has   "slack needs a sign-in: ⚠ with the /mcp step" "$OUT" "⚠ mcp            slack needs a sign-in on this host"
has   "a sign-in step is counted as a person's step" "$OUT" "1 step(s) need a person"
check "a sign-in step alone does not fail --check" "$RC" 0
reset_calls; run_level --check --no-mcp
hasnt "--no-mcp: claude mcp list is not run" "$(calls)" "claude mcp list"
new_case
: >"$H/.zshrc.local"
run_level --check
has   "no LINEAR_API_KEY on this host: ⚠" "$OUT" "LINEAR_API_KEY is not in this host's ~/.zshrc.local"
mapfile -t F < <(facts)
OUT="$(LINEAR_API_KEY=inherited HOME="$H" PATH="/usr/local/bin:/usr/bin:/bin" bash "$SUT" --here --check "${F[@]}" 2>&1)"
has   "a key in the CALLER's environment does not read as in the file" "$OUT" "LINEAR_API_KEY is not in this host's ~/.zshrc.local"

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
new_case
HOST_SYNC_DOTFILES_LOCAL_REPO='x;rm -rf /' run --check
check "an unsafe HOST_SYNC_DOTFILES_LOCAL_REPO is refused (64)" "$RC" 64

echo "== timer"
# The timer row's glyph and area, as row() prints them, so a needle also pins ✓ against ✗ and ·.
TIMER_OK="$(printf '✓ %-14s ' timer)"; TIMER_DRIFT="$(printf '✗ %-14s ' timer)"; TIMER_INFO="$(printf '· %-14s ' timer)"
# What follows "arms it" on the information row; the whole line when nothing does.
info_suffix() {
    local line
    while IFS= read -r line; do
        [[ "$line" == *"${TIMER_INFO}not armed on this host"* ]] && printf '%s' "${line#*from the laptop arms it }"
    done <<<"$OUT"
}
new_case
rm "$H/.config/host-sync/armed"; timer_off host-sync.timer
reset_calls; run_level --apply
check "unarmed dev, --apply without --arm: refused (2)" "$RC" 2
check "unarmed dev: nothing mutating was called" "$(mutations)" 0
has   "unarmed: the refusal names the command that arms it, with --host" "$OUT" "scripts/host-sync --host <alias> --apply"
run_level --check
has   "unarmed host: --check is information" "$OUT" \
    "${TIMER_INFO}not armed on this host (no ~/.config/host-sync/armed); host-sync --host <alias> --apply from the laptop arms it"
check "unarmed host: --check is information, exit 0" "$RC" 0
hasnt "unarmed host, timer not enabled: no skipped-unit note" "$OUT" "fires into a skipped unit"
run_level --apply --arm
check "--arm: the marker is written" "$([[ -e "$H/.config/host-sync/armed" ]] && echo yes || echo no)" yes
has   "--arm: enable, never reenable" "$(calls)" "systemctl --user enable --now host-sync.timer"
hasnt "--arm: no reenable or disable" "$(grep -E 'reenable|disable' "$H/stub/calls")" "host-sync.timer"
new_case
rm "$H/.config/host-sync/armed"
run_level --check
check "unarmed host with an enabled timer: the information row names it" "$(info_suffix)" \
    "(is-enabled=enabled, is-active=active: a timer that fires into a skipped unit)"
new_case
echo inactive >"$H/stub/active-host-sync.timer"
run_level --check
has   "armed marker, timer inactive: ✗ in --check" "$OUT" \
    "${TIMER_DRIFT}armed (marker present) but host-sync.timer is-enabled=enabled, is-active=inactive"
reset_calls; run_level --apply
has   "armed marker, timer inactive: --apply without --arm re-arms" "$(calls)" "systemctl --user enable --now host-sync.timer"
check "armed marker, timer inactive: --apply without --arm re-arms, exit 0" "$RC" 0
new_case
rm "$H/.config/host-sync/armed"; timer_off host-sync.timer; : >"$H/.config/host-sync/disarmed"
reset_calls; run_level --apply --arm
check "disarmed by hand: --arm does not write the marker" "$([[ -e "$H/.config/host-sync/armed" ]] && echo yes || echo no)" no
hasnt "disarmed by hand: the timer is not enabled" "$(calls)" "enable --now host-sync.timer"
has   "disarmed by hand: · says so, and it is not drift" "$OUT" "· timer          disarmed by hand"
check "disarmed by hand: the rest still syncs, and exits 0" "$RC" 0

echo "== timer: the arming moves from dev-sync.timer to host-sync.timer"
# The first --apply after the rename. dev-sync.service runs only while ~/.config/dev-sync/armed
# exists, so that marker moves only once host-sync.timer reads back enabled and active, and every
# failure leaves dev-sync.timer, its .wants link and its marker exactly as found.
legacy_case
before="$(snapshot)"
run_level --check
check "legacy: --check names the move and changes nothing: exit 1" "$RC" 1
has   "legacy: --check names the move and changes nothing: the ✗ row" "$OUT" \
    "${TIMER_DRIFT}dev-sync.timer is armed; --apply moves the arming to host-sync.timer"
hasnt "legacy: --check names the move and changes nothing: the install stamp is read where it is" "$OUT" "./install has not run"
check "legacy: --check names the move and changes nothing: no file changes" "$(diff <(echo "$before") <(snapshot) | head -n 5)" ""
reset_calls; run_level --apply
check "legacy: --apply without --arm is not refused" "$RC" 0
check "legacy: the state dir is moved under the lock and the install stamp carried: the stamp" \
    "$(cat "$H/.local/state/host-sync/installed-head" 2>/dev/null)" "$(head_of "$H/.dotfiles")"
check "legacy: the state dir is moved under the lock and the install stamp carried: the old dir is gone" \
    "$(present "$H/.local/state/dev-sync")" gone
check "legacy: the state dir is moved under the lock and the install stamp carried: ./install is not re-run" \
    "$(present "$H/stub/install-ran")" gone
has   "legacy: host-sync.timer is enabled with enable --now, never reenable" "$(calls)" "systemctl --user enable --now host-sync.timer"
hasnt "legacy: host-sync.timer is enabled with enable --now, never reenable: no reenable or disable of any timer" \
    "$(grep -E 'reenable|disable' "$H/stub/calls")" ".timer"
check "legacy: enable, read back, then stop, in that order" "$(arming_order)" "enable, read back, then stop"
check "legacy: the marker moves only after the new timer reads back armed: ~/.config/host-sync/armed" "$(armed_where)" host-sync
check "legacy: the marker moves only after the new timer reads back armed: ~/.config/dev-sync is removed" \
    "$(present "$H/.config/dev-sync")" gone
has   "legacy: dev-sync.timer is stopped and its .wants link removed: the stop" "$(calls)" "systemctl --user stop dev-sync.timer"
check "legacy: dev-sync.timer is stopped and its .wants link removed: the link" "$(present "$WANTS/dev-sync.timer")" gone
check "legacy: dev-sync.timer is stopped and its .wants link removed: daemon-reload after it" "$(reload_after_stop)" after
check "legacy: the unit link of dev-sync.timer is left" "$(present "$H/.config/systemd/user/dev-sync.timer")" present
has   "legacy: ✓ says the arming moved" "$OUT" "${TIMER_OK}arming moved from dev-sync.timer to host-sync.timer"
# Left out besides the state dir: every --apply fetches origin main into both checkouts, and git's
# own bookkeeping for that (FETCH_HEAD, the objects dir's mtime) is not a change to the host.
SECOND_APPLY_LEAVE_OUT=("$H/.local/state/host-sync" "$H/.dotfiles/.git/FETCH_HEAD" "$H/.dotfiles/.git/objects"
    "$H/.dotfiles-local/.git/FETCH_HEAD" "$H/.dotfiles-local/.git/objects")
reset_calls; before="$(snapshot "${SECOND_APPLY_LEAVE_OUT[@]}")"
run_level --apply
check "legacy: a second --apply calls nothing mutating" "$(mutations)" 0
check "legacy: a second --apply changes no file" "$(diff <(echo "$before") <(snapshot "${SECOND_APPLY_LEAVE_OUT[@]}") | head -n 5)" ""

# The lock is taken in the legacy dir, before the move: a rename keeps the inode, so the host's own
# tick holding it there refuses this run, and nothing has moved when it does.
legacy_case
LEGACY_LOCK="$H/.local/state/dev-sync/lock"
exec 8>"$LEGACY_LOCK"; flock -n 8 || fatal "could not take $LEGACY_LOCK for the legacy lock row"
reset_calls; run_level --apply
exec 8>&-
check "legacy: a run that cannot take the lock moves nothing: exit 2" "$RC" 2
has   "legacy: a run that cannot take the lock moves nothing: refused by the lock" "$OUT" "another run holds"
check "legacy: a run that cannot take the lock moves nothing: the marker" "$(armed_where)" dev-sync
check "legacy: a run that cannot take the lock moves nothing: the state dir" "$(present "$H/.local/state/dev-sync")" present
hasnt "legacy: a run that cannot take the lock moves nothing: no enable" "$(calls)" "systemctl --user enable"

legacy_case
rm "$H/.config/systemd/user/host-sync.timer"
reset_calls; run_level --apply
has   "legacy: when the new timer cannot be armed the old one is left armed: the ✗ row" "$OUT" \
    "${TIMER_DRIFT}host-sync.timer is not linked (./install has not run for a commit that has it); dev-sync.timer left armed"
hasnt "legacy: when the new timer cannot be armed the old one is left armed: no stop" "$(calls)" "stop dev-sync.timer"
check "legacy: when the new timer cannot be armed the old one is left armed: the .wants link" "$(present "$WANTS/dev-sync.timer")" present
check "legacy: when the new timer cannot be armed the old one is left armed: the marker" "$(present "$H/.config/dev-sync/armed")" present

legacy_case
touch "$H/stub/enable-fails"
reset_calls; run_level --apply
has   "legacy: an enable that fails leaves the old timer and the marker in place: the ✗ row" "$OUT" \
    "${TIMER_DRIFT}host-sync.timer could not be armed (is-enabled=disabled, is-active=inactive); dev-sync.timer left armed"
hasnt "legacy: an enable that fails leaves the old timer and the marker in place: no stop" "$(calls)" "stop dev-sync.timer"
check "legacy: an enable that fails leaves the old timer and the marker in place: the .wants link" "$(present "$WANTS/dev-sync.timer")" present
check "legacy: an enable that fails leaves the old timer and the marker in place: the marker" "$(present "$H/.config/dev-sync/armed")" present

# host-sync.timer is already live, but the new marker dir cannot be written: the marker cannot
# move, so dev-sync.timer keeps its own and is not stopped.
legacy_case
stub_timer_live host-sync.timer
mkdir "$H/.config/host-sync"; chmod 555 "$H/.config/host-sync"
reset_calls; run_level --apply
chmod 755 "$H/.config/host-sync"
has   "legacy: a marker that cannot move leaves dev-sync.timer armed: the ✗ row" "$OUT" \
    "${TIMER_DRIFT}~/.config/host-sync/armed could not be written; dev-sync.timer left armed"
hasnt "legacy: a marker that cannot move leaves dev-sync.timer armed: no stop" "$(calls)" "stop dev-sync.timer"
check "legacy: a marker that cannot move leaves dev-sync.timer armed: its marker and .wants link" \
    "$(armed_where)/$(present "$WANTS/dev-sync.timer")" dev-sync/present

# An earlier run armed host-sync.timer and died before it stopped dev-sync.timer.
legacy_case
stub_timer_live host-sync.timer
reset_calls; run_level --apply
has   "legacy: both timers enabled (half migrated): --apply finishes the move: the stop" "$(calls)" "systemctl --user stop dev-sync.timer"
check "legacy: both timers enabled (half migrated): --apply finishes the move: the .wants link" "$(present "$WANTS/dev-sync.timer")" gone
check "legacy: both timers enabled (half migrated): --apply finishes the move: the marker" "$(armed_where)" host-sync
hasnt "legacy: both timers enabled (half migrated): --apply finishes the move: no second enable" "$(calls)" "enable --now"

# dev-sync.timer already pruned, its marker left behind: the marker moves once host-sync.timer is
# live, whether it already was (state 3) or this run armed it (state 4).
legacy_case
timer_off dev-sync.timer; stub_timer_live host-sync.timer
run_level --apply
check "legacy: a marker left in the old dir moves once host-sync.timer is live: already live" "$(armed_where)" host-sync
legacy_case
timer_off dev-sync.timer
run_level --apply
check "legacy: a marker left in the old dir moves once host-sync.timer is live: armed by this run" "$(armed_where)" host-sync

# State 4 again, but the enable fails. arm_timer writes the new marker before it enables (the new
# service's condition must hold before its timer can fire), so ~/.config/host-sync/armed exists
# either way. The legacy marker is what must stay until the timer reads back armed (H2).
legacy_case
timer_off dev-sync.timer; touch "$H/stub/enable-fails"
run_level --apply
has   "legacy: a failed arm in state 4 leaves a legacy marker in place: the ✗ row" "$OUT" \
    "${TIMER_DRIFT}arming failed: is-enabled=disabled, is-active=inactive"
check "legacy: a failed arm in state 4 leaves a legacy marker in place: the legacy marker stays" "$(armed_where)" both
rm "$H/stub/enable-fails"
run_level --apply
check "legacy: a failed arm in state 4 leaves a legacy marker in place: the next --apply moves it" \
    "$(armed_where)/$(present "$H/.config/dev-sync")" host-sync/gone

legacy_case
rm "$H/.config/dev-sync/armed"; : >"$H/.config/dev-sync/disarmed"; timer_off dev-sync.timer
run_level --check
has   "legacy: a disarmed legacy host reads disarmed in --check" "$OUT" "${TIMER_INFO}disarmed by hand"
hasnt "legacy: a disarmed legacy host reads disarmed in --check: not the not-armed text" "$OUT" "not armed on this host"
check "legacy: a disarmed legacy host reads disarmed in --check: exit 0" "$RC" 0
reset_calls; run_level --apply --arm
check "legacy: --apply --arm on a disarmed legacy host writes no marker and moves the disarmed file: moved" \
    "$(present "$H/.config/host-sync/disarmed")/$(present "$H/.config/dev-sync")" present/gone
check "legacy: --apply --arm on a disarmed legacy host writes no marker and moves the disarmed file: no marker" "$(armed_where)" none
hasnt "legacy: --apply --arm on a disarmed legacy host writes no marker and moves the disarmed file: no enable" "$(calls)" "enable --now"

legacy_case
mkdir "$H/.config/host-sync"
run_level --apply
check "legacy: an existing host-sync dir does not strand the legacy marker: dev-sync/ is gone" "$(present "$H/.config/dev-sync")" gone
# Its exact contents: a directory mv would nest dev-sync/ inside it.
check "legacy: an existing host-sync dir does not strand the legacy marker: host-sync/ holds armed alone" \
    "$(find "$H/.config/host-sync" -mindepth 1 -printf '%P ')" "armed "

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
FACTS_OUT="$(HOME="$L" PATH="/usr/local/bin:/usr/bin:/bin" HOST_SYNC_DOTFILES_REMOTE="file://$GH/quantivly/dotfiles.git" \
    HOST_SYNC_GITHUB_BASE="file://$GH" bash "$SUT" --host dev --print-facts 2>&1)"
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
E2E="$(HOME="$L" PATH="/usr/local/bin:/usr/bin:/bin" HOST_SYNC_SSH="$C/fakessh" HOST_SYNC_NO_SCOPE=1 \
    HOST_SYNC_DOTFILES_REMOTE="file://$GH/quantivly/dotfiles.git" HOST_SYNC_GITHUB_BASE="file://$GH" \
    HOST_SYNC_NPM_URL="file://$C/npm.json" bash "$SUT" --host dev --check 2>&1)"; E2E_RC=$?
check "end to end --check: exit 1 on drift" "$E2E_RC" 1
has   "end to end --check: the laptop's version reached dev" "$E2E" "2.1.272, laptop has $V_LAPTOP"
has   "end to end --check: a laptop-only clone reads as missing" "$E2E" "Gamma missing (laptop: quantivly/gamma)"
E2E="$(HOME="$L" PATH="/usr/local/bin:/usr/bin:/bin" HOST_SYNC_SSH="$C/fakessh" HOST_SYNC_NO_SCOPE=1 \
    HOST_SYNC_DOTFILES_REMOTE="file://$GH/quantivly/dotfiles.git" HOST_SYNC_GITHUB_BASE="file://$GH" \
    HOST_SYNC_NPM_URL="file://$C/npm.json" bash "$SUT" --host dev --apply 2>&1)"; E2E_RC=$?
has   "end to end --apply: claude raised to the laptop's" "$(cat "$H/stub/claude-version")" "$V_LAPTOP"
has   "end to end --apply: the clone failure is reported, not hidden" "$E2E" "Gamma: git clone quantivly/gamma failed"
check "end to end --apply: so it exits 1" "$E2E_RC" 1
# Reachable, and the dotfiles probe answers; only the run itself dies, as an OOM kill would.
# shellcheck disable=SC2016  # expanded by the inner shell, deliberately
printf '#!/usr/bin/env bash\n[[ "$*" == *"bash -s"* ]] && { cat >/dev/null; exit 137; }\nexec "%s" "$@"\n' "$C/fakessh" >"$C/oomssh"
chmod +x "$C/oomssh"
OUT="$(HOME="$L" PATH="/usr/local/bin:/usr/bin:/bin" HOST_SYNC_SSH="$C/oomssh" HOST_SYNC_NO_SCOPE=1 \
    HOST_SYNC_DOTFILES_REMOTE="file://$GH/quantivly/dotfiles.git" HOST_SYNC_GITHUB_BASE="file://$GH" \
    bash "$SUT" --host dev --check 2>&1)"; RC=$?
check "the remote run killed (137): exit 2, never read as drift" "$RC" 2
# host-sync's own ssh never forwards the laptop's agent, whatever ssh_config says: a forwarded
# agent's socket on dev is usable by any process there while the run is open (review 3, S2). The
# default ssh command, through a stub that logs its argv and answers as an unreachable host.
mkdir -p "$C/sshbin"; printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\nexit 255\n' "$C/ssh-argv" >"$C/sshbin/ssh"
chmod +x "$C/sshbin/ssh"
env -u HOST_SYNC_SSH HOME="$L" PATH="$C/sshbin:/usr/local/bin:/usr/bin:/bin" HOST_SYNC_NO_SCOPE=1 \
    HOST_SYNC_DOTFILES_REMOTE="file://$GH/quantivly/dotfiles.git" HOST_SYNC_GITHUB_BASE="file://$GH" \
    bash "$SUT" --host dev --check >/dev/null 2>&1 </dev/null
check "host-sync's ssh never forwards an agent (-o ForwardAgent=no)" \
    "$(grep -c -e '-o ForwardAgent=no' "$C/ssh-argv" 2>/dev/null | awk '{print ($1 > 0)}')" 1
has   "the remote run killed: says so" "$OUT" "ended with status 137"
# dotfiles-local on the laptop: its main's sha is a fact, and how far the host is behind it is
# counted from the laptop's own objects, off the second line of the one ssh probe for both heads.
push_to ZviBaratz/dotfiles-local c.txt laptop
git clone -q "$GH/ZviBaratz/dotfiles-local.git" "$L/.dotfiles-local"
overlay_facts() {   # what the laptop would send, as --print-facts prints it
    HOME="$L" PATH="/usr/local/bin:/usr/bin:/bin" HOST_SYNC_DOTFILES_REMOTE="file://$GH/quantivly/dotfiles.git" \
        HOST_SYNC_GITHUB_BASE="file://$GH" HOST_SYNC_DOTFILES_LOCAL_REMOTE="file://$GH/ZviBaratz/dotfiles-local.git" \
        bash "$SUT" --host dev --print-facts 2>&1
}
has   "facts: the laptop sends dotfiles-local's main sha when it has the checkout" "$(overlay_facts)" \
    "--dotfiles-local-sha $(overlay_main)"
E2E="$(HOME="$L" PATH="/usr/local/bin:/usr/bin:/bin" HOST_SYNC_SSH="$C/fakessh" HOST_SYNC_NO_SCOPE=1 \
    HOST_SYNC_DOTFILES_REMOTE="file://$GH/quantivly/dotfiles.git" HOST_SYNC_GITHUB_BASE="file://$GH" \
    HOST_SYNC_DOTFILES_LOCAL_REMOTE="file://$GH/ZviBaratz/dotfiles-local.git" \
    HOST_SYNC_NPM_URL="file://$C/npm.json" bash "$SUT" --host dev --check 2>&1)"
has   "end to end --check: the laptop counts how far dotfiles-local is behind" "$E2E" \
    "$(printf '✗ %-14s ' dotfiles-local)1 commits behind origin/main"
rm -rf "$L/.dotfiles-local"
hasnt "facts: the laptop sends dotfiles-local's main sha when it has the checkout: without it, none" "$(overlay_facts)" \
    "--dotfiles-local-sha"

echo "== --host is required, and the dev-sync wrapper"
# Every row runs under the fixture HOME with the local remotes, so none reaches the network or an agent.
WRAPPER_ENV=(HOME="$L" PATH="/usr/local/bin:/usr/bin:/bin" HOST_SYNC_NO_SCOPE=1
    HOST_SYNC_DOTFILES_REMOTE="file://$GH/quantivly/dotfiles.git" HOST_SYNC_GITHUB_BASE="file://$GH"
    HOST_SYNC_NPM_URL="file://$C/npm.json")
# A stub ssh that records its first argument (the host alias) and answers as an unreachable host.
# shellcheck disable=SC2016  # expanded by the stub itself, deliberately
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >>"%s"\nexit 255\n' "$C/wrapper-ssh-hosts" >"$C/wrapper-ssh"
chmod +x "$C/wrapper-ssh"
# Without --host or --here nothing may reach ssh at all: the stub and no agent make a regression visible.
: >"$C/wrapper-ssh-hosts"
OUT="$(env -u SSH_AUTH_SOCK "${WRAPPER_ENV[@]}" HOST_SYNC_SSH="$C/wrapper-ssh" bash "$SUT" --check 2>&1 </dev/null)"; RC=$?
check "host-sync with neither --host nor --here: usage (64)" "$RC" 64
has   "host-sync with neither --host nor --here: says --host is required" "$OUT" "--host <ssh alias> is required"
check "host-sync with neither --host nor --here: ssh is never run" "$(cat "$C/wrapper-ssh-hosts")" ""
# An alias that ssh would read as an option: refused before any ssh call.
: >"$C/wrapper-ssh-hosts"
env -u SSH_AUTH_SOCK "${WRAPPER_ENV[@]}" HOST_SYNC_SSH="$C/wrapper-ssh" bash "$SUT" --host -oProxyCommand=x --check \
    >/dev/null 2>&1 </dev/null; RC=$?
check "an unsafe --host alias is refused (64) without an ssh call" "$RC/$(cat "$C/wrapper-ssh-hosts")" "64/"
OUT="$(env -u SSH_AUTH_SOCK "${WRAPPER_ENV[@]}" bash "$SUT" --help 2>&1 </dev/null)"; RC=$?
check "host-sync --help: exit 0" "$RC" 0
has   "host-sync --help: prints the usage" "$OUT" "--print-facts"
wrapper_hosts_after() {   # $@ = the wrapper's arguments; prints the aliases the stub ssh saw
    : >"$C/wrapper-ssh-hosts"
    env "${WRAPPER_ENV[@]}" HOST_SYNC_SSH="$C/wrapper-ssh" bash "$WRAPPER" "$@" >/dev/null 2>&1 </dev/null
    cat "$C/wrapper-ssh-hosts"
}
has "the dev-sync wrapper runs host-sync against dev" "$(wrapper_hosts_after --check)" "dev"
OUT="$(env -u SSH_AUTH_SOCK HOME="$H" HOST_SYNC_GITHUB_BASE="file://$GH" HOST_SYNC_NPM_URL="file://$C/npm.json" \
    HOST_SYNC_HERDR_RELEASES="file://$C/releases" HOST_SYNC_PROC="$C/proc" XDG_RUNTIME_DIR="$C/run" \
    PATH="/usr/local/bin:/usr/bin:/bin" bash "$WRAPPER" --here --check 2>&1 </dev/null)"
has "the wrapper passes --here through unchanged" "$OUT" "host-sync check on"
has "the wrapper honours an explicit --host" "$(wrapper_hosts_after --host other --check)" "other"
has "the wrapper honours an explicit --host=" "$(wrapper_hosts_after --host=other --check)" "other"

echo "== the long-lived Claude token"
new_case
run_level --check
check "token level: --check exits 0" "$RC" 0
has   "token level: logged in by the token, said so" "$OUT" "claude uses the long-lived token (oauth_token)"
has   "token level: its date and age are reported" "$OUT" "token stored $(date -d '10 days ago' +%F), 10 day(s) old"
has   "token level: the running Claude process carries it" "$OUT" "all 1 Claude process(es) carry the token"
hasnt "token level: the token value is never printed" "$OUT" "$FAKE_TOK"
check "token level: every claude call host-sync makes carries the token" \
    "$(wc -l <"$H/stub/calls-with-token")" "$(grep -c '^claude ' "$H/stub/calls")"
has   "token level: auth status is among them" "$(cat "$H/stub/calls-with-token")" "claude auth status --json"

new_case
rm -rf "$H/.config/claude-oauth"
CLAUDE_CODE_OAUTH_TOKEN="$FAKE_TOK" run_level --check
check "no token file: still exit 0 (a person's step, not drift)" "$RC" 0
has   "no token file: only the shared /login, warned" "$OUT" "only the shared /login (claude.ai)"
check "no token file: a token the CALLER exported is not used" \
    "$(ntok)" 0
hasnt "no token file: no age row" "$OUT" "token stored"

new_case
rm -rf "$H/.config/claude-oauth"; touch "$H/stub/no-login"
run_level --check
has   "not logged in: said so" "$OUT" "Claude is not logged in on this host (none)"

new_case
touch "$H/stub/auth-fails"
run_level --check
has   "auth status gives no answer: unknown, not 'not logged in'" "$OUT" "claude auth status gave no answer"

new_case
chmod 000 "$H/.config/claude-oauth/token.env"
run_level --check
has   "an unreadable token file: named as unreadable" "$OUT" "token.env is not readable by"

new_case
touch "$H/stub/ignores-token"
run_level --check
has   "a stored token claude does not use: said so" "$OUT" "a token is stored, but claude reports claude.ai"

new_case
chmod 644 "$H/.config/claude-oauth/token.env"
run_level --check
has   "token file mode 644: warned with the fix" "$OUT" "the token file is mode 644, not 600"

new_case
printf 'export CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$FAKE_TOK" >"$H/.config/claude-oauth/token.env"
run_level --check
has   "a malformed token line: warned" "$OUT" "holds no CLAUDE_CODE_OAUTH_TOKEN line"
check "a malformed token line: not loaded" "$(ntok)" 0
hasnt "a malformed token line: its value is never printed" "$OUT" "$FAKE_TOK"

new_case
rm "$H/.config/claude-oauth/created"
run_level --check
has   "no created date: expiry unknown, warned" "$OUT" "has no readable date"

new_case
date -d '334 days ago' +%F >"$H/.config/claude-oauth/created"
run_level --check
has   "334 days old: still ✓" "$OUT" "334 day(s) old"
new_case
date -d '335 days ago' +%F >"$H/.config/claude-oauth/created"
run_level --check
has   "335 days old: a month's warning" "$OUT" "expires in about 30 day(s)"
new_case
date -d '365 days ago' +%F >"$H/.config/claude-oauth/created"
run_level --check
has   "365 days old: expired on the day" "$OUT" "is a year old and has expired"
new_case
date -d '30 days' +%F >"$H/.config/claude-oauth/created"
run_level --check
has   "a date in the future: expiry unknown, warned" "$OUT" "is in the future"
new_case
date -d '400 days ago' +%F >"$H/.config/claude-oauth/created"
run_level --check
has   "400 days old: expired" "$OUT" "is a year old and has expired"

new_case
fake_proc 4102 claude 0; fake_proc 4103 zsh 0; fake_proc 4104 2.1.296 0
run_level --check
has   "Claude processes without the token, a versioned one included: counted, others ignored" "$OUT" \
    "2 of 3 Claude process(es) started without the token"
new_case
rm -rf "$C/proc"
run_level --check
has   "no Claude process: information only" "$OUT" "no Claude process running"

new_case
mkdir "$H/.clauth"
run_level --check
has   "clauth host: the auth rows do not apply" "$OUT" \
    "$(printf '· %-14s ' auth)accounts are managed by clauth on this host; the long-lived-token rows do not apply"
hasnt "clauth host: the auth rows do not apply: no claude auth call" "$(calls)" "claude auth"
check "clauth host: the auth rows do not apply: no other auth row" "$(area_rows auth)" 1

echo "== token.env as a link to a seat (the layout PR B adopts; dev's token.env is still a file)"
new_case
link_token quantivly-5
run_level --check
check "link: --check exits 0" "$RC" 0
has   "link: the token is loaded through it" "$OUT" "claude uses the long-lived token (oauth_token)"
hasnt "link: the mode read is the seat file's 600, not the link's 777" "$OUT" "not 600"
has   "link: the date is the seat's, not the legacy file's" "$OUT" "token stored $(date -d '10 days ago' +%F), 10 day(s) old"
hasnt "link: the token value is never printed" "$OUT" "$FAKE_TOK"
new_case
link_token quantivly-5; chmod 644 "$H/.config/claude-oauth/seats/quantivly-5.env"
run_level --check
has   "link to a mode-644 seat file: the seat file's mode is warned" "$OUT" "the token file is mode 644, not 600"
new_case
link_token quantivly-5; rm "$H/.config/claude-oauth/seats/quantivly-5.created"
run_level --check
has   "link to a seat with no date: expiry unknown, naming the seat's date file" "$OUT" "/seats/quantivly-5.created, so its expiry is unknown"
new_case
link_token quantivly-5; rm "$H/.config/claude-oauth/seats/quantivly-5.env"
run_level --check
has   "a dangling link: ⚠, naming the missing seat" "$OUT" "token.env links to seats/quantivly-5.env, which does not exist"
check "a dangling link: nothing is loaded" "$(ntok)" 0
# A target outside the layout is refused by name, whatever the file there holds: here every one
# holds a well-formed token, so only the name rule can refuse it. The environment tries to widen
# the rule (v2's dropped CLAUDE_OAUTH_SEAT_PREFIX); the rule is a constant and must not move.
# The last two pass the name rule alone, so only "exactly seats/<name>.env" refuses them.
for t in ../outside.env seats/../outside.env ABSOLUTE seats/other-5.env seats/Quantivly-5.env \
    seats/quantivly-5.env.bak seats/sub/quantivly-5.env quantivly-5.env seats/quantivly-5; do
    new_case
    d="$H/.config/claude-oauth"; link_token quantivly-5
    [[ "$t" == ABSOLUTE ]] && t="$d/seats/quantivly-5.env"   # the real seat, named absolutely
    mkdir -p "$(dirname "$d/${t#"$d/"}")"
    [[ -e "$d/${t#"$d/"}" ]] || cp "$d/seats/quantivly-5.env" "$d/${t#"$d/"}"
    ln -sfn "$t" "$d/token.env"
    CLAUDE_OAUTH_SEAT_PREFIX='../' run_level --check
    has   "a link to ${t#"$H/"}: ⚠, not a seat" "$OUT" "which is not a seat"
    check "a link to ${t#"$H/"}: host-sync loads nothing through it" "$(ntok)" 0
done
STORE="$DOTFILES/scripts/claude-oauth-store"
check "the seat-name rule: one constant, spelt the same in the store and in host-sync" \
    "$(grep -h '^SEAT_RE=' "$SUT" "$STORE" | uniq -c | sed 's/^ *//')" "2 SEAT_RE='^quantivly-[a-z0-9][a-z0-9-]{0,30}\$'"

echo "== the shared /login coming back (claudeAiOauth)"
new_case
run_level --check
has   "no credentials file: ✓, no shared /login" "$OUT" "${AUTH_OK}no shared /login on this host (claudeAiOauth absent)"
new_case
creds none
run_level --check
has   "credentials without claudeAiOauth: ✓" "$OUT" "${AUTH_OK}no shared /login on this host (claudeAiOauth absent)"
hasnt "credentials without claudeAiOauth: nothing of the file is printed" "$OUT" "$FAKE_LOGIN"
new_case
creds login
run_level --check
has   "claudeAiOauth back: ⚠, said so" "$OUT" "${AUTH_OPER}the shared /login is back on this host"
check "claudeAiOauth back: a person's step, not drift" "$RC" 0
hasnt "claudeAiOauth back: nothing of the file is printed" "$OUT" "$FAKE_LOGIN"
new_case
creds garbage
run_level --check
has   "unparseable credentials: ⚠ unknown, never ✓" "$OUT" "${AUTH_OPER}could not tell whether the shared /login is back"
hasnt "unparseable credentials: nothing of it is printed, jq's error included" "$OUT" "$FAKE_LOGIN"
new_case
rm -rf "$H/.config/claude-oauth"; creds login
run_level --check
hasnt "no token stored: the /login is the only login, so no write-back row" "$OUT" "is back on this host"

echo "== claude_procs reads no environment into bash (F11)"
new_case
# The running process carries a SECOND fake token, which only the /proc scan could ever see.
FAKE_TOK2="sk-ant-""oat01-FIXTUREsecondNOTREAL0123456789abcd"
printf 'HOME=/x\0CLAUDE_CODE_OAUTH_TOKEN=%s\0TERM=y\0' "$FAKE_TOK2" >"$C/proc/4101/environ"
fake_proc 4102 claude 0
XTRACE=1 run_level --check
has   "xtrace: the counts are unchanged" "$OUT" "1 of 2 Claude process(es) started without the token"
has   "xtrace: the trace covers the /proc scan (else the next row proves nothing)" "$(cat "$C/xtrace")" "proc/4101/comm"
hasnt "xtrace: no environ entry reaches a shell variable (a set -x run shows none)" "$(cat "$C/xtrace")" "$FAKE_TOK2"
# dev's OWN stored token, too (A3): load_token reads it into this shell, and the counts row above
# is printed only once it loaded. The trace must reach load_token, or the hasnt proves nothing.
has   "xtrace: the trace covers load_token (else the next row proves nothing)" "$(cat "$C/xtrace")" "+ load_token"
hasnt "xtrace: dev's own stored token never reaches the trace" "$(cat "$C/xtrace")" "$FAKE_TOK"

echo "== claude-oauth-store"
STORE="$DOTFILES/scripts/claude-oauth-store"
store() {   # $1 = what is typed at the prompt, then the empty line that ends it; under a pty
    SO="$C/store.out"; SE="$C/store.err"
    printf '%s\n\n' "$1" | env -i HOME="$H" PATH="/usr/bin:/bin" TERM=dumb \
        script -qec "'$STORE' >'$SO' 2>'$SE'" /dev/null >/dev/null 2>&1
    RC=$?
}
new_case
rm -rf "$H/.config/claude-oauth"
store "$FAKE_TOK"
check "store: exit 0" "$RC" 0
check "store: the file holds exactly the one line" "$(cat "$H/.config/claude-oauth/token.env")" "CLAUDE_CODE_OAUTH_TOKEN=$FAKE_TOK"
check "store: file mode 600" "$(stat -c %a "$H/.config/claude-oauth/token.env")" 600
check "store: directory mode 700" "$(stat -c %a "$H/.config/claude-oauth")" 700
check "store: dated today" "$(cat "$H/.config/claude-oauth/created")" "$(date +%F)"
hasnt "store: never prints the token" "$(cat "$SO" "$SE")" "$FAKE_TOK"
run_level --check
has   "store: what it writes is what host-sync accepts" "$OUT" "claude uses the long-lived token (oauth_token)"

new_case
rm -rf "$H/.config/claude-oauth"
store "sk-ant-api03-notasetuptoken0123456789abcdef"
check "store: a non-setup-token key is refused" "$RC" 1
check "store: nothing written for it" "$([[ -e "$H/.config/claude-oauth/token.env" ]] && echo yes || echo no)" no
hasnt "store: the refused value is not echoed" "$(cat "$SO" "$SE")" "notasetuptoken"

new_case
rm -rf "$H/.config/claude-oauth"
# The 2026-10-14 failure: setup-token's output wrapped, and only the first line was stored.
store "${FAKE_TOK:0:25}"$'\n'"   ${FAKE_TOK:25}"
check "store: a paste wrapped across lines is joined and stored whole" \
    "$(cat "$H/.config/claude-oauth/token.env" 2>/dev/null)" "CLAUDE_CODE_OAUTH_TOKEN=$FAKE_TOK"
has   "store: the token is checked with one request, with the token in its environment" \
    "$(cat "$H/stub/calls-with-token" 2>/dev/null)" "claude -p"
has   "store: the check leaves no transcript and starts no MCP server" "$(grep '^claude -p' "$H/stub/calls")" \
    "--no-session-persistence --strict-mcp-config"

new_case
rm -rf "$H/.config/claude-oauth"; touch "$H/stub/token-rejected"
store "$FAKE_TOK"
check "store: a token the API refuses is not stored" "$RC/$([[ -e "$H/.config/claude-oauth/token.env" ]] && echo written || echo none)" "1/none"
has   "store: says the API refused it, and why" "$(cat "$SE")" "the API refused it (Failed to authenticate"
hasnt "store: the refused token is not echoed" "$(cat "$SO" "$SE")" "$FAKE_TOK"

new_case
rm -rf "$H/.config/claude-oauth"; rm "$H/.local/bin/claude"
store "$FAKE_TOK"
check "store: no claude to check with: nothing stored" "$RC/$([[ -e "$H/.config/claude-oauth/token.env" ]] && echo written || echo none)" "1/none"
has   "store: says it could not check" "$(cat "$SE")" "cannot check the token: claude is not installed here"

new_case
rm -rf "$H/.config/claude-oauth"
# Typed AFTER the prompt is up, as a person would: with echo off, the terminal never shows it.
{ sleep 2; printf '%s\n\n' "$FAKE_TOK"; } | env -i HOME="$H" PATH="/usr/bin:/bin" TERM=dumb \
    script -qec "'$STORE' >/dev/null 2>&1" "$C/typescript" >/dev/null 2>&1
check "store: a typed token is stored" "$(cat "$H/.config/claude-oauth/token.env" 2>/dev/null)" "CLAUDE_CODE_OAUTH_TOKEN=$FAKE_TOK"
hasnt "store: a typed token is never echoed to the terminal" "$(cat "$C/typescript")" "$FAKE_TOK"

new_case
chmod 755 "$H/.config/claude-oauth"
store "$FAKE_TOK"
check "store: an existing directory is tightened to 700" "$(stat -c %a "$H/.config/claude-oauth")" 700

new_case
rm -rf "$H/.config/claude-oauth"
printf '%s\n' "$FAKE_TOK" | env -i HOME="$H" PATH="/usr/bin:/bin" "$STORE" >/dev/null 2>&1; RC=$?
check "store: a piped token (no terminal) is refused" "$RC" 1
check "store: nothing written from a pipe" "$([[ -e "$H/.config/claude-oauth/token.env" ]] && echo yes || echo no)" no

new_case
rm -rf "$H/.config/claude-oauth"; mkdir -p "$H/.clauth"
store "$FAKE_TOK"
check "store: refused where clauth manages accounts" "$RC" 1
has   "store: says why" "$(cat "$SE")" "clauth manages Claude accounts here"

echo "== claude-oauth-store over a link: it renews the seat the link names"
FAKE_TOK3="sk-ant-""oat01-FIXTUREthirdNOTREAL0123456789abcdef"
new_case
D="$H/.config/claude-oauth"; link_token quantivly-5
store "$FAKE_TOK3"
check "store over a link: exit 0" "$RC" 0
check "store over a link: token.env is still the same link" \
    "$([[ -L "$D/token.env" ]] && readlink "$D/token.env")" "seats/quantivly-5.env"
check "store over a link: the seat file holds the new token" "$(cat "$D/seats/quantivly-5.env")" "CLAUDE_CODE_OAUTH_TOKEN=$FAKE_TOK3"
check "store over a link: the seat file is mode 600" "$(stat -c %a "$D/seats/quantivly-5.env")" 600
check "store over a link: the seat is dated today" "$(cat "$D/seats/quantivly-5.created")" "$(date +%F)"
check "store over a link: the legacy date is left alone" "$(cat "$D/created")" "$(date -d '300 days ago' +%F)"
has   "store over a link: reports the seat file's mode, not the link's" "$(cat "$SO")" "(mode 600)"
hasnt "store over a link: never prints the token" "$(cat "$SO" "$SE")" "$FAKE_TOK3"
check "store: the probe child runs before the lock is taken" "$(sort -u "$H/stub/store-lock-during" 2>/dev/null)" free
run_level --check
has   "store over a link: host-sync reads the renewed seat's date" "$OUT" "token stored $(date +%F), 0 day(s) old"
new_case
D="$H/.config/claude-oauth"; link_token quantivly-5; rm "$D/seats/quantivly-5.env"
store "$FAKE_TOK3"
check "store over a dangling seat link: the seat file is written, the link kept" \
    "$(cat "$D/seats/quantivly-5.env" 2>/dev/null)/$(readlink "$D/token.env")" "CLAUDE_CODE_OAUTH_TOKEN=$FAKE_TOK3/seats/quantivly-5.env"
new_case
D="$H/.config/claude-oauth"; link_token quantivly-5
cp "$D/seats/quantivly-5.env" "$D/outside.env"; ln -sfn seats/../outside.env "$D/token.env"
store "$FAKE_TOK3"
check "store over a link that is not a seat: refused" "$RC" 1
has   "store over a link that is not a seat: says why" "$(cat "$SE")" "which is not a seat"
check "store over a link that is not a seat: its target is untouched" "$(cat "$D/outside.env")" "CLAUDE_CODE_OAUTH_TOKEN=$FAKE_TOK"
new_case
D="$H/.config/claude-oauth"
exec 8>"$D/.lock"; flock -n 8 || fatal "could not take $D/.lock for the refusal row"
store "$FAKE_TOK3"
exec 8>&-
check "store while another run holds its lock: refused, nothing written" \
    "$RC/$(cat "$D/token.env")" "1/CLAUDE_CODE_OAUTH_TOKEN=$FAKE_TOK"
has   "store while another run holds its lock: says so" "$(cat "$SE")" "another claude-oauth-store run holds"

echo "== dev never publishes a forwarded ssh agent"
rowtxt() { printf '%s %-14s %s' "$1" "$2" "$3"; }   # a row as host-sync prints it
mksock() { mkdir -p "$(dirname "$1")"; python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }
# A forwarded agent: sshd's /…/ssh-*/agent.<pid>, with a process really named sshd behind the pid
# (the shell reads the real /proc). A script run by its #! line takes the script's name as its
# comm; a copied binary would not do (sleep here is a multi-call binary that refuses other names).
agent_fixture() {
    R="$C/run"; mksock "$R/ssh-agent.socket"; LOCAL="$(readlink -f "$R/ssh-agent.socket")"
    mkdir -p "$C/abin" "$H/.ssh"; printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$C/abin/sshd"; chmod +x "$C/abin/sshd"
    "$C/abin/sshd" & SSHD_PID=$!
    # The name is the script's only once the fork has exec'd it: read at once, it raced and read
    # bash's name, and the fatal below then left this loop running for good. Wait for it, briefly.
    local _
    for _ in {1..100}; do
        [[ "$(cat "/proc/$SSHD_PID/comm" 2>/dev/null)" == sshd ]] && break
        sleep 0.02
    done
    if [[ "$(cat "/proc/$SSHD_PID/comm" 2>/dev/null)" != sshd ]]; then
        kill "$SSHD_PID" 2>/dev/null
        fatal "the fixture's sshd process is named $(cat "/proc/$SSHD_PID/comm" 2>/dev/null)"
    fi
    FWD="$C/ssh-Fwd123/agent.$SSHD_PID"; mksock "$FWD"
    sleep 300 & OTHER_PID=$!   # a local `ssh-agent -s` socket is named after its parent: not sshd
    OWN="$C/ssh-Own456/agent.$OTHER_PID"; mksock "$OWN"
}
agent_done() { kill "$SSHD_PID" "$OTHER_PID" 2>/dev/null; wait "$SSHD_PID" "$OTHER_PID" 2>/dev/null; }
zagent() {   # $1 = SSH_AUTH_SOCK the shell starts with ("" = unset). Sets ZS (its final socket), ZL (the link), ZMS
    # ZTEMPLATE = a file sourced after the plugins file, as zshrc sources ~/.zshrc.local after it.
    local out
    : >"$H/stub/ssh-add-calls"
    # shellcheck disable=SC2016  # expanded by the inner zsh, deliberately
    out="$(env -i HOME="$H" XDG_RUNTIME_DIR="$R" PATH="$H/.local/bin:/usr/bin:/bin" ${1:+SSH_AUTH_SOCK="$1"} zsh -f -c '
        zmodload zsh/datetime; t=$EPOCHREALTIME
        source "$1" >/dev/null 2>&1
        [[ -n "$2" ]] && source "$2" >/dev/null 2>&1
        print -r -- "${SSH_AUTH_SOCK:+${SSH_AUTH_SOCK:A}}|$(readlink -f ~/.ssh/ssh_auth_sock 2>/dev/null)|$(( (EPOCHREALTIME - t) * 1000 ))"' \
        zsh "$DOTFILES/zsh/zshrc.conditionals.plugins" "${ZTEMPLATE:-}")"
    IFS='|' read -r ZS ZL ZMS <<<"$out"; ZMS="${ZMS%%.*}"
    ZS="${ZS/#$LOCAL/local}"; ZS="${ZS/#$FWD/fwd}"; ZS="${ZS/#$OWN/own}"
    ZL="${ZL/#$LOCAL/local}"; ZL="${ZL/#$FWD/fwd}"; ZL="${ZL/#$OWN/own}"
}
fwd_asked() { grep -c "ssh-Fwd123" "$H/stub/ssh-add-calls" 2>/dev/null || true; }
# An `ssh-agent -s` the shell starts outlives it: on dev, one per host-sync run sat orphaned under
# pid 1 (2026-11-03). The stub logs the call and starts nothing.
agents_started() { grep -c '^ssh-agent' "$H/stub/calls" 2>/dev/null || true; }

new_case
agent_fixture
ln -sfn "$FWD" "$H/.ssh/ssh_auth_sock"
zagent "$H/.ssh/ssh_auth_sock"
check "dev pane, link on a forwarded agent: repaired to dev's own agent" "$ZS/$ZL" "local/local"

# With no agent of dev's own to fall back on, the link must still not be reused or asked.
mv "$R/ssh-agent.socket" "$R/off.socket"; ln -sfn "$FWD" "$H/.ssh/ssh_auth_sock"
reset_calls; zagent "$H/.ssh/ssh_auth_sock"
# (Systemd's socket path is exported instead, absent here, so the template's block below starts none.)
check "dev, no local agent, link on a forwarded agent: never asked, never reused" "$(fwd_asked)/$ZS" "0/local"
check "dev, no local agent: no ssh-agent of its own is started" "$(agents_started)" 0
mv "$R/off.socket" "$R/ssh-agent.socket"

ln -sfn "$LOCAL" "$H/.ssh/ssh_auth_sock"
zagent "$FWD"
check "dev login with its own forwarded agent: may use it, never publishes it" "$ZS/$ZL" "fwd/local"

ln -sfn "$C/gone/agent.1" "$H/.ssh/ssh_auth_sock"
zagent ""
check "dev, dangling link, no agent: relinked to dev's own agent" "$ZS/$ZL" "local/local"

zagent "$OWN"
check "dev, a local ssh-agent -s socket is not mistaken for a forwarded one" "$ZS/$ZL" "own/own"

touch "$H/stub/ssh-add-hangs"; ln -sfn "$C/gone/agent.1" "$H/.ssh/ssh_auth_sock"
reset_calls; zagent ""
rm "$H/stub/ssh-add-hangs"
# Not adopted: the shell is handed the dangling link (`:A` leaves it unresolved), never the
# socket that hangs.
check "dev, an agent that never answers: shell start bounded (two 1 s probes, not two 10 s ones), and not adopted" \
    "$(( ZMS < 5000 ))/$ZS" "1/$H/.ssh/ssh_auth_sock"
# A slow agent is the likely shape under a host-sync run's load: the probes time out, and the
# last resort used to start a stray agent there.
check "dev, an agent that never answers: no ssh-agent of its own is started" "$(agents_started)" 0
# An interactive shell then sources ~/.zshrc.local, whose workstation template block starts an
# agent when SSH_AUTH_SOCK is empty. With nothing answering, a shared host still hands it a path:
# the link unless forwarded, else systemd's socket path (#347's review, U1). The stub agent logs.
# shellcheck disable=SC2016  # the block's own text, expanded only by the shell that sources it
printf 'if [ -z "$SSH_AUTH_SOCK" ]; then\n    eval "$(ssh-agent -s)" > /dev/null\nfi\n' >"$C/zl-template"
mv "$R/ssh-agent.socket" "$R/off.socket"; rm -f "$H/.ssh/ssh_auth_sock"
reset_calls; ZTEMPLATE="$C/zl-template" zagent ""
check "dev, no agent and no link, then the template's block: no agent started" "$(agents_started)" 0
ln -sfn "$C/gone/agent.1" "$H/.ssh/ssh_auth_sock"
reset_calls; ZTEMPLATE="$C/zl-template" zagent ""
check "dev, no agent and a dangling link, then the template's block: no agent started" "$(agents_started)" 0
mv "$R/off.socket" "$R/ssh-agent.socket"

# VSCode forwards an agent too, and the shell prefers it to dev's own when one is keyed.
mksock "$R/vscode-ssh-auth-sock-1"; echo 0 >"$H/stub/ssh-add-rc"; ln -sfn "$C/gone/agent.1" "$H/.ssh/ssh_auth_sock"
zagent ""
rm "$R/vscode-ssh-auth-sock-1" "$H/stub/ssh-add-rc"
check "dev, a VSCode-forwarded socket is never adopted" "$ZS/$ZL" "local/local"

mv "$H/.config/host-sync" "$H/.config/host-sync.off"
ln -sfn "$LOCAL" "$H/.ssh/ssh_auth_sock"
zagent "$FWD"
check "laptop (no host-sync marker): unchanged, the login's agent is published as before" "$ZS/$ZL" "fwd/fwd"
# The last resort stands off a shared host: with no agent anywhere, the shell starts one.
mv "$R/ssh-agent.socket" "$R/off.socket"; ln -sfn "$C/gone/agent.1" "$H/.ssh/ssh_auth_sock"
reset_calls; zagent ""
check "laptop, no agent anywhere: the shell still starts one" "$(agents_started)" 1
check "laptop, no agent anywhere: no fallback path is exported (the shared-host branch only)" "$ZS" ""
mv "$R/off.socket" "$R/ssh-agent.socket"
# The marker of the release before the rename still marks a shared host.
mv "$H/.config/host-sync.off" "$H/.config/dev-sync"
ln -sfn "$LOCAL" "$H/.ssh/ssh_auth_sock"
zagent "$FWD"
check "a host with only the old dev-sync marker is still a shared host: never publishes the forwarded agent" "$ZS/$ZL" "fwd/local"
mv "$H/.config/dev-sync" "$H/.config/host-sync"
agent_done

echo "== host-sync reports the agent link"
new_case
agent_fixture
ln -sfn "$LOCAL" "$H/.ssh/ssh_auth_sock"
run_level --check
# shellcheck disable=SC2088  # a label as host-sync prints it
has   "agent: a local agent is named" "$OUT" "~/.ssh/ssh_auth_sock → $LOCAL, a local agent"
has   "agent: with a bounded ssh-add timing" "$OUT" "ssh-add -l answered in"
echo 0 >"$H/stub/ssh-add-rc"; run_level --check
has   "agent: keys loaded" "$OUT" "ms, keys loaded"
rm "$H/stub/ssh-add-rc"; touch "$H/stub/ssh-add-hangs"; run_level --check; rm "$H/stub/ssh-add-hangs"
has   "agent: an agent that does not answer in 1 s: a person's step" "$OUT" "$(rowtxt ⚠ agent "ssh-add -l did not answer within 1 s")"
ln -sfn "$FWD" "$H/.ssh/ssh_auth_sock"
fake_proc "$SSHD_PID" sshd 0
: >"$H/stub/ssh-add-calls"; run_level --check
# shellcheck disable=SC2088  # a label as host-sync prints it
has   "agent: a link on a forwarded agent: a person's step" "$OUT" "$(rowtxt ⚠ agent "~/.ssh/ssh_auth_sock → an agent FORWARDED from the laptop")"
check "agent: the forwarded agent is never probed" "$(fwd_asked)" 0
check "agent: report-only, no drift from it" "$RC" 0
fake_proc "$SSHD_PID" sleep 0
run_level --check
has   "agent: the same socket shape from a local agent is local" "$OUT" "$FWD, a local agent"
ln -sfn "$C/gone/agent.1" "$H/.ssh/ssh_auth_sock"
run_level --check
# shellcheck disable=SC2088  # a label as host-sync prints it
has   "agent: a dangling link is information" "$OUT" "$(rowtxt · agent "~/.ssh/ssh_auth_sock dangles")"
rm "$H/.ssh/ssh_auth_sock"
run_level --check
# shellcheck disable=SC2088  # a label as host-sync prints it
has   "agent: no link is information" "$OUT" "$(rowtxt · agent "no ~/.ssh/ssh_auth_sock link")"
agent_done

echo "== host-sync hands its children dev's own agent link"
new_case
agent_fixture
# The workstation template's block, which dev's ~/.zshrc.local holds (counted, not read, 11-03), and
# a line recording what the shell sourcing it was handed. The mcp row sources this file; the stub
# ssh-agent logs its call and starts nothing.
cat >>"$H/.zshrc.local" <<'ZL'
print -r -- "${SSH_AUTH_SOCK:-unset}" >"$HOME/stub/zl-sock"
if [ -z "$SSH_AUTH_SOCK" ]; then
    eval "$(ssh-agent -s)" > /dev/null
fi
ZL
ln -sfn "$LOCAL" "$H/.ssh/ssh_auth_sock"
reset_calls; run_level --check
has   "children: the mcp row sourced ~/.zshrc.local (else the next rows prove nothing)" "$OUT" "LINEAR_API_KEY is set in ~/.zshrc.local"
check "children: a shell host-sync starts is handed the stable link" "$(cat "$H/stub/zl-sock" 2>/dev/null)" "$H/.ssh/ssh_auth_sock"
check "children: so the template's block starts no agent" "$(agents_started)" 0
# Without a link to hand on, systemd's socket path: never forwarded, and non-empty even when it is
# absent, so the block still starts nothing and ssh falls back to the key files (review 3, S1).
ln -sfn "$FWD" "$H/.ssh/ssh_auth_sock"; fake_proc "$SSHD_PID" sshd 0
reset_calls; run_level --check
check "children: a link on a forwarded agent is never handed on: systemd's socket instead" \
    "$(cat "$H/stub/zl-sock" 2>/dev/null)" "$R/ssh-agent.socket"
check "children: a forwarded link: the template's block starts no agent" "$(agents_started)" 0
rm "$H/.ssh/ssh_auth_sock"
reset_calls; run_level --check
check "children: no link: the template's block starts no agent" "$(agents_started)" 0
agent_done

echo "== shells and the herdr launcher load it"
zload() {   # what an interactive shell on the host ends up with: unset, the token, or other
    # shellcheck disable=SC2016  # expanded by the inner zsh, deliberately
    env -i HOME="$H" PATH="/usr/bin:/bin" zsh -f -c \
        'source "$1" >/dev/null 2>&1
         if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then echo unset
         elif [[ "$CLAUDE_CODE_OAUTH_TOKEN" == "$2" ]]; then echo token; else echo other; fi' \
        zsh "$DOTFILES/zsh/zshrc.company" "$FAKE_TOK"
}
new_case
check "zshrc.company exports the stored token" "$(zload)" token
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s; touch x\n' "$FAKE_TOK" >"$H/.config/claude-oauth/token.env"
check "zshrc.company exports nothing from a line of any other shape" "$(zload)" unset
new_case
mkdir -p "$H/.clauth"
check "zshrc.company exports nothing on a clauth machine" "$(zload)" unset

LAUNCH="$DOTFILES/scripts/herdr-server-launch.sh"
new_case
OUT="$(env -i HOME="$H" USER=t PATH="/usr/bin:/bin" "$LAUNCH" --print-env 2>/dev/null)"
has   "launcher --print-env: the token is declared, masked" "$OUT" "CLAUDE_CODE_OAUTH_TOKEN=<set>"
hasnt "launcher --print-env: never its value" "$OUT" "$FAKE_TOK"
# The launcher's own zsh sources ~/.zshrc.local for LINEAR_API_KEY. A headless user manager has no
# SSH_AUTH_SOCK, so the workstation template's block started an agent at every server start, inside
# herdr-server.service (#346's re-check, T1). That zsh now gets the agent path the server gets. A
# temp HOME and the stub ssh-agent, which logs its call and starts nothing.
cat >>"$H/.zshrc.local" <<'ZL'
if [ -z "$SSH_AUTH_SOCK" ]; then
    eval "$(ssh-agent -s)" > /dev/null
fi
ZL
reset_calls
OUT="$(env -i HOME="$H" USER=t PATH="$H/.local/bin:/usr/bin:/bin" "$LAUNCH" --print-env 2>/dev/null)"
has   "launcher: LINEAR_API_KEY is still read from ~/.zshrc.local (else the next rows prove nothing)" "$OUT" "LINEAR_API_KEY=<set>"
hasnt "launcher: ...and its value is never printed" "$OUT" "$FAKE_KEY"
check "launcher, no agent link: the template's block starts no agent" "$(agents_started)" 0
mkdir -p "$H/.ssh"; ln -sfn "$C/run/ssh-agent.socket" "$H/.ssh/ssh_auth_sock"
reset_calls
env -i HOME="$H" USER=t PATH="$H/.local/bin:/usr/bin:/bin" "$LAUNCH" --print-env >/dev/null 2>&1
check "launcher, with the agent link: the template's block starts no agent" "$(agents_started)" 0
rm "$H/.ssh/ssh_auth_sock"
# The server gets the same fallback, so a pane's shell starts with a path even when the server
# started without the link (#347's review, U1).
OUT="$(env -i HOME="$H" USER=t XDG_RUNTIME_DIR="$C/run" PATH="/usr/bin:/bin" "$LAUNCH" --print-env 2>/dev/null)"
has   "launcher, no agent link: the server still gets systemd's socket path" "$OUT" "SSH_AUTH_SOCK=$C/run/ssh-agent.socket"
# A real launch, into a herdr stub that reports what the server would inherit.
mkdir -p "$C/run"; chmod 700 "$C/run"
# shellcheck disable=SC2016  # expanded by the stub, deliberately
printf '#!/bin/sh\n[ "$1" = server ] || exit 0\n[ "$CLAUDE_CODE_OAUTH_TOKEN" = "%s" ] && echo yes >"%s" || echo no >"%s"\n' \
    "$FAKE_TOK" "$C/server-env" "$C/server-env" >"$H/.local/bin/herdr"
rm -f "$H/.zshrc.local"   # no LINEAR_API_KEY: the token alone must take the hand-off path
# The /bin/sh that reads the hand-off resolves `rm` on the declared PATH, which starts at
# ~/.local/bin: this stub records the file's mode on its way out. umask 022 is the user
# manager's default, under which a plain redirect would make it 644.
# shellcheck disable=SC2016  # expanded by the stub, deliberately
printf '#!/bin/sh
for a; do f=$a; done
stat -c %%a "$f" >"%s"
exec /bin/rm "$@"
' "$C/handoff-mode" >"$H/.local/bin/rm"
chmod +x "$H/.local/bin/rm"
(umask 022; env -i HOME="$H" USER=t PATH="/usr/bin:/bin" XDG_RUNTIME_DIR="$C/run" "$LAUNCH" >/dev/null 2>&1)
check "launcher: the server starts with the token" "$(cat "$C/server-env" 2>/dev/null)" yes
check "launcher: the hand-off file is 0600 under umask 022" "$(cat "$C/handoff-mode" 2>/dev/null)" 600
check "launcher: the hand-off file is gone" "$(ls -A "$C/run")" ""
mkdir -p "$H/.clauth"; : >"$C/server-env"
env -i HOME="$H" USER=t PATH="/usr/bin:/bin" XDG_RUNTIME_DIR="$C/run" "$LAUNCH" >/dev/null 2>&1
check "launcher: no token on a clauth machine" "$(cat "$C/server-env")" no
rmdir "$H/.clauth"
rm -rf "$H/.config/claude-oauth"; : >"$C/server-env"
env -i HOME="$H" USER=t PATH="/usr/bin:/bin" XDG_RUNTIME_DIR="$C/run" "$LAUNCH" >/dev/null 2>&1
check "launcher: no file, no token" "$(cat "$C/server-env")" no
# The hand-off file is SOURCED by /bin/sh, so a line that is not exactly the one assignment must
# never reach it: here it would run a command as the server starts.
mkdir -p "$H/.config/claude-oauth"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s; touch %s\n' "$FAKE_TOK" "$C/pwned" >"$H/.config/claude-oauth/token.env"
env -i HOME="$H" USER=t PATH="/usr/bin:/bin" XDG_RUNTIME_DIR="$C/run" "$LAUNCH" >/dev/null 2>&1
check "launcher: a line of any other shape is never sourced" "$([[ -e "$C/pwned" ]] && echo ran || echo no)" no

# Every loader reads token.env through a link exactly as it reads a file (the layout PR B adopts).
# These pin what already holds: a loader that tested -f, or refused a link, would fail them. rabota
# has no row: it only NAMES the file in EnvironmentFile=, and systemd does the reading.
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$FAKE_TOK" >"$H/.config/claude-oauth/token.env"
date +%F >"$H/.config/claude-oauth/created"
link_token quantivly-5
check "zshrc.company exports the token through a link" "$(zload)" token
OUT="$(env -i HOME="$H" USER=t PATH="/usr/bin:/bin" "$LAUNCH" --print-env 2>/dev/null)"
has   "launcher --print-env through a link: the token is declared, masked" "$OUT" "CLAUDE_CODE_OAUTH_TOKEN=<set>"
: >"$C/server-env"
env -i HOME="$H" USER=t PATH="/usr/bin:/bin" XDG_RUNTIME_DIR="$C/run" "$LAUNCH" >/dev/null 2>&1
check "launcher through a link: the server starts with the token" "$(cat "$C/server-env")" yes
rm "$H/.config/claude-oauth/seats/quantivly-5.env"; : >"$C/server-env"
check "zshrc.company exports nothing through a dangling link" "$(zload)" unset
env -i HOME="$H" USER=t PATH="/usr/bin:/bin" XDG_RUNTIME_DIR="$C/run" "$LAUNCH" >/dev/null 2>&1
check "launcher through a dangling link: no token" "$(cat "$C/server-env")" no

printf '\n'
EXPECTED_ROWS=487
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '\033[1;31mROW COUNT\033[0m: expected %d rows, %d ran — a check vanished or was added without updating EXPECTED_ROWS\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))" >&2
    exit 1
fi
if (( FAIL )); then printf '\033[1;31m%d of %d failed\033[0m\n' "$FAIL" "$((PASS + FAIL))"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$PASS"
