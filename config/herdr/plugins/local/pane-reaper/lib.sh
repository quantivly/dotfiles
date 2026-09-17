# shellcheck shell=sh
#
# Shared by on-status-changed.sh (the hook) and recheck.sh (the timer).
# Callers set PR_ROOT before sourcing. Design and every gate:
# ~/Projects/handoffs/2026-09-17-pane-reaper-design.md, mirrored in
# docs/HERDR_GUIDE.md.

PR_HERDR="${HERDR_BIN_PATH:-herdr}"
PR_DEFAULT_MIN=5

# Per-user and never world-writable: a runtime dir if the session has one,
# otherwise the user's state dir. Not /tmp, where another user could pre-create
# the path.
pr_slot_dir() {
    if [ -n "${PANE_REAPER_SLOT_DIR:-}" ]; then
        printf '%s\n' "$PANE_REAPER_SLOT_DIR"
    elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        printf '%s\n' "$XDG_RUNTIME_DIR/pane-reaper"
    else
        printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/pane-reaper/slots"
    fi
}

pr_slot_file() {
    printf '%s/%s\n' "$(pr_slot_dir)" "$(printf '%s' "$1" | tr ':/' '__')"
}

# One slot per pane: "<terminal_id>:<seq> <nonce> <epoch>", the epoch being
# when the pane was first armed (pr_slot_write <pane> <gen> <nonce> [epoch];
# now when omitted). Written atomically, because hook invocations run
# concurrently and a timer reads it on wake.
pr_slot_write() {
    _dir=$(pr_slot_dir)
    _f=$(pr_slot_file "$1")
    mkdir -p "$_dir" 2>/dev/null && chmod 700 "$_dir" 2>/dev/null
    # Grouped so a failed `>` open (unwritable slot dir) is silenced too: that
    # redirect failure is reported before this command's own `2>/dev/null`
    # would otherwise apply, and would leak the shell's diagnostic to stderr.
    { printf '%s %s %s\n' "$2" "$3" "${4:-$(date +%s)}" > "$_f.tmp.$$" && mv -f "$_f.tmp.$$" "$_f"; } 2>/dev/null
}

pr_slot_gen() {
    _f=$(pr_slot_file "$1")
    [ -f "$_f" ] && cut -d' ' -f1 < "$_f"
}

pr_slot_nonce() {
    _f=$(pr_slot_file "$1")
    [ -f "$_f" ] && cut -d' ' -f2 < "$_f"
}

# pr_slot_epoch <pane>: the slot's arm time, normalized for `$(( ))`, or 0 when
# it can't be trusted: no slot, a slot written before arm times existed, the
# failed-clear "disarmed" marker, or anything but 1-12 digits. pr_uint caps at 4
# digits, so an epoch gets its own check; leading zeros are stripped for the
# same octal reason.
pr_slot_epoch() {
    _f=$(pr_slot_file "$1")
    _g='' _n='' _e=''
    # Grouped so a failed `<` open (slot removed meanwhile) is silenced too.
    [ -f "$_f" ] && { read -r _g _n _e < "$_f"; } 2>/dev/null
    case "$_g" in disarmed) _e='' ;; esac
    case "$_e" in
        ''|*[!0-9]*) printf '0\n'; return 0 ;;
    esac
    [ "${#_e}" -le 12 ] || { printf '0\n'; return 0; }
    _e=$(printf '%s' "$_e" | sed 's/^0*//')
    printf '%s\n' "${_e:-0}"
}

# pr_epoch_age <epoch>: seconds since <epoch> (a pr_slot_epoch value). An
# untrusted (0) or future epoch, or an unreadable clock, reads as long ago: the
# pre-flap behaviour, which treats any state change as a new turn.
pr_epoch_age() {
    _now=$(date +%s)
    case "$_now" in ''|*[!0-9]*) printf '999999\n'; return 0 ;; esac
    if [ "$1" -eq 0 ] || [ "$1" -gt "$_now" ]; then
        printf '999999\n'
    else
        printf '%s\n' "$((_now - $1))"
    fi
}

pr_slot_age() {
    pr_epoch_age "$(pr_slot_epoch "$1")"
}

pr_log() {
    _d="${XDG_STATE_HOME:-$HOME/.local/state}/pane-reaper"
    mkdir -p "$_d" 2>/dev/null || return 0
    # Grouped for the same reason as in pr_slot_write: a failed `>>` open is
    # reported before a trailing `2>/dev/null` would apply.
    { printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$_d/log"; } 2>/dev/null || :
}

# pr_disarm <pane>: cancel an armed pane that started a new turn. The token is
# cleared BEFORE the slot is dropped: a failed clear must not lose the slot, or
# the next done/idle would re-arm from the stale `ready` token. A failed clear
# marks the slot "disarmed" instead. That can never equal a real
# "<terminal_id>:<seq>" generation, so the arm path refuses it, and the next
# working/blocked event retries the clear. Fails safe: a pane whose clear keeps
# failing is never reaped.
pr_disarm() {
    if _out=$("$PR_HERDR" pane report-metadata "$1" --source pane-reaper \
            --clear-token pane_reaper 2>&1); then
        rm -f "$(pr_slot_file "$1")" 2>/dev/null
        pr_log "$1" "disarmed:new-turn"
    else
        _code=$(pr_field "$_out" '.error.code')
        pr_slot_write "$1" disarmed "$(pr_nonce)"
        pr_log "$1" "disarm-failed:${_code:-unknown}"
    fi
}

pr_agent_json() {
    "$PR_HERDR" agent get "$1" 2>/dev/null
}

# pr_field <json> <jq path>: the value, or nothing. `// empty` also blanks a
# JSON false, so compare booleans against "true" only.
pr_field() {
    printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null
}

# pr_uint <raw> <default>: <raw> normalized to a decimal literal safe for `$(( ))`
# when it is 1-4 decimal digits (leading zeros stripped: "08" -> "8", "00" ->
# "0"), otherwise <default> verbatim. A leading-zero numeral left unstripped
# makes dash's arithmetic parser read it as octal and abort on an invalid digit
# (e.g. "08"), which would crash the caller before it could log anything.
pr_uint() {
    case "$1" in
        [0-9]|[0-9][0-9]|[0-9][0-9][0-9]|[0-9][0-9][0-9][0-9])
            _v=$(printf '%s' "$1" | sed 's/^0*//')
            printf '%s\n' "${_v:-0}"
            ;;
        *) printf '%s\n' "$2" ;;
    esac
}

# An agent can flap right after it finishes (live: done, working +0.3 s, done
# +0.9 s, all in one turn). A state change within this many seconds of arming
# is the agent settling, not a new turn.
# shellcheck disable=SC2034 # read by on-status-changed.sh, which sources this
PR_FLAP_SECONDS=$(pr_uint "${PANE_REAPER_FLAP_SECONDS:-10}" 10)

# Token values are arbitrary strings: only a short all-digit value is a grace.
pr_minutes() {
    pr_uint "$1" "$PR_DEFAULT_MIN"
}

pr_nonce() {
    printf '%s-%s-%s\n' "$$" "$(date +%s)" "$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
}

pr_ps() {
    if [ -n "${PANE_REAPER_PS_FILE:-}" ]; then
        cat "$PANE_REAPER_PS_FILE"
    else
        ps -e -o pid= -o ppid= -o args=
    fi
}

# True ("busy") when any descendant of the pane's foreground processes is a
# Claude Code Bash-tool shell: every Bash call, background ones included, runs
# as `zsh -c source …/shell-snapshots/snapshot-…`. MCP servers never match.
# Only a clean "no" (awk exit 1) is free. Everything else answers busy: herdr
# cannot say what runs in the pane, it lists no foreground process, the process
# table source fails, or awk fails (exit 2+). A re-arm is cheap and a wrong
# close is not. The roots go to awk as ONE space-separated line: BWK awk
# (macOS) rejects a newline in `-v`.
pr_has_bash_children() {
    _info=$("$PR_HERDR" pane process-info --pane "$1" 2>/dev/null) || return 0
    _roots=$(printf '%s' "$_info" | jq -r '.result.process_info.foreground_processes[]?.pid' 2>/dev/null) || return 0
    _roots=$(printf '%s' "$_roots" | tr '\n' ' ')
    case "$_roots" in *[!\ ]*) ;; *) return 0 ;; esac
    # Captured before awk runs: a bare `pr_ps | awk …` pipe reports awk's exit
    # status, not pr_ps's, so a failed process table (e.g. `ps` unavailable)
    # would hand awk an empty stdin, which reads as a clean "no" and frees the
    # pane instead of re-arming it.
    _table=$(pr_ps 2>/dev/null) || return 0
    printf '%s\n' "$_table" | awk -v roots="$_roots" '
        BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) root[r[i]] = 1 }
        { pid = $1; ppid = $2; $1 = ""; $2 = ""; parent[pid] = ppid; args[pid] = $0 }
        END {
            for (p in args) {
                if (index(args[p], "/shell-snapshots/snapshot-") == 0) continue
                q = parent[p]; hops = 0
                while (q != "" && hops++ < 64) {
                    if (q in root) exit 0
                    q = parent[q]
                }
            }
            exit 1
        }'
    [ $? -ne 1 ]
}

# The redirect is load-bearing: herdr reads a hook's stdout/stderr to EOF and
# only then frees its in-flight slot (32, shared by every plugin). A timer that
# held a pipe open would occupy one for its whole grace.
pr_launch_timer() {
    if [ -n "${PANE_REAPER_LAUNCH_LOG:-}" ]; then
        printf 'launch %s\n' "$*" >> "$PANE_REAPER_LAUNCH_LOG"
        return 0
    fi
    nohup sh "$PR_ROOT/recheck.sh" "$@" < /dev/null > /dev/null 2>&1 &
}
