#!/usr/bin/env bash
# Keep the always-loaded prose surfaces of this repository inside a budget that
# can only tighten, and keep everything they point at reachable.
#
# WHY THIS EXISTS. CLAUDE.md is loaded in full into every request of every
# session. It held 14k-36k chars for eight months, then went 35,682 -> 350,324
# in the nineteen days from 2026-08-30 to 2026-09-18 because every PR appended
# its own review narrative. That is ~87k tokens per request, and the documented
# reason for the 150k warning is that longer files "reduce adherence" -- the
# file stops producing the behaviour it was written to produce. The one-off cut
# has already been tried here (2026-01-07, 32.6k -> 14.2k) and regrew 25x, so
# the ratchet is the deliverable and the cut is secondary.
#
# THE CEILING IS DERIVED, NOT WRITTEN DOWN. It is
#
#     min     = min(size of CLAUDE.md over base-branch commits that ALSO carry
#                   this script)
#     ceiling = max(FLOOR, min + SLACK)
#
# so there is no number anyone can raise. Every design where a human writes the
# ceiling into a file has the same hole: the PR that breaks the rule edits the
# number in the same diff. Here the only way to raise the ceiling is to lower
# CLAUDE.md and merge it, which is the goal. It is a RATCHET rather than a rate
# limit because the minimum cannot be lowered by a larger commit -- SLACK is a
# one-time buffer, not a per-PR allowance (parent-size + SLACK at ~1 PR/day is
# ~550k/year, i.e. the pathology, slightly slowed).
#
# FLOOR stops the ratchet tightening forever: a ratchet with no floor eventually
# forbids all edits, and one accidental truncation commit would pin min near
# zero and make this permanently red. A permanently-red checker gets deleted,
# taking its protection with it -- this repo has recorded that failure seven
# times. FLOOR and SLACK are constants here rather than in the config file
# because they are integrity-critical; they are pinned BEHAVIOURALLY by rows in
# scripts/test-claude-md.sh, never by grepping these literals.
#
# THE ANCHOR IS SELF-REFERENTIAL. min is taken only over commits that carry this
# script, so the ratchet begins the instant it lands and needs no hardcoded date,
# tag or SHA (a date drifts under rebase, a tag can be moved, and a SHA cannot be
# known by the PR that introduces the guard). Scanning stops at the first
# base-branch commit that lacks the script: a delete-and-re-add would therefore
# only be counted from the re-add, which is more permissive, but deleting it
# fails the CI job loudly and this repo squash-merges, so such a pair collapses
# into one guard-bearing commit.
#
# Exit 0 = every rule evaluated and none violated. 1 = a rule was violated (the
# tree is wrong). 2 = could not run (this script could not evaluate a rule) --
# "could not run" is NEVER reported as clean, because every way of getting a
# path or a ref wrong would otherwise narrow this check into silence. 3 = this
# script is self-inconsistent (the checker is wrong). 2 and 3 are deliberately
# distinct from check-workflow-apt.sh's single exit 1 for its denominator: a
# skipped check means the guard is broken and a violation means the tree is
# broken, and a state-table row can only pin the difference if the codes differ.
#
# Every rule prints a prefix unique to itself (SIZE:/AGGR:/CAP-CARD:/CAP-SKILL:/
# FM:/LINK:/ORPH:/SCOPE:) so a state-table needle is unambiguous, and no pass-path message
# contains a fail-path prefix. Colour only when stdout is a terminal: an
# unconditional escape puts control characters into every redirect and makes a
# tick un-greppable, which has already let a row in this repo pass whatever was
# printed.
set -uo pipefail

FLOOR=20000
SLACK=1500
EXPECTED_CHECKS=8

if [ -t 1 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; RST=$'\033[0m'; else RED=''; GRN=''; RST=''; fi

die_cannot_run() { printf '%scheck-claude-md: %s%s\n' "$RED" "$1" "$RST" >&2; exit 2; }

root=${1:-}
case "$root" in
    -*) die_cannot_run "unrecognised argument: $root" ;;
esac
if [ -z "$root" ]; then
    root=$(git rev-parse --show-toplevel 2>/dev/null) ||
        die_cannot_run "not a git repository and no root given"
fi
[ -d "$root" ] || die_cannot_run "no such directory: $root"
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 ||
    die_cannot_run "$root is not a git repository"

# A shallow clone makes the historical minimum equal today's size, so the
# ceiling becomes today+SLACK and the guard reports success while enforcing
# nothing. actions/checkout@v4 defaults to fetch-depth: 1, so this is the
# default state in CI unless the job asks otherwise -- it must be exit 2.
[ "$(git -C "$root" rev-parse --is-shallow-repository 2>/dev/null)" = "false" ] ||
    die_cannot_run "shallow repository: the ratchet needs history (use fetch-depth: 0)"

CLAUDE_MD="$root/CLAUDE.md"
[ -f "$CLAUDE_MD" ] || die_cannot_run "CLAUDE.md is missing or is not a regular file"
[ -r "$CLAUDE_MD" ] || die_cannot_run "CLAUDE.md is not readable"

CONF="$root/scripts/context-budget.conf"
[ -r "$CONF" ] || die_cannot_run "cannot read $CONF"
conf_int() { # conf_int <KEY>
    local v
    v=$(sed -n "s/^$1=\([0-9][0-9]*\)[[:space:]]*$/\1/p" "$CONF" | head -1)
    [ -n "$v" ] || die_cannot_run "$1 missing or not a decimal integer in $CONF"
    printf '%s' "$v"
}
RULE_CARD_MAX=$(conf_int RULE_CARD_MAX_BYTES)
SKILL_MD_MAX=$(conf_int SKILL_MD_MAX_BYTES)
AGGR_EXTRA=$(conf_int AGGREGATE_EXTRA_BYTES)

fsize() { wc -c < "$1" | tr -d ' '; }

# --- the ceiling ---------------------------------------------------------
base=''
for cand in refs/remotes/origin/HEAD refs/remotes/origin/main refs/heads/main; do
    if git -C "$root" rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then base=$cand; break; fi
done
[ -n "$base" ] || base=HEAD

# Two `git cat-file --batch-check` passes rather than two git forks per commit:
# history here is ~900 commits and this runs in a pre-commit hook.
commits=$(git -C "$root" rev-list --first-parent "$base" 2>/dev/null) ||
    die_cannot_run "could not list commits on $base"

min=''
if [ -n "$commits" ]; then
    guard_rel='scripts/check-claude-md.sh'
    have=$(printf '%s\n' "$commits" | sed "s|\$|:$guard_rel|" |
           git -C "$root" cat-file --batch-check='%(objecttype)' 2>/dev/null) ||
        die_cannot_run "could not probe history for $guard_rel"
    sizes=$(printf '%s\n' "$commits" | sed 's|$|:CLAUDE.md|' |
            git -C "$root" cat-file --batch-check='%(objectsize)' 2>/dev/null) ||
        die_cannot_run "could not probe history for CLAUDE.md"
    min=$(paste -d' ' <(printf '%s\n' "$have") <(printf '%s\n' "$sizes") |
          awk '$1!="blob"{exit} $2 ~ /^[0-9]+$/ {if (m=="" || $2<m) m=$2} END{if (m!="") print m}')
fi

if [ -n "$min" ]; then
    base_label=$base
else
    # No base-branch commit carries this script yet: the guard is new. Fall back
    # to the working tree so PR1 is not permanently red, and SAY SO. Bootstrap
    # still evaluates every other rule below -- it is not an escape hatch.
    min=$(fsize "$CLAUDE_MD")
    base_label=bootstrap
fi

ceiling=$(( min + SLACK ))
[ "$ceiling" -ge "$FLOOR" ] || ceiling=$FLOOR
# The aggregate gets its own allowance on top. Sharing one ceiling sounds
# stricter and is unusable: it leaves the whole card layer SLACK bytes -- one
# card, ever -- so the first card spends the budget and every later area has
# nowhere to put its trigger rules except back in CLAUDE.md.
aggr_ceiling=$(( ceiling + AGGR_EXTRA ))

# --- file sets -----------------------------------------------------------
shopt -s nullglob globstar
rules=( "$root"/.claude/rules/*.md )
skills=( "$root"/.claude/skills/*/SKILL.md )
docs=( "$root"/docs/**/*.md )

if [ -d "$root/.claude/rules" ] && [ ! -x "$root/.claude/rules" ]; then
    die_cannot_run ".claude/rules exists but cannot be enumerated"
fi
if [ -d "$root/.claude/skills" ] && [ ! -x "$root/.claude/skills" ]; then
    die_cannot_run ".claude/skills exists but cannot be enumerated"
fi

checks=0; viol=0
ok()  { checks=$((checks+1)); printf '%s  ok%s   %s\n' "$GRN" "$RST" "$1"; }
bad() { checks=$((checks+1)); viol=$((viol+1)); printf '%s  BAD%s  %s\n' "$RED" "$RST" "$1"; }

# --- R1 SIZE -------------------------------------------------------------
size=$(fsize "$CLAUDE_MD")
if [ "$size" -le "$ceiling" ]; then
    ok "SIZE: CLAUDE.md $size <= $ceiling"
else
    bad "SIZE: CLAUDE.md is $size bytes, over the $ceiling ceiling by $((size-ceiling)). Remove as much as you add; elaboration belongs in docs/."
fi

# --- R2 AGGR -------------------------------------------------------------
# The obvious defeat of R1 is moving prose to another ALWAYS-LOADED surface, so
# the budget is on the aggregate too. @-imports are inlined into context and
# counted against the same budget, so they are counted here. Skills are excluded
# because their bodies load on demand; if that turns out to be false, this is
# the line to change and C3 in the state table is the row that encodes it.
aggr=$size
for f in "${rules[@]}"; do aggr=$(( aggr + $(fsize "$f") )); done
while IFS= read -r imp; do
    [ -n "$imp" ] || continue
    [ -f "$root/$imp" ] && aggr=$(( aggr + $(fsize "$root/$imp") ))
done < <(sed -n 's/^@\([^[:space:]`]*\).*/\1/p' "$CLAUDE_MD")
if [ "$aggr" -le "$aggr_ceiling" ]; then
    ok "AGGR: always-loaded total $aggr <= $aggr_ceiling"
else
    bad "AGGR: always-loaded total is $aggr bytes over $aggr_ceiling — CLAUDE.md plus rule cards plus @-imports. Moving prose into a rule card does not reduce what is loaded."
fi

# --- R3 CAP (rule cards) / R4 CAP (skills) -------------------------------
# Two checks, not one: each must be independently killable by a mutant, and a
# single combined message would make either needle ambiguous.
cardfail=0
for f in "${rules[@]}"; do
    n=$(fsize "$f")
    [ "$n" -le "$RULE_CARD_MAX" ] || { cardfail=1
        printf '%s  ..%s   CAP: %s is %s > %s\n' "$RED" "$RST" "${f#"$root"/}" "$n" "$RULE_CARD_MAX"; }
done
if [ "$cardfail" -eq 0 ]; then
    ok "CAP-CARD: ${#rules[@]} rule card(s) within $RULE_CARD_MAX"
else
    bad "CAP-CARD: a rule card is over $RULE_CARD_MAX bytes — a card carries imperative lines and links, and this cap is what keeps prose out of it"
fi

skillfail=0
for f in "${skills[@]}"; do
    n=$(fsize "$f")
    [ "$n" -le "$SKILL_MD_MAX" ] || { skillfail=1
        printf '%s  ..%s   CAP: %s is %s > %s\n' "$RED" "$RST" "${f#"$root"/}" "$n" "$SKILL_MD_MAX"; }
done
if [ "$skillfail" -eq 0 ]; then
    ok "CAP-SKILL: ${#skills[@]} SKILL.md within $SKILL_MD_MAX"
else
    bad "CAP-SKILL: a SKILL.md is over $SKILL_MD_MAX bytes — references/, scripts/ and assets/ under the skill are uncapped, so move the detail there"
fi

# --- R5 FM ---------------------------------------------------------------
# Deliberately a SMALL grammar rather than a YAML parser: frontmatter is the
# block between a `---` on line 1 and the next `---`, and only flat scalars and
# flat lists are recognised. This repo has recorded six ways a hand-written
# parser went quiet; the mitigation is not a better parser, it is a grammar
# small enough that anything it cannot read is a card too complex to be a card.
# CRLF needs no strip: every pattern that reads this block matches `[[:space:]]`,
# which includes \r. A `tr -d '\r'` here was unkillable by mutation for exactly
# that reason, so it went; rows E8/E9 pin the tolerance at the patterns instead.
fm_block() { sed -n '1{/^---[[:space:]]*$/!q}; 1d; /^---[[:space:]]*$/q; p' "$1"; }
fmfail=0
for f in "${skills[@]}"; do
    b=$(fm_block "$f")
    for key in name description; do
        v=$(printf '%s\n' "$b" | sed -n "s/^$key:[[:space:]]*//p" | head -1)
        follow=$(printf '%s\n' "$b" | sed -n "/^$key:/{n;p}" | head -1)
        if ! printf '%s\n' "$b" | grep -q "^$key:"; then
            fmfail=1; printf '%s  ..%s   FM: %s has no %s:\n' "$RED" "$RST" "${f#"$root"/}" "$key"
        elif [ -z "$v" ] && [ -z "${follow// /}" ]; then
            fmfail=1; printf '%s  ..%s   FM: %s has an empty %s:\n' "$RED" "$RST" "${f#"$root"/}" "$key"
        fi
    done
done
if [ "$fmfail" -eq 0 ]; then
    ok "FM: frontmatter valid on ${#skills[@]} skill(s)"
else
    bad "FM: a SKILL.md has a missing or empty name: or description:"
fi

# --- link extraction (shared by R6 and R7) -------------------------------
# Skips fenced code blocks: CLAUDE.md carries ~50 fences full of example paths,
# and checking them would make this permanently red on a correct tree.
links_of() { # links_of <file> -> one relative target per line
    # POSIX awk only: index()/substr(), never gawk's 3-arg match(). `awk` is
    # MAWK on Ubuntu and on this box, where the gawk form is a syntax error --
    # and the first draft of this function paired that with `2>/dev/null ||
    # true`, so it produced ZERO links and R6/R7 reported a clean tree they had
    # never read. That is the silent pass this whole file exists to prevent, so
    # errors are not suppressed here and links_selftest below proves the
    # extractor still works before any rule trusts it.
    awk '
        /^[[:space:]]*```/ { fence = !fence; next }
        fence { next }
        {
            line = $0
            while (1) {
                i = index(line, "](")
                if (i == 0) break
                rest = substr(line, i + 2)
                j = index(rest, ")")
                if (j == 0) break
                print substr(rest, 1, j - 1)
                line = substr(rest, j + 1)
            }
        }
    ' "$1" |
    sed 's/[[:space:]].*$//; s/#.*$//' |
    grep -Ev '^$|^(https?:|mailto:|ftp:)'
    return 0
}

# A checker that silently extracts nothing reports a perfect tree. This asserts
# the extractor against a fixture whose answers are known: one ordinary link,
# one fenced link that must be skipped, one external that must be dropped, and
# one anchor that must be stripped to its file.
links_selftest() {
    local t out
    t=$(mktemp) || die_cannot_run "cannot create a temp file for the link self-test"
    printf '%s\n' \
        '[a](docs/REAL.md)' \
        '```' \
        '[b](docs/FENCED.md)' \
        '```' \
        '[c](https://example.invalid/x)' \
        '[d](docs/ANCHOR.md#sec)' > "$t"
    out=$(links_of "$t" | tr '\n' ' ')
    rm -f "$t"
    [ "$out" = "docs/REAL.md docs/ANCHOR.md " ] ||
        die_cannot_run "link extractor self-test failed (got: '''$out'''), refusing to report on links"
}
links_selftest

# --- R6 LINK -------------------------------------------------------------
linkfail=0
for f in "$CLAUDE_MD" "${rules[@]}" "${skills[@]}"; do
    d=$(dirname "$f")
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        case "$t" in /*) continue ;; esac
        [ -e "$d/$t" ] || { linkfail=1
            printf '%s  ..%s   LINK: %s -> %s does not exist\n' "$RED" "$RST" "${f#"$root"/}" "$t"; }
    done < <(links_of "$f")
done
if [ "$linkfail" -eq 0 ]; then
    ok "LINK: every relative link resolves"
else
    bad "LINK: a relative link does not resolve (targets resolve relative to the file that contains them)"
fi

# --- R7 ORPH -------------------------------------------------------------
# Reachability by BFS from CLAUDE.md and README.md, NOT an inbound-link count:
# two orphans linking only to each other pass a count and fail this. This is the
# rule that makes the architecture survive, because it is the only check that
# does not depend on any belief about Claude Code's loading semantics. CLAUDE.md
# is loaded; anything reachable from it can be opened. CHANGELOG.md is
# deliberately not a root -- a page cited only by a changelog entry is not
# routed, it is mentioned.
declare -A seen=()
queue=()
for r in "$root/CLAUDE.md" "$root/README.md"; do
    [ -f "$r" ] && { seen["$r"]=1; queue+=("$r"); }
done
for f in "${skills[@]}"; do :; done
i=0
while [ "$i" -lt "${#queue[@]}" ]; do
    cur=${queue[$i]}; i=$((i+1))
    d=$(dirname "$cur")
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        case "$t" in /*) continue ;; esac
        tgt="$d/$t"
        [ -f "$tgt" ] || continue
        case "$tgt" in *.md) ;; *) continue ;; esac
        abs=$(cd "$(dirname "$tgt")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename "$tgt")") || continue
        if [ -z "${seen[$abs]:-}" ]; then seen["$abs"]=1; queue+=("$abs"); fi
    done < <(links_of "$cur")
done
orphfail=0
for f in "${docs[@]}" "${rules[@]}" "${skills[@]}"; do
    case "${f#"$root"/}" in
        docs/plans/*|docs/superpowers/*) continue ;;
    esac
    abs=$(cd "$(dirname "$f")" && printf '%s/%s' "$(pwd)" "$(basename "$f")")
    [ -n "${seen[$abs]:-}" ] || { orphfail=1
        printf '%s  ..%s   ORPH: %s is not reachable from CLAUDE.md or README.md\n' "$RED" "$RST" "${f#"$root"/}"; }
done
if [ "$orphfail" -eq 0 ]; then
    ok "ORPH: every docs page, rule card and skill is reachable"
else
    bad "ORPH: a file is unreachable — an unrouted file is an unread file. Link it from CLAUDE.md or README.md."
fi

# --- R9 SCOPE ------------------------------------------------------------
# A card that loads is a card that costs. Since `paths:` scoping does not work
# (see FM above), every card here is unconditional and therefore ALWAYS loaded,
# which is exactly what the aggregate rule budgets. This check states that
# relationship out loud rather than leaving it implied, so the day scoping starts
# working somebody has to come and change this line deliberately.
scopefail=0
for f in "${rules[@]}"; do
    b=$(fm_block "$f")
    if [ -n "$b" ] && printf '%s\n' "$b" | grep -q '^[[:space:]]*paths:'; then scopefail=1; fi
done
if [ "$scopefail" -eq 0 ]; then
    ok "SCOPE: all ${#rules[@]} card(s) are unconditional, so all are counted by AGGR"
else
    bad "SCOPE: a card is scoped with paths: and so never loads — it is dead weight the aggregate cannot see"
fi

# --- summary -------------------------------------------------------------
# Printed on EVERY exit path, so a raised ceiling is visible in a CI log and
# `rules=0 skills=0` cannot be mistaken for a clean enumeration.
printf 'SUMMARY: size=%s aggregate=%s ceiling=%s aggr_ceiling=%s floor=%s slack=%s base=%s min=%s rules=%s skills=%s docs=%s\n' \
    "$size" "$aggr" "$ceiling" "$aggr_ceiling" "$FLOOR" "$SLACK" "$base_label" "$min" \
    "${#rules[@]}" "${#skills[@]}" "${#docs[@]}"

if [ "$checks" -ne "$EXPECTED_CHECKS" ]; then
    printf '%scheck-claude-md: performed %d checks, expected %d — a check vanished%s\n' \
        "$RED" "$checks" "$EXPECTED_CHECKS" "$RST" >&2
    exit 3
fi
if [ "$viol" -gt 0 ]; then
    printf '%scheck-claude-md: %d of %d checks failed%s\n' "$RED" "$viol" "$checks" "$RST" >&2
    exit 1
fi
printf '%scheck-claude-md: all %d checks passed%s\n' "$GRN" "$checks" "$RST"
