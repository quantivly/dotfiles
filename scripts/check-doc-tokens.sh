#!/usr/bin/env bash
# Assert that moving prose out of CLAUDE.md did not silently DELETE any of it.
#
# WHY THIS EXISTS (DO-622). CLAUDE.md is being cut from ~354k chars to ~20k by
# moving its evidence into docs/. A move and a deletion look identical in a
# diff of CLAUDE.md, and the whole value of that prose is that it was measured,
# so losing a paragraph in transit is losing the measurement. This compares the
# BASE branch's CLAUDE.md against the tree as it is now.
#
# Two axes, because each is blind where the other sees:
#
#   TOKENS -- every Linear id (DO-123), date (2026-09-18), script path
#   (scripts/foo.sh), PR reference (#160) and heading text in the base
#   CLAUDE.md must still occur somewhere in CLAUDE.md, docs/**/*.md or
#   .claude/**/*.md. CHANGELOG.md is deliberately NOT searched: a token
#   surviving only because the migration's own changelog entry mentions it has
#   not been preserved, it has been cited.
#   VOLUME -- total bytes of *.md under CLAUDE.md, docs/, examples/ and
#   .claude/ must not fall by more than 10%. Content must be MOVED.
#
# BE HONEST ABOUT WHAT THIS CANNOT SEE. ~120 anchors over ~4,400 lines is one
# per ~36 lines, so the token axis samples the file at roughly 3% resolution.
# Neither axis sees reasoning lost in a paraphrase, a negation flipped, or a
# rule demoted from first to last. That is why the migration moves text
# VERBATIM, and why human review of each PR is the control for the rest.
#
# RETIRING something is legitimate -- a rule whose condition can no longer fire
# should go, not move. Do it by adding a line to docs/RETIRED.md naming the
# token and the reason. That resolves the token here, leaves a reviewable
# record, and needs no bypass flag.
#
# Exit 0 = nothing lost. 1 = a token or the volume bound was lost. 2 = could
# not run (no base ref, no CLAUDE.md at base, not a repo) -- never a pass.
set -uo pipefail

if [ -t 1 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; RST=$'\033[0m'; else RED=''; GRN=''; RST=''; fi
die() { printf '%scheck-doc-tokens: %s%s\n' "$RED" "$1" "$RST" >&2; exit 2; }

root=${1:-}
base=${2:-}
if [ -z "$root" ]; then
    root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not a git repository and no root given"
fi
[ -d "$root" ] || die "no such directory: $root"
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || die "$root is not a git repository"
if [ -z "$base" ]; then
    for cand in refs/remotes/origin/HEAD refs/remotes/origin/main refs/heads/main; do
        if git -C "$root" rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then base=$cand; break; fi
    done
    [ -n "$base" ] || die "no base ref found (origin/HEAD, origin/main, main) -- pass one explicitly"
fi
git -C "$root" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1 || die "base ref '$base' does not resolve"

base_md=$(git -C "$root" show "$base:CLAUDE.md" 2>/dev/null) || die "CLAUDE.md does not exist at $base"
[ -n "$base_md" ] || die "CLAUDE.md is empty at $base"

# The corpus a token may survive in. Built once; every search is against it.
corpus=$(mktemp) || die "cannot create a temp file"
trap 'rm -f "$corpus"' EXIT
shopt -s nullglob globstar
files=( "$root/CLAUDE.md" "$root"/docs/**/*.md "$root"/.claude/**/*.md )
[ "${#files[@]}" -gt 0 ] || die "no corpus files found under $root"
cat "${files[@]}" > "$corpus" 2>/dev/null || die "could not read the corpus"

lost=0
missing() { lost=$((lost+1)); printf '%s  LOST%s %-8s %s\n' "$RED" "$RST" "$1" "$2"; }

# --- tokens --------------------------------------------------------------
ntok=0
check_class() { # check_class <label> <extended-regex> <fixed|pr>
    local label=$1 re=$2 mode=$3 t
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        ntok=$((ntok+1))
        case "$mode" in
            # A PR ref must not be satisfied by a longer number: #16 is not #160.
            pr)    grep -Eq "#${t#\#}([^0-9]|\$)" "$corpus" || missing "$label" "$t" ;;
            fixed) grep -Fq -- "$t" "$corpus" || missing "$label" "$t" ;;
        esac
    done < <(printf '%s\n' "$base_md" | grep -oE -- "$re" | sort -u)
}
check_class TICKET '\bDO-[0-9]+\b'                       fixed
check_class DATE   '\b[0-9]{4}-[0-9]{2}-[0-9]{2}\b'      fixed
check_class SCRIPT 'scripts/[A-Za-z0-9_.-]+[A-Za-z0-9_]' fixed
check_class PR     '#[0-9]{2,4}\b'                       pr

# Headings: the TEXT must survive, at any level -- a moved section is usually
# demoted or promoted by one level, which is a move, not a loss.
while IFS= read -r h; do
    [ -n "$h" ] || continue
    ntok=$((ntok+1))
    grep -Fq -- "$h" "$corpus" || missing HEADING "$h"
done < <(printf '%s\n' "$base_md" | awk '/^```/{f=!f; next} !f && /^#{2,4} /{sub(/^#+ /,""); print}' | sort -u)

# --- volume --------------------------------------------------------------
vol_paths=( CLAUDE.md docs examples .claude )
base_vol=$(git -C "$root" ls-tree -r -l "$base" -- "${vol_paths[@]}" 2>/dev/null |
           awk '$NF ~ /\.md$/ {s+=$4} END{print s+0}')
now_vol=0
for f in "$root/CLAUDE.md" "$root"/docs/**/*.md "$root"/examples/**/*.md "$root"/.claude/**/*.md; do
    [ -f "$f" ] && now_vol=$(( now_vol + $(wc -c < "$f") ))
done
[ "$base_vol" -gt 0 ] || die "could not measure the documentation volume at $base"
floor=$(( base_vol * 90 / 100 ))
volfail=0
if [ "$now_vol" -lt "$floor" ]; then
    volfail=1
    printf '%s  LOST%s VOLUME   documentation fell from %s to %s bytes, more than 10%% -- content must be moved, not deleted\n' \
        "$RED" "$RST" "$base_vol" "$now_vol"
fi

printf 'SUMMARY: base=%s tokens=%s lost=%s volume=%s->%s floor=%s\n' \
    "$base" "$ntok" "$lost" "$base_vol" "$now_vol" "$floor"
[ "$ntok" -gt 0 ] || die "extracted zero tokens from the base CLAUDE.md -- the extractor is broken, not the tree clean"

if [ "$lost" -gt 0 ] || [ "$volfail" -gt 0 ]; then
    printf '%scheck-doc-tokens: content lost relative to %s. Move it into docs/, or retire it with a line in docs/RETIRED.md.%s\n' \
        "$RED" "$base" "$RST" >&2
    exit 1
fi
printf '%scheck-doc-tokens: all %s tokens resolve and volume is within 10%%%s\n' "$GRN" "$ntok" "$RST"
