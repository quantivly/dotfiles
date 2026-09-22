# Smoke: prove the lane substrate
## Common rules
Read `/home/zvi/quantivly/handoffs/rabota/_common-rules.md` first. Read-only except under out_dir.
## Role
You verify a runtime; you implement nothing and change no file outside out_dir.
## Assignment
1. Run `rabota version` and record stdout verbatim.
2. Run `python3 --version` and `uname -n` and record them.
3. Confirm `git -C . status --porcelain` is empty in this worktree.
## Ownership
This worktree is yours to read. You write only under out_dir. No git verbs other than `status`.
## Outputs
out_dir: {out_dir}
Write `{out_dir}/verdict.json` in the spec §C6 shape: `lane`, `status` (`done`), three `claims` (one per
assignment item) each with `evidence: {cmd, expected, observed}` and `confidence`, empty `deliverables`
and `followups`. ≤ 4096 bytes. Then stop.
## Summary
Three commands, one verdict file, nothing else.
