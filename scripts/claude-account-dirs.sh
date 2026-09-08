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
# Idempotent and additive. It never writes to ~/.claude/ or ~/.claude.json.
#
# It DOES write under ~/.clauth/profiles/<p>/ -- corrected 2026-09-08, because the
# previous sentence here claimed otherwise and this file exists because one
# unverified header sentence was believed for weeks. Reconciling a rotation means
# writing the adopted credential into the profile store, and it also creates
# `.reconcile.lock`, `credentials.json.superseded-*` backups and a transient
# `.credentials.adopt.$$`. Nothing else under ~/.clauth is touched.
#
# Delete the whole account-dir tree and re-run: the only thing lost is each
# account's .claude.json, which costs one onboarding.
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

# The state of one credential file. Prints its expiresAt on stdout when, and
# only when, the file holds a credential that can actually authenticate.
#
#   0 = LIVE    -- an object, a NON-EMPTY accessToken, and a numeric expiresAt
#   1 = DEAD    -- parses, but cannot authenticate (no block, empty token, no
#                  expiry). A discovery stub is one shape of this; so is the
#                  VICTIM of an interleaved write.
#   2 = UNKNOWN -- does not parse, or there is no jq to ask with
#
# THE accessToken CHECK IS THE WHOLE POINT, and leaving it out was a
# credential-destroying bug (found in review, 2026-09-08). CLAUDE.md's own
# discriminator for an interleaved write is that the victim "keeps its expiresAt
# and scope" while losing its accessToken -- so ranking on expiry ALONE makes the
# victim of a lost race outrank the credential that still works, and adopting it
# copies an empty token over a good one. clauth then polls with nothing and
# quarantines the account, which is the exact outcome this file exists to prevent.
#
# DEAD and UNKNOWN must stay apart: "this credential cannot work" is a decision,
# "I could not read it" is a refusal, and collapsing them lets one unreadable side
# hand the other a confident win.
#
# NEVER prints a token: an integer is the only thing that leaves this function.
cred_state() {
    local f="$1"
    has_jq || return 2
    [[ -s "$f" ]] || return 2
    jq -e . "$f" >/dev/null 2>&1 || return 2
    # -e so the EXIT STATUS decides, never the emptiness of the output. A capture
    # of nothing is indistinguishable from a legitimate answer, which is a bug
    # this repo has already shipped once (CLAUDE.md, _claude_cred_id).
    jq -e -r '.claudeAiOauth
              | select(type == "object")
              | select((.accessToken // "") != "")
              | .expiresAt | select(type == "number")' "$f" 2>/dev/null || return 1
}

# The claudeAiOauth block alone, canonicalised, for deciding whether two files
# differ only in what surrounds the login (mcpOAuth entries, mostly).
cred_login_id() {
    local f="$1"
    has_jq || return 1
    jq -e -S -c '.claudeAiOauth | select(type == "object")' "$f" 2>/dev/null || return 1
}

# Bash, not zsh: `<->` is a zsh numeric glob and is a SYNTAX ERROR here.
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# Which of the two files holds the LIVE credential: "A" (the account dir's real
# file, written by a running session) or "S" (clauth's store). "?" means the
# question could not be answered, and then NOTHING is touched.
#
# Every branch that cannot be certain returns "?" rather than guessing. A wrong
# answer here overwrites a working login with a dead one.
cred_live_side() {
    local a="$1" s="$2" ea es ra rs ma ms la ls
    ea="$(cred_state "$a")" && ra=0 || ra=$?
    es="$(cred_state "$s")" && rs=0 || rs=$?

    # UNKNOWN on EITHER side is a refusal, not a win for the other. A file that
    # parses but carries trailing garbage -- the signature of a partial write --
    # must not hand its counterpart a confident victory.
    #
    # DEFENCE IN DEPTH, and deliberately unreachable on the current path: the
    # rotation-shape gate in _reconcile_credential_locked refuses an unparseable
    # file before this function is ever called, so no state-table row can enter
    # this branch and no mutant of it can die. Kept because this function is the
    # one that decides which credential survives, and it should not depend on a
    # caller's guard for that.
    if (( ra == 2 || rs == 2 )); then
        # With no jq at all, mtime is the only question we can ask. Both branches
        # copy the loser aside before overwriting, so a wrong guess is
        # recoverable; a file we could not parse WITH jq available is not the
        # same case and stays a refusal.
        if ! has_jq; then
            ma="$(stat -c %Y "$a" 2>/dev/null)" || { printf '?\n'; return 0; }
            ms="$(stat -c %Y "$s" 2>/dev/null)" || { printf '?\n'; return 0; }
            if (( ma > ms )); then printf 'A\n'; else printf 'S\n'; fi
            return 0
        fi
        printf '?\n'; return 0
    fi

    # One side can authenticate and the other cannot: no arithmetic needed.
    if   (( ra == 0 && rs != 0 )); then printf 'A\n'; return 0
    elif (( rs == 0 && ra != 0 )); then printf 'S\n'; return 0
    elif (( ra != 0 && rs != 0 )); then printf '?\n'; return 0
    fi

    # Both are live. A non-integer expiry would make the comparison below a bash
    # arithmetic ERROR, and an errored comparison must never read as a decision.
    if ! is_uint "$ea" || ! is_uint "$es"; then printf '?\n'; return 0; fi

    if   (( ea > es )); then printf 'A\n'; return 0
    elif (( es > ea )); then printf 'S\n'; return 0
    fi

    # Equal expiry, yet the files differ -- we only reach this function after
    # `cmp -s` said so. If the LOGIN blocks are identical, the difference is
    # everything around them, which in practice is mcpOAuth: the account dir has
    # gained MCP-server logins the store never had. Adopting A keeps them; the
    # old code relinked and silently discarded them, costing one browser OAuth
    # flow per server per profile, every time the timer ran.
    la="$(cred_login_id "$a")" || la=""
    ls="$(cred_login_id "$s")" || ls=""
    if [[ -n "$la" && "$la" == "$ls" ]]; then printf 'A\n'; return 0; fi

    # Same expiry, different logins: genuinely ambiguous.
    printf '?\n'
}

# THE ROTATION-SHAPE GATE. Everything a token refresh touches, and nothing else.
#
# WHY THIS EXISTS. Upstream clauth's `try_adopt_live_rotation` gates an adopt on
# FOUR things -- a refresh token present, both expiries present, live > stored
# STRICTLY, and identity PROVEN -- and refuses on any. It proves identity with an
# HTTP call under the live token, which a 2-minute unattended timer cannot afford
# (a request per profile per tick, and a live token in a subprocess).
#
# So we gate on shape instead: adopt only when the two files differ in the fields
# a rotation actually rewrites, and refuse everything else by name -- the same
# event clauth logs as "belongs to a DIFFERENT account. Not adopting". Without
# this, a `/login` as another account inside an isolated session was adopted into
# the wrong profile's store on the strength of a later expiry, which then bills
# the wrong account, poisons that profile's usage numbers (so the picker ranks on
# them), and would be installed machine-wide by `clauth <profile>`. Reproduced in
# review, 2026-09-08.
#
# BE HONEST ABOUT ITS STRENGTH: it is a filter, not a proof. Measured here, the
# residual separates `personal` from the work accounts and `quantivly-3` from the
# other two -- but `quantivly-1` and `quantivly-2` carry an identical residual
# (same rateLimitTier, subscriptionType and scope count), so a mix-up between
# exactly those two would pass. It is defence in depth, and the refusal path is
# what carries the safety.
cred_rotation_residual() {
    local f="$1"
    has_jq || return 1
    # refreshTokenExpiresAt rotates too -- leaving it in would make EVERY genuine
    # rotation look like a shape change, i.e. refuse everything.
    jq -e -S -c 'del(.claudeAiOauth.accessToken,
                     .claudeAiOauth.refreshToken,
                     .claudeAiOauth.expiresAt,
                     .claudeAiOauth.refreshTokenExpiresAt)
                 | del(.mcpOAuth)' "$f" 2>/dev/null || return 1
}

# Does this file carry a credential that can actually authenticate AND renew?
# Upstream refuses a live file with no refresh token outright; so do we. It also
# happens to catch the interleaved-write victim a second time.
cred_has_refresh() {
    local f="$1"
    has_jq || return 1
    jq -e '(.claudeAiOauth.refreshToken // "") != ""' "$f" >/dev/null 2>&1
}

# The merged credential: the WINNING side's login, plus the UNION of both sides'
# MCP-server logins, on stdout.
#
# The union is what stops this being a coin flip with a real cost. Measured
# 2026-09-08: quantivly-3's store held ZERO mcpOAuth entries while its account dir
# held one, and quantivly-2's store held one against three in its dir -- so
# whichever side happened to rotate last decided whether those logins survived,
# twice an hour per profile once the timer runs. Each one lost is a browser OAuth
# flow to get back, which is precisely the tax that made isolation expensive.
#
# Per server: an entry with a real accessToken always beats one without (CLAUDE.md's
# own discriminator -- a discovery stub must never overwrite an authorised entry),
# then the later expiresAt wins.
cred_merge() {  # $1 = winner file (its claudeAiOauth is kept), $2 = the other
    local win="$1" other="$2"
    has_jq || return 1
    jq -e -s '
      def live(e): ((e.accessToken // "") != "");
      def exp(e):  (e.expiresAt // 0);
      def better(a; b):
        if a == null then b
        elif b == null then a
        elif live(a) and (live(b) | not) then a
        elif live(b) and (live(a) | not) then b
        elif exp(a) >= exp(b) then a
        else b
        end;
        (.[0] // {}) as $w | (.[1] // {}) as $o
      | ($w.mcpOAuth // {}) as $wm | ($o.mcpOAuth // {}) as $om
      | (($wm | keys) + ($om | keys) | unique) as $ks
      | ($ks | map({key: ., value: better($wm[.]; $om[.])}) | from_entries) as $merged
      | $w
      | if ($ks | length) > 0 then .mcpOAuth = $merged else . end
    ' "$win" "$other" 2>/dev/null || return 1
}

# Run a command holding CLAUTH'S OWN state lock, not just ours.
#
# clauth serialises every credential write on ~/.clauth/.lock -- `runtime.rs:3095`
# carries a debug_assert demanding it, with the comment "Running this outside the
# state flock races the credential writes of a concurrent acquire or switch".
# Our own per-profile lock serialises us against ourselves and against nothing
# else, so an adopt could land on top of a rotation clauth had just performed and
# restore the pre-rotation token -- the original logout bug, re-created from the
# other end of the same pipe. Found in review, 2026-09-08.
#
# Advisory and best-effort: if the lock cannot be taken we say so and proceed,
# because refusing to reconcile leaves the worse state in place.
with_clauth_lock() {
    local lockf="$HOME/.clauth/.lock" fd="" rc=0
    if command -v flock >/dev/null 2>&1 && [[ -e "$lockf" ]]; then
        if { exec {fd}<"$lockf"; } 2>/dev/null; then
            flock -w 25 "$fd" 2>/dev/null \
                || warn "could not take clauth's state lock in 25s — proceeding without it"
        else
            fd=""
        fi
    fi
    "$@" || rc=$?
    if [[ -n "$fd" ]]; then exec {fd}<&-; fi
    return $rc
}

# Copy a credential aside before it is overwritten; prints the backup's path.
cred_backup() {
    local f="$1" dest victims=()
    dest="$f.superseded-$(date +%Y%m%d-%H%M%S)-$$"
    # NOT `cp -p`. Preserving the mtime stamps the SOURCE's time on the backup,
    # and the prune below ranks by mtime -- so a backup of an old file sorts
    # oldest and can be deleted by the very call that created it, which then
    # returns 0 and a path, and the caller destroys the original believing a copy
    # exists. This is the only safety net under every adopt/discard decision.
    cp "$f" "$dest" 2>/dev/null || return 1
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

# Record what the last reconcile DECIDED, so a reader does not have to guess.
#
# WHY. claude-doctor could see that a credential had diverged but not whether the
# reconciler would fix it, so it told the reader "the 2-minute timer normally
# handles it" -- advice that is right for a rotation and silently WRONG for a
# refusal, where the timer will hit the same wall every two minutes forever. That
# is a checker giving instructions that cannot work, which is the class this whole
# feature exists to remove.
#
# The reconciler is the only thing that knows, so it writes the answer down rather
# than the doctor re-deriving it -- a second implementation of the rule would drift
# from the first, and this file already records what that costs.
#
# One line: "<epoch> <verdict> <detail...>". Never a credential.
cred_write_verdict() {  # $1 = account dir, $2 = verdict, $3.. = detail
    local dir="$1" verdict="$2"; shift 2
    printf '%s %s %s\n' "$(date +%s)" "$verdict" "$*" > "$dir/.reconcile-status" 2>/dev/null || true
    chmod 600 "$dir/.reconcile-status" 2>/dev/null || true
}

# Is the account dir PROVABLY the same account as the profile store?
#
# clauth's own anchor (account_id.json, a bare JSON string it backfills on login
# and on every successful adoption) against the oauthAccount.accountUuid Claude
# Code writes into that dir's .claude.json.
#
# A PERMIT, NEVER A VETO, and the asymmetry is the whole safety argument. That
# .claude.json is seeded once by this script and only corrected when Claude Code
# rewrites it, so it is STALE on any dir that has not seen a login -- measured
# 2026-09-08, quantivly-1 and quantivly-2 both still advertised quantivly-3's
# account. Treating a mismatch as proof of a DIFFERENT account would therefore
# refuse two healthy profiles' ordinary rotations. Treating a match as proof of
# the SAME account cannot go wrong in that direction: a stale uuid names some
# other profile's account, so it fails to match this store's anchor and simply
# falls through to the shape gate.
#
# So: match -> identity proven, adopt even when the shape check would refuse.
#      anything else -> no opinion, the shape gate decides as before.
cred_same_account() {  # $1 = account dir, $2 = profile dir
    local dir="$1" pdir="$2" anchor uuid
    has_jq || return 1
    [[ -s "$pdir/account_id.json" && -s "$dir/.claude.json" ]] || return 1
    anchor="$(jq -e -r 'select(type == "string") | select(. != "")' \
              "$pdir/account_id.json" 2>/dev/null)" || return 1
    uuid="$(jq -e -r '.oauthAccount.accountUuid | select(type == "string") | select(. != "")' \
            "$dir/.claude.json" 2>/dev/null)" || return 1
    [[ "$anchor" == "$uuid" ]]
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
        cred_write_verdict "$account_dir" refused-store-symlink "the clauth store credential is itself a symlink"
        warn "$profile: the clauth store credential is itself a symlink — an unexpected"
        warn "        shape, so both files are left exactly as they are."
        return 1
    fi
    if [[ ! -f "$S" ]]; then
        cred_write_verdict "$account_dir" refused-no-store "clauth login $profile"
        warn "$profile: no credential in the clauth store (${S/#$HOME/\~}) — refusing to"
        warn "        invent one. Run 'clauth login $profile'."
        return 1
    fi

    # The healthy state, and by far the common one.
    if [[ -L "$A" && "$(readlink "$A")" == "$S" ]]; then
        cred_write_verdict "$account_dir" linked
        return 0
    fi

    if [[ -L "$A" ]]; then
        if cred_relink "$A" "$S"; then
            cred_write_verdict "$account_dir" linked "repointed from another profile's store"
            warn "$profile: the credential link pointed somewhere other than this profile's"
            warn "        store — repointed. Check which account that session was billing."
            return 0
        fi
        warn "$profile: the credential link points at another profile's store and could"
        warn "        NOT be repointed. Sessions here are billing the wrong account."
        return 1
    fi

    if [[ ! -e "$A" ]]; then
        # Never a bare `ln -s`: an unwritable account dir would otherwise leave
        # this returning 0 with no credential at all, and Claude Code would then
        # write a fresh, independent login there -- manufacturing exactly the
        # independent holder this design forbids.
        if ! cred_relink "$A" "$S"; then
            cred_write_verdict "$account_dir" error-no-link "could not create the credential link"
            warn "$profile: could not create the credential link in ${A%/*}"
            return 1
        fi
        cred_write_verdict "$account_dir" linked
        return 0
    fi

    # A is a REAL FILE -- the ordinary aftermath of a token refresh (see the
    # header), not corruption. Identical content means the refresh was already
    # adopted, or none has happened, so relinking loses nothing.
    if cmp -s "$A" "$S"; then
        cred_relink "$A" "$S" || {
            cred_write_verdict "$account_dir" error-no-relink "could not relink an identical credential"
            warn "$profile: could not relink an identical credential — left as a real file."
            return 1
        }
        cred_write_verdict "$account_dir" linked
        return 0
    fi

    # Everything from here is a REAL FILE that differs from the store.

    # 1. Is this even shaped like a rotation? Anything else -- a different
    #    account's login above all -- is refused by name, never adopted.
    local ra rs_
    ra="$(cred_rotation_residual "$A")" || ra=""
    rs_="$(cred_rotation_residual "$S")" || rs_=""
    if [[ -z "$ra" || -z "$rs_" ]]; then
        cred_write_verdict "$account_dir" refused-unreadable "clauth login $profile"
        warn "$profile: could not read one of the credentials well enough to tell a token"
        warn "        refresh from a different account. Both left untouched."
        return 1
    fi
    if [[ "$ra" != "$rs_" ]]; then
        # ...unless the two are PROVABLY the same account. A plain re-login of the
        # same account is not shaped like a rotation -- a fresh /login can fill in
        # fields an older stored credential left null, and one did here on
        # 2026-09-08: `personal` went rateLimitTier null -> default_claude_max_20x
        # and was refused, with the doctor then telling the reader to wait for a
        # timer that would refuse it again every two minutes. A /login happens
        # about eight times a month on this machine, so that is real friction for
        # no safety: identity is a STRONGER answer than shape, not a weaker one.
        if cred_same_account "$account_dir" "$pdir"; then
            warn "$profile: the account dir's credential is not shaped like a rotation, but it"
            warn "        belongs to the SAME account (clauth's anchor matches this dir's"
            warn "        oauthAccount) — a re-login. Proceeding."
        else
            cred_write_verdict "$account_dir" refused-not-rotation "clauth login $profile"
            warn "$profile: the account dir's credential is NOT a rotation of the stored one —"
            warn "        it differs outside the fields a refresh touches, which is what a login"
            warn "        as a DIFFERENT account looks like. Not adopting; both left untouched."
            warn "        If that was deliberate, capture it with 'clauth login $profile'."
            return 1
        fi
    fi

    # 2. Upstream's free anchor rule: no identity on record for this profile means
    #    nothing to reason about, so refuse rather than write.
    if [[ ! -s "$pdir/account_id.json" ]]; then
        cred_write_verdict "$account_dir" refused-no-anchor "clauth login $profile"
        warn "$profile: the clauth profile has no account_id.json anchor — refusing to"
        warn "        write its credential store. 'clauth login $profile' establishes it."
        return 1
    fi

    # 3. A credential with no refresh token cannot renew, so it is never the one to
    #    keep. Upstream rejects such a live file outright.
    local a_ok=0 s_ok=0
    cred_has_refresh "$A" && a_ok=1
    cred_has_refresh "$S" && s_ok=1

    side="$(cred_live_side "$A" "$S")"
    if   (( a_ok && ! s_ok )); then side=A
    elif (( s_ok && ! a_ok )); then side=S
    elif (( ! a_ok && ! s_ok )); then side="?"
    fi

    case "$side" in
        A|S)
            local winner other
            if [[ "$side" == A ]]; then winner="$A"; other="$S"; else winner="$S"; other="$A"; fi

            # ONE write path, and it discards nothing: the winner's login plus the
            # UNION of both sides' MCP logins. There is no losing side any more,
            # which is what makes a tie harmless rather than destructive.
            local merged="$pdir/.credentials.merged.$$"
            if ! cred_merge "$winner" "$other" > "$merged" 2>/dev/null || [[ ! -s "$merged" ]]; then
                rm -f "$merged"
                warn "$profile: could not merge the two credentials — nothing changed."
                return 1
            fi
            chmod 600 "$merged" 2>/dev/null || true

            if cmp -s "$merged" "$S"; then
                # The store already holds the answer; only the link needs fixing.
                rm -f "$merged"
                cred_write_verdict "$account_dir" linked
            else
                backup="$(cred_backup "$S")" || {
                    rm -f "$merged"
                    warn "$profile: could not copy the store credential aside — nothing changed."
                    return 1
                }
                if ! with_clauth_lock cred_install "$merged" "$S"; then
                    rm -f "$merged"
                    warn "$profile: could not write the store — the account dir's own file is"
                    warn "        left in place, unharmed."
                    return 1
                fi
                rm -f "$merged"
                if [[ "$side" == A ]]; then
                    cred_write_verdict "$account_dir" adopted
                    warn "$profile: adopted the live session's rotated credential into the clauth"
                    warn "        store (superseded store copy kept as ${backup##*/})."
                else
                    cred_write_verdict "$account_dir" kept-store
                    warn "$profile: kept the stored credential and merged in the account dir's"
                    warn "        MCP logins (previous store copy kept as ${backup##*/})."
                fi
            fi

            cred_relink "$A" "$S" || {
                warn "$profile: reconciled the store, but could not relink — it stays a real file."
                return 1
            }
            ;;
        *)
            cred_write_verdict "$account_dir" refused-undecidable "clauth login $profile"
            warn "$profile: the account dir and the clauth store hold DIFFERENT credentials"
            warn "        and neither could be shown to be the live one. Both are left"
            warn "        untouched. 'claude-doctor' explains; 'clauth login $profile' fixes."
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

    # DELIBERATELY 0 even when a profile was refused. This is a timer's ExecStart:
    # the refusals it can hit (a credential only a human can disambiguate, a
    # profile with no store yet) are states nobody can fix from here, and
    # returning non-zero for them means a oneshot that fails 720 times a day
    # forever -- an alarm that is always on, which is an alarm nobody reads. Every
    # refusal is printed, and `claude-doctor` is the surface that reports them as
    # findings. $rc is kept for callers that want it.
    (( rc == 0 )) || warn "some profiles were refused (above); claude-doctor explains"
    return 0
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
