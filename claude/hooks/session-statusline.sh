#!/bin/sh
# Custom statusLine command (~/.claude/settings.json "statusLine").
#
# statusLine's JSON stdin is the only documented, stable source for several
# per-session facts a dedicated agent dashboard would show: model, effort
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
#   idle_ok | idle_warn | idle_crit         "idle 12m"         (dim/yellow/red)
#
# idle_* (added 2026-08-30, eval F8) is now - mtime(transcript_path): Claude
# appends to the transcript on every turn and tool result, so its mtime is "last
# activity" — the same fact herdmates' quiet/stalled tiers read, and the
# thresholds match them (signal_engine.rs: quiet 5 min, stalled 10 min):
# < 5 min idle_ok, 5-9 idle_warn, >= 10 idle_crit; values "idle 2m", "idle 3h",
# "idle 2d" (<= 12 chars). Purpose: the sidebar showed identity and context
# pressure but no time dimension, herdmates' `stale` is a bare uncoloured word,
# and time is the cleanup cue — an idle_crit row is the one to reap. The visible
# line gets "| idle Nm" too, but only from 5 min, so an active session is not
# nagged.
#
# THIS BAND ONLY WORKS BECAUSE settings.json SETS refreshInterval. Claude Code
# re-runs the statusLine command on conversation events, debounced at 300 ms,
# and those events go quiet exactly when idle grows; `"refreshInterval": 60` in
# the statusLine entry re-runs it every 60 s regardless (docs:
# code.claude.com/docs/en/statusline, "event-driven triggers can go quiet when
# the main session is idle"). Without it the band would freeze at its last
# value and then every token here would expire with the 4-minute TTL below.
# INFERRED, not separately proven: that timer is also why mdl/eff/ctx survive
# for hours on idle panes today.
#
# macOS: the idle age comes from python's os.stat, which is portable — BSD
# `stat -f` and GNU `stat -c` disagree, which is why no `stat` binary is used.
# The remaining GNU-isms are `date +%s%N` and `timeout` (HERDR_GUIDE.md §10).
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
#   - 11 keys per call — mdl + 4 eff_* + 3 ctx_* + 3 idle_*, sets and clears
#     together (herdr's limit is 16 per report, 32 retained).
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

# One python3 call; prints 13 lines, each field on its own line:
#   1 mdl value  2 eff key  3 eff value  4 ctx key  5 ctx value
#   6 rl key     7 rl value 8 cost value 9 model    10 ctx pct  11 cwd
#   12 idle key  13 idle value
# New fields are APPENDED so the absolute `sed -n 'Np'` indices below stay valid.
# Reads defensively: any field may be missing or JSON null, and a total parse
# failure must still leave the status line printable.
read_fields() {
  printf '%s' "$input" | python3 -c '
import json, os, sys, time

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

# --- idle band -----------------------------------------------------------
# now - mtime(transcript_path). Defensive: the field may be missing, the file
# may not exist yet (no turn written), or the clock may sit behind the mtime
# (clamped to 0). Any failure means "no idle band", which clears all three
# tokens rather than leaving a stale one behind.
idle_key = ""
idle_val = ""
tp = d.get("transcript_path")
if isinstance(tp, str) and tp:
    try:
        secs = max(0, int(time.time() - os.stat(tp).st_mtime))
    except (OSError, ValueError, OverflowError):
        secs = None
    if secs is not None:
        mins = secs // 60
        if mins >= 1440:
            idle_val = "idle %dd" % (mins // 1440)
        elif mins >= 60:
            idle_val = "idle %dh" % (mins // 60)
        else:
            idle_val = "idle %dm" % mins
        idle_key = "idle_ok" if secs < 300 else ("idle_warn" if secs < 600 else "idle_crit")

for line in (mdl, eff_key, lvl, ctx_key, ctx_val, rl_key, rl_val, cost_val,
             model, ("" if cpct is None else str(cpct)), cwd, idle_key, idle_val):
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
# Line 6 is the rate-limit BAND key. It is intentionally not read: the rl_* tokens
# are no longer published to herdr (see the header), only rl_val is still printed in
# the visible status line. The python block keeps emitting it so these sed indices
# stay absolute and stable — do not renumber.
rl_val=$(printf '%s\n' "$fields" | sed -n '7p')
cost_val=$(printf '%s\n' "$fields" | sed -n '8p')
model=$(printf '%s\n' "$fields" | sed -n '9p')
pct=$(printf '%s\n' "$fields" | sed -n '10p')
cwd=$(printf '%s\n' "$fields" | sed -n '11p')
idle_key=$(printf '%s\n' "$fields" | sed -n '12p')
idle_val=$(printf '%s\n' "$fields" | sed -n '13p')

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
  for k in idle_ok idle_warn idle_crit; do
    if [ "$k" = "$idle_key" ]; then
      set -- "$@" --token "$k=$idle_val"
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
# Idle only from 5 min (idle_warn / idle_crit): an active session is not nagged.
case "$idle_key" in idle_warn|idle_crit) printf ' | %s' "$idle_val" ;; esac
[ -n "$rl_val" ] && printf ' | %s' "$rl_val"
[ -n "$cost_val" ] && printf ' | %s' "$cost_val"
[ -n "$cwd" ] && printf ' | %s' "$cwd"
printf '\n'

exit 0
