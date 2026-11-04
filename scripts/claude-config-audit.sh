#!/usr/bin/env bash
#
# scripts/claude-config-audit.sh
# ==============================
#
# Collect every agent host's Claude Code configuration into one workspace on the
# laptop, and report where the hosts agree or differ.
#
# WHY. The laptop, dev, sol-build and nanoclaw each grew their own ~/.claude (or
# ~/.claude-herdr) by hand, so no one can say which skills, hooks, memory and
# settings a host has, or which copy is the reference. The shared-configuration
# design (docs/superpowers/specs/2026-11-04-shared-claude-config-design.md) needs
# that answer BEFORE any host is rendered from, or synced to, a shared source:
# overwriting across hosts without it destroys whichever copy was newer.
#
# TWO VERBS.
#   --collect   for each host, copy its configuration tree into
#               <workspace>/<name>/ (over ssh, or locally for `local`) and write
#               facts.tsv beside it.
#   --matrix    read the workspace's facts.tsv files and print one row per fact,
#               one column per host, marking where the hosts differ.
#
# READ-ONLY. Nothing is changed on any host. Credentials, transcripts, caches and
# plugin stores are excluded from what is copied (EXCLUDE_NAMES), and the only
# thing written is the workspace.
#
# Usage:
#   claude-config-audit.sh --collect [--workspace DIR] [--host NAME=ALIAS:CFGDIR]...
#   claude-config-audit.sh --matrix  [--workspace DIR] [--host NAME=ALIAS:CFGDIR]...
#   claude-config-audit.sh --help
#     --workspace DIR              default: ~/Projects/handoffs/2026-11-claude-config-audit
#     --host NAME=ALIAS:CFGDIR     repeatable; replaces the default hosts. ALIAS is an
#                                  ssh alias, or `local` to collect without ssh;
#                                  CFGDIR is a dot-directory under that host's $HOME
#
# Exit: --collect  0 every host collected · 2 a host failed
#       --matrix   0 identical · 1 drift · 2 a declared host has no facts.tsv
#       64 usage
#
# Test overrides (scripts/test-claude-config-audit.sh): CLAUDE_CONFIG_AUDIT_SSH (the ssh
# command), CLAUDE_CONFIG_AUDIT_WORKSPACE (the default workspace).

set -uo pipefail

SELF="${BASH_SOURCE[0]}"

# --- constants ----------------------------------------------------------------------------------

DEFAULT_WORKSPACE="$HOME/Projects/handoffs/2026-11-claude-config-audit"

# name=alias:cfgdir. `local` as the alias means collect without ssh.
DEFAULT_HOSTS=(
    "laptop=local:.claude"
    "dev=dev:.claude"
    "sol-build=sol-build:.claude"
    "nanoclaw=nanoclaw:.claude-herdr"
)

# Interpolated into ssh command lines and tar arguments, so anything else is refused
# before it can reach a shell or a path.
ALIAS_RE='^[A-Za-z0-9._-]+$'
CFGDIR_RE='^\.[A-Za-z0-9._-]+$'

SSH_CMD="${CLAUDE_CONFIG_AUDIT_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=30 -o ForwardAgent=no}"

# Never copied: credentials, transcripts and caches, and plugin stores that a host
# re-downloads. Matched against names inside the configuration directory.
EXCLUDE_NAMES=(
    '.credentials.json*'
    '.claude.json*'
    '*.jsonl'
    'sessions'
    'shell-snapshots'
    'file-history'
    'paste-cache'
    'debug'
    'cache'
    'backups'
    'downloads'
    'telemetry'
    'security'
    '*.signature*'
    'plugins/cache'
    'plugins/marketplaces'
    'plugins/repos'
    'plugins/data'
    'plugins/store'
    'plugins/synced'
    'skills/synced'
)

EXIT_COLLECT_FAILED=2
EXIT_USAGE=64

# --- failure ------------------------------------------------------------------------------------

usage() { sed -n '/^# Usage:/,/^# Exit:/p' "$SELF" | sed '$d; s/^# \{0,1\}//'; }

die() { printf 'claude-config-audit: %s\n' "$*" >&2; exit "$EXIT_COLLECT_FAILED"; }

usage_error() { printf 'claude-config-audit: %s\n\n' "$*" >&2; usage >&2; exit "$EXIT_USAGE"; }

# --- arguments ----------------------------------------------------------------------------------

MODE=""
WORKSPACE="${CLAUDE_CONFIG_AUDIT_WORKSPACE:-$DEFAULT_WORKSPACE}"
HOSTS=()

validate_host_spec() {   # $1 = name=alias:cfgdir
    local spec="$1" name alias_part cfgdir
    [[ "$spec" == *=*:* ]] || usage_error "--host wants NAME=ALIAS:CFGDIR, got '$spec'"
    name="${spec%%=*}"
    alias_part="${spec#*=}"; alias_part="${alias_part%%:*}"
    cfgdir="${spec#*:}"
    [[ "$name" =~ $ALIAS_RE ]]       || usage_error "host name '$name' must match $ALIAS_RE"
    [[ "$alias_part" =~ $ALIAS_RE ]] || usage_error "host alias '$alias_part' must match $ALIAS_RE"
    [[ "$cfgdir" =~ $CFGDIR_RE ]]    || usage_error "config dir '$cfgdir' must match $CFGDIR_RE"
}

parse_args() {
    local custom_hosts=()
    while (( $# )); do
        case "$1" in
            --collect) MODE=collect ;;
            --matrix)  MODE=matrix ;;
            --help|-h) usage; exit 0 ;;
            --workspace)
                (( $# >= 2 )) || usage_error "--workspace needs a directory"
                WORKSPACE="$2"; shift ;;
            --host)
                (( $# >= 2 )) || usage_error "--host needs NAME=ALIAS:CFGDIR"
                validate_host_spec "$2"
                custom_hosts+=("$2"); shift ;;
            *) usage_error "unknown argument '$1'" ;;
        esac
        shift
    done
    [[ -n "$MODE" ]] || usage_error "say what to do: --collect or --matrix"
    if (( ${#custom_hosts[@]} )); then HOSTS=("${custom_hosts[@]}"); else HOSTS=("${DEFAULT_HOSTS[@]}"); fi
}

# --- verbs (Tasks 3-5) --------------------------------------------------------------------------

collect_main() { die "--collect is not implemented"; }
matrix_main()  { die "--matrix is not implemented"; }

main() {
    parse_args "$@"
    case "$MODE" in
        collect) collect_main ;;
        matrix)  matrix_main ;;
    esac
}

main "$@"
