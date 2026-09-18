# Repo checks: the CI guards, and what reviewing them taught

The evidence behind the CI and checker rules in [CLAUDE.md](../CLAUDE.md): the `apt-get update`
outage and the guard written for it (DO-608), the seventeen defects three review rounds found in
that one checker under a fully green state table, why it now parses YAML with a YAML parser, and
the mutation-testing rounds — including what their numbers did and did not measure.

> **Moved verbatim from CLAUDE.md on 2026-09-18 (DO-626), from the tree at `95568ae`.** Nothing
> was rewritten, so "this file" below means CLAUDE.md, and "above", "below" and "N sections up"
> refer to its layout at that commit; `git show 95568ae:CLAUDE.md` restores the context. **Add new
> evidence here, not to CLAUDE.md** — the rules stay there, the evidence lives here.

---

## CI/CD Testing

GitHub Actions runs: ShellCheck, syntax validation, YAML validation, pre-commit hooks, installation tests (Ubuntu 22.04/24.04), security scans, and documentation checks.

**Run locally:**
```bash
pre-commit run --all-files    # All checks
bash -n install               # Syntax check
shellcheck -x install         # Lint
act -j shellcheck             # Run specific CI job locally (requires act)
```

See `.github/README.md` for details.

**`apt-get update`'s exit status is not evidence about the job running it (DO-608).**
It exits non-zero when **any** configured source errors, and the runner images ship
third-party lists (Google Chrome, Microsoft Edge) that no job here reads. On 2026-09-09
Google's repo served a `Packages.gz` that did not match its own `Release` file, and ten
steps shaped `sudo apt-get update && sudo apt-get install -y …` took **11 of 20 jobs red
for ~40 minutes on every branch** — then hid a genuine `Pre-commit Hooks` failure for a
day underneath the noise. Measured against a fixture repository (root-free — `Dir::Etc`,
`Dir::State` and `Dir::Cache` redirected into a temp tree): a source whose `Release`
advertises a `Packages` hash it does not serve gives `E: … Hash Sum mismatch` and **exit
100**, while a healthy source configured alongside it **still lands its index and its
package stays a valid install candidate**. So the install was always possible; only the
gate failed. An *unreachable* source is merely `W:` and exits **0** — a different class,
and the reason "it exits non-zero on a broken repo" is too coarse a summary to reason
from. All apt installs now go through `.github/actions/apt-install`, which holds that
reasoning once, warns via `::warning::` when the refresh reports errors, and keeps the
**install** strict — so a genuinely broken Ubuntu archive still fails the job, loudly.
Two alternatives were rejected for reasons this file already records elsewhere: dropping
`google-chrome.list` names one vendor and leaves the next third-party repo fatal, and
`-o Dir::Etc::sourceparts=/dev/null` would silently drop the **main** archive on Ubuntu
24.04, where it lives in `sources.list.d/ubuntu.sources` — a pathspec that matches
nothing narrowing a check invisibly.

Traps in the guard written for it, every one of which reported success. They are
listed because the guard was **29/29 green over all of them at once** — an
independent review reproduced seven live defects against a fully passing suite,
which is the "rows that check the plumbing and not the answer" case this file
already records, met at scale:

- **The rule matched the literal string `apt-get <verb>`**, so `sudo apt update
  && sudo apt install -y zsh` — the spelling people actually type — and
  `sudo apt-get -qq update && …` were invisible to every rule. Program and verb
  are matched separately now, with word boundaries so `aptitude` and `adapt` stay
  out.
- **Asking whether `&&` is absent asked about the MECHANISM.** Four regressions
  *inside the composite action* — the one file that runs apt, and the one the
  workflow-scoped rules never inspect — all printed `all 6 checks passed`:
  `set -euo pipefail` plus a bare refresh (a complete restoration of the outage,
  and what "hardening" looks like to the next person), `update -qq &&`,
  `update || exit 1`, and `update; install`. Three contain no `&&` at all, so no
  tightening of that token could ever reach them. The rule is now the positive
  form — every refresh must sit in a construct that cannot fail its step (an
  `if` condition, or an explicit `|| true`) — because GitHub runs a composite
  `shell: bash` step as `bash --noprofile --norc -eo pipefail`, so a bare refresh
  is fatal whether or not the script says `set -e`, which is also why scanning
  for `set -e` would be the wrong test.
- **`… | grep -q PAT && var=…` under `set -o pipefail` is a RACE**, and it loses
  most often on the files you care about. `grep -q` exits at its first match; if
  `sed` still has output pending it dies of SIGPIPE and pipefail fails the
  *pipeline*, so a matched pattern reads as *no match*. Measured: 0 in 30/30 runs
  at 27 KB, 141 in 30/30 at 289 KB, and `ci.yml` at 29 KB missing its own ten
  violations in **13 of 20 runs**. This is the SC2015 family, one layer down.
- **Line-based quote stripping hid real violations two ways.** Two apostrophes
  inside *separate* double-quoted strings paired with each other and swallowed
  the command between them; a `#` inside a quoted string truncated the line.
  Both are ordinary shell. The stripper is character-by-character and
  quote-aware now, and after the fix it removes exactly what a shell would treat
  as quoted — so anything it hides was never going to run as a command.
- **YAML prose is not shell.** A step whose `name:` named the forbidden shape was
  reported as three violations *while correctly using the action*, with a remedy
  telling the reader to do what they had already done; the action's own
  `description:` failed the refresh rule the same way. Matching is scoped to
  `run:` scalars now. A checker that refuses a correct workflow gets deleted —
  the permanently-red failure this file records five times.
- **An empty answer was agreement, twice.** The `${{ }}` rule extracted the run
  block with `awk` and grepped it, so a one-line or folded `run:` yielded an
  *empty* extraction that read as "no interpolation" — a tick over the exact
  injection it forbids. It is a positive-form count now (every `${{` must be an
  `env:` assignment) with no empty case. Separately, `ACTION_REL` hardcoded
  `action.yml`, so renaming to the equally-valid `action.yaml` printed a false
  "is missing" **and silently dropped the check count from 6 to 4** — two
  assertions never ran and nothing said so. Both extensions resolve now, and a
  fixed `EXPECTED_CHECKS` makes a run that performed fewer checks than expected
  a failure in itself.
- **`apt-get install -y` with no operands exits 0**, so the "strict install"
  claim was hollow: `inputs.<id>.required` is advisory, the runner does not fail
  a step for a missing input, and `set -u` does not help because `PACKAGES` is
  set and merely empty. A job whose only package is preinstalled (`jq`) would
  have stayed green forever with the install switched off. The action refuses an
  empty or whitespace-only list now.
- **An unquoted expansion globs as well as splits.** The step's cwd is the
  checkout, so `packages: 'zsh*'` expanded against repository files — measured,
  it became `zsh-real` and apt failed naming a filename. A `*` is legal in apt's
  own patterns, so this needed no attacker. `read -ra` plus `-- "${pkgs[@]}"`
  splits without globbing and stops a package name beginning with `-`.
- **Two of the fixes were then unpinnable, and the fixture size was why.** The
  row for the SIGPIPE race used a ~20-line fixture, far too small to trigger it,
  so reinstating the bug passed the suite; and once the racing code was gone the
  oversized replacement fixture cost **205 seconds per check**, because the first
  version of the shell-scoping helper forked `awk` once per line. The helper is
  one `awk` pass now (2.4 s on the same 560 KB input) and the race is pinned at
  the source instead — the checker must never pipe into `grep -q`, which is
  deterministic and free, where a behavioural row could only be probabilistic.
- **A fixture built by a `python3` heredoc goes quiet when `python3` is absent.**
  The row then asserted its expected exit code against an *unmodified* fixture
  and passed for a reason unrelated to the rule — no error, no skip. Rebuilt
  with `sed`, plus an assertion that the edit applied. This is the class this
  file already records for `verify-tools.sh`: a new external tool in a checker is
  a new way for a check to go quiet.

State table: `scripts/test-workflow-apt.sh` (112 checks, in CI as
`workflow-apt-test`) over `scripts/check-workflow-apt.sh`. Hermetic — every row
builds its own fixture tree and is handed an explicit root; only the last rows
read this repository, to assert the shipped tree passes. Most rows assert what it
must **not** flag, because a false positive costs the whole check while a miss
costs one outage: a comment naming the forbidden line, a commit message
mentioning it, an unquoted YAML `name:` describing it, `aptitude`/`adapt`, a
quoted `env:` value, and a mid-word `#` all have to pass. "Could not run" is exit
2, never a pass, and the suite asserts its own total so a row that VANISHES —
an emptied `for` list, an early exit in a fixture builder — fails rather than
shrinking the denominator under a cheerful "all N passed".

Be precise about what those count guards do and do not see: they count reported
checks, so they detect a check that was **skipped** and never one that was
**hollow**. Every defect listed above kept the count at exactly six while
printing six ticks over a hidden violation. A rule that stops being *reached* is
invisible to them, which is why the rows above are what actually hold this
guard up.

- **A file-extension clause no fixture exercised was decoration, twice.** Every
  fixture wrote `ci.yml`, so `-o -name '*.yaml'` was unpinned in both finds —
  and with it removed, a violating `release.yaml` was invisible while the suite
  stayed green. GitHub accepts either extension; the only reason the repo was
  safe is that nobody had named a workflow `.yaml` yet. Worse, a hardcoded
  `action.yml` had been *accidentally* covering the same gap for the action
  (it reported "is missing"), so accepting both extensions removed a fail-safe
  nobody had chosen — which is exactly why the extension now has a row instead
  of an accident. The narrowing that IS deliberate — `-maxdepth 1`, because
  GitHub does not read nested workflow files — has its own row saying so, and
  the refresh rule was rescoped to agree with it rather than scanning every
  YAML under `.github` and disagreeing with the rules beside it.
- **Both halves of a two-state stripper need both directions.** The rows
  covered double quotes only, so deleting the single-quote branch survived
  while false-positiving on `git commit -m 'stop apt-get update failing CI'` —
  the more natural spelling of the two. Each state now has a must-pass row and
  a must-catch mirror.
- **The one path a human takes was executed by nothing.** Every row passed an
  explicit root, so the default `git rev-parse --show-toplevel` branch — what
  you get typing the script's name with no argument — had no coverage, and
  making its exit code 0 survived the suite.

**The guard now parses YAML with a YAML parser, and that is the finding.** Three
independent review rounds found **seventeen** defects in this one checker, every
one of them under a fully green state table. Rounds one and two were fixed by
patching. Round three found eight more, six of which were the same kind of thing:
`run: |  # refresh, then install` is valid YAML but a comment after the block
indicator meant the hand-written awk parser never opened the block, dropped the
whole script and silenced **three rules at once**; a step's sibling keys are
indented deeper than the `- ` of `- run: |`, so they were read as block body and
a `name:` describing the forbidden shape became a false violation; a multi-line
string's continuation lines were scanned as unquoted shell because quote state
reset per line; CRLF broke block detection the same way; and the install-strict
check read the whole file, so an unquoted `description:` mentioning
`apt-get install -y` satisfied it while the action installed nothing.

The pattern, not the bugs, is the lesson: **those are YAML questions, and each
round of patching produced a new way to answer one wrongly.** `scripts/gha-yaml-shell.py`
now hands the checker the shell of every `run:` scalar and the placement of every
`${{ }}`, using PyYAML. Six defects stopped being reachable rather than being
fixed. What remains is genuinely shell-level — operator position, apt's option
forms, heredoc bodies — and lives where it belongs.

The dependency is deliberate and it cannot go quiet: PyYAML missing, a file
unreadable, or YAML that does not parse all exit **2**, and the CI job installs
`python3-yaml` through this repo's own composite action. That matters because
this repo already records what a quiet dependency costs a checker, and the first
version of the very code enforcing it had the bug it was written against — the
helpers ran inside `$(...)`, so their `exit 2` exited the *subshell* and the
parent read zero records as "this file contains no shell", passing an
unparseable workflow clean. Status is tested in the parent now. `require_emitter`
was also **defined and never called** for a while, which no linter here catches.

Two smaller things worth keeping from the same round. **`grep` is not GNU grep
everywhere** — on this machine it resolves to a `ugrep` shim, which rejected a
`grep -P` pattern the CI runner's GNU grep would have accepted; the matching is
awk now, which this checker already depended on. And **a fixture can be wrong in
a way only a real parser reveals**: a row asserting that a `#` inside a quoted
string must not truncate the line used `- run: echo "tag #1" && sudo apt-get
update`, where ` #` opens a *YAML* comment — so the value is `echo "tag` and apt
never runs at all. The hand parser had been flagging a line GitHub would not
execute, and the row encoded that mistake. It needs a block scalar to mean what
it says.

**The mutation figures across three rounds, with the set beside the ratio,
because the ratio alone is what misled the first time.** An independent reviewer
grew the set each round specifically into rules that had no rows — the only way
the number means anything: **27/8 at `133cc91`, 31/12 at `e4bb8f3`, 36 mutants
with 27 killed and 9 survivors at `e381571`.** The set covered the file finds,
every branch of the shell scoping, all three copies of the quote stripper,
`apt_re`, the refresh-fatality rule and its excuse-path, the interpolation rule,
the count guards, and two mutations of `action.yml` itself.

**Every figure carries the commit it measured, deliberately.** Each of those
three trees is now several commits stale, and a ratio without its commit reads
as the suite's current coverage to anyone who finds it later. The round after
`e381571` was abandoned part-way — 16 of 34 measured, 10 killed, 6 survived, 18
never run, after the OOM watchdog killed the sweep three times on a box at
loadavg 66 and 21.6 GB of 23.7 GB swap. **That partial is deliberately not
recorded as a coverage figure**: a partial denominator quoted as a result is the
same shape as the "9 mutants, 9 deaths" claim this section exists to retract.
The reviewer said so about their own number before I could, which is the right
instinct to copy.

Two things about those numbers matter more than their size. **Every survivor of
the last round kept the check count at exactly six**, which is the evidence for
the honest label on the count guards above — a guard green over 9 of 9 of a
round's real defects is worth having and must not be described as coverage. And
**five of the nine clustered in the newest code**, the hand-written parser,
which is what decided the rewrite rather than a fourth round of patching. The
figures above are for the awk implementation; the parser rewrite came after
them, so no re-run has yet measured what shipped — recorded as unmeasured rather
than assumed to be better.

**The parser rewrite then produced a defect of its own, and the row written for
it was green BECAUSE of it.** `_heredoc_marker` read the delimiter from the
already-quote-stripped line, so `cat <<'EOF' > note.txt` — the *more* common CI
spelling — stripped to `cat << > note.txt`, whose "delimiter" was `>`. Nothing
later matched it, the heredoc never closed, and **every remaining line of that
run script was dropped**: `all 6 checks passed` over a complete restoration of
the outage. `mask=$(( 1 << 3 ))` did the same on `3`. The single heredoc row
asserted rc=0 and passed *in virtue of the defect* — it could not distinguish
"bodies are data" from "everything after is silently gone", which is why a
mutant making the end-marker never match survived it.

Three things fixed it and are worth stating as rules: read the introducer from
the **raw** line, inside the scan where quote state is known, so a quoted
delimiter works and a `<<` inside a string is not one; require a delimiter to
**look** like a delimiter (`[A-Za-z_]\w*`), which is what stops arithmetic
opening one; and treat an **unterminated** heredoc as exit 2 rather than
reporting the lines before it as the whole script. The discriminating row is a
real gate placed *after* the `EOF`, asserting that scanning **resumes** — the
row that existed asserted only that the body was ignored, which the defect also
satisfied.

**Two more from the round after that, both in the dependency handling and both
about caching or shadowing rather than logic.**

**`arr[k]=$(cmd)` creates the element even when `cmd` fails** — only the
statement's status is non-zero. So memoising the parser output cached a FAILED
run as a successful EMPTY result: the first call returned 2 and every later call
for that file returned empty with status 0, turning "could not read this file"
into "this file has no shell" — in the helper whose own comment warns about
exactly that. It was masked only because the first caller exits immediately, so
it was a loaded gun rather than a live outage, and it was found by a reviewer
reading the bash semantics rather than by any fixture. Assign to a local first
and populate the cache only on success; the behavioural row calls the helper
twice for a failing file and asserts 2 both times.

**Guards that shadow each other are individually unpinnable.** All four
`|| die_unreadable` call sites survived deletion, because every fixture that
reaches one reaches an earlier one first — and deleting two of them *together*
gave `all 6 checks passed` on an unparseable workflow. Each now has a fixture
whose broken file only that call site reads: a malformed non-workflow YAML under
`.github` for the refresh rule, and an unreadable action file (workflows intact)
for the install and interpolation rules. **The general rule: a row that deletes
one guard proves nothing while another guard upstream can answer for it — count
how many independent deletions it takes to reach a silent pass, not how many
guards exist.** An unreadable file is also a different emitter branch from
unparseable YAML (`OSError`, not `YAMLError`) and had no row at all.

**The cheap half of review outlives the expensive half.** Four gaps in that
round were found by *grepping the suite* rather than by mutation — no CRLF
fixture, no unreadable-file row, no row invoking the parser directly, no
multi-document fixture — and those findings survived four commits of churn,
because they are properties of the suite's text rather than of one tree's
behaviour. Re-checking them at a later commit is a grep; re-running the mutants
is an hour of load. Two were already closed by then and two were real: the
multi-document row is pinned (a single-document walk drops the second document
and the row dies), and **there is deliberately no CRLF row** — measured with the
emitter's `\r` strip removed, a CRLF workflow carrying a gate still exits 1 and
a CRLF action with a tolerant refresh still exits 0, because these patterns
accept a carriage return anyway. The property is protected twice, so no fixture
can distinguish the strip being present from absent. Knowing why a row is
impossible is worth more than having one that always passes.

Recorded and deliberately NOT acted on: the suite went from ~15s to ~62s idle as
it grew to 109 checks, one python start per uncached file per fixture. Combining
the emitter's two modes into one invocation would roughly halve it. It is left
alone because every round of this change has introduced a defect of its own, and
a performance edit is the one kind that cannot fix one — the measurement is here
so the next person can decide with the number in front of them.

Three lessons from that round that generalise past this guard:

- **A `contains` needle must be unique to the RULE, not merely absent from the
  pass path.** Three of this checker's rules print `<file>:<line>` in the same
  format, so a bare path needle is ambiguous by construction: one row passed
  with the verb rule's filename deleted, satisfied by the refresh rule's
  message instead. Anchor on the message prefix.
- **Check the needle against what the PASS path prints.** The interpolation
  rule's ok and bad messages both contain "env: assignment", so that needle
  asserted nothing at all.
- **A row whose fixture fails for more than one reason is decoration however
  carefully worded.** Two rows added for the parser exit 1 from the
  install-strict rule whether or not the property under test holds; only a
  rule-specific `contains` makes them able to fail, and one of them shipped
  without one.

**On the mutation numbers, which is the part worth carrying forward.** An earlier
version of this section claimed "9 mutants, 9 deaths" for this guard. That was
true and meaningless: the set only mutated rules that already had rows, so it
measured nothing about the rules that had none — and the suite it certified was
simultaneously green over seven reproduced defects. A mutation set assembled from
the code you happen to have tested is a mirror, not a check. **Ask of the
mutation set what you already ask of a row: what would it fail to notice?** The
current set is rebuilt against the rewritten matching core, and the honest figure
is whatever an independent re-run reports — recorded when it does, not asserted
here in advance.
