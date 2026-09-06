# shellcheck shell=bash
# =============================================================================
# Claude Code account + MCP health
# =============================================================================
# `claude-doctor` answers one question: is this machine's Claude Code auth and
# MCP surface actually working, as opposed to merely configured?
#
# WHY THIS EXISTS. On 2026-09-06 an investigation found two servers that had
# been failing 100% of the time for over a month with nothing reporting it:
#
#   - plugin:desktop-commander had connected 0 times in 509 attempts since
#     2026-08-03. Its npx cache (~/.npm/_npx/4b4c857f6efdfb61) was a
#     half-finished npm reify with 414 orphaned staging dirs and no
#     .package-lock.json, so `npx -y ...@latest` died on ENOTEMPTY every launch.
#   - the claude.ai Linear connector's server id had gone dead upstream and
#     returned mcp_endpoint_not_found 1936 times, accelerating.
#
# Both were invisible because nothing read the per-server log store that Claude
# Code has been writing all along:
#
#     ~/.cache/claude-cli-nodejs/<slugified-cwd>/mcp-logs-<server>/<ISO>.jsonl
#
# 6,663 files of evidence, unread. This doctor reads it. It adds no logging of
# its own, because none was missing — only a reader was.
#
# THE OTHER HALF is the credential file. ~/.claude/.credentials.json holds BOTH
# the claude.ai login (claudeAiOauth) AND every plugin MCP server's OAuth token
# (mcpOAuth), at mode 0600, with NO lock — there is a ~/.claude/.claude.json.lock
# for the config file, and nothing for the credentials. Every refresh is a
# read-modify-write of the whole file, and this box routinely runs ~23 Claude
# processes at once.
#
# WHAT THE DAMAGE ACTUALLY LOOKS LIKE, corrected 2026-09-06 against the transcript
# record rather than against single reads of the file. Nine login-expiry incidents
# in the preceding eight days hit 1, 1, 5, 4, 3, 1, 1, 3 and 6 sessions: FIVE of
# the nine were simultaneous multi-session events. That is the signature of one bad
# value landing in one shared file, not of holders orphaning each other — at ~25
# processes and a ~7.5h access token, per-holder orphaning would cost dozens of
# logouts a day and this box averages about one. So the mechanism to fear is a
# THIRD PARTY writing a superseded credential (a profile switch), or a lost
# interleaved write, and the section that matters is the one grouping processes by
# which credential file they hold.
#
# A CORRECTION THAT MATTERS MORE THAN THE FIX IT PRODUCED. The mcpOAuth checks
# below used to report every empty accessToken as "an interleaved write". They are
# not: mcpOAuth is stored PER CONFIG DIR, and the entry Claude Code writes after
# OAuth discovery but before authorisation has an empty accessToken and no
# expiresAt, scope or refreshToken at all. Every isolated session starts there. The
# old rule reported three failures against a healthy `clauth start` session while
# the same three entries read "valid, refreshable" out of the global file in the
# same minute — and the earlier note in this file citing plugin:slack:slack "with
# refreshToken/expiresAt/scope keys absent entirely" was describing that state, not
# a race. The discriminator is the METADATA, not the token: an authorised entry
# that loses its accessToken keeps its expiresAt/scope, because a token cannot shed
# its own string and keep its bookkeeping by expiring. Only that shape is a fossil
# of a lost race, and only that shape earns a ✗.
#
# NEVER PRINTS A CREDENTIAL. Every check reports lengths, expiries, presence and
# truncated hashes — never a token, never a URL carrying one. This file's output
# lands in session transcripts; see the "Keeping secrets out of transcripts"
# section of CLAUDE.md for what happened the last time that was not true of a
# diagnostic.
#
# Uses the shared _doctor_* emitters from zsh/functions/system.sh, so this file
# must be sourced after it (zshrc does). Their counters are locals by dynamic
# scope, so every function calling _doctor_summary declares them — see
# _doctor_ok in system.sh for why that convention is not optional.
# =============================================================================

# Where the live credential lives. CLAUDE_CONFIG_DIR *does* isolate credentials
# in Claude Code — the file moves under that directory, and on macOS the Keychain
# entry is keyed to it too. That is the opposite of GH_CONFIG_DIR, which isolates
# hosts.yml and NOT the credential (the keyring is keyed by host); CLAUDE.md
# documents that trap at length under "GitHub Account Routing". Do not carry the
# gh intuition over to Claude: here, isolation works, and it is the mechanism
# `clauth start` uses to keep a session off the shared file.
_claude_cred_file() {
  print -r -- "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
}

# The GLOBAL credential, always — never this session's.
#
# NOT a synonym for _claude_cred_file, and the difference is the whole reason this
# function exists. Under `clauth start` (which hspawn has defaulted to since #107)
# _claude_cred_file resolves, through a symlink, to the PROFILE STORE. So every
# check written against it compares that store with itself: the stored-vs-live
# comparison below could not fail, and the orphan check found its own profile and
# stayed silent about a global credential that belonged to none. Measured
# 2026-09-06 — the same command in the same minute reported "✓ stored copy matches"
# from inside an isolated session and "⚠ matches NO registered clauth profile"
# from a shell with CLAUDE_CONFIG_DIR unset. Both statements were about different
# files; only the second was about the file clauth rewrites.
#
# This is the file a session with no CLAUDE_CONFIG_DIR uses, and the one
# `clauth <profile>` overwrites. Both facts are true regardless of where the
# shell running the doctor happens to be pointed.
_claude_global_cred_file() { print -r -- "$HOME/.claude/.credentials.json"; }

# The identity clauth's profiles are keyed on: a truncated hash of the login
# triple. Never the tokens themselves — see "NEVER PRINTS A CREDENTIAL" above.
# Empty output means "could not read it", which callers must not treat as a match.
_claude_cred_id() {
  [[ -f "$1" ]] || return 1
  jq -S -c '.claudeAiOauth | {accessToken,refreshToken,expiresAt}' "$1" 2>/dev/null \
    | sha256sum | cut -c1-16
}

# Which registered clauth profile owns the credential in $1. Prints the profile
# name, or nothing when no profile matches (which is a real, reportable state —
# see the orphan check — not an error).
_claude_cred_owner() {
  local want pdir
  want="$(_claude_cred_id "$1")" || return 1
  [[ -n "$want" ]] || return 1
  for pdir in "$HOME"/.clauth/profiles/*(N/); do
    [[ -f "$pdir/credentials.json" ]] || continue
    [[ "$(_claude_cred_id "$pdir/credentials.json")" == "$want" ]] || continue
    print -r -- "${pdir:t}"
    return 0
  done
  return 1
}

# Legacy pre-clauth config dirs (~/.claude-work, ~/.claude-personal, ...). Each
# that still holds a .credentials.json is an untracked copy of a login and an
# untracked participant in refresh-token rotation. zsh/zshrc.company records this
# scheme as removed on 2026-08-28; three of them were still being written on
# 2026-09-01, and nothing on the machine reported it.
_claude_legacy_cred_dirs() {
  local d
  for d in "$HOME"/.claude-*(N/); do
    [[ -f "$d/.credentials.json" ]] && print -r -- "$d"
  done
}

_claude_mcp_log_root() { print -r -- "$HOME/.cache/claude-cli-nodejs"; }

# Overridable ONLY so the concurrency section can be pinned by a state table.
# Section 4 groups live processes by the credential file each one holds; against
# the real /proc that answer depends on what happens to be running, so the rows
# that matter — "a process with no CLAUDE_CONFIG_DIR lands in the shared group",
# "an unreadable environment is NOT CHECKED rather than shared" — could not be
# written at all. A fixture tree makes them hermetic, which is the same reason
# every other suite here stubs clauth, herdr and systemctl.
_claude_proc_root() { print -r -- "${CLAUDE_DOCTOR_PROC_ROOT:-/proc}"; }

# Epoch milliseconds, to compare against the expiresAt fields, which are ms.
_claude_now_ms() { print -r -- $(( $(date +%s) * 1000 )); }

# "in 3h" / "42m ago". Input: milliseconds until (positive) or since (negative).
_claude_fmt_delta() {
  local ms=$1 abs unit n
  abs=${ms#-}
  if   (( abs < 90000 ));     then n=$(( abs / 1000 ));     unit=s
  elif (( abs < 5400000 ));   then n=$(( abs / 60000 ));    unit=m
  elif (( abs < 172800000 )); then n=$(( abs / 3600000 ));  unit=h
  else                             n=$(( abs / 86400000 )); unit=d
  fi
  if (( ms < 0 )); then print -r -- "${n}${unit} ago"; else print -r -- "in ${n}${unit}"; fi
}

# The success and failure markers Claude Code writes into every per-server log.
# Verified against both a healthy remote server and a failing stdio one on
# 2026-09-06; they are the only pair that distinguishes "connected" from
# "attempted". Counting files alone cannot: a server that has NEVER worked
# produces exactly as many log files as one that always does — which is why
# desktop-commander's 509 attempts and 0 successes read as activity.
_CLAUDE_LOG_OK='Successfully connected'
_CLAUDE_LOG_FAIL='Connection failed'

claude-doctor() {
  # Usage: claude-doctor [--days N] [--all]
  #
  # Read-only. Switches no profile, writes no config, refreshes no token.
  #
  #   --days N   MCP log window (default 7)
  #   --all      show every MCP server, not just those with something to report
  #
  # Uses the shared _doctor_* emitters; their counters are locals by dynamic
  # scope, so this function must declare them — see _doctor_ok in system.sh.
  local _DOCTOR_FAIL=0 _DOCTOR_WARN=0
  local days=7 show_all=0
  # zsh's `local` on a name already local in this scope is a DISPLAY command, so
  # every loop-body variable is declared once, here. CLAUDE.md records the run
  # where forgetting that printed `du=zvi-quantivly` into the middle of a report.
  local cred now_ms mode exp delta nproc_claude sub scopes chain
  local active stored_hash live_hash p pdir owner
  local root d srv ok_n fail_n key empty_tok no_refresh
  local i comm svc a b
  local gcred link_target session_owner global_owner has_meta
  local shared_n unknown_n cfgdir credpath ldir grp envblob n label procroot
  local -a date_prefixes files
  local -A group_n group_label

  while (( $# )); do
    case "$1" in
      --days) days="${2:-7}"; shift ;;
      --all)  show_all=1 ;;
      --help|-h) echo "Usage: claude-doctor [--days N] [--all]"; return 0 ;;
      *) echo "usage: claude-doctor [--days N] [--all]" >&2; return 2 ;;
    esac
    shift
  done
  [[ "$days" == <-> ]] && (( days > 0 )) || { echo "--days must be a positive integer" >&2; return 2; }

  echo "=== Claude Code Account & MCP Doctor ==="

  # ---- 0. Preflight -------------------------------------------------------
  # A machine with no Claude Code is not a broken machine. Reporting ✗ here is
  # the permanently-red checker CLAUDE.md warns about three times over; the
  # answer is "there is nothing here to check", at exit 0.
  if [[ ! -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ]]; then
    echo "  ○ skipped — no Claude Code config dir (${CLAUDE_CONFIG_DIR:-~/.claude})"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    # Everything below parses JSON. Saying so is right; printing a clean bill of
    # health from zero parsed files would not be.
    echo "  ✗ jq is not installed — the credential and MCP checks below cannot run"
    return 1
  fi

  cred="$(_claude_cred_file)"
  now_ms="$(_claude_now_ms)"

  # ---- 1. The credential file ---------------------------------------------
  echo
  echo "Credential file: ${cred/#$HOME/~}"
  if [[ ! -f "$cred" ]]; then
    _doctor_warn "no credential file — this shell's Claude Code is not logged in"
    echo "    Fix: run 'claude' and /login, or 'clauth login <profile>'."
  elif ! jq -e . "$cred" >/dev/null 2>&1; then
    # Unparseable is its own state and must never fall through to "no findings".
    # An unreadable map yielding nothing, read as nothing-wrong, is the exact
    # shape of the install.conf.yaml and gh-routing-table bugs in CLAUDE.md.
    _doctor_bad "credential file is present but NOT VALID JSON — every check below is UNKNOWN"
    echo "    A partial write does this. Fix: /login (or 'clauth login') to rewrite it."
    echo
    _doctor_summary ""
    return 1
  else
    # -L, because under `clauth start` this path is a SYMLINK into the profile
    # store and `stat -c %a` reports the mode of the LINK — 777 on every Linux
    # there is. That produced a permanent ✗ on the isolated path the repo made
    # default in #107: "mode 777 — expected 600" against a target that was 600.
    # A checker that cannot pass in a supported configuration is the
    # permanently-red checker CLAUDE.md warns about three times over.
    mode=$(stat -Lc %a "$cred" 2>/dev/null)
    if [[ -z "$mode" ]]; then
      _doctor_bad "cannot stat the credential file — a dangling symlink looks like this"
    elif [[ "$mode" == "600" ]]; then
      _doctor_ok "mode $mode"
    else
      _doctor_bad "mode $mode — expected 600; the login and every MCP token are in this file"
    fi

    # Whether THIS session is isolated, and onto what. Nothing else in a running
    # pane reveals it, and it decides which account is billed and whose logout a
    # `clauth <profile>` would cause.
    if [[ -L "$cred" ]]; then
      # zsh's :A, not `readlink -f`. Forkless, and — the reason it is not merely
      # tidier — it needs no binary: the state table builds a PATH from scratch
      # holding only what the doctor uses, readlink was not on it, and the
      # resolution silently returned nothing. An empty answer here degrades to
      # "unresolvable" and to an unrecognised credential group, which is a
      # diagnostic quietly getting less accurate on exactly the machines whose
      # PATH is unusual. Same modifier the live-config guard uses in zshrc.
      link_target="${cred:A}"
      if [[ "$link_target" == "$HOME/.clauth/profiles/"*/credentials.json ]]; then
        session_owner="${${link_target#$HOME/.clauth/profiles/}%/credentials.json}"
        _doctor_note "isolated: this session writes clauth profile '$session_owner', not the shared file"
      else
        _doctor_note "isolated: symlink -> ${link_target:-<unresolvable>}"
      fi
    elif [[ -n "$CLAUDE_CONFIG_DIR" ]]; then
      _doctor_note "isolated: a real file under \$CLAUDE_CONFIG_DIR (not a clauth profile store)"
    else
      _doctor_note "SHARED: no \$CLAUDE_CONFIG_DIR — this session is on ~/.claude/.credentials.json"
    fi

    if [[ "$(jq -r 'has("claudeAiOauth")' "$cred")" == "true" ]]; then
      exp=$(jq -r '.claudeAiOauth.expiresAt // empty' "$cred")
      sub=$(jq -r '.claudeAiOauth.subscriptionType // "unknown"' "$cred")
      scopes=$(jq -r '(.claudeAiOauth.scopes // []) | length' "$cred")
      if [[ -n "$exp" && "$exp" == <-> ]]; then
        delta=$(( exp - now_ms ))
        if (( delta < 0 )); then
          _doctor_warn "access token EXPIRED $(_claude_fmt_delta $delta) — a refresh is due; if it fails you get 'Login expired'"
        else
          _doctor_ok "login present (plan: $sub, $scopes scopes); access token expires $(_claude_fmt_delta $delta)"
        fi
      else
        _doctor_warn "login present but expiresAt is missing or non-numeric — a partial write looks like this"
      fi
      if [[ "$(jq -r '((.claudeAiOauth.refreshToken // "") | length) > 0' "$cred")" != "true" ]]; then
        _doctor_bad "login has NO refresh token — this session cannot renew and will hard-expire"
      fi
      # The connector coupling, stated once so the MCP section below reads
      # correctly: claude.ai connectors are fetched WITH this token (scope
      # user:mcp_servers), so a login that goes bad drops every connector at the
      # same moment. That is why "I get logged out" and "my MCP servers keep
      # disconnecting" are one report, not two.
      if [[ "$(jq -r '((.claudeAiOauth.scopes // []) | index("user:mcp_servers")) != null' "$cred")" == "true" ]]; then
        _doctor_note "scope user:mcp_servers present — claude.ai connectors ride on this login and drop with it"
      fi
    else
      _doctor_note "no claudeAiOauth block (an API key, profile or gateway credential may be in use)"
    fi
  fi

  # ---- 2. MCP OAuth entries: shape, not just freshness ---------------------
  # These live in the SAME unlocked file as the login. Checking only expiry
  # misses the failure this section exists for: an entry that is present and
  # unexpired but structurally incomplete, which reports as "Unauthorized" and
  # looks nothing like an expiry.
  #
  # THREE STATES, and conflating the first two is what this section got wrong
  # until 2026-09-06. mcpOAuth is stored PER CONFIG DIR, so an isolated session
  # starts with none — and the entry Claude Code writes after OAuth *discovery*
  # but before *authorisation* has an empty accessToken with clientId,
  # discoveryState, issuer, redirectUri, serverName and serverUrl, and NO
  # expiresAt, scope or refreshToken. That is a server nobody has authorised in
  # this config dir. It is not damage, and calling it damage made the doctor
  # report three failures against a healthy `clauth start` session while the same
  # three entries read "✓ valid, refreshable" out of the global file in the same
  # minute.
  #
  # The discriminator is the METADATA, not the token: an authorised entry that
  # loses its accessToken keeps its expiresAt/scope/refreshToken, because a token
  # cannot shed its own string and keep its bookkeeping by expiring. Empty token
  # WITH metadata is the fossil of a lost race and the only shape that earns a ✗.
  if [[ -f "$cred" ]] && jq -e 'has("mcpOAuth")' "$cred" >/dev/null 2>&1; then
    echo
    echo "MCP OAuth entries (in the same unlocked file as the login):"
    for key in ${(f)"$(jq -r '.mcpOAuth | keys[]' "$cred" 2>/dev/null)"}; do
      [[ -n "$key" ]] || continue
      srv=$(jq -r --arg k "$key" '.mcpOAuth[$k].serverName // $k' "$cred")
      empty_tok=$(jq -r --arg k "$key" '((.mcpOAuth[$k].accessToken // "") | length) == 0' "$cred")
      no_refresh=$(jq -r --arg k "$key" '((.mcpOAuth[$k].refreshToken // "") | length) == 0' "$cred")
      has_meta=$(jq -r --arg k "$key" \
        '(.mcpOAuth[$k] | has("expiresAt")) or (.mcpOAuth[$k] | has("scope"))
         or (((.mcpOAuth[$k].refreshToken // "") | length) > 0)' "$cred")
      exp=$(jq -r --arg k "$key" '.mcpOAuth[$k].expiresAt // empty' "$cred")

      if [[ "$empty_tok" == "true" && "$has_meta" != "true" ]]; then
        _doctor_note "$srv: never authorised in this config dir (discovery record only)"
        echo "    mcpOAuth is per CLAUDE_CONFIG_DIR, so an isolated session starts with none."
        echo "    Fix: authorise it from /mcp here, or drop the plugin in favour of the"
        echo "    claude.ai connector for the same service — connectors ride the login token"
        echo "    and need no per-config-dir OAuth at all."
      elif [[ "$empty_tok" == "true" ]]; then
        _doctor_bad "$srv: accessToken is EMPTY but its expiry/scope survive — an interleaved write"
        echo "    Fix: re-authenticate it from /mcp, then see the concurrency note below."
      elif [[ "$no_refresh" == "true" ]]; then
        _doctor_bad "$srv: no refreshToken — it can only die and need a manual re-auth"
      elif [[ -z "$exp" || "$exp" != <-> ]]; then
        _doctor_warn "$srv: token present but expiresAt is missing or non-numeric"
      else
        delta=$(( exp - now_ms ))
        if (( delta < 0 )); then
          _doctor_warn "$srv: token expired $(_claude_fmt_delta $delta) (it has a refresh token, so it should renew)"
        else
          _doctor_ok "$srv: valid $(_claude_fmt_delta $delta), refreshable"
        fi
      fi
    done
  fi

  # ---- 3. clauth: the third writer -----------------------------------------
  # Not installed is a normal machine, not a fault.
  #
  # EVERYTHING HERE IS ABOUT THE GLOBAL FILE, deliberately. clauth's profile
  # switch rewrites ~/.claude/.credentials.json; an isolated session does not read
  # it. Written against _claude_cred_file instead, both checks below silently
  # stopped working the moment #107 made isolation the default — see
  # _claude_global_cred_file for the measurement.
  echo
  gcred="$(_claude_global_cred_file)"
  if ! command -v clauth >/dev/null 2>&1; then
    echo "clauth: ○ not installed — single-account machine, nothing to check"
  else
    echo "clauth (owns the profiles that get written OVER ~/.claude/.credentials.json):"
    active=$(clauth which 2>/dev/null | tr -d '[:space:]')
    # `clauth which` answers the literal string "unknown" when the credential it
    # is looking at belongs to no profile — a sentinel, not a name. Taking it as
    # one produced "no stored credentials for 'unknown' to compare against",
    # which reads like a missing file rather than the orphan it is, and skipped
    # the status.json fallback that would have named the real active profile.
    [[ "$active" == "unknown" ]] && active=""
    [[ -z "$active" ]] && active=$(jq -r '.active_profile // empty' "$HOME/.clauth/status.json" 2>/dev/null)
    if [[ -z "$active" ]]; then
      _doctor_warn "could not determine the active profile — clauth answered nothing"
    else
      _doctor_note "active profile: $active"
    fi
    # Said once, because "live credential" below is otherwise ambiguous in an
    # isolated session, where this shell's own credential is a different file.
    _doctor_note "'live credential' below means ~/.claude/.credentials.json — the file a switch overwrites"

    # Who owns the GLOBAL credential. An ORPHANED one belongs to no registered
    # profile: clauth has no copy to restore, and the next `clauth <profile>`
    # overwrites it with no way back. Normal for a few minutes right after a
    # /login; a standing hazard after that. Observed 2026-09-06 12:25 and still
    # unhealed three daemon polls later.
    #
    # TWO INDEPENDENT CHECKS, and they must stay independent. Ownership is decided
    # by the very token triple the staleness comparison uses, so "no profile owns
    # the global credential" and "the active profile's stored copy differs from it"
    # are the SAME condition seen from two sides. Nesting the comparison inside the
    # owned branch — which this section briefly did — makes the DIFFERS message
    # unreachable in precisely the state it exists to report. They are siblings.
    if [[ ! -f "$gcred" ]]; then
      _doctor_note "no global credential file — nothing for a profile switch to overwrite"
    else
      # (a) THE HAZARD. `clauth <profile>` restores the profile's STORED copy over
      # the global file. Claude Code rotates refresh tokens — clauth's own log says
      # so: "adopted the live session's rotated login ... the running claude
      # refreshed first" — and clauth only notices on a ~90s poll. In that window
      # the stored copy is a SUPERSEDED refresh token, and restoring it can
      # invalidate every holder at once. This is the one check that predicts a mass
      # logout before it happens.
      pdir="$HOME/.clauth/profiles/$active"
      if [[ -n "$active" && -f "$pdir/credentials.json" ]]; then
        live_hash="$(_claude_cred_id "$gcred")"
        stored_hash="$(_claude_cred_id "$pdir/credentials.json")"
        if [[ -z "$live_hash" || -z "$stored_hash" ]]; then
          _doctor_warn "could not compare stored and live credentials — NOT CHECKED (an unreadable file is not agreement)"
        elif [[ "$live_hash" == "$stored_hash" ]]; then
          _doctor_ok "stored copy of '$active' matches the live credential — switching away and back is safe"
        else
          _doctor_warn "stored copy of '$active' DIFFERS from the live credential"
          echo "    Claude Code has rotated the login since clauth last captured it."
          echo "    Switching profile now would restore the older token and can log out every"
          echo "    holder of that profile. clauth adopts the rotation on its own ~90s poll —"
          echo "    re-run this check, or capture explicitly, before switching."
        fi
      elif [[ -n "$active" ]]; then
        _doctor_note "no stored credentials for '$active' to compare against"
      fi

      # (b) WHO OWNS IT. An orphaned credential belongs to no registered profile:
      # clauth has no copy to restore, and the next `clauth <profile>` overwrites it
      # with no way back. Normal for a few minutes right after a /login; a standing
      # hazard after that — observed 2026-09-06 12:25 and still unhealed three
      # daemon polls later.
      if ! global_owner="$(_claude_cred_owner "$gcred")"; then
        if [[ -z "$(_claude_cred_id "$gcred")" ]]; then
          # An unreadable file is not agreement. Naming it apart from "orphaned"
          # matters: the fixes differ, and only one of them is /login.
          _doctor_warn "could not read the live credential — NOT CHECKED"
        else
          _doctor_warn "the live credential matches NO registered clauth profile"
          echo "    clauth cannot identify it, so it has no copy to restore and the next"
          echo "    'clauth <profile>' will overwrite it with no way back. Normal right after"
          echo "    a /login — and note that a rotation clauth has not adopted yet looks"
          echo "    exactly like this, so read it together with the comparison above."
          echo "    Capture it into the profile it belongs to before switching."
        fi
      else
        _doctor_note "live credential belongs to profile '$global_owner'"
        if [[ -n "$active" && "$global_owner" != "$active" ]]; then
          _doctor_warn "the live credential belongs to '$global_owner', but the active profile is '$active'"
          echo "    Every other check can pass while sessions on the global file bill"
          echo "    '$global_owner' rather than the account you think is selected."
        fi
      fi
    fi

    # Legacy pre-clauth config dirs. Each is a login nobody rotates, tracks, or
    # would think to revoke.
    for ldir in ${(f)"$(_claude_legacy_cred_dirs)"}; do
      [[ -n "$ldir" ]] || continue
      _doctor_warn "legacy config dir still holds a credential: ${ldir/#$HOME/~}/.credentials.json"
      echo "    An untracked copy of a login, and an untracked participant in refresh"
      echo "    rotation. Remove it once nothing launches with CLAUDE_CONFIG_DIR=$ldir."
    done

    if [[ -n "$active" ]]; then
      # Armed auto-switch is a loaded landmine, not a fault: when quota fills it
      # rewrites the shared credential under every live session. Report it so it
      # is never a surprise; do not call a deliberate setting broken.
      #
      # And say that a switch is UNLOGGED. The first pass of this investigation
      # concluded auto-switch had never fired, because clauth.log contains no
      # switch event in 39 lines — then the active profile changed from
      # quantivly-3 to quantivly-2 mid-session with nothing written anywhere. A
      # quiet log is not a quiet mechanism, and a reader who does not know that
      # will draw the same wrong conclusion.
      if [[ -f "$HOME/.clauth/profiles.toml" ]]; then
        # FLATTENED FIRST, because `grep -oE` is line-based and clauth writes the
        # array over several lines. Measured 2026-09-06: against this machine's own
        # profiles.toml the un-flattened pattern matched nothing and exited 1, so
        # the whole note — the one that says a switch is unlogged — had never once
        # printed on the box it was written for. A check that cannot fire is
        # indistinguishable from a machine with auto-switch disarmed.
        chain=$(tr '\n' ' ' < "$HOME/.clauth/profiles.toml" 2>/dev/null \
                | grep -oE 'fallback_chain[^]]*\]' | head -1 | tr -s ' ')
        if [[ -n "$chain" ]]; then
          _doctor_note "auto-switch armed: $chain"
          _doctor_note "a switch rewrites the global credential under running sessions AND IS NOT LOGGED —"
          _doctor_note "  compare the active profile above against what you last saw; clauth.log will not say"
        fi
        # `preferred` is the setting that makes a switch AWAY from that profile
        # temporary: the daemon walks the active account back to it, unlogged. It
        # is a deliberate setting, so it is a note — but it is the reason a
        # hand-made switch to another account does not stay made.
        for pdir in "$HOME"/.clauth/profiles/*(N/); do
          [[ -f "$pdir/config.toml" ]] || continue
          grep -qE '^[[:space:]]*preferred[[:space:]]*=[[:space:]]*true' "$pdir/config.toml" 2>/dev/null \
            && _doctor_note "profile '${pdir:t}' is preferred — the daemon walks the active account back to it, unlogged"
        done
      fi
    fi
  fi

  # ---- 4. Concurrency on the shared file -----------------------------------
  # Claude Code does not lock .credentials.json. That is upstream's to fix, not
  # ours, so it is a ⚠ at worst and only when the count makes a race likely — an
  # unfixable condition reported as ✗ is how gh-doctor came to exit 1 on every
  # run (CLAUDE.md, "GitHub Account Routing").
  #
  # Counts by /proc comm, because Claude Code teammates exec the VERSIONED
  # binary and so appear as "2.1.259" rather than "claude" — the same blind spot
  # that made `herdr agent list` report 14 while 33 processes ran.
  echo
  nproc_claude=0; shared_n=0; unknown_n=0
  group_n=(); group_label=()
  procroot="$(_claude_proc_root)"
  for p in $procroot/[0-9]*(N); do
    [[ -r "$p/comm" ]] || continue
    comm="$(<"$p/comm")" 2>/dev/null
    case "$comm" in claude|2.[0-9]*) ;; *) continue ;; esac
    (( nproc_claude++ ))
    # Which credential file this process holds — the only thing that decides whose
    # logout a bad write causes. Reads ONE variable's value and reports a PATH,
    # never a value: a process environment is full of tokens and this output lands
    # in transcripts. See "Keeping secrets out of transcripts" in CLAUDE.md.
    envblob="$(tr '\0' '\n' < "$p/environ" 2>/dev/null)"
    if [[ -z "$envblob" ]]; then
      # Unreadable, or a process that exited between the two reads. "Cannot tell"
      # is not "shares the global file" — the same rule _dotfiles_umask_guard
      # follows in system.sh when /etc/group cannot answer.
      (( unknown_n++ )); continue
    fi
    cfgdir="$(print -r -- "$envblob" | grep -m1 '^CLAUDE_CONFIG_DIR=')"
    cfgdir="${cfgdir#CLAUDE_CONFIG_DIR=}"
    if [[ -z "$cfgdir" ]]; then
      credpath="$gcred"; grp="the SHARED global file"; (( shared_n++ ))
    else
      credpath="$cfgdir/.credentials.json"
      credpath="${credpath:A}"          # see the :A note in section 1
      if [[ "$credpath" == "$HOME/.clauth/profiles/"*/credentials.json ]]; then
        grp="clauth profile '${${credpath#$HOME/.clauth/profiles/}%/credentials.json}'"
      else
        grp="${credpath/#$HOME/~}"
      fi
    fi
    group_n[$credpath]=$(( ${group_n[$credpath]:-0} + 1 ))
    group_label[$credpath]="$grp"
  done

  # A FLAT PROCESS COUNT IS NOT ACTIONABLE, and it was also the wrong model.
  # Grouping by credential file is: the nine login-expiry incidents in the eight
  # days to 2026-09-06 hit 1, 1, 5, 4, 3, 1, 1, 3 and 6 sessions — five of the nine
  # were simultaneous multi-session events, which is the signature of ONE BAD WRITE
  # landing in ONE SHARED FILE, not of independent per-session refresh collisions.
  # (At ~25 processes and a ~7.5h access token, per-holder orphaning would cost
  # dozens of logouts a day; this box averages about one.) So the number that
  # predicts damage is the size of a group, and the number worth acting on is how
  # many processes are still on the file clauth rewrites.
  echo "Concurrency (one credential file = one group; a bad write takes the whole group):"
  if (( nproc_claude == 0 )); then
    _doctor_note "no Claude processes running"
  else
    for credpath in ${(ko)group_n}; do
      n=${group_n[$credpath]}
      label=${group_label[$credpath]}
      if [[ "$credpath" == "$gcred" ]]; then
        # A finding only where isolation is actually available. On a machine with
        # no clauth there is one credential and nothing to do about it, and a ⚠
        # nobody can act on is a ⚠ nobody reads.
        if [[ -d "$HOME/.clauth/profiles" ]] && command -v clauth >/dev/null 2>&1; then
          _doctor_warn "$n on $label — the one a profile switch overwrites"
          echo "    Give them their own CLAUDE_CONFIG_DIR (hspawn, or 'clauth start <profile>')."
        else
          _doctor_note "$n on $label"
        fi
      elif (( n > 6 )); then
        _doctor_warn "$n on $label — one lost write logs out all $n"
      else
        _doctor_ok "$n on $label"
      fi
    done
    (( unknown_n > 0 )) && _doctor_note "$unknown_n process(es) whose config dir could not be read — NOT CHECKED"
    _doctor_note "$nproc_claude Claude process(es) total; the credential file has no lock in any of them"
  fi

  # ---- 5. MCP servers, from the log store ----------------------------------
  # Effect, not intent: this reads what actually happened, never enabledPlugins.
  # A server can be enabled, configured, advertising a full tool list, and 404 on
  # every call — the claude.ai Linear connector did exactly that, 1936 times.
  echo
  root="$(_claude_mcp_log_root)"
  echo "MCP servers (last ${days}d, from ${root/#$HOME/~}):"
  if [[ ! -d "$root" ]]; then
    _doctor_note "no MCP log store yet — NOT CHECKED (absence of logs is not absence of faults)"
  else
    date_prefixes=()
    for (( i = 0; i < days; i++ )); do
      date_prefixes+=("$(date -d "-${i} day" +%Y-%m-%d 2>/dev/null)")
    done
    for srv in ${(f)"$(ls -d $root/*/mcp-logs-*(N) 2>/dev/null | sed 's#.*/mcp-logs-##' | sort -u)"}; do
      [[ -n "$srv" ]] || continue
      files=()
      for d in $date_prefixes; do files+=($root/*/mcp-logs-$srv/${d}T*.jsonl(N)); done
      (( ${#files} )) || continue
      ok_n=$(grep -l -- "$_CLAUDE_LOG_OK" $files 2>/dev/null | wc -l)
      fail_n=$(grep -l -- "$_CLAUDE_LOG_FAIL" $files 2>/dev/null | wc -l)
      if (( ok_n == 0 )); then
        _doctor_bad "$srv: 0 successful connections in ${#files} attempts — it has never worked in this window"
      elif (( fail_n * 4 > ${#files} )); then
        _doctor_warn "$srv: $fail_n/${#files} attempts failed ($ok_n succeeded)"
      elif (( show_all )); then
        _doctor_ok "$srv: $ok_n/${#files} connected"
      fi
    done
  fi

  # ---- 6. Duplicated services ----------------------------------------------
  # The same service reachable twice is two credentials, two failure modes and
  # two tool surfaces for one capability. Not a fault on its own — hence ⚠ — but
  # it is how a working Notion and a broken Notion come to be present at once.
  echo
  echo "Duplicated services (same capability on two paths):"
  if [[ -d "$root" ]]; then
    # Scoped to the SAME window as the server check above, by log FILES rather
    # than by directory existence. A log directory is never deleted, so keying
    # on it reports a duplicate for a connector removed months ago — which is a
    # warning the reader cannot act on, and a checker that emits those is one
    # people stop reading. Found the hour after this section was written: the
    # dead claude.ai Linear connector was disconnected and the row went on
    # firing off its leftover directory.
    for svc in Linear Notion Slack Figma Miro; do
      files=()
      for d in $date_prefixes; do files+=($root/*/mcp-logs-claude-ai-${svc}/${d}T*.jsonl(N)); done
      a=${#files}
      files=()
      for d in $date_prefixes; do
        files+=($root/*/mcp-logs-plugin-${svc}-${svc:l}/${d}T*.jsonl(N))
        files+=($root/*/mcp-logs-plugin-${svc:l}-${svc:l}/${d}T*.jsonl(N))
      done
      b=${#files}
      if (( a > 0 && b > 0 )); then
        _doctor_warn "$svc is reachable on BOTH the claude.ai connector and a plugin MCP server (both active in the last ${days}d)"
      fi
    done
  else
    _doctor_note "no log store — NOT CHECKED"
  fi

  echo
  _doctor_summary "Claude Code auth and MCP surface look healthy." \
    "Start with the ✗ items; 'claude-doctor --all' also lists the servers that are fine."
}
