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
#       other holder for real.
#
#       CORRECTED 2026-09-08. This block used to claim the symlink was "verified
#       to be written THROUGH rather than replaced". IT IS NOT, and the claim was
#       never checked. Claude Code writes the credential ATOMICALLY (temp file +
#       rename), and a rename REPLACES a symlink with a real file. Measured: three
#       of four account dirs held real, diverged files, and `personal` was rebuilt
#       at 09:35 and replaced by 09:43 the same morning.
#
#       That alone is survivable -- one real file per account is still one holder.
#       What was NOT survivable is what this script then did with it: an
#       unconditional `ln -sfn` restored the symlink to the store's SUPERSEDED
#       token, and because the rotation had already invalidated it server-side,
#       every live session on that account was logged out. clauth quarantined
#       `personal` as auth_broken exactly this way. `claude()` runs this script on
#       every launch, so each new session on a profile re-armed the trap.
#
#       So the credential is now RECONCILED rather than relinked -- see
#       reconcile_credential(). The invariant it defends, stated once: for each
#       account there is exactly ONE credential file, and every process using that
#       account reads it. clauth's store is necessarily a live holder too
#       (`preemptive_rotation` defaults to true, so usage polling rotates), which
#       is why the account dir must SHARE that file rather than own a copy.
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

# How many superseded credential copies to keep per file. These are real
# credentials on disk, so the set is bounded -- but a destroyed one costs a
# browser re-login, so it is bounded rather than zero.
CRED_BACKUPS_KEPT=5

has_jq() { command -v jq >/dev/null 2>&1; }

# The expiry stamp inside a credential file, on stdout.
#   0 = a usable claudeAiOauth block, its expiresAt printed
#   1 = the file parses but carries no usable block. A discovery stub is the
#       common case: the entry Claude Code writes after OAuth discovery but
#       before authorisation has an empty accessToken and no expiresAt at all.
#   2 = no jq, so the question could not be asked
# NEVER prints a token: an integer is the only thing that leaves this function.
cred_expiry() {
    local f="$1"
    has_jq || return 2
    [[ -s "$f" ]] || return 1
    # -e so the EXIT STATUS decides, never the emptiness of the output. A capture
    # of nothing is indistinguishable from a legitimate answer, which is a bug
    # this repo has already shipped once (CLAUDE.md, _claude_cred_id).
    jq -e -r '.claudeAiOauth | select(type == "object") | .expiresAt
              | select(. != null) | tonumber' "$f" 2>/dev/null || return 1
}

# Which of the two files holds the LIVE credential: "A" (the account dir's real
# file, written by a running session) or "S" (clauth's store). "?" means the
# question could not be answered, and then nothing is touched.
cred_live_side() {
    local a="$1" s="$2" ea es ra rs ma ms
    ea="$(cred_expiry "$a")" && ra=0 || ra=$?
    es="$(cred_expiry "$s")" && rs=0 || rs=$?

    if (( ra == 2 || rs == 2 )); then
        # No jq. mtime is a coarser proxy for "which was written last", and both
        # branches copy the loser aside before overwriting, so a wrong guess here
        # is recoverable rather than destructive.
        ma="$(stat -c %Y "$a" 2>/dev/null)" || { printf '?\n'; return 0; }
        ms="$(stat -c %Y "$s" 2>/dev/null)" || { printf '?\n'; return 0; }
        if (( ma > ms )); then printf 'A\n'; else printf 'S\n'; fi
        return 0
    fi

    if   (( ra == 0 && rs != 0 )); then printf 'A\n'
    elif (( rs == 0 && ra != 0 )); then printf 'S\n'
    elif (( ra != 0 && rs != 0 )); then printf '?\n'
    # Both parse: the later expiry is the one a refresh produced. A tie resolves
    # to the store, which changes nothing and touches no file.
    elif (( ea > es ));            then printf 'A\n'
    else                                printf 'S\n'
    fi
}

# Copy a credential aside before it is overwritten; prints the backup's path.
cred_backup() {
    local f="$1" dest victims=()
    dest="$f.superseded-$(date +%Y%m%d-%H%M%S)-$$"
    cp -p "$f" "$dest" 2>/dev/null || return 1
    chmod 600 "$dest" 2>/dev/null || true
    shopt -s nullglob
    victims=("$f".superseded-*)
    shopt -u nullglob
    if (( ${#victims[@]} > CRED_BACKUPS_KEPT )); then
        # `stat | sort -rn`, not `ls -t` (SC2012) and not awk. awk is not on the
        # from-scratch PATH the state tables build, and CLAUDE.md records two
        # checks that silently produced nothing for exactly that reason. These
        # names are generated here, so a plain `read` split is safe.
        local _mtime path kept=0
        while read -r _mtime path; do
            kept=$(( kept + 1 ))
            if (( kept > CRED_BACKUPS_KEPT )); then rm -f "$path"; fi
        done < <(stat -c '%Y %n' "${victims[@]}" 2>/dev/null | sort -rn)
    fi
    printf '%s\n' "$dest"
}

# Install src's content as dst, atomically and within dst's own directory.
cred_install() {
    local src="$1" dst="$2" tmp
    tmp="${dst%/*}/.credentials.adopt.$$"
    cp "$src" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Replace whatever is at the account dir path with a fresh link to the store.
# Written as an if rather than `rm && ln` because the latter is a failing command
# when rm fails, which `set -e` turns into a silent exit.
cred_relink() {
    local link="$1" store="$2"
    rm -f "$link" || return 1
    ln -s "$store" "$link" || return 1
}

# Bring one account dir's credential back to the invariant: a symlink to the
# profile store, with the LIVE token in the store. Never destroys a credential
# without keeping a copy, and never restores a superseded one over a live one.
#
# Serialised per profile, because `claude()` runs this on every launch and two
# sessions starting together would otherwise race the adopt.
reconcile_credential() {
    local profile="$1" pdir="$2" account_dir="$3" rc=0 lock_fd=""

    if command -v flock >/dev/null 2>&1; then
        # `exec {fd}>file 2>/dev/null` has NO COMMAND, so BOTH redirections apply
        # to the shell permanently -- that spelling sent this script's own stderr
        # to /dev/null for the rest of the run, silencing every later warn() and
        # die(). Scoping the suppression to a group keeps the fd allocation while
        # leaving fd 2 alone.
        if { exec {lock_fd}>"$pdir/.reconcile.lock"; } 2>/dev/null; then
            flock -w 10 "$lock_fd" 2>/dev/null \
                || warn "$profile: no credential lock after 10s — proceeding unserialised"
        else
            lock_fd=""
        fi
    fi

    _reconcile_credential_locked "$profile" "$pdir" "$account_dir" || rc=$?
    # NOT `[[ -n "$lock_fd" ]] && exec ...`: as a bare statement that is a failing
    # command whenever the lock was not taken, and `set -e` then kills the script
    # silently -- which is exactly how this shipped broken the first time.
    if [[ -n "$lock_fd" ]]; then exec {lock_fd}>&-; fi
    return $rc
}

_reconcile_credential_locked() {
    local profile="$1" pdir="$2" account_dir="$3"
    local A="$account_dir/.credentials.json" S="$pdir/credentials.json"
    local side backup

    if [[ -L "$S" ]]; then
        warn "$profile: the clauth store credential is itself a symlink — an unexpected"
        warn "        shape, so both files are left exactly as they are."
        return 1
    fi
    if [[ ! -f "$S" ]]; then
        warn "$profile: no credential in the clauth store (${S/#$HOME/\~}) — refusing to"
        warn "        invent one. Run 'clauth login $profile'."
        return 1
    fi

    # The healthy state, and by far the common one.
    if [[ -L "$A" && "$(readlink "$A")" == "$S" ]]; then
        return 0
    fi

    if [[ -L "$A" ]]; then
        cred_relink "$A" "$S"
        warn "$profile: the credential link pointed somewhere other than this profile's"
        warn "        store — repointed. Check which account that session was billing."
        return 0
    fi

    if [[ ! -e "$A" ]]; then
        ln -s "$S" "$A"
        return 0
    fi

    # A is a REAL FILE -- the ordinary aftermath of a token refresh (see the
    # header), not corruption. Identical content means the refresh was already
    # adopted, or none has happened, so relinking loses nothing.
    if cmp -s "$A" "$S"; then
        cred_relink "$A" "$S"
        return 0
    fi

    side="$(cred_live_side "$A" "$S")"
    case "$side" in
        A)
            backup="$(cred_backup "$S")" || {
                warn "$profile: could not copy the store credential aside — nothing changed."
                return 1
            }
            if cred_install "$A" "$S"; then
                cred_relink "$A" "$S"
                warn "$profile: adopted the live session's rotated credential into the clauth"
                warn "        store (superseded store copy kept as ${backup##*/})."
            else
                warn "$profile: could not write the adopted credential into the store — the"
                warn "        account dir's own file is left in place, unharmed."
                return 1
            fi
            ;;
        S)
            backup="$(cred_backup "$A")" || {
                warn "$profile: could not copy the account dir credential aside — nothing changed."
                return 1
            }
            cred_relink "$A" "$S"
            warn "$profile: the account dir held a superseded credential — relinked to the"
            warn "        store (old copy kept as ${backup##*/})."
            ;;
        *)
            warn "$profile: the account dir and the clauth store hold DIFFERENT credentials"
            warn "        and neither could be read well enough to say which is live. Both are"
            warn "        left untouched. 'claude-doctor' explains; 'clauth login $profile' fixes."
            return 1
            ;;
    esac
    return 0
}

# Reconcile every account dir that already exists, building nothing. This is the
# path the timer takes: launch-time reconciliation alone leaves the store stale
# between a rotation and the next launch, and clauth quarantines an account whose
# stored token it can no longer poll with -- which is how `personal` reached
# auth_broken.
reconcile_all() {
    local d profile rc=0 seen=0
    [[ -d "$ROOT" ]] || { warn "no account dirs at ${ROOT/#$HOME/\~} — nothing to reconcile"; return 0; }
    shopt -s nullglob
    for d in "$ROOT"/*/; do
        profile="$(basename "$d")"
        [[ -d "$PROFILES_DIR/$profile" ]] || {
            warn "$profile: an account dir with no clauth profile — left alone"
            continue
        }
        seen=1
        reconcile_credential "$profile" "$PROFILES_DIR/$profile" "${d%/}" || rc=1
    done
    shopt -u nullglob
    (( seen )) || warn "no account dirs under ${ROOT/#$HOME/\~} matched a clauth profile"
    return $rc
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

    # 3. The credential: reconciled, never blindly relinked. See the header.
    reconcile_credential "$profile" "$pdir" "$account_dir" || true

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
    (( $# )) || { printf 'Usage: %s <profile> [<profile>...] | --all | --reconcile\n' "$0" >&2; exit 2; }

    if [[ "$1" == "--reconcile" ]]; then
        reconcile_all
        return $?
    fi

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
