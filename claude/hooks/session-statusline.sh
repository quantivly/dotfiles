#!/bin/sh
# Custom statusLine command (~/.claude/settings.json "statusLine").
#
# statusLine's JSON stdin is the only documented, stable source for several
# per-session facts Atrium used to show in its own dashboard: model, effort
# level, context-window usage, rate-limit usage, and running API cost. Hooks
# carry none of this; the transcript JSONL format is explicitly undocumented/
# unstable across versions. Confirmed live-reloaded — no restart needed for
# edits here to take effect in an already-running session.
#
# Publishes them as herdr sidebar metadata via `herdr pane report-metadata`
# (source id "claude-context") when running in a herdr pane, and also prints
# a real status line so this doubles as Claude Code's own visible status text.
#
# herdr has no per-value styling: token *values* are plain text and the only
# style knobs are per-token-slot (`{ token = "$x", fg, bold, dim }` in
# ui.sidebar.agents.rows*). So colour is expressed by publishing mutually
# exclusive *band* tokens and clearing the siblings:
#
#   mdl                                     "✻ Fable 5 1M"     (brand colour)
#   eff_lo | eff_high | eff_xhigh | eff_max "xhigh"            (dim/blue/orange/red)
#   ctx_ok | ctx_warn | ctx_crit            "▅ 62%"            (green/yellow/red)
#
# NOT published to herdr (removed 2026-08-30): rate limits and session cost.
# The clauth daemon already rotates accounts automatically at its thresholds, so
# the rate-limit bands explained why a rotation had happened rather than prompting
# any action, and every published token is a silent-failure surface. Both are still
# computed below and printed in the VISIBLE status line, in the pane where you are
# already looking — that costs nothing extra, since this script runs either way as
# Claude Code's own statusLine command. Any rl_*/cost tokens left on a pane from a
# previous version expire on their own within the 4-minute TTL.
#
# Invariants that shape the code below:
#   - ONE report-metadata call per tick (sets and clears together). Claude Code
#     cancels an in-flight statusLine when a newer update arrives, so a second
#     call could be killed and leave half-updated bands.
#   - --seq $(date +%s%N) so a cancelled run's straggler cannot overwrite a
#     newer report; --ttl-ms 240000 so bands self-clear when Claude exits but
#     the pane lives on (tokens are never cleared on process exit).
#   - timeout 2 … || true: the CLI has no socket timeout, and a wedged herdr
#     must never wedge the status line.
#   - <= 8 keys per call (herdr's limit is 16 per report, 32 retained).
#   - Token names are global per pane, last writer wins across sources:
#     herdmates publishes `model` on team-lead panes, so ours is `mdl`.
#     `context`/`effort` are deliberately no longer published (legacy names).
#   - No U+00B7 "·" inside a value — it is indistinguishable from herdr's own
#     token separator.
#
# NOT permission mode: statusLine's JSON has no field for it (checked the
# full live schema). It IS visible directly in-pane (Claude Code's own
# "auto mode on" / "plan mode" indicator), just not exposed to herdr's
# sidebar by any documented mechanism.
#
# NOT installed under ~/.claude/hooks/herdr-agent-state.sh — that file is
# owned/overwritten by `herdr integration install claude`. This one is ours.

set -eu

input="$(cat)"

# One python3 call; prints 11 lines, each field on its own line:
#   1 mdl value  2 eff key  3 eff value  4 ctx key  5 ctx value
#   6 rl key     7 rl value 8 cost value 9 model    10 ctx pct  11 cwd
# Reads defensively: any field may be missing or JSON null, and a total parse
# failure must still leave the status line printable.
read_fields() {
  printf '%s' "$input" | python3 -c '
import json, sys

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}

def dsub(parent, key):
    v = parent.get(key)
    return v if isinstance(v, dict) else {}

def sub(key):
    return dsub(d, key)

def num(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return v

def pct(v):
    n = num(v)
    return None if n is None else int(round(n))

def oneline(s):
    return "".join(" " if (ord(c) < 32 or ord(c) == 127) else c for c in str(s))

def clean(s):
    s = "".join(" " if (ord(c) < 32 or ord(c) == 127 or c == "·") else c for c in str(s))
    return " ".join(s.split())[:80]

# --- model ---------------------------------------------------------------
model = sub("model").get("display_name")
model = model if isinstance(model, str) and model.strip() else "claude"
model = model.replace(" (1M context)", "").strip()

cw = sub("context_window")
size = num(cw.get("context_window_size"))
suffix = ""
if size is not None:
    n = int(size)
    if n == 1000000:
        suffix = "1M"
    elif n == 200000:
        suffix = "200k"
    elif n >= 1000000 and n % 1000000 == 0:
        suffix = str(n // 1000000) + "M"
    elif n >= 1000:
        suffix = str(n // 1000) + "k"
    elif n > 0:
        suffix = str(n)
mdl = clean("✻ " + model + ((" " + suffix) if suffix else ""))

# --- effort band ---------------------------------------------------------
lvl = sub("effort").get("level")
lvl = clean(lvl) if isinstance(lvl, str) else ""
eff_key = ""
if lvl:
    eff_key = {"high": "eff_high", "xhigh": "eff_xhigh", "max": "eff_max"}.get(lvl.lower(), "eff_lo")

# --- context band --------------------------------------------------------
cpct = pct(cw.get("used_percentage"))
ctx_key = ""
ctx_val = ""
if cpct is not None:
    ramp = "▁▂▃▄▅▆▇█"
    ctx_val = ramp[max(0, min(7, cpct * 8 // 100))] + " " + str(cpct) + "%"
    ctx_key = "ctx_ok" if cpct < 75 else ("ctx_warn" if cpct < 90 else "ctx_crit")

# --- rate-limit band -----------------------------------------------------
rlim = sub("rate_limits")
h5 = pct(dsub(rlim, "five_hour").get("used_percentage"))
d7 = pct(dsub(rlim, "seven_day").get("used_percentage"))
rl_key = ""
rl_val = ""
parts = []
if h5 is not None:
    parts.append("5h " + str(h5) + "%")
if d7 is not None:
    parts.append("7d " + str(d7) + "%")
if parts:
    rl_val = " ".join(parts)
    worst = max(x for x in (h5, d7) if x is not None)
    rl_key = "rl_ok" if worst < 80 else ("rl_warn" if worst < 95 else "rl_crit")

# --- cost ----------------------------------------------------------------
cost = num(sub("cost").get("total_cost_usd"))
cost_val = ("$%.2f" % cost) if cost is not None else ""

cwd = sub("workspace").get("current_dir")
cwd = cwd if isinstance(cwd, str) else ""

for line in (mdl, eff_key, lvl, ctx_key, ctx_val, rl_key, rl_val, cost_val,
             model, ("" if cpct is None else str(cpct)), cwd):
    print(oneline(line))
'
}

fields=""
if ! fields="$(read_fields 2>/dev/null)"; then
  fields=""
fi

mdl=$(printf '%s\n' "$fields" | sed -n '1p')
eff_key=$(printf '%s\n' "$fields" | sed -n '2p')
eff_val=$(printf '%s\n' "$fields" | sed -n '3p')
ctx_key=$(printf '%s\n' "$fields" | sed -n '4p')
ctx_val=$(printf '%s\n' "$fields" | sed -n '5p')
rl_key=$(printf '%s\n' "$fields" | sed -n '6p')
rl_val=$(printf '%s\n' "$fields" | sed -n '7p')
cost_val=$(printf '%s\n' "$fields" | sed -n '8p')
model=$(printf '%s\n' "$fields" | sed -n '9p')
pct=$(printf '%s\n' "$fields" | sed -n '10p')
cwd=$(printf '%s\n' "$fields" | sed -n '11p')

# `mdl` is non-empty whenever python succeeded (model falls back to "claude"),
# so an empty one means "no data" — publish nothing rather than clearing bands.
if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ] \
   && [ -n "${HERDR_SOCKET_PATH:-}" ] && [ -n "$mdl" ]; then
  set -- report-metadata "$HERDR_PANE_ID" --source claude-context \
         --seq "$(date +%s%N)" --ttl-ms 240000 --token "mdl=$mdl"
  for k in eff_lo eff_high eff_xhigh eff_max; do
    if [ "$k" = "$eff_key" ]; then
      set -- "$@" --token "$k=$eff_val"
    else
      set -- "$@" --clear-token "$k"
    fi
  done
  for k in ctx_ok ctx_warn ctx_crit; do
    if [ "$k" = "$ctx_key" ]; then
      set -- "$@" --token "$k=$ctx_val"
    else
      set -- "$@" --clear-token "$k"
    fi
  done
  timeout 2 herdr pane "$@" >/dev/null 2>>"$HOME/.cache/statusline-herdr.err" || true
fi

# Visible status line text (this command's stdout).
printf '%s' "${model:-claude}"
[ -n "$eff_val" ] && printf ' (%s)' "$eff_val"
[ -n "$pct" ] && printf ' | ctx %s%%' "$pct"
[ -n "$rl_val" ] && printf ' | %s' "$rl_val"
[ -n "$cost_val" ] && printf ' | %s' "$cost_val"
[ -n "$cwd" ] && printf ' | %s' "$cwd"
printf '\n'

exit 0
