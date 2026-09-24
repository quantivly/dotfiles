# Smoke: prove the lane substrate
## Common rules
Read `_common-rules.md`, in this brief's own directory, first. Read-only except under out_dir.
If it is not there, **stop**: write a verdict with `status` `failed` saying the rules did not
reach you, and do nothing else.
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
assignment item) each with **`id`**, **`text`**, `evidence: {cmd, expected, observed}` and `confidence`,
empty `deliverables` and `followups`. ≤ 4096 bytes. Then stop.

`id` and `text` are not optional — `lanes/verdict.py` refuses a claim without them, and a refused
verdict makes `lane recipe --kind evaluate --of <id>` unreachable.
## Summary
Three commands, one verdict file, nothing else.
