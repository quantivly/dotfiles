#!/usr/bin/env bash
# Comprehensive tool installation status check
#
# This script verifies which development tools are installed and provides
# their versions. It's useful for:
# - Onboarding new developers
# - Troubleshooting environment issues
# - Verifying post-setup state
# - Checking which optional tools are available
#
# Usage:
#   ./scripts/verify-tools.sh
#   verify-tools  # If symlinked to ~/.local/bin
#
# EXIT CODE: non-zero if and only if one of the three ASSERTION sections FAILs:
# "herdr server environment hygiene" — forbidden variables in the running
# server's environment, a teammux shim dir on its PATH, or session variables the
# session provides that the server does not have — or "systemd user unit
# enablement", where a unit's .wants/ symlink no longer matches the WantedBy= in
# the unit file this checkout links. That is the one section the switch-over runbooks
# (systemd/herdr-server.service, scripts/herdr-server-launch.sh) treat as an
# assertion ("must be green"), so it must be gateable by a caller or CI, like
# backup-doctor and audit-status. The third is "Claude Code wiring" -- the
# statusLine and agent-skill file that ./install links a hook for but cannot
# finish, both of which fail silently and neither of which anything checked
# before DO-563. Everything else stays informational and exits
# 0: missing/optional tools, mise drift, a missing LINEAR_API_KEY (a WARN — a
# keyless machine is degraded, not contaminated), and the hygiene check being
# SKIPPED because no server is running.

# NO `set -e` HERE — deliberately. This script's entire purpose is to report which
# tools are missing, and check_tool returns 1 for each one it doesn't find. Under
# errexit, a `check_tool x || check_tool x_fallback` pair where BOTH are absent kills
# the script outright. It had been dying at the first fully-missing tool (`bat`) after
# 12 lines and exit 1, silently reporting nothing about the other ~20 tools — which is
# why the missing `delta` that broke `git diff` was never surfaced despite this script
# existing to surface exactly that. A verifier must outlive the failures it reports.

# --herdr: report ONLY what a modular herdr adopter installed (DO-563).
#
# Why this flag exists. `./install --herdr` links five files and deliberately
# does NOT link ~/.config/mise/config.toml, so on such a machine the eleven
# full-install sections below are all noise -- and the mise-drift check is
# worse than noise: it prints a FAIL and offers a pasteable `ln -sfn` that
# would pin ~25 tools globally and override whatever node/python the machine
# already runs. The team write-up had to carry a callout telling readers to
# ignore both. A checker that needs a prose disclaimer is the permanently-red
# checker this repo's own CLAUDE.md warns about twice; the fix is scope, not
# prose.
# This checkout, resolved from THIS script rather than from $HOME/.dotfiles.
# Two reasons, and the first one bit during DO-563: the old definition lived
# inside the full-install report, so --herdr left it empty and the enablement
# assertion failed with "/scripts/reconcile-systemd-units.sh missing" — a FAIL
# reporting the checker's absence, in a section whose whole point is that a
# missing checker is not a pass. The second is that a checkout is not
# necessarily at ~/.dotfiles (see DO-564), and a verifier that can only verify
# one path is one more thing to be wrong somewhere else.
DOTFILES_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

HERDR_ONLY=false
case "$#:${1:-}" in
    0:) ;;
    1:--herdr) HERDR_ONLY=true ;;
    1:-h | 1:--help)
        cat <<'USAGE'
Usage: verify-tools.sh [--herdr]
  (no args)  full report: every tool this repo declares, plus the herdr checks
  --herdr    ONLY the herdr checks -- server env, unit enablement, plugin deps
             under the server PATH, and Claude Code wiring. For a machine that
             ran `./install --herdr` and linked five files, not eighteen.

EXIT: non-zero if a herdr assertion FAILs (server env, unit enablement, Claude
Code wiring). Missing optional tools and mise drift stay informational.
USAGE
        exit 0 ;;
    *)
        # The case key is "$#:$1", so any arity != 1 lands here -- and blaming
        # "$1" then accused the VALID flag of being unknown when the real fault
        # was a second word. Separate the two messages.
        if (( $# > 1 )); then
            echo "verify-tools.sh: too many arguments (expected at most one, got $#: $*)" >&2
        else
            echo "verify-tools.sh: unknown argument '${1}' (try --help)" >&2
        fi
        exit 2 ;;
esac

# Color codes (only if TTY)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Check if command exists and show version
check_tool() {
    local tool=$1
    local version_cmd=${2:-"--version"}
    local is_required=${3:-false}

    if command -v "$tool" &>/dev/null; then
        local version
        version=$(eval "$tool $version_cmd" 2>&1 | head -1)
        echo -e "${GREEN}✓${NC} $tool: $version"
        return 0
    else
        if [[ "$is_required" == true ]]; then
            echo -e "${YELLOW}✗${NC} $tool: NOT FOUND (required)"
        else
            echo -e "  ○ $tool: not installed (optional)"
        fi
        return 1
    fi
}

# Everything from here to the herdr sections is the FULL-INSTALL report, and is
# skipped wholesale under --herdr. Deliberately NOT re-indented: wrapping ~170
# lines in an `if` purely to change their indentation would bury the one-line
# change that actually happened in a diff nobody can read.
if [[ "$HERDR_ONLY" != true ]]; then

echo -e "${BLUE}=== Required Tools ===${NC}"
check_tool zsh "--version" true
check_tool git "--version" true
check_tool bash "--version" true

echo ""
echo -e "${BLUE}=== Strongly Recommended Tools ===${NC}"
check_tool fzf "--version"
check_tool gh "--version"

echo ""
echo -e "${BLUE}=== Modern CLI Tools (From mise) ===${NC}"

# Parse tools from .mise.toml [tools] section
if [[ -f "${DOTFILES_ROOT}/.mise.toml" ]]; then
    # Extract tool names from .mise.toml
    while IFS= read -r line; do
        tool_name=$(echo "$line" | awk -F= '{print $1}' | xargs)
        [[ -z "$tool_name" || "$tool_name" =~ ^# ]] && continue

        case "$tool_name" in
            bat) check_tool bat "--version" || check_tool batcat "--version" ;;
            fd) check_tool fd "--version" || check_tool fdfind "--version" ;;
            *) check_tool "$tool_name" "--version" ;;
        esac
    done < <(sed -n '/^\[tools\]/,/^\[/p' "${DOTFILES_ROOT}/.mise.toml" | grep -E '^\w+\s*=\s*"')
else
    echo -e "${YELLOW}⚠${NC} .mise.toml not found - using fallback"
    check_tool bat "--version" || check_tool batcat "--version"
    check_tool eza "--version"
    check_tool fd "--version" || check_tool fdfind "--version"
fi

echo ""
echo -e "${BLUE}=== Version Manager ===${NC}"
check_tool mise "--version"

echo ""
echo -e "${BLUE}=== Developer Tools ===${NC}"
check_tool lazygit "--version"
check_tool yazi "--version"
check_tool just "--version"
check_tool glow "--version"
check_tool hyperfine "--version"
check_tool dive "--version"
check_tool ctop "-v"  # ctop uses -v not --version
check_tool lazydocker "--version"

echo ""
echo -e "${BLUE}=== Security & Code Quality ===${NC}"
check_tool gitleaks "version"

# Check pre-commit (prefer user-installed version over virtualenv)
if [[ -x "$HOME/.local/bin/pre-commit" ]]; then
    # Use local version but display as "pre-commit" not full path
    precommit_version=$("$HOME/.local/bin/pre-commit" --version 2>&1 | head -1)
    echo -e "${GREEN}✓${NC} pre-commit: $precommit_version"
elif command -v pre-commit &>/dev/null; then
    check_tool pre-commit "--version"
else
    echo -e "  ○ pre-commit: not installed (optional)"
fi

check_tool sops "--version"
check_tool gpg "--version"

echo ""
echo -e "${BLUE}=== Productivity Tools ===${NC}"
check_tool tldr "--version"
check_tool cheat "--version"
check_tool fastfetch "--version" || check_tool neofetch "--version"

echo ""
echo -e "${BLUE}=== Optional Development Tools ===${NC}"
check_tool direnv "version"
check_tool autojump "--version"
check_tool poetry "--version"
check_tool docker "--version"
check_tool docker-compose "--version"

echo ""
echo -e "${BLUE}=== Oh-My-Zsh Plugins ===${NC}"
if [[ -d ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions ]]; then
    echo -e "${GREEN}✓${NC} zsh-autosuggestions: installed"
else
    echo -e "  ○ zsh-autosuggestions: not installed"
fi

if [[ -d ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting ]]; then
    echo -e "${GREEN}✓${NC} zsh-syntax-highlighting: installed"
else
    echo -e "  ○ zsh-syntax-highlighting: not installed"
fi

if [[ -d ~/.oh-my-zsh/custom/plugins/zsh-fzf-history-search ]]; then
    echo -e "${GREEN}✓${NC} zsh-fzf-history-search: installed"
else
    echo -e "  ○ zsh-fzf-history-search: not installed"
fi

if [[ -d ~/.oh-my-zsh/custom/themes/powerlevel10k ]]; then
    echo -e "${GREEN}✓${NC} powerlevel10k theme: installed"
else
    echo -e "  ○ powerlevel10k theme: not installed"
fi

echo ""
echo -e "${BLUE}=== Forgit (Git + FZF Integration) ===${NC}"
if [[ -d ~/.forgit ]]; then
    echo -e "${GREEN}✓${NC} forgit: installed"
else
    echo -e "  ○ forgit: not installed (optional)"
fi

echo ""
echo -e "${BLUE}=== mise config drift ===${NC}"
# Why this check exists: ~/.config/mise/config.toml is supposed to be a SYMLINK to
# ~/.dotfiles/.mise.toml, so the repo is the single source of truth. `./install`
# only creates that symlink when the target is absent or byte-identical; if a real
# file is already there and differs, it prints one warning and keeps the local copy
# — forever. That state is stable, self-perpetuating, and invisible.
#
# It happened, and it was not cosmetic: the live config declared 10 tools while the
# repo declared 23, so ~11 installed tools were simply never put on PATH. `delta` was
# one of them, and gitconfig routes pager.diff/log/show/reflog through it — so
# `git diff` failed outright in a terminal with "unable to execute pager 'delta'".
# Nothing anywhere reported it.
MISE_ACTIVE="$HOME/.config/mise/config.toml"
# Deliberately $HOME/.dotfiles, NOT $DOTFILES_ROOT — the inconsistency with the
# tool inventory above is the point, not an oversight. This check asks whether
# the LIVE symlink points at the canonical deployment; run from a worktree,
# comparing against the worktree's own .mise.toml would call a correctly-linked
# machine drifted.
MISE_REPO="$HOME/.dotfiles/.mise.toml"
if [[ ! -e "$MISE_ACTIVE" ]]; then
    echo -e "${YELLOW}✗${NC} no active mise config at $MISE_ACTIVE"
elif [[ -L "$MISE_ACTIVE" ]] && [[ "$(readlink -f "$MISE_ACTIVE")" == "$(readlink -f "$MISE_REPO")" ]]; then
    echo -e "${GREEN}✓${NC} mise config symlinked to dotfiles (single source of truth)"
else
    echo -e "${YELLOW}✗${NC} mise config is NOT symlinked to $MISE_REPO"
    echo "    Declared tools will silently never reach PATH. Diff them, then:"
    echo "      ln -sfn $MISE_REPO $MISE_ACTIVE && mise install"
fi

# Every tool the repo declares must actually contribute a binary directory.
#
# `mise bin-paths` is the right probe, and the only one that isn't a heuristic: it
# lists the bin dir each active tool contributes, which is exactly what comes back
# EMPTY when a version pin no longer exists in its backend. glow 1.5.1 and fastfetch
# 2.8.10 both failed this way — mise created the install directory, reported "all
# tools are installed", and produced no binary at all.
#
# Rejected alternatives, each of which produced false positives here:
#   - `mise which <tool>` takes a BINARY name; several tools ship binaries named
#     differently (awscli->aws, ripgrep->rg, helix->hx, rust->rustc).
#   - `mise where <tool>` + find: the install dir may be a symlink (rust) and the
#     binary may sit at an arbitrary depth (fastfetch: <pkg>/usr/bin/fastfetch).
if command -v mise &>/dev/null && [[ -f "$MISE_REPO" ]]; then
    binpaths=$(mise bin-paths 2>/dev/null)
    no_binary=""
    while IFS= read -r tool; do
        grep -q "/installs/${tool}/" <<<"$binpaths" || no_binary+=" $tool"
    done < <(sed -n '/^\[tools\]/,/^\[/p' "$MISE_REPO" | grep -oE '^[a-z0-9_-]+' | sort -u)

    if [[ -z "$no_binary" ]]; then
        echo -e "${GREEN}✓${NC} every tool declared in .mise.toml contributes a binary"
    else
        echo -e "${YELLOW}✗${NC} declared but contributing NO binary:$no_binary"
        echo "    Usually a version pin that no longer exists in its backend — mise"
        echo "    still reports 'installed'. Check 'mise ls-remote <tool>' and re-pin,"
        echo "    or remove the tool from .mise.toml. A declaration that does not match"
        echo "    reality is what caused the drift above."
    fi
fi

fi  # end of the full-install report (skipped under --herdr)

echo ""
echo -e "${BLUE}=== herdr server environment hygiene ===${NC}"
# Why this check exists: every herdr pane inherits the SERVER's environment, and
# the server inherits whatever started it. On 2026-08-29 the server was restarted
# from inside a herdmates team-lead pane, so every pane on the machine got a fake
# TMUX=teammux,0,0, the teammux shim ahead of real tmux on PATH, HERDR_PANE_ID=w2:p1,
# CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 and herdmates' plugin state dirs. Every
# Claude session became a "team of one", `tmn`/`tmux kill-server` hit the shim, the
# runbook's `command -v tmux` capability check passed for everyone — and nothing
# reported it (herdr-eval finding F1). scripts/herdr-server-launch.sh (run by
# systemd/herdr-server.service) is the fix; this asserts the RUNNING server is
# actually clean. Variable NAMES only are printed, never values.
#
# `(^|/)herdr server$`, not the guide's looser `herdr server`: the loose form also
# matches any shell whose command line merely contains the string — including a
# `bash -c '… herdr server …'` that is running this very check.
HERDR_FORBIDDEN_VARS=(TMUX TMUX_PANE TEAMMUX_STATE_PATH HERDR_PANE_ID HERDR_TAB_ID
    HERDR_WORKSPACE_ID HERDR_PLUGIN_STATE_DIR HERDR_PLUGIN_CONFIG_DIR
    CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS CLAUDECODE CLAUDE_CODE_SESSION_ID
    CLAUDE_CODE_CHILD_SESSION)
# This section is the one ASSERTION in the script (see EXIT CODE in the header):
# a FAIL here sets this flag and the script exits non-zero at the bottom.
herdr_hygiene_failed=0
herdr_pid=$(pgrep -f '(^|/)herdr server$' 2>/dev/null | head -1)
server_path=""
if [[ -z "$herdr_pid" ]]; then
    echo "  ○ no 'herdr server' process — skipped (start: systemctl --user start herdr-server.service)"
elif [[ ! -r "/proc/$herdr_pid/environ" ]]; then
    echo -e "${YELLOW}⚠${NC} cannot read /proc/$herdr_pid/environ — skipped (no /proc here? try: ps eww -p $herdr_pid)"
else
    # NUL-delimited parse: a value containing a newline must not masquerade as a name.
    server_names=""
    server_sess=""
    while IFS= read -r -d '' entry; do
        name="${entry%%=*}"
        server_names+="$name"$'\n'
        [[ "$name" == PATH ]] && server_path="${entry#PATH=}"
        # Kept with their VALUES for the completeness check below. A server that
        # outlived a logout holds a DISPLAY naming a dead session — present, so a
        # names-only check cannot see it.
        case "$name" in
            DISPLAY|WAYLAND_DISPLAY|XAUTHORITY) server_sess+="$entry"$'\n' ;;
        esac
    done < "/proc/$herdr_pid/environ"

    leaked=""
    for v in "${HERDR_FORBIDDEN_VARS[@]}"; do
        grep -qx "$v" <<<"$server_names" && leaked+=" $v"
    done
    shim_entries=$(tr ':' '\n' <<<"$server_path" | grep '/teammux/bin' | tr '\n' ' ')
    shim_entries="${shim_entries% }"

    # "Clean" is not "complete", and they are different questions. Everything
    # above asks only whether something FORBIDDEN is present. A server started at
    # boot — before any graphical session existed to import an environment from —
    # carries no forbidden variable at all, so it passed as clean while every pane
    # had lost `gh --web`, `xdg-open` and the ssh agent. That is the regression the
    # graphical-session.target [Install] exists to prevent, and nothing here saw it.
    #
    # Compared against the USER MANAGER's own environment rather than a fixed
    # list: that is what a correctly started server would have inherited, and on a
    # headless box neither side has these, so there is correctly nothing to
    # report. Names only in the output — see the note at the top of this section.
    sess_missing=""; sess_stale=""; mgr_env=""
    if command -v systemctl >/dev/null 2>&1 && [[ -n "${XDG_RUNTIME_DIR:-}" ]] \
       && mgr_env="$(systemctl --user show-environment 2>/dev/null)"; then
        for v in DISPLAY WAYLAND_DISPLAY XAUTHORITY SSH_AUTH_SOCK; do
            grep -q "^${v}=" <<<"$mgr_env" || continue   # this session does not offer it
            if ! grep -qx "$v" <<<"$server_names"; then
                sess_missing+=" $v"
                continue
            fi
            # SSH_AUTH_SOCK, and ONLY SSH_AUTH_SOCK, is excluded from the VALUE
            # comparison: the launcher substitutes a stable symlink for it on
            # purpose, so a difference there is by design rather than drift.
            #
            # XAUTHORITY used to be excluded too, silently — and it is the only
            # one of the three that a re-login changes. DISPLAY (:0) and
            # WAYLAND_DISPLAY (wayland-0) are deterministic per session, so
            # comparing them detects nothing; XAUTHORITY is a per-login temp file
            # (/run/user/1000/.mutter-Xwaylandauth.<random>). A server that
            # outlived a logout therefore matched on both compared values and
            # printed the all-clear while holding a deleted Xauthority — exactly
            # the case this check was added for, and the one the launcher's own
            # header warns about ("X11 tools then fail until the next ...").
            case "$v" in SSH_AUTH_SOCK) continue ;; esac
            if [[ "$(grep "^${v}=" <<<"$mgr_env" | head -1)" \
               != "$(grep "^${v}=" <<<"$server_sess" | head -1)" ]]; then
                sess_stale+=" $v"
            fi
        done
    fi

    if [[ -z "$leaked" && -z "$shim_entries" ]]; then
        echo -e "${GREEN}✓${NC} herdr server (pid $herdr_pid) environment is clean"
    else
        if [[ -n "$leaked" ]]; then
            echo -e "${RED}✗ FAIL:${NC} herdr server (pid $herdr_pid) environment carries:$leaked"
            herdr_hygiene_failed=1
        fi
        if [[ -n "$shim_entries" ]]; then
            echo -e "${RED}✗ FAIL:${NC} herdr server PATH contains a teammux shim: $shim_entries"
            herdr_hygiene_failed=1
        fi
        echo "    The server was started from inside a herdr pane or a Claude session, and"
        echo "    every pane inherits this. Restart it from a clean environment — this ENDS"
        echo "    every agent session, so check 'herdr pane list' first:"
        echo "      systemctl --user restart herdr-server.service         # if the unit is enabled"
        echo "      herdr server stop; scripts/herdr-server-launch.sh &   # else, from a PLAIN terminal"
    fi

    if [[ -n "$sess_missing" ]]; then
        echo -e "${RED}✗ FAIL:${NC} herdr server is missing session variables this session provides:$sess_missing"
        echo "    Panes inherit that: no 'gh --web', no 'xdg-open', and the slow ssh-agent path."
        echo "    Typically a server started before the graphical session existed. Check that the"
        echo "    unit is enabled under the target its own file declares:"
        echo "      scripts/reconcile-systemd-units.sh --check"
        herdr_hygiene_failed=1
    elif [[ -n "$sess_stale" ]]; then
        # WARN, not FAIL: everything works until the old session's socket dies,
        # and the unit deliberately does not restart across a logout.
        echo -e "${YELLOW}⚠${NC} herdr server holds session variables from a PREVIOUS login:$sess_stale"
        echo "    Desktop-opening plugin actions fail silently. A restart fixes it and ENDS EVERY"
        echo "    AGENT SESSION — do it from a plain terminal when the panes are idle."
    elif [[ -n "$mgr_env" ]]; then
        echo -e "${GREEN}✓${NC} herdr server has the session variables this session provides"
    fi

    # WARN, not FAIL, and it does not affect the exit code: a server without the
    # key is degraded (no Linear picker), not contaminated.
    if grep -qx 'LINEAR_API_KEY' <<<"$server_names"; then
        echo -e "${GREEN}✓${NC} LINEAR_API_KEY present in the server environment"
    else
        echo -e "${YELLOW}⚠${NC} LINEAR_API_KEY absent from the server environment — tdi.worktree-from-linear"
        echo "    (the Linear picker) cannot authenticate. Set it in ~/.zshrc.local BEFORE the"
        echo "    server starts; the launcher reads it from there."
    fi
fi

echo ""
echo -e "${BLUE}=== systemd user unit enablement vs the linked unit files ===${NC}"
# Also an ASSERTION (see EXIT CODE in the header). systemd records [Install] at
# `enable` time, so editing WantedBy= in a unit file moves nothing until the
# enablement is redone — and ./install is not in this repo's deploy path, because
# `git checkout` here IS the deploy. So the enablement silently keeps pointing at
# whatever target was current when the unit was first enabled. On this machine
# that meant the server would have kept starting at boot, before any graphical
# session existed, which the section above would then have called "clean".
# WHICH checkout to ask about. Not $DOTFILES_ROOT: deriving that from
# BASH_SOURCE fixed a real bug (see :58) but made THIS assertion vacuous when
# run from a worktree -- which `dotfiles-work` makes the normal place to run it.
# It skipped with "no units linked from <worktree>" while the live deployment
# had an enabled unit, so exit 0 meant "not checked" in the section whose own
# comment says a missing checker is not a pass. Found in review.
#
# The enablement question is about the LIVE deployment, so resolve it from the
# links systemd actually holds and report which checkout that turned out to be.
# A side benefit: with a fake HOME there are no links, so nothing is executed
# and the section is genuinely hermetic (it used to shell out to the real
# script on every test row).
enable_root=""
enable_found_link=0
for _u in "$HOME"/.config/systemd/user/*.service "$HOME"/.config/systemd/user/*.timer \
          "$HOME"/.config/systemd/user/*.socket  "$HOME"/.config/systemd/user/*.path \
          "$HOME"/.config/systemd/user/*.target; do
    [[ -L "$_u" ]] || continue
    _t="$(readlink -f "$_u" 2>/dev/null)" || continue
    # Only links that point into a checkout's systemd/ dir are ours to reconcile.
    [[ "$_t" == */systemd/* ]] || continue
    enable_found_link=1
    _cand="${_t%/systemd/*}"
    if [[ -x "$_cand/scripts/reconcile-systemd-units.sh" ]]; then
        enable_root="$_cand"
        break
    fi
done

if (( ! enable_found_link )); then
    echo "  ○ no managed systemd user units linked into ~/.config/systemd/user — skipped"
elif [[ -z "$enable_root" ]]; then
    # Units ARE linked; we just cannot check them. Not a pass.
    echo -e "${RED}✗ FAIL:${NC} units are linked into ~/.config/systemd/user but the checkout they"
    echo "    point into has no scripts/reconcile-systemd-units.sh — enablement UNCHECKED"
    herdr_hygiene_failed=1
elif [[ -x "$enable_root/scripts/reconcile-systemd-units.sh" ]]; then
    [[ "$enable_root" != "$DOTFILES_ROOT" ]] && \
        echo "  · checking the checkout the live links point into: $enable_root"
    if ! "$enable_root/scripts/reconcile-systemd-units.sh" --check; then
        herdr_hygiene_failed=1
        # `./install` on a modular machine links ~/.zshrc, ~/.gitconfig,
        # ~/.tmux.conf, ~/.p10k.zsh and VS Code's settings -- the exact takeover
        # --herdr exists to avoid, printed as the remedy inside --herdr output.
        # install.conf.herdr.yaml runs the reconcile too, so the right advice
        # already exists.
        if [[ "$HERDR_ONLY" == true ]]; then
            echo "    Fix: ./install --herdr — it reconciles this."
        else
            echo "    Fix: ./install — it reconciles this."
        fi
        # NOT `systemctl --user reenable`, which this line used to suggest. Its
        # disable half removes every symlink in the unit search path pointing at
        # the unit, and for a dotbot-installed unit the entry in
        # ~/.config/systemd/user IS such a symlink, into the checkout — so it
        # deletes the unit and the enable half then fails with "Unit does not
        # exist". That happened on this machine on 2026-09-01, from advice this
        # repo printed. The warning was added to the unit header, install.conf.yaml
        # and CLAUDE.md, and missed here: the one place a user reads mid-failure,
        # with the destructive command last on the line.
    fi
else
    # A FAIL, not a warning: this section is one of the two assertions the exit
    # code is built on, and "the checker is missing" is not a pass. Reporting it
    # as a warning let the check be absent and the script still exit 0 — the
    # unanswerable question resolving to the answer it would have had if
    # everything were fine, which is the failure mode this whole file is about.
    echo -e "${RED}✗ FAIL:${NC} $enable_root/scripts/reconcile-systemd-units.sh missing — enablement UNCHECKED"
    herdr_hygiene_failed=1
fi

echo ""
echo -e "${BLUE}=== Plugin dependencies under the herdr SERVER PATH ===${NC}"
# Why: the server's PATH is a snapshot taken when it started, and it is what every
# plugin and popup resolves against — not your shell's PATH (mise adds tools per
# shell from a precmd hook, so a shell check proves nothing). A tool missing here
# shows up as a pane that flickers and vanishes, with no error anywhere. Checked
# ONE AT A TIME: POSIX `command -v a b` exits 0 when only the FIRST resolves.
# `/bin/sh` by absolute path so `env -i` does not have to find the shell itself.
# With no server running, the launcher's declared PATH is used instead, so a fresh
# machine still learns what would be missing.
HERDR_SERVER_DEPS=(herdr herdmates teammux bun node python3 jq gh notify-send lazygit yazi clauth sh bash)
herdr_launcher="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/herdr-server-launch.sh"
declared_path=""
if [[ -x "$herdr_launcher" ]]; then
    declared_path=$("$herdr_launcher" --print-env 2>/dev/null | sed -n 's/^PATH=//p')
fi
# $server_path is only set above when /proc/<pid>/environ was READABLE, so an
# empty one means either "no server" or "a server whose environment could not be
# read" — two states that need different sentences and, more importantly,
# different downstream behaviour. Reported as one, this section announced "no
# server running" about a server that is running, and the live-vs-declared drift
# warning at the bottom then compared the declared PATH against itself and could
# never fire again. Hence live_server_path: the drift check needs the LIVE value,
# not whatever $server_path was last assigned.
live_server_path="$server_path"
if [[ -n "$live_server_path" ]]; then
    echo "  resolving against the live server's PATH (pid $herdr_pid)"
elif [[ -n "$declared_path" ]]; then
    server_path="$declared_path"
    if [[ -n "$herdr_pid" ]]; then
        echo -e "  ${YELLOW}⚠${NC} server pid $herdr_pid is running but its environment was unreadable —"
        echo "    resolving against the launcher's declared PATH instead; live-vs-declared PATH"
        echo "    drift is UNCHECKED for this run (see the ⚠ in the hygiene section above)."
    else
        echo "  no server running — resolving against the launcher's declared PATH"
    fi
fi
if [[ -z "$server_path" ]]; then
    echo "  ○ no server PATH available (no server, no launcher) — skipped"
else
    missing_deps=""
    for dep in "${HERDR_SERVER_DEPS[@]}"; do
        # shellcheck disable=SC2016  # "$1" is for /bin/sh to expand, deliberately not bash
        if resolved=$(env -i PATH="$server_path" /bin/sh -c 'command -v "$1"' sh "$dep" 2>/dev/null); then
            echo -e "${GREEN}✓${NC} $dep → $resolved"
        else
            echo -e "${YELLOW}✗${NC} $dep: MISSING under the server PATH"
            missing_deps+=" $dep"
        fi
    done
    if [[ -n "$missing_deps" ]]; then
        echo "    Install it, or symlink it into ~/.local/bin (on the server PATH; takes effect"
        echo "    without a restart). A tool added to mise needs a server restart to be seen."
    fi
    # $live_server_path, never $server_path: the latter falls back to
    # $declared_path, and comparing that against itself is a check that reports
    # success in every state, including the one it exists to catch.
    if [[ -n "$live_server_path" && -n "$declared_path" && "$declared_path" != "$live_server_path" ]]; then
        echo -e "${YELLOW}⚠${NC} the live server's PATH differs from the launcher's declared PATH — the server"
        echo "    predates a mise/PATH change, or was not started via herdr-server-launch.sh."
        echo "    A restart (see above) brings the two back together."
    fi
fi

echo ""
echo -e "${BLUE}=== Claude Code wiring ===${NC}"
# The two steps ./install CANNOT do, both of which fail silently and neither of
# which was checked by anything until DO-563. Asserted in BOTH modes: the full
# install links the statusline hook and wires nothing, exactly like the modular
# one, so this is not a modular-only concern.
#
#   statusLine       without it every $mdl / $eff_* / $ctx_* token resolves to
#                    nothing and those sidebar rows render EMPTY, no error.
#   refreshInterval  without it the idle band freezes when a session goes quiet
#                    and every token then expires on the 4-minute TTL -- the
#                    same blank rows, arriving later and looking unrelated.
#   SKILL.md         `herdr --skill` only PRINTS; nothing generates the file, so
#                    a lead agent silently has no herdr CLI reference.
#
# FAIL rather than WARN because both are one command to fix, and that command is
# named on every failing line. An unfixable condition would be a WARN (see the
# keyring collapse in gh-doctor); these are not.
claude_wiring_failed=0
CC_SETTINGS="$HOME/.claude/settings.json"
CC_HOOK="$HOME/.claude/hooks/session-statusline.sh"
CC_SKILL="$HOME/.claude/skills/herdr/SKILL.md"
# Absolute: this script may be invoked as `verify-tools` from ~/.local/bin, and
# a relative remedy is not pasteable from an arbitrary cwd. The full-install
# summary already prints absolute paths, so relative ones here made the two
# halves of one report disagree.
CC_FIX="    Fix: $DOTFILES_ROOT/scripts/herdr-claude-wire.sh"

# SKIP when there is nothing to wire, matching all three sibling herdr sections
# (each degrades to `○ skipped` when its subject is absent). Asserting
# unconditionally made this permanently red for a full-install user who does not
# run herdr -- whose only "fix" would be to install two programs they chose not
# to -- and red on any machine straight after `./install`, before anyone had the
# chance to wire anything. That is the permanently-red checker this repo warns
# about twice, reproduced in the change that exists to remove one. Found in
# review, not in use.
#
# The gate is deliberately narrow: herdr present AND Claude Code having run here
# means an unwired statusLine is a real, actionable fault, so it stays a ✗.
# Body NOT re-indented, same reason as the full-install block above.
if ! command -v herdr &>/dev/null; then
    echo "  ○ herdr not installed — skipped (this section checks the bridge between herdr and Claude Code)"
elif [[ ! -d "$HOME/.claude" ]]; then
    # Belt-and-braces only: dotbot links ~/.claude/hooks/session-statusline.sh in
    # BOTH install paths, so this directory exists on any machine that ran either
    # one. `command -v herdr` is the arm that actually fires; this one covers a
    # hand-copied checkout.
    echo "  ○ no ~/.claude — Claude Code has not run here; skipped"
else

if ! command -v jq &>/dev/null; then
    # An empty answer is never agreement: with no JSON parser this check cannot
    # be performed, and saying nothing would read as saying it passed.
    echo -e "${YELLOW}⚠${NC} jq not installed — statusLine NOT CHECKED (install jq to check it)"
elif [[ ! -e "$CC_SETTINGS" ]]; then
    echo -e "${RED}✗ FAIL:${NC} no ${CC_SETTINGS/#$HOME/\~} — statusLine is not wired"
    echo "$CC_FIX"
    claude_wiring_failed=1
elif ! jq -e . "$CC_SETTINGS" &>/dev/null; then
    echo -e "${RED}✗ FAIL:${NC} ${CC_SETTINGS/#$HOME/\~} is not valid JSON — statusLine cannot be read"
    echo "    Claude Code reads this file too, so this is not only a herdr problem. Fix it by hand."
    claude_wiring_failed=1
else
    # Type before value: `.statusLine.command` is a jq ERROR on a non-object
    # statusLine, and an unchecked empty capture reported "no statusLine" for a
    # file that has one of the wrong shape -- a confident wrong answer, and it
    # leaked jq's own stderr into the report. Same defect as the wirer's.
    cc_type="$(jq -r '.statusLine | type' "$CC_SETTINGS" 2>/dev/null)" || cc_type=""
    [[ -n "$cc_type" ]] || cc_type="unreadable"
    cc_cmd=""; cc_int=""
    if [[ "$cc_type" == object ]]; then
        cc_cmd="$(jq -r '.statusLine.command // ""' "$CC_SETTINGS" 2>/dev/null)"
        cc_int="$(jq -r '.statusLine.refreshInterval // ""' "$CC_SETTINGS" 2>/dev/null)"
    fi
    if [[ "$cc_type" != null && "$cc_type" != object ]]; then
        echo -e "${RED}✗ FAIL:${NC} statusLine is a ${cc_type}, not an object — Claude Code will not run it"
        echo "    Inspect ${CC_SETTINGS/#$HOME/\~} by hand; herdr-claude-wire.sh refuses to overwrite it."
        claude_wiring_failed=1
    elif [[ -z "$cc_cmd" ]]; then
        echo -e "${RED}✗ FAIL:${NC} no statusLine in ${CC_SETTINGS/#$HOME/\~} — every sidebar row will render empty"
        echo "$CC_FIX"
        claude_wiring_failed=1
    elif [[ "$cc_cmd" != *session-statusline.sh* ]]; then
        # Not ours, and settings.json has room for exactly one statusLine.
        echo -e "${RED}✗ FAIL:${NC} statusLine belongs to something else: $cc_cmd"
        echo "    herdr's sidebar rows cannot populate while another publisher owns this key."
        claude_wiring_failed=1
    elif ! jq -e '.statusLine.refreshInterval | type == "number" and . > 0 and . <= 240' \
              "$CC_SETTINGS" >/dev/null 2>&1; then
        # A bare numeric regex on `jq -r` output accepted three values that are
        # equivalent to the key being absent: the JSON STRING "60" (jq -r strips
        # the quotes), 0, and anything past the TTL. All three reported ✓.
        #
        # The 240s upper bound is INFERRED from this repo's own note that tokens
        # expire on a 4-minute TTL -- not from testing Claude Code, which has not
        # been checked for whether it honours 0 or a string. The lower bound and
        # the type are not inferences.
        echo -e "${RED}✗ FAIL:${NC} statusLine refreshInterval is not a usable number: ${cc_int:-<absent>}"
        echo "    Must be a JSON number, 0 < n <= 240 — tokens expire on a 4-minute TTL, so a"
        echo "    larger interval (or 0, or a quoted \"60\") blanks the rows it exists to keep alive."
        echo "$CC_FIX"
        claude_wiring_failed=1
    elif [[ ! -e "$CC_HOOK" ]]; then
        echo -e "${RED}✗ FAIL:${NC} statusLine points at ${CC_HOOK/#$HOME/\~}, which does not exist"
        echo "    Run ./install --herdr (dotbot links it); wiring alone cannot substitute for the file."
        claude_wiring_failed=1
    else
        echo -e "${GREEN}✓${NC} statusLine wired (refreshInterval ${cc_int})"
    fi
fi

# -f, not -e: a DIRECTORY named SKILL.md satisfies both -e and -s (a directory
# is never zero-length), so `mkdir SKILL.md` produced "✓ agent skill file
# present" and exit 0. Found in review.
if [[ -d "$CC_SKILL" ]]; then
    echo -e "${RED}✗ FAIL:${NC} ${CC_SKILL/#$HOME/\~} is a DIRECTORY, not a file"
    echo "    Remove it; nothing can generate the skill file over a directory."
    claude_wiring_failed=1
elif [[ ! -f "$CC_SKILL" ]]; then
    echo -e "${RED}✗ FAIL:${NC} no ${CC_SKILL/#$HOME/\~} — your agents have no herdr CLI reference"
    echo "$CC_FIX"
    claude_wiring_failed=1
elif [[ ! -s "$CC_SKILL" ]]; then
    # `herdr --skill` on a broken install exits 0 and prints nothing, so a
    # zero-byte file is the likely result of a truncated redirect -- and it is
    # indistinguishable from a wired one until an agent reads it.
    echo -e "${RED}✗ FAIL:${NC} ${CC_SKILL/#$HOME/\~} is empty — 'herdr --skill' produced nothing"
    echo "$CC_FIX"
    claude_wiring_failed=1
elif command -v herdr &>/dev/null && ! diff -q <(herdr --skill 2>/dev/null) "$CC_SKILL" &>/dev/null; then
    # A stale skill file is what the wirer's own header calls "worse than none,
    # because it looks fine": it teaches a lead agent flags that no longer
    # exist. ⚠ and NOT part of the exit code, deliberately -- it goes stale on
    # every `herdr update`, and a ✗ that appears on every upgrade until someone
    # re-runs a command is the permanently-red checker in slow motion.
    echo -e "${YELLOW}⚠${NC} agent skill file is stale — it differs from 'herdr --skill' output"
    echo "    Regenerate: scripts/herdr-claude-wire.sh (it is version-specific)"
else
    echo -e "${GREEN}✓${NC} agent skill file present"
fi

fi  # end of the Claude Code wiring section (skipped when there is nothing to wire)

echo ""
echo -e "${BLUE}=== Summary ===${NC}"
if [[ "$HERDR_ONLY" == true ]]; then
    # Deliberately NOT the full report's advice: a modular adopter linked five
    # files and no mise config, so "run mise install" and "read CLAUDE.md" are
    # instructions for a machine they did not install.
    echo "Modular herdr install."
    echo "  Runtime dependencies: $DOTFILES_ROOT/scripts/herdr-deps-check.sh"
    echo "  Claude Code wiring:   $DOTFILES_ROOT/scripts/herdr-claude-wire.sh"
    echo "  Full guide:           $DOTFILES_ROOT/docs/HERDR_GUIDE.md"
else
    echo "For installation instructions, see:"
    echo "  - ~/.dotfiles/CLAUDE.md (comprehensive guide)"
    echo "  - ~/.dotfiles/scripts/install-modern-tools.sh (automated installer)"
    echo ""
    echo "To install missing tools via mise:"
    echo "  mise install"
fi
echo ""

# Non-zero on a herdr ASSERTION failure — see EXIT CODE in the header. Both
# counters, not just the first: OR-ing them here is what keeps a green tick from
# one section standing in for the other.
if (( herdr_hygiene_failed || claude_wiring_failed )); then
    exit 1
fi
exit 0
