#!/bin/sh
# Publishes a per-agent glyph as the pane's `icon` metadata token, so a sidebar
# row can tell a codex pane from a gemini pane at a glance instead of reading
# the agent name.
#
# Runs from the pane.agent_detected hook only, which is why it takes the pane
# from the injected context rather than an argument.
set -u

herdr_bin="${HERDR_BIN_PATH:-herdr}"
pane="${HERDR_PANE_ID:-}"

# An event with no pane is not something this plugin can answer for.
[ -n "$pane" ] || exit 0

# The pane.agent_detected payload carries the detected kind as `agent`. Parsed
# with sed rather than jq: a hook runs on every agent detection, and this plugin
# has no business requiring a JSON parser be installed for one string.
agent=$(printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-}" | sed -n 's/.*"agent":"\([^"]*\)".*/\1/p')

# An unrecognized agent still gets a mark (`*` below) — herdr detects some two
# dozen kinds and a generic dot beats an empty slot. An *unparsed* one does not:
# publishing the generic glyph there would assert something we never read.
[ -n "$agent" ] || exit 0

case "$agent" in
    claude)  icon='✻' ;;
    codex)   icon='❖' ;;
    gemini)  icon='✦' ;;
    agy)     icon='✜' ;;
    # The brief's copilot glyph did not survive being written down (the arrow
    # had nothing after it), so this is a stand-in chosen to sit in the same
    # geometric family as cursor's without being confusable with it. One line
    # to change if you had another in mind.
    copilot) icon='◈' ;;
    cursor)  icon='◇' ;;
    *)       icon='•' ;;
esac

# The pane id goes BEFORE the flags. `report-metadata --help` prints it last,
# and that order answers `unknown option: <value>` at exit 2 on 0.8.x. Named
# flags may sit in any order; only the positional-first order is load-bearing.
# (Same trap clauth's report-profile.sh documents.)
#
# No --ttl-ms: which agent occupies a pane does not decay, and the token is
# already dropped when the server restarts.
"$herdr_bin" pane report-metadata "$pane" \
    --source "${HERDR_PLUGIN_ID:-sidebar-icons}" \
    --token "icon=$icon"
