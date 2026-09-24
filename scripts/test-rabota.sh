#!/usr/bin/env bash
# Runs the rabota unit tests. Mirrors the other scripts/test-*.sh in this repo.
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# NOT a bare `python3`: rabota/config.py imports tomllib (3.11+), and on dev python3 is 3.10.12,
# where the whole suite collapses into import errors (21 of them, measured 2026-09-24 by a review
# lane -- which is the machine every lane runs on, so "run the suite" was not a thing a lane could
# be asked to do). scripts/rabota already picks a capable interpreter; ask it rather than choosing
# again here, so the two cannot drift.
py="$(RABOTA_PRINT_PYTHON=1 "$here/scripts/rabota")"
cd "$here/rabota"
"$py" -m unittest discover -s tests -t . -v "$@"

# Skill v2 size budget (WS5 task 5.3): SKILL.md must stay short enough that a fresh agent reads
# it in full, and its references must stay small enough to load on demand without eating the
# skill's own token budget.
skill_lines="$(wc -l < "$here/claude/skills/rabota/SKILL.md")"
if [ "$skill_lines" -gt 150 ]; then
  echo "test-rabota: claude/skills/rabota/SKILL.md is $skill_lines lines, budget is 150" >&2
  exit 1
fi
refs_bytes="$(du -cb "$here"/claude/skills/rabota/references/*.md | tail -1 | cut -f1)"
if [ "$refs_bytes" -gt 12288 ]; then
  echo "test-rabota: claude/skills/rabota/references/*.md total $refs_bytes bytes, budget is 12288" >&2
  exit 1
fi
echo "test-rabota: skill size budget ok ($skill_lines SKILL.md lines, $refs_bytes references bytes)"
