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
# processes at once. The partial write that produces is not theoretical: the
# plugin:slack:slack entry was observed twice in a degraded state on 2026-09-06
# (once with a zero-length accessToken and refreshToken/expiresAt/scope keys
# absent entirely, once with expiresAt null) and had healed by the next read.
# Expiries do not grow keys back; that was an interleaved write.
#
# So the mcpOAuth checks below assert SHAPE, not just freshness: an entry whose
# accessToken is empty, or which has no refreshToken at all, is the fossil of a
# lost race and the reason a server reports "Unauthorized" while holding a token
# that has not expired.
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

_claude_mcp_log_root() { print -r -- "$HOME/.cache/claude-cli-nodejs"; }

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
  local -a date_prefixes files

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
    mode=$(stat -c %a "$cred" 2>/dev/null)
    if [[ "$mode" == "600" ]]; then
      _doctor_ok "mode $mode"
    else
      _doctor_bad "mode $mode — expected 600; the login and every MCP token are in this file"
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
  if [[ -f "$cred" ]] && jq -e 'has("mcpOAuth")' "$cred" >/dev/null 2>&1; then
    echo
    echo "MCP OAuth entries (in the same unlocked file as the login):"
    for key in ${(f)"$(jq -r '.mcpOAuth | keys[]' "$cred" 2>/dev/null)"}; do
      [[ -n "$key" ]] || continue
      srv=$(jq -r --arg k "$key" '.mcpOAuth[$k].serverName // $k' "$cred")
      empty_tok=$(jq -r --arg k "$key" '((.mcpOAuth[$k].accessToken // "") | length) == 0' "$cred")
      no_refresh=$(jq -r --arg k "$key" '((.mcpOAuth[$k].refreshToken // "") | length) == 0' "$cred")
      exp=$(jq -r --arg k "$key" '.mcpOAuth[$k].expiresAt // empty' "$cred")

      if [[ "$empty_tok" == "true" ]]; then
        _doctor_bad "$srv: accessToken is EMPTY — an interleaved write, not an expiry"
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
  echo
  if ! command -v clauth >/dev/null 2>&1; then
    echo "clauth: ○ not installed — single-account machine, nothing to check"
  else
    echo "clauth (owns the profiles that get written OVER the file above):"
    active=$(clauth which 2>/dev/null | tr -d '[:space:]')
    [[ -z "$active" ]] && active=$(jq -r '.active_profile // empty' "$HOME/.clauth/status.json" 2>/dev/null)
    if [[ -z "$active" ]]; then
      _doctor_warn "could not determine the active profile — clauth answered nothing"
    else
      _doctor_note "active profile: $active"
      # THE HAZARD. `clauth <profile>` restores the profile's STORED copy over
      # the live file. Claude Code rotates refresh tokens — clauth's own log says
      # so: "adopted the live session's rotated login ... the running claude
      # refreshed first" — and clauth only notices on a ~90s poll. In the window
      # between a rotation and that poll, the stored copy is a SUPERSEDED refresh
      # token, and restoring it can invalidate every live session at once. This
      # is the one check that predicts a mass logout before it happens.
      pdir="$HOME/.clauth/profiles/$active"
      if [[ -f "$pdir/credentials.json" && -f "$cred" ]]; then
        live_hash=$(jq -S -c '.claudeAiOauth | {accessToken,refreshToken,expiresAt}' "$cred" 2>/dev/null | sha256sum | cut -c1-16)
        stored_hash=$(jq -S -c '.claudeAiOauth | {accessToken,refreshToken,expiresAt}' "$pdir/credentials.json" 2>/dev/null | sha256sum | cut -c1-16)
        if [[ -z "$live_hash" || -z "$stored_hash" ]]; then
          _doctor_warn "could not compare live and stored credentials — NOT CHECKED (an unreadable file is not agreement)"
        elif [[ "$live_hash" == "$stored_hash" ]]; then
          _doctor_ok "stored copy of '$active' matches the live credential — switching away and back is safe"
        else
          _doctor_warn "stored copy of '$active' DIFFERS from the live credential"
          echo "    Claude Code has rotated the login since clauth last captured it."
          echo "    Switching profile now would restore the older token and can log out every"
          echo "    live session. clauth adopts the rotation on its own ~90s poll — re-run this"
          echo "    check, or capture explicitly, before switching."
        fi
      else
        _doctor_note "no stored credentials for '$active' to compare against"
      fi
      # An ORPHANED live credential: it belongs to none of the registered
      # profiles. `clauth which` answers `unknown`, which the block above
      # reports as two quiet notes — far too quiet for what it means. Observed
      # 2026-09-06 12:25 immediately after a /login recovery: the fresh
      # credential is one clauth has never captured, so (a) clauth cannot
      # restore it if you switch away, and (b) the next `clauth <profile>`
      # overwrites a credential of which no copy exists anywhere.
      if [[ -f "$cred" && -d "$HOME/.clauth/profiles" ]]; then
        live_hash=$(jq -S -c '.claudeAiOauth | {accessToken,refreshToken,expiresAt}' "$cred" 2>/dev/null | sha256sum | cut -c1-16)
        if [[ -n "$live_hash" ]]; then
          owner=""
          for pdir in "$HOME"/.clauth/profiles/*(N/); do
            [[ -f "$pdir/credentials.json" ]] || continue
            stored_hash=$(jq -S -c '.claudeAiOauth | {accessToken,refreshToken,expiresAt}' "$pdir/credentials.json" 2>/dev/null | sha256sum | cut -c1-16)
            [[ "$stored_hash" == "$live_hash" ]] && { owner="${pdir:t}"; break; }
          done
          if [[ -z "$owner" ]]; then
            _doctor_warn "the live credential matches NO registered clauth profile"
            echo "    clauth cannot identify it, so it has no copy to restore and the next"
            echo "    'clauth <profile>' will overwrite it with no way back. Normal right after"
            echo "    a /login. Capture it into the profile it belongs to before switching."
          elif [[ -n "$active" && "$owner" != "$active" ]]; then
            _doctor_warn "the live credential belongs to '$owner', but the active profile is '$active'"
          fi
        fi
      fi
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
        chain=$(grep -oE 'fallback_chain[^]]*\]' "$HOME/.clauth/profiles.toml" 2>/dev/null | head -1)
        if [[ -n "$chain" ]]; then
          _doctor_note "auto-switch armed: $chain"
          _doctor_note "a switch rewrites the shared credential under running sessions AND IS NOT LOGGED —"
          _doctor_note "  compare the active profile above against what you last saw; clauth.log will not say"
        fi
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
  nproc_claude=0
  for p in /proc/[0-9]*; do
    [[ -r "$p/comm" ]] || continue
    comm="$(<"$p/comm")" 2>/dev/null
    case "$comm" in claude|2.[0-9]*) (( nproc_claude++ )) ;; esac
  done
  echo "Concurrency:"
  if (( nproc_claude > 8 )); then
    _doctor_warn "$nproc_claude Claude processes running, and .credentials.json has no lock"
    echo "    Every refresh is a read-modify-write of one file. This is the mechanism"
    echo "    behind random logouts and 'Unauthorized' on tokens that have not expired."
    echo "    Reduce with hreap, or give workers their own CLAUDE_CONFIG_DIR"
    echo "    (hspawn --profile <p>, which launches via 'clauth start')."
  else
    _doctor_ok "$nproc_claude Claude processes — low contention on the shared credential file"
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
