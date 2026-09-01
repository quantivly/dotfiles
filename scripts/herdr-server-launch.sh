#!/usr/bin/env bash
# scripts/herdr-server-launch.sh
# ==============================
# Start the herdr server from a DECLARED, CLEAN environment. Builds the
# environment from nothing (`env -i`) and execs `herdr server`, so the server —
# and therefore every pane it will ever create — inherits exactly what is listed
# below, and nothing from whichever shell happened to launch it.
#
# WHY (herdr-eval finding F1, 2026-08-30). Every herdr pane inherits the SERVER's
# environment, and the server inherits the environment of whatever started it.
# On 2026-08-29 the live server was restarted from inside a herdmates team-lead
# pane, so its environment — and every pane created since — carried
# HERDR_PANE_ID=w2:p1, a fake TMUX=teammux,0,0, TEAMMUX_STATE_PATH, herdmates'
# HERDR_PLUGIN_STATE_DIR/CONFIG_DIR, CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1, and
# the teammux shim ahead of real tmux on PATH. Every Claude session on the box
# became a "team of one", `tmn`/`tmux kill-server` hit the shim instead of tmux,
# plugin CLIs leaked herdmates' state into unrelated sessions, and the runbook's
# `command -v tmux` capability check passed for everyone — while `herdr config
# check` said `ok` throughout. A rule to scrub the shell before launching already
# existed and was not applied; a launcher that cannot inherit anything is the fix.
#
# HOW TO USE
#   Preferred — the systemd user unit systemd/herdr-server.service (symlinked to
#   ~/.config/systemd/user/ by ./install; linking does NOT enable it). One-time
#   switch-over, from a PLAIN terminal (not a herdr pane, not a Claude session):
#     systemctl --user daemon-reload
#     herdr server stop                       # ends EVERY agent session on the machine
#     systemctl --user disable herdr-server.service   # only if it was enabled under the OLD
#     systemctl --user enable --now herdr-server.service   # target; changing [Install] does
#                                             # not move an existing .wants/ symlink
#     scripts/verify-tools.sh                 # "herdr server environment hygiene" must be green
#                                             # (non-zero exit on a hygiene FAIL)
#     journalctl --user -u herdr-server.service -e   # server log
#   Manual fallback (no systemd), again from a plain terminal:
#     scripts/herdr-server-launch.sh &
#   Either way, bare `herdr` at a keyboard then attaches to this server ("Launch
#   or attach to the persistent session" — `herdr --help`).
#
#   --print-env   Print the environment the server WOULD get, one KEY=value per
#                 line, any value whose key matches KEY|TOKEN|SECRET|PASSWORD shown
#                 as <set>; exit 0 without starting anything. This is how the
#                 launcher is tested, and what scripts/verify-tools.sh compares the
#                 live server against.
#
# GUARDS. Refuses to start (exit 1) when HERDR_ENV=1 (this shell is a herdr pane)
# or when CLAUDECODE / CLAUDE_CODE_SESSION_ID is set (this is a Claude session).
# `env -i` would clean the environment either way, but a server started there is
# still a CHILD of the pane or session that launched it — it dies with that pane,
# and it is exactly the mistake F1 describes. --print-env is exempt from both.
#
# WHAT IS DECLARED (everything else is dropped):
#   PATH        ~/.local/bin (herdr, clauth, herdmates, teammux, and the
#               bun/lazygit/yazi symlinks) : every `mise bin-paths` entry :
#               ~/.cargo/bin : /usr/local/bin : /usr/bin : /bin. mise is called
#               by absolute path (~/.local/bin/mise), from $HOME, under a scrubbed
#               env, so the result is the GLOBAL mise config regardless of the
#               caller's cwd or shell state (verified identical to a plain
#               `mise bin-paths`). The server PATH is a snapshot: a tool added to
#               mise later is invisible until the server restarts — or is
#               symlinked into ~/.local/bin, which is why bun/lazygit/yazi are.
#   HOME USER LOGNAME SHELL   identity; SHELL from the passwd entry, else /bin/zsh.
#   LANG LC_ALL  passed through when set. (The systemd user manager exports LANG
#               here; pane shells re-export both from zshrc anyway.)
#   TERM        xterm-256color.
#   XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS   the session bus — `notify-send`
#               toasts and gh's keyring lookups both go through it. Defaults
#               /run/user/<uid> and unix:path=<that>/bus when the caller has neither.
#   WAYLAND_DISPLAY DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
#               passed through when set, for anything a plugin opens on the desktop
#               (xdg-open, `gh … --web`). XAUTHORITY must travel with DISPLAY: on
#               this Wayland box mutter writes the Xwayland cookie to
#               /run/user/<uid>/.mutter-Xwaylandauth.XXXXXX (there is no
#               ~/.Xauthority), so an X11 client with DISPLAY but no XAUTHORITY is
#               refused with "Authorization required" — worse than no DISPLAY at
#               all, because callers stop falling back. CAVEAT: that cookie path is
#               regenerated at each login, so a long-lived server can hold a STALE
#               XAUTHORITY after a re-login — X11 tools then fail until the next
#               server restart; Wayland-native clients (WAYLAND_DISPLAY) are
#               unaffected. Under the unit these come from the user manager's
#               environment (`systemctl --user show-environment`, which carries all
#               of them here), which GNOME populates at session start. That
#               ordering used to be UNVERIFIED; it is now settled and it is why the
#               unit hangs off graphical-session.target rather than default.target.
#               Linger=yes on this account means the user manager, and so
#               default.target, comes up at BOOT — before any graphical session
#               exists — so a unit wanted by default.target would start with none
#               of these set. Toasts need only the D-Bus address, which is always
#               present.
#   SSH_AUTH_SOCK    the caller's value when set, else ~/.ssh/ssh_auth_sock — the
#               STABLE SYMLINK, which is the point. The real agent socket here
#               belongs to the Bitwarden snap, and Bitwarden is a GNOME *autostart*
#               app (~/.config/autostart/bitwarden_bitwarden.desktop), so it launches
#               AFTER graphical-session.target: even with the unit ordered there, the
#               live path is often not in the manager's environment yet. Handing the
#               server a symlink instead of a snapshot makes that a non-race — the
#               agent binds that path whenever it starts, before or after the server,
#               and every pane inherits an indirection that stays correct.
#               zshrc.conditionals.plugins' _setup_ssh_agent re-points the symlink
#               whenever the real path changes, and tmux.conf already relies on
#               exactly this (see its own comment). The symlink is used even when
#               currently DANGLING, deliberately: at boot it names where the agent
#               will appear. Without any of this, pane shells still recover via
#               _setup_ssh_agent's repair path — two `ssh-add -l` probes (~56 ms
#               each) per new pane instead of the sub-ms fast path.
#   LINEAR_API_KEY   read from ~/.zshrc.local in a NON-interactive zsh (no prompt,
#               no plugins, just the file); when non-empty, handed to the server
#               via a 0600 file under XDG_RUNTIME_DIR that /bin/sh exports (and
#               deletes) just before exec'ing herdr — NEVER via argv: `env -i
#               LINEAR_API_KEY=… ` would put the value in env(1)'s
#               /proc/<pid>/cmdline, which is world-readable (no hidepid on this
#               box). Never printed; --print-env masks it as <set>.
#               Why this key sits in the server env at all when GH_TOKEN
#               deliberately does not: tdi.worktree-from-linear reads
#               LINEAR_API_KEY from the SERVER environment and has no keyring
#               path — a key exported after the server started is never seen.
#               gh, by contrast, authenticates through its config + keyring
#               (GH_CONFIG_DIR only selects the account), so no token needs to
#               sit in an environment every pane inherits.
#   GH_CONFIG_DIR    ~/.config/gh-quantivly when that directory exists — see the
#               trade-off where it is set below.

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: herdr-server-launch.sh [--print-env]
  (no args)    build the clean environment and exec `herdr server`
               (refuses inside a herdr pane or a Claude session)
  --print-env  print the environment that would be used (secrets masked), exit 0
USAGE
}

warn() { printf 'herdr-server-launch: %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

print_env_only=false
case "$#:${1:-}" in
    0:) ;;
    1:--print-env) print_env_only=true ;;
    1:-h | 1:--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# Guards: never start a server whose parent is a herdr pane or a Claude session.
# ---------------------------------------------------------------------------
if [[ "$print_env_only" != true ]]; then
    if [[ "${HERDR_ENV:-}" == 1 ]]; then
        die "refusing to start: HERDR_ENV=1, so this shell is a herdr pane. A server started here is a child of the running server and dies with it (and it is how F1 happened). Start from a plain terminal, or: systemctl --user start herdr-server.service. --print-env is fine here."
    fi
    if [[ -n "${CLAUDECODE:-}" || -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
        die "refusing to start: CLAUDECODE/CLAUDE_CODE_SESSION_ID set, so this is a Claude session. The server would be a child of that session. Start from a plain terminal, or: systemctl --user start herdr-server.service. --print-env is fine here."
    fi
fi

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
user="${USER:-$(id -un)}"
home="${HOME:-$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)}"
[[ -n "$home" ]] || die "cannot determine HOME for $user"
logname="${LOGNAME:-$user}"
login_shell="$(getent passwd "$user" 2>/dev/null | cut -d: -f7 || true)"
[[ -n "$login_shell" ]] || login_shell=/bin/zsh
uid="$(id -u)"

# ---------------------------------------------------------------------------
# PATH — declared, in order. Never a plugin shim dir.
# ---------------------------------------------------------------------------
path="$home/.local/bin"
mise_bin="$home/.local/bin/mise"
if [[ -x "$mise_bin" ]]; then
    # Scrubbed env + cd $HOME: the GLOBAL config only, whatever the caller's cwd or
    # shell state. Output is one bin dir per line, in mise's own order.
    if mise_paths="$(cd "$home" && env -i HOME="$home" USER="$user" PATH=/usr/local/bin:/usr/bin:/bin "$mise_bin" bin-paths 2>/dev/null)"; then
        while IFS= read -r dir; do
            if [[ -n "$dir" ]]; then path+=":$dir"; fi
        done <<<"$mise_paths"
    else
        warn "'$mise_bin bin-paths' failed — mise-managed tools (node, python3, bun, ...) will be ABSENT from the server PATH"
    fi
else
    warn "$mise_bin not found — mise-managed tools (node, python3, bun, ...) will be ABSENT from the server PATH"
fi
path+=":$home/.cargo/bin:/usr/local/bin:/usr/bin:/bin"

# Invariant, not a heuristic: nothing above can legitimately produce a shim dir.
case ":$path:" in
    *"/teammux/bin"*) die "refusing to start: the declared PATH contains a teammux shim dir: $path" ;;
esac

# Resolve herdr the way the server's own children will (absolute /bin/sh: env must
# not search for the shell itself). Exec'd by absolute path below.
herdr_bin="$(env -i PATH="$path" /bin/sh -c 'command -v herdr' 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# Session bus / desktop
# ---------------------------------------------------------------------------
xdg_runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$uid}"
dbus_address="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$xdg_runtime_dir/bus}"
# SSH_AUTH_SOCK: the caller's value, else the stable symlink (see the header).
# -L, not -S, on purpose: a dangling symlink still names where the agent will
# bind, and the Bitwarden snap that owns it autostarts after this unit.
ssh_auth_sock="${SSH_AUTH_SOCK:-}"
if [[ -z "$ssh_auth_sock" && -L "$home/.ssh/ssh_auth_sock" ]]; then
    ssh_auth_sock="$home/.ssh/ssh_auth_sock"
fi

# ---------------------------------------------------------------------------
# Secrets the plugins need. Values are captured, never echoed — and never placed
# in any argv either (see LINEAR_API_KEY in the header): /proc/<pid>/cmdline is
# world-readable, so a secret in argv is a secret published.
# ---------------------------------------------------------------------------
linear_key=""
if [[ -r "$home/.zshrc.local" ]] && command -v zsh >/dev/null 2>&1; then
    linear_key="$(zsh -c 'source "$1" >/dev/null 2>&1; printf %s "${LINEAR_API_KEY:-}"' zsh "$home/.zshrc.local" 2>/dev/null || true)"
fi
if [[ -z "$linear_key" ]]; then
    warn "LINEAR_API_KEY not found in ~/.zshrc.local — tdi.worktree-from-linear (the Linear picker) will not authenticate"
fi

# gh account for plugins. The gh-pr plugin runs `gh` under the SERVER env, so one
# account serves every pane; work repos dominate here, so it is the Quantivly config
# and panes in personal repos that account cannot see get no `$pr` row. Per
# docs/TROUBLESHOOTING.md, GH_CONFIG_DIR alone selects the config while auth still
# goes through the shared keyring default; a GH_TOKEN would pin the account but would
# put a token into an environment every pane inherits, so it is deliberately not set
# here. VERIFIED 2026-08-31, under exactly this env (env -i with the declared PATH,
# HOME, GH_CONFIG_DIR, DBUS_SESSION_BUS_ADDRESS, XDG_RUNTIME_DIR): `gh auth status`
# → "✓ Logged in to github.com account zvi-quantivly (keyring)". Re-check against a
# RUNNING server with the server's own values:
#   pid=$(pgrep -f '(^|/)herdr server$'); env -i $(tr '\0' '\n' </proc/$pid/environ \
#     | grep -E '^(HOME|PATH|GH_CONFIG_DIR|DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR)=') gh auth status
gh_config_dir=""
if [[ -d "$home/.config/gh-quantivly" ]]; then
    gh_config_dir="$home/.config/gh-quantivly"
fi

# ---------------------------------------------------------------------------
# Assemble
# ---------------------------------------------------------------------------
server_env=(
    "HOME=$home"
    "USER=$user"
    "LOGNAME=$logname"
    "SHELL=$login_shell"
    "PATH=$path"
    "TERM=xterm-256color"
    "XDG_RUNTIME_DIR=$xdg_runtime_dir"
    "DBUS_SESSION_BUS_ADDRESS=$dbus_address"
)
# Pass-through, only when set.
for var in LANG LC_ALL WAYLAND_DISPLAY DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE; do
    if [[ -n "${!var:-}" ]]; then server_env+=("$var=${!var}"); fi
done
# SSH_AUTH_SOCK is resolved above rather than merely passed through: without it
# every new pane shell takes zshrc's slow agent-repair path.
if [[ -n "$ssh_auth_sock" ]]; then server_env+=("SSH_AUTH_SOCK=$ssh_auth_sock"); fi
# LINEAR_API_KEY is deliberately NOT in server_env: server_env becomes env(1)'s
# argv, and /proc/<pid>/cmdline is world-readable. It reaches the server via the
# 0600 env file at the exec below.
if [[ -n "$gh_config_dir" ]]; then server_env+=("GH_CONFIG_DIR=$gh_config_dir"); fi

if [[ "$print_env_only" == true ]]; then
    mask_re='KEY|TOKEN|SECRET|PASSWORD'
    {
        for entry in "${server_env[@]}"; do
            key="${entry%%=*}"
            if [[ "$key" =~ $mask_re ]]; then
                printf '%s=<set>\n' "$key"
            else
                printf '%s\n' "$entry"
            fi
        done
        # Not in server_env (argv hygiene, above) but part of the environment the
        # server WOULD get — shown masked, like any other secret.
        if [[ -n "$linear_key" ]]; then printf 'LINEAR_API_KEY=<set>\n'; fi
    } | sort
    if [[ -z "$herdr_bin" ]]; then
        warn "note: herdr is NOT resolvable on the declared PATH — a real launch would refuse"
    fi
    exit 0
fi

[[ -n "$herdr_bin" ]] || die "herdr not found on the declared PATH: $path"

# Deterministic cwd (the unit's default is $HOME too); panes open in their
# workspace directories, not here.
cd "$home"
if [[ -n "$linear_key" ]]; then
    # Argv hygiene: `env -i LINEAR_API_KEY=… ` would publish the value in
    # env(1)'s /proc/<pid>/cmdline (world-readable; no hidepid here). Instead the
    # key goes into a 0600 file under XDG_RUNTIME_DIR (user-only tmpfs) that the
    # intermediate /bin/sh exports and deletes before exec'ing herdr — every argv
    # along the way carries only paths. Single-quote-escaped so the value can
    # never be parsed as anything but one assignment.
    envfile="$xdg_runtime_dir/herdr-server-env.$$"
    sq_key=${linear_key//\'/\'\\\'\'}
    ( umask 077; printf "LINEAR_API_KEY='%s'\n" "$sq_key" > "$envfile" )
    # shellcheck disable=SC2016  # "$1"/"$2" are for /bin/sh to expand, deliberately not bash
    exec env -i "${server_env[@]}" /bin/sh -c \
        'set -a; . "$1"; set +a; rm -f -- "$1"; exec "$2" server' sh "$envfile" "$herdr_bin"
fi
exec env -i "${server_env[@]}" "$herdr_bin" server
