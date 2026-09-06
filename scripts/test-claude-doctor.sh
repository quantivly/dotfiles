#!/usr/bin/env bash
#
# scripts/test-claude-doctor.sh
# =============================
#
# State table for `claude-doctor` in zsh/functions/claude.sh.
#
# Why this exists: every fault this doctor reports was, before it, reported by
# nothing at all. plugin:desktop-commander connected 0 times in 509 attempts
# across 34 days; the claude.ai Linear connector 404'd 1936 times; the
# plugin:slack:slack credential was twice caught mid-write with a zero-length
# accessToken. All three states look exactly like a quiet, healthy machine from
# every surface that existed at the time. So the rows here are written against
# the state that produces a GREEN TICK, not against an obvious error.
#
# HERMETIC, and deliberately so in one specific way: a `clauth` STUB is put at
# the front of PATH for every run that wants clauth present. Not "no clauth on
# PATH" — this box has a real one at ~/.local/bin/clauth wired to a running
# clauth-daemon.service that owns four live Claude accounts, and `clauth
# <profile>` REWRITES the machine's credentials. A suite that relied on clauth
# being absent would pass on a CI runner and switch a real account here. The
# same reasoning as the herdr stub in test-hspawn.sh and the systemctl stub in
# test-systemd-reconcile.sh.
#
# $HOME is a fixture throughout, so no row can read or write the real
# ~/.claude, ~/.clauth or ~/.cache/claude-cli-nodejs.
#
# Requires: zsh, bash, jq. No sudo, no network, no clauth, no Claude Code.
#
# Usage: scripts/test-claude-doctor.sh

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEMSH="$DOTFILES/zsh/functions/system.sh"
# Overridable so the fix can be reverted in a COPY of the file and the row that
# names it re-run against the mutant. A row that passes with the fix and without
# it pins nothing, however carefully it is worded — CLAUDE.md records the row in
# test-herdr-modular.sh that was decorative for exactly this reason.
#     CLAUDE_DOCTOR_SH=/tmp/mutant.sh scripts/test-claude-doctor.sh
CLAUDESH="${CLAUDE_DOCTOR_SH:-$DOTFILES/zsh/functions/claude.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Assert on the doctor's OUTPUT. `want_out` requires the substring, `no_out`
# forbids it — both are needed, because most of the bugs this file pins produce
# a report that is missing a line rather than one carrying a wrong line.
want_out() { if [[ "$OUT" == *"$2"* ]]; then ok "$1"; else bad "$1 — expected output to contain '$2'"; fi; }
no_out()   { if [[ "$OUT" != *"$2"* ]]; then ok "$1"; else bad "$1 — output must NOT contain '$2'"; fi; }
want_rc()  { if [[ "$RC" == "$2" ]]; then ok "$1"; else bad "$1 — expected exit $2, got $RC"; fi; }

for tool in zsh bash jq; do
    command -v "$tool" >/dev/null || fatal "$tool is required"
done
[[ -r "$SYSTEMSH" ]] || fatal "cannot read $SYSTEMSH"
[[ -r "$CLAUDESH" ]] || fatal "cannot read $CLAUDESH"

# Assert the functions under test are actually DEFINED before asserting on their
# behaviour. Most rows below are "this line does not appear", which is also
# exactly what a suite that loaded nothing produces.
for fn in claude-doctor _claude_cred_file _claude_now_ms _claude_fmt_delta _claude_mcp_log_root; do
    zsh -c "source '$SYSTEMSH' >/dev/null 2>&1; source '$CLAUDESH'; (( \$+functions[$fn] ))" \
        || fatal "$fn is not defined after sourcing $CLAUDESH — the suite would assert nothing"
done

STUBBIN="$TMPROOT/bin"; mkdir -p "$STUBBIN"
CLAUTH_LOG="$TMPROOT/clauth.log"

# A PATH built from scratch, holding exactly the binaries the doctor uses and
# nothing else. Two rows depend on this and cannot be written any other way:
#
#   - "clauth absent" must genuinely not find clauth. Inheriting $PATH finds the
#     REAL ~/.local/bin/clauth, and the row then passes or fails for reasons
#     having nothing to do with the code under test. That is not hypothetical:
#     it is how this suite behaved when first written, and it ran the real
#     binary. The header claims hermetic; this is what makes it true.
#   - "jq missing" must remove jq while keeping zsh reachable, so it cannot be
#     done by blanking PATH — env would fail to exec zsh and report 127, which
#     is a different failure wearing the same exit code.
SYSBIN="$TMPROOT/sysbin"; mkdir -p "$SYSBIN"
for t in zsh date stat grep sed sort uniq head tail cut tr wc ls sha256sum cat printf; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$SYSBIN/$t"
done
JQ_BIN="$(command -v jq)"
ln -sf "$JQ_BIN" "$SYSBIN/jq"
[[ -x "$SYSBIN/zsh" ]] || fatal "could not stage zsh into the fixture PATH"
# The same set minus jq, for the jq-missing row.
NOJQBIN="$TMPROOT/nojqbin"; mkdir -p "$NOJQBIN"
cp -a "$SYSBIN/." "$NOJQBIN/"; rm -f "$NOJQBIN/jq"

#-----------------------------------------------------------------------------
# The clauth stub
#-----------------------------------------------------------------------------
cat > "$STUBBIN/clauth" <<'STUB'
#!/bin/sh
# Fake `clauth` for scripts/test-claude-doctor.sh. Records every invocation and
# answers `which` from CLAUTH_STUB_WHICH. It never touches a credential, which
# is the entire point of stubbing it.
printf 'CMD %s\n' "$*" >> "$CLAUTH_STUB_LOG"
case "$1" in
    which) [ -n "${CLAUTH_STUB_WHICH:-}" ] && printf '%s\n' "$CLAUTH_STUB_WHICH"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUBBIN/clauth"

# A distinctive fake secret. Row "never prints a credential" asserts this string
# never reaches the report — the doctor's output goes into session transcripts,
# and CLAUDE.md records the audit that found both live GitHub tokens in five of
# them. A diagnostic that leaks is worse than no diagnostic.
FAKE_TOKEN="sk-ant-oat01-FAKEDOCTORCANARY0123456789"

NOW_MS=$(( $(date +%s) * 1000 ))
FUTURE=$(( NOW_MS + 3600000 ))     # +1h
PAST=$((   NOW_MS - 3600000 ))     # -1h

# Build a fresh fixture HOME. Every row calls this, so no row inherits another's
# state — a suite whose rows leak into each other reports the previous row's
# verdict for the current row's fixture.
new_home() {
    FHOME="$TMPROOT/home.$1"
    rm -rf "$FHOME"
    mkdir -p "$FHOME/.claude" "$FHOME/.cache/claude-cli-nodejs"
    CRED="$FHOME/.claude/.credentials.json"
}

# Write a credentials.json. $1 = jq filter applied to the healthy baseline, so a
# row states only its own deviation.
write_cred() {
    jq -n --arg tok "$FAKE_TOKEN" --argjson fut "$FUTURE" '{
      claudeAiOauth: {
        accessToken: $tok, refreshToken: ($tok + "-refresh"), expiresAt: $fut,
        scopes: ["user:inference","user:profile","user:mcp_servers"],
        subscriptionType: "team"
      },
      mcpOAuth: {
        "plugin:linear:linear|abc": {
          serverName: "plugin:linear:linear", serverUrl: "https://mcp.linear.app/mcp",
          accessToken: $tok, refreshToken: ($tok + "-r"), expiresAt: $fut, scope: "read"
        }
      }
    }' | jq "${1:-.}" > "$CRED"
    chmod 600 "$CRED"
}

# Create an MCP log dir with $2 successful and $3 failed connection records.
# The markers are the ones Claude Code actually writes, verified 2026-09-06
# against both a healthy remote server and a failing stdio one.
mk_logs() {
    local srv="$1" n_ok="${2:-0}" n_fail="${3:-0}" i d
    d="$FHOME/.cache/claude-cli-nodejs/-fixture/mcp-logs-$srv"
    mkdir -p "$d"
    for (( i = 0; i < n_ok; i++ )); do
        printf '{"debug":"Successfully connected (transport: http) in 42ms"}\n' \
            > "$d/$(date +%Y-%m-%d)T00-00-$(printf '%02d' "$i")-000Z.jsonl"
    done
    for (( i = 0; i < n_fail; i++ )); do
        printf '{"debug":"Connection failed after 30036ms: timed out"}\n' \
            > "$d/$(date +%Y-%m-%d)T01-00-$(printf '%02d' "$i")-000Z.jsonl"
    done
}

# Run the doctor against the current fixture. WITH_CLAUTH=1 puts the stub on
# PATH; NO_JQ=1 removes everything from PATH so `command -v jq` fails.
run_doctor() {
    local base="$SYSBIN" p
    [[ "${NO_JQ:-0}" == 1 ]] && base="$NOJQBIN"
    # The clauth stub is prepended ONLY when a row asks for it. Without it there
    # is no clauth anywhere on this PATH — see the SYSBIN note above.
    p="$base"
    [[ "${WITH_CLAUTH:-0}" == 1 ]] && p="$STUBBIN:$base"
    OUT="$(env -u CLAUDE_CONFIG_DIR HOME="$FHOME" \
              CLAUTH_STUB_LOG="$CLAUTH_LOG" CLAUTH_STUB_WHICH="${CLAUTH_STUB_WHICH:-}" \
              "PATH=$p" \
        "$SYSBIN/zsh" -c "source '$SYSTEMSH' >/dev/null 2>&1; source '$CLAUDESH'; claude-doctor $*" 2>&1)"
    RC=$?
}

echo "=== claude-doctor state table ==="

#-----------------------------------------------------------------------------
section "A. Preflight — a machine without Claude Code is not a broken machine"
#-----------------------------------------------------------------------------
# The permanently-red checker is this repo's most-repeated self-inflicted bug —
# CLAUDE.md records it three times (gh-doctor, backup-doctor, the herdr wiring).
# A doctor that fails on a machine with nothing to check is useless twice over.
new_home a1; rm -rf "$FHOME/.claude"
run_doctor
want_out "no ~/.claude reports skipped, not a failure" "○ skipped"
want_rc  "no ~/.claude exits 0"                        0

new_home a2; write_cred
NO_JQ=1 run_doctor; NO_JQ=0
want_out "jq missing is named, not silently skipped" "jq is not installed"
want_rc  "jq missing exits non-zero"                 1

#-----------------------------------------------------------------------------
section "B. The credential file"
#-----------------------------------------------------------------------------
new_home b1   # .claude exists, no credentials.json
run_doctor
want_out "absent credential file warns"        "not logged in"
want_rc  "absent credential file is not a ✗"   0

new_home b2; printf '{"claudeAiOauth": {' > "$CRED"; chmod 600 "$CRED"
run_doctor
# "Unparseable yields nothing, and nothing reads as no findings" is the exact
# shape of the install.conf.yaml and gh routing-table bugs in CLAUDE.md.
want_out "invalid JSON is its own state" "NOT VALID JSON"
want_rc  "invalid JSON fails"            1

new_home b3; write_cred; chmod 644 "$CRED"
run_doctor
want_out "wrong mode is a failure" "mode 644"

new_home b4; write_cred
run_doctor
want_out "healthy login reported"    "login present (plan: team"
want_out "connector coupling noted"  "claude.ai connectors ride on this login"

new_home b5; write_cred 'del(.claudeAiOauth.refreshToken)'
run_doctor
want_out "login with no refresh token fails" "NO refresh token"
want_rc  "login with no refresh token exits non-zero" 1

new_home b6; write_cred ".claudeAiOauth.expiresAt = $PAST"
run_doctor
want_out "expired access token warns" "access token EXPIRED"

new_home b7; write_cred '.claudeAiOauth.expiresAt = "soon"'
run_doctor
# A non-numeric expiresAt is what a torn write leaves behind; it must not be
# read as "no expiry information, therefore fine".
want_out "non-numeric expiresAt warns" "expiresAt is missing or non-numeric"

#-----------------------------------------------------------------------------
section "C. mcpOAuth shape — the fossils of a lost write race"
#-----------------------------------------------------------------------------
# Each of these was observed on the real machine on 2026-09-06 while the token
# had NOT expired. Checking freshness alone passes all of them.
new_home c1; write_cred '.mcpOAuth["plugin:linear:linear|abc"].accessToken = ""'
run_doctor
want_out "zero-length accessToken is a failure"      "accessToken is EMPTY"
want_out "and is named as a write race, not expiry"  "interleaved write"
want_rc  "zero-length accessToken exits non-zero"    1

new_home c2; write_cred 'del(.mcpOAuth["plugin:linear:linear|abc"].refreshToken)'
run_doctor
want_out "entry with no refreshToken is a failure" "no refreshToken"

new_home c3; write_cred 'del(.mcpOAuth["plugin:linear:linear|abc"].expiresAt)'
run_doctor
want_out "entry with no expiresAt warns" "expiresAt is missing or non-numeric"

new_home c4; write_cred ".mcpOAuth[\"plugin:linear:linear|abc\"].expiresAt = $PAST"
run_doctor
want_out "expired but refreshable entry warns, not fails" "token expired"

new_home c5; write_cred
run_doctor
want_out "healthy entry reported valid" "plugin:linear:linear: valid"

#-----------------------------------------------------------------------------
section "D. clauth — the third writer"
#-----------------------------------------------------------------------------
new_home d1; write_cred
run_doctor    # WITH_CLAUTH unset: clauth absent
want_out "clauth absent is a note, not a fault" "○ not installed"
no_out   "clauth absent adds no failure line"   "✗ clauth"

new_home d2; write_cred
mkdir -p "$FHOME/.clauth/profiles/p1"
jq '{claudeAiOauth}' "$CRED" > "$FHOME/.clauth/profiles/p1/credentials.json"
WITH_CLAUTH=1 CLAUTH_STUB_WHICH=p1 run_doctor
want_out "stored copy matching live is safe to switch" "switching away and back is safe"

new_home d3; write_cred
mkdir -p "$FHOME/.clauth/profiles/p1"
# The stored copy holds a SUPERSEDED token — exactly what Claude Code's refresh
# rotation leaves behind between clauth's ~90s polls. Restoring it is the one
# action that can log out every live session at once, so it must be reported
# BEFORE a switch, not diagnosed after one.
jq '{claudeAiOauth}' "$CRED" | jq '.claudeAiOauth.refreshToken = "stale-superseded"' \
    > "$FHOME/.clauth/profiles/p1/credentials.json"
WITH_CLAUTH=1 CLAUTH_STUB_WHICH=p1 run_doctor
want_out "stale stored copy is reported"        "DIFFERS from the live credential"
want_out "and says what switching would cost"   "log out every"

new_home d4; write_cred
mkdir -p "$FHOME/.clauth/profiles/p1"
printf 'fallback_chain = ["p1", "p2"]\n' > "$FHOME/.clauth/profiles.toml"
jq '{claudeAiOauth}' "$CRED" > "$FHOME/.clauth/profiles/p1/credentials.json"
WITH_CLAUTH=1 CLAUTH_STUB_WHICH=p1 run_doctor
want_out "armed auto-switch is surfaced" "auto-switch armed"

new_home d5; write_cred
WITH_CLAUTH=1 CLAUTH_STUB_WHICH= run_doctor
want_out "clauth answering nothing is NOT read as healthy" "could not determine the active profile"

#-----------------------------------------------------------------------------
section "E. MCP servers — read the log store, not the config"
#-----------------------------------------------------------------------------
new_home e1; write_cred; mk_logs "plugin-dead-dead" 0 6
run_doctor
# The desktop-commander row: 509 attempts, 0 successes, 34 days, and every
# surface green. Attempt COUNT is not health; only the success marker is.
want_out "a server that never connected is a failure" "0 successful connections"
want_rc  "never-connected server exits non-zero"      1

new_home e2; write_cred; mk_logs "plugin-flaky-flaky" 6 4
run_doctor
want_out "a mostly-failing server warns" "attempts failed"

new_home e3; write_cred; mk_logs "plugin-good-good" 6 0
run_doctor
no_out   "a healthy server is quiet by default" "plugin-good-good"
run_doctor --all
want_out "--all shows the healthy server too"   "plugin-good-good"

new_home e4; write_cred; rm -rf "$FHOME/.cache/claude-cli-nodejs"
run_doctor
# "An empty answer is never agreement" — CLAUDE.md, twice. No log store means
# unchecked, and must never render as a clean bill of health.
#
# Asserted on the SERVER section's own wording, not on the bare string
# "NOT CHECKED": the duplicated-services section below emits that phrase too, so
# a row matching it alone passes while the line it names has been replaced by a
# green tick. Mutation testing found exactly that — the row was decorative.
want_out "absent log store reports NOT CHECKED" "no MCP log store yet — NOT CHECKED"
no_out   "absent log store claims no successes" "0 successful connections"

#-----------------------------------------------------------------------------
section "F. Duplicated services"
#-----------------------------------------------------------------------------
new_home f1; write_cred
mk_logs "claude-ai-Linear" 3 0
mk_logs "plugin-linear-linear" 3 0
run_doctor
want_out "same service on two paths is reported" "Linear is reachable on BOTH"

new_home f2; write_cred; mk_logs "plugin-linear-linear" 3 0
run_doctor
no_out "a single path is not reported as duplicated" "reachable on BOTH"

# A log DIRECTORY is never deleted, so a connector removed at claude.ai leaves
# one behind forever. Keying the duplicate check on the directory reports that
# removal as an ongoing duplicate — a warning with no action behind it, which is
# how a checker stops being read. Found live, an hour after the check was
# written, on the connector this work had just had disconnected.
new_home f3; write_cred
mk_logs "plugin-linear-linear" 3 0
mkdir -p "$FHOME/.cache/claude-cli-nodejs/-fixture/mcp-logs-claude-ai-Linear"
printf '{"debug":"Successfully connected (transport: http) in 9ms"}\n' \
    > "$FHOME/.cache/claude-cli-nodejs/-fixture/mcp-logs-claude-ai-Linear/2020-01-01T00-00-00-000Z.jsonl"
run_doctor
no_out "a stale log dir outside the window is not a duplicate" "reachable on BOTH"

#-----------------------------------------------------------------------------
section "G. Conventions this repo has already been bitten by"
#-----------------------------------------------------------------------------
# The _doctor_* counters are locals by dynamic scope. A doctor that forgets to
# declare them silently restores the globals and inherits the PREVIOUS run's
# exit code — asserted here over the function itself, not a fixed list.
new_home g1; write_cred
OUT="$(env -u CLAUDE_CONFIG_DIR HOME="$FHOME" zsh -c "
    source '$SYSTEMSH' >/dev/null 2>&1; source '$CLAUDESH'
    typeset -g _DOCTOR_FAIL=999 _DOCTOR_WARN=999
    claude-doctor >/dev/null 2>&1
    print -r -- \"\$_DOCTOR_FAIL/\$_DOCTOR_WARN\"" 2>&1 | tail -1)"
if [[ "$OUT" == "999/999" ]]; then
    ok "counters are local — the caller's values survive a run"
else
    bad "counters leaked into the caller — expected '999/999', got '$OUT'"
fi

new_home g2; write_cred
run_doctor --days nonsense
want_rc "a non-numeric --days is refused, not silently defaulted" 2

new_home g3; write_cred
run_doctor --all
no_out "NEVER prints a credential value" "$FAKE_TOKEN"
new_home g4; write_cred '.mcpOAuth["plugin:linear:linear|abc"].accessToken = ""'
run_doctor --all
no_out "no credential value even on the failure paths" "$FAKE_TOKEN"

#-----------------------------------------------------------------------------
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
