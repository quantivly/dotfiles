---
paths:
  - CLAUDE.md
  - docs/**/*.md
  - .claude/rules/*.md
---

# You are editing an always-loaded surface

`CLAUDE.md` is loaded in full into every request of every session. It grew
35,682 → 350,324 in nineteen days because each PR appended its own review
narrative, and a one-off cut in Jan 2026 regrew 25×. A budget is now enforced
by `scripts/check-claude-md.sh` (CI + pre-commit) against a ceiling derived
from history that can only tighten.

- **Remove as much as you add.** The ceiling does not rise because you need it to.
- **Route it before you write it** — see `## How to extend this file` in
  [CLAUDE.md](../../CLAUDE.md). One imperative line here; the evidence in `docs/`.
- **Extract the elaboration, keep the operative rule inline.** The threshold, the
  decision and the emitted line stay in `CLAUDE.md`. A rule moved out behind a
  pointer is a rule that stops being read — measured at zero reads over 102 runs.
- **Retire, do not extract,** a rule whose condition can no longer fire.
- **One prose home per fact.** A one-line imperative and a memory hook are
  pointers; the same *explanation* written twice is the drift `69d815d` fixed.
- **Link anything you add** under `docs/`, `.claude/rules/` or `.claude/skills/`
  from `CLAUDE.md` or `README.md`. The guard fails on an unreachable file,
  because an unrouted file is an unread file.

Run `./scripts/check-claude-md.sh` before you commit.
