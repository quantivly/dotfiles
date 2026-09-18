# The broadcast-kill audit tripwire

The maintainer's record behind the **Audit Tripwire** rules in [CLAUDE.md](../CLAUDE.md): why a
`kill(-1, sig)` on this machine leaves no evidence without it, why the `a0` constant must stay 32
bits, and the three independent things "armed" means — each of which can be false while the other
two look fine.

> **Moved verbatim from CLAUDE.md on 2026-09-18 (DO-627), from the tree at `18c70fb`.** Nothing
> was rewritten, so "this file" below means CLAUDE.md, and "above", "below" and "N sections up"
> refer to its layout at that commit; `git show 18c70fb:CLAUDE.md` restores the context. **Add new
> evidence here, not to CLAUDE.md** — the rules stay there, the evidence lives here.

---

## Audit Tripwire (broadcast kills)

A two-line **auditd** rule that records any real `kill(-1, sig)` — *"signal every
process I may signal"*, which on a desktop is the entire graphical session. This
machine runs many parallel agent sessions with shell access, and a broadcast kill
produces a perfectly orderly teardown: no crash, no OOM, no coredump, nothing in
the journal explaining it. Without the rule there is no evidence to find; with it
the record names the sending process, exe, cmdline and parent.

- **Source of truth:** `audit/99-logout-catch.rules`. **Copied** root-owned to
  `/etc/audit/rules.d/` by `audit-setup` — never symlinked, same reasoning as
  `resticprofile/profiles.toml` (root's auditd reads it).
- **`a0` must stay `0xFFFFFFFF`, never widened to 64 bits.** Audit's rule field is
  u32, and on x86-64 a C `int` of `-1` is passed via `mov edi,-1`, which
  zero-extends — the kernel sees `0x00000000FFFFFFFF`. A 64-bit constant matches
  nothing, and a rule that matches nothing is indistinguishable from a clean
  machine. `a1!=0` drops signal-0 probes (error-checking only, sends nothing).
- **auditd takes AppArmor denials out of the journal.** After install,
  `journalctl -k | grep apparmor` returns nothing — use `sudo ausearch -m AVC`.
  Relevant to the snap/`unprivileged_userns` notes above.
- **"Armed" is three independent things**, and each can be false while the other
  two look fine: the rules are in the kernel (`auditctl -l`), auditing is switched
  on (`enabled != 0`), and **a daemon is persisting records to disk** (`pid != 0`).
  Rules live in the *kernel*, so `auditctl -l` lists them happily with auditd
  stopped — but then records go to the kernel ring buffer instead of
  `/var/log/audit/audit.log`, and `ausearch` (so `audit-sweeps`) is blind forever
  with no error. `audit-setup` and `audit-status` both assert all three.
- **Silent-failure modes** (`audit-status` reports each as its own failure): a
  rejected rule field leaves *zero* rules loaded with no error; auditing switched
  off; no daemon registered; a climbing `lost` counter dropping records;
  `/etc` drifted from `~/.dotfiles` (the file is *copied*, so editing the repo
  copy alone changes nothing); and `disk_full_action`/`admin_space_left_action`
  are `SUSPEND`, so auditd stops logging quietly if `/var` runs low. Each
  otherwise looks exactly like "nothing bad happened".
- **Scope: `a0 == -1` only.** `kill(0, sig)` ("my whole process group") is a real
  hazard but shells issue it routinely, so a rule would be noise; `kill(-pgid,
  sig)` isn't expressible statically. `-1` is the one that can only ever be a
  session-wide broadcast. See the rules file for the full reasoning.
- Expect a benign burst from `systemd-shutdown` (pid 1) at every reboot.

Commands: `audit-setup` (add `--yes` to skip the auditd install prompt),
`audit-status`, `audit-sweeps`.
