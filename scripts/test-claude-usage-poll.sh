#!/usr/bin/env bash
#
# scripts/test-claude-usage-poll.sh — hermetic state table for scripts/claude-usage-poll.
#
# A stub HTTP server on 127.0.0.1 answers by bearer token: `fake-ok` → 200 JSON,
# `fake-401` → 401, `fake-429` → 429 + Retry-After, `fake-bad` → 200 non-JSON.
# Every credential here is a fixture with a made-up token; the canary row at the
# end asserts none of those strings reached stdout, stderr or any file the poller
# wrote. "Could not run" is exit 2, never a pass, and the suite asserts its own
# row total (scripts/check-state-table-totals.sh).
set -u
DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$DOTFILES/scripts/claude-usage-poll"
for t in python3 jq curl; do command -v "$t" >/dev/null 2>&1 || { echo "test-claude-usage-poll: $t missing — could not run" >&2; exit 2; }; done
[[ -x "$SUT" ]] || { echo "test-claude-usage-poll: $SUT not executable — could not run" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[0;32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[1;31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }

TMPROOT="$(mktemp -d)"; chmod 700 "$TMPROOT"
trap 'kill "$STUB_PID" 2>/dev/null; rm -rf "$TMPROOT"' EXIT
ROOT="$TMPROOT/dirs"; mkdir -p "$ROOT"
STUB_LOG="$TMPROOT/stub.log"; PORTFILE="$TMPROOT/port"; : > "$STUB_LOG"

cat > "$TMPROOT/stub.py" <<'PY'
import http.server, json, sys
LOG, PORTFILE = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _log(self, verb):
        tok = self.headers.get('Authorization', '').replace('Bearer ', '')
        with open(LOG, 'a') as f:
            f.write(f"{verb} {tok} ua={self.headers.get('User-Agent','')} beta={self.headers.get('anthropic-beta','')}\n")
        return tok
    def do_GET(self):
        tok = self._log('GET')
        if tok == 'fake-ok':
            body = json.dumps({"five_hour": {"utilization": 12.5, "resets_at": "2026-10-01T00:00:00Z"},
                               "seven_day": {"utilization": 40.0, "resets_at": "2026-10-03T00:00:00Z"}}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(body)
        elif tok == 'fake-401':
            self.send_response(401); self.end_headers(); self.wfile.write(b'{"error":"unauthorized"}')
        elif tok == 'fake-429':
            self.send_response(429); self.send_header('Retry-After', '7'); self.end_headers(); self.wfile.write(b'{}')
        elif tok == 'fake-bad':
            self.send_response(200); self.end_headers(); self.wfile.write(b'not json')
        else:
            self.send_response(404); self.end_headers()
    def do_POST(self):
        self._log('POST'); self.send_response(405); self.end_headers()
srv = http.server.HTTPServer(('127.0.0.1', 0), H)
open(PORTFILE, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$TMPROOT/stub.py" "$STUB_LOG" "$PORTFILE" & STUB_PID=$!
for _ in $(seq 1 50); do [[ -s "$PORTFILE" ]] && break; sleep 0.1; done
[[ -s "$PORTFILE" ]] || { echo "stub server did not start — could not run" >&2; exit 2; }
URL="http://127.0.0.1:$(cat "$PORTFILE")/usage"

# seed NAME TOKEN EXPIRES_MS — a fixture credential with a made-up token.
future=$(( ($(date +%s) + 3600) * 1000 )); past=$(( ($(date +%s) - 3600) * 1000 ))
seed() { mkdir -p "$ROOT/$1"; printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"%s-r","expiresAt":%s,"scopes":["user:inference"],"subscriptionType":"max"}}\n' "$2" "$2" "$3" > "$ROOT/$1/.credentials.json"; chmod 600 "$ROOT/$1/.credentials.json"; }
seed ok      fake-ok  "$future"
seed denied  fake-401 "$future"
seed limited fake-429 "$future"
seed garbled fake-bad "$future"
seed expired fake-exp "$past"
mkdir -p "$ROOT/stub"; printf '{"claudeAiOauth":{"accessToken":"","scopes":[]}}\n' > "$ROOT/stub/.credentials.json"; chmod 600 "$ROOT/stub/.credentials.json"
ln -s "$ROOT/ok" "$ROOT/alias"
mkdir -p "$ROOT/nocred"
hits() { grep -c -- "GET $1 " "$STUB_LOG" || true; }
state() { jq -r '.state // "none"' "$ROOT/$1/usage.json" 2>/dev/null || echo none; }
reason() { jq -r '.reason // ""' "$ROOT/$1/usage.json" 2>/dev/null; }

echo "=== could not run is exit 2 ==="
OUT="$("$SUT" --root "$TMPROOT/nowhere" --url "$URL" 2>&1)"; RC=$?
check "an unreadable root exits 2"                                      "$RC" "2"
check "...and says could not run"                                       "$(grep -c 'could not run' <<<"$OUT")" "1"

echo "=== dry run writes and sends nothing ==="
OUT="$("$SUT" --root "$ROOT" --url "$URL" --dry-run 2>&1)"; RC=$?
check "dry-run exits 0"                                                 "$RC" "0"
check "dry-run names the GET it would make"                             "$(grep -c 'ok: would GET' <<<"$OUT")" "1"
check "dry-run wrote no usage.json"                                     "$(find "$ROOT" -name usage.json | wc -l)" "0"
check "dry-run sent no request"                                         "$(wc -l < "$STUB_LOG")" "0"

echo "=== one live run ==="
OUT="$("$SUT" --root "$ROOT" --url "$URL" 2>&1)"; RC=$?
check "a full run exits 0 whatever the states"                          "$RC" "0"
check "200: state ok"                                                   "$(state ok)" "ok"
check "200: the raw reply is kept (five_hour.utilization)"              "$(jq -r '.five_hour.utilization' "$ROOT/ok/usage.json")" "12.5"
check "200: fetched_at is epoch ms"                                     "$(jq -r '.fetched_at | tostring | test("^[0-9]{13}$")' "$ROOT/ok/usage.json")" "true"
check "200: usage.json is 0600"                                         "$(stat -c '%a' "$ROOT/ok/usage.json")" "600"
check "200: no temp file left beside it"                                "$(find "$ROOT/ok" -name '.usage.json.*' | wc -l)" "0"
check "the request carries Claude Code's User-Agent"                    "$(grep -c 'GET fake-ok ua=claude-cli' "$STUB_LOG")" "1"
check "...and the oauth beta header"                                    "$(grep -c 'GET fake-ok .*beta=oauth-2025-04-20' "$STUB_LOG")" "1"
check "401: state unknown"                                              "$(state denied)" "unknown"
check "401: the reason names it"                                        "$(reason denied | grep -c '401')" "1"
check "401: exactly one request, no refresh POST"                       "$(hits fake-401)/$(grep -c '^POST' "$STUB_LOG" || true)" "1/0"
check "429: state unknown"                                              "$(state limited)" "unknown"
# Guarded read: a MISSING sidecar must fail this row, not skip it (a mutant that
# never wrote the file made the bare arithmetic error out and the row vanish).
sidecar_future() { [[ -r "$ROOT/limited/.usage.retry-after" ]] || { echo absent; return; }; (( $(tr -dc '0-9' < "$ROOT/limited/.usage.retry-after") > $(date +%s)000 )) && echo future || echo past; }
check "429: retry-after sidecar written with a future instant"          "$(sidecar_future)" "future"
check "malformed 200: state unknown"                                    "$(state garbled)" "unknown"
check "malformed 200: the reason says so"                               "$(reason garbled | grep -c 'not a JSON object')" "1"
check "expired token: state unknown"                                    "$(state expired)" "unknown"
check "expired token: NO request was made (never refreshed)"            "$(hits fake-exp)" "0"
check "discovery stub (no expiresAt): state unknown"                    "$(state stub)" "unknown"
check "alias symlink: skipped, not polled twice"                        "$(grep -c '^alias: skipped (alias -> ok)' <<<"$OUT")/$(hits fake-ok)" "1/1"
check "a dir with no credential is skipped"                             "$(grep -c '^nocred: skipped' <<<"$OUT")" "1"

echo "=== a second run honours the 429 sidecar ==="
OUT="$("$SUT" --root "$ROOT" --url "$URL" 2>&1)"
check "rate-limited profile is skipped while retry-after stands"        "$(grep -c '^limited: skipped (rate-limited' <<<"$OUT")" "1"
check "...so the server saw it once"                                    "$(hits fake-429)" "1"
check "the others were polled again"                                    "$(hits fake-ok)" "2"

echo "=== no response ==="
OUT="$("$SUT" --root "$ROOT" --url "http://127.0.0.1:1/closed" 2>&1)"
check "a refused connection is unknown, not a crash"                    "$(state ok)/$(reason ok | grep -c 'no response')" "unknown/1"

echo "=== canary: no token in any output or written file ==="
leak=0
for tok in fake-ok fake-401 fake-429 fake-bad fake-exp; do
  grep -rq -- "$tok" "$ROOT"/*/usage.json "$ROOT"/*/.usage.retry-after 2>/dev/null && leak=$((leak + 1))
done
check "no fixture token in any file the poller wrote"                   "$leak" "0"
check "no fixture token in the poller's output"                         "$(grep -c -E 'fake-(ok|401|429|bad|exp)' <<<"$OUT")" "0"

# --- the row total, and the count this suite is documented as running --------
EXPECTED_ROWS=34
docs_claim() {
  local f="$DOTFILES/$1"
  [[ -r "$f" ]] || { printf 'cannot read %s' "$1"; return; }
  tr -s '[:space:]' ' ' <"$f" | grep -c -F "\`scripts/test-claude-usage-poll.sh\` ($EXPECTED_ROWS checks"
}
printf '\nthe count this suite is documented as running\n'
check "docs/CLAUDE_ACCOUNT_PICKER.md says $EXPECTED_ROWS checks" "$(docs_claim docs/CLAUDE_ACCOUNT_PICKER.md)" 1
check "a documented file that cannot be read is not a pass" "$(docs_claim no/such/file.md)" "cannot read no/such/file.md"

if (( PASS + FAIL != EXPECTED_ROWS )); then
  printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' "$EXPECTED_ROWS" "$((PASS + FAIL))"
  FAIL=$((FAIL + 1))
fi
echo; echo "=== $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
