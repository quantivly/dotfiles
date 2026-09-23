# Retired

Things this repository deliberately stopped carrying, and why.

**This page is the sanctioned way to remove something, not a graveyard.** CLAUDE.md's routing
table ends with *"a rule whose condition can no longer fire — **retire it — do not extract it**"*,
and `scripts/check-doc-tokens.sh` is built around that: it asserts that prose leaving `CLAUDE.md`
was **moved** rather than deleted, and a line here naming the token resolves it. That is a
reviewable record rather than a bypass flag, so a deletion still has to be argued in a diff
somebody reads.

An entry is one line: `<ticket> / <date> / <token> / (<PR>): <why it can no longer fire>`, with
the reasoning underneath when it needs more than a clause.

- DO-705 / 2026-09-23 / `scripts/test-gpg-installation.sh` / (#51 orphaned it): the three
  scripts it tests do not exist.

  DO-264 (#51, 2026-01-28) migrated this repo from GPG to SSH commit signing and deleted seven
  files in one commit — `scripts/gpg-prime-cache`, `scripts/git-check-gpg-cache`,
  `scripts/install-gpg-hooks`, `config/git/hooks/pre-commit`, `zsh/zshrc.gpg-reminder`,
  `docs/GPG_SIGNING_SETUP.md` and `examples/gpg-setup-guide.md` — along with the `gpg-prime`
  alias and the `install.conf.yaml` symlinks. It did not delete the suite that tests them, and
  nothing has referenced that suite since: no CI job, no documentation page, no script. Run by
  hand it exits at its first assertion, `✗ gpg-prime-cache missing`, and had been doing so
  unnoticed for eight months, because **nothing ran it**.

  Repairing it would mean restoring three deleted scripts to satisfy a test — reverting a
  deliberate migration in order to make an assertion pass. Wiring it into CI would mean wiring
  in a permanently red job, which this repo has recorded getting deleted, along with whatever it
  protected, seven separate times.

  It was found by `scripts/check-state-table-totals.sh` on the run that introduced that guard,
  as one of the files with no row total. **Giving it a row total instead would have been the
  guard's first false green, written by the person who built it** — a suite that cannot reach
  its second assertion does not need a count of the rows it never runs. SSH signing is the
  supported path and its guide is [SSH_SIGNING_SETUP.md](SSH_SIGNING_SETUP.md), which documents
  GPG as a deprecated alternative for anyone who still needs it.
