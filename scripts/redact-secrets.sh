#!/usr/bin/env bash
#
# scripts/redact-secrets.sh
# =========================
#
# Filter: stdin -> stdout, with credential-shaped strings replaced.
#
# Why this exists: on 2026-09-01 an audit found BOTH of this machine's live
# GitHub tokens sitting in plaintext in five Claude Code session transcripts,
# two of them written days earlier. Transcripts are conversation context, so the
# values had also left the host. Nothing had gone wrong in an interesting way —
# ordinary diagnostic commands (`ps` showing a process started with
# `-e GH_TOKEN=…`, a `printf` of `$GH_TOKEN`, a bare `gh auth token`) print
# secrets, and everything printed is recorded.
#
# Rotation is the wrong loop to optimise: it is manual, it is browser-only for
# GitHub (no CLI, no API — the OAuth Authorizations API was removed in 2020),
# and it does nothing about the next capture. This filter plus
# claude/hooks/secret-emission-guard.sh attacks the emission instead.
#
# DESIGN: fail OPEN on content, never on the pipeline. A redactor that swallows
# output, reorders it, or exits non-zero would get removed from commands within
# a day, and then it protects nothing. It streams, preserves exit status via
# PIPESTATUS in the caller, and only ever substitutes.
#
# TWO RULES, because either alone leaks. Shape matching (gho_…, sk-ant-…) finds
# a credential wherever it appears, including bare in prose — but it cannot know
# that CLAUDE_CODE_MESSAGING_TOKEN=b7dc… is a secret, since 32 hex characters is
# also every short git SHA and every md5. Name matching (…TOKEN=, …SECRET=)
# catches those in the `VAR=value` shapes an env dump produces, without
# false-positiving on arbitrary hex. Neither is sufficient; the gap was found by
# running the pair against a real `printenv` and noticing what survived.
#
# It is deliberately NOT a general secret scanner. `gitleaks` already runs in
# pre-commit for the repository; this covers the credential shapes that actually
# reach a terminal here, and matches on shape alone so it needs no wordlist and
# cannot leak by failing to know a variable name.
#
# Usage:  <command that may print a secret> 2>&1 | redact-secrets
#         redact-secrets < file
#
# Exit status is sed's. Input is passed through unchanged on any pattern miss.

set -uo pipefail

# One sed program. Ordered longest/most-specific first so a broader pattern
# cannot eat half of a narrower one's match.
exec sed -E \
  -e 's/gh[pousr]_[A-Za-z0-9]{30,}/<REDACTED:github-token>/g' \
  -e 's/github_pat_[A-Za-z0-9_]{20,}/<REDACTED:github-pat>/g' \
  -e 's/sk-ant-[A-Za-z0-9_-]{20,}/<REDACTED:anthropic-key>/g' \
  -e 's/xox[baprse]-[A-Za-z0-9-]{10,}/<REDACTED:slack-token>/g' \
  -e 's/AKIA[0-9A-Z]{16}/<REDACTED:aws-access-key-id>/g' \
  -e 's/ASIA[0-9A-Z]{16}/<REDACTED:aws-temp-key-id>/g' \
  -e 's/(aws_secret_access_key[[:space:]]*=[[:space:]]*)[A-Za-z0-9\/+=]{30,}/\1<REDACTED:aws-secret>/g' \
  -e 's/glpat-[A-Za-z0-9_-]{20,}/<REDACTED:gitlab-pat>/g' \
  -e 's/([Bb]earer[[:space:]]+)[A-Za-z0-9._~+\/-]{20,}=*/\1<REDACTED:bearer>/g' \
  -e 's/(-----BEGIN [A-Z ]*PRIVATE KEY-----).*/\1<REDACTED:private-key>/g' \
  -e 's/(https?:\/\/[^:@[:space:]\/]+):[^@[:space:]\/]+@/\1:<REDACTED:url-password>@/g' \
  -e 's/((^|[[:space:]])[A-Z][A-Z0-9_]*(TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|CREDENTIAL)[A-Z0-9_]*=)[^[:space:]]+/\1<REDACTED:by-name>/g'
