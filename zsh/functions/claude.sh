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

# The GLOBAL settings.json, for exactly the reason _claude_global_cred_file exists.
# `clauth start` gives its runtime an OWN real settings.json (not a symlink), and a
# `claude-as` account dir may carry one too — so a check written against
# $CLAUDE_CONFIG_DIR asks about a copy, while the file clauth REWRITES is always
# this one. Section 7 is about that file and no other.
_claude_global_settings_file() { print -r -- "$HOME/.claude/settings.json"; }

# The machine-wide active clauth profile, from clauth's own config.
#
# NOT `clauth which`, which this asked until 2026-09-14 and which answers a
# DIFFERENT QUESTION. Its own help says so: "Print the profile owning the loaded
# .credentials.json ... CLAUDE_CONFIG_DIR-aware; prints `unknown` when nothing
# matches." Ownership, not selection — and measured against clauth 0.15.1 the
# match is on the refreshToken alone: with `active_profile = "B"` configured and
# the global credential equal to A's store, it answers A.
#
# That cost two separate wrong answers, and fixing only the first is what made
# the second visible. It answered from $CLAUDE_CONFIG_DIR, so an isolated
# session — the default for every session since #107 — was told ITS OWN profile
# (measured: `personal-1` machine-wide, `quantivly-0` from a session isolated
# onto quantivly-0). Clearing the environment fixed that and left the deeper one:
# with the environment cleared it answers the very quantity `_claude_cred_owner`
# computes from the same file, so "the live credential belongs to X, but the
# active profile is Y" could never fire — X and Y were one number read twice, and
# `stored copy of 'X' matches` compared a file with itself whenever the global
# credential is a symlink into a store, which on this box it is.
#
# `active_profile` in profiles.toml is the authority: it is part of clauth's
# config state, written by the switch primitive under the config lock. status.json
# is the DAEMON'S published feed of the same value — clauth's own TUI has a notion
# of it being stale ("wedging / pre-abort / just booted") — so it is the fallback
# and never the primary. Reading the config also means no fork, and no dependency
# on a CLI whose documented meaning is not the one the label promises.
#
# Bounded sed, not a TOML parser: the value is a top-level scalar, and the scan
# QUITS at the first table header so a `[profile.x]` section carrying the same key
# can never be read as the global one. Matching requires the quotes TOML demands
# of a string, so a comment after the value cannot be absorbed. The
# `fallback_chain` match further down carries the full reasoning for why an
# unbounded match here is a defect and not a style.
_claude_active_profile() {
  local v
  v=$(sed -n -e '/^[[:space:]]*\[/q' \
             -e 's/^[[:space:]]*active_profile[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
             -e "s/^[[:space:]]*active_profile[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" \
         "$HOME/.clauth/profiles.toml" 2>/dev/null)
  # First match only, and forklessly — `head` is one more binary in a function
  # that runs on a PATH built from scratch.
  v="${v%%$'\n'*}"
  [[ -n "$v" ]] || v=$(jq -r '.active_profile // empty' "$HOME/.clauth/status.json" 2>/dev/null)
  print -r -- "$v"
}

# The profiles clauth has QUARANTINED — `auth_broken` in ~/.clauth/profiles.toml,
# one name per line.
#
# THE AUTHORITY IS profiles.toml, NOT status.json. clauth writes the flag there
# under its own state flock (`set_auth_broken_persisted` -> `save_app_state`);
# status.json only republishes it as `profiles[].auth = "broken"`, and that feed
# is the daemon's, so a reader of it goes quiet exactly when the daemon is
# stopped — a state this machine has been in deliberately, and the one most worth
# reporting. Same precedence #145 settled for the active profile, same reason.
#
# Returns 1 when the question could not be ASKED, so empty output never carries
# two meanings: at status 0 it means "nothing quarantined", including the case
# where clauth has written no `auth_broken` key at all. The contract and the
# reasoning behind it are stated once, on the helper.
#
# The parse is in `_claude_toml_name_array` below, which this and the
# `fallback_chain` reader share: two keys in this file, one array-of-names shape,
# and CLAUDE.md's rule about the pair is that a fix right on one side of a report
# and wrong on the other is worse than one wrong on both, "since the correct half
# is the reason nobody re-reads the other". The other two readers of auth_broken
# stay separate copies for reasons that do not apply here — see the helper.
#
# THREE READERS OF THIS ONE KEY, and a change belongs in all of them:
# `_claude_profile_excluded` in zsh/zshrc.herdr (the picker's exclusion — this
# file must not depend on that one, see §3c) and `profile_is_quarantined` in
# scripts/claude-account-dirs.sh (bash, and a membership test rather than an
# enumeration, because the reconciler already knows the name it is asking about).
_claude_quarantined_profiles() {
  _claude_toml_name_array auth_broken
}

# The chain clauth walks when a quota fills — `fallback_chain` in
# ~/.clauth/profiles.toml, one name per line, same contract as the quarantine
# reader above: empty output at status 0 means no chain is configured, status 1
# means the question could not be ASKED.
#
# THIS ONE IS A DISPLAY, NOT A DECISION, and that is why it was fixed last and
# separately. The other readers of this array shape answer "is this profile
# quarantined" and a wrong answer picks the wrong account; this one prints what
# the chain holds, so its failure mode was a false alarm plus a leak of adjacent
# file content. Both halves were live until 2026-09-17: measured on
# `fallback_chain = [` followed by `profiles = [ "p1", "p2", ]`, the doctor
# printed `auto-switch armed: fallback_chain = [ profiles = [ "p1", "p2", ]` —
# the neighbouring assignment quoted verbatim into a report that lands in
# transcripts, in the function whose own header says NEVER PRINTS A CREDENTIAL,
# while claiming an auto-switch was armed on a box whose chain is deliberately
# empty.
#
# The caller prints the NAMES THIS RETURNS and never a span, which is the rule
# with no trade-off: a validated member is the value of the key being reported,
# where a span is whatever the range happened to swallow.
_claude_fallback_chain() {
  _claude_toml_name_array fallback_chain
}

# An array-of-quoted-names under a top-level key in ~/.clauth/profiles.toml, one
# name per line. $1 is the key, and must be a literal identifier: it is
# interpolated into a sed address, and both call sites in this file pass a
# constant. No guard for that, deliberately — no row could reach it, and
# CLAUDE.md's rule is that a branch whose mutant cannot die reads as coverage.
#
# Returns 1 when the question could not be ASKED, so empty output never carries
# two meanings. An ABSENT key is not that case: clauth serialises these lists
# with serde's `skip_serializing_if = "Vec::is_empty"`, so an empty list means
# the key is simply not written — verified against the live file, 13 lines with
# no `auth_broken` among them. Empty output at status 0 is "the list is empty".
#
# ONE COPY IN THIS FILE, TWO KEYS. The other two readers of `auth_broken` are
# deliberate duplicates — `zsh/zshrc.herdr` must be sourceable ALONE by a modular
# adopter who has neither this file nor the reconciler, and
# scripts/claude-account-dirs.sh is bash — but no such constraint separates
# `auth_broken` from `fallback_chain`, which sit forty lines apart in one file.
# A verbatim copy differing by one word is the drift this repo keeps paying for.
#
# THE SPAN IS VALIDATED, NOT MERELY TERMINATED, and the difference is a row that
# failed in each of the two keys in turn. sed's range ends at the first line
# carrying `]`, which bounds it to a line range and NOT to one assignment: the
# span can swallow every quoted string below it whenever the closing bracket
# never arrives — turning a malformed file into confident, specific, wrong
# findings. For `auth_broken` that invents quarantined accounts; for
# `fallback_chain` it printed a neighbouring line into the report.
#
# Checking for a `]` is not enough, which is what both rows caught: a
# `<key> = [` with no members, followed by `profiles = [ "p1", ]`, has a `]` —
# the OTHER array's. So the INTERIOR is checked instead: after the first `[` and
# before the first `]`, an array of names is nothing but quoted strings, commas
# and whitespace. Split on `"` and the odd fields are exactly what sits between
# the names; anything else there means the range ran into another assignment. A
# missing bracket of either kind fails the same test, so truncation needs no
# separate arm.
#
# Splitting on `"` and taking the EVEN fields reads clauth's multi-line array and
# a single-line one identically. `s/.*"\([^"]*\)".*/\1/p` does not: it is greedy,
# so `auth_broken = ["a", "b"]` yields only `b`.
_claude_toml_name_array() {
  local key="${1:-}" toml="$HOME/.clauth/profiles.toml" span body dq='"' i
  local -a parts
  # DEFENCE IN DEPTH, and unkillable through either consumer: sed's own status
  # below already returns 1 for an unreadable file (measured with `chmod 000` —
  # identical rc and output with this line removed). It is kept because the
  # contract is "no file, no answer" and a future reader of `$span` should not
  # have to know that sed happens to cover it, and it is LABELLED because
  # CLAUDE.md's rule is that a branch whose mutant cannot die reads as coverage.
  [[ -r "$toml" ]] || return 1
  # THE STATUS IS THE POINT, not the output. `sed` is an external tool and an
  # external tool is a way for a check to go quiet — CLAUDE.md records that for
  # `readlink -f` and `awk` in these same files, and the bash twin in the
  # reconciler avoids the class entirely with a `while read` loop. Without this
  # test a sed that never ran (absent from PATH, exec failure) yields an EMPTY
  # span, which the next line reads as "the list is empty": the doctor then
  # prints a confident ✓ for a question it could not ask — over a standing
  # quarantine, or over an ARMED fallback chain, which is the state that rewrites
  # the global credential under every running session. sed still exits 0 when it
  # matches nothing, so the ordinary empty-list case is unaffected.
  span="$(sed -n "/^[[:space:]]*${key}[[:space:]]*=/,/]/{p; /]/q}" "$toml" 2>/dev/null)" || return 1
  # No assignment found — the ordinary "the list is empty", not a failure to read.
  # DO NOT restate this as "clauth omits the key when the list is empty": that is
  # true of `auth_broken` (serde `skip_serializing_if = "Vec::is_empty"`, and the
  # live file carries no such key) and FALSE of `fallback_chain`, which has no
  # such attribute and sits in the live file as `fallback_chain = []`. Measured
  # 2026-09-17: one `fallback_chain` assignment present, zero `auth_broken`. The
  # first version of this comment carried the claim for both keys, having been
  # copied from the quarantine reader — the drift the sharing was meant to stop,
  # arriving in the comment layer instead. So this path is reached by an absent
  # key whoever omitted it, and the EMPTY-LIST case reaches the checks below.
  [[ -n "$span" ]] || return 0
  # Also unkillable, for a reason worth stating rather than discovering: the span
  # always begins with the unquoted key name, so when there is no `[` to strip
  # the key itself lands in odd field 1, which is never clean. Four fixtures
  # (`= "a]b"`, `= ]`, a multi-line bracketless form, `= "a" , ]`) give identical
  # rc and output with this line removed. Same label as the `-r` test above, same
  # reason: it states the contract, and it is not coverage.
  [[ "$span" == *'['* ]] || return 1
  body="${span#*\[}"
  [[ "$body" == *']'* ]] || return 1
  body="${body%%\]*}"
  parts=( "${(@ps:$dq:)body}" )
  # Odd fields sit BETWEEN the quoted names; in an array they hold nothing but
  # commas and whitespace. `${x//[...]/}` rather than an extended-glob pattern,
  # because claude-doctor is sourced into whatever shell asks for it and
  # EXTENDED_GLOB is not guaranteed there.
  for (( i = 1; i <= ${#parts}; i += 2 )); do
    # `\r` is in the class because the bash twin's `[[:space:],]` includes it and
    # the two are presented as one rule in two languages. Without it a CRLF
    # profiles.toml is `YES` to the reconciler and NOT CHECKED to the doctor —
    # measured, and the exact divergence the cross-check row exists to prevent.
    # Reachability is low (clauth writes LF via toml::to_string_pretty on Linux),
    # which is why this is one character rather than a new state.
    [[ -z "${parts[i]//[$' \t\r\n,']/}" ]] || return 1
  done
  # A MEMBER MUST LOOK LIKE A NAME, and checking the odd fields does NOT
  # establish that — it validates what sits BETWEEN the names and never the
  # names. Found by an independent review of #160, measured against the first
  # version of this very function: a span truncated MID-MEMBER (`<key> = ["`)
  # leaves odd field 1 empty, which passes, and flips quote parity, so the
  # neighbouring assignment lands in an EVEN field and was emitted as a member.
  # `fallback_chain = ["` over `profiles = ["` printed
  # `auto-switch armed: the chain walks profiles = [` — both halves of the
  # defect this function exists to remove, reproduced against the fix, and on
  # `auth_broken` the same span reached a REMEDY as
  # `Do NOT run 'clauth login profiles = ['`.
  #
  # The class is clauth's own, from `validate_profile_name`'s refusal on the
  # installed 0.15.1 binary: "letters, digits and - _ . @ + only, and can't
  # start with '.'". Anything outside it is the range having run into another
  # assignment. The leading-dot half is deliberately NOT enforced: it is
  # clauth's rule for CREATING a profile, not a lexical fact about the array, a
  # `.name` member is no evidence of a runaway, and the class alone closes the
  # leak — a second rule with no observed producer would be a branch whose
  # mutant cannot die.
  #
  # ITS OWN PASS, BEFORE THE EMIT LOOP, because the emit loop prints as it goes:
  # folded in there, a bad member late in the list would be caught only after
  # the good ones had already been printed, so a caller would get a partial
  # emission AND a `return 1`.
  for (( i = 2; i <= ${#parts}; i += 2 )); do
    [[ -z "${parts[i]//[A-Za-z0-9._@+-]/}" ]] || return 1
  done
  for (( i = 2; i <= ${#parts}; i += 2 )); do
    # An EMPTY member is skipped rather than refused: `["", "p1"]` is legal TOML
    # and an empty name is no evidence of a runaway, where the class check above
    # is. Both consumers split with an unquoted `${(f)...}`, which drops an empty
    # field anyway, so this guard is only observable at the helper's own
    # contract — which is why the suite calls it directly rather than always
    # through a consumer that papers over it.
    [[ -n "${parts[i]}" ]] && print -r -- "${parts[i]}"
  done
  return 0
}

# Whether a clauth profile store's credential can still authenticate. One word,
# plus the expiry in ms for the two states that have one:
#
#   usable <expiresAt>    a non-empty accessToken and a numeric expiresAt ahead
#   expired <expiresAt>   the same, with that expiry already past
#   dead                  parses, but cannot authenticate — no claudeAiOauth, an
#                         EMPTY accessToken, or no numeric expiry. The OAuth
#                         discovery stub and the victim of an interleaved write
#                         are both this shape.
#   unreadable            no file, or it does not parse
#
# THE EMPTY-accessToken TEST IS THE WHOLE POINT, and it is the same discriminator
# scripts/claude-account-dirs.sh's `cred_state` uses: a freshness signal is not an
# aliveness signal. CLAUDE.md records the credential-destroying bug that came of
# ranking on expiry while meaning alive — the victim of a lost race KEEPS its
# expiresAt and loses its accessToken, so it outranked a credential that worked.
#
# NEVER PRINTS A TOKEN: a word and an integer are the only things that leave here.
_claude_store_auth_state() {
  local f="${1:-}" exp
  [[ -f "$f" ]] || { print -r -- unreadable; return 0 }
  jq -e . "$f" >/dev/null 2>&1 || { print -r -- unreadable; return 0 }
  # jq's EXIT STATUS decides, never the emptiness of its output — the
  # hash-of-nothing class this file already carries two notes about. `-e` plus
  # the selects means a missing block produces no output AND a non-zero status.
  exp="$(jq -e -r '.claudeAiOauth
                   | select(type == "object")
                   | select((.accessToken // "") != "")
                   | .expiresAt | select(type == "number")' "$f" 2>/dev/null)" \
    || { print -r -- dead; return 0 }
  if (( exp > $(_claude_now_ms) )); then
    print -r -- "usable $exp"
  else
    print -r -- "expired $exp"
  fi
}

# The identity clauth's profiles are keyed on: a truncated hash of the login
# triple. Never the tokens themselves — see "NEVER PRINTS A CREDENTIAL" above.
# Empty output means "could not read it", which callers must not treat as a match.
_claude_cred_id() {
  local body
  [[ -f "$1" ]] || return 1
  # jq's EXIT STATUS, not just its output. Piping jq straight into sha256sum
  # hashes jq's EMPTY output when it fails, and sha256sum of nothing is a
  # constant (e3b0c44298fc1c14) — so every unreadable file got the same id and
  # therefore "matched" every other unreadable file. That printed
  # "✓ stored copy matches — switching away and back is safe" across two corrupt
  # credentials and made all three of this file's NOT-CHECKED branches
  # unreachable. A file that parses but carries no claudeAiOauth was the same bug
  # one level up: {accessToken:null,...} is also a constant.
  #
  # -e makes jq exit non-zero when it produced no output, and the select() makes
  # a missing claudeAiOauth produce none.
  body="$(jq -e -S -c '.claudeAiOauth | select(. != null) | {accessToken,refreshToken,expiresAt}' "$1" 2>/dev/null)" || return 1
  [[ -n "$body" ]] || return 1
  print -r -- "$body" | sha256sum | cut -c1-16
}

# Which registered clauth profile owns the credential whose ID is $1. Prints the
# profile name, or nothing when no profile matches (a real, reportable state —
# see the orphan check — not an error).
#
# Takes the ID rather than a path on purpose: the caller already has it, and
# deriving it here meant the global credential's id was computed up to three
# times per run — once for the staleness comparison, once here, and once more to
# tell "no match" apart from "unreadable" — roughly 21 forks with four profiles
# registered.
_claude_cred_owner() {
  local want="$1" pdir
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

# Seconds since a file was last written, or nothing. Loads its own modules: a
# helper that depends on a module its CALLER happened to load returns nothing
# when called any other way — and "no age" reads as "fresh", which is how a stale
# reading comes to be believed.
_claude_file_age_s() {
  local mtime
  [[ -r "$1" ]] || return 1
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  zmodload zsh/datetime 2>/dev/null || return 1
  mtime=$(zstat +mtime -- "$1" 2>/dev/null) || return 1
  [[ "$mtime" == <-> ]] || return 1
  print -r -- $(( EPOCHSECONDS - mtime ))
}

# Can this name be a clauth profile at all?
#
# Returns 0 when it CANNOT. One definition, used by both enumerations below —
# the account dirs and the profile store dirs — because both had the same
# fall-through: every name they could see was assumed to be a would-be profile,
# and the remedy text sent the reader to `clauth login <name>`.
#
# THE TEST IS A LEADING DOT AND NOTHING WIDER, deliberately. `clauth login` can
# never create such a name, and a leading dot is what this machine's own tooling
# produces for archives and internal state (a profile rename left
# `.personal.stray-20260910-112747`). A first cut used `[[ "$1" != [A-Za-z0-9]* ]]`
# and that also rejects `_weird` and `-dash`, which are unusual rather than
# impossible — and a checker that misfiles a real account dir as "not mine"
# reintroduces the blind spot from the other side, which is the whole reason #132
# widened these globs.
#
# NOT a glob-narrowing fix. `setopt GLOB_DOTS` is set repo-wide (`zshrc`), so
# `*(N/)` in this codebase has NEVER excluded dotfiles — re-excluding them here
# would make a dot-prefixed directory holding a REAL credential invisible again,
# which is exactly the class #132 exists to close. The enumeration stays wide and
# the classification gets wider.
_claude_name_cannot_be_profile() { [[ "${1:-}" == .* ]] }

# WHICH OF THE FOUR SHAPES a credential path is, because "is there a credential
# here" cannot answer what to SAY about one — and answering it with
# `[[ -e || -L ]]` produced advice that destroyed the thing it was reporting.
#
# The designed shape of a per-account credential is a SYMLINK into
# `~/.clauth/profiles/<p>/credentials.json` — CLAUDE.md states the invariant as
# "the credential is a symlink, never a copy", and every account dir on a healthy
# machine is that. So the presence test is true for the managed case, and calling
# that "an unmanaged copy of a login" and offering `shred` as the remedy is worse
# than saying nothing: `shred` FOLLOWS the link and overwrites the TARGET in
# place, which is the live credential every session on that profile is reading.
# Measured: the target file survives and its contents do not. That logs out the
# whole account — the outcome the account-dir design exists to prevent.
#
# A dangling link is its own answer too. `-L` is true for one, so folding it in
# reported "it holds a credential" about a link that holds nothing, and offered a
# remedy for a file that is not there. A half-finished rename is exactly the
# state these sections are supposed to describe, not to misname.
#
# ONE helper for both the account-dir and the profile-store loop. The store-side
# comment below already records why: a fix that is right on one side of a report
# and wrong on the other is worse than one wrong on both, because the correct
# half is the reason nobody re-reads the other.
#
# Echoes one word, and a second field where there is a target worth naming:
#   absent              nothing there, and no link either
#   file                a real file — the ONLY shape that is an unmanaged copy
#   managed <profile>   a symlink resolving into that profile's store
#   foreign <path>      a symlink resolving somewhere that is not a profile store
#   dangling <path>     a symlink whose target does not exist
_claude_cred_shape() {
  local f="${1:-}" t=""
  if [[ -L "$f" ]]; then
    # `zstat +link`, not `${f:A}`: :A resolves only as far as the path EXISTS, so
    # on a dangling link it hands back the link's own path and the report names
    # the link instead of the target. Same reasoning, same module, as the
    # symlinked-account-dir branch below — and a zsh module rather than
    # `readlink`, which CLAUDE.md records silently producing nothing under the
    # state table's from-scratch PATH, in this very file.
    zmodload -F zsh/stat b:zstat 2>/dev/null
    t="$(zstat +link -- "$f" 2>/dev/null)" || t=""
    [[ -n "$t" ]] || t="${f:A}"
    # A relative target is relative to the link's own directory.
    [[ "$t" == /* ]] || t="${f:h}/$t"
    if [[ ! -e "$t" ]]; then
      print -r -- "dangling $t"
      return 0
    fi
    if [[ "${t:h:h}" == "$HOME/.clauth/profiles" && -d "${t:h}" ]]; then
      print -r -- "managed ${t:h:t}"
      return 0
    fi
    print -r -- "foreign $t"
    return 0
  fi
  [[ -e "$f" ]] && { print -r -- file; return 0 }
  print -r -- absent
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
  local cred now_ms mode exp delta nproc_claude sub scopes crc cspan
  local active stored_hash live_hash p pdir spath
  local root d srv ok_n fail_n unauth_n invalid_n key empty_tok no_refresh
  local i comm svc a b
  local gcred gcred_id link_target session_owner global_owner has_meta gsettings val
  local unknown_n cfgdir credpath ldir grp envblob n label procroot
  local uc_max uc_age uc_oldest uc_oldest_p uc_seen uc_stale uc_missing ucf
  local pname
  # The quarantine block in §3. Declared HERE with everything else: zsh has no
  # block scope and `local` on a name already local in this scope is a DISPLAY
  # command, which CLAUDE.md records printing `pdir=/home/...` into the middle of
  # a report.
  local qspan qrc qstate qexp qstore qreal
  local -a date_prefixes files stray_profiles unprofiled_dirs unmanaged_stores
  # Declared here for the reason this PR exists: a ~950-line function with no
  # block scope shares one namespace, and an undeclared assignment inside it
  # leaks a global — which is the defect the `local pdir pname` fix above closed.
  local -a _cshape shared_stores dangling_stores
  local -a quarantined chain_walk
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
  if [[ -L "$cred" && ! -e "$cred" ]]; then
    # BEFORE the -f test, which FOLLOWS symlinks: a dangling link is "not a
    # regular file", so this state used to print "not logged in — run /login"
    # and send the reader to re-authenticate instead of at the broken link. A
    # deleted clauth profile leaving a live `clauth start` runtime dir behind is
    # a real way to reach it. (The stat branch below cannot report this: it runs
    # only once -f has already passed.)
    _doctor_bad "credential symlink is DANGLING -> $(readlink "$cred")"
    echo "    Its target is gone — a deleted clauth profile does this. Fix: point"
    echo "    CLAUDE_CONFIG_DIR somewhere real, or re-create the profile."
  elif [[ ! -f "$cred" ]]; then
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
      _doctor_bad "cannot stat the credential file"
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
      # READ THE TYPE FIRST, once, before anything indexes the entry. An
      # mcpOAuth value that is a string or null is a plausible product of the
      # very interleaved write this section hunts, and every `.mcpOAuth[$k].x`
      # below then fails with "Cannot index string with string" — four parser
      # errors printed into the middle of the report, after which the empty
      # captures read as a benign shape and the entry was excused. CLAUDE.md
      # records the same lesson from herdr-claude-wire.sh: `//` substitutes for
      # null, never for a type error.
      if [[ "$(jq -r --arg k "$key" '.mcpOAuth[$k] | type' "$cred" 2>/dev/null)" != "object" ]]; then
        _doctor_warn "$key: entry is not an object — NOT CHECKED (a lost race can produce this)"
        continue
      fi
      srv=$(jq -r --arg k "$key" '.mcpOAuth[$k].serverName // $k' "$cred" 2>/dev/null)
      [[ -n "$srv" ]] || srv="$key"
      empty_tok=$(jq -r --arg k "$key" '((.mcpOAuth[$k].accessToken // "") | length) == 0' "$cred" 2>/dev/null)
      no_refresh=$(jq -r --arg k "$key" '((.mcpOAuth[$k].refreshToken // "") | length) == 0' "$cred" 2>/dev/null)
      has_meta=$(jq -r --arg k "$key" \
        '(.mcpOAuth[$k] | has("expiresAt")) or (.mcpOAuth[$k] | has("scope"))
         or (((.mcpOAuth[$k].refreshToken // "") | length) > 0)' "$cred" 2>/dev/null)
      exp=$(jq -r --arg k "$key" '.mcpOAuth[$k].expiresAt // empty' "$cred" 2>/dev/null)

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
  # :A here too. Every per-process path below is normalised, and leaving this one
  # raw put two processes on the SAME physical credential file into two groups —
  # "⚠ 1 on the SHARED global file" and "✓ 1 on clauth profile p1" — when
  # ~/.claude/.credentials.json is itself a symlink into a profile store. The ✓
  # was on a process a write to that store would log out, under a heading that
  # promises one file is one group.
  gcred="$(_claude_global_cred_file)"; gcred="${gcred:A}"
  if ! command -v clauth >/dev/null 2>&1; then
    echo "clauth: ○ not installed — single-account machine, nothing to check"
  else
    echo "clauth (owns the profiles that get written OVER ~/.claude/.credentials.json):"
    # THE SAME MISTAKE AS THE LINE ABOVE, one axis over — and one level deeper
    # than the first fix for it reached. `_claude_active_profile` carries the
    # whole reasoning; the short version is that this asked `clauth which`, which
    # reports credential OWNERSHIP and not the active profile, so the answer was
    # wrong in an isolated session and tautological in every other. It reads
    # clauth's config now, which is both the right question and one fewer fork.
    active=$(_claude_active_profile)
    if [[ -z "$active" ]]; then
      _doctor_warn "could not determine the active profile — clauth's config names none"
      echo "    Neither 'active_profile' in ~/.clauth/profiles.toml nor ~/.clauth/status.json"
      echo "    could be read. The comparisons below that need it are skipped, not passed."
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
    elif ! jq -e . "$gcred" >/dev/null 2>&1; then
      # Section 1 makes this check against THIS SESSION's credential. Under
      # isolation that is a different file, so a torn global went unmentioned by
      # the doctor whose entire subject is torn writes — while it reported the
      # session's own healthy file as ✓.
      _doctor_bad "the live credential is present but NOT VALID JSON — every check below is UNKNOWN"
      echo "    A partial write does this, and every non-isolated session reads it."
      echo "    Fix: /login (or 'clauth login') to rewrite it."
    else
      # (a) THE HAZARD. `clauth <profile>` restores the profile's STORED copy over
      # the global file. Claude Code rotates refresh tokens — clauth's own log says
      # so: "adopted the live session's rotated login ... the running claude
      # refreshed first" — and clauth only notices on a ~90s poll. In that window
      # the stored copy is a SUPERSEDED refresh token, and restoring it can
      # invalidate every holder at once. This is the one check that predicts a mass
      # logout before it happens.
      # Derived once, here, and reused by both checks below.
      gcred_id="$(_claude_cred_id "$gcred")" || gcred_id=""
      pdir="$HOME/.clauth/profiles/$active"
      if [[ -n "$active" && -f "$pdir/credentials.json" ]]; then
        live_hash="$gcred_id"
        stored_hash="$(_claude_cred_id "$pdir/credentials.json")" || stored_hash=""
        # Resolved, because $gcred is resolved: both sides have to be physical or
        # the comparison below is about spelling rather than about the file.
        spath="$pdir/credentials.json"; spath="${spath:A}"
        if [[ -z "$live_hash" || -z "$stored_hash" ]]; then
          _doctor_warn "could not compare stored and live credentials — NOT CHECKED (an unreadable file is not agreement)"
        elif [[ "$spath" == "$gcred" ]]; then
          # SAME FILE, so "they match" is a tautology, not a finding. The global
          # path is a symlink into the store on this machine (relinked 2026-09-14
          # so the two Chrome native hosts stopped being independent holders), and
          # a comparison of a file with itself printing ✓ under the heading "the
          # one check that predicts a mass logout" is the vacuous-tick trap this
          # file already records for isolated sessions, back by a new route. It is
          # a note rather than a warning: one file is the DESIGNED shape, and the
          # only thing lost is this check, which has nothing left to compare.
          _doctor_note "stored copy of '$active' IS the live credential (same file) — nothing to compare"
          echo "    ~/.claude/.credentials.json resolves into that profile's store, so a switch"
          echo "    away and back cannot restore a superseded token. clauth's own"
          echo "    active_diverged_unsaved guard is blind here for the same reason."
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
      if [[ ! -d "$HOME/.clauth/profiles" ]]; then
        # No profiles registered (a fresh clauth, or a relocated profile root).
        # Without this the orphan warning below fires on every run forever,
        # telling the reader to "capture it into the profile it belongs to" when
        # there are no profiles at all — the permanently-red checker again.
        _doctor_note "no registered profiles yet — nothing to attribute the credential to"
      elif [[ -z "$gcred_id" ]]; then
        # An unreadable file is not agreement. Naming it apart from "orphaned"
        # matters: the fixes differ, and only one of them is /login.
        _doctor_warn "could not read the live credential — NOT CHECKED"
      elif ! global_owner="$(_claude_cred_owner "$gcred_id")"; then
        _doctor_warn "the live credential matches NO registered clauth profile"
        echo "    clauth cannot identify it, so it has no copy to restore and the next"
        echo "    'clauth <profile>' will overwrite it with no way back. Normal right after"
        echo "    a /login — and note that a rotation clauth has not adopted yet looks"
        echo "    exactly like this, so read it together with the comparison above."
        echo "    Capture it into the profile it belongs to before switching."
      else
        _doctor_note "live credential belongs to profile '$global_owner'"
        if [[ -n "$active" && "$global_owner" != "$active" ]]; then
          _doctor_warn "the live credential belongs to '$global_owner', but the active profile is '$active'"
          echo "    Every other check can pass while sessions on the global file bill"
          echo "    '$global_owner' rather than the account you think is selected."
        fi
      fi
    fi

    # NOT gated on $active. It was, and `[[ "$active" == "unknown" ]] && active=""`
    # above then made that gate fail in exactly the orphaned-credential state — so
    # the report said least about the armed, unlogged fallback chain precisely
    # when a switch was most dangerous. Neither note needs to know the active
    # profile.
    {
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
        # PARSED, NOT QUOTED — and that is the whole of this block's history.
        # The first version matched `fallback_chain[^]]*\]` with a line-based
        # `grep -oE`, which never fired against clauth's multi-line array, so the
        # note had never once printed on the box it was written for. Flattening
        # the file with `tr` to fix that removed the very line boundary that
        # bounded the match, and it then ran from anywhere those words appear to
        # the next `]` ANYWHERE in the file. A sed RANGE replaced it — and a
        # range still ends at the first line carrying `]`, which bounds it to a
        # LINE RANGE and not to one assignment, so on
        # `fallback_chain = [` + `profiles = [ "p1", "p2", ]` it printed
        # `auto-switch armed: fallback_chain = [ profiles = [ "p1", "p2", ]`:
        # a false alarm about the most disruptive thing clauth can do, over a
        # neighbouring line of profiles.toml quoted verbatim into a report that
        # lands in transcripts, in the file whose own header says NEVER PRINTS A
        # CREDENTIAL. Measured 2026-09-17, three fixes in.
        #
        # So the span is never printed and never trusted: `_claude_fallback_chain`
        # validates the array's interior and returns the member NAMES, and what
        # goes into the report is this function's own prose around them. A
        # validated member is the value of the key being reported; a span is
        # whatever the range happened to swallow.
        #
        # Scalar first, then split — the shape the quarantine consumer forty
        # lines below uses, so a reader comparing the two blocks sees one idiom.
        # `cspan=$(...)` makes it unambiguous that $? is the READER's status and
        # not an array assignment's, and unquoted `${(f)cspan}` yields an empty
        # array rather than one empty element when there is no chain.
        cspan="$(_claude_fallback_chain)"; crc=$?
        chain_walk=( ${(f)cspan} )
        if (( crc != 0 )); then
          # A ⚠, and NOT CHECKED rather than silence. An empty answer from a
          # question we could not ask is never agreement — and the thing not
          # answered here is whether clauth will rewrite the shared credential
          # under every running session when a quota fills. Not a ✗: the file is
          # clauth's, the repair is a hand-edit of another tool's config, and a
          # doctor that exits non-zero over that is the permanently-red checker
          # this repo has now produced seven times. Same severity the quarantine
          # reader below gives the same file being malformed, deliberately: two
          # readers of one file must not disagree about what unreadable costs.
          _doctor_warn "could not read clauth's fallback_chain — NOT CHECKED"
          # EVERY CAUSE THIS ARM CAN HAVE, because the first version named two and
          # the suite has a dedicated row for a third: on the `sed`-missing path
          # the file is fine and PATH is not, and a reader sent to inspect
          # another tool's config over a PATH fault is the "the remedy the guard
          # names did not remedy" class this repo already records. The last
          # clause is the honest limit: a comment inside the array, or TOML
          # literal ('single-quoted') strings, are legal and are refused here —
          # clauth writes neither, so only a hand-edit reaches it, and guessing
          # at a span we cannot validate would be worse than saying so.
          echo "    ~/.clauth/profiles.toml is unreadable, or that array is unterminated (a truncated"
          echo "    write), or 'sed' is not on PATH, or the array holds a comment or 'literal' strings,"
          echo "    which are legal TOML that this deliberately refuses rather than guess at."
          echo "    Whether an auto-switch is armed is therefore UNKNOWN, and an armed switch"
          echo "    rewrites the global credential under every running session."
        elif (( ${#chain_walk} )); then
          # Armed auto-switch is a loaded landmine, not a fault — hence a note.
          # `fallback_chain = []` reaches here with no members and is correctly
          # silent: it parses, it is configured, and it is not armed.
          _doctor_note "auto-switch armed: the chain walks ${(j:, :)chain_walk}"
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

        # ---- the quarantine: the one clauth state nothing here reported -----
        #
        # `auth_broken` is clauth's own quarantine — the profile's last token
        # refresh came back revoked/invalid — and it drops the account from the
        # fallback walk, refuses it as a switch target, and, because
        # `_claude_profile_excluded` reads this same key, excludes it from this
        # repo's account picker.
        #
        # WHY IT NEEDS REPORTING, given the picker already acts on it: acting on
        # it is what CONCEALS it. A quarantined account is never chosen, so no
        # session launches on it, so nothing the reader sees at launch mentions
        # it — work silently concentrates on the accounts that are left, which is
        # the concentration the account-dir design exists to undo. Before this
        # block nothing in this repo printed the word outside a comment.
        #
        # AND IT DOES NOT HEAL ITSELF. Measured against the INSTALLED clauth —
        # 0.15.1, and that is proven rather than assumed: sha256 of
        # ~/.local/bin/clauth equals the clauth-linux-x86_64 asset of the v0.15.1
        # release, so the source read below is the code that runs. The flag has
        # exactly seven mutation sites and five clearing paths: `clauth login` /
        # capture, an adopt from the live mirror, an adopt from disk at switch
        # time, a carry after a terminal 400, and a successful REFRESH. A
        # successful usage FETCH is not one of them. So once anything else has
        # put a live token in the store the poll stops 401ing, the rotation leg
        # is never entered, and the flag outlives the rejection that set it.
        # Observed: on 2026-09-14 three profiles were flagged at 08:29:13-27, the
        # reconciler adopted their live credentials at 08:29:28, and the flag
        # stood 70 minutes until `clauth login` — with no `auth_broken cleared`
        # line in the journal, which clauth emits on every transition.
        #
        # A ⚠, NEVER A ✗. Clearing it is a write to profiles.toml, which clauth
        # owns, and there is no out-of-band clear: no CLI subcommand, no TUI
        # action, no MCP tool (`clauth enable` restores a USER-disabled profile,
        # and upstream's own comment says that is "never auth_broken's"). The
        # remedy therefore needs a human and a browser, and a retired-but-still-
        # registered account would make claude-doctor exit non-zero forever — the
        # permanently-red checker this repo has now produced six times.
        qspan="$(_claude_quarantined_profiles)"; qrc=$?
        if (( qrc != 0 )); then
          _doctor_warn "could not read clauth's quarantine list — NOT CHECKED"
          echo "    ~/.clauth/profiles.toml is there but unreadable, or its auth_broken array is"
          echo "    unterminated (a truncated write). An empty answer from a file we could not"
          echo "    read is not agreement: a quarantined account is dropped from the picker with"
          echo "    nothing else on the machine saying so."
        else
          quarantined=( ${(f)qspan} )
          qreal=0
          for pname in $quarantined; do
            qstore="$HOME/.clauth/profiles/$pname/credentials.json"
            # TOTAL CLASSIFICATION, not a fall-through. `clauth login <name>` for
            # a name that is not a profile CREATES one — the trap the reconciler
            # carries four lines about ("clauth login would make it real again"),
            # and #132's lesson that an enumeration must classify every name it
            # can see or its remedy is unrunnable for one of them. Reachable by a
            # hand-edit or a crash between writes: `set_auth_broken_persisted`
            # refuses to ADD a name the profile list does not carry, and `remove`
            # takes it back out, so the two lists agree unless something else
            # wrote one of them.
            # THE DISCRIMINATOR IS THE PROFILE DIRECTORY, NOT THE CREDENTIAL.
            # Keying "inert" on `credentials.json` misfiles a REGISTERED profile
            # whose credential is merely missing — a rename in flight (the
            # reconciler's own `refused-no-store` path), a crash between
            # `clauth login`'s registration and the credential write, or a
            # credential removed to force a re-login. For those `clauth login`
            # REPAIRS rather than creates, and the Account-dirs enumeration below
            # already tells the reader so about the same name: two sections of one
            # report must not print opposite remedies.
            if [[ ! -d "${qstore:h}" ]]; then
              _doctor_note "clauth's quarantine list names '$pname', which is not a registered profile — inert"
              echo "    Nothing can be launched or polled under that name, so the entry costs"
              echo "    nothing. Do NOT run 'clauth login $pname' to clear it — that would create"
              echo "    the profile rather than repair one. 'clauth list' shows what is registered."
              continue
            fi
            qreal=$(( qreal + 1 ))
            if [[ ! -f "$qstore" ]]; then
              _doctor_warn "clauth has '$pname' quarantined (auth_broken), and its profile store holds NO credential"
              echo "    The profile IS registered, so this is a store to repair rather than a name"
              echo "    that cannot be launched."
              echo "    Fix: clauth login $pname"
              continue
            fi
            qstate="$(_claude_store_auth_state "$qstore")"
            qexp="${qstate#* }"; qstate="${qstate%% *}"
            case "$qstate" in
              usable)
                _doctor_warn "clauth has '$pname' quarantined (auth_broken) — but its stored credential is USABLE"
                echo "    That token expires $(_claude_fmt_delta $(( qexp - now_ms ))), so clauth is refusing an account that"
                echo "    still works. A rotation clauth could not attribute leaves exactly this." ;;
              expired)
                _doctor_warn "clauth has '$pname' quarantined (auth_broken); its stored access token expired $(_claude_fmt_delta $(( qexp - now_ms )))"
                echo "    Renewing it needs a refresh. The flag WIDENS that profile's poll rather than"
                echo "    stopping it — poll_backoff_ms returns AUTH_BROKEN_BACKOFF_MS (~15 min) before"
                echo "    it consults any streak — so recovery is slow, not absent." ;;
              dead)
                _doctor_warn "clauth has '$pname' quarantined (auth_broken), and its stored credential cannot authenticate"
                echo "    There is no usable access token in the store either, so the flag agrees"
                echo "    with what is on disk." ;;
              *)
                _doctor_warn "clauth has '$pname' quarantined (auth_broken); its stored credential could not be read"
                echo "    Whether the flag is stale is NOT CHECKED — an unreadable file is not agreement." ;;
            esac
            echo "    Fix: clauth login $pname"
          done
          if (( qreal )); then
            # Said ONCE, after the rows, and only when at least one entry names a
            # real profile: on the inert-entry path every sentence here is wrong.
            echo "    What lifts an auth_broken flag on clauth 0.15.1: 'clauth login', or clauth"
            echo "    itself adopting or carrying a rotation it can prove. A later successful usage"
            echo "    FETCH does not, so a flag can stand for hours after the store is healthy again."
            # ATTRIBUTED ONLY WHERE THE RECONCILER CAN RUN. `reconcile_all` walks
            # this root and nothing else, so on a machine with no account dirs —
            # a modular adopter with clauth and no timer, or any box before the
            # first build — blaming "our own reconciler" names a mechanism that
            # has never executed there. The general sentence above is true
            # everywhere; this one is not.
            if [[ -d "${CLAUDE_ACCOUNT_DIRS_ROOT:-$HOME/.local/state/claude-account-dirs}" ]]; then
              echo "    On this machine our own reconciler adopting the live token is also what removes"
              echo "    the failing poll clauth would otherwise have recovered through."
            fi
          elif (( ${#quarantined} == 0 )); then
            _doctor_ok "no profile is quarantined by clauth (auth_broken)"
          fi
        fi
      fi
    }
  fi

  # ---- 3b. Legacy pre-clauth config dirs -----------------------------------
  # OUTSIDE the clauth branch, deliberately. This sat inside the `else` of
  # "is clauth installed", which is exactly backwards: a machine that never
  # adopted clauth is the one most likely to still carry ~/.claude-work and
  # ~/.claude-personal, and it was the one machine that got no report at all.
  # The check depends on nothing clauth provides.
  for ldir in ${(f)"$(_claude_legacy_cred_dirs)"}; do
    [[ -n "$ldir" ]] || continue
    _doctor_warn "legacy config dir still holds a credential: ${ldir/#$HOME/~}/.credentials.json"
    echo "    An untracked copy of a login, and an untracked participant in refresh"
    echo "    rotation. Remove it once nothing launches with CLAUDE_CONFIG_DIR=$ldir."
  done

  # ---- 3c. Usage-cache freshness: what the picker is ranking on ------------
  #
  # WHY THIS IS A LINE AND NOT A TIMER. §5.7 of the tenant/pool spec called for a
  # `claude-usage-refresh.timer` and a drop of the picker's staleness threshold
  # from 3600 s to 900 s. Neither shipped, and the reason is measured rather than
  # argued: THERE IS NO REFRESH ENTRY POINT. clauth's only writer of
  # usage_cache.json is its scheduler, every fetch is gated on a lease acquired
  # in exactly two places — its TUI and its daemon — and no CLI subcommand takes
  # that lease. Probed 2026-09-09 against caches already 207–282 s old:
  # `clauth which`, `clauth status --json`, `clauth list`, `clauth sessions` and
  # `clauth jobs` refreshed nothing, mtimes unchanged to the second, and
  # `clauth --help` has no `refresh`. A 15-minute sample at 10 s resolution
  # recorded ZERO writes to any cache while ~29 panes were open.
  #
  # So the honest report is the age, said plainly, with no command to offer. A ✗
  # would be the permanently-red checker this file's own rules forbid: on this
  # machine a stale cache is the ordinary resting state, not a fault, and the
  # only thing that clears it is a person opening clauth's TUI.
  #
  # The default repeated here (3600) is _claude_pick_class's. It is a literal in
  # two files because zsh/functions/claude.sh must not depend on zshrc.herdr —
  # claude-doctor is a full-install command and the picker is the portable herdr
  # layer, which a modular adopter sources alone. A state-table row asserts the
  # two literals are the same number, so they cannot drift apart in silence.
  echo
  uc_max="${CLAUDE_PICK_CACHE_MAX_AGE:-3600}"
  [[ "$uc_max" == <-> ]] && (( uc_max > 0 )) || uc_max=3600
  uc_seen=0; uc_stale=0; uc_missing=0; uc_oldest=-1; uc_oldest_p=""
  for pdir in "$HOME"/.clauth/profiles/*(N-/); do
    [[ -e "$pdir/credentials.json" || -L "$pdir/credentials.json" ]] || continue
    (( uc_seen++ ))
    ucf="$pdir/usage_cache.json"
    if [[ ! -r "$ucf" ]]; then
      (( uc_missing++ )); continue
    fi
    uc_age="$(_claude_file_age_s "$ucf")" || uc_age=""
    if [[ -z "$uc_age" ]]; then
      (( uc_missing++ )); continue
    fi
    (( uc_age > uc_oldest )) && { uc_oldest="$uc_age"; uc_oldest_p="${pdir:t}" }
    (( uc_age > uc_max )) && (( uc_stale++ ))
  done
  if (( ! uc_seen )); then
    _doctor_note "no registered profile with a credential — nothing for the picker to rank"
  else
    # An UNREADABLE cache is its own state and is counted apart from a stale one:
    # the picker classes both `unknown`, but the fixes differ (one is age, the
    # other is a file that was never written).
    if (( uc_oldest >= 0 )); then
      if (( uc_stale )); then
        # MILLISECONDS: _claude_fmt_delta's input is ms, and feeding it seconds
        # renders a 20-minute-old cache as "1s ago" — a stale reading reported as
        # a fresh one, by the line whose whole job is to say it is stale.
        _doctor_warn "usage caches: oldest $(_claude_fmt_delta $(( - uc_oldest * 1000 ))) ('$uc_oldest_p') — $uc_stale of $uc_seen past the picker's ${uc_max}s threshold, so it ranks them as 'unknown'"
      else
        _doctor_ok "usage caches: oldest $(_claude_fmt_delta $(( - uc_oldest * 1000 ))) ('$uc_oldest_p'), all within the picker's ${uc_max}s threshold"
      fi
    fi
    (( uc_missing )) &&       _doctor_note "$uc_missing of $uc_seen profiles have no readable usage cache at all — also 'unknown' to the picker"
    # Said on EVERY run, stale or not, because the absence of a refresher is the
    # standing fact a reader needs in order to act on the line above — and the
    # thing they would otherwise go looking for a timer to fix.
    _doctor_note "nothing refreshes these on a schedule: clauth's only usage writer is lease-gated to its TUI and its daemon, and there is no 'clauth refresh'"
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
  nproc_claude=0; unknown_n=0
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
      credpath="$gcred"; grp="the SHARED global file"
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
      elif (( n >= 3 )); then
        # THREE, from the evidence above rather than from the >8 flat count this
        # replaced: the observed multi-session incidents hit 3, 3, 4, 5 and 6
        # sessions, so a group of 6 printing ✓ meant the largest event on record
        # read as healthy. The remedy is named because more groups needs more
        # logins, not rebalancing.
        _doctor_warn "$n on $label — one lost write logs out all $n"
      else
        _doctor_ok "$n on $label"
      fi
    done
    (( unknown_n > 0 )) && _doctor_note "$unknown_n process(es) whose config dir could not be read — NOT CHECKED"
    # The TOTAL still matters and the grouping does not capture it. Replacing the
    # old flat count outright meant forty processes spread over eight groups of
    # five reported eight ✓ and no warning — while CLAUDE.md records 33 Claude
    # processes driving this box to load 27 and 96% swap. Memory, not the
    # credential file, is the binding constraint here.
    if (( nproc_claude > 8 )); then
      _doctor_warn "$nproc_claude Claude processes in total — memory is the binding constraint on this box"
      echo "    Reduce with 'hreap --close --mine'; an idle agent still holds its memory"
      echo "    AND still refreshes its token. To add credential groups: 'clauth login <name>'."
    else
      _doctor_note "$nproc_claude Claude process(es) total; the credential file has no lock in any of them"
    fi
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
      # "Never connected" and "never authorised" are different findings, and
      # conflating them made this section permanently red. On 2026-09-07 it
      # flagged ten claude.ai connectors that had never been set up — Apollo,
      # Attio, Canva, Clay, Doc360, HubSpot, Lightfield, Miro, Superhuman,
      # Sybill — as failures. They are the catalogue claude.ai advertises, not
      # anything configured here, and every attempt ends the same way:
      #
      #   authentication_error … error_code: mcp_unauthorized_no_token
      #
      # Nothing can be repaired, so a ✗ there is a line the reader cannot act
      # on — and a checker that emits those stops being read. Fifth time this
      # repo has hit that trap.
      #
      # A MINIMUM-ATTEMPTS FLOOR WOULD NOT HAVE WORKED, which is worth saying
      # because it is the obvious fix: those connectors had 24 attempts each,
      # Miro 73. Volume does not separate them. The discriminator is the ERROR
      # CODE — the same lesson #109 learned for mcpOAuth, where the metadata
      # rather than the absence told two states apart. `mcp_unauthorized_no_token`
      # is never-authorised; `mcp_endpoint_not_found` (the dead claude.ai Linear
      # connector, 1,936 times) is configured-and-broken, which is what ✗ is for.
      # Keyed on the ATTEMPT COUNT, not on fail_n, and that is not a style
      # choice. $_CLAUDE_LOG_FAIL is "Connection failed", but the claude.ai proxy
      # transport writes LOWERCASE "claude.ai proxy connection failed" — so
      # fail_n is 0 for every connector of this kind, and a `fail_n > 0` guard
      # here could never be true. (First draft of this fix had exactly that and
      # changed nothing; the live run is what caught it.) A pre-existing
      # consequence, left alone deliberately because widening the match would
      # move every ⚠ threshold in this section and wants its own change: the
      # "mostly failing" warning below undercounts claude.ai connectors whose
      # failures only ever appear in lowercase.
      # A THIRD state, found by running this against the real log store rather
      # than reasoning about it: claude.ai Miro fails 72 of 73 attempts with
      # "OAuth token has been invalidated. Re-authentication is required." That
      # connector DID work once, so "it has never worked in this window" was
      # both false and unactionable — the reader needs to be told to
      # re-authenticate, not that the thing is dead. Still a ✗: unlike the
      # never-authorised case there is something to do about it.
      unauth_n=$(grep -l -- 'mcp_unauthorized_no_token' $files 2>/dev/null | wc -l)
      invalid_n=$(grep -l -- 'OAuth token has been invalidated' $files 2>/dev/null | wc -l)
      if (( ok_n == 0 && unauth_n == ${#files} )); then
        (( show_all )) && _doctor_note "$srv: never authorised — ${#files} attempts, all mcp_unauthorized_no_token (offered, not configured)"
      elif (( ok_n == 0 && invalid_n > 0 )); then
        _doctor_bad "$srv: OAuth token invalidated — 0 of ${#files} attempts connected; re-authenticate it (/mcp, or at claude.ai)"
      elif (( ok_n == 0 )); then
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

  # ---- 7. Global settings.json: keys a third party can remove --------------
  # ~/.claude/settings.json is user-level, NOT in this repo, and clauth REWRITES
  # it: it merges a profile's [env] on switch and clears it on switch away (which
  # is why `env` is `{}`), and it writes the profile's [models] block. On
  # 2026-09-06 that removed `model: opus[1m]` outright — every new session
  # silently defaulted to a different model for a day before anyone noticed. The
  # file also carries the statusLine publisher, the secret-emission guard hook and
  # 23 enabled plugins, so a key vanishing from it is not cosmetic.
  #
  # Deliberately NOT managed by dotbot. A symlink would make clauth write through
  # it, and clauth rewrites on every profile switch — a permanently dirty tracked
  # file, which is the churn DOTFILES_EXPECTED_DIRTY exists to paper over
  # elsewhere. Detect the damage instead of fighting for ownership of the file:
  # the same choice claude-doctor makes about the credential.
  #
  # The check is ARMED BY THE USER and silent by default. A hardcoded list of
  # required keys would be a permanently-red check on every machine that
  # legitimately sets none of them — the trap this file's own header warns about.
  # Declare what matters in ~/.zshrc.local:
  #
  #     CLAUDE_SETTINGS_REQUIRE=( model statusLine.command )
  #
  # Values are jq paths, tested for "present and non-empty". Unarmed, the section
  # still PRINTS the current values, so a removal is visible to a reader even when
  # nothing fails — visible beats silent, and neither is a false alarm.
  echo
  echo "Global settings (${$(_claude_global_settings_file)/#$HOME/~} — clauth rewrites this file):"
  gsettings="$(_claude_global_settings_file)"
  if [[ ! -f "$gsettings" ]]; then
    _doctor_note "no global settings.json — NOT CHECKED"
  elif ! jq -e . "$gsettings" >/dev/null 2>&1; then
    _doctor_bad "global settings.json is NOT VALID JSON — Claude Code will ignore it wholesale"
  else
    for key in model statusLine.command; do
      val="$(jq -r --arg k "$key" 'getpath($k | split(".")) // empty' "$gsettings" 2>/dev/null)"
      _doctor_note "$key = ${val:-<absent>}"
    done
    _doctor_note "plugins enabled: $(jq -r '(.enabledPlugins // {}) | length' "$gsettings" 2>/dev/null), hook events: $(jq -r '(.hooks // {}) | length' "$gsettings" 2>/dev/null)"
    # Accepts a zsh array (the documented form, for ~/.zshrc.local) OR a plain
    # space-separated scalar, which is all an exported environment variable can
    # be. Joining then splitting normalises both. Safe here in a way it would NOT
    # be for DOTFILES_EXPECTED_DIRTY — CLAUDE.md records that word-splitting a
    # scalar makes a PATH containing a space impossible to express; these are jq
    # key paths, which cannot contain spaces.
    local -a req
    req=( ${=${(j: :)CLAUDE_SETTINGS_REQUIRE}} )
    if (( ${#req} == 0 )); then
      _doctor_note "no CLAUDE_SETTINGS_REQUIRE set — nothing is asserted; see the note in claude.sh to arm it"
    else
      for key in "${req[@]}"; do
        [[ -n "$key" ]] || continue
        val="$(jq -r --arg k "$key" 'getpath($k | split(".")) // empty' "$gsettings" 2>/dev/null)"
        if [[ -n "$val" ]]; then
          _doctor_ok "required key '$key' present"
        else
          _doctor_bad "required key '$key' is MISSING from the global settings.json"
          echo "    clauth clears \`env\` and rewrites \`[models]\` on every profile switch."
          echo "    Restore it, or drop the key from CLAUDE_SETTINGS_REQUIRE if it is no longer wanted."
        fi
      done
    fi
  fi

  echo
  #===========================================================================
  # The account dirs: one credential per account, and a shared everything else
  #===========================================================================
  # WHY THIS SECTION EXISTS. scripts/claude-account-dirs.sh points each account
  # dir's .credentials.json at the clauth profile store as a SYMLINK, and Claude
  # Code writes that file ATOMICALLY -- a rename, which REPLACES the symlink with
  # a real file holding a freshly rotated token. The builder then used to restore
  # the link unconditionally, putting the store's SUPERSEDED token back; rotation
  # is server-side, so that logged out every live session on the account. Three
  # of four account dirs were in that state when it was found (2026-09-08), with
  # one profile already quarantined by clauth as auth_broken, and NOTHING on the
  # machine reported any of it.
  #
  # The builder now reconciles instead. This is the check that says whether the
  # invariant actually holds -- for each account, exactly ONE credential file,
  # read by every process using that account.
  echo
  echo "--- Account dirs ---"
  {
    local adroot="${CLAUDE_ACCOUNT_DIRS_ROOT:-$HOME/.local/state/claude-account-dirs}"
    local ad name store shared tstate real_n=0 seen=0
    local vfile verdict vdetail vage vline id_a id_s adlink
    local -a shared_missing

    if [[ ! -d "$adroot" ]]; then
      # Nothing to check is not a failure: a modular adopter, or anyone who has
      # not run an isolated session, legitimately has no account dirs.
      _doctor_note "no account dirs at ${adroot/#$HOME/~} — nothing isolated yet"
    else
      # `(N-/)`, NOT `(N/)`. The `/` qualifier matches directories only, and a
      # symlink TO a directory is not one unless `-` makes the qualifiers follow
      # links. With the bare `/`, a symlinked account dir was silently never
      # checked — not reported as skipped, not reported at all; the section
      # simply behaved as though it did not exist.
      #
      #     mkdir real; ln -s real link
      #     print -l -- *(N/)    -> real
      #     print -l -- *(N-/)   -> link  real
      #
      # That took out every check below for such a dir: credential mode, dangling
      # links, store divergence, "links to ANOTHER profile's store", and the
      # shared-subtree assertions. The last is why it matters — a symlinked
      # account dir resolving to a DIFFERENT profile's store is exactly the
      # silent-wrong-account shape this section exists to catch, and the one
      # checker that would notice could not see it.
      # `(N-/)` covers real dirs and symlinks TO dirs; `(N@)` adds the symlinks
      # `-/` drops — a DANGLING one, or one pointing at a non-directory. All three
      # are account dirs as far as a reader is concerned, and a dangling one is
      # precisely the half-finished rename this section should be reporting.
      # Deduplicated, because a live symlink-to-dir matches both patterns.
      local -a _ad_all
      # `D` FORCES dotfile matching rather than inheriting it. `setopt GLOB_DOTS`
      # is set by this repo's own `zshrc`, so in an interactive shell these globs
      # already saw dot-directories — but claude-doctor is a function that can be
      # sourced anywhere, and with the option off a dot-prefixed account dir
      # HOLDING A CREDENTIAL was invisible to the one checker that would report it.
      # That is the same blind spot #132 widened these globs to close, reachable
      # through the caller's shell options instead of through the qualifiers.
      # It is also why #132's own rows could not catch the defect above: the state
      # table runs `zsh -c`, where GLOB_DOTS is off, so the branch was unreachable.
      _ad_all=( "$adroot"/*(ND-/) "$adroot"/*(ND@) )
      for ad in ${(u)_ad_all}; do
        name="${ad:t}"
        store="$HOME/.clauth/profiles/$name/credentials.json"
        # NOT `seen=1` here. This loop enumerates dot-named archives too, and the
        # classification below calls those "not an account dir" — so setting the
        # flag up front made a machine holding nothing BUT archives print that
        # line and then suppress "no account dirs built yet", contradicting
        # itself. It is set past the point where the name is known to be one.

        # A symlinked account dir is how a profile RENAME keeps old paths working
        # while panes drain: an expected transitional state, not a fault. So it is
        # a note when it resolves to a registered profile and a ⚠ naming the
        # target when it does not. Reported BEFORE the store check below, which
        # would otherwise call a compat link "an account dir with no clauth
        # profile store" and send the reader to `clauth login` for a name that is
        # deliberately no longer a profile.
        if [[ -L "$ad" ]]; then
          # `${ad:A}` resolves a symlink only as far as it EXISTS: on a dangling
          # one it returns the link's own path, so the warning below would have
          # read "p9 is a symlink to .../p9" — naming the link instead of the
          # target, which is the one fact the reader needs. `zstat +link` reads
          # the target itself, and unlike `readlink` it is a zsh module rather
          # than a PATH dependency: CLAUDE.md records readlink silently producing
          # NOTHING under the state table's from-scratch PATH, in this very file.
          zmodload -F zsh/stat b:zstat 2>/dev/null
          adlink="$(zstat +link -- "$ad" 2>/dev/null)" || adlink=""
          [[ -n "$adlink" ]] || adlink="${ad:A}"
          # A relative target is relative to the link's own directory.
          [[ "$adlink" == /* ]] || adlink="${ad:h}/$adlink"
          if [[ -d "$HOME/.clauth/profiles/${adlink:t}" ]]; then
            _doctor_note "$name -> ${adlink:t} (compat symlink; resolves to a registered profile)"
            store="$HOME/.clauth/profiles/${adlink:t}/credentials.json"
          else
            _doctor_warn "$name is a symlink to '${adlink/#$HOME/~}', which is not a registered profile"
            echo "    A rename in progress looks like this. If it is not one, the link points nowhere useful."
          fi
          # A link whose target is not a directory has no account dir to check
          # past this point; every test below would read through the dead link.
          if [[ ! -d "$ad" ]]; then
            continue
          fi
        fi

        # A NAME CLAUTH CANNOT OWN IS NOT A BROKEN ACCOUNT DIR, and it must be
        # classified before the store check below — which is the fall-through for
        # every name and assumes each one is a would-be profile. Without this, a
        # deliberately dot-prefixed archive directory read as
        # "an account dir with no clauth profile store" and the reader was told to
        # run `clauth login .personal.stray-20260910-112747`, which cannot succeed.
        # Observed in live output 2026-09-10.
        #
        # This was NOT a #132 regression, and the correction matters because the
        # obvious fix is wrong: `setopt GLOB_DOTS` is set repo-wide, so the old
        # `*(N/)` had already been matching dot-directories for as long as it
        # existed — #132 only added symlinks. Re-narrowing the glob would hide a
        # dot-prefixed directory that HOLDS A CREDENTIAL, which is the blind spot
        # #132 was written to close. So the enumeration stays wide, and the two
        # cases are told apart: a credential under such a name is a finding
        # (nothing manages it, nothing rotates it), and no credential is a note.
        if _claude_name_cannot_be_profile "$name"; then
          # FOUR SHAPES, NOT TWO. `[[ -e || -L ]]` is true for the DESIGNED shape
          # of an account-dir credential — a symlink into the profile store — so
          # the one-line presence test called the managed case an unmanaged copy
          # and told the reader to shred it, which destroys the live credential
          # through the link. See _claude_cred_shape for the measurement.
          _cshape=( ${=$(_claude_cred_shape "$ad/.credentials.json")} )
          case "${_cshape[1]}" in
            file)
              _doctor_warn "$name: not a profile name, but it holds a credential of its own"
              echo "    A real file, not a link into the store: nothing reconciles it and nothing"
              echo "    rotates it, because no profile can carry this name. Move it into a real"
              echo "    profile or shred it — an unmanaged copy of a login is what this is for."
              ;;
            managed)
              _doctor_note "$name: archived directory sharing profile '${_cshape[2]}'s credential"
              echo "    The credential here is a SYMLINK into profile '${_cshape[2]}', which is"
              echo "    reconciled and rotated under that name — so this is a stale directory, not"
              echo "    an unmanaged login. Remove the directory; that drops the link and touches"
              echo "    nothing '${_cshape[2]}' relies on."
              echo "    Do NOT shred the link: shred follows it and overwrites the live credential."
              ;;
            dangling)
              _doctor_note "$name: archived directory whose credential link is dangling"
              echo "    It holds nothing — the link points at '${_cshape[2]/#$HOME/~}', which does not"
              echo "    exist. A rename that removed the profile leaves exactly this. Remove the"
              echo "    directory; there is no credential here to move anywhere."
              ;;
            foreign)
              _doctor_warn "$name: not a profile name, and its credential links outside the store"
              echo "    The link resolves to '${_cshape[2]/#$HOME/~}', which is not a clauth profile"
              echo "    store, so nothing reconciles or rotates it. Check what wrote it before"
              echo "    removing anything — the target may be in use by something else."
              ;;
            *)
              _doctor_note "$name: archived or internal directory, not an account dir (a leading dot cannot be a profile name)"
              echo "    Ignored by the picker, the builder and the reconciler. Remove it once it has"
              echo "    served its purpose. NOT a 'clauth login' candidate."
              ;;
          esac
          continue
        fi

        seen=1

        if [[ ! -e "$store" && ! -L "$store" ]]; then
          _doctor_warn "$name: an account dir with no clauth profile store"
          echo "    Nothing can reconcile it. 'clauth login $name' if it should be a profile;"
          echo "    if the name was renamed away, remove the dir instead — 'clauth login'"
          echo "    would make the name real again and a rename in progress needs it free."
          continue
        fi

        # -L before -e: [[ -e ]] FOLLOWS symlinks, so a dangling link reads as
        # "no file" and would be reported as "not logged in" — sending the reader
        # to /login instead of at the broken link. CLAUDE.md records this exact
        # trap for the credential check one section up.
        #
        # `${x:A}`, NOT `readlink`. CLAUDE.md records readlink as a DEPENDENCY the
        # state table's from-scratch PATH does not carry, and this section shipped
        # in #116 using it anyway — so under that PATH readlink produced NOTHING,
        # every comparison failed, and a perfectly healthy link was reported as
        # "links to ANOTHER profile's store". Found the moment this section finally
        # got rows, which it shipped without. `:A` is a zsh modifier: no fork, no
        # dependency, and it is what the credential check above already uses.
        if [[ -L "$ad/.credentials.json" ]]; then
          if [[ ! -e "$ad/.credentials.json" ]]; then
            _doctor_bad "$name: credential link DANGLES — its target is gone"
            echo "    -> ${${ad}/#$HOME/~}/.credentials.json"
            echo "    'clauth login $name' to recreate it."
          # `:A` is a MODIFIER on a parameter, not a glob qualifier: written as
          # `"$x"(:A)` inside [[ ]] it parses fine and resolves nothing, so every
          # healthy link compared unequal. Bind the paths first.
          elif adlink="$ad/.credentials.json"; [[ "${adlink:A}" == "${store:A}" ]]; then
            _doctor_ok "$name: credential shared with the clauth store"
          else
            _doctor_bad "$name: credential links to ANOTHER profile's store"
            echo "    -> ${${ad}/#$HOME/~}/.credentials.json"
            echo "    Sessions in this dir bill that account. Re-run the builder to repoint it."
          fi
        elif [[ -f "$ad/.credentials.json" ]]; then
          real_n=$(( real_n + 1 ))
          # `_claude_cred_id`, not `cmp`: cmp is not on the state table's PATH
          # either, so it failed silently and every identical pair was reported as
          # DIFFERING. The id helper is jq+sha256sum, both of which ARE on it, and
          # it already refuses to hash nothing.
          id_a="$(_claude_cred_id "$ad/.credentials.json" 2>/dev/null)" || id_a=""
          id_s="$(_claude_cred_id "$store" 2>/dev/null)" || id_s=""
          if [[ -n "$id_a" && "$id_a" == "$id_s" ]]; then
            # Identical content: a rotation that has not been reconciled yet, or
            # none since the last one. Harmless until they diverge, so it is a
            # note about pending work, not an alarm.
            _doctor_note "$name: credential is a real file, still identical to the store"
            echo "    A session's atomic write replaced the link. Reconciling relinks it."
          else
            # A ⚠, NOT a ✗. This state is produced by an ordinary token refresh and
            # is resolved by the reconciler on the next launch or the next timer
            # tick, so calling it a failure makes claude-doctor exit non-zero on a
            # busy machine essentially always — the permanently-red checker this
            # repo has now documented four times, three lines above a note calling
            # the same state "Expected after a token refresh". It is still worth
            # naming, because until it IS reconciled clauth is polling with a
            # stale token, which is how an account gets quarantined.
            #
            # WHICH ADVICE TO GIVE depends on whether the reconciler will actually
            # resolve it, and only the reconciler knows: it REFUSES a divergence it
            # cannot attribute (a login as another account, an unreadable file, a
            # profile with no anchor), and for those the timer hits the same wall
            # every two minutes forever. Saying "the timer normally handles it"
            # there is a checker prescribing something that cannot work — the
            # failure this whole feature exists to remove. So the reconciler writes
            # its verdict down and this reads it, rather than re-deriving the rule
            # and drifting from it.
            _doctor_warn "$name: credential is a real file that DIFFERS from the clauth store"
            vfile="$ad/.reconcile-status"; verdict=""; vdetail=""; vage=""
            if [[ -r "$vfile" ]]; then
                vline="$(< "$vfile")"
                verdict="${${(s: :)vline}[2]}"
                vdetail="${vline#* * }"
                # `date`, not EPOCHSECONDS: that needs zsh/datetime, which this
                # file never loads, and the state table builds a PATH from scratch
                # — so the module would be absent there and the check would go
                # quiet rather than fail. `date` is already on that PATH.
                vage=$(( $(date +%s) - ${${(s: :)vline}[1]:-0} ))
            fi

            if [[ "$verdict" == refused-* ]]; then
                echo "    The reconciler REFUSED this one ($verdict), so the timer will not fix"
                echo "    it — it will refuse again on every tick. Until then clauth polls with"
                echo "    the stale stored token, which is how an account gets quarantined."
                case "$verdict" in
                    refused-not-rotation)
                        echo "    The two credentials differ outside the fields a refresh touches and"
                        echo "    could not be shown to be the same account — a login as a DIFFERENT"
                        echo "    account looks exactly like this." ;;
                    refused-no-anchor)
                        echo "    clauth has no account_id.json anchor for this profile." ;;
                    refused-unreadable)
                        echo "    One of the two files could not be read well enough to decide." ;;
                    refused-no-store)
                        echo "    The clauth profile has no stored credential to reconcile against." ;;
                esac
                [[ -n "$vdetail" ]] && echo "    Fix: $vdetail"
            else
                echo "    An ordinary token refresh produces this. Until it is reconciled, clauth"
                echo "    polls with the stale stored token, which is how an account gets"
                echo "    quarantined as auth_broken. The 2-minute timer normally handles it; to"
                echo "    do it now:"
                echo "      ~/.dotfiles/scripts/claude-account-dirs.sh --reconcile"
                # No verdict on record is its own state: it means the reconciler has
                # not run here since this was introduced, NOT that all is well.
                [[ -z "$verdict" ]] && \
                    echo "    (no reconciler verdict on record yet for this account dir)"
            fi
            if [[ -n "$verdict" && -n "$vage" ]] && (( vage > 900 )); then
                echo "    Last reconciler verdict is $(( vage / 60 ))m old — is the timer running?"
            fi
          fi
        else
          _doctor_bad "$name: no credential in the account dir at all"
          echo "    Sessions started here will not be logged in. Re-run the builder."
        fi

        # THE POOLED-SHARING INVARIANT. Memory, plugins, skills, hooks and the
        # user-level CLAUDE.md must stay symlinked back to ~/.claude, or accounts
        # in a pool silently stop sharing them — and a session cannot tell.
        shared_missing=()
        for shared in projects plugins skills hooks CLAUDE.md; do
          [[ -e "$HOME/.claude/$shared" || -L "$HOME/.claude/$shared" ]] || continue
          if [[ ! -L "$ad/$shared" ]]; then shared_missing+=("$shared"); fi
        done
        if (( ${#shared_missing} )); then
          _doctor_bad "$name: not sharing ${(j:, :)shared_missing} with ~/.claude"
          echo "    Accounts in a pool are supposed to share memory, plugins and skills."
          echo "    Re-run: ~/.dotfiles/scripts/claude-account-dirs.sh $name"
        fi
      done

      # The reconciler timer. A LINKED unit is not a RUNNING one, and this whole
      # section exists because a credential quietly goes stale between launches;
      # a reconciler that is installed but not enabled restores exactly that
      # failure while every other line here reads green.
      #
      # Reported only when there is something to reconcile AND a user manager to
      # ask, so a machine with no systemd (a container, a server) and a machine
      # with no account dirs both stay silent rather than permanently red.
      if (( seen )) && command -v systemctl >/dev/null 2>&1; then
        tstate="$(systemctl --user is-active claude-cred-reconcile.timer 2>/dev/null)"
        if [[ "$tstate" == active ]]; then
          _doctor_ok "the credential reconciler timer is running"
        elif [[ -z "$tstate" ]]; then
          # No user manager to answer (no session bus, a container). "Could not
          # ask" is not "it is broken".
          _doctor_note "could not ask systemd about the reconciler timer — NOT CHECKED"
        else
          _doctor_warn "the credential reconciler timer is not running ($tstate)"
          echo "    Credentials are reconciled at launch, but a rotation between launches"
          echo "    leaves clauth polling a stale token, which is how an account gets"
          echo "    quarantined. Enable it:"
          echo "      systemctl --user enable --now claude-cred-reconcile.timer"
        fi
      fi

      (( seen )) || _doctor_note "no account dirs built yet"
      if (( real_n )); then
        _doctor_note "$real_n account dir(s) hold a real credential file rather than a link"
        echo "    Expected after a token refresh. '--reconcile' adopts the live one and relinks."
      fi
    fi

    # A DIRECTORY under ~/.clauth/profiles is not a profile. clauth leaves runtime
    # dirs and a .reconcile.lock behind under a name it no longer registers, and
    # the result looks exactly like a profile to anything globbing that path —
    # while having no credential and no entry in profiles.toml. Observed on this
    # machine 2026-09-10: `profiles/personal/` holding only `runtime-*/` and
    # `.reconcile.lock` after the profile was renamed away.
    #
    # The picker already skips it (it requires credentials.json), and the account
    # dir builder refuses it with `refused-no-store`. Both are correct and silent,
    # which is the reason to say it here: nothing else reports that a name which
    # still LOOKS like a profile has stopped being one.
    # NO `local` HERE. `pdir` is already local to this function (declared at the
    # top with every other loop variable), and in zsh `local NAME` with no
    # assignment on a name that already exists in the same scope DISPLAYS it as
    # `name=value` instead of re-declaring it. #132 added `local pdir pname` at
    # this spot and the doctor then printed a bare
    # `pdir=/home/…/.clauth/profiles/<last profile>` onto stdout, between two
    # sections — loop residue from the `preferred` check 555 lines earlier,
    # surfaced by the redundant re-declaration. Nothing in the repo echoes `pdir`.
    #
    # The convention this violated is stated at the top of this very function,
    # three lines from its first `local`, and CLAUDE.md records the earlier run
    # where forgetting it printed `du=zvi-quantivly` into the middle of a report.
    # A ~950-line function with no block scope is the real hazard: every `local`
    # in it shares one namespace. A state-table row now greps stdout for any bare
    # `name=value` line, so the next one is caught whatever the variable is.
    stray_profiles=(); unprofiled_dirs=(); unmanaged_stores=()
    shared_stores=(); dangling_stores=()
    for pdir in "$HOME"/.clauth/profiles/*(ND-/); do
      pname="${pdir:t}"
      # A name clauth cannot own is not a half-finished profile. Same rule, same
      # helper, as the account-dir enumeration above — see its comment for why
      # the test is a leading dot and nothing wider.
      #
      # And the SAME TWO-WAY SPLIT, which this loop was missing: classifying on
      # the name alone filed a dot-named store holding a LIVE CREDENTIAL as
      # benign archived state, as a note. That is the one shape this wide
      # enumeration exists to surface — a credential nothing rotates, under a
      # name no profile can ever be created to adopt, so `clauth login` cannot
      # even be offered as the remedy. A fix that is right on one side of a
      # report and wrong on the other is worse than one that is wrong on both:
      # the correct half is the reason nobody re-reads the other.
      if _claude_name_cannot_be_profile "$pname"; then
        # The same four-way split as the account-dir loop, through the same
        # helper. A presence test here had the identical defect: a dot-named
        # store whose credentials.json is a LINK into a real profile's store is
        # managed under that profile's name, and telling the reader to shred it
        # destroys that profile's live credential through the link.
        _cshape=( ${=$(_claude_cred_shape "$pdir/credentials.json")} )
        case "${_cshape[1]}" in
          file)               unmanaged_stores+=("$pname") ;;
          managed)            shared_stores+=("$pname -> ${_cshape[2]}") ;;
          dangling|foreign)   dangling_stores+=("$pname") ;;
          *)                  unprofiled_dirs+=("$pname") ;;
        esac
        continue
      fi
      [[ -e "$pdir/credentials.json" || -L "$pdir/credentials.json" ]] && continue
      stray_profiles+=("$pname")
    done
    if (( ${#stray_profiles} )); then
      _doctor_note "profile director$( (( ${#stray_profiles} == 1 )) && echo y || echo ies ) with no credential: ${(j:, :)stray_profiles}"
      echo "    Leftover runtime state, not a profile: nothing can launch on it, and the"
      echo "    picker and the account-dir builder both skip it. Remove when nothing is"
      echo "    running under it, or 'clauth login <name>' if it should be real —"
      echo "    but NOT if the name was renamed away: that would make it real again."
    fi
    if (( ${#unmanaged_stores} )); then
      _doctor_warn "under profiles/, not a profile name but holding a credential of its own: ${(j:, :)unmanaged_stores}"
      echo "    A real file, not a link into another store. A leading dot cannot be a clauth"
      echo "    profile name, so nothing reconciles these and nothing rotates them — and"
      echo "    'clauth login' cannot adopt them, because it refuses the name outright"
      echo "    ('can't start with a dot'). Move the credential into a real profile or shred"
      echo "    it; an unmanaged copy of a login is what this section is for."
    fi
    if (( ${#shared_stores} )); then
      _doctor_note "under profiles/, archived name sharing a real profile's credential: ${(j:, :)shared_stores}"
      echo "    The credential is a SYMLINK into the named profile's store, which is reconciled"
      echo "    and rotated under that name — so what is stale here is the directory, not a"
      echo "    login. Remove the directory; do NOT shred the link, which would follow it and"
      echo "    overwrite the live credential the real profile is using."
    fi
    if (( ${#dangling_stores} )); then
      _doctor_note "under profiles/, archived name whose credential link goes nowhere: ${(j:, :)dangling_stores}"
      echo "    The link has no target, so there is no credential here to move or remove. A"
      echo "    rename that took the profile away leaves exactly this. Remove the directory."
    fi
    if (( ${#unprofiled_dirs} )); then
      _doctor_note "under profiles/, not profile director$( (( ${#unprofiled_dirs} == 1 )) && echo y || echo ies ): ${(j:, :)unprofiled_dirs}"
      echo "    A leading dot cannot be a clauth profile name, so these are internal or"
      echo "    archived state rather than profiles missing a credential. Not a"
      echo "    'clauth login' candidate."
    fi

    # TWO sources of truth for the pool is a finding, not a merge (spec §5.1).
    # CLAUDE_ACCOUNT_POOL is ignored the moment a tenant table is loaded, so a
    # leftover flat pool is not wrong today — it is a line that silently stopped
    # meaning anything, and the next person to edit it will believe it works.
    if (( ${#CLAUDE_TENANT_POOL} )) && (( ${#CLAUDE_ACCOUNT_POOL} )); then
      _doctor_note "both pool sources are set: CLAUDE_ACCOUNT_POOL (${#CLAUDE_ACCOUNT_POOL} entries) and a tenant table (${#CLAUDE_TENANT_POOL} tenants)"
      echo "    The tenant table wins; CLAUDE_ACCOUNT_POOL is inert. Delete the flat pool so"
      echo "    there is one source of truth — a stale one reads as configuration that works."
    fi
  }

  _doctor_summary "Claude Code auth and MCP surface look healthy." \
    "Start with the ✗ items; 'claude-doctor --all' also lists the servers that are fine."
}
