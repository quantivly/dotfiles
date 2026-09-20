# DO-635 — Run Agent Sessions on dev: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Where this lives:** approved in plan mode, then saved verbatim to
> `docs/superpowers/plans/2026-09-19-do-635-dev-box-offload.md` in the DO-635 worktree
> (`docs/superpowers/*` is exempt from the reachability guard, `scripts/check-claude-md.sh:350`).
> Each **Part** below becomes one Linear issue (§5). DO-635 does not grow.

**Goal:** Quantivly agent work that needs none of the laptop runs on `dev`, billed to dev's own seat (`quantivly-0`), so the laptop stops carrying it.

**Architecture:** Dev already runs its own herdr server and holds its own quantivly-0 login. The laptop drives it through herdr's native machine view (`dev (EC2)` is already saved). The work is:

- make git on dev work with no agent (**A**), and deploy and wire dev (**B**);
- close the one door through which the laptop spends dev's seat (**C**);
- give agents a single narrow way to start sessions on dev (**D**);
- stop dev-setup from reintroducing the git defect (**E**).

**Tech Stack:** zsh (`zsh/zshrc.herdr`), bash (scripts, hermetic state tables), herdr 0.9.0 + herdr-draft, systemd --user on dev (systemd 249, `memory` delegated), gh's HTTPS credential helper.

**Spec:** this document's §1–§4 (the survey and the decisions), plus rabota's
`~/quantivly/handoffs/rabota-v2/2026-09-16-rabota-v2-design.md` §2.2 and §C9,
`2026-09-16-consolidation-design.md` §1.1, and `plans/WS6-remote-dev.md` §6.3, which this plan
supersedes in part (§5 note).

## Global Constraints

- **Nothing personal or toysim reaches dev.** No `personal-*`/`toysim-*` profiles, no `gh-personal`, no `~/.dotfiles-local` there (rabota F4). Dev is work-only by its own policy (`~/.ssh/WORK_INSTANCE_SETUP.md`: "Do NOT clone personal (ZviBaratz) repositories on this host").
- **Never `git config --global` on dev.** `~/.gitconfig` there is a symlink into the tracked, public `~/.dotfiles/gitconfig`. Machine settings go to `~/.gitconfig.local` (`git config --file ~/.gitconfig.local …`).
- **Every write on dev, to `~/.claude/settings.json`, to `~/.dotfiles-local`, and every Linear filing, needs Zvi's typed OK.** Agents prepare and print the exact command, then wait.
- **Non-interactive `ssh dev` has no `~/.local/bin` on `PATH`.** Remote commands set `PATH="$HOME/.local/bin:$PATH"` or use absolute paths. Prefer `ssh -o BatchMode=yes dev 'bash -s' < script` over nested quoting.
- **Never `zsh -ic` on dev except where a step says so.** Dev's interactive startup repoints `~/.ssh/ssh_auth_sock` (agent auto-repair).
- **Restart herdr only with `systemctl --user restart herdr-server.service`**, never from a pane or a Claude session (CLAUDE.md).
- **Never close panes, kill sessions or reap work you did not create.** The two live `clauth start quantivly-0` sessions on the laptop end on their own.
- New guard → hermetic rows plus a mutation sweep (CLAUDE.md "CI/CD Testing"). Run `./scripts/check-claude-md.sh` before any commit touching CLAUDE.md; **remove as much as you add**.
- Commit trailer: `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`. Deploy with `merge --ff-only`, never `git pull`; never `git stash`.

---

## 0. Decisions taken (Zvi, 2026-09-19)

| # | Question | Decision |
|---|---|---|
| 1 | DO-635 vs rabota WS6.3 | **DO-635 owns the host.** WS6.3 shrinks to rabota-only items (python 3.11 pick, tenant config, wt-gc) and is rebased on Parts A+B, with its F10 step replaced by Part A |
| 2 | quantivly-0 on the laptop | **Keep the laptop's grant for monitoring; guard launches.** Refuse `clauth start`/`clauth <p>`/`claude-as`/`hspawn -p` for a profile another machine owns |
| 3 | What moves | **Headless lanes + autonomous attended quantivly sessions.** The console (quantivly-3) and anything needing the local GUI or laptop files stay local |
| 4 | Agents spawning on dev | **Yes, through one narrow allow rule**, on a wrapper whose inputs cannot reach the remote shell unquoted |

## 1. Context

The laptop (`cilantro`) is saturated: load 13.4 on 8 threads and swap 56% (DO-635), and three
places in this repo work around that. The *account* moved to dev on 2026-09-15; the *work* did
not. DO-635 asks what dev has, which lanes move, how lanes get repos and push PRs, how the laptop
drives dev, and what the seat policy is. The survey shows dev is mostly ready, that rabota
already decided most of this, and that dev's seat is being spent **from the laptop**.

## 2. Survey — what dev actually is (all measured 2026-09-19, read-only)

| Question | Command | Result |
|---|---|---|
| Size / load | `nproc; free -h; df -h /; uptime` | 16 cores · 61 GiB, **13 GiB available** · 192 G disk free · load `0.20, 0.29, 0.30` |
| RAM owner | `docker ps`/`docker stats` | **47 swarm services / 70 containers** (re-counted 2026-09-20; "~40" was low): **dev is the shared platform stack**, so an agent OOM here is a team outage |
| Tools | `zsh -lic 'whence -p …'` | claude 2.1.272 (laptop 2.1.278) · herdr 0.9.0 (= laptop) · mise 2025.12.12 · tmux 3.2a · gh 2.83.2 · Go 1.26.4 via mise · **no clauth** |
| Non-interactive `PATH` | plain `ssh dev 'command -v claude'` | `MISSING` (rabota F-finding confirmed) |
| Dotfiles | `git -C ~/.dotfiles …` | `main` @ `5905f7a` (09-16), **23 behind `origin/main` as it stood on 2026-09-19** (the count moves as `main` does; re-measure rather than expect 23), clean; config symlinked into it; has #146 (`claude()` safe without clauth) |
| herdr | `systemctl --user show herdr-server` | active since 09-15, `default.target` drop-in, `Linger=yes`, idle; pane shells run **inside `herdr-server.service`'s cgroup**, `MemoryMax=infinity`; user manager delegates `memory pids` |
| herdr-draft | `herdr plugin list` | installed at `baae1b4` (laptop checkout `4734e67`, which adds `create --dry-run`) |
| Claude login | `jq .oauthAccount ~/.claude.json` | quantivly-0 (`zvi.baratz@quantivly.com`, Team) from dev's **own** `/login` (5× on 09-15); last refresh **09-18 05:54Z**; last session 09-18 (rabota ws3); idle since |
| Claude wiring | `jq ~/.claude/settings.json` | **no hooks** (secret guard unregistered), **no statusLine** |
| gh | `gh api user --jq .login`, with and without agent | `zvi-quantivly` both ways (single account in `hosts.yml`) |
| git over SSH | `ssh -T git@github.com` | `Hi ZviBaratz!`: forwarded agent offers the personal key first (DO-474) |
| …pinned | `ssh -o IdentitiesOnly=yes -o IdentityFile=…/quantivly.pub -T git@github.com` | **`Hi ZviBaratz!`**: dev's `ControlMaster auto` reused an unpinned master; `-o ControlPath=none` → `Hi zvi-quantivly!` |
| …no agent | `ssh -o ForwardAgent=no -o ControlPath=none dev 'git ls-remote …'` | SSH remote **fails**; HTTPS remote (private `hub`) **works** via `!gh auth git-credential` |
| Signing | fingerprint vs `gh api users/zvi-quantivly/ssh_signing_keys` | `SHA256:IbWPc…` **registered**, so commits from dev show Verified; key local, no agent needed |
| Remotes | `git remote get-url origin` ×21 | 11 SSH, 10 HTTPS; `~/.dotfiles` SSH. Missing vs laptop lanes: `auto-conf`, `offline-reports`, `qspace-server` |

Laptop side: `herdr machine list` has **`dev (EC2)` enabled**. `herdr --machine dev …` → `unknown option` (the flag is in 0.9.1 docs, not 0.9.0). A Claude session's RSS is a **median of 337 MiB** (p90 428, n=22). Remote transport: 48 health-check timeouts in 23 days (21 dev, 27 nanoclaw), **28 paired with the other machine within 2 s**, and the laptop suspended repeatedly in the same window. So they are laptop-side, and herdr keeps remote agents running through them. No transport change is planned.

## 3. Findings that change the issue

1. **`server-bootstrap.sh` is the wrong tool.** It targets shared `ec2-user` admin boxes: a server mise subset without node, an `admin@` identity, HTTPS→SSH rewrites (backwards for dev), and `git pull`. Dev is a full work instance; the gap is Parts A–B.
2. **rabota v2 already decided this, and part of it is open.** Decision §2.2 #2 (quantivly lanes on dev), C9, consolidation §1.1 seats (q3 console, q1 laptop headless, **q0 dev**), WS6.3 unchecked, three dev lanes run 09-16..18, Blocker A (the classifier refused `ssh dev systemd-run …`).
3. **quantivly-0 is being spent from the laptop.** clauth here still holds quantivly-0 and re-issued it at 12:02Z today. Two live sessions came from `clauth start quantivly-0`, **typed into panes by herdr-draft's account row** (README "launcher": `"start"` types `clauth start <profile> -- …` into the pane). The seat is at 66% of its week and 21% of 5h (resets 09-20 02:00Z) while dev is idle. The pool is not the only door. [DO-632](https://linear.app/quantivly/issue/DO-632) is a second one: the picker's last-resort fallback hands out clauth's *active* profile, `personal-1` here. Its "other holder is live" evidence is contradicted by the two sessions above (live at its 18:20 IDT measurement, counted `2` by `_claude_holder_count`), so a correction comment is drafted.
4. **Two independent logins of one account appear to coexist**, which `docs/CLAUDE_ACCOUNTS.md:515-520` lists as untested. The laptop's grant polled continuously on 09-17/18 (944 polls on 09-18) while dev's own grant refreshed at 09-18 05:54Z. So "one machine per profile" protects **window accounting**, not the login. Part B Task B3 upgrades this to a direct test.
5. **Git on dev must be HTTPS-only, and WS6.3(d) as written would corrupt dev's checkout** (`--global` writes through the symlink). dev-setup's work-only profile has the same two defects (`modules/accounts.sh:378-434`: `git config --global`, forwarded agent with no pin).

## 4. Scope answers (the issue's five bullets)

- **What dev has:** §2. Do not run the bootstrap; do Parts A–B.
- **Which lanes move:**
  - **Move** (decision 3): quantivly long builds and tests (hub, sre-core, platform), review/evaluate lanes, and attended sessions that mostly run on their own. Attended work arrives as a herdr
    session (`dev-spawn`, Part D), never as a bare-ssh `claude -p` lane outside any budget —
    corrected 2026-09-20 (DO-649). **Superseded in turn, same day:** headless work now also
    reaches dev, through a door DO-649 did not anticipate — `rabota lane recipe --machine dev
    --run` (`docs/superpowers/plans/2026-09-20-remote-lanes.md`), whose `ssh … systemd-run` joins
    `agents.slice` with an explicit `--slice=agents.slice`, so it is accounted without going
    through a herdr pane at all. Measured 2026-09-20: two lanes landed under
    `agents.slice/rabota-lane-…` with `MemoryMax=6442450944`.
  - **Stay:** toysim and personal; the quantivly-3 console; anything needing the local browser/GUI (chrome-devtools MCP) or laptop files (`~/.dotfiles-local`, `~/toysim`); work that tests this laptop's live herdr, systemd, GNOME or backup config.
- **Repo, worktree and PRs:** dev's own `~/quantivly/<repo>` checkouts; worktrees cut there by herdr-draft (or rabota). Missing repos cloned over HTTPS. Push and `gh pr create` go through gh as `zvi-quantivly`, with commits signed by dev's registered key. No deploy key, no agent.
- **How the laptop drives dev:** herdr's native machine view, not nested tmux (F12 loses the laptop's agent detection and notifications). Agents use `dev-spawn` (Part D), and `ssh dev herdr …` to inspect.
- **quantivly-0 and the pool:** stays pinned to dev. An exhausted laptop quantivly pool keeps its designed behaviour: interactive sessions proceed on the least-bad member, `hspawn`/`--strict` refuse. The remedy is to run the work on dev, never to widen the pool. Part C closes the leak.

## 5. Issues to file (DO team; after approval, with Zvi's OK)

| Part | Linear title | Repo / where | Depends on |
|---|---|---|---|
| A | dev: route all GitHub git traffic over HTTPS through gh (DO-474 on dev) | dev (ops) + `examples/ssh-config.template` | — |
| B | dev: deploy current dotfiles and wire it as an agent host | dev (ops) + `docs/HERDR_GUIDE.md` | A |
| C | Refuse explicit launches on a profile another machine owns | `zsh/zshrc.herdr`, `scripts/test-hspawn.sh`, `~/.dotfiles-local`, CLAUDE.md, `docs/CLAUDE_ACCOUNTS.md` | — (related DO-632, the fallback door; its option 1 can reuse C's table) |
| D | `dev-spawn`: the one door agents use to start sessions on dev | `scripts/dev-spawn`, `scripts/test-dev-spawn.sh`, CI, `install.conf.yaml`, `~/.claude/settings.json`, `docs/HERDR_GUIDE.md` | B (plugin with `--dry-run`) |
| E | dev-setup work-only: HTTPS through gh, never `--global` through a dotfiles symlink | `quantivly/dev-setup` `modules/accounts.sh` + tests | — (relates DO-474) |

All five are `related` to DO-635; E also relates to DO-474. **rabota note** (no new issue): update
`plans/WS6-remote-dev.md` §6.3 and consolidation plan §3.4. Replace (d) with "done by DO-635 Part A".
Add `--slice=agents.slice` to the dev lane recipe (Part B Task B4), and `Bash(rabota lane recipe:*)` to the
allow list once `lane recipe --run` exists (it does not yet: there is no `lane` command in `rabota/rabota/commands/`).

### File structure

| File | Part | Responsibility |
|---|---|---|
| dev `~/.gitconfig.local` | A | HTTPS rewrite for `git@github.com:`; drop the defeated `core.sshCommand` pin |
| `examples/ssh-config.template` | A | Correct the remote-context GitHub guidance (the pin is defeated by ControlMaster) |
| dev `~/.claude/settings.json` | B | Secret guard registered; statusLine (via `herdr-claude-wire.sh`) |
| dev `~/.config/systemd/user/agents.slice` + `herdr-server.service.d/30-slice.conf` | B | One memory budget for every agent process on dev |
| `zsh/zshrc.herdr` | C | `CLAUDE_TENANT_MACHINE_OWNED`, `_claude_profile_foreign`, `_claude_foreign_refuse`, `clauth()` wrapper, checks in `claude()` and `hspawn` |
| `scripts/test-hspawn.sh` | C | Hermetic rows for every door |
| `~/.dotfiles-local/claude/tenants.zsh` | C | The data: `quantivly-0 → "dev (EC2)"` |
| `scripts/dev-spawn` (+ `~/.local/bin` link) | D | Validated, quoted, stdin-prompt remote `herdr-draft create` |
| `scripts/test-dev-spawn.sh` + `.github/workflows/ci.yml` | D | Hermetic rows incl. injection |
| `docs/HERDR_GUIDE.md` §9 "Working on dev" | B, D | The operator's guide |

---

## Part A — dev: GitHub git traffic over HTTPS through gh

### Task A1: Rewrite `git@github.com:` to HTTPS in dev's `~/.gitconfig.local` (gated: writes on dev)

**Files:** dev `~/.gitconfig.local`; dev `~/.ssh/WORK_INSTANCE_SETUP.md` and `AUTHENTICATION_ARCHITECTURE.md` (dev-local notes).

- [ ] **Step 1: Record the before-state** (read-only)
```bash
ssh -o BatchMode=yes dev 'git config --file ~/.gitconfig.local --get-regexp "^(url\.|core\.sshcommand)"; git -C ~/.dotfiles status --porcelain | wc -l'
```
Expected: `url.https://github.com/.insteadof ssh://git@github.com/`, `core.sshcommand ssh -o IdentitiesOnly=yes -o IdentityFile=~/.ssh/github-keys/quantivly.pub`, and `0`.

- [ ] **Step 2: Prove the failure first** (no agent, no mux)
```bash
ssh -o BatchMode=yes -o ControlPath=none -o ForwardAgent=no dev \
  'GIT_TERMINAL_PROMPT=0 timeout 25 git -C ~/quantivly/sre-sdk ls-remote origin HEAD 2>&1 | tail -1'
```
Expected: `and the repository exists.` (fails).

- [ ] **Step 3: Apply** (Zvi's OK)
```bash
ssh -o BatchMode=yes dev 'git config --file ~/.gitconfig.local --add url.https://github.com/.insteadOf git@github.com: \
  && git config --file ~/.gitconfig.local --unset core.sshCommand'
```

- [ ] **Step 4: Verify with no agent and no mux.** Every remote form works, a push authenticates, and the checkout was not written through:
```bash
ssh -o BatchMode=yes -o ControlPath=none -o ForwardAgent=no dev '
  for r in ~/.dotfiles ~/quantivly/sre-sdk ~/quantivly/hub; do
    printf "%-26s %s\n" "$r" "$(GIT_TERMINAL_PROMPT=0 timeout 25 git -C "$r" ls-remote origin HEAD | cut -c1-12)"; done
  GIT_TERMINAL_PROMPT=0 git -C ~/quantivly/sre-sdk push --dry-run origin HEAD:refs/heads/do-635-probe 2>&1 | tail -2
  git -C ~/.dotfiles status --porcelain | wc -l'
```
Expected: three 12-char SHAs; `To https://github.com/quantivly/sre-sdk.git` / `* [new branch] HEAD -> do-635-probe` (dry run, nothing created); `0`.

- [ ] **Step 5: Verify the mux trap no longer matters** (with agent)
```bash
ssh -o BatchMode=yes dev 'ssh -T git@github.com 2>&1 | head -1; GIT_TERMINAL_PROMPT=0 git -C ~/quantivly/sre-sdk ls-remote origin HEAD | cut -c1-12'
```
Expected: `Hi ZviBaratz!…` (the master opens as personal) and a SHA, because git no longer uses SSH.

- [ ] **Step 6:** Correct dev's two `~/.ssh/*.md` notes in place. They claim the pin lives in `~/.gitconfig` and that `ssh -T` shows `zvi-quantivly`. Replace the mechanism section with: "all github.com git traffic is HTTPS through `gh auth git-credential` (`~/.gitconfig.local` `url.insteadOf`); SSH to GitHub is unused by git; measured 2026-09-19, DO-635."

### Task A2: Correct `examples/ssh-config.template`'s remote-context GitHub guidance

**Files:** Modify `examples/ssh-config.template` (the `Host github.com` block under "REMOTE SERVER CONFIGURATION", whose comments say key selection is handled by `core.sshCommand`).

- [ ] **Step 1:** Replace the four comment lines above `Host github.com` in the remote section with:
```
# WORK DEVELOPMENT INSTANCE: route git to GitHub over HTTPS, not SSH.
# In ~/.gitconfig.local (NEVER --global: ~/.gitconfig is a symlink into dotfiles):
#   git config --file ~/.gitconfig.local --add url.https://github.com/.insteadOf git@github.com:
# gh's credential helper then authenticates as the one account in gh's hosts.yml,
# with no forwarded agent — which a session left running after you disconnect
# does not have. A core.sshCommand key pin is NOT enough: with ControlMaster on,
# a pinned ssh reuses whatever identity an earlier unpinned `ssh git@github.com`
# opened the master with, for ControlPersist (measured on dev, 2026-09-19, DO-635).
```
- [ ] **Step 2:** `pre-commit run --files examples/ssh-config.template` → passes. Commit: `docs(ssh): remote work boxes route GitHub over HTTPS, not a pinned key (DO-635)`.

---

## Part B — dev: deploy and wire as an agent host (all dev writes gated)

### Task B1: Fast-forward dev's dotfiles and install

- [ ] **Step 1:** Seat check (`jq -c '{d5:.five_hour.utilization, d7:.seven_day.utilization}' ~/.clauth/profiles/personal-0/usage_cache.json`). Then fetch and inspect:
```bash
ssh -o BatchMode=yes -o ControlPath=none -o ForwardAgent=no dev 'git -C ~/.dotfiles fetch origin main && git -C ~/.dotfiles status --porcelain && git -C ~/.dotfiles diff --name-only HEAD..origin/main | wc -l'
```
Expected: fetch succeeds **with no agent** (proves Part A; `ControlPath=none` so a laptop-side master cannot carry an agent in), empty porcelain, a count ≥ 23.
- [ ] **Step 2 (Zvi's OK):** `ssh -o BatchMode=yes dev 'export PATH=$HOME/.local/bin:$PATH; git -C ~/.dotfiles merge --ff-only origin/main && bash ~/.dotfiles/install'`. The `PATH` matters: `./install` skips its mise section when mise is not on `PATH`, and a non-interactive ssh has no `~/.local/bin`. This runs from the primary checkout on `main`, so it is the documented deploy, not a worktree install.
- [ ] **Step 3:** Verify that `ssh dev 'git -C ~/.dotfiles rev-parse --short HEAD'` equals the laptop's `git rev-parse --short origin/main`. Then `ssh dev 'bash ~/.dotfiles/scripts/verify-tools.sh --herdr'` should show no ✗; fix only what it names.

### Task B2: Wire Claude on dev (statusLine + secret guard)

- [ ] **Step 1:** `ssh -o BatchMode=yes dev 'PATH=$HOME/.local/bin:$PATH bash ~/.dotfiles/scripts/herdr-claude-wire.sh'`, then `ssh dev 'jq -r .statusLine.command ~/.claude/settings.json'` should be non-null.
- [ ] **Step 2:** Register the guard with the laptop's exact entry (matcher `Bash`). Save as a scratch script and run it with `ssh -o BatchMode=yes dev 'bash -s' < register-guard.sh`:
```bash
set -euo pipefail
f="$HOME/.claude/settings.json"
test -r "$HOME/.claude/hooks/secret-emission-guard.sh"   # placed by ./install in B1
cp "$f" "$f.bak-do635"
cmd='f="$HOME/.claude/hooks/secret-emission-guard.sh"; [ -r "$f" ] && exec bash "$f"; exit 0'
jq --arg c "$cmd" '
  if ([.hooks.PreToolUse[]?.hooks[]?.command] | index($c)) then .
  else .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{matcher: "Bash", hooks: [{type: "command", command: $c}]}]) end' \
  "$f" > "$f.new" && mv "$f.new" "$f"
jq -c '[.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[].command]' "$f"
```
Expected: the last line lists the guard command once. Re-running is a no-op (idempotent).
- [ ] **Step 3:** Prove the guard denies on dev without spending the seat:
```bash
ssh -o BatchMode=yes dev 'printf "%s" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"gh auth token\"}}" | bash ~/.claude/hooks/secret-emission-guard.sh; echo "rc=$?"'
```
Expected: a deny decision naming the redactor (same output as on the laptop).

### Task B3: Is dev's login alive? (first use of quantivly-0 on dev since 09-18; also the coexistence test)

- [ ] **Step 1:** `ssh -o BatchMode=yes dev 'cd ~ && ~/.local/bin/claude -p "Reply with the single word ok." --model haiku 2>&1 | tail -1'`
Expected: `ok`. If it prints `Login expired` / `OAuth session expired`, **stop**. Zvi runs `/login` in a dev pane (herdr sidebar → `dev (EC2)` → pane → `claude` → `/login`). Record which outcome it was.
- [ ] **Step 2:** Record the outcome with dates in Part C Task C4. The laptop re-issued its own quantivly-0 grant at 09-19 12:02Z, so a successful refresh on dev here means two independent logins coexisted across that rotation.

### Task B4: One memory budget for all agent work on dev

The attended pane shells already run in `herdr-server.service`'s cgroup, which has no limit, and dev also hosts the team's platform stack.

- [ ] **Step 1 (Zvi's OK)**, via `ssh dev 'bash -s'`:
```bash
set -euo pipefail
d="$HOME/.config/systemd/user"
cat > "$d/agents.slice" <<'EOF'
[Unit]
Description=herdr panes and rabota lanes on this host (DO-635)
[Slice]
MemoryHigh=8G
MemoryMax=10G
MemorySwapMax=4G
EOF
mkdir -p "$d/herdr-server.service.d"
cat > "$d/herdr-server.service.d/30-slice.conf" <<'EOF'
[Service]
Slice=agents.slice
EOF
systemctl --user daemon-reload
systemctl --user restart herdr-server.service     # dev's server is idle (one shell pane, no agents) — re-check first
systemctl --user show herdr-server.service -p ControlGroup
cat "/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/agents.slice/memory.max"
```
Expected: `ControlGroup=/…/agents.slice/herdr-server.service` and `10737418240`. The numbers leave ≥3 GiB of today's 13 GiB for the platform; revisit after a week of `agents.slice/memory.peak`.
- [ ] **Step 2:** `ssh dev 'bash ~/.dotfiles/scripts/verify-tools.sh --herdr'` must still pass. A `Slice=` drop-in touches no `[Install]` key, so the reconciler's drop-in merge (HERDR_INTERNALS) should not flag it. If it does, that is a checker defect to report, not a reason to drop the cap.

### Task B5: herdr-draft current on dev, missing repos, 09-15 spill

- [ ] **Step 1:** Back up `~/.config/herdr/plugins/config/zvibaratz.draft`, then reinstall at the laptop's ref:
`ssh dev 'export PATH=$HOME/.local/bin:$HOME/.local/share/mise/installs/go/1.26.4/bin:$PATH; herdr plugin install ZviBaratz/herdr-draft --ref 4734e67 -y'`. If it refuses as already installed, `herdr plugin uninstall zvibaratz.draft` then install, and restore the config dir. Verify: `herdr plugin list` shows `@4734e67…` and `herdr-draft create --help | grep -c -- --dry-run` → `1`.
- [ ] **Step 2:** Clone over HTTPS the quantivly repos lanes need that dev lacks (`auto-conf`, `offline-reports`, `qspace-server`; confirm with Zvi): `git -C ~/quantivly clone https://github.com/quantivly/<repo>.git`.
- [ ] **Step 3:** With `pgrep -c claude` on dev = `0`, move the 09-15 spill aside (reversible) without reading it: `mkdir ~/.claude-home-spill-20260915 && mv ~/history.jsonl ~/projects ~/sessions ~/plugins ~/settings.json ~/cache ~/backups ~/credentials.json.blanked-backup ~/.claude-home-spill-20260915/`. Tell Zvi to delete the directory if the `blanked-backup` holds a live credential.

### Task B6: Document "Working on dev"

**Files:** Modify `docs/HERDR_GUIDE.md`: new subsection at the end of `## 9. Spawning work`, ≤40 lines.

- [ ] **Step 1:** Write the subsection covering:
  - **Policy:** quantivly only; the seat is quantivly-0.
  - **Opening dev:** open `dev (EC2)` from the machine sidebar, and spawn with herdr-draft's popup there.
  - **Agents:** use `dev-spawn` (Part D). On herdr 0.9.0 the local `herdr` CLI targets only the local socket, so inspect dev with `ssh dev 'PATH=$HOME/.local/bin:$PATH herdr agent list'`.
  - **Git:** HTTPS only (Part A).
  - **Memory:** the `agents.slice` budget (B4) and how to read `memory.peak`.
  - **Disconnects:** they leave dev's agents running. The measured timeouts are the laptop's own suspends.
  - **Closing panes:** close what you spawn on dev with `ssh dev herdr pane close <id>`.
- [ ] **Step 2:** `./scripts/check-claude-md.sh` → no ✗. Commit: `docs(herdr): working on dev (DO-635)`.

---

## Part C — refuse explicit launches on a profile another machine owns

### Task C1: Failing rows in `scripts/test-hspawn.sh`

**Files:** Modify `scripts/test-hspawn.sh`: new section before the final tally. The harness already stubs `clauth` (log `$TMPROOT/clauth.log`), `claude` (`$CLAUDE_LOG`) and `herdr` (`$LOG`), and `run` sources `zsh/zshrc.herdr` under the fixture `$FHOME`.

- [ ] **Step 1: Add the rows**
```bash
#-----------------------------------------------------------------------------
# Machine-owned profiles (DO-635)
#-----------------------------------------------------------------------------
# The pool keeps a profile another machine owns out of AUTOMATIC selection. These
# rows pin the EXPLICIT doors that went past it: on 2026-09-19 two sessions were
# spending dev's seat from the laptop via `clauth start quantivly-0`, typed into
# panes by herdr-draft's account row. `run` does not truncate the clauth log, so
# every row here does it itself.
FOREIGN_TENANTS="$TMPROOT/tenants-foreign.zsh"
printf '%s\n' 'CLAUDE_TENANT_MACHINE_OWNED=( fz "box-z" )' > "$FOREIGN_TENANTS"
mkdir -p "$FHOME/.clauth/profiles/fz"
export CLAUDE_TENANTS_FILE="$FOREIGN_TENANTS"
crun()   { : > "$TMPROOT/clauth.log"; run "$1"; }
clog()   { grep -cF -- "CMD $1" "$TMPROOT/clauth.log" || true; }

crun "clauth start fz --effort high"
check "foreign: clauth start <owned> is refused"                    "$RC" "3"
check "foreign: ...before the binary runs"                          "$(clog 'start')" "0"
check "foreign: ...naming the machine that owns it"                 "$(inout 'owned by box-z')" "1"
crun "clauth start --isolated fz"
check "foreign: a flag before the profile does not hide it"         "$RC" "3"
crun "clauth start --theme full fz"
check "foreign: --theme's VALUE is not read as the profile"         "$RC" "3"
crun "clauth fz"
check "foreign: the bare machine-wide switch is refused"            "$RC" "3"
check "foreign: ...before the binary runs"                          "$(clog 'fz')" "0"
crun "clauth start personal"
check "foreign: an unowned profile passes through"                  "$(clog 'start personal')" "1"
crun "clauth login fz"
check "foreign: login passes (it is how this box SEES that window)" "$(clog 'login fz')" "1"
crun "CLAUDE_FOREIGN_PROFILE_OK=1 clauth start fz"
check "foreign: the per-command override passes through"            "$(clog 'start fz')" "1"
crun "unset -f _claude_profile_foreign; clauth start fz"
check "foreign: helpers absent (a Bash-tool shell) fails OPEN"      "$(clog 'start fz')" "1"
crun "claude-as fz"
check "foreign: claude-as <owned> is refused"                       "$RC" "3"
check "foreign: ...and claude never ran"                            "$(wc -l < "$CLAUDE_LOG" | tr -d ' ')" "0"
crun "hspawn -p fz -m opus -e high '$REPO' slug"
check "foreign: hspawn -p <owned> is refused"                       "$RC" "3"
check "foreign: ...reaching herdr zero times"                       "$(herdrcmds)" ""
check "foreign: ...and clauth zero times"                           "$(wc -l < "$TMPROOT/clauth.log" | tr -d ' ')" "0"
unset CLAUDE_TENANTS_FILE
crun "clauth start fz"
check "foreign: no tenant table (modular adopter) guards nothing"   "$(clog 'start fz')" "1"
rm -rf "$FHOME/.clauth/profiles/fz"
```
- [ ] **Step 2:** `./scripts/test-hspawn.sh 2>&1 | grep -E 'foreign:|passed'`. Expected: the refusal rows FAIL (`expected '3', got '0'`) and the pass-through rows pass. Nothing is guarded yet.

### Task C2: Implement the guard in `zsh/zshrc.herdr`

**Interfaces — Produces:** `_claude_profile_foreign <profile>` → prints owner label, rc 0 if owned elsewhere, else rc 1 and no output; `_claude_foreign_refuse <cmd> <profile> <owner>` → stderr message; `clauth()` → rc 3 on refusal, otherwise `command clauth "$@"`'s rc. Data: `typeset -gA CLAUDE_TENANT_MACHINE_OWNED` (profile → machine label).

- [ ] **Step 1: Declare the table.** In the declaration line before the tenants file is sourced (`typeset -gA CLAUDE_TENANT_POOL CLAUDE_TENANT_OVERFLOW CLAUDE_TENANT_GH_DIR`), append ` CLAUDE_TENANT_MACHINE_OWNED`. Add one line to the example block above it:
```zsh
#   CLAUDE_TENANT_MACHINE_OWNED=( quantivly-0 "dev (EC2)" )   # profile=the machine that owns it
```
- [ ] **Step 2: Predicate and message.** Insert directly after `_claude_profile_excluded()`'s closing brace:
```zsh
# Is this profile OWNED BY ANOTHER MACHINE? Prints that machine's label, rc 0;
# otherwise prints nothing, rc 1.
#
# The pool already keeps such a profile out of AUTOMATIC selection. This is for
# the explicit doors, every one of which went straight past the pool: on
# 2026-09-19 two `clauth start quantivly-0` sessions, typed into panes by
# herdr-draft's account row, were spending dev's seat from the laptop while dev
# sat idle. Holding the LOGIN stays allowed: this machine's own grant is how it
# SEES that seat's window, and two independent logins of one account coexist
# (docs/CLAUDE_ACCOUNTS.md). Launching on it is what drains one window from two
# machines, each invisible to the other's picker. DO-635.
#
# No table, or no entry, means "not foreign": a modular adopter has no machines.
_claude_profile_foreign() {
  [[ -n "$1" && -z "${CLAUDE_FOREIGN_PROFILE_OK:-}" ]] || return 1
  local owner="${CLAUDE_TENANT_MACHINE_OWNED[$1]:-}"
  [[ -n "$owner" ]] || return 1
  print -r -- "$owner"
}

# The one refusal every door prints, so the doors cannot drift apart.
_claude_foreign_refuse() {   # $1 = refusing command, $2 = profile, $3 = owner
  print -u2 -- "$1: refused — '$2' is owned by $3 (CLAUDE_TENANT_MACHINE_OWNED)."
  print -u2 -- "    Run this work on $3 instead: its machine in herdr's sidebar."
  print -u2 -- "    To borrow it on purpose, for one command: CLAUDE_FOREIGN_PROFILE_OK=1 $1 …"
}
```
- [ ] **Step 3: The `clauth` wrapper.** Insert directly before the `claude-as()` comment block:
```zsh
# `clauth` as a function, for the two forms that NAME a profile outright —
# `clauth start [opts] <profile>` and `clauth <profile>` (a machine-wide switch).
# A profile another machine owns is refused (_claude_profile_foreign); everything
# else reaches the binary untouched. herdr-draft's account row TYPES
# `clauth start <p> --` into a pane's interactive shell, so this is the door the
# 2026-09-19 sessions came through.
#
# FAILS OPEN where the helpers are absent — a Claude Code Bash-tool shell keeps
# public functions and drops single-underscore ones — because a wrapper that
# breaks `clauth` when it breaks gets removed wholesale.
clauth() {
  local p="" owner="" a skip=0
  if [[ "${1:-}" == start ]]; then
    for a in "${@:2}"; do
      if (( skip )); then skip=0; continue; fi
      case "$a" in
        --theme) skip=1 ;;        # the one `clauth start` option that takes a value
        -*) ;;
        *) p="$a"; break ;;
      esac
    done
  elif [[ -n "${1:-}" && "$1" != -* && -d "$HOME/.clauth/profiles/$1" ]]; then
    p="$1"
  fi
  if [[ -n "$p" ]] && (( $+functions[_claude_profile_foreign] && $+functions[_claude_foreign_refuse] )) \
     && owner="$(_claude_profile_foreign "$p")"; then
    _claude_foreign_refuse clauth "$p" "$owner"
    return 3
  fi
  command clauth "$@"
}
```
- [ ] **Step 4: `claude()`**, which carries `claude-as` and a hand-set `CLAUDE_ACCOUNT_PROFILE`. Insert immediately after `local _claude_pick_prog=claude`:
```zsh
  # DO-635: a NAMED profile (claude-as, or CLAUDE_ACCOUNT_PROFILE by hand) is an
  # explicit door past the pool, so it gets the same machine-ownership refusal.
  local _foreign_owner=""
  if [[ -n "${CLAUDE_ACCOUNT_PROFILE:-}" ]] \
     && (( $+functions[_claude_profile_foreign] && $+functions[_claude_foreign_refuse] )) \
     && _foreign_owner="$(_claude_profile_foreign "$CLAUDE_ACCOUNT_PROFILE")"; then
    _claude_foreign_refuse claude "$CLAUDE_ACCOUNT_PROFILE" "$_foreign_owner"
    return 3
  fi
```
- [ ] **Step 5: `hspawn`.** Insert immediately before `if (( ! profile_set )) && [[ -z "$profile" ]] && (( ! shared )); then`. It covers `-p`, `--profile=` and the deprecated positional slot, because all of them set `$profile`:
```zsh
  # DO-635: a named profile is an explicit door past the pool. Refused here,
  # before any resolution or herdr call, so a rejected spawn reaches nothing.
  local _foreign_owner=""
  if [[ -n "$profile" ]] \
     && (( $+functions[_claude_profile_foreign] && $+functions[_claude_foreign_refuse] )) \
     && _foreign_owner="$(_claude_profile_foreign "$profile")"; then
    _claude_foreign_refuse hspawn "$profile" "$_foreign_owner"
    return 3
  fi
```
- [ ] **Step 6:** `zsh -n zsh/zshrc.herdr && ./scripts/test-hspawn.sh && ./scripts/test-claude-pick.sh && ./scripts/test-herdr-modular.sh`. Expected: all pass. If the hspawn row reports herdr calls, a herdr call precedes the insertion point: move the block up to the first validation after option parsing.

### Task C3: Mutation sweep (dry-run each for applicability first)

- [ ] For each mutation: confirm it applies (`grep -c` the target line = 1), apply it, run `./scripts/test-hspawn.sh`, confirm the named rows fail, then `git checkout -- zsh/zshrc.herdr`:
  - M1 `_claude_profile_foreign` body → `return 1`: every "is refused" row fails.
  - M2 delete `--theme) skip=1 ;;`: the `--theme` row fails.
  - M3 delete the `elif … -d "$HOME/.clauth/profiles/$1"` branch: both bare-switch rows fail.
  - M4 delete the `claude()` block: both `claude-as` rows fail.
  - M5 delete the `hspawn` block: all three hspawn rows fail.
  - M6 `-z "${CLAUDE_FOREIGN_PROFILE_OK:-}"` → `-n …`: the override row and the refusals fail.
  A mutation that leaves every row green is a hollow row: fix the row, not the tally.
- [ ] Commit: `feat(herdr): refuse explicit launches on a profile another machine owns (DO-635)`.

### Task C4: Data, docs and the CLAUDE.md line

- [ ] **Step 1 (Zvi's OK; `~/.dotfiles-local` is his private repo):** in `~/.dotfiles-local/claude/tenants.zsh`, add `CLAUDE_TENANT_MACHINE_OWNED` to its `typeset -gA` line, then after `CLAUDE_TENANT_POOL`:
```zsh
# profile -> the machine that owns it. The pool keeps these out of AUTOMATIC
# selection; this table makes zshrc.herdr refuse the EXPLICIT doors too —
# `clauth start <p>` (which herdr-draft's account row types), `clauth <p>`,
# `claude-as <p>`, `hspawn -p <p>`. Found 2026-09-19 (DO-635): two laptop
# sessions were on quantivly-0 through `clauth start` while dev sat idle.
# The laptop KEEPS its logins to both, deliberately: they are how this machine
# sees those windows. personal-1 is listed too (Zvi, 2026-09-19), "at least
# until we get a better sense of how to utilize efficiently across hosts".
CLAUDE_TENANT_MACHINE_OWNED=(
  quantivly-0 "dev (EC2)"
  personal-1  "nanoclaw (Hetzner)"
)
```
Verify: `zsh -ic 'clauth start quantivly-0 </dev/null'` and `zsh -ic 'clauth start personal-1 </dev/null'` each print the refusal and exit 3 without launching.

Note: `personal-1` is also clauth's `active_profile` on the laptop, and the picker's last-resort fallback hands that profile out (DO-632). This guard does not close that door; DO-632 does. The live personal-1 sessions end on their own.
- [ ] **Step 2:** `docs/CLAUDE_ACCOUNTS.md`, "Credential groups can only equal logins" bullet (`:515-520`): replace "is **untested**" with the measured evidence. That is §3 finding 4 plus Task B3's result, with dates, stated as "natural experiment, not a controlled test" if B3 was not run.
- [ ] **Step 3: CLAUDE.md, net-zero bytes.** Replace the Herdr bullet at `CLAUDE.md:520` (`**\`clauth start <profile>\` bypasses \`claude()\`**, so it is not a team lead: \`clauth <profile>\` then \`claude\`.`) with this, keeping its original advice:
```
- **`clauth start <profile>` bypasses `claude()`**, so it is not a team lead (`clauth <profile>` then `claude`); it is refused for a profile another machine owns (`CLAUDE_TENANT_MACHINE_OWNED`). Quantivly work that needs none of this laptop runs on dev: [HERDR_GUIDE §9](docs/HERDR_GUIDE.md).
```
Then remove at least the added bytes elsewhere. Proposed: **move** the Tmux section's "Nested tmux (remote servers)" paragraph (`CLAUDE.md:473`, 274 bytes) verbatim into `docs/TMUX_LEARNING_GUIDE.md`, which does not cover it today (measured: 0 matches for `nested|F12|[INNER]`). Leave behind a link in the Tmux section's existing "See … for comprehensive guides" line. This is an extraction of elaboration, not a deletion. Run `./scripts/check-claude-md.sh` until clean. Commit: `docs: the machine-ownership guard and where quantivly work runs (DO-635)`.

---

## Part D — `dev-spawn`: the one door agents use to start sessions on dev

> **Superseded in part, 2026-09-20, by
> [`docs/superpowers/plans/2026-09-20-remote-lanes.md`](2026-09-20-remote-lanes.md).** This Part
> was written when "the one door" had to cover headless work too, because nothing else could join
> `agents.slice`. It no longer does: headless lanes go through `rabota lane recipe --machine dev
> --run`, whose `systemd-run` joins the slice directly with an explicit `--slice=agents.slice`
> (measured working, two lanes, 2026-09-20) — not through `dev-spawn` or a herdr pane at all.
> `dev-spawn` stays the door for **attended** sessions only (Task D2's `herdr-draft create`); its
> tasks below are unaffected. `docs/HERDR_GUIDE.md` §9 documents both doors.

A raw allow rule on `ssh dev herdr-draft create:*` is not narrow: the remote shell re-parses its
arguments, so `\;` in an argument becomes a second remote command. `dev-spawn` validates
every value against a closed vocabulary or `%q`-quotes it, and carries the prompt on ssh's
**stdin** into `herdr-draft create --prompt -`, never on a command line.

### Task D1: Failing state table `scripts/test-dev-spawn.sh`

**Files:** Create `scripts/test-dev-spawn.sh` (executable).

- [ ] **Step 1: Write it**
```bash
#!/usr/bin/env bash
#
# scripts/test-dev-spawn.sh — state table for scripts/dev-spawn (DO-635).
# HERMETIC: `ssh` is a stub on a PATH built from scratch; the remote command it
# receives is re-run locally under a fixture HOME with a stub herdr-draft, which
# is how the injection rows prove quoting rather than assume it.
set -uo pipefail
DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$DOTFILES/scripts/dev-spawn"
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
[[ -x "$SUT" ]] || { echo "FATAL: $SUT missing or not executable" >&2; exit 2; }

BIN="$TMPROOT/bin"; mkdir -p "$BIN"
# `touch` MUST be here: without it an injected `touch PWNED` could never create the
# sentinel, and the injection rows would pass whether or not quoting works.
for t in bash cat printf sed grep tr wc env mkdir touch ls; do ln -s "$(command -v "$t")" "$BIN/$t"; done
# ssh stub: argv to ssh.args (one per line), stdin to ssh.stdin, exit $SSH_RC.
cat > "$BIN/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$SSH_ARGS"; cat > "$SSH_STDIN"; exit "${SSH_RC:-0}"
EOF
chmod +x "$BIN/ssh"
# Fixture "dev": a HOME with one checkout and a herdr-draft that prints its argv.
FIX="$TMPROOT/devhome"; mkdir -p "$FIX/quantivly/hub" "$FIX/.local/bin"
cat > "$FIX/.local/bin/herdr-draft" <<'EOF'
#!/bin/bash
printf 'ARG %s\n' "$@"; printf 'STDIN %s\n' "$(cat)"
EOF
chmod +x "$FIX/.local/bin/herdr-draft"

RC=0; OUT=""
ds() {   # $1 = prompt on stdin, rest = dev-spawn args
  local p="$1"; shift
  : > "$TMPROOT/ssh.args"; : > "$TMPROOT/ssh.stdin"
  OUT="$(printf '%s' "$p" | env -i PATH="$BIN" HOME="$TMPROOT" SSH_ARGS="$TMPROOT/ssh.args" \
         SSH_STDIN="$TMPROOT/ssh.stdin" SSH_RC="${SSH_RC:-0}" "$SUT" "$@" 2>&1)"; RC=$?
}
ssh_calls() { [[ -s "$TMPROOT/ssh.args" ]] && echo 1 || echo 0; }
remote()    { tail -n1 "$TMPROOT/ssh.args"; }       # the remote command string
replay()    { printf '%s' "$(cat "$TMPROOT/ssh.stdin")" | env -i PATH="$BIN" HOME="$FIX" bash -c "$(remote)"; }

echo "=== usage and policy refusals reach ssh zero times"
ds "do it" --title t;                        check "no --repo → 2"                "$RC" "2"; check "...no ssh" "$(ssh_calls)" "0"
ds "do it" --repo ../etc --title t;          check "path escape in --repo → 2"    "$RC" "2"; check "...no ssh" "$(ssh_calls)" "0"
ds "do it" --repo 'hub;id' --title t;        check "metachar in --repo → 2"       "$RC" "2"; check "...no ssh" "$(ssh_calls)" "0"
ds "do it" --repo hub --title t --model gpt; check "model outside the aliases → 2" "$RC" "2"; check "...no ssh" "$(ssh_calls)" "0"
ds "do it" --repo hub --title t --effort 11; check "effort outside the levels → 2" "$RC" "2"; check "...no ssh" "$(ssh_calls)" "0"
ds "   "  --repo hub --title t;              check "blank prompt → 3"             "$RC" "3"; check "...no ssh" "$(ssh_calls)" "0"

echo "=== the happy path"
ds "SENTINEL-PROMPT-7f3a" --repo hub --title "Fix the thing" --model sonnet --effort medium
check "valid spawn → 0"                           "$RC" "0"
check "ssh targets dev in batch mode"             "$(grep -cx -- 'BatchMode=yes' "$TMPROOT/ssh.args")$(grep -cx -- dev "$TMPROOT/ssh.args")" "11"
check "the prompt is NOT on any command line"     "$(grep -c SENTINEL "$TMPROOT/ssh.args")" "0"
check "the prompt travels on stdin"               "$(cat "$TMPROOT/ssh.stdin")" "SENTINEL-PROMPT-7f3a"
R="$(replay)"
check "remote runs herdr-draft create in the checkout" "$(grep -cx 'ARG create' <<<"$R")" "1"
check "remote passes --worktree"                  "$(grep -cx 'ARG --worktree' <<<"$R")" "1"
check "remote reads the prompt from stdin"        "$(grep -cx 'STDIN SENTINEL-PROMPT-7f3a' <<<"$R")" "1"

echo "=== injection: the title reaches herdr-draft as ONE literal argument"
ds "p" --repo hub --title 'x"; touch PWNED; echo "$(touch PWNED2)`touch PWNED3`'
R="$(cd "$FIX" && replay)"
check "title arrives verbatim"                    "$(grep -cxF 'ARG x"; touch PWNED; echo "$(touch PWNED2)`touch PWNED3`' <<<"$R")" "1"
check "no command ran on the remote side"         "$(ls "$FIX" "$FIX/quantivly/hub" | grep -c PWNED)" "0"

echo "=== dry run and remote failures"
ds "p" --repo hub --title t --dry-run;             check "--dry-run is forwarded" "$(replay | grep -cx 'ARG --dry-run')" "1"
ds "p" --repo nosuch --title t                     # the REMOTE string itself, replayed
check "the remote command exits 3 for a missing checkout" "$(replay >/dev/null 2>&1; echo $?)" "3"
SSH_RC=3 ds "p" --repo nosuch --title t;           check "remote: no such checkout → 3" "$RC" "3"
check "...and it names the checkout"               "$(grep -c 'no checkout ~/quantivly/nosuch' <<<"$OUT")" "1"
SSH_RC=255 ds "p" --repo hub --title t;            check "ssh failure → 1" "$RC" "1"

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
(( PASS + FAIL == 26 )) || { echo "FATAL: expected 26 rows, ran $((PASS+FAIL))" >&2; exit 2; }
(( FAIL == 0 ))
```
- [ ] **Step 2:** `chmod +x scripts/test-dev-spawn.sh && ./scripts/test-dev-spawn.sh; echo rc=$?` → `FATAL: …dev-spawn missing`, `rc=2`.

### Task D2: Implement `scripts/dev-spawn`

**Interfaces — Produces:** `dev-spawn --repo <name> --title <text> [--model fable|opus|sonnet|haiku] [--effort low|medium|high|xhigh|max] [--base <ref>] [--dry-run] < prompt`; exit 0 created, 1 ssh/remote failure, 2 usage, 3 refused (blank prompt, no such checkout on dev). Env `DEV_SPAWN_HOST` (default `dev`).

- [ ] **Step 1: Write it**
```bash
#!/usr/bin/env bash
#
# scripts/dev-spawn
# =================
#
# Start an agent session on the dev box (DO-635): a herdr-draft session in its
# own worktree of one of dev's ~/quantivly checkouts, billed to dev's own seat.
#
# The ONE door agents use to start work on dev, and the only one the permission
# allow-list names (Bash(dev-spawn:*)). It exists so that rule can be narrow: a
# rule on raw `ssh dev …` lets the remote shell re-parse whatever an agent wrote.
# Here every value is checked against a closed vocabulary or %q-quoted, and the
# prompt never touches a command line — it rides ssh's stdin into
# `herdr-draft create --prompt -`.
#
# Usage: dev-spawn --repo <name> --title <text> [--model M] [--effort E]
#                  [--base REF] [--dry-run]  < prompt
#   --repo     a checkout under ~/quantivly on dev (hub, sre-core, platform, ...)
#   --title    session title (herdr-draft normalises it to 32 runes)
#   --model    fable | opus | sonnet | haiku
#   --effort   low | medium | high | xhigh | max
#   --dry-run  show what herdr-draft would create; create nothing
# Exit: 0 created · 1 ssh/remote failure · 2 usage · 3 refused
#
# No pipefail: the prompt is piped into ssh, and a remote that exits without
# reading stdin (a refusal, a dry run) can SIGPIPE the printf — which is not a
# failure of anything. The status that matters is ssh's, read from PIPESTATUS.
set -u

host="${DEV_SPAWN_HOST:-dev}"
usage() { sed -n '/^# Usage:/,/^# Exit:/s/^# \{0,1\}//p' "$0" >&2; exit 2; }
die()   { printf 'dev-spawn: %s\n' "$2" >&2; exit "$1"; }

repo="" title="" model="" effort="" base="" dry=0
while (( $# )); do
  case "$1" in
    --repo|--title|--model|--effort|--base)
      (( $# >= 2 )) || die 2 "$1 needs a value"
      case "$1" in
        --repo) repo="$2" ;; --title) title="$2" ;; --model) model="$2" ;;
        --effort) effort="$2" ;; --base) base="$2" ;;
      esac
      shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) usage ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done

[[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$repo" != *..* ]] \
  || die 2 "--repo must be a bare checkout name under ~/quantivly on $host"
[[ -n "$title" ]] || die 2 "--title is required"
case "$model"  in ""|fable|opus|sonnet|haiku) ;; *) die 2 "--model: fable|opus|sonnet|haiku" ;; esac
case "$effort" in ""|low|medium|high|xhigh|max) ;; *) die 2 "--effort: low|medium|high|xhigh|max" ;; esac
[[ -z "$base" || "$base" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die 2 "--base must be a plain ref name"

prompt="$(cat)"
[[ -n "${prompt//[[:space:]]/}" ]] || die 3 "the prompt on stdin is blank"

args=(herdr-draft create --project . --worktree --prompt - --title "$title")
[[ -n "$model"  ]] && args+=(--model "$model")
[[ -n "$effort" ]] && args+=(--effort "$effort")
[[ -n "$base"   ]] && args+=(--base "$base")
(( dry )) && args+=(--dry-run)

# $repo is validated above, so it is safe unquoted here; everything else is %q.
remote="cd \"\$HOME/quantivly/$repo\" 2>/dev/null || exit 3; export PATH=\"\$HOME/.local/bin:\$PATH\"; exec $(printf '%q ' "${args[@]}")"
printf '%s' "$prompt" | ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" -- "$remote"
rc=${PIPESTATUS[1]}
case "$rc" in
  0) exit 0 ;;
  3) die 3 "no checkout ~/quantivly/$repo on $host (clone it over HTTPS first)" ;;
  *) die 1 "ssh/remote exited $rc" ;;
esac
```
- [ ] **Step 2:** `chmod +x scripts/dev-spawn && ./scripts/test-dev-spawn.sh` → `26 passed, 0 failed`. `shellcheck -x scripts/dev-spawn scripts/test-dev-spawn.sh` → clean.
- [ ] **Step 3: Mutation sweep** (apply, confirm the named rows fail, revert):
  - `%q ` → `%s `: both injection rows fail.
  - `--prompt -` → `--prompt "$prompt"`: "NOT on any command line" fails.
  - Replace the repo regex with `[[ -n "$repo" ]]`: the path-escape and metachar rows fail.
  - `exit 3` → `exit 1` inside `remote`: "the remote command exits 3" fails.
  - `rc=${PIPESTATUS[1]}` → `rc=0`: "ssh failure → 1" and "no such checkout → 3" fail.

### Task D3: Wire it (link, CI) and allow it (gated)

- [ ] **Step 1:** In `install.conf.yaml`, next to `~/.local/bin/claude-pick: scripts/claude-pick`, add `~/.local/bin/dev-spawn: scripts/dev-spawn`.
- [ ] **Step 2:** In `.github/workflows/ci.yml`, next to the hspawn step, add:
```yaml
      - name: Run the dev-spawn state table
        run: ./scripts/test-dev-spawn.sh
```
- [ ] **Step 3:** `pre-commit run --all-files` → pass. Commit: `feat: dev-spawn, the one door agents use to start sessions on dev (DO-635)`.
- [ ] **Step 4 (Zvi's OK; user-level, not in this repo):** add `"Bash(dev-spawn:*)"` to `permissions.allow` in `~/.claude/settings.json`. Account dirs copy it on their next build (`scripts/claude-account-dirs.sh:995-1004`); run `scripts/claude-account-dirs.sh --all` to apply it now.
- [ ] **Step 5: Live smoke** (after merge, deploy and Part B; one call per Bash invocation):
  - From an auto-mode session: `printf 'Reply ok, then stop.' | dev-spawn --repo hub --title "do635 smoke" --dry-run`. Expected: herdr-draft's dry-run summary and no classifier denial.
  - Then the same without `--dry-run`. Confirm with `ssh dev 'PATH=$HOME/.local/bin:$PATH herdr agent list'`, and that the laptop's herdr sidebar shows it under `dev (EC2)` with its statusLine tokens (B2).
  - Close it: `ssh dev 'PATH=$HOME/.local/bin:$PATH herdr pane close <id>'`, and remove its worktree with `herdr worktree remove` on dev.

---

## Part E — dev-setup work-only profile (quantivly/dev-setup)

Scoped for its own plan in that repo; the requirement is fixed here.

- **A work-only profile routes GitHub over HTTPS through gh:** `url.https://github.com/.insteadOf git@github.com:` and `…insteadOf ssh://git@github.com/`, with no `core.sshCommand` pin and no dependence on a forwarded agent.
- **It writes machine settings to `~/.gitconfig.local` whenever `~/.gitconfig` is a symlink**, never `--global` through it. Today, `modules/accounts.sh:387-412` writes `user.email`, `user.signingkey` and `commit.gpgsign` with `--global`.
- **It prefers a local signing key over "any forwarded key"** (`:409` falls back to `ssh-add -L | head -n1`, which on dev is the *personal* key).
- **Tests:** extend `tests/test-git-identity-routing.sh` with a fixture HOME whose `~/.gitconfig` is a symlink (assert the target is unchanged) and a no-agent row.

---

## 6. Execution order and gates

1. **Now, on approval:** save this plan to `docs/superpowers/plans/2026-09-19-do-635-dev-box-offload.md`. File Parts A–E in Linear with the full-URL links (raw GraphQL, since the MCP is down; chips need full URLs). Add the rabota note to WS6/STATUS. All of this needs Zvi's OK.
2. **A → B** (dev ops; Zvi runs or OKs each gated step). **C** and **E** in parallel with them.
3. **D** after B5 (herdr-draft with `--dry-run` on dev) and C's merge.
4. **Seat before every expensive step:** `personal-0` for this work, `quantivly-0` for dev smoke tests. Nothing on q1/q3 until 09-21.

## 7. Verification (end to end)

- **Git:** Part A Step 4 (no agent, no mux: fetch, ls-remote and push-dry-run work; dev's checkout stays clean).
- **Host:** `ssh dev 'bash ~/.dotfiles/scripts/verify-tools.sh --herdr'` passes. Dev's `HEAD` equals `origin/main`. The guard denies `gh auth token` on dev. `agents.slice` has `memory.max` = 10 GiB and contains `herdr-server.service`.
- **Seat:** `./scripts/test-hspawn.sh`, `test-claude-pick.sh` and `test-herdr-modular.sh` are green; every C3 mutation killed. On the laptop, `clauth start quantivly-0` refuses with rc 3, while `clauth list` still shows quantivly-0's usage (the monitoring grant kept).
- **Spawn:** `./scripts/test-dev-spawn.sh` shows 26/26; every D2 mutation killed. The live smoke (D3 Step 5) creates, shows, and closes a session on dev from an auto-mode agent without a classifier denial.
- **The point of the issue**, one week after D lands: the laptop's load and swap, sampled against DO-635's 13.4 and 56%. `agents.slice/memory.peak` on dev must stay under 8 GiB. quantivly-0's weekly utilization should be drawn from dev only: `clauth status --json` on the laptop, with zero `clauth start quantivly-0` holders here.

## 8. Side effects of the survey on dev

- Mostly read-only. Running `zsh -ic`/`zsh -lic` over ssh ran dev's interactive startup, whose agent auto-repair **repointed `~/.ssh/ssh_auth_sock`** at my forwarded agent socket (now dead; the next interactive login repairs it).
- `ssh -T git@github.com` opened a 10-minute ControlMaster to github.com, since expired.
- No config, credential, ref or unit was written.

## 9. Out of scope, flagged

- **personal-1 (nanoclaw's) on the laptop:** decided 2026-09-19 to list it in `CLAUDE_TENANT_MACHINE_OWNED` (Part C, Task C4) until cross-host utilization is better understood. That it is also clauth's `active_profile` here, and so the picker fallback's pick, is DO-632's to fix.
- **herdr 0.9.1 on both machines** (for `herdr --machine dev …`): restarting the laptop's server is disruptive with ~22 sessions live. Schedule it separately; nothing here needs it.
- **A picker hint** ("quantivly pool exhausted; dev has N% left"): wait until usage of dev's seat is read from dev, not only through the laptop's grant.
