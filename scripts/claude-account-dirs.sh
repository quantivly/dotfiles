#!/usr/bin/env bash
#
# scripts/claude-account-dirs.sh
# ==============================
#
# Builds a PERSISTENT, isolated CLAUDE_CONFIG_DIR for a clauth profile, at
# ~/.local/state/claude-account-dirs/<profile>/, and prints its path on stdout.
#
# WHY THIS EXISTS. `clauth start <profile>` already gives a session an isolated
# credential without losing anything else — its runtime dir symlinks hooks,
# plugins, skills, CLAUDE.md, projects and the rest back to ~/.claude/ and points
# only .credentials.json at the profile's own store. But it launches the claude
# BINARY, so it never passes through the claude() wrapper in zsh/zshrc.herdr, and
# a session started that way has no teammateMode:tmux and cannot lead a herdr
# team. Its runtime dirs are also per-run and torn down.
#
# A directory with the same layout and a STABLE path removes both limits at once:
# `CLAUDE_CONFIG_DIR=<dir> claude` is the shell function, so it gets the teammux
# launch AND the isolated credential. That composition is verified, not assumed —
# zsh exports a prefix assignment on a FUNCTION call into that function's
# children (`zsh -f -c 'f(){ printenv V; }; V=x f'` prints x), which is what makes
# it work at all.
#
# THE THREE FILES THAT ARE NOT SYMLINKS, and why each is what it is:
#
#   .credentials.json  ->  symlink to ~/.clauth/profiles/<p>/credentials.json.
#       NEVER a copy. A copy is an independent holder of one OAuth grant, and
#       refresh-token rotation is server-side, so the first rotation orphans the
#       other holder for real. The symlink is also verified to be written THROUGH
#       rather than replaced: that profile store carries mcpOAuth discovery
#       records that only Claude Code writes.
#
#   settings.json      ->  a real file, REFRESHED from ~/.claude/settings.json on
#       every build. Not a symlink: clauth rewrites the global file's `env` and
#       `[models]` blocks on a profile switch (it is how `model` came to be null
#       there), and a symlink imports that churn into every account dir. A refresh
#       at build time is exactly the launch-time snapshot clauth's own runtime
#       dirs take, and this script runs at launch.
#
#   .claude.json       ->  a real file, seeded ONCE and never overwritten. It
#       holds oauthAccount and userID, which must differ per account, plus the
#       project trust records and the onboarding flag.
#
#       THE SEED IS ~/.claude.json, NOT ~/.claude/.claude.json. Claude Code keeps
#       this file in $HOME, and only moves it under CLAUDE_CONFIG_DIR when that is
#       set. On this machine ~/.claude/.claude.json is a 1,156-byte husk with
#       projects:{}, no hasCompletedOnboarding and a DIFFERENT machineID, last
#       written 2026-08-28, while ~/.claude.json is 95 kB with 21 projects and
#       matches what clauth seeds into its runtime dirs. Seeding from the husk
#       would give every account dir first-run onboarding and a trust dialog in
#       every worktree — silently, because a husk is still valid JSON. That is why
#       an implausibly small seed is a hard error here rather than a default.
#
# Everything else in ~/.claude/ is symlinked back, DERIVED FROM THE LIVE
# DIRECTORY rather than from a list in this file. A hand-maintained mirror of a
# directory listing drifts by construction — the version of this script that
# named its files explicitly hardcoded five machine-specific settings.json.bak-*
# entries and still missed two that clauth links.
#
# Idempotent and additive. It never writes to ~/.claude/, ~/.claude.json or
# anything under ~/.clauth/. Delete the whole tree and re-run: the only thing lost
# is each account's .claude.json, which costs one onboarding.
#
# Usage:
#   scripts/claude-account-dirs.sh <profile> [<profile>...]
#   scripts/claude-account-dirs.sh --all

set -euo pipefail

GLOBAL_DIR="$HOME/.claude"
GLOBAL_JSON="$HOME/.claude.json"
PROFILES_DIR="$HOME/.clauth/profiles"
ROOT="${CLAUDE_ACCOUNT_DIRS_ROOT:-$HOME/.local/state/claude-account-dirs}"

# Under this, ~/.claude.json is not a config file, it is a husk — see the header.
# The real one is two orders of magnitude bigger; the husk that caused the bug was
# 1,156 bytes. Anything in between is unexplained and worth stopping for.
MIN_CLAUDE_JSON_BYTES=10240

# Handled individually below; everything else in $GLOBAL_DIR is symlinked.
SPECIAL=(.credentials.json .claude.json settings.json)

warn() { printf 'claude-account-dirs: %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

is_special() {
    local n
    for n in "${SPECIAL[@]}"; do [[ "$1" == "$n" ]] && return 0; done
    return 1
}

build_one() {
    local profile="$1" pdir account_dir name entry target
    pdir="$PROFILES_DIR/$profile"
    [[ -d "$pdir" ]] || die "no clauth profile '$profile' at ${pdir/#$HOME/\~}"
    [[ -f "$pdir/credentials.json" ]] \
        || die "'$profile' has no credentials.json yet — run 'clauth login $profile' first"
    [[ -d "$GLOBAL_DIR" ]] || die "no ${GLOBAL_DIR/#$HOME/\~} to inherit from"

    account_dir="$ROOT/$profile"
    mkdir -p "$account_dir"

    # 1. Everything shared, derived from what is actually in ~/.claude right now.
    shopt -s dotglob nullglob
    for entry in "$GLOBAL_DIR"/*; do
        name="${entry##*/}"
        is_special "$name" && continue
        ln -sfn "$entry" "$account_dir/$name"
    done

    # 2. Prune links whose source has since disappeared. A renamed source
    #    otherwise leaves a dangling link here forever, and [[ -e ]] follows
    #    symlinks, so nothing that merely checks existence would ever see it —
    #    the same trap the systemd reconciler was caught by (CLAUDE.md).
    for entry in "$account_dir"/*; do
        name="${entry##*/}"
        is_special "$name" && continue
        [[ -L "$entry" ]] || continue
        target="$(readlink "$entry")"
        [[ "$target" == "$GLOBAL_DIR/"* ]] || continue
        [[ -e "$target" ]] && continue
        rm -f "$entry"
        warn "$profile: pruned dangling link '$name' (its source is gone from ~/.claude)"
    done
    shopt -u dotglob nullglob

    # 3. The credential: a symlink to the profile's own store, never a copy.
    ln -sfn "$pdir/credentials.json" "$account_dir/.credentials.json"

    # 4. settings.json: a real file, refreshed every build.
    if [[ -f "$GLOBAL_DIR/settings.json" ]]; then
        if [[ -f "$account_dir/settings.json" ]] \
           && ! cmp -s "$GLOBAL_DIR/settings.json" "$account_dir/settings.json"; then
            warn "$profile: settings.json refreshed from ~/.claude/settings.json (it had drifted)"
        fi
        # Written via a temp file in the same directory so a session reading it
        # never sees a half-written one.
        cp "$GLOBAL_DIR/settings.json" "$account_dir/.settings.json.new"
        mv -f "$account_dir/.settings.json.new" "$account_dir/settings.json"
    else
        warn "$profile: no ~/.claude/settings.json to copy — the statusline and hooks will be absent"
    fi

    # 5. .claude.json: real, seeded once, never overwritten by a re-run.
    if [[ ! -e "$account_dir/.claude.json" ]]; then
        [[ -f "$GLOBAL_JSON" ]] \
            || die "$profile: no ${GLOBAL_JSON/#$HOME/\~} to seed .claude.json from — refusing to create an unonboarded config dir"
        local size
        size=$(stat -Lc %s "$GLOBAL_JSON")
        if (( size < MIN_CLAUDE_JSON_BYTES )); then
            die "$profile: ${GLOBAL_JSON/#$HOME/\~} is only ${size} bytes — that is a husk, not a config file.
       Seeding from it would give this account dir first-run onboarding and a trust
       dialog in every worktree, silently, because a husk is still valid JSON.
       Check which file Claude Code is really using before re-running."
        fi
        cp -p "$GLOBAL_JSON" "$account_dir/.claude.json"
        chmod 600 "$account_dir/.claude.json"
    fi

    printf '%s\n' "$account_dir"
}

main() {
    (( $# )) || { printf 'Usage: %s <profile> [<profile>...] | --all\n' "$0" >&2; exit 2; }

    if [[ "$1" == "--all" ]]; then
        [[ -d "$PROFILES_DIR" ]] || die "no clauth profiles dir at ${PROFILES_DIR/#$HOME/\~}"
        # The DIRECTORIES, not profiles.toml's `profiles = [...]` array: a profile
        # clauth can actually launch is one with a directory and a credential here,
        # so this needs no TOML parser and cannot drift from what clauth would use.
        local d found=0
        shopt -s nullglob
        for d in "$PROFILES_DIR"/*/; do
            [[ -f "$d/credentials.json" ]] || continue
            found=1
            build_one "$(basename "$d")"
        done
        shopt -u nullglob
        (( found )) || die "no profiles with credentials.json under ${PROFILES_DIR/#$HOME/\~}"
    else
        local profile
        for profile in "$@"; do build_one "$profile"; done
    fi
}

main "$@"
