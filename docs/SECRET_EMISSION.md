# Keeping secrets out of transcripts: the emission guard and the redactor

The maintainer's record behind the **secret-emission** rules in [CLAUDE.md](../CLAUDE.md): the
2026-09-01 audit that found both live GitHub tokens in five session transcripts, why rotation is the
wrong loop to optimise, and the two pieces written to attack the emission instead — with every hole
since found in them, including one the guard's own suggested remedy did not remedy. This page is
about **preventing** an emission; if a secret has already been committed, the cleanup runbook is
[SECURITY_INCIDENTS.md](SECURITY_INCIDENTS.md).

> **Moved verbatim from CLAUDE.md on 2026-09-18 (DO-627), from the tree at `18c70fb`.** Nothing
> was rewritten, so "this file" below means CLAUDE.md, and "above", "below" and "N sections up"
> refer to its layout at that commit; `git show 18c70fb:CLAUDE.md` restores the context. **Add new
> evidence here, not to CLAUDE.md** — the rules stay there, the evidence lives here.

---

## Keeping secrets out of transcripts

**Everything a command prints is recorded, and that is where the credentials went.** An
audit on 2026-09-01 found *both* of this machine's live GitHub tokens in plaintext in five
Claude Code session transcripts — two written days earlier, matched by SHA-256 against the
live values, so not a historical artifact. Transcripts are conversation context, so those
values had also left the host.

No single dramatic mistake produced this. Ordinary diagnostics do it: `ps` showing a
process launched with `-e GH_TOKEN=…`, a `printf` of `$GH_TOKEN`, a bare `gh auth token`.

**Rotation is the wrong loop to optimise.** For GitHub it is browser-only — `gh auth` has
no `revoke`, `/authorizations` and `/applications/grants` are 404 (the API was removed in
2020), and the endpoints that can revoke need the OAuth *app's* client secret, i.e. you
would have to be GitHub. `gh auth logout` looks like rotation and is not: it drops the
local copy while the leaked value stays valid. So rotation is manual, and it does nothing
about the next capture.

Two pieces attack the emission instead:

- **`scripts/redact-secrets.sh`** — a stdin→stdout filter. **Two rules, because either
  alone leaks.** Shape matching (`gho_…`, `sk-ant-…`, `AKIA…`) finds a credential anywhere,
  including bare in prose, but cannot know that `CLAUDE_CODE_MESSAGING_TOKEN=b7dc…` is a
  secret — 32 hex characters is also every short git SHA. Name matching (`…TOKEN=`,
  `…SECRET=`) catches those in the `VAR=value` shapes an env dump produces, without
  false-positiving on arbitrary hex. That gap was found by running the pair against a real
  `printenv` and seeing what survived.
- **`claude/hooks/secret-emission-guard.sh`** — a `PreToolUse` hook (matcher `Bash`) that
  **refuses** the handful of command shapes that print credentials unless piped through the
  redactor: `gh auth token`, `gh auth status --show-token`, `ps` with full command lines,
  `pgrep -a`, a bare `env`/`printenv`, and reads of `/proc/*/cmdline|environ`.

Design decisions that are load-bearing, not preferences:

- **Deny, not ask.** The remedy is mechanical (append `| redact-secrets`), so a prompt
  would only train the human to click through — and an `ask` on commands an agent runs
  constantly makes the guard the most irritating thing on the machine.
- **Fail open, always.** Bad JSON, no `jq`, an unreadable payload, *or the hook file not
  being deployed yet* — all allow. A hook that breaks the shell when it breaks gets
  disabled wholesale, taking its protection with it. The registration in
  `~/.claude/settings.json` carries its own `[ -r "$f" ]` guard for exactly this: the file
  arrives via dotbot, so it is absent whenever the checkout is mid-deploy or on a branch
  without it, and registering it without that guard put `exit 127` on **every** Bash call
  in every session on the box until it was fixed.
- **Most of the state table asserts what it must NOT block.** `ps -o comm=`,
  `env -u GH_TOKEN … gh api user`, `printenv GH_CONFIG_DIR`, and
  `git commit -m "stop ps aux leaking"` all have to pass — quoted strings are stripped
  before matching so a command that merely *mentions* a shape is not refused. A false
  positive costs the entire guard; a miss costs one redaction.
- **It is a papercut guard, not a boundary.** Any command can print a secret and this knows
  about seven shapes. The real fixes are shorter-lived credentials (a fine-grained PAT with
  an expiry, so a leak decays on its own) and narrower scopes — both `gh` tokens here carry
  `admin:public_key`, the scope that lets a leak plant an SSH key surviving revocation.
- **Every original rule caught a command printing a secret it FETCHED; none caught one
  printing a FILE — and this file's own Security Rules send every secret to
  `~/.zshrc.local`.** So the guard covered every emission shape except the documented home
  of all of them. On 2026-09-07 an agent ran `tail -8 ~/.zshrc.local` to find where to
  append a `pathadd` line; the tail of that file held a live `LINEAR_API_KEY` and a
  `NOTION_PAT`, both reached the transcript, and both had to be rotated — the same class as
  the incident that created the hook, six days later. The rule added for it fires on
  `~/.zshrc.local`, `~/.gitconfig.local`, `~/.backup.local` and `~/.claude/.credentials.json`
  and **needs two conditions, whose split is the whole design**: the PATH matches on the raw
  command (`$probe` has quoted strings stripped, so `cat "$HOME/.zshrc.local"` — the most
  natural spelling — would escape a `$probe` match), while the VERB matches on `$probe`.
  Path-alone on the raw command refuses `git commit -m "move flyctl to ~/.zshrc.local"`, a
  message merely *naming* the file, which is the false positive that costs the whole guard.
  Metadata-only commands (`ls`, `stat`, `test -f`, `wc`, `readlink`) print no content and are
  deliberately not verbs. A `python3` heredoc that opens the file is not caught either: it
  prints nothing by default, and refusing it would block ordinary edits to the very file
  people are told to keep their secrets in.
- **The remedy the guard names did not remedy.** Immediately after the rule above shipped,
  running its own suggested `tail ~/.zshrc.local | redact-secrets` against the real file
  printed the `NOTION_PAT` in full. `NOTION_PAT` matched no name pattern (the alternation is
  `TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|CREDENTIAL`) and `ntn_` matched no shape pattern, so
  it fell through both rules — the exact case the redactor's header says two rules exist to
  prevent. **Worse than a plain miss:** the deny message points at the redactor, so the
  failure mode is guard blocks, human adds the pipe, token prints anyway, and it looks
  handled. Fixed by `ntn_` and `lin_api_` shape rules plus a `_PAT=` name rule. That last one
  is its OWN `-e`, never an entry in the alternation: the alternation is followed by
  `[A-Z0-9_]*=`, so any PAT inside it has the trailing class absorb what follows and redacts
  `SOME_PATH=`, `MY_PATHS=` and `COMPATIBLE=` (measured, both for `PAT` and `_PAT`). `PATH=`
  and `PATTERN=` are safe for a different reason — the `=` adjacency — and only a rule
  allowing PAT anywhere before the `=` reaches them. Six mutations, all pinned; the reasoning
  above was wrong on first writing (it blamed `PATH=` for what actually breaks `SOME_PATH=`)
  and the state table is what corrected it.
- **The quote-stripping has a hole of its own, found the same day and NOT fixed.** A heredoc
  body is not a quoted string, so a command whose heredoc merely *quotes this guard's own
  source* trips the `/proc/*cmdline*` rule — which happened while editing the guard, and the
  workaround is the documented one (pipe through the redactor). Worth knowing before assuming
  a refusal means the command really would have leaked.
- **A credential with no distinctive shape is invisible to the redactor AT REST, and that is
  not a bug in it.** Its name rules are anchored on real whitespace and terminated on real
  whitespace; inside a `.jsonl` transcript the newlines are escaped `\n` within a JSON string,
  so the anchor never matches — and the terminator would swallow the rest of the line, so
  loosening the anchor alone would mangle transcripts rather than redact them. Both ends are
  wrong for that grammar, which is why the file-at-rest job is a separate tool
  (`scripts/scrub-transcript-secrets.py`, on a nightly timer) rather than another `-e` here.
  Found 2026-09-23, when a `SONIOX_API_KEY` survived in a transcript while the GitHub and
  Linear keys beside it were caught by shape. The audit, the scrub and the cadence:
  [TRANSCRIPT_SCRUB.md](TRANSCRIPT_SCRUB.md).

**`.gitignore`'s `**/*secret*` rule excluded all three of these files**, whose entire job
is secrets — and `git add -A` skips ignored paths **silently**, so `git commit`, `git push`
and `gh pr create` all reported success with the content absent. Only CI caught it, via
`No such file or directory` on the test script and dotbot's `Nonexistent target` on the
hook. Three negations after the rule fix it (`!scripts/redact-secrets.sh` etc.), and the
check that matters is `git add --dry-run`, not `git check-ignore -v` — the latter exits 0
when a path matches *any* rule, negations included, so it reports "matched" for a file that
is not ignored at all and reads as the opposite of the truth.

**Like the sidebar publisher, `./install` only does half.** dotbot puts the hook file in
`~/.claude/hooks/`; it does nothing until it is also registered as a `PreToolUse` hook in
`~/.claude/settings.json`, which is user-level and not in this repo.

State table: `scripts/test-secret-guard.sh` (192 checks, run in CI, hermetic — the fixture
credentials are assembled at runtime so this file contains no string that would trip the
`gitleaks` pre-commit hook over its own test data).
