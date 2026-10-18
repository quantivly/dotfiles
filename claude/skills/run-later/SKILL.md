---
name: run-later
description: >
  Schedule work to run LATER on THIS laptop with `rabota schedule add`, instead of writing a
  prompt for @zvi to paste on a date. Use when you would say "re-check this tomorrow", "run X
  after the weekend", "verify in N days", "remind me to check", or would hand over a command or
  prompt to run later, and the work needs this laptop's files, credentials or tools (the
  journal, local repos, ~/.local/state, account and herdr state). Use it INSTEAD of the
  built-in cloud `schedule` skill for any such one-off run: that one runs in Anthropic's cloud
  and cannot see this machine. Also use it to read what an earlier session scheduled
  (`rabota schedule list`, `rabota schedule show`). Do NOT use for a recurring cron routine, or
  for work that needs nothing from this machine (a remote repo, the web, an API): those go to
  `schedule`. Do NOT use where `rabota` is not installed.
---

# run-later — schedule a run on this laptop, never a prompt to paste

`rabota schedule add` stores a run in the tenant's queue. `rabota-schedule@<tenant>.timer` ticks
every 10 minutes and catches up after a suspend. The tick runs it, appends the result to a
record file, and escalates anything but a clean pass to @zvi: a desktop notification, and
"Needs you" at the top of `rabota brief`. Nobody has to remember a date. Design:
`docs/superpowers/specs/2026-10-11-scheduled-agent-runs-design.md` in the dotfiles repo.

## Pick the kind: a command, today

- **A mechanical verdict is a `--command <script>` run.** It is live, it bills no seat, and it
  is deterministic. Exit **0 `pass`, 1 `fail`, 2 `could-not-run`**; any other code, a timeout
  kill or no exit status at all is `could-not-run` too, and is retried once, 30 minutes later.
  A run that cannot start at all, because its `--cwd` is gone or its frozen script changed, is
  `could-not-run` at once and never retried. `fail` is a result and is never retried.
- **Judgement goes in `--ask`, not in an agent.** Agent runs (`--prompt-file`) are accepted and
  stored, but agent runs are not dispatched yet: the tick defers every one until phase 2
  (DO-820), so it sits `pending` until it expires (default: due + 48 h) and escalates as
  `expired`. Do not schedule one expecting it to run. Write a script that gathers the evidence
  and decides mechanically, and put the question the evidence raises in `--ask`.
- **An agent run's permissions are declared, not inherited**, for when phase 2 lands: one
  `--allow 'Bash(journalctl:*)'` per Bash rule, `--read <absolute path>` per read, and it writes
  only its own output directory. `--allow`, `--read`, `--seat`, `--model`, `--effort` and
  `--max-budget-usd` configure an agent run; a command run refuses them.

## Write the script

- **It is frozen.** `add` copies it into the tenant's state; editing or deleting the source
  afterwards changes nothing. To change it, `cancel` and `add` again.
- **Start it with a shebang**; it is executed directly. Arguments go after `--`.
- **It is not your shell.** It runs in a transient systemd user unit in `--cwd`, with no
  terminal and no zsh functions or aliases. Its `PATH` is exactly
  `~/.local/bin:/usr/local/bin:/usr/bin:/bin`, so tools mise installs (e.g. `rg`) are not on it.
  A script that calls one exits 127 on both attempts and escalates, and `--dry-run` cannot catch
  that, because it never runs the script. Call such a tool by its absolute path, or stick to
  `/usr/bin` tools.
- **Its `gh` gets the config dir gh routing gives `--cwd`**, the one `gh-doctor <cwd>` shows
  under "Route for this directory:". The tick sets it on the unit as `GH_CONFIG_DIR` and never
  sets a `GH_TOKEN`. That names a config dir, not an account: with no token, gh takes the
  keyring's, which need not be the one the dir declares. Ask what a run would act as with
  `env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR=<dir> gh api user --jq .login`, never from the
  route line. Where no route applies, the unit gets no `GH_CONFIG_DIR` and gh uses its default
  config dir. A route that cannot be resolved (a repo git cannot read, a broken route table)
  starts nothing: that attempt is `could-not-run`, retried like any other.
- **It runs unconfined, as you.** Only its memory (1G) and `--timeout` (default 15 min, at most
  6 h) bound it. Keep it a read-only check: no edits, pushes, merges or messages.
- **Print the evidence.** The last 4 KiB of stdout and of stderr go, redacted, into the result
  and the record. Make the last lines say what was measured.
- **It must not invoke `claude` or a launcher of it** (`clauth`, `hspawn`, `herdr-draft`), even
  in a comment: `add` refuses the script. Never route around that with a second script.

```bash
#!/usr/bin/env bash
out=$(journalctl --user -u example.service --since -7d --no-pager) || exit 2   # could not run
n=$(printf '%s\n' "$out" | grep -c 'refused')
echo "refused lines in the last 7 days: $n"
[ "$n" -eq 0 ]                                                                  # 0 pass, 1 fail
```

## Declare it: dry run first

```bash
rabota --dry-run schedule add --at 'YYYY-MM-DD 09:00' --title 'refusals since the fix: still zero?' \
    --command <check.sh> --cwd <repo> --record <results.md> --timeout 5m \
    --ask 'Refusals came back. Reopen the issue?' \
    --option 'reopen it, I will' --option 'look again tomorrow=rerun:+24h' --option 'drop it=cancel-followups'
```

`--dry-run` and `--text` are global flags and go BEFORE `schedule`. A dry run validates and
prints the whole declaration and stores nothing. Then run the same line without `--dry-run`.

- **`--at`** is local time, `'YYYY-MM-DD HH:MM'`, not in the past and at most 30 days ahead.
  **`--expires`** defaults to due + 48 h and may be at most 30 days after `--at`. A laptop that
  is asleep at the due time runs it on resume, if it has not expired.
- **`--title`** is one line and is shown on every surface. Make it the question.
- **`--cwd`** is where the run starts; without it, your cwd. A cwd that contains the tenant's
  state directory is refused, so from a workspace root such as `~/quantivly` pass
  `--cwd <a repo or other directory>`. Pick one that still exists at the due time, not a worktree
  the daily sweep may remove.
- **The tenant** is `--tenant`, else `$CLAUDE_ACCOUNT_TENANT`, else whatever owns your cwd (its git
  remote, then its path); never `--cwd`. Outside every tenant's tree, pass `--tenant`.
- **`--record <file>`** must already exist, must not be a file the secret guard protects, and
  must not be tracked by git, then or later: the tick asks again at every write, and a record
  that became tracked is not written, which escalates even a pass. So never a note in a repo that
  commits its notes, such as a handoffs repo; use a file outside every repo, or one its repo
  ignores. Each result goes before a `<!-- rabota-schedule-results -->` marker if the file has
  one, and at the end otherwise. The run never writes the record itself.
- **`--ask '<question>'` and `--option '<label>[=action]'`**, repeatable, are the decision
  @zvi is offered on any outcome but a clean pass. Write them now, while you hold the context.
  The label text is never executed; only the action after `=` is: `none` (the default),
  `rerun`, `rerun:+<n>m|h|d` (at most 30 days) or `cancel-followups`. A label may not contain
  `=`. `--option` needs `--ask`. Without options, the escalation offers *acknowledge*,
  *re-run now* and *cancel follow-ups*.
- **There are no recurring schedules.** A check that should repeat offers a `rerun:+24h` or
  `rerun:+7d` option, and @zvi picks it.
- **At most 2 command runs run at once per tenant**; a due run past that waits for a later tick.
  A wait is not an attempt.

## Refusals (exit 3) and what to do

- **`rabota-schedule@<tenant>.timer is not enabled`.** Nothing was stored and no id exists. Tell
  @zvi, and hand over the exact `add` line, with its script and record left where it names them,
  to run once the timer is armed. The refusal comes last, so the declaration is otherwise valid.
  Never arm the timer yourself: enabling it is his step.
- **Anything else** (a past `--at`, a horizon over 30 days, a tracked or guarded record, a
  `--cwd` holding the state directory, a script that invokes `claude`, a timeout over 6 h)
  names what failed. Fix the declaration. Usage errors exit 2.

## Read the results (the next agent)

- `rabota --text schedule list` for this tenant's runs, `rabota schedule list --status done`
  (or `pending`, `running`, `failed`, `expired`, `cancelled`), `--all-tenants` for every tenant.
- `rabota schedule show <id>`: the whole declaration, `status`, `outcome`, `last_reason` (a
  deferral says why) and whether the frozen payload is intact.
- The record file, and `rabota --text escalations --open`.
- `rabota schedule cancel <id>` cancels a run that is still `pending`.
- Never run `rabota answer`: answering an escalation is @zvi's. Never run
  `rabota schedule tick`: that is the timer's. Never start, stop or enable the units.

## Hand it over

Tell the user the run's id, its due and expiry times, its record, and the question it will ask.
That replaces the prompt you would have written for them to paste. Only a refused `add` (a
disarmed timer) still hands over a line, and it is the `add` line itself.
